defmodule Mythweaver.AI.ReasoningParser do
  @moduledoc """
  Splits inline reasoning out of streamed reply text, for backends that put thinking in the content
  (`<think>…</think>`) instead of a separate wire field.

  An incremental state machine over content tokens, following SillyTavern's reasoning auto-parse
  (`public/scripts/reasoning.js`): parsing only starts if the reply *begins* with the prefix (leading
  whitespace allowed); everything up to the suffix is reasoning; content resumes after it with
  leading whitespace trimmed; a missing suffix leaves the whole tail as reasoning. Only the first
  block counts; a later tag pair stays in content.

  Adapter-agnostic: it sees plain strings, so any adapter can run its content through it. No event
  ever carries `""`, which keeps the adapter contract that tokens are non-empty.
  """

  @type event :: {:reasoning | :delta, String.t()}
  @opaque t :: map()

  @doc "A parser for `{prefix, suffix}`, or a passthrough parser for `nil`."
  @spec new({String.t(), String.t()} | nil) :: t
  def new(nil), do: %{state: :passthrough}

  def new({prefix, suffix}) when is_binary(prefix) and is_binary(suffix),
    do: %{tags: {prefix, suffix}, state: :detecting, buffer: "", trim?: false}

  @doc "Feeds one content token, returning the events it completes and the next parser."
  @spec feed(t, String.t()) :: {[event], t}
  def feed(%{state: :passthrough} = parser, ""), do: {[], parser}
  def feed(%{state: :passthrough} = parser, text), do: {[{:delta, text}], parser}

  def feed(parser, text) when is_binary(text) do
    {events, parser} = step(parser, text, [])
    {Enum.reverse(events), parser}
  end

  @doc """
  Flushes whatever is held back at the end of the reply. A dangling partial prefix is content (a
  reply of only `"<thi"`); an unterminated think block (e.g. cut off by `max_tokens`) is reasoning.
  """
  @spec finish(t) :: [event]
  def finish(%{state: :detecting, buffer: buffer} = parser),
    do: parser |> put(:delta, buffer, []) |> elem(0) |> Enum.reverse()

  def finish(%{state: :reasoning, buffer: buffer} = parser),
    do: parser |> put(:reasoning, buffer, []) |> elem(0) |> Enum.reverse()

  def finish(_parser), do: []

  @doc "Splits a whole reply: `{reasoning, content}`, with `reasoning` `nil` when there is none."
  @spec split(String.t(), {String.t(), String.t()} | nil) :: {String.t() | nil, String.t()}
  def split(text, tags) when is_binary(text) do
    parser = new(tags)
    {events, parser} = feed(parser, text)
    events = events ++ finish(parser)

    reasoning = for {:reasoning, piece} <- events, do: piece
    content = for {:delta, piece} <- events, do: piece

    {if(reasoning != [], do: IO.iodata_to_binary(reasoning)), IO.iodata_to_binary(content)}
  end

  defp step(%{state: :detecting, tags: {prefix, _suffix}} = parser, text, events) do
    combined = parser.buffer <> text
    trimmed = String.trim_leading(combined)

    cond do
      String.starts_with?(trimmed, prefix) ->
        rest = binary_part(trimmed, byte_size(prefix), byte_size(trimmed) - byte_size(prefix))
        step(%{parser | state: :reasoning, buffer: "", trim?: true}, rest, events)

      # Covers the all-whitespace buffer too: `""` is a prefix of everything.
      String.starts_with?(prefix, trimmed) ->
        {events, %{parser | buffer: combined}}

      true ->
        put(%{parser | state: :content, buffer: ""}, :delta, combined, events)
    end
  end

  defp step(%{state: :reasoning, tags: {_prefix, suffix}} = parser, text, events) do
    combined = parser.buffer <> text

    case :binary.match(combined, suffix) do
      {pos, len} ->
        {events, parser} = put(%{parser | buffer: ""}, :reasoning, binary_part(combined, 0, pos), events)
        after_suffix = binary_part(combined, pos + len, byte_size(combined) - pos - len)
        put(%{parser | state: :content, trim?: true}, :delta, after_suffix, events)

      :nomatch ->
        held = held_back(combined, suffix)
        emitted = binary_part(combined, 0, byte_size(combined) - held)
        {events, parser} = put(parser, :reasoning, emitted, events)
        {events, %{parser | buffer: binary_part(combined, byte_size(combined) - held, held)}}
    end
  end

  defp step(%{state: :content} = parser, text, events), do: put(parser, :delta, text, events)

  # Length of the longest tail of `combined` that is a proper prefix of `suffix`: those bytes may be
  # the start of the suffix split across tokens, so they cannot be emitted as reasoning yet.
  defp held_back(combined, suffix) do
    max = min(byte_size(suffix) - 1, byte_size(combined))

    Enum.find(max..1//-1, 0, fn k ->
      binary_part(combined, byte_size(combined) - k, k) == binary_part(suffix, 0, k)
    end)
  end

  # Prepends one event onto the reversed list, left-trimming while `trim?` holds and never emitting
  # `""`. `trim?` turns off at the first non-empty piece.
  defp put(parser, type, piece, events) do
    piece = if parser.trim?, do: String.trim_leading(piece), else: piece

    if piece == "" do
      {events, parser}
    else
      {[{type, piece} | events], %{parser | trim?: false}}
    end
  end
end
