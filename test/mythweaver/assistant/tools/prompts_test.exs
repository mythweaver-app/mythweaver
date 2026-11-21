defmodule Mythweaver.Assistant.Tools.PromptsTest do
  use Mythweaver.DataCase

  alias Mythweaver.Assistant.Tools
  alias Mythweaver.Prompts

  defp run!(scope, name, args) do
    {:ok, tool} = Tools.fetch(name)
    Tools.run(scope, tool, args)
  end

  defp prompt!(scope, attrs) do
    {:ok, prompt} = Prompts.create_prompt(scope, attrs)
    prompt
  end

  defp block!(scope, name) do
    {:ok, block} = Prompts.create_block(scope, %{name: name, kind: :template, role: :system, content: name})
    block
  end

  defp blocks(scope, prompt) do
    {:ok, %{"blocks" => blocks}} = run!(scope, "get_prompt", %{"id" => prompt.id})
    blocks
  end

  setup do
    %{scope: scope!()}
  end

  test "create_prompts then a partial update keeps the other fields", %{scope: scope} do
    assert {:ok, %{"done" => [%{"id" => id, "path" => "/prompts/" <> _}]}} =
             run!(scope, "create_prompts", %{"items" => [%{"name" => "Story", "description" => "Narrator setup"}]})

    assert {:ok, %{"done" => [%{"thinking" => :low}]}} =
             run!(scope, "update_prompts", %{"items" => [%{"id" => id, "name" => "Saga", "thinking" => "low"}]})

    assert %{name: "Saga", description: "Narrator setup", thinking: :low} = Prompts.get_prompt(scope, id)
  end

  test "create_prompt_blocks with prompt_id appends the block to the prompt", %{scope: scope} do
    prompt = prompt!(scope, %{name: "Story"})
    prompt_id = prompt.id

    assert {:ok, %{"done" => [%{"id" => block_id, "prompt_id" => ^prompt_id}]}} =
             run!(scope, "create_prompt_blocks", %{
               "items" => [
                 %{
                   "name" => "Intro",
                   "kind" => "template",
                   "role" => "system",
                   "content" => "You narrate.",
                   "prompt_id" => prompt_id
                 }
               ]
             })

    assert [%{"block_id" => ^block_id, "name" => "Intro", "membership_id" => _}] = blocks(scope, prompt)
  end

  test "update_prompt_blocks changes kind and speaker_roles", %{scope: scope} do
    block = block!(scope, "History")

    assert {:ok, %{"done" => [%{"kind" => :chat_history, "speaker_roles" => :fixed}]}} =
             run!(scope, "update_prompt_blocks", %{
               "items" => [%{"id" => block.id, "kind" => "chat_history", "speaker_roles" => "fixed"}]
             })
  end

  test "update_prompt_blocks sets and clears role_tag and forbid_overrides", %{scope: scope} do
    block = block!(scope, "Main")

    assert {:ok, %{"done" => [%{"role_tag" => :main, "forbid_overrides" => true}]}} =
             run!(scope, "update_prompt_blocks", %{
               "items" => [%{"id" => block.id, "role_tag" => "main", "forbid_overrides" => true}]
             })

    assert {:ok, %{"done" => [%{"role_tag" => nil}]}} =
             run!(scope, "update_prompt_blocks", %{"items" => [%{"id" => block.id, "role_tag" => nil}]})
  end

  test "duplicate_prompts copies the block list", %{scope: scope} do
    prompt = prompt!(scope, %{name: "Story"})
    {:ok, _} = Prompts.add_block(scope, prompt, block!(scope, "Intro"))

    assert {:ok, %{"done" => [%{"id" => copy_id}]}} = run!(scope, "duplicate_prompts", %{"ids" => [prompt.id]})
    assert copy_id != prompt.id
    assert [_] = blocks(scope, %{id: copy_id})
  end

  describe "memberships" do
    test "add, toggle and remove a block; the block itself stays", %{scope: scope} do
      prompt = prompt!(scope, %{name: "Story"})
      block = block!(scope, "Intro")

      assert {:ok, %{"done" => [%{"membership_id" => membership_id, "block_id" => block_id}]}} =
               run!(scope, "add_prompt_blocks", %{"items" => [%{"id" => block.id, "prompt_id" => prompt.id}]})

      assert block_id == block.id

      assert {:ok, %{"done" => [%{"enabled" => false}]}} =
               run!(scope, "update_prompt_block_memberships", %{
                 "items" => [%{"id" => membership_id, "enabled" => false}]
               })

      assert [%{"enabled" => false}] = blocks(scope, prompt)

      assert {:ok, %{"done" => [%{"deleted" => true}]}} =
               run!(scope, "remove_prompt_blocks", %{"ids" => [membership_id]})

      assert blocks(scope, prompt) == []
      assert Prompts.get_block(scope, block.id)
    end

    test "reorder_prompt_blocks reorders and rejects a non-permutation", %{scope: scope} do
      prompt = prompt!(scope, %{name: "Story"})
      [one, two] = for name <- ~w(One Two), do: block!(scope, name)
      for block <- [one, two], do: {:ok, _} = Prompts.add_block(scope, prompt, block)

      assert {:ok, %{"reordered" => true}} =
               run!(scope, "reorder_prompt_blocks", %{"id" => prompt.id, "block_ids" => [two.id, one.id]})

      assert Enum.map(blocks(scope, prompt), & &1["block_id"]) == [two.id, one.id]

      assert {:error, %{"error" => "The ids must list every current item exactly once, in the new order."}} =
               run!(scope, "reorder_prompt_blocks", %{"id" => prompt.id, "block_ids" => [two.id]})
    end
  end

  describe "bindings" do
    test "bind, list and unbind a roleplay prompt", %{scope: scope} do
      prompt = prompt!(scope, %{name: "Story", purpose: :roleplay})

      assert {:ok, %{"done" => [%{"id" => binding_id, "scope" => "global"}]}} =
               run!(scope, "bind_prompts", %{"items" => [%{"id" => prompt.id, "scope" => "global"}]})

      assert {:ok, %{"bindings" => [%{"id" => ^binding_id, "scope" => "global"}]}} =
               run!(scope, "list_prompt_bindings", %{"id" => prompt.id})

      assert {:ok, %{"done" => [%{"deleted" => true}]}} = run!(scope, "unbind_prompts", %{"ids" => [binding_id]})
      assert {:ok, %{"bindings" => []}} = run!(scope, "list_prompt_bindings", %{"id" => prompt.id})
    end

    test "bind_prompts refuses a non-roleplay prompt and an unknown scope", %{scope: scope} do
      memory = prompt!(scope, %{name: "Memory", purpose: :memory})

      assert {:error, %{"failed" => [%{"error" => "Only a roleplay prompt can be bound."}]}} =
               run!(scope, "bind_prompts", %{"items" => [%{"id" => memory.id, "scope" => "global"}]})

      assert {:error, %{"failed" => [%{"error" => "scope must be one of" <> _}]}} =
               run!(scope, "bind_prompts", %{"items" => [%{"id" => memory.id, "scope" => "everywhere"}]})
    end
  end

  test "outlets: create, update, read, list and delete", %{scope: scope} do
    assert {:ok, %{"done" => [%{"id" => id, "path" => path}]}} =
             run!(scope, "create_prompt_outlets", %{"items" => [%{"key" => "diary", "name" => "Diary"}]})

    assert path == "/prompts/outlets/#{id}/edit"

    assert {:ok, %{"done" => [%{"name" => "Journal", "key" => "diary"}]}} =
             run!(scope, "update_prompt_outlets", %{"items" => [%{"id" => id, "name" => "Journal"}]})

    assert {:ok, %{"key" => "diary", "name" => "Journal"}} = run!(scope, "get_prompt_outlet", %{"id" => id})
    assert {:ok, %{"outlets" => outlets}} = run!(scope, "list_prompt_outlets", %{"query" => "journ"})
    assert Enum.any?(outlets, &(&1["id"] == id))

    assert {:ok, %{"done" => [%{"deleted" => true}]}} = run!(scope, "delete_prompt_outlets", %{"ids" => [id]})
    assert Prompts.get_outlet(scope, id) == nil
  end

  test "an unknown purpose is an error" do
    assert {:error, %{"error" => "unknown purpose" <> _}} = run!(scope!(), "list_prompts", %{"purpose" => "bogus"})
  end

  test "a non-UUID id is an error map" do
    assert {:error, %{"failed" => [%{"error" => "id is not a valid id"}]}} =
             run!(scope!(), "update_prompts", %{"items" => [%{"id" => "nope"}]})
  end

  test "a runtime-only block's content, and every block's in a runtime-only prompt, is hidden from plain users" do
    admin = scope!(%{role: :admin})
    user = scope!(%{role: :user})

    site_block = fn name, visibility ->
      {:ok, block} =
        Prompts.create_block(
          admin,
          %{name: name, kind: :template, role: :system, content: "#{name} text", site_visibility: visibility},
          site: true
        )

      block
    end

    secret = site_block.("Secret", :runtime_only)
    open = site_block.("Open", :readable)
    {:ok, story} = Prompts.create_prompt(admin, %{name: "Story"}, site: true)
    {:ok, sealed} = Prompts.create_prompt(admin, %{name: "Sealed", site_visibility: :runtime_only}, site: true)
    for block <- [secret, open], do: {:ok, _} = Prompts.add_block(admin, story, block)
    {:ok, _} = Prompts.add_block(admin, sealed, open)

    assert [%{"name" => "Secret", "content" => nil}, %{"name" => "Open", "content" => "Open text"}] =
             blocks(user, story)

    assert [%{"name" => "Open", "content" => nil}] = blocks(user, sealed)

    {:ok, %{"blocks" => rows}} = run!(user, "list_prompt_blocks", %{})
    contents = Map.new(rows, &{&1["name"], &1["content"]})
    assert %{"Secret" => nil, "Open" => "Open text"} = contents

    assert [%{"content" => "Secret text"}, %{"content" => "Open text"}] = blocks(admin, story)
    assert [%{"content" => "Open text"}] = blocks(admin, sealed)
  end
end
