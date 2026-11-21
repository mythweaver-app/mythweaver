defmodule MythweaverWeb.ModerationGate do
  @moduledoc """
  The `live_session :app` hook after authentication. On every connected mount it records the
  socket's fingerprint signals (`MythweaverWeb.Signals`, `Mythweaver.Moderation.Fingerprints`) and
  logs the session out when its account, device, browser fingerprint or IP address is banned
  (`Mythweaver.Moderation.Sanctions.active_ban/2`). Every mount sends an account with an
  unacknowledged warning to `/warnings` (`MythweaverWeb.WarningLive`) until it acknowledges.
  """

  use Phoenix.VerifiedRoutes, endpoint: MythweaverWeb.Endpoint, router: MythweaverWeb.Router

  import Phoenix.LiveView

  alias Mythweaver.Accounts
  alias Mythweaver.Moderation.Fingerprints
  alias Mythweaver.Moderation.Sanctions
  alias MythweaverWeb.Signals

  def on_mount(:default, _params, session, socket) do
    user = socket.assigns.current_scope.user

    with :cont <- check_ban(socket, user, session),
         :cont <- check_warnings(socket, user) do
      {:cont, socket}
    end
  end

  defp check_ban(socket, user, session) do
    if connected?(socket) do
      signals = Signals.from_socket(socket, session)
      :ok = Fingerprints.record(user.id, signals)

      case Sanctions.active_ban(user, signals) do
        nil ->
          :cont

        ban ->
          if token = session["user_token"], do: Accounts.delete_user_session_token(token)
          if id = session["live_socket_id"], do: MythweaverWeb.Endpoint.broadcast(id, "disconnect", %{})

          {:halt, socket |> put_flash(:error, Sanctions.refusal_message(ban)) |> redirect(to: ~p"/users/log-in")}
      end
    else
      :cont
    end
  end

  defp check_warnings(%{view: MythweaverWeb.WarningLive}, _user), do: :cont

  defp check_warnings(socket, user) do
    if Sanctions.pending_warnings?(user.id), do: {:halt, redirect(socket, to: ~p"/warnings")}, else: :cont
  end
end
