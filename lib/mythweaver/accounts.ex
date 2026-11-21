defmodule Mythweaver.Accounts do
  @moduledoc """
  User accounts and login sessions.

  Every account has a role (`User.role/0`): an owner may do anything and manage any account; a user
  holds what its groups and own grants give it (`Mythweaver.Permissions`). A `"users.manage"` holder
  manages every account but owners (it cannot create, edit, reset or delete an owner, nor grant
  `:owner`); a plain user plays in its own chats, edits its own settings and keeps its own content
  when its permissions allow (`Mythweaver.Ownership`).
  Nobody changes their own role, so the last owner can never be demoted or deleted. With
  `:auto_login` on (`MYTHWEAVER_AUTO_LOGIN`, default on in dev), an install with at most one account
  logs that account in without a password, creating a passwordless owner when there is none
  (`auto_login_user/0`).
  """

  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Query, warn: false

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.Throttle
  alias Mythweaver.Accounts.User
  alias Mythweaver.Accounts.UserToken
  alias Mythweaver.AI.Model
  alias Mythweaver.AI.Provider
  alias Mythweaver.Changes
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Repo

  ## Users

  @spec list_users() :: [User.t()]
  def list_users, do: Repo.all(from(u in User, order_by: [asc: u.handle]))

  @doc "A user by id; `nil` for an unknown or malformed id."
  @spec get_user(String.t()) :: User.t() | nil
  def get_user(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get(User, id)
      :error -> nil
    end
  end

  @doc "The user with `handle` (trimmed, a leading `@` dropped, any case), or nil."
  @spec get_user_by_handle(term()) :: User.t() | nil
  def get_user_by_handle(handle) when is_binary(handle), do: Repo.get_by(User, handle: User.normalize_handle(handle))
  def get_user_by_handle(_handle), do: nil

  @doc "The user with `email` (any case: the column is citext), or nil."
  @spec get_user_by_email(String.t()) :: User.t() | nil
  def get_user_by_email(email) when is_binary(email), do: Repo.get_by(User, email: String.trim(email))

  @spec any_users?() :: boolean()
  def any_users?, do: Repo.exists?(User)

  @doc "The user with `email` (case-insensitive) when `password` matches, else nil."
  @spec get_user_by_email_and_password(String.t(), String.t()) :: User.t() | nil
  def get_user_by_email_and_password(email, password) when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  def change_user_registration(%User{} = user, attrs \\ %{}, opts \\ []),
    do: User.registration_changeset(user, attrs, opts)

  def change_user_profile(%User{} = user, attrs \\ %{}, opts \\ []), do: User.profile_changeset(user, attrs, opts)

  def change_user_password(%User{} = user, attrs \\ %{}, opts \\ []), do: User.password_changeset(user, attrs, opts)

  @doc "Creates an account with `role`, without an actor check (first-user setup, tests)."
  @spec register_user(map(), User.role()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def register_user(attrs, role \\ :user) do
    %User{}
    |> User.registration_changeset(attrs)
    |> User.role_changeset(role)
    |> Repo.insert()
  end

  @doc "Roles `scope` may grant: an owner any, a `\"users.manage\"` holder `:user`, anyone else none."
  @spec assignable_roles(Scope.t()) :: [User.role()]
  def assignable_roles(%Scope{} = scope) do
    cond do
      Scope.owner?(scope) -> [:owner, :user]
      Scope.can?(scope, "users.manage") -> [:user]
      true -> []
    end
  end

  @doc "Whether `scope` may edit, reset, re-role or delete `user`: owners anyone, `\"users.manage\"` holders any non-owner."
  @spec can_manage?(Scope.t(), User.t()) :: boolean()
  def can_manage?(%Scope{} = scope, %User{role: role}),
    do: Scope.owner?(scope) or (Scope.can?(scope, "users.manage") and role != :owner)

  @doc """
  Creates an account from the Users page. `attrs` is string-keyed, as the form sends it; `"role"`
  defaults to `"user"` and must be one of `assignable_roles/1`.
  """
  @spec create_user(Scope.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def create_user(%Scope{} = scope, attrs) do
    changeset =
      %User{}
      |> User.registration_changeset(attrs)
      |> User.role_changeset(Map.get(attrs, "role", "user"))

    if Ecto.Changeset.get_field(changeset, :role) in assignable_roles(scope) do
      with {:ok, user} <- Repo.insert(changeset), do: Changes.notify({:ok, user}, :accounts, [nil, user.id])
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Creates the first account (`/setup`). Refuses once any account exists; the table lock makes two
  concurrent setups serialize, so only one wins.
  """
  @spec register_first_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t() | :already_set_up}
  def register_first_user(attrs) do
    Repo.transact(fn ->
      lock_users!()

      if any_users?() do
        {:error, :already_set_up}
      else
        with {:ok, user} <- register_user(attrs, :owner) do
          :ok = Chats.adopt_unowned(user)
          {:ok, user}
        end
      end
    end)
  end

  @doc "Whether login is bypassed on installs with at most one account."
  @spec auto_login_enabled?() :: boolean()
  def auto_login_enabled?, do: Application.get_env(:mythweaver, :auto_login, false)

  @doc """
  The user auto-login signs in, or nil.

  Nil unless auto-login is enabled and there is at most one account. With no accounts it creates the
  passwordless admin (`User.auto_login_changeset/0`) under a table lock, so concurrent first requests
  cannot create two admins (which would turn auto-login off for good).
  """
  @spec auto_login_user() :: User.t() | nil
  def auto_login_user do
    if auto_login_enabled?() do
      case first_two_users() do
        [user] -> user
        [_, _] -> nil
        [] -> create_auto_login_user()
      end
    end
  end

  defp create_auto_login_user do
    {:ok, user} =
      Repo.transact(fn ->
        lock_users!()

        case first_two_users() do
          [] ->
            with {:ok, user} <- Repo.insert(User.auto_login_changeset()) do
              :ok = Chats.adopt_unowned(user)
              {:ok, user}
            end

          [user] ->
            {:ok, user}

          [_, _] ->
            {:ok, nil}
        end
      end)

    user
  end

  defp first_two_users, do: Repo.all(from(u in User, limit: 2))

  defp lock_users!, do: Repo.query!("LOCK TABLE users IN SHARE ROW EXCLUSIVE MODE")

  @doc "Whether the login page may offer to continue without logging in."
  @spec auto_login_available?() :: boolean()
  def auto_login_available?, do: auto_login_enabled?() and Repo.aggregate(User, :count) <= 1

  @doc """
  Self-service profile update. Changing the email requires the current password (a passwordless
  user has none to give).
  """
  @spec update_user_profile(User.t(), String.t() | nil, map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_user_profile(%User{} = user, current_password, attrs) do
    changeset = User.profile_changeset(user, attrs)

    changeset =
      if Ecto.Changeset.get_change(changeset, :email),
        do: validate_current_password(changeset, current_password),
        else: changeset

    changeset |> Repo.update() |> Changes.notify(:accounts, [nil, user.id])
  end

  @doc """
  Checks `password` as the current password of the changeset's user (`changeset.data`), throttled
  per user (`Mythweaver.Accounts.Throttle`): too many wrong tries add a "tried too often" error
  without checking.
  """
  @spec validate_current_password(Ecto.Changeset.t(), String.t() | nil) :: Ecto.Changeset.t()
  def validate_current_password(%Ecto.Changeset{data: %User{} = user} = changeset, password) do
    key = {:password, user.id}

    case Throttle.attempt(key) do
      {:error, {:throttled, seconds}} ->
        add_throttled_error(changeset, Throttle.wait(seconds))

      :ok ->
        changeset = User.validate_current_password(changeset, password)

        # A wrong password stays counted; anything else forgives the key.
        if is_nil(user.hashed_password) or not Keyword.has_key?(changeset.errors, :current_password),
          do: Throttle.clear(key)

        changeset
    end
  end

  defp add_throttled_error(changeset, {:seconds, seconds}) do
    Ecto.Changeset.add_error(
      changeset,
      :current_password,
      dgettext_noop("errors", "has been tried too often, try again in %{count} seconds"),
      count: seconds
    )
  end

  defp add_throttled_error(changeset, {:minutes, minutes}) do
    Ecto.Changeset.add_error(
      changeset,
      :current_password,
      dgettext_noop("errors", "has been tried too often, try again in %{count} minutes"),
      count: minutes
    )
  end

  @doc """
  Users-page profile update of `user`, without a password check. A `"role"` in `attrs` re-roles it;
  nobody may change their own role, only roles in `assignable_roles/1` may be granted, and a role
  change needs sudo mode (`sudo?/1`).
  """
  @spec update_user(Scope.t(), User.t(), map()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t() | :unauthorized | :own_role | :sudo_required}
  def update_user(%Scope{} = scope, %User{} = user, attrs) do
    with_locked_user(user, fn user ->
      changeset = User.profile_changeset(user, attrs)
      changeset = if attrs["role"], do: User.role_changeset(changeset, attrs["role"]), else: changeset
      new_role = Ecto.Changeset.get_change(changeset, :role)

      cond do
        not can_manage?(scope, user) -> {:error, :unauthorized}
        new_role && self?(scope, user) -> {:error, :own_role}
        new_role && new_role not in assignable_roles(scope) -> {:error, :unauthorized}
        new_role && not sudo?(scope) -> {:error, :sudo_required}
        true -> Repo.update(changeset)
      end
    end)
    |> Changes.notify(:accounts, [nil, user.id])
  end

  @doc """
  Self-service password change; expires every session of the user and returns the expired tokens so
  the caller can disconnect their sockets.
  """
  @spec update_user_password(User.t(), String.t() | nil, map()) ::
          {:ok, {User.t(), [UserToken.t()]}} | {:error, Ecto.Changeset.t()}
  def update_user_password(%User{} = user, current_password, attrs) do
    user
    |> User.password_changeset(attrs)
    |> validate_current_password(current_password)
    |> update_user_and_delete_all_tokens()
  end

  @doc "Users-page password reset of another user (in sudo mode); expires that user's sessions like `update_user_password/3`."
  @spec reset_user_password(Scope.t(), User.t(), map()) ::
          {:ok, {User.t(), [UserToken.t()]}} | {:error, Ecto.Changeset.t() | :unauthorized | :self | :sudo_required}
  def reset_user_password(%Scope{} = scope, %User{} = user, attrs) do
    with_other_managed_user(scope, user, fn user ->
      user
      |> User.password_changeset(attrs)
      |> update_user_and_delete_all_tokens()
    end)
  end

  @doc """
  Deletes another user (in sudo mode), with everything they own: each of their items with accepted
  editors goes to its oldest editor first (`Mythweaver.Sharing.hand_off_owned_by/1`), then the shares
  of the rest end (`Mythweaver.Sharing.revoke_owned_by/2`), then their chats go (which hold their
  personal characters as participants) and their AI connections and models, then the user, whose
  other personal content cascades. Returns its session tokens for disconnecting.
  """
  @spec delete_user(Scope.t(), User.t()) ::
          {:ok, {User.t(), [UserToken.t()]}} | {:error, Ecto.Changeset.t() | :unauthorized | :self | :sudo_required}
  def delete_user(%Scope{} = scope, %User{} = user) do
    with_other_managed_user(scope, user, fn user ->
      :ok = Mythweaver.Sharing.hand_off_owned_by(user)
      :ok = Mythweaver.Sharing.revoke_owned_by(user.id, :account_deleted)
      tokens = session_tokens(user)
      Repo.delete_all(from(c in Chat, where: c.user_id == ^user.id))
      # Before the user: a job or stat row of theirs on their own model would otherwise be updated
      # twice in the one cascade (`user_id` and `ai_model_id` both nilified), which Postgres refuses.
      Repo.delete_all(from(m in Model, where: m.user_id == ^user.id))
      Repo.delete_all(from(p in Provider, where: p.user_id == ^user.id))

      with {:ok, user} <- Repo.delete(user) do
        {:ok, {user, tokens}}
      end
    end)
    |> Changes.notify(:accounts, [nil, user.id])
  end

  @doc "The user's session tokens, for `MythweaverWeb.UserAuth.disconnect_sessions/1` after a role change."
  @spec session_tokens(User.t()) :: [UserToken.t()]
  def session_tokens(%User{id: id}), do: Repo.all_by(UserToken, user_id: id)

  @doc """
  Records the locale `user`'s browser last asked for (`Mythweaver.Locale.id/1`), so text built for
  them outside a request (`Mythweaver.Locale.for_user/1`) can follow it. A no-op when unchanged.
  """
  @spec put_browser_locale(User.t(), String.t()) :: :ok
  def put_browser_locale(%User{browser_locale: id}, id), do: :ok

  def put_browser_locale(%User{id: user_id}, id) when is_binary(id) do
    _ = Repo.update_all(from(u in User, where: u.id == ^user_id), set: [browser_locale: id])
    :ok
  end

  defp self?(%Scope{user: %User{id: id}}, %User{id: id}), do: true
  defp self?(_, _), do: false

  # Runs `fun` on a fresh `FOR UPDATE` copy of the target, so role checks see its current role rather
  # than a page's stale struct. A target deleted meanwhile is `:unauthorized`.
  defp with_locked_user(%User{id: id}, fun) do
    Repo.transact(fn ->
      case Repo.one(from(u in User, where: u.id == ^id, lock: "FOR UPDATE")) do
        nil -> {:error, :unauthorized}
        user -> fun.(user)
      end
    end)
  end

  # `with_locked_user/2` for a user `scope` manages other than itself, in sudo mode.
  defp with_other_managed_user(scope, user, fun) do
    with_locked_user(user, fn user ->
      cond do
        not can_manage?(scope, user) -> {:error, :unauthorized}
        self?(scope, user) -> {:error, :self}
        not sudo?(scope) -> {:error, :sudo_required}
        true -> fun.(user)
      end
    end)
  end

  ## Session

  @doc "Generates and stores a session token."
  @spec generate_user_session_token(User.t()) :: binary()
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc "`{user, token_inserted_at, token_id, sudo_until}` for a valid session token, else nil."
  @spec get_user_by_session_token(binary()) :: {User.t(), DateTime.t(), Ecto.UUID.t(), DateTime.t() | nil} | nil
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @sudo_minutes 15

  @doc """
  Confirms the scope's user by `password` and lets its session make sensitive changes for
  #{@sudo_minutes} minutes (`sudo?/1`). Returns the scope carrying the new `sudo_until`. Wrong
  passwords are throttled per user (`Mythweaver.Accounts.Throttle`).
  """
  @spec enter_sudo(Scope.t(), String.t()) ::
          {:ok, Scope.t()} | {:error, :no_password | :invalid_password | {:throttled, pos_integer()}}
  def enter_sudo(%Scope{user: %User{} = user} = scope, password) when is_binary(password) do
    key = {:password, user.id}

    cond do
      is_nil(user.hashed_password) ->
        {:error, :no_password}

      match?({:error, _}, throttled = Throttle.attempt(key)) ->
        throttled

      # The attempt stays counted.
      not User.valid_password?(user, password) ->
        {:error, :invalid_password}

      true ->
        Throttle.clear(key)
        until = DateTime.utc_now() |> DateTime.add(@sudo_minutes, :minute) |> DateTime.truncate(:second)

        if scope.session_token_id,
          do: Repo.update_all(from(t in UserToken, where: t.id == ^scope.session_token_id), set: [sudo_until: until])

        {:ok, %{scope | sudo_until: until}}
    end
  end

  @doc """
  Whether `scope` may make sensitive changes now: within #{@sudo_minutes} minutes of `enter_sudo/2`,
  or always on a single-user auto-login install (which has no password to ask for).
  """
  @spec sudo?(Scope.t()) :: boolean()
  def sudo?(%Scope{} = scope) do
    (match?(%DateTime{}, scope.sudo_until) and DateTime.after?(scope.sudo_until, DateTime.utc_now())) or
      auto_login_available?()
  end

  @doc "`:ok` when `sudo?/1`, else `{:error, :sudo_required}`."
  @spec authorize_sudo(Scope.t()) :: :ok | {:error, :sudo_required}
  def authorize_sudo(%Scope{} = scope), do: if(sudo?(scope), do: :ok, else: {:error, :sudo_required})

  @doc "Deletes a session token."
  @spec delete_user_session_token(binary()) :: :ok
  def delete_user_session_token(token) do
    Repo.delete_all(UserToken.by_token_and_context_query(token, :session))
    :ok
  end

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = session_tokens(user)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
