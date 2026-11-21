---
title: Inclusion pools
order: 3
description: Pools let only a few of several matching entries activate at once, picked by a weighted draw.
---

An inclusion pool limits how many of its entries can activate in one prompt. Use one for mutually exclusive variants, such as three versions of the weather or several possible moods for a character: when more of them match than the pool admits, a weighted draw picks the winners. This generalizes SillyTavern's inclusion groups, which always pick exactly one.

Pools are separate from books. Books decide which entries are available in a chat; a pool decides how many of them may speak at once. You manage pools at **Lore pools** (`/lore/pools`).

## To create a pool

1. Open **Lore pools** at `/lore/pools` and choose **New pool**.
2. Enter a **Name**, an optional **Description**, and **Admits (entries active at once)**.
3. Save.

You can also create a pool from an entry: in the entry's **Pools** field choose **New pool**, name it and choose **Create**. The entry joins the new pool when you save the entry.

## To add an entry to a pool

1. Open the entry in **Lore** at `/lore`.
2. Under **Pools**, pick the pool.
3. Set its **Weight**, and **Override** or **Scored** if needed, on the pool's row.
4. Save the entry.

A pool's page lists its entries with their weights. Members are added from each entry's own editor, not from the pool page.

## How the draw works

On each activation pass, the entries of a pool that would otherwise activate become candidates, and the pool picks among them:

1. Entries already active in this reply, and sticky members holding from earlier messages, take their slots first. A pool can therefore never exceed its limit by carrying a previous winner forward.
2. If any remaining member is marked **Scored**, only the members whose keywords match the most stay in the draw.
3. Members marked **Override** win over the others, highest order first.
4. Any slots left go to a weighted draw among the rest, using each member's **Weight**.

The losers are dropped for this reply. An entry in several pools must be drawn in each one to activate. The winners still face their probability roll and the token budget; see [Timing, budgets and recursion](timing.md).

## Pool fields

| Field | What it does |
| --- | --- |
| **Name** | The pool's name in lists and pickers. |
| **Description** | Notes for you. |
| **Admits (entries active at once)** | The most members that may activate in one prompt. 1 or more; 1 by default. |

## Member settings

These are set per membership, on the pool's row in the entry's **Pools** field, so the same entry can be a long shot in one pool and the favorite in another.

| Setting | What it does |
| --- | --- |
| **Weight** | The draw odds within the pool. 100 by default. A weight of 0 keeps the entry eligible but means it is never drawn. |
| **Override** | Wins over non-override members, by order. SillyTavern's group override. |
| **Scored** | Only members matching the most keys stay in the draw. SillyTavern's group scoring. |

> [!NOTE]
> Deleting a pool never deletes its entries; they just leave the pool.
