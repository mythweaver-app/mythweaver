---
title: The composer
order: 2
description: Write and send messages, recall what you sent, attach files, guide replies, and run templates and inline Lua.
---

The composer is the message box at the bottom of a chat. You write your character's messages in it, attach files, and use its text to steer the next reply.

## To send a message

1. Type in **Write a message…**. You don't have to click the box first: pressing a printable key anywhere outside a field moves the cursor there.
2. Press Enter or select **Send**. Shift+Enter adds a new line. On touch screens, Enter adds a new line and you send with **Send**.

Your message is posted as the character you play, and the chat's reply strategy decides who answers. See [Group chats and turn-taking](group-chats.md).

If you play no character in the chat, the composer is replaced by a note: the owner sees "Assign a player character to this chat to send messages.", and a guest is asked to take a character or ask the owner for one. Select **Clear message** to empty the composer.

## Drafts

What you type is saved as the chat's draft as you go. Leave the chat, reload, or open it on another device, and the text is still there. Each chat has one draft, kept for the chat's owner; sending the message clears it.

## To recall a message you sent

Press Alt+↑ (**Previous sent message**) in the composer to bring back what you sent before, and Alt+↓ (**Next sent message**) to go forward again, like a shell's command history. The arrows next to the composer do the same.

The history holds your last 200 sent messages, as you typed them (before templates ran), and is kept in this browser across all chats.

## To attach files

- Select **Attach files** (the paperclip), drop files onto the composer, or paste an image.
- Up to 4 attachments go with one message. Remove one with its **Remove** button before you send.
- Wait for uploads to finish: sending while one is still uploading is refused with "Wait for attachments to finish uploading".

Images, audio, video and documents can get text descriptions, so models that can't read them still know what they show. Depending on your settings, the composer may ask you to review descriptions before the message goes out. See [Images and attachments](../images/index.md).

## Guides

A guide steers a single reply without becoming part of the chat. When the composer has text or attachments in it, any of these takes them as the guide instead of sending them as a message:

- **Queue a guided reply from** a character, in the **Participants** rail.
- **Regenerate this reply** on the latest message.
- **Continue this message** on the latest message.

The guide is recorded on the new swipe ("Guide: …"), where you can see it in **Swipe history**. The refine button on the latest reply uses the composer text as editing instructions instead; see [Messages and swipes](messages.md#to-refine-a-reply).

> [!NOTE]
> A guide only works if the chat's prompt has a block that reads it, the Guide block. Without one you are told the guide would be ignored. See [Blocks](../prompts/blocks.md).

## Templates in your messages

The composer understands Liquid. When you send, your message is rendered as a Liquid template before it is posted, so you can use variables and logic:

```liquid
{% if vars.mood == "tense" %}I keep my hand on my sword.{% else %}I relax by the fire.{% endif %}
```

The message is posted with the result, not the template. A template error stops the send and keeps your text in the composer. See [Template reference](../prompts/templates.md) and [Variables](../prompts/variables.md). Edits are rendered the same way.

## Inline Lua

Text between `{!` and `!}` is a Lua block that runs once when you send the message. Whatever the block returns takes its place; returning nothing removes it.

```text
I roll the dice: {! return math.random(1, 20) !}
```

- The blocks are taken out before Liquid renders and run after it, so a `{% if %}` can decide whether a block runs at all.
- Blocks run in order, each one fresh. All blocks of one message share one script's time limit.
- The block itself is never stored; only its result is.
- A syntax error in any block stops the send before anything runs. A runtime error stops the send at that block, but blocks before it have already taken effect.
- If the message is blank after the blocks run and has no images, nothing is posted, and the composer is cleared.
- Lines a block prints are shown to you as notices.

Inline Lua needs permission to create scripts, and in a shared chat the **Run scripts** guest permission. The script API and the `inline` event are described in [Script API reference](../scripts/api.md).

## Quick replies

Quick replies are buttons above the composer that run one of your scripts with the composer's text. A quick reply can replace the composer text, send a message, or clear it. You need a player character to use them. See [Scripts](../scripts/index.md).

## What happens when you send

In order:

1. The send waits for uploads and for any image descriptions you need to review.
2. `{! … !}` blocks are taken out and your text is rendered as Liquid.
3. The inline Lua blocks run and their results are filled in.
4. Your scripts that react to user messages run on the text.
5. The message is posted and the composer is cleared.
6. The reply strategy queues the characters who answer. A guest without the **Trigger replies** permission only posts.
