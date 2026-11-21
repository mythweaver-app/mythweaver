---
title: Chat settings
order: 4
description: The settings dialog at /chats/:id/settings, the chat's model, and injections that steer the next replies.
---

Each chat has its own settings: its name, model, prompt, cast, lore books, how replies are made, and who else is in it. Open them with **Chat settings** in the chat header, or go to `/chats/:id/settings`.

The chat's owner and its editors can change settings. Guests can't open them.

## To change a chat's settings

1. Select **Chat settings** in the chat header.
2. Switch between the tabs. Your edits on every tab are kept until you save; a tab with an error is marked with an alert icon.
3. Select **Apply** to save and keep the dialog open, or **Save** to save and close it. **Cancel** closes without saving, and asks first if you have unsaved changes.

The **Members** tab works differently: its changes take effect at once.

## Basics

| Field | What it does |
| --- | --- |
| **Name** | The chat's name in the **Chats** rail. |
| **Default model** | The model every character replies with, unless a character has its own model in this chat. **Default model from Settings** uses your default model. Only the owner can change it. |
| **Prompt** | The prompt the chat builds its requests from. **Inherit (no chat prompt)** uses the prompt bound to the characters or your default. See [Prompts](../prompts/index.md). |
| **Group cards** | Which other characters' cards a reply sees. See [Group chats and turn-taking](group-chats.md#group-cards). |
| Tags | Your tags for the chat, used by the chat search. See [Tags](../tools/tags.md). |
| **Describe all attachments** | Describes every image, audio clip, video and document in the chat that has no description yet, skipping hidden messages. It starts right away, not on save. See [Images and attachments](../images/index.md). |

The owner also sees **Delete**, which deletes the chat and all its messages, and an export button. See [Import and export](../tools/import-export.md).

### The chat model

A reply uses the character's model in this chat if it has one, else the chat's **Default model**, else your default model. If none of those is set and you have several models, you are asked to pick one. See [Models](../ai/models.md) and [Group chats and turn-taking](group-chats.md#which-model-replies).

## Replies

| Field | What it does |
| --- | --- |
| **Reply strategy** | Who answers your messages: **Manual**, **Natural order**, **List order** or **Pooled order**. |
| **Allow self responses** | Lets a character answer its own message on an auto mode turn. |
| **Maximum replies per turn** | Caps how many characters answer one message. Blank is **Unlimited**. |
| **Auto mode delay (seconds)** | How long auto mode waits between turns, from 1 to 999. |

These are explained in [Group chats and turn-taking](group-chats.md#reply-strategies).

## Participants

| Field | What it does |
| --- | --- |
| **Participants (at least 2)** | The characters in the chat. Search by name or tag. |
| **Player character** | The character you play. **None (spectator)** plays nobody. |

## Lore books

**Lore books** lists the lore books bound to this chat. Their entries can activate in every reply. See [Lore](../lore/index.md).

## Members

The **Members** tab invites other people into the chat and sets what they may do. See [Sharing and the catalog](sharing.md#share-a-chat).

## Injections

An injection is a short piece of text that you add to a chat's prompt from outside the prompt itself, to steer the next replies. Use one for a temporary instruction, such as "It starts raining", or a reminder that should last a few replies and then go away.

Open them with **Injections** in the chat header (under **More chat tools** on small screens). The button shows how many injections are active.

### To add an injection

1. Select **Injections**, then **New injection**.
2. Fill in the fields below and select **Save**.

Each injection in the list can be edited, switched on or off, deleted, and re-armed once spent. **Clean up spent** deletes every spent injection.

### Injection fields

| Field | What it does |
| --- | --- |
| **Key** | A name for the injection. Letters, digits and underscores, not starting with a digit. |
| **Text (Liquid)** | The text to add. It is a Liquid template, rendered at the point it lands in the prompt. See [Template reference](../prompts/templates.md). |
| **Position** | Where the text goes: **Before character**, **After character**, **Before examples**, **After examples**, **Before author's note**, **After author's note** (the default), or **In chat history, at depth**. A slot position puts it after that slot's lore. |
| **Depth (0 = after the last message)** | With **In chat history, at depth**: how many messages from the end it goes. 4 by default. |
| **Role** | With **In chat history, at depth**: whether it is sent as a **System**, **User** or **Assistant** message. |
| **Condition (Liquid, optional)** | A Liquid condition, such as `vars.mood == "tense"`. The injection applies only when it is true. Blank means always. |
| **Lasts for N replies (blank = until removed)** | How many successful replies the injection is used for. Blank keeps it until you remove it. |
| **Order** | Sorts injections that land in the same place; lower comes first. 100 by default. |
| **Enabled** | Switches the injection on or off without deleting it. |

### When an injection is spent

Each time a reply finishes successfully, every limited injection used in it counts down by one. The list shows how many replies are left, such as **2 of 3 left**. A failed or stopped reply doesn't count.

When none are left, the injection is marked **spent** and no longer applies, but it stays in the list. Select **Re-arm** to give it its full count again, or **Clean up spent** to delete spent injections.

> [!TIP]
> To check what happened to an injection in a particular reply, open **Inspect prompt** on that message. Its Injections view shows each injection as applied, **disabled**, **spent**, condition false or **not placed**.

## Other chat tools

The chat header also opens these, all of which the owner and editors can use:

| Tool | What it does |
| --- | --- |
| **Memory** | The chat's memory settings and memories, at `/chats/:id/memory`. See [Memory](../memory/index.md). |
| **Variables** | The chat's variables, which templates read as `vars`. See [Variables](../prompts/variables.md). |
| **Jobs** | The background jobs of this chat. See [Jobs and analytics](../tools/jobs-and-analytics.md). |
