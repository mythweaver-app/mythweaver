defmodule Mythweaver.Permissions.Member do
  @moduledoc "A user's membership in a `Mythweaver.Permissions.Group` (never the Everyone group)."
  use Mythweaver.Schema

  alias Mythweaver.Accounts.User
  alias Mythweaver.Permissions.Group

  @type t :: %__MODULE__{}

  schema "permission_group_members" do
    belongs_to :group, Group
    belongs_to :user, User

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
