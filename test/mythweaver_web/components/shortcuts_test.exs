defmodule MythweaverWeb.ShortcutsTest do
  use ExUnit.Case, async: true

  alias MythweaverWeb.Shortcuts

  test "Mod-K searches everywhere; Mod-F searches the page outside editors, only where it has a scope" do
    bindings = Shortcuts.client_bindings()

    assert %{keys: ["Mod", "K"], action: "search_global", typing: "always"} =
             Enum.find(bindings, &(&1.id == "search_global"))

    assert %{keys: ["Mod", "F"], action: "search_local", typing: "outside_editor", when: "#search[data-local]"} =
             Enum.find(bindings, &(&1.id == "search_local"))
  end
end
