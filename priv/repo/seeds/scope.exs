# The scope seeds act as. Required by every seed file (`Code.require_file/2` loads it once).
defmodule Mythweaver.Seeds do
  import Ecto.Query

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.Repo

  @doc """
  An admin scope: the oldest account's, or a placeholder user's before any account exists. Seed
  writes are global config, which needs an admin; seeds start no jobs, so no user id is recorded.

  The placeholder has an id no row carries: queries filter by the scope's user id, and comparing
  with `nil` is an error, so it reads as an admin who owns nothing.
  """
  def scope do
    Scope.for_user(Repo.one(from(u in User, order_by: [asc: u.inserted_at, asc: u.id], limit: 1))) ||
      %Scope{user: %User{id: Mythweaver.Schema.generate_id(), role: :owner}}
  end
end
