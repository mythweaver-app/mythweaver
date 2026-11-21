defmodule Mythweaver.Assistant.Tools.AITest do
  use Mythweaver.DataCase

  alias Mythweaver.AI
  alias Mythweaver.Assistant.Tools

  setup do
    %{scope: scope!()}
  end

  defp run!(scope, name, args) do
    {:ok, tool} = Tools.fetch(name)
    Tools.run(scope, tool, args)
  end

  defp provider!(scope, attrs \\ %{}) do
    {:ok, provider} =
      AI.create_provider(
        scope,
        Map.merge(%{name: "Local #{System.unique_integer([:positive])}", base_url: "http://localhost:8080/v1"}, attrs)
      )

    provider
  end

  defp stub_models(entries) do
    Req.Test.stub(Mythweaver.AI, &Req.Test.json(&1, %{"data" => entries}))
  end

  defp model!(scope, attrs \\ %{}) do
    {:ok, model} =
      AI.create_model(scope, Map.merge(%{name: "M #{System.unique_integer([:positive])}", api_model_id: "m"}, attrs))

    model
  end

  defp link!(scope, provider, model) do
    {:ok, link} = AI.link_model(scope, provider, model)
    link
  end

  test "create_connections ignores an api_key argument", %{scope: scope} do
    assert {:ok, %{"done" => [%{"id" => id, "path" => path}]}} =
             run!(scope, "create_connections", %{
               "items" => [%{"name" => "Box", "base_url" => "http://box:1234/v1", "api_key" => "sk-sneaky"}]
             })

    provider = AI.get_provider(scope, id)
    assert provider.adapter == :openai_compatible
    assert provider.api_key == nil
    assert path == "/ai/providers/#{id}/edit"
  end

  test "create_connections rejects an unknown adapter, creates a personal row by default and a site row on request",
       %{scope: scope} do
    assert {:error, %{"failed" => [%{"error" => "invalid", "fields" => %{adapter: ["is invalid"]}}]}} =
             run!(scope, "create_connections", %{
               "items" => [%{"name" => "Box", "base_url" => "http://box:1234/v1", "adapter" => "other"}]
             })

    assert {:ok, %{"done" => [%{"id" => id, "owner" => "personal"}]}} =
             run!(scope, "create_connections", %{"items" => [%{"name" => "Mine", "base_url" => "http://box:1234/v1"}]})

    assert AI.get_provider(scope, id).user_id == scope.user.id

    assert {:ok, %{"done" => [%{"id" => site_id, "owner" => "site"}]}} =
             run!(scope, "create_connections", %{
               "items" => [%{"name" => "Shared", "base_url" => "http://box:1234/v1", "site" => true}]
             })

    assert AI.get_provider(scope, site_id).user_id == nil
  end

  test "update_connections changes only the given fields across items", %{scope: scope} do
    provider = provider!(scope)
    other = provider!(scope)

    assert {:ok, %{"done" => [%{"name" => "Renamed"}, updated]}} =
             run!(scope, "update_connections", %{
               "items" => [
                 %{"id" => provider.id, "name" => "Renamed"},
                 %{"id" => other.id, "priority" => 1, "max_concurrency" => 2, "extra_headers" => %{"x-env" => "test"}}
               ]
             })

    assert %{"priority" => 1, "max_concurrency" => 2, "extra_headers" => %{"x-env" => "test"}} = updated

    updated = AI.get_provider(scope, provider.id)
    assert updated.name == "Renamed"
    assert updated.base_url == "http://localhost:8080/v1"
  end

  test "list_connections reports whether a key is set and never the key", %{scope: scope} do
    provider = provider!(scope, %{api_key: "sk-hidden-value"})

    assert {:ok, %{"connections" => rows}} = run!(scope, "list_connections", %{})
    assert %{"api_key_set" => true} = Enum.find(rows, &(&1["id"] == provider.id))
    refute Jason.encode!(rows) =~ "sk-hidden-value"
  end

  test "add_models creates an offered model, refuses one not offered and reports one already linked", %{scope: scope} do
    provider = provider!(scope)
    stub_models([%{"id" => "gemma-4", "object" => "model"}])

    assert {:error, %{"failed" => [%{"error" => "That connection does not offer it; call discover_models."}]}} =
             run!(scope, "add_models", %{"connection_id" => provider.id, "models" => ["nope"]})

    assert {:ok, %{"done" => [%{"id" => model_id, "name" => "gemma-4"}]}} =
             run!(scope, "add_models", %{"connection_id" => provider.id, "models" => ["gemma-4"]})

    assert AI.get_model(scope, model_id).api_model_id == "gemma-4"

    assert {:ok, %{"done" => [%{"already_linked" => true}]}} =
             run!(scope, "add_models", %{"connection_id" => provider.id, "models" => ["gemma-4"]})
  end

  test "add_models discovers once for the whole batch and adds each offered model", %{scope: scope} do
    provider = provider!(scope)
    counter = start_supervised!({Agent, fn -> 0 end})

    Req.Test.stub(Mythweaver.AI, fn conn ->
      Agent.update(counter, &(&1 + 1))
      Req.Test.json(conn, %{"data" => [%{"id" => "gemma-4"}, %{"id" => "qwen-3"}]})
    end)

    {:ok, _} = run!(scope, "discover_models", %{"connection_id" => provider.id})
    one_discovery = Agent.get_and_update(counter, &{&1, 0})

    assert {:ok, %{"done" => [%{"name" => "gemma-4"}, %{"name" => "qwen-3"}], "failed" => [failed]}} =
             run!(scope, "add_models", %{"connection_id" => provider.id, "models" => ["gemma-4", "nope", "qwen-3"]})

    assert %{"index" => 1, "id" => "nope"} = failed
    assert Agent.get(counter, & &1) == one_discovery
  end

  test "a non-UUID id gives an error map", %{scope: scope} do
    assert {:error, %{"failed" => [%{"error" => "id is not a valid id"}]}} =
             run!(scope, "update_connections", %{"items" => [%{"id" => "abc"}]})

    assert {:error, %{"error" => "connection_id is not a valid id"}} =
             run!(scope, "test_connection", %{"connection_id" => "abc"})
  end

  describe "models" do
    test "update_models exposes every model field, including sampler", %{scope: scope} do
      model = model!(scope)

      assert {:ok, %{"done" => [updated]}} =
               run!(scope, "update_models", %{
                 "items" => [
                   %{
                     "id" => model.id,
                     "supports_images" => true,
                     "caption_max_tokens" => 99,
                     "image_detail" => "low",
                     "sampler" => %{"temperature" => 0.5}
                   }
                 ]
               })

      assert %{"supports_images" => true, "caption_max_tokens" => 99, "image_detail" => "low"} = updated
      assert %{"temperature" => 0.5} = updated["sampler"]

      assert {:ok, %{"done" => [%{"sampler" => %{"temperature" => 0.5, "top_k" => 5}}]}} =
               run!(scope, "update_models", %{"items" => [%{"id" => model.id, "sampler" => %{"top_k" => 5}}]})
    end

    test "update_models refuses a mode switch blocked by current use", %{scope: scope} do
      model = model!(scope)
      {:ok, a} = Mythweaver.Characters.create_character(scope, %{name: "A"})
      {:ok, b} = Mythweaver.Characters.create_character(scope, %{name: "B"})

      {:ok, _chat} =
        Mythweaver.Chats.create_chat(scope, %{
          "ai_model_id" => model.id,
          "participants" => [%{"character_id" => a.id}, %{"character_id" => b.id}]
        })

      assert {:error, %{"failed" => [%{"error" => "invalid", "fields" => %{completion_mode: [_]}}]}} =
               run!(scope, "update_models", %{"items" => [%{"id" => model.id, "completion_mode" => "embedding"}]})
    end

    test "delete_models deletes an editable model and refuses another user's", %{scope: scope} do
      model = model!(scope)
      other = scope!(%{role: :user})

      assert {:error, %{"failed" => [%{"error" => "Not found."}]}} =
               run!(other, "delete_models", %{"ids" => [model.id]})

      assert {:ok, %{"done" => [%{"deleted" => true, "id" => id}]}} =
               run!(scope, "delete_models", %{"ids" => [model.id]})

      assert id == model.id
      assert AI.get_editable_model(scope, id) == nil
    end

    test "list_models filters by mode", %{scope: scope} do
      chat_model = model!(scope)
      embedding = model!(scope, %{completion_mode: :embedding})

      assert {:ok, %{"models" => rows}} = run!(scope, "list_models", %{"mode" => "embedding"})
      ids = Enum.map(rows, & &1["id"])
      assert embedding.id in ids
      refute chat_model.id in ids

      assert {:error, %{"error" => "mode must be chat_and_text, embedding or classifier"}} =
               run!(scope, "list_models", %{"mode" => "bogus"})
    end
  end

  describe "links" do
    test "create, update and delete a link", %{scope: scope} do
      provider = provider!(scope)
      model = model!(scope)

      assert {:ok, %{"done" => [%{"id" => link_id, "weight" => 2, "provider_id" => pid, "model_id" => mid}]}} =
               run!(scope, "create_links", %{
                 "items" => [%{"provider_id" => provider.id, "model_id" => model.id, "weight" => 2}]
               })

      assert {pid, mid} == {provider.id, model.id}

      assert {:ok, %{"done" => [%{"weight" => 5, "enabled" => false}]}} =
               run!(scope, "update_links", %{"items" => [%{"id" => link_id, "weight" => 5, "enabled" => false}]})

      assert {:ok, %{"done" => [%{"deleted" => true, "id" => ^link_id}]}} =
               run!(scope, "delete_links", %{"ids" => [link_id]})

      assert AI.get_provider(scope, provider.id)
      assert AI.get_editable_model(scope, model.id)
    end

    test "create_links refuses a model and connection of different owners", %{scope: scope} do
      {:ok, personal} = AI.create_provider(scope, %{name: "Mine", base_url: "http://x/v1"})
      {:ok, model} = AI.create_model(scope, %{name: "Site M", api_model_id: "m"}, site: true)

      assert {:error, %{"failed" => [%{"error" => "You are not allowed to do that."}]}} =
               run!(scope, "create_links", %{"items" => [%{"provider_id" => personal.id, "model_id" => model.id}]})
    end

    test "test_link runs a capped completion, reports an embedding's vector length, and refuses another user",
         %{scope: scope} do
      provider = provider!(scope)
      chat_link = link!(scope, provider, model!(scope))
      embedding_link = link!(scope, provider, model!(scope, %{completion_mode: :embedding}))

      Req.Test.stub(Mythweaver.AI, fn conn ->
        if String.ends_with?(conn.request_path, "/embeddings"),
          do: Req.Test.json(conn, %{"data" => [%{"index" => 0, "embedding" => [0.1, 0.2, 0.3]}]}),
          else:
            Req.Test.json(conn, %{
              "choices" => [
                %{"index" => 0, "message" => %{"role" => "assistant", "content" => "Hello"}, "finish_reason" => "stop"}
              ]
            })
      end)

      assert {:ok, %{"ok" => true, "reply" => "Hello"}} = run!(scope, "test_link", %{"link_id" => chat_link.id})
      assert {:ok, %{"ok" => true, "vector_length" => 3}} = run!(scope, "test_link", %{"link_id" => embedding_link.id})

      assert {:error, %{"error" => "You are not allowed to do that."}} =
               run!(scope!(%{role: :user}), "test_link", %{"link_id" => chat_link.id})
    end
  end

  describe "transfer" do
    test "transfer_connections moves a connection and its models to the site", %{scope: scope} do
      {:ok, provider} = AI.create_provider(scope, %{name: "Mine", base_url: "http://x/v1"})
      {:ok, model} = AI.create_model(scope, %{name: "Mine M", api_model_id: "m"})
      link!(scope, provider, model)

      assert {:ok, %{"done" => [%{"owner" => "site"}]}} = run!(scope, "transfer_connections", %{"ids" => [provider.id]})

      assert AI.get_editable_model(scope, model.id).user_id == nil
    end

    test "transfer_models moves the caller's own model to the site, once", %{scope: scope} do
      {:ok, model} = AI.create_model(scope, %{name: "Own M", api_model_id: "m"})

      assert {:ok, %{"done" => [%{"owner" => "site"}]}} = run!(scope, "transfer_models", %{"ids" => [model.id]})

      assert {:error, %{"failed" => [%{"error" => "It already has that owner."}]}} =
               run!(scope, "transfer_models", %{"ids" => [model.id]})
    end
  end
end
