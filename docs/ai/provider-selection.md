---
title: Priority and weight
order: 3
description: How Mythweaver chooses which connection serves a model that is linked to several.
---

A model is often reachable through more than one connection: a local llama.cpp box, a free hosted tier, a paid API. Each time a reply or background job runs, Mythweaver picks one of the model's links. Two settings control the choice, and they do different jobs: the connection's **Priority** picks the tier, and the link's **Weight** splits the traffic inside it.

## Priority picks the tier

**Priority** is set on each connection at `/ai/providers`, from 1 to 5. Lower wins. It is a strict preference order: while a model has an enabled link on a priority-1 connection, that connection takes every call, and its priority-3 connections take none.

That is what makes "free before paid" work. Give your free or local connection priority 1 and your paid API priority 3, link the same model to both, and the paid API serves the model only when the free one is unavailable.

## Weight splits traffic within a tier

**Weight (share of traffic within this priority tier)** is set on each link, under **Model connections** in a connection's editor. It is a share of traffic among a model's connections of equal priority, not a second preference order. A higher weight doesn't mean "try this one first"; it means "send this one a larger fraction of the calls".

Only the ratio between weights matters: 3, 2, 1 behaves exactly like 30, 20, 10.

With three connections in the same tier at weights 3, 2 and 1:

- the weight-3 connection gets three times the calls of the weight-1 connection,
- the weight-2 connection gets twice the calls of the weight-1 connection,
- the weight-1 connection is never starved: it keeps getting its share, just less often.

The split is exact, not approximate. Over 60 calls it is exactly 30, 20 and 10, and the calls are interleaved, so no connection is hit many times in a row.

Spreading calls this way keeps one backend from being driven into its rate limits, quota or a hot GPU while the others sit idle.

## A worked example

You have one model linked to three connections, all at priority 2:

| Connection | Weight |
|---|---|
| Local | 3 |
| Backup | 2 |
| Paid | 1 |

Twelve replies in a row are served like this:

| Reply | Served by |
|---|---|
| 1 | Local |
| 2 | Backup |
| 3 | Paid |
| 4 | Local |
| 5 | Backup |
| 6 | Local |
| 7 | Local |
| 8 | Backup |
| 9 | Paid |
| 10 | Local |
| 11 | Backup |
| 12 | Local |

After six replies the tally is exactly 3, 2 and 1, and after twelve it is 6, 4 and 2. Then the pattern repeats. Local never runs more than twice in a row, and Paid is served on replies 3 and 9 instead of waiting until the end of a block. The first three replies may come in any order, since all three start even; from then on the schedule is the same.

Now add a fourth connection, Free, at priority 1, and link the model to it. Free takes every reply while it and its link are enabled; Local, Backup and Paid get none. Switch Free off and the three priority-2 connections pick up where their 3:2:1 split left off.

## Fallback

A connection or link that is switched off drops out of the rotation, and the next tier takes over:

- If every enabled link in the lowest-numbered tier is gone, the next tier serves the model.
- Within a tier, the remaining links share the traffic by their weights.
- If the model has no enabled link on an enabled connection, it can't run.

**Priority** decides among connections that are switched on. To take a connection out of use, untick **Enabled** on the connection, or click **Disable** on its link to stop it serving one model.

## Adding, re-enabling and re-weighting

When you add a link to a model that is already rotating, re-enable a link, or change a link's weight, the change takes effect from the next call, at its new share. A new link doesn't get a burst of calls to "catch up" with the others.

> [!NOTE]
> Re-enabling a whole connection (ticking **Enabled** on it) brings back all its links at once without this adjustment, so they may get more than their share for up to one cycle before the split settles. Re-enabling links one at a time with **Enable** avoids it.

## Setting weights

- Weights are whole numbers, 1 or more. The default is 1, so a model whose links you never touch rotates evenly (plain round-robin).
- There is no weight 0. To stop using a connection for a model, click **Disable** on the link, or switch the connection off.
- Weight does nothing across tiers. To split traffic between two connections, give them the same **Priority** and different weights.
- The "used" count in a link's summary (for example "weight 3 · used 120x") shows how many calls the link has served. It is a record only and doesn't affect selection.
- **Send test message** goes straight to the link you test and never counts toward the rotation.
