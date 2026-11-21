defmodule Mythweaver.Memory.Consolidation do
  @moduledoc """
  Consolidation of memories into higher tiers (Arc … Epic): which records may be consolidated, how
  they are cut into batches, when a watched tier is ready, and running and saving consolidation
  jobs (`consolidate/6`, `save_consolidation/4`, `regenerate_candidate/3`).
  """

  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Query, warn: false

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI.Model
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Format
  alias Mythweaver.Jobs
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Lore
  alias Mythweaver.Lore.BookEntry
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Memory
  alias Mythweaver.Memory.ChatSettings
  alias Mythweaver.Memory.JSON
  alias Mythweaver.Memory.Profile
  alias Mythweaver.Memory.Record
  alias Mythweaver.Memory.RecordSource
  alias Mythweaver.Memory.Scene
  alias Mythweaver.Memory.Tiers
  alias Mythweaver.Memory.Title
  alias Mythweaver.Memory.Workers
  alias Mythweaver.Notifications
  alias Mythweaver.Prompts.Prompt
  alias Mythweaver.Repo
  alias Mythweaver.Tokenizer

  @pubsub Mythweaver.PubSub

  @doc """
  The records of `book` a `target_tier` consolidation may use: one tier below, not consolidated yet,
  with their entry enabled in the record's book, in the book's entry order (imported records have no
  `range_start`, so only the book's order puts them among generated ones). Shared copies
  (`Record.without_shared_copies/1`) are left out: they go with their canonical. Entries are
  preloaded. `[]` when the scope may not act on the book's chat.
  """
  @spec eligible(Scope.t(), LoreBook.t() | Ecto.UUID.t(), 1..6) :: [Record.t()]
  def eligible(%Scope{} = scope, %LoreBook{id: book_id}, target_tier), do: eligible(scope, book_id, target_tier)

  def eligible(%Scope{} = scope, book_id, target_tier) when is_binary(book_id) and target_tier in 1..6 do
    if Memory.authorize_book(scope, book_id) == :ok, do: Repo.all(eligible_query(book_id, target_tier)), else: []
  end

  defp eligible_query(book_id, target_tier) do
    from([r, e, be] in eligible_base(book_id),
      where: r.tier == ^(target_tier - 1),
      order_by: [asc: be.order, asc_nulls_last: r.range_start, asc: r.sequence, asc: r.inserted_at],
      preload: [entry: e]
    )
  end

  # Unconsolidated memories and consolidations of `book_id` enabled in it, of any tier.
  defp eligible_base(book_id) do
    from(r in Record,
      join: e in assoc(r, :entry),
      join: be in BookEntry,
      on: be.lore_book_id == r.lore_book_id and be.lore_entry_id == r.lore_entry_id,
      where: r.lore_book_id == ^book_id,
      where: r.kind in [:memory, :consolidation] and is_nil(r.consolidated_into_id) and be.enabled
    )
    |> Record.without_shared_copies()
  end

  @doc """
  Cuts `records` (entries preloaded), in order, into consecutive groups of at most `max_entries`
  records and `token_budget` entry-content tokens (counted with `model`'s tokenizer). A record over
  the budget on its own forms its own group.
  """
  @spec batches([Record.t()], pos_integer(), pos_integer(), Model.t() | nil) :: [[Record.t()]]
  def batches(records, max_entries, token_budget, model) do
    records
    |> Enum.reduce({[], [], 0}, fn record, {groups, group, tokens} ->
      {n, _exact} = Tokenizer.count(model, record.entry.content)

      if group != [] and (length(group) >= max_entries or tokens + n > token_budget),
        do: {[Enum.reverse(group) | groups], [record], n},
        else: {groups, [record | group], tokens + n}
    end)
    |> then(fn
      {groups, [], _tokens} -> groups
      {groups, group, _tokens} -> [Enum.reverse(group) | groups]
    end)
    |> Enum.reverse()
  end

  @doc """
  The watched tiers (`preferences.consolidation_watch_tiers`) of `book` with at least their
  `consolidation_minimums` of eligible sources.
  """
  @spec ready_tiers(Scope.t(), LoreBook.t() | Ecto.UUID.t() | nil) :: [1..6]
  def ready_tiers(%Scope{}, nil), do: []
  def ready_tiers(%Scope{} = scope, %LoreBook{id: book_id}), do: ready_tiers(scope, book_id)

  def ready_tiers(%Scope{} = scope, book_id) do
    if Memory.authorize_book(scope, book_id) == :ok, do: book_ready_tiers(scope, book_id), else: []
  end

  defp book_ready_tiers(scope, book_id) do
    prefs = Memory.preferences(scope)

    case Enum.sort(prefs.consolidation_watch_tiers) do
      [] ->
        []

      tiers ->
        counts =
          from(r in eligible_base(book_id),
            where: r.tier in ^Enum.map(tiers, &(&1 - 1)),
            group_by: r.tier,
            select: {r.tier, count(r.id)}
          )
          |> Repo.all()
          |> Map.new()

        Enum.filter(tiers, &(Map.get(counts, &1 - 1, 0) >= Map.get(prefs.consolidation_minimums, to_string(&1), 1)))
    end
  end

  @doc """
  Announces each ready tier of `book` (`ready_tiers/1`) as `{:consolidation_ready, %{book_id:, tier:}}`
  on the memory topic of every chat of `scope`'s user whose memory book it is: the saves that call it
  run as the chat's owner, so another owner's chat on the same book hears nothing. The user's inbox
  keeps each ready tier until it no longer is (`Notifications.consolidation_ready/4`, opening the
  most recently active of those chats). Nothing is consolidated here.
  """
  @spec check_ready(Scope.t(), LoreBook.t() | nil) :: :ok
  def check_ready(%Scope{}, nil), do: :ok

  def check_ready(%Scope{user: %{id: owner_id}} = scope, %LoreBook{id: book_id} = book) do
    tiers = ready_tiers(scope, book)

    chats =
      if tiers == [] do
        []
      else
        Repo.all(
          from(s in ChatSettings,
            join: c in Chat,
            on: c.id == s.chat_id,
            where: s.memory_book_id == ^book_id and c.user_id == ^owner_id,
            order_by: [desc_nulls_last: c.last_activity_at, desc: c.id],
            select: c
          )
        )
      end

    for chat <- chats, tier <- tiers do
      Phoenix.PubSub.broadcast(@pubsub, Memory.topic(chat.id), {:consolidation_ready, %{book_id: book_id, tier: tier}})
    end

    Notifications.consolidation_ready(scope, book, List.first(chats), tiers)
  end

  # No user: nothing it could consolidate.
  def check_ready(%Scope{}, %LoreBook{}), do: :ok

  @doc "The `:consolidation` prompt `id`: `{:error, :no_prompt}` when missing or of another purpose."
  @spec consolidation_prompt(Scope.t(), Ecto.UUID.t() | nil) :: {:ok, Prompt.t()} | {:error, :no_prompt}
  def consolidation_prompt(%Scope{} = scope, id), do: Memory.purpose_prompt(scope, id, :consolidation)

  @doc """
  Queues consolidations of `record_ids` from `book` into `target_tier` (1..6), one `:consolidation`
  job per batch (`Consolidation.batches/4`). Every id must be eligible (`Consolidation.eligible/2`).

  `opts`: `:prompt_id` (default the profile's consolidation prompt), `:disable_sources` (default
  true), `:max_entries` (default `memory.consolidation_max_entries`), `:token_budget` (default
  `memory.consolidation_token_budget`) and `:review` (default `prefs.show_consolidation_previews`).
  """
  @spec consolidate(Scope.t(), Chat.t(), LoreBook.t(), 1..6, [Ecto.UUID.t()], keyword()) ::
          {:ok, [Job.t()]}
          | {:error,
             :no_profile | :no_model | :ambiguous_model | :no_prompt | :no_sources | :ineligible | :unauthorized}
  def consolidate(%Scope{} = scope, %Chat{} = chat, %LoreBook{} = book, target_tier, record_ids, opts \\ [])
      when target_tier in 1..6 do
    with :ok <- Chats.authorize(scope, chat, :manage),
         do: do_consolidate(Chats.run_scope(scope, chat), chat, book, target_tier, record_ids, opts)
  end

  defp do_consolidate(scope, chat, book, target_tier, record_ids, opts) do
    eligible = eligible(scope, book, target_tier)
    eligible_ids = MapSet.new(eligible, & &1.id)
    wanted = MapSet.new(record_ids)

    with {:ok, profile} <- Memory.profile_for(scope, chat),
         {:ok, model} <- Memory.model_for(scope, chat, profile),
         {:ok, prompt} <- consolidation_prompt(scope, opts[:prompt_id] || profile.consolidation_prompt_id),
         :ok <- if(record_ids == [], do: {:error, :no_sources}, else: :ok),
         :ok <- if(MapSet.subset?(wanted, eligible_ids), do: :ok, else: {:error, :ineligible}) do
      prefs = Memory.preferences(scope)

      attrs = %{
        "disable_sources" => Keyword.get(opts, :disable_sources, true),
        "review" => Keyword.get(opts, :review, prefs.show_consolidation_previews)
      }

      eligible
      |> Enum.filter(&MapSet.member?(wanted, &1.id))
      |> batches(
        opts[:max_entries] || prefs.consolidation_max_entries,
        opts[:token_budget] || prefs.consolidation_token_budget,
        model
      )
      |> Memory.collect_ok(&enqueue_consolidation(scope, chat, book, profile, {model, prompt}, target_tier, &1, attrs))
    end
  end

  @doc false
  def enqueue_consolidation(scope, chat, book, profile, {model, prompt}, tier, sources, attrs) do
    params =
      Map.merge(attrs, %{
        "chat_id" => chat.id,
        "profile_id" => profile.id,
        "book_id" => book.id,
        "prompt_id" => prompt.id,
        "target_tier" => tier,
        "source_ids" => Enum.map(sources, & &1.id),
        "source_versions" => Map.new(sources, &{&1.id, DateTime.to_iso8601(&1.entry.updated_at)}),
        "source_fingerprints" => Map.new(sources, &{&1.id, Scene.sha256(&1.entry.content)})
      })

    Jobs.enqueue(scope, :consolidation, %{
      origin: :interactive,
      chat_id: chat.id,
      label: consolidation_job_label(tier, length(sources)),
      ai_model_id: model.id,
      params: params,
      range_start: sources |> Enum.map(& &1.range_start) |> Enum.reject(&is_nil/1) |> Enum.min(fn -> nil end),
      range_end: sources |> Enum.map(& &1.range_end) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end)
    })
  end

  @doc """
  A consolidation job's source records, entries preloaded, in batch order.
  `{:error, :source_missing}` when any has been deleted.
  """
  @spec consolidation_sources(map()) :: {:ok, [Record.t()]} | {:error, :source_missing}
  def consolidation_sources(%{"source_ids" => ids}) do
    sources = Workers.records(ids)
    if ids == [] or nil in sources, do: {:error, :source_missing}, else: {:ok, sources}
  end

  @doc """
  Saves a `:consolidation` job's `candidates` (`"title"`, `"summary"`, `"keywords"`, `"source_ids"`),
  in one transaction: an entry and a tier record per candidate, each source linked and marked
  consolidated (and switched off in its own book with `disable_sources`). A source claimed by two candidates
  stays with the first; ids outside the job's sources are ignored.

  A regeneration (`params["record_id"]`) rewrites that record's entry in place from the first
  candidate, keeping its sequence; `{:error, :unauthorized}` unless the record is this chat's, in a
  book `scope` may edit. `{:error, :changed}` when a source was edited, deleted or consolidated
  elsewhere since the job was queued.

  `unassigned` (`%{"record_id", "reason"}` maps) is stored on the completed job; when non-empty,
  `{:consolidation_left_out, %{book_id:, count:}}` is broadcast on `topic/1`.
  """
  @spec save_consolidation(Scope.t(), Job.t(), [map()], [map()]) :: {:ok, [Record.t()]} | {:error, term()}
  def save_consolidation(%Scope{} = scope, %Job{params: params} = job, candidates, unassigned \\ []) do
    with {:ok, drafts} <- consolidation_drafts(params, candidates),
         %Chat{} = chat <- Chats.get_chat(params["chat_id"]) || {:error, :no_chat},
         :ok <- Chats.authorize(scope, chat, :manage),
         scope = Chats.run_scope(scope, chat),
         %Profile{} = profile <- Memory.get_profile(scope, params["profile_id"]) || {:error, :no_profile},
         %LoreBook{} = book <- Repo.get(LoreBook, params["book_id"]) || {:error, :no_book},
         {:ok, records} <-
           Jobs.complete_in_transaction(job, fn ->
             records = save_consolidation_tx(scope, job, chat, profile, book, drafts)
             {records, %{"record_ids" => Enum.map(records, & &1.id), "unassigned" => unassigned}}
           end) do
      Memory.broadcast_changed(chat.id)

      if unassigned != [] do
        Phoenix.PubSub.broadcast(
          @pubsub,
          Memory.topic(chat.id),
          {:consolidation_left_out, %{book_id: book.id, count: length(unassigned)}}
        )
      end

      check_ready(scope, book)
      {:ok, records}
    end
    |> Memory.invalid_changeset()
  end

  @doc """
  Queues a one-summary regeneration of candidate `index` of a `:consolidation` job in review, over
  that candidate's sources. The child job replaces the candidate in place (`replace_candidate/3`).
  """
  @spec regenerate_candidate(Scope.t(), Job.t(), non_neg_integer()) :: {:ok, Job.t()} | {:error, term()}
  def regenerate_candidate(%Scope{} = scope, %Job{tag: :consolidation, status: :review} = job, index)
      when is_integer(index) and index >= 0 do
    params = job.params

    with :ok <- Chats.authorize(scope, job.chat_id, :manage),
         scope = Chats.run_scope(scope, job.chat_id),
         %{} = candidate <- Enum.at(job.result["candidates"] || [], index) || {:error, :not_found},
         {:ok, sources} <- consolidation_sources(%{"source_ids" => candidate["source_ids"] || []}),
         %Chat{} = chat <- Chats.get_chat(params["chat_id"]) || {:error, :no_chat},
         %Profile{} = profile <- Memory.get_profile(scope, params["profile_id"]) || {:error, :no_profile},
         %LoreBook{} = book <- Repo.get(LoreBook, params["book_id"]) || {:error, :no_book},
         {:ok, model} <- Memory.model_for(scope, chat, profile),
         {:ok, prompt} <- consolidation_prompt(scope, params["prompt_id"]) do
      enqueue_consolidation(scope, chat, book, profile, {model, prompt}, params["target_tier"], sources, %{
        "replace" => %{"job_id" => job.id, "index" => index},
        "review" => false,
        "disable_sources" => params["disable_sources"]
      })
    end
  end

  def regenerate_candidate(%Scope{}, %Job{}, _index), do: {:error, :not_found}

  @doc """
  Completes a candidate-regeneration `child_job` by writing `candidate` over its parent review's
  candidate, keeping the old `source_ids`. `{:error, :changed}` when the parent left review or the
  candidate's sources changed.
  """
  @spec replace_candidate(Scope.t(), Job.t(), map()) :: {:ok, map()} | {:error, term()}
  def replace_candidate(%Scope{}, %Job{params: %{"replace" => replace} = params} = child_job, candidate) do
    %{"job_id" => parent_id, "index" => index} = replace

    result =
      Jobs.complete_in_transaction(child_job, fn ->
        Jobs.update_review_result(parent_id, fn result ->
          candidates = result["candidates"] || []
          old = Enum.at(candidates, index)

          if is_nil(old) or old["source_ids"] != params["source_ids"], do: Repo.rollback(:changed)

          %{
            result
            | "candidates" => List.replace_at(candidates, index, Map.put(candidate, "source_ids", old["source_ids"]))
          }
        end)

        {%{"replaced" => index}, %{"replaced" => index}}
      end)

    with {:ok, value} <- result do
      Memory.broadcast_changed(child_job.chat_id)
      {:ok, value}
    end
  end

  defp consolidation_drafts(params, candidates) do
    allowed = params["source_ids"] || []

    candidates
    |> Enum.reduce_while({[], MapSet.new()}, fn candidate, {drafts, claimed} ->
      ids = Enum.filter(allowed, &(&1 in List.wrap(candidate["source_ids"]) and not MapSet.member?(claimed, &1)))

      case JSON.memory(%{
             "title" => candidate["title"],
             "content" => candidate["summary"],
             "keywords" => candidate["keywords"]
           }) do
        {:ok, _draft} when ids == [] -> {:cont, {drafts, claimed}}
        {:ok, draft} -> {:cont, {[Map.put(draft, "source_ids", ids) | drafts], MapSet.union(claimed, MapSet.new(ids))}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      {[], _claimed} -> {:error, :nothing_kept}
      {drafts, _claimed} -> {:ok, Enum.reverse(drafts)}
    end
  end

  defp save_consolidation_tx(scope, job, chat, profile, book, drafts) do
    params = job.params
    tier = params["target_tier"]
    regenerated = Memory.regenerated_record(scope, chat, :consolidation, params)
    claimed = drafts |> Enum.flat_map(& &1["source_ids"]) |> Enum.uniq()
    sources = locked_sources!(params, if(job.status == :running, do: params["source_ids"], else: claimed))
    by_id = Map.new(sources, &{&1.id, &1})

    if regenerated && regenerated.consolidated_into_id, do: Repo.rollback(:changed)

    case regenerated do
      nil ->
        Enum.map(drafts, fn draft ->
          its_sources = Enum.map(draft["source_ids"], &by_id[&1])
          sequence = Memory.next_tier_sequence(book, tier)

          entry =
            Memory.write_entry(
              scope,
              nil,
              book,
              profile,
              consolidation_attrs(chat, profile, draft, its_sources, tier, sequence),
              sequence,
              []
            )

          record =
            %Record{}
            |> Record.changeset(consolidation_record_attrs(chat, book, profile, params, entry, its_sources, sequence))
            |> Repo.insert()
            |> Repo.ok_or_rollback()

          Enum.each(its_sources, &consolidate_source!(&1, record, params["disable_sources"]))
          record
        end)

      %Record{} = record ->
        [draft | _] = drafts
        attrs = consolidation_attrs(chat, profile, draft, sources, record.tier, record.sequence)
        entry = Memory.write_entry(scope, record, book, profile, attrs, record.sequence, [])

        record =
          record
          |> Record.changeset(%{written_fingerprint: Scene.sha256(entry.content), prompt_id: params["prompt_id"]})
          |> Repo.update()
          |> Repo.ok_or_rollback()

        [record]
    end
  end

  # Locked so a concurrent save cannot consolidate one twice, and compared with the versions captured
  # at enqueue. An unattended save (the worker's own, `review: false`) checks every source the model
  # read, since no one looked at the draft; an approval, attended, checks only the sources its kept
  # drafts claim. A regeneration's sources are already consolidated into its record.
  defp locked_sources!(params, ids) do
    expected_parent = params["record_id"]
    sources = Repo.all(from(r in Record, where: r.id in ^ids, lock: "FOR UPDATE", preload: :entry))

    unchanged? =
      length(sources) == length(ids) and
        Enum.all?(sources, fn source ->
          source.consolidated_into_id == expected_parent and
            DateTime.to_iso8601(source.entry.updated_at) == params["source_versions"][source.id] and
            Scene.sha256(source.entry.content) == params["source_fingerprints"][source.id]
        end)

    if !unchanged?, do: Repo.rollback(:changed)
    sources
  end

  defp consolidation_attrs(chat, profile, draft, sources, tier, sequence) do
    {first, last} = source_range(sources)

    title =
      Title.format(profile.consolidation_title_format, %{
        tier: tier |> Tiers.name() |> String.upcase(),
        title: draft["title"],
        scene: first && "##{first + 1}–##{last + 1}",
        char: chat |> Chat.bots() |> Enum.map_join(", ", &(&1.character && &1.character.name)),
        chat: Chat.title(chat),
        present: "",
        user: (chat.player_character && chat.player_character.name) || "",
        messages: length(sources),
        profile: profile.name,
        sequence: sequence
      })

    %{name: title, content: draft["content"], keywords: draft["keywords"]}
  end

  defp consolidation_record_attrs(chat, book, profile, params, entry, sources, sequence) do
    {first, last} = source_range(sources)

    %{
      lore_entry_id: entry.id,
      lore_book_id: book.id,
      chat_id: chat.id,
      kind: :consolidation,
      tier: params["target_tier"],
      sequence: sequence,
      range_start: first,
      range_end: last,
      written_fingerprint: Scene.sha256(entry.content),
      profile_id: profile.id,
      prompt_id: params["prompt_id"],
      # The source list survives a source's deletion (which drops its join row), so a regeneration
      # can tell a source is gone.
      snapshot: %{"source_ids" => Enum.map(sources, & &1.id)}
    }
  end

  defp source_range(sources) do
    starts = sources |> Enum.map(& &1.range_start) |> Enum.reject(&is_nil/1)
    ends = sources |> Enum.map(& &1.range_end) |> Enum.reject(&is_nil/1)
    if starts == [] or ends == [], do: {nil, nil}, else: {Enum.min(starts), Enum.max(ends)}
  end

  # The source's shared copies go with it: consolidated, and switched off alongside, without being
  # sources themselves.
  defp consolidate_source!(source, record, disable?) do
    Repo.insert!(%RecordSource{record_id: record.id, source_id: source.id})
    copies = Repo.all(Record.shared_copies([source.id]))

    if disable?,
      do: Lore.set_memberships_enabled(Enum.map([source | copies], &{&1.lore_book_id, &1.lore_entry_id}), false)

    ids = Enum.map(copies, & &1.id)

    Repo.update_all(from(r in Record, where: r.id in ^ids),
      set: [consolidated_into_id: record.id, disabled_by_consolidation: disable? == true]
    )

    source
    |> Ecto.Changeset.change(consolidated_into_id: record.id, disabled_by_consolidation: disable? == true)
    |> Repo.update!()
  end

  defp consolidation_job_label(1, n),
    do:
      dpngettext(
        "memory",
        "heading: job that consolidates memories into an Arc",
        "Arc from %{entry_count} memory",
        "Arc from %{entry_count} memories",
        n, entry_count: Format.number(n))

  defp consolidation_job_label(2, n),
    do:
      dpngettext(
        "memory",
        "heading: job that consolidates arcs into a Chapter",
        "Chapter from %{entry_count} arc",
        "Chapter from %{entry_count} arcs",
        n, entry_count: Format.number(n))

  defp consolidation_job_label(3, n),
    do:
      dpngettext(
        "memory",
        "heading: job that consolidates chapters into a Book",
        "Book from %{entry_count} chapter",
        "Book from %{entry_count} chapters",
        n, entry_count: Format.number(n))

  defp consolidation_job_label(4, n),
    do:
      dpngettext(
        "memory",
        "heading: job that consolidates books into a Legend",
        "Legend from %{entry_count} book",
        "Legend from %{entry_count} books",
        n, entry_count: Format.number(n))

  defp consolidation_job_label(5, n),
    do:
      dpngettext(
        "memory",
        "heading: job that consolidates legends into a Series",
        "Series from %{entry_count} legend",
        "Series from %{entry_count} legends",
        n, entry_count: Format.number(n))

  defp consolidation_job_label(6, n),
    do:
      dpngettext(
        "memory",
        "heading: job that consolidates series into an Epic",
        "Epic from %{entry_count} series",
        "Epic from %{entry_count} series",
        n, entry_count: Format.number(n))
end
