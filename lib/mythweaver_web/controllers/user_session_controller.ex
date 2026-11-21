defmodule MythweaverWeb.UserSessionController do
  @moduledoc """
  The HTTP side of the LiveView auth forms: they validate live, then trigger a plain POST here so the
  session cookie can be written.
  """
  use MythweaverWeb, :controller

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.Throttle
  alias Mythweaver.Format
  alias Mythweaver.Moderation.Fingerprints
  alias Mythweaver.Moderation.Sanctions
  alias MythweaverWeb.ClientIp
  alias MythweaverWeb.Signals
  alias MythweaverWeb.UserAuth

  def create(conn, %{"user" => %{"email" => email, "password" => password} = user_params} = params) do
    info = if params["_action"] == "registered", do: message(:registered), else: message(:welcome_back)
    email_key = {:login_email, email |> String.trim() |> String.downcase()}
    ip_keys = ip_keys(ClientIp.from_conn(conn))

    # The attempt counts before the password check (`Throttle.attempt/1`), so parallel guesses
    # can't all pass. A success forgives the email and takes back its count on the shared IP.
    with :ok <- Throttle.attempt([email_key | ip_keys]),
         %{} = user <- Accounts.get_user_by_email_and_password(email, password) do
      Throttle.clear(email_key)
      Throttle.release(ip_keys)
      signals = Signals.from_conn(conn, user_params["fingerprint"])
      :ok = Fingerprints.record(user.id, signals)

      case Sanctions.active_ban(user, signals) do
        nil ->
          conn
          |> put_flash(:info, info)
          |> UserAuth.log_in_user(user, user_params)

        ban ->
          conn
          |> put_flash(:error, Sanctions.refusal_message(ban))
          |> redirect(to: ~p"/users/log-in")
      end
    else
      {:error, {:throttled, seconds}} ->
        conn
        |> put_flash(:error, throttled(Throttle.wait(seconds)))
        |> put_flash(:email, String.slice(email, 0, 160))
        |> redirect(to: ~p"/users/log-in")

      nil ->
        # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
        conn
        |> put_flash(:error, message(:invalid_credentials))
        |> put_flash(:email, String.slice(email, 0, 160))
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # Loopback means an untrusted local proxy, where every client would share one IP key.
  defp ip_keys(ip) when is_nil(ip) or ip == "::1", do: []
  defp ip_keys(ip), do: if(String.starts_with?(ip, "127."), do: [], else: [{:login_ip, ip}])

  defp throttled({:seconds, seconds}) do
    gettext_comment("Flash on the sign-in page after too many wrong passwords; the wait is under a minute.")

    dngettext(
      "accounts",
      "Too many sign-in attempts. Try again in %{wait_seconds} second.",
      "Too many sign-in attempts. Try again in %{wait_seconds} seconds.",
      seconds,
      wait_seconds: Format.number(seconds)
    )
  end

  defp throttled({:minutes, minutes}) do
    gettext_comment("Flash on the sign-in page after too many wrong passwords; the wait is rounded up to minutes.")

    dngettext(
      "accounts",
      "Too many sign-in attempts. Try again in %{wait_minutes} minute.",
      "Too many sign-in attempts. Try again in %{wait_minutes} minutes.",
      minutes,
      wait_minutes: Format.number(minutes)
    )
  end

  defp message(:registered) do
    gettext_comment("Flash after signing up, as the new account is signed in.")
    dpgettext("accounts", "status: a new account was just created", "Account created")
  end

  defp message(:welcome_back) do
    gettext_comment("Flash after signing in.")
    dpgettext("accounts", "status: greeting after signing in", "Welcome back!")
  end

  defp message(:invalid_credentials) do
    gettext_comment("Flash on the sign-in page when the email or password is wrong; it never says which.")
    dpgettext("accounts", "status: sign-in refused, email or password wrong", "Invalid email or password")
  end

  defp message(:password_updated) do
    gettext_comment("Flash after changing the account password.")
    dpgettext("accounts", "status: the account password was changed", "Password updated")
  end

  defp message(:password_not_updated) do
    gettext_comment("Flash when changing the account password fails.")
    dpgettext("accounts", "status: the account password change failed", "Could not update password")
  end

  defp message(:logged_out) do
    gettext_comment("Flash after signing out.")
    dpgettext("accounts", "status: signed out", "Logged out")
  end

  # A passwordless user sets a first password, so `current_password` may be absent.
  def update_password(conn, %{"user" => user_params}) do
    user = conn.assigns.current_scope.user

    case Accounts.update_user_password(user, user_params["current_password"], user_params) do
      {:ok, {user, expired_tokens}} ->
        # Disconnect all existing LiveViews with old sessions.
        UserAuth.disconnect_sessions(expired_tokens)

        conn
        |> put_session(:user_return_to, ~p"/users/settings")
        |> put_flash(:info, message(:password_updated))
        |> UserAuth.log_in_user(user, user_params)

      {:error, _changeset} ->
        conn
        |> put_flash(:error, message(:password_not_updated))
        |> redirect(to: ~p"/users/settings")
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, message(:logged_out))
    |> UserAuth.log_out_user()
  end
end
