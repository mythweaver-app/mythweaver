defmodule MythweaverWeb.ClientStringsTest do
  use ExUnit.Case, async: true

  alias MythweaverWeb.ClientStrings

  test "a plural carries one template per category of the UI language, each with its placeholder" do
    Gettext.put_locale(Mythweaver.Gettext, "pl")
    forms = ClientStrings.catalog()["chart_tokens"]

    assert forms |> Map.keys() |> Enum.sort() == ~w(few many one other)
    assert Enum.all?(Map.values(forms), &(&1 =~ "%{token_count}"))
  end

  test "plural categories follow the language, not the regional format" do
    Gettext.put_locale(Mythweaver.Gettext, "en")
    {:ok, _} = Localize.put_locale(:pl)

    assert ClientStrings.catalog()["chart_tokens"] == %{
             "one" => "%{token_count} token",
             "other" => "%{token_count} tokens"
           }
  end
end
