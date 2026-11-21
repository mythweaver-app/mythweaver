defmodule Mythweaver.Import.Preset do
  @moduledoc """
  Parses a SillyTavern Chat Completion preset into prompt blocks and sampler values.

  Marker prompts become Mythweaver's own functional blocks (`Mythweaver.Prompts.Standard`);
  `chatHistory` expands to "Start of chat", "Chat history", "Guide" and "Author's note". Prompts
  injected in-chat at depth are placed right after "Chat history". "Group nudge" (when set) and
  "Refine" close the list. `extensions.mythweaver` (a Mythweaver export's bundle) is passed on as
  `embedded` for `Mythweaver.Import.Embedded.resolve/1`.
  """

  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.AI.SamplerParams
  alias Mythweaver.Import.Embedded
  alias Mythweaver.Import.Text
  alias Mythweaver.Prompts.Standard

  @type block :: %{
          optional(:role_tag) => :main | :post_history,
          optional(:forbid_overrides) => boolean(),
          name: String.t(),
          role: :system | :user | :assistant,
          kind: :template | :chat_history,
          content: String.t() | nil,
          enabled: boolean()
        }

  @type t :: %{
          kind: :preset,
          name: String.t(),
          blocks: [block()],
          sampler: map(),
          ignored: [String.t()],
          warnings: [String.t()],
          unconverted: [String.t()],
          embedded: map() | nil
        }

  @sampler [
    {"temperature", :temperature},
    {"top_p", :top_p},
    {"top_k", :top_k},
    {"top_a", :top_a},
    {"min_p", :min_p},
    {"repetition_penalty", :repetition_penalty},
    {"frequency_penalty", :frequency_penalty},
    {"presence_penalty", :presence_penalty},
    {"openai_max_tokens", :max_tokens},
    {"seed", :seed}
  ]

  @doc "The sampler keys a preset carries, as `{preset key, SamplerParams field}`."
  @spec sampler_fields() :: [{String.t(), atom()}]
  def sampler_fields, do: @sampler

  # {key, default that counts as "not customized"}
  @ignorable [
    {"impersonation_prompt", nil},
    {"continue_nudge_prompt", nil},
    {"assistant_prefill", nil},
    {"assistant_impersonation", nil},
    {"wi_format", "{0}"},
    {"scenario_format", "{{scenario}}"},
    {"personality_format", "{{personality}}"}
  ]

  @standard_ids ~w(worldInfoBefore worldInfoAfter charDescription personaDescription charPersonality scenario dialogueExamples chatHistory)

  @spec parse(map(), String.t()) :: {:ok, t()}
  def parse(json, name) do
    prompts = json["prompts"] |> List.wrap() |> Enum.filter(&is_map/1)
    by_id = Map.new(prompts, &{&1["identifier"], &1})

    state = %{main: [], deferred: [], warnings: [], names: []}

    state =
      json
      |> order(prompts)
      |> Enum.reduce(state, fn {id, enabled}, state ->
        case Map.fetch(by_id, id) do
          {:ok, prompt} -> add_prompt(state, json, name, id, prompt, enabled)
          :error -> state
        end
      end)

    tail =
      state.deferred ++ [block(name, "Guide", Standard.guide()), block(name, "Author's note", Standard.author_note())]

    main =
      if :history_slot in state.main,
        do: Enum.flat_map(state.main, &if(&1 == :history_slot, do: tail, else: [&1])),
        else: state.main ++ tail

    {nudge, names} =
      if Text.blank?(json["group_nudge_prompt"]) do
        {[], state.names}
      else
        {text, names} = Text.convert(json["group_nudge_prompt"], state.names)
        {[block(name, "Group nudge", Standard.group_nudge(text))], names}
      end

    blocks = main ++ nudge ++ [block(name, "Refine", Standard.refine())]
    {sampler, sampler_warnings} = sampler(json)
    ignored = ignored(json)

    ignored_warnings =
      if ignored == [],
        do: [],
        else: [
          dpgettext(
            "import_export",
            "status: import warning, SillyTavern preset settings not imported",
            "Not imported: %{setting_keys}",
            setting_keys: Enum.join(ignored, ", ")
          )
        ]

    {:ok,
     %{
       kind: :preset,
       name: name,
       blocks: blocks,
       sampler: sampler,
       ignored: ignored,
       warnings: state.warnings ++ sampler_warnings ++ ignored_warnings,
       unconverted: names,
       embedded: Embedded.extract(json["extensions"])
     }}
  end

  defp order(json, prompts) do
    orders = json["prompt_order"] |> List.wrap() |> Enum.filter(&is_map/1)

    chosen =
      Enum.find(orders, &(&1["character_id"] == 100_001)) ||
        Enum.find(orders, &(&1["character_id"] == 100_000)) || List.first(orders)

    case chosen do
      nil ->
        Enum.map(prompts, &{&1["identifier"], true})

      %{} ->
        chosen["order"]
        |> List.wrap()
        |> Enum.filter(&is_map/1)
        |> Enum.map(&{&1["identifier"], &1["enabled"] != false})
    end
  end

  defp add_prompt(state, json, preset, id, prompt, enabled) do
    label = prompt_name(prompt, id)

    if id not in @standard_ids and prompt["injection_position"] == 1 do
      {content, names} = Text.convert(Text.string(prompt["content"]) || "", state.names)
      depth = prompt["injection_depth"] || 4

      %{
        state
        | deferred: state.deferred ++ [block(preset, label, content, role(prompt), enabled)],
          names: names,
          warnings:
            state.warnings ++
              [
                dgettext(
                  "import_export",
                  "'%{block_name}' was placed after chat history (it was inserted at depth %{depth}).",
                  block_name: label,
                  depth: Mythweaver.Format.number(depth)
                )
              ]
      }
    else
      {blocks, names} = blocks(id, prompt, json, preset, label, enabled, state.names)
      %{state | main: state.main ++ blocks, names: names}
    end
  end

  defp blocks("worldInfoBefore", p, _json, preset, label, enabled, names),
    do: {[block(preset, label, Standard.lore_before(), role(p), enabled)], names}

  defp blocks("worldInfoAfter", p, _json, preset, label, enabled, names),
    do: {[block(preset, label, Standard.lore_after(), role(p), enabled)], names}

  defp blocks("charDescription", p, _json, preset, label, enabled, names),
    do: {[block(preset, label, Standard.character(), role(p), enabled)], names}

  defp blocks("personaDescription", p, _json, preset, label, enabled, names),
    do: {[block(preset, label, Standard.player(), role(p), enabled)], names}

  defp blocks(id, _p, _json, _preset, _label, _enabled, names) when id in ["charPersonality", "scenario"],
    do: {[], names}

  defp blocks("dialogueExamples", p, json, preset, label, enabled, names) do
    {header, names} = setting(json, "new_example_chat_prompt", "[Example chat]", names)
    {[block(preset, label, Standard.example_dialogue(header), role(p), enabled)], names}
  end

  defp blocks("chatHistory", _p, json, preset, _label, enabled, names) do
    {new_chat, names} = setting(json, "new_chat_prompt", "[Start a new chat]", names)

    {new_group, names} =
      setting(
        json,
        "new_group_chat_prompt",
        "[Start a new group chat. Group members: {{ anchors.participants }}]",
        names
      )

    history = %{
      name: "#{preset}: Chat history",
      role: :system,
      kind: :chat_history,
      content: nil,
      enabled: enabled
    }

    start = block(preset, "Start of chat", Standard.start_of_chat(new_chat, new_group), :system, enabled)
    {[start, history, :history_slot], names}
  end

  defp blocks("jailbreak", p, _json, preset, label, enabled, names) do
    {content, names} = Text.convert(Text.string(p["content"]) || "", names)
    tags = %{role_tag: :post_history, forbid_overrides: p["forbid_overrides"] == true}
    {[block(preset, label, content <> "\n" <> Standard.post_history(), role(p), enabled, tags)], names}
  end

  # A card's system prompt replaces the main prompt, unless the preset forbids overrides.
  defp blocks(id, p, _json, preset, label, enabled, names) do
    {content, names} = Text.convert(Text.string(p["content"]) || "", names)
    extra = if id == "main", do: %{role_tag: :main, forbid_overrides: p["forbid_overrides"] == true}, else: %{}
    {[block(preset, label, content, role(p), enabled, extra)], names}
  end

  # A missing setting uses the default; an explicit string (even blank) is converted as given.
  defp setting(json, key, default, names) do
    case Text.string(json[key]) do
      nil -> {default, names}
      text -> Text.convert(text, names)
    end
  end

  defp prompt_name(prompt, id) do
    if Text.blank?(prompt["name"]), do: to_string(id), else: String.trim(prompt["name"])
  end

  defp block(preset, label, content, role \\ :system, enabled \\ true, extra \\ %{}) do
    Map.merge(%{name: "#{preset}: #{label}", role: role, kind: :template, content: content, enabled: enabled}, extra)
  end

  defp role(prompt) do
    case prompt["role"] do
      "user" -> :user
      "assistant" -> :assistant
      _other -> :system
    end
  end

  defp sampler(json) do
    Enum.reduce(@sampler, {%{}, []}, fn {st_key, field}, {acc, warnings} ->
      value = json[st_key]

      cond do
        is_nil(value) ->
          {acc, warnings}

        field == :seed and is_number(value) and value < 0 ->
          {acc, warnings}

        SamplerParams.changeset(%SamplerParams{}, %{field => value}).valid? ->
          {Map.put(acc, field, value), warnings}

        true ->
          warning =
            dgettext(
              "import_export",
              "Sampler %{sampler_key} = %{sampler_value} is out of range and was skipped.",
              sampler_key: st_key,
              sampler_value: format(value)
            )

          {acc, warnings ++ [warning]}
      end
    end)
  end

  defp format(value) when is_binary(value) or is_number(value), do: to_string(value)
  defp format(value), do: inspect(value)

  defp ignored(json) do
    for {key, default} <- @ignorable,
        value = json[key],
        is_binary(value) and not Text.blank?(value) and value != default,
        do: key
  end
end
