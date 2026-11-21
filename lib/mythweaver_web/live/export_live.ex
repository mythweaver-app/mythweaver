defmodule MythweaverWeb.ExportLive do
  @moduledoc """
  The `/export` page: pick items of any kind, see what the export pulls in with them
  (`Mythweaver.Export.plan/2`), choose a format and download.

  The download can't come from a LiveView, so submitting the form validates the request here and
  then sets `phx-trigger-action`, which posts the same form to `MythweaverWeb.ExportController`.

  `?kind=…&item=<id>` preselects that item, which is how the editors' Export buttons link here.
  """
  use MythweaverWeb, :live_view

  alias Mythweaver.AI
  alias Mythweaver.Export
  alias MythweaverWeb.LiveSync

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(
       page_title: dpgettext("import_export", "page title: export items", "Export"),
       kind: :character,
       query: "",
       current: %{},
       selected: MapSet.new(),
       names: %{},
       summary: nil,
       formats: Export.formats(scope, []),
       form: to_form(%{"format" => "native", "sampler_model_id" => "", "include_bundle" => "true"}, as: :export),
       models: AI.list_models(scope),
       trigger_submit: false,
       exportables_empty?: true
     )
     |> stream_configure(:exportables, dom_id: &"exportables-#{&1.id}")
     |> stream(:exportables, [])
     |> LiveSync.attach([:characters, :lore, :prompts, :memory, :scripts, :ai], &sync/2)}
  end

  defp sync(socket, kinds) do
    socket = load_exportables(socket)

    if :ai in kinds,
      do: assign(socket, models: AI.list_models(socket.assigns.current_scope)),
      else: socket
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(kind: parse_kind(params["kind"]))
     |> load_exportables()
     |> preselect(params["item"])}
  end

  # `load_exportables/1` just reset the stream, so its rows already render the new selection.
  defp preselect(socket, nil), do: socket

  defp preselect(socket, id) do
    case Map.get(socket.assigns.current, id) do
      nil ->
        gettext_comment("Flash when the export page is opened for an item the user cannot export.")
        put_flash(socket, :error, dgettext("import_export", "That item can't be exported."))

      item ->
        socket |> add(socket.assigns.kind, item) |> selection_changed()
    end
  end

  defp parse_kind(value, fallback \\ :character) do
    Enum.find_value(Export.kinds(), fallback, fn {kind, _label} ->
      if Atom.to_string(kind) == value, do: kind
    end)
  end

  defp load_exportables(socket) do
    %{current_scope: scope, kind: kind, query: query} = socket.assigns
    needle = query |> String.trim() |> String.downcase()

    items =
      scope
      |> Export.exportables(kind)
      |> Enum.filter(&(needle == "" or String.contains?(String.downcase(&1.name), needle)))

    socket
    |> assign(current: Map.new(items, &{&1.id, &1}), exportables_empty?: items == [])
    |> stream(:exportables, items, reset: true)
  end

  @impl true
  def handle_event("filter", %{"query" => query}, socket) do
    {:noreply, socket |> assign(query: query) |> load_exportables()}
  end

  def handle_event("toggle", %{"id" => id} = params, socket) do
    # A summary row's remove button names its own kind; a list checkbox is the current tab's.
    kind = parse_kind(params["kind"], socket.assigns.kind)
    key = {kind, id}

    socket =
      if MapSet.member?(socket.assigns.selected, key) do
        update(socket, :selected, &MapSet.delete(&1, key))
      else
        add(socket, kind, Map.get(socket.assigns.current, id))
      end

    {:noreply, socket |> reinsert(kind, [id]) |> selection_changed()}
  end

  def handle_event("select_range", %{"ids" => ids}, socket) when is_list(ids) do
    %{kind: kind, current: current} = socket.assigns
    items = ids |> Enum.map(&Map.get(current, &1)) |> Enum.reject(&is_nil/1)
    socket = Enum.reduce(items, socket, &add(&2, kind, &1))
    {:noreply, socket |> reinsert(kind, Enum.map(items, & &1.id)) |> selection_changed()}
  end

  def handle_event("clear", _params, socket) do
    {:noreply,
     socket
     |> assign(selected: MapSet.new(), names: %{})
     |> load_exportables()
     |> selection_changed()}
  end

  def handle_event("change_format", %{"export" => params}, socket) do
    {:noreply, assign(socket, form: to_form(form_params(params, socket), as: :export))}
  end

  def handle_event("export", %{"export" => params}, socket) do
    params = form_params(params, socket)
    request_params = Map.put(params, "items", item_params(socket.assigns.selected))

    with {:ok, request} <- Export.request(request_params),
         {:ok, _plan} <- Export.plan(socket.assigns.current_scope, request) do
      send(self(), :reset_trigger)
      {:noreply, assign(socket, form: to_form(params, as: :export), trigger_submit: true)}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_info(:reset_trigger, socket), do: {:noreply, assign(socket, trigger_submit: false)}

  defp add(socket, _kind, nil), do: socket

  defp add(socket, kind, item) do
    socket
    |> update(:selected, &MapSet.put(&1, {kind, item.id}))
    |> update(:names, &Map.put(&1, {kind, item.id}, item.name))
  end

  # Re-render the rows shown on the current tab, so their boxes match the selection.
  defp reinsert(socket, kind, ids) do
    if kind == socket.assigns.kind do
      Enum.reduce(ids, socket, fn id, socket ->
        case Map.get(socket.assigns.current, id) do
          nil -> socket
          item -> stream_insert(socket, :exportables, item)
        end
      end)
    else
      socket
    end
  end

  defp selection_changed(socket) do
    %{current_scope: scope, selected: selected} = socket.assigns
    items = MapSet.to_list(selected)
    formats = Export.formats(scope, items)
    params = form_params(socket.assigns.form.params, socket, formats)

    summary =
      with true <- items != [],
           {:ok, request} <- Export.request(%{"items" => item_params(selected), "format" => "native"}),
           {:ok, plan} <- Export.plan(scope, request) do
        plan
      else
        _ -> nil
      end

    assign(socket, formats: formats, summary: summary, form: to_form(params, as: :export))
  end

  # The format falls back to native when the chosen one isn't available for the selection.
  defp form_params(params, socket, formats \\ nil) do
    formats = formats || socket.assigns.formats
    format = params["format"]
    format = if format in available_values(formats), do: format, else: "native"

    %{
      "format" => format,
      "sampler_model_id" => params["sampler_model_id"] || "",
      "include_bundle" => params["include_bundle"] || socket.assigns.form.params["include_bundle"] || "true"
    }
  end

  defp available_values(formats) do
    for %{available?: true, format: format} <- formats, do: Atom.to_string(format)
  end

  defp item_params(selected), do: Enum.map(selected, fn {kind, id} -> "#{kind}:#{id}" end)

  @impl true
  def render(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      /* The page is one panel. Its root is the scope root, so it needs `:scope`; the class keeps
         slot content (also scope roots, e.g. inside `<.form>`) from matching. */
      div.export-page:scope {
        margin: var(--panel-gap);
        border: 1px solid var(--border);
        border-radius: var(--radius-3);
        background: var(--card);
        box-shadow: var(--elevation-lg);
        overflow-y: auto;
      }

      .export-body {
        display: grid;
        grid-template-columns: minmax(0, 1fr) minmax(0, 22rem);
        gap: var(--size-4);
        padding: var(--size-4);
      }

      .export-pick,
      .export-side {
        display: flex;
        flex-direction: column;
        gap: var(--size-3);
        min-inline-size: 0;
      }

      .export-tabs {
        display: flex;
        flex-wrap: wrap;
        gap: var(--size-2);
      }

      .export-list {
        display: flex;
        flex-direction: column;
        margin: 0;
        padding: 0;
        list-style: none;
        border: 1px solid var(--border);
        border-radius: var(--radius-2);
      }

      .export-row + .export-row {
        border-block-start: 1px solid var(--border);
      }

      .export-row label {
        display: flex;
        gap: var(--size-2);
        align-items: center;
        padding: var(--size-2) var(--size-3);
        cursor: pointer;
      }

      .export-row-name {
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }

      .export-empty,
      .export-muted,
      p.export-reason:scope {
        color: var(--muted-foreground);
      }

      .export-empty {
        padding: var(--size-3);
      }

      .export-selected {
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
        margin: 0;
        padding: 0;
        list-style: none;
      }

      .export-selected li {
        display: flex;
        gap: var(--size-2);
        align-items: center;
        justify-content: space-between;
      }

      .export-warnings {
        margin: 0;
        padding-inline-start: var(--size-4);
        color: var(--muted-foreground);
      }

      /* Slot content of `<.form>`: a scope root of its own, so `:scope`. */
      div.export-actions:scope {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: var(--size-2);
      }

      @media (--phone) {
        .export-body {
          grid-template-columns: minmax(0, 1fr);
        }
      }
    </style>

    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="export-page">
        <.panel_header>
          {dpgettext("import_export", "heading: export items", "Export")}
          <:actions>
            <.button size="sm" navigate={~p"/import"} id="export-open-import">
              {dpgettext("import_export", "link: open the import page", "Import…")}
            </.button>
          </:actions>
        </.panel_header>
        <div class="export-body">
          <section class="export-pick">
            <nav
              class="export-tabs"
              aria-label={
                dpgettext(
                  "import_export",
                  "aria label: tabs choosing the kind of item to export",
                  "Kinds"
                )
              }
            >
              <.button
                :for={{kind, label} <- Export.kinds()}
                size="sm"
                variant={if kind == @kind, do: "primary", else: "secondary"}
                patch={~p"/export?kind=#{kind}"}
                id={"export-kind-#{kind}"}
                aria-current={kind == @kind && "page"}
              >
                {label}{count_suffix(@selected, kind)}
              </.button>
            </nav>

            <form id="export-filter-form" phx-change="filter" phx-submit="filter">
              <.input
                type="search"
                name="query"
                id="export-filter"
                value={@query}
                placeholder={
                  dpgettext(
                    "import_export",
                    "placeholder: filter exportable items by name",
                    "Filter by name"
                  )
                }
                phx-debounce="200"
              />
            </form>

            <ul
              id="exportables"
              class="export-list"
              phx-update="stream"
              phx-hook="RangeSelect"
              data-range-event="select_range"
            >
              <li :for={{dom_id, item} <- @streams.exportables} id={dom_id} class="export-row">
                <label>
                  <input
                    type="checkbox"
                    id={"export-check-#{item.id}"}
                    phx-click="toggle"
                    phx-value-id={item.id}
                    data-range-id={item.id}
                    checked={MapSet.member?(@selected, {@kind, item.id})}
                  />
                  <span class="export-row-name">{item.name}</span>
                </label>
              </li>
            </ul>
            <p :if={@exportables_empty?} id="exportables-empty" class="export-empty">
              {if @query == "",
                do:
                  dpgettext(
                    "import_export",
                    "empty state: no items of this kind to export",
                    "Nothing to export here yet."
                  ),
                else:
                  dpgettext(
                    "import_export",
                    "empty state: no exportable item matches the filter",
                    "Nothing matches the filter."
                  )}
            </p>
          </section>

          <aside class="export-side" id="export-summary">
            <.section_header>
              {dpgettext("import_export", "heading: items chosen for export", "Selected")}
            </.section_header>
            <p :if={MapSet.size(@selected) == 0} class="export-muted">
              {dgettext(
                "import_export",
                "Pick items on the left. Everything they depend on comes along."
              )}
            </p>
            <ul :if={MapSet.size(@selected) > 0} class="export-selected" id="export-selected">
              <li :for={{kind, id} <- sorted(@selected, @names)} id={"export-selected-#{id}"}>
                <span>
                  {dpgettext(
                    "import_export",
                    "status: kind and name of an item chosen for export",
                    "%{item_kind} · %{item_name}",
                    item_kind: kind_label(kind),
                    item_name: @names[{kind, id}]
                  )}
                </span>
                <.button
                  size="sm"
                  icon
                  aria-label={
                    dpgettext(
                      "import_export",
                      "aria label: icon button that removes an item from the export",
                      "Remove"
                    )
                  }
                  phx-click="toggle"
                  phx-value-id={id}
                  phx-value-kind={kind}
                >
                  <.lucide name="x" />
                </.button>
              </li>
            </ul>
            <p :if={@summary} class="export-muted" id="export-counts">
              {counts_text(@summary.counts)}
            </p>
            <ul :if={@summary && @summary.warnings != []} class="export-warnings" id="export-warnings">
              <li :for={warning <- @summary.warnings}>{warning}</li>
            </ul>

            <.form
              for={@form}
              id="export-form"
              action={~p"/export"}
              method="post"
              phx-change="change_format"
              phx-submit="export"
              phx-trigger-action={@trigger_submit}
            >
              <input
                :for={{kind, id} <- MapSet.to_list(@selected)}
                type="hidden"
                name="export[items][]"
                value={"#{kind}:#{id}"}
              />
              <.input
                type="select"
                field={@form[:format]}
                id="export-form-format"
                label={dpgettext("import_export", "field label: file format of an export", "Format")}
                options={for f <- @formats, f.available?, do: {f.label, Atom.to_string(f.format)}}
              />
              <.input
                :if={@form[:format].value != "native"}
                type="checkbox"
                field={@form[:include_bundle]}
                id="export-form-include_bundle"
                label={
                  dpgettext(
                    "import_export",
                    "field label: also embed Mythweaver's own data in an export",
                    "Include Mythweaver data"
                  )
                }
              />
              <p :for={f <- Enum.reject(@formats, & &1.available?)} class="export-reason">
                {dpgettext(
                  "import_export",
                  "status: export format and why it is unavailable",
                  "%{format_name}: %{unavailable_reason}",
                  format_name: f.label,
                  unavailable_reason: f.reason
                )}
              </p>
              <.input
                :if={@form[:format].value == "st_preset"}
                type="select"
                field={@form[:sampler_model_id]}
                id="export-form-sampler_model_id"
                label={
                  dpgettext(
                    "import_export",
                    "field label: model whose samplers an exported preset carries",
                    "Samplers from"
                  )
                }
                prompt={
                  dpgettext(
                    "import_export",
                    "option: export a preset without sampler values",
                    "No sampler"
                  )
                }
                options={Enum.map(@models, &{&1.name, &1.id})}
              />
              <div class="export-actions">
                <.button
                  variant="primary"
                  type="submit"
                  id="export-submit"
                  disabled={MapSet.size(@selected) == 0}
                >
                  <.lucide name="download" /> {dpgettext(
                    "import_export",
                    "button: download the export file",
                    "Download"
                  )}
                </.button>
                <.button :if={MapSet.size(@selected) > 0} phx-click="clear" id="export-clear">
                  {dpgettext("import_export", "button: clear the export selection", "Clear")}
                </.button>
              </div>
            </.form>
          </aside>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp count_suffix(selected, kind) do
    case Enum.count(selected, fn {k, _} -> k == kind end) do
      0 ->
        ""

      n ->
        dpgettext(
          "import_export",
          "unit: how many items of this kind are chosen, after the tab label",
          " (%{selected_count})",
          selected_count: Mythweaver.Format.number(n)
        )
    end
  end

  defp sorted(selected, names) do
    order = Export.kinds() |> Enum.with_index() |> Map.new(fn {{kind, _}, i} -> {kind, i} end)
    Enum.sort_by(selected, fn {kind, id} = key -> {order[kind], String.downcase(names[key] || ""), id} end)
  end

  defp kind_label(kind) do
    Enum.find_value(Export.kinds(), to_string(kind), fn {k, label} -> if k == kind, do: label end)
  end

  @count_keys ~w(character avatar lore_book lore_entry lore_pool prompt prompt_block prompt_outlet ai_model script
                 memory_profile side_prompt side_prompt_set chat message blob)a

  defp counts_text(counts) do
    parts =
      for key <- @count_keys, (n = Map.get(counts, key, 0)) > 0 do
        count_part(key, n, Mythweaver.Format.number(n))
      end

    if parts == [] do
      ""
    else
      gettext_comment(
        "What an export contains; the placeholder is a comma-separated list like “2 characters, 1 lore book”."
      )

      dpgettext("import_export", "status: summary of what an export contains", "Includes %{item_totals}.",
        item_totals: Enum.join(parts, ", ")
      )
    end
  end

  defp count_part(:character, n, f),
    do:
      dpngettext("import_export", "unit: items in an export", "%{item_count} character", "%{item_count} characters", n,
        item_count: f
      )

  defp count_part(:avatar, n, f),
    do:
      dpngettext("import_export", "unit: items in an export", "%{item_count} avatar", "%{item_count} avatars", n,
        item_count: f
      )

  defp count_part(:lore_book, n, f),
    do:
      dpngettext("import_export", "unit: items in an export", "%{item_count} lore book", "%{item_count} lore books", n,
        item_count: f
      )

  defp count_part(:lore_entry, n, f),
    do:
      dpngettext("import_export", "unit: items in an export", "%{item_count} entry", "%{item_count} entries", n,
        item_count: f
      )

  defp count_part(:lore_pool, n, f),
    do:
      dpngettext("import_export", "unit: items in an export", "%{item_count} pool", "%{item_count} pools", n,
        item_count: f
      )

  defp count_part(:prompt, n, f),
    do:
      dpngettext("import_export", "unit: items in an export", "%{item_count} prompt", "%{item_count} prompts", n,
        item_count: f
      )

  defp count_part(:prompt_block, n, f),
    do:
      dpngettext("import_export", "unit: items in an export", "%{item_count} block", "%{item_count} blocks", n,
        item_count: f
      )

  defp count_part(:prompt_outlet, n, f),
    do:
      dpngettext("import_export", "unit: items in an export", "%{item_count} outlet", "%{item_count} outlets", n,
        item_count: f
      )

  defp count_part(:ai_model, n, f),
    do:
      dpngettext("import_export", "unit: items in an export", "%{item_count} AI model", "%{item_count} AI models", n,
        item_count: f
      )

  defp count_part(:script, n, f),
    do:
      dpngettext("import_export", "unit: items in an export", "%{item_count} script", "%{item_count} scripts", n,
        item_count: f
      )

  defp count_part(:memory_profile, n, f),
    do:
      dpngettext(
        "import_export",
        "unit: items in an export",
        "%{item_count} memory profile",
        "%{item_count} memory profiles",
        n, item_count: f)

  defp count_part(:side_prompt, n, f),
    do:
      dpngettext(
        "import_export",
        "unit: items in an export",
        "%{item_count} side prompt",
        "%{item_count} side prompts",
        n, item_count: f)

  defp count_part(:side_prompt_set, n, f),
    do:
      dpngettext(
        "import_export",
        "unit: items in an export",
        "%{item_count} side prompt set",
        "%{item_count} side prompt sets",
        n, item_count: f)

  defp count_part(:chat, n, f),
    do:
      dpngettext("import_export", "unit: items in an export", "%{item_count} chat", "%{item_count} chats", n,
        item_count: f
      )

  defp count_part(:message, n, f),
    do:
      dpngettext("import_export", "unit: items in an export", "%{item_count} message", "%{item_count} messages", n,
        item_count: f
      )

  defp count_part(:blob, n, f),
    do:
      dpngettext("import_export", "unit: items in an export", "%{item_count} file", "%{item_count} files", n,
        item_count: f
      )
end
