---
title: Install Mythweaver
order: 0
description: Run Mythweaver on your own computer with Docker, then start, stop, upgrade and back it up.
---

The simplest way to run Mythweaver is on your own computer with Docker: you download one file and start it with one command. This page covers that install and the commands you'll use afterwards to run, upgrade and back it up. To run Mythweaver on a server for other people, see [Installation](../administration/installation.md).

## What you need

- Docker with Docker Compose 2.23.1 or newer. On macOS and Windows, install Docker Desktop. On Linux, install Docker Engine with the Compose plugin. Run `docker compose version` to check your version.
- About 1.5 GB of free disk space for the images, plus room for your uploads and the database.
- Port 4000 free on your computer. You can pick another port; see [Settings](#settings).

## To install

1. Make an empty directory for Mythweaver and open a terminal in it. The directory's name becomes the name of the install, so keep it once you have chosen it.
2. Download the compose file into it:
   ```bash
   curl -LO https://github.com/mythweaver-app/mythweaver/releases/latest/download/compose.yml
   ```
   You can also copy the file from [To run with Docker Compose](../administration/installation.md#to-run-with-docker-compose) and save it as `compose.yml`.
3. Start Mythweaver:
   ```bash
   docker compose up -d
   ```
   The first start downloads the images, creates the database, generates the secrets and loads the built-in prompts. It can take a few minutes.
4. Open http://localhost:4000. Mythweaver sends you to `/setup`, where you create the owner account; see [First run](first-run.md).

> [!IMPORTANT]
> Use `http://localhost:4000` exactly. Mythweaver's live connection accepts only `localhost`. At `http://127.0.0.1:4000` pages load but don't respond, and any other name redirects to HTTPS, which this install doesn't serve.

## What runs

`docker compose up -d` starts five services. You only open the web address; the services talk to each other inside Docker.

| Service | What it does |
| --- | --- |
| `mythweaver` | The app itself. It updates the database when a new version starts. |
| `db` | The PostgreSQL database that holds accounts, characters, chats and settings. |
| `nginx` | The web server at http://localhost:4000. It passes pages to the app and images to `xi`. |
| `xi` | Resizes uploaded images, such as character portraits, for display. |
| `secrets` | Runs on every `docker compose up`, creates the secret keys if they don't exist yet, then stops. |

Your data lives in three Docker volumes:

| Volume | What it holds |
| --- | --- |
| `db` | The database. |
| `data` | Your uploads and, under `secrets/`, the keys Mythweaver generated. One of them encrypts the API keys of your AI connections. |
| `xi-cache` | Resized copies of images. Safe to lose; they are made again on demand. |

## To start, stop and check on it

Run these in the directory that holds `compose.yml`.

| Command | What it does |
| --- | --- |
| `docker compose up -d` | Starts Mythweaver, or applies changes to `compose.yml` and `.env`. |
| `docker compose stop` | Stops it. Your data stays. |
| `docker compose ps -a` | Shows each service's state. `secrets` showing as exited is normal. |
| `docker compose logs mythweaver` | Shows the app's log. Add `-f` to follow it. |

Mythweaver starts again by itself after a restart of your computer or of Docker, unless you stopped it with `docker compose stop`.

## To upgrade

1. Download the latest compose file over the old one, with the same `curl` command as in [To install](#to-install). Each release's compose file pins that release's version, so this step is what moves you to the new one.
2. Run:
   ```bash
   docker compose pull && docker compose up -d
   ```
   The new version updates the database when it starts.
3. If the release notes say it brings new built-in content (prompts, memory, caption or expression presets), load it:
   ```bash
   docker compose run --rm mythweaver /app/bin/seed
   ```

## To back up

> [!WARNING]
> Back up both the `db` and `data` volumes. If you lose `data`, you lose your uploads and the key that encrypts stored AI API keys, and every saved API key must be entered again.

With Mythweaver running, this saves the database to `mythweaver.sql`:

```bash
docker compose exec db pg_dump -U postgres mythweaver > mythweaver.sql
```

This saves the `data` volume to `data.tar.gz`. Docker names the volume after your directory, so replace `mythweaver` in `mythweaver_data` if your directory has another name:

```bash
docker run --rm -v mythweaver_data:/data -v "$PWD":/backup alpine tar -czf /backup/data.tar.gz -C /data .
```

## Settings

Optional settings go in a file named `.env` beside `compose.yml`, one `NAME=value` per line. Run `docker compose up -d` after changing it.

| Setting | Default | What it does |
| --- | --- | --- |
| `MYTHWEAVER_PORT` | `4000` | The port Mythweaver is served on. With `MYTHWEAVER_PORT=4100`, open http://localhost:4100. |
| `MYTHWEAVER_BIND` | `127.0.0.1` | The address the port is published on. The default allows only this computer. |
| `POSTGRES_PASSWORD` | `mythweaver` | The database password. Set it before the first start: the database keeps the password it was created with. |

For example:

```text
MYTHWEAVER_PORT=4100
POSTGRES_PASSWORD=pick-a-long-random-password
```

> [!NOTE]
> Changing `MYTHWEAVER_BIND` lets other devices reach the port, but they are redirected to HTTPS, which this install doesn't serve. To use Mythweaver from other devices, serve it over HTTPS; see [HTTPS and client IPs](../administration/https-and-proxies.md).

## To uninstall

- `docker compose down` removes the containers and keeps your data in the volumes.
- `docker compose down -v` also deletes the volumes, with every account, chat, upload and key. Back up first if you might want them again.

## Troubleshooting

| Problem | What to do |
| --- | --- |
| `docker compose up -d` says the port is already allocated | Another program uses port 4000. Set `MYTHWEAVER_PORT` to a free port in `.env`. |
| Compose reports an unknown `content` option under `configs` | Your Docker Compose is older than 2.23.1. Update Docker Desktop or the Compose plugin. |
| The page doesn't load right after the first start | The app is still setting up the database. Wait a minute, or watch `docker compose logs -f mythweaver` until it reports that it is running. |
| Pages load but buttons and chats don't respond | Open the site at `http://localhost:` and your port, not `127.0.0.1` or a network name. |
