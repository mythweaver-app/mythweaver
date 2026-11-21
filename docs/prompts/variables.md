---
title: Variables
order: 4
description: Chat and global variables, how to edit them, and how templates read and write them with vars, globals and setvar.
---

Variables let templates remember things between replies: a turn counter, the current location, a character's mood, a running inventory. A **chat variable** belongs to one chat. A **global variable** applies to every chat, either yours or, for site globals, everyone's. Templates read them as `vars` and `globals` and write them with `{% setvar %}` and `{% setglobalvar %}`.

## Chat and global variables

| Kind | Belongs to | Edited at | Read in templates as |
|---|---|---|---|
| Chat variable | One chat | The chat's **Variables** dialog | `vars.<key>` |
| Your global variable | You; used by every chat you own | **Variables** at `/variables` | `vars.<key>` (unless the chat has its own) or `globals.<key>` |
| Site global variable | The site; used by every chat | **Variables** at `/variables`, by users who manage site content | `vars.<key>` or `globals.<key>`, unless the chat owner has their own global with that key |

Every variable has a **Key** and a value. The value can be any JSON value: text, a number, `true` or `false`, a list or an object.

## To view or edit a chat's variables

1. In the chat, open the **More chat tools** drawer and select **Variables**. You can also run **chat: variables** from the [command palette](../tools/command-palette.md).
2. The **Variables** dialog lists every variable in the chat with its value, or says "No variables in this chat".
3. To add one, select **New variable**, enter a **Key** and a **Value (JSON, or plain text)**, and select **Save**.
4. To change one, select its edit button (**Edit** *key*), change the value and select **Save**. To remove it, select its delete button.

Anyone who can inspect the chat can see its variables; changing them needs the right to manage the chat.

## To manage global variables

1. Open **Variables** at `/variables` (or run **variables: open** from the command palette).
2. Select **New variable**.
3. If you manage site content, choose the **Owner**: **Personal (only me)** for your own global, or **Site (every user)** for a site global.
4. Enter a **Key** and a **Value (JSON, or plain text)**, then select **Save**.

Select a variable in the list to edit it, or **Delete** to remove it. The search box matches keys and values. The list shows your own globals, plus the site's if you manage site content.

## Values

The value box takes JSON. Anything that isn't valid JSON is stored as plain text.

| You type | Stored as |
|---|---|
| `42` | The number 42 |
| `2.5` | The decimal 2.5 |
| `true` | True |
| `[1, 2, 3]` | A list |
| `{"gold": 10, "items": ["rope"]}` | An object |
| `"quoted"` | The text `quoted` |
| `the old mill` | The text `the old mill` |

## Reading variables in templates

| Path | What it reads |
|---|---|
| `vars.<key>` | The chat variable with that key; if the chat has none, the global variable with that key. |
| `globals.<key>` | Only the global variable: the chat owner's own, else the site's. |

An unset variable is `nil` and renders as nothing. Use `default` for a fallback, and dot or bracket access for lists and objects:

```liquid
Location: {{ vars.location | default: "unknown" }}
Gold: {{ vars.inventory.gold }}
First item: {{ vars.inventory.items[0] }}
```

Globals are read from the chat **owner's** point of view, so in a chat someone else owns, you see their globals, not yours.

## Writing variables from templates

Two tags write variables while a prompt renders:

| Tag | Writes |
|---|---|
| `{% setvar key = value %}` | A chat variable in the chat being rendered. |
| `{% setglobalvar key = value %}` | A global variable of the chat's owner. It never writes a site global. |

The value is any Liquid expression, filters included. Setting a variable to `nil` deletes it. A key starts with a letter or underscore, continues with letters, digits or underscores, and is at most 64 characters; otherwise the template fails with "Variable name must be a plain identifier of at most 64 characters".

```liquid
{% setvar turn = vars.turn | default: 0 | plus: 1 %}
{% setvar mood = "wary" %}
{% setvar old_location = nil %}
```

A write is visible at once to the rest of that template and to every template that renders after it in the same prompt. A written value keeps its type: numbers stay numbers, lists stay lists, and decimals are stored as decimals.

### When writes are saved

> [!IMPORTANT]
> Writes are saved only by a real reply, at the moment Mythweaver sends the prompt to the model. Stopping the reply or an error afterwards does not undo them, so a regenerate runs the templates again and writes again.

Writes are never saved by:

- The **Preview** panel on the prompt and block editors.
- Any other prompt inspection.
- A message you type. Messages can read variables but not write them; a write in a message is dropped with the notice "Variable writes in messages are ignored."

To see what a reply wrote, open its prompt inspector and select the **Variables** tab (see [The prompt inspector](index.md#the-prompt-inspector)).

## Example: a turn counter

1. Create a template block named "Turn counter" with this template, and add it near the end of your prompt:

   ```liquid
   {% setvar turn = vars.turn | default: 0 | plus: 1 %}
   [This is turn {{ vars.turn }} of the story.]
   ```

2. Open the chat and let a character reply. The chat's **Variables** dialog now shows `turn` with the value `1`, and each reply adds one.
3. To start over, delete `turn` in the dialog or set it to `0`.

## Variables in lore and scripts

Lore entries and character descriptions are templates too, so they can read and write variables the same way; they render before the prompt's blocks. Lua scripts can also read and write chat and global variables (see [Script API reference](../scripts/api.md)).
