defmodule Mythweaver.Import.BundleWriter do
  @moduledoc """
  Writes a `Mythweaver.Bundle` (a `.mythweaver` file, or an external file's embedded bundle) for a
  scope, in one transaction.

  Each decision-kind item is Replaced, Copied or Skipped per `Mythweaver.Import.Review` (recomputed
  here), overridden by `opts[:decisions]` where the override is one of the row's options. Kinds are
  written in a fixed order so every link points at a row that already exists: prompts (and their
  blocks), models, characters, lore books, lore entries (with pools and outlets), character ↔ book
  bindings, scripts, memory profiles, side prompts, side prompt sets, model caption links, chats,
  memory records.

  A link (a bundle uid, or a `%{"kind", "uid", "name"}` ref to a row outside the bundle; see
  `Mythweaver.Bundle`) resolves, in order, to the row this import wrote or matched for that uid, the
  local match (`Mythweaver.Bundle.Origins.match/3`), a usable row of the same name, else nothing (with
  a warning). Every written row records its origin and gets the bundle's tags. Avatars are stored and
  books re-embedded after the commit.
  """

  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Query
  import Mythweaver.Import.WriterHelpers

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.Attachments
  alias Mythweaver.Bundle
  alias Mythweaver.Bundle.Codec
  alias Mythweaver.Bundle.Origins
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Import.Review
  alias Mythweaver.Injections
  alias Mythweaver.Lore
  alias Mythweaver.Lore.BookCharacter
  alias Mythweaver.Lore.BookChat
  alias Mythweaver.Lore.BookEntry
  alias Mythweaver.Lore.Embeddings
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Memory
  alias Mythweaver.Memory.Record
  alias Mythweaver.Messages
  alias Mythweaver.Messages.MessageBody
  alias Mythweaver.Ownership
  alias Mythweaver.Prompts
  alias Mythweaver.Repo
  alias Mythweaver.Scripts
  alias Mythweaver.Tags
  alias Mythweaver.Tags.Tagging

  @profile_prompts ~w(memory_prompt group_memory_prompt consolidation_prompt compaction_prompt topical_clip_prompt
                      character_memory_prompt clip_review_prompt clip_suggestions_prompt combine_clips_prompt)

  @spec import(Scope.t(), %{bundle: Bundle.t()}, keyword()) ::
          {:ok, %{kind: :bundle, record: struct(), warnings: [String.t()]}} | {:error, String.t()}
  def import(%Scope{} = scope, %{bundle: %Bundle{} = bundle}, opts) do
    overrides = Keyword.get(opts, :decisions, %{})

    result =
      transaction(fn ->
        ctx = context(scope, bundle, overrides)

        state =
          %{
            written: %{},
            matched: %{},
            entries: %{},
            blobs: %{},
            avatars: [],
            book_ids: [],
            chats: MapSet.new(),
            warnings: [],
            names: %{}
          }
          |> write_prompts(ctx)
          |> write_models(ctx)
          |> write_characters(ctx)
          |> write_books(ctx)
          |> write_entries(ctx)
          |> bind_character_books(ctx)
          |> write_scripts(ctx)
          |> write_profiles(ctx)
          |> write_side_prompts(ctx)
          |> write_side_prompt_sets(ctx)
          |> link_caption_models(ctx)
          |> write_chats(ctx)
          |> write_records(ctx)

        if state.written == %{},
          do: Repo.rollback(dgettext("import_export", "Nothing was imported: every item was skipped."))

        root =
          bundle.items
          |> Enum.filter(&(&1.root and Map.has_key?(state.written, &1.uid)))
          |> Enum.min_by(& &1.position, fn -> nil end)

        record =
          if root,
            do: state.written[root.uid],
            else: bundle.items |> Enum.sort_by(& &1.position) |> Enum.find_value(&state.written[&1.uid])

        {record, state}
      end)

    with {:ok, {record, state}} <- result do
      :ok = Embeddings.refresh_books_later(scope, Enum.uniq(state.book_ids))

      avatar_warnings =
        Enum.flat_map(Enum.reverse(state.avatars), fn {character, bytes} -> store_avatar(scope, character, bytes) end)

      {:ok, %{kind: :bundle, record: record, warnings: Enum.reverse(state.warnings, avatar_warnings)}}
    end
  end

  ## Context and decisions

  defp context(scope, bundle, overrides) do
    rows = Review.review(scope, bundle)
    by_uid = Map.new(bundle.items, &{&1.uid, &1})

    decisions =
      Map.new(rows, fn row ->
        wanted = Map.get(overrides, row.uid)
        {row.uid, if(wanted in row.options, do: wanted, else: row.default)}
      end)

    %{
      scope: scope,
      bundle: bundle,
      items: by_uid,
      decisions: decisions,
      outlets: for(%{kind: :prompt_outlet} = item <- bundle.items, into: %{}, do: {item.data["key"], item})
    }
  end

  defp items(ctx, kind), do: ctx.bundle.items |> Enum.filter(&(&1.kind == kind)) |> Enum.sort_by(& &1.position)

  # `{:copy, nil}`, `{:replace, match}` or `{:skip, match | nil}` for a decision-kind item.
  defp decide(ctx, item) do
    case ctx.decisions[item.uid] do
      :copy -> {:copy, nil}
      decision -> {decision || :skip, Origins.match(ctx.scope, item.kind, item.uid)}
    end
  end

  # Runs one decision-kind item: Skip records the match, Copy/Replace write through `write`
  # (`fn mode, match, state -> {row, state}`), then origin and tags.
  defp each_item(state, ctx, kind, write) do
    Enum.reduce(items(ctx, kind), state, fn item, state ->
      case decide(ctx, item) do
        {:skip, nil} ->
          state

        {:skip, match} ->
          put_in(state.matched[item.uid], match)

        {:replace, nil} ->
          {row, state} = write.(item, :copy, nil, state)
          written(state, ctx, item, row)

        {mode, match} ->
          {row, state} = write.(item, mode, match, state)
          written(state, ctx, item, row)
      end
    end)
  end

  defp written(state, _ctx, _item, nil), do: state

  defp written(state, ctx, item, row) do
    :ok = Origins.record!(item.kind, row.id, item.uid)
    state = put_in(state.written[item.uid], row)
    set_tags(state, ctx, item, row)
  end

  # A free name for a copy among `kind`'s existing names (`list` loads them once per import), kept
  # with every name this import writes so later copies of the same kind see it.
  defp copy_name(state, kind, name, list) do
    taken = Map.get_lazy(state.names, kind, fn -> MapSet.new(list.(), & &1.name) end)
    unique = unique_name(name, taken)
    {unique, put_in(state.names[kind], MapSet.put(taken, unique))}
  end

  # A replace may rename a row: later copies of `kind` must not take its new name.
  defp note_name(%{names: names} = state, kind, name) when is_map_key(names, kind),
    do: put_in(state.names[kind], MapSet.put(names[kind], name))

  defp note_name(state, _kind, _name), do: state

  defp set_tags(state, ctx, item, row) do
    tags = item.data["tags"]

    if item.kind in Tagging.kinds() and is_list(tags) and (tags != [] or ctx.decisions[item.uid] == :replace) do
      domain = if row.user_id, do: :mine, else: :site

      case Tags.set_item_tags(ctx.scope, row, domain, tags) do
        :ok ->
          state

        {:error, _} ->
          warn(state, dgettext("import_export", "'%{item_name}''s tags couldn't be set.", item_name: item.name))
      end
    else
      state
    end
  end

  defp warn(state, message), do: %{state | warnings: [message | state.warnings]}

  ## Link resolution

  # A link to a `kind` row: a bundle uid (named after its bundle item) or a `{"kind", "uid", "name"}`
  # ref of that kind. Written/matched row, local match, usable row by name, else nil.
  defp resolve(state, _ctx, _kind, nil, _owner), do: {nil, state}

  defp resolve(state, ctx, kind, uid, owner) when is_binary(uid) do
    name = with %{name: name} <- ctx.items[uid], do: name
    resolve(state, ctx, kind, uid, name, owner)
  end

  defp resolve(state, ctx, kind, %{"kind" => kind_string, "uid" => uid} = ref, owner) when is_binary(uid) do
    if Bundle.kind(kind_string) == kind,
      do: resolve(state, ctx, kind, uid, ref["name"], owner),
      else: {nil, state}
  end

  defp resolve(state, _ctx, _kind, _link, _owner), do: {nil, state}

  defp resolve(state, ctx, kind, uid, name, owner) do
    found =
      state.written[uid] || state.matched[uid] || Origins.match(ctx.scope, kind, uid) ||
        by_name(ctx.scope, kind, name)

    cond do
      found -> {found, state}
      is_nil(owner) -> {nil, state}
      true -> {nil, warn(state, missing_link(kind, owner, name))}
    end
  end

  defp missing_link(:character, owner, name),
    do:
      dgettext("import_export", "'%{owner_name}' links to character '%{target_name}', which isn't here.",
        owner_name: owner,
        target_name: name
      )

  defp missing_link(:lore_book, owner, name),
    do:
      dgettext("import_export", "'%{owner_name}' links to lore book '%{target_name}', which isn't here.",
        owner_name: owner,
        target_name: name
      )

  defp missing_link(:lore_entry, owner, name),
    do:
      dgettext("import_export", "'%{owner_name}' links to lore entry '%{target_name}', which isn't here.",
        owner_name: owner,
        target_name: name
      )

  defp missing_link(:lore_pool, owner, name),
    do:
      dgettext("import_export", "'%{owner_name}' links to lore pool '%{target_name}', which isn't here.",
        owner_name: owner,
        target_name: name
      )

  defp missing_link(:prompt, owner, name),
    do:
      dgettext("import_export", "'%{owner_name}' links to prompt '%{target_name}', which isn't here.",
        owner_name: owner,
        target_name: name
      )

  defp missing_link(:prompt_block, owner, name),
    do:
      dgettext("import_export", "'%{owner_name}' links to prompt block '%{target_name}', which isn't here.",
        owner_name: owner,
        target_name: name
      )

  defp missing_link(:prompt_outlet, owner, name),
    do:
      dgettext("import_export", "'%{owner_name}' links to outlet '%{target_name}', which isn't here.",
        owner_name: owner,
        target_name: name
      )

  defp missing_link(:ai_model, owner, name),
    do:
      dgettext("import_export", "'%{owner_name}' links to AI model '%{target_name}', which isn't here.",
        owner_name: owner,
        target_name: name
      )

  defp missing_link(:script, owner, name),
    do:
      dgettext("import_export", "'%{owner_name}' links to script '%{target_name}', which isn't here.",
        owner_name: owner,
        target_name: name
      )

  defp missing_link(:memory_profile, owner, name),
    do:
      dgettext("import_export", "'%{owner_name}' links to memory profile '%{target_name}', which isn't here.",
        owner_name: owner,
        target_name: name
      )

  defp missing_link(:side_prompt, owner, name),
    do:
      dgettext("import_export", "'%{owner_name}' links to side prompt '%{target_name}', which isn't here.",
        owner_name: owner,
        target_name: name
      )

  defp missing_link(:side_prompt_set, owner, name),
    do:
      dgettext("import_export", "'%{owner_name}' links to side prompt set '%{target_name}', which isn't here.",
        owner_name: owner,
        target_name: name
      )

  defp missing_link(:chat, owner, name),
    do:
      dgettext("import_export", "'%{owner_name}' links to chat '%{target_name}', which isn't here.",
        owner_name: owner,
        target_name: name
      )

  defp by_name(_scope, _kind, name) when not is_binary(name), do: nil
  defp by_name(scope, :character, name), do: Characters.find_character_by_name(scope, name)

  defp by_name(%Scope{user: %{id: uid}}, :chat, name),
    do: Repo.one(from(c in Chat, where: c.user_id == ^uid and c.kind == :roleplay and c.name == ^name, limit: 1))

  defp by_name(_scope, :chat, _name), do: nil

  defp by_name(scope, :ai_model, name) do
    from(m in AI.Model, where: m.name == ^name, order_by: [asc: m.id], limit: 1)
    |> AI.usable(scope)
    |> Repo.one()
  end

  defp by_name(scope, kind, name) do
    kind
    |> Codec.schema()
    |> Ownership.usable(scope)
    |> where([r], r.name == ^name)
    |> order_by(^[asc: Ownership.owner_rank(scope.user && scope.user.id), asc: :id])
    |> limit(1)
    |> Repo.one()
  end

  defp id(nil), do: nil
  defp id(row), do: row.id

  defp attrs(item), do: Codec.attrs(item.kind, item.data)

  ## 1. Prompts and blocks

  defp write_prompts(state, ctx) do
    each_item(state, ctx, :prompt, fn item, mode, match, state ->
      owner = import_owner(ctx, Prompts.Prompt, mode, match)
      {attrs, state} = visibility_attrs(state, item, attrs(item), owner)

      {prompt, state} =
        case mode do
          :copy ->
            {name, state} = copy_name(state, :prompt, item.name, fn -> Prompts.list_editable_prompts(ctx.scope) end)
            {ok!(Prompts.create_prompt(ctx.scope, Map.put(attrs, "name", name))), state}

          :replace ->
            prompt = ok!(Prompts.update_prompt(ctx.scope, match, attrs))
            {prompt, note_name(state, :prompt, prompt.name)}
        end

      state = write_prompt_blocks(state, ctx, item, mode, prompt)
      {prompt, state}
    end)
  end

  defp write_prompt_blocks(state, ctx, item, mode, prompt) do
    current = Prompts.list_prompt_blocks(prompt)
    members = MapSet.new(current, & &1.block_id)

    {wanted, state} =
      (item.data["blocks"] || [])
      |> Enum.uniq_by(& &1["uid"])
      |> Enum.flat_map_reduce(state, fn link, state ->
        case prompt_block(state, ctx, item, prompt, link["uid"], mode, members) do
          {nil, state} -> {[], state}
          {block, state} -> {[{block, link["enabled"] != false}], state}
        end
      end)

    wanted = Enum.uniq_by(wanted, fn {block, _} -> block.id end)

    case mode do
      :copy ->
        for {block, enabled} <- wanted, do: ok!(Prompts.add_block(ctx.scope, prompt, block, %{enabled: enabled}))

      :replace ->
        wanted_ids = MapSet.new(wanted, fn {block, _} -> block.id end)

        for membership <- current,
            not MapSet.member?(wanted_ids, membership.block_id),
            do: ok!(Prompts.remove_block(ctx.scope, membership))

        for {block, enabled} <- wanted,
            not MapSet.member?(members, block.id),
            do: ok!(Prompts.add_block(ctx.scope, prompt, block, %{enabled: enabled}))

        if wanted != [], do: ok!(Prompts.reorder_blocks(ctx.scope, prompt, Enum.map(wanted, fn {b, _} -> b.id end)))

        by_block = Map.new(Prompts.list_prompt_blocks(prompt), &{&1.block_id, &1})

        for {block, enabled} <- wanted,
            by_block[block.id].enabled != enabled,
            do: ok!(Prompts.update_block_membership(ctx.scope, by_block[block.id], %{enabled: enabled}))
    end

    state
  end

  # A bundle block is written (`write_block/5`); a ref is matched, and used when the prompt may.
  defp prompt_block(state, ctx, _item, _prompt, uid, mode, members) when is_binary(uid) do
    case ctx.items[uid] do
      %{kind: :prompt_block} = block_item -> write_block(state, ctx, block_item, mode, members)
      _ -> {nil, state}
    end
  end

  defp prompt_block(state, ctx, item, prompt, link, _mode, _members) do
    case resolve(state, ctx, :prompt_block, link, item.name) do
      {nil, state} ->
        {nil, state}

      {block, state} ->
        if Ownership.reference_ok?(prompt.user_id, block),
          do: {block, state},
          else:
            {nil,
             warn(
               state,
               dgettext("import_export", "'%{item_name}' couldn't be linked to the prompt block '%{block_name}'.",
                 item_name: item.name,
                 block_name: block.name
               )
             )}
    end
  end

  defp write_block(state, ctx, item, mode, members) do
    case state.written[item.uid] do
      %Prompts.Block{} = block ->
        {block, state}

      _ ->
        match = if mode == :replace, do: Origins.match(ctx.scope, :prompt_block, item.uid)
        update? = match && MapSet.member?(members, match.id) && Ownership.authorize_edit(ctx.scope, match) == :ok
        owner = if update?, do: match.user_id, else: import_owner(ctx, Prompts.Block, :copy, nil)
        {attrs, state} = visibility_attrs(state, item, attrs(item), owner)

        {block, state} =
          if update? do
            block = ok!(Prompts.update_block(ctx.scope, match, attrs))
            {block, note_name(state, :prompt_block, block.name)}
          else
            {name, state} =
              copy_name(state, :prompt_block, item.name, fn -> Prompts.list_editable_blocks(ctx.scope) end)

            {ok!(Prompts.create_block(ctx.scope, Map.put(attrs, "name", name))), state}
          end

        {block, written(state, ctx, item, block)}
    end
  end

  ## 2. AI models

  defp write_models(state, ctx) do
    each_item(state, ctx, :ai_model, fn item, mode, match, state ->
      {caption_prompt, state} = resolve(state, ctx, :prompt, item.data["caption_prompt"], item.name)

      attrs =
        item
        |> attrs()
        |> Map.put("caption_prompt_id", id(caption_prompt))
        |> then(&if(is_map(item.data["sampler"]), do: Map.put(&1, "sampler", item.data["sampler"]), else: &1))

      case mode do
        :copy ->
          {name, state} = copy_name(state, :ai_model, item.name, fn -> AI.list_editable_models(ctx.scope) end)
          {ok!(AI.create_model(ctx.scope, Map.put(attrs, "name", name))), state}

        :replace ->
          model = ok!(AI.update_model(ctx.scope, match, attrs))
          {model, note_name(state, :ai_model, model.name)}
      end
    end)
  end

  ## 3. Characters

  defp write_characters(state, ctx) do
    each_item(state, ctx, :character, fn item, mode, match, state ->
      owner = import_owner(ctx, Characters.Character, mode, match)
      {attrs, state} = visibility_attrs(state, item, attrs(item), owner)

      character =
        case mode do
          :copy -> ok!(Characters.create_character(ctx.scope, attrs, import: true))
          :replace -> ok!(Characters.update_character(ctx.scope, match, attrs, import: true))
        end

      state =
        case ctx.bundle.blobs[item.data["avatar"]] do
          %{bytes: bytes} when is_binary(bytes) -> %{state | avatars: [{character, bytes} | state.avatars]}
          _ -> state
        end

      {character, state}
    end)
  end

  ## 4. Lore books

  defp write_books(state, ctx) do
    each_item(state, ctx, :lore_book, fn item, mode, match, state ->
      owner = import_owner(ctx, LoreBook, mode, match)
      {attrs, state} = book_attrs(state, item, owner)

      {book, state} =
        case mode do
          :copy ->
            {name, state} = copy_name(state, :lore_book, item.name, fn -> Lore.list_books(ctx.scope) end)
            {ok!(Lore.create_book(ctx.scope, Map.put(attrs, "name", name), import: true)), state}

          :replace ->
            book = ok!(Lore.update_book(ctx.scope, match, attrs, import: true))
            {book, note_name(state, :lore_book, book.name)}
        end

      ok!(Lore.set_book_filter_tags(ctx.scope, book, item.data["filter_tags"] || []))
      {book, %{state | book_ids: [book.id | state.book_ids]}}
    end)
  end

  # A user's book is always readable and never forced (those are site-lore controls).
  defp book_attrs(state, item, nil), do: {book_item_attrs(item), state}

  defp book_attrs(state, item, _user_id) do
    attrs = book_item_attrs(item)
    forced = Map.merge(attrs, %{"site_visibility" => "readable", "forced" => false})

    if Map.get(attrs, "site_visibility", "readable") != "readable" or Map.get(attrs, "forced", false) == true,
      do:
        {forced,
         warn(
           state,
           dgettext(
             "import_export",
             "'%{item_name}' can't be hidden or forced outside the site's lore; imported readable.",
             item_name: item.name
           )
         )},
      else: {forced, state}
  end

  # Bundles written before site visibility carry `user_visibility` (`visible`/`names_only`/`hidden`).
  @legacy_visibility %{"visible" => "readable", "names_only" => "runtime_only", "hidden" => "hidden"}

  defp book_item_attrs(item) do
    attrs = attrs(item)

    case item.data do
      %{"site_visibility" => _} -> attrs
      %{"user_visibility" => legacy} -> Map.put(attrs, "site_visibility", Map.get(@legacy_visibility, legacy, legacy))
      _ -> attrs
    end
  end

  defp import_owner(ctx, schema, :copy, _match) do
    case Ownership.new_owner(ctx.scope, schema) do
      {:ok, owner} -> owner
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp import_owner(_ctx, _schema, :replace, match), do: match.user_id

  # A personal row is always readable (runtime-only is a site control).
  defp visibility_attrs(state, _item, attrs, nil), do: {attrs, state}

  defp visibility_attrs(state, item, attrs, _user_id) do
    if Map.get(attrs, "site_visibility", "readable") == "readable",
      do: {attrs, state},
      else:
        {Map.put(attrs, "site_visibility", "readable"),
         warn(
           state,
           dgettext(
             "import_export",
             "'%{item_name}' can't be runtime-only outside the site's content; imported readable.",
             item_name: item.name
           )
         )}
  end

  ## 5. Lore entries, pools, outlets

  defp write_entries(state, ctx) do
    # Books written by this import, and for each entry uid its `{book, membership}` targets.
    books =
      for item <- items(ctx, :lore_book), %LoreBook{} = book <- [state.written[item.uid]], do: {item, book}

    targets =
      Enum.reduce(books, %{}, fn {item, book}, acc ->
        (item.data["entries"] || [])
        |> Enum.reduce(acc, fn link, acc ->
          Map.update(acc, link["uid"], [{book, link}], &(&1 ++ [{book, link}]))
        end)
      end)

    replaced = for {item, book} <- books, ctx.decisions[item.uid] == :replace, do: book

    state =
      ctx
      |> items(:lore_entry)
      |> Enum.filter(&Map.has_key?(targets, &1.uid))
      |> Enum.reduce(state, &write_entry(&2, ctx, &1, targets[&1.uid], replaced))

    state =
      for {%{} = link, group} <- targets, {book, membership} <- group, reduce: state do
        state -> link_entry(state, ctx, link, book, membership)
      end

    # A replaced book keeps only the bundle's entries.
    Enum.reduce(replaced, state, fn book, state ->
      kept =
        state.entries
        |> Map.values()
        |> Enum.concat()
        |> Enum.flat_map(fn {entry, entry_books} ->
          if book.id in Enum.map(entry_books, & &1.id), do: [entry.id], else: []
        end)

      from(be in BookEntry,
        where: be.lore_book_id == ^book.id and be.lore_entry_id not in ^kept,
        select: be.lore_entry_id
      )
      |> Repo.all()
      |> Enum.each(&ok!(Lore.remove_entry_from_book(ctx.scope, book, %LoreEntry{id: &1})))

      state
    end)
  end

  defp write_entry(state, ctx, item, targets, replaced) do
    attrs = attrs(item)
    replaced_ids = MapSet.new(replaced, & &1.id)

    match =
      if Enum.any?(targets, fn {book, _} -> book.id in replaced_ids end),
        do: Origins.match(ctx.scope, :lore_entry, item.uid)

    {rows, state} =
      targets
      |> Enum.group_by(fn {book, _} -> book.user_id end)
      |> Enum.reduce({[], state}, fn {owner, group}, {rows, state} ->
        group_books = Enum.map(group, &elem(&1, 0))

        case write_entry_row(state, ctx, item, attrs, owner, group_books, match, replaced_ids) do
          {nil, state} ->
            {rows, state}

          {entry, state} ->
            state = entry_links(state, ctx, item, entry, group)
            {rows ++ [{entry, group_books}], state}
        end
      end)

    case rows do
      [] ->
        state

      [{first, _} | _] ->
        state = put_in(state.entries[item.uid], rows)
        state = written(state, ctx, item, first)

        rows
        |> Enum.drop(1)
        |> Enum.reduce(state, fn {entry, _}, state ->
          :ok = Origins.record!(:lore_entry, entry.id, item.uid)
          set_tags(state, ctx, item, entry)
        end)
    end
  end

  # An entry outside the bundle joins `book` when it is the book owner's and `scope` may edit it.
  defp link_entry(state, ctx, link, book, membership) do
    case resolve(state, ctx, :lore_entry, link, book.name) do
      {nil, state} ->
        state

      {entry, state} ->
        if entry.user_id == book.user_id and Ownership.authorize_edit(ctx.scope, entry) == :ok do
          current = Repo.all(from(be in BookEntry, where: be.lore_entry_id == ^entry.id, select: be.lore_book_id))
          ok!(Lore.set_entry_books(ctx.scope, entry, Enum.uniq(current ++ [book.id])))
          order = membership["order"]
          if is_integer(order), do: ok!(Lore.set_membership_order(ctx.scope, book, entry.id, order))
          ok!(Lore.set_membership_enabled(ctx.scope, book, entry.id, membership["enabled"] != false))

          books =
            case state.entries[link["uid"]] do
              [{_entry, books}] -> books
              _ -> []
            end

          put_in(state.entries[link["uid"]], [{entry, books ++ [book]}])
        else
          warn(
            state,
            dgettext("import_export", "'%{book_name}' couldn't be linked to the lore entry '%{entry_name}'.",
              book_name: book.name,
              entry_name: entry.name
            )
          )
        end
    end
  end

  defp write_entry_row(state, ctx, item, attrs, owner, books, match, replaced_ids) do
    if outlet = custom_outlet(ctx, item), do: ensure_outlet(ctx.scope, owner, outlet)
    book_ids = Enum.map(books, & &1.id)

    replaceable =
      match && match.user_id == owner && Ownership.authorize_edit(ctx.scope, match) == :ok &&
        Repo.exists?(
          from(be in BookEntry,
            where: be.lore_entry_id == ^match.id and be.lore_book_id in ^MapSet.to_list(replaced_ids)
          )
        ) && Enum.any?(book_ids, &MapSet.member?(replaced_ids, &1))

    if replaceable do
      entry = ok!(Lore.update_entry(ctx.scope, match, attrs, import: true))
      current = Repo.all(from(be in BookEntry, where: be.lore_entry_id == ^entry.id, select: be.lore_book_id))
      ok!(Lore.set_entry_books(ctx.scope, entry, Enum.uniq(current ++ book_ids)))
      {entry, state}
    else
      changeset = LoreEntry.import_changeset(%LoreEntry{}, attrs)

      if changeset.valid?,
        do: {ok!(Lore.create_entry(ctx.scope, attrs, book_ids, %{}, import: true)), state},
        else:
          {nil,
           warn(
             state,
             dpgettext(
               "import_export",
               "status: import warning, a lore entry was skipped",
               "'%{item_name}' skipped: %{field_errors}",
               item_name: item.name,
               field_errors: errors(changeset)
             )
           )}
    end
  end

  defp custom_outlet(ctx, item) do
    with "custom" <- item.data["outlet"],
         key when is_binary(key) and key != "" <- item.data["custom_outlet"] do
      case ctx.outlets[key] do
        %{data: data} -> %{key: key, name: data["name"] || key, description: data["description"]}
        nil -> %{key: key, name: key}
      end
    else
      _ -> nil
    end
  end

  defp entry_links(state, ctx, item, entry, group) do
    for {book, link} <- group do
      if is_integer(link["order"]), do: ok!(Lore.set_membership_order(ctx.scope, book, entry.id, link["order"]))
      ok!(Lore.set_membership_enabled(ctx.scope, book, entry.id, link["enabled"] != false))
    end

    {characters, state} =
      Enum.map_reduce(item.data["filter_characters"] || [], state, &resolve(&2, ctx, :character, &1, item.name))

    character_ids =
      for %{} = c <- characters, Ownership.reference_ok?(entry.user_id, c), uniq: true, do: c.id

    ok!(Lore.set_entry_filter_characters(ctx.scope, entry, character_ids))
    ok!(Lore.set_entry_filter_tags(ctx.scope, entry, item.data["filter_tags"] || []))
    write_pools(state, ctx, entry, item.data["pools"] || [])
  end

  defp write_pools(state, ctx, entry, links) do
    {pools, state} =
      Enum.flat_map_reduce(links, state, fn link, state ->
        case entry_pool(state, ctx, entry, link["uid"]) do
          {nil, state} -> {[], state}
          {pool, state} -> {[{pool, link}], state}
        end
      end)

    pools = Enum.uniq_by(pools, fn {pool, _} -> pool.id end)
    ok!(Lore.set_entry_pools(ctx.scope, entry, Enum.map(pools, fn {pool, _} -> pool.id end)))

    flags = for {pool, link} <- pools, attrs = membership_attrs(link), attrs != %{}, into: %{}, do: {pool.id, attrs}
    if flags != %{}, do: ok!(Lore.set_pool_memberships(ctx.scope, entry, flags))

    state
  end

  defp membership_attrs(link) do
    weight = if is_integer(link["weight"]), do: %{weight: link["weight"]}, else: %{}

    for key <- [:override, :scored],
        is_boolean(link[Atom.to_string(key)]),
        into: weight,
        do: {key, link[Atom.to_string(key)]}
  end

  # A bundle pool (`pool/4`); a ref is matched, and used when it is the entry owner's.
  defp entry_pool(state, ctx, entry, uid) when is_binary(uid) do
    case ctx.items[uid] do
      %{kind: :lore_pool} = item -> pool(state, ctx, item, entry.user_id)
      _ -> {nil, state}
    end
  end

  defp entry_pool(state, ctx, entry, link) do
    owner = entry.user_id

    case resolve(state, ctx, :lore_pool, link, entry.name) do
      {nil, state} ->
        {nil, state}

      {%{user_id: ^owner} = pool, state} ->
        {pool, state}

      {pool, state} ->
        {nil,
         warn(
           state,
           dgettext("import_export", "'%{entry_name}' couldn't be linked to the lore pool '%{pool_name}'.",
             entry_name: entry.name,
             pool_name: pool.name
           )
         )}
    end
  end

  # A shared pool: one this import wrote, a usable local match with the entry's owner, else new.
  defp pool(state, ctx, item, owner) do
    case state.written[item.uid] do
      nil ->
        case Origins.match(ctx.scope, :lore_pool, item.uid) do
          %{user_id: ^owner} = pool ->
            {pool, state}

          _ ->
            {name, state} = copy_name(state, :lore_pool, item.name, fn -> Lore.list_pools(ctx.scope) end)
            pool = ok!(Lore.create_pool(ctx.scope, Map.put(attrs(item), "name", name)))
            {pool, written(state, ctx, item, pool)}
        end

      pool ->
        {pool, state}
    end
  end

  ## 6. Character ↔ book bindings (additive)

  defp bind_character_books(state, ctx) do
    ctx
    |> items(:character)
    |> Enum.filter(&match?(%Characters.Character{}, state.written[&1.uid]))
    |> Enum.reduce(state, fn item, state ->
      character = state.written[item.uid]

      Enum.reduce(item.data["books"] || [], state, fn link, state ->
        case resolve(state, ctx, :lore_book, link["uid"], item.name) do
          {nil, state} -> state
          {book, state} -> bind_character_book(state, ctx, item, character, book, link["enabled"] != false)
        end
      end)
    end)
  end

  defp bind_character_book(state, ctx, item, character, book, enabled) do
    binding =
      case Repo.get_by(BookCharacter, lore_book_id: book.id, character_id: character.id) do
        nil ->
          case Lore.bind_book_to_character(book, character.id) do
            {:ok, binding} -> binding
            {:error, _} -> nil
          end

        binding ->
          binding
      end

    cond do
      is_nil(binding) ->
        warn(
          state,
          dgettext("import_export", "'%{item_name}' couldn't be linked to the lore book '%{book_name}'.",
            item_name: item.name,
            book_name: book.name
          )
        )

      binding.enabled != enabled ->
        case Lore.set_binding_enabled(ctx.scope, binding, enabled) do
          {:ok, _} ->
            state

          {:error, _} ->
            warn(
              state,
              dgettext("import_export", "'%{item_name}' couldn't be linked to the lore book '%{book_name}'.",
                item_name: item.name,
                book_name: book.name
              )
            )
        end

      true ->
        state
    end
  end

  ## 7. Scripts

  defp write_scripts(state, ctx) do
    state =
      each_item(state, ctx, :script, fn item, mode, match, state ->
        owner = import_owner(ctx, Scripts.Script, mode, match)
        {attrs, state} = visibility_attrs(state, item, attrs(item), owner)

        case mode do
          :copy ->
            {name, state} = copy_name(state, :script, item.name, fn -> Scripts.list_scripts(ctx.scope) end)
            {ok!(Scripts.create_script(ctx.scope, Map.put(attrs, "name", name))), state}

          :replace ->
            script = ok!(Scripts.update_script(ctx.scope, match, attrs))
            {script, note_name(state, :script, script.name)}
        end
      end)

    ctx
    |> items(:script)
    |> Enum.filter(&(ctx.decisions[&1.uid] in [:copy, :replace] and Map.has_key?(state.written, &1.uid)))
    |> Enum.reduce(state, fn item, state ->
      {deps, state} =
        Enum.map_reduce(item.data["dependencies"] || [], state, &resolve(&2, ctx, :script, &1, item.name))

      script =
        ok!(
          Scripts.update_script(ctx.scope, state.written[item.uid], %{
            "dependency_ids" => deps |> Enum.reject(&is_nil/1) |> Enum.map(& &1.id) |> Enum.uniq()
          })
        )

      put_in(state.written[item.uid], script)
    end)
  end

  ## 8. Memory profiles, side prompts, side prompt sets

  defp write_profiles(state, ctx) do
    each_item(state, ctx, :memory_profile, fn item, mode, match, state ->
      {model, state} = resolve(state, ctx, :ai_model, item.data["model"], item.name)
      prompts = item.data["prompts"] || %{}

      {attrs, state} =
        Enum.reduce(@profile_prompts, {Map.put(attrs(item), "ai_model_id", id(model)), state}, fn key, {attrs, state} ->
          {prompt, state} = resolve(state, ctx, :prompt, prompts[key], item.name)
          {Map.put(attrs, "#{key}_id", id(prompt)), state}
        end)

      case mode do
        :copy ->
          {name, state} =
            copy_name(state, :memory_profile, item.name, fn ->
              ctx.scope |> Memory.list_usable_profiles() |> Enum.filter(&editable?(ctx, &1))
            end)

          {ok!(Memory.create_profile(ctx.scope, Map.put(attrs, "name", name))), state}

        :replace ->
          profile = ok!(Memory.update_profile(ctx.scope, match, attrs))
          {profile, note_name(state, :memory_profile, profile.name)}
      end
    end)
  end

  defp write_side_prompts(state, ctx) do
    each_item(state, ctx, :side_prompt, fn item, mode, match, state ->
      {prompt, state} = resolve(state, ctx, :prompt, item.data["prompt"], item.name)
      {profile, state} = resolve(state, ctx, :memory_profile, item.data["profile"], item.name)
      {book, state} = resolve(state, ctx, :lore_book, item.data["target_book"], item.name)

      attrs =
        item
        |> attrs()
        |> Map.merge(%{"prompt_id" => id(prompt), "profile_id" => id(profile), "target_book_id" => id(book)})

      case mode do
        :copy ->
          {name, state} =
            copy_name(state, :side_prompt, item.name, fn ->
              ctx.scope |> Memory.list_usable_side_prompts() |> Enum.filter(&editable?(ctx, &1))
            end)

          {ok!(Memory.create_side_prompt(ctx.scope, Map.put(attrs, "name", name))), state}

        :replace ->
          side_prompt = ok!(Memory.update_side_prompt(ctx.scope, match, attrs))
          {side_prompt, note_name(state, :side_prompt, side_prompt.name)}
      end
    end)
  end

  defp write_side_prompt_sets(state, ctx) do
    each_item(state, ctx, :side_prompt_set, fn item, mode, match, state ->
      {rows, state} =
        Enum.flat_map_reduce(item.data["rows"] || [], state, fn row, state ->
          case resolve(state, ctx, :side_prompt, row["side_prompt"], item.name) do
            {nil, state} ->
              {[],
               warn(
                 state,
                 dgettext("import_export", "A row of '%{set_name}' was dropped: its side prompt isn't here.",
                   set_name: item.name
                 )
               )}

            {side_prompt, state} ->
              {[
                 %{
                   "side_prompt_id" => side_prompt.id,
                   "label" => row["label"],
                   "macro_values" => row["macro_values"] || %{}
                 }
               ], state}
          end
        end)

      attrs = Map.put(attrs(item), "rows", rows)

      case mode do
        :copy ->
          {name, state} =
            copy_name(state, :side_prompt_set, item.name, fn ->
              ctx.scope |> Memory.list_usable_side_prompt_sets() |> Enum.filter(&editable?(ctx, &1))
            end)

          {ok!(Memory.create_side_prompt_set(ctx.scope, Map.put(attrs, "name", name))), state}

        :replace ->
          set = ok!(Memory.update_side_prompt_set(ctx.scope, match, attrs))
          {set, note_name(state, :side_prompt_set, set.name)}
      end
    end)
  end

  defp editable?(ctx, row), do: Ownership.authorize_edit(ctx.scope, row) == :ok

  ## 9. Model caption links

  defp link_caption_models(state, ctx) do
    ctx
    |> items(:ai_model)
    |> Enum.filter(&(ctx.decisions[&1.uid] in [:copy, :replace] and &1.data["caption_model"] != nil))
    |> Enum.reduce(state, fn item, state ->
      case {state.written[item.uid], resolve(state, ctx, :ai_model, item.data["caption_model"], item.name)} do
        {%AI.Model{} = model, {%AI.Model{} = caption, state}} ->
          put_in(state.written[item.uid], ok!(AI.update_model(ctx.scope, model, %{"caption_model_id" => caption.id})))

        {_, {_, state}} ->
          state
      end
    end)
  end

  ## 10. Chats

  defp write_chats(state, ctx) do
    state =
      each_item(state, ctx, :chat, fn item, mode, match, state ->
        if mode == :replace, do: ok!(Chats.delete_chat(ctx.scope, match))
        {chat, state} = write_chat(state, ctx, item)
        {chat, %{state | chats: MapSet.put(state.chats, item.uid)}}
      end)

    state
  end

  defp write_chat(state, ctx, item) do
    data = item.data

    {participants, state} =
      Enum.flat_map_reduce(data["participants"] || [], state, fn p, state ->
        case resolve(state, ctx, :character, p["character"], item.name) do
          {nil, state} ->
            {[], state}

          {character, state} ->
            {model, state} = resolve(state, ctx, :ai_model, p["model"], item.name)

            {[
               %{
                 "character_id" => character.id,
                 "ai_model_id" => id(model),
                 "muted" => p["muted"] || false,
                 "talkativeness" => p["talkativeness"]
               }
             ], state}
        end
      end)

    participants = Enum.uniq_by(participants, & &1["character_id"])
    {player, state} = resolve(state, ctx, :character, data["player"], nil)

    if is_nil(player),
      do: Repo.rollback(dgettext("import_export", "'%{chat_name}' needs its player character.", chat_name: item.name))

    participants =
      if Enum.any?(participants, &(&1["character_id"] == player.id)),
        do: participants,
        else: [%{"character_id" => player.id} | participants]

    if length(participants) < 2,
      do:
        Repo.rollback(
          dgettext("import_export", "'%{chat_name}' needs at least two of its characters.", chat_name: item.name)
        )

    {model, state} = resolve(state, ctx, :ai_model, data["model"], item.name)

    chat =
      ok!(
        Chats.create_chat(ctx.scope, %{
          "name" => data["name"],
          "player_character_id" => player.id,
          "ai_model_id" => id(model),
          "participants" => participants
        })
      )

    chat = ok!(Chats.update_chat(ctx.scope, chat, Map.delete(attrs(item), "name")))
    {chat, state} = write_messages(state, ctx, item, chat)
    state = chat_books(state, ctx, item, chat)

    {prompt, state} = resolve(state, ctx, :prompt, data["prompt"], item.name)
    if prompt, do: ok!(Prompts.set_chat_prompt(chat, prompt.id))

    for injection <- data["injections"] || [],
        do: ok!(Injections.create_injection(ctx.scope, chat.id, injection))

    for variable <- data["variables"] || [],
        do: ok!(Mythweaver.Variables.create_variable(ctx.scope, chat.id, Map.take(variable, ["key", "value"])))

    state = chat_memory(state, ctx, item, chat)
    {chat, state}
  end

  defp write_messages(state, ctx, item, chat) do
    {entries, state} =
      Enum.map_reduce(ctx.bundle.messages[item.uid] || [], state, fn message, state ->
        {author, state} = resolve(state, ctx, :character, message["author"], nil)

        {attachments, state} = blobs(state, ctx, message["attachments"] || [])

        {bodies, state} =
          Enum.map_reduce(message["bodies"] || [], state, fn body, state ->
            {body_attachments, state} = blobs(state, ctx, body["attachments"] || [])
            {body(body, body_attachments), state}
          end)

        at = datetime(message["inserted_at"]) || DateTime.utc_now()

        entry = %{
          author_character_id: id(author),
          author_name: if(!author, do: message["author_name"]),
          visible_to_ai: message["visible_to_ai"] != false,
          inserted_at: at,
          bodies: bodies,
          active: Enum.find_index(message["bodies"] || [], & &1["active"]) || 0,
          attachments: attachments
        }

        {entry, state}
      end)

    entries = Enum.reject(entries, &(&1.bodies == []))
    if entries != [], do: :ok = Messages.import_transcript(chat, entries)
    {chat, state}
  end

  defp body(body, attachments) do
    %{
      content: body["content"] || "",
      reasoning: body["reasoning"],
      origin: enum(MessageBody, :origin, body["origin"]),
      guide: body["guide"],
      finish_reason: body["finish_reason"],
      prompt_tokens: body["prompt_tokens"],
      completion_tokens: body["completion_tokens"],
      total_tokens: body["total_tokens"],
      cost: decimal(body["cost"]),
      cost_estimated: body["cost_estimated"] == true,
      generation_ms: body["generation_ms"],
      error: body["error"],
      inserted_at: datetime(body["inserted_at"]),
      attachments: attachments
    }
  end

  # Bundle blobs as stored attachments, one per blob uid for the whole import.
  defp blobs(state, ctx, uids) do
    Enum.flat_map_reduce(uids, state, fn uid, state ->
      case {state.blobs[uid], ctx.bundle.blobs[uid]} do
        {%Attachments.Attachment{} = attachment, _} ->
          {[attachment], state}

        {nil, %{bytes: bytes} = blob} when is_binary(bytes) ->
          with {:ok, attachment} <-
                 Attachments.store_upload(ctx.scope, bytes, filename: blob[:filename], kinds: [blob.kind]),
               {:ok, attachment} <- Attachments.restore_description(attachment, blob[:description]) do
            {[attachment], put_in(state.blobs[uid], attachment)}
          else
            _ ->
              {[],
               warn(
                 state,
                 dgettext("import_export", "A file (%{file_name}) couldn't be saved.",
                   file_name: blob[:filename] || uid
                 )
               )}
          end

        _ ->
          {[], state}
      end
    end)
  end

  defp chat_books(state, ctx, item, chat) do
    {books, state} =
      Enum.flat_map_reduce(item.data["books"] || [], state, fn link, state ->
        case resolve(state, ctx, :lore_book, link["uid"], item.name) do
          {nil, state} -> {[], state}
          {book, state} -> {[{book, link["enabled"] != false}], state}
        end
      end)

    books = Enum.uniq_by(books, fn {book, _} -> book.id end)

    case Lore.set_chat_books(chat, Enum.map(books, fn {book, _} -> book.id end)) do
      {:ok, _} ->
        disabled = for {book, false} <- books, do: book.id

        if disabled != [] do
          from(bc in BookChat, where: bc.chat_id == ^chat.id and bc.lore_book_id in ^disabled)
          |> Repo.all()
          |> Enum.each(&ok!(Lore.set_binding_enabled(ctx.scope, &1, false)))
        end

        state

      {:error, _} ->
        warn(
          state,
          dgettext("import_export", "'%{item_name}' couldn't be linked to its lore books.", item_name: item.name)
        )
    end
  end

  @settings_fields ~w(auto_enabled auto_trigger auto_interval auto_buffer auto_token_threshold auto_hide
                      leave_unhidden side_prompt_set_mode)

  defp chat_memory(state, _ctx, %{data: %{"memory" => memory}}, _chat) when not is_map(memory), do: state
  defp chat_memory(state, _ctx, %{data: data}, _chat) when not is_map_key(data, "memory"), do: state

  defp chat_memory(state, ctx, item, chat) do
    memory = item.data["memory"]
    name = item.name
    {book, state} = resolve(state, ctx, :lore_book, memory["memory_book"], name)
    {profile, state} = resolve(state, ctx, :memory_profile, memory["profile"], name)
    {set, state} = resolve(state, ctx, :side_prompt_set, memory["side_prompt_set"], name)

    {entries, state} =
      Enum.map_reduce(memory["context_entry_ids"] || [], state, &resolve(&2, ctx, :lore_entry, &1, name))

    {side_books, state} =
      Enum.flat_map_reduce(memory["side_prompt_book_ids"] || [], state, fn pair, state ->
        {side_prompt, state} = resolve(state, ctx, :side_prompt, pair["side_prompt"], name)
        {book, state} = resolve(state, ctx, :lore_book, pair["book"], name)
        {if(side_prompt && book, do: [{side_prompt.id, book.id}], else: []), state}
      end)

    {character_books, state} =
      Enum.flat_map_reduce(memory["character_book_ids"] || [], state, fn pair, state ->
        {character, state} = resolve(state, ctx, :character, pair["character"], name)
        {book, state} = resolve(state, ctx, :lore_book, pair["book"], name)
        {if(character && book, do: [{character.id, book.id}], else: []), state}
      end)

    {cast, state} = Enum.map_reduce(memory["cast_ids"] || [], state, &resolve(&2, ctx, :character, &1, name))

    attrs =
      memory
      |> Map.take(@settings_fields)
      |> Map.merge(%{
        "memory_book_id" => id(book),
        "profile_id" => id(profile),
        "side_prompt_set_id" => id(set),
        "context_entry_ids" => entries |> Enum.reject(&is_nil/1) |> Enum.map(& &1.id) |> Enum.uniq(),
        "side_prompt_book_ids" => Map.new(side_books),
        "character_book_ids" => Map.new(character_books),
        "cast_ids" => cast |> Enum.reject(&is_nil/1) |> Enum.map(& &1.id) |> Enum.uniq()
      })

    settings = Memory.chat_settings(ctx.scope, chat)

    case Memory.update_chat_settings(ctx.scope, settings, attrs) do
      {:ok, settings} ->
        :ok = Memory.restore_progress(settings, memory["highest_processed"])
        state

      {:error, _} ->
        :ok = Memory.restore_progress(settings, memory["highest_processed"])

        warn(
          state,
          dgettext("import_export", "'%{item_name}''s memory settings couldn't be restored.", item_name: name)
        )
    end
  end

  ## 11. Memory records

  defp write_records(state, ctx) do
    entry_ids = Map.new(state.entries, fn {uid, [{entry, _} | _]} -> {uid, entry.id} end)

    by_book =
      for item <- items(ctx, :lore_entry),
          is_map(item.data["memory"]),
          {entry, books} <- state.entries[item.uid] || [],
          book <- books,
          reduce: %{} do
        acc -> Map.update(acc, book, [{item, entry}], &(&1 ++ [{item, entry}]))
      end

    Enum.reduce(by_book, state, fn {book, pairs}, state ->
      {specs, state} =
        Enum.map_reduce(pairs, state, fn {item, entry}, state -> record_spec(state, ctx, item, entry, entry_ids) end)

      ok!(Memory.import_records(ctx.scope, book, specs))
      state
    end)
  end

  defp record_spec(state, ctx, item, entry, entry_ids) do
    memory = item.data["memory"]

    chat =
      with uid when is_binary(uid) <- memory["chat"],
           true <- MapSet.member?(state.chats, uid),
           do: state.written[uid],
           else: (_ -> nil)

    {profile, state} = resolve(state, ctx, :memory_profile, memory["profile"], item.name)
    {prompt, state} = resolve(state, ctx, :prompt, memory["prompt"], item.name)
    {side_prompt, state} = resolve(state, ctx, :side_prompt, memory["side_prompt"], item.name)

    spec = %{
      entry_id: entry.id,
      kind: enum(Record, :kind, memory["kind"]),
      tier: memory["tier"],
      sequence: memory["sequence"],
      range_start: if(chat, do: memory["range_start"]),
      range_end: if(chat, do: memory["range_end"]),
      chat_id: id(chat),
      scene_fingerprint: memory["scene_fingerprint"],
      written_fingerprint: memory["written_fingerprint"],
      disabled_by_consolidation: memory["disabled_by_consolidation"] == true,
      version: memory["version"],
      snapshot: memory["snapshot"] || %{},
      profile_id: id(profile),
      prompt_id: id(prompt),
      side_prompt_id: id(side_prompt),
      consolidated_into_entry_id: record_entry_id(state, ctx, memory["consolidated_into"], entry_ids),
      canonical_entry_id: record_entry_id(state, ctx, memory["canonical"], entry_ids),
      source_entry_ids:
        (memory["sources"] || []) |> Enum.map(&record_entry_id(state, ctx, &1, entry_ids)) |> Enum.reject(&is_nil/1)
    }

    {spec, state}
  end

  # A record link's entry: one this import wrote or linked, else the local entry a ref matches.
  defp record_entry_id(_state, _ctx, uid, entry_ids) when is_binary(uid), do: entry_ids[uid]

  defp record_entry_id(state, ctx, link, _entry_ids) do
    {entry, _state} = resolve(state, ctx, :lore_entry, link, nil)
    id(entry)
  end

  ## Value conversion

  defp enum(_schema, _field, nil), do: nil

  defp enum(schema, field, value) when is_binary(value) do
    Enum.find_value(Ecto.Enum.mappings(schema, field), fn {atom, string} -> if string == value, do: atom end)
  end

  defp enum(_schema, _field, value) when is_atom(value), do: value

  defp datetime(nil), do: nil

  defp datetime(string) when is_binary(string) do
    case DateTime.from_iso8601(string) do
      {:ok, %DateTime{microsecond: {us, _}} = at, _offset} -> %{at | microsecond: {us, 6}}
      _ -> nil
    end
  end

  defp decimal(nil), do: nil
  defp decimal(value) when is_binary(value), do: Decimal.new(value)
  defp decimal(value) when is_number(value), do: Decimal.from_float(value * 1.0)
end
