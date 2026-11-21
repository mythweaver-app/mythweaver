defmodule Mythweaver.Export.Macros do
  @moduledoc """
  Converts Mythweaver Liquid back to SillyTavern macros for external exports, inverting the shapes
  `Mythweaver.Import.Macros.to_liquid/1` emits:

    * `{{ anchors.character.name }}` and its root alias `{{ char }}` → `{{char}}`;
      `{{ anchors.player.name }}` and `{{ user }}` → `{{user}}`; `{{ anchors.participants }}` →
      `{{group}}`
    * `{{ anchors.character.description }}` → `{{description}}`;
      `{{ anchors.player.description }}` → `{{persona}}`; `{{ original }}` → `{{original}}`
    * `{{ vars.k }}` / `{{ globals.k }}` → `{{getvar::k}}` / `{{getglobalvar::k}}`
    * `{% setvar k = "v" %}` / `{% setglobalvar k = "v" %}` → `{{setvar::k::v}}` /
      `{{setglobalvar::k::v}}`
    * `{{ "X" | roll }}` → `{{roll:X}}`
    * `{{ "a::b" | split: "::" | random }}` and `pick` → `{{random::a::b}}` / `{{pick::a::b}}`

  `{% raw %}…{% endraw %}` blocks become their inner text verbatim and are never rewritten, so
  the consecutive blocks `Import.Macros` writes around a literal `{% endraw %}` rejoin. Any other
  `{{` or `{%` outside raw blocks is left as is and reported.
  """

  use Gettext, backend: Mythweaver.Gettext

  @raw ~r/\{%-?\s*raw\s*-?%\}(.*?)\{%-?\s*endraw\s*-?%\}/s
  @key "[A-Za-z_][A-Za-z0-9_]{0,63}"
  @string ~S{(?:"([^"]*)"|'([^']*)')}

  # Each path must fill the whole tag (`@outputs`), so `char` never matches `characters`.
  @anchors [
    {"anchors\\.character\\.name", "{{char}}"},
    {"char", "{{char}}"},
    {"anchors\\.player\\.name", "{{user}}"},
    {"user", "{{user}}"},
    {"anchors\\.participants", "{{group}}"},
    {"anchors\\.character\\.description", "{{description}}"},
    {"anchors\\.player\\.description", "{{persona}}"},
    {"original", "{{original}}"}
  ]

  @outputs Enum.map(@anchors, fn {path, st} ->
             {Regex.compile!("\\A\\{\\{\\s*#{path}\\s*\\}\\}"), st}
           end)
  @variable Regex.compile!("\\A\\{\\{\\s*(vars|globals)\\.(#{@key})\\s*\\}\\}")
  @setvar Regex.compile!("\\A\\{%\\s*(setvar|setglobalvar)\\s+(#{@key})\\s*=\\s*#{@string}\\s*%\\}")
  @roll Regex.compile!("\\A\\{\\{\\s*#{@string}\\s*\\|\\s*roll\\s*\\}\\}")
  @list Regex.compile!("\\A\\{\\{\\s*#{@string}\\s*\\|\\s*split:\\s*#{@string}\\s*\\|\\s*(random|pick)\\s*\\}\\}")

  @doc """
  Returns `text` with Liquid converted to SillyTavern macros, and whether Liquid that SillyTavern
  can't run remains.
  """
  @spec to_st(String.t() | nil) :: {String.t(), boolean()}
  def to_st(nil), do: {"", false}

  def to_st(text) when is_binary(text) do
    {acc, left?, pos} =
      @raw
      |> Regex.scan(text, return: :index)
      |> Enum.reduce({"", false, 0}, fn [{start, length}, {inner, inner_length}], {acc, left?, pos} ->
        {converted, part_left?} = scan(binary_part(text, pos, start - pos), "", false)
        raw = binary_part(text, inner, inner_length)
        {acc <> converted <> raw, left? or part_left?, start + length}
      end)

    {converted, rest_left?} = scan(binary_part(text, pos, byte_size(text) - pos), "", false)
    {acc <> converted, left? or rest_left?}
  end

  @doc """
  The warning callers add once per export when `to_st/1` reported leftover Liquid in `names`.
  """
  @spec warning([String.t()]) :: String.t()
  def warning(names) do
    gettext_comment(
      "Export warning; the placeholder is a comma-separated list of the field and entry names whose text keeps Mythweaver templates."
    )

    dgettext("import_export", "Some text uses Mythweaver templates SillyTavern can't run: %{field_names}.",
      field_names: Enum.join(names, ", ")
    )
  end

  defp scan(text, acc, left?) do
    case :binary.match(text, ["{{", "{%"]) do
      :nomatch ->
        {acc <> text, left?}

      {pos, _length} ->
        {before, rest} = :erlang.split_binary(text, pos)

        case convert(rest) do
          {:ok, st, length} ->
            scan(binary_part(rest, length, byte_size(rest) - length), acc <> before <> st, left?)

          :error ->
            <<open::binary-size(2), tail::binary>> = rest
            scan(tail, acc <> before <> open, true)
        end
    end
  end

  defp convert(text) do
    Enum.find_value(@outputs, fn {regex, st} -> match(regex, text, fn _ -> st end) end) ||
      match(@variable, text, fn [ns, key] -> "{{#{getter(ns)}::#{key}}}" end) ||
      match(@setvar, text, fn [set, key | value] -> "{{#{set}::#{key}::#{string(value)}}}" end) ||
      match(@roll, text, fn dice -> "{{roll:#{string(dice)}}}" end) ||
      match(@list, text, &list/1) ||
      :error
  end

  defp match(regex, text, fun) do
    with [whole | captures] <- Regex.run(regex, text),
         st when is_binary(st) <- fun.(captures),
         true <- macro_safe?(st) do
      {:ok, st, byte_size(whole)}
    else
      _ -> nil
    end
  end

  # ST closes a macro at the first `}}`, so a value holding braces can't be written as one.
  defp macro_safe?("{{" <> inner) do
    inner = String.replace_suffix(inner, "}}", "")
    not String.contains?(inner, ["{{", "}}"])
  end

  defp getter("vars"), do: "getvar"
  defp getter("globals"), do: "getglobalvar"

  # Captures of `@string`: the double-quoted group, else the single-quoted one (an unmatched
  # middle group captures `""`, a trailing one is omitted).
  defp string(["" | rest]), do: Enum.join(rest)
  defp string([double | _]), do: double

  defp list([list_double, list_single, sep_double, sep_single, filter]) do
    list = string([list_double, list_single])
    sep = string([sep_double, sep_single])
    items = if sep != "", do: String.split(list, sep)

    if items && String.split(Enum.join(items, "::"), "::") == items do
      "{{#{filter}::#{Enum.join(items, "::")}}}"
    end
  end
end
