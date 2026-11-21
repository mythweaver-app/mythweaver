defmodule MythweaverDocs.Content do
  @moduledoc """
  Loads `docs/` into a `MythweaverDocs.Site`, enforcing its layout rules (AGENTS.md, "User
  documentation"; the app's `test/mythweaver/docs_test.exs` checks the same ones): `index.md` and
  `<section>/<page>.md` only, every section with an `index.md`, front matter `title`, `order`
  (all but the home page) and optional `description` and nothing else, no H1 in a body, and
  relative links. Any violation raises `ArgumentError` naming the file.

  Relative links to `.md` files become the target page's URL, and links to other files the copied
  asset's; a missing target, or a fragment naming no heading of its page, raises.
  """

  alias MythweaverDocs.Page
  alias MythweaverDocs.Section
  alias MythweaverDocs.Site

  @front_matter ~r/\A---\r?\n(.*?)\r?\n---\r?\n(.*)\z/s
  @slug ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/
  @scheme ~r/\A[a-z][a-z0-9+.-]*:/i
  @headings ~w[h1 h2 h3 h4 h5 h6]
  @blocks ~w[p li pre div td th tr blockquote ul ol table dt dd br hr] ++ @headings

  @doc "Loads and renders every page under `dir`."
  @spec load!(Path.t()) :: Site.t()
  def load!(dir) do
    dir = Path.expand(dir)

    {md, assets} =
      dir
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, dir))
      |> Enum.sort()
      |> Enum.split_with(&(Path.extname(&1) == ".md"))

    pages = Enum.map(md, &read!(dir, &1))
    permalinks = Map.new(pages, &{&1.rel_path, &1.permalink})
    asset_set = MapSet.new(assets)

    pages = Enum.map(pages, &render!(&1, permalinks, asset_set))
    check_fragments!(pages)
    by_permalink = Map.new(pages, &{&1.permalink, &1})

    home = by_permalink["/"] || raise ArgumentError, "index.md: the home page is missing"
    sections = sections!(pages)

    %Site{
      home: home,
      sections: sections,
      reading_order: [home | Enum.flat_map(sections, &[&1.index | &1.pages])],
      by_permalink: by_permalink,
      assets: assets
    }
  end

  @doc "The search index: one entry per page intro and per h2/h3 section, in reading order."
  @spec search_index(Site.t()) :: [map()]
  def search_index(%Site{} = site) do
    titles = Map.new(site.sections, &{&1.key, &1.title})

    site.reading_order
    |> Enum.flat_map(fn page -> Enum.map(page.search, &{page, &1}) end)
    |> Enum.with_index(fn {page, entry}, n ->
      %{
        "id" => n,
        "url" => entry.url,
        "page" => page.title,
        # A section's index page is the section itself: no `Section › Section` breadcrumb.
        "section" => if(page.slug, do: titles[page.section]),
        "heading" => entry.heading,
        "text" => entry.text
      }
    end)
  end

  ## Reading

  defp read!(dir, rel) do
    {section, slug, permalink} = place!(rel)
    {meta, body} = front_matter!(rel, File.read!(Path.join(dir, rel)))
    required = if permalink == "/", do: ~w[title], else: ~w[title order]

    for key <- required,
        not Map.has_key?(meta, key),
        do: fail!(rel, "missing front matter `#{key}`")

    for key <- Map.keys(meta),
        key not in ["description" | required],
        do: fail!(rel, "unknown front matter key `#{key}`")

    unless is_binary(meta["title"]) and meta["title"] != "",
      do: fail!(rel, "`title` must be a string")

    if "order" in required and not is_integer(meta["order"]),
      do: fail!(rel, "`order` must be an integer")

    unless is_nil(meta["description"]) or is_binary(meta["description"]),
      do: fail!(rel, "`description` must be a string")

    %Page{
      source: body,
      rel_path: rel,
      section: section,
      slug: slug,
      permalink: permalink,
      title: meta["title"],
      description: meta["description"],
      order: meta["order"]
    }
  end

  defp place!(rel) do
    case Path.split(rel) do
      ["index.md"] ->
        {nil, nil, "/"}

      [section, "index.md"] ->
        slug!(rel, section)
        {section, nil, "/#{section}/"}

      [section, file] ->
        slug!(rel, section)
        slug = slug!(rel, Path.rootname(file))
        {section, slug, "/#{section}/#{slug}/"}

      _ ->
        fail!(rel, "pages must be `index.md` or `<section>/<page>.md`")
    end
  end

  defp slug!(rel, name) do
    if name =~ @slug, do: name, else: fail!(rel, "`#{name}` is not a lowercase slug")
  end

  defp front_matter!(rel, text) do
    with [_, yaml, body] <- Regex.run(@front_matter, text),
         {:ok, %{} = meta} <- YamlElixir.read_from_string(yaml) do
      {meta, body}
    else
      _ -> fail!(rel, "needs a `---` YAML front matter block holding a map")
    end
  end

  ## Rendering

  defp render!(%Page{} = page, permalinks, assets) do
    opts = Application.fetch_env!(:mythweaver_docs, :markdown)
    doc = MDEx.parse_document!(page.source, opts)

    {doc, links} =
      MDEx.traverse_and_update(doc, [], fn
        %MDEx.Heading{level: 1} = node, _acc ->
          fail!(page.rel_path, "has an H1; the front matter `title` is the page's H1")
          {node, []}

        %struct{url: url} = node, acc when struct in [MDEx.Link, MDEx.Image] ->
          {url, link} = rewrite!(page, url, permalinks, assets)
          {%{node | url: url}, if(link, do: [link | acc], else: acc)}

        node, acc ->
          {node, acc}
      end)

    html = MDEx.to_html!(doc, opts)
    nodes = html |> LazyHTML.from_fragment() |> LazyHTML.to_tree()

    %{page | html: html, links: Enum.reverse(links), toc: toc(nodes), search: search(page, nodes)}
  end

  defp rewrite!(page, url, permalinks, assets) do
    cond do
      url =~ @scheme ->
        {url, nil}

      String.starts_with?(url, "#") ->
        {url, {page.permalink, String.trim_leading(url, "#")}}

      String.starts_with?(url, "/") ->
        fail!(page.rel_path, "root-relative link #{url}; link to the file relatively")

      true ->
        {target, fragment} =
          case String.split(url, "#", parts: 2) do
            [target, fragment] -> {target, fragment}
            [target] -> {target, nil}
          end

        resolved =
          target
          |> Path.expand(Path.join("/", Path.dirname(page.rel_path)))
          |> Path.relative_to("/")

        suffix = if fragment, do: "#" <> fragment, else: ""

        cond do
          Map.has_key?(permalinks, resolved) ->
            permalink = permalinks[resolved]
            {MythweaverDocs.path(permalink) <> suffix, fragment && {permalink, fragment}}

          MapSet.member?(assets, resolved) ->
            {MythweaverDocs.path("/" <> resolved) <> suffix, nil}

          true ->
            fail!(page.rel_path, "broken link #{url}")
        end
    end
  end

  defp check_fragments!(pages) do
    ids = Map.new(pages, &{&1.permalink, heading_ids(&1.html)})

    for page <- pages, {permalink, fragment} <- page.links, fragment not in ids[permalink] do
      fail!(page.rel_path, "link to #{permalink}##{fragment} has no such heading")
    end
  end

  defp heading_ids(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(Enum.join(@headings, ","))
    |> Enum.flat_map(&heading_id/1)
    |> MapSet.new()
  end

  # comrak puts the id on the heading; older versions put it on the inner `a.anchor`.
  defp heading_id(%LazyHTML{} = node) do
    case LazyHTML.attribute(node, "id") do
      [id] -> [id]
      [] -> node |> LazyHTML.query("[id]") |> LazyHTML.attribute("id") |> Enum.take(1)
    end
  end

  defp tree_id({_tag, attrs, children}) do
    case List.keyfind(attrs, "id", 0) do
      {"id", id} -> id
      nil -> Enum.find_value(children, &(is_tuple(&1) and tuple_size(&1) == 3 and tree_id(&1)))
    end
  end

  ## TOC and search

  defp toc(nodes) do
    for {tag, _, _} = node <- nodes, tag in ~w[h2 h3] do
      %{level: if(tag == "h2", do: 2, else: 3), id: tree_id(node), text: text([node])}
    end
  end

  defp search(page, nodes) do
    url = MythweaverDocs.path(page.permalink)

    {intro, sections} =
      Enum.reduce(nodes, {[], []}, fn
        {tag, _, _} = node, {intro, sections} when tag in ~w[h2 h3] ->
          {intro, [{node, []} | sections]}

        node, {intro, []} ->
          {[node | intro], []}

        node, {intro, [{heading, body} | rest]} ->
          {intro, [{heading, [node | body]} | rest]}
      end)

    [
      %{heading: nil, url: url, text: text(Enum.reverse(intro))}
      | sections
        |> Enum.reverse()
        |> Enum.map(fn {heading, body} ->
          %{
            heading: text([heading]),
            url: url <> "#" <> tree_id(heading),
            text: text(Enum.reverse(body))
          }
        end)
    ]
  end

  defp text(nodes), do: nodes |> Enum.map(&node_text/1) |> IO.iodata_to_binary() |> collapse()

  defp node_text(text) when is_binary(text), do: text

  defp node_text({tag, _, children}) when tag in @blocks,
    do: [" ", Enum.map(children, &node_text/1), " "]

  defp node_text({_tag, _, children}), do: Enum.map(children, &node_text/1)
  defp node_text(_comment), do: []

  defp collapse(text), do: text |> String.split() |> Enum.join(" ")

  ## Sections

  defp sections!(pages) do
    pages
    |> Enum.reject(&is_nil(&1.section))
    |> Enum.group_by(& &1.section)
    |> Enum.map(fn {key, pages} ->
      {[index], pages} = Enum.split_with(pages, &is_nil(&1.slug)) |> require_index!(key)

      %Section{
        key: key,
        title: index.title,
        order: index.order,
        index: index,
        pages: Enum.sort_by(pages, &{&1.order, &1.title})
      }
    end)
    |> Enum.sort_by(&{&1.order, &1.title})
  end

  defp require_index!({[], _}, key), do: fail!("#{key}/", "the section has no index.md")
  defp require_index!(split, _key), do: split

  @spec fail!(String.t(), String.t()) :: no_return()
  defp fail!(rel, problem), do: raise(ArgumentError, "#{rel}: #{problem}")
end
