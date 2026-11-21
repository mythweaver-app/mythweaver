defmodule MythweaverWeb.CoreComponents.Button do
  @moduledoc """
  The app's button: a rectangle with a label (or an icon on a backdrop). It is also the app's
  button-styled link: given `navigate`, `patch` or `href` it renders `<.link>` (an `<a>`), else a
  `<button>` (`type="button"` unless told otherwise). Cancel controls are secondary buttons, as links
  when they navigate away and as buttons when they fire an event.

    * `variant`: `"primary"` (filled; the screen's main action) or `"secondary"` (outlined; the
      default).
    * `danger`: destructive, with red text and a red fill on hover (primary: a red fill).
    * `icon`: icon-only, with square padding. Give it an `aria-label`.
    * `size="sm"`: the compact toolbar size.
    * `block`: full width, content centered.

  On a secondary button `aria-pressed="true"` marks a toggle on (accent outline), `"mixed"` partly on
  (dashed accent).

  Borderless controls (bare toolbar icons, close crosses) are not buttons in this sense and keep
  their own styling.

  Styles are global (`MythweaverWeb.ColocatedCSS`), not scoped: a `<.link>` root carries no scope
  marker. `class` is a caller hook for layout only (margins, flex); the element is this component's
  root, so the caller's rule must sit in a `lower-bound="none"` or `"inclusive"` block to reach it.
  """

  use Phoenix.Component

  attr :variant, :string, default: "secondary", values: ~w(primary secondary)
  attr :size, :string, default: "md", values: ~w(sm md)
  attr :icon, :boolean, default: false, doc: "icon-only; pair with an aria-label"
  attr :danger, :boolean, default: false
  attr :block, :boolean, default: false, doc: "full width, content centered"
  attr :type, :string, default: "button", doc: "ignored for links"
  attr :class, :any, default: nil, doc: "layout hook for the caller; see the moduledoc"

  attr :rest, :global,
    include:
      ~w(href navigate patch replace method csrf_token download form formmethod name value disabled popovertarget popovertargetaction commandfor command)

  slot :inner_block, required: true

  def button(assigns) do
    assigns =
      assign(assigns, :classes, [
        "button",
        "button--#{assigns.variant}",
        assigns.size == "sm" && "button--sm",
        assigns.icon && "button--icon",
        assigns.danger && "button--danger",
        assigns.block && "button--block",
        assigns.class
      ])

    if link?(assigns.rest) do
      ~H"""
      <.link class={@classes} {@rest}>{render_slot(@inner_block)}</.link>
      """
    else
      ~H"""
      <style :type={MythweaverWeb.ColocatedCSS}>
        /* A 1px border on both variants (transparent on primary), so a primary and a secondary side
           by side are the same height. */
        .button {
          display: inline-flex;
          align-items: center;
          justify-content: center;
          gap: var(--size-1);
          padding: var(--size-1) var(--size-2);
          border: 1px solid transparent;
          border-radius: var(--radius-2);
          font: inherit;
          text-decoration: none;
          white-space: nowrap;
          cursor: pointer;
          transition:
            background-color 150ms ease,
            color 150ms ease,
            border-color 150ms ease;
        }

        /* `display: inline-flex` outranks the UA `[hidden] { display: none }`. */
        .button[hidden] {
          display: none;
        }

        .button:disabled,
        .button[aria-disabled="true"] {
          opacity: 0.4;
          cursor: default;
        }

        .button--sm {
          font-size: 0.85rem;
        }

        /* `line-height: 0` so the box hugs the 1em icon instead of a text line. */
        .button--icon {
          padding: var(--size-1);
          line-height: 0;
        }

        .button--block {
          display: flex;
          inline-size: 100%;
        }

        .button--primary {
          background: var(--primary);
          color: var(--primary-foreground);
        }

        .button--primary:hover:not(:disabled, [aria-disabled="true"]) {
          filter: brightness(1.5);
        }

        .button--secondary {
          border-color: var(--border-grey);
          background: none;
          color: var(--muted-foreground);
        }

        .button--secondary:hover:not(:disabled, [aria-disabled="true"]) {
          color: var(--foreground);
          background: var(--surface-5);
        }

        .button--secondary[aria-pressed="true"] {
          color: var(--primary-accent);
          border-color: var(--primary-accent);
        }

        .button--secondary[aria-pressed="mixed"] {
          color: var(--primary-accent);
          border-color: var(--primary-accent);
          border-style: dashed;
        }

        .button--danger {
          color: var(--destructive);
        }

        .button--danger:hover:not(:disabled, [aria-disabled="true"]),
        .button--primary.button--danger {
          color: var(--destructive-foreground);
          background: var(--destructive);
        }

        @media (--coarse) {
          .button {
            min-block-size: var(--touch-target);
          }

          .button--icon {
            min-inline-size: var(--touch-target);
          }
        }
      </style>
      <button type={@type} class={@classes} {@rest}>{render_slot(@inner_block)}</button>
      """
    end
  end

  defp link?(rest), do: Enum.any?([:href, :navigate, :patch], &Map.has_key?(rest, &1))
end
