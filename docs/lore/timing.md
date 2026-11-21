---
title: Timing, budgets and recursion
order: 2
description: Probability, sticky, cooldown, delay, recursion, token budgets and filters that shape which entries reach the prompt.
---

Once an entry's keywords or activation mode say it may activate, its timing settings, filters and the token budget decide whether it actually reaches the prompt. You set them in the entry and book panes of **Lore** at `/lore`, and the global defaults in **Settings** › **Lore** (see [Settings](../account/settings.md)).

## Order of checks

Each reply runs one or more activation passes. In every pass, each remaining entry goes through these checks in order:

1. The book and entry are live in the chat and pass their tag and character filters.
2. **Delay (messages)**, cooldown and **Delay until recursion level** do not hold it back. A sticky entry skips straight to activation.
3. Its keywords, constant mode or vector similarity activate it.
4. Its [inclusion pools](pools.md) draw it.
5. It wins its probability roll.
6. It fits the token budget.

The prompt inspector shows the entries that activated and, for the rest, why they did not.

## Trigger probability

**Probability %** is the chance, from 0 to 100, that the entry is used once its conditions are met. 100 always activates. A failed roll holds for the rest of that reply, so later recursion passes don't roll it again. A sticky entry skips the roll while it sticks. The entry list shows this value in the **Trigger** column.

## Sticky

**Sticky turns** keeps an entry active for this many more messages after it activates, even without its keywords. Empty (**Not sticky**) means the entry is not sticky.

Only a fresh activation starts the sticky window; the entry holding on through its window does not push the window further out. A sticky entry also keeps its place in its pools before any new draw happens.

## Cooldown

**Cooldown turns** stops an entry from activating again for this many messages after it activates, counted after its sticky turns end. Empty (**No cooldown**) means no cooldown.

> [!NOTE]
> Sticky and cooldown are recorded when a reply is generated. Previews and the prompt inspector never change them.

## Delay

**Delay (messages)** keeps the entry from activating until the chat has at least this many messages. Empty (**No delay**) means no delay. Use it for lore that should only appear once a story is underway.

## Recursion

Activated entries can activate others: after each pass, the text of the entries that just activated is added to what the next pass searches. Passes continue until one activates nothing new.

| Control | Where | What it does |
| --- | --- | --- |
| **Recursive** | Book | Off, this book's entries match only the chat itself, never other entries' text. |
| **Cannot be activated by recursion** | Entry | The entry activates only from the chat messages, never from the text of other activated entries. |
| **Content does not feed recursion** | Entry | This entry's text is not searched for other entries' keywords, so it cannot activate them. |
| **Delay until recursion level (0 = off)** | Entry | The entry activates only on a recursion pass, never from the chat messages alone. A higher level waits until lower levels have activated nothing more. |
| **Activation passes** | Settings › Lore | The most passes per reply, the first included. 0 (the default) means no limit: passes continue until one activates nothing. |

**Trigger only (activates and triggers other entries, never inserted)** entries are handy here: they activate and feed recursion without adding their own text.

Recursion also stops when the global budget overflows.

## Token budget

Lore has a global token budget per prompt, and each book may add its own cap.

| Setting | Where | What it does |
| --- | --- | --- |
| **Lore budget (% of context)** | Settings › Lore | Share of the reply's context limit (the smaller of the model's context window and **Max context**) lore may use. Default 25%. |
| **Lore budget cap** | Settings › Lore | Most tokens of lore in one prompt, whatever the percentage gives. 0 means no cap. When the context limit is unknown, this cap applies, or 15,000 tokens when it is 0. |
| **After the budget overflows** | Settings › Lore | **Stop (SillyTavern)** admits nothing more once one entry doesn't fit, except ignore-budget entries. **Keep filling** keeps trying smaller entries. |
| **Token budget** | Book | The most tokens this book's entries may add to one prompt. Empty means no per-book cap; the global settings still apply. |
| **Ignore budget** | Entry | Never dropped for exceeding the global or book budget. Its tokens still count toward the global budget, but not its book's. |

Entry sizes are counted with the responding model's tokenizer when it has one; otherwise they are estimated as characters ÷ 3.3. The entry pane shows the size and how it was counted. Trigger-only entries and entries of a card book never count toward the budget. A forced book ignores user lore settings and uses only the site's settings and its own **Token budget**.

### Who claims the budget first

Entries claim the budget in this order:

1. Entries from the replying character's own books, so other characters' books cannot crowd them out.
2. Then books by **Priority**, highest first.
3. Then by effective order (the entry's **Order** plus the book's **Order adjustment**), highest first.
4. Then by name.

Overflowing only a book's budget drops that entry but does not count as a global overflow.

## Character and tag filters

Filters limit which chats an entry or book may activate in. They check who takes part in the chat, not who is replying.

### Entry character filter

**Character filter** has three modes:

| Mode | Effect |
| --- | --- |
| **Off** | Ignores both lists. |
| **Include** | Activates only in chats where a filter character, or a character with a filter tag, takes part. |
| **Exclude** | Never activates in those chats. |

**Filter characters** lists the characters the filter checks for. **Filter tags** adds every character carrying any of these tags.

### Book tag filter

A book's **Tag filter** with **Any of these tags** works the same way for every entry in the book: **Include** activates the book's entries only in chats where a character with one of these tags takes part, **Exclude** never in those chats, and **Off** ignores the list. Tags expand through their siblings and parents; see [Tags](../tools/tags.md).

For finer control over where a book applies, such as a particular responder or a chat variable, use the book's activation rules, described in [Lore](index.md#activation-rules).
