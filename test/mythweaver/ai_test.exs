defmodule Mythweaver.AITest do
  use Mythweaver.DataCase

  alias Mythweaver.AI
  alias Mythweaver.AI.Completion
  alias Mythweaver.AI.Embedding
  alias Mythweaver.AI.Model
  alias Mythweaver.AI.Provider
  alias Mythweaver.AI.ProviderModel
  alias Mythweaver.AI.Request
  alias Mythweaver.AI.SamplerParams
  alias Mythweaver.AI.StreamEvent
  alias Mythweaver.Lore.EntryEmbedding
  alias Mythweaver.Permissions
  alias Mythweaver.Permissions.Group
  alias Mythweaver.Schema
  alias Mythweaver.Settings

  setup do
    %{scope: scope!()}
  end

  # A trimmed live llama.cpp stream: reasoning deltas, content deltas, the finish-reason frame, the
  # separate empty-`choices` usage frame, then the non-JSON sentinel.
  @chat_frames [
    ~s(data: {"choices":[{"finish_reason":null,"index":0,"delta":{"role":"assistant","content":null}}],"model":"/models/gemma-4.gguf"}\n\n),
    ~s(data: {"choices":[{"finish_reason":null,"index":0,"delta":{"reasoning_content":"The"}}]}\n\n),
    ~s(data: {"choices":[{"finish_reason":null,"index":0,"delta":{"content":"po"}}]}\n\n),
    ~s(data: {"choices":[{"finish_reason":null,"index":0,"delta":{"content":"ng"}}]}\n\n),
    ~s(data: {"choices":[{"finish_reason":"stop","index":0,"delta":{}}]}\n\n),
    ~s(data: {"choices":[],"usage":{"completion_tokens":31,"prompt_tokens":18,"total_tokens":49}}\n\n),
    "data: [DONE]\n\n"
  ]

  # Each frame goes out as its own HTTP chunk, so the fold sees real frame/chunk misalignment.
  defp stub_chat_stream do
    Req.Test.stub(Mythweaver.AI, fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)

      Enum.reduce(@chat_frames, conn, fn frame, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, frame)
        conn
      end)
    end)
  end

  defp stub_models(entries) do
    Req.Test.stub(Mythweaver.AI, &Req.Test.json(&1, %{"data" => entries}))
  end

  defp provider!(scope, name, attrs \\ %{}, opts \\ []) do
    {:ok, provider} =
      AI.create_provider(
        scope,
        Map.merge(
          %{name: name, adapter: :openai_compatible, base_url: "http://localhost:8080/v1"},
          attrs
        ),
        opts
      )

    provider
  end

  defp model!(scope, name, attrs \\ %{}, opts \\ []) do
    {:ok, model} = AI.create_model(scope, Map.merge(%{name: name, api_model_id: "gemma-4"}, attrs), opts)
    model
  end

  defp group!(name) do
    Repo.insert!(Group.changeset(%Group{}, %{name: "#{name} #{System.unique_integer([:positive])}"}))
  end

  defp listed?(scope, model), do: model.id in Enum.map(AI.list_models(scope), & &1.id)

  defp picks(model, count) do
    Enum.map(1..count, fn _i ->
      {:ok, link} = AI.next_provider_model(model, model.user_id)
      link.provider.name
    end)
  end

  defp tally(model, count), do: model |> picks(count) |> Enum.frequencies()

  # The longest stretch one provider served back to back. A deadline schedule interleaves, so this
  # stays tiny; a weighted random draw clumps 8-11 deep.
  defp longest_run(picks) do
    picks
    |> Enum.chunk_by(& &1)
    |> Enum.map(&length/1)
    |> Enum.max()
  end

  describe "caption models" do
    test "a caption model must be a chat model that takes images, audio or video, and not the model itself",
         %{scope: scope} do
      vision = model!(scope, "Vision", %{supports_images: true}, site: true)
      listener = model!(scope, "Listener", %{supports_audio: true}, site: true)
      text_vision = model!(scope, "Text vision", %{supports_images: true, completion_mode: :text}, site: true)
      blind = model!(scope, "Blind", %{}, site: true)

      assert {:ok, %{caption_model_id: id}} = AI.update_model(scope, blind, %{caption_model_id: vision.id})
      assert id == vision.id
      assert {:ok, %{caption_model_id: id}} = AI.update_model(scope, blind, %{caption_model_id: listener.id})
      assert id == listener.id

      assert {:error, cs} = AI.update_model(scope, blind, %{caption_model_id: text_vision.id})
      assert "must be a chat model that supports images, audio or video" in errors_on(cs).caption_model_id

      assert {:error, cs} = AI.update_model(scope, vision, %{caption_model_id: vision.id})
      assert "can't caption for itself" in errors_on(cs).caption_model_id

      assert AI.caption_model_options(scope, nil, vision.id) == [{listener.name, listener.id}]

      assert AI.caption_model_options(scope, nil, blind.id) ==
               Enum.sort([{vision.name, vision.id}, {listener.name, listener.id}])
    end
  end

  describe "next_provider_model/3" do
    test "rotates through every linked provider before repeating one", %{scope: scope} do
      model = model!(scope, "Gemma 4 31B")
      providers = Enum.map(["Alpha", "Beta", "Gamma"], &provider!(scope, &1))
      Enum.each(providers, &({:ok, _} = AI.link_model(scope, &1, model)))

      picks =
        Enum.map(1..5, fn _i ->
          {:ok, link} = AI.next_provider_model(model, model.user_id)
          link.provider.name
        end)

      assert Enum.sort(Enum.take(picks, 3)) == ["Alpha", "Beta", "Gamma"]
      assert Enum.at(picks, 3) == Enum.at(picks, 0)
      assert Enum.at(picks, 4) == Enum.at(picks, 1)
    end

    test "prefers a lower-priority-number provider over round-robin", %{scope: scope} do
      model = model!(scope, "Gemma 4 31B")
      cheap = provider!(scope, "Local", %{priority: 1})
      paid = provider!(scope, "Hosted", %{priority: 3})
      {:ok, _} = AI.link_model(scope, cheap, model)
      {:ok, _} = AI.link_model(scope, paid, model)

      names =
        Enum.map(1..3, fn _i ->
          {:ok, link} = AI.next_provider_model(model, model.user_id)
          link.provider.name
        end)

      assert names == ["Local", "Local", "Local"]
    end

    test "concurrent selections never pick the same link", %{scope: scope} do
      model = model!(scope, "Gemma 4 31B")
      {:ok, _} = AI.link_model(scope, provider!(scope, "Alpha"), model)
      {:ok, _} = AI.link_model(scope, provider!(scope, "Beta"), model)

      ids =
        1..2
        |> Task.async_stream(fn _i -> AI.next_provider_model(model, model.user_id) end, max_concurrency: 2)
        |> Enum.map(fn {:ok, {:ok, link}} -> link.id end)

      assert ids |> Enum.uniq() |> length() == 2
    end

    test "records the use on the link it returns", %{scope: scope} do
      model = model!(scope, "Gemma 4 31B")
      provider = provider!(scope, "Local")
      {:ok, _} = AI.link_model(scope, provider, model)

      {:ok, first} = AI.next_provider_model(model, model.user_id)
      assert first.use_count == 1
      assert %DateTime{} = first.last_used_at

      {:ok, second} = AI.next_provider_model(model, model.user_id)
      assert second.use_count == 2
    end

    test "skips a disabled link and a disabled provider", %{scope: scope} do
      model = model!(scope, "Gemma 4 31B")
      by_link = provider!(scope, "DisabledLink")
      by_provider = provider!(scope, "DisabledProvider")

      {:ok, link} = AI.link_model(scope, by_link, model)
      {:ok, _} = AI.update_link(scope, link, %{enabled: false})

      {:ok, _} = AI.link_model(scope, by_provider, model)
      {:ok, _} = AI.update_provider(scope, by_provider, %{enabled: false})

      assert AI.next_provider_model(model, model.user_id) == {:error, :no_provider}
    end

    test "refuses a model with no links at all", %{scope: scope} do
      assert AI.next_provider_model(model!(scope, "Orphan"), scope.user.id) == {:error, :no_provider}
    end

    test "except_provider_ids leaves those providers out of selection", %{scope: scope} do
      model = model!(scope, "Gemma 4")
      [busy, idle] = Enum.map(["Busy", "Idle"], &provider!(scope, &1))
      Enum.each([busy, idle], &({:ok, _} = AI.link_model(scope, &1, model)))

      for _i <- 1..3 do
        assert {:ok, link} = AI.next_provider_model(model, model.user_id, except_provider_ids: [busy.id])
        assert link.provider_id == idle.id
      end

      assert AI.next_provider_model(model, model.user_id, except_provider_ids: [busy.id, idle.id]) ==
               {:error, :no_provider}
    end

    test "splits traffic exactly in proportion to weight over a full cycle", %{scope: scope} do
      model = model!(scope, "Gemma 4 31B")

      for {name, weight} <- [{"W3", 3}, {"W2", 2}, {"W1", 1}] do
        {:ok, _} = AI.link_model(scope, provider!(scope, name), model, %{weight: weight})
      end

      assert tally(model, 60) == %{"W3" => 30, "W2" => 20, "W1" => 10}
    end

    test "serves the lowest-weight link inside a short window without clumping", %{scope: scope} do
      model = model!(scope, "Gemma 4 31B")

      for {name, weight} <- [{"W3", 3}, {"W2", 2}, {"W1", 1}] do
        {:ok, _} = AI.link_model(scope, provider!(scope, name), model, %{weight: weight})
      end

      picks = picks(model, 12)

      assert Enum.frequencies(picks) == %{"W3" => 6, "W2" => 4, "W1" => 2}
      assert longest_run(picks) <= 2
    end

    test "a newly linked provider joins mid-rotation instead of monopolizing", %{scope: scope} do
      model = model!(scope, "Gemma 4 31B")
      {:ok, _} = AI.link_model(scope, provider!(scope, "W3"), model, %{weight: 3})
      {:ok, _} = AI.link_model(scope, provider!(scope, "W2"), model, %{weight: 2})

      _ = picks(model, 20)
      {:ok, _} = AI.link_model(scope, provider!(scope, "Joiner"), model, %{weight: 1})

      assert tally(model, 12) == %{"W3" => 6, "W2" => 4, "Joiner" => 2}
    end

    test "a re-enabled link rejoins mid-rotation instead of monopolizing", %{scope: scope} do
      model = model!(scope, "Gemma 4 31B")
      {:ok, _} = AI.link_model(scope, provider!(scope, "W3"), model, %{weight: 3})
      {:ok, _} = AI.link_model(scope, provider!(scope, "W2"), model, %{weight: 2})
      {:ok, idle} = AI.link_model(scope, provider!(scope, "W1"), model, %{weight: 1})

      {:ok, idle} = AI.update_link(scope, idle, %{enabled: false})
      _ = picks(model, 20)
      {:ok, _} = AI.update_link(scope, idle, %{enabled: true})

      assert tally(model, 12) == %{"W3" => 6, "W2" => 4, "W1" => 2}
    end

    test "a weight change takes effect on the very next call", %{scope: scope} do
      model = model!(scope, "Gemma 4 31B")
      {:ok, starved} = AI.link_model(scope, provider!(scope, "Starved"), model, %{weight: 1})
      {:ok, _} = AI.link_model(scope, provider!(scope, "Favoured"), model, %{weight: 20})

      assert tally(model, 24) == %{"Starved" => 2, "Favoured" => 22}

      {:ok, _} = AI.update_link(scope, starved, %{weight: 20})

      assert tally(model, 20) == %{"Starved" => 10, "Favoured" => 10}
    end
  end

  describe "links" do
    test "a duplicate link is a changeset error, not a raise", %{scope: scope} do
      model = model!(scope, "Gemma 4 31B")
      provider = provider!(scope, "Local")

      {:ok, _} = AI.link_model(scope, provider, model)
      assert {:error, changeset} = AI.link_model(scope, provider, model)
      assert [_] = errors_on(changeset).ai_model_id
    end
  end

  describe "discovery" do
    test "annotates a brand-new wire id as unknown", %{scope: scope} do
      stub_models([%{"id" => "gemma-4", "name" => "Gemma 4 31B"}])

      assert {:ok, [entry]} = AI.discover_models(scope, provider!(scope, "Local"))
      assert entry == %{id: "gemma-4", name: "Gemma 4 31B", attrs: %{}, model_id: nil, linked?: false}
    end

    test "falls back to the wire id when the provider sends no name", %{scope: scope} do
      stub_models([%{"id" => "gemma-4"}])

      assert {:ok, [entry]} = AI.discover_models(scope, provider!(scope, "Local"))
      assert entry.name == "gemma-4"
    end

    test "marks an existing local model as known but unlinked", %{scope: scope} do
      model = model!(scope, "Gemma 4 31B", %{api_model_id: "gemma-4"})
      stub_models([%{"id" => "gemma-4"}])

      assert {:ok, [entry]} = AI.discover_models(scope, provider!(scope, "Local"))
      assert entry.model_id == model.id
      refute entry.linked?
    end

    test "marks an already-linked model as linked", %{scope: scope} do
      model = model!(scope, "Gemma 4 31B", %{api_model_id: "gemma-4"})
      provider = provider!(scope, "Local")
      {:ok, _link} = AI.link_model(scope, provider, model)
      stub_models([%{"id" => "gemma-4"}])

      assert {:ok, [entry]} = AI.discover_models(scope, provider)
      assert entry.linked?
    end

    test "passes the adapter's error through untouched", %{scope: scope} do
      Req.Test.stub(Mythweaver.AI, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, ~s({"error":"boom"}))
      end)

      assert {:error, {:http_error, 500, _body}} = AI.discover_models(scope, provider!(scope, "Local"))
    end

    test "create_discovered_model/2 creates the model and the link together", %{scope: scope} do
      provider = provider!(scope, "Local")

      assert {:ok, model} =
               AI.create_discovered_model(scope, provider, %{
                 id: "gemma-4",
                 name: "Gemma 4 31B",
                 attrs: %{}
               })

      assert model.api_model_id == "gemma-4"
      assert model.completion_mode == :chat

      assert [link] = AI.get_provider!(provider.id).provider_models
      assert link.ai_model_id == model.id
    end

    test "create_discovered_model/2 persists the fields the payload advertised", %{scope: scope} do
      stub_models([
        %{
          "id" => "anthropic/claude-fable-5.1",
          "name" => "Claude Fable 5.1",
          "description" => "Frontier role-play model.",
          "context_length" => 1_000_000,
          "top_provider" => %{"max_completion_tokens" => 128_000},
          "pricing" => %{"prompt" => "0.000000075", "completion" => "0.00000057552"},
          "architecture" => %{"input_modalities" => ["text", "image"]},
          "supported_parameters" => ["tools", "include_reasoning"]
        }
      ])

      provider = provider!(scope, "OpenRouter")
      {:ok, [entry]} = AI.discover_models(scope, provider)

      assert {:ok, model} = AI.create_discovered_model(scope, provider, entry)
      assert model.name == "Claude Fable 5.1"
      assert model.api_model_id == "anthropic/claude-fable-5.1"
      assert model.context_window == 1_000_000
      assert Decimal.equal?(model.prompt_cost_per_mtok, Decimal.new("0.075"))
      assert Decimal.equal?(model.completion_cost_per_mtok, Decimal.new("0.57552"))
      assert model.supports_images
      assert model.supports_tools
      assert model.supports_thinking
      # The payload advertised a `description`; `notes` is user-authored and stays empty.
      assert model.notes == nil
    end

    # The `ai_models_context_window_positive` check constraint raises `Postgrex.Error` rather than
    # producing a changeset error, so a zero-valued advertised context must never reach the insert.
    test "create_discovered_model/2 leaves a non-positive advertised context unset", %{scope: scope} do
      stub_models([%{"id" => "x", "max_model_len" => 0, "meta" => %{"n_ctx_train" => 0}}])

      provider = provider!(scope, "Local")
      {:ok, [entry]} = AI.discover_models(scope, provider)

      assert {:ok, model} = AI.create_discovered_model(scope, provider, entry)
      assert model.context_window == nil
    end

    test "a name collision rolls back the link too", %{scope: scope} do
      provider = provider!(scope, "Local")
      _existing = model!(scope, "Gemma 4 31B", %{api_model_id: "other-wire-id"})

      assert {:error, changeset} =
               AI.create_discovered_model(scope, provider, %{
                 id: "gemma-4",
                 name: "Gemma 4 31B",
                 attrs: %{}
               })

      assert errors_on(changeset).name == ["has already been taken"]
      assert length(AI.list_models(scope)) == 1
      assert AI.get_provider!(provider.id).provider_models == []
    end

    test "link_discovered_model/2 reports a missing model", %{scope: scope} do
      assert AI.link_discovered_model(scope, provider!(scope, "Local"), Schema.generate_id()) ==
               {:error, :not_found}
    end
  end

  describe "connection tests" do
    test "check_provider/1 tests an unsaved connection and counts what /models advertises", %{scope: scope} do
      test = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        send(test, {:request, conn.method, conn.request_path, Plug.Conn.get_req_header(conn, "authorization")})
        Req.Test.json(conn, %{"data" => [%{"id" => "gemma-4"}, %{"id" => "qwen-3"}]})
      end)

      provider =
        %Provider{}
        |> AI.change_provider(%{name: "Draft", base_url: "http://draft:8080/v1", api_key: "sk-draft"})
        |> Ecto.Changeset.apply_changes()

      assert AI.check_provider(scope, provider) == {:ok, 2}
      assert_receive {:request, "GET", "/v1/models", ["Bearer sk-draft"]}
      assert AI.list_providers(scope) == []
    end

    test "check_provider/1 fails on a non-200 status", %{scope: scope} do
      Req.Test.stub(Mythweaver.AI, &Plug.Conn.send_resp(&1, 401, ""))

      assert {:error, {:http_error, 401, _body}} = AI.check_provider(scope, provider!(scope, "Local"))
    end

    test "test_link/1 sends a capped Hi to that link without thinking or recording a use", %{scope: scope} do
      test = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:request, conn.request_path, Jason.decode!(raw)})
        Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "Hello!"}, "finish_reason" => "stop"}]})
      end)

      model = model!(scope, "Gemma 4 31B", %{sampler: %{max_tokens: 4096, thinking: :high, temperature: 0.7}})
      provider = provider!(scope, "OpenRouter", %{thinking_dialect: :openrouter})

      # Disabled, so weighted selection would never pick it; a test goes to it regardless.
      {:ok, link} = AI.link_model(scope, provider, model, %{api_model_id_override: "google/gemma-4", enabled: false})

      assert {:ok, %Completion{text: "Hello!"}} = AI.test_link(scope, AI.get_link(link.id))

      assert_receive {:request, "/v1/chat/completions", body}
      assert body["model"] == "google/gemma-4"
      assert body["messages"] == [%{"role" => "user", "content" => "Hi"}]
      assert body["max_tokens"] == 16
      assert body["temperature"] == 0.7
      refute Map.has_key?(body, "reasoning")

      assert AI.get_link(link.id).use_count == 0
    end
  end

  describe "embedding models" do
    # Each text becomes `[1.0, 0.0]` if it mentions a dragon, else `[0.0, 1.0]`, answered in reverse
    # index order so input order must be restored.
    defp stub_embeddings do
      test = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        send(test, {:embed, conn.request_path, body})

        data =
          body["input"]
          |> Enum.with_index()
          |> Enum.map(fn {text, i} ->
            vector = if text =~ ~r/dragon/i, do: [1.0, 0.0], else: [0, 1]
            %{"index" => i, "embedding" => vector}
          end)
          |> Enum.reverse()

        Req.Test.json(conn, %{"data" => data, "usage" => %{"prompt_tokens" => 7}})
      end)
    end

    defp embedder!(scope) do
      model = model!(scope, "Embedder", %{api_model_id: "embed-1", completion_mode: :embedding})
      {:ok, _link} = AI.link_model(scope, provider!(scope, "Local"), model)
      AI.get_model!(model.id)
    end

    test "embed/2 returns vectors in input order", %{scope: scope} do
      stub_embeddings()

      assert {:ok, %Embedding{vectors: vectors, usage: %{"prompt_tokens" => 7}}, %ProviderModel{}} =
               AI.embed(embedder!(scope), scope.user.id, ["A dragon lands", "Rain falls", "Dragons"])

      assert vectors == [[1.0, 0.0], [0.0, 1.0], [1.0, 0.0]]
      assert_receive {:embed, "/v1/embeddings", %{"model" => "embed-1", "input" => ["A dragon lands", _, _]} = body}
      refute Map.has_key?(body, "encoding_format")
    end

    test "embed/2 passes an HTTP error through", %{scope: scope} do
      Req.Test.stub(Mythweaver.AI, &Plug.Conn.send_resp(&1, 401, ""))
      assert {:error, _} = AI.embed(embedder!(scope), scope.user.id, ["Hi"])
    end

    test "embed/2 refuses a chat model", %{scope: scope} do
      assert AI.embed(model!(scope, "Chat"), scope.user.id, ["Hi"]) ==
               {:error, {:invalid_request, :not_embedding_model}}
    end

    test "list_models/1 lists only generating models; embedding and classifier models list apart", %{scope: scope} do
      chat = model!(scope, "Chat")
      embedder = embedder!(scope)
      classifier = classifier!(scope)

      assert Enum.map(AI.list_models(scope), & &1.id) == [chat.id]
      assert Enum.map(AI.list_embedding_models(scope), & &1.id) == [embedder.id]
      assert Enum.map(AI.list_classifier_models(scope), & &1.id) == [classifier.id]
    end

    defp classifier!(scope) do
      model = model!(scope, "Emotions", %{api_model_id: "go-emotions", completion_mode: :classifier})
      {:ok, _link} = AI.link_model(scope, provider!(scope, "Classifiers"), model)
      AI.get_model!(model.id)
    end

    test "classify/2 asks for raw logits and returns them per text", %{scope: scope} do
      test = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:classify, conn.request_path, Jason.decode!(raw)})

        Req.Test.json(conn, %{
          "data" => [%{"index" => 0, "embedding" => [2.5, -3.0]}],
          "usage" => %{"prompt_tokens" => 4}
        })
      end)

      # A model layer can't turn llama-server's normalization back on.
      {:ok, classifier} = AI.update_model(scope, classifier!(scope), %{extra_body: %{"embd_normalize" => 2}})

      assert {:ok, %Embedding{vectors: [[2.5, -3.0]]}, %ProviderModel{}} =
               AI.classify(classifier, scope.user.id, ["Yay"])

      assert_receive {:classify, "/v1/embeddings",
                      %{"model" => "go-emotions", "input" => ["Yay"], "embd_normalize" => -1}}

      assert AI.classify(model!(scope, "Chat"), scope.user.id, ["Hi"]) ==
               {:error, {:invalid_request, :not_classifier_model}}
    end

    test "the Expressions setting lets a model move between chat and classifier, not to embedding", %{scope: scope} do
      classifier = classifier!(scope)
      :ok = Settings.put(scope, :user, "expressions.classifier_model", classifier.id)

      assert AI.mode_switch_blockers(classifier, :chat) == []
      assert AI.mode_switch_blockers(classifier, :embedding) == ["the Classifier model setting"]

      assert {:error, cs} = AI.update_model(scope, classifier, %{completion_mode: :embedding})

      assert errors_on(cs).completion_mode == [
               "can't change to this mode while it is used by the Classifier model setting"
             ]
    end

    test "an unused model switches to and from embedding", %{scope: scope} do
      assert {:ok, %Model{completion_mode: :embedding} = model} =
               AI.update_model(scope, model!(scope, "Chat"), %{completion_mode: :embedding})

      assert {:ok, %Model{completion_mode: :text}} = AI.update_model(scope, model, %{completion_mode: :text})
    end

    test "a switch is refused, naming what uses the model as the kind it leaves", %{scope: scope} do
      chat_model = model!(scope, "Chat")
      [ann, bot] = for name <- ["Ann", "Bot"], do: elem(Mythweaver.Characters.create_character(scope, %{name: name}), 1)

      {:ok, _chat} =
        Mythweaver.Chats.create_chat(scope, %{
          name: "c",
          participants: [%{character_id: ann.id}, %{character_id: bot.id}],
          player_character_id: ann.id,
          ai_model_id: chat_model.id
        })

      assert {:error, cs} = AI.update_model(scope, chat_model, %{completion_mode: :embedding})

      assert errors_on(cs).completion_mode ==
               ["can't change to this mode while it is used by 1 chat"]

      assert AI.mode_switch_blockers(chat_model, :classifier) == ["1 chat"]

      embedder = embedder!(scope)
      :ok = Settings.put(scope, :user, "lore.embedding_model", embedder.id)
      assert AI.mode_switch_blockers(embedder, :chat) == ["the Embedding model setting"]
      assert {:error, _} = AI.update_model(scope, embedder, %{completion_mode: :chat})
    end

    test "an assistant thread naming a chat model blocks its switch to text, not text's to chat", %{scope: scope} do
      chat_model = model!(scope, "Chat")
      {:ok, _thread} = Mythweaver.Assistant.create_chat(scope, %{ai_model_id: chat_model.id})

      assert AI.mode_switch_blockers(chat_model, :text) == ["1 Mythweaver conversation"]

      text_model = model!(scope, "Text", %{completion_mode: :text})
      assert AI.mode_switch_blockers(text_model, :chat) == []
    end

    test "leaving embedding deletes the vectors the model made", %{scope: scope} do
      embedder = embedder!(scope)

      {:ok, entry} =
        Mythweaver.Lore.create_entry(scope, %{name: "E", content: "A dragon", activation: :vector, keywords: []}, [])

      Repo.insert!(%EntryEmbedding{
        lore_entry_id: entry.id,
        ai_model_id: embedder.id,
        content_hash: :crypto.hash(:sha256, "A dragon"),
        embedding: Pgvector.new([1.0, 0.0])
      })

      assert {:ok, %Model{completion_mode: :chat}} = AI.update_model(scope, embedder, %{completion_mode: :chat})
      assert Repo.aggregate(EntryEmbedding, :count) == 0
    end

    test "test_link/2 embeds Hi on an embedding link", %{scope: scope} do
      stub_embeddings()
      [link] = embedder!(scope).provider_models

      assert {:ok, %Embedding{vectors: [[+0.0, 1.0]]}} = AI.test_link(scope, AI.get_link(link.id))
      assert_receive {:embed, "/v1/embeddings", %{"input" => ["Hi"]}}
    end

    test "discovery adds OpenRouter's embedding listing, deduplicated", %{scope: scope} do
      chat_entry = %{"id" => "m/chat"}

      embed_entry = %{
        "id" => "m/embed",
        "architecture" => %{"output_modalities" => ["embeddings"]},
        "pricing" => %{"prompt" => "0.00000002"}
      }

      Req.Test.stub(Mythweaver.AI, fn conn ->
        case conn.query_string do
          "output_modalities=embeddings" -> Req.Test.json(conn, %{"data" => [embed_entry, chat_entry]})
          "" -> Req.Test.json(conn, %{"data" => [chat_entry]})
        end
      end)

      provider = provider!(scope, "OpenRouter")
      assert {:ok, entries} = AI.discover_models(scope, provider)
      assert Enum.map(entries, & &1.id) == ["m/chat", "m/embed"]

      [chat, embed] = entries
      assert {:ok, %Model{completion_mode: :embedding} = model} = AI.create_discovered_model(scope, provider, embed)
      assert Decimal.equal?(model.prompt_cost_per_mtok, Decimal.new("0.02"))
      assert {:ok, %Model{completion_mode: :chat}} = AI.create_discovered_model(scope, provider, chat)
    end

    test "discovery ignores a failing embedding listing", %{scope: scope} do
      Req.Test.stub(Mythweaver.AI, fn conn ->
        case conn.query_string do
          "" -> Req.Test.json(conn, %{"data" => [%{"id" => "m/chat"}]})
          _embeddings -> Plug.Conn.send_resp(conn, 404, "")
        end
      end)

      assert {:ok, [%{id: "m/chat"}]} = AI.discover_models(scope, provider!(scope, "Local"))
    end
  end

  describe "effective_model_id/1" do
    test "prefers the per-provider override over the model's own id", %{scope: scope} do
      model = model!(scope, "Gemma 4 31B")
      provider = provider!(scope, "OpenRouter")

      {:ok, link} = AI.link_model(scope, provider, model, %{api_model_id_override: "google/gemma-4-31b"})
      link = Repo.preload(link, :model)

      assert ProviderModel.effective_model_id(link) == "google/gemma-4-31b"
    end

    test "falls back to the model's id when no override is set", %{scope: scope} do
      model = model!(scope, "Gemma 4 31B")
      {:ok, link} = AI.link_model(scope, provider!(scope, "Local"), model)

      assert ProviderModel.effective_model_id(Repo.preload(link, :model)) == "gemma-4"
    end
  end

  describe "sampler params" do
    test "round-trip through the database preserves typed fields and extra", %{scope: scope} do
      {:ok, model} =
        AI.create_model(scope, %{
          name: "Skyfall",
          api_model_id: "skyfall-32b",
          sampler: %{
            temperature: 0.85,
            top_k: 40,
            stop_sequences: ["</s>"],
            extra: %{"dry_multiplier" => 0.8}
          }
        })

      reloaded = AI.get_model!(model.id)

      assert reloaded.sampler.temperature == 0.85
      assert reloaded.sampler.top_k == 40
      assert reloaded.sampler.stop_sequences == ["</s>"]
      assert reloaded.sampler.extra == %{"dry_multiplier" => 0.8}
    end

    test "a model with no sampler still exposes an all-defaults struct", %{scope: scope} do
      model = AI.get_model!(model!(scope, "Bare").id)

      assert %SamplerParams{temperature: nil, stop_sequences: [], extra: %{}} = model.sampler
    end

    test "an out-of-range sampler value is rejected on the embed", %{scope: scope} do
      assert {:error, changeset} =
               AI.create_model(scope, %{name: "Bad", api_model_id: "x", sampler: %{temperature: 9.0}})

      assert [_message] = errors_on(changeset).sampler.temperature
    end

    test "a nested map in extra is rejected", %{scope: scope} do
      assert {:error, changeset} =
               AI.create_model(scope, %{
                 name: "Bad",
                 api_model_id: "x",
                 sampler: %{extra: %{"nested" => %{"a" => 1}}}
               })

      assert [_] = errors_on(changeset).sampler.extra
    end

    test "reasoning tags must be set as a pair", %{scope: scope} do
      assert {:error, changeset} =
               AI.create_model(scope, %{name: "Half", api_model_id: "x", reasoning_prefix: "<think>"})

      assert [_] = errors_on(changeset).reasoning_suffix

      assert {:ok, model} =
               AI.create_model(scope, %{
                 name: "Both",
                 api_model_id: "x",
                 reasoning_prefix: "<think>",
                 reasoning_suffix: "</think>"
               })

      assert Model.reasoning_tags(model) == {"<think>", "</think>"}
    end

    test "tokenizer must be a Hugging Face repo id", %{scope: scope} do
      assert {:error, changeset} = AI.create_model(scope, %{name: "Bad", api_model_id: "x", tokenizer: "not a repo"})
      assert [_] = errors_on(changeset).tokenizer

      assert {:ok, %{tokenizer: "Qwen/Qwen3-8B"}} =
               AI.create_model(scope, %{name: "Qwen", api_model_id: "x", tokenizer: "Qwen/Qwen3-8B"})
    end

    test "a pasted Hugging Face page URL saves as its repo id", %{scope: scope} do
      assert {:ok, %{tokenizer: "Qwen/Qwen3-8B"}} =
               AI.create_model(scope, %{
                 name: "Qwen URL",
                 api_model_id: "x",
                 tokenizer: "https://huggingface.co/Qwen/Qwen3-8B/blob/main/README.md"
               })
    end
  end

  describe "providers" do
    test "a trailing slash on base_url is normalized away", %{scope: scope} do
      assert provider!(scope, "Local", %{base_url: "http://localhost:8080/v1/"}).base_url ==
               "http://localhost:8080/v1"
    end

    test "a base_url without a scheme is rejected", %{scope: scope} do
      assert {:error, changeset} =
               AI.create_provider(scope, %{name: "Bad", base_url: "localhost:8080/v1"})

      assert [_] = errors_on(changeset).base_url
    end

    test "a non-scalar extra_header is rejected", %{scope: scope} do
      assert {:error, changeset} =
               AI.create_provider(scope, %{
                 name: "Bad",
                 base_url: "http://localhost:8080",
                 extra_headers: %{"x" => %{"nested" => true}}
               })

      assert [_] = errors_on(changeset).extra_headers
    end

    test "a nested extra_body is accepted", %{scope: scope} do
      assert {:ok, provider} =
               AI.create_provider(scope, %{
                 name: "Nested",
                 base_url: "http://localhost:8080",
                 extra_body: %{"chat_template_kwargs" => %{"enable_thinking" => false}}
               })

      assert provider.extra_body == %{"chat_template_kwargs" => %{"enable_thinking" => false}}
    end

    test "a non-JSON model extra_body is rejected", %{scope: scope} do
      assert {:error, changeset} =
               AI.create_model(scope, %{name: "Bad", api_model_id: "x", extra_body: %{"k" => {:tuple}}})

      assert [_] = errors_on(changeset).extra_body
    end

    test "priority outside 1..5 is rejected", %{scope: scope} do
      assert {:error, changeset} =
               AI.create_provider(scope, %{
                 name: "Bad",
                 base_url: "http://localhost:8080",
                 priority: 9
               })

      assert [_message] = errors_on(changeset).priority
    end

    test "listing orders by name, not priority", %{scope: scope} do
      provider!(scope, "Zed", %{priority: 1})
      provider!(scope, "beta", %{priority: 3})
      provider!(scope, "Alpha", %{priority: 3})

      assert Enum.map(AI.list_providers(scope), & &1.name) == ["Alpha", "beta", "Zed"]
    end
  end

  describe "stream/3" do
    setup do
      stub_chat_stream()
      :ok
    end

    test "returns the assembled completion and the link that served it", %{scope: scope} do
      provider = provider!(scope, "Local")
      model = model!(scope, "Gemma 4")
      {:ok, _link} = AI.link_model(scope, provider, model)

      test_pid = self()

      assert {:ok, completion, link} =
               AI.stream(
                 model,
                 model.user_id,
                 %{messages: [%Request.Message{role: :user, content: "ping"}]},
                 fn event ->
                   send(test_pid, {:event, event})
                 end
               )

      assert completion.text == "pong"
      assert completion.total_tokens == 49
      assert link.provider_id == provider.id
      assert link.use_count == 1

      assert_received {:event, %StreamEvent.Delta{text: "po"}}
      assert_received {:event, %StreamEvent.Delta{text: "ng"}}
      assert_received {:event, %StreamEvent.Done{finish_reason: "stop"}}
    end

    test "passes the selection refusal straight through", %{scope: scope} do
      assert AI.stream(
               model!(scope, "Orphan"),
               scope.user.id,
               %{messages: [%Request.Message{role: :user, content: "ping"}]},
               fn _event ->
                 :ok
               end
             ) == {:error, :no_provider}
    end

    test "input :sampler overrides the model's sampler and input :extra_body merges last", %{scope: scope} do
      model = model!(scope, "Gemma 4", %{sampler: %{temperature: 0.7, max_tokens: 4096}})

      {:ok, _link} =
        AI.link_model(scope, provider!(scope, "Local"), model, %{extra_body: %{"a" => 1, "nested" => %{"x" => 1}}})

      test_pid = self()

      input = %{
        messages: [%Request.Message{role: :user, content: "ping"}],
        sampler: %{temperature: 0.2, max_tokens: nil},
        extra_body: %{"a" => 3, "nested" => %{"y" => 2}}
      }

      assert {:ok, _completion, _link} =
               AI.stream(model, model.user_id, input, fn
                 %StreamEvent.Request{body: body} -> send(test_pid, {:body, body})
                 _event -> :ok
               end)

      assert_received {:body, body}
      assert body["temperature"] == 0.2
      assert body["max_tokens"] == 4096
      assert body["a"] == 3
      assert body["nested"] == %{"x" => 1, "y" => 2}
    end
  end

  describe "default_model/1" do
    test "refuses when no model is reachable", %{scope: scope} do
      model!(scope, "Unlinked")

      assert AI.default_model(scope) == {:error, :no_model}
    end

    test "returns the sole reachable model", %{scope: scope} do
      model = model!(scope, "Gemma 4")
      {:ok, _link} = AI.link_model(scope, provider!(scope, "Local"), model)

      assert {:ok, %Model{} = found} = AI.default_model(scope)
      assert found.id == model.id
    end

    test "refuses when more than one model is reachable", %{scope: scope} do
      provider = provider!(scope, "Local")
      {:ok, _link} = AI.link_model(scope, provider, model!(scope, "Gemma 4"))
      {:ok, _link} = AI.link_model(scope, provider, model!(scope, "Qwen 3", %{api_model_id: "qwen-3"}))

      assert AI.default_model(scope) == {:error, :ambiguous_model}
    end

    test "a model whose only link is disabled is unreachable", %{scope: scope} do
      {:ok, _link} = AI.link_model(scope, provider!(scope, "Local"), model!(scope, "Gemma 4"), %{enabled: false})

      assert AI.default_model(scope) == {:error, :no_model}
    end

    test "a model served only by a disabled provider is unreachable", %{scope: scope} do
      {:ok, _link} = AI.link_model(scope, provider!(scope, "Local", %{enabled: false}), model!(scope, "Gemma 4"))

      assert AI.default_model(scope) == {:error, :no_model}
    end

    test "counts only the models the scope may run", %{scope: admin} do
      user = scope!(%{role: :user})
      {:ok, _link} = AI.link_model(user, provider!(user, "Mine"), model!(user, "Mine"))

      assert {:ok, %Model{name: "Mine"}} = AI.default_model(user)
      assert AI.default_model(admin) == {:error, :no_model}
      assert AI.default_model(scope!(%{role: :user})) == {:error, :no_model}
    end

    test "ai.default_model settles several reachable models, the user's choice over the site's", %{scope: admin} do
      provider = provider!(admin, "Local", %{}, site: true)
      gemma = model!(admin, "Gemma 4", %{}, site: true)
      qwen = model!(admin, "Qwen 3", %{api_model_id: "qwen-3"}, site: true)
      for m <- [gemma, qwen], do: {:ok, _} = AI.link_model(admin, provider, m)
      user = scope!(%{role: :user})
      gemma_id = gemma.id
      qwen_id = qwen.id

      :ok = Settings.put(admin, :site, "ai.default_model", gemma.id)
      assert {:ok, %Model{id: ^gemma_id}} = AI.default_model(user)

      :ok = Settings.put(user, :user, "ai.default_model", qwen.id)
      assert {:ok, %Model{id: ^qwen_id}} = AI.default_model(user)
      assert {:ok, %Model{id: ^gemma_id}} = AI.default_model(admin)

      :ok = Settings.put(user, :user, "ai.default_model", "")
      assert {:ok, %Model{id: ^gemma_id}} = AI.default_model(user)
    end

    test "a site default the user may not run falls back to the user's sole model", %{scope: admin} do
      {:ok, _} =
        AI.link_model(admin, provider!(admin, "Site", %{}, site: true), site = model!(admin, "Site", %{}, site: true))

      :ok = Settings.put(admin, :site, "ai.default_model", site.id)
      :ok = Mythweaver.Permissions.put_grant!(:everyone, "ai.site_models.use", :deny)
      user = scope!(%{role: :user})
      {:ok, _} = AI.link_model(user, provider!(user, "Mine"), model!(user, "Mine"))

      assert {:ok, %Model{name: "Mine"}} = AI.default_model(user)
    end

    test "only site models may be the site default; users pick among what they may run", %{scope: admin} do
      user = scope!(%{role: :user})
      mine = model!(user, "Mine")
      site = model!(admin, "Site", %{}, site: true)

      assert {:error, "is not an option"} = Settings.put(admin, :site, "ai.default_model", mine.id)
      assert :ok = Settings.put(user, :user, "ai.default_model", mine.id)
      assert :ok = Settings.put(user, :user, "ai.default_model", site.id)
    end
  end

  describe "ownership" do
    setup %{scope: admin} do
      user = scope!(%{role: :user})
      site_provider = provider!(admin, "Site", %{}, site: true)
      site_model = model!(admin, "Site", %{}, site: true)
      {:ok, _} = AI.link_model(admin, site_provider, site_model)

      %{
        admin: admin,
        user: user,
        site_provider: site_provider,
        site_model: site_model,
        own_provider: provider!(user, "Site"),
        own_model: model!(user, "Site")
      }
    end

    test "a model's caption prompt is the site's or its owner's own", ctx do
      other = scope!(%{role: :user})
      {:ok, theirs} = Mythweaver.Prompts.create_prompt(other, %{name: "Theirs", purpose: :caption})
      {:ok, mine} = Mythweaver.Prompts.create_prompt(ctx.user, %{name: "Mine", purpose: :caption})

      assert {:error, cs} = AI.update_model(ctx.user, ctx.own_model, %{caption_prompt_id: theirs.id})
      assert "must be a caption prompt" in errors_on(cs).caption_prompt_id
      assert Repo.reload!(ctx.own_model).caption_prompt_id == nil

      assert {:error, _} = AI.update_model(ctx.admin, ctx.site_model, %{caption_prompt_id: mine.id})
      assert {:ok, %{caption_prompt_id: id}} = AI.update_model(ctx.user, ctx.own_model, %{caption_prompt_id: mine.id})
      assert id == mine.id
    end

    test "everyone's new rows are their own, an admin's site rows only on request, with names unique per owner",
         ctx do
      assert ctx.site_provider.user_id == nil and ctx.site_model.user_id == nil
      assert ctx.own_provider.user_id == ctx.user.user.id and ctx.own_model.user_id == ctx.user.user.id
      assert provider!(ctx.admin, "Admin's").user_id == ctx.admin.user.id
      assert model!(ctx.admin, "Admin's").user_id == ctx.admin.user.id
      assert {:error, :unauthorized} = AI.create_provider(ctx.user, %{name: "Shared", base_url: "http://x"}, site: true)
      assert {:error, :unauthorized} = AI.create_model(ctx.user, %{name: "Shared", api_model_id: "x"}, site: true)
      assert {:error, %Ecto.Changeset{}} = AI.create_provider(ctx.user, %{name: "Site", base_url: "http://x"})
    end

    test "connections are seen only by their owner, and site ones only by admins", ctx do
      assert Enum.map(AI.list_providers(ctx.user), & &1.id) == [ctx.own_provider.id]
      refute AI.get_provider(ctx.user, ctx.site_provider.id)
      assert Enum.map(AI.list_providers(ctx.admin), & &1.id) == [ctx.site_provider.id]
      refute AI.get_provider(ctx.admin, ctx.own_provider.id)
      assert {:error, :unauthorized} = AI.update_provider(ctx.admin, ctx.own_provider, %{name: "Mine now"})
      assert {:error, :unauthorized} = AI.delete_provider(ctx.user, ctx.site_provider)
    end

    test "a user runs site models and their own, but edits only their own", ctx do
      assert ctx.user |> AI.list_models() |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.sort([ctx.site_model.id, ctx.own_model.id])

      assert Enum.map(AI.list_editable_models(ctx.user), & &1.id) == [ctx.own_model.id]
      refute AI.get_editable_model(ctx.user, ctx.site_model.id)
      refute AI.get_model(scope!(%{role: :user}), ctx.own_model.id)
      refute AI.usable?(ctx.admin, ctx.own_model)
      assert {:error, :unauthorized} = AI.update_model(ctx.user, ctx.site_model, %{name: "Mine now"})
    end

    test "a link only joins a model and a connection with the same owner", ctx do
      assert {:error, :unauthorized} = AI.link_model(ctx.user, ctx.own_provider, ctx.site_model)
      assert {:error, :unauthorized} = AI.link_model(ctx.admin, ctx.site_provider, ctx.own_model)
      assert {:ok, _} = AI.link_model(ctx.user, ctx.own_provider, ctx.own_model)
      assert AI.link_model_options(ctx.own_provider) == [{"Site", ctx.own_model.id}]
    end

    test "a site model cannot name a personal captioner", ctx do
      captioner = model!(ctx.user, "Eyes", %{supports_images: true})

      assert {:error, changeset} = AI.update_model(ctx.admin, ctx.site_model, %{caption_model_id: captioner.id})
      assert "does not exist" in errors_on(changeset).caption_model_id
      assert {:ok, _} = AI.update_model(ctx.user, ctx.own_model, %{caption_model_id: captioner.id})
    end
  end

  test "an API key is ciphertext at rest and plaintext once loaded", %{scope: scope} do
    provider = provider!(scope, "Keyed", %{api_key: "sk-secret"})
    [[raw]] = Repo.query!("SELECT api_key FROM providers WHERE id = $1", [Ecto.UUID.dump!(provider.id)]).rows

    refute raw =~ "sk-secret"
    assert Repo.get!(Provider, provider.id).api_key == "sk-secret"
  end

  describe "model groups" do
    setup %{scope: admin} do
      group = group!("Players")
      member = scope!(%{role: :user})
      :ok = Permissions.add_member!(group, member.user)
      outsider = scope!(%{role: :user})
      model = model!(admin, "Site #{System.unique_integer([:positive])}", %{}, site: true)
      %{group: group, member: member, outsider: outsider, model: model}
    end

    test "a site model listing groups runs only for their members", ctx do
      %{scope: admin, group: group, member: member, outsider: outsider, model: model} = ctx

      assert AI.set_model_groups(admin, model, [group.id]) == :ok
      assert AI.model_group_ids(model) == [group.id]

      assert listed?(member, model)
      assert AI.usable?(member, model)
      refute listed?(outsider, model)
      refute AI.usable?(outsider, model)
      assert AI.get_model(outsider, model.id) == nil
      assert AI.usable?(admin, model)
    end

    test "no groups opens it to everyone allowed site models", ctx do
      %{scope: admin, group: group, member: member, outsider: outsider, model: model} = ctx

      :ok = AI.set_model_groups(admin, model, [group.id])
      assert AI.set_model_groups(admin, model, []) == :ok
      assert AI.model_group_ids(model) == []

      for scope <- [member, outsider] do
        assert listed?(scope, model)
        assert AI.usable?(scope, model)
      end
    end

    test "the Everyone group, or any one listed group, lets a user run it", ctx do
      %{scope: admin, group: group, member: member, outsider: outsider, model: model} = ctx
      other = group!("Others")

      :ok = AI.set_model_groups(admin, model, [other.id, group.id])
      assert listed?(member, model)
      assert AI.usable?(member, model)
      refute listed?(outsider, model)
      refute AI.usable?(outsider, model)

      :ok = AI.set_model_groups(admin, model, [other.id, Permissions.system_group!(:everyone).id])

      for scope <- [member, outsider] do
        assert listed?(scope, model)
        assert AI.usable?(scope, model)
      end
    end

    test "only a site manager sets them", %{group: group, model: model} do
      assert AI.set_model_groups(scope!(%{role: :user}), model, [group.id]) == {:error, :unauthorized}
      assert AI.model_group_ids(model) == []
    end
  end
end
