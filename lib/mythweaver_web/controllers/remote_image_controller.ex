defmodule MythweaverWeb.RemoteImageController do
  @moduledoc """
  Serves the remote images markdown links to (`MythweaverWeb.RemoteImage`) at
  `/remote-images/<token>`. The token is the credential; there is no session and no `Set-Cookie`.

  `appearance.remote_images` decides: `:off` is a 404, `:direct` redirects to the image's own site,
  and `:proxy` serves `MythweaverWeb.RemoteImage.fetch/2`'s image (guarded, capped, cached, and only
  PNG, JPEG, GIF, WebP or AVIF). A proxy with every fetch slot busy answers 503; anything else that
  fails is a plain 404.
  """

  use MythweaverWeb, :controller

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Settings
  alias MythweaverWeb.RemoteImage

  def show(conn, %{"token" => token}) do
    case RemoteImage.open(token) do
      {:ok, url, expires_at} ->
        case Settings.get(%Scope{}, "appearance.remote_images") do
          :direct ->
            conn
            |> put_resp_header("cache-control", "private, max-age=3600")
            |> redirect(external: url)

          :proxy ->
            proxy(conn, url, expires_at)

          _off ->
            not_found(conn)
        end

      :error ->
        not_found(conn)
    end
  end

  defp proxy(conn, url, expires_at) do
    case RemoteImage.fetch(url, expires_at) do
      {:ok, type, body} ->
        conn
        |> put_resp_content_type(type, nil)
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("content-security-policy", "default-src 'none'")
        |> put_resp_header("cache-control", "private, max-age=86400")
        |> put_resp_header("content-disposition", "inline")
        |> send_resp(200, body)

      :busy ->
        conn
        |> put_resp_header("retry-after", "5")
        |> send_resp(503, "Service Unavailable")

      :error ->
        not_found(conn)
    end
  end

  defp not_found(conn), do: send_resp(conn, 404, "Not Found")
end
