defmodule Mythweaver.MixProject do
  use Mix.Project

  def project do
    [
      app: :mythweaver,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers() ++ [:iconex],
      listeners: [Phoenix.CodeReloader],
      releases: [mythweaver: [include_executables_for: [:unix]]],
      # References without line numbers, so `gettext.extract --check-up-to-date` fails only when a
      # msgid changes, not when code moves.
      gettext: [write_reference_line_numbers: false],
      # Advisories with no fixed release that don't reach this app: `Mythweaver.Vault` uses only
      # Cloak's AES-GCM cipher (not AES-CTR), and no schema uses a Cloak.Ecto PBKDF2 field.
      hex: [ignore_advisories: ["EEF-CVE-2026-95105", "EEF-CVE-2026-94206"]]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Mythweaver.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    # quokka:sort
    [
      {:bandit, "~> 1.13"},
      {:bcrypt_elixir, "~> 3.3"},
      {:cloak, "~> 1.1"},
      {:cloak_ecto, "~> 1.3"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dns_cluster, "~> 0.3.1"},
      {:ecto_sql, "~> 3.14"},
      {:ex_pdf_read, "~> 1.0"},
      {:exqlite, "~> 0.43"},
      {:finch, "~> 0.24"},
      {:gettext, "~> 1.0"},
      {:iconex, "~> 0.1.0"},
      {:igniter, "~> 0.8.4", only: [:dev, :test]},
      {:jason, "~> 1.4"},
      {:lazy_html, "~> 0.1.13", only: :test},
      {:localize, "~> 1.8"},
      {:localize_web, "~> 1.3"},
      {:locus, "~> 2.3"},
      {:lua, "~> 1.0"},
      {:mdex, "~> 0.14"},
      {:mdex_katex, "~> 0.3"},
      {:mint, "~> 1.11"},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:pgvector, "~> 0.4"},
      {:phoenix, "~> 1.8.16"},
      {:phoenix_bun_assets, "~> 0.1", only: [:dev, :test], runtime: false},
      {:phoenix_ecto, "~> 4.7"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_live_dashboard, "~> 0.9.1"},
      {:phoenix_live_reload, "~> 1.7", only: :dev},
      {:phoenix_live_view, "~> 1.2.13"},
      {:postgrex, "~> 0.22"},
      {:quokka, "~> 2.13", only: [:dev, :test], runtime: false},
      {:req, "~> 0.7.5"},
      {:req_s3, "~> 0.2.5"},
      {:solid, "~> 1.3"},
      {:telemetry_metrics, "~> 1.2"},
      {:telemetry_poller, "~> 1.3"},
      {:tokenizers, "~> 0.5"},
      {:web_push_ex, "~> 0.2.0"},
      {:yaml_elixir, "~> 2.12"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "localize.download_locales", "ecto.setup", "mythweaver.geoip.download"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      # Destructive sample data for development (`priv/repo/dev_seeds.exs`); never on a real install.
      "ecto.setup.dev": ["ecto.create", "ecto.migrate", "run priv/repo/dev_seeds.exs"],
      "ecto.reset.dev": ["ecto.drop", "ecto.setup.dev"],
      # Needs the network, so it stays out of `precommit`.
      audit: ["deps.audit", "hex.audit"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      precommit: [
        "compile --warnings-as-errors",
        # Its own build dir: the extractor force-recompiles with consolidated protocols, which
        # would break the next compile in `_build/test`.
        "cmd env MIX_ENV=test MIX_BUILD_PATH=_build/gettext mix gettext.extract --check-up-to-date",
        "cmd mise exec oxlint -- oxlint --deny-warnings assets/js _build/test/phoenix-colocated/mythweaver",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "test"
      ],
      "assets.build": ["compile", "cmd --cd assets bun run build.ts"],
      "assets.deploy": ["compile", "cmd --cd assets bun run build.ts deploy", "phx.digest"]
    ]
  end
end
