defmodule Mythweaver.Import.Writer do
  @moduledoc """
  Writes a parsed import (`Mythweaver.Import.parse/2`) for a scope; `Mythweaver.Import.import/3`
  is the public entry point.

  Each kind runs in one `Repo.transaction`, so a failure leaves nothing behind. Lore entries are
  validated before `Lore.create_entry/4`, whose inner rollback would abort the whole import: an
  invalid entry is skipped with a warning instead. Owners follow each context's
  `Ownership.new_owner/2`, so an admin's imports are site rows. Book, prompt and block names are
  made unique against the scope's editable rows; character names may repeat.
  """

  use Gettext, backend: Mythweaver.Gettext

  import Mythweaver.Import.WriterHelpers

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Import.BundleWriter
  alias Mythweaver.Lore
  alias Mythweaver.Lore.Embeddings
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Lore.PoolEntry
  alias Mythweaver.Memory
  alias Mythweaver.Messages
  alias Mythweaver.Ownership
  alias Mythweaver.Prompts
  alias Mythweaver.Repo
  alias Mythweaver.Schema

  @type result :: {:ok, %{kind: atom(), record: struct(), warnings: [String.t()]}} | {:error, String.t()}

  @spec import(Scope.t(), map(), keyword()) :: result()
  def import(%Scope{} = scope, %{kind: :character} = parsed, _opts) do
    with {:ok, {character, warnings, book_ids}} <- transaction(fn -> write_character(scope, parsed) end) do
      :ok = Embeddings.refresh_books_later(scope, book_ids)

      after_commit =
        store_avatar(scope, character, parsed[:avatar]) ++ store_tags(scope, character, parsed[:tags] || [])

      {:ok, %{kind: :character, record: character, warnings: warnings ++ after_commit}}
    end
  end

  def import(%Scope{} = scope, %{kind: :lore_book} = parsed, _opts) do
    with {:ok, {book, warnings}} <-
           transaction(fn -> write_book(scope, parsed.name, parsed.book, parsed.entries) end) do
      :ok = Embeddings.refresh_books_later(scope, [book.id])
      {:ok, %{kind: :lore_book, record: book, warnings: warnings}}
    end
  end

  def import(%Scope{} = scope, %{kind: :chat} = parsed, opts) do
    speakers = Keyword.get(opts, :speakers, %{})
    player = Keyword.get(opts, :player)

    if match?({:character, _}, speakers[player]) or speakers[player] == :create do
      with {:ok, chat} <- transaction(fn -> write_chat(scope, parsed, player, speakers) end) do
        {:ok, %{kind: :chat, record: chat, warnings: []}}
      end
    else
      {:error, choose_player()}
    end
  end

  def import(%Scope{} = scope, %{kind: :preset} = parsed, opts) do
    with {:ok, prompt} <- transaction(fn -> write_preset(scope, parsed, opts[:model_id]) end) do
      {:ok, %{kind: :preset, record: prompt, warnings: []}}
    end
  end

  def import(%Scope{} = scope, %{kind: :bundle} = parsed, opts), do: BundleWriter.import(scope, parsed, opts)

  ## Characters

  defp write_character(scope, parsed) do
    character =
      parsed
      |> Map.take([
        :name,
        :description,
        :first_message,
        :alternate_greetings,
        :group_greetings,
        :creator,
        :creator_notes,
        :character_version,
        :talkativeness,
        :system_prompt,
        :post_history_instructions,
        :source_file,
        :foreign
      ])
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
      |> then(&Characters.create_character(scope, &1, import: true))
      |> ok!()

    {card_warnings, card_book_id} =
      case parsed.card_fields do
        [] ->
          {[], nil}

        fields ->
          book =
            ok!(
              Lore.create_book(
                scope,
                %{
                  name: unique_name("#{parsed.name} (card)", book_names(scope)),
                  description: "Imported from #{parsed.name}'s character card.",
                  kind: :card
                },
                import: true
              )
            )

          warnings = write_entries(scope, book, fields)
          ok!(Lore.bind_book_to_character(book, character.id))
          {warnings, book.id}
      end

    {book_warnings, book_id} =
      case world_book(scope, parsed, character) do
        {:linked, book, warnings} ->
          ok!(Lore.bind_book_to_character(book, character.id))
          {warnings, nil}

        {:embedded, nil, warnings} ->
          {warnings, nil}

        {:embedded, spec, warnings} ->
          {book, book_warnings} = write_book(scope, spec.name, spec.book, spec.entries)
          ok!(Lore.bind_book_to_character(book, character.id))
          {warnings ++ book_warnings, book.id}
      end

    {character, card_warnings ++ book_warnings, Enum.reject([card_book_id, book_id], &is_nil/1)}
  end

  # The World Info book a card links (`extensions.world`): an existing book of that name `scope` may
  # use is bound instead of the embedded copy, as SillyTavern uses the linked world and offers the
  # embedded book only when it's missing. There's no batch import, so the linked file must have
  # been imported first. It binds like `Lore.bind_book_to_character/2`: the book's owner must be
  # able to reference the character, so a site book links only a site character; one that can't is
  # warned about as such, not as missing.
  defp world_book(_scope, %{world: nil} = parsed, _character), do: {:embedded, parsed.book, []}

  defp world_book(scope, %{world: world} = parsed, character) do
    book = Lore.find_usable_book_by_name(scope, world)
    linked = if book && Ownership.reference_ok?(book.user_id, character), do: book

    cond do
      linked && parsed.book ->
        {:linked, linked,
         [
           dgettext(
             "import_export",
             "Bound the existing lore book '%{book_name}' this card links; its embedded copy wasn't imported.",
             book_name: world
           )
         ]}

      linked ->
        {:linked, linked,
         [dgettext("import_export", "Bound the existing lore book '%{book_name}' this card links.", book_name: world)]}

      book && parsed.book ->
        {:embedded, parsed.book,
         [
           dgettext(
             "import_export",
             "The lore book '%{book_name}' this card links exists but can't be bound to this character; its embedded copy was imported.",
             book_name: world
           )
         ]}

      book ->
        {:embedded, nil,
         [
           dgettext(
             "import_export",
             "The lore book '%{book_name}' this card links exists but can't be bound to this character.",
             book_name: world
           )
         ]}

      parsed.book && parsed.book.name != world ->
        {:embedded, parsed.book,
         [
           dgettext("import_export", "This card also links the lore book '%{book_name}', which isn't here.",
             book_name: world
           )
         ]}

      parsed.book ->
        {:embedded, parsed.book, []}

      true ->
        {:embedded, nil,
         [
           dgettext(
             "import_export",
             "This card links the lore book '%{book_name}', which isn't here. Import it, then bind it to the character.",
             book_name: world
           )
         ]}
    end
  end

  ## Lore

  defp write_book(scope, name, attrs, entries) do
    book =
      ok!(Lore.create_book(scope, Map.put(attrs, :name, unique_name(name, book_names(scope))), import: true))

    {book, write_entries(scope, book, entries)}
  end

  defp book_names(scope), do: Enum.map(Lore.list_books(scope), & &1.name)

  defp write_entries(scope, book, specs) do
    # Pool and filter names repeat across entries; each is looked up once.
    pool_ids =
      specs
      |> Enum.flat_map(& &1.pools)
      |> Enum.map(& &1.name)
      |> Enum.uniq()
      |> Map.new(&{&1, ensure_pool(scope, book.user_id, &1).id})

    filter_characters =
      specs
      |> Enum.flat_map(&((&1.character_filter && &1.character_filter.names) || []))
      |> Enum.uniq()
      |> Map.new(&{&1, Characters.find_character_for_filter(scope, &1)})

    {warnings, memories, pool_rows} =
      Enum.reduce(specs, {[], [], []}, fn spec, {warnings, memories, pool_rows} ->
        {entry_warnings, entry} = write_entry(scope, book, spec, filter_characters)
        memories = if entry && spec.memory, do: [{entry.id, spec.memory} | memories], else: memories
        pool_rows = if entry, do: pool_rows(entry, spec.pools, pool_ids) ++ pool_rows, else: pool_rows
        {[entry_warnings | warnings], memories, pool_rows}
      end)

    write_pools(pool_rows)
    entry_warnings = warnings |> Enum.reverse() |> Enum.concat()
    entry_warnings ++ mark_memories(scope, book, Enum.reverse(memories))
  end

  # SillyTavern-MemoryBooks entries (`stmemorybooks`) become memories of their book; its summaries
  # (arcs and up) consolidations of their tier, linked to their sources by STMB uid.
  defp mark_memories(_scope, _book, []), do: []

  defp mark_memories(scope, book, memories) do
    entry_by_uid = Map.new(memories, fn {entry_id, memory} -> {memory.uid, entry_id} end)

    adoptions =
      for {entry_id, memory} <- memories do
        sources = memory.source_uids |> Enum.map(&entry_by_uid[&1]) |> Enum.reject(&is_nil/1)
        %{entry_id: entry_id, tier: memory.tier, source_entry_ids: sources}
      end

    case ok!(Memory.adopt_memories(scope, book, adoptions)) do
      %{marked: 0} ->
        []

      %{marked: n} ->
        [
          dngettext(
            "import_export",
            "%{entry_count} entry was marked as a memory (it has no chat or message range).",
            "%{entry_count} entries were marked as memories (they have no chat or message range).",
            n,
            entry_count: Mythweaver.Format.number(n)
          )
        ]
    end
  end

  defp write_entry(scope, book, spec, filter_characters) do
    name = spec.attrs.name
    {filter, filter_warnings} = resolve_filter(book, spec.character_filter, name, filter_characters)
    attrs = if filter, do: Map.put(spec.attrs, :character_filter_mode, filter.mode), else: spec.attrs
    changeset = LoreEntry.import_changeset(%LoreEntry{}, attrs)

    if changeset.valid? do
      if spec.outlet, do: ensure_outlet(scope, book.user_id, spec.outlet)
      entry = ok!(Lore.create_entry(scope, attrs, [book.id], %{order: spec.order}, import: true))

      if filter && filter.ids != [], do: ok!(Lore.set_entry_filter_characters(scope, entry, filter.ids))

      off_warnings =
        if filter && filter.mode == :include && filter.ids == [] do
          [
            dgettext(
              "import_export",
              "'%{entry_name}' was limited to characters that aren't here; imported switched off.",
              entry_name: name
            )
          ]
        else
          []
        end

      if not spec.enabled or off_warnings != [],
        do: ok!(Lore.set_membership_enabled(scope, book, entry.id, false))

      {filter_warnings ++ off_warnings, entry}
    else
      gettext_comment(
        "Import warning; the error is a field name with its validation messages, separated by semicolons."
      )

      warning =
        dpgettext(
          "import_export",
          "status: import warning, a lore entry skipped for its errors",
          "'%{entry_name}' skipped: %{entry_errors}",
          entry_name: name,
          entry_errors: errors(changeset)
        )

      {[warning], nil}
    end
  end

  # SillyTavern inclusion groups: each joins the owner's pool of that name (`pool_ids`). The entry
  # is new and its pools share its owner (`ensure_pool/3` with the book's), so the memberships are
  # inserted directly, all at once; `Mythweaver.Import.import/3` broadcasts after the commit.
  defp pool_rows(entry, pools, pool_ids) do
    now = DateTime.utc_now(:second)

    # Keyed by pool, so a group named twice joins once (the last one's settings).
    for {pool_id, pool} <- Map.new(pools, &{Map.fetch!(pool_ids, &1.name), &1}) do
      %{
        id: Schema.generate_id(),
        lore_pool_id: pool_id,
        lore_entry_id: entry.id,
        weight: pool.weight,
        override: pool.override,
        scored: pool.scored,
        inserted_at: now,
        updated_at: now
      }
    end
  end

  defp write_pools([]), do: :ok

  defp write_pools(rows) do
    {_count, _rows} = Repo.insert_all(PoolEntry, rows)
    :ok
  end

  # The filter's names matched (`characters`: name => usable character or nil) to characters the
  # entry (owned like its book) may reference.
  defp resolve_filter(_book, nil, _name, _characters), do: {nil, []}

  defp resolve_filter(book, %{mode: mode, names: names, tags: tags}, name, characters) do
    {ids, missing} =
      Enum.reduce(names, {[], []}, fn wanted, {ids, missing} ->
        case characters[wanted] do
          %{} = character ->
            if Ownership.reference_ok?(book.user_id, character),
              do: {[character.id | ids], missing},
              else: {ids, [wanted | missing]}

          nil ->
            {ids, [wanted | missing]}
        end
      end)

    missing_warnings =
      if missing == [],
        do: [],
        else: [
          dgettext("import_export", "'%{entry_name}' character filter: no character named %{character_names}.",
            entry_name: name,
            character_names: Enum.join(Enum.reverse(missing), ", ")
          )
        ]

    tag_warnings =
      if tags == [],
        do: [],
        else: [
          dgettext("import_export", "'%{entry_name}' character filter tags weren't imported: %{tag_list}.",
            entry_name: name,
            tag_list: Enum.join(tags, ", ")
          )
        ]

    {%{mode: mode, ids: ids |> Enum.reverse() |> Enum.uniq()}, missing_warnings ++ tag_warnings}
  end

  ## Chats

  defp write_chat(scope, parsed, player, speakers) do
    usable = MapSet.new(Characters.list_characters(scope), & &1.id)

    ids =
      Map.new(parsed.speakers, fn speaker ->
        id =
          case Map.get(speakers, speaker.key, :name_only) do
            :create ->
              ok!(Characters.create_character(scope, %{name: speaker.name})).id

            {:character, id} ->
              if MapSet.member?(usable, id),
                do: id,
                else:
                  Repo.rollback(
                    dpgettext(
                      "import_export",
                      "status: import error, a chat speaker is mapped to a character that can't be used",
                      "That character isn't available."
                    )
                  )

            :name_only ->
              nil
          end

        {speaker.key, id}
      end)

    player_id = ids[player] || Repo.rollback(choose_player())

    participants =
      [player_id | Enum.map(parsed.speakers, &ids[&1.key])]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if length(participants) < 2,
      do:
        Repo.rollback(
          dgettext("import_export", "A chat needs at least two characters; map another speaker to a character.")
        )

    chat =
      ok!(
        Chats.create_chat(scope, %{
          name: parsed.name,
          player_character_id: player_id,
          participants: Enum.map(participants, &%{character_id: &1})
        })
      )

    names = Map.new(parsed.speakers, &{&1.key, &1.name})

    entries =
      Enum.map(parsed.messages, fn message ->
        author = ids[message.speaker]

        %{
          author_character_id: author,
          author_name: if(!author, do: names[message.speaker]),
          visible_to_ai: message.visible_to_ai,
          inserted_at: message.inserted_at,
          bodies: message.bodies,
          active: message.active
        }
      end)

    :ok = Messages.import_transcript(chat, entries)
    chat
  end

  ## Presets

  defp write_preset(scope, parsed, model_id) do
    prompt =
      ok!(
        Prompts.create_prompt(scope, %{
          name: unique_name(parsed.name, Enum.map(Prompts.list_editable_prompts(scope), & &1.name)),
          description: "Imported from the SillyTavern preset \"#{parsed.name}\"."
        })
      )

    taken = MapSet.new(Prompts.list_editable_blocks(scope), & &1.name)

    _taken =
      Enum.reduce(parsed.blocks, taken, fn spec, taken ->
        name = unique_name(spec.name, taken)

        block =
          ok!(
            Prompts.create_block(scope, %{
              name: name,
              role: spec.role,
              kind: spec.kind,
              content: block_content(spec),
              role_tag: spec[:role_tag],
              forbid_overrides: spec[:forbid_overrides] || false
            })
          )

        ok!(Prompts.add_block(scope, prompt, block, %{enabled: spec.enabled}))
        MapSet.put(taken, name)
      end)

    if model_id, do: write_sampler(scope, model_id, parsed.sampler)
    prompt
  end

  @empty_block "{% comment %}Empty in the SillyTavern preset.{% endcomment %}\n"

  # A template block's text is required, so an empty ST prompt keeps its place as a comment that
  # renders nothing.
  defp block_content(%{kind: :template, content: content}) do
    if String.trim(content || "") == "", do: @empty_block, else: content
  end

  defp block_content(%{content: content}), do: content

  defp write_sampler(scope, model_id, sampler) do
    model =
      with {:ok, id} <- Ecto.UUID.cast(model_id), %{} = model <- AI.get_editable_model(scope, id) do
        model
      else
        _ -> Repo.rollback(dgettext("import_export", "That model can't be edited."))
      end

    if sampler != %{}, do: ok!(AI.update_model(scope, model, %{sampler: sampler}))
  end

  defp choose_player, do: dgettext("import_export", "Choose a character for the player.")
end
