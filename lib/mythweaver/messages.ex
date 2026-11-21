defmodule Mythweaver.Messages do
  @moduledoc "The Messages context."

  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Query, warn: false

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Attachments
  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Attachments.Captions
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Lore.Embeddings
  alias Mythweaver.Memory
  alias Mythweaver.Memory.Positions
  alias Mythweaver.Memory.Rollback
  alias Mythweaver.Messages.Cleanup
  alias Mythweaver.Messages.DraftBuffer
  alias Mythweaver.Messages.Message
  alias Mythweaver.Messages.MessageBody
  alias Mythweaver.Messages.PromptSnapshot
  alias Mythweaver.Messages.Scratchpad
  alias Mythweaver.Messages.Segment
  alias Mythweaver.Moderation.Gate
  alias Mythweaver.Notifications
  alias Mythweaver.Repo

  @pubsub Mythweaver.PubSub

  @doc """
  Topic for one chat. Carries `{:message_created, message}`, `{:message_updated, message}`,
  `{:message_deleted, message}`, `{:messages_split, %{chat_id:, message_id:, position:, shift:}}` (every
  transcript position after `position` moved up by `shift`), `{:scratchpads_changed, chat_id}` and
  `{:bodies_embedded, body_ids}` (`Mythweaver.Lore.Embeddings` stored vectors for those bodies), plus
  the typing and generation-progress tuples below.
  """
  def topic(chat_id), do: "chat:#{chat_id}"

  def subscribe(%Chat{} = chat), do: Phoenix.PubSub.subscribe(@pubsub, topic(chat.id))

  @doc """
  One user's chat-activity topic: `{:chat_activity, chat_id, last_activity_at}` (the activity stamp
  of one of their own or member chats moved: see `touch_activity/1`, sent to `Chats.audience/1`) and
  `{:chat_read, chat_id, last_read_at}` (that user's own last-read cursor advanced: `mark_read/2`).
  """
  def activity_topic(user_id), do: "user:#{user_id}:chat_activity"

  def subscribe_activity(%Scope{user: %{id: user_id}}), do: Phoenix.PubSub.subscribe(@pubsub, activity_topic(user_id))

  @doc """
  Announces that `character_id` is composing in `chat` to every *other* subscriber of
  `topic(chat.id)`. The originating process is skipped so the typing tab never shows itself.
  """
  def broadcast_typing(%Chat{} = chat, character_id, character_name) do
    Phoenix.PubSub.broadcast_from(
      @pubsub,
      self(),
      topic(chat.id),
      {:typing, character_id, character_name}
    )
  end

  @doc "Announces that `character_id` stopped composing in `chat`, skipping the caller."
  def broadcast_typing_stopped(%Chat{} = chat, character_id) do
    Phoenix.PubSub.broadcast_from(
      @pubsub,
      self(),
      topic(chat.id),
      {:typing_stopped, character_id}
    )
  end

  @doc """
  Announces streamed generation progress for one body on `topic(chat_id)`.

  `content` and `reasoning` are the full accumulated text, not the delta: a subscriber that joined
  late or dropped a frame renders correctly from any single message, and LiveView diffing makes
  resending the whole string cheaper than reconciling deltas client-side. Both fields ride every
  frame, so a tab that mounted mid-stream from stale DB columns becomes correct from any single frame.
  `reasoning_redacted` is `reasoning` with the build's protected values scrubbed (nil when it
  revealed none); a tab whose scope lacks `site.hidden.view` shows it instead.
  `reasoning_share_redacted` is `reasoning` with only its share-protected values scrubbed (nil when
  there were none); a tab whose scope holds `site.hidden.view` shows it instead.

  Plain `broadcast/3`, not `broadcast_from/4`: unlike typing, the originating tab must also receive
  these, because the generation runs in a GenServer, not in any LiveView.
  """
  def broadcast_body_delta(
        chat_id,
        message_id,
        body_id,
        content,
        reasoning,
        reasoning_redacted \\ nil,
        reasoning_share_redacted \\ nil
      ) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      topic(chat_id),
      {:body_delta,
       %{
         message_id: message_id,
         body_id: body_id,
         content: content,
         reasoning: reasoning,
         reasoning_redacted: reasoning_redacted,
         reasoning_share_redacted: reasoning_share_redacted
       }}
    )
  end

  @doc """
  Announces that a body's generation ended (success or failure) on `topic(chat_id)`, and queues the
  chat's background embedding pass (`Mythweaver.Lore.Embeddings.sync_chat_later/1`).
  """
  def broadcast_generation_finished(chat_id, message_id) do
    Phoenix.PubSub.broadcast(@pubsub, topic(chat_id), {:generation_finished, message_id})
    Embeddings.sync_chat_later(chat_id)
  end

  @doc """
  Announces that a generation in `chat_id` produced no text and was discarded
  (`discard_generation/3`), with the `error` that explains it, as `{:generation_discarded, chat_id,
  error}`. Sent before that generation's `{:generation_finished, _}`.
  """
  def broadcast_generation_discarded(chat_id, error) when is_binary(error),
    do: Phoenix.PubSub.broadcast(@pubsub, topic(chat_id), {:generation_discarded, chat_id, error})

  @doc """
  Announces a new or re-bodied message; subscribers `stream_insert` it. Queues the chat's background
  embedding pass, like `broadcast_generation_finished/2`.
  """
  def broadcast_message_created(chat_id, %Message{} = message) do
    Phoenix.PubSub.broadcast(@pubsub, topic(chat_id), {:message_created, message})
    Embeddings.sync_chat_later(chat_id)
  end

  @doc """
  Announces an edited message (new swipe or visibility change); subscribers `stream_insert` it.
  Queues the chat's background embedding pass, like `broadcast_generation_finished/2`.
  """
  def broadcast_message_updated(chat_id, %Message{} = message) do
    Phoenix.PubSub.broadcast(@pubsub, topic(chat_id), {:message_updated, message})
    Embeddings.sync_chat_later(chat_id)
  end

  @doc "Announces that `Mythweaver.Lore.Embeddings` stored vectors for `body_ids`."
  def broadcast_bodies_embedded(chat_id, body_ids),
    do: Phoenix.PubSub.broadcast(@pubsub, topic(chat_id), {:bodies_embedded, body_ids})

  @doc "Announces a deleted message; subscribers `stream_delete` it."
  def broadcast_message_deleted(chat_id, %Message{} = message),
    do: Phoenix.PubSub.broadcast(@pubsub, topic(chat_id), {:message_deleted, message})

  @doc """
  Announces that splitting the message at `position` moved every later position up by `shift`.
  Subscribers reload their window; see `split_message/4`. Queues the chat's background embedding
  pass (`Mythweaver.Lore.Embeddings.sync_chat_later/1`) for the new pieces.
  """
  def broadcast_messages_split(chat_id, %{position: _, shift: _} = payload) do
    Phoenix.PubSub.broadcast(@pubsub, topic(chat_id), {:messages_split, payload})
    Embeddings.sync_chat_later(chat_id)
  end

  @doc "Announces that the chat's scratchpads changed; subscribers re-list them."
  def broadcast_scratchpads_changed(chat_id),
    do: Phoenix.PubSub.broadcast(@pubsub, topic(chat_id), {:scratchpads_changed, chat_id})

  @doc """
  Records something a reader should notice in `chat_id` (a new message, or tokens a generation
  produced) by moving its `last_activity_at` to now, then broadcasts
  `{:chat_activity, chat_id, last_activity_at}`.

  `GREATEST`, not a plain set: two writers racing must not move the stamp backwards past a cursor a tab
  already advanced to.
  """
  @spec touch_activity(Ecto.UUID.t()) :: :ok
  def touch_activity(chat_id) do
    now = DateTime.utc_now()

    {_, rows} =
      Repo.update_all(
        from(c in Chat,
          where: c.id == ^chat_id,
          select: {c.user_id, c.last_activity_at},
          update: [
            set: [
              last_activity_at: fragment("GREATEST(?, ?)", c.last_activity_at, type(^now, :utc_datetime_usec))
            ]
          ]
        ),
        []
      )

    case rows do
      [{_owner, at}] -> broadcast_activity(Chats.audience(chat_id), {:chat_activity, chat_id, at})
      [] -> :ok
    end
  end

  @doc """
  The scope's own and accepted member chats whose `last_activity_at` is newer than the scope user's own
  read cursor (`Chats.read_cursors_query/1`; nil: never read), as `%{chat_id => last_activity_at}`.

  Read once per page; a tab then patches it from the activity topic's payloads, whose stamps say
  whether a `:chat_read` covers the newest activity it knows of, however the two arrive.
  """
  @spec unread_chats(Scope.t()) :: %{Ecto.UUID.t() => DateTime.t()}
  def unread_chats(%Scope{user: %{id: user_id}}) do
    from(r in subquery(Chats.read_cursors_query(user_id)),
      where: not is_nil(r.last_activity_at) and (is_nil(r.read_at) or r.last_activity_at > r.read_at),
      select: {r.chat_id, r.last_activity_at}
    )
    |> Repo.all()
    |> Map.new()
  end

  def unread_chats(%Scope{}), do: %{}

  @doc """
  Advances the scope user's own last-read cursor in `chat` to its `last_activity_at` (the owner's and
  each member's are apart: `Chats.read_cursors_query/1`) and, when it moved, broadcasts
  `{:chat_read, chat.id, last_read_at}` on that user's activity topic. Never moves the cursor backwards.
  """
  @spec mark_read(Scope.t(), Chat.t()) :: :ok | {:error, :unauthorized}
  def mark_read(%Scope{} = scope, %Chat{} = chat) do
    with :ok <- Chats.authorize(scope, chat, :read), do: do_mark_read(scope, chat)
  end

  # Only the reader's cursor moves, and only the reader's reply items go.
  defp do_mark_read(%Scope{user: %{id: reader_id}}, chat) do
    with %DateTime{} = read_at <- Chats.advance_read_cursor(reader_id, chat.id) do
      broadcast_activity([reader_id], {:chat_read, chat.id, read_at})
      Notifications.clear_chat_replies(reader_id, chat.id)
    end

    :ok
  end

  defp broadcast_activity(user_ids, message),
    do: Enum.each(user_ids, &Phoenix.PubSub.broadcast(@pubsub, activity_topic(&1), message))

  def list_messages(%Chat{} = chat) do
    from(m in transcript_query(chat), order_by: [asc: m.position, asc: m.inserted_at])
    |> Repo.all()
    |> Repo.preload(message_preloads())
  end

  @doc """
  A page of `chat`'s transcript in `list_messages/1` order, and whether more messages lie beyond it in
  the direction paged. Refused: `{[], false}`.

  `opts`: `:limit` (required, positive). `:before`, a position: the newest `limit` messages older than
  it. `:after`, a position: the oldest `limit` messages newer than it. Neither: the newest `limit`
  messages, with `more?` saying whether older ones exist.
  """
  @spec list_messages_page(Scope.t(), Chat.t(), keyword()) :: {[Message.t()], boolean()}
  def list_messages_page(%Scope{} = scope, %Chat{} = chat, opts) do
    if Chats.authorize(scope, chat, :read) == :ok, do: messages_page(chat, opts), else: {[], false}
  end

  @doc "The newest message in `chat`'s transcript written by the player, or `nil` (also when refused)."
  @spec last_player_message(Scope.t(), Chat.t()) :: Message.t() | nil
  def last_player_message(%Scope{} = scope, %Chat{} = chat) do
    if Chats.authorize(scope, chat, :read) == :ok do
      from(m in transcript_query(chat), where: m.author_is_player, order_by: [desc: m.position], limit: 1)
      |> Repo.one()
    end
  end

  defp messages_page(chat, opts) do
    limit = Keyword.fetch!(opts, :limit)
    base = from(m in transcript_query(chat), limit: ^(limit + 1))

    {query, reverse?} =
      case {opts[:before], opts[:after]} do
        {nil, nil} ->
          {from(m in base, order_by: [desc: m.position]), true}

        {before, nil} ->
          {from(m in base, where: m.position < ^before, order_by: [desc: m.position]), true}

        {nil, after_position} ->
          {from(m in base, where: m.position > ^after_position, order_by: [asc: m.position]), false}
      end

    rows = Repo.all(query)
    page = Enum.take(rows, limit)
    page = if reverse?, do: Enum.reverse(page), else: page

    {Repo.preload(page, message_preloads()), length(rows) > limit}
  end

  @doc "Every transcript message whose position is in `first..last`, inclusive, oldest first."
  @spec list_messages_between(Scope.t(), Chat.t(), integer(), integer()) :: [Message.t()]
  def list_messages_between(%Scope{} = scope, %Chat{} = chat, first, last) do
    if Chats.authorize(scope, chat, :read) == :ok, do: messages_between(chat, first, last), else: []
  end

  defp messages_between(chat, first, last) do
    from(m in transcript_query(chat),
      where: m.position >= ^first and m.position <= ^last,
      order_by: [asc: m.position]
    )
    |> Repo.all()
    |> Repo.preload(message_preloads())
  end

  @doc "Transcript messages of `chat` whose active body is among `body_ids`, oldest first."
  @spec list_messages_by_active_body(Scope.t(), Chat.t(), [Ecto.UUID.t()]) :: [Message.t()]
  def list_messages_by_active_body(%Scope{} = scope, %Chat{} = chat, body_ids) when is_list(body_ids) do
    if body_ids != [] and Chats.authorize(scope, chat, :read) == :ok do
      from(m in transcript_query(chat),
        join: b in MessageBody,
        on: b.message_id == m.id and b.active,
        where: b.id in ^body_ids,
        order_by: [asc: m.position]
      )
      |> Repo.all()
      |> Repo.preload(message_preloads())
    else
      []
    end
  end

  @doc """
  Transcript messages of `chat` whose active body or speaker name contains `query`
  (case-insensitive, literal; blank matches all), oldest first, with whether more follow.
  `opts`: `:hidden_only`, `:offset` (default 0), `:limit` (default 50).
  """
  @spec search_messages(Scope.t(), Chat.t(), String.t(), keyword()) :: {[Message.t()], boolean()}
  def search_messages(%Scope{} = scope, %Chat{} = chat, query, opts \\ []) do
    if Chats.authorize(scope, chat, :read) == :ok, do: do_search_messages(chat, query, opts), else: {[], false}
  end

  defp do_search_messages(chat, query, opts) do
    limit = opts[:limit] || 50
    trimmed = String.trim(query || "")

    base =
      from(m in transcript_query(chat),
        join: b in MessageBody,
        on: b.message_id == m.id and b.active,
        left_join: c in assoc(m, :author_character),
        order_by: [asc: m.position],
        offset: ^(opts[:offset] || 0),
        limit: ^(limit + 1)
      )

    base =
      if trimmed == "" do
        base
      else
        pattern = "%" <> String.replace(trimmed, ~r/[\\%_]/, "\\\\\\0") <> "%"
        where(base, [m, b, c], ilike(b.content, ^pattern) or ilike(m.author_name, ^pattern) or ilike(c.name, ^pattern))
      end

    base = if opts[:hidden_only], do: where(base, [m], not m.visible_to_ai), else: base
    rows = Repo.all(base)
    {rows |> Enum.take(limit) |> Repo.preload(message_preloads()), length(rows) > limit}
  end

  @doc """
  Every transcript message of `chat` whose id is in `ids`, whose position is in `positions`, or
  whose position falls in one of the inclusive `{first, last}` `ranges`, oldest first. `ids` must be
  well-formed UUIDs.
  """
  @spec list_targeted(Chat.t(), [Ecto.UUID.t()], [integer()], [{integer(), integer()}]) :: [Message.t()]
  def list_targeted(%Chat{} = chat, ids, positions, ranges) do
    condition =
      Enum.reduce(ranges, dynamic([m], m.id in ^ids or m.position in ^positions), fn {first, last}, acc ->
        dynamic([m], ^acc or (m.position >= ^first and m.position <= ^last))
      end)

    from(m in transcript_query(chat), where: ^condition, order_by: [asc: m.position])
    |> Repo.all()
    |> Repo.preload(message_preloads())
  end

  @doc """
  `{id, position}` of up to `count` transcript messages within `first..last` (inclusive), starting at
  `edge` and moving inward: `:oldest` ascending from `first`, `:newest` descending from `last`.
  """
  @spec window_edge(Scope.t(), Chat.t(), integer(), integer(), :oldest | :newest, pos_integer()) ::
          [{Ecto.UUID.t(), integer()}]
  def window_edge(%Scope{} = scope, %Chat{} = chat, first, last, edge, count) do
    if Chats.authorize(scope, chat, :read) == :ok, do: edge_ids(chat, first, last, edge, count), else: []
  end

  defp edge_ids(chat, first, last, edge, count) do
    order = if edge == :oldest, do: [asc: :position], else: [desc: :position]

    from(m in transcript_query(chat),
      where: m.position >= ^first and m.position <= ^last,
      order_by: ^order,
      limit: ^count,
      select: {m.id, m.position}
    )
    |> Repo.all()
  end

  defp transcript_query(%Chat{} = chat), do: from(m in Message, where: m.chat_id == ^chat.id and m.draft == false)

  @doc "Whether the chat has any non-draft message."
  def has_messages?(%Scope{} = scope, %Chat{} = chat) do
    authorize!(scope, chat, :read)
    Repo.exists?(transcript_query(chat))
  end

  defp authorize!(scope, chat_or_id, action) do
    if Chats.authorize(scope, chat_or_id, action) != :ok, do: raise(Mythweaver.UnauthorizedError)
    :ok
  end

  @doc """
  Returns the chat's draft message (one per chat, whoever the player is), with bodies preloaded, or
  `nil`.
  """
  def get_draft(%Chat{} = chat) do
    from(m in Message, where: m.chat_id == ^chat.id and m.draft == true)
    |> Repo.one()
    |> Repo.preload(bodies: bodies_query())
  end

  @doc """
  `:ok` when the scope may read and write the chat's draft: only its owner, since the chat's one
  draft is the owner's composer (members compose without one). Else `{:error, :unauthorized}`.
  """
  @spec authorize_draft(Scope.t(), Chat.t() | Ecto.UUID.t()) :: :ok | {:error, :unauthorized}
  def authorize_draft(%Scope{} = scope, chat_or_id),
    do: if(Chats.role(scope, chat_or_id) == :owner, do: :ok, else: {:error, :unauthorized})

  @doc """
  Content of the chat's draft, or `\"\"` when there is none. A draft still pending
  in `DraftBuffer` wins over the DB row, so a reload inside the debounce window shows the latest text.
  Raises `Mythweaver.UnauthorizedError` unless the scope is the chat's owner (`authorize_draft/2`).
  """
  def draft_content(%Scope{} = scope, %Chat{} = chat) do
    if authorize_draft(scope, chat) != :ok, do: raise(Mythweaver.UnauthorizedError)

    case DraftBuffer.fetch(chat.id) do
      {:ok, content} -> content
      :error -> draft_text(get_draft(chat))
    end
  end

  defp draft_text(%Message{bodies: [body | _]}), do: body.content
  defp draft_text(nil), do: ""

  @doc """
  Creates, updates, or clears the chat's single draft. A new draft is authored by the chat's current
  player; an existing one keeps its author, since only its text is read. Only the chat's owner
  (`authorize_draft/2`).

  Blank content deletes it and returns `{:ok, nil}`. Drafts carry no `position`
  and are excluded from `list_messages/1`, so they are never rendered in the transcript.
  """
  def upsert_draft(%Scope{} = scope, %Chat{} = chat, content) do
    with :ok <- authorize_draft(scope, chat), do: write_draft(chat, content)
  end

  defp write_draft(chat, content) do
    trimmed = String.trim(content)

    case {get_draft(chat), trimmed} do
      {nil, ""} ->
        {:ok, nil}

      {%Message{} = draft, ""} ->
        {:ok, _} = Repo.delete(draft)
        {:ok, nil}

      {nil, text} ->
        %Message{
          chat_id: chat.id,
          position: nil,
          draft: true,
          author_is_character: true,
          author_character_id: chat.player_character_id
        }
        |> Message.create_changeset(%{
          author_is_character: true,
          author_character_id: chat.player_character_id,
          bodies: [%{content: text}]
        })
        |> Message.put_author_is_player(chat)
        |> Repo.insert()

      {%Message{} = draft, text} ->
        draft.bodies
        |> List.first()
        |> Ecto.Changeset.change(content: text)
        |> Repo.update()
    end
  end

  @doc """
  Sends `content` as a message stamped with the scope's user (`author_user_id`), clearing the chat's
  draft when its owner sends (the draft is the owner's), broadcasts `{:message_created, message}` on
  `topic(chat.id)`, and `touch_activity/1`s the chat. Needs `:post`, and `:attach` with attachments.

  When the scope's user holds characters in the chat (`Chats.locks_of/2`), the author is
  `character_id` if it is one of them, else their first held character in speaking order. Holding
  none, only the chat's owner may post, as `character_id` (the player, from the composer); a member
  gets `{:error, :no_character}`.

  `opts[:attachments]` (`:ready` `Mythweaver.Attachments.Attachment`s) are linked to the message in
  the same transaction; with any, blank text is legal (an image-only message). Their captions spend
  the sender's `Chats.spend_scope/2` models; the expression classification runs as the chat's owner
  (`Chats.run_scope/2`).

  Returns `{:error, :empty}` for blank content and no attachments without touching the database.
  """
  @spec send_message(Scope.t(), Chat.t(), Ecto.UUID.t() | nil, String.t(), keyword()) ::
          {:ok, Message.t()} | {:error, :unauthorized | :no_character | :empty | Ecto.Changeset.t()}
  def send_message(%Scope{} = scope, %Chat{} = chat, character_id, content, opts \\ []) do
    with :ok <- Chats.authorize(scope, chat, :post),
         :ok <- if(Keyword.get(opts, :attachments, []) == [], do: :ok, else: Chats.authorize(scope, chat, :attach)),
         {:ok, author_id} <- posting_character(scope, chat, character_id),
         do: do_send_message(scope, chat, author_id, content, opts)
  end

  defp posting_character(scope, chat, character_id) do
    case Chats.locks_of(scope, chat) do
      [] -> if Chats.role(scope, chat) == :owner, do: {:ok, character_id}, else: {:error, :no_character}
      held -> if character_id in held, do: {:ok, character_id}, else: {:ok, hd(held)}
    end
  end

  defp do_send_message(scope, chat, character_id, content, opts) do
    attachments = Keyword.get(opts, :attachments, [])

    case {String.trim(content), attachments} do
      {"", []} ->
        {:error, :empty}

      {text, _} ->
        author_user_id = scope.user && scope.user.id
        # The chat's single draft is its owner's composer: a member's send leaves it alone.
        owner? = author_user_id != nil and author_user_id == chat.user_id
        # Before the transaction: discarding after it would let an already-queued timer write the
        # draft back after it had been deleted.
        if owner?, do: :ok = DraftBuffer.discard(scope, chat.id)
        changeset = if attachments == [], do: &Message.create_changeset/2, else: &Message.attached_changeset/2
        stamped = fn message, attrs -> changeset.(%{message | author_user_id: author_user_id}, attrs) end

        result =
          Repo.transaction(fn ->
            draft = owner? && get_draft(chat)
            if draft, do: Repo.delete!(draft)

            message =
              chat
              |> create_message(
                %{author_is_character: true, author_character_id: character_id, bodies: [%{content: text}]},
                stamped
              )
              |> Repo.ok_or_rollback()

            Attachments.link_message!(message, attachments)
            fetch_message!(message.id)
          end)

        with {:ok, message} <- result, {:ok, message} <- publish_created(scope, chat, message) do
          if attachments != [], do: Captions.request_for_message(scope, chat, message)

          Mythweaver.Expressions.classify_later(
            Chats.run_scope(scope, chat),
            chat.id,
            message.id,
            Message.active_body(message).id
          )

          :ok = Gate.scan_message(scope, message, Message.active_content(message))
          {:ok, message}
        end
    end
  end

  @doc """
  Attaches stored images to an existing message of `chat` (an AI-generated image, made with
  `Mythweaver.Attachments.store_binary/2` and `source: :generated`), rebroadcasts the message, and
  queues their captions (`Captions.request_for_message/2`, where generated images fall back to the
  site default caption model).
  """
  @spec attach_images(Scope.t(), Chat.t(), Message.t(), [Attachment.t()]) ::
          {:ok, Message.t()} | {:error, :unauthorized}
  def attach_images(
        %Scope{} = scope,
        %Chat{id: chat_id} = chat,
        %Message{chat_id: chat_id} = message,
        [_ | _] = attachments
      ) do
    with :ok <- Chats.authorize(scope, chat, :attach) do
      {:ok, :ok} = Repo.transaction(fn -> Attachments.link_message!(message, attachments) end)
      {:ok, message} = publish_updated(message)
      :ok = Captions.request_for_message(scope, chat, message)
      {:ok, message}
    end
  end

  @doc """
  Makes `attachments` the message's attachments (every swipe shares them): links the new ones,
  unlinks the rest and deletes those no owner links any more, rebroadcasts the message, and
  queues captions for added images (`Captions.request_for_message/3`).
  """
  @spec set_attachments(Scope.t(), Chat.t(), Message.t(), [Attachment.t()]) ::
          {:ok, Message.t()} | {:error, :unauthorized}
  def set_attachments(%Scope{} = scope, %Chat{id: chat_id} = chat, %Message{chat_id: chat_id} = message, attachments) do
    with :ok <- Chats.authorize(scope, chat, {:edit_message, message}),
         :ok <- Chats.authorize(scope, chat, :attach) do
      current = Attachments.message_attachment_ids(message.id)
      add = for %Attachment{status: :ready} = a <- attachments, a.id not in current, do: a
      remove = current -- Enum.map(attachments, & &1.id)

      {:ok, :ok} =
        Repo.transaction(fn ->
          Attachments.link_message!(message, add)
          Attachments.unlink_message!(message, remove)
        end)

      :ok = Attachments.delete_orphaned(remove)
      {:ok, message} = publish_updated(message)
      if add != [], do: Captions.request_for_message(scope, chat, message)
      {:ok, message}
    end
  end

  @doc """
  Posts like `send_message/4` but leaves drafts alone; the Lua script API's create. A script posting
  as the player must not wipe the player's composer draft. `author` is a character
  (`{:character, id}`) or, as `reattribute_message/3` takes it, a name with no character
  (`{:name, name}`, trimmed). Membership is the caller's check.
  """
  @spec post_message(Scope.t(), Chat.t(), {:character, Ecto.UUID.t()} | {:name, String.t()}, String.t()) ::
          {:ok, Message.t()} | {:error, :empty | :unauthorized | Ecto.Changeset.t()}
  def post_message(%Scope{} = scope, %Chat{} = chat, author, content) do
    with :ok <- Chats.authorize(scope, chat, :post) do
      case String.trim(content) do
        "" ->
          {:error, :empty}

        text ->
          with {:ok, message} <- create_message(chat, Map.put(post_author(author), :bodies, [%{content: text}])) do
            publish_created(scope, chat, fetch_message!(message.id))
          end
      end
    end
  end

  @doc """
  Posts a new chat's greeting (`Mythweaver.Greetings`): one message by `author` (as `post_message/4`
  takes it) whose swipes are `texts` in order, `active` the shown one. A character greeting is
  classified like a sent message.
  """
  @spec post_greeting(
          Scope.t(),
          Chat.t(),
          {:character, Ecto.UUID.t()} | {:name, String.t()},
          [String.t(), ...],
          non_neg_integer()
        ) :: {:ok, Message.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def post_greeting(%Scope{} = scope, %Chat{} = chat, author, [_ | _] = texts, active) do
    with :ok <- Chats.authorize(scope, chat, :post) do
      # Swipes keep insert order: ids are monotonic v7 and `bodies_query/0` sorts by them.
      bodies = Enum.with_index(texts, fn text, i -> %{content: text, active: i == active} end)
      attrs = Map.put(post_author(author), :bodies, bodies)

      with {:ok, message} <- create_message(chat, attrs, &Message.greeting_changeset/2),
           {:ok, message} <- publish_created(scope, chat, fetch_message!(message.id)) do
        if match?({:character, _}, author),
          do:
            Mythweaver.Expressions.classify_later(
              Chats.run_scope(scope, chat),
              chat.id,
              message.id,
              Message.active_body(message).id
            )

        {:ok, message}
      end
    end
  end

  defp post_author({:character, id}), do: %{author_is_character: true, author_character_id: id}

  defp post_author({:name, name}) when is_binary(name),
    do: %{author_is_character: false, author_name: String.trim(name)}

  defp publish_created(scope, chat, message) do
    broadcast_message_created(chat.id, message)
    touch_activity(chat.id)
    Cleanup.check_later(chat.id)
    Memory.Auto.check(scope, chat.id)
    {:ok, message}
  end

  @doc """
  Posts the user's message in an assistant chat. Unlike `post_message/4` it runs no memory check:
  an assistant chat has no memory. `attachments` (`:ready` attachments) are linked to it in the
  same transaction, as `send_message/5` does, and with any the text may be blank; their captions
  are queued (`Captions.request_for_message/3`).
  """
  @spec post_assistant_user_message(Scope.t(), Chat.t(), String.t(), [Attachment.t()]) ::
          {:ok, Message.t()} | {:error, :empty | :unauthorized | Ecto.Changeset.t()}
  def post_assistant_user_message(%Scope{} = scope, %Chat{kind: :assistant} = chat, content, attachments \\ []) do
    with :ok <- Chats.authorize(scope, chat, :post) do
      case {String.trim(content), attachments} do
        {"", []} ->
          {:error, :empty}

        {text, _} ->
          changeset = if attachments == [], do: &Message.create_changeset/2, else: &Message.attached_changeset/2
          attrs = %{author_is_character: false, author_name: "You", bodies: [%{content: text}]}

          result =
            Repo.transaction(fn ->
              message = chat |> create_message(attrs, changeset) |> Repo.ok_or_rollback()
              Attachments.link_message!(message, attachments)
              fetch_message!(message.id)
            end)

          with {:ok, message} <- result do
            broadcast_message_created(chat.id, message)
            touch_activity(chat.id)
            if attachments != [], do: Captions.request_for_message(scope, chat, message)
            {:ok, message}
          end
      end
    end
  end

  @doc "The message when the scope may act on its chat; raises `Ecto.NoResultsError` or `Mythweaver.UnauthorizedError`."
  @spec get_message!(Scope.t(), Ecto.UUID.t()) :: Message.t()
  def get_message!(%Scope{} = scope, id) do
    message = fetch_message!(id)
    authorize!(scope, message.chat_id, :read)
    message
  end

  @doc "The message when it exists and the scope may act on its chat, else nil."
  @spec get_message(Scope.t(), Ecto.UUID.t()) :: Message.t() | nil
  def get_message(%Scope{} = scope, id) do
    message = fetch_message(id)
    if message && Chats.authorize(scope, message.chat_id, :read) == :ok, do: message
  end

  @doc """
  The messages among `ids` that exist and whose chat the scope may act on (`get_message/2`'s check),
  with the same preloads: one query for the rows, not one per id. Unknown, malformed and other users'
  ids are skipped. Ordered by position then id, not by `ids`; ids of several chats may mix.
  """
  @spec get_messages(Scope.t(), [Ecto.UUID.t()]) :: [Message.t()]
  def get_messages(%Scope{user: %{id: user_id}}, ids) when is_binary(user_id) and is_list(ids) do
    case for(id <- ids, {:ok, id} <- [Ecto.UUID.cast(id)], do: id) do
      [] ->
        []

      ids ->
        from(m in Message,
          join: c in Chat,
          on: c.id == m.chat_id,
          where: m.id in ^ids and c.user_id == ^user_id,
          order_by: [asc: m.position, asc: m.id]
        )
        |> Repo.all()
        |> Repo.preload(message_preloads())
    end
  end

  def get_messages(%Scope{}, ids) when is_list(ids), do: []

  defp fetch_message!(id), do: Message |> Repo.get!(id) |> Repo.preload(message_preloads())

  defp fetch_message(id), do: Message |> Repo.get(id) |> Repo.preload(message_preloads())

  # Reloads `message` with its preloads and announces it on its chat's topic.
  defp publish_updated(%Message{id: id}) do
    message = fetch_message!(id)
    broadcast_message_updated(message.chat_id, message)
    {:ok, message}
  end

  defp generating?(%Message{bodies: bodies}), do: Enum.any?(bodies, & &1.generating)

  @doc """
  Sets `visible_to_ai` on `chat`'s messages `ids` in one update (ids of other chats are ignored), then
  broadcasts `{:message_updated, m}` for each one that changed. Returns the changed messages.
  """
  @spec set_visible_many(Chat.t(), [Ecto.UUID.t()], boolean()) :: [Message.t()]
  def set_visible_many(%Chat{}, [], _visible?), do: []

  def set_visible_many(%Chat{} = chat, ids, visible?) when is_list(ids) and is_boolean(visible?) do
    {_count, changed} =
      Repo.update_all(
        from(m in Message,
          where: m.chat_id == ^chat.id and m.id in ^ids and m.visible_to_ai != ^visible?,
          select: m.id
        ),
        set: [visible_to_ai: visible?, updated_at: DateTime.utc_now()]
      )

    messages =
      from(m in Message, where: m.id in ^changed, order_by: [asc: m.position])
      |> Repo.all()
      |> Repo.preload(message_preloads())

    Enum.each(messages, &broadcast_message_updated(&1.chat_id, &1))
    messages
  end

  # The snapshot preload selects only ids, so the transcript knows which swipes can be inspected
  # without loading their payloads.
  defp bodies_query do
    from(b in MessageBody,
      order_by: [asc: b.inserted_at, asc: b.id],
      preload: [
        prompt_snapshot: ^from(s in PromptSnapshot, select: struct(s, [:id, :message_body_id])),
        guide_attachments: [],
        expression_sprite: :attachment
      ]
    )
  end

  defp message_preloads, do: [author_character: :avatar, bodies: bodies_query(), attachments: []]

  @doc "Records what a generation is about to send for `body`. Maps are stored with string keys."
  def create_prompt_snapshot(%MessageBody{} = body, attrs) do
    %PromptSnapshot{message_body_id: body.id}
    |> PromptSnapshot.create_changeset(normalize(attrs))
    |> Repo.insert()
  end

  @doc """
  Stores the exact request body the adapter sent, with image data URLs reduced to a byte count
  (`Mythweaver.Attachments.scrub_data_urls/1`).
  """
  def put_snapshot_request(%PromptSnapshot{} = snapshot, request) do
    request = Attachments.scrub_data_urls(request)
    snapshot |> PromptSnapshot.update_changeset(%{request: normalize(request)}) |> Repo.update()
  end

  @doc "Stores the assembled response, or the failure."
  def put_snapshot_response(%PromptSnapshot{} = snapshot, response) do
    snapshot |> PromptSnapshot.update_changeset(%{response: normalize(response)}) |> Repo.update()
  end

  @doc "The full, unredacted snapshot for a body, or `nil` (also when the scope may not inspect its chat)."
  @spec get_prompt_snapshot(Scope.t(), Ecto.UUID.t()) :: PromptSnapshot.t() | nil
  def get_prompt_snapshot(%Scope{} = scope, body_id) do
    chat_id =
      Repo.one(
        from(b in MessageBody, join: m in Message, on: m.id == b.message_id, where: b.id == ^body_id, select: m.chat_id)
      )

    if chat_id && Chats.authorize(scope, chat_id, :inspect) == :ok,
      do: Repo.get_by(PromptSnapshot, message_body_id: body_id)
  end

  # Round-trips through JSON so atom keys and values come back exactly as the database returns them.
  defp normalize(map), do: map |> Jason.encode!() |> Jason.decode!()

  def create_message(%Chat{} = chat, attrs \\ %{}, changeset \\ &Message.create_changeset/2) do
    Repo.transaction(fn ->
      lock_chat!(chat)

      %Message{chat_id: chat.id, position: next_position(chat)}
      |> changeset.(attrs)
      |> Message.put_author_is_player(chat)
      |> Repo.insert()
      |> Repo.ok_or_rollback()
    end)
  end

  # Serialises inserts per chat, so two writers cannot both read the same `max(position)`.
  defp lock_chat!(%Chat{id: id}), do: Repo.one!(from c in Chat, where: c.id == ^id, select: c.id, lock: "FOR UPDATE")

  defp next_position(%Chat{} = chat) do
    Repo.one(from m in Message, where: m.chat_id == ^chat.id, select: coalesce(max(m.position), -1)) + 1
  end

  @doc """
  Appends an already-rendered transcript (an import) to `chat` in bulk, after any existing messages.

  Each entry is one message with its swipes in order; `active` indexes the active body. Rows are
  written with `Repo.insert_all/3`, so every column is explicit; ids are generated in order so they
  stay monotonic, and `inserted_at` is the entry's time. No per-message broadcast: callers import
  into a fresh chat. `touch_activity/1`s the chat afterwards.

  An entry may carry `attachments` (`:ready` attachments linked to the message) and each body may
  carry `origin`, `guide`, `finish_reason`, token counts, `cost`, `cost_estimated`, `generation_ms`,
  `error`, `inserted_at` and `attachments` (images linked to the body); missing ones keep the
  defaults (`origin: :original`, the entry's time).
  """
  @spec import_transcript(Chat.t(), [
          %{
            required(:author_character_id) => Ecto.UUID.t() | nil,
            required(:author_name) => String.t() | nil,
            required(:visible_to_ai) => boolean(),
            required(:inserted_at) => DateTime.t(),
            required(:bodies) => [map()],
            required(:active) => non_neg_integer(),
            optional(:attachments) => [Attachment.t()]
          }
        ]) :: :ok
  def import_transcript(%Chat{} = chat, entries) do
    {:ok, :ok} =
      Repo.transaction(fn ->
        lock_chat!(chat)
        start = next_position(chat)

        rows =
          entries
          |> Enum.with_index(start)
          |> Enum.map(fn {entry, position} -> transcript_rows(chat, entry, position) end)

        messages = Enum.map(rows, &elem(&1, 0))
        bodies = Enum.flat_map(rows, &elem(&1, 1))

        messages |> Enum.chunk_every(500) |> Enum.each(&Repo.insert_all(Message, &1))

        bodies
        |> Enum.map(&Map.delete(&1, :attachments))
        |> Enum.chunk_every(1000)
        |> Enum.each(&Repo.insert_all(MessageBody, &1))

        for {message, body_rows, attachments} <- rows do
          if attachments != [], do: Attachments.link_message!(%Message{id: message.id}, attachments)
          for body <- body_rows, do: Attachments.link_body!(%MessageBody{id: body.id}, body.attachments)
        end

        :ok
      end)

    touch_activity(chat.id)
    :ok
  end

  defp transcript_rows(chat, entry, position) do
    id = Mythweaver.Schema.generate_id()
    at = entry.inserted_at
    author = entry.author_character_id

    message = %{
      id: id,
      chat_id: chat.id,
      position: position,
      draft: false,
      author_is_character: not is_nil(author),
      author_character_id: author,
      author_name: entry.author_name,
      visible_to_ai: entry.visible_to_ai,
      author_is_player: author != nil and author == chat.player_character_id,
      inserted_at: at,
      updated_at: at
    }

    bodies =
      Enum.with_index(entry.bodies, fn body, index ->
        body_at = body[:inserted_at] || at

        %{
          id: Mythweaver.Schema.generate_id(),
          message_id: id,
          content: body.content || "",
          reasoning: body[:reasoning],
          active: index == entry.active,
          generating: false,
          cost_estimated: body[:cost_estimated] || false,
          origin: body[:origin] || :original,
          guide: body[:guide],
          finish_reason: body[:finish_reason],
          prompt_tokens: body[:prompt_tokens],
          completion_tokens: body[:completion_tokens],
          total_tokens: body[:total_tokens],
          cost: body[:cost],
          generation_ms: body[:generation_ms],
          error: body[:error],
          inserted_at: body_at,
          updated_at: body_at,
          attachments: body[:attachments] || []
        }
      end)

    {message, bodies, entry[:attachments] || []}
  end

  def update_message(%Message{} = message, attrs) do
    message
    |> Message.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Hides `message` from (or shows it to) the AI (`Prompts.Transcript` and lore scanning skip hidden
  messages) and broadcasts `{:message_updated, message}` (reloaded, bodies preloaded).
  """
  def set_visible_to_ai(%Scope{} = scope, %Message{} = message, visible?) when is_boolean(visible?) do
    with :ok <- Chats.authorize(scope, message.chat_id, {:edit_message, message}),
         {:ok, _} <- update_message(message, %{visible_to_ai: visible?}),
         do: publish_updated(message)
  end

  @doc """
  Changes `message`'s author without adding a swipe; broadcasts `{:message_updated, message}`. Every
  swipe's expression is cleared, so no sprite shows on another character's message, and the active
  swipe is classified again for the new author (`Mythweaver.Expressions.classify_later/5`).
  """
  @spec reattribute_message(Scope.t(), Chat.t(), Message.t(), {:character, Ecto.UUID.t()} | {:name, String.t()}) ::
          {:ok, Message.t()} | {:error, :generating | :not_participant | :unauthorized | Ecto.Changeset.t()}
  def reattribute_message(%Scope{} = scope, %Chat{} = chat, %Message{} = message, author) do
    with :ok <- Chats.authorize(scope, chat, :manage),
         :ok <- check_not_generating(message),
         {:ok, attrs} <- reattribute_attrs(chat, author),
         {:ok, _} <- message |> Message.reattribute_changeset(attrs) |> Repo.update() do
      Repo.update_all(from(b in MessageBody, where: b.message_id == ^message.id),
        set: [expression: nil, expression_scores: nil, expression_source: nil, expression_sprite_id: nil]
      )

      with {:ok, message} <- publish_updated(message) do
        if body = Message.active_body(message),
          do: Mythweaver.Expressions.classify_later(scope, chat.id, message.id, body.id)

        {:ok, message}
      end
    end
  end

  defp check_not_generating(message), do: if(generating?(message), do: {:error, :generating}, else: :ok)

  defp reattribute_attrs(%Chat{participants: participants}, {:character, id}) do
    if Enum.any?(participants, &(&1.character_id == id)) do
      {:ok, %{author_is_character: true, author_character_id: id, author_name: nil}}
    else
      {:error, :not_participant}
    end
  end

  defp reattribute_attrs(_chat, {:name, name}) when is_binary(name) do
    {:ok, %{author_is_character: false, author_character_id: nil, author_name: String.trim(name)}}
  end

  @doc """
  Deletes the message; its bodies (swipes) and attachment links go with it via the FK cascade, and
  attachments no other owner links are deleted after. Runs memory auto-rollback
  (`Mythweaver.Memory.Rollback.message_deleted/2`), then broadcasts `{:message_deleted, message}`.
  """
  def delete_message(%Scope{} = scope, %Message{} = message) do
    with :ok <- Chats.authorize(scope, message.chat_id, {:delete_message, message}) do
      attachment_ids = Attachments.message_attachment_ids(message.id)

      with {:ok, deleted} <- Repo.delete(message) do
        Attachments.delete_orphaned(attachment_ids)
        :ok = Rollback.message_deleted(scope, deleted)
        broadcast_message_deleted(deleted.chat_id, deleted)
        {:ok, deleted}
      end
    end
  end

  @type divider :: %{boundary: pos_integer(), author_id: Ecto.UUID.t() | :scratchpad | nil}

  @doc """
  Splits `message` at paragraph boundaries (`Mythweaver.Messages.Segment.paragraphs/1`) into one
  message (or scratchpad) per region.

  `content` is the active text the caller planned against; `splits` are the dividers, each a boundary
  (a paragraph index in `1..n-1`) and an optional author for the piece that starts there: nil keeps
  `message`'s author, and `:scratchpad` cuts the piece into a `Mythweaver.Messages.Scratchpad` of
  `message` instead of a message. The first region becomes a new active `:split` swipe of `message`;
  the message pieces are inserted right after it, in order, and every later message, along with every
  position memory stored (see `Mythweaver.Memory.Positions`), moves up to make room. Templates and
  scripts do not run: the text was rendered when it was stored.

  Broadcasts `{:messages_split, _}` when any message piece was inserted (else `{:message_updated, _}`),
  plus `{:scratchpads_changed, _}` when any scratchpad was made, and returns the reloaded `message`.
  """
  @spec split_message(Scope.t(), Chat.t(), Message.t(), String.t(), [divider()]) ::
          {:ok, Message.t()} | {:error, :stale | :generating | :invalid_split | :unauthorized}
  def split_message(%Scope{} = scope, %Chat{} = chat, %Message{} = message, content, splits)
      when is_binary(content) and is_list(splits) do
    with :ok <- Chats.authorize(scope, chat, {:edit_message, message}),
         do: do_split_message(scope, chat, message, content, splits)
  end

  defp do_split_message(scope, chat, message, content, splits) do
    result =
      Repo.transaction(fn ->
        lock_chat!(chat)
        chat = Repo.preload(chat, :participants, force: true)

        with {:ok, message} <- reload_for_split(chat, message, content),
             {:ok, [head | tail], authors} <- split_regions(chat, content, splits) do
          {pads, pieces} = tail |> Enum.zip(authors) |> Enum.split_with(&match?({_, :scratchpad}, &1))
          p = message.position
          d = length(pieces)

          if d > 0 do
            shift_positions!(chat, p, d)
            :ok = Positions.shift!(chat.id, p, d)
          end

          {:ok, _} = add_body(message, %{content: head}, :split)

          pieces
          |> Enum.with_index(1)
          |> Enum.each(fn {{region, author_id}, i} -> insert_piece!(chat, message, p + i, region, author_id) end)

          Enum.each(pads, fn {region, :scratchpad} ->
            %Scratchpad{chat_id: chat.id, message_id: message.id}
            |> Scratchpad.changeset(%{content: region})
            |> Repo.insert!()
          end)

          {message, d, pads != []}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    with {:ok, {message, d, pads?}} <- result do
      if d > 0 do
        Rollback.cancel_jobs(scope, chat.id, message.position)

        broadcast_messages_split(chat.id, %{
          chat_id: chat.id,
          message_id: message.id,
          position: message.position,
          shift: d
        })

        Memory.broadcast_changed(chat.id)
      end

      message = fetch_message!(message.id)
      if d == 0, do: broadcast_message_updated(chat.id, message)
      if pads?, do: broadcast_scratchpads_changed(chat.id)
      {:ok, message}
    end
  end

  # The message as it is now, refused when a body is generating or its text is not what was planned on.
  defp reload_for_split(%Chat{id: chat_id}, %Message{id: id}, content) do
    case fetch_message(id) do
      %Message{chat_id: ^chat_id, draft: false} = message ->
        cond do
          generating?(message) -> {:error, :generating}
          Message.active_content(message) != content -> {:error, :stale}
          true -> {:ok, message}
        end

      _gone ->
        {:error, :stale}
    end
  end

  defp split_regions(chat, content, splits) do
    segments = Segment.paragraphs(content)
    n = length(segments)
    splits = Enum.sort_by(splits, & &1.boundary)
    bounds = Enum.map(splits, & &1.boundary)
    authors = Enum.map(splits, & &1.author_id)
    character_ids = MapSet.new(chat.participants, & &1.character_id)

    valid? =
      splits != [] and bounds == Enum.uniq(bounds) and
        Enum.all?(bounds, &(is_integer(&1) and &1 >= 1 and &1 <= n - 1)) and
        Enum.all?(authors, &(is_nil(&1) or &1 == :scratchpad or MapSet.member?(character_ids, &1)))

    if valid? do
      regions =
        ([0 | bounds] ++ [n])
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [from, to] -> segments |> Enum.slice(from, to - from) |> Segment.join() end)

      {:ok, regions, authors}
    else
      {:error, :invalid_split}
    end
  end

  # Two passes through negative positions: a single `+ shift` UPDATE collides on the
  # `(chat_id, position)` unique index (as in `Prompts.restage_positions!/1`).
  defp shift_positions!(%Chat{} = chat, position, shift) do
    Repo.update_all(
      from(m in transcript_query(chat),
        where: m.position > ^position,
        update: [set: [position: fragment("-1 - ? - ?", m.position, ^shift)]]
      ),
      []
    )

    Repo.update_all(
      from(m in transcript_query(chat),
        where: m.position < 0,
        update: [set: [position: fragment("-1 - ?", m.position)]]
      ),
      []
    )
  end

  defp insert_piece!(chat, %Message{} = source, position, content, author_id) do
    base = %{visible_to_ai: source.visible_to_ai, bodies: [%{content: content}]}

    changeset =
      case author_id do
        nil ->
          %Message{chat_id: chat.id, position: position}
          |> Message.create_changeset(
            Map.merge(base, %{
              author_is_character: source.author_is_character,
              author_character_id: source.author_character_id,
              author_name: source.author_name
            })
          )
          |> Ecto.Changeset.put_change(:author_is_player, source.author_is_player)

        id ->
          %Message{chat_id: chat.id, position: position}
          |> Message.create_changeset(Map.merge(base, %{author_is_character: true, author_character_id: id}))
          |> Message.put_author_is_player(chat)
      end

    changeset |> Ecto.Changeset.put_change(:inserted_at, source.inserted_at) |> Repo.insert!()
  end

  @doc """
  Merges the transcript messages `ids`, a contiguous run, into the first of them: its new active
  `:merge` swipe joins every active text (`Segment.join/1`), and the rest are deleted. Memory rollback
  does not run, since the text moved rather than vanished; queued memory jobs from the first position
  on are cancelled.
  """
  @spec merge_messages(Scope.t(), Chat.t(), [Ecto.UUID.t()]) ::
          {:ok, Message.t()} | {:error, :not_found | :too_few | :not_contiguous | :generating | :unauthorized}
  def merge_messages(%Scope{} = scope, %Chat{} = chat, ids) when is_list(ids) do
    with :ok <- Chats.authorize(scope, chat, :manage), do: do_merge_messages(scope, chat, Enum.uniq(ids))
  end

  defp do_merge_messages(scope, chat, ids) do
    result =
      Repo.transaction(fn ->
        lock_chat!(chat)

        messages =
          from(m in transcript_query(chat), where: m.id in ^ids, order_by: [asc: m.position])
          |> Repo.all()
          |> Repo.preload(message_preloads())

        case check_mergeable(chat, ids, messages) do
          :ok ->
            [first | rest] = messages
            content = messages |> Enum.map(&Message.active_content/1) |> Segment.join()
            {:ok, _} = add_body(first, %{content: content}, :merge)
            Attachments.move_message_links(Enum.map(rest, & &1.id), first.id)
            Enum.each(rest, &Repo.delete!/1)
            {first, rest}

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    with {:ok, {first, rest}} <- result do
      Rollback.cancel_jobs(scope, chat.id, first.position)
      Enum.each(rest, &broadcast_message_deleted(chat.id, &1))
      publish_updated(first)
    end
  end

  defp check_mergeable(chat, ids, messages) do
    count = length(messages)

    cond do
      count != length(ids) ->
        {:error, :not_found}

      count < 2 ->
        {:error, :too_few}

      Repo.aggregate(
        from(m in transcript_query(chat),
          where: m.position >= ^hd(messages).position and m.position <= ^List.last(messages).position
        ),
        :count
      ) != count ->
        {:error, :not_contiguous}

      Enum.any?(messages, &generating?/1) ->
        {:error, :generating}

      true ->
        :ok
    end
  end

  @doc "Merges `message` into the transcript message right before it; see `merge_messages/3`."
  @spec merge_into_previous(Scope.t(), Chat.t(), Message.t()) ::
          {:ok, Message.t()}
          | {:error, :no_previous | :not_found | :too_few | :not_contiguous | :generating | :unauthorized}
  def merge_into_previous(%Scope{} = scope, %Chat{} = chat, %Message{} = message) do
    with :ok <- Chats.authorize(scope, chat, :manage), do: merge_with_previous(scope, chat, message)
  end

  defp merge_with_previous(scope, chat, message) do
    previous =
      from(m in transcript_query(chat),
        where: m.position < ^message.position,
        order_by: [desc: m.position],
        limit: 1,
        select: m.id
      )
      |> Repo.one()

    case previous do
      nil -> {:error, :no_previous}
      id -> do_merge_messages(scope, chat, [id, message.id])
    end
  end

  @doc "The chat's scratchpads, oldest first, with `message: :author_character` preloaded."
  @spec list_scratchpads(Scope.t(), Chat.t()) :: [Scratchpad.t()]
  def list_scratchpads(%Scope{} = scope, %Chat{} = chat) do
    if Chats.authorize(scope, chat, :manage) == :ok do
      from(s in Scratchpad, where: s.chat_id == ^chat.id, order_by: [asc: s.inserted_at, asc: s.id])
      |> Repo.all()
      |> Repo.preload(message: :author_character)
    else
      []
    end
  end

  @doc "One scratchpad with `message: :author_character` preloaded, or nil (also when the scope may not act on its chat)."
  @spec get_scratchpad(Scope.t(), Ecto.UUID.t()) :: Scratchpad.t() | nil
  def get_scratchpad(%Scope{} = scope, id) do
    with %Scratchpad{} = scratchpad <- Repo.get(Scratchpad, id),
         :ok <- Chats.authorize(scope, scratchpad.chat_id, :manage) do
      Repo.preload(scratchpad, message: :author_character)
    else
      _ -> nil
    end
  end

  @doc """
  Cuts the chat's newest message at paragraph `boundary`: the head becomes its new active `:split`
  swipe and the tail a `Mythweaver.Messages.Scratchpad`. No position moves. Returns the reloaded
  message.
  """
  @spec split_to_scratchpad(Scope.t(), Chat.t(), Message.t(), String.t(), pos_integer()) ::
          {:ok, Message.t()} | {:error, :stale | :generating | :not_last | :invalid_split | :unauthorized}
  def split_to_scratchpad(%Scope{} = scope, %Chat{} = chat, %Message{} = message, content, boundary)
      when is_binary(content) do
    with :ok <- Chats.authorize(scope, chat, :manage), do: do_split_to_scratchpad(chat, message, content, boundary)
  end

  defp do_split_to_scratchpad(chat, message, content, boundary) do
    segments = Segment.paragraphs(content)

    result =
      Repo.transaction(fn ->
        lock_chat!(chat)

        with {:ok, message} <- reload_for_split(chat, message, content),
             true <- newest?(message) || {:error, :not_last},
             true <- (is_integer(boundary) and boundary in 1..(length(segments) - 1)//1) || {:error, :invalid_split} do
          {head, tail} = Enum.split(segments, boundary)
          {:ok, _} = add_body(message, %{content: Segment.join(head)}, :split)

          %Scratchpad{chat_id: chat.id, message_id: message.id}
          |> Scratchpad.changeset(%{content: Segment.join(tail)})
          |> Repo.insert!()

          message
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    with {:ok, message} <- result, do: publish_with_scratchpads(message)
  end

  @doc "Saves an edit to a scratchpad's text and broadcasts `{:scratchpads_changed, _}`."
  @spec update_scratchpad(Scope.t(), Scratchpad.t(), map()) ::
          {:ok, Scratchpad.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def update_scratchpad(%Scope{} = scope, %Scratchpad{} = scratchpad, attrs) do
    with :ok <- Chats.authorize(scope, scratchpad.chat_id, :manage),
         {:ok, scratchpad} <- scratchpad |> Scratchpad.changeset(attrs) |> Repo.update() do
      broadcast_scratchpads_changed(scratchpad.chat_id)
      {:ok, scratchpad}
    end
  end

  @doc """
  Appends a scratchpad onto its message's *current* active swipe (a continued or regenerated head is
  what gets extended) as a new `:append` swipe, then deletes the scratchpad. Returns the message.
  """
  @spec append_scratchpad(Scope.t(), Scratchpad.t()) ::
          {:ok, Message.t()} | {:error, :not_found | :orphaned | :generating | :unauthorized}
  def append_scratchpad(%Scope{} = scope, %Scratchpad{id: id, chat_id: chat_id}) do
    with :ok <- Chats.authorize(scope, chat_id, :manage), do: do_append_scratchpad(id)
  end

  defp do_append_scratchpad(id) do
    result =
      Repo.transaction(fn ->
        with {:ok, scratchpad} <- lock_scratchpad(id),
             {:ok, message} <- scratchpad_message(scratchpad),
             :ok <- check_not_generating(message) do
          content = Segment.join([Message.active_content(message), scratchpad.content])
          {:ok, _} = add_body(message, %{content: content}, :append)
          Repo.delete!(scratchpad)
          message
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    with {:ok, message} <- result, do: publish_with_scratchpads(message)
  end

  defp publish_with_scratchpads(message) do
    {:ok, message} = publish_updated(message)
    broadcast_scratchpads_changed(message.chat_id)
    {:ok, message}
  end

  defp lock_scratchpad(id) do
    case Repo.one(from(s in Scratchpad, where: s.id == ^id, lock: "FOR UPDATE")) do
      nil -> {:error, :not_found}
      scratchpad -> {:ok, scratchpad}
    end
  end

  defp scratchpad_message(%Scratchpad{message_id: nil}), do: {:error, :orphaned}

  defp scratchpad_message(%Scratchpad{message_id: id}) do
    case fetch_message(id) do
      nil -> {:error, :orphaned}
      message -> {:ok, message}
    end
  end

  @doc "Deletes a scratchpad (already gone is fine) and broadcasts `{:scratchpads_changed, _}`."
  @spec discard_scratchpad(Scope.t(), Scratchpad.t()) :: :ok | {:error, :unauthorized}
  def discard_scratchpad(%Scope{} = scope, %Scratchpad{} = scratchpad) do
    with :ok <- Chats.authorize(scope, scratchpad.chat_id, :manage) do
      Repo.delete_all(from(s in Scratchpad, where: s.id == ^scratchpad.id))
      broadcast_scratchpads_changed(scratchpad.chat_id)
      :ok
    end
  end

  @doc """
  Adds a user-made body as a new active swipe, sourced from the previously active swipe, deactivating
  the previous one in the same transaction. `origin` is `:edit`, or `:split`/`:merge`/`:append` for
  text a split, merge or scratchpad append produced.
  """
  def add_body(%Message{} = message, attrs \\ %{}, origin \\ :edit) when origin in [:edit, :split, :merge, :append] do
    body = %MessageBody{message_id: message.id, origin: origin, source_body_id: source_id(message)}
    insert_active_body(message, MessageBody.initial_changeset(body, attrs))
  end

  defp source_id(%Message{bodies: bodies}) when is_list(bodies) do
    Enum.find_value(bodies, fn body -> body.active && body.id end)
  end

  defp source_id(%Message{bodies: %Ecto.Association.NotLoaded{}} = message) do
    source_id(fetch_message!(message.id))
  end

  @doc """
  Saves a user edit as a new active swipe on `message`, leaving every existing body untouched, and
  broadcasts `{:message_updated, message}` (reloaded, bodies preloaded) on `topic(chat_id)`
  (`update_edited_body/4` saves into an existing one).
  """
  def add_edited_body(%Scope{} = scope, %Message{} = message, attrs) do
    with :ok <- Chats.authorize(scope, message.chat_id, {:edit_message, message}),
         {:ok, body} <- add_body(message, attrs),
         {:ok, message} <- publish_updated(message) do
      Mythweaver.Expressions.classify_later(scope, message.chat_id, message.id, body.id)
      :ok = Gate.scan_message(scope, message, body.content)
      {:ok, message}
    end
  end

  @doc """
  Saves a user edit into `message`'s swipe `body_id` (the one the edit opened on), keeping every other
  body and the swipe's other fields, and broadcasts `{:message_updated, message}` (reloaded, bodies
  preloaded) on `topic(chat_id)`. `{:error, :generating}` while any of its bodies is still generating;
  `{:error, :not_found}` when `message` has no such body.
  """
  def update_edited_body(%Scope{} = scope, %Message{} = message, body_id, attrs) do
    with :ok <- Chats.authorize(scope, message.chat_id, {:edit_message, message}),
         :ok <- check_not_generating(message),
         %MessageBody{} = body <- Enum.find(message.bodies, &(&1.id == body_id)) || {:error, :not_found},
         {:ok, body} <- body |> MessageBody.edit_changeset(attrs) |> Repo.update(),
         {:ok, message} <- publish_updated(message) do
      Mythweaver.Expressions.classify_later(scope, message.chat_id, message.id, body.id)
      :ok = Gate.scan_message(scope, message, body.content)
      {:ok, message}
    end
  end

  @doc """
  Creates a visible, empty message authored by `character_id` with one blank active body flagged
  `generating`, broadcasts `{:message_created, message}` on `topic(chat.id)`, and `touch_activity/1`s
  the chat.

  The row is created before the first token so every connected tab has something to stream into and a
  refresh mid-generation still shows the reply in progress.

  `guide` is the outline the generation follows, stored on the body.
  """
  def create_generating_message(%Chat{} = chat, character_id, guide \\ nil),
    do: insert_generating(chat, %{author_is_character: true, author_character_id: character_id}, guide)

  @doc "`create_generating_message/3` for an assistant chat: the reply's author is `Message.assistant_author/0`."
  def create_assistant_reply(%Chat{kind: :assistant} = chat),
    do: insert_generating(chat, %{author_is_character: false, author_name: Message.assistant_author()}, nil)

  @doc "`create_assistant_reply/1` for a compaction: the generating reply is marked `summary`."
  def create_assistant_summary(%Chat{kind: :assistant} = chat),
    do:
      insert_generating(chat, %{author_is_character: false, author_name: Message.assistant_author()}, nil,
        summary: true
      )

  defp insert_generating(chat, author_attrs, guide, fields \\ []) do
    result =
      Repo.transaction(fn ->
        lock_chat!(chat)

        %Message{chat_id: chat.id, position: next_position(chat)}
        |> struct(fields)
        |> Message.generating_changeset(author_attrs, guide)
        |> Message.put_author_is_player(chat)
        |> Repo.insert()
        |> Repo.ok_or_rollback()
      end)

    with {:ok, message} <- result do
      message = fetch_message!(message.id)
      broadcast_message_created(chat.id, message)
      touch_activity(chat.id)
      Cleanup.check_later(chat.id)
      {:ok, message}
    end
  end

  @doc """
  Adds a blank `generating` body to an existing message and makes it active, deactivating the previous
  one, so a regeneration goes into a new swipe. `guide` is stored on the new body.
  """
  def add_generating_body(%Message{} = message, guide \\ nil) do
    body = %MessageBody{message_id: message.id, origin: :regenerate, guide: guide}
    insert_active_body(message, MessageBody.streaming_changeset(body, %{}))
  end

  @doc "Adds a generating active swipe seeded with `source`'s text and reasoning, for a continue."
  def add_continuing_body(%Message{} = message, %MessageBody{} = source, guide \\ nil) do
    body = %MessageBody{message_id: message.id, origin: :continue, source_body_id: source.id, guide: guide}

    insert_active_body(
      message,
      MessageBody.continuing_changeset(body, %{
        content: source.content,
        reasoning: source.reasoning,
        reasoning_redacted: source.reasoning_redacted,
        reasoning_share_redacted: source.reasoning_share_redacted
      })
    )
  end

  @doc """
  Adds a blank generating active swipe rewriting `source` (`origin: :refine`); `instructions`, the
  user's editing instructions, are stored as the body's `guide`.
  """
  def add_refining_body(%Message{} = message, %MessageBody{} = source, instructions) do
    body = %MessageBody{message_id: message.id, origin: :refine, source_body_id: source.id, guide: instructions}
    insert_active_body(message, MessageBody.streaming_changeset(body, %{}))
  end

  @doc "Whether `message` is the chat's newest non-draft message, in `list_messages/1` order."
  def last_message?(%Scope{} = scope, %Message{} = message) do
    authorize!(scope, message.chat_id, :read)
    newest?(message)
  end

  defp newest?(message) do
    not Repo.exists?(
      from m in Message,
        where:
          m.chat_id == ^message.chat_id and m.draft == false and m.id != ^message.id and
            (m.position > ^message.position or
               (m.position == ^message.position and m.inserted_at > ^message.inserted_at))
    )
  end

  defp insert_active_body(%Message{} = message, changeset) do
    Repo.transaction(fn ->
      deactivate_bodies(message.id)
      changeset |> Repo.insert() |> Repo.ok_or_rollback()
    end)
  end

  @doc "Delay after the last token or draft edit before the buffered text is written to the DB."
  def write_debounce_ms, do: Application.get_env(:mythweaver, :write_debounce_ms, 3_000)

  @doc """
  Writes a streaming body's buffered `content`, `reasoning`, `reasoning_redacted` and
  `reasoning_share_redacted` in one UPDATE. Called by `Mythweaver.Generation.Server` on its
  debounce timer, never per token.
  """
  def save_streamed_body(
        %MessageBody{} = body,
        content,
        reasoning,
        reasoning_redacted \\ nil,
        reasoning_share_redacted \\ nil
      )
      when is_binary(content) do
    {1, _} =
      Repo.update_all(from(b in MessageBody, where: b.id == ^body.id),
        set: [
          content: content,
          reasoning: reasoning,
          reasoning_redacted: reasoning_redacted,
          reasoning_share_redacted: reasoning_share_redacted,
          updated_at: DateTime.utc_now()
        ]
      )

    :ok
  end

  @doc "Writes the outcome of a streamed generation onto `body` and clears its `generating` flag."
  def finalize_body(%MessageBody{} = body, attrs) do
    body |> MessageBody.finalize_changeset(attrs) |> Repo.update()
  end

  @doc """
  Discards a generation that produced no text (see `Mythweaver.Generation.Server`): deletes `body`,
  and the whole message with it when no other swipe has text (`delete_message/2`, so attachments,
  memory rollback and `{:message_deleted, _}` follow). Otherwise `restore_id` (the swipe that was
  active before the generation) is active again, or the newest remaining swipe once that one is gone.
  Broadcasts nothing else: the generation's `{:generation_finished, _}` repaints the message.
  """
  @spec discard_generation(Scope.t(), MessageBody.t(), Ecto.UUID.t() | nil) :: {:ok, :body | :message}
  def discard_generation(%Scope{} = scope, %MessageBody{} = body, restore_id) do
    others =
      Repo.all(
        from(b in MessageBody,
          where: b.message_id == ^body.message_id and b.id != ^body.id,
          order_by: [asc: b.inserted_at, asc: b.id]
        )
      )

    case Repo.get(Message, body.message_id) do
      nil ->
        {:ok, :message}

      message ->
        if Enum.any?(others, &(not blank?(&1.content))) do
          restore = Enum.find(others, &(&1.id == restore_id)) || List.last(others)

          {:ok, _} =
            Repo.transaction(fn ->
              Repo.delete_all(from(b in MessageBody, where: b.id == ^body.id))
              Repo.update_all(from(b in MessageBody, where: b.id == ^restore.id), set: [active: true])
            end)

          {:ok, :body}
        else
          {:ok, _} = delete_message(scope, message)
          {:ok, :message}
        end
    end
  end

  @doc "Whether generated `content` carries no text: nil, empty or whitespace only."
  @spec blank?(String.t() | nil) :: boolean()
  def blank?(content), do: String.trim(content || "") == ""

  @doc """
  Settles every body still `generating`. Run once at boot: no generation survives a restart, so any
  such body was stranded by a hard kill or a crash before its Server could finalize it (see
  `Mythweaver.Generation.Server`).

  One with no text is discarded as `discard_generation/3` would, along with its message when no
  swipe of it has text, and a message that keeps other swipes gets its newest one active again. No
  memory rollback runs (nobody's scope is at hand, and a memory never covers a reply still being
  written), and orphaned attachments are left to `Mythweaver.Attachments.sweep_orphans/0`. Assistant
  chats keep theirs, since a reply there may be tool calls alone. The rest are marked finished with
  the error "Interrupted.".
  """
  @spec finalize_interrupted_bodies() :: :ok
  def finalize_interrupted_bodies do
    {:ok, _} =
      Repo.transaction(fn ->
        empty =
          from(b in MessageBody,
            join: m in assoc(b, :message),
            join: c in assoc(m, :chat),
            where: b.generating and c.kind != :assistant and fragment("coalesce(?, '') ~ '^\\s*$'", b.content)
          )

        message_ids = Repo.all(from(b in empty, distinct: true, select: b.message_id))
        Repo.delete_all(from(b in MessageBody, where: b.id in subquery(select(empty, [b], b.id))))

        with_text =
          from(b in MessageBody,
            where: b.message_id == parent_as(:message).id and fragment("coalesce(?, '') !~ '^\\s*$'", b.content)
          )

        Repo.delete_all(from(m in Message, as: :message, where: m.id in ^message_ids and not exists(with_text)))

        Enum.each(message_ids, &reactivate_newest/1)
      end)

    # Bodies of many users at once, at boot: the site's default language.
    error =
      Mythweaver.Locale.with_user_locale(nil, fn ->
        dpgettext("jobs", "status: error text of a reply cut off by a server restart", "Interrupted.")
      end)

    from(b in MessageBody, where: b.generating)
    |> Repo.update_all(set: [generating: false, error: error, updated_at: DateTime.utc_now()])

    :ok
  end

  # A message left without an active swipe (its active one was discarded) gets its newest one back.
  defp reactivate_newest(message_id) do
    if !Repo.exists?(from(b in MessageBody, where: b.message_id == ^message_id and b.active)) do
      newest =
        from(b in MessageBody,
          where: b.message_id == ^message_id,
          order_by: [desc: b.inserted_at, desc: b.id],
          limit: 1,
          select: b.id
        )

      Repo.update_all(from(b in MessageBody, where: b.id in subquery(newest)), set: [active: true])
    end
  end

  @doc """
  Selects an existing body as the active one (swipe navigation), deactivating the current
  active body in the same transaction. Broadcasts nothing (the caller repaints), but queues the
  chat's background embedding pass (`Mythweaver.Lore.Embeddings.sync_chat_later/1`).
  """
  def set_active_body(%Scope{} = scope, %MessageBody{} = body) do
    chat_id = Repo.one(from(m in Message, where: m.id == ^body.message_id, select: m.chat_id))

    with :ok <- Chats.authorize(scope, chat_id, :regenerate),
         {:ok, _} = result <- activate_body(body) do
      Embeddings.sync_chat_later(chat_id)
      result
    end
  end

  defp activate_body(body) do
    Repo.transaction(fn ->
      deactivate_bodies(body.message_id)
      body |> Ecto.Changeset.change(active: true) |> Repo.update!()
    end)
  end

  @doc """
  Reattributes messages authored by `character` to a verbatim string author, snapshotting the
  character's name into `author_name`. Called during character deletion so attribution survives.
  The DB `on_delete: :nilify_all` then clears `author_character_id`.
  """
  def detach_character(%Character{} = character) do
    Repo.delete_all(from(m in Message, where: m.draft == true and m.author_character_id == ^character.id))

    from(m in Message, where: m.author_character_id == ^character.id and m.draft == false)
    |> Repo.update_all(set: [author_is_character: false, author_name: character.name])
  end

  @doc """
  Detaches `character` from the messages of `chat_ids` only (a chat owner lost it): drafts are
  deleted, the rest keep its name as a verbatim author, no longer point at it (sharing it again
  re-attaches nothing) and lose their expression, whose sprite was the character's.
  """
  def detach_character(%Character{} = character, chat_ids) when is_list(chat_ids) do
    scoped = from(m in Message, where: m.author_character_id == ^character.id and m.chat_id in ^chat_ids)

    Repo.delete_all(where(scoped, [m], m.draft == true))

    Repo.update_all(
      from(b in MessageBody, where: b.message_id in subquery(select(where(scoped, [m], m.draft == false), [m], m.id))),
      set: [expression: nil, expression_scores: nil, expression_source: nil, expression_sprite_id: nil]
    )

    Repo.update_all(where(scoped, [m], m.draft == false),
      set: [author_is_character: false, author_name: character.name, author_character_id: nil]
    )
  end

  defp deactivate_bodies(message_id) do
    Repo.update_all(
      from(b in MessageBody, where: b.message_id == ^message_id and b.active == true),
      set: [active: false]
    )
  end
end
