defmodule MythweaverWeb.MainChatLive.MessageWindow do
  @moduledoc """
  The slice of a chat's transcript `MainChatLive` holds in its `:messages` stream, and the
  `:message_window` assign describing it. This module owns that stream: every insert, delete and
  reset of `:messages` goes through it.

  Invariant: the loaded rows are exactly the chat's non-draft messages with
  `oldest <= position <= newest`. It holds because the initial load is contiguous, pages extend the
  window contiguously, live appends happen only while `newer?` is false, a new message always gets a
  position above every existing one (`Messages.next_position/1`), and a delete removes the row from
  both the DB and the window. Positions move only on a split (`Messages.split_message/4`), and
  `receive_split/3` moves the bounds with them.

  A chat opens on its newest `page_size/0` messages; paging either way fetches `page_size/0` more.
  Past `max_loaded/0` rows the far end is unloaded, so `older?`/`newer?` say whether messages exist
  beyond each loaded edge. A jump to an unloaded message (`load_around/2`) replaces the window with
  one page around it.

  Selecting a chat only `open/1`s its window: empty and `loading?`, so the page or patch that switches
  chats renders without the transcript, whose rows are most of its weight. `MainChatLive` then runs
  `load_latest/1` from a message it sent itself. That message is handled in the LiveView process, in
  order with the chat's broadcasts, so the invariant still holds: a broadcast handled before it is
  already in what it reads, and a `loading?` window takes no row from one (`receive_created/3`).

  It also keeps the `:embedding_status` assign (`Mythweaver.Lore.Embeddings.status/3`) the rows'
  embedding icons read. Every reset of the window reads it afresh, `on?` included; a page adds its
  bodies to `embedded`. `bodies_embedded/2` and `restream_swiped/2` keep it current between loads.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [stream: 4, stream_insert: 4, stream_delete: 3, stream_delete_by_dom_id: 3]

  alias Mythweaver.Lore.Embeddings
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message

  # Rows fetched per page, initial load included.
  @page_size 50
  # Most rows the transcript holds; loading past it unloads the far end. May become configuration.
  @max_loaded 200

  defstruct oldest: nil, newest: nil, count: 0, older?: false, newer?: false, loading?: false

  @type t :: %__MODULE__{
          oldest: integer() | nil,
          newest: integer() | nil,
          count: non_neg_integer(),
          older?: boolean(),
          newer?: boolean(),
          loading?: boolean()
        }

  def page_size, do: @page_size
  def max_loaded, do: @max_loaded

  @doc "The `:embedding_status` of a window without Vector lore: no icons."
  def embedding_off, do: %{on?: false, embedded: MapSet.new()}

  @doc """
  Empties the transcript for a newly selected chat without reading it; `load_latest/1` fills it.
  With no chat there is nothing to load.
  """
  def open(%{assigns: %{selected_chat: nil}} = socket), do: load_latest(socket)

  def open(socket) do
    socket
    |> stream(:messages, [], reset: true)
    |> assign(message_window: %__MODULE__{loading?: true}, messages_empty?: false, embedding_status: embedding_off())
  end

  @doc "Resets the transcript to the selected chat's newest page."
  def load_latest(%{assigns: %{selected_chat: nil}} = socket) do
    socket
    |> stream(:messages, [], reset: true)
    |> assign(message_window: %__MODULE__{}, messages_empty?: true, embedding_status: embedding_off())
  end

  def load_latest(socket) do
    {page, older?} =
      Messages.list_messages_page(socket.assigns.current_scope, socket.assigns.selected_chat, limit: @page_size)

    window =
      case page do
        [] ->
          %__MODULE__{older?: older?}

        [first | _] ->
          %__MODULE__{
            oldest: first.position,
            newest: List.last(page).position,
            count: length(page),
            older?: older?
          }
      end

    socket
    |> stream(:messages, page, reset: true)
    |> assign(message_window: window, messages_empty?: page == [])
    |> reset_embedding_status(page)
  end

  @doc "Prepends the page before the loaded window, unloading the newest rows past `max_loaded/0`."
  def load_older(%{assigns: %{message_window: %__MODULE__{older?: false}}} = socket), do: socket

  def load_older(socket) do
    window = socket.assigns.message_window

    {page, more?} =
      Messages.list_messages_page(socket.assigns.current_scope, socket.assigns.selected_chat,
        before: window.oldest,
        limit: @page_size
      )

    case page do
      [] ->
        assign(socket, message_window: %{window | older?: false})

      [first | _] ->
        window = %{window | oldest: first.position, count: window.count + length(page), older?: more?}

        socket
        |> stream(:messages, Enum.reverse(page), at: 0)
        |> assign(message_window: window)
        |> extend_embedding_status(page)
        |> trim_excess(:newest)
    end
  end

  @doc "Appends the page after the loaded window, unloading the oldest rows past `max_loaded/0`."
  def load_newer(%{assigns: %{message_window: %__MODULE__{newer?: false}}} = socket), do: socket

  def load_newer(socket) do
    window = socket.assigns.message_window

    {page, more?} =
      Messages.list_messages_page(socket.assigns.current_scope, socket.assigns.selected_chat,
        after: window.newest,
        limit: @page_size
      )

    case page do
      [] ->
        assign(socket, message_window: %{window | newer?: false})

      _ ->
        window = %{window | newest: List.last(page).position, count: window.count + length(page), newer?: more?}

        socket
        |> stream(:messages, page, at: -1)
        |> assign(message_window: window)
        |> extend_embedding_status(page)
        |> trim_excess(:oldest)
    end
  end

  @doc """
  Makes the message at `position` loaded and returns it: `{:ok, socket, message}`, or `:error` when
  the chat has no message there. A loaded one leaves the window alone; otherwise the window becomes
  the page that starts half a page before it (fuller above when it is near the newest end).
  """
  def load_around(socket, position) when is_integer(position) do
    %{current_scope: scope, selected_chat: chat, message_window: window} = socket.assigns

    if window.oldest != nil and window.oldest <= position and position <= window.newest do
      case Messages.list_messages_between(scope, chat, position, position) do
        [message] -> {:ok, socket, message}
        [] -> :error
      end
    else
      case Messages.list_messages_page(scope, chat, after: position - 1, limit: @page_size - div(@page_size, 2)) do
        {[%Message{position: ^position} = message | _] = newer, newer?} ->
          {older, older?} =
            Messages.list_messages_page(scope, chat, before: position, limit: @page_size - length(newer))

          page = older ++ newer

          window = %__MODULE__{
            oldest: hd(page).position,
            newest: List.last(page).position,
            count: length(page),
            older?: older?,
            newer?: newer?
          }

          socket =
            socket
            |> stream(:messages, page, reset: true)
            |> assign(message_window: window, messages_empty?: false)
            |> reset_embedding_status(page)

          {:ok, socket, message}

        _ ->
          :error
      end
    end
  end

  defp trim_excess(socket, edge) do
    case socket.assigns.message_window.count - @max_loaded do
      excess when excess > 0 -> trim(socket, edge, excess)
      _ -> socket
    end
  end

  # Unloads `k` rows from `edge`. The bound moves to the first kept row, read from the DB, so the
  # window stays contiguous.
  defp trim(socket, edge, k) do
    window = socket.assigns.message_window

    rows =
      Messages.window_edge(
        socket.assigns.current_scope,
        socket.assigns.selected_chat,
        window.oldest,
        window.newest,
        edge,
        k + 1
      )

    {dropped, kept} =
      case Enum.split(rows, k) do
        # A delete broadcast is still in flight, so `count` ran ahead of the DB: keep the innermost row.
        {dropped, []} -> Enum.split(dropped, length(dropped) - 1)
        split -> split
      end

    case kept do
      [] ->
        socket

      [{_id, bound} | _] ->
        socket =
          Enum.reduce(dropped, socket, fn {id, _}, s -> stream_delete_by_dom_id(s, :messages, "messages-#{id}") end)

        window = %{window | count: window.count - length(dropped)}

        window =
          case edge do
            :newest -> %{window | newest: bound, newer?: true}
            :oldest -> %{window | oldest: bound, older?: true}
          end

        assign(socket, message_window: window)
    end
  end

  @doc "Whether `message` falls inside the loaded window."
  def loaded?(%__MODULE__{} = window, %Message{position: position}) do
    window.oldest != nil and is_integer(position) and window.oldest <= position and position <= window.newest
  end

  @doc """
  Repaints `message`'s row when it is loaded; otherwise leaves the socket alone, since inserting a row
  outside the window would append it out of order.
  """
  def restream(socket, %Message{} = message) do
    if loaded?(socket.assigns.message_window, message),
      do: stream_insert(socket, :messages, message, []),
      else: socket
  end

  @doc "Re-reads message `id` and repaints its row, as `restream/2`; a message that is gone is skipped."
  def restream_id(socket, id) do
    case Messages.get_message(socket.assigns.current_scope, id) do
      nil -> socket
      message -> restream(socket, message)
    end
  end

  @doc """
  Repaints a message whose active swipe just changed, as `restream/2`. The newly active body may
  have been embedded long ago, which no `bodies_embedded/2` will announce, so its status is read.
  """
  def restream_swiped(socket, %Message{} = message) do
    socket |> extend_embedding_status([message]) |> restream(message)
  end

  @doc """
  Handles a `{:bodies_embedded, body_ids}` broadcast: marks the bodies embedded and repaints the
  loaded rows they are active on. Stream rows only change when re-inserted.
  """
  def bodies_embedded(%{assigns: %{embedding_status: %{on?: true} = status}} = socket, body_ids) do
    socket = assign(socket, embedding_status: %{status | embedded: MapSet.union(status.embedded, MapSet.new(body_ids))})

    socket.assigns.current_scope
    |> Messages.list_messages_by_active_body(socket.assigns.selected_chat, body_ids)
    |> Enum.reduce(socket, &restream(&2, &1))
  end

  def bodies_embedded(socket, _body_ids), do: socket

  @doc """
  Handles a `{:message_created, message}` broadcast. `own?` means this tab sent it, which snaps the
  transcript back to the latest page when the newest rows are unloaded.
  """
  def receive_created(socket, message, own?)

  # `load_latest/1` has yet to read the chat, and will find the message there.
  def receive_created(%{assigns: %{message_window: %__MODULE__{loading?: true}}} = socket, _message, _own?),
    do: {socket, :skipped}

  def receive_created(socket, %Message{} = message, own?) do
    window = socket.assigns.message_window

    cond do
      window.newest != nil and message.position <= window.newest ->
        if loaded?(window, message),
          do: {restream(socket, message), :updated},
          else: {socket, :skipped}

      window.newer? ->
        if own?, do: {load_latest(socket), :reloaded}, else: {socket, :skipped}

      true ->
        window = %{
          window
          | newest: message.position,
            oldest: window.oldest || message.position,
            count: window.count + 1
        }

        socket =
          socket
          |> stream_insert(:messages, message, at: -1)
          |> assign(message_window: window)

        socket = if window.count > @max_loaded, do: trim(socket, :oldest, 1), else: socket
        {socket, :appended}
    end
  end

  @doc "Removes a deleted message's row when it is loaded. The bounds stay put; the invariant still holds."
  def delete(socket, %Message{} = message) do
    window = socket.assigns.message_window

    if loaded?(window, message) do
      socket
      |> stream_delete(:messages, message)
      |> assign(message_window: %{window | count: window.count - 1})
    else
      socket
    end
  end

  @doc """
  Handles a `{:messages_split, _}` broadcast: every position after `position` moved up by `shift`, and
  the new pieces sit right after `position`. Moves the bounds with the rows and reloads the window.
  """
  def receive_split(socket, position, shift) do
    window = socket.assigns.message_window

    if window.oldest == nil or position > window.newest do
      socket
    else
      oldest = if window.oldest > position, do: window.oldest + shift, else: window.oldest
      newest = if window.newest > position or not window.newer?, do: window.newest + shift, else: window.newest
      rows = Messages.list_messages_between(socket.assigns.current_scope, socket.assigns.selected_chat, oldest, newest)

      socket
      |> stream(:messages, rows, reset: true)
      |> assign(message_window: %{window | oldest: oldest, newest: newest, count: length(rows)})
      |> reset_embedding_status(rows)
      |> trim_excess(:oldest)
    end
  end

  @doc "The loaded rows, read back from the DB, oldest first."
  def loaded_messages(%{assigns: %{message_window: %__MODULE__{oldest: nil}}}), do: []

  def loaded_messages(socket) do
    window = socket.assigns.message_window

    Messages.list_messages_between(
      socket.assigns.current_scope,
      socket.assigns.selected_chat,
      window.oldest,
      window.newest
    )
  end

  defp reset_embedding_status(socket, page) do
    %{current_scope: scope, selected_chat: chat} = socket.assigns
    assign(socket, embedding_status: Embeddings.status(scope, chat, active_body_ids(page)))
  end

  # `on?` stays as the last reset read it, so every loaded row agrees on whether icons show.
  defp extend_embedding_status(%{assigns: %{embedding_status: %{on?: true} = status}} = socket, page) do
    case Enum.reject(active_body_ids(page), &MapSet.member?(status.embedded, &1)) do
      [] ->
        socket

      ids ->
        %{embedded: embedded} = Embeddings.status(socket.assigns.current_scope, socket.assigns.selected_chat, ids)
        assign(socket, embedding_status: %{status | embedded: MapSet.union(status.embedded, embedded)})
    end
  end

  defp extend_embedding_status(socket, _page), do: socket

  defp active_body_ids(messages) do
    for message <- messages, %{id: id} <- [Message.active_body(message)], do: id
  end
end
