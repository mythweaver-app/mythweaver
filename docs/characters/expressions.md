---
title: Expressions and sprites
order: 1
description: Show a character's mood with sprite images that replace its portrait, chosen by a classifier model or by hand.
---

Expressions let a character's messages show a sprite that matches the mood of what it says, such as a smiling image for joy, in place of its usual portrait. A classifier model rates each message's emotions, and Mythweaver picks the expression and one of its sprites. You can also set an expression by hand.

Expressions are off until you choose a classifier model, and they only apply to characters that have sprites.

## How expressions work

1. A character finishes a reply, or you send or edit a message as the player.
2. If the **Classifier model** setting is set, the chat is a role-play chat, the author is a character with sprites and the message isn't blank, the model rates how strongly the message expresses each emotion, from 0 to 100.
3. The scores go through the character's rule profile, which picks one expression label (see [How the expression is chosen](#how-the-expression-is-chosen)).
4. A sprite with that label, from the character's current outfit, appears beside the message in place of the portrait. When nothing matches, the message keeps the portrait.

### Emotion labels

The classifier always rates the 28 base emotions: admiration, amusement, anger, annoyance, approval, caring, confusion, curiosity, desire, disappointment, disapproval, disgust, embarrassment, excitement, fear, gratitude, grief, joy, love, nervousness, optimism, pride, realization, relief, remorse, sadness, surprise and neutral.

A character can add its own **Custom expressions**, which a chat or text classifier rates as well. A rule profile adds more labels on top: each enabled rule's name is an expression derived from the scores.

## To turn expressions on

1. Open **Settings** at `/settings` and go to the **Expressions** category.
2. Under **Classification**, set **Classifier model** to a model. **None** (the default) keeps expressions off and costs nothing.
3. Add sprites to at least one character (see [To add sprites](#to-add-sprites)).

The model you pick changes how classification runs:

| Model kind | How it classifies |
| --- | --- |
| A chat or text model | Asked once per message with the **Classifier instruction**. Each call shows in **Jobs** (see [Jobs and analytics](../tools/jobs-and-analytics.md)). It rates the base emotions and the character's custom expressions. |
| A classifier model | A GoEmotions sequence classifier served by llama-server. It scores the message directly in a few milliseconds, and rates only the 28 base emotions. |

See [Models](../ai/models.md) for setting a model's completion mode.

## To add sprites

Sprites live in the **Expressions** section of the character editor, below the main form. Save a new character first.

1. Open the character at `/characters/<id>/edit` and scroll to **Expressions**.
2. Pick an outfit tab: **Default**, or one of your outfits.
3. Add images in one of these ways:
   - **Add sprites (named like joy.png, joy-2.png)**: upload one or more images. Each file's name gives its label: `Joy.png`, `joy-2.webp` and `joy.expressive.png` all become `joy`. A file whose name isn't a usable label is refused with "no expression in the file name".
   - **Add** on a label in the grid: the next upload goes to that label whatever the file is called. The bar shows "Adding to:" followed by the label; select the **×** to stop.
   - **Import sprite pack (.zip)**: a SillyTavern sprite pack, a ZIP of images named like `joy.png`. See [Sprite packs](#sprite-packs).
4. The grid shows each label with its sprites. Delete a single image with **Delete sprite**.

A label you upload that the character doesn't know yet is added to its **Custom expressions** automatically ("New expressions: …").

A label can have several sprites. One is picked at random each time, and with **Avoid repeating a sprite** on (the default), the one the character's previous message showed is skipped.

### Sprite packs

A sprite pack is a ZIP archive of images:

- Images at the top level go into the outfit tab that is open.
- Images one folder deep go into an outfit named after the folder, which is created if it doesn't exist ("New outfits: …").
- Deeper files, files whose names aren't labels, and files that aren't images are skipped and listed ("Skipped: …"). Folders, `__MACOSX/` and hidden files are ignored.

A pack can hold at most 1,000 files and 500 MB unpacked, and the ZIP itself at most 200 MB.

## Outfits

An outfit is a named set of sprites, for example the same character in different clothes. Sprites not in any outfit form the **Default** set.

- To add one, type a name in **New outfit** and select **Add outfit**.
- To delete the open outfit and all its sprites, select **Delete outfit** and confirm.
- To use one in a chat, pick it in the character's **Outfit** option among the chat's participants (see [Group chats and turn-taking](../chats/group-chats.md)). **Default** uses the Default set.

When the chosen outfit has no sprite that matches a message, the Default set is tried before falling back to the portrait.

## Character expression settings

The top of the **Expressions** section has the character's own settings. Select its **Save** button to keep changes.

| Field | What it does |
| --- | --- |
| **Rule profile** | The expression rule profile this character uses. **Default (settings)** uses the **Default rule profile** setting. |
| **Fallback expression (when nothing matches)** | The label to show when no emotion or rule wins. It must have a sprite; otherwise the portrait shows. |
| **Custom expressions** | Extra labels for this character. Type a label, then press Enter. Remove one with the **×** on its grid row; its sprites stay until you delete them. |

In the grid, labels from the rule profile carry a **rule** badge and the character's own labels a **custom** badge.

## Expression rule profiles

A rule profile adds derived expressions to the base emotions, after the expressions-plus extension for SillyTavern. For example, an "elated" rule can win when joy and excitement score high together. Manage profiles in **Expression rules** at `/characters/expression-profiles`, reached with the **Expression rules** switch above the character list.

### To create a profile

1. Select **New profile**.
2. If you may create site profiles, pick personal or site.
3. Enter a **Name**.
4. Select **Add rule** for each rule, fill it in (see [Rule fields](#rule-fields)) and add its emotions with **Add emotion**.
5. Select **Save**.

To use the profile, pick it as a character's **Rule profile**, or make it the **Default rule profile** in **Settings**. Deleting a profile makes characters that use it fall back to the default profile.

### Rule fields

| Field | What it does |
| --- | --- |
| **Expression** | The label the rule produces, such as `elated`. It only wins if the character has a sprite with this label. |
| **Kind** | **Combination** or **Range**. |
| **Max difference between emotions, %** | Combination rules only (default 25). How far below the strongest of the listed emotions each of the others may score. |
| **Enabled** | Turn a rule off without deleting it. |
| **Emotion** | One emotion the rule looks at, such as `joy`. A rule has one or more. |
| **Min %** / **Max %** | Range rules only. The bounds the emotion's score must fall in. Either may be left empty. |

Remove a rule with **Remove rule** and an emotion with **Remove emotion**.

- A **Combination** rule matches when every listed emotion scores above zero and within the maximum difference of the strongest of them. It scores higher than any one of its parts, so a good blend beats a single emotion.
- A **Range** rule matches when every listed emotion's score lies within its bounds. It scores the average of those emotions.

### How the expression is chosen

1. The best-scoring emotion that has a sprite is a candidate, if its score is above zero.
2. Each enabled rule that has a sprite and matches is a candidate.
3. The highest score wins. On a tie, a rule beats a plain emotion, then a rule with more emotions wins, then the earlier rule.
4. When nothing matches, the **Fallback expression** is used if it has a sprite; otherwise the message shows the portrait.

## To set an expression by hand

1. On a character's message in the chat, choose **Set expression** from the message menu.
2. Pick a label. Only labels with a sprite in the character's outfit or its Default set are offered. **Portrait (no expression)** goes back to the portrait.

The message then shows "· set by hand" next to its expression. Classification leaves a hand-picked expression alone, even when the message is edited or classified again in the background.

To let the classifier choose again, open **Set expression** and select **Classify again**. This needs a **Classifier model**; without one you see "Set a classifier model in Settings → Expressions first".

The expression applies to the message's active swipe. If the character has no sprites, the picker says "No sprites for this character." with an **Add some** link to the editor.

## Expression settings reference

These live in the **Expressions** category of **Settings**. Site admins set the defaults, and each user can override them. See [Settings](../account/settings.md).

| Setting | What it does |
| --- | --- |
| **Classifier model** (`expressions.classifier_model`) | The model that rates each reply and each message you send. **None** turns expressions off. Default: none. |
| **Classifier instruction** (`expressions.classifier_prompt`) | What a chat or text classifier is told before the message. Liquid, with `labels` (the emotions to rate, comma separated) and `char` (the character's name). It must ask for `{"scores": {emotion: 0-100}}`. Empty uses the built-in instruction. |
| **Ask for structured output** (`expressions.structured_output`) | Send a JSON schema with each request, for backends that support `response_format`. Default: off. |
| **Default rule profile** (`expressions.default_profile`) | The rules for characters that don't pick their own profile. **None** uses the base emotions only. |
| **Avoid repeating a sprite** (`expressions.reroll_if_same`) | When an expression has several sprites, don't show the one the character's previous message used. Default: on. |

> [!TIP]
> A chat or text classifier's reply that can't be read is retried once with a repair request. If expressions never appear, check **Jobs** for failed expression jobs, and try turning on **Ask for structured output** if your backend supports it.
