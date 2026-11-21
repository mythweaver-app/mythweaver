defmodule MythweaverWeb.CoreComponents.Drawer do
  @moduledoc """
  The app's one slide-over mechanism: side rails and toolbars that move into a drawer on narrow
  screens. Built on the HTML Popover API, so it needs no hook and no server state: light dismiss,
  Escape, the backdrop and the toggle's `aria-expanded` are native, and the open state survives
  LiveView patches because it is not an attribute.

  A drawer is the existing panel element itself, given `popover`, an id, and the classes

    * `drawer`, always;
    * `drawer--start` (slides in from the inline start), `drawer--end` or `drawer--bottom` (a sheet);
    * `drawer--phone` (a drawer at ≤ 50rem, the `--phone` custom media), `drawer--tablet`
      (≤ 64rem, `--tablet`) or `drawer--laptop` (≤ 87rem, `--laptop`; see `assets/css/media.css`).

  Above its breakpoint the element is an ordinary in-flow panel and keeps its own styling; below it
  the element is hidden until opened into the top layer, by `drawer_toggle/1` (which shows only
  below the same breakpoint), a sideways flick, or anything else that calls `showPopover()`. A
  drawer whose content has no padding of its own sets `--drawer-padding` on itself.

  Every drawer carries `--drawer-active`: `1` below its breakpoint (it is a drawer there), `0`
  above it (an in-flow panel). Scripts read it to tell a drawer from a panel hidden for another
  reason (a collapsed rail), so the breakpoint stays in the stylesheet.

  A link followed inside an open drawer closes it (`assets/js/drawers.ts`; a patch keeps the
  element, so it would otherwise stay open). With `data-drawer-actions` on the drawer, every button
  inside closes it too (an action sheet); otherwise buttons, checkboxes and `<summary>`s keep it
  open (a list drawer).

  A side drawer with `data-drawer-swipe` also opens on a sideways flick while collapsed (rightward
  for `drawer--start`, leftward for `drawer--end`) and closes on a flick toward its own edge; the
  chat picker, the participants rail and every `pane_layout` list opt in.

  Styles are global (`MythweaverWeb.ColocatedCSS`): the classes land on callers' elements.
  """

  use Phoenix.Component

  import MythweaverWeb.CoreComponents.Button, only: [button: 1]

  attr :for, :string, required: true, doc: "id of the drawer element (carries `popover`)"
  attr :breakpoint, :string, required: true, values: ~w(phone tablet laptop)
  attr :label, :string, required: true, doc: "aria-label and title"

  attr :icon, :boolean,
    default: true,
    doc: "icon-only square button; false when the slot carries text"

  attr :id, :string, required: true
  slot :inner_block, required: true, doc: "the `<.lucide>` (and text when `icon={false}`)"

  def drawer_toggle(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedCSS}>
      .button.drawer-toggle {
        display: none;
      }

      @media (--laptop) {
        .button.drawer-toggle--laptop {
          display: inline-flex;
        }
      }

      @media (--tablet) {
        .button.drawer-toggle--tablet {
          display: inline-flex;
        }
      }

      @media (--phone) {
        .button.drawer-toggle--phone {
          display: inline-flex;
        }
      }

      /* 1 below the breakpoint (set in each media block below); see the moduledoc. */
      :where([popover].drawer) {
        --drawer-active: 0;
      }

      /* Closed and in flow (above the breakpoint): undo the UA popover box, including its
         `display: none`. Zero specificity, so the element's own styles (display, border,
         background, overflow) win. */
      :where([popover].drawer:not(:popover-open)) {
        position: static;
        display: block;
        inset: auto;
        inline-size: auto;
        block-size: auto;
        margin: 0;
        padding: 0;
        border: 0;
        overflow: visible;
        color: inherit;
        background: none;
      }

      @media (--laptop) {
        [popover].drawer--laptop {
          --drawer-active: 1;
        }

        [popover].drawer--laptop:not(:popover-open) {
          display: none;
        }
      }

      @media (--tablet) {
        [popover].drawer--tablet {
          --drawer-active: 1;
        }

        [popover].drawer--tablet:not(:popover-open) {
          display: none;
        }
      }

      @media (--phone) {
        [popover].drawer--phone {
          --drawer-active: 1;
        }

        [popover].drawer--phone:not(:popover-open) {
          display: none;
        }
      }

      /* Open: no media query, since whatever opens a drawer (its toggle, a flick) does so only
         below the breakpoint. Out-specifies the panel's own card styling. */
      [popover].drawer:popover-open {
        --drawer-padding-total: var(--drawer-padding, 0px);
        position: fixed;
        display: flex;
        flex-direction: column;
        inset-block: 0;
        margin: 0;
        inline-size: min(22rem, calc(100vw - 3rem));
        max-inline-size: none;
        block-size: 100dvh;
        max-block-size: none;
        overflow-y: auto;
        padding: calc(var(--drawer-padding-total) + env(safe-area-inset-top))
          calc(var(--drawer-padding-total) + env(safe-area-inset-right))
          calc(var(--drawer-padding-total) + env(safe-area-inset-bottom))
          calc(var(--drawer-padding-total) + env(safe-area-inset-left));
        border: 0;
        border-radius: 0;
        background: var(--background);
        color: var(--foreground);
        box-shadow: var(--elevation-2xl);
        translate: none;
        transition: translate 200ms ease;

        @starting-style {
          translate: var(--drawer-from);
        }
      }

      [popover].drawer.drawer--start:popover-open {
        inset-inline: 0 auto;
        --drawer-from: -100% 0;
        border-inline-end: 1px solid var(--border);
      }

      [popover].drawer.drawer--end:popover-open {
        inset-inline: auto 0;
        --drawer-from: 100% 0;
        border-inline-start: 1px solid var(--border);
      }

      [popover].drawer.drawer--bottom:popover-open {
        inset-block: auto 0;
        inset-inline: 0;
        inline-size: auto;
        block-size: auto;
        max-block-size: 80dvh;
        --drawer-from: 0 100%;
        border-block-start: 1px solid var(--border);
        border-start-start-radius: var(--radius-3);
        border-start-end-radius: var(--radius-3);
      }

      [popover].drawer::backdrop {
        background: oklch(0 0 0 / 0.5);
      }

      @media (prefers-reduced-motion: reduce) {
        [popover].drawer:popover-open {
          transition: none;
        }
      }
    </style>
    <.button
      size="sm"
      icon={@icon}
      id={@id}
      popovertarget={@for}
      aria-label={@label}
      title={@label}
      class={["drawer-toggle", "drawer-toggle--#{@breakpoint}"]}
    >
      {render_slot(@inner_block)}
    </.button>
    """
  end
end
