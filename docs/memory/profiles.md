---
title: Memory profiles
order: 1
description: A memory profile picks the model and prompts memory jobs use and the lore entry settings every memory gets.
---

A memory profile is a reusable bundle of settings for memory work: which model writes the memories, which prompt each kind of job uses, and how the lore entries it writes activate and where they go in the prompt. Manage profiles at **Memory** › **Profiles** (`/memory/profiles`).

## To create a profile

1. Go to `/memory/profiles` and select **New profile**.
2. Enter a **Name**, pick a **Model** (or leave **Chat model**), and pick the prompts.
3. Adjust the entry settings and select **Save**.

To start from the built-in profile, open **Default** and use it as a model for your own.

## To make a profile the default

Open the profile and select **Make default**. The list marks it with a **Default** badge. Each owner has at most one default profile, so making one the default moves the badge from the previous one.

## Which profile a chat uses

A chat uses the profile picked in its memory **Settings** tab. When that is **Default**, it uses the chat owner's default profile, and when the owner has none, the site's default profile. A side prompt can name its own profile for the model (see [Side prompts](side-prompts.md)).

If a memory job has no model, it fails with "No model: set one on the memory profile or the chat."

## Profile fields

### Model and prompts

| Field | What it does |
| --- | --- |
| **Name** | The profile's name. |
| **Model** | The model memory jobs use. **Chat model** uses the chat's own model. |
| **Memory prompt** | Writes scene memories. |
| **Group memory prompt** | Used instead of the memory prompt when a scene has two or more non-player speakers. **Same as memory prompt** always uses the memory prompt. |
| **Consolidation prompt** | Merges memories into a higher tier. See [Consolidation tiers](consolidation.md). |
| **Compaction prompt** | Rewrites an entry more briefly when you select **Compact**. |
| **Topical clip prompt** | Writes topical clips. See [Clips and Memory Assistance](clips.md). |
| **Character memory prompt** | Writes each character book's copy of a memory from that character's perspective. **None** copies the memory verbatim. See [Character books and locks](character-books.md). |
| **Memory assistance prompt** | Reviews clips against a new scene. |
| **Topic suggestions prompt** | Suggests new topical clips. |
| **Combine clips prompt** | Merges several topical clips into one. |

Each picker lists prompts of the matching kind. A job whose prompt is **None** fails with "The memory profile has no prompt for this job." Write memory prompts like other prompts; the `anchors.memory` values available to them are listed in the [Template reference](../prompts/templates.md).

### Response

| Field | What it does |
| --- | --- |
| **Temperature (blank: model's)** | The sampling temperature. Blank uses the model's own. |
| **Max tokens** | Most tokens a memory response may use; 0 uses the model's own response limit. Default 4096. |
| **Request structured JSON output** | Asks the model for JSON output. Memory replies are JSON either way; this asks the provider to enforce it. |

### Titles

| Field | What it does |
| --- | --- |
| **Title format** | The title of each scene memory. Default `[000] - {{title}}`. |
| **Consolidation title format** | The title of each consolidation. Default `[{{tier}} 000] - {{title}}`. |

The first number token in a format (`[000]`, `[ARC 000]`, `(000)`, `{000}`, `#000` or a bare `000`) takes the entry's number, padded to as many digits as it has zeros. A format without a token gets no number. These placeholders are available:

| Placeholder | Value |
| --- | --- |
| `{{title}}` | The title the model wrote. |
| `{{scene}}` | The message range, such as `#12–#30`. |
| `{{char}}` | The chat's non-player participants. |
| `{{chat}}` | The chat's name. |
| `{{present}}` | The scene's speakers. |
| `{{user}}` | The player's name, or nothing. |
| `{{messages}}` | The number of messages in the scene. |
| `{{profile}}` | The profile's name. |
| `{{tier}}` | A consolidation's tier in capitals, such as `ARC` or `CHAPTER`. |
| `{{date}}`, `{{time}}` | The current date and time (UTC). |

### Entry settings

These are copied onto each lore entry the profile writes. They mean the same as on any lore entry; see [Entries and activation](../lore/entries.md) and [Timing, budgets and recursion](../lore/timing.md).

| Field | What it does |
| --- | --- |
| **Activation** | How the memory activates. Default is keyword activation, keyed on the memory's keywords. |
| **Outlet** | Where the entry's text is inserted. |
| **Placement** | Where within the outlet. |
| **Custom outlet** | The outlet name, when **Outlet** is a custom outlet. |
| **Depth** | The insertion depth, for depth placements. |
| **Order** | **By sequence** orders memories by their number; **Fixed** uses **Fixed order** for all of them. |
| **Fixed order** | The order value used with **Fixed**. |
| **Prevent recursion** | The memory's text does not activate other entries. |
| **Exclude from recursion** | Other entries' text does not activate the memory. |
| **Limit each memory to the characters who spoke in it** | Filters each memory to the characters who spoke in its scene, so it only activates on their turns. |

## Sharing and ownership

Profiles belong to you or to the site, like lore books. The list shows the profiles you can edit, and the chat's **Profile** picker shows the ones you can use. A profile can only reference prompts, models and books that belong to its own owner or to the site. Open a profile to export it, share it, or delete it.
