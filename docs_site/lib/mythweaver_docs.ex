defmodule MythweaverDocs do
  @moduledoc """
  The Mythweaver user documentation site: `docs/` (in the app's repository) rendered by Tableau.
  `MythweaverDocs.Content` loads and checks the Markdown, `MythweaverDocs.Extension` turns it into
  pages, and the layouts render them.
  """

  @doc """
  The site-relative URL of `permalink` under the configured base path (`""` locally,
  `"/mythweaver"` on GitHub Pages). Every internal href and src goes through it.
  """
  @spec path(String.t()) :: String.t()
  def path("/" <> _ = permalink), do: base_path() <> permalink

  @doc "The configured base path, without a trailing slash (`\"\"` for the root)."
  @spec base_path() :: String.t()
  def base_path, do: Application.fetch_env!(:tableau, :config)[:base_path] || ""
end
