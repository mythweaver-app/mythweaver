defmodule MythweaverWeb.MultiSelect do
  @moduledoc """
  A checkbox multi-select for a list of options inside a caller's form: a name search, an optional
  tag filter (the lists' `MythweaverWeb.TagFilter` chips, behind a tag toggle), one checkbox row per
  option, All/None buttons acting on the rows shown, a "Checked only" toggle, a "N selected" count
  and shift-click ranges (`RangeSelect`).

  It renders no `<form>` (it sits inside the caller's, and the HTML parser drops nested forms).
  The checkboxes post `name` with the caller's form, after an always-present `""` sentinel that keeps
  the key when nothing is checked, so the caller drops `""`. The search box and the tag chips carry
  their own `phx-change` and `phx-target`, so they reach this component and never fire the caller's
  `phx-change`; the caller's form still posts them (`<id>[query]`, `<id>[tag_filter][]`) on its own
  change and submit, so its handlers ignore unknown keys. They sit in a `[data-unsaved-ignore]`
  wrapper, so `UnsavedChanges` never counts them as edits.

  Filtering hides rows with the `hidden` attribute rather than dropping them, so a checked row the
  filter hides still posts. Shift-click ranges and All/None reach only the rows shown.

  "Checked only" shows the rows checked when it was turned on, a snapshot rather than the live
  selection, so unchecking a row leaves it in place to check again; turning it off and on again
  takes a new snapshot.

  **The caller's form needs a `phx-change` that passes the posted list back as `selected`.** Every
  LiveView re-render (a search keystroke included) resets each checkbox to the server-rendered
  `checked`, so the server must always know the live selection.

  Assigns (a LiveComponent does not enforce `attr`s):

    * `id` (required): the component's and the root's DOM id; also the filter inputs' param key.
    * `name` (required): the checkbox list name, ending in `[]`, e.g. `"settings[participant_ids][]"`.
    * `label` (required): the legend text.
    * `options` (required): `[{label, value}]`, the shape of `Characters.character_options/1`.
    * `selected` (required): the selected values (strings); `nil` is `[]`.
    * `errors`: translated error strings (default `[]`).
    * `empty`: the text shown when `options == []` (default `"Nothing to choose from"`).
    * `tag_kind`: a `Mythweaver.Tags.Tagging` kind (e.g. `:character`); `nil` (the default) hides
      the tag toggle.
    * `viewer_id`, `tag_graph`: required with `tag_kind`. They take `current_scope.user.id` and the
      caller's `@tag_graph`, matched as the lists' tag filters do.
    * `tag_vocabulary`: the caller's `@tag_vocabulary`, the chip input's suggestions (default `[]`).
    * `disabled`: read-only, so the boxes and All/None are disabled; search and filters still
      narrow the rows (default `false`).
    * `hint`: slot, help shown by a `?` after the legend.
    * `toolbar`: slot, the caller's own controls after Checked only (e.g. a "New …" button); with
      no `phx-target` they reach the LiveView.

  DOM ids: `<id>-query`, `<id>-tags-toggle`, `<id>-tag-filter` (with the chip input `<id>-tags`),
  `<id>-all`, `<id>-none`, `<id>-checked-only`, `<id>-count`, `<id>-options`, rows
  `<id>-option-<value>`, boxes `<id>-<value>`, and `<id>-empty`/`<id>-no-match`.
  """

  use MythweaverWeb, :live_component

  import MythweaverWeb.CoreComponents.Hint, only: [hint: 1]
  import MythweaverWeb.TagFilter, only: [tag_filter: 1]

  alias Mythweaver.Tags
  alias Mythweaver.Tags.Graph
  alias MythweaverWeb.Pane
  alias MythweaverWeb.TagFilter

  @closed_tags [tag_values: [], predicates: [], tag_errors: [], tag_invalid: []]

  @impl true
  def mount(socket) do
    {:ok, assign(socket, [query: "", tags_open?: false, item_tags: nil, checked_only: nil] ++ @closed_tags)}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:errors, fn -> [] end)
      |> assign_new(:empty, fn ->
        pgettext("empty state: a multi-select list with no options", "Nothing to choose from")
      end)
      |> assign_new(:tag_kind, fn -> nil end)
      |> assign_new(:viewer_id, fn -> nil end)
      |> assign_new(:tag_graph, fn -> nil end)
      |> assign_new(:tag_vocabulary, fn -> [] end)
      |> assign_new(:hint, fn -> [] end)
      |> assign_new(:toolbar, fn -> [] end)
      |> assign_new(:disabled, fn -> false end)

    selected = MapSet.new(List.wrap(socket.assigns.selected))
    count = Enum.count(socket.assigns.options, fn {_, value} -> MapSet.member?(selected, value) end)

    {:ok,
     socket
     |> assign(selected_set: selected, selected_count: count)
     |> assign_item_tags()
     |> assign_shown()}
  end

  @impl true
  def handle_event("filter", params, socket) do
    filter = Map.get(params, socket.assigns.id, %{})

    socket =
      if Map.has_key?(filter, "query"), do: assign(socket, query: filter["query"]), else: socket

    socket =
      if Map.has_key?(filter, "tag_filter") do
        %{values: values, predicates: predicates, errors: errors, invalid: invalid} = TagFilter.parse(filter)
        assign(socket, tag_values: values, predicates: predicates, tag_errors: errors, tag_invalid: invalid)
      else
        socket
      end

    {:noreply, socket |> assign_item_tags() |> assign_shown()}
  end

  # A closed tag filter never narrows the rows, as the lists' search toggles behave.
  def handle_event("toggle_tags", _params, %{assigns: %{tags_open?: true}} = socket) do
    {:noreply, socket |> assign([tags_open?: false] ++ @closed_tags) |> assign_shown()}
  end

  def handle_event("toggle_tags", _params, socket) do
    {:noreply, assign(socket, tags_open?: true)}
  end

  def handle_event("toggle_checked_only", _params, %{assigns: %{checked_only: nil}} = socket) do
    {:noreply, socket |> assign(checked_only: socket.assigns.selected_set) |> assign_shown()}
  end

  def handle_event("toggle_checked_only", _params, socket) do
    {:noreply, socket |> assign(checked_only: nil) |> assign_shown()}
  end

  # The options' expanded tags in the viewer's view, read only while chips are active and again
  # only after the option list or the tag graph changed.
  defp assign_item_tags(%{assigns: %{predicates: []}} = socket), do: socket

  defp assign_item_tags(socket) do
    %{options: options, tag_graph: graph, viewer_id: viewer, tag_kind: kind} = socket.assigns
    ids = Enum.map(options, &elem(&1, 1))

    case socket.assigns.item_tags do
      %{ids: ^ids, graph: ^graph} ->
        socket

      _ ->
        hard = Tags.tags_by_item(viewer, kind, ids)
        expanded = Map.new(ids, &{&1, Graph.expand(graph, Map.get(hard, &1, []))})
        assign(socket, item_tags: %{ids: ids, graph: graph, expanded: expanded})
    end
  end

  defp assign_shown(socket) do
    %{options: options, query: query, predicates: predicates, checked_only: checked} = socket.assigns

    shown =
      options
      |> Pane.search(query, &[elem(&1, 0)])
      |> filter_tags(predicates, socket.assigns)
      |> filter_checked(checked)

    assign(socket, shown: MapSet.new(shown, &elem(&1, 1)))
  end

  defp filter_checked(options, nil), do: options
  defp filter_checked(options, checked), do: Enum.filter(options, &MapSet.member?(checked, elem(&1, 1)))

  # `Graph.matches?/3` needs a `%Graph{}`, which a picker without `tag_kind` has none of.
  defp filter_tags(options, [], _assigns), do: options

  defp filter_tags(options, predicates, %{tag_graph: graph, item_tags: %{expanded: expanded}}) do
    Enum.filter(options, fn {_, value} ->
      Graph.matches?(graph, Map.get(expanded, value, MapSet.new()), predicates)
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      /* `block-size: 100%` fills a stretched cell (`field_row align="stretch"`), so pickers side by
         side share one height; under an auto-height parent it computes to auto. */
      fieldset:scope {
        box-sizing: border-box;
        block-size: 100%;
        margin: 0;
        padding: var(--size-2);
        min-inline-size: 0;
        border: 1px solid var(--border);
        border-radius: var(--radius-2);
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .multi-select-legend {
        padding: 0 var(--size-1);
      }

      .multi-select-search {
        display: flex;
        align-items: stretch;
        gap: var(--size-1);
      }

      /* A wrapper of this block's own: `<.input>`'s root carries `phx-r`, which the scope's lower
         bound excludes. */
      .multi-select-query {
        flex: 1 1 auto;
        min-inline-size: 0;
      }

      .multi-select-toolbar {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: var(--size-1);
      }

      .multi-select-count {
        margin-inline-start: auto;
        color: var(--muted-foreground);
        font-size: var(--font-size-0);
        white-space: nowrap;
      }

      .multi-select-options {
        list-style: none;
        margin: 0;
        padding: 0;
        max-block-size: 15rem;
        overflow-y: auto;
      }

      /* Never set `display` here, or `hidden` stops hiding a row. */
      .multi-select-options > li {
        padding: 0;
      }

      /* Tag-qualified: the chat forms' `label { display: block }` reaches every label in them, and
         ties on specificity; this nearer scope then wins. */
      label.multi-select-row {
        display: flex;
        align-items: center;
        gap: var(--size-2);
        padding: var(--size-1) var(--size-2);
        border-radius: var(--radius-2);
        cursor: pointer;

        &:hover {
          background: var(--surface-3);
        }

        &:has(input:checked) {
          background: color-mix(in oklab, var(--primary-accent) 10%, transparent);
        }

        &:has(input:disabled) {
          cursor: default;
          opacity: 0.6;
        }
      }

      .multi-select-name {
        min-inline-size: 0;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }

      .multi-select-empty {
        margin: 0;
        color: var(--muted-foreground);
        font-style: italic;
      }

      @media (--coarse) {
        label.multi-select-row {
          min-block-size: var(--touch-target);
        }
      }
    </style>
    <%!-- `inclusive`: `<.button>`'s root carries `phx-r`, which the default bound excludes. --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="inclusive">
      /* As tall as the search input beside it (the row stretches it) and as wide: the input's
         height is one line of the same font plus its `--size-2` padding and 1px borders. A
         stretched height does not feed `aspect-ratio`, hence the explicit width. */
      button.multi-select-tags-toggle {
        line-height: inherit;
        inline-size: calc(1lh + 2 * var(--size-2) + 2px);
      }
    </style>
    <fieldset id={@id} class="multi-select" phx-hook=".MultiSelect">
      <legend class="multi-select-legend">
        {@label}
        <.hint :if={@hint != []} id={"#{@id}-hint"}>{render_slot(@hint)}</.hint>
      </legend>
      <div class="multi-select-filter" data-unsaved-ignore>
        <div class="multi-select-search">
          <div class="multi-select-query">
            <.input
              type="search"
              id={"#{@id}-query"}
              name={"#{@id}[query]"}
              value={@query}
              placeholder={
                pgettext("placeholder: filter the options of a multi-select list", "Search")
              }
              aria-label={
                pgettext("aria label: filter field of a multi-select list", "Search %{list_label}",
                  list_label: @label
                )
              }
              autocomplete="off"
              phx-change="filter"
              phx-target={@myself}
              phx-debounce="150"
              aria-controls={"#{@id}-options"}
              data-select-query
            />
          </div>
          <.button
            :if={@tag_kind}
            icon
            id={"#{@id}-tags-toggle"}
            class="multi-select-tags-toggle"
            phx-click="toggle_tags"
            phx-target={@myself}
            aria-label={tags_toggle_label(@tags_open?)}
            title={tags_toggle_label(@tags_open?)}
            aria-controls={"#{@id}-tag-filter"}
            aria-pressed={to_string(@tags_open?)}
          >
            <.lucide name="tag" />
          </.button>
        </div>
        <div
          :if={@tags_open?}
          id={"#{@id}-tag-filter"}
          phx-mounted={JS.focus(to: "##{@id}-tags-entry")}
        >
          <.tag_filter
            id={"#{@id}-tags"}
            name={"#{@id}[tag_filter][]"}
            values={@tag_values}
            vocabulary={@tag_vocabulary}
            errors={@tag_errors}
            invalid={@tag_invalid}
            input_attrs={["phx-change": "filter", "phx-target": @myself]}
          />
        </div>
      </div>
      <div class="multi-select-toolbar">
        <.button size="sm" id={"#{@id}-all"} data-select="all" disabled={@options == [] or @disabled}>
          {pgettext("button: check every shown option of a multi-select list", "All")}
        </.button>
        <.button
          size="sm"
          id={"#{@id}-none"}
          data-select="none"
          disabled={@options == [] or @disabled}
        >
          {pgettext("button: uncheck every shown option of a multi-select list", "None")}
        </.button>
        <.button
          size="sm"
          id={"#{@id}-checked-only"}
          phx-click="toggle_checked_only"
          phx-target={@myself}
          aria-pressed={to_string(@checked_only != nil)}
          disabled={@options == []}
        >
          {pgettext("toggle: show only the checked options of a multi-select list", "Checked only")}
        </.button>
        {render_slot(@toolbar)}
        <span id={"#{@id}-count"} class="multi-select-count">
          {pngettext(
            "status: how many options of a multi-select list are checked",
            "%{selected_count} selected",
            "%{selected_count} selected",
            @selected_count,
            selected_count: Mythweaver.Format.number(@selected_count)
          )}
        </span>
      </div>
      <input type="hidden" name={@name} value="" />
      <p :if={@options == []} id={"#{@id}-empty"} class="multi-select-empty">{@empty}</p>
      <p
        :if={@options != [] and MapSet.size(@shown) == 0}
        id={"#{@id}-no-match"}
        class="multi-select-empty"
      >
        {if @checked_only && MapSet.size(@checked_only) == 0,
          do:
            pgettext(
              "empty state: multi-select list showing only checked options, none checked",
              "Nothing checked"
            ),
          else: pgettext("empty state: multi-select list filter matched nothing", "No matches")}
      </p>
      <%!-- No `phx-change` on the boxes: their input events are the caller's form's change. Only
      shown rows carry `data-range-id`, so ranges and All/None never reach a row the filter hides. --%>
      <ul
        :if={@options != []}
        id={"#{@id}-options"}
        class="multi-select-options"
        phx-hook="RangeSelect"
      >
        <li
          :for={{label, value} <- @options}
          id={"#{@id}-option-#{value}"}
          hidden={not MapSet.member?(@shown, value)}
        >
          <label class="multi-select-row">
            <input
              type="checkbox"
              id={"#{@id}-#{value}"}
              name={@name}
              value={value}
              checked={MapSet.member?(@selected_set, value)}
              data-range-id={MapSet.member?(@shown, value) && value}
              disabled={@disabled}
            />
            <span class="multi-select-name">{label}</span>
          </label>
        </li>
      </ul>
      <.error :for={msg <- @errors}>{msg}</.error>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".MultiSelect">
        // All/None set the shown boxes and fire one bubbling `input` from the last changed one, which
        // LiveView sends as the caller's form change (and `UnsavedChanges` sees as an edit). Arrow keys
        // move between the search and the shown boxes; Enter in the search never submits the form.
        export default {
          mounted() {
            this.el.addEventListener("click", (e) => {
              const button = e.target.closest("[data-select]");
              if (button && this.el.contains(button))
                this.setAll(button.dataset.select === "all");
            });

            this.el.addEventListener("keydown", (e) => {
              const target = e.target;

              if (target.matches("[data-select-query]")) {
                if (e.key === "Enter") {
                  e.preventDefault();
                } else if (e.key === "ArrowDown") {
                  const first = this.boxes()[0];
                  if (first) {
                    e.preventDefault();
                    first.focus();
                  }
                }
                return;
              }

              if (e.key !== "ArrowDown" && e.key !== "ArrowUp") return;
              const boxes = this.boxes();
              const index = boxes.indexOf(target);
              if (index === -1) return;
              e.preventDefault();

              if (e.key === "ArrowDown") {
                boxes[index + 1]?.focus();
              } else if (index === 0) {
                this.el.querySelector("[data-select-query]")?.focus();
              } else {
                boxes[index - 1].focus();
              }
            });
          },

          boxes() {
            return Array.from(
              this.el.querySelectorAll("input[type=checkbox][data-range-id]"),
            );
          },

          setAll(on) {
            const changed = this.boxes().filter((box) => box.checked !== on);
            changed.forEach((box) => (box.checked = on));
            changed.at(-1)?.dispatchEvent(new Event("input", { bubbles: true }));
          },
        };
      </script>
    </fieldset>
    """
  end

  defp tags_toggle_label(true), do: pgettext("tooltip: button that closes a list's tag filter", "Close tag filter")
  defp tags_toggle_label(false), do: pgettext("tooltip: button that opens a list's tag filter", "Filter by tags")
end
