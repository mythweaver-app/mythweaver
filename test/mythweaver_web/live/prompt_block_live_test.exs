defmodule MythweaverWeb.PromptBlockLiveTest do
  use MythweaverWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Prompts

  setup :register_and_log_in_user

  test "index selects nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/prompts/blocks")

    assert has_element?(view, "#prompt-block-placeholder")
    refute has_element?(view, "#prompt-block-form")
  end

  test "the Kind select hides the template box and reference for chat history", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/prompts/blocks/new")

    assert has_element?(view, "#prompt-block-form-content")
    refute has_element?(view, "#prompt-block-form-speaker_roles")
    assert has_element?(view, "#prompt-block-template-reference")

    view |> form("#prompt-block-form", %{"block" => %{"kind" => "chat_history"}}) |> render_change()

    refute has_element?(view, "#prompt-block-form-content")
    refute has_element?(view, "#prompt-block-template-reference")
    assert has_element?(view, "#prompt-block-form-speaker_roles")

    view |> form("#prompt-block-form", %{"block" => %{"kind" => "template"}}) |> render_change()

    assert has_element?(view, "#prompt-block-form-content")
    assert has_element?(view, "#prompt-block-template-reference")
  end

  test "saving a chat-history block drops any stale content", %{scope: scope, conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/prompts/blocks/new")

    render_submit(view, "save", %{
      "block" => %{
        "name" => "H",
        "role" => "system",
        "kind" => "chat_history",
        "content" => "stale",
        "speaker_roles" => "fixed"
      }
    })

    assert [saved] = Prompts.list_blocks(scope)
    assert saved.kind == :chat_history
    assert saved.content == nil
    assert saved.speaker_roles == :fixed
  end

  test "the template reference lists custom outlets", %{scope: scope, conn: conn} do
    {:ok, _} = Prompts.create_outlet(scope, %{key: "ending", name: "Ending"})

    {:ok, view, _html} = live(conn, ~p"/prompts/blocks/new")

    assert has_element?(view, "#prompt-block-reference-outlet-ending")
  end

  test "the search box matches a block's content, and a chat-history block by its kind", %{scope: scope, conn: conn} do
    {:ok, opening} = Prompts.create_block(scope, %{name: "Opening", content: "Once upon a time"})
    {:ok, history} = Prompts.create_block(scope, %{name: "Transcript", kind: :chat_history})

    {:ok, view, _html} = live(conn, ~p"/prompts/blocks/new")

    view |> form("#prompt-block-filter", %{"query" => "upon a"}) |> render_change()
    assert has_element?(view, "#prompt-blocks-#{opening.id}")
    refute has_element?(view, "#prompt-blocks-#{history.id}")

    view |> form("#prompt-block-filter", %{"query" => "Chat history"}) |> render_change()
    assert has_element?(view, "#prompt-blocks-#{history.id}")
    refute has_element?(view, "#prompt-blocks-#{opening.id}")
  end

  test "preview renders the block as typed, before it is saved", %{scope: scope, conn: conn, user: user} do
    {:ok, alice} = Mythweaver.Characters.create_character(scope, %{name: "Alice"})
    {:ok, bob} = Mythweaver.Characters.create_character(scope, %{name: "Bob"})

    {:ok, _chat} =
      Mythweaver.Chats.create_chat(Scope.for_user(user), %{
        name: "Den",
        participants: [%{character_id: alice.id}, %{character_id: bob.id}],
        player_character_id: alice.id
      })

    {:ok, view, _html} = live(conn, ~p"/prompts/blocks/new")
    refute has_element?(view, "#prompt-block-preview-result")

    view
    |> form("#prompt-block-form", %{
      "block" => %{"content" => "{{ anchors.character.name }} in {{ anchors.chat.name }}"}
    })
    |> render_change()

    view |> form("#prompt-block-preview-form") |> render_submit()

    assert has_element?(view, "#prompt-block-preview-section-0-text", "Bob in Den")
    assert Prompts.list_blocks(scope) == []
  end

  describe "creating a block from a prompt" do
    test "adds the saved block to the end of that prompt and navigates back to it", %{scope: scope, conn: conn} do
      {:ok, prompt} = Prompts.create_prompt(scope, %{name: "Story"})
      {:ok, existing} = Prompts.create_block(scope, %{name: "Existing", content: "already here"})
      {:ok, _} = Prompts.add_block(scope, prompt, existing)

      {:ok, view, _html} = live(conn, ~p"/prompts/blocks/new?#{[prompt_id: prompt.id]}")

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> form("#prompt-block-form", %{
                 "block" => %{"name" => "Fresh", "role" => "system", "content" => "new text"}
               })
               |> render_submit()

      assert to == "/prompts/#{prompt.id}/edit"

      assert prompt |> Prompts.list_prompt_blocks() |> Enum.map(& &1.block.name) ==
               ["Existing", "Fresh"]
    end

    test "Cancel goes back to the prompt without creating anything", %{scope: scope, conn: conn} do
      {:ok, prompt} = Prompts.create_prompt(scope, %{name: "Story"})

      {:ok, view, _html} = live(conn, ~p"/prompts/blocks/new?#{[prompt_id: prompt.id]}")

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> element("#prompt-block-form a", "Cancel") |> render_click()

      assert to == "/prompts/#{prompt.id}/edit"
      assert Prompts.list_blocks(scope) == []
    end

    test "an unknown or malformed prompt_id leaves the plain new-block form", %{scope: scope, conn: conn} do
      for id <- [Mythweaver.Schema.generate_id(), "not-a-uuid"] do
        {:ok, view, _html} = live(conn, ~p"/prompts/blocks/new?#{[prompt_id: id]}")

        refute has_element?(view, "#prompt-block-return-hint")

        view
        |> form("#prompt-block-form", %{
          "block" => %{"name" => "Plain #{id}", "role" => "system", "content" => "text"}
        })
        |> render_submit()

        block = Enum.find(Prompts.list_blocks(scope), &(&1.name == "Plain #{id}"))
        assert_patch(view, "/prompts/blocks/#{block.id}/edit")
      end
    end
  end

  describe "editing a block from a prompt" do
    setup %{scope: scope} do
      {:ok, prompt} = Prompts.create_prompt(scope, %{name: "Story"})
      {:ok, block} = Prompts.create_block(scope, %{name: "Scene", content: "old"})
      {:ok, _} = Prompts.add_block(scope, prompt, block)
      %{prompt: prompt, block: block}
    end

    test "the prompt's edit button returns there after a save", %{
      scope: scope,
      conn: conn,
      prompt: prompt,
      block: block
    } do
      {:ok, prompt_view, _html} = live(conn, ~p"/prompts/#{prompt.id}/edit")
      [membership] = Prompts.list_prompt_blocks(prompt)

      {:ok, view, _html} =
        prompt_view
        |> element("#edit-prompt-block-#{membership.id}")
        |> render_click()
        |> follow_redirect(conn)

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> form("#prompt-block-form", %{"block" => %{"content" => "new"}}) |> render_submit()

      assert to == "/prompts/#{prompt.id}/edit"
      assert Prompts.get_block(scope, block.id).content == "new"
      assert [_one] = Prompts.list_prompt_blocks(prompt)
    end

    test "Cancel returns to the prompt", %{conn: conn, prompt: prompt, block: block} do
      {:ok, view, _html} = live(conn, ~p"/prompts/blocks/#{block.id}/edit?#{[prompt_id: prompt.id]}")

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> element("#prompt-block-form a", "Cancel") |> render_click()

      assert to == "/prompts/#{prompt.id}/edit"
    end

    test "without a prompt_id, saving stays on the block", %{conn: conn, block: block} do
      {:ok, view, _html} = live(conn, ~p"/prompts/blocks/#{block.id}/edit")

      view |> form("#prompt-block-form", %{"block" => %{"content" => "new"}}) |> render_submit()

      assert_patch(view, "/prompts/blocks/#{block.id}/edit")
      refute has_element?(view, "#prompt-block-return-hint")
    end
  end
end
