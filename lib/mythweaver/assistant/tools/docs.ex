defmodule Mythweaver.Assistant.Tools.Docs do
  @moduledoc """
  Assistant tools for the user documentation compiled into the app (`Mythweaver.Docs`): list its
  pages, search them, and read a page or one of its sections, so "how do I…" questions are answered
  from the docs rather than from the model's guesses.
  """

  alias Mythweaver.Assistant.Tool
  alias Mythweaver.Assistant.Tools.Args
  alias Mythweaver.Docs

  @default_limit 8
  @max_limit 20

  def tools do
    [
      %Tool{
        name: "list_docs",
        description:
          "Lists every page of Mythweaver's user documentation (how to use and run the app) with its id, title and description.",
        parameters: %{"type" => "object", "properties" => %{}},
        kind: :read,
        summary: fn _ -> "List the documentation" end,
        run: fn _scope, _args -> {:ok, %{"pages" => Docs.list() |> Enum.map(&page_entry/1)}} end
      },
      %Tool{
        name: "search_docs",
        description:
          "Searches Mythweaver's user documentation for a how-to or reference question (features, screens, settings, " <>
            "permissions, setup). Returns the best matching sections with the page id and section to pass to read_doc.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "description" => "Key words, e.g. \"sticky lore entry\"."},
            "limit" => %{
              "type" => "integer",
              "minimum" => 1,
              "maximum" => @max_limit,
              "description" => "Most results (default #{@default_limit})."
            }
          },
          "required" => ["query"]
        },
        kind: :read,
        summary: fn args -> "Search the documentation for “#{args["query"]}”" end,
        run: &search/2
      },
      %Tool{
        name: "read_doc",
        description:
          "Reads a page of Mythweaver's user documentation as Markdown, or one section of it. Links in it name other " <>
            "pages by id (lore/timing, lore/timing#sticky), which read_doc also accepts.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "page" => %{"type" => "string", "description" => "Page id from list_docs or search_docs, e.g. lore/timing."},
            "section" => %{
              "type" => "string",
              "description" => "Optional heading text or anchor (sticky); reads only that section and its subsections."
            }
          },
          "required" => ["page"]
        },
        kind: :read,
        summary: fn args -> "Read the documentation: #{args["page"]}" end,
        run: &read/2
      }
    ]
  end

  defp search(_scope, %{"query" => query} = args) when is_binary(query) do
    limit = args["limit"]
    limit = if is_integer(limit) and limit > 0, do: min(limit, @max_limit), else: @default_limit

    results =
      for %{page: page, section: section, snippet: snippet} <- Docs.search(query, limit) do
        %{"page" => page.id, "title" => page.title, "section" => section.heading, "snippet" => snippet}
      end

    {:ok, %{"results" => results}}
  end

  defp search(_scope, _args), do: {:error, Args.error("query must be text.")}

  defp read(_scope, %{"page" => ref} = args) when is_binary(ref) do
    section = if is_binary(args["section"]), do: args["section"]

    case Docs.get(ref, section) do
      {:ok, page, nil} ->
        {:ok,
         page
         |> page_entry()
         |> Map.merge(%{
           "sections" => for(%{heading: heading} when heading != nil <- page.sections, do: heading),
           "markdown" => page.body
         })}

      {:ok, page, section} ->
        {:ok, page |> page_entry() |> Map.merge(%{"section" => section.heading, "markdown" => section.text})}

      {:error, :not_found} ->
        {:error, Args.error("No documentation page #{ref}; call list_docs or search_docs for page ids.")}

      {:error, :no_section} ->
        {:error, Args.error("That page has no such section; read the page without one to see its sections.")}
    end
  end

  defp read(_scope, _args), do: {:error, Args.error("page must be text.")}

  defp page_entry(page), do: %{"page" => page.id, "title" => page.title, "description" => page.description}
end
