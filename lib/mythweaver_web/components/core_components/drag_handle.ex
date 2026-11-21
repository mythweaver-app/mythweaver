defmodule MythweaverWeb.CoreComponents.DragHandle do
  @moduledoc """
  The grip a draggable row is dragged by, and the styles of every drag in the app. The behaviour is
  `sortable/2` in `assets/js/hooks/sortable_list.ts`, the one drag implementation, which reorders
  through the `SortableList` hook and moves lore tree entries through `LoreTree`. A row drags only
  by this handle, so the rest of the row keeps its clicks.

  The handle is hidden from assistive tech (`aria-hidden`) because dragging has no keyboard
  alternative. Inside a list marked `data-sortable-disabled="true"` it is hidden, since the list
  can't be dragged. The dragged row stays in the list as the drop indicator (`.drag-ghost`), and
  SortableJS's floating copy (`.drag-fallback`) is hidden. The cursor is `grabbing` for the whole
  drag (`:root.drag-active`), or `alias` while a drag will copy (`:root.drag-copy`).

  Styles are global (`MythweaverWeb.ColocatedCSS`): the ghost class lands on the caller's rows and
  the cursor classes on `:root`, which no scoped rule here reaches.
  """

  use Phoenix.Component
  use Gettext, backend: Mythweaver.Gettext

  import Iconex, only: [lucide: 1]

  attr :title, :string, default: nil, doc: "the tooltip; nil: \"Drag to reorder\""

  def drag_handle(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedCSS}>
      .drag-handle {
        flex: none;
        line-height: 0;
        color: var(--muted-foreground);
        cursor: grab;
        /* The fallback drag runs on pointer events, so a touch on the handle must not scroll. */
        touch-action: none;
      }

      .drag-handle:hover {
        color: var(--foreground);
      }

      [data-sortable-disabled="true"] .drag-handle {
        visibility: hidden;
      }

      /* Coarse pointers: a 44px hit area. The negative margin cancels the padding, so the row's
         layout is unchanged (a handle never sits beside another small control). */
      @media (--coarse) {
        .drag-handle {
          padding: calc((var(--touch-target) - 1em) / 2);
          margin: calc((1em - var(--touch-target)) / 2);
        }
      }

      .drag-ghost {
        background: color-mix(in oklab, var(--primary-accent) 13%, transparent);
        outline: 1px dashed var(--primary-accent);
        outline-offset: -1px;
      }

      .drag-ghost > * {
        opacity: 0.6;
      }

      .drag-fallback {
        visibility: hidden;
      }

      :root.drag-active,
      :root.drag-active * {
        cursor: grabbing !important;
      }

      :root.drag-copy,
      :root.drag-copy * {
        cursor: alias !important;
      }
    </style>
    <span
      class="drag-handle"
      data-drag-handle
      aria-hidden="true"
      title={
        @title || pgettext("tooltip: grip that drags a list row to reorder it", "Drag to reorder")
      }
    >
      <.lucide name="grip-vertical" />
    </span>
    """
  end
end
