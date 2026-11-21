defmodule Mythweaver.Scripts.InlineTest do
  use ExUnit.Case, async: true

  alias Mythweaver.Scripts.Inline

  test "text without {! has no blocks" do
    assert Inline.prepare("plain {{ x }}") == :none
  end

  test "blocks become markers in source order" do
    assert {:ok, %{template: template, scripts: [" return 1 ", " return 2 "]}} =
             Inline.prepare("A {! return 1 !} B {! return 2 !}")

    assert Inline.present(template, 2) == [1, 2]
    assert Inline.fill(template, %{1 => "x", 2 => "y"}) == "A x B y"
  end

  test "the first !} closes a block, and an empty body is allowed" do
    assert {:ok, %{template: template, scripts: ["", " return 1 "]}} = Inline.prepare("{!!}!}{! return 1 !}")
    assert Inline.fill(template, %{1 => "", 2 => "1"}) == "!}1"
  end

  test "an unclosed block is an error naming it" do
    assert Inline.prepare("{! return 1 !} A {! return 1") == {:error, "inline script 2 has no closing !}"}
  end

  test "a syntax error names its block" do
    assert {:error, "inline script 2: " <> _} = Inline.prepare("{! return 1 !}{! return ( !}")
  end

  test "the reserved marker characters are refused" do
    assert Inline.prepare("\u{E010} {! return 1 !}") ==
             {:error, "the message contains the reserved character U+E010"}

    assert Inline.prepare("\u{E011} {! return 1 !}") ==
             {:error, "the message contains the reserved character U+E011"}
  end

  test "a message holds at most 10 blocks" do
    assert {:ok, %{scripts: scripts}} = Inline.prepare(String.duplicate("{! return 1 !}", 10))
    assert length(scripts) == 10

    assert Inline.prepare(String.duplicate("{! return 1 !}", 11)) ==
             {:error, "a message may hold at most 10 inline scripts"}
  end

  test "Lua containing Liquid delimiters is kept verbatim" do
    assert {:ok, %{template: template, scripts: [" local t = {{1}} return #t "]}} =
             Inline.prepare("{! local t = {{1}} return #t !}")

    refute template =~ "{{"
  end

  test "present/2 drops a marker rendering removed, even between neighbours that spell it" do
    {:ok, %{template: template}} = Inline.prepare("{! return 1 !}2{! return 2 !}{! return 3 !}")
    # Block 2 removed, leaving block 1's marker, the digit 2 and block 3's marker side by side.
    [first, rest] = String.split(template, "2", parts: 2)
    [_second, third] = String.split(rest, "\u{E011}", parts: 2)
    rendered = first <> "2" <> third

    assert Inline.present(rendered, 3) == [1, 3]
  end

  test "fill/2 fills every copy of a repeated marker" do
    {:ok, %{template: template}} = Inline.prepare("{! return 1 !}")
    assert Inline.fill(template <> "-" <> template, %{1 => "v"}) == "v-v"
  end
end
