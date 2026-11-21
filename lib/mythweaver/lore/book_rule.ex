defmodule Mythweaver.Lore.BookRule do
  @moduledoc """
  One activation rule of a lore book: it matches when all of its `conditions` hold. A book with at
  least one enabled rule activates only where one of them matches (`Mythweaver.Lore.Rules`).
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Lore.BookRuleCondition
  alias Mythweaver.Lore.LoreBook

  @type t :: %__MODULE__{}

  schema "lore_book_rules" do
    field :position, :integer, default: 0
    field :enabled, :boolean, default: true

    belongs_to :book, LoreBook, foreign_key: :lore_book_id

    has_many :conditions, BookRuleCondition,
      foreign_key: :lore_book_rule_id,
      on_replace: :delete,
      preload_order: [asc: :position, asc: :id]

    timestamps(type: :utc_datetime)
  end

  @doc """
  `refs` lists the chats and characters a condition may name (`BookRuleCondition.changeset/4`).
  """
  def changeset(rule, attrs, position, refs) do
    # A rule just built by `cast_assoc` has no conditions loaded yet.
    rule =
      case rule.conditions do
        %Ecto.Association.NotLoaded{} -> %{rule | conditions: []}
        _ -> rule
      end

    changeset = cast(rule, attrs, [:enabled])
    changeset = if is_nil(position), do: changeset, else: put_change(changeset, :position, position)

    changeset =
      cast_assoc(changeset, :conditions,
        with: &BookRuleCondition.changeset(&1, &2, &3, refs),
        sort_param: :conditions_sort,
        drop_param: :conditions_drop
      )

    case get_field(changeset, :conditions) do
      [_ | _] -> changeset
      _ -> add_error(changeset, :conditions, dgettext_noop("errors", "add at least one condition"))
    end
  end
end
