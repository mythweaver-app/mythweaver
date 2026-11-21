defmodule Mythweaver.Import.DecoratorsTest do
  use ExUnit.Case, async: true

  alias Mythweaver.Import.Decorators

  test "known decorators are kept and stripped from the content" do
    assert Decorators.parse("@@activate\nText") == %{decorators: ["@@activate"], unknown: [], content: "Text"}
    assert Decorators.parse("@@dont_activate\nText").decorators == ["@@dont_activate"]
  end

  test "an unknown decorator is reported and stripped" do
    assert Decorators.parse("@@foo\nText") == %{decorators: [], unknown: ["@@foo"], content: "Text"}
  end

  test "an escaped line alone is skipped and the content kept whole" do
    assert Decorators.parse("@@@literal") == %{decorators: [], unknown: [], content: "@@@literal"}
  end

  test "an escaped decorator after an unknown one is its fallback" do
    assert Decorators.parse("@@foo\n@@@activate\nText") ==
             %{decorators: ["@@activate"], unknown: ["@@foo"], content: "Text"}
  end

  test "content without a leading @@ has no decorators" do
    assert Decorators.parse("Text\n@@activate") == %{decorators: [], unknown: [], content: "Text\n@@activate"}
  end
end
