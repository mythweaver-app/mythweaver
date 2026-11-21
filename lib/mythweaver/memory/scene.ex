defmodule Mythweaver.Memory.Scene do
  @moduledoc """
  The messages a scene memory summarizes, and the forms its prompt and safety checks need.
  Positions are `Messages.Message.position`s; the `#N` numbers shown to models and people are
  `position + 1`.
  """

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message

  @doc """
  The transcript messages in `first..last`: those visible to the AI (all of them with
  `prefs.include_hidden`), minus any whose active body is blank.
  """
  @spec messages(Scope.t(), Chat.t(), integer(), integer(), map()) :: [Message.t()]
  def messages(%Scope{} = scope, %Chat{} = chat, first, last, %{include_hidden: include_hidden}) do
    scope
    |> Messages.list_messages_between(chat, first, last)
    |> Enum.filter(&(include_hidden or &1.visible_to_ai))
    |> reject_blank()
  end

  @doc "The transcript messages in `first..last` whose ids are in `ids`, hidden or not, minus any whose active body is blank."
  @spec listed(Scope.t(), Chat.t(), integer(), integer(), [Ecto.UUID.t()]) :: [Message.t()]
  def listed(%Scope{} = scope, %Chat{} = chat, first, last, ids) do
    ids = MapSet.new(ids)

    scope
    |> Messages.list_messages_between(chat, first, last)
    |> Enum.filter(&MapSet.member?(ids, &1.id))
    |> reject_blank()
  end

  defp reject_blank(messages), do: Enum.reject(messages, &(String.trim(Message.active_content(&1) || "") == ""))

  @doc """
  The distinct characters who speak in `messages`, the player excluded, in order of first line.
  `override`, a list of character ids, replaces detection: its ids that are a participant of the
  chat (the player included), deduplicated, in the given order.
  """
  @spec speakers(Chat.t(), [Message.t()], [Ecto.UUID.t()] | nil) :: [Ecto.UUID.t()]
  def speakers(chat, messages, override \\ nil)

  def speakers(%Chat{} = chat, _messages, override) when is_list(override) do
    members = MapSet.new(chat.participants, & &1.character_id)
    override |> Enum.filter(&MapSet.member?(members, &1)) |> Enum.uniq()
  end

  def speakers(%Chat{player_character_id: player_id}, messages, nil) do
    messages
    |> Enum.filter(&(&1.author_is_character and &1.author_character_id not in [nil, player_id]))
    |> Enum.map(& &1.author_character_id)
    |> Enum.uniq()
  end

  @doc "Names of `speakers/3`."
  @spec speaker_names(Chat.t(), [Message.t()], [Ecto.UUID.t()] | nil) :: [String.t()]
  def speaker_names(chat, messages, override \\ nil)

  def speaker_names(%Chat{} = chat, messages, override) when is_list(override) do
    chat |> speakers(messages, override) |> Enum.map(&Chat.participant_name(chat, &1)) |> Enum.reject(&is_nil/1)
  end

  def speaker_names(%Chat{} = chat, messages, nil) do
    ids = speakers(chat, messages)

    messages
    |> Enum.filter(&(&1.author_character_id in ids))
    |> Enum.uniq_by(& &1.author_character_id)
    |> Enum.map(&author/1)
  end

  @doc "sha256 hex of the messages' `id:content` lines: changes when any of them is edited or swiped."
  @spec fingerprint([Message.t()]) :: String.t()
  def fingerprint(messages) do
    messages
    |> Enum.map_join("\n", &"#{&1.id}:#{Message.active_content(&1)}")
    |> sha256()
  end

  @doc "`\"[#N] Name: text\"` lines, separated by blank lines."
  @spec text([Message.t()]) :: String.t()
  def text(messages), do: Enum.map_join(messages, "\n\n", &"[##{&1.position + 1}] #{author(&1)}: #{content(&1)}")

  @doc "One message's author name."
  @spec author(Message.t()) :: String.t()
  def author(%Message{author_character: %{name: name}}) when is_binary(name), do: name
  def author(%Message{author_name: name}), do: name || ""

  @doc "One message's active content, trimmed."
  @spec content(Message.t()) :: String.t()
  def content(message), do: String.trim(Message.active_content(message) || "")

  @doc "Lowercase sha256 hex."
  @spec sha256(String.t()) :: String.t()
  def sha256(text), do: :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower)
end
