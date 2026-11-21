defmodule Mythweaver.Assistant.Tools.NavigationTest do
  use Mythweaver.DataCase

  alias Mythweaver.Assistant.Tools

  defp open(args) do
    {:ok, tool} = Tools.fetch("open_page")
    Tools.run(scope!(%{role: :user}), tool, args)
  end

  test "a singular page needs an id" do
    assert {:error, %{"error" => _}} = open(%{"page" => "character"})

    id = Ecto.UUID.generate()
    assert {:ok, %{"path" => path, "label" => "Character"}} = open(%{"page" => "character", "id" => id})
    assert path == "/characters/#{id}/edit"

    memory_id = Mythweaver.Schema.generate_id()
    assert {:ok, %{"path" => memory_path}} = open(%{"page" => "chat_memory", "id" => memory_id})
    assert memory_path == "/chats/#{memory_id}/memory"
  end

  test "a non-UUID record id gives an error map" do
    assert {:error, %{"error" => "id is not a valid id"}} = open(%{"page" => "lore_book", "id" => "x"})
  end

  test "index and settings pages" do
    assert {:ok, %{"path" => "/ai/providers"}} = open(%{"page" => "ai_connections"})
    assert {:ok, %{"path" => "/settings"}} = open(%{"page" => "settings"})
    assert {:ok, %{"path" => "/settings/models"}} = open(%{"page" => "settings", "id" => "models"})
    assert {:ok, %{"path" => "/analytics"}} = open(%{"page" => "analytics"})
  end
end
