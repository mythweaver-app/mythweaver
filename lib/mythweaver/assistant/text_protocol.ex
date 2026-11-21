defmodule Mythweaver.Assistant.TextProtocol do
  @moduledoc """
  Tool calling for a model without native `tools` support (`Model.supports_tools` off): the tool
  list goes into the system message, and the model ends its reply with one
  `<tool_call>{"name": …, "arguments": {…}}</tool_call>` block per call. Results come back in the
  next user message as `<tool_result id="…" name="…">JSON</tool_result>`.
  """

  alias Mythweaver.Assistant.Tool

  @open "<tool_call>"
  @block ~r/<tool_call>\s*(.*?)\s*<\/tool_call>/s

  @doc "The system-message section that teaches the protocol and lists `tools`."
  @spec instructions([Tool.t()]) :: String.t()
  def instructions(tools) do
    listing = Jason.encode!(for t <- tools, do: %{name: t.name, description: t.description, parameters: t.parameters})

    "## Tools\nYou can call these tools:\n" <>
      listing <>
      "\n\nTo call tools, end your reply with one block per call, exactly:\n" <>
      ~s(<tool_call>{"name": "tool_name", "arguments": {…}}</tool_call>\n) <>
      ~s(Write nothing after the blocks. Results arrive in the next message as <tool_result id="…" name="…">JSON</tool_result>.)
  end

  @doc """
  The reply's visible text (before the first block, trimmed) and its calls. A block that is not a
  `{"name", "arguments"}` object becomes a call with no name and the raw text as arguments, which
  the runner records as failed.
  """
  @spec parse(String.t()) :: {String.t(), [%{id: String.t(), name: String.t(), arguments: String.t()}]}
  def parse(text) when is_binary(text) do
    calls =
      @block
      |> Regex.scan(text, capture: :all_but_first)
      |> Enum.with_index()
      |> Enum.map(fn {[raw], i} ->
        case Jason.decode(raw) do
          {:ok, %{"name" => name} = call} when is_binary(name) ->
            %{id: "text_#{i}", name: name, arguments: Jason.encode!(call["arguments"] || %{})}

          _ ->
            %{id: "text_#{i}", name: "", arguments: raw}
        end
      end)

    {text |> before_open() |> String.trim(), calls}
  end

  @doc """
  The text a stream shows so far: everything before the first block, also holding back a trailing
  partial `<tool_call>` so the markup never flashes.
  """
  @spec visible_streaming(String.t()) :: String.t()
  def visible_streaming(text) when is_binary(text) do
    text = before_open(text)

    held =
      Enum.find((String.length(@open) - 1)..1//-1, 0, fn n ->
        String.ends_with?(text, String.slice(@open, 0, n))
      end)

    String.slice(text, 0, String.length(text) - held)
  end

  defp before_open(text) do
    case :binary.split(text, @open) do
      [before, _rest] -> before
      [all] -> all
    end
  end
end
