---
title: Connect a model
order: 2
description: Add a connection to your AI backend, add its models, test them, and pick a default model.
---

Mythweaver needs at least one AI model before any character can reply. You set one up in two parts: a **connection** (the backend's address and key) and a **model** (one AI that the connection serves). This page gets one of each working; [AI connections and models](../ai/index.md) covers every option.

## To add a connection

1. Select **AI** in the top bar. The **Connections** pane opens at `/ai/providers`.
2. Select **New connection**.
3. Fill in at least these fields:

   | Field | What it does |
   |---|---|
   | **Name** | A label you choose, such as "OpenRouter" or "Local llama.cpp". |
   | **Adapter** | The API type. **OpenAI-compatible** is the only one, and it covers OpenAI, OpenRouter, llama.cpp, vLLM, TabbyAPI, llama-swap and similar servers. |
   | **Base URL** | The API's base address, including the version path, such as `http://localhost:8080/v1` or `https://openrouter.ai/api/v1`. |
   | **API key** | The key the backend expects. Leave it blank for a local server that needs none. The key is stored encrypted; when you edit the connection later, a blank field keeps the stored key. |
   | **Enabled** | Leave this on. A switched-off connection serves nothing. |

4. Select **Save**.

The other fields (extra headers and body, **Request timeout (ms)**, **Max concurrent generations**, **Priority**) can stay at their defaults for now. See [Connections](../ai/connections.md) when you need them.

## To test the connection

With the saved connection open, select **Test connection**. A success message means Mythweaver reached the backend and read its model list. A failure names the cause, for example "Connection test failed: the provider answered HTTP 401" (usually a wrong key) or "could not reach the provider" (usually a wrong **Base URL** or a server that is not running).

## To add models with Discover models

The quickest way to add a model is to let the connection list what it offers.

1. With the connection open, select **Discover models**. The **Models this connection advertises** list appears, with badges for what each model can do (images, tools, reasoning and so on). Models you already have are marked.
2. Select **Add** next to the model you want. Mythweaver creates the model, fills in what the backend reports (such as the context window and prices), and links it to this connection. Use **Add as embedding** or **Add as classifier** instead for models meant for vector lore or expression classification, not for chat.
3. The model now appears under **Model connections**.

Select **Refresh** to list the models again if the backend's offer changes.

> [!TIP]
> If discovery shows "This connection advertises no models.", create the model by hand: open **Models** (`/ai/models`), select **New model**, set **Name** and **API model id** (the exact id the backend expects) and a **Completion mode** of **Chat**, then **Save**. Back on the connection, pick it under **Link a model** and select **Link**.

## To send a test message

Under **Model connections**, select **Send test message** next to a linked model. Mythweaver sends a short prompt through that connection and shows the start of the reply, such as "Llama 3 answered HTTP 200: Hello!". A failure explains what went wrong, as the connection test does.

## To set the default model

Each character and each chat can name its own model, but the default model answers whenever neither does. Setting it now means every new chat works straight away.

1. Open the **Account** menu and select **Settings**, then the **Models** category (`/settings/models`).
2. Under **Defaults**, set **Default model** (the `ai.default_model` setting) to the model you added.

If you leave it on **Automatic**, Mythweaver uses the only model that can run, and asks you to pick one once there are several. An administrator can set it for the whole site; you can also set your own. See [Settings](../account/settings.md) for how site and personal values combine.

## Which model replies

When a character replies, Mythweaver uses the first model it finds in this order:

1. The model set for that participant in the chat.
2. The chat's model, set in its chat settings.
3. The **Default model** setting.

See [Models](../ai/models.md) for model options and [Chat settings](../chats/chat-settings.md) for choosing a model per chat.
