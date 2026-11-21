---
title: Administration
order: 12
description: Running a Mythweaver server, and what the owner and site administrators can do.
---

This section is for the people who install and run a Mythweaver server: the owner, and the accounts the owner trusts with site administration or moderation.

## The owner

The first person to open `/setup` on a fresh install claims the **owner** account. An owner holds every permission and no limit applies to them. Owners are always exempt from content moderation, can't be warned or banned, and only another owner can change an owner's account. Each user's chats are their own, the owner's included: an owner sees another account's private content only through the moderation tools, and every such look is logged.

## Site administrators

Every other account has the **User** role, and what it may do comes from permission keys granted to groups or to the user directly. A fresh install has two system groups: **Everyone**, which every account belongs to implicitly, and **Administrators**, which holds the site administration and moderation permissions. Depending on the keys they hold, administrators can:

- create and edit the site's shared characters, lore, prompts, scripts, memory and variables;
- manage the site's AI connections and models;
- change site-wide setting defaults and lock settings for everyone (see [Settings](../account/settings.md));
- create, edit and delete accounts, and manage groups and permissions;
- review reports, flagged and held content, look up any content, warn, suspend and ban accounts, and read the moderation log.

The admin screens live under **Moderation** (paths beginning with `/moderation`). Each tab appears only to accounts holding the matching permission.

## In this section

| Page | What it covers |
| --- | --- |
| [Installation](installation.md) | Running in production with a release or Docker, first-run seeding and `/setup`. |
| [Environment variables](configuration.md) | Every variable the server reads. |
| [Image storage and proxies](image-storage.md) | Local or S3 storage, image proxies and link expiry. |
| [HTTPS and client IPs](https-and-proxies.md) | TLS with the bundled nginx and trusting reverse proxies. |
| [Web Push](push.md) | VAPID keys and the secure-origin requirement. |
| [GeoIP](geoip.md) | Showing where IP addresses on a moderation record come from. |
| [Branding](branding.md) | Renaming the installation and replacing the logo. |
| [Users, groups and permissions](users-and-permissions.md) | Accounts, groups, every permission key and quota. |
| [Moderation](moderation.md) | Reports, lookups, bans, content moderation rules and the log. |
