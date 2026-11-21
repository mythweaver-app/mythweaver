defmodule Mythweaver.Memory.TitleTest do
  use ExUnit.Case, async: true

  alias Mythweaver.Memory.Title

  @now ~U[2026-10-03 09:05:00Z]

  test "substitutes macros, then pads the first numbering token" do
    assert Title.format("[000] - {{title}}", %{title: "Title", sequence: 1}) == "[001] - Title"
    assert Title.format("{{title}} (00) #000", %{title: "T", sequence: 7}) == "T (07) #000"
    assert Title.format("{0} {{chat}}", %{chat: "C", sequence: 12}) == "{12} C"

    assert Title.format("{{scene}} {{user}} {{date}} {{time}} {{unknown}}", %{scene: "#1–#5", now: @now}) ==
             "#1–#5  2026-10-03 09:05 {{unknown}}"
  end

  test "a labeled bracket token takes the number, so consolidations carry their tier" do
    assert Title.format("[{{tier}} 000] - {{title}}", %{tier: "ARC", title: "Mei", sequence: 9}) == "[ARC 009] - Mei"
  end

  test "a bare zero run is a token, but only in the format and only as its own word" do
    assert Title.format("000 - {{title}}", %{title: "Beach", sequence: 52}) == "052 - Beach"
    assert Title.format("{{title}} 00", %{title: "Beach", sequence: 3}) == "Beach 03"
    # Zeros a macro brings in, or inside a word, are text.
    assert Title.format("{{title}} - {{date}}", %{title: "Year 2000", sequence: 4, now: @now}) ==
             "Year 2000 - 2026-10-03"

    assert Title.format("v100 {{title}}", %{title: "T", sequence: 5}) == "v100 T"
  end

  test "adds no number without a token, and removes control characters" do
    assert Title.format("{{title}}", %{title: "A\nB\u0085", sequence: 3}) == "AB"
  end
end
