---
title: Connections
order: 1
description: Add an AI backend, fill in every connection field, test it, and link models to it.
---

A connection is one API endpoint Mythweaver sends requests to: a local llama.cpp or vLLM server, a hosted API, or a router such as OpenRouter. You manage connections on **Connections** at `/ai/providers`. The list on the left shows each connection with its model count and priority; the editor on the right shows the selected one.

## To add a connection

1. Open **Connections** at `/ai/providers` and click **New connection**.
2. If you may create both site and personal connections, choose the **Owner**: **Personal (only me)** or **Site (every user)**. See [AI connections and models](index.md#site-and-personal-rows-bring-your-own-provider).
3. Enter a **Name** and the **Base URL**, for example `http://localhost:8080/v1` for a local llama.cpp server.
4. Enter the API key if the backend needs one.
5. Click **Test connection**, then **Save**.

Once the connection is saved, its editor shows **Model connections** and **Discover models** below the form.

## To test a connection

**Test connection** checks the form as it stands, saved or not. It asks the backend for its model list and reports the result in a notice, such as "Connected: /models answered HTTP 200 with 12 models". Nothing is saved.

A failed test tells you why: the provider could not be reached, it answered with an HTTP error status, or its reply was unreadable.

> [!NOTE]
> Some providers (OpenRouter among them) list their models without checking the key, so **Test connection** can pass with a wrong key. Use **Send test message** on a linked model to prove the key works. See [To test a linked model](#to-test-a-linked-model).

## To discover and add models

1. Open a saved connection and click **Discover models**. Mythweaver asks the connection which models it advertises and lists them under **Models this connection advertises**.
2. Each entry shows what the backend reported: context window, prices per million tokens, and badges such as **images**, **files**, **audio**, **video**, **tools**, **thinking** and **embedding**. Models you already have are marked **known**.
3. Click one of the buttons next to an entry:

| Button | What it does |
|---|---|
| **Add** | Creates a model from the entry (its name, model id, context window, prices and capabilities) and links it to this connection. |
| **Add as embedding** | Adds it as an embedding model, for [Vector lore](../lore/vector-lore.md), when the server doesn't say it embeds. Its chat capability flags are dropped. |
| **Add as classifier** | Adds it as a classifier model, for character expressions: a GoEmotions classifier served with `--pooling rank`. See [Expressions and sprites](../characters/expressions.md). |
| **Link** | For a **known** model: links the existing model to this connection. |

Click **Refresh** to list the models again. A model created this way belongs to the same owner as the connection. Review it afterwards at `/ai/models`; see [Models](models.md).

## To link an existing model

1. Open the connection.
2. Under **Model connections**, pick the model in **Model** and click **Link**.

You can only link a model with the same owner as the connection (site to site, personal to personal). If you have no models yet, the section offers **New model** instead.

## To change a link

Each linked model is a collapsed row under **Model connections**. Its summary shows the link's weight and how many times it has served a reply, with a **disabled** badge when the link is off and an **override** badge when it overrides the model id. Open a row to edit it, then click its own **Save**; each row saves separately from the connection form.

| Field | What it does |
|---|---|
| **API model id override (blank uses the model's own id)** | The id sent to this backend instead of the model's **API model id**, for when one backend names the same model differently. |
| **Weight (share of traffic within this priority tier)** | How large a share of this model's calls this connection gets, compared with the model's other connections at the same priority. Whole numbers from 1. See [Priority and weight](provider-selection.md). |
| **Thinking dialect (overrides the connection)** | Replaces the connection's **Thinking dialect** for this model only. |
| **Sampler dialect (overrides the connection)** | Replaces the connection's **Sampler dialect** for this model only. |
| **Extra request body (JSON object; overrides the model and the connection)** | Keys merged into every request for this model through this connection. They win over the model's and the connection's extra body. |
| **Enabled** | Off, this connection is not used for this model. |

The row's buttons:

| Button | What it does |
|---|---|
| **Edit model** | Opens the model in **Models**. |
| **Send test message** | Sends the saved link a short test request. See below. |
| **Disable** / **Enable** | Switches the link off or on. |
| **Unlink** | Removes the link. The model itself stays. |

### To test a linked model

Click **Send test message** on a link. Mythweaver sends one short "Hi", capped at a few tokens, straight to that link, even when it is disabled. The notice shows the start of the reply, or for an embedding or classifier model the size of the vector it returned. A test runs immediately, never waits behind replies in progress, and does not count toward the link's use count or rotation. It does bill a few real tokens.

Save the link first: the test uses the saved settings.

## Connection fields

| Field | What it does |
|---|---|
| **Owner** | Shown on a new connection when you may create both kinds: **Personal (only me)** or **Site (every user)**. An existing connection shows its owner instead. |
| **Name** | The name shown in lists. Required. |
| **Adapter** | The API type. **OpenAI-compatible** is the only one, and it covers llama.cpp, vLLM, TabbyAPI, Ollama, OpenRouter, OpenAI and other OpenAI-style APIs. |
| **Thinking dialect** | How a model's **Thinking** setting is sent: **OpenAI reasoning_effort**, **OpenRouter reasoning** or **llama.cpp**. **None (thinking setting not sent)** sends no thinking keys at all. |
| **Sampler dialect** | How sampler settings are named on the wire. **Generic (canonical names: vLLM, TabbyAPI, others)** is the default. **llama.cpp** renames repetition penalties and converts dynamic temperature. **OpenAI (strict)** sends only the parameters OpenAI accepts. **OpenRouter** uses OpenRouter's names. |
| **Base URL** | The API root, starting with `http://` or `https://`, for example `http://localhost:8080/v1`. Required. |
| **API key (leave blank to keep the stored key)** | The secret sent with each request. It is stored encrypted and never shown again; leave the field blank when editing to keep the stored key. A connection without a key shows a **no key** badge. |
| **Priority** | 1 to 5, lower preferred (default 3). A model uses its lowest-numbered enabled connection for every call while one is available. See [Priority and weight](provider-selection.md). |
| **Request timeout (ms)** | How long one request may go without sending anything before it fails, in milliseconds. The default, 120000 (two minutes), leaves room for a local server loading a model cold. |
| **Max concurrent generations** | How many generations run on this connection at once (default 1). Others wait their turn. Keep 1 for a single local server; a hosted API can usually take more. |
| **Extra headers (JSON object)** | HTTP headers added to every request, for example `{"HTTP-Referer": "https://example.com"}`. |
| **Extra body (JSON object)** | Keys merged into every request body on this connection. They win over a model's **Extra request body**; a link's extra body wins over both. |
| **Report prompt progress (llama.cpp and TabbyAPI only)** | Asks the backend to report how far it has read the prompt, so you can watch a long prompt load. Leave it off for hosted APIs such as OpenAI, which reject the request. |
| **Enabled** | Off, the connection is not used and its list row shows a **disabled** badge. |

> [!NOTE]
> A model's own time limits (see [Models](models.md#time-limits)) govern how long a reply may take. **Request timeout (ms)** is a lower-level cutoff for a request that sends nothing at all.

## To delete a connection

Click **Delete** in the connection's editor and confirm. Its model links go with it; the models themselves stay.
