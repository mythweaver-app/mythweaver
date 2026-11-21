defmodule MythweaverWeb.SharedLiveTest do
  use MythweaverWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.Characters
  alias Mythweaver.Lore
  alias Mythweaver.Permissions
  alias Mythweaver.Repo
  alias Mythweaver.Sharing
  alias Mythweaver.Sharing.Share

  setup do
    owner = register_user!(%{role: :user})
    user = register_user!(%{role: :user})
    %{owner: owner, owner_scope: Scope.for_user(owner), user: user, conn: log_in_user(build_conn(), user)}
  end

  defp character(scope) do
    {:ok, character} =
      Characters.create_character(scope, %{
        name: "Aqua",
        description: "Secret description",
        appearance: "Blue hair",
        creator: "Akatsuki"
      })

    character
  end

  defp share!(owner_scope, item, user, opts) do
    {:ok, share} = Sharing.invite(owner_scope, item, user.handle, opts)
    {:ok, share} = Sharing.accept(Scope.for_user(user), share.id)
    share
  end

  defp ai_model!(scope) do
    {:ok, model} = AI.create_model(scope, %{name: "Gemma", api_model_id: "secret-id"})
    model
  end

  test "lists accepted shares only, and the nav link shows once there is one", %{
    owner_scope: owner_scope,
    user: user,
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/shared")
    refute has_element?(view, "#nav-shared")
    assert render(view) =~ "Nothing is shared with you yet"

    character = character(owner_scope)
    share = share!(owner_scope, character, user, role: :subscriber)
    {:ok, pending} = Characters.create_character(owner_scope, %{name: "Pending"})
    {:ok, _} = Sharing.invite(owner_scope, pending, user.handle, role: :subscriber)

    {:ok, view, _html} = live(conn, ~p"/shared")
    assert has_element?(view, "#nav-shared")
    assert has_element?(view, "#shares-#{share.id}", "Aqua")
    assert has_element?(view, "#shares-#{share.id}", "Subscriber, Runtime-only")
    refute has_element?(view, "#shares", "Pending")
    assert has_element?(view, "#shared-placeholder")
  end

  test "a script card shows a Runtime-only subscriber its capabilities, not its body, and Enable turns it on", %{
    owner_scope: owner_scope,
    user: user,
    conn: conn
  } do
    {:ok, script} =
      Mythweaver.Scripts.create_script(owner_scope, %{
        name: "Peek",
        trigger: :user_message,
        body: "mw.lore.books() return mw.messages.last()"
      })

    share = share!(owner_scope, script, user, role: :subscriber)
    {:ok, view, _html} = live(conn, ~p"/shared/#{share.id}")

    assert has_element?(view, "#shared-card-capabilities", "mw.lore and mw.messages")
    refute render(view) =~ "mw.lore.books()"
    assert has_element?(view, "#toggle-script-#{script.id}[data-confirm*='mw.lore and mw.messages']", "Enable")

    view |> element("#toggle-script-#{script.id}") |> render_click()

    assert has_element?(view, "#toggle-script-#{script.id}", "Disable")
    assert Sharing.toggles(user.id, :script, [script.id]) == %{script.id => true}
  end

  test "a Runtime-only subscriber's card hides the description; a Readable one shows it", %{
    owner_scope: owner_scope,
    user: user,
    conn: conn
  } do
    character = character(owner_scope)
    share = share!(owner_scope, character, user, role: :subscriber)

    {:ok, view, html} = live(conn, ~p"/shared/#{share.id}")
    assert has_element?(view, "#shared-card-creator", "Akatsuki")
    refute has_element?(view, "#shared-card-description")
    refute has_element?(view, "#shared-card-appearance")
    assert has_element?(view, "#shared-card-hidden")
    refute html =~ "Secret description"
    refute html =~ "Blue hair"
    refute has_element?(view, "#shared-edit")

    # The owner's switch reaches the open card.
    {:ok, _} = Sharing.set_visibility(owner_scope, share.id, :readable)
    assert has_element?(view, "#shared-card-description", "Secret description")
    assert has_element?(view, "#shared-card-appearance", "Blue hair")
    refute has_element?(view, "#shared-card-hidden")
  end

  test "a lore book card names its entries and shows their content only when Readable", %{
    owner_scope: owner_scope,
    user: user,
    conn: conn
  } do
    {:ok, book} = Lore.create_book(owner_scope, %{name: "Lore", description: "World notes"})

    {:ok, entry} =
      Lore.create_entry(owner_scope, %{name: "Cave", content: "Hidden cave", keywords: ["cave"]}, [book.id])

    share = share!(owner_scope, book, user, role: :subscriber)

    {:ok, view, html} = live(conn, ~p"/shared/#{share.id}")
    assert has_element?(view, "#shared-card-description", "World notes")
    assert has_element?(view, "#shared-part-#{entry.id}", "Cave")
    refute has_element?(view, "#shared-part-#{entry.id}-content")
    refute html =~ "Hidden cave"

    {:ok, _} = Sharing.set_visibility(owner_scope, share.id, :readable)
    assert has_element?(view, "#shared-part-#{entry.id}-content", "Hidden cave")
    assert has_element?(view, "#shared-part-#{entry.id}-keywords", "cave")
  end

  test "an editor share links to the editor", %{owner_scope: owner_scope, user: user, conn: conn} do
    character = character(owner_scope)
    share = share!(owner_scope, character, user, role: :editor)

    {:ok, view, _html} = live(conn, ~p"/shared/#{share.id}")
    assert has_element?(view, "#shared-edit[href='/characters/#{character.id}/edit']")
    refute has_element?(view, "#shared-card")
  end

  test "Leave removes the share", %{owner_scope: owner_scope, user: user, conn: conn} do
    character = character(owner_scope)
    share = share!(owner_scope, character, user, role: :subscriber)

    {:ok, view, _html} = live(conn, ~p"/shared/#{share.id}")
    view |> element("#shared-leave") |> render_click()

    assert_patch(view, ~p"/shared")
    refute Repo.get(Share, share.id)
    refute has_element?(view, "#shares-#{share.id}")
    refute Characters.get_character(Scope.for_user(user), character.id)
  end

  test "a share ended elsewhere patches the open card to the index", %{
    owner_scope: owner_scope,
    user: user,
    conn: conn
  } do
    character = character(owner_scope)
    share = share!(owner_scope, character, user, role: :subscriber)

    {:ok, view, _html} = live(conn, ~p"/shared/#{share.id}")
    {:ok, _} = Sharing.remove(owner_scope, share.id)

    assert_patch(view, ~p"/shared")
    assert has_element?(view, "#shared-placeholder")
  end

  test "an unknown share id redirects to the index", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/shared", flash: %{"error" => "Share not found"}}}} =
             live(conn, ~p"/shared/#{Ecto.UUID.generate()}")
  end

  test "accepting a subscriber invite from the inbox lands on its card", %{
    owner_scope: owner_scope,
    user: user,
    conn: conn
  } do
    character = character(owner_scope)
    {:ok, share} = Sharing.invite(owner_scope, character, user.handle, role: :subscriber)
    [notification] = Mythweaver.Notifications.inbox(Scope.for_user(user))

    {:ok, view, _html} = live(conn, ~p"/")

    assert {:error, {:live_redirect, %{to: to}}} =
             view |> element("#notification-inbox-accept-#{notification.id}") |> render_click()

    assert to == ~p"/shared/#{share.id}"
  end

  test "Clone shows only on a Readable card and opens the copy's editor", %{
    owner_scope: owner_scope,
    user: user,
    conn: conn
  } do
    character = character(owner_scope)
    share = share!(owner_scope, character, user, role: :subscriber)

    {:ok, view, _html} = live(conn, ~p"/shared/#{share.id}")
    refute has_element?(view, "#shared-clone")

    {:ok, _} = Sharing.set_visibility(owner_scope, share.id, :readable)
    assert {:error, {:live_redirect, %{to: to}}} = view |> element("#shared-clone") |> render_click()

    assert [copy] = Characters.list_characters(Scope.for_user(user)) |> Enum.filter(&(&1.user_id == user.id))
    assert copy.cloned_from_id == character.id
    assert to == "/characters/#{copy.id}/edit"
  end

  test "the site section lists site content and Hide takes it out of the viewer's lists", %{
    user: user,
    conn: conn
  } do
    admin = Scope.for_user(register_user!(%{role: :admin}))
    {:ok, site} = Characters.create_character(admin, %{name: "Site Hero"}, site: true)
    scope = Scope.for_user(user)

    {:ok, view, _html} = live(conn, ~p"/shared")
    assert has_element?(view, "#site-items #site-item-character-#{site.id}", "Site Hero")
    assert has_element?(view, "#site-clone-character-#{site.id}")
    assert Enum.any?(Characters.list_characters(scope), &(&1.id == site.id))

    view |> element("#site-opt-out-character-#{site.id}") |> render_click()
    assert has_element?(view, "#site-item-character-#{site.id}", "Nothing of yours uses it.")
    view |> element("#site-opt-out-confirm-character-#{site.id}") |> render_click()

    refute Enum.any?(Characters.list_characters(scope), &(&1.id == site.id))
    assert has_element?(view, "#site-opt-out-character-#{site.id}", "Restore")

    view |> element("#site-opt-out-character-#{site.id}") |> render_click()
    assert Enum.any?(Characters.list_characters(scope), &(&1.id == site.id))
  end

  describe "AI model shares" do
    setup %{owner: owner, user: user} do
      for account <- [owner, user], do: :ok = Permissions.put_grant!(account, "ai.connections.create", :allow)
      %{owner_scope: Scope.for_user(owner), user_scope: Scope.for_user(user)}
    end

    test "an own-key card connects one of the viewer's connections and removes the link", %{
      owner_scope: owner_scope,
      user_scope: user_scope,
      user: user,
      conn: conn
    } do
      share = share!(owner_scope, ai_model!(owner_scope), user, role: :subscriber)

      {:ok, provider} =
        AI.create_provider(user_scope, %{
          name: "My key",
          adapter: :openai_compatible,
          base_url: "http://localhost:8080/v1"
        })

      {:ok, view, _html} = live(conn, ~p"/shared/#{share.id}")

      assert has_element?(view, "#shared-ai-mode", "your own connection")
      assert has_element?(view, "#shared-links-empty")

      view |> form("#shared-connect", connect: %{provider_id: provider.id}) |> render_submit()

      assert [link] = AI.list_own_links(user_scope, AI.get_model!(share.item_id))
      assert has_element?(view, "#shared-links #shared-link-#{link.id}", "My key")
      refute has_element?(view, "#shared-connect")

      view |> element("#shared-unlink-#{link.id}") |> render_click()

      assert AI.list_own_links(user_scope, AI.get_model!(share.item_id)) == []
      refute has_element?(view, "#shared-link-#{link.id}")
      assert has_element?(view, "#shared-connect")
    end

    test "an owner-key card names the owner's connection and the daily limit", %{
      owner: owner,
      user: user,
      conn: conn
    } do
      :ok = Permissions.put_grant!(owner, "sharing.ai.owner_key", :allow)
      owner_scope = Scope.for_user(owner)
      model = ai_model!(owner_scope)
      limited = share!(owner_scope, model, user, role: :subscriber, ai_mode: :owner_key, token_limit_per_day: 2000)

      {:ok, view, _html} = live(conn, ~p"/shared/#{limited.id}")

      assert has_element?(view, "#shared-ai-mode", "Runs on @#{owner.handle}'s connection")
      assert has_element?(view, "#shared-ai-limit", "Daily limit: 2,000 tokens")
      refute has_element?(view, "#shared-connect")

      {:ok, _share} = Sharing.set_ai_mode(owner_scope, limited.id, :owner_key, nil)
      assert has_element?(view, "#shared-ai-limit", "No daily limit")
    end
  end
end
