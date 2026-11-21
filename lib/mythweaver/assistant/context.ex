defmodule Mythweaver.Assistant.Context do
  @moduledoc """
  The request input for one assistant round: the system message, the thread's history with its
  tool calls and results, and (for `:native`) the offered tools. The protocol follows the current
  model, so a thread survives a model switch either way.

  The history is the thread after its newest usable compaction summary (`thread/1`), whose text
  rides in the system message. It is fitted to `ContextLimit.for_reply/2`, oldest thread messages
  dropped first and each message kept or dropped with its tool results; with no known limit it is
  the last 50 messages. Each tool result goes out whole up to the window (`window_bytes/1`); a
  longer one is cut there and ends with a note naming `read_tool_result` for the rest.

  The user's attachments go as the model can take them, the way role-play prompts send them, each
  kind within its inline limit (`Mythweaver.AI.Model.inline_limits/1`): images to a model that sees
  images, PDFs, audio and video to one that reads, hears or watches them, as parts
  (`Mythweaver.Attachments.inline_attachments/2`); every other one as its text line
  (`describe_line/1`, `file_line/2`, a document past its limit as its summary).
  """

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI.Model
  alias Mythweaver.AI.Request.Message, as: RequestMessage
  alias Mythweaver.AI.Request.Text
  alias Mythweaver.Assistant
  alias Mythweaver.Assistant.Prompt
  alias Mythweaver.Assistant.TextProtocol
  alias Mythweaver.Assistant.Tool
  alias Mythweaver.Assistant.ToolCall
  alias Mythweaver.Assistant.Tools
  alias Mythweaver.Attachments
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message
  alias Mythweaver.Prompts.AttachmentRef
  alias Mythweaver.Prompts.ContextLimit
  alias Mythweaver.Prompts.Transcript

  @history 50
  # One tool result's share of the context: `@default_window` bytes with no known limit, else a
  # quarter of the usable tokens at `@bytes_per_token`, never under `@min_window`.
  @default_window 32_000
  @min_window 2_000
  @bytes_per_token 3

  @doc "`%{messages:, tools:}` for `Jobs.stream_async/5`'s input."
  @spec build(Scope.t(), Chat.t(), Model.t(), :native | :text) :: %{messages: [RequestMessage.t()], tools: [map()]}
  def build(%Scope{} = scope, %Chat{} = chat, %Model{} = model, protocol) when protocol in [:native, :text],
    do: input(scope, chat, model, protocol, :reply)

  @doc """
  The input for a compaction: the thread as a reply reads it, in the text protocol's form and with
  no tools, ending with `Prompt.compaction_request/0`.
  """
  @spec compaction(Scope.t(), Chat.t(), Model.t()) :: %{messages: [RequestMessage.t()], tools: []}
  def compaction(%Scope{} = scope, %Chat{} = chat, %Model{} = model), do: input(scope, chat, model, :text, :compact)

  @doc "The thread as the model reads it: the newest usable summary message (or nil) and the messages after it, other summaries left out."
  @spec thread(Chat.t()) :: {Message.t() | nil, [Message.t()]}
  def thread(%Chat{} = chat) do
    newest_first =
      chat
      |> Messages.list_messages()
      |> Enum.filter(& &1.visible_to_ai)
      |> Enum.reject(&match?(%{generating: true}, Message.active_body(&1)))
      |> Enum.reverse()

    {after_summary, rest} = Enum.split_while(newest_first, &(not usable_summary?(&1)))
    after_summary = after_summary |> Enum.reverse() |> Enum.reject(& &1.summary)

    case rest do
      [summary | _] -> {summary, after_summary}
      [] -> {nil, after_summary}
    end
  end

  # A stopped, failed or empty summary leaves the earlier one (or the whole thread) in force.
  defp usable_summary?(%Message{summary: true} = message) do
    case Message.active_body(message) do
      %{error: nil, content: content} when is_binary(content) -> String.trim(content) != ""
      _ -> false
    end
  end

  defp usable_summary?(%Message{}), do: false

  defp input(scope, chat, model, protocol, mode) do
    tools = Tools.all()
    {summary, messages} = thread(chat)
    cl = ContextLimit.for_reply(scope, model)
    window = window_bytes(cl)

    system =
      Prompt.system(scope) <>
        if(mode == :reply and protocol == :text, do: "\n\n" <> TextProtocol.instructions(tools), else: "") <>
        if(mode == :reply, do: Prompt.limits_section(cl && cl.limit, window), else: "") <>
        if(summary, do: Prompt.summary_section(Message.active_content(summary)), else: "")

    wire_tools = if mode == :reply and protocol == :native, do: Enum.map(tools, &Tool.wire/1), else: []

    tail =
      case mode do
        :reply -> []
        :compact -> [%RequestMessage{role: :user, content: Prompt.compaction_request()}]
      end

    calls = Assistant.list_tool_calls(chat.id)

    inline = Transcript.within_limits(messages, Model.inline_limits(model))

    per = Enum.map(messages, &history_messages(&1, Map.get(calls, &1.id, []), protocol, model, inline, window))
    fixed = [system | if(wire_tools == [], do: [], else: [Jason.encode!(wire_tools)])] ++ Enum.map(tail, & &1.content)
    history = per |> Enum.take(-kept(cl, fixed, per)) |> Enum.concat()

    Attachments.inline_attachments(
      %{messages: [%RequestMessage{role: :system, content: system} | history] ++ tail, tools: wire_tools},
      model
    )
  end

  # How many of the newest thread messages go out. The newest always does, even on overflow, so the
  # provider's own error shows on the reply instead of an empty request.
  defp kept(nil, _fixed, _per), do: @history

  defp kept(%ContextLimit{} = cl, fixed, per) do
    {kept, _report} = ContextLimit.fit(cl, fixed, Enum.map(per, &entry/1))
    max(kept, min(1, length(per)))
  end

  # The bytes of one tool result sent whole: about a quarter of the usable context.
  defp window_bytes(nil), do: @default_window

  defp window_bytes(%ContextLimit{limit: limit, reserve: reserve}),
    do: max(@min_window, div(max(limit - reserve, 0), 4) * @bytes_per_token)

  # One thread message's request messages as a `ContextLimit.entry()`.
  defp entry(sent) do
    attachments =
      for %RequestMessage{content: parts} <- sent,
          is_list(parts),
          %AttachmentRef{attachment: attachment} <- parts,
          do: attachment

    {images, files} = Enum.split_with(attachments, &(&1.kind == :image))
    %{content: sent |> Enum.flat_map(&texts/1) |> Enum.join("\n"), images: images, files: files}
  end

  defp texts(%RequestMessage{content: content, tool_calls: calls}) do
    content_texts =
      case content do
        text when is_binary(text) -> [text]
        parts when is_list(parts) -> for %Text{text: text} <- parts, do: text
        nil -> []
      end

    content_texts ++ for(%{name: name, arguments: arguments} <- calls, do: name <> arguments)
  end

  defp history_messages(%Message{author_is_player: true} = message, _calls, _protocol, model, inline, _window),
    do: [%RequestMessage{role: :user, content: user_content(message, model, inline)}]

  defp history_messages(%Message{} = message, calls, protocol, _model, _inline, window) do
    content = Message.active_content(message) || ""

    if String.trim(content) == "" and calls == [],
      do: [],
      else: assistant_messages(content, calls, protocol, window)
  end

  # Plain text without attachments; else the text and each attachment's text line, then the parts.
  defp user_content(message, model, inline) do
    text = Message.active_content(message) || ""
    ready = Enum.filter(Message.loaded_attachments(message), &(&1.status == :ready))
    {native, as_text} = Enum.split_with(ready, &native?(&1, model, inline))

    lines =
      [
        text
        | Enum.map(as_text, &text_line(&1, inline))
      ]
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.join("\n")

    if native == [],
      do: lines,
      else: [%Text{text: lines} | Enum.map(native, &%AttachmentRef{attachment: &1})]
  end

  # An attachment goes natively when the model takes its kind and it is within its kind's limit.
  defp native?(%{kind: :image, id: id}, model, inline), do: Model.sees_images?(model) and MapSet.member?(inline, id)

  defp native?(%{content_type: "application/pdf", id: id}, model, inline),
    do: Model.reads_files?(model) and MapSet.member?(inline, id)

  defp native?(%{kind: :audio, id: id}, model, inline), do: Model.hears_audio?(model) and MapSet.member?(inline, id)
  defp native?(%{kind: :video, id: id}, model, inline), do: Model.watches_video?(model) and MapSet.member?(inline, id)
  defp native?(_attachment, _model, _inline), do: false

  # Past its limit a document reads as its summary.
  defp text_line(%{kind: :image} = a, _inline), do: Attachments.describe_line(a)

  defp text_line(a, inline), do: Attachments.file_line(a, if(MapSet.member?(inline, a.id), do: :full, else: :summary))

  defp assistant_messages(content, calls, :native, window) do
    wire_calls = for c <- calls, do: %{id: c.call_id, name: c.name, arguments: Jason.encode!(c.arguments)}

    [
      %RequestMessage{role: :assistant, content: content, tool_calls: wire_calls}
      | for(c <- calls, do: %RequestMessage{role: :tool, tool_call_id: c.call_id, content: result_text(c, window)})
    ]
  end

  defp assistant_messages(content, calls, :text, window) do
    blocks =
      Enum.map_join(calls, fn c ->
        "\n<tool_call>#{Jason.encode!(%{name: c.name, arguments: c.arguments})}</tool_call>"
      end)

    results =
      Enum.map_join(calls, "\n", fn c ->
        ~s(<tool_result id="#{c.call_id}" name="#{c.name}">#{result_text(c, window)}</tool_result>)
      end)

    [%RequestMessage{role: :assistant, content: content <> blocks}] ++
      if(calls == [], do: [], else: [%RequestMessage{role: :user, content: results}])
  end

  # What the model reads as a call's result: the terminal outcome, whole up to `window` bytes, else
  # its first `window` bytes and a note on paging the rest with `read_tool_result` (the call's row
  # id; a page of ⅔ the window stays under it once escaped as that tool's own result).
  defp result_text(%ToolCall{} = call, window) do
    if ToolCall.terminal?(call) do
      json = ToolCall.result_json(call)

      if byte_size(json) <= window do
        json
      else
        {head, _start, stop} = page(json, 0, window)

        head <>
          "…[truncated: bytes 0–#{stop} of #{byte_size(json)} shown. Read more with read_tool_result " <>
          ~s|{"id": "#{call.id}", "offset": #{stop}, "length": #{div(window * 2, 3)}}]|
      end
    else
      ~s({"error":"No result: the user has not acted on this."})
    end
  end

  @doc "Bytes offset..offset+length of text, both ends moved off UTF-8 continuation bytes (start forward, end back): {slice, start, stop}."
  @spec page(String.t(), non_neg_integer(), pos_integer()) :: {String.t(), non_neg_integer(), non_neg_integer()}
  def page(text, offset, length) do
    size = byte_size(text)
    start = forward(text, min(offset, size), size)
    stop = back(text, min(start + length, size), start, size)
    {binary_part(text, start, stop - start), start, stop}
  end

  defp forward(text, at, size) when at < size do
    if continuation?(text, at), do: forward(text, at + 1, size), else: at
  end

  defp forward(_text, at, _size), do: at

  defp back(text, at, start, size) when at > start and at < size do
    if continuation?(text, at), do: back(text, at - 1, start, size), else: at
  end

  defp back(_text, at, _start, _size), do: at

  defp continuation?(text, at), do: match?(<<0b10::2, _::6>>, binary_part(text, at, 1))
end
