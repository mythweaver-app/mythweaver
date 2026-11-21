defmodule MythweaverWeb.ContentSecurityPolicyTest do
  use MythweaverWeb.ConnCase, async: true

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Settings

  setup do
    %{admin: Scope.for_user(register_user!())}
  end

  # The signed-out login page's policy, as `%{directive => sources}`.
  defp policy do
    [header] = build_conn() |> get(~p"/users/log-in") |> get_resp_header("content-security-policy")

    Map.new(String.split(header, "; "), fn directive ->
      [name | sources] = String.split(directive, " ")
      {name, sources}
    end)
  end

  test "by default: own scripts with a fresh nonce, Google Fonts styles and fonts, no remote images" do
    policy = policy()

    assert policy["style-src"] == ["'self'", "'unsafe-inline'", "https://fonts.googleapis.com"]
    assert policy["font-src"] == ["'self'", "https://fonts.gstatic.com"]
    assert ["'self'", "'nonce-" <> nonce] = policy["script-src"]
    assert policy["img-src"] == ["'self'", "data:", "blob:"]
    refute "https:" in policy["media-src"]
    assert policy["object-src"] == ["'none'"]
    assert policy["frame-ancestors"] == ["'self'"]

    assert ["'self'", "'nonce-" <> other] = policy()["script-src"]
    refute other == nonce
  end

  test "third-party fonts off: no font service", %{admin: admin} do
    assert :ok = Settings.put(admin, :site, "appearance.allow_third_party_fonts", false)
    policy = policy()

    assert policy["style-src"] == ["'self'", "'unsafe-inline'"]
    assert policy["font-src"] == ["'self'"]
  end

  test "unrestricted user sheets: styles and fonts from any https host", %{admin: admin} do
    assert :ok = Settings.put(admin, :site, "appearance.restrict_user_css", false)
    policy = policy()

    assert policy["style-src"] == ["'self'", "'unsafe-inline'", "https:"]
    assert policy["font-src"] == ["'self'", "https:"]
    assert "https:" in policy["img-src"]
    refute "https:" in policy["media-src"]
  end

  test "direct remote images: images and media from any https host", %{admin: admin} do
    assert :ok = Settings.put(admin, :site, "appearance.remote_images", :direct)
    policy = policy()

    assert "https:" in policy["img-src"]
    assert "https:" in policy["media-src"]
  end

  test "extra sources join styles, fonts and images", %{admin: admin} do
    assert :ok = Settings.put(admin, :site, "appearance.extra_sources", "https://use.typekit.net")
    policy = policy()

    assert "https://use.typekit.net" in policy["style-src"]
    assert "https://use.typekit.net" in policy["font-src"]
    assert "https://use.typekit.net" in policy["img-src"]
    refute "https://use.typekit.net" in policy["connect-src"]
  end
end
