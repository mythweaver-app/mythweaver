defmodule MythweaverWeb.MainChatLive.Annotations do
  @moduledoc """
  Rewrite notes on the chat's last character reply, for `MainChatLive`, which routes every name in
  `events/0` here (and handles `"rewrite_annotations"` itself). The popup and the notes panel are
  `MythweaverWeb.Chat.MessageAnnotations`; a passage is opened from the selection toolbar.

  State is the `:annotations` assign, held by this tab only and nil while nothing is pending:
  `%{message_id, content, next_id, items, draft}`. `content` is the active text the passages were
  quoted from, so a changed message drops its notes. `items` (`%{id, quote, start, end, action,
  note}`) stay sorted by `start`; `start`/`end` count characters of the body's rendered text, as
  the client's `Range.toString()` does. `draft` is the open popup (`%{quote, start, end, form,
  error}`) or nil.
  """
  use Gettext, backend: Mythweaver.Gettext

  import Phoenix.Component, only: [assign: 2, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message
  alias MythweaverWeb.MainChatLive.MessageWindow

  @events ~w(open_annotation save_annotation close_annotation remove_annotation discard_annotations)

  @actions %{
    "note" => :note,
    "reject" => :reject,
    "emphasize" => :emphasize,
    "expand" => :expand,
    "shorten" => :shorten,
    "keep" => :keep
  }

  def events, do: @events

  defp still_generating do
    gettext_comment("Flash when the user acts on a message whose reply is still streaming.")
    dgettext("chat", "That message is still being generated.")
  end

  defp not_latest do
    gettext_comment("Flash when the user selects a passage of an older reply to annotate.")
    dgettext("chat", "Only the latest reply can be annotated.")
  end

  defp changed do
    gettext_comment("Flash when the annotated message was edited before the note was saved.")
    dgettext("chat", "The message changed; select the passage again.")
  end

  def handle_event(
        "open_annotation",
        %{"message_id" => id, "text" => text, "start" => s, "end" => e},
        %{assigns: %{selected_chat: %{} = chat}} = socket
      )
      when is_binary(id) and is_binary(text) do
    scope = socket.assigns.current_scope

    with {:ok, s} <- int(s),
         {:ok, e} <- int(e),
         true <- s >= 0 and s < e and String.trim(text) != "",
         %Message{} = message <- Messages.get_message(scope, id),
         true <- message.chat_id == chat.id and not message.draft and message.author_is_character do
      content = Message.active_content(message)

      cond do
        Enum.any?(message.bodies, & &1.generating) ->
          {:noreply, put_flash(socket, :error, still_generating())}

        not Messages.last_message?(scope, message) ->
          {:noreply, put_flash(socket, :error, not_latest())}

        String.trim(content || "") == "" ->
          {:noreply, socket}

        true ->
          state =
            case socket.assigns.annotations do
              %{message_id: ^id, content: ^content} = state -> state
              _ -> %{message_id: message.id, content: content, next_id: 1, items: [], draft: nil}
            end

          draft = %{
            quote: String.trim(text),
            start: s,
            end: e,
            form: to_form(%{"note" => ""}, as: :annotation),
            error: nil
          }

          {:noreply, assign(socket, annotations: %{state | draft: draft})}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event(
        "save_annotation",
        %{"annotation" => params},
        %{assigns: %{annotations: %{draft: %{}} = state}} = socket
      ) do
    note = params["note"] |> to_string() |> String.trim()
    note = if note != "", do: note
    message = Messages.get_message(socket.assigns.current_scope, state.message_id)

    cond do
      message == nil or Message.active_content(message) != state.content ->
        {:noreply,
         socket
         |> discard()
         |> put_flash(:error, changed())}

      params["action"] == "rewrite" ->
        cond do
          note != nil ->
            {:noreply, socket |> put_state(add(state, :note, note)) |> rewrite_later()}

          state.items == [] ->
            {:noreply,
             put_error(
               socket,
               state,
               params,
               dpgettext("chat", "status: rewrite request error when no note was added", "Write a note first.")
             )}

          true ->
            {:noreply, socket |> put_state(%{state | draft: nil}) |> rewrite_later()}
        end

      true ->
        case Map.get(@actions, to_string(params["action"]), :note) do
          :note when note == nil ->
            {:noreply, put_error(socket, state, params, dgettext("chat", "Write a note, or pick a quick action."))}

          action ->
            {:noreply, put_state(socket, add(state, action, note))}
        end
    end
  end

  def handle_event("close_annotation", _params, socket), do: {:noreply, close_draft(socket)}

  def handle_event("remove_annotation", %{"id" => id}, %{assigns: %{annotations: %{} = state}} = socket) do
    case int(id) do
      {:ok, id} -> {:noreply, put_state(socket, %{state | items: Enum.reject(state.items, &(&1.id == id))})}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("discard_annotations", _params, socket), do: {:noreply, discard(socket)}

  # Nothing pending, no chat selected, or malformed params.
  def handle_event(event, _params, socket) when event in @events, do: {:noreply, socket}

  @doc "Forgets every note and repaints the message when it still exists."
  def discard(%{assigns: %{annotations: nil}} = socket), do: socket

  def discard(%{assigns: %{annotations: state}} = socket) do
    socket |> assign(annotations: nil) |> MessageWindow.restream_id(state.message_id)
  end

  @doc "Closes the popup, keeping the saved notes."
  def close_draft(%{assigns: %{annotations: %{} = state}} = socket),
    do: assign(socket, annotations: normalize(%{state | draft: nil}))

  def close_draft(socket), do: socket

  @doc "Forgets the notes when they are on `message_id`, without repainting: the caller does."
  def drop(%{assigns: %{annotations: %{message_id: message_id}}} = socket, message_id),
    do: assign(socket, annotations: nil)

  def drop(socket, _message_id), do: socket

  @doc "Drops the notes when `message`'s active text no longer matches what they quote."
  def refresh(%{assigns: %{annotations: %{message_id: id, content: content}}} = socket, %Message{id: id} = message) do
    if Message.active_content(message) == content, do: socket, else: drop(socket, id)
  end

  def refresh(socket, _message), do: socket

  @doc """
  The rewrite instructions for `items` (in `start` order), followed by the composer's `general`
  text when it is not blank. Each passage is quoted and numbered, with its quick action's line and
  its note beneath it.
  """
  @spec instructions([map()], String.t() | nil) :: String.t()
  def instructions(items, general) do
    notes =
      items
      |> Enum.sort_by(& &1.start)
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {item, n} ->
        "#{n}. \"#{item.quote}\"" <>
          if(item.action == :note, do: "", else: "\n   " <> action_line(item.action)) <>
          if(item.note, do: "\n   Note: " <> item.note, else: "")
      end)

    text = "Notes on passages of the message, each quoted from it:\n\n" <> notes

    case String.trim(general || "") do
      "" -> text
      general -> text <> "\n\nGeneral instructions:\n" <> general
    end
  end

  defp action_line(:reject), do: "Remove this passage entirely. Do not replace it with something similar."
  defp action_line(:emphasize), do: "Emphasize this passage: keep it and make it more prominent."
  defp action_line(:expand), do: "Expand this passage with more detail."
  defp action_line(:shorten), do: "Shorten this passage."
  defp action_line(:keep), do: "Keep this passage exactly as written."

  # The draft becomes an item, and the popup closes.
  defp add(%{draft: draft} = state, action, note) do
    item = %{id: state.next_id, quote: draft.quote, start: draft.start, end: draft.end, action: action, note: note}

    %{state | items: Enum.sort_by([item | state.items], & &1.start), next_id: state.next_id + 1, draft: nil}
  end

  defp put_error(socket, state, params, error) do
    draft = %{state.draft | form: to_form(params, as: :annotation), error: error}
    assign(socket, annotations: %{state | draft: draft})
  end

  defp put_state(socket, state) do
    socket |> assign(annotations: normalize(state)) |> MessageWindow.restream_id(state.message_id)
  end

  defp rewrite_later(socket) do
    send(self(), :rewrite_annotations)
    socket
  end

  defp normalize(%{items: [], draft: nil}), do: nil
  defp normalize(state), do: state

  defp int(n) when is_integer(n), do: {:ok, n}

  defp int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp int(_), do: :error
end
