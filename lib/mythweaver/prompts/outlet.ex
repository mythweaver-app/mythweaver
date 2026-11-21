defmodule Mythweaver.Prompts.Outlet do
  @moduledoc """
  A user-defined injection point a lore entry can target.

  `key` is the stable id lore rows store (never this row's UUID), so an outlet can be renamed freely,
  and deleted and recreated under the same key, without orphaning lore entries. The user types the key
  for exactly that reason: nothing derives it from the friendly `name`.
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Accounts.User

  schema "prompt_outlets" do
    field :key, :string
    field :name, :string
    field :description, :string

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

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(outlet, attrs) do
    outlet
    |> cast(attrs, [:key, :name, :description])
    |> validate_required([:key, :name])
    |> validate_format(:key, ~r/\A[a-z0-9_]+\z/,
      message: dgettext_noop("errors", "may only contain lowercase letters, numbers, and underscores")
    )
    |> unique_constraint(:key, name: :prompt_outlets_user_id_key_index)
  end
end
