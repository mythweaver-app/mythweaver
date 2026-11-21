defmodule Mythweaver.Export.ExternalTest do
  use Mythweaver.DataCase

  alias Mythweaver.AI.Model
  alias Mythweaver.AI.SamplerParams
  alias Mythweaver.Attachments
  alias Mythweaver.Characters
  alias Mythweaver.Export
  alias Mythweaver.Export.Collect
  alias Mythweaver.Export.Png, as: ExportPng
  alias Mythweaver.Export.Preset, as: ExportPreset
  alias Mythweaver.Import
  alias Mythweaver.Import.Png
  alias Mythweaver.Prompts.Standard

  @changed "This file was changed outside Mythweaver, so its Mythweaver-only details weren't imported."

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
       )

  @card %{
    "spec" => "chara_card_v3",
    "spec_version" => "3.0",
    "data" => %{
      "name" => "Seraphina",
      "description" => "{{char}} guards the forest for {{user}}.",
      "personality" => "Kind and fierce.",
      "scenario" => "A glade at dusk.",
      "first_mes" => "Hello, {{user}}.",
      "alternate_greetings" => ["{{char}} waves."],
      "group_only_greetings" => ["Welcome, all."],
      "mes_example" => "<START>\n{{user}}: Hello?\n<START>\n{{char}}: Welcome.",
      "system_prompt" => "You are {{char}}.",
      "post_history_instructions" => "Stay in character.",
      "creator" => "Ana",
      "character_version" => "2",
      "creator_notes" => "For testing.",
      "tags" => [],
      "extensions" => %{
        "talkativeness" => 0.7,
        "depth_prompt" => %{"prompt" => "Remember the oath.", "depth" => 3, "role" => "system"}
      },
      "character_book" => %{
        "name" => "Forest lore",
        "scan_depth" => 3,
        "entries" => [
          %{
            "id" => 0,
            "keys" => ["glade"],
            "comment" => "Glade",
            "content" => "The glade is quiet.",
            "insertion_order" => 10,
            "enabled" => true,
            "position" => "after_char",
            "extensions" => %{"position" => 7, "outlet_name" => "Weather", "probability" => 80}
          },
          %{
            "id" => 1,
            "keys" => ["oath"],
            "secondary_keys" => ["vow"],
            "selective" => true,
            "comment" => "Oath",
            "content" => "{{char}} swore an oath.",
            "insertion_order" => 20,
            "enabled" => false,
            "position" => "before_char",
            "extensions" => %{"position" => 4, "depth" => 2, "selectiveLogic" => 3}
          },
          %{
            "id" => 2,
            "keys" => ["first"],
            "comment" => "Memory one",
            "content" => "They met.",
            "insertion_order" => 30,
            "enabled" => true,
            "position" => "after_char",
            "extensions" => %{"stmemorybooks" => true}
          },
          %{
            "id" => 3,
            "keys" => ["arc"],
            "comment" => "Arc one",
            "content" => "The first arc.",
            "insertion_order" => 40,
            "enabled" => true,
            "position" => "after_char",
            "extensions" => %{
              "stmemorybooks" => true,
              "stmbSummary" => true,
              "stmbSummaryTier" => 1,
              "stmbSourceEntryUids" => [2]
            }
          }
        ]
      }
    }
  }

  @world %{
    "entries" => %{
      "0" => %{
        "uid" => 0,
        "key" => ["castle"],
        "comment" => "Castle",
        "content" => "{{user}} sees a castle.",
        "order" => 10,
        "position" => 0
      },
      "1" => %{
        "uid" => 1,
        "key" => ["moat"],
        "keysecondary" => ["water"],
        "selective" => true,
        "selectiveLogic" => 2,
        "comment" => "Moat",
        "content" => "A moat.",
        "order" => 20,
        "position" => 1
      },
      "2" => %{
        "uid" => 2,
        "key" => [],
        "constant" => true,
        "comment" => "Rules",
        "content" => "Rules.",
        "order" => 30,
        "position" => 2
      },
      "3" => %{
        "uid" => 3,
        "key" => ["tower"],
        "comment" => "Tower",
        "content" => "A tower.",
        "order" => 40,
        "position" => 3
      },
      "4" => %{
        "uid" => 4,
        "key" => ["gate"],
        "comment" => "Gate",
        "content" => "A gate.",
        "order" => 50,
        "position" => 4,
        "depth" => 6
      },
      "5" => %{
        "uid" => 5,
        "key" => ["hall"],
        "comment" => "Hall",
        "content" => "A hall.",
        "order" => 60,
        "position" => 5
      },
      "6" => %{
        "uid" => 6,
        "key" => ["crypt"],
        "comment" => "Crypt",
        "content" => "A crypt.",
        "order" => 70,
        "position" => 6,
        "disable" => true
      },
      "7" => %{
        "uid" => 7,
        "key" => ["note"],
        "comment" => "Note",
        "content" => "A note.",
        "order" => 80,
        "position" => 7,
        "outletName" => "Side notes"
      },
      "8" => %{
        "uid" => 8,
        "key" => ["met"],
        "comment" => "Memory",
        "content" => "They met.",
        "order" => 90,
        "position" => 1,
        "stmemorybooks" => true
      },
      "9" => %{
        "uid" => 9,
        "key" => ["saga"],
        "comment" => "Saga",
        "content" => "The saga.",
        "order" => 100,
        "position" => 1,
        "stmemorybooks" => true,
        "stmbSummary" => true,
        "stmbSummaryTier" => 1,
        "stmbSourceEntryUids" => [8]
      },
      "10" => %{
        "uid" => 10,
        "key" => ["wolf"],
        "comment" => "Wolf",
        "content" => "A wolf.",
        "order" => 110,
        "position" => 0,
        "characterFilter" => %{"isExclude" => true, "names" => ["Ranger"], "tags" => []}
      }
    }
  }

  @preset %{
    "prompts" => [
      %{"identifier" => "main", "name" => "Main Prompt", "role" => "system", "content" => "Write {{char}}'s reply."},
      %{"identifier" => "worldInfoBefore", "name" => "World Info (before)", "marker" => true},
      %{"identifier" => "charDescription", "name" => "Char Description", "marker" => true},
      %{"identifier" => "personaDescription", "name" => "Persona Description", "marker" => true},
      %{"identifier" => "worldInfoAfter", "name" => "World Info (after)", "marker" => true},
      %{"identifier" => "dialogueExamples", "name" => "Chat Examples", "marker" => true},
      %{"identifier" => "chatHistory", "name" => "Chat History", "marker" => true},
      %{
        "identifier" => "nsfw",
        "name" => "Auxiliary",
        "role" => "user",
        "content" => "Keep it {{random::calm::tense}}."
      },
      %{"identifier" => "jailbreak", "name" => "Post-History Instructions", "content" => "Stay brief."}
    ],
    "prompt_order" => [
      %{
        "character_id" => 100_001,
        "order" => [
          %{"identifier" => "main", "enabled" => true},
          %{"identifier" => "worldInfoBefore", "enabled" => true},
          %{"identifier" => "charDescription", "enabled" => true},
          %{"identifier" => "personaDescription", "enabled" => true},
          %{"identifier" => "worldInfoAfter", "enabled" => true},
          %{"identifier" => "dialogueExamples", "enabled" => true},
          %{"identifier" => "chatHistory", "enabled" => true},
          %{"identifier" => "nsfw", "enabled" => false},
          %{"identifier" => "jailbreak", "enabled" => true}
        ]
      }
    ],
    "new_chat_prompt" => "[New scene]",
    "new_group_chat_prompt" => "[Group: {{group}}]",
    "new_example_chat_prompt" => "[Example]",
    "group_nudge_prompt" => "[Write as {{char}}]"
  }

  @chat [
    %{"user_name" => "Ana", "character_name" => "Seraphina", "create_date" => "2024-01-05T14:30:12.000Z"},
    %{
      "name" => "Seraphina",
      "is_user" => false,
      "send_date" => "2024-01-05T14:30:12.000Z",
      "mes" => "Welcome.",
      "swipes" => ["Hi.", "Welcome."],
      "swipe_id" => 1,
      "swipe_info" => [%{"extra" => %{"reasoning" => "first"}}, %{"extra" => %{"reasoning" => "second"}}],
      "extra" => %{"reasoning" => "second"}
    },
    %{"name" => "Ana", "is_user" => true, "send_date" => "2024-01-05T14:31:00.000Z", "mes" => "Thanks."},
    %{"name" => "Narrator", "is_system" => true, "send_date" => "2024-01-05T14:32:00.000Z", "mes" => "Night falls."}
  ]

  setup do
    %{scope: scope!()}
  end

  defp character!(scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: name})
    character
  end

  defp parse!(filename, bytes) do
    {:ok, parsed} = Import.parse(filename, bytes)
    parsed
  end

  defp import!(scope, filename, bytes, opts \\ []) do
    {:ok, %{record: record}} = Import.import(scope, parse!(filename, bytes), opts)
    record
  end

  defp export!(scope, kind, id, format) do
    {:ok, request} = Export.request(%{"items" => ["#{kind}:#{id}"], "format" => Atom.to_string(format)})
    {:ok, file} = Export.build(scope, request)
    file
  end

  defp jsonl(lines), do: Enum.map_join(lines, "\n", &Jason.encode!/1)

  # Rewrites the card JSON inside a card file of `format`.
  defp rewrite_card(:card_json, bytes, fun), do: bytes |> Jason.decode!() |> fun.() |> Jason.encode!()

  defp rewrite_card(:card_png, bytes, fun) do
    {:ok, texts} = Png.text_chunks(bytes)
    {:ok, image} = Png.strip_text(bytes)

    card = fn key ->
      texts[key] |> Base.decode64!() |> Jason.decode!() |> fun.() |> Jason.encode!() |> Base.encode64()
    end

    ExportPng.embed(image, [{"chara", card.("chara")}, {"ccv3", card.("ccv3")}])
  end

  defp rewrite_card(:charx, bytes, fun) do
    {:ok, files} = :zip.unzip(bytes, [:memory])

    files =
      Enum.map(files, fn
        {~c"card.json", json} -> {~c"card.json", rewrite_card(:card_json, json, fun)}
        file -> file
      end)

    {:ok, {_name, zip}} = :zip.create(~c"card.charx", files, [:memory])
    zip
  end

  defp strip_card(card), do: update_in(card, ["data", "extensions"], &Map.delete(&1, "mythweaver"))

  # Every chunk's type, checking lengths and CRCs on the way.
  defp png_chunks(<<137, 80, 78, 71, 13, 10, 26, 10, rest::binary>>), do: png_chunks(rest, [])

  defp png_chunks(<<>>, acc), do: Enum.reverse(acc)

  defp png_chunks(<<len::32, type::binary-4, data::binary-size(len), crc::32, rest::binary>>, acc) do
    assert crc == :erlang.crc32(type <> data)
    png_chunks(rest, [type | acc])
  end

  # Memory uids are file-local (entry ids in the source, indices in an export), and entries come out
  # in membership order rather than the source's. A Mythweaver book always has a `recursive` value.
  defp comparable(%{book: book} = card) do
    book = %{book | entries: by_name(book.entries), book: Map.take(book.book, [:scan_depth])}
    %{Map.drop(card, [:warnings, :unconverted, :avatar, :embedded]) | book: book}
  end

  defp comparable_entry(entry) do
    Map.update!(entry, :memory, fn
      nil -> nil
      memory -> %{tier: memory.tier, sources: length(memory.source_uids)}
    end)
  end

  defp by_name(entries), do: entries |> Enum.map(&comparable_entry/1) |> Enum.sort_by(& &1.attrs.name)

  describe "character cards" do
    setup %{scope: scope} do
      character = import!(scope, "Seraphina.json", Jason.encode!(@card))
      {:ok, avatar} = Attachments.store_binary(@png)
      :ok = Attachments.set_avatar(scope, character, avatar)
      %{character: character, original: parse!("Seraphina.json", Jason.encode!(@card))}
    end

    for format <- [:card_json, :card_png, :charx] do
      @format format

      test "#{format} imports as a bundle, and as the original card without its extension", ctx do
        file = export!(ctx.scope, :character, ctx.character.id, @format)
        filename = file.filename

        assert %{kind: :bundle, bundle: bundle, warnings: []} = parse!(filename, file.bytes)
        assert [%{kind: :character, name: "Seraphina"} = root] = Enum.filter(bundle.items, & &1.root)

        if @format == :card_json do
          assert "JSON cards carry no avatar; choose PNG or CHARX to keep it." in file.warnings
          assert bundle.blobs == %{}
        else
          assert [%{bytes: @png, content_type: "image/png"}] = Map.values(bundle.blobs)
          assert Map.has_key?(bundle.blobs, root.data["avatar"])
        end

        stripped = parse!(filename, rewrite_card(@format, file.bytes, &strip_card/1))
        # The card's own embedded scan_depth round-trips (and is warned about) as in the original.
        assert %{kind: :character, warnings: warnings} = stripped
        assert warnings == ctx.original.warnings
        assert comparable(stripped) == comparable(%{ctx.original | avatar: nil})

        changed = parse!(filename, rewrite_card(@format, file.bytes, &put_in(&1, ["data", "description"], "Changed.")))
        assert %{kind: :character, description: "Changed."} = changed
        assert @changed in changed.warnings
      end
    end

    test "the card book is lifted back into card fields", ctx do
      file = export!(ctx.scope, :character, ctx.character.id, :card_json)
      data = Jason.decode!(file.bytes)["data"]

      assert data["system_prompt"] == "You are {{char}}."
      assert data["personality"] == "Kind and fierce."
      assert data["mes_example"] == "<START>\n{{user}}: Hello?\n<START>\n{{char}}: Welcome."
      assert data["post_history_instructions"] == "Stay in character."
      assert data["first_mes"] == "Hello, {{user}}."
      assert data["alternate_greetings"] == ["{{char}} waves."]
      assert data["group_only_greetings"] == ["Welcome, all."]
      assert data["extensions"]["depth_prompt"] == %{"prompt" => "Remember the oath.", "depth" => 3, "role" => "system"}
      assert data["character_book"]["name"] == "Forest lore"

      assert data["character_book"]["entries"] |> Enum.map(& &1["comment"]) |> Enum.sort() ==
               ["Arc one", "Glade", "Memory one", "Oath"]
    end

    test "a legacy card book's System prompt entry exports into system_prompt", ctx do
      {:ok, character} = Characters.update_character(ctx.scope, ctx.character, %{system_prompt: nil})
      card_book = Enum.find(Mythweaver.Lore.list_books(ctx.scope), &(&1.kind == :card))

      {:ok, _entry} =
        Mythweaver.Lore.create_entry(
          ctx.scope,
          %{
            name: "System prompt",
            content: "Legacy prompt.",
            activation: :constant,
            outlet: :character,
            placement: :before
          },
          [card_book.id]
        )

      data = Jason.decode!(export!(ctx.scope, :character, character.id, :card_json).bytes)["data"]
      assert data["system_prompt"] == "Legacy prompt."
      assert data["personality"] == "Kind and fierce."
    end

    test "the character's own system prompt wins over a legacy card book entry", ctx do
      card_book = Enum.find(Mythweaver.Lore.list_books(ctx.scope), &(&1.kind == :card))

      {:ok, _entry} =
        Mythweaver.Lore.create_entry(
          ctx.scope,
          %{
            name: "System prompt",
            content: "Legacy prompt.",
            activation: :constant,
            outlet: :character,
            placement: :before
          },
          [card_book.id]
        )

      data = Jason.decode!(export!(ctx.scope, :character, ctx.character.id, :card_json).bytes)["data"]
      assert data["system_prompt"] == "You are {{char}}."
      refute Enum.any?(data["character_book"]["entries"], &(&1["comment"] == "System prompt"))
    end

    test "a card book with a disabled field exports as character_book lore, not card text", ctx do
      card_book = Enum.find(Mythweaver.Lore.list_books(ctx.scope), &(&1.kind == :card))
      scenario = Enum.find(Mythweaver.Lore.list_entries(ctx.scope), &(&1.name == "Scenario"))
      {:ok, _membership} = Mythweaver.Lore.set_membership_enabled(ctx.scope, card_book, scenario.id, false)

      data = Jason.decode!(export!(ctx.scope, :character, ctx.character.id, :card_json).bytes)["data"]
      assert {data["scenario"], data["personality"]} == {"", ""}

      by_comment = Map.new(data["character_book"]["entries"], &{&1["comment"], &1})
      assert %{"enabled" => false, "content" => "A glade at dusk."} = by_comment["Scenario"]
      assert %{"enabled" => true, "content" => "Kind and fierce."} = by_comment["Personality"]
    end

    test "the character_book's stlo follows the book's settings, top level or under extensions", %{scope: scope} do
      for {name, stlo_path} <- [{"Keeper", ["stlo"]}, {"Warden", ["extensions", "stlo"]}] do
        book =
          put_in(
            %{
              "name" => "#{name} lore",
              "extensions" => %{"other" => 1},
              "entries" => [
                %{"id" => 0, "keys" => ["door"], "content" => "A door.", "enabled" => true, "insertion_order" => -5}
              ]
            },
            stlo_path,
            %{"priority" => 2, "orderAdjustment" => 0}
          )

        card = %{"spec" => "chara_card_v2", "data" => %{"name" => name, "character_book" => book}}
        character = import!(scope, "#{name}.json", Jason.encode!(card))
        lore = Enum.find(Mythweaver.Lore.list_books(scope), &(&1.name == "#{name} lore"))
        assert {lore.priority, lore.order_adjustment} == {2, -5}
        {:ok, _lore} = Mythweaver.Lore.update_book(scope, lore, %{priority: 4})

        cb = Jason.decode!(export!(scope, :character, character.id, :card_json).bytes)["data"]["character_book"]
        assert %{"priority" => 4, "orderAdjustment" => -5} = get_in(cb, stlo_path)
        assert [%{"insertion_order" => 0}] = cb["entries"]
        assert cb["extensions"]["other"] == 1
      end
    end

    test "a card book entry's unheld secondary keys and filter tags round-trip", %{scope: scope} do
      card = %{
        "spec" => "chara_card_v2",
        "data" => %{
          "name" => "Tagger",
          "character_book" => %{
            "entries" => [
              %{
                "id" => 0,
                "keys" => ["trail"],
                "secondary_keys" => ["later"],
                "selective" => false,
                "comment" => "Trail",
                "content" => "A trail.",
                "enabled" => true,
                "extensions" => %{"character_filter" => %{"isExclude" => true, "names" => [], "tags" => ["elf"]}}
              }
            ]
          }
        }
      }

      character = import!(scope, "Tagger.json", Jason.encode!(card))

      [entry] =
        Jason.decode!(export!(scope, :character, character.id, :card_json).bytes)["data"]["character_book"]["entries"]

      assert %{"secondary_keys" => ["later"], "selective" => false} = entry
      assert entry["extensions"]["character_filter"] == %{"isExclude" => true, "names" => [], "tags" => ["elf"]}
    end

    test "add-mode card prompts export with {{original}} first", ctx do
      {:ok, character} = Characters.update_character(ctx.scope, ctx.character, %{card_prompt_mode: :add})
      data = Jason.decode!(export!(ctx.scope, :character, character.id, :card_json).bytes)["data"]

      assert data["system_prompt"] == "{{original}}\nYou are {{char}}."
      assert data["post_history_instructions"] == "{{original}}\nStay in character."
    end

    test "a card-book entry's character filter round-trips without the bundle", %{scope: scope} do
      character!(scope, "Ranger")

      card = %{
        "spec" => "chara_card_v2",
        "data" => %{
          "name" => "Scout",
          "character_book" => %{
            "entries" => [
              %{
                "id" => 0,
                "keys" => ["trail"],
                "comment" => "Trail",
                "content" => "A trail.",
                "enabled" => true,
                "extensions" => %{"character_filter" => %{"isExclude" => false, "names" => ["Ranger"], "tags" => []}}
              }
            ]
          }
        }
      }

      character = import!(scope, "Scout.json", Jason.encode!(card))

      {:ok, request} =
        Export.request(%{
          "items" => ["character:#{character.id}"],
          "format" => "card_json",
          "include_bundle" => "false"
        })

      {:ok, file} = Export.build(scope, request)
      [entry] = Jason.decode!(file.bytes)["data"]["character_book"]["entries"]

      assert entry["extensions"]["character_filter"] == %{"isExclude" => false, "names" => ["Ranger"], "tags" => []}

      assert %{book: %{entries: [parsed]}} = parse!(file.filename, file.bytes)
      assert %{mode: :include, names: ["Ranger"]} = parsed.character_filter
    end

    test "a card whose greetings are all alternates exports with a blank first_mes", %{scope: scope} do
      card = %{
        "spec" => "chara_card_v2",
        "data" => %{"name" => "Alt", "first_mes" => " ", "alternate_greetings" => ["Hi."]}
      }

      character = import!(scope, "Alt.json", Jason.encode!(card))
      assert {character.first_message, character.alternate_greetings} == {nil, ["Hi."]}

      data = Jason.decode!(export!(scope, :character, character.id, :card_json).bytes)["data"]
      assert {data["first_mes"], data["alternate_greetings"]} == {"", ["Hi."]}
    end

    test "a PNG card is a valid PNG Mythweaver reads", ctx do
      file = export!(ctx.scope, :character, ctx.character.id, :card_png)

      assert ["IHDR" | _] = types = png_chunks(file.bytes)
      assert List.last(types) == "IEND"
      assert Enum.count(types, &(&1 == "tEXt")) == 2
      assert {:ok, %{name: "Seraphina", avatar: @png}} = Png.card(file.bytes)
    end

    test "a character without an avatar is drawn on the placeholder", %{scope: scope} do
      character = character!(scope, "Plain")
      file = export!(scope, :character, character.id, :card_png)

      assert ["IHDR" | _] = png_chunks(file.bytes)
      assert <<_sig::binary-8, _len::32, "IHDR", 400::32, 600::32, _rest::binary>> = file.bytes
      assert %{kind: :bundle, bundle: %{blobs: blobs}} = parse!(file.filename, file.bytes)
      assert blobs == %{}
    end
  end

  describe "World Info" do
    setup %{scope: scope} do
      character!(scope, "Ranger")
      book = import!(scope, "Castle.json", Jason.encode!(@world))
      %{book: book, original: parse!("Castle.json", Jason.encode!(@world))}
    end

    test "imports as a bundle, and as the original entries without its extension", ctx do
      file = export!(ctx.scope, :lore_book, ctx.book.id, :world_info)
      assert file.filename == "Castle.json"
      assert %{kind: :bundle, bundle: bundle} = parse!(file.filename, file.bytes)
      assert Enum.any?(bundle.items, &(&1.root and &1.kind == :lore_book))

      json = Jason.decode!(file.bytes)
      stripped = parse!(file.filename, Jason.encode!(Map.delete(json, "extensions")))
      assert %{kind: :lore_book, warnings: []} = stripped
      assert length(stripped.entries) == length(ctx.original.entries)
      for {left, right} <- Enum.zip(by_name(stripped.entries), by_name(ctx.original.entries)), do: assert(left == right)

      changed = put_in(json, ["entries", "0", "content"], "Changed.")
      changed = parse!(file.filename, Jason.encode!(changed))
      assert %{kind: :lore_book} = changed
      assert @changed in changed.warnings
    end

    test "groups, roles, trigger-only, stlo and foreign keys round-trip", %{scope: scope} do
      world = %{
        "stlo" => %{"priority" => 5},
        "entries" => %{
          "0" => %{
            "uid" => 0,
            "key" => ["door"],
            "content" => "a",
            "position" => 4,
            "depth" => 2,
            "role" => 1,
            "group" => "G",
            "groupOverride" => true,
            "someTool" => %{"x" => 1}
          },
          "1" => %{"uid" => 1, "key" => ["{{char}}"], "content" => "b", "position" => 0, "activationOnly" => true}
        }
      }

      book = import!(scope, "Doors.json", Jason.encode!(world))
      json = Jason.decode!(export!(scope, :lore_book, book.id, :world_info).bytes)
      by_key = Map.new(json["entries"], fn {_uid, entry} -> {hd(entry["key"]), entry} end)

      assert %{"group" => "G", "groupOverride" => true, "role" => 1, "someTool" => %{"x" => 1}} = by_key["door"]
      assert %{"activationOnly" => true} = by_key["{{char}}"]
      assert json["stlo"]["priority"] == 5
    end

    test "exports without the Mythweaver bundle", ctx do
      {:ok, request} =
        Export.request(%{
          "items" => ["lore_book:#{ctx.book.id}"],
          "format" => "world_info",
          "include_bundle" => "false"
        })

      {:ok, file} = Export.build(ctx.scope, request)
      refute get_in(Jason.decode!(file.bytes), ["extensions", "mythweaver"])
    end

    test "character filter names carry no .png", ctx do
      json = Jason.decode!(export!(ctx.scope, :lore_book, ctx.book.id, :world_info).bytes)
      wolf = Enum.find_value(json["entries"], fn {_uid, e} -> if e["comment"] == "Wolf", do: e end)
      assert wolf["characterFilter"] == %{"isExclude" => true, "names" => ["Ranger"], "tags" => []}
    end

    test "a non-selective entry's secondary keys and character filter tags round-trip", %{scope: scope} do
      world = %{
        "entries" => %{
          "0" => %{
            "uid" => 0,
            "key" => ["door"],
            "keysecondary" => ["later"],
            "selective" => false,
            "comment" => "Door",
            "content" => "a",
            "position" => 0,
            "characterFilter" => %{"isExclude" => false, "names" => ["Ranger"], "tags" => ["elf"]}
          },
          "1" => %{
            "uid" => 1,
            "key" => ["gate"],
            "comment" => "Gate",
            "content" => "b",
            "position" => 0,
            "characterFilter" => %{"isExclude" => true, "names" => [], "tags" => ["orc"]}
          }
        }
      }

      book = import!(scope, "Tags.json", Jason.encode!(world))
      json = Jason.decode!(export!(scope, :lore_book, book.id, :world_info).bytes)
      by_comment = Map.new(json["entries"], fn {_uid, entry} -> {entry["comment"], entry} end)

      assert %{"keysecondary" => ["later"], "selective" => false} = by_comment["Door"]
      assert by_comment["Door"]["characterFilter"] == %{"isExclude" => false, "names" => ["Ranger"], "tags" => ["elf"]}
      assert by_comment["Gate"]["characterFilter"] == %{"isExclude" => true, "names" => [], "tags" => ["orc"]}
    end

    test "stlo under extensions stays there, keeping a percentage budget mode", %{scope: scope} do
      world = %{
        "extensions" => %{"stlo" => %{"priority" => 5, "budgetMode" => "percentage_context", "budget" => 20}},
        "entries" => %{"0" => %{"uid" => 0, "key" => ["door"], "content" => "a", "position" => 0}}
      }

      book = import!(scope, "Pct.json", Jason.encode!(world))
      json = Jason.decode!(export!(scope, :lore_book, book.id, :world_info).bytes)

      refute Map.has_key?(json, "stlo")

      assert %{"priority" => 5, "budgetMode" => "percentage_context", "budget" => 20} =
               json["extensions"]["stlo"]
    end

    test "a file whose extensions isn't a map exports", %{scope: scope} do
      world = %{"extensions" => [], "entries" => %{"0" => %{"uid" => 0, "key" => ["door"], "content" => "a"}}}
      book = import!(scope, "List.json", Jason.encode!(world))
      assert %{"entries" => %{"0" => _}} = Jason.decode!(export!(scope, :lore_book, book.id, :world_info).bytes)
    end

    test "trigger-only entries and x/f regex flags are warned about", %{scope: scope} do
      world = %{
        "entries" => %{
          "0" => %{"uid" => 0, "key" => ["door"], "comment" => "Door", "content" => "a", "activationOnly" => true},
          "1" => %{"uid" => 1, "key" => ["/gate/x"], "comment" => "Gate", "content" => "b", "position" => 0}
        }
      }

      book = import!(scope, "Warn.json", Jason.encode!(world))
      file = export!(scope, :lore_book, book.id, :world_info)

      assert "Door: trigger-only; SillyTavern has no such setting and will insert the content." in file.warnings

      assert "Gate: regex flags x/f aren't supported by SillyTavern; the key will match as plain text." in file.warnings
    end
  end

  describe "presets" do
    setup %{scope: scope} do
      %{
        prompt: import!(scope, "My preset.json", Jason.encode!(@preset)),
        original: parse!("My preset.json", Jason.encode!(@preset))
      }
    end

    test "imports as a bundle, and as the original blocks without its extension", ctx do
      file = export!(ctx.scope, :prompt, ctx.prompt.id, :st_preset)
      assert file.filename == "My preset.json"
      assert %{kind: :bundle} = parse!(file.filename, file.bytes)

      json = Jason.decode!(file.bytes)
      stripped = parse!(file.filename, Jason.encode!(Map.delete(json, "extensions")))
      assert %{kind: :preset, warnings: []} = stripped
      assert stripped.blocks == ctx.original.blocks

      assert [
               %{"identifier" => _main, "enabled" => true},
               %{"identifier" => "worldInfoBefore"},
               %{"identifier" => "charDescription"},
               %{"identifier" => "personaDescription"},
               %{"identifier" => "worldInfoAfter"},
               %{"identifier" => "dialogueExamples"},
               %{"identifier" => "chatHistory"},
               %{"identifier" => _nsfw, "enabled" => false},
               %{"identifier" => "jailbreak", "enabled" => true}
             ] = hd(json["prompt_order"])["order"]

      assert json["new_chat_prompt"] == "[New scene]"
      assert json["new_group_chat_prompt"] == "[Group: {{group}}]"
      assert json["new_example_chat_prompt"] == "[Example]"
      assert json["group_nudge_prompt"] == "[Write as {{char}}]"

      changed = parse!(file.filename, Jason.encode!(Map.put(json, "new_chat_prompt", "[Changed]")))
      assert %{kind: :preset} = changed
      assert @changed in changed.warnings
    end

    test "carries the sampler model's values", ctx do
      {:ok, bundle, []} = Collect.run(ctx.scope, [{:prompt, ctx.prompt.id}])
      root = Enum.find(bundle.items, & &1.root).uid
      model = %Model{sampler: %SamplerParams{temperature: 0.8, max_tokens: 300}}
      json = Jason.decode!(ExportPreset.file(bundle, root, model).bytes)

      assert json["temperature"] == 0.8
      assert json["openai_max_tokens"] == 300
      refute Map.has_key?(json, "top_p")
    end

    test "an empty main prompt exports empty", %{scope: scope} do
      preset = %{
        "prompts" => [%{"identifier" => "main", "name" => "Main Prompt", "content" => ""}],
        "prompt_order" => [%{"character_id" => 100_001, "order" => [%{"identifier" => "main", "enabled" => true}]}]
      }

      prompt = import!(scope, "Empty.json", Jason.encode!(preset))
      json = Jason.decode!(export!(scope, :prompt, prompt.id, :st_preset).bytes)
      assert %{"content" => ""} = Enum.find(json["prompts"], &(&1["identifier"] == "main"))
    end

    test "the seeded post-history block exports an empty jailbreak", %{scope: scope} do
      {:ok, prompt} = Mythweaver.Prompts.create_prompt(scope, %{name: "Seeded"})

      {:ok, block} =
        Mythweaver.Prompts.create_block(scope, %{
          name: "Post-history instructions",
          content: Standard.post_history(),
          role_tag: :post_history
        })

      {:ok, _} = Mythweaver.Prompts.add_block(scope, prompt, block)
      json = Jason.decode!(export!(scope, :prompt, prompt.id, :st_preset).bytes)
      assert %{"content" => ""} = Enum.find(json["prompts"], &(&1["identifier"] == "jailbreak"))
    end
  end

  describe "chat logs" do
    setup %{scope: scope} do
      seraphina = character!(scope, "Seraphina")
      ana = character!(scope, "Ana")
      bytes = jsonl(@chat)

      chat =
        import!(scope, "Evening.jsonl", bytes,
          player: 1,
          speakers: %{0 => {:character, seraphina.id}, 1 => {:character, ana.id}}
        )

      %{chat: chat, original: parse!("Evening.jsonl", bytes)}
    end

    test "imports as a bundle, and as the original transcript without its extension", ctx do
      file = export!(ctx.scope, :chat, ctx.chat.id, :st_chat)
      assert %{kind: :bundle, bundle: bundle} = parse!(file.filename, file.bytes)
      assert [_chat_uid] = Map.keys(bundle.messages)

      [header | lines] = file.bytes |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      stripped = parse!(file.filename, jsonl([Map.delete(header, "chat_metadata") | lines]))
      assert %{kind: :chat, warnings: []} = stripped
      assert stripped.player_name == "Ana"
      assert stripped.speakers == ctx.original.speakers
      assert stripped.messages == ctx.original.messages

      changed =
        parse!(file.filename, jsonl([header, %{hd(lines) | "mes" => "Changed.", "swipes" => ["Changed."]} | tl(lines)]))

      assert %{kind: :chat} = changed
      assert @changed in changed.warnings
    end
  end
end
