defmodule Mythweaver.Assistant.Tools.MemoryTest do
  use Mythweaver.DataCase

  alias Mythweaver.Assistant.Tools
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Lore
  alias Mythweaver.Memory
  alias Mythweaver.Prompts

  defp run!(scope, name, args) do
    {:ok, tool} = Tools.fetch(name)
    Tools.run(scope, tool, args)
  end

  defp profile!(scope, name) do
    {:ok, profile} = Memory.create_profile(scope, %{name: name})
    profile
  end

  defp prompt!(scope, purpose) do
    {:ok, prompt} =
      Prompts.create_prompt(scope, %{name: "#{purpose} #{System.unique_integer([:positive])}", purpose: purpose})

    prompt
  end

  defp side_prompt!(scope, name) do
    {:ok, side_prompt} = Memory.create_side_prompt(scope, %{name: name, prompt_id: prompt!(scope, :side_prompt).id})
    side_prompt
  end

  defp chat!(scope) do
    {:ok, a} = Characters.create_character(scope, %{name: "A", description: "d"})
    {:ok, b} = Characters.create_character(scope, %{name: "B", description: "d"})

    {:ok, chat} =
      Chats.create_chat(scope, %{"participants" => [%{"character_id" => a.id}, %{"character_id" => b.id}]})

    chat
  end

  setup do
    %{scope: scope!(%{role: :user})}
  end

  describe "profiles" do
    test "create then a partial update keeps other fields", %{scope: scope} do
      assert {:ok, %{"done" => [%{"id" => id, "name" => "P", "default" => false, "path" => path}]}} =
               run!(scope, "create_memory_profiles", %{"items" => [%{"name" => "P", "title_format" => "{{title}}"}]})

      assert path == "/memory/profiles/#{id}/edit"

      assert {:ok, %{"done" => [%{"max_tokens" => 10, "title_format" => "{{title}}"}]}} =
               run!(scope, "update_memory_profiles", %{"items" => [%{"id" => id, "max_tokens" => 10}]})

      assert {:ok, %{"name" => "P", "max_tokens" => 10}} = run!(scope, "get_memory_profile", %{"id" => id})
    end

    test "set_default_memory_profile moves the default", %{scope: scope} do
      first = profile!(scope, "First")
      second = profile!(scope, "Second")

      assert {:ok, %{"default" => true}} = run!(scope, "set_default_memory_profile", %{"id" => first.id})
      assert {:ok, %{"default" => true}} = run!(scope, "set_default_memory_profile", %{"id" => second.id})

      assert [second.id] == for(p <- Memory.list_profiles(scope), p.default, do: p.id)
    end

    test "a prompt of the wrong purpose is refused, and delete removes the row", %{scope: scope} do
      roleplay = prompt!(scope, :roleplay)

      assert {:error, %{"failed" => [%{"error" => "invalid", "fields" => %{memory_prompt_id: [_]}}]}} =
               run!(scope, "create_memory_profiles", %{
                 "items" => [%{"name" => "Bad", "memory_prompt_id" => roleplay.id}]
               })

      profile = profile!(scope, "Gone")

      assert {:ok, %{"done" => [%{"deleted" => true}]}} =
               run!(scope, "delete_memory_profiles", %{"ids" => [profile.id]})

      assert Memory.get_profile(scope, profile.id) == nil
    end

    test "list filters by name and a non-UUID id is an error map", %{scope: scope} do
      profile!(scope, "Long memories")
      profile!(scope, "Short")

      assert {:ok, %{"memory_profiles" => [%{"name" => "Long memories"}], "total" => 1}} =
               run!(scope, "list_memory_profiles", %{"query" => "LONG"})

      assert {:error, %{"error" => "id is not a valid id"}} = run!(scope, "get_memory_profile", %{"id" => "nope"})

      assert {:error, %{"failed" => [%{"error" => "id is not a valid id"}]}} =
               run!(scope, "update_memory_profiles", %{"items" => [%{"id" => "nope"}]})
    end
  end

  describe "side prompts" do
    test "create, update and delete", %{scope: scope} do
      prompt = prompt!(scope, :side_prompt)

      assert {:ok, %{"done" => [%{"id" => id, "path" => path}]}} =
               run!(scope, "create_side_prompts", %{"items" => [%{"name" => "Diary", "prompt_id" => prompt.id}]})

      assert path == "/memory/side-prompts/#{id}/edit"

      assert {:ok, %{"done" => [%{"interval" => 12, "name" => "Diary"}]}} =
               run!(scope, "update_side_prompts", %{"items" => [%{"id" => id, "interval" => 12}]})

      assert {:ok, %{"done" => [%{"deleted" => true}]}} = run!(scope, "delete_side_prompts", %{"ids" => [id]})
      assert Memory.get_side_prompt(scope, id) == nil
    end

    test "a prompt of the wrong purpose is refused", %{scope: scope} do
      roleplay = prompt!(scope, :roleplay)

      assert {:error, %{"failed" => [%{"error" => "invalid", "fields" => %{prompt_id: [_]}}]}} =
               run!(scope, "create_side_prompts", %{"items" => [%{"name" => "Bad", "prompt_id" => roleplay.id}]})
    end
  end

  describe "side prompt sets" do
    test "create with rows, then update replaces them", %{scope: scope} do
      first = side_prompt!(scope, "First")
      second = side_prompt!(scope, "Second")

      assert {:ok, %{"done" => [%{"id" => id, "rows" => [row]}]}} =
               run!(scope, "create_side_prompt_sets", %{
                 "items" => [%{"name" => "Set", "rows" => [%{"side_prompt_id" => first.id, "label" => "NPC"}]}]
               })

      assert %{"side_prompt_id" => first_id, "label" => "NPC", "side_prompt_name" => "First"} = row
      assert first_id == first.id

      assert {:ok, %{"done" => [%{"rows" => [%{"side_prompt_name" => "Second"}]}]}} =
               run!(scope, "update_side_prompt_sets", %{
                 "items" => [%{"id" => id, "rows" => [%{"side_prompt_id" => second.id}]}]
               })

      assert {:ok, %{"rows" => [%{"side_prompt_name" => "Second"}]}} = run!(scope, "get_side_prompt_set", %{"id" => id})

      assert {:ok, %{"done" => [%{"deleted" => true}]}} = run!(scope, "delete_side_prompt_sets", %{"ids" => [id]})
    end

    test "another user's side prompt is refused", %{scope: scope} do
      theirs = side_prompt!(scope!(%{role: :user}), "Theirs")

      assert {:error, %{"failed" => [%{"error" => "You are not allowed to do that."}]}} =
               run!(scope, "create_side_prompt_sets", %{
                 "items" => [%{"name" => "Set", "rows" => [%{"side_prompt_id" => theirs.id}]}]
               })
    end
  end

  describe "chat memory settings" do
    test "first read returns defaults", %{scope: scope} do
      chat = chat!(scope)
      chat_id = chat.id

      assert {:ok, %{"chat_id" => ^chat_id, "auto_hide" => :none, "side_prompt_set_mode" => :default} = settings} =
               run!(scope, "get_chat_memory_settings", %{"chat_id" => chat.id})

      assert settings["path"] == "/chats/#{chat.id}/memory"
      assert %{"auto_interval" => _} = settings["effective_auto"]
    end

    test "update sets the memory book and broadcasts", %{scope: scope} do
      chat = chat!(scope)
      {:ok, book} = Lore.create_book(scope, %{name: "Memories"})
      Phoenix.PubSub.subscribe(Mythweaver.PubSub, Memory.topic(chat.id))

      assert {:ok, %{"done" => [%{"memory_book_id" => book_id}]}} =
               run!(scope, "update_chat_memory_settings", %{
                 "items" => [%{"id" => chat.id, "memory_book_id" => book.id}]
               })

      assert book_id == book.id
      chat_id = chat.id
      assert_receive {:memory_changed, ^chat_id}
    end

    test "another user's book and an unknown chat are refused", %{scope: scope} do
      chat = chat!(scope)
      {:ok, theirs} = Lore.create_book(scope!(%{role: :user}), %{name: "Theirs"})

      assert {:error, %{"failed" => [%{"error" => "You are not allowed to do that."}]}} =
               run!(scope, "update_chat_memory_settings", %{
                 "items" => [%{"id" => chat.id, "memory_book_id" => theirs.id}]
               })

      assert Memory.chat_settings(scope, chat).memory_book_id == nil

      assert {:error, %{"failed" => [%{"error" => "Not found."}]}} =
               run!(scope, "update_chat_memory_settings", %{
                 "items" => [%{"id" => Mythweaver.Schema.generate_id(), "auto_enabled" => true}]
               })
    end
  end
end
