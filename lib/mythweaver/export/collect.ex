defmodule Mythweaver.Export.Collect do
  @moduledoc """
  Gathers what an export carries: the requested rows and their owned closure, as a
  `Mythweaver.Bundle`.

  What each kind pulls in:

  - a character: its avatar and every bound book;
  - a lore book: its member entries, their pools and the outlets their `custom_outlet` keys name;
  - a prompt: its blocks, in position order;
  - an AI model: its caption prompt;
  - a script: its dependencies, recursively;
  - a memory profile: its nine prompts and its custom outlet;
  - a side prompt: its prompt and its custom outlet;
  - a side prompt set: each row's side prompt;
  - a chat: every participant's character, its bound books, its prompt, its memory book, its
    transcript (drafts excluded) and the transcript's attachments.

  A link names its target by bundle uid when the bundle carries the target, else by ref
  (`%{"kind", "uid", "name"}`) the importer re-matches, or nil when the scope may not use the target
  (`link/3`). Only rows the scope may use are read; lore in a book whose content is hidden from the
  scope is left out with a warning (`Sharing.Visibility`), as are runtime-only characters,
  prompts, blocks, scripts and AI models whose content is hidden from it, so links to those are refs.
  Connections, API keys and provider rows are never read.

  Items are emitted dependencies first (outlets, blocks, prompts, pools, entries, books, models,
  characters, scripts, profiles, side prompts, sets, chats), each kind in discovery order, scripts
  after their dependencies; `position` is the emission index and `root` marks the requested rows.
  `data` is JSON-equivalent (string keys and enum values, ISO-8601 times, decimals as strings).
  """

  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Query

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.AI.Model
  alias Mythweaver.Attachments
  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Attachments.BodyAttachment
  alias Mythweaver.Attachments.MessageAttachment
  alias Mythweaver.Bundle
  alias Mythweaver.Bundle.Codec
  alias Mythweaver.Bundle.Origins
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Chats.Participant
  alias Mythweaver.Injections.Injection
  alias Mythweaver.Lore.BookCharacter
  alias Mythweaver.Lore.BookChat
  alias Mythweaver.Lore.BookEntry
  alias Mythweaver.Lore.BookFilterTag
  alias Mythweaver.Lore.EntryCharacter
  alias Mythweaver.Lore.EntryFilterTag
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Lore.LorePool
  alias Mythweaver.Lore.PoolEntry
  alias Mythweaver.Memory.ChatSettings
  alias Mythweaver.Memory.Profile
  alias Mythweaver.Memory.Record
  alias Mythweaver.Memory.SidePrompt
  alias Mythweaver.Memory.SidePromptSet
  alias Mythweaver.Memory.SidePromptSetRow
  alias Mythweaver.Messages.Message
  alias Mythweaver.Messages.MessageBody
  alias Mythweaver.Ownership
  alias Mythweaver.Prompts
  alias Mythweaver.Prompts.Block
  alias Mythweaver.Prompts.Prompt
  alias Mythweaver.Prompts.PromptBlock
  alias Mythweaver.Repo
  alias Mythweaver.Scripts.Script
  alias Mythweaver.Sharing.Visibility
  alias Mythweaver.Tags.Tag
  alias Mythweaver.Tags.Tagging
  alias Mythweaver.Variables.Variable

  @type item_ref :: {Bundle.kind(), Ecto.UUID.t()}
  @type counts :: %{(Bundle.kind() | :message | :blob) => non_neg_integer()}

  # The walk visits kinds in this order; no kind links to one visited earlier (scripts loop on
  # themselves), so one pass loads everything.
  @stages [
    :side_prompt_set,
    :side_prompt,
    :memory_profile,
    :ai_model,
    :chat,
    :character,
    :lore_book,
    :lore_entry,
    :lore_pool,
    :prompt_outlet,
    :prompt,
    :prompt_block,
    :script
  ]

  @emission [
    :prompt_outlet,
    :prompt_block,
    :prompt,
    :lore_pool,
    :lore_entry,
    :lore_book,
    :ai_model,
    :character,
    :script,
    :memory_profile,
    :side_prompt,
    :side_prompt_set,
    :chat
  ]

  @profile_prompts [
    :memory_prompt_id,
    :group_memory_prompt_id,
    :consolidation_prompt_id,
    :compaction_prompt_id,
    :topical_clip_prompt_id,
    :character_memory_prompt_id,
    :clip_review_prompt_id,
    :clip_suggestions_prompt_id,
    :combine_clips_prompt_id
  ]

  @settings_fields [
    :auto_enabled,
    :auto_trigger,
    :auto_interval,
    :auto_buffer,
    :auto_token_threshold,
    :auto_hide,
    :leave_unhidden,
    :side_prompt_set_mode
  ]

  @injection_fields [:key, :content, :position, :depth, :role, :condition, :enabled, :uses, :order]

  @body_fields [
    :content,
    :reasoning,
    :active,
    :origin,
    :guide,
    :finish_reason,
    :prompt_tokens,
    :completion_tokens,
    :total_tokens,
    :cost,
    :cost_estimated,
    :generation_ms,
    :error,
    :inserted_at
  ]

  @record_fields [
    :kind,
    :tier,
    :sequence,
    :range_start,
    :range_end,
    :scene_fingerprint,
    :written_fingerprint,
    :disabled_by_consolidation,
    :version,
    :snapshot
  ]

  @doc """
  The bundle of `items` (`[{kind, id}]`, each a row `scope` may export) and its closure, plus
  warnings about what was left out. `opts[:payload]` false skips file bytes and transcripts (no
  blobs, no messages). `{:error, message}` when a requested row isn't there for `scope`.
  """
  @spec run(Scope.t(), [item_ref()], keyword()) :: {:ok, Bundle.t(), [String.t()]} | {:error, String.t()}
  def run(%Scope{} = scope, items, opts \\ []) when is_list(items) do
    payload? = Keyword.get(opts, :payload, true)

    with {:ok, state} <- walk(scope, items) do
      {bundle, state} = bundle(state, payload?)
      {:ok, bundle, warnings(state)}
    end
  end

  @doc """
  What exporting `items` would carry, without reading files or transcripts: item counts by kind,
  plus `:message` (transcript messages) and `:blob` (files), and the warnings `run/3` would give
  about left-out lore. Kinds with nothing are omitted.
  """
  @spec plan(Scope.t(), [item_ref()]) :: {:ok, counts(), [String.t()]} | {:error, String.t()}
  def plan(%Scope{} = scope, items) when is_list(items) do
    with {:ok, state} <- walk(scope, items) do
      counts =
        for {kind, ids} <- state.order, ids != [], into: %{}, do: {kind, length(ids)}

      chat_ids = ids(state, :chat)

      counts =
        counts
        |> put_count(:message, message_count(chat_ids))
        |> put_count(:blob, blob_count(state, chat_ids))

      {:ok, counts, warnings(state)}
    end
  end

  defp put_count(counts, _key, 0), do: counts
  defp put_count(counts, key, n), do: Map.put(counts, key, n)

  defp message_count([]), do: 0

  defp message_count(chat_ids),
    do: Repo.aggregate(from(m in Message, where: m.chat_id in ^chat_ids and m.draft == false), :count)

  defp blob_count(state, chat_ids) do
    avatars = for {_id, %Character{avatar: %Attachment{id: id}}} <- rows(state, :character), do: id

    files =
      if chat_ids == [] do
        []
      else
        message_files =
          from(ma in MessageAttachment,
            join: m in Message,
            on: m.id == ma.message_id,
            where: m.chat_id in ^chat_ids and m.draft == false,
            select: ma.attachment_id
          )

        body_files =
          from(ba in BodyAttachment,
            join: b in MessageBody,
            on: b.id == ba.message_body_id,
            join: m in Message,
            on: m.id == b.message_id,
            where: m.chat_id in ^chat_ids and m.draft == false,
            select: ba.attachment_id
          )

        Repo.all(message_files) ++ Repo.all(body_files)
      end

    (avatars ++ files) |> Enum.uniq() |> length()
  end

  defp warnings(state), do: state.warnings |> Enum.reverse() |> Enum.uniq()

  ## The walk

  defp walk(scope, items) do
    items = Enum.uniq(items)

    state = %{
      scope: scope,
      roots: MapSet.new(items),
      order: Map.new(@stages, &{&1, []}),
      seen: MapSet.new(),
      rows: Map.new(@stages, &{&1, %{}}),
      links: %{},
      outlet_keys: [],
      warnings: []
    }

    state = Enum.reduce(items, state, fn {kind, id}, state -> add(state, kind, [id]) end)
    state = Enum.reduce(@stages, state, &stage(&2, &1))

    if Enum.all?(items, fn {kind, id} -> Map.has_key?(state.rows[kind], id) end),
      do: {:ok, state},
      else: {:error, dgettext("import_export", "Something you picked is no longer available.")}
  end

  # Appends unseen ids of `kind` in order; nils are skipped.
  defp add(state, kind, ids) do
    Enum.reduce(ids, state, fn
      nil, state ->
        state

      id, state ->
        if MapSet.member?(state.seen, {kind, id}),
          do: state,
          else: %{state | seen: MapSet.put(state.seen, {kind, id}), order: Map.update!(state.order, kind, &[id | &1])}
    end)
  end

  defp ids(state, kind), do: Enum.reverse(state.order[kind])
  defp rows(state, kind), do: Enum.map(ids(state, kind), &{&1, state.rows[kind][&1]})

  defp pending(state, kind), do: Enum.reject(ids(state, kind), &Map.has_key?(state.rows[kind], &1))

  # Loads the pending ids of `kind` through `query_fun` (given the ids); ids it doesn't return are
  # dropped. Returns the loaded rows in order.
  defp fetch(state, kind, query_fun) do
    case pending(state, kind) do
      [] ->
        {state, []}

      ids ->
        found = ids |> query_fun.() |> Repo.all() |> Map.new(&{&1.id, &1})
        {keep(state, kind, found), Enum.flat_map(ids, &List.wrap(found[&1]))}
    end
  end

  # Records `found` as loaded rows of `kind` and drops the other pending ids.
  defp keep(state, kind, found) do
    loaded = state.rows[kind]
    order = Enum.filter(state.order[kind], &(Map.has_key?(loaded, &1) or Map.has_key?(found, &1)))
    %{state | rows: Map.put(state.rows, kind, Map.merge(loaded, found)), order: Map.put(state.order, kind, order)}
  end

  defp drop(state, kind, ids) do
    ids = MapSet.new(ids)

    %{
      state
      | rows: Map.update!(state.rows, kind, &Map.drop(&1, MapSet.to_list(ids))),
        order: Map.update!(state.order, kind, &Enum.reject(&1, fn id -> MapSet.member?(ids, id) end))
    }
  end

  defp put_link(state, key, value), do: %{state | links: Map.put(state.links, key, value)}
  defp linked(state, key, default), do: Map.get(state.links, key, default)

  defp warn(state, message), do: %{state | warnings: [message | state.warnings]}

  defp hidden_warning(name),
    do: dgettext("import_export", "'%{item_name}' is hidden lore and was left out.", item_name: name)

  # Drops the loaded `rows` of `kind` whose content is hidden from the scope, each with a warning,
  # and returns the rest. Links to the dropped rows become refs (`link/3`).
  defp drop_hidden(state, kind, rows) do
    {hidden, kept} = Enum.split_with(rows, &Visibility.content_hidden_for?(state.scope, &1))

    state =
      Enum.reduce(hidden, state, fn row, state ->
        warn(state, dgettext("import_export", "'%{item_name}' is runtime-only and was left out.", item_name: row.name))
      end)

    {drop(state, kind, Enum.map(hidden, & &1.id)), kept}
  end

  defp usable(schema, scope, ids), do: schema |> Ownership.usable(scope) |> where([r], r.id in ^ids)

  defp outlet_key(state, %{outlet: :custom, custom_outlet: key, user_id: owner}) when is_binary(key) and key != "",
    do: %{state | outlet_keys: [{owner, key} | state.outlet_keys]}

  defp outlet_key(state, _row), do: state

  defp stage(state, :side_prompt_set) do
    rows_query = from(r in SidePromptSetRow, order_by: [asc: r.position, asc: r.id])

    {state, sets} =
      fetch(state, :side_prompt_set, &(SidePromptSet |> usable(state.scope, &1) |> preload(rows: ^rows_query)))

    add(state, :side_prompt, for(set <- sets, row <- set.rows, do: row.side_prompt_id))
  end

  defp stage(state, :side_prompt) do
    {state, side_prompts} = fetch(state, :side_prompt, &usable(SidePrompt, state.scope, &1))
    state = Enum.reduce(side_prompts, state, &outlet_key(&2, &1))
    add(state, :prompt, Enum.map(side_prompts, & &1.prompt_id))
  end

  defp stage(state, :memory_profile) do
    {state, profiles} = fetch(state, :memory_profile, &usable(Profile, state.scope, &1))
    state = Enum.reduce(profiles, state, &outlet_key(&2, &1))
    add(state, :prompt, for(profile <- profiles, field <- @profile_prompts, do: Map.fetch!(profile, field)))
  end

  defp stage(state, :ai_model) do
    scope = state.scope

    case pending(state, :ai_model) do
      [] ->
        state

      ids ->
        models = from(m in Model, where: m.id in ^ids) |> AI.usable(scope) |> Repo.all()
        {state, models} = drop_hidden(state, :ai_model, models)
        found = Map.new(models, &{&1.id, &1})

        state |> keep(:ai_model, found) |> add(:prompt, Enum.map(Map.values(found), & &1.caption_prompt_id))
    end
  end

  defp stage(state, :chat) do
    participants = from(p in Participant, order_by: [asc: p.position, asc: p.id])

    {state, chats} =
      fetch(state, :chat, fn ids ->
        case state.scope.user do
          %{id: user_id} ->
            from(c in Chat,
              where: c.id in ^ids and c.user_id == ^user_id and c.kind == ^:roleplay,
              preload: [participants: ^participants]
            )

          nil ->
            from(c in Chat, where: false)
        end
      end)

    chat_ids = Enum.map(chats, & &1.id)

    book_chats =
      Repo.all(from(bc in BookChat, where: bc.chat_id in ^chat_ids, order_by: [asc: bc.inserted_at, asc: bc.id]))

    settings = Repo.all(from(s in ChatSettings, where: s.chat_id in ^chat_ids))
    prompts = Map.new(chats, &{&1.id, Prompts.chat_prompt_id(&1)})

    state
    |> put_link(:book_chats, Enum.group_by(book_chats, & &1.chat_id))
    |> put_link(:chat_settings, Map.new(settings, &{&1.chat_id, &1}))
    |> put_link(:chat_prompts, prompts)
    |> add(:character, for(chat <- chats, p <- chat.participants, do: p.character_id))
    |> add(:lore_book, Enum.map(book_chats, & &1.lore_book_id) ++ Enum.map(settings, & &1.memory_book_id))
    |> add(:prompt, Map.values(prompts))
  end

  defp stage(state, :character) do
    {state, characters} = fetch(state, :character, &(Character |> usable(state.scope, &1) |> preload(:avatar)))
    {state, characters} = drop_hidden(state, :character, characters)
    ids = Enum.map(characters, & &1.id)

    bindings =
      Repo.all(from(bc in BookCharacter, where: bc.character_id in ^ids, order_by: [asc: bc.inserted_at, asc: bc.id]))

    state
    |> put_link(:book_characters, Enum.group_by(bindings, & &1.character_id))
    |> add(:lore_book, Enum.map(bindings, & &1.lore_book_id))
  end

  defp stage(state, :lore_book) do
    scope = state.scope
    {state, books} = fetch(state, :lore_book, &usable(LoreBook, scope, &1))
    {hidden, books} = Enum.split_with(books, &Visibility.content_hidden_for?(scope, &1))
    state = Enum.reduce(hidden, state, &warn(&2, hidden_warning(&1.name)))
    state = drop(state, :lore_book, Enum.map(hidden, & &1.id))
    book_ids = Enum.map(books, & &1.id)

    memberships =
      from(be in BookEntry,
        join: b in assoc(be, :book),
        join: e in assoc(be, :entry),
        where: be.lore_book_id in ^book_ids,
        order_by: [desc: be.order + b.order_adjustment, asc: e.name, asc: e.id]
      )
      |> Repo.all()

    state
    |> put_link(:book_entries, Enum.group_by(memberships, & &1.lore_book_id))
    |> add(:lore_entry, Enum.map(memberships, & &1.lore_entry_id))
  end

  defp stage(state, :lore_entry) do
    scope = state.scope
    {state, entries} = fetch(state, :lore_entry, &usable(LoreEntry, scope, &1))
    ids = Enum.map(entries, & &1.id)

    readable =
      LoreEntry
      |> where([e], e.id in ^ids)
      |> Visibility.readable_entries(scope)
      |> select([e], e.id)
      |> Repo.all()
      |> MapSet.new()

    {entries, hidden} = Enum.split_with(entries, &MapSet.member?(readable, &1.id))
    state = Enum.reduce(hidden, state, &warn(&2, hidden_warning(&1.name)))
    state = drop(state, :lore_entry, Enum.map(hidden, & &1.id))
    state = Enum.reduce(entries, state, &outlet_key(&2, &1))
    ids = Enum.map(entries, & &1.id)

    pool_entries =
      Repo.all(from(pe in PoolEntry, where: pe.lore_entry_id in ^ids, order_by: [asc: pe.inserted_at, asc: pe.id]))

    state
    |> put_link(:pool_entries, Enum.group_by(pool_entries, & &1.lore_entry_id))
    |> add(:lore_pool, Enum.map(pool_entries, & &1.lore_pool_id))
  end

  defp stage(state, :lore_pool) do
    {state, _pools} = fetch(state, :lore_pool, &usable(LorePool, state.scope, &1))
    state
  end

  defp stage(state, :prompt_outlet) do
    outlets =
      state.outlet_keys
      |> Enum.reverse()
      |> Enum.uniq()
      |> Enum.map(fn {owner, key} -> Prompts.get_outlet_by_key(owner, key) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.id)

    state |> add(:prompt_outlet, Enum.map(outlets, & &1.id)) |> keep(:prompt_outlet, Map.new(outlets, &{&1.id, &1}))
  end

  defp stage(state, :prompt) do
    {state, prompts} = fetch(state, :prompt, &usable(Prompt, state.scope, &1))
    {state, prompts} = drop_hidden(state, :prompt, prompts)
    ids = Enum.map(prompts, & &1.id)

    memberships =
      Repo.all(from(pb in PromptBlock, where: pb.prompt_id in ^ids, order_by: [asc: pb.position, asc: pb.id]))

    state
    |> put_link(:prompt_blocks, Enum.group_by(memberships, & &1.prompt_id))
    |> add(:prompt_block, Enum.map(memberships, & &1.block_id))
  end

  defp stage(state, :prompt_block) do
    {state, blocks} = fetch(state, :prompt_block, &usable(Block, state.scope, &1))
    {state, _blocks} = drop_hidden(state, :prompt_block, blocks)
    state
  end

  defp stage(state, :script) do
    {state, scripts} = fetch(state, :script, &(Script |> usable(state.scope, &1) |> preload(:dependencies)))

    case drop_hidden(state, :script, scripts) do
      {state, []} ->
        state

      {state, scripts} ->
        deps = for script <- scripts, dep <- Enum.sort_by(script.dependencies, &{&1.name, &1.id}), do: dep.id
        state |> add(:script, deps) |> stage(:script)
    end
  end

  ## The bundle

  defp bundle(state, payload?) do
    {messages, state} = if payload?, do: load_messages(state), else: {%{}, state}
    {blobs, blob_uids, state} = if payload?, do: load_blobs(state, messages), else: {%{}, %{}, state}

    ctx = context(state, messages, blob_uids)

    items =
      @emission
      |> Enum.flat_map(fn kind -> Enum.map(emission_ids(state, kind), &{kind, &1}) end)
      |> Enum.with_index()
      |> Enum.map(fn {{kind, id}, position} ->
        row = state.rows[kind][id]

        %{
          uid: uid(ctx, kind, id),
          kind: kind,
          name: name(kind, row),
          root: MapSet.member?(state.roots, {kind, id}),
          position: position,
          data: data(kind, row, ctx)
        }
      end)

    transcripts =
      for {chat_id, list} <- messages, list != [], into: %{} do
        {uid(ctx, :chat, chat_id), Enum.map(list, &message_data(&1, ctx))}
      end

    refs = load_refs(state.scope, collect_refs([Enum.map(items, & &1.data), Map.values(transcripts)]))
    items = Enum.map(items, &%{&1 | data: resolve(&1.data, refs)})
    transcripts = Map.new(transcripts, fn {chat_uid, list} -> {chat_uid, resolve(list, refs)} end)

    {%Bundle{items: items, messages: transcripts, blobs: blobs}, state}
  end

  defp emission_ids(state, :script), do: script_order(state)
  defp emission_ids(state, kind), do: ids(state, kind)

  # Dependencies before dependents, otherwise in discovery order.
  defp script_order(state) do
    scripts = state.rows.script

    {order, _seen} =
      Enum.reduce(ids(state, :script), {[], MapSet.new()}, fn id, acc -> visit_script(id, scripts, acc) end)

    Enum.reverse(order)
  end

  defp visit_script(id, scripts, {order, seen} = acc) do
    if MapSet.member?(seen, id) or not Map.has_key?(scripts, id) do
      acc
    else
      deps = scripts[id].dependencies |> Enum.sort_by(&{&1.name, &1.id}) |> Enum.map(& &1.id)
      {order, seen} = Enum.reduce(deps, {order, MapSet.put(seen, id)}, &visit_script(&1, scripts, &2))
      {[id | order], seen}
    end
  end

  defp name(:chat, chat), do: Chat.title(chat)
  defp name(_kind, row), do: row.name

  # Transcripts: `%{chat_id => [Message]}`, drafts excluded, in transcript order.
  defp load_messages(state) do
    case ids(state, :chat) do
      [] ->
        {%{}, state}

      chat_ids ->
        bodies = from(b in MessageBody, order_by: [asc: b.inserted_at, asc: b.id], preload: [:guide_attachments])

        messages =
          from(m in Message,
            where: m.chat_id in ^chat_ids and m.draft == false,
            order_by: [asc: m.position, asc: m.inserted_at, asc: m.id],
            preload: [:author_character, :attachments, bodies: ^bodies]
          )
          |> Repo.all()
          |> Enum.group_by(& &1.chat_id)

        {Map.new(chat_ids, &{&1, Map.get(messages, &1, [])}), state}
    end
  end

  # Reads every avatar and transcript file once. Returns the blobs by uid, `%{attachment_id =>
  # blob uid}` for those read, and the state with a warning per unreadable file.
  defp load_blobs(state, messages) do
    avatars = for {_id, %Character{avatar: %Attachment{} = a} = c} <- rows(state, :character), do: {a, c.name}

    files =
      for {chat_id, list} <- messages,
          title = Chat.title(state.rows.chat[chat_id]),
          message <- list,
          attachment <- message.attachments ++ Enum.flat_map(message.bodies, & &1.guide_attachments),
          do: {attachment, title}

    (avatars ++ files)
    |> Enum.uniq_by(fn {attachment, _owner} -> attachment.id end)
    |> Enum.reduce({%{}, %{}, state}, fn {attachment, owner}, {blobs, uids, state} ->
      case Attachments.read(attachment) do
        {:ok, bytes} ->
          uid = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

          blob = %{
            kind: attachment.kind,
            content_type: attachment.content_type,
            filename: attachment.filename,
            description: attachment.description,
            bytes: bytes
          }

          {Map.put_new(blobs, uid, blob), Map.put(uids, attachment.id, uid), state}

        {:error, _reason} ->
          {blobs, uids, warn(state, "'#{owner}''s file couldn't be read and was left out.")}
      end
    end)
  end

  defp context(state, messages, blob_uids) do
    uids =
      Map.new(@emission, fn
        :prompt_outlet -> {:prompt_outlet, Map.new(ids(state, :prompt_outlet), &{&1, &1})}
        kind -> {kind, Origins.uids_for(kind, ids(state, kind))}
      end)

    entry_ids = ids(state, :lore_entry)
    records = records(entry_ids)

    %{
      state: state,
      uids: uids,
      blobs: blob_uids,
      positions: Map.new(messages, fn {chat_id, list} -> {chat_id, Enum.map(list, & &1.position)} end),
      tags: Map.new(Tagging.kinds(), &{&1, tags(state.scope, &1, ids(state, &1))}),
      book_filter_tags: filter_tags(BookFilterTag, :lore_book_id, ids(state, :lore_book)),
      entry_filter_tags: filter_tags(EntryFilterTag, :lore_entry_id, entry_ids),
      entry_characters: entry_characters(entry_ids),
      records: Map.new(records, &{&1.lore_entry_id, &1}),
      record_entries: record_entries(records),
      injections: by_chat(Injection, ids(state, :chat), asc: :order, asc: :inserted_at, asc: :id),
      variables: by_chat(Variable, ids(state, :chat), asc: :key, asc: :id)
    }
  end

  defp uid(ctx, kind, id), do: ctx.uids[kind][id]

  # A link to `kind` row `id`: its uid when the bundle carries the row, else a ref that `resolve/2`
  # turns into `%{"kind", "uid", "name"}`, or nil when the scope may not use the row (`load_refs/2`).
  defp link(_ctx, _kind, nil), do: nil
  defp link(ctx, kind, id), do: uid(ctx, kind, id) || {:ref, kind, id}

  # A list element kept only when its `key` link resolves to something (`resolve/2`).
  defp row(key, map), do: {:row, key, map}

  defp tags(_scope, _kind, []), do: %{}

  defp tags(scope, kind, ids) do
    column = Tagging.column(kind)

    visible =
      case scope.user do
        %{id: user_id} -> dynamic([tg, t], is_nil(t.user_id) or t.user_id == ^user_id)
        nil -> dynamic([tg, t], is_nil(t.user_id))
      end

    from(tg in Tagging,
      join: t in Tag,
      on: t.id == tg.tag_id,
      where: field(tg, ^column) in ^ids,
      where: ^visible,
      select: {field(tg, ^column), t.namespace, t.name}
    )
    |> Repo.all()
    |> texts_by_owner()
  end

  defp filter_tags(_schema, _column, []), do: %{}

  defp filter_tags(schema, column, ids) do
    from(f in schema,
      join: t in Tag,
      on: t.id == f.tag_id,
      where: field(f, ^column) in ^ids,
      select: {field(f, ^column), t.namespace, t.name}
    )
    |> Repo.all()
    |> texts_by_owner()
  end

  defp texts_by_owner(rows) do
    rows
    |> Enum.group_by(&elem(&1, 0), fn {_id, namespace, name} -> Tag.text(%{namespace: namespace, name: name}) end)
    |> Map.new(fn {id, texts} -> {id, texts |> Enum.uniq() |> Enum.sort()} end)
  end

  defp entry_characters([]), do: %{}

  defp entry_characters(ids) do
    from(ec in EntryCharacter, where: ec.lore_entry_id in ^ids, order_by: [asc: ec.inserted_at, asc: ec.id])
    |> Repo.all()
    |> Enum.group_by(& &1.lore_entry_id, & &1.character_id)
  end

  defp records([]), do: []

  defp records(entry_ids) do
    Repo.all(from(r in Record, where: r.lore_entry_id in ^entry_ids, preload: :sources))
  end

  # `%{record_id => entry_id}` for every record a bundle record points at.
  defp record_entries(records) do
    ids =
      Enum.flat_map(records, fn r -> [r.id, r.consolidated_into_id, r.canonical_id | Enum.map(r.sources, & &1.id)] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if ids == [],
      do: %{},
      else: Map.new(Repo.all(from(r in Record, where: r.id in ^ids, select: {r.id, r.lore_entry_id})))
  end

  defp by_chat(_schema, [], _order), do: %{}

  defp by_chat(schema, chat_ids, order) do
    from(r in schema, where: r.chat_id in ^chat_ids, order_by: ^order)
    |> Repo.all()
    |> Enum.group_by(& &1.chat_id)
  end

  ## Item data

  defp data(kind, row, ctx), do: kind |> Codec.dump(row) |> Map.merge(links(kind, row, ctx)) |> put_tags(kind, row, ctx)

  defp put_tags(data, kind, row, ctx) do
    if kind in Tagging.kinds(), do: Map.put(data, "tags", Map.get(ctx.tags[kind], row.id, [])), else: data
  end

  defp links(:character, character, ctx) do
    avatar = with %Attachment{id: id} <- character.avatar, do: ctx.blobs[id]

    books =
      ctx.state
      |> linked(:book_characters, %{})
      |> Map.get(character.id, [])
      |> book_links(ctx)

    %{"avatar" => avatar, "books" => books}
  end

  defp links(:lore_book, book, ctx) do
    entries =
      for membership <- ctx.state |> linked(:book_entries, %{}) |> Map.get(book.id, []) do
        row("uid", %{
          "uid" => link(ctx, :lore_entry, membership.lore_entry_id),
          "order" => membership.order,
          "enabled" => membership.enabled
        })
      end

    %{"filter_tags" => Map.get(ctx.book_filter_tags, book.id, []), "entries" => entries}
  end

  defp links(:lore_entry, entry, ctx) do
    pools =
      for pe <- ctx.state |> linked(:pool_entries, %{}) |> Map.get(entry.id, []),
          do:
            row("uid", %{
              "uid" => link(ctx, :lore_pool, pe.lore_pool_id),
              "weight" => pe.weight,
              "override" => pe.override,
              "scored" => pe.scored
            })

    %{
      "filter_tags" => Map.get(ctx.entry_filter_tags, entry.id, []),
      "filter_characters" => Enum.map(Map.get(ctx.entry_characters, entry.id, []), &link(ctx, :character, &1)),
      "pools" => pools,
      "memory" => memory(ctx.records[entry.id], ctx)
    }
  end

  defp links(:prompt, prompt, ctx) do
    blocks =
      for pb <- ctx.state |> linked(:prompt_blocks, %{}) |> Map.get(prompt.id, []),
          do: row("uid", %{"uid" => link(ctx, :prompt_block, pb.block_id), "enabled" => pb.enabled})

    %{"blocks" => blocks}
  end

  defp links(:ai_model, model, ctx) do
    %{
      "sampler" => Codec.sampler(model.sampler),
      "caption_prompt" => link(ctx, :prompt, model.caption_prompt_id),
      "caption_model" => link(ctx, :ai_model, model.caption_model_id)
    }
  end

  defp links(:script, script, ctx) do
    deps = for dep <- Enum.sort_by(script.dependencies, &{&1.name, &1.id}), do: link(ctx, :script, dep.id)
    %{"dependencies" => deps}
  end

  defp links(:memory_profile, profile, ctx) do
    prompts =
      Map.new(@profile_prompts, fn field ->
        {field |> Atom.to_string() |> String.replace_suffix("_id", ""), link(ctx, :prompt, Map.fetch!(profile, field))}
      end)

    %{"model" => link(ctx, :ai_model, profile.ai_model_id), "prompts" => prompts}
  end

  defp links(:side_prompt, side_prompt, ctx) do
    %{
      "prompt" => link(ctx, :prompt, side_prompt.prompt_id),
      "profile" => link(ctx, :memory_profile, side_prompt.profile_id),
      "target_book" => link(ctx, :lore_book, side_prompt.target_book_id)
    }
  end

  defp links(:side_prompt_set, set, ctx) do
    rows =
      for set_row <- set.rows do
        row("side_prompt", %{
          "side_prompt" => link(ctx, :side_prompt, set_row.side_prompt_id),
          "label" => set_row.label,
          "macro_values" => Codec.value(set_row.macro_values)
        })
      end

    %{"rows" => rows}
  end

  defp links(:chat, chat, ctx) do
    participants =
      for p <- chat.participants do
        row("character", %{
          "character" => link(ctx, :character, p.character_id),
          "model" => link(ctx, :ai_model, p.ai_model_id),
          "muted" => p.muted,
          "talkativeness" => p.talkativeness
        })
      end

    %{
      "player" => link(ctx, :character, chat.player_character_id),
      "model" => link(ctx, :ai_model, chat.ai_model_id),
      "participants" => participants,
      "books" => ctx.state |> linked(:book_chats, %{}) |> Map.get(chat.id, []) |> book_links(ctx),
      "prompt" => link(ctx, :prompt, ctx.state |> linked(:chat_prompts, %{}) |> Map.get(chat.id)),
      "injections" => Enum.map(Map.get(ctx.injections, chat.id, []), &dump_fields(&1, @injection_fields)),
      "variables" =>
        Enum.map(Map.get(ctx.variables, chat.id, []), &%{"key" => &1.key, "value" => Codec.value(&1.value)}),
      "memory" => ctx.state |> linked(:chat_settings, %{}) |> Map.get(chat.id) |> chat_memory(chat, ctx)
    }
  end

  defp links(_kind, _row, _ctx), do: %{}

  # Bindings (`BookCharacter`/`BookChat`): books in the bundle by name, then the others.
  defp book_links(bindings, ctx) do
    books = ctx.state.rows.lore_book

    bindings
    |> Enum.uniq_by(& &1.lore_book_id)
    |> Enum.sort_by(fn %{lore_book_id: id} -> {is_nil(books[id]), books[id] && books[id].name, id} end)
    |> Enum.map(&row("uid", %{"uid" => link(ctx, :lore_book, &1.lore_book_id), "enabled" => &1.enabled}))
  end

  defp dump_fields(row, fields), do: Map.new(fields, &{Atom.to_string(&1), Codec.value(Map.fetch!(row, &1))})

  defp memory(nil, _ctx), do: nil

  defp memory(%Record{} = record, ctx) do
    positions = record.chat_id && ctx.positions[record.chat_id]

    record
    |> dump_fields(@record_fields)
    |> Map.merge(%{
      "range_start" => remap_start(record.range_start, positions),
      "range_end" => remap_end(record.range_end, positions),
      "chat" => link(ctx, :chat, record.chat_id),
      "consolidated_into" => record_entry_link(record.consolidated_into_id, ctx),
      "sources" =>
        record.sources
        |> Enum.sort_by(& &1.sequence)
        |> Enum.map(&record_entry_link(&1.id, ctx))
        |> Enum.reject(&is_nil/1),
      "canonical" => record_entry_link(record.canonical_id, ctx),
      "profile" => link(ctx, :memory_profile, record.profile_id),
      "prompt" => link(ctx, :prompt, record.prompt_id),
      "side_prompt" => link(ctx, :side_prompt, record.side_prompt_id)
    })
  end

  # A link to the entry of record `record_id`.
  defp record_entry_link(nil, _ctx), do: nil
  defp record_entry_link(record_id, ctx), do: link(ctx, :lore_entry, ctx.record_entries[record_id])

  defp chat_memory(nil, _chat, _ctx), do: nil

  defp chat_memory(%ChatSettings{} = settings, chat, ctx) do
    character_books =
      for {character_id, book_id} <- Enum.sort(settings.character_book_ids),
          do:
            row("character", %{
              "character" => link(ctx, :character, character_id),
              "book" => link(ctx, :lore_book, book_id)
            })

    side_prompt_books =
      for {side_prompt_id, book_id} <- Enum.sort(settings.side_prompt_book_ids),
          do: %{"side_prompt" => link(ctx, :side_prompt, side_prompt_id), "book" => link(ctx, :lore_book, book_id)}

    settings
    |> dump_fields(@settings_fields)
    |> Map.merge(%{
      "memory_book" => link(ctx, :lore_book, settings.memory_book_id),
      "profile" => link(ctx, :memory_profile, settings.profile_id),
      "side_prompt_set" => link(ctx, :side_prompt_set, settings.side_prompt_set_id),
      "context_entry_ids" => Enum.map(settings.context_entry_ids, &link(ctx, :lore_entry, &1)),
      "side_prompt_book_ids" => side_prompt_books,
      "character_book_ids" => character_books,
      "cast_ids" => Enum.map(settings.cast_ids, &link(ctx, :character, &1)),
      "highest_processed" => remap_end(settings.highest_processed, ctx.positions[chat.id])
    })
  end

  # A record range or progress mark as indices into the exported transcript (`positions`, its
  # messages' old positions in order); unchanged when the transcript isn't exported.
  defp remap_start(nil, _positions), do: nil
  defp remap_start(value, nil), do: value
  defp remap_start(value, positions), do: Enum.find_index(positions, &(&1 >= value))

  defp remap_end(nil, _positions), do: nil
  defp remap_end(value, nil), do: value

  defp remap_end(value, positions) do
    positions
    |> Enum.with_index()
    |> Enum.filter(fn {p, _i} -> p <= value end)
    |> List.last()
    |> case do
      {_p, index} -> index
      nil -> nil
    end
  end

  # An author outside the bundle also leaves its name, for a target the link can't reach.
  defp message_data(%Message{} = message, ctx) do
    author_id = message.author_character_id

    author_name =
      case {author_id && uid(ctx, :character, author_id), message.author_character} do
        {nil, %Character{name: name}} -> name
        _other -> message.author_name
      end

    %{
      "uid" => message.id,
      "author" => link(ctx, :character, author_id),
      "author_name" => author_name,
      "visible_to_ai" => message.visible_to_ai,
      "inserted_at" => Codec.value(message.inserted_at),
      "attachments" => blob_uids(message.attachments, ctx),
      "bodies" =>
        Enum.map(message.bodies, fn body ->
          body |> dump_fields(@body_fields) |> Map.put("attachments", blob_uids(body.guide_attachments, ctx))
        end)
    }
  end

  defp blob_uids(attachments, ctx), do: attachments |> Enum.map(&ctx.blobs[&1.id]) |> Enum.reject(&is_nil/1)

  ## Refs

  defp collect_refs(term), do: term |> refs_in([]) |> Enum.uniq() |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

  defp refs_in({:ref, kind, id}, acc), do: [{kind, id} | acc]
  defp refs_in({:row, _key, map}, acc), do: refs_in(map, acc)
  defp refs_in(list, acc) when is_list(list), do: Enum.reduce(list, acc, &refs_in/2)
  defp refs_in(map, acc) when is_map(map) and not is_struct(map), do: Enum.reduce(Map.values(map), acc, &refs_in/2)
  defp refs_in(_term, acc), do: acc

  # `%{{kind, id} => ref map}` for the targets `scope` may use; the others resolve to nil.
  defp load_refs(scope, by_kind) do
    for {kind, ids} <- by_kind,
        names = Map.new(ref_names(scope, kind, ids)),
        uids = Origins.uids_for(kind, Map.keys(names)),
        {id, name} <- names,
        into: %{},
        do: {{kind, id}, %{"kind" => Map.fetch!(Bundle.kinds(), kind), "uid" => uids[id], "name" => name}}
  end

  defp ref_names(scope, :ai_model, ids), do: from(m in Model, where: m.id in ^ids) |> AI.usable(scope) |> names()

  defp ref_names(%Scope{user: %{id: user_id}}, :chat, ids) do
    from(c in Chat, where: c.id in ^ids and c.user_id == ^user_id and c.kind == ^:roleplay)
    |> Repo.all()
    |> Enum.map(&{&1.id, Chat.title(&1)})
  end

  defp ref_names(%Scope{}, :chat, _ids), do: []

  defp ref_names(scope, :lore_book, ids),
    do: LoreBook |> usable(scope, ids) |> Visibility.listed_books(scope) |> names()

  defp ref_names(scope, :lore_entry, ids),
    do: LoreEntry |> usable(scope, ids) |> Visibility.listed_entries(scope) |> names()

  defp ref_names(scope, kind, ids), do: kind |> Codec.schema() |> usable(scope, ids) |> names()

  defp names(query), do: query |> select([r], {r.id, r.name}) |> Repo.all()

  defp resolve({:ref, kind, id}, refs), do: refs[{kind, id}]

  # In a list, a ref that resolves to nothing is dropped, as is a `row/2` whose key link is.
  defp resolve(list, refs) when is_list(list) do
    Enum.flat_map(list, fn
      {:ref, kind, id} ->
        List.wrap(refs[{kind, id}])

      {:row, key, map} ->
        map = resolve(map, refs)
        if is_nil(map[key]), do: [], else: [map]

      term ->
        [resolve(term, refs)]
    end)
  end

  defp resolve(map, refs) when is_map(map), do: Map.new(map, fn {k, v} -> {k, resolve(v, refs)} end)
  defp resolve(term, _refs), do: term
end
