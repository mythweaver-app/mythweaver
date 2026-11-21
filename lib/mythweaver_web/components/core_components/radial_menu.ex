defmodule MythweaverWeb.CoreComponents.RadialMenu do
  @moduledoc """
  The page's one radial (pie) menu: right-click (mouse) or long-press (touch) on a target row opens
  a ring of that row's actions around the pointer. The user can press, drag onto a slice and
  release (releasing back at the center cancels), or release first and then tap a slice. The
  behaviour is the external `RadialMenu` hook (`assets/js/hooks/radial_menu.ts`); `Layouts.app`
  renders `<.radial_menu />` once per page, so a surface opts in with markup alone.

  The ring is built from the row's own buttons and activates them with `.click()`, so their
  permissions, `phx-click`/`phx-value-*`, `data-confirm` and CSS visibility rules all carry over.
  An entry that is disabled, `aria-disabled="true"` or not visible (`checkVisibility()`) shows
  dimmed and can't be picked, and so does every slot the target's layout (`radial_layout/1`) names
  but the row doesn't render: the ring keeps one shape on every row. A row with no usable entry
  opens nothing and keeps the native context menu.

  Markup contract:

    * `data-radial-menu="<label>"` on a row makes it a target. The label is the ring's
      `aria-label` and shows in the hub (the ring's center) until a slice is pointed at: hovered
      with a mouse, or dragged onto in a press-drag (the only way on touch). The hub then shows
      that entry's label (`aria-label`, else `title`, else its text). `data-radial-slots="N"`
      on the target divides its ring into N slots (default 8); a ring of more slots than fit
      around the default radius grows until its slices stay apart.
    * `data-radial-item` on a `button` or `a` inside the target makes it an entry. It needs an
      `id` (an entry replaced by a LiveView patch is found again by id) and a Lucide/Carbon icon.
      `data-radial-slot="0"..N-1` places it: 0 is north, then clockwise in `360 / N`° steps
      (with 8: 1 NE, 2 E, 3 SE, 4 S, 5 SW, 6 W, 7 NW). Slots are fixed so positions stay the
      same between rows; an absent entry leaves its slot empty, and of two visible entries on
      one slot the first in DOM order wins.
    * `data-radial-danger` on an entry gives its slice the destructive tint.
    * `data-radial-layout="<id>"` on a target names its `radial_layout/1` template, the label and
      icon of every slot, shown dimmed where the row has no usable entry.
    * `data-radial-native` on a region inside a target keeps touch long-press native there (text
      selection). Right-click there still opens the ring.

  Shift+right-click, right-click on a field, an editor or a link, and right-click while text is
  selected keep the native menu.

  Styles are global (`MythweaverWeb.ColocatedCSS`): the hook builds the ring's DOM itself, which no
  scope marker reaches, and the touch rules apply to the callers' rows.
  """

  use Phoenix.Component

  def radial_menu(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedCSS}>
      dialog.radial-menu {
        position: fixed;
        inset: auto;
        margin: 0;
        padding: 0;
        border: 0;
        background: transparent;
        box-shadow: none;
        overflow: visible;
        max-inline-size: none;
        max-block-size: none;
        inline-size: calc(2 * var(--radial-radius) + 3rem);
        block-size: calc(2 * var(--radial-radius) + 3rem);
        translate: -50% -50%;
        color: var(--foreground);
        /* Focus sits on the ring itself only after a pointer opened it; slices show their own ring. */
        outline: none;
      }

      .radial-menu::backdrop {
        background: transparent;
      }

      .radial-menu-slice {
        position: absolute;
        left: 50%;
        top: 50%;
        inline-size: 2.5rem;
        block-size: 2.5rem;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        border-radius: var(--radius-round);
        border: 1px solid var(--border);
        background: var(--surface-8);
        box-shadow: var(--elevation-md);
        font-size: 1.15rem;
        color: inherit;
        cursor: pointer;
        /* `--radial-scale` comes last so the slice grows in place, out on the ring. */
        transform: translate(-50%, -50%) rotate(var(--radial-angle))
          translateY(calc(-1 * var(--radial-radius)))
          rotate(calc(-1 * var(--radial-angle))) scale(var(--radial-scale, 1));
      }

      @media (--coarse) {
        .radial-menu-slice {
          inline-size: var(--touch-target);
          block-size: var(--touch-target);
        }
      }

      .radial-menu-slice[aria-pressed="true"] {
        color: var(--primary-accent);
      }

      /* The slice a drag points at or the mouse hovers doubles, over its neighbours (the hub's
         label stays on top). */
      .radial-menu-slice[data-active] {
        --radial-scale: 2;
        z-index: 1;
        background: var(--primary);
        color: var(--primary-foreground);
        border-color: transparent;
      }

      .radial-menu-slice:not(:disabled):hover {
        --radial-scale: 2;
        z-index: 1;
        background: var(--primary);
        color: var(--primary-foreground);
        border-color: transparent;
      }

      .radial-menu-slice[data-danger]:not(:disabled):is([data-active], :hover) {
        background: var(--destructive);
        color: var(--destructive-foreground);
      }

      /* Touch has no hover: a tapped slice's sticky :hover must not highlight it, only a drag
         ([data-active]) does. Same specificity as the rules above, so these win by order. */
      @media (--touch) {
        .radial-menu-slice:not(:disabled):not([data-active]):hover {
          --radial-scale: 1;
          z-index: auto;
          background: var(--surface-8);
          color: inherit;
          border-color: var(--border);
        }

        .radial-menu-slice[aria-pressed="true"]:not([data-active]):hover {
          color: var(--primary-accent);
        }
      }

      .radial-menu-slice:disabled {
        opacity: 0.35;
        box-shadow: none;
        cursor: default;
      }

      .radial-menu-slice:focus-visible {
        outline: 2px solid var(--ring);
        outline-offset: 2px;
      }

      .radial-menu-hub {
        position: absolute;
        left: 50%;
        top: 50%;
        translate: -50% -50%;
        inline-size: max-content;
        max-inline-size: 8rem;
        padding: var(--size-1) var(--size-2);
        border-radius: var(--radius-3);
        background: var(--surface-10);
        border: 1px solid var(--border);
        font-size: var(--font-size-0);
        /* An action's label can be a sentence: up to three centered lines inside the ring. */
        text-align: center;
        display: -webkit-box;
        -webkit-box-orient: vertical;
        -webkit-line-clamp: 3;
        line-clamp: 3;
        overflow: hidden;
        pointer-events: none;
        z-index: 2;
      }

      .radial-menu[open] .radial-menu-slice {
        transition:
          opacity 120ms ease-out,
          scale 120ms ease-out,
          transform 120ms ease-out;
      }

      @starting-style {
        .radial-menu[open] .radial-menu-slice {
          opacity: 0;
          scale: 0.6;
        }
      }

      @media (prefers-reduced-motion: reduce) {
        .radial-menu[open] .radial-menu-slice {
          transition: none;
        }
      }

      /* A long-press on a target's header or avatar must not start a native selection or callout
         before the ring's timer fires. Fields and `data-radial-native` regions stay native. */
      @media (--touch) {
        [data-radial-menu] {
          -webkit-touch-callout: none;
          -webkit-user-select: none;
          user-select: none;
        }

        [data-radial-menu]
          :is([data-radial-native], input, textarea, select, [contenteditable]) {
          -webkit-touch-callout: default;
          -webkit-user-select: text;
          user-select: text;
        }
      }
    </style>
    <div id="radial-menu" phx-hook="RadialMenu" phx-update="ignore"></div>
    """
  end

  @doc """
  The full layout of a surface's ring: one `:item` per slot, with the label and icon its slice
  shows dimmed on a row that doesn't render that action (no permission, not applicable). Rendered
  once per surface as a `<template>`, outside the rows; each row points at it with
  `data-radial-layout={id}`. The icon is the inner block, so its name stays a literal the Iconex
  compiler sees.
  """
  attr :id, :string, required: true

  slot :item, required: true do
    attr :index, :integer, required: true
    attr :label, :string, required: true
  end

  def radial_layout(assigns) do
    ~H"""
    <template id={@id}>
      <span :for={item <- @item} data-radial-slot={item.index} aria-label={item.label}>
        {render_slot(item)}
      </span>
    </template>
    """
  end
end
