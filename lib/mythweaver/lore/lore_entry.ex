defmodule Mythweaver.Lore.LoreEntry do
  @moduledoc """
  One piece of world knowledge, with the rules that decide when it enters a prompt and where.

  An entry is activated either unconditionally (`activation: :constant`) or by keyword scan
  (`:keyword`, the default), optionally narrowed by `secondary_keywords` under `secondary_logic`.
  A keyword wrapped as `/source/flags` is a regex, validated at cast time so a bad pattern is a
  changeset error rather than a runtime crash inside `Mythweaver.Lore.Matcher`. A `:vector` entry
  activates when `Mythweaver.Lore.Embeddings` finds its content similar enough to a message in its
  scan window, or on its keywords if it has any.

  Injection position is `outlet` + `placement`, flattened by `slot/1`. `:at_depth` and `:custom`
  ignore `placement`: a depth number and a named outlet are each a single insertion point with no
  before/after axis.

  Fields left `nil` inherit, and `nil` is meaningful here, so it is never defaulted in the schema:
  `scan_depth` falls back to the owning book and then `Mythweaver.Lore.Settings`; `case_sensitive`
  and `match_whole_words` fall back straight to `Mythweaver.Lore.Settings` (books carry no match flags).

  An entry belongs to books (`BookEntry`) rather than to one, and may also sit in pools (`PoolEntry`)
  for mutually exclusive variants. An entry may belong to no book at all; it is then "unlinked" and
  never activates. Its order is per book, on the membership (`BookEntry.order`).

  `:outlet`'s value list must stay in literal lockstep with `Mythweaver.Lore.Settings.outlets/0`.
  `Ecto.Enum` needs a compile-time literal, so only a test enforces the coupling.
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Accounts.User
  alias Mythweaver.Lore.BookEntry
  alias Mythweaver.Lore.EntryCharacter
  alias Mythweaver.Lore.EntryFilterTag
  alias Mythweaver.Lore.Matcher
  alias Mythweaver.Lore.PoolEntry
  alias Mythweaver.Lore.Settings
  alias Mythweaver.Templates

  schema "lore_entries" do
    # Set on a catalog mirror row (`Mythweaver.Catalog`): its listing and the live row it copies.
    # Never cast.
    field :frozen_listing_id, Ecto.UUID
    field :mirror_of_id, Ecto.UUID

    field :name, :string
    field :content, :string, default: ""
    field :activation, Ecto.Enum, values: [:keyword, :constant, :vector], default: :keyword
    field :keywords, {:array, :string}, default: []
    field :secondary_keywords, {:array, :string}, default: []

    field :secondary_logic, Ecto.Enum,
      values: [:and_any, :and_all, :not_any, :not_all],
      default: :and_any

    field :case_sensitive, :boolean
    field :match_whole_words, :boolean
    field :scan_depth, :integer

    field :outlet, Ecto.Enum,
      values: [:character, :examples, :author_note, :at_depth, :custom],
      default: :character

    field :placement, Ecto.Enum, values: [:before, :after], default: :before

    # The `Prompts.Outlet` *key*, not its id: an outlet may be deleted and recreated under the same key
    # without orphaning lore rows, and renaming its friendly name never touches them.
    field :custom_outlet, :string

    field :depth, :integer
    field :probability, :integer, default: 100
    field :sticky, :integer
    field :cooldown, :integer
    field :delay, :integer
    field :exclude_recursion, :boolean, default: false
    field :prevent_recursion, :boolean, default: false
    field :character_filter_mode, Ecto.Enum, values: [:off, :include, :exclude], default: :off
    field :ignore_budget, :boolean, default: false
    field :role, Ecto.Enum, values: [:system, :user, :assistant], default: :system
    field :trigger_only, :boolean, default: false
    field :delay_until_recursion, :integer, default: 0
    # Keys an import couldn't map, kept so an export can write them back. Never rendered.
    field :foreign, :map, default: %{}

    # nil: a site entry. Set by `Mythweaver.Lore` from `Mythweaver.Ownership`; never cast.
    belongs_to :user, User

    has_many :book_entries, BookEntry, foreign_key: :lore_entry_id
    has_many :books, through: [:book_entries, :book]
    has_many :pool_entries, PoolEntry, foreign_key: :lore_entry_id
    has_many :pools, through: [:pool_entries, :pool]
    has_many :entry_characters, EntryCharacter, foreign_key: :lore_entry_id
    has_many :filter_characters, through: [:entry_characters, :character]
    has_many :entry_filter_tags, EntryFilterTag, foreign_key: :lore_entry_id
    has_many :filter_tags, through: [:entry_filter_tags, :tag]

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :name,
      :content,
      :activation,
      :keywords,
      :secondary_keywords,
      :secondary_logic,
      :case_sensitive,
      :match_whole_words,
      :scan_depth,
      :outlet,
      :placement,
      :custom_outlet,
      :depth,
      :probability,
      :sticky,
      :cooldown,
      :delay,
      :exclude_recursion,
      :prevent_recursion,
      :character_filter_mode,
      :ignore_budget,
      :role,
      :trigger_only,
      :delay_until_recursion
    ])
    |> put_blank_content()
    |> validate_required([:name, :outlet, :placement])
    |> validate_number(:delay_until_recursion, greater_than_or_equal_to: 0)
    |> validate_number(:probability, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:scan_depth,
      greater_than: 0,
      message: dgettext_noop("errors", "must be 1 or more (leave blank to inherit)")
    )
    |> validate_custom_outlet()
    |> update_change(:keywords, &normalize_keywords/1)
    |> update_change(:secondary_keywords, &normalize_keywords/1)
    |> validate_keywords_present()
    |> validate_regex_keywords(:keywords)
    |> validate_regex_keywords(:secondary_keywords)
    |> Templates.validate(:content)
  end

  @doc "`changeset/2` plus `foreign`, which only an import writes (a map with string keys)."
  def import_changeset(entry, attrs) do
    entry
    |> changeset(attrs)
    |> cast(attrs, [:foreign])
    |> validate_foreign()
  end

  defp validate_foreign(changeset) do
    validate_change(changeset, :foreign, fn _field, value ->
      if is_map(value) and Enum.all?(value, fn {key, _} -> is_binary(key) end),
        do: [],
        else: [foreign: dgettext_noop("errors", "is invalid")]
    end)
  end

  @doc """
  The injection slot this entry resolves to: outlet and placement flattened to one string, e.g.
  `"after_author_note"`. `at_depth` ignores `placement`: the depth number is the position, so
  there is no before/after axis for it.

  A `:custom` entry's slot is `"custom:<key>"`; like `:at_depth` it ignores `placement`, because a custom
  outlet is a single named insertion point with no before/after axis. The `"custom:"` prefix keeps the
  namespace separate, so an outlet keyed `character` can never collide with the `before_character` family.
  """
  def slot(%__MODULE__{} = entry) do
    outlet = entry.outlet || Settings.default_outlet()

    case outlet do
      :at_depth -> "at_depth"
      :custom -> "custom:#{entry.custom_outlet}"
      _ -> "#{entry.placement || Settings.default_placement()}_#{outlet}"
    end
  end

  @doc "Trims, drops blanks and dedupes a keyword list; anything else passes through."
  def normalize_keywords(list) when is_list(list) do
    list
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def normalize_keywords(other), do: other

  defp validate_keywords_present(changeset) do
    keywords = get_field(changeset, :keywords) || []

    if get_field(changeset, :activation) == :keyword and keywords == [] do
      add_error(changeset, :keywords, dgettext_noop("errors", "keyword entries need at least one keyword"))
    else
      changeset
    end
  end

  # A custom entry with no outlet name would resolve to nothing and be silently inert, so it is a
  # validation error rather than a runtime shrug. Non-custom entries may carry a stale name: `slot/1`
  # ignores it, and clearing it would discard the user's choice if they switch the outlet back.
  defp validate_custom_outlet(changeset) do
    if get_field(changeset, :outlet) == :custom and blank?(get_field(changeset, :custom_outlet)) do
      add_error(changeset, :custom_outlet, dgettext_noop("errors", "a custom outlet entry needs an outlet"))
    else
      changeset
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""

  # The column is non-null, and Ecto casts "" to nil: an empty entry (a trigger, or one only its
  # keys matter for) stores "".
  defp put_blank_content(changeset) do
    if is_nil(get_field(changeset, :content)), do: put_change(changeset, :content, ""), else: changeset
  end

  defp validate_regex_keywords(changeset, field) do
    changeset
    |> get_field(field)
    |> List.wrap()
    |> Enum.reject(&Templates.template?/1)
    |> Enum.reduce(changeset, fn keyword, acc ->
      case Matcher.parse_regex(keyword) do
        {:error, _reason} ->
          add_error(acc, field, dgettext_noop("errors", "is not a valid regex: %{keyword}"), keyword: keyword)

        _regex_or_literal ->
          acc
      end
    end)
  end
end
