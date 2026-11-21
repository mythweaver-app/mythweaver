---
title: Settings
order: 2
description: How settings cascade from the built-in default to the site to you, how admins lock them, and every setting on the Settings page.
---

**Settings** at `/settings` holds the preferences that shape how Mythweaver behaves for you: which model replies by default, how lore and memories work, image descriptions, expressions, notifications and appearance. Every change saves as soon as you make it.

## How a value is chosen

Each setting has up to three layers, and the most specific one that is set wins:

1. **The built-in default**, the value Mythweaver ships with.
2. **The site value**, set by an admin for everyone on the site.
3. **Your value**, set by you for yourself.

So a site value replaces the built-in default for everyone who hasn't chosen their own, and your value replaces the site value for you alone. A row you have changed shows a **Modified** badge. Its **Reset** button removes your value, so the row falls back to the site value (or the built-in default).

Some settings exist at one level only. The tables below say which:

| Levels | Meaning |
| --- | --- |
| User and site | Admins set a site value; each user may override it unless it is locked. |
| Site only | Only admins set it, for the whole site. It never appears on the **User** tab. |
| User only | Only each user sets it, for themselves. It never appears on the **Site** tab. |

Several settings are also defaults for things that can set their own value: a character or chat that names a model, a lore entry that sets its own scan depth, or a chat with its own memory settings wins over the setting.

## To change a setting

1. Open **Settings** at `/settings`.
2. Pick a category in the list on the left, or type in **Search settings…** to find a setting by name or description.
3. Change the control. The value saves at once.
4. To go back to the inherited value, select **Reset** beside the control.

A category has its own address, such as `/settings/notifications`.

## Site settings and locks

If you hold the `site.settings.manage` permission, the page shows two tabs, **User** and **Site**. **User** edits your own values, like everyone else. **Site** edits the site values that apply to every user who hasn't overridden them.

On the **Site** tab, each setting users may change has a **Users may change** checkbox (in the notification grid it is a lock button). Clear it to lock the setting:

- Every user reads the site value, whatever they had chosen.
- On their **User** tab the row shows **Locked by an admin**, and they can neither change nor reset it.
- Their own stored values are kept. Unlocking brings them back.

> [!NOTE]
> Only settings marked "User and site" can be locked. Site-only settings need no lock, because users never see them.

## Models

Defaults for which model replies and how replies are trimmed and cleaned. See [Models](../ai/models.md) for how a reply picks its model.

### Defaults

| Setting | Key | Levels | Default | What it does |
| --- | --- | --- | --- | --- |
| **Default model** | `ai.default_model` | User and site | Automatic | Runs replies and memory jobs when neither the character, the chat nor the memory profile names a model. Automatic uses the only model that can run, and asks for a pick when there are several. |
| **Mythweaver model** | `assistant.model` | User and site | Automatic | Runs the Mythweaver assistant chat when the conversation names no model of its own. Automatic uses the default model. It must be a chat-mode model; one that supports tools works best, others use a text fallback. |

### Context

| Setting | Key | Levels | Default | What it does |
| --- | --- | --- | --- | --- |
| **Max context** | `generation.max_context` | User and site | 0 | The most tokens a reply's prompt may use, response tokens included. The oldest chat history is left out to fit. The smaller of this and the model's context window applies. 0 uses the model's context window alone; a model with neither is never trimmed. A model with no response tokens set keeps 1024 free for the reply. |
| **Trim in steps of** | `generation.trim_step` | User and site | 10 | When old history has to go, it goes this many messages at a time, so the start of the history stays put for several replies and a local model's prompt cache can reuse it. 1 trims one message at a time. |

### Stop strings

| Setting | Key | Levels | Default | What it does |
| --- | --- | --- | --- | --- |
| **Stop at other speakers' names** | `generation.names_as_stop_strings` | User and site | On | Ends a reply where it starts another participant's line, such as "Bob:". Text-completion models are also sent the names as stop strings. |
| **Single-line replies** | `generation.single_line` | User and site | Off | Ends every reply at its first line break. Text-completion models are also sent the line break as a stop string. |

### Reply text

| Setting | Key | Levels | Default | What it does |
| --- | --- | --- | --- | --- |
| **Remove the speaker's own name** | `generation.trim_own_name` | User and site | On | Drops the replying character's name and colon where a reply starts a line with it, such as "Alice:" in Alice's reply. Off, replies keep it as written. |

### Swipes

| Setting | Key | Levels | Default | What it does |
| --- | --- | --- | --- | --- |
| **Swipes per reply** | `generation.swipes_per_generation` | User and site | 1 | How many swipes one reply or regenerate produces. Extra swipes are generated one after another, before anyone else replies, and each is a full request. Continue, refine, script-started regenerations and replies written as your own character always make one. |

### Cleanup

Old messages carry data that is only useful while they are recent. Cleanup removes it. The section also has a **Clean up my chats** row (on the **Site** tab, **Clean up all chats**) with a **Clean up now** button that runs a cleanup at once with the values shown, whether or not automatic cleanup is on.

| Setting | Key | Levels | Default | What it does |
| --- | --- | --- | --- | --- |
| **Automatic cleanup** | `cleanup.automatic` | User and site | On | Cleans up a chat's old messages on their own as the chat grows. Off, they are cleaned only when you clean up by hand. |
| **Clean up messages older than** | `cleanup.after_messages` | User and site | 100 | Messages further back than this many lose their prompt inspection data, their reasoning text and their inactive swipes' embeddings, and their near-identical swipes are merged. |
| **Clean up every** | `cleanup.every_messages` | User and site | 10 | How many messages a chat gets between automatic cleanups. |
| **Merge swipes at similarity %** | `cleanup.swipe_similarity` | User and site | 80 | Two swipes of an old message at least this similar keep only the newer one. The swipe being shown is always kept. |

> [!WARNING]
> Cleanup is permanent. Prompt inspection data, reasoning text and merged swipes of cleaned messages cannot be brought back.

## Lore

Defaults for lore entries that don't set their own value. See [Lore](../lore/index.md).

### Keyword matching

| Setting | Key | Levels | Default | What it does |
| --- | --- | --- | --- | --- |
| **Scan depth** | `lore.scan_depth` | User and site | 2 | Recent messages searched for keywords when neither the entry nor its book sets a scan depth. |
| **Case-sensitive keywords** | `lore.case_sensitive` | User and site | Off | Matches keywords case-sensitively when an entry does not say. |
| **Match whole words** | `lore.match_whole_words` | User and site | On | Keywords match only whole words when an entry does not say. |
| **Word boundary** | `lore.word_boundary` | User and site | ASCII (SillyTavern) | What ends a word for whole-word matching: **ASCII (SillyTavern)** or **Unicode**. ASCII treats every non-ASCII character as a separator, so Japanese or Chinese keys match inside sentences. |

### Activation limits

| Setting | Key | Levels | Default | What it does |
| --- | --- | --- | --- | --- |
| **Activation passes** | `lore.max_recursion_steps` | User and site | 0 | The most activation passes per reply, the first included. Entries activated in one pass can trigger more in the next. 0 means no limit: passes continue until one activates nothing. |
| **Lore budget (% of context)** | `lore.token_budget_percent` | User and site | 25 | The share of the reply's context limit (the smaller of the model's context window and **Max context**) lore may use. |
| **Lore budget cap** | `lore.token_budget` | User and site | 0 | The most tokens of lore in one prompt, whatever the percentage gives. 0 means no cap. When the context limit is unknown, this cap applies, or 15,000 tokens when it is 0. |
| **After the budget overflows** | `lore.overflow` | User and site | Stop (SillyTavern) | **Stop (SillyTavern)** admits nothing more once one entry doesn't fit, except entries that ignore the budget. **Keep filling** keeps trying smaller entries. |

### Placement

| Setting | Key | Levels | Default | What it does |
| --- | --- | --- | --- | --- |
| **Default insertion depth** | `lore.default_depth` | User and site | 4 | How many messages from the end an at-depth entry goes when it names no depth. |

### Vector matching

| Setting | Key | Levels | Default | What it does |
| --- | --- | --- | --- | --- |
| **Embedding model** | `lore.embedding_model` | User and site | None | Turns Vector lore entries and recent messages into embeddings, so those entries activate on similar meaning. **None** leaves Vector entries to their keywords. |
| **Minimum similarity %** | `lore.vector_threshold` | User and site | 25 | How similar, in percent, the scanned messages must be to a Vector entry for it to activate. |
| **Most vector activations** | `lore.vector_max_entries` | User and site | 5 | The most Vector entries activated by similarity per reply, most similar first. Entries their keywords activate don't count. |

## Memory

Defaults for Memory Books. A chat can set its own values for the automatic memory settings. See [Memory](../memory/index.md).

### Memories

| Setting | Key | Levels | Default | What it does |
| --- | --- | --- | --- | --- |
| **Review memories before saving** | `memory.show_previews` | User and site | On | Shows a generated memory for review before it is saved to the memory book. |
| **Review consolidations before saving** | `memory.show_consolidation_previews` | User and site | On | Shows a consolidated memory for review before it replaces its sources. |
| **Token warning threshold** | `memory.token_warning_threshold` | User and site | 30,000 | Asks before sending a memory request estimated at more than this many tokens: the prompt, earlier memories, additional context and the scene together. |
| **Previous memories sent by default** | `memory.default_previous_count` | User and site | 1 | How many earlier memories accompany a scene when a new memory is written. |
| **Allow overlapping scenes** | `memory.allow_overlap` | User and site | Off | Lets a new scene include messages an earlier memory already covers. |
| **Include messages hidden from the AI** | `memory.include_hidden` | User and site | Off | Sends messages hidden from the AI when writing a memory of their scene. |
| **Processed boundary** | `memory.boundary_indicator` | User and site | Divider | Marks the last message already covered by a memory in the chat: **Divider** or **Off**. |

### Automatic memories

| Setting | Key | Levels | Default | What it does |
| --- | --- | --- | --- | --- |
| **Trigger** | `memory.auto_trigger` | User and site | Every N messages | What starts an automatic memory in a chat that has them on: **Every N messages** or **Token threshold**. |
| **Interval** | `memory.auto_interval` | User and site | 30 | With the message trigger: how many new messages past the processed boundary, not counting the buffer, make a memory. |
| **Buffer** | `memory.auto_buffer` | User and site | 2 | How many of the newest messages an automatic memory leaves out of its scene, so the latest exchange can still change. |
| **Token threshold** | `memory.auto_token_threshold` | User and site | 8000 | With the token trigger: how many tokens of new messages past the processed boundary, not counting the buffer, make a memory. |

### Reminders

| Setting | Key | Levels | Default | What it does |
| --- | --- | --- | --- | --- |
| **Manual reminders** | `memory.manual_reminders` | User and site | Off | Reminds you to make memories when automatic memories are off. |
| **Manual reminder interval** | `memory.manual_reminder_interval` | User and site | 50 | Unprocessed messages before the first reminder, and between reminders. |
| **Automatic reminders** | `memory.auto_reminders` | User and site | Off | Reminds you when automatic memories fall behind. |
| **Automatic reminder interval** | `memory.auto_reminder_interval` | User and site | 10 | Messages past the automatic interval and buffer before the first reminder, and between reminders. |

### Consolidation

| Setting | Key | Levels | Default | What it does |
| --- | --- | --- | --- | --- |
| **Announce when ready** | `memory.consolidation_watch_tiers` | User and site | All tiers | Tiers whose readiness to consolidate is announced in the chat, in a notice linking to the Consolidate tab, once a tier has its minimum of eligible entries. |
| **Arc minimum** | `memory.consolidation_minimum_1` | User and site | 5 | How many eligible entries make the arc tier ready to consolidate. |
| **Chapter minimum** | `memory.consolidation_minimum_2` | User and site | 4 | How many eligible entries make the chapter tier ready to consolidate. |
| **Book minimum** | `memory.consolidation_minimum_3` | User and site | 4 | How many eligible entries make the book tier ready to consolidate. |
| **Legend minimum** | `memory.consolidation_minimum_4` | User and site | 3 | How many eligible entries make the legend tier ready to consolidate. |
| **Series minimum** | `memory.consolidation_minimum_5` | User and site | 3 | How many eligible entries make the series tier ready to consolidate. |
| **Epic minimum** | `memory.consolidation_minimum_6` | User and site | 3 | How many eligible entries make the epic tier ready to consolidate. |
| **Max entries per pass** | `memory.consolidation_max_entries` | User and site | 20 | The most entries one consolidation pass reads; more are split into further passes. |
| **Token budget per pass** | `memory.consolidation_token_budget` | User and site | 12,000 | The most tokens of entries one consolidation pass reads; more are split into further passes. |

### Rollback on message deletion

| Setting | Key | Levels | Default | What it does |
| --- | --- | --- | --- | --- |
| **Roll back memories when a message is deleted** | `memory.rollback_enabled` | User and site | Off | Deleting a message a memory covers undoes that memory's effects. |
| **Scope** | `memory.rollback_scope` | User and site | Memories covering the message | Which memories a deleted message rolls back: **Memories covering the message** or **Every later memory**. |
| **Move the boundary back** | `memory.rollback_update_boundary` | User and site | On | Moves the processed boundary back to before the deleted message. |
| **Delete affected memories** | `memory.rollback_delete_memories` | User and site | On | Deletes the memories the rollback covers from the memory book. |
| **Restore side-prompt entries** | `memory.rollback_restore_side_prompts` | User and site | On | Restores side-prompt entries to the versions before the rolled-back memories. |

### Side prompts

| Setting | Key | Levels | Default | What it does |
| --- | --- | --- | --- | --- |
| **Keep side-prompt versions** | `memory.side_prompt_versioning` | User and site | Off | Keeps each earlier version of a side-prompt entry when it is rewritten. |
| **Default side prompt set (solo chats)** | `memory.side_prompt_set_solo` | User and site | None (individual side prompts) | One-character chats left on Default run this set's rows after memories and on intervals, instead of individually enabled side prompts. |
| **Default side prompt set (group chats)** | `memory.side_prompt_set_group` | User and site | None (individual side prompts) | The same for group chats. |

### Memory assistance

| Setting | Key | Levels | Default | What it does |
| --- | --- | --- | --- | --- |
| **Memory assistance** | `memory.assistance_mode` | User and site | Off | After each new memory, reviews the book's clips against the scene. Options: **Off**, **Suggest clip updates**, **Suggest new topics**, **Suggest updates and new topics**, **Apply clip additions automatically**. Suggestions wait in Reviews; the automatic mode adds clip lines itself and leaves topical clip rewrites for review. |

## Images

How images, audio and video attachments are described for models and readers. See [Images and attachments](../images/index.md).

### Image descriptions

| Setting | Key | Levels | Default | What it does |
| --- | --- | --- | --- | --- |
| **Review image descriptions before sending** | `images.review_captions` | User and site | On | Describes images as they are attached and holds Send until each description is ready to check and edit. Off, images are described in the background after sending. |
| **Default caption model** | `images.default_caption_model` | Site only | Automatic | Describes avatars, and AI-generated images in chats where no participant has a caption model. Automatic picks the first caption-capable site model by name. |
| **Describe images automatically** | `images.auto_caption` | User and site | On | Describes chat images, audio and video as they are attached, sent or needed for a reply, older attachments past a model's inline limits, and new avatars. Off, an attachment is described only when someone asks. |
| **Ask every time** | `images.ask_every_time` | User and site | Off | Before each description someone starts, or that starts as an image is attached or sent, asks for a question to send instead of the caption prompt. Leave the question blank for the usual description. Background descriptions use the caption prompt. |
| **Review captions before saving** | `images.review_results` | User and site | Off | Holds each finished description of a sent attachment until it is saved, edited or discarded. A reply waiting on one keeps waiting until it is resolved or the reply is stopped. |

### Avatars

| Setting | Key | Levels | Default | What it does |
| --- | --- | --- | --- | --- |
| **Update Appearance when the avatar changes** | `images.avatar_updates_appearance` | User and site | On | Writes a new avatar's description into the character's Appearance. In the character editor it fills the field before you save, and Revert puts back what was there. Off, new avatars are not described automatically (Describe avatar still works). Each character can override this. |
| **Avatar caption prompt** | `images.avatar_caption_prompt` | Site only | Built-in instruction | The prompt the default caption model gets to describe an avatar, in place of its own caption prompt, since an avatar has no chat scene. |

### Image text

| Setting | Key | Levels | Default | What it does |
| --- | --- | --- | --- | --- |
| **Image text** | `images.caption_template` | User and site | Empty (built-in) | What a model that can't see an image reads in its place, and what lore and memory read. Liquid, with `caption` (nil until described), `user` (who sent it) and `char` (who is replying). Empty uses the default, `[Image: caption]` or `[Image]`. |

## Expressions

Emotion classification for characters with expression sprites. See [Expressions and sprites](../characters/expressions.md).

### Classification

| Setting | Key | Levels | Default | What it does |
| --- | --- | --- | --- | --- |
| **Classifier model** | `expressions.classifier_model` | User and site | None (expressions off) | Rates the emotions of each reply and each message you send, and shows the matching sprite in place of the portrait. A chat or text model is asked once per message and the call shows in Jobs. A classifier model (a GoEmotions sequence classifier served by llama-server) scores it directly in milliseconds and rates only the 28 base emotions. |
| **Classifier instruction** | `expressions.classifier_prompt` | User and site | Empty (built-in) | What the classifier model is told before the message. Liquid, with `labels` (the emotions to rate, comma separated) and `char` (the character's name). It must ask for `{"scores": {emotion: 0-100}}`. |
| **Ask for structured output** | `expressions.structured_output` | User and site | Off | Sends a JSON schema with each request, for backends that support `response_format`. |

### Sprites

| Setting | Key | Levels | Default | What it does |
| --- | --- | --- | --- | --- |
| **Default rule profile** | `expressions.default_profile` | User and site | None (base emotions only) | The combination and range rules for characters that don't pick their own profile. |
| **Avoid repeating a sprite** | `expressions.reroll_if_same` | User and site | On | When an expression has several sprites, doesn't show the one the character's previous message used. |

## Notifications

Popups, sounds and push. See [Notifications](notifications.md) for how they behave.

### General

| Setting | Key | Levels | Default | What it does |
| --- | --- | --- | --- | --- |
| **Mute all notifications** | `notifications.muted` | User and site | Off | Silences every notification: no popups, no sounds and no push. Each kind keeps its own settings for when you unmute. The notifications inbox still lists them. |
| **Show message text in push notifications** | `notifications.push_preview` | User and site | On | Off, a push notification names the chat and character but not what they wrote, for a lock screen others can see. Shown only while Web Push is set up. |

### Events

This section is a grid: one row per kind of event, with a **Notification** checkbox, a **Sound** toggle (with a **Play this sound** preview) and, while Web Push is set up, a **Push** checkbox.

| Row | Keys | Default | When it fires |
| --- | --- | --- | --- |
| **New messages** | `notifications.new_message.popup`, `.sound`, `.push` | All on | A character's new reply finishes. |
| **Regenerations** | `notifications.regenerate.popup`, `.sound`, `.push` | All on | A regenerated swipe or a rewrite finishes. Several swipes from one request notify once, after the last. |
| **Continues** | `notifications.continue.popup`, `.sound`, `.push` | All on | A continued message finishes. |
| **Memory reviews** | `notifications.memory_review.popup`, `.sound`, `.push` | All on | A memory draft is waiting for your review in the chat's Memory → Reviews. |

All of these are "User and site" settings. On the **User** tab, while Web Push is set up, the category also shows your **Push devices**.

## Appearance

Language, theme and custom stylesheets. See [Appearance](appearance.md) for how each is applied.

### Language and region

| Setting | Key | Levels | Default | What it does |
| --- | --- | --- | --- | --- |
| **Language** | `appearance.language` | User only | Match my browser | The language of the app's text. Only languages the app has a translation for are listed. |
| **Regional format** | `appearance.locale` | User only | Match my browser | How numbers, dates, times and money are written, whatever the language. |
| **Default language** | `appearance.default_language` | Site only | Built-in default (English) | The language for anyone whose browser asks for none the app has a translation for, and in notifications to people who have not chosen one. |
| **Default regional format** | `appearance.default_locale` | Site only | Built-in default (English) | How numbers, dates and money are written for anyone whose browser asks for no supported region, and in notifications to people who have not chosen one. |

### Theme

| Setting | Key | Levels | Default | What it does |
| --- | --- | --- | --- | --- |
| **Primary hue** | `appearance.primary_hue` | User and site | 263 | The hue every color in the app is tinted with, from 0 to 359 degrees around the color wheel. |
| **Tint strength** | `appearance.tint_strength` | User and site | 100 | How strongly backgrounds, surfaces and borders take on the primary hue, as a percentage: 0 is neutral grey, 100 the default. |

### Chat avatars

| Setting | Key | Levels | Default | What it does |
| --- | --- | --- | --- | --- |
| **Largest avatar width** | `appearance.avatar_max_width` | User and site | 300 | The widest, in pixels, a chat message's portrait or expression sprite grows on a wide screen. |
| **Largest avatar height** | `appearance.avatar_max_height` | User and site | 400 | The tallest, in pixels, a portrait or sprite grows. A portrait keeps its 3:4 shape, so this also narrows it. |

### Stylesheets

| Setting | Key | Levels | Default | What it does |
| --- | --- | --- | --- | --- |
| **Site stylesheet** | `appearance.site_css` | Site only | Empty | CSS for every page, for everyone, signed-out pages included, applied before each user's own. |
| **Extra stylesheet sources** | `appearance.extra_sources` | Site only | Empty | Origins the site stylesheet may load stylesheets, fonts and images from, besides the app and the allowed font services, separated by spaces or new lines (at most 20). Users' stylesheets may load from them too. |
| **Restrict user stylesheets** | `appearance.restrict_user_css` | Site only | On | Users' stylesheets may not load anything from outside the app (no `url()`, `image-set()`, `@import` or similar), except font stylesheets while third-party fonts are allowed. Turn off to let users write any CSS. |
| **Allow third-party fonts** | `appearance.allow_third_party_fonts` | Site only | On | Restricted user stylesheets may still `@import` a Google Fonts stylesheet. The font service sees each visitor's IP address. Has no effect while user stylesheets are unrestricted. |
| **Your stylesheet** | `appearance.user_css` | User only | Empty | CSS for every page you see, applied after the site's. |

### Remote images

| Setting | Key | Levels | Default | What it does |
| --- | --- | --- | --- | --- |
| **Remote images in messages** | `appearance.remote_images` | Site only | Through this server | How images a message links from other sites are shown. **Through this server**: the image's site sees the server's address instead of each reader's. **Directly from their site**: it sees every reader's address and can tell who read the message. **Off: don't show them** hides them. |
