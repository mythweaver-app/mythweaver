---
title: Tags
order: 4
description: Organize characters, lore, prompts and more with namespaced tags, siblings and parents, and filter any list by them.
---

Tags label your items so you can find and group them. They work like Hydrus tags: a tag can have a namespace (`series:metroid`), can be shown as another tag (a sibling), and can imply other tags (parents). You manage them at **Tags** (`/tags`) and filter lists by them everywhere.

## What can be tagged

Characters, chats, lore books, lore entries, prompts, prompt blocks, scripts and AI models. Each editor has a **Tags** field: type a tag and press Enter to add it, or click its remove button to take it off. A character card you import brings its tags along; see [Import and export](import-export.md).

## Tag text

A tag is `namespace:name` or just `name`, for example `series:metroid`, `genre:horror` or `favorite`. Everything up to the first `:` is the namespace. Tags are stored lowercase with whitespace collapsed, so `Series: Metroid` and `series:metroid` are the same tag.

A tag can't start with `-`, can't contain `*`, and needs a name. Namespaces are limited to 64 characters and names to 200.

## Site and personal tags

| Kind | Who sees it | Who edits it |
|---|---|---|
| **Site** (every user) | Everyone. | Administrators who hold `site.content.manage`. Site tags can be put only on site items. |
| **Personal** (only me) | Only you. No other user, admin or not, sees your personal tags or their rules. | You. You can put them on any item you can see. |

Creating a new personal tag needs the `content.tags.create` permission. A site tag and a personal tag with the same text are treated as one tag everywhere.

## Siblings and parents

- A **sibling** ("Displays as") says: wherever this tag appears, show that one instead. Use it to merge spellings, for example `lotr` displays as `series:the lord of the rings`. A tag has at most one sibling.
- **Parents** say: every item with this tag also counts as having these. For example `character:samus aran` with parent `series:metroid` makes every Samus item match a `series:metroid` filter.

Items store only the tags you put on them. Siblings and parents are applied when tags are shown and filtered, so changing a rule updates every item at once. Your personal rules override the site's sibling for the same tag; parents from both are combined.

## To create or edit a tag

1. Open **Tags** at `/tags`. The left pane lists **Site tags** (everyone sees these) and **My tags** (only you see these), each with its item count.
2. Click **New tag**, or select an existing tag.
3. Fill in the form and click **Save**.

| Field | What it does |
|---|---|
| **Tag text** | The tag, as `namespace:name`. Stored lowercase. |
| **Owner** | **Personal (only me)** or **Site (every user)**. Only administrators see the site option. |
| **Displays as** | The sibling to show in this tag's place. |
| **Parents** | Tags this one implies. |

Below the form you see the tags **Shown as this tag** (tags whose sibling is this one), its **Children** (tags with this as a parent), and **Items with this tag**, each linking to its editor.

**Delete** removes the tag from every item and filter.

### To edit many tags at once

Turn on select mode in the tag list, select tags, and choose an action: delete them, set their **Displays as**, **Add parents** or **Remove parents**.

## To filter a list by tags

Lists such as the character, lore, prompt, script, model and chat lists have a tag filter in their search bar. Enter one or more chips; an item must match all of them.

| Chip | Matches |
|---|---|
| `series:metroid` | Items with that tag, directly or through a sibling or parent. |
| `-color:red` | Items without that tag. |
| `character:*` | Items with any tag in the `character` namespace. |
| `-character:*` | Items with no tag in that namespace. |

The placeholder shows an example: `series:metroid  -color:red  character:*`. A chip that isn't valid is marked with the reason, such as *\* must be a namespace wildcard like series:\**.

Tags can also be used by lore books to include or exclude entries; see [Timing, budgets and recursion](../lore/timing.md).
