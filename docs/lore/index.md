---
title: Lore
order: 6
description: Lore books hold world knowledge that enters the prompt only when the chat calls for it.
---

Lore lets you write down facts about your world, its places, people and history, and have them added to the prompt only when they matter. Each fact is a lore **entry**; entries are grouped into lore **books**, and a book applies to a chat through its bindings.

You manage lore at **Lore** (`/lore`). Entries that should compete with each other are grouped in pools at **Lore pools** (`/lore/pools`), described in [Inclusion pools](pools.md).

## How lore works

On every reply, Mythweaver collects the books that are live in the chat, checks each enabled entry in them against the recent messages, and adds the entries that activate to the prompt at the position each one names. The pages in this section cover each step:

- [Entries and activation](entries.md): keywords, constant and vector entries, and where an entry's text goes.
- [Timing, budgets and recursion](timing.md): probability, sticky, cooldown, delay, recursion, the token budget and filters.
- [Inclusion pools](pools.md): letting only some of several matching entries in.
- [Vector lore](vector-lore.md): activating entries by meaning instead of keywords.

## Books and entries

A book is a named collection of entries plus the rules that apply to all of them: where it applies, its priority, its scan depth and its token budget. An entry is one piece of knowledge with its own keywords and placement.

An entry is not owned by one book. The same entry can sit in several books, and each membership has its own settings:

- **On**: switches the entry off in this book only. Its other books are untouched.
- **Order**: the entry's position in this book only. Within a slot, higher order renders later; within a custom outlet, higher order renders first.

An entry that belongs to no book never activates. Such entries are listed in the **Unlinked** folder of the tree. Deleting a book does not delete its entries: entries that were only in that book become unlinked.

When one entry is reachable through several books in the same chat, it is used once, through the book with the highest **Priority** (then the highest **Order adjustment**).

## The Lore editor

**Lore** at `/lore` shows a tree of your books with their entries, and the **Unlinked** folder. Select a book or entry to edit it in the pane beside the tree.

- **New book**, **New entry** and **Import** sit at the top of the tree. Import opens the import page; see [Import and export](../tools/import-export.md).
- The search box finds books by name, and entries by name, content or keyword.
- Drag an entry onto another book to move it there. Hold Cmd/Ctrl while dropping to copy it into that book instead, so it belongs to both.
- A book's entry list has the columns **On**, **Name**, **Activation**, **Position**, **Trigger** and **Order**. Clicking a column header sorts the list for viewing only; while it is sorted, drag to reorder is off. **Back to book order** restores it.
- Select entries or books with their checkboxes for bulk actions: **Edit entries…** / **Edit books…** change one field on all of them, and **Tag entries…** / **Tag books…** change their tags. **Remove from this book** takes an entry out of a book without deleting it; **Delete the entry everywhere** deletes it.
- Books written by Memory Books can hold memory entries; the memory actions (**Mark as memories**, **Unmark memories**, **Hide disabled memories**) are covered in [Memory](../memory/index.md).

An entry's own **Books** field also lists every book it belongs to. Its order and on/off switch are set per book, in each book's entry list.

## Where a book applies

A book has no on/off switch of its own. It is live in a chat when any of these holds:

| Source | How it applies |
| --- | --- |
| **Global (active in every chat)** | The book applies in every chat, whatever its bindings. |
| Chat binding | The book applies in each chat selected under **Bindings** › **Chats**, for every reply. |
| Character binding | The book applies in any chat where a selected character's card is part of the reply. That is the responder only, unless the chat's **Group cards** setting joins other members' cards (see [Group chats and turn-taking](../chats/group-chats.md)). |
| **Forced (every reply, cannot be turned off)** | Site books only. See [Forced books](#forced-books). |
| Memory | A character memory book chosen for the chat or locked to a character. See [Memory](../memory/index.md). |

Bindings add up: a book bound to a chat and to a character applies in that chat and wherever that character appears.

### To bind a book

1. Open the book in **Lore**.
2. Under **Bindings**, pick the chats and characters it should apply to.
3. Save. Each binding then appears in the list below the pickers.

To pause a binding without removing it, uncheck it in that list.

### To pick books from a chat

You can also choose a chat's books from the chat itself: open the chat's settings and use the **Lore books** tab. See [Chat settings](../chats/chat-settings.md). Each binding added there can be paused from the book's editor the same way.

### Activation rules

**Activation rules** only narrow where a book applies; they never add a chat. With any enabled rule, the book's entries activate only where Global, Forced or a binding already puts the book, *and* at least one enabled rule matches. A rule matches when all its conditions hold. Use **Add rule** and **Add condition** to build them, and **Not** to invert a condition.

| Condition | Matches when |
| --- | --- |
| **Chat is** | The reply is in the picked chat. |
| **Character present** | The picked character's card is in the reply. |
| **Responder is** | The picked character is the one replying. |
| **Chat has tag** | The chat carries any of the listed tags. |
| **Present character has tag** | Any present character carries any of the listed tags. |
| **Template** | A Liquid condition is true. It reads the chat's stored variables (`vars`, `globals`); see [Variables](../prompts/variables.md). |

A condition whose chat or character was deleted matches nothing.

## Site and personal books

A personal book is yours alone: only you see and use it. A site book is usable by every user and edited only by those allowed to manage site content. An admin can move a personal book to the site with **Make site book**.

> [!WARNING]
> A site book cannot be made personal again. Moving a book to the site removes every link the site may not hold: bindings to personal characters, character filters and tag filters naming personal characters or tags, its entries' memberships in other books and pools, and side prompts writing into it. The confirmation dialog lists what will change, and removed links stay removed.

### Hidden site books

**Visible to users** controls what users who are not admins see of a site book:

| Option | What users see |
| --- | --- |
| **Everything** | The whole book and its entries. |
| **Names only (runtime-only)** | The book and entry names, never their text, in the prompt inspector or scripts. |
| **Nothing (hidden)** | Nothing: users cannot see, pick or bind the book. |

Visibility limits what people see, not what is sent: a hidden book that applies to a chat still reaches the model. Admins, and anyone with the `site.hidden.view` permission, always see everything.

### Forced books

A **Forced** site book is active in every chat whether or not **Global** is set, and is sent with every reply even when a prompt has no slot for it (then as a system section at the top). No user can switch it off. User lore settings such as the token budget do not apply to it; it uses the site's lore settings and its own **Token budget**.

## Book fields

| Field | What it does |
| --- | --- |
| **Name** | The book's name in lists and pickers. It is never sent to the model. |
| **Description** | Notes for you. Activation never reads it and it is never sent to the model. |
| **Priority** | 1 to 5. Higher-priority books go first: their entries claim the lore token budget before lower books' entries, except that the replying character's own books always go first. When one entry sits in several books, the copy in the highest-priority book is used. |
| **Order adjustment** | Added to the order of every entry in this book, so you can move the whole book ahead of or behind other books without editing each entry. |
| **Token budget** | The most tokens this book's entries may add to one prompt. Empty means no per-book cap. See [Timing, budgets and recursion](timing.md#token-budget). |
| **Scan depth** | How many recent messages this book's entries search. An entry's own scan depth overrides it; empty uses the global setting. |
| **Recursive** | Lets this book's entries be activated by the text of other activated entries, not just by chat messages. |
| **Global** | Active in every chat, whatever its bindings. |
| **Forced** | Site books only. Active and delivered in every reply. |
| **Visible to users** | Site books only. See [Hidden site books](#hidden-site-books). |
| **Tag filter** / **Any of these tags** | Include: the book's entries activate only in chats where a character with one of these tags takes part. Exclude: never in those chats. Off ignores the list. |
| **Bindings** | The chats and characters the book is bound to. |
| **Activation rules** | Conditions that narrow where the book applies. |

A book imported from a character card shows the **Card book** badge. Its entries go first in their slot and skip the lore budget.
