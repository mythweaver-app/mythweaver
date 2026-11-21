defmodule Mythweaver.Generation.Overlap do
  @moduledoc """
  Drops the part of a continue that only repeats the continued message's ending.

  Asked to continue, models often restart the last sentence or paragraph instead of extending it:
  "…noting its" continued as "Katy looked at the car approvingly, noting its stylish lines" repeats
  the line it was given. When the generated text starts with the message's own ending (from a word
  start through its last character, trailing whitespace aside, at least `@min_bytes` long and two
  words or more), that repeated ending is removed, so only the new part is appended. Shorter or
  inexact matches are kept: a legitimate continuation can start with a word the message ended on.

  Streaming: while everything generated so far could still be the start of such a repeat, nothing is
  shown, so a repeat never flashes up and then disappears. When the reply ends inside a repeat of at
  least `@min_bytes`, the repeat is dropped; a shorter one is kept.
  """

  @min_bytes 16
  # How far back from the end a repeat may start, in bytes: a long last paragraph and then some.
  @window 4_000

  @doc """
  The part of `new` (a continue's generated text) to append to `prefix` (the continued text):
  `new` itself, `new` without a repeat of `prefix`'s ending, or `""` while `new` may still turn out
  to be one. `done?` is true once the reply is complete.
  """
  @spec trim(String.t(), String.t(), boolean()) :: String.t()
  def trim(prefix, new, done?) do
    lead = String.trim_leading(new)
    tails = tails(String.trim_trailing(prefix))

    case Enum.find(tails, &String.starts_with?(lead, &1)) do
      nil ->
        cond do
          lead == "" -> new
          not Enum.any?(tails, &String.starts_with?(&1, lead)) -> new
          not done? -> ""
          long_enough?(lead) -> ""
          true -> new
        end

      tail ->
        rest = binary_part(lead, byte_size(tail), byte_size(lead) - byte_size(tail))
        # The message already ends in whitespace, so the repeat's own leading whitespace would double it.
        if prefix =~ ~r/\s\z/u, do: String.trim_leading(rest), else: rest
    end
  end

  # Every ending of `base` that starts at a word, longest first, long enough to count as a repeat.
  defp tails(base) do
    start = max(byte_size(base) - @window, 0)
    window = binary_part(base, start, byte_size(base) - start)

    ~r/(?:\A|\s)\K\S/u
    |> Regex.scan(window, return: :index)
    |> Enum.map(fn [{offset, _length}] -> binary_part(window, offset, byte_size(window) - offset) end)
    # A window cut mid-word would offer that word's tail as a word start.
    |> then(fn tails -> if start > 0, do: Enum.drop(tails, 1), else: tails end)
    |> Enum.filter(&long_enough?/1)
  end

  defp long_enough?(text), do: byte_size(text) >= @min_bytes and text =~ ~r/\S\s+\S/u
end
