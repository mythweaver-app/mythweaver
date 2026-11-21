defmodule Mythweaver.Memory.Rollback do
  @moduledoc """
  Auto-rollback when a processed message is deleted (SillyTavern-MemoryBooks' rollback settings).

  `message_deleted/1` runs after `Messages.delete_message/1` deletes a message. With
  `"memory.rollback_enabled"` on and the chat holding scene memories, it:

    * cancels the chat's queued/running memory jobs whose range reaches the deleted position
    * with `rollback_delete_memories`, deletes the affected memories (`rollback_scope` `:affected`:
      those covering the position; `:full`: every memory ending at or after it) and, transitively,
      every consolidation built on them, re-enabling the sources those consolidations disabled
    * with `rollback_update_boundary`, moves `highest_processed` back to the surviving memories
    * with `rollback_restore_side_prompts`, undoes side prompt writes over the position, but only
      where the entry still holds exactly what the side prompt wrote (`written_fingerprint`)

  Only records of this chat in books the scope may edit are deleted or restored; the walk up to
  consolidations stops at any other record (another chat's Arc keeps its entry).
  """

  import Ecto.Query, warn: false

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Chats
  alias Mythweaver.Jobs
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Lore
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Memory
  alias Mythweaver.Memory.ChatSettings
  alias Mythweaver.Memory.Record
  alias Mythweaver.Memory.Scene
  alias Mythweaver.Messages.Message
  alias Mythweaver.Moderation.Gate
  alias Mythweaver.Ownership
  alias Mythweaver.Repo

  @doc "Rolls the chat's memories back past the deleted `message`. Always returns `:ok`."
  @spec message_deleted(Scope.t(), Message.t()) :: :ok
  def message_deleted(%Scope{} = scope, %Message{chat_id: chat_id, position: position}) do
    prefs = Memory.preferences(scope)

    if prefs.rollback_enabled and has_memories?(chat_id) do
      rollback(scope, chat_id, position, prefs)
    end

    :ok
  end

  defp has_memories?(chat_id) do
    Repo.exists?(from(r in Record, where: r.chat_id == ^chat_id and r.kind == :memory))
  end

  @doc """
  What deleting messages at `positions` would roll back under the current preferences, without
  changing anything: memories and consolidations deleted, side-prompt entries restored. Records have
  `:entry` preloaded; empty lists when rollback is off, the chat has no memories or the scope may
  not inspect them (a guest). Raises `Mythweaver.UnauthorizedError` when the scope may not read the
  chat.
  """
  @spec preview(Scope.t(), Ecto.UUID.t(), [integer()]) ::
          %{memories: [Record.t()], consolidations: [Record.t()], side_prompts: [Record.t()]}
  def preview(%Scope{} = scope, chat_id, positions) do
    if Chats.authorize(scope, chat_id, :read) != :ok, do: raise(Mythweaver.UnauthorizedError)
    prefs = Memory.preferences(scope)
    none = %{memories: [], consolidations: [], side_prompts: []}

    if positions != [] and prefs.rollback_enabled and has_memories?(chat_id) and
         Chats.authorize(scope, chat_id, :inspect) == :ok do
      # A bulk delete rolls back once per message, and positions are never renumbered, so the
      # union over positions is exactly what it does.
      memories =
        if prefs.rollback_delete_memories do
          scope |> affected_any_query(chat_id, positions, prefs.rollback_scope) |> Repo.all()
        else
          []
        end

      side_prompts =
        if prefs.rollback_restore_side_prompts do
          position = Enum.min(positions)

          from(r in chat_records(scope, chat_id), where: r.kind == :side_prompt, preload: :entry)
          |> Repo.all()
          |> Enum.filter(&restorable?(&1, position))
        else
          []
        end

      %{
        memories: Repo.preload(memories, :entry),
        consolidations:
          memories |> Enum.map(& &1.consolidated_into_id) |> ancestors(scope, chat_id, []) |> Repo.preload(:entry),
        side_prompts: side_prompts
      }
    else
      none
    end
  end

  defp rollback(scope, chat_id, position, prefs) do
    cancel_jobs(scope, chat_id, position)

    {:ok, _} =
      Repo.transaction(fn ->
        if prefs.rollback_delete_memories, do: delete_memories(scope, chat_id, position, prefs.rollback_scope)
        if prefs.rollback_update_boundary, do: update_boundary(chat_id)
        if prefs.rollback_restore_side_prompts, do: restore_side_prompts(scope, chat_id, position)
      end)

    Memory.broadcast_changed(chat_id)
  end

  @doc "Cancels the chat's queued/running memory jobs whose range reaches `position`."
  @spec cancel_jobs(Scope.t(), Ecto.UUID.t(), integer()) :: :ok
  def cancel_jobs(%Scope{} = scope, chat_id, position) do
    from(j in Job,
      where:
        j.chat_id == ^chat_id and j.tag in ^Jobs.memory_tags() and j.status in [:queued, :running] and
          j.range_end >= ^position,
      select: j.id
    )
    |> Repo.all()
    |> Enum.each(&Jobs.cancel(scope, &1))

    :ok
  end

  defp delete_memories(scope, chat_id, position, mode) do
    affected = Repo.all(affected_query(scope, chat_id, position, mode))
    ancestors = ancestors(Enum.map(affected, & &1.consolidated_into_id), scope, chat_id, [])
    ancestor_ids = Enum.map(ancestors, & &1.id)

    sources =
      Repo.all(from(r in Record, where: r.consolidated_into_id in ^ancestor_ids and r.disabled_by_consolidation))

    Lore.set_memberships_enabled(Enum.map(sources, &{&1.lore_book_id, &1.lore_entry_id}), true)

    Repo.update_all(from(r in Record, where: r.id in ^Enum.map(sources, & &1.id)),
      set: [disabled_by_consolidation: false, consolidated_into_id: nil, updated_at: DateTime.utc_now(:second)]
    )

    entry_ids = Enum.map(ancestors ++ affected, & &1.lore_entry_id)
    LoreEntry |> where([e], e.id in ^entry_ids) |> Ownership.editable(scope) |> Repo.delete_all()
  end

  # The chat's own records in books `scope` may edit: the only ones a rollback deletes.
  defp chat_records(scope, chat_id) do
    editable_books = LoreBook |> Ownership.editable(scope) |> select([b], b.id)
    from(r in Record, where: r.chat_id == ^chat_id and r.lore_book_id in subquery(editable_books))
  end

  defp affected_query(scope, chat_id, position, :affected) do
    from(r in chat_records(scope, chat_id),
      where: r.kind == :memory and r.range_start <= ^position and r.range_end >= ^position
    )
  end

  defp affected_query(scope, chat_id, position, :full) do
    from(r in chat_records(scope, chat_id), where: r.kind == :memory and r.range_end >= ^position)
  end

  # The memories `affected_query/4` gives for any of `positions`, in one query.
  defp affected_any_query(scope, chat_id, positions, :affected) do
    from(r in chat_records(scope, chat_id),
      where:
        r.kind == :memory and
          fragment(
            "EXISTS (SELECT 1 FROM unnest(?) AS p(pos) WHERE p.pos BETWEEN ? AND ?)",
            type(^positions, {:array, :integer}),
            r.range_start,
            r.range_end
          ),
      order_by: [asc: r.range_start, asc: r.id]
    )
  end

  defp affected_any_query(scope, chat_id, positions, :full) do
    from(r in chat_records(scope, chat_id),
      where: r.kind == :memory and r.range_end >= ^Enum.min(positions),
      order_by: [asc: r.range_start, asc: r.id]
    )
  end

  # Walks `consolidated_into_id` upward, collecting every consolidation above the given parents
  # among the chat's own records (`chat_records/2`).
  defp ancestors(parent_ids, scope, chat_id, acc) do
    known = MapSet.new(acc, & &1.id)
    ids = parent_ids |> Enum.reject(&(is_nil(&1) or MapSet.member?(known, &1))) |> Enum.uniq()

    case ids do
      [] ->
        acc

      ids ->
        found = Repo.all(from(r in chat_records(scope, chat_id), where: r.id in ^ids))
        ancestors(Enum.map(found, & &1.consolidated_into_id), scope, chat_id, acc ++ found)
    end
  end

  defp update_boundary(chat_id) do
    highest = Repo.one(from(r in Record, where: r.chat_id == ^chat_id and r.kind == :memory, select: max(r.range_end)))
    Repo.update_all(from(s in ChatSettings, where: s.chat_id == ^chat_id), set: [highest_processed: highest])
  end

  defp restore_side_prompts(scope, chat_id, position) do
    from(r in chat_records(scope, chat_id), where: r.kind == :side_prompt, preload: :entry)
    |> Repo.all()
    |> Enum.filter(&restorable?(&1, position))
    |> Enum.each(&restore(scope, &1))
  end

  defp restorable?(%Record{snapshot: %{"range" => [_first, last]}, entry: %LoreEntry{} = entry} = record, position)
       when is_integer(last) do
    last >= position and Scene.sha256(entry.content) == record.written_fingerprint
  end

  defp restorable?(_record, _position), do: false

  # Older versions were switched off in their own record's book; that membership comes back on.
  defp restore(scope, %Record{snapshot: %{"existed" => false} = snapshot} = record) do
    reenable = snapshot["disabled_entry_ids"] || []

    from(r in Record, where: r.lore_entry_id in ^reenable, select: {r.lore_book_id, r.lore_entry_id})
    |> Repo.all()
    |> Lore.set_memberships_enabled(true)

    {:ok, _} = Lore.delete_entry(scope, record.entry)
  end

  defp restore(scope, %Record{snapshot: %{"prior" => %{} = prior}} = record) do
    if is_boolean(prior["enabled"]),
      do: Lore.set_memberships_enabled([{record.lore_book_id, record.lore_entry_id}], prior["enabled"])

    {:ok, entry} =
      Gate.unmoderated(fn ->
        Lore.update_entry(scope, record.entry, %{
          name: prior["name"],
          content: prior["content"],
          keywords: prior["keywords"]
        })
      end)

    record |> Ecto.Changeset.change(snapshot: %{}, written_fingerprint: Scene.sha256(entry.content)) |> Repo.update!()
  end

  defp restore(_scope, _record), do: :ok
end
