defmodule Mythweaver.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Mythweaver.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Repo

  using do
    quote do
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Mythweaver.DataCase

      alias Mythweaver.Repo
    end
  end

  setup tags do
    Mythweaver.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  @doc """
  Registers a fresh user (merged with `attrs`) and returns its scope, in sudo mode (`sudo/1`). `role:`
  (default `:admin`): `:owner` registers an owner, `:admin` a user in the Administrators group,
  `:user` a plain user.
  """
  def scope!(attrs \\ %{}) do
    {role, attrs} = Map.pop(attrs, :role, :admin)
    n = System.unique_integer([:positive])

    {:ok, user} =
      Mythweaver.Accounts.register_user(
        Map.merge(
          %{
            email: "user#{n}@example.com",
            handle: "u_" <> String.downcase(Integer.to_string(n, 36)),
            password: "a long test password"
          },
          attrs
        ),
        if(role == :owner, do: :owner, else: :user)
      )

    if role == :admin, do: Mythweaver.Permissions.add_member!(:administrators, user)
    sudo(Scope.for_user(user))
  end

  @doc "`scope` in sudo mode for the next hour (`Mythweaver.Accounts.sudo?/1`)."
  def sudo(scope), do: %{scope | sudo_until: DateTime.add(DateTime.utc_now(:second), 1, :hour)}
end
