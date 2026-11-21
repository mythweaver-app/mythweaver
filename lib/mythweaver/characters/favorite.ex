defmodule Mythweaver.Characters.Favorite do
  @moduledoc """
  One user's starred character: `Mythweaver.Characters`' list functions put a user's favorites
  first. Rows are built only inside `Mythweaver.Characters` (`set_favorite/3`), so there is no
  changeset.
  """

  use Mythweaver.Schema

  alias Mythweaver.Accounts.User
  alias Mythweaver.Characters.Character

  @type t :: %__MODULE__{}

  schema "character_favorites" do
    belongs_to :user, User
    belongs_to :character, Character

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
