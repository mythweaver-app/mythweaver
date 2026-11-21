---
title: Clips and Memory Assistance
order: 4
description: Save highlighted passages as clips, gather a topic into one topical clip, and let Memory Assistance keep them current.
---

Clips hold details you want the AI to remember exactly, outside the scene memories. A **clip** is an entry you build by hand from highlighted passages, one line per passage. A **topical clip** is an AI-written entry that gathers everything about one topic (a sword, a city, a relationship) from your memories and messages. **Memory Assistance** reviews clips after each new memory and suggests updates and new topics.

## To clip a passage

1. Highlight text in a message. A small toolbar appears.
2. Select **Clip**.
3. In the **Clip** dialog, check the **Text**.
4. Under **Add to**, choose **New clip** or an existing clip.
5. For a new clip, enter a **Title** and pick its **Activation**: **By keyword (the title)** or **Always**.
6. Select **Save clip**.

No AI is involved. The text is trimmed, its line breaks become spaces, and it is added as a line of the clip in the chat's memory book. A clip's entry is framed by `=== Title ===` and `=== END Title ===` lines, and new lines go before the end marker.

## To make a topical clip

1. Open the chat's memory window and the **Topical clip** tab. Or highlight text in a message and select **Extract**, which opens the tab with the message search filled in and that message picked.
2. Pick the **Book** the clip goes to (**Chat memory book (created on save)** by default).
3. Under **Clip**, keep **New topical clip** or pick an existing one to update.
4. Enter a **Topic**, such as "Mira's sword", and optional **Keywords** (default: the topic).
5. With **Include memories** on, pick the **Memories** to draw from.
6. Optionally turn on **Include chat messages** and choose **Messages**: **A range** (**From #** and **To #**) or **Picked messages**. To pick, use **Search messages** (with **Hidden messages only** to find hidden ones), then check messages, **Pick all shown** or **Clear picks**.
7. Select **Create clip** (or **Update clip**).

Topical clips are always reviewed: the draft appears in **Reviews** with its **Title**, **Draft** text and **Keywords** for you to save.

### Updating a topical clip

When you update a clip, only the sources that are new or changed since it was written are sent, along with the clip's current text. Check **Rebuild from every picked source (otherwise only new and changed ones are sent)** to rewrite it from scratch. If nothing is new, the tab says "Nothing new or changed since this clip was written: pick more sources, or rebuild."

### Combining topical clips

Under **Combine clips** in the same tab, pick two or more topical clips of the book, enter a **Title**, and select **Combine**. The keywords are the union of the clips' keywords. The draft goes to **Reviews**. With **Disable the original clips after saving** on, the originals are switched off, never deleted.

## Memory Assistance

Memory Assistance runs after each new scene memory and compares the scene with the book's clips.

- **Clip updates**: for an ordinary clip, it suggests a **New clip line**; for a topical clip, a **Revised clip** (select **Current** to compare). Each suggestion has **Keep this update** and notes the message it came from.
- **Topic suggestions**: it proposes **Suggested topical clips**, each with **Create this topical clip**, a **Topic** and **Keywords**. You can add your own under **Add a topic**.

Suggestions wait in **Reviews**. Saving a topic suggestion queues a topical clip draft for each kept topic. Pending topics also appear under **Suggested topics** in the **Topical clip** tab, where **Draft** writes the clip and **Dismiss** removes the topic.

### Memory assistance setting

Pick the mode at `/settings/memory` under **Memory assistance** (`memory.assistance_mode`).

| Option | What it does |
| --- | --- |
| **Off** | No Memory Assistance. The default. |
| **Suggest clip updates** | Reviews existing clips against each new scene. |
| **Suggest new topics** | Suggests new topical clips. |
| **Suggest updates and new topics** | Both. |
| **Apply clip additions automatically** | Adds new clip lines without review ("Added N clip lines automatically.") and leaves topical clip rewrites for review. |

The prompts are the profile's **Memory assistance prompt** and **Topic suggestions prompt** (see [Memory profiles](profiles.md)).

## Compacting entries

**Compact** rewrites an entry more briefly with the profile's compaction prompt. In the memory window's **Entries** tab, the result waits in **Reviews** with **Original** and **Draft**. The lore entry editor also has a compact button that rewrites the text in the form without saving.
