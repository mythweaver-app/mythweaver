defmodule MythweaverWeb.CoreComponents.FormActions do
  @moduledoc """
  A form's Save/Cancel row, placed last in the `<form>` (a direct child, or the last child of the
  block wrapping the fields). The inner block is the right-aligned cluster, Cancel then the submit
  button; `:start` holds controls kept apart on the left (Delete, Test, New, Add row).

  In a form guarded by the `UnsavedChanges` hook (`assets/js/hooks/unsaved_changes.ts`) the hook
  sets `data-unsaved` on the `<form>` while any field differs from its saved value. The row then
  shows "Unsaved changes" and floats as a raised bar pinned to the bottom of the nearest scroll
  container (the pane editor, the modal, the page), so Save stays in reach however far up the form
  the user is. It stops at the form's own end, so it never covers what follows the form. Outside a
  guarded form, or with nothing unsaved, it is a plain row in the flow.

  The bar's padding and border are always there (transparent while clean) and offset by a negative
  margin, so turning it on moves nothing. Styles are global (`MythweaverWeb.ColocatedCSS`) because
  the trigger is an attribute on the caller's `<form>`, outside this component.
  """

  use Phoenix.Component
  use Gettext, backend: Mythweaver.Gettext

  attr :id, :string, default: nil
  attr :class, :any, default: nil, doc: "layout hook for the caller, as on `<.button>`"
  attr :rest, :global

  slot :start, doc: "controls kept apart on the left, before the unsaved notice"
  slot :inner_block, required: true, doc: "the right-aligned cluster: Cancel, then submit"

  def form_actions(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedCSS}>
      .form-actions {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: var(--size-2);
        margin: calc(-1 * var(--size-2) - 1px);
        padding: var(--size-2);
        border: 1px solid transparent;
        border-radius: var(--radius-3);
      }

      .form-actions-start,
      .form-actions-end {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: var(--size-2);
      }

      .form-actions-end {
        margin-inline-start: auto;
        justify-content: flex-end;
      }

      .form-actions-status {
        display: none;
        align-items: center;
        gap: var(--size-1);
        color: var(--primary-accent);
        font-size: 0.85rem;
        white-space: nowrap;
      }

      /* The same dot `<.input>` puts before an unsaved field's label. */
      .form-actions-status::before {
        content: "";
        inline-size: 0.5em;
        block-size: 0.5em;
        border-radius: 50%;
        background: currentColor;
      }

      form[data-unsaved] .form-actions {
        position: sticky;
        inset-block-end: var(--size-2);
        z-index: 2;
        background: var(--surface-6);
        border-color: var(--primary-accent);
        box-shadow: var(--elevation-lg);
      }

      form[data-unsaved] .form-actions-status {
        display: inline-flex;
      }
    </style>
    <div id={@id} class={["form-actions", @class]} {@rest}>
      <div :if={@start != []} class="form-actions-start">{render_slot(@start)}</div>
      <span class="form-actions-status">
        {pgettext("status: the form has edits that are not saved yet", "Unsaved changes")}
      </span>
      <div class="form-actions-end">{render_slot(@inner_block)}</div>
    </div>
    """
  end
end
