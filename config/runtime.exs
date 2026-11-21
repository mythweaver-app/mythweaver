import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/mythweaver start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :mythweaver, MythweaverWeb.Endpoint, server: true
end

config :mythweaver, MythweaverWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Hugging Face token for gated tokenizer repos (meta-llama, google); ungated repos need none.
config :mythweaver, hf_token: System.get_env("HF_TOKEN")

# Where downloaded tokenizer.json files live (default: the OS user cache dir). Never in test:
# the suite wipes its own throwaway cache dir, which must not be a real one.
if config_env() != :test do
  if dir = System.get_env("MYTHWEAVER_TOKENIZER_CACHE"), do: config(:mythweaver, tokenizer_cache_dir: dir)
end

# Auto-login for single-user installs (`Mythweaver.Accounts.auto_login_user/0`). Never in test:
# tests flip it with `Application.put_env/3`.
if config_env() != :test do
  if value = System.get_env("MYTHWEAVER_AUTO_LOGIN"),
    do: config(:mythweaver, auto_login: value in ~w(true 1))
end

# Reverse proxies whose `x-forwarded-for` is believed (`MythweaverWeb.ClientIp`); an empty value
# trusts none. Checked at boot (`ClientIp.validate_config!/0`).
if config_env() != :test do
  if proxies = System.get_env("MYTHWEAVER_TRUSTED_PROXIES") do
    config :mythweaver,
           :trusted_proxies,
           proxies |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end
end

# The public base URL webhook moderation rules call back to (`Mythweaver.Moderation.callback_url/0`).
# Never in test: the suite's own base URL must win.
if config_env() != :test do
  if url = System.get_env("MODERATION_CALLBACK_URL") do
    config :mythweaver, Mythweaver.Moderation, callback_url: url
  end
end

# Where the GeoLite2 databases live (`Mythweaver.Moderation.GeoIP`, `mix mythweaver.geoip.download`);
# `priv/geoip` otherwise. Never in test: the suite's fixture databases must win.
if config_env() != :test do
  if dir = System.get_env("MYTHWEAVER_GEOIP_DIR"), do: config(:mythweaver, :geoip_dir, dir)
end

# Attachment storage and image proxy (`Mythweaver.Attachments`); `validate_config!/0` checks each
# backend's settings at boot. Never in test: the suite's throwaway upload dir must win.
if config_env() != :test do
  storage =
    case System.get_env("MYTHWEAVER_STORAGE", "local") do
      "local" -> :local
      "s3" -> :s3
      other -> raise "MYTHWEAVER_STORAGE must be local or s3, got: #{inspect(other)}"
    end

  proxy =
    case System.get_env("MYTHWEAVER_IMAGE_PROXY", "none") do
      "none" -> :none
      "xtandard" -> :xtandard
      "cloudflare" -> :cloudflare
      "fastly" -> :fastly
      other -> raise "MYTHWEAVER_IMAGE_PROXY must be none, xtandard, cloudflare or fastly, got: #{inspect(other)}"
    end

  uploads_dir = System.get_env("MYTHWEAVER_UPLOADS_DIR")

  if config_env() == :prod and storage == :local and is_nil(uploads_dir) do
    raise """
    environment variable MYTHWEAVER_UPLOADS_DIR is missing.
    Set it to a persistent directory for uploaded images, or set MYTHWEAVER_STORAGE=s3.
    """
  end

  # `BUCKET_NAME` and the `AWS_*` names are what `fly storage create` sets for Tigris.
  config :mythweaver, Mythweaver.Attachments,
    storage: storage,
    proxy: proxy,
    # Cloudflare or Fastly over local storage: the header value the CDN adds to every request it
    # forwards to `/uploads` (`x-mythweaver-origin-secret`); images there need it.
    uploads_origin_secret: System.get_env("MYTHWEAVER_UPLOADS_ORIGIN_SECRET"),
    s3: [
      bucket: System.get_env("MYTHWEAVER_S3_BUCKET") || System.get_env("BUCKET_NAME"),
      region: System.get_env("AWS_REGION", "auto"),
      endpoint_url: System.get_env("AWS_ENDPOINT_URL_S3"),
      access_key_id: System.get_env("AWS_ACCESS_KEY_ID"),
      secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY")
    ],
    xtandard: [
      base_url: System.get_env("MYTHWEAVER_XI_URL"),
      # Where the server itself reaches xi, when that differs from the browser's address
      # (`Mythweaver.Attachments.model_image/1`, `refresh_blurhash/1`). Unset: `base_url`.
      internal_url: System.get_env("MYTHWEAVER_XI_INTERNAL_URL"),
      key: System.get_env("MYTHWEAVER_XI_KEY"),
      salt: System.get_env("MYTHWEAVER_XI_SALT"),
      encryption_key: System.get_env("MYTHWEAVER_XI_ENCRYPTION_KEY"),
      source_prefix: System.get_env("MYTHWEAVER_XI_SOURCE_PREFIX")
    ],
    cloudflare: [zone_url: System.get_env("MYTHWEAVER_CLOUDFLARE_ZONE_URL")],
    fastly: [base_url: System.get_env("MYTHWEAVER_FASTLY_BASE_URL")]

  if uploads_dir, do: config(:mythweaver, Mythweaver.Attachments, local: [root: uploads_dir])

  if max = System.get_env("MYTHWEAVER_MAX_UPLOAD_BYTES"),
    do: config(:mythweaver, Mythweaver.Attachments, max_upload_bytes: String.to_integer(max))

  if window = System.get_env("MYTHWEAVER_IMAGE_LINK_WINDOW"),
    do: config(:mythweaver, Mythweaver.Attachments, link_window_seconds: String.to_integer(window))
end

# Web Push (`Mythweaver.Notifications.WebPush`): VAPID keys from `mix web_push_ex.vapid` and a
# `mailto:`/`https:` subject. Unset: push is off and the app notifies in open tabs only. Never in
# test: tests set the keys themselves.
if config_env() != :test do
  vapid =
    for {key, var} <- [
          public_key: "MYTHWEAVER_VAPID_PUBLIC_KEY",
          private_key: "MYTHWEAVER_VAPID_PRIVATE_KEY",
          subject: "MYTHWEAVER_VAPID_SUBJECT"
        ],
        value = System.get_env(var),
        value not in [nil, ""],
        do: {key, value}

  case length(vapid) do
    0 ->
      :ok

    3 ->
      config(:web_push_ex, :vapid, vapid)

    _ ->
      raise "Web Push needs all of MYTHWEAVER_VAPID_PUBLIC_KEY, MYTHWEAVER_VAPID_PRIVATE_KEY and MYTHWEAVER_VAPID_SUBJECT"
  end
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :mythweaver, MythweaverWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/mythweaver_web/router\.ex$"E,
        ~r"lib/mythweaver_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

# The block below contains prod specific runtime configuration.
if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # A wrong host also breaks LiveView's origin check, so there is no fallback.
  host =
    System.get_env("PHX_HOST") ||
      raise """
      environment variable PHX_HOST is missing.
      Set it to the public host name, e.g. mythweaver.example.org
      """

  # The scheme and port of public links (`url/1`). Plain http works only on localhost:
  # `config/prod.exs`' force_ssl exempts just localhost and 127.0.0.1.
  scheme =
    case System.get_env("PHX_SCHEME", "https") do
      scheme when scheme in ~w(http https) -> scheme
      other -> raise "PHX_SCHEME must be http or https, got: #{inspect(other)}"
    end

  url_port =
    String.to_integer(System.get_env("PHX_URL_PORT") || if(scheme == "https", do: "443", else: "80"))

  config :mythweaver, Mythweaver.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # Encrypts AI connection API keys at rest (`Mythweaver.Vault`). Losing it loses every stored key.
  config :mythweaver, Mythweaver.Vault,
    key:
      System.get_env("MYTHWEAVER_VAULT_KEY") ||
        raise("""
        environment variable MYTHWEAVER_VAULT_KEY is missing.
        Generate one with: openssl rand -base64 32
        """)

  config :mythweaver, MythweaverWeb.Endpoint,
    url: [host: host, port: url_port, scheme: scheme],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  config :mythweaver, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :mythweaver, MythweaverWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :mythweaver, MythweaverWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
