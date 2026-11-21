---
title: Your account
order: 11
description: Change your email, handle, nickname and password, and learn when Mythweaver asks for your password again.
---

**Account settings** at `/users/settings` holds the details of your own account: your email, your public handle, your nickname and your password. It also lists your MCP access tokens. Preferences such as the default model, the theme and notifications live separately under [Settings](settings.md).

To open it, go to `/users/settings`. Holders of moderation permissions also see a **Moderation** button there that opens the moderation pages.

## To change your profile

1. Open **Account settings** at `/users/settings`.
2. Under **Profile**, edit **Email**, **Handle** or **Nickname (optional)**.
3. If you change the email, type your password in **Current password (needed to change email)**. An account without a password is not asked.
4. Select **Save**. Mythweaver confirms with "Account saved".

| Field | What it does |
| --- | --- |
| **Email** | The address you log in with. Changing it needs your current password. |
| **Handle** | Your unique public name, shown to other people on the site (for example in shared chats and the catalog). |
| **Nickname (optional)** | A display name shown in place of your handle where one is set. |
| **Current password (needed to change email)** | Asked for only when the email changes. |

## To change your password

1. Under **Change password**, type your **Current password**.
2. Type the new one in **New password (at least 12 characters)** and again in **Confirm new password**.
3. Select **Change password**.

The form checks the new password as you type. Changing your password logs out every other session of your account (other browsers and devices) and keeps you logged in here.

> [!NOTE]
> An account created by auto-login has no password. Its section is called **Set a password** instead, with a **Set password** button and no current-password field. Setting one is needed before you can log in from a login page, and before you invite other people (see [Auto-login on single-account installs](#auto-login-on-single-account-installs)).

## MCP access

The **MCP access** section creates and revokes tokens that let AI clients such as Claude, Cursor or Codex use your account over MCP. It appears only if you hold the `mcp.use` permission. Creating a token needs sudo mode. See [MCP access](../tools/mcp.md) for the details.

## Sudo mode

Some changes are sensitive enough that Mythweaver asks for your password again before making them, even though you are already logged in. When you start one, a **Confirm it's you** dialog opens: "Enter your password to continue. You won't be asked again for 15 minutes." Type your **Password** and confirm, and the change you asked for goes through.

After you confirm, your session is in sudo mode for 15 minutes. Other sensitive changes in that window don't ask again.

Sudo mode is needed to:

- create an MCP access token;
- create, change or delete permission groups, change a user's groups or permission grants, and change a user's role;
- reset another user's password or delete another user;
- ban a user or lift a ban, and delete content from moderation;
- move an AI connection, a model or a lore book into the site's shared collection.

Too many wrong passwords lock the prompt for a while ("Too many tries. Try again in …"). If your account has no password, the prompt says "Set a password in Account settings first."

> [!TIP]
> On a single-account install with auto-login on, sudo mode is always on: there is no password to ask for.

## Auto-login on single-account installs

A personal install can skip logging in. When the server runs with `MYTHWEAVER_AUTO_LOGIN` set to `true` (the default in development), and the site has at most one account, that account is logged in automatically on every visit. If the site has no account yet, Mythweaver creates a passwordless owner account on the first visit.

Auto-login turns off by itself as soon as a second account exists. Before you invite anyone, set a password under **Set a password** so you can still log in. See [Environment variables](../administration/configuration.md) for how to set `MYTHWEAVER_AUTO_LOGIN`.
