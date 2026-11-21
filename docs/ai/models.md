---
title: Models
order: 2
description: Every model field, completion modes, samplers, time limits, testing, and which model answers a reply.
---

A model is exactly one AI model, such as "Qwen3 8B" or "Claude Sonnet 4.5": its name, the id the backend expects, what it can read, what it costs and the default sampler settings replies start from. You manage models on **Models** at `/ai/models`. A model runs only once it is linked to an enabled connection; see [Connections](connections.md).

## To add a model

The quickest way is **Discover models** on a connection, which fills in the model from what the backend reports and links it in one step. See [Connections](connections.md#to-discover-and-add-models).

To add one by hand:

1. Open **Models** at `/ai/models` and click **New model**.
2. If you may create both kinds, choose the **Owner**: **Personal (only me)** or **Site (every user)**.
3. Enter a **Name** and the **API model id**, and pick the **Completion mode**.
4. Optionally enter a **Tokenizer (Hugging Face repo)** and click **Fill from Hugging Face** to fill in the context window, capabilities and recommended samplers.
5. Click **Save**.
6. Link the model to a connection: open the connection at `/ai/providers` and use **Model connections**.

## To test a model

Open the connection the model is linked to, open the model's row under **Model connections** and click **Send test message**. Mythweaver sends one short "Hi" through that link and shows the start of the reply. See [Connections](connections.md#to-test-a-linked-model).

## Completion modes

**Completion mode** says what the model is for.

| Mode | What it does | Can reply in chats |
|---|---|---|
| **Chat** | Sends the prompt as role-tagged messages to `/chat/completions`; the backend applies the model's chat template. The default, and the only mode that sends images, PDFs, audio and video inline. | Yes |
| **Text completion** | Sends one flat prompt to `/completions`, for base models or a chat template written into the prompt itself. Attachments always go as text descriptions. | Yes |
| **Embedding** | Turns text into vectors for [Vector lore](../lore/vector-lore.md) entries. | No |
| **Classifier** | A GoEmotions sequence classifier served like an embedding model (llama-server `--embedding --pooling rank`), for the Expressions classifier setting. See [Expressions and sprites](../characters/expressions.md). | No |

Only **Chat** and **Text completion** models can run a chat, a participant, a memory profile or a background job.

### Switching modes

A model switches modes only while nothing uses it in a way the new mode can't serve. When a switch is blocked, the form says what is in the way.

- To **Embedding** or **Classifier**: no chat, participant, memory profile or prompt binding may use the model, no model may use it to describe attachments, and no model setting (such as **Default model**) may name it unless that setting accepts the new mode.
- To **Text completion**: no Chat with Mythweaver thread may use it; the assistant needs **Chat**.
- To **Chat**: always allowed.

Past usage (statistics, finished jobs, prompt snapshots) never blocks a switch.

> [!WARNING]
> Switching a model away from **Embedding** deletes every vector it made. They are only a cache, but every lore entry and message has to be embedded again by whichever model you use next.

## Which model replies

When a character speaks in a chat, Mythweaver takes the first of these that is set and that you may run:

1. The participant's own model, set on the character's row in the chat. See [Group chats and turn-taking](../chats/group-chats.md).
2. The chat's model, in [Chat settings](../chats/chat-settings.md).
3. The **Default model** setting (`ai.default_model`) in [Settings](../account/settings.md).
4. If **Default model** is left on automatic: the only chat or text model that has an enabled link on an enabled connection you may use.

A rung that names a model you may not run (another user's, or a site model you are not allowed) counts as unset. If nothing resolves, or automatic finds several models, the reply can't run until you set a **Default model** or pick a model for the chat.

> [!NOTE]
> A chat member who joins with their own model uses their own pick for the chat, or their own **Default model**, and ignores the chat owner's models.

## Fields

### Identity

| Field | What it does |
|---|---|
| **Owner** | Shown on a new model when you may create both kinds: **Personal (only me)** or **Site (every user)**. |
| **Name** | The name in pickers and lists. It is never sent to the backend. Names are unique per owner. |
| **API model id** | The exact id the backend expects, sent as `model` with every request, for example `gemma-4` or `anthropic/claude-sonnet-4.5`. A connection link can override it. Required. |
| **Tokenizer (Hugging Face repo)** | The Hugging Face repo (such as `Qwen/Qwen3-8B`, or a `huggingface.co` link) whose tokenizer counts this model's tokens, for the lore budget, prompt section sizes and cost estimates. Without one, counts are estimated. |
| **Completion mode** | See [Completion modes](#completion-modes). |
| **Context window** | How many tokens the model can read at once, prompt and reply together. Recorded for reference: prompts are not yet trimmed to fit it. |
| **Notes** | Your own notes about the model. They are never sent anywhere. |

### Visibility

**Visible to users** appears on site models. It controls what non-administrators see of the model.

| Option | What it does |
|---|---|
| **Everything** | Users see every field. |
| **Only names (runtime-only)** | Users see the model's name but never its API model id, sampler, extras, reasoning tags, tokenizer, notes, time limits or caption prompt, in the assistant or in exports. The model still runs for them. |

Administrators always see everything. A personal model's editor ends with a sharing section instead; see [Sharing and the catalog](../chats/sharing.md).

### Fill from Hugging Face

With a **Tokenizer (Hugging Face repo)** entered, **Fill from Hugging Face** reads the repo's context window, capabilities and recommended sampler values and opens a comparison: the form's value on one side, Hugging Face's on the other. Toggle the rows you want (**Use Hugging Face value** or **Keep current value**), or use **Copy all** or **Copy missing**, then click **Apply to form**. **Show unchanged** also lists rows that already match. Click **Save** to keep the applied values.

> [!NOTE]
> Gated or private repos need the `HF_TOKEN` environment variable set on the server, followed by a restart. See [Environment variables](../administration/configuration.md).

### Prices

| Field | What it does |
|---|---|
| **Prompt cost per Mtok** | Dollars per million prompt tokens, used to estimate a reply's cost when the connection reports no charge of its own. For an embedding model, this prices the text it embeds. |
| **Completion cost per Mtok** | Dollars per million generated tokens, reasoning included. Unused by embedding models. |

Leave both empty to skip estimates. Costs appear at `/analytics`; see [Jobs and analytics](../tools/jobs-and-analytics.md).

### Capabilities and attachments

| Field | What it does |
|---|---|
| **Supports images** | The model reads images itself, so chat images are sent to it inline. Off, it reads them only as text descriptions written by a caption model. |
| **Messages with images sent inline** | How many of the chat's newest messages with images send their images inline. Older ones go as their descriptions. Empty sends them all. |
| **Image detail** | The detail hint OpenAI-style backends read with each image: **low** (a fixed 85 tokens per image), **high** (fine detail, many more tokens) or **auto** (the backend chooses). **Not sent** leaves it out, for backends that reject it. |
| **Reads PDFs** | PDFs are sent to the model as files. Off, it reads their extracted text. |
| **Messages with documents sent in full** | How many of the newest messages with documents send them in full; older ones go as a short summary. Empty sends them all. |
| **Hears audio** | Audio clips are sent to the model. Off, it sees only `[Audio: name]`. |
| **Messages with audio sent inline** | How many of the newest messages with audio send their clips; older clips go as their descriptions. Empty sends them all. |
| **Watches video** | Video clips are sent to the model. Off, it sees only `[Video: name]`. |
| **Messages with video sent inline** | As above, for video. |
| **Describe images, audio and video with** | A caption model: a chat model that can read what this one can't, and describes each attachment as text. With **None**, attachments appear as `[Image: name]`, `[Audio: name]` or `[Video: name]`. See [Images and attachments](../images/index.md). |
| **Caption prompt** | For a model that describes attachments: the prompt it follows. **Built-in instruction** asks for one short, objective paragraph. |
| **Caption max tokens** | The longest a description or summary this model writes may run (default 300). |
| **Supports tools** | Records that the model can call tools. Informational for now: replies do not use tools yet. |
| **Supports thinking** | The backend returns the model's reasoning in its own field, shown apart from the reply. For a model that thinks inline in its text, set the reasoning prefix and suffix instead. |
| **Reasoning prefix** | The tag that opens inline thinking, such as `<think>`. A reply that starts with it is reasoning up to the suffix. Leave both tags empty for a model without inline thinking. |
| **Reasoning suffix** | The tag that closes inline thinking, such as `</think>`. A block that never closes is all reasoning. |
| **Continue by assistant prefill** | **Continue** sends the unfinished message as a trailing assistant turn for the model to extend word for word, instead of instructing it to carry on. Chat mode only, and the backend must support it (llama.cpp and Claude do). |
| **Extra request body** | A JSON object merged into every request body, for backend-specific keys this form has no field for. The connection's extra body overrides it, then the link's. |

### Time limits

These limits stop a generation that takes too long. Values are in seconds; empty keeps the default shown in the field, and `0` means no limit. Embedding models ignore them.

| Field | What it does | Default |
|---|---|---|
| **Chat: first token** | How long a reply may wait for its first token, prompt processing included. | 180 |
| **Chat: stall** | How long a reply may go silent after its first token. | 120 |
| **Chat: total** | The longest a reply may run in all. | No limit |
| **Background: first token** | As for chat, for memory and caption jobs, whose prompts are often larger. | 300 |
| **Background: stall** | As for chat, for memory and caption jobs. | 120 |
| **Background: total** | The longest a memory or caption job may run. | No limit for memory, 600 for captions |

"Chat" covers replies, regenerations, continues, refines and Chat with Mythweaver. "Background" covers memory work and image captions. The connection's **Request timeout (ms)** still ends a request that sends nothing at all for that long.

### Default sampler

The **Default sampler** section sets the generation settings every reply starts from. **Neutralize samplers** turns every cutoff and penalty off and sets temperature to 1; click **Save** to keep it. Empty fields are not sent, so the backend's own default applies. Which backends read each setting depends on the connection's **Sampler dialect**.

| Field | What it does |
|---|---|
| **Response tokens** | The most tokens one reply may generate. Lower keeps replies short and cheap; raise it if replies end mid-sentence. A thinking model spends its reasoning from the same budget. Empty lets the backend decide. |
| **Temperature** | How random each word choice is. 0 always picks the likeliest token; around 0.7 to 1.0 suits role-play. |
| **Top p** | Chooses only among the likeliest tokens whose probabilities add up to this. 1 turns it off. |
| **Top k** | Chooses only among the k likeliest tokens. 0 turns it off. |
| **Min p** | Drops tokens less likely than this fraction of the top token's probability. 0.05 to 0.1 is common for local models; 0 turns it off. |
| **Top a** | Drops tokens below this value times the square of the top token's probability. 0 turns it off. Read by OpenRouter and TabbyAPI. |
| **Typical p** | Locally typical sampling. 1 turns it off. Not sent to OpenAI or OpenRouter. |
| **Repetition penalty** | Makes tokens that already appeared less likely. 1 turns it off; 1.05 to 1.15 is typical. |
| **Frequency penalty** | Penalizes a token more each time it has appeared. 0 turns it off. |
| **Presence penalty** | Penalizes any token that has appeared at all. 0 turns it off. |
| **Repetition penalty range** | How many recent tokens the repetition penalty looks at. |
| **DRY**: **Multiplier**, **Base**, **Allowed length**, **Penalty range**, **Sequence breakers** | "Don't repeat yourself": penalizes extending a phrase already in the context. **Multiplier** 0 turns it off (0.8 is a common start); **Base** (usually 1.75) sets how fast the penalty grows; **Allowed length** (usually 2) is the longest repeat left alone; **Penalty range** 0 scans the whole context; **Sequence breakers** is a JSON list of strings that end a phrase. llama.cpp and TabbyAPI. |
| **XTC**: **Threshold**, **Probability** | "Exclude top choices": removes all but the least likely of several likely tokens. **Probability** 0 turns it off. llama.cpp and TabbyAPI. |
| **Dynamic temperature**: **Minimum**, **Maximum**, **Exponent** | Temperature that rises when the model is unsure. Replaces **Temperature** when set. |
| **Top nσ** | Keeps tokens within this many standard deviations of the top token. 0 turns it off. llama.cpp only. |
| **Ban EOS token** | On, the model may not end its reply, so it runs to the token limit or a stop sequence. |
| **Skip special tokens** | Off, the reply keeps the model's special tokens in its text. vLLM. |
| **Logit bias** | A JSON object of token id or text to a bias from -100 to 100; `false` bans the token. Text keys work only on llama.cpp. |
| **Sampler order** | The order llama.cpp applies its samplers in. **Customize order** lets you drag them; **Use backend order** goes back to **Backend default order**. |
| **Thinking** | How hard a reasoning model thinks: **Off**, **Minimal**, **Low**, **Medium**, **High**, **Extra high**, **Max**, or **Backend default** (nothing sent). Translated by the connection's **Thinking dialect** and ignored when it has none. |
| **Seed** | Fixes the random seed, so the same prompt gives the same reply where supported. Empty picks a new seed every time. |
| **Stop sequences (comma separated)** | Strings that end a reply where they appear. They are sent to the backend and also enforced by Mythweaver, on top of the speaker-name stop strings in Settings. |
| **Extra sampler params** | A JSON object of sampler keys passed to the backend verbatim, for settings this form lacks (mirostat, grammar). A key here wins over the matching field above. |

> [!TIP]
> If a thinking model replies with nothing, its reasoning probably used up **Response tokens**. Raise **Response tokens**, or cap reasoning in **Extra request body** (llama.cpp: `thinking_budget_tokens`). The form warns you when the limit looks too low.

## To delete a model

Click **Delete** in the model's editor and confirm. Its connection links go with it.
