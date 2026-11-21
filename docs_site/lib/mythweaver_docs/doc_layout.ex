defmodule MythweaverDocs.DocLayout do
  @moduledoc """
  A documentation page: the header (menu toggle, brand, search), the section nav, the article with
  its breadcrumb and prev/next pager, and the "On this page" table of contents.
  """

  use Tableau.Layout, layout: MythweaverDocs.RootLayout
  use Phoenix.Component

  @logo_path Path.expand("../../../priv/static/images/logo.svg", __DIR__)
  @external_resource @logo_path
  @logo File.read!(@logo_path)

  def template(assigns) do
    site = assigns.docs
    page = assigns.page.docs_page

    # Tableau's assigns are a plain map (no `__changed__`), so `assign/2` does not apply.
    assigns =
      Map.merge(assigns, %{
        site: site,
        doc: page,
        section: Enum.find(site.sections, &(&1.key == page.section)),
        logo: Phoenix.HTML.raw(@logo),
        neighbours: neighbours(site.reading_order, page)
      })

    ~H"""
    <header id="docs-header">
      <button popovertarget="docs-nav" class="docs-nav-toggle" aria-label="Menu">
        <Iconex.lucide name="menu" />
      </button>
      <a class="docs-brand" href={MythweaverDocs.path("/")}>
        <span class="docs-logo" aria-hidden="true">{@logo}</span>
        <span>Mythweaver Docs</span>
      </a>
      <div id="docs-search" role="search">
        <Iconex.lucide name="search" />
        <input
          id="docs-search-input"
          type="search"
          placeholder="Search the docs"
          autocomplete="off"
          aria-label="Search the docs"
          aria-controls="docs-search-results"
          aria-expanded="false"
        />
        <kbd>/</kbd>
        <ul id="docs-search-results" role="listbox" hidden></ul>
      </div>
    </header>
    <div id="docs-body">
      <nav id="docs-nav" popover aria-label="Documentation">
        <a href={MythweaverDocs.path("/")} aria-current={current(@site.home, @doc)}>Home</a>
        <details :for={section <- @site.sections} open={section.key == @doc.section}>
          <%!-- The summary only toggles; the section's index is the list's first link. --%>
          <summary>{section.title}</summary>
          <ul>
            <li>
              <a
                href={MythweaverDocs.path(section.index.permalink)}
                aria-current={current(section.index, @doc)}
              >
                Overview
              </a>
            </li>
            <li :for={page <- section.pages}>
              <a href={MythweaverDocs.path(page.permalink)} aria-current={current(page, @doc)}>
                {page.title}
              </a>
            </li>
          </ul>
        </details>
      </nav>
      <main id="docs-article">
        <nav :if={@section && @doc.slug} class="docs-breadcrumb" aria-label="Breadcrumb">
          <a href={MythweaverDocs.path(@section.index.permalink)}>{@section.title}</a>
        </nav>
        <h1>{@doc.title}</h1>
        <p :if={@doc.description} class="docs-description">{@doc.description}</p>
        <article class="docs-prose">{Phoenix.HTML.raw(render(@inner_content))}</article>
        <nav id="docs-pager" aria-label="Pages">
          <a
            :if={prev = elem(@neighbours, 0)}
            class="docs-pager-prev"
            rel="prev"
            href={MythweaverDocs.path(prev.permalink)}
          >
            <span>Previous</span>
            {prev.title}
          </a>
          <a
            :if={next = elem(@neighbours, 1)}
            class="docs-pager-next"
            rel="next"
            href={MythweaverDocs.path(next.permalink)}
          >
            <span>Next</span>
            {next.title}
          </a>
        </nav>
      </main>
      <aside :if={@doc.toc != []} id="docs-toc" aria-labelledby="docs-toc-title">
        <p id="docs-toc-title">On this page</p>
        <ul>
          <li :for={entry <- @doc.toc} class={"docs-toc-h#{entry.level}"}>
            <a href={"#" <> entry.id}>{entry.text}</a>
          </li>
        </ul>
      </aside>
    </div>
    """
  end

  defp current(%{permalink: p}, %{permalink: p}), do: "page"
  defp current(_, _), do: nil

  defp neighbours(order, page) do
    index = Enum.find_index(order, &(&1.permalink == page.permalink))
    prev = if index > 0, do: Enum.at(order, index - 1)
    {prev, Enum.at(order, index + 1)}
  end
end
