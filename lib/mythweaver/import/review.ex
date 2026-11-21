defmodule Mythweaver.Import.Review do
  @moduledoc """
  The per-item decisions for importing a `Mythweaver.Bundle`: one row per decision-kind item
  (roots first, then in bundle order) with its local match (`Mythweaver.Bundle.Origins.match/3`),
  the options it allows and the default.

  No match: Copy or Skip (Copy). A match `scope` may edit: Replace, Copy or Skip (Replace). A match
  it may only use: Skip or Copy (Skip).
  """

  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Bundle
  alias Mythweaver.Bundle.Origins
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Ownership

  @type decision :: :replace | :copy | :skip

  @type row :: %{
          uid: String.t(),
          kind: Bundle.kind(),
          name: String.t(),
          root?: boolean(),
          match: %{id: Ecto.UUID.t(), name: String.t(), editable?: boolean()} | nil,
          options: [decision()],
          default: decision()
        }

  @spec review(Scope.t(), Bundle.t()) :: [row()]
  def review(%Scope{} = scope, %Bundle{} = bundle) do
    decision_kinds = Bundle.decision_kinds()

    bundle.items
    |> Enum.filter(&(&1.kind in decision_kinds))
    |> Enum.sort_by(&{not &1.root, &1.position})
    |> Enum.map(&row(scope, &1))
  end

  defp row(scope, item) do
    match =
      case Origins.match(scope, item.kind, item.uid) do
        nil -> nil
        found -> %{id: found.id, name: match_name(found), editable?: editable?(scope, found), row: found}
      end

    {options, default} =
      case match do
        nil -> {[:copy, :skip], :copy}
        %{editable?: true} -> {[:replace, :copy, :skip], :replace}
        %{editable?: false} -> {[:skip, :copy], :skip}
      end

    %{
      uid: item.uid,
      kind: item.kind,
      name: item.name,
      root?: item.root,
      match: match && Map.delete(match, :row),
      options: options,
      default: default
    }
  end

  defp match_name(%Chat{} = chat), do: Chat.title(chat)
  defp match_name(row), do: row.name

  defp editable?(scope, %Chat{} = chat), do: Chats.authorize(scope, chat, :manage) == :ok
  defp editable?(scope, row), do: Ownership.authorize_edit(scope, row) == :ok

  @doc "Button/select text for each decision."
  @spec labels() :: %{decision() => String.t()}
  def labels do
    %{
      replace: dpgettext("import_export", "option: import an item over its existing local match", "Replace"),
      copy: dpgettext("import_export", "option: import an item as a new copy", "Copy"),
      skip: dpgettext("import_export", "option: do not import an item", "Skip")
    }
  end

  @doc "The singular, capitalized label of a bundle item kind (\"Lore book\")."
  @spec kind_label(Bundle.kind()) :: String.t()
  def kind_label(:character), do: dpgettext("import_export", "badge: kind of an imported item", "Character")
  def kind_label(:lore_book), do: dpgettext("import_export", "badge: kind of an imported item", "Lore book")
  def kind_label(:lore_entry), do: dpgettext("import_export", "badge: kind of an imported item", "Lore entry")
  def kind_label(:lore_pool), do: dpgettext("import_export", "badge: kind of an imported item", "Lore pool")
  def kind_label(:prompt), do: dpgettext("import_export", "badge: kind of an imported item", "Prompt")
  def kind_label(:prompt_block), do: dpgettext("import_export", "badge: kind of an imported item", "Prompt block")
  def kind_label(:prompt_outlet), do: dpgettext("import_export", "badge: kind of an imported item", "Outlet")
  def kind_label(:ai_model), do: dpgettext("import_export", "badge: kind of an imported item", "AI model")
  def kind_label(:script), do: dpgettext("import_export", "badge: kind of an imported item", "Script")
  def kind_label(:memory_profile), do: dpgettext("import_export", "badge: kind of an imported item", "Memory profile")
  def kind_label(:side_prompt), do: dpgettext("import_export", "badge: kind of an imported item", "Side prompt")
  def kind_label(:side_prompt_set), do: dpgettext("import_export", "badge: kind of an imported item", "Side prompt set")
  def kind_label(:chat), do: dpgettext("import_export", "badge: kind of an imported item", "Chat")
end
