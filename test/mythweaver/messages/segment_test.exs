defmodule Mythweaver.Messages.SegmentTest do
  use ExUnit.Case, async: true

  alias Mythweaver.Messages.Segment

  test "blank and whitespace-only lines separate paragraphs and are dropped" do
    assert Segment.paragraphs("a\n\n\n  \n\nb") == ["a", "b"]
  end

  test "blank lines inside a fence are content" do
    assert Segment.paragraphs("```\nx\n\ny\n```\n\nz") == ["```\nx\n\ny\n```", "z"]
  end

  test "only the opening fence character closes a fence" do
    text = "~~~\na\n```\n\nb\n~~~\n\nc"
    assert Segment.paragraphs(text) == ["~~~\na\n```\n\nb\n~~~", "c"]
  end

  test "a single paragraph stays whole" do
    assert Segment.paragraphs("one\ntwo") == ["one\ntwo"]
  end
end
