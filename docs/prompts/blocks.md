---
title: Blocks
order: 1
description: Template and chat history blocks, their roles, turning them on and off, ordering them, and character overrides.
---

A block is one section of a prompt: a piece of Liquid text, or the chat history. Blocks are reusable, so one block can sit in many prompts at different positions, and editing it changes every prompt that includes it. You manage blocks at **Prompt blocks** (`/prompts/blocks`).

## To create a block

1. Open **Prompt blocks** at `/prompts/blocks` and select **New block**.
2. Enter a **Name** and, optionally, a **Description**.
3. Choose the **Kind**: **Template** for text, or **Chat history** for the transcript.
4. Choose the **Role** it is sent as.
5. For a template block, write the **Template**. For a chat history block, choose its **Speaker roles**.
6. Select **Save**.

A new block is not in any prompt yet. To add it, open the prompt and pick it under **Add a block** (see [Arrange the blocks](index.md#arrange-the-blocks)). If you start from a prompt's **Create new block** button instead, the block is added to that prompt when you save it, and you return to the prompt. The Owner of such a block is the prompt's owner.

## To edit or delete a block

Select the block in the **Prompt blocks** list, or select the pencil button on its row in a prompt. Changes apply to every prompt that uses the block.

Deleting a block removes it from every prompt that used it. Deleting a prompt never deletes its blocks.

## Template blocks

A template block's **Template** is Liquid text. It can read the characters, the chat, activated lore, outlets and variables, and it renders fresh for every reply. For example:

```liquid
{% if anchors.chat.name %}Scene: {{ anchors.chat.name }}
{% endif %}Participants: {{ anchors.participants }}
```

The editor suggests paths, tags and filters as you type. Open **Template reference** under the field for a list of every value with its type, including one entry per custom outlet you can use. [Template reference](templates.md) covers everything in detail.

A template is checked for syntax errors when you save it. A template that renders only blank text (for example, an empty lore slot) adds nothing to the prompt, so you can keep optional sections in a prompt without leaving stray empty messages.

## Chat history blocks

A **Chat history** block has no text of its own. It marks where the transcript goes: the messages of the chat that are visible to the AI, oldest first. A prompt normally has exactly one.

For a chat model, the history becomes one message per turn, and **Speaker roles** decides each turn's role:

| Speaker roles | What the model receives |
|---|---|
| **Responder: its own lines as the assistant, everyone else's named** | The replying character's own lines are `assistant` turns without a name. Everyone else's lines are `user` turns that start with `Name: `. |
| **Fixed: characters as the assistant, the player as the user, every line named** | Every non-player character's lines are `assistant` turns and everyone else's are `user` turns, all starting with `Name: `. The turns read the same whoever replies. |

For a text model, every line is `Name: line` either way.

> [!TIP]
> In a group chat, **Fixed** keeps the history identical from one reply to the next, so a provider's or a local model's prompt cache can reuse it. With **Responder**, every change of speaker flips the roles of earlier lines and the whole history is read again.

Lore and injections placed **At depth** go inside the chat history block, counted in messages from its end. If a prompt has no chat history block, they are not placed. When a model has a context limit, the history keeps its newest turns that fit after everything else and the space kept for the reply, and the oldest turns are left out.

## Roles

**Role** is the chat role a block is sent as: **System**, **User** or **Assistant**. It matters only for chat models:

- Neighbouring blocks with the same role join into one message, so six system blocks in a row become one system message.
- A chat history block's turns take their roles from **Speaker roles**, not from **Role**.

Text models ignore roles entirely: the prompt is one string with every block joined by blank lines. Mythweaver does not invent `System:` prefixes.

## Turning blocks on and off

There are two switches, and a block renders only when both are on:

| Switch | Where | Effect |
|---|---|---|
| **Enabled** | The block editor | Turns the block off in every prompt that uses it. The list marks it **disabled**. |
| Eye button | The block's row in **Blocks in this prompt** | Turns the block off in that one prompt only. The row shows a **disabled** badge. |

A block that someone else owns and shares with you, or a site block, can also be switched off for your own chats only, from its card on **Shared** (`/shared`); see [Sharing and the catalog](../chats/sharing.md).

## Ordering blocks

A prompt's blocks render in the order of **Blocks in this prompt**. Drag a row by its handle to move it. The same block can be at a different position in each prompt that uses it.

Order matters in two ways. Templates later in the prompt see variables set by earlier ones. And for prompt caching, keep everything that changes from reply to reply (such as who replies next) after the chat history, so the text before it stays the same.

## Character overrides

A character card can carry its own **System prompt** and **Post-history instructions** (see [Characters](../characters/index.md)). **Character override** on a template block says which of them may replace the block:

| Character override | Effect |
|---|---|
| **None** | Character cards never replace this block. |
| **Main prompt (a card's system prompt replaces it)** | When the replying character has a system prompt, it renders instead of this block. |
| **Post-history instructions (a card's replace them)** | When the replying character has post-history instructions, they render instead of this block. |

The first block in the prompt with each tag is the one replaced. Inside the card's text, `{{ original }}` is this block's own rendered text, so a card can extend the block instead of discarding it.

Turn on **Ignore character overrides** to keep the block's own text even when the character has its own prompt; the card's text is then not used. It is also not used when the tagged block is turned off.

What happens to the card's text also depends on the character's **Card prompts** setting:

| Card prompts | Effect |
|---|---|
| **Replace the prompt's tagged block** | The card's text replaces the tagged block, as above. |
| **Add to the prompt** | The block keeps its own text, and the card's text is added: a system prompt goes ahead of the lore before the character, post-history instructions ahead of the `post_history` outlet. |

A prompt with no block tagged for a card prompt treats it as **Add to the prompt**. Only role-play prompts use card prompts.

## Guide and Refine blocks

Guided generations and refines from the composer need the prompt to read them (see [The composer](../chats/composer.md)). A guide is in `anchors.guide` and a refine's request in `anchors.refine`. If the chat's prompt has no block that reads them, the generation does not start and Mythweaver says "This chat's prompt has no block that reads anchors.guide, so the guide would be ignored. Add the Guide block to the prompt." (or the same for **Refine**). **Default Roleplay** includes both.

## Block fields

| Field | What it does |
|---|---|
| **Owner** | Shown only when you create a block and may manage site content: **Personal (only me)** or **Site (every user)**. |
| **Name** | The block's name, unique per owner. |
| **Description** | Notes in Markdown. Not sent to the model. |
| **Role** | **System**, **User** or **Assistant**: the chat role the block is sent as. |
| **Kind** | **Template** (Liquid text) or **Chat history** (the transcript). Switching to **Chat history** clears the template text and the character override. |
| **Speaker roles** | Chat history only. How turns get their roles; see [Chat history blocks](#chat-history-blocks). |
| **Template** | Template only. The Liquid text. Required. |
| **Character override** | Template only. Which character card prompt replaces this block; see [Character overrides](#character-overrides). |
| **Ignore character overrides** | Template only. Keeps this block's text even when a card has its own prompt. |
| **Enabled** | Off removes the block from every prompt that uses it. |
| **Visible to users** | Site blocks only. **Only names (runtime-only)** hides the block's content from users who are not admins, in any prompt, the prompt inspector, the assistant, scripts and exports; the model still gets it. |
| **Tags** | Tags for finding and filtering blocks. |

The block editor also has a **Preview** panel that renders just this block against a chat, even unsaved or turned off (see [Preview](index.md#preview)).

## The Default Roleplay blocks

The **Default Roleplay** prompt that comes with Mythweaver uses these site blocks, in this order. Every one is a **System** block. Nothing before the chat history depends on who replies (when the chat's **Group cards** setting is **Join** or **Join all**), so a prompt cache can reuse it between replies.

| Block | What it adds |
|---|---|
| Main prompt | The opening instruction, naming every participant. Tagged **Main prompt**. |
| Lore before character | Lore in the `before_character` slot. |
| Characters | Every card the reply sees, in participant order. |
| Player | The player's card. |
| Scene | The chat's name and who is in it. |
| Lore after character | Lore in the `after_character` slot. |
| Example dialogue | Lore in the examples slots. |
| Start of chat | An opener that differs for one-on-one and group chats. |
| Chat history | The transcript, with **Fixed** speaker roles. |
| Guide | A guided generation's outline. Renders nothing without a guide. |
| Author's note | Lore before and after the author's note. |
| Post-history instructions | The `post_history` outlet. Tagged **Post-history instructions**. |
| Reply as | Which character to write, and not to write for the player. Left out of a refine. |
| Refine | A refine's instructions and the message being rewritten. Renders nothing unless refining. |
