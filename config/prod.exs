import Config

# Do not print debug messages in production
config :logger, level: :info

# Use the digested asset manifest produced by `mix phx.digest`
config :mythweaver, MythweaverWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

config :mythweaver, MythweaverWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [
      # paths: ["/health"],
      hosts: ["localhost", "127.0.0.1"]
    ]
  ]

config :mythweaver, secure_cookies: true

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
