---
title: Characters
order: 3
description: Create and edit the characters you chat with, from their description and greetings to their avatar and tags.
---

A character is a persona the AI plays in a chat: its name, description, appearance, greetings and card prompts all feed the prompt it replies from. You manage them in **Characters** at `/characters`.

## The Characters screen

The screen has two panes. The list on the left shows every character you can use, with your favorites first, each marked with a star. The editor on the right shows the selected character, or the hint "Select a character, or create a new one." when nothing is open.

Above the list you have:

| Control | What it does |
| --- | --- |
| **New character** | Opens an empty editor at `/characters/new`. |
| **Import** | Opens the import page at `/import`, where you bring in character cards. See [Import and export](../tools/import-export.md). |
| Bulk select | Turns on checkboxes in the list so you can act on several characters at once. |
| Search | Filters the list by name, description or creator (the placeholder reads "Name, description, or creator"). |
| Tag filter | Narrows the list to characters with, or without, certain tags. See [Tags](../tools/tags.md). |
| **Expression rules** | Switches to the expression rule profiles at `/characters/expression-profiles`. See [Expressions and sprites](expressions.md). |

## To create a character

1. Select **New character**.
2. If you may create site characters, pick whether the character is personal or belongs to the site.
3. Enter a **Name**. It is the only required field.
4. Fill in whatever else you want (see [Editor fields](#editor-fields)).
5. Select **Save**.

Expression sprites can only be added after the first save; until then the editor shows "Save the character to add expression sprites."

## To edit, favorite, export or delete a character

1. Select the character in the list. Its editor opens at `/characters/<id>/edit`.
2. Change the fields and select **Save**, or select **Cancel** to throw away your edits.

The editor header also has:

- **Favorite** / **Unfavorite**, which pins the character to the top of your list with a star. Favorites are personal: other people don't see yours.
- An export button that downloads the character. See [Import and export](../tools/import-export.md).
- A delete button, which asks you to confirm before it removes the character. A character that is in a chat can't be deleted. If you delete a character that is shared with someone else, it is handed to another user instead (the message reads "Given to @handle").

Below the form, the editor has the **Expressions** section (see [Expressions and sprites](expressions.md)) and a sharing panel (see [Sharing and the catalog](../chats/sharing.md)).

## To set an avatar

1. In the editor, use the **Avatar** file picker, or drop or paste an image anywhere on the page.
2. The image uploads at once and shows as a preview. Select **Keep current** to discard it and keep the previous avatar.
3. Select **Save**. The new image becomes the avatar together with the rest of the form.

To remove an avatar, select **Remove avatar** and then **Save**.

## To fill Appearance from the avatar

Mythweaver can describe the avatar with an image-capable model and write that description into **Appearance**, so models that can't see images still know what the character looks like.

- **Automatically**: when you upload a new avatar, it is described straight away if the **Describe images automatically** setting is on and the character's **Update Appearance from a new avatar** option says yes. The text replaces **Appearance** in the form before you save.
- **On request**: select **Describe avatar** next to **Appearance**. While a new, unsaved avatar is showing, you can first type a **Question for Describe avatar (optional)** to ask something specific instead of a general description. A requested description always fills **Appearance**, whatever the option says. The button reads **Describing…** while it works.

After a description fills the field, **Revert** puts back the Appearance text you had before. Nothing is stored until you select **Save**.

> [!NOTE]
> **Describe avatar** only shows when the character has an avatar (saved or just uploaded). If no model can describe images, you see "No model can describe images." Set up a caption model as described in [Images and attachments](../images/index.md).

The site and user default for the automatic behavior is the **Update Appearance when the avatar changes** setting (`images.avatar_updates_appearance`) in [Settings](../account/settings.md). Outside the editor (scripts, imports), an Appearance someone already wrote is kept.

## Editor fields

| Field | What it does |
| --- | --- |
| **Name** | The character's name, shown in chats and used as `char` in templates. Required. |
| **Avatar** | The portrait shown beside the character's messages and in lists. |
| **Description** | Who the character is: personality, background, behavior. Supports Liquid templates. **Compact** asks a model to rewrite it shorter, using the default memory profile's compaction prompt; review the result and **Save** it, or **Cancel**. |
| **Appearance** | What the character looks like, in Markdown. **Describe avatar** and **Revert** work on this field. |
| **Update Appearance from a new avatar** | **Follow my settings** (the default), **Yes** or **No**: whether a new avatar's description replaces Appearance. |
| **First message** | The greeting the character opens a new chat with. Supports Liquid. |
| **Alternate greetings** | Extra greetings. Every greeting is attached to the opening message as a swipe, so you can switch between them. Add one with **Add alternate greeting**. |
| **Group-only greetings** | Greetings that only count in a group chat (two or more characters besides the player). In a group, the opening greeting is picked at random. Add one with **Add group-only greeting**. |
| **Creator** | Who made the character card. |
| **Creator notes** | Notes from the card's author, in Markdown. They are for people, not the model. |
| **System prompt** | The card's own system prompt. Supports Liquid. See **Card prompts** for where it goes. |
| **Post-history instructions** | Instructions placed after the chat history. Supports Liquid. |
| **Card prompts** | How **System prompt** and **Post-history instructions** apply: **Replace the prompt's tagged block** or **Add to the prompt**. See [Card prompts](#card-prompts). |
| **Character version** | A version string for the card, for your own bookkeeping. |
| **Pronouns** | The character's pronouns, available to templates. |
| **Talkativeness** | From 0 to 1, in steps of 0.05. How eager the character is to speak in a group chat: 0 only when named, 1 every turn. See [Group chats and turn-taking](../chats/group-chats.md). |
| **Visible to users** | Site characters only. **Everything** or **Only names (runtime-only)**. See [Site character visibility](#site-character-visibility). |
| Tags | Labels for sorting and filtering characters. See [Tags](../tools/tags.md). |

### Card prompts

With **Replace the prompt's tagged block**, the character's **System prompt** replaces the prompt block tagged Main prompt. Inside it, `{{ original }}` inserts the text of the block it replaces. When the prompt has no tagged block, or you pick **Add to the prompt**, the system prompt goes in before the before-character lore instead. See [Blocks](../prompts/blocks.md) for how prompt blocks are tagged.

### Site character visibility

A site character can hide its details from people who aren't admins. With **Only names (runtime-only)**, users who are not admins see only the character's name: never its description or appearance, in the prompt inspector, the assistant, scripts or exports. The model still gets the full text when it replies. Admins always see everything.
