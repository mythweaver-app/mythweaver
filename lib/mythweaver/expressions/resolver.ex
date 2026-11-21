defmodule Mythweaver.Expressions.Resolver do
  @moduledoc """
  Turns a classifier's percent scores into one expression label, and picks a sprite for it. Pure.

  A port of expressions-plus `selectExpression` (`src/classification.js`) on a 0..100 scale:

    * The simple candidate is the best-scoring classifier label that has a sprite (SillyTavern's
      "filter available"), when its score is above zero.
    * Each enabled rule whose name has a sprite is a candidate when it matches: a `:range` rule
      scores the mean of its conditions' scores, a `:combination` rule `sum / ((n + 1) / 2)`, which
      rewards blends over any one of their parts.
    * The highest score wins; ties go to a rule over the simple candidate, then to more conditions,
      then to the earlier rule.
    * Nothing matching falls back to `fallback` when it has a sprite, else nil (the portrait).
  """

  alias Mythweaver.Expressions.Rule
  alias Mythweaver.Expressions.Sprite

  @type config :: %{
          labels: [String.t()],
          rules: [Rule.t()],
          available: MapSet.t(String.t()),
          fallback: String.t() | nil
        }

  @spec resolve(%{String.t() => number()}, config()) :: String.t() | nil
  def resolve(scores, %{labels: labels, rules: rules, available: available, fallback: fallback}) do
    candidates =
      List.wrap(simple_candidate(scores, labels, available)) ++
        (rules
         |> Enum.with_index()
         |> Enum.flat_map(fn {rule, index} -> List.wrap(rule_candidate(rule, index, scores, available)) end))

    case candidates do
      [] ->
        if fallback && MapSet.member?(available, fallback), do: fallback

      _ ->
        candidates
        |> Enum.min_by(fn %{score: score, rule?: rule?, conditions: n, index: index} ->
          {-score, if(rule?, do: 0, else: 1), -n, index}
        end)
        |> Map.fetch!(:label)
    end
  end

  defp simple_candidate(scores, labels, available) do
    labels
    |> Enum.filter(&MapSet.member?(available, &1))
    # max_by keeps the first of equal maxima: ties go to the earlier label.
    |> Enum.max_by(&score(scores, &1), fn -> nil end)
    |> case do
      nil ->
        nil

      label ->
        s = score(scores, label)
        if s > 0, do: %{label: label, score: s, rule?: false, conditions: 1, index: -1}
    end
  end

  defp rule_candidate(%Rule{enabled: false}, _index, _scores, _available), do: nil

  defp rule_candidate(%Rule{name: name, conditions: [_ | _] = conditions} = rule, index, scores, available) do
    if MapSet.member?(available, name) do
      ss = Enum.map(conditions, &score(scores, &1.label))

      with score when is_number(score) <- rule_score(rule, conditions, ss),
           do: %{label: name, score: score, rule?: true, conditions: length(conditions), index: index}
    end
  end

  defp rule_candidate(%Rule{}, _index, _scores, _available), do: nil

  defp rule_score(%Rule{kind: :range}, conditions, ss) do
    in_range? =
      conditions
      |> Enum.zip(ss)
      |> Enum.all?(fn {c, s} -> (is_nil(c.min) or s >= c.min) and (is_nil(c.max) or s <= c.max) end)

    if in_range?, do: Enum.sum(ss) / length(ss)
  end

  defp rule_score(%Rule{kind: :combination, max_difference: max_difference}, _conditions, ss) do
    h = Enum.max(ss)
    allowed = 100 - (max_difference || 0)

    if h > 0 and Enum.all?(ss, &(&1 > 0 and &1 * 100 >= h * allowed)),
      do: Enum.sum(ss) / ((length(ss) + 1) / 2)
  end

  defp score(scores, label) do
    case Map.get(scores, label) do
      n when is_number(n) -> n
      _ -> 0
    end
  end

  @doc """
  A random sprite of `sprites`, or nil for none. With `reroll?` and a choice to make, the sprite the
  previous message showed (`previous_sprite_id`) is left out, so the image visibly changes.
  """
  @spec pick_sprite([Sprite.t()], Ecto.UUID.t() | nil, boolean()) :: Sprite.t() | nil
  def pick_sprite([], _previous_sprite_id, _reroll?), do: nil

  def pick_sprite(sprites, previous_sprite_id, reroll?) do
    pool =
      if reroll? and match?([_, _ | _], sprites) and Enum.any?(sprites, &(&1.id == previous_sprite_id)),
        do: Enum.reject(sprites, &(&1.id == previous_sprite_id)),
        else: sprites

    Enum.random(pool)
  end
end
