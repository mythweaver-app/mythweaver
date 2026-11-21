defmodule Mythweaver.Scripts.API.Lore do
  @moduledoc """
  `mw.lore.*`: lore books, their entries, per-book entry switches, and chat bindings.

  Reads see books and entries the script's scope may use (its own and the site's); writes go through
  `Mythweaver.Lore`'s ownership checks, and binding a book to the chat needs the chat's owner to be
  able to use it.
  """

  use Gettext, backend: Mythweaver.Gettext

  import Mythweaver.Scripts.API.Convert

  alias Mythweaver.Lore
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Sharing.Visibility

  @book_fields [
    :id,
    :name,
    :description,
    :global,
    :priority,
    :order_adjustment,
    :token_budget,
    :scan_depth,
    :recursive,
    :site_visibility,
    :forced
  ]

  @functions %{
    books: {"mw.lore.books()", dgettext_noop("scripts", "Every lore book you may use.")},
    book: {"mw.lore.book(id)", dgettext_noop("scripts", "The lore book with this id, with its entries.")},
    create_book:
      {"mw.lore.create_book(fields)",
       dgettext_noop("scripts", ~s(Creates a book from fields such as {name = "Places"}; returns it.))},
    update_book:
      {"mw.lore.update_book(id, fields)", dgettext_noop("scripts", "Updates the book's given fields; returns it.")},
    delete_book:
      {"mw.lore.delete_book(id)",
       dgettext_noop("scripts", "Deletes the book; entries in no other book become unlinked. Returns true.")},
    create_entry:
      {"mw.lore.create_entry(book_id, fields)",
       dgettext_noop(
         "scripts",
         "Creates an entry in the book from fields such as {name, content, keywords}; returns it."
       )},
    update_entry:
      {"mw.lore.update_entry(id, fields)", dgettext_noop("scripts", "Updates the entry's given fields; returns it.")},
    delete_entry:
      {"mw.lore.delete_entry(id)", dgettext_noop("scripts", "Deletes the entry from every book; returns true.")},
    set_entry_enabled:
      {"mw.lore.set_entry_enabled(book_id, entry_id, enabled)",
       dgettext_noop("scripts", "Turns an entry on or off within this book only; returns true.")},
    set_chat_bound:
      {"mw.lore.set_chat_bound(book_id, bound)",
       dgettext_noop("scripts", "Binds the book to the current chat, or unbinds it; returns true.")}
  }

  @usage Map.new(@functions, fn {name, {signature, _info}} -> {name, signature} end)

  @doc "The installed functions' signatures and descriptions, by name."
  def functions, do: @functions

  def install(lua, ctx), do: install_functions(lua, [:mw, :lore], @functions, &call(&1, ctx, &2, &3))

  def book_table(%LoreBook{} = book), do: Map.take(book, @book_fields)

  @doc """
  An entry's Lua table. `book_id`, `enabled` and `order` come from its membership in `book_id`, or
  from its only membership when no book is given; otherwise they are `nil`. `hide_content?` blanks
  `content` and `keywords`, for a reader who may not see the book's content.
  """
  def entry_table(%LoreEntry{} = entry, book_id \\ nil, hide_content? \\ false) do
    membership =
      case {book_id, entry.book_entries} do
        {nil, [only]} -> only
        {nil, _} -> nil
        {book_id, memberships} -> Enum.find(memberships, &(&1.lore_book_id == book_id))
      end

    %{
      id: entry.id,
      name: entry.name,
      content: if(!hide_content?, do: entry.content),
      keywords: if(!hide_content?, do: entry.keywords),
      activation: entry.activation,
      book_id: membership && membership.lore_book_id,
      enabled: membership && membership.enabled,
      order: membership && membership.order
    }
  end

  defp call(:books, ctx, [], state), do: ok(state, Enum.map(Lore.list_usable_books(ctx.scope), &book_table/1))

  defp call(:book, ctx, [id], state) when is_binary(id) do
    with_book(ctx, id, state, fn book ->
      hide? = Visibility.content_hidden_for?(ctx.scope, book)
      entries = Lore.list_entries_in_book(ctx.scope, book) |> Enum.map(&entry_table(&1, book.id, hide?))
      ok(state, Map.put(book_table(book), :entries, entries))
    end)
  end

  defp call(:create_book, ctx, [fields], state) do
    attrs = fields!(state, fields, @usage.create_book)
    ctx.scope |> Lore.create_book(attrs) |> reply(state, &book_table/1)
  end

  defp call(:update_book, ctx, [id, fields], state) when is_binary(id) do
    attrs = fields!(state, fields, @usage.update_book)

    with_book(ctx, id, state, fn book ->
      ctx.scope |> Lore.update_book(book, attrs) |> reply(state, &book_table/1)
    end)
  end

  defp call(:delete_book, ctx, [id], state) when is_binary(id) do
    with_book(ctx, id, state, &(Lore.delete_book(ctx.scope, &1) |> reply(state, fn _ -> true end)))
  end

  defp call(:create_entry, ctx, [book_id, fields], state) when is_binary(book_id) do
    attrs = fields!(state, fields, @usage.create_entry)

    with_book(ctx, book_id, state, fn book ->
      ctx.scope |> Lore.create_entry(attrs, [book.id]) |> reply(state, &entry_table(&1, book.id))
    end)
  end

  defp call(:update_entry, ctx, [id, fields], state) when is_binary(id) do
    attrs = fields!(state, fields, @usage.update_entry)

    with_entry(ctx, id, state, fn entry ->
      ctx.scope
      |> Lore.update_entry(entry, attrs)
      |> reply(state, &entry_table(%{&1 | book_entries: entry.book_entries}))
    end)
  end

  defp call(:delete_entry, ctx, [id], state) when is_binary(id) do
    with_entry(ctx, id, state, &(Lore.delete_entry(ctx.scope, &1) |> reply(state, fn _ -> true end)))
  end

  defp call(:set_entry_enabled, ctx, [book_id, entry_id, enabled?], state)
       when is_binary(book_id) and is_binary(entry_id) and is_boolean(enabled?) do
    with_book(ctx, book_id, state, fn book ->
      ctx.scope |> Lore.set_membership_enabled(book, entry_id, enabled?) |> reply(state, fn _ -> true end)
    end)
  end

  defp call(:set_chat_bound, ctx, [book_id, bound?], state) when is_binary(book_id) and is_boolean(bound?) do
    with_book(ctx, book_id, state, fn book ->
      ids = Lore.chat_book_ids(ctx.chat) -- [book.id]
      ids = if bound?, do: [book.id | ids], else: ids
      ctx.chat |> Lore.set_chat_books(ids) |> reply(state, fn _ -> true end)
    end)
  end

  defp call(name, _ctx, _args, _state), do: usage!(@usage[name])

  defp with_book(ctx, id, state, fun) do
    case fetch(id, &Lore.get_book(ctx.scope, &1)) do
      nil -> refuse(state, :not_found)
      book -> fun.(book)
    end
  end

  defp with_entry(ctx, id, state, fun) do
    case fetch(id, &Lore.get_entry(ctx.scope, &1)) do
      nil -> refuse(state, :not_found)
      entry -> fun.(entry)
    end
  end
end
