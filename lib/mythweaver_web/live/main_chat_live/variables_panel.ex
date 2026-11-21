defmodule MythweaverWeb.MainChatLive.VariablesPanel do
  @moduledoc """
  The chat variables modal's events for `MainChatLive`, which routes every name in `events/0` here.
  The panel lives in the `:chat_variables` assign (nil while closed): the chat's variables, the
  form, its JSON value text, and the id being edited.
  """
  import MythweaverWeb.Flash, only: [flash_unauthorized: 1]
  import Phoenix.Component, only: [assign: 2, to_form: 1]

  alias Mythweaver.Variables
  alias Mythweaver.Variables.Variable
  alias MythweaverWeb.JSONText

  @events ~w(open_chat_variables close_chat_variables new_chat_variable edit_chat_variable
             validate_chat_variable save_chat_variable delete_chat_variable)

  def events, do: @events

  def handle_event("open_chat_variables", _params, %{assigns: %{selected_chat: %{} = chat}} = socket),
    do: {:noreply, assign(socket, chat_variables: variables_panel(socket.assigns.current_scope, chat))}

  def handle_event("close_chat_variables", _params, socket), do: {:noreply, assign(socket, chat_variables: nil)}

  def handle_event("new_chat_variable", _params, %{assigns: %{chat_variables: %{} = panel}} = socket),
    do: {:noreply, assign(socket, chat_variables: blank_variable_form(panel))}

  # Ids are looked up in the panel's own list, which is this chat's variables, so a crafted id cannot
  # reach another chat's or a global variable.
  def handle_event("edit_chat_variable", %{"id" => id}, %{assigns: %{chat_variables: %{} = panel}} = socket) do
    case Enum.find(panel.variables, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      variable ->
        panel = %{
          panel
          | form: to_form(Variables.change_variable(variable)),
            value_text: JSONText.encode_value(variable.value),
            editing_id: id
        }

        {:noreply, assign(socket, chat_variables: panel)}
    end
  end

  def handle_event(
        "validate_chat_variable",
        %{"variable" => params},
        %{assigns: %{chat_variables: %{} = panel}} = socket
      ) do
    changeset =
      panel
      |> editing_variable()
      |> Variables.change_variable(variable_attrs(params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, chat_variables: %{panel | form: to_form(changeset), value_text: params["value"] || ""})}
  end

  def handle_event(
        "save_chat_variable",
        %{"variable" => params},
        %{assigns: %{chat_variables: %{} = panel, selected_chat: %{} = chat}} = socket
      ) do
    scope = socket.assigns.current_scope
    attrs = variable_attrs(params)

    result =
      case editing_variable(panel) do
        %Variable{id: nil} -> Variables.create_variable(scope, chat.id, attrs)
        variable -> Variables.update_variable(scope, variable, attrs)
      end

    case result do
      {:ok, _variable} ->
        {:noreply, assign(socket, chat_variables: variables_panel(scope, chat))}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}

      {:error, changeset} ->
        panel = %{panel | form: to_form(changeset), value_text: params["value"] || ""}
        {:noreply, assign(socket, chat_variables: panel)}
    end
  end

  def handle_event(
        "delete_chat_variable",
        %{"id" => id},
        %{assigns: %{chat_variables: %{} = panel, selected_chat: %{} = chat}} = socket
      ) do
    case Enum.find(panel.variables, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      variable ->
        scope = socket.assigns.current_scope
        {:ok, _} = Variables.delete_variable(scope, variable)
        panel = if panel.editing_id == id, do: blank_variable_form(panel), else: panel
        {:noreply, assign(socket, chat_variables: %{panel | variables: Variables.list_chat_variables(scope, chat.id)})}
    end
  end

  # A closed panel, or no chat selected.
  def handle_event(event, _params, socket) when event in @events, do: {:noreply, socket}

  defp variables_panel(scope, chat) do
    blank_variable_form(%{variables: Variables.list_chat_variables(scope, chat.id)})
  end

  defp blank_variable_form(panel) do
    Map.merge(panel, %{
      form: to_form(Variables.change_variable(%Variable{})),
      value_text: "",
      editing_id: nil
    })
  end

  # The variable the form edits; a fresh struct when creating, or when the edited row is gone.
  defp editing_variable(%{editing_id: nil}), do: %Variable{}
  defp editing_variable(panel), do: Enum.find(panel.variables, %Variable{}, &(&1.id == panel.editing_id))

  defp variable_attrs(params), do: Map.update(params, "value", nil, &JSONText.decode_value/1)
end
