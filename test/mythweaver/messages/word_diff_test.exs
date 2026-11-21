defmodule Mythweaver.Messages.WordDiffTest do
  use ExUnit.Case, async: true

  alias Mythweaver.Messages.WordDiff

  test "a replaced word is a delete then an insert between equal runs" do
    assert WordDiff.diff("The cat sat", "The dog sat") == [eq: "The ", del: "cat", ins: "dog", eq: " sat"]
  end

  test "an appended phrase is a trailing insert" do
    diff = WordDiff.diff("Hi", "Hi there")

    assert hd(diff) == {:eq, "Hi"}
    assert List.last(diff) == {:ins, " there"}
  end

  test "a nil source diffs as all-inserted" do
    assert WordDiff.diff(nil, "x") == [ins: "x"]
  end

  test "equal and inserted chunks rebuild the new text, equal and deleted chunks the old" do
    old = "First paragraph here.\n\nSecond  one, with   spacing."
    new = "First paragraph there.\n\nSecond one, with spacing.\n\nThird."
    diff = WordDiff.diff(old, new)

    assert rebuild(diff, :ins) == new
    assert rebuild(diff, :del) == old
  end

  test "similarity is the share of characters the diff leaves unchanged" do
    assert WordDiff.similarity("a b c d", "a b c d") == 1.0
    assert WordDiff.similarity(nil, "") == 1.0
    assert WordDiff.similarity("one", "two") == 0.0

    partial = WordDiff.similarity("the cat sat", "the dog sat")
    assert partial > 0 and partial < 1
  end

  test "similar? agrees with similarity at the threshold, short-circuited or not" do
    pairs = [
      {"the cat sat", "the dog sat"},
      {"a b c d", "d c b a"},
      {"The knight rode north at dawn.", "The knight rode south at dawn."},
      {"one", "two"},
      {nil, ""}
    ]

    for {old, new} <- pairs, threshold <- [0.5, 0.6, 0.7, 0.8, 0.9, 1.0] do
      assert WordDiff.similar?(old, new, threshold) == WordDiff.similarity(old, new) >= threshold
    end
  end

  defp rebuild(diff, side) do
    diff |> Enum.filter(fn {op, _} -> op in [:eq, side] end) |> Enum.map_join(&elem(&1, 1))
  end
end
