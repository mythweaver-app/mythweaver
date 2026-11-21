defmodule Mythweaver.Search.Query do
  @moduledoc """
  Turns typed search text into a Postgres `tsquery` string for the `simple`
  configuration.

  Bare words are prefix-matched (`drag` finds `dragons`), so results follow
  each keystroke; `websearch_to_tsquery` has no prefix form, hence this parser.
  A `"quoted phrase"` matches its words adjacent and whole, a leading `-`
  excludes a word or phrase, and punctuation inside a token joins its words as
  a phrase (`sky-blue` → `'sky' <-> 'blue':*`). Lexemes keep only letters and
  digits, so the output needs no further quoting.
  """

  @max_terms 16
  @token ~r/(-?)"([^"]*)"|(-?)(\S+)/u
  @separator ~r/[^\p{L}\p{N}]+/u

  @doc """
  Returns `{:ok, tsquery}`, or `:empty` when the text has no positive term to
  match.

      iex> Mythweaver.Search.Query.to_tsquery(~s(Dragon "red scale" -ice))
      {:ok, "'dragon':* & ('red' <-> 'scale') & !('ice':*)"}
  """
  @spec to_tsquery(String.t() | nil) :: {:ok, String.t()} | :empty
  def to_tsquery(nil), do: :empty

  def to_tsquery(text) when is_binary(text) do
    terms =
      @token
      |> Regex.scan(text, capture: :all_but_first)
      |> Enum.flat_map(&term/1)
      |> Enum.take(@max_terms)

    {positive, negative} = Enum.split_with(terms, &match?({:pos, _}, &1))

    if positive == [] do
      :empty
    else
      {:ok, Enum.map_join(positive ++ negative, " & ", &render/1)}
    end
  end

  defp term([neg, phrase]), do: build(neg, phrase, false)
  defp term([_, _, neg, token]), do: build(neg, token, true)

  defp build(neg, text, prefix?) do
    text
    |> String.downcase()
    |> String.split(@separator, trim: true)
    |> case do
      [] -> []
      words -> [{if(neg == "-", do: :neg, else: :pos), expression(words, prefix?)}]
    end
  end

  defp expression([word], true), do: "'#{word}':*"

  defp expression(words, prefix?) do
    {init, [last]} = Enum.split(words, -1)
    lexemes = Enum.map(init, &"'#{&1}'") ++ ["'#{last}'" <> if(prefix?, do: ":*", else: "")]
    "(" <> Enum.join(lexemes, " <-> ") <> ")"
  end

  defp render({:pos, expr}), do: expr
  defp render({:neg, expr}), do: "!(#{expr})"
end
