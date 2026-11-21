defmodule Mythweaver.Assistant.Tools.PreviewTest do
  use ExUnit.Case, async: true

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Assistant.Tools.Preview
  alias Mythweaver.Schema

  describe "change/3" do
    test "names each changed field with its new value and only a map's key names" do
      id = Schema.generate_id()
      label = fn _scope, ^id -> "Main" end

      line =
        Preview.change(label, %Scope{}, %{
          "id" => id,
          "base_url" => "https://new.example/v1",
          "extra_headers" => %{"Authorization" => "x"}
        })

      assert line == ~s|Main: base url "https://new.example/v1", extra headers (Authorization)|
      refute line =~ ~s|"x"|
    end

    test "flattens and cuts long text, counts lists" do
      id = Schema.generate_id()
      label = fn _scope, _id -> "Castle" end
      long = String.duplicate("a", 70)

      assert Preview.change(label, %Scope{}, %{"id" => id, "content" => " one\ntwo ", "keywords" => [1, 2]}) ==
               ~s|Castle: content "one two", keywords (2 items)|

      assert Preview.change(label, %Scope{}, %{"id" => id, "content" => long}) ==
               ~s|Castle: content "#{String.duplicate("a", 60)}…"|
    end
  end
end
