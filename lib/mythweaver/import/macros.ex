defmodule Mythweaver.Import.Macros do
  @moduledoc """
  Converts SillyTavern macros to Mythweaver Liquid, so imported card, lore and prompt text parses
  and renders the same way.

  The scan runs left to right over `{{…}}` (the shortest match, names case-insensitive, inner
  whitespace trimmed) and the legacy `<USER>`-style tokens:

    * `{{char}}`, `{{charIfNotGroup}}`, `<BOT>`, `<CHAR>`, `<CHARIFNOTGROUP>` →
      `{{ anchors.character.name }}`
    * `{{user}}`, `<USER>` → `{{ anchors.player.name }}` (the chat's player character)
    * `{{group}}`, `<GROUP>` → `{{ anchors.participants }}`
    * `{{description}}` → `{{ anchors.character.description }}`; `{{persona}}` →
      `{{ anchors.player.description }}`
    * `{{newline}}` → a newline; `{{noop}}`, `{{// …}}` → nothing; `{{trim}}` → nothing, along with
      the newlines around it; `{{original}}` → nothing, unless `original: true` (a card's system
      prompt or post-history instructions), when the first becomes `{{ original }}` (the prompt
      block's own text, `Mythweaver.Prompts.Builder`) and later ones nothing, as in SillyTavern
    * `{{random::a::b}}` / `{{random:a,b}}` and `pick` → `{{ "a::b" | split: "::" | random }}`
    * `{{roll:X}}` / `{{roll X}}` → `{{ "X" | roll }}` when `Mythweaver.Dice.parse/1` accepts `X`
      (bare digits `N` mean `dN`)
    * `{{getvar::k}}` / `{{getglobalvar::k}}` → `{{ vars.k }}` / `{{ globals.k }}`
    * `{{setvar::k::v}}` / `{{setglobalvar::k::v}}` → `{% setvar k = "v" %}` /
      `{% setglobalvar k = "v" %}`

  Any other macro is kept as literal text inside `{% raw %}…{% endraw %}` and its name reported, as
  is any stray `{%` or unclosed `{{`. Text that still fails `Mythweaver.Templates.parse/1` is
  returned whole inside `raw`, reported as `"unparseable template"`.
  """

  alias Mythweaver.Dice
  alias Mythweaver.Templates

  # `Mythweaver.Variables.Variable`'s key rule, as `Mythweaver.Templates.SetVarTag` enforces.
  @key ~r/\A[A-Za-z_][A-Za-z0-9_]{0,63}\z/
  @legacy ~r/\A<(charifnotgroup|char|bot|user|group)>/i
  @list_macro ~r/\A(random|pick)\s?::?(.+)\z/is
  @roll ~r/\Aroll[ :](.+)\z/is
  @variable ~r/\A(getvar|getglobalvar|setvar|setglobalvar)::(.*)\z/is
  @separators ["::", "|", "~~"]

  # Stands in for `{{original}}` during the scan; `place_original/2` resolves it.
  @original "\uE000original\uE000"

  @doc """
  Returns `text` converted to Liquid and the distinct names of the macros left unconverted.
  `opts`: `original: true` keeps the first `{{original}}`.
  """
  @spec to_liquid(String.t() | nil, keyword()) :: {String.t(), [String.t()]}
  def to_liquid(text, opts \\ [])
  def to_liquid(nil, _opts), do: {"", []}

  def to_liquid(text, opts) when is_binary(text) do
    {liquid, names} = scan(text, "", [])
    liquid = place_original(liquid, Keyword.get(opts, :original, false))
    names = names |> Enum.reverse() |> Enum.uniq_by(&String.downcase/1)

    case Templates.parse(liquid) do
      {:ok, _template} -> {liquid, names}
      {:error, _message} -> {raw(text), names ++ ["unparseable template"]}
    end
  end

  defp place_original(liquid, true) do
    case String.split(liquid, @original, parts: 2) do
      [before, rest] -> before <> "{{ original }}" <> String.replace(rest, @original, "")
      [_none] -> liquid
    end
  end

  defp place_original(liquid, false), do: String.replace(liquid, @original, "")

  defp scan(text, acc, names) do
    case :binary.match(text, ["{{", "{%", "<"]) do
      :nomatch ->
        {acc <> text, names}

      {pos, _length} ->
        {before, rest} = :erlang.split_binary(text, pos)
        token(rest, acc <> before, names)
    end
  end

  # `{{{char}}}`: the first brace is text, as in ST, and must not open a Liquid output tag.
  defp token(<<"{{{", _::binary>> = text, acc, names) do
    <<_brace, rest::binary>> = text
    scan(rest, acc <> raw("{"), names)
  end

  defp token(<<"{{", rest::binary>>, acc, names) do
    case :binary.match(rest, "}}") do
      :nomatch ->
        scan(rest, acc <> raw("{{"), names)

      {pos, 2} ->
        {body, <<"}}", tail::binary>>} = :erlang.split_binary(rest, pos)
        macro(String.trim(body), "{{" <> body <> "}}", tail, acc, names)
    end
  end

  defp token(<<"{%", rest::binary>>, acc, names), do: scan(rest, acc <> raw("{%"), names)

  defp token(<<"<", rest::binary>> = text, acc, names) do
    case Regex.run(@legacy, text) do
      [match, name] ->
        tail = binary_part(text, byte_size(match), byte_size(text) - byte_size(match))
        scan(tail, acc <> legacy(String.downcase(name)), names)

      nil ->
        scan(rest, acc <> "<", names)
    end
  end

  defp legacy("user"), do: "{{ anchors.player.name }}"
  defp legacy("group"), do: "{{ anchors.participants }}"
  defp legacy(_char), do: "{{ anchors.character.name }}"

  # Like ST's `(?:\r?\n)*{{trim}}(?:\r?\n)*`.
  defp macro(inner, original, tail, acc, names) do
    if String.downcase(inner) == "trim" do
      scan(
        String.replace(tail, ~r/\A(?:\r?\n)+/, ""),
        String.replace(acc, ~r/(?:\r?\n)+\z/, ""),
        names
      )
    else
      case convert(inner) do
        {:ok, liquid} -> scan(tail, acc <> liquid, names)
        :unknown -> scan(tail, acc <> raw(original), add_name(names, inner))
      end
    end
  end

  defp convert(inner) do
    case String.downcase(inner) do
      name when name in ["char", "charifnotgroup", "user", "group"] -> {:ok, legacy(name)}
      "description" -> {:ok, "{{ anchors.character.description }}"}
      "persona" -> {:ok, "{{ anchors.player.description }}"}
      "newline" -> {:ok, "\n"}
      "noop" -> {:ok, ""}
      "original" -> {:ok, @original}
      "//" <> _comment -> {:ok, ""}
      _other -> if String.contains?(inner, "{{"), do: :unknown, else: parameterized(inner)
    end
  end

  # Each conversion is parsed alone, so one odd value stays literal instead of failing the text.
  defp parameterized(inner) do
    result =
      with :nomatch <- list_macro(inner),
           :nomatch <- roll(inner),
           :nomatch <- variable(inner) do
        :unknown
      end

    with {:ok, liquid} <- result,
         {:ok, _template} <- Templates.parse(liquid) do
      {:ok, liquid}
    else
      _ -> :unknown
    end
  end

  defp list_macro(inner) do
    case Regex.run(@list_macro, inner) do
      [_, filter, list] -> list_liquid(String.downcase(filter), items(list))
      nil -> :nomatch
    end
  end

  # ST splits on `::` when the list has one, else on unescaped commas, trimming each item.
  defp items(list) do
    if String.contains?(list, "::") do
      String.split(list, "::")
    else
      list
      |> String.split(~r/(?<!\\),/)
      |> Enum.map(&(&1 |> String.replace("\\,", ",") |> String.trim()))
    end
  end

  defp list_liquid(filter, items) do
    with sep when is_binary(sep) <-
           Enum.find(@separators, &(String.split(Enum.join(items, &1), &1) == items)),
         {:ok, literal} <- literal(Enum.join(items, sep)) do
      {:ok, ~s({{ #{literal} | split: "#{sep}" | #{filter} }})}
    else
      _ -> :unknown
    end
  end

  defp roll(inner) do
    case Regex.run(@roll, inner) do
      [_, dice] ->
        dice = String.trim(dice)
        dice = if Regex.match?(~r/\A\d+\z/, dice), do: "d" <> dice, else: dice

        case Dice.parse(dice) do
          {:ok, _dice} -> {:ok, ~s({{ "#{dice}" | roll }})}
          :error -> :unknown
        end

      nil ->
        :nomatch
    end
  end

  defp variable(inner) do
    case Regex.run(@variable, inner) do
      [_, macro, args] -> variable(String.downcase(macro), args)
      nil -> :nomatch
    end
  end

  defp variable(get, key) when get in ["getvar", "getglobalvar"] do
    key = String.trim(key)
    if Regex.match?(@key, key), do: {:ok, "{{ #{namespace(get)}.#{key} }}"}, else: :unknown
  end

  defp variable(set, args) do
    with [key, value] <- String.split(args, "::", parts: 2),
         key = String.trim(key),
         true <- Regex.match?(@key, key),
         {:ok, literal} <- literal(value) do
      {:ok, "{% #{set} #{key} = #{literal} %}"}
    else
      _ -> :unknown
    end
  end

  defp namespace("getvar"), do: "vars"
  defp namespace("getglobalvar"), do: "globals"

  # Liquid strings have no escapes, so the quote is whichever kind the text lacks.
  defp literal(text) do
    cond do
      not String.contains?(text, "\"") -> {:ok, ~s("#{text}")}
      not String.contains?(text, "'") -> {:ok, "'#{text}'"}
      true -> :error
    end
  end

  defp add_name(names, inner) do
    case Regex.run(~r/\A[^\s:]+/u, inner) do
      [name] -> [name | names]
      nil -> names
    end
  end

  # An `{% endraw %}` inside the text would close the block early, so its `{%` ends one raw block
  # and the rest of the tag opens the next.
  defp raw(text) do
    "{% raw %}" <>
      String.replace(text, ~r/\{%(?=-?\s*endraw)/, "{%{% endraw %}{% raw %}") <> "{% endraw %}"
  end
end
