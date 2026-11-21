defmodule MythweaverDocs.NotFoundPage do
  @moduledoc "`404.html`, which GitHub Pages serves for any missing path."

  use Tableau.Page,
    layout: MythweaverDocs.RootLayout,
    permalink: "/404.html",
    title: "Page not found"

  use Phoenix.Component

  def template(assigns) do
    ~H"""
    <main id="docs-not-found">
      <h1>Page not found</h1>
      <p>There is no page at this address. It may have moved.</p>
      <p><a href={MythweaverDocs.path("/")}>Go to the documentation home</a></p>
    </main>
    """
  end
end
