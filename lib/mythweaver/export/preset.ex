defmodule Mythweaver.Export.Preset do
  @moduledoc """
  Writes a bundle's prompt as a SillyTavern Chat Completion preset, the inverse of
  `Mythweaver.Import.Preset`.

  Blocks become prompts in order. Mythweaver's standard blocks (`Mythweaver.Prompts.Standard`) turn
  back into ST's markers (`worldInfoBefore`, `charDescription`, `chatHistory`, …) or settings
  (`new_chat_prompt`, `group_nudge_prompt`, …); the guide, author's note and refine blocks are left
  out, since the importer adds them again. Template text goes through
  `Mythweaver.Export.Macros.to_st/1`.
  """

  alias Mythweaver.AI.Model
  alias Mythweaver.Bundle
  alias Mythweaver.Bundle.Codec
  alias Mythweaver.Export
  alias Mythweaver.Export.Macros
  alias Mythweaver.Export.WorldInfo
  alias Mythweaver.Import.Embedded
  alias Mythweaver.Import.Preset, as: ImportPreset
  alias Mythweaver.Prompts.Standard

  @examples_prefix "{% if anchors.lore.before_examples or anchors.lore.after_examples %}\n"
  @examples_suffix "\n{% if anchors.lore.before_examples %}{{ anchors.lore.before_examples }}\n" <>
                     "{% endif %}{{ anchors.lore.after_examples }}\n{% endif %}\n"
  @start_prefix "{% if anchors.chat.participants.size > 2 %}"
  @start_suffix "{% endif %}\n"
  @nudge_prefix "{% unless anchors.refine %}"
  @nudge_suffix "{% endunless %}\n"

  # `Mythweaver.Import.Writer` stores an empty ST prompt as this comment.
  @empty_block "{% comment %}Empty in the SillyTavern preset.{% endcomment %}\n"

  @doc """
  The preset file for the prompt item `prompt_uid` of `bundle`, with `sampler_model`'s sampler
  values when given. `opts`: `bundle:` (default true) adds `extensions.mythweaver`.
  """
  @spec file(Bundle.t(), String.t(), Model.t() | nil, keyword()) :: %{
          bytes: binary(),
          filename: String.t(),
          content_type: String.t(),
          warnings: [String.t()]
        }
  def file(%Bundle{} = bundle, prompt_uid, sampler_model, opts \\ []) do
    items = WorldInfo.index(bundle)
    prompt = Map.fetch!(items, prompt_uid)
    prefix = "#{prompt.data["name"] || prompt.name}: "

    blocks =
      for %{"uid" => uid} = membership <- List.wrap(prompt.data["blocks"]),
          %{kind: :prompt_block} = block <- [items[uid]],
          do: {block, membership["enabled"] != false}

    state = %{prompts: [], order: [], settings: %{}, used: MapSet.new(), names: []}
    state = Enum.reduce(blocks, state, &add_block(&1, &2, prefix))

    json =
      state.settings
      |> Map.merge(sampler(sampler_model))
      |> Map.merge(%{
        "prompts" => Enum.reverse(state.prompts),
        "prompt_order" => [%{"character_id" => 100_001, "order" => Enum.reverse(state.order)}]
      })

    json =
      if Keyword.get(opts, :bundle, true) do
        {:ok, parsed} = json |> Jason.encode!() |> Jason.decode!() |> ImportPreset.parse(prompt.name)
        Map.put(json, "extensions", %{"mythweaver" => Bundle.to_embedded(bundle, Embedded.digest(parsed))})
      else
        json
      end

    %{
      bytes: Jason.encode!(json, pretty: true),
      filename: Export.filename(prompt.name, "json"),
      content_type: "application/json",
      warnings: WorldInfo.macro_warnings(state.names)
    }
  end

  defp add_block({block, member_enabled}, state, prefix) do
    data = if block.data["content"] == @empty_block, do: Map.put(block.data, "content", ""), else: block.data
    enabled = data["enabled"] != false and member_enabled
    name = String.replace_prefix(data["name"] || block.name, prefix, "")

    case classify(data, state.used) do
      :skip ->
        state

      {:marker, id} ->
        prompt = %{"identifier" => id, "name" => name, "marker" => true, "system_prompt" => true}
        state |> emit(prompt, data, enabled) |> mark_used(id)

      {:setting, id, settings, extra_marker} ->
        {settings, names} =
          Enum.reduce(settings, {%{}, state.names}, fn {key, text}, {acc, names} ->
            {st, names} = convert(text, block.name, names)
            {Map.put(acc, key, st), names}
          end)

        state = mark_used(%{state | settings: Map.merge(state.settings, settings), names: names}, id)

        if extra_marker do
          prompt = %{"identifier" => extra_marker, "name" => name, "marker" => true, "system_prompt" => true}
          state |> emit(prompt, data, enabled) |> mark_used(extra_marker)
        else
          state
        end

      {:system_prompt, id, text} ->
        {content, names} = convert(text, block.name, state.names)
        prompt = %{"identifier" => id, "name" => name, "content" => content, "system_prompt" => true}
        %{state | names: names} |> emit(prompt, data, enabled) |> mark_used(id)

      :template ->
        {content, names} = convert(data["content"], block.name, state.names)
        prompt = %{"identifier" => block.uid, "name" => name, "content" => content, "system_prompt" => false}
        emit(%{state | names: names}, prompt, data, enabled)
    end
  end

  defp emit(state, prompt, data, enabled) do
    prompt =
      Map.merge(
        %{
          "role" => data["role"] || "system",
          "marker" => false,
          "injection_position" => 0,
          "injection_depth" => 4,
          "forbid_overrides" => data["forbid_overrides"] == true
        },
        prompt
      )

    order = %{"identifier" => prompt["identifier"], "enabled" => enabled}
    %{state | prompts: [prompt | state.prompts], order: [order | state.order]}
  end

  defp mark_used(state, id), do: %{state | used: MapSet.put(state.used, id)}

  defp convert(text, label, names) do
    case Macros.to_st(text) do
      {st, true} -> {st, [label | names]}
      {st, false} -> {st, names}
    end
  end

  # What a block becomes. A marker or setting already written once makes a repeat a plain template.
  # A block's `role_tag` makes it ST's main prompt or post-history instructions first.
  defp classify(%{"kind" => "chat_history"}, used),
    do: if(MapSet.member?(used, "chatHistory"), do: :skip, else: {:marker, "chatHistory"})

  defp classify(%{"role_tag" => "main", "content" => content}, used) when is_binary(content) do
    if MapSet.member?(used, "main"), do: :template, else: {:system_prompt, "main", content}
  end

  defp classify(%{"role_tag" => "post_history", "content" => content}, used) when is_binary(content) do
    if MapSet.member?(used, "jailbreak"), do: :template, else: jailbreak(content)
  end

  defp classify(%{"content" => content}, used) when is_binary(content) do
    content
    |> standard()
    |> case do
      {:marker, id} = marker ->
        if MapSet.member?(used, id), do: :template, else: marker

      {:setting, id, _settings, _marker} = setting ->
        if MapSet.member?(used, id), do: :template, else: setting

      {:system_prompt, "jailbreak", _text} = jailbreak ->
        if MapSet.member?(used, "jailbreak"), do: :template, else: jailbreak

      other ->
        other
    end
  end

  defp classify(_data, _used), do: :template

  defp standard(content) do
    cond do
      content == Standard.lore_before() ->
        {:marker, "worldInfoBefore"}

      content == Standard.lore_after() ->
        {:marker, "worldInfoAfter"}

      content == Standard.character() ->
        {:marker, "charDescription"}

      content == Standard.player() ->
        {:marker, "personaDescription"}

      content in [Standard.guide(), Standard.author_note(), Standard.refine()] ->
        :skip

      header = between(content, @examples_prefix, @examples_suffix) ->
        {:setting, "dialogueExamples", [{"new_example_chat_prompt", header}], "dialogueExamples"}

      middle = between(content, @start_prefix, @start_suffix) ->
        start_of_chat(middle)

      text = between(content, @nudge_prefix, @nudge_suffix) ->
        {:setting, "group_nudge", [{"group_nudge_prompt", text}], nil}

      elem(Standard.split_post_history(content), 1) != "" ->
        jailbreak(content)

      true ->
        :template
    end
  end

  defp start_of_chat(middle) do
    case :binary.split(middle, "{% else %}") do
      [group, chat] -> {:setting, "start_of_chat", [{"new_chat_prompt", chat}, {"new_group_chat_prompt", group}], nil}
      [_no_else] -> :template
    end
  end

  defp jailbreak(content) do
    {own, _suffix} = Standard.split_post_history(content)
    {:system_prompt, "jailbreak", String.trim_trailing(own)}
  end

  # The text between `prefix` and `suffix` when `content` is exactly that, else nil.
  defp between(content, prefix, suffix) do
    if String.starts_with?(content, prefix) and String.ends_with?(content, suffix) and
         byte_size(content) >= byte_size(prefix) + byte_size(suffix) do
      binary_part(content, byte_size(prefix), byte_size(content) - byte_size(prefix) - byte_size(suffix))
    end
  end

  # The reverse of the importer's sampler table; nil values are left out.
  defp sampler(%Model{sampler: sampler}) do
    values = Codec.sampler(sampler) || %{}

    for {st_key, field} <- ImportPreset.sampler_fields(),
        value = values[Atom.to_string(field)],
        into: %{},
        do: {st_key, value}
  end

  defp sampler(nil), do: %{}
end
