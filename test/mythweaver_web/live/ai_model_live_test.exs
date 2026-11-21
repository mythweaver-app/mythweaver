defmodule MythweaverWeb.AIModelLiveTest do
  use MythweaverWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.AI.HuggingFace
  alias Mythweaver.AI.SamplerParams
  alias Mythweaver.Permissions
  alias Mythweaver.Sharing

  setup :register_and_log_in_user

  defp model!(scope, name, attrs \\ %{}) do
    {:ok, model} =
      AI.create_model(scope, Map.merge(%{name: name, api_model_id: "wire-#{name}"}, attrs))

    model
  end

  test "index selects nothing and lists every one", %{scope: scope, conn: conn} do
    gemma = model!(scope, "Gemma")
    opus = model!(scope, "Opus")

    {:ok, view, _html} = live(conn, ~p"/ai/models")

    assert has_element?(view, "#ai-model-placeholder")
    refute has_element?(view, "#ai-model-form")
    assert has_element?(view, "#ai-models-#{gemma.id}")
    assert has_element?(view, "#ai-models-#{opus.id}")
    refute has_element?(view, "#ai-models a[aria-current='page']")

    view |> element("#ai-models-#{gemma.id} a") |> render_click()
    assert_patch(view, ~p"/ai/models/#{gemma.id}/edit")
    assert has_element?(view, "#ai-models-#{gemma.id} a[aria-current='page']")
    refute has_element?(view, "#ai-models-#{opus.id} a[aria-current]")
    refute has_element?(view, "#ai-model-placeholder")
  end

  test "the search box narrows the list by name or wire id", %{scope: scope, conn: conn} do
    gemma = model!(scope, "Gemma", %{api_model_id: "google/gemma-4"})
    opus = model!(scope, "Opus", %{api_model_id: "claude-opus"})

    {:ok, view, _html} = live(conn, ~p"/ai/models/#{gemma.id}/edit")

    view |> form("#ai-model-filter", %{"query" => "GOOGLE/"}) |> render_change()
    assert has_element?(view, "#ai-models-#{gemma.id} a[aria-current='page']")
    refute has_element?(view, "#ai-models-#{opus.id}")

    view |> form("#ai-model-filter", %{"query" => "opus"}) |> render_change()
    assert has_element?(view, "#ai-models-#{opus.id}")
    refute has_element?(view, "#ai-models-#{gemma.id}")

    view |> form("#ai-model-filter", %{"query" => "nothing"}) |> render_change()
    assert has_element?(view, "#ai-models-nav .pane-empty")
    refute has_element?(view, "#ai-models li[id]")
  end

  test "index with no models selects nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ai/models")

    assert has_element?(view, "#ai-model-placeholder")
    refute has_element?(view, "#ai-model-form")
  end

  test "an unknown model id lands back on the index", %{scope: scope, conn: conn} do
    model = model!(scope, "Gemma")

    {:ok, view, _html} = live(conn, ~p"/ai/models/#{model.id}/edit")
    render_patch(view, ~p"/ai/models/#{Mythweaver.Schema.generate_id()}/edit")

    assert_patch(view, ~p"/ai/models")
    assert has_element?(view, "#ai-model-placeholder")
  end

  test "the pane switch goes to connections", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ai/models/new")

    assert {:error, {:live_redirect, %{to: "/ai/providers"}}} =
             view |> element("#pane-switch-connections") |> render_click()
  end

  test "deleting from the editor removes the model and its links", %{scope: scope, conn: conn} do
    {:ok, provider} = AI.create_provider(scope, %{name: "Local", base_url: "http://localhost:8080/v1"})
    model = model!(scope, "Gemma")
    {:ok, _link} = AI.link_model(scope, provider, model)

    {:ok, view, _html} = live(conn, ~p"/ai/models/#{model.id}/edit")

    view |> element("#delete-ai-model") |> render_click()

    assert_patch(view, ~p"/ai/models")
    assert has_element?(view, "#ai-model-placeholder")
    assert AI.get_model(scope, model.id) == nil
    assert [surviving] = AI.list_providers(scope)
    assert surviving.id == provider.id
    assert surviving.model_count == 0
  end

  test "creates a model with sampler defaults", %{scope: scope, conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ai/models/new")

    view
    |> form("#ai-model-form",
      model: %{
        name: "Gemma 4 31B",
        api_model_id: "gemma-4",
        completion_mode: "text",
        context_window: "32768",
        supports_thinking: "true",
        tokenizer: "Qwen/Qwen3-8B",
        sampler: %{
          temperature: "0.7",
          top_p: "0.9",
          max_tokens: "512",
          stop_sequences: "</s>, ###",
          extra: ~s({"mirostat":2})
        }
      }
    )
    |> render_submit()

    assert [created] = AI.list_models(scope)
    assert_patch(view, "/ai/models/#{created.id}/edit")
    reloaded = AI.get_model!(created.id)

    assert reloaded.name == "Gemma 4 31B"
    assert reloaded.api_model_id == "gemma-4"
    assert reloaded.completion_mode == :text
    assert reloaded.context_window == 32_768
    assert reloaded.supports_thinking == true
    assert reloaded.tokenizer == "Qwen/Qwen3-8B"
    assert reloaded.sampler.temperature == 0.7
    assert reloaded.sampler.top_p == 0.9
    assert reloaded.sampler.max_tokens == 512
    assert reloaded.sampler.stop_sequences == ["</s>", "###"]
    assert reloaded.sampler.extra == %{"mirostat" => 2}

    assert has_element?(view, "#ai-models-#{created.id} a[aria-current='page']")
  end

  test "saves a nested extra_body", %{scope: scope, conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ai/models/new")

    view
    |> form("#ai-model-form",
      model: %{
        name: "Gemma 4 31B",
        api_model_id: "gemma-4",
        extra_body: ~s({"chat_template_kwargs":{"enable_thinking":false}})
      }
    )
    |> render_submit()

    assert [created] = AI.list_models(scope)

    assert AI.get_model!(created.id).extra_body ==
             %{"chat_template_kwargs" => %{"enable_thinking" => false}}
  end

  test "saves time limits and refuses a negative one", %{scope: scope, conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ai/models/new")

    view
    |> form("#ai-model-form",
      model: %{
        name: "Gemma 4 31B",
        api_model_id: "gemma-4",
        chat_first_token_seconds: "240",
        background_deadline_seconds: "0"
      }
    )
    |> render_submit()

    assert [created] = AI.list_models(scope)
    reloaded = AI.get_model!(created.id)
    assert reloaded.chat_first_token_seconds == 240
    assert reloaded.background_deadline_seconds == 0
    assert reloaded.chat_stall_seconds == nil

    {:ok, view, _html} = live(conn, ~p"/ai/models/new")

    view
    |> form("#ai-model-form", model: %{name: "Other", api_model_id: "other", chat_stall_seconds: "-1"})
    |> render_submit()

    assert has_element?(view, "#ai-model-form")
    assert [_only] = AI.list_models(scope)
  end

  test "saves the sampler's thinking level", %{scope: scope, conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ai/models/new")

    view
    |> form("#ai-model-form",
      model: %{name: "Gemma 4 31B", api_model_id: "gemma-4", sampler: %{thinking: "none"}}
    )
    |> render_submit()

    assert [created] = AI.list_models(scope)
    assert AI.get_model!(created.id).sampler.thinking == :none
  end

  test "a thinking model with a small max_tokens shows the budget warning", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ai/models/new")

    change = fn thinking, max_tokens ->
      view
      |> form("#ai-model-form",
        model: %{supports_thinking: thinking, sampler: %{max_tokens: max_tokens}}
      )
      |> render_change()
    end

    change.("true", "300")
    assert has_element?(view, "#ai-model-form-thinking-warning")

    change.("true", "2048")
    refute has_element?(view, "#ai-model-form-thinking-warning")

    change.("false", "300")
    refute has_element?(view, "#ai-model-form-thinking-warning")
  end

  test "saves the inline reasoning tag pair", %{scope: scope, conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ai/models/new")

    view
    |> form("#ai-model-form",
      model: %{
        name: "Qwen inline",
        api_model_id: "qwen-3.6",
        reasoning_prefix: "<think>",
        reasoning_suffix: "</think>"
      }
    )
    |> render_submit()

    assert [created] = AI.list_models(scope)
    reloaded = AI.get_model!(created.id)
    assert {reloaded.reasoning_prefix, reloaded.reasoning_suffix} == {"<think>", "</think>"}
  end

  test "sampler numeric bounds match the changeset", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ai/models/new")

    assert has_element?(view, "#ai-model-form-sampler-temperature[type='number'][min='0'][max='5']")

    # Penalties are signed: a `min="0"` here would make every negative value the changeset accepts
    # unenterable.
    assert has_element?(
             view,
             "#ai-model-form-sampler-frequency_penalty[type='number'][min='-2'][max='2']"
           )

    assert has_element?(
             view,
             "#ai-model-form-sampler-presence_penalty[type='number'][min='-2'][max='2']"
           )

    assert has_element?(view, "#ai-model-form-sampler-xtc_probability[type='number'][min='0'][max='1']")
  end

  test "Neutralize samplers turns truncation and penalties off and keeps the rest", %{scope: scope, conn: conn} do
    model =
      model!(scope, "Gemma", %{
        sampler: %{
          temperature: 0.7,
          top_k: 40,
          min_p: 0.1,
          max_tokens: 400,
          dry_multiplier: 0.8,
          dry_sequence_breakers: ["\n", ":"]
        }
      })

    {:ok, view, _html} = live(conn, ~p"/ai/models/#{model.id}/edit")

    view |> element("#ai-model-form-sampler-neutralize") |> render_click()
    # Not saved until Save: the form reads as edited.
    refute has_element?(view, "#ai-model-form[data-saved]")
    assert AI.get_model!(model.id).sampler.temperature == 0.7

    view |> form("#ai-model-form") |> render_submit()

    sampler = AI.get_model!(model.id).sampler
    assert sampler.temperature == 1.0
    assert sampler.top_k == 0
    assert sampler.min_p == 0.0
    assert sampler.dry_multiplier == 0.0
    assert sampler.max_tokens == 400
    assert sampler.dry_sequence_breakers == ["\n", ":"]
  end

  test "a dragged sampler order saves, and a non-permutation is ignored", %{scope: scope, conn: conn} do
    model = model!(scope, "Gemma")

    {:ok, view, _html} = live(conn, ~p"/ai/models/#{model.id}/edit")

    view |> element("#ai-model-form-sampler-order-customize") |> render_click()
    names = Enum.map(SamplerParams.default_sampler_order(), &Atom.to_string/1)
    dragged = ["temperature" | names -- ["temperature"]]

    render_hook(view, "sampler_order_reorder", %{"ids" => ["temperature", "bogus"]})
    render_hook(view, "sampler_order_reorder", %{"ids" => dragged})
    view |> form("#ai-model-form") |> render_submit()

    assert AI.get_model!(model.id).sampler.sampler_order == Enum.map(dragged, &String.to_existing_atom/1)

    view |> element("#ai-model-form-sampler-order-reset") |> render_click()
    view |> form("#ai-model-form") |> render_submit()

    assert AI.get_model!(model.id).sampler.sampler_order == []
  end

  test "saves DRY sequence breakers and logit bias from their JSON boxes", %{scope: scope, conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ai/models/new")

    view
    |> form("#ai-model-form",
      model: %{
        name: "Gemma",
        api_model_id: "gemma-4",
        sampler: %{dry_sequence_breakers: ~s(["\\n", ":"]), logit_bias: ~s({"shiver": false})}
      }
    )
    |> render_submit()

    assert [created] = AI.list_models(scope)
    sampler = AI.get_model!(created.id).sampler
    assert sampler.dry_sequence_breakers == ["\n", ":"]
    assert sampler.logit_bias == %{"shiver" => false}
  end

  test "invalid sequence breakers keep the form open and create nothing", %{scope: scope, conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ai/models/new")

    view
    |> form("#ai-model-form",
      model: %{name: "Gemma", api_model_id: "gemma-4", sampler: %{dry_sequence_breakers: "not json"}}
    )
    |> render_submit()

    assert has_element?(view, "#ai-model-form")
    assert AI.list_models(scope) == []
  end

  test "an out-of-range sampler value keeps the form open", %{scope: scope, conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ai/models/new")

    view
    |> form("#ai-model-form",
      model: %{name: "Gemma", api_model_id: "gemma-4", sampler: %{temperature: "9"}}
    )
    |> render_submit()

    assert has_element?(view, "#ai-model-form")
    assert AI.list_models(scope) == []
  end

  test "malformed sampler extra JSON keeps the form open and creates nothing", %{scope: scope, conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ai/models/new")

    html =
      view
      |> form("#ai-model-form",
        model: %{name: "Gemma", api_model_id: "gemma-4", sampler: %{extra: "not json"}}
      )
      |> render_submit()

    assert has_element?(view, "#ai-model-form")
    assert AI.list_models(scope) == []
    assert html =~ "extra must be a JSON object"
  end

  test "edits a model and stays on it", %{scope: scope, conn: conn} do
    model = model!(scope, "Gemma", %{context_window: 8192})

    {:ok, view, _html} = live(conn, ~p"/ai/models/#{model.id}/edit")

    view
    |> form("#ai-model-form", model: %{name: "Gemma 4 31B", context_window: "32768"})
    |> render_submit()

    assert_patch(view, "/ai/models/#{model.id}/edit")
    assert has_element?(view, "#ai-model-form-name[value='Gemma 4 31B']")

    reloaded = AI.get_model!(model.id)
    assert reloaded.name == "Gemma 4 31B"
    assert reloaded.context_window == 32_768
  end

  describe "Sharing panel" do
    test "the owner invites an own-key subscriber; My connection needs the permission", %{
      scope: scope,
      user: user,
      conn: conn
    } do
      model = model!(scope, "Gemma")
      invitee = register_user!(%{role: :user})
      {:ok, view, _html} = live(conn, ~p"/ai/models/#{model.id}/edit")

      assert has_element?(view, "#ai-model-share-invite-ai_mode option[value='own_key']", "Their own connection")
      refute has_element?(view, "#ai-model-share-invite-ai_mode option[value='owner_key']")
      refute has_element?(view, "#ai-model-share-invite-hint")

      view |> form("#ai-model-share-invite", share: %{role: "subscriber"}) |> render_change()

      view
      |> form("#ai-model-share-invite", share: %{handle: invitee.handle, role: "subscriber", ai_mode: "own_key"})
      |> render_submit()

      assert [share] = Sharing.list_shares(Scope.for_user(user), model)
      assert share.ai_mode == :own_key and share.token_limit_per_day == nil
      assert has_element?(view, "#ai-model-share-ai-mode-text-#{share.id}", "Their own connection")
      refute has_element?(view, "#ai-model-share-ai-mode-#{share.id}")
    end

    test "with sharing.ai.owner_key the owner invites on their connection with a limit and switches it back",
         %{scope: scope, user: user, conn: conn} do
      :ok = Permissions.put_grant!(user, "sharing.ai.owner_key", :allow)
      model = model!(scope, "Gemma")
      invitee = register_user!(%{role: :user})
      {:ok, view, _html} = live(conn, ~p"/ai/models/#{model.id}/edit")

      assert has_element?(view, "#ai-model-share-invite-ai_mode option[value='owner_key']", "My connection")
      refute has_element?(view, "#ai-model-share-invite-token_limit")

      view
      |> form("#ai-model-share-invite", share: %{role: "subscriber", ai_mode: "owner_key"})
      |> render_change()

      assert has_element?(view, "#ai-model-share-invite-token_limit")

      view
      |> form("#ai-model-share-invite",
        share: %{handle: invitee.handle, role: "subscriber", ai_mode: "owner_key", token_limit: "0"}
      )
      |> render_submit()

      assert render(view) =~ "must be a whole number above 0"
      assert Sharing.list_shares(Scope.for_user(user), model) == []

      view
      |> form("#ai-model-share-invite",
        share: %{handle: invitee.handle, role: "subscriber", ai_mode: "owner_key", token_limit: "5000"}
      )
      |> render_submit()

      assert [share] = Sharing.list_shares(Scope.for_user(user), model)
      assert share.ai_mode == :owner_key and share.token_limit_per_day == 5000
      assert has_element?(view, "#ai-model-share-ai-mode-#{share.id}-limit[value='5000']")

      view |> form("#ai-model-share-ai-mode-#{share.id}", %{token_limit: "1200"}) |> render_change()
      assert [%{ai_mode: :owner_key, token_limit_per_day: 1200}] = Sharing.list_shares(Scope.for_user(user), model)

      view |> form("#ai-model-share-ai-mode-#{share.id}", %{ai_mode: "own_key"}) |> render_change()
      assert [%{ai_mode: :own_key, token_limit_per_day: nil}] = Sharing.list_shares(Scope.for_user(user), model)
      refute has_element?(view, "#ai-model-share-ai-mode-#{share.id}-limit")
    end
  end

  describe "Fill from Hugging Face" do
    # Failed tokenizer loads log a warning by design.
    @describetag :capture_log

    @fixture File.read!("test/support/fixtures/word_level_tokenizer.json")

    setup do
      File.rm_rf!(Application.fetch_env!(:mythweaver, :tokenizer_cache_dir))
      :ok
    end

    test "compares, toggles, applies to the form, and saves only on submit", %{scope: scope, conn: conn} do
      stub_gguf()
      model = model!(scope, "Mine")
      {:ok, view, _html} = live(conn, ~p"/ai/models/#{model.id}/edit")

      open_compare(view)

      assert has_element?(view, "#hf-compare-modal")
      assert has_element?(view, "#hf-row-context_window.hf-row--applied")
      assert has_element?(view, "#hf-row-name:not(.hf-row--applied)")
      assert has_element?(view, "#hf-row-name", "Mine")
      assert has_element?(view, "#hf-row-name", "lv-base")

      view |> element("#hf-row-toggle-name") |> render_click()
      assert has_element?(view, "#hf-row-name.hf-row--applied")

      view |> element("#hf-row-toggle-context_window") |> render_click()
      refute has_element?(view, "#hf-row-context_window.hf-row--applied")

      view |> element("#hf-compare-apply") |> render_click()

      refute has_element?(view, "#hf-compare-modal")
      assert has_element?(view, "#ai-model-form-name[value='lv-base']")
      assert has_element?(view, "#ai-model-form-tokenizer[value='test/lv-base']")
      refute has_element?(view, "#ai-model-form-context_window[value='131072']")
      assert AI.get_model!(model.id).name == "Mine"

      view |> form("#ai-model-form") |> render_submit()

      reloaded = AI.get_model!(model.id)
      assert reloaded.name == "lv-base"
      assert reloaded.tokenizer == "test/lv-base"
      assert reloaded.context_window == nil
    end

    test "a gated or missing repo shows the HF_TOKEN hint and no modal", %{scope: scope, conn: conn} do
      Req.Test.stub(HuggingFace, &Plug.Conn.send_resp(&1, 401, ""))
      model = model!(scope, "Mine")
      {:ok, view, _html} = live(conn, ~p"/ai/models/#{model.id}/edit")

      open_compare(view)

      assert has_element?(view, "#ai-model-form-hf-error", "HF_TOKEN")
      refute has_element?(view, "#hf-compare-modal")
    end

    test "closing the modal leaves the form unchanged", %{scope: scope, conn: conn} do
      stub_gguf()
      model = model!(scope, "Mine")
      {:ok, view, _html} = live(conn, ~p"/ai/models/#{model.id}/edit")

      open_compare(view)
      render_hook(view, "close_hf_compare", %{})

      refute has_element?(view, "#hf-compare-modal")
      assert has_element?(view, "#ai-model-form-name[value='Mine']")
    end

    defp open_compare(view) do
      view
      |> form("#ai-model-form", model: %{tokenizer: "https://huggingface.co/test/lv-gguf"})
      |> render_change()

      view |> element("#ai-model-form-hf-fill") |> render_click()
      render_async(view)
    end

    defp stub_gguf do
      Req.Test.stub(HuggingFace, fn conn ->
        case conn.request_path do
          "/api/models/test/lv-gguf" ->
            Req.Test.json(conn, %{
              "siblings" => [%{"rfilename" => "model-Q4.gguf"}],
              "cardData" => %{"base_model" => "test/lv-base"},
              "gguf" => %{"context_length" => 131_072, "chat_template" => "{{ tools }}"}
            })

          "/api/models/test/lv-base" ->
            Req.Test.json(conn, %{"siblings" => [%{"rfilename" => "tokenizer.json"}]})

          "/test/lv-base/resolve/main/tokenizer.json" ->
            Plug.Conn.send_resp(conn, 200, @fixture)

          _ ->
            Plug.Conn.send_resp(conn, 404, "")
        end
      end)
    end
  end
end
