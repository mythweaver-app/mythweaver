defmodule Mythweaver.LocaleTest do
  use Mythweaver.DataCase

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Locale
  alias Mythweaver.Settings

  defp user!(role \\ :user) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(
        %{
          email: "locale#{n}@example.com",
          handle: "loc_" <> String.downcase(Integer.to_string(n, 36)),
          nickname: "Tester",
          password: "a long test password"
        },
        role
      )

    user
  end

  defp tag!(id), do: elem(Localize.validate_locale(id), 1)

  defp format_id(%Locale{format: tag}), do: tag.cldr_locale_id

  defp browser(header), do: Locale.from_accept_language(header)

  describe "from_accept_language/1" do
    test "takes the best regional match, and the first language the app has a catalog for" do
      assert %Locale{language: "de", format: format} = browser("de-DE,de;q=0.9")
      assert format.language == :de

      assert %Locale{language: "es", format: %{language: :fr}} = browser("fr-FR,es;q=0.5")
      assert %Locale{language: nil} = browser("fr-FR")
      assert browser(nil) == %Locale{language: nil, format: nil}
    end
  end

  describe "resolve/2" do
    test "the user's settings beat the browser, each on its own" do
      user = user!()
      :ok = Settings.put(Scope.for_user(user), :user, "appearance.locale", "fr")

      locale = Locale.resolve(Scope.for_user(user), browser("de-DE"))
      assert format_id(locale) == :fr
      assert locale.language == "de"

      :ok = Settings.put(Scope.for_user(user), :user, "appearance.language", "es")
      assert %Locale{language: "es"} = Locale.resolve(Scope.for_user(user), browser("de-DE"))
    end

    test "with no user setting, the browser's regional match applies" do
      assert format_id(Locale.resolve(Scope.for_user(user!()), browser("de"))) == :de
    end

    test "a browser language without a catalog leaves the language at the site default" do
      assert %Locale{language: "en"} = Locale.resolve(Scope.for_user(user!()), browser("fr"))

      :ok = Settings.put(Scope.for_user(user!(:owner)), :site, "appearance.default_language", "es")
      assert %Locale{language: "es"} = Locale.resolve(Scope.for_user(user!()), browser("fr"))
    end

    test "with no browser match, the site default regional format applies, then the built-in one" do
      assert format_id(Locale.resolve(nil, browser(nil))) == :en

      :ok = Settings.put(Scope.for_user(user!(:owner)), :site, "appearance.default_locale", "pt")
      assert format_id(Locale.resolve(nil, browser(nil))) == :pt
    end
  end

  describe "with_user_locale/2" do
    test "uses the user's setting, else their last browser locale" do
      user = user!()
      read = fn -> Locale.with_user_locale(user.id, fn -> Localize.get_locale().cldr_locale_id end) end

      assert read.() == :en

      :ok = Accounts.put_browser_locale(user, "de")
      assert read.() == :de

      :ok = Settings.put(Scope.for_user(user), :user, "appearance.locale", "fr")
      assert read.() == :fr
    end

    test "restores the caller's locale afterwards" do
      Locale.with_user_locale(nil, fn -> :ok end)
      assert Localize.get_locale().cldr_locale_id == :en
    end
  end

  test "carry/1 runs a task in the caller's language and regional format" do
    fun =
      Locale.with_locale(%Locale{language: "en", format: tag!("de")}, fn ->
        Locale.carry(fn -> {Gettext.get_locale(Mythweaver.Gettext), Localize.get_locale().cldr_locale_id} end)
      end)

    assert fun |> Task.async() |> Task.await() == {"en", :de}
  end

  test "the regional format setting accepts only supported CLDR ids" do
    scope = Scope.for_user(user!())

    assert {:error, "is not an option"} = Settings.put(scope, :user, "appearance.locale", "xx")
    assert :ok = Settings.put(scope, :user, "appearance.locale", "de")
    assert Settings.get(scope, "appearance.locale") == "de"
  end

  test "the language setting accepts only languages with a catalog" do
    scope = Scope.for_user(user!())

    assert {:error, "is not an option"} = Settings.put(scope, :user, "appearance.language", "fr")
    assert :ok = Settings.put(scope, :user, "appearance.language", "de")
    assert Settings.get(scope, "appearance.language") == "de"
  end
end
