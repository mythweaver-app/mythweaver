defmodule MythweaverWeb.ContentSecurityPolicy do
  @moduledoc """
  The `content-security-policy` of every `:browser` page, replacing `put_secure_browser_headers`'s
  default. Scripts are the app's own; the per-request nonce (`conn.assigns.csp_nonce`) is for
  LiveDashboard's inline scripts only. Styles allow `'unsafe-inline'` because CodeMirror's
  style-mod, the interestfor polyfill, KaTeX, blurhash and HEEx `style=` attributes write inline
  styles; `style-src` never carries a nonce, since one makes browsers ignore `'unsafe-inline'`.
  Style and font origins follow the custom-CSS settings: any `https:` while
  `appearance.restrict_user_css` is off, else the font providers' (`Webfonts.csp_sources/0`) while
  `appearance.allow_third_party_fonts` is on, plus `appearance.extra_sources` (also images). Markdown's
  remote images come through `/remote-images/` (`MythweaverWeb.RemoteImage`), so images and media
  take any `https:` host only while `appearance.remote_images` is `:direct`; images also do while
  user CSS is unrestricted, for its `url()` images. Otherwise `Mythweaver.Stylesheets.Policy` stops
  CSS `url()` exfiltration. `data:` images are
  blurhash's placeholders, `blob:` images and media `live_img_preview`'s; `connect-src` adds the
  attachment origins for direct S3 uploads (`Attachments.browser_origins/0`), and `frame-src
  'self'` is the dev live-reload iframe. With dev routes on, `font-src` also takes `data:` for
  LiveDashboard's inlined fonts (its `dist/css/app.css`). An open tab keeps the policy it loaded
  with until a reload: LiveView navigation sends no new headers.
  """

  @behaviour Plug

  import Plug.Conn

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Attachments
  alias Mythweaver.Settings
  alias Mythweaver.Stylesheets.Webfonts

  @dev_fonts if Application.compile_env(:mythweaver, :dev_routes), do: ["data:"], else: []

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    nonce = 16 |> :crypto.strong_rand_bytes() |> Base.encode64()

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", policy(conn.assigns[:current_scope] || %Scope{}, nonce))
  end

  defp policy(scope, nonce) do
    settings =
      Settings.get_many(scope, [
        "appearance.restrict_user_css",
        "appearance.allow_third_party_fonts",
        "appearance.extra_sources",
        "appearance.remote_images"
      ])

    extra = settings["appearance.extra_sources"]

    {style, font} =
      cond do
        not settings["appearance.restrict_user_css"] -> {["https:"], ["https:"]}
        settings["appearance.allow_third_party_fonts"] -> fonts(Webfonts.csp_sources())
        true -> {[], []}
      end

    attachments = Attachments.browser_origins()
    direct? = settings["appearance.remote_images"] == :direct
    remote_img = if direct? or not settings["appearance.restrict_user_css"], do: ["https:"], else: []
    remote_media = if direct?, do: ["https:"], else: []

    [
      {"default-src", ["'self'"]},
      {"script-src", ["'self'", "'nonce-#{nonce}'"]},
      {"style-src", ["'self'", "'unsafe-inline'" | style] ++ extra},
      {"font-src", ["'self'" | @dev_fonts] ++ font ++ extra},
      {"img-src", ["'self'", "data:", "blob:" | remote_img] ++ attachments ++ extra},
      {"media-src", ["'self'", "blob:" | remote_media] ++ attachments},
      {"connect-src", ["'self'" | attachments]},
      {"frame-src", ["'self'"]},
      {"worker-src", ["'self'"]},
      {"object-src", ["'none'"]},
      {"base-uri", ["'self'"]},
      {"form-action", ["'self'"]},
      {"frame-ancestors", ["'self'"]}
    ]
    |> Enum.map_join("; ", fn {directive, sources} -> Enum.join([directive | Enum.uniq(sources)], " ") end)
  end

  defp fonts(%{style: style, font: font}), do: {style, font}
end
