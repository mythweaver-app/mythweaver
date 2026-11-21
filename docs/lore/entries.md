---
title: Entries and activation
order: 1
description: How a lore entry decides to activate, and where its text goes in the prompt.
---

An entry's activation settings decide when it enters the prompt; its placement settings decide where. You edit both in the entry pane of **Lore** at `/lore`.

## To create an entry

1. In **Lore**, choose **New entry**, or open a book and add the entry from its entry list.
2. Give it a **Name** and write its **Content**.
3. Choose an **Activation** mode and, for keyword entries, enter at least one keyword.
4. Pick its **Books** so it can activate. An entry in no book never activates.
5. Choose an **Outlet** and **Placement**, then save.

**Content** is a Liquid template, so it can read variables and outlets; see [Template reference](../prompts/templates.md). Content may be empty, which is useful for trigger-only entries.

## Activation modes

| Mode | When the entry activates |
| --- | --- |
| **Keyword** | A keyword appears in the scanned messages. Requires at least one keyword. |
| **Constant** | Always included, subject to its other conditions (probability, delay, cooldown, character filter, budget). |
| **Vector** | The scanned messages are close in meaning to the entry's content, or on its keywords if it has any. See [Vector lore](vector-lore.md). |

Every mode is still subject to the timing, filters and budget described in [Timing, budgets and recursion](timing.md), and to [Inclusion pools](pools.md).

## Keywords

**Keywords** are words or phrases; the entry activates when any one of them appears in the scanned messages. Type a keyword, then press Enter or comma to add it.

### Regular expressions

A keyword written as `/pattern/flags` is a regular expression, in the same form SillyTavern uses:

```text
/dragon(s|kin)?/i
/\bking\s+\w+/
```

- The flags `i`, `m`, `s` and `u` work as usual; `g` and `y` are accepted and ignored.
- A slash inside the pattern must be escaped as `\/`. A keyword with an unescaped slash inside, such as `/r/roleplay`, is treated as plain text.
- A pattern that does not compile is a save error, so a bad regex never silently fails.
- A regex's own flags take precedence over **Case sensitive** and **Whole words**.

### Case sensitivity and whole words

**Case sensitive** and **Whole words** each offer **Default**, **Yes** and **No**. **Default** follows the global setting in **Settings** › **Lore** (**Case-sensitive keywords**, off by default; **Match whole words**, on by default). See [Settings](../account/settings.md).

With whole-word matching, a single-word keyword must match a whole word: `cat` does not match `category`. Keywords that contain spaces always match as plain text. The **Word boundary** setting decides what ends a word: **ASCII (SillyTavern)** treats every non-ASCII character as a separator, so Japanese or Chinese keys match inside sentences; **Unicode** uses Unicode word characters.

### Secondary keywords

**Secondary keywords** are an optional second list, checked only after a primary keyword matches. **Logic** decides how they filter the match:

| Logic | The entry activates when |
| --- | --- |
| **AND any** | At least one secondary keyword also appears. |
| **AND all** | Every secondary keyword appears. |
| **NOT any** | None of the secondary keywords appear. |
| **NOT all** | Not every secondary keyword appears. |

Leave the list empty to activate on the primary keywords alone; **Logic** is then ignored.

## Scan depth

**Scan depth** is how many recent messages are searched for the entry's keywords, or compared against a vector entry. Empty uses the book's scan depth, then the global **Scan depth** setting (2 by default). It must be 1 or more.

## Placement

**Outlet** decides where the content goes in the prompt:

| Outlet | Where the content goes |
| --- | --- |
| **Character** | Next to the character description. |
| **Examples** | Next to the example dialogue. |
| **Author note** | Next to the author's note. |
| **At depth** | Into the chat history, **Depth** messages from the end. |
| **Custom** | Into the custom prompt outlet you pick under **Custom outlet**. See [Outlets](../prompts/outlets.md). |

**Placement** (**Before** or **After**) decides whether the content goes before or after the outlet's own text. It is not used for **At depth** or **Custom**, which are single insertion points.

The tree shows each entry's position in short form: **Char**, **EM** and **AN** for the three outlets, `@D4` for depth 4, and the custom outlet's name.

### At depth

For **At depth**, **Depth** is how many messages from the end of the chat history the content goes. Empty uses the global **Default insertion depth** setting (4 by default). **Role** sets the message role the content is sent as in the chat history: **System**, **User** or **Assistant**.

### Order within a slot

Entries in the same slot render by their effective order: their **Order** in the book plus the book's **Order adjustment**. Within a slot, higher order renders later; within a custom outlet, higher order renders first, as in SillyTavern.

Prompt blocks read the activated lore through `anchors.lore` slots such as `before_character` and `after_author_note`; see [Template reference](../prompts/templates.md).

## Entry fields

| Field | What it does |
| --- | --- |
| **Name** | The entry's name in lists. It is never sent to the model. |
| **Content** | The text added to the prompt when the entry activates. A Liquid template. |
| **Activation** | **Keyword**, **Constant** or **Vector**. |
| **Probability %** | The chance the entry is used once its conditions are met. See [Timing, budgets and recursion](timing.md#trigger-probability). |
| **Keywords** | Words that activate the entry. Required for keyword activation; optional for vector. |
| **Secondary keywords** / **Logic** | An optional second keyword list and how it filters a primary match. |
| **Scan depth** | Recent messages searched. Empty inherits. |
| **Case sensitive** / **Whole words** | Keyword matching rules. **Default** follows the global setting. |
| **Cannot be activated by recursion** | The entry activates only from the chat messages. See [Recursion](timing.md#recursion). |
| **Content does not feed recursion** | This entry's text is not searched for other entries' keywords. |
| **Ignore budget** | Never dropped for exceeding a token budget. |
| **Trigger only (activates and triggers other entries, never inserted)** | The entry activates as usual, so its text can trigger other entries and it counts toward its pools, but its text never goes into the prompt or the budget. |
| **Outlet** / **Custom outlet** / **Placement** | Where the content goes. |
| **Depth** / **Role** | For **At depth** entries. |
| **Sticky turns** / **Cooldown turns** / **Delay (messages)** / **Delay until recursion level (0 = off)** | Timing. See [Timing, budgets and recursion](timing.md). |
| **Character filter** / **Filter characters** / **Filter tags** | Which chats the entry may activate in. See [Character and tag filters](timing.md#character-and-tag-filters). |
| **Books** | The books the entry belongs to. |
| **Pools** | The inclusion pools the entry belongs to, with its weight and flags in each. See [Inclusion pools](pools.md). |
