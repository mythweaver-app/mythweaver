defmodule Mythweaver.Import.WorldInfo do
  @moduledoc """
  Normalizes a SillyTavern World Info file (or a card's `character_book` after converting it the
  way ST's `convertCharacterBook` does) into entry specs.

  Each `t:entry_spec/0` holds `attrs`, ready for `LoreEntry.changeset/2`, plus the membership fields
  (`order`, `enabled`), an optional `character_filter` to resolve against characters, for a
  custom-outlet entry the `outlet` key/name to ensure exists, `pools` (ST inclusion groups, matched
  to pools by name) and `memory` (a SillyTavern-MemoryBooks entry, `stmemorybooks`: its uid, summary
  tier and source uids). ST positions map onto `LoreEntry`'s `outlet` + `placement` fields:

  | ST position | attrs |
  |---|---|
  | 0, `"before_char"` | `outlet: :character, placement: :before` |
  | 1, `"after_char"` | `outlet: :character, placement: :after` |
  | 2 | `outlet: :author_note, placement: :before` |
  | 3 | `outlet: :author_note, placement: :after` |
  | 4 | `outlet: :at_depth, depth: depth` (and `role`) |
  | 5 | `outlet: :examples, placement: :before` |
  | 6 | `outlet: :examples, placement: :after` |
  | 7 | `outlet: :custom, custom_outlet: slug(outletName)` |
  | other | `trigger_only: true` (SillyTavern never inserts it) |

  Keys convert their macros like content does; an ST regex key loses its `g` (and sticky `y`)
  flag, and one Mythweaver can't compile is dropped. Leading `@@` decorators
  (`Mythweaver.Import.Decorators`) apply `@@activate`/`@@dont_activate`. Orders are whole numbers,
  shifted up so none is negative, with the book's order adjustment lowered by as much. Aikobots'
  `stlo` settings give the book's priority, order
  adjustment and fixed budget. Keys nothing maps are kept in `foreign` so an export can write them
  back, as are a non-selective entry's secondary keys and character filter tags, which Mythweaver
  doesn't hold; an embedded book's own `scan_depth`, `token_budget` and `recursive_scanning` are
  kept there too, not applied, as SillyTavern ignores them. A World Info file's `originalData` (ST's
  stale copy of the card book it came from) is dropped.
  """

  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.Format
  alias Mythweaver.Import.Decorators
  alias Mythweaver.Import.Text
  alias Mythweaver.Lore.Matcher
  alias Mythweaver.Templates

  @type pool_spec :: %{name: String.t(), weight: non_neg_integer(), override: boolean(), scored: boolean()}

  @type entry_spec :: %{
          attrs: map(),
          order: non_neg_integer(),
          enabled: boolean(),
          character_filter: %{mode: :include | :exclude, names: [String.t()], tags: [String.t()]} | nil,
          outlet: %{key: String.t(), name: String.t()} | nil,
          pools: [pool_spec()],
          memory: %{uid: String.t(), tier: 0..6, source_uids: [String.t()]} | nil
        }

  @type book_spec :: %{name: String.t(), book: map(), entries: [entry_spec()]}

  @type t :: %{
          kind: :lore_book,
          name: String.t(),
          book: map(),
          entries: [entry_spec()],
          warnings: [String.t()],
          unconverted: [String.t()]
        }

  @logic %{0 => :and_any, 1 => :not_all, 2 => :not_any, 3 => :and_all}
  @roles %{0 => :system, 1 => :user, 2 => :assistant, "system" => :system, "user" => :user, "assistant" => :assistant}

  # Every World Info entry key the importer reads (or deliberately drops), so `foreign` keeps the rest.
  @wi_mapped ~w(uid key keysecondary comment content constant vectorized selective order position
    excludeRecursion preventRecursion disable displayIndex addMemo probability useProbability depth
    selectiveLogic outletName scanDepth caseSensitive matchWholeWords sticky cooldown delay ignoreBudget
    group groupOverride groupWeight useGroupScoring role activationOnly delayUntilRecursion
    characterFilter stmemorybooks stmbSummary stmbSummaryTier stmbArc stmbSourceEntryUids
    disabledBySummaryId type)

  # World Info entry key => the `character_book` entry `extensions` key holding it
  # (`character_book_extensions/0`).
  @cb_extensions [
    {"position", "position"},
    {"depth", "depth"},
    {"role", "role"},
    {"probability", "probability"},
    {"useProbability", "useProbability"},
    {"selectiveLogic", "selectiveLogic"},
    {"outletName", "outlet_name"},
    {"excludeRecursion", "exclude_recursion"},
    {"preventRecursion", "prevent_recursion"},
    {"scanDepth", "scan_depth"},
    {"caseSensitive", "case_sensitive"},
    {"matchWholeWords", "match_whole_words"},
    {"sticky", "sticky"},
    {"cooldown", "cooldown"},
    {"delay", "delay"},
    {"ignoreBudget", "ignore_budget"},
    {"vectorized", "vectorized"},
    {"displayIndex", "display_index"},
    {"group", "group"},
    {"groupWeight", "group_weight"},
    {"groupOverride", "group_override"},
    {"useGroupScoring", "use_group_scoring"},
    {"activationOnly", "activation_only"},
    {"delayUntilRecursion", "delay_until_recursion"},
    {"characterFilter", "character_filter"},
    {"stmemorybooks", "stmemorybooks"},
    {"stmbSummary", "stmbSummary"},
    {"stmbSummaryTier", "stmbSummaryTier"},
    {"stmbSourceEntryUids", "stmbSourceEntryUids"},
    {"disabledBySummaryId", "disabledBySummaryId"}
  ]

  # World Info keys other tools write under their own name in a `character_book` entry's
  # `extensions`; read when the standard key is absent, and counted for one warning.
  @cb_spellings ~w(excludeRecursion preventRecursion displayIndex matchWholeWords caseSensitive scanDepth
    ignoreBudget outletName)

  # A `character_book` entry's top-level and `extensions` keys `convert_entry/3` maps.
  @cb_mapped ~w(keys secondary_keys comment content constant selective insertion_order enabled position
    id use_regex extensions stmemorybooks stmbSummary stmbSummaryTier stmbArc stmbSourceEntryUids
    disabledBySummaryId type whole_words_only sticky)
  @cb_ext_mapped Enum.map(@cb_extensions, &elem(&1, 1)) ++
                   @cb_spellings ++ ~w(activationOnly characterFilter stmbArc type mythweaver)

  @aikobots_unmapped ~w(orderAdjustmentGroupOnly randomTrim characterOverrides onlyWhenSpeaking)

  @doc "A World Info file (its `entries`, a map of uid => entry or a list) as a lore book."
  @spec normalize(map(), String.t()) :: t()
  def normalize(json, name) when is_map(json) do
    # `originalData` is ST's stale copy of the card book the file came from.
    {foreign, foreign_warnings} =
      json |> Map.drop(["entries", "originalData"]) |> drop_mythweaver() |> Text.foreign([], name)

    {book, stlo_warnings} = stlo_book(json)
    book = put_foreign(book, "world_info", foreign)

    result = build(json["entries"], name, book, %{})
    %{result | warnings: foreign_warnings ++ stlo_warnings ++ result.warnings}
  end

  @doc "An ST entry role (a number or name) as `LoreEntry`'s `role`; anything else is `:system`."
  @spec role(term()) :: :system | :user | :assistant
  def role(value), do: Map.get(@roles, value, :system)

  @doc """
  `{world_info_key, character_book_extension_key}` for every World Info entry key a card's
  `character_book` entry holds under `extensions`: `Mythweaver.Export.Card` writes them, and the
  import reads them back.
  """
  @spec character_book_extensions() :: [{String.t(), String.t()}]
  def character_book_extensions, do: @cb_extensions

  @doc "A card's `character_book`, converted to world-info entries first."
  @spec character_book(map(), String.t()) :: t()
  def character_book(%{} = cb, default_name) do
    name = if Text.blank?(cb["name"]), do: default_name, else: String.trim(cb["name"])

    {entries, fallbacks} =
      cb["entries"]
      |> Enum.filter(&is_map/1)
      |> Enum.with_index()
      |> Enum.map_reduce(0, fn {entry, index}, count ->
        id = Map.get(entry, "id") || index
        {converted, foreign, used} = convert_entry(entry, id, index)
        {{id, converted, foreign}, count + used}
      end)

    {foreign, foreign_warnings} =
      cb |> Map.drop(["name", "entries"]) |> drop_mythweaver() |> Text.foreign([], name)

    {book, stlo_warnings} = stlo_book(cb)
    book = put_foreign(book, "character_book", foreign)

    ignored =
      for key <- ~w(token_budget scan_depth recursive_scanning),
          not is_nil(cb[key]),
          do: "#{key} #{Jason.encode!(cb[key])}"

    warnings =
      foreign_warnings ++
        stlo_warnings ++
        if(fallbacks > 0,
          do: [
            dngettext(
              "import_export",
              "Read %{field_count} non-standard field spelling.",
              "Read %{field_count} non-standard field spellings.",
              fallbacks,
              field_count: Format.number(fallbacks)
            )
          ],
          else: []
        ) ++
        if(ignored == [],
          do: [],
          else: [
            dgettext(
              "import_export",
              "The embedded book's %{setting_list} weren't applied (SillyTavern ignores them).",
              setting_list: Enum.join(ignored, ", ")
            )
          ]
        )

    result =
      build(
        Map.new(entries, fn {id, converted, _foreign} -> {id, converted} end),
        name,
        book,
        Map.new(entries, fn {id, _converted, foreign} -> {id, foreign} end)
      )

    %{result | warnings: warnings ++ result.warnings}
  end

  # A Mythweaver export's own data is read by `Mythweaver.Import.Embedded`, not kept; a non-map
  # `extensions` is malformed and dropped.
  defp drop_mythweaver(%{"extensions" => %{} = ext} = map),
    do: Map.put(map, "extensions", Map.delete(ext, "mythweaver"))

  defp drop_mythweaver(%{"extensions" => _other} = map), do: Map.delete(map, "extensions")
  defp drop_mythweaver(map), do: map

  defp put_foreign(book, _namespace, kept) when kept == %{}, do: book
  defp put_foreign(book, namespace, kept), do: Map.put(book, :foreign, %{namespace => kept})

  # Aikobots (`stlo`): book priority, order adjustment and a fixed budget.
  defp stlo_book(json) do
    case json["stlo"] || get_in(Text.map(json["extensions"]), ["stlo"]) do
      %{} = stlo ->
        book =
          %{
            priority: clamp(stlo["priority"], 1, 5) || 3,
            order_adjustment: clamp(stlo["orderAdjustment"], -10_000, 10_000) || 0
          }
          |> then(fn book ->
            budget = Text.pos_int(stlo["budget"])
            if stlo["budgetMode"] == "fixed" and budget, do: Map.put(book, :token_budget, budget), else: book
          end)

        mode_warnings =
          if stlo["budgetMode"] in ["percentage_context", "percentage_budget"],
            do: [
              dgettext(
                "import_export",
                "Aikobots budget mode %{budget_mode} (%{budget_percent}%) wasn't imported; set the book's token budget by hand.",
                budget_mode: stlo["budgetMode"],
                budget_percent: Jason.encode!(stlo["budget"])
              )
            ],
            else: []

        unmapped = for key <- @aikobots_unmapped, stlo[key] not in [nil, false, "", [], %{}], do: key

        unmapped_warnings =
          if unmapped == [],
            do: [],
            else: [
              dgettext("import_export", "Aikobots settings not imported: %{setting_keys}.",
                setting_keys: Enum.join(unmapped, ", ")
              )
            ]

        {book, mode_warnings ++ unmapped_warnings}

      _none ->
        {%{}, []}
    end
  end

  defp clamp(value, low, high) when is_number(value), do: value |> round() |> max(low) |> min(high)
  defp clamp(_value, _low, _high), do: nil

  # Mirrors ST's `convertCharacterBook` (public/scripts/world-info.js) for the keys mapped here, plus
  # the non-standard spellings other tools write (counted, for one warning). Returns the converted
  # entry, its `{foreign, warnings}` and the number of fallback spellings used.
  defp convert_entry(entry, id, index) do
    ext = Text.map(entry["extensions"])

    standard = Map.new(@cb_extensions)

    {fallback, used} =
      Enum.reduce(@cb_spellings, {%{}, 0}, fn key, {acc, used} ->
        cond do
          Map.has_key?(ext, standard[key]) -> {Map.put(acc, key, ext[standard[key]]), used}
          Map.has_key?(ext, key) -> {Map.put(acc, key, ext[key]), used + 1}
          true -> {acc, used}
        end
      end)

    # Wyvern writes these at the top level.
    {whole_words, used} =
      cond do
        Map.has_key?(fallback, "matchWholeWords") -> {fallback["matchWholeWords"], used}
        Map.has_key?(entry, "whole_words_only") -> {entry["whole_words_only"], used + 1}
        true -> {nil, used}
      end

    {sticky, used} =
      cond do
        Map.has_key?(ext, "sticky") -> {ext["sticky"], used}
        Map.has_key?(entry, "sticky") -> {entry["sticky"], used + 1}
        true -> {nil, used}
      end

    name = entry["comment"] || "Entry #{id}"
    {top, top_warnings} = Text.foreign(entry, @cb_mapped, name)
    {ext_kept, ext_warnings} = Text.foreign(ext, @cb_ext_mapped, name)

    foreign =
      %{"entry" => top, "extensions" => ext_kept}
      |> Map.reject(fn {_key, kept} -> kept == %{} end)
      |> then(&if(&1 == %{}, do: %{}, else: %{"character_book" => &1}))

    # Each extension key as is, then the spellings, defaults and top-level fallbacks over it.
    plain = Map.new(@cb_extensions, fn {key, cb_key} -> {key, ext[cb_key]} end)

    converted = %{
      "uid" => id,
      "key" => entry["keys"],
      "keysecondary" => entry["secondary_keys"] || [],
      "comment" => entry["comment"] || "",
      "content" => entry["content"],
      "constant" => entry["constant"] || false,
      "vectorized" => nn(ext["vectorized"], false),
      "selective" => entry["selective"] || false,
      "order" => entry["insertion_order"],
      "position" => nn(ext["position"], if(entry["position"] == "before_char", do: 0, else: 1)),
      "excludeRecursion" => nn(fallback["excludeRecursion"], false),
      "preventRecursion" => nn(fallback["preventRecursion"], false),
      "disable" => !truthy?(entry["enabled"]),
      "displayIndex" => nn(fallback["displayIndex"], index),
      "probability" => nn(ext["probability"], 100),
      "useProbability" => nn(ext["useProbability"], true),
      "depth" => nn(ext["depth"], 4),
      "selectiveLogic" => nn(ext["selectiveLogic"], 0),
      "outletName" => nn(fallback["outletName"], ""),
      "scanDepth" => fallback["scanDepth"],
      "caseSensitive" => fallback["caseSensitive"],
      "matchWholeWords" => whole_words,
      "sticky" => sticky,
      "ignoreBudget" => nn(fallback["ignoreBudget"], false),
      "activationOnly" => nn(ext["activation_only"], ext["activationOnly"]),
      # ST reads no filter from a card's book; reading one is deliberate.
      "characterFilter" => nn(ext["character_filter"], ext["characterFilter"]),
      # Read for the not-imported warning only (`dropped/1`).
      "triggers" => ext["triggers"],
      "automationId" => ext["automation_id"],
      "matchPersonaDescription" => ext["match_persona_description"],
      "matchCharacterDescription" => ext["match_character_description"],
      "matchCharacterPersonality" => ext["match_character_personality"],
      "matchCharacterDepthPrompt" => ext["match_character_depth_prompt"],
      "matchScenario" => ext["match_scenario"],
      "matchCreatorNotes" => ext["match_creator_notes"],
      "stmemorybooks" => nn(entry["stmemorybooks"], ext["stmemorybooks"]),
      "stmbSummary" => nn(entry["stmbSummary"], ext["stmbSummary"]),
      "stmbSummaryTier" => nn(entry["stmbSummaryTier"], ext["stmbSummaryTier"]),
      "stmbArc" => nn(entry["stmbArc"], ext["stmbArc"]),
      "stmbSourceEntryUids" => nn(entry["stmbSourceEntryUids"], ext["stmbSourceEntryUids"]),
      "disabledBySummaryId" => nn(entry["disabledBySummaryId"], ext["disabledBySummaryId"]),
      "type" => nn(entry["type"], ext["type"])
    }

    {Map.merge(plain, converted), {foreign, top_warnings ++ ext_warnings}, used}
  end

  defp nn(nil, default), do: default
  defp nn(value, _default), do: value

  defp truthy?(value), do: value not in [nil, false, 0, ""]

  # `converted_foreign` holds, by uid, the `{foreign, warnings}` of entries converted from a card
  # book (`convert_entry/3`); every other entry keeps its unmapped World Info keys.
  defp build(entries, name, book, converted_foreign) do
    entries = list_entries(entries)
    sources = summary_sources(entries)

    {specs, warnings, names, decorated} =
      Enum.reduce(entries, {[], [], [], 0}, fn entry, {specs, warnings, names, decorated} ->
        {spec, entry_warnings, names, decorated?} = entry_spec(entry, names, sources, converted_foreign)
        {[spec | specs], [entry_warnings | warnings], names, decorated + if(decorated?, do: 1, else: 0)}
      end)

    {specs, book, shift_warnings} = shift_orders(Enum.reverse(specs), book)

    warnings =
      Enum.concat(Enum.reverse(warnings)) ++
        if(decorated > 0,
          do: [
            dngettext(
              "import_export",
              "Converted decorators in %{entry_count} entry.",
              "Converted decorators in %{entry_count} entries.",
              decorated,
              entry_count: Format.number(decorated)
            )
          ],
          else: []
        ) ++
        shift_warnings ++ dropped(entries)

    %{
      kind: :lore_book,
      name: name,
      book: book,
      entries: specs,
      warnings: warnings,
      unconverted: names
    }
  end

  # ST orders may be negative; membership orders may not. Shifting every order keeps their spacing,
  # and lowering the book's order adjustment by as much keeps each effective order the ST one.
  defp shift_orders([], book), do: {[], book, []}

  defp shift_orders(specs, book) do
    specs
    |> Enum.map(& &1.order)
    |> Enum.min()
    |> case do
      min when min < 0 ->
        adjustment = clamp(Map.get(book, :order_adjustment, 0) + min, -10_000, 10_000)

        {Enum.map(specs, &%{&1 | order: &1.order - min}), Map.put(book, :order_adjustment, adjustment),
         [
           dgettext("import_export", "Shifted orders up by %{order_shift} so none is negative.",
             order_shift: Format.number(-min)
           )
         ]}

      _min ->
        {specs, book, []}
    end
  end

  # One warning naming what SillyTavern entries carry and Mythweaver can't import.
  defp dropped(entries) do
    counts = [
      {:match_sources, Enum.count(entries, &match_sources?/1)},
      {:triggers, Enum.count(entries, &(Text.strings(&1["triggers"]) != []))},
      {:automation_id, Enum.count(entries, &(not Text.blank?(&1["automationId"])))},
      {:filter_tags, Enum.count(entries, &filter_tags_only?/1)}
    ]

    case for {feature, n} <- counts, n > 0, do: dropped_part(feature, n) do
      [] ->
        []

      parts ->
        gettext_comment(
          "Import warning; the placeholder is a comma-separated list of SillyTavern features, each with how many entries use it."
        )

        [
          dpgettext(
            "import_export",
            "status: import warning, SillyTavern lore entry features not imported",
            "Not imported: %{feature_list}.",
            feature_list: Enum.join(parts, ", ")
          )
        ]
    end
  end

  # Fragments of a list (lowercase, SillyTavern feature names), hence the `unit:` contexts.
  defp dropped_part(:match_sources, n),
    do:
      dpngettext(
        "import_export",
        "unit: SillyTavern entry feature not imported, with how many entries use it",
        "match* scan sources (%{entry_count} entry)",
        "match* scan sources (%{entry_count} entries)",
        n, entry_count: Format.number(n))

  defp dropped_part(:triggers, n),
    do:
      dpgettext(
        "import_export",
        "unit: SillyTavern entry feature not imported, with how many entries use it",
        "triggers (%{entry_count})", entry_count: Format.number(n))

  defp dropped_part(:automation_id, n), do: "automationId (#{Format.number(n)})"

  defp dropped_part(:filter_tags, n),
    do:
      dpgettext(
        "import_export",
        "unit: SillyTavern entry feature not imported, with how many entries use it",
        "character filter tags (%{entry_count})", entry_count: Format.number(n))

  defp match_sources?(entry) do
    Enum.any?(entry, fn {key, value} ->
      is_binary(key) and String.starts_with?(key, "match") and key != "matchWholeWords" and value == true
    end)
  end

  defp filter_tags_only?(%{"characterFilter" => %{} = filter}),
    do: Text.strings(filter["names"]) == [] and Text.strings(filter["tags"]) != []

  defp filter_tags_only?(_entry), do: false

  defp list_entries(entries) when is_map(entries) do
    sort(for {uid, entry} <- entries, is_map(entry), do: Map.put_new(entry, "uid", uid))
  end

  defp list_entries(entries) when is_list(entries) do
    entries
    |> Enum.filter(&is_map/1)
    |> Enum.with_index(fn entry, index -> Map.put_new(entry, "uid", index) end)
    |> sort()
  end

  defp list_entries(_entries), do: []

  defp sort(entries), do: Enum.sort_by(entries, &{sort_num(&1["displayIndex"]), sort_num(&1["uid"])})

  defp sort_num(value) when is_number(value), do: value

  defp sort_num(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _other -> value
    end
  end

  # nil sorts after numbers but before strings in term order; push it after everything.
  defp sort_num(_value), do: {:none}

  defp entry_spec(entry, names, sources, converted_foreign) do
    raw_keys = entry["key"] |> Text.strings() |> clean()
    name = entry_name(entry, raw_keys)

    decorated = Decorators.parse(Text.string(entry["content"]) || "")
    {content, names} = Text.convert(decorated.content, names)

    {keywords, names, primary_warnings} = keys(raw_keys, names, name)

    {secondary, names, secondary_warnings} =
      if entry["selective"] == true,
        do: entry["keysecondary"] |> Text.strings() |> clean() |> keys(names, name),
        else: {[], names, []}

    {location, outlet, location_warnings} = position(entry, name)

    {foreign, foreign_warnings} =
      case Map.fetch(converted_foreign, entry["uid"]) do
        {:ok, {foreign, warnings}} ->
          {put_unheld(foreign, "character_book", entry), warnings}

        :error ->
          {kept, warnings} = Text.foreign(entry, @wi_mapped, name)
          {put_unheld(if(kept == %{}, do: %{}, else: %{"world_info" => kept}), "world_info", entry), warnings}
      end

    attrs =
      Map.merge(
        %{
          name: name,
          content: content,
          activation:
            cond do
              entry["constant"] == true -> :constant
              entry["vectorized"] == true -> :vector
              true -> :keyword
            end,
          keywords: keywords,
          secondary_keywords: secondary,
          secondary_logic: Map.get(@logic, entry["selectiveLogic"], :and_any),
          case_sensitive: Text.bool(entry["caseSensitive"]),
          match_whole_words: Text.bool(entry["matchWholeWords"]),
          scan_depth: Text.pos_int(entry["scanDepth"]),
          probability: probability(entry),
          sticky: Text.pos_int(entry["sticky"]),
          cooldown: Text.pos_int(entry["cooldown"]),
          delay: Text.pos_int(entry["delay"]),
          exclude_recursion: entry["excludeRecursion"] == true,
          prevent_recursion: entry["preventRecursion"] == true,
          ignore_budget: entry["ignoreBudget"] == true,
          role: role(entry["role"]),
          trigger_only: entry["activationOnly"] == true,
          delay_until_recursion: delay_until_recursion(entry["delayUntilRecursion"]),
          foreign: foreign
        },
        location,
        fn
          :trigger_only, own, from_position -> own or from_position
          _key, _own, from_position -> from_position
        end
      )

    {attrs, enabled} =
      cond do
        "@@activate" in decorated.decorators -> {%{attrs | activation: :constant}, entry["disable"] != true}
        "@@dont_activate" in decorated.decorators -> {attrs, false}
        true -> {attrs, entry["disable"] != true}
      end

    {attrs, enabled, keyword_warnings} =
      if attrs.activation == :keyword and keywords == [] do
        warning = dgettext("import_export", "'%{entry_name}' had no keywords; imported switched off.", entry_name: name)
        {%{attrs | activation: :constant}, false, [warning]}
      else
        {attrs, enabled, []}
      end

    {order, order_warnings} =
      case order_value(entry["order"]) do
        nil ->
          {100,
           [
             dgettext("import_export", "'%{entry_name}' had no usable order; imported at %{order_value}.",
               entry_name: name,
               order_value: Format.number(100)
             )
           ]}

        order ->
          {order, []}
      end

    spec = %{
      attrs: attrs,
      order: order,
      enabled: enabled,
      character_filter: character_filter(entry["characterFilter"]),
      outlet: outlet,
      pools: pools(entry),
      memory: memory(entry, sources)
    }

    decorator_warnings =
      for line <- decorated.unknown,
          do:
            dgettext("import_export", "Unknown decorator %{decorator_line} in '%{entry_name}'.",
              decorator_line: line,
              entry_name: name
            )

    warnings =
      location_warnings ++
        primary_warnings ++
        secondary_warnings ++
        keyword_warnings ++ order_warnings ++ decorator_warnings ++ foreign_warnings

    {spec, warnings, names, decorated.decorators != [] or decorated.unknown != []}
  end

  # What Mythweaver doesn't hold of two mapped keys, kept raw so an export writes it back: a
  # non-selective entry's secondary keys, and character filter tags (with no names: the names are
  # the entry's own filter). A card book's entry keeps them in its `character_book` spellings.
  defp put_unheld(foreign, namespace, entry) do
    secondary = if entry["selective"] == true, do: [], else: Text.strings(entry["keysecondary"])
    filter = Text.map(entry["characterFilter"])
    tags = Text.strings(filter["tags"])
    filter = if tags != [], do: %{"isExclude" => filter["isExclude"] == true, "names" => [], "tags" => tags}

    case namespace do
      "world_info" ->
        unheld = %{} |> put_kept("keysecondary", secondary) |> put_kept("characterFilter", filter)
        if unheld == %{}, do: foreign, else: Map.update(foreign, "world_info", unheld, &Map.merge(&1, unheld))

      "character_book" ->
        entry_kept = put_kept(%{}, "secondary_keys", secondary)
        ext_kept = put_kept(%{}, "character_filter", filter)

        if entry_kept == %{} and ext_kept == %{} do
          foreign
        else
          cb =
            (foreign["character_book"] || %{})
            |> Map.update("entry", entry_kept, &Map.merge(&1, entry_kept))
            |> Map.update("extensions", ext_kept, &Map.merge(&1, ext_kept))
            |> Map.reject(fn {_part, kept} -> kept == %{} end)

          Map.put(foreign, "character_book", cb)
        end
    end
  end

  defp put_kept(map, _key, value) when value in [nil, []], do: map
  defp put_kept(map, key, value), do: Map.put(map, key, value)

  defp order_value(value) when is_integer(value), do: value
  defp order_value(value) when is_float(value), do: round(value)

  defp order_value(value) when is_binary(value) do
    text = String.trim(value)

    case Integer.parse(text) do
      {int, ""} ->
        int

      _other ->
        case Float.parse(text) do
          {float, ""} -> round(float)
          _other -> nil
        end
    end
  end

  defp order_value(_value), do: nil

  defp delay_until_recursion(true), do: 1
  defp delay_until_recursion(level), do: Text.pos_int(level) || 0

  # ST inclusion groups: a comma-separated list of names, sharing the entry's weight and flags.
  defp pools(%{"group" => group} = entry) when is_binary(group) do
    weight = Text.non_neg_int(entry["groupWeight"], 100)

    group
    |> String.split(~r/,\s*/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.map(
      &%{name: &1, weight: weight, override: entry["groupOverride"] == true, scored: entry["useGroupScoring"] == true}
    )
  end

  defp pools(_entry), do: []

  # Macro conversion, then ST's key shape (`st_key/2`). Returns `{keys, names, warnings}`.
  defp keys(raw, names, name) do
    {keys, {names, warnings}} =
      Enum.flat_map_reduce(raw, {names, []}, fn key, {names, warnings} ->
        {converted, names} = Text.convert(key, names)

        case st_key(converted, name) do
          {:keep, kept, key_warnings} -> {[kept], {names, warnings ++ key_warnings}}
          {:drop, warning} -> {[], {names, warnings ++ [warning]}}
        end
      end)

    {clean(keys), names, warnings}
  end

  # ST's `parseRegexFromString` (world-info.js): `/pattern/flags` with JS flags and no unescaped `/`
  # inside is a regex; anything else is text.
  defp st_key(key, name) do
    with [pattern, flags] <- Regex.run(~r{\A/([\s\S]+?)/([gimsuy]*)\z}, key, capture: :all_but_first),
         false <- Regex.match?(~r{(^|[^\\])/}, pattern) do
      sticky_warnings =
        if String.contains?(flags, "y"),
          do: [
            dgettext(
              "import_export",
              "'%{entry_name}': key %{entry_key} loses the sticky flag y, so it matches more widely than in SillyTavern.",
              entry_name: name,
              entry_key: key
            )
          ],
          else: []

      rebuilt = "/#{pattern}/#{String.replace(flags, ["g", "y"], "")}"

      cond do
        Templates.template?(rebuilt) -> {:keep, rebuilt, sticky_warnings}
        match?({:ok, _regex}, Matcher.parse_regex(rebuilt)) -> {:keep, rebuilt, sticky_warnings}
        true -> {:drop, invalid_regex(name, key)}
      end
    else
      _text -> mythweaver_key(key, name)
    end
  end

  # A key ST reads as text: kept, but warned about when Mythweaver reads it as a regex, and dropped
  # when Mythweaver reads it as a regex that won't compile (it would fail `LoreEntry` validation).
  defp mythweaver_key(key, name) do
    if Templates.template?(key) do
      {:keep, key, []}
    else
      case Matcher.parse_regex(key) do
        :literal ->
          {:keep, key, []}

        {:ok, _regex} ->
          {:keep, key,
           [
             dgettext(
               "import_export",
               "'%{entry_name}': key %{entry_key} is plain text in SillyTavern but a regex here.",
               entry_name: name,
               entry_key: key
             )
           ]}

        {:error, _reason} ->
          {:drop, invalid_regex(name, key)}
      end
    end
  end

  defp invalid_regex(name, key) do
    dgettext("import_export", "'%{entry_name}': key %{entry_key} isn't a valid regex here and was dropped.",
      entry_name: name,
      entry_key: key
    )
  end

  # SillyTavern-MemoryBooks flags its entries; they become memories with no chat or range. Its
  # summaries (arcs and up) keep their tier, as STMB's `getEntrySummaryTier` (summaryTiers.js) reads
  # it, and their sources: the summary's `stmbSourceEntryUids` plus every entry whose
  # `disabledBySummaryId` names it.
  defp memory(%{"stmemorybooks" => true} = entry, sources) do
    uid = to_string(entry["uid"])
    tier = stmb_tier(entry)
    listed = if is_list(entry["stmbSourceEntryUids"]), do: entry["stmbSourceEntryUids"], else: []
    own = if tier > 0, do: Enum.map(listed, &to_string/1) ++ Map.get(sources, uid, []), else: []

    %{uid: uid, tier: tier, source_uids: Enum.uniq(own)}
  end

  defp memory(_entry, _sources), do: nil

  defp stmb_tier(%{"stmbSummary" => true} = entry) do
    case Text.pos_int(entry["stmbSummaryTier"]) do
      nil -> 1
      tier -> min(tier, 6)
    end
  end

  defp stmb_tier(%{"stmbArc" => true}), do: 1
  defp stmb_tier(%{"type" => type}) when is_binary(type), do: if(String.downcase(type) == "arc", do: 1, else: 0)
  defp stmb_tier(_entry), do: 0

  # Summary uid => uids of the entries STMB disabled when it consolidated them into that summary.
  defp summary_sources(entries) do
    entries
    |> Enum.reject(&(&1["disabledBySummaryId"] in [nil, ""]))
    |> Enum.group_by(&to_string(&1["disabledBySummaryId"]), &to_string(&1["uid"]))
  end

  defp clean(keywords), do: keywords |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()

  defp entry_name(entry, keywords) do
    cond do
      not Text.blank?(entry["comment"]) -> String.trim(entry["comment"])
      keywords != [] -> hd(keywords)
      true -> "Entry #{entry["uid"]}"
    end
  end

  defp position(entry, name) do
    case entry["position"] do
      0 -> {%{outlet: :character, placement: :before}, nil, []}
      1 -> {%{outlet: :character, placement: :after}, nil, []}
      2 -> {%{outlet: :author_note, placement: :before}, nil, []}
      3 -> {%{outlet: :author_note, placement: :after}, nil, []}
      4 -> {%{outlet: :at_depth, depth: Text.non_neg_int(entry["depth"], 4)}, nil, []}
      5 -> {%{outlet: :examples, placement: :before}, nil, []}
      6 -> {%{outlet: :examples, placement: :after}, nil, []}
      7 -> custom_position(entry, name)
      "before_char" -> text_position(:before, name)
      "after_char" -> text_position(:after, name)
      _other -> {%{outlet: :character, placement: :before, trigger_only: true}, nil, [unknown_position(name)]}
    end
  end

  defp text_position(placement, name),
    do: {%{outlet: :character, placement: placement}, nil, [text_position_warning(placement, name)]}

  defp text_position_warning(:before, name),
    do:
      dgettext("import_export", "'%{entry_name}' stored its position as text; read as before the character.",
        entry_name: name
      )

  defp text_position_warning(:after, name),
    do:
      dgettext("import_export", "'%{entry_name}' stored its position as text; read as after the character.",
        entry_name: name
      )

  defp unknown_position(name),
    do:
      dgettext(
        "import_export",
        "'%{entry_name}' has an unknown position; imported as trigger-only (SillyTavern never inserts it).",
        entry_name: name
      )

  defp custom_position(entry, name) do
    outlet_name = Text.string(entry["outletName"]) || ""
    key = slug(outlet_name)

    if key == "" do
      warning =
        dgettext("import_export", "'%{entry_name}' had no outlet name; imported after the character.", entry_name: name)

      {%{outlet: :character, placement: :after}, nil, [warning]}
    else
      label = if Text.blank?(outlet_name), do: key, else: String.trim(outlet_name)
      {%{outlet: :custom, custom_outlet: key}, %{key: key, name: label}, []}
    end
  end

  @doc "An outlet key from a free-form name: lowercase, runs outside `[a-z0-9_]` become `_`."
  @spec slug(String.t()) :: String.t()
  def slug(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> String.trim("_")
  end

  defp probability(%{"useProbability" => false}), do: 100

  defp probability(entry) do
    case entry["probability"] do
      value when is_number(value) -> value |> round() |> max(0) |> min(100)
      _other -> 100
    end
  end

  defp character_filter(%{} = filter) do
    filter
    |> Map.get("names")
    |> Text.strings()
    |> case do
      [] ->
        nil

      names ->
        %{
          mode: if(filter["isExclude"] == true, do: :exclude, else: :include),
          names: names,
          tags: Text.strings(filter["tags"])
        }
    end
  end

  defp character_filter(_filter), do: nil
end
