defmodule Mythweaver.Accounts.UserToken do
  @moduledoc """
  A login session token. Session tokens live in a signed cookie, so they are stored unhashed; keeping
  them in the database lets a session be expired (logout, password change, account deletion).
  """
  use Mythweaver.Schema

  import Ecto.Query

  alias Mythweaver.Accounts.User
  alias Mythweaver.Accounts.UserToken

  @rand_size 32
  @session_validity_in_days 14

  @type t :: %__MODULE__{}

  schema "users_tokens" do
    field :token, :binary
    field :context, Ecto.Enum, values: [:session]
    # Until when this session may make sensitive changes without re-entering the password.
    field :sudo_until, :utc_datetime
    belongs_to :user, User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Builds a random session token and its unsaved row."
  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    {token, %UserToken{token: token, context: :session, user_id: user.id}}
  end

  @doc """
  The lookup query for a session token: selects `{user, token.inserted_at, token.id,
  token.sudo_until}` when the token exists and is younger than #{@session_validity_in_days} days.
  """
  def verify_session_token_query(token) do
    query =
      from token in by_token_and_context_query(token, :session),
        join: user in assoc(token, :user),
        where: token.inserted_at > ago(@session_validity_in_days, "day"),
        select: {user, token.inserted_at, token.id, token.sudo_until}

    {:ok, query}
  end

  @doc "Tokens matching `token` in `context`."
  def by_token_and_context_query(token, context) do
    from UserToken, where: [token: ^token, context: ^context]
  end
end
