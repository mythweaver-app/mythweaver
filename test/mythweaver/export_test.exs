defmodule Mythweaver.ExportTest do
  use Mythweaver.DataCase

  alias Mythweaver.Attachments
  alias Mythweaver.Attachments.Proxy
  alias Mythweaver.Bundle
  alias Mythweaver.Bundle.Origins
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Export
  alias Mythweaver.Export.Collect
  alias Mythweaver.Export.Request
  alias Mythweaver.Import.Png
  alias Mythweaver.Injections
  alias Mythweaver.Lore
  alias Mythweaver.Memory
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message
  alias Mythweaver.Prompts
  alias Mythweaver.Tags
  alias Mythweaver.Variables

  @unavailable "Something you picked is no longer available."
  @not_png "The avatar isn't a PNG and the image proxy can't convert it; choose CHARX to keep it."

  setup do
    %{scope: scope!(%{role: :user}), admin: scope!()}
  end

  defp png,
    do:
      Base.decode64!("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")

  # A JPEG header with a 1x1 frame: enough for the attachment store, which only reads the header.
  defp jpeg, do: <<0xFF, 0xD8, 0xFF, 0xC0, 0, 11, 8, 0, 1, 0, 1, 1, 1, 0x11, 0, 0xFF, 0xD9>>

  defp sha(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp put_attachments_config(changes) do
    original = Application.get_env(:mythweaver, Attachments)
    Application.put_env(:mythweaver, Attachments, Keyword.merge(original, changes))
    on_exit(fn -> Application.put_env(:mythweaver, Attachments, original) end)
  end

  defp xi_config do
    [
      base_url: "http://img",
      source_prefix: "xi://uploads/",
      key: "736563726574",
      salt: "68656C6C6F",
      encryption_key: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    ]
  end

  defp character!(scope, name, attrs \\ %{}, opts \\ []) do
    {:ok, character} = Characters.create_character(scope, Map.merge(%{name: name}, attrs), opts)
    character
  end

  defp avatar!(scope, character, bytes) do
    {:ok, attachment} = Attachments.store_binary(bytes)
    :ok = Attachments.set_avatar(scope, character, attachment, describe: false)
    attachment
  end

  defp book!(scope, name, attrs \\ %{}, opts \\ []) do
    {:ok, book} = Lore.create_book(scope, Map.merge(%{name: name}, attrs), opts)
    book
  end

  defp entry!(scope, name, book_ids, attrs \\ %{}) do
    defaults = %{name: name, content: "#{name} content", keywords: [name]}
    {:ok, entry} = Lore.create_entry(scope, Map.merge(defaults, attrs), book_ids)
    entry
  end

  defp chat!(scope, [player | _] = characters) do
    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: "Tavern talk",
        participants: Enum.map(characters, &%{character_id: &1.id}),
        player_character_id: player.id
      })

    Chats.get_chat!(chat.id)
  end

  defp collect!(scope, items, opts \\ []) do
    {:ok, bundle, warnings} = Collect.run(scope, items, opts)
    {bundle, warnings}
  end

  defp item(bundle, kind, name), do: Enum.find(bundle.items, &(&1.kind == kind and &1.name == name))

  defp kinds(bundle), do: Enum.map(bundle.items, & &1.kind)

  defp assert_json_safe(bundle) do
    for item <- bundle.items, do: assert(Jason.decode!(Jason.encode!(item.data)) == item.data)
    for {_chat, messages} <- bundle.messages, do: assert(Jason.decode!(Jason.encode!(messages)) == messages)
  end

  describe "request/1" do
    test "parses items, format and sampler model" do
      id = Ecto.UUID.generate()
      model_id = Ecto.UUID.generate()

      assert Export.request(%{
               "items" => ["character:#{id}", "character:#{id}", "connection:#{id}", "chat:not-a-uuid", 7],
               "format" => "native",
               "sampler_model_id" => ""
             }) == {:ok, %Request{items: [{:character, id}], format: :native, sampler_model_id: nil}}

      assert Export.request(%{"items" => ["prompt:#{id}"], "format" => "st_preset", "sampler_model_id" => model_id}) ==
               {:ok, %Request{items: [{:prompt, id}], format: :st_preset, sampler_model_id: model_id}}

      assert {:ok, %Request{format: :native}} = Export.request(%{"items" => ["chat:#{id}"]})
    end

    test "refuses an empty selection and an unknown format" do
      id = Ecto.UUID.generate()

      assert Export.request(%{}) == {:error, "Choose something to export."}
      assert Export.request(%{"items" => ["bogus:#{id}"]}) == {:error, "Choose something to export."}

      assert Export.request(%{"items" => ["character:#{id}"], "format" => "exe"}) ==
               {:error, "Unknown export format."}
    end
  end

  describe "exportables/2" do
    test "leaves out site lore whose content is hidden, unless the scope may see it",
         %{scope: scope, admin: admin} do
      open = book!(admin, "Open atlas", %{}, site: true)
      book!(admin, "Names atlas", %{site_visibility: :runtime_only}, site: true)
      book!(admin, "Secret atlas", %{site_visibility: :hidden}, site: true)
      own = book!(scope, "My notes")

      assert Enum.map(Export.exportables(scope, :lore_book), & &1.id) |> Enum.sort() == Enum.sort([open.id, own.id])

      assert ["Names atlas", "Open atlas", "Secret atlas"] --
               Enum.map(Export.exportables(admin, :lore_book), & &1.name) == []
    end

    test "leaves out runtime-only site characters, unless the scope may see them", %{scope: scope, admin: admin} do
      character!(admin, "Sphinx", %{site_visibility: :runtime_only}, site: true)
      open = character!(admin, "Herald", %{}, site: true)

      names = Enum.map(Export.exportables(scope, :character), & &1.name)
      assert open.name in names
      refute "Sphinx" in names
      assert "Sphinx" in Enum.map(Export.exportables(admin, :character), & &1.name)
    end

    test "chats are the scope's own role-play chats, named by title", %{scope: scope, admin: admin} do
      chat = chat!(scope, [character!(scope, "Me"), character!(scope, "Bot")])
      chat!(admin, [character!(admin, "Admin"), character!(admin, "Other")])

      assert Export.exportables(scope, :chat) == [%{id: chat.id, name: "Tavern talk"}]
    end
  end

  describe "Collect.run/3" do
    test "a character carries its avatar, bound books, entries, pools, outlets and memory", %{scope: scope} do
      hero = character!(scope, "Hero", %{description: "Brave."})
      villain = character!(scope, "Villain")
      avatar!(scope, hero, png())
      :ok = Tags.set_item_tags(scope, hero, :mine, ["hero", "mood:brave"])

      {:ok, _outlet} = Prompts.create_outlet(scope, %{key: "sidebar", name: "Sidebar", description: "Aside"})
      book = book!(scope, "Hero lore")
      {:ok, :ok} = Lore.set_book_characters(scope, book, [hero.id])

      castle =
        entry!(scope, "Castle", [book.id], %{
          outlet: :custom,
          custom_outlet: "sidebar",
          character_filter_mode: :include
        })

      {:ok, _} = Lore.set_entry_filter_characters(scope, castle, [villain.id])
      {:ok, :ok} = Lore.set_entry_filter_tags(scope, castle, ["place"])
      {:ok, pool} = Lore.create_pool(scope, %{name: "Places"})
      {:ok, _} = Lore.set_entry_pools(scope, castle, [pool.id])
      {:ok, :ok} = Lore.set_pool_memberships(scope, castle, %{pool.id => %{weight: 40}})
      {:ok, 1} = Memory.import_records(scope, book, [%{entry_id: castle.id, kind: :memory, tier: 0, sequence: 3}])

      {bundle, warnings} = collect!(scope, [{:character, hero.id}])

      assert warnings == []
      assert kinds(bundle) == [:prompt_outlet, :lore_pool, :lore_entry, :lore_book, :character]
      assert Enum.map(bundle.items, & &1.position) == [0, 1, 2, 3, 4]
      assert Enum.map(bundle.items, & &1.root) == [false, false, false, false, true]
      assert_json_safe(bundle)

      character = item(bundle, :character, "Hero")
      assert character.uid == hero.id
      assert character.data["description"] == "Brave."
      assert character.data["talkativeness"] == 0.5
      assert character.data["avatar"] == sha(png())
      assert character.data["books"] == [%{"uid" => book.id, "enabled" => true}]
      assert character.data["tags"] == ["hero", "mood:brave"]

      assert %{kind: :image, content_type: "image/png", bytes: bytes} = bundle.blobs[sha(png())]
      assert bytes == png()

      assert item(bundle, :lore_book, "Hero lore").data["entries"] == [
               %{"uid" => castle.id, "order" => 1, "enabled" => true}
             ]

      entry = item(bundle, :lore_entry, "Castle").data
      assert entry["outlet"] == "custom"
      assert entry["custom_outlet"] == "sidebar"
      assert entry["character_filter_mode"] == "include"
      assert entry["filter_characters"] == [%{"kind" => "character", "uid" => villain.id, "name" => "Villain"}]
      assert entry["filter_tags"] == ["place"]
      assert entry["pools"] == [%{"uid" => pool.id, "weight" => 40, "override" => false, "scored" => false}]
      assert %{"kind" => "memory", "tier" => 0, "sequence" => 3, "chat" => nil, "sources" => []} = entry["memory"]

      assert item(bundle, :lore_pool, "Places").data == %{
               "name" => "Places",
               "description" => nil,
               "max_activations" => 1
             }

      assert item(bundle, :prompt_outlet, "Sidebar").data == %{
               "key" => "sidebar",
               "name" => "Sidebar",
               "description" => "Aside"
             }

      refute item(bundle, :character, "Villain")
    end

    test "a chat carries its characters, transcript, files, settings and remapped memory", %{scope: scope} do
      me = character!(scope, "Me")
      bot = character!(scope, "Bot")
      chat = chat!(scope, [me, bot])
      {:ok, image} = Attachments.store_binary(png())
      at = ~U[2026-01-02 03:04:05.000000Z]

      :ok =
        Messages.import_transcript(chat, [
          %{
            author_character_id: me.id,
            author_name: "Me",
            visible_to_ai: true,
            inserted_at: at,
            bodies: [%{content: "Hi"}],
            active: 0
          },
          %{
            author_character_id: bot.id,
            author_name: "Bot",
            visible_to_ai: true,
            inserted_at: at,
            bodies: [%{content: "Gone"}],
            active: 0
          },
          %{
            author_character_id: bot.id,
            author_name: "Bot",
            visible_to_ai: true,
            inserted_at: at,
            attachments: [image],
            bodies: [
              %{content: "Hello"},
              %{content: "Hello again", origin: :regenerate, prompt_tokens: 12, cost: Decimal.new("0.25")}
            ],
            active: 1
          },
          %{
            author_character_id: nil,
            author_name: "Narrator",
            visible_to_ai: false,
            inserted_at: at,
            bodies: [%{content: "Later"}],
            active: 0
          }
        ])

      [first, gone, third, fourth] = Repo.all(from(m in Message, where: m.chat_id == ^chat.id, order_by: m.position))
      Repo.delete!(gone)
      {:ok, _draft} = Messages.upsert_draft(scope, chat, "Unsent")

      {:ok, _} = Injections.create_injection(scope, chat.id, %{key: "weather", content: "Rain.", position: :at_depth})
      {:ok, _} = Variables.create_variable(scope, chat.id, %{key: "mood", value: "calm"})
      {:ok, memories} = Lore.create_chat_book(scope, chat, %{name: "Memories"})
      settings = Memory.chat_settings(scope, chat)
      {:ok, settings} = Memory.update_chat_settings(scope, settings, %{memory_book_id: memories.id, cast_ids: [bot.id]})
      :ok = Memory.restore_progress(settings, fourth.position)
      scene = entry!(scope, "Scene", [memories.id])

      {:ok, 1} =
        Memory.import_records(scope, memories, [
          %{entry_id: scene.id, kind: :memory, chat_id: chat.id, range_start: gone.position, range_end: third.position}
        ])

      {bundle, warnings} = collect!(scope, [{:chat, chat.id}])

      assert warnings == []
      assert kinds(bundle) == [:lore_entry, :lore_book, :character, :character, :chat]
      assert_json_safe(bundle)

      data = item(bundle, :chat, "Tavern talk").data
      assert data["player"] == me.id
      assert Enum.map(data["participants"], & &1["character"]) == [me.id, bot.id]
      assert data["books"] == [%{"uid" => memories.id, "enabled" => true}]

      assert [%{"key" => "weather", "content" => "Rain.", "position" => "at_depth", "depth" => 4}] =
               data["injections"]

      assert data["variables"] == [%{"key" => "mood", "value" => "calm"}]
      assert data["memory"]["memory_book"] == memories.id
      assert data["memory"]["cast_ids"] == [bot.id]
      assert data["memory"]["highest_processed"] == 2

      memory = item(bundle, :lore_entry, "Scene").data["memory"]
      assert memory["chat"] == chat.id
      assert {memory["range_start"], memory["range_end"]} == {1, 1}

      messages = bundle.messages[chat.id]
      assert Enum.map(messages, & &1["uid"]) == [first.id, third.id, fourth.id]
      assert Enum.map(messages, & &1["author"]) == [me.id, bot.id, nil]
      assert Enum.map(messages, & &1["author_name"]) == ["Me", "Bot", "Narrator"]
      assert Enum.at(messages, 1)["attachments"] == [sha(png())]

      assert [%{"content" => "Hello", "active" => false}, regen] = Enum.at(messages, 1)["bodies"]

      assert %{"active" => true, "origin" => "regenerate", "prompt_tokens" => 12, "cost" => "0.25", "attachments" => []} =
               regen

      assert %{kind: :image, bytes: bytes} = bundle.blobs[sha(png())]
      assert bytes == png()
    end

    test "an author outside the bundle is written by ref and by name", %{scope: scope} do
      me = character!(scope, "Me")
      bot = character!(scope, "Bot")
      guest = character!(scope, "Guest")
      chat = chat!(scope, [me, bot, guest])
      at = DateTime.utc_now()

      :ok =
        Messages.import_transcript(chat, [
          %{
            author_character_id: guest.id,
            author_name: nil,
            visible_to_ai: true,
            inserted_at: at,
            bodies: [%{content: "Hi"}],
            active: 0
          }
        ])

      {:ok, _} = Chats.remove_participant(scope, Enum.find(chat.participants, &(&1.character_id == guest.id)))

      {bundle, _warnings} = collect!(scope, [{:chat, chat.id}])
      guest_ref = %{"kind" => "character", "uid" => guest.id, "name" => "Guest"}
      assert [%{"author" => ^guest_ref, "author_name" => "Guest"}] = bundle.messages[chat.id]
    end

    test "payload: false reads no files and no transcript", %{scope: scope} do
      me = character!(scope, "Me")
      avatar!(scope, me, png())
      chat = chat!(scope, [me, character!(scope, "Bot")])

      :ok =
        Messages.import_transcript(chat, [
          %{
            author_character_id: me.id,
            author_name: "Me",
            visible_to_ai: true,
            inserted_at: DateTime.utc_now(),
            bodies: [%{content: "Hi"}],
            active: 0
          }
        ])

      {bundle, []} = collect!(scope, [{:chat, chat.id}], payload: false)
      assert bundle.blobs == %{}
      assert bundle.messages == %{}
      assert item(bundle, :character, "Me").data["avatar"] == nil
    end

    test "prompts carry their blocks, models their caption prompt, scripts their dependencies", %{admin: admin} do
      {:ok, prompt} = Prompts.create_prompt(admin, %{name: "Story"})
      {:ok, first} = Prompts.create_block(admin, %{name: "Intro", content: "Hello"})
      {:ok, history} = Prompts.create_block(admin, %{name: "History", kind: :chat_history})
      {:ok, _} = Prompts.add_block(admin, prompt, first)
      {:ok, membership} = Prompts.add_block(admin, prompt, history)
      {:ok, _} = Prompts.update_block_membership(admin, membership, %{enabled: false})

      {:ok, base} = Mythweaver.Scripts.create_script(admin, %{name: "Base", body: "", trigger: :command})

      {:ok, top} =
        Mythweaver.Scripts.create_script(admin, %{name: "Top", body: "", trigger: :command, dependency_ids: [base.id]})

      {bundle, []} = collect!(admin, [{:script, top.id}, {:prompt, prompt.id}])

      assert kinds(bundle) == [:prompt_block, :prompt_block, :prompt, :script, :script]
      assert Enum.map(bundle.items, & &1.name) == ["Intro", "History", "Story", "Base", "Top"]

      assert item(bundle, :prompt, "Story").data["blocks"] == [
               %{"uid" => first.id, "enabled" => true},
               %{"uid" => history.id, "enabled" => false}
             ]

      assert item(bundle, :prompt_block, "History").data["kind"] == "chat_history"
      assert item(bundle, :script, "Top").data["dependencies"] == [base.id]
      assert item(bundle, :script, "Base").root == false
    end

    test "hidden lore bound to a character is left out with a warning", %{scope: scope, admin: admin} do
      hero = character!(admin, "Site hero", %{}, site: true)
      vault = book!(admin, "Vault", %{site_visibility: :runtime_only}, site: true)
      {:ok, :ok} = Lore.set_book_characters(admin, vault, [hero.id])

      {bundle, warnings} = collect!(scope, [{:character, hero.id}])
      assert kinds(bundle) == [:character]
      assert warnings == ["'Vault' is hidden lore and was left out."]

      assert {:ok, %{counts: %{character: 1}, warnings: ^warnings}} =
               Export.plan(scope, %Request{items: [{:character, hero.id}]})

      {admin_bundle, []} = collect!(admin, [{:character, hero.id}])
      assert :lore_book in kinds(admin_bundle)
    end

    test "a runtime-only site character is left out with a warning; the chat links it by ref",
         %{scope: scope, admin: admin} do
      sphinx =
        character!(admin, "Sphinx", %{description: "riddle answer", site_visibility: :runtime_only}, site: true)

      chat = chat!(scope, [character!(scope, "Me"), sphinx])

      {bundle, warnings} = collect!(scope, [{:chat, chat.id}])
      assert item(bundle, :character, "Sphinx") == nil
      assert item(bundle, :character, "Me")
      assert warnings == ["'Sphinx' is runtime-only and was left out."]
      refute inspect(bundle) =~ "riddle answer"

      participants = item(bundle, :chat, "Tavern talk").data["participants"]

      assert [%{"kind" => "character", "uid" => _, "name" => "Sphinx"}] =
               for(%{"character" => %{} = ref} <- participants, do: ref)

      {admin_bundle, []} = collect!(admin, [{:character, sphinx.id}])
      assert item(admin_bundle, :character, "Sphinx").data["description"] == "riddle answer"
    end

    test "uses the recorded origin as the uid", %{scope: scope} do
      hero = character!(scope, "Hero")
      origin = Ecto.UUID.generate()
      :ok = Origins.record!(:character, hero.id, origin)

      {bundle, []} = collect!(scope, [{:character, hero.id}])
      assert item(bundle, :character, "Hero").uid == origin
    end
  end

  describe "plan/2" do
    test "counts the closure, messages and files", %{scope: scope} do
      me = character!(scope, "Me")
      avatar!(scope, me, png())
      chat = chat!(scope, [me, character!(scope, "Bot")])
      at = DateTime.utc_now()

      :ok =
        Messages.import_transcript(chat, [
          %{
            author_character_id: me.id,
            author_name: "Me",
            visible_to_ai: true,
            inserted_at: at,
            bodies: [%{content: "Hi"}],
            active: 0
          },
          %{
            author_character_id: me.id,
            author_name: "Me",
            visible_to_ai: true,
            inserted_at: at,
            bodies: [%{content: "Yo"}],
            active: 0
          }
        ])

      {:ok, _} = Messages.upsert_draft(scope, chat, "Unsent")

      assert Export.plan(scope, %Request{items: [{:chat, chat.id}]}) ==
               {:ok, %{counts: %{chat: 1, character: 2, message: 2, blob: 1}, warnings: []}}
    end
  end

  describe "build/2" do
    test "native output decodes to the collected bundle", %{scope: scope} do
      hero = character!(scope, "Hero: the/first")
      avatar!(scope, hero, png())
      book = book!(scope, "Lore")
      {:ok, :ok} = Lore.set_book_characters(scope, book, [hero.id])
      entry!(scope, "Fact", [book.id])
      chat = chat!(scope, [hero, character!(scope, "Bot")])

      :ok =
        Messages.import_transcript(chat, [
          %{
            author_character_id: hero.id,
            author_name: "Hero",
            visible_to_ai: true,
            inserted_at: DateTime.utc_now(),
            bodies: [%{content: "Hi"}],
            active: 0
          }
        ])

      request = %Request{items: [{:chat, chat.id}, {:character, hero.id}]}
      assert {:ok, %{bytes: bytes, filename: filename, content_type: type, warnings: []}} = Export.build(scope, request)
      assert filename == "mythweaver-export-#{Date.utc_today()}.mythweaver"
      assert type == "application/vnd.mythweaver.bundle"

      {expected, []} = collect!(scope, request.items)
      assert {:ok, decoded} = Bundle.decode(bytes)
      assert decoded.items == expected.items
      assert decoded.messages == expected.messages
      assert decoded.blobs == expected.blobs
      assert decoded.meta["title"] == "Mythweaver export"

      assert {:ok, %{filename: "Hero_ the_first.mythweaver"}} =
               Export.build(scope, %Request{items: [{:character, hero.id}]})
    end

    test "refuses rows the scope can't export", %{scope: scope, admin: admin} do
      theirs = character!(scope!(%{role: :user}), "Theirs")
      hidden = book!(admin, "Vault", %{site_visibility: :hidden}, site: true)

      for items <- [[{:character, Ecto.UUID.generate()}], [{:character, theirs.id}], [{:lore_book, hidden.id}]] do
        assert Export.build(scope, %Request{items: items}) == {:error, @unavailable}
        assert Export.plan(scope, %Request{items: items}) == {:error, @unavailable}
      end
    end

    test "refuses a format the selection doesn't offer", %{scope: scope} do
      hero = character!(scope, "Hero")
      book = book!(scope, "Lore")

      assert Export.build(scope, %Request{items: [{:character, hero.id}], format: :world_info}) ==
               {:error, "Unknown export format."}

      assert Export.build(scope, %Request{items: [{:character, hero.id}, {:lore_book, book.id}], format: :card_json}) ==
               {:error, "Unknown export format."}
    end
  end

  describe "formats/2" do
    test "a PNG card needs a PNG avatar, none, or a proxy that writes PNG", %{scope: scope} do
      put_attachments_config(proxy: :none)
      plain = character!(scope, "Plain")
      png_hero = character!(scope, "Png")
      avatar!(scope, png_hero, png())
      jpeg_hero = character!(scope, "Jpeg")
      avatar!(scope, jpeg_hero, jpeg())

      card_png = fn character ->
        Enum.find(Export.formats(scope, [{:character, character.id}]), &(&1.format == :card_png))
      end

      assert %{available?: true, reason: nil, label: "Character card (PNG)"} = card_png.(plain)
      assert %{available?: true} = card_png.(png_hero)

      assert %{available?: false, reason: @not_png} = card_png.(jpeg_hero)

      assert Enum.map(Export.formats(scope, [{:character, plain.id}]), & &1.format) ==
               [:native, :card_png, :card_json, :charx]

      assert Enum.map(Export.formats(scope, [{:character, plain.id}, {:character, jpeg_hero.id}]), & &1.format) ==
               [:native]

      assert Export.build(scope, %Request{items: [{:character, jpeg_hero.id}], format: :card_png}) ==
               {:error, @not_png}
    end

    test "a PNG card re-encodes another avatar through the image proxy", %{scope: scope} do
      put_attachments_config(proxy: :xtandard, xtandard: xi_config())
      hero = character!(scope, "Jpeg")
      avatar!(scope, hero, jpeg())
      request = %Request{items: [{:character, hero.id}], format: :card_png}

      assert %{available?: true} = Enum.find(Export.formats(scope, request.items), &(&1.format == :card_png))

      Req.Test.stub(Proxy, fn conn ->
        conn |> Plug.Conn.put_resp_content_type("image/png", nil) |> Plug.Conn.send_resp(200, png())
      end)

      assert {:ok, %{bytes: bytes, warnings: []}} = Export.build(scope, request)
      assert Png.strip_text(bytes) == {:ok, png()}
    end

    @tag :capture_log
    test "a PNG card falls back to the placeholder when the proxy fails", %{scope: scope} do
      put_attachments_config(proxy: :xtandard, xtandard: xi_config())
      hero = character!(scope, "Jpeg")
      avatar!(scope, hero, jpeg())
      Req.Test.stub(Proxy, &Plug.Conn.send_resp(&1, 502, "down"))

      assert {:ok, %{bytes: bytes, warnings: warnings}} =
               Export.build(scope, %Request{items: [{:character, hero.id}], format: :card_png})

      assert <<_sig::binary-8, _len::32, "IHDR", 400::32, 600::32, _rest::binary>> = bytes
      assert Enum.any?(warnings, &(&1 =~ "couldn't be made a PNG"))
    end

    test "other single items offer their SillyTavern format", %{scope: scope} do
      book = book!(scope, "Lore")
      assert Enum.map(Export.formats(scope, [{:lore_book, book.id}]), & &1.format) == [:native, :world_info]
    end
  end

  test "filename/2 replaces unsafe characters" do
    assert Export.filename(~s(a/b\\c:d*e?f"g<h>i|j), "json") == "a_b_c_d_e_f_g_h_i_j.json"
    assert Export.filename("  \x01 ", "png") == "_.png"
    assert Export.filename("   ", "png") == "export.png"
    assert Export.filename(nil, "png") == "export.png"
  end
end
