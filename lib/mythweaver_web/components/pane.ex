defmodule MythweaverWeb.Pane do
  @moduledoc """
  The two-pane editor layout every manager screen shares: a list `<nav>` on the left (a header with
  optional switches to sibling screens, an actions cluster such as a "New" button, and a stream of
  patch links with the selected row marked `aria-current="page"`), and the selected item's editor
  `<section>` on the right. With nothing selected (the `:index` action) the editor slot holds
  `pane_placeholder/1` instead of a form.

  Each piece owns its CSS, so no LiveView repeats list or header rules. An editor's title bar is
  `<.panel_header sticky>` (`MythweaverWeb.CoreComponents.Header`). `pane_search/1` plus `search/3`
  give a list an optional search box above its rows. `pane_section/1` divides the editor surface
  into rule-separated blocks.
  """

  use MythweaverWeb, :html

  import MythweaverWeb.BulkComponents, only: [bulk_check: 1]
  import Phoenix.LiveView, only: [stream: 4]

  alias Mythweaver.Export
  alias Phoenix.HTML.Form
  alias Phoenix.LiveView.Socket

  slot :list, required: true do
    attr :id, :string, required: true
    attr :label, :string, required: true
  end

  slot :editor, required: true do
    attr :id, :string, required: true
  end

  def pane_layout(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      div:scope {
        flex: 1 1 auto;
        min-height: 0;
        padding: var(--panel-gap);
        display: grid;
        grid-template-columns: minmax(14rem, 18rem) minmax(0, 1fr);
        gap: var(--panel-gap);
      }

      .pane-list {
        background: var(--card);
        border: 1px solid var(--border);
        border-radius: var(--radius-3);
        box-shadow: var(--elevation-lg);
        overflow-y: auto;
        min-height: 0;
        display: flex;
        flex-direction: column;
      }

      .pane-editor {
        overflow-y: auto;
        min-height: 0;
        display: flex;
        flex-direction: column;
        background: var(--card);
        border: 1px solid var(--border);
        border-radius: var(--radius-3);
        box-shadow: var(--elevation-lg);
      }

      .pane-phone-bar {
        display: none;
      }

      /* Phones: the editor fills the screen and the list opens as a drawer from the bar above it. */
      @media (--phone) {
        div:scope {
          grid-template-columns: minmax(0, 1fr);
          grid-template-rows: auto minmax(0, 1fr);
        }

        .pane-phone-bar {
          display: flex;
          align-items: center;
        }
      }
    </style>
    <div class="pane-layout">
      <div :for={list <- @list} class="pane-phone-bar">
        <.drawer_toggle
          for={list.id}
          breakpoint="phone"
          label={list.label}
          icon={false}
          id={"#{list.id}-toggle"}
        >
          <.lucide name="panel-left" /> {list.label}
        </.drawer_toggle>
      </div>
      <nav
        :for={list <- @list}
        id={list.id}
        class="pane-list drawer drawer--start drawer--phone"
        popover
        data-drawer-swipe
        aria-label={list.label}
      >
        {render_slot(list)}
      </nav>
      <section :for={editor <- @editor} id={editor.id} class="pane-editor">
        {render_slot(editor)}
      </section>
    </div>
    """
  end

  attr :title, :string, required: true

  slot :switch do
    attr :navigate, :string, required: true
    attr :id, :string, required: true
  end

  def pane_header(assigns) do
    ~H"""
    <%!-- `.pane-switches` is a root tag of `panel_header`'s slot, so it is itself a scope root. --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      div.pane-switches:scope {
        display: flex;
        gap: var(--size-1);
      }
    </style>
    <%!-- `wrap`: the 14-18rem list is too narrow for a long title ("Custom outlets") beside the switches. --%>
    <.panel_header wrap>
      {@title}
      <:actions :if={@switch != []}>
        <div class="pane-switches">
          <.button :for={s <- @switch} size="sm" navigate={s.navigate} id={s.id}>
            {render_slot(s)}
          </.button>
        </div>
      </:actions>
    </.panel_header>
    """
  end

  slot :inner_block, required: true, doc: "the controls, usually `<.button>`s"

  @doc """
  The cluster of controls at the top of a list pane, under its header: a wrapping row with the
  pane's own padding. It styles only the row; the content is the caller's.
  """
  def pane_actions(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      div:scope {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: var(--size-2);
        padding: var(--size-2);
        justify-content: center;
      }
    </style>
    <div class="pane-actions">
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :id, :string, required: true, doc: "form id; the query input is `<id>-query`"
  attr :form, Form, required: true, doc: "carries a `query` field"
  attr :placeholder, :string, default: nil
  attr :event, :string, default: "filter", doc: "the change and submit event"

  slot :inner_block,
    doc: "extra filter fields (e.g. a select)"

  @doc """
  The list's search box, a `phx-change` form on `event` (default `"filter"`). The LiveView owns the
  event and narrows its stream with `search/3`. Submit is wired to the same event so Enter does not
  reload the page.
  """
  def pane_search(assigns) do
    ~H"""
    <%!--
      `lower-bound="none"`: rules here may reach inside `<.input>`'s own template. The root
      `div` exists because `<.form>` is a component, not a tag, so it could not carry this block's
      scope marker.
    --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      div.pane-search:scope {
        padding: 0 var(--size-2) var(--size-2);
      }

      .pane-search-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .pane-search-form label {
        display: block;
      }
    </style>
    <div class="pane-search">
      <.form
        for={@form}
        id={@id}
        class="pane-search-form"
        phx-change={@event}
        phx-submit={@event}
      >
        <.input
          field={@form[:query]}
          type="text"
          label={pgettext("field label: filter a pane's list", "Search")}
          id={"#{@id}-query"}
          placeholder={@placeholder}
        />
        {render_slot(@inner_block)}
      </.form>
    </div>
    """
  end

  @doc """
  Keeps the items whose `fields` (a 1-arity fn returning strings or `nil`s) contain `query`,
  case-insensitively. A blank query keeps everything.
  """
  @spec search([item], String.t() | nil, (item -> [String.t() | nil])) :: [item] when item: var
  def search(items, query, fields) do
    query
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> case do
      "" ->
        items

      needle ->
        Enum.filter(items, fn item ->
          item |> fields.() |> Enum.any?(&(&1 && String.contains?(String.downcase(&1), needle)))
        end)
    end
  end

  @doc "Assigns the search state `pane_search/1` renders: each key as an assign, plus `filter_form`."
  @spec assign_filter(Socket.t(), map(), [atom()]) :: Socket.t()
  def assign_filter(socket, params \\ %{}, keys \\ [:query]) do
    values = Map.new(keys, &{&1, params[Atom.to_string(&1)] || ""})

    socket
    |> assign(values)
    |> assign(filter_form: to_form(Map.new(values, fn {k, v} -> {Atom.to_string(k), v} end)))
  end

  @doc """
  Streams `items` narrowed by `search/3` against the `:query` assign, setting `<name>_empty?` and
  `<name>_ids` (the listed ids, which a `MythweaverWeb.Bulk.Spec`'s `ids` reads).

  When the listed ids are unchanged (a bulk select toggle, a save that kept the row set), the rows
  are re-inserted in place instead of resetting the stream: a reset removes and re-adds every row,
  which loses the list's scroll position and the focused control.
  """
  @spec stream_search(Socket.t(), atom(), [item], (item -> [String.t() | nil])) ::
          Socket.t()
        when item: var
  def stream_search(socket, name, items, fields),
    do: stream_rows(socket, name, search(items, socket.assigns.query, fields))

  @doc "Streams `items` as `stream_search/4` does, without narrowing them."
  @spec stream_rows(Socket.t(), atom(), [map()]) :: Socket.t()
  def stream_rows(socket, name, items) do
    ids = Enum.map(items, & &1.id)
    reset? = Map.get(socket.assigns, :"#{name}_ids") != ids

    socket
    |> assign(:"#{name}_empty?", items == [])
    |> assign(:"#{name}_ids", ids)
    |> stream(name, items, reset: reset?)
  end

  attr :id, :string, required: true
  slot :inner_block, required: true, doc: "the prompt, e.g. \"Select a character, or create one.\""

  @doc """
  The editor slot's content while nothing is selected (a screen's `:index` action): a centered
  prompt to pick a row from the list or create one.
  """
  def pane_placeholder(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      div:scope {
        flex: 1 1 auto;
        display: flex;
        flex-direction: column;
        align-items: center;
        justify-content: center;
        gap: var(--size-3);
        padding: var(--size-6) var(--size-4);
        color: var(--muted-foreground);
        text-align: center;
      }

      .pane-placeholder-icon {
        font-size: var(--font-size-6);
        line-height: 0;
      }

      .pane-placeholder-text {
        margin: 0;
      }
    </style>
    <div id={@id} class="pane-placeholder">
      <span class="pane-placeholder-icon"><.lucide name="mouse-pointer-click" /></span>
      <p class="pane-placeholder-text">{render_slot(@inner_block)}</p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :rows, :any, required: true, doc: "a `@streams.x` stream"
  attr :patch, :any, required: true, doc: "1-arity fn from a row to its edit path"
  attr :selected_id, :any, default: nil
  attr :empty?, :boolean, required: true
  attr :empty, :string, required: true
  attr :bulk, :any, default: nil, doc: "a `MythweaverWeb.Bulk` state: its select mode turns rows into boxes"
  attr :bulk_list, :string, default: nil, doc: "the bulk spec name of these rows"
  slot :inner_block, required: true

  def pane_items(assigns) do
    ~H"""
    <%!--
      `lower-bound="none"`: the caller's spans sit inside each row's `<a>`, a `<.link>` root carrying
      `phx-r` that the default exclusive bound cuts off. With no lower bound every element carrying
      this block's marker is a scope root, so root rules are class-qualified.
    --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      p.pane-empty:scope {
        margin: 0;
        padding: 0 var(--size-2);
        color: var(--muted-foreground);
      }

      ul.pane-items:scope {
        list-style: none;
        margin: 0;
        padding: 0 var(--size-1) var(--size-2);
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
      }

      .pane-item {
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
        padding: var(--size-2);
        border-radius: var(--radius-2);
        color: inherit;
        text-decoration: none;
        transition:
          background-color 250ms ease,
          color 250ms ease;
      }

      .pane-item:hover {
        background: var(--surface-4);
      }

      /* Same tint and colour as `.chat-picker-link--active` in chat_picker.ex. The name takes the
         primary colour by inheritance; the meta line keeps its own muted colour. */
      .pane-item[aria-current="page"] {
        background-color: color-mix(in oklab, var(--primary-accent) 13%, transparent);
        color: var(--primary-accent);
      }

      .pane-item-name {
        font-weight: 600;
        overflow-wrap: anywhere;
      }

      .pane-item-meta {
        color: var(--muted-foreground);
        font-size: 0.85rem;
      }

      .pane-item-badges {
        display: flex;
        flex-wrap: wrap;
        gap: var(--size-1);
      }

      /* Select mode: the box on the left, the row's usual column of lines beside it. */
      label.pane-item--check {
        flex-direction: row;
        align-items: flex-start;
        text-align: start;
      }

      .pane-item--check > input {
        flex: none;
        margin: 0.2em 0 0;
      }

      .pane-item-body {
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
        min-inline-size: 0;
      }

      @media (--coarse) {
        .pane-item {
          min-block-size: var(--touch-target);
          justify-content: center;
        }
      }
    </style>
    <p :if={@empty?} class="pane-empty">{@empty}</p>
    <ul
      id={@id}
      class="pane-items"
      phx-update="stream"
      phx-hook={@bulk && "RangeSelect"}
      data-range-event={@bulk && "bulk_range"}
    >
      <li :for={{dom_id, item} <- @rows} id={dom_id}>
        <.bulk_check
          :if={@bulk && @bulk.active?}
          bulk={@bulk}
          list={@bulk_list}
          id={item.id}
          class="pane-item pane-item--check"
        >
          <span class="pane-item-body">{render_slot(@inner_block, item)}</span>
        </.bulk_check>
        <.link
          :if={!(@bulk && @bulk.active?)}
          patch={@patch.(item)}
          class="pane-item"
          aria-current={item.id == @selected_id && "page"}
        >
          {render_slot(@inner_block, item)}
        </.link>
      </li>
    </ul>
    """
  end

  attr :id, :string, required: true
  attr :confirm, :string, required: true
  attr :rest, :global
  slot :inner_block, required: true

  def pane_delete(assigns) do
    ~H"""
    <.button size="sm" danger id={@id} data-confirm={@confirm} {@rest}>
      <.lucide name="trash" /> {render_slot(@inner_block)}
    </.button>
    """
  end

  attr :id, :string, required: true
  attr :kind, :atom, required: true, doc: "a `Mythweaver.Export.kinds/0` kind"
  attr :item, :any, required: true, doc: "the row being edited"
  attr :current_scope, :any, required: true

  @doc """
  An editor header's Export button: a link to `/export` with `item` preselected on its kind's tab
  (nothing downloads until the user picks a format there). Renders nothing for a row the export
  page would not offer (`Mythweaver.Export.exportable_row?/3`).
  """
  def pane_export(assigns) do
    ~H"""
    <.button
      :if={Export.exportable_row?(@current_scope, @kind, @item)}
      size="sm"
      id={@id}
      navigate={~p"/export?kind=#{@kind}&item=#{@item.id}"}
    >
      <.lucide name="download" /> Export
    </.button>
    """
  end

  attr :id, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  @doc """
  One rule-divided block of the editor surface. Wrap the form and each panel in one; callers keep
  their own inner styles (their `*-editor-body` wrapper is an ancestor, so their scoped rules still
  reach the content).
  """
  def pane_section(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      section:scope {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
        padding: var(--size-3);
        /* Every section draws the rule above it. The -1px tucks the first section's rule under
           the header's bottom border, so header→section and section→section each show exactly
           one line. */
        border-top: 1px solid var(--border-grey);
        margin-top: -1px;
      }
    </style>
    <section id={@id} class="pane-section" {@rest}>{render_slot(@inner_block)}</section>
    """
  end
end
