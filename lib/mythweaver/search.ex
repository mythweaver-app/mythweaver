defmodule Mythweaver.Search do
  @moduledoc """
  Full-text search over the app's content (the Mod-K/Mod-F overlay, `MythweaverWeb.Search`).

  Each searched table carries a generated `search_vector` (`simple` configuration, so matching is
  language-agnostic and unstemmed) with a GIN index; no schema declares the column, so queries reach
  it through a schemaless self-join on `id`. Typed text becomes a prefix-matching tsquery through
  `Search.Query`.

  Owned kinds list only rows `scope` may edit (`Ownership.editable/2`, the same rule as their
  editors' lists), so every hit opens. Chats and messages are the scope user's own; only a
  message's active swipe and no drafts are searched.
  """

  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Query

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.AI
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Lore.BookEntry
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Memory
  alias Mythweaver.Messages.Message
  alias Mythweaver.Messages.MessageBody
  alias Mythweaver.Ownership
  alias Mythweaver.Prompts.Block
  alias Mythweaver.Prompts.Outlet
  alias Mythweaver.Prompts.Prompt
  alias Mythweaver.Repo
  alias Mythweaver.Scripts.Script
  alias Mythweaver.Search.Hit
  alias Mythweaver.Search.Query

  @kinds [
    :chat,
    :message,
    :character,
    :lore_book,
    :lore_entry,
    :prompt,
    :prompt_block,
    :prompt_outlet,
    :script,
    :side_prompt,
    :memory_profile,
    :ai_model,
    :ai_provider
  ]

  # ts_headline marks matches with private-use characters, split into segments by `segments/1`.
  @start_sel "\uE000"
  @stop_sel "\uE001"
  @title_opts "HighlightAll=true, StartSel=#{@start_sel}, StopSel=#{@stop_sel}"
  @snippet_opts "StartSel=#{@start_sel}, StopSel=#{@stop_sel}, MaxWords=30, MinWords=12, " <>
                  "MaxFragments=2, FragmentDelimiter=\" … \""

  @type group :: %{kind: atom(), hits: [Hit.t()], more?: boolean()}

  @doc "Every searchable kind, in result order."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc """
  Searches `text` across kinds, returning the kinds with hits in `kinds/0` order.

  Options: `:kinds` (default all), `:limit` per kind (default 5; `more?` says whether more matched),
  `:chat_id` (messages of that chat only, newest first; skips chats), `:book_id` (lore entries
  linked to that book only), `:chat_kind` (`:roleplay` or `:assistant`; chats and messages of that
  kind only).
  """
  @spec search(Scope.t(), String.t() | nil, keyword()) :: [group()]
  def search(%Scope{} = scope, text, opts \\ []) do
    case Query.to_tsquery(text) do
      :empty ->
        []

      {:ok, tsq} ->
        wanted = Keyword.get(opts, :kinds, @kinds)
        limit = Keyword.get(opts, :limit, 5)
        kinds = Enum.filter(@kinds, &(&1 in wanted and not (&1 == :chat and opts[:chat_id] != nil)))

        Enum.flat_map(kinds, fn kind ->
          rows = kind |> query(scope, tsq, limit, opts) |> Repo.all()

          case Enum.split(rows, limit) do
            {[], _} -> []
            {rows, extra} -> [%{kind: kind, hits: Enum.map(rows, &hit(kind, &1)), more?: extra != []}]
          end
        end)
    end
  end

  defp query(:chat, scope, tsq, limit, opts) do
    from(c in Chat,
      as: :chat,
      join: v in "chats",
      on: v.id == c.id,
      where: fragment("? @@ to_tsquery('simple', ?)", v.search_vector, ^tsq),
      select: %{id: c.id, title: c.name, rank: fragment("ts_rank(?, to_tsquery('simple', ?))", v.search_vector, ^tsq)},
      order_by: [
        desc: fragment("ts_rank(?, to_tsquery('simple', ?))", v.search_vector, ^tsq),
        asc: c.name,
        asc: c.id
      ],
      limit: ^(limit + 1)
    )
    |> own_chats(scope)
    |> chat_kind(opts[:chat_kind])
    |> headlines(tsq, false, :rank_title)
  end

  defp query(:message, scope, tsq, limit, opts) do
    chat_id = opts[:chat_id]

    from(b in MessageBody,
      join: v in "message_bodies",
      on: v.id == b.id,
      join: m in Message,
      on: m.id == b.message_id,
      join: c in Chat,
      as: :chat,
      on: c.id == m.chat_id,
      left_join: a in Character,
      on: a.id == m.author_character_id,
      where: b.active and not m.draft,
      where: fragment("? @@ to_tsquery('simple', ?)", v.search_vector, ^tsq),
      select: %{
        id: m.id,
        chat_id: c.id,
        chat_name: c.name,
        position: m.position,
        title: coalesce(m.author_name, a.name),
        snippet: b.content,
        rank: fragment("ts_rank(?, to_tsquery('simple', ?))", v.search_vector, ^tsq)
      },
      limit: ^(limit + 1)
    )
    |> then(fn q ->
      if chat_id do
        q |> where([_b, _v, m], m.chat_id == ^chat_id) |> order_by([_b, _v, m], desc: m.position)
      else
        order_by(q, [_b, v, m],
          desc: fragment("ts_rank(?, to_tsquery('simple', ?))", v.search_vector, ^tsq),
          desc: m.position
        )
      end
    end)
    |> own_chats(scope)
    |> chat_kind(opts[:chat_kind])
    |> headlines(tsq, true, if(chat_id, do: :position, else: :rank_position))
  end

  defp query(kind, scope, tsq, limit, opts) do
    %{schema: schema, table: table, title: title, snippet: snippet} = source(kind)

    from(r in schema,
      as: :row,
      join: v in ^table,
      on: v.id == r.id,
      where: fragment("? @@ to_tsquery('simple', ?)", v.search_vector, ^tsq),
      select: %{
        id: r.id,
        title: field(r, ^title),
        rank: fragment("ts_rank(?, to_tsquery('simple', ?))", v.search_vector, ^tsq)
      },
      order_by: [
        desc: fragment("ts_rank(?, to_tsquery('simple', ?))", v.search_vector, ^tsq),
        asc: field(r, ^title),
        asc: r.id
      ],
      limit: ^(limit + 1)
    )
    |> then(fn q -> if snippet, do: select_merge(q, [r], %{snippet: field(r, ^snippet)}), else: q end)
    |> in_book(kind, opts[:book_id])
    |> Ownership.editable(scope)
    |> headlines(tsq, snippet != nil, :rank_title)
  end

  defp in_book(query, :lore_entry, book_id) when is_binary(book_id) do
    where(
      query,
      exists(
        from be in BookEntry,
          where: be.lore_entry_id == parent_as(:row).id and be.lore_book_id == ^book_id
      )
    )
  end

  defp in_book(query, _kind, _book_id), do: query

  # Headlines are computed outside the limited inner query so only the returned rows pay for them.
  defp headlines(inner, tsq, snippet?, order) do
    outer =
      from(s in subquery(inner),
        select: s,
        select_merge: %{
          title: fragment("ts_headline('simple', ?, to_tsquery('simple', ?), ?)", s.title, ^tsq, ^@title_opts)
        }
      )

    outer =
      if snippet? do
        select_merge(outer, [s], %{
          snippet: fragment("ts_headline('simple', ?, to_tsquery('simple', ?), ?)", s.snippet, ^tsq, ^@snippet_opts)
        })
      else
        outer
      end

    case order do
      :rank_title -> order_by(outer, [s], desc: s.rank, asc: s.title, asc: s.id)
      :rank_position -> order_by(outer, [s], desc: s.rank, desc: s.position)
      :position -> order_by(outer, [s], desc: s.position)
    end
  end

  # Chats and messages are only ever the scope user's own; a scope without a user has none.
  defp own_chats(query, %Scope{user: %User{id: id}}), do: where(query, [chat: c], c.user_id == ^id)
  defp own_chats(query, %Scope{}), do: where(query, false)

  defp chat_kind(query, nil), do: query
  defp chat_kind(query, kind), do: where(query, [chat: c], c.kind == ^kind)

  defp source(:character), do: %{schema: Character, table: "characters", title: :name, snippet: :description}
  defp source(:lore_book), do: %{schema: LoreBook, table: "lore_books", title: :name, snippet: :description}
  defp source(:lore_entry), do: %{schema: LoreEntry, table: "lore_entries", title: :name, snippet: :content}
  defp source(:prompt), do: %{schema: Prompt, table: "prompts", title: :name, snippet: :description}
  defp source(:prompt_block), do: %{schema: Block, table: "prompt_blocks", title: :name, snippet: :content}
  defp source(:prompt_outlet), do: %{schema: Outlet, table: "prompt_outlets", title: :name, snippet: :description}
  defp source(:script), do: %{schema: Script, table: "scripts", title: :name, snippet: :body}
  defp source(:side_prompt), do: %{schema: Memory.SidePrompt, table: "side_prompts", title: :name, snippet: :title}
  defp source(:memory_profile), do: %{schema: Memory.Profile, table: "memory_profiles", title: :name, snippet: nil}
  defp source(:ai_model), do: %{schema: AI.Model, table: "ai_models", title: :name, snippet: :notes}
  defp source(:ai_provider), do: %{schema: AI.Provider, table: "providers", title: :name, snippet: nil}

  defp hit(:message, row) do
    %Hit{
      kind: :message,
      id: row.id,
      title: segments(row.title),
      snippet: segments(row.snippet),
      rank: row.rank,
      chat_id: row.chat_id,
      chat_title: row.chat_name || pgettext("status: title of a search hit's chat that has no name", "Untitled chat"),
      position: row.position
    }
  end

  defp hit(kind, row) do
    %Hit{kind: kind, id: row.id, title: segments(row.title), snippet: segments(row[:snippet]), rank: row.rank}
  end

  defp segments(nil), do: nil

  defp segments(text) do
    if String.trim(text) != "", do: split_segments(text)
  end

  defp split_segments(text) do
    [plain | marked] = String.split(text, @start_sel)

    [{plain, false} | Enum.flat_map(marked, &marked_segments/1)]
    |> Enum.reject(fn {chunk, _} -> chunk == "" end)
    |> case do
      [] -> nil
      segments -> segments
    end
  end

  defp marked_segments(chunk) do
    case String.split(chunk, @stop_sel, parts: 2) do
      [mark, rest] -> [{mark, true}, {rest, false}]
      [mark] -> [{mark, true}]
    end
  end
end
