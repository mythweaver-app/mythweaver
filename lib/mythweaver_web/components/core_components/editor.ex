defmodule MythweaverWeb.CoreComponents.Editor do
  @moduledoc """
  The app's multi-line field: a CodeMirror 6 source editor (the `RichInput` hook,
  `assets/js/hooks/rich_input/`). Not WYSIWYG; `language` picks the highlighting:

    * `"markdown"`: GFM plus role-play marks (`"dialogue"`, `*actions*`), list continuation,
      auto-pairing and Mod-B/I wrapping.
    * `"liquid"`: the same Markdown with Solid/Liquid inside it and autocomplete from
      `completions` (`Mythweaver.Prompts.Completions.template/1`) plus Liquid's standard tags and
      filters, and hover docs for the variables, property paths, filters and tags in a template.
    * `"json"`: JSON highlighting and bracket matching, monospace.
    * `"lua"`: Lua highlighting (CodeMirror legacy mode), bracket matching, monospace,
      autocomplete and hover docs for keywords, the sandbox's standard library, declared locals
      and, from `completions` (`Mythweaver.Scripts.Completions.lua/1`), `event` fields and host
      functions.
    * `"css"`: CSS highlighting (CodeMirror legacy mode), bracket matching, monospace.

  In the code languages (`json`, `lua`, `css`) Tab accepts an open completion or indents and Shift-Tab
  dedents; Escape then Tab leaves the field. Elsewhere Tab leaves the field.

  It grows from `rows` to `max_rows` lines, then scrolls. `line_numbers` adds a line-number gutter
  and `spellcheck` turns on the browser's spell checking; both are independent of `language`.

  DOM: the wrapper (`id`, `phx-hook`) carries the server value in `data-value`. The named
  `<textarea>` that forms serialize sits hidden inside a `phx-update="ignore"` div, so LiveView never
  patches its value under the editor; the hook writes it on every edit and fires `input` for
  `phx-change`. The hook applies a changed `data-value` only when it is not an echo of its own edits.

  Styles are global (`MythweaverWeb.ColocatedCSS`) so a caller's `div.<class>` rule wins on
  specificity; `class` lands on the bordered box.
  """

  use Phoenix.Component

  import MythweaverWeb.CoreComponents, only: [error: 1, translate_error: 1]
  import MythweaverWeb.CoreComponents.Hint, only: [hint: 1]

  alias Phoenix.HTML.FormField

  attr :id, :any, default: nil
  attr :name, :any
  attr :value, :any
  attr :field, FormField, doc: "a form field struct retrieved from the form, e.g. @form[:content]"
  attr :errors, :list, default: []
  attr :label, :string, default: nil
  attr :language, :string, default: "markdown", values: ~w(markdown liquid json lua css)

  attr :completions, :map,
    default: nil,
    doc:
      ~s|`Mythweaver.Prompts.Completions.template/1` for `language="liquid"`, `Mythweaver.Scripts.Completions.lua/1` for `"lua"`. A liquid map with an `:inline_lua` key (`Scripts.Completions.lua(:inline)`) also parses `{! … !}` blocks as Lua: highlighting, completion, hover, mono font, no spellcheck|

  attr :rows, :integer, default: 3
  attr :max_rows, :integer, default: 20
  attr :placeholder, :string, default: nil
  attr :debounce, :string, default: nil
  attr :autofocus, :boolean, default: false
  attr :caret, :integer, default: nil, doc: "initial cursor offset, in UTF-16 code units"
  attr :caret_end, :integer, default: nil, doc: "with `caret`, the initial selection runs `caret..caret_end`"

  attr :submit_on_enter, :boolean,
    default: false,
    doc:
      "Enter submits a non-blank form; in a liquid editor, not while a block is open (`open_blocks.ts`); " <>
        "never where the caller's CSS sets `--rich-input-enter: newline` (`submitKeymap`)"

  attr :submit_on_escape, :boolean, default: false
  attr :line_numbers, :boolean, default: false, doc: "show a line-number gutter"

  attr :spellcheck, :boolean,
    default: false,
    doc: "browser spell checking, autocorrect and sentence autocapitalization; for prose fields"

  attr :class, :any,
    default: nil,
    doc: "layout/chrome hook on the bordered box; override with a `div.<class>` rule"

  slot :hint, doc: "one-paragraph help, phrasing HTML allowed, shown by a `?` after the label (`hint/1`)"

  slot :meta,
    doc: "a short muted line between the label and the box, at its upper left (e.g. a token count)"

  def editor(%{field: %FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error/1))
    |> assign_new(:name, fn -> field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> editor()
  end

  def editor(assigns) do
    assigns = assign(assigns, :text, if(is_nil(assigns.value), do: "", else: to_string(assigns.value)))

    ~H"""
    <style :type={MythweaverWeb.ColocatedCSS}>
      .rich-input-field > label {
        display: block;
      }

      .rich-input {
        display: block;
        width: 100%;
        line-height: 1.5;
        min-block-size: calc(var(--rich-input-rows) * 1lh + 2 * var(--size-2) + 2px);
        color: var(--foreground);
        background: var(--surface-2);
        border: 1px solid var(--input);
        border-radius: var(--radius-2);
        padding: var(--size-2);
        cursor: text;
      }

      .rich-input:focus-within {
        outline: 2px solid var(--ring);
        outline-offset: 2px;
      }

      /* An edit not saved yet: the `UnsavedChanges` hook marks the box for its hidden textarea. */
      .rich-input[data-unsaved] {
        border-color: var(--primary-accent);
        box-shadow: 0 0 0 1px var(--primary-accent);
      }

      .rich-input-meta {
        margin-block-end: var(--size-1);
        color: var(--muted-foreground);
        font-size: var(--font-size-0);
      }
    </style>
    <div class="rich-input-field">
      <label :if={@label} id={"#{@id}-label"} for={"#{@id}-value"}>
        {@label}
        <.hint :if={@hint != []} id={"#{@id}-hint"}>{render_slot(@hint)}</.hint>
      </label>
      <div :if={@meta != []} id={"#{@id}-meta"} class="rich-input-meta">{render_slot(@meta)}</div>
      <div
        id={@id}
        phx-hook="RichInput"
        class={["rich-input", @class]}
        style={"--rich-input-rows: #{@rows}; --rich-input-max-rows: #{@max_rows}"}
        data-value={@text}
        data-language={@language}
        data-completions={@completions && Jason.encode!(@completions)}
        data-placeholder={@placeholder}
        data-autofocus={@autofocus}
        data-caret={@caret}
        data-caret-end={@caret_end}
        data-submit-on-enter={@submit_on_enter}
        data-submit-on-escape={@submit_on_escape}
        data-line-numbers={@line_numbers}
        data-spellcheck={@spellcheck}
        data-label={@label && "#{@id}-label"}
        aria-invalid={@errors != [] && "true"}
      >
        <div id={"#{@id}-view"} class="rich-input-view" phx-update="ignore" data-rich-input-view>
          <textarea id={"#{@id}-value"} name={@name} hidden phx-debounce={@debounce}>{Phoenix.HTML.Form.normalize_value("textarea", @text)}</textarea>
        </div>
      </div>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end
end
