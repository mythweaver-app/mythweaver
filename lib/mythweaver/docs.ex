defmodule Mythweaver.Docs do
  @moduledoc """
  The user documentation (`docs/`, which `docs_site/` publishes) compiled into the app, so the
  assistant can answer "how do I…" questions from it (`Mythweaver.Assistant.Tools.Docs`).

  A page's id is its path under `docs/` without `.md` (`lore/timing`; a section's `index.md` is the
  section, `lore`; the home page is `index`). Links between pages in a page's Markdown are page ids
  too (`lore/timing#sticky`). Each page is split into sections at its `##`/`###` headings; the text
  before the first heading is a section with no heading.

  Adding, removing or editing a page recompiles this module.
  """

  alias Mythweaver.Docs.Source

  @root Path.expand("../../docs", __DIR__)
  @files @root |> Path.join("**/*.md") |> Path.wildcard() |> Enum.sort()

  for file <- @files, do: @external_resource(file)

  # Pages in reading order: home, then each section's index followed by its pages, by file name.
  @pages @files
         |> Enum.map(&Source.read!(@root, &1))
         |> Enum.sort_by(fn
           %{id: "index"} -> {"", 0, ""}
           %{id: id} -> {id |> String.split("/") |> hd(), if(String.contains?(id, "/"), do: 1, else: 0), id}
         end)

  @stopwords ~w[a an the to how do does i in of for and or is it my me can what with on at be by this that]

  @doc false
  def __mix_recompile__?, do: @root |> Path.join("**/*.md") |> Path.wildcard() |> Enum.sort() != @files

  @doc "Every page, home first: `%{id, title, description}`."
  @spec list() :: [%{id: String.t(), title: String.t(), description: String.t() | nil}]
  def list, do: Enum.map(pages(), &Map.take(&1, [:id, :title, :description]))

  @doc """
  The page `ref` names, and its section when `ref` carries one (`lore/timing#sticky`) or `section`
  is given (a heading's text or anchor). Accepts `lore/timing`, `lore/timing.md` and `/lore/timing/`.
  A section runs from its heading to the next heading of the same or a higher level.
  """
  @spec get(String.t(), String.t() | nil) ::
          {:ok, Source.page(), Source.section() | nil} | {:error, :not_found | :no_section}
  def get(ref, section \\ nil) do
    {id, fragment} = parse_ref(ref)

    case Enum.find(pages(), &(&1.id == id)) do
      nil -> {:error, :not_found}
      page -> with_section(page, blank_to_nil(section) || fragment)
    end
  end

  @doc """
  Sections matching `query`, best first, at most `limit`. Each query word (short and common words
  dropped) scores in a section's heading, its page's title and id, and its text, heading over title
  over text, weighted by how few sections hold it, so a rare word ("sticky") outranks common ones
  ("lore", "entry"); a section holding more of the words ranks higher.
  """
  @spec search(String.t(), pos_integer()) :: [%{page: Source.page(), section: Source.section(), snippet: String.t()}]
  def search(query, limit) do
    case terms(query) do
      [] -> []
      terms -> rank(terms, limit)
    end
  end

  defp rank(terms, limit) do
    docs =
      for page <- pages(), section <- page.sections do
        {page, section, String.downcase(page.title <> " " <> page.id), String.downcase(section.heading || ""),
         String.downcase(section.text)}
      end

    weights = Map.new(terms, &{&1, weight(docs, &1)})

    docs
    |> Enum.map(fn {page, section, _, _, _} = doc -> {score(doc, terms, weights), page, section} end)
    |> Enum.filter(fn {score, _, _} -> score > 0 end)
    |> Enum.sort_by(fn {score, _, _} -> -score end)
    |> Enum.take(limit)
    |> Enum.map(fn {_, page, section} -> %{page: page, section: section, snippet: snippet(section.text, terms)} end)
  end

  # The one place the embedded pages are read, so they are compiled in once.
  defp pages, do: @pages

  defp parse_ref(ref) do
    {path, fragment} =
      ref
      |> String.trim()
      |> String.split("#", parts: 2)
      |> case do
        [path, fragment] -> {path, blank_to_nil(fragment)}
        [path] -> {path, nil}
      end

    path = path |> String.replace(~r{\A(\.\.?/)+}, "") |> String.trim("/") |> String.replace_suffix(".md", "")
    {if(path == "", do: "index", else: Source.page_id(path <> ".md")), fragment}
  end

  defp with_section(page, nil), do: {:ok, page, nil}

  defp with_section(page, wanted) do
    key = String.downcase(String.trim(wanted))
    other? = &(&1.heading == nil or (&1.id != key and String.downcase(&1.heading) != key))

    case Enum.split_while(page.sections, other?) do
      {_, []} ->
        {:error, :no_section}

      {_, [section | rest]} ->
        nested = Enum.take_while(rest, &(&1.level > section.level))
        text = Enum.map_join([section | nested], "\n\n", &section_markdown/1)
        {:ok, page, %{section | text: text}}
    end
  end

  defp section_markdown(%{heading: nil, text: text}), do: text

  defp section_markdown(%{heading: heading, level: level, text: text}),
    do: "#{String.duplicate("#", level)} #{heading}\n\n#{text}"

  defp terms(query) do
    query
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}_.]+/u, trim: true)
    |> Enum.map(&String.trim(&1, "."))
    |> Enum.reject(&(String.length(&1) < 2 or &1 in @stopwords))
    |> Enum.uniq()
  end

  # Inverse document frequency: rarer words weigh more.
  defp weight(docs, term) do
    held =
      Enum.count(docs, fn {_, _, title, heading, text} ->
        String.contains?(heading <> " " <> title <> " " <> text, term)
      end)

    if held == 0, do: 0.0, else: :math.log(1 + length(docs) / held)
  end

  defp score({_, _, title, heading, text}, terms, weights) do
    {matched, points} =
      Enum.reduce(terms, {0, 0.0}, fn term, {matched, points} ->
        hits =
          min(length(:binary.matches(text, term)), 5) + if(String.contains?(heading, term), do: 6, else: 0) +
            if(String.contains?(title, term), do: 3, else: 0)

        if hits > 0, do: {matched + 1, points + hits * weights[term]}, else: {matched, points}
      end)

    points * matched / length(terms)
  end

  # About 240 characters of `text` around the first query term in it.
  defp snippet(text, terms) do
    flat = text |> String.split() |> Enum.join(" ")
    down = String.downcase(flat)

    # The first match's position in characters, so the cut never splits one.
    at =
      terms
      |> Enum.flat_map(fn term ->
        case :binary.match(down, term) do
          {at, _} -> [String.length(binary_part(down, 0, at))]
          :nomatch -> []
        end
      end)
      |> Enum.min(fn -> 0 end)

    start = max(0, at - 80)
    length = String.length(flat)

    if(start > 0, do: "…", else: "") <>
      String.slice(flat, start, 240) <> if(start + 240 < length, do: "…", else: "")
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(text), do: if(String.trim(text) != "", do: text)
end
