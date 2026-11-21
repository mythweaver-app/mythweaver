defmodule Mythweaver.Memory.Clips do
  @moduledoc """
  Clips: highlighted passages saved as lines of a clip entry in the chat's memory book
  (`save_clip/4`), AI-written topical clips drawn from a book's memories (`topical_clip/4`,
  `combine_clips/4`), and Memory Assistance, which reviews clips and suggests topics
  (`enqueue_assistance/3`, `list_topic_suggestions/2`).
  """

  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Query, warn: false

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Jobs
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Lore
  alias Mythweaver.Lore.BookEntry
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Memory
  alias Mythweaver.Memory.Consolidation
  alias Mythweaver.Memory.JSON
  alias Mythweaver.Memory.Record
  alias Mythweaver.Memory.Scene
  alias Mythweaver.Memory.TopicSuggestion
  alias Mythweaver.Messages.Message
  alias Mythweaver.Moderation.Gate
  alias Mythweaver.Ownership
  alias Mythweaver.Prompts.Prompt
  alias Mythweaver.Repo

  require Logger

  ## Clips

  @doc """
  Saves a highlighted passage as one clip line, with no AI call:

    * `{:new, title, activation}`: a new `=== title ===` … `=== END title ===` entry in the chat's
      memory book (`:keyword` activation is keyed on the title) and its `:clip` record
    * `{:existing, record_id}`: the line goes before that clip's `=== END` marker, or at the end
      when the marker is gone

  The text is trimmed and its line breaks collapsed to spaces.
  """
  @spec save_clip(
          Scope.t(),
          Chat.t(),
          String.t() | nil,
          {:new, String.t(), :keyword | :constant} | {:existing, Ecto.UUID.t()}
        ) ::
          {:ok, Record.t()} | {:error, :empty | :no_title | :not_found | :invalid | :unauthorized}
  def save_clip(%Scope{} = scope, %Chat{} = chat, text, target) do
    with :ok <- Chats.authorize(scope, chat, :manage),
         {:ok, line} <- clip_line(text),
         {:ok, record} <- Repo.transaction(fn -> save_clip_tx(scope, chat, line, target) end) do
      Memory.broadcast_changed(chat.id)
      {:ok, record}
    end
    |> Memory.invalid_changeset()
  end

  defp clip_line(text) when is_binary(text) do
    text
    |> String.trim()
    |> String.replace(~r/\s*[\r\n]+\s*/, " ")
    |> case do
      "" -> {:error, :empty}
      line -> {:ok, line}
    end
  end

  defp clip_line(_text), do: {:error, :empty}

  defp save_clip_tx(scope, chat, line, {:new, title, activation}) when activation in [:keyword, :constant] do
    title = String.trim(title || "")
    if title == "", do: Repo.rollback(:no_title)
    book = Memory.ensure_book(scope, chat)

    entry =
      %{
        name: title,
        content: "=== #{title} ===\n\n- #{line}\n\n=== END #{title} ===",
        activation: activation,
        keywords: if(activation == :keyword, do: [title], else: [])
      }
      |> then(fn attrs -> Gate.unmoderated(fn -> Lore.create_entry(scope, attrs, [book.id]) end) end)
      |> Repo.ok_or_rollback()

    %Record{}
    |> Record.changeset(%{
      lore_entry_id: entry.id,
      lore_book_id: book.id,
      chat_id: chat.id,
      kind: :clip,
      written_fingerprint: Scene.sha256(entry.content)
    })
    |> Repo.insert()
    |> Repo.ok_or_rollback()
  end

  defp save_clip_tx(scope, _chat, line, {:existing, record_id}) do
    record = Memory.lock_record!(record_id, :clip, :not_found)
    Memory.rewrite_content!(scope, record, add_clip_line(record.entry.content, line))
  end

  # The new item follows the last line before the `=== END` marker, so the blank line ahead of the
  # marker stays where it was.
  defp add_clip_line(content, line) do
    lines = String.split(content, "\n")

    end_at =
      lines
      |> Enum.with_index()
      |> Enum.filter(fn {text, _i} -> String.starts_with?(String.trim(text), "=== END") end)
      |> List.last()

    case end_at do
      {_marker, i} ->
        {before, rest} = Enum.split(lines, i)
        {blanks, items} = before |> Enum.reverse() |> Enum.split_while(&(String.trim(&1) == ""))
        Enum.join(Enum.reverse(items, ["- " <> line] ++ blanks ++ rest), "\n")

      nil ->
        case String.trim_trailing(content) do
          "" -> "- " <> line
          kept -> kept <> "\n- " <> line
        end
    end
  end

  ## Topical clips

  @doc "The profile's topical-clip prompt: `{:error, :no_prompt}` when unset, missing or of another purpose."
  @spec topical_clip_prompt(Scope.t(), Ecto.UUID.t() | nil) :: {:ok, Prompt.t()} | {:error, :no_prompt}
  def topical_clip_prompt(%Scope{} = scope, id), do: Memory.purpose_prompt(scope, id, :topical_clip)

  @doc "The profile's Memory Assistance clip-review prompt: `{:error, :no_prompt}` when unset, missing or of another purpose."
  @spec clip_review_prompt(Scope.t(), Ecto.UUID.t() | nil) :: {:ok, Prompt.t()} | {:error, :no_prompt}
  def clip_review_prompt(%Scope{} = scope, id), do: Memory.purpose_prompt(scope, id, :clip_review)

  @doc "The profile's topic-suggestions prompt: `{:error, :no_prompt}` when unset, missing or of another purpose."
  @spec clip_suggestions_prompt(Scope.t(), Ecto.UUID.t() | nil) :: {:ok, Prompt.t()} | {:error, :no_prompt}
  def clip_suggestions_prompt(%Scope{} = scope, id), do: Memory.purpose_prompt(scope, id, :clip_suggestions)

  @doc "The profile's combine-clips prompt: `{:error, :no_prompt}` when unset, missing or of another purpose."
  @spec combine_clips_prompt(Scope.t(), Ecto.UUID.t() | nil) :: {:ok, Prompt.t()} | {:error, :no_prompt}
  def combine_clips_prompt(%Scope{} = scope, id), do: Memory.purpose_prompt(scope, id, :combine_clips)

  @doc """
  The records a topical clip may draw on in `book_id`: memories and consolidations (not clips or side
  prompts), with entries, by tier then the book's entry order. `[]` for nil or a refused scope.
  """
  @spec topical_sources(Scope.t(), Ecto.UUID.t() | nil) :: [Record.t()]
  def topical_sources(%Scope{}, nil), do: []

  def topical_sources(%Scope{} = scope, book_id) do
    if Memory.authorize_book(scope, book_id) == :ok, do: book_topical_sources(book_id), else: []
  end

  defp book_topical_sources(book_id) do
    Repo.all(
      from(r in Record,
        left_join: be in BookEntry,
        on: be.lore_book_id == r.lore_book_id and be.lore_entry_id == r.lore_entry_id,
        where: r.lore_book_id == ^book_id and r.kind in [:memory, :consolidation],
        order_by: [
          asc: r.tier,
          asc_nulls_last: be.order,
          asc_nulls_last: r.range_start,
          asc: r.sequence,
          asc: r.inserted_at
        ],
        preload: :entry
      )
    )
  end

  @doc "The topical clips of `book_id`, with entries, by name. `[]` for nil."
  @spec topical_clips(Scope.t(), Ecto.UUID.t() | nil) :: [Record.t()]
  def topical_clips(%Scope{}, nil), do: []

  def topical_clips(%Scope{} = scope, book_id) do
    if Memory.authorize_book(scope, book_id) == :ok, do: book_topical_clips(book_id), else: []
  end

  defp book_topical_clips(book_id) do
    Repo.all(
      from(r in Record,
        join: e in assoc(r, :entry),
        where: r.lore_book_id == ^book_id and r.kind == :topical_clip,
        order_by: [asc: e.name, asc: r.id],
        preload: [entry: {e, :book_entries}]
      )
    )
  end

  @doc """
  Queues a topical clip: one entry gathering everything about `topic` from a book's memories and,
  optionally, a range of messages. Always reviewed; `approve/2` writes the entry.

  `opts`: `:topic` (required), `:keywords` (default `[topic]`), `:book_id` (default the chat's
  memory book), `:include_memories` (default true) with `:record_ids` (nil = every
  `topical_sources/1` record), `:include_messages` with `:start`/`:end` positions or
  `:message_ids` (picked messages, hidden ones included), `:target_record_id` (a topical clip to
  update), `:rebuild` and `:suggestion_id` (the `TopicSuggestion` the draft is for, deleted when
  the clip is saved).

  Updating without `:rebuild` sends only the sources that are new or changed since the target's
  snapshot, and its existing content; rebuilding sends every picked source and no existing content.
  `{:error, :no_sources}` when nothing is left to send.
  """
  @spec topical_clip(Scope.t(), Chat.t(), keyword()) ::
          {:ok, Job.t()}
          | {:error,
             :no_topic
             | :no_sources
             | :not_found
             | :empty_scene
             | :no_profile
             | :no_model
             | :ambiguous_model
             | :no_prompt
             | :unauthorized}
  def topical_clip(%Scope{} = scope, %Chat{} = chat, opts) do
    with :ok <- Chats.authorize(scope, chat, :manage), do: do_topical_clip(Chats.run_scope(scope, chat), chat, opts)
  end

  defp do_topical_clip(scope, chat, opts) do
    topic = String.trim(opts[:topic] || "")
    rebuild? = opts[:rebuild] == true
    book_id = opts[:book_id] || Memory.settings_row(chat).memory_book_id

    with :ok <- if(topic == "", do: {:error, :no_topic}, else: :ok),
         {:ok, target} <- topical_target(opts[:target_record_id]),
         {:ok, profile} <- Memory.profile_for(scope, chat),
         {:ok, model} <- Memory.model_for(scope, chat, profile),
         {:ok, prompt} <- topical_clip_prompt(scope, profile.topical_clip_prompt_id),
         {:ok, messages} <- topical_messages(scope, chat, opts) do
      snapshot = (target && !rebuild? && target.snapshot) || %{}

      chosen =
        cond do
          opts[:include_memories] == false -> []
          is_list(opts[:record_ids]) -> Enum.filter(topical_sources(scope, book_id), &(&1.id in opts[:record_ids]))
          true -> topical_sources(scope, book_id)
        end

      fingerprints = Map.new(chosen, &{&1.id, Scene.sha256(&1.entry.content)})
      known = snapshot["sources"] || %{}
      sent = Enum.reject(chosen, &(known[&1.id] == fingerprints[&1.id]))
      send_messages? = messages != nil and snapshot["messages"] != messages

      if sent == [] and not send_messages? do
        {:error, :no_sources}
      else
        keywords = topical_keywords(opts[:keywords], topic)
        range = if send_messages?, do: messages

        Jobs.enqueue(scope, :topical_clip, %{
          origin: :interactive,
          chat_id: chat.id,
          label:
            dpgettext("memory", "heading: job that drafts a topical clip", "Topical clip — %{topic_name}",
              topic_name: topic
            ),
          ai_model_id: model.id,
          range_start: range && range["start"],
          range_end: range && range["end"],
          params:
            Map.reject(
              %{
                "chat_id" => chat.id,
                "profile_id" => profile.id,
                "prompt_id" => prompt.id,
                "book_id" => (target && target.lore_book_id) || book_id,
                "topic" => topic,
                "keywords" => keywords,
                "source_ids" => Enum.map(sent, & &1.id),
                "messages" => range,
                "rebuild" => rebuild?,
                "review" => true,
                "target_record_id" => target && target.id,
                "suggestion_id" => opts[:suggestion_id],
                "entry_updated_at" => target && DateTime.to_iso8601(target.entry.updated_at),
                "entry_fingerprint" => target && Scene.sha256(target.entry.content),
                # What the clip covers once saved: an update adds to what it covered before.
                "snapshot" => %{
                  "topic" => topic,
                  "sources" => Map.merge(known, fingerprints),
                  "messages" => messages || snapshot["messages"]
                }
              },
              fn {_key, value} -> is_nil(value) end
            )
        })
      end
    end
  end

  defp topical_target(nil), do: {:ok, nil}

  defp topical_target(id) do
    case Repo.one(from(r in Record, where: r.id == ^id and r.kind == :topical_clip, preload: :entry)) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  # The messages as their snapshot (`"start"`, `"end"`, `"fingerprint"`, plus `"message_ids"` for
  # picked messages), or nil when not included.
  defp topical_messages(scope, chat, opts) do
    cond do
      opts[:include_messages] != true -> {:ok, nil}
      match?([_ | _], opts[:message_ids]) -> topical_picked_messages(scope, chat, opts[:message_ids])
      true -> topical_range_messages(scope, chat, opts)
    end
  end

  defp topical_picked_messages(scope, chat, ids) do
    positions =
      Repo.all(
        from(m in Message, where: m.chat_id == ^chat.id and m.id in ^ids and m.draft == false, select: m.position)
      )

    with [_ | _] <- positions,
         {first, last} = Enum.min_max(positions),
         [_ | _] = messages <- Scene.listed(scope, chat, first, last, ids) do
      {:ok,
       %{
         "message_ids" => Enum.map(messages, & &1.id),
         "start" => first,
         "end" => last,
         "fingerprint" => Scene.fingerprint(messages)
       }}
    else
      [] -> {:error, :empty_scene}
    end
  end

  defp topical_range_messages(scope, chat, opts) do
    with first when is_integer(first) <- opts[:start],
         last when is_integer(last) <- opts[:end],
         [_ | _] = messages <- Scene.messages(scope, chat, first, last, Memory.preferences(scope)) do
      {:ok, %{"start" => first, "end" => last, "fingerprint" => Scene.fingerprint(messages)}}
    else
      _empty -> {:error, :empty_scene}
    end
  end

  defp topical_keywords(keywords, topic) do
    case JSON.keywords(keywords) do
      [] -> [topic]
      keywords -> keywords
    end
  end

  @doc """
  Queues a combination of two or more topical clips of one book into a new topical clip titled
  `:title`, always reviewed; approving writes it and, with `:disable_originals` (default true),
  disables the originals in their book (they are never deleted).

  `opts`: `:book_id`, `:record_ids` (topical clips of that book, in order), `:title` and
  `:disable_originals`. The keywords are the union of the clips' keywords (else `[title]`).
  """
  @spec combine_clips(Scope.t(), Chat.t(), keyword()) ::
          {:ok, Job.t()}
          | {:error, :no_title | :too_few | :not_found | :no_profile | :no_model | :ambiguous_model}
          | {:error, :no_prompt | :unauthorized}
  def combine_clips(%Scope{} = scope, %Chat{} = chat, opts) do
    title = String.trim(opts[:title] || "")
    ids = Enum.uniq(opts[:record_ids] || [])
    book_id = opts[:book_id]

    with :ok <- Chats.authorize(scope, chat, :manage),
         scope = Chats.run_scope(scope, chat),
         :ok <- if(title == "", do: {:error, :no_title}, else: :ok),
         :ok <- if(length(ids) < 2, do: {:error, :too_few}, else: :ok),
         {:ok, clips} <- combine_sources(scope, book_id, ids),
         {:ok, profile} <- Memory.profile_for(scope, chat),
         {:ok, model} <- Memory.model_for(scope, chat, profile),
         {:ok, prompt} <- combine_clips_prompt(scope, profile.combine_clips_prompt_id) do
      keywords =
        clips
        |> Enum.flat_map(& &1.entry.keywords)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
        |> case do
          [] -> [title]
          keywords -> keywords
        end

      Jobs.enqueue(scope, :topical_clip, %{
        origin: :interactive,
        chat_id: chat.id,
        label:
          dpgettext("memory", "heading: job that combines topical clips", "Combine clips — %{clip_title}",
            clip_title: title
          ),
        ai_model_id: model.id,
        params: %{
          "combine" => true,
          "chat_id" => chat.id,
          "profile_id" => profile.id,
          "prompt_id" => prompt.id,
          "book_id" => book_id,
          "topic" => title,
          "keywords" => keywords,
          "source_ids" => ids,
          "source_fingerprints" => Map.new(clips, &{&1.id, Scene.sha256(&1.entry.content)}),
          "disable_originals" => opts[:disable_originals] != false,
          "review" => true,
          "snapshot" => %{
            "topic" => title,
            "combined_from" => ids,
            "sources" => Enum.reduce(clips, %{}, &Map.merge(&2, &1.snapshot["sources"] || %{}))
          }
        }
      })
    end
  end

  defp combine_sources(scope, book_id, ids) do
    if Memory.authorize_book(scope, book_id) == :ok do
      by_id = Map.new(book_topical_clips(book_id), &{&1.id, &1})
      clips = Enum.map(ids, &by_id[&1])
      if nil in clips, do: {:error, :not_found}, else: {:ok, clips}
    else
      {:error, :not_found}
    end
  end

  # Creates the topical clip's entry and record, or rewrites the target in place when it is unchanged
  # since the job was queued.
  @doc false
  @spec save_topical_clip(Scope.t(), Job.t(), String.t() | nil) :: {:ok, Record.t()} | {:error, term()}
  def save_topical_clip(%Scope{} = scope, %Job{params: params} = job, content) do
    with {:ok, content} <- Memory.non_blank(content),
         %Chat{} = chat <- Chats.get_chat(params["chat_id"]) || {:error, :no_chat},
         :ok <- Chats.authorize(scope, chat, :manage),
         scope = Chats.run_scope(scope, chat),
         {:ok, record} <-
           Jobs.complete_in_transaction(job, fn ->
             record = save_topical_clip_tx(scope, chat, params, content)
             {record, Map.put(job.result || %{}, "record_id", record.id)}
           end) do
      Memory.broadcast_changed(chat.id)
      {:ok, record}
    end
    |> Memory.invalid_changeset()
  end

  defp save_topical_clip_tx(scope, chat, params, content) do
    entry_attrs = %{name: params["topic"], content: content, keywords: params["keywords"], activation: :keyword}
    snapshot = params["snapshot"]

    record_attrs = %{
      chat_id: chat.id,
      kind: :topical_clip,
      range_start: snapshot["messages"] && snapshot["messages"]["start"],
      range_end: snapshot["messages"] && snapshot["messages"]["end"],
      profile_id: params["profile_id"],
      prompt_id: params["prompt_id"],
      snapshot: snapshot
    }

    case params["target_record_id"] do
      nil ->
        sources = if params["combine"], do: lock_combine_sources!(params), else: []

        book =
          Memory.get_owned(Ownership.editable(LoreBook, scope), params["book_id"]) || Memory.ensure_book(scope, chat)

        entry = Gate.unmoderated(fn -> Lore.create_entry(scope, entry_attrs, [book.id]) end) |> Repo.ok_or_rollback()

        record =
          %Record{}
          |> Record.changeset(
            Map.merge(record_attrs, %{
              lore_entry_id: entry.id,
              lore_book_id: book.id,
              written_fingerprint: Scene.sha256(entry.content)
            })
          )
          |> Repo.insert()
          |> Repo.ok_or_rollback()

        if params["disable_originals"],
          do: Lore.set_memberships_enabled(Enum.map(sources, &{&1.lore_book_id, &1.lore_entry_id}), false)

        delete_topic_suggestion!(params["suggestion_id"])
        record

      id ->
        record = Memory.lock_record!(id, :topical_clip, :changed)
        if !Memory.entry_unchanged?(record.entry, params), do: Repo.rollback(:changed)
        entry = Gate.unmoderated(fn -> Lore.update_entry(scope, record.entry, entry_attrs) end) |> Repo.ok_or_rollback()

        record
        |> Record.changeset(Map.put(record_attrs, :written_fingerprint, Scene.sha256(entry.content)))
        |> Repo.update()
        |> Repo.ok_or_rollback()
    end
  end

  # A combination's source clips, locked: each must still exist unchanged since the job was queued.
  defp lock_combine_sources!(params) do
    ids = params["source_ids"]

    sources =
      Repo.all(from(r in Record, where: r.id in ^ids and r.kind == :topical_clip, lock: "FOR UPDATE", preload: :entry))

    by_id = Map.new(sources, &{&1.id, &1})

    if !Enum.all?(ids, &(by_id[&1] && Scene.sha256(by_id[&1].entry.content) == params["source_fingerprints"][&1])),
      do: Repo.rollback(:changed)

    sources
  end

  defp delete_topic_suggestion!(nil), do: :ok

  defp delete_topic_suggestion!(id) do
    Repo.delete_all(from(s in TopicSuggestion, where: s.id == ^id))
    :ok
  end

  ## Memory Assistance

  @doc "The `:clip` and `:topical_clip` records of `book_id` whose membership there is enabled, with entries, by name."
  @spec assistance_clips(Ecto.UUID.t()) :: [Record.t()]
  def assistance_clips(book_id) do
    Repo.all(
      from(r in Record,
        join: be in BookEntry,
        on: be.lore_book_id == r.lore_book_id and be.lore_entry_id == r.lore_entry_id,
        join: e in assoc(r, :entry),
        where: r.lore_book_id == ^book_id and r.kind in [:clip, :topical_clip] and be.enabled,
        order_by: [asc: e.name, asc: r.id],
        preload: [entry: e]
      )
    )
  end

  @doc """
  Queues Memory Assistance for a newly saved scene memory `record`, by `memory.assistance_mode`: a
  topic-suggestions job (`"pass" => "suggest"`) first when suggesting, then one clip-review job
  (`"pass" => "review"`) per token batch of the book's enabled clips when updating. Failures are
  logged; always `:ok`.
  """
  @spec enqueue_assistance(Scope.t(), Chat.t(), Record.t(), [Ecto.UUID.t()], Ecto.UUID.t() | nil) :: :ok
  def enqueue_assistance(%Scope{} = scope, %Chat{} = chat, %Record{} = record, message_ids, parent_id) do
    prefs = Memory.preferences(scope)
    mode = to_string(prefs.assistance_mode || :off)

    if mode != "off" do
      with {:ok, profile} <- Memory.profile_for(scope, chat),
           {:ok, model} <- Memory.model_for(scope, chat, profile),
           %LoreBook{} = book <- Repo.get(LoreBook, record.lore_book_id) || {:error, :no_book} do
        clips = assistance_clips(book.id)

        base = %{
          origin: :background,
          chat_id: chat.id,
          ai_model_id: model.id,
          range_start: record.range_start,
          range_end: record.range_end,
          parent_id: parent_id
        }

        params = %{
          "chat_id" => chat.id,
          "profile_id" => profile.id,
          "book_id" => book.id,
          "record_id" => record.id,
          "start" => record.range_start,
          "end" => record.range_end,
          "message_ids" => message_ids,
          "mode" => mode
        }

        if mode in ~w(suggest update_and_suggest) do
          with {:ok, prompt} <- clip_suggestions_prompt(scope, profile.clip_suggestions_prompt_id) do
            topical_ids = for r <- clips, r.kind == :topical_clip, do: r.id
            p = Map.merge(params, %{"pass" => "suggest", "prompt_id" => prompt.id, "clip_ids" => topical_ids})

            Jobs.enqueue(
              scope,
              :memory_assistance,
              Map.merge(base, %{label: assistance_job_label(scope, :suggest, book), params: p})
            )
          end
          |> log_assistance(chat)
        end

        if mode in ~w(update update_and_suggest automatic) and clips != [] do
          case clip_review_prompt(scope, profile.clip_review_prompt_id) do
            {:ok, prompt} ->
              clips
              |> Consolidation.batches(length(clips), prefs.consolidation_token_budget, model)
              |> Enum.each(fn batch ->
                p =
                  Map.merge(params, %{
                    "pass" => "review",
                    "prompt_id" => prompt.id,
                    "clip_ids" => Enum.map(batch, & &1.id),
                    "fingerprints" => Map.new(batch, &{&1.id, Scene.sha256(&1.entry.content)})
                  })

                scope
                |> Jobs.enqueue(
                  :memory_assistance,
                  Map.merge(base, %{label: assistance_job_label(scope, :update, book), params: p})
                )
                |> log_assistance(chat)
              end)

            error ->
              log_assistance(error, chat)
          end
        end
      else
        error -> log_assistance(error, chat)
      end
    end

    :ok
  end

  defp log_assistance({:ok, _job}, _chat), do: :ok

  defp log_assistance(error, chat),
    do: Logger.warning("Memory assistance for chat #{chat.id} not started: #{inspect(error)}")

  @doc """
  Writes a `:memory_assistance` job's kept `candidates` and completes it, in one transaction: an
  ordinary clip gains the candidate's line; a topical clip's content becomes the candidate's text,
  only while it is as the job saw it (else `{:error, :changed}`). Each `{topic, keywords}` of
  `topics` is stored as a pending `TopicSuggestion` for the job's book in the same transaction (a
  topic already pending for the book is kept as is). Returns the number of candidates written.
  """
  @spec save_assistance(Scope.t(), Job.t(), [map()], [{String.t(), [String.t()]}]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def save_assistance(%Scope{} = scope, %Job{tag: :memory_assistance} = job, candidates, topics \\ []) do
    with %Chat{} = chat <- Chats.get_chat(job.params["chat_id"]) || {:error, :no_chat},
         :ok <- Chats.authorize(scope, chat, :manage),
         scope = Chats.run_scope(scope, chat),
         {:ok, n} <-
           Jobs.complete_in_transaction(job, fn ->
             n = write_assistance!(scope, chat, job, candidates)
             insert_topic_suggestions!(chat, job, topics)
             {n, %{"applied" => n + ((job.result || %{})["applied"] || 0)}}
           end) do
      Memory.broadcast_changed(chat.id)
      {:ok, n}
    end
    |> Memory.invalid_changeset()
  end

  @doc """
  Automatic mode with topical candidates still to review: writes the ordinary `candidates` now, in
  their own transaction, and leaves the job running. Returns the number written.
  """
  @spec apply_clip_additions(Scope.t(), Job.t(), [map()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def apply_clip_additions(%Scope{} = scope, %Job{tag: :memory_assistance} = job, candidates) do
    with %Chat{} = chat <- Chats.get_chat(job.params["chat_id"]) || {:error, :no_chat},
         :ok <- Chats.authorize(scope, chat, :manage),
         scope = Chats.run_scope(scope, chat),
         {:ok, n} <- Repo.transaction(fn -> write_assistance!(scope, chat, job, candidates) end) do
      Memory.broadcast_changed(chat.id)
      {:ok, n}
    end
    |> Memory.invalid_changeset()
  end

  defp write_assistance!(scope, chat, job, candidates) do
    Enum.each(candidates, fn
      %{"type" => "ordinary", "record_id" => id, "text" => text} ->
        save_clip_tx(scope, chat, Repo.ok_or_rollback(clip_line(text)), {:existing, id})

      %{"type" => "topical", "record_id" => id, "text" => text} ->
        record = Memory.lock_record!(id, :topical_clip, :changed)
        if Scene.sha256(record.entry.content) != job.params["fingerprints"][id], do: Repo.rollback(:changed)
        if String.trim(text || "") == "", do: Repo.rollback(:empty)
        Memory.rewrite_content!(scope, record, text)
    end)

    length(candidates)
  end

  @doc false
  def approve_assistance(scope, %Job{} = job, edited) do
    with {:ok, edits} <- Memory.edited_candidates(edited["candidates"] || %{}),
         {:ok, topics} <- edited_topics(edited["topics"] || %{}) do
      candidates =
        for {candidate, i} <- Enum.with_index(job.result["candidates"] || []),
            edit <- [Map.get(edits, i, %{})],
            edit["keep"] not in [false, "false"],
            do: if(is_binary(edit["text"]), do: %{candidate | "text" => edit["text"]}, else: candidate)

      commit_assistance(scope, job, candidates, topics)
    end
  end

  defp commit_assistance(scope, %Job{params: params} = job, candidates, topics) do
    with %Chat{} = chat <- Chats.get_chat(params["chat_id"]) || {:error, :no_chat},
         :ok <- Chats.authorize(scope, chat, :manage),
         :ok <- topics_prompt_ready(scope, chat, topics),
         {:ok, _n} <- save_assistance(scope, job, candidates, topics) do
      chat
      |> pending_suggestions(params["book_id"], Enum.map(topics, &elem(&1, 0)))
      |> Enum.each(fn suggestion ->
        with {:error, reason} <- draft_suggestion(scope, chat, suggestion),
             do: Logger.warning("Topical clip draft for suggestion #{suggestion.id} not queued: #{inspect(reason)}")
      end)

      {:ok, job}
    end
  end

  defp topics_prompt_ready(_scope, _chat, []), do: :ok

  defp topics_prompt_ready(scope, chat, _topics) do
    with {:ok, profile} <- Memory.profile_for(scope, chat),
         {:ok, _prompt} <- topical_clip_prompt(scope, profile.topical_clip_prompt_id),
         do: :ok
  end

  # Stores each `{topic, keywords}` as pending for the job's book, unless the book already has it
  # pending. The memory may be gone by now (a rollback): the suggestion then keeps only its scene.
  defp insert_topic_suggestions!(_chat, _job, []), do: :ok

  defp insert_topic_suggestions!(chat, %Job{params: params} = job, topics) do
    book_id = params["book_id"]
    if !Repo.exists?(from(b in LoreBook, where: b.id == ^book_id)), do: Repo.rollback(:not_found)
    record_id = params["record_id"]
    record_id = if record_id && Repo.exists?(from(r in Record, where: r.id == ^record_id)), do: record_id

    Enum.each(topics, fn {topic, keywords} ->
      Repo.insert!(
        %TopicSuggestion{
          chat_id: chat.id,
          lore_book_id: book_id,
          topic: topic,
          keywords: keywords,
          record_id: record_id,
          message_ids: params["message_ids"] || [],
          job_id: job.id
        },
        on_conflict: :nothing,
        conflict_target: {:unsafe_fragment, "(lore_book_id, lower(topic))"}
      )
    end)
  end

  # The chat's pending suggestions for `book_id` among `topics` (case-insensitively), oldest first.
  defp pending_suggestions(_chat, _book_id, []), do: []

  defp pending_suggestions(chat, book_id, topics) do
    lowered = Enum.map(topics, &String.downcase/1)

    Repo.all(
      from(s in TopicSuggestion,
        where: s.chat_id == ^chat.id and s.lore_book_id == ^book_id,
        where: fragment("lower(?)", s.topic) in type(^lowered, {:array, :string}),
        order_by: [asc: s.inserted_at, asc: s.id]
      )
    )
  end

  @doc """
  The chat's pending topic suggestions, oldest first, with `:book` preloaded and the virtual
  `drafting?` set when a `:topical_clip` draft for the suggestion is queued, running or in review.
  """
  @spec list_topic_suggestions(Scope.t(), Chat.t()) :: [TopicSuggestion.t()]
  def list_topic_suggestions(%Scope{} = scope, %Chat{} = chat) do
    case Chats.authorize(scope, chat, :inspect) do
      :ok ->
        suggestions =
          Repo.all(
            from(s in TopicSuggestion,
              where: s.chat_id == ^chat.id,
              order_by: [asc: s.inserted_at, asc: s.id],
              preload: :book
            )
          )

        drafting = suggestions_drafting(chat, Enum.map(suggestions, & &1.id))
        Enum.map(suggestions, &%{&1 | drafting?: MapSet.member?(drafting, &1.id)})

      _error ->
        []
    end
  end

  # The ids among `ids` with a topical clip draft in flight.
  defp suggestions_drafting(_chat, []), do: MapSet.new()

  defp suggestions_drafting(chat, ids) do
    from(j in Job,
      where: j.chat_id == ^chat.id and j.tag == :topical_clip and j.status in [:queued, :running, :review],
      where: fragment("?->>'suggestion_id'", j.params) in type(^ids, {:array, :string}),
      select: fragment("?->>'suggestion_id'", j.params)
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Queues a topical clip draft for the chat's pending suggestion `id`, from the memory and scene
  that prompted it; saving the draft removes the suggestion. `{:error, :busy}` while a draft for it
  is queued, running or in review; `{:error, :not_found}` for a missing id or another chat's.
  Otherwise as `topical_clip/3`.
  """
  @spec draft_topic_suggestion(Scope.t(), Chat.t(), Ecto.UUID.t()) :: {:ok, Job.t()} | {:error, term()}
  def draft_topic_suggestion(%Scope{} = scope, %Chat{} = chat, id) do
    with :ok <- Chats.authorize(scope, chat, :manage),
         %TopicSuggestion{} = suggestion <- get_topic_suggestion(chat, id) || {:error, :not_found},
         do: draft_suggestion(scope, chat, suggestion)
  end

  defp draft_suggestion(scope, chat, %TopicSuggestion{} = suggestion) do
    if MapSet.member?(suggestions_drafting(chat, [suggestion.id]), suggestion.id) do
      {:error, :busy}
    else
      topical_clip(scope, chat,
        topic: suggestion.topic,
        keywords: if(suggestion.keywords == [], do: [suggestion.topic], else: suggestion.keywords),
        book_id: suggestion.lore_book_id,
        include_memories: suggestion.record_id != nil,
        record_ids: List.wrap(suggestion.record_id),
        include_messages: suggestion.message_ids != [],
        message_ids: suggestion.message_ids,
        suggestion_id: suggestion.id
      )
    end
  end

  @doc "Deletes the chat's pending suggestion `id`; `{:error, :not_found}` for a missing id or another chat's."
  @spec dismiss_topic_suggestion(Scope.t(), Chat.t(), Ecto.UUID.t()) :: :ok | {:error, :not_found | :unauthorized}
  def dismiss_topic_suggestion(%Scope{} = scope, %Chat{} = chat, id) do
    with :ok <- Chats.authorize(scope, chat, :manage),
         %TopicSuggestion{} = suggestion <- get_topic_suggestion(chat, id) || {:error, :not_found} do
      Repo.delete!(suggestion)
      Memory.broadcast_changed(chat.id)
      :ok
    end
  end

  defp get_topic_suggestion(chat, id),
    do: Memory.get_owned(from(s in TopicSuggestion, where: s.chat_id == ^chat.id), id)

  # The assistance form's topics, keyed by index plus `"new"` (sorted last), as `{topic, keywords}`
  # in form order; blank and unkept topics are dropped. A key that is neither is `{:error, :invalid}`.
  defp edited_topics(%{} = topics) do
    Enum.reduce_while(topics, {:ok, []}, fn {key, t}, {:ok, acc} ->
      case if(key == "new", do: {:ok, :infinity}, else: Memory.form_index(key)) do
        {:ok, order} -> {:cont, {:ok, [{order, key, t} | acc]}}
        :error -> {:halt, {:error, :invalid}}
      end
    end)
    |> case do
      {:ok, keyed} ->
        {:ok,
         keyed
         |> Enum.sort_by(&elem(&1, 0))
         |> Enum.flat_map(fn {_order, key, t} -> edited_topic(key, t) end)}

      error ->
        error
    end
  end

  defp edited_topics(_none), do: {:error, :invalid}

  defp edited_topic(key, %{} = t) do
    topic = String.trim(t["topic"] || "")

    if topic == "" or (key != "new" and t["keep"] in [false, "false"]) do
      []
    else
      [{topic, JSON.keywords(t["keywords"])}]
    end
  end

  defp edited_topic(_key, _t), do: []

  defp assistance_job_label(scope, :suggest, book) do
    Mythweaver.Locale.with_user_locale(scope, fn ->
      dpgettext("memory", "heading: job that suggests topical clips for a book", "Topic suggestions — %{book_name}",
        book_name: book.name
      )
    end)
  end

  defp assistance_job_label(scope, :update, book) do
    Mythweaver.Locale.with_user_locale(scope, fn ->
      dpgettext("memory", "heading: job that updates the clips of a book", "Memory assistance — %{book_name}",
        book_name: book.name
      )
    end)
  end
end
