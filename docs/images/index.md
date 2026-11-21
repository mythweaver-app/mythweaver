---
title: Images and attachments
order: 9
description: Attach images, documents, audio and video to messages, and let a caption model describe them for models that can't see.
---

Messages can carry images, documents, audio, video and other files. Models that can't see an image read a text description of it instead, written by a caption model; you can read, edit, ask about and redo those descriptions. This page covers attachments from the chat side. Where files are stored and how images are resized is an administrator setting, described in [Image storage and proxies](../administration/image-storage.md).

## To attach a file

1. In the composer, select the attach button (**Attach files (or drop them, or paste images, into the message)**), or drop files onto the message box, or paste an image into it.
2. Wait for each image's description if your settings review descriptions before sending (the default). The composer shows **Describing images. Review the descriptions, then send.** while they are written, and **Send** waits until they are ready.
3. Read or edit each description, then send.

To take an image out of a draft, select **Remove image** on it. See [The composer](../chats/composer.md) for the rest of the composer.

## Attachment types

The server checks what each file really is from its contents, rather than trusting the browser.

| Type | What happens with it |
| --- | --- |
| Image | Shown inline in the message. PNG, JPEG and WebP are accepted; GIF is refused, because several vision services reject it. Vision models receive the image itself; other models read its description. |
| Document | A PDF or a text or Markdown file. Its text is extracted when it uploads. |
| Audio | Played in the chat. A model that accepts audio may receive it directly; otherwise it can be described. |
| Video | Played in the chat. A model that accepts video may receive it directly; otherwise it can be described. |
| File | Anything else. It is stored and offered for download. |

Each image has an upload size limit set by the administrator (20 MB by default).

## Image descriptions

A description is plain text that stands in for an attachment when a model can't take it. Descriptions are also what lore keyword matching and memory read, so an image can trigger lore through what it shows.

### Which model describes

On a model's edit page under **AI** (see [Models](../ai/models.md)):

| Field | What it does |
| --- | --- |
| **Supports images** | The model reads images itself, so chat images are sent to it inline. Off, it reads them only as descriptions. |
| **Describe images, audio and video with** | The caption model that describes attachments this model can't take. With none, they appear as `[Image]` and the like. |
| **Caption prompt** | For a vision model, the prompt it follows when it describes an image for another model or an avatar. The built-in instruction asks for one short, objective paragraph. |
| **Caption max tokens** | Caps the length of the descriptions this model writes. |
| **Image detail** | The detail hint sent to OpenAI-style services: low, high, auto, or not sent. |
| **Messages with images sent inline** | How many of the chat's newest messages with images send their images to this model. Older ones go as their descriptions, so a long chat does not re-send every picture. Empty sends them all. |

Past the inline limit, older images are described in the background, up to ten per reply. Images in messages hidden from the AI are never described in the background.

If no model in the chat can describe an attachment and none has a caption model for it, you see **No model in this chat can describe that, and none has a caption model for it**.

### To edit or redo a description

- Edit the description text on the image, before or after sending.
- Select **Describe** (**Have the caption model describe this image now**) on an image that has no description yet.
- Select **Redescribe** to have the caption model write it again.

### To ask about an image

Select **Ask…** on an image (**Ask the caption model a question about this image**) and type a question. The caption model answers that question once, in place of its usual caption prompt, and the answer becomes the description. Turn on **Ask every time** in settings to be asked for a question before every description.

### To describe a whole chat

In the chat's settings (see [Chat settings](../chats/chat-settings.md)), select **Describe all attachments**. It describes every image, audio clip, video and document in the chat that has no description yet. Hidden messages are skipped.

### Reviewing finished descriptions

With **Review captions before saving** on, each finished description of a sent attachment is held for you. You can save it, edit it, discard it or redescribe it in place. A reply waiting on it keeps waiting until you resolve it or stop the reply.

## Avatar descriptions

When you upload a new avatar in the character editor, the default caption model describes it into the character's unsaved **Appearance**. **Revert** puts the earlier text back; **Save** keeps the avatar and the text together. Select **Describe avatar** to describe it on demand, optionally with a question. Each character can override whether a new avatar updates Appearance. See [Characters](../characters/index.md).

## Scripts and the prompt inspector

Scripts can describe images and ask the player for one (see [Script API reference](../scripts/api.md)). When a script asks for an image, every open tab of the chat shows a dialog whose **Choose image** button opens the file picker. The prompt inspector lists the images a reply sent, each with an estimated token cost; the estimate uses OpenAI's tile rule, and other services count differently.

## Image settings

The image settings are at **Settings** → **Images** (`/settings/images`). See [Settings](../account/settings.md) for how site and personal values combine.

| Setting | What it does |
| --- | --- |
| **Review image descriptions before sending** | Describes images as they are attached and holds **Send** until each description is ready to check and edit. Off, images are described in the background after sending. On by default. |
| **Default caption model** | Site only. Describes avatars, and AI-generated images in chats where no participant has a caption model. **Automatic** picks the first caption-capable site model by name. |
| **Describe images automatically** | Describes chat images, audio and video as they are attached, sent or needed for a reply, older attachments past a model's inline limits, and new avatars. Off, an attachment is described only when someone asks (**Describe**, **Ask…**, **Describe all attachments**, or a script). |
| **Ask every time** | Before each description someone starts, or one that starts as an image is attached or sent, asks for a question to send instead of the caption prompt. Leave the question blank for the usual description. Background descriptions always use the caption prompt. |
| **Review captions before saving** | Holds each finished description of a sent attachment until it is saved, edited or discarded. |
| **Update Appearance when the avatar changes** | Writes a new avatar's description into the character's Appearance. Elsewhere (scripts, imports) an Appearance someone wrote is kept. Off, new avatars are not described automatically, but **Describe avatar** still works. |
| **Avatar caption prompt** | Site only. The prompt the default caption model gets for an avatar, in place of its own caption prompt. **Built-in instruction** sends the plain describing instruction. |
| **Image text** | What a model that can't see an image reads in its place, and what lore and memory read. See below. |

### The image text template

**Image text** is a Liquid template (see [Template reference](../prompts/templates.md)) with these variables:

| Variable | What it holds |
| --- | --- |
| `caption` | The description, or nil until the image is described. |
| `user` | Who sent the image. |
| `char` | Who is replying. |

Leaving it empty uses the default, which reads `[Image: …]` with the description, or `[Image]` without one:

```liquid
{% if caption %}[Image: {{ caption }}]{% else %}[Image]{% endif %}
```
