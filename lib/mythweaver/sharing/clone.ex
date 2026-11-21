defmodule Mythweaver.Sharing.Clone do
  @moduledoc """
  Copies a root item another owner made into the scope user's own (`clone/2`): a Readable share's
  item, or a site item whose content the user may read. The copy is a new row owned by the user,
  Readable, named by `next_copy_name/4` when its name is taken, with `cloned_from_type`/`cloned_from_id`
  pointing at the source (the live item for a catalog mirror's row, with `cloned_from_release_id`
  its listing's current release).

  What the source references goes by the member rule: a row the user may read (another owner's,
  through a Readable grant) is copied once and relinked; a row the user may only use (a Runtime-only
  grant, a site row, the user's own) is linked as is, which `Mythweaver.Ownership.reference_ok?/2`
  allows; a row it may not use is dropped. A lore book's entries and the pools holding only its
  entries are its parts and are always copied with it. A character's avatar and sprite files are
  copied into new attachments uploaded by the user, held to its upload storage.

  `mirror/5` copies the scope user's own root item into a catalog mirror (`Mythweaver.Catalog`)
  instead: every row of its closure (the user's own) is copied, site rows linked, others dropped;
  each copy is marked `frozen_listing_id` and `mirror_of_id`, keeps its name, and counts against no
  quota. Given the mirror's current rows, it updates them in place.
  """

  import Ecto.Query

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.AI
  alias Mythweaver.Attachments
  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Attachments.CharacterAttachment
  alias Mythweaver.Catalog.Listing
  alias Mythweaver.Changes
  alias Mythweaver.Expressions.Outfit
  alias Mythweaver.Expressions.Sprite
  alias Mythweaver.Lore.BookCharacter
  alias Mythweaver.Lore.BookEntry
  alias Mythweaver.Lore.EntryCharacter
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Lore.LorePool
  alias Mythweaver.Lore.PoolEntry
  alias Mythweaver.Memory.Profile
  alias Mythweaver.Memory.SidePrompt
  alias Mythweaver.Memory.SidePromptSetRow
  alias Mythweaver.Ownership
  alias Mythweaver.Permissions.Quota
  alias Mythweaver.Prompts.Prompt
  alias Mythweaver.Prompts.PromptBlock
  alias Mythweaver.Repo
  alias Mythweaver.Scripts.Script
  alias Mythweaver.Sharing.Items
  alias Mythweaver.Sharing.Visibility

  @quota %{
    character: "quota.characters",
    lore_book: "quota.lore_books",
    prompt: "quota.prompts",
    script: "quota.scripts"
  }

  # The column each type's copy must keep unique per owner (characters and entries are not unique;
  # a character's name is made unique anyway so the copy reads apart from what the user has).
  @unique %{
    character: :name,
    lore_book: :name,
    lore_pool: :name,
    prompt: :name,
    block: :name,
    outlet: :key,
    script: :name,
    memory_profile: :name,
    side_prompt: :name,
    side_prompt_set: :name,
    expression_profile: :name
  }

  @doc """
  Copies the root `item` into the scope user's own, with what it references going by the member
  rule (see the moduledoc), in one transaction.

  `{:error, :unauthorized}` when `item` is the user's own, the user may not read it (`readable?/2`),
  lacks the type's create permission, or `item` is a side prompt whose prompt the user may not use.
  `{:error, :quota_exceeded}` past a row count or the upload storage.
  """
  @spec clone(Scope.t(), struct()) :: {:ok, struct()} | {:error, :unauthorized | :quota_exceeded | term()}
  def clone(%Scope{user: %User{id: uid}} = scope, %{id: id, user_id: owner} = item)
      when is_binary(id) and owner != uid do
    type = Items.type_of(item)

    with true <- (clonable_type?(type) and readable?(scope, item)) || {:error, :unauthorized},
         :ok <- Scope.authorize(scope, Ownership.create_permission(item.__struct__)),
         :ok <- check_quota(scope, type),
         :ok <- check_refs(scope, type, item),
         {:ok, files} <- copy_files(scope, type, item) do
      ctx = %{scope: scope, uid: uid, copies: %{}, files: files, mirror: nil}

      case Repo.transact(fn -> {:ok, copy(type, item, ctx)} end) do
        {:ok, {copy_id, ctx}} ->
          Changes.broadcast(Enum.uniq(for({t, _id} <- Map.keys(ctx.copies), do: Items.kind(t))), uid)
          {:ok, Items.get(type, copy_id)}

        {:error, reason} ->
          Attachments.delete_orphaned(for {_old, new} <- files, do: new.id)
          {:error, reason}
      end
    end
  end

  def clone(_scope, _item), do: {:error, :unauthorized}

  @doc """
  Whether `clone/2` of `item` passes its checks before quotas: a root item not the scope user's own,
  readable by it (`readable?/2`), whose type it may create.
  """
  @spec clonable?(Scope.t() | nil, struct()) :: boolean()
  def clonable?(%Scope{user: %User{id: uid}} = scope, %{user_id: owner} = item) when owner != uid,
    do:
      clonable_type?(Items.type_of(item)) and readable?(scope, item) and
        Scope.can?(scope, Ownership.create_permission(item.__struct__))

  def clonable?(_scope, _item), do: false

  # An AI model is not copied: a subscriber links it to their own connection instead.
  defp clonable_type?(type), do: Items.root?(type) and type != :ai_model

  @typedoc """
  A mirror's rows by what they copy: `{type, live id}` for grant-type rows, `{:outfit | :sprite |
  :set_row, live id}` for a character's outfits and sprites and a side prompt set's rows.
  """
  @type mirror_rows :: %{{atom(), Ecto.UUID.t()} => Ecto.UUID.t()}

  @doc """
  Copies the files `mirror/5` of `item` links, before its transaction: `{:ok, files}`, or the
  `Mythweaver.Attachments.copy/2` error (nothing kept).
  """
  @spec mirror_files(Scope.t(), struct()) :: {:ok, %{Ecto.UUID.t() => Attachment.t()}} | {:error, term()}
  def mirror_files(scope, item), do: copy_files(scope, Items.type_of(item), item)

  @doc """
  Copies the scope user's own root `item` and its closure into the mirror of catalog listing
  `listing_id` (see the moduledoc), inside the caller's transaction, with the `files` from
  `mirror_files/2`. `existing` is the mirror's current rows: each still reached is updated in place
  and its links rebuilt; the caller deletes those `copies` leaves out.

  Returns `{root id, copies, replaced}`: the mirror root (nil when it cannot be copied: a side prompt
  whose prompt is another user's), every row copied (`t:mirror_rows/0`) and the attachments the
  existing rows linked before, for `Mythweaver.Attachments.delete_orphaned/1` after the commit.
  """
  @spec mirror(Scope.t(), struct(), Ecto.UUID.t(), mirror_rows(), %{Ecto.UUID.t() => Attachment.t()}) ::
          {Ecto.UUID.t() | nil, mirror_rows(), [Ecto.UUID.t()]}
  def mirror(%Scope{user: %User{id: uid}} = scope, %{user_id: uid} = item, listing_id, existing, files) do
    replaced = clear_links(existing)
    ctx = %{scope: scope, uid: uid, copies: %{}, files: files, mirror: %{listing_id: listing_id, existing: existing}}
    {id, ctx} = copy(Items.type_of(item), item, ctx)
    {id, ctx.copies, replaced}
  end

  # Deletes the links the `existing` mirror rows own, which the copy inserts again, and returns the
  # attachments their characters linked. Outfits, sprites and set rows are updated in place instead.
  defp clear_links(existing) when existing == %{}, do: []

  defp clear_links(existing) do
    ids = Enum.group_by(existing, fn {{type, _live}, _id} -> type end, fn {_key, id} -> id end)
    of = &Map.get(ids, &1, [])
    characters = of.(:character)

    replaced =
      Repo.all(from(ca in CharacterAttachment, where: ca.character_id in ^characters, select: ca.attachment_id)) ++
        Repo.all(from(s in Sprite, where: s.character_id in ^characters, select: s.attachment_id))

    Repo.delete_all(from(ca in CharacterAttachment, where: ca.character_id in ^characters))
    Repo.delete_all(from(bc in BookCharacter, where: bc.character_id in ^characters))
    Repo.delete_all(from(be in BookEntry, where: be.lore_book_id in ^of.(:lore_book)))
    Repo.delete_all(from(ec in EntryCharacter, where: ec.lore_entry_id in ^of.(:lore_entry)))
    Repo.delete_all(from(pe in PoolEntry, where: pe.lore_pool_id in ^of.(:lore_pool)))
    Repo.delete_all(from(pb in PromptBlock, where: pb.prompt_id in ^of.(:prompt)))
    scripts = Enum.map(of.(:script), &Ecto.UUID.dump!/1)
    Repo.delete_all(from(d in "script_dependencies", where: d.script_id in ^scripts))
    Enum.uniq(replaced)
  end

  @doc """
  Whether `scope` may read `row`'s protected content, so may clone it: a site row not content-hidden
  from it, its own row, or another user's through a Readable or editor grant.
  """
  @spec readable?(Scope.t() | nil, struct()) :: boolean()
  def readable?(scope, row) do
    site_hidden? =
      Map.has_key?(row, :site_visibility) and Visibility.content_hidden?(row) and not Visibility.view_hidden?(scope)

    uid = scope && scope.user && scope.user.id

    not site_hidden? and not Visibility.share_protected?(row, uid)
  end

  @doc """
  The next free `field` value in `name`'s series among `owner_id`'s `schema` rows (nil: the site's):
  trailing digits are incremented (`"Act 3"` -> `"Act 4"`, `"p3"` -> `"p4"`), a name without them
  gains `" 2"` (`"_2"` for an outlet key). Taken candidates are skipped, so duplicating twice yields
  `"Act 4"` then `"Act 5"` rather than a constraint error.
  """
  @spec next_copy_name(module(), String.t(), Ecto.UUID.t() | nil, atom()) :: String.t()
  def next_copy_name(schema, name, owner_id, field \\ :name) when is_binary(name) do
    {base, separator, start} =
      case Regex.named_captures(~r/^(?<base>.*?)(?<separator>[\s_]*)(?<number>\d+)$/u, name) do
        %{"base" => base, "separator" => separator, "number" => number} ->
          {base, separator, String.to_integer(number) + 1}

        nil ->
          {name, if(field == :key, do: "_", else: " "), 2}
      end

    Stream.iterate(start, &(&1 + 1))
    |> Stream.map(&candidate_name(base, separator, &1))
    |> Enum.find(&(not taken?(schema, field, &1, owner_id)))
  end

  # Names are varchar(255); an over-long name raises from Postgrex instead of surfacing as a
  # changeset, so the base is trimmed rather than the number.
  defp candidate_name(base, separator, number) do
    suffix = "#{separator}#{number}"
    "#{String.slice(base, 0, max(255 - String.length(suffix), 0))}#{suffix}"
  end

  defp taken?(schema, field, value, owner_id),
    do: schema |> Ownership.owned_exactly(owner_id) |> where([r], field(r, ^field) == ^value) |> Repo.exists?()

  defp check_quota(scope, type) do
    case @quota[type] do
      nil -> :ok
      key -> Quota.check_new_row(scope, scope.user.id, key, Items.schema(type))
    end
  end

  ## Members

  # How the copy treats a row the source references: `:copy` (the user may read another owner's
  # row), `:link` (it may use it, or it is the site's or the user's own) or `:drop`. A mirror copies
  # the user's own rows, links the site's and drops the rest.
  defp disposition(_ctx, nil), do: :drop

  defp disposition(%{mirror: %{}, uid: uid}, %{user_id: owner} = row) do
    cond do
      owner == uid and is_nil(Map.get(row, :frozen_listing_id)) -> :copy
      is_nil(owner) -> :link
      true -> :drop
    end
  end

  defp disposition(%{uid: uid}, %{user_id: owner}) when owner == nil or owner == uid, do: :link

  defp disposition(ctx, row) do
    cond do
      readable?(ctx.scope, row) -> :copy
      Ownership.reference_ok?(ctx.uid, row) -> :link
      true -> :drop
    end
  end

  # The id the copy links for `row` of `type` under the member rule (nil: dropped), copying it once.
  defp member(_type, nil, ctx), do: {nil, ctx}

  defp member(type, row, ctx) do
    case {Map.fetch(ctx.copies, {type, row.id}), disposition(ctx, row)} do
      {{:ok, id}, _} -> {id, ctx}
      {:error, :copy} -> copy(type, row, ctx)
      {:error, :link} -> {row.id, ctx}
      {:error, :drop} -> {nil, ctx}
    end
  end

  # Inserts a copy of `source` owned by the user, with `overrides`, and records it in `ctx`. A mirror's
  # copy keeps the name and counts against no quota; it replaces the mirror's existing row of `source`.
  defp insert_copy(type, source, overrides, %{mirror: %{} = mirror} = ctx) do
    schema = source.__struct__

    attrs =
      source
      |> Map.take(schema.__schema__(:fields) -- [:inserted_at, :updated_at])
      |> Map.merge(%{
        id: Map.get(mirror.existing, {type, source.id}) || Mythweaver.Schema.generate_id(),
        user_id: ctx.uid,
        frozen_listing_id: mirror.listing_id,
        mirror_of_id: source.id
      })
      |> Map.merge(overrides)

    copy = upsert!(struct(schema, attrs))
    {copy, %{ctx | copies: Map.put(ctx.copies, {type, source.id}, copy.id)}}
  end

  defp insert_copy(type, source, overrides, ctx) do
    schema = source.__struct__
    fields = schema.__schema__(:fields)

    with key when is_binary(key) <- @quota[type],
         {:error, :quota_exceeded} <- Quota.check_new_row(ctx.scope, ctx.uid, key, schema) do
      Repo.rollback(:quota_exceeded)
    end

    attrs =
      source
      |> Map.take(fields -- [:id, :inserted_at, :updated_at])
      |> Map.put(:user_id, ctx.uid)
      |> put_if(:cloned_from_type in fields,
        cloned_from_type: Items.type_of(source),
        cloned_from_id: Map.get(source, :mirror_of_id) || source.id
      )
      |> put_if(:cloned_from_release_id in fields, cloned_from_release_id: release_of(source))
      |> put_if(:frozen_listing_id in fields, frozen_listing_id: nil, mirror_of_id: nil)
      |> put_if(:site_visibility in fields, site_visibility: :readable)
      |> put_unique(type, schema, ctx.uid)
      |> Map.merge(overrides)

    copy = Repo.insert!(struct(schema, attrs))
    {copy, %{ctx | copies: Map.put(ctx.copies, {type, source.id}, copy.id)}}
  end

  # Inserts `row`, a child of a copy (an outfit, sprite or set row). In a mirror it replaces the
  # existing mirror child of `source_id`, recorded in `ctx` as `{kind, source_id}`.
  defp insert_child(row, kind, source_id, %{mirror: %{} = mirror} = ctx) do
    id = Map.get(mirror.existing, {kind, source_id}) || Mythweaver.Schema.generate_id()
    child = upsert!(%{row | id: id, mirror_of_id: source_id})
    {child.id, %{ctx | copies: Map.put(ctx.copies, {kind, source_id}, child.id)}}
  end

  defp insert_child(row, _kind, _source_id, ctx), do: {Repo.insert!(row).id, ctx}

  defp upsert!(row),
    do: Repo.insert!(row, on_conflict: {:replace_all_except, [:id, :inserted_at]}, conflict_target: :id)

  # The current release of the listing whose mirror `source` belongs to (nil for a live row).
  defp release_of(%{frozen_listing_id: listing_id}) when is_binary(listing_id),
    do: Repo.one(from(l in Listing, where: l.id == ^listing_id, select: l.current_release_id))

  defp release_of(_source), do: nil

  defp put_if(attrs, true, values), do: Map.merge(attrs, Map.new(values))
  defp put_if(attrs, false, _values), do: attrs

  defp put_unique(attrs, type, schema, uid) do
    with field when is_atom(field) and field != nil <- @unique[type],
         value when is_binary(value) <- Map.get(attrs, field),
         true <- taken?(schema, field, value, uid) do
      Map.put(attrs, field, next_copy_name(schema, value, uid, field))
    else
      _ -> attrs
    end
  end

  # A side prompt cannot run without its prompt, so a prompt the user may not use refuses the clone.
  defp check_refs(scope, :side_prompt, %SidePrompt{prompt_id: prompt_id}) when is_binary(prompt_id) do
    if disposition(%{scope: scope, uid: scope.user.id}, Repo.get(Prompt, prompt_id)) == :drop,
      do: {:error, :unauthorized},
      else: :ok
  end

  defp check_refs(_scope, _type, _item), do: :ok

  # A character's avatar and sprite files, copied before the transaction (storage is not
  # transactional): `%{source attachment id => copy}`. A failure deletes the copies made so far.
  defp copy_files(scope, :character, character) do
    character = Repo.preload(character, [:avatar_link, :sprites])
    ids = Enum.uniq(for link <- List.wrap(character.avatar_link) ++ character.sprites, do: link.attachment_id)

    Enum.reduce_while(Repo.all(from(a in Attachment, where: a.id in ^ids)), {:ok, %{}}, fn attachment, {:ok, acc} ->
      case Attachments.copy(scope, attachment) do
        {:ok, copy} ->
          {:cont, {:ok, Map.put(acc, attachment.id, copy)}}

        {:error, reason} ->
          Attachments.delete_orphaned(for {_old, new} <- acc, do: new.id)
          {:halt, {:error, reason}}
      end
    end)
  end

  defp copy_files(_scope, _type, _item), do: {:ok, %{}}

  ## Copies: each returns `{copy id, ctx}`, or `{nil, ctx}` for a row that cannot be copied.

  defp copy(type, row, ctx) when type in [:block, :outlet, :expression_profile] do
    {copy, ctx} = insert_copy(type, row, %{}, ctx)
    {copy.id, ctx}
  end

  defp copy(:script, script, ctx) do
    {copy, ctx} = insert_copy(:script, script, %{last_error: nil, last_error_at: nil, last_success_at: nil}, ctx)

    deps =
      Repo.all(
        from(s in Script,
          join: d in "script_dependencies",
          on: d.dependency_id == s.id,
          where: d.script_id == type(^script.id, Ecto.UUID)
        )
      )

    {ids, ctx} = Enum.map_reduce(deps, ctx, &member(:script, &1, &2))
    dump = &Ecto.UUID.dump!/1
    rows = for id <- Enum.uniq(ids), id, id != copy.id, do: %{script_id: dump.(copy.id), dependency_id: dump.(id)}
    Repo.insert_all("script_dependencies", rows)
    {copy.id, ctx}
  end

  # Outfits are copied, the avatar and sprites link the files `copy_files/3` copied, and bound
  # books and the expression profile go by the member rule.
  defp copy(:character, character, ctx) do
    character = Repo.preload(character, [:avatar_link, :outfits, :sprites, :expression_profile])
    {profile_id, ctx} = member(:expression_profile, character.expression_profile, ctx)
    {copy, ctx} = insert_copy(:character, character, %{expression_profile_id: profile_id}, ctx)

    if link = character.avatar_link do
      Repo.insert!(%CharacterAttachment{character_id: copy.id, role: :avatar, attachment_id: file(ctx, link)})
    end

    {outfits, ctx} =
      Enum.map_reduce(character.outfits, ctx, fn outfit, ctx ->
        row = %Outfit{character_id: copy.id, name: outfit.name, position: outfit.position}
        {id, ctx} = insert_child(row, :outfit, outfit.id, ctx)
        {{outfit.id, id}, ctx}
      end)

    outfits = Map.new(outfits)

    ctx =
      Enum.reduce(character.sprites, ctx, fn sprite, ctx ->
        row = %Sprite{
          character_id: copy.id,
          label: sprite.label,
          outfit_id: sprite.outfit_id && Map.fetch!(outfits, sprite.outfit_id),
          attachment_id: file(ctx, sprite)
        }

        {_id, ctx} = insert_child(row, :sprite, sprite.id, ctx)
        ctx
      end)

    bindings = Repo.all(from(bc in BookCharacter, where: bc.character_id == ^character.id, preload: :book))

    ctx =
      each_member(:lore_book, bindings, & &1.book, ctx, fn binding, book_id ->
        Repo.insert!(%BookCharacter{lore_book_id: book_id, character_id: copy.id, enabled: binding.enabled})
      end)

    {copy.id, ctx}
  end

  # A book's entries the user may read (with their order and enabled), and the pools holding only
  # its entries, are copied. Tags are not, so the copy's tag filter is off.
  defp copy(:lore_book, book, ctx) do
    {copy, ctx} = insert_copy(:lore_book, book, %{forced: false, tag_filter_mode: :off}, ctx)
    readable = Visibility.readable_entries(from(e in LoreEntry, select: e.id), ctx.scope)

    memberships =
      Repo.all(
        from(be in BookEntry,
          join: e in assoc(be, :entry),
          where: be.lore_book_id == ^book.id and e.id in subquery(readable),
          order_by: [asc: be.order],
          select: {be, e}
        )
      )

    {entries, ctx} =
      Enum.flat_map_reduce(memberships, ctx, fn {membership, entry}, ctx ->
        case entry_member(entry, ctx) do
          {nil, ctx} ->
            {[], ctx}

          {id, ctx} ->
            Repo.insert!(%BookEntry{
              lore_book_id: copy.id,
              lore_entry_id: id,
              enabled: membership.enabled,
              order: membership.order
            })

            {[{entry.id, id}], ctx}
        end
      end)

    {copy.id, copy_pools(book, Map.new(entries), ctx)}
  end

  # An entry's character filter keeps the characters the copy's owner may reference (the copy, for
  # the character being cloned).
  defp copy(:lore_entry, entry, ctx) do
    {copy, ctx} = insert_copy(:lore_entry, entry, %{}, ctx)

    characters =
      Repo.all(
        from(ec in EntryCharacter, join: c in assoc(ec, :character), where: ec.lore_entry_id == ^entry.id, select: c)
      )

    for character <- characters, id <- List.wrap(filter_character(character, ctx)) do
      Repo.insert!(%EntryCharacter{lore_entry_id: copy.id, character_id: id})
    end

    {copy.id, ctx}
  end

  # Block memberships keep their position and enabled; bindings are not copied (see
  # `Mythweaver.Prompts.duplicate_prompt/2`).
  defp copy(:prompt, prompt, ctx) do
    {copy, ctx} = insert_copy(:prompt, prompt, %{}, ctx)
    memberships = Repo.all(from(pb in PromptBlock, where: pb.prompt_id == ^prompt.id, preload: :block))

    ctx =
      each_member(:block, memberships, & &1.block, ctx, fn pb, block_id ->
        Repo.insert!(%PromptBlock{prompt_id: copy.id, block_id: block_id, position: pb.position, enabled: pb.enabled})
      end)

    {copy.id, ctx}
  end

  # The model is kept when the user may run it.
  defp copy(:memory_profile, profile, ctx) do
    {prompts, ctx} =
      Enum.map_reduce(Profile.prompt_purposes(), ctx, fn {field, _purpose}, ctx ->
        {id, ctx} = member(:prompt, row(Prompt, Map.fetch!(profile, field)), ctx)
        {{field, id}, ctx}
      end)

    model = row(AI.Model, profile.ai_model_id)
    overrides = %{ai_model_id: model && AI.usable?(ctx.scope, model) && model.id, default: false}
    {copy, ctx} = insert_copy(:memory_profile, profile, Map.merge(Map.new(prompts), overrides), ctx)
    {copy.id, ctx}
  end

  # Not copied without its prompt (`check_refs/3` refuses that for the item being cloned).
  defp copy(:side_prompt, side_prompt, ctx) do
    case member(:prompt, row(Prompt, side_prompt.prompt_id), ctx) do
      {nil, ctx} when side_prompt.prompt_id != nil ->
        {nil, ctx}

      {prompt_id, ctx} ->
        {profile_id, ctx} = member(:memory_profile, row(Profile, side_prompt.profile_id), ctx)
        {book_id, ctx} = member(:lore_book, row(LoreBook, side_prompt.target_book_id), ctx)
        overrides = %{prompt_id: prompt_id, profile_id: profile_id, target_book_id: book_id}
        {copy, ctx} = insert_copy(:side_prompt, side_prompt, overrides, ctx)
        {copy.id, ctx}
    end
  end

  defp copy(:side_prompt_set, set, ctx) do
    {copy, ctx} = insert_copy(:side_prompt_set, set, %{}, ctx)
    rows = Repo.all(from(r in SidePromptSetRow, where: r.side_prompt_set_id == ^set.id, preload: :side_prompt))

    ctx =
      Enum.reduce(rows, ctx, fn row, ctx ->
        case member(:side_prompt, row.side_prompt, ctx) do
          {nil, ctx} ->
            ctx

          {side_prompt_id, ctx} ->
            set_row = %SidePromptSetRow{
              side_prompt_set_id: copy.id,
              side_prompt_id: side_prompt_id,
              position: row.position,
              label: row.label,
              macro_values: row.macro_values
            }

            {_id, ctx} = insert_child(set_row, :set_row, row.id, ctx)
            ctx
        end
      end)

    {copy.id, ctx}
  end

  # For each of `links`, the member rule on `target.(link)` of `type`; `insert.(link, id)` for each
  # one kept.
  defp each_member(type, links, target, ctx, insert) do
    Enum.reduce(links, ctx, fn link, ctx ->
      case member(type, target.(link), ctx) do
        {nil, ctx} ->
          ctx

        {id, ctx} ->
          insert.(link, id)
          ctx
      end
    end)
  end

  defp row(_schema, nil), do: nil
  defp row(schema, id), do: Repo.get(schema, id)

  defp file(ctx, %{attachment_id: id}), do: Map.fetch!(ctx.files, id).id

  # A mirror copies the user's own entries; a clone links them.
  defp entry_member(entry, %{mirror: %{}} = ctx), do: member(:lore_entry, entry, ctx)
  defp entry_member(%LoreEntry{user_id: uid} = entry, %{uid: uid} = ctx), do: {entry.id, ctx}

  defp entry_member(entry, ctx) do
    case Map.fetch(ctx.copies, {:lore_entry, entry.id}) do
      {:ok, id} -> {id, ctx}
      :error -> copy(:lore_entry, entry, ctx)
    end
  end

  # A mirror keeps the characters it copied and site characters only.
  defp filter_character(character, ctx) do
    cond do
      id = ctx.copies[{:character, character.id}] -> id
      ctx.mirror != nil -> if is_nil(character.user_id), do: character.id
      Ownership.reference_ok?(ctx.uid, character) -> character.id
      true -> nil
    end
  end

  # The pools of `book`'s owner holding only its entries, each copied once with the entries in
  # `entries` (source id => the id the copy links).
  defp copy_pools(book, entries, ctx) do
    book_entries = from(be in BookEntry, where: be.lore_book_id == ^book.id, select: be.lore_entry_id)
    owner = if book.user_id, do: dynamic([p], p.user_id == ^book.user_id), else: dynamic([p], is_nil(p.user_id))

    pools =
      Repo.all(
        from(p in LorePool,
          as: :pool,
          where: ^owner,
          where: exists(from(pe in PoolEntry, where: pe.lore_pool_id == parent_as(:pool).id)),
          where:
            not exists(
              from(pe in PoolEntry,
                where: pe.lore_pool_id == parent_as(:pool).id and pe.lore_entry_id not in subquery(book_entries)
              )
            ),
          preload: :pool_entries
        )
      )

    Enum.reduce(pools, ctx, fn pool, ctx ->
      kept = Enum.filter(pool.pool_entries, &Map.has_key?(entries, &1.lore_entry_id))

      if kept == [] or Map.has_key?(ctx.copies, {:lore_pool, pool.id}) do
        ctx
      else
        {copy, ctx} = insert_copy(:lore_pool, pool, %{}, ctx)

        for pe <- kept,
            do:
              Repo.insert!(%PoolEntry{
                lore_pool_id: copy.id,
                lore_entry_id: entries[pe.lore_entry_id],
                weight: pe.weight
              })

        ctx
      end
    end)
  end
end
