defmodule Mythweaver.Prompts.Completions do
  @moduledoc """
  Autocomplete and hover data for template editors, JSON-encoded into an editor's
  `data-completions` and read by `assets/js/hooks/rich_input/liquid.ts`.

  The client ships the standard Liquid tags and filters with their descriptions, so this module
  lists only Mythweaver additions: the template root, anchor/outlet/variable property paths, the
  variable tags, and Mythweaver's and Solid's extra filters. Each option is a CodeMirror
  `Completion`; `detail` and `info` are omitted when absent because CodeMirror treats a non-string
  `info` as a function.
  """

  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Prompts
  alias Mythweaver.Prompts.Anchor
  alias Mythweaver.Variables

  defp variables do
    [
      %{
        label: "anchors",
        type: "namespace",
        info: dgettext("prompts", "Chat, characters and lore for this render.")
      },
      %{
        label: "outlets",
        type: "namespace",
        info: dgettext("prompts", "Rendered custom-outlet lore by key.")
      },
      %{
        label: "vars",
        type: "namespace",
        info: dgettext("prompts", "A chat variable, falling back to a global variable with the same key.")
      },
      %{
        label: "globals",
        type: "namespace",
        info:
          dpgettext(
            "prompts",
            "tooltip: template editor hover text for the globals namespace",
            "A global variable only."
          )
      },
      %{
        label: "char",
        type: "variable",
        info:
          dgettext(
            "prompts",
            "SillyTavern's {{char}}: anchors.character.name; in a typed message, the AI character (the author when a character speaks)."
          )
      },
      %{
        label: "user",
        type: "variable",
        info:
          dpgettext(
            "prompts",
            "tooltip: template editor hover text for the user variable",
            "SillyTavern's {{user}}: anchors.player.name."
          )
      }
    ]
  end

  defp tags do
    [
      %{
        label: "setvar",
        type: "keyword",
        detail: "key = value",
        info: dgettext("prompts", "Writes a chat variable; nil deletes it.")
      },
      %{
        label: "setglobalvar",
        type: "keyword",
        detail: "key = value",
        info: dgettext("prompts", "Writes a global variable; nil deletes it.")
      }
    ]
  end

  # `{label, arguments, description}`; the arguments read as they follow the filter name.
  defp filters do
    [
      {"random", nil, dgettext("prompts", "A random element on every render; `nil` for an empty list")},
      {"pick", nil,
       dgettext(
         "prompts",
         "A \"random\" element that stays the same for a given chat, template text, and position, so a regenerated reply gets the same choice"
       )},
      {"roll", nil,
       dgettext(
         "prompts",
         ~s{Dice such as "2d6+1" or "d6": up to 999 dice (default 1) with 1–9999 sides and a ±9999 modifier. A malformed roll is reported as an error}
       )},
      {"push", ": value", dgettext("prompts", "Appends a value to a list; on `nil` it starts a new list")},
      {"to_sentence", nil,
       dgettext(
         "prompts",
         ~s(Joins an array as English: `["a", "b", "c", "d"]` → `a, b, c, and d`; two items → `a and b`; one → `a`; `[]` or `nil` → empty. A non-array is reported as an error)
       )},
      {"squish", nil, dgettext("prompts", "Trims the text and collapses each run of whitespace to one space")},
      {"replace_last", ": search, replacement", dgettext("prompts", "Replaces the last occurrence of search")},
      {"remove_last", ": search", dgettext("prompts", "Removes the last occurrence of search")},
      {"base64_encode", nil,
       dpgettext(
         "prompts",
         "tooltip: template editor hover text for the base64_encode filter",
         "The text, Base64-encoded"
       )},
      {"base64_decode", nil,
       dpgettext("prompts", "tooltip: template editor hover text for the base64_decode filter", "Decodes Base64 text")},
      {"base64_url_safe_encode", nil, dgettext("prompts", "The text, Base64-encoded with the URL-safe alphabet")},
      {"base64_url_safe_decode", nil,
       dpgettext(
         "prompts",
         "tooltip: template editor hover text for the base64_url_safe_decode filter",
         "Decodes URL-safe Base64 text"
       )}
    ]
    |> Enum.map(fn {label, detail, info} ->
      Map.reject(%{label: label, type: "function", detail: detail, info: info}, fn {_, v} -> is_nil(v) end)
    end)
  end

  @doc """
  Completion data for a template; `chat_id` scopes `vars` to that chat's variables. A chat `scope` may
  not act on contributes no chat variables. Outlets and globals are those `scope` may use (own plus
  site, one per key).
  """
  @spec template(Scope.t(), Ecto.UUID.t() | nil) :: map()
  def template(%Scope{} = scope, chat_id \\ nil) do
    globals = scope |> Variables.list_usable_global_variables() |> Enum.map(& &1.key) |> Enum.uniq()

    %{
      variables: variables(),
      properties:
        anchor_properties()
        |> Map.put("outlets", outlet_options(scope))
        |> Map.put("globals", Enum.map(globals, &variable(&1, "global")))
        |> Map.put("vars", var_options(scope, chat_id, globals)),
      tags: tags(),
      filters: filters()
    }
  end

  # Memory paths are listed for every editor: a block does not know which purpose's prompts hold it.
  defp anchor_properties do
    (Anchor.catalog() ++ Anchor.memory_catalog())
    |> Enum.flat_map(fn entry ->
      segments = String.split(entry.path, ".")
      last = length(segments) - 1

      options =
        for i <- 1..last//1 do
          key = segments |> Enum.take(i) |> Enum.join(".")
          label = Enum.at(segments, i)

          option =
            if i == last,
              do: compact(%{label: label, type: "property", detail: entry.type, info: entry.description}),
              else: %{label: label, type: "namespace"}

          {key, option}
        end

      fields =
        for {name, type} <- Map.get(entry, :fields, []),
            do: {entry.path <> ".[]", %{label: name, type: "property", detail: type}}

      options ++ fields
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {key, options} -> {key, Enum.uniq_by(options, & &1.label)} end)
  end

  defp outlet_options(scope) do
    for o <- Prompts.list_outlets(scope),
        do: compact(%{label: o.key, type: "property", detail: o.name, info: o.description})
  end

  defp var_options(_scope, nil, globals), do: Enum.map(globals, &variable(&1, "global"))

  defp var_options(scope, chat_id, globals) do
    chat = Enum.map(Variables.list_chat_variables(scope, chat_id), & &1.key)
    Enum.map(chat, &variable(&1, "chat")) ++ for(k <- globals, k not in chat, do: variable(k, "global"))
  end

  defp variable(key, detail), do: %{label: key, type: "variable", detail: detail}

  defp compact(option), do: option |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()
end
