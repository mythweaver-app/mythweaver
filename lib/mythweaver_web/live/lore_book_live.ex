defmodule MythweaverWeb.LoreBookLive do
  @moduledoc """
  The lore page. On the left a tree: every lore book as a folder of its entries (by effective
  order), plus an "Unlinked" folder for entries in no book. Dragging an entry between folders moves
  it; holding the OS primary modifier (Cmd on macOS, Ctrl elsewhere) keeps it in the source too
  (`Lore.place_entry/5`, via the external `LoreTree` hook, which also persists folder open state in
  localStorage). A search replaces the tree with a flat list of matching books and entries.

  On the right either the selected book's editor (`:new`/`:edit`/`:new_entry`/`:edit_entry`: form,
  then bindings, activation rules and entries table, the `MythweaverWeb.Lore.BookSections`
  components) or a full entry editor (`:entry_new`/`:entry_edit`). `:index` selects
  nothing: the editor pane shows a placeholder until a book or entry is picked.
  The list header's Pools switch leads to `MythweaverWeb.LorePoolLive`, the pool editor.

  The book's entries are a SillyTavern-style table of collapsed rows: drag handle, expand chevron, a
  checkbox for this book's membership (`BookEntry.enabled`, the only on/off switch an entry has), name,
  activation, position, this book's order (editable inline) and trigger %, and remove/delete. A row
  opens by patching to `:edit_entry`, which renders the shared `MythweaverWeb.Lore.EntryForm` inside
  it through `MythweaverWeb.Lore.InlineEntryForm`; one row is open at a time, none by default, and a
  new entry's form sits above the table.
  Dragging a handle renumbers this book's memberships serially (`Lore.reorder_book_entries/2`). The
  column headers sort the rows for viewing only (`entry_sort`, cleared when the book changes) and
  switch dragging off while shown.

  Rows can be selected (`selected_entry_ids`, cleared when the book changes and pruned to the listed
  entries on every reload) for bulk actions in the selection bar: marking entries as memories
  (`Mythweaver.Memory.mark_as_memories/3`) and unmarking them. A badge marks each entry that is a
  memory. Rows are stream items rendered once, so every selection change re-streams them.

  The entries stream carries an explicit `dom_id` because the default (`entries-<id>`) does not
  match the `lore-entries-<id>` id contract.

  Entries are shared across books, so this view edits *the entry* plus its membership set rather
  than owning it.

  Writes made elsewhere (`MythweaverWeb.LiveSync`) reload the tree, the open book and the open entry:
  an untouched form takes the new values, an edited one keeps its edits under the
  `lore-changed-elsewhere` notice, and a deleted row closes its editor.

  Open to anyone `MythweaverWeb.ContentAccess` admits; it lists and edits only rows the scope may
  edit (`Mythweaver.Ownership`): a user's own books and entries, plus the site's for an admin.
  """

  use MythweaverWeb, :live_view

  import MythweaverWeb.BulkComponents
  import MythweaverWeb.Lore.EntryForm, only: [entry_form: 1]
  import MythweaverWeb.Pane
  import MythweaverWeb.TagFields
  import MythweaverWeb.TagFilter

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Chats
  alias Mythweaver.Jobs
  alias Mythweaver.Lore
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Memory
  alias Mythweaver.Memory.Record
  alias Mythweaver.Ownership
  alias Mythweaver.Tags.Tag
  alias MythweaverWeb.Bulk
  alias MythweaverWeb.Bulk.Field
  alias MythweaverWeb.Bulk.Selection
  alias MythweaverWeb.Bulk.Spec
  alias MythweaverWeb.CoreComponents.OwnerSelect
  alias MythweaverWeb.EnumLabels
  alias MythweaverWeb.FieldCompaction
  alias MythweaverWeb.LiveSync
  alias MythweaverWeb.Lore.BookSections
  alias MythweaverWeb.Lore.EntryForm
  alias MythweaverWeb.Lore.InlineEntryForm

  require FieldCompaction

  on_mount {MythweaverWeb.ContentAccess, :lore}
  on_mount MythweaverWeb.Sudo

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Jobs.subscribe(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(
       page_title: lore_title(),
       form: nil,
       editing_book: nil,
       transfer: nil,
       new_owner: "personal",
       selected_id: nil,
       selected_entry_id: nil,
       entries_empty?: true,
       entry_ids: [],
       selected_entry_ids: MapSet.new(),
       memory_kinds: %{},
       open_row: nil,
       entry_sort: nil,
       hide_disabled_memories: false,
       hidden_entry_count: 0,
       chat_options: [],
       rules_form: nil,
       rules_book: nil,
       rule_chat_options: [],
       tree: %{books: [], unlinked: []}
     )
     |> EntryForm.clear_entry()
     |> EntryForm.assign_options()
     |> assign_filter()
     |> assign_tag_filter()
     |> assign_search_results()
     |> stream_configure(:entries, dom_id: &"lore-entries-#{&1.id}")
     |> stream(:entries, [])
     |> Bulk.attach([books_spec(), entries_spec()])
     |> LiveSync.attach_editor([:lore, :characters, :prompts, :tags, :ai, :settings], &sync/2)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(
      form: nil,
      editing_book: nil,
      transfer: nil,
      selected_id: nil,
      selected_entry_id: nil,
      selected_entry_ids: MapSet.new(),
      open_row: nil,
      entry_sort: nil,
      page_title: lore_title()
    )
    |> EntryForm.clear_entry()
    |> load_tree()
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(
      form: to_form(Lore.change_book(%LoreBook{})),
      editing_book: nil,
      new_owner: "personal",
      book_filter_tags: [],
      selected_id: nil,
      selected_entry_id: nil,
      selected_entry_ids: MapSet.new(),
      page_title: lore_title()
    )
    |> EntryForm.clear_entry()
    |> assign_tag_fields(:book, nil, OwnerSelect.new_owner(socket.assigns.current_scope, LoreBook, "personal"))
    |> load_tree()
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    with_book(socket, id, &EntryForm.clear_entry/1)
  end

  defp apply_action(socket, :new_entry, %{"id" => id}) do
    with_book(socket, id, &EntryForm.assign_new_entry(&1, [&1.assigns.editing_book.id]))
  end

  defp apply_action(socket, :edit_entry, %{"id" => id, "entry_id" => entry_id}) do
    with_book(socket, id, fn socket ->
      case Lore.get_editable_entry(socket.assigns.current_scope, entry_id) do
        nil ->
          socket
          |> put_flash(:error, entry_not_found())
          |> push_patch(to: ~p"/lore/#{id}/edit")

        entry ->
          socket
          |> assign(selected_entry_id: entry.id)
          |> EntryForm.assign_edit_entry(entry)
      end
    end)
  end

  # The full-pane entry editor, outside any book. `?book=<id>` preselects that book.
  defp apply_action(socket, :entry_new, params) do
    book_ids =
      case params["book"] && Lore.get_editable_book(socket.assigns.current_scope, params["book"]) do
        %LoreBook{id: id} -> [id]
        _ -> []
      end

    socket
    |> reset_to_entry_page(dpgettext("lore", "page title: create a lore entry", "New entry"))
    |> EntryForm.assign_new_entry(book_ids)
    |> load_tree()
  end

  defp apply_action(socket, :entry_edit, %{"entry_id" => id}) do
    socket =
      case Lore.get_editable_entry(socket.assigns.current_scope, id) do
        nil ->
          socket
          |> put_flash(:error, entry_not_found())
          |> push_patch(to: ~p"/lore")

        entry ->
          socket
          |> reset_to_entry_page(entry.name)
          |> assign(selected_entry_id: entry.id)
          |> EntryForm.assign_edit_entry(entry)
      end

    load_tree(socket)
  end

  defp reset_to_entry_page(socket, title) do
    socket
    |> assign(
      editing_book: nil,
      selected_id: nil,
      selected_entry_id: nil,
      selected_entry_ids: MapSet.new(),
      form: nil,
      open_row: nil,
      entry_sort: nil,
      page_title: title
    )
    |> EntryForm.assign_options()
  end

  defp with_book(socket, id, fun) do
    case Lore.get_editable_book(socket.assigns.current_scope, id) do
      nil ->
        socket
        |> put_flash(:error, book_not_found())
        |> push_patch(to: ~p"/lore")

      book ->
        # A column sort and a row selection are views of one book; another book starts afresh.
        same_book? = match?(%{id: ^id}, socket.assigns.editing_book)

        socket
        |> assign(
          form: to_form(Lore.change_book(book)),
          editing_book: book,
          book_filter_tags: Enum.map(book.filter_tags, &Tag.text/1),
          selected_id: book.id,
          selected_entry_id: nil,
          page_title: book.name,
          entry_sort: if(same_book?, do: socket.assigns.entry_sort),
          selected_entry_ids: if(same_book?, do: socket.assigns.selected_entry_ids, else: MapSet.new())
        )
        |> assign_tag_fields(:book, book, book.user_id)
        |> EntryForm.assign_options()
        |> assign(chat_options: Chats.chat_options(socket.assigns.current_scope))
        |> assign_rules_form(book)
        |> load_tree()
        |> fun.()
        |> load_entries(book)
    end
  end

  # After the entry form is set up, so the open row is known. Stream rows render once, so the open
  # row's form is a LiveComponent that `refresh_open_row/1` updates without re-inserting the row.
  # The selection keeps only entries still listed, and the rows render its checkboxes and the
  # memory badges as of this load. The stream is reset only when the listed rows or their order
  # changed: a reset rebuilds the whole table, which snaps a scrolled pane back up, while the same
  # rows re-sent are patched in place.
  #
  # "Hide disabled memories" drops memory entries (any memory record) switched off in this book,
  # such as the sources a consolidation turned off; other off entries and on memories stay.
  defp load_entries(socket, book) do
    all =
      Lore.list_entries_in_book(socket.assigns.current_scope, book) |> sort_entries(socket.assigns.entry_sort, book)

    memory_kinds = Memory.memory_kinds(Enum.map(all, & &1.id))

    entries =
      if socket.assigns.hide_disabled_memories,
        do: Enum.reject(all, &(memory_kinds[&1.id] && !enabled_in_book?(&1, book))),
        else: all

    editing = socket.assigns.editing_entry
    ids = Enum.map(entries, & &1.id)
    reset? = ids != socket.assigns.entry_ids

    socket
    |> assign(
      entries_empty?: entries == [],
      hidden_entry_count: length(all) - length(entries),
      entry_ids: ids,
      selected_entry_ids: MapSet.intersection(socket.assigns.selected_entry_ids, MapSet.new(ids)),
      memory_kinds: Map.take(memory_kinds, ids),
      open_row: editing && Enum.find(entries, &(&1.id == editing.id))
    )
    |> stream(:entries, entries, reset: reset?)
  end

  # The column headers' sort: a view only, never written back. `nil` is the persisted order
  # (`Lore.list_entries_in_book/1`), the one drag-and-drop edits.
  @entry_sort_columns ~w(on name activation position order trigger)

  defp sort_entries(entries, nil, _book), do: entries

  defp sort_entries(entries, {column, direction}, book) do
    # `Enum.sort_by/3` is stable, and the persisted order is by order, then name, so ties keep it.
    Enum.sort_by(entries, &sort_key(column, &1, book), direction)
  end

  defp sort_key("on", entry, book), do: enabled_in_book?(entry, book)
  defp sort_key("name", entry, _book), do: String.downcase(entry.name)
  defp sort_key("activation", entry, _book), do: entry.activation
  defp sort_key("position", entry, _book), do: {entry.outlet, entry.placement, entry.depth || 0, entry.custom_outlet}
  defp sort_key("order", entry, book), do: effective_order(entry, book)
  defp sort_key("trigger", entry, _book), do: entry.probability

  # Ascending, then descending, then back to the persisted order.
  defp next_sort({column, :asc}, column), do: {column, :desc}
  defp next_sort({column, :desc}, column), do: nil
  defp next_sort(_current, column), do: {column, :asc}

  defp refresh_open_row(%{assigns: %{open_row: %{}}} = socket) do
    InlineEntryForm.refresh(socket.assigns)
    socket
  end

  defp refresh_open_row(socket), do: socket

  # Leaves `form` alone, so unsaved book-form edits survive binding and entry actions.
  defp reload_book(socket) do
    case Lore.get_editable_book(socket.assigns.current_scope, socket.assigns.editing_book.id) do
      nil ->
        socket
        |> put_flash(:error, book_not_found())
        |> push_patch(to: ~p"/lore")

      book ->
        socket
        |> assign(editing_book: book)
        |> reload_rules_form(book)
        |> load_entries(book)
        |> load_tree()
    end
  end

  # The rules form starts from the book's saved rules. A rule may name only the book owner's chats,
  # so another owner's book (a site book) offers none.
  # `rules_book` is the book the form was built from, so validate/save and the changed-elsewhere
  # check compare against what the user is editing.
  defp assign_rules_form(socket, book) do
    changeset = Lore.change_book_rules(book)
    own? = book.user_id == socket.assigns.current_scope.user.id

    assign(socket,
      rules_form: to_form(changeset, as: :lore_book_rules),
      rules_book: changeset.data,
      rule_chat_options: if(own?, do: socket.assigns.chat_options, else: []),
      rule_character_options: if(own?, do: socket.assigns.character_options, else: Lore.rule_character_options(book))
    )
  end

  # A rules form with unsaved edits keeps them, flagging a save made elsewhere.
  defp reload_rules_form(socket, book) do
    cond do
      LiveSync.clean?(socket.assigns.rules_form) ->
        assign_rules_form(socket, book)

      rules_changed?(socket.assigns.rules_book, Lore.change_book_rules(book).data) ->
        assign(socket, changed_elsewhere?: true)

      true ->
        socket
    end
  end

  defp rules_changed?(held, fresh), do: rules_key(held) != rules_key(fresh)

  defp rules_key(book) do
    for rule <- book.rules do
      {rule.id, rule.enabled,
       Enum.map(rule.conditions, &Map.take(&1, [:id, :kind, :negate, :chat_id, :character_id, :tags, :template]))}
    end
  end

  # Reloads whatever the right pane shows: the book (which also reloads the tree), or just the tree.
  defp refresh(%{assigns: %{editing_book: %LoreBook{}}} = socket), do: reload_book(socket)
  defp refresh(socket), do: load_tree(socket)

  # A write made elsewhere: the form's option lists and the tag graph, then the open book and the
  # open entry (each reloaded when untouched, flagged when edited, closed when gone), then the tree
  # and the book's table, then the open row's inline form, which only `send_update` reaches.
  @option_kinds [:lore, :characters, :prompts, :ai, :settings]

  defp sync(socket, kinds) do
    scope = socket.assigns.current_scope
    socket = if Enum.any?(kinds, &(&1 in @option_kinds)), do: EntryForm.assign_options(socket), else: socket
    socket = if :tags in kinds, do: refresh_graph(socket), else: socket

    socket =
      LiveSync.sync_open(socket, :editing_book,
        fetch: &Lore.get_editable_book(scope, &1),
        clean?: LiveSync.clean?(socket.assigns.form),
        compare: &book_changed?/2,
        reload: &reload_book_form/2,
        on_gone: &assign(&1, open_row: nil),
        gone: ~p"/lore",
        gone_message:
          (
            gettext_comment("Flash shown when the lore book open in the editor was deleted or moved by someone else.")
            dgettext("lore", "The lore book was deleted or moved elsewhere.")
          ),
        force: :tags in kinds
      )

    socket =
      LiveSync.sync_open(socket, :editing_entry,
        fetch: &Lore.get_editable_entry(scope, &1),
        clean?: LiveSync.clean?(socket.assigns.entry_form),
        compare: &entry_changed?/2,
        reload: &reload_entry_form/2,
        on_gone: &EntryForm.clear_entry/1,
        gone: if(book = socket.assigns.editing_book, do: ~p"/lore/#{book.id}/edit", else: ~p"/lore"),
        gone_message:
          (
            gettext_comment("Flash shown when the lore entry open in the editor was deleted or moved by someone else.")
            dgettext("lore", "The lore entry was deleted or moved elsewhere.")
          ),
        force: :tags in kinds
      )

    socket |> refresh() |> refresh_open_row()
  end

  # Beyond the stored fields, the associations each form edits.
  defp book_changed?(held, fresh),
    do: LiveSync.changed?(held, fresh) or assoc_ids(held, :filter_tags) != assoc_ids(fresh, :filter_tags)

  defp entry_changed?(held, fresh) do
    LiveSync.changed?(held, fresh) or
      Enum.any?([:books, :pools, :filter_characters, :filter_tags], &(assoc_ids(held, &1) != assoc_ids(fresh, &1)))
  end

  defp assoc_ids(row, assoc) do
    case Map.fetch!(row, assoc) do
      rows when is_list(rows) -> rows |> Enum.map(& &1.id) |> Enum.sort()
      _not_loaded -> nil
    end
  end

  defp reload_book_form(socket, book) do
    socket
    |> assign(
      form: to_form(Lore.change_book(book)),
      editing_book: book,
      book_filter_tags: Enum.map(book.filter_tags, &Tag.text/1),
      page_title: book.name
    )
    |> assign_tag_fields(:book, book, book.user_id)
  end

  # `assign_edit_entry/2` clears a running Compact; its rewrite still lands in this form.
  defp reload_entry_form(socket, entry) do
    compaction = socket.assigns.entry_compaction

    socket
    |> EntryForm.assign_edit_entry(entry)
    |> assign(entry_compaction: compaction)
  end

  # Search results follow the data too, so a save or drop while searching shows up in them.
  defp load_tree(socket) do
    socket
    |> assign(tree: Lore.list_tree(socket.assigns.current_scope))
    |> assign_search_results()
  end

  # While a search is typed (or a tag filter set) the tree is hidden and these flat lists stand in
  # for it: matching book names first, then entries by name, content or keyword, each kept only when
  # it passes the tag filter.
  defp assign_search_results(socket) do
    query = socket.assigns.query
    scope = socket.assigns.current_scope
    searching? = String.trim(query) != "" or socket.assigns.tag_predicates != []

    results =
      if searching?,
        do: %{
          books: socket |> filter_tagged(Lore.list_books(scope), :lore_book) |> search(query, &[&1.name]),
          entries:
            socket
            |> filter_tagged(Lore.list_entries(scope), :lore_entry)
            |> search(query, &[&1.name, &1.content | &1.keywords])
        },
        else: %{books: [], entries: []}

    assign(socket, searching?: searching?, search_results: results)
  end

  defp books_spec do
    %Spec{
      name: :lore_books,
      tag_kind: :lore_book,
      count_label:
        &dpngettext(
          "lore",
          "count phrase: lore books affected by a bulk action",
          "%{book_count} book",
          "%{book_count} books",
          &1,
          book_count: Mythweaver.Format.number(&1)
        ),
      edit_label: dpgettext("lore", "button: bulk-edit the selected lore books", "Edit books…"),
      tag_label: dpgettext("lore", "button: bulk-change tags of the selected lore books", "Tag books…"),
      ids: fn %{assigns: a} ->
        if a.searching?, do: Enum.map(a.search_results.books, & &1.id), else: Enum.map(a.tree.books, & &1.book.id)
      end,
      get: &Lore.get_editable_book/2,
      update: &Lore.update_book/3,
      delete: &Lore.delete_book/2,
      title: & &1.name,
      refresh: &load_tree/1,
      open_id: & &1.assigns.selected_id,
      index_path: ~p"/lore",
      edit_path: &~p"/lore/#{&1}/edit",
      fields: [
        %Field{key: :global, label: dpgettext("lore", "field label: lore book is active in every chat", "Global")},
        %Field{
          key: :recursive,
          label: dpgettext("lore", "field label: lore book entries can be activated by recursion", "Recursive")
        },
        %Field{
          key: :site_visibility,
          label: visibility_label(),
          type: :select,
          options: for({label, value} <- visibility_options(), do: {label, String.to_existing_atom(value)})
        },
        %Field{key: :forced, label: dpgettext("lore", "field label: lore book is sent with every reply", "Forced")},
        %Field{
          key: :priority,
          label: priority_label(),
          type: :select,
          options: for(n <- 1..5, do: {Mythweaver.Format.number(n), n})
        },
        %Field{key: :token_budget, label: token_budget_label(), type: :number, min: 1},
        %Field{key: :scan_depth, label: book_scan_depth_label(), type: :number, min: 1}
      ]
    }
  end

  defp entries_spec do
    %Spec{
      name: :lore_entries,
      tag_kind: :lore_entry,
      count_label:
        &dpngettext(
          "lore",
          "count phrase: lore entries affected by a bulk action",
          "%{entry_count} entry",
          "%{entry_count} entries",
          &1,
          entry_count: Mythweaver.Format.number(&1)
        ),
      edit_label: dpgettext("lore", "button: bulk-edit the selected lore entries", "Edit entries…"),
      tag_label: dpgettext("lore", "button: bulk-change tags of the selected lore entries", "Tag entries…"),
      ids: fn %{assigns: a} ->
        if a.searching?,
          do: Enum.map(a.search_results.entries, & &1.id),
          else:
            Enum.uniq(
              for(folder <- a.tree.books, row <- folder.entries, do: row.entry.id) ++
                Enum.map(a.tree.unlinked, & &1.id)
            )
      end,
      get: &Lore.get_editable_entry/2,
      update: &Lore.update_entry/3,
      delete: &Lore.delete_entry/2,
      title: & &1.name,
      refresh: &load_tree/1,
      open_id: & &1.assigns.selected_entry_id,
      index_path: ~p"/lore",
      edit_path: &~p"/lore/entries/#{&1}/edit",
      fields:
        Enum.map(~w(activation placement secondary_logic character_filter_mode)a, fn key ->
          %Field{
            key: key,
            label: EnumLabels.field_label(LoreEntry, key),
            type: :select,
            options: Field.enum_options(LoreEntry, key)
          }
        end) ++
          [
            %Field{
              key: :outlet,
              label: dpgettext("lore", "field label: where a lore entry's text is inserted", "Outlet"),
              type: :select,
              options: Field.enum_options(LoreEntry, :outlet, [:custom])
            }
          ] ++
          Enum.map(~w(case_sensitive match_whole_words exclude_recursion prevent_recursion ignore_budget)a, fn key ->
            %Field{key: key, label: EnumLabels.field_label(LoreEntry, key)}
          end) ++
          [
            %Field{
              key: :probability,
              label: dpgettext("lore", "field label: chance in percent that a lore entry is used", "Probability"),
              type: :number,
              min: 0,
              max: 100
            },
            %Field{
              key: :depth,
              label: dpgettext("lore", "field label: insertion depth of a lore entry", "Depth"),
              type: :number,
              min: 0
            }
          ]
    }
  end

  ## List

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, socket |> assign_filter(params) |> assign_tag_filter(params) |> assign_search_results()}
  end

  # A drop in the tree. `""` is the Unlinked folder. The hook puts the dragged node back before
  # pushing, so the re-render here is the only thing that moves it.
  def handle_event("place_entry", %{"entry_id" => entry_id, "from" => from, "to" => to} = params, socket) do
    case Lore.place_entry(
           socket.assigns.current_scope,
           entry_id,
           blank_to_nil(from),
           blank_to_nil(to),
           params["copy"] == true,
           List.wrap(params["ids"])
         ) do
      {:ok, _} ->
        {:noreply, refresh(socket)}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}

      {:error, :not_found} ->
        {:noreply, socket |> put_flash(:error, place_gone()) |> load_tree()}
    end
  end

  ## Book

  def handle_event("validate", %{"lore_book" => params} = all, socket) do
    owner = OwnerSelect.choice(all)
    {params, socket} = lift_book_tags(params, all, socket)

    socket =
      if is_nil(socket.assigns.editing_book) and owner != socket.assigns.new_owner,
        do:
          socket
          |> assign(new_owner: owner)
          |> put_owner(:book, OwnerSelect.new_owner(socket.assigns.current_scope, LoreBook, owner)),
        else: assign(socket, new_owner: owner)

    changeset =
      socket
      |> target_book()
      |> Lore.change_book(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"lore_book" => params} = all, socket) do
    scope = socket.assigns.current_scope
    {params, socket} = lift_book_tags(params, all, socket)

    result =
      case socket.assigns.editing_book do
        nil -> Lore.create_book(scope, params, OwnerSelect.create_opts(OwnerSelect.choice(all)))
        book -> Lore.update_book(scope, book, params)
      end

    case result do
      {:ok, book} ->
        {socket, unsaved} = save_book_tags(socket, book)

        message = book_saved_message(book.name, unsaved)
        kind = if unsaved == [], do: :info, else: :error

        {:noreply,
         socket
         |> put_flash(kind, message)
         |> push_patch(to: ~p"/lore/#{book.id}/edit")}

      {:error, :quota_exceeded} ->
        {:noreply, flash_quota(socket, "quota.lore_books")}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(:error, save_failed())}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Lore.get_editable_book(socket.assigns.current_scope, id) do
      nil ->
        {:noreply, socket}

      book ->
        result = Lore.delete_book(socket.assigns.current_scope, book)
        {:noreply, MythweaverWeb.HandOff.after_delete(socket, result, book.name, ~p"/lore")}
    end
  end

  def handle_event("prepare_transfer", _params, %{assigns: %{editing_book: %LoreBook{} = book}} = socket) do
    case Lore.transfer_impact(socket.assigns.current_scope, book, :site) do
      {:ok, impact} ->
        {:noreply, assign(socket, transfer: %{warnings: transfer_warnings(impact)})}

      {:error, _reason} ->
        {:noreply, flash_unauthorized(socket)}
    end
  end

  def handle_event("cancel_transfer", _params, socket), do: {:noreply, assign(socket, transfer: nil)}

  def handle_event("transfer_book", params, %{assigns: %{editing_book: %LoreBook{} = book, transfer: %{}}} = socket) do
    case Lore.transfer_book(socket.assigns.current_scope, book, :site) do
      {:ok, moved} ->
        {:noreply,
         socket
         |> assign(transfer: nil)
         |> put_flash(:info, transferred(moved.name))
         |> push_patch(to: ~p"/lore/#{moved.id}/edit")}

      # The transfer stays prepared, so the confirmed password replays this event.
      {:error, :sudo_required} ->
        {:noreply, MythweaverWeb.Sudo.require(socket, "transfer_book", params)}

      {:error, _reason} ->
        {:noreply, socket |> assign(transfer: nil) |> flash_unauthorized()}
    end
  end

  ## Bindings

  def handle_event("save_bindings", params, socket) do
    book = socket.assigns.editing_book
    scope = socket.assigns.current_scope
    # Both pickers always post a `""` sentinel.
    chat_ids = params["chats"] |> List.wrap() |> Enum.reject(&(&1 == ""))
    character_ids = params["characters"] |> List.wrap() |> Enum.reject(&(&1 == ""))

    socket =
      with {:ok, :ok} <- Lore.set_book_chats(scope, book, chat_ids),
           {:ok, :ok} <- Lore.set_book_characters(scope, book, character_ids) do
        socket
      else
        {:error, :unauthorized} -> flash_unauthorized(socket)
        {:error, _reason} -> put_flash(socket, :error, bindings_failed())
      end

    {:noreply, reload_book(socket)}
  end

  def handle_event("toggle_binding", %{"id" => id, "kind" => kind}, socket) do
    book_id = socket.assigns.editing_book.id
    scope = socket.assigns.current_scope

    binding =
      case kind do
        "chat" -> Lore.get_book_chat(scope, id)
        "character" -> Lore.get_book_character(scope, id)
        _ -> nil
      end

    case binding do
      %{lore_book_id: ^book_id} = binding ->
        case Lore.set_binding_enabled(scope, binding, !binding.enabled) do
          {:ok, _} ->
            {:noreply, reload_book(socket)}

          {:error, :unauthorized} ->
            {:noreply, flash_unauthorized(socket)}

          {:error, _} ->
            {:noreply, socket |> put_flash(:error, binding_failed()) |> reload_book()}
        end

      _ ->
        {:noreply, socket}
    end
  end

  ## Activation rules

  def handle_event("validate_rules", %{"lore_book_rules" => params}, socket) do
    changeset = Lore.change_book_rules(socket.assigns.rules_book, params)
    {:noreply, assign(socket, rules_form: to_form(changeset, as: :lore_book_rules, action: :validate))}
  end

  def handle_event("save_rules", %{"lore_book_rules" => params}, socket) do
    case Lore.set_book_rules(socket.assigns.current_scope, socket.assigns.rules_book, params) do
      {:ok, _book} ->
        socket = socket |> put_flash(:info, rules_saved()) |> reload_book()
        {:noreply, assign_rules_form(socket, socket.assigns.editing_book)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, rules_form: to_form(changeset, as: :lore_book_rules, action: :update))}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}
    end
  end

  ## Entries

  def handle_event("validate_entry", %{"lore_entry" => params}, socket),
    do: {:noreply, socket |> EntryForm.validate(params) |> refresh_open_row()}

  def handle_event("save_entry", %{"lore_entry" => params}, socket) do
    case EntryForm.save(socket, params) do
      {:ok, entry, socket} ->
        to =
          case socket.assigns.editing_book do
            nil -> ~p"/lore/entries/#{entry.id}/edit"
            book -> ~p"/lore/#{book.id}/entries/#{entry.id}/edit"
          end

        {:noreply,
         socket
         |> refresh()
         |> put_flash(:info, entry_saved(entry.name))
         |> push_patch(to: to)}

      {:partial, entry, unsaved, socket} ->
        {:noreply,
         socket
         |> refresh()
         |> put_flash(:error, EntryForm.partial_message(entry.name, unsaved))}

      {:held, hold, socket} ->
        to =
          case {socket.assigns.editing_book, socket.assigns.editing_entry} do
            {nil, nil} -> ~p"/lore"
            {nil, entry} -> ~p"/lore/entries/#{entry.id}/edit"
            {book, nil} -> ~p"/lore/#{book.id}/edit"
            {book, entry} -> ~p"/lore/#{book.id}/entries/#{entry.id}/edit"
          end

        {:noreply, socket |> refresh() |> flash_held(hold) |> push_patch(to: to)}

      {:error, message, socket} ->
        {:noreply, socket |> refresh_open_row() |> put_flash(:error, message)}
    end
  end

  # Compacts the Content as the form shows it (`MythweaverWeb.FieldCompaction`); the rewrite replaces
  # the field unsaved.
  def handle_event("compact_entry", _params, socket) do
    form = socket.assigns.entry_form

    kind =
      case socket.assigns.entry_memory do
        %{record: %Record{kind: kind}} -> Atom.to_string(kind)
        _none -> "lore"
      end

    attrs = %{title: form[:name].value, content: form[:content].value, kind: kind}

    {:noreply,
     socket
     |> FieldCompaction.start(:entry_compaction, compaction_target(socket), attrs)
     |> refresh_open_row()}
  end

  def handle_event("toggle_entry_diff", _params, socket),
    do: {:noreply, socket |> assign(entry_diff: !socket.assigns.entry_diff) |> refresh_open_row()}

  # The entry form's New pool dialog (`EntryForm.new_pool_modal/1`); a created pool is picked unsaved.
  def handle_event("new_entry_pool", _params, socket), do: {:noreply, EntryForm.open_new_pool(socket)}

  def handle_event("cancel_entry_pool", _params, socket), do: {:noreply, EntryForm.close_new_pool(socket)}

  def handle_event("validate_entry_pool", %{"lore_pool" => params}, socket),
    do: {:noreply, EntryForm.validate_new_pool(socket, params)}

  def handle_event("create_entry_pool", %{"lore_pool" => params}, socket) do
    case EntryForm.create_new_pool(socket, params) do
      {:ok, pool, socket} -> {:noreply, socket |> refresh_open_row() |> put_flash(:info, pool_created(pool.name))}
      {:invalid, socket} -> {:noreply, socket}
      {:error, message, socket} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("remove_from_book", %{"id" => id}, socket) do
    book = socket.assigns.editing_book

    case Lore.get_editable_entry(socket.assigns.current_scope, id) do
      nil ->
        {:noreply, socket}

      entry ->
        case Lore.remove_entry_from_book(socket.assigns.current_scope, book, entry) do
          {:ok, _membership} ->
            {:noreply,
             socket
             |> reload_book()
             |> put_flash(:info, removed_from_book(entry.name, book.name))
             |> close_entry_form(entry.id)}

          {:error, :unauthorized} ->
            {:noreply, flash_unauthorized(socket)}

          {:error, :not_a_member} ->
            {:noreply, put_flash(socket, :error, not_in_book(entry.name, book.name))}
        end
    end
  end

  def handle_event("sort_entries", %{"by" => column}, socket) when column in @entry_sort_columns do
    socket = assign(socket, entry_sort: next_sort(socket.assigns.entry_sort, column))
    {:noreply, load_entries(socket, socket.assigns.editing_book)}
  end

  # Dragging is off while a column sort is shown (the rows are not in persisted order then) or rows
  # are hidden (a partial order would be written); a stale tab's drop is refused here too. Either
  # way the reload snaps the rows to what is stored.
  def handle_event("reorder_entries", %{"ids" => ids}, socket) when is_list(ids) do
    if socket.assigns.entry_sort == nil and not socket.assigns.hide_disabled_memories do
      _ = Lore.reorder_book_entries(socket.assigns.current_scope, socket.assigns.editing_book, ids)
    end

    {:noreply, reload_book(socket)}
  end

  # This book's order for one row, from the table's inline number field. A bad value flashes and
  # the reload puts the stored number back.
  def handle_event("set_entry_order", %{"entry_id" => id, "order" => raw}, socket) do
    result =
      case Integer.parse(String.trim(raw)) do
        {order, ""} -> Lore.set_membership_order(socket.assigns.current_scope, socket.assigns.editing_book, id, order)
        _ -> :error
      end

    socket =
      case result do
        {:ok, _} -> socket
        {:error, :unauthorized} -> flash_unauthorized(socket)
        _ -> put_flash(socket, :error, bad_order())
      end

    {:noreply, reload_book(socket)}
  end

  def handle_event("clear_entry_sort", _params, socket) do
    {:noreply, socket |> assign(entry_sort: nil) |> load_entries(socket.assigns.editing_book)}
  end

  def handle_event("toggle_hide_disabled_memories", _params, %{assigns: %{editing_book: %LoreBook{} = book}} = socket) do
    socket = assign(socket, hide_disabled_memories: !socket.assigns.hide_disabled_memories)
    {:noreply, load_entries(socket, book)}
  end

  def handle_event("toggle_in_book", %{"id" => id}, socket) do
    book = socket.assigns.editing_book
    membership = Enum.find(book.book_entries, &(&1.lore_entry_id == id))

    case membership && Lore.set_membership_enabled(socket.assigns.current_scope, book, id, !membership.enabled) do
      {:ok, _membership} -> {:noreply, reload_book(socket)}
      {:error, :unauthorized} -> {:noreply, flash_unauthorized(socket)}
      _ -> {:noreply, put_flash(socket, :error, entry_not_in_book(book.name))}
    end
  end

  def handle_event("delete_entry", %{"id" => id}, socket) do
    case Lore.get_editable_entry(socket.assigns.current_scope, id) do
      nil ->
        {:noreply, socket}

      entry ->
        {:ok, _entry} = Lore.delete_entry(socket.assigns.current_scope, entry)

        socket =
          socket
          |> refresh()
          |> put_flash(:info, entry_deleted(entry.name))

        case socket.assigns.editing_book do
          nil -> {:noreply, push_patch(socket, to: ~p"/lore")}
          _book -> {:noreply, close_entry_form(socket, entry.id)}
        end
    end
  end

  # Row selection, the base of the bulk actions. Every change reloads the rows (`load_entries/2`) so
  # each stream row's checkbox renders the current selection.
  #
  # A shift-click range comes from the `RangeSelect` hook (assets/js/hooks/range_select.ts), which
  # works out the rows in the order shown: every listed id the book's table holds is added.
  def handle_event("select_entry_range", %{"ids" => ids}, %{assigns: %{editing_book: %LoreBook{} = book}} = socket)
      when is_list(ids) do
    selected = Selection.add_range(socket.assigns.selected_entry_ids, ids, socket.assigns.entry_ids)
    {:noreply, socket |> assign(selected_entry_ids: selected) |> load_entries(book)}
  end

  def handle_event("toggle_entry_selection", %{"id" => id}, %{assigns: %{editing_book: %LoreBook{} = book}} = socket) do
    selected = Selection.toggle(socket.assigns.selected_entry_ids, id, socket.assigns.entry_ids)

    {:noreply, socket |> assign(selected_entry_ids: selected) |> load_entries(book)}
  end

  def handle_event("toggle_all_entries", _params, %{assigns: %{editing_book: %LoreBook{} = book}} = socket) do
    selected = Selection.toggle_all(socket.assigns.selected_entry_ids, socket.assigns.entry_ids)

    {:noreply, socket |> assign(selected_entry_ids: selected) |> load_entries(book)}
  end

  def handle_event("clear_entry_selection", _params, %{assigns: %{editing_book: %LoreBook{} = book}} = socket) do
    {:noreply, socket |> assign(selected_entry_ids: MapSet.new()) |> load_entries(book)}
  end

  def handle_event("mark_entries_as_memories", _params, %{assigns: %{editing_book: %LoreBook{} = book}} = socket) do
    selected = MapSet.to_list(socket.assigns.selected_entry_ids)

    case Memory.mark_as_memories(socket.assigns.current_scope, book, selected) do
      {:ok, counts} -> {:noreply, socket |> load_entries(book) |> put_flash(:info, marked_message(counts))}
      {:error, :unauthorized} -> {:noreply, flash_unauthorized(socket)}
    end
  end

  def handle_event("unmark_entry_memories", _params, %{assigns: %{editing_book: %LoreBook{} = book}} = socket) do
    selected = MapSet.to_list(socket.assigns.selected_entry_ids)

    case Memory.unmark_memories(socket.assigns.current_scope, book, selected) do
      {:ok, counts} -> {:noreply, socket |> load_entries(book) |> put_flash(:info, unmarked_message(counts))}
      {:error, :unauthorized} -> {:noreply, flash_unauthorized(socket)}
    end
  end

  # A selection event that arrives after the book closed (a stale click) has nothing to act on.
  def handle_event(event, _params, socket)
      when event in ~w(toggle_entry_selection select_entry_range toggle_all_entries clear_entry_selection
                       mark_entries_as_memories unmark_entry_memories), do: {:noreply, socket}

  @impl true
  def handle_info({:job_changed, %{id: id, status: status}}, %{assigns: %{entry_compaction: %{id: id}}} = socket)
      when FieldCompaction.finished?(status) do
    {:noreply,
     socket
     |> FieldCompaction.finish(:entry_compaction, compaction_target(socket), &EntryForm.put_content/2)
     |> refresh_open_row()}
  end

  def handle_info({:job_changed, _change}, socket), do: {:noreply, socket}
  def handle_info({:job_progress, _progress}, socket), do: {:noreply, socket}
  def handle_info({:job_queue, _positions}, socket), do: {:noreply, socket}

  # The entry form showing now (nil when closed), so a rewrite lands only in the form it came from.
  defp compaction_target(%{assigns: %{entry_form: nil}}), do: nil
  defp compaction_target(%{assigns: %{editing_entry: entry}}), do: {:entry, entry && entry.id}

  defp marked_message(%{marked: marked, skipped: 0}) do
    gettext_comment("Info flash after marking the selected lore entries as memories.")

    case marked do
      0 ->
        dgettext("lore", "No entries were marked as memories.")

      n ->
        dngettext("lore", "Marked %{marked_count} entry as a memory.", "Marked %{marked_count} entries as memories.", n,
          marked_count: Mythweaver.Format.number(n)
        )
    end
  end

  defp marked_message(%{marked: marked, skipped: skipped}) do
    gettext_comment(
      "Info flash after marking the selected lore entries as memories; skipped_count entries already were memories. The plural follows skipped_count."
    )

    bindings = [marked_count: Mythweaver.Format.number(marked), skipped_count: Mythweaver.Format.number(skipped)]

    case marked do
      0 ->
        dngettext(
          "lore",
          "No entries were marked as memories; %{skipped_count} already was a memory.",
          "No entries were marked as memories; %{skipped_count} already were memories.",
          skipped,
          bindings
        )

      1 ->
        dngettext(
          "lore",
          "Marked %{marked_count} entry as a memory; %{skipped_count} already was a memory.",
          "Marked %{marked_count} entry as a memory; %{skipped_count} already were memories.",
          skipped,
          bindings
        )

      _n ->
        dngettext(
          "lore",
          "Marked %{marked_count} entries as memories; %{skipped_count} already was a memory.",
          "Marked %{marked_count} entries as memories; %{skipped_count} already were memories.",
          skipped,
          bindings
        )
    end
  end

  defp unmarked_message(%{unmarked: unmarked, skipped: 0}) do
    gettext_comment("Info flash after unmarking the selected lore entries as memories.")

    case unmarked do
      0 ->
        dpgettext(
          "lore",
          "status: flash after unmarking lore entries as memories when none changed",
          "No memories were unmarked."
        )

      n ->
        dpngettext(
          "lore",
          "status: flash after unmarking lore entries as memories",
          "Unmarked %{unmarked_count} memory.",
          "Unmarked %{unmarked_count} memories.",
          n,
          unmarked_count: Mythweaver.Format.number(n)
        )
    end
  end

  defp unmarked_message(%{unmarked: unmarked, skipped: skipped}) do
    gettext_comment(
      "Info flash after unmarking the selected lore entries as memories; skipped_count were kept. The plural follows skipped_count."
    )

    bindings = [unmarked_count: Mythweaver.Format.number(unmarked), skipped_count: Mythweaver.Format.number(skipped)]

    case unmarked do
      0 ->
        dngettext(
          "lore",
          "No memories were unmarked; %{skipped_count} was kept (consolidated, or not a plain memory).",
          "No memories were unmarked; %{skipped_count} were kept (consolidated, or not plain memories).",
          skipped,
          bindings
        )

      1 ->
        dngettext(
          "lore",
          "Unmarked %{unmarked_count} memory; %{skipped_count} was kept (consolidated, or not a plain memory).",
          "Unmarked %{unmarked_count} memory; %{skipped_count} were kept (consolidated, or not plain memories).",
          skipped,
          bindings
        )

      _n ->
        dngettext(
          "lore",
          "Unmarked %{unmarked_count} memories; %{skipped_count} was kept (consolidated, or not a plain memory).",
          "Unmarked %{unmarked_count} memories; %{skipped_count} were kept (consolidated, or not plain memories).",
          skipped,
          bindings
        )
    end
  end

  defp lore_title, do: dpgettext("lore", "page title: lore books and entries", "Lore")

  defp entry_not_found do
    gettext_comment("Error flash when the lore entry in the URL does not exist or is not editable.")
    dpgettext("lore", "status: flash when the lore entry in the URL is not found", "Lore entry not found")
  end

  defp book_not_found do
    gettext_comment("Error flash when the lore book in the URL does not exist or is not editable.")
    dpgettext("lore", "status: flash when the lore book in the URL is not found", "Lore book not found")
  end

  defp place_gone do
    gettext_comment("Error flash when a dragged lore entry or its target book was deleted meanwhile.")
    dgettext("lore", "That entry or book no longer exists")
  end

  defp save_failed do
    gettext_comment("Flash when saving an editor form fails validation; the invalid fields are highlighted.")
    dgettext("lore", "Could not save — see the highlighted fields")
  end

  defp book_saved_message(book_name, []) do
    gettext_comment("Info flash after a lore book is saved.")
    dpgettext("lore", "status: flash after saving a lore book", "%{book_name} saved", book_name: book_name)
  end

  defp book_saved_message(book_name, [:tags]) do
    gettext_comment("Error flash: a lore book saved, but its tags did not.")
    dgettext("lore", "%{book_name} saved, but its tags did not", book_name: book_name)
  end

  defp book_saved_message(book_name, [:tag_filter]) do
    gettext_comment("Error flash: a lore book saved, but its tag filter did not.")
    dgettext("lore", "%{book_name} saved, but its tag filter did not", book_name: book_name)
  end

  defp book_saved_message(book_name, [:tags, :tag_filter]) do
    gettext_comment("Error flash: a lore book saved, but neither its tags nor its tag filter did.")
    dgettext("lore", "%{book_name} saved, but its tags and its tag filter did not", book_name: book_name)
  end

  defp transferred(book_name) do
    gettext_comment("Info flash after a personal lore book is moved to the site.")
    dgettext("lore", "%{book_name} is now a site book", book_name: book_name)
  end

  defp bindings_failed do
    gettext_comment("Error flash when a lore book's chat and character bindings fail to save.")
    dgettext("lore", "Could not save the bindings")
  end

  defp binding_failed do
    gettext_comment("Error flash when pausing or resuming one lore book binding fails.")
    dgettext("lore", "Could not update the binding")
  end

  defp rules_saved do
    gettext_comment("Info flash after a lore book's activation rules are saved.")
    dpgettext("lore", "status: flash after saving a lore book's activation rules", "Activation rules saved")
  end

  defp entry_saved(entry_name) do
    gettext_comment("Info flash after a lore entry is saved.")
    dpgettext("lore", "status: flash after saving a lore entry", "%{entry_name} saved", entry_name: entry_name)
  end

  defp pool_created(pool_name) do
    gettext_comment("Info flash after a lore pool is created from the entry form.")
    dpgettext("lore", "status: flash after creating a lore pool", "%{pool_name} created", pool_name: pool_name)
  end

  defp removed_from_book(entry_name, book_name) do
    gettext_comment("Info flash after a lore entry is removed from a book (the entry itself stays).")

    dpgettext(
      "lore",
      "status: flash after removing a lore entry from a book",
      "%{entry_name} removed from %{book_name}",
      entry_name: entry_name,
      book_name: book_name
    )
  end

  defp not_in_book(entry_name, book_name) do
    gettext_comment("Error flash when removing a lore entry from a book it is no longer in.")
    dgettext("lore", "%{entry_name} is not in %{book_name}", entry_name: entry_name, book_name: book_name)
  end

  defp entry_not_in_book(book_name) do
    gettext_comment("Error flash when switching a lore entry on or off in a book it is no longer in.")
    dgettext("lore", "That entry is not in %{book_name}", book_name: book_name)
  end

  defp bad_order do
    gettext_comment("Error flash when a lore entry's order in a book is not a valid number.")
    dgettext("lore", "Order must be a whole number, 0 or more")
  end

  defp entry_deleted(entry_name) do
    gettext_comment("Info flash after a lore entry is deleted.")
    dpgettext("lore", "status: flash after deleting a lore entry", "%{entry_name} deleted", entry_name: entry_name)
  end

  @doc false
  def delete_confirm(item_name) do
    gettext_comment("Confirm dialog before deleting a lore book or entry.")

    dpgettext("lore", "status: confirm dialog before deleting a lore book or entry", "Delete %{item_name}?",
      item_name: item_name
    )
  end

  defp visibility_label,
    do: dpgettext("lore", "field label: what non-admin users see of a site lore book", "Visible to users")

  defp visibility_options,
    do: [
      {dpgettext("lore", "option: users see all of a site lore book", "Everything"), "readable"},
      {dpgettext("lore", "option: users see only a site lore book's names", "Names only (runtime-only)"),
       "runtime_only"},
      {dpgettext("lore", "option: users see nothing of a site lore book", "Nothing (hidden)"), "hidden"}
    ]

  defp priority_label, do: dpgettext("lore", "field label: priority of a lore book", "Priority")
  defp token_budget_label, do: dpgettext("lore", "field label: token budget of a lore book", "Token budget")

  defp book_scan_depth_label,
    do: dpgettext("lore", "field label: how many recent messages a lore book scans", "Scan depth")

  defp unlinked_label, do: dpgettext("lore", "heading: folder of lore entries in no book", "Unlinked")

  defp shared_label(book_count),
    do:
      dpngettext(
        "lore",
        "tooltip: a lore entry sits in several books",
        "In %{book_count} book",
        "In %{book_count} books",
        book_count, book_count: Mythweaver.Format.number(book_count))

  defp make_site_book, do: dpgettext("lore", "button: move a personal lore book to the site", "Make site book")
  defp global_default, do: dpgettext("lore", "placeholder: empty value uses the global lore setting", "Global default")

  # The inline form must not keep editing a row that no longer exists, nor a membership set this
  # book has just dropped (its next Save would put it back).
  defp close_entry_form(%{assigns: %{editing_entry: %{id: id}}} = socket, id) do
    push_patch(socket, to: ~p"/lore/#{socket.assigns.editing_book.id}/edit")
  end

  defp close_entry_form(socket, _id), do: socket

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp target_book(%{assigns: %{editing_book: nil, new_owner: "personal", current_scope: scope}}),
    do: %LoreBook{user_id: scope.user.id}

  defp target_book(socket), do: socket.assigns.editing_book || %LoreBook{}

  # The book's tags (`all["tags"]`) and tag filter (`params["filter_tags"]`) live in assigns, not in
  # the `LoreBook` changeset.
  defp lift_book_tags(params, all, socket) do
    socket = put_tag_params(socket, :book, all["tags"])

    socket =
      case params do
        %{"filter_tags" => texts} -> assign(socket, book_filter_tags: texts |> List.wrap() |> Enum.reject(&(&1 == "")))
        _ -> socket
      end

    {Map.delete(params, "filter_tags"), socket}
  end

  # Writes the book's tags and tag filter after the book itself saved; returns what did not save.
  defp save_book_tags(socket, book) do
    {socket, unsaved} =
      case save_tags(socket, :book, book) do
        {:ok, socket} -> {socket, []}
        {:error, _what, socket} -> {socket, [:tags]}
      end

    case Lore.set_book_filter_tags(socket.assigns.current_scope, book, socket.assigns.book_filter_tags) do
      {:ok, :ok} -> {socket, unsaved}
      {:error, _} -> {socket, unsaved ++ [:tag_filter]}
    end
  end

  defp personal_for_admin?(%LoreBook{user_id: user_id}, scope),
    do: user_id != nil and Scope.can?(scope, "site.content.manage")

  # One line per kind of link the move to the site removes, from `Lore.transfer_impact/3`; kinds it
  # leaves alone say nothing. The entries' own move is not a warning: the dialog's lead says it.
  defp transfer_warnings(impact) do
    [
      {:other_books, impact.other_books},
      {:pools, impact.pools},
      {:entry_filters, impact.entry_filters},
      {:character_bindings, impact.character_bindings},
      {:tag_filters, impact.tag_filters + impact.book_tag_filters},
      {:rules, impact.rule_chats + impact.rule_characters},
      {:side_prompts, impact.side_prompts}
    ]
    |> Enum.reject(fn {_kind, count} -> count == 0 end)
    |> Enum.map(fn {kind, count} -> transfer_warning(kind, Mythweaver.Format.number(count)) end)
  end

  defp transfer_warning(:other_books, n),
    do: dgettext("lore", "Its entries leave other books they are in: %{link_count}.", link_count: n)

  defp transfer_warning(:pools, n), do: dgettext("lore", "Its entries leave their pools: %{link_count}.", link_count: n)

  defp transfer_warning(:entry_filters, n),
    do:
      dgettext("lore", "Character filters on its entries that name personal characters are removed: %{link_count}.",
        link_count: n
      )

  defp transfer_warning(:character_bindings, n),
    do: dgettext("lore", "Bindings to personal characters are removed: %{link_count}.", link_count: n)

  defp transfer_warning(:tag_filters, n),
    do: dgettext("lore", "Tag filters naming personal tags are removed: %{link_count}.", link_count: n)

  defp transfer_warning(:rules, n),
    do:
      dgettext(
        "lore",
        "Activation rule conditions naming chats or personal characters lose their target: %{link_count}.",
        link_count: n
      )

  defp transfer_warning(:side_prompts, n),
    do: dgettext("lore", "Side prompts stop writing into this book: %{link_count}.", link_count: n)

  defp new_entry_path(nil), do: ~p"/lore/entries/new"
  defp new_entry_path(%LoreBook{id: id}), do: ~p"/lore/entries/new?#{[book: id]}"

  # This book's membership switch for a row; rows come from `Lore.list_entries_in_book/1`, which
  # preloads `book_entries`.
  @doc false
  def enabled_in_book?(entry, book) do
    Enum.any?(entry.book_entries, &(&1.lore_book_id == book.id and &1.enabled))
  end

  @doc false
  def membership_order(entry, book) do
    case Enum.find(entry.book_entries, &(&1.lore_book_id == book.id)) do
      nil -> nil
      membership -> membership.order
    end
  end

  defp effective_order(entry, book), do: (membership_order(entry, book) || 0) + book.order_adjustment

  @impl true
  def render(assigns) do
    ~H"""
    <%!--
      `lower-bound="none"`: rules here may reach
      inside `<.input>`'s own template, which is a nested-component root carrying `phx-r` that the
      default exclusive bound cuts off.
    --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      /* The editor slot's root. `pane_layout`'s `<section>` carries no marker from this block, so
         without it `<.form>` and the panels would sit outside this scope. */
      div.lore-book-editor-body:scope {
        display: contents;
      }

      .lore-book-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .lore-book-form label {
        display: block;
      }

      #lore-book-entries label {
        display: block;
      }

      /* `:where`: an id here would outrank the character picker's `label.multi-select-row`. */
      :where(#lore-book-bindings) label {
        display: block;
      }

      .lore-bindings-list {
        list-style: none;
        margin: 0;
        padding: 0;
        border: 1px solid var(--border-grey);
        border-radius: var(--radius-2);
        background: var(--surface-2);
      }

      .lore-binding {
        display: flex;
        align-items: center;
        gap: var(--size-1);
        padding: var(--size-2) var(--size-3);
        border-bottom: 1px solid var(--border-grey);
      }

      .lore-binding:last-child {
        border-bottom: 0;
      }

      .lore-binding-empty,
      .lore-entries-empty {
        margin: 0;
        color: var(--muted-foreground);
      }

      .lore-entries-list {
        list-style: none;
        margin: 0;
        padding: 0;
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
      }

      /* One grid for the column headers and every collapsed row, so the cells line up like
         SillyTavern's entry table: selection checkbox, drag handle, expand, in-book checkbox, name,
         activation, position, order, trigger %, actions. Every track is fixed but the name's, so the
         header row (with an empty actions cell) and the rows share widths. */
      .lore-entries-columns,
      .lore-entry-summary {
        display: grid;
        grid-template-columns:
          1rem 1rem 1.75rem 1.5rem minmax(0, 1fr)
          2rem 4.5rem 4.5rem 4.5rem 4.5rem;
        align-items: center;
        gap: var(--size-2);
      }

      .lore-entries-columns {
        padding: 0 var(--size-2);
        border: 1px solid transparent;
        color: var(--muted-foreground);
        font-size: 0.75rem;
        text-transform: uppercase;
      }

      .lore-entries-sort {
        display: inline-flex;
        align-items: center;
        gap: 0.2rem;
        padding: 0;
        border: 0;
        background: none;
        color: inherit;
        font: inherit;
        text-transform: inherit;
        cursor: pointer;
      }

      .lore-entries-sort:hover,
      .lore-entries-sort[aria-pressed="true"] {
        color: var(--primary-accent);
      }

      .lore-entries-filters {
        display: flex;
        gap: var(--size-2);
      }

      .lore-entries-sorted {
        display: flex;
        align-items: center;
        gap: var(--size-2);
        margin: 0;
        color: var(--muted-foreground);
        font-size: 0.85rem;
      }

      /* The reset indents `li`; the row is a full-width grid box. */
      .lore-entry-row {
        padding: 0;
        border: 1px solid var(--border-grey);
        border-radius: var(--radius-2);
        background: var(--surface-2);
      }

      .lore-entry-summary {
        padding: var(--size-1) var(--size-2);
      }

      .lore-entry-expand {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        inline-size: 1.75rem;
        block-size: 1.75rem;
        border-radius: var(--radius-round);
        background: var(--surface-5);
        color: var(--foreground);
        text-decoration: none;
      }

      .lore-entry-expand:hover {
        background: var(--surface-7);
      }

      .lore-entry-in-book,
      .lore-entry-select {
        margin: 0;
        accent-color: var(--primary-accent);
      }

      .lore-entry-memory-badge {
        flex: none;
        padding: 0 var(--size-1);
        border: 1px solid var(--primary-accent);
        border-radius: var(--radius-2);
        color: var(--primary-accent);
        font-size: 0.75rem;
        line-height: 1.4;
      }

      .lore-entry-title {
        display: flex;
        align-items: center;
        gap: var(--size-2);
        min-width: 0;
      }

      .lore-entry-name {
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
        color: inherit;
        font-weight: 600;
        text-decoration: none;
      }

      .lore-entry-name:hover {
        text-decoration: underline;
      }

      .lore-entry-shared {
        flex: none;
        color: var(--muted-foreground);
        font-size: 0.8rem;
      }

      .lore-entry-activation {
        display: inline-flex;
        justify-content: center;
        color: var(--muted-foreground);
      }

      .lore-entry-activation[data-activation="constant"] {
        color: var(--primary-accent);
      }

      .lore-entry-cell {
        padding: var(--size-1) var(--size-2);
        border-radius: var(--radius-2);
        background: var(--surface-1);
        font-variant-numeric: tabular-nums;
        white-space: nowrap;
        overflow: hidden;
        text-overflow: ellipsis;
      }

      .lore-entry-actions {
        display: flex;
        gap: var(--size-1);
      }

      /* Not active in this book (its membership is unchecked). ST dims the whole row. */
      .lore-entry-row--off
        .lore-entry-summary
        > :not(.lore-entry-in-book, .lore-entry-expand, .lore-entry-select) {
        opacity: 50%;
      }

      .lore-entry-detail {
        padding: var(--size-3);
        border-top: 1px solid var(--border-grey);
      }

      .lore-entry-order-form {
        margin: 0;
        min-inline-size: 0;
      }

      .lore-entry-order {
        inline-size: 100%;
        border: 1px solid var(--border-grey);
        color: inherit;
        font: inherit;
      }

      /* The list slot's root tags are scope roots themselves, so their rules need `:scope`. */
      div.lore-tree:scope,
      ul.lore-search-results:scope {
        padding: 0 var(--size-1) var(--size-2);
      }

      .lore-tree-summary {
        display: flex;
        align-items: center;
        gap: var(--size-2);
        padding: var(--size-1) var(--size-2);
        border-radius: var(--radius-2);
        cursor: pointer;
        list-style: none;
      }

      .lore-tree-summary::-webkit-details-marker {
        display: none;
      }

      .lore-tree-chevron {
        flex: none;
        line-height: 0;
        color: var(--muted-foreground);
        transition: transform 0.15s;
      }

      details[open] > .lore-tree-summary .lore-tree-chevron {
        transform: rotate(90deg);
      }

      .lore-tree-book {
        flex: 1;
        min-inline-size: 0;
        overflow-wrap: anywhere;
        color: inherit;
        font-weight: 600;
        text-decoration: none;
      }

      .lore-tree-owner {
        color: var(--muted-foreground);
        font-size: 0.75rem;
        text-transform: uppercase;
        letter-spacing: 0.04em;
        border: 1px solid var(--border);
        border-radius: var(--radius-1);
        padding: 0 var(--size-1);
      }

      .lore-book-owner {
        display: flex;
        align-items: center;
        gap: var(--size-3);
        color: var(--muted-foreground);
      }

      /* A root tag of `<.modal>`'s slot: it carries this block's marker, so it is a scope root. */
      div:scope.lore-book-transfer-actions {
        display: flex;
        justify-content: flex-end;
        gap: var(--size-2);
      }

      .lore-tree-count {
        color: var(--muted-foreground);
        font-size: 0.85rem;
        font-variant-numeric: tabular-nums;
      }

      /* A floor height, so an empty open folder still takes a drop. */
      .lore-tree-children {
        min-block-size: 1.5rem;
        list-style: none;
        margin: 0;
        padding: 0 0 0 var(--size-4);
      }

      .lore-tree-entry,
      .lore-search-results > li {
        display: flex;
        align-items: center;
        gap: var(--size-2);
        padding: 0 var(--size-2);
        border-radius: var(--radius-2);
      }

      .lore-tree-entry > a,
      .lore-tree-entry > label.bulk-check,
      .lore-search-results > li > a,
      .lore-search-results > li > label.bulk-check {
        flex: 1;
        min-inline-size: 0;
        padding: var(--size-1) 0;
        overflow-wrap: anywhere;
        color: inherit;
        text-decoration: none;
      }

      ul.lore-search-results:scope {
        list-style: none;
        margin: 0;
      }

      .lore-search-results > li > a {
        display: flex;
        flex-direction: column;
      }

      .lore-search-name {
        font-weight: 600;
      }

      .lore-search-meta,
      .lore-search-empty {
        color: var(--muted-foreground);
        font-size: 0.85rem;
      }

      .lore-tree-summary:hover,
      .lore-tree-entry:hover,
      .lore-search-results > li:hover {
        background: var(--surface-4);
      }

      .lore-tree-summary[aria-current="page"],
      .lore-tree-entry:has(> a[aria-current="page"]),
      .lore-search-results > li:has(> a[aria-current="page"]) {
        background-color: color-mix(in oklab, var(--primary-accent) 13%, transparent);
        color: var(--primary-accent);
      }

      .lore-tree-entry--off {
        opacity: 50%;
      }

      .lore-tree-shared {
        margin-inline-start: auto;
        line-height: 0;
        color: var(--muted-foreground);
      }

      #lore-tree-folder-unlinked .lore-tree-book {
        font-style: italic;
      }

      /* Phones and coarse pointers (their 44px icon buttons overflow the fixed tracks): each entry
         is a two-line card. Line 1: select, handle, expand, in-book, name (with "also in" under it),
         actions; line 2: activation, Position, Order, Trigger, as one row of chips. */
      @media (--phone), (--coarse) {
        .lore-entries-columns {
          display: flex;
          flex-wrap: wrap;
          align-items: center;
          gap: var(--size-1) var(--size-3);
        }
        .lore-entries-columns > span:empty {
          display: none;
        }
        .lore-entry-summary {
          display: flex;
          flex-wrap: wrap;
          align-items: center;
          gap: var(--size-2);
        }
        .lore-entry-title {
          flex: 1 1 0;
          flex-wrap: wrap;
          row-gap: 0;
          min-inline-size: 0;
        }
        .lore-entry-name {
          max-inline-size: 100%;
        }
        .lore-entry-shared {
          flex-basis: 100%;
        }
        .lore-entry-actions {
          order: 1;
        }
        .lore-entry-summary::after {
          content: "";
          flex-basis: 100%;
          order: 2;
        }
        :is(.lore-entry-activation, .lore-entry-cell, .lore-entry-order-form) {
          order: 3;
        }
        [data-label]::before {
          content: attr(data-label) ": ";
          color: var(--muted-foreground);
          font-size: 0.75rem;
        }
        .lore-entry-order-form[data-label] {
          display: inline-flex;
          align-items: center;
          gap: var(--size-1);
        }
        .lore-entry-order {
          inline-size: 3rem;
        }
        /* Line 2's chips, small enough to share one row on a 360px phone. */
        :is(.lore-entry-cell, .lore-entry-order) {
          padding-inline: var(--size-1);
        }
        .lore-entry-summary > :is(.lore-entry-cell, .lore-entry-order-form) {
          font-size: 0.875rem;
        }
        .lore-entry-summary {
          column-gap: var(--size-1);
        }
      }

      .lore-rules-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .lore-rule {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
        padding: var(--size-2);
        border: 1px solid var(--border);
        border-radius: var(--radius-2);
      }

      .lore-rule-row {
        display: flex;
        flex-wrap: wrap;
        gap: var(--size-2);
        align-items: flex-end;
      }

      .lore-rule-condition {
        display: flex;
        flex-wrap: wrap;
        gap: var(--size-2);
        align-items: flex-end;
        padding-inline-start: var(--size-3);
      }

      .lore-rule-errors {
        margin: 0;
        color: var(--destructive);
      }

      .lore-rules-hint {
        color: var(--muted-foreground);
      }

      @media (--coarse) {
        .lore-entry-expand {
          inline-size: var(--touch-target);
          block-size: var(--touch-target);
        }
      }
    </style>
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      search={if @editing_book, do: {:lore_book, @editing_book}, else: :lore}
    >
      <.pane_layout>
        <:list
          id="lore-nav"
          label={dpgettext("lore", "aria label: list of lore books and entries", "Lore")}
        >
          <.pane_header title={dpgettext("lore", "heading: list of lore books and entries", "Lore")}>
            <:switch id="pane-switch-pools" navigate={~p"/lore/pools"}>
              <.lucide name="layers" /> {dpgettext(
                "lore",
                "link: switch to the lore pools list",
                "Pools"
              )}
            </:switch>
          </.pane_header>

          <.pane_actions>
            <.button variant="primary" size="sm" patch={~p"/lore/new"} id="new-lore-book">
              <.lucide name="plus" /> {dpgettext("lore", "button: create a lore book", "New book")}
            </.button>
            <.button size="sm" patch={new_entry_path(@editing_book)} id="new-lore-entry-standalone">
              <.lucide name="plus" /> {dpgettext("lore", "button: create a lore entry", "New entry")}
            </.button>
            <.button size="sm" navigate={~p"/import"} id="import-lore">
              <.lucide name="upload" /> {dpgettext("lore", "button: open the import page", "Import")}
            </.button>
            <.bulk_toggle bulk={@bulk} id="lore-bulk-toggle" />
          </.pane_actions>
          <.bulk_bar bulk={@bulk} id="lore-bulk" />

          <.pane_search
            id="lore-book-filter"
            form={@filter_form}
            placeholder={dgettext("lore", "Book name, or entry name, content or keyword")}
          >
            <.tag_filter
              id="lore-filter-tags"
              values={@tag_filter}
              vocabulary={@tag_vocabulary}
              errors={@tag_filter_errors}
              invalid={@tag_filter_invalid}
            />
          </.pane_search>

          <ul
            :if={@searching?}
            id="lore-search-results"
            class="lore-search-results"
            phx-hook="RangeSelect"
            data-range-event="bulk_range"
          >
            <li :for={book <- @search_results.books} id={"lore-search-book-#{book.id}"}>
              <.bulk_check :if={@bulk.active?} bulk={@bulk} list="lore_books" id={book.id}>
                <span class="lore-search-name">{book.name}</span>
              </.bulk_check>
              <.link
                :if={!@bulk.active?}
                patch={~p"/lore/#{book.id}/edit"}
                aria-current={book.id == @selected_id && "page"}
              >
                <span class="lore-search-name">{book.name}</span>
                <span class="lore-search-meta">{dpgettext(
                  "lore",
                  "badge: search result is a lore book",
                  "Lore book"
                )}</span>
              </.link>
            </li>
            <li :for={entry <- @search_results.entries} id={"lore-search-entry-#{entry.id}"}>
              <.bulk_check :if={@bulk.active?} bulk={@bulk} list="lore_entries" id={entry.id}>
                <span class="lore-search-name">{entry.name}</span>
              </.bulk_check>
              <.link
                :if={!@bulk.active?}
                patch={~p"/lore/entries/#{entry.id}/edit"}
                aria-current={entry.id == @selected_entry_id && "page"}
              >
                <span class="lore-search-name">{entry.name}</span>
                <span class="lore-search-meta">
                  {if entry.books == [],
                    do: unlinked_label(),
                    else: Enum.map_join(entry.books, ", ", & &1.name)}
                </span>
              </.link>
            </li>
            <li
              :if={@search_results.books == [] and @search_results.entries == []}
              class="lore-search-empty"
            >
              {dpgettext(
                "lore",
                "empty state: no lore books or entries match the search",
                "Nothing matches this search"
              )}
            </li>
          </ul>

          <%!-- The server never renders `open`: the LoreTree hook owns it (localStorage). --%>
          <div
            id="lore-tree"
            class="lore-tree"
            phx-hook="LoreTree"
            data-storage-key="mythweaver:lore-tree:open"
            hidden={@searching?}
          >
            <%!-- `RangeSelect` for bulk select mode; `#lore-tree` already holds the `LoreTree` hook. --%>
            <div id="lore-tree-select" phx-hook="RangeSelect" data-range-event="bulk_range">
              <details
                :for={folder <- @tree.books}
                id={"lore-tree-folder-#{folder.book.id}"}
                class="lore-tree-folder"
                data-folder-key={folder.book.id}
              >
                <summary
                  class="lore-tree-summary"
                  aria-current={folder.book.id == @selected_id && "page"}
                >
                  <span class="lore-tree-chevron" aria-hidden="true"><.lucide name="chevron-right" /></span>
                  <.bulk_check
                    :if={@bulk.active?}
                    bulk={@bulk}
                    list="lore_books"
                    id={folder.book.id}
                    class="lore-tree-book"
                  >
                    {folder.book.name}
                  </.bulk_check>
                  <.link
                    :if={!@bulk.active?}
                    patch={~p"/lore/#{folder.book.id}/edit"}
                    class="lore-tree-book"
                  >
                    {folder.book.name}
                  </.link>
                  <%!-- An admin's tree mixes the site's books with their own; mark the own ones. --%>
                  <span
                    :if={personal_for_admin?(folder.book, @current_scope)}
                    id={"lore-tree-personal-#{folder.book.id}"}
                    class="lore-tree-owner"
                    title={dgettext("lore", "Your own book: only you see and use it")}
                  >
                    {dpgettext("lore", "badge: lore book is personal, not the site's", "Personal")}
                  </span>
                  <span class="lore-tree-count">{length(folder.entries)}</span>
                </summary>
                <ul class="lore-tree-children" data-tree-folder data-book-id={folder.book.id}>
                  <li
                    :for={row <- folder.entries}
                    id={"lore-tree-#{folder.book.id}-#{row.entry.id}"}
                    data-entry-id={row.entry.id}
                    class={[
                      "lore-tree-entry",
                      !row.membership.enabled && "lore-tree-entry--off"
                    ]}
                  >
                    <.drag_handle title={dgettext("lore", "Drag to move (hold Cmd/Ctrl to copy)")} />
                    <.bulk_check
                      :if={@bulk.active?}
                      bulk={@bulk}
                      list="lore_entries"
                      id={row.entry.id}
                      dom_id={"bulk-lore_entries-#{folder.book.id}-#{row.entry.id}"}
                    >
                      {row.entry.name}
                    </.bulk_check>
                    <.link
                      :if={!@bulk.active?}
                      patch={~p"/lore/entries/#{row.entry.id}/edit"}
                      aria-current={row.entry.id == @selected_entry_id && "page"}
                    >
                      {row.entry.name}
                    </.link>
                    <span
                      :if={row.book_count > 1}
                      class="lore-tree-shared"
                      title={shared_label(row.book_count)}
                      aria-label={shared_label(row.book_count)}
                    >
                      <.lucide name="book-copy" />
                    </span>
                  </li>
                </ul>
              </details>
              <details
                id="lore-tree-folder-unlinked"
                class="lore-tree-folder"
                data-folder-key="unlinked"
              >
                <summary class="lore-tree-summary">
                  <span class="lore-tree-chevron" aria-hidden="true"><.lucide name="chevron-right" /></span>
                  <span class="lore-tree-book">{unlinked_label()}</span>
                  <span class="lore-tree-count">{length(@tree.unlinked)}</span>
                </summary>
                <ul class="lore-tree-children" data-tree-folder data-book-id="">
                  <li
                    :for={entry <- @tree.unlinked}
                    id={"lore-tree-unlinked-#{entry.id}"}
                    data-entry-id={entry.id}
                    class="lore-tree-entry"
                  >
                    <.drag_handle title={
                      dpgettext(
                        "lore",
                        "tooltip: drag handle of an unlinked lore entry",
                        "Drag to a book"
                      )
                    } />
                    <.bulk_check :if={@bulk.active?} bulk={@bulk} list="lore_entries" id={entry.id}>
                      {entry.name}
                    </.bulk_check>
                    <.link
                      :if={!@bulk.active?}
                      patch={~p"/lore/entries/#{entry.id}/edit"}
                      aria-current={entry.id == @selected_entry_id && "page"}
                    >
                      {entry.name}
                    </.link>
                  </li>
                </ul>
              </details>
            </div>
          </div>
        </:list>

        <:editor id="lore-book-editor">
          <%!-- One notice for the open book and the open entry, inline or full-pane. --%>
          <.pane_section :if={@changed_elsewhere?}>
            <.changed_elsewhere id="lore-changed-elsewhere" patch={@live_sync_path} />
          </.pane_section>

          <div :if={@live_action in [:entry_new, :entry_edit]} class="lore-book-editor-body">
            <.panel_header sticky>
              {if @editing_entry,
                do: @editing_entry.name,
                else: dpgettext("lore", "heading: create a lore entry", "New entry")}
              <:actions :if={@editing_entry}>
                <.pane_delete
                  :if={Ownership.deletable?(@current_scope, @editing_entry)}
                  id="delete-lore-entry"
                  phx-click="delete_entry"
                  phx-value-id={@editing_entry.id}
                  confirm={delete_confirm(@editing_entry.name)}
                >
                  {dpgettext("lore", "button: delete this lore entry", "Delete")}
                </.pane_delete>
              </:actions>
            </.panel_header>

            <.pane_section :if={@entry_form}>
              <.entry_form
                form={@entry_form}
                keywords={@entry_keywords}
                secondary_keywords={@entry_secondary_keywords}
                entry_books={@entry_books}
                entry_pools={@entry_pools}
                entry_pool_settings={@entry_pool_settings}
                entry_filter_characters={@entry_filter_characters}
                character_options={@character_options}
                books={@books}
                entry_filter_tags={@entry_filter_tags}
                tag_field={@tag_fields.entry}
                tag_vocabulary={@tag_vocabulary}
                viewer_id={@current_scope.user.id}
                tag_graph={@tag_graph}
                owner={@entry_owner}
                pools={@pools}
                prompt_outlets={@prompt_outlets}
                completions={@template_completions}
                memory={@entry_memory}
                compacting={@entry_compaction != nil}
                diff={@entry_diff}
                token_model={@token_model}
                cancel={
                  if @editing_entry,
                    do: ~p"/lore/entries/#{@editing_entry.id}/edit",
                    else: ~p"/lore"
                }
              />
            </.pane_section>
          </div>

          <.pane_placeholder :if={@live_action == :index} id="lore-book-placeholder">
            {dgettext("lore", "Select a lore book or entry, or create a new one.")}
          </.pane_placeholder>

          <div
            :if={@live_action not in [:index, :entry_new, :entry_edit]}
            class="lore-book-editor-body"
          >
            <.panel_header sticky>
              {if @editing_book,
                do: @editing_book.name,
                else: dpgettext("lore", "heading: create a lore book", "New lore book")}
              <.badge
                :if={@editing_book && @editing_book.kind == :card}
                id="lore-book-card-badge"
                title={
                  dgettext(
                    "lore",
                    "Imported from a character card: its entries go first in their slot and skip the lore budget"
                  )
                }
              >
                {dpgettext("lore", "badge: lore book imported from a character card", "Card book")}
              </.badge>
              <:actions :if={@editing_book}>
                <.pane_export
                  id="export-lore-book"
                  kind={:lore_book}
                  item={@editing_book}
                  current_scope={@current_scope}
                />
                <.live_component
                  :if={Ownership.deletable?(@current_scope, @editing_book)}
                  module={MythweaverWeb.HandOff}
                  id="lore-book-handoff"
                  thing="lore-book"
                  current_scope={@current_scope}
                  item={@editing_book}
                  delete={&Lore.delete_book/3}
                  index={~p"/lore"}
                  delete_id="delete-lore-book"
                  confirm={delete_confirm(@editing_book.name)}
                />
              </:actions>
            </.panel_header>
            <.live_component
              :if={@editing_book}
              module={MythweaverWeb.Lineage}
              id="lore-book-lineage-line"
              thing="lore-book"
              current_scope={@current_scope}
              item={@editing_book}
            />

            <.pane_section>
              <.form
                for={@form}
                id="lore-book-form"
                class="lore-book-form"
                phx-hook="UnsavedChanges"
                data-saved={is_nil(@form.action)}
                phx-change="validate"
                phx-submit="save"
              >
                <.owner_select
                  :if={is_nil(@editing_book)}
                  id="lore-book-form-owner"
                  scope={@current_scope}
                  schema={LoreBook}
                  value={@new_owner}
                >
                  {dgettext("lore", "You can move it later from the book's editor.")}
                </.owner_select>
                <div
                  :if={@editing_book && Scope.can?(@current_scope, "site.content.manage")}
                  id="lore-book-owner"
                  class="lore-book-owner"
                >
                  <span id="lore-book-owner-label">
                    {if @editing_book.user_id,
                      do: dgettext("lore", "Personal book: only you see and use it."),
                      else: dgettext("lore", "Site book: every user can use it.")}
                  </span>
                  <.button
                    :if={@editing_book.user_id}
                    type="button"
                    size="sm"
                    id="lore-book-transfer"
                    phx-click="prepare_transfer"
                  >
                    {make_site_book()}
                  </.button>
                </div>
                <.field_row id="lore-book-form-settings-row">
                  <:field size="wide">
                    <.input
                      field={@form[:name]}
                      type="text"
                      label={dpgettext("lore", "field label: name of a lore book", "Name")}
                      id="lore-book-form-name"
                      required
                    >
                      <:hint>
                        {dgettext(
                          "lore",
                          "The book's name in lists and pickers. It is never sent to the model."
                        )}
                      </:hint>
                    </.input>
                  </:field>
                  <:field>
                    <.input
                      field={@form[:priority]}
                      type="select"
                      label={priority_label()}
                      options={Enum.map(1..5, &{Mythweaver.Format.number(&1), &1})}
                      id="lore-book-form-priority"
                    >
                      <:hint>
                        {dgettext(
                          "lore",
                          "Higher-priority books go first. Their entries claim the lore token budget before lower books' entries, except that the replying character's own books always go first. When one entry sits in several books, the copy in the highest-priority book is the one used."
                        )}
                      </:hint>
                    </.input>
                  </:field>
                  <:field>
                    <.input
                      field={@form[:order_adjustment]}
                      type="number"
                      label={
                        dpgettext(
                          "lore",
                          "field label: amount added to every entry's order in a lore book",
                          "Order adjustment"
                        )
                      }
                      id="lore-book-form-order_adjustment"
                      min="-10000"
                      max="10000"
                    >
                      <:hint>
                        {dgettext(
                          "lore",
                          "Added to the order of every entry in this book, so you can move the whole book ahead of or behind other books without editing each entry. Within a slot, higher order renders later; within a custom outlet, higher order renders first (as in SillyTavern)."
                        )}
                      </:hint>
                    </.input>
                  </:field>
                  <:field>
                    <.input
                      field={@form[:token_budget]}
                      type="number"
                      label={token_budget_label()}
                      placeholder={global_default()}
                      id="lore-book-form-token_budget"
                      min="1"
                    >
                      <:hint>
                        {rich(
                          dgettext(
                            "lore",
                            "The most tokens this book's entries may add to one prompt. Empty means no per-book cap; the global %{budget_percent_setting} and %{budget_cap_setting} settings still apply. Entries set to %{ignore_budget} are never cut. Ignore-budget entries don't count toward this budget; they still count toward the global one.",
                            budget_percent_setting:
                              em(
                                dpgettext(
                                  "lore",
                                  "field label: global lore budget setting",
                                  "Lore budget (% of context)"
                                )
                              ),
                            budget_cap_setting:
                              em(
                                dpgettext(
                                  "lore",
                                  "field label: global lore budget cap setting",
                                  "Lore budget cap"
                                )
                              ),
                            ignore_budget:
                              em(
                                dpgettext(
                                  "lore",
                                  "field label: lore entry is never dropped for the token budget",
                                  "Ignore budget"
                                )
                              )
                          )
                        )}
                      </:hint>
                    </.input>
                  </:field>
                  <:field>
                    <.input
                      field={@form[:scan_depth]}
                      type="number"
                      label={book_scan_depth_label()}
                      placeholder={global_default()}
                      id="lore-book-form-scan_depth"
                      min="1"
                    >
                      <:hint>
                        {rich(
                          dgettext(
                            "lore",
                            "How many recent messages this book's entries search for keywords. An entry's own scan depth overrides it; empty uses the global %{scan_depth_setting} setting.",
                            scan_depth_setting:
                              em(
                                dpgettext(
                                  "lore",
                                  "field label: global lore scan depth setting",
                                  "Scan depth"
                                )
                              )
                          )
                        )}
                      </:hint>
                    </.input>
                  </:field>
                </.field_row>
                <.editor
                  field={@form[:description]}
                  label={dpgettext("lore", "field label: description of a lore book", "Description")}
                  rows={3}
                  id="lore-book-form-description"
                  language="markdown"
                  spellcheck
                >
                  <:hint>
                    {dgettext(
                      "lore",
                      "Notes for you. Activation never reads it and it is never sent to the model."
                    )}
                  </:hint>
                </.editor>
                <.field_row id="lore-book-form-flags-row">
                  <:field size="fit">
                    <.input
                      field={@form[:global]}
                      type="checkbox"
                      label={dgettext("lore", "Global (active in every chat)")}
                      id="lore-book-form-global"
                    >
                      <:hint>
                        {dgettext(
                          "lore",
                          "Active in every chat, whatever its bindings. Off, the book applies only through the chats and characters it is bound to below."
                        )}
                      </:hint>
                    </.input>
                  </:field>
                  <:field size="fit">
                    <.input
                      field={@form[:recursive]}
                      type="checkbox"
                      label={
                        dpgettext(
                          "lore",
                          "field label: lore book entries can be activated by recursion",
                          "Recursive activation"
                        )
                      }
                      id="lore-book-form-recursive"
                    >
                      <:hint>
                        {dgettext(
                          "lore",
                          "Lets this book's entries be activated by the text of other activated entries, not just by chat messages. Off, they match only the chat itself."
                        )}
                      </:hint>
                    </.input>
                  </:field>
                </.field_row>
                <.field_row
                  :if={OwnerSelect.site_row?(@editing_book, @current_scope, LoreBook, @new_owner)}
                  id="lore-book-form-visibility-row"
                >
                  <:field>
                    <.input
                      field={@form[:site_visibility]}
                      type="select"
                      label={visibility_label()}
                      id="lore-book-form-site_visibility"
                      options={visibility_options()}
                    >
                      <:hint>
                        {dgettext(
                          "lore",
                          "What users who are not admins see of this book. Names only: the book and its entry names, never their text, in the prompt inspector or scripts. Nothing: users cannot see, pick or bind it. Admins always see everything."
                        )}
                      </:hint>
                    </.input>
                  </:field>
                </.field_row>
                <.field_row
                  :if={OwnerSelect.site_row?(@editing_book, @current_scope, LoreBook, @new_owner)}
                  id="lore-book-form-forced-row"
                >
                  <:field size="fit">
                    <.input
                      field={@form[:forced]}
                      type="checkbox"
                      label={dgettext("lore", "Forced (every reply, cannot be turned off)")}
                      id="lore-book-form-forced"
                    >
                      <:hint>
                        {dgettext(
                          "lore",
                          "Active in every chat whether or not Global is set, and sent with every reply even when a prompt has no slot for it (then as a system section at the top). User lore settings such as the token budget do not apply to it; its own token budget does."
                        )}
                      </:hint>
                    </.input>
                  </:field>
                </.field_row>
                <.tag_fields
                  :if={@tag_fields[:book]}
                  id="lore-book-form-tags"
                  field={@tag_fields.book}
                  vocabulary={@tag_vocabulary}
                />
                <.field_row id="lore-book-form-tag-filter-row">
                  <:field size="fit">
                    <.input
                      field={@form[:tag_filter_mode]}
                      type="select"
                      label={
                        dpgettext("lore", "field label: lore book tag filter mode", "Tag filter")
                      }
                      options={[
                        {dpgettext("lore", "option: lore book tag filter mode", "Off"), :off},
                        {dpgettext("lore", "option: lore book tag filter mode", "Include"), :include},
                        {dpgettext("lore", "option: lore book tag filter mode", "Exclude"), :exclude}
                      ]}
                      id="lore-book-form-tag_filter_mode"
                    >
                      <:hint>
                        {dgettext(
                          "lore",
                          "Include: the book's entries activate only in chats where a character with one of these tags takes part. Exclude: never in those chats. Off ignores the list."
                        )}
                      </:hint>
                    </.input>
                  </:field>
                  <:field>
                    <.tag_input
                      id="lore-book-form-filter_tags"
                      name="lore_book[filter_tags][]"
                      label={
                        dpgettext(
                          "lore",
                          "field label: character tags a lore book's filter checks",
                          "Filter tags"
                        )
                      }
                      values={@book_filter_tags}
                      vocabulary={@tag_vocabulary}
                    />
                  </:field>
                </.field_row>
                <.form_actions>
                  <.button patch={
                    if @editing_book, do: ~p"/lore/#{@editing_book.id}/edit", else: ~p"/lore"
                  }>
                    {dpgettext("lore", "button: discard edits to the open form", "Cancel")}
                  </.button>
                  <.button type="submit" variant="primary">{dpgettext(
                    "lore",
                    "button: save the open form",
                    "Save"
                  )}</.button>
                </.form_actions>
              </.form>
            </.pane_section>

            <BookSections.book_bindings
              :if={@editing_book}
              editing_book={@editing_book}
              chat_options={@chat_options}
              character_options={@character_options}
              current_scope={@current_scope}
              tag_graph={@tag_graph}
              tag_vocabulary={@tag_vocabulary}
            />

            <BookSections.book_rules
              :if={@editing_book}
              editing_book={@editing_book}
              rules_form={@rules_form}
              rule_chat_options={@rule_chat_options}
              rule_character_options={@rule_character_options}
              tag_vocabulary={@tag_vocabulary}
            />

            <BookSections.book_entries
              :if={@editing_book}
              editing_book={@editing_book}
              entries={@streams.entries}
              entries_empty?={@entries_empty?}
              hidden_entry_count={@hidden_entry_count}
              hide_disabled_memories={@hide_disabled_memories}
              selected_entry_ids={@selected_entry_ids}
              entry_ids={@entry_ids}
              entry_sort={@entry_sort}
              memory_kinds={@memory_kinds}
              editing_entry={@editing_entry}
              open_row={@open_row}
              entry_form={@entry_form}
              entry_keywords={@entry_keywords}
              entry_secondary_keywords={@entry_secondary_keywords}
              entry_books={@entry_books}
              entry_pools={@entry_pools}
              entry_pool_settings={@entry_pool_settings}
              entry_filter_characters={@entry_filter_characters}
              entry_filter_tags={@entry_filter_tags}
              entry_owner={@entry_owner}
              entry_memory={@entry_memory}
              entry_compaction={@entry_compaction}
              entry_diff={@entry_diff}
              character_options={@character_options}
              books={@books}
              pools={@pools}
              prompt_outlets={@prompt_outlets}
              template_completions={@template_completions}
              token_model={@token_model}
              tag_fields={@tag_fields}
              tag_vocabulary={@tag_vocabulary}
              tag_graph={@tag_graph}
              current_scope={@current_scope}
            />
            <.live_component
              :if={@editing_book}
              module={MythweaverWeb.SharePanel}
              id="lore-book-share"
              current_scope={@current_scope}
              item={@editing_book}
            />
          </div>
        </:editor>
      </.pane_layout>
      <EntryForm.new_pool_modal form={@entry_pool_form} />
      <.modal
        :if={@transfer}
        id="lore-book-transfer-modal"
        title={
          dpgettext(
            "lore",
            "heading: confirm moving a personal lore book to the site",
            "Make this a site book?"
          )
        }
        on_cancel="cancel_transfer"
      >
        <p>
          {dgettext(
            "lore",
            "Every user will be able to use %{book_name} and its entries; only admins will edit them.",
            book_name: @editing_book.name
          )}
        </p>
        <p :if={@transfer.warnings != []}>{dgettext("lore", "This also changes other lore:")}</p>
        <ul id="lore-book-transfer-warnings">
          <li :for={warning <- @transfer.warnings}>{warning}</li>
        </ul>
        <p>
          {dgettext(
            "lore",
            "A site book cannot be made personal again, and removed links stay removed."
          )}
        </p>
        <div class="lore-book-transfer-actions">
          <.button
            type="button"
            id="lore-book-transfer-cancel"
            phx-click={Phoenix.LiveView.JS.dispatch("modal:close", to: "#lore-book-transfer-modal")}
          >
            {dpgettext("lore", "button: close the dialog without changing anything", "Cancel")}
          </.button>
          <.button
            type="button"
            variant="primary"
            danger
            id="lore-book-transfer-confirm"
            phx-click="transfer_book"
          >
            {make_site_book()}
          </.button>
        </div>
      </.modal>
      <MythweaverWeb.Sudo.modal :if={@sudo_prompt} prompt={@sudo_prompt} />
    </Layouts.app>
    """
  end
end
