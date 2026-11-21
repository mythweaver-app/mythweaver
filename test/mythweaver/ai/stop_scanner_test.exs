defmodule Mythweaver.AI.StopScannerTest do
  use ExUnit.Case, async: true

  alias Mythweaver.AI.StopScanner

  # Feeds `tokens` one at a time; returns everything emitted and whether a stop string ended it.
  defp run(strings, tokens) do
    Enum.reduce_while(tokens, {"", StopScanner.new(strings)}, fn token, {out, scanner} ->
      case StopScanner.feed(scanner, token) do
        {:cont, text, scanner} -> {:cont, {out <> text, scanner}}
        {:stop, text} -> {:halt, {:stopped, out <> text}}
      end
    end)
    |> case do
      {:stopped, out} -> {out, true}
      {out, scanner} -> {out <> StopScanner.finish(scanner), false}
    end
  end

  test "a stop string split across tokens ends the reply before it" do
    assert run(["\nBob:"], ["Hi", " there.\n", "Bo", "b: no"]) == {"Hi there.", true}
  end

  test "holds a possible stop string back until it resolves" do
    scanner = StopScanner.new(["\nBob:"])
    assert {:cont, "Hi.", scanner} = StopScanner.feed(scanner, "Hi.\nBo")
    assert {:cont, "\nBoat", _scanner} = StopScanner.feed(scanner, "at")
  end

  test "the earliest of several stop strings wins" do
    assert run(["###", "\nBob:"], ["a\nBob: b ### c"]) == {"a", true}
  end

  test "a newline-led stop string matches at the start of the reply, a bare newline does not" do
    assert run(["\nBob:"], ["Bo", "b: hi"]) == {"", true}
    assert run(["\n"], ["\nHello", " there\nmore"]) == {"\nHello there", true}
  end

  test "the start-of-reply match ends once text is emitted" do
    assert run(["\nBob:"], ["Hi ", "Bob: x"]) == {"Hi Bob: x", false}
  end

  test "no stop strings passes text through" do
    assert run([], ["a\n", "b"]) == {"a\nb", false}
  end

  test "keeps multibyte text whole around a held tail" do
    assert run(["\nÉlodie:"], ["Café ☕\nÉl", "an"]) == {"Café ☕\nÉlan", false}
    assert run(["\nÉlodie:"], ["Café ☕\nÉl", "odie: x"]) == {"Café ☕", true}
  end

  test "cut/2 trims a whole reply" do
    assert StopScanner.cut("one\nBob: two", ["\nBob:"]) == {"one", true}
    assert StopScanner.cut("one two", ["\nBob:"]) == {"one two", false}
  end
end
