defmodule Mythweaver.Prompts.PreviewTest do
  use Mythweaver.DataCase

  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Injections
  alias Mythweaver.Lore
  alias Mythweaver.Prompts
  alias Mythweaver.Prompts.Block
  alias Mythweaver.Prompts.Builder
  alias Mythweaver.Prompts.Preview
  alias Mythweaver.Variables

  setup do
    %{scope: scope!()}
  end

  setup %{scope: scope} do
    {:ok, player} = Characters.create_character(scope, %{name: "Alice"})
    {:ok, bot} = Characters.create_character(scope, %{name: "Bob"})

    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: "Den",
        participants: [%{character_id: player.id}, %{character_id: bot.id}],
        player_character_id: player.id
      })

    %{chat: Chats.get_chat!(chat.id), player: player, bot: bot}
  end

  test "an unsaved block renders for the chosen responder, read-only", %{scope: scope} = ctx do
    block = %Block{
      name: "Draft",
      kind: :template,
      role: :system,
      enabled: false,
      content: "{% setvar seen = true %}{{ anchors.character.name }} in {{ anchors.chat.name }}"
    }

    preview = Preview.run(scope, Preview.block_prompt(scope, block), ctx.chat, ctx.player)

    assert [%{"content" => "Alice in Den", "source" => "template", "template_errors" => []}] = preview.sections
    assert preview.request["prompt"] == "Alice in Den\n\nAlice:"

    assert Preview.run(scope, Preview.block_prompt(scope, block), ctx.chat, nil).sections |> hd() |> Map.get("content") ==
             "Bob in Den"

    assert Variables.values(ctx.chat.id).chat == %{}
  end

  describe "a names-only site book" do
    setup %{scope: admin, chat: admin_chat} do
      user = scope!(%{role: :user})
      {:ok, player} = Characters.create_character(user, %{name: "Ann"})
      {:ok, bot} = Characters.create_character(user, %{name: "Ben"})

      {:ok, user_chat} =
        Chats.create_chat(user, %{
          name: "Hut",
          participants: [%{character_id: player.id}, %{character_id: bot.id}],
          player_character_id: player.id
        })

      {:ok, book} = Lore.create_book(admin, %{name: "Vault", site_visibility: :runtime_only}, site: true)
      {:ok, _} = Lore.bind_book_to_chat(book, user_chat.id)
      {:ok, _} = Lore.bind_book_to_chat(book, admin_chat.id)

      {:ok, _} =
        Lore.create_entry(
          admin,
          %{name: "Secret", content: "SECRET LORE", activation: :constant, outlet: :character, placement: :before},
          [book.id]
        )

      %{user: user, user_chat: Chats.get_chat!(user_chat.id)}
    end

    defp slot_block(content), do: %Block{name: "Slot", kind: :template, role: :system, enabled: true, content: content}

    test "templates cannot transform its text, and only an admin sees it", %{scope: admin, user: user} = ctx do
      block = slot_block("{{ anchors.lore.before_character | upcase }} / {{ anchors.lore.before_character }}")
      prompt = Preview.block_prompt(user, block)

      # The model gets the text untouched: the filter saw only a placeholder.
      assert Builder.build(prompt, Builder.context(user, ctx.user_chat)).segments |> hd() |> Map.get(:content) ==
               "SECRET LORE / SECRET LORE"

      assert [%{"content" => "[Hidden lore: Vault] / [Hidden lore: Vault]"}] =
               Preview.run(user, prompt, ctx.user_chat, nil).sections

      assert [%{"entry_name" => "Secret"} = entry] = Preview.run(user, prompt, ctx.user_chat, nil).lore["activated"]
      refute Map.has_key?(entry, "content")

      assert [%{"content" => "SECRET LORE / SECRET LORE"}] = Preview.run(admin, prompt, ctx.chat, nil).sections
    end

    test "a variable copy cut by a filter carries none of its text", %{user: user} = ctx do
      block = slot_block("{% setvar k = anchors.lore.before_character %}{{ k | slice: 0, 3 }}")
      built = Builder.build(Preview.block_prompt(user, block), Builder.context(user, ctx.user_chat))

      refute Enum.any?(built.segments, &(&1.content =~ "SECRET"))
    end
  end

  test "reports each of the chat's injections in order", %{scope: scope} = ctx do
    {:ok, _} = Injections.create_injection(scope, ctx.chat.id, %{key: "on", content: "On", order: 1})
    {:ok, _} = Injections.create_injection(scope, ctx.chat.id, %{key: "off", content: "Off", order: 2, enabled: false})
    {:ok, block} = Prompts.create_block(scope, %{name: "Slot", content: "{{ anchors.lore.after_author_note }}"})
    preview = Preview.run(scope, Preview.block_prompt(scope, block), ctx.chat, nil)

    assert [%{"content" => "On"}] = preview.sections
    assert Enum.map(preview.injections, &{&1["key"], &1["status"]}) == [{"on", "applied"}, {"off", "disabled"}]
  end
end
