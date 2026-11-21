defmodule MythweaverWeb.UserAuth do
  @moduledoc """
  Session authentication, after `phx.gen.auth`: database session tokens in the session cookie, an
  optional remember-me cookie, and `current_scope` on the conn and socket.

  `require_authenticated_user/2` resolves a request in order: a valid session, then auto-login
  (`Mythweaver.Accounts.auto_login_user/0`), then `/setup` when no account exists, then the login
  page.
  """
  use MythweaverWeb, :verified_routes
  use Gettext, backend: Mythweaver.Gettext

  import Phoenix.Controller
  import Plug.Conn

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.Scope

  # Make the remember me cookie valid for 14 days. This should match the session validity setting in
  # `Mythweaver.Accounts.UserToken`.
  @max_cookie_age_in_days 14
  @remember_me_cookie "_mythweaver_user_remember_me"
  @remember_me_options [
    sign: true,
    max_age: @max_cookie_age_in_days * 24 * 60 * 60,
    same_site: "Lax",
    secure: Application.compile_env(:mythweaver, :secure_cookies, false)
  ]

  # How old the session token should be before a new one is issued. When a request is made with a
  # session token older than this value, then a new session token will be created and the session
  # and remember-me cookies (if set) will be updated with the new token.
  @session_reissue_age_in_days 7

  @doc """
  Logs the user in.

  Redirects to the session's `:user_return_to` path or falls back to the `signed_in_path/1`.
  """
  def log_in_user(conn, user, params \\ %{}) do
    user_return_to = get_session(conn, :user_return_to)

    conn
    |> create_or_extend_session(user, params)
    |> delete_session(:user_return_to)
    |> redirect(to: user_return_to || signed_in_path(conn))
  end

  @doc """
  Logs the user out.

  It clears all session data for safety. See renew_session. Lands on the login page, not `/`, which
  auto-login would sign straight back into.
  """
  def log_out_user(conn) do
    user_token = get_session(conn, :user_token)
    user_token && Accounts.delete_user_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      MythweaverWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session(nil)
    |> delete_resp_cookie(@remember_me_cookie, @remember_me_options)
    |> redirect(to: ~p"/users/log-in")
  end

  @doc """
  Authenticates the user by looking into the session and remember me token.

  Will reissue the session token if it is older than the configured age.
  """
  def fetch_current_scope_for_user(conn, _opts) do
    with {token, conn} <- ensure_user_token(conn),
         {user, token_inserted_at, token_id, sudo_until} <- Accounts.get_user_by_session_token(token) do
      conn
      |> assign(:current_scope, Scope.for_user(user, session_token_id: token_id, sudo_until: sudo_until))
      |> maybe_reissue_user_session_token(user, token_inserted_at)
    else
      nil -> assign(conn, :current_scope, Scope.for_user(nil))
    end
  end

  @doc """
  Plug for routes that require a user: passes a logged-in request, logs in the auto-login user, sends
  an install with no accounts to `/setup`, and everything else to the login page.
  """
  def require_authenticated_user(conn, _opts) do
    cond do
      conn.assigns.current_scope && conn.assigns.current_scope.user ->
        conn

      user = Accounts.auto_login_user() ->
        conn
        |> create_or_extend_session(user, %{})
        |> assign(:current_scope, Scope.for_user(user))

      not Accounts.any_users?() ->
        conn
        |> redirect(to: ~p"/setup")
        |> halt()

      true ->
        conn
        |> put_flash(:error, log_in_message())
        |> maybe_store_return_to()
        |> redirect(to: ~p"/users/log-in")
        |> halt()
    end
  end

  defp ensure_user_token(conn) do
    if token = get_session(conn, :user_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])

      if token = conn.cookies[@remember_me_cookie] do
        {token, conn |> put_token_in_session(token) |> put_session(:user_remember_me, true)}
      end
    end
  end

  # Reissue the session token if it is older than the configured reissue age.
  defp maybe_reissue_user_session_token(conn, user, token_inserted_at) do
    token_age = DateTime.diff(DateTime.utc_now(:second), token_inserted_at, :day)

    if token_age >= @session_reissue_age_in_days do
      create_or_extend_session(conn, user, %{})
    else
      conn
    end
  end

  # Creates a session token and stores it in the session and, when asked, the remember-me cookie.
  # When the session is created, rather than extended, `renew_session/2` clears the session to avoid
  # fixation attacks.
  defp create_or_extend_session(conn, user, params) do
    token = Accounts.generate_user_session_token(user)
    remember_me = get_session(conn, :user_remember_me)

    conn
    |> renew_session(user)
    |> put_token_in_session(token)
    |> maybe_write_remember_me_cookie(token, params, remember_me)
  end

  # Do not renew session if the user is already logged in to prevent CSRF errors or data being lost
  # in tabs that are still open
  defp renew_session(conn, user) when conn.assigns.current_scope.user.id == user.id do
    conn
  end

  # Renews the session ID and erases the whole session to avoid fixation attacks.
  defp renew_session(conn, _user) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}, _),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, token, _params, true), do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, _token, _params, _), do: conn

  defp write_remember_me_cookie(conn, token) do
    conn
    |> put_session(:user_remember_me, true)
    |> put_resp_cookie(@remember_me_cookie, token, @remember_me_options)
  end

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, user_session_topic(token))
  end

  defp maybe_store_return_to(%{method: "GET"} = conn), do: put_session(conn, :user_return_to, current_path(conn))

  defp maybe_store_return_to(conn), do: conn

  @doc """
  Disconnects existing sockets for the given tokens.
  """
  def disconnect_sessions(tokens) do
    Enum.each(tokens, fn %{token: token} ->
      MythweaverWeb.Endpoint.broadcast(user_session_topic(token), "disconnect", %{})
    end)
  end

  @doc "Disconnects every session of `users`, so their next mount rebuilds the scope (e.g. after a permission change)."
  def disconnect_users(users), do: Enum.each(users, &disconnect_sessions(Accounts.session_tokens(&1)))

  defp user_session_topic(token), do: "users_sessions:#{Base.url_encode64(token)}"

  @doc """
  Handles mounting and authenticating the `current_scope` in LiveViews.

  ## `on_mount` arguments

    * `:mount_current_scope` - Assigns `current_scope` from the session's `user_token`, or nil.

    * `:require_authenticated` - Like `:mount_current_scope`, but redirects to the login page when
      there is no logged-in user.

    * `{:require_permission, key}` - Mounted by the admin pages after the `live_session` hooks:
      continues when the scope holds `key` (`Scope.can?/2`) and redirects anyone else to `/` with an
      error flash.

    * `{:require_any_permission, keys}` - Like `{:require_permission, key}`, continuing when the
      scope holds any of `keys` (the moderation panel's pages each serve several permissions).

  Both scope-mounting hooks also assign `safe_mode?`: whether the URL carries `?safe_mode`, which
  leaves the user's own stylesheet out of the page (`MythweaverWeb.Layouts.custom_style_imports/2`).
  """
  def on_mount(:mount_current_scope, params, session, socket) do
    {:cont, socket |> mount_current_scope(session) |> assign_safe_mode(params)}
  end

  def on_mount(:require_authenticated, params, session, socket) do
    socket = socket |> mount_current_scope(session) |> assign_safe_mode(params)

    if socket.assigns.current_scope && socket.assigns.current_scope.user do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, log_in_message())
        |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

      {:halt, socket}
    end
  end

  def on_mount({:require_permission, key}, _params, _session, socket) do
    if Scope.can?(socket.assigns.current_scope, key) do
      {:cont, socket}
    else
      {:halt,
       socket
       |> MythweaverWeb.Flash.flash_unauthorized()
       |> Phoenix.LiveView.redirect(to: ~p"/")}
    end
  end

  def on_mount({:require_any_permission, keys}, _params, _session, socket) do
    if Enum.any?(keys, &Scope.can?(socket.assigns.current_scope, &1)) do
      {:cont, socket}
    else
      {:halt,
       socket
       |> MythweaverWeb.Flash.flash_unauthorized()
       |> Phoenix.LiveView.redirect(to: ~p"/")}
    end
  end

  defp mount_current_scope(socket, session) do
    Phoenix.Component.assign_new(socket, :current_scope, fn ->
      with token when is_binary(token) <- session["user_token"],
           {user, _inserted_at, token_id, sudo_until} <- Accounts.get_user_by_session_token(token) do
        Scope.for_user(user, session_token_id: token_id, sudo_until: sudo_until)
      else
        _ -> nil
      end
    end)
  end

  # `params` is `:not_mounted_at_router` for a nested LiveView.
  defp assign_safe_mode(socket, params),
    do: Phoenix.Component.assign(socket, :safe_mode?, is_map(params) and Map.has_key?(params, "safe_mode"))

  defp log_in_message do
    gettext_comment("Flash on the sign-in page after a signed-out visitor opened a page that needs an account.")
    dgettext("accounts", "You must log in to access this page.")
  end

  @doc "Returns the path to redirect to after log in."
  def signed_in_path(_), do: ~p"/"
end
