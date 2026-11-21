defmodule MythweaverDocs.RootLayout do
  @moduledoc "The HTML document around every page: head, stylesheet, script and icon sprite."

  use Tableau.Layout
  use Phoenix.Component

  def template(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{title(@page)}</title>
        <meta :if={@page[:description]} name="description" content={@page[:description]} />
        <link rel="icon" href={MythweaverDocs.path("/images/logo.svg")} />
        <link rel="stylesheet" href={MythweaverDocs.path("/css/site.css")} />
        <script defer src={MythweaverDocs.path("/js/site.js")}>
        </script>
      </head>
      <body data-base-path={MythweaverDocs.base_path()}>
        {Iconex.sprite_tag()}
        {render(@inner_content)}
        <.live_reload />
      </body>
    </html>
    """
    |> Phoenix.HTML.Safe.to_iodata()
  end

  defp title(%{permalink: "/"}), do: "Mythweaver Docs"
  defp title(page), do: "#{page.title} · Mythweaver Docs"

  if Mix.env() == :dev do
    # The dev server's component returns a plain HTML string, not a rendered template. Its classic
    # inline script, run while the page parses, makes Chromium skip the incoming view transition;
    # as a module script it runs deferred and the transition plays.
    defp live_reload(assigns) do
      script =
        assigns
        |> TableauDevServer.live_reload()
        |> String.replace("<script>", ~s(<script type="module">), global: false)

      assigns = Map.put(assigns, :script, Phoenix.HTML.raw(script))
      ~H"{@script}"
    end
  else
    defp live_reload(assigns), do: ~H""
  end
end
