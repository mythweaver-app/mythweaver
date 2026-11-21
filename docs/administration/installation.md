---
title: Installation
order: 1
description: Running Mythweaver in production from source, as a release, or in Docker.
---

This page covers installing Mythweaver on a server for real use. For every variable mentioned here, see [Environment variables](configuration.md).

> [!CAUTION]
> Never serve the development configuration. It has a public encryption key and secret key base, turns off the WebSocket origin check, logs in automatically while only one account exists, and exposes a live dashboard at `/dev/dashboard`.

## Requirements

- PostgreSQL with the `vector` extension (for example the `pgvector/pgvector:pg18-trixie` image).
- These environment variables, or the server refuses to start:

| Variable | What it is |
| --- | --- |
| `MIX_ENV=prod` | Runs the production configuration. |
| `DATABASE_URL` | The database, for example `ecto://USER:PASS@HOST/DATABASE`. |
| `SECRET_KEY_BASE` | Signs and encrypts cookies and links. Generate one with `mix phx.gen.secret`. |
| `MYTHWEAVER_VAULT_KEY` | Encrypts stored AI API keys. Generate one with `openssl rand -base64 32`. |
| `PHX_HOST` | The public host name, for example `mythweaver.example.org`. |
| `MYTHWEAVER_UPLOADS_DIR` | A persistent directory for uploads, unless you set `MYTHWEAVER_STORAGE=s3`. |

`PORT` is optional and defaults to 4000.

> [!WARNING]
> Keep `MYTHWEAVER_VAULT_KEY` safe. If you lose it, every stored AI connection API key is lost and must be entered again.

## To install from source

```bash
export MIX_ENV=prod
mix deps.get --only prod
mix compile
mix assets.deploy
mix ecto.create
mix ecto.migrate
mix run -e "Mythweaver.Release.seed()"   # first install only
mix phx.server
```

On later upgrades run `mix ecto.migrate` instead of seeding.

The seed step loads only the built-in prompts, memory, caption and expression content. It is safe to run again: it adds the default prompt only while no prompt exists, and updates the other built-in rows in place.

> [!CAUTION]
> Don't run `mix ecto.setup.dev` on a real install. Its development seeds delete every chat and character to load sample data.

## To build a release

1. Run `MIX_ENV=prod mix assets.deploy && MIX_ENV=prod mix release`.
2. The release is written to `_build/prod/rel/mythweaver`. It contains three helper scripts:

| Script | What it does |
| --- | --- |
| `bin/migrate` | Runs every pending migration. Run it before starting a new version. |
| `bin/seed` | Loads the built-in content. Run it on first install. |
| `bin/server` | Starts the web server. |

## To run with Docker

The repository's `Dockerfile` builds the release into a small Ubuntu image.

```bash
docker build -t mythweaver .                  # optionally --build-arg MYTHWEAVER_NAME=…
docker run --rm --env-file .env mythweaver /app/bin/migrate
docker run --rm --env-file .env mythweaver /app/bin/seed      # first install only
docker run --env-file .env -v mythweaver-data:/data -p 4000:4000 mythweaver
```

The env file holds the required variables above, plus `MYTHWEAVER_TRUSTED_PROXIES` for the proxy in front of the app (see [HTTPS and client IPs](https-and-proxies.md)). Uploads, GeoIP databases and tokenizers live under `/data`, so keep that volume.

The name and logo are build arguments because they are fixed when the image is built; see [Branding](branding.md).

## To finish setup

1. Open the site. While no account exists, every visitor is sent to `/setup`.
2. Fill in **Email**, **Handle**, **Nickname (optional)**, **Password (at least 12 characters)** and **Confirm password**, then select **Create account**. The first visitor to complete this form becomes the owner and is logged in, and `/setup` closes for good.
3. Connect a model next; see [Connect a model](../getting-started/connect-a-model.md).

> [!IMPORTANT]
> Finish `/setup` before you expose the site to anyone else, or a stranger could claim the owner account.

## Default permissions

After installation the **Everyone** group holds:

- content creation (the `content.*.create` keys);
- the `scripts.*` keys;
- `ai.connections.create`;
- `mcp.use`, `sharing.invite`, `chats.invite`, `catalog.publish` and `reports.create`.

Updates that add new capabilities may also grant them to Everyone. Deny any of them for Everyone at `/moderation/groups`; see [Users, groups and permissions](users-and-permissions.md).

## What moderation records

For every account Mythweaver records IP addresses, user agent, browser languages, a device cookie that lasts 400 days and a browser fingerprint hash. Each is deleted a year after it was last seen. Let your users know; see [Moderation](moderation.md).
