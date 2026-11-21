defmodule MythweaverWeb.Bulk.SelectionTest do
  use ExUnit.Case, async: true

  alias MythweaverWeb.Bulk.Selection

  test "toggle adds a listed id, removes a selected one, and ignores an unlisted one" do
    assert Selection.toggle(MapSet.new(), "a", ["a", "b"]) == MapSet.new(["a"])
    assert Selection.toggle(MapSet.new(["a"]), "a", ["a"]) == MapSet.new()
    assert Selection.toggle(MapSet.new(["a"]), "z", ["a"]) == MapSet.new(["a"])
  end

  test "add_range drops unlisted ids" do
    assert Selection.add_range(MapSet.new(["a"]), ["b", "z"], ["a", "b"]) == MapSet.new(["a", "b"])
  end

  test "toggle_all selects every listed id, then clears, and leaves an empty list alone" do
    hidden = MapSet.new(["h"])
    assert Selection.toggle_all(hidden, ["a", "b"]) == MapSet.new(["a", "b", "h"])
    assert Selection.toggle_all(MapSet.new(["a", "b"]), ["a", "b"]) == MapSet.new()
    assert Selection.toggle_all(hidden, []) == hidden
  end
end
