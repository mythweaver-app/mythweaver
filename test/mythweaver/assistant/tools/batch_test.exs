defmodule Mythweaver.Assistant.Tools.BatchTest do
  use Mythweaver.DataCase

  alias Mythweaver.Assistant.Tools
  alias Mythweaver.Characters
  alias Mythweaver.Lore
  alias Mythweaver.Schema

  defp run!(scope, name, args) do
    {:ok, tool} = Tools.fetch(name)
    Tools.run(scope, tool, args)
  end

  defp preview(scope, name, args) do
    {:ok, tool} = Tools.fetch(name)
    tool.preview.(scope, args)
  end

  defp entry!(scope, name) do
    {:ok, %{"done" => [%{"id" => id}]}} =
      run!(scope, "create_lore_entries", %{
        "items" => [%{"name" => name, "content" => "About #{name}.", "keywords" => [name]}]
      })

    id
  end

  defp character!(scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: name})
    character
  end

  setup do
    %{scope: scope!()}
  end

  test "a single-row write's card names its row as stored, not as the call names it", %{scope: scope} do
    a = character!(scope, "Aqua")
    b = character!(scope, "Kazuma")
    unknown = Schema.generate_id()

    assert preview(scope, "create_chat", %{"character_ids" => [a.id, b.id, unknown]}) ==
             ["Aqua", "Kazuma", "Not found: #{inspect(unknown)}"]

    {:ok, %{"id" => chat_id}} = run!(scope, "create_chat", %{"name" => "Guild", "character_ids" => [a.id, b.id]})

    assert preview(scope, "update_chat", %{"id" => chat_id, "name" => "Renamed", "reply_strategy" => "list"}) ==
             [~s|Guild: name "Renamed", reply strategy "list"|]
  end

  test "delete_lore_entries deletes every listed entry and reports the unknown one", %{scope: scope} do
    castle = entry!(scope, "Castle")
    river = entry!(scope, "River")
    unknown = Schema.generate_id()

    assert preview(scope, "delete_lore_entries", %{"ids" => [castle, river, unknown]}) ==
             ["Castle", "River", "Not found: #{inspect(unknown)}"]

    assert {:ok, %{"done" => [_, _], "failed" => [%{"index" => 2, "id" => ^unknown, "error" => "Not found."}]}} =
             run!(scope, "delete_lore_entries", %{"ids" => [castle, river, unknown]})

    refute Lore.get_entry(scope, castle)
    refute Lore.get_entry(scope, river)
  end

  test "a batch where every item fails is an error, with each failure named", %{scope: scope} do
    a = character!(scope, "Aqua")
    b = character!(scope, "Kazuma")
    {:ok, _} = run!(scope, "create_chat", %{"character_ids" => [a.id, b.id]})

    assert {:error, %{"error" => "Nothing was done" <> _, "done" => [], "failed" => failed}} =
             run!(scope, "delete_characters", %{"ids" => [a.id, b.id]})

    assert Enum.map(failed, & &1["name"]) == ["Aqua", "Kazuma"]
    assert Characters.get_character(scope, a.id)
  end

  test "update_lore_entries applies each item's own fields and fails an item without an id", %{scope: scope} do
    castle = entry!(scope, "Castle")
    river = entry!(scope, "River")

    items = [
      %{"id" => castle, "keywords" => ["keep"]},
      %{"id" => river, "name" => "Stream"},
      %{"name" => "No id"}
    ]

    assert preview(scope, "update_lore_entries", %{"items" => items}) == [
             "Castle: keywords (1 items)",
             ~s(River: name "Stream"),
             "No id"
           ]

    assert {:ok, %{"done" => [_, _], "failed" => [%{"index" => 2, "error" => "missing argument: id"}]}} =
             run!(scope, "update_lore_entries", %{"items" => items})

    assert %{name: "Castle", keywords: ["keep"]} = Lore.get_entry(scope, castle)
    assert %{name: "Stream"} = Lore.get_entry(scope, river)
  end

  test "create_lore_entries creates each item", %{scope: scope} do
    items = [
      %{"name" => "Castle", "content" => "Stone.", "keywords" => ["castle"]},
      %{"name" => "River", "content" => "Water.", "activation" => "constant"}
    ]

    assert {:ok, %{"done" => [%{"id" => castle}, %{"id" => river}], "failed" => []}} =
             run!(scope, "create_lore_entries", %{"items" => items})

    assert %{name: "Castle", content: "Stone."} = Lore.get_entry(scope, castle)
    assert %{name: "River"} = Lore.get_entry(scope, river)
  end

  test "an empty or oversized list is refused before anything runs", %{scope: scope} do
    castle = entry!(scope, "Castle")

    assert {:error, %{"error" => "ids must be a list of 1 to 100 entries"}} =
             run!(scope, "delete_lore_entries", %{"ids" => []})

    ids = [castle | Enum.map(1..100, fn _ -> Schema.generate_id() end)]

    assert {:error, %{"error" => "ids must be a list of 1 to 100 entries"}} =
             run!(scope, "delete_lore_entries", %{"ids" => ids})

    assert Lore.get_entry(scope, castle)
  end
end
