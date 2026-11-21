---
title: Users, groups and permissions
order: 8
description: Managing accounts, permission groups, every permission key and the per-user quotas.
---

What an account may do is set by permission keys. Keys are granted to groups or to a single user, and every account is implicitly in the **Everyone** group. Quotas are permission keys too: they cap things like daily spending or the number of characters a user may own.

## Roles

| Role | What it means |
| --- | --- |
| **Owner** | Holds every permission and no limit applies. Always exempt from content moderation and can never be warned or banned. Only an owner can change an owner's account or look up an owner's content. The first account, created at `/setup`, is an owner. |
| **User** | Holds whatever the Everyone group, the user's other groups and the user's own grants give. |

You can't change your own role or delete your own account.

## To manage accounts

Open **Moderation** → **Users** at `/moderation/users` (needs `users.manage`).

1. Select **New user**, or pick an account from the list. Search by **Email, handle or nickname**.
2. Edit **Email**, **Handle**, **Nickname (optional)** and **Role**, then select **Save**.
3. To set a new password for someone else, use **Reset password**. Your own password is changed in **Account settings**.
4. Choose the account's groups and select **Save groups**.
5. Under **Overrides**, set permissions for this one account (needs `groups.manage`).
6. **Content** opens the account's chats and content, and **Lookup** opens its moderation record (see [Moderation](moderation.md)).
7. **Delete** removes the account after a confirmation.

> [!IMPORTANT]
> On a single-account install with automatic login, set a password for yourself in **Account settings** before adding users. Automatic login stops once a second account exists.

## To manage groups

Open **Moderation** → **Groups** at `/moderation/groups` (needs `groups.manage`).

1. Select **New group**, or pick a group. Enter its **Name** and **Description (optional)**, then select **Save**.
2. Under **Members**, choose accounts and select **Save members**. Everyone has no member list: it always contains every account.
3. Under **Permissions**, set each key, then save.

The system groups, marked **System**, are **Everyone** (every account, implicitly) and **Administrators** (site administration). They can't be renamed or deleted.

> [!NOTE]
> You can't change a group that holds a permission you don't hold yourself. This stops admins from granting more than they have.

## How permissions combine

Each flag key can be **Allow**, **Deny** or **Unset**. Each limit key can be **Set** to a number, **Unlimited**, or **Unset**.

1. A value set on the user under **Overrides** beats every group.
2. For flags, across Everyone and the user's groups, any **Deny** beats any **Allow**. Unset everywhere means off.
3. For limits, the most generous group value wins, and **Unlimited** beats any number. Unset everywhere means unlimited.

So to take a capability away from one group of users while Everyone has it, add a **Deny** on that group. To take it from everyone but a few, deny it on Everyone and allow it on those users' **Overrides**.

## Default permissions

On a new install the **Everyone** group holds content creation (`content.*.create`), the `scripts.*` keys, the `uploads.*` keys, `ai.connections.create`, `mcp.use`, `sharing.invite`, `chats.invite`, `catalog.publish` and `reports.create`. **Administrators** holds the site administration and moderation keys. Updates that add capabilities may grant them to Everyone as well. Deny any of them for Everyone to switch them off.

## Permission keys

### Content

| Key | Label | What it allows |
| --- | --- | --- |
| `content.characters.create` | Create own characters | Keep characters only the user sees and edits. |
| `content.lore.create` | Create own lore (books, entries, pools) | Keep lore books, entries and pools only the user sees and edits. |
| `content.prompts.create` | Create own prompts, blocks and outlets | Keep prompts, prompt blocks and outlets only the user sees and edits. |
| `content.scripts.create` | Create own scripts | Keep scripts only the user sees and edits. |
| `content.memory.create` | Create own memory profiles and side prompts | Keep memory profiles, side prompts and side prompt sets only the user sees and edits. |
| `content.variables.create` | Create own global variables | Keep global variables only the user sees and edits. |
| `content.tags.create` | Create own tags | Keep tags, siblings and parents only the user sees, and tag anything they can see. |

### AI

| Key | Label | What it allows |
| --- | --- | --- |
| `ai.connections.create` | Add own AI connections and models | Add AI connections and models that only the user sees and runs. See [Connections](../ai/connections.md). |
| `ai.site_models.use` | Use the site's AI models | Run the site's AI connections and models; off, only the user's own models work. |

### MCP

| Key | Label | What it allows |
| --- | --- | --- |
| `mcp.use` | Connect AI tools over MCP | Create MCP access tokens and use Mythweaver's tools from outside AI clients (Claude, Cursor and others) with them. See [MCP access](../tools/mcp.md). |

### Uploads

| Key | Label | What it allows |
| --- | --- | --- |
| `uploads.images` | Upload images | Attach PNG, JPEG and WebP images to messages, and upload avatars. |
| `uploads.documents` | Upload documents | Attach PDFs and text or Markdown files to messages; models read their text, or the PDF itself. |
| `uploads.audio` | Upload audio | Attach audio clips to messages; models that hear audio get the clip. |
| `uploads.video` | Upload video | Attach video clips to messages, played in the chat; models that watch video get the clip. |
| `uploads.files` | Upload other files | Attach any other file to messages, offered as a download; models see only its name. |

### Sharing

| Key | Label | What it allows |
| --- | --- | --- |
| `sharing.invite` | Share own content with others | Invite other accounts by handle to edit the user's characters, lore, prompts, scripts and memory items. |
| `chats.invite` | Invite others to chats | Invite other accounts by handle into the user's chats, as chat editors or guests. |
| `sharing.ai.owner_key` | Share models on own connections | Let subscribers' runs on a shared model use this user's own AI connections and spend their key. |
| `catalog.publish` | Publish to the catalog | Publish the user's own characters, lore, prompts, scripts and memory items to the catalog for anyone to subscribe to. |

See [Sharing and the catalog](../chats/sharing.md).

### Administration

| Key | Label | What it allows |
| --- | --- | --- |
| `site.content.manage` | Manage site content (characters, lore, prompts, scripts, memory, variables) | Create and edit the site's shared characters, lore, prompts, scripts, memory and variables. |
| `site.ai.manage` | Manage site AI connections and models | Create and edit the site's shared AI connections and models. |
| `site.settings.manage` | Change site settings and lock user settings | Change site-wide setting defaults and lock settings users may not override. See [Settings](../account/settings.md). |
| `site.cleanup.run` | Clean up every user's chats | Run the message cleanup over every chat in the app, with the site's cleanup settings. |
| `site.hidden.view` | See runtime-only and hidden site content | See the protected content of site items hidden from users: runtime-only characters, prompts, blocks and scripts, and runtime-only or hidden lore. |
| `analytics.all.view` | See every user's analytics | See generation analytics for every account. |
| `catalog.feature` | Choose featured catalog listings | Feature and unfeature catalog listings. |

### Moderation

| Key | Label | What it allows |
| --- | --- | --- |
| `reports.create` | Report content | Report catalog listings, accounts and chat messages to the moderators. Everyone holds it by default; deny it for Everyone to turn reporting off. |
| `users.manage` | Manage accounts | Create, edit, reset and delete accounts other than owners. |
| `groups.manage` | Manage groups and permissions | Create groups, set their permissions and members, and set users' own permissions. |
| `moderation.reports` | Review reports | See reported catalog listings, accounts and messages, and dismiss reports. |
| `moderation.content.view` | Look up any content | Look up and read any account's chats, messages and content by link, id or handle. Every look is written to the moderation log. |
| `moderation.content.delete` | Remove content | Delete any account's chats, messages and content, take down catalog listings, and move users' lore books to the site (with site content management). |
| `moderation.accounts.sanction` | Warn and suspend accounts | Warn accounts other than owners, suspend them for a time or for good, and lift suspensions. |
| `moderation.fingerprints` | See and ban devices and networks | See an account's IP addresses, browsers, devices and the accounts that share them, and ban devices, browser fingerprints and IP addresses. |
| `moderation.log.view` | Read the moderation log | See every moderation action and every look at private content. |
| `moderation.review` | Review flagged and held content | See content the moderation rules flagged and content held for review; approve, reject or dismiss it. |
| `moderation.rules.manage` | Manage moderation rules | Create, edit and delete the regex and webhook rules every moderated save is checked against. |

### Content moderation

These keys put an account into a moderation mode for a content type. See [Moderation](moderation.md).

| Key | Label | What it does |
| --- | --- | --- |
| `moderation.chats.permissive` | Scan chats | Check this account's chat names and the messages it writes against the moderation rules after saving; matches are flagged for review. |
| `moderation.characters.permissive` | Scan characters | Check this account's characters against the rules after saving; matches are flagged for review. |
| `moderation.characters.restrictive` | Hold characters for review | Keep new characters and character text edits in memory, unsaved, until the rules or a moderator approve them. Wins over scanning. |
| `moderation.lore.permissive` | Scan lore books and entries | Check this account's lore books and entries against the rules after saving; matches are flagged for review. |
| `moderation.lore.restrictive` | Hold lore entries for review | Keep new lore entries and lore entry text edits in memory, unsaved, until approved; lore books are scanned. Wins over scanning. |
| `moderation.ai.permissive` | Scan AI connections and models | Check this account's AI connections and models against the rules after saving; matches are flagged for review. |
| `moderation.ai.restrictive` | Hold AI connections and models for review | Keep new AI connections and models and their text edits in memory, unsaved, until approved. Wins over scanning. |
| `moderation.prompts.permissive` | Scan prompts, blocks and outlets | Check this account's prompts, blocks and outlets against the rules after saving; matches are flagged for review. |
| `moderation.prompts.restrictive` | Hold prompts, blocks and outlets for review | Keep new prompts, blocks and outlets and their text edits in memory, unsaved, until approved. Wins over scanning. |

### Scripts

These decide what the user's Lua scripts may do. See [Scripts](../scripts/index.md).

| Key | Label | What it allows |
| --- | --- | --- |
| `scripts.messages` | Scripts may change messages | Let the user's scripts create, edit and delete messages. |
| `scripts.images` | Scripts may caption and request images | Let the user's scripts caption images and request new ones. |
| `scripts.generation` | Scripts may start generations | Let the user's scripts start AI replies. |
| `scripts.memory` | Scripts may run memory jobs and change memory settings | Let the user's scripts run memory jobs and change a chat's memory settings. |
| `scripts.characters` | Scripts may change characters and avatars | Let the user's scripts change characters and their avatars. |
| `scripts.prompts` | Scripts may switch prompts and blocks | Let the user's scripts switch a chat's prompt and toggle its blocks. |
| `scripts.lore` | Scripts may change lore | Let the user's scripts change lore books and entries. |
| `scripts.variables` | Scripts may change variables | Let the user's scripts set and delete a chat's variables and the user's own global variables. |
| `scripts.injections` | Scripts may change injections | Let the user's scripts create, edit and delete a chat's injections. |

## Quotas

Quotas live under **Limits**. Unset everywhere, a quota is unlimited.

| Key | Label | Unit | What it limits |
| --- | --- | --- | --- |
| `quota.spend_per_day` | Spending per day on the site's AI connections | US dollars | What the user's replies, jobs and lore embeddings may cost in any 24 hours on connections the site provides: the connection's reported charge, else an estimate from the model's per-Mtok prices. A run on a model with neither counts as free. Runs on the user's own connections are never limited. |
| `quota.characters` | Own characters | Count | How many characters the user may own. |
| `quota.lore_books` | Own lore books | Count | How many lore books the user may own. |
| `quota.prompts` | Own prompts | Count | How many prompts the user may own. |
| `quota.scripts` | Own scripts | Count | How many scripts the user may own. |
| `quota.chats` | Own chats | Count | How many chats the user may own. |
| `quota.ai_connections` | Own AI connections | Count | How many AI connections the user may own. |
| `quota.ai_models` | Own AI models | Count | How many AI models the user may own. |
| `quota.pending_invites` | Pending invites | Count | How many share and chat invites the user may have waiting for an answer. |
| `quota.upload_bytes` | Upload storage | MiB | How much the user's uploaded files may take up in total. Generated images don't count. |

> [!NOTE]
> The spending check happens when a reply starts, so a run already in progress can take a user slightly over their daily limit.
