defmodule Mythweaver.Dice do
  @moduledoc """
  The one dice grammar, shared by the Liquid `roll` filter and Lua's `mw.roll`: `[count]d<sides>[±mod]`,
  case-insensitive `d`, with up to 999 dice (default 1), 1–9999 sides and a ±9999 modifier.
  """

  # A zero-sided die would crash `:rand.uniform/1`, so sides start at 1.
  @dice ~r/\A(\d{1,3})?[dD]([1-9]\d{0,3})([+-]\d{1,4})?\z/

  @spec parse(String.t()) ::
          {:ok, {count :: non_neg_integer(), sides :: pos_integer(), modifier :: integer()}} | :error
  def parse(dice) when is_binary(dice) do
    case Regex.run(@dice, dice) do
      [_, count, sides | modifier] ->
        count = if count == "", do: 1, else: String.to_integer(count)

        modifier =
          case modifier do
            [mod] -> String.to_integer(mod)
            [] -> 0
          end

        {:ok, {count, String.to_integer(sides), modifier}}

      nil ->
        :error
    end
  end

  def parse(_dice), do: :error

  @spec roll(String.t()) :: {:ok, integer()} | :error
  def roll(dice) do
    with {:ok, {count, sides, modifier}} <- parse(dice) do
      {:ok, Enum.reduce(1..count//1, modifier, fn _, acc -> acc + :rand.uniform(sides) end)}
    end
  end
end
