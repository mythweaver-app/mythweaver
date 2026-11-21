defmodule MythweaverWeb.Search do
  @moduledoc """
  The search overlay: Mod-K searches everything (`Mythweaver.Search`), Mod-F searches the page's
  own scope. `Layouts.app` renders it on every page; `local` is the page's scope (`nil` when the
  page has none, so Mod-F falls through to the browser's find):
  `{:chat, chat}`, `{:lore_book, book}`, `:lore`, `:characters`, `:prompts`, `:scripts`, `:memory`
  or `:ai`.

  `MythweaverWeb.Shortcuts`' listener owns both keys and dispatches `shortcuts:search` with the
  mode. A message hit in the chat being viewed jumps there through the LiveView's
  `{MythweaverWeb.Search, :chat_event, "jump_to_message", params}` message; every other hit
  navigates (a message to `/chats/:id?message=:id`).
  """

  use MythweaverWeb, :live_component

  alias Mythweaver.Search
  alias Mythweaver.Search.Query

  @closed [
    open?: false,
    mode: :global,
    kind: nil,
    query: "",
    groups: [],
    rows: [],
    selected: 0
  ]

  @global_limit 5
  @local_limit 25
  @kind_limit 50

  @kind_icons %{
    chat: "messages-square",
    message: "message-square",
    character: "user",
    lore_book: "book",
    lore_entry: "scroll-text",
    prompt: "file-text",
    prompt_block: "blocks",
    prompt_outlet: "plug",
    script: "code",
    side_prompt: "sparkles",
    memory_profile: "brain",
    ai_model: "cpu",
    ai_provider: "server"
  }

  # The content area whose editors open each owned kind (`MythweaverWeb.ContentAccess`).
  @content_areas %{
    character: :characters,
    lore_book: :lore,
    lore_entry: :lore,
    prompt: :prompts,
    prompt_block: :prompts,
    prompt_outlet: :prompts,
    script: :scripts,
    side_prompt: :memory,
    memory_profile: :memory
  }

  @impl true
  def mount(socket), do: {:ok, assign(socket, @closed)}

  # A page whose scope changed under an open local search would show the old page's results.
  @impl true
  def update(assigns, socket) do
    old = local_key(socket.assigns[:local])
    socket = assign(socket, current_scope: assigns[:current_scope], local: assigns[:local])

    if socket.assigns.open? and socket.assigns.mode == :local and local_key(socket.assigns.local) != old,
      do: {:ok, assign(socket, @closed)},
      else: {:ok, socket}
  end

  defp local_key({:chat, chat}), do: {:chat, chat.id}
  defp local_key({:lore_book, book}), do: {:lore_book, book.id}
  defp local_key(local), do: local

  @impl true
  def handle_event(_event, _params, %{assigns: %{current_scope: nil}} = socket), do: {:noreply, socket}

  def handle_event("open", %{"mode" => mode}, socket) when mode in ["global", "local"] do
    mode = if mode == "local" and socket.assigns.local != nil, do: :local, else: :global

    cond do
      not socket.assigns.open? ->
        {:noreply, socket |> assign(@closed) |> assign(open?: true, mode: mode)}

      socket.assigns.mode == mode ->
        {:noreply, assign(socket, @closed)}

      true ->
        {:noreply, socket |> assign(mode: mode, kind: nil) |> run() |> focus()}
    end
  end

  def handle_event("close", _params, socket), do: {:noreply, assign(socket, @closed)}

  def handle_event("query", %{"query" => query}, socket) when is_binary(query) do
    {:noreply, socket |> assign(query: query) |> run()}
  end

  def handle_event("choose", %{"index" => index}, socket) do
    case index(index, length(socket.assigns.rows)) do
      nil -> {:noreply, socket}
      i -> {:noreply, socket |> assign(selected: i) |> choose()}
    end
  end

  def handle_event("widen", _params, socket), do: {:noreply, widen(socket)}

  def handle_event("key", %{"key" => key}, socket), do: {:reply, %{}, key(key, socket)}

  defp key("ArrowDown", socket),
    do: assign(socket, selected: step(socket.assigns.selected, 1, length(socket.assigns.rows)))

  defp key("ArrowUp", socket),
    do: assign(socket, selected: step(socket.assigns.selected, -1, length(socket.assigns.rows)))

  defp key("Enter", socket), do: choose(socket)
  defp key("Escape", socket), do: assign(socket, @closed)
  # Sent only from an empty input: steps the scope out, like the chip's ×.
  defp key("Backspace", socket), do: widen(socket)
  defp key(_key, socket), do: socket

  defp step(_current, _delta, 0), do: 0
  defp step(current, delta, count), do: Integer.mod(current + delta, count)

  # A phx-value arrives as a string; anything else or out of range is ignored.
  defp index(value, count) when is_binary(value) do
    case Integer.parse(value) do
      {i, ""} when i >= 0 and i < count -> i
      _ -> nil
    end
  end

  defp index(_value, _count), do: nil

  defp widen(%{assigns: %{kind: kind}} = socket) when kind != nil, do: socket |> assign(kind: nil) |> run() |> focus()

  defp widen(%{assigns: %{mode: :local}} = socket), do: socket |> assign(mode: :global) |> run() |> focus()
  defp widen(socket), do: socket

  defp focus(socket), do: push_event(socket, "search:focus", %{id: "search-input"})

  defp run(socket) do
    groups = Search.search(socket.assigns.current_scope, socket.assigns.query, search_opts(socket.assigns))
    kind = socket.assigns.kind

    rows =
      Enum.flat_map(groups, fn group ->
        hits = Enum.map(group.hits, &{:hit, &1})
        if group.more? and kind == nil, do: hits ++ [{:more, group.kind}], else: hits
      end)

    assign(socket, groups: groups, rows: rows, selected: 0)
  end

  defp search_opts(%{mode: mode, kind: kind, local: local, current_scope: scope}) do
    allowed = allowed_kinds(scope)

    {kinds, filters, limit} =
      case mode do
        :global ->
          {Search.kinds(), [], @global_limit}

        :local ->
          opts = local_opts(local)
          {Keyword.fetch!(opts, :kinds), Keyword.delete(opts, :kinds), @local_limit}
      end

    if kind,
      do: [kinds: [kind], limit: @kind_limit] ++ filters,
      else: [kinds: Enum.filter(kinds, &(&1 in allowed)), limit: limit] ++ filters
  end

  # Chats and messages are every user's own; the rest need their editors' access.
  defp allowed_kinds(scope) do
    Enum.filter(Search.kinds(), fn
      kind when kind in [:chat, :message] -> true
      kind when kind in [:ai_model, :ai_provider] -> MythweaverWeb.AIAccess.allowed?(scope)
      kind -> MythweaverWeb.ContentAccess.allowed?(scope, Map.fetch!(@content_areas, kind))
    end)
  end

  defp local_opts({:chat, chat}), do: [kinds: [:message], chat_id: chat.id]
  defp local_opts({:lore_book, book}), do: [kinds: [:lore_entry], book_id: book.id]
  defp local_opts(:lore), do: [kinds: [:lore_book, :lore_entry]]
  defp local_opts(:characters), do: [kinds: [:character]]
  defp local_opts(:prompts), do: [kinds: [:prompt, :prompt_block, :prompt_outlet]]
  defp local_opts(:scripts), do: [kinds: [:script]]
  defp local_opts(:memory), do: [kinds: [:memory_profile, :side_prompt]]
  defp local_opts(:ai), do: [kinds: [:ai_model, :ai_provider]]

  # The scope chip of a page search: what the search is limited to.
  defp scope_label({:chat, _chat}), do: pgettext("button: search limited to the open chat", "In this chat")

  defp scope_label({:lore_book, book}),
    do: pgettext("button: search limited to the open lore book", "In %{book_name}", book_name: book.name)

  defp scope_label(:lore), do: pgettext("button: search limited to lore", "In lore")
  defp scope_label(:characters), do: pgettext("button: search limited to characters", "In characters")
  defp scope_label(:prompts), do: pgettext("button: search limited to prompts", "In prompts")
  defp scope_label(:scripts), do: pgettext("button: search limited to scripts", "In scripts")
  defp scope_label(:memory), do: pgettext("button: search limited to memory", "In memory")
  defp scope_label(:ai), do: gettext("In AI models and connections")

  defp choose(socket) do
    case Enum.at(socket.assigns.rows, socket.assigns.selected) do
      nil -> socket
      {:more, kind} -> socket |> assign(kind: kind) |> run() |> focus()
      {:hit, hit} -> open_hit(assign(socket, @closed), hit, socket.assigns)
    end
  end

  defp open_hit(socket, %{kind: :message} = hit, %{local: {:chat, %{id: chat_id}}}) when hit.chat_id == chat_id do
    send(self(), {__MODULE__, :chat_event, "jump_to_message", %{"number" => hit.position + 1}})
    socket
  end

  defp open_hit(socket, hit, assigns), do: push_navigate(socket, to: hit_path(hit, assigns))

  defp hit_path(%{kind: :message} = hit, _assigns), do: ~p"/chats/#{hit.chat_id}?#{[message: hit.id]}"
  defp hit_path(%{kind: :chat, id: id}, _assigns), do: ~p"/chats/#{id}"

  # Book-scoped results are entries of that book, so they open inside it.
  defp hit_path(%{kind: :lore_entry, id: id}, %{mode: :local, local: {:lore_book, book}}),
    do: ~p"/lore/#{book.id}/entries/#{id}/edit"

  defp hit_path(%{kind: :lore_entry, id: id}, _assigns), do: ~p"/lore/entries/#{id}/edit"
  defp hit_path(%{kind: :lore_book, id: id}, _assigns), do: ~p"/lore/#{id}/edit"
  defp hit_path(%{kind: :character, id: id}, _assigns), do: ~p"/characters/#{id}/edit"
  defp hit_path(%{kind: :prompt, id: id}, _assigns), do: ~p"/prompts/#{id}/edit"
  defp hit_path(%{kind: :prompt_block, id: id}, _assigns), do: ~p"/prompts/blocks/#{id}/edit"
  defp hit_path(%{kind: :prompt_outlet, id: id}, _assigns), do: ~p"/prompts/outlets/#{id}/edit"
  defp hit_path(%{kind: :script, id: id}, _assigns), do: ~p"/scripts/#{id}/edit"
  defp hit_path(%{kind: :side_prompt, id: id}, _assigns), do: ~p"/memory/side-prompts/#{id}/edit"
  defp hit_path(%{kind: :memory_profile, id: id}, _assigns), do: ~p"/memory/profiles/#{id}/edit"
  defp hit_path(%{kind: :ai_model, id: id}, _assigns), do: ~p"/ai/models/#{id}/edit"
  defp hit_path(%{kind: :ai_provider, id: id}, _assigns), do: ~p"/ai/providers/#{id}/edit"

  # The listbox in order: a heading per group, then its hits (keyboard indexes into `rows`) and its
  # "show more" row.
  defp items(groups, kind) do
    {items, _i} =
      Enum.flat_map_reduce(groups, 0, fn group, i ->
        hits = group.hits |> Enum.with_index(i) |> Enum.map(fn {hit, j} -> {:hit, hit, j} end)
        next = i + length(hits)
        more = if group.more? and kind == nil, do: [{:more, group.kind, next}], else: []
        {[{:group, group.kind} | hits] ++ more, next + length(more)}
      end)

    items
  end

  defp kind_label(:chat), do: pgettext("heading: search results group", "Chats")
  defp kind_label(:message), do: pgettext("heading: search results group", "Messages")
  defp kind_label(:character), do: pgettext("heading: search results group", "Characters")
  defp kind_label(:lore_book), do: pgettext("heading: search results group", "Lore books")
  defp kind_label(:lore_entry), do: pgettext("heading: search results group", "Lore entries")
  defp kind_label(:prompt), do: pgettext("heading: search results group", "Prompts")
  defp kind_label(:prompt_block), do: pgettext("heading: search results group", "Prompt blocks")
  defp kind_label(:prompt_outlet), do: pgettext("heading: search results group", "Outlets")
  defp kind_label(:script), do: pgettext("heading: search results group", "Scripts")
  defp kind_label(:side_prompt), do: pgettext("heading: search results group", "Side prompts")
  defp kind_label(:memory_profile), do: pgettext("heading: search results group", "Memory profiles")
  defp kind_label(:ai_model), do: pgettext("heading: search results group", "AI models")
  defp kind_label(:ai_provider), do: pgettext("heading: search results group", "AI connections")

  defp more_label(:chat), do: pgettext("option: show more search results", "Show more chats")
  defp more_label(:message), do: pgettext("option: show more search results", "Show more messages")
  defp more_label(:character), do: pgettext("option: show more search results", "Show more characters")
  defp more_label(:lore_book), do: pgettext("option: show more search results", "Show more lore books")
  defp more_label(:lore_entry), do: pgettext("option: show more search results", "Show more lore entries")
  defp more_label(:prompt), do: pgettext("option: show more search results", "Show more prompts")
  defp more_label(:prompt_block), do: pgettext("option: show more search results", "Show more prompt blocks")
  defp more_label(:prompt_outlet), do: pgettext("option: show more search results", "Show more outlets")
  defp more_label(:script), do: pgettext("option: show more search results", "Show more scripts")
  defp more_label(:side_prompt), do: pgettext("option: show more search results", "Show more side prompts")
  defp more_label(:memory_profile), do: pgettext("option: show more search results", "Show more memory profiles")
  defp more_label(:ai_model), do: pgettext("option: show more search results", "Show more AI models")
  defp more_label(:ai_provider), do: pgettext("option: show more search results", "Show more AI connections")
  defp kind_icon(kind), do: Map.fetch!(@kind_icons, kind)

  defp subtitle(%{kind: :message} = hit, local) do
    number =
      pgettext("status: position of a message in its chat", "#%{message_number}",
        message_number: Mythweaver.Format.number(hit.position + 1)
      )

    case local do
      {:chat, %{id: id}} when id == hit.chat_id ->
        number

      _ ->
        pgettext("status: search hit subtitle, chat title then message position", "%{chat_title} · %{message_position}",
          chat_title: hit.chat_title,
          message_position: number
        )
    end
  end

  defp subtitle(_hit, _local), do: nil

  defp placeholder(:global, _local), do: pgettext("placeholder: search across the whole app", "Search everything…")
  defp placeholder(:local, {:chat, _chat}), do: pgettext("placeholder: search the open chat", "Search this chat…")

  defp placeholder(:local, {:lore_book, book}),
    do: pgettext("placeholder: search the open lore book", "Search %{book_name}…", book_name: book.name)

  defp placeholder(:local, :lore), do: pgettext("placeholder: search lore", "Search lore…")
  defp placeholder(:local, :characters), do: pgettext("placeholder: search characters", "Search characters…")
  defp placeholder(:local, :prompts), do: pgettext("placeholder: search prompts", "Search prompts…")
  defp placeholder(:local, :scripts), do: pgettext("placeholder: search scripts", "Search scripts…")
  defp placeholder(:local, :memory), do: pgettext("placeholder: search memory", "Search memory…")

  defp placeholder(:local, :ai),
    do: pgettext("placeholder: search AI models and connections", "Search AI models and connections…")

  attr :segments, :list, required: true
  attr :class, :string, required: true

  defp segments(assigns) do
    ~H"""
    <span class={@class} phx-no-format><%= for {text, marked?} <- @segments do %><%= if marked? do %><mark>{text}</mark><% else %>{text}<% end %><% end %></span>
    """
  end

  @impl true
  def render(assigns) do
    # Kind icons are picked at runtime; the Iconex compiler only sees literals.
    Iconex.hint(
      :lucide,
      ~w[messages-square message-square user book scroll-text file-text blocks plug code sparkles brain cpu server]
    )

    assigns =
      assign(assigns,
        items: items(assigns.groups, assigns.kind),
        searchable?: Query.to_tsquery(assigns.query) != :empty,
        truncated?: assigns.kind != nil and Enum.any?(assigns.groups, & &1.more?)
      )

    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      /* Every marked element is a scope root here, so the component root is named outright. */
      div.search:scope {
        display: contents;
      }

      dialog.search-dialog {
        margin: 12dvh auto auto;
        padding: 0;
        border: 0;
        background: none;
        inline-size: min(44rem, calc(100vw - 2 * var(--panel-gap)));
        max-inline-size: min(44rem, calc(100vw - 2 * var(--panel-gap)));
        color: var(--foreground);
      }

      .search-dialog::backdrop {
        background: oklch(0 0 0 / 0.25);
      }

      .search-panel {
        display: flex;
        flex-direction: column;
        max-block-size: 70dvh;
        background: var(--surface-4);
        border: 1px solid var(--border);
        border-radius: var(--radius-3);
        box-shadow: var(--elevation-2xl);
        overflow: hidden;
      }

      .search-query {
        display: flex;
        align-items: center;
        gap: var(--size-2);
        padding-inline-start: var(--size-3);
        border-block-end: 1px solid var(--border);
      }

      .search-form {
        flex: 1 1 auto;
        min-inline-size: 0;
      }

      .search-scope {
        display: inline-flex;
        align-items: center;
        gap: var(--size-1);
        flex: none;
        max-inline-size: 50%;
        padding: var(--size-1) var(--size-2);
        border: 0;
        border-radius: var(--radius-round);
        background: var(--surface-6);
        color: var(--foreground);
        font: inherit;
        font-size: var(--font-size-0);
        white-space: nowrap;
        overflow: hidden;
        text-overflow: ellipsis;
        cursor: pointer;
      }

      .search-scope:hover {
        background: var(--surface-7);
      }

      .search-input {
        display: block;
        inline-size: 100%;
        border: 0;
        background: transparent;
        font: inherit;
        font-size: var(--font-size-3);
        padding: var(--size-3);
        color: var(--foreground);
        outline: none;
      }

      .search-list {
        list-style: none;
        margin: 0;
        padding: var(--size-1);
        overflow-y: auto;
        flex: 1 1 auto;
      }

      .search-group {
        text-transform: uppercase;
        font-size: var(--font-size-00);
        color: var(--muted-foreground);
        padding: var(--size-2) var(--size-3) var(--size-1);
      }

      .search-row,
      .search-note {
        display: flex;
        align-items: flex-start;
        gap: var(--size-2);
        padding: var(--size-2) var(--size-3);
        border-radius: var(--radius-2);
      }

      .search-row {
        cursor: pointer;
      }

      .search-row:hover {
        background: var(--surface-6);
      }

      .search-row[aria-selected="true"] {
        background: var(--surface-7);
      }

      .search-row .iconex {
        flex: none;
        margin-block-start: 0.2em;
        color: var(--muted-foreground);
      }

      .search-text {
        display: flex;
        flex-direction: column;
        min-inline-size: 0;
      }

      .search-subtitle,
      .search-note,
      .search-more {
        color: var(--muted-foreground);
      }

      .search-subtitle {
        font-size: var(--font-size-0);
      }

      .search-snippet {
        color: var(--muted-foreground);
        font-size: var(--font-size-0);
        display: -webkit-box;
        -webkit-box-orient: vertical;
        -webkit-line-clamp: 2;
        overflow: hidden;
      }

      .search-list mark {
        background: color-mix(in oklch, var(--primary-accent) 30%, transparent);
        color: inherit;
        border-radius: var(--radius-1);
      }

      .search-footer {
        border-block-start: 1px solid var(--border);
        display: flex;
        justify-content: flex-end;
        gap: var(--size-3);
        padding: var(--size-2) var(--size-3);
        font-size: var(--font-size-0);
        color: var(--muted-foreground);
      }

      .search-footer kbd {
        font: inherit;
        opacity: 0.8;
      }

      @media (--phone) {
        dialog.search-dialog {
          margin-block-start: calc(var(--panel-gap) + env(safe-area-inset-top));
        }
      }
    </style>

    <div id="search" class="search" phx-hook=".Search" phx-target={@myself} data-local={@local != nil}>
      <dialog
        :if={@open?}
        id="search-dialog"
        class="search-dialog"
        phx-hook=".SearchDialog"
        phx-target={@myself}
        aria-label={pgettext("aria label: the search dialog", "Search")}
      >
        <div class="search-panel">
          <div class="search-query">
            <button
              :if={@mode == :local or @kind != nil}
              type="button"
              id="search-scope"
              class="search-scope"
              phx-click="widen"
              phx-target={@myself}
              title={pgettext("tooltip: button that removes the search's limit", "Widen the search")}
            >
              <span :if={@kind}>{kind_label(@kind)}</span>
              <span :if={!@kind}>{scope_label(@local)}</span>
              <.lucide name="x" />
            </button>
            <.form
              for={%{}}
              id="search-form"
              class="search-form"
              phx-change="query"
              phx-submit="query"
              phx-target={@myself}
            >
              <.input
                type="text"
                name="query"
                value={@query}
                id="search-input"
                class="search-input"
                placeholder={placeholder(@mode, @local)}
                autocomplete="off"
                phx-debounce="150"
              />
            </.form>
          </div>
          <ul id="search-results" class="search-list" role="listbox">
            <%= for item <- @items do %>
              <%= case item do %>
                <% {:group, kind} -> %>
                  <li class="search-group" role="presentation">{kind_label(kind)}</li>
                <% {:hit, hit, i} -> %>
                  <li
                    id={"search-hit-#{hit.kind}-#{hit.id}"}
                    class="search-row"
                    role="option"
                    aria-selected={"#{i == @selected}"}
                    phx-click="choose"
                    phx-value-index={i}
                    phx-target={@myself}
                  >
                    <.lucide name={kind_icon(hit.kind)} />
                    <span class="search-text">
                      <.segments :if={hit.title} segments={hit.title} class="search-title" />
                      <span :if={!hit.title} class="search-title">
                        {pgettext("status: search hit without a title", "Untitled")}
                      </span>
                      <span :if={subtitle(hit, @local)} class="search-subtitle">
                        {subtitle(hit, @local)}
                      </span>
                      <.segments :if={hit.snippet} segments={hit.snippet} class="search-snippet" />
                    </span>
                  </li>
                <% {:more, kind, i} -> %>
                  <li
                    id={"search-more-#{kind}"}
                    class="search-row search-more"
                    role="option"
                    aria-selected={"#{i == @selected}"}
                    phx-click="choose"
                    phx-value-index={i}
                    phx-target={@myself}
                  >
                    {more_label(kind)}
                  </li>
              <% end %>
            <% end %>
            <li :if={@truncated?} id="search-truncated" class="search-note">
              {gettext("Showing the first %{match_limit} matches — refine the search to narrow them.",
                match_limit: Mythweaver.Format.number(50)
              )}
            </li>
            <li :if={@groups == []} id="search-empty" class="search-note">
              {if @searchable?,
                do: pgettext("empty state: search matched nothing", "No matches"),
                else: pgettext("empty state: search with no query yet", "Type to search")}
            </li>
          </ul>
          <footer class="search-footer">
            <span>
              {rich(
                pgettext(
                  "status: search footer hint, press the key to open the hit",
                  "Open %{enter_key}",
                  enter_key:
                    kbd(pgettext("keyboard key: Enter, lowercase as printed on a key hint", "enter"))
                )
              )}
            </span>
            <span><kbd>↑</kbd><kbd>↓</kbd></span>
            <span><kbd>{pgettext("keyboard key: Escape, lowercase as printed on a key hint", "esc")}</kbd></span>
          </footer>
        </div>
      </dialog>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".Search">
        export default {
          mounted() {
            // `MythweaverWeb.Shortcuts`' listener owns Mod-K/Mod-F and dispatches this.
            this.onOpen = (e) =>
              this.pushEventTo(this.el, "open", { mode: e.detail.mode });
            window.addEventListener("shortcuts:search", this.onOpen);
          },
          destroyed() {
            window.removeEventListener("shortcuts:search", this.onOpen);
          },
        };
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".SearchDialog">
        const KEYS = ["ArrowUp", "ArrowDown", "Enter", "Escape"];

        function focusEnd(input) {
          if (!input) return;
          input.focus();
          const end = input.value.length;
          input.setSelectionRange?.(end, end);
        }

        export default {
          mounted() {
            this.previous = document.activeElement;
            // See `MythweaverWeb.CoreComponents.Modal`: opened from the client so it is modal,
            // and `open` survives patches.
            this.el.showModal();
            this.js().ignoreAttributes(this.el, ["open"]);
            focusEnd(this.el.querySelector("#search-input"));

            // Escape is a search key, not the dialog's own cancel.
            this.el.addEventListener("cancel", (e) => e.preventDefault());
            this.el.addEventListener("close", () =>
              this.pushEventTo(this.el, "close", {}),
            );
            this.el.addEventListener("click", (e) => {
              if (e.target === this.el) this.el.close();
            });

            this.el.addEventListener("keydown", (e) => {
              if (e.isComposing) return;
              const widen =
                e.key === "Backspace" &&
                e.target.id === "search-input" &&
                e.target.value === "";
              if (!KEYS.includes(e.key) && !widen) return;
              e.preventDefault();
              e.stopPropagation();
              this.pushEventTo(this.el, "key", { key: e.key }, () => {
                this.el
                  .querySelector('[aria-selected="true"]')
                  ?.scrollIntoView({ block: "nearest" });
              });
            });

            this.handleEvent("search:focus", ({ id }) =>
              focusEnd(document.getElementById(id)),
            );
          },
          destroyed() {
            if (this.previous?.isConnected) this.previous.focus();
          },
        };
      </script>
    </div>
    """
  end
end
