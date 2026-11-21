---
title: First run
order: 1
description: Create the owner account, log in, and learn the top bar and the command palette.
---

The first time you open a new Mythweaver install, you create its first account. This page covers that setup, logging in afterwards, and the parts of the screen you use everywhere.

## To create the first account

On a fresh install with no accounts, every page sends you to the setup screen at `/setup`, headed **Welcome to Mythweaver** (or your site's name if it has custom branding).

1. Open the site in your browser. You land on `/setup`.
2. Fill in the form:

   | Field | What it does |
   |---|---|
   | **Email** | The address you log in with. |
   | **Handle** | Your unique public name on this install. |
   | **Nickname (optional)** | A display name shown instead of the handle. |
   | **Password (at least 12 characters)** | Your password. |
   | **Confirm password** | The same password again. |

3. Select **Create account**. You are logged in straight away.

The first account is the install's owner: it can do anything and manage every other account. See [Administration](../administration/index.md) for what that covers.

> [!NOTE]
> `/setup` works only while no account exists. Once someone has created the first account, `/setup` sends you to the login page, and if two people submit the form at once, the second sees "Mythweaver is already set up".

## To log in

1. Go to `/users/log-in` (any page sends you there when you are logged out).
2. Enter your **Email** and **Password**.
3. Select **Log in**.

To log out, open the **Account** menu at the right of the top bar and select **Log out**.

## Auto-login on single-account installs

A server can be started with auto-login turned on (the `MYTHWEAVER_AUTO_LOGIN` environment variable; see [Environment variables](../administration/configuration.md)). While auto-login is on and the install has at most one account, nobody needs a password:

- With no accounts at all, the first visit creates a passwordless owner account and logs you in, so you never see `/setup`.
- With exactly one account, the login page offers **Continue without logging in**, which enters as that account.

As soon as a second account exists, auto-login stops and everyone logs in normally.

> [!WARNING]
> Auto-login lets anyone who can reach the server use the single account. Use it only on a machine or network you alone can reach.

## The top bar

The top bar runs along every page. From the left, it holds the site name (a link home), the command palette button, and links to the app's areas. Some links appear only when your permissions allow that area.

| Link | Where it goes |
|---|---|
| **Chat** | The chat screen at `/`, with your chat list. |
| **Characters** | The character editor at `/characters`. |
| **Lore** | Lore books at `/lore`. |
| **Prompts** | Prompts at `/prompts`. |
| **AI** | AI connections and models at `/ai/providers`. |
| **Variables** | Global variables at `/variables`. |
| **Scripts** | Lua scripts at `/scripts`. |
| **Tags** | Tags at `/tags`. |
| **Jobs** | Background jobs at `/jobs`. |
| **Analytics** | Usage and cost analytics at `/analytics`. |
| **Memory** | Memory profiles at `/memory/profiles`. |
| **Shared with me** | Chats others shared with you at `/shared` (shown once something is shared with you). |
| **Catalog** | Published content at `/catalog`. |

The **Account** menu at the far right holds **Account** (`/users/settings`), **Moderation** and **Submissions** when you may use them, **Import/Export**, **Settings** (`/settings`) and **Log out**. On a small screen, all of these fold into the **Menu** button.

## The command palette

The command palette lets you jump to any screen or run a command by typing part of its name.

1. Press **Ctrl+P** (**⌘P** on macOS), or select the **Command palette** button in the top bar.
2. Type to filter the commands. Recently used commands come first.
3. Use the arrow keys to pick one and press **Enter** to run it. Press **Esc** to close the palette.

Some commands ask for values after you choose them; suggestions appear under the focused field, and **Tab** moves between fields. See [Command palette](../tools/command-palette.md) for the full list.
