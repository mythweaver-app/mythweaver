alias Mythweaver.Prompts
alias Mythweaver.Prompts.Standard
alias Mythweaver.Repo

Code.require_file("scope.exs", __DIR__)
seed_scope = Mythweaver.Seeds.scope()

# Seed Prompts
#
# Runnable on its own (`mix run priv/repo/seeds/prompts.exs`) and required by `priv/repo/seeds.exs`.
# Re-runnable: it replaces every prompt and block. Deleting prompts cascades memberships and bindings.
#
# Modeled on SillyTavern's `default/content/presets/openai/Default.json`: its `prompt_order`, merged
# with the group scope (100001), and its `new_chat_prompt`, `new_group_chat_prompt`,
# `new_example_chat_prompt` and `group_nudge_prompt` strings. Following AikoBots' layout, the prompt
# is a list of lore outlets around fixed text. Every block is a Liquid template reading `anchors.*`
# and `outlets.*`, and each block is one logical section rather than a heading block followed by a
# value block. Chat history is the one non-template block: for chat models it expands into turns.
#
# Laid out so everything ahead of the chat history reads the same whoever replies. A local model's
# prompt cache (llama.cpp and the like) reuses only an unchanged prompt prefix; SillyTavern's layout
# names the responder in its first sentence and puts their card apart from everyone else's, so in a
# group chat every change of speaker would read the whole prompt again. Here no section before the
# history depends on the responder: the main prompt names nobody, every card the reply sees
# (`anchors.cards`) is listed in participant order, and the player's card always shows. Who to
# write, and the never-write-for-the-player rule, come after the history. The chat history block
# uses fixed speaker roles, so for a chat model the turns themselves do not change with the
# responder either (responder roles would flip every earlier line by either speaker). With the
# chat's Group cards on Join or Join all, everything before the closing instruction is then the same
# for every reply; with Swap only the responder's card is sent, so it still changes with the speaker.
Repo.delete_all(Prompts.Prompt)
Repo.delete_all(Prompts.Block)

# SillyTavern's Default preset ships `jailbreak` ("Post-History Instructions") with empty content: a
# named slot at the very end of the prompt that the user fills in. A custom outlet is the equivalent
# here, except the content arrives through lore activation, so it can be conditional and budgeted.
_post_history_outlet =
  Enum.find(Prompts.list_outlets(seed_scope), &(&1.key == "post_history")) ||
    (fn ->
       {:ok, outlet} =
         Prompts.create_outlet(
           seed_scope,
           %{
             key: "post_history",
             name: "Post-history instructions",
             description: "Rendered last, after the conversation — SillyTavern's Post-History Instructions slot."
           },
           site: true
         )

       outlet
     end).()

block_specs = [
  {"Main prompt", :template,
   ~S"""
   A fictional roleplay between {{ anchors.chat.participants | to_sentence }}. Stay in character and keep replies vivid and concise. Which character to write is said at the end.
   """, "SillyTavern's Main Prompt without the responder's name, so it reads the same for every reply.", %{}},
  {"Lore before character", :template, Standard.lore_before(), "SillyTavern's World Info (before).", %{}},
  {"Characters", :template, Standard.cards(),
   "Every card the reply sees (the chat's Group cards setting), the responder's included, in participant order.", %{}},
  {"Player", :template,
   ~S"""
   {% if anchors.player %}
   Player name: {{ anchors.player.name }}
   {% if anchors.player.pronouns %}Player pronouns: {{ anchors.player.pronouns }}
   {% endif %}{% if anchors.player.description %}Player description: {{ anchors.player.description }}
   {% endif %}{% if anchors.player.appearance %}Player appearance: {{ anchors.player.appearance }}{% endif %}
   {% endif %}
   """, "The player's card, shown even when the AI speaks for the player, so it never changes with the responder.",
   %{}},
  {"Scene", :template,
   ~S"""
   {% if anchors.chat.name %}Scene: {{ anchors.chat.name }}
   {% endif %}Participants: {{ anchors.participants }}
   """, "The chat and who is in it.", %{}},
  {"Lore after character", :template, Standard.lore_after(), "SillyTavern's World Info (after).", %{}},
  {"Example dialogue", :template, Standard.example_dialogue("[Example chat]"),
   "SillyTavern's Chat Examples, filled from the examples lore slots.", %{}},
  {"Start of chat", :template,
   Standard.start_of_chat(
     "[Start a new chat]",
     "[Start a new group chat. Group members: {{ anchors.participants }}]"
   ), "SillyTavern's new_chat_prompt, or its new_group_chat_prompt when more than two characters share the chat.",
   %{}},
  {"Chat history", :chat_history, nil,
   "The transcript with fixed speaker roles: characters as the assistant, the player as the user, every line named, whoever replies.",
   %{speaker_roles: :fixed}},
  {"Guide", :template, Standard.guide(),
   "A guided generation's outline, framed as beats to write out rather than text to continue. Renders nothing without a guide.",
   %{}},
  {"Refine", :template, Standard.refine(),
   "A refine's editing instructions and the message being rewritten, placed last so nothing after it asks for a new reply. Renders nothing unless refining.",
   %{}},
  {"Author's note", :template, Standard.author_note(), "World Info before/after the author's note.", %{}},
  {"Post-history instructions", :template, Standard.post_history(),
   "SillyTavern's Post-History Instructions, filled by the post_history outlet.", %{}},
  {"Reply as", :template,
   Standard.group_nudge(
     String.trim(~S"""
     [Write {{ anchors.character.name }}'s next reply only. Stay in character as {{ anchors.character.name }}, and never write dialogue or actions for {% if anchors.character.player %}anyone else{% else %}{{ anchors.player.name | default: "the player" }} or anyone else{% endif %}.]
     """)
   ),
   "Who to write and the never-write-for-the-player rule, after the history where a change of speaker costs no cache. Left out of a refine.",
   %{}}
]

blocks =
  Map.new(block_specs, fn {name, kind, content, description, extra} ->
    {:ok, block} =
      Prompts.create_block(
        seed_scope,
        Map.merge(
          %{
            name: name,
            role: :system,
            kind: kind,
            content: content && String.trim(content),
            description: description,
            # A card's system prompt and post-history instructions replace these
            # (`Mythweaver.Prompts.Builder`), SillyTavern's `prefer_character_prompt` default.
            role_tag: %{"Main prompt" => :main, "Post-history instructions" => :post_history}[name]
          },
          extra
        ),
        site: true
      )

    {name, block}
  end)

# Every chat here may have several AI characters, so there is one prompt, not SillyTavern's separate
# 1:1 and group orders: the opener branches on chat size, and "Reply as" is harmless with one AI
# character.
{:ok, default_prompt} =
  Prompts.create_prompt(
    seed_scope,
    %{
      name: "Default Roleplay",
      description:
        "Nothing before the chat history depends on who replies (with Group cards on Join or Join all), so a local model's prompt cache reuses it between replies; who to write comes at the end. Bound globally, so every chat gets it until something more specific is bound."
    },
    site: true
  )

Enum.each(
  [
    "Main prompt",
    "Lore before character",
    "Characters",
    "Player",
    "Scene",
    "Lore after character",
    "Example dialogue",
    "Start of chat",
    "Chat history",
    "Guide",
    "Author's note",
    "Post-history instructions",
    "Reply as",
    # Last, so the edit framing is the final instruction the model reads.
    "Refine"
  ],
  fn name ->
    {:ok, _} = Prompts.add_block(seed_scope, default_prompt, Map.fetch!(blocks, name), %{enabled: true})
  end
)

{:ok, _} = Prompts.bind_prompt(seed_scope, default_prompt, :global)

IO.puts("Seeded #{length(Prompts.list_blocks(seed_scope))} prompt blocks and the Default Roleplay prompt")
