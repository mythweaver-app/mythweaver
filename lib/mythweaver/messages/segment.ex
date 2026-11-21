defmodule Mythweaver.Messages.Segment do
  @moduledoc """
  Paragraph segmentation for splitting and merging messages.

  A paragraph ends at a blank line. Fenced code blocks (```` ``` ```` or `~~~`) are atomic: blank lines
  inside them are content, and only the fence character that opened a block closes it. Every split and
  merge rejoins paragraphs with `join/1`, so `paragraphs/1` of a joined text gives the parts back.
  """

  @fence ~r/^(`{3,}|~{3,})/

  @doc "The non-blank paragraphs of `text`, each trimmed, in order."
  @spec paragraphs(String.t()) :: [String.t()]
  def paragraphs(text) when is_binary(text) do
    {done, current, _fence} =
      text
      |> String.split("\n")
      |> Enum.reduce({[], [], nil}, &line/2)

    done |> flush(current) |> Enum.reverse()
  end

  defp line(line, {done, current, fence}) do
    case Regex.run(@fence, String.trim_leading(line), capture: :all_but_first) do
      [marker] ->
        char = String.first(marker)

        fence =
          cond do
            fence == nil -> char
            fence == char -> nil
            true -> fence
          end

        {done, [line | current], fence}

      nil ->
        if fence == nil and String.trim(line) == "" do
          {flush(done, current), [], nil}
        else
          {done, [line | current], fence}
        end
    end
  end

  defp flush(done, current) do
    current
    |> Enum.reverse()
    |> Enum.join("\n")
    |> String.trim()
    |> case do
      "" -> done
      paragraph -> [paragraph | done]
    end
  end

  @doc "Joins paragraphs with one blank line between them."
  @spec join([String.t()]) :: String.t()
  def join(parts), do: Enum.join(parts, "\n\n")
end
