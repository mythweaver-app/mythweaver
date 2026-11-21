---
title: AI connections and models
order: 4
description: How connections, models and the links between them work, and who may add or run them.
---

Mythweaver talks to AI backends you choose: a local llama.cpp server, a hosted API such as OpenRouter, or anything else that speaks the OpenAI-compatible API. You set this up on two screens, **Connections** at `/ai/providers` and **Models** at `/ai/models`, and switch between them with the link in each list's header.

## Connections, models and links

Three things work together:

| Thing | What it is | Where you edit it |
|---|---|---|
| Connection | One API endpoint: its base URL, API key, timeouts, how many replies it runs at once, and its priority. | **Connections** at `/ai/providers` |
| Model | Exactly one AI model: its friendly name, the id the backend expects, what it can do (images, audio, thinking), its context window, prices and default samplers. | **Models** at `/ai/models` |
| Link | A model reachable through a connection. A link can override the model id, carry its own weight and extra request body, and be switched off. | **Model connections** on a connection's editor |

The same model is often reachable through more than one connection: a free local box and a paid API, say. You create the model once and link it to each connection. When a reply runs, Mythweaver picks one of the model's enabled links, using the connections' priority and the links' weight. See [Priority and weight](provider-selection.md).

Nothing runs until a model is linked to at least one enabled connection.

## To set up your first model

1. Open **Connections** at `/ai/providers` and click **New connection**.
2. Fill in **Name**, **Base URL** and, if the backend needs one, the API key, then click **Save**. See [Connections](connections.md).
3. Click **Test connection** to check the URL and key.
4. Click **Discover models** to list what the connection offers, then click **Add** next to a model. This creates the model and links it in one step.
5. Open the model's row under **Model connections** and click **Send test message** to make sure it answers.
6. If you have more than one model, pick one as the **Default model** in [Settings](../account/settings.md).

For a guided walk-through, see [Connect a model](../getting-started/connect-a-model.md).

## Site and personal rows ("bring your own provider")

Every connection and model belongs either to the site or to one user.

- A **site** connection or model is there for every user allowed to use the site's AI. Only site managers edit it.
- A **personal** connection or model is yours alone. No other user sees it or runs it, administrators included, so nobody can read your API key. Site managers see a **personal** badge on their own personal rows, to tell them apart from the site's.

A link only joins a model and a connection with the same owner. A site model never runs on your personal key, and your personal model never spends the site's. The one exception is a model someone shares with you in a mode where you supply your own key: you may link it to your own connection. See [Sharing and the catalog](../chats/sharing.md).

When you may create both kinds, a new connection or model form starts with an **Owner** choice: **Personal (only me)** or **Site (every user)**.

### To make a personal row the site's

Site managers can move their own personal connection or model to the site.

1. Open the connection or model in its editor.
2. Click **Make site connection** or **Make site model**.
3. Review the confirmation. It lists what else changes: a connection takes every model linked to it along, and a model loses its links to personal connections (link it again to a site connection).
4. Confirm. You need to have recently re-entered your password (sudo mode).

> [!WARNING]
> This can't be undone. A site connection or model cannot be made personal again. If the site already has a row with the same name, rename yours first.

## Who may do what

Administrators grant these permissions to groups at `/moderation/groups`. See [Users, groups and permissions](../administration/users-and-permissions.md).

| Permission key | Name | What it allows |
|---|---|---|
| `ai.connections.create` | Add own AI connections and models | Add personal connections and models that only you see and run. |
| `ai.site_models.use` | Use the site's AI models | Run the site's connections and models. Without it, only your own models work. |
| `site.ai.manage` | Manage site AI connections and models | Create and edit the site's connections and models, and run them. |
| `quota.ai_connections` | Own AI connections | How many personal connections you may own. |
| `quota.ai_models` | Own AI models | How many personal models you may own. |

The editors list what you may edit: your own rows, plus the site's when you hold `site.ai.manage`, plus models shared with you as an editor. Model pickers elsewhere list what you may run: your own, the site's when allowed, and models shared with you.

## Restricting a site model to groups

By default, a site model is open to everyone who holds `ai.site_models.use`. A site manager can narrow it to some groups:

1. Open the site model at `/ai/models`.
2. Under **Who may use it**, below the main form, pick the groups that may run it.
3. Click **Save**.

Leave the list empty for everyone allowed to use site models. Site managers can always run every site model.

A site model's **Visible to users** setting controls how much of it non-administrators see. See [Models](models.md#visibility).

## In this section

- [Connections](connections.md): every connection field, testing and discovering models.
- [Models](models.md): model fields, completion modes, samplers, time limits and which model replies.
- [Priority and weight](provider-selection.md): how Mythweaver picks a connection when a model has several.
