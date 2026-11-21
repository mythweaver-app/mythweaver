---
title: Script API reference
order: 1
description: Every mw.* and regex.* function available to Lua scripts, and the event table each trigger receives.
---

This page lists everything a script can use: the `event` table each trigger passes in, and the `mw.*` and `regex.*` functions. For how to create scripts, triggers, run order and limits, see [Scripts](index.md).

## Conventions

Every function follows the same return rules:

- **Success** returns the value: a record table, a list of them, or `true` for toggles and deletes.
- **Refusal** returns two values, `nil` and a reason string such as `"not_found"`. Check for it:

  ```lua
  local msg, err = mw.messages.get(id)
  if not msg then print("could not read: " .. err) return end
  ```

- **A malformed call** (wrong argument types, a bad regex) raises an error. Catch it with `pcall` if you need to.

Message numbers are the `#N` the chat shows, from 1. Ranges such as `first, last` include both ends.

### Common refusals

| Reason | When |
| --- | --- |
| `"no_permission"` | The person the script runs for lacks the namespace's script permission (see [Script permissions](index.md#script-permissions)). Reads are never refused this way. |
| `"no_chat"` | A chat function was called with no chat, such as a command picked off a chat page. |
| `"test_run"` | A function that writes data or needs a chat was called in **Run test**. |
| `"not_allowed"` | A function that starts a generation, memory job or image request was called from a trigger that may not. |
| `"not_found"` | The id names nothing you may use. |
| `"not_in_chat"` | A character is neither the chat's player nor a participant. |
| `"generating"` | The message is being generated. |
| `"held_for_review"` | Content moderation held a character or lore write for review. |
| `"hold_limit"` | Too much of your content is already held for review. |

### Targets

`mw.messages.delete`, `set_visible` and `select` take a **target**, which is one of:

| Target | Example |
| --- | --- |
| A message id | `"0b6e…"` |
| A message number | `12` |
| A range of numbers, both ends included | `"3-7"` |
| A list of any of these | `{1, "4-6", id}` |

### Records

| Record | Fields |
| --- | --- |
| Message | `id`, `number`, `position` (the same as `number`), `character_id`, `author = {id, name}`, `author_is_player`, `text`, `visible_to_ai`, `generating`, `version`, `version_count`, `created_at`. `author.id` is `nil` for a speaker with no character (an imported speaker, a narrator or a deleted character). |
| Version | `index` (from 1), `text`, `active`, `origin` (`"original"`, `"edit"`, `"continue"`, `"regenerate"`, `"refine"`, `"split"`, `"merge"` or `"append"`), `generating`, `created_at`. |
| Image | `id`, `message_id`, `content_type`, `width`, `height`, `description`, `caption_status` (`"none"`, `"pending"`, `"done"`, `"failed"`), `url`. The `url` is a signed link that expires (within two days by default); fetch it again rather than storing it. |
| Character | `id`, `name`, `description`, `pronouns`, `appearance`, `creator`, `creator_notes`, `character_version`, `talkativeness`, `site_visibility`. `description` and `appearance` are `nil` when a site character's content is hidden from you. |
| Prompt | `id`, `name`, `enabled`, `purpose`, `site_visibility`, `blocks`. Each block has `id`, `name`, `enabled` (its switch in this prompt), `block_enabled` (its own switch), `site_visibility`. |
| Lore book | `id`, `name`, `description`, `global`, `priority`, `order_adjustment`, `token_budget`, `scan_depth`, `recursive`, `site_visibility`, `forced`. `mw.lore.book` adds `entries`. |
| Lore entry | `id`, `name`, `content`, `keywords`, `activation`, `book_id`, `enabled`, `order`. `content` and `keywords` are `nil` when the book's content is hidden from you. |
| Injection | `id`, `key`, `content`, `position`, `depth`, `role`, `condition`, `enabled`, `uses`, `remaining`, `order`, `active` (whether it applies to the next generation). |
| Memory job | `id`, `tag`, `status`, `label`, `range_start`, `range_end`. |

## Events

Every script gets a global `event` table. Every event has these fields:

| Field | Type | What it holds |
| --- | --- | --- |
| `trigger` | string | The trigger that ran this script, such as `"user_message"`. |
| `chat_id` | string | The chat the event happened in. `mw.messages.*`, `mw.generation.*`, `mw.memory.*`, `mw.vars.*` and `mw.injections.*` act on it. |

### user_message

**Outgoing user message.** Runs when the player sends a message or saves an edit, before it is stored. Blank text with no images skips scripts. Only the chat owner's own messages run them.

| Field | Type | What it holds |
| --- | --- | --- |
| `text` | string | The message text after template rendering. An earlier script may already have rewritten it. |
| `character_id` | string | The author: the chat's player for a new message, the message's author for an edit. |
| `message_id` | string or nil | The edited message, or `nil` for a new message. |
| `edit` | bool | `true` when an existing message is being edited. |
| `images` | array of string | The ids of the images sent with the message (already stored, so `mw.images.get` and `mw.images.caption` work on them), or the edited message's images. |

Return a string to replace the text, or nothing to keep it. Returning blank text cancels a send unless images are attached; a blank edit is refused.

```lua
return event.text .. " *waves*"
```

### ai_generation

**Incoming AI generation.** Runs when an AI reply finishes successfully, before it is saved. A stopped or failed reply runs no scripts.

| Field | Type | What it holds |
| --- | --- | --- |
| `text` | string | The reply's full text. A continue includes the original text before the new part. An earlier script may already have rewritten it. |
| `message_id` | string | The message the reply is written into. |
| `character_id` | string | The character who spoke. |
| `mode` | string | `"new"`, `"regenerate"`, `"continue"` or `"refine"`. |
| `script_triggered` | bool | `true` when a script started this generation through `mw.generation.*`. |

Return a string to replace the saved text, or nothing to keep it. The prompt inspector still shows what the model sent. `mw.generation.*` is refused here.

```lua
return (event.text:gsub("%s+$", ""))
```

### lore_activated

**Lore book activated.** Runs when a generation activates lore, after the lore is resolved and before the prompt is sent.

| Field | Type | What it holds |
| --- | --- | --- |
| `character_id` | string | The character about to speak. |
| `books` | array of `{id, name}` | Each book with at least one activated entry, once. |
| `entries` | array of `{id, name, book_id}` | Every activated entry, with the book it activated from. |
| `script_triggered` | bool | `true` when a script started this generation through `mw.generation.*`. |

Return values are ignored. Changes to lore or prompts apply from the next generation, because this one's prompt is already built. `mw.generation.*` is refused here.

```lua
for _, e in ipairs(event.entries) do
  mw.lore.set_entry_enabled(e.book_id, e.id, false)
end
```

### image_described

**Image described.** Runs when an image in a chat gets a description: from a caption model, typed by a person, or set by a script outside this trigger. It runs before replies waiting on the caption read it. Avatars run no scripts, and only the chat owner's own descriptions run them.

| Field | Type | What it holds |
| --- | --- | --- |
| `text` | string | The new description. An earlier script may already have rewritten it. |
| `image_id` | string | The described image. |
| `message_id` | string or nil | The message the image belongs to, or `nil` for an image still in the composer. |
| `by` | string | `"model"`, `"person"` or `"script"`. |
| `model_id` | string or nil | The caption model, when `by` is `"model"`. |
| `tag` | string or nil | The `tag` passed to `mw.images.caption(id, {tag = …})` or to the `mw.images.request(prompt, {tag = …})` that brought the image. |
| `data` | any | The `opts.data` passed alongside the tag, as given. It is held in memory, so it is `nil` after a server restart. |

Return a string to replace the saved description, or nothing to keep it; blank is ignored. `mw.images.set_description` here saves without running this trigger again. `mw.generation.*` is refused here.

```lua
return (event.text:gsub("^This image shows ", ""))
```

### command

**Command palette.** Runs when picked from the command palette as `lua: <name>`. See [Commands](index.md#commands) for declaring parameters.

| Field | Type | What it holds |
| --- | --- | --- |
| `args` | table | The parameters by name. |

`args` values by parameter type:

| Type | Value |
| --- | --- |
| `string`, choices | The text. |
| `integer`, `number` | A number. |
| `boolean` | A boolean. |
| `character`, `participant` | A character record. |
| `message` | A message record. |
| `lore_book`, `lore_entry`, `prompt`, `prompt_block` | Its record. |
| `model` | `{id, name, api_model_id, completion_mode}` |
| `chat` | `{id, name}` |
| `script` | `{id, name, description, trigger, enabled}` |

A blank optional parameter is `nil`. Return a string or number to show it as a notice; nothing shows none. Off a chat page, `chat_id` is `nil` and chat functions return `nil, "no_chat"`.

When another script calls the command with `mw.commands.run`, it runs with the caller's `event` and trigger, with only `event.args` replaced, and its return values go back to the caller unchanged.

```lua
---@param who participant Who speaks
mw.generation.generate(event.args.who.id)
return event.args.who.name .. " is up"
```

### quick_reply

**Quick reply.** Runs when its button above the composer is clicked, or `quick reply: <name>` is picked from the palette, in a chat with a player character.

| Field | Type | What it holds |
| --- | --- | --- |
| `text` | string | What is in the composer when it runs; may be blank. |

| Return | Effect |
| --- | --- |
| A string | Replaces the composer's text. |
| `{"message", text}` | Sends `text` as if typed and sent: templates, `{! !}` blocks and **Outgoing user message** scripts run, staged images go with it, and the composer is cleared. |
| `{"clear"}` | Empties the composer. |
| `nil` or nothing | Changes nothing. |

```lua
return {"message", event.text .. " *waves*"}
```

### inline

**Inline, in a sent message.** Runs once for each `{! … !}` block when a message containing them is sent from the composer. See [Inline scripts](index.md#inline-scripts).

| Field | Type | What it holds |
| --- | --- | --- |
| `character_id` | string | The player character sending the message. |
| `images` | array of string | The ids of the images being sent. |
| `index` | integer | This block's position among the message's blocks, from 1. |

Return a string or number to put in the block's place, or nothing to remove the block.

```lua
for _, m in ipairs(mw.messages.list()) do
  if m.character_id == event.character_id then mw.messages.set_visible(m.id, false) end
end
```

## mw.messages

Messages in the current chat. Writing needs `scripts.messages`; `list`, `get`, `last`, `select` and `versions` are always allowed.

### mw.messages.list

`mw.messages.list([first [, last]])` returns the chat's messages in order: all of them, or those numbered `first` to `last` inclusive. `last` defaults to the end.

### mw.messages.get

`mw.messages.get(id)` returns the message with this id, or `nil, "not_found"`.

### mw.messages.last

`mw.messages.last()` returns the newest message, or `nil` in an empty chat. Its `number` is the newest `#N`.

### mw.messages.select

`mw.messages.select(target)` returns the messages a [target](#targets) names, in order. It always returns a list, empty when none match.

### mw.messages.create

`mw.messages.create(author, text)` posts `text` as a new message and returns it.

| Argument | What it takes |
| --- | --- |
| `author` | The chat's player or a participant: its character id or `{id = character_id}`. Or `{name = "Narrator"}` for a speaker with no character. Another message's `author` table works. |
| `text` | The message text. |

Refuses `"not_in_chat"` for a character outside the chat, and `"blank_name"` for a blank name.

```lua
mw.messages.create({name = "Narrator"}, "Thunder rolls over the hills.")
```

### mw.messages.edit

`mw.messages.edit(id, text)` saves `text` as the message's new active version and returns the message. Refuses `"generating"`.

### mw.messages.delete

`mw.messages.delete(target)` deletes messages. For one id or number it returns `true`, or `nil, "not_found"`. For a range or list it returns how many were deleted. If any of them is generating, it refuses `"generating"` and deletes nothing.

### mw.messages.set_visible

`mw.messages.set_visible(target, visible)` shows messages to the AI's prompt (`true`) or hides them (`false`). For one id or number it returns the message, or `nil, "not_found"`. For a range or list it updates them at once and returns the messages that changed.

### mw.messages.versions

`mw.messages.versions(id)` returns the message's versions (swipes), oldest first, as [version records](#records).

### mw.messages.set_version

`mw.messages.set_version(id, index)` makes version `index` (from 1, as in `versions`) the active one and returns the message. Refuses `"not_found"` or `"generating"`.

### mw.messages.merge

`mw.messages.merge(ids)` merges two or more consecutive messages into the first: its new active version joins their texts, and the rest are deleted. Returns the merged message. Refuses `"not_found"`, `"too_few"`, `"not_contiguous"` or `"generating"`.

### mw.messages.split

`mw.messages.split(id, match [, multi])` splits the message before the first paragraph (after its first paragraph) whose text contains `match`, or before every such paragraph when `multi` is `true`, as the split editor's markers do. The pieces keep the author and visibility. Returns the resulting messages in order. Refuses `"no_match"` or `"generating"`.

### mw.messages.set_author

`mw.messages.set_author(id, author)` changes who wrote the message without adding a version. `author` is a participant's character id, `{id = character_id}`, or `{name = "text"}`. Returns the message. Refuses `"not_in_chat"`, `"blank_name"` or `"generating"`.

## mw.images

Images in the current chat. `list` and `get` are always allowed; the rest need `scripts.images`.

### mw.images.list

`mw.images.list(message_id)` returns the images attached to the message, in order, as [image records](#records), or `nil, "not_found"`.

### mw.images.get

`mw.images.get(id)` returns one image record, or `nil, "not_found"`.

### mw.images.caption

`mw.images.caption(id, opts?)` has the chat's caption model describe the image in the background and returns `true`. The description arrives as an [image_described](#image_described) run.

| Option | What it does |
| --- | --- |
| `tag` | A string that comes back as `event.tag`. |
| `data` | Any value, at most 64 KB, that comes back as `event.data`. |

Refuses `"not_found"`, `"no_captioner"`, `"data_too_large"`, or `"same_image"` when an **Image described** script asks for its own image.

### mw.images.set_description

`mw.images.set_description(id, text)` saves `text` as the image's description, kept over any caption still running; blank clears it. Runs **Image described** (with `by = "script"`) except from inside it. Returns the image, or `nil, "not_found"`.

### mw.images.request

`mw.images.request(prompt?, opts?)` asks the player for an image: the chat shows a dialog with `prompt` and a **Choose image** button, and the image joins the composer like any upload. Returns `true` at once. The image arrives as an **Image described** run once it is described, with `opts.tag` and `opts.data` as `event.tag` and `event.data`. A newer request replaces an open one. Refuses `"not_allowed"` in **Lore book activated**, or `"data_too_large"`.

## mw.generation

Starts AI replies in the current chat. Needs `scripts.generation`, and works only in **Outgoing user message**, **Command palette**, **Quick reply** and inline scripts; elsewhere it returns `nil, "not_allowed"`.

### mw.generation.generate

`mw.generation.generate(character_id [, guide])` queues a reply from a participant, steered by the optional `guide` text. Returns `true`, or `nil` and a reason such as `"busy"`.

### mw.generation.regenerate

`mw.generation.regenerate(message_id [, guide])` queues a new version of the last AI reply, steered by the optional `guide`. Returns `true`, or `nil` and a reason such as `"not_last"`.

## mw.memory

Memory Book commands for the current chat; see [Memory](../memory/index.md). `highest` is always allowed; the rest need `scripts.memory`. `create`, `next`, `catch_up` and `run_side_prompt` follow the same trigger rule as `mw.generation` and return `nil, "not_allowed"` elsewhere. Jobs run in the background without token confirmation but keep the configured review policy.

### mw.memory.create

`mw.memory.create(start, finish)` queues a memory for the inclusive message range. Returns its [job](#records), or `nil` and a reason.

### mw.memory.next

`mw.memory.next()` queues a memory for every unprocessed message. Returns its job, or `nil, "empty_scene"` when none remain.

### mw.memory.catch_up

`mw.memory.catch_up(start, finish, chunk)` queues consecutive memory jobs over the inclusive range, `chunk` messages each. `chunk` must be 5 through 250. Returns a list of jobs.

### mw.memory.run_side_prompt

`mw.memory.run_side_prompt(side_prompt_id [, start [, finish]])` queues a side prompt over the optional inclusive range. Omitted endpoints use its checkpoint and latest defaults. Returns its job; refuses `"not_found"` for an unknown side prompt.

### mw.memory.set_side_prompt_enabled

`mw.memory.set_side_prompt_enabled(side_prompt_id_or_all, enabled)` enables or disables one global side prompt, or every one for the literal `"all"`. Returns how many changed (`0` for `"all"` with none). If an update fails it refuses with that reason, and the side prompts updated before it stay changed.

### mw.memory.highest

`mw.memory.highest()` returns the processed boundary as a message number, or `nil` when it is clear.

### mw.memory.set_highest

`mw.memory.set_highest(number_or_nil)` sets the processed boundary to a positive message number, or clears it with `nil`. Returns `true`.

## mw.characters

Every character you may use, not only this chat's. `list`, `get` and `find` are always allowed; the rest need `scripts.characters`.

### mw.characters.list

`mw.characters.list()` returns every usable character (your own and the site's) as [character records](#records).

### mw.characters.get

`mw.characters.get(id)` returns the character, or `nil, "not_found"`.

### mw.characters.find

`mw.characters.find(name)` returns the first usable character with this whole name, ignoring case and surrounding spaces (your own before the site's, then the oldest), or `nil, "not_found"`. Names are not unique.

### mw.characters.update

`mw.characters.update(id, fields)` updates the given fields, such as `{name = "Ciri"}`, and returns the character.

### mw.characters.set_avatar

`mw.characters.set_avatar(character, prompt?, describe?)` asks the player for an image that becomes the character's avatar. `character` is its id or record. The chat shows a dialog with `prompt` and a **Choose image** button. Returns `true` at once; the avatar is set when the image is chosen.

The new avatar is described when the `images.auto_caption` setting is on and the character's Appearance follows its avatar; `describe` set to `true` or `false` overrides both. The description fills an appearance nobody wrote. A newer request replaces an open one. Needs a chat. Refuses `"not_found"`, or `"not_allowed"` in **Lore book activated**.

### mw.characters.set_appearance

`mw.characters.set_appearance(character, text)` saves `text` as how the character looks (`character` is its id or record); blank clears it. Returns the character.

## mw.prompts and mw.blocks

Prompts and their blocks; see [Prompts](../prompts/index.md). `mw.prompts.list` is always allowed; the switches need `scripts.prompts`.

### mw.prompts.list

`mw.prompts.list()` returns every prompt you may use (your own and the site's) with its blocks, as [prompt records](#records).

### mw.prompts.set_enabled

`mw.prompts.set_enabled(prompt_id, enabled)` turns a prompt on or off and returns `true`.

### mw.prompts.set_block_enabled

`mw.prompts.set_block_enabled(prompt_id, block_id, enabled)` turns a block on or off in this prompt only (its membership switch) and returns `true`.

### mw.blocks.set_enabled

`mw.blocks.set_enabled(block_id, enabled)` turns a block on or off in every prompt that holds it (its own switch) and returns `true`.

## mw.lore

Lore books and entries; see [Lore](../lore/index.md). `books` and `book` are always allowed; the rest need `scripts.lore`.

### mw.lore.books

`mw.lore.books()` returns every lore book you may use, as [book records](#records).

### mw.lore.book

`mw.lore.book(id)` returns the book with its `entries`.

### mw.lore.create_book

`mw.lore.create_book(fields)` creates a book from fields such as `{name = "Places"}` and returns it.

### mw.lore.update_book

`mw.lore.update_book(id, fields)` updates the book's given fields and returns it.

### mw.lore.delete_book

`mw.lore.delete_book(id)` deletes the book and returns `true`. Entries in no other book become unlinked.

### mw.lore.create_entry

`mw.lore.create_entry(book_id, fields)` creates an entry in the book from fields such as `{name = …, content = …, keywords = …}` and returns it.

```lua
mw.lore.create_entry(book.id, {name = "Harbor", content = "Fog hides the harbor at dawn.", keywords = {"harbor", "docks"}})
```

### mw.lore.update_entry

`mw.lore.update_entry(id, fields)` updates the entry's given fields and returns it.

### mw.lore.delete_entry

`mw.lore.delete_entry(id)` deletes the entry from every book and returns `true`.

### mw.lore.set_entry_enabled

`mw.lore.set_entry_enabled(book_id, entry_id, enabled)` turns an entry on or off within this book only and returns `true`.

### mw.lore.set_chat_bound

`mw.lore.set_chat_bound(book_id, bound)` binds the book to the current chat (`true`) or unbinds it (`false`) and returns `true`. Needs a chat.

## mw.vars and mw.globals

Variables that templates read; see [Variables](../prompts/variables.md). `get` and `list` are always allowed; `set` needs `scripts.variables`. Values are strings, numbers, booleans and tables of them; anything else raises. A malformed key refuses with the key's error.

### mw.vars.get

`mw.vars.get(key)` returns the chat variable's value (`vars.<key>` in templates), or `nil` when it is unset.

### mw.vars.set

`mw.vars.set(key, value)` sets the chat variable, as `{% setvar %}` does, and returns `true`. A `nil` value deletes it.

### mw.vars.list

`mw.vars.list()` returns every chat variable as a table of `key = value`.

### mw.globals.get

`mw.globals.get(key)` returns the global variable's value as your chats read it (`globals.<key>`: site globals overlaid by your own), or `nil` when it is unset.

### mw.globals.set

`mw.globals.set(key, value)` sets your own global variable, never the site's, as `{% setglobalvar %}` does, and returns `true`. A `nil` value deletes it.

### mw.globals.list

`mw.globals.list()` returns every global variable your chats read, as a table of `key = value`.

## mw.injections

The current chat's injections. `list` and `get` are always allowed; the rest need `scripts.injections`.

Injection fields match the chat's injections panel:

| Field | What it takes |
| --- | --- |
| `key` | A name to find the injection by. |
| `content` | The text to inject. |
| `position` | A lore slot such as `"after_author_note"` or `"at_depth"`. |
| `depth` | The depth, for `"at_depth"`. |
| `role` | `"system"`, `"user"` or `"assistant"`. |
| `condition` | When it applies; `false` clears it. |
| `enabled` | Whether it is on. |
| `uses` | How many successful replies it lasts for; `false` clears it. |
| `order` | Its order among injections. |

### mw.injections.list

`mw.injections.list()` returns every injection in the chat, spent and disabled ones included, in application order.

### mw.injections.get

`mw.injections.get(key_or_id)` returns the injection with this key or id.

### mw.injections.create

`mw.injections.create(fields)` creates an injection and returns it.

```lua
mw.injections.create({key = "mood", content = "Rain falls.", uses = 3})
```

### mw.injections.update

`mw.injections.update(key_or_id, fields)` updates the injection's given fields and returns it.

### mw.injections.set_enabled

`mw.injections.set_enabled(key_or_id, enabled)` turns the injection on or off and returns `true`.

### mw.injections.rearm

`mw.injections.rearm(key_or_id)` restores a limited injection's `remaining` replies to its `uses` and returns it.

### mw.injections.delete

`mw.injections.delete(key_or_id)` deletes the injection and returns `true`.

### mw.injections.clean_up

`mw.injections.clean_up()` deletes the chat's spent injections and returns how many.

## mw.commands

### mw.commands.run

`mw.commands.run(name [, args])` runs the enabled **Command palette** script with this name as if picked from the palette, and returns what it returns. It is always allowed; the command's own calls are checked as usual. Your own command is preferred over a site command of the same name.

| Argument | What it takes |
| --- | --- |
| `name` | The command script's name. |
| `args` | A table keyed by `---@param` name. An entity is its id or its record table. |

The command runs with this script's event, trigger and permissions. Refuses `"not_found"` for no such command, `"<param>: <problem>"` for a bad argument, and `"too_deep"` past 3 nested calls. A failing command fails this call.

```lua
local notice = mw.commands.run("Weather", {season = "winter"})
```

## mw.roll

`mw.roll(dice)` rolls dice such as `"2d6+1"`, `"d6"` or `"D20"` and returns the total. It is always allowed.

```lua
if mw.roll("d20") >= 15 then return event.text .. " (success)" end
```

## regex

PCRE regular expressions, which Lua's own patterns lack. Always allowed. Positions are byte positions from 1.

`flags` is a string of any of these letters:

| Flag | Meaning |
| --- | --- |
| `i` | Ignore case. |
| `m` | `^` and `$` match at line breaks. |
| `s` | `.` matches newlines. |
| `x` | Extended: whitespace and `#` comments in the pattern are ignored. |
| `U` | Ungreedy: quantifiers are lazy by default. |

An unknown flag or an invalid pattern raises an error.

A **match table** is `{text, start, finish, groups, named}`: the matched text, its first and last byte, the numbered groups, and the named groups.

### regex.test

`regex.test(s, pattern [, flags])` returns whether `pattern` matches anywhere in `s`.

### regex.match

`regex.match(s, pattern [, flags [, init]])` returns the first match at or after byte `init` as a match table, or `nil` when there is none.

### regex.match_all

`regex.match_all(s, pattern [, flags [, limit]])` returns every match (at most `limit`) as an array of match tables.

### regex.replace

`regex.replace(s, pattern, repl [, flags [, limit]])` replaces matches (at most `limit`) and returns the new string and the number of replacements. `repl` is either a template, where `$1` is a group, `${name}` a named group and `$$` a literal `$`, or a function that receives the match table and returns a string, or `nil` or `false` to keep the match.

```lua
local text = regex.replace(event.text, [[\b(\w+) \1\b]], "$1", "i")
```

### regex.split

`regex.split(s, pattern [, flags [, limit]])` returns the pieces of `s` between matches (at most `limit` splits).

### regex.escape

`regex.escape(s)` returns `s` with every regex metacharacter escaped, to match it literally.
