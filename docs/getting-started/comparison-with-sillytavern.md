---
title: Comparison with SillyTavern
order: 5
description: A comparison of MythWeaver with SillyTavern
---

Mythweaver and SillyTavern both do very similar things. This isn't surprising, as Mythweaver was _very heavily_ inspired by SillyTavern, as well as the improvements made in a fork, [AikoBots](https://github.com/aikohanasaki/Aikobots). However, Mythweaver is _not_ a drop in, or even close to a 1:1 replacement for SillyTavern. There are still use cases where SillyTavern is the better choice.

## Key Differences

Mythweaver was written, from the beginning, to do a few things very differently than SillyTavern. SillyTavern is primarily focused on single-user chats, where a single user chats with an AI. Mythweaver was built to be a multi-user chat experience, focusing on group chats. SillyTavern has _much broader_ support for different types of AI and providers, while Mythweaver is (currently) limited.

### Group Chats

In SillyTavern, the basic chat is a 1:1 chat between a human and an AI. Group chats exist, and are quite well supported, however they are subject to certain occasional limitations. In Mythweaver, we drop many of the key concepts that SillyTavern is built around, replacing them with a different approach. In Mythweaver, _all_ chats are group-chats, between 0 or more humans and AIs. You can have a SillyTavern style 1:1 chat, it is just a group chat with only two members.

### Multi-user

There are multi-user experiences for SillyTavern, RossAscends, one of the primary developers of SillyTavern has written an experimental plugin. However, Mythweaver is built from the ground up for multi-user, and may provide a better experience.

In Mythweaver, controls are available for group chat owners to invite multiple people, assign them characters, share models or invite them to bring their own keys, moderate chats, and more. Multi-user chat allows users to send messages simultaneously (multiple users are typing…), share ownership of the chat, and more.

### AI Providers and Models

Mythweaver attempted to streamline much of the AI connection code that SillyTavern has built over the years. We currently _only_ support OpenAI compatible APIs. We do not ship templates for connecting to popular services such as OpenRouter, OpenAI, ElectronHub, or similar (yet). These may be added in the future, or as importables.

SillyTavern supports a very broad range of AI providers and models. There are pre-built integrations for major providers, and many providers even offer templates for use in SillyTavern.

Furthermore, SillyTavern offers a variety of utilities to coax good experiences out of limited AIs. They have a much broader set of "knobs" that can be turned to adjust AI behavior, such as CFG. Mythweaver only offers standard AI sampler params, with custom ones requiring you to write them as a JSON payload to send with the request.

## Extensions

Mythweaver does not have any extension support. SillyTavern does. SillyTavern extensions can extend the platform to do a tremendous amount of powerful things.

However, Mythweaver was designed to encompass many features that require plugins in SillyTavern, such as Aiko's SillyTavern Memory Books plugin, guided continues, and more. If you feel there is a feature missing, or an extension you'd like to have, [open a ticket](https://github.com/mythweaver-app/mythweaver/issues/new) or submit a pull request, and we'll see what we can do.

That said, certain chat experiences, such as visual novels, are not supported in Mythweaver. SillyTavern has a number of plugins for this.

## Feature comparison

The table below compares Mythweaver with SillyTavern as its [official documentation](https://docs.sillytavern.app/) describes it, counting only SillyTavern's built-in features and its official extensions. A third-party extension may cover something listed as missing. Features Mythweaver has and SillyTavern lacks come first, then the reverse.

| Feature | Mythweaver | SillyTavern |
| --- | --- | --- |
| **Shared chats** | Invite editors and guests into one chat, each playing their own characters; every change shows live in every open tab. See [Sharing and the catalog](../chats/sharing.md). | [Multi-user mode](https://docs.sillytavern.app/administration/multi-user/) gives each person their own separate data on one server. A chat belongs to one user. |
| **Permissions, groups and quotas** | Permission keys granted to groups or single users, an Everyone group, and quotas such as daily spend. See [Users, groups and permissions](../administration/users-and-permissions.md). | Two roles, Admin and User, which differ only in managing users. User permissions are listed as "TBD". |
| **Moderation** | Reports, account and network bans, content rules that flag or hold content for review, and a moderation log. See [Moderation](../administration/moderation.md). | None. |
| **Encrypted API keys** | Connection API keys are encrypted at rest and never shown again. See [Connections](../ai/connections.md). | All user data, API keys included, is stored in plain text on the server. |
| **Sharing between users** | Share characters, lore, prompts and AI models with other users, or publish them to the catalog. A shared model can run on the owner's key or the user's own. See [Sharing and the catalog](../chats/sharing.md). | No sharing between users. Community assets download from the Extensions & Assets menu. |
| **Several providers per model** | One model can be linked to several connections, picked by priority and split by weight. See [Priority and weight](../ai/provider-selection.md). | [Connection profiles](https://docs.sillytavern.app/usage/core-concepts/connection-profiles/) switch between saved connections by hand. |
| **Job queue and analytics** | Every generation runs through one queue that respects each connection's concurrency and time limits, with usage, token and cost charts. See [Jobs and analytics](../tools/jobs-and-analytics.md). | None. |
| **Built-in Memory Books** | Scene memories, consolidation tiers, side prompts and clips, with review before saving. See [Memory](../memory/index.md). | The [Summarize](https://docs.sillytavern.app/extensions/summarize/) extension keeps a rolling summary. Memory Books is a third-party extension. |
| **An assistant that sets up the app** | Chat with Mythweaver creates and edits characters, lore, prompts, connections and more through tool calls you approve. See [Chat with Mythweaver](../tools/assistant.md). | The [Welcome Screen](https://docs.sillytavern.app/usage/welcome-assistants/) assistant is a plain character chat. |
| **MCP server** | Outside AI clients can use the assistant's tools over MCP. See [MCP access](../tools/mcp.md). | None. |
| **Guides and refine** | Steer one reply with an outline, or rewrite the last reply following editing instructions. See [The composer](../chats/composer.md) and [Messages and swipes](../chats/messages.md). | Not built in. |
| **Inclusion pools** | A pool can let several of its matching entries activate, picked by a weighted draw. See [Inclusion pools](../lore/pools.md). | [Inclusion groups](https://docs.sillytavern.app/usage/core-concepts/worldinfo/) activate one entry per group. |
| **Hierarchical tags** | Namespaced tags with siblings and parents, on characters, lore, prompts, chats and more, and as lore filters. See [Tags](../tools/tags.md). | [Tags](https://docs.sillytavern.app/usage/core-concepts/tags/) on characters and groups, without siblings or parents. |
| **Push notifications** | Web Push reaches your devices with the app closed. See [Notifications](../account/notifications.md). | None. |
| **Built-in API integrations** | OpenAI-compatible APIs only. See [Connections](../ai/connections.md). | Dedicated [connections](https://docs.sillytavern.app/usage/api-connections/) for Claude, Google AI Studio and Vertex, KoboldCpp, Ollama, NovelAI, AI Horde, OpenRouter and many more. |
| **Instruct and context templates** | **Text completion** sends one flat prompt; you write the chat template into the prompt yourself. See [Models](../ai/models.md). | [Instruct mode](https://docs.sillytavern.app/usage/core-concepts/instructmode/) formats text completion prompts for Alpaca, ChatML, Llama and other formats. |
| **CFG and extra knobs** | The standard samplers, plus backend-specific parameters written as JSON. See [Models](../ai/models.md). | [Classifier-free guidance](https://docs.sillytavern.app/usage/prompts/cfg/) and a wide set of backend-specific settings. |
| **Connection profiles** | No profiles. A model is picked per chat or participant. See [Models](../ai/models.md). | [Profiles](https://docs.sillytavern.app/usage/core-concepts/connection-profiles/) save an API, model and formatting templates to switch between. |
| **Branches and checkpoints** | None. Swipes keep the other versions of a message. See [Messages and swipes](../chats/messages.md). | [Branch or checkpoint](https://docs.sillytavern.app/usage/core-concepts/chatfilemanagement/) a chat at any message. |
| **Document retrieval** | [Vector lore](../lore/vector-lore.md) matches lore entries only. An attached document goes into the message it's attached to. | The [Data Bank](https://docs.sillytavern.app/usage/core-concepts/data-bank/) retrieves from attached documents, and [chat vectorization](https://docs.sillytavern.app/extensions/chat-vectorization/) retrieves past messages. |
| **Image generation** | None. | [Stable Diffusion, FLUX and DALL-E](https://docs.sillytavern.app/extensions/stable-diffusion/). |
| **Voice** | None. | [Text-to-speech](https://docs.sillytavern.app/extensions/tts/) and [speech recognition](https://docs.sillytavern.app/extensions/speech-recognition/). |
| **Chat translation** | The interface is translated; messages aren't. See [Appearance](../account/appearance.md). | [Translates messages](https://docs.sillytavern.app/extensions/translation/) through translation providers. |
| **Web search** | None. | [Adds web search results](https://docs.sillytavern.app/extensions/websearch/) to prompts. |
| **Visual novel layouts** | Expressions replace the character's portrait in the chat. See [Expressions and sprites](../characters/expressions.md). | [Visual Novel Mode](https://docs.sillytavern.app/usage/user-settings/visual-novel/), plus Live2D and VRM extensions. |
| **UI themes** | A theme tint and custom stylesheets. See [Appearance](../account/appearance.md). | [Theme files](https://docs.sillytavern.app/usage/core-concepts/uicustomization/), background images, custom CSS and movable panels. |
| **Extensions** | None. | [Extensions](https://docs.sillytavern.app/extensions/) and server plugins, installable per user. |
| **Tools during replies** | Chat replies don't use tools; only Chat with Mythweaver does. See [Models](../ai/models.md). | [Function calling](https://docs.sillytavern.app/for-contributors/function-calling/) lets extensions give the model tools in a chat. |
| **Single sign-on** | None. | [SSO](https://docs.sillytavern.app/administration/sso/) through Authelia or Authentik. |
| **Lightweight install** | Needs a PostgreSQL server with the `vector` extension. See [Installation](../administration/installation.md). | Needs only Node.js, and [runs on Android](https://docs.sillytavern.app/installation/android-(termux)/) through Termux. |
