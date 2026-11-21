defmodule MythweaverWeb.CoreComponents.Header do
  @moduledoc """
  The app's two heading treatments, so each is styled in exactly one place.

    * `panel_header/1`: the small uppercase bar across the top of a panel (the chat rails, a pane's
      list and editor), underlined, with optional trailing controls.
    * `section_header/1`: a section's heading inside a panel (a 1rem `h2`), with optional trailing
      controls.

  Both take the title as the inner block and the controls in `:actions`, which is right-aligned and
  never shrinks: a long title truncates (panel; `wrap` lets it wrap instead) or wraps (section).

  Slot content is the caller's markup, so its scoped CSS keeps styling it, but a caller block
  without `lower-bound="none"` reaches a slot root only through `:scope` (e.g.
  `div.chat-participants-tools:scope`), as with any slot.
  """

  use Phoenix.Component

  attr :sticky, :boolean,
    default: false,
    doc: "pin to the top of the scrolling panel, opaque over the content scrolling beneath"

  attr :wrap, :boolean,
    default: false,
    doc: "wrap a long title instead of truncating it, for a narrow panel whose title must stay whole"

  attr :rest, :global
  slot :inner_block, required: true, doc: "the title"
  slot :actions, doc: "trailing controls"

  def panel_header(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      /* `position: relative` so a caller's absolutely positioned overlay in `:actions` (the chat's
         bulk-selection panel) can hang off the header's bottom edge.

         The top corners take the parent panel's radius: a panel that doesn't clip its content
         (`overflow: visible`) would otherwise show the header's square background corners past its
         own rounded ones. A non-panel parent has no radius, so the header stays square there. */
      header:scope {
        position: relative;
        display: flex;
        align-items: center;
        gap: var(--size-2);
        padding-inline: var(--size-3);
        border-bottom: 1px solid var(--border-grey);
        border-start-start-radius: inherit;
        border-start-end-radius: inherit;
        background: var(--surface-3);
      }

      /* The header's background is the opaque `--surface-3`, so scrolled content can't show
         through. */
      header.panel-header--sticky:scope {
        position: sticky;
        top: 0;
        z-index: 1;
      }

      /* The block padding, not the root's, sets the bar's height, so a bar with controls is as tall
         as one without. */
      .panel-header-title {
        flex: 1 1 auto;
        min-width: 0;
        margin: 0;
        padding-block: var(--size-3);
        font-size: 0.8rem;
        text-transform: uppercase;
        letter-spacing: 0.05em;
        white-space: nowrap;
        overflow: hidden;
        text-overflow: ellipsis;
      }

      header.panel-header--wrap:scope .panel-header-title {
        white-space: normal;
      }

      .panel-header-actions {
        display: flex;
        flex-shrink: 0;
        align-items: center;
        gap: var(--size-1);
      }

      /* Phones: a long title truncates first; actions drop to their own line only when they alone
         overflow. */
      @media (--phone) {
        header:scope {
          flex-wrap: wrap;
        }

        .panel-header-title {
          flex: 1 1 0;
          min-inline-size: 6rem;
        }

        .panel-header-actions {
          flex-wrap: wrap;
          justify-content: flex-end;
          margin-inline-start: auto;
          padding-block: var(--size-1);
        }
      }
    </style>
    <header
      class={[
        "panel-header",
        @sticky && "panel-header--sticky",
        @wrap && "panel-header--wrap"
      ]}
      {@rest}
    >
      <h2 class="panel-header-title">{render_slot(@inner_block)}</h2>
      <div :if={@actions != []} class="panel-header-actions">{render_slot(@actions)}</div>
    </header>
    """
  end

  attr :rest, :global
  slot :inner_block, required: true, doc: "the title"
  slot :actions, doc: "trailing controls"

  def section_header(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      header:scope {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: var(--size-2);
      }

      .section-header-title {
        min-width: 0;
        margin: 0;
        font-size: 1rem;
      }

      .section-header-actions {
        display: flex;
        flex-shrink: 0;
        align-items: center;
        gap: var(--size-1);
      }
    </style>
    <header class="section-header" {@rest}>
      <h2 class="section-header-title">{render_slot(@inner_block)}</h2>
      <div :if={@actions != []} class="section-header-actions">{render_slot(@actions)}</div>
    </header>
    """
  end
end
