# Mythweaver

Mythweaver is a self-hosted app for AI role-play, in the vein of
[SillyTavern](https://docs.sillytavern.app). You can run group chats with several characters, give
them lore books, memory and prompt templates, and connect any OpenAI-compatible model provider,
local or hosted.

## Install

You need Docker with Docker Compose 2.23.1 or newer.

1. Make an empty directory and download the compose file into it:
   ```bash
   mkdir mythweaver && cd mythweaver
   curl -LO https://github.com/mythweaver-app/mythweaver/releases/latest/download/compose.yml
   ```
2. Start it:
   ```bash
   docker compose up -d
   ```
3. Open http://localhost:4000 and create the owner account. Whoever finishes this page first
   becomes the owner, so do it before anyone else can reach the site.

On the first start Mythweaver creates its database, generates its secrets and loads the built-in
prompts. After that, connect a model in the app and start a chat.

The downloaded `compose.yml` pins the release it came from. To upgrade, download the latest one
over it with the same `curl` command, then run `docker compose pull && docker compose up -d` in
the same directory. The new version migrates the database when it starts.

> [!WARNING]
> Back up the `data` and `db` volumes. `data` holds your uploads and the key that encrypts
> stored AI API keys; if you lose it, every saved API key must be entered again.

The compose file serves plain http, which works only on `localhost`. To reach Mythweaver from
other devices over HTTPS, or to install it without Docker (a Linux release tarball, or from
source), see [Installation](docs/administration/installation.md).

## Documentation

The published documentation site is coming soon. Until then, the pages are in [`docs/`](docs/);
start with [Installation](docs/administration/installation.md) and
[Environment variables](docs/administration/configuration.md).

## Development

The repo ships a dev container (`.devcontainer/`) that installs Erlang, Elixir, bun, oxfmt and
oxlint with [mise](https://mise.jdx.dev) and runs Postgres 18 beside it. The host needs only a
container runtime: Docker Desktop, or a `docker`/`podman` binary on `PATH` (Zed).

1. Open the container:
   - **VS Code / Cursor:** _Dev Containers: Reopen in Container_.
   - **Zed:** accept the dev-container prompt, or _Project: Open Remote_ →
     _Connect Dev Container_.
2. Wait for `postCreateCommand` to finish. It installs the tools and runs `mix setup` (deps,
   database create/migrate, seeds). The seeds load only built-in content; `mix ecto.reset.dev`
   replaces chats and characters with a sample cast and chat.
3. Start the server inside the container and browse
   [`localhost:4000`](http://localhost:4000):
   ```
   sudo chown -R vscode:vscode deps && sudo chown -R vscode:vscode _build && cd assets && sudo chown -R vscode:vscode node_modules && cd ..
   mix ecto.reset
   mix phx.server
   ```

After the first run, start it with:
```
iex -S mix phx.server
```

Inside the container, live reload and asset rebuilds poll for changes (`FILE_WATCHER_POLL=true`)
because bind mounts don't forward host inotify events. The endpoint binds `0.0.0.0` there
(`PHX_BIND_ALL=true`), and the database host comes from `DATABASE_HOST=db`. Unset, all three fall
back to host-native behavior.

Zed doesn't rebuild the container when `devcontainer.json` changes. Stop it yourself
(`docker compose -p <project>_devcontainer down`) before reopening.

On Windows, Docker Desktop must use the WSL2 backend. Three more things can bite:

- Git on Windows defaults to `core.autocrlf=true`, which checks the container's shell scripts out
  with CRLF line endings and breaks provisioning. The repo's `.gitattributes` pins LF, but a clone
  made before that file existed still has CRLF: run `git config --global core.autocrlf false`,
  then re-clone (or `git add --renormalize .`).
- Clone into the WSL2 filesystem (for example under `\\wsl$\Ubuntu\home\<user>`), not an NTFS
  path such as `C:\Users\...`. The workspace bind mount is much slower across the NTFS boundary.
  `_build`, `deps` and `assets/node_modules` are already named volumes, so only the source tree
  pays that cost.
- A devcontainer attempt that failed during `postCreateCommand` leaves root-owned named volumes
  behind, and Docker never re-seeds a volume that already exists. After pulling this fix, run
  _Dev Containers: Rebuild Container_. If mise or deps permission errors persist, remove the stale
  volumes with `docker compose -p <project>_devcontainer down -v` and reopen.

You can also develop without the container: `docker compose up -d` for Postgres and the image
proxy, then `mise install && mix setup && mix phx.server`.

### Images in development

Local development puts xi behind nginx (`docker/nginx.conf.template`), which serves the app at `/`
and xi at `/img/` on one origin. Image links are therefore relative and load from any device that
can reach it. Open the app at http://localhost:4080 (the dev container: 4081), not Phoenix's 4000,
or images won't load.

`mise.toml` sets the proxy variables for host-native runs (started by `docker compose up -d`), and
the dev container's `containerEnv` sets them for its own. A value already in the environment wins
over mise's. To run without the proxy, export `MYTHWEAVER_IMAGE_PROXY=none`. The dev keys are
public; a real deployment generates its own (`openssl rand -hex 32`, three times) and sets the
rest itself.

xi caches nothing itself. Each thumbnail is resized once per format (AVIF, WebP or original) per
link window and then served from the `xi-cache` volume. The `X-Cache-Status` response header shows
`HIT` or `MISS`.

To reach the dev server from other devices (a LAN or a tailnet), publish nginx beyond loopback
before `docker compose up -d`, then open `http://<host>:4080`; Phoenix stays on loopback. Either
set `MYTHWEAVER_NGINX_BIND=0.0.0.0` (every interface, in the shell or a git-ignored `.env`), or
keep the default and list specific addresses (e.g. `tailscale ip -4`, the LAN one) in a git-ignored
`compose.override.yml`, as `compose.yml` shows. Don't do both. `0.0.0.0` includes any untrusted
network the machine joins, and dev runs with a public secret key base and, on single-user
installs, auto-login.
