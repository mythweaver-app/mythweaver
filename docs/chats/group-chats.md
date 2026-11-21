---
title: Group chats and turn-taking
order: 3
description: Manage a chat's characters, decide who replies and in what order, and let the chat run on its own with auto mode.
---

Any chat with more than one character besides yours is a group chat. You decide who is in it, which character you play, and how the next speaker is picked. All of this is managed from the **Participants** rail and the chat settings.

## Participants and the player

Every character in a chat is a participant. The **Participants** rail lists them in speaking order, with **You** next to the character you play.

The character you play is the chat's player character. Automatic turns never pick it: its lines are normally the ones you type. You can still ask for a reply from it on purpose with **Queue a reply**. A chat may also have no player character (**None (spectator)**), in which case you watch and steer but don't post.

### To add or remove characters

- Select **Add characters** in the rail header, pick characters and select **Add**. Search by name or tag with **Search participants by name or tag**.
- To remove one, open its row's menu and select **Remove from this chat**, then confirm. Its earlier messages stay.
- You can also change the cast on the **Participants** tab of [Chat settings](chat-settings.md). A chat needs at least two participants.

### To change who you play

Select **Play as this character** on a participant's row. From now on your messages are posted as that character, and it becomes the chat's player character. In a shared chat this picks which of your held characters you post as; see [Sharing and the catalog](sharing.md).

### To change the speaking order

Drag a row by its handle in the **Participants** rail. The order matters for the **List order** strategy, for **Every character** greetings, and for ties elsewhere.

### To mute a character

Select the mute button on a row (**Mute in automatic replies**). A muted character stays in the scene, but automatic turns never pick it; you can still queue a reply from it yourself. The header has **Mute all characters** / **Unmute all characters**, which act on the characters your search shows, and **Hide muted characters**, which this browser remembers.

### Per-character settings in a chat

Select **Settings in this chat** on a row to open **Settings for this character**:

| Field | What it does |
| --- | --- |
| **Model** | The model this character replies with in this chat. **Chat default** uses the chat's model. Only the chat's owner can change it. |
| **Outfit** | Which set of sprites the character uses here. **Default** is its default set. See [Expressions and sprites](../characters/expressions.md). |
| **Talkativeness (blank = character default, …)** | A number from 0 to 1 that overrides the character's own talkativeness in this chat. Leave it blank to use the character's value. |

### Which model replies

Each reply uses the first model that is set of:

1. the participant's **Model** in this chat,
2. the chat's **Default model** (in [Chat settings](chat-settings.md)),
3. your default model. See [Models](../ai/models.md).

## To ask a character to reply

Select **Queue a reply** on a participant's row (**Queue a reply from …**). With text in the composer, the button becomes **Queue a guided reply from …** and the text guides that one reply; see [The composer](composer.md#guides). The reply joins the reply queue.

## Reply strategies

When you send a message, the chat's **Reply strategy** decides which characters answer. Set it on the **Replies** tab of [Chat settings](chat-settings.md).

Only eligible characters are ever picked automatically: everyone except the player character, characters other people play, and muted characters.

| Strategy | After your message | On an auto mode turn |
| --- | --- | --- |
| **Manual** (default) | Nobody replies. You pick speakers with **Queue a reply**. | One random eligible character. |
| **Natural order** | Characters named in your message reply first, then each other character speaks if a roll against its talkativeness succeeds. If nobody is picked, one random character replies, preferring those whose talkativeness is above 0. | The same, except that the last speaker is left out unless **Allow self responses** is on. |
| **List order** | Every eligible character replies, one after another, in speaking order. | The same. |
| **Pooled order** | One random character. | One character who has not spoken since your last message; once all have, a random one other than the last speaker. |

### Talkativeness

Talkativeness is a number from 0 (never volunteers) to 1 (always speaks) that **Natural order** rolls against. Each character has its own on its editor (see [Characters](../characters/index.md)), and you can override it per chat in **Settings for this character**. A character is also always picked when your message names it.

### Self responses

**Allow self responses** lets a character answer its own message on an auto mode turn under **Natural order**. Off by default, so characters take turns instead of talking to themselves.

### Max turns

**Maximum replies per turn** caps how many characters answer one message or one auto mode turn. Leave it blank (**Unlimited**) for no cap. It applies to every strategy except **Manual**.

## Auto mode

Auto mode keeps the conversation going without you. Turn it on with **Auto** in the chat header.

1. Whenever the reply queue is empty, the chat waits **Auto mode delay (seconds)** (5 by default, up to 999).
2. Then the reply strategy picks speakers for an auto mode turn, as in the table above, and their replies are queued.
3. This repeats until you turn **Auto** off, select **Stop**, or a reply fails.

Auto mode turns itself off when a queued reply can't start (for example, no model is available), so a broken setup doesn't keep retrying. It is also off after the server restarts. In a shared chat, auto mode replies are made on behalf of whoever turned it on.

## The reply queue

Replies are written strictly one at a time, so they never mix in the transcript. Select **Queue** in the chat header to see the queue:

- who is speaking now, with **Stop**,
- the waiting replies in order, each with **Remove from queue**,
- **Clear queue** to drop all of them.

Selecting **Stop** (or pressing Escape) ends the reply being written, turns auto mode off and pauses the queue with its order kept (**Queue paused**). Select **Resume** in the header, or send a message, to carry on.

## Group cards

**Group cards**, on the **Basics** tab of [Chat settings](chat-settings.md), decides which other characters' cards a reply sees besides the one replying and the player's. A card here means a character's description (the Other characters block of the prompt) and the lore books bound to that character, such as an imported card's personality and scenario.

| Option | What a reply sees |
| --- | --- |
| **Swap: only the responder's card** (default) | Only the replying character's own card, plus the player's. |
| **Join: every unmuted member's card** | The cards of every unmuted participant. |
| **Join all: every member's card, muted included** | The cards of every participant. |

Use **Swap** when characters should not know each other's details, and **Join** or **Join all** when the scene needs everyone in view. See [Prompts](../prompts/index.md) and [Lore](../lore/index.md).
