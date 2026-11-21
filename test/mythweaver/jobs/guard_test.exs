defmodule Mythweaver.Jobs.GuardTest do
  use ExUnit.Case, async: true

  alias Mythweaver.Jobs.Guard

  defp feed_all(guard, type, pieces) do
    Enum.reduce_while(pieces, {:ok, guard}, fn piece, {:ok, guard} ->
      case Guard.feed(guard, type, piece) do
        {:ok, guard} -> {:cont, {:ok, guard}}
        error -> {:halt, error}
      end
    end)
  end

  # Roughly 4000 bytes of sentences that never repeat a 60-byte stretch.
  @prose 1..64
         |> Enum.map_join(" ", fn n ->
           "Sentence #{n} wanders through hall #{n * 7} where lantern #{n * 13} flickers."
         end)

  test "a looping content stream trips :repetition once it is long enough" do
    guard = Guard.new(loop_guard?: true)
    pieces = List.duplicate("the same line again. ", 400)

    assert feed_all(guard, :delta, pieces) == {:error, :repetition}
    # Below 600 bytes even a pure loop is left alone.
    assert {:ok, _guard} = feed_all(guard, :delta, Enum.take(pieces, 25))
  end

  test "a looping reasoning stream trips :repetition too" do
    assert Guard.new(loop_guard?: true) |> Guard.feed(:reasoning, String.duplicate("hmm, wait. ", 300)) ==
             {:error, :repetition}
  end

  test "ordinary prose does not trip the loop guard" do
    assert byte_size(@prose) >= 4000
    pieces = for <<chunk::binary-size(7) <- @prose>>, do: chunk

    assert {:ok, %{text: text}} = feed_all(Guard.new(loop_guard?: true), :delta, pieces)
    assert byte_size(text) >= 4000
  end

  test "loops pass when the loop guard is off" do
    assert {:ok, _guard} = Guard.feed(Guard.new(), :delta, String.duplicate("again ", 1000))
  end

  test ":output_cap counts content and reasoning together" do
    guard = Guard.new(max_chars: 10)

    assert {:ok, guard} = Guard.feed(guard, :reasoning, "12345")
    assert {:ok, guard} = Guard.feed(guard, :delta, "67890")
    assert Guard.feed(guard, :delta, "!") == {:error, :output_cap}
  end
end
