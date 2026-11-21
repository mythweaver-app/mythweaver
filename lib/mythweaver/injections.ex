defmodule Mythweaver.Injections do
  @moduledoc """
  A chat's injections: prompt text outside the prompt's blocks that steers the next generations.

  Every change is announced as `{:injections_changed, chat_id}` on `Messages.topic(chat_id)`.
  `spend/2` is called only by `Mythweaver.Generation.Server`, after a reply finishes successfully.
  """

  import Ecto.Query, warn: false

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Chats
  alias Mythweaver.Injections.Injection
  alias Mythweaver.Messages
  alias Mythweaver.Repo

  @pubsub Mythweaver.PubSub

  @doc "Every injection in `chat_id`, including disabled and spent ones, in application order."
  @spec list_injections(Scope.t(), Ecto.UUID.t()) :: [Injection.t()]
  def list_injections(%Scope{} = scope, chat_id) do
    if Chats.authorize(scope, chat_id, :inspect) == :ok do
      Repo.all(
        from(i in Injection,
          where: i.chat_id == ^chat_id,
          order_by: [asc: i.order, asc: i.inserted_at, asc: i.id]
        )
      )
    else
      []
    end
  end

  @doc """
  A chat's injection `scope` may edit, by id; `nil` for an unknown or malformed id or one `scope`
  may not edit.
  """
  @spec get_injection(Scope.t(), String.t()) :: Injection.t() | nil
  def get_injection(%Scope{} = scope, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Injection{} = injection <- Repo.get(Injection, id),
         :ok <- Chats.authorize(scope, injection.chat_id, :inspect) do
      injection
    else
      _ -> nil
    end
  end

  @doc "How many of `chat_id`'s injections are enabled and not spent."
  @spec count_active(Scope.t(), Ecto.UUID.t()) :: non_neg_integer()
  def count_active(%Scope{} = scope, chat_id) do
    if Chats.authorize(scope, chat_id, :inspect) != :ok, do: raise(Mythweaver.UnauthorizedError)

    Repo.aggregate(
      from(i in Injection,
        where: i.chat_id == ^chat_id and i.enabled and (is_nil(i.remaining) or i.remaining > 0)
      ),
      :count
    )
  end

  def change_injection(%Injection{} = injection, attrs \\ %{}), do: Injection.changeset(injection, attrs)

  @spec create_injection(Scope.t(), Ecto.UUID.t(), map()) ::
          {:ok, Injection.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def create_injection(%Scope{} = scope, chat_id, attrs) do
    with :ok <- Chats.authorize(scope, chat_id, :manage) do
      %Injection{chat_id: chat_id}
      |> Injection.changeset(attrs)
      |> Repo.insert()
      |> broadcast_change()
    end
  end

  @spec update_injection(Scope.t(), Injection.t(), map()) ::
          {:ok, Injection.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def update_injection(%Scope{} = scope, %Injection{} = injection, attrs) do
    with :ok <- Chats.authorize(scope, injection.chat_id, :manage) do
      injection
      |> Injection.changeset(attrs)
      |> Repo.update()
      |> broadcast_change()
    end
  end

  @spec delete_injection(Scope.t(), Injection.t()) ::
          {:ok, Injection.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def delete_injection(%Scope{} = scope, %Injection{} = injection) do
    with :ok <- Chats.authorize(scope, injection.chat_id, :manage) do
      injection
      |> Repo.delete(allow_stale: true)
      |> broadcast_change()
    end
  end

  @doc "Restores a limited injection's `remaining` to its full `uses`."
  @spec rearm(Scope.t(), Injection.t()) :: {:ok, Injection.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def rearm(%Scope{} = scope, %Injection{} = injection) do
    with :ok <- Chats.authorize(scope, injection.chat_id, :manage) do
      injection
      |> Ecto.Changeset.change(remaining: injection.uses)
      |> Repo.update()
      |> broadcast_change()
    end
  end

  @doc "Deletes `chat_id`'s spent injections. A disabled injection with replies left survives."
  @spec clean_up(Scope.t(), Ecto.UUID.t()) :: {:ok, non_neg_integer()} | {:error, :unauthorized}
  def clean_up(%Scope{} = scope, chat_id) do
    with :ok <- Chats.authorize(scope, chat_id, :manage) do
      {count, _} =
        Repo.delete_all(from(i in Injection, where: i.chat_id == ^chat_id and not is_nil(i.uses) and i.remaining == 0))

      if count > 0, do: broadcast(chat_id)
      {:ok, count}
    end
  end

  @doc "Counts one successful reply against each limited injection in `ids`; never below zero."
  @spec spend(Ecto.UUID.t(), [Ecto.UUID.t()]) :: :ok
  def spend(_chat_id, []), do: :ok

  def spend(chat_id, ids) do
    Repo.update_all(
      from(i in Injection, where: i.id in ^ids and not is_nil(i.remaining) and i.remaining > 0),
      inc: [remaining: -1]
    )

    broadcast(chat_id)
  end

  defp broadcast_change({:ok, %Injection{chat_id: chat_id}} = result) do
    broadcast(chat_id)
    result
  end

  defp broadcast_change(error), do: error

  defp broadcast(chat_id),
    do: Phoenix.PubSub.broadcast(@pubsub, Messages.topic(chat_id), {:injections_changed, chat_id})
end
