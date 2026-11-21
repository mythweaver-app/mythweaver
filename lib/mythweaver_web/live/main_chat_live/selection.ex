defmodule MythweaverWeb.MainChatLive.Selection do
  @moduledoc """
  The message checkboxes' events for `MainChatLive`, which routes every name in `events/0` here:
  selecting rows, then hiding, deleting (through `MessageActions`' `:delete_confirm` dialog), merging
  or making a memory of them. The selection is the `:selected_messages` assign (message id =>
  `visible_to_ai`), cached because stream rows are not enumerable; it covers loaded rows only.
  """
  use Gettext, backend: Mythweaver.Gettext
  use MythweaverWeb, :verified_routes

  import MythweaverWeb.Flash, only: [unauthorized_message: 0]
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [push_patch: 2, put_flash: 3]

  alias Mythweaver.Memory.Rollback
  alias Mythweaver.Messages
  alias MythweaverWeb.MainChatLive.MessageWindow
  alias MythweaverWeb.MainChatLive.SplitEditor
  alias MythweaverWeb.MainChatLive.Swipes

  @events ~w(select_message_range toggle_message_selection bulk_toggle_visibility bulk_delete_messages
             merge_into_previous bulk_merge_messages select_all_messages clear_message_selection
             bulk_create_memory)

  def events, do: @events

  # A shift-click range from the `RangeSelect` hook (assets/js/hooks/range_select.ts): add every
  # listed row that is loaded. The hook checked the boxes itself; the new rows are re-inserted so
  # they also render checked.
  def handle_event("select_message_range", %{"ids" => ids}, socket) when is_list(ids) do
    selected = socket.assigns.selected_messages
    ids = MapSet.new(ids)
    added = for m <- MessageWindow.loaded_messages(socket), m.id in ids, not Map.has_key?(selected, m.id), do: m
    socket = Enum.reduce(added, socket, &MessageWindow.restream(&2, &1))

    {:noreply, assign(socket, selected_messages: Map.merge(selected, Map.new(added, &{&1.id, &1.visible_to_ai})))}
  end

  # The browser already toggled the box, so the row needs no re-render.
  def handle_event("toggle_message_selection", %{"message_id" => id}, socket) do
    selected = socket.assigns.selected_messages

    selected =
      if Map.has_key?(selected, id) do
        Map.delete(selected, id)
      else
        case Swipes.chat_message(socket, id) do
          nil -> selected
          message -> Map.put(selected, id, message.visible_to_ai)
        end
      end

    {:noreply, assign(socket, selected_messages: selected)}
  end

  # Tri-state: any visible message selected → hide them all; all already hidden → show them all.
  # The selection is kept so a second click reverses the first.
  def handle_event("bulk_toggle_visibility", _params, socket) do
    selected = socket.assigns.selected_messages
    visible? = not Enum.any?(Map.values(selected))

    {socket, kept} =
      socket.assigns.current_scope
      |> Messages.get_messages(Map.keys(selected))
      |> Enum.reduce({socket, %{}}, fn
        %{visible_to_ai: ^visible?} = message, {socket, kept} ->
          {socket, Map.put(kept, message.id, visible?)}

        message, {socket, kept} ->
          {:ok, message} = Messages.set_visible_to_ai(socket.assigns.current_scope, message, visible?)
          {MessageWindow.restream(socket, message), Map.put(kept, message.id, visible?)}
      end)

    {:noreply, socket |> assign(selected_messages: kept)}
  end

  def handle_event("bulk_delete_messages", _params, %{assigns: %{selected_messages: selected}} = socket)
      when selected == %{}, do: {:noreply, socket}

  def handle_event("bulk_delete_messages", _params, %{assigns: %{selected_chat: %{} = chat}} = socket) do
    {:noreply,
     assign(socket,
       delete_confirm: %{
         kind: :bulk,
         count: map_size(socket.assigns.selected_messages),
         preview: Rollback.preview(socket.assigns.current_scope, chat.id, selected_positions(socket))
       }
     )}
  end

  def handle_event("bulk_delete_messages", _params, socket), do: {:noreply, socket}

  # Every tab, this one included, repaints from the `{:message_deleted, _}`/`{:message_updated, _}` broadcasts.
  def handle_event("merge_into_previous", %{"message_id" => id}, %{assigns: %{selected_chat: %{} = chat}} = socket) do
    case Swipes.chat_message(socket, id) do
      nil ->
        {:noreply, socket}

      message ->
        if SplitEditor.idle?(socket.assigns.current_scope, chat) do
          case Messages.merge_into_previous(socket.assigns.current_scope, chat, message) do
            {:ok, _} -> {:noreply, socket}
            {:error, reason} -> {:noreply, put_flash(socket, :error, merge_error(reason))}
          end
        else
          {:noreply, put_flash(socket, :error, SplitEditor.busy_message())}
        end
    end
  end

  def handle_event("merge_into_previous", _params, socket), do: {:noreply, socket}

  def handle_event("bulk_merge_messages", _params, %{assigns: %{selected_chat: %{} = chat}} = socket) do
    if SplitEditor.idle?(socket.assigns.current_scope, chat) do
      case Messages.merge_messages(socket.assigns.current_scope, chat, Map.keys(socket.assigns.selected_messages)) do
        {:ok, _} -> {:noreply, clear_selection(socket)}
        {:error, reason} -> {:noreply, put_flash(socket, :error, merge_error(reason))}
      end
    else
      {:noreply, put_flash(socket, :error, SplitEditor.busy_message())}
    end
  end

  def handle_event("bulk_merge_messages", _params, socket), do: {:noreply, socket}

  # Selects the loaded rows only. Rows not already selected are re-inserted, so their boxes render checked.
  def handle_event("select_all_messages", _params, socket) do
    selected = socket.assigns.selected_messages
    messages = MessageWindow.loaded_messages(socket)

    socket =
      messages
      |> Enum.reject(&Map.has_key?(selected, &1.id))
      |> Enum.reduce(socket, &MessageWindow.restream(&2, &1))

    {:noreply, assign(socket, selected_messages: Map.new(messages, &{&1.id, &1.visible_to_ai}))}
  end

  def handle_event("clear_message_selection", _params, socket), do: {:noreply, clear_selection(socket)}

  # A scene from the selected messages: the memory modal opens prefilled with their span.
  def handle_event("bulk_create_memory", _params, %{assigns: %{selected_chat: %{} = chat}} = socket) do
    case selected_positions(socket) do
      [] ->
        {:noreply, put_flash(socket, :error, dgettext("chat", "Check the messages to make a memory of first."))}

      positions ->
        {first, last} = Enum.min_max(positions)

        {:noreply,
         socket
         |> clear_selection()
         |> push_patch(to: ~p"/chats/#{chat.id}/memory?start=#{first + 1}&end=#{last + 1}")}
    end
  end

  # Stream rows only re-render on insert, so each selected row is re-inserted to clear its box.
  defp clear_selection(socket) do
    socket.assigns.current_scope
    |> Messages.get_messages(Map.keys(socket.assigns.selected_messages))
    |> Enum.reduce(socket, &MessageWindow.restream(&2, &1))
    |> assign(selected_messages: %{})
  end

  # The selected messages' positions; an id a delete outran is skipped.
  defp selected_positions(socket) do
    socket.assigns.current_scope
    |> Messages.get_messages(Map.keys(socket.assigns.selected_messages))
    |> Enum.map(& &1.position)
  end

  # `:not_contiguous` cannot happen for neighbours; `:not_found` is a selection a delete outran.
  defp merge_error(:no_previous), do: dgettext("chat", "No previous message to merge into.")
  defp merge_error(:too_few), do: dgettext("chat", "Select at least two messages to merge.")
  defp merge_error(:not_contiguous), do: dgettext("chat", "Merge needs a contiguous run of messages.")
  defp merge_error(:generating), do: Swipes.still_generating()
  defp merge_error(:unauthorized), do: unauthorized_message()
  defp merge_error(:not_found), do: dgettext("chat", "Some selected messages are gone; select again.")
end
