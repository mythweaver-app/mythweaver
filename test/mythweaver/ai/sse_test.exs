defmodule Mythweaver.AI.SSETest do
  use ExUnit.Case, async: true

  alias Mythweaver.AI.SSE

  test "buffers a frame split across chunks and emits it once complete" do
    assert {[], decoder} = SSE.decode(SSE.new(), ~s(data: {"a":1}))
    assert {payloads, _decoder} = SSE.decode(decoder, "\n\ndata: {\"b\":2}\n\n")
    assert payloads == [~s({"a":1}), ~s({"b":2})]
  end

  test "emits every frame carried by one chunk, in order" do
    chunk = "data: one\n\ndata: two\n\ndata: three\n\n"

    assert {["one", "two", "three"], _decoder} = SSE.decode(SSE.new(), chunk)
  end

  test "treats CRLF separators the same as LF" do
    chunk = "data: one\r\n\r\ndata: two\r\n\r\n"

    assert {["one", "two"], _decoder} = SSE.decode(SSE.new(), chunk)
  end

  test "a CRLF separator split between chunks still ends the frame" do
    {first, decoder} = SSE.decode(SSE.new(), "data: one\r\n\r")
    {second, _decoder} = SSE.decode(decoder, "\ndata: two\r\n\r\n")

    assert first ++ second == ["one", "two"]
  end

  test "returns the [DONE] sentinel as an ordinary payload" do
    assert {["[DONE]"], _decoder} = SSE.decode(SSE.new(), "data: [DONE]\n\n")
  end

  test "strips the data prefix and at most one space" do
    assert {["x"], _decoder} = SSE.decode(SSE.new(), "data:x\n\n")
    assert {["x"], _decoder} = SSE.decode(SSE.new(), "data: x\n\n")
    assert {[" own"], _decoder} = SSE.decode(SSE.new(), "data:  own\n\n")
  end

  test "drops comments and non-data fields" do
    assert {["hi"], _decoder} = SSE.decode(SSE.new(), ":comment\nevent: message\ndata: hi\n\n")
    assert {[], _decoder} = SSE.decode(SSE.new(), ":keep-alive\nevent: ping\n\n")
  end

  test "joins multiple data lines in one frame with a newline" do
    assert {["a\nb"], _decoder} = SSE.decode(SSE.new(), "data: a\ndata: b\n\n")
  end

  test "an empty chunk changes nothing" do
    {[], decoder} = SSE.decode(SSE.new(), "data: partial")

    assert SSE.decode(decoder, "") == {[], decoder}
  end
end
