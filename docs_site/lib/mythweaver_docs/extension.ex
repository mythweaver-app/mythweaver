defmodule MythweaverDocs.Extension do
  @moduledoc """
  Loads `docs/` (`MythweaverDocs.Content.load!/1`) into the token as `:docs`, adds one page per
  Markdown file, and after the write adds `search-index.json` and copies the content's assets.
  """

  use Tableau.Extension, key: :docs, priority: 100

  alias MythweaverDocs.Content

  @impl Tableau.Extension
  def pre_build(token) do
    {:ok,
     Map.put(token, :docs, Content.load!(Application.fetch_env!(:mythweaver_docs, :content_dir)))}
  end

  @impl Tableau.Extension
  def pre_render(token) do
    pages =
      for page <- token.docs.reading_order do
        %Tableau.Page{
          parent: MythweaverDocs.DocLayout,
          permalink: page.permalink,
          template: fn _ -> page.html end,
          ext: :md,
          opts: %{
            title: page.title,
            description: page.description,
            permalink: page.permalink,
            docs_page: page
          }
        }
      end

    {:ok, Map.put(token, :graph, Tableau.Graph.insert(token.graph, pages))}
  end

  @impl Tableau.Extension
  def post_write(token) do
    out = token.site.config.out_dir
    dir = Application.fetch_env!(:mythweaver_docs, :content_dir)

    File.write!(
      Path.join(out, "search-index.json"),
      Jason.encode!(Content.search_index(token.docs))
    )

    for rel <- token.docs.assets do
      dest = Path.join(out, rel)
      File.mkdir_p!(Path.dirname(dest))
      File.cp!(Path.join(dir, rel), dest)
    end

    {:ok, token}
  end
end
