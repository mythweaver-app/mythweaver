defmodule Mythweaver.Jobs.Guard do
  @moduledoc """
  Output checks a job's runner applies to every streamed token, pure so they are cheap to test.

  Two trips:

    * `:output_cap`: content plus reasoning exceeds `max_chars` bytes (nil disables it).
    * `:repetition`: with `loop_guard?` on, the stream just fed has looped: once it is at least 600
      bytes, its last 60 bytes occur 5 or more times within its last 3000 bytes. That is llama.cpp's
      streaming form of an endless loop; the silent form is the scheduler's token watchdog.
  """

  @min_bytes 600
  @tail_bytes 60
  @window_bytes 3000
  @max_repeats 5

  @type t :: %{max_chars: pos_integer() | nil, loop_guard?: boolean(), text: binary(), reasoning: binary()}

  @doc "A fresh guard. `opts`: `:max_chars` (nil = no cap), `:loop_guard?` (default false)."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %{
      max_chars: Keyword.get(opts, :max_chars),
      loop_guard?: Keyword.get(opts, :loop_guard?, false),
      text: "",
      reasoning: ""
    }
  end

  @doc "Feeds one `:delta` or `:reasoning` piece."
  @spec feed(t(), :delta | :reasoning, binary()) :: {:ok, t()} | {:error, :output_cap | :repetition}
  def feed(guard, :delta, text), do: check(%{guard | text: guard.text <> text}, :text)
  def feed(guard, :reasoning, text), do: check(%{guard | reasoning: guard.reasoning <> text}, :reasoning)

  defp check(guard, stream) do
    cond do
      guard.max_chars != nil and byte_size(guard.text) + byte_size(guard.reasoning) > guard.max_chars ->
        {:error, :output_cap}

      guard.loop_guard? and looping?(Map.fetch!(guard, stream)) ->
        {:error, :repetition}

      true ->
        {:ok, guard}
    end
  end

  defp looping?(text) when byte_size(text) < @min_bytes, do: false

  defp looping?(text) do
    size = byte_size(text)
    tail = binary_part(text, size, -@tail_bytes)
    window = binary_part(text, size, -min(size, @window_bytes))
    length(:binary.matches(window, tail)) >= @max_repeats
  end
end
