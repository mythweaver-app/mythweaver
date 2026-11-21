defmodule MythweaverWeb.CharacterLiveTest do
  use MythweaverWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.Attachments
  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Characters
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats
  alias Mythweaver.Moderation.Rules
  alias Mythweaver.Repo
  alias Mythweaver.Sharing.Share
  alias Mythweaver.Tags

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
       )

  setup :register_and_log_in_user

  defp character(scope, name, description \\ nil) do
    {:ok, character} = Characters.create_character(scope, %{name: name, description: description})
    character
  end

  test "index selects nothing and lists every one", %{scope: scope, conn: conn} do
    character(scope, "Aqua", "Useless goddess")
    character(scope, "Kazuma")
    [first, second] = Characters.list_characters(scope)

    {:ok, view, _html} = live(conn, ~p"/characters")

    assert has_element?(view, "#character-placeholder")
    refute has_element?(view, "#character-form")
    assert has_element?(view, "#characters-#{first.id}")
    assert has_element?(view, "#characters-#{second.id}")
    refute has_element?(view, "#characters a[aria-current='page']")
    assert has_element?(view, ".top-bar-nav a[href='/characters']")

    view |> element("#characters-#{first.id} a") |> render_click()
    assert_patch(view, ~p"/characters/#{first.id}/edit")
    assert has_element?(view, "#characters-#{first.id} a[aria-current='page']")
    refute has_element?(view, "#character-placeholder")
  end

  test "starring a character lists it first with a star", %{scope: scope, conn: conn} do
    aqua = character(scope, "Aqua")
    kazuma = character(scope, "Kazuma")

    order = fn view ->
      view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("#characters > li") |> LazyHTML.attribute("id")
    end

    {:ok, view, _html} = live(conn, ~p"/characters/#{kazuma.id}/edit")
    assert has_element?(view, "#character-favorite[aria-pressed='false']")
    refute has_element?(view, "#characters-#{kazuma.id} .character-list-favorite")

    view |> element("#character-favorite") |> render_click()
    assert has_element?(view, "#character-favorite[aria-pressed='true']")
    assert has_element?(view, "#characters-#{kazuma.id} .character-list-favorite")
    refute has_element?(view, "#characters-#{aqua.id} .character-list-favorite")
    assert order.(view) == ["characters-#{kazuma.id}", "characters-#{aqua.id}"]

    view |> element("#character-favorite") |> render_click()
    assert has_element?(view, "#character-favorite[aria-pressed='false']")
    refute has_element?(view, "#characters-#{kazuma.id} .character-list-favorite")
    assert order.(view) == ["characters-#{aqua.id}", "characters-#{kazuma.id}"]
  end

  test "a non-editing view shows no favorite toggle", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/characters")
    refute has_element?(view, "#character-favorite")

    {:ok, view, _html} = live(conn, ~p"/characters/new")
    refute has_element?(view, "#character-favorite")
  end

  test "the search box narrows the list by name, description, or creator", %{scope: scope, conn: conn} do
    aqua = character(scope, "Aqua", "Useless goddess")
    kazuma = character(scope, "Kazuma")
    {:ok, kazuma} = Characters.update_character(scope, kazuma, %{creator: "Natsume"})

    {:ok, view, _html} = live(conn, ~p"/characters/#{aqua.id}/edit")

    view |> form("#character-filter", %{"query" => "GODDESS"}) |> render_change()
    assert has_element?(view, "#characters-#{aqua.id} a[aria-current='page']")
    refute has_element?(view, "#characters-#{kazuma.id}")

    view |> form("#character-filter", %{"query" => "natsu"}) |> render_change()
    assert has_element?(view, "#characters-#{kazuma.id}")
    refute has_element?(view, "#characters-#{aqua.id}")

    view |> form("#character-filter", %{"query" => "nobody"}) |> render_change()
    assert has_element?(view, "#characters-nav .pane-empty")
    refute has_element?(view, "#characters li[id]")
  end

  test "saving the form keeps the tags typed into it", %{scope: scope, conn: conn} do
    aqua = character(scope, "Aqua")
    {:ok, view, _html} = live(conn, ~p"/characters/#{aqua.id}/edit")

    view
    |> form("#character-form", character: %{name: "Aqua"})
    |> render_submit(%{"tags" => %{"mine" => ["", "color:purple"]}})

    assert %{mine: ["color:purple"]} = Tags.item_tags(scope, aqua)
  end

  test "the tag filter drops characters with an excluded tag", %{scope: scope, conn: conn} do
    aqua = character(scope, "Aqua")
    kazuma = character(scope, "Kazuma")
    :ok = Tags.set_item_tags(scope, aqua, :mine, ["color:purple"])

    {:ok, view, _html} = live(conn, ~p"/characters/#{kazuma.id}/edit")

    view |> form("#character-filter", %{"query" => ""}) |> render_change(%{"tag_filter" => ["-color:purple"]})
    refute has_element?(view, "#characters-#{aqua.id}")
    assert has_element?(view, "#characters-#{kazuma.id}")
  end

  test "creates a character from the new form", %{scope: scope, conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/characters/new")

    view
    |> form("#character-form",
      character: %{
        name: "Aqua",
        description: "Useless goddess",
        creator: "Natsume",
        creator_notes: "Original creator notes",
        character_version: "1.2",
        pronouns: "she/her"
      }
    )
    |> render_submit()

    assert [created] = Characters.list_characters(scope)
    assert created.name == "Aqua"
    assert created.creator == "Natsume"
    assert created.creator_notes == "Original creator notes"
    assert created.character_version == "1.2"
    assert created.pronouns == "she/her"
    assert_patch(view, "/characters/#{created.id}/edit")
    assert has_element?(view, "#characters-#{created.id} a[aria-current='page']")
  end

  test "an admin's new character with Owner Personal is their own and can be shared", %{scope: scope, conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/characters/new")
    assert has_element?(view, "#character-form-owner option[value='personal'][selected]")

    view |> form("#character-form", owner: "personal", character: %{name: "Mine"}) |> render_submit()

    assert [%{name: "Mine"} = created] = Characters.list_editable_characters(scope)
    assert created.user_id == scope.user.id
    {:ok, view, _html} = live(conn, ~p"/characters/#{created.id}/edit")
    assert has_element?(view, "#character-share")
  end

  test "an admin's new character with Owner Site is the site's", %{scope: scope, conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/characters/new")

    view |> form("#character-form", owner: "site", character: %{name: "Shared"}) |> render_submit()

    assert [%{name: "Shared", user_id: nil}] = Characters.list_editable_characters(scope)
  end

  test "a site manager sets a site character runtime-only; personal ones get no visibility select",
       %{scope: scope, conn: conn} do
    {:ok, site} = Characters.create_character(scope, %{name: "Sphinx"}, site: true)
    own = character(scope, "Mine")

    {:ok, view, _html} = live(conn, ~p"/characters/new")
    refute has_element?(view, "#character-form-site_visibility")
    view |> form("#character-form", owner: "site", character: %{name: "New"}) |> render_change()
    assert has_element?(view, "#character-form-site_visibility")

    {:ok, view, _html} = live(conn, ~p"/characters/#{own.id}/edit")
    refute has_element?(view, "#character-form-site_visibility")

    {:ok, view, _html} = live(conn, ~p"/characters/#{site.id}/edit")
    view |> form("#character-form", character: %{site_visibility: "runtime_only"}) |> render_submit()

    assert Characters.get_character!(site.id).site_visibility == :runtime_only
  end

  test "an uploaded avatar is saved with the character and can be removed", %{scope: scope, conn: conn} do
    aqua = character(scope, "Aqua")

    {:ok, view, _html} = live(conn, ~p"/characters/#{aqua.id}/edit")

    view
    |> file_input("#character-form", :avatar, [%{name: "aqua.png", content: @png, type: "image/png"}])
    |> render_upload("aqua.png")

    # Shown, but the character's only once the form is saved.
    assert has_element?(view, "#character-form-avatar img[alt='New avatar']")
    refute Characters.preload_avatar(scope, Characters.get_character!(aqua.id)).avatar

    view |> form("#character-form", character: %{name: "Aqua"}) |> render_submit()

    assert has_element?(view, "#character-form-avatar img")
    assert Characters.preload_avatar(scope, Characters.get_character!(aqua.id)).avatar

    view |> element("#character-form-avatar-remove") |> render_click()

    refute has_element?(view, "#character-form-avatar img")
    refute Characters.preload_avatar(scope, Characters.get_character!(aqua.id)).avatar
  end

  test "invalid submission keeps the form open and creates nothing", %{scope: scope, conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/characters/new")

    view |> form("#character-form", character: %{name: ""}) |> render_submit()

    assert has_element?(view, "#character-form")
    assert Characters.list_characters(scope) == []
  end

  test "edits an existing character", %{scope: scope, conn: conn} do
    aqua = character(scope, "Aqua")

    {:ok, view, _html} = live(conn, ~p"/characters/#{aqua.id}/edit")

    view |> form("#character-form", character: %{name: "Renamed"}) |> render_submit()

    assert Characters.get_character!(aqua.id).name == "Renamed"
    assert_patch(view, "/characters/#{aqua.id}/edit")
    assert has_element?(view, "#character-form-name[value='Renamed']")
  end

  test "Export opens the export page with the character preselected", %{scope: scope, conn: conn} do
    aqua = character(scope, "Aqua")
    {:ok, view, _html} = live(conn, ~p"/characters/#{aqua.id}/edit")

    view |> element("#export-character") |> render_click()
    assert_redirect(view, "/export?kind=character&item=#{aqua.id}")
  end

  test "a save elsewhere reloads an untouched form and flags an edited one", %{scope: scope, conn: conn} do
    aqua = character(scope, "Aqua")
    {:ok, clean, _html} = live(conn, ~p"/characters/#{aqua.id}/edit")
    {:ok, dirty, _html} = live(conn, ~p"/characters/#{aqua.id}/edit")

    dirty |> form("#character-form", character: %{description: "typed"}) |> render_change()
    {:ok, _} = Characters.update_character(scope, aqua, %{name: "Aqua II"})

    assert has_element?(clean, "#character-form-name[value='Aqua II']")
    assert has_element?(clean, "#characters-#{aqua.id}", "Aqua II")
    refute has_element?(clean, "#character-changed-elsewhere")

    assert has_element?(dirty, "#character-changed-elsewhere")
    assert has_element?(dirty, "#character-form-name[value='Aqua']")

    dirty |> element("#character-changed-elsewhere-reload") |> render_click()
    assert_patch(dirty, ~p"/characters/#{aqua.id}/edit")
    assert has_element?(dirty, "#character-form-name[value='Aqua II']")
    refute has_element?(dirty, "#character-changed-elsewhere")
  end

  test "a character deleted elsewhere closes its editor", %{scope: scope, conn: conn} do
    aqua = character(scope, "Aqua")
    {:ok, view, _html} = live(conn, ~p"/characters/#{aqua.id}/edit")

    {:ok, _} = Characters.delete_character(scope, aqua)

    assert_patch(view, ~p"/characters")
  end

  test "deletes a character not in any chat", %{scope: scope, conn: conn} do
    aqua = character(scope, "Aqua")

    {:ok, view, _html} = live(conn, ~p"/characters/#{aqua.id}/edit")

    view |> element("#delete-character") |> render_click()

    assert_patch(view, "/characters")
    assert has_element?(view, "#character-placeholder")
    assert Characters.get_character(scope, aqua.id) == nil
  end

  test "refuses to delete a character that participates in a chat", %{scope: scope, conn: conn, user: user} do
    aqua = character(scope, "Aqua")
    kazuma = character(scope, "Kazuma")

    {:ok, _chat} =
      Chats.create_chat(Scope.for_user(user), %{participants: [%{character_id: aqua.id}, %{character_id: kazuma.id}]})

    {:ok, view, _html} = live(conn, ~p"/characters/#{aqua.id}/edit")

    html = view |> element("#delete-character") |> render_click()

    assert html =~ "is in a chat and can&#39;t be deleted"
    assert has_element?(view, "#characters-#{aqua.id}")
    assert Characters.get_character(scope, aqua.id) != nil
  end

  test "the avatar-updates-Appearance override saves No, and Follow as nil", %{scope: scope, conn: conn} do
    aqua = character(scope, "Aqua")
    {:ok, view, _html} = live(conn, ~p"/characters/#{aqua.id}/edit")
    assert has_element?(view, "#character-form-avatar_updates_appearance")

    view |> form("#character-form", character: %{avatar_updates_appearance: "false"}) |> render_submit()
    assert Characters.get_character!(aqua.id).avatar_updates_appearance == false

    view |> form("#character-form", character: %{avatar_updates_appearance: ""}) |> render_submit()
    assert Characters.get_character!(aqua.id).avatar_updates_appearance == nil
  end

  test "alternate greetings are added and removed in the form, and blank ones are dropped on save",
       %{scope: scope, conn: conn} do
    {:ok, aqua} = Characters.create_character(scope, %{name: "Aqua", alternate_greetings: ["Hello."]})
    {:ok, view, _html} = live(conn, ~p"/characters/#{aqua.id}/edit")
    assert has_element?(view, "#character-form-first-message")
    assert has_element?(view, "#character-form-alternate-greetings-0")
    refute has_element?(view, "#character-form-alternate-greetings-1")

    # Add and Remove post the form's change with their own name/value.
    add = %{"character" => %{"alternate_greetings_add" => "1"}}
    view |> form("#character-form") |> render_change(add)
    view |> form("#character-form") |> render_change(add)
    assert has_element?(view, "#character-form-alternate-greetings-2")

    assert has_element?(
             view,
             "#character-form-alternate-greetings-add[name='character[alternate_greetings_add]']"
           )

    assert has_element?(
             view,
             "#character-form-alternate-greetings-0-remove[name='character[alternate_greetings_drop]'][value='0']"
           )

    # Removing the saved one leaves the two new blank rows, though the cast drops blanks.
    view |> form("#character-form") |> render_change(%{"character" => %{"alternate_greetings_drop" => "0"}})
    assert has_element?(view, "#character-form-alternate-greetings-1")
    refute has_element?(view, "#character-form-alternate-greetings-2")

    view
    |> form("#character-form")
    |> render_submit(%{
      "character" => %{"first_message" => "Hey.", "greeting_lists" => "1", "alternate_greetings" => ["Hi.", " "]}
    })

    assert %{first_message: "Hey.", alternate_greetings: ["Hi."]} = Characters.get_character!(aqua.id)
  end

  test "a failed save marks the collapsed greeting list that holds the invalid greeting",
       %{scope: scope, conn: conn} do
    {:ok, aqua} = Characters.create_character(scope, %{name: "Aqua"})
    {:ok, view, _html} = live(conn, ~p"/characters/#{aqua.id}/edit")

    refute has_element?(view, "#character-form-alternate-greetings-invalid")

    view
    |> form("#character-form")
    |> render_submit(%{"character" => %{"greeting_lists" => "1", "alternate_greetings" => ["{% if x %}"]}})

    assert has_element?(
             view,
             "details#character-form-alternate-greetings > summary #character-form-alternate-greetings-invalid"
           )

    refute has_element?(view, "#character-form-group-greetings-invalid")
  end

  test "the greeting lists and expressions start collapsed", %{scope: scope, conn: conn} do
    aqua = character(scope, "Aqua")
    {:ok, view, _html} = live(conn, ~p"/characters/#{aqua.id}/edit")

    assert has_element?(view, "details#character-form-alternate-greetings:not([open])")
    assert has_element?(view, "details#character-form-group-greetings:not([open])")
    assert has_element?(view, "details#character-expressions-details:not([open])")
  end

  describe "expressions" do
    defp upload_sprite(view, name) do
      view
      |> file_input("#character-sprites-upload", :sprites, [%{name: name, content: @png, type: "image/png"}])
      |> render_upload(name)
    end

    test "an uploaded sprite lands under the label its file names, and can be deleted", %{scope: scope, conn: conn} do
      aqua = character(scope, "Aqua")
      {:ok, view, _html} = live(conn, ~p"/characters/#{aqua.id}/edit")

      upload_sprite(view, "joy-2.png")

      assert has_element?(view, "#sprite-label-joy img")
      [sprite] = Mythweaver.Expressions.list_sprites(scope, aqua)
      assert sprite.label == "joy"

      view |> element("#delete-sprite-#{sprite.id}") |> render_click()
      refute has_element?(view, "#sprite-label-joy img")
      assert Mythweaver.Expressions.list_sprites(scope, aqua) == []
    end

    test "a file with no label in its name goes to the card whose Add was clicked", %{scope: scope, conn: conn} do
      aqua = character(scope, "Aqua")
      {:ok, view, _html} = live(conn, ~p"/characters/#{aqua.id}/edit")

      view |> element("#add-sprite-sadness") |> render_click()
      upload_sprite(view, "IMG 0001.png")

      assert has_element?(view, "#sprite-label-sadness img")
    end

    test "a sprite pack's folder becomes an outfit tab", %{scope: scope, conn: conn} do
      aqua = character(scope, "Aqua")
      {:ok, {_name, zip}} = :zip.create(~c"p.zip", [{~c"armor/anger-1.png", @png}], [:memory])
      {:ok, view, _html} = live(conn, ~p"/characters/#{aqua.id}/edit")

      view
      |> file_input("#character-sprites-upload", :sprite_pack, [
        %{name: "pack.zip", content: zip, type: "application/zip"}
      ])
      |> render_upload("pack.zip")

      [armor] = Mythweaver.Expressions.list_outfits(scope, aqua)
      refute has_element?(view, "#sprite-label-anger img")

      view |> element("#character-outfits-tab-#{armor.id}") |> render_click()
      assert has_element?(view, "#sprite-label-anger img")
    end

    test "saving a custom label adds its card", %{scope: scope, conn: conn} do
      aqua = character(scope, "Aqua")
      {:ok, view, _html} = live(conn, ~p"/characters/#{aqua.id}/edit")
      refute has_element?(view, "#sprite-label-smug")

      view
      |> form("#character-expressions-form")
      |> render_submit(%{"character" => %{"expression_labels" => ["", "Smug"], "fallback_expression" => "neutral"}})

      assert has_element?(view, "#sprite-label-smug")
      assert has_element?(view, "#character-expressions-form[data-saved]")
      assert Characters.get_character!(aqua.id).expression_labels == ["smug"]
    end

    test "a new character has no Expressions section yet", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/characters/new")
      assert has_element?(view, "#character-expressions-hint")
      refute has_element?(view, "#character-expressions")
    end
  end

  describe "a new avatar's description" do
    setup %{scope: scope} = context do
      Req.Test.set_req_test_to_shared(context)

      {:ok, provider} =
        AI.create_provider(scope, %{name: "Local", adapter: :openai_compatible, base_url: "http://x/v1"}, site: true)

      {:ok, eyes} = AI.create_model(scope, %{name: "Eyes", api_model_id: "eyes", supports_images: true}, site: true)
      {:ok, _} = AI.link_model(scope, provider, eyes)
      stub_caption("A tall woman")

      {:ok, aqua} = Characters.create_character(scope, %{name: "Aqua", appearance: "Blue hair"})
      :ok = Mythweaver.Jobs.subscribe(scope)
      %{aqua: aqua}
    end

    # Each request's decoded body is sent to the test as `{:caption_body, body}`.
    defp stub_caption(text) do
      test = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:caption_body, Jason.decode!(raw)})
        frame = Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => %{"content" => text}}]})
        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce(["data: #{frame}\n\n", "data: [DONE]\n\n"], conn, fn chunk, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, chunk)
          conn
        end)
      end)
    end

    defp upload_avatar(view) do
      view
      |> file_input("#character-form", :avatar, [%{name: "aqua.png", content: @png, type: "image/png"}])
      |> render_upload("aqua.png")
    end

    defp await_description do
      assert_receive {:caption_body, _body}, 2_000
      assert_receive {:job_changed, %{tag: :caption, status: :completed}}, 2_000
    end

    defp saved(scope, character), do: Characters.preload_avatar(scope, Characters.get_character!(character.id))

    test "fills the unsaved Appearance as the avatar uploads, and Save keeps both", %{
      scope: scope,
      conn: conn,
      aqua: aqua
    } do
      {:ok, view, _html} = live(conn, ~p"/characters/#{aqua.id}/edit")
      view |> form("#character-form", character: %{name: "Aqua the goddess"}) |> render_change()

      upload_avatar(view)
      await_description()

      assert has_element?(view, "#character-form-appearance[data-value='A tall woman']")
      assert has_element?(view, "#character-form-name[value='Aqua the goddess']")
      assert has_element?(view, "#character-appearance-revert")
      assert has_element?(view, "#character-form-avatar img[alt='New avatar']")
      refute has_element?(view, "#character-form[data-saved]")

      # Nothing is saved before Save.
      assert %{appearance: "Blue hair", avatar: nil} = saved(scope, aqua)

      # The editor's hook sends the field's shown value with the form.
      view
      |> form("#character-form", character: %{name: "Aqua the goddess", appearance: "A tall woman"})
      |> render_submit()

      assert %{name: "Aqua the goddess", appearance: "A tall woman", avatar: %{description: "A tall woman"}} =
               saved(scope, aqua)

      assert has_element?(view, "#character-form-avatar img[alt='Avatar']")
      refute has_element?(view, "#character-appearance-revert")
    end

    test "Revert puts back the earlier Appearance and keeps the new avatar; editing by hand hides it",
         %{scope: scope, conn: conn, aqua: aqua} do
      {:ok, view, _html} = live(conn, ~p"/characters/#{aqua.id}/edit")
      upload_avatar(view)
      await_description()

      view |> element("#character-appearance-revert") |> render_click()

      assert has_element?(view, "#character-form-appearance[data-value='Blue hair']")
      refute has_element?(view, "#character-appearance-revert")
      assert has_element?(view, "#character-form-avatar img[alt='New avatar']")

      view |> form("#character-form", character: %{appearance: "Blue hair"}) |> render_submit()
      assert %{appearance: "Blue hair", avatar: %{description: "A tall woman"}} = saved(scope, aqua)

      # Describe avatar fills it again; a hand edit makes the text the person's own.
      view |> element("#character-form-appearance-describe") |> render_click()
      await_description()
      assert has_element?(view, "#character-appearance-revert")

      view |> form("#character-form", character: %{appearance: "A tall woman, smiling"}) |> render_change()
      refute has_element?(view, "#character-appearance-revert")
    end

    test "with avatar_updates_appearance off, a new avatar waits for Describe avatar",
         %{conn: conn, aqua: aqua} do
      {:ok, view, _html} = live(conn, ~p"/characters/#{aqua.id}/edit")
      view |> form("#character-form", character: %{avatar_updates_appearance: "false"}) |> render_change()

      upload_avatar(view)
      refute_received {:caption_body, _}
      assert [%Attachment{caption_status: :none}] = Repo.all(Attachment)
      assert has_element?(view, "#character-form-appearance[data-value='Blue hair']")
      refute has_element?(view, "#character-appearance-revert")

      view |> form("#character-form", %{avatar_question: "Who is she?"}) |> render_change()
      view |> element("#character-form-appearance-describe") |> render_click()
      assert_receive {:caption_body, body}, 2_000
      assert_receive {:job_changed, %{tag: :caption, status: :completed}}, 2_000

      assert %{"content" => [%{"type" => "text", "text" => "Who is she?"}, _image]} = List.last(body["messages"])
      assert has_element?(view, "#character-form-appearance[data-value='A tall woman']")
      assert has_element?(view, "#character-appearance-revert")
    end

    test "with images.auto_caption off, a new avatar is not described", %{scope: scope, conn: conn, aqua: aqua} do
      :ok = Mythweaver.Settings.put(scope, :user, "images.auto_caption", false)
      {:ok, view, _html} = live(conn, ~p"/characters/#{aqua.id}/edit")

      upload_avatar(view)

      refute_received {:caption_body, _}
      assert [%Attachment{caption_status: :none}] = Repo.all(Attachment)
      assert has_element?(view, "#character-form-appearance-describe", "Describe avatar")
    end

    test "an avatar still uploading already counts as unsaved, until Keep current drops it",
         %{scope: scope, conn: conn, aqua: aqua} do
      :ok = Mythweaver.Settings.put(scope, :user, "images.auto_caption", false)
      {:ok, view, _html} = live(conn, ~p"/characters/#{aqua.id}/edit")
      assert has_element?(view, "#character-form[data-saved]")

      avatar = file_input(view, "#character-form", :avatar, [%{name: "aqua.png", content: @png, type: "image/png"}])
      render_upload(avatar, "aqua.png", 50)

      refute has_element?(view, "#character-form[data-saved]")
      refute has_element?(view, "#character-form-staged-avatar[value='']")
      assert has_element?(view, "#character-form-staged-avatar[value]")

      view |> element("#character-form-avatar-cancel") |> render_click()
      refute has_element?(view, "#character-form-staged-avatar[value]")
    end

    test "following a setting that keeps Appearance, a new avatar is not described",
         %{scope: scope, conn: conn, aqua: aqua} do
      :ok = Mythweaver.Settings.put(scope, :user, "images.avatar_updates_appearance", false)
      {:ok, view, _html} = live(conn, ~p"/characters/#{aqua.id}/edit")

      upload_avatar(view)

      refute_received {:caption_body, _}
      assert [%Attachment{caption_status: :none}] = Repo.all(Attachment)
    end

    test "Keep current drops the uploaded avatar and its description", %{scope: scope, conn: conn, aqua: aqua} do
      {:ok, view, _html} = live(conn, ~p"/characters/#{aqua.id}/edit")
      upload_avatar(view)
      await_description()
      assert [%Attachment{id: id}] = Repo.all(Attachment)

      view |> element("#character-form-avatar-cancel") |> render_click()

      assert has_element?(view, "#character-form-appearance[data-value='Blue hair']")
      refute has_element?(view, "#character-appearance-revert")
      refute has_element?(view, "#character-form-avatar img")
      refute Attachments.get_attachment(scope, id)
    end

    test "a new character is created with its avatar and the description", %{scope: scope, conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/characters/new")
      upload_avatar(view)
      await_description()
      assert has_element?(view, "#character-form-appearance[data-value='A tall woman']")

      view |> form("#character-form", character: %{name: "Megumin", appearance: "A tall woman"}) |> render_submit()

      created = Enum.find(Characters.list_characters(scope), &(&1.name == "Megumin"))
      assert %{appearance: "A tall woman", avatar: %{description: "A tall woman"}} = saved(scope, created)
    end
  end

  describe "compacting the description" do
    setup %{scope: scope} = context do
      Req.Test.set_req_test_to_shared(context)
      :ok = Mythweaver.Jobs.subscribe(scope)

      {:ok, provider} =
        AI.create_provider(scope, %{name: "Local", adapter: :openai_compatible, base_url: "http://x/v1"})

      {:ok, model} = AI.create_model(scope, %{name: "Gemma", api_model_id: "gemma-4"})
      {:ok, _} = AI.link_model(scope, provider, model)

      {:ok, prompt} = Mythweaver.Prompts.create_prompt(scope, %{name: "Compact", purpose: :compaction})

      {:ok, block} =
        Mythweaver.Prompts.create_block(scope, %{
          name: "Material",
          role: :user,
          content: "{{ anchors.memory.entry.kind }}: {{ anchors.memory.entry.content }}"
        })

      {:ok, _} = Mythweaver.Prompts.add_block(scope, prompt, block)

      {:ok, profile} =
        Mythweaver.Memory.create_profile(scope, %{
          name: "Default",
          ai_model_id: model.id,
          compaction_prompt_id: prompt.id
        })

      {:ok, _} = Mythweaver.Memory.set_default_profile(scope, profile)
      :ok
    end

    test "Compact replaces the form's Description unsaved, keeping its other edits", %{scope: scope, conn: conn} do
      test = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:request, raw})
        frame = Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => %{"content" => "Short."}}]})
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, "data: #{frame}\n\ndata: [DONE]\n\n")
        conn
      end)

      aqua = character(scope, "Aqua", "A goddess.")
      {:ok, view, _html} = live(conn, ~p"/characters/#{aqua.id}/edit")

      view
      |> form("#character-form", character: %{name: "Aqua the Goddess", description: "A long, wordy goddess."})
      |> render_change()

      view |> element("#character-form-description-compact") |> render_click()
      assert has_element?(view, "#character-form-description-compact[disabled]")

      assert_receive {:job_changed, %{tag: :compaction, status: :completed}}, 2_000
      assert_received {:request, body}
      assert body =~ "character: A long, wordy goddess."

      assert has_element?(view, "#character-form-description[data-value='Short.']")
      assert has_element?(view, "#character-form-name[value='Aqua the Goddess']")
      assert has_element?(view, "#character-form:not([data-saved])")
      refute has_element?(view, "#character-form-description-compact[disabled]")
      assert Characters.get_character!(aqua.id).description == "A goddess."
    end
  end

  describe "as a user" do
    test "lists only their own characters and creates owned ones", %{scope: admin} do
      user = register_user!(%{role: :user})
      conn = log_in_user(build_conn(), user)
      user_scope = Scope.for_user(user)
      {:ok, site} = Characters.create_character(admin, %{name: "Site"}, site: true)

      {:ok, view, _html} = live(conn, ~p"/characters/new")
      refute has_element?(view, "#characters-#{site.id}")

      view |> form("#character-form", character: %{name: "Mine"}) |> render_submit()

      assert [%{name: "Mine", user_id: user_id} = mine] = Characters.list_editable_characters(user_scope)
      assert user_id == user.id
      assert has_element?(view, "#characters-#{mine.id}")
      refute Characters.get_character(admin, mine.id)

      # A site character is not editable from a user's editor.
      assert {:error, {:live_redirect, _}} = live(conn, ~p"/characters/#{site.id}/edit")
    end
  end

  describe "bulk select" do
    setup %{scope: scope} do
      %{a: character(scope, "Aqua"), b: character(scope, "Darkness"), c: character(scope, "Kazuma")}
    end

    defp select_mode(conn, a) do
      {:ok, view, _html} = live(conn, ~p"/characters/#{a.id}/edit")
      refute has_element?(view, "#bulk-characters-#{a.id}")
      view |> element("#characters-bulk-toggle") |> render_click()
      assert has_element?(view, "#bulk-characters-#{a.id}")
      view
    end

    defp tick(view, row), do: view |> element("#bulk-characters-#{row.id}") |> render_click()

    # The rows are not re-rendered on a toggle or range (the browser sets those boxes), so the
    # selection shows in the count.
    test "counts the boxes clicked, and a range adds exactly the ids sent", %{conn: conn, a: a, b: b, c: c} do
      view = select_mode(conn, a)
      tick(view, a)
      tick(view, c)
      assert view |> element("#characters-bulk .selection-bar-count") |> render() =~ "2 selected"

      render_hook(view, "bulk_range", %{"ids" => ["characters:#{a.id}", "characters:#{b.id}"]})
      assert view |> element("#characters-bulk .selection-bar-count") |> render() =~ "3 selected"

      tick(view, b)
      assert view |> element("#characters-bulk .selection-bar-count") |> render() =~ "2 selected"
    end

    test "edits only the ticked fields of the selected rows", %{conn: conn, a: a, b: b, c: c} do
      view = select_mode(conn, a)
      tick(view, a)
      tick(view, b)
      view |> element("#characters-bulk-edit-characters") |> render_click()

      view
      |> element("#bulk-edit-form")
      |> render_change(%{"_target" => ["bulk", "talkativeness"], "bulk" => %{"talkativeness" => "0.2"}})

      assert has_element?(view, "#bulk-edit-form-apply-talkativeness[checked]")

      html =
        view
        |> form("#bulk-edit-form", bulk: %{apply_talkativeness: "true", talkativeness: "0.2"})
        |> render_submit()

      assert html =~ "Updated 2 characters."
      assert Characters.get_character!(a.id).talkativeness == 0.2
      assert Characters.get_character!(b.id).talkativeness == 0.2
      assert Characters.get_character!(c.id).talkativeness == 0.5
      assert Characters.get_character!(a.id).avatar_updates_appearance == nil
    end

    test "refuses an edit with no field ticked", %{conn: conn, a: a} do
      view = select_mode(conn, a)
      tick(view, a)
      view |> element("#characters-bulk-edit-characters") |> render_click()
      view |> form("#bulk-edit-form", bulk: %{talkativeness: "0.9"}) |> render_submit()

      assert has_element?(view, "#bulk-edit-error")
      assert Characters.get_character!(a.id).talkativeness == 0.5
    end

    test "adds and removes tags on the selected rows only", %{conn: conn, scope: scope, a: a, b: b, c: c} do
      :ok = Mythweaver.Tags.set_item_tags(scope, a, :mine, ["keep", "old"])
      :ok = Mythweaver.Tags.set_item_tags(scope, c, :mine, ["old"])

      view = select_mode(conn, a)
      tick(view, a)
      tick(view, b)
      view |> element("#characters-bulk-tags-characters") |> render_click()

      html =
        view
        |> form("#bulk-tags-form")
        |> render_submit(%{"tags" => %{"domain" => "mine", "add" => ["", "Color:Red"], "remove" => ["", "old"]}})

      assert html =~ "Tagged 2 characters."
      refute has_element?(view, "#bulk-tags-modal")
      assert Mythweaver.Tags.item_tags(scope, a).mine == ["color:red", "keep"]
      assert Mythweaver.Tags.item_tags(scope, b).mine == ["color:red"]
      assert Mythweaver.Tags.item_tags(scope, c).mine == ["old"]
    end

    test "refuses invalid or empty tag changes and writes nothing", %{conn: conn, scope: scope, a: a} do
      view = select_mode(conn, a)
      tick(view, a)
      view |> element("#characters-bulk-tags-characters") |> render_click()

      view |> form("#bulk-tags-form") |> render_submit(%{"tags" => %{"add" => [""], "remove" => [""]}})
      assert has_element?(view, "#bulk-tags-error", "Add or remove at least one tag.")

      view |> form("#bulk-tags-form") |> render_submit(%{"tags" => %{"add" => ["-bad"], "remove" => [""]}})
      assert has_element?(view, "#bulk-tags-form-add", "-bad: can't start with -")
      assert Mythweaver.Tags.item_tags(scope, a) == %{site: [], mine: []}
    end

    test "deletes what it can and names what it couldn't", %{conn: conn, user: user, scope: scope, a: a, b: b, c: c} do
      {:ok, _chat} =
        Chats.create_chat(Scope.for_user(user), %{participants: [%{character_id: a.id}, %{character_id: c.id}]})

      view = select_mode(conn, b)
      tick(view, a)
      tick(view, b)
      html = view |> element("#characters-bulk-delete") |> render_click()

      assert html =~ "Deleted 1 character."
      assert html =~ "couldn&#39;t be deleted:"
      assert html =~ "Aqua (In use)"
      assert Characters.get_character(scope, b.id) == nil
      assert Characters.get_character(scope, a.id) != nil
      # The open character was deleted, so the editor falls back to the placeholder.
      assert_patch(view, ~p"/characters")
      assert has_element?(view, "#character-placeholder")
    end
  end

  describe "sharing" do
    # An admin's new character is the site's; sharing is for personal items.
    setup do
      owner = register_user!(%{role: :user})
      %{owner: owner, owner_scope: Scope.for_user(owner), editor: register_user!(%{role: :user})}
    end

    test "the owner invites by handle and an unknown handle is named", %{
      owner: owner,
      owner_scope: scope,
      editor: editor
    } do
      character = character(scope, "Aqua")
      {:ok, view, _html} = live(log_in_user(build_conn(), owner), ~p"/characters/#{character.id}/edit")

      html = view |> form("#character-share-invite", share: %{handle: "@nobody_has_this"}) |> render_submit()
      assert html =~ "No account has that handle."

      view |> form("#character-share-invite", share: %{handle: "@" <> editor.handle}) |> render_submit()
      [share] = Mythweaver.Sharing.list_shares(scope, character)
      assert has_element?(view, "#character-share-#{share.id}")
    end

    test "an editor accepts from the inbox, lands on the item and cannot delete it",
         %{owner_scope: scope, editor: editor} do
      character = character(scope, "Aqua")
      {:ok, share} = Mythweaver.Sharing.invite(scope, character, "@" <> editor.handle)
      [notification] = Mythweaver.Notifications.inbox(Scope.for_user(editor))

      {:ok, view, _html} = live(log_in_user(build_conn(), editor), ~p"/")

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> element("#notification-inbox-accept-#{notification.id}") |> render_click()

      assert to == ~p"/characters/#{character.id}/edit"
      assert Mythweaver.Repo.get(Share, share.id).status == :accepted

      {:ok, view, _html} = live(log_in_user(build_conn(), editor), to)
      assert has_element?(view, "#character-form")
      assert has_element?(view, "#character-share-owner")
      refute has_element?(view, "#delete-character")
    end

    test "an editor sees no role select and invites a Runtime-only subscriber, removable by them",
         %{owner_scope: scope, editor: editor} do
      character = character(scope, "Aqua")
      {:ok, editor_share} = Mythweaver.Sharing.invite(scope, character, editor.handle)
      {:ok, _} = Mythweaver.Sharing.accept(Scope.for_user(editor), editor_share.id)
      other_editor = register_user!(%{role: :user})
      {:ok, other_share} = Mythweaver.Sharing.invite(scope, character, other_editor.handle)
      subscriber = register_user!(%{role: :user})

      {:ok, view, _html} = live(log_in_user(build_conn(), editor), ~p"/characters/#{character.id}/edit")
      refute has_element?(view, "#character-share-invite-role")
      refute has_element?(view, "#character-share-invite-visibility")
      assert has_element?(view, "#character-share-invite-hint")
      assert view |> element("#character-share-invite button[type=submit]") |> render() =~ "Invite subscriber"
      refute has_element?(view, "#character-share-remove-#{other_share.id}")

      view |> form("#character-share-invite", share: %{handle: subscriber.handle}) |> render_submit()

      share = Repo.get_by!(Share, user_id: subscriber.id)
      assert %{role: :subscriber, visibility: :runtime_only, invited_by_id: invited_by} = share
      assert invited_by == editor.id
      assert view |> element("#character-share-#{share.id}") |> render() =~ "Runtime-only"
      assert has_element?(view, "#character-share-remove-#{share.id}")
      refute has_element?(view, "#character-share-visibility-#{share.id}")
    end

    test "the owner invites a Readable subscriber and switches it to Runtime-only and back",
         %{owner: owner, owner_scope: scope, editor: subscriber} do
      character = character(scope, "Aqua")
      {:ok, view, _html} = live(log_in_user(build_conn(), owner), ~p"/characters/#{character.id}/edit")
      refute has_element?(view, "#character-share-invite-visibility")
      refute has_element?(view, "#character-share-invite-hint")

      view |> form("#character-share-invite", share: %{role: "subscriber"}) |> render_change()
      assert has_element?(view, "#character-share-invite-visibility")
      assert has_element?(view, "#character-share-invite-hint")

      view
      |> form("#character-share-invite", share: %{role: "subscriber", visibility: "readable"})
      |> render_change()

      refute has_element?(view, "#character-share-invite-hint")

      view
      |> form("#character-share-invite",
        share: %{handle: subscriber.handle, role: "subscriber", visibility: "readable"}
      )
      |> render_submit()

      share = Repo.get_by!(Share, user_id: subscriber.id)
      assert %{role: :subscriber, visibility: :readable} = share

      view
      |> form("#character-share-visibility-form-#{share.id}", visibility: "runtime_only")
      |> render_change()

      assert Repo.get!(Share, share.id).visibility == :runtime_only

      view
      |> form("#character-share-visibility-form-#{share.id}", visibility: "readable")
      |> render_change()

      assert Repo.get!(Share, share.id).visibility == :readable
    end

    test "deleting with editors opens the Give to modal, oldest preselected, and hands off",
         %{owner: owner, owner_scope: scope, editor: editor} do
      character = character(scope, "Aqua")
      second = register_user!(%{role: :user})

      for {user, accepted_at} <- [{editor, ~U[2026-01-01 00:00:00Z]}, {second, ~U[2026-02-01 00:00:00Z]}] do
        {:ok, share} = Mythweaver.Sharing.invite(scope, character, user.handle)
        {:ok, share} = Mythweaver.Sharing.accept(Scope.for_user(user), share.id)
        share |> Ecto.Changeset.change(accepted_at: accepted_at) |> Repo.update!()
      end

      {:ok, view, _html} = live(log_in_user(build_conn(), owner), ~p"/characters/#{character.id}/edit")
      refute view |> element("#delete-character") |> render() =~ "data-confirm"

      view |> element("#delete-character") |> render_click()
      assert has_element?(view, "#character-handoff-modal")
      assert has_element?(view, "#character-handoff-to option[value='#{second.id}']")
      assert has_element?(view, "#character-handoff-to option[selected][value='#{editor.id}']")

      view |> form("#character-handoff-form") |> render_submit()

      assert_patch(view, ~p"/characters")
      assert render(view) =~ "Given to @#{editor.handle}"
      assert Characters.get_character!(character.id).user_id == editor.id
    end
  end

  test "a held create patches to the list with the review flash and is not listed", %{conn: conn, user: user} do
    {:ok, _rule} =
      Rules.create_rule(Scope.for_user(register_user!()), %{
        "name" => "Words",
        "kind" => "regex",
        "content_types" => ["characters"],
        "pattern" => "forbidden"
      })

    :ok = Mythweaver.Permissions.put_grant!(user, "moderation.characters.restrictive", :allow)
    {:ok, view, _html} = live(conn, ~p"/characters/new")

    html =
      view
      |> form("#character-form", owner: "personal", character: %{name: "Hidden", description: "forbidden"})
      |> render_submit()

    assert_patch(view, ~p"/characters")
    assert html =~ "is waiting for moderator review"
    refute Repo.get_by(Character, name: "Hidden")
    assert has_element?(view, "#nav-submissions")
  end
end
