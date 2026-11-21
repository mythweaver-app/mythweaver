defmodule Mythweaver.Catalog.Listing do
  @moduledoc """
  A root item published to the catalog (`Mythweaver.Catalog`). `item_type`/`item_id` name the live
  root its owner keeps editing; `mirror_id` the frozen copy of its closure subscribers reach, updated
  by each release. `visibility` is every subscription share's. `hidden_at`/`hidden_by_id` record a
  takedown. `current_release_id` is the latest `Mythweaver.Catalog.Release`; `subscriber_count`
  is shown instead of who subscribed.
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Accounts.User
  alias Mythweaver.Catalog.Release

  @type t :: %__MODULE__{}

  schema "catalog_listings" do
    field :item_type, Ecto.Enum,
      values: [
        :character,
        :lore_book,
        :prompt,
        :block,
        :outlet,
        :script,
        :memory_profile,
        :side_prompt,
        :side_prompt_set
      ]

    field :item_id, Ecto.UUID
    field :mirror_id, Ecto.UUID
    field :title, :string
    field :summary, :string
    field :tags, {:array, :string}, default: []
    field :visibility, Ecto.Enum, values: [:readable, :runtime_only], default: :runtime_only
    field :featured, :boolean, default: false
    field :published_at, :utc_datetime
    field :hidden_at, :utc_datetime
    field :subscriber_count, :integer, default: 0

    belongs_to :owner, User
    belongs_to :hidden_by, User
    belongs_to :current_release, Release
    has_many :releases, Release, foreign_key: :listing_id, preload_order: [desc: :version]

    timestamps(type: :utc_datetime)
  end

  @doc "A changeset for what the publisher describes: title, summary, tags and visibility."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(listing, attrs) do
    listing
    |> cast(attrs, [:title, :summary, :tags, :visibility])
    |> update_change(:tags, &normalize_tags/1)
    |> validate_required([:title, :visibility])
    |> validate_length(:title, max: 120)
    |> validate_length(:summary, max: 5000)
    |> unique_constraint([:item_type, :item_id], message: dgettext_noop("errors", "is already published"))
  end

  defp normalize_tags(tags),
    do: tags |> Enum.map(&(&1 |> String.trim() |> String.downcase())) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
end
