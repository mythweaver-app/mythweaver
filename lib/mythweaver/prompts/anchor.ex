defmodule Mythweaver.Prompts.Anchor do
  @moduledoc """
  The `anchors` template data: the named values a prompt block, lore entry, character description or
  typed message reads as `{{ anchors.… }}`.

  This is the only place anchor data is assembled. `data/2` returns plain string-keyed maps, never
  structs, so a template reaches only the fields listed here. Character descriptions arrive
  pre-rendered from `Mythweaver.Prompts.Builder`; `anchors.lore` starts empty and the builder fills it
  once lore has rendered.

  A protected character's (`Mythweaver.Sharing.Visibility.protected_for?/2` for the chat owner)
  description and appearance are never here as text: `:character_tokens` maps its id to a token id
  per field, and `data/2` gives `Mythweaver.Sharing.Protected.token/1` instead, which the builder
  reveals once every template has rendered.

  A value that would be blank (`nil`, `""` or whitespace) is `nil`: Liquid treats `""` as truthy, so
  `{% if anchors.character.pronouns %}` only works if blanks are `nil`.

  Called anchors, not tokens: "token" in this app already means an LLM token (`SamplerParams.max_tokens`,
  `Model.context_window`, `Completion.prompt_tokens`), and overloading it would make budget code and
  prompt code indistinguishable.

  Deliberately small: anchors only name data this app actually stores. `Mythweaver.Characters.Character`
  has no personality/scenario/system_prompt column, so there is no anchor for them. Add the column
  first, then the anchor. Its greetings get no anchor on purpose: they open a chat
  (`Mythweaver.Greetings`), they are not prompt text. Custom lore outlets are user data, so they live
  under `outlets.<key>`, not here.

  `anchors.memory_counts` is always present. `anchors.memory` exists only while a memory-book prompt
  renders (`Builder.context/2` with `:memory`); its paths are listed apart, in `memory_catalog/0`, so
  a roleplay prompt's data never carries them.
  """

  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Injections.Injection
  alias Mythweaver.Lore.Activation
  alias Mythweaver.Lore.Settings
  alias Mythweaver.Messages.Message
  alias Mythweaver.Prompts.ContextLimit
  alias Mythweaver.Prompts.Transcript
  alias Mythweaver.Sharing.Protected
  alias Mythweaver.Templates.State

  @type context :: %{
          chat: Chat.t() | nil,
          owner_id: Ecto.UUID.t() | nil,
          character: Character.t() | nil,
          player_character: Character.t() | nil,
          tags: %{characters: map(), chat: [String.t()]} | nil,
          messages: [Message.t()],
          lore: Activation.result() | nil,
          outlets: %{optional(String.t()) => [Activation.decision()]},
          continue: String.t() | nil,
          guide: String.t() | nil,
          guide_attachments: [Attachment.t()],
          reply: Message.t() | nil,
          refine: %{instructions: String.t(), text: String.t() | nil} | nil,
          templates: State.t() | nil,
          variables: %{chat: map(), global: map()} | nil,
          injections: [Injection.t()],
          memory: map() | nil,
          memory_counts: %{optional(String.t()) => non_neg_integer()},
          attach_images: boolean(),
          inline_limits: %{optional(atom()) => non_neg_integer() | nil},
          attach_files: boolean(),
          attach_audio: boolean(),
          attach_video: boolean(),
          caption_template: String.t() | nil,
          context_limit: ContextLimit.t() | nil,
          character_tokens: %{optional(Ecto.UUID.t()) => %{optional(String.t()) => Ecto.UUID.t()}}
        }

  # `type` is a display string: `| nil` marks a value that is `nil` when blank or absent. An
  # `array<map>` entry lists its items' `fields` in order. `test/mythweaver/prompts/anchor_test.exs`
  # checks every entry against what `Prompts.Builder` actually produces, and against
  # `docs/prompts/templates.md`, so a path, type or field added on one side and not the other fails.
  @catalog [
             %{
               path: "anchors.character.name",
               type: "string | nil",
               description:
                 dpgettext_noop(
                   "prompts",
                   "tooltip: what a template anchor path holds",
                   "The responding character's name; in a typed message, the message's author (use anchors.chat.characters or char for the AI characters); nil when there is no responder."
                 )
             },
             %{
               path: "anchors.character.pronouns",
               type: "string | nil",
               description:
                 dpgettext_noop(
                   "prompts",
                   "tooltip: what a template anchor path holds",
                   "The responding character's pronouns."
                 )
             },
             %{
               path: "anchors.character.description",
               type: "string | nil",
               description:
                 dpgettext_noop(
                   "prompts",
                   "tooltip: what a template anchor path holds",
                   "The responding character's description, rendered."
                 )
             },
             %{
               path: "anchors.character.appearance",
               type: "string | nil",
               description:
                 dpgettext_noop(
                   "prompts",
                   "tooltip: what a template anchor path holds",
                   "How the responding character looks; filled from their avatar's description, editable."
                 )
             },
             %{
               path: "anchors.character.player",
               type: "bool | nil",
               description:
                 dpgettext_noop(
                   "prompts",
                   "tooltip: what a template anchor path holds",
                   "Whether the responder is the player: true when the AI speaks for the player, and in the player's own typed messages; nil when there is no responder."
                 )
             },
             %{
               path: "anchors.character.tags",
               type: "array<string> | nil",
               description:
                 dpgettext_noop(
                   "prompts",
                   "tooltip: what a template anchor path holds",
                   "The responding character's tags, siblings resolved and parents implied (e.g. \"species:dragon\"); nil when there is no responder."
                 )
             },
             %{
               path: "anchors.player.name",
               type: "string | nil",
               description:
                 dpgettext_noop(
                   "prompts",
                   "tooltip: what a template anchor path holds",
                   "The player character's name; nil when the chat has no player."
                 )
             },
             %{
               path: "anchors.player.pronouns",
               type: "string | nil",
               description:
                 dpgettext_noop(
                   "prompts",
                   "tooltip: what a template anchor path holds",
                   "The player character's pronouns."
                 )
             },
             %{
               path: "anchors.player.description",
               type: "string | nil",
               description:
                 dpgettext_noop(
                   "prompts",
                   "tooltip: what a template anchor path holds",
                   "The player character's description, rendered."
                 )
             },
             %{
               path: "anchors.player.appearance",
               type: "string | nil",
               description:
                 dpgettext_noop(
                   "prompts",
                   "tooltip: what a template anchor path holds",
                   "How the player character looks."
                 )
             },
             %{
               path: "anchors.player.tags",
               type: "array<string> | nil",
               description:
                 dpgettext_noop(
                   "prompts",
                   "tooltip: what a template anchor path holds",
                   "The player character's tags, siblings resolved and parents implied."
                 )
             },
             %{
               path: "anchors.chat.name",
               type: "string | nil",
               description: dpgettext_noop("prompts", "tooltip: what a template anchor path holds", "The chat's name.")
             },
             %{
               path: "anchors.chat.participants",
               type: "array<string>",
               description:
                 dpgettext_noop(
                   "prompts",
                   "tooltip: what a template anchor path holds",
                   "Every participant's name, player first. Join it for prose: | join: \", \"."
                 )
             },
             %{
               path: "anchors.chat.tags",
               type: "array<string>",
               description:
                 dpgettext_noop(
                   "prompts",
                   "tooltip: what a template anchor path holds",
                   "The chat's tags, siblings resolved and parents implied."
                 )
             },
             %{
               path: "anchors.chat.members",
               type: "array<map>",
               description:
                 dpgettext_noop(
                   "prompts",
                   "tooltip: what a template anchor path holds",
                   "Every participant in speaking order."
                 ),
               fields: [
                 {"name", "string"},
                 {"description", "string | nil"},
                 {"pronouns", "string | nil"},
                 {"appearance", "string | nil"},
                 {"muted", "bool"},
                 {"player", "bool"},
                 {"tags", "array<string>"}
               ]
             },
             %{
               path: "anchors.chat.characters",
               type: "array<string>",
               description:
                 dpgettext_noop(
                   "prompts",
                   "tooltip: what a template anchor path holds",
                   "Every participant's name but the player's, in speaking order. In a typed message this names the AI characters: | join: \", \"."
                 )
             },
             %{
               path: "anchors.participants",
               type: "string | nil",
               description:
                 dpgettext_noop(
                   "prompts",
                   "tooltip: what a template anchor path holds",
                   "Every participant's name, player first, comma separated."
                 )
             },
             %{
               path: "anchors.other_characters",
               type: "string | nil",
               description:
                 dpgettext_noop(
                   "prompts",
                   "tooltip: what a template anchor path holds",
                   "Everyone but the responder and the player whose card the chat's Group cards setting joins (none with swap), as \"Name: description\" paragraphs. Card text, not a list of names: use anchors.chat.characters for names."
                 )
             },
             %{
               path: "anchors.cards",
               type: "array<map>",
               description:
                 dpgettext_noop(
                   "prompts",
                   "tooltip: what a template anchor path holds",
                   "Every character whose card the chat's Group cards setting gives this reply, the responder included and the player left out (they are anchors.player), in participant order. The same list whoever replies, unless with swap."
                 ),
               fields: [
                 {"name", "string"},
                 {"description", "string | nil"},
                 {"pronouns", "string | nil"},
                 {"appearance", "string | nil"}
               ]
             },
             %{
               path: "anchors.messages",
               type: "array<map>",
               description:
                 dpgettext_noop(
                   "prompts",
                   "tooltip: what a template anchor path holds",
                   ~s{The AI-visible transcript, oldest first. role is "user" or "assistant".}
                 ),
               fields: [{"author", "string"}, {"content", "string"}, {"role", "string"}]
             },
             %{
               path: "anchors.now",
               type: "string",
               description:
                 dpgettext_noop(
                   "prompts",
                   "tooltip: what a template anchor path holds",
                   "The current UTC time (ISO 8601)."
                 )
             },
             %{
               path: "anchors.guide.text",
               type: "string | nil",
               description:
                 dpgettext_noop(
                   "prompts",
                   "tooltip: what a template anchor path holds",
                   "The user's outline for this one generation, verbatim, then one line per attachment sent with the guide (an image's description; a clip's or document's text unless the model receives it natively). anchors.guide is nil when the generation has no guide."
                 )
             },
             %{
               path: "anchors.guide.continue",
               type: "bool | nil",
               description:
                 dpgettext_noop(
                   "prompts",
                   "tooltip: what a template anchor path holds",
                   "True when the guided generation continues the last message instead of writing a new one."
                 )
             },
             %{
               path: "anchors.refine.instructions",
               type: "string | nil",
               description:
                 dpgettext_noop(
                   "prompts",
                   "tooltip: what a template anchor path holds",
                   "The user's editing instructions for a refine, verbatim, then one line per attachment sent with them (an image's description; a clip's or document's text unless the model receives it natively). anchors.refine is nil unless the generation rewrites the last message."
                 )
             },
             %{
               path: "anchors.refine.text",
               type: "string | nil",
               description:
                 dpgettext_noop(
                   "prompts",
                   "tooltip: what a template anchor path holds",
                   "The current text of the message being rewritten."
                 )
             }
           ] ++
             for(
               slot <- Settings.anchor_slots(),
               do: %{
                 path: "anchors.lore.#{slot}",
                 type: "string | nil",
                 description:
                   dpgettext_noop(
                     "prompts",
                     "tooltip: what a template anchor path holds",
                     "Lore that activated into the %{slot_name} slot, rendered."
                   ),
                 bindings: %{slot_name: String.replace(slot, "_", " ")}
               }
             ) ++
             [
               %{
                 path: "anchors.memory_counts.tier0",
                 type: "int",
                 description:
                   dpgettext_noop(
                     "prompts",
                     "tooltip: what a template anchor path holds",
                     "How many tier-0 memories the chat's memory book holds; 0 when it has no book."
                   )
               },
               %{
                 path: "anchors.memory_counts.tier1",
                 type: "int",
                 description:
                   dpgettext_noop(
                     "prompts",
                     "tooltip: what a template anchor path holds",
                     "How many tier-1 consolidations (Arcs) the chat's memory book holds; 0 when it has no book."
                   )
               },
               %{
                 path: "anchors.memory_counts.tier2",
                 type: "int",
                 description:
                   dpgettext_noop(
                     "prompts",
                     "tooltip: what a template anchor path holds",
                     "How many tier-2 consolidations (Chapters) the chat's memory book holds; 0 when it has no book."
                   )
               },
               %{
                 path: "anchors.memory_counts.tier3",
                 type: "int",
                 description:
                   dpgettext_noop(
                     "prompts",
                     "tooltip: what a template anchor path holds",
                     "How many tier-3 consolidations (Books) the chat's memory book holds; 0 when it has no book."
                   )
               },
               %{
                 path: "anchors.memory_counts.tier4",
                 type: "int",
                 description:
                   dpgettext_noop(
                     "prompts",
                     "tooltip: what a template anchor path holds",
                     "How many tier-4 consolidations (Legends) the chat's memory book holds; 0 when it has no book."
                   )
               },
               %{
                 path: "anchors.memory_counts.tier5",
                 type: "int",
                 description:
                   dpgettext_noop(
                     "prompts",
                     "tooltip: what a template anchor path holds",
                     "How many tier-5 consolidations (Series) the chat's memory book holds; 0 when it has no book."
                   )
               },
               %{
                 path: "anchors.memory_counts.tier6",
                 type: "int",
                 description:
                   dpgettext_noop(
                     "prompts",
                     "tooltip: what a template anchor path holds",
                     "How many tier-6 consolidations (Epics) the chat's memory book holds; 0 when it has no book."
                   )
               },
               %{
                 path: "anchors.memory_counts.clips",
                 type: "int",
                 description:
                   dpgettext_noop(
                     "prompts",
                     "tooltip: what a template anchor path holds",
                     "How many clips the chat's memory book holds; 0 when it has no book."
                   )
               },
               %{
                 path: "anchors.memory_counts.side_prompts",
                 type: "int",
                 description:
                   dpgettext_noop(
                     "prompts",
                     "tooltip: what a template anchor path holds",
                     "How many side-prompt entries the chat's memory book holds; 0 when it has no book."
                   )
               }
             ]

  @memory_counts_zero Map.new(
                        ~w(tier0 tier1 tier2 tier3 tier4 tier5 tier6 clips side_prompts),
                        &{&1, 0}
                      )

  # The same contract as `@catalog`, for `anchors.memory`; the same anchor test holds it to a populated
  # memory map and to the doc's "Memory anchors" section.
  @memory_catalog [
    %{
      path: "anchors.memory.kind",
      type: "string",
      description:
        dpgettext_noop(
          "prompts",
          "tooltip: what a template anchor path holds",
          ~s{The job: "memory", "consolidation", "compaction", "topical_clip", "side_prompt" or "memory_assistance".}
        )
    },
    %{
      path: "anchors.memory.scene",
      type: "string | nil",
      description:
        dpgettext_noop(
          "prompts",
          "tooltip: what a template anchor path holds",
          ~s{The scene's messages as "[#N] Name: text" lines, separated by blank lines.}
        )
    },
    %{
      path: "anchors.memory.scene_messages",
      type: "array<map>",
      description:
        dpgettext_noop(
          "prompts",
          "tooltip: what a template anchor path holds",
          "The scene's messages, oldest first. number is the message's display number."
        ),
      fields: [{"number", "int"}, {"author", "string"}, {"content", "string"}]
    },
    %{
      path: "anchors.memory.range.start",
      type: "int | nil",
      description:
        dpgettext_noop("prompts", "tooltip: what a template anchor path holds", "The scene's first display number.")
    },
    %{
      path: "anchors.memory.range.end",
      type: "int | nil",
      description:
        dpgettext_noop("prompts", "tooltip: what a template anchor path holds", "The scene's last display number.")
    },
    %{
      path: "anchors.memory.speakers",
      type: "string | nil",
      description:
        dpgettext_noop(
          "prompts",
          "tooltip: what a template anchor path holds",
          "The characters who speak in the scene, player excluded, comma separated."
        )
    },
    %{
      path: "anchors.memory.previous_memories",
      type: "array<map>",
      description:
        dpgettext_noop(
          "prompts",
          "tooltip: what a template anchor path holds",
          "Earlier memories sent as reference only, oldest first."
        ),
      fields: [{"title", "string"}, {"content", "string"}]
    },
    %{
      path: "anchors.memory.previous_text",
      type: "string | nil",
      description:
        dpgettext_noop(
          "prompts",
          "tooltip: what a template anchor path holds",
          ~s{Those previous memories as "### title" then content blocks.}
        )
    },
    %{
      path: "anchors.memory.context",
      type: "string | nil",
      description:
        dpgettext_noop(
          "prompts",
          "tooltip: what a template anchor path holds",
          ~s{The chat's Additional Context lore entries as "### name" then content blocks.}
        )
    },
    %{
      path: "anchors.memory.sources",
      type: "array<map>",
      description:
        dpgettext_noop(
          "prompts",
          "tooltip: what a template anchor path holds",
          ~s{The entries being consolidated or clipped. id is their zero-padded batch index ("001").}
        ),
      fields: [{"id", "string"}, {"title", "string"}, {"content", "string"}]
    },
    %{
      path: "anchors.memory.sources_text",
      type: "string | nil",
      description:
        dpgettext_noop(
          "prompts",
          "tooltip: what a template anchor path holds",
          ~s{Those sources as "[id] title" then content blocks.}
        )
    },
    %{
      path: "anchors.memory.previous_summary.title",
      type: "string | nil",
      description:
        dpgettext_noop(
          "prompts",
          "tooltip: what a template anchor path holds",
          "The newest entry already at the target tier, as canon. anchors.memory.previous_summary is nil when there is none."
        )
    },
    %{
      path: "anchors.memory.previous_summary.content",
      type: "string | nil",
      description: dpgettext_noop("prompts", "tooltip: what a template anchor path holds", "That entry's content.")
    },
    %{
      path: "anchors.memory.target_tier.number",
      type: "int | nil",
      description:
        dpgettext_noop(
          "prompts",
          "tooltip: what a template anchor path holds",
          "The consolidation's target tier, 1 to 6. anchors.memory.target_tier is nil outside consolidation."
        )
    },
    %{
      path: "anchors.memory.target_tier.name",
      type: "string | nil",
      description:
        dpgettext_noop(
          "prompts",
          "tooltip: what a template anchor path holds",
          "The target tier's name: Arc, Chapter, Book, Legend, Series or Epic."
        )
    },
    %{
      path: "anchors.memory.entry.title",
      type: "string | nil",
      description:
        dpgettext_noop(
          "prompts",
          "tooltip: what a template anchor path holds",
          "The existing entry being compacted or updated. anchors.memory.entry is nil when there is none."
        )
    },
    %{
      path: "anchors.memory.entry.content",
      type: "string | nil",
      description: dpgettext_noop("prompts", "tooltip: what a template anchor path holds", "That entry's content.")
    },
    %{
      path: "anchors.memory.entry.kind",
      type: "string | nil",
      description:
        dpgettext_noop(
          "prompts",
          "tooltip: what a template anchor path holds",
          ~s{That entry's record kind: "memory", "consolidation", "clip", "topical_clip" or "side_prompt".}
        )
    },
    %{
      path: "anchors.memory.topic",
      type: "string | nil",
      description: dpgettext_noop("prompts", "tooltip: what a template anchor path holds", "The topical clip's topic.")
    },
    %{
      path: "anchors.memory.keywords",
      type: "string | nil",
      description:
        dpgettext_noop(
          "prompts",
          "tooltip: what a template anchor path holds",
          "The topical clip's keywords, comma separated."
        )
    },
    %{
      path: "anchors.memory.clips",
      type: "array<map>",
      description:
        dpgettext_noop(
          "prompts",
          "tooltip: what a template anchor path holds",
          ~s{Memory assistance: the clips under review (uid is their batch index, "001"; type "ordinary" or "topical"), or the existing topical clips for topic suggestions.}
        ),
      fields: [
        {"uid", "string"},
        {"type", "string"},
        {"title", "string"},
        {"topic", "string"},
        {"keywords", "string"},
        {"content", "string"}
      ]
    },
    %{
      path: "anchors.memory.clips_text",
      type: "string | nil",
      description:
        dpgettext_noop("prompts", "tooltip: what a template anchor path holds", "Those clips as pretty-printed JSON.")
    },
    %{
      path: "anchors.memory.character",
      type: "string | nil",
      description:
        dpgettext_noop(
          "prompts",
          "tooltip: what a template anchor path holds",
          "A character memory copy's target character name(s), comma separated."
        )
    }
  ]

  @doc """
  The block editor's reference list of anchor paths, in display order. `fields` is present only on
  `array<map>` entries.
  """
  @spec catalog() :: [
          %{
            required(:path) => String.t(),
            required(:type) => String.t(),
            required(:description) => String.t(),
            optional(:fields) => [{String.t(), String.t()}]
          }
        ]
  def catalog, do: localize(@catalog)

  @doc """
  The reference list of `anchors.memory` paths, in the same shape as `catalog/0`. Present only while a
  memory-book prompt renders.
  """
  @spec memory_catalog() :: [
          %{
            required(:path) => String.t(),
            required(:type) => String.t(),
            required(:description) => String.t(),
            optional(:fields) => [{String.t(), String.t()}]
          }
        ]
  def memory_catalog, do: localize(@memory_catalog)

  # Descriptions are `dpgettext_noop` msgids (with `bindings` where they take a value), translated here.
  defp localize(entries) do
    Enum.map(entries, fn entry ->
      {bindings, entry} = Map.pop(entry, :bindings, %{})

      description =
        Gettext.dpgettext(
          Mythweaver.Gettext,
          "prompts",
          "tooltip: what a template anchor path holds",
          entry.description,
          bindings
        )

      %{entry | description: description}
    end)
  end

  @doc "`anchors.memory_counts` for a chat without a memory book: every count 0."
  @spec empty_memory_counts() :: %{String.t() => 0}
  def empty_memory_counts, do: @memory_counts_zero

  @doc """
  The `anchors` map for `context`.

  `descriptions` maps a character id to its rendered description; a character absent from it uses its
  raw `description`. A character in `context`'s `:character_tokens` shows the token for each field it
  has, never the text. `"memory"` is set only when `context` carries `:memory`; `"memory_counts"` is
  always set, all zeros when `context` has none.
  """
  @spec data(context() | map(), %{optional(Ecto.UUID.t()) => String.t() | nil}) :: map()
  def data(context, descriptions \\ %{}) do
    chat = Map.get(context, :chat)
    character = Map.get(context, :character)
    player = Map.get(context, :player_character)
    tags = Map.get(context, :tags) || %{characters: %{}, chat: []}
    texts = %{descriptions: descriptions, tokens: Map.get(context, :character_tokens) || %{}}
    names = participant_names(chat)

    %{
      "character" => responder(character, player, texts, tags),
      "player" => tagged_person(player, texts, tags),
      "chat" => chat_data(chat, names, texts, tags),
      "participants" => presence(Enum.join(names, ", ")),
      "other_characters" => presence(other_characters(chat, character, texts)),
      "cards" => chat |> card_characters(character) |> Enum.map(&person(&1, texts)),
      "messages" =>
        for e <-
              Transcript.entries(Map.get(context, :messages, []), character,
                caption_template: Map.get(context, :caption_template)
              ) do
          %{"author" => e.name, "content" => e.content, "role" => to_string(e.role)}
        end,
      "now" => DateTime.to_iso8601(DateTime.utc_now()),
      "guide" => guide_data(Map.get(context, :guide), Map.get(context, :continue)),
      "refine" => refine_data(Map.get(context, :refine)),
      "lore" => %{},
      "memory_counts" => Map.get(context, :memory_counts) || @memory_counts_zero
    }
    |> put_memory(Map.get(context, :memory))
  end

  defp put_memory(data, nil), do: data
  defp put_memory(data, memory), do: Map.put(data, "memory", memory)

  defp guide_data(text, continue) do
    case presence(text) do
      nil -> nil
      text -> %{"text" => text, "continue" => not is_nil(continue)}
    end
  end

  defp refine_data(nil), do: nil
  defp refine_data(%{instructions: instructions, text: text}), do: %{"instructions" => instructions, "text" => text}

  @doc """
  `anchors.character` for `character` as the subject (descriptions not yet rendered): what a
  character's own description sees, whoever replies. `character_tokens` is the context's
  `:character_tokens`.
  """
  @spec character(Character.t(), Character.t() | nil, %{optional(Ecto.UUID.t()) => map()}) :: map()
  def character(%Character{} = character, player, character_tokens),
    do: responder(character, player, %{descriptions: %{}, tokens: character_tokens}, %{characters: %{}, chat: []})

  # The responder can be the player when the AI is asked to speak for them, so templates can tell.
  defp responder(%Character{} = character, player, texts, tags) do
    is_player = is_struct(player, Character) and player.id == character.id
    Map.put(tagged_person(character, texts, tags), "player", is_player)
  end

  defp responder(_character, _player, _texts, _tags), do: nil

  defp chat_data(nil, _names, _texts, _tags),
    do: %{"name" => nil, "participants" => [], "members" => [], "characters" => [], "tags" => []}

  defp chat_data(%Chat{} = chat, names, texts, tags) do
    %{
      "name" => presence(chat.name),
      "participants" => names,
      "tags" => tags.chat,
      "characters" =>
        for(
          p <- chat.participants,
          is_struct(p.character, Character),
          p.character_id != chat.player_character_id,
          do: p.character.name
        ),
      "members" =>
        for p <- chat.participants, is_struct(p.character, Character) do
          Map.merge(tagged_person(p.character, texts, tags), %{
            "muted" => p.muted,
            "player" => p.character_id == chat.player_character_id
          })
        end
    }
  end

  # `person/2` plus the character's expanded tags; cards and other characters stay untagged.
  defp tagged_person(%Character{} = c, texts, tags),
    do: Map.put(person(c, texts), "tags", Map.get(tags.characters, c.id, []))

  defp tagged_person(_, _, _), do: nil

  defp person(%Character{} = c, texts) do
    %{
      "name" => c.name,
      "description" => description(c, texts),
      "pronouns" => presence(c.pronouns),
      "appearance" => shield(c.appearance, c, texts, "appearance")
    }
  end

  defp person(_, _), do: nil

  defp description(%Character{} = c, texts),
    do: texts.descriptions |> Map.get(c.id, c.description) |> shield(c, texts, "description")

  # `text` as templates see it: nil when blank, else the field's token for a protected character.
  defp shield(text, %Character{id: id}, texts, field) do
    case {presence(text), get_in(texts.tokens, [id, field])} do
      {nil, _token_id} -> nil
      {text, nil} -> text
      {_text, token_id} -> Protected.token(token_id)
    end
  end

  # Who appears follows the chat's `group_cards` (`Chat.card_character_ids/2`): the responder alone
  # with swap, also the unmuted with join, everyone with join_all. Never the player, who has
  # `anchors.player`. Participant order.
  defp card_characters(%Chat{} = chat, character) do
    responder_id =
      case character do
        %Character{id: id} -> id
        _ -> nil
      end

    joined = MapSet.new(Chat.card_character_ids(chat, responder_id))

    chat
    |> Chat.characters()
    |> Enum.filter(&(is_struct(&1, Character) and MapSet.member?(joined, &1.id) and &1.id != chat.player_character_id))
  end

  defp card_characters(_chat, _character), do: []

  defp other_characters(chat, character, texts) do
    responder_id = match?(%Character{}, character) && character.id

    chat
    |> card_characters(character)
    |> Enum.reject(&(&1.id == responder_id))
    |> Enum.map_join("\n\n", &character_paragraph(&1, texts))
  end

  defp character_paragraph(%Character{name: name} = character, texts) do
    case description(character, texts) do
      nil -> to_text(name)
      description -> "#{name}: #{description}"
    end
  end

  defp participant_names(nil), do: []

  defp participant_names(chat) do
    chat
    |> Chat.characters()
    |> Enum.filter(&is_struct(&1, Character))
    # `false` sorts before `true`, and `Enum.sort_by/2` is stable, so the player leads and
    # everyone else keeps participant order.
    |> Enum.sort_by(&(&1.id != chat.player_character_id))
    |> Enum.map(&to_text(&1.name))
  end

  defp presence(value) when is_binary(value) do
    if String.trim(value) != "", do: value
  end

  defp presence(_), do: nil

  defp to_text(nil), do: ""
  defp to_text(value) when is_binary(value), do: value
end
