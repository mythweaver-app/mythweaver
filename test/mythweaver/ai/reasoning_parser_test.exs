defmodule Mythweaver.AI.ReasoningParserTest do
  use ExUnit.Case, async: true

  alias Mythweaver.AI.ReasoningParser

  @think {"<think>", "</think>"}

  # Feeds every chunk, then finishes, returning `{reasoning, content, events}`.
  defp run(chunks, tags \\ @think) do
    {events, parser} =
      Enum.reduce(chunks, {[], ReasoningParser.new(tags)}, fn chunk, {events, parser} ->
        {new, parser} = ReasoningParser.feed(parser, chunk)
        {events ++ new, parser}
      end)

    events = events ++ ReasoningParser.finish(parser)
    refute Enum.any?(events, fn {_type, text} -> text == "" end)

    {join(events, :reasoning), join(events, :delta), events}
  end

  defp join(events, type), do: for({^type, text} <- events, into: "", do: text)

  test "tags split across chunks" do
    assert {"Hmm", "Hi", _} = run(["<th", "ink>\nHm", "m</thi", "nk>\n\nHi"])
  end

  test "a reply without the prefix streams immediately" do
    parser = ReasoningParser.new(@think)
    assert {[{:delta, "Hello"}], _parser} = ReasoningParser.feed(parser, "Hello")
  end

  test "a partial prefix that diverges is content" do
    assert {"", "<b>bold", _} = run(["<b", ">bold"])
  end

  test "leading whitespace before the prefix is allowed" do
    assert {"x", "y", _} = run(["\n <think>x</think>y"])
  end

  test "an unterminated block is all reasoning" do
    assert {"still going", "", _} = run(["<think>still going"])
  end

  test "a reply of only a partial prefix is content" do
    assert {"", "<thi", _} = run(["<thi"])
  end

  test "only the first block counts" do
    assert {"a", "b</think>c", _} = run(["<think>a</think>b</think>c"])
  end

  test "the Gemma 4 channel pair" do
    tags = {"<|channel>thought", "<channel|>"}

    assert {"plan", "Hello", _} =
             run(["<|chan", "nel>thought\npl", "an<chan", "nel|>Hello"], tags)
  end

  test "nil tags pass everything through" do
    assert {"", "<think>x</think>", [{:delta, "<think>x</think>"}]} = run(["<think>x</think>"], nil)
  end

  test "split/2 on a whole reply" do
    assert ReasoningParser.split("<think>plan</think>\n\nHello", @think) == {"plan", "Hello"}
    assert ReasoningParser.split("Hello", @think) == {nil, "Hello"}
    assert ReasoningParser.split("<think>x</think>y", nil) == {nil, "<think>x</think>y"}
  end
end
