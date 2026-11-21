defmodule Mythweaver.Settings do
  @moduledoc """
  Settings, looked up by key: `get(scope, key)`.

  Every setting is defined in `@categories` below: its label, description, type, default and the
  levels it may be set at. A value cascades default → site → user: the program default, then the
  site's override, then the user's own. Overrides live in the `settings` table
  (`Mythweaver.Settings.Setting`), one jsonb map per level: the site row (`user_id` nil) and at most
  one row per user. A lookup is one query returning those two rows at most; there is no cache.

  Types are `:boolean`, `:integer`, `:select`, `:multi_select`, `:template`, `:css`, `:origins`, `:model`,
  `:side_prompt_set`, `:expression_profile`, `:caption_prompt`, `:language` and `:locale`. An `:origins` is a list of at most 20
  web origins (`https://host[:port]`, or `http` for `localhost`), typed separated by spaces, commas or
  new lines and stored normalized; blank is `nil` (no override). A `:template` is Liquid source of at most 2000 characters, checked by parsing;
  blank is `nil` (the built-in text, stored as no override); its optional `placeholder` is what the
  empty editor shows. A `:css` is CSS source of at most 100000
  characters, stored as typed; blank is `nil`. One carrying `restricted: true` is held to
  `Mythweaver.Stylesheets.restriction/1`: while `appearance.restrict_user_css` is on, it refuses
  sheets that load outside files (`Mythweaver.Stylesheets.Policy`), except font-provider `@import`s
  while `appearance.allow_third_party_fonts` is on. A `:model`
  is a model id, its options the models of its `models` kind read at runtime (only site models at
  the site level), or `nil` ("Automatic", stored as no override). The kinds are `:text` (chat and
  text models), `:caption`, `:embedding` and `:expression` (chat, text and classifier models);
  `accepted_modes/1` maps each to the completion modes it takes. A `:side_prompt_set` is a
  `Mythweaver.Memory.SidePromptSet` id the same way: its options the usable sets (only site sets at
  the site level), or `nil` (none). An `:expression_profile` is a `Mythweaver.Expressions.Profile`
  id the same way, or `nil` (base emotions only). A `:caption_prompt` is a site `:caption`-purpose prompt id the
  same way, or `nil` (the built-in instruction). A `:language` is a Gettext locale id the app has a
  catalog for, its options `Mythweaver.Locale.language_options/0`; a `:locale` is a supported CLDR
  locale id string (`Mythweaver.Locale.id/1`), its options `Mythweaver.Locale.format_options/0`.
  Either is `nil` for no choice: the next source of `Mythweaver.Locale.resolve/2` applies. An `:integer` may
  carry `control: :hue` or `:tint_strength`, shown as a slider that previews `--tint-h` or
  `--tint-strength` on the page.

  A definition's `levels` says who may ever set it: `[:site]` only `"site.settings.manage"` holders
  (for the whole site), `[:site, :user]` users too, for themselves, and `[:user]` only users, for
  themselves. A key appears only at the levels it lists: a `[:site]` key never at the user level, a
  `[:user]` key never at the site level. A `"site.settings.manage"` holder may lock a user-overridable key: users then read the site value, and may
  neither change nor reset theirs. Locking keeps the stored user values and unlocking brings them
  back. `can_edit?/3` is the only access rule; every write goes through it.

  A section may carry a `description`, shown under its heading, and a `grid` that lays its settings
  out as a table rather than one row each: `rows` and `columns` (each `%{id, label}`; a row may have
  a `description`, a column a `control`, `:checkbox` or `:speaker`), and every setting in it names
  its `cell: {row_id, column_id}`. A grid's settings are `:boolean`; a column none of whose settings
  is listed is left out.

  A definition with `requires: :web_push` exists only while Web Push is configured
  (`Mythweaver.Notifications.WebPush.configured?/0`): `entries/2` leaves it out otherwise, and its
  value stays readable through `get/2`.

  Keys are `"<area>.<name>"` strings; finding every caller of a setting is a search for its key. An
  unknown key raises, so a typo fails the first time it runs rather than reading as `nil`. The
  `memory.*` keys are read through `Mythweaver.Memory.preferences/1`.

  A stored value that no longer fits its definition (its type or options changed) is ignored, so the
  next layer down wins; a stored key with no definition is never read.
  """

  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Query

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI.Model
  alias Mythweaver.Changes
  alias Mythweaver.Format
  alias Mythweaver.Memory.Tiers
  alias Mythweaver.Notifications.WebPush
  alias Mythweaver.Repo
  alias Mythweaver.Settings.Setting
  alias Mythweaver.Stylesheets
  alias Mythweaver.Stylesheets.Policy
  alias Mythweaver.Stylesheets.Webfonts

  @tiers for tier <- 1..6, do: {tier, Tiers.name(tier)}
  @minimum_defaults %{1 => 5, 2 => 4, 3 => 4, 4 => 3, 5 => 3, 6 => 3}

  @categories [
    %{
      id: "models",
      label: dpgettext_noop("settings", "settings category: models", "Models"),
      sections: [
        %{
          id: "defaults",
          label: dpgettext_noop("settings", "settings section heading: models.defaults", "Defaults"),
          settings: [
            {"ai.default_model",
             %{
               label: dpgettext_noop("settings", "setting name: ai.default_model", "Default model"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: ai.default_model",
                   "Runs replies and memory jobs when neither the character, the chat nor the memory profile names a model. Automatic uses the only model that can run, and asks for a pick when there are several."
                 ),
               type: :model,
               models: :text,
               default: nil,
               levels: [:site, :user]
             }},
            {"assistant.model",
             %{
               label: dpgettext_noop("settings", "setting name: assistant.model", "Mythweaver model"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: assistant.model",
                   "Runs the Mythweaver assistant chat when the conversation names no model of its own. Automatic uses the default model. It must be a chat-mode model; one that supports tools works best, others use a text fallback."
                 ),
               type: :model,
               models: :text,
               default: nil,
               levels: [:site, :user]
             }}
          ]
        },
        %{
          id: "context",
          label: dpgettext_noop("settings", "settings section heading: models.context", "Context"),
          settings: [
            {"generation.max_context",
             %{
               label: dpgettext_noop("settings", "setting name: generation.max_context", "Max context"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: generation.max_context",
                   "Most tokens a reply's prompt may use, its response tokens included; the oldest chat history is left out to fit. The smaller of this and the model's context window applies. 0 uses the model's context window alone; a model with neither is never trimmed. A model with no response tokens set keeps 1024 free for the reply."
                 ),
               type: :integer,
               default: 0,
               min: 0,
               levels: [:site, :user]
             }},
            {"generation.trim_step",
             %{
               label: dpgettext_noop("settings", "setting name: generation.trim_step", "Trim in steps of"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: generation.trim_step",
                   "When old chat history has to go, it goes this many messages at a time, so the start of the history stays put for several replies. A local model's prompt cache then reuses the unchanged history instead of reading the whole prompt again; the cost is up to this many fewer old messages in the prompt. 1 trims one message at a time."
                 ),
               type: :integer,
               default: 10,
               min: 1,
               max: 100,
               levels: [:site, :user]
             }}
          ]
        },
        %{
          id: "stop_strings",
          label: dpgettext_noop("settings", "settings section heading: models.stop_strings", "Stop strings"),
          settings: [
            {"generation.names_as_stop_strings",
             %{
               label:
                 dpgettext_noop(
                   "settings",
                   "setting name: generation.names_as_stop_strings",
                   "Stop at other speakers' names"
                 ),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: generation.names_as_stop_strings",
                   "End a reply where it starts another participant's line: a line beginning with their name and a colon, such as \"Bob:\". Text-completion models are also sent the names as stop strings."
                 ),
               type: :boolean,
               default: true,
               levels: [:site, :user]
             }},
            {"generation.single_line",
             %{
               label: dpgettext_noop("settings", "setting name: generation.single_line", "Single-line replies"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: generation.single_line",
                   "End every reply at its first line break. Text-completion models are also sent the line break as a stop string."
                 ),
               type: :boolean,
               default: false,
               levels: [:site, :user]
             }}
          ]
        },
        %{
          id: "reply_text",
          label: dpgettext_noop("settings", "settings section heading: models.reply_text", "Reply text"),
          settings: [
            {"generation.trim_own_name",
             %{
               label:
                 dpgettext_noop("settings", "setting name: generation.trim_own_name", "Remove the speaker's own name"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: generation.trim_own_name",
                   "Drop the replying character's name and colon where a reply starts a line with it, such as \"Alice:\" in Alice's reply. Off, replies keep it as written."
                 ),
               type: :boolean,
               default: true,
               levels: [:site, :user]
             }}
          ]
        },
        %{
          id: "swipes",
          label: dpgettext_noop("settings", "settings section heading: models.swipes", "Swipes"),
          settings: [
            {"generation.swipes_per_generation",
             %{
               label: dpgettext_noop("settings", "setting name: generation.swipes_per_generation", "Swipes per reply"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: generation.swipes_per_generation",
                   "How many swipes one reply or regenerate produces. Extra swipes are generated one after another as regenerations of the same message, before anyone else replies, and each is a full request. Continue, refine, script-started regenerations and replies written as your own character always make one."
                 ),
               type: :integer,
               default: 1,
               min: 1,
               max: 8,
               levels: [:site, :user]
             }}
          ]
        },
        %{
          id: "cleanup",
          label: dpgettext_noop("settings", "settings section heading: models.cleanup", "Cleanup"),
          settings: [
            {"cleanup.automatic",
             %{
               label: dpgettext_noop("settings", "setting name: cleanup.automatic", "Automatic cleanup"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: cleanup.automatic",
                   "Clean up a chat's old messages on their own as the chat grows. Off, they're cleaned only when you clean up by hand."
                 ),
               type: :boolean,
               default: true,
               levels: [:site, :user]
             }},
            {"cleanup.after_messages",
             %{
               label:
                 dpgettext_noop("settings", "setting name: cleanup.after_messages", "Clean up messages older than"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: cleanup.after_messages",
                   "Messages further back than this many lose their prompt inspection data, their reasoning text and their inactive swipes' embeddings, and their near-identical swipes are merged."
                 ),
               type: :integer,
               default: 100,
               min: 1,
               levels: [:site, :user]
             }},
            {"cleanup.every_messages",
             %{
               label: dpgettext_noop("settings", "setting name: cleanup.every_messages", "Clean up every"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: cleanup.every_messages",
                   "How many messages a chat gets between automatic cleanups."
                 ),
               type: :integer,
               default: 10,
               min: 1,
               max: 1000,
               levels: [:site, :user]
             }},
            {"cleanup.swipe_similarity",
             %{
               label:
                 dpgettext_noop("settings", "setting name: cleanup.swipe_similarity", "Merge swipes at similarity %"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: cleanup.swipe_similarity",
                   "Two swipes of an old message at least this similar, as the share of their text a word diff finds unchanged, keep only the newer one. The swipe being shown is always kept; a newer near-copy of it goes instead."
                 ),
               type: :integer,
               default: 80,
               min: 50,
               max: 100,
               levels: [:site, :user]
             }}
          ]
        }
      ]
    },
    %{
      id: "lore",
      label: dpgettext_noop("settings", "settings category: lore", "Lore"),
      sections: [
        %{
          id: "matching",
          label: dpgettext_noop("settings", "settings section heading: lore.matching", "Keyword matching"),
          settings: [
            {"lore.scan_depth",
             %{
               label: dpgettext_noop("settings", "setting name: lore.scan_depth", "Scan depth"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: lore.scan_depth",
                   "Recent messages searched for keywords when neither the entry nor its book sets a scan depth."
                 ),
               type: :integer,
               default: 2,
               min: 1,
               levels: [:site, :user]
             }},
            {"lore.case_sensitive",
             %{
               label: dpgettext_noop("settings", "setting name: lore.case_sensitive", "Case-sensitive keywords"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: lore.case_sensitive",
                   "Match keywords case-sensitively when an entry does not say."
                 ),
               type: :boolean,
               default: false,
               levels: [:site, :user]
             }},
            {"lore.match_whole_words",
             %{
               label: dpgettext_noop("settings", "setting name: lore.match_whole_words", "Match whole words"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: lore.match_whole_words",
                   "Keywords match only whole words when an entry does not say."
                 ),
               type: :boolean,
               default: true,
               levels: [:site, :user]
             }},
            {"lore.word_boundary",
             %{
               label: dpgettext_noop("settings", "setting name: lore.word_boundary", "Word boundary"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: lore.word_boundary",
                   "What ends a word for whole-word matching. ASCII treats every non-ASCII character as a separator, as SillyTavern does, so Japanese or Chinese keys match inside sentences."
                 ),
               type: :select,
               default: :ascii,
               options: [
                 {:ascii, dpgettext_noop("settings", "setting option: lore.word_boundary", "ASCII (SillyTavern)")},
                 {:unicode, dpgettext_noop("settings", "setting option: lore.word_boundary", "Unicode")}
               ],
               levels: [:site, :user]
             }}
          ]
        },
        %{
          id: "limits",
          label: dpgettext_noop("settings", "settings section heading: lore.limits", "Activation limits"),
          settings: [
            {"lore.max_recursion_steps",
             %{
               label: dpgettext_noop("settings", "setting name: lore.max_recursion_steps", "Activation passes"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: lore.max_recursion_steps",
                   "Most activation passes per reply, the first included; entries activated in one pass can trigger more in the next. 0 = no limit: passes continue until one activates nothing (SillyTavern's default)."
                 ),
               type: :integer,
               default: 0,
               min: 0,
               max: 10,
               levels: [:site, :user]
             }},
            {"lore.token_budget_percent",
             %{
               label:
                 dpgettext_noop("settings", "setting name: lore.token_budget_percent", "Lore budget (% of context)"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: lore.token_budget_percent",
                   "Share of the reply's context limit (the smaller of the model's context window and Max context) lore may use, as in SillyTavern."
                 ),
               type: :integer,
               default: 25,
               min: 1,
               max: 100,
               levels: [:site, :user]
             }},
            {"lore.token_budget",
             %{
               label: dpgettext_noop("settings", "setting name: lore.token_budget", "Lore budget cap"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: lore.token_budget",
                   "Most tokens of lore in one prompt, whatever the percentage gives. 0 = no cap. When the context limit is unknown, this cap applies, or 15,000 tokens when it is 0."
                 ),
               type: :integer,
               default: 0,
               min: 0,
               levels: [:site, :user]
             }},
            {"lore.overflow",
             %{
               label: dpgettext_noop("settings", "setting name: lore.overflow", "After the budget overflows"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: lore.overflow",
                   "Stop admits nothing more once one entry doesn't fit, except ignore-budget entries (SillyTavern). Fill keeps trying smaller entries."
                 ),
               type: :select,
               default: :stop,
               options: [
                 {:stop, dpgettext_noop("settings", "setting option: lore.overflow", "Stop (SillyTavern)")},
                 {:fill, dpgettext_noop("settings", "setting option: lore.overflow", "Keep filling")}
               ],
               levels: [:site, :user]
             }}
          ]
        },
        %{
          id: "placement",
          label: dpgettext_noop("settings", "settings section heading: lore.placement", "Placement"),
          settings: [
            {"lore.default_depth",
             %{
               label: dpgettext_noop("settings", "setting name: lore.default_depth", "Default insertion depth"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: lore.default_depth",
                   "How many messages from the end an at-depth entry goes when it names no depth."
                 ),
               type: :integer,
               default: 4,
               min: 0,
               levels: [:site, :user]
             }}
          ]
        },
        %{
          id: "vector",
          label: dpgettext_noop("settings", "settings section heading: lore.vector", "Vector matching"),
          settings: [
            {"lore.embedding_model",
             %{
               label: dpgettext_noop("settings", "setting name: lore.embedding_model", "Embedding model"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: lore.embedding_model",
                   "Turns Vector lore entries and recent messages into embeddings, so those entries activate on similar meaning. None leaves Vector entries to their keywords."
                 ),
               type: :model,
               models: :embedding,
               default: nil,
               levels: [:site, :user]
             }},
            {"lore.vector_threshold",
             %{
               label: dpgettext_noop("settings", "setting name: lore.vector_threshold", "Minimum similarity %"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: lore.vector_threshold",
                   "How similar, in percent, the scanned messages must be to a Vector entry for it to activate."
                 ),
               type: :integer,
               default: 25,
               min: 0,
               max: 100,
               levels: [:site, :user]
             }},
            {"lore.vector_max_entries",
             %{
               label: dpgettext_noop("settings", "setting name: lore.vector_max_entries", "Most vector activations"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: lore.vector_max_entries",
                   "Most Vector entries activated by similarity per reply, most similar first. Entries their keywords activate don't count."
                 ),
               type: :integer,
               default: 5,
               min: 1,
               max: 50,
               levels: [:site, :user]
             }}
          ]
        }
      ]
    },
    %{
      id: "memory",
      label: dpgettext_noop("settings", "settings category: memory", "Memory"),
      sections: [
        %{
          id: "memories",
          label: dpgettext_noop("settings", "settings section heading: memory.memories", "Memories"),
          settings: [
            {"memory.show_previews",
             %{
               label: dpgettext_noop("settings", "setting name: memory.show_previews", "Review memories before saving"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: memory.show_previews",
                   "Show a generated memory for review before it is saved to the memory book."
                 ),
               type: :boolean,
               default: true,
               levels: [:site, :user]
             }},
            {"memory.show_consolidation_previews",
             %{
               label:
                 dpgettext_noop(
                   "settings",
                   "setting name: memory.show_consolidation_previews",
                   "Review consolidations before saving"
                 ),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: memory.show_consolidation_previews",
                   "Show a consolidated memory for review before it replaces its sources."
                 ),
               type: :boolean,
               default: true,
               levels: [:site, :user]
             }},
            {"memory.token_warning_threshold",
             %{
               label:
                 dpgettext_noop("settings", "setting name: memory.token_warning_threshold", "Token warning threshold"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: memory.token_warning_threshold",
                   "Ask before sending a memory request estimated at more than this many tokens: the prompt, earlier memories, additional context and the scene together."
                 ),
               type: :integer,
               default: 30_000,
               min: 1000,
               max: 1_000_000,
               levels: [:site, :user]
             }},
            {"memory.default_previous_count",
             %{
               label:
                 dpgettext_noop(
                   "settings",
                   "setting name: memory.default_previous_count",
                   "Previous memories sent by default"
                 ),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: memory.default_previous_count",
                   "How many earlier memories accompany a scene when a new memory is written."
                 ),
               type: :integer,
               default: 1,
               min: 0,
               max: 7,
               levels: [:site, :user]
             }},
            {"memory.allow_overlap",
             %{
               label: dpgettext_noop("settings", "setting name: memory.allow_overlap", "Allow overlapping scenes"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: memory.allow_overlap",
                   "Let a new scene include messages an earlier memory already covers."
                 ),
               type: :boolean,
               default: false,
               levels: [:site, :user]
             }},
            {"memory.include_hidden",
             %{
               label:
                 dpgettext_noop(
                   "settings",
                   "setting name: memory.include_hidden",
                   "Include messages hidden from the AI"
                 ),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: memory.include_hidden",
                   "Send messages hidden from the AI when writing a memory of their scene."
                 ),
               type: :boolean,
               default: false,
               levels: [:site, :user]
             }},
            {"memory.boundary_indicator",
             %{
               label: dpgettext_noop("settings", "setting name: memory.boundary_indicator", "Processed boundary"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: memory.boundary_indicator",
                   "Mark the last message already covered by a memory in the chat."
                 ),
               type: :select,
               default: :divider,
               options: [
                 {:divider, dpgettext_noop("settings", "setting option: memory.boundary_indicator", "Divider")},
                 {:off, dpgettext_noop("settings", "setting option: memory.boundary_indicator", "Off")}
               ],
               levels: [:site, :user]
             }}
          ]
        },
        %{
          id: "automatic",
          label: dpgettext_noop("settings", "settings section heading: memory.automatic", "Automatic memories"),
          settings: [
            {"memory.auto_trigger",
             %{
               label: dpgettext_noop("settings", "setting name: memory.auto_trigger", "Trigger"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: memory.auto_trigger",
                   "What starts an automatic memory in a chat that has them on: a count of new messages, or the new messages reaching a token threshold. A chat may set its own."
                 ),
               type: :select,
               default: :messages,
               options: [
                 {:messages, dpgettext_noop("settings", "setting option: memory.auto_trigger", "Every N messages")},
                 {:tokens, dpgettext_noop("settings", "setting option: memory.auto_trigger", "Token threshold")}
               ],
               levels: [:site, :user]
             }},
            {"memory.auto_interval",
             %{
               label: dpgettext_noop("settings", "setting name: memory.auto_interval", "Interval"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: memory.auto_interval",
                   "With the message trigger: how many new messages past the processed boundary, not counting the buffer, make a memory. A chat may set its own."
                 ),
               type: :integer,
               default: 30,
               min: 5,
               max: 250,
               levels: [:site, :user]
             }},
            {"memory.auto_buffer",
             %{
               label: dpgettext_noop("settings", "setting name: memory.auto_buffer", "Buffer"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: memory.auto_buffer",
                   "How many of the newest messages an automatic memory leaves out of its scene, so the latest exchange can still change. A chat may set its own."
                 ),
               type: :integer,
               default: 2,
               min: 0,
               max: 50,
               levels: [:site, :user]
             }},
            {"memory.auto_token_threshold",
             %{
               label: dpgettext_noop("settings", "setting name: memory.auto_token_threshold", "Token threshold"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: memory.auto_token_threshold",
                   "With the token trigger: how many tokens of new messages past the processed boundary, not counting the buffer, make a memory. A chat may set its own."
                 ),
               type: :integer,
               default: 8000,
               min: 1,
               levels: [:site, :user]
             }}
          ]
        },
        %{
          id: "reminders",
          label: dpgettext_noop("settings", "settings section heading: memory.reminders", "Reminders"),
          settings: [
            {"memory.manual_reminders",
             %{
               label: dpgettext_noop("settings", "setting name: memory.manual_reminders", "Manual reminders"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: memory.manual_reminders",
                   "Remind me to make memories when automatic memories are off."
                 ),
               type: :boolean,
               default: false,
               levels: [:site, :user]
             }},
            {"memory.manual_reminder_interval",
             %{
               label:
                 dpgettext_noop("settings", "setting name: memory.manual_reminder_interval", "Manual reminder interval"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: memory.manual_reminder_interval",
                   "Unprocessed messages before the first reminder, and between reminders."
                 ),
               type: :integer,
               default: 50,
               min: 1,
               levels: [:site, :user]
             }},
            {"memory.auto_reminders",
             %{
               label: dpgettext_noop("settings", "setting name: memory.auto_reminders", "Automatic reminders"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: memory.auto_reminders",
                   "Remind me when automatic memories fall behind."
                 ),
               type: :boolean,
               default: false,
               levels: [:site, :user]
             }},
            {"memory.auto_reminder_interval",
             %{
               label:
                 dpgettext_noop(
                   "settings",
                   "setting name: memory.auto_reminder_interval",
                   "Automatic reminder interval"
                 ),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: memory.auto_reminder_interval",
                   "Messages past the automatic interval and buffer before the first reminder, and between reminders."
                 ),
               type: :integer,
               default: 10,
               min: 1,
               levels: [:site, :user]
             }}
          ]
        },
        %{
          id: "consolidation",
          label: dpgettext_noop("settings", "settings section heading: memory.consolidation", "Consolidation"),
          settings:
            [
              {"memory.consolidation_watch_tiers",
               %{
                 label:
                   dpgettext_noop("settings", "setting name: memory.consolidation_watch_tiers", "Announce when ready"),
                 description:
                   dpgettext_noop(
                     "settings",
                     "setting description: memory.consolidation_watch_tiers",
                     "Tiers whose readiness to consolidate is announced in the chat, in a notice linking to the Consolidate tab, once a tier has its minimum of eligible entries."
                   ),
                 type: :multi_select,
                 default: Enum.map(@tiers, &elem(&1, 0)),
                 options: @tiers,
                 levels: [:site, :user]
               }}
            ] ++
              for {tier, label, description} <- [
                    {1, dpgettext_noop("settings", "setting name: memory.consolidation_minimum_1", "Arc minimum"),
                     dpgettext_noop(
                       "settings",
                       "setting description: memory.consolidation_minimum_1",
                       "How many eligible entries make the arc tier ready to consolidate."
                     )},
                    {2, dpgettext_noop("settings", "setting name: memory.consolidation_minimum_2", "Chapter minimum"),
                     dpgettext_noop(
                       "settings",
                       "setting description: memory.consolidation_minimum_2",
                       "How many eligible entries make the chapter tier ready to consolidate."
                     )},
                    {3, dpgettext_noop("settings", "setting name: memory.consolidation_minimum_3", "Book minimum"),
                     dpgettext_noop(
                       "settings",
                       "setting description: memory.consolidation_minimum_3",
                       "How many eligible entries make the book tier ready to consolidate."
                     )},
                    {4, dpgettext_noop("settings", "setting name: memory.consolidation_minimum_4", "Legend minimum"),
                     dpgettext_noop(
                       "settings",
                       "setting description: memory.consolidation_minimum_4",
                       "How many eligible entries make the legend tier ready to consolidate."
                     )},
                    {5, dpgettext_noop("settings", "setting name: memory.consolidation_minimum_5", "Series minimum"),
                     dpgettext_noop(
                       "settings",
                       "setting description: memory.consolidation_minimum_5",
                       "How many eligible entries make the series tier ready to consolidate."
                     )},
                    {6, dpgettext_noop("settings", "setting name: memory.consolidation_minimum_6", "Epic minimum"),
                     dpgettext_noop(
                       "settings",
                       "setting description: memory.consolidation_minimum_6",
                       "How many eligible entries make the epic tier ready to consolidate."
                     )}
                  ] do
                {"memory.consolidation_minimum_#{tier}",
                 %{
                   label: label,
                   description: description,
                   type: :integer,
                   default: Map.fetch!(@minimum_defaults, tier),
                   min: 1,
                   levels: [:site, :user]
                 }}
              end ++
              [
                {"memory.consolidation_max_entries",
                 %{
                   label:
                     dpgettext_noop(
                       "settings",
                       "setting name: memory.consolidation_max_entries",
                       "Max entries per pass"
                     ),
                   description:
                     dpgettext_noop(
                       "settings",
                       "setting description: memory.consolidation_max_entries",
                       "Most entries one consolidation pass reads; more are split into further passes."
                     ),
                   type: :integer,
                   default: 20,
                   min: 1,
                   levels: [:site, :user]
                 }},
                {"memory.consolidation_token_budget",
                 %{
                   label:
                     dpgettext_noop(
                       "settings",
                       "setting name: memory.consolidation_token_budget",
                       "Token budget per pass"
                     ),
                   description:
                     dpgettext_noop(
                       "settings",
                       "setting description: memory.consolidation_token_budget",
                       "Most tokens of entries one consolidation pass reads; more are split into further passes."
                     ),
                   type: :integer,
                   default: 12_000,
                   min: 1,
                   levels: [:site, :user]
                 }}
              ]
        },
        %{
          id: "rollback",
          label:
            dpgettext_noop("settings", "settings section heading: memory.rollback", "Rollback on message deletion"),
          settings: [
            {"memory.rollback_enabled",
             %{
               label:
                 dpgettext_noop(
                   "settings",
                   "setting name: memory.rollback_enabled",
                   "Roll back memories when a message is deleted"
                 ),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: memory.rollback_enabled",
                   "Deleting a message a memory covers undoes that memory's effects."
                 ),
               type: :boolean,
               default: false,
               levels: [:site, :user]
             }},
            {"memory.rollback_scope",
             %{
               label: dpgettext_noop("settings", "setting name: memory.rollback_scope", "Scope"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: memory.rollback_scope",
                   "Which memories a deleted message rolls back."
                 ),
               type: :select,
               default: :affected,
               options: [
                 {:affected,
                  dpgettext_noop("settings", "setting option: memory.rollback_scope", "Memories covering the message")},
                 {:full, dpgettext_noop("settings", "setting option: memory.rollback_scope", "Every later memory")}
               ],
               levels: [:site, :user]
             }},
            {"memory.rollback_update_boundary",
             %{
               label:
                 dpgettext_noop("settings", "setting name: memory.rollback_update_boundary", "Move the boundary back"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: memory.rollback_update_boundary",
                   "Move the processed boundary back to before the deleted message."
                 ),
               type: :boolean,
               default: true,
               levels: [:site, :user]
             }},
            {"memory.rollback_delete_memories",
             %{
               label:
                 dpgettext_noop("settings", "setting name: memory.rollback_delete_memories", "Delete affected memories"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: memory.rollback_delete_memories",
                   "Delete the memories the rollback covers from the memory book."
                 ),
               type: :boolean,
               default: true,
               levels: [:site, :user]
             }},
            {"memory.rollback_restore_side_prompts",
             %{
               label:
                 dpgettext_noop(
                   "settings",
                   "setting name: memory.rollback_restore_side_prompts",
                   "Restore side-prompt entries"
                 ),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: memory.rollback_restore_side_prompts",
                   "Restore side-prompt entries to the versions before the rolled-back memories."
                 ),
               type: :boolean,
               default: true,
               levels: [:site, :user]
             }}
          ]
        },
        %{
          id: "side_prompts",
          label: dpgettext_noop("settings", "settings section heading: memory.side_prompts", "Side prompts"),
          settings: [
            {"memory.side_prompt_versioning",
             %{
               label:
                 dpgettext_noop("settings", "setting name: memory.side_prompt_versioning", "Keep side-prompt versions"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: memory.side_prompt_versioning",
                   "Keep each earlier version of a side-prompt entry when it is rewritten."
                 ),
               type: :boolean,
               default: false,
               levels: [:site, :user]
             }},
            {"memory.side_prompt_set_solo",
             %{
               label:
                 dpgettext_noop(
                   "settings",
                   "setting name: memory.side_prompt_set_solo",
                   "Default side prompt set (solo chats)"
                 ),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: memory.side_prompt_set_solo",
                   "Chats left on Default run this set's rows after memories and on intervals instead of individually enabled side prompts. None runs the enabled side prompts."
                 ),
               type: :side_prompt_set,
               default: nil,
               levels: [:site, :user]
             }},
            {"memory.side_prompt_set_group",
             %{
               label:
                 dpgettext_noop(
                   "settings",
                   "setting name: memory.side_prompt_set_group",
                   "Default side prompt set (group chats)"
                 ),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: memory.side_prompt_set_group",
                   "Chats left on Default run this set's rows after memories and on intervals instead of individually enabled side prompts. None runs the enabled side prompts."
                 ),
               type: :side_prompt_set,
               default: nil,
               levels: [:site, :user]
             }}
          ]
        },
        %{
          id: "assistance",
          label: dpgettext_noop("settings", "settings section heading: memory.assistance", "Memory assistance"),
          settings: [
            {"memory.assistance_mode",
             %{
               label: dpgettext_noop("settings", "setting name: memory.assistance_mode", "Memory assistance"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: memory.assistance_mode",
                   "After each new memory, review the book's clips against the scene. Updates wait in Reviews; Automatic adds clip lines itself and leaves topical clip rewrites for review."
                 ),
               type: :select,
               default: :off,
               options: [
                 {:off, dpgettext_noop("settings", "setting option: memory.assistance_mode", "Off")},
                 {:update,
                  dpgettext_noop("settings", "setting option: memory.assistance_mode", "Suggest clip updates")},
                 {:suggest, dpgettext_noop("settings", "setting option: memory.assistance_mode", "Suggest new topics")},
                 {:update_and_suggest,
                  dpgettext_noop("settings", "setting option: memory.assistance_mode", "Suggest updates and new topics")},
                 {:automatic,
                  dpgettext_noop(
                    "settings",
                    "setting option: memory.assistance_mode",
                    "Apply clip additions automatically"
                  )}
               ],
               levels: [:site, :user]
             }}
          ]
        }
      ]
    },
    %{
      id: "images",
      label: dpgettext_noop("settings", "settings category: images", "Images"),
      sections: [
        %{
          id: "captions",
          label: dpgettext_noop("settings", "settings section heading: images.captions", "Image descriptions"),
          settings: [
            {"images.review_captions",
             %{
               label:
                 dpgettext_noop(
                   "settings",
                   "setting name: images.review_captions",
                   "Review image descriptions before sending"
                 ),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: images.review_captions",
                   "Describe images as they are attached and hold Send until each description is ready to check and edit. Off, images are described in the background after sending."
                 ),
               type: :boolean,
               default: true,
               levels: [:site, :user]
             }},
            {"images.default_caption_model",
             %{
               label: dpgettext_noop("settings", "setting name: images.default_caption_model", "Default caption model"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: images.default_caption_model",
                   "Describes avatars, and AI-generated images in chats where no participant has a caption model. Automatic picks the first caption-capable site model by name."
                 ),
               type: :model,
               models: :caption,
               default: nil,
               levels: [:site]
             }},
            {"images.auto_caption",
             %{
               label: dpgettext_noop("settings", "setting name: images.auto_caption", "Describe images automatically"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: images.auto_caption",
                   "Describe chat images, audio and video as they are attached, sent or needed for a reply, older attachments past a model's inline limits, and new avatars. Off, an attachment is described only when someone asks (Describe, Ask…, Describe all attachments, a script)."
                 ),
               type: :boolean,
               default: true,
               levels: [:site, :user]
             }},
            {"images.ask_every_time",
             %{
               label: dpgettext_noop("settings", "setting name: images.ask_every_time", "Ask every time"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: images.ask_every_time",
                   "Before each description someone starts, or that starts as an image is attached or sent, ask for a question to send instead of the caption prompt. Leave it blank for the usual description. Descriptions made in the background use the caption prompt."
                 ),
               type: :boolean,
               default: false,
               levels: [:site, :user]
             }},
            {"images.review_results",
             %{
               label:
                 dpgettext_noop("settings", "setting name: images.review_results", "Review captions before saving"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: images.review_results",
                   "Hold each finished description of a sent attachment until it is saved, edited or discarded. A reply waiting on one keeps waiting until it is resolved or the reply is stopped."
                 ),
               type: :boolean,
               default: false,
               levels: [:site, :user]
             }}
          ]
        },
        %{
          id: "avatars",
          label: dpgettext_noop("settings", "settings section heading: images.avatars", "Avatars"),
          settings: [
            {"images.avatar_updates_appearance",
             %{
               label:
                 dpgettext_noop(
                   "settings",
                   "setting name: images.avatar_updates_appearance",
                   "Update Appearance when the avatar changes"
                 ),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: images.avatar_updates_appearance",
                   "Write a new avatar's description into the character's Appearance. In the character editor it fills the field before you save, and Revert puts back what was there; elsewhere (scripts, imports) an Appearance someone wrote is kept. Off, new avatars are not described automatically (Describe avatar still works). Each character can override this."
                 ),
               type: :boolean,
               default: true,
               levels: [:site, :user]
             }},
            {"images.avatar_caption_prompt",
             %{
               label: dpgettext_noop("settings", "setting name: images.avatar_caption_prompt", "Avatar caption prompt"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: images.avatar_caption_prompt",
                   "The prompt the default caption model gets to describe an avatar, in place of its own caption prompt: an avatar has no chat, so a prompt written for chat images would describe a scene that isn't there. Built-in instruction sends the plain describing instruction."
                 ),
               type: :caption_prompt,
               default: nil,
               levels: [:site]
             }}
          ]
        },
        %{
          id: "text",
          label: dpgettext_noop("settings", "settings section heading: images.text", "Image text"),
          settings: [
            {"images.caption_template",
             %{
               label: dpgettext_noop("settings", "setting name: images.caption_template", "Image text"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: images.caption_template",
                   "What a model that can't see an image reads in its place, and what lore and memory read. Liquid, with caption (nil until described), user (who sent it) and char (who is replying). Empty uses the default, [Image: caption] or [Image]."
                 ),
               type: :template,
               placeholder: "{% if caption %}[Image: {{ caption }}]{% else %}[Image]{% endif %}",
               default: nil,
               levels: [:site, :user]
             }}
          ]
        }
      ]
    },
    %{
      id: "expressions",
      label: dpgettext_noop("settings", "settings category: expressions", "Expressions"),
      sections: [
        %{
          id: "classification",
          label: dpgettext_noop("settings", "settings section heading: expressions.classification", "Classification"),
          settings: [
            {"expressions.classifier_model",
             %{
               label: dpgettext_noop("settings", "setting name: expressions.classifier_model", "Classifier model"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: expressions.classifier_model",
                   "Rates the emotions of each reply and each message you send, for characters that have expression sprites, and shows the matching sprite in place of their portrait. None turns expressions off. A chat or text model is asked once per message and the call shows in Jobs; a classifier model (a GoEmotions sequence classifier served by llama-server) scores it directly in a few milliseconds and rates only the 28 base emotions."
                 ),
               type: :model,
               models: :expression,
               default: nil,
               levels: [:site, :user]
             }},
            {"expressions.classifier_prompt",
             %{
               label:
                 dpgettext_noop("settings", "setting name: expressions.classifier_prompt", "Classifier instruction"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: expressions.classifier_prompt",
                   "What the classifier model is told before the message. Liquid, with labels (the emotions to rate, comma separated) and char (the character's name). It must ask for {\"scores\": {emotion: 0-100}}. Empty uses the built-in instruction."
                 ),
               type: :template,
               placeholder:
                 "Rate how strongly the message below expresses each of these emotions, from 0 to 100: {{ labels }}. …",
               default: nil,
               levels: [:site, :user]
             }},
            {"expressions.structured_output",
             %{
               label:
                 dpgettext_noop("settings", "setting name: expressions.structured_output", "Ask for structured output"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: expressions.structured_output",
                   "Send a JSON schema with each request, for backends that support response_format."
                 ),
               type: :boolean,
               default: false,
               levels: [:site, :user]
             }}
          ]
        },
        %{
          id: "sprites",
          label: dpgettext_noop("settings", "settings section heading: expressions.sprites", "Sprites"),
          settings: [
            {"expressions.default_profile",
             %{
               label: dpgettext_noop("settings", "setting name: expressions.default_profile", "Default rule profile"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: expressions.default_profile",
                   "The combination and range rules for characters that don't pick their own profile. None uses the base emotions only."
                 ),
               type: :expression_profile,
               default: nil,
               levels: [:site, :user]
             }},
            {"expressions.reroll_if_same",
             %{
               label:
                 dpgettext_noop("settings", "setting name: expressions.reroll_if_same", "Avoid repeating a sprite"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: expressions.reroll_if_same",
                   "When an expression has several sprites, don't show the one the character's previous message used."
                 ),
               type: :boolean,
               default: true,
               levels: [:site, :user]
             }}
          ]
        }
      ]
    },
    %{
      id: "notifications",
      label: dpgettext_noop("settings", "settings category: notifications", "Notifications"),
      sections: [
        %{
          id: "general",
          label: dpgettext_noop("settings", "settings section heading: notifications.general", "General"),
          settings: [
            {"notifications.muted",
             %{
               label: dpgettext_noop("settings", "setting name: notifications.muted", "Mute all notifications"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: notifications.muted",
                   "Silence every notification below: no popups and no sounds. Each kind keeps its own settings for when you unmute. The notifications inbox still lists them."
                 ),
               type: :boolean,
               default: false,
               levels: [:site, :user]
             }},
            {"notifications.push_preview",
             %{
               label:
                 dpgettext_noop(
                   "settings",
                   "setting name: notifications.push_preview",
                   "Show message text in push notifications"
                 ),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: notifications.push_preview",
                   "Off, a push notification names the chat and character but not what they wrote, for a lock screen others can see."
                 ),
               type: :boolean,
               default: true,
               levels: [:site, :user],
               requires: :web_push
             }}
          ]
        },
        %{
          id: "events",
          label: dpgettext_noop("settings", "settings section heading: notifications.events", "Events"),
          description:
            dpgettext_noop(
              "settings",
              "settings section description: notifications.events",
              "Notification: a browser notification, unless you are looking at that chat; the browser asks for permission the first time you click in the app. Sound: a sound for each kind, even while you watch."
            ),
          grid: %{
            columns: [
              %{
                id: :popup,
                label: dpgettext_noop("settings", "settings grid column: notifications.events.popup", "Notification"),
                control: :checkbox
              },
              %{
                id: :sound,
                label: dpgettext_noop("settings", "settings grid column: notifications.events.sound", "Sound"),
                control: :speaker
              },
              %{
                id: :push,
                label: dpgettext_noop("settings", "settings grid column: notifications.events.push", "Push"),
                control: :checkbox
              }
            ],
            rows: [
              %{
                id: :new_message,
                label:
                  dpgettext_noop("settings", "settings grid row: notifications.events.new_message", "New messages"),
                description:
                  dpgettext_noop(
                    "settings",
                    "settings grid row description: notifications.events.new_message",
                    "A character's new reply finishes."
                  )
              },
              %{
                id: :regenerate,
                label:
                  dpgettext_noop("settings", "settings grid row: notifications.events.regenerate", "Regenerations"),
                description:
                  dpgettext_noop(
                    "settings",
                    "settings grid row description: notifications.events.regenerate",
                    "A regenerated swipe or a rewrite finishes. Several swipes from one request notify once, after the last."
                  )
              },
              %{
                id: :continue,
                label: dpgettext_noop("settings", "settings grid row: notifications.events.continue", "Continues"),
                description:
                  dpgettext_noop(
                    "settings",
                    "settings grid row description: notifications.events.continue",
                    "A continued message finishes."
                  )
              },
              %{
                id: :memory_review,
                label:
                  dpgettext_noop("settings", "settings grid row: notifications.events.memory_review", "Memory reviews"),
                description:
                  dpgettext_noop(
                    "settings",
                    "settings grid row description: notifications.events.memory_review",
                    "A memory draft is waiting for your review in the chat's Memory → Reviews."
                  )
              }
            ]
          },
          settings: [
            {"notifications.new_message.popup",
             %{
               label:
                 dpgettext_noop("settings", "setting name: notifications.new_message.popup", "Notify for new messages"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: notifications.new_message.popup",
                   "A browser notification when a character's new reply finishes."
                 ),
               cell: {:new_message, :popup},
               type: :boolean,
               default: true,
               levels: [:site, :user]
             }},
            {"notifications.new_message.push",
             %{
               label:
                 dpgettext_noop("settings", "setting name: notifications.new_message.push", "Push for new messages"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: notifications.new_message.push",
                   "A push notification when a character's new reply finishes."
                 ),
               cell: {:new_message, :push},
               type: :boolean,
               default: true,
               levels: [:site, :user],
               requires: :web_push
             }},
            {"notifications.new_message.sound",
             %{
               label:
                 dpgettext_noop("settings", "setting name: notifications.new_message.sound", "Sound for new messages"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: notifications.new_message.sound",
                   "A sound when a character's new reply finishes."
                 ),
               cell: {:new_message, :sound},
               type: :boolean,
               default: true,
               levels: [:site, :user]
             }},
            {"notifications.regenerate.popup",
             %{
               label:
                 dpgettext_noop("settings", "setting name: notifications.regenerate.popup", "Notify for regenerations"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: notifications.regenerate.popup",
                   "A browser notification when a regenerated swipe or a rewrite finishes."
                 ),
               cell: {:regenerate, :popup},
               type: :boolean,
               default: true,
               levels: [:site, :user]
             }},
            {"notifications.regenerate.push",
             %{
               label:
                 dpgettext_noop("settings", "setting name: notifications.regenerate.push", "Push for regenerations"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: notifications.regenerate.push",
                   "A push notification when a regenerated swipe or a rewrite finishes."
                 ),
               cell: {:regenerate, :push},
               type: :boolean,
               default: true,
               levels: [:site, :user],
               requires: :web_push
             }},
            {"notifications.regenerate.sound",
             %{
               label:
                 dpgettext_noop("settings", "setting name: notifications.regenerate.sound", "Sound for regenerations"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: notifications.regenerate.sound",
                   "A sound when a regenerated swipe or a rewrite finishes."
                 ),
               cell: {:regenerate, :sound},
               type: :boolean,
               default: true,
               levels: [:site, :user]
             }},
            {"notifications.continue.popup",
             %{
               label: dpgettext_noop("settings", "setting name: notifications.continue.popup", "Notify for continues"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: notifications.continue.popup",
                   "A browser notification when a continued message finishes."
                 ),
               cell: {:continue, :popup},
               type: :boolean,
               default: true,
               levels: [:site, :user]
             }},
            {"notifications.continue.push",
             %{
               label: dpgettext_noop("settings", "setting name: notifications.continue.push", "Push for continues"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: notifications.continue.push",
                   "A push notification when a continued message finishes."
                 ),
               cell: {:continue, :push},
               type: :boolean,
               default: true,
               levels: [:site, :user],
               requires: :web_push
             }},
            {"notifications.continue.sound",
             %{
               label: dpgettext_noop("settings", "setting name: notifications.continue.sound", "Sound for continues"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: notifications.continue.sound",
                   "A sound when a continued message finishes."
                 ),
               cell: {:continue, :sound},
               type: :boolean,
               default: true,
               levels: [:site, :user]
             }},
            {"notifications.memory_review.popup",
             %{
               label:
                 dpgettext_noop(
                   "settings",
                   "setting name: notifications.memory_review.popup",
                   "Notify for memory reviews"
                 ),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: notifications.memory_review.popup",
                   "A browser notification when a memory draft is waiting for your review."
                 ),
               cell: {:memory_review, :popup},
               type: :boolean,
               default: true,
               levels: [:site, :user]
             }},
            {"notifications.memory_review.push",
             %{
               label:
                 dpgettext_noop("settings", "setting name: notifications.memory_review.push", "Push for memory reviews"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: notifications.memory_review.push",
                   "A push notification when a memory draft is waiting for your review."
                 ),
               cell: {:memory_review, :push},
               type: :boolean,
               default: true,
               levels: [:site, :user],
               requires: :web_push
             }},
            {"notifications.memory_review.sound",
             %{
               label:
                 dpgettext_noop(
                   "settings",
                   "setting name: notifications.memory_review.sound",
                   "Sound for memory reviews"
                 ),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: notifications.memory_review.sound",
                   "A sound when a memory draft is waiting for your review."
                 ),
               cell: {:memory_review, :sound},
               type: :boolean,
               default: true,
               levels: [:site, :user]
             }}
          ]
        }
      ]
    },
    %{
      id: "appearance",
      label: dpgettext_noop("settings", "settings category: appearance", "Appearance"),
      sections: [
        %{
          id: "language",
          label: dpgettext_noop("settings", "settings section heading: appearance.language", "Language and region"),
          settings: [
            {"appearance.language",
             %{
               label: dpgettext_noop("settings", "setting name: appearance.language", "Language"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: appearance.language",
                   "The language of the app's text. Only languages the app has a translation for are listed; Match my browser uses your browser's preferred one of them."
                 ),
               type: :language,
               default: nil,
               levels: [:user]
             }},
            {"appearance.locale",
             %{
               label: dpgettext_noop("settings", "setting name: appearance.locale", "Regional format"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: appearance.locale",
                   "How numbers, dates, times and money are written, whatever the language. Match my browser uses your browser's preferred region."
                 ),
               type: :locale,
               default: nil,
               levels: [:user]
             }},
            {"appearance.default_language",
             %{
               label: dpgettext_noop("settings", "setting name: appearance.default_language", "Default language"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: appearance.default_language",
                   "The language of the app's text for anyone whose browser asks for none the app has a translation for, and in notifications to people who have not chosen one."
                 ),
               type: :language,
               default: nil,
               levels: [:site]
             }},
            {"appearance.default_locale",
             %{
               label: dpgettext_noop("settings", "setting name: appearance.default_locale", "Default regional format"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: appearance.default_locale",
                   "How numbers, dates and money are written for anyone whose browser asks for no supported region, and in notifications to people who have not chosen one."
                 ),
               type: :locale,
               default: nil,
               levels: [:site]
             }}
          ]
        },
        %{
          id: "theme",
          label: dpgettext_noop("settings", "settings section heading: appearance.theme", "Theme"),
          settings: [
            {"appearance.primary_hue",
             %{
               label: dpgettext_noop("settings", "setting name: appearance.primary_hue", "Primary hue"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: appearance.primary_hue",
                   "The hue every color in the app is tinted with, from 0 to 359 degrees around the color wheel."
                 ),
               type: :integer,
               control: :hue,
               default: 263,
               min: 0,
               max: 359,
               levels: [:site, :user]
             }},
            {"appearance.tint_strength",
             %{
               label: dpgettext_noop("settings", "setting name: appearance.tint_strength", "Tint strength"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: appearance.tint_strength",
                   "How strongly backgrounds, surfaces and borders take on the primary hue, as a percentage of the theme's own: 0 is neutral grey, 100 the default."
                 ),
               type: :integer,
               control: :tint_strength,
               default: 100,
               min: 0,
               max: 300,
               levels: [:site, :user]
             }}
          ]
        },
        %{
          id: "chat_avatars",
          label: dpgettext_noop("settings", "settings section heading: appearance.chat_avatars", "Chat avatars"),
          settings: [
            {"appearance.avatar_max_width",
             %{
               label: dpgettext_noop("settings", "setting name: appearance.avatar_max_width", "Largest avatar width"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: appearance.avatar_max_width",
                   "The widest, in pixels, a chat message's portrait or expression sprite grows on a wide screen."
                 ),
               type: :integer,
               default: 300,
               min: 48,
               max: 1000,
               levels: [:site, :user]
             }},
            {"appearance.avatar_max_height",
             %{
               label: dpgettext_noop("settings", "setting name: appearance.avatar_max_height", "Largest avatar height"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: appearance.avatar_max_height",
                   "The tallest, in pixels, a chat message's portrait or expression sprite grows; a portrait keeps its 3:4 shape, so this also narrows it."
                 ),
               type: :integer,
               default: 400,
               min: 64,
               max: 1333,
               levels: [:site, :user]
             }}
          ]
        },
        %{
          id: "stylesheets",
          label: dpgettext_noop("settings", "settings section heading: appearance.stylesheets", "Stylesheets"),
          settings: [
            {"appearance.site_css",
             %{
               label: dpgettext_noop("settings", "setting name: appearance.site_css", "Site stylesheet"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: appearance.site_css",
                   "CSS for every page, for everyone, signed-out pages included, applied as written before each user's own."
                 ),
               type: :css,
               default: nil,
               levels: [:site]
             }},
            {"appearance.extra_sources",
             %{
               label: dpgettext_noop("settings", "setting name: appearance.extra_sources", "Extra stylesheet sources"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: appearance.extra_sources",
                   "Origins the site stylesheet may load stylesheets, fonts and images from, besides the app and the allowed font services, separated by spaces or new lines, e.g. https://use.typekit.net https://p.typekit.net. Users' stylesheets may load from them too."
                 ),
               type: :origins,
               default: [],
               levels: [:site]
             }},
            {"appearance.restrict_user_css",
             %{
               label:
                 dpgettext_noop("settings", "setting name: appearance.restrict_user_css", "Restrict user stylesheets"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: appearance.restrict_user_css",
                   "Users' stylesheets may not load anything from outside the app: no url(), image-set(), @import or similar, except font stylesheets while third-party fonts are allowed. Turn off to let users write any CSS."
                 ),
               type: :boolean,
               default: true,
               levels: [:site]
             }},
            {"appearance.allow_third_party_fonts",
             %{
               label:
                 dpgettext_noop(
                   "settings",
                   "setting name: appearance.allow_third_party_fonts",
                   "Allow third-party fonts"
                 ),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: appearance.allow_third_party_fonts",
                   ~s|Restricted user stylesheets may still @import a Google Fonts stylesheet, e.g. @import url("https://fonts.googleapis.com/css2?family=Inter&display=swap");. The font service sees each visitor's IP address. Has no effect while user stylesheets are unrestricted.|
                 ),
               type: :boolean,
               default: true,
               levels: [:site]
             }},
            {"appearance.user_css",
             %{
               label: dpgettext_noop("settings", "setting name: appearance.user_css", "Your stylesheet"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: appearance.user_css",
                   "CSS for every page you see, applied after the site's. Add ?safe_mode to a page's address to load it without this stylesheet. Where the site allows third-party fonts, you may @import a Google Fonts stylesheet."
                 ),
               type: :css,
               default: nil,
               levels: [:user],
               restricted: true
             }}
          ]
        },
        %{
          id: "remote_media",
          label: dpgettext_noop("settings", "settings section heading: appearance.remote_media", "Remote images"),
          settings: [
            {"appearance.remote_images",
             %{
               label: dpgettext_noop("settings", "setting name: appearance.remote_images", "Remote images in messages"),
               description:
                 dpgettext_noop(
                   "settings",
                   "setting description: appearance.remote_images",
                   "Images a message links from other sites. Through this server, the image's site sees the server's address instead of each reader's. Directly, it sees every reader's address and can tell who read the message."
                 ),
               type: :select,
               default: :proxy,
               options: [
                 {:off, dpgettext_noop("settings", "setting option: appearance.remote_images", "Off: don't show them")},
                 {:proxy,
                  dpgettext_noop("settings", "setting option: appearance.remote_images", "Through this server")},
                 {:direct,
                  dpgettext_noop("settings", "setting option: appearance.remote_images", "Directly from their site")}
               ],
               levels: [:site]
             }}
          ]
        }
      ]
    }
  ]

  @definitions for c <- @categories,
                   s <- c.sections,
                   {key, d} <- s.settings,
                   do: {key, Map.merge(d, %{key: key, category: c.id, section: s.id})}

  @settings Map.new(@definitions)
  @site_keys for {key, d} <- @definitions, :site in d.levels, do: key
  @user_keys for {key, d} <- @definitions, :user in d.levels, do: key
  @model_keys for {key, %{type: :model} = d} <- @definitions, do: {key, d.label, d.models}

  @category_index for c <- @categories,
                      do: %{
                        c
                        | sections: for(s <- c.sections, do: %{s | settings: Enum.map(s.settings, &elem(&1, 0))})
                      }

  @type level :: :site | :user
  @type key :: String.t()

  @doc "The value of setting `key` for `scope`. Raises `ArgumentError` for an unknown key."
  @spec get(Scope.t(), key()) :: term()
  def get(%Scope{} = scope, key), do: Map.fetch!(get_many(scope, [key]), key)

  @doc "The values of `keys` for `scope`, in one query. Raises `ArgumentError` for an unknown key."
  @spec get_many(Scope.t(), [key()]) :: %{key() => term()}
  def get_many(%Scope{} = scope, keys) do
    definitions = Enum.map(keys, &definition!/1)
    layers = layers(scope)
    Map.new(definitions, &{&1.key, cascade(&1, layers)})
  end

  @doc """
  Whether `scope` may set or reset `key` at `level`: the site level is admins', for keys whose
  `levels` include `:site`; the user level is any signed-in user's, for keys users may override that
  the site has not locked.
  """
  @spec can_edit?(Scope.t(), level(), key()) :: boolean()
  def can_edit?(%Scope{} = scope, level, key) when level in [:site, :user] do
    editable?(scope, level, definition!(key), locked_keys(scope, level))
  end

  @doc """
  Sets `key` at `level` (the site, or `scope`'s user) from a typed value or form string.
  """
  @spec put(Scope.t(), level(), key(), term()) :: :ok | {:error, :unauthorized | String.t()}
  def put(%Scope{} = scope, level, key, raw) when level in [:site, :user] do
    definition = definition!(key)

    with true <- can_edit?(scope, level, key) || {:error, :unauthorized},
         {:ok, value} <- cast(with_options(definition, scope, level), raw) do
      result = if is_nil(value), do: remove(scope, level, key), else: upsert(scope, level, key, value)
      Changes.notify(result, :settings, level_user_id(scope, level))
    end
  end

  defp upsert(scope, level, key, value) do
    change = %{key => encode(value)}
    now = now()

    # Merged inside Postgres, so concurrent writes of different keys never clobber each other.
    {:ok, _} =
      Repo.insert(%Setting{user_id: level_user_id(scope, level), values: change},
        conflict_target: [:user_id],
        on_conflict:
          from(s in Setting,
            update: [set: [values: fragment("? || ?", s.values, type(^change, :map)), updated_at: ^now]]
          )
      )

    :ok
  end

  # No override stored: the next layer down applies.
  defp remove(scope, level, key) do
    now = now()

    level
    |> level_query(scope)
    |> update([s], set: [values: fragment("? - ?::text", s.values, ^key), updated_at: ^now])
    |> Repo.update_all([])

    :ok
  end

  @doc "Removes `key`'s override at `level`, so the next layer down applies again."
  @spec reset(Scope.t(), level(), key()) :: :ok | {:error, :unauthorized}
  def reset(%Scope{} = scope, level, key) when level in [:site, :user] do
    if can_edit?(scope, level, key),
      do: scope |> remove(level, key) |> Changes.notify(:settings, level_user_id(scope, level)),
      else: {:error, :unauthorized}
  end

  @doc "Locks (`true`) or unlocks a user-overridable `key`. Admins only."
  @spec lock(Scope.t(), key(), boolean()) :: :ok | {:error, :unauthorized}
  def lock(%Scope{} = scope, key, locked) when is_boolean(locked) do
    definition = definition!(key)

    if Scope.can?(scope, "site.settings.manage") and :user in definition.levels do
      add = if locked, do: [key], else: []
      now = now()

      {:ok, _} =
        Repo.insert(%Setting{user_id: nil, values: %{}, locked_keys: add},
          conflict_target: [:user_id],
          on_conflict:
            from(s in Setting,
              update: [
                set: [
                  locked_keys: fragment("array_remove(?, ?::text) || ?::text[]", s.locked_keys, ^key, ^add),
                  updated_at: ^now
                ]
              ]
            )
        )

      Changes.notify(:ok, :settings, nil)
    else
      {:error, :unauthorized}
    end
  end

  @doc "The categories, each section listing its setting keys, in display order."
  @spec categories() :: [map()]
  def categories, do: Enum.map(@category_index, &localize_category/1)

  @doc """
  The `:model` settings that name `model_id` at any level, site or any user's, each as
  `%{key:, label:, models:, count:}` (`models` the setting's model kind, `count` how many rows name
  it). `Mythweaver.AI` reads it before changing a model's completion mode.
  """
  @spec model_uses(Ecto.UUID.t()) :: [%{key: key(), label: String.t(), models: atom(), count: pos_integer()}]
  def model_uses(model_id) do
    for {key, label, models} <- @model_keys,
        count = Repo.aggregate(from(s in Setting, where: fragment("?->>? = ?", s.values, ^key, ^model_id)), :count),
        count > 0,
        do: %{key: key, label: translate("setting name: " <> key, label), models: models, count: count}
  end

  @doc "The completion modes a `:model` setting of kind `models` accepts."
  @spec accepted_modes(atom()) :: [atom()]
  def accepted_modes(:embedding), do: [:embedding]
  def accepted_modes(:expression), do: Model.text_modes() ++ [:classifier]
  def accepted_modes(kind) when kind in [:text, :caption], do: Model.text_modes()

  @doc """
  Every setting visible at `level`, in display order, each its definition plus `value` (at `:site`
  the site value or default, at `:user` the full cascade), `modified?` (this level overrides it),
  `locked?` and `editable?`. The site level is admins' only: anyone else gets `[]`.
  """
  @spec entries(Scope.t(), level()) :: [map()]
  def entries(%Scope{} = scope, :site) do
    if Scope.can?(scope, "site.settings.manage"), do: build_entries(scope, :site, @site_keys), else: []
  end

  def entries(%Scope{} = scope, :user), do: build_entries(scope, :user, @user_keys)

  defp build_entries(scope, level, keys) do
    layers = layers(scope)

    {own, cascade_layers} =
      if level == :site,
        do: {layers.site, %{layers | user: %{}}},
        else: {layers.user, layers}

    for key <- keys, available?(@settings[key]) do
      definition = @settings[key] |> localize() |> with_options(scope, level)

      Map.merge(definition, %{
        value: cascade(definition, cascade_layers),
        modified?: match?({:ok, _}, stored(definition, own)),
        locked?: key in layers.locked,
        editable?: editable?(scope, level, definition, layers.locked)
      })
    end
  end

  defp available?(%{requires: :web_push}), do: WebPush.configured?()
  defp available?(_definition), do: true

  # A `:model` setting's options are `{id, name}` pairs, like a `:select`'s, read per call because
  # models change at runtime: the site level offers site models (a personal one would not run for
  # everyone), the user level every model the user may run.
  defp with_options(%{type: :model} = definition, scope, level),
    do: Map.put(definition, :options, model_options(definition, scope, level))

  # A `:side_prompt_set` setting's options likewise: site sets at the site level, every usable set at
  # the user level.
  defp with_options(%{type: :side_prompt_set} = definition, scope, level) do
    options =
      for set <- Mythweaver.Memory.list_usable_side_prompt_sets(scope),
          level == :user or is_nil(set.user_id),
          do: {set.id, set.name}

    Map.put(definition, :options, options)
  end

  # An `:expression_profile` setting's options likewise.
  defp with_options(%{type: :expression_profile} = definition, scope, level) do
    options =
      for p <- Mythweaver.Expressions.list_profiles(scope), level == :user or is_nil(p.user_id), do: {p.id, p.name}

    Map.put(definition, :options, options)
  end

  # A `:caption_prompt` setting's options: the site's caption prompts (only site-level settings use it).
  defp with_options(%{type: :caption_prompt} = definition, scope, _level) do
    options =
      for prompt <- Mythweaver.Prompts.list_prompts(scope, :caption),
          is_nil(prompt.user_id),
          do: {prompt.id, prompt.name}

    Map.put(definition, :options, options)
  end

  # A restricted `:css` setting carries the restriction in force now (`nil` when off), for `cast/2`.
  defp with_options(%{type: :css, restricted: true} = definition, scope, _level),
    do: Map.put(definition, :restriction, Stylesheets.restriction(scope))

  defp with_options(%{type: :language} = definition, _scope, _level),
    do: Map.put(definition, :options, Mythweaver.Locale.language_options())

  defp with_options(%{type: :locale} = definition, _scope, _level),
    do: Map.put(definition, :options, Mythweaver.Locale.format_options())

  defp with_options(definition, _scope, _level), do: definition

  # Every text in `@categories` is an English `dpgettext_noop` msgid whose context is built from ids;
  # these rebuild each context and translate the text into the current locale.
  defp localize(%{key: key} = definition) do
    definition
    |> Map.update!(:label, &translate("setting name: " <> key, &1))
    |> Map.update!(:description, &translate("setting description: " <> key, &1))
    |> localize_options()
  end

  # `@tiers` holds the English tier names only as compile-time stand-ins; `Tiers.label/1` translates.
  defp localize_options(%{options: @tiers} = definition),
    do: %{definition | options: for({tier, _name} <- @tiers, do: {tier, Tiers.label(tier)})}

  defp localize_options(%{type: :select, key: key, options: options} = definition) do
    %{definition | options: for({value, label} <- options, do: {value, translate("setting option: " <> key, label)})}
  end

  defp localize_options(definition), do: definition

  defp localize_category(%{id: id} = category) do
    %{
      category
      | label: translate("settings category: " <> id, category.label),
        sections: Enum.map(category.sections, &localize_section(id, &1))
    }
  end

  defp localize_section(category_id, %{id: id} = section) do
    path = category_id <> "." <> id

    section
    |> Map.update!(:label, &translate("settings section heading: " <> path, &1))
    |> Map.replace_lazy(:description, &translate("settings section description: " <> path, &1))
    |> Map.replace_lazy(:grid, &localize_grid(path, &1))
  end

  defp localize_grid(path, grid) do
    columns =
      for column <- grid.columns,
          do: %{column | label: translate("settings grid column: #{path}.#{column.id}", column.label)}

    rows =
      for row <- grid.rows do
        row
        |> Map.update!(:label, &translate("settings grid row: #{path}.#{row.id}", &1))
        |> Map.replace_lazy(:description, &translate("settings grid row description: #{path}.#{row.id}", &1))
      end

    %{grid | columns: columns, rows: rows}
  end

  defp translate(context, msgid), do: Gettext.dpgettext(Mythweaver.Gettext, "settings", context, msgid)

  defp model_options(%{models: :caption}, scope, _level) do
    for {name, id} <- Mythweaver.AI.caption_model_options(scope, nil, nil), do: {id, name}
  end

  defp model_options(%{models: :text}, scope, level) do
    for model <- Mythweaver.AI.list_models(scope), level == :user or is_nil(model.user_id), do: {model.id, model.name}
  end

  defp model_options(%{models: :expression}, scope, level) do
    for model <- Mythweaver.AI.list_models(scope) ++ Mythweaver.AI.list_classifier_models(scope),
        level == :user or is_nil(model.user_id),
        do: {model.id, model.name}
  end

  defp model_options(%{models: :embedding}, scope, level) do
    for model <- Mythweaver.AI.list_embedding_models(scope),
        level == :user or is_nil(model.user_id),
        do: {model.id, model.name}
  end

  defp definition!(key) when is_map_key(@settings, key), do: Map.fetch!(@settings, key)
  defp definition!(key), do: raise(ArgumentError, "unknown setting: #{inspect(key)}")

  # The single access rule.
  defp editable?(scope, :site, definition, _locked),
    do: Scope.can?(scope, "site.settings.manage") and :site in definition.levels

  defp editable?(scope, :user, definition, locked) do
    scope.user != nil and :user in definition.levels and definition.key not in locked
  end

  defp cascade(definition, %{site: site, user: user, locked: locked}) do
    user_value =
      if :user in definition.levels and definition.key not in locked,
        do: stored(definition, user),
        else: :error

    with :error <- user_value,
         :error <- stored(definition, site) do
      definition.default
    else
      {:ok, value} -> value
    end
  end

  defp stored(definition, values) do
    case Map.fetch(values, definition.key) do
      {:ok, value} -> decode(definition, value)
      :error -> :error
    end
  end

  # The site row and the scope user's row, at most two.
  defp layers(scope) do
    rows = Repo.all(rows_query(scope))
    site = Enum.find(rows, &is_nil(&1.user_id))
    user = Enum.find(rows, &(&1.user_id != nil))

    %{
      site: (site && site.values) || %{},
      user: (user && user.values) || %{},
      locked: (site && site.locked_keys) || []
    }
  end

  defp rows_query(%Scope{user: %{id: user_id}}),
    do: from(s in Setting, where: is_nil(s.user_id) or s.user_id == ^user_id)

  defp rows_query(%Scope{}), do: from(s in Setting, where: is_nil(s.user_id))

  defp locked_keys(_scope, :site), do: []

  defp locked_keys(_scope, :user) do
    Repo.one(from(s in Setting, where: is_nil(s.user_id), select: s.locked_keys)) || []
  end

  defp level_user_id(_scope, :site), do: nil
  defp level_user_id(scope, :user), do: scope.user.id

  defp level_query(:site, _scope), do: from(s in Setting, where: is_nil(s.user_id))
  defp level_query(:user, scope), do: from(s in Setting, where: s.user_id == ^scope.user.id)

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)

  @max_template_bytes 2000
  @max_css_characters 100_000

  defp cast(%{type: :boolean}, raw) when is_boolean(raw), do: {:ok, raw}
  defp cast(%{type: :boolean}, "true"), do: {:ok, true}
  defp cast(%{type: :boolean}, "false"), do: {:ok, false}
  defp cast(%{type: :boolean}, _raw), do: {:error, dgettext("errors", "must be true or false")}

  defp cast(%{type: :integer} = definition, raw) when is_integer(raw), do: check_range(definition, raw)

  defp cast(%{type: :integer} = definition, raw) when is_binary(raw) do
    case Integer.parse(String.trim(raw)) do
      {value, ""} -> check_range(definition, value)
      _ -> {:error, dgettext("errors", "must be a whole number")}
    end
  end

  defp cast(%{type: :integer}, _raw), do: {:error, dgettext("errors", "must be a whole number")}

  defp cast(%{type: :select, options: options}, raw) do
    case option(options, raw) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, dgettext("errors", "is not an option")}
    end
  end

  defp cast(%{type: :multi_select, options: options}, raw) when is_list(raw) do
    raw
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn element, {:ok, acc} ->
      case option(options, element) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, {:error, dgettext("errors", "is not an option")}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, for({value, _} <- options, value in values, do: value)}
      error -> error
    end
  end

  defp cast(%{type: :multi_select}, _raw), do: {:error, dgettext("errors", "must be a list")}

  defp cast(%{type: :template}, nil), do: {:ok, nil}

  defp cast(%{type: :template}, raw) when is_binary(raw) do
    case String.trim(raw) do
      "" ->
        {:ok, nil}

      text when byte_size(text) > @max_template_bytes ->
        {:error, too_long(@max_template_bytes)}

      text ->
        case Mythweaver.Templates.parse(text) do
          {:ok, _} ->
            {:ok, text}

          {:error, message} ->
            {:error, dgettext("errors", "is not a valid template: %{parse_error}", parse_error: message)}
        end
    end
  end

  defp cast(%{type: :template}, _raw), do: {:error, dgettext("errors", "must be text")}

  defp cast(%{type: :css}, nil), do: {:ok, nil}

  defp cast(%{type: :css} = definition, raw) when is_binary(raw) do
    cond do
      String.trim(raw) == "" -> {:ok, nil}
      not String.valid?(raw) -> {:error, dgettext("errors", "must be text")}
      String.length(raw) > @max_css_characters -> {:error, too_long(@max_css_characters)}
      definition[:restriction] -> restricted_css(raw, definition.restriction)
      true -> {:ok, raw}
    end
  end

  defp cast(%{type: :css}, _raw), do: {:error, dgettext("errors", "must be text")}

  @max_origins 20

  defp cast(%{type: :origins}, nil), do: {:ok, nil}

  defp cast(%{type: :origins}, raw) when is_binary(raw) do
    entries = String.split(raw, ~r/[\s,]+/u, trim: true)

    cond do
      entries == [] ->
        {:ok, nil}

      length(entries) > @max_origins ->
        {:error,
         dngettext(
           "errors",
           "must be at most %{origin_limit} origin",
           "must be at most %{origin_limit} origins",
           @max_origins,
           origin_limit: Format.number(@max_origins)
         )}

      true ->
        entries
        |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
          case origin(entry) do
            {:ok, origin} -> {:cont, {:ok, [origin | acc]}}
            :error -> {:halt, {:error, not_an_origin(entry)}}
          end
        end)
        |> case do
          {:ok, origins} -> {:ok, origins |> Enum.reverse() |> Enum.uniq()}
          error -> error
        end
    end
  end

  defp cast(%{type: :origins}, _raw), do: {:error, dgettext("errors", "must be text")}

  defp cast(%{type: type}, raw)
       when type in [:model, :side_prompt_set, :expression_profile, :caption_prompt, :language, :locale] and
              raw in [nil, ""], do: {:ok, nil}

  defp cast(%{type: type, options: options}, raw)
       when type in [:model, :side_prompt_set, :expression_profile, :caption_prompt, :language, :locale] and
              is_binary(raw) do
    if Enum.any?(options, &(elem(&1, 0) == raw)),
      do: {:ok, raw},
      else: {:error, dgettext("errors", "is not an option")}
  end

  defp cast(%{type: type}, _raw)
       when type in [:model, :side_prompt_set, :expression_profile, :caption_prompt, :language, :locale],
       do: {:error, dgettext("errors", "is not an option")}

  # A bare web origin: `https` (or `http` on `localhost`), a host, no userinfo, and nothing past an
  # optional `/`. Lowercased, the port kept only when it is not the scheme's default.
  defp origin(entry) do
    with {:ok, %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil} = uri}
         when is_binary(scheme) and is_binary(host) and host != "" <- URI.new(entry),
         scheme = String.downcase(scheme, :ascii),
         host = String.downcase(host, :ascii),
         true <- scheme == "https" or (scheme == "http" and host == "localhost"),
         true <- uri.path in [nil, "", "/"] do
      port = if uri.port == URI.default_port(scheme), do: "", else: ":#{uri.port}"
      {:ok, "#{scheme}://#{host}#{port}"}
    else
      _ -> :error
    end
  end

  defp not_an_origin(entry) do
    gettext_comment("A typed stylesheet source that is not a bare web origin; the example origin stays as is.")
    dgettext("errors", "%{typed_origin} isn't an origin like https://fonts.example.com", typed_origin: entry)
  end

  defp too_long(limit) do
    dngettext(
      "errors",
      "must be at most %{character_limit} character",
      "must be at most %{character_limit} characters",
      limit,
      character_limit: Format.number(limit)
    )
  end

  defp restricted_css(raw, restriction) do
    case Policy.check(raw, restriction) do
      :ok ->
        {:ok, raw}

      {:error, construct} ->
        {:error, outside_files(construct, restriction)}
    end
  end

  defp outside_files("@import", webfonts: true) do
    gettext_comment(
      "A CSS construct such as url() or @import, verbatim; the font services are brand names joined as an \"or\" list."
    )

    dgettext("errors", "can't load outside files: %{css_construct} isn't allowed, except a %{font_services} stylesheet",
      css_construct: "@import",
      font_services: Localize.List.to_string!(Webfonts.names(), list_style: :or, locale: Localize.get_locale())
    )
  end

  defp outside_files(construct, _restriction) do
    gettext_comment("A CSS construct such as url() or @import, verbatim.")
    dgettext("errors", "can't load outside files: %{css_construct} isn't allowed", css_construct: construct)
  end

  defp check_range(definition, value) do
    cond do
      is_integer(definition[:min]) and value < definition.min ->
        {:error, dgettext("errors", "must be at least %{minimum}", minimum: Format.number(definition.min))}

      is_integer(definition[:max]) and value > definition.max ->
        {:error, dgettext("errors", "must be at most %{maximum}", maximum: Format.number(definition.max))}

      true ->
        {:ok, value}
    end
  end

  defp option(options, raw) do
    case Enum.find(options, fn {value, _} -> to_string(value) == to_string(raw) end) do
      {value, _} -> {:ok, value}
      nil -> :error
    end
  end

  defp encode(value) when is_list(value), do: Enum.map(value, &encode/1)
  defp encode(value) when is_atom(value) and not is_boolean(value) and not is_nil(value), do: Atom.to_string(value)
  defp encode(value), do: value

  # Type checks only, no range check: a stored value that no longer fits is `:error`.
  defp decode(%{type: :boolean}, value) when is_boolean(value), do: {:ok, value}
  defp decode(%{type: :integer}, value) when is_integer(value), do: {:ok, value}
  defp decode(%{type: :select, options: options}, value), do: decode_option(options, value)

  defp decode(%{type: :multi_select, options: options}, values) when is_list(values) do
    decoded = Enum.map(values, &decode_option(options, &1))

    if Enum.all?(decoded, &match?({:ok, _}, &1)),
      do: {:ok, Enum.map(decoded, &elem(&1, 1))},
      else: :error
  end

  defp decode(%{type: :template}, value) when is_binary(value), do: {:ok, value}
  defp decode(%{type: :css}, value) when is_binary(value), do: {:ok, value}

  defp decode(%{type: :origins}, values) when is_list(values) do
    if Enum.all?(values, &is_binary/1), do: {:ok, values}, else: :error
  end

  # Existence is the reader's check: a stored id whose model is gone still decodes.
  defp decode(%{type: type}, nil)
       when type in [:model, :side_prompt_set, :expression_profile, :caption_prompt, :language, :locale], do: {:ok, nil}

  defp decode(%{type: type}, value)
       when type in [:model, :side_prompt_set, :expression_profile, :caption_prompt] and is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> :error
    end
  end

  # Any id Localize still supports; one it dropped reads as no choice.
  defp decode(%{type: :locale}, value) when is_binary(value) do
    case Localize.validate_locale(value) do
      {:ok, _tag} -> {:ok, value}
      {:error, _} -> :error
    end
  end

  # A language whose catalog was removed reads as no choice.
  defp decode(%{type: :language}, value) when is_binary(value) do
    if value in Gettext.known_locales(Mythweaver.Gettext), do: {:ok, value}, else: :error
  end

  defp decode(_definition, _value), do: :error

  defp decode_option(options, stored) do
    case Enum.find(options, fn {value, _} -> encode(value) == stored end) do
      {value, _} -> {:ok, value}
      nil -> :error
    end
  end
end
