defmodule Mythweaver.Expressions.ResolverTest do
  use ExUnit.Case, async: true

  alias Mythweaver.Expressions
  alias Mythweaver.Expressions.Condition
  alias Mythweaver.Expressions.Resolver
  alias Mythweaver.Expressions.Rule
  alias Mythweaver.Expressions.Sprite

  defp config(available, rules \\ [], fallback \\ "neutral") do
    %{labels: Expressions.base_labels(), rules: rules, available: MapSet.new(available), fallback: fallback}
  end

  defp combination(name, labels, max_difference \\ 25),
    do: %Rule{
      name: name,
      kind: :combination,
      max_difference: max_difference,
      conditions: Enum.map(labels, &%Condition{label: &1})
    }

  test "the best-scoring available label wins" do
    assert Resolver.resolve(%{"joy" => 80, "anger" => 10}, config(~w(joy anger))) == "joy"
  end

  test "a label without a sprite is passed over for the best one that has one" do
    assert Resolver.resolve(%{"anger" => 90, "joy" => 30}, config(~w(joy))) == "joy"
  end

  test "a combination wins when its emotions score close together, and not when they don't" do
    elated = combination("elated", ~w(excitement joy))
    available = ~w(elated excitement joy)

    # 2 * 110 / 3 ≈ 73 beats excitement's 60.
    assert Resolver.resolve(%{"excitement" => 60, "joy" => 50}, config(available, [elated])) == "elated"
    # 40 < 60 * 0.75: no blend.
    assert Resolver.resolve(%{"excitement" => 60, "joy" => 40}, config(available, [elated])) == "excitement"
  end

  test "a combination whose name has no sprite never wins" do
    elated = combination("elated", ~w(excitement joy))
    assert Resolver.resolve(%{"excitement" => 60, "joy" => 50}, config(~w(excitement joy), [elated])) == "excitement"
  end

  test "a disabled rule never wins" do
    elated = %{combination("elated", ~w(excitement joy)) | enabled: false}
    assert Resolver.resolve(%{"excitement" => 60, "joy" => 50}, config(~w(elated excitement), [elated])) == "excitement"
  end

  test "a range rule matches inside its bounds and beats a simple candidate" do
    smirk = %Rule{name: "smirk", kind: :range, conditions: [%Condition{label: "amusement", min: 5, max: 10}]}
    available = ~w(smirk amusement neutral)

    assert Resolver.resolve(%{"amusement" => 7, "neutral" => 3}, config(available, [smirk])) == "smirk"
    assert Resolver.resolve(%{"amusement" => 12, "neutral" => 3}, config(available, [smirk])) == "amusement"
  end

  test "all zero falls back to the fallback when it has a sprite, else nil" do
    assert Resolver.resolve(%{}, config(~w(neutral joy))) == "neutral"
    assert Resolver.resolve(%{"joy" => 0}, config(~w(joy))) == nil
  end

  describe "pick_sprite/3" do
    test "with reroll, never repeats the previous sprite when another exists" do
      a = %Sprite{id: "a"}
      b = %Sprite{id: "b"}

      for _ <- 1..20, do: assert(Resolver.pick_sprite([a, b], "a", true) == b)
      assert Resolver.pick_sprite([a], "a", true) == a
    end

    test "without reroll, either may come back" do
      a = %Sprite{id: "a"}
      b = %Sprite{id: "b"}
      picks = for _ <- 1..60, into: MapSet.new(), do: Resolver.pick_sprite([a, b], "a", false).id

      assert picks == MapSet.new(["a", "b"])
    end

    test "nothing to pick from is nil" do
      assert Resolver.pick_sprite([], nil, true) == nil
    end
  end
end
