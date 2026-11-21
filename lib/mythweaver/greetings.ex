defmodule Mythweaver.Greetings do
  @moduledoc """
  A new chat's opening messages, chosen at creation (`Chat`'s virtual `greeting`/`greeting_text`),
  after SillyTavern (`script.js` `getFirstMessage`, `group-chats.js` `getFirstCharacterMessage`).

  `greeting` is nil (no greeting), a non-player participant's character id, `"random"` (one of them
  with greetings), `"all"` (each of them with greetings, in speaking order, one message apiece), or
  `"custom"` (`greeting_text`, posted by a non-character author named "Narrator").

  A character's message carries all its greetings (`Character.greetings/2`) as swipes, rendered once
  as Liquid. A one-on-one chat shows the first, as SillyTavern's solo chat does (`first_mes`, or the
  first alternate when it is blank); a group shows one picked at random, as a SillyTavern group does.
  A chat is a group when it has two or more non-player characters (`Chat.bots/1`); only then do
  `group_greetings` count. The player never greets.
  """

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message
  alias Mythweaver.Prompts.Builder

  @narrator "Narrator"

  @doc "Whether each of `characters` has greetings: `id => {one-on-one?, group?}`."
  @spec index([Character.t()]) :: %{Ecto.UUID.t() => {boolean(), boolean()}}
  def index(characters) when is_list(characters), do: Map.new(characters, &{&1.id, flags(&1)})

  @doc """
  The greeting values a chat of `participant_ids` played by `player_id` offers, in display order,
  per an `index/1` map: `"all"` with two or more greeters, `"random"` with one or more, each
  greeter's character id, then `"custom"`.
  """
  @spec choices(map(), [Ecto.UUID.t()], Ecto.UUID.t() | nil) :: [String.t()]
  def choices(index, participant_ids, player_id) do
    greeters = greeter_ids(index, participant_ids, player_id)

    if(match?([_, _ | _], greeters), do: ["all"], else: []) ++
      if(greeters == [], do: [], else: ["random"]) ++ greeters ++ ["custom"]
  end

  # The non-player participants, in order, who could greet a chat of `participant_ids` played by
  # `player_id`, per an `index/1` map. Ids missing from it are skipped.
  defp greeter_ids(index, participant_ids, player_id) do
    bots = participant_ids |> Enum.uniq() |> Enum.reject(&(&1 == player_id))
    slot = if group?(bots), do: 1, else: 0

    for id <- bots, {:ok, tuple} <- [Map.fetch(index, id)], elem(tuple, slot), do: id
  end

  defp flags(%Character{} = c), do: {Character.greetings(c, false) != [], Character.greetings(c, true) != []}

  @doc """
  Posts the greeting chosen for the just-created `chat`, if any. Every greeting renders before any
  is posted, so a template error posts nothing.
  """
  @spec post(Scope.t(), Chat.t()) ::
          :none
          | {:ok, [Message.t(), ...]}
          | {:error, :no_greeting | :unauthorized | String.t() | Ecto.Changeset.t()}
  def post(_scope, %Chat{greeting: nil}), do: :none

  def post(%Scope{} = scope, %Chat{} = created) do
    chat = Chats.get_chat!(created.id)
    bots = Chat.bots(chat)
    group? = group?(bots)
    characters = for p <- bots, p.character, into: %{}, do: {p.character_id, p.character}

    greeters =
      characters
      |> Map.new(fn {id, c} -> {id, flags(c)} end)
      |> greeter_ids(Enum.map(chat.participants, & &1.character_id), chat.player_character_id)
      |> Enum.map(&Map.fetch!(characters, &1))

    case created.greeting do
      "custom" ->
        with {:ok, texts} <- render(scope, chat, nil, [created.greeting_text]),
             {:ok, message} <- Messages.post_greeting(scope, chat, {:name, @narrator}, texts, 0),
             do: {:ok, [message]}

      "all" ->
        post_characters(scope, chat, greeters, group?)

      "random" ->
        post_characters(scope, chat, Enum.take_random(greeters, 1), group?)

      id ->
        post_characters(scope, chat, Enum.filter(greeters, &(&1.id == id)), group?)
    end
  end

  defp post_characters(scope, chat, characters, group?) do
    with {:ok, rendered} <- render_characters(scope, chat, characters, group?) do
      rendered
      |> Enum.reduce_while({:ok, []}, fn {character, texts}, {:ok, posted} ->
        active = if group?, do: Enum.random(0..(length(texts) - 1)), else: 0

        case Messages.post_greeting(scope, chat, {:character, character.id}, texts, active) do
          {:ok, message} -> {:cont, {:ok, [message | posted]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, posted} -> {:ok, Enum.reverse(posted)}
        error -> error
      end
    end
  end

  # Each character's rendered greetings; one whose all render blank is skipped, none left is
  # `{:error, :no_greeting}`, and the first render error stops the lot.
  defp render_characters(scope, chat, characters, group?) do
    characters
    |> Enum.reduce_while([], fn character, acc ->
      case render(scope, chat, character.id, Character.greetings(character, group?)) do
        {:ok, texts} -> {:cont, [{character, texts} | acc]}
        {:error, :no_greeting} -> {:cont, acc}
        error -> {:halt, error}
      end
    end)
    |> case do
      [] -> {:error, :no_greeting}
      [_ | _] = rendered -> {:ok, Enum.reverse(rendered)}
      error -> error
    end
  end

  # Rendered texts, blank ones dropped; none left is `{:error, :no_greeting}`.
  defp render(scope, chat, author_id, sources) do
    with {:ok, texts} <- Builder.render_texts(scope, chat, author_id, sources) do
      case Enum.reject(texts, &(String.trim(&1) == "")) do
        [] -> {:error, :no_greeting}
        texts -> {:ok, texts}
      end
    end
  end

  defp group?(bots), do: length(bots) >= 2
end
