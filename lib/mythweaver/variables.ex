defmodule Mythweaver.Variables do
  @moduledoc """
  Chat-scoped and global variables, the store templates read through `vars`/`globals`.

  Global rows are owned (`Mythweaver.Ownership`): a nil `user_id` is a site global, edited by admins;
  a user's own globals are theirs alone. A chat reads site globals overlaid by the chat owner's own
  (the owner's key wins), and a chat's global writes go to the chat owner's own globals (site globals
  for an unowned chat), never to the site's from a user's chat. Chat variables are owned by their chat.

  A chat change is announced as `{:variables_changed, chat_id}` on `Messages.topic(chat_id)`; a
  global one as `{Mythweaver.Changes, :variables}` on its owner's `Mythweaver.Changes` topic (the
  site's for a site global), so a user's own global writes reach only that user.
  """

  import Ecto.Query, warn: false

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Changes
  alias Mythweaver.Chats
  alias Mythweaver.Messages
  alias Mythweaver.Ownership
  alias Mythweaver.Repo
  alias Mythweaver.Templates.State
  alias Mythweaver.Variables.Variable

  @pubsub Mythweaver.PubSub

  @spec list_chat_variables(Scope.t(), Ecto.UUID.t()) :: [Variable.t()]
  def list_chat_variables(%Scope{} = scope, chat_id) do
    if Chats.authorize(scope, chat_id, :inspect) == :ok,
      do: Repo.all(from(v in Variable, where: v.chat_id == ^chat_id, order_by: v.key)),
      else: []
  end

  @doc "The global variables `scope` may edit (its own; plus the site's for a site content manager), by key."
  @spec list_global_variables(Scope.t()) :: [Variable.t()]
  def list_global_variables(%Scope{} = scope), do: globals_by_key() |> Ownership.editable(scope) |> Repo.all()

  @doc "The global variables `scope` may use (its own plus the site's), by key."
  @spec list_usable_global_variables(Scope.t()) :: [Variable.t()]
  def list_usable_global_variables(%Scope{} = scope), do: globals_by_key() |> Ownership.usable(scope) |> Repo.all()

  defp globals_by_key, do: from(v in Variable, where: is_nil(v.chat_id), order_by: [v.key, v.user_id])

  @doc """
  A global variable `scope` may edit, by id; `nil` for an unknown or malformed id, a chat variable or
  one `scope` may not edit.
  """
  @spec get_global_variable(Scope.t(), String.t()) :: Variable.t() | nil
  def get_global_variable(%Scope{} = scope, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        from(v in Variable, where: v.id == ^id and is_nil(v.chat_id))
        |> Ownership.editable(scope)
        |> Repo.one()

      :error ->
        nil
    end
  end

  @doc """
  A variable `scope` may edit, by id, whether chat-scoped or global; `nil` for an unknown or
  malformed id or one `scope` may not edit.
  """
  @spec get_editable_variable(Scope.t(), String.t()) :: Variable.t() | nil
  def get_editable_variable(%Scope{} = scope, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Variable{} = variable <- Repo.get(Variable, id),
         :ok <- authorize(scope, variable) do
      variable
    else
      _ -> nil
    end
  end

  def get_variable!(id), do: Repo.get!(Variable, id)

  def change_variable(%Variable{} = variable, attrs \\ %{}), do: Variable.changeset(variable, attrs)

  @doc """
  Creates a variable in `chat_id`, or a global one when `chat_id` is `nil`: owned per
  `Ownership.new_owner/3`, `scope`'s own, or the site's with `site: true` (globals only).
  """
  @spec create_variable(Scope.t(), Ecto.UUID.t() | nil, map(), keyword()) ::
          {:ok, Variable.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def create_variable(scope, chat_id, attrs, opts \\ [])

  def create_variable(%Scope{} = scope, nil, attrs, opts) do
    with {:ok, user_id} <- Ownership.new_owner(scope, Variable, opts) do
      %Variable{user_id: user_id}
      |> Variable.changeset(attrs)
      |> Repo.insert()
      |> broadcast_change()
    end
  end

  def create_variable(%Scope{} = scope, chat_id, attrs, _opts) do
    with :ok <- Chats.authorize(scope, chat_id, :manage) do
      %Variable{chat_id: chat_id}
      |> Variable.changeset(attrs)
      |> Repo.insert()
      |> broadcast_change()
    end
  end

  @spec update_variable(Scope.t(), Variable.t(), map()) ::
          {:ok, Variable.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def update_variable(%Scope{} = scope, %Variable{} = variable, attrs) do
    with :ok <- authorize(scope, variable) do
      variable
      |> Variable.changeset(attrs)
      |> Repo.update()
      |> broadcast_change()
    end
  end

  # `allow_stale`: a generation may have deleted the row (`{% setvar k = nil %}`) since it was listed.
  @spec delete_variable(Scope.t(), Variable.t()) ::
          {:ok, Variable.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def delete_variable(%Scope{} = scope, %Variable{} = variable) do
    with :ok <- authorize(scope, variable) do
      variable
      |> Repo.delete(allow_stale: true)
      |> broadcast_change()
    end
  end

  defp authorize(scope, %Variable{chat_id: nil} = variable), do: Ownership.authorize_edit(scope, variable)
  defp authorize(scope, %Variable{chat_id: chat_id}), do: Chats.authorize(scope, chat_id, :manage)

  @doc """
  The stored values a template starts from: `chat_id`'s variables and the globals, site globals
  overlaid by the chat owner's own.
  """
  @spec values(Ecto.UUID.t()) :: %{chat: map(), global: map()}
  def values(chat_id) do
    chat = from(v in Variable, where: v.chat_id == ^chat_id, select: {v.key, v.value}) |> Repo.all() |> Map.new()
    %{chat: chat, global: globals_of(Chats.owner_id(chat_id))}
  end

  @doc "The globals `scope`'s own chats read: site globals overlaid by its own, by key."
  @spec global_values(Scope.t()) :: map()
  def global_values(%Scope{user: %{id: user_id}}), do: globals_of(user_id)

  # Site globals overlaid by `owner_id`'s own.
  defp globals_of(owner_id) do
    from(v in Variable, where: is_nil(v.chat_id), select: {v.user_id, v.key, v.value})
    |> Ownership.for_owner(owner_id)
    |> Repo.all()
    # Site rows first, so the owner's own value for a key replaces the site's.
    |> Enum.sort_by(fn {user_id, _, _} -> not is_nil(user_id) end)
    |> Map.new(fn {_, key, value} -> {key, value} end)
  end

  @doc """
  Writes one variable by key, as `{% setvar %}` (`chat_id`) or `{% setglobalvar %}` (`nil`) does: a
  global goes to `scope`'s own globals, never the site's. A `nil` value deletes the variable.
  """
  @spec put_value(Scope.t(), Ecto.UUID.t() | nil, String.t(), term()) ::
          :ok | {:error, Ecto.Changeset.t() | :unauthorized}
  def put_value(%Scope{} = scope, chat_id, key, value) do
    {kind, user_id} = if chat_id, do: {"chat", nil}, else: {"global", scope.user.id}
    changeset = Variable.changeset(%Variable{chat_id: chat_id, user_id: user_id}, %{key: key, value: value})

    # Deleting needs no valid value; an invalid key matches no row.
    # A script's write: the script itself was cleared to run in the chat (`Mythweaver.Scripts`).
    with :ok <- if(chat_id, do: Chats.authorize(scope, chat_id, :post), else: :ok),
         :ok <- if(is_nil(value) or changeset.valid?, do: :ok, else: {:error, changeset}) do
      write_scope(kind, chat_id, user_id, [{key, value}])
      if chat_id, do: broadcast_chat(chat_id), else: Changes.broadcast(:variables, user_id)
      :ok
    end
  end

  @doc """
  Persists a render's variable writes in one transaction: the last write per key wins, a `nil`
  value deletes. Values are already JSON terms (`Mythweaver.Templates.Value.to_json/1`).
  """
  @spec apply_writes(Ecto.UUID.t(), [State.write()]) :: :ok
  def apply_writes(_chat_id, []), do: :ok

  def apply_writes(chat_id, writes) do
    by_scope =
      writes
      |> Map.new(fn %{"scope" => scope, "key" => key, "value" => value} -> {{scope, key}, value} end)
      |> Enum.group_by(fn {{scope, _key}, _} -> scope end, fn {{_, key}, value} -> {key, value} end)

    owner_id = if Map.has_key?(by_scope, "global"), do: Chats.owner_id(chat_id)

    {:ok, _} =
      Repo.transaction(fn ->
        Enum.each(by_scope, fn {scope, finals} -> write_scope(scope, chat_id, owner_id, finals) end)
      end)

    if Map.has_key?(by_scope, "chat"), do: broadcast_chat(chat_id)
    if Map.has_key?(by_scope, "global"), do: Changes.broadcast(:variables, owner_id)
    :ok
  end

  defp write_scope(scope, chat_id, user_id, finals) do
    {chat_id, user_id} = if scope == "chat", do: {chat_id, nil}, else: {nil, user_id}
    {deleted, kept} = Enum.split_with(finals, fn {_key, value} -> is_nil(value) end)

    if deleted != [] do
      keys = Enum.map(deleted, &elem(&1, 0))
      Repo.delete_all(from(v in scope_query(chat_id, user_id), where: v.key in ^keys))
    end

    if kept != [] do
      now = DateTime.utc_now()

      rows =
        Enum.map(kept, fn {key, value} ->
          %{
            id: Mythweaver.Schema.generate_id(),
            chat_id: chat_id,
            user_id: user_id,
            key: key,
            value: value,
            inserted_at: now,
            updated_at: now
          }
        end)

      Repo.insert_all(Variable, rows,
        on_conflict: {:replace, [:value, :updated_at]},
        conflict_target: conflict_target(scope)
      )
    end
  end

  # The unique indexes are partial, so the conflict target must repeat their predicates.
  defp conflict_target("chat"), do: {:unsafe_fragment, "(chat_id, key) WHERE chat_id IS NOT NULL"}
  defp conflict_target("global"), do: {:unsafe_fragment, "(user_id, key) WHERE chat_id IS NULL"}

  defp scope_query(nil, user_id), do: Ownership.owned_exactly(from(v in Variable, where: is_nil(v.chat_id)), user_id)
  defp scope_query(chat_id, _user_id), do: from(v in Variable, where: v.chat_id == ^chat_id)

  defp broadcast_change({:ok, %Variable{chat_id: nil, user_id: user_id}} = result) do
    Changes.broadcast(:variables, user_id)
    result
  end

  defp broadcast_change({:ok, %Variable{chat_id: chat_id}} = result) do
    broadcast_chat(chat_id)
    result
  end

  defp broadcast_change(error), do: error

  defp broadcast_chat(chat_id),
    do: Phoenix.PubSub.broadcast(@pubsub, Messages.topic(chat_id), {:variables_changed, chat_id})
end
