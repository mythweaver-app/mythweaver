defmodule MythweaverWeb.StylesheetController do
  @moduledoc """
  Serves the custom stylesheets (`Mythweaver.Stylesheets`) the root layout `@import`s:
  `/styles/site.css` and `/styles/user.css`, the latter the signed-in viewer's own (`""` signed
  out). The restriction on user sheets is applied here, at serve time, so a sheet saved while it was
  off stops being served once it is back on.

  The root layout links each sheet at `?v=<version>` (`Mythweaver.Stylesheets.versions/1`), a hash of
  the settings behind it, so a request carrying the current version can be cached forever
  (`immutable`): any change gives a new URL. Any other `v` revalidates every time. The response
  depends on the session, so it is `private`: no shared cache may keep it. `nosniff` keeps the
  browser from reading it as anything but CSS.
  """

  use MythweaverWeb, :controller

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Stylesheets

  def site(conn, params) do
    scope = scope(conn)
    send_css(conn, Stylesheets.site(scope), Stylesheets.versions(scope).site, params["v"])
  end

  def user(conn, params) do
    scope = scope(conn)
    send_css(conn, Stylesheets.user(scope), Stylesheets.versions(scope).user, params["v"])
  end

  defp scope(conn), do: conn.assigns.current_scope || %Scope{}

  defp send_css(conn, css, version, requested) do
    cache_control =
      if version != nil and requested == version,
        do: "private, max-age=31536000, immutable",
        else: "private, no-cache"

    conn
    |> put_resp_content_type("text/css")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("cache-control", cache_control)
    |> send_resp(200, css)
  end
end
