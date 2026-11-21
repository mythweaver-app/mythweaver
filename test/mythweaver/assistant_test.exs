defmodule Mythweaver.AssistantTest do
  # Not `async: true`: the runner GenServer and the AI task it spawns must reach the shared sandbox.
  use Mythweaver.DataCase

  alias Mythweaver.AI
  alias Mythweaver.Assistant
  alias Mythweaver.Assistant.Prompt
  alias Mythweaver.Assistant.ToolCall
  alias Mythweaver.Assistant.Tools
  alias Mythweaver.Characters
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message
  alias Mythweaver.Messages.MessageBody
  alias Mythweaver.Settings

  setup context do
    Req.Test.set_req_test_to_shared(context)
    scope = scope!()
    provider = provider!(scope)
    {:ok, chat} = Assistant.create_chat(scope)
    :ok = Messages.subscribe(chat)
    %{scope: scope, provider: provider, chat: chat}
  end

  defp provider!(scope) do
    {:ok, provider} =
      AI.create_provider(scope, %{
        name: "Local-#{System.unique_integer([:positive])}",
        adapter: :openai_compatible,
        base_url: "http://localhost:8080/v1"
      })

    provider
  end

  defp model!(scope, provider, attrs \\ %{}) do
    {:ok, model} =
      AI.create_model(
        scope,
        Map.merge(%{name: "Gemma-#{System.unique_integer([:positive])}", api_model_id: "gemma-4"}, attrs)
      )

    {:ok, _link} = AI.link_model(scope, provider, model)
    model
  end

  defp content_frames(text) do
    [
      ~s(data: #{Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => %{"content" => text}}]})}\n\n),
      ~s(data: {"choices":[{"finish_reason":"stop","index":0,"delta":{}}]}\n\n),
      "data: [DONE]\n\n"
    ]
  end

  defp call_frames(name, arguments) do
    call = %{"index" => 0, "id" => "call_1", "function" => %{"name" => name, "arguments" => Jason.encode!(arguments)}}

    [
      ~s(data: #{Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => %{"tool_calls" => [call]}}]})}\n\n),
      ~s(data: {"choices":[{"finish_reason":"tool_calls","index":0,"delta":{}}]}\n\n),
      "data: [DONE]\n\n"
    ]
  end

  # Every request body goes to the test as `{:request, body}`; `frames_for` picks the reply from it.
  defp stub(frames_for) do
    test = self()

    Req.Test.stub(Mythweaver.AI, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      send(test, {:request, body})
      conn = Plug.Conn.send_chunked(conn, 200)

      Enum.reduce(frames_for.(body), conn, fn frame, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, frame)
        conn
      end)
    end)
  end

  defp answered?(body), do: Enum.any?(body["messages"], &(&1["role"] == "tool"))

  defp text_answered?(body),
    do: Enum.any?(body["messages"], &(&1["role"] == "user" and &1["content"] =~ "<tool_result"))

  # Waits for the chat's runner, if any, to exit.
  defp await_runner(chat) do
    case Registry.lookup(Mythweaver.Generation.Registry, {:assistant, chat.id}) do
      [{pid, _}] ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000

      [] ->
        :ok
    end
  end

  defp replies(chat) do
    chat
    |> Messages.list_messages()
    |> Enum.filter(&(&1.author_name == Message.assistant_author()))
  end

  defp calls(chat), do: chat.id |> Assistant.list_tool_calls() |> Map.values() |> List.flatten()

  test "a native read call runs at once and the next round answers", %{scope: scope, provider: provider, chat: chat} do
    model!(scope, provider, %{supports_tools: true})
    {:ok, aqua} = Characters.create_character(scope, %{name: "Aqua"})

    stub(fn body ->
      if answered?(body), do: content_frames("You have Aqua."), else: call_frames("list_characters", %{})
    end)

    assert {:ok, %Message{author_is_player: true}} = Assistant.send_message(scope, chat, "List my characters")
    await_runner(chat)

    assert [first, second] = replies(chat)
    refute first.author_is_player
    assert Message.active_content(second) == "You have Aqua."

    assert [%ToolCall{status: :succeeded, message_id: message_id, result: result}] = calls(chat)
    assert message_id == first.id
    assert Enum.any?(result["characters"], &(&1["id"] == aqua.id))

    assert_received {:request, %{"tools" => [_ | _]}}
    assert Repo.exists?(from(j in Job, where: j.chat_id == ^chat.id and j.tag == :assistant))
    assert Chats.get_chat(scope, chat.id).name == "List my characters"
  end

  test "a result past the window is cut with a note, and read_tool_result pages the rest",
       %{scope: scope, provider: provider, chat: chat} do
    # window = max(2000, div(4000 - 1024, 4) * 3) = 2232 bytes; a page is ⅔ of it.
    model!(scope, provider, %{supports_tools: true, context_window: 4000})
    {:ok, a} = Characters.create_character(scope, %{name: "A"})
    {:ok, b} = Characters.create_character(scope, %{name: "B"})
    {:ok, rp} = Chats.create_chat(scope, %{participants: [%{character_id: a.id}, %{character_id: b.id}]})
    {:ok, _} = Messages.post_message(scope, rp, {:character, a.id}, String.duplicate("lantern ", 1250))

    stub(fn body ->
      if answered?(body),
        do: content_frames("ok"),
        else: call_frames("read_chat_messages", %{"chat_id" => rp.id, "messages" => ["-1"]})
    end)

    {:ok, _} = Assistant.send_message(scope, chat, "Read the last message")
    await_runner(chat)

    assert_received {:request, _first}
    assert_received {:request, second}
    assert [%ToolCall{status: :succeeded} = call] = calls(chat)
    assert [%{"content" => cut}] = Enum.filter(second["messages"], &(&1["role"] == "tool"))

    assert cut =~ "[truncated: bytes 0–"
    assert cut =~ "read_tool_result"
    assert cut =~ call.id
    assert byte_size(cut) < 2232 + 300

    [offset] = Regex.run(~r/"offset": (\d+)/, cut, capture: :all_but_first)
    offset = String.to_integer(offset)
    {:ok, tool} = Tools.fetch("read_tool_result")

    assert {:ok, %{"text" => text, "next_offset" => next}} =
             Tools.run(scope, tool, %{"id" => call.id, "offset" => offset, "length" => 1488})

    assert text == binary_part(ToolCall.result_json(call), offset, byte_size(text))
    assert next == offset + byte_size(text)

    assert {:error, %{"error" => "Not found."}} =
             Tools.run(scope!(), tool, %{"id" => call.id, "offset" => offset, "length" => 1488})
  end

  describe "a write call" do
    setup %{scope: scope, provider: provider, chat: chat} do
      model!(scope, provider, %{supports_tools: true})

      stub(fn body ->
        if answered?(body),
          do: content_frames("Noted."),
          else: call_frames("create_characters", %{"items" => [%{"name" => "Bob"}]})
      end)

      {:ok, _} = Assistant.send_message(scope, chat, "Make Bob")
      await_runner(chat)
      [call] = calls(chat)
      %{call: call}
    end

    defp bob?, do: Repo.exists?(from(c in Character, where: c.name == "Bob"))

    test "waits for approval, then runs and resumes", %{scope: scope, chat: chat, call: call} do
      assert call.status == :pending
      refute bob?()
      assert length(replies(chat)) == 1

      assert Assistant.decide(scope, chat, call.id, :approve) == {:ok, :resumed}
      await_runner(chat)

      assert bob?()
      assert [%ToolCall{status: :succeeded}] = calls(chat)
      assert length(replies(chat)) == 2
      assert Assistant.decide(scope, chat, call.id, :approve) == {:error, :not_pending}
    end

    test "a rejection creates nothing and tells the model", %{scope: scope, chat: chat, call: call} do
      assert_received {:request, _first}
      assert Assistant.decide(scope, chat, call.id, :reject) == {:ok, :resumed}
      await_runner(chat)

      refute bob?()
      assert [%ToolCall{status: :rejected}] = calls(chat)
      assert_received {:request, body}
      assert Enum.any?(body["messages"], &(&1["role"] == "tool" and &1["content"] =~ "The user rejected this."))
    end

    test "a new message rejects the open call first", %{scope: scope, chat: chat, call: call} do
      {:ok, _} = Assistant.send_message(scope, chat, "Never mind")
      await_runner(chat)

      assert %ToolCall{status: :rejected, result: %{"error" => error}} = Repo.get!(ToolCall, call.id)
      assert error =~ "new message"
      refute bob?()
    end
  end

  test "the text protocol parses calls out of the reply", %{scope: scope, provider: provider, chat: chat} do
    model!(scope, provider, %{supports_tools: false})

    stub(fn body ->
      if text_answered?(body),
        do: content_frames("All done."),
        else: content_frames(~s(Sure.\n<tool_call>{"name":"list_characters","arguments":{}}</tool_call>))
    end)

    {:ok, _} = Assistant.send_message(scope, chat, "List them")
    await_runner(chat)

    assert [first, second] = replies(chat)
    assert Message.active_content(first) == "Sure."
    assert Message.active_content(second) == "All done."
    assert [%ToolCall{name: "list_characters", status: :succeeded}] = calls(chat)

    assert_received {:request, _round1}
    assert_received {:request, round2}
    refute Map.has_key?(round2, "tools")
    assert [%{"role" => "system", "content" => system} | _] = round2["messages"]
    assert system =~ "<tool_call>"
  end

  # llama.cpp's own tool-call parser turns a tool-trained model's `<tool_call>` text into
  # `tool_calls` even when no tools were offered, so the text holds no blocks.
  test "the text protocol takes calls the backend parsed out of the text", %{
    scope: scope,
    provider: provider,
    chat: chat
  } do
    model!(scope, provider, %{supports_tools: false})

    stub(fn body ->
      if text_answered?(body), do: content_frames("All done."), else: call_frames("list_characters", %{})
    end)

    {:ok, _} = Assistant.send_message(scope, chat, "List them")
    await_runner(chat)

    assert [%ToolCall{name: "list_characters", status: :succeeded}] = calls(chat)
    assert [_first, second] = replies(chat)
    assert Message.active_content(second) == "All done."
  end

  test "a key card for a connection that does not exist fails instead of opening",
       %{scope: scope, provider: provider, chat: chat} do
    model!(scope, provider, %{supports_tools: true})
    missing = Mythweaver.Schema.generate_id()

    stub(fn body ->
      if answered?(body),
        do: content_frames("Sorry."),
        else: call_frames("request_api_key", %{"connection_id" => missing})
    end)

    {:ok, _} = Assistant.send_message(scope, chat, "Set a key")
    await_runner(chat)

    assert [%ToolCall{status: :failed, result: %{"error" => "Not found."}}] = calls(chat)
    assert length(replies(chat)) == 2
  end

  test "an API key goes to the connection and nowhere else", %{scope: scope, provider: provider, chat: chat} do
    model!(scope, provider, %{supports_tools: true})

    stub(fn body ->
      if answered?(body),
        do: content_frames("Saved."),
        else: call_frames("request_api_key", %{"connection_id" => provider.id})
    end)

    {:ok, _} = Assistant.send_message(scope, chat, "Set my key")
    await_runner(chat)
    assert [%ToolCall{status: :awaiting_input} = call] = calls(chat)

    assert Assistant.submit_api_key(scope, chat, call.id, "  ") == {:error, :empty}
    assert Assistant.submit_api_key(scope, chat, call.id, "sk-secret") == {:ok, :resumed}
    await_runner(chat)

    assert AI.get_provider(scope, provider.id).api_key == "sk-secret"
    assert [%ToolCall{status: :succeeded} = call] = calls(chat)
    refute inspect({call.arguments, call.result}) =~ "sk-secret"
    refute Repo.exists?(from(b in MessageBody, where: like(b.content, "%sk-secret%")))

    assert_received {:request, _round1}
    assert_received {:request, round2}
    refute Jason.encode!(round2) =~ "sk-secret"
  end

  test "stop ends a streaming reply, and a running chat is busy", %{scope: scope, provider: provider, chat: chat} do
    model!(scope, provider, %{supports_tools: true})
    test = self()

    Req.Test.stub(Mythweaver.AI, fn conn ->
      send(test, :request_hanging)
      Process.sleep(:infinity)
      conn
    end)

    {:ok, _} = Assistant.send_message(scope, chat, "Hello")
    assert_receive :request_hanging
    chat_id = chat.id
    assert_received {:assistant_state, ^chat_id, true}
    assert Assistant.running?(scope, chat)
    assert Assistant.send_message(scope, chat, "Again") == {:error, :busy}

    assert Assistant.stop(scope, chat) == :ok
    assert_receive {:assistant_state, ^chat_id, false}
    await_runner(chat)

    refute Assistant.running?(scope, chat)
    assert [reply] = replies(chat)
    assert %MessageBody{error: "Stopped.", generating: false} = Message.active_body(reply)
    assert Assistant.stop(scope, chat) == {:error, :not_running}
  end

  test "a run stops after the round cap", %{scope: scope, provider: provider, chat: chat} do
    model!(scope, provider, %{supports_tools: true})
    stub(fn _body -> call_frames("list_characters", %{}) end)

    {:ok, _} = Assistant.send_message(scope, chat, "Loop")
    await_runner(chat)

    replies = replies(chat)
    assert length(replies) == 8
    assert Message.active_body(List.last(replies)).error =~ "8 tool rounds"
  end

  describe "compact/2" do
    setup %{scope: scope, provider: provider} do
      model!(scope, provider, %{supports_tools: true})
      :ok
    end

    defp compaction?(body), do: List.last(body["messages"])["content"] == Prompt.compaction_request()

    defp mentions?(body, text), do: Enum.any?(body["messages"], &(is_binary(&1["content"]) and &1["content"] =~ text))

    test "the summary replaces the messages before it in later rounds", %{scope: scope, chat: chat} do
      stub(fn body -> content_frames(if compaction?(body), do: "SUMMARY-TEXT", else: "Reply") end)
      assert Assistant.compact(scope, chat) == {:error, :nothing_to_compact}

      {:ok, _} = Assistant.send_message(scope, chat, "first question")
      await_runner(chat)
      assert_receive {:request, _first}

      assert Assistant.compact(scope, chat) == :ok
      await_runner(chat)

      summary = chat |> Messages.list_messages() |> List.last()
      assert summary.summary
      assert Message.active_content(summary) == "SUMMARY-TEXT"

      assert_receive {:request, compaction}
      assert compaction["tools"] in [nil, []]
      assert List.last(compaction["messages"])["role"] == "user"
      assert mentions?(compaction, "first question")
      refute Enum.any?(compaction["messages"], &(&1["role"] == "tool" or &1["tool_calls"] not in [nil, []]))

      assert Assistant.compact(scope, chat) == {:error, :nothing_to_compact}

      {:ok, _} = Assistant.send_message(scope, chat, "next")
      await_runner(chat)
      assert_receive {:request, next}

      assert [%{"role" => "system", "content" => system} | _] = next["messages"]
      assert system =~ "SUMMARY-TEXT"
      refute mentions?(next, "first question")
      assert Enum.any?(next["messages"], &(&1["role"] == "user" and &1["content"] == "next"))
    end

    test "a failed summary leaves the whole thread in force", %{scope: scope, chat: chat} do
      test = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        send(test, {:request, body})

        if compaction?(body) do
          Plug.Conn.send_resp(conn, 500, "boom")
        else
          conn = Plug.Conn.send_chunked(conn, 200)

          Enum.reduce(content_frames("Reply"), conn, fn frame, conn ->
            {:ok, conn} = Plug.Conn.chunk(conn, frame)
            conn
          end)
        end
      end)

      {:ok, _} = Assistant.send_message(scope, chat, "first question")
      await_runner(chat)
      assert :ok = Assistant.compact(scope, chat)
      await_runner(chat)

      summary = chat |> Messages.list_messages() |> List.last()
      assert summary.summary
      assert Message.active_body(summary).error

      {:ok, _} = Assistant.send_message(scope, chat, "next")
      await_runner(chat)
      assert_receive {:request, %{"messages" => [_ | _]} = first}
      assert_receive {:request, compaction}
      assert compaction?(compaction)
      refute compaction?(first)
      assert_receive {:request, next}

      assert mentions?(next, "first question")
      refute hd(next["messages"])["content"] =~ "Earlier in this conversation"
    end
  end

  describe "model/2" do
    test "the setting wins, else the default model, and a text model is refused",
         %{scope: scope, provider: provider} do
      only = model!(scope, provider)
      assert {:ok, %{id: id}} = Assistant.model(scope, nil)
      assert id == only.id

      chosen = model!(scope, provider)
      assert Assistant.model(scope, nil) == {:error, :ambiguous_model}

      :ok = Settings.put(scope, :user, "assistant.model", chosen.id)
      assert {:ok, %{id: id}} = Assistant.model(scope, nil)
      assert id == chosen.id

      text = model!(scope, provider, %{completion_mode: :text})
      :ok = Settings.put(scope, :user, "assistant.model", text.id)
      assert Assistant.model(scope, nil) == {:error, :text_model}
    end

    test "the thread's model wins over the setting, unless the scope may not run it",
         %{scope: scope, provider: provider} do
      a = model!(scope, provider)
      b = model!(scope, provider)
      :ok = Settings.put(scope, :user, "assistant.model", a.id)

      assert {:ok, %{id: id}} = Assistant.model(scope, b.id)
      assert id == b.id

      other = scope!(%{nickname: "Other"})
      c = model!(other, provider!(other))
      assert {:ok, %{id: id}} = Assistant.model(scope, c.id)
      assert id == a.id
    end

    test "a thread created with a model runs on it", %{scope: scope, provider: provider} do
      picked = model!(scope, provider, %{api_model_id: "picked"})
      model!(scope, provider)

      {:ok, chat} = Assistant.create_chat(scope, %{ai_model_id: picked.id})
      stub(fn _ -> content_frames("ok") end)
      assert {:ok, _} = Assistant.send_message(scope, chat, "Hi")
      await_runner(chat)

      assert_receive {:request, %{"model" => "picked"}}
    end
  end

  test "refuses a role-play chat and another user's thread", %{scope: scope, provider: provider} do
    model!(scope, provider, %{supports_tools: true})
    {:ok, a} = Characters.create_character(scope, %{name: "A"})
    {:ok, b} = Characters.create_character(scope, %{name: "B"})
    {:ok, roleplay} = Chats.create_chat(scope, %{participants: [%{character_id: a.id}, %{character_id: b.id}]})
    assert Assistant.send_message(scope, roleplay, "Hi") == {:error, :not_assistant}

    other = scope!(%{nickname: "Other"})
    {:ok, theirs} = Assistant.create_chat(other)
    assert Assistant.send_message(scope, theirs, "Hi") == {:error, :unauthorized}
  end
end
