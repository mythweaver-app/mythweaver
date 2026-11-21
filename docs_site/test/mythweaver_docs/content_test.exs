defmodule MythweaverDocs.ContentTest do
  use ExUnit.Case, async: false

  alias MythweaverDocs.Content

  setup do
    dir = Path.join(System.tmp_dir!(), "mythweaver-docs-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp tree!(dir, files) do
    files = Map.merge(%{"index.md" => "---\ntitle: Home\n---\n\nHome.\n"}, files)

    for {rel, text} <- files do
      path = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, text)
    end

    dir
  end

  defp page(title, order, body \\ ""),
    do: "---\ntitle: #{title}\norder: #{order}\n---\n\n#{body}\n"

  defp linked(dir) do
    tree!(dir, %{
      "getting-started/index.md" => page("Getting started", 1),
      "getting-started/a.md" => page("A", 1, "See [e](../lore/entries.md#sticky)."),
      "lore/index.md" => page("Lore", 2),
      "lore/entries.md" => page("Entries", 1, "## Sticky\n\nStays.")
    })
  end

  test "relative .md links become page URLs under the base path", %{dir: dir} do
    dir = linked(dir)

    assert Content.load!(dir).by_permalink["/getting-started/a/"].html =~
             ~s(href="/lore/entries/#sticky")

    config = Application.fetch_env!(:tableau, :config)
    on_exit(fn -> Application.put_env(:tableau, :config, config) end)
    Application.put_env(:tableau, :config, Keyword.put(config, :base_path, "/mythweaver"))

    assert Content.load!(dir).by_permalink["/getting-started/a/"].html =~
             ~s(href="/mythweaver/lore/entries/#sticky")
  end

  test "a link to a missing file raises naming the file and the URL", %{dir: dir} do
    tree!(dir, %{"s/index.md" => page("S", 1, "[x](missing.md)")})

    assert_raise ArgumentError, ~r{s/index\.md.*missing\.md}, fn -> Content.load!(dir) end
  end

  test "a fragment naming no heading of its page raises", %{dir: dir} do
    tree!(dir, %{
      "s/index.md" => page("S", 1, "[x](a.md#nope)"),
      "s/a.md" => page("A", 1, "## Yes")
    })

    assert_raise ArgumentError, ~r{s/index\.md: link to /s/a/#nope has no such heading}, fn ->
      Content.load!(dir)
    end
  end

  test "an intro and h2/h3 sections become search entries and the TOC", %{dir: dir} do
    tree!(dir, %{
      "s/index.md" => page("S", 1),
      "s/p.md" => page("P", 1, "Intro.\n\n## One\n\nFirst.\n\n### Two\n\nSecond.")
    })

    page = Content.load!(dir).by_permalink["/s/p/"]

    assert Enum.map(page.search, & &1.url) == ["/s/p/", "/s/p/#one", "/s/p/#two"]
    assert Enum.map(page.search, & &1.text) == ["Intro.", "First.", "Second."]
    assert [%{level: 2, id: "one", text: "One"}, %{level: 3, id: "two", text: "Two"}] = page.toc
  end

  test "sections sort by order, pages by order then title", %{dir: dir} do
    tree!(dir, %{
      "b/index.md" => page("B", 2),
      "a/index.md" => page("A", 1),
      "a/z.md" => page("Zed", 1),
      "a/y.md" => page("Yak", 2),
      "a/x.md" => page("Alpha", 1)
    })

    site = Content.load!(dir)

    assert Enum.map(site.sections, & &1.key) == ["a", "b"]
    assert Enum.map(hd(site.sections).pages, & &1.title) == ["Alpha", "Zed", "Yak"]

    assert Enum.map(site.reading_order, & &1.permalink) == [
             "/",
             "/a/",
             "/a/x/",
             "/a/z/",
             "/a/y/",
             "/b/"
           ]
  end

  test "an unknown front matter key raises", %{dir: dir} do
    tree!(dir, %{"s/index.md" => "---\ntitle: S\norder: 1\ntitel: typo\n---\n"})

    assert_raise ArgumentError, ~r{s/index\.md: unknown front matter key `titel`}, fn ->
      Content.load!(dir)
    end
  end
end
