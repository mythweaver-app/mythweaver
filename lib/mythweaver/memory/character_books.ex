defmodule Mythweaver.Memory.CharacterBooks do
  @moduledoc """
  Character memory books: a user's lock of one character to a book (`Mythweaver.Memory.CharacterBook`)
  and a chat's per-character book choice, which together pick the book that receives a character's
  copies of new memories (`character_book/3`).
  """

  import Ecto.Query, warn: false

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Memory
  alias Mythweaver.Memory.CharacterBook
  alias Mythweaver.Memory.ChatSettings
  alias Mythweaver.Ownership
  alias Mythweaver.Repo

  @doc "The scope user's lock of `character_id` to a book (`book` preloaded), or nil."
  @spec character_lock(Scope.t(), Ecto.UUID.t()) :: CharacterBook.t() | nil
  def character_lock(%Scope{} = scope, character_id) do
    scope |> character_locks([character_id]) |> Map.values() |> List.first()
  end

  @doc "The scope user's locks of `character_ids`, keyed by character id, books preloaded."
  @spec character_locks(Scope.t(), [Ecto.UUID.t()]) :: %{Ecto.UUID.t() => CharacterBook.t()}
  def character_locks(%Scope{user: %User{id: user_id}}, character_ids) do
    ids = Memory.uuids(character_ids)

    from(l in CharacterBook, where: l.user_id == ^user_id and l.character_id in ^ids, preload: :book)
    |> Repo.all()
    |> Map.new(&{&1.character_id, &1})
  end

  @doc """
  The book that receives `character_id`'s copies of `chat`'s new memories: the scope user's lock's
  book while `scope` may edit it (a broken lock, `lock_broken?/2`, gives nil until unlocked), else
  the chat's `character_book_ids` choice while `scope` may edit it; else nil.
  """
  @spec character_book(Scope.t(), Chat.t(), Ecto.UUID.t()) :: LoreBook.t() | nil
  def character_book(%Scope{} = scope, %Chat{} = chat, character_id) do
    scope |> character_books(chat, [character_id]) |> Map.get(character_id)
  end

  # `character_book/3` for each of `character_ids` whose book resolves, by character id: one lock
  # query, the chat's settings only when some character has no lock, one book query.
  @doc false
  def character_books(scope, chat, character_ids) do
    locks = character_locks(scope, character_ids)

    choices =
      if Enum.all?(character_ids, &Map.has_key?(locks, &1)),
        do: %{},
        else: Memory.chat_settings(scope, chat).character_book_ids

    book_ids =
      Map.new(character_ids, fn id ->
        case locks[id] do
          %CharacterBook{lore_book_id: book_id} -> {id, book_id}
          nil -> {id, choices[id]}
        end
      end)

    books =
      Ownership.editable(LoreBook, scope)
      |> where([b], b.id in ^Memory.uuids(Map.values(book_ids)))
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    for {id, book_id} <- book_ids, %LoreBook{} = book <- [books[book_id]], into: %{}, do: {id, book}
  end

  @doc """
  Whether `lock`'s book is no longer one `scope` may edit (moved to another owner, say): the lock
  then gives its character no copies and must be unlocked. A deleted book deletes its locks.
  """
  @spec lock_broken?(Scope.t(), CharacterBook.t()) :: boolean()
  def lock_broken?(%Scope{} = scope, %CharacterBook{lore_book_id: book_id}),
    do: is_nil(Memory.get_owned(Ownership.editable(LoreBook, scope), book_id))

  @doc """
  Locks `character_id`, a non-player participant of `chat`, to one book for every chat of the scope
  user's: in a solo chat the chat's memory book (`ensure_book/2`), else the character's book in this
  chat (`character_book/3`). The book is then live in each of the user's chats the character joins
  and receives the character's copies of new memories; a solo chat with the character saves its
  memories there (`chat_settings/2`). `{:error, :not_found}` when the character is not one of the
  chat's, `{:error, :no_book}` when a group chat has no book for it.
  """
  @spec lock_character_book(Scope.t(), Chat.t(), Ecto.UUID.t()) ::
          {:ok, CharacterBook.t()} | {:error, :unauthorized | :not_found | :no_book}
  def lock_character_book(%Scope{user: %User{id: user_id}} = scope, %Chat{} = chat, character_id) do
    chat = Repo.preload(chat, :participants)
    bots = Chat.bots(chat)

    with :ok <- Chats.authorize(scope, chat, :manage),
         true <- Enum.any?(bots, &(&1.character_id == character_id)) || {:error, :not_found},
         %LoreBook{} = book <- lock_book(scope, chat, bots, character_id) || {:error, :no_book} do
      upsert_lock(user_id, character_id, book.id)

      Memory.broadcast_changed(chat.id)
      {:ok, character_lock(scope, character_id)}
    end
  end

  defp lock_book(scope, chat, [_solo], _character_id), do: Memory.ensure_book(scope, chat)
  defp lock_book(scope, chat, _bots, character_id), do: character_book(scope, chat, character_id)

  @doc "Removes the scope user's lock of `character_id`; the book and its memories stay."
  @spec unlock_character_book(Scope.t(), Chat.t(), Ecto.UUID.t()) :: :ok | {:error, :unauthorized}
  def unlock_character_book(%Scope{user: %User{id: user_id}} = scope, %Chat{} = chat, character_id) do
    with :ok <- Chats.authorize(scope, chat, :manage) do
      delete_lock(user_id, character_id)
      Memory.broadcast_changed(chat.id)
      :ok
    end
  end

  @doc """
  Sets `book_id` as `character_id`'s book in `chat` (`character_book_ids`) and, when `lock?`, also
  locks the character to it for every chat of the scope user's (`lock_character_book/3`).
  `{:error, :not_found}` when the character is not one of the chat's non-player participants,
  `{:error, :unauthorized}` for a book the scope may not edit.
  """
  @spec assign_character_book(Scope.t(), Chat.t(), Ecto.UUID.t(), Ecto.UUID.t(), boolean()) ::
          {:ok, ChatSettings.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def assign_character_book(%Scope{user: %User{id: user_id}} = scope, %Chat{} = chat, character_id, book_id, lock?) do
    chat = Repo.preload(chat, :participants)

    with :ok <- Chats.authorize(scope, chat, :manage),
         true <- Enum.any?(Chat.bots(chat), &(&1.character_id == character_id)) || {:error, :not_found},
         {:ok, settings} <-
           Repo.transaction(fn -> assign_in_transaction(scope, chat, character_id, book_id, lock?, user_id) end) do
      Memory.broadcast_changed(chat.id)
      {:ok, settings}
    end
  end

  defp assign_in_transaction(scope, chat, character_id, book_id, lock?, user_id) do
    settings = Memory.chat_settings(scope, chat)
    ids = Map.put(settings.character_book_ids, character_id, book_id)

    case Memory.update_chat_settings(scope, settings, %{"character_book_ids" => ids}) do
      {:ok, settings} ->
        if lock?, do: upsert_lock(user_id, character_id, book_id)
        settings

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  @doc """
  Removes `character_id`'s setup in `chat`: its `character_book_ids` choice and the scope user's lock.
  The lock is per user, so this also unlocks the character in the user's other chats. The book and
  its memories stay.
  """
  @spec remove_character_book(Scope.t(), Chat.t(), Ecto.UUID.t()) :: :ok | {:error, :unauthorized}
  def remove_character_book(%Scope{user: %User{id: user_id}} = scope, %Chat{} = chat, character_id) do
    with :ok <- Chats.authorize(scope, chat, :manage) do
      Repo.transaction(fn ->
        settings = Memory.chat_settings(scope, chat)

        settings
        |> Ecto.Changeset.change(character_book_ids: Map.delete(settings.character_book_ids, character_id))
        |> Repo.update!()

        delete_lock(user_id, character_id)
      end)

      Memory.broadcast_changed(chat.id)
      :ok
    end
  end

  defp upsert_lock(user_id, character_id, book_id) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    Repo.insert!(%CharacterBook{user_id: user_id, character_id: character_id, lore_book_id: book_id},
      on_conflict: [set: [lore_book_id: book_id, updated_at: now]],
      conflict_target: [:user_id, :character_id]
    )
  end

  defp delete_lock(user_id, character_id) do
    ids = Memory.uuids([character_id])
    Repo.delete_all(from(l in CharacterBook, where: l.user_id == ^user_id and l.character_id in ^ids))
  end
end
