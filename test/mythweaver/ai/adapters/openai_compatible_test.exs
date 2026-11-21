defmodule Mythweaver.AI.Adapters.OpenAICompatibleTest do
  use Mythweaver.DataCase

  alias Mythweaver.AI
  alias Mythweaver.AI.Adapters.OpenAICompatible
  alias Mythweaver.AI.Request
  alias Mythweaver.AI.SamplerParams
  alias Mythweaver.AI.StreamEvent
  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Prompts.AttachmentRef

  setup do
    %{scope: scope!()}
  end

  # The verbatim body a local llama-swap/llama.cpp `/v1/chat/completions` returned this session for a
  # thinking model truncated by `max_tokens`: empty `content`, the answer in `reasoning_content`, and
  # a `.gguf` path echoed as the model.
  @llamacpp_chat_body %{
    "choices" => [
      %{
        "finish_reason" => "length",
        "index" => 0,
        "message" => %{
          "role" => "assistant",
          "content" => "",
          "reasoning_content" => "The user wants me to say exactly \"pong\"…"
        }
      }
    ],
    "created" => 1_757_000_000,
    "id" => "chatcmpl-abc123",
    "model" => "/Users/x/models/gemma-4-31B-it-UD-Q8_K_XL.gguf",
    "object" => "chat.completion",
    "usage" => %{
      "completion_tokens" => 16,
      "prompt_tokens" => 20,
      "total_tokens" => 36,
      "prompt_tokens_details" => %{"cached_tokens" => 0}
    }
  }

  defp provider!(scope, attrs \\ %{}) do
    {:ok, provider} =
      AI.create_provider(
        scope,
        Map.merge(
          %{
            name: "Local #{System.unique_integer([:positive])}",
            adapter: :openai_compatible,
            base_url: "http://localhost:8080/v1"
          },
          attrs
        )
      )

    provider
  end

  defp chat_request(sampler \\ %SamplerParams{}) do
    %Request{
      model_id: "gemma-4",
      mode: :chat,
      sampler: sampler,
      messages: [%Request.Message{role: :user, content: "Reply with the single word: pong"}]
    }
  end

  # Verbatim frames from a live llama.cpp `/v1/chat/completions` stream: a role announcement with
  # null content, reasoning deltas before content deltas, a finish-reason frame with an empty delta,
  # then a separate usage frame with an empty `choices` list, then the non-JSON sentinel.
  @chat_frames [
    ~s(data: {"choices":[{"finish_reason":null,"index":0,"delta":{"role":"assistant","content":null}}],"model":"/Users/x/models/gemma-4-31B-it-UD-Q8_K_XL.gguf","object":"chat.completion.chunk"}\n\n),
    ~s(data: {"choices":[{"finish_reason":null,"index":0,"delta":{"reasoning_content":"The"}}],"object":"chat.completion.chunk"}\n\n),
    ~s(data: {"choices":[{"finish_reason":null,"index":0,"delta":{"reasoning_content":" user"}}],"object":"chat.completion.chunk"}\n\n),
    ~s(data: {"choices":[{"finish_reason":null,"index":0,"delta":{"content":"po"}}],"object":"chat.completion.chunk"}\n\n),
    ~s(data: {"choices":[{"finish_reason":null,"index":0,"delta":{"content":"ng"}}],"object":"chat.completion.chunk"}\n\n),
    ~s(data: {"choices":[{"finish_reason":"stop","index":0,"delta":{}}],"object":"chat.completion.chunk"}\n\n),
    ~s(data: {"choices":[],"object":"chat.completion.chunk","usage":{"completion_tokens":31,"prompt_tokens":18,"total_tokens":49,"prompt_tokens_details":{"cached_tokens":7}}}\n\n),
    "data: [DONE]\n\n"
  ]

  # `/v1/completions` differs twice: the token is at `choices[0]["text"]`, and usage rides the final
  # *content* frame instead of a separate empty-`choices` one.
  @text_frames [
    ~s(data: {"choices":[{"text":" own","index":0,"logprobs":null,"finish_reason":null}],"object":"text_completion"}\n\n),
    ~s(data: {"choices":[{"text":" own","index":0,"logprobs":null,"finish_reason":null}],"object":"text_completion"}\n\n),
    ~s(data: {"choices":[{"text":"","index":0,"logprobs":null,"finish_reason":"length"}],"object":"text_completion","usage":{"completion_tokens":16,"prompt_tokens":7,"total_tokens":23}}\n\n),
    "data: [DONE]\n\n"
  ]

  defp stub_models(entries) do
    Req.Test.stub(Mythweaver.AI, &Req.Test.json(&1, %{"data" => entries}))
  end

  # Each element is delivered as its own HTTP chunk, so the adapter's fold sees the same frame/chunk
  # misalignment a real socket produces.
  defp stub_chunks(chunks) do
    Req.Test.stub(Mythweaver.AI, &chunk_frames(&1, chunks))
  end

  defp chunk_frames(conn, chunks) do
    conn = Plug.Conn.send_chunked(conn, 200)

    Enum.reduce(chunks, conn, fn chunk, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, chunk)
      conn
    end)
  end

  defp event_collector do
    test_pid = self()
    fn event -> send(test_pid, {:event, event}) end
  end

  defp collected_events do
    Enum.reverse(drain_events([]))
  end

  defp drain_events(acc) do
    receive do
      {:event, event} -> drain_events([event | acc])
    after
      0 -> acc
    end
  end

  defp thinking_model!(scope, provider, sampler, link_attrs \\ %{}, model_attrs \\ %{}) do
    {:ok, model} =
      AI.create_model(scope, Map.merge(%{name: "Gemma 4 31B", api_model_id: "gemma-4", sampler: sampler}, model_attrs))

    {:ok, _link} = AI.link_model(scope, provider, model, link_attrs)
    model
  end

  # The body `AI.stream/3` sends for `model`: selection, wire id, extra_body layering and the thinking
  # dialect all happen in the AI layer before the adapter posts.
  defp sent_body(model, messages \\ [%Request.Message{role: :user, content: "ping"}], input \\ %{}) do
    test_pid = self()

    Req.Test.stub(Mythweaver.AI, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:body, Jason.decode!(raw)})
      chunk_frames(conn, @chat_frames)
    end)

    assert {:ok, _completion, _link} =
             AI.stream(model, model.user_id, Map.put(input, :messages, messages), fn _event -> :ok end)

    assert_received {:body, body}
    body
  end

  describe "discover_models/1" do
    test "surfaces the id and the non-standard friendly name", %{scope: scope} do
      Req.Test.stub(Mythweaver.AI, fn conn ->
        Req.Test.json(conn, %{
          "data" => [%{"id" => "gemma-4", "name" => "Gemma 4 31B IT (Q8_K)"}]
        })
      end)

      assert {:ok, [model]} = OpenAICompatible.discover_models(provider!(scope))
      assert model.id == "gemma-4"
      assert model.name == "Gemma 4 31B IT (Q8_K)"
      assert model.attrs == %{}
    end

    # Verbatim key shapes from a live `https://openrouter.ai/api/v1/models` fetch. Pricing there is
    # USD per *single* token as a decimal string, so the adapter must scale it to this app's per-Mtok
    # unit rather than pass it through.
    test "extracts every field an OpenRouter entry advertises", %{scope: scope} do
      stub_models([
        %{
          "id" => "anthropic/claude-fable-5.1",
          "name" => "Anthropic: Claude Fable 5.1",
          "description" => "A long marketing description.",
          "context_length" => 1_000_000,
          "top_provider" => %{"max_completion_tokens" => 128_000},
          "pricing" => %{"prompt" => "0.00001", "completion" => "0.00005"},
          "architecture" => %{"input_modalities" => ["text", "image", "file"]},
          "supported_parameters" => ["tools", "reasoning"]
        }
      ])

      assert {:ok, [model]} = OpenAICompatible.discover_models(provider!(scope))

      # Prices are compared numerically: `Decimal.normalize/1` leaves `10` as coefficient 1 exponent 1,
      # which `==` distinguishes from `Decimal.new("10")` while both print `"10"` at `:normal`.
      assert Decimal.equal?(model.attrs["prompt_cost_per_mtok"], Decimal.new("10"))
      assert Decimal.equal?(model.attrs["completion_cost_per_mtok"], Decimal.new("50"))
      assert Decimal.to_string(model.attrs["prompt_cost_per_mtok"], :normal) == "10"

      # Everything else exactly, so an invented key fails. That includes `notes`: the entry advertises a
      # `description` and the adapter must not carry that free text into state or onto the model.
      assert Map.drop(model.attrs, ["prompt_cost_per_mtok", "completion_cost_per_mtok"]) == %{
               "context_window" => 1_000_000,
               "supports_images" => true,
               "supports_files" => true,
               "supports_tools" => true,
               "supports_thinking" => true
             }
    end

    test "flags audio and video input from the advertised modalities, llama-swap's included", %{scope: scope} do
      stub_models([
        %{"id" => "voice-1", "architecture" => %{"input_modalities" => ["text", "audio"]}},
        %{"id" => "artemis-31b", "architecture" => %{"input_modalities" => ["text", "audio", "image", "video"]}}
      ])

      assert {:ok, [voice, artemis]} = OpenAICompatible.discover_models(provider!(scope))
      assert voice.attrs == %{"supports_audio" => true}
      assert artemis.attrs == %{"supports_audio" => true, "supports_images" => true, "supports_video" => true}
    end

    # A hostile or merely chatty `/models` reply controls this string's length, once per advertised
    # model; `notes` is a user-authored field and never a channel for it.
    test "ignores a description entirely", %{scope: scope} do
      stub_models([%{"id" => "gemma-4", "description" => String.duplicate("x", 10_000)}])

      assert {:ok, [model]} = OpenAICompatible.discover_models(provider!(scope))
      assert model.attrs == %{}
    end

    test "drops OpenRouter's -1 pricing sentinel but keeps a real free tier", %{scope: scope} do
      stub_models([
        %{"id" => "openrouter/auto", "pricing" => %{"prompt" => "-1", "completion" => "-1"}},
        %{"id" => "free/model", "pricing" => %{"prompt" => "0", "completion" => "0"}}
      ])

      assert {:ok, [priced_at_runtime, free]} = OpenAICompatible.discover_models(provider!(scope))
      assert priced_at_runtime.attrs == %{}

      assert Map.keys(free.attrs) == ["completion_cost_per_mtok", "prompt_cost_per_mtok"]
      assert Decimal.equal?(free.attrs["prompt_cost_per_mtok"], Decimal.new("0"))
      assert Decimal.equal?(free.attrs["completion_cost_per_mtok"], Decimal.new("0"))
    end

    test "prefers a llama.cpp entry's loaded context over its training context", %{scope: scope} do
      stub_models([%{"id" => "gemma-4", "meta" => %{"n_ctx" => 32_768, "n_ctx_train" => 131_072}}])

      assert {:ok, [model]} = OpenAICompatible.discover_models(provider!(scope))
      assert model.attrs == %{"context_window" => 32_768}
    end

    test "ignores a non-positive context rather than letting it reach the database", %{scope: scope} do
      stub_models([%{"id" => "x", "max_model_len" => 0, "meta" => %{"n_ctx_train" => 0}}])

      assert {:ok, [model]} = OpenAICompatible.discover_models(provider!(scope))
      assert model.attrs == %{}
    end

    test "reports a 200 body it cannot read", %{scope: scope} do
      Req.Test.stub(Mythweaver.AI, fn conn -> Req.Test.json(conn, %{"models" => []}) end)

      assert {:error, {:unexpected_body, %{"models" => []}}} =
               OpenAICompatible.discover_models(provider!(scope))
    end

    test "reports an HTTP error with its status and body", %{scope: scope} do
      Req.Test.stub(Mythweaver.AI, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, ~s({"error":"nope"}))
      end)

      assert {:error, {:http_error, 401, %{"error" => "nope"}}} =
               OpenAICompatible.discover_models(provider!(scope))
    end

    test "reports a transport error", %{scope: scope} do
      Req.Test.stub(Mythweaver.AI, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, {:transport_error, message}} = OpenAICompatible.discover_models(provider!(scope))
      assert is_binary(message)
    end
  end

  describe "complete/2 chat" do
    test "keeps reasoning content when a thinking model returns empty text", %{scope: scope} do
      Req.Test.stub(Mythweaver.AI, &Req.Test.json(&1, @llamacpp_chat_body))

      assert {:ok, completion} = OpenAICompatible.complete(provider!(scope), chat_request())
      assert completion.text == ""
      assert completion.reasoning =~ "pong"
      assert completion.finish_reason == "length"
      assert completion.model == "/Users/x/models/gemma-4-31B-it-UD-Q8_K_XL.gguf"
      assert completion.prompt_tokens == 20
      assert completion.completion_tokens == 16
      assert completion.total_tokens == 36
      assert completion.cost == nil
      assert completion.raw == @llamacpp_chat_body
    end

    test "carries a provider-reported cost as a decimal", %{scope: scope} do
      Req.Test.stub(Mythweaver.AI, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"content" => "pong"}, "finish_reason" => "stop"}],
          "model" => "google/gemma-4-31b-it",
          "usage" => %{
            "cost" => 0.00042,
            "prompt_tokens" => 10,
            "completion_tokens" => 5,
            "total_tokens" => 15
          }
        })
      end)

      assert {:ok, completion} = OpenAICompatible.complete(provider!(scope), chat_request())
      assert completion.text == "pong"
      assert Decimal.equal?(completion.cost, Decimal.new("0.00042"))
    end

    test "sends the sampler under wire names, with extra_body winning over a canonical field", %{scope: scope} do
      test_pid = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, Jason.decode!(raw)})
        send(test_pid, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
        Req.Test.json(conn, @llamacpp_chat_body)
      end)

      provider = provider!(scope, %{api_key: "sk-test"})

      sampler = %SamplerParams{
        temperature: 0.85,
        top_k: 40,
        min_p: 0.05,
        max_tokens: 64,
        stop_sequences: ["</s>"]
      }

      request = chat_request(sampler) |> Map.put(:extra_body, %{"temperature" => 1.5})
      assert {:ok, _completion} = OpenAICompatible.complete(provider, request)

      assert_received {:body, body}
      assert body["model"] == "gemma-4"
      assert body["stream"] == false
      assert body["messages"] == [%{"role" => "user", "content" => "Reply with the single word: pong"}]
      assert body["stop"] == ["</s>"]
      assert body["top_k"] == 40
      assert body["min_p"] == 0.05
      assert body["max_tokens"] == 64
      refute Map.has_key?(body, "stop_sequences")
      assert body["temperature"] == 1.5

      assert_received {:auth, ["Bearer sk-test"]}
    end

    test "sends no authorization header when the provider has no key", %{scope: scope} do
      test_pid = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        send(test_pid, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
        Req.Test.json(conn, @llamacpp_chat_body)
      end)

      assert {:ok, _completion} = OpenAICompatible.complete(provider!(scope), chat_request())
      assert_received {:auth, []}
    end

    test "sends the session id as x-session-id", %{scope: scope} do
      test_pid = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        send(test_pid, {:session, Plug.Conn.get_req_header(conn, "x-session-id")})
        Req.Test.json(conn, @llamacpp_chat_body)
      end)

      request = %{chat_request() | session_id: "user-1:chat-1"}
      assert {:ok, _completion} = OpenAICompatible.complete(provider!(scope), request)
      assert_received {:session, ["user-1:chat-1"]}
    end

    test "sends no x-session-id without a session", %{scope: scope} do
      test_pid = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        send(test_pid, {:session, Plug.Conn.get_req_header(conn, "x-session-id")})
        Req.Test.json(conn, @llamacpp_chat_body)
      end)

      assert {:ok, _completion} = OpenAICompatible.complete(provider!(scope), chat_request())
      assert_received {:session, []}
    end

    test "an extra_header overrides the bearer scheme", %{scope: scope} do
      test_pid = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        send(test_pid, {:key, Plug.Conn.get_req_header(conn, "x-api-key")})
        Req.Test.json(conn, @llamacpp_chat_body)
      end)

      provider = provider!(scope, %{api_key: "sk-test", extra_headers: %{"x-api-key" => "anthropic"}})

      assert {:ok, _completion} = OpenAICompatible.complete(provider, chat_request())
      assert_received {:key, ["anthropic"]}
    end

    test "identifies as Mythweaver with the app version", %{scope: scope} do
      test_pid = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        send(test_pid, {:ua, Plug.Conn.get_req_header(conn, "user-agent")})
        Req.Test.json(conn, @llamacpp_chat_body)
      end)

      assert {:ok, _completion} = OpenAICompatible.complete(provider!(scope), chat_request())
      assert_received {:ua, [ua]}
      assert ua == "Mythweaver/#{Application.spec(:mythweaver, :vsn)}"
    end

    test "an extra_header overrides the user-agent", %{scope: scope} do
      test_pid = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        send(test_pid, {:ua, Plug.Conn.get_req_header(conn, "user-agent")})
        Req.Test.json(conn, @llamacpp_chat_body)
      end)

      provider = provider!(scope, %{extra_headers: %{"user-agent" => "custom/1"}})

      assert {:ok, _completion} = OpenAICompatible.complete(provider, chat_request())
      assert_received {:ua, ["custom/1"]}
    end

    test "a capitalised extra_header replaces the built-in header instead of duplicating it", %{scope: scope} do
      test_pid = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        send(test_pid, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
        Req.Test.json(conn, @llamacpp_chat_body)
      end)

      provider = provider!(scope, %{api_key: "sk-test", extra_headers: %{"Authorization" => "Bearer custom"}})

      assert {:ok, _completion} = OpenAICompatible.complete(provider, chat_request())
      assert_received {:auth, ["Bearer custom"]}
    end

    test "a stop in sampler extra wins over stop_sequences", %{scope: scope} do
      test_pid = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, Jason.decode!(raw)})
        Req.Test.json(conn, @llamacpp_chat_body)
      end)

      sampler = %SamplerParams{stop_sequences: ["</s>"], extra: %{"stop" => ["\n"]}}

      assert {:ok, _completion} = OpenAICompatible.complete(provider!(scope), chat_request(sampler))
      assert_received {:body, %{"stop" => ["\n"]}}
    end

    test "cuts a whole reply at a stop string, including one that opens it", %{scope: scope} do
      reply = fn content ->
        Req.Test.stub(Mythweaver.AI, fn conn ->
          Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => content}, "finish_reason" => "length"}]})
        end)

        {:ok, completion} = OpenAICompatible.complete(provider!(scope), %{chat_request() | stop: ["\nBob:"]})
        {completion.text, completion.finish_reason}
      end

      assert reply.("She nods.\nBob: Sure.") == {"She nods.", "stop"}
      assert reply.("Bob: Sure.") == {"", "stop"}
      assert reply.("Ask Bob: sure.") == {"Ask Bob: sure.", "length"}
    end

    test "refuses a chat request with no messages", %{scope: scope} do
      assert OpenAICompatible.complete(provider!(scope), %Request{
               model_id: "gemma-4",
               mode: :chat,
               sampler: %SamplerParams{}
             }) == {:error, {:invalid_request, :missing_messages}}
    end

    test "reports a response with no choices", %{scope: scope} do
      Req.Test.stub(Mythweaver.AI, &Req.Test.json(&1, %{"choices" => []}))

      assert {:error, {:unexpected_body, %{"choices" => []}}} =
               OpenAICompatible.complete(provider!(scope), chat_request())
    end

    test "splits inline think tags only when the request carries them", %{scope: scope} do
      Req.Test.stub(
        Mythweaver.AI,
        &Req.Test.json(&1, %{
          "choices" => [
            %{
              "index" => 0,
              "finish_reason" => "stop",
              "message" => %{"role" => "assistant", "content" => "<think>plan</think>\n\nHello"}
            }
          ]
        })
      )

      request = Map.put(chat_request(), :reasoning_tags, {"<think>", "</think>"})
      assert {:ok, completion} = OpenAICompatible.complete(provider!(scope), request)
      assert completion.reasoning == "plan"
      assert completion.text == "Hello"

      assert {:ok, completion} = OpenAICompatible.complete(provider!(scope), chat_request())
      assert completion.reasoning == nil
      assert completion.text == "<think>plan</think>\n\nHello"
    end
  end

  describe "complete/2 text" do
    test "reads the completion from the text field", %{scope: scope} do
      test_pid = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, Jason.decode!(raw)})

        Req.Test.json(conn, %{
          "choices" => [%{"text" => " pong", "index" => 0, "finish_reason" => "stop"}],
          "object" => "text_completion",
          "usage" => %{"prompt_tokens" => 4, "completion_tokens" => 2, "total_tokens" => 6}
        })
      end)

      request = %Request{
        model_id: "gemma-4",
        mode: :text,
        sampler: %SamplerParams{max_tokens: 8},
        prompt: "Say pong."
      }

      assert {:ok, completion} = OpenAICompatible.complete(provider!(scope), request)
      assert completion.text == " pong"
      assert completion.total_tokens == 6

      assert_received {:body, body}
      assert body["prompt"] == "Say pong."
      refute Map.has_key?(body, "messages")
    end

    test "refuses a text request with no prompt", %{scope: scope} do
      assert OpenAICompatible.complete(provider!(scope), %Request{
               model_id: "gemma-4",
               mode: :text,
               sampler: %SamplerParams{}
             }) == {:error, {:invalid_request, :missing_prompt}}
    end
  end

  describe "AI.stream/3 request body" do
    test "sends the per-provider override as the wire model id", %{scope: scope} do
      provider = provider!(scope)
      {:ok, model} = AI.create_model(scope, %{name: "Gemma 4 31B", api_model_id: "gemma-4"})
      {:ok, _link} = AI.link_model(scope, provider, model, %{api_model_id_override: "google/gemma-4-31b"})

      assert %{"model" => "google/gemma-4-31b"} = sent_body(model)
    end

    test "sends image parts as base64 data URLs", %{scope: scope} do
      provider = provider!(scope)
      {:ok, model} = AI.create_model(scope, %{name: "Vision", api_model_id: "vision", supports_images: true})
      {:ok, _link} = AI.link_model(scope, provider, model)

      png =
        Base.decode64!(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        )

      content = [
        %Request.Text{text: "Look"},
        %Request.Image{media_type: "image/png", data: png},
        %Request.Image{media_type: "image/png", data: png, detail: :low}
      ]

      assert %{"messages" => [%{"role" => "user", "content" => wire}]} =
               sent_body(model, [%Request.Message{role: :user, content: content}])

      url = "data:image/png;base64," <> Base.encode64(png)

      # `detail` goes only where a part carries one.
      assert wire == [
               %{"type" => "text", "text" => "Look"},
               %{"type" => "image_url", "image_url" => %{"url" => url}},
               %{"type" => "image_url", "image_url" => %{"url" => url, "detail" => "low"}}
             ]
    end

    test "sends file parts and video as data URLs and audio as base64 input_audio", %{scope: scope} do
      provider = provider!(scope)
      {:ok, model} = AI.create_model(scope, %{name: "Ears", api_model_id: "ears", supports_audio: true})
      {:ok, _link} = AI.link_model(scope, provider, model)

      content = [
        %Request.File{media_type: "application/pdf", filename: "fox.pdf", data: "%PDF"},
        %Request.Audio{format: "mp3", data: "x"},
        %Request.Video{media_type: "video/mp4", data: "x"}
      ]

      assert %{"messages" => [%{"content" => wire}]} =
               sent_body(model, [%Request.Message{role: :user, content: content}])

      assert wire == [
               %{
                 "type" => "file",
                 "file" => %{"filename" => "fox.pdf", "file_data" => "data:application/pdf;base64,JVBERg=="}
               },
               %{"type" => "input_audio", "input_audio" => %{"data" => "eA==", "format" => "mp3"}},
               %{"type" => "video_url", "video_url" => %{"url" => "data:video/mp4;base64,eA=="}}
             ]
    end

    test "deep-merges extra_body: model, then connection, then link", %{scope: scope} do
      provider = provider!(scope, %{extra_body: %{"b" => 2, "c" => 2}})

      {:ok, model} =
        AI.create_model(scope, %{
          name: "Gemma 4 31B",
          api_model_id: "gemma-4",
          extra_body: %{
            "a" => 1,
            "b" => 1,
            "chat_template_kwargs" => %{"enable_thinking" => true, "x" => 1}
          }
        })

      {:ok, _link} =
        AI.link_model(scope, provider, model, %{
          extra_body: %{"c" => 3, "chat_template_kwargs" => %{"enable_thinking" => false}}
        })

      body = sent_body(model)
      assert body["a"] == 1
      assert body["b"] == 2
      assert body["c"] == 3
      assert body["chat_template_kwargs"] == %{"enable_thinking" => false, "x" => 1}
    end

    test "translates thinking through the connection's dialect and never sends the canonical key", %{scope: scope} do
      provider = provider!(scope, %{thinking_dialect: :llama_cpp})
      model = thinking_model!(scope, provider, %{thinking: :none})

      body = sent_body(model)
      assert body["reasoning_effort"] == "none"
      refute Map.has_key?(body, "thinking")
    end

    test "a request's thinking never goes above the model's level, and goes as is on backend default",
         %{scope: scope} do
      provider = provider!(scope, %{thinking_dialect: :llama_cpp})
      capped = thinking_model!(scope, provider, %{thinking: :low})
      open = thinking_model!(scope, provider, %{}, %{}, %{name: "Open", api_model_id: "open"})
      ping = [%Request.Message{role: :user, content: "ping"}]

      assert sent_body(capped, ping, %{thinking: :high})["reasoning_effort"] == "low"
      assert sent_body(capped, ping, %{thinking: :none})["reasoning_effort"] == "none"
      assert sent_body(open, ping, %{thinking: :medium})["reasoning_effort"] == "medium"
      refute Map.has_key?(sent_body(open, ping), "reasoning_effort")
    end

    test "a link's dialect overrides the connection's", %{scope: scope} do
      provider = provider!(scope, %{thinking_dialect: :llama_cpp})
      model = thinking_model!(scope, provider, %{thinking: :high}, %{thinking_dialect: :openrouter})

      body = sent_body(model)
      assert body["reasoning"] == %{"effort" => "high"}
      refute Map.has_key?(body, "reasoning_effort")
    end

    test "extra_body layers deep-merge over the dialect fragment", %{scope: scope} do
      provider = provider!(scope, %{thinking_dialect: :openrouter})

      model =
        thinking_model!(scope, provider, %{thinking: :high}, %{}, %{
          extra_body: %{"reasoning" => %{"exclude" => true}}
        })

      assert sent_body(model)["reasoning"] == %{"effort" => "high", "exclude" => true}

      provider =
        provider!(scope, %{
          name: "Override",
          thinking_dialect: :llama_cpp,
          extra_body: %{"reasoning_effort" => "low"}
        })

      model = thinking_model!(scope, provider, %{thinking: :high}, %{}, %{name: "Other", api_model_id: "other"})

      assert sent_body(model)["reasoning_effort"] == "low"
    end

    test "sends no thinking keys when neither the connection nor the link has a dialect", %{scope: scope} do
      model = thinking_model!(scope, provider!(scope), %{thinking: :high})

      body = sent_body(model)
      refute Map.has_key?(body, "thinking")
      refute Map.has_key?(body, "reasoning_effort")
      refute Map.has_key?(body, "reasoning")
    end

    test "names repetition penalties through the connection's sampler dialect", %{scope: scope} do
      provider = provider!(scope, %{sampler_dialect: :llama_cpp})
      model = thinking_model!(scope, provider, %{repetition_penalty: 1.1})

      body = sent_body(model)
      assert body["repeat_penalty"] == 1.1
      refute Map.has_key?(body, "repetition_penalty")
    end

    test "a link's sampler dialect overrides the connection's", %{scope: scope} do
      provider = provider!(scope, %{sampler_dialect: :llama_cpp})
      model = thinking_model!(scope, provider, %{top_k: 40, temperature: 0.7}, %{sampler_dialect: :openai})

      body = sent_body(model)
      assert body["temperature"] == 0.7
      refute Map.has_key?(body, "top_k")
    end

    test "a sampler extra key beats the dialect's typed field", %{scope: scope} do
      provider = provider!(scope, %{sampler_dialect: :llama_cpp})

      model =
        thinking_model!(scope, provider, %{
          temperature: 0.5,
          repetition_penalty: 1.1,
          extra: %{"temperature" => 1.5, "repeat_penalty" => 1.2}
        })

      body = sent_body(model)
      assert body["temperature"] == 1.5
      assert body["repeat_penalty"] == 1.2
    end
  end

  describe "stream/3 chat" do
    test "folds the frames a live llama.cpp stream emits into events and a completion", %{scope: scope} do
      stub_chunks(@chat_frames)

      collector = event_collector()

      assert {:ok, completion} = OpenAICompatible.stream(provider!(scope), chat_request(), collector)

      events = collected_events()

      # Null content, an empty final delta, and an empty text field all occur in these frames; none of
      # them may reach the callback.
      tokens = Enum.filter(events, &match?(%struct{} when struct in [StreamEvent.Delta, StreamEvent.Reasoning], &1))
      refute Enum.any?(tokens, &(&1.text in [nil, ""]))

      assert Enum.map(events, & &1.__struct__) == [
               StreamEvent.Request,
               StreamEvent.Reasoning,
               StreamEvent.Reasoning,
               StreamEvent.Delta,
               StreamEvent.Delta,
               StreamEvent.Done
             ]

      assert %StreamEvent.Request{body: %{"stream" => true, "messages" => [_ | _]}} = hd(events)
      assert List.last(events) == %StreamEvent.Done{finish_reason: "stop"}

      assert completion.text == "po" <> "ng"
      assert completion.reasoning == "The user"
      assert completion.finish_reason == "stop"
      assert completion.model == "/Users/x/models/gemma-4-31B-it-UD-Q8_K_XL.gguf"
      assert completion.prompt_tokens == 18
      assert completion.completion_tokens == 31
      assert completion.total_tokens == 49
      assert completion.cost == nil
    end

    test "reassembles a frame split mid-JSON across two chunks", %{scope: scope} do
      <<head::binary-size(40), tail::binary>> = IO.iodata_to_binary(@chat_frames)
      stub_chunks([head, tail])

      assert {:ok, completion} = OpenAICompatible.stream(provider!(scope), chat_request(), event_collector())
      assert completion.text == "pong"
      assert completion.reasoning == "The user"
      assert completion.total_tokens == 49
    end

    test "drops non-object payloads and malformed choices instead of raising", %{scope: scope} do
      stub_chunks([
        ~s(data: {"choices":[{"index":0,"delta":{"content":"po"}}]}\n\n),
        "data: 1\n\n",
        ~s(data: {"choices":["x"]}\n\n),
        ~s(data: {"choices":[{"delta":"x"}]}\n\n),
        ~s(data: {"choices":[{"index":0,"delta":{"content":"ng"}}]}\n\n),
        "data: [DONE]\n\n"
      ])

      assert {:ok, completion} = OpenAICompatible.stream(provider!(scope), chat_request(), event_collector())
      assert completion.text == "pong"
    end

    test "sends the streaming keys, and extra_body cannot switch streaming off", %{scope: scope} do
      test_pid = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, Jason.decode!(raw)})
        chunk_frames(conn, @chat_frames)
      end)

      assert {:ok, _completion} = OpenAICompatible.stream(provider!(scope), chat_request(), event_collector())
      assert_received {:body, body}
      assert body["stream"] == true
      assert body["stream_options"] == %{"include_usage" => true}

      request = Map.put(chat_request(), :extra_body, %{"stream" => false})

      assert {:ok, _completion} = OpenAICompatible.stream(provider!(scope), request, event_collector())
      assert_received {:body, overridden}
      assert overridden["stream"] == true
    end

    test "emits only the request event for a non-200 body", %{scope: scope} do
      Req.Test.stub(Mythweaver.AI, &Plug.Conn.send_resp(&1, 401, ~s({"error":"nope"})))

      assert {:error, {:http_error, 401, body}} =
               OpenAICompatible.stream(provider!(scope), chat_request(), event_collector())

      assert body =~ "nope"
      assert Enum.map(collected_events(), & &1.__struct__) == [StreamEvent.Request]
    end

    test "reports a transport error", %{scope: scope} do
      Req.Test.stub(Mythweaver.AI, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, {:transport_error, _message}} =
               OpenAICompatible.stream(provider!(scope), chat_request(), event_collector())
    end

    test "refuses a chat stream with no messages", %{scope: scope} do
      assert OpenAICompatible.stream(
               provider!(scope),
               %Request{model_id: "gemma-4", mode: :chat, sampler: %SamplerParams{}},
               event_collector()
             ) == {:error, {:invalid_request, :missing_messages}}
    end

    # Only `Request.Text`/`Request.Image` reach the wire: a builder placeholder that was never inlined
    # must fail loudly instead of posting a malformed part.
    test "raises on a leaked image placeholder", %{scope: scope} do
      request = %{
        chat_request()
        | messages: [%Request.Message{role: :user, content: [%AttachmentRef{attachment: %Attachment{}}]}]
      }

      assert_raise FunctionClauseError, fn -> OpenAICompatible.stream(provider!(scope), request, event_collector()) end
    end

    test "asks for prompt progress only on a connection that opted in", %{scope: scope} do
      stub_chunks(@chat_frames)

      assert {:ok, _completion} =
               OpenAICompatible.stream(provider!(scope, %{prompt_progress: true}), chat_request(), event_collector())

      assert [%StreamEvent.Request{body: %{"return_progress" => true}} | _] = collected_events()

      assert {:ok, _completion} = OpenAICompatible.stream(provider!(scope), chat_request(), event_collector())
      assert [%StreamEvent.Request{body: body} | _] = collected_events()
      refute Map.has_key?(body, "return_progress")
    end

    # llama.cpp's shape: a top-level `prompt_progress` on a role-announcement chunk.
    test "reports uncached prompt progress and skips a fully cached prompt", %{scope: scope} do
      progress = fn json ->
        ~s(data: {"choices":[{"finish_reason":null,"index":0,"delta":{"role":"assistant","content":null}}],"prompt_progress":#{json}}\n\n)
      end

      stub_chunks([
        progress.(~s({"total":4096,"cache":1024,"processed":2048,"time_ms":10})),
        progress.(~s({"total":1024,"cache":1024,"processed":1024,"time_ms":1}))
        | @chat_frames
      ])

      assert {:ok, completion} = OpenAICompatible.stream(provider!(scope), chat_request(), event_collector())
      events = collected_events()

      assert [%StreamEvent.PromptProgress{done: 1024, total: 3072}] =
               Enum.filter(events, &match?(%StreamEvent.PromptProgress{}, &1))

      assert completion.text == "pong"
    end

    test "folds tool-call deltas split across chunks into calls in index order", %{scope: scope} do
      frame = fn delta -> ~s(data: {"choices":[{"finish_reason":null,"index":0,"delta":#{delta}}]}\n\n) end

      stub_chunks([
        frame.(
          ~s({"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"list_characters","arguments":""}}]})
        ),
        frame.(~s({"tool_calls":[{"index":0,"function":{"arguments":"{\\"a"}}]})),
        frame.(~s({"tool_calls":[{"index":0,"function":{"arguments":"\\":"}}]})),
        frame.(~s({"tool_calls":[{"index":1,"id":"call_b","function":{"name":"get_character","arguments":"{}"}}]})),
        frame.(~s({"tool_calls":[{"index":0,"function":{"arguments":"1}"}}]})),
        ~s(data: {"choices":[{"finish_reason":"tool_calls","index":0,"delta":{}}]}\n\n),
        "data: [DONE]\n\n"
      ])

      assert {:ok, completion} = OpenAICompatible.stream(provider!(scope), chat_request(), event_collector())

      assert completion.tool_calls == [
               %{id: "call_a", name: "list_characters", arguments: ~s({"a":1})},
               %{id: "call_b", name: "get_character", arguments: "{}"}
             ]

      assert completion.text == ""
      assert completion.finish_reason == "tool_calls"
    end

    test "sends the offered tools, the assistant's calls and the tool results", %{scope: scope} do
      tools = [
        %{
          "type" => "function",
          "function" => %{"name" => "list_characters", "description" => "d", "parameters" => %{"type" => "object"}}
        }
      ]

      request = %{
        chat_request()
        | tools: tools,
          messages: [
            %Request.Message{role: :user, content: "list"},
            %Request.Message{
              role: :assistant,
              content: nil,
              tool_calls: [%{id: "call_a", name: "list_characters", arguments: "{}"}]
            },
            %Request.Message{role: :tool, tool_call_id: "call_a", content: ~s({"total":0})}
          ]
      }

      stub_chunks(@chat_frames)
      assert {:ok, _} = OpenAICompatible.stream(provider!(scope), request, event_collector())
      assert [%StreamEvent.Request{body: body} | _] = collected_events()

      assert body["tools"] == tools

      assert [
               %{"role" => "user"},
               %{
                 "role" => "assistant",
                 "content" => "",
                 "tool_calls" => [
                   %{
                     "id" => "call_a",
                     "type" => "function",
                     "function" => %{"name" => "list_characters", "arguments" => "{}"}
                   }
                 ]
               },
               %{"role" => "tool", "tool_call_id" => "call_a", "content" => ~s({"total":0})}
             ] = body["messages"]
    end

    test "sends no tools key when the request offers none", %{scope: scope} do
      stub_chunks(@chat_frames)
      assert {:ok, completion} = OpenAICompatible.stream(provider!(scope), chat_request(), event_collector())
      assert [%StreamEvent.Request{body: body} | _] = collected_events()
      refute Map.has_key?(body, "tools")
      assert completion.tool_calls == []
    end
  end

  describe "stream/3 text" do
    test "reads usage from the final content frame", %{scope: scope} do
      stub_chunks(@text_frames)

      request = %Request{
        model_id: "gemma-4",
        mode: :text,
        sampler: %SamplerParams{max_tokens: 16},
        prompt: "Count to three: one,"
      }

      assert {:ok, completion} = OpenAICompatible.stream(provider!(scope), request, event_collector())
      assert completion.text == " own own"
      assert completion.reasoning == nil
      assert completion.finish_reason == "length"
      assert completion.total_tokens == 23
      assert completion.completion_tokens == 16
    end

    test "splits inline think tags out of the content", %{scope: scope} do
      frame = fn text, finish ->
        ~s(data: ) <>
          Jason.encode!(%{"choices" => [%{"text" => text, "index" => 0, "finish_reason" => finish}]}) <>
          "\n\n"
      end

      stub_chunks([
        frame.("<think>\nHm", nil),
        frame.("m</think>\n", nil),
        frame.("Hi", nil),
        ~s(data: {"choices":[{"text":"","index":0,"finish_reason":"stop"}],"usage":{"completion_tokens":5,"prompt_tokens":3,"total_tokens":8}}\n\n)
      ])

      request = %Request{
        model_id: "qwen-3.6",
        mode: :text,
        sampler: %SamplerParams{},
        prompt: "Say hi.",
        reasoning_tags: {"<think>", "</think>"}
      }

      assert {:ok, completion} = OpenAICompatible.stream(provider!(scope), request, event_collector())

      assert Enum.map(collected_events(), & &1.__struct__) == [
               StreamEvent.Request,
               StreamEvent.Reasoning,
               StreamEvent.Reasoning,
               StreamEvent.Delta,
               StreamEvent.Done
             ]

      assert completion.reasoning == "Hmm"
      assert completion.text == "Hi"
    end

    test "ends the reply at a stop string the backend ignored and drops the rest", %{scope: scope} do
      frame = fn text ->
        ~s(data: ) <> Jason.encode!(%{"choices" => [%{"text" => text, "index" => 0, "finish_reason" => nil}]}) <> "\n\n"
      end

      # "\nBo" could still become "\nBob:", so it is held, then dropped with everything after it.
      stub_chunks([
        frame.("Alice waves.\nBo"),
        frame.("b: Hi!"),
        frame.(" More."),
        ~s(data: {"choices":[{"text":"","index":0,"finish_reason":"length"}]}\n\n)
      ])

      request = %Request{
        model_id: "gemma-4",
        mode: :text,
        sampler: %SamplerParams{},
        prompt: "Alice:",
        stop: ["\nBob:"]
      }

      assert {:ok, completion} = OpenAICompatible.stream(provider!(scope), request, event_collector())

      events = collected_events()
      deltas = for %StreamEvent.Delta{text: text} <- events, do: text
      assert Enum.join(deltas) == "Alice waves."
      assert List.last(events) == %StreamEvent.Done{finish_reason: "stop"}
      assert completion.text == "Alice waves."
      assert completion.finish_reason == "stop"
    end

    test "releases a held tail that never became a stop string", %{scope: scope} do
      frame = fn text, finish ->
        ~s(data: ) <>
          Jason.encode!(%{"choices" => [%{"text" => text, "index" => 0, "finish_reason" => finish}]}) <> "\n\n"
      end

      stub_chunks([frame.("Hi.\nBo", nil), frame.("", "length")])

      request = %Request{
        model_id: "gemma-4",
        mode: :text,
        sampler: %SamplerParams{},
        prompt: "Alice:",
        stop: ["\nBob:"]
      }

      assert {:ok, completion} = OpenAICompatible.stream(provider!(scope), request, event_collector())
      assert completion.text == "Hi.\nBo"
      assert completion.finish_reason == "length"
    end

    test "refuses a text stream with no prompt", %{scope: scope} do
      assert OpenAICompatible.stream(
               provider!(scope),
               %Request{model_id: "gemma-4", mode: :text, sampler: %SamplerParams{}},
               event_collector()
             ) == {:error, {:invalid_request, :missing_prompt}}
    end
  end
end
