defmodule Mythweaver.FormatTest do
  use ExUnit.Case, async: true

  alias Mythweaver.Format

  describe "in German" do
    setup do
      {:ok, _} = Localize.put_locale(:de)
      :ok
    end

    test "groups and separates numbers the German way" do
      assert Format.number(1234.5) == "1.234,5"
    end

    test "formats money, percentages and sub-cent amounts" do
      money = Format.money(Decimal.new("1.5"))
      assert money =~ "1,50"
      assert money =~ "$"

      percent = Format.percent(0.42)
      assert percent =~ "42"
      assert percent =~ "%"

      assert Format.money(0.001) == "<" <> Format.money(0.01)
    end
  end

  describe "in English" do
    test "durations and seconds stay short" do
      assert Format.duration_ms(125_000) == "2m 5s"
      assert Format.seconds(1234, fractional_digits: 1) == "1.2s"
    end

    test "nil money is a dash" do
      assert Format.money(nil) == "—"
    end
  end
end
