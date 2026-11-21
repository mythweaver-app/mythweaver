defmodule Mythweaver.ImportTest do
  use Mythweaver.DataCase

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Attachments.CharacterAttachment
  alias Mythweaver.Characters
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats
  alias Mythweaver.Import
  alias Mythweaver.Lore.BookCharacter
  alias Mythweaver.Lore.BookEntry
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Lore.LorePool
  alias Mythweaver.Memory.Consolidation
  alias Mythweaver.Memory.Record
  alias Mythweaver.Messages
  alias Mythweaver.Moderation.Holds
  alias Mythweaver.Moderation.Rules
  alias Mythweaver.Prompts
  alias Mythweaver.Prompts.PromptBlock

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
       )

  setup do
    %{scope: scope!()}
  end

  defp card_png(chunks) do
    body = binary_part(@png, 0, byte_size(@png) - 12)
    iend = binary_part(@png, byte_size(@png) - 12, 12)

    text =
      Enum.map_join(chunks, fn {keyword, value} ->
        data = keyword <> <<0>> <> value
        <<byte_size(data)::32, "tEXt", data::binary, :erlang.crc32("tEXt" <> data)::32>>
      end)

    body <> text <> iend
  end

  defp encode(map), do: map |> Jason.encode!() |> Base.encode64()

  defp v2(name, data), do: %{"spec" => "chara_card_v2", "data" => Map.merge(%{"name" => name}, data)}

  defp import!(scope, filename, bytes, opts \\ []) do
    {:ok, parsed} = Import.parse(filename, bytes)
    {:ok, result} = Import.import(scope, parsed, opts)
    result
  end

  defp avatar_id(character) do
    Repo.one(
      from l in CharacterAttachment,
        where: l.character_id == ^character.id and l.role == :avatar,
        select: l.attachment_id
    )
  end

  defp bound_books(character) do
    Repo.all(
      from b in LoreBook,
        join: bc in BookCharacter,
        on: bc.lore_book_id == b.id,
        where: bc.character_id == ^character.id,
        order_by: b.name
    )
  end

  # {entry, membership} pairs of a book, in membership order of insertion.
  defp members(book) do
    Repo.all(
      from be in BookEntry,
        join: e in LoreEntry,
        on: e.id == be.lore_entry_id,
        where: be.lore_book_id == ^book.id,
        order_by: e.id,
        select: {e, be}
    )
  end

  describe "characters" do
    test "a V2 PNG imports columns, the avatar and a bound card book", %{scope: scope} do
      card =
        v2("Ann", %{
          "description" => "Tall {{user}}",
          "creator" => "me",
          "personality" => "Kind",
          "mes_example" => "<START>\nA: hi",
          "post_history_instructions" => "Stay",
          "extensions" => %{"talkativeness" => "0.7"},
          "character_book" => %{"entries" => [%{"keys" => ["k"], "content" => "Lore", "enabled" => true}]}
        })

      assert %{kind: :character, record: ann, warnings: []} =
               import!(scope, "ann.png", card_png([{"chara", encode(card)}]))

      assert %{
               name: "Ann",
               description: "Tall {{ anchors.player.name }}",
               creator: "me",
               talkativeness: 0.7,
               post_history_instructions: "Stay",
               source_file: "ann"
             } = Characters.get_character!(ann.id)

      assert avatar_id(ann)

      assert [%{name: "Ann (card)", kind: :card} = card_book, %{name: "Ann (lore)"} = lore_book] = bound_books(ann)

      slots = Map.new(members(card_book), fn {entry, _} -> {entry.name, LoreEntry.slot(entry)} end)

      assert slots == %{"Personality" => "after_character", "Example dialogue" => "after_examples"}
      assert [{%{name: "k", content: "Lore"}, %{enabled: true}}] = members(lore_book)
    end

    test "the import stores the import-only fields", %{scope: scope} do
      card =
        v2("Ann", %{
          "personality" => "Kind",
          "extensions" => %{"other_tool" => %{"a" => 1}},
          "character_book" => %{
            "entries" => [%{"keys" => ["k"], "content" => "Lore", "enabled" => true, "extra" => 1}],
            "kept" => true
          }
        })

      %{record: ann} = import!(scope, "ann.json", Jason.encode!(card))
      assert %{source_file: "ann", foreign: %{"extensions" => %{"other_tool" => %{"a" => 1}}}} = ann

      assert [%{kind: :card}, %{kind: :lore, foreign: %{"character_book" => %{"kept" => true}}} = lore] =
               bound_books(ann)

      assert [{%{foreign: %{"character_book" => %{"entry" => %{"extra" => 1}}}}, _}] = members(lore)
    end

    test "ccv3 beats chara, and a second import gets a unique card book name", %{scope: scope} do
      png =
        card_png([
          {"chara", encode(v2("Old", %{"scenario" => "S"}))},
          {"ccv3", encode(%{v2("New", %{"scenario" => "S"}) | "spec" => "chara_card_v3"})}
        ])

      assert %{record: %{name: "New"} = first} = import!(scope, "x.png", png)
      assert %{record: %{name: "New"} = second} = import!(scope, "x.png", png)
      assert [%{name: "New (card)"}] = bound_books(first)
      assert [%{name: "New (card) (2)"}] = bound_books(second)
    end

    test "V1 and Pygmalion JSON", %{scope: scope} do
      v1 = Jason.encode!(%{"name" => "Bob", "description" => "D", "creatorcomment" => "note", "talkativeness" => 3})
      assert %{record: bob} = import!(scope, "bob.json", v1)
      assert %{name: "Bob", description: "D", creator_notes: "note", talkativeness: 1.0} = bob
      assert bound_books(bob) == []
      refute avatar_id(bob)

      pyg = Jason.encode!(%{"char_name" => "Pyg", "char_persona" => "P", "world_scenario" => "S"})
      assert %{record: %{name: "Pyg", description: "P"} = pyg} = import!(scope, "p.json", pyg)
      assert [book] = bound_books(pyg)
      assert [{%{name: "Scenario", content: "S", activation: :constant}, _}] = members(book)
    end

    test "a CHARX's icon becomes the avatar", %{scope: scope} do
      card = %{
        "spec" => "chara_card_v3",
        "data" => %{
          "name" => "Zip",
          "assets" => [%{"type" => "icon", "name" => "main", "uri" => "embeded://assets/icon/main.png"}]
        }
      }

      {:ok, {_name, zip}} =
        :zip.create(~c"x.charx", [{~c"card.json", Jason.encode!(card)}, {~c"assets/icon/main.png", @png}], [:memory])

      assert %{record: zip_character, warnings: []} = import!(scope, "zip.charx", zip)
      assert avatar_id(zip_character)
    end

    test "an import's avatar is held to the importer's upload permissions" do
      user = scope!(%{role: :user})
      :ok = Mythweaver.Permissions.put_grant!(user.user, "uploads.images", :deny)
      user = user.user.id |> Mythweaver.Accounts.get_user() |> Scope.for_user()

      card = %{
        "spec" => "chara_card_v3",
        "data" => %{
          "name" => "Denied",
          "assets" => [%{"type" => "icon", "name" => "main", "uri" => "embeded://assets/icon/main.png"}]
        }
      }

      {:ok, {_name, zip}} =
        :zip.create(~c"x.charx", [{~c"card.json", Jason.encode!(card)}, {~c"assets/icon/main.png", @png}], [:memory])

      before = Repo.aggregate(Attachment, :count)
      assert %{record: character, warnings: warnings} = import!(user, "denied.charx", zip)
      assert "The avatar couldn't be saved." in warnings
      refute avatar_id(character)
      assert Repo.aggregate(Attachment, :count) == before
    end
  end

  describe "parse limits" do
    setup do
      previous = Application.get_env(:mythweaver, Mythweaver.Import)
      Application.put_env(:mythweaver, Mythweaver.Import, max_parse_bytes: 64 * 1024 * 1024)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:mythweaver, Mythweaver.Import, previous),
          else: Application.delete_env(:mythweaver, Mythweaver.Import)
      end)
    end

    test "a CHARX inflates only its card, however large its other entries", %{scope: scope} do
      card = Jason.encode!(%{"spec" => "chara_card_v3", "data" => %{"name" => "Light"}})
      junk = :binary.copy(" ", 128 * 1024 * 1024)
      {:ok, {_name, zip}} = :zip.create(~c"x.charx", [{~c"card.json", card}, {~c"junk.bin", junk}], [:memory])

      assert %{record: %{name: "Light"}} = import!(scope, "light.charx", zip)
    end

    test "a parse past the heap cap is refused" do
      card =
        ~s({"spec":"chara_card_v3","data":{"name":"x","description":") <>
          :binary.copy("a", 128 * 1024 * 1024) <> ~s("}})

      {:ok, {_name, zip}} = :zip.create(~c"x.charx", [{~c"card.json", card}], [:memory])

      assert Import.parse("bomb.charx", zip) == {:error, "This file is too large to import."}
    end
  end

  describe "SillyTavern links" do
    test "a card's linked world binds the existing book instead of its embedded copy", %{scope: scope} do
      world = Jason.encode!(%{"entries" => [%{"key" => ["k"], "content" => "World lore", "position" => 0}]})
      %{record: existing} = import!(scope, "foo.json", world)

      card =
        v2("Mira", %{
          "extensions" => %{"world" => "foo"},
          "character_book" => %{"name" => "foo", "entries" => [%{"keys" => ["k"], "content" => "Copy"}]}
        })

      {:ok, parsed} = Import.parse("Mira.json", Jason.encode!(card))
      assert {:ok, %{record: mira, warnings: warnings}} = Import.import(scope, parsed)

      assert [%{id: id}] = bound_books(mira)
      assert id == existing.id
      assert "Bound the existing lore book 'foo' this card links; its embedded copy wasn't imported." in warnings
    end

    test "a linked world that isn't here is warned about", %{scope: scope} do
      card = v2("Mira", %{"extensions" => %{"world" => "Elsewhere"}})

      assert %{warnings: warnings} = import!(scope, "Mira.json", Jason.encode!(card))

      assert "This card links the lore book 'Elsewhere', which isn't here. Import it, then bind it to the character." in warnings
    end

    test "inclusion groups share one pool by name across files", %{scope: scope} do
      for name <- ~w(A B) do
        world = Jason.encode!(%{"entries" => [%{"key" => ["k"], "content" => name, "group" => "G", "position" => 0}]})
        import!(scope, "#{name}.json", world)
      end

      assert [pool] = Repo.all(from p in LorePool, where: p.name == "G", preload: :pool_entries)
      assert length(pool.pool_entries) == 2
    end

    test "inclusion group weight and flags reach the pool membership", %{scope: scope} do
      entry = %{
        "key" => ["k"],
        "content" => "c",
        "group" => "G, H",
        "groupWeight" => 40,
        "groupOverride" => true,
        "useGroupScoring" => true,
        "position" => 0
      }

      %{record: book} = import!(scope, "W.json", Jason.encode!(%{"entries" => [entry]}))
      assert [{entry, _}] = members(book)

      assert [%{weight: 40, override: true, scored: true}, %{weight: 40, override: true, scored: true}] =
               Repo.preload(entry, :pool_entries).pool_entries
    end

    test "a linked world is looked up among usable books; a site book can't bind a user's character",
         %{scope: admin} do
      {:ok, _site} = Mythweaver.Lore.create_book(admin, %{name: "Shared World"}, site: true)
      card = Jason.encode!(v2("Mira", %{"extensions" => %{"world" => "Shared World"}}))

      for scope <- [admin, scope!(%{role: :user})] do
        %{record: mira, warnings: warnings} = import!(scope, "Mira.json", card)
        assert bound_books(mira) == []

        assert "The lore book 'Shared World' this card links exists but can't be bound to this character." in warnings
      end

      user = scope!(%{role: :user})
      {:ok, own} = Mythweaver.Lore.create_book(user, %{name: "Shared World"})
      %{record: mira, warnings: warnings} = import!(user, "Mira.json", card)
      assert [%{id: id}] = bound_books(mira)
      assert id == own.id
      assert "Bound the existing lore book 'Shared World' this card links." in warnings
    end

    test "a linked world that's a hidden site book is treated as missing", %{scope: admin} do
      {:ok, _hidden} = Mythweaver.Lore.create_book(admin, %{name: "Vault", site_visibility: :hidden}, site: true)
      card = Jason.encode!(v2("Mira", %{"extensions" => %{"world" => "Vault"}}))

      %{record: mira, warnings: warnings} = import!(scope!(%{role: :user}), "Mira.json", card)

      assert bound_books(mira) == []

      assert "This card links the lore book 'Vault', which isn't here. Import it, then bind it to the character." in warnings
    end

    test "a card's tags tag the character", %{scope: scope} do
      %{record: mira} = import!(scope, "Mira.json", Jason.encode!(v2("Mira", %{"tags" => ["fantasy"]})))

      tags = Mythweaver.Tags.item_tags(scope, mira)
      assert "fantasy" in (tags.site ++ tags.mine)
    end

    test "a character filter names a card by its file name", %{scope: scope} do
      %{record: mira} = import!(scope, "Mira_1.png", card_png([{"chara", encode(v2("Mira", %{}))}]))

      world =
        Jason.encode!(%{
          "entries" => [
            %{"key" => ["k"], "content" => "c", "position" => 0, "characterFilter" => %{"names" => ["Mira_1.png"]}}
          ]
        })

      %{record: book} = import!(scope, "W.json", world)
      assert [{entry, _membership}] = members(book)
      assert [%{character_id: id}] = Repo.preload(entry, :entry_characters).entry_characters
      assert id == mira.id
    end
  end

  describe "lore books" do
    test "maps positions and switches; an invalid regex key is dropped", %{scope: scope} do
      entries =
        for pos <- 0..7, into: %{} do
          {"#{pos}",
           %{
             "uid" => pos,
             "key" => ["k#{pos}"],
             "content" => "c#{pos}",
             "position" => pos,
             "depth" => 3,
             "outletName" => "My Outlet!",
             "selectiveLogic" => rem(pos, 4),
             "selective" => true,
             "keysecondary" => ["s"],
             "displayIndex" => pos
           }}
        end
        |> Map.put("8", %{"uid" => 8, "key" => [], "content" => "nokeys", "displayIndex" => 8})
        |> Map.put("9", %{
          "uid" => 9,
          "key" => ["x"],
          "content" => "off",
          "disable" => true,
          "useProbability" => false,
          "probability" => 5,
          "order" => 7,
          "displayIndex" => 9
        })
        |> Map.put("10", %{
          "uid" => 10,
          "key" => ["/(/"],
          "content" => "bad",
          "comment" => "Bad",
          "position" => 0,
          "displayIndex" => 10
        })

      bytes = Jason.encode!(%{"entries" => entries})
      {:ok, parsed} = Import.parse("World.json", bytes)
      assert "'Bad': key /(/ isn't a valid regex here and was dropped." in parsed.warnings

      assert %{kind: :lore_book, record: book} = import!(scope, "World.json", bytes)
      assert book.name == "World"

      by_name = Map.new(members(book), fn {entry, be} -> {entry.name, {entry, be}} end)
      assert map_size(by_name) == 11
      refute elem(by_name["Bad"], 1).enabled

      slot = fn name -> by_name |> Map.fetch!(name) |> elem(0) |> LoreEntry.slot() end

      assert Enum.map(0..7, &slot.("k#{&1}")) == [
               "before_character",
               "after_character",
               "before_author_note",
               "after_author_note",
               "at_depth",
               "before_examples",
               "after_examples",
               "custom:my_outlet"
             ]

      assert Enum.map(0..3, &elem(by_name["k#{&1}"], 0).secondary_logic) == [:and_any, :not_all, :not_any, :and_all]
      assert elem(by_name["k4"], 0).depth == 3
      assert Enum.any?(Prompts.list_outlets(scope), &(&1.key == "my_outlet" and &1.name == "My Outlet!"))

      {no_keys, no_keys_member} = by_name["Entry 8"]
      assert no_keys.activation == :constant
      refute no_keys_member.enabled

      {off, off_member} = by_name["x"]
      assert off.probability == 100
      assert off_member.order == 7
      refute off_member.enabled
      assert elem(by_name["k0"], 1).enabled
    end

    test "character filters match by name; an unmatched include switches the entry off", %{scope: scope} do
      {:ok, ann} = Characters.create_character(scope, %{name: "Ann"})

      entries = [
        %{"uid" => 0, "key" => ["a"], "content" => "A", "characterFilter" => %{"names" => ["Ann.png", "Ghost"]}},
        %{
          "uid" => 1,
          "key" => ["b"],
          "content" => "B",
          "characterFilter" => %{"names" => ["Ghost"], "tags" => ["t"]}
        },
        %{
          "uid" => 2,
          "key" => ["c"],
          "content" => "C",
          "characterFilter" => %{"names" => ["Ann"], "isExclude" => true}
        }
      ]

      assert %{record: book, warnings: warnings} = import!(scope, "F.json", Jason.encode!(%{"entries" => entries}))

      assert "'a' character filter: no character named Ghost." in warnings
      assert "'b' character filter tags weren't imported: t." in warnings
      assert "'b' was limited to characters that aren't here; imported switched off." in warnings

      by_name =
        Map.new(members(book), fn {entry, be} -> {entry.name, {Repo.preload(entry, :filter_characters), be}} end)

      assert {%{character_filter_mode: :include, filter_characters: [%{id: id}]}, %{enabled: true}} = by_name["a"]
      assert id == ann.id
      assert {%{character_filter_mode: :include, filter_characters: []}, %{enabled: false}} = by_name["b"]
      assert {%{character_filter_mode: :exclude, filter_characters: [%{id: ^id}]}, _} = by_name["c"]
    end

    test "SillyTavern-MemoryBooks entries become memories with no chat or range", %{scope: scope} do
      entries = %{
        "0" => %{
          "uid" => 0,
          "key" => ["a"],
          "content" => "Scene one",
          "comment" => "01 - Scene",
          "stmemorybooks" => true
        },
        "1" => %{"uid" => 1, "key" => ["b"], "content" => "Plain", "comment" => "Plain"}
      }

      assert %{record: book, warnings: warnings} =
               import!(scope, "Memories.json", Jason.encode!(%{"entries" => entries}))

      assert "1 entry was marked as a memory (it has no chat or message range)." in warnings

      by_name = Map.new(members(book), fn {entry, _be} -> {entry.name, entry} end)
      assert [record] = Repo.all(from r in Record, where: r.lore_book_id == ^book.id)
      assert record.lore_entry_id == by_name["01 - Scene"].id
      assert %{kind: :memory, tier: 0, sequence: 1, chat_id: nil, range_start: nil, range_end: nil} = record
    end

    test "SillyTavern-MemoryBooks summaries keep their tier and sources", %{scope: scope} do
      memory = fn uid, name, extra ->
        Map.merge(
          %{"uid" => uid, "key" => ["k#{uid}"], "content" => name, "comment" => name, "stmemorybooks" => true},
          extra
        )
      end

      entries = %{
        "0" => memory.(0, "001 - One", %{"disable" => true, "disabledBySummaryId" => 3}),
        "1" => memory.(1, "002 - Two", %{"disable" => true}),
        "2" => memory.(2, "003 - Three", %{}),
        "3" =>
          memory.(3, "[ARC 001] - Arc", %{"stmbSummary" => true, "stmbSummaryTier" => 1, "stmbSourceEntryUids" => ["1"]}),
        "4" => memory.(4, "[ARC 002] - Legacy", %{"stmbArc" => true})
      }

      %{record: book} = import!(scope, "Memories.json", Jason.encode!(%{"entries" => entries}))

      records =
        Map.new(Repo.all(from r in Record, where: r.lore_book_id == ^book.id, preload: :entry), &{&1.entry.name, &1})

      arc = records["[ARC 001] - Arc"]
      assert %{kind: :consolidation, tier: 1, sequence: 1, chat_id: nil} = arc
      assert %{kind: :consolidation, tier: 1, sequence: 2} = records["[ARC 002] - Legacy"]
      assert %{kind: :memory, tier: 0, sequence: 3, consolidated_into_id: nil} = records["003 - Three"]

      for name <- ["001 - One", "002 - Two"] do
        assert %{consolidated_into_id: id, disabled_by_consolidation: true} = records[name]
        assert id == arc.id
      end

      assert Enum.sort(arc.snapshot["source_ids"]) == Enum.sort([records["001 - One"].id, records["002 - Two"].id])
      assert Consolidation.eligible(scope, book, 1) |> Enum.map(& &1.entry.name) == ["003 - Three"]
    end

    test "a character book's extensions.stmemorybooks entries become memories", %{scope: scope} do
      entry = %{"keys" => ["k"], "content" => "Lore", "enabled" => true, "extensions" => %{"stmemorybooks" => true}}
      card = v2("Ann", %{"character_book" => %{"entries" => [entry]}})

      assert %{record: character, warnings: warnings} = import!(scope, "Ann.json", Jason.encode!(card))
      assert "1 entry was marked as a memory (it has no chat or message range)." in warnings
      assert [book] = bound_books(character)
      assert [%{kind: :memory, tier: 0}] = Repo.all(from r in Record, where: r.lore_book_id == ^book.id)
    end

    test "negative orders keep their effective order through the book's adjustment", %{scope: scope} do
      entries = [%{"key" => ["a"], "content" => "a", "order" => -5}, %{"key" => ["b"], "content" => "b", "order" => 3}]
      %{record: book} = import!(scope, "Neg.json", Jason.encode!(%{"entries" => entries}))

      assert book.order_adjustment == -5
      assert members(book) |> Enum.map(fn {_e, be} -> be.order + book.order_adjustment end) == [-5, 3]
    end

    test "a vectorized entry with no keys imports as an enabled vector entry", %{scope: scope} do
      entries = %{"0" => %{"uid" => 0, "key" => [], "content" => "Dragons", "vectorized" => true, "displayIndex" => 0}}

      assert %{kind: :lore_book, record: book, warnings: []} =
               import!(scope, "Vec.json", Jason.encode!(%{"entries" => entries}))

      assert [{%{activation: :vector}, %{enabled: true}}] = members(book)
    end

    test "a character book's extensions.vectorized entry imports as vector", %{scope: scope} do
      entry = %{"keys" => [], "content" => "Dragons", "enabled" => true, "extensions" => %{"vectorized" => true}}
      card = v2("Ann", %{"character_book" => %{"entries" => [entry]}})

      assert %{record: character} = import!(scope, "Ann.json", Jason.encode!(card))
      assert [book] = bound_books(character)
      assert [{%{activation: :vector}, %{enabled: true}}] = members(book)
    end
  end

  describe "chats" do
    defp chat_jsonl do
      [
        %{"user_name" => "Me", "character_name" => "Ann", "create_date" => "2024-01-01T00:00:00Z"},
        %{"name" => "Me", "is_user" => true, "mes" => "hi", "send_date" => "2024-3-5 @14h 30m 12s 345ms"},
        %{
          "name" => "Ann",
          "mes" => "b",
          "send_date" => 1_700_000_000_000,
          "swipes" => ["a", "b"],
          "swipe_id" => 1,
          "extra" => %{"reasoning" => "think"}
        },
        %{"name" => "System", "is_system" => true, "mes" => "note", "send_date" => "March 5, 2024 2:30pm"}
      ]
      |> Enum.map_join("\n", &Jason.encode!/1)
    end

    test "maps speakers and writes the transcript", %{scope: scope} do
      {:ok, me} = Characters.create_character(scope, %{name: "Me"})
      {:ok, parsed} = Import.parse("Tavern.jsonl", chat_jsonl())
      [%{key: me_key, name: "Me"}, %{key: ann_key, name: "Ann"}, %{key: sys_key, name: "System"}] = parsed.speakers

      speakers = %{me_key => {:character, me.id}, ann_key => :create, sys_key => :name_only}

      assert {:ok, %{kind: :chat, record: chat, warnings: []}} =
               Import.import(scope, parsed, player: me_key, speakers: speakers)

      chat = Chats.get_chat!(chat.id)
      assert chat.name == "Tavern"
      assert chat.player_character_id == me.id
      assert [me_id, ann_id] = chat.participants |> Enum.sort_by(& &1.position) |> Enum.map(& &1.character_id)
      assert me_id == me.id
      assert %{name: "Ann"} = Characters.get_character!(ann_id)

      assert [first, second, third] = Messages.list_messages(chat)
      assert Enum.map([first, second, third], & &1.position) == [0, 1, 2]

      assert %{author_character_id: ^me_id, author_is_player: true, visible_to_ai: true} = first
      assert first.inserted_at == ~U[2024-03-05 14:30:12.345000Z]
      assert [%{content: "hi", active: true}] = first.bodies

      assert %{author_character_id: ^ann_id, author_is_player: false} = second
      assert DateTime.compare(second.inserted_at, DateTime.from_unix!(1_700_000_000_000, :millisecond)) == :eq

      assert [%{content: "a", active: false}, %{content: "b", active: true, reasoning: "think"}] =
               second.bodies

      assert %{author_character_id: nil, author_name: "System", visible_to_ai: false} = third
      assert third.inserted_at == ~U[2024-03-05 14:30:00.000000Z]
    end

    test "the player needs a character, and a chat needs two", %{scope: scope} do
      {:ok, parsed} = Import.parse("T.jsonl", chat_jsonl())
      speakers = %{0 => :name_only, 1 => :create, 2 => :name_only}

      assert {:error, "Choose a character for the player."} =
               Import.import(scope, parsed, player: 0, speakers: speakers)

      assert {:error, "A chat needs at least two characters; map another speaker to a character."} =
               Import.import(scope, parsed, player: 1, speakers: speakers)

      unknown = Mythweaver.Schema.generate_id()

      assert {:error, "That character isn't available."} =
               Import.import(scope, parsed, player: 1, speakers: %{speakers | 0 => {:character, unknown}})

      assert Characters.list_characters(scope) == []
    end
  end

  describe "presets" do
    defp preset_json do
      prompts = [
        %{"identifier" => "main", "name" => "Main Prompt", "role" => "system", "content" => "Be {{char}}."},
        %{"identifier" => "nsfw", "name" => "Auxiliary Prompt", "role" => "system", "content" => ""},
        %{"identifier" => "dialogueExamples", "name" => "Chat Examples", "marker" => true},
        %{"identifier" => "jailbreak", "name" => "Post-History Instructions", "role" => "system", "content" => ""},
        %{"identifier" => "chatHistory", "name" => "Chat History", "marker" => true},
        %{"identifier" => "worldInfoAfter", "name" => "World Info (after)", "marker" => true},
        %{"identifier" => "worldInfoBefore", "name" => "World Info (before)", "marker" => true},
        %{
          "identifier" => "enhanceDefinitions",
          "name" => "Enhance Definitions",
          "role" => "system",
          "content" => "More."
        },
        %{"identifier" => "charDescription", "name" => "Char Description", "marker" => true},
        %{"identifier" => "charPersonality", "name" => "Char Personality", "marker" => true},
        %{"identifier" => "scenario", "name" => "Scenario", "marker" => true},
        %{"identifier" => "personaDescription", "name" => "Persona Description", "marker" => true}
      ]

      order = fn ids -> Enum.map(ids, fn {id, on} -> %{"identifier" => id, "enabled" => on} end) end

      %{
        "temperature" => 0.8,
        "seed" => -1,
        "prompts" => prompts,
        "prompt_order" => [
          %{"character_id" => 100_000, "order" => order.([{"main", true}])},
          %{
            "character_id" => 100_001,
            "order" =>
              order.([
                {"main", true},
                {"worldInfoBefore", true},
                {"personaDescription", true},
                {"charDescription", true},
                {"charPersonality", true},
                {"scenario", true},
                {"enhanceDefinitions", false},
                {"nsfw", true},
                {"worldInfoAfter", true},
                {"dialogueExamples", true},
                {"chatHistory", true},
                {"jailbreak", true}
              ])
          }
        ]
      }
    end

    defp prompt_blocks(prompt) do
      Repo.all(
        from pb in PromptBlock,
          where: pb.prompt_id == ^prompt.id,
          order_by: pb.position,
          preload: :block
      )
    end

    test "blocks in prompt_order 100001 order, sampler onto the chosen model", %{scope: scope} do
      {:ok, model} = AI.create_model(scope, %{name: "M", api_model_id: "m", sampler: %{seed: 7, top_k: 40}})

      assert %{kind: :preset, record: prompt} =
               import!(scope, "Default.json", Jason.encode!(preset_json()), model_id: model.id)

      assert prompt.name == "Default"
      blocks = prompt_blocks(prompt)

      assert Enum.map(blocks, & &1.block.name) == [
               "Default: Main Prompt",
               "Default: World Info (before)",
               "Default: Persona Description",
               "Default: Char Description",
               "Default: Enhance Definitions",
               "Default: Auxiliary Prompt",
               "Default: World Info (after)",
               "Default: Chat Examples",
               "Default: Start of chat",
               "Default: Chat history",
               "Default: Guide",
               "Default: Author's note",
               "Default: Post-History Instructions",
               "Default: Refine"
             ]

      by_name = Map.new(blocks, &{&1.block.name, &1})
      refute by_name["Default: Enhance Definitions"].enabled
      assert by_name["Default: Guide"].enabled
      assert %{kind: :chat_history, content: nil} = by_name["Default: Chat history"].block
      assert by_name["Default: Main Prompt"].block.content == "Be {{ anchors.character.name }}."

      sampler = AI.get_editable_model(scope, model.id).sampler
      assert %{temperature: 0.8, seed: 7, top_k: 40} = sampler

      assert %{record: %{name: "Default (2)"} = again} = import!(scope, "Default.json", Jason.encode!(preset_json()))
      assert hd(prompt_blocks(again)).block.name == "Default: Main Prompt (2)"

      assert %{role_tag: :main, forbid_overrides: false} = by_name["Default: Main Prompt"].block
      assert %{role_tag: :post_history} = by_name["Default: Post-History Instructions"].block
      assert %{role_tag: nil} = by_name["Default: Enhance Definitions"].block
    end

    test "an uneditable model rolls the import back", %{scope: scope} do
      {:ok, parsed} = Import.parse("P.json", Jason.encode!(preset_json()))
      unknown = Mythweaver.Schema.generate_id()

      assert {:error, "That model can't be edited."} = Import.import(scope, parsed, model_id: unknown)
      assert Prompts.list_editable_prompts(scope) == []
    end

    test "a text-completion preset is refused" do
      assert {:error,
              "Only SillyTavern Chat Completion presets can be imported; this looks like a text-completion preset or template."} =
               Import.parse("tc.json", Jason.encode!(%{"temp" => 0.7, "rep_pen" => 1.1}))
    end
  end

  describe "content moderation" do
    test "a restrictive user's card import is held whole, then applied on approval", %{scope: scope} do
      :ok = Mythweaver.Permissions.put_grant!(scope.user, "moderation.characters.restrictive", :allow)
      scope = Scope.for_user(scope.user)

      {:ok, _rule} =
        Rules.create_rule(scope!(), %{
          "name" => "Words",
          "kind" => "regex",
          "content_types" => ["characters"],
          "pattern" => "forbidden"
        })

      card = v2("Held", %{"description" => "a forbidden tale", "scenario" => "S"})
      {:ok, parsed} = Import.parse("held.png", card_png([{"chara", encode(card)}]))

      assert {:held, hold} = Import.import(scope, parsed)
      assert hold.kind == :import
      assert Repo.all(from c in Character, where: c.user_id == ^scope.user.id) == []

      assert {:ok, character} = Holds.approve(scope!(), hold.id)
      assert character.name == "Held"
      assert [%{name: "Held (card)"}] = bound_books(character)
    end
  end
end
