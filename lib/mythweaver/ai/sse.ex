defmodule Mythweaver.AI.SSE do
  @moduledoc """
  Incremental Server-Sent-Events decoder.

  HTTP chunks do not align with SSE frames (one TCP chunk may carry three frames, half a frame, or
  a single byte), so decoding is stateful: feed bytes in, get complete payloads out, keep the
  remainder for next time.

  Only the `data:` field is decoded. Providers streaming completions use no other SSE field, and
  `id:`/`event:`/`retry:` lines are dropped rather than modeled.
  """

  defstruct buffer: ""

  @type t :: %__MODULE__{buffer: binary()}

  @doc "A decoder with an empty buffer."
  def new, do: %__MODULE__{}

  @doc """
  Feeds `chunk` in, returning `{payloads, decoder}`.

  `payloads` are the `data:` values of every frame completed by this chunk, in order, with the
  leading `data:` and one optional space stripped, and multi-line `data:` fields joined with `\\n`
  per the SSE spec. An incomplete trailing frame stays in the decoder.
  """
  def decode(%__MODULE__{buffer: buffer} = decoder, chunk) when is_binary(chunk) do
    # CRLF is normalized after joining the buffer and the chunk, so one split on "\n\n" handles both
    # llama.cpp's bare LF frames and the CRLF that OpenAI/Azure send, even when a `\r\n` pair is
    # split across two chunks.
    data = String.replace(buffer <> chunk, "\r\n", "\n")

    case String.split(data, "\n\n") do
      [remainder] ->
        {[], %{decoder | buffer: remainder}}

      frames ->
        {complete, [remainder]} = Enum.split(frames, -1)
        {Enum.flat_map(complete, &frame_payload/1), %{decoder | buffer: remainder}}
    end
  end

  # A frame with no `data:` line (a lone comment, a keep-alive, the blank tail of a trailing
  # separator) yields nothing rather than an empty payload.
  defp frame_payload(frame) do
    frame
    |> String.split("\n")
    |> Enum.flat_map(&data_line/1)
    |> case do
      [] -> []
      lines -> [Enum.join(lines, "\n")]
    end
  end

  defp data_line("data:" <> rest), do: [strip_one_space(rest)]
  defp data_line(_other), do: []

  # Exactly one leading space, never `String.trim/1`: a token's text is legitimately " own" in the
  # live text-mode stream, and trimming would corrupt it.
  defp strip_one_space(" " <> rest), do: rest
  defp strip_one_space(rest), do: rest
end
