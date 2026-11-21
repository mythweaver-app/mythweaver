defmodule Mythweaver.Lore.Transfer do
  @moduledoc """
  Moves a user's lore book to the site (`user_id` nil), taking its entries along.

  `Mythweaver.Ownership` lets a row reference only site rows or rows of its own owner, so a move
  breaks every link a site row may not hold. Nothing re-validates those links later, so the move
  removes them in the same transaction:

    * the entries' memberships in other books and in pools (those keep the old owner), and their
      character filters on personal characters;
    * entry and book tag filters naming personal tags;
    * bindings to personal characters;
    * activation rule conditions naming a chat (chats are always personal) or a personal
      character, which lose their target;
    * side prompts of any user that write into it (a side prompt writes only into a book of its own
      owner).

  The book loses its shares (`Mythweaver.Sharing.drop_all/2`): every account may use it now, so it
  strands no chat, and every tagging stays (anyone who sees a site item may tag it). `impact/2`
  counts each kind before the move, so the editor can warn about it. Memory records keep pointing at
  their entries, which move with the book.

  With `clear_memory_of: user_id` the move also clears that user's memory settings, character locks
  and topic suggestions naming the book, for a user who cannot edit site books (an admin moving a
  user's book to the site from `Mythweaver.Accounts.UserData`).

  `Mythweaver.Lore.transfer_book/3` and `Mythweaver.Accounts.UserData.move_book_to_site/3` are the
  authorized entry points.
  """

  import Ecto.Query

  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Lore.BookCharacter
  alias Mythweaver.Lore.BookEntry
  alias Mythweaver.Lore.BookFilterTag
  alias Mythweaver.Lore.BookRule
  alias Mythweaver.Lore.BookRuleCondition
  alias Mythweaver.Lore.EntryCharacter
  alias Mythweaver.Lore.EntryFilterTag
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Lore.PoolEntry
  alias Mythweaver.Memory.CharacterBook
  alias Mythweaver.Memory.ChatSettings
  alias Mythweaver.Memory.SidePrompt
  alias Mythweaver.Memory.TopicSuggestion
  alias Mythweaver.Repo
  alias Mythweaver.Tags.Tag

  @typedoc "How many rows of each kind a move changes or removes."
  @type impact :: %{
          entries: non_neg_integer(),
          other_books: non_neg_integer(),
          pools: non_neg_integer(),
          entry_filters: non_neg_integer(),
          character_bindings: non_neg_integer(),
          memory_settings: non_neg_integer(),
          character_locks: non_neg_integer(),
          side_prompts: non_neg_integer(),
          topic_suggestions: non_neg_integer(),
          tag_filters: non_neg_integer(),
          book_tag_filters: non_neg_integer(),
          rule_chats: non_neg_integer(),
          rule_characters: non_neg_integer()
        }

  @doc "What moving `book` to the site would change, by kind. `opts` as `run/2`."
  @spec impact(LoreBook.t(), keyword()) :: impact()
  def impact(%LoreBook{} = book, opts \\ []) do
    book
    |> fallout(opts[:clear_memory_of])
    |> Map.new(fn {kind, query, _action} -> {kind, Repo.aggregate(query, :count)} end)
  end

  @doc """
  Moves `book` and its entries to the site, removing every link the site may not hold. Returns the
  moved book. `opts`: `:clear_memory_of` (see the moduledoc).
  """
  @spec run(LoreBook.t(), keyword()) :: {:ok, LoreBook.t()} | {:error, term()}
  def run(%LoreBook{} = book, opts \\ []) do
    Repo.transact(fn ->
      :ok = Mythweaver.Sharing.drop_all(:lore_book, book.id)

      # Links are found through the book's memberships and the entries' current owner, so they go
      # before the entries and the book move.
      for {_kind, query, action} <- fallout(book, opts[:clear_memory_of]), do: apply_action(query, action)

      {1, [moved]} = Repo.update_all(from(b in LoreBook, where: b.id == ^book.id, select: b), set: [user_id: nil])
      {:ok, moved}
    end)
  end

  # `{kind, query, action}` per kind of row the move touches. The entries' own move (`:entries`)
  # comes last: the other queries find the book's entries through its memberships, which stay.
  defp fallout(%LoreBook{id: id}, clear) do
    entry_ids = from(be in BookEntry, where: be.lore_book_id == ^id, select: be.lore_entry_id)
    entries = Repo.all(entry_ids)

    [
      {:other_books, from(be in BookEntry, where: be.lore_entry_id in subquery(entry_ids) and be.lore_book_id != ^id),
       :delete},
      {:pools, from(pe in PoolEntry, where: pe.lore_entry_id in subquery(entry_ids)), :delete},
      {:entry_filters,
       from(ec in EntryCharacter,
         join: c in Character,
         on: c.id == ec.character_id,
         where: ec.lore_entry_id in subquery(entry_ids) and not is_nil(c.user_id)
       ), :delete},
      {:character_bindings,
       from(bc in BookCharacter,
         join: c in Character,
         on: c.id == bc.character_id,
         where: bc.lore_book_id == ^id and not is_nil(c.user_id)
       ), :delete},
      # A site book is every chat's to use, so only `clear`'s memory references go.
      {:memory_settings, of_clear(settings_naming(id, entries), clear), {:memory_settings, id, entries}},
      {:character_locks, locks_of(id, clear), :delete},
      {:topic_suggestions, of_clear(from(t in TopicSuggestion, where: t.lore_book_id == ^id), clear), :delete},
      {:side_prompts, from(s in SidePrompt, where: s.target_book_id == ^id and not is_nil(s.user_id)),
       {:set, target_book_id: nil}},
      {:tag_filters,
       from(ef in EntryFilterTag,
         join: t in Tag,
         on: t.id == ef.tag_id,
         where: ef.lore_entry_id in subquery(entry_ids) and not is_nil(t.user_id)
       ), :delete},
      {:book_tag_filters,
       from(bf in BookFilterTag,
         join: t in Tag,
         on: t.id == bf.tag_id,
         where: bf.lore_book_id == ^id and not is_nil(t.user_id)
       ), :delete},
      {:rule_chats, from(rc in rule_conditions(id), where: not is_nil(rc.chat_id)), {:set, chat_id: nil}},
      {:rule_characters,
       from(rc in rule_conditions(id),
         where: rc.character_id in subquery(from(c in Character, where: not is_nil(c.user_id), select: c.id))
       ), {:set, character_id: nil}},
      {:entries, from(e in LoreEntry, where: e.id in subquery(entry_ids)), {:set, user_id: nil}}
    ]
  end

  # The book's activation rule conditions. A subquery, not a join, so `update_all` stays plain.
  defp rule_conditions(id) do
    from(rc in BookRuleCondition,
      where: rc.lore_book_rule_id in subquery(from(r in BookRule, where: r.lore_book_id == ^id, select: r.id))
    )
  end

  # Rows of chat-bound `query` (a `chat_id` field) in `clear`'s chats; none without `clear`.
  defp of_clear(query, nil), do: where(query, false)
  defp of_clear(query, clear), do: from(r in query, join: c in Chat, on: c.id == r.chat_id, where: c.user_id == ^clear)

  # Memory settings naming the book (as the chat's memory book, or a side prompt's or character's) or
  # one of its entries as Additional Context.
  defp settings_naming(id, entries) do
    from(s in ChatSettings,
      where:
        s.memory_book_id == ^id or
          fragment("EXISTS (SELECT 1 FROM jsonb_each_text(?) AS v WHERE v.value = ?)", s.side_prompt_book_ids, ^id) or
          fragment("EXISTS (SELECT 1 FROM jsonb_each_text(?) AS v WHERE v.value = ?)", s.character_book_ids, ^id) or
          fragment("? && ?", s.context_entry_ids, type(^entries, {:array, Ecto.UUID}))
    )
  end

  defp locks_of(_id, nil), do: where(CharacterBook, false)
  defp locks_of(id, clear), do: from(l in CharacterBook, where: l.lore_book_id == ^id and l.user_id == ^clear)

  defp apply_action(query, :delete), do: Repo.delete_all(query)
  defp apply_action(query, {:set, set}), do: Repo.update_all(query, set: set)

  defp apply_action(query, {:memory_settings, id, entries}) do
    for settings <- Repo.all(query) do
      Repo.update_all(from(s in ChatSettings, where: s.id == ^settings.id),
        set: [
          memory_book_id: if(settings.memory_book_id != id, do: settings.memory_book_id),
          side_prompt_book_ids: reject_value(settings.side_prompt_book_ids, id),
          character_book_ids: reject_value(settings.character_book_ids, id),
          context_entry_ids: settings.context_entry_ids -- entries
        ]
      )
    end
  end

  defp reject_value(map, id), do: map |> Enum.reject(fn {_key, value} -> value == id end) |> Map.new()
end
