---
title: Memory
order: 7
description: Memory Books write AI summaries of your chat's scenes into a lore book, so long chats keep their history within the model's context.
---

Memory Books keep a long chat's history available to the AI. A model reads a scene (a range of messages) and writes a short memory of it, with a title and keywords, into the chat's **memory book**. The memory book is an ordinary lore book, so memories activate like any other lore entry and the AI recalls past events without reading the whole transcript. Memory Books is a server-side port of SillyTavern-MemoryBooks.

Besides scene memories, Memory Books can:

- merge many memories into larger summaries ([consolidation tiers](consolidation.md): Arc, Chapter, Book, Legend, Series, Epic),
- keep extra tracker entries up to date, such as a plot tracker or a list of what changed about a character ([side prompts](side-prompts.md)),
- save highlighted passages and gather everything about one topic into one entry ([clips and Memory Assistance](clips.md)),
- give each character in a group chat a book of their own memories ([character books and locks](character-books.md)).

The model, prompts and entry settings a memory job uses come from a [memory profile](profiles.md).

## Open a chat's memory

Select **Memory** in the chat's header (it shows a brain icon) or go to `/chats/:id/memory`. You can also run **chat: memory** from the [command palette](../tools/command-palette.md). The memory window has these tabs:

| Tab | What it holds |
| --- | --- |
| **Memory** | The chat's book, profile and processed boundary, and the **Create a memory** and **Catch up** forms. |
| **Reviews** | Drafts waiting for you to check, edit and save: memories, consolidations, compactions, topical clips, side prompt updates and Memory Assistance suggestions. A badge counts them. |
| **Entries** | Every memory, clip and side prompt entry of the chat's memory book, grouped by kind and tier, with **Regenerate**, **Compact** and **Edit**. |
| **Consolidate** | Merges memories into the next tier. See [Consolidation tiers](consolidation.md). |
| **Topical clip** | Gathers one topic into one entry. See [Clips and Memory Assistance](clips.md). |
| **Side prompts** | Turns side prompts on or off, runs them by hand and shows how far each has run. See [Side prompts](side-prompts.md). |
| **Character books** | Per-character memory books in group chats. See [Character books and locks](character-books.md). |
| **Context** | **Additional context entries**: lore entries sent with every memory request for this chat. |
| **Settings** | **This chat's memory settings**. |

An **In progress** list at the top of the window shows memory jobs that are queued or running.

> [!NOTE]
> The memory window is available to people who can inspect the chat. Memory jobs always run as the chat's owner: they use the owner's profile, models, prompts and quota, even when a chat editor starts them.

## To create a memory

1. Open the **Memory** tab.
2. Under **Create a memory**, enter the first and last message numbers in **From #** and **To #**. Select **Next scene** to fill them from the processed boundary to the latest message.
3. Set **Previous memories**: how many earlier memories the model reads for continuity.
4. Optionally pick characters under **Present (none selected: whoever speaks)**. When you pick none, the characters who spoke in the scene are used.
5. Select **Create**.

When **Review memories before saving** is on (the default), the draft appears in **Reviews**. Edit its **Title**, **Content** and **Keywords**, then select **Save**, **Regenerate** or **Discard**. **View raw response** shows the model's reply as it came back. When the setting is off, the memory is saved directly.

You can also select messages in the transcript and choose **Create memory** in the selection bar (see [Messages and swipes](../chats/messages.md)), or run **chat: create memory**, **chat: create scene memory** or **chat: create next memory** from the command palette.

If the request is larger than **Token warning threshold**, the form warns you and offers **Create anyway**.

## To catch up an old chat

**Catch up** writes memories for a long stretch of past messages in one go.

1. In the **Memory** tab, under **Catch up**, enter **From #** and **To #**.
2. Set **Messages per memory** (5 to 250).
3. Select **Catch up**.

The range is cut into consecutive chunks, and each chunk becomes one memory, saved without review, in order. If one chunk fails, the rest are cancelled. The command palette command is **chat: catch up memories**.

## The processed boundary

The processed boundary is the last message any memory covers. The **Memory** tab shows it as **Processed through #N** (or **Nothing processed yet**), and the transcript marks it with a divider unless **Processed boundary** is **Off**. **Next scene**, automatic memories and reminders all count from it.

To move it by hand, enter a number in **Processed through #** and select **Set**, or select **Clear** to forget it.

## To create memories automatically

1. Open the **Settings** tab.
2. Turn on **Create memories automatically**.
3. Pick a **Trigger**: **Every N messages** or **Token threshold**. Leave it on the default to follow `/settings/memory`.
4. Adjust **Interval**, **Buffer** or **Token threshold** if this chat needs its own values. Blank fields follow `/settings/memory`.
5. Select **Save settings**.

After each new message, the chat checks whether enough unprocessed messages have piled up past the boundary. If so, it writes a memory of them, leaving the newest **Buffer** messages out so the latest exchange can still change. The transcript shows **Automatic memory due** when one is about to run.

## Entries

The **Entries** tab lists the chat's memory book, newest first within each kind and tier. Each entry shows its message range, whether it is **Enabled** or **Disabled**, and badges such as **Consolidated** or **Character copy**.

| Action | What it does |
| --- | --- |
| **Regenerate** | Writes the memory again from the same messages. If the messages changed since, it asks you to confirm with **Regenerate anyway**. A character's copy cannot be regenerated on its own; regenerating the chat's memory refreshes it. |
| **Compact** | Asks the profile's compaction prompt to rewrite the entry more briefly. The result waits in **Reviews**, showing **Original** and **Draft**. |
| **Edit** | Opens the entry in the lore editor. |

Memories written elsewhere, such as imported summaries, can be adopted: in the lore book editor, select the entries and choose **Mark as memories**. Adopted memories have no chat or message range and are never regenerated. **Unmark memories** reverses it; the entries stay.

## Chat memory settings

The **Settings** tab holds **This chat's memory settings**. Select **Save settings** to apply changes.

| Field | What it does |
| --- | --- |
| **Memory book** | The lore book this chat's memories are saved to. **Create automatically** makes one, bound to this chat, on the first save. |
| **Lock this book to** a character | Solo chats only. Locks the memory book to the chat's character, so it follows the character into your other chats. See [Character books and locks](character-books.md). |
| **Always present (silent witnesses)** | Characters present in every new memory besides whoever speaks: the memory names them, is filtered to them, and is copied into their character books. |
| **Profile** | The memory profile this chat uses. **Default** uses your default memory profile. |
| **Create memories automatically** | Writes a memory of the newest scene whenever the trigger is reached. |
| **Trigger** | **Every N messages** or **Token threshold**. The default follows `/settings/memory`. |
| **Interval** | With the message trigger, how many new messages past the boundary (buffer not counted) make a memory. |
| **Buffer** | How many of the newest messages an automatic memory leaves out of its scene. |
| **Token threshold** | With the token trigger, how many tokens of new messages past the boundary (buffer not counted) make a memory. |
| **Auto-hide processed messages** | After a memory is saved, hides the messages it covers from the AI: **Off**, **All processed**, or **Last scene only**. |
| **Leave unhidden** | How many of the newest processed messages auto-hide leaves visible to the AI. |
| **Side prompt books** | The book each side prompt saves its new entries to in this chat. **Side prompt's own target** uses the book the side prompt names. |
| **Side prompts that run automatically** | **Default** (follows the default side prompt set settings), **Individually enabled side prompts**, or **A set**. |
| **Side prompt set** | The set to run when you pick **A set**. |

## Additional context

The **Context** tab lists lore entries sent with every memory request for this chat, such as a character sheet or world summary that helps the model write accurate memories. Select **Add context entries**, pick **Entries**, and select **Add**. Remove one with its trash button.

## Memory preferences

Your memory preferences are at `/settings/memory` (the **Memory** category of [Settings](../account/settings.md)). An administrator can set site defaults, and each user can override them.

### Memories

| Setting | Key | What it does |
| --- | --- | --- |
| **Review memories before saving** | `memory.show_previews` | Shows a generated memory in **Reviews** before it is saved. On by default. |
| **Review consolidations before saving** | `memory.show_consolidation_previews` | Shows a consolidation for review before it replaces its sources. On by default. |
| **Token warning threshold** | `memory.token_warning_threshold` | Asks before sending a memory request estimated at more than this many tokens (prompt, earlier memories, additional context and scene together). Default 30,000. |
| **Previous memories sent by default** | `memory.default_previous_count` | How many earlier memories accompany a scene (0 to 7). Default 1. |
| **Allow overlapping scenes** | `memory.allow_overlap` | Lets a new scene include messages an earlier memory already covers. Off by default. |
| **Include messages hidden from the AI** | `memory.include_hidden` | Sends hidden messages when writing a memory of their scene. Off by default. |
| **Processed boundary** | `memory.boundary_indicator` | **Divider** marks the last processed message in the chat; **Off** hides the mark. |

### Automatic memories

| Setting | Key | What it does |
| --- | --- | --- |
| **Trigger** | `memory.auto_trigger` | **Every N messages** (default) or **Token threshold**. |
| **Interval** | `memory.auto_interval` | New messages past the boundary, not counting the buffer, that make a memory (5 to 250). Default 30. |
| **Buffer** | `memory.auto_buffer` | Newest messages left out of an automatic memory (0 to 50). Default 2. |
| **Token threshold** | `memory.auto_token_threshold` | Tokens of new messages past the boundary that make a memory, with the token trigger. Default 8,000. |

A chat can override each of these in its **Settings** tab.

### Reminders

| Setting | Key | What it does |
| --- | --- | --- |
| **Manual reminders** | `memory.manual_reminders` | Reminds you to make memories when automatic memories are off. |
| **Manual reminder interval** | `memory.manual_reminder_interval` | Unprocessed messages before the first reminder, and between reminders. Default 50. |
| **Automatic reminders** | `memory.auto_reminders` | Reminds you when automatic memories fall behind. |
| **Automatic reminder interval** | `memory.auto_reminder_interval` | Messages past the automatic interval and buffer before the first reminder, and between reminders. Default 10. |

### Consolidation

See [Consolidation tiers](consolidation.md#consolidation-settings).

### Rollback on message deletion

| Setting | Key | What it does |
| --- | --- | --- |
| **Roll back memories when a message is deleted** | `memory.rollback_enabled` | Deleting a message a memory covers undoes that memory's effects. Off by default. |
| **Scope** | `memory.rollback_scope` | **Memories covering the message**, or **Every later memory**. |
| **Move the boundary back** | `memory.rollback_update_boundary` | Moves the processed boundary back to before the deleted message. |
| **Delete affected memories** | `memory.rollback_delete_memories` | Deletes the rolled-back memories, and any consolidation built on them, from the memory book. The sources those consolidations switched off are switched back on. |
| **Restore side-prompt entries** | `memory.rollback_restore_side_prompts` | Restores side prompt entries to their versions before the rolled-back memories, but only where the entry still holds exactly what the side prompt wrote. |

Rollback also cancels queued or running memory jobs whose range reaches the deleted message.

> [!WARNING]
> With rollback on, deleting a single message can delete memories and consolidations. Turn it on only if you want the memory book to follow edits to the transcript.

### Side prompts and Memory assistance

See [Side prompts](side-prompts.md#side-prompt-settings) and [Clips and Memory Assistance](clips.md#memory-assistance-setting).

## What a new install includes

A new install has a site-wide **Default** profile using built-in prompts (**Memory: Summary**, **Memory: Group**, **Consolidation**, **Compaction**, **Topical clip**, **Memory assistance**, **Memory assistance: topics**, **Combine clips**), the extra memory prompts **Memory: Minimal**, **Memory: Comprehensive** and **Memory: Character**, and a **Plot tracker** side prompt that is off until you turn it on. You can edit these prompts like any other at **Prompts** (see [Prompts](../prompts/index.md)).
