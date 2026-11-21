---
title: Outlets
order: 2
description: Built-in lore slots and custom outlets, the named places in a prompt where activated lore lands.
---

An outlet is a named place in a prompt where activated lore lands. Mythweaver has built-in slots around the character card, the example dialogue and the author's note, and you can add **custom outlets** for anything else, such as a "world state" section or instructions that come after the chat history. You manage custom outlets at **Custom outlets** (`/prompts/outlets`).

## Built-in slots and custom outlets

Every lore entry has an **Outlet** that says where its text goes (see [Entries and activation](../lore/entries.md)). The built-in outlets fill fixed slots that blocks read through `anchors.lore`:

| Lore entry outlet | Placement | Read in a block as |
|---|---|---|
| **Character** | **Before** | `{{ anchors.lore.before_character }}` |
| **Character** | **After** | `{{ anchors.lore.after_character }}` |
| **Examples** | **Before** | `{{ anchors.lore.before_examples }}` |
| **Examples** | **After** | `{{ anchors.lore.after_examples }}` |
| **Author note** | **Before** | `{{ anchors.lore.before_author_note }}` |
| **Author note** | **After** | `{{ anchors.lore.after_author_note }}` |
| **At depth** | (not used) | Nothing: the text goes inside the chat history block, its depth counted in messages from the end. |
| **Custom** | (not used) | `{{ outlets.<key> }}`, with the custom outlet's **Key**. |

A slot or outlet that nothing activated into is empty, and a block that reads only an empty one renders nothing and is left out of the prompt.

A custom outlet does nothing until a block reads it. That is the point: you decide exactly where in the prompt its lore appears, and you can wrap it in your own text or conditions.

## To create a custom outlet

1. Open **Custom outlets** at `/prompts/outlets` and select **New outlet**. (From **Prompts**, select **Outlets** at the top of the list.)
2. Enter a **Key (stable id: lowercase, numbers, underscores)**, for example `world_state`. Lore entries store this key.
3. Enter a **Name**, which is what the lore entry's picker shows, and optionally a **Description**.
4. Select **Save**.

## To send lore to an outlet

1. Open the lore entry (see [Lore](../lore/index.md)).
2. Set its **Outlet** to **Custom**.
3. Pick the outlet in **Custom outlet**.
4. Save the entry.

**Placement** is not used for a custom outlet. When several entries activate into one outlet, their rendered text is joined with newlines.

## To place an outlet in a prompt

Add a template block that reads the outlet, and put it where you want the lore to appear (see [Blocks](blocks.md)). A plain reference works:

```liquid
{{ outlets.world_state }}
```

To add a heading only when something activated, test the outlet first:

```liquid
{% if outlets.world_state %}
[World state]
{{ outlets.world_state }}
{% endif %}
```

The block editor's **Template reference** lists every custom outlet you can use, as `{{ outlets.<key> }}` with "Lore that activated into the … outlet, rendered."

## Renaming and deleting outlets

Lore entries store the outlet's key, not the outlet itself, so you can rename an outlet freely. Keep the key the same: changing it disconnects every entry that uses the old key.

Deleting an outlet only removes it from the pickers. Entries still keyed to it keep filling `outlets.<key>`, and creating a new outlet with the same key brings it back into the pickers.

## Personal and site outlets

Like prompts and blocks, an outlet is a site outlet or a personal one (see [Site and personal prompts](index.md#site-and-personal-prompts)). If you own an outlet with the same key as a site outlet, the pickers show yours, and your chats use yours.

## The post_history outlet

A fresh installation comes with one site outlet, **Post-history instructions** (key `post_history`). The **Default Roleplay** prompt reads it in its **Post-history instructions** block, after the chat history, as SillyTavern's Post-History Instructions slot. Send a lore entry there for instructions the model should read last. A character's own post-history instructions in **Add to the prompt** mode are added ahead of this outlet's lore (see [Character overrides](blocks.md#character-overrides)).

## Outlet fields

| Field | What it does |
|---|---|
| **Owner** | Shown only when you create an outlet and may manage site content: **Personal (only me)** or **Site (every user)**. |
| **Key (stable id: lowercase, numbers, underscores)** | The id lore entries store and blocks read as `outlets.<key>`. Only lowercase letters, numbers and underscores, unique per owner. |
| **Name** | The name shown in a lore entry's **Custom outlet** picker. |
| **Description** | Notes in Markdown. |
