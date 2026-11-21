import Config

config :mdex_native, syntax_highlighter: :lumis

config :tableau, :config,
  url: System.get_env("MYTHWEAVER_DOCS_URL", "http://localhost:4999"),
  base_path: "MYTHWEAVER_DOCS_BASE_PATH" |> System.get_env("") |> String.trim_trailing("/"),
  include_dir: "extra",
  out_dir: "_site"

for ext <- [
      Tableau.PageExtension,
      Tableau.PostExtension,
      Tableau.DataExtension,
      Tableau.TagExtension,
      Tableau.RSSExtension,
      Tableau.SitemapExtension
    ],
    do: config(:tableau, ext, enabled: false)

config :mythweaver_docs, content_dir: Path.expand("../../docs", __DIR__)

config :mythweaver_docs, :markdown,
  extension: [
    table: true,
    strikethrough: true,
    autolink: true,
    tasklist: true,
    footnotes: true,
    alerts: true,
    header_id_prefix: ""
  ],
  render: [unsafe: true],
  syntax_highlight: [engine: :lumis, opts: [formatter: :html_linked]]

config :iconex, sets: [:lucide], delivery: :inline, otp_app: :mythweaver_docs

import_config "#{config_env()}.exs"
