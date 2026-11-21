defmodule Mythweaver.Prompts.BuilderTest do
  use Mythweaver.DataCase

  alias Mythweaver.AI
  alias Mythweaver.AI.Request
  alias Mythweaver.Attachments
  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Injections
  alias Mythweaver.Lore
  alias Mythweaver.Messages
  alias Mythweaver.Messages.PromptSnapshot
  alias Mythweaver.Prompts
  alias Mythweaver.Prompts.Anchor
  alias Mythweaver.Prompts.AttachmentRef
  alias Mythweaver.Prompts.Builder
  alias Mythweaver.Prompts.ContextLimit
  alias Mythweaver.Prompts.Standard
  alias Mythweaver.Sharing
  alias Mythweaver.Templates.State
  alias Mythweaver.Variables

  setup do
    %{scope: scope!()}
  end

  setup %{scope: scope} do
    hero = character(scope, "Hero")
    foil = character(scope, "Foil")
    chat = chat(scope, [hero, foil])

    %{chat: chat, hero: hero, foil: foil}
  end

  describe "one builder, two wire shapes" do
    test "the same prompt renders as chat messages or as a flat completion", %{scope: scope} = ctx do
      say(scope, ctx.chat, ctx.hero, "A dragon circles the keep")

      prompt =
        prompt(scope, "Unified", [
          block(scope, "System", %{content: "You are a narrator."}),
          block(scope, "Who", %{content: "{{ anchors.character.name }}"}),
          block(scope, "History", %{kind: :chat_history})
        ])

      context = Builder.context(scope, ctx.chat, character: ctx.foil)

      assert %{messages: [%{role: :system, content: sys}, %{role: :user, content: user}]} =
               Builder.render(prompt, model(scope, :chat), context)

      assert user == "#{ctx.hero.name}: A dragon circles the keep"

      assert %{prompt: text} = Builder.render(prompt, model(scope, :text), context)

      for fragment <- ["You are a narrator.", ctx.foil.name, "A dragon circles the keep"] do
        assert sys <> user =~ fragment
        assert text =~ fragment
      end

      # Roles are meaningful in a chat request and meaningless in a flat one, so the text form must not
      # invent labels the user never typed.
      refute text =~ "system"
      refute text =~ "System:"
    end

    test "adjacent same-role segments collapse into one message", %{scope: scope} = ctx do
      prompt =
        prompt(scope, "Runs", [
          block(scope, "One", %{content: "one", role: :system}),
          block(scope, "Two", %{content: "two", role: :system}),
          block(scope, "Three", %{content: "three", role: :system})
        ])

      assert %{messages: [%{role: :system, content: "one\ntwo\nthree"}]} =
               Builder.render(prompt, model(scope, :chat), Builder.context(scope, ctx.chat))
    end

    test "a role change starts a new message", %{scope: scope} = ctx do
      prompt =
        prompt(scope, "Mixed", [
          block(scope, "Sys", %{content: "sys", role: :system}),
          block(scope, "Say", %{content: "say", role: :user}),
          block(scope, "More", %{content: "more", role: :system})
        ])

      assert %{messages: messages} =
               Builder.render(prompt, model(scope, :chat), Builder.context(scope, ctx.chat))

      assert Enum.map(messages, & &1.role) == [:system, :user, :system]
    end
  end

  # The responder (`foil`) with `attrs` set, and the template segments `blocks` build to.
  defp card_build(scope, ctx, attrs, blocks) do
    {:ok, foil} = Characters.update_character(scope, ctx.foil, attrs)
    context = Builder.context(scope, Chats.get_chat!(ctx.chat.id), character: foil)
    %{segments: segments} = Builder.build(prompt(scope, "Card", blocks), context)
    Enum.map(segments, & &1.content)
  end

  describe "card prompts" do
    test "a system prompt replaces the block tagged main, reading its text as original", %{scope: scope} = ctx do
      main = block(scope, "Main", %{content: "Main text", role_tag: :main})
      assert card_build(scope, ctx, %{system_prompt: "{{ original }} + card"}, [main]) == ["Main text + card"]
    end

    test "a block that forbids overrides keeps its text and drops the card's", %{scope: scope} = ctx do
      main = block(scope, "Main", %{content: "Main text", role_tag: :main, forbid_overrides: true})
      lore = block(scope, "Lore", %{content: "[{{ anchors.lore.before_character }}]"})

      assert card_build(scope, ctx, %{system_prompt: "card"}, [main, lore]) == ["Main text", "[]"]
    end

    test "with no tagged block, the system prompt goes ahead of the before-character lore", %{scope: scope} = ctx do
      lore = block(scope, "Lore", %{content: "[{{ anchors.lore.before_character }}]"})
      assert card_build(scope, ctx, %{system_prompt: "Be brief."}, [lore]) == ["[Be brief.]"]
    end

    test "post-history instructions replace their block and keep its outlet lore", %{scope: scope} = ctx do
      book = book(scope)
      {:ok, _} = Lore.bind_book_to_chat(book, ctx.chat.id)

      lore_entry(scope, "X", book, %{
        activation: :constant,
        keywords: [],
        content: "X",
        outlet: :custom,
        custom_outlet: "post_history"
      })

      phi = block(scope, "PHI", %{content: "Jail\n" <> Standard.post_history(), role_tag: :post_history})

      assert card_build(scope, ctx, %{post_history_instructions: "PHI {{ original }}"}, [phi]) == ["PHI Jail\nX"]
    end

    test "add mode leaves the tagged block alone and adds to the lore slot", %{scope: scope} = ctx do
      main = block(scope, "Main", %{content: "Main text", role_tag: :main})
      lore = block(scope, "Lore", %{content: "[{{ anchors.lore.before_character }}]"})

      assert card_build(scope, ctx, %{system_prompt: "card", card_prompt_mode: :add}, [main, lore]) ==
               ["Main text", "[card]"]
    end

    test "a protected responder's replaced post-history block keeps forced outlet lore outside its token",
         %{scope: scope} = ctx do
      {:ok, sphinx} =
        Characters.create_character(
          scope,
          %{
            name: "Sphinx-#{unique()}",
            site_visibility: :runtime_only,
            post_history_instructions: "PHI {{ original }}"
          },
          site: true
        )

      {:ok, book} = Lore.create_book(scope, %{name: "Rules-#{unique()}", forced: true}, site: true)

      lore_entry(scope, "Rules", book, %{
        activation: :constant,
        content: "RULES",
        outlet: :custom,
        custom_outlet: "post_history"
      })

      phi = block(scope, "PHI", %{content: "Jail\n" <> Standard.post_history(), role_tag: :post_history})
      chat = chat(scope, [ctx.hero, sphinx])
      built = Builder.build(prompt(scope, "Card", [phi]), Builder.context(scope, chat, character: sphinx))

      assert [%{source: :template, content: "PHI Jail\nRULES"}] = built.segments

      assert %{label: "[Hidden: #{sphinx.name}'s post-history instructions]", text: "PHI Jail", source: :site} in built.protected_values
    end

    test "an added system prompt's template errors reach the build's errors", %{scope: scope} = ctx do
      foil = ctx.foil |> Ecto.Changeset.change(system_prompt: "{% if %}") |> Repo.update!()
      lore = block(scope, "Lore", %{content: "[{{ anchors.lore.before_character }}]"})
      context = Builder.context(scope, Chats.get_chat!(ctx.chat.id), character: foil)

      assert %{errors: [error]} = Builder.build(prompt(scope, "Card", [lore]), context)
      assert String.starts_with?(error, "#{foil.name}'s system prompt: Template syntax error: ")
    end

    test "a prompt that is not for role-play gets no card text", %{scope: scope} = ctx do
      {:ok, foil} = Characters.update_character(scope, ctx.foil, %{system_prompt: "Card text"})
      lore = block(scope, "Lore", %{content: "[{{ anchors.lore.before_character }}]"})
      prompt = %{prompt(scope, "Caption", [lore]) | purpose: :caption}
      context = Builder.context(scope, Chats.get_chat!(ctx.chat.id), character: foil)

      assert [%{content: "[]"}] = Builder.build(prompt, context).segments
    end

    test "a tagged block switched to chat history loses its tag", %{scope: scope} do
      main = block(scope, "Main", %{content: "Main text", role_tag: :main, forbid_overrides: true})

      assert {:ok, %{kind: :chat_history, role_tag: nil, forbid_overrides: false}} =
               Prompts.update_block(scope, main, %{kind: :chat_history})
    end
  end

  describe "chat history turns" do
    setup %{scope: scope} = ctx do
      third = character(scope, "Third")
      chat = chat(scope, [ctx.hero, ctx.foil, third])

      prompt =
        prompt(scope, "Turns", [
          block(scope, "S", %{content: "S"}),
          block(scope, "History", %{kind: :chat_history})
        ])

      %{chat: chat, third: third, prompt: prompt}
    end

    test "the responder is assistant; everyone else is a name-prefixed user", %{scope: scope} = ctx do
      say(scope, ctx.chat, ctx.hero, "one")
      say(scope, ctx.chat, ctx.foil, "two")
      say(scope, ctx.chat, ctx.third, "three")
      say(scope, ctx.chat, ctx.hero, "four")

      context = Builder.context(scope, ctx.chat, character: ctx.foil)

      assert Builder.render(ctx.prompt, model(scope, :chat), context) == %{
               messages: [
                 %Request.Message{role: :system, content: "S"},
                 %Request.Message{role: :user, content: "#{ctx.hero.name}: one"},
                 %Request.Message{role: :assistant, content: "two"},
                 %Request.Message{role: :user, content: "#{ctx.third.name}: three\n#{ctx.hero.name}: four"}
               ]
             }

      # Text keeps every name prefix and ends on the responder's cue, or the model has no turn to take.
      assert Builder.render(ctx.prompt, model(scope, :text), context) == %{
               prompt:
                 "S\n\n#{ctx.hero.name}: one\n#{ctx.foil.name}: two\n#{ctx.third.name}: three\n" <>
                   "#{ctx.hero.name}: four\n\n#{ctx.foil.name}:"
             }
    end

    test "fixed speaker roles name every line and do not change with the responder", %{scope: scope} = ctx do
      say(scope, ctx.chat, ctx.hero, "one")
      say(scope, ctx.chat, ctx.foil, "two")
      say(scope, ctx.chat, ctx.third, "three")

      prompt =
        prompt(scope, "Fixed", [block(scope, "History", %{kind: :chat_history, speaker_roles: :fixed})])

      render = fn responder ->
        Builder.render(prompt, model(scope, :chat), Builder.context(scope, ctx.chat, character: responder))
      end

      # The player (hero) is user; every other character is assistant, all name-prefixed.
      assert render.(ctx.foil) == %{
               messages: [
                 %Request.Message{role: :user, content: "#{ctx.hero.name}: one"},
                 %Request.Message{
                   role: :assistant,
                   content: "#{ctx.foil.name}: two\n#{ctx.third.name}: three"
                 }
               ]
             }

      assert render.(ctx.third) == render.(ctx.foil)
    end

    test "a message hidden from the AI is not a turn", %{scope: scope} = ctx do
      say(scope, ctx.chat, ctx.hero, "one")
      hidden = say(scope, ctx.chat, ctx.foil, "secret")
      {:ok, _} = Messages.update_message(hidden, %{visible_to_ai: false})

      context = Builder.context(scope, ctx.chat, character: ctx.foil)

      assert %{messages: messages} = Builder.render(ctx.prompt, model(scope, :chat), context)

      assert messages == [
               %Request.Message{role: :system, content: "S"},
               %Request.Message{role: :user, content: "#{ctx.hero.name}: one"}
             ]
    end

    test "reasoning never reaches the history", %{scope: scope} = ctx do
      {:ok, message} = Messages.create_generating_message(ctx.chat, ctx.foil.id)
      [body] = message.bodies
      {:ok, _} = Messages.finalize_body(body, %{content: "two", reasoning: "SECRET-THOUGHTS"})

      context = Builder.context(scope, ctx.chat, character: ctx.foil)

      assert %{messages: messages} = Builder.render(ctx.prompt, model(scope, :chat), context)
      assert %Request.Message{role: :assistant, content: "two"} in messages
      refute Enum.any?(messages, &(&1.content =~ "SECRET-THOUGHTS"))

      assert %{prompt: text} = Builder.render(ctx.prompt, model(scope, :text), context)
      refute text =~ "SECRET-THOUGHTS"
    end
  end

  describe "continuation" do
    setup %{scope: scope} = ctx do
      prompt =
        prompt(scope, "Continue", [
          block(scope, "S", %{content: "S"}),
          block(scope, "History", %{kind: :chat_history})
        ])

      say(scope, ctx.chat, ctx.hero, "one")
      last = say(scope, ctx.chat, ctx.foil, "two")

      context =
        Builder.context(scope, ctx.chat, character: ctx.foil, continue: Messages.get_message!(scope, last.id))

      %{prompt: prompt, context: context}
    end

    test "chat ends on the continued turn and the nudge", %{scope: scope} = ctx do
      assert Builder.render(ctx.prompt, model(scope, :chat), ctx.context) == %{
               messages: [
                 %Request.Message{role: :system, content: "S"},
                 %Request.Message{role: :user, content: "#{ctx.hero.name}: one"},
                 %Request.Message{role: :assistant, content: "two"},
                 %Request.Message{
                   role: :system,
                   content: "[Continue your last message without repeating its original content.]"
                 }
               ]
             }
    end

    test "a prefill model ends on the continued assistant turn with no nudge", %{scope: scope} = ctx do
      {:ok, prefill} =
        AI.create_model(scope, %{
          name: "model-#{unique()}",
          api_model_id: "m",
          completion_mode: :chat,
          continue_prefill: true
        })

      assert %{messages: messages} = Builder.render(ctx.prompt, prefill, ctx.context)
      assert List.last(messages) == %Request.Message{role: :assistant, content: "two"}
      assert Enum.count(messages, &(&1.content =~ "two")) == 1
    end

    test "text ends on the continued line, once, with no trailing cue", %{scope: scope} = ctx do
      assert Builder.render(ctx.prompt, model(scope, :text), ctx.context) == %{
               prompt: "S\n\n#{ctx.hero.name}: one\n\n#{ctx.foil.name}: two"
             }
    end
  end

  describe "guide" do
    setup %{scope: scope} do
      %{
        flags:
          prompt(scope, "Guide", [
            block(scope, "Guide", %{content: "{{ anchors.guide.text }}|{{ anchors.guide.continue }}"})
          ])
      }
    end

    test "a guide reaches anchors.guide for a new message", %{scope: scope} = ctx do
      context = Builder.context(scope, ctx.chat, guide: "Tom sits down.")
      assert [%{content: "Tom sits down.|false"}] = Builder.segments(ctx.flags, context)
    end

    test "a guided continue says so", %{scope: scope} = ctx do
      last = say(scope, ctx.chat, ctx.foil, "two")

      context =
        Builder.context(scope, ctx.chat,
          character: ctx.foil,
          guide: "Tom sits down.",
          continue: Messages.get_message!(scope, last.id)
        )

      assert [%{content: "Tom sits down.|true"}] = Builder.segments(ctx.flags, context)
    end

    test "no guide and a blank guide both leave anchors.guide nil", %{scope: scope} = ctx do
      prompt = prompt(scope, "Gate", [block(scope, "Gate", %{content: "{% if anchors.guide %}x{% endif %}y"})])

      assert [%{content: "y"}] = Builder.segments(prompt, Builder.context(scope, ctx.chat))
      assert [%{content: "y"}] = Builder.segments(prompt, Builder.context(scope, ctx.chat, guide: "   "))
    end

    test "the guide is data, never rendered as a template", %{scope: scope} = ctx do
      context = Builder.context(scope, ctx.chat, guide: "{{ anchors.player.name }}")
      assert [%{content: "{{ anchors.player.name }}|false"}] = Builder.segments(ctx.flags, context)
    end
  end

  describe "segments/2" do
    test "skips disabled blocks, disabled memberships, and blank resolutions", %{scope: scope} = ctx do
      kept = block(scope, "Kept", %{content: "kept"})
      off = block(scope, "Off", %{content: "off", enabled: false})
      # The character has no pronouns, so this block renders blank.
      blank = block(scope, "Blank", %{content: "{{ anchors.character.pronouns }}"})
      muted = block(scope, "Muted", %{content: "muted"})

      prompt = prompt(scope, "Filtered", [kept, off, blank, muted])

      membership = Enum.find(Prompts.list_prompt_blocks(prompt), &(&1.block_id == muted.id))
      {:ok, _} = Prompts.update_block_membership(scope, membership, %{enabled: false})
      prompt = Prompts.get_prompt!(prompt.id)

      segments = Builder.segments(prompt, Builder.context(scope, ctx.chat, character: ctx.foil))

      assert Enum.map(segments, & &1.content) == ["kept"]
    end

    test "an outlet block renders what activated into that outlet, and nothing when none did", %{scope: scope} = ctx do
      _outlet = outlet(scope, "ending")
      book = book(scope)
      {:ok, _} = Lore.bind_book_to_chat(book, ctx.chat.id)

      lore_entry(scope, "Dragon lore", book, %{
        keywords: ["dragon"],
        content: "Dragons hoard gold.",
        outlet: :custom,
        custom_outlet: "ending"
      })

      prompt = prompt(scope, "Outlet", [block(scope, "Ending", %{content: "{{ outlets.ending }}"})])

      assert Builder.segments(prompt, Builder.context(scope, ctx.chat)) == []

      say(scope, ctx.chat, ctx.hero, "A dragon circles the keep")
      chat = Chats.get_chat!(ctx.chat.id)

      assert [%{content: "Dragons hoard gold.", source: :template}] =
               Builder.segments(prompt, Builder.context(scope, chat))
    end
  end

  describe "forced lore" do
    setup %{scope: scope} do
      {:ok, book} = Lore.create_book(scope, %{name: "Rules-#{unique()}", forced: true}, site: true)

      lore_entry(scope, "Rules", book, %{
        activation: :constant,
        content: "RULES",
        outlet: :character,
        placement: :before
      })

      :ok
    end

    test "a role-play prompt with no slot for it carries it in a system section at the top",
         %{scope: scope} = ctx do
      prompt = prompt(scope, "Bare", [block(scope, "Hi", %{content: "Say hi."})])

      assert [%{source: :forced_lore, role: :system, content: "RULES"}, %{source: :template, content: "Say hi."}] =
               Builder.segments(prompt, Builder.context(scope, ctx.chat))
    end

    test "a block that places it gets it, and no fallback section is added", %{scope: scope} = ctx do
      prompt = prompt(scope, "Slot", [block(scope, "Slot", %{content: "{{ anchors.lore.before_character }}"})])

      assert [%{source: :template, content: "RULES"}] = Builder.segments(prompt, Builder.context(scope, ctx.chat))
    end

    test "a prompt that is not for role-play gets no fallback section", %{scope: scope} = ctx do
      prompt = %{prompt(scope, "Caption", [block(scope, "Hi", %{content: "Say hi."})]) | purpose: :caption}

      assert [%{source: :template}] = Builder.segments(prompt, Builder.context(scope, ctx.chat))
    end
  end

  describe "context/2" do
    test "lore activated into a built-in slot reaches its anchor", %{scope: scope} = ctx do
      book = book(scope)
      {:ok, _} = Lore.bind_book_to_chat(book, ctx.chat.id)

      lore_entry(scope, "Keep lore", book, %{
        keywords: ["dragon"],
        content: "The keep is ancient.",
        outlet: :character,
        placement: :before
      })

      say(scope, ctx.chat, ctx.hero, "A dragon circles the keep")
      chat = Chats.get_chat!(ctx.chat.id)

      prompt = prompt(scope, "Lore", [block(scope, "Slot", %{content: "{{ anchors.lore.before_character }}"})])

      assert [%{content: "The keep is ancient."}] =
               Builder.segments(prompt, Builder.context(scope, chat))
    end

    test "the default responder is a participant who is not the player", %{scope: scope} = ctx do
      context = Builder.context(scope, ctx.chat)

      assert context.character.id == ctx.foil.id
      assert context.player_character.id == ctx.hero.id
    end

    test "a memory context exposes anchors.memory and activates no lore or injections", %{scope: scope} = ctx do
      book = book(scope)
      {:ok, _} = Lore.bind_book_to_chat(book, ctx.chat.id)

      lore_entry(scope, "Always", book, %{
        activation: :constant,
        content: "Lore text",
        outlet: :character,
        placement: :after
      })

      injection!(scope, ctx.chat, %{key: "inj", content: "Injected", position: :after_character})
      chat = Chats.get_chat!(ctx.chat.id)

      prompt =
        prompt(scope, "Memory", [
          block(scope, "Scene", %{content: "{{ anchors.memory.scene }}|{{ anchors.lore.after_character }}"})
        ])

      assert %{segments: [%{content: "[#1] Hero: Hi|"}], injections: []} =
               Builder.build(prompt, Builder.context(scope, chat, memory: %{"scene" => "[#1] Hero: Hi"}))

      # Without `:memory` the same chat activates both, and carries no `anchors.memory`.
      assert %{segments: [%{content: "|Lore text\nInjected"}]} = Builder.build(prompt, Builder.context(scope, chat))
    end

    test "anchors.memory_counts defaults to zeros and takes the counts given", %{scope: scope} = ctx do
      prompt = prompt(scope, "Counts", [block(scope, "Counts", %{content: "{{ anchors.memory_counts.tier0 }}"})])
      counts = Map.put(Anchor.empty_memory_counts(), "tier0", 3)

      assert [%{content: "0"}] = Builder.segments(prompt, Builder.context(scope, ctx.chat))
      assert [%{content: "3"}] = Builder.segments(prompt, Builder.context(scope, ctx.chat, memory_counts: counts))
    end
  end

  describe "templates" do
    test "a literal block reads the characters", %{scope: scope} = ctx do
      prompt =
        prompt(scope, "Names", [
          block(scope, "Names", %{content: "{{ anchors.character.name }} vs {{ anchors.player.name }}"})
        ])

      assert [%{content: content, errors: []}] = Builder.segments(prompt, Builder.context(scope, ctx.chat))
      assert content == "#{ctx.foil.name} vs #{ctx.hero.name}"
    end

    test "char and user alias the responder and the player", %{scope: scope} = ctx do
      prompt = prompt(scope, "Aliases", [block(scope, "Aliases", %{content: "{{char}}/{{user}}"})])

      assert [%{content: content, errors: []}] =
               Builder.segments(prompt, Builder.context(scope, ctx.chat, character: ctx.foil))

      assert content == "#{ctx.foil.name}/#{ctx.hero.name}"
    end

    test "a variable written in one block is read by a later one", %{scope: scope} = ctx do
      prompt =
        prompt(scope, "Vars", [
          block(scope, "Write", %{content: "{% setvar seen = true %}"}),
          block(scope, "Read", %{content: "{% if vars.seen %}yes{% endif %}"})
        ])

      assert %{segments: [%{content: "yes"}], state: state} = Builder.build(prompt, Builder.context(scope, ctx.chat))
      assert State.writes(state) == [%{"scope" => "chat", "key" => "seen", "value" => true}]
    end

    test "activated lore renders per entry", %{scope: scope} = ctx do
      book = book(scope)
      {:ok, _} = Lore.bind_book_to_chat(book, ctx.chat.id)

      entry =
        lore_entry(scope, "Knows", book, %{
          keywords: ["dragon"],
          content: "{{ anchors.character.name }} knows",
          outlet: :character,
          placement: :before
        })

      say(scope, ctx.chat, ctx.hero, "A dragon circles the keep")
      chat = Chats.get_chat!(ctx.chat.id)
      prompt = prompt(scope, "Lore", [block(scope, "Slot", %{content: "{{ anchors.lore.before_character }}"})])
      expected = "#{ctx.foil.name} knows"

      assert %{segments: [%{content: ^expected}], lore: lore_render} =
               Builder.build(prompt, Builder.context(scope, chat))

      assert lore_render == %{entry.id => %{text: expected, errors: [], placed: true}}
    end

    test "an outlet block renders its entries", %{scope: scope} = ctx do
      outlet = outlet(scope, "hoard")
      book = book(scope)
      {:ok, _} = Lore.bind_book_to_chat(book, ctx.chat.id)

      lore_entry(scope, "Hoard", book, %{
        keywords: ["dragon"],
        content: "{{ anchors.player.name }} hoards gold.",
        outlet: :custom,
        custom_outlet: outlet.key
      })

      say(scope, ctx.chat, ctx.hero, "A dragon circles the keep")
      chat = Chats.get_chat!(ctx.chat.id)
      prompt = prompt(scope, "Outlet", [block(scope, "Ending", %{content: "{{ outlets.hoard }}"})])
      expected = "#{ctx.hero.name} hoards gold."

      assert [%{content: ^expected, source: :template}] = Builder.segments(prompt, Builder.context(scope, chat))
    end

    test "chat history is never rendered", %{scope: scope} = ctx do
      say(scope, ctx.chat, ctx.hero, "{{ anchors.character.name }}")
      prompt = prompt(scope, "History", [block(scope, "History", %{kind: :chat_history})])

      assert [%{content: content, turns: [%{content: turn}]}] =
               Builder.segments(prompt, Builder.context(scope, ctx.chat, character: ctx.foil))

      assert content =~ "{{ anchors.character.name }}"
      assert turn =~ "{{ anchors.character.name }}"
    end

    test "descriptions render before blocks, and blocks see the rendered text", %{scope: scope} = ctx do
      {:ok, _} = Characters.update_character(scope, ctx.foil, %{description: "Serves {{ anchors.player.name }}."})

      {:ok, third} =
        Characters.create_character(scope, %{name: "Third-#{unique()}", description: "Knows {{ anchors.player.name }}."})

      chat = %{chat(scope, [ctx.hero, ctx.foil, third]) | group_cards: :join_all}

      prompt =
        prompt(scope, "Desc", [
          block(scope, "Desc", %{content: "{{ anchors.character.description }}"}),
          block(scope, "Others", %{content: "{{ anchors.other_characters }}"})
        ])

      foil = Characters.get_character!(ctx.foil.id)

      assert %{segments: [%{content: desc}, %{content: others}], errors: []} =
               Builder.build(prompt, Builder.context(scope, chat, character: foil))

      assert desc == "Serves #{ctx.hero.name}."
      assert others == "#{third.name}: Knows #{ctx.hero.name}."
    end

    test "a broken description falls back to its raw text and reports", %{scope: scope} = ctx do
      foil = ctx.foil |> Ecto.Changeset.change(description: "{% if %}") |> Repo.update!()
      prompt = prompt(scope, "Broken", [block(scope, "Desc", %{content: "{{ anchors.character.description }}"})])
      chat = Chats.get_chat!(ctx.chat.id)

      assert %{segments: [%{content: "{% if %}", errors: []}], errors: [error]} =
               Builder.build(prompt, Builder.context(scope, chat, character: foil))

      assert String.starts_with?(error, "#{foil.name}'s description: Template syntax error: ")
    end

    test "the standard cards show appearance only when it is set", %{scope: scope} = ctx do
      cards = fn ->
        prompt =
          prompt(scope, "Cards", [
            block(scope, "Character", %{content: Standard.character()}),
            block(scope, "Player", %{content: Standard.player()})
          ])

        chat = Chats.get_chat!(ctx.chat.id)
        foil = Characters.get_character!(ctx.foil.id)
        %{segments: segments, errors: []} = Builder.build(prompt, Builder.context(scope, chat, character: foil))
        Enum.map_join(segments, "\n", & &1.content)
      end

      refute cards.() =~ "appearance:"

      {:ok, _} = Characters.update_character(scope, ctx.foil, %{appearance: "Silver hair."})
      {:ok, _} = Characters.update_character(scope, ctx.hero, %{appearance: "A red cloak."})

      text = cards.()
      assert text =~ "Character appearance: Silver hair."
      assert text =~ "Player appearance: A red cloak."
    end

    test "a blank anchor is nil, so an if on it is false", %{scope: scope} = ctx do
      prompt =
        prompt(scope, "Pronouns", [block(scope, "P", %{content: "{% if anchors.character.pronouns %}P{% endif %}x"})])

      assert [%{content: "x"}] = Builder.segments(prompt, Builder.context(scope, ctx.chat))
    end

    test "lore renders before blocks, even when no block reads its slot", %{scope: scope} = ctx do
      book = book(scope)
      {:ok, _} = Lore.bind_book_to_chat(book, ctx.chat.id)

      lore_entry(scope, "Writes", book, %{
        activation: :constant,
        content: "{% setvar seen = true %}Lore",
        outlet: :character,
        placement: :before
      })

      chat = Chats.get_chat!(ctx.chat.id)
      prompt = prompt(scope, "Reads", [block(scope, "Read", %{content: "{% if vars.seen %}yes{% endif %}"})])

      segments = Builder.segments(prompt, Builder.context(scope, chat))
      assert Enum.map(segments, & &1.content) == ["yes"]
    end
  end

  describe "protected content" do
    setup %{scope: scope} = ctx do
      {:ok, sphinx} =
        Characters.create_character(
          scope,
          %{
            name: "Sphinx-#{unique()}",
            description: "The answer is {{ anchors.character.name }}",
            appearance: "A winged lion",
            site_visibility: :runtime_only
          },
          site: true
        )

      %{sphinx: sphinx, chat: chat(scope, [ctx.hero, sphinx])}
    end

    test "a runtime-only character's description and appearance reach templates only as tokens",
         %{scope: scope, sphinx: sphinx} = ctx do
      prompt =
        prompt(scope, "Card", [
          block(scope, "Card", %{
            content:
              "{% setvar d = anchors.character.description %}{% setvar a = anchors.character.appearance | upcase %}" <>
                "{{ anchors.character.description }} / {{ anchors.character.appearance | upcase }}"
          })
        ])

      description = "The answer is #{sphinx.name}"
      built = Builder.build(prompt, Builder.context(scope, ctx.chat, character: sphinx))

      assert [%{content: content}] = built.segments
      assert content == "#{description} / A winged lion"

      assert [_, _] = writes = State.writes(built.state)

      for %{"value" => value} <- writes do
        refute value =~ "answer"
        refute value =~ ~r/lion/i
      end

      assert %{label: "[Hidden: #{sphinx.name}'s description]", text: description, source: :site} in built.protected_values

      assert %{label: "[Hidden: #{sphinx.name}'s appearance]", text: "A winged lion", source: :site} in built.protected_values
    end

    test "lore and other descriptions that quote it get the text back", %{scope: scope, sphinx: sphinx} = ctx do
      {:ok, _hero} =
        Characters.update_character(scope, ctx.hero, %{description: "Facing {{ anchors.character.description }}"})

      book = book(scope)
      {:ok, _} = Lore.bind_book_to_chat(book, ctx.chat.id)

      entry =
        lore_entry(scope, "Quotes", book, %{
          activation: :constant,
          content: "Lore: {{ anchors.character.description }}",
          outlet: :character,
          placement: :before
        })

      prompt =
        prompt(scope, "Quotes", [
          block(scope, "Lore", %{content: "{{ anchors.lore.before_character }}"}),
          block(scope, "Player", %{content: "{{ anchors.player.description }}", role: :user})
        ])

      built = Builder.build(prompt, Builder.context(scope, Chats.get_chat!(ctx.chat.id), character: sphinx))

      # Lore renders after descriptions, so it quotes the rendered one; descriptions see each other raw.
      assert Enum.map(built.segments, & &1.content) == [
               "Lore: The answer is #{sphinx.name}",
               "Facing The answer is {{ anchors.character.name }}"
             ]

      assert built.lore[entry.id].text == "Lore: The answer is #{sphinx.name}"
    end

    test "a runtime-only block's section, or every section of a runtime-only prompt, is content-hidden",
         %{scope: scope} = ctx do
      site_block = fn name, visibility ->
        {:ok, block} =
          Prompts.create_block(
            scope,
            %{name: "#{name}-#{unique()}", content: "#{name} text", site_visibility: visibility},
            site: true
          )

        block
      end

      secret = site_block.("Secret", :runtime_only)
      open = site_block.("Open", :readable)

      sections = fn visibility ->
        {:ok, prompt} =
          Prompts.create_prompt(scope, %{name: "Story-#{unique()}", site_visibility: visibility}, site: true)

        for block <- [secret, open], do: {:ok, _} = Prompts.add_block(scope, prompt, block)
        prompt = Prompts.get_prompt!(prompt.id)
        context = Builder.context(scope, ctx.chat)
        built = Builder.build(prompt, context)
        attrs = PromptSnapshot.build_attrs(prompt, built, context.lore, nil)
        blocks = Enum.filter(built.protected_values, &String.starts_with?(&1.label, "[Hidden block"))
        {blocks, Enum.map(attrs.sections, &{&1["block_name"], &1["content_hidden"]})}
      end

      assert sections.(:readable) ==
               {[%{label: "[Hidden block: #{secret.name}]", text: "Secret text", source: :site}],
                [{secret.name, true}, {open.name, false}]}

      assert {[_, _], [{_, true}, {_, true}]} = sections.(:runtime_only)
    end

    test "a Runtime-only subscriber's chat tokenizes the shared character's description, as a share value" do
      owner = scope!(%{role: :user})
      subscriber = scope!(%{role: :user})

      {:ok, card} =
        Characters.create_character(owner, %{name: "Card-#{unique()}", description: "Owner's plan", appearance: "Tall"})

      share = subscribe!(owner, subscriber, card)
      chat = chat(subscriber, [character(subscriber, "Hero"), card])

      prompt =
        prompt(subscriber, "Card", [
          block(subscriber, "Card", %{
            content: "{% setvar d = anchors.character.description %}{{ anchors.character.description }}"
          })
        ])

      built = Builder.build(prompt, Builder.context(subscriber, chat, character: card))

      assert [%{content: "Owner's plan"}] = built.segments
      assert [%{"value" => value}] = State.writes(built.state)
      refute value =~ "plan"
      assert built.owner_id == subscriber.user.id

      assert %{label: "[Hidden: #{card.name}'s description]", text: "Owner's plan", source: :share} in built.protected_values
      assert %{label: "[Hidden: #{card.name}'s appearance]", text: "Tall", source: :share} in built.protected_values

      {:ok, _share} = Sharing.set_visibility(owner, share.id, :readable)
      assert Builder.build(prompt, Builder.context(subscriber, chat, character: card)).protected_values == []
    end

    test "a Runtime-only subscribed book's entries are share values, stamped share-hidden in the snapshot" do
      owner = scope!(%{role: :user})
      subscriber = scope!(%{role: :user})
      book = book(owner)

      entry =
        lore_entry(owner, "Vault", book, %{
          activation: :constant,
          content: "The vault code is 1234",
          outlet: :character,
          placement: :before
        })

      subscribe!(owner, subscriber, book)
      hero = character(subscriber, "Hero")
      chat = chat(subscriber, [hero, character(subscriber, "Foil")])
      {:ok, _} = Lore.bind_book_to_chat(book, chat.id)
      chat = Chats.get_chat!(chat.id)

      prompt =
        prompt(subscriber, "Lore", [
          block(subscriber, "Lore", %{content: "{{ anchors.lore.before_character }}"})
        ])

      context = Builder.context(subscriber, chat)
      built = Builder.build(prompt, context)

      assert [%{content: "The vault code is 1234"}] = built.segments

      assert %{label: "[Hidden lore: #{book.name}]", text: "The vault code is 1234", source: :share} in built.protected_values

      attrs = PromptSnapshot.build_attrs(prompt, built, context.lore, nil)
      assert [%{"entry_id" => entry_id, "share_hidden" => true}] = attrs.lore["activated"]
      assert entry_id == entry.id
      assert [%{"source" => "share"}] = attrs.protected
    end
  end

  describe "render_user_text/3" do
    test "plain text is returned untouched", %{scope: scope} = ctx do
      assert Builder.render_user_text(scope, ctx.chat, ctx.hero.id, "plain") == {:ok, "plain", []}
    end

    test "anchors render into the stored text", %{scope: scope} = ctx do
      names = "#{ctx.hero.name}, #{ctx.foil.name}"

      assert Builder.render_user_text(scope, ctx.chat, ctx.hero.id, "Hi {{ anchors.participants }}") ==
               {:ok, "Hi #{names}", []}

      assert Builder.render_user_text(scope, ctx.chat, ctx.hero.id, "{{ anchors.chat.participants | join: \" & \" }}") ==
               {:ok, "#{ctx.hero.name} & #{ctx.foil.name}", []}

      assert Builder.render_user_text(scope, ctx.chat, ctx.hero.id, "{{ anchors.chat.participants.size }}") ==
               {:ok, "2", []}
    end

    test "anchors.character is the message's author, not the default responder", %{scope: scope} = ctx do
      source = "{{ anchors.character.name }}"

      # The player is never the default responder, so this case tells the author apart from the responder.
      assert Builder.render_user_text(scope, ctx.chat, ctx.hero.id, source) == {:ok, ctx.hero.name, []}
      assert Builder.render_user_text(scope, ctx.chat, ctx.foil.id, source) == {:ok, ctx.foil.name, []}
      assert Builder.render_user_text(scope, ctx.chat, nil, source) == {:ok, "", []}
    end

    test "char names the AI character: the author when one speaks, else the responder", %{scope: scope} = ctx do
      assert Builder.render_user_text(scope, ctx.chat, ctx.hero.id, "{{char}} and {{user}}") ==
               {:ok, "#{ctx.foil.name} and #{ctx.hero.name}", []}

      assert Builder.render_user_text(scope, ctx.chat, ctx.foil.id, "{{ char }}") == {:ok, ctx.foil.name, []}

      assert Builder.render_user_text(scope, ctx.chat, ctx.hero.id, "{% assign char = \"X\" %}{{ char }}") ==
               {:ok, "X", []}
    end

    test "anchors.chat.characters names every non-player participant", %{scope: scope} = ctx do
      assert Builder.render_user_text(scope, ctx.chat, ctx.hero.id, "{{ anchors.chat.characters | join: \", \" }}") ==
               {:ok, ctx.foil.name, []}
    end

    test "variable writes are discarded with a notice", %{scope: scope} = ctx do
      assert {:ok, "ok", [_notice]} = Builder.render_user_text(scope, ctx.chat, ctx.hero.id, "{% setvar x = 1 %}ok")

      assert Variables.values(ctx.chat.id).chat == %{}
    end

    test "a syntax error is an error, not raw text", %{scope: scope} = ctx do
      assert {:error, "Template syntax error: " <> _} =
               Builder.render_user_text(scope, ctx.chat, ctx.hero.id, "{% if %}")
    end
  end

  describe "injections" do
    test "a slot injection renders after that slot's lore", %{scope: scope} = ctx do
      book = book(scope)
      {:ok, _} = Lore.bind_book_to_chat(book, ctx.chat.id)

      lore_entry(scope, "Lore", book, %{
        keywords: ["dragon"],
        content: "Lore text",
        outlet: :character,
        placement: :after
      })

      say(scope, ctx.chat, ctx.hero, "A dragon circles the keep")
      injection!(scope, ctx.chat, %{key: "inj", content: "Injected", position: :after_character})
      prompt = prompt(scope, "Slot", [block(scope, "Slot", %{content: "{{ anchors.lore.after_character }}"})])

      assert %{segments: [%{content: "Lore text\nInjected"}], injections: [%{status: :applied, text: "Injected"}]} =
               Builder.build(prompt, Builder.context(scope, Chats.get_chat!(ctx.chat.id)))
    end

    test "injections in one slot render in order", %{scope: scope} = ctx do
      injection!(scope, ctx.chat, %{key: "second", content: "B", position: :before_character, order: 20})
      injection!(scope, ctx.chat, %{key: "first", content: "A", position: :before_character, order: 10})
      prompt = prompt(scope, "Order", [block(scope, "Slot", %{content: "{{ anchors.lore.before_character }}"})])

      assert %{segments: [%{content: "A\nB"}]} = Builder.build(prompt, Builder.context(scope, ctx.chat))
    end

    test "disabled, spent and condition-false injections are skipped and reported", %{scope: scope} = ctx do
      injection!(scope, ctx.chat, %{key: "off", content: "Off", enabled: false, order: 1})
      spent = injection!(scope, ctx.chat, %{key: "spent", content: "Spent", uses: 1, order: 2})
      :ok = Injections.spend(ctx.chat.id, [spent.id])
      injection!(scope, ctx.chat, %{key: "never", content: "Never", condition: "false", order: 3})
      injection!(scope, ctx.chat, %{key: "on", content: "On", order: 4})
      prompt = prompt(scope, "Skip", [block(scope, "Slot", %{content: "{{ anchors.lore.after_author_note }}"})])

      assert %{segments: [%{content: "On"}], injections: reports} =
               Builder.build(prompt, Builder.context(scope, ctx.chat))

      assert Enum.map(reports, &{&1.key, &1.status, &1.text}) == [
               {"off", :disabled, nil},
               {"spent", :spent, nil},
               {"never", :condition_false, nil},
               {"on", :applied, "On"}
             ]
    end

    test "a condition reads chat variables", %{scope: scope} = ctx do
      injection!(scope, ctx.chat, %{key: "tense", content: "Tense", condition: ~s(vars.mood == "tense")})
      prompt = prompt(scope, "Cond", [block(scope, "Slot", %{content: "x {{ anchors.lore.after_author_note }}"})])

      assert %{segments: [%{content: "x"}], injections: [%{status: :condition_false, errors: []}]} =
               Builder.build(prompt, Builder.context(scope, ctx.chat))

      {:ok, _} = Variables.create_variable(scope, ctx.chat.id, %{key: "mood", value: "tense"})

      assert %{segments: [%{content: "x Tense"}], injections: [%{status: :applied}]} =
               Builder.build(prompt, Builder.context(scope, ctx.chat))
    end

    test "an at_depth injection lands inside chat history", %{scope: scope} = ctx do
      say(scope, ctx.chat, ctx.hero, "one")
      say(scope, ctx.chat, ctx.foil, "two")
      injection!(scope, ctx.chat, %{key: "aside", content: "Aside", position: :at_depth, depth: 1, role: :user})
      prompt = prompt(scope, "Depth", [block(scope, "History", %{kind: :chat_history})])
      context = Builder.context(scope, ctx.chat, character: ctx.foil)

      assert %{messages: [%{role: :user, content: user}, %{role: :assistant, content: "two"}]} =
               Builder.render(prompt, model(scope, :chat), context)

      assert user == "#{ctx.hero.name}: one\nAside"

      assert %{segments: [%{content: content}], injections: [%{status: :applied, depth: 1, role: :user}]} =
               Builder.build(prompt, context)

      assert content == "#{ctx.hero.name}: one\nAside\n#{ctx.foil.name}: two"
    end

    test "depth 0 lands after the last line and a depth past the start lands first", %{scope: scope} = ctx do
      say(scope, ctx.chat, ctx.hero, "one")
      say(scope, ctx.chat, ctx.foil, "two")
      injection!(scope, ctx.chat, %{key: "last", content: "Last", position: :at_depth, depth: 0})
      injection!(scope, ctx.chat, %{key: "first", content: "First", position: :at_depth, depth: 99})
      prompt = prompt(scope, "Ends", [block(scope, "History", %{kind: :chat_history})])

      assert %{segments: [%{content: content}]} = Builder.build(prompt, Builder.context(scope, ctx.chat))
      assert content == "First\n#{ctx.hero.name}: one\n#{ctx.foil.name}: two\nLast"
    end

    test "an at_depth lore entry lands in history as system, not in anchors", %{scope: scope} = ctx do
      book = book(scope)
      {:ok, _} = Lore.bind_book_to_chat(book, ctx.chat.id)
      lore_entry(scope, "Deep", book, %{keywords: ["dragon"], content: "Deep lore", outlet: :at_depth, depth: 1})
      say(scope, ctx.chat, ctx.hero, "A dragon")
      say(scope, ctx.chat, ctx.foil, "two")

      prompt =
        prompt(scope, "Deep", [
          block(scope, "Anchor", %{content: "[{{ anchors.lore.at_depth }}]"}),
          block(scope, "History", %{kind: :chat_history})
        ])

      context = Builder.context(scope, Chats.get_chat!(ctx.chat.id), character: ctx.foil)

      assert %{segments: [%{content: "[]"}, %{content: history}]} = Builder.build(prompt, context)
      assert history == "#{ctx.hero.name}: A dragon\nDeep lore\n#{ctx.foil.name}: two"

      assert %{messages: messages} = Builder.render(prompt, model(scope, :chat), context)

      assert Enum.map(messages, &{&1.role, &1.content}) == [
               {:system, "[]"},
               {:user, "#{ctx.hero.name}: A dragon"},
               {:system, "Deep lore"},
               {:assistant, "two"}
             ]
    end

    test "an at_depth lore entry is sent with its own role", %{scope: scope} = ctx do
      book = book(scope)
      {:ok, _} = Lore.bind_book_to_chat(book, ctx.chat.id)

      lore_entry(scope, "Deep", book, %{
        keywords: ["dragon"],
        content: "Deep lore",
        outlet: :at_depth,
        depth: 1,
        role: :user
      })

      say(scope, ctx.chat, ctx.hero, "A dragon")
      say(scope, ctx.chat, ctx.foil, "two")

      prompt = prompt(scope, "Deep", [block(scope, "History", %{kind: :chat_history})])
      context = Builder.context(scope, Chats.get_chat!(ctx.chat.id), character: ctx.foil)
      %{messages: messages} = Builder.render(prompt, model(scope, :chat), context)

      assert [%{role: :user, content: content}] = Enum.filter(messages, &(&1.content =~ "Deep lore"))
      assert content == "#{ctx.hero.name}: A dragon\nDeep lore"
    end

    test "without a chat-history block, depth content is not placed", %{scope: scope} = ctx do
      book = book(scope)
      {:ok, _} = Lore.bind_book_to_chat(book, ctx.chat.id)
      entry = lore_entry(scope, "Deep", book, %{keywords: ["dragon"], content: "Deep lore", outlet: :at_depth})
      say(scope, ctx.chat, ctx.hero, "A dragon")
      injection!(scope, ctx.chat, %{key: "aside", content: "Aside", position: :at_depth})
      prompt = prompt(scope, "NoHistory", [block(scope, "Sys", %{content: "sys"})])

      assert %{segments: [%{content: "sys"}], injections: [%{status: :not_placed}], lore: lore} =
               Builder.build(prompt, Builder.context(scope, Chats.get_chat!(ctx.chat.id)))

      assert %{placed: false} = lore[entry.id]
    end
  end

  describe "Anchor.data/2" do
    test "other characters follows Group cards, never listing the responder or the player", %{scope: scope} do
      player = character(scope, "Player")
      {:ok, alice} = Characters.create_character(scope, %{name: "Alice", description: "A"})
      {:ok, bob} = Characters.create_character(scope, %{name: "Bob"})
      chat = chat(scope, [player, alice, bob])

      others = fn chat, character ->
        Anchor.data(Builder.context(scope, chat, character: character))["other_characters"]
      end

      # Swap (the default): only the responder's card.
      assert chat.group_cards == :swap
      assert others.(chat, alice) == nil

      join_all = %{chat | group_cards: :join_all}
      assert others.(join_all, alice) == "Bob"
      assert others.(join_all, bob) == "Alice: A"

      muted_bob =
        Enum.map(chat.participants, fn p -> if p.character_id == bob.id, do: %{p | muted: true}, else: p end)

      assert others.(%{chat | group_cards: :join, participants: muted_bob}, alice) == nil
      assert others.(%{chat | group_cards: :join_all, participants: muted_bob}, alice) == "Bob"
      # A muted responder still sees the unmuted.
      assert others.(%{chat | group_cards: :join, participants: muted_bob}, bob) == "Alice: A"
    end

    test "cards list every joined character, the responder included and the player not, in participant order",
         %{scope: scope} do
      player = character(scope, "Player")
      {:ok, alice} = Characters.create_character(scope, %{name: "Alice", description: "A"})
      {:ok, bob} = Characters.create_character(scope, %{name: "Bob"})
      chat = chat(scope, [player, alice, bob])

      names = fn chat, character ->
        Enum.map(Anchor.data(Builder.context(scope, chat, character: character))["cards"], & &1["name"])
      end

      # Swap: the responder alone, so the list changes with the speaker.
      assert names.(chat, alice) == ["Alice"]
      assert names.(chat, bob) == ["Bob"]

      # Join: the same list whoever replies, which is what lets a prompt cache it.
      join = %{chat | group_cards: :join}
      assert names.(join, alice) == ["Alice", "Bob"]
      assert names.(join, bob) == ["Alice", "Bob"]

      muted_bob =
        Enum.map(chat.participants, fn p -> if p.character_id == bob.id, do: %{p | muted: true}, else: p end)

      assert names.(%{join | participants: muted_bob}, alice) == ["Alice"]
      # A muted responder still sees its own card.
      assert names.(%{join | participants: muted_bob}, bob) == ["Alice", "Bob"]

      text = fn chat, character ->
        state = Builder.context(scope, chat, character: character).templates
        {text, _state, []} = Mythweaver.Templates.render(Standard.cards(), state)
        String.trim(text)
      end

      assert text.(join, bob) == "Character name: Alice\nCharacter description: A\n\nCharacter name: Bob"
    end

    test "a character's own description names that character, whoever replies", %{scope: scope} do
      {:ok, player} =
        Characters.create_character(scope, %{
          name: "Pat",
          description: "{{ anchors.player.name }} watches {{ anchors.character.name }}."
        })

      {:ok, alice} =
        Characters.create_character(scope, %{name: "Alice", description: "{{ anchors.character.name }} hums."})

      {:ok, bob} = Characters.create_character(scope, %{name: "Bob"})
      chat = %{chat(scope, [player, alice, bob]) | group_cards: :join}
      empty = prompt(scope, "Empty", [])

      anchors = fn responder ->
        Builder.build(empty, Builder.context(scope, chat, character: responder)).state.data["anchors"]
      end

      for responder <- [alice, bob] do
        anchors = anchors.(responder)
        # Alice's card names Alice either way; the player's description sees the responder.
        assert Enum.map(anchors["cards"], & &1["description"]) == ["Alice hums.", nil]
        assert anchors["player"]["description"] == "Pat watches #{responder.name}."
        # Once the descriptions are done, anchors.character is the responder again.
        assert anchors["character"]["name"] == responder.name
      end
    end
  end

  describe "images" do
    setup %{scope: scope} do
      prompt =
        prompt(scope, "Images", [
          block(scope, "Sys", %{content: "sys"}),
          block(scope, "History", %{kind: :chat_history})
        ])

      %{prompt: prompt, fox: fox!()}
    end

    test "a model that cannot see images reads the description line", %{scope: scope} = ctx do
      say(scope, ctx.chat, ctx.hero, "Look", [ctx.fox])

      assert %{messages: [_, %{role: :user, content: content}]} =
               Builder.render(ctx.prompt, model(scope, :chat), Builder.context(scope, ctx.chat, character: ctx.foil))

      assert content == "#{ctx.hero.name}: Look\n[Image: A red fox]"

      assert %{prompt: text} =
               Builder.render(ctx.prompt, model(scope, :text), Builder.context(scope, ctx.chat, character: ctx.foil))

      assert text =~ "#{ctx.hero.name}: Look\n[Image: A red fox]"
    end

    test "attach_images sends the image as a part after its turn's text", %{scope: scope} = ctx do
      say(scope, ctx.chat, ctx.hero, "Look", [ctx.fox])
      context = Builder.context(scope, ctx.chat, character: ctx.foil, attach_images: true)

      assert %{messages: [_, %{role: :user, content: parts}]} = Builder.render(ctx.prompt, model(scope, :chat), context)
      fox_id = ctx.fox.id

      assert [%Request.Text{text: text}, %AttachmentRef{attachment: %Attachment{id: ^fox_id}}] = parts
      assert text == "#{ctx.hero.name}: Look"
    end

    test "adjacent turns in one role run merge their text around the images", %{scope: scope} = ctx do
      say(scope, ctx.chat, ctx.hero, "Look", [ctx.fox])
      say(scope, ctx.chat, ctx.hero, "Again")
      context = Builder.context(scope, ctx.chat, character: ctx.foil, attach_images: true)

      assert %{messages: [_, %{role: :user, content: [_text, %AttachmentRef{}, %Request.Text{text: again}]}]} =
               Builder.render(ctx.prompt, model(scope, :chat), context)

      assert again == "#{ctx.hero.name}: Again"
    end

    test "an image-only message still makes a turn", %{scope: scope} = ctx do
      say(scope, ctx.chat, ctx.hero, "", [ctx.fox])

      assert %{messages: [_, %{role: :user, content: content}]} =
               Builder.render(ctx.prompt, model(scope, :chat), Builder.context(scope, ctx.chat, character: ctx.foil))

      assert content == "#{ctx.hero.name}: [Image: A red fox]"
    end

    test "past the image limit, older images go as their description lines", %{scope: scope} = ctx do
      {:ok, owl} = Attachments.store_binary(fox_png())
      owl = owl |> Ecto.Changeset.change(description: "An owl") |> Repo.update!()
      say(scope, ctx.chat, ctx.hero, "First", [ctx.fox])
      say(scope, ctx.chat, ctx.foil, "Second", [owl])
      context = Builder.context(scope, ctx.chat, character: ctx.foil, attach_images: true, inline_limits: %{image: 1})
      owl_id = owl.id

      assert %{messages: [_, %{role: :user, content: older}, %{role: :assistant, content: newer}]} =
               Builder.render(ctx.prompt, model(scope, :chat), context)

      assert older == "#{ctx.hero.name}: First\n[Image: A red fox]"
      assert [%Request.Text{text: "Second"}, %AttachmentRef{attachment: %Attachment{id: ^owl_id}}] = newer
    end

    test "the inline limit never splits a message's images", %{scope: scope} = ctx do
      {:ok, owl} = Attachments.store_binary(fox_png())
      {:ok, cat} = Attachments.store_binary(fox_png())
      say(scope, ctx.chat, ctx.hero, "First", [ctx.fox])
      say(scope, ctx.chat, ctx.foil, "Second", [owl, cat])
      context = Builder.context(scope, ctx.chat, character: ctx.foil, attach_images: true, inline_limits: %{image: 1})
      {owl_id, cat_id} = {owl.id, cat.id}

      assert %{messages: [_, %{role: :user, content: older}, %{role: :assistant, content: newer}]} =
               Builder.render(ctx.prompt, model(scope, :chat), context)

      assert older == "#{ctx.hero.name}: First\n[Image: A red fox]"

      assert [
               %Request.Text{text: "Second"},
               %AttachmentRef{attachment: %Attachment{id: ^owl_id}},
               %AttachmentRef{attachment: %Attachment{id: ^cat_id}}
             ] = newer
    end

    test "the reply's images count toward the inline limit as the newest message", %{scope: scope} = ctx do
      {:ok, owl} = Attachments.store_binary(fox_png())
      say(scope, ctx.chat, ctx.hero, "First", [ctx.fox])
      reply = say(scope, ctx.chat, ctx.foil, "", [owl])
      {[reply], messages} = Enum.split_with(Messages.list_messages(ctx.chat), &(&1.id == reply.id))
      owl_id = owl.id

      context =
        Builder.context(scope, ctx.chat,
          character: ctx.foil,
          messages: messages,
          reply: reply,
          attach_images: true,
          inline_limits: %{image: 1}
        )

      assert %{messages: rendered} = Builder.render(ctx.prompt, model(scope, :chat), context)

      assert [%AttachmentRef{attachment: %Attachment{id: ^owl_id}}] =
               for(%{content: parts} <- rendered, is_list(parts), %AttachmentRef{} = part <- parts, do: part)
    end

    test "guide images join the last user turn for a vision model, and read as description lines otherwise",
         %{scope: scope} = ctx do
      prompt =
        prompt(scope, "Guided", [
          block(scope, "Sys", %{content: "Guide: {{ anchors.guide.text }}"}),
          block(scope, "History", %{kind: :chat_history})
        ])

      say(scope, ctx.chat, ctx.hero, "Look")
      fox_id = ctx.fox.id

      context =
        Builder.context(scope, ctx.chat,
          character: ctx.foil,
          guide: "Show it",
          guide_attachments: [ctx.fox],
          attach_images: true
        )

      assert %{messages: [%{role: :system, content: system}, %{role: :user, content: parts}]} =
               Builder.render(prompt, model(scope, :chat), context)

      assert system == "Guide: Show it\n[Image: A red fox]"
      assert [%Request.Text{text: text}, %AttachmentRef{attachment: %Attachment{id: ^fox_id}}] = parts
      assert text == "#{ctx.hero.name}: Look"

      blind = Builder.context(scope, ctx.chat, character: ctx.foil, guide: "Show it", guide_attachments: [ctx.fox])
      assert %{messages: messages} = Builder.render(prompt, model(scope, :chat), blind)
      assert hd(messages).content == "Guide: Show it\n[Image: A red fox]"
      refute inspect(messages) =~ "AttachmentRef"
    end

    test "a document past the document limit goes as its summary, or its full text until it has one",
         %{scope: scope} = ctx do
      {:ok, older} = Attachments.store_binary("The long first notes.", filename: "a.txt", kinds: Attachment.kinds())
      {:ok, newer} = Attachments.store_binary("The long second notes.", filename: "b.txt", kinds: Attachment.kinds())
      older = older |> Ecto.Changeset.change(description: "Short summary") |> Repo.update!()
      say(scope, ctx.chat, ctx.hero, "First", [older])
      say(scope, ctx.chat, ctx.hero, "Second", [newer])
      model = model(scope, :chat)

      render = fn ->
        context = Builder.context(scope, ctx.chat, character: ctx.foil, inline_limits: %{document: 1})
        %{messages: [_, %{role: :user, content: content}]} = Builder.render(ctx.prompt, model, context)
        content
      end

      content = render.()
      assert content =~ "First\n[Document: a.txt (summary)]\nShort summary\n[/Document]"
      assert content =~ "Second\n[Document: b.txt]\nThe long second notes.\n[/Document]"
      refute content =~ "The long first notes."

      older |> Ecto.Changeset.change(description: nil) |> Repo.update!()
      assert render.() =~ "First\n[Document: a.txt]\nThe long first notes.\n[/Document]"
    end

    test "a described audio clip reads as its description to a model that can't hear it", %{scope: scope} = ctx do
      {:ok, clip} =
        Attachments.store_binary("ID3" <> <<4, 0, 0, 0, 0, 0>>, filename: "howl.mp3", kinds: Attachment.kinds())

      clip = clip |> Ecto.Changeset.change(description: "A dog barks") |> Repo.update!()
      say(scope, ctx.chat, ctx.hero, "Listen", [clip])

      assert %{messages: [_, %{role: :user, content: content}]} =
               Builder.render(ctx.prompt, model(scope, :chat), Builder.context(scope, ctx.chat, character: ctx.foil))

      assert content == "#{ctx.hero.name}: Listen\n[Audio: howl.mp3]\nA dog barks\n[/Audio]"
    end
  end

  describe "context limit" do
    # Each message estimates to about 1000 tokens; 4000 - 500 reserved holds three after the margin.
    setup %{scope: scope} = ctx do
      for i <- 1..6, do: say(scope, ctx.chat, ctx.hero, "M#{i} " <> String.duplicate("x", 3300))

      prompt =
        prompt(scope, "Fit", [
          block(scope, "System", %{content: "You are a narrator."}),
          block(scope, "History", %{kind: :chat_history})
        ])

      %{prompt: prompt}
    end

    test "chat history keeps its newest turns that fit", %{scope: scope} = ctx do
      for mode <- [:chat, :text] do
        model = model(scope, mode)
        cl = %ContextLimit{limit: 4000, reserve: 500, model: model}
        context = Builder.context(scope, ctx.chat, character: ctx.foil, context_limit: cl)
        built = Builder.build(ctx.prompt, context)

        assert %{kept: 3, trimmed: 3, overflow?: false} = built.context

        text =
          case Builder.render_segments(built.segments, model, context) do
            %{messages: messages} -> Enum.map_join(messages, "\n", & &1.content)
            %{prompt: prompt} -> prompt
          end

        for i <- 1..3, do: refute(text =~ "M#{i} ")
        for i <- 4..6, do: assert(text =~ "M#{i} ")
      end
    end

    test "an at_depth item counts from the end of the kept history", %{scope: scope} = ctx do
      injection!(scope, ctx.chat, %{key: "aside", content: "Aside", position: :at_depth, depth: 1})
      cl = %ContextLimit{limit: 4000, reserve: 500, model: model(scope, :chat)}
      context = Builder.context(scope, ctx.chat, character: ctx.foil, context_limit: cl)

      assert %{segments: [_system, %{source: :chat_history, turns: turns}]} = Builder.build(ctx.prompt, context)
      assert [%{content: "Aside"}, %{content: last}] = Enum.take(turns, -2)
      assert last =~ "M6 "
      assert length(turns) == 4
    end

    test "fixed text over the limit overflows and sends no history", %{scope: scope} = ctx do
      prompt =
        prompt(scope, "Huge", [
          block(scope, "System", %{content: String.duplicate("x", 6600)}),
          block(scope, "History", %{kind: :chat_history})
        ])

      cl = %ContextLimit{limit: 1000, reserve: 500, model: model(scope, :chat)}
      built = Builder.build(prompt, Builder.context(scope, ctx.chat, character: ctx.foil, context_limit: cl))

      assert %{overflow?: true, kept: 0, trimmed: 6} = built.context
      assert [%{source: :template}] = built.segments
    end

    test "without a limit every message goes and there is no report", %{scope: scope} = ctx do
      built = Builder.build(ctx.prompt, Builder.context(scope, ctx.chat, character: ctx.foil))

      assert built.context == nil
      assert [_system, %{turns: turns}] = built.segments
      assert length(turns) == 6
    end

    test "the reply's image costs a kept history entry", %{scope: scope} = ctx do
      reply = say(scope, ctx.chat, ctx.foil, "", [fox!()])
      {[reply], messages} = Enum.split_with(Messages.list_messages(ctx.chat), &(&1.id == reply.id))
      model = %{model(scope, :chat) | image_detail: :low}
      opts = [character: ctx.foil, messages: messages, attach_images: true]

      assert_costs_one_entry(
        ctx.prompt,
        model,
        &Builder.context(scope, ctx.chat, opts ++ [context_limit: &1]),
        &Builder.context(scope, ctx.chat, opts ++ [reply: reply, context_limit: &1])
      )
    end

    test "a native guide video costs a kept history entry", %{scope: scope} = ctx do
      # Entries larger than a video's 2000-token estimate, so it takes exactly one.
      chat = chat(scope, [ctx.hero, ctx.foil])
      for i <- 1..6, do: say(scope, chat, ctx.hero, "V#{i} " <> String.duplicate("x", 11_000))
      {:ok, clip} = Attachments.store_binary(fox_png())
      video = %{clip | kind: :video, content_type: "video/mp4", status: :ready}
      opts = [character: ctx.foil, attach_video: true]

      assert_costs_one_entry(
        ctx.prompt,
        model(scope, :chat),
        &Builder.context(scope, chat, opts ++ [context_limit: &1]),
        &Builder.context(scope, chat, opts ++ [guide_attachments: [video], context_limit: &1])
      )
    end
  end

  describe "subscriber toggles" do
    test "a site block the chat owner toggled off is missing from their build", %{scope: admin} do
      user = scope!(%{role: :user})

      {:ok, site_block} =
        Prompts.create_block(admin, %{name: "Site-#{unique()}", content: "Site text"}, site: true)

      own = block(user, "Own", %{content: "Own text"})
      prompt = prompt(user, "Mixed", [site_block, own])
      chat = chat(user, [character(user, "Hero"), character(user, "Foil")])
      contents = fn -> Enum.map(Builder.build(prompt, Builder.context(user, chat)).segments, & &1.content) end

      assert contents.() == ["Site text", "Own text"]
      assert {:ok, _} = Sharing.set_toggle(user, site_block, false)
      assert contents.() == ["Own text"]
    end
  end

  ## Helpers

  # Sizes a limit that `base`'s whole history exactly fills, then asserts `extra`'s added fixed cost
  # keeps one entry fewer.
  defp assert_costs_one_entry(prompt, model, base, extra) do
    loose = %ContextLimit{limit: 1_000_000, reserve: 500, model: model}
    %{context: %{used: used, kept: kept}} = Builder.build(prompt, base.(loose))
    tight = %{loose | limit: 500 + used + div(used, 10) + 128}

    assert %{context: %{kept: ^kept}} = Builder.build(prompt, base.(tight))
    assert %{context: %{kept: fewer}} = Builder.build(prompt, extra.(tight))
    assert fewer == kept - 1
  end

  defp unique, do: System.unique_integer([:positive])

  defp subscribe!(owner, subscriber, item) do
    {:ok, share} = Sharing.invite(owner, item, "@" <> subscriber.user.handle, role: :subscriber)
    {:ok, share} = Sharing.accept(subscriber, share.id)
    share
  end

  defp prompt(scope, name, blocks) do
    {:ok, prompt} = Prompts.create_prompt(scope, %{name: "#{name}-#{unique()}"})
    for b <- blocks, do: {:ok, _} = Prompts.add_block(scope, prompt, b)
    Prompts.get_prompt!(prompt.id)
  end

  defp block(scope, name, attrs) do
    {:ok, block} = Prompts.create_block(scope, Map.merge(%{name: "#{name}-#{unique()}"}, attrs))
    block
  end

  defp outlet(scope, key) do
    {:ok, outlet} = Prompts.create_outlet(scope, %{key: key, name: String.capitalize(key)})
    outlet
  end

  defp model(scope, mode) do
    {:ok, model} =
      AI.create_model(scope, %{name: "model-#{unique()}", api_model_id: "m", completion_mode: mode})

    model
  end

  defp book(scope) do
    {:ok, book} = Lore.create_book(scope, %{name: "book-#{unique()}"})
    book
  end

  defp lore_entry(scope, name, book, attrs) do
    {:ok, entry} = Lore.create_entry(scope, Map.merge(%{name: "#{name}-#{unique()}"}, attrs), [book.id])
    entry
  end

  defp injection!(scope, chat, attrs) do
    {:ok, injection} = Injections.create_injection(scope, chat.id, attrs)
    injection
  end

  defp say(scope, chat, character, content) do
    {:ok, message} = Messages.send_message(scope, chat, character.id, content)
    message
  end

  defp say(scope, chat, character, content, attachments) do
    {:ok, message} = Messages.send_message(scope, chat, character.id, content, attachments: attachments)
    message
  end

  defp fox_png,
    do:
      Base.decode64!("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")

  defp fox! do
    {:ok, attachment} = Attachments.store_binary(fox_png())
    attachment |> Ecto.Changeset.change(description: "A red fox") |> Repo.update!()
  end

  defp character(scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: "#{name}-#{unique()}"})
    character
  end

  defp chat(scope, [player | _] = characters) do
    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: "chat-#{unique()}",
        participants: Enum.map(characters, &%{character_id: &1.id}),
        player_character_id: player.id
      })

    Chats.get_chat!(chat.id)
  end
end
