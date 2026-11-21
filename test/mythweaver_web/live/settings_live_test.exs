defmodule MythweaverWeb.SettingsLiveTest do
  use MythweaverWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Notifications.WebPush
  alias Mythweaver.Settings

  setup %{conn: conn} do
    user = register_user!(%{role: :user})
    admin = register_user!()

    %{
      conn: log_in_user(conn, user),
      admin_conn: log_in_user(build_conn(), admin),
      user_scope: Scope.for_user(user),
      admin_scope: Scope.for_user(admin)
    }
  end

  test "a user sees only their own level and user-overridable settings", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#settings-tree-memory")
    refute has_element?(view, "#settings-level-tab-site")

    {:ok, view, _html} = live(conn, ~p"/settings/appearance?level=site")
    refute has_element?(view, "#setting-appearance-restrict_user_css-form")
    refute has_element?(view, "#setting-memory-show_previews-lock-form")
  end

  test "a user overrides a setting for themselves and resets it", %{conn: conn, user_scope: scope} do
    {:ok, view, _html} = live(conn, ~p"/settings/memory")

    view
    |> element("#setting-memory-show_previews-form")
    |> render_change(%{setting: %{key: "memory.show_previews", value: "false"}})

    assert Settings.get(scope, "memory.show_previews") == false
    assert has_element?(view, "#setting-memory-show_previews-modified")

    view |> element("#setting-memory-show_previews-reset") |> render_click()

    assert Settings.get(scope, "memory.show_previews") == true
    refute has_element?(view, "#setting-memory-show_previews-modified")
  end

  test "an invalid value flashes the error and stores nothing", %{admin_conn: conn, admin_scope: scope} do
    {:ok, view, _html} = live(conn, ~p"/settings/memory?level=site")

    html =
      view
      |> element("#setting-memory-token_warning_threshold-form")
      |> render_change(%{setting: %{key: "memory.token_warning_threshold", value: "999"}})

    assert html =~ "must be at least 1,000"
    assert Settings.get(scope, "memory.token_warning_threshold") == 30_000
    refute has_element?(view, "#setting-memory-token_warning_threshold-modified")
  end

  describe "the tint" do
    test "a user's hue tints every page they load", %{conn: conn, user_scope: scope} do
      assert html_response(get(conn, ~p"/settings"), 200) =~ ~s(style="--tint-h: 263;)

      {:ok, view, _html} = live(conn, ~p"/settings/appearance")

      view
      |> element("#setting-appearance-primary_hue-form")
      |> render_change(%{setting: %{key: "appearance.primary_hue", value: "120"}})

      assert Settings.get(scope, "appearance.primary_hue") == 120
      assert has_element?(view, "#setting-appearance-primary_hue-value[data-effective='120']")
      assert html_response(get(conn, ~p"/settings"), 200) =~ ~s(style="--tint-h: 120;)
    end

    test "the site's hue reaches users without their own and signed-out pages", ctx do
      :ok = Settings.put(ctx.user_scope, :user, "appearance.primary_hue", "120")
      :ok = Settings.put(ctx.admin_scope, :user, "appearance.primary_hue", "200")

      {:ok, view, _html} = live(ctx.admin_conn, ~p"/settings/appearance?level=site")

      view
      |> element("#setting-appearance-primary_hue-form")
      |> render_change(%{setting: %{key: "appearance.primary_hue", value: "30"}})

      # The admin keeps seeing their own hue while editing the site's.
      assert has_element?(view, "#setting-appearance-primary_hue-value[value='30'][data-effective='200']")

      assert html_response(get(build_conn(), ~p"/users/log-in"), 200) =~ ~s(style="--tint-h: 30;)
      assert html_response(get(ctx.conn, ~p"/settings"), 200) =~ ~s(style="--tint-h: 120;)

      fresh = log_in_user(build_conn(), register_user!(%{role: :user}))
      assert html_response(get(fresh, ~p"/settings"), 200) =~ ~s(style="--tint-h: 30;)
    end

    test "a user's tint strength reaches every page, within its range", %{conn: conn, user_scope: scope} do
      assert html_response(get(conn, ~p"/settings"), 200) =~ "--tint-strength: 100\""

      {:ok, view, _html} = live(conn, ~p"/settings/appearance")

      view
      |> element("#setting-appearance-tint_strength-form")
      |> render_change(%{setting: %{key: "appearance.tint_strength", value: "250"}})

      assert has_element?(view, "#setting-appearance-tint_strength-value[data-effective='250']")
      assert html_response(get(conn, ~p"/settings"), 200) =~ "--tint-strength: 250\""

      assert Settings.put(scope, :user, "appearance.tint_strength", "301") == {:error, "must be at most 300"}
    end
  end

  test "a user edits the image text template; an invalid one is refused", %{conn: conn, user_scope: scope} do
    {:ok, view, _html} = live(conn, ~p"/settings/images")
    assert has_element?(view, "#setting-images-caption_template-value")

    html =
      view
      |> element("#setting-images-caption_template-form")
      |> render_change(%{setting: %{key: "images.caption_template", value: "{% if %}"}})

    assert html =~ "is not a valid template"
    refute has_element?(view, "#setting-images-caption_template-modified")

    view
    |> element("#setting-images-caption_template-form")
    |> render_change(%{setting: %{key: "images.caption_template", value: "[Pic: {{ caption }}]"}})

    assert Settings.get(scope, "images.caption_template") == "[Pic: {{ caption }}]"
    assert has_element?(view, "#setting-images-caption_template-modified")
  end

  test "an admin sets site-only settings and locks a user-overridable one", ctx do
    {:ok, admin_view, _html} = live(ctx.admin_conn, ~p"/settings/appearance?level=site")
    assert has_element?(admin_view, "#settings-level-tab-site[aria-selected='true']")
    assert has_element?(admin_view, "#setting-appearance-restrict_user_css-form")

    admin_view
    |> element("#setting-appearance-restrict_user_css-form")
    |> render_change(%{setting: %{key: "appearance.restrict_user_css", value: "false"}})

    assert Settings.get(ctx.user_scope, "appearance.restrict_user_css") == false

    {:ok, admin_view, _html} = live(ctx.admin_conn, ~p"/settings/memory?level=site")

    admin_view
    |> element("#setting-memory-show_previews-lock-form")
    |> render_change(%{setting: %{key: "memory.show_previews", users_may_change: "false"}})

    {:ok, view, _html} = live(ctx.conn, ~p"/settings/memory")
    assert has_element?(view, "#setting-memory-show_previews-locked")
    assert has_element?(view, "#setting-memory-show_previews-value[disabled]")
    refute Settings.can_edit?(ctx.user_scope, :user, "memory.show_previews")
  end

  test "an admin picks the site's default caption model; users never see it", ctx do
    {:ok, model} =
      Mythweaver.AI.create_model(
        ctx.admin_scope,
        %{
          name: "Captioner#{System.unique_integer([:positive])}",
          api_model_id: "captioner",
          supports_images: true
        },
        site: true
      )

    {:ok, view, _html} = live(ctx.admin_conn, ~p"/settings/images?level=site")
    assert has_element?(view, "#setting-images-default_caption_model-value")

    view
    |> element("#setting-images-default_caption_model-form")
    |> render_change(%{setting: %{key: "images.default_caption_model", value: model.id}})

    assert Settings.get(ctx.admin_scope, "images.default_caption_model") == model.id

    {:ok, view, _html} = live(ctx.conn, ~p"/settings/images")
    assert has_element?(view, "#settings-tree-images")
    refute has_element?(view, "#settings-images-default_caption_model")
  end

  test "the default model offers site models at the site level and the user's own at theirs", ctx do
    {:ok, site} =
      Mythweaver.AI.create_model(ctx.admin_scope, %{name: "Site model", api_model_id: "site"}, site: true)

    {:ok, mine} = Mythweaver.AI.create_model(ctx.user_scope, %{name: "My model", api_model_id: "mine"})
    option = "#setting-ai-default_model-value option"

    {:ok, view, _html} = live(ctx.admin_conn, ~p"/settings/models?level=site")
    assert has_element?(view, "#{option}[value='#{site.id}']")
    refute has_element?(view, "#{option}[value='#{mine.id}']")

    {:ok, view, _html} = live(ctx.conn, ~p"/settings/models")
    assert has_element?(view, "#{option}[value='#{site.id}']")

    view
    |> element("#setting-ai-default_model-form")
    |> render_change(%{setting: %{key: "ai.default_model", value: mine.id}})

    assert Settings.get(ctx.user_scope, "ai.default_model") == mine.id
    assert has_element?(view, "#setting-ai-default_model-modified")
  end

  test "the avatar caption prompt offers only the site's caption prompts", ctx do
    {:ok, avatar} =
      Mythweaver.Prompts.create_prompt(ctx.admin_scope, %{name: "Avatar", purpose: :caption}, site: true)

    {:ok, roleplay} = Mythweaver.Prompts.create_prompt(ctx.admin_scope, %{name: "Roleplay"}, site: true)
    {:ok, mine} = Mythweaver.Prompts.create_prompt(ctx.user_scope, %{name: "Mine", purpose: :caption})
    option = "#setting-images-avatar_caption_prompt-value option"

    {:ok, view, _html} = live(ctx.admin_conn, ~p"/settings/images?level=site")
    assert has_element?(view, "#{option}[value='#{avatar.id}']")
    refute has_element?(view, "#{option}[value='#{roleplay.id}']")
    refute has_element?(view, "#{option}[value='#{mine.id}']")

    view
    |> element("#setting-images-avatar_caption_prompt-form")
    |> render_change(%{setting: %{key: "images.avatar_caption_prompt", value: avatar.id}})

    assert Settings.get(ctx.user_scope, "images.avatar_caption_prompt") == avatar.id
  end

  test "search narrows the rows across sections", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view |> element("#settings-search") |> render_change(%{query: "rollback"})

    assert has_element?(view, "#settings-memory-rollback_enabled")
    refute has_element?(view, "#settings-memory-show_previews")

    view |> element("#settings-search") |> render_change(%{query: "no such setting"})
    assert has_element?(view, "#settings-empty")
  end

  describe "a grid section" do
    test "the speaker toggles a cell's sound; the checkbox its notification; reset puts it back",
         %{conn: conn, user_scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/settings/notifications")
      sound = "#setting-notifications-regenerate-sound-value"
      assert has_element?(view, "#settings-grid-notifications-events-regenerate #{sound}[aria-pressed='true']")

      view |> element(sound) |> render_click()
      assert Settings.get(scope, "notifications.regenerate.sound") == false
      assert has_element?(view, "#{sound}[aria-pressed='false']")

      view
      |> element("#setting-notifications-regenerate-popup-form")
      |> render_change(%{setting: %{key: "notifications.regenerate.popup", value: "false"}})

      assert Settings.get(scope, "notifications.regenerate.popup") == false

      view |> element("#setting-notifications-regenerate-sound-reset") |> render_click()
      assert Settings.get(scope, "notifications.regenerate.sound") == true
      assert has_element?(view, "#setting-notifications-regenerate-sound-reset[hidden]")
    end

    test "an admin locks one cell; the user sees it disabled", ctx do
      {:ok, admin_view, _html} = live(ctx.admin_conn, ~p"/settings/notifications?level=site")
      admin_view |> element("#setting-notifications-continue-sound-lock") |> render_click()
      assert has_element?(admin_view, "#setting-notifications-continue-sound-lock[aria-pressed='true']")

      {:ok, view, _html} = live(ctx.conn, ~p"/settings/notifications")
      assert has_element?(view, "#setting-notifications-continue-sound-value[disabled]")
      refute has_element?(view, "#setting-notifications-continue-popup-value[disabled]")
      refute Settings.can_edit?(ctx.user_scope, :user, "notifications.continue.sound")
    end

    test "search keeps only the rows with a match", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      view |> element("#settings-search") |> render_change(%{query: "continues"})

      assert has_element?(view, "#settings-grid-notifications-events-continue")
      refute has_element?(view, "#settings-grid-notifications-events-new_message")
    end
  end

  describe "push" do
    defp configure_push do
      {public, private} = :crypto.generate_key(:ecdh, :prime256v1)
      encode = &Base.url_encode64(&1, padding: false)

      Application.put_env(:web_push_ex, :vapid,
        public_key: encode.(public),
        private_key: encode.(private),
        subject: "mailto:admin@example.com"
      )

      on_exit(fn -> Application.delete_env(:web_push_ex, :vapid) end)
      encode.(public)
    end

    defp browser_subscription(endpoint) do
      {public, _} = :crypto.generate_key(:ecdh, :prime256v1)

      %{
        "endpoint" => endpoint,
        "keys" => %{
          "p256dh" => Base.url_encode64(public, padding: false),
          "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
        }
      }
    end

    test "without VAPID keys there is no Push column, preview setting or device panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/notifications")

      assert has_element?(view, "#setting-notifications-new_message-popup-form")
      refute has_element?(view, "#setting-notifications-new_message-push-form")
      refute has_element?(view, "#settings-grid-notifications-events th", "Push")
      refute has_element?(view, "#setting-notifications-push_preview-form")
      refute has_element?(view, "#settings-push-devices")
    end

    test "with keys the grid gains Push and the panel shows, at the User level only",
         %{conn: conn, admin_conn: admin_conn} do
      key = configure_push()
      {:ok, view, _html} = live(conn, ~p"/settings/notifications")

      assert has_element?(view, "#setting-notifications-new_message-push-form")
      assert has_element?(view, "#setting-notifications-push_preview-form")
      assert has_element?(view, "#settings-push-devices[data-key='#{key}']")

      {:ok, admin_view, _html} = live(admin_conn, ~p"/settings/notifications?level=site")
      assert has_element?(admin_view, "#setting-notifications-new_message-push-form")
      refute has_element?(admin_view, "#settings-push-devices")
    end

    test "the panel explains why this browser cannot have push", %{conn: conn} do
      configure_push()
      {:ok, view, _html} = live(conn, ~p"/settings/notifications")

      for status <- ~w(insecure ios_install denied unsupported) do
        view |> element("#settings-push-devices") |> render_hook("push_state", %{status: status, endpoint: nil})
        assert has_element?(view, "#push-unavailable")
        refute has_element?(view, "#push-enable")
      end
    end

    test "enabling this browser saves it; disabling removes it", %{conn: conn, user_scope: scope} do
      configure_push()
      endpoint = "https://fcm.googleapis.com/fcm/send/this-browser"
      {:ok, view, _html} = live(conn, ~p"/settings/notifications")
      panel = element(view, "#settings-push-devices")

      render_hook(panel, "push_state", %{status: "ready", endpoint: nil})
      assert has_element?(view, "#push-enable")

      render_hook(panel, "push_subscribe", %{subscription: browser_subscription(endpoint), label: "Chrome on Android"})
      assert_reply(view, %{ok: true})
      assert [%{id: id, label: "Chrome on Android"}] = Mythweaver.Notifications.list_devices(scope)

      render_hook(panel, "push_state", %{status: "ready", endpoint: endpoint})
      assert has_element?(view, "#push-disable")
      assert has_element?(view, "#push-devices-#{id} .push-device-badge")

      render_hook(panel, "push_unsubscribe", %{endpoint: endpoint})
      assert Mythweaver.Notifications.list_devices(scope) == []
      refute has_element?(view, "#push-devices-#{id}")
    end

    test "a refused subscription replies not ok and says so", %{conn: conn, user_scope: scope} do
      configure_push()
      {:ok, view, _html} = live(conn, ~p"/settings/notifications")

      view
      |> element("#settings-push-devices")
      |> render_hook("push_subscribe", %{subscription: browser_subscription("http://insecure.example/x"), label: "x"})

      assert_reply(view, %{ok: false})
      assert has_element?(view, "#flash-error")
      assert Mythweaver.Notifications.list_devices(scope) == []
    end

    test "Send test pushes to that device; Remove deletes it", %{conn: conn, user_scope: scope} do
      configure_push()

      {:ok, device} =
        Mythweaver.Notifications.subscribe_device(
          scope,
          browser_subscription("https://push.example.net/x"),
          "Firefox on Linux"
        )

      test = self()

      Req.Test.stub(WebPush, fn conn ->
        send(test, :pushed)
        Plug.Conn.send_resp(conn, 201, "")
      end)

      {:ok, view, _html} = live(conn, ~p"/settings/notifications")
      view |> element("#push-device-test-#{device.id}") |> render_click()
      render_async(view)

      assert_received :pushed
      assert has_element?(view, "#flash-info")
      assert has_element?(view, "#push-device-time-#{device.id}")

      view |> element("#push-device-remove-#{device.id}") |> render_click()
      refute has_element?(view, "#push-devices-#{device.id}")
      assert Mythweaver.Notifications.list_devices(scope) == []
    end

    test "a device the push service no longer knows is removed by its test", %{conn: conn, user_scope: scope} do
      configure_push()

      {:ok, device} =
        Mythweaver.Notifications.subscribe_device(
          scope,
          browser_subscription("https://push.example.net/y"),
          "Safari on iOS"
        )

      Req.Test.stub(WebPush, &Plug.Conn.send_resp(&1, 410, ""))

      {:ok, view, _html} = live(conn, ~p"/settings/notifications")
      view |> element("#push-device-test-#{device.id}") |> render_click()
      render_async(view)

      assert has_element?(view, "#flash-error")
      refute has_element?(view, "#push-devices-#{device.id}")
    end
  end

  describe "custom stylesheets" do
    @user_import "@import url(/styles/user.css?v="
    @site_import "@import url(/styles/site.css?v="

    test "every page imports the user's and site's sheets; ?safe_mode leaves the user's out",
         %{conn: conn, user_scope: scope, admin_scope: admin} do
      refute html_response(get(conn, ~p"/settings"), 200) =~ "@import"

      assert :ok = Settings.put(scope, :user, "appearance.user_css", "body { outline: 1px solid red }")
      assert :ok = Settings.put(admin, :site, "appearance.site_css", "body { font-style: italic }")

      html = html_response(get(conn, ~p"/settings"), 200)
      assert html =~ @user_import
      assert html =~ @site_import

      safe = html_response(get(conn, ~p"/settings?safe_mode"), 200)
      refute safe =~ @user_import
      assert safe =~ @site_import

      signed_out = html_response(get(build_conn(), ~p"/users/log-in"), 200)
      assert signed_out =~ @site_import
      refute signed_out =~ @user_import
    end

    test "a refused save flashes why", %{conn: conn, user_scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/settings/appearance")

      view
      |> element("#setting-appearance-user_css-form")
      |> render_change(%{setting: %{key: "appearance.user_css", value: "a { background: url(x) }"}})

      assert has_element?(
               view,
               "[data-flash][data-kind=error]",
               "Your stylesheet: can't load outside files: url() isn't allowed"
             )

      assert Settings.get(scope, "appearance.user_css") == nil
    end

    test "a sheet the restored restriction refuses says it is not applied",
         %{conn: conn, user_scope: scope, admin_scope: admin} do
      assert :ok = Settings.put(admin, :site, "appearance.restrict_user_css", false)
      assert :ok = Settings.put(scope, :user, "appearance.user_css", "a { background: url(x) }")

      {:ok, view, _html} = live(conn, ~p"/settings/appearance")
      refute has_element?(view, "#setting-appearance-user_css-blocked")

      assert :ok = Settings.put(admin, :site, "appearance.restrict_user_css", true)
      {:ok, view, _html} = live(conn, ~p"/settings/appearance")
      assert has_element?(view, "#setting-appearance-user_css-blocked")
    end

    test "a save points the page's imports at the new version", %{conn: conn, user_scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/settings/appearance")
      refute has_element?(view, "#custom-styles-sync[data-imports*='user.css']")

      view
      |> element("#setting-appearance-user_css-form")
      |> render_change(%{setting: %{key: "appearance.user_css", value: "a { color: red }"}})

      version = Mythweaver.Stylesheets.versions(scope).user
      assert has_element?(view, "#custom-styles-sync[data-imports*='user.css?v=#{version}']")
    end
  end

  describe "cleanup" do
    test "a user's button sits after the automatic checkbox and cleans their chats", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/settings/models")

      ids =
        view
        |> render()
        |> LazyHTML.from_document()
        |> LazyHTML.query("#settings-section-models-cleanup [id]")
        |> LazyHTML.attribute("id")
        |> Enum.filter(&(&1 in ~w(setting-cleanup-automatic-form settings-cleanup setting-cleanup-after_messages-form)))

      assert ids == ~w(setting-cleanup-automatic-form settings-cleanup setting-cleanup-after_messages-form)
      assert has_element?(view, "#settings-cleanup", "Clean up my chats")

      view |> element("#settings-cleanup-now") |> render_click()
      render_async(view)
      assert has_element?(view, "#flash-info", "Cleaned up")

      view
      |> element("#setting-cleanup-automatic-form")
      |> render_change(%{setting: %{key: "cleanup.automatic", value: "false"}})

      assert Settings.get(ctx.user_scope, "cleanup.automatic") == false
    end

    test "the Site button needs the cleanup permission", ctx do
      {:ok, view, _html} = live(ctx.admin_conn, ~p"/settings/models?level=site")
      refute has_element?(view, "#settings-cleanup")

      owner = log_in_user(build_conn(), register_user!(%{role: :owner}))
      {:ok, view, _html} = live(owner, ~p"/settings/models?level=site")
      assert has_element?(view, "#settings-cleanup", "Clean up all chats")

      view |> element("#settings-cleanup-now") |> render_click()
      render_async(view)
      assert has_element?(view, "#flash-info", "Cleaned up")
    end
  end
end
