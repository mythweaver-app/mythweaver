---
title: Command palette
order: 2
description: A keyboard launcher for jumping to any screen and running chat actions without the mouse.
---

The command palette lets you reach any screen and run most chat actions from the keyboard. It is available on every page.

## To run a command

1. Press **Ctrl-P** (**⌘-P** on macOS). The **Command palette** opens with your recently used commands first.
2. Type part of a command's name. The list is filtered by fuzzy matching, so `lbe` finds `lore book: edit`.
3. Use **↑** and **↓** to pick a command, then press **Enter**.
4. If the command needs parameters, the palette asks for each one in turn. Suggestions appear under the focused field; use **↑**/**↓** to pick one and **Tab** to move to the next field. Optional parameters are labeled *(optional)*. Press **Enter** to run the command.
5. Press **Esc** to go back from the parameters to the command list, or to close the palette.

The footer shows the keys: **Run enter**, **Back esc** and **Next tab**.

The palette remembers your last 20 commands in this browser and lists them first.

### Parameter types

| Field hint | What it takes |
|---|---|
| **Text** | Free text. |
| **Whole number** / **Number** | A number, such as a message number. |
| **Type to filter** | A choice from the suggestions (a chat, character, model…). Typing something not on the list gives *Pick one from the list.* |
| Image | A PNG, JPEG or WebP file, chosen or pasted. |

A required parameter left blank shows *Required.*

### Results and messages

Commands that finish with a message (a cleanup summary, an error such as *This chat has no messages yet.*) show it as a flash notice at the top of the page, the same way the page's own buttons do. If a command script crashes you see *The command script crashed.*; if a background command fails, *The command failed.*

## Global commands

These work on every page. Each one appears only when you have access to that area.

| Command | What it does |
|---|---|
| `chats: open`, `chat: switch` | Open the chat list, or open a chat by name. |
| `characters: open`, `character: new`, `character: edit` | The character editor at `/characters`. |
| `expression rules: open`, `expression rules: new` | Expression profiles at `/characters/expression-profiles`. |
| `lore: open`, `lore book: new`, `lore book: edit`, `lore entry: new`, `lore entry: edit` | The lore editor at `/lore`. |
| `lore pools: open`, `lore pool: new` | Inclusion pools at `/lore/pools`. |
| `prompts: open`, `prompt: new`, `prompt: edit` | Prompts at `/prompts`. |
| `prompt blocks: open`, `prompt block: new`, `prompt block: edit` | Prompt blocks. |
| `prompt outlets: open`, `prompt outlet: new`, `prompt outlet: edit` | Prompt outlets. |
| `ai providers: open`, `ai provider: new`, `ai provider: edit` | AI connections at `/ai/providers`. |
| `ai models: open`, `ai model: new`, `ai model: edit` | AI models. |
| `variables: open`, `variable: new`, `variable: edit` | Global variables at `/variables`. |
| `scripts: open`, `script: new`, `script: edit` | Lua scripts at `/scripts`. |
| `tags: open`, `tag: new`, `tag: edit` | The tag manager at `/tags`. |
| `memory profiles: open`, `memory profile: new`, `memory profile: edit` | Memory profiles at `/memory/profiles`. |
| `side prompts: open`, `side prompt: new`, `side prompt: edit` | Side prompts. |
| `jobs: open` | The job queue at `/jobs`. |
| `settings: open` | Settings at `/settings`. |
| `import: open`, `export: open` | [Import and export](import-export.md). |
| `submissions: open` | The moderation submissions queue at `/submissions`. |
| `cleanup: my chats` | Tidies old messages in all your chats now, with your cleanup settings, and reports what it removed. |
| `cleanup: all chats` | The same over every user's chats with the site's values. Needs the `site.cleanup.run` permission. |

Cleanup affects only messages older than the cleanup threshold: it drops near-duplicate inactive swipes, clears reasoning text and deletes stored prompt snapshots. The cleanup settings are described in [Settings](../account/settings.md).

### Script commands

Each enabled command script adds a `lua: <name>` entry, with the parameters the script declares. On a chat page, each enabled quick reply script adds a `quick reply: <name>` entry. See [Scripts](../scripts/index.md).

## Chat commands

These appear only while a role-play chat is open (not in a conversation with Mythweaver). They do exactly what the matching buttons in the chat do.

| Command | What it does |
|---|---|
| `chat: new` | Start a new chat. |
| `chat: settings`, `chat: memory`, `chat: variables`, `chat: injections`, `chat: turn queue` | Open that panel of the current chat. |
| `chat: generate reply` | Ask a character to reply; **Speaker** picks which one. |
| `chat: regenerate last reply`, `chat: continue last reply` | Regenerate or continue the last reply. |
| `chat: rewrite last reply with the composer text` | Refine the last reply using what you typed in the composer as the instruction. |
| `chat: stop generation` | Stop the reply in progress. |
| `chat: toggle auto mode` | Turn auto mode on or off. |
| `chat: edit last message`, `chat: edit last player message` | Open the editor on that message. |
| `chat: previous swipe`, `chat: next swipe` | Move between swipes of the last reply. |
| `chat: jump to latest`, `chat: go to message` | Scroll to the end, or to a **Message number**. |
| `chat: delete message`, `chat: toggle message visibility` | Delete a message, or hide it from the AI (or show it again). |
| `chat: play as` | Choose which **Character** you play. |
| `chat: add participants` | Add characters to the chat. |
| `chat: toggle mute`, `chat: toggle mute shown characters` | Mute or unmute a **Participant**, or every character currently shown. |
| `chat: toggle muted participants`, `chat: show muted participants`, `chat: hide muted participants` | Show or hide muted participants in the participant list. |
| `chat: set expression of last message`, `chat: classify last message's expression again` | Set the last message's expression by hand, or run the classifier again. |
| `chat: change outfit` | Switch a **Character**'s outfit. |
| `chat: describe all attachments`, `chat: caption image` | Describe every image in the chat, or caption one **Image** with an optional **Prompt**. |
| `chat: create memory`, `chat: create next memory`, `chat: create scene memory` | Make a memory now, the next one in sequence, or one for a **Start**–**End** message range. |
| `chat: catch up memories` | Make memories over a range in chunks (**Chunk size** 5 to 250 messages). |
| `chat: consolidate memories` | Run consolidation. |
| `chat: run side prompt`, `chat: enable side prompt`, `chat: disable side prompt`, `chat: enable all side prompts`, `chat: disable all side prompts` | Run or switch side prompts for this chat. |
| `chat: show processed boundary`, `chat: set processed boundary`, `chat: clear processed boundary` | Inspect or move the point up to which memory has processed the chat. |

The memory commands are explained in [Memory](../memory/index.md); the chat actions in [Messages and swipes](../chats/messages.md) and [Group chats and turn-taking](../chats/group-chats.md).
