defmodule Mythweaver.Sharing.Share do
  @moduledoc """
  One item shared with one other account. `owner_id` is the item's owner when it was shared (a share
  goes before its item changes owner or is deleted), `user_id` the account it is shared with,
  `invited_by_id` who sent the invite. `status` moves `:pending` → `:accepted` or `:declined`; a
  declined share may be invited again. An `:editor` edits the item and its parts, never deletes it; a
  `:subscriber` only uses them. `visibility` (subscribers only; ignored for editors) is `:readable`
  (may inspect the protected content) or `:runtime_only` (the model gets it, the user never sees it).
  An AI model share's `ai_mode` (nil for other types) is `:own_key` (the user's runs use their own
  connections, linked to the model with `Mythweaver.AI.link_model/4`) or `:owner_key` (they use the
  owner's, at most `token_limit_per_day` tokens a day when set).

  `item_id` has no foreign key (shares span several item tables); `Mythweaver.Sharing` keeps it
  consistent. Rows are built only inside `Mythweaver.Sharing` from trusted values, so there is no
  changeset.
  """

  use Mythweaver.Schema

  alias Mythweaver.Accounts.User

  @type t :: %__MODULE__{}

  schema "shares" do
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
        :ai_model
      ]

    field :item_id, Ecto.UUID
    field :role, Ecto.Enum, values: [:editor, :subscriber], default: :editor
    field :visibility, Ecto.Enum, values: [:readable, :runtime_only], default: :runtime_only
    field :status, Ecto.Enum, values: [:pending, :accepted, :declined], default: :pending
    field :accepted_at, :utc_datetime
    field :ai_mode, Ecto.Enum, values: [:own_key, :owner_key]
    field :token_limit_per_day, :integer
    # A catalog subscription (`Mythweaver.Catalog`): the listing whose mirror this share reaches.
    field :catalog_listing_id, Ecto.UUID

    belongs_to :owner, User
    belongs_to :user, User
    belongs_to :invited_by, User

    timestamps(type: :utc_datetime)
  end
end
