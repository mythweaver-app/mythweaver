defmodule Mythweaver.Lore.Rules do
  @moduledoc """
  Evaluates lore books' activation rules (`Mythweaver.Lore.BookRule`) for one reply.

  Rules are a gate on top of a book's scope, never a source of it: `Mythweaver.Lore.Activation` asks
  only about books already live in the chat. A book with no enabled rules passes; otherwise it passes
  when any enabled rule matches, and a rule matches when all its conditions hold. A template
  condition that fails to render does not hold, negated or not, so an error keeps the gate closed.

  Facts a condition reads are built only when some enabled rule needs them, so a chat with no rules
  costs no query.
  """

  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.Chats.Chat
  alias Mythweaver.Lore.BookRuleCondition
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Tags
  alias Mythweaver.Tags.Graph
  alias Mythweaver.Templates
  alias Mythweaver.Variables

  @doc """
  `book_id => detail` for each of `books` (with `rules: :conditions` loaded) whose gate stays shut, for
  a reply in `chat` whose card set is `character_ids` and whose responder is `responder` (nil for a
  preview). `graph` is the chat owner's tag graph. `known_character_tags` is the card set's expanded
  tags when the caller already has them (`Tags.participant_tags/2`), else nil.
  """
  @spec failures([LoreBook.t()], Chat.t(), MapSet.t(), Ecto.UUID.t() | nil, Graph.t(), MapSet.t() | nil) ::
          %{optional(Ecto.UUID.t()) => String.t()}
  def failures(books, %Chat{} = chat, character_ids, responder, graph, known_character_tags) do
    gated = for book <- books, rules = enabled_rules(book), rules != [], do: {book, rules}

    if gated == [] do
      %{}
    else
      kinds = for {_book, rules} <- gated, rule <- rules, c <- rule.conditions, into: MapSet.new(), do: c.kind

      facts = %{
        chat: chat,
        character_ids: character_ids,
        responder: responder,
        graph: graph,
        chat_tags: if(:chat_tag in kinds, do: chat_tags(chat, graph)),
        character_tags:
          if(:character_tag in kinds,
            do:
              known_character_tags || Tags.expanded_tags(chat.user_id, graph, :character, MapSet.to_list(character_ids))
          ),
        state: if(:template in kinds, do: template_state(chat))
      }

      for {book, rules} <- gated, detail = failure(rules, facts), detail != nil, into: %{}, do: {book.id, detail}
    end
  end

  defp enabled_rules(%LoreBook{rules: rules}), do: Enum.filter(rules, & &1.enabled)

  defp chat_tags(%Chat{id: nil}, _graph), do: MapSet.new()
  defp chat_tags(%Chat{} = chat, graph), do: Tags.expanded_tags(chat.user_id, graph, :chat, [chat.id])

  # Template conditions see only the stored variables as lore resolves.
  defp template_state(%Chat{id: nil}), do: Templates.State.new(%{}, %{chat: %{}, global: %{}}, nil)
  defp template_state(%Chat{id: id}), do: Templates.State.new(%{}, Variables.values(id), id)

  # nil when some rule matches, else the detail.
  defp failure(rules, facts) do
    Enum.reduce_while(rules, [], fn rule, errors ->
      case rule_match(rule, facts) do
        :ok -> {:halt, :matched}
        {:fail, new} -> {:cont, errors ++ new}
      end
    end)
    |> case do
      :matched ->
        nil

      [] ->
        dgettext("errors", "no activation rule matched")

      errors ->
        gettext_comment("The placeholder is the template engine's own error texts, separated by semicolons.")

        dgettext("errors", "no activation rule matched; template error: %{template_errors}",
          template_errors: Enum.join(errors, "; ")
        )
    end
  end

  # Cheap conditions first, so one that fails skips the template renders.
  defp rule_match(rule, facts) do
    {templates, others} = Enum.split_with(rule.conditions, &(&1.kind == :template))

    Enum.reduce_while(others ++ templates, :ok, fn condition, :ok ->
      case holds(condition, facts) do
        true -> {:cont, :ok}
        false -> {:halt, {:fail, []}}
        {:error, errors} -> {:halt, {:fail, errors}}
      end
    end)
  end

  defp holds(%BookRuleCondition{kind: :template, template: nil}, _facts), do: false

  defp holds(%BookRuleCondition{kind: :template} = condition, facts) do
    case Templates.condition(condition.template, facts.state) do
      {:ok, result} -> result != condition.negate
      {:error, _errors} = error -> error
    end
  end

  defp holds(%BookRuleCondition{} = condition, facts), do: check(condition, facts) != condition.negate

  defp check(%{kind: :chat, chat_id: id}, facts), do: id != nil and facts.chat.id != nil and id == facts.chat.id
  defp check(%{kind: :character_present, character_id: nil}, _facts), do: false
  defp check(%{kind: :character_present, character_id: id}, facts), do: MapSet.member?(facts.character_ids, id)
  defp check(%{kind: :responder, character_id: id}, facts), do: id != nil and id == facts.responder
  defp check(%{kind: :chat_tag, tags: tags}, facts), do: overlap?(tags, facts.chat_tags, facts.graph)
  defp check(%{kind: :character_tag, tags: tags}, facts), do: overlap?(tags, facts.character_tags, facts.graph)

  defp overlap?(tags, set, graph), do: Enum.any?(tags, &MapSet.member?(set, Graph.ideal(graph, &1)))
end
