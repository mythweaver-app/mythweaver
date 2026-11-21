defmodule Mythweaver.Assistant.Tools.Results do
  @moduledoc "Assistant tool for paging a tool result that `Mythweaver.Assistant.Context` cut short."

  alias Mythweaver.Assistant
  alias Mythweaver.Assistant.Context
  alias Mythweaver.Assistant.Tool
  alias Mythweaver.Assistant.ToolCall
  alias Mythweaver.Assistant.Tools.Args

  def tools do
    [
      %Tool{
        name: "read_tool_result",
        description:
          "Reads part of an earlier tool result that was cut short, using the id, offset and length its truncation " <>
            "note gives (bytes of the result's JSON text). next_offset is where the following part starts; null at the end.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "id" => %{"type" => "string", "description" => "The id from the truncation note."},
            "offset" => %{"type" => "integer", "minimum" => 0, "description" => "First byte to read."},
            "length" => %{"type" => "integer", "minimum" => 1, "description" => "Bytes to read."}
          },
          "required" => ["id", "offset", "length"]
        },
        kind: :read,
        summary: fn _ -> "Read more of a tool result" end,
        run: &read/2
      }
    ]
  end

  defp read(scope, args) do
    with {:ok, id} <- Args.uuid(args, "id"),
         {:ok, call} <- fetch(scope, id),
         {:ok, offset, length} <- window(args) do
      json = ToolCall.result_json(call)
      size = byte_size(json)

      if offset > size do
        {:error, Args.error("offset is past the end (#{size} bytes).")}
      else
        {text, start, stop} = Context.page(json, offset, length)

        {:ok,
         %{
           "id" => call.id,
           "offset" => start,
           "next_offset" => if(stop < size, do: stop),
           "total_bytes" => size,
           "text" => text
         }}
      end
    end
  end

  defp fetch(scope, id) do
    case Assistant.get_tool_call(scope, id) do
      nil -> {:error, Args.error(:not_found)}
      call -> if ToolCall.terminal?(call), do: {:ok, call}, else: {:error, Args.error("That call has no result yet.")}
    end
  end

  defp window(%{"offset" => offset, "length" => length})
       when is_integer(offset) and offset >= 0 and is_integer(length) and length > 0, do: {:ok, offset, length}

  defp window(_args), do: {:error, Args.error("offset must be an integer of 0 or more and length one of 1 or more.")}
end
