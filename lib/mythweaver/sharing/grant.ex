defmodule Mythweaver.Sharing.Grant do
  @moduledoc """
  What an accepted share lets its user reach: one row per item of the share's closure
  (`Mythweaver.Sharing.Closure`), with `access` `:edit` (the item and its parts) or `:use` (what it
  references; everything, for a subscriber share), and the share's `visibility` (`:readable` for
  editors). `Mythweaver.Ownership` joins these, so runtime resolution stays one indexed lookup.
  Kept equal to the closure by `Closure.rebuild/1`; deleted with its share.
  """

  use Mythweaver.Schema

  alias Mythweaver.Accounts.User
  alias Mythweaver.Sharing.Share

  @type t :: %__MODULE__{}

  schema "access_grants" do
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
        :side_prompt_set,
        :lore_entry,
        :lore_pool,
        :expression_profile,
        :ai_model
      ]

    field :item_id, Ecto.UUID
    field :access, Ecto.Enum, values: [:edit, :use]
    field :visibility, Ecto.Enum, values: [:readable, :runtime_only], default: :readable

    belongs_to :share, Share
    belongs_to :user, User
    belongs_to :owner, User

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
