defmodule Mythweaver.Import.BundleWriterTest do
  use Mythweaver.DataCase

  alias Mythweaver.Attachments
  alias Mythweaver.Attachments.MessageAttachment
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Export
  alias Mythweaver.Import
  alias Mythweaver.Import.Review
  alias Mythweaver.Injections
  alias Mythweaver.Lore
  alias Mythweaver.Lore.BookCharacter
  alias Mythweaver.Lore.BookEntry
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Memory
  alias Mythweaver.Memory.Record
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message
  alias Mythweaver.Messages.MessageBody
  alias Mythweaver.Prompts
  alias Mythweaver.Scripts
  alias Mythweaver.Tags
  alias Mythweaver.Variables

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
       )

  setup do
    %{scope: scope!()}
  end

  defp character!(scope, name, attrs \\ %{}) do
    {:ok, character} = Characters.create_character(scope, Map.put(attrs, :name, name))
    character
  end

  defp book!(scope, name) do
    {:ok, book} = Lore.create_book(scope, %{name: name})
    book
  end

  defp entry!(scope, book, attrs) do
    {:ok, entry} = Lore.create_entry(scope, Map.merge(%{content: "Text", activation: :constant}, attrs), [book.id])
    entry
  end

  defp parse!(scope, items) do
    {:ok, request} =
      Export.request(%{"items" => Enum.map(items, fn {kind, id} -> "#{kind}:#{id}" end), "format" => "native"})

    {:ok, %{bytes: bytes}} = Export.build(scope, request)
    {:ok, %{kind: :bundle} = parsed} = Import.parse("x.mythweaver", bytes)
    parsed
  end

  defp decisions(scope, parsed, decision), do: Map.new(Review.review(scope, parsed.bundle), &{&1.uid, decision})

  defp copy!(scope, parsed) do
    {:ok, result} = Import.import(scope, parsed, decisions: decisions(scope, parsed, :copy))
    result
  end

  defp tags(scope, item), do: scope |> Tags.item_tags(item) |> then(&(&1.site ++ &1.mine)) |> Enum.sort()

  defp bound_books(character) do
    Repo.all(
      from b in LoreBook,
        join: bc in BookCharacter,
        on: bc.lore_book_id == b.id,
        where: bc.character_id == ^character.id,
        order_by: b.name
    )
  end

  defp book_entries(book) do
    Repo.all(
      from e in LoreEntry,
        join: be in BookEntry,
        on: be.lore_entry_id == e.id,
        where: be.lore_book_id == ^book.id,
        order_by: e.name,
        preload: [:filter_characters, :filter_tags, :pool_entries]
    )
  end

  defp avatar_bytes(scope, character) do
    case Characters.preload_avatar(scope, character).avatar do
      nil -> nil
      avatar -> elem(Attachments.read(avatar), 1)
    end
  end

  describe "character with lore" do
    setup %{scope: scope} do
      character = character!(scope, "Seraphina", %{description: "A guardian."})
      ranger = character!(scope, "Ranger")
      {:ok, avatar} = Attachments.store_binary(@png)
      :ok = Attachments.set_avatar(scope, character, avatar)
      :ok = Tags.set_item_tags(scope, character, :mine, ["alpha", "beta"])

      book = book!(scope, "Forest")
      {:ok, _} = Lore.bind_book_to_character(book, character.id)
      {:ok, _} = Prompts.create_outlet(scope, %{key: "weather", name: "Weather", description: "Skies"})

      glade =
        entry!(scope, book, %{
          name: "Glade",
          outlet: :custom,
          custom_outlet: "weather",
          character_filter_mode: :include
        })

      {:ok, _} = Lore.set_entry_filter_characters(scope, glade, [ranger.id])
      {:ok, _} = Lore.set_entry_filter_tags(scope, glade, ["woods"])
      {:ok, pool} = Lore.create_pool(scope, %{name: "Weathers"})
      {:ok, _} = Lore.set_entry_pools(scope, glade, [pool.id])
      {:ok, :ok} = Lore.set_pool_memberships(scope, glade, %{pool.id => %{weight: 7}})

      memory = entry!(scope, book, %{name: "Memory one"})
      {:ok, _} = Memory.adopt_memories(scope, book, [%{entry_id: memory.id, tier: 0, source_entry_ids: []}])

      %{character: character, ranger: ranger, book: book}
    end

    test "Copy restores fields, tags, avatar, bound lore, filters, pool and memory", %{scope: scope} = ctx do
      parsed = parse!(scope, [{:character, ctx.character.id}])
      %{record: %Characters.Character{} = copy} = copy!(scope, parsed)

      assert copy.id != ctx.character.id
      assert copy.name == "Seraphina"
      assert copy.description == "A guardian."
      assert tags(scope, copy) == ["alpha", "beta"]
      assert avatar_bytes(scope, copy) == @png

      [book] = bound_books(copy)
      assert book.id != ctx.book.id
      assert book.name =~ "Forest"

      [glade, memory] = book_entries(book)
      assert glade.name == "Glade"
      assert glade.outlet == :custom and glade.custom_outlet == "weather"
      assert Prompts.get_outlet_by_key(book.user_id, "weather")
      assert glade.character_filter_mode == :include
      assert Enum.map(glade.filter_characters, & &1.name) == ["Ranger"]
      assert Enum.map(glade.filter_tags, & &1.name) == ["woods"]
      assert [%{weight: 7}] = glade.pool_entries

      assert %Record{kind: :memory, tier: 0} = Repo.get_by(Record, lore_entry_id: memory.id)
    end

    test "re-import: review defaults to Replace; Replace, Copy and Skip", %{scope: scope} = ctx do
      parsed = parse!(scope, [{:character, ctx.character.id}])
      rows = Review.review(scope, parsed.bundle)
      row = Enum.find(rows, &(&1.kind == :character and &1.root?))

      assert row.match.id == ctx.character.id
      assert row.default == :replace
      assert row.options == [:replace, :copy, :skip]

      {:ok, _} = Characters.update_character(scope, ctx.character, %{description: "Changed"})
      {:ok, %{record: replaced}} = Import.import(scope, parsed)
      assert replaced.id == ctx.character.id
      assert Characters.get_character!(ctx.character.id).description == "A guardian."
      # The bound book was replaced in place, not duplicated.
      assert [%{id: book_id}] = bound_books(replaced)
      assert book_id == ctx.book.id

      count = length(Characters.list_characters(scope))
      {:ok, %{record: copy}} = Import.import(scope, parsed, decisions: %{row.uid => :copy})
      assert copy.id != ctx.character.id
      assert length(Characters.list_characters(scope)) == count + 1

      assert {:error, "Nothing was imported: every item was skipped."} =
               Import.import(scope, parsed, decisions: decisions(scope, parsed, :skip))
    end

    test "Replace of a book drops entries that aren't in the bundle", %{scope: scope} = ctx do
      parsed = parse!(scope, [{:lore_book, ctx.book.id}])
      local = entry!(scope, ctx.book, %{name: "Local only"})

      {:ok, %{record: book}} = Import.import(scope, parsed)
      assert book.id == ctx.book.id
      assert Enum.map(book_entries(book), & &1.name) == ["Glade", "Memory one"]
      assert Repo.get(LoreEntry, local.id)
    end
  end

  test "a chat with swipes, attachments, injections, variables and memory", %{scope: scope} do
    player = character!(scope, "Player")
    bot = character!(scope, "Bot")

    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: "Adventure",
        player_character_id: player.id,
        participants: [%{character_id: player.id}, %{character_id: bot.id}]
      })

    {:ok, image} = Attachments.store_binary(@png)
    at = ~U[2026-01-01 10:00:00.000000Z]

    :ok =
      Messages.import_transcript(chat, [
        %{
          author_character_id: player.id,
          author_name: nil,
          visible_to_ai: true,
          inserted_at: at,
          active: 0,
          attachments: [image],
          bodies: [%{content: "Hello"}]
        },
        %{
          author_character_id: bot.id,
          author_name: nil,
          visible_to_ai: true,
          inserted_at: DateTime.add(at, 60),
          active: 1,
          bodies: [
            %{content: "Hi"},
            %{content: "Greetings", origin: :regenerate, prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
          ]
        },
        %{
          author_character_id: bot.id,
          author_name: nil,
          visible_to_ai: true,
          inserted_at: DateTime.add(at, 120),
          active: 0,
          bodies: [%{content: "Onward"}]
        }
      ])

    {:ok, _} = Injections.create_injection(scope, chat.id, %{key: "mood", content: "Tense"})
    {:ok, _} = Variables.create_variable(scope, chat.id, %{key: "gold", value: 3})

    book = book!(scope, "Adventure memories")
    {:ok, _} = Lore.set_chat_books(chat, [book.id])
    settings = Memory.chat_settings(scope, chat)
    {:ok, settings} = Memory.update_chat_settings(scope, settings, %{memory_book_id: book.id, auto_enabled: true})
    :ok = Memory.restore_progress(settings, 2)

    entry = entry!(scope, book, %{name: "Scene"})

    %Record{}
    |> Record.changeset(%{lore_entry_id: entry.id, lore_book_id: book.id, chat_id: chat.id, kind: :memory, tier: 0})
    |> Ecto.Changeset.change(range_start: 1, range_end: 2, sequence: 1)
    |> Repo.insert!()

    parsed = parse!(scope, [{:chat, chat.id}])
    %{record: %Chats.Chat{} = copy} = copy!(scope, parsed)

    assert copy.id != chat.id
    assert copy.name == "Adventure"

    messages = Repo.all(from m in Message, where: m.chat_id == ^copy.id, order_by: m.position, preload: :bodies)
    assert Enum.map(messages, & &1.position) == [0, 1, 2]
    [first, second, _] = messages
    assert Repo.exists?(from a in MessageAttachment, where: a.message_id == ^first.id)

    [greetings, hi] = Enum.sort_by(second.bodies, & &1.content)
    assert hi.content == "Hi" and not hi.active
    assert %MessageBody{origin: :regenerate, prompt_tokens: 10, total_tokens: 15, active: true} = greetings

    assert [%{key: "mood", content: "Tense"}] = Injections.list_injections(scope, copy.id)
    assert [%{key: "gold", value: 3}] = Variables.list_chat_variables(scope, copy.id)

    copy_settings = Memory.chat_settings(scope, copy)
    assert copy_settings.auto_enabled
    assert copy_settings.highest_processed == 2
    assert copy_settings.memory_book_id && copy_settings.memory_book_id != book.id

    [copied_entry] = book_entries(Repo.get!(LoreBook, copy_settings.memory_book_id))
    record = Repo.get_by!(Record, lore_entry_id: copied_entry.id)
    assert record.chat_id == copy.id
    assert {record.range_start, record.range_end} == {1, 2}
  end

  test "a prompt's blocks and a script's dependency", %{scope: scope} do
    {:ok, prompt} = Prompts.create_prompt(scope, %{name: "Story"})
    {:ok, history} = Prompts.create_block(scope, %{name: "History", kind: :chat_history, role: :user})
    {:ok, intro} = Prompts.create_block(scope, %{name: "Intro", content: "Be kind."})
    {:ok, outro} = Prompts.create_block(scope, %{name: "Outro", content: "Bye."})
    {:ok, _} = Prompts.add_block(scope, prompt, intro)
    {:ok, _} = Prompts.add_block(scope, prompt, history)
    {:ok, _} = Prompts.add_block(scope, prompt, outro, %{enabled: false})

    {:ok, base} = Scripts.create_script(scope, %{name: "Base", trigger: :ai_generation, body: "return 1"})

    {:ok, top} =
      Scripts.create_script(scope, %{name: "Top", trigger: :ai_generation, body: "return 2", dependency_ids: [base.id]})

    parsed = parse!(scope, [{:prompt, prompt.id}, {:script, top.id}])
    copy!(scope, parsed)

    copy = Enum.find(Prompts.list_prompts(scope), &(&1.name != "Story" and &1.name =~ "Story"))
    memberships = Prompts.list_prompt_blocks(copy)

    assert Enum.map(memberships, &{&1.block.kind, &1.enabled}) == [
             {:template, true},
             {:chat_history, true},
             {:template, false}
           ]

    assert Enum.map(memberships, & &1.block.content) |> Enum.at(0) == "Be kind."
    refute Enum.any?(memberships, &(&1.block_id in [intro.id, history.id, outro.id]))

    top_copy = Enum.find(Scripts.list_scripts(scope), &(&1.name != "Top" and &1.name =~ "Top"))
    [dependency] = top_copy.dependencies
    assert dependency.name =~ "Base"
    assert dependency.id != base.id
  end

  describe "a chat linking a runtime-only character by ref" do
    setup do
      admin = scope!()
      user = scope!(%{role: :user})

      {:ok, sphinx} =
        Characters.create_character(
          admin,
          %{name: "Sphinx", description: "riddle answer", site_visibility: :runtime_only},
          site: true
        )

      me = character!(user, "Me")
      bot = character!(user, "Bot")

      {:ok, chat} =
        Chats.create_chat(user, %{
          name: "Riddles",
          player_character_id: me.id,
          participants: [%{character_id: me.id}, %{character_id: bot.id}, %{character_id: sphinx.id}]
        })

      parsed = parse!(user, [{:chat, chat.id}])
      chat_item = Enum.find(parsed.bundle.items, &(&1.kind == :chat))

      assert [%{"kind" => "character", "name" => "Sphinx"}] =
               for(%{"character" => %{} = ref} <- chat_item.data["participants"], do: ref)

      refute inspect(parsed.bundle) =~ "riddle answer"

      # Another site: the exporter's Sphinx isn't there.
      {:ok, _} = Chats.delete_chat(user, chat)
      Repo.delete!(sphinx)

      %{user: user, parsed: parsed}
    end

    test "links the participant to a usable character of that name", %{parsed: parsed} do
      other = scope!(%{role: :user})
      own = character!(other, "Sphinx")

      %{record: %Chats.Chat{} = copy, warnings: warnings} = copy!(other, parsed)

      assert own.id in Enum.map(Chats.get_chat(other, copy.id).participants, & &1.character_id)
      refute Enum.any?(warnings, &(&1 =~ "Sphinx"))
    end

    test "without one, the warning names the character", %{user: user, parsed: parsed} do
      %{record: %Chats.Chat{} = copy, warnings: warnings} = copy!(user, parsed)

      assert "'Riddles' links to character 'Sphinx', which isn't here." in warnings
      assert length(Chats.get_chat(user, copy.id).participants) == 2
    end
  end
end
