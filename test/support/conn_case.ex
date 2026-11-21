defmodule MythweaverWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use MythweaverWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.UserToken

  using do
    quote do
      use MythweaverWeb, :verified_routes

      import MythweaverWeb.ConnCase
      import Phoenix.ConnTest
      import Plug.Conn
      # The default endpoint for testing
      @endpoint MythweaverWeb.Endpoint

      # Import conveniences for testing with connections
    end
  end

  setup tags do
    Mythweaver.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Registers a user with a password (`\"a long test password\"`) through `Accounts.register_user/2`;
  `role:` (default `:admin`): `:owner`, `:admin` (a user in the Administrators group) or `:user`.
  """
  def register_user!(attrs \\ %{}) do
    {role, attrs} = Map.pop(attrs, :role, :admin)
    n = System.unique_integer([:positive])

    {:ok, user} =
      %{
        email: "user#{n}@example.com",
        handle: "u_" <> String.downcase(Integer.to_string(n, 36)),
        nickname: "Tester",
        password: "a long test password"
      }
      |> Map.merge(attrs)
      |> Accounts.register_user(if(role == :owner, do: :owner, else: :user))

    if role == :admin, do: Mythweaver.Permissions.add_member!(:administrators, user)
    user
  end

  @doc """
  Setup helper that registers and logs in a user.

      setup :register_and_log_in_user

  It stores an updated connection and the registered user in the test context.
  """
  def register_and_log_in_user(%{conn: conn}) do
    user = register_user!()
    %{conn: log_in_user(conn, user), user: user, scope: Mythweaver.DataCase.sudo(Scope.for_user(user))}
  end

  @doc """
  Logs the given `user` into the `conn`. The session is in sudo mode (`Accounts.sudo?/1`) unless
  `sudo: false`, so only tests about the password prompt meet it.
  """
  def log_in_user(conn, user, opts \\ []) do
    token = Accounts.generate_user_session_token(user)

    if Keyword.get(opts, :sudo, true) do
      Mythweaver.Repo.update_all(
        UserToken.by_token_and_context_query(token, :session),
        set: [sudo_until: DateTime.add(DateTime.utc_now(:second), 1, :hour)]
      )
    end

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end
end
