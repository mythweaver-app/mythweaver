defmodule MythweaverWeb.CoreComponents.TagInput do
  @moduledoc """
  Tag chips and the chip input every tag field, tag filter and keyword list uses.

  `tag_chip/1` is one tag: its namespace part tinted by a hue stable per namespace
  (`Mythweaver.Tags.namespace_hue/1`), and `→ ideal` when a sibling rule shows it as another tag.
  `plain` shows the text as is (a keyword, which has no namespace).

  `tag_input/1` is a chip list plus a typing entry, driven by the external `TagInput` hook
  (`assets/js/hooks/tag_input.ts`, which documents the DOM contract). Each chip carries a hidden
  input named `name` (a list name, e.g. `"tags[mine][]"`), and an always-present empty sentinel
  keeps the key in the params when every chip is removed, so callers drop `""`. The entry has no
  name and sits in a `phx-update="ignore"` wrapper; the hook shows a committed tag at once as a
  provisional chip and fires the form's `phx-change`, whose re-render replaces it with the server's
  chip (or drops it), so the form must have one and render `values` from what it posts. With
  nothing typed, the entry suggests the viewer's most-used tags.
  `mode="filter"` takes `-tag` excludes and
  `ns:*` wildcards; `max={1}` keeps a single value. `mode="keywords"` is a lore keyword list
  (`Mythweaver.Lore.Matcher`): plain chips, a `/regex/flags` keyword set in monospace and marked
  invalid when it does not compile, a comma typed inside a regex kept as text, and a pasted
  comma-separated list split into keywords.
  """

  use Phoenix.Component
  use Gettext, backend: Mythweaver.Gettext

  import Iconex, only: [lucide: 1]
  import MythweaverWeb.CoreComponents, only: [error: 1]
  import MythweaverWeb.CoreComponents.Hint, only: [hint: 1]

  alias Mythweaver.Lore.Matcher
  alias Mythweaver.Tags

  attr :text, :string, required: true
  attr :ideal, :string, default: nil, doc: "the text this one displays as, shown as `→ ideal`"
  attr :implied, :boolean, default: false, doc: "implied by a parent rule, not a hard tag"
  attr :exclude, :boolean, default: false, doc: "a filter's excluded tag"
  attr :invalid, :boolean, default: false
  attr :plain, :boolean, default: false, doc: "the text as is, no namespace (a keyword)"
  attr :regex, :boolean, default: false, doc: "a `/regex/flags` keyword, set in monospace"
  attr :rest, :global

  def tag_chip(assigns) do
    namespace = if assigns.plain, do: "", else: Tags.namespace(assigns.text)
    name = if namespace == "", do: assigns.text, else: String.replace_prefix(assigns.text, namespace <> ":", "")

    assigns =
      assign(assigns,
        namespace: namespace,
        name: name,
        style: if(namespace != "", do: "--tag-hue: #{Tags.namespace_hue(namespace)}")
      )

    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      :scope {
        display: inline-flex;
        align-items: baseline;
        gap: 0.15em;
        max-inline-size: 100%;
        padding: 0.05rem 0.45rem;
        border: 1px solid transparent;
        border-radius: var(--radius-round);
        font-size: 0.8rem;
        line-height: 1.4;
        overflow-wrap: anywhere;
        background: var(--muted);
        color: var(--foreground);
      }

      :scope.tag-chip-namespaced {
        color: oklch(from var(--primary-accent) l c var(--tag-hue));
        background: oklch(from var(--primary-accent) l c var(--tag-hue) / 0.14);
      }

      :scope.tag-chip-implied {
        border-style: dashed;
        border-color: currentColor;
        background: transparent;
        opacity: 0.75;
      }

      :scope.tag-chip-invalid {
        border-color: var(--destructive);
      }

      :scope.tag-chip-regex {
        font-family: var(--font-monospace-code, ui-monospace, monospace);
      }

      .tag-chip-ns {
        opacity: 0.8;
      }

      .tag-chip-ideal,
      .tag-chip-sign {
        opacity: 0.7;
      }
    </style>
    <span
      class={[
        "tag-chip",
        @namespace != "" && "tag-chip-namespaced",
        @implied && "tag-chip-implied",
        @invalid && "tag-chip-invalid",
        @regex && "tag-chip-regex"
      ]}
      style={@style}
      {@rest}
    >
      <span
        :if={@exclude}
        class="tag-chip-sign"
        aria-label={dpgettext("tags", "aria label: minus sign marking an excluded filter tag", "not")}
      >
        −
      </span>
      <span :if={@namespace != ""} class="tag-chip-ns">{@namespace}:</span>
      <span class="tag-chip-name">{@name}</span>
      <span :if={@ideal} class="tag-chip-ideal">→ {@ideal}</span>
    </span>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true, doc: "the full list input name, e.g. \"tags[mine][]\""
  attr :label, :string, default: nil
  attr :values, :list, default: []

  attr :vocabulary, :list,
    default: [],
    doc: "`[%{text:, ideal:, uses:}]` suggestions (`Mythweaver.Tags.vocabulary/2`)"

  attr :mode, :string, default: "tags", values: ~w(tags filter keywords)
  attr :max, :integer, default: nil
  attr :placeholder, :string, default: nil
  attr :implied, :list, default: [], doc: "texts implied by the values' parents, shown under the input"
  attr :errors, :list, default: []
  attr :invalid, :list, default: [], doc: "values to mark invalid (keywords mode adds regexes that do not compile)"

  attr :input_attrs, :list,
    default: [],
    doc:
      "extra attributes on every hidden value input (sentinel, chips, template chip), e.g. a per-input phx-change and phx-target"

  slot :hint, doc: "one-paragraph help shown by a `?` after the label"

  def tag_input(assigns) do
    ideals = Map.new(assigns.vocabulary, &{&1.text, &1.ideal})
    chips = assigns.values |> Enum.uniq() |> Enum.map(&chip(&1, assigns.mode, ideals))
    assigns = assign(assigns, ideals: ideals, chips: chips)

    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      :scope {
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
        min-inline-size: 0;
      }

      .tag-input-box {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: var(--size-1);
        padding: var(--size-1) var(--size-2);
        background: var(--surface-2);
        border: 1px solid var(--input);
        border-radius: var(--radius-2);
        /* The suggestion list spans the whole box, so a narrow entry beside many chips still gets
           a usable list that stays inside the pane. */
        position: relative;
      }

      .tag-input-box:focus-within {
        border-color: var(--ring);
      }

      .tag-input-chips {
        display: contents;
        list-style: none;
        margin: 0;
        padding: 0;
      }

      .tag-input-chips > li {
        display: inline-flex;
        align-items: center;
        gap: 0.1rem;
        max-inline-size: 100%;
        padding: 0;
      }

      .tag-input-remove {
        display: inline-flex;
        padding: 0.1rem;
        border: 0;
        background: none;
        color: var(--muted-foreground);
        cursor: pointer;
        font-size: 0.75rem;
        opacity: 0.7;
      }

      .tag-input-remove:hover,
      .tag-input-remove:focus-visible {
        opacity: 1;
      }

      .tag-input-entry-wrap {
        flex: 1 1 8rem;
        min-inline-size: 6rem;
      }

      .tag-input-entry {
        inline-size: 100%;
        padding: var(--size-1) 0;
        border: 0;
        outline: none;
        background: transparent;
        color: var(--foreground);
        font: inherit;
      }

      .tag-input-suggestions {
        position: absolute;
        inset-inline: 0;
        inset-block-start: calc(100% + var(--size-1));
        z-index: 20;
        max-block-size: 16rem;
        overflow-y: auto;
        margin: 0;
        padding: var(--size-1) 0;
        list-style: none;
        background: var(--surface-6);
        border: 1px solid var(--border);
        border-radius: var(--radius-2);
        box-shadow: var(--elevation-md);
      }

      .tag-input-suggestions[hidden] {
        display: none;
      }

      .tag-input-suggestions > li {
        padding: var(--size-1) var(--size-2);
        cursor: pointer;
      }

      .tag-input-suggestions > li[aria-selected="true"],
      .tag-input-suggestions > li:hover {
        background: var(--surface-8);
      }

      .tag-input-suggestion-ideal {
        margin-inline-start: var(--size-1);
        opacity: 0.6;
      }

      .tag-input-implied {
        display: flex;
        flex-wrap: wrap;
        align-items: baseline;
        gap: var(--size-1);
        font-size: 0.8rem;
        color: var(--muted-foreground);
      }
    </style>
    <div
      id={@id}
      class="tag-input"
      phx-hook="TagInput"
      data-name={@name}
      data-mode={@mode}
      data-max={@max}
      data-vocabulary={Jason.encode!(@vocabulary)}
    >
      <label :if={@label} for={"#{@id}-entry"} class="tag-input-label">
        <span>{@label}
        <.hint :if={@hint != []} id={"#{@id}-hint"}>{render_slot(@hint)}</.hint></span>
      </label>
      <input type="hidden" name={@name} value="" data-tag-sentinel {@input_attrs} />
      <div class="tag-input-box">
        <%!-- Keyed by value: the hook removes and appends chips itself, so index tracking would
        point an unchanged chip's skipped (`data-phx-skip`) icon at a node it already removed,
        leaving an empty, 300×150 `<svg>`. --%>
        <ul id={"#{@id}-chips"} class="tag-input-chips">
          <li :for={chip <- @chips} :key={chip.value} data-tag={chip.value}>
            <.tag_chip
              text={chip.text}
              ideal={chip.ideal}
              exclude={chip.exclude}
              invalid={chip.invalid or chip.value in @invalid}
              plain={@mode == "keywords"}
              regex={chip.regex}
            />
            <input type="hidden" name={@name} value={chip.value} {@input_attrs} />
            <button
              type="button"
              class="tag-input-remove"
              data-tag-remove
              aria-label={
                dpgettext(
                  "tags",
                  "aria label: button that removes this tag from the field",
                  "Remove %{tag_name}",
                  tag_name: chip.value
                )
              }
            >
              <.lucide name="x" />
            </button>
          </li>
        </ul>
        <%!-- The chip `TagInput` shows the moment a value is committed, before the `phx-change`
        re-render replaces it with the server's own (ideal, implied, regex and invalid marks).
        Template content is inert, so its input never posts. --%>
        <template data-tag-template>
          <li data-tag="">
            <.tag_chip text="" plain />
            <input type="hidden" name={@name} value="" {@input_attrs} />
            <button
              type="button"
              class="tag-input-remove"
              data-tag-remove
              aria-label={
                dpgettext("tags", "aria label: button that removes a tag not yet named", "Remove")
              }
            >
              <.lucide name="x" />
            </button>
          </li>
        </template>
        <div id={"#{@id}-entry-wrap"} class="tag-input-entry-wrap" phx-update="ignore">
          <input
            type="text"
            id={"#{@id}-entry"}
            class="tag-input-entry"
            autocomplete="off"
            placeholder={@placeholder}
            role="combobox"
            aria-autocomplete="list"
            aria-expanded="false"
            aria-controls={"#{@id}-suggestions"}
          />
          <ul id={"#{@id}-suggestions"} class="tag-input-suggestions" role="listbox" hidden></ul>
        </div>
      </div>
      <div :if={@implied != []} id={"#{@id}-implied"} class="tag-input-implied">
        <span>{dpgettext("tags", "field label: tags implied by the field's parent rules", "Implies:")}</span>
        <.tag_chip :for={text <- @implied} text={text} implied />
      </div>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  defp chip(value, "keywords", _ideals) do
    parsed = Matcher.parse_regex(value)

    %{
      value: value,
      text: value,
      exclude: false,
      ideal: nil,
      regex: parsed != :literal,
      invalid: match?({:error, _}, parsed)
    }
  end

  defp chip(value, mode, ideals) do
    {exclude, text} =
      case {mode, value} do
        {"filter", "-" <> rest} -> {true, rest}
        _ -> {false, value}
      end

    %{value: value, text: text, exclude: exclude, ideal: Map.get(ideals, text), regex: false, invalid: false}
  end
end
