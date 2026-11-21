---
title: Your first chat
order: 3
description: Create two characters, start a chat, and send, regenerate, swipe and continue messages.
---

Every role-play chat in Mythweaver is a group chat with at least two participants: the character you play and at least one character the AI plays. This page creates two characters, starts a chat between them and walks through the basic message controls. You need a working model first; see [Connect a model](connect-a-model.md).

## To create two characters

1. Select **Characters** in the top bar to open `/characters`.
2. Select **New character**.
3. Fill in **Name** and **Description**. The description is what the AI reads about the character: personality, background, how they speak. Optionally add a **First message**, the character's greeting when a chat opens.
4. Select **Save**.
5. Repeat for a second character. One of the two is the character you play, so a short description of yourself is enough for it.

See [Characters](../characters/index.md) for every field in the editor.

## To start a chat

1. Select **Chat** in the top bar to return to the chat screen.
2. Select the **New chat** button at the top of the chat list.
3. In the **New chat** dialog, fill in:

   | Field | What it does |
   |---|---|
   | **Name** | The chat's name in your chat list. |
   | **Participants (pick at least 2)** | The characters in the chat. Pick both of your characters. |
   | **You play as** | The character you speak as. **Choose later** leaves it open. |
   | **Greeting** | How the chat opens: **No greeting**, **A random character**, **Every character (one message each)**, or **Narrator (write it below)**, which shows a **Narrator's message** field. Greetings use the characters' **First message**. |

4. Select **Create**. The chat opens with its participants in the rail beside the messages.

## To send a message and get a reply

1. Type in the composer at the bottom of the chat.
2. Press **Enter** or select **Send message**. Use **Shift+Enter** for a new line. On a touch keyboard, Enter adds a line and the **Send message** button sends.
3. Ask a character to reply: in the participants rail, select **Queue a reply from** *name* on the character's row. The reply streams in word by word.

A new chat uses the **manual** reply strategy, so nobody answers until you ask. To have characters answer on their own after each of your messages, change the **Reply strategy** in the chat's settings; see [Group chats and turn-taking](../chats/group-chats.md).

To stop a reply while it is being written, select **Stop** or press **Esc**.

## To regenerate a reply

If you don't like a reply, select **Regenerate this reply** under the latest message. The character writes a new version. The old version is not lost: it stays as a swipe.

## To swipe between versions

Every version of a message is kept as a **swipe**. Regenerating adds one, and so do editing and continuing. Use **Previous swipe** and **Next swipe** in the message's footer to flip between them. The version showing is the one the AI sees from then on.

## To continue a reply

When a reply stops too early, select **Continue this message** (tooltip **Continue (adds a swipe)**) under the latest message. The character keeps writing from where it ended, and the longer text is saved as a new swipe.

> [!TIP]
> Text in the composer changes what **Regenerate this reply** and **Continue this message** do: instead of being sent as a message, it guides the new reply as a one-off instruction, such as "make it shorter". See [The composer](../chats/composer.md).

## Next steps

- [Messages and swipes](../chats/messages.md): editing, hiding messages from the AI, bulk selection and deletion.
- [Group chats and turn-taking](../chats/group-chats.md): reply strategies, muting and auto mode.
- [Chat settings](../chats/chat-settings.md): the chat's model and other per-chat options.
