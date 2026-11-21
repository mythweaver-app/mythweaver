defmodule MythweaverWeb.PermissionGridTest do
  use ExUnit.Case, async: true

  alias MythweaverWeb.PermissionGrid

  defp spend(raw),
    do:
      PermissionGrid.to_grants(%{
        "grants" => %{"quota.spend_per_day" => "set"},
        "limits" => %{"quota.spend_per_day" => raw}
      })["quota.spend_per_day"]

  test "a spending limit is entered in dollars and stored in cents" do
    assert spend("2.50") == "250"
    assert spend(" 3 ") == "300"
    assert spend("0.004") == "0"
    assert spend("0.005") == "1"
  end

  test "a negative, blank or non-numeric spending limit is invalid" do
    for raw <- ["-1", "", "abc", "1.5x", "inf", "NaN"], do: assert(spend(raw) == "invalid", raw)
  end
end
