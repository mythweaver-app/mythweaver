defmodule Mythweaver.Generation.TurnPolicy do
  @moduledoc """
  Decides which characters reply, and in what order, for one round of a group chat. Pure: it reads
  the chat and its messages and returns character ids; the conductor does the generating.

  Ported from SillyTavern's group reply strategies (`public/scripts/group-chats.js`:
  `activateNaturalOrder`, `activateListOrder`, `activatePooledOrder`) plus AikoBots' max-turns cap:

  - `:manual`: nobody after a player message; one random character on an auto-mode tick.
  - `:list`: every eligible participant, in speaking order.
  - `:pooled`: one character who has not spoken since the player last did; once all have, a random
    one other than the last speaker.
  - `:natural`: characters named in the last message first, then each by a talkativeness roll; if
    nobody activates, one random (preferring the non-silent). On an auto tick the last speaker is
    excluded unless `allow_self_responses`.

  Eligible = participants other than the player character and the characters users play
  (`played`, their locks) that are not `muted`. `chat.max_turns` caps every strategy but `:manual`.

  `waiting/3` is the `turn_mode: :round` gate the conductor checks before a round.
  """

  alias Mythweaver.Chats.Chat
  alias Mythweaver.Messages.Message

  @type trigger :: :player | :auto

  @doc """
  Character ids to reply this round, in speaking order. `chat` must have `participants: [:character]`
  preloaded (as `Mythweaver.Chats.get_chat/1` does); `messages` is `Mythweaver.Messages.list_messages/1`;
  `played` the locked characters (`Mythweaver.Chats.locks/1`), never picked.
  """
  @spec round(Chat.t(), [Message.t()], trigger(), [Ecto.UUID.t()]) :: [Ecto.UUID.t()]
  def round(%Chat{} = chat, messages, trigger, played \\ []) when trigger in [:player, :auto] do
    eligible =
      Enum.filter(
        chat.participants,
        &(&1.character_id != chat.player_character_id and &1.character_id not in played and not &1.muted)
      )

    chosen = choose(chat.reply_strategy, chat, eligible, messages, trigger)

    chosen =
      if chat.reply_strategy != :manual and chat.max_turns,
        do: Enum.take(chosen, chat.max_turns),
        else: chosen

    Enum.map(chosen, & &1.character_id)
  end

  @doc """
  The users among `holder_ids` (who hold character locks) a `turn_mode: :round` chat still waits on:
  those who neither posted (`author_user_id`) since the last message no user posted (an AI reply),
  nor are in `skipped`.
  """
  @spec waiting([Ecto.UUID.t()], [Message.t()], Enumerable.t()) :: [Ecto.UUID.t()]
  def waiting(holder_ids, messages, skipped) do
    posted =
      messages
      |> Enum.reverse()
      |> Enum.take_while(&(&1.author_user_id != nil))
      |> MapSet.new(& &1.author_user_id)

    Enum.reject(holder_ids, &(MapSet.member?(posted, &1) or &1 in skipped))
  end

  defp choose(:manual, _chat, _eligible, _messages, :player), do: []
  defp choose(:manual, _chat, eligible, _messages, :auto), do: Enum.take_random(eligible, 1)

  defp choose(:list, _chat, eligible, _messages, _trigger), do: eligible

  defp choose(:pooled, chat, eligible, messages, trigger) do
    spoken = if trigger == :player, do: [], else: spoken_since_player(messages, chat.player_character_id)

    case Enum.reject(eligible, &(&1.character_id in spoken)) do
      [] ->
        last_author = author_id(List.last(messages))

        pool =
          if length(eligible) > 1,
            do: Enum.reject(eligible, &(&1.character_id == last_author)),
            else: eligible

        Enum.take_random(pool, 1)

      fresh ->
        Enum.take_random(fresh, 1)
    end
  end

  defp choose(:natural, chat, eligible, messages, trigger) do
    last = List.last(messages)
    banned = if trigger == :auto and not chat.allow_self_responses, do: author_id(last)
    candidates = Enum.reject(eligible, &(banned && &1.character_id == banned))

    # Each name split once, not once per word of the message.
    names = Enum.map(candidates, &{&1, words(&1.character.name)})

    mentioned =
      for word <- words(text(last)),
          {p, name_words} <- names,
          word in name_words,
          do: p

    rolled = Enum.filter(Enum.shuffle(candidates), &(talk(&1) >= :rand.uniform()))

    activated =
      case {mentioned ++ rolled, candidates} do
        {[], []} ->
          []

        {[], _} ->
          case Enum.filter(candidates, &(talk(&1) > 0)) do
            [] -> Enum.take_random(candidates, 1)
            chatty -> Enum.take_random(chatty, 1)
          end

        {list, _} ->
          list
      end

    Enum.uniq_by(activated, & &1.character_id)
  end

  # Character authors since the player's last message, newest first. String-authored messages are
  # skipped without ending the walk.
  defp spoken_since_player(messages, player_id) do
    messages
    |> Enum.reverse()
    |> Enum.reduce_while([], fn
      %Message{author_is_character: true, author_character_id: ^player_id}, acc -> {:halt, acc}
      %Message{author_is_character: true, author_character_id: id}, acc when not is_nil(id) -> {:cont, [id | acc]}
      _message, acc -> {:cont, acc}
    end)
  end

  defp author_id(%Message{author_is_character: true, author_character_id: id}), do: id
  defp author_id(_message), do: nil

  defp talk(participant), do: participant.talkativeness || participant.character.talkativeness

  # Same word split as ST's `extractAllWords`.
  defp words(s), do: ~r/\b\w+\b/u |> Regex.scan(String.downcase(s || "")) |> List.flatten()

  defp text(nil), do: nil
  defp text(message), do: Message.active_content(message)
end
