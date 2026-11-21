defmodule Mythweaver.StylesheetsTest do
  use Mythweaver.DataCase, async: true

  alias Mythweaver.Settings
  alias Mythweaver.Stylesheets
  alias Mythweaver.Stylesheets.Policy

  describe "Policy.check/1" do
    test "passes CSS that loads nothing, wherever url-like text sits" do
      for css <- [
            "a { color: red }",
            ~s|a::after { content: "url(x)" }|,
            "/* url(x) */ a {}",
            "@media (width < 600px) { a { color: red } }",
            # a dimension with unit `url`, then a bare paren block
            "a { width: 1url(x) }",
            # a hash token
            "a { --x: #url(x) }",
            "@font-face { font-family: X; src: local(Arial) }",
            "@-webkit-keyframes x { from { opacity: 0 } }"
          ] do
        assert Policy.check(css) == :ok, css
      end
    end

    test "refuses url() in every spelling the browser reads as one" do
      for css <- [
            "a { background: url(x) }",
            ~s|a { background: url( "x" ) }|,
            "a { background: URL(x) }",
            "a { background: \\75 rl(x) }",
            "a { background: u\\rl(x) }",
            # a bad-url token: still a fetch attempt
            "a { background: url(x y) }",
            "a { --x: url(x) }"
          ] do
        assert Policy.check(css) == {:error, "url()"}, css
      end
    end

    test "refuses the other file-loading functions and at-rules, naming the first" do
      for {css, construct} <- [
            {~s|a { background: image-set("a.png" 1x) }|, "image-set()"},
            {~s|a { background: -webkit-image-set("a.png" 1x) }|, "-webkit-image-set()"},
            {~s|a { background: src("a.png") }|, "src()"},
            {~s|a { background: image("a.png") }|, "image()"},
            {~s|a { background: cross-fade("a.png", "b.png") }|, "cross-fade()"},
            {~s|@import "x";|, "@import"},
            {~s|@IMPORT "x";|, "@import"},
            {~s|@\\69mport "x";|, "@import"},
            {~s|@namespace svg "http://www.w3.org/2000/svg";|, "@namespace"},
            {~s|@charset "utf-8";|, "@charset"},
            {~s|a { b: image("x") } @import "y";|, "image()"}
          ] do
        assert Policy.check(css) == {:error, construct}, css
      end
    end
  end

  describe "Policy.check/2 with webfonts" do
    test "passes an @import of a Google Fonts stylesheet, which the strict check refuses" do
      for css <- [
            ~s|@import url("https://fonts.googleapis.com/css2?family=Inter:wght@400;700&display=swap");|,
            "@import url(https://fonts.googleapis.com/css?family=Lato);",
            "@import 'https://fonts.googleapis.com/css2?family=Inter' layer(fonts);",
            ~s|@IMPORT url( "HTTPS://Fonts.GoogleAPIs.com/css2?family=X" ) screen;|
          ] do
        assert Policy.check(css, webfonts: true) == :ok, css
        assert Policy.check(css) == {:error, "@import"}, css
      end
    end

    test "refuses an @import of anything but an exact provider stylesheet URL" do
      for url <- [
            "https://evil.example/css2?family=X",
            "http://fonts.googleapis.com/css2?family=X",
            "//fonts.googleapis.com/css2?family=X",
            "https://fonts.googleapis.com.evil.example/css2",
            "https://user@fonts.googleapis.com/css2",
            "https://fonts.googleapis.com:8443/css2",
            "https://fonts.googleapis.com/css2/../x",
            "https://fonts.googleapis.com/icon"
          ] do
        css = ~s|@import url("#{url}");|
        assert Policy.check(css, webfonts: true) == {:error, "@import"}, css
      end

      assert Policy.check(~s|@import url("https://fonts.googleapis.com/css2"|, webfonts: true) ==
               {:error, "@import"}
    end

    test "still refuses url() after a permitted import and outside @import" do
      for css <- [
            ~s|@import url("https://fonts.googleapis.com/css2") supports(background: url(x));|,
            ~s|a { background: url("https://fonts.googleapis.com/css2") }|
          ] do
        assert Policy.check(css, webfonts: true) == {:error, "url()"}, css
      end
    end
  end

  describe "serving" do
    test "a sheet saved unrestricted is not served once the restriction is back on" do
      admin = scope!()
      user = scope!(%{role: :user})
      css = "a { background: url(x) }"

      assert :ok = Settings.put(admin, :site, "appearance.restrict_user_css", false)
      assert :ok = Settings.put(user, :user, "appearance.user_css", css)
      assert Stylesheets.user(user) == css
      unrestricted = Stylesheets.versions(user).user

      assert :ok = Settings.put(admin, :site, "appearance.restrict_user_css", true)
      assert Stylesheets.user(user) == ""
      assert Stylesheets.blocked?(Settings.get(user, "appearance.user_css"), Stylesheets.restriction(user))
      refute Stylesheets.versions(user).user in [nil, unrestricted]
    end

    test "a font import is served only while the site allows third-party fonts" do
      admin = scope!()
      user = scope!(%{role: :user})
      css = ~s|@import url("https://fonts.googleapis.com/css2?family=Inter"); body { font-family: Inter }|

      assert :ok = Settings.put(user, :user, "appearance.user_css", css)
      assert Stylesheets.user(user) == css
      allowed = Stylesheets.versions(user).user

      assert :ok = Settings.put(admin, :site, "appearance.allow_third_party_fonts", false)
      assert Stylesheets.user(user) == ""
      assert Stylesheets.blocked?(css, Stylesheets.restriction(user))
      refute Stylesheets.versions(user).user in [nil, allowed]
    end

    test "an unset sheet has no version" do
      assert Stylesheets.versions(scope!(%{role: :user})) == %{site: nil, user: nil}
    end
  end
end
