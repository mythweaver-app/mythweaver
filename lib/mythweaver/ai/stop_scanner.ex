defmodule Mythweaver.AI.StopScanner do
  @moduledoc """
  Ends streamed reply text at the first stop string, whether or not the backend honored `stop`.

  SillyTavern's stopping strings, enforced here rather than trusted to the backend: text mode
  forwards them, but chat endpoints ignore names they were never sent, and some backends ignore
  `stop` outright. Text is held back while its tail could still become a stop string (`"\\nBo"`
  before `"\\nBob:"`), so nothing past the stop is ever emitted, as SillyTavern trims a trailing
  partial stop string from every streamed frame.

  A stop string that starts with a newline also matches at the very start of the reply: a reply
  that opens with `"Bob:"` is Bob's line, like one that breaks into it (SillyTavern's group-reply
  trimming, `(^|\\n)Name:`). A whitespace-only stop string (single-line mode's `"\\n"`) matches only
  after the reply has some text, or a reply that opens with a line break would end before it began.

  Byte-level and allocation-light: only the held tail and the new token are searched, never the
  whole reply. Splits fall on character boundaries because every match and every held tail starts
  where a valid UTF-8 stop string starts.
  """

  @opaque t :: %{strings: [String.t()], held: binary(), emitted?: boolean(), begun?: boolean()}

  @doc "A scanner for `strings`; empty strings are dropped."
  @spec new([String.t()]) :: t
  def new(strings),
    do: %{strings: Enum.uniq(for(s <- strings, s != "", do: s)), held: "", emitted?: false, begun?: false}

  @doc """
  Feeds one token. `{:cont, text, scanner}` emits `text` (possibly `""` while a tail is held);
  `{:stop, text}` emits the text before the stop string, and the reply ends there.
  """
  @spec feed(t, binary()) :: {:cont, binary(), t} | {:stop, binary()}
  def feed(%{strings: []} = scanner, text), do: {:cont, text, scanner}

  def feed(scanner, text) do
    window = scanner.held <> text
    # Before anything is emitted the window starts the reply, which sits after an implied newline.
    {hay, offset} = if scanner.emitted?, do: {window, 0}, else: {"\n" <> window, 1}

    case first_match(hay, scanner) do
      nil ->
        hold = min(longest_partial(hay, scanner.strings), byte_size(window))
        emit = binary_part(window, 0, byte_size(window) - hold)
        held = binary_part(window, byte_size(emit), hold)

        {:cont, emit,
         %{scanner | held: held, emitted?: scanner.emitted? or emit != "", begun?: scanner.begun? or not blank?(emit)}}

      at ->
        {:stop, binary_part(window, 0, max(at - offset, 0))}
    end
  end

  @doc "The text still held back when the reply ends without a stop string."
  @spec finish(t) :: binary()
  def finish(%{held: held}), do: held

  @doc "Cuts a whole reply: `{text, stopped?}`."
  @spec cut(binary(), [String.t()]) :: {binary(), boolean()}
  def cut(text, strings) do
    case feed(new(strings), text) do
      {:cont, emit, scanner} -> {emit <> finish(scanner), false}
      {:stop, emit} -> {emit, true}
    end
  end

  # The earliest match. A whitespace-only string counts only once text precedes it.
  defp first_match(hay, scanner) do
    scanner.strings
    |> Enum.flat_map(fn string ->
      matches = :binary.matches(hay, string)

      if blank?(string) and not scanner.begun?,
        do: matches |> Enum.find(fn {at, _len} -> not blank?(binary_part(hay, 0, at)) end) |> List.wrap(),
        else: Enum.take(matches, 1)
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.min(fn -> nil end)
  end

  defp blank?(text), do: String.trim(text) == ""

  # The longest tail of `hay` that is a proper prefix of some stop string.
  defp longest_partial(hay, strings) do
    size = byte_size(hay)

    Enum.reduce(strings, 0, fn string, best ->
      max_len = min(byte_size(string) - 1, size)

      Enum.find(max_len..(best + 1)//-1, best, fn len ->
        binary_part(hay, size - len, len) == binary_part(string, 0, len)
      end)
    end)
  end
end
