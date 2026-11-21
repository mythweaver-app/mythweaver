defmodule MythweaverWeb.CommandPalette.Fuzzy do
  @moduledoc """
  Subsequence matching for the command palette. A query matches text when its graphemes appear in
  order (ignoring case and the query's whitespace). Each matched grapheme scores 1, plus 8 at the
  start of a word (the text's start or after `" :_-/."`) and 4 right after the previous match;
  every skipped grapheme between the first and last match costs 1. The best alignment wins, the
  earliest on a tie.
  """

  @separators [" ", ":", "_", "-", "/", "."]

  @doc "The best `{score, matched grapheme indices}` of `query` in `text`, or `nil`."
  @spec match(String.t(), String.t()) :: {integer(), [non_neg_integer()]} | nil
  def match(query, text) do
    query
    |> String.downcase()
    |> String.replace(~r/\s+/u, "")
    |> String.graphemes()
    |> case do
      [] ->
        {0, []}

      [first | _] = query ->
        text = text |> String.graphemes() |> Enum.map(&String.downcase/1) |> List.to_tuple()

        candidates =
          for start <- 0..(tuple_size(text) - 1)//1,
              elem(text, start) == first,
              indices = align(query, text, start, []),
              indices != nil,
              do: {score(indices, text), indices}

        # `max_by` keeps the first of equal scores: the earliest alignment.
        Enum.max_by(candidates, &elem(&1, 0), fn -> nil end)
    end
  end

  # Greedy forward match from `start`; the indices in order, or nil when the query runs out of text.
  defp align([], _text, _from, acc), do: Enum.reverse(acc)

  defp align([g | rest], text, from, acc) do
    case Enum.find(from..(tuple_size(text) - 1)//1, &(elem(text, &1) == g)) do
      nil -> nil
      i -> align(rest, text, i + 1, [i | acc])
    end
  end

  defp score(indices, text) do
    {points, _previous} =
      Enum.reduce(indices, {0, nil}, fn i, {points, previous} ->
        boundary = if i == 0 or elem(text, i - 1) in @separators, do: 8, else: 0
        adjacent = if previous != nil and i == previous + 1, do: 4, else: 0
        {points + 1 + boundary + adjacent, i}
      end)

    points - (List.last(indices) - hd(indices) + 1 - length(indices))
  end

  @doc "`text` cut into runs of matched (`true`) and unmatched graphemes, for highlighting."
  @spec segments(String.t(), [non_neg_integer()]) :: [{String.t(), boolean()}]
  def segments(text, indices) do
    matched = MapSet.new(indices)

    text
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.chunk_by(fn {_g, i} -> MapSet.member?(matched, i) end)
    |> Enum.map(fn [{_g, i} | _] = run -> {Enum.map_join(run, &elem(&1, 0)), MapSet.member?(matched, i)} end)
  end
end
