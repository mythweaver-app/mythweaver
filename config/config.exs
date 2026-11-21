# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Installation branding, fixed at compile time (`Mythweaver.Branding`): MYTHWEAVER_NAME and
# MYTHWEAVER_LOGO_PATH (an SVG, absolute or relative to the project root; it renders 1em square
# and may use `currentColor`). A blank value counts as unset. Changing either needs a rebuild
# (`mix compile`, `mix assets.deploy`, a new release); `assets/build.ts` names the PWA manifest
# from MYTHWEAVER_NAME by the same rule.
branding_env = fn var, default ->
  case String.trim(System.get_env(var, "")) do
    "" -> default
    value -> value
  end
end

# CLDR data for number, date and list formatting (`Mythweaver.Format`): every "modern"-coverage
# locale, downloaded into `priv/localize/` by `mix localize.download_locales` (`mix setup`, the
# Dockerfile). `default_locale` is the last fallback of `Mythweaver.Locale.resolve/2`.
config :localize, otp_app: :mythweaver, supported_locales: [:modern], default_locale: :en

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# `/import` accepts these in `allow_upload/3`, which needs a known MIME type per extension.
# Changing this list needs `mix deps.compile mime --force`.
config :mime, :types, %{
  "application/jsonl" => ["jsonl"],
  "application/vnd.mythweaver.bundle" => ["mythweaver"],
  "application/x-charx" => ["charx"]
}

# Attachment bytes and image URLs. `config/runtime.exs` overrides these from `MYTHWEAVER_*` env vars
# (see `Mythweaver.Attachments.validate_config!/0` for what each backend needs). `local.root` is
# relative to the working directory. Image links are signed and expire: each is valid for between one
# and two `link_window_seconds` (`Mythweaver.Attachments.url/2`).
config :mythweaver, Mythweaver.Attachments,
  storage: :local,
  proxy: :none,
  max_upload_bytes: 20_000_000,
  link_window_seconds: 86_400,
  local: [root: "priv/uploads"]

config :mythweaver, Mythweaver.Branding,
  name: branding_env.("MYTHWEAVER_NAME", "Mythweaver"),
  # pgvector's `vector` type for lore and message embeddings (`Mythweaver.Lore.Embeddings`).
  logo_path: branding_env.("MYTHWEAVER_LOGO_PATH", "priv/static/images/logo.svg")

# Content moderation (`Mythweaver.Moderation`): how long a held item waits for review, the per-hold and
# per-user caps on held content, how much text a rule scan reads, and the public base URL webhook
# rules' callbacks reach (`MODERATION_CALLBACK_URL`; nil: no callback-mode rules).
config :mythweaver, Mythweaver.Moderation,
  hold_ttl_hours: 168,
  max_hold_bytes: 25 * 1024 * 1024,
  max_user_hold_bytes: 100 * 1024 * 1024,
  max_user_holds: 50,
  max_scan_chars: 200_000,
  callback_url: nil

config :mythweaver, Mythweaver.Repo, types: Mythweaver.PostgrexTypes

# Per-run limits for Lua scripts (`Mythweaver.Scripts.Sandbox`). Each accepts `:infinity` for no
# limit (self-hosted); a hosted deployment may tighten them. CPU time is time on a scheduler, so
# waiting on the database or another process does not count; `max_wall_ms` bounds the waits.
config :mythweaver, Mythweaver.Scripts,
  max_call_depth: 128,
  max_memory_bytes: 32 * 1024 * 1024,
  max_cpu_ms: 5_000,
  max_wall_ms: 10_000

# Configure the endpoint
config :mythweaver, MythweaverWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: MythweaverWeb.ErrorHTML, json: MythweaverWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Mythweaver.PubSub,
  live_view: [signing_salt: "dIXwwx79"]

# Reverse proxies whose `x-forwarded-for` is believed (`MythweaverWeb.ClientIp`), as CIDR strings.
# Set `MYTHWEAVER_TRUSTED_PROXIES` (comma-separated) in production to the proxy's address range.
config :mythweaver, :trusted_proxies, ["127.0.0.0/8", "::1/128"]

# Bypass login on single-user installs (`Mythweaver.Accounts.auto_login_user/0`); on in dev,
# `MYTHWEAVER_AUTO_LOGIN` overrides it at runtime.
config :mythweaver, auto_login: false

# `binary_id: true` drives the `:binary_id` column/`references` types in generated migrations, which is
# correct and stays. It also makes `mix phx.gen.*` emit `@primary_key {:id, :binary_id, autogenerate:
# true}` in a generated *schema*, which is v4. Replace that and `@foreign_key_type` with
# `use Mythweaver.Schema` (UUID v7). There is no generator option for the schema attribute.
config :mythweaver,
  ecto_repos: [Mythweaver.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Configure LiveView
# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
config :phoenix_live_view,
  # The attribute set on all root tags, used by Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

import_config "#{config_env()}.exs"
