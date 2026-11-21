---
title: Vector lore
order: 4
description: Activate lore entries by similar meaning instead of exact keywords, using an embedding model.
---

Vector lore activates an entry when the recent messages are close in meaning to the entry's content, even when none of its keywords appear. It needs an embedding model, and works alongside keywords: a vector entry with keywords also activates on them.

## To set up vector lore

1. Add a model with the **Embedding** completion mode to one of your connections. See [Models](../ai/models.md).
2. Open **Settings** › **Lore** › **Vector matching** and pick it as the **Embedding model**.
3. In **Lore** at `/lore`, set an entry's **Activation** to **Vector** and save it.

Without an embedding model, vector entries activate on their keywords only, and the prompt inspector reports that no embedding model is set.

## Background embedding

Mythweaver turns vector entries and chat messages into embeddings in the background:

- An entry is embedded when you save or import it.
- A message is embedded when it is created, edited or finishes generating.

Replies never wait for embeddings. A reply compares only vectors that are already stored, so an entry or message that is not embedded yet simply has no vector match on that reply, and the prompt inspector says so (for example "entry not embedded yet" or "recent messages not embedded yet"). The missing embeddings are queued, so the next reply has them.

Embedding calls are recorded in analytics like other model calls. On a site model, they count toward your daily spending limit; once it is reached, background embedding stops and the rest waits.

> [!NOTE]
> Embeddings are stored per model. If you switch to another embedding model, entries and messages are embedded again with the new one in the background, and vector matches resume as those embeddings arrive. Editing an entry's content also re-embeds it.

## Scan window

A vector entry compares its content against each message in its scan window: the last **Scan depth** messages (the entry's, then the book's, then the global setting). Only the chat messages are compared, not the text of other activated entries, so vector similarity does not take part in recursion. Messages with no text, such as an image alone, and messages still generating are skipped.

## Thresholds and limits

| Setting | What it does |
| --- | --- |
| **Embedding model** | Turns Vector entries and recent messages into embeddings. None leaves Vector entries to their keywords. |
| **Minimum similarity %** | How similar, in percent, the scanned messages must be to a Vector entry for it to activate. Default 25. |
| **Most vector activations** | Most Vector entries activated by similarity per reply, most similar first. Entries their keywords activate don't count. Default 5, at most 50. |

These are in **Settings** › **Lore** › **Vector matching**, at site and user level; see [Settings](../account/settings.md). The top entries are chosen before the delay, cooldown and character filter checks, as in SillyTavern, so an entry that is later held back still uses up one of the slots.

A forced book always uses the site's embedding model, threshold and limit.

A vector entry that activates is then treated like any other: its probability, pools and the token budget still apply. See [Timing, budgets and recursion](timing.md).
