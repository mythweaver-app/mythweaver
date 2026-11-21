defmodule MythweaverWeb.BanGate do
  @moduledoc """
  Logs a signed-in browser out when its account, device, browser fingerprint or IP address is banned
  (`Mythweaver.Moderation.Sanctions.active_ban/2`), with the reason as the flash. Runs in the
  `:browser` pipeline after `fetch_current_scope_for_user`; `MythweaverWeb.ModerationGate` does the
  same for LiveView mounts.
  """

  @behaviour Plug

  import Phoenix.Controller, only: [put_flash: 3]
  import Plug.Conn

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Moderation.Sanctions
  alias MythweaverWeb.Signals
  alias MythweaverWeb.UserAuth

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{assigns: %{current_scope: %Scope{user: %{} = user}}} = conn, _opts) do
    case Sanctions.active_ban(user, Signals.from_conn(conn, nil)) do
      nil -> conn
      ban -> conn |> put_flash(:error, Sanctions.refusal_message(ban)) |> UserAuth.log_out_user() |> halt()
    end
  end

  def call(conn, _opts), do: conn
end
