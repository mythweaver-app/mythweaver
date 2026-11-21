defmodule Mythweaver.Lore.LoreBook do
  @moduledoc """
  A named collection of lore entries, and the scope and budget rules that apply to all of them.

  Scope is either `global: true` (every chat) or explicit bindings through `BookChat` and
  `BookCharacter`. A book has no on/off switch of its own: switch it off by clearing `global` and
  unbinding it, or disabling its bindings.

  `token_budget` and `scan_depth` are nullable on purpose: `nil` inherits from
  `Mythweaver.Lore.Settings` rather than meaning "unlimited", and `order_adjustment` shifts every
  membership's `order` so a whole book can be nudged relative to others without editing entries.
  `priority`, then `order_adjustment`, is the primary sort key when the same entry is reachable
  through several books; `Mythweaver.Lore.Activation` keeps the highest-priority membership.
  `recursive: false` means entries in this book cannot be activated by another entry's content (the
  recursion passes).

  `site_visibility` is what users without `site.hidden.view` may see of a site book: everything
  (`:readable`); book and entry names but never content (`:runtime_only`); or nothing (`:hidden`).
  `forced` makes the book active in every chat and delivered in every reply, whatever the prompt or
  user lore settings. Both are site-book controls only. Holders of `site.hidden.view`
  (`Mythweaver.Sharing.Visibility.view_hidden?/1`) always see everything.

  A book does not own its entries exclusively (`BookEntry` is a join), and deleting a book leaves
  the entries it held alone unlinked rather than deleting them.

  `rules` (`BookRule`) are a gate on top of that scope, never a source of it: a book with at least
  one enabled rule activates only where it is already live (global, forced or bound) and at least
  one enabled rule matches. A rule matches when all its conditions hold
  (`Mythweaver.Lore.Rules`). `changeset/2` never touches rules; `rules_changeset/3` edits them.
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Accounts.User
  alias Mythweaver.Lore.BookCharacter
  alias Mythweaver.Lore.BookChat
  alias Mythweaver.Lore.BookEntry
  alias Mythweaver.Lore.BookFilterTag
  alias Mythweaver.Lore.BookRule

  schema "lore_books" do
    field :name, :string
    field :description, :string
    field :global, :boolean, default: false
    field :priority, :integer, default: 3
    field :order_adjustment, :integer, default: 0
    field :token_budget, :integer
    field :scan_depth, :integer
    field :recursive, :boolean, default: true
    field :site_visibility, Ecto.Enum, values: [:readable, :runtime_only, :hidden], default: :readable
    field :forced, :boolean, default: false
    field :tag_filter_mode, Ecto.Enum, values: [:off, :include, :exclude], default: :off
    # `:card`: the book an imported character card's fields live in. Its entries render first in
    # their slot and are never charged to the lore budget (`Mythweaver.Lore.Activation`).
    field :kind, Ecto.Enum, values: [:lore, :card], default: :lore
    # Keys an import couldn't map, kept so an export can write them back. Never rendered.
    field :foreign, :map, default: %{}

    # nil: a site book. Set by `Mythweaver.Lore` from `Mythweaver.Ownership`; never cast.
    belongs_to :user, User
    # What `Mythweaver.Sharing.Clone` copied this from (no FK: the source may go). Never cast.
    field :cloned_from_type, Ecto.Enum,
      values: [
        :character,
        :lore_book,
        :prompt,
        :block,
        :outlet,
        :script,
        :memory_profile,
        :side_prompt,
        :side_prompt_set,
        :ai_model
      ]

    field :cloned_from_id, Ecto.UUID
    # The catalog release a clone from a listing was made of (`Mythweaver.Catalog`).
    field :cloned_from_release_id, Ecto.UUID
    # Set on a catalog mirror row (`Mythweaver.Catalog`): its listing and the live row it copies.
    # Never cast.
    field :frozen_listing_id, Ecto.UUID
    field :mirror_of_id, Ecto.UUID

    has_many :book_entries, BookEntry, foreign_key: :lore_book_id
    has_many :entries, through: [:book_entries, :entry]
    has_many :book_chats, BookChat, foreign_key: :lore_book_id
    has_many :book_characters, BookCharacter, foreign_key: :lore_book_id
    has_many :book_filter_tags, BookFilterTag, foreign_key: :lore_book_id
    has_many :filter_tags, through: [:book_filter_tags, :tag]

    has_many :rules, BookRule,
      foreign_key: :lore_book_id,
      on_replace: :delete,
      preload_order: [asc: :position, asc: :id]

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(book, attrs) do
    book
    |> cast(attrs, [
      :name,
      :description,
      :global,
      :priority,
      :order_adjustment,
      :token_budget,
      :scan_depth,
      :recursive,
      :site_visibility,
      :forced,
      :tag_filter_mode
    ])
    |> validate_required([:name])
    |> validate_inclusion(:priority, 1..5)
    |> validate_number(:order_adjustment,
      greater_than_or_equal_to: -10_000,
      less_than_or_equal_to: 10_000
    )
    |> validate_number(:token_budget, greater_than: 0)
    |> validate_number(:scan_depth,
      greater_than: 0,
      message: dgettext_noop("errors", "must be 1 or more (leave blank to inherit)")
    )
    |> validate_site_only()
    |> unique_constraint(:name, name: :lore_books_user_id_name_index)
  end

  @doc """
  `changeset/2` plus the fields only an import writes: `kind` and `foreign` (a map with string
  keys).
  """
  def import_changeset(book, attrs) do
    book
    |> changeset(attrs)
    |> cast(attrs, [:kind, :foreign])
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
  Replaces the book's activation rules from nested `rules` params. `refs` lists the chats and
  characters a condition may name (`BookRuleCondition.changeset/4`).
  """
  def rules_changeset(book, attrs, refs) do
    book
    |> cast(attrs, [])
    |> cast_assoc(:rules,
      with: &BookRule.changeset(&1, &2, &3, refs),
      sort_param: :rules_sort,
      drop_param: :rules_drop
    )
  end

  # Visibility and forcing are site-book controls: a personal book is only ever its owner's.
  defp validate_site_only(changeset) do
    personal? = get_field(changeset, :user_id) != nil

    changeset
    |> refuse(
      personal? and get_field(changeset, :site_visibility) != :readable,
      :site_visibility,
      dgettext_noop("errors", "only site books can be hidden from users")
    )
    |> refuse(
      personal? and get_field(changeset, :forced),
      :forced,
      dgettext_noop("errors", "only site books can be forced")
    )
  end

  defp refuse(changeset, true, field, message), do: add_error(changeset, field, message)
  defp refuse(changeset, _, _field, _message), do: changeset
end
