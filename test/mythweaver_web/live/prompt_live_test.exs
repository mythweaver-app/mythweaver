defmodule MythweaverWeb.PromptLiveTest do
  use MythweaverWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Prompts
  alias Mythweaver.Prompts.Binding
  alias Mythweaver.Schema

  setup :register_and_log_in_user

  test "index selects nothing and lists every prompt", %{scope: scope, conn: conn} do
    second = prompt(scope, "Zeta")
    first = prompt(scope, "Alpha")

    {:ok, view, _html} = live(conn, ~p"/prompts")

    assert has_element?(view, "#prompt-placeholder")
    refute has_element?(view, "#prompt-form")
    assert has_element?(view, "#prompts-#{first.id}")
    assert has_element?(view, "#prompts-#{second.id}")
    refute has_element?(view, "#prompts li a[aria-current='page']")
  end

  test "duplicating a prompt opens the edit form for the copy", %{scope: scope, conn: conn} do
    {:ok, prompt} = Prompts.create_prompt(scope, %{name: "Scene 3"})
    {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}/edit")

    render_click(element(view, "#duplicate-prompt-#{prompt.id}"))

    copy = Enum.find(Prompts.list_prompts(scope), &(&1.name == "Scene 4"))
    assert copy
    assert_patched(view, ~p"/prompts/#{copy.id}/edit")
    assert has_element?(view, "#prompt-form")
    assert has_element?(view, "#prompt-form-name[value='Scene 4']")
  end

  test "the search box narrows the list by name or description and keeps the selection",
       %{conn: conn, scope: scope} do
    {:ok, story} = Prompts.create_prompt(scope, %{name: "Story", description: "Long-form narration"})
    {:ok, terse} = Prompts.create_prompt(scope, %{name: "Terse", description: "Short replies"})

    {:ok, view, _html} = live(conn, ~p"/prompts/#{story.id}/edit")

    view |> form("#prompt-filter", %{"query" => "NARRATION"}) |> render_change()
    assert has_element?(view, "#prompts-#{story.id} a[aria-current='page']")
    refute has_element?(view, "#prompts-#{terse.id}")

    view |> form("#prompt-filter", %{"query" => "nothing like this"}) |> render_change()
    refute has_element?(view, "#prompts-#{story.id}")
    assert has_element?(view, "#prompts-nav .pane-empty")
    refute has_element?(view, "#prompts li[id]")

    view |> form("#prompt-filter", %{"query" => "  "}) |> render_change()
    assert has_element?(view, "#prompts-#{story.id}")
    assert has_element?(view, "#prompts-#{terse.id}")
  end

  test "the type select narrows the list to one purpose, together with the search", %{scope: scope, conn: conn} do
    {:ok, chat} = Prompts.create_prompt(scope, %{name: "Story"})
    {:ok, summary} = Prompts.create_prompt(scope, %{name: "Memory: Summary", purpose: :memory})
    {:ok, minimal} = Prompts.create_prompt(scope, %{name: "Memory: Minimal", purpose: :memory})

    {:ok, view, _html} = live(conn, ~p"/prompts/#{chat.id}/edit")

    view |> form("#prompt-filter", %{"purpose" => "roleplay"}) |> render_change()
    assert has_element?(view, "#prompts-#{chat.id}")
    refute has_element?(view, "#prompts-#{summary.id}")

    view |> form("#prompt-filter", %{"query" => "summary", "purpose" => "memory"}) |> render_change()
    assert has_element?(view, "#prompts-#{summary.id}")
    refute has_element?(view, "#prompts-#{minimal.id}")
    refute has_element?(view, "#prompts-#{chat.id}")

    view |> form("#prompt-filter", %{"query" => "", "purpose" => ""}) |> render_change()
    assert has_element?(view, "#prompts-#{chat.id}")
    assert has_element?(view, "#prompts-#{minimal.id}")
  end

  test "saving a memory purpose tags the row and hides the bindings", %{scope: scope, conn: conn} do
    prompt = prompt(scope, "Summary")
    {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}/edit")
    assert has_element?(view, "#prompt-bindings-form")

    view |> form("#prompt-form", %{"prompt" => %{"purpose" => "memory"}}) |> render_submit()

    assert Prompts.get_prompt!(prompt.id).purpose == :memory
    assert has_element?(view, "#prompts-#{prompt.id}-purpose", "Memory")
    refute has_element?(view, "#prompt-bindings-form")
  end

  describe "composition" do
    test "a block already in the prompt is not offered again", %{scope: scope, conn: conn} do
      prompt = prompt(scope, "Partial")
      taken = block(scope, "Taken")
      free = block(scope, "Free")
      {:ok, _} = Prompts.add_block(scope, prompt, taken)

      {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}/edit")

      assert has_element?(view, "#prompt-add-block-form option[value='#{free.id}']")
      refute has_element?(view, "#prompt-add-block-form option[value='#{taken.id}']")

      view |> form("#prompt-add-block-form", %{"block_id" => free.id}) |> render_submit()

      assert positions(prompt) == [{0, taken.name}, {1, free.name}]
      refute has_element?(view, "#prompt-add-block-form option[value='#{free.id}']")
    end

    test "removing a block closes the gap in the rendered order", %{scope: scope, conn: conn} do
      prompt = prompt(scope, "Ordered")
      [a, b, c] = Enum.map(~w(Alpha Beta Gamma), &block(scope, &1))
      for blk <- [a, b, c], do: {:ok, _} = Prompts.add_block(scope, prompt, blk)

      {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}/edit")
      middle = membership(prompt, b)

      view
      |> element("button[phx-click=remove_block][phx-value-id='#{middle.id}']")
      |> render_click()

      assert positions(prompt) == [{0, a.name}, {1, c.name}]
    end

    # A chat binding needs a personal prompt: chats are owned, and a site prompt binds only to site
    # targets. So this runs as a plain user, whose prompts, characters and chat are all their own.
    test "binding a prompt to a character in a chat is what resolve_prompt returns", %{conn: conn} do
      user = register_user!(%{role: :user})
      conn = log_in_user(conn, user)
      scope = Scope.for_user(user)
      prompt = prompt(scope, "Bound")
      hero = character(scope, "Hero")
      foil = character(scope, "Foil")
      chat = chat(user, [hero, foil])

      {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}/edit")

      view
      |> form("#prompt-bindings-form", %{"scope" => "character_in_chat"})
      |> render_change()

      view
      |> form("#prompt-bindings-form", %{
        "scope" => "character_in_chat",
        "character_id" => foil.id,
        "chat_id" => chat.id
      })
      |> render_submit()

      assert Prompts.resolve_prompt(%{character: foil, chat: chat}).id == prompt.id
      assert [binding] = Prompts.list_bindings(scope, prompt)
      assert has_element?(view, "#prompt-bindings-#{binding.id}")
    end

    test "a user's chat binding of a site prompt is hidden from and locked to the admin",
         %{scope: admin, user: admin_user, conn: conn} do
      prompt = prompt(admin, "Site", site: true)
      user = register_user!(%{role: :user})
      user_scope = Scope.for_user(user)
      hero = character(admin, "Hero", site: true)
      chat = chat(user, [hero, character(admin, "Foil", site: true)])
      # A user binds a site prompt the way chat settings do: they may use it but not edit it.
      {:ok, :ok} = Prompts.set_chat_prompt(chat, prompt.id)
      binding = Mythweaver.Repo.get_by!(Binding, chat_id: chat.id)

      {:ok, view, html} = live(conn, ~p"/prompts/#{prompt.id}/edit")

      refute html =~ chat.name
      refute has_element?(view, "#prompt-bindings-#{binding.id}")
      assert Prompts.list_bindings(admin, prompt) == []
      assert Prompts.get_binding(admin, binding.id) == nil
      assert {:error, :unauthorized} = Prompts.unbind_prompt(admin, binding)

      assert [%{id: id}] = Prompts.list_bindings(user_scope, prompt)
      assert id == binding.id

      own = chat(admin_user, [hero, character(admin, "Other", site: true)])
      {:ok, mine} = Prompts.bind_prompt(admin, prompt, :chat, chat_id: own.id)
      assert [%{id: mine_id}] = Prompts.list_bindings(admin, prompt)
      assert mine_id == mine.id
      assert {:ok, _} = Prompts.unbind_prompt(admin, Prompts.get_binding(admin, mine.id))
    end

    test "a binding missing its required target is refused with the scope error", %{scope: scope, conn: conn} do
      prompt = prompt(scope, "Bound")

      {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}/edit")

      view
      |> form("#prompt-bindings-form", %{"scope" => "chat"})
      |> render_change()

      html =
        view
        |> form("#prompt-bindings-form", %{"scope" => "chat", "chat_id" => ""})
        |> render_submit()

      assert html =~ "a chat binding needs chat_id"
      assert Prompts.list_bindings(scope, prompt) == []
    end

    test "toggling a membership off leaves the row but disables the block", %{scope: scope, conn: conn} do
      prompt = prompt(scope, "Toggled")
      only = block(scope, "Alpha")
      {:ok, _} = Prompts.add_block(scope, prompt, only)

      {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}/edit")
      row = membership(prompt, only)

      view
      |> element("#toggle-prompt-block-#{row.id}")
      |> render_click()

      assert membership(prompt, only).enabled == false
      assert has_element?(view, "#prompt-prompt-blocks-#{row.id}.prompt-block-row--disabled")
      assert has_element?(view, "#toggle-prompt-block-#{row.id}[aria-pressed=false]")
    end

    test "an unknown prompt id redirects to the index", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/prompts"}}} =
               live(conn, ~p"/prompts/#{Schema.generate_id()}/edit")
    end

    test "a drag reorder persists the dropped order", %{scope: scope, conn: conn} do
      prompt = prompt(scope, "Ordered")
      [a, b, c] = Enum.map(~w(Alpha Beta Gamma), &block(scope, &1))
      for blk <- [a, b, c], do: {:ok, _} = Prompts.add_block(scope, prompt, blk)

      {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}/edit")

      view
      |> element("#prompt-blocks")
      |> render_hook("reorder_blocks", %{"ids" => [c.id, a.id, b.id]})

      assert positions(prompt) == [{0, c.name}, {1, a.name}, {2, b.name}]
      assert rendered_names(view) == [c.name, a.name, b.name]
    end

    test "a drag order that is not a permutation is refused and the rows snap back",
         %{conn: conn, scope: scope} do
      prompt = prompt(scope, "Ordered")
      [a, b] = Enum.map(~w(Alpha Beta), &block(scope, &1))
      for blk <- [a, b], do: {:ok, _} = Prompts.add_block(scope, prompt, blk)

      {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}/edit")

      view
      |> element("#prompt-blocks")
      |> render_hook("reorder_blocks", %{"ids" => [b.id]})

      assert positions(prompt) == [{0, a.name}, {1, b.name}]
      assert rendered_names(view) == [a.name, b.name]
    end
  end

  describe "preview" do
    test "renders each section of the saved prompt for the chosen chat", %{scope: scope, conn: conn, user: user} do
      hero = character(scope, "Hero")
      foil = character(scope, "Foil")
      chat = chat(user, [hero, foil])
      prompt = prompt(scope, "Story")
      {:ok, block} = Prompts.create_block(scope, %{name: "Who-#{unique()}", content: "{{ anchors.character.name }}"})
      {:ok, broken} = Prompts.create_block(scope, %{name: "Broken-#{unique()}", content: "{{ x | roll }}"})
      {:ok, _} = Prompts.add_block(scope, prompt, block)
      {:ok, _} = Prompts.add_block(scope, prompt, broken)

      {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}/edit")

      view
      |> form("#prompt-preview-form", %{"preview" => %{"chat_id" => chat.id, "character_id" => hero.id}})
      |> render_change()

      view |> form("#prompt-preview-form") |> render_submit()

      assert has_element?(view, "#prompt-preview-section-0-text", hero.name)
      assert has_element?(view, "#prompt-preview-section-1-error-0", "roll expects dice")
    end

    test "the Text mode shows the whole prompt as one string, ending on the responder's cue", %{
      scope: scope,
      conn: conn,
      user: user
    } do
      hero = character(scope, "Hero")
      foil = character(scope, "Foil")
      chat = chat(user, [hero, foil])
      prompt = prompt(scope, "Story")
      {:ok, one} = Prompts.create_block(scope, %{name: "One-#{unique()}", content: "First."})
      {:ok, two} = Prompts.create_block(scope, %{name: "Two-#{unique()}", content: "{{ anchors.chat.name }}"})
      {:ok, _} = Prompts.add_block(scope, prompt, one)
      {:ok, _} = Prompts.add_block(scope, prompt, two)

      {:ok, view, _html} = live(conn, ~p"/prompts/#{prompt.id}/edit")

      view
      |> form("#prompt-preview-form", %{"preview" => %{"chat_id" => chat.id, "character_id" => ""}})
      |> render_change()

      view |> form("#prompt-preview-form") |> render_submit()
      refute has_element?(view, "#prompt-preview-text")

      render_click(element(view, "#prompt-preview-view-text"))

      refute has_element?(view, "#prompt-preview-sections")
      text = view |> element("#prompt-preview-text") |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()
      assert text == "First.\n\n#{chat.name}\n\n#{foil.name}:"

      render_click(element(view, "#prompt-preview-view-blocks"))
      assert has_element?(view, "#prompt-preview-section-1-text", chat.name)
    end
  end

  ## Helpers

  defp unique, do: System.unique_integer([:positive])

  # The block names in `#prompt-blocks` in render order. Scoped to the row-name element rather than
  # scanned out of the whole page: a name also appears in a flash and in the add-block select, so a
  # document-wide substring search would report a false order.
  defp rendered_names(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#prompt-blocks .prompt-block-name")
    |> Enum.map(&String.trim(LazyHTML.text(&1)))
  end

  defp positions(prompt) do
    prompt
    |> Prompts.list_prompt_blocks()
    |> Enum.map(&{&1.position, &1.block.name})
  end

  defp membership(prompt, block) do
    Enum.find(Prompts.list_prompt_blocks(prompt), &(&1.block_id == block.id))
  end

  defp prompt(scope, name, opts \\ []) do
    {:ok, prompt} = Prompts.create_prompt(scope, %{name: "#{name}-#{unique()}"}, opts)
    prompt
  end

  defp block(scope, name) do
    {:ok, block} = Prompts.create_block(scope, %{name: "#{name}-#{unique()}", content: "#{name} text"})
    block
  end

  defp character(scope, name, opts \\ []) do
    {:ok, character} = Characters.create_character(scope, %{name: "#{name}-#{unique()}"}, opts)
    character
  end

  defp chat(user, [player | _] = characters) do
    {:ok, chat} =
      Chats.create_chat(Scope.for_user(user), %{
        name: "chat-#{unique()}",
        participants: Enum.map(characters, &%{character_id: &1.id}),
        player_character_id: player.id
      })

    Chats.get_chat!(chat.id)
  end
end
