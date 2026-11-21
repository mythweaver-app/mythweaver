defmodule MythweaverWeb.MainChatLive.Swipes do
  @moduledoc """
  The swipe arrows', swipe inspector's and prompt inspector's events for `MainChatLive`, which routes
  every name in `events/0` here. The inspectors live in the `:swipe_inspector` assign
  (`%{message, expanded, diff}`) and the `:prompt_inspector` assign (`%{snapshot, body, view,
  expanded, images}`), each nil while closed. Swiping does not broadcast: other tabs keep their own
  active swipe.
  """
  use Gettext, backend: Mythweaver.Gettext

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Mythweaver.Attachments
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message
  alias Mythweaver.Messages.PromptSnapshot
  alias MythweaverWeb.Chat.PromptInspector
  alias MythweaverWeb.MainChatLive.MessageWindow

  @events ~w(swipe_prev swipe_next open_swipe_inspector close_swipe_inspector toggle_swipe toggle_swipe_diff
             open_prompt_inspector close_prompt_inspector prompt_inspector_view toggle_prompt_section
             activate_swipe)

  def events, do: @events

  def handle_event("swipe_prev", %{"message_id" => id}, socket), do: swipe(socket, id, -1)
  def handle_event("swipe_next", %{"message_id" => id}, socket), do: swipe(socket, id, +1)

  def handle_event("open_swipe_inspector", %{"message_id" => id}, socket) do
    case chat_message(socket, id) do
      nil ->
        {:noreply, socket}

      message ->
        # The active swipe opens expanded: it is the one the user is most likely inspecting.
        active_id = Enum.find_value(message.bodies, &(&1.active && &1.id))
        {:noreply, assign(socket, swipe_inspector: %{message: message, expanded: active_id, diff: MapSet.new()})}
    end
  end

  def handle_event("close_swipe_inspector", _params, socket), do: {:noreply, assign(socket, swipe_inspector: nil)}

  # Exclusive: expanding a row collapses whichever row was open.
  def handle_event("toggle_swipe", %{"body_id" => id}, %{assigns: %{swipe_inspector: %{} = inspector}} = socket) do
    expanded = if inspector.expanded != id, do: id
    {:noreply, assign(socket, swipe_inspector: %{inspector | expanded: expanded})}
  end

  def handle_event("toggle_swipe", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_swipe_diff", %{"body_id" => id}, %{assigns: %{swipe_inspector: %{} = inspector}} = socket) do
    diff =
      if MapSet.member?(inspector.diff, id), do: MapSet.delete(inspector.diff, id), else: MapSet.put(inspector.diff, id)

    {:noreply, assign(socket, swipe_inspector: %{inspector | diff: diff})}
  end

  def handle_event("toggle_swipe_diff", _params, socket), do: {:noreply, socket}

  # The inspector shows the active swipe's snapshot, redacted; the stored row stays unredacted. The
  # images a section sent inline are loaded by id (one since deleted just no longer shows).
  def handle_event("open_prompt_inspector", %{"message_id" => id}, socket) do
    with %{} = message <- chat_message(socket, id),
         %{} = body <- Message.active_body(message),
         %PromptSnapshot{} = snapshot <- Messages.get_prompt_snapshot(socket.assigns.current_scope, body.id) do
      image_ids = for section <- snapshot.sections, sent <- section["inline_images"] || [], do: sent["id"]

      inspector = %{
        snapshot: PromptSnapshot.redacted(socket.assigns.current_scope, snapshot),
        body: body,
        view: :items,
        expanded: nil,
        images: Attachments.get_attachments(socket.assigns.current_scope, image_ids)
      }

      {:noreply, assign(socket, prompt_inspector: inspector)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("close_prompt_inspector", _params, socket), do: {:noreply, assign(socket, prompt_inspector: nil)}

  def handle_event(
        "prompt_inspector_view",
        %{"view" => view},
        %{assigns: %{prompt_inspector: %{} = inspector}} = socket
      ) do
    selected = Enum.find_value(PromptInspector.views(), fn {key, _label} -> Atom.to_string(key) == view && key end)

    case selected do
      nil -> {:noreply, socket}
      view -> {:noreply, assign(socket, prompt_inspector: %{inspector | view: view})}
    end
  end

  def handle_event("prompt_inspector_view", _params, socket), do: {:noreply, socket}

  # Exclusive, like the swipe rows: expanding a section collapses whichever was open.
  def handle_event(
        "toggle_prompt_section",
        %{"index" => index},
        %{assigns: %{prompt_inspector: %{} = inspector}} = socket
      ) do
    case Integer.parse(index) do
      {index, ""} ->
        expanded = if inspector.expanded != index, do: index
        {:noreply, assign(socket, prompt_inspector: %{inspector | expanded: expanded})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_prompt_section", _params, socket), do: {:noreply, socket}

  # Like the swipe arrows, this does not broadcast: other tabs keep their own active swipe.
  def handle_event("activate_swipe", %{"body_id" => body_id}, %{assigns: %{swipe_inspector: %{} = inspector}} = socket) do
    socket =
      case Messages.get_message(socket.assigns.current_scope, inspector.message.id) do
        nil ->
          assign(socket, swipe_inspector: nil)

        message ->
          cond do
            Enum.any?(message.bodies, & &1.generating) ->
              put_flash(socket, :error, still_generating())

            body = Enum.find(message.bodies, &(&1.id == body_id and not &1.active)) ->
              {:ok, _} = Messages.set_active_body(socket.assigns.current_scope, body)
              reloaded = Messages.get_message!(socket.assigns.current_scope, message.id)

              socket
              |> MessageWindow.restream_swiped(reloaded)
              |> assign(swipe_inspector: %{inspector | message: reloaded})

            true ->
              socket
          end
      end

    {:noreply, socket}
  end

  def handle_event("activate_swipe", _params, socket), do: {:noreply, socket}

  defp swipe(socket, id, delta) do
    with %Message{bodies: bodies} <- chat_message(socket, id),
         index = Enum.find_index(bodies, & &1.active) || 0,
         target = if(delta < 0 and index == 0, do: length(bodies) - 1, else: index + delta),
         %{active: false} = body <- Enum.at(bodies, target) do
      {:ok, _} = Messages.set_active_body(socket.assigns.current_scope, body)
      {:noreply, MessageWindow.restream_swiped(socket, Messages.get_message!(socket.assigns.current_scope, id))}
    else
      _ -> {:noreply, socket}
    end
  end

  @doc "The flash for acting on a message whose reply is still streaming."
  def still_generating do
    gettext_comment("Flash when the user acts on a message whose reply is still streaming.")
    dgettext("chat", "That message is still being generated.")
  end

  @doc "Message `id` when it belongs to the open chat, else nil. The id comes from the client, so it is checked."
  def chat_message(socket, id) do
    with %{id: chat_id} <- socket.assigns.selected_chat,
         %Message{chat_id: ^chat_id} = message <- Messages.get_message(socket.assigns.current_scope, id) do
      message
    else
      _ -> nil
    end
  end
end
