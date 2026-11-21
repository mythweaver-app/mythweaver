defmodule MythweaverWeb.CoreComponents.Disclosure do
  @moduledoc """
  A collapsible section: a `<details>` whose `<summary>` shows a rotating chevron, a bold title
  and optional trailing extras (counts, badges, error markers), over the inner block.

  `JS.ignore_attributes(["open"])` keeps a section the user expanded or collapsed that way across
  LiveView re-renders, so `open` only sets the state the section first mounts with.

  The title, extras and body are the caller's slot content, so the caller's own scoped CSS styles
  them. The summary's padding is `--disclosure-summary-padding` (default none), which a caller
  sets on the `<details>` through `class`.
  """

  use Phoenix.Component

  import Iconex, only: [lucide: 1]

  alias Phoenix.LiveView.JS

  attr :id, :string, required: true
  attr :open, :boolean, default: false, doc: "whether the section first mounts expanded"
  attr :rest, :global, doc: "passed to the `<details>` (e.g. `class`)"
  slot :title, required: true, doc: "the bold summary label"
  slot :summary_extra, doc: "trailing summary content: counts, badges, indicators"
  slot :inner_block, required: true

  def disclosure(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      details:scope {
        display: block;
      }

      details:scope > summary {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: var(--size-2);
        padding: var(--disclosure-summary-padding, 0);
        cursor: pointer;
        list-style: none;
      }

      /* A flex `summary` drops the disclosure triangle; the chevron stands in for it. */
      details:scope > summary::-webkit-details-marker {
        display: none;
      }

      .disclosure-chevron {
        display: inline-flex;
        transition: transform 0.15s;
      }

      details:scope[open] > summary .disclosure-chevron {
        transform: rotate(90deg);
      }

      .disclosure-title {
        display: inline-flex;
        align-items: center;
        gap: var(--size-1);
        font-weight: 600;
      }
    </style>
    <details id={@id} open={@open} phx-mounted={JS.ignore_attributes(["open"])} {@rest}>
      <summary>
        <span class="disclosure-chevron"><.lucide name="chevron-right" /></span>
        <span class="disclosure-title">{render_slot(@title)}</span>
        {render_slot(@summary_extra)}
      </summary>
      {render_slot(@inner_block)}
    </details>
    """
  end
end
