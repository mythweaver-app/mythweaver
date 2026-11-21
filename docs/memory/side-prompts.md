---
title: Side prompts
order: 2
description: Side prompts keep extra tracker entries, such as a plot tracker or a character's changes, up to date alongside your memories.
---

A side prompt is a tracker that runs over a range of messages and maintains one lore entry of its own, separate from the scene memories: a list of open plot threads, a cast list, or a record of how a character has changed. Each run reads the tracker's current text and the new messages, and writes an updated version. Manage side prompts at `/memory/side-prompts` and side prompt sets at `/memory/side-prompt-sets`.

## To create a side prompt

1. Write the prompt first. Go to **Prompts**, create a prompt with the side prompt purpose, and write its instructions (see [Prompts](../prompts/index.md)). The built-in **Side: Plot tracker** prompt is a good starting point.
2. Go to `/memory/side-prompts` and select **New side prompt**.
3. Enter a **Name** and pick the **Prompt**.
4. Under **When it runs**, choose **After each saved memory, over the memory's messages**, **Every N messages**, both, or neither (manual only).
5. Under **What it reads** and **The entry it writes**, adjust the fields below.
6. Select **Save**.

A side prompt with **Enabled** off never runs automatically; the list marks it **Off**. **Enabled** turns the side prompt on or off in every chat.

## To run a side prompt by hand

1. Open the chat's memory window and the **Side prompts** tab.
2. Find the side prompt. It shows when it runs (**After each memory**, **Every N messages**, or **Manual only**) and how far it has run here (**Run through #N** or **Not run in this chat yet**).
3. Fill in any macro fields it shows.
4. Set **From #** (blank: **After the last run**) and **To #** (blank: **Latest**).
5. Select **Run**.

The tab's power button turns the side prompt on or off, the same as **Enabled**. **Manage side prompts** and **Manage sets** open the managers.

When **Review memories before saving** is on, a manual run's draft waits in **Reviews** for you to save, regenerate or discard. Automatic runs save directly.

## How side prompts run automatically

A chat runs one of two things automatically, chosen by **Side prompts that run automatically** in the chat's memory **Settings** tab:

- **Individually enabled side prompts**: every side prompt you can use with **Enabled** on.
- **A set**: the rows of the chosen **Side prompt set**, instead of the enabled side prompts.
- **Default**: follows **Default side prompt set (solo chats)** or **Default side prompt set (group chats)** at `/settings/memory`. When that setting is **None**, the enabled side prompts run.

A side prompt with **After each saved memory, over the memory's messages** runs each time a memory is saved, over the same messages. A side prompt with **Every N messages** runs once that many messages have piled up past its last run in the chat. Interval side prompts run whether or not automatic memories are on.

> [!NOTE]
> A side prompt that uses runtime macros never runs automatically unless every macro has a value, which only a set row provides. Run it from a set, or by hand with the macro fields filled in.

## Runtime macros

**Runtime macros, comma separated, used as `{{ name }}`** declares values the prompt needs at run time. List names such as `character_name`, then use them in the prompt as Liquid variables: `{{ character_name }}`. Values come from a set row or from the fields in the **Side prompts** tab when you run it by hand.

Macros let one side prompt serve many trackers: one prompt, one row per character.

## Side prompt sets

A side prompt set is an ordered list of rows. Each row runs one side prompt with its own label and macro values, and keeps its own entry and its own record of how far it has run. The same side prompt can appear in several rows, for example one tracker per character.

### To create a set

1. Go to `/memory/side-prompt-sets` and select **New set**.
2. Enter a **Name**.
3. Under **Rows**, select **Add row**, pick a **Side prompt**, and enter a **Label (names the entry)**. Blank uses the side prompt's entry title.
4. Fill in a value for each macro the side prompt declares.
5. Order the rows with **Move up** and **Move down**, and remove one with **Remove**.
6. Select **Save**.

To use the set in a chat, pick **A set** and the set under **Side prompts that run automatically** in the chat's memory **Settings** tab. The **Side prompts** tab then shows **Set: name** with each row's **Run** button and **Run every row**.

If the chat's set is deleted, the tab shows "This chat's side prompt set is gone, so no side prompts run automatically. Pick another in Settings."

## Worked example: tracking a character's changes

This example keeps one entry per character listing how they have changed over the story.

1. **Write the prompt.** At **Prompts**, create a side prompt purpose prompt named "Side: Character changes". Its instructions could read:

   ```liquid
   You maintain a record of how {{ character_name }} changes over the story:
   appearance, injuries, possessions, relationships and beliefs.

   Current record:
   {{ anchors.memory.entry.content }}

   New scene:
   {{ anchors.memory.scene }}

   Rewrite the record, keeping everything still true and adding what changed
   in the new scene. Reply with the record only.
   ```

   The `anchors.memory` values are listed in the [Template reference](../prompts/templates.md).

2. **Create the side prompt.** At `/memory/side-prompts`, select **New side prompt**, name it "Character changes", pick the prompt, and enter `character_name` in the runtime macros field. Check **After each saved memory, over the memory's messages**. Under **The entry it writes**, leave **Activation** on its default so the record is always in context, or switch it to keywords and enter the character's name. Select **Save**.

3. **Create a set.** At `/memory/side-prompt-sets`, select **New set** and name it "Party changes". Add a row for each character: pick "Character changes", enter a label such as "Mira's changes", and enter `Mira` as the `character_name` value. Select **Save**.

4. **Use it in the chat.** In the chat's memory **Settings** tab, set **Side prompts that run automatically** to **A set**, pick "Party changes", and select **Save settings**.

From now on, each saved memory also updates "Mira's changes" and every other row's entry. To fill the records from the chat's start, open the **Side prompts** tab, enter **From #** 1, and select **Run every row**.

## Side prompt fields

### When it runs

| Field | What it does |
| --- | --- |
| **Name** | The side prompt's name, and its entry title unless you set one. |
| **Prompt** | The side prompt purpose prompt it runs. Deleting the prompt deletes the side prompt. |
| **Enabled** | Turns this side prompt on or off in every chat. |
| Runtime macros | Comma-separated macro names used as `{{ name }}` in the prompt. |
| **After each saved memory, over the memory's messages** | Runs after each memory is saved. |
| **Every N messages** | Runs on an interval. |
| **Messages** | The interval: messages past the last run that trigger it. Default 20. |

### What it reads

| Field | What it does |
| --- | --- |
| **Previous memories** | How many earlier memories the model reads. Default 0. |
| **Profile (model)** | The memory profile whose model it uses. **The chat's profile** uses the chat's. |
| **Include the chat's Additional Context** | Also sends the chat's additional context entries. |

### The entry it writes

| Field | What it does |
| --- | --- |
| **Lore book** | The book the entry goes to. **The chat's memory book** is the default. A chat can redirect it under **Side prompt books**. |
| **Entry title (blank: the name)** | The entry's title. |
| **Keywords** | The entry's keywords, for keyword activation. |
| **Activation**, **Outlet**, **Placement**, **Custom outlet**, **Depth**, **Order** | Entry settings, as on any lore entry. See [Entries and activation](../lore/entries.md). Activation defaults to always on. |
| **Prevent recursion**, **Exclude from recursion** | Recursion settings, as on any lore entry. See [Timing, budgets and recursion](../lore/timing.md). |
| **Ignore the lore budget** | Includes the entry even when the lore budget is full. |
| **Keep numbered versions (needs versioning on in Memory settings)** | Writes each run as a new numbered entry and switches off the older versions, instead of updating one entry. Needs **Keep side-prompt versions** on. |

## Side prompt settings

These are at `/settings/memory` under **Side prompts**.

| Setting | Key | What it does |
| --- | --- | --- |
| **Keep side-prompt versions** | `memory.side_prompt_versioning` | Keeps each earlier version of a side prompt entry when it is rewritten, for side prompts with numbered versions on. Off by default. |
| **Default side prompt set (solo chats)** | `memory.side_prompt_set_solo` | Solo chats left on **Default** run this set's rows instead of the enabled side prompts. **None** runs the enabled side prompts. |
| **Default side prompt set (group chats)** | `memory.side_prompt_set_group` | The same, for group chats. |
