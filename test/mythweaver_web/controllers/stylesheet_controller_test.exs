defmodule MythweaverWeb.StylesheetControllerTest do
  use MythweaverWeb.ConnCase, async: true

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Settings
  alias Mythweaver.Stylesheets

  setup %{conn: conn} do
    user = register_user!(%{role: :user})
    admin = register_user!()
    %{conn: log_in_user(conn, user), scope: Scope.for_user(user), admin_scope: Scope.for_user(admin)}
  end

  test "serves the viewer's sheet verbatim as CSS", %{conn: conn, scope: scope} do
    css = "a { color: red } /* </style> */\n"
    assert :ok = Settings.put(scope, :user, "appearance.user_css", css)

    conn = get(conn, ~p"/styles/user.css")

    assert response(conn, 200) == css
    assert get_resp_header(conn, "content-type") == ["text/css; charset=utf-8"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  test "only the current version is cached forever", %{conn: conn, scope: scope} do
    assert :ok = Settings.put(scope, :user, "appearance.user_css", "a { color: red }")
    version = Stylesheets.versions(scope).user

    current = get(conn, ~p"/styles/user.css?#{[v: version]}")
    assert get_resp_header(current, "cache-control") == ["private, max-age=31536000, immutable"]

    stale = get(conn, ~p"/styles/user.css?v=stale")
    assert get_resp_header(stale, "cache-control") == ["private, no-cache"]
  end

  test "signed out, the user sheet is empty and the site sheet is served", %{admin_scope: admin} do
    assert :ok = Settings.put(admin, :site, "appearance.site_css", "body { font-style: italic }")

    assert build_conn() |> get(~p"/styles/user.css") |> response(200) == ""
    assert build_conn() |> get(~p"/styles/site.css") |> response(200) == "body { font-style: italic }"
  end
end
