defmodule MythweaverDocs.MixProject do
  use Mix.Project

  def project do
    [
      app: :mythweaver_docs,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      compilers: Mix.compilers() ++ [:iconex],
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp aliases do
    [build: [&clean_site/1, "tableau.build", "cmd --cd assets bun run build.ts"]]
  end

  defp clean_site(_), do: File.rm_rf!("_site")

  defp deps do
    [
      {:tableau, "~> 0.31.0"},
      {:tableau_dev_server, "~> 0.1.0", only: :dev},
      {:phoenix_live_view, "~> 1.2"},
      {:mdex, "~> 0.14.7"},
      {:lumis, "~> 0.10.9"},
      {:lumis_wasm_liquid, "~> 0.26"},
      {:lumis_wasm_lua, "~> 0.26"},
      {:lumis_wasm_json, "~> 0.26"},
      {:lumis_wasm_bash, "~> 0.26"},
      {:lumis_wasm_yaml, "~> 0.26"},
      {:lumis_wasm_css, "~> 0.26"},
      {:lumis_wasm_html, "~> 0.26"},
      {:lumis_wasm_javascript, "~> 0.26"},
      {:lumis_wasm_markdown, "~> 0.26"},
      {:lumis_wasm_comment, "~> 0.26"},
      {:iconex, "~> 0.1.0"},
      {:lazy_html, "~> 0.1.13"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"}
    ]
  end
end
