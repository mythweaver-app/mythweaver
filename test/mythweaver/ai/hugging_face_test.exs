defmodule Mythweaver.AI.HuggingFaceTest do
  use ExUnit.Case, async: false

  alias Mythweaver.AI.HuggingFace
  alias Mythweaver.AI.Model
  alias Mythweaver.AI.SamplerParams
  alias Mythweaver.Tokenizer

  # Failed tokenizer loads log a warning by design.
  @moduletag :capture_log

  @fixture File.read!("test/support/fixtures/word_level_tokenizer.json")

  @gguf_routes %{
    "/api/models/test/hf-gguf" =>
      {:json,
       %{
         "siblings" => [%{"rfilename" => "model-Q4.gguf"}, %{"rfilename" => "mmproj-f16.gguf"}],
         "cardData" => %{"base_model" => ["test/hf-base"]},
         "gguf" => %{
           "context_length" => 131_072,
           "chat_template" => "{% if tools %}…{% endif %}[THINK]…[/THINK]"
         }
       }},
    "/api/models/test/hf-base" =>
      {:json,
       %{
         "siblings" => [
           %{"rfilename" => "tokenizer.json"},
           %{"rfilename" => "generation_config.json"}
         ]
       }},
    "/test/hf-base/resolve/main/tokenizer.json" => :tokenizer,
    "/test/hf-base/resolve/main/generation_config.json" =>
      {:json, %{"temperature" => 0.6, "top_k" => 20, "do_sample" => true}}
  }

  setup do
    File.rm_rf!(Application.fetch_env!(:mythweaver, :tokenizer_cache_dir))
    :ok
  end

  describe "parse_repo/1" do
    test "accepts model pages and bare ids, rejects non-models" do
      assert HuggingFace.parse_repo("https://huggingface.co/TheDrummer/Skyfall-31B-v4/tree/main") ==
               {:ok, "TheDrummer/Skyfall-31B-v4"}

      assert HuggingFace.parse_repo("hf.co/Qwen/Qwen3-8B?x=1") == {:ok, "Qwen/Qwen3-8B"}
      assert HuggingFace.parse_repo("Qwen/Qwen3-8B") == {:ok, "Qwen/Qwen3-8B"}
      assert HuggingFace.parse_repo("https://huggingface.co/spaces/a/b") == :error
      assert HuggingFace.parse_repo("gpt2") == :error
      assert HuggingFace.parse_repo(nil) == :error
    end
  end

  describe "lookup/1" do
    test "a GGUF repo follows base_model to the tokenizer and merges both repos' metadata" do
      stub_hub(@gguf_routes)

      assert HuggingFace.lookup("https://huggingface.co/test/hf-gguf") ==
               {:ok,
                %{
                  source: "test/hf-gguf",
                  tokenizer: "test/hf-base",
                  name: "hf-base",
                  completion_mode: :chat,
                  context_window: 131_072,
                  supports_images: true,
                  supports_tools: true,
                  supports_thinking: true,
                  reasoning_tags: {"[THINK]", "[/THINK]"},
                  sampler: %{temperature: 0.6, top_k: 20}
                }}
    end

    test "a repo without a chat template is a text model; config.json supplies the context" do
      stub_hub(%{
        "/api/models/test/hf-plain" =>
          {:json, %{"siblings" => [%{"rfilename" => "tokenizer.json"}, %{"rfilename" => "config.json"}]}},
        "/test/hf-plain/resolve/main/tokenizer.json" => :tokenizer,
        "/test/hf-plain/resolve/main/config.json" => {:json, %{"max_position_embeddings" => 4096}}
      })

      assert {:ok, meta} = HuggingFace.lookup("test/hf-plain")
      assert meta.completion_mode == :text
      assert meta.context_window == 4096
      assert meta.supports_tools == nil
      assert meta.reasoning_tags == nil
      assert meta.sampler == %{}
    end

    test "a 401 from the model API reads as not found" do
      stub_hub(%{"/api/models/test/hf-missing" => 401})

      assert HuggingFace.lookup("test/hf-missing") == {:error, {:not_found, "test/hf-missing"}}
    end

    test "no tokenizer and no base model" do
      stub_hub(%{"/api/models/test/hf-none" => {:json, %{"siblings" => []}}})

      assert HuggingFace.lookup("test/hf-none") == {:error, {:no_tokenizer, "test/hf-none"}}
    end

    test "an invalid base_model stops the chain without another Hub request" do
      test = self()

      Req.Test.stub(HuggingFace, fn conn ->
        send(test, {:hub_request, conn.request_path})

        Req.Test.json(conn, %{"siblings" => [], "cardData" => %{"base_model" => "../../evil?x=1"}})
      end)

      assert HuggingFace.lookup("test/hf-evil") == {:error, {:no_tokenizer, "test/hf-evil"}}
      assert_received {:hub_request, "/api/models/test/hf-evil"}
      refute_received {:hub_request, _path}
    end

    test "an explicit lookup retries a tokenizer whose failure is cached" do
      stub_hub(%{})
      assert {_, :estimate} = Tokenizer.count(%Model{tokenizer: "test/hf-retry"}, "x")

      stub_hub(%{
        "/api/models/test/hf-retry" => {:json, %{"siblings" => [%{"rfilename" => "tokenizer.json"}]}},
        "/test/hf-retry/resolve/main/tokenizer.json" => :tokenizer
      })

      assert {:ok, _meta} = HuggingFace.lookup("test/hf-retry")
    end
  end

  describe "compare/2 and form_params/1" do
    setup do
      stub_hub(@gguf_routes)
      {:ok, meta} = HuggingFace.lookup("test/hf-gguf")

      model = %Model{
        name: "Mine",
        context_window: nil,
        supports_tools: false,
        sampler: %SamplerParams{temperature: 1.0}
      }

      %{rows: HuggingFace.compare(meta, model)}
    end

    test "blank fields are pre-applied, set ones are kept", %{rows: rows} do
      applied = Map.new(rows, &{&1.key, &1.apply?})

      assert applied["tokenizer"]
      refute applied["name"]
      assert applied["context_window"]
      assert applied["supports_tools"]
      refute applied["sampler.temperature"]
      refute "completion_mode" in (rows |> Enum.filter(&HuggingFace.changed?/1) |> Enum.map(& &1.key))
    end

    test "the patch holds only applied, changed rows, in form-param shape", %{rows: rows} do
      assert HuggingFace.form_params(rows) == %{
               "tokenizer" => "test/hf-base",
               "context_window" => "131072",
               "supports_tools" => "true",
               "supports_images" => "true",
               "supports_thinking" => "true",
               "reasoning_prefix" => "[THINK]",
               "reasoning_suffix" => "[/THINK]",
               "sampler" => %{"top_k" => "20"}
             }
    end
  end

  # Routes keyed by request path: `{:json, map}`, `:tokenizer` (the word-level fixture), or a bare
  # status. Anything unrouted is a 404.
  defp stub_hub(routes) do
    Req.Test.stub(HuggingFace, fn conn ->
      case Map.get(routes, conn.request_path, 404) do
        {:json, body} -> Req.Test.json(conn, body)
        :tokenizer -> Plug.Conn.send_resp(conn, 200, @fixture)
        status -> Plug.Conn.send_resp(conn, status, "")
      end
    end)
  end
end
