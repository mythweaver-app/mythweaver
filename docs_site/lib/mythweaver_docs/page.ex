defmodule MythweaverDocs.Page do
  @moduledoc """
  One Markdown file of `docs/`, rendered. `toc` lists its h2/h3 headings, `search` its search
  index entries, and `links` the `{permalink, fragment}` of every link to a page.
  """

  @type t :: %__MODULE__{}

  defstruct [
    :source,
    :rel_path,
    :section,
    :slug,
    :permalink,
    :title,
    :description,
    :order,
    :html,
    toc: [],
    search: [],
    links: []
  ]
end
