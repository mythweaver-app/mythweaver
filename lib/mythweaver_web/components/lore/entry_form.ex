defmodule MythweaverWeb.Lore.EntryForm do
  @moduledoc """
  The lore entry form, shared by the book table's inline rows and the full-pane entry editor, both
  in `MythweaverWeb.LoreBookLive`.

  A function component plus socket helpers, not a LiveComponent: the LiveView owns the
  `"validate_entry"`/`"save_entry"` events and delegates here, and does its own flashing,
  patching and reloading. An empty Books selection leaves the entry unlinked.

  Memberships join rows of one owner (`Mythweaver.Lore`), so the Books and Pools selects offer only
  those of the entry's owner (`entry_owner`): the edited entry's, a new entry's first book's, or the
  owner `Mythweaver.Ownership.new_owner/2` gives the scope. Each picked pool gets a row for the
  entry's weight and override/scored flags in it (`entry_pool_settings`), saved through
  `Mythweaver.Lore.set_pool_memberships/3` after the Pools. The Pools toolbar's New pool button
  opens `new_pool_modal/1`, which creates a pool of the entry's owner and picks it, unsaved; it is
  hidden on another user's entry (a book shared for editing), whose pools only that user creates.

  An existing entry's form also carries a collapsed Memory group (`entry_memory`, from
  `Mythweaver.Memory.entry_memory/3`): whether it is a memory or a consolidation of some tier, its
  number and a consolidation's sources. Save writes it after the entry through
  `Mythweaver.Memory.set_entry_memory/4`.

  The entry's own tags are `MythweaverWeb.TagFields` under key `:entry` (posted as
  `lore_entry[tags]`); its tag filter (`entry_filter_tags`, texts) joins the character filter and
  saves through `Mythweaver.Lore.set_entry_filter_tags/3`.
  """

  use MythweaverWeb, :html

  import MythweaverWeb.TagFields

  alias Mythweaver.AI
  alias Mythweaver.Characters
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Format
  alias Mythweaver.Lore
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Lore.LorePool
  alias Mythweaver.Memory
  alias Mythweaver.Memory.Record
  alias Mythweaver.Memory.Tiers
  alias Mythweaver.Moderation.Hold
  alias Mythweaver.Ownership
  alias Mythweaver.Prompts
  alias Mythweaver.Prompts.Completions
  alias Mythweaver.Repo
  alias Mythweaver.Tags.Tag
  alias Mythweaver.Tokenizer
  alias MythweaverWeb.EnumLabels
  alias Phoenix.HTML.Form
  alias Phoenix.HTML.FormField
  alias Phoenix.LiveView.Socket

  @new_membership %{"weight" => "100", "override" => false, "scored" => false}

  @doc "Closes the entry form and clears its association assigns."
  @spec clear_entry(Socket.t()) :: Socket.t()
  def clear_entry(socket) do
    socket
    |> assign(
      entry_form: nil,
      editing_entry: nil,
      entry_keywords: [],
      entry_secondary_keywords: [],
      entry_books: [],
      entry_pools: [],
      entry_pool_settings: %{},
      entry_filter_characters: [],
      entry_filter_tags: [],
      entry_owner: nil,
      entry_memory: nil,
      entry_compaction: nil,
      entry_diff: false,
      entry_pool_form: nil
    )
    |> drop_tag_fields(:entry)
  end

  @doc "Loads the option lists the form's selects need."
  @spec assign_options(Socket.t()) :: Socket.t()
  def assign_options(socket) do
    scope = socket.assigns.current_scope

    assign(socket,
      character_options: Characters.character_options(scope),
      books: Lore.list_books(scope),
      pools: Lore.list_pools(scope),
      prompt_outlets: Prompts.outlet_options(scope),
      template_completions: Completions.template(scope),
      token_model: token_model(scope)
    )
  end

  # The model whose tokenizer counts the Content: the scope's default model; nil (an estimate) when
  # none resolves.
  defp token_model(scope) do
    case AI.default_model(scope) do
      {:ok, model} -> model
      {:error, _reason} -> nil
    end
  end

  @doc "Opens a blank entry form whose Books select starts at `book_ids`."
  @spec assign_new_entry(Socket.t(), [Ecto.UUID.t()]) :: Socket.t()
  def assign_new_entry(socket, book_ids) do
    owner = new_entry_owner(socket.assigns.current_scope, book_ids)

    socket
    |> clear_entry()
    |> assign(
      entry_form: to_form(Lore.change_entry(%LoreEntry{})),
      entry_books: book_ids,
      entry_owner: owner
    )
    |> assign_tag_fields(:entry, nil, owner)
  end

  defp new_entry_owner(scope, [book_id | _]) do
    LoreBook
    |> Ownership.editable(scope)
    |> Repo.get(book_id)
    |> case do
      %LoreBook{user_id: owner} -> owner
      nil -> new_entry_owner(scope, [])
    end
  end

  defp new_entry_owner(scope, []) do
    case Ownership.new_owner(scope, LoreEntry) do
      {:ok, owner} -> owner
      {:error, :unauthorized} -> nil
    end
  end

  @doc """
  Opens the form on an existing entry. Its memory group's new record would go in the open book
  (`editing_book`) when the entry is in it.
  """
  @spec assign_edit_entry(Socket.t(), Ecto.Schema.t()) :: Socket.t()
  def assign_edit_entry(socket, entry) do
    preferred = socket.assigns[:editing_book] && socket.assigns.editing_book.id

    socket
    |> assign(
      entry_form: to_form(Lore.change_entry(entry)),
      editing_entry: entry,
      entry_keywords: entry.keywords,
      entry_secondary_keywords: entry.secondary_keywords,
      entry_books: Enum.map(entry.books, & &1.id),
      entry_pools: Enum.map(entry.pools, & &1.id),
      entry_pool_settings: Map.new(entry.pool_entries, &{&1.lore_pool_id, pool_setting(&1)}),
      entry_filter_characters: Enum.map(entry.filter_characters, & &1.id),
      entry_filter_tags: Enum.map(entry.filter_tags, &Tag.text/1),
      entry_owner: entry.user_id,
      entry_memory: memory_state(Memory.entry_memory(socket.assigns.current_scope, entry, preferred)),
      entry_compaction: nil,
      entry_diff: false
    )
    |> assign_tag_fields(:entry, entry, entry.user_id)
  end

  defp pool_setting(membership),
    do: %{"weight" => to_string(membership.weight), "override" => membership.override, "scored" => membership.scored}

  # The stored memory side plus the group's form values, as strings like any other form value;
  # `stored` is those values as loaded, so an untouched group saves nothing.
  defp memory_state(%{record: record} = info) do
    values = %{
      tier: if(record && record.tier, do: to_string(record.tier), else: ""),
      sequence: if(record && record.sequence, do: to_string(record.sequence), else: ""),
      source_ids: info.source_ids
    }

    info |> Map.merge(values) |> Map.put(:stored, values)
  end

  @doc "Whether the memory group is editable: the entry is in a book the scope may edit, and is not a clip or side prompt."
  @spec memory_editable?(map() | nil) :: boolean()
  def memory_editable?(%{book: %LoreBook{}, record: nil}), do: true
  def memory_editable?(%{book: %LoreBook{}, record: %Record{kind: kind}}), do: kind in [:memory, :consolidation]
  def memory_editable?(_memory), do: false

  @doc "Handles a `phx-change`: returns the socket with a validated `entry_form`."
  @spec validate(Socket.t(), map()) :: Socket.t()
  def validate(socket, params) do
    {attrs, socket} = normalize_entry_params(params, socket)

    changeset =
      socket
      |> target_entry()
      |> Lore.change_entry(attrs)
      |> Map.put(:action, :validate)

    assign(socket, entry_form: to_form(changeset))
  end

  @doc """
  Replaces the form's Content with `text`, unsaved: the form keeps every other value it shows and
  is marked edited, so Save writes it and Cancel drops it. Not `validate/2`, whose params would
  reset the books, pools and character filter.
  """
  @spec put_content(Socket.t(), String.t()) :: Socket.t()
  def put_content(socket, text) do
    params = Map.put(socket.assigns.entry_form.source.params || %{}, "content", text)

    changeset =
      socket
      |> target_entry()
      |> Lore.change_entry(params)
      |> Map.put(:action, :validate)

    assign(socket, entry_form: to_form(changeset))
  end

  @doc "Opens the New pool dialog (`new_pool_modal/1`, `entry_pool_form`)."
  @spec open_new_pool(Socket.t()) :: Socket.t()
  def open_new_pool(socket), do: assign(socket, entry_pool_form: to_form(Lore.change_pool(%LorePool{})))

  @doc "Closes the New pool dialog."
  @spec close_new_pool(Socket.t()) :: Socket.t()
  def close_new_pool(socket), do: assign(socket, entry_pool_form: nil)

  @doc "Handles the New pool dialog's `phx-change`."
  @spec validate_new_pool(Socket.t(), map()) :: Socket.t()
  def validate_new_pool(socket, params) do
    changeset = %LorePool{} |> Lore.change_pool(params) |> Map.put(:action, :validate)
    assign(socket, entry_pool_form: to_form(changeset))
  end

  @doc """
  Creates a pool owned by the entry's owner (`entry_owner`; nil: the site's) and picks it in the
  form, unsaved: the entry joins it on Save, like a pool checked by hand. Never flashes; an invalid
  pool keeps the dialog open with its errors. Refused unless the scope would create the pool under
  that owner: an entry of a book shared for editing can't get one, as a pool of the editor's own
  would never share the entry's owner.
  """
  @spec create_new_pool(Socket.t(), map()) ::
          {:ok, LorePool.t(), Socket.t()} | {:invalid, Socket.t()} | {:error, String.t(), Socket.t()}
  def create_new_pool(socket, params) do
    scope = socket.assigns.current_scope
    owner = socket.assigns.entry_owner
    site? = is_nil(owner)

    with {:ok, ^owner} <- Ownership.new_owner(scope, LorePool, site: site?),
         {:ok, pool} <- Lore.create_pool(scope, params, site: site?) do
      socket =
        socket
        |> assign(
          entry_pool_form: nil,
          pools: Lore.list_pools(scope),
          entry_pools: socket.assigns.entry_pools ++ [pool.id],
          entry_pool_settings: Map.put(socket.assigns.entry_pool_settings, pool.id, @new_membership)
        )
        |> mark_edited()

      {:ok, pool, socket}
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:invalid, assign(socket, entry_pool_form: to_form(changeset))}
      _unauthorized -> {:error, unauthorized_message(), close_new_pool(socket)}
    end
  end

  # Marks the form edited with the values it shows, so `UnsavedChanges` asks before leaving.
  defp mark_edited(socket) do
    changeset =
      socket
      |> target_entry()
      |> Lore.change_entry(socket.assigns.entry_form.source.params || %{})
      |> Map.put(:action, :validate)

    assign(socket, entry_form: to_form(changeset))
  end

  @doc """
  Creates or updates the entry, its books, pools, character and tag filters, tags and memory
  settings. Never flashes, patches or reloads; callers do that. `:partial` names what did not save
  (`partial_message/2` turns it into the flash);
  `:held` is an entry kept for moderator review (`Mythweaver.Moderation.Holds`), its books still set
  on an edit.
  """
  @spec save(Socket.t(), map()) ::
          {:ok, Ecto.Schema.t(), Socket.t()}
          | {:partial, Ecto.Schema.t(), partial_reason(), Socket.t()}
          | {:held, Hold.t(), Socket.t()}
          | {:error, String.t(), Socket.t()}
  def save(socket, params) do
    {attrs, socket} = normalize_entry_params(params, socket)

    case socket.assigns.editing_entry do
      nil -> create_entry(socket, attrs)
      entry -> update_entry(socket, entry, attrs)
    end
  end

  defp create_entry(socket, attrs) do
    opts = [followups: tag_followups(socket, :entry, [])]

    case Lore.create_entry(socket.assigns.current_scope, attrs, socket.assigns.entry_books, %{}, opts) do
      {:ok, entry} -> saved(socket, entry)
      {:held, hold} -> {:held, hold, socket}
      {:error, :hold_limit} -> hold_limit(socket)
      {:error, :unauthorized} -> unauthorized(socket)
      {:error, %Ecto.Changeset{} = changeset} -> invalid(socket, changeset)
    end
  end

  defp update_entry(socket, entry, attrs) do
    scope = socket.assigns.current_scope

    case Lore.update_entry(scope, entry, attrs) do
      {:ok, entry} ->
        case Lore.set_entry_books(scope, entry, socket.assigns.entry_books) do
          {:ok, :ok} -> saved(socket, entry)
          {:error, _} -> {:partial, entry, :books, socket}
        end

      # Memberships are not moderated text, so they save at once.
      {:held, hold} ->
        _ = Lore.set_entry_books(scope, entry, socket.assigns.entry_books)
        {:held, hold, socket}

      {:error, :hold_limit} ->
        hold_limit(socket)

      {:error, :unauthorized} ->
        unauthorized(socket)

      {:error, %Ecto.Changeset{} = changeset} ->
        invalid(socket, changeset)
    end
  end

  defp saved(socket, entry) do
    with {:assoc, :ok} <- {:assoc, save_associations(socket, entry)},
         {:ok, socket} <- save_tags(socket, :entry, entry) do
      save_memory(socket, entry)
    else
      {:assoc, :error} -> {:partial, entry, :associations, socket}
      {:error, _what, socket} -> {:partial, entry, :tags, socket}
    end
  end

  defp save_memory(socket, entry) do
    memory = socket.assigns.entry_memory

    if memory_editable?(memory) and memory_changed?(memory) do
      attrs = %{tier: parse_int(memory.tier), sequence: parse_int(memory.sequence), source_ids: memory.source_ids}

      case Memory.set_entry_memory(socket.assigns.current_scope, entry, memory.book, attrs) do
        {:ok, _record} ->
          {:ok, entry, socket}

        {:error, :consolidated} ->
          {:partial, entry, {:memory_source, parent_name(memory.record)}, socket}

        {:error, _reason} ->
          {:partial, entry, :memory, socket}
      end
    else
      {:ok, entry, socket}
    end
  end

  defp memory_changed?(%{stored: stored} = memory) do
    memory.tier != stored.tier or String.trim(memory.sequence) != stored.sequence or
      MapSet.new(memory.source_ids) != MapSet.new(stored.source_ids)
  end

  defp parent_name(%Record{consolidated_into: %Record{entry: %LoreEntry{name: name}}}), do: name
  defp parent_name(_record), do: nil

  @typedoc "What part of a saved entry did not save."
  @type partial_reason() :: :books | :associations | :tags | :memory | {:memory_source, String.t() | nil}

  @doc "The error flash for an entry named `entry_name` that saved except for `reason`."
  @spec partial_message(String.t(), partial_reason()) :: String.t()
  def partial_message(entry_name, :books) do
    gettext_comment("Error flash: a lore entry saved, but its book memberships did not.")
    dgettext("lore", "%{entry_name} saved, but its books did not", entry_name: entry_name)
  end

  def partial_message(entry_name, :associations) do
    gettext_comment("Error flash: a lore entry saved, but its pools or filters did not.")

    dgettext("lore", "%{entry_name} saved, but its pools, character filter or tag filter did not",
      entry_name: entry_name
    )
  end

  def partial_message(entry_name, :tags) do
    gettext_comment("Error flash: a lore entry saved, but its tags did not.")
    dgettext("lore", "%{entry_name} saved, but its tags did not", entry_name: entry_name)
  end

  def partial_message(entry_name, :memory) do
    gettext_comment("Error flash: a lore entry saved, but its Memory Books settings did not.")
    dgettext("lore", "%{entry_name} saved, but its memory settings did not", entry_name: entry_name)
  end

  def partial_message(entry_name, {:memory_source, nil}) do
    gettext_comment(
      "Error flash: a lore entry saved, but its memory settings did not because it was folded into a consolidation."
    )

    dgettext(
      "lore",
      "%{entry_name} saved, but its memory settings (it is a source of another consolidation) did not",
      entry_name: entry_name
    )
  end

  def partial_message(entry_name, {:memory_source, parent_name}) do
    gettext_comment(
      "Error flash: a lore entry saved, but its memory settings did not because it was folded into the consolidation entry named by parent_name."
    )

    dgettext("lore", "%{entry_name} saved, but its memory settings (it is a source of “%{parent_name}”) did not",
      entry_name: entry_name,
      parent_name: parent_name
    )
  end

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_int(_value), do: nil

  defp invalid(socket, changeset) do
    gettext_comment("Flash when saving an editor form fails validation; the invalid fields are highlighted.")

    {:error, dgettext("lore", "Could not save — see the highlighted fields"),
     assign(socket, entry_form: to_form(changeset))}
  end

  defp unauthorized(socket), do: {:error, unauthorized_message(), socket}

  defp hold_limit(socket) do
    gettext_comment("Error flash when the user has too many items waiting for moderator review to save another.")

    {:error,
     dgettext(
       "lore",
       "You have too much waiting for review. Withdraw something on the Submissions page or wait for a decision."
     ), socket}
  end

  # `set_entry_pools/2`, `set_entry_filter_characters/2` and `set_entry_filter_tags/3` each run their
  # own transaction and can reject a join row; swallowing that is how a save silently half-applies.
  # The pool settings go after `set_entry_pools/2`, so a just-picked pool's membership exists.
  defp save_associations(socket, entry) do
    scope = socket.assigns.current_scope

    results = [
      Lore.set_entry_pools(scope, entry, socket.assigns.entry_pools),
      Lore.set_pool_memberships(scope, entry, pool_memberships(socket.assigns.entry_pool_settings)),
      Lore.set_entry_filter_characters(scope, entry, socket.assigns.entry_filter_characters),
      Lore.set_entry_filter_tags(scope, entry, socket.assigns.entry_filter_tags)
    ]

    if Enum.all?(results, &match?({:ok, _}, &1)), do: :ok, else: :error
  end

  # A blank or negative weight keeps the stored one.
  defp pool_memberships(settings) do
    Map.new(settings, fn {pool_id, %{"weight" => weight, "override" => override, "scored" => scored}} ->
      attrs = %{override: override, scored: scored}

      case parse_int(weight) do
        n when is_integer(n) and n >= 0 -> {pool_id, Map.put(attrs, :weight, n)}
        _ -> {pool_id, attrs}
      end
    end)
  end

  # One normalization used by both "validate" and "save": the keyword chip lists drop their empty
  # sentinel, and they, the association multi-selects and the tag lists are lifted into assigns
  # (the associations are not `LoreEntry` fields, and keeping them in assigns is what makes the
  # selects and the chips survive a `phx-change` re-render).
  #
  # Cleared inputs (`""`) need no mapping: `Ecto.Changeset.cast/3` already resolves `""` to the
  # field's default, which is `nil` for every optional here: the tri-state booleans
  # (`case_sensitive`, `match_whole_words`) and the optional integers (`depth`, `sticky`,
  # `cooldown`, `delay`, `scan_depth`).
  defp normalize_entry_params(params, socket) do
    pools = drop_blank(params["pools"])
    keywords = params |> Map.get("keywords", socket.assigns.entry_keywords) |> keyword_list()
    secondary = params |> Map.get("secondary_keywords", socket.assigns.entry_secondary_keywords) |> keyword_list()

    socket =
      socket
      |> assign(
        entry_keywords: keywords,
        entry_secondary_keywords: secondary,
        entry_books: drop_blank(params["books"]),
        entry_pools: pools,
        entry_pool_settings: pool_settings(pools, params["pool_settings"], socket.assigns.entry_pool_settings),
        entry_filter_characters: drop_blank(params["filter_characters"]),
        entry_filter_tags: params["filter_tags"] |> List.wrap() |> Enum.reject(&(&1 == "")),
        entry_memory: memory_params(socket.assigns.entry_memory, params["memory"])
      )
      |> put_tag_params(:entry, params["tags"])

    attrs =
      params
      |> Map.drop(["books", "pools", "pool_settings", "filter_characters", "filter_tags", "tags", "memory"])
      |> Map.put("keywords", keywords)
      |> Map.put("secondary_keywords", secondary)

    {attrs, socket}
  end

  # Each picked pool's posted settings, else the ones it had, else a new membership's defaults.
  defp pool_settings(pool_ids, posted, current) do
    posted = if is_map(posted), do: posted, else: %{}

    Map.new(pool_ids, fn id ->
      setting =
        case posted[id] do
          %{} = p ->
            %{"weight" => p["weight"] || "", "override" => p["override"] == "true", "scored" => p["scored"] == "true"}

          _ ->
            Map.get(current, id, @new_membership)
        end

      {id, setting}
    end)
  end

  # The memory group's values. Picking another tier clears a number left from the old one, so the
  # record is numbered in its new tier unless one is typed.
  defp memory_params(%{} = memory, %{} = params) do
    tier = Map.get(params, "tier", memory.tier)
    sequence = Map.get(params, "sequence", memory.sequence)
    sequence = if tier != memory.tier and sequence == memory.sequence, do: "", else: sequence
    %{memory | tier: tier, sequence: sequence, source_ids: drop_blank(params["source_ids"])}
  end

  defp memory_params(memory, _params), do: memory

  # Each picker posts a `""` sentinel so an all-unchecked list still submits.
  defp drop_blank(ids), do: ids |> List.wrap() |> Enum.reject(&(&1 == ""))

  # A keyword chip input's posted list, without its empty sentinel.
  defp keyword_list(list) when is_list(list), do: Enum.reject(list, &(&1 == ""))
  defp keyword_list(_none), do: []

  @doc "A field's errors once the user has touched it."
  def field_errors(%FormField{} = field),
    do: if(used_input?(field), do: Enum.map(field.errors, &translate_error/1), else: [])

  defp target_entry(socket), do: socket.assigns.editing_entry || %LoreEntry{}

  defp tri_state(nil), do: ""
  defp tri_state(true), do: "true"
  defp tri_state(false), do: "false"
  defp tri_state(other), do: to_string(other)

  # The form value is a string mid-`phx-change` and an atom when loaded from a row.
  defp outlet_is?(value, name), do: to_string(value) == name

  # `at_depth` positions by depth number and `custom` by outlet name; neither has a before/after axis.
  defp placement_ignored?(value), do: outlet_is?(value, "at_depth") or outlet_is?(value, "custom")

  defp tier_options, do: [{not_a_memory(), ""} | for(tier <- 0..6, do: {Tiers.label(tier), to_string(tier)})]

  # Both Type selects (editable, and the disabled one shown for a consolidated source) share it.
  defp tier_hint,
    do:
      dgettext(
        "lore",
        "A scene memory, or a consolidation tier (Arc and up) that summarizes memories one tier below. A source's type is set by what it was consolidated into."
      )

  # The tier a consolidation of the chosen tier draws from; nil for no memory or a scene memory.
  defp source_tier(%{tier: tier}) do
    case Integer.parse(tier) do
      {n, ""} when n in 1..6 -> n - 1
      _ -> nil
    end
  end

  defp consolidated?(%{record: %Record{consolidated_into_id: parent}}), do: is_binary(parent)
  defp consolidated?(_memory), do: false

  # The summary line's note on what the entry is now, as stored.
  defp memory_summary(%{record: nil}), do: not_a_memory()

  defp memory_summary(%{record: %Record{kind: :memory, sequence: n}}) when is_integer(n),
    do:
      dpgettext("lore", "status: lore entry is a numbered scene memory", "Scene memory #%{memory_number}",
        memory_number: Format.number(n)
      )

  defp memory_summary(%{record: %Record{kind: :memory}}),
    do: dpgettext("lore", "status: lore entry is a scene memory", "Scene memory")

  defp memory_summary(%{record: %Record{kind: :consolidation, tier: tier, sequence: n}}) when is_integer(n) do
    gettext_comment("tier_name is a memory tier name such as Arc or Chapter.")

    dpgettext(
      "lore",
      "status: lore entry is a numbered consolidation of a memory tier",
      "%{tier_name} #%{memory_number}",
      tier_name: Tiers.label(tier),
      memory_number: Format.number(n)
    )
  end

  defp memory_summary(%{record: %Record{kind: :consolidation, tier: tier}}), do: Tiers.label(tier)

  defp memory_summary(%{record: %Record{kind: kind}}) when kind in [:clip, :topical_clip],
    do: dpgettext("lore", "status: lore entry is a memory clip", "Clip")

  defp memory_summary(%{record: %Record{kind: :side_prompt}}),
    do: dpgettext("lore", "status: lore entry is written by a side prompt", "Side prompt")

  defp message_range(%Record{range_start: first, range_end: last}) when is_integer(first) and is_integer(last),
    do:
      dpgettext("lore", "status: chat message numbers a memory covers", "#%{first_message}–#%{last_message}",
        first_message: Format.number(first + 1),
        last_message: Format.number(last + 1)
      )

  defp message_range(_record), do: dpgettext("lore", "status: memory covers no chat messages", "None")

  attr :form, Form, required: true
  attr :keywords, :list, required: true
  attr :secondary_keywords, :list, required: true
  attr :entry_books, :list, required: true
  attr :entry_pools, :list, required: true

  attr :entry_pool_settings, :map,
    required: true,
    doc: ~s(each picked pool's `%{"weight" => text, "override" => bool, "scored" => bool}`, by pool id)

  attr :entry_filter_characters, :list, required: true
  attr :entry_filter_tags, :list, required: true, doc: "the tag filter's texts"
  attr :tag_field, :map, required: true, doc: "the entry's `tag_fields` entry (`MythweaverWeb.TagFields`, key `:entry`)"
  attr :tag_vocabulary, :list, required: true
  attr :viewer_id, :string, required: true, doc: "the current user's id, for the pickers' tag filters"
  attr :tag_graph, :any, required: true, doc: "the viewer's tag graph (`MythweaverWeb.TagFilter`)"
  attr :character_options, :list, required: true
  attr :books, :list, required: true
  attr :pools, :list, required: true
  attr :owner, :any, required: true, doc: "the entry's owner id (nil: site); only its books and pools are offered"
  attr :prompt_outlets, :list, required: true
  attr :completions, :map, required: true
  attr :cancel, :string, required: true
  attr :inset, :boolean, default: false, doc: "draw it as an inset box inside another section"
  attr :heading, :boolean, default: true, doc: "false inside a row that already names the entry"

  attr :memory, :map,
    default: nil,
    doc: "the entry's memory group state (`entry_memory`); nil hides the group (a new entry)"

  attr :compacting, :boolean, default: false, doc: "a Compact of the content is under way"

  attr :diff, :boolean,
    default: false,
    doc: "show a saved entry's stored Content against the form's, word by word"

  attr :token_model, :any,
    default: nil,
    doc: "the `Mythweaver.AI.Model` whose tokenizer counts the Content; nil estimates"

  def entry_form(assigns) do
    assigns = assign(assigns, :content_tokens, Tokenizer.count(assigns.token_model, assigns.form[:content].value))

    ~H"""
    <%!--
      `lower-bound="none"`: rules here may reach inside `<.input>`'s own template,
      which is a nested-component root carrying `phx-r` that the default exclusive bound cuts off.
      With no lower bound every element carrying this block's scope marker is a scope root, so the
      root rule is qualified as `div.lore-entry-editor--inset:scope`.
    --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      div.lore-entry-editor--inset:scope {
        background: var(--surface-2);
        border: 1px solid var(--border-grey);
        border-radius: var(--radius-2);
        padding: var(--size-3);
      }

      .lore-entry-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-3);
      }

      .lore-entry-form label {
        display: block;
      }

      /* The filter mode select stacks above the filter tags inside one row cell, so the cell is
         about as tall as the row's lists and their bottoms line up. */
      .lore-entry-group {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .lore-entry-content-actions {
        display: flex;
        justify-content: flex-end;
        gap: var(--size-2);
      }

      .lore-entry-diff {
        padding: var(--size-2);
        border: 1px solid var(--border-grey);
        border-radius: var(--radius-2);
        background: var(--surface-1);
      }

      .lore-entry-memory summary {
        cursor: pointer;
        font-weight: 600;
      }

      .lore-entry-memory > * + * {
        margin-block-start: var(--size-2);
      }

      .lore-entry-memory-current {
        margin-inline-start: var(--size-2);
        color: var(--muted-foreground);
        font-weight: normal;
      }

      .lore-entry-memory-help {
        margin: 0;
        color: var(--muted-foreground);
        font-size: 0.85rem;
      }

      .lore-entry-memory-facts {
        display: grid;
        grid-template-columns: max-content 1fr;
        gap: var(--size-1) var(--size-3);
        margin: 0;
        font-size: 0.85rem;
      }

      .lore-entry-memory-facts dt {
        margin: 0;
        color: var(--muted-foreground);
      }

      .lore-entry-memory-facts dd {
        margin: 0;
      }

      /* One line per picked pool: its name, then its weight and flags. The rows share the grid's
         columns (subgrid), so the inputs line up from row to row. On a phone the name heads its
         row and the inputs go on the line below. */
      .lore-entry-pool-settings {
        display: grid;
        grid-template-columns: minmax(0, 1fr) auto auto auto;
        gap: var(--size-2);
        align-items: center;
        margin-block-start: var(--size-2);
      }

      .lore-entry-pool-row {
        display: grid;
        grid-column: 1 / -1;
        grid-template-columns: subgrid;
        align-items: center;
      }

      .lore-entry-pool-name {
        overflow-wrap: anywhere;
      }

      @media (--phone) {
        .lore-entry-pool-settings {
          grid-template-columns: auto auto auto;
        }

        .lore-entry-pool-name {
          grid-column: 1 / -1;
        }
      }

      .lore-entry-pool-settings .input {
        inline-size: 6rem;
      }

      .lore-entry-pool-settings-help {
        grid-column: 1 / -1;
        margin: 0;
        color: var(--muted-foreground);
        font-size: 0.85rem;
      }
    </style>
    <div class={["lore-entry-editor", @inset && "lore-entry-editor--inset"]}>
      <.form
        for={@form}
        id="lore-entry-form"
        class="lore-entry-form"
        phx-hook="UnsavedChanges"
        data-saved={is_nil(@form.action)}
        phx-change="validate_entry"
        phx-submit="save_entry"
      >
        <.section_header :if={@heading}>
          {dpgettext("lore", "heading: lore entry form", "Entry")}
        </.section_header>

        <.field_row id="lore-entry-form-identity-row">
          <:field size="wide">
            <.input
              field={@form[:name]}
              type="text"
              label={dpgettext("lore", "field label: name of a lore entry", "Name")}
              id="lore-entry-form-name"
              required
            >
              <:hint>
                {dgettext("lore", "The entry's name in lists. It is never sent to the model.")}
              </:hint>
            </.input>
          </:field>
          <:field>
            <.input
              field={@form[:activation]}
              type="select"
              label={dpgettext("lore", "field label: how a lore entry activates", "Activation")}
              options={EnumLabels.values(LoreEntry, :activation)}
              id="lore-entry-form-activation"
            >
              <:hint>
                {rich(
                  dgettext(
                    "lore",
                    "%{keyword} activates when a keyword appears in the scanned messages. %{constant} is always included, subject to its other conditions (probability, delay, cooldown, character filter, budget). %{vector} activates when the scanned messages are close in meaning to the entry's content (Settings › Lore › Vector matching), or on its keywords if it has any.",
                    keyword: strong(EnumLabels.label(LoreEntry, :activation, :keyword)),
                    constant: strong(EnumLabels.label(LoreEntry, :activation, :constant)),
                    vector: strong(EnumLabels.label(LoreEntry, :activation, :vector))
                  )
                )}
              </:hint>
            </.input>
          </:field>
          <:field>
            <.input
              field={@form[:probability]}
              type="number"
              label={
                dpgettext(
                  "lore",
                  "field label: chance in percent that a lore entry is used",
                  "Probability %"
                )
              }
              id="lore-entry-form-probability"
              min="0"
              max="100"
            >
              <:hint>
                {dgettext(
                  "lore",
                  "The chance, in percent, that the entry is used once its conditions are met. 100 always activates. A sticky entry skips the roll while it sticks."
                )}
              </:hint>
            </.input>
          </:field>
        </.field_row>

        <.field_row id="lore-entry-form-keywords-row">
          <:field size="wide">
            <.tag_input
              id="lore-entry-form-keywords"
              name="lore_entry[keywords][]"
              mode="keywords"
              label={dpgettext("lore", "field label: primary keywords of a lore entry", "Keywords")}
              placeholder={dgettext("lore", "Type a keyword, then Enter or comma")}
              values={@keywords}
              errors={field_errors(@form[:keywords])}
            >
              <:hint>
                {rich(
                  dgettext(
                    "lore",
                    "Words that activate the entry when any one appears in the scanned messages. Write %{regex_syntax} for a regular expression. Required for keyword activation; optional for vector.",
                    regex_syntax: code("/pattern/flags")
                  )
                )}
              </:hint>
            </.tag_input>
          </:field>
          <:field>
            <.input
              field={@form[:secondary_logic]}
              type="select"
              label={logic_label()}
              options={[
                {logic_option(:and_any), :and_any},
                {logic_option(:and_all), :and_all},
                {logic_option(:not_any), :not_any},
                {logic_option(:not_all), :not_all}
              ]}
              id="lore-entry-form-secondary_logic"
            >
              <:hint>
                {rich(
                  dgettext(
                    "lore",
                    "How the secondary keywords filter a primary match. %{and_any}: at least one also appears. %{and_all}: every one appears. %{not_any}: none appear. %{not_all}: not every one appears. Ignored when there are no secondary keywords.",
                    and_any: strong(logic_option(:and_any)),
                    and_all: strong(logic_option(:and_all)),
                    not_any: strong(logic_option(:not_any)),
                    not_all: strong(logic_option(:not_all))
                  )
                )}
              </:hint>
            </.input>
          </:field>
          <:field size="wide">
            <.tag_input
              id="lore-entry-form-secondary_keywords"
              name="lore_entry[secondary_keywords][]"
              mode="keywords"
              label={
                dpgettext(
                  "lore",
                  "field label: secondary keywords of a lore entry",
                  "Secondary keywords"
                )
              }
              placeholder={
                dpgettext(
                  "lore",
                  "placeholder: secondary keywords of a lore entry are optional",
                  "Optional filter"
                )
              }
              values={@secondary_keywords}
              errors={field_errors(@form[:secondary_keywords])}
            >
              <:hint>
                {rich(
                  dgettext(
                    "lore",
                    "An optional second keyword list, checked with %{logic} after a primary keyword matches. Leave it empty to activate on the primary keywords alone.",
                    logic: em(logic_label())
                  )
                )}
              </:hint>
            </.tag_input>
          </:field>
        </.field_row>

        <.field_row id="lore-entry-form-matching-row">
          <:field>
            <.input
              field={@form[:scan_depth]}
              type="number"
              label={
                dpgettext(
                  "lore",
                  "field label: how many recent messages a lore entry scans",
                  "Scan depth"
                )
              }
              placeholder={
                dpgettext(
                  "lore",
                  "placeholder: empty scan depth uses the lore book's",
                  "Book default"
                )
              }
              id="lore-entry-form-scan_depth"
              min="1"
            >
              <:hint>
                {dgettext(
                  "lore",
                  "How many recent messages to search for this entry's keywords, or to compare a vector entry against. Empty uses the book's scan depth, then the global setting."
                )}
              </:hint>
            </.input>
          </:field>
          <:field>
            <.input
              field={@form[:case_sensitive]}
              type="select"
              label={
                dpgettext(
                  "lore",
                  "field label: whether lore keywords match letter case",
                  "Case sensitive"
                )
              }
              options={tri_state_options()}
              value={tri_state(@form[:case_sensitive].value)}
              id="lore-entry-form-case_sensitive"
            >
              <:hint>
                {rich(
                  dgettext(
                    "lore",
                    "Whether keywords must match letter case. %{default} follows the global setting. A regular expression's own flags take precedence.",
                    default: em(tri_default())
                  )
                )}
              </:hint>
            </.input>
          </:field>
          <:field>
            <.input
              field={@form[:match_whole_words]}
              type="select"
              label={
                dpgettext(
                  "lore",
                  "field label: whether lore keywords match whole words only",
                  "Whole words"
                )
              }
              options={tri_state_options()}
              value={tri_state(@form[:match_whole_words].value)}
              id="lore-entry-form-match_whole_words"
            >
              <:hint>
                {rich(
                  dgettext(
                    "lore",
                    "Whether a single-word keyword must match a whole word (%{short_word} won't match %{long_word}). Keywords with spaces always match as plain text. %{default} follows the global setting.",
                    short_word: code("cat"),
                    long_word: code("category"),
                    default: em(tri_default())
                  )
                )}
              </:hint>
            </.input>
          </:field>
          <:field size="column">
            <.input
              field={@form[:exclude_recursion]}
              type="checkbox"
              label={dgettext("lore", "Cannot be activated by recursion")}
              id="lore-entry-form-exclude_recursion"
            >
              <:hint>
                {dgettext(
                  "lore",
                  "The entry activates only from the chat messages, never from the text of other activated entries."
                )}
              </:hint>
            </.input>
            <.input
              field={@form[:prevent_recursion]}
              type="checkbox"
              label={dgettext("lore", "Content does not feed recursion")}
              id="lore-entry-form-prevent_recursion"
            >
              <:hint>
                {dgettext(
                  "lore",
                  "This entry's text is not searched for other entries' keywords, so it cannot activate them."
                )}
              </:hint>
            </.input>
            <.input
              field={@form[:ignore_budget]}
              type="checkbox"
              label={
                dpgettext(
                  "lore",
                  "field label: lore entry is never dropped for the token budget",
                  "Ignore budget"
                )
              }
              id="lore-entry-form-ignore_budget"
            >
              <:hint>
                {dgettext(
                  "lore",
                  "Never dropped for exceeding the global or book token budget. Its tokens still count toward the global budget, but not its book's."
                )}
              </:hint>
            </.input>
            <.input
              field={@form[:trigger_only]}
              type="checkbox"
              label={
                dgettext(
                  "lore",
                  "Trigger only (activates and triggers other entries, never inserted)"
                )
              }
              id="lore-entry-form-trigger_only"
            >
              <:hint>
                {dgettext(
                  "lore",
                  "The entry activates as usual, so its text can trigger other entries and it counts toward its pools, but its text never goes into the prompt or the budget."
                )}
              </:hint>
            </.input>
          </:field>
        </.field_row>

        <.editor
          field={@form[:content]}
          label={dpgettext("lore", "field label: text of a lore entry", "Content")}
          rows={8}
          id="lore-entry-form-content"
          language="liquid"
          spellcheck
          completions={@completions}
        >
          <:meta>
            <span
              id="lore-entry-form-content-tokens"
              title={token_title(@content_tokens, @token_model)}
            >
              {token_label(@content_tokens)}
            </span>
          </:meta>
          <:hint>
            {dgettext(
              "lore",
              "The text added to the prompt when the entry activates. It is a Liquid template, so it can read variables and outlets."
            )}
          </:hint>
        </.editor>
        <.word_diff
          :if={@diff and @form.data.id != nil}
          id="lore-entry-form-diff"
          class="lore-entry-diff"
          old={@form.data.content}
          new={@form[:content].value}
        />
        <div class="lore-entry-content-actions">
          <.button
            :if={@form.data.id != nil}
            size="sm"
            id="lore-entry-form-diff-toggle"
            phx-click="toggle_entry_diff"
            aria-pressed={to_string(@diff)}
          >
            <.lucide name="git-compare" /> {dpgettext(
              "lore",
              "toggle: show changes to a lore entry's text",
              "Diff"
            )}
          </.button>
          <.button
            size="sm"
            id="lore-entry-form-compact"
            phx-click="compact_entry"
            disabled={@compacting}
          >
            <.lucide name="shrink" /> {dpgettext(
              "lore",
              "button: shorten a lore entry's text with the model",
              "Compact"
            )}
          </.button>
        </div>

        <.field_row id="lore-entry-form-placement-row">
          <:field>
            <.input
              field={@form[:outlet]}
              type="select"
              label={
                dpgettext("lore", "field label: where a lore entry's text is inserted", "Outlet")
              }
              options={EnumLabels.values(LoreEntry, :outlet)}
              id="lore-entry-form-outlet"
            >
              <:hint>
                {dgettext(
                  "lore",
                  "Where the content goes in the prompt: next to the character description, the example dialogue or the author's note, into the chat history at a set depth, or into a custom prompt outlet."
                )}
              </:hint>
            </.input>
          </:field>
          <:field :if={outlet_is?(@form[:outlet].value, "custom")}>
            <.input
              field={@form[:custom_outlet]}
              type="select"
              label={
                dpgettext(
                  "lore",
                  "field label: custom prompt outlet of a lore entry",
                  "Custom outlet"
                )
              }
              prompt={dpgettext("lore", "option: no custom prompt outlet picked", "Choose an outlet")}
              options={@prompt_outlets}
              id="lore-entry-form-custom_outlet"
            >
              <:hint>
                {dgettext(
                  "lore",
                  "The prompt outlet that collects this entry's content. A prompt block shows it where it reads that outlet."
                )}
              </:hint>
            </.input>
          </:field>
          <:field>
            <.input
              field={@form[:placement]}
              type="select"
              label={dpgettext("lore", "field label: before or after the outlet's text", "Placement")}
              options={EnumLabels.values(LoreEntry, :placement)}
              id="lore-entry-form-placement"
              disabled={placement_ignored?(@form[:outlet].value)}
            >
              <:hint>
                {rich(
                  dgettext(
                    "lore",
                    "Whether the content goes before or after the outlet's own text. Not used for %{at_depth} or %{custom}.",
                    at_depth: em(EnumLabels.label(LoreEntry, :outlet, :at_depth)),
                    custom: em(EnumLabels.label(LoreEntry, :outlet, :custom))
                  )
                )}
              </:hint>
            </.input>
          </:field>
          <:field>
            <.input
              field={@form[:depth]}
              type="number"
              label={dpgettext("lore", "field label: insertion depth of a lore entry", "Depth")}
              placeholder={
                dpgettext(
                  "lore",
                  "placeholder: depth applies only to the at-depth outlet",
                  "At depth only"
                )
              }
              id="lore-entry-form-depth"
              min="0"
            >
              <:hint>
                {rich(
                  dgettext(
                    "lore",
                    "For %{at_depth}: how many messages from the end of the chat history the content goes. Empty uses the global %{default_depth_setting}.",
                    at_depth: em(EnumLabels.label(LoreEntry, :outlet, :at_depth)),
                    default_depth_setting:
                      em(
                        dpgettext(
                          "lore",
                          "field label: global default insertion depth setting",
                          "Default insertion depth"
                        )
                      )
                  )
                )}
              </:hint>
            </.input>
          </:field>
          <:field :if={outlet_is?(@form[:outlet].value, "at_depth")}>
            <.input
              field={@form[:role]}
              type="select"
              label={
                dpgettext("lore", "field label: chat role a lore entry's text is sent as", "Role")
              }
              options={[
                {dpgettext("lore", "option: chat message role", "System"), :system},
                {dpgettext("lore", "option: chat message role", "User"), :user},
                {dpgettext("lore", "option: chat message role", "Assistant"), :assistant}
              ]}
              id="lore-entry-form-role"
            >
              <:hint>
                {dgettext("lore", "The message role the content is sent as in the chat history.")}
              </:hint>
            </.input>
          </:field>
          <:field>
            <.input
              field={@form[:sticky]}
              type="number"
              label={
                dpgettext(
                  "lore",
                  "field label: how many more messages a lore entry stays active",
                  "Sticky turns"
                )
              }
              placeholder={dpgettext("lore", "placeholder: empty sticky turns", "Not sticky")}
              id="lore-entry-form-sticky"
              min="1"
            >
              <:hint>
                {dgettext(
                  "lore",
                  "After activating, the entry stays active for this many more messages, even without its keywords. Empty means not sticky."
                )}
              </:hint>
            </.input>
          </:field>
          <:field>
            <.input
              field={@form[:cooldown]}
              type="number"
              label={
                dpgettext(
                  "lore",
                  "field label: messages a lore entry waits before activating again",
                  "Cooldown turns"
                )
              }
              placeholder={dpgettext("lore", "placeholder: empty cooldown turns", "No cooldown")}
              id="lore-entry-form-cooldown"
              min="1"
            >
              <:hint>
                {dgettext(
                  "lore",
                  "After the entry activates (and after its sticky turns end), it cannot activate again for this many messages. Empty means no cooldown."
                )}
              </:hint>
            </.input>
          </:field>
          <:field>
            <.input
              field={@form[:delay]}
              type="number"
              label={
                dpgettext(
                  "lore",
                  "field label: messages a chat needs before a lore entry can activate",
                  "Delay (messages)"
                )
              }
              placeholder={dpgettext("lore", "placeholder: empty activation delay", "No delay")}
              id="lore-entry-form-delay"
              min="1"
            >
              <:hint>
                {dgettext(
                  "lore",
                  "The entry cannot activate until the chat has at least this many messages."
                )}
              </:hint>
            </.input>
          </:field>
          <:field>
            <.input
              field={@form[:delay_until_recursion]}
              type="number"
              label={dgettext("lore", "Delay until recursion level (0 = off)")}
              id="lore-entry-form-delay_until_recursion"
              min="0"
            >
              <:hint>
                {dgettext(
                  "lore",
                  "The entry activates only on a recursion pass, never from the chat messages alone. A higher level waits until lower levels have activated nothing more."
                )}
              </:hint>
            </.input>
          </:field>
        </.field_row>

        <.field_row id="lore-entry-form-tags-row">
          <:field>
            <.tag_fields
              id="lore-entry-form-tags"
              prefix="lore_entry[tags]"
              field={@tag_field}
              vocabulary={@tag_vocabulary}
            />
          </:field>
        </.field_row>

        <.field_row id="lore-entry-form-filters-row" align="start">
          <:field class="lore-entry-group">
            <.input
              field={@form[:character_filter_mode]}
              type="select"
              label={
                dpgettext("lore", "field label: lore entry character filter mode", "Character filter")
              }
              options={EnumLabels.values(LoreEntry, :character_filter_mode)}
              id="lore-entry-form-character_filter_mode"
            >
              <:hint>
                {rich(
                  dgettext(
                    "lore",
                    "%{include}: activates only in chats where a filter character, or a character with a filter tag, takes part. %{exclude}: never in those chats. This checks who is in the chat, not who is replying. %{off} ignores both lists.",
                    include: strong(EnumLabels.label(LoreEntry, :character_filter_mode, :include)),
                    exclude: strong(EnumLabels.label(LoreEntry, :character_filter_mode, :exclude)),
                    off: strong(EnumLabels.label(LoreEntry, :character_filter_mode, :off))
                  )
                )}
              </:hint>
            </.input>
            <.tag_input
              id="lore-entry-form-filter_tags"
              name="lore_entry[filter_tags][]"
              label={
                dpgettext(
                  "lore",
                  "field label: character tags a lore entry's filter checks",
                  "Filter tags"
                )
              }
              values={@entry_filter_tags}
              vocabulary={@tag_vocabulary}
            >
              <:hint>
                {dgettext("lore", "Characters with any of these tags count as filter characters.")}
              </:hint>
            </.tag_input>
          </:field>
          <:field size="wide">
            <.live_component
              module={MythweaverWeb.MultiSelect}
              id="lore-entry-form-filter_characters"
              name="lore_entry[filter_characters][]"
              label={
                dpgettext(
                  "lore",
                  "field label: characters a lore entry's filter checks",
                  "Filter characters"
                )
              }
              options={@character_options}
              selected={@entry_filter_characters}
              empty={
                dpgettext(
                  "lore",
                  "empty state: no characters to pick for a lore filter",
                  "No characters yet"
                )
              }
              tag_kind={:character}
              viewer_id={@viewer_id}
              tag_graph={@tag_graph}
              tag_vocabulary={@tag_vocabulary}
            >
              <:hint>
                {dgettext(
                  "lore",
                  "The characters the character filter checks for. Unused when the filter is off."
                )}
              </:hint>
            </.live_component>
          </:field>
          <:field size="wide">
            <.live_component
              module={MythweaverWeb.MultiSelect}
              id="lore-entry-form-books"
              name="lore_entry[books][]"
              label={dpgettext("lore", "field label: lore books an entry belongs to", "Books")}
              options={for b <- @books, b.user_id == @owner, do: {b.name, b.id}}
              selected={@entry_books}
              empty={dpgettext("lore", "empty state: no lore books exist", "No books yet")}
              tag_kind={:lore_book}
              viewer_id={@viewer_id}
              tag_graph={@tag_graph}
              tag_vocabulary={@tag_vocabulary}
            >
              <:hint>
                {dgettext(
                  "lore",
                  "The books this entry belongs to. An entry in no book never activates. Its order and on/off switch are set per book, in each book's entry list."
                )}
              </:hint>
            </.live_component>
          </:field>
          <:field size="wide">
            <.live_component
              module={MythweaverWeb.MultiSelect}
              id="lore-entry-form-pools"
              name="lore_entry[pools][]"
              label={dpgettext("lore", "field label: lore pools an entry belongs to", "Pools")}
              options={for p <- @pools, p.user_id == @owner, do: {p.name, p.id}}
              selected={@entry_pools}
              empty={dpgettext("lore", "empty state: no lore pools exist", "No pools yet")}
            >
              <:hint>
                {dgettext(
                  "lore",
                  "Pools limit how many of their entries can activate at once by drawing among the candidates. An entry in several pools must be drawn in each one."
                )}
              </:hint>
              <:toolbar>
                <.button
                  :if={@owner in [nil, @viewer_id]}
                  type="button"
                  size="sm"
                  id="lore-entry-form-new-pool"
                  phx-click="new_entry_pool"
                >
                  <.lucide name="plus" /> {dpgettext("lore", "button: create a lore pool", "New pool")}
                </.button>
              </:toolbar>
            </.live_component>
            <div
              :if={@entry_pools != []}
              id="lore-entry-form-pool-settings"
              class="lore-entry-pool-settings"
            >
              <div
                :for={pool <- Enum.filter(@pools, &(&1.id in @entry_pools))}
                id={"lore-entry-form-pool-#{pool.id}"}
                class="lore-entry-pool-row"
              >
                <span class="lore-entry-pool-name">{pool.name}</span>
                <.input
                  type="number"
                  name={"lore_entry[pool_settings][#{pool.id}][weight]"}
                  id={"lore-entry-form-pool-#{pool.id}-weight"}
                  value={@entry_pool_settings[pool.id]["weight"]}
                  min="0"
                  label={
                    dpgettext("lore", "field label: draw weight of an entry in a lore pool", "Weight")
                  }
                />
                <.input
                  type="checkbox"
                  name={"lore_entry[pool_settings][#{pool.id}][override]"}
                  id={"lore-entry-form-pool-#{pool.id}-override"}
                  value={@entry_pool_settings[pool.id]["override"]}
                  label={
                    dpgettext("lore", "field label: pool entry overrides the pool limit", "Override")
                  }
                />
                <.input
                  type="checkbox"
                  name={"lore_entry[pool_settings][#{pool.id}][scored]"}
                  id={"lore-entry-form-pool-#{pool.id}-scored"}
                  value={@entry_pool_settings[pool.id]["scored"]}
                  label={dpgettext("lore", "field label: pool entry is scored in the draw", "Scored")}
                />
              </div>
              <p class="lore-entry-pool-settings-help">
                {dgettext(
                  "lore",
                  "Weight: the draw odds within the pool (0 never drawn). Override: wins over non-override members, by order. Scored: only members matching the most keys stay in the draw."
                )}
              </p>
            </div>
          </:field>
        </.field_row>

        <%!-- `ignore_attributes`: every `validate_entry` re-renders the form, which would close it. --%>
        <details
          :if={@memory}
          id="lore-entry-form-memory"
          class="lore-entry-memory"
          phx-mounted={JS.ignore_attributes(["open"])}
        >
          <summary>
            {dpgettext("lore", "heading: memory settings group of a lore entry", "Memory")}
            <span class="lore-entry-memory-current">{memory_summary(@memory)}</span>
          </summary>
          <%= cond do %>
            <% @memory.book == nil -> %>
              <p class="lore-entry-memory-help">
                {dgettext("lore", "Add the entry to a book you can edit to make it a memory.")}
              </p>
            <% !memory_editable?(@memory) -> %>
              <p class="lore-entry-memory-help">
                {memory_locked_hint(@memory.record, @memory.book.name)}
              </p>
            <% true -> %>
              <p class="lore-entry-memory-help">
                {dgettext(
                  "lore",
                  "How Memory Books treat this entry in %{book_name}: a scene memory, or a consolidation (Arc and up) of memories one tier below. Consolidation offers an entry only as a source for the tier above its own.",
                  book_name: @memory.book.name
                )}
              </p>
              <.field_row id="lore-entry-form-memory-row">
                <:field>
                  <.input
                    :if={!consolidated?(@memory)}
                    type="select"
                    name="lore_entry[memory][tier]"
                    label={memory_type_label()}
                    options={tier_options()}
                    value={@memory.tier}
                    id="lore-entry-form-memory-tier"
                  >
                    <:hint>{tier_hint()}</:hint>
                  </.input>
                  <%!-- A source's tier is fixed by what it was consolidated into; a disabled select would not submit. --%>
                  <.input
                    :if={consolidated?(@memory)}
                    type="select"
                    name="lore_entry[memory][tier_shown]"
                    label={memory_type_label()}
                    options={tier_options()}
                    value={@memory.tier}
                    id="lore-entry-form-memory-tier"
                    disabled
                  >
                    <:hint>{tier_hint()}</:hint>
                  </.input>
                  <input
                    :if={consolidated?(@memory)}
                    type="hidden"
                    name="lore_entry[memory][tier]"
                    value={@memory.tier}
                  />
                </:field>
                <:field :if={@memory.tier != ""}>
                  <.input
                    type="number"
                    name="lore_entry[memory][sequence]"
                    label={
                      dpgettext(
                        "lore",
                        "field label: number of a memory among its book's memories",
                        "Number"
                      )
                    }
                    placeholder={
                      dpgettext(
                        "lore",
                        "placeholder: empty memory number takes the next free one",
                        "Next free"
                      )
                    }
                    value={@memory.sequence}
                    id="lore-entry-form-memory-sequence"
                    min="1"
                  >
                    <:hint>
                      {dgettext(
                        "lore",
                        "This entry's number among its book's memories of the same type, used in its title. Empty takes the next free number."
                      )}
                    </:hint>
                  </.input>
                </:field>
              </.field_row>
              <.live_component
                :if={source_tier(@memory) != nil}
                module={MythweaverWeb.MultiSelect}
                id="lore-entry-form-memory-sources"
                name="lore_entry[memory][source_ids][]"
                label={sources_label(source_tier(@memory))}
                options={
                  for c <- @memory.candidates, c.tier == source_tier(@memory), do: {c.name, c.id}
                }
                selected={@memory.source_ids}
                empty={
                  dpgettext(
                    "lore",
                    "empty state: no memories to pick as consolidation sources",
                    "No memories to consolidate"
                  )
                }
                tag_kind={:lore_entry}
                viewer_id={@viewer_id}
                tag_graph={@tag_graph}
                tag_vocabulary={@tag_vocabulary}
              >
                <:hint>
                  {dgettext("lore", "The memories one tier below that this consolidation summarizes.")}
                </:hint>
              </.live_component>
              <p :if={source_tier(@memory) != nil} class="lore-entry-memory-help">
                {dgettext(
                  "lore",
                  "Picked entries count as consolidated into this one. A source you drop is switched back on if consolidating switched it off."
                )}
              </p>
          <% end %>
          <dl :if={@memory.record} class="lore-entry-memory-facts">
            <dt>{dpgettext("lore", "field label: chat a memory was written from", "Chat")}</dt>
            <dd>
              {if @memory.record.chat,
                do: Chat.title(@memory.record.chat),
                else: dgettext("lore", "None (imported or marked by hand)")}
            </dd>
            <dt>{dpgettext("lore", "field label: chat messages a memory covers", "Messages")}</dt>
            <dd>{message_range(@memory.record)}</dd>
            <dt :if={@memory.record.consolidated_into}>
              {dpgettext(
                "lore",
                "field label: consolidation a memory was folded into",
                "Consolidated into"
              )}
            </dt>
            <dd :if={@memory.record.consolidated_into}>
              {@memory.record.consolidated_into.entry.name}
            </dd>
          </dl>
        </details>

        <.form_actions>
          <.button patch={@cancel}>{dpgettext(
            "lore",
            "button: discard edits to the open form",
            "Cancel"
          )}</.button>
          <.button type="submit" variant="primary">{dpgettext(
            "lore",
            "button: save the open form",
            "Save"
          )}</.button>
        </.form_actions>
      </.form>
    </div>
    """
  end

  attr :form, :any, required: true, doc: "`entry_pool_form`; nil renders nothing"

  @doc """
  The entry form's New pool dialog. Render it outside the entry `<form>` (forms don't nest); its
  `"validate_entry_pool"`/`"create_entry_pool"`/`"cancel_entry_pool"` events go to the LiveView.
  """
  def new_pool_modal(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      /* A root tag of `<.modal>`'s slot: it carries this block's marker, so it is a scope root. */
      form:scope.lore-entry-new-pool-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .lore-entry-new-pool-help {
        margin: 0;
        color: var(--muted-foreground);
      }
    </style>
    <.modal
      :if={@form}
      id="lore-entry-new-pool-modal"
      title={dpgettext("lore", "heading: create a lore pool", "New pool")}
      on_cancel="cancel_entry_pool"
    >
      <.form
        for={@form}
        id="lore-entry-new-pool-form"
        class="lore-entry-new-pool-form"
        phx-change="validate_entry_pool"
        phx-submit="create_entry_pool"
      >
        <p class="lore-entry-new-pool-help">
          {dgettext(
            "lore",
            "The entry joins the new pool when you save it. Weight and flags are set on its row under Pools."
          )}
        </p>
        <.input
          field={@form[:name]}
          type="text"
          label={dpgettext("lore", "field label: name of a lore pool", "Name")}
          id="lore-entry-new-pool-form-name"
          required
        />
        <.input
          field={@form[:max_activations]}
          type="number"
          min="1"
          label={
            dpgettext(
              "lore",
              "field label: how many entries of a lore pool may be active at once",
              "Admits (entries active at once)"
            )
          }
          id="lore-entry-new-pool-form-max_activations"
          required
        />
        <.form_actions>
          <.button
            type="button"
            id="lore-entry-new-pool-cancel"
            phx-click={JS.dispatch("modal:close", to: "#lore-entry-new-pool-modal")}
          >
            {dpgettext("lore", "button: discard edits to the open form", "Cancel")}
          </.button>
          <.button type="submit" variant="primary" id="lore-entry-new-pool-create">
            {dpgettext("lore", "button: create a lore pool", "Create")}
          </.button>
        </.form_actions>
      </.form>
    </.modal>
    """
  end

  defp token_label({count, :exact}),
    do:
      dpngettext(
        "lore",
        "unit: exact token count of a lore entry's text",
        "%{token_count} token",
        "%{token_count} tokens",
        count, token_count: Format.number(count))

  defp token_label({count, :estimate}),
    do:
      dpngettext(
        "lore",
        "unit: estimated token count of a lore entry's text",
        "≈%{token_count} token",
        "≈%{token_count} tokens",
        count, token_count: Format.number(count))

  # Blank text counts exactly zero with or without a model.
  defp token_title({_count, :exact}, nil), do: nil

  defp token_title({_count, :exact}, model),
    do:
      dpgettext("lore", "tooltip: lore entry token count counted exactly", "Counted with %{model_name}'s tokenizer",
        model_name: model.name
      )

  defp token_title({_count, :estimate}, nil),
    do: dgettext("lore", "Estimated (characters ÷ 3.3): no default model is set")

  defp token_title({_count, :estimate}, model),
    do: dgettext("lore", "Estimated (characters ÷ 3.3): %{model_name} has no tokenizer set", model_name: model.name)

  defp logic_label, do: dpgettext("lore", "field label: lore entry secondary key logic", "Logic")

  defp logic_option(:and_any), do: dpgettext("lore", "option: lore entry secondary key logic", "AND any")
  defp logic_option(:and_all), do: dpgettext("lore", "option: lore entry secondary key logic", "AND all")
  defp logic_option(:not_any), do: dpgettext("lore", "option: lore entry secondary key logic", "NOT any")
  defp logic_option(:not_all), do: dpgettext("lore", "option: lore entry secondary key logic", "NOT all")

  defp tri_default, do: dpgettext("lore", "option: use the global setting for this lore keyword rule", "Default")

  defp tri_state_options,
    do: [
      {tri_default(), ""},
      {dpgettext("lore", "option: lore keyword rule is on", "Yes"), "true"},
      {dpgettext("lore", "option: lore keyword rule is off", "No"), "false"}
    ]

  defp memory_type_label, do: dpgettext("lore", "field label: memory type of a lore entry", "Type")

  defp not_a_memory, do: dpgettext("lore", "option: lore entry is not a memory", "Not a memory")

  defp sources_label(0), do: dpgettext("lore", "field label: memories a consolidation summarizes", "Sources (memories)")
  defp sources_label(1), do: dpgettext("lore", "field label: arcs a consolidation summarizes", "Sources (arcs)")
  defp sources_label(2), do: dpgettext("lore", "field label: chapters a consolidation summarizes", "Sources (chapters)")
  defp sources_label(3), do: dpgettext("lore", "field label: books a consolidation summarizes", "Sources (books)")
  defp sources_label(4), do: dpgettext("lore", "field label: legends a consolidation summarizes", "Sources (legends)")
  defp sources_label(5), do: dpgettext("lore", "field label: series a consolidation summarizes", "Sources (series)")

  defp memory_locked_hint(%Record{kind: :memory}, book_name),
    do:
      dgettext(
        "lore",
        "This entry is a scene memory of %{book_name}. Only the job that writes it changes these settings.",
        book_name: book_name
      )

  defp memory_locked_hint(%Record{kind: :consolidation, tier: 1}, book_name),
    do:
      dgettext("lore", "This entry is an arc of %{book_name}. Only the job that writes it changes these settings.",
        book_name: book_name
      )

  defp memory_locked_hint(%Record{kind: :consolidation, tier: 2}, book_name),
    do:
      dgettext("lore", "This entry is a chapter of %{book_name}. Only the job that writes it changes these settings.",
        book_name: book_name
      )

  defp memory_locked_hint(%Record{kind: :consolidation, tier: 3}, book_name),
    do:
      dgettext("lore", "This entry is a book of %{book_name}. Only the job that writes it changes these settings.",
        book_name: book_name
      )

  defp memory_locked_hint(%Record{kind: :consolidation, tier: 4}, book_name),
    do:
      dgettext("lore", "This entry is a legend of %{book_name}. Only the job that writes it changes these settings.",
        book_name: book_name
      )

  defp memory_locked_hint(%Record{kind: :consolidation, tier: 5}, book_name),
    do:
      dgettext("lore", "This entry is a series of %{book_name}. Only the job that writes it changes these settings.",
        book_name: book_name
      )

  defp memory_locked_hint(%Record{kind: :consolidation, tier: 6}, book_name),
    do:
      dgettext("lore", "This entry is an epic of %{book_name}. Only the job that writes it changes these settings.",
        book_name: book_name
      )

  defp memory_locked_hint(%Record{kind: kind}, book_name) when kind in [:clip, :topical_clip],
    do:
      dgettext("lore", "This entry is a clip of %{book_name}. Only the job that writes it changes these settings.",
        book_name: book_name
      )

  defp memory_locked_hint(%Record{kind: :side_prompt}, book_name),
    do:
      dgettext(
        "lore",
        "This entry is a side prompt of %{book_name}. Only the job that writes it changes these settings.",
        book_name: book_name
      )
end
