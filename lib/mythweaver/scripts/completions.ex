defmodule Mythweaver.Scripts.Completions do
  @moduledoc """
  Autocomplete and hover data for the Lua script editor, JSON-encoded into its `data-completions`
  and read by `assets/js/hooks/rich_input/lua.ts`.

  The client ships Lua's keywords and the sandbox's standard library, so this module lists only
  Mythweaver additions: the `event` fields of the script's trigger and every host function, taken
  from `Mythweaver.Scripts.API.functions/0` so a new one is offered without listing it here. The
  editor's hover tooltips read the same data. Each option is a CodeMirror `Completion`; `info` is
  omitted when absent because CodeMirror treats a non-string `info` as a function.
  """

  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.Scripts
  alias Mythweaver.Scripts.API

  defp info("event"), do: dgettext("scripts", "This run's event. Its fields depend on the trigger.")

  defp info("mw"),
    do: dgettext("scripts", ~s(Mythweaver host functions. A malformed call raises; a refusal returns nil, "<reason>".))

  defp info("mw.messages"),
    do:
      dgettext(
        "scripts",
        "The current chat's transcript. A message is {id, number, position, character_id, author = {id, name}, author_is_player, text, visible_to_ai, generating, version, version_count, created_at}."
      )

  defp info("mw.images"),
    do:
      dgettext(
        "scripts",
        "Images attached to the current chat's messages, and the text descriptions non-vision models read in their place."
      )

  defp info("mw.generation"),
    do:
      dgettext(
        "scripts",
        "Starts AI replies in the current chat. Only user_message, command, quick_reply and inline scripts may start one."
      )

  defp info("mw.memory"),
    do:
      dgettext(
        "scripts",
        "Memory Books for the current chat: queue scene and catch-up jobs, run side prompts, and manage the processed boundary."
      )

  defp info("mw.characters"),
    do:
      dgettext(
        "scripts",
        "Every character. A character is {id, name, description, pronouns, creator, creator_notes, character_version, talkativeness}."
      )

  defp info("mw.prompts"),
    do: dgettext("scripts", "Prompts and their blocks. A prompt is {id, name, enabled, purpose, blocks}.")

  defp info("mw.blocks"), do: dgettext("scripts", "A prompt block's own switch, in every prompt that holds it.")

  defp info("mw.lore"),
    do:
      dpgettext(
        "scripts",
        "tooltip: script editor hover text for the mw.lore namespace",
        "Lore books and their entries."
      )

  defp info("mw.commands"), do: dgettext("scripts", "Command palette scripts, called like functions.")

  defp info("regex"),
    do:
      dgettext(
        "scripts",
        "PCRE regular expressions. A match is {text, start, finish, groups, named} with byte positions; flags are i m s x U."
      )

  defp info(_path), do: nil

  @doc """
  Completion data for a script of `trigger` (atom or string; anything else lists only the common
  `event` fields): `globals` for a bare name, `members` for the part after `path.`.
  """
  @spec lua(atom() | String.t() | nil) :: %{globals: [map()], members: %{String.t() => [map()]}}
  def lua(trigger) do
    {globals, members} = API.functions() |> Enum.flat_map(&function_options/1) |> Enum.split_with(&match?({nil, _}, &1))

    %{
      globals: [namespace("event") | globals |> Enum.map(&elem(&1, 1)) |> Enum.uniq_by(& &1.label)],
      members:
        members
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Map.new(fn {path, options} -> {path, Enum.uniq_by(options, & &1.label)} end)
        |> Map.put("event", event_fields(trigger))
    }
  end

  # `{parent, option}` for one host function: each prefix of its path as a namespace under its parent
  # (nil: a global), then the function itself under its path.
  defp function_options({signature, info}) do
    %{"path" => path, "name" => name, "args" => args} =
      Regex.named_captures(~r/\A(?<path>[\w.]+)\.(?<name>\w+)(?<args>\(.*\))\z/, signature)

    segments = String.split(path, ".")

    namespaces =
      for i <- 1..length(segments)//1 do
        parent = if i > 1, do: segments |> Enum.take(i - 1) |> Enum.join(".")
        {parent, segments |> Enum.take(i) |> Enum.join(".") |> namespace()}
      end

    namespaces ++ [{path, %{label: name, type: "function", detail: args, info: info}}]
  end

  defp namespace(path) do
    label = path |> String.split(".") |> List.last()
    compact(%{label: label, type: "namespace", info: info(path)})
  end

  defp event_fields(trigger) do
    fields =
      case Enum.find(Scripts.event_reference(), &(to_string(&1.trigger) == to_string(trigger))) do
        nil -> []
        event -> event.fields
      end

    for {name, type, description} <- Scripts.common_event_fields() ++ fields,
        do: %{label: name, type: "property", detail: type, info: description}
  end

  defp compact(option), do: option |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()
end
