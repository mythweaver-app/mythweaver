defmodule MythweaverWeb.AIProviderLiveTest do
  use MythweaverWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.AI.Provider

  setup :register_and_log_in_user

  defp provider!(scope, name, attrs \\ %{}) do
    {:ok, provider} =
      AI.create_provider(scope, Map.merge(%{name: name, base_url: "http://localhost:8080/v1"}, attrs))

    provider
  end

  defp model!(scope, name) do
    {:ok, model} = AI.create_model(scope, %{name: name, api_model_id: "wire-#{name}"})
    model
  end

  describe "connections" do
    test "index selects nothing and lists every one", %{scope: scope, conn: conn} do
      remote = provider!(scope, "OpenRouter", %{base_url: "https://openrouter.ai/api/v1", priority: 1})
      local = provider!(scope, "Local llama", %{priority: 3})

      {:ok, view, _html} = live(conn, ~p"/ai/providers")

      assert has_element?(view, "#ai-provider-placeholder")
      refute has_element?(view, "#ai-provider-form")
      refute has_element?(view, "#ai-links-section")
      refute has_element?(view, "#ai-discovery")
      assert has_element?(view, "#ai-providers-#{local.id}")
      assert has_element?(view, "#ai-providers-#{remote.id}")
      refute has_element?(view, "#ai-providers a[aria-current='page']")
      assert has_element?(view, ".top-bar-nav a[href='/ai/providers']")

      view |> element("#ai-providers-#{local.id} a") |> render_click()
      assert_patch(view, ~p"/ai/providers/#{local.id}/edit")
      assert has_element?(view, "#ai-providers-#{local.id} a[aria-current='page']")
      refute has_element?(view, "#ai-providers-#{remote.id} a[aria-current]")
      refute has_element?(view, "#ai-provider-placeholder")
    end

    test "the search box narrows the list by name or URL", %{scope: scope, conn: conn} do
      remote = provider!(scope, "OpenRouter", %{base_url: "https://openrouter.ai/api/v1"})
      local = provider!(scope, "Local llama")

      {:ok, view, _html} = live(conn, ~p"/ai/providers/#{local.id}/edit")

      view |> form("#ai-provider-filter", %{"query" => "OPENROUTER.AI"}) |> render_change()
      assert has_element?(view, "#ai-providers-#{remote.id}")
      refute has_element?(view, "#ai-providers-#{local.id}")

      view |> form("#ai-provider-filter", %{"query" => "llama"}) |> render_change()
      assert has_element?(view, "#ai-providers-#{local.id} a[aria-current='page']")
      refute has_element?(view, "#ai-providers-#{remote.id}")

      view |> form("#ai-provider-filter", %{"query" => "nothing"}) |> render_change()
      assert has_element?(view, "#ai-providers-nav .pane-empty")
      refute has_element?(view, "#ai-providers li[id]")
    end

    test "index with no connections selects nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/ai/providers")

      assert has_element?(view, "#ai-provider-placeholder")
      refute has_element?(view, "#ai-provider-form")
    end

    test "an unknown connection id lands back on the index", %{scope: scope, conn: conn} do
      provider = provider!(scope, "Local llama")
      missing = Mythweaver.Schema.generate_id()

      {:ok, view, _html} = live(conn, ~p"/ai/providers/#{provider.id}/edit")
      render_patch(view, ~p"/ai/providers/#{missing}/edit")

      assert_patch(view, ~p"/ai/providers")
      assert has_element?(view, "#ai-provider-placeholder")
    end

    test "creates a connection, round-tripping every attribute", %{scope: scope, conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/ai/providers/new")

      view
      |> form("#ai-provider-form",
        provider: %{
          name: "Local llama",
          adapter: "openai_compatible",
          base_url: "http://localhost:8080/v1/",
          api_key: "sk-test",
          priority: "1",
          request_timeout_ms: "30000",
          max_concurrency: "3",
          prompt_progress: "true",
          # Opposite to the schema default, so a dropped field cannot masquerade as a round trip.
          enabled: "false",
          extra_headers: ~s({"X-Title":"mythweaver"}),
          extra_body: ~s({"cache_prompt":true})
        }
      )
      |> render_submit()

      assert [created] = AI.list_providers(scope)
      assert_patch(view, "/ai/providers/#{created.id}/edit")
      reloaded = AI.get_provider!(created.id)

      assert reloaded.name == "Local llama"
      assert reloaded.adapter == :openai_compatible
      # The changeset trims the trailing slash.
      assert reloaded.base_url == "http://localhost:8080/v1"
      assert reloaded.api_key == "sk-test"
      assert reloaded.priority == 1
      assert reloaded.request_timeout_ms == 30_000
      assert reloaded.max_concurrency == 3
      assert reloaded.prompt_progress == true
      assert reloaded.enabled == false
      assert reloaded.extra_headers == %{"X-Title" => "mythweaver"}
      assert reloaded.extra_body == %{"cache_prompt" => true}

      assert has_element?(view, "#ai-providers-#{created.id} a[aria-current='page']")
    end

    test "malformed JSON keeps the form open and creates nothing", %{scope: scope, conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/ai/providers/new")

      html =
        view
        |> form("#ai-provider-form",
          provider: %{
            name: "Local llama",
            base_url: "http://localhost:8080/v1",
            extra_headers: "not json"
          }
        )
        |> render_submit()

      assert has_element?(view, "#ai-provider-form")
      assert AI.list_providers(scope) == []
      assert html =~ "must be a JSON object"
    end

    test "editing neither leaks nor clears the stored API key", %{scope: scope, conn: conn} do
      provider = provider!(scope, "Local llama", %{api_key: "sk-secret"})

      {:ok, view, _html} = live(conn, ~p"/ai/providers/#{provider.id}/edit")

      refute render(view) =~ "sk-secret"

      view
      |> form("#ai-provider-form", provider: %{name: "Renamed", api_key: ""})
      |> render_submit()

      reloaded = AI.get_provider!(provider.id)
      assert reloaded.name == "Renamed"
      assert reloaded.api_key == "sk-secret"
    end

    test "the new form has no model connections section", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/ai/providers/new")

      refute has_element?(view, "#ai-links-section")
      refute has_element?(view, "#delete-ai-provider")
    end

    test "the pane switch in the header goes to models", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/ai/providers/new")

      refute has_element?(view, ".pane-actions a[href='/ai/models']")

      assert {:error, {:live_redirect, %{to: "/ai/models"}}} =
               view |> element("#ai-providers-nav #pane-switch-models") |> render_click()
    end

    test "an admin creates a personal connection and it is badged in the list", %{scope: scope, conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/ai/providers/new")

      view
      |> form("#ai-provider-form", owner: "personal", provider: %{name: "My key", base_url: "http://localhost:1/v1"})
      |> render_submit()

      [provider] = AI.list_providers(scope)
      assert provider.user_id == scope.user.id
      {:ok, view, _html} = live(conn, ~p"/ai/providers/#{provider.id}/edit")
      assert has_element?(view, "#ai-providers-personal-#{provider.id}")
      assert has_element?(view, "#ai-provider-owner-transfer", "Make site connection")
    end

    test "moving a connection asks for the password, then moves it to the site" do
      admin = register_user!()
      scope = Scope.for_user(admin)
      {:ok, provider} = AI.create_provider(scope, %{name: "Mine", base_url: "http://localhost:1/v1"})
      {:ok, view, _html} = live(log_in_user(build_conn(), admin, sudo: false), ~p"/ai/providers/#{provider.id}/edit")

      view |> element("#ai-provider-owner-transfer") |> render_click()
      view |> element("#ai-provider-transfer-modal-confirm") |> render_click()
      assert has_element?(view, "#sudo-modal")

      view |> form("#sudo-form", sudo: %{password: "a long test password"}) |> render_submit()
      assert Mythweaver.Repo.get!(Provider, provider.id).user_id == nil
    end

    test "deleting from the editor cascades its links but keeps the models", %{scope: scope, conn: conn} do
      provider = provider!(scope, "Local llama")
      model = model!(scope, "Gemma")
      {:ok, _link} = AI.link_model(scope, provider, model)

      {:ok, view, _html} = live(conn, ~p"/ai/providers/#{provider.id}/edit")

      view |> element("#delete-ai-provider") |> render_click()

      assert_patch(view, ~p"/ai/providers")
      assert has_element?(view, "#ai-provider-placeholder")
      assert AI.get_provider(scope, provider.id) == nil
      assert [surviving] = AI.list_models(scope)
      assert surviving.id == model.id
      assert surviving.provider_models == []
    end
  end

  describe "model connections" do
    test "lists a collapsed row per link with the effective wire id", %{scope: scope, conn: conn} do
      provider = provider!(scope, "Local llama")
      model = model!(scope, "Gemma")

      {:ok, link} =
        AI.link_model(scope, provider, model, %{api_model_id_override: "google/gemma-4-31b"})

      {:ok, view, html} = live(conn, ~p"/ai/providers/#{provider.id}/edit")

      assert has_element?(view, "details#ai-links-#{link.id}")
      refute has_element?(view, "details#ai-links-#{link.id}[open]")
      assert html =~ "google/gemma-4-31b"
    end

    test "edits an existing link through its own form", %{scope: scope, conn: conn} do
      provider = provider!(scope, "Local llama")
      {:ok, link} = AI.link_model(scope, provider, model!(scope, "Gemma"))

      {:ok, view, _html} = live(conn, ~p"/ai/providers/#{provider.id}/edit")

      view
      |> form("#ai-link-form-#{link.id}", link_id: link.id, provider_model: %{weight: "4"})
      |> render_submit()

      assert AI.get_link(link.id).weight == 4
    end

    test "saving one link keeps another link's unsaved edits", %{scope: scope, conn: conn} do
      provider = provider!(scope, "Local llama")
      {:ok, gemma} = AI.link_model(scope, provider, model!(scope, "Gemma"))
      {:ok, opus} = AI.link_model(scope, provider, model!(scope, "Opus"))

      {:ok, view, _html} = live(conn, ~p"/ai/providers/#{provider.id}/edit")

      view
      |> form("#ai-link-form-#{opus.id}", link_id: opus.id, provider_model: %{weight: "7"})
      |> render_change()

      view
      |> form("#ai-link-form-#{gemma.id}", link_id: gemma.id, provider_model: %{weight: "4"})
      |> render_submit()

      assert has_element?(view, "#ai-link-form-#{opus.id}-weight[value='7']")
      assert AI.get_link(opus.id).weight == 1
    end

    test "a link form ignores a payload that tries to move the link", %{scope: scope, conn: conn} do
      provider = provider!(scope, "Local llama")
      other = provider!(scope, "OpenRouter")
      {:ok, link} = AI.link_model(scope, provider, model!(scope, "Gemma"))

      {:ok, view, _html} = live(conn, ~p"/ai/providers/#{provider.id}/edit")

      render_submit(view, "save_link", %{
        "link_id" => link.id,
        "provider_model" => %{"provider_id" => other.id, "weight" => "2"}
      })

      reloaded = AI.get_link(link.id)
      assert reloaded.provider_id == provider.id
      assert reloaded.weight == 2
    end

    test "links a model from the new-link form", %{scope: scope, conn: conn} do
      provider = provider!(scope, "Local llama")
      model = model!(scope, "Gemma")

      {:ok, view, _html} = live(conn, ~p"/ai/providers/#{provider.id}/edit")

      view
      |> form("#ai-link-form", provider_model: %{ai_model_id: model.id, weight: "3", enabled: "true"})
      |> render_submit()

      assert [link] = AI.get_provider!(provider.id).provider_models
      assert link.ai_model_id == model.id
      assert link.weight == 3
      assert has_element?(view, "#ai-links-#{link.id}")
      assert has_element?(view, "#ai-providers-#{provider.id}", "1 model")
    end

    test "stores a link's extra_body from the JSON box", %{scope: scope, conn: conn} do
      provider = provider!(scope, "Local llama")
      model = model!(scope, "Gemma")

      {:ok, view, _html} = live(conn, ~p"/ai/providers/#{provider.id}/edit")

      view
      |> form("#ai-link-form",
        provider_model: %{ai_model_id: model.id, extra_body: ~s({"thinking_budget_tokens":0})}
      )
      |> render_submit()

      assert [link] = AI.get_provider!(provider.id).provider_models
      assert link.extra_body == %{"thinking_budget_tokens" => 0}
    end

    test "a new link keeps its thinking dialect override", %{scope: scope, conn: conn} do
      provider = provider!(scope, "Local llama")
      model = model!(scope, "Gemma")

      {:ok, view, _html} = live(conn, ~p"/ai/providers/#{provider.id}/edit")

      view
      |> form("#ai-link-form", provider_model: %{ai_model_id: model.id, thinking_dialect: "openrouter"})
      |> render_submit()

      assert [link] = AI.get_provider!(provider.id).provider_models
      assert link.thinking_dialect == :openrouter
    end

    test "a new link keeps its sampler dialect override", %{scope: scope, conn: conn} do
      provider = provider!(scope, "Local llama")
      model = model!(scope, "Gemma")

      {:ok, view, _html} = live(conn, ~p"/ai/providers/#{provider.id}/edit")

      view
      |> form("#ai-link-form", provider_model: %{ai_model_id: model.id, sampler_dialect: "llama_cpp"})
      |> render_submit()

      assert [link] = AI.get_provider!(provider.id).provider_models
      assert link.sampler_dialect == :llama_cpp
    end

    test "rejects a link extra_body that is not a JSON object", %{scope: scope, conn: conn} do
      provider = provider!(scope, "Local llama")
      model = model!(scope, "Gemma")

      {:ok, view, _html} = live(conn, ~p"/ai/providers/#{provider.id}/edit")

      html =
        view
        |> form("#ai-link-form", provider_model: %{ai_model_id: model.id, extra_body: "not json"})
        |> render_submit()

      assert html =~ "must be a JSON object"
      assert AI.get_provider!(provider.id).provider_models == []
    end

    test "a duplicate pair surfaces the unique-constraint message", %{scope: scope, conn: conn} do
      provider = provider!(scope, "Local llama")
      model = model!(scope, "Gemma")
      {:ok, _link} = AI.link_model(scope, provider, model)

      {:ok, view, _html} = live(conn, ~p"/ai/providers/#{provider.id}/edit")

      html =
        view
        |> form("#ai-link-form", provider_model: %{ai_model_id: model.id})
        |> render_submit()

      assert html =~ "is already linked to this provider"
      assert length(AI.get_provider!(provider.id).provider_models) == 1
    end

    test "toggling a link flips enabled", %{scope: scope, conn: conn} do
      provider = provider!(scope, "Local llama")
      {:ok, link} = AI.link_model(scope, provider, model!(scope, "Gemma"))
      {:ok, _other} = AI.link_model(scope, provider, model!(scope, "Opus"))

      {:ok, view, _html} = live(conn, ~p"/ai/providers/#{provider.id}/edit")

      view
      |> element("#ai-links-#{link.id} button[phx-click='toggle_link']")
      |> render_click()

      assert AI.get_link(link.id).enabled == false

      view
      |> element("#ai-links-#{link.id} button[phx-click='toggle_link']")
      |> render_click()

      assert AI.get_link(link.id).enabled == true
    end

    test "toggle_link ignores a link of another connection", %{scope: scope, conn: conn} do
      provider = provider!(scope, "Local llama")
      other = provider!(scope, "Remote")
      {:ok, foreign} = AI.link_model(scope, other, model!(scope, "Gemma"))

      {:ok, view, _html} = live(conn, ~p"/ai/providers/#{provider.id}/edit")

      render_hook(view, "toggle_link", %{"id" => foreign.id})

      assert AI.get_link(foreign.id).enabled == true
    end

    test "unlinking the last link is allowed and keeps the model", %{scope: scope, conn: conn} do
      provider = provider!(scope, "Local llama")
      model = model!(scope, "Gemma")
      {:ok, link} = AI.link_model(scope, provider, model)

      {:ok, view, _html} = live(conn, ~p"/ai/providers/#{provider.id}/edit")

      view
      |> element("#ai-links-#{link.id} button[phx-click='delete_link']")
      |> render_click()

      assert AI.get_link(link.id) == nil
      assert AI.get_model!(model.id).id == model.id
      refute has_element?(view, "#ai-links-#{link.id}")
      assert has_element?(view, "#ai-links-empty")
    end
  end

  describe "discovery" do
    defp stub_models(entries) do
      Req.Test.stub(Mythweaver.AI, &Req.Test.json(&1, %{"data" => entries}))
    end

    defp discover(conn, provider) do
      {:ok, view, _html} = live(conn, ~p"/ai/providers/#{provider.id}/edit")
      view |> element("#discover-models") |> render_click()
      {view, render_async(view)}
    end

    test "after the first run the section stays and Refresh re-queries", %{scope: scope, conn: conn} do
      provider = provider!(scope, "Local llama")
      stub_models([%{"id" => "gemma-4"}])

      {view, _html} = discover(conn, provider)

      refute has_element?(view, "#discover-models")
      assert has_element?(view, "[id='ai-discovered-gemma-4']")

      stub_models([%{"id" => "qwen-3"}])
      view |> element("#refresh-discovery") |> render_click()
      render_async(view)

      assert has_element?(view, "[id='ai-discovered-qwen-3']")
      refute has_element?(view, "[id='ai-discovered-gemma-4']")
      refute has_element?(view, "#discover-models")
    end

    test "discovering lists what the provider advertises", %{scope: scope, conn: conn} do
      provider = provider!(scope, "Local llama")
      stub_models([%{"id" => "gemma-4", "name" => "Gemma 4 31B"}, %{"id" => "qwen-3"}])

      {view, html} = discover(conn, provider)

      assert html =~ "Gemma 4 31B"
      assert html =~ "qwen-3"
      assert has_element?(view, "[id='ai-discovered-gemma-4'] button[phx-click='add_discovered']")
      assert has_element?(view, "[id='ai-discovered-qwen-3'] button[phx-click='add_discovered']")
    end

    test "one click creates the model and links it", %{scope: scope, conn: conn} do
      provider = provider!(scope, "Local llama")
      stub_models([%{"id" => "gemma-4", "name" => "Gemma 4 31B"}])

      {view, _html} = discover(conn, provider)

      view
      |> element("[id='ai-discovered-add-gemma-4']")
      |> render_click()

      assert [created] = AI.list_models(scope)
      assert created.api_model_id == "gemma-4"
      assert created.name == "Gemma 4 31B"

      assert [link] = AI.get_provider!(provider.id).provider_models
      assert link.ai_model_id == created.id

      assert has_element?(view, "[id='ai-discovered-gemma-4'] span.ai-discovery-done")
      refute has_element?(view, "[id='ai-discovered-gemma-4'] button[phx-click='add_discovered']")
      assert has_element?(view, "#ai-links-#{link.id}")
    end

    test "the row shows what will be imported and Add persists it", %{scope: scope, conn: conn} do
      provider = provider!(scope, "Local llama")

      stub_models([
        %{
          "id" => "gemma-4",
          "name" => "Gemma 4 31B",
          "context_length" => 32_768,
          "pricing" => %{"prompt" => "0.00001", "completion" => "0.00005"},
          "architecture" => %{"input_modalities" => ["text", "image"]}
        }
      ])

      {view, html} = discover(conn, provider)

      assert html =~ "32,768 ctx"
      assert html =~ "$10.00/Mtok in"
      assert html =~ "images"

      view
      |> element("[id='ai-discovered-add-gemma-4']")
      |> render_click()

      assert [created] = AI.list_models(scope)
      assert created.context_window == 32_768
      assert Decimal.equal?(created.prompt_cost_per_mtok, Decimal.new("10"))
      assert created.supports_images
    end

    test "an already-known unlinked model offers Link, not Add", %{scope: scope, conn: conn} do
      provider = provider!(scope, "Local llama")
      {:ok, model} = AI.create_model(scope, %{name: "Gemma 4 31B", api_model_id: "gemma-4"})
      stub_models([%{"id" => "gemma-4"}])

      {view, _html} = discover(conn, provider)

      assert has_element?(view, "[id='ai-discovered-gemma-4'] button[phx-click='link_discovered']")
      refute has_element?(view, "[id='ai-discovered-gemma-4'] button[phx-click='add_discovered']")

      view
      |> element("[id='ai-discovered-gemma-4'] button[phx-click='link_discovered']")
      |> render_click()

      assert [link] = AI.get_provider!(provider.id).provider_models
      assert link.ai_model_id == model.id
    end

    test "a wire id containing a slash round-trips", %{scope: scope, conn: conn} do
      provider = provider!(scope, "Local llama")
      stub_models([%{"id" => "google/gemma-4-31b"}])

      {view, _html} = discover(conn, provider)

      view
      |> element("[id='ai-discovered-add-google/gemma-4-31b']")
      |> render_click()

      assert [created] = AI.list_models(scope)
      assert created.api_model_id == "google/gemma-4-31b"
    end

    test "Add as embedding adds a listing the server does not mark as an embedding model",
         %{scope: scope, conn: conn} do
      provider = provider!(scope, "Local llama")

      stub_models([
        %{"id" => "qwen-3-embedding", "architecture" => %{"input_modalities" => ["text", "image"]}},
        %{"id" => "m/embed", "architecture" => %{"output_modalities" => ["embeddings"]}}
      ])

      {view, _html} = discover(conn, provider)

      # Already an embedding listing: plain Add is enough.
      refute has_element?(view, "[id='ai-discovered-add-embedding-m/embed']")

      view
      |> element("[id='ai-discovered-add-embedding-qwen-3-embedding']")
      |> render_click()

      assert [%{api_model_id: "qwen-3-embedding", completion_mode: :embedding, supports_images: false}] =
               AI.list_embedding_models(scope)

      assert AI.list_models(scope) == []
      assert [_link] = AI.get_provider!(provider.id).provider_models
    end

    test "Add as classifier adds a listing as a classifier model, for Expressions", %{scope: scope, conn: conn} do
      provider = provider!(scope, "Local llama")
      stub_models([%{"id" => "go-emotions", "architecture" => %{"input_modalities" => ["text"]}}])

      {view, _html} = discover(conn, provider)
      view |> element("[id='ai-discovered-add-classifier-go-emotions']") |> render_click()

      assert [%{api_model_id: "go-emotions", completion_mode: :classifier}] = AI.list_classifier_models(scope)
      assert AI.list_models(scope) == []
      assert AI.list_embedding_models(scope) == []
    end

    test "a failed discovery reports and creates nothing", %{scope: scope, conn: conn} do
      provider = provider!(scope, "Local llama")

      Req.Test.stub(Mythweaver.AI, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, ~s({"error":"boom"}))
      end)

      {_view, html} = discover(conn, provider)

      assert html =~ "the provider answered HTTP 500"
      assert AI.list_models(scope) == []
    end

    test "an empty advertisement is distinguished from a failure", %{scope: scope, conn: conn} do
      provider = provider!(scope, "Local llama")
      stub_models([])

      {view, html} = discover(conn, provider)

      assert html =~ "advertises no models"
      refute has_element?(view, ".ai-discovery-error")
    end

    test "switching connections drops the previous connection's discovery", %{scope: scope, conn: conn} do
      provider = provider!(scope, "Local llama")
      other = provider!(scope, "OpenRouter")
      stub_models([%{"id" => "gemma-4"}])

      {view, _html} = discover(conn, provider)
      assert has_element?(view, "#ai-discovery")

      render_patch(view, ~p"/ai/providers/#{other.id}/edit")

      refute has_element?(view, "#ai-discovery")
    end
  end

  describe "connection tests" do
    defp stub_auth_probe(status) do
      test = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        send(test, {:request, conn.request_path, Plug.Conn.get_req_header(conn, "authorization")})

        case status do
          200 -> Req.Test.json(conn, %{"data" => [%{"id" => "gemma-4"}]})
          status -> Plug.Conn.send_resp(conn, status, "")
        end
      end)
    end

    test "Test connection checks the unsaved form and saves nothing", %{scope: scope, conn: conn} do
      stub_auth_probe(200)
      {:ok, view, _html} = live(conn, ~p"/ai/providers/new")

      view
      |> form("#ai-provider-form",
        provider: %{name: "Draft", base_url: "http://draft:8080/v1", api_key: "sk-draft"}
      )
      |> render_change()

      view |> element("#test-ai-provider") |> render_click()

      assert render_async(view) =~ "Connected: /models answered HTTP 200 with 1 model"
      assert_receive {:request, "/v1/models", ["Bearer sk-draft"]}
      assert AI.list_providers(scope) == []
    end

    test "a blank key box tests with the stored key", %{scope: scope, conn: conn} do
      stub_auth_probe(401)
      provider = provider!(scope, "Local llama", %{api_key: "sk-secret"})
      {:ok, view, _html} = live(conn, ~p"/ai/providers/#{provider.id}/edit")

      view |> element("#test-ai-provider") |> render_click()

      assert render_async(view) =~ "Connection test failed: the provider answered HTTP 401"
      assert_receive {:request, "/v1/models", ["Bearer sk-secret"]}
    end

    test "an invalid form is not tested", %{conn: conn} do
      stub_auth_probe(200)
      {:ok, view, _html} = live(conn, ~p"/ai/providers/new")

      assert view |> element("#test-ai-provider") |> render_click() =~ "Fix the highlighted fields"
      refute_received {:request, _path, _auth}
    end

    test "Send test message reports the link's reply or its failure", %{scope: scope, conn: conn} do
      provider = provider!(scope, "Local llama")
      {:ok, link} = AI.link_model(scope, provider, model!(scope, "Gemma"))

      Req.Test.stub(Mythweaver.AI, fn conn ->
        Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "Hello there!"}}]})
      end)

      {:ok, view, _html} = live(conn, ~p"/ai/providers/#{provider.id}/edit")
      view |> element("#test-ai-link-#{link.id}") |> render_click()
      assert render_async(view) =~ "Gemma answered HTTP 200: &quot;Hello there!&quot;"

      Req.Test.stub(Mythweaver.AI, &Plug.Conn.send_resp(&1, 401, ""))
      view |> element("#test-ai-link-#{link.id}") |> render_click()
      assert render_async(view) =~ "Gemma test failed: the provider answered HTTP 401"
    end
  end
end
