defmodule Mythweaver.Lore.Activation do
  @moduledoc """
  Resolves which lore entries are active for a chat, and why.

  `resolve/2` returns an ordered list of decisions grouped by injection slot, alongside the rejections
  that explain the absences. Its consumers: `Mythweaver.Prompts.Builder.context/2` resolves with
  `commit: false` when assembling a prompt, `Mythweaver.Generation.Server` resolves with `commit: true`
  to persist sticky/cooldown state for the reply it generates, and the chat's lore preview panel
  renders the result directly.

  A `:vector` entry activates when its stored embedding is similar enough to one of its scan window's
  messages (`Mythweaver.Lore.Embeddings.compare/3`), or on its keywords. `resolve/3` compares stored
  vectors only; `Lore.Embeddings` embeds entries and messages in the background, so vector matching
  adds database queries but never an API call to a reply.
  """

  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Query, warn: false

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Format
  alias Mythweaver.Lore
  alias Mythweaver.Lore.Embeddings
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Lore.Matcher
  alias Mythweaver.Lore.Rules
  alias Mythweaver.Lore.Settings
  alias Mythweaver.Memory.Record
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message
  alias Mythweaver.Prompts.ContextLimit
  alias Mythweaver.Prompts.Transcript
  alias Mythweaver.Repo
  alias Mythweaver.Sharing
  alias Mythweaver.Tags
  alias Mythweaver.Tags.Graph
  alias Mythweaver.Tags.Tag
  alias Mythweaver.Templates
  alias Mythweaver.Templates.State
  alias Mythweaver.Tokenizer

  @setting_keys ~w(lore.scan_depth lore.case_sensitive lore.match_whole_words lore.word_boundary lore.max_recursion_steps lore.token_budget lore.token_budget_percent lore.overflow lore.default_depth images.caption_template lore.embedding_model lore.vector_threshold lore.vector_max_entries generation.max_context)

  # The budget when neither a context limit nor `lore.token_budget` gives one.
  @fallback_budget 15_000

  @type decision :: %{
          entry: LoreEntry.t(),
          book: LoreBook.t(),
          effective_order: integer(),
          slot: String.t(),
          depth: integer() | nil,
          reason: atom(),
          pass: pos_integer(),
          tokens: non_neg_integer()
        }

  @type rejection :: %{entry: struct(), book: LoreBook.t(), reason: atom(), detail: String.t() | nil}

  @type result :: %{
          activated: [decision()],
          by_slot: %{optional(String.t()) => [decision()]},
          by_outlet: %{optional(String.t()) => [decision()]},
          rejected: [rejection()],
          budget: %{
            limit: non_neg_integer(),
            used: non_neg_integer(),
            overflowed?: boolean(),
            estimated?: boolean()
          },
          passes: non_neg_integer()
        }

  @doc """
  A result in which nothing activated, for prompts that must not activate lore (memory-book prompts:
  `Mythweaver.Prompts.Builder.context/2` with `:memory`). The only result with `passes: 0`.
  """
  @spec empty() :: result()
  def empty do
    %{
      activated: [],
      by_slot: %{},
      by_outlet: %{},
      rejected: [],
      budget: %{limit: 0, used: 0, overflowed?: false, estimated?: true},
      passes: 0
    }
  end

  @doc """
  Resolves activation for `chat`. Raises `Mythweaver.UnauthorizedError` unless `scope` may act on it.

  Options:

    * `:commit`: persist sticky/cooldown state for the activated entries (default `false`; the
      debug preview must stay side-effect free)
    * `:rng`: zero-arity float generator in `[0.0, 1.0)`, used for probability rolls and weighted
      pool draws (default `&:rand.uniform/0`); injecting it is what makes those paths testable
    * `:messages`: the scan window source (default `Messages.list_messages(chat)`)
    * `:tag_graph`: the chat owner's `Mythweaver.Tags.graph/1`, when the caller already has it
      (default: loaded here)
    * `:model`: the responding model; its tokenizer measures entry size for the budget
      (default `nil`, an estimate)
    * `:context_limit`: the reply's `Mythweaver.Prompts.ContextLimit`, when the caller already
      has it (default: `ContextLimit.for_reply/2` for `:model`)
    * `:character`: the responding character. Character-bound books apply for the characters the
      chat's Group cards setting joins to its reply (`Chat.card_character_ids/2`); with none (the
      default, a preview) every participant's apply. The responder's own books' entries take the
      budget first, ahead of book priority, so joined cards' books cannot crowd them out. A
      character's memory copy made in this chat replaces the chat's memory only on that character's
      turn; with no character, copies made in this chat stay out

  A book's activation rules (`Mythweaver.Lore.Rules`) gate its entries: a book whose enabled rules
  all fail rejects them as `:book_rule_filtered`.
  """
  @spec resolve(Scope.t(), Chat.t(), keyword()) :: result()
  def resolve(%Scope{} = scope, chat, opts \\ []) do
    if Chats.authorize(scope, chat, :inspect) != :ok, do: raise(Mythweaver.UnauthorizedError)
    model = Keyword.get(opts, :model)
    context_limit = Keyword.get_lazy(opts, :context_limit, fn -> model && ContextLimit.for_reply(scope, model) end)
    values = Mythweaver.Settings.get_many(scope, @setting_keys)
    defaults = values |> defaults() |> Map.put(:token_budget, token_budget(values, context_limit))
    # A forced book is the site's rule, so it reads the site's lore settings, not the user's.
    site_values = Mythweaver.Settings.get_many(%Scope{}, @setting_keys)
    site_defaults = defaults(site_values)

    commit? = Keyword.get(opts, :commit, false)
    rng = Keyword.get(opts, :rng, &:rand.uniform/0)
    messages = Keyword.get_lazy(opts, :messages, fn -> Messages.list_messages(chat) end)

    message_count = length(messages)
    participant_ids = MapSet.new(chat.participants || [], & &1.character_id)
    states = Lore.entry_states(chat)

    {tag_graph, participant_tags} =
      Tags.participant_tags(chat, Keyword.get_lazy(opts, :tag_graph, fn -> Tags.graph(chat.user_id) end))

    {characters, responder} = reply_characters(chat, Keyword.get(opts, :character))

    card_ids = if characters == :participants, do: participant_ids, else: MapSet.new(characters)

    {candidates, rule_failures} =
      candidates(chat, {characters, responder}, %{
        card_ids: card_ids,
        graph: tag_graph,
        character_tags: if(characters == :participants, do: participant_tags)
      })

    key_texts = key_texts(chat, candidates, Keyword.get(opts, :character))

    candidates =
      Enum.map(candidates, &compile_keywords(&1, defaults_for(&1, defaults, site_defaults), key_texts))

    defaults =
      if Enum.any?(candidates, & &1.book.forced),
        do: %{defaults | max_passes: max(defaults.max_passes, site_defaults.max_passes)},
        else: defaults

    # SillyTavern's delay-until-recursion levels: an entry delayed to level N waits for a recursion
    # pass at level N or above. The lowest level opens with the first recursion pass; each later one
    # when a pass at the current level activates nothing.
    {recursion_level, pending_levels} =
      candidates
      |> Enum.map(& &1.entry.delay_until_recursion)
      |> Enum.filter(&(&1 > 0))
      |> Enum.uniq()
      |> Enum.sort()
      |> case do
        [] -> {0, []}
        [level | rest] -> {level, rest}
      end

    state = %{
      # Newest-first; reversed once after the passes.
      activated: [],
      rejected: [],
      used_global: 0,
      used_by_book: %{},
      overflowed?: false,
      # The recursion haystack suffix and its downcased copy, extended by each pass's new content.
      recursion_suffix: {"", ""},
      pass: 0,
      model: model,
      recursion_level: recursion_level,
      pending_levels: pending_levels,
      # Entries that lost their probability roll; a failed roll holds for every later pass.
      failed_probability: MapSet.new()
    }

    windows = scan_windows(candidates, messages, defaults, site_defaults)

    state =
      run_passes(state, %{
        candidates: candidates,
        windows: windows,
        vector: vector_matches(scope, chat, candidates, messages, defaults, site_defaults),
        message_count: message_count,
        participant_ids: participant_ids,
        tag_graph: tag_graph,
        participant_tags: participant_tags,
        rule_failures: rule_failures,
        states: states,
        rng: rng,
        defaults: defaults,
        site_defaults: site_defaults
      })

    # SillyTavern's order: within a slot, ascending effective order (higher renders later), a card
    # book's entries ahead of World Info, and book priority ahead of order (Aikobots'
    # `priority × 10000 + order`; every non-Aikobots book is priority 3).
    activated =
      Enum.sort_by(
        Enum.reverse(state.activated),
        &{slot_index(&1.slot), &1.book.kind != :card, &1.book.priority, &1.effective_order, &1.entry.name}
      )

    activated_ids = MapSet.new(activated, & &1.entry.id)

    # Candidates are re-evaluated every pass, so one entry can be rejected repeatedly and for
    # different reasons as the recursion haystack grows. `state.rejected` is newest-first, so
    # `uniq_by` keeps each entry's *final* verdict; the reverse then restores evaluation order.
    rejected =
      state.rejected
      |> Enum.reject(&MapSet.member?(activated_ids, &1.entry.id))
      |> Enum.uniq_by(& &1.entry.id)
      |> Enum.reverse()

    # Only fresh activations (re)start the sticky and cooldown windows. A `:sticky` decision is the
    # window itself holding the entry, and re-recording it would push the horizon out every turn.
    if commit? do
      fresh = for %{reason: reason, entry: entry} <- activated, reason != :sticky, do: entry
      Lore.record_activations(chat, fresh, message_count)
    end

    %{
      activated: activated,
      by_slot: Enum.group_by(activated, & &1.slot),
      # Keyed by the bare `custom_outlet`, not the `"custom:"`-prefixed slot, because callers ask by
      # outlet key. `by_slot` still holds the same decisions under `"custom:<key>"`, which is what makes
      # them show up in the debug preview for free.
      by_outlet:
        activated
        |> Enum.filter(&(&1.entry.outlet == :custom and not &1.entry.trigger_only))
        |> Enum.group_by(& &1.entry.custom_outlet),
      rejected: rejected,
      budget: %{
        limit: defaults.token_budget,
        used: state.used_global,
        overflowed?: state.overflowed?,
        estimated?: not Tokenizer.exact?(model)
      },
      passes: max(state.pass, 1)
    }
  end

  defp defaults(values) do
    %{
      scan_depth: values["lore.scan_depth"],
      case_sensitive: values["lore.case_sensitive"],
      whole_words: values["lore.match_whole_words"],
      word_boundary: values["lore.word_boundary"],
      # Integers sort below atoms, so `max/2` and `pass >= max_passes` treat `:infinity` as unbounded.
      max_passes: if(values["lore.max_recursion_steps"] == 0, do: :infinity, else: values["lore.max_recursion_steps"]),
      overflow: values["lore.overflow"],
      default_depth: values["lore.default_depth"],
      caption_template: values["images.caption_template"],
      embedding_model: values["lore.embedding_model"],
      vector_threshold: values["lore.vector_threshold"],
      vector_max_entries: values["lore.vector_max_entries"]
    }
  end

  # SillyTavern's budget: a share of the reply's context limit, capped by `lore.token_budget` when
  # that is set. With no known limit (a preview) the scope's `generation.max_context` stands in;
  # with neither, the cap alone applies, else `@fallback_budget`.
  defp token_budget(values, context_limit) do
    cap = values["lore.token_budget"]
    max_context = values["generation.max_context"]

    limit =
      case context_limit do
        %ContextLimit{limit: limit} when is_integer(limit) -> limit
        _ when is_integer(max_context) and max_context > 0 -> max_context
        _ -> nil
      end

    cond do
      is_integer(limit) ->
        budget = max(round(limit * values["lore.token_budget_percent"] / 100), 1)
        if cap > 0, do: min(budget, cap), else: budget

      cap > 0 ->
        cap

      true ->
        @fallback_budget
    end
  end

  @doc """
  The chat's Vector candidates grouped by the embedding model their settings name, for
  `Mythweaver.Lore.Embeddings`' background sync: a forced book's entries under the site's
  `lore.embedding_model` (a forced book is the site's rule), every other entry under the user's.
  Candidates are every participant's, as in a resolve with no character. Groups whose setting is
  unset are dropped, so a chat without Vector entries or without a model gives `[]`.
  """
  @spec vector_groups(Scope.t(), Chat.t()) :: [{Ecto.UUID.t(), [LoreEntry.t()]}]
  def vector_groups(%Scope{} = scope, %Chat{} = chat) do
    if Chats.authorize(scope, chat, :read) != :ok, do: raise(Mythweaver.UnauthorizedError)

    {graph, participant_tags} = Tags.participant_tags(chat, Tags.graph(chat.user_id))
    {characters, responder} = reply_characters(chat, nil)

    card_ids =
      if characters == :participants,
        do: MapSet.new(chat.participants || [], & &1.character_id),
        else: MapSet.new(characters)

    facts = %{card_ids: card_ids, graph: graph, character_tags: if(characters == :participants, do: participant_tags)}
    {candidates, _rule_failures} = candidates(chat, {characters, responder}, facts)

    candidates
    |> Enum.filter(&vector_candidate?/1)
    |> case do
      [] ->
        []

      vector ->
        user_model = Mythweaver.Settings.get(scope, "lore.embedding_model")
        site_model = Mythweaver.Settings.get(%Scope{}, "lore.embedding_model")

        vector
        |> Enum.group_by(&if(&1.book.forced, do: site_model, else: user_model), & &1.entry)
        |> Enum.reject(fn {model_id, _entries} -> is_nil(model_id) end)
    end
  end

  defp vector_candidate?(%{entry: %{activation: :vector}, membership: %{enabled: true}}), do: true
  defp vector_candidate?(_candidate), do: false

  @doc """
  The concatenated content of every entry that activated into the custom outlet `key`.

  Sorted by descending effective order, ties by name, as SillyTavern builds an outlet (card-book
  entries first, then higher book priority). `resolve/2`'s `activated` list is the reverse within a
  slot: ascending, so higher order renders later.

  Every gate applies: this is a projection of `resolve/2`, not a raw query, so book scope, membership and
  entry `enabled`, the character filter, delay, cooldown, sticky, keyword/constant activation, pools,
  probability, and the token budget all decide what appears here.

  `opts` are `resolve/3`'s, plus:

    * `:result`: an already-computed `resolve/3` result, so a caller that resolved once can query
      several outlets without re-running activation.

  Returns `""` when no entry activated for `key`, so a caller can inject the value unconditionally.

  NOTE: nothing in the app calls this yet. The prompt builder reaches custom outlets through
  `outlet_decisions/1`; this single-key function is the macro system's entry point (arbitrary injection
  into any other prompt or field) and is exercised only by tests until that lands. Do not delete it as
  dead code.
  """
  @spec outlet(Scope.t(), Chat.t(), String.t(), keyword()) :: String.t()
  def outlet(%Scope{} = scope, chat, key, opts \\ []) do
    scope
    |> outlets(chat, opts)
    |> Map.get(key, "")
  end

  @doc """
  Every custom outlet that activated, as `%{key => concatenated content}`.

  Same ordering and gating as `outlet/4`: descending effective order, ties by name. Outlets with no
  activated entry are absent from the map rather than present-and-empty, so `Map.get(outlets, key, "")`
  is the caller's contract.

  One activation pass yields every outlet's value, instead of one pass per referenced outlet. The joined
  text is raw `entry.content`; the prompt builder renders entry templates, so it uses
  `outlet_decisions/1` instead.
  """
  @spec outlets(Scope.t(), Chat.t(), keyword()) :: %{optional(String.t()) => String.t()}
  def outlets(%Scope{} = scope, chat, opts \\ []) do
    # `commit: false` unless the caller insists: a lookup must not persist sticky/cooldown state.
    result =
      Keyword.get_lazy(opts, :result, fn ->
        resolve(scope, chat, Keyword.put_new(opts, :commit, false))
      end)

    result
    |> outlet_decisions()
    |> Map.new(fn {key, decisions} -> {key, Enum.map_join(decisions, "\n", & &1.entry.content)} end)
  end

  @doc """
  `result`'s custom outlets as `%{key => [decision]}`, each list in injection order: card-book
  entries first, then higher book priority, then descending effective order, then name.

  What `Mythweaver.Prompts.Builder.context/2` uses: the builder renders each entry's template on its
  own, so it needs the entries rather than `outlets/2`'s joined text.
  """
  @spec outlet_decisions(result()) :: %{optional(String.t()) => [decision()]}
  def outlet_decisions(result) do
    Map.new(result.by_outlet, fn {key, decisions} ->
      {key, Enum.sort_by(decisions, &{&1.book.kind != :card, -&1.book.priority, -&1.effective_order, &1.entry.name})}
    end)
  end

  @slot_index Settings.slots() |> Enum.with_index() |> Map.new()

  # Slots sort in injection order, not alphabetically: "after_author_note" must not lead.
  defp slot_index(slot), do: Map.get(@slot_index, slot, map_size(@slot_index))

  ## Candidates

  # The characters a reply's books bind through (`:participants` for a preview) and its responder.
  defp reply_characters(chat, character) do
    case character do
      %{id: id} when is_binary(id) -> {Chat.card_character_ids(chat, id), id}
      _none -> {:participants, nil}
    end
  end

  # One preload pass, no N+1: every membership, entry, character filter, pool row and activation
  # rule the whole resolve needs is fetched here.
  # Also returns each book's rule failures (`Rules.failures/6`), which rank the dedupe.
  defp candidates(chat, {characters, responder}, facts) do
    books =
      chat
      |> Lore.books_for_chat(characters)
      |> Repo.preload([
        :filter_tags,
        rules: :conditions,
        book_entries: [entry: [:entry_characters, :filter_tags, pool_entries: :pool]]
      ])

    rule_failures = Rules.failures(books, chat, facts.card_ids, responder, facts.graph, facts.character_tags)

    candidates =
      books
      |> Enum.flat_map(fn book ->
        Enum.map(book.book_entries, fn membership ->
          %{
            entry: membership.entry,
            book: book,
            membership: membership,
            effective_order: membership.order + book.order_adjustment
          }
        end)
      end)
      |> drop_toggled_off(chat.user_id)
      |> prefer_own_copies(own_copies(chat), responder)

    own = responder_entry_ids(candidates, chat, responder)

    sorted =
      candidates
      |> dedupe_by_winning_membership(rule_failures)
      |> Enum.sort_by(&{not MapSet.member?(own, &1.entry.id), -&1.book.priority, -&1.effective_order, &1.entry.name})

    {sorted, rule_failures}
  end

  # The chat owner's subscriber toggles (`Mythweaver.Sharing.set_toggle/3`): an entry they don't own
  # and switched off leaves, except through a forced site book, which no toggle reaches.
  defp drop_toggled_off(candidates, owner_id) do
    ids = for %{entry: %{user_id: u, id: id}} <- candidates, u != owner_id, uniq: true, do: id
    off = Sharing.toggles(owner_id, :lore_entry, ids)

    Enum.reject(candidates, fn %{entry: entry, book: book} ->
      Map.get(off, entry.id) == false and entry.user_id != owner_id and not (is_nil(book.user_id) and book.forced)
    end)
  end

  # Entries reached through the responder's own books (`Lore.character_book_ids/2`) walk first, so
  # joined cards' books cannot spend the budget before the responder's do. Taken before the dedupe:
  # an entry in both the responder's book and a higher-ranked one is still the responder's.
  defp responder_entry_ids(_candidates, _chat, nil), do: MapSet.new()

  defp responder_entry_ids(candidates, chat, responder) do
    books = Lore.character_book_ids(chat, responder)
    for %{book: book, entry: entry} <- candidates, MapSet.member?(books, book.id), into: MapSet.new(), do: entry.id
  end

  # In the chat it was made in, a character's copy of a memory (`Mythweaver.Memory.Record`'s
  # `canonical_id`) takes the place of the chat's own memory on that character's turn: a copy whose
  # filter holds the responder stays and its canonical entry goes; every other copy of this chat goes
  # (no responder, as in a preview, keeps only the canonical). Copies from other chats are ordinary
  # entries there.
  defp prefer_own_copies(candidates, copies, _responder) when map_size(copies) == 0, do: candidates

  defp prefer_own_copies(candidates, copies, responder) do
    kept =
      for %{entry: entry} <- candidates,
          Map.has_key?(copies, entry.id),
          responder != nil and Enum.any?(entry.entry_characters, &(&1.character_id == responder)),
          into: MapSet.new(),
          do: entry.id

    replaced = MapSet.new(kept, &Map.fetch!(copies, &1))

    Enum.reject(candidates, fn %{entry: %{id: id}} ->
      (Map.has_key?(copies, id) and not MapSet.member?(kept, id)) or MapSet.member?(replaced, id)
    end)
  end

  # This chat's copies: `%{copy_entry_id => canonical_entry_id}`.
  defp own_copies(%Chat{id: nil}), do: %{}

  defp own_copies(%Chat{id: chat_id}) do
    Map.new(
      Repo.all(
        from(r in Record,
          join: canonical in Record,
          on: canonical.id == r.canonical_id,
          where: r.chat_id == ^chat_id,
          select: {r.lore_entry_id, canonical.lore_entry_id}
        )
      )
    )
  end

  # An entry reachable through several books activates once. Enabled memberships rank first, then a
  # book whose activation rules pass (so a rule-failing book cannot shadow a live one); among them,
  # the winner has the greatest `{book.priority, book.order_adjustment + membership.order}`,
  # ties broken on book name so the choice is total and deterministic.
  defp dedupe_by_winning_membership(candidates, rule_failures) do
    candidates
    |> Enum.group_by(& &1.entry.id)
    |> Enum.map(fn {_id, group} -> Enum.min_by(group, &membership_rank(&1, rule_failures)) end)
  end

  # `false < true`, so an enabled membership beats a disabled one, then a rule-passing book beats a
  # rule-failing one. The rest is negated so `min_by`
  # picks the greatest priority/effective order, with `book.name` ascending as the final tie-break:
  # one total key, no custom sorter.
  defp membership_rank(candidate, rule_failures) do
    {not candidate.membership.enabled, Map.has_key?(rule_failures, candidate.book.id), -candidate.book.priority,
     -(candidate.book.order_adjustment + candidate.membership.order), candidate.book.name}
  end

  # A keyword entry's match options are fixed for the whole resolve, so its keywords compile once
  # here rather than once per pass. Only an entry that can reach `keyword_gate/3` needs them: a
  # vector entry falls back to its keywords. A Liquid key matches as `key_texts/3` rendered it; one
  # rendering blank is dropped (SillyTavern skips an empty substitution).
  defp compile_keywords(
         %{entry: %{activation: activation} = entry, membership: %{enabled: true}} = candidate,
         defaults,
         key_texts
       )
       when activation in [:keyword, :vector] do
    case_sensitive? = bool_default(entry.case_sensitive, defaults.case_sensitive)

    opts = [
      case_sensitive: case_sensitive?,
      whole_words: bool_default(entry.match_whole_words, defaults.whole_words),
      boundary: defaults.word_boundary
    ]

    compile = fn keys ->
      for key <- keys, text = Map.get(key_texts, key, key), text != "", do: Matcher.compile(text, opts)
    end

    Map.merge(candidate, %{
      case_sensitive?: case_sensitive?,
      keywords: compile.(entry.keywords),
      secondary_keywords: compile.(entry.secondary_keywords)
    })
  end

  defp compile_keywords(candidate, _defaults, _key_texts), do: candidate

  # SillyTavern expands macros in keys (`{{char}}`); a key holding Liquid renders once per resolve
  # with the names only: `anchors.character.name` (the responder, or in a preview the first
  # participant who isn't the player), `anchors.player.name` and `anchors.participants`.
  defp key_texts(chat, candidates, character) do
    keys =
      for %{entry: entry} <- candidates,
          key <- entry.keywords ++ entry.secondary_keywords,
          Templates.template?(key),
          uniq: true,
          do: key

    if keys == [] do
      %{}
    else
      keys
      |> Templates.render_many(key_state(chat, character))
      |> Enum.zip_with(keys, fn {rendered, _errors}, key -> {key, String.trim(rendered)} end)
      |> Map.new()
    end
  end

  defp key_state(chat, character) do
    chat = Repo.preload(chat, [:player_character, participants: :character])
    characters = chat |> Chat.characters() |> Enum.filter(&is_struct/1)

    responder =
      case character do
        %{name: name} when is_binary(name) -> name
        _ -> chat |> Chat.responder() |> then(&(&1 && &1.name))
      end

    data = %{
      "anchors" => %{
        "character" => %{"name" => responder},
        "player" => %{"name" => chat.player_character && chat.player_character.name},
        "participants" => Enum.map_join(characters, ", ", & &1.name)
      }
    }

    State.new(data, %{chat: %{}, global: %{}}, nil)
  end

  defp defaults_for(%{book: %{forced: true}}, _defaults, site_defaults), do: site_defaults
  defp defaults_for(_candidate, defaults, _site_defaults), do: defaults

  defp bool_default(nil, default), do: default
  defp bool_default(value, _default), do: value

  ## Pass loop

  defp run_passes(state, ctx) do
    pass = state.pass + 1
    settled_ids = MapSet.union(MapSet.new(state.activated, & &1.entry.id), state.failed_probability)
    remaining = Enum.reject(ctx.candidates, &MapSet.member?(settled_ids, &1.entry.id))

    {newly, state} = evaluate_pass(remaining, %{state | pass: pass}, ctx)

    cond do
      state.overflowed? or pass >= ctx.defaults.max_passes ->
        state

      Enum.any?(newly, &(not &1.entry.prevent_recursion)) ->
        run_passes(state, ctx)

      state.pending_levels != [] ->
        [level | rest] = state.pending_levels
        run_passes(%{state | recursion_level: level, pending_levels: rest}, ctx)

      true ->
        state
    end
  end

  defp evaluate_pass(candidates, state, ctx) do
    haystacks = build_haystacks(candidates, state, ctx)

    {gated, state} =
      Enum.reduce(candidates, {[], state}, fn candidate, {kept, state} ->
        case gate(candidate, state, ctx, haystacks) do
          {:ok, reason} -> {[Map.put(candidate, :reason, reason) | kept], state}
          {:reject, reason, detail} -> {kept, reject(state, candidate, reason, detail)}
        end
      end)

    gated = Enum.reverse(gated)

    {pool_winners, state} = apply_pools(gated, state, ctx, haystacks)
    {rolled, state} = apply_probability(pool_winners, state, ctx)
    {admitted, state} = apply_budget(rolled, state, ctx)

    state = commit_pass(admitted, state, ctx)

    {admitted, state}
  end

  # A trigger-only entry activates (it takes its pool slot, feeds recursion and records sticky and
  # cooldown) under the `"trigger_only"` slot, which no prompt renders.
  defp commit_pass(admitted, state, ctx) do
    decisions =
      Enum.map(admitted, fn candidate ->
        entry = candidate.entry
        slot = if entry.trigger_only, do: "trigger_only", else: LoreEntry.slot(entry)

        %{
          entry: entry,
          book: candidate.book,
          effective_order: candidate.effective_order,
          slot: slot,
          depth:
            cond do
              entry.trigger_only ->
                nil

              slot == "at_depth" ->
                entry.depth || defaults_for(candidate, ctx.defaults, ctx.site_defaults).default_depth

              true ->
                entry.depth
            end,
          reason: candidate.reason,
          pass: state.pass,
          tokens: candidate.tokens
        }
      end)

    added = for %{entry: entry} <- admitted, !entry.prevent_recursion, do: ["\n", entry.content]
    {suffix, lowered} = state.recursion_suffix

    suffix =
      if added == [] do
        {suffix, lowered}
      else
        added = IO.iodata_to_binary(added)
        {suffix <> added, lowered <> String.downcase(added)}
      end

    %{state | activated: Enum.reverse(decisions, state.activated), recursion_suffix: suffix}
  end

  ## Haystacks

  # Scan depth is per-entry, so the window (and its downcased copy) is built once per distinct depth
  # and shared by every pass.
  defp scan_windows(candidates, messages, defaults, site_defaults) do
    candidates
    |> depths(defaults, site_defaults)
    |> Map.new(fn depth ->
      text = window(messages, depth, defaults.caption_template)
      {depth, {text, String.downcase(text)}}
    end)
  end

  # Each pass appends what earlier passes activated, each content after a newline. The downcased copy
  # serves every case-insensitive literal keyword of the pass.
  defp build_haystacks(candidates, state, ctx) do
    {suffix, lowered_suffix} = state.recursion_suffix

    candidates
    |> depths(ctx.defaults, ctx.site_defaults)
    |> Map.new(fn depth ->
      {text, lowered} = Map.fetch!(ctx.windows, depth)
      {depth, {text <> suffix, lowered <> lowered_suffix}}
    end)
  end

  defp depths(candidates, defaults, site_defaults),
    do:
      for(
        candidate <- candidates,
        uniq: true,
        do: scan_depth(candidate, defaults_for(candidate, defaults, site_defaults))
      )

  defp scan_depth(candidate, defaults) do
    candidate.entry.scan_depth || candidate.book.scan_depth || defaults.scan_depth
  end

  # Each message's text plus its images' description lines (`Transcript.entries/3`'s `content`,
  # rendered through the caption template), so a described image triggers lore the same way its
  # words would; the same skip rules as the prompt.
  defp window(messages, depth, template) do
    messages
    |> Enum.take(-depth)
    |> Transcript.entries(nil, caption_template: template)
    |> Enum.map_join("\n", & &1.content)
  end

  ## Vector matching

  @no_vector %{hits: %{}, details: %{}}

  # Similarity is scored once per resolve, against each scan window only (not the recursion buffer),
  # from stored vectors: no API call. A forced book uses the site's embedding model, threshold and
  # top-K, as its keywords use the site's matching settings. Top-K is taken before the per-pass gates
  # (delay, cooldown, character filter), matching SillyTavern.
  defp vector_matches(scope, chat, candidates, messages, defaults, site_defaults) do
    case Enum.filter(candidates, &vector_candidate?/1) do
      [] ->
        @no_vector

      vector ->
        {matches, sync?} =
          vector
          |> Enum.group_by(& &1.book.forced)
          |> Enum.reduce({@no_vector, false}, fn {forced?, group}, {acc, sync?} ->
            group_defaults = if forced?, do: site_defaults, else: defaults
            {hits, details, group_sync?} = match_group(scope, forced?, group, messages, group_defaults)
            {%{hits: Map.merge(acc.hits, hits), details: Map.merge(acc.details, details)}, sync? or group_sync?}
          end)

        # So the next reply has what this one lacked; the resolve itself never waits on embeddings.
        if sync? and is_binary(chat.id), do: Embeddings.sync_chat_later(chat.id)
        matches
    end
  end

  defp match_group(scope, forced?, group, messages, defaults) do
    case Embeddings.model(scope, defaults.embedding_model) do
      {:error, :no_model} ->
        detail =
          if forced?,
            do: dgettext("errors", "no site embedding model set"),
            else: dgettext("errors", "no embedding model set (Settings › Lore › Vector matching)")

        {%{}, Map.new(group, &{&1.entry.id, detail}), false}

      {:ok, model} ->
        {verdicts, sync?} =
          group
          |> Enum.group_by(&scan_depth(&1, defaults))
          |> Enum.reduce({[], false}, fn {depth, candidates}, {verdicts, sync?} ->
            body_ids = window_body_ids(messages, depth)
            comparison = Embeddings.compare(model, Enum.map(candidates, & &1.entry), body_ids)
            missing? = MapSet.size(comparison.unembedded) > 0 or not comparison.all_messages_embedded?
            {verdicts ++ Enum.map(candidates, &verdict(&1.entry.id, comparison, body_ids)), sync? or missing?}
          end)

        {hits, details} = rank(verdicts, defaults)
        {hits, details, sync?}
    end
  end

  defp verdict(id, comparison, body_ids) do
    cond do
      Map.has_key?(comparison.scores, id) -> {id, {:score, Map.fetch!(comparison.scores, id)}}
      MapSet.member?(comparison.unembedded, id) -> {id, {:detail, dgettext("errors", "entry not embedded yet")}}
      body_ids == [] -> {id, {:detail, dgettext("errors", "nothing to compare: the scan window is empty")}}
      not comparison.messages_embedded? -> {id, {:detail, dgettext("errors", "recent messages not embedded yet")}}
      # Every stored message vector has another dimension (a changed model) or is a zero vector.
      true -> {id, {:detail, dgettext("errors", "no comparable message vector")}}
    end
  end

  # The most similar `vector_max_entries` at or above `vector_threshold` percent hit.
  defp rank(verdicts, defaults) do
    %{vector_threshold: threshold, vector_max_entries: max} = defaults
    {scored, unscored} = Enum.split_with(verdicts, &match?({_id, {:score, _}}, &1))

    {eligible, below} =
      scored
      |> Enum.map(fn {id, {:score, score}} -> {id, score} end)
      |> Enum.split_with(fn {_id, score} -> score * 100 >= threshold end)

    {top, cut} = eligible |> Enum.sort_by(&elem(&1, 1), :desc) |> Enum.split(max)

    details =
      Map.new(unscored, fn {id, {:detail, detail}} -> {id, detail} end)
      |> Map.merge(
        Map.new(cut, fn {id, score} ->
          {id,
           dgettext("errors", "similarity %{similarity_percent} outside the top %{entry_limit}",
             similarity_percent: Format.percent(pct(score) / 100),
             entry_limit: Format.number(max)
           )}
        end)
      )
      |> Map.merge(
        Map.new(below, fn {id, score} ->
          {id,
           dgettext("errors", "similarity %{similarity_percent} below %{threshold_percent}",
             similarity_percent: Format.percent(pct(score) / 100),
             threshold_percent: Format.percent(threshold / 100)
           )}
        end)
      )

    {Map.new(top), details}
  end

  defp pct(score), do: round(score * 100)

  # The active bodies of exactly the messages `window/3` reads (`Transcript.entries/3`'s skip rules),
  # less those that can't carry a vector: blank text (an image alone) or still generating.
  defp window_body_ids(messages, depth) do
    window = Enum.take(messages, -depth)
    bodies = Map.new(window, &{&1.id, Message.active_body(&1)})

    for %{message_id: id} <- Transcript.entries(window, nil),
        %{generating: false, content: content} = body <- [Map.get(bodies, id)],
        is_binary(content) and String.trim(content) != "",
        do: body.id
  end

  ## Gates

  defp gate(candidate, state, ctx, haystacks) do
    entry = candidate.entry
    sticky? = sticky?(entry, ctx)

    # The on/off switch lives on the membership only: an entry is off in a book where its membership is.
    cond do
      not candidate.membership.enabled ->
        {:reject, :disabled_book,
         dgettext("errors", "membership disabled in %{book_name}", book_name: candidate.book.name)}

      not book_tags_allowed?(candidate.book, ctx) ->
        {:reject, :book_tag_filtered, book_tag_filter_detail(candidate.book.tag_filter_mode)}

      Map.has_key?(ctx.rule_failures, candidate.book.id) ->
        {:reject, :book_rule_filtered, Map.fetch!(ctx.rule_failures, candidate.book.id)}

      not character_allowed?(entry, ctx) ->
        {:reject, :character_filtered, character_filter_detail(entry.character_filter_mode)}

      entry.delay && ctx.message_count < entry.delay ->
        {:reject, :delayed,
         dgettext("errors", "needs %{required_messages} messages, chat has %{message_count}",
           required_messages: Format.number(entry.delay),
           message_count: Format.number(ctx.message_count)
         )}

      cooling_down?(entry, ctx, sticky?) ->
        {:reject, :cooldown,
         dgettext("errors", "cooling down until message %{message_number}",
           message_number: Format.number(cooldown_until(entry, ctx))
         )}

      not sticky? and entry.delay_until_recursion > 0 and
          (state.pass == 1 or entry.delay_until_recursion > state.recursion_level) ->
        {:reject, :delayed_until_recursion,
         dgettext("errors", "waits for recursion level %{recursion_level}",
           recursion_level: Format.number(entry.delay_until_recursion)
         )}

      state.pass >= 2 and recursion_excluded?(candidate) ->
        {:reject, :recursion_excluded, dgettext("errors", "excluded from recursion")}

      sticky? ->
        {:ok, :sticky}

      entry.activation == :constant ->
        {:ok, :constant}

      entry.activation == :vector ->
        vector_gate(candidate, haystacks, ctx)

      true ->
        keyword_gate(candidate, haystacks, ctx)
    end
  end

  # `sticky_until` is an inclusive horizon: the entry holds through that message count. A
  # non-sticky entry has no horizon at all (`record_activations/3` writes `nil`), so committing an
  # activation never makes it sticky.
  defp sticky?(entry, ctx) do
    case Map.get(ctx.states, entry.id) do
      %{sticky_until: until} when is_integer(until) -> until >= ctx.message_count
      _ -> false
    end
  end

  defp cooling_down?(_entry, _ctx, true), do: false

  defp cooling_down?(entry, ctx, false) do
    case Map.get(ctx.states, entry.id) do
      %{cooldown_until: until} when is_integer(until) -> until > ctx.message_count
      _ -> false
    end
  end

  defp cooldown_until(entry, ctx) do
    case Map.get(ctx.states, entry.id) do
      %{cooldown_until: until} -> until
      _ -> nil
    end
  end

  defp recursion_excluded?(candidate) do
    candidate.entry.exclude_recursion or not candidate.book.recursive
  end

  # The entry's filter characters and filter tags together: overlap is any participant among the
  # characters, or any participant carrying (expanded) one of the tags.
  defp character_allowed?(entry, ctx) do
    case entry.character_filter_mode do
      :off ->
        true

      mode ->
        filtered = MapSet.new(entry.entry_characters, & &1.character_id)
        overlap? = not MapSet.disjoint?(filtered, ctx.participant_ids) or tags_overlap?(entry.filter_tags, ctx)
        if mode == :include, do: overlap?, else: not overlap?
    end
  end

  defp book_tags_allowed?(book, ctx) do
    case book.tag_filter_mode do
      :off ->
        true

      mode ->
        overlap? = tags_overlap?(book.filter_tags, ctx)
        if mode == :include, do: overlap?, else: not overlap?
    end
  end

  defp tags_overlap?(tags, ctx) do
    Enum.any?(tags, &MapSet.member?(ctx.participant_tags, Graph.ideal(ctx.tag_graph, Tag.text(&1))))
  end

  defp haystack(candidate, haystacks, ctx),
    do: Map.fetch!(haystacks, scan_depth(candidate, defaults_for(candidate, ctx.defaults, ctx.site_defaults)))

  defp keyword_gate(candidate, haystacks, ctx) do
    entry = candidate.entry
    {text, lowered} = haystack(candidate, haystacks, ctx)

    matches? = &Matcher.compiled_match?(&1, text, lowered, candidate.case_sensitive?)

    cond do
      entry.keywords == [] ->
        {:reject, :no_keywords, dgettext("errors", "keyword entry has no keywords")}

      not Enum.any?(candidate.keywords, matches?) ->
        {:reject, :no_keywords, dgettext("errors", "no primary keyword in the scan window")}

      candidate.secondary_keywords == [] ->
        {:ok, :keyword}

      secondary_satisfied?(entry.secondary_logic, candidate.secondary_keywords, matches?) ->
        {:ok, :keyword}

      true ->
        {:reject, :no_keywords, secondary_logic_detail(entry.secondary_logic)}
    end
  end

  defp secondary_satisfied?(:and_any, keywords, matches?), do: Enum.any?(keywords, matches?)
  defp secondary_satisfied?(:and_all, keywords, matches?), do: Enum.all?(keywords, matches?)
  defp secondary_satisfied?(:not_any, keywords, matches?), do: not Enum.any?(keywords, matches?)
  defp secondary_satisfied?(:not_all, keywords, matches?), do: not Enum.all?(keywords, matches?)

  # The SillyTavern-style mode names stay as the settings store them.
  defp secondary_logic_detail(:and_any), do: dgettext("errors", "secondary logic and_any not satisfied")
  defp secondary_logic_detail(:and_all), do: dgettext("errors", "secondary logic and_all not satisfied")
  defp secondary_logic_detail(:not_any), do: dgettext("errors", "secondary logic not_any not satisfied")
  defp secondary_logic_detail(:not_all), do: dgettext("errors", "secondary logic not_all not satisfied")

  defp book_tag_filter_detail(:include), do: dgettext("errors", "book tag filter include")
  defp book_tag_filter_detail(:exclude), do: dgettext("errors", "book tag filter exclude")
  defp book_tag_filter_detail(:off), do: dgettext("errors", "book tag filter off")

  defp character_filter_detail(:include), do: dgettext("errors", "character filter include")
  defp character_filter_detail(:exclude), do: dgettext("errors", "character filter exclude")
  defp character_filter_detail(:off), do: dgettext("errors", "character filter off")

  # A similarity hit (`vector_matches/6`) activates; otherwise a vector entry's keywords still can,
  # and the rejection carries both verdicts. Keywords see the recursion buffer, similarity does not.
  defp vector_gate(candidate, haystacks, ctx) do
    entry = candidate.entry
    vector_detail = Map.get(ctx.vector.details, entry.id) || dgettext("errors", "not compared")

    cond do
      Map.has_key?(ctx.vector.hits, entry.id) ->
        {:ok, :vector}

      entry.keywords != [] ->
        case keyword_gate(candidate, haystacks, ctx) do
          {:ok, :keyword} -> {:ok, :keyword}
          {:reject, _reason, keyword_detail} -> {:reject, :vector_unmatched, vector_detail <> "; " <> keyword_detail}
        end

      true ->
        {:reject, :vector_unmatched, vector_detail}
    end
  end

  ## Pools

  # SillyTavern's inclusion group picks exactly one winner; a pool generalizes that to
  # `max_activations`. An entry in several pools must win every one of them.
  defp apply_pools(candidates, state, ctx, haystacks) do
    pool_ids = for candidate <- candidates, pe <- candidate.entry.pool_entries, uniq: true, do: pe.lore_pool_id

    {losers, state} =
      Enum.reduce(pool_ids, {MapSet.new(), state}, fn pool_id, {losers, state} ->
        draw_pool(pool_id, candidates, losers, state, ctx, haystacks)
      end)

    {Enum.reject(candidates, &MapSet.member?(losers, &1.entry.id)), state}
  end

  # A member that already lost an earlier pool is out of this draw too, so it cannot take a slot from
  # the members still in contention. The pool row comes from the unfiltered members, so a pool whose
  # members all lost elsewhere still resolves.
  #
  # After sticky members take their slots, as in SillyTavern: scored members whose keys match fewer
  # than the best drop out (group scoring), then override members win by highest order (group
  # override); with none, the weighted draw decides.
  defp draw_pool(pool_id, candidates, losers, state, ctx, haystacks) do
    all_members = Enum.filter(candidates, &pool_member?(&1.entry, pool_id))
    members = Enum.reject(all_members, &MapSet.member?(losers, &1.entry.id))

    pool = Enum.find_value(all_members, &pool_entry_in(&1.entry, pool_id)).pool

    taken = Enum.count(state.activated, &pool_member?(&1.entry, pool_id))
    slots = max(pool.max_activations - taken, 0)

    {sticky, rollable} = Enum.split_with(members, &(&1.reason == :sticky))
    slots_left = max(slots - length(sticky), 0)

    {rollable, state} = score_pool(rollable, sticky, pool, haystacks, state, ctx)

    {winners, pool_losers, detail} =
      case Enum.filter(rollable, &pool_flag?(&1, pool_id, :override)) do
        [] ->
          {winners, pool_losers} = weighted_draw(rollable, pool_id, slots_left, ctx.rng)
          {winners, pool_losers, pool_admits(pool)}

        overrides ->
          picked = overrides |> Enum.sort_by(&{-&1.effective_order, &1.entry.name}) |> Enum.take(slots_left)
          ids = MapSet.new(picked, & &1.entry.id)
          rest = Enum.reject(rollable, &MapSet.member?(ids, &1.entry.id))
          # Slots the overrides leave free go to the weighted draw among the other members.
          {drawn, pool_losers} = weighted_draw(rest, pool_id, slots_left - length(picked), ctx.rng)

          detail =
            if picked == [],
              do: pool_admits(pool),
              else: dgettext("errors", "pool %{pool_name}: an override member won", pool_name: pool.name)

          {picked ++ drawn, pool_losers, detail}
      end

    state = Enum.reduce(pool_losers, state, &reject(&2, &1, :pool_loser, detail))

    winner_ids = MapSet.new(winners ++ sticky, & &1.entry.id)

    losers =
      members
      |> Enum.reject(&MapSet.member?(winner_ids, &1.entry.id))
      |> Enum.reduce(losers, &MapSet.put(&2, &1.entry.id))

    {losers, state}
  end

  defp pool_admits(pool) do
    dgettext("errors", "pool %{pool_name} admits %{activation_limit}",
      pool_name: pool.name,
      activation_limit: Format.number(pool.max_activations)
    )
  end

  defp score_pool(rollable, [], pool, haystacks, state, ctx) do
    if Enum.any?(rollable, &pool_flag?(&1, pool.id, :scored)) do
      scores = Map.new(rollable, &{&1.entry.id, key_score(&1, haystacks, ctx)})
      best = scores |> Map.values() |> Enum.max()

      {low, kept} =
        Enum.split_with(rollable, &(pool_flag?(&1, pool.id, :scored) and scores[&1.entry.id] < best))

      detail = dgettext("errors", "lower keyword score in pool %{pool_name}", pool_name: pool.name)
      {kept, Enum.reduce(low, state, &reject(&2, &1, :pool_loser, detail))}
    else
      {rollable, state}
    end
  end

  defp score_pool(rollable, _sticky, _pool, _haystacks, state, _ctx), do: {rollable, state}

  # SillyTavern's `getScore`: matching primary keys, plus matching secondary keys when the logic is
  # AND ANY, or AND ALL with every secondary key matching. 0 for an entry with no compiled keys.
  defp key_score(%{keywords: primary, secondary_keywords: secondary} = candidate, haystacks, ctx) when primary != [] do
    {text, lowered} = haystack(candidate, haystacks, ctx)
    matches? = &Matcher.compiled_match?(&1, text, lowered, candidate.case_sensitive?)
    p = Enum.count(primary, matches?)
    s = Enum.count(secondary, matches?)

    case candidate.entry.secondary_logic do
      :and_any when secondary != [] -> p + s
      :and_all when s == length(secondary) -> p + s
      _ -> p
    end
  end

  defp key_score(_candidate, _haystacks, _ctx), do: 0

  defp pool_flag?(candidate, pool_id, flag) do
    case pool_entry_in(candidate.entry, pool_id) do
      nil -> false
      pe -> Map.fetch!(pe, flag)
    end
  end

  defp pool_member?(entry, pool_id), do: pool_entry_in(entry, pool_id) != nil

  defp weighted_draw(candidates, _pool_id, slots, _rng) when slots >= length(candidates), do: {candidates, []}

  defp weighted_draw(candidates, _pool_id, 0, _rng), do: {[], candidates}

  # Only weighted members are drawn: a weight-0 member is admitted by the shortcut above when every
  # member fits, but never wins a draw.
  defp weighted_draw(candidates, pool_id, slots, rng) do
    {drawable, zero} = Enum.split_with(candidates, &(weight_in(&1.entry, pool_id) > 0))

    # Winner order is irrelevant (the caller only collects their ids), so each one is prepended.
    {winners, rest} =
      Enum.reduce(1..min(slots, length(drawable))//1, {[], drawable}, fn _, {winners, pool} ->
        {winner, rest} = draw_one(pool, pool_id, rng)
        {[winner | winners], rest}
      end)

    {winners, rest ++ zero}
  end

  # Every candidate here has a positive weight, so `total > 0` and each member owns a non-empty
  # half-open range of it.
  defp draw_one(candidates, pool_id, rng) do
    weights = Enum.map(candidates, &weight_in(&1.entry, pool_id))
    target = rng.() * Enum.sum(weights)

    {winner, _} =
      candidates
      |> Enum.zip(weights)
      |> Enum.reduce_while({nil, 0}, fn {candidate, weight}, {_, acc} ->
        acc = acc + weight
        if acc > target, do: {:halt, {candidate, acc}}, else: {:cont, {candidate, acc}}
      end)

    {winner, Enum.reject(candidates, &(&1.entry.id == winner.entry.id))}
  end

  defp weight_in(entry, pool_id) do
    pe = pool_entry_in(entry, pool_id)
    (pe && pe.weight) || 0
  end

  defp pool_entry_in(entry, pool_id), do: Enum.find(entry.pool_entries, &(&1.lore_pool_id == pool_id))

  ## Probability

  defp apply_probability(candidates, state, ctx) do
    {kept, state} =
      Enum.reduce(candidates, {[], state}, fn %{entry: entry} = candidate, {kept, state} ->
        if candidate.reason == :sticky or entry.probability >= 100 or ctx.rng.() * 100 < entry.probability do
          {[candidate | kept], state}
        else
          state =
            state
            |> reject(
              candidate,
              :probability,
              dgettext("errors", "rolled above %{probability_percent}",
                probability_percent: Format.percent(entry.probability / 100)
              )
            )
            |> Map.update!(:failed_probability, &MapSet.put(&1, entry.id))

          {kept, state}
        end
      end)

    {Enum.reverse(kept), state}
  end

  ## Budget

  # Card-book and trigger-only entries are admitted uncharged: SillyTavern never counts card fields
  # as World Info, and a trigger-only entry is never inserted. Once the global budget overflows,
  # `lore.overflow` `:stop` closes it to everything but ignore-budget entries and forced books.
  defp apply_budget(candidates, state, ctx) do
    global_limit = ctx.defaults.token_budget

    {kept, state} =
      Enum.reduce(candidates, {[], state}, fn candidate, {kept, state} ->
        entry = candidate.entry
        book = candidate.book

        exempt? = entry.trigger_only or book.kind == :card
        closed? = ctx.defaults.overflow == :stop and state.overflowed?

        # Checked before tokenizing: a closed budget rejects without needing the size.
        if not exempt? and closed? and not entry.ignore_budget and not book.forced do
          {kept, reject(state, candidate, :budget, dgettext("errors", "budget closed after an overflow"))}
        else
          size = content_size(entry, state.model)
          candidate = Map.put(candidate, :tokens, size)
          book_used = Map.get(state.used_by_book, book.id, 0)

          # A forced book answers to its own budget only: the global one is the user's setting.
          over_global? = not book.forced and state.used_global + size > global_limit
          over_book? = book.token_budget != nil and book_used + size > book.token_budget

          cond do
            exempt? ->
              {[candidate | kept], state}

            # Both budgets reject, but only the global one is an overflow: it alone ends recursion,
            # and it is what the preview and snapshot report.
            (over_global? or over_book?) and not entry.ignore_budget ->
              detail =
                if over_book?,
                  do: dgettext("errors", "book budget %{token_budget}", token_budget: Format.number(book.token_budget)),
                  else: dgettext("errors", "global budget %{token_budget}", token_budget: Format.number(global_limit))

              state = reject(state, candidate, :budget, detail)
              {kept, if(over_global?, do: %{state | overflowed?: true}, else: state)}

            true ->
              {[candidate | kept], charge(state, book, size, entry.ignore_budget)}
          end
        end
      end)

    {Enum.reverse(kept), state}
  end

  # An ignore-budget entry counts toward the global budget but not its book's (Aikobots' per-book
  # budgets skip it).
  defp charge(state, book, size, ignore_budget?) do
    by_book =
      if ignore_budget?,
        do: state.used_by_book,
        else: Map.update(state.used_by_book, book.id, size, &(&1 + size))

    %{state | used_global: state.used_global + size, used_by_book: by_book}
  end

  defp content_size(entry, model), do: elem(Tokenizer.count(model, entry.content), 0)

  ## Rejections

  defp reject(state, candidate, reason, detail) do
    rejection = %{entry: candidate.entry, book: candidate.book, reason: reason, detail: detail}
    %{state | rejected: [rejection | state.rejected]}
  end
end
