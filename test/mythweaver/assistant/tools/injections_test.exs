defmodule Mythweaver.Assistant.Tools.InjectionsTest do
  use Mythweaver.DataCase

  alias Mythweaver.Assistant.Tools
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Injections

  defp run!(scope, name, args) do
    {:ok, tool} = Tools.fetch(name)
    Tools.run(scope, tool, args)
  end

  defp chat!(scope) do
    {:ok, a} = Characters.create_character(scope, %{name: "A", description: "d"})
    {:ok, b} = Characters.create_character(scope, %{name: "B", description: "d"})

    {:ok, chat} =
      Chats.create_chat(scope, %{"participants" => [%{"character_id" => a.id}, %{"character_id" => b.id}]})

    chat
  end

  defp create!(scope, chat, attrs) do
    {:ok, %{"done" => [%{"id" => id}]}} =
      run!(scope, "create_injections", %{
        "items" => [Map.merge(%{"chat_id" => chat.id, "key" => "nudge", "content" => "Be brief."}, attrs)]
      })

    id
  end

  setup do
    scope = scope!(%{role: :user})
    %{scope: scope, chat: chat!(scope)}
  end

  test "at_depth keeps depth and role; update changes only given fields", %{scope: scope, chat: chat} do
    id = create!(scope, chat, %{"position" => "at_depth", "depth" => 6, "role" => "user"})

    assert {:ok, %{"done" => [%{"enabled" => false, "depth" => 6, "role" => :user, "content" => "Be brief."}]}} =
             run!(scope, "update_injections", %{"items" => [%{"id" => id, "enabled" => false}]})

    assert {:ok, %{"injections" => [%{"id" => ^id, "active" => false}]}} =
             run!(scope, "list_injections", %{"chat_id" => chat.id})
  end

  test "rearm_injections restores remaining uses", %{scope: scope, chat: chat} do
    id = create!(scope, chat, %{"position" => "after_author_note", "uses" => 2})
    :ok = Injections.spend(chat.id, [id])
    :ok = Injections.spend(chat.id, [id])
    assert Injections.get_injection(scope, id).remaining == 0

    assert {:ok, %{"done" => [%{"remaining" => 2, "active" => true}]}} =
             run!(scope, "rearm_injections", %{"ids" => [id]})
  end

  test "delete removes it; an unknown chat and a bad id are refused", %{scope: scope, chat: chat} do
    id = create!(scope, chat, %{"position" => "after_author_note"})

    assert {:ok, %{"done" => [%{"deleted" => true}]}} = run!(scope, "delete_injections", %{"ids" => [id]})
    assert Injections.get_injection(scope, id) == nil

    assert {:error, %{"error" => "Not found."}} =
             run!(scope, "list_injections", %{"chat_id" => Mythweaver.Schema.generate_id()})

    assert {:error, %{"failed" => [%{"error" => "id is not a valid id"}]}} =
             run!(scope, "update_injections", %{"items" => [%{"id" => "nope"}]})

    assert {:error, %{"failed" => [%{"error" => "id is not a valid id"}]}} =
             run!(scope, "rearm_injections", %{"ids" => ["nope"]})
  end
end
