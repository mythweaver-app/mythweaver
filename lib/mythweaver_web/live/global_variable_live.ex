defmodule MythweaverWeb.GlobalVariableLive do
  @moduledoc """
  Global variable manager: the variable list on the left, the selected variable's form on the right.
  Globals are what every chat's templates read as `globals` (and as `vars` unless a chat variable of
  the same key shadows them) and write with `{% setglobalvar %}`. `:index` selects nothing: the
  editor pane shows a placeholder until a variable is picked.

  A value box holds JSON; text that is not JSON is stored as a plain string
  (`MythweaverWeb.JSONText.decode_value/1`).
  """
  use MythweaverWeb, :live_view

  import MythweaverWeb.BulkComponents
  import MythweaverWeb.Pane

  alias Mythweaver.Variables
  alias Mythweaver.Variables.Variable
  alias MythweaverWeb.Bulk
  alias MythweaverWeb.Bulk.Field
  alias MythweaverWeb.Bulk.Spec
  alias MythweaverWeb.CoreComponents.OwnerSelect
  alias MythweaverWeb.JSONText
  alias MythweaverWeb.LiveSync

  on_mount {MythweaverWeb.ContentAccess, :variables}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: dpgettext("variables", "page title: global variable manager", "Variables"),
       form: nil,
       value_text: "",
       editing_variable: nil,
       new_owner: "personal",
       selected_id: nil
     )
     |> stream_configure(:variables, dom_id: &"variables-#{&1.id}")
     |> assign_filter()
     |> stream_variables()
     |> Bulk.attach([bulk_spec()])
     |> LiveSync.attach_editor([:variables], &sync/2)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(form: nil, value_text: "", editing_variable: nil, selected_id: nil)
    |> stream_variables()
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(
      form: to_form(Variables.change_variable(%Variable{})),
      value_text: "",
      editing_variable: nil,
      new_owner: "personal",
      selected_id: nil
    )
    |> stream_variables()
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Variables.get_global_variable(socket.assigns.current_scope, id) do
      nil ->
        socket
        |> put_flash(:error, not_found_message())
        |> push_patch(to: ~p"/variables")

      variable ->
        socket
        |> assign(
          form: to_form(Variables.change_variable(variable)),
          value_text: JSONText.encode_value(variable.value),
          editing_variable: variable,
          selected_id: variable.id
        )
        |> stream_variables()
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, socket |> assign_filter(params) |> stream_variables()}
  end

  def handle_event("validate", %{"variable" => params} = all, socket) do
    changeset =
      socket
      |> target_variable()
      |> Variables.change_variable(attrs(params))
      |> Map.put(:action, :validate)

    {:noreply,
     assign(socket, form: to_form(changeset), value_text: params["value"] || "", new_owner: OwnerSelect.choice(all))}
  end

  def handle_event("save", %{"variable" => params} = all, socket) do
    result =
      case socket.assigns.editing_variable do
        nil ->
          Variables.create_variable(
            socket.assigns.current_scope,
            nil,
            attrs(params),
            OwnerSelect.create_opts(OwnerSelect.choice(all))
          )

        variable ->
          Variables.update_variable(socket.assigns.current_scope, variable, attrs(params))
      end

    case result do
      {:ok, variable} ->
        {:noreply,
         socket
         |> put_flash(:info, saved_message(variable.key))
         |> push_patch(to: ~p"/variables/#{variable.id}/edit")}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset), value_text: params["value"] || "")
         |> put_flash(:error, save_failed_message())}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Variables.get_global_variable(socket.assigns.current_scope, id) do
      nil ->
        {:noreply, socket}

      variable ->
        {:ok, _} = Variables.delete_variable(socket.assigns.current_scope, variable)

        {:noreply,
         socket
         |> put_flash(:info, deleted_message(variable.key))
         |> push_patch(to: ~p"/variables")}
    end
  end

  defp not_found_message do
    gettext_comment("Error flash when opening a global variable that no longer exists.")
    dpgettext("variables", "status: flash when the global variable in the address does not exist", "Variable not found")
  end

  defp saved_message(key) do
    gettext_comment("Flash after saving a global variable; the placeholder is the variable's key.")
    dpgettext("variables", "status: flash after saving a global variable", "%{variable_key} saved", variable_key: key)
  end

  defp save_failed_message do
    gettext_comment("Error flash when a global variable form has invalid fields.")
    dgettext("variables", "Could not save — see the highlighted fields")
  end

  defp deleted_message(key) do
    gettext_comment("Flash after deleting a global variable; the placeholder is the variable's key.")

    dpgettext("variables", "status: flash after deleting a global variable", "%{variable_key} deleted",
      variable_key: key
    )
  end

  defp delete_confirm(key) do
    gettext_comment("Confirm dialog before deleting a chat or global variable; the placeholder is its key.")

    dpgettext("variables", "status: confirm dialog before deleting a variable", "Delete %{variable_key}?",
      variable_key: key
    )
  end

  # A generation's `{% setglobalvar %}`, another tab or another user changed the globals.
  defp sync(socket, _kinds) do
    scope = socket.assigns.current_scope

    socket
    |> stream_variables()
    |> LiveSync.sync_open(:editing_variable,
      fetch: &Variables.get_global_variable(scope, &1),
      clean?: LiveSync.clean?(socket.assigns.form),
      reload: fn socket, fresh ->
        assign(socket,
          form: to_form(Variables.change_variable(fresh)),
          value_text: JSONText.encode_value(fresh.value),
          editing_variable: fresh
        )
      end,
      gone: ~p"/variables",
      gone_message:
        (
          gettext_comment("Flash shown when the variable open in the editor was deleted or moved by someone else.")
          dgettext("variables", "The variable was deleted or moved elsewhere.")
        )
    )
  end

  defp target_variable(socket), do: socket.assigns.editing_variable || %Variable{}

  defp attrs(params), do: Map.update(params, "value", nil, &JSONText.decode_value/1)

  defp bulk_spec do
    %Spec{
      name: :variables,
      count_label:
        &dpngettext(
          "variables",
          "count phrase: global variables affected by a bulk action",
          "%{variable_count} variable",
          "%{variable_count} variables",
          &1,
          variable_count: Mythweaver.Format.number(&1)
        ),
      ids: & &1.assigns.variables_ids,
      get: &Variables.get_global_variable/2,
      update: &Variables.update_variable/3,
      delete: &Variables.delete_variable/2,
      title: & &1.key,
      refresh: &stream_variables/1,
      open_id: & &1.assigns.selected_id,
      index_path: ~p"/variables",
      edit_path: &~p"/variables/#{&1}/edit",
      fields: [
        %Field{
          key: :value,
          label: dpgettext("variables", "field label: value of a global variable", "Value (JSON, or plain text)"),
          type: :text,
          cast: &JSONText.decode_value/1
        }
      ]
    }
  end

  defp stream_variables(socket) do
    stream_search(socket, :variables, Variables.list_global_variables(socket.assigns.current_scope), fn variable ->
      [variable.key, JSONText.encode_value(variable.value)]
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      /* The editor slot's root. `pane_layout`'s `<section>` carries no marker from this block, so
         without it `<.form>` (which carries none either) would sit outside this scope. */
      div.variable-editor-body:scope {
        display: contents;
      }

      .variable-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .variable-form label {
        display: block;
      }
    </style>

    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.pane_layout>
        <:list
          id="variables-nav"
          label={dpgettext("variables", "aria label: list of global variables", "Variables")}
        >
          <.pane_header title={
            dpgettext("variables", "heading: global variable manager", "Variables")
          } />
          <.pane_actions>
            <.button variant="primary" patch={~p"/variables/new"} id="new-variable">
              <.lucide name="plus" /> {dpgettext(
                "variables",
                "button: create a global variable",
                "New variable"
              )}
            </.button>
            <.bulk_toggle bulk={@bulk} id="variables-bulk-toggle" />
          </.pane_actions>
          <.bulk_bar bulk={@bulk} id="variables-bulk" />
          <.pane_search
            id="variable-filter"
            form={@filter_form}
            placeholder={
              dpgettext("variables", "placeholder: search global variables", "Key or value")
            }
          />
          <.pane_items
            :let={variable}
            bulk={@bulk}
            bulk_list="variables"
            id="variables"
            rows={@streams.variables}
            empty?={@variables_empty?}
            empty={
              if @query == "",
                do:
                  dpgettext(
                    "variables",
                    "empty state: no global variables exist",
                    "No global variables yet"
                  ),
                else: dgettext("variables", "No variables match this search")
            }
            selected_id={@selected_id}
            patch={fn variable -> ~p"/variables/#{variable.id}/edit" end}
          >
            <span class="pane-item-name">{variable.key}</span>
          </.pane_items>
        </:list>
        <:editor id="variable-editor">
          <.pane_placeholder :if={@live_action == :index} id="variable-placeholder">
            {dgettext("variables", "Select a variable, or create a new one.")}
          </.pane_placeholder>
          <div :if={@live_action != :index} class="variable-editor-body">
            <.panel_header sticky>
              {if @editing_variable,
                do: @editing_variable.key,
                else:
                  dpgettext(
                    "variables",
                    "heading: form for a global variable not yet saved",
                    "New variable"
                  )}
              <:actions :if={@editing_variable}>
                <.pane_delete
                  id="delete-variable"
                  phx-click="delete"
                  phx-value-id={@editing_variable.id}
                  confirm={delete_confirm(@editing_variable.key)}
                >
                  {dpgettext("variables", "button: delete the open global variable", "Delete")}
                </.pane_delete>
              </:actions>
            </.panel_header>

            <.pane_section>
              <.changed_elsewhere
                :if={@changed_elsewhere?}
                id="variable-changed-elsewhere"
                patch={@live_sync_path}
              />
              <.form
                for={@form}
                id="variable-form"
                class="variable-form"
                phx-hook="UnsavedChanges"
                data-saved={is_nil(@form.action)}
                phx-change="validate"
                phx-submit="save"
              >
                <.owner_select
                  :if={is_nil(@editing_variable)}
                  id="variable-form-owner"
                  scope={@current_scope}
                  schema={Variable}
                  value={@new_owner}
                />
                <.input
                  field={@form[:key]}
                  type="text"
                  label={dpgettext("variables", "field label: key of a global variable", "Key")}
                  id="variable-form-key"
                  required
                />
                <.editor
                  name="variable[value]"
                  label={
                    dpgettext(
                      "variables",
                      "field label: value of a global variable",
                      "Value (JSON, or plain text)"
                    )
                  }
                  rows={6}
                  id="variable-form-value"
                  language="json"
                  line_numbers
                  value={@value_text}
                  errors={translate_errors(@form.errors, :value)}
                />
                <.form_actions>
                  <.button patch={
                    if @editing_variable,
                      do: ~p"/variables/#{@editing_variable.id}/edit",
                      else: ~p"/variables"
                  }>
                    {dpgettext("variables", "button: discard edits to a global variable", "Cancel")}
                  </.button>
                  <.button type="submit" variant="primary">
                    {dpgettext("variables", "button: save the open form", "Save")}
                  </.button>
                </.form_actions>
              </.form>
            </.pane_section>
          </div>
        </:editor>
      </.pane_layout>
    </Layouts.app>
    """
  end
end
