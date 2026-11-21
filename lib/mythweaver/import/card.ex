defmodule Mythweaver.Import.Card do
  @moduledoc """
  Normalizes a Character Card (V1, V2, V3, or Pygmalion JSON) into a `t:t/0` map.

  Card text with no `Character` column becomes constant lore entries (`card_fields`) for the card
  book; their location uses `LoreEntry`'s real `outlet` + `placement` fields (e.g. `:character` /
  `:after` is the `after_character` slot). They ignore the budget and don't feed recursion, as
  SillyTavern never counts card fields as World Info. The system prompt and post-history
  instructions are the character's own fields (`{{original}}` kept as `{{ original }}`), which the
  prompt builder puts in place of the prompt's tagged blocks. `world` is the World Info book the
  card links (`extensions.world`), `tags` its tags, and `foreign` its unmapped `data` and
  `extensions` keys. A V2/V3 card's `extensions.mythweaver` (a Mythweaver export's bundle) is passed
  on as `embedded` for `Mythweaver.Import.Embedded.resolve/1`.
  """

  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.Import.Embedded
  alias Mythweaver.Import.Text
  alias Mythweaver.Import.WorldInfo

  @type t :: %{
          kind: :character,
          name: String.t(),
          description: String.t() | nil,
          first_message: String.t() | nil,
          alternate_greetings: [String.t()],
          group_greetings: [String.t()],
          creator: String.t() | nil,
          creator_notes: String.t() | nil,
          character_version: String.t() | nil,
          talkativeness: float() | nil,
          system_prompt: String.t() | nil,
          post_history_instructions: String.t() | nil,
          world: String.t() | nil,
          tags: [String.t()],
          foreign: map(),
          card_fields: [WorldInfo.entry_spec()],
          book: WorldInfo.book_spec() | nil,
          avatar: binary() | nil,
          warnings: [String.t()],
          unconverted: [String.t()],
          embedded: map() | nil
        }

  @specs ["chara_card_v2", "chara_card_v3"]

  # `assets` is CHARX's: the avatar is read from it (`Mythweaver.Import.Charx`), and an export writes its own.
  @mapped_data ~w(name description personality scenario first_mes mes_example creator_notes system_prompt
    post_history_instructions alternate_greetings group_only_greetings tags creator character_version
    extensions character_book assets)
  @mapped_ext ~w(talkativeness depth_prompt mythweaver)

  # {source key, entry name, location attrs, order}
  @fields [
    {"personality", "Personality", %{outlet: :character, placement: :after}, 100},
    {"scenario", "Scenario", %{outlet: :character, placement: :after}, 100},
    {"mes_example", "Example dialogue", %{outlet: :examples, placement: :after}, 100}
  ]

  @doc """
  The card fields that become constant entries of the card book: `{source key, entry name, location
  attrs, membership order}`.
  """
  @spec fields() :: [{String.t(), String.t(), map(), non_neg_integer()}]
  def fields, do: @fields

  @spec normalize(map()) :: {:ok, t()} | {:error, String.t()}
  def normalize(json) when is_map(json) do
    {src, ext, talk} = source(json)
    name = src |> Map.get("name") |> Text.string()

    if Text.blank?(name) do
      {:error, no_name()}
    else
      name = String.trim(name)
      {description, names} = convert_optional(src["description"], [])

      {first_message, names} =
        if Text.blank?(src["first_mes"]), do: {nil, names}, else: Text.convert(src["first_mes"], names)

      {alternate_greetings, names} = convert_all(Text.strings(src["alternate_greetings"]), names)
      {group_greetings, names} = convert_all(Text.strings(src["group_only_greetings"]), names)
      {fields, names} = card_fields(src, ext, names)
      {book, warnings, names} = book(src["character_book"], name, names)
      {system_prompt, names} = card_prompt(src["system_prompt"], names)
      {post_history, names} = card_prompt(src["post_history_instructions"], names)
      {foreign, foreign_warnings} = foreign(json, src, ext, name)

      {:ok,
       %{
         kind: :character,
         name: name,
         description: description,
         first_message: first_message,
         alternate_greetings: alternate_greetings,
         group_greetings: group_greetings,
         creator: Text.string(src["creator"]),
         creator_notes: Text.string(src["creator_notes"]),
         character_version: Text.string(src["character_version"]),
         talkativeness: talkativeness(talk),
         system_prompt: system_prompt,
         post_history_instructions: post_history,
         world: world(ext["world"]),
         tags: tags(src["tags"]),
         foreign: foreign,
         card_fields: fields,
         book: book,
         avatar: nil,
         warnings: warnings ++ foreign_warnings,
         unconverted: names,
         embedded: Embedded.extract(ext)
       }}
    end
  end

  def normalize(_json), do: {:error, no_name()}

  defp no_name, do: dgettext("import_export", "This card has no name.")

  defp card_prompt(text, names) do
    if Text.blank?(text), do: {nil, names}, else: Text.convert(text, names, original: true)
  end

  defp world(world) when is_binary(world) do
    case String.trim(world) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp world(_world), do: nil

  defp tags(tags) do
    tags
    |> Text.strings()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.take(50)
  end

  # A V2/V3 card's `data` and `extensions` keys nothing maps; `world` and `fav` stay so they round-trip.
  defp foreign(%{"spec" => spec, "data" => data}, src, ext, name) when spec in @specs and is_map(data) do
    {data, data_warnings} = Text.foreign(src, @mapped_data, name)
    {extensions, ext_warnings} = Text.foreign(ext, @mapped_ext, name)

    foreign = Map.reject(%{"data" => data, "extensions" => extensions}, fn {_key, kept} -> kept == %{} end)
    {foreign, data_warnings ++ ext_warnings}
  end

  defp foreign(_json, _src, _ext, _name), do: {%{}, []}

  defp source(%{"spec" => spec, "data" => data}) when spec in @specs and is_map(data) do
    ext = Text.map(data["extensions"])
    {data, ext, ext["talkativeness"]}
  end

  defp source(%{"char_name" => _} = json) do
    pyg = %{
      "name" => json["char_name"],
      "description" => json["char_persona"],
      "scenario" => json["world_scenario"],
      "mes_example" => json["example_dialogue"],
      "first_mes" => json["char_greeting"]
    }

    {Map.merge(json, pyg), %{}, json["talkativeness"]}
  end

  defp source(json) do
    notes = Text.string(json["creatorcomment"]) || json["creator_notes"]
    {Map.put(json, "creator_notes", notes), %{}, json["talkativeness"]}
  end

  defp convert_optional(text, names) do
    if is_binary(text), do: Text.convert(text, names), else: {nil, names}
  end

  # Blank and non-text greetings are skipped, as SillyTavern does.
  defp convert_all(texts, names) do
    texts |> Enum.reject(&Text.blank?/1) |> Enum.map_reduce(names, &Text.convert/2)
  end

  defp card_fields(src, ext, names) do
    {specs, names} =
      Enum.reduce(@fields, {[], names}, fn {key, label, location, order}, {acc, names} ->
        text = Text.string(src[key])

        if Text.blank?(text) do
          {acc, names}
        else
          text = if key == "mes_example", do: examples(text), else: text
          {content, names} = Text.convert(text, names)
          {[entry(label, content, location, order) | acc], names}
        end
      end)

    depth_prompt = Text.map(ext["depth_prompt"])
    prompt = Text.string(depth_prompt["prompt"])

    if Text.blank?(prompt) do
      {Enum.reverse(specs), names}
    else
      {content, names} = Text.convert(prompt, names)

      location = %{
        outlet: :at_depth,
        depth: Text.non_neg_int(depth_prompt["depth"], 4),
        role: WorldInfo.role(depth_prompt["role"])
      }

      {Enum.reverse([entry("Depth prompt", content, location, 100) | specs]), names}
    end
  end

  # SillyTavern never charges card fields to the World Info budget, nor scans them for recursion.
  defp entry(name, content, location, order) do
    attrs =
      Map.merge(
        %{
          name: name,
          content: content,
          activation: :constant,
          keywords: [],
          secondary_keywords: [],
          ignore_budget: true,
          prevent_recursion: true
        },
        location
      )

    %{attrs: attrs, order: order, enabled: true, character_filter: nil, outlet: nil, pools: [], memory: nil}
  end

  # Drops a leading `<START>` line and turns every other one into an `[Example chat]` header.
  defp examples(text) do
    lines = text |> String.split(~r/\r?\n/) |> Enum.drop_while(&(String.trim(&1) == ""))

    lines =
      case lines do
        [first | rest] -> if start?(first), do: rest, else: lines
        [] -> []
      end

    Enum.map_join(lines, "\n", &if(start?(&1), do: "[Example chat]", else: &1))
  end

  defp start?(line), do: String.upcase(String.trim(line)) == "<START>"

  defp book(%{"entries" => entries} = cb, name, names) when is_list(entries) do
    spec = WorldInfo.character_book(cb, "#{name} (lore)")
    {Map.take(spec, [:name, :book, :entries]), spec.warnings, names ++ spec.unconverted}
  end

  defp book(_cb, _name, names), do: {nil, [], names}

  defp talkativeness(value) when is_number(value), do: clamp(value / 1)

  defp talkativeness(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {float, _rest} -> clamp(float)
      :error -> nil
    end
  end

  defp talkativeness(_value), do: nil

  defp clamp(float), do: float |> max(0.0) |> min(1.0)
end
