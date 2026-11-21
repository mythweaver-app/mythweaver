---
title: Sharing and the catalog
order: 5
description: Invite people into a chat, share your characters and other content, and publish to or subscribe from the catalog.
---

Mythweaver lets you play with other people and share what you make. You can invite people into a chat, share an item such as a character or lore book with particular accounts, or publish it to the catalog for anyone on the site to subscribe to.

## Share a chat

A chat's owner can invite other accounts into it as editors or guests. Invited chats appear under **Shared with me** in the invitee's **Chats** rail.

| Role | What they may do |
| --- | --- |
| Owner | Everything, including choosing models and deleting the chat. |
| **Editor** | Everything except deleting the chat and choosing models: settings, participants, memory, variables, injections, and the other tools. |
| **Guest** | Read and post, and whatever the guest permissions below allow. Guests don't see settings, memory, variables, injections, jobs, auto mode, inspectors, selection, merging or scratchpads. |

### To invite someone into a chat

1. Open **Chat settings** and go to the **Members** tab.
2. Type their handle in **Invite by handle** (such as `@alex`).
3. Pick a **Role**. An editor can invite guests only.
4. The owner also picks **Models**: **Uses my models** (their replies and image descriptions spend your models, connections and quota) or **Brings their own models** (they spend their own).
5. Select **Invite**.

The person gets an invite in their notifications and can accept or decline it; until then they are listed as **Invited**. See [Notifications](../account/notifications.md).

The members list shows each member's role. The owner can change a member's **Models** at any time. Select **Remove** to take someone out of the chat: the owner can remove anyone, an editor only guests. If someone misbehaves, select **Report** next to their name.

### Guest permissions

These switches under **Guests may** apply to every guest of the chat and take effect at once:

| Switch | Default | What it allows |
| --- | --- | --- |
| **Edit their own messages** | On | Editing messages they posted. |
| **Delete their own messages** | On | Deleting messages they posted. |
| **Regenerate and swipe replies** | On | Regenerating, continuing and swiping replies. |
| **Trigger replies** | On | Their messages start replies. Without it, a guest's message is only posted. |
| **Run scripts** | Off | Running inline Lua and other scripts from their messages. |
| **Attach files** | On | Attaching files to messages. |

### Who plays which characters

Each person posts as the characters they hold. Below the guest permissions:

| Setting | What it does |
| --- | --- |
| **Guests may bring their own characters** | Guests get a **Bring a character** button in the **Participants** rail to add their own characters. When the guest leaves, their characters leave with them. |
| **Free switching: players take and release any characters themselves** | Anyone in the chat can take any character with **Take this character (free switching)** and let it go again. Several people can play the same character. |
| **Turns** | **Any time: every message may get a reply**, or **Rounds: reply once every player posted or skipped**. In rounds, the AI waits until everyone holding a character has posted or selected **Skip turn**. |

Without free switching, the owner assigns characters under **Who plays which characters**: select **Add player** for a person, then pick their **Characters**. A character someone plays is never picked for automatic replies. In the **Participants** rail, a played character shows an icon listing who plays it, and **Play as this character** picks which of your characters you post as.

## Share an item

Characters, lore books, prompts, prompt blocks, outlets, scripts, memory profiles, side prompts, side prompt sets and AI models you own can be shared with particular accounts. Open the item's editor and find its **Sharing** section.

### To share an item

1. In the item's editor, go to **Sharing**.
2. Type the account's **@handle**.
3. Choose a role and select **Invite as editor** or **Invite subscriber**.

The invite waits as **Pending** until the person accepts or **Declined** if they refuse; you can **Cancel invite** before then. There is a limit on how many invites you can have waiting at once.

| Role | What they get |
| --- | --- |
| **Editor** | Can edit the item and its parts, and use what it references, but can't delete it. An editor can invite and remove Runtime-only subscribers. |
| **Subscriber**, **Readable** | Can use the item, and inspect, export and clone its full contents. |
| **Subscriber**, **Runtime-only** | Can use the item, but never sees its protected contents. The model still receives them. |

Only the owner can change a subscriber's visibility. Select **Remove** to end a share; Mythweaver first tells you what it also removes from that person's own content (for example, a chat participant that uses your character).

> [!WARNING]
> Runtime-only hides text from the person, not from the model. Careful prompting can still coax the model into repeating parts of it.

### Sharing an AI model

A shared AI model also says whose connection runs it:

- **Their own connection** (the default): the subscriber links the model to one of their own connections on `/shared`.
- **My connection**: their runs use your connection, optionally limited by **Tokens per day (optional)**. Only offered if you have the `sharing.ai.owner_key` permission.

See [AI connections and models](../ai/index.md).

### Giving an item away

If you delete an item that has editors, it is not deleted. Mythweaver asks **Give … away?**: pick an editor under **Give to** and select **Give and remove from my account**. That editor owns it from then on, and it leaves your account and your chats. The same happens if your account is deleted. References the new owner may not use are removed from the item.

## Shared with me

**Shared with me** at `/shared` lists everything other accounts share with you that you accepted, including catalog subscriptions.

- An editor share links to the item's editor with **Open editor**.
- A subscriber share shows a read-only card of the item. A Readable card shows everything and can be cloned with **Clone**, which makes your own copy and opens it.
- **Leave** ends a share. Mythweaver tells you first what of yours uses it, since you lose that too.
- On a card, you can switch the entries, blocks and scripts you don't own on or off for yourself, without cloning.
- A shared script is off until you enable it. Enabling it lists the `mw.*` APIs it uses and asks you to confirm. If the script changes later, it is switched off again until you re-enable it.

### Site content

The site's own content (characters, books and so on made available to everyone) is listed on `/shared` too. Select **Hide** on a site item you don't want in your lists; Mythweaver shows what that removes first. **Restore** brings it back. Lore books the site requires can't be hidden.

## The catalog

The catalog at `/catalog` lists items that their owners published for anyone to subscribe to. Featured listings come first, then the newest.

### To subscribe to a listing

1. Go to **Catalog** at `/catalog`. Search by title, summary or tag, or narrow by type (**All types**) and tag (**All tags**).
2. Select a listing to see its card, summary, tags and release history.
3. Select **Subscribe**.

The item then appears under **Shared with me**, and each new release updates it for you. Select **Unsubscribe** to leave; you lose the item and whatever of yours uses it. A Readable listing can be cloned once you are subscribed. A listing shows how many subscribers it has, never who they are.

### To publish an item

You need the `catalog.publish` permission, and the item must be your own personal item.

1. In the item's editor, find the **Catalog** section.
2. Fill in **Title**, **Summary**, **Tags** (comma-separated, such as `fantasy, sci-fi`) and **Visibility**: **Runtime-only (use only)** or **Readable (can inspect, clone and export)**.
3. Select **Publish**.

Publishing makes a frozen copy of the item and everything it depends on. Later edits to your item don't reach subscribers until you release them:

- **New release**, with optional **Release notes**, updates the published copy for every subscriber.
- **Visibility** can be changed later.
- **Unpublish** removes the listing and ends every subscription. Mythweaver shows you what it removes from subscribers' content first.

Deleting the item also unpublishes it.

People with the `catalog.feature` permission can **Feature** a listing to put it at the top.

## Reporting

Select **Report** to send something to the site's moderators with a reason (**What is wrong with it?**). You can report:

- a chat message (**Report message** in its header),
- a chat member (**Report** on the **Members** tab),
- a catalog listing or its publisher (**Report** and **Report publisher** on the listing).

You can report something once, and not your own content. Reporting needs the `reports.create` permission. See [Moderation](../administration/moderation.md).

## Submissions

If the site holds new content for review, what you create, edit or import waits unsaved until a moderator or the site's rules decide. **Submissions** at `/submissions` lists everything of yours that is waiting, with **Withdraw** to discard it. You are notified of each decision.
