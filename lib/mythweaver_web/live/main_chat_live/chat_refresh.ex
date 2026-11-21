defmodule MythweaverWeb.MainChatLive.ChatRefresh do
  @moduledoc """
  Re-reads what `MainChatLive` caches of its chats: the picker's lists (`refresh_chats/1`, filtered
  by `assign_visible_chats/1`) and the open chat with its participants' tags (`refresh_selected/2`,
  `assign_participant_tags/1`). The LiveView and every handler module that changes a chat call these.
  """
  import MythweaverWeb.TagFilter, only: [filter_tagged: 3]
  import Phoenix.Component, only: [assign: 2]

  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Tags
  alias Mythweaver.Tags.Graph
  alias MythweaverWeb.Pane

  @doc "Re-reads the picker's chat lists (`chats`, `all_chats`, `shared_chats`) and their visible rows."
  def refresh_chats(socket) do
    scope = socket.assigns.current_scope
    all_chats = Chats.list_chats(scope)

    socket
    |> assign(
      chats: Enum.filter(all_chats, &(&1.kind == :roleplay)),
      all_chats: all_chats,
      shared_chats: Chats.list_member_chats(scope)
    )
    |> assign_visible_chats()
  end

  @doc """
  The picker's rows: chats of every kind, by name, that its name and tag filter keep. `chats` stays
  the full role-play list. Shared chats follow the name filter only: their tags are their owners'.
  """
  def assign_visible_chats(socket) do
    visible = Pane.search(socket.assigns.all_chats, socket.assigns.query, &[Chat.title(&1)])

    assign(socket,
      visible_chats: filter_tagged(socket, visible, :chat),
      visible_shared_chats: Pane.search(socket.assigns.shared_chats, socket.assigns.query, &[Chat.title(&1)])
    )
  end

  @doc """
  Re-reads `chat` when it is the open one. `update_chat/2` returns the struct with `:participants`
  preloaded but nothing else, and the messages column reads `@selected_chat.name` while
  `<.participants>` reads `participant.character.name`, so re-read through `get_chat/1` for the full
  preload.
  """
  def refresh_selected(socket, %{id: id} = _chat) do
    case socket.assigns.selected_chat do
      %{id: ^id} ->
        socket
        |> assign(selected_chat: Chats.get_chat(socket.assigns.current_scope, id))
        |> assign_participant_tags()

      _ ->
        socket
    end
  end

  @doc """
  The open chat's participants' expanded character tags in the viewer's view, which the filter's
  tag chips match. Re-read whenever the chat or its participants change; only a filter with chips
  needs them.
  """
  def assign_participant_tags(
        %{assigns: %{participant_filter: %{predicates: [_ | _]}, selected_chat: %Chat{} = chat}} = socket
      ) do
    viewer = socket.assigns.current_scope.user.id
    graph = socket.assigns.tag_graph
    ids = chat.participants |> Enum.map(& &1.character_id) |> Enum.uniq()
    hard = Tags.tags_by_item(viewer, :character, ids)
    assign(socket, participant_tags: Map.new(ids, &{&1, Graph.expand(graph, Map.get(hard, &1, []))}))
  end

  def assign_participant_tags(socket), do: assign(socket, participant_tags: %{})
end
