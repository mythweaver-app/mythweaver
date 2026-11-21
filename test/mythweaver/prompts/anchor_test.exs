defmodule Mythweaver.Prompts.AnchorTest do
  # `Anchor.catalog/0` is hand-written next to `Anchor.data/2` and `docs/prompts/templates.md`. These tests
  # build the real `anchors` data for a chat where every value is populated and hold the catalog to
  # it, and the doc to the catalog, so a path, type or field changed in one place fails here.
  use Mythweaver.DataCase

  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Lore
  alias Mythweaver.Messages
  alias Mythweaver.Prompts.Anchor
  alias Mythweaver.Prompts.Builder
  alias Mythweaver.Prompts.Prompt
  alias Mythweaver.Tags

  @doc_path Path.expand("../../../docs/prompts/templates.md", __DIR__)

  setup do
    %{scope: scope!()}
  end

  setup %{scope: scope} do
    %{anchors: populated_anchors(scope), catalog: Anchor.catalog()}
  end

  describe "the catalog against Prompts.Builder's anchors" do
    test "every catalog path exists, is populated, and has its declared type", ctx do
      assert_paths_typed(ctx.anchors, ctx.catalog)
    end

    test "every anchors leaf has a catalog entry", ctx do
      catalog_paths = MapSet.new(ctx.catalog, & &1.path)

      for path <- leaves(ctx.anchors, "anchors") do
        assert path in catalog_paths, "#{path} is produced but missing from Anchor.catalog/0"
      end
    end

    test "array<map> items carry exactly their declared fields, with their types", ctx do
      assert_item_fields(ctx.anchors, ctx.catalog)
    end
  end

  describe "the memory catalog against Prompts.Builder's anchors" do
    setup %{scope: scope} do
      %{anchors: populated_memory_anchors(scope), catalog: Anchor.memory_catalog()}
    end

    test "every memory catalog path exists, is populated, and has its declared type", ctx do
      assert_paths_typed(ctx.anchors, ctx.catalog)
    end

    test "every anchors.memory leaf has a memory catalog entry", ctx do
      catalog_paths = MapSet.new(ctx.catalog, & &1.path)

      for path <- leaves(ctx.anchors["memory"], "anchors.memory") do
        assert path in catalog_paths, "#{path} is produced but missing from Anchor.memory_catalog/0"
      end
    end

    test "array<map> items carry exactly their declared fields, with their types", ctx do
      assert_item_fields(ctx.anchors, ctx.catalog)
    end
  end

  describe "docs/prompts/templates.md against the catalog" do
    setup do
      %{doc: File.read!(@doc_path), catalog: Anchor.catalog() ++ Anchor.memory_catalog()}
    end

    test "every catalog path is documented with the same type", ctx do
      rows = rows(ctx.doc)

      for %{path: path, type: type} <- ctx.catalog do
        key =
          case path do
            "anchors.lore." <> slot ->
              assert ctx.doc =~ "`#{slot}`", "lore slot #{slot} is not listed in the doc"
              "anchors.lore.<slot>"

            path ->
              path
          end

        assert Map.get(rows, key) == type,
               "#{key} is #{type} in the catalog but #{inspect(Map.get(rows, key))} in the doc"
      end
    end

    test "every documented anchors path is a catalog path or a container of one", ctx do
      paths = Enum.map(ctx.catalog, & &1.path)

      for "anchors." <> _ = path <- Map.keys(rows(ctx.doc)), path != "anchors.lore.<slot>" do
        assert path in paths or Enum.any?(paths, &String.starts_with?(&1, path <> ".")),
               "#{path} is documented but neither in Anchor.catalog/0, Anchor.memory_catalog/0 nor a container of a catalog path"
      end
    end

    test "every array<map> item table matches the declared fields", ctx do
      for %{path: path, fields: fields} <- ctx.catalog do
        assert [_, after_heading] = String.split(ctx.doc, "Each `#{path}` item:", parts: 2),
               "the doc has no \"Each `#{path}` item:\" table"

        table = after_heading |> String.split("\n\n", trim: true) |> hd()
        assert rows(table) == Map.new(fields), "the #{path} item table disagrees with its catalog fields"
      end
    end
  end

  ## Fixture: one chat where every anchor has a value, built through the real builder.

  defp populated_anchors(scope) do
    player = character!(scope, "Player", %{pronouns: "she/her", description: "The player.", appearance: "Tall."})

    responder =
      character!(scope, "Responder", %{pronouns: "he/him", description: "The responder.", appearance: "Short."})

    other = character!(scope, "Other", %{description: "Someone else."})

    # Join all, so `anchors.other_characters` is populated (swap, the default, leaves it nil).
    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: "Fixture chat",
        participants: Enum.map([player, responder, other], &%{character_id: &1.id}),
        player_character_id: player.id
      })

    {:ok, chat} = Chats.update_chat(scope, chat, %{group_cards: :join_all})

    {:ok, _} = Messages.send_message(scope, chat, player.id, "Hello")

    # Tag the responder, the player, a member and the chat, so every `tags` path is populated.
    for item <- [player, responder, other, chat] do
      :ok = Tags.set_item_tags(scope, item, :mine, ["species:dragon"])
    end

    {:ok, book} = Lore.create_book(scope, %{name: "Fixture book"})
    {:ok, _} = Lore.bind_book_to_chat(book, chat.id)

    # One constant entry per built-in slot, so every `anchors.lore.<slot>` is filled.
    for {outlet, placement} <- [
          character: :before,
          character: :after,
          examples: :before,
          examples: :after,
          author_note: :before,
          author_note: :after,
          at_depth: :before
        ] do
      {:ok, _} =
        Lore.create_entry(
          scope,
          %{
            name: "#{outlet} #{placement}",
            content: "#{outlet} #{placement} lore",
            activation: :constant,
            outlet: outlet,
            placement: placement,
            depth: 1
          },
          [book.id]
        )
    end

    chat = Chats.get_chat!(chat.id)

    context =
      Builder.context(scope, chat,
        character: responder,
        guide: "Beats.",
        refine: %{instructions: "Shorter.", text: "A long reply."}
      )

    built = Builder.build(%Prompt{prompt_blocks: []}, context)
    built.state.data["anchors"]
  end

  # A minimal chat rendered with a hand-built memory map in which every key is filled, standing in for
  # what `Memory.Anchors.build/2` produces.
  defp populated_memory_anchors(scope) do
    player = character!(scope, "Player", %{})
    responder = character!(scope, "Responder", %{})

    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: "Memory fixture chat",
        participants: Enum.map([player, responder], &%{character_id: &1.id}),
        player_character_id: player.id
      })

    memory = %{
      "kind" => "memory",
      "scene" => "[#1] Responder: Hello",
      "scene_messages" => [%{"number" => 1, "author" => "Responder", "content" => "Hello"}],
      "range" => %{"start" => 1, "end" => 1},
      "speakers" => "Responder",
      "previous_memories" => [%{"title" => "Earlier", "content" => "They met."}],
      "previous_text" => "### Earlier\nThey met.",
      "context" => "### Setting\nA tavern.",
      "sources" => [%{"id" => "001", "title" => "Earlier", "content" => "They met."}],
      "sources_text" => "[001] Earlier\nThey met.",
      "previous_summary" => %{"title" => "Arc", "content" => "So far."},
      "target_tier" => %{"number" => 1, "name" => "Arc"},
      "entry" => %{"title" => "Tracker", "content" => "- plot", "kind" => "side_prompt"},
      "topic" => "The tavern",
      "keywords" => "tavern, ale",
      "clips" => [
        %{
          "uid" => "001",
          "type" => "ordinary",
          "title" => "Kai",
          "topic" => "",
          "keywords" => "Kai",
          "content" => "- likes tea"
        }
      ],
      "clips_text" => "[]",
      "character" => "Responder"
    }

    chat = Chats.get_chat!(chat.id)

    built =
      Builder.build(%Prompt{prompt_blocks: []}, Builder.context(scope, chat, character: responder, memory: memory))

    built.state.data["anchors"]
  end

  defp character!(scope, name, attrs) do
    {:ok, character} = Characters.create_character(scope, Map.put(attrs, :name, name))
    character
  end

  defp assert_paths_typed(anchors, catalog) do
    for %{path: path, type: type} <- catalog do
      value = fetch_path!(anchors, path)

      # The fixture fills everything, so a nil or empty value means the type went unchecked.
      refute value in [nil, []], "#{path} is #{inspect(value)} in the fixture; populate it"
      assert type?(value, type), "#{path} is declared #{type} but is #{inspect(value)}"
    end
  end

  defp assert_item_fields(anchors, catalog) do
    for %{path: path, type: "array<map>"} = entry <- catalog do
      assert fields = entry[:fields], "#{path} is array<map> but declares no fields"

      for item <- fetch_path!(anchors, path) do
        assert Enum.sort(Map.keys(item)) == fields |> Enum.map(&elem(&1, 0)) |> Enum.sort(),
               "#{path} items have keys #{inspect(Map.keys(item))}, declared #{inspect(fields)}"

        for {name, type} <- fields do
          assert type?(item[name], type),
                 "#{path}[].#{name} is declared #{type} but is #{inspect(item[name])}"
        end
      end
    end
  end

  ## Helpers

  defp fetch_path!(anchors, "anchors." <> path) do
    path
    |> String.split(".")
    |> Enum.reduce(anchors, fn key, acc ->
      assert is_map(acc) and Map.has_key?(acc, key), "anchors.#{path} is missing at #{key}"
      Map.fetch!(acc, key)
    end)
  end

  # Maps are containers; anything else (strings, lists, booleans) is a documented leaf.
  defp leaves(map, prefix) do
    Enum.flat_map(map, fn
      {key, value} when is_map(value) -> leaves(value, "#{prefix}.#{key}")
      {key, _value} -> ["#{prefix}.#{key}"]
    end)
  end

  defp type?(value, type), do: type |> String.split(" | ") |> Enum.any?(&type_one?(value, &1))

  defp type_one?(value, "array<" <> rest) do
    element = String.trim_trailing(rest, ">")
    is_list(value) and Enum.all?(value, &type?(&1, element))
  end

  defp type_one?(value, "string"), do: is_binary(value)
  defp type_one?(value, "bool"), do: is_boolean(value)
  defp type_one?(value, "int"), do: is_integer(value)
  defp type_one?(value, "float"), do: is_float(value)
  defp type_one?(value, "map"), do: is_map(value)
  defp type_one?(value, "nil"), do: is_nil(value)

  # `| `path` | `type` | …` table rows, keyed by path, with Markdown's escaped `\|` undone.
  defp rows(markdown) do
    ~r/^\| `([^`]+)` \| `([^`]+)` \|/m
    |> Regex.scan(markdown)
    |> Map.new(fn [_, path, type] -> {path, String.replace(type, "\\|", "|")} end)
  end
end
