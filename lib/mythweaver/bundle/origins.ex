defmodule Mythweaver.Bundle.Origins do
  @moduledoc """
  Bundle identity: which uid a row carries out of this instance, and which local row a uid coming
  in matches.

  A row's uid is the origin uid recorded when it was imported (`Mythweaver.Bundle.Origin`), else its
  own id, so an item keeps one identity however many instances it passes through. Every row an
  import writes records the uid it was written from (`record!/3`); a later import of the same uid
  then matches it (`match/3`).
  """

  import Ecto.Query

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.AI
  alias Mythweaver.Bundle.Origin
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Lore
  alias Mythweaver.Memory
  alias Mythweaver.Ownership
  alias Mythweaver.Prompts
  alias Mythweaver.Repo
  alias Mythweaver.Scripts.Script

  @type kind ::
          :character
          | :lore_book
          | :lore_entry
          | :lore_pool
          | :prompt
          | :prompt_block
          | :ai_model
          | :script
          | :memory_profile
          | :side_prompt
          | :side_prompt_set
          | :chat

  @doc "The uid `kind` row `id` is exported under: its recorded origin uid, else `id` itself."
  @spec uid_for(kind(), Ecto.UUID.t()) :: String.t()
  def uid_for(kind, id) do
    Repo.one(from(o in Origin, where: o.kind == ^kind and o.record_id == ^id, select: o.origin_id)) || id
  end

  @doc "`uid_for/2` for many `kind` rows in one query: `%{id => uid}` with every id in `ids`."
  @spec uids_for(kind(), [Ecto.UUID.t()]) :: %{Ecto.UUID.t() => String.t()}
  def uids_for(_kind, []), do: %{}

  def uids_for(kind, ids) do
    ids = Enum.uniq(ids)

    origins =
      from(o in Origin, where: o.kind == ^kind and o.record_id in ^ids, select: {o.record_id, o.origin_id})
      |> Repo.all()
      |> Map.new()

    Map.new(ids, &{&1, Map.get(origins, &1, &1)})
  end

  @doc """
  Records that `kind` row `record_id` was written from bundle uid `uid`, replacing any earlier
  origin. A no-op when `record_id == uid` (the row already is the uid).
  """
  @spec record!(kind(), Ecto.UUID.t(), String.t()) :: :ok
  def record!(_kind, id, id), do: :ok

  def record!(kind, record_id, uid) do
    Repo.insert!(%Origin{kind: kind, record_id: record_id, origin_id: uid},
      on_conflict: {:replace, [:origin_id, :updated_at]},
      conflict_target: [:kind, :record_id]
    )

    :ok
  end

  @doc """
  The local `kind` row bundle uid `uid` matches, or nil.

  Candidates are rows `scope` may use (chats: role-play chats it owns) whose id is `uid` or whose
  recorded origin is `uid`. One `scope` may edit wins over one it may only use, then the latest
  `updated_at`.
  """
  @spec match(Scope.t(), kind(), String.t()) :: struct() | nil
  def match(%Scope{} = scope, kind, uid) when is_binary(uid) do
    schema = schema_for(kind)

    case Ecto.UUID.cast(uid) do
      {:ok, uid} ->
        imported = from(o in Origin, where: o.kind == ^kind and o.origin_id == ^uid, select: o.record_id)

        from(r in schema, where: r.id == ^uid or r.id in subquery(imported))
        |> usable(scope, kind)
        |> Repo.all()
        |> Enum.max_by(&rank(scope, kind, &1), fn -> nil end)

      :error ->
        nil
    end
  end

  def match(%Scope{}, _kind, _uid), do: nil

  # A model's site-model policy (groups included) is the AI context's.
  defp usable(query, scope, :ai_model), do: AI.usable(query, scope)

  defp usable(query, %Scope{user: %User{id: user_id}}, :chat),
    do: where(query, [c], c.user_id == ^user_id and c.kind == ^:roleplay)

  defp usable(query, %Scope{}, :chat), do: where(query, false)
  defp usable(query, scope, _kind), do: Ownership.usable(query, scope)

  defp rank(scope, kind, row), do: {editable?(scope, kind, row), DateTime.to_unix(row.updated_at, :microsecond), row.id}

  defp editable?(scope, :chat, chat), do: Chats.authorize(scope, chat, :manage) == :ok
  defp editable?(scope, _kind, row), do: Ownership.authorize_edit(scope, row) == :ok

  defp schema_for(:character), do: Character
  defp schema_for(:lore_book), do: Lore.LoreBook
  defp schema_for(:lore_entry), do: Lore.LoreEntry
  defp schema_for(:lore_pool), do: Lore.LorePool
  defp schema_for(:prompt), do: Prompts.Prompt
  defp schema_for(:prompt_block), do: Prompts.Block
  defp schema_for(:ai_model), do: AI.Model
  defp schema_for(:script), do: Script
  defp schema_for(:memory_profile), do: Memory.Profile
  defp schema_for(:side_prompt), do: Memory.SidePrompt
  defp schema_for(:side_prompt_set), do: Memory.SidePromptSet
  defp schema_for(:chat), do: Chat
end
