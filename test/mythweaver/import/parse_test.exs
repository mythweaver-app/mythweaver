defmodule Mythweaver.Import.ParseTest do
  use ExUnit.Case, async: true

  alias Mythweaver.Import
  alias Mythweaver.Import.Chat
  alias Mythweaver.Import.Png
  alias Mythweaver.Import.WorldInfo

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
       )

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

  defp v2(name, data \\ %{}), do: %{"spec" => "chara_card_v2", "data" => Map.merge(%{"name" => name}, data)}

  describe "PNG" do
    test "extracts tEXt chunks, prefers ccv3 over chara, and drops them from the avatar" do
      png = card_png([{"chara", encode(v2("Old"))}, {"ccv3", encode(%{v2("New") | "spec" => "chara_card_v3"})}])

      assert {:ok, %{"chara" => _, "ccv3" => _}} = Png.text_chunks(png)
      assert {:ok, %{kind: :character, name: "New", avatar: @png}} = Import.parse("card.png", png)
    end

    test "strip_text/1 drops text chunks and keeps a decodable PNG" do
      png = card_png([{"chara", encode(v2("Old"))}])
      assert {:ok, @png} = Png.strip_text(png)
      assert {:ok, %{}} = Png.text_chunks(@png)
      assert {:ok, stripped} = Png.strip_text(png)
      assert map_size(elem(Png.text_chunks(stripped), 1)) == 0
      assert {:error, _} = Png.strip_text("nope")
    end

    test "maps V2 fields and card text" do
      card =
        v2("Ann", %{
          "description" => "Tall",
          "creator" => "me",
          "personality" => "Kind",
          "mes_example" => "<START>\nA: hi\n<START>\nA: yo",
          "post_history_instructions" => "Stay",
          "first_mes" => "Hi {{user}}",
          "alternate_greetings" => ["{{char}} waves", " "],
          "group_only_greetings" => ["All here"],
          "extensions" => %{"talkativeness" => "0.7", "depth_prompt" => %{"prompt" => "Deep", "depth" => 2}}
        })

      assert {:ok, parsed} = Import.parse("a.png", card_png([{"chara", encode(card)}]))
      assert %{description: "Tall", creator: "me", talkativeness: 0.7} = parsed
      assert parsed.first_message == "Hi {{ anchors.player.name }}"
      assert parsed.alternate_greetings == ["{{ anchors.character.name }} waves"]
      assert parsed.group_greetings == ["All here"]

      by_name = Map.new(parsed.card_fields, &{&1.attrs.name, &1})
      assert %{outlet: :character, placement: :after} = by_name["Personality"].attrs
      assert by_name["Personality"].order == 100
      assert by_name["Example dialogue"].attrs.content == "A: hi\n[Example chat]\nA: yo"
      refute Map.has_key?(by_name, "Post-history instructions")
      assert parsed.post_history_instructions == "Stay"
      assert %{outlet: :at_depth, depth: 2, role: :system} = by_name["Depth prompt"].attrs
    end

    test "card prompts, world, tags and foreign keys" do
      card =
        v2("Ann", %{
          "system_prompt" => "{{original}} Be brief. {{original}}",
          "personality" => "Kind",
          "tags" => [" fantasy ", "Fantasy", "", "elf"],
          "fav" => true,
          "extensions" => %{"world" => " AnnWorld ", "other_tool" => %{"a" => 1}}
        })

      assert {:ok, parsed} = Import.parse("Ann_1.json", Jason.encode!(card))
      assert parsed.system_prompt == "{{ original }} Be brief. "
      assert parsed.world == "AnnWorld"
      assert parsed.tags == ["fantasy", "elf"]
      assert parsed.source_file == "Ann_1"

      assert parsed.foreign == %{
               "data" => %{"fav" => true},
               "extensions" => %{"world" => " AnnWorld ", "other_tool" => %{"a" => 1}}
             }

      by_name = Map.new(parsed.card_fields, &{&1.attrs.name, &1})
      refute Map.has_key?(by_name, "System prompt")
      assert %{ignore_budget: true, prevent_recursion: true} = by_name["Personality"].attrs
    end

    test "errors" do
      assert {:error, "This isn't a valid PNG file."} = Import.parse("x.png", "nope")
      assert {:error, "This PNG has no character card in it."} = Import.parse("x.png", @png)
    end
  end

  describe "JSON cards" do
    test "V1" do
      json = Jason.encode!(%{"name" => "Bob", "description" => "D", "creatorcomment" => "note", "talkativeness" => 3})

      assert {:ok, %{kind: :character, name: "Bob", creator_notes: "note", talkativeness: 1.0}} =
               Import.parse("bob.json", json)
    end

    test "Pygmalion" do
      json =
        Jason.encode!(%{"char_name" => "Pyg", "char_persona" => "P", "world_scenario" => "S", "char_greeting" => "Hey"})

      assert {:ok, %{name: "Pyg", description: "P", first_message: "Hey", card_fields: [scenario]}} =
               Import.parse("p.json", json)

      assert scenario.attrs.name == "Scenario"
    end

    test "no name" do
      assert {:error, "This card has no name."} =
               Import.parse("x.json", Jason.encode!(%{"spec" => "chara_card_v2", "data" => %{"name" => " "}}))
    end
  end

  describe "world info" do
    test "maps positions, logic and switches" do
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
          "displayIndex" => 9
        })
        |> Map.put("10", %{"uid" => 10, "key" => ["x"], "content" => " ", "displayIndex" => 10})

      assert {:ok, %{kind: :lore_book, name: "World", entries: specs, warnings: warnings}} =
               Import.parse("World.json", Jason.encode!(%{"entries" => entries}))

      attrs = Enum.map(specs, & &1.attrs)

      assert [
               %{outlet: :character, placement: :before, secondary_logic: :and_any},
               %{outlet: :character, placement: :after, secondary_logic: :not_all},
               %{outlet: :author_note, placement: :before, secondary_logic: :not_any},
               %{outlet: :author_note, placement: :after, secondary_logic: :and_all},
               %{outlet: :at_depth, depth: 3},
               %{outlet: :examples, placement: :before},
               %{outlet: :examples, placement: :after},
               %{outlet: :custom, custom_outlet: "my_outlet"} | _
             ] = attrs

      assert Enum.at(specs, 7).outlet == %{key: "my_outlet", name: "My Outlet!"}
      assert hd(attrs).secondary_keywords == ["s"]

      no_keys = Enum.at(specs, 8)
      assert %{activation: :constant} = no_keys.attrs
      refute no_keys.enabled

      off = Enum.at(specs, 9)
      refute off.enabled
      assert off.attrs.probability == 100

      # An empty entry is kept: it can still trigger others.
      assert length(specs) == 11
      assert Enum.at(specs, 10).attrs.content == " "
      # No position: SillyTavern never inserts it.
      assert Enum.at(specs, 9).attrs.trigger_only
      assert "'Entry 8' had no keywords; imported switched off." in warnings
    end

    test "decorators" do
      cases = [
        {"@@activate\nText", %{activation: :constant, content: "Text"}, true},
        {"@@dont_activate\nText", %{activation: :keyword, content: "Text"}, false},
        {"@@foo\nText", %{activation: :keyword, content: "Text"}, true},
        {"@@@literal", %{activation: :keyword, content: "@@@literal"}, true},
        {"@@foo\n@@@activate\nText", %{activation: :constant, content: "Text"}, true}
      ]

      for {content, attrs, enabled} <- cases do
        {[spec], warnings} = world([%{"key" => ["k"], "content" => content}])
        assert ^attrs = Map.take(spec.attrs, [:activation, :content])
        assert spec.enabled == enabled
        if content =~ "@@foo", do: assert("Unknown decorator @@foo in 'k'." in warnings)
      end

      {_specs, warnings} = world([%{"key" => ["k"], "content" => "@@activate\nText"}])
      assert "Converted decorators in 1 entry." in warnings
    end

    test "keys follow SillyTavern's regex shape and convert macros" do
      {[spec], warnings} =
        world([%{"key" => ["/dragon/gi", "/r/roleplay", "/(/", "foo", "{{char}}"], "content" => "c"}])

      assert spec.attrs.keywords == ["/dragon/i", "/r/roleplay", "foo", "{{ anchors.character.name }}"]
      assert "'/dragon/gi': key /(/ isn't a valid regex here and was dropped." in warnings
    end

    test "keys with flags outside ST's are text, as in SillyTavern; an uncompilable regex is dropped" do
      {[spec], warnings} = world([%{"key" => ["foo", "/a/b", "/x/v", "/(dragon/i"], "content" => "c"}])

      assert spec.attrs.keywords == ["foo", "/a/b", "/x/v"]
      assert "'foo': key /(dragon/i isn't a valid regex here and was dropped." in warnings
      refute Enum.any?(warnings, &(&1 =~ "plain text in SillyTavern"))
    end

    test "orders are whole numbers, shifted up so none is negative" do
      {specs, warnings} =
        world([
          %{"key" => ["a"], "content" => "a", "order" => -5},
          %{"key" => ["b"], "content" => "b", "order" => 3},
          %{"key" => ["c"], "content" => "c", "order" => "5"}
        ])

      assert Enum.map(specs, & &1.order) == [0, 8, 10]
      assert "Shifted orders up by 5 so none is negative." in warnings
    end

    test "shifting negative orders lowers the book's order adjustment by as much" do
      json = %{
        "stlo" => %{"orderAdjustment" => 10},
        "entries" => [
          %{"key" => ["a"], "content" => "a", "order" => -5},
          %{"key" => ["b"], "content" => "b", "order" => 3}
        ]
      }

      parsed = WorldInfo.normalize(json, "W")
      assert Enum.map(parsed.entries, & &1.order) == [0, 8]
      assert parsed.book.order_adjustment == 5

      assert WorldInfo.normalize(%{json | "stlo" => %{}}, "W").book.order_adjustment == -5
      assert WorldInfo.normalize(Map.delete(json, "stlo"), "W").book.order_adjustment == -5

      refute Map.has_key?(
               WorldInfo.normalize(%{"entries" => [%{"key" => ["a"], "content" => "a"}]}, "W").book,
               :order_adjustment
             )
    end

    test "malformed or reserved keys parse without raising" do
      # A user-supplied `_foreign` key is just an unmapped key (dropped, as `_`-prefixed keys are).
      {[spec], _warnings} = world([%{"key" => ["k"], "content" => "c", "_foreign" => "x"}])
      assert spec.attrs.foreign == %{}

      cb = %{
        "recursive_scanning" => %{},
        "scan_depth" => [1],
        "entries" => [%{"keys" => ["k"], "content" => "c", "_foreign" => "x", "extensions" => %{"other" => 1}}]
      }

      parsed = WorldInfo.character_book(cb, "Book")
      assert [%{attrs: %{foreign: %{"character_book" => %{"extensions" => %{"other" => 1}}}}}] = parsed.entries

      assert "The embedded book's scan_depth [1], recursive_scanning {} weren't applied (SillyTavern ignores them)." in parsed.warnings

      stlo = %{"budgetMode" => "percentage_context", "budget" => %{"x" => 1}}
      assert %{warnings: warnings} = WorldInfo.normalize(%{"entries" => [], "stlo" => stlo}, "W")
      assert Enum.any?(warnings, &(&1 =~ ~s|percentage_context ({"x":1}%)|))
    end

    test "a file's stale originalData and non-map extensions aren't kept" do
      json = %{
        "entries" => [%{"key" => ["k"], "content" => "c"}],
        "originalData" => %{"name" => "Card book"},
        "extensions" => [],
        "other" => 1
      }

      assert WorldInfo.normalize(json, "W").book.foreign == %{"world_info" => %{"other" => 1}}

      cb = %{"extensions" => "x", "entries" => [%{"keys" => ["k"], "content" => "c"}]}
      refute Map.has_key?(WorldInfo.character_book(cb, "Book").book, :foreign)
    end

    test "groups, activation-only, empty content and foreign keys" do
      {[spec], _warnings} =
        world([
          %{
            "key" => ["k"],
            "content" => "",
            "group" => "G, H",
            "groupWeight" => 40,
            "groupOverride" => true,
            "activationOnly" => true,
            "position" => 0,
            "someTool" => %{"x" => 1}
          }
        ])

      assert [%{name: "G", weight: 40, override: true, scored: false}, %{name: "H"}] = spec.pools
      assert spec.attrs.trigger_only
      assert spec.attrs.content == ""
      assert spec.attrs.foreign == %{"world_info" => %{"someTool" => %{"x" => 1}}}
    end

    test "Aikobots stlo sets the book priority" do
      json = %{"entries" => [%{"key" => ["k"], "content" => "c"}], "stlo" => %{"priority" => 5}}
      assert {:ok, %{book: %{priority: 5}}} = Import.parse("W.json", Jason.encode!(json))
    end

    test "an embedded book's own budget isn't applied" do
      cb = %{"token_budget" => 200, "entries" => [%{"keys" => ["k"], "content" => "c"}]}
      parsed = WorldInfo.character_book(cb, "Book")

      refute Map.has_key?(parsed.book, :token_budget)
      assert parsed.book.foreign == %{"character_book" => %{"token_budget" => 200}}
      assert "The embedded book's token_budget 200 weren't applied (SillyTavern ignores them)." in parsed.warnings
    end
  end

  defp world(entries) do
    %{entries: specs, warnings: warnings} = WorldInfo.normalize(%{"entries" => entries}, "W")
    {specs, warnings}
  end

  describe "chat" do
    test "parses header, swipes, reasoning, system messages and dates" do
      lines = [
        %{"user_name" => "Me", "character_name" => "Ann", "create_date" => "2024-01-01T00:00:00Z"},
        %{
          "name" => "Ann",
          "mes" => "b",
          "send_date" => 1_700_000_000_000,
          "swipes" => ["a", "b"],
          "swipe_id" => 1,
          "extra" => %{"reasoning" => "think"},
          "swipe_info" => [%{"extra" => %{"reasoning" => "old"}}, %{}]
        },
        %{"name" => " Me ", "is_user" => true, "mes" => "hi", "send_date" => "2024-3-5 @14h 30m 12s 345ms"},
        %{
          "name" => "System",
          "is_system" => true,
          "mes" => "note",
          "send_date" => "March 5, 2024 2:30pm",
          "extra" => %{"type" => "narrator"}
        },
        %{"name" => "Ann", "mes" => "x", "send_date" => "garbage"}
      ]

      jsonl = Enum.map_join(lines, "\n", &Jason.encode!/1)
      assert {:ok, chat} = Import.parse("My Chat.jsonl", jsonl)
      assert %{kind: :chat, name: "My Chat", player_name: "Me"} = chat

      assert [%{key: 0, name: "Ann", count: 2}, %{key: 1, name: "Me"}, %{key: 2, name: "System", narrator?: true}] =
               chat.speakers

      [first, second, third, fourth] = chat.messages
      assert first.active == 1
      assert first.bodies == [%{content: "a", reasoning: "old"}, %{content: "b", reasoning: "think"}]
      assert first.inserted_at == DateTime.from_unix!(1_700_000_000_000, :millisecond) |> Map.put(:microsecond, {0, 6})
      assert second.inserted_at == ~U[2024-03-05 14:30:12.345000Z]
      assert third.inserted_at == ~U[2024-03-05 14:30:00.000000Z]
      refute third.visible_to_ai
      assert second.visible_to_ai
      assert fourth.inserted_at == third.inserted_at
    end

    test "player from is_user without header; errors" do
      jsonl =
        Enum.map_join(
          [%{"name" => "U", "is_user" => true, "mes" => "a"}, %{"name" => "B", "mes" => "b"}],
          "\n",
          &Jason.encode!/1
        )

      assert {:ok, %{player_name: "U"}} = Import.parse("c.jsonl", jsonl)
      assert {:error, "Line 2 isn't valid JSON."} = Import.parse("c.jsonl", ~s({"mes":"a"}\n{bad))
      assert {:error, "This chat has no messages."} = Import.parse("c.jsonl", ~s({"user_name":"U"}))
    end

    test "timestamp formats" do
      assert Chat.timestamp("2024-01-02T03:04:05") == ~U[2024-01-02 03:04:05.000000Z]
      assert Chat.timestamp("1700000000000") == Chat.timestamp(1_700_000_000_000)
      assert Chat.timestamp("nope") == nil
    end
  end

  defp preset_json do
    prompts = [
      %{"identifier" => "main", "name" => "Main Prompt", "role" => "system", "content" => "Be good."},
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
      "temperature" => 1,
      "top_p" => 5,
      "seed" => -1,
      "openai_max_tokens" => 300,
      "impersonation_prompt" => "Pretend",
      "wi_format" => "{0}",
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

  describe "preset" do
    test "orders blocks from prompt_order 100001" do
      assert {:ok, preset} = Import.parse("Default.json", Jason.encode!(preset_json()))
      assert %{kind: :preset, name: "Default"} = preset

      assert Enum.map(preset.blocks, & &1.name) == [
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

      by_name = Map.new(preset.blocks, &{&1.name, &1})
      refute by_name["Default: Enhance Definitions"].enabled
      assert %{kind: :chat_history, content: nil} = by_name["Default: Chat history"]
      assert by_name["Default: Main Prompt"].content == "Be good."

      assert preset.sampler == %{temperature: 1, max_tokens: 300}
      assert "Sampler top_p = 5 is out of range and was skipped." in preset.warnings
      assert preset.ignored == ["impersonation_prompt"]
      assert "Not imported: impersonation_prompt" in preset.warnings
    end

    test "main and post-history prompts carry their role tags" do
      assert {:ok, preset} = Import.parse("Default.json", Jason.encode!(preset_json()))
      by_name = Map.new(preset.blocks, &{&1.name, &1})

      assert %{role_tag: :main, forbid_overrides: false} = by_name["Default: Main Prompt"]
      assert %{role_tag: :post_history, forbid_overrides: false} = by_name["Default: Post-History Instructions"]
      refute Map.has_key?(by_name["Default: Enhance Definitions"], :role_tag)
    end

    test "text-completion preset" do
      assert {:error,
              "Only SillyTavern Chat Completion presets can be imported; this looks like a text-completion preset or template."} =
               Import.parse("tc.json", Jason.encode!(%{"temp" => 0.7, "rep_pen" => 1.1}))
    end

    test "other app and unknown" do
      assert {:error, "That file is from another app; only SillyTavern and Character Card files are supported."} =
               Import.parse("x.json", Jason.encode!(%{"messages" => []}))

      assert {:error, "Unrecognized file."} = Import.parse("x.json", "{}")
      assert {:error, "Unrecognized file."} = Import.parse("x.txt", "{}")
      assert {:error, "This file isn't valid JSON."} = Import.parse("x.json", "{")
    end
  end
end
