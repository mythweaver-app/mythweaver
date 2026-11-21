defmodule Mythweaver.Sharing.OptOut do
  @moduledoc """
  A site root item one user no longer uses: `Mythweaver.Ownership` leaves it out of what the user
  may use and of what their chats resolve (`Mythweaver.Sharing.opt_out/2`). Forced lore books take
  none. Rows are built only inside `Mythweaver.Sharing`, so there is no changeset.
  """

  use Mythweaver.Schema

  import Ecto.Query

  alias Mythweaver.Accounts.User
  alias Mythweaver.Sharing.Items

  @type t :: %__MODULE__{}

  schema "site_opt_outs" do
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

    belongs_to :user, User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "The ids of the `type` site items `user_id` opted out of, as a query."
  @spec ids(Ecto.UUID.t(), Items.root_type()) :: Ecto.Query.t()
  def ids(user_id, type),
    do: from(o in __MODULE__, where: o.user_id == ^user_id and o.item_type == ^type, select: o.item_id)
end
