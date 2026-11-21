defmodule MythweaverWeb.ModerationCallbackController do
  @moduledoc """
  Where a callback-mode webhook moderation rule posts its verdict
  (`POST /moderation/callback/:token`, JSON `{"action": "approve" | "flag" | "reject", "reason": …}`).
  The signed token (`Mythweaver.Moderation.Scanner.callback_url/2`) is the only credential: no
  session, no CSRF. It is valid for a week; the scan's own deadline enforces the rule's shorter
  timeout.
  """
  use MythweaverWeb, :controller

  alias Mythweaver.Moderation.Scanner

  @max_age 7 * 24 * 3600

  def create(conn, %{"token" => token} = params) do
    result =
      case Phoenix.Token.verify(MythweaverWeb.Endpoint, "moderation callback", token, max_age: @max_age) do
        {:ok, %{"scan" => scan_id, "rule" => rule_id}} ->
          Scanner.callback(scan_id, rule_id, Map.delete(params, "token"))

        _bad_or_expired ->
          {:error, :not_found}
      end

    case result do
      :ok -> send_resp(conn, 204, "")
      {:error, :invalid} -> conn |> put_status(422) |> json(%{error: "action must be approve, flag or reject"})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "unknown or expired scan"})
    end
  end
end
