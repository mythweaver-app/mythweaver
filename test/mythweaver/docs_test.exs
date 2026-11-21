defmodule Mythweaver.DocsTest do
  # Holds `docs/` (the user documentation `docs_site/` publishes) to its layout rules, so a page the
  # site build would reject fails here first. The rules are in AGENTS.md, "User documentation".
  use ExUnit.Case, async: true

  @docs Path.expand("../../docs", __DIR__)
  @front_matter ~r/\A---\r?\n(.*?)\r?\n---\r?\n(.*)\z/s
  @slug ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/
  @scheme ~r/\A[a-z][a-z0-9+.-]*:/i

  defp rel(path), do: Path.relative_to(path, @docs)

  defp pages, do: @docs |> Path.join("**/*.md") |> Path.wildcard() |> Enum.sort()

  defp split!(path) do
    case Regex.run(@front_matter, File.read!(path)) do
      [_, yaml, body] -> {YamlElixir.read_from_string!(yaml), body}
      nil -> flunk("#{rel(path)}: no `---` front matter block")
    end
  end

  defp body_doc(path) do
    {_, body} = split!(path)
    MDEx.parse_document!(body)
  end

  test "front matter has its required keys, with their types, and no others" do
    for path <- pages() do
      {meta, _} = split!(path)
      assert is_map(meta), "#{rel(path)}: front matter is not a map"

      required = if rel(path) == "index.md", do: ~w[title], else: ~w[title order]
      allowed = ["description" | required]

      for key <- required, do: assert(Map.has_key?(meta, key), "#{rel(path)}: missing `#{key}`")

      for key <- Map.keys(meta),
          do: assert(key in allowed, "#{rel(path)}: unknown front matter key `#{key}`")

      assert is_binary(meta["title"]) and meta["title"] != "", "#{rel(path)}: `title` must be a string"

      if "order" in required,
        do: assert(is_integer(meta["order"]), "#{rel(path)}: `order` must be an integer")

      if Map.has_key?(meta, "description"),
        do: assert(is_binary(meta["description"]), "#{rel(path)}: `description` must be a string")
    end
  end

  test "pages sit at the top level or one section deep, with slug names and a section index" do
    for path <- pages() do
      case Path.split(rel(path)) do
        ["index.md"] ->
          :ok

        [section, file] ->
          assert section =~ @slug, "#{rel(path)}: section `#{section}` is not a lowercase slug"
          slug = Path.rootname(file)
          assert slug =~ @slug, "#{rel(path)}: page `#{slug}` is not a lowercase slug"

        _ ->
          flunk("#{rel(path)}: pages must be `index.md` or `<section>/<page>.md`")
      end
    end

    for dir <- @docs |> Path.join("*") |> Path.wildcard(),
        File.dir?(dir),
        dir |> Path.join("*.md") |> Path.wildcard() != [] do
      assert File.exists?(Path.join(dir, "index.md")), "#{rel(dir)}/: section has no index.md"
    end
  end

  test "no page body has an H1 (the layout renders the title)" do
    for path <- pages() do
      {_, headings} =
        MDEx.traverse_and_update(body_doc(path), [], fn
          %MDEx.Heading{level: 1} = node, acc -> {node, [node | acc]}
          node, acc -> {node, acc}
        end)

      assert headings == [], "#{rel(path)}: body has an H1; the front matter title is the page's H1"
    end
  end

  test "relative links and images point at files inside docs/, and none are root-relative" do
    for path <- pages() do
      {_, urls} =
        MDEx.traverse_and_update(body_doc(path), [], fn
          %MDEx.Link{url: url} = node, acc -> {node, [url | acc]}
          %MDEx.Image{url: url} = node, acc -> {node, [url | acc]}
          node, acc -> {node, acc}
        end)

      for url <- urls, not (url =~ @scheme), not String.starts_with?(url, "#") do
        refute String.starts_with?(url, "/"),
               "#{rel(path)}: #{url} is root-relative; link to the `.md` file relatively"

        target = url |> String.split("#", parts: 2) |> hd() |> Path.expand(Path.dirname(path))

        assert String.starts_with?(target, @docs <> "/") and File.regular?(target),
               "#{rel(path)}: broken link #{url}"
      end
    end
  end

  test "the installation page's compose file is deploy/compose.yml" do
    {_, blocks} =
      MDEx.traverse_and_update(body_doc(Path.join(@docs, "administration/installation.md")), [], fn
        %MDEx.CodeBlock{info: "yaml", literal: literal} = node, acc -> {node, [literal | acc]}
        node, acc -> {node, acc}
      end)

    assert blocks == [File.read!(Path.expand("../../deploy/compose.yml", __DIR__))],
           "administration/installation.md must hold exactly one yaml block, a copy of deploy/compose.yml"
  end
end
