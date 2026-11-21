defmodule Mythweaver.Lore.LoreEntryTest do
  use Mythweaver.DataCase, async: true

  alias Mythweaver.Lore.LoreEntry

  defp changeset(keywords), do: LoreEntry.changeset(%LoreEntry{}, %{name: "E", content: "x", keywords: keywords})

  describe "regex keyword validation" do
    test "a regex-shaped key whose source doesn't compile is refused" do
      assert %{keywords: ["is not a valid regex: /(dragon/i"]} = errors_on(changeset(["/(dragon/i"]))
    end

    test "JavaScript's g flag is accepted" do
      assert changeset(["/dragon/gi"]).valid?
    end
  end
end
