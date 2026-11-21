---
title: Messages and swipes
order: 1
description: Read, edit, regenerate, continue, refine and tidy up the messages of a chat.
---

Every post in a chat is a message. A message can hold several versions of its text, called swipes, so you can try a reply again without losing the earlier attempts. This page covers what you can do with a message once it is in the chat.

Most controls sit in each message's header (edit, visibility, split, merge, delete) and footer (swipes, regenerate, continue). Some only appear on the latest message. In a shared chat you see only the controls your role allows; see [Sharing and the catalog](sharing.md).

## Swipes

A swipe is one version of a message. The footer shows which one you are looking at as **2 / 5**.

- Select **Previous swipe** and **Next swipe** (the arrows) to flip between versions. Going back from the first swipe wraps around to the last.
- Swiping is your own view: other people and other tabs keep showing the swipe they picked.
- The swipe you see is the one the AI reads in later prompts.

New swipes come from regenerating, continuing, refining, editing, merging, splitting and appending a scratchpad. The site setting `generation.swipes_per_generation` can make every reply produce several swipes at once; see [Settings](../account/settings.md).

### To review a message's swipe history

1. Select **Swipe history** in the message footer.
2. Each swipe is listed newest first with how it came about, such as **Original**, **Regeneration**, **Edit of #2** or **Continue of #1**, plus any guide or instructions you gave.
3. Expand a swipe to read all of it. For edits, continues and refines, select **Show diff** to see the word-level changes against the swipe it came from.
4. Select **Make active** to show that swipe in the chat.

## To regenerate a reply

Select **Regenerate this reply** on the latest message. The character writes a new reply, which is added as a new swipe; the old ones stay.

If the composer has text or attachments in it when you select regenerate, they are sent along as a guide for the new reply. See [The composer](composer.md#guides).

> [!NOTE]
> Only the latest message can be regenerated, continued or refined.

## To continue a message

Select **Continue this message** (tooltip **Continue (adds a swipe)**) on the latest message. The character picks up where the text stops, and the longer text is saved as a new swipe, so the original stays one swipe back.

## To refine a reply

Refining rewrites the latest reply following instructions you give it.

1. Type your instructions in the composer, for example "Make it shorter and drop the last paragraph."
2. Select the refine button (the pencil) on the latest reply, **Rewrite with the composer text as instructions**.

The rewrite is added as a new swipe. Refining needs the chat's prompt to contain the Refine block; if it doesn't, you are told to add it. See [Blocks](../prompts/blocks.md).

### To rewrite with notes on passages

You can also mark up passages of the latest reply and have it rewritten around your notes.

1. Select some text in the latest reply. In the toolbar that appears, choose **Annotate passage**.
2. Pick a quick action, or write a note and select **Save**:

   | Action | What it asks for |
   | --- | --- |
   | **Keep verbatim** | Keep this passage word for word. |
   | **Expand** | Say more here. |
   | **Shorten** | Say less here. |
   | **Emphasize** | Make this passage stand out more. |
   | **Reject entirely** | Remove this passage. |
   | **Note** | Your own free-text instruction. |

3. Repeat for other passages. The notes are listed under the message; remove one with **Remove note**, or all with **Discard notes**.
4. Select **Rewrite with notes**. The rewrite is a new swipe.

Notes belong to the tab you made them in and are dropped if the message changes.

## To edit a message

1. Select **Edit message** in the message header, or double-click the text at the spot you want to change.
2. Change the text. You can also add or remove attachments.
3. Save it in one of two ways:
   - **Create new swipe** (also Enter, or Escape) keeps the original and adds your version as a new swipe.
   - **Save edits** (**Overwrite the shown swipe**) changes the swipe you are looking at.

Your edited text is rendered as Liquid, the same as a sent message; a template error keeps the edit open with the error shown. Saving unchanged text adds nothing.

## To change who wrote a message

Select **Change author** to pick another participant, or type a name for an author who isn't a character in the chat, then select **Save author**. This only changes the author: the text stays, and no swipe is added. Changing the author needs the right to manage the chat.

## To hide a message from the AI

Select the eye icon in the message header. Its tooltip tells you the state: **Visible to the AI (click to hide)** or **Hidden from the AI (click to show)**. A hidden message stays in the chat, dimmed, but is left out of every prompt. Select it again to bring it back.

Memory can hide summarized messages for you automatically; see [Memory](../memory/index.md).

## To split, merge and set text aside

- **Split into messages** opens a split editor on the message's paragraphs. Place dividers between paragraphs with **Add a split below**, and pick an author for each piece. Drag a divider's grip, or use the arrow keys on it, to move it. Select **Split** to turn the pieces into separate messages. A piece can go to **Scratchpad** instead.
- **Merge into previous message** joins a message onto the one above it, as a new swipe of that message.
- **Split the end into a scratchpad**, on the latest message, cuts off everything below a divider into a scratchpad.

Scratchpads collect in a dock above the composer. Each card names the message its text came from and offers **Append** (put the text back onto the end of that message, as a new swipe), **Edit** and **Discard**.

## To select several messages

1. Tick the **Select message** checkbox on a message. A bulk panel opens on the right. Select **Select all** to tick every loaded message.
2. Choose an action:

   | Action | What it does |
   | --- | --- |
   | **Hide from AI** | Hides or shows the selected messages. When the selection is mixed, the first click hides them all. |
   | **Merge** | Merges a run of adjacent messages into the first. |
   | **Create memory** | Makes a memory of the selected span; see [Memory](../memory/index.md). |
   | **Delete** | Deletes the selected messages and all their swipes. |
   | **Cancel** | Clears the selection. |

## To delete a message

1. Select **Delete message** in the message header.
2. Read the confirmation and select **Delete**.

> [!WARNING]
> Deleting a message removes it and all of its swipes. If memories were made from it, the dialog lists what is rolled back with it: memories and consolidations deleted, and side-prompt results restored to how they were before.

A message whose reply is still being written can't be deleted until it finishes or you stop it.

## To stop a reply

While a reply is being written, a red **Stop** button appears at the right of the chat header. Select it or press Escape (**Stop generating (Esc)**). What was written so far is kept. Stopping also turns auto mode off and pauses the reply queue; select **Resume** in the header to carry on. See [Group chats and turn-taking](group-chats.md#the-reply-queue).

## Other message tools

| Control | What it does |
| --- | --- |
| **Inspect prompt** | Shows exactly what the shown swipe's generation sent: each section and its share of the context, the lore that activated, what happened to each injection, the variables templates wrote, the raw request and the response. See [Prompts](../prompts/index.md). |
| **Set expression** | Picks the sprite the character shows for this message by hand. See [Expressions and sprites](../characters/expressions.md). |
| **Clip** | Saves selected text to a clip in the chat's memory book. See [Clips and Memory Assistance](../memory/clips.md). |
| **Report message** | Sends the message to the site's moderators with a reason. |
| **Thinking** | A collapsible section above a reply that shows the model's reasoning, when the model sends any. |

## How messages are displayed

Messages are written in Markdown and shown formatted:

- Usual Markdown works: emphasis, lists, quotes, headings, links, tables and code.
- Quoted dialogue ("like this") and `*actions*` in asterisks get their own colors, which your theme can change. See [Appearance](../account/appearance.md).
- Math between `$…$` or `$$…$$` is typeset. A dollar amount like "$5 and $10" stays plain text.
- Some raw HTML is allowed, but it is cleaned: scripts are removed, and styles that position, size or move things, or load files, are dropped.
- Images linked from other websites are loaded through the server, or blocked, depending on the remote image setting. See [Images and attachments](../images/index.md).
- A reply that is still arriving is revealed at a steady pace with a cursor at its end.
