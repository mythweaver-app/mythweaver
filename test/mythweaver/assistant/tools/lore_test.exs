defmodule Mythweaver.Assistant.Tools.LoreTest do
  use Mythweaver.DataCase

  alias Mythweaver.Assistant.Tools
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Lore

  defp run!(scope, name, args) do
    {:ok, tool} = Tools.fetch(name)
    Tools.run(scope, tool, args)
  end

  defp book!(scope, attrs, opts \\ []) do
    {:ok, book} = Lore.create_book(scope, attrs, opts)
    book
  end

  defp entry!(scope, name, book_ids \\ []) do
    {:ok, entry} = Lore.create_entry(scope, %{name: name, content: "c", keywords: [name]}, book_ids)
    entry
  end

  defp character!(scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: name, description: "d"})
    character
  end

  defp chat!(scope) do
    a = character!(scope, "A")
    b = character!(scope, "B")

    {:ok, chat} =
      Chats.create_chat(scope, %{"participants" => [%{"character_id" => a.id}, %{"character_id" => b.id}]})

    chat
  end

  defp pool!(scope, attrs) do
    {:ok, pool} = Lore.create_pool(scope, attrs)
    pool
  end

  defp book_entry_ids(scope, book) do
    {:ok, %{"lore_entries" => rows}} = run!(scope, "list_lore_entries", %{"book_id" => book.id})
    Enum.map(rows, & &1["id"])
  end

  setup do
    %{scope: scope!()}
  end

  test "create_lore_books creates the book", %{scope: scope} do
    assert {:ok, %{"done" => [%{"id" => id, "name" => "Realm", "path" => path}]}} =
             run!(scope, "create_lore_books", %{"items" => [%{"name" => "Realm", "priority" => 4}]})

    assert path == "/lore/#{id}/edit"
    assert %{name: "Realm", priority: 4} = Lore.get_book(scope, id)
  end

  test "update_lore_books changes only the given fields", %{scope: scope} do
    book = book!(scope, %{name: "Realm", description: "The world", priority: 4})

    assert {:ok, %{"done" => [%{"name" => "Kingdom"}]}} =
             run!(scope, "update_lore_books", %{"items" => [%{"id" => book.id, "name" => "Kingdom"}]})

    assert %{name: "Kingdom", description: "The world", priority: 4} = Lore.get_book(scope, book.id)
  end

  test "create_lore_entries puts the entry in the book with default outlet and placement", %{scope: scope} do
    book = book!(scope, %{name: "Realm"})

    assert {:ok, %{"done" => [%{"id" => entry_id, "book_ids" => [book_id]}]}} =
             run!(scope, "create_lore_entries", %{
               "items" => [
                 %{"book_id" => book.id, "name" => "Castle", "content" => "A tall castle.", "keywords" => ["castle"]}
               ]
             })

    assert book_id == book.id
    assert %{outlet: :character, placement: :before} = Lore.get_entry(scope, entry_id)

    assert {:ok, %{"entries" => [%{"id" => ^entry_id, "name" => "Castle", "keywords" => ["castle"]}]}} =
             run!(scope, "get_lore_book", %{"id" => book.id})
  end

  describe "list_lore_entries" do
    setup %{scope: scope} do
      realm = book!(scope, %{name: "Realm"})
      other = book!(scope, %{name: "Other"})

      for {name, books} <- [
            {"Castle Gate", [realm.id]},
            {"Castle", [realm.id]},
            {"Moat", [realm.id]},
            {"Castle Keep", [other.id]},
            {"Loose castle", []}
          ] do
        {:ok, _} =
          Lore.create_entry(
            scope,
            %{name: name, content: "x", activation: :constant, outlet: :character, placement: :before},
            books,
            %{}
          )
      end

      %{realm: realm}
    end

    defp names({:ok, %{"lore_entries" => rows}}), do: Enum.map(rows, & &1["name"])

    test "with book_id lists only that book's entries", %{scope: scope, realm: realm} do
      assert scope |> run!("list_lore_entries", %{"book_id" => realm.id}) |> names() |> Enum.sort() ==
               ["Castle", "Castle Gate", "Moat"]
    end

    test "query matches a name substring ignoring case, an exact name first", %{scope: scope, realm: realm} do
      assert names(run!(scope, "list_lore_entries", %{"query" => "castle"})) ==
               ["Castle", "Castle Gate", "Castle Keep", "Loose castle"]

      assert names(run!(scope, "list_lore_entries", %{"book_id" => realm.id, "query" => "CASTLE"})) |> hd() == "Castle"
      assert names(run!(scope, "list_lore_entries", %{"query" => "  "})) |> length() == 5
    end

    test "list_lore_books takes the same query", %{scope: scope} do
      assert {:ok, %{"lore_books" => [%{"name" => "Realm"}], "total" => 1}} =
               run!(scope, "list_lore_books", %{"query" => "rea"})
    end
  end

  describe "set_lore_entries_enabled" do
    setup %{scope: scope} do
      a = book!(scope, %{name: "A"})
      b = book!(scope, %{name: "B"})
      {:ok, entry} = Lore.create_entry(scope, %{name: "Castle", content: "Stone.", keywords: ["castle"]}, [a.id, b.id])
      %{a: a, b: b, entry: entry}
    end

    defp entry_enabled(scope, book, entry) do
      {:ok, %{"entries" => rows}} = run!(scope, "get_lore_book", %{"id" => book.id})
      Enum.find(rows, &(&1["id"] == entry.id))["enabled"]
    end

    test "with book_id switches only that book's membership", %{scope: scope, a: a, b: b, entry: entry} do
      assert {:ok, %{"done" => [%{"disabled_book_ids" => [disabled]}]}} =
               run!(scope, "set_lore_entries_enabled", %{
                 "items" => [%{"id" => entry.id, "enabled" => false, "book_id" => a.id}]
               })

      assert disabled == a.id
      assert entry_enabled(scope, a, entry) == false
      assert entry_enabled(scope, b, entry) == true
    end

    test "without book_id switches every book", %{scope: scope, a: a, b: b, entry: entry} do
      assert {:ok, %{"done" => [%{"disabled_book_ids" => disabled}]}} =
               run!(scope, "set_lore_entries_enabled", %{"items" => [%{"id" => entry.id, "enabled" => false}]})

      assert Enum.sort(disabled) == Enum.sort([a.id, b.id])
    end

    test "refuses a book the entry is not in and an unlinked entry", %{scope: scope, entry: entry} do
      other = book!(scope, %{name: "C"})
      {:ok, unlinked} = Lore.create_entry(scope, %{name: "Loose", content: "Nowhere.", keywords: ["loose"]}, [])

      assert {:error, %{"failed" => [%{"error" => "The entry is not in that book."}]}} =
               run!(scope, "set_lore_entries_enabled", %{
                 "items" => [%{"id" => entry.id, "enabled" => false, "book_id" => other.id}]
               })

      assert {:error, %{"failed" => [%{"error" => "The entry is in no book, so it never activates."}]}} =
               run!(scope, "set_lore_entries_enabled", %{"items" => [%{"id" => unlinked.id, "enabled" => false}]})
    end
  end

  test "a non-UUID id gives an error map", %{scope: scope} do
    assert {:error, %{"error" => "id is not a valid id"}} = run!(scope, "get_lore_book", %{"id" => "nope"})

    assert {:error, %{"failed" => [%{"error" => "id is not a valid id"}]}} =
             run!(scope, "update_lore_entries", %{"items" => [%{"id" => "nope", "name" => "x"}]})

    assert {:error, %{"failed" => [%{"error" => "book_id is not a valid id"}]}} =
             run!(scope, "create_lore_entries", %{"items" => [%{"book_id" => "nope", "name" => "x", "content" => "y"}]})
  end

  describe "fields" do
    test "update_lore_books accepts site_visibility, forced and tag_filter_mode on a site book", %{scope: scope} do
      book = book!(scope, %{name: "Site realm"}, site: true)

      assert {:ok, %{"done" => [%{"site_visibility" => :hidden, "forced" => true, "tag_filter_mode" => :include}]}} =
               run!(scope, "update_lore_books", %{
                 "items" => [
                   %{"id" => book.id, "site_visibility" => "hidden", "forced" => true, "tag_filter_mode" => "include"}
                 ]
               })

      assert %{site_visibility: :hidden, forced: true, tag_filter_mode: :include} =
               Lore.get_editable_book(scope, book.id)
    end

    test "update_lore_books refuses forced on a personal book" do
      user = scope!(%{role: :user})
      book = book!(user, %{name: "Mine"})

      assert {:error, %{"failed" => [%{"error" => "invalid", "fields" => %{forced: [_]}}]}} =
               run!(user, "update_lore_books", %{"items" => [%{"id" => book.id, "forced" => true}]})
    end

    test "update_lore_entries accepts the scheduling and filter-mode fields", %{scope: scope} do
      entry = entry!(scope, "Castle")

      attrs = %{
        "secondary_logic" => "not_any",
        "sticky" => 2,
        "cooldown" => 3,
        "delay" => 4,
        "exclude_recursion" => true,
        "prevent_recursion" => true,
        "character_filter_mode" => "exclude",
        "ignore_budget" => true,
        "match_whole_words" => true,
        "outlet" => "custom",
        "custom_outlet" => "diary"
      }

      assert {:ok, %{"done" => [_]}} =
               run!(scope, "update_lore_entries", %{"items" => [Map.put(attrs, "id", entry.id)]})

      assert %{
               secondary_logic: :not_any,
               sticky: 2,
               cooldown: 3,
               delay: 4,
               exclude_recursion: true,
               prevent_recursion: true,
               character_filter_mode: :exclude,
               ignore_budget: true,
               match_whole_words: true,
               custom_outlet: "diary"
             } = Lore.get_editable_entry(scope, entry.id)
    end

    test "update_lore_entries accepts role, trigger_only and delay_until_recursion", %{scope: scope} do
      entry = entry!(scope, "Castle")

      assert {:ok, %{"done" => [%{"role" => :user, "trigger_only" => true, "delay_until_recursion" => 2}]}} =
               run!(scope, "update_lore_entries", %{
                 "items" => [
                   %{"id" => entry.id, "role" => "user", "trigger_only" => true, "delay_until_recursion" => 2}
                 ]
               })

      assert %{role: :user, trigger_only: true, delay_until_recursion: 2} = Lore.get_editable_entry(scope, entry.id)
    end

    test "lore book results carry the read-only kind", %{scope: scope} do
      book = book!(scope, %{name: "Realm"})

      assert {:ok, %{"done" => [%{"kind" => :lore}]}} =
               run!(scope, "update_lore_books", %{"items" => [%{"id" => book.id, "kind" => "card"}]})

      assert %{kind: :lore} = Lore.get_editable_book(scope, book.id)
    end
  end

  describe "memberships and order" do
    test "set_lore_entry_books replaces an entry's books", %{scope: scope} do
      a = book!(scope, %{name: "A"})
      b = book!(scope, %{name: "B"})
      entry = entry!(scope, "Castle")

      assert {:ok, %{"done" => [%{"book_ids" => ids}]}} =
               run!(scope, "set_lore_entry_books", %{"items" => [%{"id" => entry.id, "book_ids" => [a.id, b.id]}]})

      assert Enum.sort(ids) == Enum.sort([a.id, b.id])

      assert {:ok, %{"done" => [%{"book_ids" => []}]}} =
               run!(scope, "set_lore_entry_books", %{"items" => [%{"id" => entry.id, "book_ids" => []}]})
    end

    test "reorder_lore_book_entries renumbers in the given order and refuses a non-permutation", %{scope: scope} do
      book = book!(scope, %{name: "A"})
      [x, y, z] = for name <- ~w(X Y Z), do: entry!(scope, name, [book.id])

      assert {:ok, %{"reordered" => true}} =
               run!(scope, "reorder_lore_book_entries", %{"book_id" => book.id, "entry_ids" => [y.id, z.id, x.id]})

      assert book_entry_ids(scope, book) == [y.id, z.id, x.id]

      assert {:error, %{"error" => "The ids must list every current item exactly once, in the new order."}} =
               run!(scope, "reorder_lore_book_entries", %{"book_id" => book.id, "entry_ids" => [y.id, x.id]})
    end

    test "set_lore_entry_order sets the order in one book only", %{scope: scope} do
      a = book!(scope, %{name: "A"})
      b = book!(scope, %{name: "B"})
      shared = entry!(scope, "Shared", [a.id, b.id])
      top = entry!(scope, "Top", [a.id, b.id])

      assert book_entry_ids(scope, a) == [top.id, shared.id]

      assert {:ok, %{"done" => [_]}} =
               run!(scope, "set_lore_entry_order", %{
                 "items" => [%{"id" => shared.id, "book_id" => a.id, "order" => 50}]
               })

      assert book_entry_ids(scope, a) == [shared.id, top.id]
      assert book_entry_ids(scope, b) == [top.id, shared.id]

      other = book!(scope, %{name: "C"})

      assert {:error, %{"failed" => [%{"error" => "The entry is not in that book."}]}} =
               run!(scope, "set_lore_entry_order", %{
                 "items" => [%{"id" => shared.id, "book_id" => other.id, "order" => 1}]
               })
    end
  end

  describe "bindings and filters" do
    test "set_lore_book_chats binds, set_lore_bindings_enabled disables, and [] unbinds", %{scope: scope} do
      book = book!(scope, %{name: "A"})
      chat = chat!(scope)

      assert {:ok, %{"done" => [%{"chat_ids" => [chat_id]}]}} =
               run!(scope, "set_lore_book_chats", %{"items" => [%{"id" => book.id, "chat_ids" => [chat.id]}]})

      assert chat_id == chat.id

      assert {:ok, %{"done" => [%{"enabled" => false}]}} =
               run!(scope, "set_lore_bindings_enabled", %{
                 "items" => [%{"book_id" => book.id, "kind" => "chat", "target_id" => chat.id, "enabled" => false}]
               })

      assert {:ok, %{"chat_ids" => [^chat_id], "disabled_chat_ids" => [^chat_id]}} =
               run!(scope, "get_lore_book", %{"id" => book.id})

      assert {:ok, %{"done" => [%{"chat_ids" => []}]}} =
               run!(scope, "set_lore_book_chats", %{"items" => [%{"id" => book.id, "chat_ids" => []}]})
    end

    test "set_lore_book_characters binds and unbinds", %{scope: scope} do
      book = book!(scope, %{name: "A"})
      character = character!(scope, "Hero")

      assert {:ok, %{"done" => [%{"character_ids" => [id]}]}} =
               run!(scope, "set_lore_book_characters", %{
                 "items" => [%{"id" => book.id, "character_ids" => [character.id]}]
               })

      assert id == character.id

      assert {:error, %{"failed" => [%{"error" => "That book is not bound to that chat."}]}} =
               run!(scope, "set_lore_bindings_enabled", %{
                 "items" => [%{"book_id" => book.id, "kind" => "chat", "target_id" => character.id, "enabled" => false}]
               })

      assert {:ok, %{"done" => [%{"character_ids" => []}]}} =
               run!(scope, "set_lore_book_characters", %{"items" => [%{"id" => book.id, "character_ids" => []}]})
    end

    test "set_lore_entry_filters sets character and tag filters", %{scope: scope} do
      entry = entry!(scope, "Castle")
      character = character!(scope, "Hero")

      assert {:ok, %{"done" => [%{"filter_character_ids" => [id], "filter_tags" => []}]}} =
               run!(scope, "set_lore_entry_filters", %{
                 "items" => [%{"id" => entry.id, "character_ids" => [character.id]}]
               })

      assert id == character.id

      assert {:ok, %{"done" => [%{"filter_character_ids" => [^id], "filter_tags" => ["series:metroid"]}]}} =
               run!(scope, "set_lore_entry_filters", %{"items" => [%{"id" => entry.id, "tags" => ["series:metroid"]}]})

      assert {:error, %{"failed" => [%{"error" => "character_ids or tags is required."}]}} =
               run!(scope, "set_lore_entry_filters", %{"items" => [%{"id" => entry.id}]})
    end

    test "set_lore_book_filter_tags replaces the book's tag filter", %{scope: scope} do
      book = book!(scope, %{name: "A"})

      assert {:ok, %{"done" => [%{"filter_tags" => ["dark"]}]}} =
               run!(scope, "set_lore_book_filter_tags", %{"items" => [%{"id" => book.id, "tags" => ["dark"]}]})

      assert {:ok, %{"done" => [%{"filter_tags" => []}]}} =
               run!(scope, "set_lore_book_filter_tags", %{"items" => [%{"id" => book.id, "tags" => []}]})
    end
  end

  describe "pools" do
    test "create, update, list and delete", %{scope: scope} do
      assert {:ok, %{"done" => [%{"id" => id, "max_activations" => 2}]}} =
               run!(scope, "create_lore_pools", %{"items" => [%{"name" => "Weather", "max_activations" => 2}]})

      assert {:ok, %{"done" => [%{"name" => "Climate", "max_activations" => 2}]}} =
               run!(scope, "update_lore_pools", %{"items" => [%{"id" => id, "name" => "Climate"}]})

      assert {:ok, %{"lore_pools" => [%{"id" => ^id, "entry_count" => 0}]}} = run!(scope, "list_lore_pools", %{})

      assert {:ok, %{"done" => [%{"deleted" => true}]}} = run!(scope, "delete_lore_pools", %{"ids" => [id]})
      assert Lore.get_pool(scope, id) == nil
    end

    test "set_lore_entry_pools and set_lore_pool_weights", %{scope: scope} do
      pool = pool!(scope, %{name: "Weather"})
      entry = entry!(scope, "Rain")

      assert {:ok, %{"done" => [%{"pool_ids" => [pool_id]}]}} =
               run!(scope, "set_lore_entry_pools", %{"items" => [%{"id" => entry.id, "pool_ids" => [pool.id]}]})

      assert pool_id == pool.id

      assert {:ok, %{"done" => [%{"weight" => 7, "override" => true, "scored" => false}]}} =
               run!(scope, "set_lore_pool_weights", %{
                 "items" => [%{"id" => pool.id, "entry_id" => entry.id, "weight" => 7, "override" => true}]
               })

      assert {:ok, %{"done" => [%{"weight" => 7, "override" => true, "scored" => true}]}} =
               run!(scope, "set_lore_pool_weights", %{
                 "items" => [%{"id" => pool.id, "entry_id" => entry.id, "scored" => true}]
               })

      assert {:ok, %{"entries" => [%{"id" => entry_id, "weight" => 7}]}} =
               run!(scope, "get_lore_pool", %{"id" => pool.id})

      assert entry_id == entry.id

      other = entry!(scope, "Snow")

      assert {:error, %{"failed" => [%{"error" => "That entry is not in that pool."}]}} =
               run!(scope, "set_lore_pool_weights", %{
                 "items" => [%{"id" => pool.id, "entry_id" => other.id, "weight" => 1}]
               })
    end
  end

  test "transfer_lore_books moves a personal book to the site, once", %{scope: scope} do
    book = book!(scope, %{name: "Realm"})
    entry!(scope, "Castle", [book.id])

    assert {:ok, %{"done" => [%{"owner" => "site", "impact" => %{"entries" => 1}}]}} =
             run!(scope, "transfer_lore_books", %{"items" => [%{"id" => book.id}]})

    assert Lore.get_editable_book(scope, book.id).user_id == nil

    assert {:error, %{"failed" => [%{"error" => "It already has that owner."}]}} =
             run!(scope, "transfer_lore_books", %{"items" => [%{"id" => book.id}]})
  end
end
