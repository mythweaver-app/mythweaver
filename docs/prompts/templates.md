---
title: Template reference
order: 3
description: Everything a Liquid template can read and write, with its tags, filters, limits and errors.
---

Prompt blocks, lore entries, character descriptions and the messages you type are Liquid templates. This page lists what a template can use: the data it reads, the tags and filters it may call, and how errors and limits work.

The block editor at **Prompt blocks** (`/prompts/blocks`) has a **Template reference** panel under its **Template** field that lists the same values, and the editor suggests paths and filters as you type.

## Where templates render

When a prompt is built for a reply, templates render in this order and share one state, so a value set early is visible later:

1. Every participant's and the player's **description** (each sees raw descriptions). In a character's
   own description, `anchors.character` is that character, whoever replies, so a joined card that
   names itself stays right; in the player's description it is the responder.
2. Every activated **lore entry**, slot by slot in this order: `before_character`, `after_character`,
   `before_examples`, `after_examples`, at depth, `before_author_note`, `after_author_note`, then
   custom outlets by ascending key (each sees rendered descriptions).
3. Every enabled **template block** of the prompt, in prompt order (each sees everything above).

Chat history, generated replies and continued text are never rendered.

**Typed chat messages** (what you send from the composer, and edits you save) render once, after
the same description and lore pass. The **rendered text is what gets stored**, so the template itself
is gone. Message templates are read-only: variable writes are dropped and the notice "Variable writes
in messages are ignored." is shown. A message that fails to render is not saved.

> [!NOTE]
> Because a typed message is stored already rendered, `{{ anchors.now }}` or `{{ "1d20" | roll }}` in
> a message is evaluated once, when you send it, and the result stays the same on every later reply.

## Data

The template root is exactly `anchors`, `outlets`, `vars`, and `globals`, plus the aliases `char`
and `user`.

Types are written as Liquid sees them: `string`, `int`, `float`, `bool`, `map` (a hash, read with
`.key`), `array<T>` (a list of `T`), and `nil`. `T | nil` means the value is `nil` when absent or
blank.

### `anchors`

| Path | Type | Value |
|---|---|---|
| `anchors.character` | `map \| nil` | The responding character; `nil` when there is none |
| `anchors.character.name` | `string \| nil` | The responding character's name |
| `anchors.character.pronouns` | `string \| nil` | The responding character's pronouns |
| `anchors.character.description` | `string \| nil` | The responding character's description, rendered |
| `anchors.character.appearance` | `string \| nil` | How the responding character looks; filled from their avatar's description, editable |
| `anchors.character.player` | `bool \| nil` | Whether the responder is the player: `true` when the AI speaks for the player, and in the player's own typed messages |
| `anchors.character.tags` | `array<string> \| nil` | The responding character's tags, siblings resolved and parents implied (e.g. `species:dragon`) |
| `anchors.player` | `map \| nil` | The player character; `nil` when the chat has no player |
| `anchors.player.name` | `string \| nil` | The player character's name |
| `anchors.player.pronouns` | `string \| nil` | The player character's pronouns |
| `anchors.player.description` | `string \| nil` | The player character's description, rendered |
| `anchors.player.appearance` | `string \| nil` | How the player character looks |
| `anchors.player.tags` | `array<string> \| nil` | The player character's tags, siblings resolved and parents implied |
| `anchors.chat` | `map` | The chat; always present |
| `anchors.chat.name` | `string \| nil` | The chat's name |
| `anchors.chat.participants` | `array<string>` | Every participant's name, player first; `[]` when there are none |
| `anchors.chat.tags` | `array<string>` | The chat's tags, siblings resolved and parents implied |
| `anchors.chat.members` | `array<map>` | Every participant in speaking order (fields below) |
| `anchors.chat.characters` | `array<string>` | Every participant's name but the player's, in speaking order; `[]` when there are none |
| `anchors.participants` | `string \| nil` | Every participant's name as one string, player first, joined with `", "` |
| `anchors.other_characters` | `string \| nil` | Everyone but the responder and the player whose card the chat's Group cards setting joins, as `Name: description` paragraphs: nobody with Swap (the default), unmuted members with Join, every member with Join all. Card text with descriptions, not a list of names: use `anchors.chat.characters` |
| `anchors.cards` | `array<map>` | Every character whose card the chat's Group cards setting gives this reply, the responder included and the player left out (they are `anchors.player`), in participant order (fields below). With Join or Join all it is the same list whoever replies, so a prompt that lists it ahead of the history keeps a cacheable prefix |
| `anchors.messages` | `array<map>` | The AI-visible transcript, oldest first (fields below) |
| `anchors.now` | `string` | The current UTC time, ISO 8601 (`2026-10-02T18:50:07.126982Z`) |
| `anchors.guide` | `map \| nil` | This generation's guide; `nil` when there is none |
| `anchors.guide.text` | `string \| nil` | The user's outline, verbatim (never rendered as a template), then one line per attachment sent with the guide (an image's description; a clip's or document's text unless the model receives it natively) |
| `anchors.guide.continue` | `bool \| nil` | `true` when continuing the last message |
| `anchors.refine` | `map \| nil` | A refine's request; `nil` unless this generation rewrites the last message |
| `anchors.refine.instructions` | `string \| nil` | The user's editing instructions, verbatim (never rendered as a template), then one line per attachment sent with them (an image's description; a clip's or document's text unless the model receives it natively) |
| `anchors.refine.text` | `string \| nil` | The current text of the message being rewritten |
| `anchors.lore` | `map` | Rendered lore by slot; a slot with nothing activated is absent |
| `anchors.lore.<slot>` | `string \| nil` | Rendered lore that activated into that slot, joined with newlines. Slots: `before_character`, `after_character`, `before_examples`, `after_examples`, `before_author_note`, `after_author_note` |
| `anchors.memory_counts` | `map` | Entries in the chat's memory book by kind; always present, all `0` when the chat has no book |
| `anchors.memory_counts.tier0` | `int` | Tier-0 memories |
| `anchors.memory_counts.tier1` | `int` | Tier-1 consolidations (Arcs) |
| `anchors.memory_counts.tier2` | `int` | Tier-2 consolidations (Chapters) |
| `anchors.memory_counts.tier3` | `int` | Tier-3 consolidations (Books) |
| `anchors.memory_counts.tier4` | `int` | Tier-4 consolidations (Legends) |
| `anchors.memory_counts.tier5` | `int` | Tier-5 consolidations (Series) |
| `anchors.memory_counts.tier6` | `int` | Tier-6 consolidations (Epics) |
| `anchors.memory_counts.clips` | `int` | Clips |
| `anchors.memory_counts.side_prompts` | `int` | Side-prompt entries |

Lore with the **At depth** outlet has no anchor: it goes inside the chat history block, its depth
counted in messages from the end. Lore with a **Custom** outlet is under [`outlets`](#outlets).
See [Outlets](outlets.md).

Each `anchors.chat.members` item:

| Field | Type | Value |
|---|---|---|
| `name` | `string` | The character's name |
| `description` | `string \| nil` | The character's description, rendered |
| `pronouns` | `string \| nil` | The character's pronouns |
| `appearance` | `string \| nil` | How the character looks |
| `muted` | `bool` | Whether the character is muted (still in the scene, just never auto-selected) |
| `player` | `bool` | Whether the character is the chat's player |
| `tags` | `array<string>` | The character's tags, siblings resolved and parents implied |

Tags are matched with `contains`: `{% if anchors.character.tags contains "species:dragon" %}…{% endif %}`.

Each `anchors.cards` item:

| Field | Type | Value |
|---|---|---|
| `name` | `string` | The character's name |
| `description` | `string \| nil` | The character's description, rendered |
| `pronouns` | `string \| nil` | The character's pronouns |
| `appearance` | `string \| nil` | How the character looks |

Each `anchors.messages` item:

| Field | Type | Value |
|---|---|---|
| `author` | `string` | The author's name: the character, a string author, or `"Narrator"` |
| `content` | `string` | The active swipe's text; never blank |
| `role` | `string` | `"assistant"` for lines by `anchors.character`, `"user"` for everyone else |

A string value that would be blank (`nil`, `""`, or whitespace) is `nil`, so
`{% if anchors.character.pronouns %}` works. Liquid treats `""` as truthy.

Arrays behave differently:

- `{{ array }}` concatenates with no separator (`GeraltYennefer`). Use `| join: ", "`.
- An empty array is truthy, so test `{% if array.size > 0 %}`, not `{% if array %}`.

When a typed message renders, `anchors.character` is the message's author: the player character
for a composer send, the original author for an edit. It is `nil` when the author isn't a
participant. `anchors.player` is still the chat's player. To name the AI characters from a message,
use `{{ char }}` (below) or `{{ anchors.chat.characters | join: ", " }}`; `anchors.other_characters`
pastes whole card descriptions.

### Memory anchors

`anchors.memory` exists only while a memory-book prompt renders: one whose **Purpose** is **Memory**,
**Consolidation**, **Compaction**, **Topical clip**, **Side prompt**, **Clip review**, **Clip
suggestions** or **Combine clips** (see [Memory](../memory/index.md)). Such a render activates no lore
and applies no injections, so `anchors.lore` and `outlets` are empty. Every key below is always
present; a key the job doesn't use is `nil` or `[]`.

| Path | Type | Value |
|---|---|---|
| `anchors.memory` | `map \| nil` | The memory-book job's data; `nil` in a roleplay prompt |
| `anchors.memory.kind` | `string` | The job: `"memory"`, `"consolidation"`, `"compaction"`, `"topical_clip"`, `"side_prompt"` or `"memory_assistance"` |
| `anchors.memory.scene` | `string \| nil` | The scene's messages as `[#N] Name: text` lines, separated by blank lines |
| `anchors.memory.scene_messages` | `array<map>` | The scene's messages, oldest first (fields below) |
| `anchors.memory.range` | `map \| nil` | The scene's display-number range |
| `anchors.memory.range.start` | `int \| nil` | The scene's first display number |
| `anchors.memory.range.end` | `int \| nil` | The scene's last display number |
| `anchors.memory.speakers` | `string \| nil` | The characters who speak in the scene, player excluded, joined with `", "` |
| `anchors.memory.previous_memories` | `array<map>` | Earlier memories sent as reference only, oldest first (fields below) |
| `anchors.memory.previous_text` | `string \| nil` | Those previous memories as `### title` then content blocks |
| `anchors.memory.context` | `string \| nil` | The chat's Additional Context lore entries as `### name` then content blocks |
| `anchors.memory.sources` | `array<map>` | The entries being consolidated or clipped (fields below) |
| `anchors.memory.sources_text` | `string \| nil` | Those sources as `[id] title` then content blocks |
| `anchors.memory.previous_summary` | `map \| nil` | The newest entry already at the target tier, sent as canon; `nil` when there is none |
| `anchors.memory.previous_summary.title` | `string \| nil` | That entry's title |
| `anchors.memory.previous_summary.content` | `string \| nil` | That entry's content |
| `anchors.memory.target_tier` | `map \| nil` | The consolidation's target tier; `nil` outside consolidation |
| `anchors.memory.target_tier.number` | `int \| nil` | The tier, `1` to `6` |
| `anchors.memory.target_tier.name` | `string \| nil` | The tier's name: Arc, Chapter, Book, Legend, Series or Epic |
| `anchors.memory.entry` | `map \| nil` | The existing entry being compacted or updated; `nil` when there is none |
| `anchors.memory.entry.title` | `string \| nil` | That entry's title |
| `anchors.memory.entry.content` | `string \| nil` | That entry's content |
| `anchors.memory.entry.kind` | `string \| nil` | That entry's record kind: `"memory"`, `"consolidation"`, `"clip"`, `"topical_clip"` or `"side_prompt"` |
| `anchors.memory.topic` | `string \| nil` | The topical clip's topic |
| `anchors.memory.keywords` | `string \| nil` | The topical clip's keywords, joined with `", "` |
| `anchors.memory.clips` | `array<map>` | Memory assistance: the clips under review, or the existing topical clips for topic suggestions (fields below) |
| `anchors.memory.clips_text` | `string \| nil` | Those clips as pretty-printed JSON |
| `anchors.memory.character` | `string \| nil` | A character memory copy's target character name(s), joined with `", "` |

Each `anchors.memory.scene_messages` item:

| Field | Type | Value |
|---|---|---|
| `number` | `int` | The message's display number (`#N`) |
| `author` | `string` | The author's name |
| `content` | `string` | The active swipe's text |

Each `anchors.memory.previous_memories` item:

| Field | Type | Value |
|---|---|---|
| `title` | `string` | The memory's title |
| `content` | `string` | The memory's content |

Each `anchors.memory.sources` item:

| Field | Type | Value |
|---|---|---|
| `id` | `string` | The source's 1-based index in the batch, zero-padded (`"001"`) |
| `title` | `string` | The source's title |
| `content` | `string` | The source's content |

Each `anchors.memory.clips` item:

| Field | Type | Value |
|---|---|---|
| `uid` | `string` | The clip's 1-based index in the batch, zero-padded (`"001"`) |
| `type` | `string` | `"ordinary"` or `"topical"` |
| `title` | `string` | The clip entry's name |
| `topic` | `string` | The topical clip's topic, or `""` |
| `keywords` | `string` | The entry's keywords, joined with `", "` |
| `content` | `string` | The clip's content |

Topic suggestions send only `title`, `topic` and `keywords`.

### `char` and `user`

SillyTavern's `{{char}}` and `{{user}}` work as typed, in every template.

- `user` is `anchors.player.name`.
- `char` is `anchors.character.name`: the responder in a prompt, the described character while a
  description renders.
- In a typed message or a greeting, `char` is the AI character instead: the author when a
  non-player participant wrote it, else the first participant character who isn't the player, else
  `nil`. So a player's `{{char}}` names who they're talking to, and a greeting's names its speaker.

Both are `nil` (render empty) when the anchor is. A template's own `{% assign char = … %}` wins
over the alias.

### `original`

A character's **System prompt** and **Post-history instructions** (on the character editor) are
templates too. When the character's **Card prompts** setting is **Replace the prompt's tagged block**,
the card text replaces the prompt block whose **Character override** names it, and `{{ original }}`
in the card text is that block's own rendered text, as in SillyTavern. See
[Blocks](blocks.md#character-overrides).

### `outlets`

| Path | Type | Value |
|---|---|---|
| `outlets` | `map` | Rendered custom-outlet lore by key |
| `outlets.<key>` | `string \| nil` | Rendered lore that activated into the custom outlet with that key (the outlet's **Key**), joined with newlines; absent when nothing activated |

### `vars` and `globals`

| Path | Type | Value |
|---|---|---|
| `vars.<key>` | `string \| int \| float \| bool \| array \| map \| nil` | A chat variable, falling back to a global variable with the same key |
| `globals.<key>` | `string \| int \| float \| bool \| array \| map \| nil` | A global variable only: the chat owner's own, else the site's |

Variables hold any JSON value and are `nil` when unset. A value written with `{% setvar %}` keeps
its Liquid type; decimals are stored as `float`. See [Variables](variables.md) for where they come
from and how to edit them.

## Tags

Liquid's standard tags, minus `render` (no file-system includes):

- Control flow: `if` / `elsif` / `else`, `unless`, `case` / `when`, `for` (with `break`,
  `continue`, `forloop.*`), `tablerow`, `cycle`
- Values: `assign`, `capture`, `increment`, `decrement`, `echo`
- Other: `comment`, inline `#` comments, `raw`

Mythweaver adds two tags that write [variables](variables.md):

- `{% setvar key = value %}` writes a chat variable.
- `{% setglobalvar key = value %}` writes the chat owner's own global variable (never the site's).

A `nil` value deletes the variable. Keys match `[A-Za-z_][A-Za-z0-9_]{0,63}`. A write is visible to
the rest of the render and to later templates. Only a real generation persists writes. A preview
or any other inspection doesn't, and writes in typed messages are discarded.

## Filters

### Mythweaver filters

| Filter | Behavior |
|---|---|
| `random` | A random element on every render; `nil` for an empty list |
| `pick` | A "random" element that stays the same for a given chat, template text, and position, so a regenerated reply gets the same choice |
| `roll` | Dice such as `"2d6+1"` or `"d6"`: up to 999 dice (default 1) with 1–9999 sides and a ±9999 modifier. A malformed roll is reported as an error |
| `push` | Appends a value to a list; on `nil` it starts a new list |
| `to_sentence` | Joins an array as English: `["a", "b", "c", "d"]` → `a, b, c, and d`; two items → `a and b`; one → `a`; `[]` or `nil` → empty. A non-array is reported as an error |

### Standard filters

- Strings: `append`, `prepend`, `capitalize`, `downcase`, `upcase`, `strip`, `lstrip`, `rstrip`,
  `squish`, `strip_html`, `strip_newlines`, `newline_to_br`, `replace`, `replace_first`,
  `replace_last`, `remove`, `remove_first`, `remove_last`, `slice`, `split`, `truncate`,
  `truncatewords`, `escape`, `escape_once`
- Encoding: `url_encode`, `url_decode`, `base64_encode`, `base64_decode`,
  `base64_url_safe_encode`, `base64_url_safe_decode`
- Math: `plus`, `minus`, `times`, `divided_by`, `modulo`, `abs`, `ceil`, `floor`, `round`,
  `at_least`, `at_most`
- Lists: `first`, `last`, `join`, `map`, `where`, `sort`, `sort_natural`, `uniq`, `reverse`,
  `compact`, `concat`, `size`, `sum`
- Other: `default`, `date`

## Limits and errors

- Every render runs on its own with a 1-second deadline and a memory cap of about 32 MB.
- At build time a template that fails falls back to its raw text and reports an error, which the
  **Preview** panel and the prompt inspector show. It never fails the build. The errors read
  "Template syntax error: …", "Template took longer than … ms.", "Template exceeded its memory
  limit." or "Template failed: …".
- A typed message that fails to render is refused with an error flash.
- Blocks, lore entries, and character descriptions are syntax-checked when saved.
- Undefined variables render empty and are not reported.

## Testing a template

Use the **Preview** panel on the prompt editor or the block editor to render a template against a
real chat without calling a model. A preview changes nothing: lore timing is not advanced and
variable writes are discarded. See [Preview](index.md#preview) for its options, and
[The prompt inspector](index.md#the-prompt-inspector) for what a real reply sent.

## Protected content

Protected content reaches templates only as a placeholder: lore from a forced, runtime-only or
hidden site book, and the description and appearance of a runtime-only site character. You can test
whether a value is set (`{% if anchors.lore.before_character %}`), but filters, `contains` and
`setvar` act on the placeholder, never the text, which goes back in after every block has rendered.
A role-play prompt that places no forced entry gets it in a system section at the top. To viewers
without the "See runtime-only and hidden site content" permission (`site.hidden.view`), a preview or
the prompt inspector shows protected values redacted, and a runtime-only block's (or runtime-only
prompt's) rendered text as `[Hidden block: …]`.

## Examples

### The responding character's card

This prints the responder's card the way SillyTavern does. Each line appears only when its value is set.

```liquid
{% if anchors.character %}
Character name: {{ anchors.character.name }}
{% if anchors.character.pronouns %}Character pronouns: {{ anchors.character.pronouns }}
{% endif %}{% if anchors.character.description %}Character description: {{ anchors.character.description }}
{% endif %}{% if anchors.character.appearance %}Character appearance: {{ anchors.character.appearance }}{% endif %}
{% endif %}
```

### Every card in a group chat

```liquid
{% for card in anchors.cards %}Character name: {{ card.name }}
{% if card.description %}Character description: {{ card.description }}
{% endif %}
{% endfor %}
```

### Text that depends on a tag

```liquid
{% if anchors.character.tags contains "species:dragon" %}
{{ anchors.character.name }} can breathe fire.
{% endif %}
```

### A counter kept in a chat variable

```liquid
{% assign turn = vars.turn | default: 0 | plus: 1 %}
{% setvar turn = turn %}
This is turn {{ turn }} of the story.
```

### Dice and random choices

```liquid
The weather today: {{ "sunny,rainy,foggy" | split: "," | pick }}.
{{ anchors.character.name }} rolls {{ "2d6" | roll }}.
```

`pick` keeps the same weather when you regenerate the reply; `random` would pick again each time.
