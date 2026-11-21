defmodule Mythweaver.Export.MacrosTest do
  use ExUnit.Case, async: true

  alias Mythweaver.Export.Macros
  alias Mythweaver.Import.Macros, as: ImportMacros

  defp round_trip(st), do: Macros.to_st(elem(ImportMacros.to_liquid(st), 0))

  describe "to_st/1" do
    test "inverts each macro Import.Macros converts" do
      for st <- [
            "{{char}}",
            "{{user}}",
            "{{group}}",
            "{{description}}",
            "{{persona}}",
            "{{getvar::mood}}",
            "{{getglobalvar::weather}}",
            "{{setvar::mood::happy}}",
            "{{setglobalvar::weather::rain and wind}}",
            ~s({{setvar::line::she said "hi"}}),
            "{{roll:d20}}",
            "{{roll:2d6+1}}",
            "{{random::a::b::c}}",
            "{{pick::red::green}}"
          ] do
        assert round_trip(st) == {st, false}, st
      end
    end

    test "writes comma lists in their :: form" do
      assert round_trip("{{random:a, b,c}}") == {"{{random::a::b::c}}", false}
      assert round_trip("{{pick:x,y}}") == {"{{pick::x::y}}", false}
      assert round_trip("{{random:a::b|c}}") == {"{{random::a::b|c}}", false}
    end

    test "keeps surrounding text and mixed macros" do
      st = "Hi {{user}}, I'm {{char}}. {{foo}} {{roll:d6}} <b>bold</b>"
      assert round_trip(st) == {st, false}
    end

    test "round-trips an unknown macro through raw" do
      assert {liquid, ["foo"]} = ImportMacros.to_liquid("{{foo}}")
      assert liquid =~ "{% raw %}"
      assert Macros.to_st(liquid) == {"{{foo}}", false}
    end

    test "round-trips a literal endraw split across raw blocks" do
      for st <- ["a {% endraw %} b", "{{foo {% endraw %}}}", "{% raw %}x{% endraw %}"] do
        assert round_trip(st) == {st, false}, st
      end
    end

    test "reports Liquid SillyTavern can't run" do
      assert Macros.to_st("{% if x %}yes{% endif %}") == {"{% if x %}yes{% endif %}", true}
      assert Macros.to_st("{{ anchors.lore.before }}") == {"{{ anchors.lore.before }}", true}
      assert Macros.to_st("{{ vars.mood | upcase }}") == {"{{ vars.mood | upcase }}", true}
    end

    test "accepts whitespace variations and single quotes" do
      assert Macros.to_st("{{anchors.character.name}}") == {"{{char}}", false}
      assert Macros.to_st("{%setvar k='v'%}") == {"{{setvar::k::v}}", false}
      assert Macros.to_st(~s({{ 'a,b' |split:',' |pick }})) == {"{{pick::a::b}}", false}
    end

    test "writes the char and user aliases as their macros, only as whole tags" do
      assert Macros.to_st("{{ char }} meets {{user}}") == {"{{char}} meets {{user}}", false}
      assert Macros.to_st("{{ characters }}") == {"{{ characters }}", true}
      assert Macros.to_st("{{ char.name }}") == {"{{ char.name }}", true}
      assert Macros.to_st("{{ username }}") == {"{{ username }}", true}
    end

    test "leaves values ST can't hold in one macro unconverted" do
      text = ~s({% setvar k = "a}}b" %})
      assert Macros.to_st(text) == {text, true}
    end

    test "nil is empty" do
      assert Macros.to_st(nil) == {"", false}
    end
  end

  test "warning/1 names the affected text" do
    assert Macros.warning(["Intro", "Scenario"]) ==
             "Some text uses Mythweaver templates SillyTavern can't run: Intro, Scenario."
  end
end
