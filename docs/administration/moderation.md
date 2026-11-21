---
title: Moderation
order: 9
description: Reports, content lookup, warnings and bans, what is recorded about accounts, automatic content moderation and the moderation log.
---

Moderation tools let you respond to reports, read and remove content when needed, warn or ban accounts and devices, and check content automatically with rules. They live under **Moderation** at paths beginning with `/moderation`, and each tab appears only to accounts holding its permission (see [Users, groups and permissions](users-and-permissions.md)).

| Tab | Path | Permission |
| --- | --- | --- |
| **Reports** | `/moderation/reports` | `moderation.reports` |
| **Flagged** | `/moderation/flagged` | `moderation.review` |
| **Held** | `/moderation/held` | `moderation.review` |
| **Rules** | `/moderation/rules` | `moderation.rules.manage` |
| **Lookup** | `/moderation/lookup` | `moderation.content.view` |
| **Users** | `/moderation/users` | `users.manage` |
| **Groups** | `/moderation/groups` | `groups.manage` |
| **Bans** | `/moderation/bans` | `moderation.accounts.sanction` or `moderation.fingerprints` |
| **Log** | `/moderation/log` | `moderation.log.view` |

Owners can never be warned or banned, and you can't sanction your own account. Every open moderation screen refreshes when another moderator acts.

## Reports

Accounts holding `reports.create` (Everyone, by default) can report catalog listings, accounts and chat messages they can see. They answer **What is wrong with it?** and get "Thanks, a moderator will look at it". Each reporter can have one open report per item. Deny `reports.create` for Everyone to turn reporting off.

### To handle a report

1. Open **Moderation** → **Reports** and select a report.
2. Read the reported item, then act on it:
   - **Take down** a catalog listing, or delete the message or content. The owner is told why.
   - **Warn or suspend** the account (see below).
   - **Dismiss** the report if nothing is wrong.
3. Acting on the item marks its reports **Actioned**; dismissing marks it **Dismissed**.

## Lookup

**Lookup** at `/moderation/lookup` finds any one item from **Link, id, @handle or email**: an account, a chat, a message, a character, a lore book or entry, a prompt, block or outlet, an AI connection or model, and so on. There is no browsing list; content is reached only from a report, a lookup, or an account's **Content** page.

- Reading private content needs `moderation.content.view`. Every look is written to the moderation log as **Viewed**.
- Deleting needs `moderation.content.delete` and confirming your identity again (sudo mode). A deletion removes the item for its owner and everyone it is shared with. Site content is edited in the site's own editors instead.
- Only an owner can look up or delete an owner's content.

## Accounts' moderation records

An account's record, opened with **Lookup** from **Moderation** → **Users** (`/moderation/users/<id>/record`), shows its reports, warnings, bans and log. With `moderation.fingerprints` it also shows the devices and networks it was seen with and **Accounts sharing these**.

### What is recorded

Mythweaver records these signals for each account on login, on every page it opens and on every MCP call:

| Signal | Notes |
| --- | --- |
| IP address | With location and network when [GeoIP](geoip.md) is set up. Only accurate behind a trusted proxy; see [HTTPS and client IPs](https-and-proxies.md). |
| Browser | The user agent. |
| Language | The browser's language list. |
| Device | A random device cookie that lasts 400 days. |
| Browser fingerprint | A hash; identical devices share it. |

Each row keeps when it was first and last seen and how often. Rows are deleted a year after they were last seen. IP address, device and browser fingerprint link accounts that share them and can be banned. A user agent or language alone is shared by too many people to mean anything. Let your users know what is recorded.

## Warnings and bans

### To warn an account

1. On the account's record, select **Warn or suspend**.
2. Write the **Warning** and select **Warn**.

Until the user acknowledges it with **I understand**, they see only the warning page ("A moderator warned you") whenever they use the app. Warnings stay in their inbox.

### To ban an account, device or network

1. On the account's record, select **Warn or suspend** and choose to ban. Banning asks you to confirm your identity again.
2. Choose what to ban: **Suspend the account** (needs `moderation.accounts.sanction`), and any of the **Devices and addresses seen in the last 30 days** (devices, browser fingerprints and IP addresses; needs `moderation.fingerprints`). Choose the account or at least one device or address.
3. Choose how long it lasts: 1, 3, 7, 30 or 90 days, **1 year** or **Permanent**, and give a **Reason**.

| Ban type | What it does |
| --- | --- |
| Account | Suspends the account and logs out all its browsers. The user sees "Your account is suspended" with the reason and end date. |
| Device | Blocks the device cookie. |
| Browser fingerprint | Blocks every browser with that fingerprint. Identical devices share fingerprints, so this can catch other people. |
| IP address | Blocks the address. Shared networks can catch other people. |

Device and network bans show "Logins from this device or network are blocked." Bans are checked at login, on every request and page, and on MCP calls. Network bans never apply to owners, and you can't ban a value you were seen with yourself.

**Bans** at `/moderation/bans` lists bans in force; **Show lifted and expired** shows the rest. **Lift** ends a ban early.

## Content moderation

Content moderation checks what accounts write against rules you define. Every account starts **exempt**. To moderate someone, grant a mode per content type to Everyone or a group at `/moderation/groups`, under **Content moderation**:

| Mode | What happens |
| --- | --- |
| Exempt (no flag, the default) | Saves as usual and nothing is checked. |
| **Scan** (`*.permissive` keys) | Saves as usual. The rules then check the saved text in the background, and a match opens a report under **Flagged**. |
| **Hold** (`*.restrictive` keys) | A create, text edit or import is kept in server memory, unsaved, until every rule passes or a moderator approves it under **Held**. Hold wins over scan. |

| Content type | Scan | Hold |
| --- | --- | --- |
| Chats (chat names and the messages the account writes) | Yes | No |
| Characters | Yes | Yes |
| Lore | Books and entries | Entries only; books are scanned |
| AI connections and models | Yes | Yes |
| Prompts, blocks and outlets | Yes | Yes |

An edit that changes no text (a toggle, a sampler value, an order) is never held or scanned. Owners are always exempt, and a **Deny** on any of the account's groups exempts it, as usual for permissions.

### To create a rule

1. Open **Moderation** → **Rules** (`/moderation/rules`) and select **New rule**.
2. Fill in the fields below and select **Save**.

| Field | What it does |
| --- | --- |
| **Name** | The rule's name in findings and the log. |
| **Kind** | **Regex** or **Webhook**. |
| **Content types** | Which content the rule checks: **Characters**, **Lore books and entries**, **AI connections and models**, **Prompts, blocks and outlets**, **Chats and messages**. |
| **Enabled** | Turns the rule on or off. |
| **Pattern** | Regex only. A Unicode regular expression matched against each text field. |
| **Case sensitive** | Regex only. Off, matching ignores case. |
| **On a match** | Regex only. **Flag for review** or **Reject**. |
| **URL** | Webhook only. Where the content is posted. |
| **Signing secret (optional)** | Webhook only. Signs each request. It is stored encrypted and never shown again; leave it blank to keep the current one, or use **Remove the secret**. |
| **Request timeout (ms)** | Webhook only. How long to wait for the response. |
| **Verdict** | Webhook only. **In the response (sync)** or **Later, by callback**. |
| **Callback timeout (minutes)** | Callback only. How long to wait for the verdict. |

A regex that hits its match limit or no longer compiles flags the content.

### Webhook rules

A webhook rule posts the content as JSON with fields such as `event` (`moderation.scan`), `content_type`, `subject_type`, `subject_id`, `held`, `user` (`id` and `handle`), `title` and `fields` (each text field by name), plus `chat_id` for chats and `callback_url` in callback mode. With a signing secret, the request carries `x-mythweaver-signature: sha256=<hex HMAC-SHA256 of the body>`.

The service answers with a verdict, either in the response or later by posting to the `callback_url` it was sent:

```json
{"action": "flag", "reason": "Mentions a real person's address"}
```

`action` is `approve`, `flag` or `reject`. Any failure (an error, a timeout, a bad answer) flags the content.

> [!IMPORTANT]
> Callback mode needs `MODERATION_CALLBACK_URL` on the server: the app's public base URL, for example `https://mythweaver.example`. Without it, callback rules can't be saved.

### How the verdict is decided

All enabled rules for the content type run. Any **reject** rejects the content (and ends the scan). Otherwise any **flag** sends it to review. Otherwise it is approved.

- Saved (scanned) content that is flagged or rejected gets a report under **Flagged**, marked "Reported by automated rules", with the **Rule findings**.
- Held content that is approved is saved automatically. Rejected held content is discarded and its submitter is told why. Flagged held content waits under **Held** for a moderator.

### To review flagged and held content

1. Open **Moderation** → **Flagged** or **Held** and select an item.
2. Held edits show the **Current** and **Proposed** text side by side.
3. For held content, select **Approve** to save it ("Approved and saved") or **Reject** and say why (the submitter is told). For flagged content, act on it as for a report, or **Dismiss**.

Approving saves the content as its submitter, checking ownership and quotas against current data, so a stale hold fails cleanly.

### Held content limits

> [!WARNING]
> Held content lives only in server memory. A restart or deploy discards every held item.

| Limit | Value |
| --- | --- |
| How long an item waits | 7 days, then it is discarded and the submitter is told. |
| Size of one held item | 25 MB |
| Held items per account | 50 |
| Total held per account | 100 MB |

A new edit of the same item replaces the submitter's older hold of it.

### Submissions

Submitters see their held items at `/submissions`, each marked **New**, **Edit** or **Import** and **Checking** or **Waiting for a moderator**. **Withdraw** discards an item unsaved.

## The moderation log

**Log** at `/moderation/log` lists every moderation action: **Viewed**, **Deleted**, **Took down**, **Warned**, **Banned**, **Lifted a ban**, **Dismissed a report**, **Approved held content**, **Rejected held content**, and creating, changing or deleting a moderation rule. Each account's record has its own log too.
