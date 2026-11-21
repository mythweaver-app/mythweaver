defmodule MythweaverWeb.MainChatLive.ScratchpadPanel do
  @moduledoc """
  The scratchpad dock's events for `MainChatLive`, which routes every name in `events/0` here; the
  dock is `MythweaverWeb.Chat.Scratchpads`. Every id resolves through `Messages.get_scratchpad/1`
  and must belong to the open chat, or the event is a no-op. Other tabs follow along through the
  `{:scratchpads_changed, _}` broadcast every write sends.

  Assigns: `:scratchpad_edit` (`%{id, form}` of the card being edited, or nil) and
  `:discarding_scratchpad_id` (the card asking to confirm a discard, or nil).
  """
  use Gettext, backend: Mythweaver.Gettext

  import MythweaverWeb.Flash, only: [flash_unauthorized: 1]
  import Phoenix.Component, only: [assign: 2, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Mythweaver.Messages

  @events ~w(edit_scratchpad save_scratchpad cancel_scratchpad_edit append_scratchpad ask_discard_scratchpad
             cancel_discard_scratchpad discard_scratchpad)

  def events, do: @events

  def handle_event("edit_scratchpad", %{"id" => id}, socket) do
    case chat_scratchpad(socket, id) do
      nil ->
        {:noreply, socket}

      scratchpad ->
        form = to_form(%{"content" => scratchpad.content}, as: :scratchpad)
        {:noreply, assign(socket, scratchpad_edit: %{id: scratchpad.id, form: form}, discarding_scratchpad_id: nil)}
    end
  end

  def handle_event(
        "save_scratchpad",
        %{"scratchpad" => %{"content" => content}},
        %{assigns: %{scratchpad_edit: %{id: id} = edit}} = socket
      ) do
    case chat_scratchpad(socket, id) do
      nil ->
        {:noreply, assign(socket, scratchpad_edit: nil)}

      scratchpad ->
        case Messages.update_scratchpad(socket.assigns.current_scope, scratchpad, %{content: content}) do
          {:ok, _} ->
            {:noreply, assign(socket, scratchpad_edit: nil)}

          {:error, :unauthorized} ->
            {:noreply, flash_unauthorized(socket)}

          {:error, changeset} ->
            {:noreply,
             socket
             |> assign(scratchpad_edit: %{edit | form: to_form(changeset, as: :scratchpad, action: :validate)})
             |> put_flash(:error, dgettext("chat", "A scratchpad can't be empty; discard it instead."))}
        end
    end
  end

  def handle_event("cancel_scratchpad_edit", _params, socket), do: {:noreply, assign(socket, scratchpad_edit: nil)}

  # No chat-busy check: a reply generating elsewhere does not touch this message, and a continue or
  # regenerate of the source itself is refused as `:generating`.
  def handle_event("append_scratchpad", %{"id" => id}, socket) do
    result =
      case chat_scratchpad(socket, id) do
        nil -> :gone
        scratchpad -> Messages.append_scratchpad(socket.assigns.current_scope, scratchpad)
      end

    case result do
      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}

      {:error, :orphaned} ->
        {:noreply, put_flash(socket, :error, dgettext("chat", "This scratchpad's message was deleted."))}

      {:error, :generating} ->
        {:noreply, put_flash(socket, :error, dgettext("chat", "That message is still being generated."))}

      # Done, or already gone (`:not_found`): the broadcast repaints the dock.
      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("ask_discard_scratchpad", %{"id" => id}, socket) do
    case chat_scratchpad(socket, id) do
      nil -> {:noreply, socket}
      scratchpad -> {:noreply, assign(socket, discarding_scratchpad_id: scratchpad.id)}
    end
  end

  def handle_event("cancel_discard_scratchpad", _params, socket),
    do: {:noreply, assign(socket, discarding_scratchpad_id: nil)}

  def handle_event("discard_scratchpad", %{"id" => id}, socket) do
    case chat_scratchpad(socket, id) do
      nil ->
        {:noreply, assign(socket, discarding_scratchpad_id: nil)}

      scratchpad ->
        :ok = Messages.discard_scratchpad(socket.assigns.current_scope, scratchpad)
        {:noreply, assign(socket, discarding_scratchpad_id: nil)}
    end
  end

  # No chat selected, or malformed params.
  def handle_event(event, _params, socket) when event in @events, do: {:noreply, socket}

  defp chat_scratchpad(socket, id) do
    with %{id: chat_id} <- socket.assigns.selected_chat,
         {:ok, id} <- Ecto.UUID.cast(id),
         %{chat_id: ^chat_id} = scratchpad <- Messages.get_scratchpad(socket.assigns.current_scope, id) do
      scratchpad
    else
      _ -> nil
    end
  end
end
