defmodule MythweaverWeb.CommandPalette.Suggestions do
  @moduledoc """
  What the command palette offers for one parameter: a list of `%{value, label, detail}` (`value`
  is what the command receives, an id for entities), `:free` for typed text, or `:upload` for an
  image picked or pasted into the palette.
  """

  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Lore
  alias Mythweaver.Memory
  alias Mythweaver.Messages
  alias Mythweaver.Prompts
  alias Mythweaver.Scripts
  alias Mythweaver.Scripts.API
  alias Mythweaver.Tags
  alias Mythweaver.Tags.Tag
  alias Mythweaver.Variables

  @type candidate :: %{value: String.t(), label: String.t(), detail: String.t() | nil}

  @message_limit 200

  @doc "What `param` offers to `scope` with `chat` open; `:chat` lists every chat `scope` may see."
  @spec candidates(Scope.t(), map(), Chat.t() | nil) :: [candidate()] | :free | :upload
  def candidates(%Scope{}, %{type: type}, _chat) when type in [:string, :integer, :number], do: :free
  def candidates(%Scope{}, %{type: :image}, _chat), do: :upload
  def candidates(%Scope{}, %{type: :boolean}, _chat), do: Enum.map(~w(true false), &plain/1)
  def candidates(%Scope{}, %{type: :choice, choices: choices}, _chat), do: Enum.map(choices, &plain/1)
  def candidates(%Scope{}, %{type: type}, nil) when type in [:participant, :bot, :message], do: []

  # Every participant, the player included (as the rail's reply buttons, `mw.generation.generate`
  # and `Mythweaver.Scripts.Command.cast_args/4` accept); `:bot` leaves the player out. Unmuted
  # first, each group in the participants panel's order; `panel_order?` (toggle mute) keeps muted
  # ones in place.
  def candidates(%Scope{}, %{type: :bot, panel_order?: true}, chat),
    do: Enum.map(Chat.bots(chat), &participant(&1, chat))

  def candidates(%Scope{}, %{type: :participant}, chat),
    do: chat.participants |> unmuted_first() |> Enum.map(&participant(&1, chat))

  def candidates(%Scope{}, %{type: :bot}, chat),
    do: chat |> Chat.bots() |> unmuted_first() |> Enum.map(&participant(&1, chat))

  def candidates(%Scope{} = scope, %{type: :message}, chat) do
    {messages, _more?} = Messages.list_messages_page(scope, chat, limit: @message_limit)

    for message <- Enum.reverse(messages) do
      table = API.Messages.to_table(message)
      item(message.id, message_label(table), nil)
    end
  end

  def candidates(%Scope{} = scope, %{type: :character, editable?: true}, _chat),
    do: for(c <- Characters.list_editable_characters(scope), do: item(c.id, c.name, nil))

  def candidates(%Scope{} = scope, %{type: :prompt, editable?: true}, _chat),
    do: for(p <- Prompts.list_editable_prompts(scope), do: item(p.id, p.name, to_string(p.purpose)))

  def candidates(%Scope{} = scope, %{type: :prompt_block, editable?: true}, _chat),
    do: for(b <- Prompts.list_editable_blocks(scope), do: item(b.id, b.name, nil))

  def candidates(%Scope{} = scope, %{type: :prompt_outlet, editable?: true}, _chat),
    do: for(o <- Prompts.list_editable_outlets(scope), do: item(o.id, o.name, o.key))

  def candidates(%Scope{} = scope, %{type: :model, editable?: true}, _chat),
    do: for(m <- AI.list_editable_models(scope), do: item(m.id, m.name, m.api_model_id))

  def candidates(%Scope{} = scope, %{type: :character}, _chat),
    do: for(c <- Characters.list_characters(scope), do: item(c.id, c.name, nil))

  def candidates(%Scope{} = scope, %{type: :lore_book}, _chat),
    do: for(b <- Lore.list_books(scope), do: item(b.id, b.name, nil))

  def candidates(%Scope{} = scope, %{type: :lore_entry}, _chat) do
    for e <- Lore.list_entries(scope) do
      detail =
        if e.books == [],
          do: dpgettext("commands", "badge: palette suggestion detail, the lore entry is in no book", "Unlinked"),
          else: Mythweaver.Format.list(Enum.map(e.books, & &1.name))

      item(e.id, e.name, detail)
    end
  end

  def candidates(%Scope{} = scope, %{type: :prompt}, _chat),
    do: for(p <- Prompts.list_prompts(scope), do: item(p.id, p.name, to_string(p.purpose)))

  def candidates(%Scope{} = scope, %{type: :prompt_block}, _chat),
    do: for(b <- Prompts.list_blocks(scope), do: item(b.id, b.name, nil))

  def candidates(%Scope{} = scope, %{type: :prompt_outlet}, _chat),
    do: for(o <- Prompts.list_outlets(scope), do: item(o.id, o.name, o.key))

  def candidates(%Scope{} = scope, %{type: :model}, _chat),
    do: for(m <- AI.list_models(scope), do: item(m.id, m.name, m.api_model_id))

  def candidates(%Scope{} = scope, %{type: :ai_provider}, _chat),
    do: for(p <- AI.list_providers(scope), do: item(p.id, p.name, nil))

  def candidates(%Scope{} = scope, %{type: :script}, _chat),
    do: for(s <- Scripts.list_scripts(scope), do: item(s.id, s.name, to_string(s.trigger)))

  def candidates(%Scope{} = scope, %{type: :tag}, _chat),
    do: for(t <- Tags.list_editable_tags(scope), do: item(t.id, Tag.text(t), tag_owner(t)))

  def candidates(%Scope{} = scope, %{type: :global_variable}, _chat),
    do: for(v <- Variables.list_global_variables(scope), do: item(v.id, v.key, nil))

  def candidates(%Scope{} = scope, %{type: :memory_profile}, _chat),
    do: for(p <- Memory.list_profiles(scope), do: item(p.id, p.name, nil))

  def candidates(%Scope{} = scope, %{type: :side_prompt}, _chat),
    do: for(s <- Memory.list_side_prompts(scope), do: item(s.id, s.name, nil))

  def candidates(%Scope{} = scope, %{type: :chat}, _chat),
    do: for(c <- Chats.list_chats(scope), do: item(c.id, Chat.title(c), nil))

  defp participant(p, chat) do
    detail =
      cond do
        p.character_id == chat.player_character_id ->
          dpgettext("commands", "badge: palette suggestion detail, this participant is the player's character", "You")

        p.muted ->
          dpgettext("commands", "badge: palette suggestion detail, this chat participant is muted", "Muted")

        true ->
          nil
      end

    item(p.character_id, p.character.name, detail)
  end

  defp tag_owner(%Tag{user_id: nil}),
    do: dpgettext("commands", "badge: palette suggestion detail, a site-wide tag", "Site")

  defp tag_owner(%Tag{}), do: dpgettext("commands", "badge: palette suggestion detail, the user's own tag", "Personal")

  # The excerpt is the message's first 80 characters, cut anywhere.
  defp message_label(table) do
    dpgettext(
      "commands",
      "option: a chat message in the palette picker: its number, author and opening text",
      "#%{message_position} %{author_name}: %{message_excerpt}",
      message_position: Mythweaver.Format.number(table.position),
      author_name: table.author.name,
      message_excerpt: String.slice(table.text || "", 0, 80)
    )
  end

  # `Enum.split_with/2` keeps each group's order.
  defp unmuted_first(participants) do
    {unmuted, muted} = Enum.split_with(participants, &(not &1.muted))
    unmuted ++ muted
  end

  defp plain(value), do: item(value, value, nil)
  defp item(value, label, detail), do: %{value: value, label: label, detail: detail}
end
