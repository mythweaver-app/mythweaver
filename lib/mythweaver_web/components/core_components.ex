defmodule MythweaverWeb.CoreComponents do
  @moduledoc """
    * [Phoenix.Component](https://phoenix-live-view.hexdocs.pm/Phoenix.Component.html):
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: Mythweaver.Gettext

  import Iconex, only: [lucide: 1]
  import MythweaverWeb.CoreComponents.Hint, only: [hint: 1]

  alias Phoenix.HTML.Form
  alias Phoenix.HTML.FormField
  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  A flash value is a message string, or `%{message: text, action: label, path: path}` for a
  notice with a link (e.g. "Review"), so a prompt can sit in the flash instead of interrupting.

  `key` is the flash entry shown, `kind` by default. A prompt that must not be replaced by an
  unrelated notice of the same kind has a key of its own (`Layouts.flash_group/1` lists them).

  `dismiss_after` (milliseconds) clears the entry on its own once that long has passed with the
  pointer off it and focus outside it; a new message in the same entry starts the count again.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} key={:consolidation} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling, and for lookup without a `key`"
  attr :key, :atom, default: nil, doc: "the flash entry to show, when not `kind`"
  attr :dismiss_after, :integer, default: nil, doc: "clears the entry after this many ms; nil keeps it"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign(assigns, :key, assigns.key || assigns.kind)
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.key}" end)

    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      :scope {
        pointer-events: auto;
        display: flex;
        align-items: flex-start;
        gap: var(--size-2);
        padding: var(--size-2) var(--size-3);
        background: var(--card);
        backdrop-filter: blur(8px);
        border: 1px solid var(--border);
        border-radius: var(--radius-3);
        box-shadow: var(--elevation-xl);
      }

      :scope[hidden] {
        display: none;
      }

      :scope[data-kind="info"] {
        border-color: var(--primary-accent);
      }

      :scope[data-kind="error"] {
        border-color: var(--destructive);
      }

      .flash-body {
        flex: 1 1 auto;
        min-width: 0;
      }

      .flash-title,
      .flash-message {
        margin: 0;
      }

      .flash-title {
        font-weight: 600;
      }

      :scope[data-kind="error"] .flash-title {
        color: var(--destructive);
      }

      .flash-close {
        flex: 0 0 auto;
        padding: 0;
        border: 0;
        background: none;
        color: var(--muted-foreground);
        font: inherit;
        cursor: pointer;
      }

      .flash-action {
        display: inline-block;
        margin-top: var(--size-1);
        color: var(--primary-accent);
        font-weight: 600;
      }
    </style>

    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @key)}
      id={@id}
      data-flash
      data-kind={@kind}
      data-flash-key={@key}
      data-dismiss-after={@dismiss_after}
      phx-hook=".AutoDismiss"
      role="alert"
      {@rest}
    >
      <div class="flash-body">
        <p :if={@title} class="flash-title">{@title}</p>

        <p class="flash-message">{flash_message(msg)}</p>
        <.link :if={flash_path(msg)} navigate={flash_path(msg)} class="flash-action">
          {flash_action(msg)}
        </.link>
      </div>

      <button
        type="button"
        class="flash-close"
        phx-click={JS.push("lv:clear-flash", value: %{key: @key})}
        aria-label={pgettext("aria label: icon button that dismisses a flash notice", "Close")}
      >
        <.lucide name="x" />
      </button>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".AutoDismiss">
      // Clears the flash entry after `data-dismiss-after` ms (none: never), paused while the pointer
      // is over it or focus is inside it so it can be read and its link followed. Patches that leave
      // the text alone (any re-render of the page) keep the running count; a new message restarts it.
      export default {
        mounted() {
          if (!this.el.dataset.dismissAfter) return;
          this.text = this.el.textContent;
          this.hovered = false;
          this.focused = false;
          this.el.addEventListener("pointerenter", () =>
            this.hold({ hovered: true }),
          );
          this.el.addEventListener("pointerleave", () =>
            this.hold({ hovered: false }),
          );
          this.el.addEventListener("focusin", () => this.hold({ focused: true }));
          this.el.addEventListener("focusout", (e) => {
            if (!this.el.contains(e.relatedTarget)) this.hold({ focused: false });
          });
          this.restart();
        },
        updated() {
          if (!this.el.dataset.dismissAfter || this.el.textContent === this.text)
            return;
          this.text = this.el.textContent;
          this.restart();
        },
        destroyed() {
          clearTimeout(this.timer);
        },
        restart() {
          clearTimeout(this.timer);
          this.timer = null;
          this.remaining = Number(this.el.dataset.dismissAfter);
          this.schedule();
        },
        hold(state) {
          Object.assign(this, state);
          this.schedule();
        },
        schedule() {
          if (this.timer) {
            clearTimeout(this.timer);
            this.remaining -= performance.now() - this.startedAt;
            this.timer = null;
          }
          if (this.hovered || this.focused) return;
          this.startedAt = performance.now();
          this.timer = setTimeout(
            () => {
              this.timer = null;
              // Disconnected: the rejoin renders without the flash anyway.
              this.pushEvent("lv:clear-flash", {
                key: this.el.dataset.flashKey,
              }).catch(() => {});
            },
            Math.max(0, this.remaining),
          );
        },
      };
    </script>
    """
  end

  defp flash_message(%{message: message}), do: message
  defp flash_message(message), do: message

  defp flash_path(%{path: path}), do: path
  defp flash_path(_message), do: nil

  defp flash_action(%{action: action}), do: action
  defp flash_action(_message), do: nil

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * Multi-line text is `MythweaverWeb.CoreComponents.Editor.editor/1`, not an input type

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://phoenix-html.hexdocs.pm/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text time url week hidden)

  attr :field, FormField, doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"

  attr :rest, :global, include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  slot :hint, doc: "one-paragraph help, phrasing HTML allowed, shown by a `?` after the label (`hint/1`)"

  def input(%{field: %FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error/1))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div>
      <label for={@id}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span>
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "input-check"}
            aria-invalid={@errors != [] && "true"}
            {@rest}
          />{@label}
          <.hint :if={@hint != []} id={"#{@id}-hint"}>{render_slot(@hint)}</.hint>
        </span>
      </label>

      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div>
      <label for={@id}>
        <span :if={@label}>{@label}
        <.hint :if={@hint != []} id={"#{@id}-hint"}>{render_slot(@hint)}</.hint></span>
        <select
          id={@id}
          name={@name}
          class={@class || "input"}
          multiple={@multiple}
          aria-invalid={@errors != [] && "true"}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Form.options_for_select(@options, @value)}
        </select>
      </label>

      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedCSS}>
      .input {
        display: block;
        width: 100%;
        font: inherit;
        color: var(--foreground);
        background: var(--surface-2);
        border: 1px solid var(--input);
        border-radius: var(--radius-2);
        padding: var(--size-2);
      }

      input[type="checkbox"].input-check {
        display: inline-block;
        width: auto;
        margin-right: var(--size-1);
      }

      /* `data-unsaved`: a field edited but not saved yet (the `UnsavedChanges` hook,
         `assets/js/hooks/unsaved_changes.ts`), on the control and its labels. Global because it
         reaches every `<.input>` and `<.editor>` in any guarded form. */
      :is(input, select)[data-unsaved] {
        border-color: var(--primary-accent);
        box-shadow: 0 0 0 1px var(--primary-accent);
      }

      input[type="checkbox"][data-unsaved] {
        outline: 2px solid var(--primary-accent);
        outline-offset: 1px;
      }

      label[data-unsaved]::before {
        content: "";
        display: inline-block;
        inline-size: 0.5em;
        block-size: 0.5em;
        margin-inline-end: var(--size-1);
        border-radius: 50%;
        background: var(--primary-accent);
        vertical-align: middle;
      }
    </style>
    <div class="input-wrapper">
      <label for={@id}>
        <span :if={@label}>{@label}
        <.hint :if={@hint != []} id={"#{@id}-hint"}>{render_slot(@hint)}</.hint></span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Form.normalize_value(@type, @value)}
          class={@class || "input"}
          aria-invalid={@errors != [] && "true"}
          {@rest}
        />
      </label>

      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Helper used by inputs and `CoreComponents.Editor` to generate form errors
  @doc false
  def error(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      :scope {
        margin: var(--size-1) 0 0;
        font-size: 0.8rem;
        color: var(--destructive);
      }
    </style>

    <p class="input-error">
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(Mythweaver.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(Mythweaver.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end

  @doc "First 160 characters of `content`, with an ellipsis when cut; `\"\"` for nil."
  def preview_text(nil), do: ""

  def preview_text(content) when is_binary(content) do
    if String.length(content) > 160, do: String.slice(content, 0, 160) <> "…", else: content
  end

  @doc """
  Render our logo
  """
  def logo(assigns) do
    assigns = assign(assigns, :logo, Mythweaver.Branding.logo_svg())

    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      :scope {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        line-height: 0;

        svg {
          width: 1em;
          height: 1em;
        }
      }
    </style>
    <span class="logo">
      {Phoenix.HTML.raw(@logo)}
    </span>
    """
  end
end
