defmodule Mythweaver.Sharing.Visibility do
  @moduledoc """
  The one rule for hidden site content.

  A site row's `site_visibility` says what users without `site.hidden.view` may see of it. Every
  shareable type has `:readable` (everything) and `:runtime_only` (names, never the protected
  content, which still reaches the model); lore books also have `:hidden` (nothing at all). Personal
  rows are always `:readable`.

  A row whose content is hidden is *protected*: `Mythweaver.Prompts.Builder` hands templates a
  placeholder token (`Mythweaver.Sharing.Protected`) instead of its text. A `forced` lore book is
  protected too.

  A share adds an owner-relative rule (`share_protected?/2`): a personal row reached only through
  Runtime-only share grants is protected for that user, and no permission reveals it.

  `view_hidden?/1` is the only role check; every "may this scope see hidden content" decision goes
  through it.
  """

  import Ecto.Query

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.Lore.BookEntry
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Repo
  alias Mythweaver.Sharing

  @doc "Whether `scope` may see hidden books and hidden content."
  @spec view_hidden?(Scope.t() | nil) :: boolean()
  def view_hidden?(scope), do: Scope.can?(scope, "site.hidden.view")

  @doc "Whether `row` (any struct with `site_visibility` and `user_id`) is a site row whose content is hidden."
  @spec content_hidden?(struct()) :: boolean()
  def content_hidden?(%{site_visibility: visibility, user_id: nil}), do: visibility != :readable
  def content_hidden?(%{site_visibility: _, user_id: _}), do: false

  @doc "Whether users without `site.hidden.view` may not see `book` at all."
  @spec book_hidden?(LoreBook.t()) :: boolean()
  def book_hidden?(%LoreBook{} = book), do: book.site_visibility == :hidden

  @doc """
  Whether templates see a placeholder token rather than `row`'s protected text: a lore book that is
  `forced` or content-hidden, or any other content-hidden row.
  """
  @spec protected?(struct()) :: boolean()
  def protected?(%LoreBook{} = book), do: book.forced or content_hidden?(book)
  def protected?(row), do: content_hidden?(row)

  @doc """
  Whether `row` is share-protected for the chat owner `owner_id`: a personal row not theirs, which
  they reach only through Runtime-only grants (`Mythweaver.Sharing.readable?/2`). False for site
  rows and for a nil `owner_id` (no viewer).
  """
  @spec share_protected?(struct(), Ecto.UUID.t() | nil) :: boolean()
  def share_protected?(%{user_id: nil}, _owner_id), do: false
  def share_protected?(_row, nil), do: false
  def share_protected?(%{user_id: owner_id}, owner_id), do: false
  def share_protected?(%{user_id: _} = row, owner_id), do: not Sharing.readable?(owner_id, row)
  def share_protected?(_row, _owner_id), do: false

  @doc "Whether templates of `owner_id`'s chat see a placeholder for `row`: `protected?/1` or `share_protected?/2`."
  @spec protected_for?(struct(), Ecto.UUID.t() | nil) :: boolean()
  def protected_for?(row, owner_id), do: protected?(row) or share_protected?(row, owner_id)

  @doc """
  Whether `scope` may not read `row`'s protected content: site-hidden and `scope` lacks
  `site.hidden.view`, or share-protected for the scope user (no permission reveals that).
  """
  @spec content_hidden_for?(Scope.t() | nil, struct()) :: boolean()
  def content_hidden_for?(scope, row),
    do: (content_hidden?(row) and not view_hidden?(scope)) or share_protected?(row, user_id(scope))

  @doc """
  Whether `scope` may not read `block`'s content in the context of `prompt` (nil for none): the block
  or the prompt is content-hidden and `scope` lacks `site.hidden.view`, or either is share-protected
  for the scope user. A nil scope has no permission and no share rule.
  """
  @spec block_hidden_for?(Scope.t() | nil, struct(), struct() | nil) :: boolean()
  def block_hidden_for?(scope, block, prompt) do
    uid = user_id(scope)

    ((content_hidden?(block) or (prompt != nil and content_hidden?(prompt))) and not view_hidden?(scope)) or
      share_protected?(block, uid) or (prompt != nil and share_protected?(prompt, uid))
  end

  @doc "`query` over `LoreBook` narrowed to the books `scope` may see."
  @spec listed_books(Ecto.Queryable.t(), Scope.t() | nil) :: Ecto.Query.t()
  def listed_books(query, scope) do
    if view_hidden?(scope),
      do: from(b in query),
      else: where(query, [b], b.site_visibility != :hidden)
  end

  @doc "`query` over `LoreEntry` minus entries in a book `scope` may not see."
  @spec listed_entries(Ecto.Queryable.t(), Scope.t() | nil) :: Ecto.Query.t()
  def listed_entries(query, scope) do
    if view_hidden?(scope),
      do: from(e in query),
      else: where(query, [e], e.id not in subquery(entries_in(:hidden)))
  end

  @doc """
  `query` over `LoreEntry` narrowed to the entries whose content `scope` may read: minus entries of
  content-hidden site books (unless `site.hidden.view`) and personal entries of others the scope user
  reaches only through Runtime-only grants.
  """
  @spec readable_entries(Ecto.Queryable.t(), Scope.t() | nil) :: Ecto.Query.t()
  def readable_entries(query, scope) do
    query =
      if view_hidden?(scope),
        do: from(e in query),
        else: where(query, [e], e.id not in subquery(entries_in(:not_readable)))

    case user_id(scope) do
      nil ->
        query

      uid ->
        where(
          query,
          [e],
          is_nil(e.user_id) or e.user_id == ^uid or e.id in subquery(Sharing.readable_ids(uid, :lore_entry))
        )
    end
  end

  @doc """
  Whether `scope` may not read `entry`'s content: it belongs to a content-hidden book (and `scope`
  lacks `site.hidden.view`), or it is share-protected for the scope user.
  """
  @spec entry_content_hidden_for?(Scope.t() | nil, LoreEntry.t()) :: boolean()
  def entry_content_hidden_for?(scope, %LoreEntry{id: id} = entry) do
    (not view_hidden?(scope) and Repo.exists?(where(entries_in(:not_readable), [be], be.lore_entry_id == ^id))) or
      share_protected?(entry, user_id(scope))
  end

  defp user_id(%Scope{user: %User{id: id}}), do: id
  defp user_id(_scope), do: nil

  @doc "The scope of the user with `user_id` (a userless scope for nil), where only an id is known."
  @spec owner_scope(Ecto.UUID.t() | nil) :: Scope.t()
  def owner_scope(nil), do: %Scope{}
  def owner_scope(user_id), do: Scope.for_user(Repo.get!(User, user_id))

  defp entries_in(:hidden) do
    from(be in BookEntry,
      join: b in LoreBook,
      on: b.id == be.lore_book_id,
      where: b.site_visibility == :hidden,
      select: be.lore_entry_id
    )
  end

  defp entries_in(:not_readable) do
    from(be in BookEntry,
      join: b in LoreBook,
      on: b.id == be.lore_book_id,
      where: b.site_visibility != :readable,
      select: be.lore_entry_id
    )
  end
end
