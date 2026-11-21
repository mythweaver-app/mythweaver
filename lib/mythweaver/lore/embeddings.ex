defmodule Mythweaver.Lore.Embeddings do
  @moduledoc """
  Embeddings for Vector lore entries (`activation: :vector`) and chat messages: which model makes
  them, the background work that stores them, and the scoring against stored vectors.

  Only background tasks call the embedding API. A reply, preview or caption resolves lore through
  `Mythweaver.Lore.Activation`, which runs `compare/3` over stored vectors and nothing else; an entry
  or message not embedded yet simply has no vector match on that reply.

  The model is the `lore.embedding_model` setting (user over site; the site's alone for a forced
  book). Every call is recorded in `generation_stats` (`Mythweaver.Analytics.record_call/1`),
  and on a site model each `@batch_size` chunk first passes `Mythweaver.Permissions.Quota.check_spend/3`,
  so background work stops once the user's daily spending limit is reached and the rest waits.

  Triggers: `Mythweaver.Messages`' `broadcast_message_created/2`, `broadcast_message_updated/2` and
  `broadcast_generation_finished/2` call `sync_chat_later/1`, as does a resolve that met something
  unembedded; entry saves call `refresh_later/2`, imports `refresh_books_later/2`. With
  `config :mythweaver, :lore_embeddings_in_background, false` (tests) the `*_later` functions do
  nothing.
  """

  import Ecto.Query
  import Pgvector.Ecto.Query

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.AI.Embedding
  alias Mythweaver.AI.Model
  alias Mythweaver.Analytics
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Lore.Activation
  alias Mythweaver.Lore.BookEntry
  alias Mythweaver.Lore.EmbeddingRegistry
  alias Mythweaver.Lore.EmbeddingSupervisor
  alias Mythweaver.Lore.EntryEmbedding
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Lore.MessageEmbedding
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message
  alias Mythweaver.Messages.MessageBody
  alias Mythweaver.Permissions.Quota
  alias Mythweaver.Repo
  alias Mythweaver.Schema
  alias Mythweaver.Settings

  require Logger

  @batch_size 64

  @type comparison :: %{
          scores: %{Ecto.UUID.t() => float()},
          unembedded: MapSet.t(),
          messages_embedded?: boolean(),
          all_messages_embedded?: boolean()
        }

  @doc """
  The embedding model `id` names, when `scope` may run it and it is an embedding model; anything
  else (nil, gone, not usable, another mode) is `{:error, :no_model}`.
  """
  @spec model(Scope.t(), Ecto.UUID.t() | nil) :: {:ok, Model.t()} | {:error, :no_model}
  def model(_scope, nil), do: {:error, :no_model}

  def model(%Scope{} = scope, id) do
    case AI.get_model(scope, id) do
      %Model{completion_mode: :embedding} = model -> {:ok, model}
      _other -> {:error, :no_model}
    end
  end

  @doc """
  Scores one candidate group's `entries` against one scan window's active `body_ids` under `model`,
  from stored vectors only (no HTTP call).

    * `scores`: each embedded entry's highest cosine similarity to any embedded body in the
      window, so one strongly related message is enough, as a keyword in any one message is.
    * `unembedded`: entry ids with no vector for the model, or one made from other content.
    * `messages_embedded?`: whether any of `body_ids` has a vector for the model;
      `all_messages_embedded?`: whether every one does.

  Body vectors match by id alone: a body's text only changes in place while it generates, and a
  generating body is never embedded. An edit adds a new body.
  """
  @spec compare(Model.t(), [LoreEntry.t()], [Ecto.UUID.t()]) :: comparison()
  def compare(%Model{id: model_id}, entries, body_ids) do
    # Blank entries are never embedded (`refresh/4` skips them), so they are not "unembedded" either.
    entries = Enum.reject(entries, &(String.trim(&1.content || "") == ""))
    stored = stored_hashes(EntryEmbedding, :lore_entry_id, model_id, Enum.map(entries, & &1.id))
    {fresh, stale} = Enum.split_with(entries, &(Map.get(stored, &1.id) == hash(&1.content)))

    embedded_bodies =
      if body_ids == [],
        do: [],
        else:
          Repo.all(
            from(m in MessageEmbedding,
              where: m.ai_model_id == ^model_id and m.message_body_id in ^body_ids,
              select: m.message_body_id
            )
          )

    %{
      scores: scores(model_id, Enum.map(fresh, & &1.id), embedded_bodies),
      unembedded: MapSet.new(stale, & &1.id),
      messages_embedded?: embedded_bodies != [],
      all_messages_embedded?: length(Enum.uniq(embedded_bodies)) == length(Enum.uniq(body_ids))
    }
  end

  defp scores(_model_id, [], _body_ids), do: %{}
  defp scores(_model_id, _entry_ids, []), do: %{}

  # A zero vector gives NaN, and Postgres orders NaN above every number, so one NaN would win `max`.
  defp scores(model_id, entry_ids, body_ids) do
    from(e in EntryEmbedding,
      join: m in MessageEmbedding,
      on: m.ai_model_id == e.ai_model_id,
      where:
        e.ai_model_id == ^model_id and e.lore_entry_id in ^entry_ids and m.message_body_id in ^body_ids and
          fragment("vector_dims(?) = vector_dims(?)", e.embedding, m.embedding) and
          fragment("(? <=> ?) <> 'NaN'::float8", e.embedding, m.embedding),
      group_by: e.lore_entry_id,
      select: {e.lore_entry_id, max(1 - cosine_distance(e.embedding, m.embedding))}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Embeds those of `entries` with no current vector for `model`, in chunks of #{@batch_size}.

  Each chunk first passes `Quota.check_spend/3`; a refusal stops with `{:error, :quota_exceeded}`.
  The first failed or refused chunk returns its error; chunks already written stay, and the next sync
  picks up the rest. Nothing stale means no call and no quota query. `opts`: `chat_id:` and `origin:`
  for the recorded stat.
  """
  @spec refresh(Scope.t(), Model.t(), [LoreEntry.t()], keyword()) :: :ok | {:error, term()}
  def refresh(%Scope{} = scope, %Model{} = model, entries, opts) do
    entries = Enum.uniq_by(entries, & &1.id)
    stored = stored_hashes(EntryEmbedding, :lore_entry_id, model.id, Enum.map(entries, & &1.id))

    # A blank entry (a trigger, or one only its keys matter for) has nothing to embed.
    stale =
      for %LoreEntry{id: id, content: content} <- entries,
          is_binary(content) and String.trim(content) != "",
          digest = hash(content),
          Map.get(stored, id) != digest,
          do: {id, content, digest}

    embed_chunks(scope, model, stale, opts, {EntryEmbedding, :lore_entry_id}, fn _ids -> :ok end)
  end

  @doc """
  `refresh/4`'s loop for `chat`'s message bodies: every active, finished body with non-blank content
  and no current vector for `model`, newest message first (the scan window reads the most recent).
  Hidden messages are included, since a message can be shown again; drafts are not. The text is the
  body's content alone: image description lines stay keyword-only. Each written chunk is announced
  with `Messages.broadcast_bodies_embedded/2`.
  """
  @spec embed_messages(Scope.t(), Chat.t(), Model.t()) :: :ok | {:error, term()}
  def embed_messages(%Scope{} = scope, %Chat{} = chat, %Model{} = model) do
    bodies =
      Repo.all(
        from(b in MessageBody,
          join: m in Message,
          on: m.id == b.message_id,
          left_join: e in MessageEmbedding,
          on: e.message_body_id == b.id and e.ai_model_id == ^model.id,
          where: m.chat_id == ^chat.id and m.draft == false and b.active and not b.generating,
          order_by: [desc: m.position, desc: m.inserted_at],
          select: {b.id, b.content, e.content_hash}
        )
      )

    stale =
      for {id, content, stored} <- bodies,
          is_binary(content) and String.trim(content) != "",
          digest = hash(content),
          stored != digest,
          do: {id, content, digest}

    embed_chunks(
      scope,
      model,
      stale,
      [chat_id: chat.id, origin: :background],
      {MessageEmbedding, :message_body_id},
      &Messages.broadcast_bodies_embedded(chat.id, &1)
    )
  end

  defp embed_chunks(scope, model, items, opts, {schema, key}, after_chunk) do
    items
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      with :ok <- Quota.check_spend(scope, model, AI.run_owner(scope, Keyword.get(opts, :chat_id))),
           {:ok, vectors} <- embed(scope, model, Enum.map(chunk, &elem(&1, 1)), opts) do
        now = DateTime.truncate(DateTime.utc_now(), :second)

        rows =
          Enum.zip_with(chunk, vectors, fn {id, _text, digest}, vector ->
            %{
              key => id,
              :id => Schema.generate_id(),
              :ai_model_id => model.id,
              :content_hash => digest,
              :embedding => Pgvector.new(vector),
              :inserted_at => now,
              :updated_at => now
            }
          end)

        Repo.insert_all(schema, rows,
          on_conflict: {:replace, [:content_hash, :embedding, :updated_at]},
          conflict_target: [key, :ai_model_id]
        )

        after_chunk.(Enum.map(chunk, &elem(&1, 0)))
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  # `AI.embed/3`, recorded: a missing link records nothing, any other failure a `:failed` stat.
  defp embed(scope, model, texts, opts) do
    started_at = DateTime.utc_now()
    result = AI.embed(model, AI.run_owner(scope, Keyword.get(opts, :chat_id)), texts)

    call = %{
      scope: scope,
      model: model,
      chat_id: Keyword.get(opts, :chat_id),
      origin: Keyword.get(opts, :origin, :background),
      started_at: started_at,
      finished_at: DateTime.utc_now()
    }

    case result do
      {:ok, %Embedding{vectors: vectors, usage: usage}, link} ->
        Analytics.record_call(Map.merge(call, %{tag: :embedding, status: :completed, link: link, usage: usage}))
        {:ok, vectors}

      {:error, :no_provider} = error ->
        error

      {:error, _reason} = error ->
        Analytics.record_call(Map.merge(call, %{tag: :embedding, status: :failed, link: nil, usage: %{}}))
        error
    end
  end

  @doc """
  One background pass for a chat, as its owner: for each embedding model its Vector candidates need
  (`Activation.vector_groups/2`), embeds those entries, then the chat's messages. A chat without
  Vector entries or without a model makes no call, and so does an assistant chat. A refused quota
  ends a model's pass quietly, and any other error is logged and ends it too; the next trigger
  retries both.
  """
  @spec sync_chat(Ecto.UUID.t()) :: :ok
  def sync_chat(chat_id) do
    with %Chat{user_id: user_id, kind: :roleplay} = chat when is_binary(user_id) <- Chats.get_chat(chat_id),
         %Scope{} = scope <- user_id |> Accounts.get_user() |> Scope.for_user() do
      for {model_id, entries} <- Activation.vector_groups(scope, chat) do
        sync_group(scope, chat, model_id, entries)
      end
    end

    :ok
  end

  defp sync_group(scope, chat, model_id, entries) do
    result =
      with {:ok, model} <- model(scope, model_id),
           :ok <- refresh(scope, model, entries, chat_id: chat.id, origin: :background) do
        embed_messages(scope, chat, model)
      end

    log_failure(result, "chat #{chat.id}")
  end

  @doc """
  Runs `sync_chat/1` in the background. One chat has at most one pass running: a trigger while one
  runs asks it for one more pass, so a burst coalesces. A trigger landing in the instant between a
  pass's last check and its exit is dropped; the next trigger catches up.
  """
  @spec sync_chat_later(Ecto.UUID.t()) :: :ok
  def sync_chat_later(chat_id) do
    if background?() do
      start(fn ->
        case Registry.register(EmbeddingRegistry, {:chat, chat_id}, nil) do
          {:ok, _owner} -> sync_loop(chat_id)
          {:error, {:already_registered, pid}} -> send(pid, :again)
        end
      end)
    end

    :ok
  end

  defp sync_loop(chat_id) do
    flush_again()
    sync_chat(chat_id)

    receive do
      :again -> sync_loop(chat_id)
    after
      0 -> :ok
    end
  end

  defp flush_again do
    receive do
      :again -> flush_again()
    after
      0 -> :ok
    end
  end

  @doc """
  Embeds the saved Vector entries among `entries` in the background, under the scope's
  `lore.embedding_model`. Does nothing when none is Vector, no model is set, or the quota refuses. A
  forced book on a site model other than the user's is left to the chat sync.
  """
  @spec refresh_later(Scope.t(), [LoreEntry.t()]) :: :ok
  def refresh_later(%Scope{} = scope, entries) do
    case Enum.filter(entries, &(&1.activation == :vector)) do
      [] -> :ok
      vector -> refresh_in_background(scope, fn -> vector end)
    end
  end

  @doc "`refresh_later/2` for every Vector entry in `book_ids` (an import)."
  @spec refresh_books_later(Scope.t(), [Ecto.UUID.t()]) :: :ok
  def refresh_books_later(_scope, []), do: :ok

  def refresh_books_later(%Scope{} = scope, book_ids) do
    refresh_in_background(scope, fn ->
      Repo.all(
        from(e in LoreEntry,
          join: be in BookEntry,
          on: be.lore_entry_id == e.id,
          where: be.lore_book_id in ^book_ids and e.activation == :vector,
          distinct: true
        )
      )
    end)
  end

  defp refresh_in_background(scope, entries_fun) do
    with true <- background?(),
         {:ok, model} <- model(scope, Settings.get(scope, "lore.embedding_model")),
         :ok <- Quota.check_spend(scope, model, AI.run_owner(scope, nil)) do
      start(fn ->
        scope
        |> refresh(model, entries_fun.(), origin: :background, chat_id: nil)
        |> log_failure("entries")
      end)
    end

    :ok
  end

  @doc """
  The embedding state of `body_ids` in `chat`: `on?` is whether the chat has Vector entries with a
  model (`Activation.vector_groups/2`), and `embedded` holds the bodies with a vector under every one
  of those models. One query; none when `on?` is false.
  """
  @spec status(Scope.t(), Chat.t(), [Ecto.UUID.t()]) :: %{on?: boolean(), embedded: MapSet.t()}
  def status(%Scope{} = scope, %Chat{} = chat, body_ids) do
    case Activation.vector_groups(scope, chat) do
      [] ->
        %{on?: false, embedded: MapSet.new()}

      groups ->
        %{on?: true, embedded: embedded_under_all(Enum.map(groups, &elem(&1, 0)), body_ids)}
    end
  end

  defp embedded_under_all(_model_ids, []), do: MapSet.new()

  defp embedded_under_all(model_ids, body_ids) do
    from(m in MessageEmbedding,
      where: m.message_body_id in ^body_ids and m.ai_model_id in ^model_ids,
      group_by: m.message_body_id,
      having: count(m.ai_model_id, :distinct) == ^length(model_ids),
      select: m.message_body_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp stored_hashes(_schema, _key, _model_id, []), do: %{}

  defp stored_hashes(schema, key, model_id, ids) do
    from(e in schema,
      where: e.ai_model_id == ^model_id and field(e, ^key) in ^ids,
      select: {field(e, ^key), e.content_hash}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp hash(content), do: :crypto.hash(:sha256, content || "")

  defp background?, do: Application.get_env(:mythweaver, :lore_embeddings_in_background, true)

  defp start(fun) do
    {:ok, _pid} = Task.Supervisor.start_child(EmbeddingSupervisor, fun)
    :ok
  end

  defp log_failure(:ok, _what), do: :ok
  defp log_failure({:error, reason}, _what) when reason in [:quota_exceeded, :no_model], do: :ok

  defp log_failure({:error, reason}, what) do
    Logger.warning("Lore embedding for #{what} failed: #{inspect(reason)}")
    :ok
  end
end
