defmodule MythweaverWeb.CoreComponents.Hint do
  @moduledoc """
  A `?` icon that shows a short help blurb while hovered or focused.

  Pure CSS: the popup is anchored to the icon with CSS anchor positioning and flips to stay on
  screen. `anchor-scope` keeps the shared anchor name local to each hint, so any number can sit on
  one page without per-instance names. It is `position: fixed`, so an overflowing pane does not
  clip it.

  The trigger is a `type="button"`, so it is focusable and, inside a `<label>`, does not activate
  the labelled control. The blurb is `role="tooltip"` and describes the trigger; it is
  `display: none` until shown, so it stays out of the label's accessible name.

  The blurb is the inner block, so it may hold HTML: phrasing content only (`<code>`, `<em>`,
  `<strong>`, `<kbd>`), since it renders inside a `<span>` that is often inside a `<label>`. It is
  not interactive: a tooltip takes no pointer events (a click on it would reach the label and
  toggle a checkbox), so a link in it cannot be followed. Keep it to one paragraph.

  `<.input>` and `<.editor>` render one after their label from their `:hint` slot. It is not in
  `html_helpers`, where `CommandPalette` has a private `hint/1`; import it to use it standalone.
  """

  use Phoenix.Component
  use Gettext, backend: Mythweaver.Gettext

  import Iconex, only: [lucide: 1]

  attr :id, :string, required: true, doc: "the blurb's id; the trigger is described by it"
  attr :label, :string, default: nil, doc: "the trigger's accessible name; nil: \"Help\""
  slot :inner_block, required: true

  def hint(assigns) do
    ~H"""
    <%!-- `lower-bound="inclusive"`: the blurb's tags come from the caller's slot, and each carries
         `phx-r`, so the default exclusive bound would leave its `<code>` unstyled. --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="inclusive">
      span:scope {
        anchor-scope: --hint;
        display: inline-flex;
        vertical-align: middle;
        margin-inline-start: var(--size-1);
      }

      .hint-trigger {
        anchor-name: --hint;
        display: inline-flex;
        padding: 0;
        border: 0;
        background: none;
        color: var(--muted-foreground);
        font-size: 0.9em;
        line-height: 1;
        cursor: help;
        border-radius: 50%;
      }

      /* The reset (`assets/css/reset.css`) caps `svg` at `max-inline-size: 100%`, which makes the
         icon's min-content width 0, so a one-line label measured at min-content (`<.field_row>`)
         comes up an icon short. */
      .hint-trigger svg {
        max-inline-size: none;
      }

      .hint-trigger:hover,
      .hint-trigger:focus-visible {
        color: var(--foreground);
      }

      .hint-trigger:focus-visible {
        outline: 2px solid var(--ring);
        outline-offset: 2px;
      }

      .hint-popup {
        display: none;
        position: fixed;
        position-anchor: --hint;
        position-area: block-start span-inline-end;
        position-try-fallbacks:
          flip-block,
          flip-inline,
          flip-block flip-inline;
        z-index: 50;
        margin: var(--size-1);
        inline-size: max-content;
        max-inline-size: min(36ch, calc(100vw - 2 * var(--size-2)));
        padding: var(--size-2) var(--size-3);
        border: 1px solid var(--border);
        border-radius: var(--radius-2);
        background: var(--surface-8);
        color: var(--foreground);
        box-shadow: var(--elevation-md);
        font-size: 0.85rem;
        font-weight: normal;
        line-height: 1.4;
        text-transform: none;
        letter-spacing: normal;
        white-space: normal;
        pointer-events: none;
      }

      span:scope:hover > .hint-popup,
      span:scope:focus-within > .hint-popup {
        display: block;
      }

      .hint-popup code,
      .hint-popup kbd {
        font-family: var(--font-monospace-code, ui-monospace, monospace);
        font-size: 0.95em;
        padding: 0 0.25em;
        border-radius: var(--radius-1);
        background: var(--surface-3);
      }
    </style>
    <span class="hint">
      <button
        type="button"
        class="hint-trigger"
        aria-label={
          @label || pgettext("aria label: question-mark button that shows a help tooltip", "Help")
        }
        aria-describedby={@id}
      >
        <.lucide name="circle-question-mark" />
      </button>
      <span id={@id} class="hint-popup" role="tooltip">{render_slot(@inner_block)}</span>
    </span>
    """
  end
end
