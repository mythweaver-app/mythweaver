defmodule MythweaverWeb.CoreComponents.Modal do
  @moduledoc """
  A general-purpose modal dialog built on the HTML `<dialog>` element, taking its content
  as a slot.

  A server-rendered `open` attribute yields a *non-modal* dialog, so the dialog is opened
  from the client by a colocated hook calling `showModal()` on mount. Mounting is therefore
  opening: render the component only while the dialog should be visible.

  Every dismissal (close button, Escape, backdrop) first dispatches a cancelable
  `modal:before-close` event on the dialog; a listener that cancels it keeps the dialog open. A
  `modal:close` event dispatched on the dialog dismisses it the same way, so a form's own Cancel
  button can use `JS.dispatch("modal:close", to: "#<modal id>")`.
  """

  # Bare `Phoenix.Component` plus direct imports, not `use MythweaverWeb, :html`: `html_helpers/0`
  # imports this module, so `use`ing it here is a circular self-reference and a compile error.
  use Phoenix.Component
  use Gettext, backend: Mythweaver.Gettext

  import Iconex, only: [lucide: 1]

  alias Phoenix.LiveView.JS

  attr :id, :string, required: true, doc: "DOM id; also the handle for `phx-click` targeting"
  attr :title, :string, default: nil

  attr :on_cancel, :any,
    default: nil,
    doc: "event name pushed when the dialog is dismissed (close button, Escape, or backdrop click)"

  attr :on_cancel_target, :string,
    default: nil,
    doc: "a selector inside the LiveComponent `on_cancel` goes to (`pushEventTo`); nil: the LiveView"

  attr :class, :string,
    default: "",
    doc: ~s(extra dialog classes; "modal--wide" widens the panel to 48rem, "modal--fit" sizes it to its content)

  attr :rest, :global
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <%!--
      `lower-bound="none"`: the slot content is supplied by callers whose own elements are
      nested component roots carrying `phx-r`, which the default exclusive bound would cut
      `.modal-body` styling off from. With no lower bound every element carrying this block's
      scope marker is a scope root, so the root rule is qualified as `dialog:scope`.
    --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      /* A UA stylesheet gives `[open]` dialogs a border and padding; reset both. `display` is
         deliberately not set: the UA toggles it for `open`. */
      dialog:scope {
        padding: 0;
        border: 0;
        background: none;
        /* A `<dialog>` is shrink-to-fit, so a bare `max-inline-size` never engages and the panel
           collapses to its content width; `inline-size` makes the cap the actual width. */
        inline-size: min(32rem, calc(100vw - 2 * var(--panel-gap)));
        max-inline-size: min(32rem, calc(100vw - 2 * var(--panel-gap)));
        color: var(--foreground);
      }

      dialog:scope.modal--wide {
        inline-size: min(48rem, calc(100vw - 2 * var(--panel-gap)));
        max-inline-size: min(48rem, calc(100vw - 2 * var(--panel-gap)));
      }

      /* As wide as the content's max-content width, between the default width and the viewport. A
         caller keeps long content (wrapping text, lists) from driving the width with
         `contain: inline-size`, which leaves it filling the panel but contributing no width. */
      dialog:scope.modal--fit {
        inline-size: fit-content;
        min-inline-size: min(32rem, calc(100vw - 2 * var(--panel-gap)));
        max-inline-size: calc(100vw - 2 * var(--panel-gap));
      }

      /* The backdrop pseudo-element attaches to the `@scope` root match, so it must be written
         against `:scope`; a bare `::backdrop` never matches the scope root. */
      dialog:scope::backdrop {
        background: oklch(0 0 0 / 0.5);
        backdrop-filter: blur(5px) saturate(30%) brightness(60%);
        opacity: 1;
        transition:
          opacity 0.1s ease-in,
          backdrop-filter 0.1s ease-in;

        @starting-style {
          backdrop-filter: none;
          opacity: 0;
        }
      }

      .modal-panel {
        background: color-mix(in oklch, var(--surface-5) 75%, transparent);
        border: 1px solid var(--border);
        border-radius: var(--radius-3);
        box-shadow: var(--elevation-2xl);
        padding: var(--size-3);
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
        opacity: 1;
        transition:
          opacity 0.1s ease-in,
          translate 0.1s ease-in;
        translate: 0 0;

        @starting-style {
          opacity: 0;
          translate: 0 -20px;
        }
      }

      .modal-header {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: var(--size-2);
      }

      .modal-title {
        margin: 0;
        font-size: 1.1rem;
      }

      .modal-close {
        padding: 0;
        border: 0;
        background: none;
        color: var(--muted-foreground);
        font: inherit;
        cursor: pointer;
      }

      .modal-body {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }
    </style>

    <dialog
      id={@id}
      class={["modal", @class]}
      phx-hook=".Modal"
      data-on-cancel={@on_cancel}
      data-on-cancel-target={@on_cancel_target}
      {@rest}
    >
      <div class="modal-panel">
        <header :if={@title} class="modal-header">
          <h2 class="modal-title">{@title}</h2>
          <%!--
            Dispatches a DOM event rather than closing directly, so a single hook code path
            handles every dismissal (button, Escape, backdrop) and reports it once.
          --%>
          <button
            type="button"
            class="modal-close"
            phx-click={JS.dispatch("modal:close", to: "##{@id}")}
            aria-label={pgettext("aria label: icon button that closes a dialog", "Close")}
          >
            <.lucide name="x" />
          </button>
        </header>

        <div class="modal-body">{render_slot(@inner_block)}</div>
      </div>
    </dialog>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".Modal">
      export default {
        mounted() {
          // A server-rendered `open` attribute yields a *non-modal* dialog (no backdrop, no focus
          // trap, no Escape), so the dialog must be opened from the client.
          this.el.showModal();
          // morphdom removes any attribute missing from the incoming server template, which would
          // strip the `open` that showModal() just set and silently close the dialog on the next
          // patch. `ignoreAttributes` makes LiveView copy it forward across patches instead.
          this.js().ignoreAttributes(this.el, ["open"]);

          this.onCancel = this.el.dataset.onCancel;
          this.onCancelTarget = this.el.dataset.onCancelTarget;
          // Every dismissal asks first: a cancelled `modal:before-close` keeps the dialog open (the
          // `UnsavedChanges` hook on a form inside does that when the user keeps their edits).
          const mayClose = () =>
            this.el.dispatchEvent(
              new Event("modal:before-close", { cancelable: true }),
            );
          this.el.addEventListener(
            "modal:close",
            () => mayClose() && this.el.close(),
          );
          // Escape: `cancel` comes before the `close` it would cause.
          this.el.addEventListener("cancel", (e) => mayClose() || e.preventDefault());
          // Fires for Escape and for `close()`; `cancel` alone would miss the close button.
          this.el.addEventListener("close", () => {
            if (this.onCancel && this.onCancelTarget)
              this.pushEventTo(this.onCancelTarget, this.onCancel, {});
            else if (this.onCancel) this.pushEvent(this.onCancel, {});
          });
          // A click landing on the dialog itself (not the panel) is a backdrop click.
          this.el.addEventListener("click", (e) => {
            if (e.target === this.el && mayClose()) this.el.close();
          });
        },
      };
    </script>
    """
  end
end
