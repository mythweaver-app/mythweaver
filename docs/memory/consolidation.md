---
title: Consolidation tiers
order: 3
description: Consolidation merges many memories into fewer, larger summaries, tier by tier from Arc up to Epic.
---

Consolidation keeps a very long chat's memory book small. It merges a run of scene memories into one **Arc**, several arcs into a **Chapter**, and so on up to **Epic**. Each consolidation reads the entries one tier below, writes one or more summaries of them, and by default switches the sources off so only the summary is sent to the AI.

## The tiers

| Tier | Made from |
| --- | --- |
| **Memory** | Chat messages (a scene memory). |
| **Arc** | Memories. |
| **Chapter** | Arcs. |
| **Book** | Chapters. |
| **Legend** | Books. |
| **Series** | Legends. |
| **Epic** | Series. |

An entry can be consolidated only into the tier directly above it, only once, and only while it is switched on in its book.

## To consolidate memories

1. Open the chat's memory window and the **Consolidate** tab, or run **chat: consolidate memories** from the [command palette](../tools/command-palette.md).
2. Pick the **Source book**: the chat's memory book or another book whose memories you can edit.
3. Pick **Consolidate into**, such as **Arc (from memories)** or **Chapter (from arcs)**.
4. Pick the **Prompt** (the profile's consolidation prompt is preselected).
5. Pick the **Sources**: the eligible entries of that tier. The form shows how many passes the pick needs.
6. Leave **Disable the sources once consolidated** on to switch the sources off after saving.
7. Select **Consolidate**.

If nothing is eligible, the tab says so, for example "Nothing to consolidate into Arc yet".

### Passes

A large pick is split into consecutive passes, each one consolidation job. A pass reads at most **Max entries per pass** entries and **Token budget per pass** tokens of entry text. An entry over the budget on its own gets a pass to itself. Both fields start from your `/settings/memory` values.

## To review a consolidation

When **Review consolidations before saving** is on (the default), each pass waits in **Reviews**. The model may propose more than one summary; each shows:

| Field | What it does |
| --- | --- |
| **Keep this summary** | Uncheck to drop this summary. At least one must be kept, or discard the draft. |
| **Title** | The summary's title, before the profile's **Consolidation title format** is applied. |
| **Summary** | The summary text. |
| **Keywords** | The summary's keywords. |
| **Regenerate this summary** | Writes this one summary again over the same sources. |

**Left out** lists sources the model assigned to no summary. If you save with entries left out, you are asked to confirm; those entries stay unconsolidated and can be picked again later.

Saving writes one entry per kept summary, links its sources, marks them **Consolidated**, and switches them off when you asked. If a source was edited, deleted or consolidated elsewhere since the job started, saving fails with "The source changed since this was generated."

## Readiness notices

Mythweaver can tell you when a tier has enough entries to consolidate. After a save, each watched tier with at least its minimum of eligible entries is announced in the chat ("Ready to consolidate: Arc") with a link to the **Consolidate** tab, and kept in your notification inbox until the tier is no longer ready. Nothing is consolidated automatically.

## Regenerating and rolling back

**Regenerate** on a consolidation in the **Entries** tab rewrites it over its own sources, keeping its number. When rollback on message deletion is on, deleting a memory's message also deletes every consolidation built on it and switches its sources back on (see [Memory](index.md#rollback-on-message-deletion)).

In the lore book editor, an entry's **Type** shows whether it is a scene memory or a consolidation tier, and **Sources (memories)** and **Consolidated into** show how entries are linked. This lets you consolidate memories you imported and marked with **Mark as memories**.

## Consolidation settings

These are at `/settings/memory` under **Consolidation**.

| Setting | Key | What it does |
| --- | --- | --- |
| **Announce when ready** | `memory.consolidation_watch_tiers` | Tiers whose readiness is announced. All tiers by default. |
| **Arc minimum** | `memory.consolidation_minimum_1` | Eligible entries that make the arc tier ready. Default 5. |
| **Chapter minimum** | `memory.consolidation_minimum_2` | Default 4. |
| **Book minimum** | `memory.consolidation_minimum_3` | Default 4. |
| **Legend minimum** | `memory.consolidation_minimum_4` | Default 3. |
| **Series minimum** | `memory.consolidation_minimum_5` | Default 3. |
| **Epic minimum** | `memory.consolidation_minimum_6` | Default 3. |
| **Max entries per pass** | `memory.consolidation_max_entries` | Most entries one pass reads; more are split into further passes. Default 20. |
| **Token budget per pass** | `memory.consolidation_token_budget` | Most tokens of entries one pass reads. Default 12,000. |
| **Review consolidations before saving** | `memory.show_consolidation_previews` | Sends each pass to **Reviews** before it replaces its sources. |
