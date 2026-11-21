defmodule Mythweaver.SettingsTest do
  use Mythweaver.DataCase, async: true

  alias Mythweaver.Settings
  alias Mythweaver.Settings.Setting

  test "an unknown key raises instead of reading as nil" do
    assert_raise ArgumentError, ~r/unknown setting/, fn -> Settings.get(scope!(), "ai.no_such_setting") end
  end

  describe "cascade" do
    test "default, then the site's value, then the user's own" do
      admin = scope!()
      user = scope!(%{role: :user})
      other = scope!(%{role: :user})

      assert Settings.get(user, "memory.show_previews") == true

      assert :ok = Settings.put(admin, :site, "memory.show_previews", false)
      assert Settings.get(user, "memory.show_previews") == false

      assert :ok = Settings.put(user, :user, "memory.show_previews", "true")
      assert Settings.get(user, "memory.show_previews") == true
      assert Settings.get(other, "memory.show_previews") == false
    end

    test "writes of different keys at one level both stick" do
      user = scope!(%{role: :user})

      assert :ok = Settings.put(user, :user, "memory.allow_overlap", true)
      assert :ok = Settings.put(user, :user, "memory.include_hidden", true)

      assert Settings.get_many(user, ["memory.allow_overlap", "memory.include_hidden"]) ==
               %{"memory.allow_overlap" => true, "memory.include_hidden" => true}
    end

    test "reset removes the level's override" do
      admin = scope!()
      user = scope!(%{role: :user})

      :ok = Settings.put(admin, :site, "memory.default_previous_count", 3)
      :ok = Settings.put(user, :user, "memory.default_previous_count", 5)
      assert Settings.get(user, "memory.default_previous_count") == 5

      assert :ok = Settings.reset(user, :user, "memory.default_previous_count")
      assert Settings.get(user, "memory.default_previous_count") == 3
    end
  end

  describe "locking" do
    test "a locked key reads the site value and refuses user writes until unlocked" do
      admin = scope!()
      user = scope!(%{role: :user})

      :ok = Settings.put(user, :user, "memory.show_previews", false)
      assert :ok = Settings.lock(admin, "memory.show_previews", true)

      assert Settings.get(user, "memory.show_previews") == true
      assert Settings.put(user, :user, "memory.show_previews", false) == {:error, :unauthorized}
      assert Settings.reset(user, :user, "memory.show_previews") == {:error, :unauthorized}
      refute Settings.can_edit?(user, :user, "memory.show_previews")

      assert :ok = Settings.lock(admin, "memory.show_previews", false)
      assert Settings.get(user, "memory.show_previews") == false
    end

    test "locking twice keeps one entry; non-admins and site-only keys refuse" do
      admin = scope!()
      user = scope!(%{role: :user})

      :ok = Settings.lock(admin, "memory.show_previews", true)
      :ok = Settings.lock(admin, "memory.show_previews", true)

      assert [%{locked?: true}] =
               Enum.filter(Settings.entries(admin, :site), &(&1.key == "memory.show_previews"))

      assert Settings.lock(user, "memory.show_previews", true) == {:error, :unauthorized}
      assert Settings.lock(admin, "appearance.restrict_user_css", true) == {:error, :unauthorized}
    end
  end

  describe "site-only settings" do
    test "only site settings managers set them, and the value reaches its caller" do
      admin = scope!()
      user = scope!(%{role: :user})

      assert Settings.put(user, :user, "appearance.restrict_user_css", false) == {:error, :unauthorized}
      assert Settings.put(user, :site, "appearance.restrict_user_css", false) == {:error, :unauthorized}

      assert :ok = Settings.put(admin, :site, "appearance.restrict_user_css", false)
      assert Settings.get(user, "appearance.restrict_user_css") == false
    end

    test "users see no site-only entries and no site level" do
      user = scope!(%{role: :user})

      assert Settings.entries(user, :site) == []
      refute Enum.any?(Settings.entries(user, :user), &(&1.key == "appearance.restrict_user_css"))
    end
  end

  describe "stylesheets" do
    test "a user's sheet may not load outside files while the site restricts it; the site's may" do
      admin = scope!()
      user = scope!(%{role: :user})
      css = "a { background: url(x) }"

      assert Settings.put(user, :user, "appearance.user_css", css) ==
               {:error, "can't load outside files: url() isn't allowed"}

      assert :ok = Settings.put(admin, :site, "appearance.restrict_user_css", false)
      assert :ok = Settings.put(user, :user, "appearance.user_css", css)
      assert Settings.get(user, "appearance.user_css") == css

      assert :ok = Settings.put(admin, :site, "appearance.site_css", css)
    end

    test "a restricted user sheet may import a font stylesheet while the site allows third-party fonts" do
      admin = scope!()
      user = scope!(%{role: :user})
      google_css = ~s|@import url("https://fonts.googleapis.com/css2?family=Inter&display=swap");|

      assert Settings.put(user, :user, "appearance.user_css", google_css) == :ok

      assert Settings.put(user, :user, "appearance.user_css", ~s|@import "x";|) ==
               {:error, "can't load outside files: @import isn't allowed, except a Google Fonts stylesheet"}

      assert :ok = Settings.put(admin, :site, "appearance.allow_third_party_fonts", false)

      assert Settings.put(user, :user, "appearance.user_css", google_css) ==
               {:error, "can't load outside files: @import isn't allowed"}

      assert Settings.put(user, :user, "appearance.allow_third_party_fonts", false) == {:error, :unauthorized}
    end

    test "a sheet is stored as typed, and a blank one is no override" do
      user = scope!(%{role: :user})

      assert :ok = Settings.put(user, :user, "appearance.user_css", "  a { color: red }\n")
      assert Settings.get(user, "appearance.user_css") == "  a { color: red }\n"

      assert :ok = Settings.put(user, :user, "appearance.user_css", " \n ")
      assert Settings.get(user, "appearance.user_css") == nil
    end

    test "the user sheet exists only at the user level, the site sheet only at the site level" do
      admin = scope!()
      user = scope!(%{role: :user})

      assert Settings.put(admin, :site, "appearance.user_css", "a{}") == {:error, :unauthorized}
      refute Enum.any?(Settings.entries(admin, :site), &(&1.key == "appearance.user_css"))
      refute Enum.any?(Settings.entries(user, :user), &(&1.key == "appearance.site_css"))
    end

    test "extra sources are stored as normalized origins, and anything else is refused" do
      admin = scope!()

      assert :ok =
               Settings.put(admin, :site, "appearance.extra_sources", "https://Use.Typekit.net/ https://a.example:8443")

      assert Settings.get(admin, "appearance.extra_sources") == ["https://use.typekit.net", "https://a.example:8443"]

      for bad <- ["http://evil.example", "https://a.example/path", "https://u@a.example", "use.typekit.net"] do
        assert Settings.put(admin, :site, "appearance.extra_sources", bad) ==
                 {:error, "#{bad} isn't an origin like https://fonts.example.com"}
      end

      assert :ok =
               Settings.put(admin, :site, "appearance.extra_sources", "http://localhost:4100, https://a.example:443")

      assert Settings.get(admin, "appearance.extra_sources") == ["http://localhost:4100", "https://a.example"]

      assert :ok = Settings.put(admin, :site, "appearance.extra_sources", " ")
      assert Settings.get(admin, "appearance.extra_sources") == []
    end
  end

  describe "validation" do
    test "casts form strings and rejects out-of-range or unknown values" do
      admin = scope!()

      assert Settings.put(admin, :site, "memory.token_warning_threshold", "999") ==
               {:error, "must be at least 1,000"}

      assert Settings.put(admin, :site, "memory.token_warning_threshold", "12.5") ==
               {:error, "must be a whole number"}

      assert Settings.put(admin, :site, "memory.boundary_indicator", "nope") == {:error, "is not an option"}

      assert :ok = Settings.put(admin, :site, "memory.boundary_indicator", "off")
      assert Settings.get(admin, "memory.boundary_indicator") == :off

      assert :ok = Settings.put(admin, :site, "memory.consolidation_watch_tiers", ["", "2", "1"])
      assert Settings.get(admin, "memory.consolidation_watch_tiers") == [1, 2]
    end

    test "a stored value that no longer fits falls through to the next layer" do
      user = scope!(%{role: :user})

      Repo.insert!(%Setting{
        user_id: user.user.id,
        values: %{"memory.boundary_indicator" => "gone", "memory.show_previews" => 3}
      })

      assert Settings.get(user, "memory.boundary_indicator") == :divider
      assert Settings.get(user, "memory.show_previews") == true
    end

    test "a template setting is parsed on save, and a blank one stores no override" do
      admin = scope!()

      assert {:error, "is not a valid template: " <> _} =
               Settings.put(admin, :site, "images.caption_template", "{% if %}")

      assert :ok = Settings.put(admin, :site, "images.caption_template", " [Pic: {{ caption }}] ")
      assert Settings.get(admin, "images.caption_template") == "[Pic: {{ caption }}]"

      assert :ok = Settings.put(admin, :site, "images.caption_template", "  ")
      assert Settings.get(admin, "images.caption_template") == nil
      assert Repo.one!(from s in Setting, where: is_nil(s.user_id)).values == %{}
    end

    test "lore.embedding_model accepts embedding models only, the user's own at the user level" do
      admin = scope!()
      user = scope!(%{role: :user})
      {:ok, chat} = Mythweaver.AI.create_model(admin, %{name: "Chat", api_model_id: "chat-1"}, site: true)
      site = embedding_model!(admin, "Site embedder", site: true)
      own = embedding_model!(user, "Own embedder")

      assert Settings.put(admin, :site, "lore.embedding_model", chat.id) == {:error, "is not an option"}
      assert Settings.put(admin, :site, "lore.embedding_model", own.id) == {:error, "is not an option"}
      assert :ok = Settings.put(admin, :site, "lore.embedding_model", site.id)

      assert :ok = Settings.put(user, :user, "lore.embedding_model", own.id)
      assert Settings.get(user, "lore.embedding_model") == own.id
      assert Settings.get(admin, "lore.embedding_model") == site.id
    end
  end

  defp embedding_model!(scope, name, opts \\ []) do
    {:ok, model} =
      Mythweaver.AI.create_model(scope, %{name: name, api_model_id: "embed-1", completion_mode: :embedding}, opts)

    model
  end
end
