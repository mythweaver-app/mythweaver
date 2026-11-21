---
title: Import and export
order: 3
description: Bring in SillyTavern character cards, lore books, chats and presets, and export your own items as bundles or SillyTavern files.
---

**Import** at `/import` reads SillyTavern files, Character Card V1–V3 files and Mythweaver bundles. **Export** at `/export` writes your items as a lossless Mythweaver bundle or, for single items, as SillyTavern files. This page explains both, then maps each outside format's fields onto Mythweaver: what is kept, what is converted and what is dropped.

The native `.mythweaver` bundle is lossless, so this page covers it only where it travels inside an outside file.

## Importing

### To import files

1. Open **Import** at `/import`. Drop files on **Drop files here or choose them**, up to 20 at once and up to 200 MB each. Accepted extensions are `.png`, `.charx`, `.json`, `.jsonl` and `.mythweaver`.
2. Each file is read as soon as its upload finishes and shows up as a card with its kind (**Character card**, **Lore book**, **Chat**, **Chat Completion preset** or **Mythweaver bundle**), any warnings, and options for that kind (below).
3. Click **Import**. Each file is written all at once, so a failure leaves nothing behind. The card then shows the result and any warnings, such as skipped entries, unmatched character filters or an avatar that couldn't be saved.

Imported items belong to you, or to the site if you hold the site permission for that kind of item. Book, prompt and block names get a suffix when they clash with ones you already have. Character names may repeat.

### How the file type is detected

| File | Read as |
|---|---|
| `.png` | A character card stored in the image's `ccv3` (V3, preferred) or `chara` (V1/V2) text chunk. A PNG without one is rejected with *This PNG has no character card in it.* |
| `.charx` | A zip that contains `card.json`. |
| `.jsonl` | A SillyTavern chat. |
| `.json` | Checked in order: a character card (`spec` is `chara_card_v2`/`v3`, or `name` plus `description`/`personality`/`first_mes`, or Pygmalion `char_name`), then a lore book (`entries`), then a Chat Completion preset (`prompts`/`prompt_order`). Text-completion presets and templates, and files from other apps (Agnai, Risu, NovelAI lorebooks and similar), are recognized and rejected with an error that says so. |
| `.mythweaver` | A Mythweaver bundle. |

### Import options

| Kind | Options |
|---|---|
| **Chat** | A **Player** select and one select per speaker (*N messages*). Each speaker can map to an existing character, **Create new character**, or **Name only (no character)**: the messages keep the speaker's name but have no character. By default the header's `user_name` (or the `is_user` speaker with the most messages) is the player, a speaker whose name matches one of your characters maps to it, a narrator is name only, and anyone else gets a new character. The import needs a player character and at least two characters in total. |
| **Chat Completion preset** | An optional **Model samplers** select. The preset's sampler values overwrite the chosen model's sampler settings. |
| **Mythweaver bundle** | One **Replace** / **Copy** / **Skip** select per item. With no matching item here, the choices are Copy or Skip (default Copy). With a match you may edit, Replace, Copy or Skip (default Replace). With a match you may only use, Skip or Copy (default Skip). |

### Mythweaver files that come back

Every outside file Mythweaver exports also carries its full bundle (see [Exporting](#exporting)). On import, the file's standard fields are compared with a fingerprint stored at export time:

- If they match, the file imports **as the bundle**: lossless, with the same Replace / Copy / Skip review as a `.mythweaver` file. For a PNG or CHARX card, the image in the file becomes the character's avatar.
- If they don't (the file was edited in SillyTavern or another tool), only the standard fields import, as described below, with the warning *"This file was changed outside Mythweaver, so its Mythweaver-only details weren't imported."* Files exported before the card prompt fields existed also fail this check and import from their SillyTavern fields only.

### Macro conversion

Character descriptions, greetings, card-field text, lore entry content and preset prompt text are converted from SillyTavern macros to Liquid templates (see [Template reference](../prompts/templates.md)):

| SillyTavern | Mythweaver |
|---|---|
| `{{char}}`, `{{charIfNotGroup}}`, `<BOT>`, `<CHAR>`, `<CHARIFNOTGROUP>` | `{{ anchors.character.name }}` |
| `{{user}}`, `<USER>` | `{{ anchors.player.name }}` |
| `{{group}}`, `<GROUP>` | `{{ anchors.participants }}` |
| `{{description}}` / `{{persona}}` | `{{ anchors.character.description }}` / `{{ anchors.player.description }}` |
| `{{newline}}` | a newline |
| `{{noop}}`, `{{original}}`, `{{// …}}` | nothing |
| `{{trim}}` | nothing, and the newlines around it are removed |
| `{{random::a::b}}`, `{{random:a,b}}`, `{{pick…}}` | `{{ "a::b" \| split: "::" \| random }}` (or `pick`) |
| `{{roll:X}}` | `{{ "X" \| roll }}` (only when the dice expression parses; bare `N` means `dN`) |
| `{{getvar::k}}` / `{{getglobalvar::k}}` | `{{ vars.k }}` / `{{ globals.k }}` |
| `{{setvar::k::v}}` / `{{setglobalvar::k::v}}` | `{% setvar k = "v" %}` / `{% setglobalvar k = "v" %}` |

Any other macro (`{{time}}`, `{{lastMessage}}`, `{{idle_duration}}`, …), a stray `{%` and an unclosed `{{` are kept as literal text inside `{% raw %}` and listed in one warning: *"Left as literal text (no equivalent): …"*. If the converted text still doesn't parse, the whole text is kept raw and reported as an unparseable template. Names, keywords, creator notes and chat message text are never converted. Variables are explained in [Variables](../prompts/variables.md).

## Import field mapping

Fields that Mythweaver has no place for but that it can write back are kept aside, invisibly, with the item (up to 64 KiB per key) and restored on export. They are never used in prompts.

### Character cards (V1, V2, V3, Pygmalion; PNG, JSON, CHARX)

V2/V3 cards are read from `data`. V1 cards are read from the top level, with `creatorcomment` used for creator notes. Pygmalion cards map `char_name`, `char_persona`, `world_scenario`, `example_dialogue` and `char_greeting` onto `name`, `description`, `scenario`, `mes_example` and `first_mes`.

| Card field | Becomes | Notes |
|---|---|---|
| `name` | **Name** | Required (*"This card has no name."*); trimmed |
| `description` | **Description** | Macro-converted |
| `first_mes` | **First message** | Macro-converted; blank means none |
| `alternate_greetings` | **Alternate greetings** | Macro-converted; blank and non-text items skipped |
| `group_only_greetings` (V3) | **Group-only greetings** | As above |
| `creator` | **Creator** | |
| `creator_notes` | **Creator notes** | Not converted |
| `character_version` | **Character version** | |
| `extensions.talkativeness` | **Talkativeness** | Number or numeric string, clamped to 0..1 |
| `system_prompt` | **System prompt** | Macro-converted; the first `{{original}}` becomes `{{ original }}`, later ones are dropped (as in SillyTavern). Replaces the prompt block tagged *Main prompt* (see [Card prompts](#card-prompts)) |
| `post_history_instructions` | **Post-history instructions** | As above; replaces the block tagged *Post-history instructions* |
| `personality` | Constant entry "Personality" in the *(card)* book | Character outlet, after; order 100 |
| `scenario` | Constant entry "Scenario" | Character outlet, after; order 100 (after Personality, by name) |
| `mes_example` | Constant entry "Example dialogue" | Examples outlet, after. A leading `<START>` is dropped; other `<START>` lines become `[Example chat]` |
| `extensions.depth_prompt.prompt` / `.depth` / `.role` | Constant entry "Depth prompt" | At-depth outlet; depth defaults to 4, role defaults to system |
| `tags` | The character's tags | Trimmed, duplicates (any case) dropped, at most 50; site tags for a site import, else your personal tags. A tag that can't be created is dropped with a warning. See [Tags](tags.md) |
| `extensions.world` | The linked World Info book | A book of that name you can use is bound instead of the embedded `character_book` (as SillyTavern prefers the linked world); otherwise a warning says it isn't here (a hidden site book counts as missing). One that exists but can't be bound to the character (a site book and a personal character) gets its own warning, and the embedded book is imported instead. Import the World Info file first |
| `character_book` | A separate lore book bound to the character | See [Lore books](#lore-books-world-info-and-character_book) |
| File name (without extension) | The character's card file name | What SillyTavern character filters name the card by |
| PNG image | Avatar | Stored without its text chunks, so the card isn't stored twice |
| CHARX `icon` asset (`name: "main"` preferred) | Avatar | Only assets stored inside the zip (`embeded://`, `embedded://`, `__asset:`) |
| `extensions.mythweaver` | Embedded bundle | See [Mythweaver files that come back](#mythweaver-files-that-come-back) |
| Any other `data` / `extensions` key (V2/V3) | Kept aside | Written back on export; never rendered |

The card-field entries go into one lore book, *"<name> (card)"*, bound to the character. That book is created only when at least one of those fields isn't blank. Its entries render first in their slot and are never charged to the lore budget, and they don't feed recursion. See [Lore](../lore/index.md).

**Dropped:**

- V3 `nickname`, `source`, `creation_date`, `modification_date`, `creator_notes_multilingual` (kept aside)
- CHARX assets other than the one avatar icon (warning *"Ignored N extra assets."*), including expression sprites, backgrounds and remote (`http`) assets
- PNG `zTXt`/`iTXt` chunks (removed from the stored avatar, never read)
- Fields cards don't have: **Pronouns**, **Appearance**, the expression profile and sprites stay unset (see [Characters](../characters/index.md))

### Lore books (World Info and `character_book`)

A World Info file's `entries` can be an object keyed by uid or a list. A card's `character_book` is first converted the way SillyTavern does it (`keys` → `key`, `insertion_order` → `order`, the `extensions.*` fields promoted, `enabled` → `disable`, `position: "before_char"` → 0, else 1). Non-standard spellings other tools write (`excludeRecursion`, `matchWholeWords`, …, and Wyvern's top-level `whole_words_only`/`sticky`) are read when the standard key is absent, with one warning. Entries are sorted by `displayIndex`, then uid.

**Book level.** A World Info file's name comes from its filename; its `originalData` (SillyTavern's stale copy of the card book it came from) is dropped. For a `character_book`, the name defaults to *"<character> (lore)"*; its `scan_depth`, `token_budget` and `recursive_scanning` are not applied (SillyTavern ignores them) but kept aside, with a warning. Aikobots' `stlo` (top level or under `extensions`) gives the book's **Priority** (1..5), **Order adjustment** and, for `budgetMode: "fixed"`, **Token budget**; its percentage modes and other settings are warned about. Every other top-level key, except `entries` and `extensions.mythweaver`, is kept aside.

**Entries.** The lore entry fields are explained in [Entries and activation](../lore/entries.md) and [Timing, budgets and recursion](../lore/timing.md).

| SillyTavern entry field | Becomes | Notes |
|---|---|---|
| `comment` | Entry name | Falls back to the first keyword, then "Entry <uid>" |
| `content` | Content | Macro-converted; empty entries are kept (they can still trigger others). A leading `@@activate` makes the entry constant and `@@dont_activate` switches it off; unknown decorators are warned about |
| `key` | **Keywords** | Macro-converted, trimmed, blanks and duplicates removed. A regex (`/pattern/flags`) loses `g` (and sticky `y`, with a warning); one Mythweaver can't compile is dropped with a warning. `/r/roleplay`-style keys stay literal, as in SillyTavern |
| `keysecondary` | **Secondary keywords** | Only when `selective` is true; same rules as `key`. Otherwise the raw keys are kept aside |
| `selectiveLogic` 0/1/2/3 | **Logic**: and any / not all / not any / and all | |
| `constant` / `vectorized` | **Activation**: constant / vector, else keyword | A keyword entry with no keywords imports as constant and switched off, with a warning |
| `position` + `depth` + `outletName` | **Outlet**, **Placement** / **Depth** / custom outlet | See the position table below |
| `role` 0/1/2 (or the names) | **Role** | The at-depth message role |
| `order` | The entry's order in the book | Integers, floats (rounded) and numeric strings; anything else is 100 with a warning. When any is negative, every order shifts up by the same amount and the book's order adjustment drops by it, so effective orders stay the same |
| `disable` | Enabled in the book | |
| `probability` (+ `useProbability`) | **Trigger probability** | Clamped to 0..100; `useProbability: false` means 100 |
| `caseSensitive`, `matchWholeWords`, `scanDepth` | **Case sensitive**, **Whole words**, **Scan depth** | `null` means "use the book's setting" |
| `sticky`, `cooldown`, `delay` | **Sticky turns**, **Cooldown turns**, **Delay (messages)** | Positive integers only |
| `excludeRecursion`, `preventRecursion`, `ignoreBudget` | **Cannot be activated by recursion**, **Content does not feed recursion**, **Ignore budget** | |
| `activationOnly` | **Trigger only** | Activates and triggers others, never inserted or charged |
| `delayUntilRecursion` | **Delay until recursion level** | `true` is level 1 |
| `group`, `groupWeight`, `groupOverride`, `useGroupScoring` | Inclusion pools | Each comma-separated group joins your pool of that name (created with one slot when missing), carrying the weight, override and scoring flags. See [Inclusion pools](../lore/pools.md) |
| `characterFilter.names` / `.isExclude` | **Character filter** (include or exclude) | Matched by card file name (`.png` stripped), then by name. Unknown names get a warning; an include filter that matches nobody imports switched off |
| `stmemorybooks`, `stmbSummary`, `stmbSummaryTier`, `stmbArc`, `stmbSourceEntryUids`, `disabledBySummaryId`, `type` | Memory records | SillyTavern-MemoryBooks entries become memories of the book, with no chat or message range (so they can't be regenerated). Summaries become consolidations of their tier, linked to their sources. See [Memory](../memory/index.md) |
| Any other key | Kept aside | Written back on export |

| SillyTavern `position` | Mythweaver location |
|---|---|
| 0, `"before_char"` | Character outlet, before (text positions warned about) |
| 1, `"after_char"` | Character outlet, after |
| 2 | Author's note outlet, before |
| 3 | Author's note outlet, after |
| 4 | At depth (`depth`, default 4) |
| 5 | Examples outlet, before |
| 6 | Examples outlet, after |
| 7 | Custom outlet named after `outletName`; the outlet is created if missing. A blank name falls back to character/after, with a warning |
| other | Trigger only (SillyTavern never inserts it), with a warning |

Outlets are explained in [Outlets](../prompts/outlets.md).

**Not imported** (one warning per book; kept aside and written back on export):

- `characterFilter.tags` (the warning lists them)
- `automationId`, `triggers` (generation-type filters)
- The `match*` extra scan sources (`matchPersonaDescription`, `matchCharacterDescription`, …)
- `keysecondary` when `selective` is false (no warning)

### Card prompts

A character's **System prompt** and **Post-history instructions** (Liquid; `{{ original }}` is the replaced block's own text) go where SillyTavern puts them, per the character's **Card prompts** setting:

- **Replace the prompt's tagged block** (the default): the first block tagged *Main prompt* / *Post-history instructions* (the block's **Character override**) is replaced. A replaced post-history block keeps its trailing post-history outlet, so that lore still lands. When the tagged block is switched off or set to ignore character overrides, the card's text is unused, as in SillyTavern. A prompt with no tagged block falls back to adding.
- **Add to the prompt**: the system prompt goes ahead of the before-character lore, the post-history instructions ahead of the post-history outlet.

The built-in "Post-history instructions" block is tagged, and so are an imported preset's `main` and `jailbreak` prompts. A runtime-only character's card prompts are hidden like its description. See [Blocks](../prompts/blocks.md).

### Chats (SillyTavern `.jsonl`)

The first line is a header when it has `user_name` or `chat_metadata` and no `mes`. Every other non-blank line is a message. A chat with no messages is rejected.

| SillyTavern field | Becomes | Notes |
|---|---|---|
| Filename stem | Chat name | |
| Header `user_name` | Default player | Falls back to the most frequent `is_user` speaker |
| Message `name` | Speaker (by trimmed name) | Blank means "Unknown". Mapped in the import options; `is_user` only picks the default player |
| `extra.type == "narrator"` | Speaker defaults to **Name only** | |
| `swipes` (all strings) | Swipes | Otherwise one swipe from `mes` |
| `swipe_id` | Active swipe | Falls back to the swipe equal to `mes`, then the last one |
| `extra.reasoning` / `swipe_info[i].extra.reasoning` | The swipe's reasoning | |
| `is_system` | Hidden from the AI | Still shown in the chat |
| `send_date` | Message time | Unix ms, ISO 8601, `2024-1-5 @14h 30m 12s 345ms`, or `January 5, 2024 2:30pm`. Falls back to the previous message, then the header `create_date`, then now |
| Header `chat_metadata.mythweaver` | Embedded bundle | |

Message text is stored as written. It is never macro-converted.

**Dropped:**

- Images (`extra.image`, `inline_image`, `media`): *"N images weren't imported."*
- Every other header key: `character_name`, `create_date` (fallback only), `chat_metadata` (author's note, chat variables, linked World Info, bookmarks, …)
- Other `extra` data (token counts, `api`, `model`, `gen_started`/`gen_finished`, `bias`, `display_text`, title), `force_avatar`, `original_avatar`, `is_user` (beyond the default player)
- `swipe_info` beyond reasoning (per-swipe dates and generation metadata)

### Chat Completion presets

The prompts are read in `prompt_order` order: the order for `character_id` 100001, else 100000, else the first one, else the `prompts` list as is. An order item's `enabled` sets the block's enabled flag in the new prompt. Each block is named *"<preset>: <prompt name>"*. Prompt text is macro-converted.

| SillyTavern prompt / key | Becomes |
|---|---|
| `worldInfoBefore` / `worldInfoAfter` markers | Standard lore-before / lore-after blocks |
| `charDescription` | Standard character block |
| `personaDescription` | Standard player block |
| `charPersonality`, `scenario` markers | Nothing: imported cards put personality and scenario in the card book, which the character block already renders |
| `dialogueExamples` + `new_example_chat_prompt` | Standard example-dialogue block with that header (default `[Example chat]`) |
| `chatHistory` + `new_chat_prompt` / `new_group_chat_prompt` | A "Start of chat" block, a chat-history block, then "Guide" and "Author's note" blocks |
| `main` | Template block tagged *Main prompt* (a card's system prompt replaces it); `forbid_overrides` carried over |
| `jailbreak` | Its text plus the standard post-history outlet, tagged *Post-history instructions*; `forbid_overrides` carried over |
| Any other prompt | Template block with its `content` and `role` (`system`/`user`/`assistant`). An empty prompt keeps its place as a Liquid comment |
| Prompt with `injection_position: 1` (in-chat) | Placed right after chat history, with a warning naming the depth it had |
| `group_nudge_prompt` | "Group nudge" block (only when set) |
| (always) | A final "Refine" block |
| `temperature`, `top_p`, `top_k`, `top_a`, `min_p`, `repetition_penalty`, `frequency_penalty`, `presence_penalty`, `openai_max_tokens` (→ max tokens), `seed` | The chosen model's samplers, only when a model is picked in **Model samplers**. Out-of-range values are skipped with a warning; a negative seed is ignored. See [Models](../ai/models.md) |

**Dropped:**

- With a warning, when customized: `impersonation_prompt`, `continue_nudge_prompt`, `assistant_prefill`, `assistant_impersonation`, `wi_format`, `scenario_format`, `personality_format` (*"Not imported: …"*)
- Silently: `injection_depth` and `injection_order` (in-chat prompts lose their depth), `system_prompt`/`marker` flags, prompt orders for other characters, and every other preset setting: API source and model, context size, streaming, `names_behavior`, `squash_system_messages`, `wrap_in_quotes`, `bias_preset_selected`/logit bias, reasoning effort, function calling, image inlining, `continue_prefill`, `send_if_empty`, `stream_openai`, `max_context_unlocked`, …
- Sampler keys not in the table above (`typical_p`, `tfs`, …)

## Exporting

### To export items

1. Open **Export** at `/export`. Pick items from the kind tabs (Characters, Lore books, Prompts, AI models, Scripts, Memory profiles, Side prompts, Side prompt sets, Chats). You can filter the list and Shift-click to select a range. Hidden and runtime-only site items aren't listed. Chats are your own role-play chats.
2. The side panel lists your selection, the counts of everything the file will carry (what the selection owns: a character's books and entries, a chat's participants, transcript and files, …), and warnings about lore left out.
3. Pick a **Format**. **Mythweaver bundle** is always offered. With exactly one item selected, its SillyTavern formats are offered too (table below).
4. Click **Export** to download the file. Export warnings (leftover Liquid, a missing avatar, attachments left out) are shown on the page.

| Selection | Formats |
|---|---|
| One character | **Character card (PNG)**, **Character card (JSON)**, **Character card (CHARX)** |
| One lore book | **SillyTavern World Info** |
| One prompt | **SillyTavern preset**, plus **Samplers from**: a model whose sampler values go in the file |
| One chat | **SillyTavern chat** |

PNG is unavailable when the avatar isn't a PNG and the image proxy can't convert it.

Every outside file embeds the whole bundle under `extensions.mythweaver` (cards, World Info, presets) or `chat_metadata.mythweaver` (chats), unless you uncheck **Include Mythweaver data**. Re-importing an unchanged file with it is therefore lossless. The tables below describe what SillyTavern and other tools see. Fields an import kept aside are written back alongside the mapped ones.

### Macro conversion back

Text is converted back to SillyTavern macros, inverting the import table: `anchors.character.name` and the shorthand `char` → `{{char}}`, `anchors.player.name` and `user` → `{{user}}`, `anchors.participants` → `{{group}}`, the two descriptions → `{{description}}`/`{{persona}}`, `original` → `{{original}}`, `vars`/`globals` → `{{getvar::k}}`/`{{getglobalvar::k}}`, `setvar`/`setglobalvar` with a string literal → `{{setvar::k::v}}`, `roll` → `{{roll:X}}`, `split | random`/`pick` → `{{random::…}}`/`{{pick::…}}`. `{% raw %}` blocks are unwrapped verbatim. Any other Liquid (`if`, `for`, filters, other anchors, `setvar` with a non-literal value, a value containing braces) is left as is, and the export warns *"Some text uses Mythweaver templates SillyTavern can't run: …"* naming the affected fields or entries.

## Export field mapping

### Character cards (PNG, JSON, CHARX)

All three formats write a V3 card (`chara_card_v3`, `spec_version` 3.0). A PNG also writes a V2 copy in a `chara` chunk next to `ccv3`. The V2 copy is the same `data` without `group_only_greetings`.

| Mythweaver | Card field | Notes |
|---|---|---|
| **Name** | `name` | |
| **Description** | `description` | Converted |
| **First message** | `first_mes` | Converted |
| **Alternate greetings** | `alternate_greetings` | Converted |
| **Group-only greetings** | `group_only_greetings` | V3 only |
| **Creator notes**, **Creator**, **Character version** | Same | `""` when unset |
| **Talkativeness** | `extensions.talkativeness` | |
| Character tags | `tags` | |
| **System prompt**, **Post-history instructions** | `system_prompt`, `post_history_instructions` | Converted; in **Add to the prompt** mode prefixed with `{{original}}`. A blank one takes an older card book's entry (below) |
| Card book entries (see below) | `personality`, `scenario`, `mes_example`, `extensions.depth_prompt` (with the entry's role) | `[Example chat]` lines become `<START>` and the examples open with one |
| Other bound lore books | `character_book` | Merged into one book, see below |
| Avatar | PNG image / CHARX `assets/icon/images/main.<ext>` (`icon`, `name: "main"`) | JSON cards carry none (warning). A non-PNG avatar for a PNG card is converted by the image proxy; if that fails the card uses a placeholder image (warning) |

**Card book.** A bound book counts as a card book when every entry in it is one of the card-field entries the importer creates ("Personality", "Scenario", "Example dialogue", "Depth prompt", or the "System prompt" and "Post-history instructions" entries that older imports wrote), each at most once, enabled and constant. A book imported as the card's own book may have moved its entries or given them keywords; any other book must also keep each entry without keywords in that field's import location. The first such book by name is turned back into the card fields; a "System prompt" or "Post-history instructions" entry is used only when the character's own field is blank. A book with a disabled or non-constant field entry isn't a card book: it's exported as `character_book` lore with the rest, so nothing about it is lost.

**`character_book`.** Every other bound book is merged into one `character_book`, in book-name order, with duplicate entries removed. Its `name` is the book's name when there is only one, else *"<character> (lore)"*. SillyTavern ignores an embedded book's `scan_depth`, `token_budget` and `recursive_scanning`, so they're written only when the first book was imported carrying them. The first book's priority, order adjustment and token budget are written as Aikobots `stlo` the way a World Info file writes them (next section), at the top level or under `extensions`, wherever the import found it. Each entry is written like a World Info entry (next section) in V2 `character_book` shape: `keys`, `secondary_keys`, `comment`, `content`, `constant`, `selective`, `insertion_order`, `enabled`, `position` (`before_char` for position 0, else `after_char`), `use_regex: true`, and the rest under `extensions` (`position`, `depth`, `role`, `probability`, `selectiveLogic`, `outlet_name`, recursion flags, `scan_depth`, `case_sensitive`, `match_whole_words`, `sticky`, `cooldown`, `delay`, `ignore_budget`, `vectorized`, `display_index`, `group`, `group_weight`, `group_override`, `use_group_scoring`, `activation_only`, `delay_until_recursion`, `character_filter`, MemoryBooks keys).

**Omitted from the card:**

- The character's **Pronouns**, **Appearance**, avatar captioning, expression labels, fallback expression, expression profile, outfits and sprites (CHARX gets only the avatar icon)
- Entry filter tags (beyond imported ones kept aside), book filter tags
- Book-level settings: book description, global, forced, tag filter mode, and every merged book's settings but the first's `stlo`. The split into several books is lost too
- Lore bindings beyond the character (chat bindings), memory-record details other than the MemoryBooks keys
- Entry order beyond `insertion_order` (the book's order adjustment is only in `stlo`, not applied)

### SillyTavern World Info

One lore book becomes `{"entries": {"0": …, "1": …}}` in the book's entry order; `uid` and `displayIndex` follow that order. The filename is the book name.

| Mythweaver | SillyTavern entry field |
|---|---|
| Entry name | `comment` |
| Content | `content` (converted) |
| **Keywords** / **Secondary keywords** | `key` / `keysecondary` (converted); `selective` is true when there are secondary keywords. With none, an imported non-selective entry's raw `keysecondary` is written back |
| **Logic** | `selectiveLogic` |
| **Activation** | `constant` / `vectorized` |
| **Outlet** + **Placement** / **Depth** / custom outlet | `position` 0–7 (the import table in reverse), `depth`, `outletName` (the outlet's name) |
| Order / enabled in the book | `order` / `disable` |
| **Trigger probability** | `probability` (`useProbability: true`) |
| **Case sensitive**, **Whole words**, **Scan depth**, **Sticky turns**, **Cooldown turns**, **Delay (messages)** | `caseSensitive`, `matchWholeWords`, `scanDepth`, `sticky`, `cooldown`, `delay` |
| **Cannot be activated by recursion**, **Content does not feed recursion**, **Ignore budget** | `excludeRecursion`, `preventRecursion`, `ignoreBudget` |
| **Character filter** (include/exclude + characters) | `characterFilter` `{isExclude, names: ["<card file name or name>"], tags}` (card-book entries: `extensions.character_filter`); `tags` are the imported ones kept aside, else empty |
| **Role** | `role` 0/1/2 |
| **Trigger only** | `activationOnly` (SillyTavern ignores it; the export warns) |
| **Delay until recursion level** | `delayUntilRecursion` (the level, else `false`) |
| Inclusion pools | `group` (pool names joined by `,`), `groupWeight` (the first pool's), `groupOverride`, `useGroupScoring` (`true`, else `null`) |
| Book **Priority**, **Order adjustment**, **Token budget** | Aikobots `stlo` `{priority, orderAdjustment, budgetMode, budget}`, written when any differs from the default or the imported file had `stlo` |
| Memory records | `stmemorybooks`; consolidations add `stmbSummary`, `stmbSummaryTier`, `stmbSourceEntryUids`; consolidated sources get `disabledBySummaryId` |

The file also gets `addMemo: true`.

**Omitted:**

- Book-level fields with no SillyTavern or Aikobots equivalent: description, global, forced, scan depth, recursion, tag filter and filter tags, and bindings to characters and chats (the book's name survives only as the filename)
- Entry filter tags, beyond imported ones kept aside
- Memory-record details beyond the MemoryBooks keys: chat, message range, profile, prompt, canonical link

### SillyTavern preset

The prompt's blocks become `prompts` plus one `prompt_order` (`character_id` 100001), in order, with `enabled` true only when the block is enabled both itself and in the prompt. The *"<prompt>: "* name prefix the importer adds is removed.

| Mythweaver block | SillyTavern |
|---|---|
| Standard lore-before / lore-after | `worldInfoBefore` / `worldInfoAfter` markers |
| Standard character / player | `charDescription` / `personaDescription` markers |
| Standard example dialogue | `dialogueExamples` marker + `new_example_chat_prompt` |
| Chat-history block | `chatHistory` marker |
| "Start of chat" block | `new_chat_prompt` + `new_group_chat_prompt` |
| "Group nudge" block | `group_nudge_prompt` |
| Block tagged *Main prompt* | `main` prompt (`system_prompt: true`) |
| Block tagged *Post-history instructions*, or ending in the standard post-history outlet | `jailbreak` prompt with the text before the outlet |
| Any other template block | A prompt with `content` (converted) and `role` |
| Standard guide, author's note and refine blocks | Omitted: the importer adds them again |
| **Samplers from** model | `temperature`, `top_p`, `top_k`, `top_a`, `min_p`, `repetition_penalty`, `frequency_penalty`, `presence_penalty`, `openai_max_tokens`, `seed` (unset values left out) |

Each marker or setting is written once. A second block of the same standard kind is exported as a plain prompt.

**Omitted:**

- The prompt's description, enabled flag, purpose, thinking settings and bindings (which characters or chats use it)
- Block descriptions and speaker roles
- Placement: every prompt is written with `injection_position: 0` and `injection_depth: 4`, so an imported in-chat prompt comes back as a relative one
- Sampler fields outside the table (and the model itself)
- Guide, author's note and refine blocks, including any edits to their text

### SillyTavern chat

A header line, then one line per message.

| Mythweaver | SillyTavern |
|---|---|
| Player character's name | Header `user_name` |
| First participant who isn't the player | Header `character_name` |
| First message's time (else now) | Header `create_date` |
| Author character's name (else the stored speaker name, else "Unknown") | `name` |
| Author is the player | `is_user` |
| Hidden from the AI | `is_system: true` |
| Message time | `send_date` (ISO 8601) |
| Swipes | `swipes`, `swipe_id`, `mes` (the active swipe) |
| Swipe reasoning | `extra.reasoning` (active) and `swipe_info[i].extra.reasoning`; `swipe_info[i].send_date` is the swipe's time |

Message text is written as stored, with no macro conversion.

**Omitted:**

- Attachments (warning: *"Attachments aren't part of SillyTavern chats and were left out."*)
- Swipe origin, guide, finish reason and other generation metadata; expressions
- Everything chat-level other than the names above: participant list and order, per-participant model, mute and talkativeness, the chat's model, prompt and bound books, injections, chat variables, memory settings and memory records, turn-taking settings
- Drafts are never exported

SillyTavern groups chats by character, so a group chat opens in SillyTavern as a one-on-one chat with `character_name`. The other speakers keep only their `name` on each line.
