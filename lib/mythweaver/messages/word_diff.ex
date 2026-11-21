defmodule Mythweaver.Messages.WordDiff do
  @moduledoc """
  Word-level diff between two texts: swipes in the swipe inspector, and a lore entry's stored and
  edited Content (`MythweaverWeb.CoreComponents.WordDiff` renders it).

  Whitespace runs are their own tokens, so joining every `:eq`/`:ins` chunk reproduces `new` exactly
  and every `:eq`/`:del` chunk reproduces `old`.

  Built on `List.myers_difference/2`.
  """

  @spec diff(String.t() | nil, String.t() | nil) :: [{:eq | :ins | :del, String.t()}]
  def diff(old, new) do
    old
    |> tokens()
    |> List.myers_difference(tokens(new))
    |> Enum.map(fn {op, chunk} -> {op, Enum.join(chunk)} end)
  end

  @doc "How alike two texts are, 0.0..1.0: the share of all characters in the diff's chunks that sit in `:eq` chunks. Two blank texts are 1.0."
  @spec similarity(String.t() | nil, String.t() | nil) :: float()
  def similarity(old, new) do
    {eq, total} =
      old
      |> diff(new)
      |> Enum.reduce({0, 0}, fn {op, chunk}, {eq, total} ->
        length = String.length(chunk)
        {if(op == :eq, do: eq + length, else: eq), total + length}
      end)

    if total == 0, do: 1.0, else: eq / total
  end

  @doc """
  Whether `similarity(old, new) >= threshold`. The diff is skipped when the texts' shared tokens,
  counted as a bag, already rule the threshold out: the diff's `:eq` chunks can hold no more than
  that, and most pairs of unrelated texts fail there. Unrelated texts are the diff's slowest case.
  """
  @spec similar?(String.t() | nil, String.t() | nil, float()) :: boolean()
  def similar?(old, new, threshold) do
    old_tokens = tokens(old)
    new_tokens = tokens(new)
    shared = shared_length(old_tokens, new_tokens)
    total = text_length(old_tokens) + text_length(new_tokens) - shared

    # `similarity/2` is eq / (old + new - eq), rising with eq, so `shared` (≥ eq) bounds it.
    cond do
      total == 0 -> true
      shared / total < threshold -> false
      true -> similarity(old, new) >= threshold
    end
  end

  defp shared_length(old_tokens, new_tokens) do
    new_counts = Enum.frequencies(new_tokens)

    old_tokens
    |> Enum.frequencies()
    |> Enum.reduce(0, fn {token, n}, acc -> acc + min(n, Map.get(new_counts, token, 0)) * String.length(token) end)
  end

  defp text_length(tokens), do: Enum.reduce(tokens, 0, &(String.length(&1) + &2))

  defp tokens(nil), do: []
  defp tokens(text), do: Regex.split(~r/(\s+)/, text, include_captures: true, trim: true)
end
