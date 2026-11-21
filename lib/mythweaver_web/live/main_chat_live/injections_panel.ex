defmodule MythweaverWeb.MainChatLive.InjectionsPanel do
  @moduledoc """
  The chat injections modal's events for `MainChatLive`, which routes every name in `events/0` here.
  The panel lives in the `:chat_injections` assign (nil while closed): the chat's injections, the
  form, and the id being edited. Every write also refreshes the header's `:injection_count` badge.
  """
  use Gettext, backend: Mythweaver.Gettext

  import MythweaverWeb.Flash, only: [flash_unauthorized: 1]
  import Phoenix.Component, only: [assign: 2, to_form: 1]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Mythweaver.Format
  alias Mythweaver.Injections
  alias Mythweaver.Injections.Injection

  @events ~w(open_chat_injections close_chat_injections new_chat_injection edit_chat_injection
             validate_chat_injection save_chat_injection delete_chat_injection toggle_chat_injection
             rearm_chat_injection clean_up_chat_injections)

  def events, do: @events

  def handle_event("open_chat_injections", _params, %{assigns: %{selected_chat: %{} = chat}} = socket),
    do: {:noreply, assign(socket, chat_injections: injections_panel(socket.assigns.current_scope, chat))}

  def handle_event("close_chat_injections", _params, socket), do: {:noreply, assign(socket, chat_injections: nil)}

  def handle_event("new_chat_injection", _params, %{assigns: %{chat_injections: %{} = panel}} = socket),
    do: {:noreply, assign(socket, chat_injections: blank_injection_form(panel))}

  # Ids are looked up in the panel's own list, which is this chat's injections, so a crafted id cannot
  # reach another chat's.
  def handle_event("edit_chat_injection", %{"id" => id}, %{assigns: %{chat_injections: %{} = panel}} = socket) do
    case Enum.find(panel.injections, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      injection ->
        panel = %{panel | form: to_form(Injections.change_injection(injection)), editing_id: id}
        {:noreply, assign(socket, chat_injections: panel)}
    end
  end

  def handle_event(
        "validate_chat_injection",
        %{"injection" => params},
        %{assigns: %{chat_injections: %{} = panel}} = socket
      ) do
    changeset =
      panel
      |> editing_injection()
      |> Injections.change_injection(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, chat_injections: %{panel | form: to_form(changeset)})}
  end

  def handle_event(
        "save_chat_injection",
        %{"injection" => params},
        %{assigns: %{chat_injections: %{} = panel, selected_chat: %{} = chat}} = socket
      ) do
    scope = socket.assigns.current_scope

    result =
      case editing_injection(panel) do
        %Injection{id: nil} -> Injections.create_injection(scope, chat.id, params)
        injection -> Injections.update_injection(scope, injection, params)
      end

    case result do
      {:ok, _injection} ->
        {:noreply, refresh_injections(socket, chat, injections_panel(scope, chat))}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}

      {:error, changeset} ->
        {:noreply, assign(socket, chat_injections: %{panel | form: to_form(changeset)})}
    end
  end

  def handle_event(
        event,
        %{"id" => id},
        %{assigns: %{chat_injections: %{} = panel, selected_chat: %{} = chat}} = socket
      )
      when event in ~w(delete_chat_injection toggle_chat_injection rearm_chat_injection) do
    case Enum.find(panel.injections, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      injection ->
        {:ok, _} = injection_action(socket.assigns.current_scope, event, injection)
        {:noreply, refresh_injections(socket, chat, panel)}
    end
  end

  def handle_event(
        "clean_up_chat_injections",
        _params,
        %{assigns: %{chat_injections: %{} = panel, selected_chat: %{} = chat}} = socket
      ) do
    {:ok, count} = Injections.clean_up(socket.assigns.current_scope, chat.id)
    socket = refresh_injections(socket, chat, panel)

    socket =
      if count > 0,
        do: put_flash(socket, :info, removed_flash(count)),
        else: socket

    {:noreply, socket}
  end

  # A closed panel, or no chat selected.
  def handle_event(event, _params, socket) when event in @events, do: {:noreply, socket}

  defp removed_flash(count) do
    gettext_comment("Flash after the user cleans up injections that have already fired.")

    dpngettext(
      "chat",
      "status: flash after spent injections are removed",
      "Removed %{injection_count} spent injection",
      "Removed %{injection_count} spent injections",
      count,
      injection_count: Format.number(count)
    )
  end

  defp injections_panel(scope, chat) do
    blank_injection_form(%{injections: Injections.list_injections(scope, chat.id)})
  end

  defp blank_injection_form(panel) do
    Map.merge(panel, %{form: to_form(Injections.change_injection(%Injection{})), editing_id: nil})
  end

  # The injection the form edits; a fresh struct when creating, or when the edited row is gone.
  defp editing_injection(%{editing_id: nil}), do: %Injection{}
  defp editing_injection(panel), do: Enum.find(panel.injections, %Injection{}, &(&1.id == panel.editing_id))

  defp injection_action(scope, "delete_chat_injection", injection), do: Injections.delete_injection(scope, injection)
  defp injection_action(scope, "rearm_chat_injection", injection), do: Injections.rearm(scope, injection)

  defp injection_action(scope, "toggle_chat_injection", injection),
    do: Injections.update_injection(scope, injection, %{enabled: !injection.enabled})

  # After a write from this panel: a fresh list and badge; a form editing a row that is gone resets.
  defp refresh_injections(socket, chat, panel) do
    scope = socket.assigns.current_scope
    injections = Injections.list_injections(scope, chat.id)
    panel = %{panel | injections: injections}

    panel =
      if panel.editing_id && not Enum.any?(injections, &(&1.id == panel.editing_id)),
        do: blank_injection_form(panel),
        else: panel

    assign(socket, chat_injections: panel, injection_count: Injections.count_active(scope, chat.id))
  end
end
