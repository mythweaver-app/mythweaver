defmodule MythweaverWeb.SidePromptSetLive do
  @moduledoc """
  Side prompt set manager: the set list on the left, the selected set's form on the right. A set
  (`Mythweaver.Memory.SidePromptSet`) is an ordered list of rows, each a side prompt with a label
  (naming its entry) and values for the runtime macros the side prompt declares. A chat on a set
  runs its rows after memories and on intervals instead of the individually enabled side prompts.
  `:index` selects nothing: the editor pane shows a placeholder until a set is picked.

  Rows are ordered as the form lists them (`sort_param`); "Add row" and the remove boxes are the
  standard `sort_param`/`drop_param` inputs, and the move buttons swap two rows' values.

  Open to anyone `MythweaverWeb.ContentAccess` admits: the list holds sets the scope may edit
  (`Mythweaver.Ownership`), and the side prompt picker those it may use.
  """
  use MythweaverWeb, :live_view

  import MythweaverWeb.BulkComponents
  import MythweaverWeb.Pane

  alias Mythweaver.Memory
  alias Mythweaver.Memory.SidePromptSet
  alias Mythweaver.Ownership
  alias MythweaverWeb.Bulk
  alias MythweaverWeb.Bulk.Spec
  alias MythweaverWeb.CoreComponents.OwnerSelect
  alias MythweaverWeb.LiveSync

  on_mount {MythweaverWeb.ContentAccess, :memory}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: dpgettext("memory", "page title: list of side prompt sets", "Side prompt sets"),
       form: nil,
       editing_set: nil,
       new_owner: "personal",
       selected_id: nil
     )
     |> assign_options()
     |> stream_configure(:side_prompt_sets, dom_id: &"side-prompt-sets-#{&1.id}")
     |> assign_filter()
     |> stream_sets()
     |> Bulk.attach([bulk_spec()])
     |> LiveSync.attach_editor([:memory], &sync/2)}
  end

  defp assign_options(socket) do
    side_prompts = Memory.list_usable_side_prompts(socket.assigns.current_scope)

    assign(socket,
      side_prompt_options: Enum.map(side_prompts, &{&1.name, &1.id}),
      macros_by_prompt: Map.new(side_prompts, &{&1.id, &1.macros})
    )
  end

  defp sync(socket, _kinds) do
    scope = socket.assigns.current_scope

    socket
    |> assign_options()
    |> stream_sets()
    |> LiveSync.sync_open(:editing_set,
      fetch: &Memory.get_editable_side_prompt_set(scope, &1),
      clean?: LiveSync.clean?(socket.assigns.form),
      reload: &assign(&1, form: to_form(Memory.change_side_prompt_set(&2)), editing_set: &2),
      gone: ~p"/memory/side-prompt-sets",
      gone_message:
        (
          gettext_comment(
            "Flash shown when the side prompt set open in the editor was deleted or moved by someone else."
          )

          dgettext("memory", "The side prompt set was deleted or moved elsewhere.")
        )
    )
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(form: nil, editing_set: nil, selected_id: nil)
    |> stream_sets()
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(
      form: to_form(Memory.change_side_prompt_set(%SidePromptSet{})),
      editing_set: nil,
      new_owner: "personal",
      selected_id: nil
    )
    |> stream_sets()
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    edit(socket, Memory.get_editable_side_prompt_set(socket.assigns.current_scope, id))
  end

  defp edit(socket, nil) do
    socket
    |> put_flash(:error, not_found_flash())
    |> push_patch(to: ~p"/memory/side-prompt-sets")
  end

  defp edit(socket, set) do
    socket
    |> assign(form: to_form(Memory.change_side_prompt_set(set)), editing_set: set, selected_id: set.id)
    |> stream_sets()
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, socket |> assign_filter(params) |> stream_sets()}
  end

  def handle_event("validate", %{"side_prompt_set" => params} = all, socket) do
    {:noreply, socket |> assign(new_owner: OwnerSelect.choice(all)) |> validate(params)}
  end

  # Swaps row `index` with its neighbour in `dir`, keeping every row's current values.
  def handle_event("move_row", %{"index" => index, "dir" => dir}, socket) do
    params = form_params(socket.assigns.form.source)
    count = map_size(params["rows"])

    with {i, ""} <- Integer.parse(index),
         j = if(dir == "up", do: i - 1, else: i + 1),
         true <- i in 0..(count - 1)//1 and j in 0..(count - 1)//1 do
      rows = params["rows"]
      rows = %{rows | "#{i}" => rows["#{j}"], "#{j}" => rows["#{i}"]}
      {:noreply, validate(socket, %{params | "rows" => rows})}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("save", %{"side_prompt_set" => params} = all, socket) do
    scope = socket.assigns.current_scope

    result =
      case socket.assigns.editing_set do
        nil -> Memory.create_side_prompt_set(scope, params, OwnerSelect.create_opts(OwnerSelect.choice(all)))
        set -> Memory.update_side_prompt_set(scope, set, params)
      end

    case result do
      {:ok, set} ->
        {:noreply,
         socket
         |> put_flash(:info, saved_flash(set.name))
         |> push_patch(to: ~p"/memory/side-prompt-sets/#{set.id}/edit")}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(:error, save_failed_flash())}
    end
  end

  def handle_event("delete", _params, %{assigns: %{editing_set: %SidePromptSet{} = set}} = socket) do
    result = Memory.delete_side_prompt_set(socket.assigns.current_scope, set)
    {:noreply, MythweaverWeb.HandOff.after_delete(socket, result, set.name, ~p"/memory/side-prompt-sets")}
  end

  defp validate(socket, params) do
    changeset =
      (socket.assigns.editing_set || %SidePromptSet{})
      |> Memory.change_side_prompt_set(params)
      |> Map.put(:action, :validate)

    assign(socket, form: to_form(changeset))
  end

  # The form's current values as params, rows in order: what a submit of the form would post.
  defp form_params(changeset) do
    rows =
      changeset
      |> Ecto.Changeset.get_field(:rows)
      |> Enum.with_index()
      |> Map.new(fn {row, i} ->
        params =
          Map.reject(
            %{
              "id" => row.id,
              "side_prompt_id" => row.side_prompt_id,
              "label" => row.label,
              "macro_values" => row.macro_values
            },
            fn {_key, value} -> is_nil(value) end
          )

        {"#{i}", params}
      end)

    %{"name" => Ecto.Changeset.get_field(changeset, :name), "rows" => rows}
  end

  defp stream_sets(socket) do
    stream_search(socket, :side_prompt_sets, Memory.list_side_prompt_sets(socket.assigns.current_scope), &[&1.name])
  end

  defp bulk_spec do
    %Spec{
      name: :side_prompt_sets,
      count_label:
        &dpngettext(
          "memory",
          "count phrase: side prompt sets affected by a bulk action",
          "%{set_count} set",
          "%{set_count} sets",
          &1,
          set_count: Mythweaver.Format.number(&1)
        ),
      ids: & &1.assigns.side_prompt_sets_ids,
      get: &Memory.get_editable_side_prompt_set/2,
      delete: &Memory.delete_side_prompt_set/2,
      title: & &1.name,
      refresh: &stream_sets/1,
      open_id: & &1.assigns.selected_id,
      index_path: ~p"/memory/side-prompt-sets",
      edit_path: &~p"/memory/side-prompt-sets/#{&1}/edit"
    }
  end

  defp row_macros(macros_by_prompt, row), do: Map.get(macros_by_prompt, row[:side_prompt_id].value, [])

  defp macro_value(row, name), do: Map.get(row[:macro_values].value || %{}, name, "")

  defp not_found_flash do
    gettext_comment("Flash when the side prompt set being opened no longer exists or is not editable.")
    dpgettext("memory", "status: side prompt set was not found", "Side prompt set not found")
  end

  defp saved_flash(name) do
    gettext_comment("Flash after a side prompt set was saved.")
    dpgettext("memory", "status: a side prompt set was saved", "%{set_name} saved", set_name: name)
  end

  defp save_failed_flash do
    gettext_comment("Flash when saving an editor form fails validation; the invalid fields are highlighted.")
    dgettext("memory", "Could not save — see the highlighted fields")
  end

  defp delete_confirm(name) do
    gettext_comment("Confirm dialog before deleting a side prompt set.")

    dpgettext(
      "memory",
      "heading: confirm dialog before deleting a side prompt set",
      "Delete %{set_name}?",
      set_name: name
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      div.side-prompt-set-editor-body:scope {
        display: contents;
      }

      .side-prompt-set-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .side-prompt-set-form label {
        display: block;
      }

      .side-prompt-set-form h3 {
        margin: var(--size-2) 0 0;
        font-size: 0.95rem;
      }

      .side-prompt-set-row {
        display: flex;
        flex-wrap: wrap;
        gap: var(--size-2);
        align-items: flex-end;
        padding: var(--size-2);
        border: 1px solid var(--border);
        border-radius: var(--radius-2);
      }

      .side-prompt-set-row-tools {
        display: flex;
        gap: var(--size-1);
        align-items: center;
        margin-inline-start: auto;
      }
    </style>

    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.pane_layout>
        <:list
          id="side-prompt-sets-nav"
          label={dpgettext("memory", "aria label: list of side prompt sets", "Side prompt sets")}
        >
          <.pane_header title={
            dpgettext("memory", "heading: side prompt sets page", "Side prompt sets")
          }>
            <:switch navigate={~p"/memory/side-prompts"} id="side-prompts-link">
              {dpgettext("memory", "link: memory section side prompts page", "Side prompts")}
            </:switch>
            <:switch navigate={~p"/settings/memory"} id="memory-settings-link">
              {dpgettext("memory", "link: memory settings page", "Settings")}
            </:switch>
          </.pane_header>
          <.pane_actions>
            <.button
              variant="primary"
              patch={~p"/memory/side-prompt-sets/new"}
              id="new-side-prompt-set"
            >
              <.lucide name="plus" />
              {dpgettext("memory", "button: create a side prompt set", "New set")}
            </.button>
            <.bulk_toggle bulk={@bulk} id="side-prompt-sets-bulk-toggle" />
          </.pane_actions>
          <.bulk_bar bulk={@bulk} id="side-prompt-sets-bulk" />
          <.pane_search
            id="side-prompt-set-filter"
            form={@filter_form}
            placeholder={dpgettext("memory", "placeholder: search side prompt sets by name", "Name")}
          />
          <.pane_items
            :let={set}
            bulk={@bulk}
            bulk_list="side_prompt_sets"
            id="side-prompt-sets"
            rows={@streams.side_prompt_sets}
            empty?={@side_prompt_sets_empty?}
            empty={
              if @query == "",
                do:
                  dpgettext(
                    "memory",
                    "empty state: user has no side prompt sets",
                    "No side prompt sets yet"
                  ),
                else:
                  dpgettext(
                    "memory",
                    "empty state: no side prompt sets match the search",
                    "No sets match this search"
                  )
            }
            selected_id={@selected_id}
            patch={fn set -> ~p"/memory/side-prompt-sets/#{set.id}/edit" end}
          >
            <span class="pane-item-name">{set.name}</span>
          </.pane_items>
        </:list>
        <:editor id="side-prompt-set-editor">
          <.pane_placeholder :if={@live_action == :index} id="side-prompt-set-placeholder">
            {dgettext("memory", "Select a side prompt set, or create a new one.")}
          </.pane_placeholder>
          <div :if={@live_action != :index} class="side-prompt-set-editor-body">
            <.panel_header sticky>
              {if @editing_set,
                do: @editing_set.name,
                else:
                  dpgettext("memory", "heading: side prompt set being created", "New side prompt set")}
              <:actions :if={@editing_set}>
                <.pane_export
                  id="export-side-prompt-set"
                  kind={:side_prompt_set}
                  item={@editing_set}
                  current_scope={@current_scope}
                />
                <.live_component
                  :if={Ownership.deletable?(@current_scope, @editing_set)}
                  module={MythweaverWeb.HandOff}
                  id="side-prompt-set-handoff"
                  thing="side-prompt-set"
                  current_scope={@current_scope}
                  item={@editing_set}
                  delete={&Memory.delete_side_prompt_set/3}
                  index={~p"/memory/side-prompt-sets"}
                  delete_id="delete-side-prompt-set"
                  confirm={delete_confirm(@editing_set.name)}
                />
              </:actions>
            </.panel_header>
            <.live_component
              :if={@editing_set}
              module={MythweaverWeb.Lineage}
              id="side-prompt-set-lineage-line"
              thing="side-prompt-set"
              current_scope={@current_scope}
              item={@editing_set}
            />

            <.pane_section>
              <.changed_elsewhere
                :if={@changed_elsewhere?}
                id="side-prompt-set-changed-elsewhere"
                patch={@live_sync_path}
              />
              <.form
                for={@form}
                id="side-prompt-set-form"
                class="side-prompt-set-form"
                phx-hook="UnsavedChanges"
                data-saved={is_nil(@form.action)}
                phx-change="validate"
                phx-submit="save"
              >
                <.owner_select
                  :if={is_nil(@editing_set)}
                  id="side-prompt-set-form-owner"
                  scope={@current_scope}
                  schema={SidePromptSet}
                  value={@new_owner}
                />
                <.input
                  field={@form[:name]}
                  type="text"
                  label={dpgettext("memory", "field label: name of a side prompt set", "Name")}
                  id="side-prompt-set-form-name"
                  required
                />

                <h3>{dpgettext("memory", "heading: rows of a side prompt set", "Rows")}</h3>
                <.inputs_for :let={row} field={@form[:rows]}>
                  <div class="side-prompt-set-row" id={"side-prompt-set-row-#{row.index}"}>
                    <input type="hidden" name="side_prompt_set[rows_sort][]" value={row.index} />
                    <.input
                      field={row[:side_prompt_id]}
                      type="select"
                      label={
                        dpgettext("memory", "field label: side prompt a set row runs", "Side prompt")
                      }
                      prompt={
                        dpgettext("memory", "option: no side prompt picked yet", "Pick a side prompt")
                      }
                      options={@side_prompt_options}
                      id={"side-prompt-set-row-#{row.index}-side-prompt"}
                    />
                    <.input
                      field={row[:label]}
                      type="text"
                      label={
                        dpgettext(
                          "memory",
                          "field label: label of a side prompt set row, used in its entry's name",
                          "Label (names the entry)"
                        )
                      }
                      id={"side-prompt-set-row-#{row.index}-label"}
                    />
                    <.input
                      :for={name <- row_macros(@macros_by_prompt, row)}
                      type="text"
                      name={"side_prompt_set[rows][#{row.index}][macro_values][#{name}]"}
                      id={"side-prompt-set-row-#{row.index}-macro-#{name}"}
                      value={macro_value(row, name)}
                      label={"{{ #{name} }}"}
                    />
                    <div class="side-prompt-set-row-tools">
                      <.button
                        size="sm"
                        icon
                        id={"side-prompt-set-row-#{row.index}-up"}
                        phx-click="move_row"
                        phx-value-index={row.index}
                        phx-value-dir="up"
                        aria-label={
                          dpgettext("memory", "aria label: move a side prompt set row up", "Move up")
                        }
                      >
                        <.lucide name="arrow-up" />
                      </.button>
                      <.button
                        size="sm"
                        icon
                        id={"side-prompt-set-row-#{row.index}-down"}
                        phx-click="move_row"
                        phx-value-index={row.index}
                        phx-value-dir="down"
                        aria-label={
                          dpgettext(
                            "memory",
                            "aria label: move a side prompt set row down",
                            "Move down"
                          )
                        }
                      >
                        <.lucide name="arrow-down" />
                      </.button>
                      <label>
                        <input
                          type="checkbox"
                          name="side_prompt_set[rows_drop][]"
                          value={row.index}
                          id={"side-prompt-set-row-#{row.index}-remove"}
                        /> {dpgettext(
                          "memory",
                          "toggle: remove a side prompt set row on save",
                          "Remove"
                        )}
                      </label>
                    </div>
                  </div>
                </.inputs_for>
                <input type="hidden" name="side_prompt_set[rows_drop][]" />

                <.form_actions>
                  <:start>
                    <.button
                      size="sm"
                      id="side-prompt-set-add-row"
                      name="side_prompt_set[rows_sort][]"
                      value="new"
                      phx-click={JS.dispatch("change")}
                    >
                      <.lucide name="plus" />
                      {dpgettext("memory", "button: add a row to a side prompt set", "Add row")}
                    </.button>
                  </:start>
                  <.button patch={
                    if @editing_set,
                      do: ~p"/memory/side-prompt-sets/#{@editing_set.id}/edit",
                      else: ~p"/memory/side-prompt-sets"
                  }>
                    {dpgettext("memory", "button: cancel editing a side prompt set", "Cancel")}
                  </.button>
                  <.button type="submit" variant="primary">
                    {dpgettext("memory", "button: save a side prompt set", "Save")}
                  </.button>
                </.form_actions>
              </.form>
            </.pane_section>
            <.live_component
              :if={@editing_set}
              module={MythweaverWeb.SharePanel}
              id="side-prompt-set-share"
              current_scope={@current_scope}
              item={@editing_set}
            />
          </div>
        </:editor>
      </.pane_layout>
    </Layouts.app>
    """
  end
end
