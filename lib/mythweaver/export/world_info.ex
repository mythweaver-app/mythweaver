defmodule Mythweaver.Export.WorldInfo do
  @moduledoc """
  Writes a bundle's lore book as a SillyTavern World Info file, the inverse of
  `Mythweaver.Import.WorldInfo`, and holds what the card exporter's `character_book` shares: the
  mapped entry keys (`mapped_entry/8`), writing them over `foreign` (`merge_foreign/4`) and the
  `stlo` book settings (`put_stlo/3`).

  Entries keep their membership order (`order`, `displayIndex` and the entry `uid` all follow it);
  content and keys go through `Mythweaver.Export.Macros.to_st/1`. Pools become ST inclusion groups,
  book priority, order adjustment and budget Aikobots' `stlo`, and the keys an import couldn't map
  (`foreign`) are written back under the mapped ones. Unless `bundle: false`, the bundle travels
  under `extensions.mythweaver` (`Mythweaver.Bundle.to_embedded/2`), with the digest of the
  importer's own reading of the file.
  """

  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.Bundle
  alias Mythweaver.Export
  alias Mythweaver.Export.Macros
  alias Mythweaver.Import.Embedded
  alias Mythweaver.Import.WorldInfo, as: ImportWorldInfo

  @positions %{
    {"character", "before"} => 0,
    {"character", "after"} => 1,
    {"author_note", "before"} => 2,
    {"author_note", "after"} => 3,
    {"examples", "before"} => 5,
    {"examples", "after"} => 6
  }

  # The inverse of `Mythweaver.Import.WorldInfo`'s `@logic`.
  @logic %{"and_any" => 0, "not_all" => 1, "not_any" => 2, "and_all" => 3}

  @roles %{"system" => 0, "user" => 1, "assistant" => 2}

  @doc "The World Info file for the lore book item `book_uid` of `bundle`. `opts`: `bundle:` (default true)."
  @spec file(Bundle.t(), String.t(), keyword()) :: %{
          bytes: binary(),
          filename: String.t(),
          content_type: String.t(),
          warnings: [String.t()]
        }
  def file(%Bundle{} = bundle, book_uid, opts \\ []) do
    items = index(bundle)
    book = Map.fetch!(items, book_uid)
    members = entries(items, book)
    outlets = outlet_names(bundle)
    index_by_uid = members |> Enum.with_index(fn {entry, _membership}, i -> {entry.uid, i} end) |> Map.new()

    {entries, names} =
      members
      |> Enum.with_index()
      |> Enum.map_reduce([], fn {{entry, membership}, i}, names ->
        {content, left?} = Macros.to_st(entry.data["content"])
        {keys, names} = entry_keys(entry, left?, names)
        mapped = mapped_entry(entry, membership, i, content, keys, outlets, index_by_uid, items)
        foreign = get_in(entry.data, ["foreign", "world_info"]) || %{}
        {{Integer.to_string(i), merge_foreign(foreign, mapped, "keysecondary", "characterFilter")}, names}
      end)

    foreign = get_in(book.data, ["foreign", "world_info"]) || %{}
    {foreign_extensions, foreign} = Map.pop(foreign, "extensions", %{})
    foreign_extensions = if is_map(foreign_extensions), do: foreign_extensions, else: %{}
    {json, foreign_extensions} = put_stlo(Map.put(foreign, "entries", Map.new(entries)), book.data, foreign_extensions)

    json = if(foreign_extensions == %{}, do: json, else: Map.put(json, "extensions", foreign_extensions))

    json =
      if Keyword.get(opts, :bundle, true) do
        digest =
          json
          |> Jason.encode!()
          |> Jason.decode!()
          |> ImportWorldInfo.normalize(book.name)
          |> Embedded.digest()

        Map.put(json, "extensions", Map.put(foreign_extensions, "mythweaver", Bundle.to_embedded(bundle, digest)))
      else
        json
      end

    %{
      bytes: Jason.encode!(json, pretty: true),
      filename: Export.filename(book.name, "json"),
      content_type: "application/json",
      warnings: macro_warnings(names) ++ entry_warnings(Enum.map(members, &elem(&1, 0)))
    }
  end

  @doc """
  `json` and its `foreign_extensions` with the book item `data`'s priority, order adjustment and
  fixed budget in Aikobots' `stlo`, which it reads them from. Written only when one differs from
  the default or the imported file had it, top level or under `extensions` (kept where it was, its
  other keys too); a percentage budget mode Mythweaver can't represent is left alone.
  """
  @spec put_stlo(map(), map(), map()) :: {map(), map()}
  def put_stlo(json, data, foreign_extensions) do
    nested? = not is_map(json["stlo"]) and is_map(foreign_extensions["stlo"])
    foreign = if nested?, do: foreign_extensions["stlo"], else: json["stlo"]
    budget = data["token_budget"]
    priority = data["priority"] || 3
    adjustment = data["order_adjustment"] || 0

    if priority != 3 or adjustment != 0 or budget != nil or is_map(foreign) do
      budget_keys =
        cond do
          budget -> %{"budgetMode" => "fixed", "budget" => budget}
          is_map(foreign) and foreign["budgetMode"] in ["percentage_context", "percentage_budget"] -> %{}
          true -> %{"budgetMode" => "default", "budget" => nil}
        end

      stlo =
        if(is_map(foreign), do: foreign, else: %{})
        |> Map.merge(%{"priority" => priority, "orderAdjustment" => adjustment})
        |> Map.merge(budget_keys)

      if nested?,
        do: {json, Map.put(foreign_extensions, "stlo", stlo)},
        else: {Map.put(json, "stlo", stlo), foreign_extensions}
    else
      {json, foreign_extensions}
    end
  end

  @doc """
  An entry's primary and secondary keys with their Liquid turned back into ST macros, adding the
  entry's name to the leftover-Liquid `names` when any key (or `content_left?`) kept a template.
  """
  @spec entry_keys(Bundle.item(), boolean(), [String.t()]) ::
          {%{primary: [String.t()], secondary: [String.t()]}, [String.t()]}
  def entry_keys(entry, content_left?, names) do
    {primary, primary_left?} = keys(entry.data["keywords"])
    {secondary, secondary_left?} = keys(entry.data["secondary_keywords"])
    names = if content_left? or primary_left? or secondary_left?, do: [entry.name | names], else: names
    {%{primary: primary, secondary: secondary}, names}
  end

  @doc """
  The warnings for entry items whose settings SillyTavern can't honour: regex keys with the `x` or
  `f` flag, and trigger-only entries.
  """
  @spec entry_warnings([Bundle.item()]) :: [String.t()]
  def entry_warnings(entries) do
    flagged = for e <- entries, Enum.any?(all_keys(e.data), &st_unsupported_flags?/1), do: e.name
    triggers = for e <- entries, e.data["trigger_only"] == true, do: e.name

    Enum.concat([
      if(flagged == [], do: [], else: [flags_warning(Enum.join(Enum.uniq(flagged), ", "))]),
      if(triggers == [], do: [], else: [trigger_warning(Enum.join(Enum.uniq(triggers), ", "))])
    ])
  end

  defp flags_warning(entry_names) do
    gettext_comment("Export warning; the placeholder is a comma-separated list of lore entry names.")

    dgettext(
      "import_export",
      "%{entry_names}: regex flags x/f aren't supported by SillyTavern; the key will match as plain text.",
      entry_names: entry_names
    )
  end

  defp trigger_warning(entry_names) do
    gettext_comment("Export warning; the placeholder is a comma-separated list of lore entry names.")

    dgettext(
      "import_export",
      "%{entry_names}: trigger-only; SillyTavern has no such setting and will insert the content.",
      entry_names: entry_names
    )
  end

  defp all_keys(data), do: List.wrap(data["keywords"]) ++ List.wrap(data["secondary_keywords"])

  defp st_unsupported_flags?(key) when is_binary(key) do
    case Regex.run(~r{\A/(?:\\.|[^\\/])+/([imsuxf]*)\z}s, key) do
      [_, flags] -> String.contains?(flags, ["x", "f"])
      nil -> false
    end
  end

  defp st_unsupported_flags?(_key), do: false

  @doc """
  The World Info keys Mythweaver maps for `entry` (no `foreign`), at index `i` of its file:
  `membership` gives `order` and `disable`, `content` and `keys` are already converted
  (`entry_keys/3`), `outlets` names custom outlets (`outlet_names/1`), `index_by_uid` places STMB
  sources (SillyTavern-MemoryBooks keys) and `items` resolves pools and filter characters.
  """
  @spec mapped_entry(
          Bundle.item(),
          map(),
          non_neg_integer(),
          String.t(),
          %{primary: [String.t()], secondary: [String.t()]},
          %{String.t() => String.t()},
          %{String.t() => non_neg_integer()},
          %{String.t() => Bundle.item()}
        ) :: map()
  def mapped_entry(entry, membership, i, content, keys, outlets, index_by_uid, items) do
    data = entry.data
    {position, outlet_name} = position(data, outlets)
    secondary = keys.secondary
    groups = groups(data, items)

    mapped =
      %{
        "uid" => i,
        "key" => keys.primary,
        "keysecondary" => secondary,
        "comment" => data["name"] || entry.name,
        "content" => content,
        "constant" => data["activation"] == "constant",
        "vectorized" => data["activation"] == "vector",
        "selective" => secondary != [],
        "selectiveLogic" => logic(data["secondary_logic"]),
        "addMemo" => true,
        "order" => membership["order"] || 100,
        "position" => position,
        "disable" => membership["enabled"] == false,
        "excludeRecursion" => data["exclude_recursion"] == true,
        "preventRecursion" => data["prevent_recursion"] == true,
        "probability" => data["probability"] || 100,
        "useProbability" => true,
        "depth" => data["depth"] || 4,
        "role" => role(data),
        "group" => groups.group,
        "groupOverride" => groups.override,
        "groupWeight" => groups.weight,
        "useGroupScoring" => groups.scored,
        "activationOnly" => data["trigger_only"] == true,
        "delayUntilRecursion" => delay_until_recursion(data),
        "scanDepth" => data["scan_depth"],
        "caseSensitive" => data["case_sensitive"],
        "matchWholeWords" => data["match_whole_words"],
        "sticky" => data["sticky"],
        "cooldown" => data["cooldown"],
        "delay" => data["delay"],
        "ignoreBudget" => data["ignore_budget"] == true,
        "outletName" => outlet_name,
        "displayIndex" => i
      }
      |> put_character_filter(data, items)

    Map.merge(mapped, stmb(entry, index_by_uid))
  end

  @doc """
  `mapped` written over the `foreign` keys an import kept, keeping what an import held raw because
  Mythweaver doesn't: the foreign secondary keys (`secondary_key`) while `mapped` has none, and the
  foreign character filter's `tags` in `mapped`'s filter (`filter_key`).
  """
  @spec merge_foreign(map(), map(), String.t(), String.t()) :: map()
  def merge_foreign(foreign, mapped, secondary_key, filter_key) do
    mapped =
      if mapped[secondary_key] == [] and is_list(foreign[secondary_key]),
        do: Map.delete(mapped, secondary_key),
        else: mapped

    mapped =
      case {foreign[filter_key], mapped[filter_key]} do
        {%{"tags" => tags}, %{} = filter} -> Map.put(mapped, filter_key, Map.put(filter, "tags", tags))
        _other -> mapped
      end

    Map.merge(foreign, mapped)
  end

  # Keys with their Liquid turned back into ST macros, and whether any kept a template.
  defp keys(keys) do
    {converted, lefts} = keys |> List.wrap() |> Enum.map(&Macros.to_st/1) |> Enum.unzip()
    {converted, Enum.any?(lefts)}
  end

  # An entry item's pools as an ST inclusion group: the pool names joined with `,`, the first
  # membership's weight (100 with none), and whether any membership overrides or scores (`scored`
  # is `nil` when none does, ST's "use the global setting").
  defp groups(data, items) do
    links =
      for %{"uid" => uid} = link <- List.wrap(data["pools"]),
          %{kind: :lore_pool} = pool <- [items[uid]],
          do: {pool, link}

    %{
      group: Enum.map_join(links, ",", fn {pool, _link} -> pool.name end),
      weight:
        case links do
          [{_pool, %{"weight" => weight}} | _] when is_integer(weight) -> weight
          _other -> 100
        end,
      override: Enum.any?(links, fn {_pool, link} -> link["override"] == true end),
      scored: if(Enum.any?(links, fn {_pool, link} -> link["scored"] == true end), do: true)
    }
  end

  # ST's role number for an entry's `role` (0 system, 1 user, 2 assistant).
  defp role(data), do: Map.get(@roles, data["role"], 0)

  # ST's `delayUntilRecursion`: the level when above 0, else `false`.
  defp delay_until_recursion(%{"delay_until_recursion" => level}) when is_integer(level) and level > 0, do: level
  defp delay_until_recursion(_data), do: false

  # The ST character filter names of an entry's filter characters: each card's file name
  # (`source_file`, when the character is in the bundle) or its name. ST compares against the avatar
  # name without its extension.
  defp filter_names(refs, items) do
    Enum.map(refs, fn ref ->
      case items[ref["uid"]] do
        %{kind: :character, data: %{"source_file" => file}} when is_binary(file) -> file
        _other -> ref["name"]
      end
    end)
  end

  defp put_character_filter(json, %{"character_filter_mode" => mode, "filter_characters" => [_ | _] = refs}, items)
       when mode in ["include", "exclude"] do
    Map.put(json, "characterFilter", %{
      "isExclude" => mode == "exclude",
      "names" => filter_names(refs, items),
      "tags" => []
    })
  end

  defp put_character_filter(json, _data, _items), do: json

  # The ST `position` of an entry's `data` and its `outletName` (`""` unless custom). A custom outlet
  # is named by its outlet item's name when that name slugs back to the key
  # (`Mythweaver.Import.WorldInfo.slug/1`), else by the key itself, so the key survives the trip.
  defp position(data, outlet_names) do
    case data["outlet"] do
      "at_depth" -> {4, ""}
      "custom" -> {7, outlet_name(data["custom_outlet"] || "", outlet_names)}
      outlet -> {Map.get(@positions, {outlet, data["placement"] || "before"}, 0), ""}
    end
  end

  defp outlet_name(key, outlet_names) do
    name = Map.get(outlet_names, key)
    if is_binary(name) and ImportWorldInfo.slug(name) == key, do: String.trim(name), else: key
  end

  # ST's `selectiveLogic` number for a `secondary_logic` string.
  defp logic(secondary_logic), do: Map.get(@logic, secondary_logic, 0)

  # The SillyTavern-MemoryBooks keys for an entry item, `index_by_uid` mapping entry uids to their
  # index in the file: a `memory` record is `stmemorybooks`; a `consolidation` is also a summary of its
  # tier listing its sources; an entry folded into a summary in the file names it in
  # `disabledBySummaryId`. Other entries get none.
  defp stmb(%{data: data}, index_by_uid) do
    memory = data["memory"]

    keys =
      case memory do
        %{"kind" => "memory"} ->
          %{"stmemorybooks" => true}

        %{"kind" => "consolidation"} ->
          %{
            "stmemorybooks" => true,
            "stmbSummary" => true,
            "stmbSummaryTier" => memory["tier"],
            "stmbSourceEntryUids" => for(uid <- List.wrap(memory["sources"]), i = index_by_uid[uid], do: i)
          }

        _other ->
          %{}
      end

    case memory do
      %{"disabled_by_consolidation" => true, "consolidated_into" => into} when is_map_key(index_by_uid, into) ->
        Map.put(keys, "disabledBySummaryId", Map.fetch!(index_by_uid, into))

      _other ->
        keys
    end
  end

  @doc "`bundle`'s items by uid."
  @spec index(Bundle.t()) :: %{String.t() => Bundle.item()}
  def index(%Bundle{items: items}), do: Map.new(items, &{&1.uid, &1})

  @doc "A book item's entry items in membership order, each with its membership map (`order`, `enabled`)."
  @spec entries(%{String.t() => Bundle.item()}, Bundle.item()) :: [{Bundle.item(), map()}]
  def entries(items, book) do
    for %{"uid" => uid} = membership <- List.wrap(book.data["entries"]),
        %{kind: :lore_entry} = entry <- [items[uid]],
        do: {entry, membership}
  end

  @doc "Outlet key => name for every outlet item in `bundle`."
  @spec outlet_names(Bundle.t()) :: %{String.t() => String.t()}
  def outlet_names(%Bundle{items: items}) do
    for %{kind: :prompt_outlet, data: data} <- items, into: %{}, do: {data["key"], data["name"]}
  end

  @doc "The one leftover-Liquid warning for the affected `names`, or none."
  @spec macro_warnings([String.t()]) :: [String.t()]
  def macro_warnings([]), do: []
  def macro_warnings(names), do: [names |> Enum.reverse() |> Enum.uniq() |> Macros.warning()]
end
