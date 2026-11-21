# Weighted Provider Selection

A model is usually reachable through more than one provider connection — a local llama.cpp box, a
free hosted tier, a paid API. `Mythweaver.AI.next_provider_model/1` picks which connection serves
each generation. Two knobs control it, and they do different jobs.

## `priority` picks the tier; `weight` splits the traffic inside it

Provider `priority` (1–5, lower wins) is a **preference order**. A priority-1 connection takes every
call while it is enabled and a priority-3 connection takes none. That is what makes "free before
paid" work with no extra configuration.

Link `weight` is a **share of traffic** among connections of equal priority. It is not a second
preference order: a higher weight does not mean "try this one first", it means "send this one a
larger fraction of the calls".

## What a weight means

Weights are relative, and only their ratio matters — `3/2/1` and `30/20/10` behave identically.

Given three connections in the same priority tier with weights 3, 2 and 1:

- the weight-3 connection receives **3×** the calls of the weight-1 connection
- the weight-2 connection receives **2×** the calls of the weight-1 connection
- the weight-1 connection is **never starved** — it keeps getting its share, just less often

Over 60 calls that is exactly 30 / 20 / 10. Over 600 it is exactly 300 / 200 / 100. The split is
exact rather than approximate, and it holds at every cycle boundary rather than only "on average
eventually".

This is deliberately not the naive reading of weight, where a higher-weighted connection is simply
tried first. That approach drives one backend to exhaustion — rate limits, quota, a hot local GPU —
while the others idle. Share-of-traffic spreads the load in proportion instead.

## How it works: a virtual deadline per connection

Each link carries a `selection_deadline`, a number that only ever moves forward.

1. Selection takes the link with the **smallest** deadline (ties broken by row id, so it is
   deterministic).
2. That link's deadline advances by `1 / weight`.
3. Nothing else changes — one row is written per call.

A weight-3 link advances in steps of `1/3`, so it returns to the front of the queue three times as
often as a weight-1 link, which advances in steps of `1`. The proportion falls out of the step size.

Twelve calls across weights 3 / 2 / 1, showing every deadline before the pick:

| Call | Local (w3) | Backup (w2) | Paid (w1) | Picked | Advanced to |
|---|---|---|---|---|---|
| 1 | 0 | 0 | 0 | **Local** | 1/3 |
| 2 | 1/3 | 0 | 0 | **Backup** | 1/2 |
| 3 | 1/3 | 1/2 | 0 | **Paid** | 1 |
| 4 | 1/3 | 1/2 | 1 | **Local** | 2/3 |
| 5 | 2/3 | 1/2 | 1 | **Backup** | 1 |
| 6 | 2/3 | 1 | 1 | **Local** | 1 |
| 7 | 1 | 1 | 1 | **Local** | 4/3 |
| 8 | 4/3 | 1 | 1 | **Backup** | 3/2 |
| 9 | 4/3 | 3/2 | 1 | **Paid** | 2 |
| 10 | 4/3 | 3/2 | 2 | **Local** | 5/3 |
| 11 | 5/3 | 3/2 | 2 | **Backup** | 2 |
| 12 | 5/3 | 2 | 2 | **Local** | 2 |

Six calls in, the tally is exactly 3 / 2 / 1. Twelve calls in, every deadline has reconverged on 2
and the pattern repeats. Note the interleaving: `Local` never runs more than twice in a row, and
`Paid` is served on calls 3 and 9 rather than being deferred to the end of a block.

The table assumes `Local`, `Backup`, `Paid` in ascending row-id order, because calls 1–3 are a
three-way tie at deadline 0 and the id breaks it. Row ids are random UUIDs, so a real rotation may
open with those first three in any order; from call 4 onward the deadlines decide and the schedule is
identical either way.

Equal weights degenerate to plain round-robin — every deadline advances by 1, so every connection is
served once before any repeats.

## Why not a weighted random draw

The obvious alternative is to roll a weighted die per call, which is what LiteLLM's `simple-shuffle`
strategy does (`random.choices(..., weights=w)`) and what OpenRouter does internally with price.
It is simpler and needs no stored state, but it only hits the target ratio *in expectation*:

- Five independent runs of 600 calls at weights 3/2/1 produced 313/189/98, 319/175/106, 294/215/91,
  311/189/100 and 313/192/95 — never the exact 300/200/100.
- It clumps. The longest run on a single connection was 8–11 consecutive calls.
- It starves. Across 2000 windows of 12 calls, the weight-1 connection got **zero** calls in 11.6% of
  them.

A deadline schedule has none of those properties, at the cost of one column and one extra field in an
`UPDATE` that already happens.

## Adding, re-enabling, and re-weighting a connection

A deadline is only meaningful relative to its siblings'. A brand-new link starting at `0` while the
incumbents sit at `60` would win *every* call until it caught up — measured at 30 consecutive calls
in a three-link rotation.

So a link joining an existing rotation starts at the **smallest deadline currently in play**, which
is the standard fix from weighted fair queueing. This applies when a link is created, when a disabled
link is re-enabled, and when a link's weight changes (its in-flight deadline was accrued in the old
step size). In each case the new share takes effect from the very next call, with no catch-up burst.

One gap, accepted deliberately: re-enabling a whole **provider** reactivates all of its links at once
without rebasing them, so those links may run ahead for up to one cycle before the schedule
self-corrects. Re-enabling links individually rebases correctly.

## Setting weights

- Weights are integers, 1 or greater. `1` is the default, so an unconfigured setup is plain
  round-robin.
- There is no "0 = never use this" — disable the link (`enabled: false`) or its provider instead.
- Weight does nothing across priority tiers. To split traffic between two connections, give them the
  same provider `priority` and different weights.
- `use_count` and `last_used_at` on the link are audit fields — how many times a connection served
  and when it last did. They no longer influence selection order.
