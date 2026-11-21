import Config

config :tableau, :reloader,
  patterns: [~r"^lib/.*\.ex$", ~r"^_site/(css|js)/", ~r"^_site/\.content-changed$"]

config :tableau, :assets,
  bun: ["run", "build.ts", "--watch", cd: Path.expand("../assets", __DIR__)]
