defmodule Mythweaver.Templates.Filters do
  @moduledoc """
  Mythweaver's Liquid filters on top of Solid's standard set: `random`, `pick`, `roll`, `push`,
  `to_sentence`.

  Passed to Solid as a function, so an unknown name returns `:error` and Solid falls back to its
  standard filters.
  """

  @spec apply(String.t(), list(), term(), String.t()) :: {:ok, term()} | :error
  def apply("random", [[]], _seed, _source), do: {:ok, nil}
  def apply("random", [list], _seed, _source) when is_list(list), do: {:ok, Enum.random(list)}

  # Stable per chat, template text and occurrence, so a regenerated reply sees the same pick. The
  # process dictionary is safe: every render owns a fresh task process.
  def apply("pick", [list], seed, source) when is_list(list) do
    n = Process.get(:templates_pick, 0)
    Process.put(:templates_pick, n + 1)

    case list do
      [] -> {:ok, nil}
      list -> {:ok, Enum.at(list, :erlang.phash2({seed, source, n}, length(list)))}
    end
  end

  def apply("roll", [dice], _seed, _source) when is_binary(dice) do
    case Mythweaver.Dice.roll(dice) do
      {:ok, total} -> {:ok, total}
      :error -> invalid_dice(dice)
    end
  end

  def apply("roll", [dice], _seed, _source), do: invalid_dice(inspect(dice))

  def apply("push", [nil, value], _seed, _source), do: {:ok, [value]}
  def apply("push", [list, value], _seed, _source) when is_list(list), do: {:ok, list ++ [value]}

  # Serial comma: two items read "a and b", since "a, and b" is not English.
  def apply("to_sentence", [nil], _seed, _source), do: {:ok, ""}

  def apply("to_sentence", [list], _seed, _source) when is_list(list) do
    sentence =
      case Enum.map(list, &text/1) do
        [] -> ""
        [one] -> one
        [a, b] -> "#{a} and #{b}"
        items -> Enum.join(Enum.drop(items, -1), ", ") <> ", and " <> List.last(items)
      end

    {:ok, sentence}
  end

  def apply("to_sentence", [other], _seed, _source) do
    raise Solid.ArgumentError, message: "to_sentence expects an array, got #{inspect(other)}"
  end

  def apply(_name, _args, _seed, _source), do: :error

  # Solid's filter dispatch rescues this and records it, with the filter's location, as a render
  # error; a plain `:error` would fall through to the standard filters and vanish silently.
  defp invalid_dice(dice) do
    raise Solid.ArgumentError, message: "roll expects dice like \"2d6+1\" or \"d6\", got #{dice}"
  end

  defp text(nil), do: ""
  defp text(value) when is_binary(value), do: value
  defp text(value) when is_number(value) or is_boolean(value) or is_atom(value), do: to_string(value)
  defp text(value), do: inspect(value)
end
