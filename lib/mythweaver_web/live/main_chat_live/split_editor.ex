defmodule MythweaverWeb.MainChatLive.SplitEditor do
  @moduledoc """
  The split editor's events for `MainChatLive`, which routes every name in `events/0` here; the
  editor itself is `MythweaverWeb.Chat.MessageSplit`, rendered in place of the message's body.

  State is the `:split` assign, nil while closed:
  `%{message_id, target: :messages | :scratchpad, content, segments, dividers, author_options, form}`.
  `content` is the active text the dividers were placed against, so a confirm on changed text is
  refused (`:stale`) instead of splitting something else. `dividers` (`%{boundary, author_id}`) stay
  sorted by boundary, and a divider's index is its place in that list; `author_id: :scratchpad` cuts
  the piece below into a scratchpad. A scratchpad split has exactly one divider.
  """
  use Gettext, backend: Mythweaver.Gettext

  import MythweaverWeb.Flash, only: [flash_unauthorized: 1]
  import Phoenix.Component, only: [assign: 2, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Mythweaver.Generation
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message
  alias Mythweaver.Messages.Segment
  alias MythweaverWeb.MainChatLive.MessageWindow

  @events ~w(open_split move_split_divider add_split_divider remove_split_divider change_split confirm_split cancel_split)

  def events, do: @events

  @doc "Whether no reply is speaking or queued in `chat`: splits and merges wait for the queue."
  def idle?(scope, chat), do: match?(%{speaking: nil, queue: []}, Generation.status(scope, chat))

  def handle_event(
        "open_split",
        %{"message_id" => id, "target" => target},
        %{assigns: %{selected_chat: %{} = chat}} = socket
      )
      when target in ["messages", "scratchpad"] do
    target = String.to_existing_atom(target)

    case socket.assigns.split do
      %{message_id: ^id} -> {:noreply, close(socket)}
      _ -> {:noreply, open(close(socket), chat, id, target)}
    end
  end

  def handle_event(
        "move_split_divider",
        %{"index" => index, "boundary" => boundary},
        %{assigns: %{split: %{}}} = socket
      ) do
    with {:ok, index} <- int(index),
         {:ok, boundary} <- int(boundary),
         %{} = divider <- Enum.at(socket.assigns.split.dividers, index),
         true <- free?(socket.assigns.split, boundary, index) do
      dividers = socket.assigns.split.dividers |> List.replace_at(index, %{divider | boundary: boundary})
      {:noreply, put_dividers(socket, dividers)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event(
        "add_split_divider",
        %{"index" => index},
        %{assigns: %{split: %{target: :messages} = split}} = socket
      ) do
    with {:ok, index} <- int(index),
         %{boundary: boundary} <- Enum.at(split.dividers, index),
         true <- free?(split, boundary + 1, nil) do
      {:noreply, put_dividers(socket, [%{boundary: boundary + 1, author_id: nil} | split.dividers])}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event(
        "remove_split_divider",
        %{"index" => index},
        %{assigns: %{split: %{target: :messages} = split}} = socket
      ) do
    with {:ok, index} <- int(index),
         true <- length(split.dividers) > 1 and index < length(split.dividers) do
      {:noreply, put_dividers(socket, List.delete_at(split.dividers, index))}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event(
        "change_split",
        %{"split" => %{"authors" => %{} = authors}},
        %{assigns: %{split: %{} = split}} = socket
      ) do
    ids = MapSet.new(split.author_options, &elem(&1, 1))

    dividers =
      split.dividers
      |> Enum.with_index()
      |> Enum.map(fn {divider, k} ->
        case Map.fetch(authors, Integer.to_string(k)) do
          {:ok, ""} -> %{divider | author_id: nil}
          {:ok, "scratchpad"} -> %{divider | author_id: :scratchpad}
          {:ok, id} -> if MapSet.member?(ids, id), do: %{divider | author_id: id}, else: divider
          :error -> divider
        end
      end)

    {:noreply, assign(socket, split: %{split | dividers: dividers})}
  end

  def handle_event("confirm_split", _params, %{assigns: %{split: %{} = split, selected_chat: %{} = chat}} = socket) do
    scope = socket.assigns.current_scope
    message = Messages.get_message(scope, split.message_id)

    result =
      cond do
        not idle?(scope, chat) -> {:error, :busy}
        message == nil or message.chat_id != chat.id -> {:error, :stale}
        split.target == :messages -> Messages.split_message(scope, chat, message, split.content, split.dividers)
        true -> Messages.split_to_scratchpad(scope, chat, message, split.content, hd(split.dividers).boundary)
      end

    case result do
      # The `{:messages_split, _}` / `{:message_updated, _}` broadcasts repaint every tab.
      {:ok, _message} -> {:noreply, assign(socket, split: nil)}
      {:error, :busy} -> {:noreply, put_flash(socket, :error, busy_message())}
      {:error, :unauthorized} -> {:noreply, flash_unauthorized(socket)}
      {:error, reason} -> {:noreply, socket |> close() |> put_flash(:error, error_message(reason))}
    end
  end

  def handle_event("cancel_split", _params, socket), do: {:noreply, close(socket)}

  # A closed editor, no chat selected, or malformed params.
  def handle_event(event, _params, socket) when event in @events, do: {:noreply, socket}

  @doc "The flash for a split or merge refused while replies are in flight."
  def busy_message do
    gettext_comment("Flash when the user splits or merges messages while replies are still generating.")
    dgettext("chat", "Wait for the reply queue to finish first.")
  end

  @doc "Closes the editor and repaints its message when it still exists."
  def close(%{assigns: %{split: nil}} = socket), do: socket

  def close(%{assigns: %{split: split}} = socket) do
    socket |> assign(split: nil) |> MessageWindow.restream_id(split.message_id)
  end

  @doc "Forgets the editor when it is on `message_id`, without repainting: the caller does."
  def drop(%{assigns: %{split: %{message_id: message_id}}} = socket, message_id), do: assign(socket, split: nil)
  def drop(socket, _message_id), do: socket

  @doc "Drops the editor when `message`'s active text no longer matches what it was opened on."
  def refresh(%{assigns: %{split: %{message_id: id, content: content}}} = socket, %Message{id: id} = message) do
    if Message.active_content(message) == content, do: socket, else: drop(socket, id)
  end

  def refresh(socket, _message), do: socket

  defp open(socket, chat, id, target) do
    scope = socket.assigns.current_scope
    message = Messages.get_message(scope, id)
    segments = message && Segment.paragraphs(Message.active_content(message) || "")

    cond do
      message == nil or message.chat_id != chat.id or message.draft ->
        socket

      not idle?(scope, chat) ->
        put_flash(socket, :error, busy_message())

      Enum.any?(message.bodies, & &1.generating) ->
        put_flash(socket, :error, error_message(:generating))

      length(segments) < 2 ->
        put_flash(socket, :error, dgettext("chat", "This message has no paragraph breaks to split on."))

      target == :scratchpad and not Messages.last_message?(scope, message) ->
        put_flash(socket, :error, error_message(:not_last))

      true ->
        boundary = if target == :messages, do: 1, else: length(segments) - 1

        split = %{
          message_id: message.id,
          target: target,
          content: Message.active_content(message),
          segments: segments,
          dividers: [%{boundary: boundary, author_id: nil}],
          author_options: author_options(chat),
          form: to_form(%{}, as: :split)
        }

        socket |> assign(split: split) |> MessageWindow.restream(message)
    end
  end

  @doc "`{label, character_id}` per character participant; the player's label ends ` (you)`."
  def author_options(chat) do
    for %{character: %{} = character} <- chat.participants do
      label =
        if character.id == chat.player_character_id,
          do:
            dpgettext("chat", "option: author of a split piece, the player's own character", "%{character_name} (you)",
              character_name: character.name
            ),
          else: character.name

      {label, character.id}
    end
  end

  defp put_dividers(socket, dividers) do
    socket
    |> assign(split: %{socket.assigns.split | dividers: Enum.sort_by(dividers, & &1.boundary)})
    |> MessageWindow.restream_id(socket.assigns.split.message_id)
  end

  # `boundary` is a paragraph gap no divider other than the one at `index` holds.
  defp free?(split, boundary, index) do
    boundary >= 1 and boundary <= length(split.segments) - 1 and
      split.dividers
      |> Enum.with_index()
      |> Enum.all?(fn {d, k} -> k == index or d.boundary != boundary end)
  end

  defp int(n) when is_integer(n), do: {:ok, n}

  defp int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp int(_), do: :error

  defp error_message(:stale), do: dgettext("chat", "The message changed while you were splitting it; try again.")
  defp error_message(:generating), do: dgettext("chat", "That message is still being generated.")
  defp error_message(:not_last), do: dgettext("chat", "Only the newest message can be split to a scratchpad.")
  defp error_message(:invalid_split), do: dgettext("chat", "That split is no longer valid; try again.")
end
