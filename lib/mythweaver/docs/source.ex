defmodule Mythweaver.Docs.Source do
  @moduledoc """
  Reads one `docs/` page for `Mythweaver.Docs` at compile time: its front matter, its body with
  relative `.md` links turned into page ids (`../lore/timing.md#sticky` → `lore/timing#sticky`),
  and its sections, split at every `##`/`###` heading outside fenced code.
  """

  @front_matter ~r/\A---\r?\n(.*?)\r?\n---\r?\n(.*)\z/s
  @md_link ~r/\]\((?![a-z][a-z0-9+.-]*:|#|\/)([^)\s#]+\.md)(#[^)\s]*)?\)/i
  @heading ~r/\A(\#{2,3})\s+(.+?)\s*\z/

  @type section :: %{heading: String.t() | nil, id: String.t() | nil, level: 2 | 3 | nil, text: String.t()}
  @type page :: %{
          id: String.t(),
          title: String.t(),
          description: String.t() | nil,
          body: String.t(),
          sections: [section()]
        }

  @doc "The page at `file` under `root`."
  @spec read!(Path.t(), Path.t()) :: page()
  def read!(root, file) do
    rel = Path.relative_to(file, root)
    [_, yaml, body] = Regex.run(@front_matter, File.read!(file)) || raise "#{rel}: no front matter"
    meta = YamlElixir.read_from_string!(yaml)
    body = body |> String.trim() |> rewrite_links(rel)

    %{
      id: page_id(rel),
      title: meta["title"],
      description: meta["description"],
      body: body,
      sections: sections(body)
    }
  end

  @doc "A page's id: its path under `docs/` without `.md`; a section's `index.md` is the section's name."
  @spec page_id(String.t()) :: String.t()
  def page_id(rel) do
    rel
    |> Path.rootname()
    |> Path.split()
    |> case do
      ["index"] -> "index"
      [section, "index"] -> section
      parts -> Path.join(parts)
    end
  end

  @doc "A heading's anchor, as the docs site makes it: lowercased, punctuation dropped, spaces as `-`."
  @spec slug(String.t()) :: String.t()
  def slug(heading) do
    heading
    |> plain()
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s_-]/u, "")
    |> String.replace(~r/\s/u, "-")
  end

  # A heading's text without inline Markdown: link targets, code and emphasis marks.
  defp plain(text), do: text |> String.replace(~r/\]\([^)]*\)/, "") |> String.replace(~r/[`*\[\]]/, "")

  defp rewrite_links(body, rel) do
    dir = Path.dirname(rel)

    Regex.replace(@md_link, body, fn _, target, fragment ->
      id = target |> Path.expand(Path.join("/", dir)) |> Path.relative_to("/") |> page_id()
      "](#{id}#{fragment})"
    end)
  end

  defp sections(body) do
    {sections, current, _fence?} =
      body
      |> String.split("\n")
      |> Enum.reduce({[], {nil, nil, []}, false}, fn line, {done, {heading, level, lines} = current, fence?} ->
        cond do
          String.starts_with?(line, ["```", "~~~"]) ->
            {done, {heading, level, [line | lines]}, not fence?}

          not fence? and Regex.match?(@heading, line) ->
            [_, hashes, text] = Regex.run(@heading, line)
            {[current | done], {plain(text), String.length(hashes), []}, fence?}

          true ->
            {done, {heading, level, [line | lines]}, fence?}
        end
      end)

    for {heading, level, lines} <- Enum.reverse([current | sections]) do
      %{
        heading: heading,
        id: heading && slug(heading),
        level: level,
        text: lines |> Enum.reverse() |> Enum.join("\n") |> String.trim()
      }
    end
  end
end
