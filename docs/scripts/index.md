---
title: Scripts
order: 8
description: Lua scripts that react to chat events, add commands and quick replies, and change chats, lore and characters.
---

Scripts are small Lua programs that run when something happens in a chat: a message is sent, an AI reply finishes, lore activates or an image gets a description. They can rewrite text, post or hide messages, start replies, switch lore and prompts, and add your own commands and quick reply buttons. For every function and event field, see the [Script API reference](api.md).

## To create a script

1. Open **Scripts** at `/scripts` and select **New script** (`/scripts/new`).
2. Enter a **Name** and, optionally, a **Description**.
3. Choose a **Trigger** (see [Triggers](#triggers)).
4. Write the Lua in the **Script** editor. Select **Validate** to check it for syntax errors; a clean check shows **No problems found.**
5. Optionally pick scripts under **Runs after** and set a **Priority**.
6. Select **Save**.

Every enabled script of a trigger runs in each of your chats when that trigger fires. Turn **Enabled** off to keep a script without running it.

> [!NOTE]
> Your own scripts need the `content.scripts.create` permission ("Create own scripts"). Your scripts run only in your own chats. Site scripts, which have no owner, are edited by admins and run in every chat.

### To test a script

Under **Test the script**, type **Sample text** (what the script gets as `event.text`) and select **Run test**. The test has no chat and changes nothing: every function that needs a chat or writes data returns `nil, "test_run"`. Only these work in a test: `mw.characters.list`, `get` and `find`, `mw.prompts.list`, `mw.lore.books` and `book`, `mw.globals.get` and `list`, `mw.commands.run` and `mw.roll`, plus `regex.*`. The result shows the returned text, or **The script failed:** with the error, and any `print` output.

### To see whether a script works

The script's form shows when it last ran without error (**Never** if it hasn't) and its **Last error:** (**None** if it hasn't failed). A failing script is marked in the list. The status counts only runs in chats of people who may edit the script, and it resets when you change the body or trigger. Errors and `print` lines from a run are also shown to the person whose message ran it, as `Script "<name>" printed: …`.

## Triggers

| Trigger | Badge | When it runs | What a return value does |
| --- | --- | --- | --- |
| **Incoming AI generation** | AI reply | An AI reply finishes successfully, before it is saved. Stopped or failed replies run nothing. | A string replaces the saved text. |
| **Outgoing user message** | User message | The player sends a message or saves an edit, before it is stored. Only the chat owner's own messages run scripts. | A string replaces the text. Blank text cancels a send with no images. |
| **Lore book activated** | Lore | A generation activates lore, before the prompt is sent. | Ignored. Changes apply from the next generation. |
| **Image described** | Image | An image in a chat gets a description from a caption model, a person or a script. Avatars run nothing. | A string replaces the saved description. |
| **Command palette** | Command | You pick `lua: <name>` from the command palette. | A string or number is shown as a notice. |
| **Quick reply** | Quick reply | You click its button above the composer, or pick `quick reply: <name>` from the palette. | A string replaces the composer text; `{"message", text}` sends it; `{"clear"}` empties the composer. |

There is also an **Inline, in a sent message** trigger that you don't create on this page: see [Inline scripts](#inline-scripts).

The editor lists each trigger's `event` fields and **Return value:** below the form; the [Script API reference](api.md#events) has the same reference.

## Run order and dependencies

Scripts of one trigger run one after another:

1. A script listed under **Runs after** runs only after those scripts have succeeded. If a dependency failed, was skipped or is disabled, the script does not run.
2. Among scripts that are ready, a higher **Priority (higher runs first)** runs first, then scripts sort by name.

Each script runs in a fresh Lua state. Only `event.text` passes from one script to the next, so a later script sees the text an earlier one returned.

A script can depend only on scripts with the same trigger, and only on site scripts or scripts you own. A site script can depend only on site scripts.

For quick replies, the field is **Priority (higher shows first)** and orders the buttons above the composer (then by name).

## Commands

A **Command palette** script appears in the command palette (Cmd-P / Ctrl-P) as `lua: <name>`. To ask for inputs, declare them in `---` comment lines at the very top of the script:

```lua
--- Has a participant speak next.
---@param who participant Who speaks
---@param mood? "happy"|"sad" Mood
mw.generation.generate(event.args.who.id, "Speak in a " .. (event.args.mood or "calm") .. " tone.")
return event.args.who.name .. " is up"
```

- `---@param name type Label` declares a parameter; `name?` makes it optional. A blank optional parameter is `nil`.
- Other `---` text is the command's description. Other `---@` tags are ignored. The header ends at the first line that isn't a `---` comment.
- Types: `string`, `integer`, `number`, `boolean`, `character`, `participant`, `message`, `lore_book`, `lore_entry`, `prompt`, `prompt_block`, `model`, `chat`, `script`, or quoted choices such as `"a"|"b"`.
- A command with a `participant` or `message` parameter is offered only in a chat.
- Off a chat page, `event.chat_id` is `nil` and chat functions return `nil, "no_chat"`.

Other scripts can call a command with [`mw.commands.run`](api.md#mwcommandsrun).

## Quick replies

A **Quick reply** script shows as a button named after the script above the chat composer, and as `quick reply: <name>` in the command palette. It runs in chats that have a player character and gets the composer's text as `event.text`.

```lua
return {"message", event.text .. " *waves*"}
```

## Inline scripts

Lua between `{!` and `!}` in a message you type runs once when you send it, and the block is never stored. The block's return value (a string or number) takes its place in the message; returning nothing removes it.

```text
I roll for initiative: {! return mw.roll("d20") !}
```

- The blocks are taken out before Liquid renders the message, so Liquid never touches the Lua. A block inside a false `{% if %}` branch does not run.
- The first `!}` closes a block; there is no escape.
- A message can hold at most 10 blocks. They run in order.
- A syntax error in any block blocks the send; a runtime error stops the send at that block.
- If the message is blank afterwards and has no images, nothing is posted.

## Who may start generations

Only **Outgoing user message**, **Command palette**, **Quick reply** and inline scripts may start AI replies or memory jobs (`mw.generation.*`, `mw.memory.create`, `next`, `catch_up` and `run_side_prompt`). Inside a generation (**Incoming AI generation**, **Lore book activated**) and in **Image described**, those functions return `nil, "not_allowed"` or are refused, so an AI reply never starts another.

## Script permissions

A script acts with the permissions of the person it runs for. Reading is always allowed, but each namespace's writing functions need a permission; without it they return `nil, "no_permission"`.

| Permission key | Name | Covers |
| --- | --- | --- |
| `scripts.messages` | Scripts may change messages | `mw.messages.*` |
| `scripts.images` | Scripts may caption and request images | `mw.images.*` |
| `scripts.generation` | Scripts may start generations | `mw.generation.*` |
| `scripts.memory` | Scripts may run memory jobs and change memory settings | `mw.memory.*` |
| `scripts.characters` | Scripts may change characters and avatars | `mw.characters.*` |
| `scripts.prompts` | Scripts may switch prompts and blocks | `mw.prompts.*`, `mw.blocks.*` |
| `scripts.lore` | Scripts may change lore | `mw.lore.*` |
| `scripts.variables` | Scripts may change variables | `mw.vars.*`, `mw.globals.*` |
| `scripts.injections` | Scripts may change injections | `mw.injections.*` |

Admins grant these under [Users, groups and permissions](../administration/users-and-permissions.md).

## Sandbox limits

Each run is isolated and limited:

| Limit | Default | What happens |
| --- | --- | --- |
| CPU time | 5,000 ms | The run stops with "Script exceeded its CPU time limit". Time spent waiting on the database doesn't count. |
| Wall-clock time | 10,000 ms | The run stops with "Script exceeded its time limit". |
| Memory | 32 MB | The run stops with "Script exceeded its memory limit". A single string may be at most a quarter of this. |
| Call depth | 128 | Deeper recursion fails. |
| Script size | 64 KB | The script can't be saved. |
| `print` output | 20 lines of 500 characters | Further lines are dropped. |
| Nested commands | 3 | `mw.commands.run` returns `nil, "too_deep"`. |

These are not available to scripts: `io`, `file`, `package`, `require`, `load`, `loadfile`, `loadstring`, `dofile`, `os.execute`, `os.exit`, `os.getenv`, `os.remove`, `os.rename`, `os.tmpname`, `string.pack`, and the `debug` functions that read or change locals, upvalues and hooks. `print` doesn't reach the server; its lines come back with the run's result.

> [!NOTE]
> The defaults suit a self-hosted install. The server administrator can change them in the app's configuration; they are not settings in the UI.

## Site scripts

Admins can create site scripts, which run in every chat. **Visible to users** controls what people who aren't admins see:

| Option | What it does |
| --- | --- |
| **Everything** | Users can read the script's body. |
| **Only names (runtime-only)** | Users see only the name, never the body, in the assistant, scripts or exports. It still runs. |

Admins always see everything. Scripts can be shared and published like other content; see [Sharing and the catalog](../chats/sharing.md).

## Script form reference

| Field | What it does |
| --- | --- |
| **Name** | The script's name, unique among your scripts. Commands and quick replies show it. |
| **Description** | A note for you. |
| **Trigger** | The event that runs the script. |
| **Priority** | Run order among ready scripts (or button order for quick replies); higher first. |
| **Enabled** | Whether the script runs on its trigger. |
| **Visible to users** | Site scripts only: see [Site scripts](#site-scripts). |
| **Runs after** | Scripts of the same trigger that must succeed first. |
| **Script** | The Lua source, at most 64 KB. |
