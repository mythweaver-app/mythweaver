defmodule MythweaverWeb.Locale do
  @moduledoc """
  The viewer's language and regional format for a request and its LiveViews
  (`Mythweaver.Locale.resolve/2`).

  As a plug in the `:browser` pipeline (after `:fetch_current_scope_for_user`, so the user's
  `appearance.language` and `appearance.locale` count) it reads `Accept-Language`
  (`Mythweaver.Locale.from_accept_language/1`), sets the request process's locale, keeps both in
  the session (`"language"`, `"locale"`) and records the browser's regional match on the user
  (`Mythweaver.Accounts.put_browser_locale/2`). As the first `on_mount` hook of every
  `live_session` it sets the LiveView process's locale from those session values, so a change
  takes a page reload (`MythweaverWeb.SettingsLive` redirects).
  """
  @behaviour Plug

  import Plug.Conn

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.Scope

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    browser = conn |> get_req_header("accept-language") |> List.first() |> Mythweaver.Locale.from_accept_language()
    scope = conn.assigns[:current_scope]
    locale = Mythweaver.Locale.resolve(scope, browser)
    :ok = Mythweaver.Locale.put(locale)

    with %Scope{user: %Accounts.User{} = user} <- scope, %Localize.LanguageTag{} = format <- browser.format do
      Accounts.put_browser_locale(user, Mythweaver.Locale.id(format))
    end

    conn
    |> put_session("language", locale.language)
    |> put_session("locale", Mythweaver.Locale.id(locale.format))
  end

  def on_mount(:default, _params, session, socket) do
    locale =
      with id when is_binary(id) <- session["locale"],
           {:ok, format} <- Localize.validate_locale(id),
           language when is_binary(language) <- session["language"],
           true <- language in Gettext.known_locales(Mythweaver.Gettext) do
        %Mythweaver.Locale{language: language, format: format}
      else
        _ -> Mythweaver.Locale.resolve(nil, Mythweaver.Locale.from_accept_language(nil))
      end

    :ok = Mythweaver.Locale.put(locale)
    {:cont, socket}
  end
end
