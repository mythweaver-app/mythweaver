defmodule Mythweaver.Import.Decorators do
  @moduledoc """
  SillyTavern's World Info decorators: leading `@@` lines of an entry's content, a port of
  `parseDecorators` (public/scripts/world-info.js).

  Only content starting with `@@` has decorators. Each leading line starting with `@@` is one: a
  known one (`@@activate`, `@@dont_activate`; `@@@` escapes it to a fallback) is kept, an unknown
  one is reported in `unknown`. A `@@@` line is skipped unless it follows an unknown decorator. The
  first line not starting with `@@` and everything after it is the content; when every line starts
  with `@@`, the content is left as it was (the decorators still apply).
  """

  @known ["@@activate", "@@dont_activate"]

  @spec parse(String.t()) :: %{decorators: [String.t()], unknown: [String.t()], content: String.t()}
  def parse("@@" <> _ = content) do
    walk(String.split(content, "\n"), false, %{decorators: [], unknown: [], content: content})
  end

  def parse(content), do: %{decorators: [], unknown: [], content: content}

  defp walk([], _fallbacked, acc), do: finish(acc)

  defp walk(["@@" <> _ = line | rest], fallbacked, acc) do
    cond do
      String.starts_with?(line, "@@@") and not fallbacked ->
        walk(rest, fallbacked, acc)

      known?(line) ->
        walk(rest, false, %{acc | decorators: [unescape(line) | acc.decorators]})

      true ->
        walk(rest, true, %{acc | unknown: [line | acc.unknown]})
    end
  end

  defp walk(lines, _fallbacked, acc), do: finish(%{acc | content: Enum.join(lines, "\n")})

  defp finish(acc), do: %{acc | decorators: Enum.reverse(acc.decorators), unknown: Enum.reverse(acc.unknown)}

  defp known?(line), do: String.starts_with?(unescape(line), @known)

  defp unescape("@@@" <> rest), do: "@@" <> rest
  defp unescape(line), do: line
end
