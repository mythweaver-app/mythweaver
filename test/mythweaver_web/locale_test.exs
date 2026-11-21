defmodule MythweaverWeb.LocaleTest do
  use MythweaverWeb.ConnCase

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Repo
  alias Mythweaver.Settings

  defp html_attr(conn, name) do
    conn |> html_response(200) |> LazyHTML.from_document() |> LazyHTML.query("html") |> LazyHTML.attribute(name)
  end

  # With no account at all, `/users/log-in` sends to `/setup`.
  defp with_an_account(_context) do
    register_user!()
    :ok
  end

  setup :with_an_account

  test "a visitor gets the browser's language and regional format", %{conn: conn} do
    conn = conn |> put_req_header("accept-language", "de-DE,de;q=0.9") |> get(~p"/users/log-in")

    assert [format] = html_attr(conn, "data-locale")
    assert String.starts_with?(format, "de")
    assert html_attr(conn, "lang") == ["de"]
    assert get_session(conn, "locale") =~ ~r/^de/
    assert get_session(conn, "language") == "de"
  end

  test "a browser language without a catalog keeps its regional format but English text", %{conn: conn} do
    conn = conn |> put_req_header("accept-language", "fr-FR") |> get(~p"/users/log-in")

    assert [format] = html_attr(conn, "data-locale")
    assert String.starts_with?(format, "fr")
    assert html_attr(conn, "lang") == ["en"]
  end

  test "with no Accept-Language, the built-in defaults", %{conn: conn} do
    conn = get(conn, ~p"/users/log-in")

    assert html_attr(conn, "lang") == ["en"]
    assert [format] = html_attr(conn, "data-locale")
    assert String.starts_with?(format, "en")
  end

  test "a user's regional format setting beats the browser, which is still recorded", %{conn: conn} do
    user = register_user!()
    :ok = Settings.put(Scope.for_user(user), :user, "appearance.locale", "fr")

    conn =
      conn
      |> log_in_user(user)
      |> put_req_header("accept-language", "de-DE,de;q=0.9")
      |> get(~p"/settings")

    assert [format] = html_attr(conn, "data-locale")
    assert String.starts_with?(format, "fr")
    assert Repo.reload!(user).browser_locale =~ ~r/^de/
  end
end
