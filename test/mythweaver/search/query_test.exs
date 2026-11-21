defmodule Mythweaver.Search.QueryTest do
  use ExUnit.Case, async: true

  alias Mythweaver.Search.Query

  doctest Query

  test "prefixes bare words, keeps phrases whole and negates after the positives" do
    assert Query.to_tsquery(~s(Dragon "red scale" -ice)) ==
             {:ok, "'dragon':* & ('red' <-> 'scale') & !('ice':*)"}
  end

  test "text with no positive term is empty" do
    assert Query.to_tsquery("-ice") == :empty
    assert Query.to_tsquery("  ") == :empty
    assert Query.to_tsquery(~s(-"" ...)) == :empty
    assert Query.to_tsquery(nil) == :empty
  end

  test "punctuation inside a token joins its words as a prefixed phrase" do
    assert Query.to_tsquery("sky-blue") == {:ok, "('sky' <-> 'blue':*)"}
  end

  test "an unterminated quote is a bare token" do
    assert Query.to_tsquery(~s("dragon)) == {:ok, "'dragon':*"}
  end

  test "keeps non-ASCII letters, lowercased" do
    assert Query.to_tsquery("Ünïcode") == {:ok, "'ünïcode':*"}
  end

  test "keeps only the first 16 terms" do
    {:ok, tsq} = 1..20 |> Enum.map_join(" ", &"w#{&1}") |> Query.to_tsquery()
    assert tsq |> String.split(" & ") |> length() == 16
    refute tsq =~ "w17"
  end
end
