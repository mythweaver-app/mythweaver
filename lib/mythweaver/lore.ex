defmodule Mythweaver.Lore do
  @moduledoc """
  The Lore context: lore books, lore entries, their membership joins, inclusion pools, and the
  bindings that decide which books are live in a chat.

  A lore entry is first-class and shared: it belongs to zero or more books, and each membership
  (`Lore.BookEntry`) carries its own `enabled` flag and `order`; the entry itself has no on/off
  switch. An entry in no book is "unlinked": it never activates, and deleting a book leaves its
  exclusive entries unlinked.

  ## Ownership

  Books, entries and pools follow `Mythweaver.Ownership` (`"content.lore.create"`): a site row
  (`user_id` nil) is usable by everyone and edited by site content managers; a user's row only by that user. Editor
  lists (`list_books/1`, `list_entries/1`, `list_pools/1`, `list_tree/1`, `get_editable_*`) hold
  editable rows; pickers and chats read usable ones (`list_usable_books/1`, `get_book/2`,
  `get_entry/2`). A membership (`BookEntry`, `PoolEntry`) joins rows of the same owner (or both
  site), so a new entry takes its books' owner. A book binds only characters its owner may reference
  (a site book: site characters), and a chat only books its owner may use. Activation
  (`books_for_chat/2`) reads books usable by the chat's owner. An admin may move their own book to the
  site (`transfer_book/3`), which removes every link the site may not hold; a site book never becomes
  personal.
  """

  import Ecto.Query, warn: false

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.Changes
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Chats.Participant
  alias Mythweaver.Lore.BookCharacter
  alias Mythweaver.Lore.BookChat
  alias Mythweaver.Lore.BookEntry
  alias Mythweaver.Lore.BookFilterTag
  alias Mythweaver.Lore.Embeddings
  alias Mythweaver.Lore.EntryCharacter
  alias Mythweaver.Lore.EntryFilterTag
  alias Mythweaver.Lore.EntryState
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Lore.LorePool
  alias Mythweaver.Lore.PoolEntry
  alias Mythweaver.Lore.Transfer
  alias Mythweaver.Memory.CharacterBook
  alias Mythweaver.Memory.ChatSettings
  alias Mythweaver.Moderation.Gate
  alias Mythweaver.Moderation.Hold
  alias Mythweaver.Ownership
  alias Mythweaver.Permissions.Quota
  alias Mythweaver.Repo
  alias Mythweaver.Schema
  alias Mythweaver.Sharing.Visibility
  alias Mythweaver.Tags

  ## Books

  @doc "Books `scope` may edit (its own; plus the site's for an admin), by name."
  def list_books(%Scope{} = scope) do
    from(b in LoreBook, order_by: [asc: b.name, asc: b.id], preload: [:book_entries])
    |> Ownership.editable(scope)
    |> Repo.all()
  end

  @doc """
  Books `scope` may use and see (its own plus the site's, minus hidden ones), by name: binding and
  memory-book pickers.
  """
  def list_usable_books(%Scope{} = scope) do
    from(b in LoreBook, order_by: [asc: b.name, asc: b.id])
    |> Ownership.usable(scope)
    |> Visibility.listed_books(scope)
    |> Repo.all()
  end

  @doc """
  The first book usable by `scope` and visible to it (no hidden site book) named exactly `name`, or
  nil: the scope user's own wins over a site one, then the oldest (ids are time-ordered UUID v7).
  """
  @spec find_usable_book_by_name(Scope.t(), String.t()) :: LoreBook.t() | nil
  def find_usable_book_by_name(%Scope{} = scope, name) when is_binary(name) do
    listed = LoreBook |> Ownership.usable(scope) |> Visibility.listed_books(scope)

    Repo.one(
      from(b in listed,
        where: b.name == ^name,
        order_by: ^[asc: Ownership.owner_rank(scope.user && scope.user.id), asc: dynamic([b], b.id)],
        limit: 1
      )
    )
  end

  def get_book!(id), do: LoreBook |> Repo.get!(id) |> Repo.preload(book_preloads())

  @doc "A book `scope` may use and see, preloaded (chat bindings: only `scope`'s own chats), or nil."
  def get_book(%Scope{} = scope, id),
    do: LoreBook |> Ownership.usable(scope) |> Visibility.listed_books(scope) |> fetch_owned(id, book_preloads(scope))

  @doc "A book `scope` may edit, preloaded (chat bindings: only `scope`'s own chats), or nil."
  def get_editable_book(%Scope{} = scope, id),
    do: fetch_owned(Ownership.editable(LoreBook, scope), id, book_preloads(scope))

  defp fetch_owned(query, id, preloads) do
    with {:ok, id} <- Ecto.UUID.cast(id), %{} = row <- Repo.get(query, id) do
      Repo.preload(row, preloads)
    else
      _ -> nil
    end
  end

  @doc """
  Creates a book owned per `Ownership.new_owner/3`: `scope`'s own, or the site's with `site: true`
  (which needs `"site.content.manage"`). `import: true` also casts the import-only fields
  (`LoreBook.import_changeset/2`).
  """
  @spec create_book(Scope.t(), map(), keyword()) ::
          {:ok, LoreBook.t()} | {:error, Ecto.Changeset.t() | :unauthorized | :quota_exceeded}
  def create_book(%Scope{} = scope, attrs \\ %{}, opts \\ []) do
    with {:ok, owner} <- Ownership.new_owner(scope, LoreBook, opts),
         :ok <- Quota.check_new_row(scope, owner, "quota.lore_books", LoreBook) do
      changeset = book_changeset(%LoreBook{user_id: owner}, attrs, opts)

      # Books are scanned, never held (`Mythweaver.Moderation.Gate`).
      scope
      |> Gate.run(changeset, {__MODULE__, :create_book, [attrs, opts]}, [], fn -> Repo.insert(changeset) end)
      |> Changes.notify(:lore)
    end
  end

  defp book_changeset(book, attrs, opts) do
    if Keyword.get(opts, :import, false),
      do: LoreBook.import_changeset(book, attrs),
      else: LoreBook.changeset(book, attrs)
  end

  @doc """
  Creates a book bound to `chat` (its memory book), owned by the chat's owner. Needs
  `:manage` on the chat (`Chats.authorize/3`: its owner or a chat editor), not an admin.
  """
  @spec create_chat_book(Scope.t(), Chat.t(), map()) ::
          {:ok, LoreBook.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def create_chat_book(%Scope{} = scope, %Chat{} = chat, attrs) do
    with :ok <- Chats.authorize(scope, chat, :manage) do
      Repo.transact(fn ->
        with {:ok, book} <- %LoreBook{user_id: chat.user_id} |> LoreBook.changeset(attrs) |> Repo.insert(),
             {:ok, _} <- set_chat_books(chat, chat_book_ids(chat) ++ [book.id]) do
          {:ok, book}
        end
      end)
      |> Changes.notify(:lore, chat.user_id)
    end
  end

  @doc "Updates a book `scope` may edit; `import: true` as for `create_book/3`."
  @spec update_book(Scope.t(), LoreBook.t(), map(), keyword()) ::
          {:ok, LoreBook.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def update_book(%Scope{} = scope, %LoreBook{} = book, attrs, opts \\ []) do
    with :ok <- Ownership.authorize_edit(scope, book) do
      changeset = book_changeset(book, attrs, opts)

      scope
      |> Gate.run(changeset, {__MODULE__, :update_book, [{:row, LoreBook, book.id}, attrs, opts]}, [], fn ->
        Repo.update(changeset)
      end)
      |> Changes.notify(:lore)
    end
  end

  @doc """
  Deletes a book. Its memberships cascade; entries it held alone become unlinked. With accepted
  editors it is given to `opts[:to]` or the oldest of them instead (`Mythweaver.Sharing.hand_off_or/4`).
  """
  @spec delete_book(Scope.t(), LoreBook.t(), keyword()) ::
          {:ok, LoreBook.t() | {:handed_off, User.t()}}
          | {:error, Ecto.Changeset.t() | :unauthorized}
  def delete_book(%Scope{} = scope, %LoreBook{} = book, opts \\ []) do
    with :ok <- Ownership.authorize_delete(scope, book) do
      Mythweaver.Sharing.hand_off_or(scope, book, opts, fn ->
        :ok = Mythweaver.Sharing.revoke_all(:lore_book, book.id, :deleted)
        book |> Repo.delete() |> Changes.notify(:lore)
      end)
    end
  end

  @doc """
  Moves `book` and its entries to the site (`:site`), removing every link the site may not hold
  (`Mythweaver.Lore.Transfer`). Site content managers only, in sudo mode, and only a book `scope` may
  delete: its own. `{:error, :same_owner}` when the book is already the site's.
  """
  @spec transfer_book(Scope.t(), LoreBook.t(), :site) ::
          {:ok, LoreBook.t()} | {:error, :unauthorized | :same_owner | :sudo_required}
  def transfer_book(%Scope{} = scope, %LoreBook{} = book, :site) do
    with :ok <- authorize_transfer(scope, book),
         :ok <- Mythweaver.Accounts.authorize_sudo(scope),
         do: book |> Transfer.run() |> Changes.notify(:lore, [nil, scope.user.id])
  end

  @doc "What `transfer_book/3` would change, by kind (`Mythweaver.Lore.Transfer.impact/2`)."
  @spec transfer_impact(Scope.t(), LoreBook.t(), :site) ::
          {:ok, Transfer.impact()} | {:error, :unauthorized | :same_owner}
  def transfer_impact(%Scope{} = scope, %LoreBook{} = book, :site) do
    with :ok <- authorize_transfer(scope, book), do: {:ok, Transfer.impact(book)}
  end

  defp authorize_transfer(scope, book) do
    cond do
      not Scope.can?(scope, "site.content.manage") or Ownership.authorize_delete(scope, book) != :ok ->
        {:error, :unauthorized}

      is_nil(book.user_id) ->
        {:error, :same_owner}

      true ->
        :ok
    end
  end

  def change_book(%LoreBook{} = book, attrs \\ %{}) do
    LoreBook.changeset(book, attrs)
  end

  defp book_preloads,
    do: [
      :filter_tags,
      book_entries: :entry,
      book_chats: :chat,
      book_characters: :character,
      rules: [conditions: [:chat, :character]]
    ]

  # Another user's chat binding is theirs alone: its chat name and switch stay hidden from the editor;
  # so does the chat a rule condition names.
  defp book_preloads(%Scope{user: %{id: uid}}) do
    own_chats = from(bc in BookChat, join: c in assoc(bc, :chat), where: c.user_id == ^uid, preload: [chat: c])

    [
      :filter_tags,
      book_entries: :entry,
      book_chats: own_chats,
      book_characters: :character,
      rules: [conditions: [:character, chat: from(c in Chat, where: c.user_id == ^uid)]]
    ]
  end

  ## Entries

  @doc "Entries `scope` may edit, by name."
  def list_entries(%Scope{} = scope) do
    from(e in LoreEntry, order_by: [asc: e.name, asc: e.id], preload: [:books, :pools, :book_entries])
    |> Ownership.editable(scope)
    |> Repo.all()
  end

  @doc """
  Entries `scope` may use and read (own plus the site's, minus hidden content), by name: the
  Additional Context picker.
  """
  def list_usable_entries(%Scope{} = scope) do
    from(e in LoreEntry, order_by: [asc: e.name, asc: e.id])
    |> Ownership.usable(scope)
    |> Visibility.readable_entries(scope)
    |> Repo.all()
  end

  @doc """
  Entries of one book, ordered by effective injection order (descending), then name. Each carries
  its `book_entries`, so a caller can read this book's membership (`enabled`, `order`).
  """
  def list_entries_in_book(%Scope{}, %LoreBook{} = book) do
    from(be in BookEntry,
      where: be.lore_book_id == ^book.id,
      join: e in assoc(be, :entry),
      order_by: [desc: be.order + ^book.order_adjustment, asc: e.name],
      preload: [entry: {e, [:books, :pools, :entry_characters, :book_entries]}]
    )
    |> Repo.all()
    |> Enum.map(& &1.entry)
  end

  def get_entry!(id), do: LoreEntry |> Repo.get!(id) |> Repo.preload(entry_preloads())

  @doc "An entry `scope` may use and see (in no book hidden from it), preloaded, or nil."
  def get_entry(%Scope{} = scope, id),
    do: LoreEntry |> Ownership.usable(scope) |> Visibility.listed_entries(scope) |> fetch_owned(id, entry_preloads())

  @doc "An entry `scope` may edit, preloaded, or nil."
  def get_editable_entry(%Scope{} = scope, id),
    do: fetch_owned(Ownership.editable(LoreEntry, scope), id, entry_preloads())

  @doc """
  Creates an entry and its book memberships in one transaction. `book_ids == []` leaves it unlinked,
  owned per `Ownership.new_owner/2`; otherwise every book must be editable by `scope` and share one
  owner, which the entry takes. Each membership takes `membership_attrs[:order]`, or lands at the top
  of its book when absent. `import: true` also casts `foreign` (`LoreEntry.import_changeset/2`).
  Content moderation may hold it instead (`Mythweaver.Moderation.Gate.run/5`); `followups:` run
  after an approved hold saves.
  """
  @spec create_entry(Scope.t(), map(), [Ecto.UUID.t()], map(), keyword()) ::
          {:ok, LoreEntry.t()}
          | {:held, Hold.t()}
          | {:error, Ecto.Changeset.t() | :unauthorized | :hold_limit}
  def create_entry(%Scope{} = scope, attrs, book_ids, membership_attrs \\ %{}, opts \\ []) when is_list(book_ids) do
    {followups, opts} = Keyword.pop(opts, :followups, [])

    with {:ok, owner} <- entry_owner(scope, book_ids) do
      changeset = entry_changeset(%LoreEntry{user_id: owner}, attrs, opts)
      op = {__MODULE__, :create_entry, [attrs, book_ids, membership_attrs, opts]}

      scope
      |> Gate.run(changeset, op, [followups: followups], fn ->
        Repo.transaction(fn ->
          entry = changeset |> Repo.insert() |> Repo.ok_or_rollback()

          Enum.each(book_ids, fn book_id ->
            insert_membership!(book_id, entry.id, membership_attrs[:order])
          end)

          Repo.preload(entry, entry_preloads())
        end)
        |> refresh_embeddings(scope)
      end)
      |> Changes.notify(:lore)
    end
  end

  defp entry_changeset(entry, attrs, opts) do
    if Keyword.get(opts, :import, false),
      do: LoreEntry.import_changeset(entry, attrs),
      else: LoreEntry.changeset(entry, attrs)
  end

  defp entry_owner(scope, []), do: Ownership.new_owner(scope, LoreEntry)

  defp entry_owner(scope, book_ids) do
    book_ids = Enum.uniq(book_ids)
    books = Repo.all(from(b in LoreBook, where: b.id in ^book_ids))

    with true <- length(books) == length(book_ids),
         [owner] <- books |> Enum.map(& &1.user_id) |> Enum.uniq(),
         true <- Enum.all?(books, &(Ownership.authorize_edit(scope, &1) == :ok)) do
      {:ok, owner}
    else
      _ -> {:error, :unauthorized}
    end
  end

  @doc "Updates an entry `scope` may edit; `import: true` as for `create_entry/5`."
  @spec update_entry(Scope.t(), LoreEntry.t(), map(), keyword()) ::
          {:ok, LoreEntry.t()} | {:held, Hold.t()} | {:error, Ecto.Changeset.t() | :unauthorized | :hold_limit}
  def update_entry(%Scope{} = scope, %LoreEntry{} = entry, attrs, opts \\ []) do
    with :ok <- Ownership.authorize_edit(scope, entry) do
      changeset = entry_changeset(entry, attrs, opts)

      scope
      |> Gate.run(changeset, {__MODULE__, :update_entry, [{:row, LoreEntry, entry.id}, attrs, opts]}, [], fn ->
        changeset |> Repo.update() |> refresh_embeddings(scope)
      end)
      |> Changes.notify(:lore)
    end
  end

  # A saved Vector entry is embedded in the background. Not from inside an outer transaction (memory
  # writers, imports): the task could not see the uncommitted row, so the next chat sync or the
  # import's `Embeddings.refresh_books_later/2` catches those up.
  defp refresh_embeddings({:ok, entry} = result, scope) do
    if !Repo.in_transaction?(), do: Embeddings.refresh_later(scope, [entry])
    result
  end

  defp refresh_embeddings(result, _scope), do: result

  @doc "Deletes an entry outright; every join row cascades."
  @spec delete_entry(Scope.t(), LoreEntry.t()) :: {:ok, LoreEntry.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def delete_entry(%Scope{} = scope, %LoreEntry{} = entry) do
    with :ok <- Ownership.authorize_delete(scope, entry), do: entry |> Repo.delete() |> Changes.notify(:lore)
  end

  def change_entry(%LoreEntry{} = entry, attrs \\ %{}) do
    LoreEntry.changeset(entry, attrs)
  end

  defp entry_preloads, do: [:books, :pools, :book_entries, :entry_characters, :filter_characters, :filter_tags]

  defp insert_membership!(book_id, entry_id, order) do
    %BookEntry{}
    |> BookEntry.changeset(%{lore_book_id: book_id, lore_entry_id: entry_id, order: order || next_order(book_id)})
    |> Repo.insert()
    |> Repo.ok_or_rollback()
  end

  # One above the book's highest order, so a new membership lands at the top of the descending list.
  defp next_order(book_id) do
    (Repo.one(from(be in BookEntry, where: be.lore_book_id == ^book_id, select: max(be.order))) || 0) + 1
  end

  # Serial numbering of this book's memberships, top row first: the bottom row gets 1. Only this book's
  # rows are touched, so a shared entry keeps its order elsewhere. One `UPDATE … FROM unnest(…)`.
  defp renumber!(book_id, entry_ids) do
    count = length(entry_ids)

    Repo.update_all(
      from(be in BookEntry,
        join:
          n in fragment(
            "SELECT * FROM unnest(?, ?) AS n(entry_id, ord)",
            type(^entry_ids, {:array, Ecto.UUID}),
            type(^Enum.to_list(count..1//-1), {:array, :integer})
          ),
        on: n.entry_id == be.lore_entry_id,
        where: be.lore_book_id == ^book_id,
        update: [set: [order: n.ord]]
      ),
      []
    )
  end

  ## Membership

  @doc "Drops one membership. Removing an entry's last book leaves it unlinked."
  @spec remove_entry_from_book(Scope.t(), LoreBook.t(), LoreEntry.t()) ::
          {:ok, BookEntry.t()} | {:error, :not_a_member | :unauthorized}
  def remove_entry_from_book(%Scope{} = scope, %LoreBook{} = book, %LoreEntry{} = entry) do
    with :ok <- Ownership.authorize_edit(scope, book) do
      Repo.transaction(fn ->
        case Repo.get_by(BookEntry, lore_book_id: book.id, lore_entry_id: entry.id) do
          nil -> Repo.rollback(:not_a_member)
          membership -> Repo.delete!(membership)
        end
      end)
      |> Changes.notify(:lore, book.user_id)
    end
  end

  def update_membership(%BookEntry{} = membership, attrs) do
    membership
    |> BookEntry.changeset(attrs)
    |> Repo.update()
    |> Changes.notify(:lore, book_owners([membership.lore_book_id]))
  end

  @doc """
  Switches `entry_id` on or off in `book` only; its other books are untouched.
  `{:error, :not_a_member}` when the entry is not in the book (a malformed id included).
  """
  @spec set_membership_enabled(Scope.t(), LoreBook.t(), term(), boolean()) ::
          {:ok, BookEntry.t()} | {:error, Ecto.Changeset.t() | :not_a_member | :unauthorized}
  def set_membership_enabled(%Scope{} = scope, %LoreBook{} = book, entry_id, enabled?) when is_boolean(enabled?) do
    with :ok <- Ownership.authorize_edit(scope, book),
         do: book |> update_member(entry_id, %{enabled: enabled?}) |> Changes.notify(:lore, book.user_id)
  end

  defp update_member(book, entry_id, attrs) do
    with {:ok, entry_id} <- Ecto.UUID.cast(entry_id),
         %BookEntry{} = membership <- Repo.get_by(BookEntry, lore_book_id: book.id, lore_entry_id: entry_id) do
      update_membership(membership, attrs)
    else
      _ -> {:error, :not_a_member}
    end
  end

  @doc """
  Switches each `{book_id, entry_id}` membership on or off; a pair with no membership is skipped.
  """
  def set_memberships_enabled([], enabled?) when is_boolean(enabled?), do: :ok

  def set_memberships_enabled(pairs, enabled?) when is_list(pairs) and is_boolean(enabled?) do
    {book_ids, entry_ids} = Enum.unzip(pairs)

    Repo.update_all(
      from(be in BookEntry,
        join:
          p in fragment(
            "SELECT * FROM unnest(?, ?) AS p(book_id, entry_id)",
            type(^book_ids, {:array, Ecto.UUID}),
            type(^entry_ids, {:array, Ecto.UUID})
          ),
        on: p.book_id == be.lore_book_id and p.entry_id == be.lore_entry_id
      ),
      set: [enabled: enabled?]
    )

    Changes.notify(:ok, :lore, book_owners(book_ids))
  end

  @doc """
  Sets `entry_id`'s order in `book` only. `{:error, :not_a_member}` when the entry is not in the book,
  `{:error, changeset}` when the order is invalid.
  """
  @spec set_membership_order(Scope.t(), LoreBook.t(), term(), term()) ::
          {:ok, BookEntry.t()} | {:error, Ecto.Changeset.t() | :not_a_member | :unauthorized}
  def set_membership_order(%Scope{} = scope, %LoreBook{} = book, entry_id, order) do
    with :ok <- Ownership.authorize_edit(scope, book),
         do: book |> update_member(entry_id, %{order: order}) |> Changes.notify(:lore, book.user_id)
  end

  @doc """
  Renumbers `book`'s memberships from a dragged list, top row first. Naive serial numbering: the
  bottom row gets `order` 1 and each row above one more, whatever the old numbers were, because the
  book lists (and activation sorts) by order descending. Only this book's memberships change, so a
  shared entry keeps its order in its other books.

  `entry_ids` must be a permutation of the book's entries, else `{:error, :not_a_permutation}`.
  """
  @spec reorder_book_entries(Scope.t(), LoreBook.t(), [Ecto.UUID.t()]) ::
          {:ok, :ok} | {:error, :not_a_permutation | :unauthorized}
  def reorder_book_entries(%Scope{} = scope, %LoreBook{} = book, entry_ids) when is_list(entry_ids) do
    with :ok <- Ownership.authorize_edit(scope, book) do
      if Enum.sort(entry_ids) == Enum.sort(book_entry_ids(book.id)) do
        Repo.transaction(fn ->
          # `update_all`, so `updated_at` stays put on the entries: Memory Books compare it to detect a
          # hand edit of an entry's content, and a reorder is not one.
          renumber!(book.id, entry_ids)
          :ok
        end)
        |> Changes.notify(:lore, book.user_id)
      else
        {:error, :not_a_permutation}
      end
    end
  end

  defp book_entry_ids(book_id) do
    Repo.all(from(be in BookEntry, where: be.lore_book_id == ^book_id, select: be.lore_entry_id))
  end

  @doc """
  Makes the entry's memberships exactly `book_ids` plus those in books `scope` cannot edit (kept, as
  the picker never lists them), in one transaction. An empty list unlinks it from every book it can
  edit. New memberships land at the top of their book; kept rows are untouched. Every requested book
  must have the entry's owner, else `{:error, :unauthorized}`.
  """
  @spec set_entry_books(Scope.t(), LoreEntry.t(), [Ecto.UUID.t()]) :: {:ok, :ok} | {:error, term()}
  def set_entry_books(%Scope{} = scope, %LoreEntry{} = entry, book_ids) when is_list(book_ids) do
    with :ok <- Ownership.authorize_edit(scope, entry),
         :ok <- same_owner(LoreBook, MapSet.new(book_ids), entry.user_id) do
      Repo.transaction(fn ->
        existing = Repo.all(from(be in BookEntry, where: be.lore_entry_id == ^entry.id))
        unseen = unseen(Enum.map(existing, & &1.lore_book_id), Ownership.editable(LoreBook, scope))

        Repo.sync_rows!(
          existing,
          :lore_book_id,
          MapSet.new(book_ids ++ unseen),
          &BookEntry.changeset(%BookEntry{}, %{lore_book_id: &1, lore_entry_id: entry.id, order: next_order(&1)})
        )
      end)
      |> Changes.notify(:lore, entry.user_id)
    end
  end

  # `:ok` when every id in `ids` is a `schema` row owned exactly by `owner` (a membership's two sides).
  defp same_owner(schema, ids, owner), do: all_in(Ownership.owned_exactly(schema, owner), ids)

  @doc """
  The books `scope` may edit with their entries, plus its editable entries in no book, for the lore
  tree:

      %{books: [%{book: book, entries: [%{entry: entry, membership: membership, book_count: n}]}],
        unlinked: [entry]}

  Books by name; each book's entries by effective order descending, then name.
  """
  def list_tree(%Scope{} = scope) do
    books = from(b in LoreBook, order_by: [asc: b.name, asc: b.id]) |> Ownership.editable(scope) |> Repo.all()
    book_ids = Enum.map(books, & &1.id)

    rows =
      Repo.all(
        from(be in BookEntry,
          where: be.lore_book_id in ^book_ids,
          join: e in assoc(be, :entry),
          left_join:
            c in subquery(
              from(be in BookEntry, group_by: be.lore_entry_id, select: %{id: be.lore_entry_id, n: count()})
            ),
          on: c.id == e.id,
          select: {be, e, c.n}
        )
      )

    by_book = Enum.group_by(rows, fn {be, _, _} -> be.lore_book_id end)

    unlinked =
      from(e in LoreEntry,
        as: :e,
        where: not exists(from(be in BookEntry, where: be.lore_entry_id == parent_as(:e).id)),
        order_by: [asc: e.name, asc: e.id]
      )
      |> Ownership.editable(scope)
      |> Repo.all()

    %{
      books:
        Enum.map(books, fn book ->
          entries =
            by_book
            |> Map.get(book.id, [])
            |> Enum.map(fn {be, e, n} -> %{entry: e, membership: be, book_count: n} end)
            |> Enum.sort_by(&{-(&1.membership.order + book.order_adjustment), &1.entry.name})

          %{book: book, entries: entries}
        end),
      unlinked: unlinked
    }
  end

  @doc """
  Handles a lore tree drop: moves `entry_id` from `from_book_id` to `to_book_id` (`nil` = Unlinked),
  keeping the source membership too when `copy?`. `ordered_ids` is the target folder's rows top-first;
  it renumbers the target when it matches the folder's entries, else is ignored (a stale client) and a
  new membership keeps its top-of-book order. `{:error, :not_found}` when the entry or a book is gone
  or not editable by `scope`, `{:error, :unauthorized}` when the target book has another owner.
  """
  @spec place_entry(Scope.t(), term(), term(), term(), boolean(), list()) ::
          {:ok, :placed} | {:error, :not_found | :unauthorized | term()}
  def place_entry(%Scope{} = scope, entry_id, from_book_id, to_book_id, copy?, ordered_ids) when is_list(ordered_ids) do
    Repo.transaction(fn ->
      entry = fetch!(scope, LoreEntry, entry_id)
      from_id = from_book_id && fetch!(scope, LoreBook, from_book_id).id
      to_book = to_book_id && fetch!(scope, LoreBook, to_book_id)
      to_id = to_book && to_book.id

      if to_book && to_book.user_id != entry.user_id, do: Repo.rollback(:unauthorized)

      if to_id do
        if !Repo.get_by(BookEntry, lore_book_id: to_id, lore_entry_id: entry.id),
          do: insert_membership!(to_id, entry.id, nil)

        if !copy? and from_id not in [nil, to_id], do: delete_membership!(from_id, entry.id)

        ids = Enum.uniq(ordered_ids)
        if Enum.sort(ids) == Enum.sort(book_entry_ids(to_id)), do: renumber!(to_id, ids)
      else
        if !copy? and from_id, do: delete_membership!(from_id, entry.id)
      end

      :placed
    end)
    |> Changes.notify(:lore, book_owners([from_book_id, to_book_id]))
  end

  defp fetch!(scope, schema, id) do
    with {:ok, id} <- Ecto.UUID.cast(id), %{} = row <- Repo.get(Ownership.editable(schema, scope), id) do
      row
    else
      _ -> Repo.rollback(:not_found)
    end
  end

  defp delete_membership!(book_id, entry_id) do
    Repo.delete_all(from(be in BookEntry, where: be.lore_book_id == ^book_id and be.lore_entry_id == ^entry_id))
  end

  ## Pools

  @doc "Pools `scope` may edit, by name."
  def list_pools(%Scope{} = scope) do
    from(p in LorePool, order_by: [asc: p.name, asc: p.id], preload: [:pool_entries])
    |> Ownership.editable(scope)
    |> Repo.all()
  end

  @doc "A pool `scope` may edit, preloaded, or nil."
  def get_pool(%Scope{} = scope, id), do: fetch_owned(Ownership.editable(LorePool, scope), id, pool_entries: :entry)

  @doc "Creates a pool owned per `Ownership.new_owner/3`: `scope`'s own, or the site's with `site: true`."
  @spec create_pool(Scope.t(), map(), keyword()) :: {:ok, LorePool.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def create_pool(%Scope{} = scope, attrs \\ %{}, opts \\ []) do
    with {:ok, owner} <- Ownership.new_owner(scope, LorePool, opts) do
      %LorePool{user_id: owner}
      |> LorePool.changeset(attrs)
      |> Repo.insert()
      |> Changes.notify(:lore)
    end
  end

  @spec update_pool(Scope.t(), LorePool.t(), map()) ::
          {:ok, LorePool.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def update_pool(%Scope{} = scope, %LorePool{} = pool, attrs) do
    with :ok <- Ownership.authorize_edit(scope, pool) do
      pool
      |> LorePool.changeset(attrs)
      |> Repo.update()
      |> Changes.notify(:lore)
    end
  end

  @spec delete_pool(Scope.t(), LorePool.t()) :: {:ok, LorePool.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def delete_pool(%Scope{} = scope, %LorePool{} = pool) do
    with :ok <- Ownership.authorize_delete(scope, pool), do: pool |> Repo.delete() |> Changes.notify(:lore)
  end

  def change_pool(%LorePool{} = pool, attrs \\ %{}) do
    LorePool.changeset(pool, attrs)
  end

  @doc """
  Makes the entry's pool memberships exactly `pool_ids` plus those in pools `scope` cannot edit
  (kept); new rows take the default weight. Every requested pool must have the entry's owner, else
  `{:error, :unauthorized}`.
  """
  @spec set_entry_pools(Scope.t(), LoreEntry.t(), [Ecto.UUID.t()]) :: {:ok, :ok} | {:error, term()}
  def set_entry_pools(%Scope{} = scope, %LoreEntry{} = entry, pool_ids) when is_list(pool_ids) do
    with :ok <- Ownership.authorize_edit(scope, entry),
         :ok <- same_owner(LorePool, MapSet.new(pool_ids), entry.user_id) do
      Repo.transaction(fn ->
        existing = Repo.all(from(pe in PoolEntry, where: pe.lore_entry_id == ^entry.id))
        unseen = unseen(Enum.map(existing, & &1.lore_pool_id), Ownership.editable(LorePool, scope))

        Repo.sync_rows!(
          existing,
          :lore_pool_id,
          MapSet.new(pool_ids ++ unseen),
          &PoolEntry.changeset(%PoolEntry{}, %{lore_pool_id: &1, lore_entry_id: entry.id})
        )
      end)
      |> Changes.notify(:lore, entry.user_id)
    end
  end

  @doc """
  Updates the entry's memberships in the pools keyed in `settings` (`pool_id => %{weight:,
  override:, scored:}`, each key optional); pools the entry isn't in are ignored and unchanged rows
  aren't written. `{:error, :unauthorized}` unless `scope` may edit the entry.
  """
  @spec set_pool_memberships(Scope.t(), LoreEntry.t(), %{Ecto.UUID.t() => map()}) :: {:ok, :ok} | {:error, term()}
  def set_pool_memberships(%Scope{} = scope, %LoreEntry{} = entry, settings) when is_map(settings) do
    with :ok <- Ownership.authorize_edit(scope, entry) do
      Repo.transaction(fn ->
        rows =
          Repo.all(
            from(pe in PoolEntry, where: pe.lore_entry_id == ^entry.id and pe.lore_pool_id in ^Map.keys(settings))
          )

        for m <- rows,
            attrs = Map.fetch!(settings, m.lore_pool_id),
            Enum.any?(attrs, fn {k, v} -> Map.fetch!(m, k) != v end) do
          m
          |> PoolEntry.changeset(attrs)
          |> Repo.update()
          |> case do
            {:ok, _} -> :ok
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end

        :ok
      end)
      |> Changes.notify(:lore, entry.user_id)
    end
  end

  ## Bindings

  @doc """
  Binds `book` to a chat; `{:error, :unauthorized}` unless the chat's owner may use and see the book.
  """
  def bind_book_to_chat(%LoreBook{} = book, chat_id) do
    with %Chat{} = chat <- Repo.get(Chat, chat_id),
         true <- Ownership.reference_ok?(chat.user_id, book),
         true <- not Visibility.book_hidden?(book) or Visibility.view_hidden?(Visibility.owner_scope(chat.user_id)) do
      %BookChat{}
      |> BookChat.changeset(%{lore_book_id: book.id, chat_id: chat_id})
      |> Repo.insert()
      |> Changes.notify(:lore, book.user_id)
    else
      _ -> {:error, :unauthorized}
    end
  end

  def chat_book_ids(%Chat{} = chat) do
    Repo.all(from(bc in BookChat, where: bc.chat_id == ^chat.id, select: bc.lore_book_id))
  end

  @doc """
  Makes the chat's book bindings exactly `book_ids`; kept rows keep their `enabled` flag. Every book
  must be usable by the chat's owner, and every newly bound one visible to them, and, given `actor`
  (a chat editor), every newly bound one usable and visible to them too, else
  `{:error, :unauthorized}`. A book already bound stays bound even when hidden from the owner, so
  binding another book never fails over it.
  """
  def set_chat_books(%Chat{} = chat, book_ids, actor \\ nil) when is_list(book_ids) do
    wanted = MapSet.new(book_ids)
    added = MapSet.difference(wanted, MapSet.new(chat_book_ids(chat)))
    visible = Visibility.listed_books(LoreBook, Visibility.owner_scope(chat.user_id))

    with :ok <- all_in(Ownership.for_owner(LoreBook, chat.user_id), wanted),
         :ok <- all_in(visible, added),
         :ok <-
           if(actor,
             do: all_in(Visibility.listed_books(Ownership.usable(LoreBook, actor), actor), added),
             else: :ok
           ) do
      Repo.transaction(fn ->
        Repo.sync_rows!(
          Repo.all(from(bc in BookChat, where: bc.chat_id == ^chat.id)),
          :lore_book_id,
          wanted,
          &BookChat.changeset(%BookChat{}, %{lore_book_id: &1, chat_id: chat.id})
        )
      end)
      |> Changes.notify(:lore, chat.user_id)
    end
  end

  @doc "Binds `book` to a character; `{:error, :unauthorized}` unless the book's owner may reference it."
  def bind_book_to_character(%LoreBook{} = book, character_id) do
    with %Character{} = character <- Repo.get(Character, character_id),
         true <- Ownership.reference_ok?(book.user_id, character) do
      %BookCharacter{}
      |> BookCharacter.changeset(%{lore_book_id: book.id, character_id: character_id})
      |> Repo.insert()
      |> Changes.notify(:lore, book.user_id)
    else
      _ -> {:error, :unauthorized}
    end
  end

  @doc """
  Makes the book's bindings to the scope's own chats exactly those in `chat_ids`; kept rows keep their
  `enabled` flag. Bindings to chats the scope does not own are kept, and `chat_ids` it does not own
  are ignored, because the binding select only lists the scope's own chats (`Chats.chat_options/1`).
  A book `scope` may edit is the site's or its own, so its own chats may always use it.
  """
  @spec set_book_chats(Scope.t(), LoreBook.t(), [Ecto.UUID.t()]) :: {:ok, :ok} | {:error, term()}
  def set_book_chats(%Scope{} = scope, %LoreBook{} = book, chat_ids) when is_list(chat_ids) do
    with :ok <- Ownership.authorize_edit(scope, book) do
      Repo.transaction(fn ->
        existing = Repo.all(from(bc in BookChat, where: bc.lore_book_id == ^book.id))
        owned = MapSet.new(Repo.all(from(c in Chat, where: c.user_id == ^scope.user.id, select: c.id)))
        requested = Enum.filter(chat_ids, &MapSet.member?(owned, &1))
        unseen = for bc <- existing, not MapSet.member?(owned, bc.chat_id), do: bc.chat_id
        wanted = MapSet.new(requested ++ unseen)

        Repo.sync_rows!(
          existing,
          :chat_id,
          wanted,
          &BookChat.changeset(%BookChat{}, %{lore_book_id: book.id, chat_id: &1})
        )
      end)
      |> Changes.notify(:lore, book.user_id)
    end
  end

  @doc """
  Makes the book's character bindings exactly `character_ids` plus those to characters `scope` cannot
  use (kept, as the picker never lists them); kept rows keep their `enabled` flag. Every requested
  character must be one the book's owner may reference (a site book: site characters only).
  """
  @spec set_book_characters(Scope.t(), LoreBook.t(), [Ecto.UUID.t()]) :: {:ok, :ok} | {:error, term()}
  def set_book_characters(%Scope{} = scope, %LoreBook{} = book, character_ids) when is_list(character_ids) do
    with :ok <- Ownership.authorize_edit(scope, book),
         :ok <- all_in(Ownership.for_owner(Character, book.user_id), MapSet.new(character_ids)) do
      Repo.transaction(fn ->
        existing = Repo.all(from(bc in BookCharacter, where: bc.lore_book_id == ^book.id))
        unseen = unseen(Enum.map(existing, & &1.character_id), Ownership.usable(Character, scope))

        Repo.sync_rows!(
          existing,
          :character_id,
          MapSet.new(character_ids ++ unseen),
          &BookCharacter.changeset(%BookCharacter{}, %{lore_book_id: book.id, character_id: &1})
        )
      end)
      |> Changes.notify(:lore, book.user_id)
    end
  end

  @doc """
  Switches a binding on or off; needs edit rights on its book, and for a chat binding the chat
  (`Chats.authorize/3`'s `:manage`: its owner or a chat editor).
  """
  @spec set_binding_enabled(Scope.t(), BookChat.t() | BookCharacter.t(), boolean()) ::
          {:ok, BookChat.t() | BookCharacter.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def set_binding_enabled(%Scope{} = scope, %BookChat{} = binding, enabled?) do
    with :ok <- authorize_binding(scope, binding),
         do:
           binding
           |> BookChat.changeset(%{enabled: enabled?})
           |> Repo.update()
           |> Changes.notify(:lore, book_owners([binding.lore_book_id]))
  end

  def set_binding_enabled(%Scope{} = scope, %BookCharacter{} = binding, enabled?) do
    with :ok <- authorize_binding(scope, binding),
         do:
           binding
           |> BookCharacter.changeset(%{enabled: enabled?})
           |> Repo.update()
           |> Changes.notify(:lore, book_owners([binding.lore_book_id]))
  end

  defp authorize_binding(scope, %BookChat{chat_id: chat_id} = binding) do
    with :ok <- Chats.authorize(scope, chat_id, :manage), do: authorize_book(scope, binding)
  end

  defp authorize_binding(scope, binding), do: authorize_book(scope, binding)

  defp authorize_book(scope, %{lore_book_id: book_id}),
    do: Ownership.authorize_edit(scope, Repo.get!(LoreBook, book_id))

  # Owners of the given books, for broadcasting changes to them. Nil and malformed ids are dropped.
  defp book_owners(book_ids) do
    ids = for id <- book_ids, {:ok, id} <- [Ecto.UUID.cast(id)], uniq: true, do: id
    Repo.all(from(b in LoreBook, where: b.id in ^ids, distinct: true, select: b.user_id))
  end

  @doc "A binding of a book `scope` may edit to one of `scope`'s own chats, or nil."
  def get_book_chat(%Scope{user: %{id: uid}} = scope, id) do
    with %BookChat{} = binding <- get_binding(scope, BookChat, id),
         %Chat{user_id: ^uid} <- Repo.get(Chat, binding.chat_id) do
      binding
    else
      _ -> nil
    end
  end

  @doc "A character binding of a book `scope` may edit, or nil."
  def get_book_character(%Scope{} = scope, id), do: get_binding(scope, BookCharacter, id)

  defp get_binding(scope, schema, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        Repo.one(
          from(bc in schema,
            where:
              bc.id == ^id and
                bc.lore_book_id in (LoreBook |> Ownership.editable(scope) |> select([b], b.id) |> subquery())
          )
        )

      _ ->
        nil
    end
  end

  @doc """
  Books live in `chat`: books usable by the chat's owner (`Ownership.for_owner/2`) that are forced or
  global (forced site books join every chat whatever its bindings),
  bound-and-enabled to the chat, bound-and-enabled to a character the reply sees, the chat's own
  character memory book choice (`chat_memory_settings.character_book_ids`) for such a character, or
  the chat owner's character memory book lock (`Mythweaver.Memory.CharacterBook`) of such a
  character. `character_ids` lists those (`Chat.card_character_ids/2`, per the chat's Group cards
  setting); `:participants`, the default, is every participant. Another user's book never applies,
  even bound to a site character. Hidden lore is included: user visibility limits what non-admins
  see of a book, not what generation sends.
  """
  def books_for_chat(%Chat{} = chat, character_ids \\ :participants) do
    chat_bound = from(bc in BookChat, where: bc.chat_id == ^chat.id and bc.enabled, select: bc.lore_book_id)
    char_bound = character_bound(chat, character_ids)
    locked = character_locked(chat, character_ids)
    chosen = character_chosen(chat, character_ids)

    from(b in LoreBook,
      where:
        b.forced or b.global or b.id in subquery(chat_bound) or b.id in subquery(char_bound) or
          b.id in subquery(locked) or b.id in ^chosen,
      distinct: true,
      order_by: [asc: b.name, asc: b.id]
    )
    |> Ownership.for_owner(chat.user_id)
    |> Repo.all()
  end

  @doc """
  The ids of the books `books_for_chat/2` applies in `chat` through `character_id` itself: bound and
  enabled to the character, its memory book lock, or the chat's character memory book choice for it.
  Global and chat-bound books are not the character's, though one may also be among these.
  """
  @spec character_book_ids(Chat.t(), Ecto.UUID.t()) :: MapSet.t(Ecto.UUID.t())
  def character_book_ids(%Chat{} = chat, character_id) do
    bound = character_bound(chat, [character_id])
    locked = character_locked(chat, [character_id])

    from(b in LoreBook, where: b.id in subquery(bound) or b.id in subquery(locked), select: b.id)
    |> Repo.all()
    |> Enum.concat(character_chosen(chat, [character_id]))
    |> MapSet.new()
  end

  defp character_bound(chat, :participants) do
    from(bc in BookCharacter,
      join: p in Participant,
      on: p.character_id == bc.character_id,
      where: p.chat_id == ^chat.id and bc.enabled,
      select: bc.lore_book_id
    )
  end

  defp character_bound(_chat, character_ids) when is_list(character_ids) do
    from(bc in BookCharacter, where: bc.character_id in ^character_ids and bc.enabled, select: bc.lore_book_id)
  end

  # An unowned chat has no owner's locks.
  defp character_locked(%Chat{user_id: nil}, _character_ids),
    do: from(l in CharacterBook, where: false, select: l.lore_book_id)

  defp character_locked(chat, :participants) do
    from(l in CharacterBook,
      join: p in Participant,
      on: p.character_id == l.character_id,
      where: p.chat_id == ^chat.id and l.user_id == ^chat.user_id,
      select: l.lore_book_id
    )
  end

  defp character_locked(chat, character_ids) when is_list(character_ids) do
    from(l in CharacterBook,
      where: l.character_id in ^character_ids and l.user_id == ^chat.user_id,
      select: l.lore_book_id
    )
  end

  # The chat's per-chat character memory books of the characters (`Mythweaver.Memory.ChatSettings`).
  defp character_chosen(%Chat{user_id: nil}, _character_ids), do: []

  defp character_chosen(chat, character_ids) do
    chosen =
      Repo.one(from(s in ChatSettings, where: s.chat_id == ^chat.id, select: s.character_book_ids)) || %{}

    characters =
      case character_ids do
        :participants -> Repo.all(from(p in Participant, where: p.chat_id == ^chat.id, select: p.character_id))
        ids when is_list(ids) -> ids
      end

    for {character_id, book_id} <- chosen, character_id in characters, {:ok, id} <- [Ecto.UUID.cast(book_id)], do: id
  end

  @doc """
  Makes the entry's character filter exactly `character_ids` plus characters `scope` cannot use
  (kept). Every requested character must be one the entry's owner may reference, else
  `{:error, :unauthorized}`.
  """
  @spec set_entry_filter_characters(Scope.t(), LoreEntry.t(), [Ecto.UUID.t()]) :: {:ok, :ok} | {:error, term()}
  def set_entry_filter_characters(%Scope{} = scope, %LoreEntry{} = entry, character_ids) when is_list(character_ids) do
    with :ok <- Ownership.authorize_edit(scope, entry),
         :ok <- all_in(Ownership.for_owner(Character, entry.user_id), MapSet.new(character_ids)) do
      Repo.transaction(fn ->
        existing = Repo.all(from(ec in EntryCharacter, where: ec.lore_entry_id == ^entry.id))
        unseen = unseen(Enum.map(existing, & &1.character_id), Ownership.usable(Character, scope))

        Repo.sync_rows!(
          existing,
          :character_id,
          MapSet.new(character_ids ++ unseen),
          &EntryCharacter.changeset(%EntryCharacter{}, %{lore_entry_id: entry.id, character_id: &1})
        )
      end)
      |> Changes.notify(:lore, entry.user_id)
    end
  end

  @doc """
  Makes the entry's tag filter exactly `texts`, as tags of the entry's own domain (created when
  missing, which needs the matching create permission).
  """
  @spec set_entry_filter_tags(Scope.t(), LoreEntry.t(), [String.t()]) :: {:ok, :ok} | {:error, term()}
  def set_entry_filter_tags(%Scope{} = scope, %LoreEntry{} = entry, texts) when is_list(texts) do
    with :ok <- Ownership.authorize_edit(scope, entry),
         {:ok, tags} <- Tags.ensure_tags(scope, entry.user_id, texts) do
      Repo.transaction(fn ->
        Repo.sync_rows!(
          Repo.all(from(ef in EntryFilterTag, where: ef.lore_entry_id == ^entry.id)),
          :tag_id,
          MapSet.new(tags, & &1.id),
          &EntryFilterTag.changeset(%EntryFilterTag{}, %{lore_entry_id: entry.id, tag_id: &1})
        )
      end)
      |> Changes.notify(:lore, entry.user_id)
    end
  end

  @doc """
  Makes the book's tag filter exactly `texts`, as tags of the book's own domain (created when
  missing, which needs the matching create permission).
  """
  @spec set_book_filter_tags(Scope.t(), LoreBook.t(), [String.t()]) :: {:ok, :ok} | {:error, term()}
  def set_book_filter_tags(%Scope{} = scope, %LoreBook{} = book, texts) when is_list(texts) do
    with :ok <- Ownership.authorize_edit(scope, book),
         {:ok, tags} <- Tags.ensure_tags(scope, book.user_id, texts) do
      Repo.transaction(fn ->
        Repo.sync_rows!(
          Repo.all(from(bf in BookFilterTag, where: bf.lore_book_id == ^book.id)),
          :tag_id,
          MapSet.new(tags, & &1.id),
          &BookFilterTag.changeset(%BookFilterTag{}, %{lore_book_id: book.id, tag_id: &1})
        )
      end)
      |> Changes.notify(:lore, book.user_id)
    end
  end

  ## Activation rules

  @doc """
  A changeset over `book`'s activation rules (`LoreBook.rules_changeset/3`) for the editor form;
  references are checked only on save (`set_book_rules/3`).
  """
  @spec change_book_rules(LoreBook.t(), map()) :: Ecto.Changeset.t()
  def change_book_rules(%LoreBook{} = book, attrs \\ %{}) do
    LoreBook.rules_changeset(Repo.preload(book, rules: :conditions), attrs, %{chats: :any, characters: :any})
  end

  @doc """
  Replaces `book`'s activation rules from nested `rules` params. A condition may name only the book
  owner's chats (none for a site book: chats are always personal) and characters the owner may
  reference (a site book: site characters), as `set_book_characters/3` does.
  """
  @spec set_book_rules(Scope.t(), LoreBook.t(), map()) ::
          {:ok, LoreBook.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def set_book_rules(%Scope{} = scope, %LoreBook{} = book, attrs) do
    with :ok <- Ownership.authorize_edit(scope, book) do
      book = Repo.preload(book, [rules: :conditions], force: true)
      chat_ids = rule_ref_ids(attrs, "chat_id")

      chats =
        case book.user_id do
          nil ->
            MapSet.new()

          owner ->
            MapSet.new(Repo.all(from(c in Chat, where: c.user_id == ^owner and c.id in ^chat_ids, select: c.id)))
        end

      characters =
        Character
        |> Ownership.for_owner(book.user_id)
        |> where([c], c.id in ^rule_ref_ids(attrs, "character_id"))
        |> select([c], c.id)
        |> Repo.all()
        |> MapSet.new()

      book
      |> LoreBook.rules_changeset(attrs, %{chats: chats, characters: characters})
      |> Repo.update()
      |> Changes.notify(:lore, book.user_id)
    end
  end

  @doc """
  `{name, id}` for every character a rule condition on `book` may name (those `set_book_rules/3`
  accepts), ordered by name.
  """
  @spec rule_character_options(LoreBook.t()) :: [{String.t(), Ecto.UUID.t()}]
  def rule_character_options(%LoreBook{} = book) do
    Character
    |> Ownership.for_owner(book.user_id)
    |> order_by([c], asc: c.name)
    |> select([c], {c.name, c.id})
    |> Repo.all()
  end

  # The castable ids the submitted conditions name in `field` (only those need an ownership check).
  defp rule_ref_ids(attrs, field) do
    for {_i, rule} <- index_map(attrs["rules"]),
        {_j, condition} <- index_map(is_map(rule) && rule["conditions"]),
        is_map(condition),
        {:ok, id} <- [Ecto.UUID.cast(condition[field] || "")],
        uniq: true,
        do: id
  end

  defp index_map(map) when is_map(map), do: map
  defp index_map(_other), do: %{}

  ## Turn state (sticky / cooldown)

  @doc "Per-chat activation state, keyed by lore entry id."
  def entry_states(%Chat{} = chat) do
    from(s in EntryState, where: s.chat_id == ^chat.id)
    |> Repo.all()
    |> Map.new(&{&1.lore_entry_id, &1})
  end

  @doc """
  Records that `entries` activated in `chat` at `message_count` (non-draft message count), so
  sticky and cooldown can be honoured on later turns.
  """
  def record_activations(%Chat{} = chat, entries, message_count) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      Enum.map(entries, fn entry ->
        # A non-sticky entry gets no sticky horizon: writing `message_count + 0` would report the
        # entry as `:sticky` on the very next resolve at the same count. Cooldown still runs from
        # the end of the sticky window, which for a non-sticky entry is this turn.
        sticky = entry.sticky || 0

        %{
          id: Schema.generate_id(),
          chat_id: chat.id,
          lore_entry_id: entry.id,
          sticky_until: if(entry.sticky, do: message_count + sticky),
          cooldown_until: message_count + sticky + (entry.cooldown || 0),
          last_activated_at_count: message_count,
          inserted_at: now,
          updated_at: now
        }
      end)

    if rows != [] do
      Repo.insert_all(EntryState, rows,
        on_conflict: {:replace, [:sticky_until, :cooldown_until, :last_activated_at_count, :updated_at]},
        conflict_target: [:chat_id, :lore_entry_id]
      )
    end

    :ok
  end

  # `:ok` when every id in `ids` is a row of `query`, else `{:error, :unauthorized}`.
  defp all_in(query, ids) do
    ids = Enum.to_list(ids)

    with true <- Enum.all?(ids, &match?({:ok, _}, Ecto.UUID.cast(&1))),
         n when n == length(ids) <- Repo.aggregate(where(query, [r], r.id in ^ids), :count) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  # The ids among `ids` that `visible` does not return: rows `scope` cannot see, which an exact-set
  # write keeps because its picker never lists them.
  defp unseen(ids, visible) do
    seen = MapSet.new(Repo.all(from(r in visible, where: r.id in ^ids, select: r.id)))
    Enum.reject(ids, &MapSet.member?(seen, &1))
  end
end
