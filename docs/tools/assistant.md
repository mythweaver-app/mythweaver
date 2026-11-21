---
title: Chat with Mythweaver
order: 1
description: The built-in assistant that sets things up for you by reading and changing your data through tool calls.
---

**Chat with Mythweaver** is an assistant built into the chat screen. You describe what you want in plain language ("set up an OpenRouter connection", "write a lore book for my space station setting", "start a chat with Mira and Tomas"), and the assistant looks up and changes your characters, lore, prompts, chats, settings and more on your behalf. It reads freely, but every change waits for your approval.

## To start a conversation

1. Open **Chats** at `/` with no chat selected. The landing page shows **Chat with Mythweaver** and the prompt *Ask Mythweaver anything about setting up your stories.*
2. Optionally, click the gear button to pick the **Model** the new conversation runs on.
3. Type your request in the **Message Mythweaver…** box and send it.

Sending the first message creates a new conversation. To start another one later, click **New Mythweaver conversation** (the sparkles button) at the top of the chat list. Conversations with Mythweaver appear in the chat list next to your role-play chats, marked by a star, and only you can see them.

## To approve or reject a change

The assistant's replies can contain tool calls, shown as cards under the reply. A tool that only reads data (listing characters, searching, opening a page) runs at once. A tool that writes data stops and shows a card marked **Needs approval** with a summary of what it is about to do, such as *Delete 3 lore entries*, and the items it names.

1. Read the card. Open **Details** to see exactly what will change.
2. Click **Approve** to run it, or **Reject** to refuse it.

The assistant continues once every card of its reply has been answered. If you send a new message instead, any card still waiting is rejected first.

> [!IMPORTANT]
> Approve runs the change for real, with your own permissions. There is no undo beyond editing or deleting the result by hand.

### Bulk changes

One write call can cover 1 to 100 items, so a request like "delete all the entries in this book" produces a single card. The items run one at a time, without a transaction: if some fail, the others still go through, and the card reports *N done, M not done* with the reason for each failed item.

### API keys

When the assistant creates a connection that needs an API key, it asks for the key with a card marked **Needs input**. Enter the key in the **API key** field and save it. The key goes straight to the connection; the model never sees it and it is not stored in the conversation.

### Card statuses

| Status | Meaning |
|---|---|
| **Needs approval** | A write is waiting for **Approve** or **Reject**. |
| **Needs input** | The assistant is asking for an API key. |
| **Running** | The tool is running. |
| **Done** | The tool finished. A card for a created or changed item has an **Open** link to its editor. |
| **Failed** | The tool returned an error, which the assistant sees and can react to. |
| **Rejected** | You rejected the call, or it was closed by a new message. |

## To compact a long conversation

A long conversation costs more tokens on every round. Click **Compact** in the conversation's header to have the model summarize the conversation so far into one **Summary** message. Later rounds send that summary in place of the messages before it. If nothing new has happened since the last summary, you see *Nothing new to compact since the last summary.*

## To rename a conversation or change its model

Open the conversation's **Settings** (the **Conversation settings** dialog) and change its **Name** or **Model**, then click **Save**. A new conversation takes its name from the first line of your first message. **Delete conversation** removes it.

## Which model the assistant uses

The assistant runs on the first of these that is set:

1. The conversation's own **Model**.
2. The **Mythweaver model** setting (`assistant.model`) in **Settings** at `/settings`, under **Models**.
3. Your default model (`ai.default_model`).

It must be a chat-mode model. A model that supports tools works best; other chat models use a text-based fallback that is less reliable. See [Models](../ai/models.md) for completion modes and capabilities, and [Settings](../account/settings.md) for the settings themselves.

| Message | What to do |
|---|---|
| *No model can run Mythweaver…* | Add a connection under **AI → Connections**, or pick a model in **Settings → Models**. |
| *Several models are available…* | Pick one with the gear button, or set **Mythweaver model**. |
| *Mythweaver needs a chat-mode model.* | Choose a model whose completion mode is chat. |
| *Mythweaver is still replying.* | Wait, or click **Stop**. |

## What the assistant can do

The assistant's tools cover most of the app. It can:

- list, read, create, update and delete characters, outfits, sprites and expression profiles;
- manage lore books, entries, pools and their bindings;
- create and edit chats, participants and injections, and read chat messages;
- manage AI connections and models, discover a connection's models and test them;
- edit prompts, prompt blocks and outlets, and reorder blocks;
- read and change settings and variables, read scripts, memory settings, jobs and analytics;
- search across your data, tag items and find tagged items;
- answer questions about how Mythweaver works from this documentation, naming the page it used;
- open a page in the app for you.

It works with your permissions: it can't see or change anything you couldn't in the app yourself. A single reply runs at most 8 rounds of tool calls before it stops and waits for your next message.

You can attach files and images to messages in an open conversation. A model that can't see images waits for the image descriptions first; see [Images and attachments](../images/index.md).

The same tools are available to outside AI clients over [MCP access](mcp.md).
