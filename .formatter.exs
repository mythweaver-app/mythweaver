Code.require_file("priv/formatter/js_and_css_formatter.ex")

[
  import_deps: [:ecto, :ecto_sql, :phoenix],
  subdirectories: ["priv/*/migrations"],
  plugins: [Phoenix.LiveView.HTMLFormatter, Quokka],
  # Config sorting moves comments away from the calls they describe.
  quokka: [exclude: [:configs]],
  tag_formatters: %{script: JsAndCssFormatter, style: JsAndCssFormatter},
  inputs: ["*.{heex,ex,exs}", "{config,lib,test}/**/*.{heex,ex,exs}", "priv/*/{seeds,dev_seeds}.exs"]
]
