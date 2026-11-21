defmodule Mythweaver.Import.MacrosTest do
  use ExUnit.Case, async: true

  alias Mythweaver.Import.Macros
  alias Mythweaver.Templates
  alias Mythweaver.Templates.State

  # Every conversion must parse, or the importer's changesets would reject it.
  defp convert(text) do
    {liquid, names} = Macros.to_liquid(text)
    assert {:ok, _template} = Templates.parse(liquid)
    {liquid, names}
  end

  defp render(liquid, data \\ %{}) do
    {text, _state, []} =
      Templates.render(liquid, State.new(data, %{chat: %{}, global: %{}}, "c1"))

    text
  end

  test "nil is empty" do
    assert Macros.to_liquid(nil) == {"", []}
  end

  test "text without macros is unchanged" do
    assert convert("Plain <b>text</b> with a < sign.") == {"Plain <b>text</b> with a < sign.", []}
  end

  test "names become anchors" do
    assert convert("{{char}} greets {{user}}") ==
             {"{{ anchors.character.name }} greets {{ anchors.player.name }}", []}

    assert convert("{{ Char }}, {{charIfNotGroup}}, {{GROUP}}") ==
             {"{{ anchors.character.name }}, {{ anchors.character.name }}, {{ anchors.participants }}", []}

    assert convert("{{description}} / {{persona}}") ==
             {"{{ anchors.character.description }} / {{ anchors.player.description }}", []}
  end

  test "legacy tokens become anchors, case-insensitively" do
    assert convert("<USER> meets <BOT>, <char>, <CHARIFNOTGROUP> and <GROUP>") ==
             {"{{ anchors.player.name }} meets {{ anchors.character.name }}, " <>
                "{{ anchors.character.name }}, {{ anchors.character.name }} and " <>
                "{{ anchors.participants }}", []}
  end

  test "newline, noop, original and comments" do
    assert convert("a{{newline}}b{{noop}}{{original}}{{// a note }}c") == {"a\nbc", []}
  end

  test "trim removes itself and the newlines around it" do
    assert convert("a\r\n\n{{trim}}\n\nb") == {"ab", []}
    assert convert("a {{trim}} b") == {"a  b", []}
  end

  test "random and pick become split filters" do
    assert {~s({{ "a::b" | split: "::" | random }}), []} = convert("{{random::a::b}}")
    assert {~s({{ "a::b" | split: "::" | pick }}), []} = convert("{{pick::a::b}}")
    assert {~s({{ "a::b c::d" | split: "::" | random }}), []} = convert("{{random: a, b c ,d}}")
    assert {~s({{ "x,y::z" | split: "::" | random }}), []} = convert("{{random:x\\,y,z}}")
  end

  test "the separator avoids the items and the quote avoids the text" do
    assert {~s({{ "a::b,c" | split: "::" | random }}), []} = convert("{{random:a::b,c}}")
    assert {~s({{ "a:|:b" | split: "|" | random }}), []} = convert("{{random:a:,:b}}")

    assert {~s({{ 'say "hi"::bye' | split: "::" | random }}), []} =
             convert(~s({{random::say "hi"::bye}}))

    assert {~s({% raw %}{{random::"a"::'b'}}{% endraw %}), ["random"]} =
             convert(~s({{random::"a"::'b'}}))
  end

  test "the converted random renders one of the items" do
    {liquid, []} = convert("{{random::a::b}}")
    assert render(liquid) in ["a", "b"]
  end

  test "roll accepts dice and bare sides" do
    assert convert("{{roll:d6}}") == {~s({{ "d6" | roll }}), []}
    assert convert("{{roll:20}}") == {~s({{ "d20" | roll }}), []}
    assert convert("{{roll 2D6+1}}") == {~s({{ "2D6+1" | roll }}), []}
    assert convert("{{roll:x}}") == {"{% raw %}{{roll:x}}{% endraw %}", ["roll"]}
  end

  test "getvar and getglobalvar read variables" do
    assert convert("{{getvar::mood}} {{getglobalvar::day}}") ==
             {"{{ vars.mood }} {{ globals.day }}", []}

    assert convert("{{getvar::bad key}}") ==
             {"{% raw %}{{getvar::bad key}}{% endraw %}", ["getvar"]}
  end

  test "setvar and setglobalvar write variables" do
    assert convert("{{setvar::mood::calm}}{{setglobalvar::day::1::2}}") ==
             {~s({% setvar mood = "calm" %}{% setglobalvar day = "1::2" %}), []}

    assert convert(~s({{setvar::q::say "hi"}})) == {~s({% setvar q = 'say "hi"' %}), []}

    {liquid, []} = convert("{{setvar::mood::calm}}{{getvar::mood}}")
    assert render(liquid) == "calm"
  end

  test "unknown macros stay literal and are reported once" do
    assert convert("{{time}} {%") ==
             {"{% raw %}{{time}}{% endraw %} {% raw %}{%{% endraw %}", ["time"]}

    assert {_liquid, ["addvar", "personality"]} =
             convert("{{addvar::x::1}}{{personality}}{{addVar::y::2}}")

    {liquid, ["time"]} = convert("At {{time}}, {{char}} waits.")

    assert render(liquid, %{"anchors" => %{"character" => %{"name" => "Ann"}}}) ==
             "At {{time}}, Ann waits."
  end

  test "nested macros stay literal" do
    assert {liquid, ["random"]} = convert("{{random::{{user}}::b}}")
    assert render(liquid) == "{{random::{{user}}::b}}"
  end

  test "an unclosed {{, a stray {% and a brace before a macro stay literal" do
    {liquid, []} = convert("{{{char}}} then {{ and {% end")

    assert render(liquid, %{"anchors" => %{"character" => %{"name" => "Ann"}}}) ==
             "{Ann} then {{ and {% end"
  end

  test "an endraw inside an unknown macro can't close its raw block" do
    {liquid, ["time"]} = convert("{{time {% endraw %}}}")
    assert render(liquid) == "{{time {% endraw %}}}"
  end

  test "text that still can't parse is wrapped whole" do
    assert {liquid, ["unparseable template"]} = convert("{<USER>")
    assert liquid == "{% raw %}{<USER>{% endraw %}"
    assert render(liquid) == "{<USER>"
  end
end
