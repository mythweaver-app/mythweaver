import Config

alias Mythweaver.AI.HuggingFace
alias Mythweaver.Attachments.Proxy
alias Mythweaver.Attachments.Storage.S3
alias Mythweaver.Moderation.GeoIP
alias Mythweaver.Notifications.WebPush

# Cheap password hashing; tests flip `:auto_login` with `Application.put_env/3`.
config :bcrypt_elixir, :log_rounds, 1

# Print only warnings and errors during test
config :logger, level: :warning

# Attachments land in a throwaway dir; S3 calls go through the same `Req.Test` seam.
config :mythweaver, Mythweaver.Attachments, local: [root: Path.join(System.tmp_dir!(), "mythweaver-uploads-test")]

# Tests assert the stock branding whatever MYTHWEAVER_NAME/MYTHWEAVER_LOGO_PATH the shell sets.
config :mythweaver, Mythweaver.Branding, name: "Mythweaver", logo_path: "priv/static/images/logo.svg"
config :mythweaver, Mythweaver.Moderation, callback_url: "http://localhost:4002"

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :mythweaver, Mythweaver.Repo,
  username: "postgres",
  password: "postgres",
  hostname: System.get_env("DATABASE_HOST", "localhost"),
  database: "mythweaver_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Dev-only, public key: test rows are throwaway.
config :mythweaver, Mythweaver.Vault, key: "4tFezsLU52yHzbmqQEAYPcqnT8kFoRqoH82MokVirLg="

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :mythweaver, MythweaverWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "kJq28SBeHThsxjKaEll06N5NjyoKWG1lbeS8m+G63XPaSz7PpjQRzw8bbtTPY+vn",
  server: false

# No background blurhash task outlives a test's sandbox; tests call `Attachments.refresh_blurhash/1`.
config :mythweaver, :attachment_blurhash_in_background, false

# Classifier-model expressions run in the caller, so no task outlives a test's sandbox.
config :mythweaver, :expressions_in_background, false

# MaxMind's public GeoLite2 test databases (`Mythweaver.Moderation.GeoIP`), and the download
# task's `Req.Test` seam (`mix mythweaver.geoip.download`).
config :mythweaver, :geoip_dir, Path.expand("../test/fixtures/geoip", __DIR__)

# No background embedding task outlives a test's sandbox; tests call `Lore.Embeddings` directly.
config :mythweaver, :lore_embeddings_in_background, false

# No background cleanup task outlives a test's sandbox; tests call `Messages.Cleanup` directly.
config :mythweaver, :message_cleanup_in_background, false

# Content moderation scans run in the caller, so no task outlives a test's sandbox; webhook rules go
# through a `Req.Test` seam, and callback-mode rules have a base URL.
config :mythweaver, :moderation_in_background, false

# The daily fingerprint prune would race the SQL sandbox; tests call `Fingerprints.prune/1`.
config :mythweaver, :moderation_pruner, false

# `Req.Test` seam for `Mythweaver.AI` adapters: no AI request leaves the test suite.
config :mythweaver, ai_req_options: [plug: {Req.Test, Mythweaver.AI}]
config :mythweaver, attachments_req_options: [plug: {Req.Test, S3}]

# A reply waiting on captions rechecks them quickly, so a deleted image releases it within a test.
config :mythweaver, caption_recheck_ms: 50

# The boot sweep of stranded `generating` bodies would race the SQL sandbox.
config :mythweaver, finalize_interrupted_bodies_on_boot: false
config :mythweaver, geoip_req_options: [plug: {Req.Test, GeoIP}]

# The same `Req.Test` seam for `Mythweaver.Tokenizer` downloads, with a throwaway disk cache.
config :mythweaver,
  hf_req_options: [plug: {Req.Test, HuggingFace}],
  tokenizer_cache_dir: Path.join(System.tmp_dir!(), "mythweaver-tokenizers-test")

# Images fetched from the image proxy for vision-model prompts (`Attachments.model_image/1`).
config :mythweaver, image_proxy_req_options: [plug: {Req.Test, Proxy}]

# The job scheduler's token watchdog ticks fast, so 50 ms first-token/idle timeouts finish quickly.
config :mythweaver, jobs_watchdog_ms: 10
config :mythweaver, moderation_req_options: [plug: {Req.Test, Mythweaver.Moderation}]
config :mythweaver, push_req_options: [plug: {Req.Test, WebPush}]
config :mythweaver, remote_image_req_options: [plug: {Req.Test, MythweaverWeb.RemoteImageController}]

# Buffered writes never fire on their own in tests; tests flush explicitly.
config :mythweaver, write_debounce_ms: 3_600_000

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
