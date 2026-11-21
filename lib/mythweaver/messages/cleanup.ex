defmodule Mythweaver.Messages.Cleanup do
  @moduledoc """
  Cleanup of a roleplay chat's old messages: those further back than `cleanup.after_messages`
  (default 100) from the newest.

  Triggers:

  - automatic: every `cleanup.every_messages` (default 10) messages, unless the chat owner turned
    `cleanup.automatic` (default on) off (`check_later/1`, called by `Messages` on each new message);
  - by hand, over the user's own chats with the user's values (`clean_up_mine/1`);
  - by hand, over every chat with the Site values, for holders of `"site.cleanup.run"` (`clean_up_all/1`).

  Effects on old messages (`run/2`):

  - two swipes at least `cleanup.swipe_similarity`% alike (default 80, `WordDiff.similarity/2`) keep
    only the newer, unless the older is the active one, which is never dropped;
  - their prompt snapshots are deleted;
  - their reasoning text is cleared;
  - their inactive swipes' vector embeddings are deleted.

  Nothing is broadcast: old messages are normally outside the loaded transcript, and every swipe or
  inspect action re-reads the message first.
  """

  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Query

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Lore.MessageEmbedding
  alias Mythweaver.Messages.CleanupRegistry
  alias Mythweaver.Messages.CleanupSupervisor
  alias Mythweaver.Messages.Message
  alias Mythweaver.Messages.MessageBody
  alias Mythweaver.Messages.PromptSnapshot
  alias Mythweaver.Messages.WordDiff
  alias Mythweaver.Repo
  alias Mythweaver.Settings

  @type thresholds :: %{after_messages: pos_integer(), swipe_similarity: 50..100}
  @type stats :: %{chats: non_neg_integer(), swipes: non_neg_integer(), snapshots: non_neg_integer()}

  @keys ~w(cleanup.automatic cleanup.after_messages cleanup.every_messages cleanup.swipe_similarity)

  @doc """
  Runs `check/1` in the background. One chat has at most one check running: a trigger while one
  runs asks it for one more pass, so a burst coalesces.
  """
  @spec check_later(Ecto.UUID.t()) :: :ok
  def check_later(chat_id) do
    if background?() do
      {:ok, _pid} =
        Task.Supervisor.start_child(CleanupSupervisor, fn ->
          case Registry.register(CleanupRegistry, {:chat, chat_id}, nil) do
            {:ok, _owner} -> check_loop(chat_id)
            {:error, {:already_registered, pid}} -> send(pid, :again)
          end
        end)
    end

    :ok
  end

  defp check_loop(chat_id) do
    flush_again()
    check(chat_id)

    receive do
      :again -> check_loop(chat_id)
    after
      0 -> :ok
    end
  end

  defp flush_again do
    receive do
      :again -> flush_again()
    after
      0 -> :ok
    end
  end

  @doc """
  The automatic cleanup: runs `run/2` over a roleplay chat with its owner's values when automatic
  cleanup is on, the chat has more than `cleanup.after_messages` messages and their count is a
  multiple of `cleanup.every_messages`.
  """
  @spec check(Ecto.UUID.t()) :: :ok
  def check(chat_id) do
    with %Chat{kind: :roleplay, user_id: user_id} = chat when is_binary(user_id) <- Chats.get_chat(chat_id),
         %Scope{} = scope <- user_id |> Accounts.get_user() |> Scope.for_user() do
      values = Settings.get_many(scope, @keys)

      count =
        Repo.aggregate(from(m in Message, where: m.chat_id == ^chat.id and m.draft == false), :count)

      if values["cleanup.automatic"] and count > values["cleanup.after_messages"] and
           rem(count, values["cleanup.every_messages"]) == 0 do
        run(chat, thresholds(values))
      end
    end

    :ok
  end

  @doc "Cleans every roleplay chat the scope's user owns with the user's values, automatic cleanup on or off."
  @spec clean_up_mine(Scope.t()) :: {:ok, stats()}
  def clean_up_mine(%Scope{user: %User{id: user_id}} = scope) do
    thresholds = thresholds(Settings.get_many(scope, @keys))
    chats = Repo.all(from(c in Chat, where: c.user_id == ^user_id and c.kind == :roleplay))
    {:ok, run_all(chats, thresholds)}
  end

  @doc "Cleans every roleplay chat in the app with the Site values; needs `\"site.cleanup.run\"`."
  @spec clean_up_all(Scope.t()) :: {:ok, stats()} | {:error, :unauthorized}
  def clean_up_all(%Scope{} = scope) do
    if Scope.can?(scope, "site.cleanup.run") do
      # A scope without a user reads the site row only, so users' overrides are ignored.
      thresholds = thresholds(Settings.get_many(%Scope{}, @keys))
      chats = Repo.all(from(c in Chat, where: c.kind == :roleplay))
      {:ok, run_all(chats, thresholds)}
    else
      {:error, :unauthorized}
    end
  end

  @doc "The flash text for a manual cleanup's stats."
  @spec summary(stats()) :: String.t()
  def summary(%{chats: chats, swipes: swipes, snapshots: snapshots}) do
    chat_phrase =
      dpngettext(
        "commands",
        "unit: chats a manual cleanup went through",
        "%{chat_count} chat",
        "%{chat_count} chats",
        chats,
        chat_count: Mythweaver.Format.number(chats)
      )

    swipe_phrase =
      dpngettext(
        "commands",
        "unit: swipes a manual cleanup merged",
        "%{swipe_count} swipe",
        "%{swipe_count} swipes",
        swipes,
        swipe_count: Mythweaver.Format.number(swipes)
      )

    snapshot_phrase =
      dpngettext(
        "commands",
        "unit: prompt snapshots a manual cleanup removed",
        "%{snapshot_count} prompt snapshot",
        "%{snapshot_count} prompt snapshots",
        snapshots,
        snapshot_count: Mythweaver.Format.number(snapshots)
      )

    gettext_comment(
      ~s(Flash after a manual cleanup. Each placeholder is a counted phrase translated on its own: "3 chats", "1 swipe", "2 prompt snapshots".)
    )

    dgettext("commands", "Cleaned up %{chat_phrase}: merged %{swipe_phrase} and removed %{snapshot_phrase}.",
      chat_phrase: chat_phrase,
      swipe_phrase: swipe_phrase,
      snapshot_phrase: snapshot_phrase
    )
  end

  defp run_all(chats, thresholds) do
    Enum.reduce(chats, %{chats: 0, swipes: 0, snapshots: 0}, fn chat, acc ->
      Map.merge(acc, run(chat, thresholds), fn _key, a, b -> a + b end)
    end)
  end

  defp thresholds(values) do
    %{
      after_messages: values["cleanup.after_messages"],
      swipe_similarity: values["cleanup.swipe_similarity"]
    }
  end

  @doc "One unconditional cleanup pass over the chat's messages older than `thresholds.after_messages`."
  @spec run(Chat.t(), thresholds()) :: stats()
  def run(%Chat{} = chat, thresholds) do
    # Newest-first like the transcript; positions have gaps after deletes, so cut by offset.
    old_ids =
      from(m in Message,
        where: m.chat_id == ^chat.id and m.draft == false,
        order_by: [desc: m.position, desc: m.inserted_at],
        offset: ^thresholds.after_messages,
        select: m.id
      )

    swipes = merge_swipes(old_ids, thresholds.swipe_similarity / 100)

    old_body_ids = from(b in MessageBody, where: b.message_id in subquery(old_ids), select: b.id)

    {snapshots, _} =
      Repo.delete_all(from(s in PromptSnapshot, where: s.message_body_id in subquery(old_body_ids)))

    Repo.update_all(
      from(b in MessageBody,
        where: b.message_id in subquery(old_ids) and not is_nil(b.reasoning) and not b.generating
      ),
      set: [reasoning: nil, reasoning_redacted: nil, reasoning_share_redacted: nil]
    )

    inactive_ids =
      from(b in MessageBody, where: b.message_id in subquery(old_ids) and not b.active, select: b.id)

    Repo.delete_all(from(e in MessageEmbedding, where: e.message_body_id in subquery(inactive_ids)))

    %{chats: 1, swipes: swipes, snapshots: snapshots}
  end

  defp merge_swipes(old_ids, similarity) do
    candidates =
      from(b in MessageBody,
        where: b.message_id in subquery(old_ids),
        group_by: b.message_id,
        having: count(b.id) >= 2 and not fragment("bool_or(?)", b.generating),
        select: b.message_id
      )

    from(b in MessageBody,
      where: b.message_id in subquery(candidates),
      order_by: [asc: b.message_id, asc: b.inserted_at, asc: b.id],
      select: struct(b, [:id, :message_id, :content, :active, :source_body_id])
    )
    |> Repo.all()
    |> Enum.chunk_by(& &1.message_id)
    |> Enum.reduce(0, fn bodies, total -> total + merge_message(bodies, similarity) end)
  end

  # `bodies` oldest first. Returns how many were dropped.
  defp merge_message(bodies, similarity) do
    {_kept, drops} =
      bodies
      |> Enum.reverse()
      |> Enum.reduce({[], []}, fn body, {kept, drops} ->
        # `kept` runs nearest-newer first, so `hd(similar)` is the closest newer survivor.
        {similar, rest} =
          Enum.split_with(kept, &WordDiff.similar?(body.content, &1.content, similarity))

        cond do
          similar == [] -> {[body | kept], drops}
          body.active -> {[body | rest], drops ++ Enum.map(similar, &{&1, body})}
          true -> {kept, drops ++ [{body, hd(similar)}]}
        end
      end)

    if drops != [] do
      sources = Map.new(bodies, &{&1.id, &1.source_body_id})
      {:ok, _} = Repo.transaction(fn -> Enum.reduce(drops, sources, &drop/2) end)
    end

    length(drops)
  end

  # Deletes `dropped`, handing its place in the swipe lineage to `kept`. `sources` maps each of the
  # message's body ids to its current `source_body_id`.
  defp drop({%MessageBody{id: dropped_id}, %MessageBody{id: kept_id}}, sources) do
    dropped_source = Map.fetch!(sources, dropped_id)

    Repo.update_all(
      from(b in MessageBody, where: b.source_body_id == ^dropped_id and b.id != ^kept_id),
      set: [source_body_id: kept_id]
    )

    sources =
      Map.new(sources, fn
        {id, ^dropped_id} when id != kept_id -> {id, kept_id}
        entry -> entry
      end)

    sources =
      if Map.fetch!(sources, kept_id) == dropped_id do
        inherited = if dropped_source != kept_id, do: dropped_source
        Repo.update_all(from(b in MessageBody, where: b.id == ^kept_id), set: [source_body_id: inherited])
        Map.put(sources, kept_id, inherited)
      else
        sources
      end

    Repo.delete_all(from(b in MessageBody, where: b.id == ^dropped_id))
    Map.delete(sources, dropped_id)
  end

  defp background?, do: Application.get_env(:mythweaver, :message_cleanup_in_background, true)
end
