---
title: Environment variables
order: 2
description: Every environment variable Mythweaver and its compose stack read, with defaults.
---

Mythweaver is configured with environment variables. Most are read when the server starts, so a change needs a restart. A few are read when the app is built and need a rebuild, as noted below. A missing required variable, or a bad combination of storage and image proxy settings, stops the server at boot with a message naming the variable.

## To set variables

- **From source or a release:** export the variables in the shell or service manager that starts the server.
- **Docker:** put them in an env file and pass it with `--env-file .env`.
- **Compose stack:** the `docker compose` variables (the nginx ones below) go in a `.env` file beside `compose.yml`.

In development, `mise.toml` sets the image proxy and trusted proxy variables for you. A value already in your environment wins over mise's.

## Server

| Variable | Required | Default | What it does |
| --- | --- | --- | --- |
| `MIX_ENV` | Yes, `prod` | `dev` | Selects the configuration. Production needs `prod`; never serve `dev`. |
| `DATABASE_URL` | Yes (prod) | None | The PostgreSQL database, for example `ecto://USER:PASS@HOST/DATABASE`. The database needs the `vector` extension. |
| `SECRET_KEY_BASE` | Yes (prod) | None | Signs and encrypts cookies, sessions and `/uploads` links. Generate with `mix phx.gen.secret`. Changing it logs everyone out and invalidates outstanding links. |
| `MYTHWEAVER_VAULT_KEY` | Yes (prod) | None | Encrypts AI connection API keys at rest. Generate with `openssl rand -base64 32`. Losing it loses every stored key. |
| `PHX_HOST` | Yes (prod) | None | The public host name, for example `mythweaver.example.org`. A wrong value breaks the live connection's origin check. Production links use it with `PHX_SCHEME` and `PHX_URL_PORT`. |
| `PHX_SCHEME` | No | `https` | The scheme of the site's public links, `https` or `http`. `http` works only when `PHX_HOST` is `localhost`, because production redirects every other host to HTTPS. |
| `PHX_URL_PORT` | No | `443` for `https`, `80` for `http` | The port of the site's public links, for example the MCP address in user settings. Set it when visitors reach the site on another port. |
| `MYTHWEAVER_SECRETS_DIR` | No | `/data/secrets` in Docker | Where the Docker image keeps the secrets it generates on first start: `app.env` (`SECRET_KEY_BASE` and `MYTHWEAVER_VAULT_KEY`) and `xi.env` (the image resizer's keys, used when `MYTHWEAVER_IMAGE_PROXY=xtandard`). A file there is never rewritten, and a variable you set yourself wins over it. |
| `PORT` | No | `4000` | The HTTP port the server listens on. |
| `PHX_SERVER` | For releases | Unset | Starts the web server in a release. `bin/server` sets it for you. |
| `POOL_SIZE` | No | `10` | Number of database connections. |
| `ECTO_IPV6` | No | Off | `true` or `1` connects to the database over IPv6. |
| `DNS_CLUSTER_QUERY` | No | Unset | A DNS name to discover other nodes for clustering. |
| `MYTHWEAVER_AUTO_LOGIN` | No | Off (on in development) | `true` or `1` logs visitors in without a password while only one account exists. Once a second account exists, normal login applies. |
| `MYTHWEAVER_TRUSTED_PROXIES` | No | None trusted (`mise.toml`: `127.0.0.0/8,::1/128,172.30.250.0/24`) | Comma-separated CIDRs of reverse proxies whose `X-Forwarded-For` header is believed. An empty value trusts none. See [HTTPS and client IPs](https-and-proxies.md). |
| `MODERATION_CALLBACK_URL` | For callback rules | Unset | The app's public base URL (for example `https://mythweaver.example`) that webhook moderation rules in callback mode post their verdict back to. See [Moderation](moderation.md). |
| `HF_TOKEN` | No | Unset | A Hugging Face token for downloading gated tokenizers (for example Meta Llama or Google models). Ungated tokenizers need none. |
| `MYTHWEAVER_TOKENIZER_CACHE` | No | Your operating system's user cache directory (`/data/tokenizers` in Docker) | Where downloaded tokenizer files are kept. |

## Branding (build time)

These are read when the app is compiled and its assets are built. Set them for `mix compile` and `mix assets.deploy`, or pass them as `--build-arg` to `docker build`, and rebuild after changing them. See [Branding](branding.md).

| Variable | Required | Default | What it does |
| --- | --- | --- | --- |
| `MYTHWEAVER_NAME` | No | `Mythweaver` | The installation's name in the top bar, tab title, login and setup pages, app manifest and test push notifications. |
| `MYTHWEAVER_LOGO_PATH` | No | The built-in logo | An SVG file, absolute or relative to the project root, that replaces the top-bar logo. A missing or non-SVG file fails the build. |

## Uploads and images

See [Image storage and proxies](image-storage.md) for how these fit together.

| Variable | Required | Default | What it does |
| --- | --- | --- | --- |
| `MYTHWEAVER_STORAGE` | No | `local` | `local` stores uploads on disk; `s3` stores them in an S3-compatible bucket. |
| `MYTHWEAVER_UPLOADS_DIR` | Yes in prod with `local` | `priv/uploads` (`/data/uploads` in Docker) | The persistent directory for uploaded files. |
| `MYTHWEAVER_S3_BUCKET` | With `s3` | None | The bucket name. `BUCKET_NAME` is accepted instead. |
| `BUCKET_NAME` | With `s3`, if no `MYTHWEAVER_S3_BUCKET` | None | Alternative bucket name variable, as set by `fly storage create` for Tigris. |
| `AWS_ACCESS_KEY_ID` | With `s3` | None | The bucket's access key. |
| `AWS_SECRET_ACCESS_KEY` | With `s3` | None | The bucket's secret key. |
| `AWS_REGION` | No | `auto` | The bucket's region. |
| `AWS_ENDPOINT_URL_S3` | With `s3` | None | The S3 endpoint URL (AWS, Tigris, MinIO and so on). |
| `MYTHWEAVER_IMAGE_PROXY` | No | `none` (`mise.toml`: `xtandard`) | `none`, `xtandard`, `cloudflare` or `fastly`: what resizes images. |
| `MYTHWEAVER_XI_URL` | With `xtandard` | None (`mise.toml`: `/img`) | The address browsers reach xtandard-image at. May be relative. |
| `MYTHWEAVER_XI_INTERNAL_URL` | No | `MYTHWEAVER_XI_URL` (`mise.toml`: `http://localhost:4080/img`) | The address the server itself reaches xtandard-image at, when the browser's address is relative or unreachable from the server. |
| `MYTHWEAVER_XI_KEY` | With `xtandard` | None | Hex signing key; must equal xtandard-image's `XI_SIGNING_KEYS`. |
| `MYTHWEAVER_XI_SALT` | With `xtandard` | None | Hex signing salt; must equal `XI_SIGNING_SALTS`. |
| `MYTHWEAVER_XI_ENCRYPTION_KEY` | With `xtandard` | None | Hex key of 16, 24 or 32 bytes; must equal `XI_ENCRYPTION_KEYS`. |
| `MYTHWEAVER_XI_SOURCE_PREFIX` | With `xtandard` and `local` | None (`mise.toml`: `xi://uploads/`) | The xtandard-image source that points at the uploads directory, for example `xi://uploads/`. |
| `MYTHWEAVER_CLOUDFLARE_ZONE_URL` | With `cloudflare` | None | The Cloudflare zone URL that serves image transformations. |
| `MYTHWEAVER_FASTLY_BASE_URL` | With `fastly` and `s3` | None | The Fastly service URL that serves image optimization. |
| `MYTHWEAVER_UPLOADS_ORIGIN_SECRET` | With `cloudflare` or `fastly` over `local` | None | A secret the CDN sends as the `x-mythweaver-origin-secret` header; `/uploads` refuses images to requests without it. |
| `MYTHWEAVER_IMAGE_LINK_WINDOW` | No | `86400` | Seconds per link window; image links stay valid for one to two windows. At most `302400` with S3. |
| `MYTHWEAVER_MAX_UPLOAD_BYTES` | No | 20 MB | The largest image, in bytes, a user may upload. |

## Web Push

All three or none. Setting only some stops the server at boot. See [Web Push](push.md).

| Variable | Required | Default | What it does |
| --- | --- | --- | --- |
| `MYTHWEAVER_VAPID_PUBLIC_KEY` | For push | Unset | The VAPID public key from `mix web_push_ex.vapid`. |
| `MYTHWEAVER_VAPID_PRIVATE_KEY` | For push | Unset | The matching private key. |
| `MYTHWEAVER_VAPID_SUBJECT` | For push | Unset | A `mailto:` address or `https:` URL push services may contact. |

## GeoIP

See [GeoIP](geoip.md).

| Variable | Required | Default | What it does |
| --- | --- | --- | --- |
| `MYTHWEAVER_MAXMIND_ACCOUNT_ID` | For GeoIP | Unset | Your MaxMind GeoLite account ID, used by `mix mythweaver.geoip.download`. |
| `MYTHWEAVER_MAXMIND_LICENSE_KEY` | For GeoIP | Unset | Your MaxMind licence key. |
| `MYTHWEAVER_GEOIP_DIR` | No | `priv/geoip` (`/data/tokenizers` in Docker) | Where the GeoLite2 databases are stored and read from. |

## Compose file (deploy)

These are read by `docker compose` from a `.env` file beside the end-user compose file in [To run with Docker Compose](installation.md#to-run-with-docker-compose), not by the app.

| Variable | Required | Default | What it does |
| --- | --- | --- | --- |
| `MYTHWEAVER_PORT` | No | `4000` | The port on this computer the site is served on. |
| `MYTHWEAVER_BIND` | No | `127.0.0.1` | The address that port is published on. `0.0.0.0` publishes it on every interface. |
| `POSTGRES_PASSWORD` | No | `mythweaver` | The database password. Set it before the first start: the database keeps the password it was created with. |

## Compose stack (nginx)

These are read by `docker compose`, not by the app. See [HTTPS and client IPs](https-and-proxies.md).

| Variable | Required | Default | What it does |
| --- | --- | --- | --- |
| `COMPOSE_FILE` | For HTTPS | `compose.yml` | Set to `compose.yml:compose.tls.yml` to turn on TLS. |
| `MYTHWEAVER_DOMAIN` | With TLS | None | The site's public host name; its DNS must point at this host. |
| `MYTHWEAVER_ACME_EMAIL` | With TLS | None | The contact address for Let's Encrypt notices. |
| `MYTHWEAVER_NGINX_TRUSTED_UPSTREAM` | No | `127.0.0.1/32` | The address another proxy in front of nginx connects from, so nginx believes its `X-Forwarded-For`. |
| `MYTHWEAVER_NGINX_BIND` | No | `127.0.0.1` | The address nginx's port 4080 is published on. `0.0.0.0` publishes it on every interface. |

## Development only

| Variable | Default | What it does |
| --- | --- | --- |
| `DATABASE_HOST` | `localhost` | The development and test database host. |
| `DATABASE_NAME` | `mythweaver_dev` | The development database name. |
| `PHX_BIND_ALL` | Off | `true` or `1` makes the development server listen on every interface instead of loopback. Needed for nginx on Linux Docker. |
| `FILE_WATCHER_POLL` | Off | `true` or `1` makes live reload poll for file changes, for file systems without change events. |
