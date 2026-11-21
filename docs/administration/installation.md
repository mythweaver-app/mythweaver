---
title: Installation
order: 1
description: Running Mythweaver in production with Docker Compose, from source, as a release, or in Docker.
---

This page covers installing Mythweaver on a server for real use. For every variable mentioned here, see [Environment variables](configuration.md).

> [!CAUTION]
> Never serve the development configuration. It has a public encryption key and secret key base, turns off the WebSocket origin check, logs in automatically while only one account exists, and exposes a live dashboard at `/dev/dashboard`.

## To run with Docker Compose

The quickest install runs everything in Docker on one computer: Mythweaver, its database, the image resizer and a web server in front of them. You need only Docker with Docker Compose 2.23.1 or newer.

1. Make an empty directory.
2. Save the file below in it as `compose.yml`.
3. In that directory, run `docker compose up -d`.
4. Open http://localhost:4000 and create the owner account; see [To finish setup](#to-finish-setup).

The first start creates the database, generates the secrets and loads the built-in prompts. Optional settings (the port, the address it listens on, the database password) go in a `.env` file beside `compose.yml`; see [Compose file (deploy)](configuration.md#compose-file-deploy).

```yaml
# Mythweaver. Put this file in an empty directory, run `docker compose up -d`, then open
# http://localhost:4000 and create the owner account. The first start creates the database,
# generates the secrets (in the `data` volume, under `secrets/`) and loads the built-in prompts.
#
# Optional settings go in a `.env` file beside this one:
#   MYTHWEAVER_PORT=4000          the port on this computer
#   MYTHWEAVER_BIND=127.0.0.1     the address it is published on
#   POSTGRES_PASSWORD=...         the database password; set it before the first start
#
# Plain http works only at http://localhost. Back up both volumes: `data` holds the uploads and
# the key that encrypts stored AI API keys.
services:
  db:
    image: pgvector/pgvector:pg18-trixie
    restart: unless-stopped
    shm_size: 128mb
    environment:
      POSTGRES_DB: mythweaver
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-mythweaver}
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d mythweaver"]
      interval: 5s
      timeout: 5s
      retries: 20
    volumes:
      - db:/var/lib/postgresql

  # Generates the secrets once, before the app and xi start.
  secrets:
    image: ghcr.io/mythweaver-app/mythweaver:latest
    command: ["/app/bin/secrets"]
    volumes:
      - data:/data

  mythweaver:
    image: ghcr.io/mythweaver-app/mythweaver:latest
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
      secrets:
        condition: service_completed_successfully
    environment:
      DATABASE_URL: ecto://postgres:${POSTGRES_PASSWORD:-mythweaver}@db/mythweaver
      PHX_HOST: localhost
      PHX_SCHEME: http
      PHX_URL_PORT: ${MYTHWEAVER_PORT:-4000}
      # Only containers on this network reach the app; nginx is the one that forwards clients.
      MYTHWEAVER_TRUSTED_PROXIES: 10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,fc00::/7
      MYTHWEAVER_IMAGE_PROXY: xtandard
      MYTHWEAVER_XI_URL: /img
      MYTHWEAVER_XI_INTERNAL_URL: http://nginx/img
      MYTHWEAVER_XI_SOURCE_PREFIX: xi://uploads/
    volumes:
      - data:/data

  # Resizes uploaded images. Signed and encrypted URLs only, with the keys from `secrets/xi.env`.
  xi:
    image: ghcr.io/xantiagoma/xtandard-image:0.1.1-full
    restart: unless-stopped
    user: "65534:65534"
    read_only: true
    tmpfs:
      - /tmp:size=64m
    entrypoint: ["/bin/sh", "-c", "set -a && . /data/secrets/xi.env && exec /usr/local/bin/xtandard-image serve"]
    depends_on:
      secrets:
        condition: service_completed_successfully
    environment:
      XI_SOURCES: uploads
      XI_SOURCES_UPLOADS_TYPE: fs
      XI_SOURCES_UPLOADS_ROOT: /data/uploads
      XI_SECURITY_UNSIGNED_POLICY: deny
      XI_CACHE_HEADERS_TTL: 86400s
      XI_DETECT_ENABLED: "true"
      XI_VIDEO_ENABLED: "true"
    volumes:
      - data:/data:ro

  # The front door: the app at / and cached, resized images at /img/.
  nginx:
    image: nginx:alpine
    restart: unless-stopped
    depends_on:
      - mythweaver
      - xi
    ports:
      - ${MYTHWEAVER_BIND:-127.0.0.1}:${MYTHWEAVER_PORT:-4000}:80
    configs:
      - source: nginx
        target: /etc/nginx/conf.d/default.conf
    volumes:
      - xi-cache:/var/cache/nginx/xi

configs:
  nginx:
    content: |
      proxy_cache_path /var/cache/nginx/xi levels=1:2 keys_zone=xi:10m max_size=2g inactive=3d use_temp_path=off;

      map $$http_accept $$xi_format {
        default "";
        "~*image/avif" "avif";
        "~*image/webp" "webp";
      }

      map $$http_upgrade $$connection_upgrade {
        default upgrade;
        "" close;
      }

      server {
        listen 80;
        client_max_body_size 0;

        location /img/ {
          proxy_pass http://xi:8080/;
          proxy_http_version 1.1;
          proxy_cache xi;
          proxy_cache_key "$$request_uri|$$xi_format";
          proxy_ignore_headers Vary;
          proxy_cache_valid 200 1d;
          proxy_cache_valid 404 1m;
          proxy_cache_lock on;
          proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
        }

        location / {
          proxy_pass http://mythweaver:4000;
          proxy_http_version 1.1;
          proxy_set_header Host $$http_host;
          proxy_set_header X-Forwarded-For $$remote_addr;
          proxy_set_header X-Forwarded-Proto $$scheme;
          proxy_set_header Upgrade $$http_upgrade;
          proxy_set_header Connection $$connection_upgrade;
          proxy_read_timeout 1h;
        }
      }

volumes:
  db:
  data:
  xi-cache:
```

> [!WARNING]
> The `data` volume holds the key that encrypts stored AI API keys, in `secrets/app.env`. If you lose the volume, every stored AI connection API key is lost and must be entered again. Back up both the `data` and `db` volumes.

To upgrade, run this in the same directory. The new version migrates the database when it starts.

```bash
docker compose pull && docker compose up -d
```

When an upgrade brings new built-in content (prompts, memory, caption and expression rows), load it with:

```bash
docker compose run --rm mythweaver /app/bin/seed
```

Plain http works only at http://localhost. To reach the install from other devices, serve it over HTTPS with `PHX_HOST` set to its public name; see [HTTPS and client IPs](https-and-proxies.md).

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

## To install a release tarball

Every release on GitHub carries a built release for Linux, `mythweaver-<version>-linux-amd64.tar.gz` and `mythweaver-<version>-linux-arm64.tar.gz`, with their checksums in `SHA256SUMS`. It needs glibc 2.39 or newer, OpenSSL 3 and ncurses 6, as on Ubuntu 24.04 or newer.

1. Download the tarball for your machine from the GitHub release.
2. Unpack it with `tar -xzf mythweaver-<version>-linux-<arch>.tar.gz`. It unpacks into a `mythweaver` directory.
3. Set the required variables above, then run `mythweaver/bin/migrate`, `mythweaver/bin/seed` (first install only) and `mythweaver/bin/server`, as described in [To build a release](#to-build-a-release).

## To run with Docker

The published image is `ghcr.io/mythweaver-app/mythweaver` (`latest`, or a version such as `0.1.0`). The repository's `Dockerfile` builds the same image if you want your own branding.

```bash
docker build -t mythweaver .                  # optional, your own build: then run `mythweaver` instead
docker run --env-file .env -v mythweaver-data:/data -p 4000:4000 ghcr.io/mythweaver-app/mythweaver:latest
docker run --rm --env-file .env -v mythweaver-data:/data ghcr.io/mythweaver-app/mythweaver:latest /app/bin/seed   # after an upgrade with new built-in content
```

On every start the image:

1. Generates the secrets that are missing into `/data/secrets` (`app.env` with `SECRET_KEY_BASE` and `MYTHWEAVER_VAULT_KEY`, and `xi.env` with the image resizer's keys). An existing file is never rewritten, and a variable in the env file wins over it, so you may leave both keys out of the env file.
2. Runs every pending migration, and loads the built-in content when the database was brand new.
3. Starts the server.

The env file holds the other required variables above, plus `MYTHWEAVER_TRUSTED_PROXIES` for the proxy in front of the app (see [HTTPS and client IPs](https-and-proxies.md)). Uploads, secrets, GeoIP databases and tokenizers live under `/data`, so keep and back up that volume.

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
