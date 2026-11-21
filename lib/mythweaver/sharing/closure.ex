defmodule Mythweaver.Sharing.Closure do
  @moduledoc """
  What a share reaches: its item and everything that item needs to work, all of the share owner's
  own rows (a site row is usable anyway; another user's row is never passed on).

  For an editor share the item and its parts take `:edit`: a lore book's entries and the pools
  holding only its entries. What it references is `:use`, recursively with that reference's own
  parts and references: a character's bound lore books and expression profile, a prompt's blocks, a
  memory profile's prompts, a side prompt's prompt, profile and target book, a side prompt set's
  side prompts, a script's dependencies, an AI model's caption model and caption prompt. AI models
  other items name, AI connections, memory-book locks, prompt bindings and outlets never travel.
  """

  import Ecto.Query

  alias Mythweaver.AI
  alias Mythweaver.Characters.Character
  alias Mythweaver.Expressions
  alias Mythweaver.Lore.BookCharacter
  alias Mythweaver.Lore.BookEntry
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Lore.LorePool
  alias Mythweaver.Lore.PoolEntry
  alias Mythweaver.Memory.Profile
  alias Mythweaver.Memory.SidePrompt
  alias Mythweaver.Memory.SidePromptSetRow
  alias Mythweaver.Prompts.Block
  alias Mythweaver.Prompts.Prompt
  alias Mythweaver.Prompts.PromptBlock
  alias Mythweaver.Repo
  alias Mythweaver.Scripts.Script
  alias Mythweaver.Sharing.Grant
  alias Mythweaver.Sharing.Items
  alias Mythweaver.Sharing.Share

  @type member :: {Items.type(), Ecto.UUID.t(), :edit | :use}

  @doc """
  The closure of `owner_id`'s item `type`/`id`: `{type, id, access}` per row, each once (`:edit` wins
  over `:use`). Empty when the item is gone or is not `owner_id`'s.
  """
  @spec of(Items.type(), Ecto.UUID.t(), Ecto.UUID.t()) :: [member()]
  def of(type, id, owner_id) do
    case Items.get(type, id) do
      %{user_id: ^owner_id} -> [{type, id, :edit}] |> walk(owner_id, %{}) |> Enum.map(fn {{t, i}, a} -> {t, i, a} end)
      _ -> []
    end
  end

  @doc "Each of `user_ids`' grants as `{item_type, item_id}` sets, by user id; a user with none maps to an empty set."
  @spec grant_sets([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => MapSet.t()}
  def grant_sets(user_ids) do
    found =
      from(g in Grant, where: g.user_id in ^user_ids, select: {g.user_id, {g.item_type, g.item_id}})
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    Map.new(user_ids, &{&1, MapSet.new(Map.get(found, &1, []))})
  end

  @doc """
  Brings the grants of an accepted `share` to its current closure, deleting and inserting only rows
  that differ (an access or visibility change replaces the row). A subscriber share grants every
  member `:use`; other shares get none.
  """
  @spec rebuild(Share.t()) :: :ok
  def rebuild(%Share{status: :accepted} = share) do
    visibility = if share.role == :editor, do: :readable, else: share.visibility

    wanted =
      for {type, id, access} <- of(share.item_type, share.item_id, share.owner_id), into: MapSet.new() do
        {type, id, if(share.role == :subscriber, do: :use, else: access), visibility}
      end

    current =
      Repo.all(
        from(g in Grant,
          where: g.share_id == ^share.id,
          select: {{g.item_type, g.item_id, g.access, g.visibility}, g.id}
        )
      )

    stale = for {member, id} <- current, not MapSet.member?(wanted, member), do: id
    fresh = MapSet.difference(wanted, MapSet.new(current, &elem(&1, 0)))
    now = DateTime.utc_now(:second)

    rows =
      for {type, id, access, visibility} <- fresh do
        %{
          id: Mythweaver.Schema.generate_id(),
          share_id: share.id,
          user_id: share.user_id,
          owner_id: share.owner_id,
          item_type: type,
          item_id: id,
          access: access,
          visibility: visibility,
          inserted_at: now
        }
      end

    if stale != [] or rows != [] do
      {:ok, :ok} =
        Repo.transact(fn ->
          if stale != [], do: Repo.delete_all(from(g in Grant, where: g.id in ^stale))
          if rows != [], do: Repo.insert_all(Grant, rows)
          {:ok, :ok}
        end)
    end

    :ok
  end

  def rebuild(%Share{}), do: :ok

  # Visits each row once; a row first reached as `:use` is visited again when reached as `:edit`,
  # so its parts take the stronger access.
  defp walk([], _owner, acc), do: acc

  defp walk([{type, id, access} | rest], owner, acc) do
    case Map.get(acc, {type, id}) do
      :edit ->
        walk(rest, owner, acc)

      ^access ->
        walk(rest, owner, acc)

      _ ->
        next =
          for({t, i} <- parts(type, id, owner), do: {t, i, access}) ++
            for({t, i} <- references(type, id, owner), do: {t, i, :use})

        walk(next ++ rest, owner, Map.put(acc, {type, id}, access))
    end
  end

  defp parts(:lore_book, id, owner) do
    entry_ids = from(be in BookEntry, where: be.lore_book_id == ^id, select: be.lore_entry_id)

    entries =
      from(e in LoreEntry, where: e.user_id == ^owner and e.id in subquery(entry_ids), select: e.id)
      |> Repo.all()

    pools =
      from(p in LorePool,
        as: :pool,
        where: p.user_id == ^owner,
        where: exists(from(pe in PoolEntry, where: pe.lore_pool_id == parent_as(:pool).id)),
        where:
          not exists(
            from(pe in PoolEntry,
              where: pe.lore_pool_id == parent_as(:pool).id and pe.lore_entry_id not in subquery(entry_ids)
            )
          ),
        select: p.id
      )
      |> Repo.all()

    Enum.map(entries, &{:lore_entry, &1}) ++ Enum.map(pools, &{:lore_pool, &1})
  end

  defp parts(_type, _id, _owner), do: []

  defp references(:character, id, owner) do
    books =
      from(bc in BookCharacter,
        join: b in LoreBook,
        on: b.id == bc.lore_book_id,
        where: bc.character_id == ^id and b.user_id == ^owner,
        select: b.id
      )
      |> Repo.all()

    profiles =
      from(c in Character,
        join: p in Expressions.Profile,
        on: p.id == c.expression_profile_id,
        where: c.id == ^id and p.user_id == ^owner,
        select: p.id
      )
      |> Repo.all()

    Enum.map(books, &{:lore_book, &1}) ++ Enum.map(profiles, &{:expression_profile, &1})
  end

  defp references(:prompt, id, owner) do
    from(pb in PromptBlock,
      join: b in Block,
      on: b.id == pb.block_id,
      where: pb.prompt_id == ^id and b.user_id == ^owner,
      select: b.id
    )
    |> Repo.all()
    |> Enum.map(&{:block, &1})
  end

  defp references(:memory_profile, id, owner) do
    case Repo.get(Profile, id) do
      nil ->
        []

      profile ->
        ids = for {field, _purpose} <- Profile.prompt_purposes(), value = Map.fetch!(profile, field), value, do: value
        owned(Prompt, Enum.uniq(ids), owner, :prompt)
    end
  end

  defp references(:side_prompt, id, owner) do
    case Repo.get(SidePrompt, id) do
      nil ->
        []

      side_prompt ->
        owned(Prompt, List.wrap(side_prompt.prompt_id), owner, :prompt) ++
          owned(Profile, List.wrap(side_prompt.profile_id), owner, :memory_profile) ++
          owned(LoreBook, List.wrap(side_prompt.target_book_id), owner, :lore_book)
    end
  end

  defp references(:side_prompt_set, id, owner) do
    from(r in SidePromptSetRow,
      join: s in SidePrompt,
      on: s.id == r.side_prompt_id,
      where: r.side_prompt_set_id == ^id and s.user_id == ^owner,
      distinct: true,
      select: s.id
    )
    |> Repo.all()
    |> Enum.map(&{:side_prompt, &1})
  end

  defp references(:script, id, owner) do
    from(d in "script_dependencies",
      join: s in Script,
      on: s.id == d.dependency_id,
      where: d.script_id == type(^id, Ecto.UUID) and s.user_id == ^owner,
      select: s.id
    )
    |> Repo.all()
    |> Enum.map(&{:script, &1})
  end

  # Connections never travel: a subscriber runs a model on their own key or, by its share's AI
  # mode, the owner's (`Mythweaver.AI.next_provider_model/2`).
  defp references(:ai_model, id, owner) do
    case Repo.get(AI.Model, id) do
      nil ->
        []

      model ->
        owned(AI.Model, List.wrap(model.caption_model_id), owner, :ai_model) ++
          owned(Prompt, List.wrap(model.caption_prompt_id), owner, :prompt)
    end
  end

  defp references(_type, _id, _owner), do: []

  defp owned(_schema, [], _owner, _type), do: []

  defp owned(schema, ids, owner, type) do
    from(r in schema, where: r.id in ^ids and r.user_id == ^owner, select: r.id)
    |> Repo.all()
    |> Enum.map(&{type, &1})
  end
end
