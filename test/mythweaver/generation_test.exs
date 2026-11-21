defmodule Mythweaver.GenerationTest do
  # Not `async: true` on purpose: the shared sandbox owner must be reachable from the generation
  # GenServer and the AI task it spawns (`test/support/data_case.ex:42`).
  use Mythweaver.DataCase

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.AI.Model
  alias Mythweaver.AI.StreamEvent
  alias Mythweaver.Attachments
  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Generation
  alias Mythweaver.Injections
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Lore
  alias Mythweaver.Messages
  alias Mythweaver.Messages.MessageBody
  alias Mythweaver.Notifications
  alias Mythweaver.Prompts
  alias Mythweaver.Scripts
  alias Mythweaver.Variables

  # The same trimmed llama.cpp stream `Mythweaver.AITest` uses, chunk per frame.
  @chat_frames [
    ~s(data: {"choices":[{"finish_reason":null,"index":0,"delta":{"role":"assistant","content":null}}],"model":"/models/gemma-4.gguf"}\n\n),
    ~s(data: {"choices":[{"finish_reason":null,"index":0,"delta":{"reasoning_content":"The"}}]}\n\n),
    ~s(data: {"choices":[{"finish_reason":null,"index":0,"delta":{"content":"po"}}]}\n\n),
    ~s(data: {"choices":[{"finish_reason":null,"index":0,"delta":{"content":"ng"}}]}\n\n),
    ~s(data: {"choices":[{"finish_reason":"stop","index":0,"delta":{}}]}\n\n),
    ~s(data: {"choices":[],"usage":{"completion_tokens":31,"prompt_tokens":18,"total_tokens":49}}\n\n),
    "data: [DONE]\n\n"
  ]

  setup context do
    # The AI task is started by the GenServer, which is started by the test process, so the stub has
    # to be visible outside the `$callers` chain of the test pid.
    Req.Test.set_req_test_to_shared(context)

    scope = scope!()
    player = character(scope, "Player")
    bot = character(scope, "Bot")
    chat = chat(scope, [player, bot])

    %{scope: scope, chat: chat, player: player, bot: bot}
  end

  defp stub_chat_stream(frames \\ @chat_frames) do
    Req.Test.stub(Mythweaver.AI, fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)

      Enum.reduce(frames, conn, fn frame, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, frame)
        conn
      end)
    end)
  end

  defp drain_deltas(acc) do
    receive do
      {:body_delta, _payload} = delta -> drain_deltas([delta | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # A response that never arrives, so a cancellation lands mid-flight. `Req.Test`'s plug runs in the
  # requesting process, so chunks it writes before sleeping are not observable. Only the hang matters.
  # It sends `:request_hanging` first: cancelling before the request is out would kill the AI task
  # while it still holds the shared sandbox connection.
  defp hanging_stub do
    test = self()

    Req.Test.stub(Mythweaver.AI, fn conn ->
      send(test, :request_hanging)
      Process.sleep(:infinity)
      conn
    end)
  end

  defp character(scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: "#{name}-#{System.unique_integer([:positive])}"})
    character
  end

  defp chat(scope, [player | _] = characters) do
    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: "chat-#{System.unique_integer([:positive])}",
        participants: Enum.map(characters, &%{character_id: &1.id}),
        player_character_id: player.id
      })

    Chats.get_chat!(chat.id)
  end

  defp model!(scope, name \\ "Gemma 4") do
    {:ok, model} =
      AI.create_model(scope, %{
        name: "#{name}-#{System.unique_integer([:positive])}",
        api_model_id: "gemma-4"
      })

    model
  end

  defp provider!(scope, name \\ "Local") do
    {:ok, provider} =
      AI.create_provider(scope, %{
        name: "#{name}-#{System.unique_integer([:positive])}",
        adapter: :openai_compatible,
        base_url: "http://localhost:8080/v1"
      })

    provider
  end

  defp linked_model!(scope) do
    model = model!(scope)
    {:ok, _link} = AI.link_model(scope, provider!(scope), model)
    model
  end

  defp global_prompt!(scope, content \\ "Be brief.") do
    {:ok, prompt} = Prompts.create_prompt(scope, %{name: "Prompt-#{System.unique_integer([:positive])}"})
    {:ok, block} = Prompts.create_block(scope, %{name: "Sys-#{System.unique_integer([:positive])}", content: content})
    {:ok, _} = Prompts.add_block(scope, prompt, block)
    {:ok, _binding} = Prompts.bind_prompt(scope, prompt, :global)
    prompt
  end

  defp active_body(scope, message_id) do
    Messages.get_message!(scope, message_id).bodies |> Enum.find(& &1.active)
  end

  defp priced_model!(scope) do
    {:ok, model} =
      AI.update_model(scope, linked_model!(scope), %{prompt_cost_per_mtok: "1.00", completion_cost_per_mtok: "2.00"})

    model
  end

  defp generate_and_finish(scope, chat, bot) do
    :ok = Messages.subscribe(chat)
    assert :ok = Generation.generate(scope, chat, bot)
    assert_receive {:message_created, message}
    assert_receive {:generation_finished, _message_id}
    active_body(scope, message.id)
  end

  describe "generate/3" do
    test "streams a reply into a new message and records provenance", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      global_prompt!(scope)
      stub_chat_stream()
      :ok = Messages.subscribe(chat)
      :ok = Notifications.subscribe(scope)

      assert :ok = Generation.generate(scope, chat, bot)

      assert_receive {:message_created, message}
      assert message.author_character_id == bot.id
      assert [%MessageBody{content: "", generating: true}] = message.bodies

      assert_receive {:body_delta, %{reasoning: "The", content: ""}}
      assert_receive {:body_delta, %{content: "po"}}
      assert_receive {:generation_finished, message_id}
      assert message_id == message.id

      # Sent before `:generation_finished`, from the same process.
      assert_received {Notifications, :in_app, notification, %{popup: true, sound: true}}
      assert %{kind: :new_message, message_id: ^message_id, chat_id: chat_id, body: "pong"} = notification
      assert chat_id == chat.id
      assert notification.title == "#{bot.name} replied — #{chat.name}"

      body = active_body(scope, message.id)
      assert body.content == "pong"
      assert body.reasoning == "The"
      assert body.reasoning_redacted == nil
      assert body.finish_reason == "stop"
      assert body.completion_tokens == 31
      assert body.total_tokens == 49
      assert body.generating == false
      assert body.error == nil
      assert body.provider_model_id

      snapshot = Messages.get_prompt_snapshot(scope, body.id)
      assert snapshot.request["body"]["stream"] == true
      assert [_ | _] = snapshot.sections
      assert Enum.all?(snapshot.sections, &is_binary(&1["source"]))
      assert snapshot.lore["budget"]["limit"] == 15_000
      assert snapshot.response["finish_reason"] == "stop"
      assert snapshot.response["usage"]["total_tokens"] == body.total_tokens
    end

    test "a second request queues behind the running reply", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      global_prompt!(scope)
      hanging_stub()
      :ok = Messages.subscribe(chat)

      assert :ok = Generation.generate(scope, chat, bot)
      assert :ok = Generation.generate(scope, chat, bot)
      assert_receive {:message_created, _message}
      assert_receive :request_hanging

      bot_id = bot.id
      assert %{speaking: ^bot_id, queue: [%{character_id: ^bot_id}]} = Generation.status(scope, chat)

      # Stopped inside the test: a server that outlives it writes against a rolled-back sandbox.
      assert Generation.cancel(scope, chat) == :ok

      assert Generation.status(scope, chat) == %{
               chat_id: chat.id,
               speaking: nil,
               queue: [],
               auto?: false,
               paused?: false
             }
    end

    test "respond/1 runs the chat's list strategy in speaking order", %{scope: scope, player: player} do
      linked_model!(scope)
      global_prompt!(scope)
      stub_chat_stream()
      [bot1, bot2] = [character(scope, "Bot1"), character(scope, "Bot2")]
      chat = chat(scope, [player, bot1, bot2])
      {:ok, chat} = Chats.update_chat(scope, chat, %{reply_strategy: :list})
      chat = Chats.get_chat!(chat.id)
      :ok = Messages.subscribe(chat)

      assert :ok = Generation.respond(scope, chat)
      assert_receive {:generation_finished, _}
      assert_receive {:generation_finished, _}

      assert Enum.map(Messages.list_messages(chat), & &1.author_character_id) == [bot1.id, bot2.id]
      Generation.cancel(scope, chat)
    end

    test "auto mode replies without player input until cancelled", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      global_prompt!(scope)
      stub_chat_stream()
      {:ok, chat} = Chats.update_chat(scope, chat, %{auto_mode_delay: 1})
      chat = Chats.get_chat!(chat.id)
      :ok = Messages.subscribe(chat)

      assert :ok = Generation.set_auto(scope, chat, true)
      assert_receive {:message_created, message}, 3_000
      assert message.author_character_id == bot.id
      assert_receive {:generation_finished, _}, 3_000

      assert Generation.cancel(scope, chat) == :ok
      assert %{auto?: false, queue: []} = Generation.status(scope, chat)
    end

    test "generates as the player when asked", %{scope: scope, chat: chat, player: player} do
      linked_model!(scope)
      global_prompt!(scope)
      stub_chat_stream()

      body = generate_and_finish(scope, chat, player)

      assert [message] = Messages.list_messages(chat)
      assert message.author_character_id == player.id
      assert body.content != ""
    end

    test "refuses before writing anything when no model is reachable", %{scope: scope, chat: chat, bot: bot} do
      global_prompt!(scope)

      assert Generation.generate(scope, chat, bot) == {:error, :no_model}
      assert Messages.list_messages(chat) == []
    end

    test "refuses before writing anything when no prompt is bound", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)

      assert Generation.generate(scope, chat, bot) == {:error, :no_prompt}
      assert Messages.list_messages(chat) == []
    end

    test "a backend failing before any text discards the reply and reports the error", %{
      scope: scope,
      chat: chat,
      bot: bot
    } do
      linked_model!(scope)
      global_prompt!(scope)
      Req.Test.stub(Mythweaver.AI, &Plug.Conn.send_resp(&1, 500, "boom"))
      :ok = Messages.subscribe(chat)

      assert :ok = Generation.generate(scope, chat, bot)

      assert_receive {:message_created, message}
      chat_id = chat.id
      assert_receive {:generation_discarded, ^chat_id, "The connection returned HTTP 500: boom"}
      assert_receive {:message_deleted, %{id: id}} when id == message.id
      assert_receive {:generation_finished, _message_id}

      assert Messages.get_message(scope, message.id) == nil
    end

    test "a reasoning-only reply is discarded as having no text", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      global_prompt!(scope)

      stub_chat_stream([
        ~s(data: {"choices":[{"finish_reason":null,"index":0,"delta":{"role":"assistant","content":null}}]}\n\n),
        ~s(data: {"choices":[{"finish_reason":null,"index":0,"delta":{"reasoning_content":"Thinking"}}]}\n\n),
        ~s(data: {"choices":[{"finish_reason":"length","index":0,"delta":{}}]}\n\n),
        "data: [DONE]\n\n"
      ])

      :ok = Messages.subscribe(chat)
      assert :ok = Generation.generate(scope, chat, bot)
      assert_receive {:message_created, message}

      expected = "#{bot.name} replied with no text."
      assert_receive {:generation_discarded, _chat_id, ^expected}
      assert_receive {:generation_finished, _message_id}
      assert Messages.get_message(scope, message.id) == nil
    end

    test "estimates cost from the model's prices when the provider reports none", %{scope: scope, chat: chat, bot: bot} do
      priced_model!(scope)
      global_prompt!(scope)
      stub_chat_stream()

      body = generate_and_finish(scope, chat, bot)

      # 18 prompt tokens at $1 and 31 completion tokens at $2 per Mtok.
      assert Decimal.equal?(body.cost, Decimal.new("0.00008"))
      assert body.cost_estimated == true
      assert is_integer(body.generation_ms) and body.generation_ms >= 0
    end

    test "a provider-reported cost wins", %{scope: scope, chat: chat, bot: bot} do
      priced_model!(scope)
      global_prompt!(scope)

      @chat_frames
      |> List.replace_at(
        5,
        ~s(data: {"choices":[],"usage":{"completion_tokens":31,"prompt_tokens":18,"total_tokens":49,"cost":0.5}}\n\n)
      )
      |> stub_chat_stream()

      body = generate_and_finish(scope, chat, bot)

      assert Decimal.equal?(body.cost, Decimal.new("0.5"))
      assert body.cost_estimated == false
    end

    test "no prices and no reported cost leaves cost unset", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      global_prompt!(scope)
      stub_chat_stream()

      body = generate_and_finish(scope, chat, bot)

      assert body.cost == nil
      assert body.cost_estimated == false
    end

    test "commits the prompt's variable writes and records them on the snapshot", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      global_prompt!(scope, ~s({% setvar mood = "happy" %}Be brief.))
      stub_chat_stream()

      body = generate_and_finish(scope, chat, bot)

      assert Variables.values(chat.id).chat == %{"mood" => "happy"}

      snapshot = Messages.get_prompt_snapshot(scope, body.id)
      assert snapshot.variable_writes == [%{"scope" => "chat", "key" => "mood", "value" => "happy"}]
      refute Jason.encode!(snapshot.request) =~ "setvar"
      assert Jason.encode!(snapshot.request) =~ "Be brief."
    end

    test "a successful reply spends applied injections and records them", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      global_prompt!(scope, "Be brief. {{ anchors.lore.after_author_note }}")
      stub_chat_stream()
      {:ok, once} = Injections.create_injection(scope, chat.id, %{key: "once", content: "Be short.", uses: 1})
      {:ok, forever} = Injections.create_injection(scope, chat.id, %{key: "forever", content: "Stay calm.", order: 200})

      body = generate_and_finish(scope, chat, bot)

      by_id = Map.new(Injections.list_injections(scope, chat.id), &{&1.id, &1})
      assert %{uses: 1, remaining: 0} = by_id[once.id]
      assert %{uses: nil, remaining: nil} = by_id[forever.id]

      snapshot = Messages.get_prompt_snapshot(scope, body.id)

      assert [
               %{"key" => "once", "status" => "applied", "text" => "Be short."},
               %{"key" => "forever", "status" => "applied"}
             ] = snapshot.injections

      assert Jason.encode!(snapshot.request) =~ "Be short.\\nStay calm."
    end

    test "a failed reply keeps its injections armed", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      global_prompt!(scope)
      Req.Test.stub(Mythweaver.AI, &Plug.Conn.send_resp(&1, 500, "boom"))
      {:ok, once} = Injections.create_injection(scope, chat.id, %{key: "once", content: "Be short.", uses: 1})

      :ok = Messages.subscribe(chat)
      assert :ok = Generation.generate(scope, chat, bot)
      assert_receive {:generation_finished, _message_id}

      assert [%{remaining: 1}] = Enum.filter(Injections.list_injections(scope, chat.id), &(&1.id == once.id))
    end

    test "reasoning that echoes a runtime-only site character's description is also stored redacted",
         %{scope: scope, player: player} do
      secret = "Keeper of the fog riddle"
      name = "Sphinx-#{System.unique_integer([:positive])}"

      {:ok, sphinx} =
        Characters.create_character(scope, %{name: name, description: secret, site_visibility: :runtime_only},
          site: true
        )

      chat = chat(scope, [player, sphinx])
      linked_model!(scope)
      global_prompt!(scope, "{{ anchors.character.description }}")
      thought = "I recall: #{secret}."
      # Escaped: chat reasoning renders as markdown, where a bare `[…]` reads as a link.
      label = "\\[Hidden: #{name}'s description\\]"

      stub_chat_stream(
        List.replace_at(
          @chat_frames,
          1,
          ~s(data: {"choices":[{"finish_reason":null,"index":0,"delta":{"reasoning_content":#{Jason.encode!(thought)}}}]}\n\n)
        )
      )

      :ok = Messages.subscribe(chat)
      assert :ok = Generation.generate(scope, chat, sphinx)
      assert_receive {:message_created, message}

      redacted = "I recall: #{label}."
      assert_receive {:body_delta, %{reasoning: ^thought, reasoning_redacted: ^redacted, reasoning_share_redacted: nil}}
      assert_receive {:generation_finished, _message_id}

      body = active_body(scope, message.id)
      assert body.reasoning == thought
      assert body.reasoning_redacted == redacted
      assert body.reasoning_share_redacted == nil
    end

    test "reasoning that echoes a Runtime-only shared character's description is stored share-redacted",
         %{scope: scope, player: player} do
      owner = scope!(%{role: :user})
      secret = "Keeper of the owl's plan"
      name = "Owl-#{System.unique_integer([:positive])}"
      {:ok, owl} = Characters.create_character(owner, %{name: name, description: secret})

      {:ok, share} =
        Mythweaver.Sharing.invite(owner, owl, "@" <> scope.user.handle, role: :subscriber, visibility: :runtime_only)

      {:ok, _share} = Mythweaver.Sharing.accept(scope, share.id)

      chat = chat(scope, [player, owl])
      linked_model!(scope)
      global_prompt!(scope, "{{ anchors.character.description }}")
      thought = "I recall: #{secret}."

      stub_chat_stream(
        List.replace_at(
          @chat_frames,
          1,
          ~s(data: {"choices":[{"finish_reason":null,"index":0,"delta":{"reasoning_content":#{Jason.encode!(thought)}}}]}\n\n)
        )
      )

      :ok = Messages.subscribe(chat)
      assert :ok = Generation.generate(scope, chat, owl)
      assert_receive {:message_created, message}

      redacted = "I recall: \\[Hidden: #{name}'s description\\]."
      assert_receive {:body_delta, %{reasoning: ^thought, reasoning_share_redacted: ^redacted}}
      assert_receive {:generation_finished, _message_id}

      body = active_body(scope, message.id)
      assert body.reasoning == thought
      assert body.reasoning_redacted == redacted
      assert body.reasoning_share_redacted == redacted
    end
  end

  describe "stop strings and own name" do
    # Streams `text` as one content frame and reports each request body to the test.
    defp stub_reply(mode, text) do
      test = self()

      frame =
        case mode do
          :chat -> %{"choices" => [%{"index" => 0, "delta" => %{"content" => text}}]}
          :text -> %{"choices" => [%{"index" => 0, "text" => text}]}
        end

      Req.Test.stub(Mythweaver.AI, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:request_body, Jason.decode!(raw)})
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, "data: #{Jason.encode!(frame)}\n\ndata: [DONE]\n\n")
        conn
      end)
    end

    test "a chat reply ends where it starts the player's line, without sending the name", ctx do
      %{scope: scope, chat: chat, player: player, bot: bot} = ctx
      linked_model!(scope)
      global_prompt!(scope)
      stub_reply(:chat, "She waves.\n#{player.name}: Hello!")

      body = generate_and_finish(scope, chat, bot)

      assert body.content == "She waves."
      assert body.finish_reason == "stop"
      assert_received {:request_body, sent}
      refute Map.has_key?(sent, "stop")
    end

    test "a text model is sent the other speakers' names alongside its own stop sequences", ctx do
      %{scope: scope, chat: chat, player: player, bot: bot} = ctx

      {:ok, model} =
        AI.update_model(scope, linked_model!(scope), %{completion_mode: :text, sampler: %{stop_sequences: ["</s>"]}})

      assert model.completion_mode == :text
      global_prompt!(scope)
      stub_reply(:text, "She waves.")

      generate_and_finish(scope, chat, bot)

      assert_received {:request_body, %{"stop" => ["</s>", stop]}}
      assert stop == "\n#{player.name}:"
    end

    test "the settings turn names off and single-line replies on", ctx do
      %{scope: scope, chat: chat, player: player, bot: bot} = ctx
      linked_model!(scope)
      global_prompt!(scope)
      :ok = Mythweaver.Settings.put(scope, :user, "generation.names_as_stop_strings", false)
      :ok = Mythweaver.Settings.put(scope, :user, "generation.single_line", true)
      stub_reply(:chat, "She waves, then says\n#{player.name}: Hello!")

      assert generate_and_finish(scope, chat, bot).content == "She waves, then says"

      :ok = Mythweaver.Settings.put(scope, :user, "generation.single_line", false)
      stub_reply(:chat, "She waves.\n#{player.name}: Hello!")

      assert generate_and_finish(scope, chat, bot).content == "She waves.\n#{player.name}: Hello!"
    end

    test "a reply loses its speaker's own name at line starts, unless the setting keeps it", ctx do
      %{scope: scope, chat: chat, bot: bot} = ctx
      linked_model!(scope)
      global_prompt!(scope)
      reply = "#{bot.name}: Hello.\n#{bot.name}:  I said, #{bot.name}: hello."
      stub_reply(:chat, reply)

      assert generate_and_finish(scope, chat, bot).content == "Hello.\nI said, #{bot.name}: hello."

      :ok = Mythweaver.Settings.put(scope, :user, "generation.trim_own_name", false)
      stub_reply(:chat, reply)

      assert generate_and_finish(scope, chat, bot).content == reply
    end
  end

  describe "attribution" do
    test "a reply's job belongs to the user who asked for it", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      prompt = global_prompt!(scope)
      stub_chat_stream()

      generate_and_finish(scope, chat, bot)

      user_id = scope.user.id
      assert [%Job{tag: :reply, user_id: ^user_id, prompt_name: name}] = Repo.all(Job)
      assert name == prompt.name
    end

    test "an auto tick's job belongs to the user who turned auto mode on", %{scope: scope, chat: chat} do
      linked_model!(scope)
      global_prompt!(scope)
      stub_chat_stream()
      {:ok, chat} = Chats.update_chat(scope, chat, %{auto_mode_delay: 1})
      chat = Chats.get_chat!(chat.id)
      :ok = Messages.subscribe(chat)

      assert :ok = Generation.set_auto(scope, chat, true)
      assert_receive {:generation_finished, _}, 3_000
      assert Generation.cancel(scope, chat) == :ok

      user_id = scope.user.id
      assert [_ | _] = jobs = Repo.all(Job)
      assert Enum.all?(jobs, &match?(%Job{user_id: ^user_id}, &1))
    end

    test "a scope that may not act on the chat is refused before a conductor starts", %{chat: chat} do
      assert Generation.respond(%Scope{}, chat) == {:error, :unauthorized}
      assert Registry.lookup(Mythweaver.Generation.Registry, chat.id) == []
    end
  end

  describe "cancel/1" do
    test "a reply stopped before any text is discarded and frees the chat", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      global_prompt!(scope)
      hanging_stub()

      :ok = Messages.subscribe(chat)

      assert :ok = Generation.generate(scope, chat, bot)
      assert_receive {:message_created, message}
      assert_receive :request_hanging
      assert Generation.generating?(scope, chat)

      assert Generation.cancel(scope, chat) == :ok
      assert_receive {:generation_finished, _message_id}

      # A stop is the user's own doing: nothing to report.
      refute_received {:generation_discarded, _, _}
      assert Messages.get_message(scope, message.id) == nil
      refute Generation.generating?(scope, chat)
    end

    test "a stopped reply carries an estimated cost and its duration", %{scope: scope, chat: chat, bot: bot} do
      priced_model!(scope)
      global_prompt!(scope)
      test = self()

      # As in the next test: the delta goes to the Server under its stream ref.
      Req.Test.stub(Mythweaver.AI, fn conn ->
        send(test, {:request_hanging, hd(Process.get(:"$callers"))})
        Process.sleep(:infinity)
        conn
      end)

      :ok = Messages.subscribe(chat)

      assert :ok = Generation.generate(scope, chat, bot)
      assert_receive {:message_created, message}
      assert_receive {:request_hanging, server}
      send(server, {:ai_stream, :sys.get_state(server).ref, %StreamEvent.Delta{text: "po"}})
      assert_receive {:body_delta, %{content: "po"}}

      assert Generation.cancel(scope, chat) == :ok
      assert_receive {:generation_finished, _message_id}

      body = active_body(scope, message.id)
      assert body.error == "Stopped."
      assert body.cost_estimated == true
      assert Decimal.compare(body.cost, 0) == :gt
      assert is_integer(body.generation_ms)
    end

    test "a stop keeps streamed text that was never flushed", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      global_prompt!(scope)
      test = self()

      # Chunks written by the plug are not observable before it returns (see `hanging_stub/0`), so the
      # delta is delivered the way the AI task would: to the Server (the task's first `$callers`
      # entry) under the Server's stream ref.
      Req.Test.stub(Mythweaver.AI, fn conn ->
        send(test, {:request_hanging, hd(Process.get(:"$callers"))})
        Process.sleep(:infinity)
        conn
      end)

      :ok = Messages.subscribe(chat)

      assert :ok = Generation.generate(scope, chat, bot)
      assert_receive {:message_created, message}
      assert_receive {:request_hanging, server}

      send(server, {:ai_stream, :sys.get_state(server).ref, %StreamEvent.Delta{text: "po"}})
      assert_receive {:body_delta, %{content: "po"}}
      assert active_body(scope, message.id).content == ""

      assert Generation.cancel(scope, chat) == :ok
      assert_receive {:generation_finished, _message_id}

      assert %MessageBody{content: "po", error: "Stopped.", generating: false} = active_body(scope, message.id)
    end

    test "refuses when nothing is generating", %{scope: scope, chat: chat} do
      assert Generation.cancel(scope, chat) == {:error, :not_generating}
    end
  end

  describe "stop/1" do
    # Two replies from `bot`, the first stopped mid-flight: the second is left queued and paused.
    defp stop_with_one_queued(scope, chat, bot) do
      linked_model!(scope)
      global_prompt!(scope)
      hanging_stub()
      :ok = Messages.subscribe(chat)

      assert :ok = Generation.generate(scope, chat, bot)
      assert :ok = Generation.generate(scope, chat, bot)
      assert_receive {:message_created, message}
      assert_receive :request_hanging

      assert Generation.stop(scope, chat) == :ok
      assert_receive {:generation_finished, _}
      message
    end

    test "stops the reply but keeps the queue, paused", %{scope: scope, chat: chat, bot: bot} do
      :ok = Notifications.subscribe(scope)
      message = stop_with_one_queued(scope, chat, bot)
      refute_received {Notifications, _, _, _}

      bot_id = bot.id

      assert %{speaking: nil, queue: [%{character_id: ^bot_id}], auto?: false, paused?: true} =
               Generation.status(scope, chat)

      refute_receive {:message_created, _}, 200
      assert Messages.get_message(scope, message.id) == nil

      assert Generation.cancel(scope, chat) == :ok
    end

    test "resume/1 runs the paused queue", %{scope: scope, chat: chat, bot: bot} do
      stop_with_one_queued(scope, chat, bot)

      assert :ok = Generation.resume(scope, chat)
      assert_receive {:message_created, _}
      assert_receive :request_hanging

      bot_id = bot.id
      assert %{speaking: ^bot_id, queue: [], paused?: false} = Generation.status(scope, chat)

      assert Generation.cancel(scope, chat) == :ok
    end

    test "a new request resumes a paused queue behind the kept order", %{scope: scope, chat: chat, bot: bot} do
      stop_with_one_queued(scope, chat, bot)

      assert :ok = Generation.generate(scope, chat, bot)
      assert_receive {:message_created, _}
      assert_receive :request_hanging

      bot_id = bot.id

      assert %{speaking: ^bot_id, queue: [%{character_id: ^bot_id}], paused?: false} =
               Generation.status(scope, chat)

      assert Generation.cancel(scope, chat) == :ok
    end

    test "clearing a paused queue with auto mode on schedules the next auto turn", %{scope: scope, chat: chat, bot: bot} do
      stop_with_one_queued(scope, chat, bot)

      assert :ok = Generation.set_auto(scope, chat, true)
      assert :ok = Generation.clear_queue(scope, chat)

      [{conductor, _value}] = Registry.lookup(Mythweaver.Generation.Registry, chat.id)
      assert %{auto?: true, timer: timer} = :sys.get_state(conductor)
      assert timer != nil

      assert Generation.cancel(scope, chat) == :ok
    end

    test "refuses when nothing is speaking", %{scope: scope, chat: chat} do
      assert Generation.stop(scope, chat) == {:error, :not_generating}
    end
  end

  describe "regenerate/3" do
    test "streams into a new active swipe", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      global_prompt!(scope)
      stub_chat_stream()

      {:ok, original} = Messages.send_message(scope, chat, bot.id, "first take")
      [first_body] = original.bodies

      :ok = Messages.subscribe(chat)
      :ok = Notifications.subscribe(scope)

      assert :ok = Generation.regenerate(scope, chat, original)
      assert_receive {:generation_finished, _message_id}

      original_id = original.id
      assert_received {Notifications, :in_app, %{kind: :regenerate, message_id: ^original_id} = notification, _}
      assert notification.title == "New swipe from #{bot.name} — #{chat.name}"

      reloaded = Messages.get_message!(scope, original.id)
      assert length(reloaded.bodies) == 2
      assert Enum.find(reloaded.bodies, &(&1.id == first_body.id)).active == false

      body = Enum.find(reloaded.bodies, & &1.active)
      assert body.content == "pong"
      assert body.generating == false
    end

    test "a failed swipe is dropped and the one it replaced is active again", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      global_prompt!(scope)

      {:ok, original} = Messages.send_message(scope, chat, bot.id, "first take")
      {:ok, second} = Messages.add_edited_body(scope, original, %{content: "second take"})
      [first_body, _second_body] = second.bodies
      {:ok, _} = Messages.set_active_body(scope, first_body)
      original = Messages.get_message!(scope, original.id)

      Req.Test.stub(Mythweaver.AI, &Plug.Conn.send_resp(&1, 500, "boom"))
      :ok = Messages.subscribe(chat)

      assert :ok = Generation.regenerate(scope, chat, original)
      assert_receive {:generation_finished, _message_id}, 1_000
      assert_received {:generation_discarded, _chat_id, "The connection returned HTTP 500: boom"}

      # The earlier, not the newest, swipe: the one that was showing.
      reloaded = Messages.get_message!(scope, original.id)
      assert length(reloaded.bodies) == 2
      assert %{id: id, content: "first take"} = Enum.find(reloaded.bodies, & &1.active)
      assert id == first_body.id
    end

    test "the prompt leaves out the reply being replaced", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      prompt = global_prompt!(scope)

      {:ok, history} =
        Prompts.create_block(scope, %{name: "History-#{System.unique_integer([:positive])}", kind: :chat_history})

      {:ok, _} = Prompts.add_block(scope, prompt, history)
      test = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:body, Jason.decode!(raw)})
        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce(@chat_frames, conn, fn frame, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, frame)
          conn
        end)
      end)

      {:ok, _} = Messages.send_message(scope, chat, bot.id, "EARLIER-REPLY")
      {:ok, original} = Messages.send_message(scope, chat, bot.id, "ORIGINAL-REPLY")
      :ok = Messages.subscribe(chat)

      assert :ok = Generation.regenerate(scope, chat, original)
      assert_receive {:body, body}
      assert_receive {:generation_finished, _message_id}

      assert inspect(body["messages"]) =~ "EARLIER-REPLY"
      refute inspect(body["messages"]) =~ "ORIGINAL-REPLY"
    end

    test "refuses an earlier message and leaves its swipes alone", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      global_prompt!(scope)

      {:ok, earlier} = Messages.send_message(scope, chat, bot.id, "one")
      {:ok, _later} = Messages.send_message(scope, chat, bot.id, "two")

      assert Generation.regenerate(scope, chat, earlier) == {:error, :not_last}
      assert [%{content: "one"}] = Messages.get_message!(scope, earlier.id).bodies
    end

    test "refuses a message with no character author", %{scope: scope, chat: chat} do
      linked_model!(scope)
      global_prompt!(scope)

      {:ok, message} =
        Messages.create_message(chat, %{
          author_is_character: false,
          author_name: "Narrator",
          bodies: [%{content: "A dark night."}]
        })

      assert Generation.regenerate(scope, chat, message) == {:error, :not_character_authored}
    end
  end

  describe "swipes per generation" do
    defp finish_n(n) do
      for _ <- 1..n, do: assert_receive({:generation_finished, _}, 2000)
      refute_receive {:generation_finished, _}, 200
    end

    test "one reply fans out into the set number of swipes", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      global_prompt!(scope)
      stub_chat_stream()
      :ok = Mythweaver.Settings.put(scope, :user, "generation.swipes_per_generation", 3)
      :ok = Messages.subscribe(chat)
      :ok = Notifications.subscribe(scope)

      assert :ok = Generation.generate(scope, chat, bot)
      assert_receive {:message_created, message}
      finish_n(3)

      # One notification for the whole batch, from its last swipe.
      message_id = message.id
      assert_received {Notifications, :in_app, %{kind: :new_message, message_id: ^message_id}, _}
      refute_received {Notifications, _, _, _}

      bodies = Messages.get_message!(scope, message.id).bodies
      assert length(bodies) == 3
      assert Enum.all?(bodies, &(&1.content == "pong"))
      assert %{speaking: nil, queue: []} = Generation.status(scope, chat)
    end

    test "a regenerate adds the set number of swipes", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      global_prompt!(scope)
      stub_chat_stream()
      :ok = Mythweaver.Settings.put(scope, :user, "generation.swipes_per_generation", 2)
      {:ok, original} = Messages.send_message(scope, chat, bot.id, "first take")
      :ok = Messages.subscribe(chat)
      :ok = Notifications.subscribe(scope)

      assert :ok = Generation.regenerate(scope, chat, original)
      finish_n(2)
      assert_received {Notifications, :in_app, %{kind: :regenerate}, _}
      refute_received {Notifications, _, _, _}

      assert length(Messages.get_message!(scope, original.id).bodies) == 3
    end

    test "a script-started regenerate makes one swipe", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      global_prompt!(scope)
      stub_chat_stream()
      :ok = Mythweaver.Settings.put(scope, :user, "generation.swipes_per_generation", 3)
      {:ok, original} = Messages.send_message(scope, chat, bot.id, "first take")
      :ok = Messages.subscribe(chat)

      assert :ok = Generation.regenerate(scope, chat, original, script: true)
      finish_n(1)

      assert length(Messages.get_message!(scope, original.id).bodies) == 2
    end

    test "stopping a swipe drops the rest of its batch", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      global_prompt!(scope)
      :ok = Mythweaver.Settings.put(scope, :user, "generation.swipes_per_generation", 3)
      counter = start_supervised!({Agent, fn -> 0 end})
      test = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        if Agent.get_and_update(counter, &{&1, &1 + 1}) == 0 do
          conn = Plug.Conn.send_chunked(conn, 200)

          Enum.reduce(@chat_frames, conn, fn frame, conn ->
            {:ok, conn} = Plug.Conn.chunk(conn, frame)
            conn
          end)
        else
          send(test, :request_hanging)
          Process.sleep(:infinity)
          conn
        end
      end)

      :ok = Messages.subscribe(chat)
      :ok = Notifications.subscribe(scope)
      assert :ok = Generation.generate(scope, chat, bot)
      assert_receive {:generation_finished, _}
      assert_receive :request_hanging

      assert Generation.stop(scope, chat) == :ok
      assert_receive {:generation_finished, _}
      assert %{queue: [], paused?: false} = Generation.status(scope, chat)
      # The batch's first reply leaves notifying to its last swipe, which never ran.
      refute_received {Notifications, _, _, _}
    end
  end

  describe "continue/3" do
    test "streams the original text plus the continuation into a new swipe", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      global_prompt!(scope)
      stub_chat_stream()

      {:ok, original} = Messages.send_message(scope, chat, bot.id, "first take")
      [first_body] = original.bodies

      :ok = Messages.subscribe(chat)
      :ok = Notifications.subscribe(scope)

      assert :ok = Generation.continue(scope, chat, original)
      assert_receive {:generation_finished, _message_id}

      original_id = original.id
      assert_received {Notifications, :in_app, %{kind: :continue, message_id: ^original_id} = notification, _}
      assert notification.title == "#{bot.name} continued — #{chat.name}"
      assert notification.body == "first take pong"

      reloaded = Messages.get_message!(scope, original.id)
      assert length(reloaded.bodies) == 2

      untouched = Enum.find(reloaded.bodies, &(&1.id == first_body.id))
      assert %{active: false, content: "first take"} = untouched

      assert %{content: "first take pong", reasoning: "The", generating: false} =
               Enum.find(reloaded.bodies, & &1.active)
    end

    test "continues the player's own message as the player", %{scope: scope, chat: chat, player: player} do
      linked_model!(scope)
      global_prompt!(scope)
      stub_chat_stream()

      {:ok, message} = Messages.send_message(scope, chat, player.id, "I draw")
      :ok = Messages.subscribe(chat)

      assert :ok = Generation.continue(scope, chat, message)
      assert_receive {:generation_finished, _message_id}

      assert active_body(scope, message.id).content == "I draw pong"
    end

    test "a continuation that restarts the message's last line keeps only the new part, even mid-stream",
         %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      global_prompt!(scope)

      ["Katy looked at the luxury car ", "approvingly, noting its", " stylish lines."]
      |> Enum.map(
        &("data: " <> Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => %{"content" => &1}}]}) <> "\n\n")
      )
      |> Kernel.++([~s(data: {"choices":[{"finish_reason":"stop","index":0,"delta":{}}]}\n\n), "data: [DONE]\n\n"])
      |> stub_chat_stream()

      partial = "Katy looked at the luxury car approvingly, noting its"
      {:ok, original} = Messages.send_message(scope, chat, bot.id, partial)
      :ok = Messages.subscribe(chat)

      assert :ok = Generation.continue(scope, chat, original)
      assert_receive {:generation_finished, _message_id}

      assert active_body(scope, original.id).content == partial <> " stylish lines."

      for {:body_delta, %{content: content}} <- drain_deltas([]) do
        refute content =~ "its Katy"
      end
    end

    test "a prefill model ends the request on the assistant text and joins raw", %{scope: scope, chat: chat, bot: bot} do
      model = linked_model!(scope)
      {:ok, _} = AI.update_model(scope, model, %{continue_prefill: true})
      global_prompt!(scope)
      test = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:body, Jason.decode!(raw)})
        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce(@chat_frames, conn, fn frame, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, frame)
          conn
        end)
      end)

      {:ok, original} = Messages.send_message(scope, chat, bot.id, "first take")
      :ok = Messages.subscribe(chat)

      assert :ok = Generation.continue(scope, chat, original)
      assert_receive {:body, %{"messages" => wire}}
      assert_receive {:generation_finished, _message_id}

      assert List.last(wire) == %{"role" => "assistant", "content" => "first take"}
      assert active_body(scope, original.id).content == "first takepong"
    end

    test "a stop before any new text discards the swipe and keeps the original", %{
      scope: scope,
      chat: chat,
      bot: bot
    } do
      linked_model!(scope)
      global_prompt!(scope)
      hanging_stub()

      {:ok, original} = Messages.send_message(scope, chat, bot.id, "first take")
      :ok = Messages.subscribe(chat)

      assert :ok = Generation.continue(scope, chat, original)
      assert_receive :request_hanging

      assert Generation.stop(scope, chat) == :ok
      assert_receive {:generation_finished, _message_id}

      assert [%{content: "first take", active: true}] = Messages.get_message!(scope, original.id).bodies
    end

    test "refuses an earlier message", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      global_prompt!(scope)

      {:ok, earlier} = Messages.send_message(scope, chat, bot.id, "one")
      {:ok, _later} = Messages.send_message(scope, chat, bot.id, "two")

      assert Generation.continue(scope, chat, earlier) == {:error, :not_last}
    end

    test "refuses a message with no character author", %{scope: scope, chat: chat} do
      linked_model!(scope)
      global_prompt!(scope)

      {:ok, message} =
        Messages.create_message(chat, %{
          author_is_character: false,
          author_name: "Narrator",
          bodies: [%{content: "A dark night."}]
        })

      assert Generation.continue(scope, chat, message) == {:error, :not_character_authored}
    end
  end

  describe "unread activity" do
    setup %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      global_prompt!(scope)
      {:ok, original} = Messages.send_message(scope, chat, bot.id, "first take")
      :ok = Messages.mark_read(scope, chat)
      :ok = Messages.subscribe(chat)
      %{original: original}
    end

    test "a regenerated swipe's tokens make a read chat unread", %{scope: scope, chat: chat, original: original} do
      stub_chat_stream()

      assert :ok = Generation.regenerate(scope, chat, original)
      assert_receive {:generation_finished, _message_id}

      assert Map.has_key?(Messages.unread_chats(scope), chat.id)
    end

    test "a swipe stopped before any token leaves a read chat read", %{scope: scope, chat: chat, original: original} do
      hanging_stub()

      assert :ok = Generation.regenerate(scope, chat, original)
      assert_receive :request_hanging
      assert Generation.stop(scope, chat) == :ok
      assert_receive {:generation_finished, _message_id}

      refute Map.has_key?(Messages.unread_chats(scope), chat.id)
    end
  end

  describe "guided generations" do
    defp guided_prompt!(scope), do: global_prompt!(scope, "Be brief. {{ anchors.guide.text }}")

    test "a guided reply stores its guide and sends it", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      guided_prompt!(scope)
      stub_chat_stream()
      :ok = Messages.subscribe(chat)

      assert :ok = Generation.generate(scope, chat, bot, guide: "Tom sits down.")
      assert_receive {:message_created, message}
      assert_receive {:generation_finished, _}

      body = active_body(scope, message.id)
      assert body.guide == "Tom sits down."
      assert Jason.encode!(Messages.get_prompt_snapshot(scope, body.id).request) =~ "Tom sits down."
    end

    test "a guided reply as the player is written by the player", %{scope: scope, chat: chat, player: player} do
      linked_model!(scope)
      guided_prompt!(scope)
      stub_chat_stream()
      :ok = Messages.subscribe(chat)

      assert :ok = Generation.generate(scope, chat, player, guide: "Paige drives off.")
      assert_receive {:message_created, message}
      assert_receive {:generation_finished, _}

      assert message.author_character_id == player.id
      assert active_body(scope, message.id).guide == "Paige drives off."
    end

    test "a guided regenerate guides only its own swipe", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      guided_prompt!(scope)
      stub_chat_stream()
      {:ok, message} = Messages.send_message(scope, chat, bot.id, "first take")
      :ok = Messages.subscribe(chat)

      assert :ok = Generation.regenerate(scope, chat, message, guide: "Shorter.")
      assert_receive {:generation_finished, _}
      assert_receive {:turn_state, %{speaking: nil}}
      assert %{origin: :regenerate, guide: "Shorter."} = active_body(scope, message.id)

      assert :ok = Generation.regenerate(scope, chat, Messages.get_message!(scope, message.id))
      assert_receive {:generation_finished, _}
      assert %{origin: :regenerate, guide: nil} = active_body(scope, message.id)
    end

    test "a guided continue stores its guide", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      guided_prompt!(scope)
      stub_chat_stream()
      {:ok, message} = Messages.send_message(scope, chat, bot.id, "first take")
      :ok = Messages.subscribe(chat)

      assert :ok = Generation.continue(scope, chat, message, guide: "Then rain.")
      assert_receive {:generation_finished, _}
      assert %{origin: :continue, guide: "Then rain."} = active_body(scope, message.id)
    end

    test "a guide is refused when no block reads it; a blank one is no guide", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      global_prompt!(scope)
      stub_chat_stream()
      :ok = Messages.subscribe(chat)

      assert Generation.generate(scope, chat, bot, guide: "x") == {:error, :no_guide_block}

      assert :ok = Generation.generate(scope, chat, bot, guide: "  ")
      assert_receive {:message_created, message}
      assert_receive {:generation_finished, _}
      assert active_body(scope, message.id).guide == nil
    end
  end

  describe "refine/3" do
    defp refine_prompt!(scope) do
      prompt = global_prompt!(scope, "Be brief.")

      {:ok, refine} =
        Prompts.create_block(scope, %{
          name: "Refine-#{System.unique_integer([:positive])}",
          content:
            "{% if anchors.refine %}DO: {{ anchors.refine.instructions }} TEXT: {{ anchors.refine.text }}{% endif %}"
        })

      {:ok, history} =
        Prompts.create_block(scope, %{name: "History-#{System.unique_integer([:positive])}", kind: :chat_history})

      {:ok, _} = Prompts.add_block(scope, prompt, history)
      {:ok, _} = Prompts.add_block(scope, prompt, refine)
      prompt
    end

    test "rewrites the last reply from its text and the instructions, out of history", %{
      scope: scope,
      chat: chat,
      bot: bot
    } do
      linked_model!(scope)
      refine_prompt!(scope)
      test = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:body, Jason.decode!(raw)})
        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce(@chat_frames, conn, fn frame, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, frame)
          conn
        end)
      end)

      {:ok, _} = Messages.send_message(scope, chat, bot.id, "EARLIER-REPLY")
      {:ok, original} = Messages.send_message(scope, chat, bot.id, "ORIGINAL-REPLY")
      source = active_body(scope, original.id)
      :ok = Messages.subscribe(chat)

      assert :ok = Generation.refine(scope, chat, original, "Make it rhyme.")
      assert_receive {:body, %{"messages" => wire}}
      assert_receive {:generation_finished, _message_id}

      contents = Enum.map(wire, & &1["content"])
      assert Enum.any?(contents, &(&1 =~ "EARLIER-REPLY"))
      assert Enum.any?(contents, &(&1 =~ "DO: Make it rhyme. TEXT: ORIGINAL-REPLY"))
      refute "ORIGINAL-REPLY" in contents

      body = active_body(scope, original.id)
      assert %{origin: :refine, guide: "Make it rhyme.", content: "pong"} = body
      assert body.source_body_id == source.id
      assert [%{tag: :refine}] = Mythweaver.Repo.all(Job)
    end

    test "refuses a prompt with no block reading anchors.refine", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      global_prompt!(scope)
      {:ok, message} = Messages.send_message(scope, chat, bot.id, "first take")

      assert Generation.refine(scope, chat, message, "Shorter.") == {:error, :no_refine_block}
    end

    test "refuses blank instructions", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      refine_prompt!(scope)
      {:ok, message} = Messages.send_message(scope, chat, bot.id, "first take")

      assert Generation.refine(scope, chat, message, "  ") == {:error, :no_instructions}
      assert Generation.refine(scope, chat, message, nil) == {:error, :no_instructions}
    end

    test "refuses an earlier message", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      refine_prompt!(scope)
      {:ok, earlier} = Messages.send_message(scope, chat, bot.id, "one")
      {:ok, _later} = Messages.send_message(scope, chat, bot.id, "two")

      assert Generation.refine(scope, chat, earlier, "Shorter.") == {:error, :not_last}
    end
  end

  describe "model_for/2" do
    test "the participant's model wins over the chat's", %{scope: scope, chat: chat, bot: bot} do
      chat_model = linked_model!(scope)
      participant_model = model!(scope, "Participant")

      {:ok, _chat} = Chats.update_chat(scope, chat, %{"ai_model_id" => chat_model.id})

      participant = Enum.find(chat.participants, &(&1.character_id == bot.id))
      {:ok, _participant} = Chats.update_participant(scope, participant, %{"ai_model_id" => participant_model.id})

      assert {:ok, model} = Generation.model_for(scope, Chats.get_chat!(chat.id), bot)
      assert model.id == participant_model.id
    end

    test "the chat's model wins over the app default", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      chat_model = model!(scope, "Chat")

      {:ok, _chat} = Chats.update_chat(scope, chat, %{"ai_model_id" => chat_model.id})

      assert {:ok, model} = Generation.model_for(scope, Chats.get_chat!(chat.id), bot)
      assert model.id == chat_model.id
    end

    test "falls through to the sole reachable model", %{scope: scope, chat: chat, bot: bot} do
      default = linked_model!(scope)

      assert {:ok, model} = Generation.model_for(scope, chat, bot)
      assert model.id == default.id
    end

    test "a blank participant override falls back to the chat", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      chat_model = model!(scope, "Chat")
      participant_model = model!(scope, "Participant")

      {:ok, _chat} = Chats.update_chat(scope, chat, %{"ai_model_id" => chat_model.id})
      participant = Enum.find(chat.participants, &(&1.character_id == bot.id))
      {:ok, _} = Chats.update_participant(scope, participant, %{"ai_model_id" => participant_model.id})

      participant = Chats.get_participant(participant.id)
      {:ok, _} = Chats.update_participant(scope, participant, %{"ai_model_id" => ""})

      assert {:ok, model} = Generation.model_for(scope, Chats.get_chat!(chat.id), bot)
      assert model.id == chat_model.id
    end
  end

  describe "scripts" do
    test "an ai_generation script rewrites the stored reply, not the snapshot", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      global_prompt!(scope)
      stub_chat_stream()

      {:ok, _} =
        Scripts.create_script(scope, %{name: "Upper", trigger: :ai_generation, body: "return event.text:upper()"})

      body = generate_and_finish(scope, chat, bot)

      assert body.content == "PONG"
      assert Messages.get_prompt_snapshot(scope, body.id).response["text"] == "pong"
    end

    test "a lore_activated script sees the activated books", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      global_prompt!(scope)
      stub_chat_stream()
      {:ok, book} = Lore.create_book(scope, %{name: "Book-#{System.unique_integer([:positive])}", global: true})
      {:ok, _} = Lore.create_entry(scope, %{name: "Always", content: "Lore.", activation: :constant}, [book.id])

      {:ok, _} =
        Scripts.create_script(scope, %{
          name: "Seen",
          trigger: :lore_activated,
          body: ~s|assert(mw.lore.update_book(event.books[1].id, {description = "seen"}))|
        })

      generate_and_finish(scope, chat, bot)

      assert Lore.get_book!(book.id).description == "seen"
    end

    test "an ai_generation script cannot start another generation", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      global_prompt!(scope)
      stub_chat_stream()

      {:ok, _} =
        Scripts.create_script(scope, %{
          name: "Chain",
          trigger: :ai_generation,
          body: ~s|local _, reason = mw.generation.generate(event.character_id) return reason|
        })

      assert generate_and_finish(scope, chat, bot).content == "not_allowed"
      refute_receive {:message_created, _}, 200
      assert [_] = Mythweaver.Repo.all(Job)
    end

    test "a user_message script's generation is marked script-triggered", %{scope: scope, chat: chat, bot: bot} do
      linked_model!(scope)
      global_prompt!(scope)
      stub_chat_stream()

      {:ok, _} =
        Scripts.create_script(scope, %{
          name: "Ask",
          trigger: :user_message,
          body: ~s|assert(mw.generation.generate("#{bot.id}"))|
        })

      {:ok, _} =
        Scripts.create_script(scope, %{
          name: "Mark",
          trigger: :ai_generation,
          body: "return tostring(event.script_triggered)"
        })

      :ok = Messages.subscribe(chat)
      assert %{errors: []} = Scripts.run(scope, :user_message, chat, %{"text" => "hi"})
      assert_receive {:message_created, message}
      assert_receive {:generation_finished, _}

      assert active_body(scope, message.id).content == "true"
      assert [%{label: label}] = Mythweaver.Repo.all(Job)
      assert label =~ "(script)"
    end
  end

  describe "images" do
    setup %{scope: scope, chat: chat} do
      provider = provider!(scope)

      {:ok, joy} =
        AI.create_model(scope, %{
          name: "JoyCaption-#{System.unique_integer([:positive])}",
          api_model_id: "joycaption",
          supports_images: true
        })

      {:ok, skyfall} =
        AI.create_model(scope, %{
          name: "Skyfall-#{System.unique_integer([:positive])}",
          api_model_id: "skyfall",
          caption_model_id: joy.id
        })

      {:ok, _} = AI.link_model(scope, provider, joy)
      {:ok, _} = AI.link_model(scope, provider, skyfall)
      {:ok, _} = Chats.update_chat(scope, chat, %{"ai_model_id" => skyfall.id})

      prompt = global_prompt!(scope)

      {:ok, history} =
        Prompts.create_block(scope, %{name: "History-#{System.unique_integer([:positive])}", kind: :chat_history})

      {:ok, _} = Prompts.add_block(scope, prompt, history)

      {:ok, fox} = Attachments.store_binary(png())
      %{chat: Chats.get_chat!(chat.id), joy: joy, skyfall: skyfall, fox: fox, prompt: prompt}
    end

    # JoyCaption's request blocks until the test sends `:release`; every other model's reports its body.
    defp stub_models do
      test = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        text =
          case body["model"] do
            "joycaption" ->
              send(test, {:caption_request, self()})
              assert_receive :release, 5_000
              "A red fox"

            _ ->
              send(test, {:reply_body, body})
              "pong"
          end

        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce(content_frames(text), conn, fn frame, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, frame)
          conn
        end)
      end)
    end

    defp content_frames(text) do
      [
        "data: " <> Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => %{"content" => text}}]}) <> "\n\n",
        ~s(data: {"choices":[{"finish_reason":"stop","index":0,"delta":{}}]}\n\n),
        "data: [DONE]\n\n"
      ]
    end

    defp guide_block!(scope, prompt) do
      {:ok, block} =
        Prompts.create_block(scope, %{
          name: "Guide-#{System.unique_integer([:positive])}",
          content: "Guide: {{ anchors.guide.text }}"
        })

      {:ok, _} = Prompts.add_block(scope, prompt, block)
    end

    test "a guided regenerate sends the composer's images with the guide and links them to its swipe",
         %{scope: scope} = ctx do
      {:ok, _} = AI.update_model(scope, ctx.skyfall, %{supports_images: true, caption_model_id: nil})
      guide_block!(scope, ctx.prompt)
      chat = Chats.get_chat!(ctx.chat.id)
      stub_models()
      {:ok, reply} = Messages.send_message(scope, chat, ctx.bot.id, "first take")
      :ok = Messages.subscribe(chat)

      assert :ok = Generation.regenerate(scope, chat, reply, guide_attachments: [ctx.fox])
      assert_receive {:reply_body, body}, 2_000
      assert_receive {:generation_finished, _}, 2_000

      last_user = body["messages"] |> Enum.filter(&(&1["role"] == "user")) |> List.last()
      assert Enum.any?(last_user["content"], &(&1["type"] == "image_url"))

      fox_id = ctx.fox.id

      assert %{origin: :regenerate, guide: nil, guide_attachments: [%Attachment{id: ^fox_id}]} =
               active_body(scope, reply.id)
    end

    test "a model that cannot see images waits for a guide image's caption", %{scope: scope} = ctx do
      guide_block!(scope, ctx.prompt)
      stub_models()
      :ok = Messages.subscribe(ctx.chat)

      assert :ok = Generation.generate(scope, ctx.chat, ctx.bot, guide: "Show it", guide_attachments: [ctx.fox])
      assert_receive {:caption_request, captioner}
      refute_receive {:reply_body, _}, 200

      send(captioner, :release)
      assert_receive {:reply_body, body}, 2_000
      assert_receive {:generation_finished, _}, 2_000
      assert inspect(body["messages"]) =~ "Guide: Show it\\n[Image: A red fox]"
    end

    test "an image-only guide on a prompt without a guide block is refused", %{scope: scope} = ctx do
      assert Generation.generate(scope, ctx.chat, ctx.bot, guide_attachments: [ctx.fox]) == {:error, :no_guide_block}
    end

    test "a model that cannot see images waits for the caption, then reads it", %{scope: scope} = ctx do
      stub_models()
      :ok = Messages.subscribe(ctx.chat)
      {:ok, _} = Messages.send_message(scope, ctx.chat, ctx.player.id, "Look", attachments: [ctx.fox])

      assert :ok = Generation.generate(scope, ctx.chat, ctx.bot)
      assert_receive {:caption_request, captioner}
      refute_receive {:reply_body, _}, 200

      send(captioner, :release)
      assert_receive {:reply_body, body}, 2_000
      assert_receive {:generation_finished, _}, 2_000

      assert inspect(body["messages"]) =~ "Look\\n[Image: A red fox]"
      fox = Repo.get!(Attachment, ctx.fox.id)
      assert fox.caption_status == :done
      assert fox.described_by_model_id == ctx.joy.id
    end

    test "a reply stops waiting when an awaited image is deleted", %{scope: scope} = ctx do
      stub_models()
      :ok = Messages.subscribe(ctx.chat)
      {:ok, _} = Messages.send_message(scope, ctx.chat, ctx.player.id, "Look", attachments: [ctx.fox])

      assert :ok = Generation.generate(scope, ctx.chat, ctx.bot)
      assert_receive {:caption_request, captioner}
      refute_receive {:reply_body, _}, 200

      # The reply starts while the caption still runs; its request waits for the provider's slot.
      Repo.delete!(Repo.get!(Attachment, ctx.fox.id))
      bot_id = ctx.bot.id
      assert_receive {:message_created, %{author_character_id: ^bot_id}}, 2_000

      send(captioner, :release)
      assert_receive {:reply_body, body}, 2_000
      assert_receive {:generation_finished, _}, 2_000
      refute inspect(body["messages"]) =~ "[Image"
    end

    test "a vision model gets the image inline, and the snapshot keeps no bytes", %{scope: scope} = ctx do
      {:ok, _} = AI.update_model(scope, ctx.skyfall, %{supports_images: true, caption_model_id: nil})
      chat = Chats.get_chat!(ctx.chat.id)
      stub_models()
      :ok = Messages.subscribe(chat)
      {:ok, _} = Messages.send_message(scope, chat, ctx.player.id, "Look", attachments: [ctx.fox])

      assert :ok = Generation.generate(scope, chat, ctx.bot)
      assert_receive {:reply_body, body}, 2_000
      assert_receive {:message_created, %{author_character_id: bot_id} = reply} when bot_id == ctx.bot.id
      assert_receive {:generation_finished, _}, 2_000
      refute_received {:caption_request, _}

      encoded = Base.encode64(png())

      assert [%{"type" => "text"}, %{"type" => "image_url", "image_url" => %{"url" => url}}] =
               Enum.find_value(body["messages"], fn m -> is_list(m["content"]) && m["content"] end)

      assert url == "data:image/png;base64," <> encoded

      snapshot = Messages.get_prompt_snapshot(scope, active_body(scope, reply.id).id)
      request = inspect(snapshot.request)
      assert request =~ "bytes omitted"
      refute request =~ encoded

      # The inline image is counted in its history section, as an estimate (a 1×1 image costs 85).
      fox_id = ctx.fox.id

      assert %{"images" => 1, "image_tokens" => 85, "estimated" => true, "inline_images" => [%{"id" => ^fox_id}]} =
               Enum.find(snapshot.sections, &(&1["source"] == "chat_history"))
    end

    test "past its inline limit, a vision model reads older images as text and describes them once",
         %{scope: scope} = ctx do
      {:ok, skyfall} =
        AI.update_model(scope, ctx.skyfall, %{supports_images: true, caption_model_id: nil, inline_image_limit: 1})

      chat = Chats.get_chat!(ctx.chat.id)
      stub_models()
      :ok = Messages.subscribe(chat)
      :ok = Mythweaver.Jobs.subscribe(scope)
      {:ok, owl} = Attachments.store_binary(png())
      {:ok, _} = Messages.send_message(scope, chat, ctx.player.id, "First", attachments: [ctx.fox])
      {:ok, _} = Messages.send_message(scope, chat, ctx.player.id, "Second", attachments: [owl])

      assert :ok = Generation.generate(scope, chat, ctx.bot)
      assert_receive {:generation_finished, _}, 2_000
      assert_receive {:job_changed, %{tag: :caption, status: :completed}}, 2_000

      # Two requests went to the vision model: the reply, and the background caption of the older image.
      assert_received {:reply_body, first}
      assert_received {:reply_body, second}
      reply = Enum.find([first, second], &(inspect(&1["messages"]) =~ "Second"))

      # The reply carried only the newest image inline; the older one, undescribed then, as `[Image]`.
      assert length(Regex.scan(~r/"type" => "image_url"/, inspect(reply["messages"]))) == 1
      assert inspect(reply["messages"]) =~ "First\\n[Image]"
      skyfall_id = skyfall.id
      assert %Attachment{caption_status: :done, described_by_model_id: ^skyfall_id} = Repo.reload!(ctx.fox)
      assert %Attachment{caption_status: :none} = Repo.reload!(owl)
    end

    test "a model that reads files gets a PDF as a file part, and the snapshot keeps no bytes",
         %{scope: scope} = ctx do
      {:ok, _} = AI.update_model(scope, ctx.skyfall, %{supports_files: true})
      chat = Chats.get_chat!(ctx.chat.id)
      stub_models()
      :ok = Messages.subscribe(chat)
      pdf = pdf_with_text("Hello fox")
      {:ok, doc} = Attachments.store_binary(pdf, filename: "fox.pdf", kinds: Attachment.kinds())
      {:ok, _} = Messages.send_message(scope, chat, ctx.player.id, "Read", attachments: [doc])

      assert :ok = Generation.generate(scope, chat, ctx.bot)
      assert_receive {:reply_body, body}, 2_000
      assert_receive {:message_created, %{author_character_id: bot_id} = reply} when bot_id == ctx.bot.id
      assert_receive {:generation_finished, _}, 2_000

      parts = Enum.find_value(body["messages"], fn m -> is_list(m["content"]) && m["content"] end)

      assert %{"type" => "file", "file" => %{"filename" => "fox.pdf", "file_data" => data}} =
               Enum.find(parts, &(&1["type"] == "file"))

      assert data == "data:application/pdf;base64," <> Base.encode64(pdf)
      refute inspect(body["messages"]) =~ "[Document:"

      snapshot = Messages.get_prompt_snapshot(scope, active_body(scope, reply.id).id)
      assert inspect(snapshot.request) =~ "bytes omitted"
      refute inspect(snapshot.request) =~ Base.encode64(pdf)

      assert %{"estimated" => true, "file_tokens" => tokens} =
               Enum.find(snapshot.sections, &(&1["source"] == "chat_history"))

      assert tokens > 500
    end

    test "a model that does not read files gets a PDF's extracted text", %{scope: scope} = ctx do
      stub_models()
      :ok = Messages.subscribe(ctx.chat)
      {:ok, doc} = Attachments.store_binary(pdf_with_text("Hello fox"), filename: "fox.pdf", kinds: Attachment.kinds())
      {:ok, _} = Messages.send_message(scope, ctx.chat, ctx.player.id, "Read", attachments: [doc])

      assert :ok = Generation.generate(scope, ctx.chat, ctx.bot)
      assert_receive {:reply_body, body}, 2_000
      assert_receive {:generation_finished, _}, 2_000
      assert inspect(body["messages"]) =~ "Read\\n[Document: fox.pdf]\\nHello fox\\n[/Document]"
    end

    test "a model that can't hear waits for the caption model's description of an audio clip",
         %{scope: scope} = ctx do
      {:ok, _} = AI.update_model(scope, ctx.joy, %{supports_audio: true})
      chat = Chats.get_chat!(ctx.chat.id)
      stub_models()
      :ok = Messages.subscribe(chat)

      {:ok, clip} =
        Attachments.store_binary("ID3" <> <<4, 0, 0, 0, 0, 0>>, filename: "clip.mp3", kinds: Attachment.kinds())

      {:ok, _} = Messages.send_message(scope, chat, ctx.player.id, "Listen", attachments: [clip])

      assert :ok = Generation.generate(scope, chat, ctx.bot)
      assert_receive {:caption_request, captioner}
      refute_receive {:reply_body, _}, 200

      send(captioner, :release)
      assert_receive {:reply_body, body}, 2_000
      assert_receive {:generation_finished, _}, 2_000
      assert inspect(body["messages"]) =~ "Listen\\n[Audio: clip.mp3]\\nA red fox\\n[/Audio]"
      assert %Attachment{caption_status: :done, described_by_model_id: joy_id} = Repo.reload!(clip)
      assert joy_id == ctx.joy.id
    end

    test "past its document limit, a model summarizes the older document once, in the background",
         %{scope: scope} = ctx do
      {:ok, skyfall} = AI.update_model(scope, ctx.skyfall, %{inline_document_limit: 1})
      chat = Chats.get_chat!(ctx.chat.id)
      stub_models()
      :ok = Messages.subscribe(chat)
      :ok = Mythweaver.Jobs.subscribe(scope)
      {:ok, older} = Attachments.store_binary("The first notes.", filename: "a.txt", kinds: Attachment.kinds())
      {:ok, newer} = Attachments.store_binary("The second notes.", filename: "b.txt", kinds: Attachment.kinds())
      {:ok, _} = Messages.send_message(scope, chat, ctx.player.id, "One", attachments: [older])
      {:ok, _} = Messages.send_message(scope, chat, ctx.player.id, "Two", attachments: [newer])

      assert :ok = Generation.generate(scope, chat, ctx.bot)
      assert_receive {:generation_finished, _}, 2_000
      assert_receive {:job_changed, %{tag: :caption, status: :completed}}, 2_000

      assert_received {:reply_body, first}
      assert_received {:reply_body, second}
      prompt = Model.default_description_prompt(:document)
      {summary, [reply]} = Enum.split_with([first, second], &(inspect(&1) =~ prompt))

      # The reply read both in full: the older had no summary yet.
      assert inspect(reply["messages"]) =~ "[Document: a.txt]\\nThe first notes.\\n[/Document]"
      assert inspect(reply["messages"]) =~ "[Document: b.txt]\\nThe second notes.\\n[/Document]"
      assert [%{"messages" => messages}] = summary
      assert inspect(messages) =~ "The first notes."
      refute inspect(messages) =~ "The second notes."

      older_id = older.id
      skyfall_id = skyfall.id

      assert [%Job{label: "Summarize document", ai_model_id: ^skyfall_id, params: %{"attachment_id" => ^older_id}}] =
               Enum.filter(Repo.all(Job), &(&1.tag == :caption))

      assert %Attachment{caption_status: :done, description: "pong"} = Repo.reload!(older)
      assert %Attachment{caption_status: :none} = Repo.reload!(newer)
    end

    test "a model that watches video gets a clip as a video_url part; one that doesn't, its line",
         %{scope: scope} = ctx do
      clip = <<0, 0, 0, 24, "ftypisom", 0::32>> <> :crypto.strong_rand_bytes(64)
      {:ok, mp4} = Attachments.store_binary(clip, filename: "run.mp4", kinds: Attachment.kinds())
      stub_models()
      :ok = Messages.subscribe(ctx.chat)
      {:ok, _} = Messages.send_message(scope, ctx.chat, ctx.player.id, "Watch", attachments: [mp4])

      assert :ok = Generation.generate(scope, ctx.chat, ctx.bot)
      assert_receive {:reply_body, body}, 2_000
      assert_receive {:generation_finished, _}, 2_000
      assert_receive {:message_created, %{author_character_id: bot_id}} when bot_id == ctx.bot.id
      assert inspect(body["messages"]) =~ "Watch\\n[Video: run.mp4]"

      {:ok, _} = AI.update_model(scope, ctx.skyfall, %{supports_video: true})
      chat = Chats.get_chat!(ctx.chat.id)
      assert :ok = Generation.generate(scope, chat, ctx.bot)
      assert_receive {:reply_body, body}, 2_000
      assert_receive {:message_created, %{author_character_id: bot_id} = reply} when bot_id == ctx.bot.id
      assert_receive {:generation_finished, _}, 2_000

      parts = Enum.find_value(body["messages"], fn m -> is_list(m["content"]) && m["content"] end)
      assert %{"video_url" => %{"url" => url}} = Enum.find(parts, &(&1["type"] == "video_url"))
      assert url == "data:video/mp4;base64," <> Base.encode64(clip)
      refute inspect(parts) =~ "[Video:"

      snapshot = Messages.get_prompt_snapshot(scope, active_body(scope, reply.id).id)
      refute inspect(snapshot.request) =~ Base.encode64(clip)

      assert %{"file_tokens" => 2_000, "estimated" => true} =
               Enum.find(snapshot.sections, &(&1["source"] == "chat_history"))
    end

    test "a guide's video reads as its line for a blind model and goes as a part for one that watches",
         %{scope: scope} = ctx do
      clip = <<0, 0, 0, 24, "ftypisom", 0::32>> <> :crypto.strong_rand_bytes(64)
      {:ok, mp4} = Attachments.store_binary(clip, filename: "run.mp4", kinds: Attachment.kinds())
      guide_block!(scope, ctx.prompt)
      stub_models()
      {:ok, reply} = Messages.send_message(scope, ctx.chat, ctx.bot.id, "first take")
      :ok = Messages.subscribe(ctx.chat)

      assert :ok = Generation.regenerate(scope, ctx.chat, reply, guide_attachments: [mp4])
      assert_receive {:reply_body, body}, 2_000
      assert_receive {:generation_finished, _}, 2_000
      assert inspect(body["messages"]) =~ "Guide: [Video: run.mp4]"

      mp4_id = mp4.id
      assert %{guide_attachments: [%Attachment{id: ^mp4_id}]} = active_body(scope, reply.id)

      {:ok, _} = AI.update_model(scope, ctx.skyfall, %{supports_video: true})
      chat = Chats.get_chat!(ctx.chat.id)
      assert :ok = Generation.regenerate(scope, chat, reply, guide_attachments: [mp4])
      assert_receive {:reply_body, body}, 2_000
      assert_receive {:generation_finished, _}, 2_000

      last_user = body["messages"] |> Enum.filter(&(&1["role"] == "user")) |> List.last()
      assert Enum.any?(last_user["content"], &(&1["type"] == "video_url"))
      refute inspect(body["messages"]) =~ "[Video:"
    end

    test "a refine's media go with its instructions and link to its swipe", %{scope: scope} = ctx do
      {:ok, block} =
        Prompts.create_block(scope, %{
          name: "Refine-#{System.unique_integer([:positive])}",
          content: "{% if anchors.refine %}DO: {{ anchors.refine.instructions }}{% endif %}"
        })

      {:ok, _} = Prompts.add_block(scope, ctx.prompt, block)
      fox = described!(ctx.fox)
      stub_models()
      {:ok, reply} = Messages.send_message(scope, ctx.chat, ctx.bot.id, "first take")
      :ok = Messages.subscribe(ctx.chat)

      assert :ok = Generation.refine(scope, ctx.chat, reply, "Mention it", guide_attachments: [fox])
      assert_receive {:reply_body, body}, 2_000
      assert_receive {:generation_finished, _}, 2_000
      assert inspect(body["messages"]) =~ "DO: Mention it\\n[Image: A red fox]"

      fox_id = fox.id
      assert %{origin: :refine, guide_attachments: [%Attachment{id: ^fox_id}]} = active_body(scope, reply.id)
    end

    test "a regenerate keeps the replaced message's media, as text for a blind model", %{scope: scope} = ctx do
      fox = described!(ctx.fox)
      stub_models()
      {:ok, reply} = Messages.send_message(scope, ctx.chat, ctx.bot.id, "first take")
      {:ok, reply} = Messages.set_attachments(scope, ctx.chat, reply, [fox])
      :ok = Messages.subscribe(ctx.chat)

      assert :ok = Generation.regenerate(scope, ctx.chat, reply)
      assert_receive {:reply_body, body}, 2_000
      assert_receive {:generation_finished, _}, 2_000

      assert Enum.any?(
               body["messages"],
               &(&1["role"] == "user" and inspect(&1["content"]) =~ "#{ctx.bot.name}: [Image: A red fox]")
             )

      refute inspect(body) =~ "first take"
    end

    test "a continue sends the continued message's image to a vision model before its text",
         %{scope: scope} = ctx do
      {:ok, _} = AI.update_model(scope, ctx.skyfall, %{supports_images: true, caption_model_id: nil})
      chat = Chats.get_chat!(ctx.chat.id)
      stub_models()
      {:ok, reply} = Messages.send_message(scope, chat, ctx.bot.id, "first take", attachments: [ctx.fox])
      :ok = Messages.subscribe(chat)

      assert :ok = Generation.continue(scope, chat, reply)
      assert_receive {:reply_body, body}, 2_000
      assert_receive {:generation_finished, _}, 2_000

      messages = body["messages"]

      image_at =
        Enum.find_index(
          messages,
          &(&1["role"] == "user" and is_list(&1["content"]) and
              Enum.any?(&1["content"], fn p -> p["type"] == "image_url" end))
        )

      tail_at = Enum.find_index(messages, &(&1["role"] == "assistant" and inspect(&1["content"]) =~ "first take"))
      assert is_integer(image_at) and is_integer(tail_at) and image_at < tail_at
    end

    test "a regenerate waits for the description of the replaced message's own image", %{scope: scope} = ctx do
      stub_models()
      {:ok, reply} = Messages.send_message(scope, ctx.chat, ctx.bot.id, "first take")
      {:ok, reply} = Messages.set_attachments(scope, ctx.chat, reply, [ctx.fox])
      :ok = Messages.subscribe(ctx.chat)

      assert :ok = Generation.regenerate(scope, ctx.chat, reply)
      assert_receive {:caption_request, captioner}, 2_000
      refute_receive {:reply_body, _}, 200

      send(captioner, :release)
      assert_receive {:reply_body, body}, 2_000
      assert_receive {:generation_finished, _}, 2_000
      assert inspect(body["messages"]) =~ "[Image: A red fox]"
    end

    defp described!(attachment),
      do: attachment |> Ecto.Changeset.change(description: "A red fox", caption_status: :done) |> Repo.update!()
  end

  describe "context limit" do
    setup %{scope: scope, chat: chat, player: player} do
      for i <- 1..6,
          do: {:ok, _} = Messages.send_message(scope, chat, player.id, "M#{i} " <> String.duplicate("x", 3300))

      test = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:body, Jason.decode!(raw)})
        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce(@chat_frames, conn, fn frame, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, frame)
          conn
        end)
      end)

      :ok
    end

    defp history_prompt!(scope, content) do
      prompt = global_prompt!(scope, content)

      {:ok, history} =
        Prompts.create_block(scope, %{name: "History-#{System.unique_integer([:positive])}", kind: :chat_history})

      {:ok, _} = Prompts.add_block(scope, prompt, history)
      prompt
    end

    defp windowed_model!(scope, window) do
      {:ok, model} =
        AI.update_model(scope, linked_model!(scope), %{context_window: window, sampler: %{max_tokens: 500}})

      model
    end

    test "the oldest history is left out to fit the model's window", %{scope: scope, chat: chat, bot: bot} do
      windowed_model!(scope, 4000)
      history_prompt!(scope, "Be brief.")
      :ok = Messages.subscribe(chat)

      assert :ok = Generation.generate(scope, chat, bot)
      assert_receive {:message_created, message}
      assert_receive {:body, request}
      assert_receive {:generation_finished, _message_id}

      sent = Jason.encode!(request["messages"])
      refute sent =~ "M1 "
      assert sent =~ "M6 "

      body = active_body(scope, message.id)
      assert body.error == nil
      assert %{"trimmed" => trimmed, "overflow" => false} = Messages.get_prompt_snapshot(scope, body.id).context
      assert trimmed > 0
    end

    test "a prompt over the limit without history is refused before any request", %{scope: scope, chat: chat, bot: bot} do
      windowed_model!(scope, 1000)
      history_prompt!(scope, String.duplicate("x", 6600))
      :ok = Messages.subscribe(chat)

      assert :ok = Generation.generate(scope, chat, bot)
      assert_receive {:message_created, message}

      assert_receive {:generation_discarded, _chat_id,
                      "The prompt is too long for the 1,000-token context limit even without chat history: about 2,000 tokens, with 500 kept free for the reply."}

      assert_receive {:generation_finished, _message_id}
      refute_received {:body, _}
      assert Messages.get_message(scope, message.id) == nil
    end
  end

  defp png,
    do:
      Base.decode64!("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")

  # A one-page PDF with real xref offsets, so it opens without recovery.
  defp pdf_with_text(text) do
    stream = "BT /F1 12 Tf 72 720 Td (#{text}) Tj ET"

    objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
      "<< /Length #{byte_size(stream)} >>\nstream\n#{stream}\nendstream",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"
    ]

    {body, offsets} =
      objects
      |> Enum.with_index(1)
      |> Enum.reduce({"%PDF-1.4\n", []}, fn {object, i}, {acc, offsets} ->
        {acc <> "#{i} 0 obj\n#{object}\nendobj\n", [byte_size(acc) | offsets]}
      end)

    xref =
      "xref\n0 #{length(objects) + 1}\n0000000000 65535 f \n" <>
        Enum.map_join(Enum.reverse(offsets), "", &(String.pad_leading("#{&1}", 10, "0") <> " 00000 n \n"))

    body <> xref <> "trailer\n<< /Size #{length(objects) + 1} /Root 1 0 R >>\nstartxref\n#{byte_size(body)}\n%%EOF\n"
  end
end
