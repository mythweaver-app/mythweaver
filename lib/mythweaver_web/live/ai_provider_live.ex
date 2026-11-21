defmodule MythweaverWeb.AIProviderLive do
  @moduledoc """
  AI connection (provider) editor: the connection list on the left, the selected connection's form
  and its model connections on the right.

  Modelled on `MythweaverWeb.LoreBookLive`: stream + `apply_action/3` per `live_action`, no modals
  and no LiveComponents. `:index` selects nothing: the editor pane shows a placeholder until a
  connection is picked.

  Model connections (links) are one collapsed `<details>` row each, and every row owns a small form
  that saves on its own. One form per link, rather than one form for the connection and all its
  links, keeps `AI.link_model/3`/`AI.update_link/2` in charge of `selection_deadline`, and HTML
  forbids nesting them inside the connection form anyway. A write to one row rebuilds the others
  from the database but keeps their unsaved form state.

  Three connection fields are handled outside the changeset-backed form fields:

    * `api_key` is write-only. It is encrypted at rest (`Mythweaver.Encrypted.Binary`), but Cloak
      decrypts it on load and `redact: true` only affects `inspect/1`, so rendering
      `@form[:api_key]` would print the secret into the HTML on every edit. The input is
      fieldless, its text lives in the `api_key_input` assign, and a blank value is dropped from the
      attrs so an unchanged edit keeps the stored key.
    * The `api_key_input` assign is a `MythweaverWeb.SecretInput`, so a crash report prints it
      redacted. The event params of a crash's last message can still hold the key.
    * `extra_headers` and `extra_body` are `:map` columns, and `cast/3` rejects a raw string with
      `"is invalid"`. Both are fieldless JSON editors whose text lives in assigns
      (`headers_json`/`body_json`) and is parsed here before the changeset sees it.

  A link's selection state (`selection_deadline`, `last_used_at`, `use_count`) is never rendered as
  an input: `Mythweaver.AI` owns it and `ProviderModel.changeset/2` does not cast it. The link's
  `extra_body` is a fieldless JSON editor whose raw text lives in `link_body_json` (keyed by link
  id) or `new_link_body_json` and is parsed here before the changeset.

  Two tests mirror SillyTavern's. "Test connection" checks the form *as it stands*, saved or not,
  with `AI.check_provider/1` (`GET /models`). Each link's "Send test message" sends the *saved* link
  one capped "Hi" with `AI.test_link/1`, which is the only one of the two that proves the key on a
  provider whose `/models` is public. Both report through the flash.
  """

  use MythweaverWeb, :live_view

  import MythweaverWeb.BulkComponents
  import MythweaverWeb.Pane

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.AI.Embedding
  alias Mythweaver.AI.Provider
  alias Mythweaver.AI.Provider.Adapter
  alias Mythweaver.AI.Provider.SamplerDialect
  alias Mythweaver.AI.Provider.ThinkingDialect
  alias Mythweaver.AI.ProviderModel
  alias Mythweaver.Format
  alias MythweaverWeb.AIOwnership
  alias MythweaverWeb.Bulk
  alias MythweaverWeb.Bulk.Field
  alias MythweaverWeb.Bulk.Spec
  alias MythweaverWeb.JSONText
  alias MythweaverWeb.LiveSync
  alias MythweaverWeb.SecretInput
  alias Phoenix.HTML.Form

  on_mount MythweaverWeb.AIAccess
  on_mount MythweaverWeb.Sudo

  # What a link form may write. `ProviderModel.changeset/2` also casts `provider_id`/`ai_model_id`,
  # which a crafted payload must not be able to move.
  @link_fields ~w(api_model_id_override weight enabled extra_body thinking_dialect sampler_dialect)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: dpgettext("ai", "page title: AI connection editor", "AI connections"),
       form: nil,
       editing_provider: nil,
       api_key_input: %SecretInput{},
       headers_json: "{}",
       body_json: "{}",
       selected_id: nil,
       links: [],
       link_forms: %{},
       link_body_json: %{},
       new_link_form: nil,
       new_link_body_json: "{}",
       model_options: [],
       discovery: :idle,
       discovered: [],
       testing_connection?: false,
       testing_link_id: nil,
       new_owner: "personal",
       transfer: nil
     )
     |> stream_configure(:providers, dom_id: &"ai-providers-#{&1.id}")
     |> assign_filter()
     |> stream_providers()
     |> Bulk.attach([bulk_spec()])
     |> LiveSync.attach_editor([:ai], &sync/2)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> reset_discovery()
    |> reset_tests()
    |> assign(
      form: nil,
      editing_provider: nil,
      api_key_input: %SecretInput{},
      headers_json: "{}",
      body_json: "{}",
      selected_id: nil,
      links: [],
      link_forms: %{},
      link_body_json: %{},
      new_link_form: nil,
      new_owner: "personal",
      transfer: nil
    )
    |> stream_providers()
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> reset_discovery()
    |> reset_tests()
    |> assign(
      form: to_form(AI.change_provider(%Provider{})),
      editing_provider: nil,
      api_key_input: %SecretInput{},
      headers_json: "{}",
      body_json: "{}",
      selected_id: nil,
      links: [],
      link_forms: %{},
      link_body_json: %{},
      new_link_form: nil,
      new_owner: "personal",
      transfer: nil
    )
    |> stream_providers()
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case AI.get_provider(socket.assigns.current_scope, id) do
      nil ->
        socket
        |> put_flash(:error, not_found_flash())
        |> push_patch(to: ~p"/ai/providers")

      provider ->
        socket
        |> reset_discovery()
        |> reset_tests()
        |> assign(transfer: nil)
        |> open_provider(provider)
        |> stream_providers()
    end
  end

  defp open_provider(socket, provider) do
    socket
    |> assign(
      form: to_form(AI.change_provider(provider)),
      editing_provider: provider,
      selected_id: provider.id,
      api_key_input: %SecretInput{},
      headers_json: JSONText.encode(provider.extra_headers),
      body_json: JSONText.encode(provider.extra_body)
    )
    |> load_links(provider)
  end

  defp sync(socket, _kinds) do
    scope = socket.assigns.current_scope

    socket
    |> stream_providers()
    |> LiveSync.sync_open(:editing_provider,
      fetch: &AI.get_provider(scope, &1),
      clean?: provider_clean?(socket.assigns),
      reload: &open_provider/2,
      compare: fn a, b -> LiveSync.changed?(a, b) or link_rows(a) != link_rows(b) end,
      gone: ~p"/ai/providers",
      gone_message:
        (
          gettext_comment("Flash shown when the AI connection open in the editor was deleted or moved by someone else.")
          dgettext("ai", "The AI connection was deleted or moved elsewhere.")
        )
    )
  end

  defp provider_clean?(%{form: form, link_forms: link_forms, new_link_form: new_link_form}) do
    LiveSync.clean?(form) and
      Enum.all?(Map.values(link_forms), &is_nil(&1.action)) and
      (is_nil(new_link_form) or is_nil(new_link_form.action))
  end

  # A link's stored settings; the selection state `Mythweaver.AI` writes on every use is left out.
  defp link_rows(provider) do
    provider.provider_models
    |> Enum.map(
      &Map.take(&1, [
        :id,
        :ai_model_id,
        :enabled,
        :api_model_id_override,
        :weight,
        :extra_body,
        :thinking_dialect,
        :sampler_dialect
      ])
    )
    |> Enum.sort_by(& &1.id)
  end

  # Cancelled first so a slow discovery for the previous connection cannot land on this one.
  defp reset_discovery(socket) do
    socket
    |> cancel_async(:discover)
    |> assign(discovery: :idle, discovered: [])
  end

  # Cancelled for the same reason: a result must not be reported against the next connection.
  defp reset_tests(socket) do
    socket
    |> cancel_async(:test_connection)
    |> cancel_async(:test_link)
    |> assign(testing_connection?: false, testing_link_id: nil)
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, socket |> assign_filter(params) |> stream_providers()}
  end

  def handle_event("validate", %{"provider" => params} = all, socket) do
    socket = assign(socket, new_owner: AIOwnership.owner_choice(all))
    {attrs, json_errors} = normalize_params(params, socket)

    {:noreply,
     socket
     |> assign(form: to_form(validate_changeset(socket, attrs, json_errors)))
     |> assign_raw(params)}
  end

  def handle_event("save", %{"provider" => params} = all, socket) do
    socket = assign(socket, new_owner: AIOwnership.owner_choice(all))
    {attrs, json_errors} = normalize_params(params, socket)

    if json_errors == [] do
      save_provider(socket, attrs, params)
    else
      {:noreply,
       socket
       |> assign(form: to_form(validate_changeset(socket, attrs, json_errors)))
       |> assign_raw(params)
       |> put_flash(:error, save_failed_flash())}
    end
  end

  # Patches to `:index`, which selects nothing.
  def handle_event("delete", %{"id" => id}, socket) do
    case AI.get_provider(socket.assigns.current_scope, id) do
      nil ->
        {:noreply, socket}

      provider ->
        result = AI.delete_provider(socket.assigns.current_scope, provider)
        {:noreply, MythweaverWeb.HandOff.after_delete(socket, result, provider.name, ~p"/ai/providers")}
    end
  end

  def handle_event("prepare_transfer", _params, %{assigns: %{editing_provider: %Provider{} = provider}} = socket),
    do: {:noreply, AIOwnership.prepare(socket, provider)}

  def handle_event("cancel_transfer", _params, socket), do: {:noreply, assign(socket, transfer: nil)}

  def handle_event("transfer", params, %{assigns: %{editing_provider: %Provider{} = provider, transfer: %{}}} = socket),
    do: {:noreply, AIOwnership.run(socket, provider, &~p"/ai/providers/#{&1.id}/edit", params)}

  def handle_event("validate_link", %{"link_id" => id, "provider_model" => params}, socket) do
    case find_link(socket, id) do
      nil ->
        {:noreply, socket}

      link ->
        {socket, attrs, ok?} = take_link_params(socket, id, params)
        {:noreply, put_link_form(socket, link, link_changeset(link, attrs, ok?))}
    end
  end

  def handle_event("save_link", %{"link_id" => id, "provider_model" => params}, socket) do
    case find_link(socket, id) do
      nil ->
        {:noreply, socket}

      link ->
        {socket, attrs, ok?} = take_link_params(socket, id, params)

        result =
          if ok?,
            do: AI.update_link(socket.assigns.current_scope, link, attrs),
            else: {:error, link_changeset(link, attrs, ok?)}

        case result do
          {:ok, _link} ->
            {:noreply,
             socket
             |> refresh_links(other_link_ids(socket, id))
             |> put_flash(:info, link_saved_flash(link.model.name))}

          {:error, :unauthorized} ->
            {:noreply, flash_unauthorized(socket)}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             socket
             |> put_link_form(link, changeset)
             |> put_flash(:error, save_failed_flash())}
        end
    end
  end

  def handle_event("validate_new_link", %{"provider_model" => params}, socket) do
    {socket, attrs, ok?} = take_new_link_params(socket, params)
    {:noreply, assign(socket, new_link_form: link_form(nil, link_changeset(%ProviderModel{}, attrs, ok?)))}
  end

  def handle_event("create_link", %{"provider_model" => params}, socket) do
    {socket, attrs, ok?} = take_new_link_params(socket, params)

    if ok? do
      create_link(socket, attrs)
    else
      {:noreply,
       socket
       |> assign(new_link_form: link_form(nil, link_changeset(%ProviderModel{}, attrs, ok?)))
       |> put_flash(:error, save_failed_flash())}
    end
  end

  def handle_event("delete_link", %{"id" => id}, socket) do
    case find_link(socket, id) do
      nil ->
        {:noreply, socket}

      link ->
        case AI.delete_link(socket.assigns.current_scope, link) do
          {:ok, _} ->
            {:noreply,
             socket
             |> refresh_links(other_link_ids(socket, id))
             |> put_flash(:info, unlinked_flash(link.model.name))}

          {:error, _} ->
            {:noreply, flash_unauthorized(socket)}
        end
    end
  end

  # Enabling or disabling one slot is the common operation, and `update_link/2` rebases
  # `selection_deadline` on reactivation; a toggle saves on its own rather than through the row form.
  def handle_event("toggle_link", %{"id" => id}, socket) do
    case find_link(socket, id) do
      nil ->
        {:noreply, socket}

      link ->
        {:ok, _} = AI.update_link(socket.assigns.current_scope, link, %{enabled: !link.enabled})
        {:noreply, refresh_links(socket, other_link_ids(socket, id))}
    end
  end

  # `start_async` rather than a synchronous call: the request can take `provider.request_timeout_ms`
  # (120s by default), and blocking the LiveView process for that window means no spinner and no other
  # event handled. A crash inside the task arrives as `{:exit, reason}` instead of taking the socket
  # down, which is why this is not the `Task.Supervisor` + `make_ref` shape `Mythweaver.Jobs.stream_async/4` uses.
  def handle_event("discover", _params, socket) do
    provider = socket.assigns.editing_provider
    scope = socket.assigns.current_scope

    {:noreply,
     socket
     |> assign(discovery: :loading, discovered: [])
     |> start_async(:discover, Mythweaver.Locale.carry(fn -> AI.discover_models(scope, provider) end))}
  end

  # `validate` keeps `@form`'s changeset current, so it already holds the unsaved edits, and the
  # stored key when the key box is blank. `start_async` for the same reason as "discover".
  def handle_event("test_connection", _params, socket) do
    changeset = socket.assigns.form.source

    if changeset.valid? do
      provider = Ecto.Changeset.apply_changes(changeset)
      scope = socket.assigns.current_scope

      {:noreply,
       socket
       |> assign(testing_connection?: true)
       |> start_async(:test_connection, Mythweaver.Locale.carry(fn -> AI.check_provider(scope, provider) end))}
    else
      {:noreply,
       socket
       |> assign(form: to_form(Map.put(changeset, :action, :validate)))
       |> put_flash(:error, fix_before_test_flash())}
    end
  end

  def handle_event("test_link", %{"id" => id}, socket) do
    case find_link(socket, id) do
      nil ->
        {:noreply, socket}

      link ->
        link = %{link | provider: socket.assigns.editing_provider}
        scope = socket.assigns.current_scope

        {:noreply,
         socket
         |> assign(testing_link_id: link.id)
         |> start_async(:test_link, Mythweaver.Locale.carry(fn -> {link.model.name, AI.test_link(scope, link)} end))}
    end
  end

  # The entry is looked up in server-held state rather than trusted from `phx-value-*`: the prefill
  # attrs are a whole payload-derived map, and a client-supplied one would be an arbitrary write.
  # `as=embedding` / `as=classifier` add it as that kind, for backends that do not say what a model is.
  def handle_event("add_discovered", %{"id" => wire_id} = params, socket) do
    case Enum.find(socket.assigns.discovered, &(&1.id == wire_id)) do
      nil ->
        {:noreply,
         socket
         |> refresh_discovered()
         |> put_flash(:error, entry_gone_flash())}

      entry ->
        add_discovered(socket, entry, discovered_as(params["as"]))
    end
  end

  def handle_event("link_discovered", %{"model-id" => model_id}, socket) do
    case AI.link_discovered_model(socket.assigns.current_scope, socket.assigns.editing_provider, model_id) do
      {:ok, _link} ->
        {:noreply,
         socket
         |> refresh_links(all_link_ids(socket))
         |> refresh_discovered()
         |> put_flash(:info, linked_flash())}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> refresh_discovered()
         |> put_flash(:error, model_gone_flash())}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, link_rejected_flash(changeset))}
    end
  end

  @impl true
  def handle_async(:discover, {:ok, {:ok, entries}}, socket) do
    {:noreply, assign(socket, discovery: :loaded, discovered: entries)}
  end

  def handle_async(:discover, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(discovery: {:error, reason}, discovered: [])
     |> put_flash(:error, discovery_failed_flash(reason))}
  end

  # A raise or exit inside the task arrives here rather than as `{:ok, {:error, _}}`; without this
  # clause it would be an unmatched-function crash that takes the page down.
  def handle_async(:discover, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(discovery: {:error, :crashed}, discovered: [])
     |> put_flash(:error, crashed_flash(:discovery, reason))}
  end

  def handle_async(:test_connection, {:ok, {:ok, count}}, socket) do
    {:noreply,
     socket
     |> assign(testing_connection?: false)
     |> put_flash(:info, connected_flash(count))}
  end

  def handle_async(:test_connection, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(testing_connection?: false)
     |> put_flash(:error, connection_failed_flash(reason))}
  end

  def handle_async(:test_connection, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(testing_connection?: false)
     |> put_flash(:error, crashed_flash(:connection, reason))}
  end

  def handle_async(:test_link, {:ok, {name, {:ok, %Embedding{vectors: [vector | _]}}}}, socket) do
    {:noreply,
     socket
     |> assign(testing_link_id: nil)
     |> put_flash(:info, embedding_answered_flash(name, length(vector)))}
  end

  def handle_async(:test_link, {:ok, {name, {:ok, completion}}}, socket) do
    {:noreply,
     socket
     |> assign(testing_link_id: nil)
     |> put_flash(:info, reply_answered_flash(name, completion.text))}
  end

  def handle_async(:test_link, {:ok, {name, {:error, reason}}}, socket) do
    {:noreply,
     socket
     |> assign(testing_link_id: nil)
     |> put_flash(:error, link_failed_flash(name, reason))}
  end

  def handle_async(:test_link, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(testing_link_id: nil)
     |> put_flash(:error, crashed_flash(:link, reason))}
  end

  defp save_provider(socket, attrs, params) do
    result =
      case socket.assigns.editing_provider do
        nil ->
          AI.create_provider(socket.assigns.current_scope, attrs, site: socket.assigns.new_owner == "site")

        provider ->
          AI.update_provider(socket.assigns.current_scope, provider, attrs)
      end

    case result do
      {:ok, provider} ->
        {:noreply,
         socket
         |> put_flash(:info, saved_flash(provider.name))
         |> push_patch(to: ~p"/ai/providers/#{provider.id}/edit")}

      {:held, hold} ->
        path =
          case socket.assigns.editing_provider do
            nil -> ~p"/ai/providers"
            provider -> ~p"/ai/providers/#{provider.id}/edit"
          end

        {:noreply, socket |> flash_held(hold) |> push_patch(to: path)}

      {:error, :hold_limit} ->
        {:noreply, flash_hold_limit(socket)}

      {:error, :quota_exceeded} ->
        {:noreply, flash_quota(socket, "quota.ai_connections")}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> assign_raw(params)
         |> put_flash(:error, save_failed_flash())}
    end
  end

  defp validate_changeset(socket, attrs, json_errors) do
    changeset =
      socket
      |> target_provider()
      |> AI.change_provider(attrs)
      |> Map.put(:action, :validate)

    Enum.reduce(
      json_errors,
      changeset,
      &Ecto.Changeset.add_error(&2, &1, dgettext_noop("errors", "must be a JSON object"))
    )
  end

  defp target_provider(socket), do: socket.assigns.editing_provider || %Provider{}

  defp bulk_spec do
    %Spec{
      name: :providers,
      count_label:
        &dpngettext(
          "ai",
          "count phrase: AI connections affected by a bulk action",
          "%{connection_count} connection",
          "%{connection_count} connections",
          &1,
          connection_count: Mythweaver.Format.number(&1)
        ),
      ids: & &1.assigns.providers_ids,
      get: &AI.get_provider/2,
      update: &AI.update_provider/3,
      delete: &AI.delete_provider/2,
      title: & &1.name,
      refresh: &stream_providers/1,
      open_id: & &1.assigns.selected_id,
      index_path: ~p"/ai/providers",
      edit_path: &~p"/ai/providers/#{&1}/edit",
      fields: [
        %Field{
          key: :enabled,
          label: dpgettext("ai", "field label: AI connection is switched on", "Enabled"),
          type: :checkbox
        },
        %Field{
          key: :prompt_progress,
          label:
            dpgettext("ai", "field label: AI connection reports prompt reading progress", "Report prompt progress"),
          type: :checkbox
        },
        %Field{
          key: :priority,
          label: dpgettext("ai", "field label: AI connection selection priority", "Priority"),
          type: :select,
          options: for(n <- 1..5, do: {Format.number(n), n})
        },
        %Field{
          key: :thinking_dialect,
          label: dpgettext("ai", "field label: how an AI connection sends the thinking setting", "Thinking dialect"),
          type: :select,
          options: registry_options(ThinkingDialect.dialects()),
          prompt: dpgettext("ai", "option: no thinking dialect on an AI connection", "None")
        },
        %Field{
          key: :sampler_dialect,
          label: dpgettext("ai", "field label: how an AI connection names sampler settings", "Sampler dialect"),
          type: :select,
          options: registry_options(SamplerDialect.dialects()),
          prompt: dpgettext("ai", "option: no sampler dialect on an AI connection", "None")
        },
        %Field{
          key: :max_concurrency,
          label: dpgettext("ai", "field label: AI connection concurrency limit", "Max concurrent generations"),
          type: :number,
          min: 1
        },
        %Field{
          key: :request_timeout_ms,
          label: dpgettext("ai", "field label: AI connection request timeout in milliseconds", "Request timeout (ms)"),
          type: :number,
          min: 1
        }
      ]
    }
  end

  defp stream_providers(socket) do
    stream_search(socket, :providers, AI.list_providers(socket.assigns.current_scope), &[&1.name, &1.base_url])
  end

  # Returns `{attrs, json_error_fields}`: the params the changeset may cast, plus the JSON fields
  # whose text did not parse, which get an explicit changeset error instead of silently reverting
  # to `%{}`.
  defp normalize_params(params, socket) do
    {attrs, headers_ok?} =
      params
      |> Map.drop(["extra_headers", "extra_body"])
      |> reject_blank_api_key()
      |> JSONText.put_map("extra_headers", params["extra_headers"] || socket.assigns.headers_json)

    {attrs, body_ok?} =
      JSONText.put_map(attrs, "extra_body", params["extra_body"] || socket.assigns.body_json)

    {attrs, for({key, false} <- [extra_headers: headers_ok?, extra_body: body_ok?], do: key)}
  end

  # The raw text of the three fieldless inputs lives in assigns so it survives the `phx-change`
  # re-render; a partial payload that omits a key falls back to what is already there.
  defp assign_raw(socket, params) do
    assign(socket,
      api_key_input: %SecretInput{value: params["api_key"] || socket.assigns.api_key_input.value},
      headers_json: params["extra_headers"] || socket.assigns.headers_json,
      body_json: params["extra_body"] || socket.assigns.body_json
    )
  end

  defp reject_blank_api_key(attrs) do
    case attrs["api_key"] do
      key when is_binary(key) -> if String.trim(key) == "", do: Map.delete(attrs, "api_key"), else: attrs
      _ -> attrs
    end
  end

  ## Model connections

  # `link_model/3` seeds `selection_deadline` from the chosen model's active siblings, so it needs the
  # model row rather than just its id.
  defp create_link(socket, params) do
    case AI.get_editable_model(socket.assigns.current_scope, params["ai_model_id"]) do
      nil ->
        {:noreply, put_flash(socket, :error, pick_model_flash())}

      model ->
        attrs = Map.take(params, @link_fields)

        case AI.link_model(socket.assigns.current_scope, socket.assigns.editing_provider, model, attrs) do
          {:ok, _link} ->
            {:noreply,
             socket
             |> refresh_links(all_link_ids(socket))
             |> reset_new_link()
             |> put_flash(:info, model_linked_flash(model.name))}

          {:error, :unauthorized} ->
            {:noreply, flash_unauthorized(socket)}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             socket
             |> assign(new_link_form: link_form(nil, changeset))
             |> put_flash(:error, save_failed_flash())}
        end
    end
  end

  defp find_link(socket, id), do: Enum.find(socket.assigns.links, &(&1.id == id))

  defp all_link_ids(socket), do: Enum.map(socket.assigns.links, & &1.id)

  defp other_link_ids(socket, id), do: for(link <- socket.assigns.links, link.id != id, do: link.id)

  defp link_form(nil, changeset), do: to_form(changeset, id: "ai-link-form")
  defp link_form(link, changeset), do: to_form(changeset, id: "ai-link-form-#{link.id}")

  defp put_link_form(socket, link, changeset) do
    assign(socket, link_forms: Map.put(socket.assigns.link_forms, link.id, link_form(link, changeset)))
  end

  # Each returns `{socket, attrs, ok?}`: the decoded params, with the box's raw JSON text kept in
  # assigns. A partial `phx-change` payload that omits the box falls back to the text already there.
  defp take_link_params(socket, id, params) do
    params = Map.take(params, @link_fields)
    text = params["extra_body"] || socket.assigns.link_body_json[id]
    {attrs, ok?} = JSONText.put_map(params, "extra_body", text)
    {assign(socket, link_body_json: Map.put(socket.assigns.link_body_json, id, text)), attrs, ok?}
  end

  # The new-link form also writes `ai_model_id`, which `create_link/2` resolves and drops.
  defp take_new_link_params(socket, params) do
    text = params["extra_body"] || socket.assigns.new_link_body_json
    {attrs, ok?} = JSONText.put_map(params, "extra_body", text)
    {assign(socket, new_link_body_json: text), attrs, ok?}
  end

  defp link_changeset(link, attrs, ok?) do
    changeset =
      link
      |> AI.change_link(attrs)
      |> Map.put(:action, :validate)

    if ok?,
      do: changeset,
      else: Ecto.Changeset.add_error(changeset, :extra_body, dgettext_noop("errors", "must be a JSON object"))
  end

  defp load_links(socket, provider) do
    socket
    |> assign(link_forms: %{}, link_body_json: %{})
    |> assign_links(provider, [])
    |> reset_new_link()
  end

  # Re-reads the connection after a link write. Rows in `keep_ids` keep their unsaved form state;
  # every other row is rebuilt from the database and rows of deleted links drop out.
  defp refresh_links(socket, keep_ids) do
    case AI.get_provider(socket.assigns.current_scope, socket.assigns.selected_id) do
      nil ->
        push_patch(socket, to: ~p"/ai/providers")

      provider ->
        socket
        |> assign(editing_provider: provider)
        |> assign_links(provider, keep_ids)
        |> stream_providers()
    end
  end

  # The `provider_models` preload is unordered.
  defp assign_links(socket, provider, keep_ids) do
    links = Enum.sort_by(provider.provider_models, & &1.model.name)
    %{link_forms: forms, link_body_json: bodies} = socket.assigns

    {forms, bodies} =
      Enum.reduce(links, {%{}, %{}}, fn link, {acc_forms, acc_bodies} ->
        if link.id in keep_ids and Map.has_key?(forms, link.id) do
          {Map.put(acc_forms, link.id, forms[link.id]), Map.put(acc_bodies, link.id, bodies[link.id])}
        else
          {Map.put(acc_forms, link.id, link_form(link, AI.change_link(link))),
           Map.put(acc_bodies, link.id, JSONText.encode(link.extra_body))}
        end
      end)

    assign(socket,
      links: links,
      link_forms: forms,
      link_body_json: bodies,
      model_options: AI.link_model_options(provider)
    )
  end

  defp reset_new_link(socket) do
    assign(socket,
      new_link_form: link_form(nil, AI.change_link(%ProviderModel{})),
      new_link_body_json: "{}"
    )
  end

  ## Discovery and test messages

  # The discovery section's own error line (the flash says more): a lowercase reason, in `errors`
  # like the other spliced-in reasons.
  defp discovery_error(:unauthorized), do: dgettext("errors", "you're not allowed to do that")
  defp discovery_error(:crashed), do: dgettext("errors", "the request crashed")

  defp discovery_error({:http_error, status, _body}),
    do: dgettext("errors", "the provider answered HTTP %{http_status}", http_status: status)

  defp discovery_error({:transport_error, message}) do
    gettext_comment("%{error_detail} is the network error's own text, in English.")
    dgettext("errors", "could not reach the provider (%{error_detail})", error_detail: message)
  end

  defp discovery_error({:unexpected_body, _body}), do: dgettext("errors", "the provider's /models reply was unreadable")
  defp discovery_error(reason), do: inspect(reason)

  defp discovery_failed_flash(:unauthorized) do
    gettext_comment("Flash when listing a connection's models fails.")
    dgettext("ai", "Discovery failed: you're not allowed to do that")
  end

  defp discovery_failed_flash({:http_error, status, _body}) do
    gettext_comment("Flash when listing a connection's models fails.")
    dgettext("ai", "Discovery failed: the provider answered HTTP %{http_status}", http_status: status)
  end

  defp discovery_failed_flash({:transport_error, message}) do
    gettext_comment(
      "Flash when listing a connection's models fails. %{error_detail} is the network error's own text, in English."
    )

    dgettext("ai", "Discovery failed: could not reach the provider (%{error_detail})", error_detail: message)
  end

  defp discovery_failed_flash({:unexpected_body, _body}) do
    gettext_comment("Flash when listing a connection's models fails.")
    dgettext("ai", "Discovery failed: the provider's /models reply was unreadable")
  end

  defp discovery_failed_flash(reason) do
    gettext_comment("Flash when listing a connection's models fails. %{error_detail} is an internal error term.")

    dpgettext("ai", "status: flash after listing a connection's models failed", "Discovery failed: %{error_detail}",
      error_detail: inspect(reason)
    )
  end

  defp connection_failed_flash(:unauthorized) do
    gettext_comment("Flash when the Test connection button's check fails.")
    dgettext("ai", "Connection test failed: you're not allowed to do that")
  end

  defp connection_failed_flash({:http_error, status, _body}) do
    gettext_comment("Flash when the Test connection button's check fails.")
    dgettext("ai", "Connection test failed: the provider answered HTTP %{http_status}", http_status: status)
  end

  defp connection_failed_flash({:transport_error, message}) do
    gettext_comment(
      "Flash when the Test connection button's check fails. %{error_detail} is the network error's own text, in English."
    )

    dgettext("ai", "Connection test failed: could not reach the provider (%{error_detail})", error_detail: message)
  end

  defp connection_failed_flash({:unexpected_body, _body}) do
    gettext_comment("Flash when the Test connection button's check fails.")
    dgettext("ai", "Connection test failed: the provider's /models reply was unreadable")
  end

  defp connection_failed_flash(reason) do
    gettext_comment("Flash when the Test connection button's check fails. %{error_detail} is an internal error term.")

    dpgettext("ai", "status: flash after an AI connection test failed", "Connection test failed: %{error_detail}",
      error_detail: inspect(reason)
    )
  end

  defp link_failed_flash(name, :unauthorized) do
    gettext_comment("Flash when a model link's test message fails.")
    dgettext("ai", "%{model_name} test failed: you're not allowed to do that", model_name: name)
  end

  defp link_failed_flash(name, {:http_error, status, _body}) do
    gettext_comment("Flash when a model link's test message fails.")

    dgettext("ai", "%{model_name} test failed: the provider answered HTTP %{http_status}",
      model_name: name,
      http_status: status
    )
  end

  defp link_failed_flash(name, {:transport_error, message}) do
    gettext_comment(
      "Flash when a model link's test message fails. %{error_detail} is the network error's own text, in English."
    )

    dgettext("ai", "%{model_name} test failed: could not reach the provider (%{error_detail})",
      model_name: name,
      error_detail: message
    )
  end

  defp link_failed_flash(name, {:unexpected_body, _body}) do
    gettext_comment("Flash when a model link's test message fails.")
    dgettext("ai", "%{model_name} test failed: the reply carried no completion", model_name: name)
  end

  defp link_failed_flash(name, reason) do
    gettext_comment("Flash when a model link's test message fails. %{error_detail} is an internal error term.")

    dpgettext(
      "ai",
      "status: flash after a model link's test message failed",
      "%{model_name} test failed: %{error_detail}",
      model_name: name,
      error_detail: inspect(reason)
    )
  end

  defp crashed_flash(:discovery, reason) do
    gettext_comment("Flash when listing a connection's models crashed. %{error_detail} is an internal error term.")

    dpgettext("ai", "status: flash after listing a connection's models crashed", "Discovery crashed: %{error_detail}",
      error_detail: inspect(reason)
    )
  end

  defp crashed_flash(:connection, reason) do
    gettext_comment("Flash when the Test connection check crashed. %{error_detail} is an internal error term.")

    dpgettext("ai", "status: flash after an AI connection test crashed", "Connection test crashed: %{error_detail}",
      error_detail: inspect(reason)
    )
  end

  defp crashed_flash(:link, reason) do
    gettext_comment("Flash when a model link's test message crashed. %{error_detail} is an internal error term.")

    dpgettext("ai", "status: flash after a model link's test message crashed", "Test message crashed: %{error_detail}",
      error_detail: inspect(reason)
    )
  end

  defp connected_flash(count) do
    gettext_comment("Flash when the Test connection button's check succeeds.")

    dngettext(
      "ai",
      "Connected: /models answered HTTP 200 with %{model_count} model",
      "Connected: /models answered HTTP 200 with %{model_count} models",
      count,
      model_count: Format.number(count)
    )
  end

  defp embedding_answered_flash(name, dimensions) do
    gettext_comment("Flash when an embedding model's test request succeeds.")

    dgettext("ai", "%{model_name} answered HTTP 200: a %{dimension_count}-dimension embedding",
      model_name: name,
      dimension_count: Format.number(dimensions)
    )
  end

  # Remote text, so bounded; a thinking model can spend the whole cap before any reply text.
  defp reply_answered_flash(name, text) do
    case String.trim(text || "") do
      "" ->
        gettext_comment("Flash when a model's test message got an answer with no text in it.")
        dgettext("ai", "%{model_name} answered HTTP 200: no reply text within the token cap", model_name: name)

      text ->
        gettext_comment(
          "Flash when a model's test message got an answer. %{reply_excerpt} is the start of the reply, in quotes."
        )

        dgettext("ai", "%{model_name} answered HTTP 200: %{reply_excerpt}",
          model_name: name,
          reply_excerpt: inspect(String.slice(text, 0, 80))
        )
    end
  end

  defp not_found_flash do
    gettext_comment("Flash when the AI connection in the address no longer exists or is not yours.")
    dpgettext("ai", "status: flash when an AI connection could not be found", "AI connection not found")
  end

  defp save_failed_flash do
    gettext_comment("Flash when a form did not save because of invalid fields.")
    dgettext("ai", "Could not save — see the highlighted fields")
  end

  defp saved_flash(name) do
    gettext_comment("Flash after an AI connection was saved.")
    dpgettext("ai", "status: flash after saving an AI connection", "%{connection_name} saved", connection_name: name)
  end

  defp link_saved_flash(name) do
    gettext_comment("Flash after a model link's settings were saved.")
    dpgettext("ai", "status: flash after saving a model link's settings", "%{model_name} updated", model_name: name)
  end

  defp unlinked_flash(name) do
    gettext_comment("Flash after a model was unlinked from the connection.")

    dpgettext("ai", "status: flash after unlinking a model from an AI connection", "%{model_name} unlinked",
      model_name: name
    )
  end

  defp model_linked_flash(name) do
    gettext_comment("Flash after a model was linked to the connection.")
    dpgettext("ai", "status: flash after linking a model to an AI connection", "%{model_name} linked", model_name: name)
  end

  defp linked_flash do
    gettext_comment("Flash after a discovered model was linked to the connection.")
    dpgettext("ai", "status: a discovered model was linked to the connection", "Linked")
  end

  defp fix_before_test_flash do
    gettext_comment("Flash when Test connection is pressed while the form has invalid fields.")
    dgettext("ai", "Fix the highlighted fields before testing")
  end

  defp entry_gone_flash do
    gettext_comment("Flash when adding a discovered model that is no longer in the discovered list.")
    dgettext("ai", "That model is no longer in the list")
  end

  defp model_gone_flash do
    gettext_comment("Flash when linking a discovered model whose model row was deleted.")
    dgettext("ai", "That model no longer exists")
  end

  defp pick_model_flash do
    gettext_comment("Flash when Link is pressed with no model chosen.")
    dgettext("ai", "Pick a model to link")
  end

  defp added_flash(name) do
    gettext_comment("Flash after a discovered model was created and linked to the connection.")

    dpgettext(
      "ai",
      "status: flash after creating a discovered model and linking it to an AI connection",
      "%{model_name} added and linked",
      model_name: name
    )
  end

  defp link_rejected_flash(%Ecto.Changeset{errors: [{field, _} | _]} = changeset) do
    gettext_comment(
      "Flash when linking a discovered model was rejected. %{field_name} is the internal field name, %{error_messages} its validation errors."
    )

    dgettext("ai", "Could not link: %{field_name} %{error_messages}",
      field_name: field,
      error_messages: Format.list(translate_errors(changeset.errors, field))
    )
  end

  defp link_rejected_flash(%Ecto.Changeset{}) do
    gettext_comment("Flash when linking a discovered model was rejected.")
    dgettext("ai", "Could not link: it was rejected")
  end

  defp add_rejected_flash(name, %Ecto.Changeset{errors: [{field, _} | _]} = changeset) do
    gettext_comment(
      "Flash when adding a discovered model was rejected. %{field_name} is the internal field name, %{error_messages} its validation errors."
    )

    dgettext("ai", "Could not add %{model_name}: %{field_name} %{error_messages}",
      model_name: name,
      field_name: field,
      error_messages: Format.list(translate_errors(changeset.errors, field))
    )
  end

  defp add_rejected_flash(name, %Ecto.Changeset{}) do
    gettext_comment("Flash when adding a discovered model was rejected.")
    dgettext("ai", "Could not add %{model_name}: it was rejected", model_name: name)
  end

  defp add_discovered(socket, entry, opts) do
    case AI.create_discovered_model(socket.assigns.current_scope, socket.assigns.editing_provider, entry, opts) do
      {:ok, model} ->
        {:noreply,
         socket
         |> refresh_links(all_link_ids(socket))
         |> refresh_discovered()
         |> put_flash(:info, added_flash(model.name))}

      {:error, :quota_exceeded} ->
        {:noreply, flash_quota(socket, "quota.ai_models")}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, add_rejected_flash(entry.name, changeset))}
    end
  end

  defp discovered_as("embedding"), do: [as: :embedding]
  defp discovered_as("classifier"), do: [as: :classifier]
  defp discovered_as(_as), do: []

  # One `" · "`-joined line so a row stays one line. There is no `notes` segment because the adapter
  # never extracts a provider's `description` at all (see `model_attrs/1`).
  defp discovery_facts(attrs) do
    [
      fact(attrs["completion_mode"], &mode_fact/1),
      fact(attrs["context_window"], fn tokens ->
        dpgettext("ai", "unit: context window of a discovered model", "%{token_count} ctx",
          token_count: Format.number(tokens)
        )
      end),
      fact(attrs["prompt_cost_per_mtok"], fn cost ->
        dpgettext("ai", "unit: prompt price per million tokens of a discovered model", "%{price}/Mtok in",
          price: price(cost)
        )
      end),
      fact(attrs["completion_cost_per_mtok"], fn cost ->
        dpgettext("ai", "unit: completion price per million tokens of a discovered model", "%{price}/Mtok out",
          price: price(cost)
        )
      end),
      fact(attrs["supports_images"], fn _true ->
        dpgettext("ai", "badge: a discovered model accepts images", "images")
      end),
      fact(attrs["supports_files"], fn _true -> dpgettext("ai", "badge: a discovered model accepts files", "files") end),
      fact(attrs["supports_audio"], fn _true -> dpgettext("ai", "badge: a discovered model accepts audio", "audio") end),
      fact(attrs["supports_video"], fn _true -> dpgettext("ai", "badge: a discovered model accepts video", "video") end),
      fact(attrs["supports_tools"], fn _true -> dpgettext("ai", "badge: a discovered model can call tools", "tools") end),
      fact(attrs["supports_thinking"], fn _true ->
        dpgettext("ai", "badge: a discovered model can reason before replying", "thinking")
      end)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp mode_fact("embedding"), do: dpgettext("ai", "badge: a discovered model makes embeddings", "embedding")
  defp mode_fact("classifier"), do: dpgettext("ai", "badge: a discovered model is a classifier", "classifier")

  # A per-million-token price keeps every digit the provider gave, at least cents.
  defp price(%Decimal{} = amount) do
    digits = max(-Decimal.normalize(amount).exp, 2)
    Format.number(amount, currency: :USD, fractional_digits: digits)
  end

  defp fact(nil, _format), do: nil
  defp fact(false, _format), do: nil
  defp fact(value, format), do: format.(value)

  # Re-annotates the rows already on screen after a write, so the row just added flips to `known` +
  # `Linked` in place with no second HTTP request.
  defp refresh_discovered(%{assigns: %{discovered: []}} = socket), do: socket

  defp refresh_discovered(socket) do
    assign(socket,
      discovered:
        AI.annotate_discovered(socket.assigns.current_scope, socket.assigns.editing_provider, socket.assigns.discovered)
    )
  end

  defp delete_confirm(name) do
    gettext_comment("Confirm dialog before deleting an AI connection.")
    dgettext("ai", "Delete %{connection_name}? Its model links go with it.", connection_name: name)
  end

  defp unlink_confirm(model_name, connection_name) do
    gettext_comment("Confirm dialog before removing a model's link to an AI connection.")

    dpgettext(
      "ai",
      "status: confirm dialog before unlinking a model from an AI connection",
      "Unlink %{model_name} from %{connection_name}?",
      model_name: model_name,
      connection_name: connection_name
    )
  end

  # Read from the registries rather than hardcoding the enums, so a newly registered adapter or
  # dialect appears without touching this file.
  defp registry_options(registry) do
    registry
    |> Enum.map(fn {key, module} -> {module.label(), key} end)
    |> Enum.sort()
  end

  # The selected adapter, a stored atom or a submitted string, offers the opt-in only if it can report
  # progress at all (`Adapter.prompt_progress?/1`).
  defp prompt_progress?(selected) do
    case Enum.find(Map.keys(Adapter.adapters()), &(to_string(&1) == to_string(selected))) do
      nil -> false
      adapter -> Adapter.prompt_progress?(adapter)
    end
  end

  attr :form, Form, required: true
  attr :body_json, :string, required: true

  # The fields a saved link's form shares with the new-link form; ids derive from the form's own id
  # (`link_form/2`).
  defp link_fields(assigns) do
    ~H"""
    <.input
      field={@form[:api_model_id_override]}
      type="text"
      label={dgettext("ai", "API model id override (blank uses the model's own id)")}
      id={"#{@form.id}-api_model_id_override"}
    />
    <.input
      field={@form[:weight]}
      type="number"
      label={dgettext("ai", "Weight (share of traffic within this priority tier)")}
      id={"#{@form.id}-weight"}
      min="1"
    />
    <.input
      field={@form[:thinking_dialect]}
      type="select"
      label={dgettext("ai", "Thinking dialect (overrides the connection)")}
      prompt={
        dpgettext(
          "ai",
          "option: a model link uses its connection's dialect",
          "Inherit from connection"
        )
      }
      options={registry_options(ThinkingDialect.dialects())}
      id={"#{@form.id}-thinking_dialect"}
    />
    <.input
      field={@form[:sampler_dialect]}
      type="select"
      label={dgettext("ai", "Sampler dialect (overrides the connection)")}
      prompt={
        dpgettext(
          "ai",
          "option: a model link uses its connection's dialect",
          "Inherit from connection"
        )
      }
      options={registry_options(SamplerDialect.dialects())}
      id={"#{@form.id}-sampler_dialect"}
    />
    <.editor
      name="provider_model[extra_body]"
      id={"#{@form.id}-extra_body"}
      label={
        dgettext("ai", "Extra request body (JSON object; overrides the model and the connection)")
      }
      rows={3}
      language="json"
      line_numbers
      value={@body_json}
      errors={translate_errors(@form.errors, :extra_body)}
    />
    <.input
      field={@form[:enabled]}
      type="checkbox"
      label={dpgettext("ai", "field label: a model link is switched on", "Enabled")}
      id={"#{@form.id}-enabled"}
    />
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!--
      `lower-bound="none"`: rules here may reach inside
      `<.input>`'s own template, which is a nested-component root carrying `phx-r` that the default
      exclusive bound cuts off. With no lower bound every element carrying this block's scope marker
      is a scope root, including the root `div` of each `<.form>` slot.
    --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      /* The editor slot's root. `pane_layout`'s `<section>` carries no marker from this block, so
         without it `<.form>` and the links section would sit outside this scope. */
      div.ai-provider-editor-body:scope {
        display: contents;
      }

      .ai-provider-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .ai-provider-form label {
        display: block;
      }

      .ai-links-empty {
        margin: 0;
        color: var(--muted-foreground);
      }

      .ai-links-list {
        border: 1px solid var(--border-grey);
        border-radius: var(--radius-2);
        background: var(--surface-2);
      }

      details.ai-link-row {
        --disclosure-summary-padding: var(--size-2);
        border-bottom: 1px solid var(--border-grey);
      }

      details.ai-link-row:last-child {
        border-bottom: 0;
      }

      .ai-link-row-id {
        font-family: var(--font-monospace-code, ui-monospace, monospace);
        color: var(--muted-foreground);
        overflow-wrap: anywhere;
      }

      .ai-link-row-meta {
        color: var(--muted-foreground);
      }

      .ai-link-form {
        padding: 0 var(--size-3) var(--size-3);
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .ai-link-form label {
        display: block;
      }

      .ai-provider-link {
        display: inline-flex;
        align-items: center;
        gap: var(--size-1);
        color: var(--muted-foreground);
        text-decoration: none;
      }

      button.ai-provider-link {
        align-self: flex-start;
        background: none;
        border: 0;
        font: inherit;
        cursor: pointer;
      }

      .ai-discovery-note {
        margin: 0;
        color: var(--muted-foreground);
      }

      .ai-discovery-error {
        margin: 0;
        color: var(--destructive);
      }

      .ai-discovery-list {
        list-style: none;
        margin: 0;
        padding: 0;
        border: 1px solid var(--border-grey);
        border-radius: var(--radius-2);
        background: var(--surface-2);
      }

      .ai-discovery-row {
        display: flex;
        align-items: center;
        gap: var(--size-2);
        padding: var(--size-2) var(--size-3);
        border-bottom: 1px solid var(--border-grey);
      }

      .ai-discovery-row:last-child {
        border-bottom: 0;
      }

      .ai-discovery-row-text {
        display: flex;
        flex-direction: column;
        margin-right: auto;
        min-width: 0;
      }

      .ai-discovery-row-id {
        font-family: var(--font-monospace-code, ui-monospace, monospace);
        color: var(--muted-foreground);
        overflow-wrap: anywhere;
      }

      .ai-discovery-row-facts {
        color: var(--muted-foreground);
        font-size: 0.85rem;
      }

      .ai-discovery-done {
        color: var(--muted-foreground);
      }
    </style>
    <Layouts.app flash={@flash} current_scope={@current_scope} search={:ai}>
      <.pane_layout>
        <:list
          id="ai-providers-nav"
          label={dpgettext("ai", "aria label: list of AI connections", "AI connections")}
        >
          <.pane_header title={dpgettext("ai", "heading: list of AI connections", "Connections")}>
            <:switch id="pane-switch-models" navigate={~p"/ai/models"}>
              <.lucide name="cpu" /> {dpgettext("ai", "link: switch to the AI model editor", "Models")}
            </:switch>
          </.pane_header>

          <.pane_actions>
            <.button variant="primary" patch={~p"/ai/providers/new"} id="new-ai-provider">
              <.lucide name="plus" /> {dpgettext(
                "ai",
                "button: create an AI connection",
                "New connection"
              )}
            </.button>
            <.bulk_toggle bulk={@bulk} id="providers-bulk-toggle" />
          </.pane_actions>
          <.bulk_bar bulk={@bulk} id="providers-bulk" />

          <.pane_search
            id="ai-provider-filter"
            form={@filter_form}
            placeholder={dpgettext("ai", "placeholder: search AI connections", "Name or URL")}
          />

          <.pane_items
            :let={provider}
            id="ai-providers"
            rows={@streams.providers}
            bulk={@bulk}
            bulk_list="providers"
            patch={fn provider -> ~p"/ai/providers/#{provider.id}/edit" end}
            selected_id={@selected_id}
            empty?={@providers_empty?}
            empty={
              if @query == "",
                do: dpgettext("ai", "empty state: no AI connections exist", "No AI connections yet"),
                else: dgettext("ai", "No connections match this search")
            }
          >
            <span class="pane-item-name">{provider.name}</span>
            <span class="pane-item-meta">
              {dngettext(
                "ai",
                "%{model_count} model · priority %{priority}",
                "%{model_count} models · priority %{priority}",
                provider.model_count,
                model_count: Format.number(provider.model_count),
                priority: Format.number(provider.priority)
              )}
            </span>
            <span
              :if={
                !provider.enabled or provider.api_key in [nil, ""] or
                  AIOwnership.personal_badge?(provider, @current_scope)
              }
              class="pane-item-badges"
            >
              <.badge
                :if={AIOwnership.personal_badge?(provider, @current_scope)}
                id={"ai-providers-personal-#{provider.id}"}
              >
                {dpgettext("ai", "badge: a personal AI connection", "personal")}
              </.badge>
              <.badge :if={!provider.enabled}>
                {dpgettext("ai", "badge: an AI connection switched off", "disabled")}
              </.badge>
              <.badge :if={provider.api_key in [nil, ""]}>
                {dpgettext("ai", "badge: an AI connection with no API key", "no key")}
              </.badge>
            </span>
          </.pane_items>
        </:list>

        <:editor id="ai-provider-editor">
          <.pane_placeholder :if={@live_action == :index} id="ai-provider-placeholder">
            {dgettext("ai", "Select a connection, or create a new one.")}
          </.pane_placeholder>
          <div :if={@live_action != :index} class="ai-provider-editor-body">
            <.panel_header sticky>
              {if @editing_provider,
                do: @editing_provider.name,
                else: dpgettext("ai", "heading: form creating an AI connection", "New connection")}
              <:actions :if={@editing_provider}>
                <.pane_delete
                  id="delete-ai-provider"
                  phx-click="delete"
                  phx-value-id={@editing_provider.id}
                  confirm={delete_confirm(@editing_provider.name)}
                >
                  {dpgettext("ai", "button: delete this AI connection", "Delete")}
                </.pane_delete>
              </:actions>
            </.panel_header>

            <.pane_section>
              <.changed_elsewhere
                :if={@changed_elsewhere?}
                id="ai-provider-changed-elsewhere"
                patch={@live_sync_path}
              />
              <.form
                for={@form}
                id="ai-provider-form"
                class="ai-provider-form"
                phx-hook="UnsavedChanges"
                data-saved={is_nil(@form.action)}
                phx-change="validate"
                phx-submit="save"
              >
                <AIOwnership.owner_select
                  :if={is_nil(@editing_provider) and AI.owner_choice?(@current_scope)}
                  id="ai-provider-form-owner"
                  value={@new_owner}
                  kind={:connection}
                />
                <AIOwnership.owner_line
                  :if={@editing_provider && Scope.can?(@current_scope, "site.ai.manage")}
                  id="ai-provider-owner"
                  row={@editing_provider}
                  kind={:connection}
                />
                <.input
                  field={@form[:name]}
                  type="text"
                  label={dpgettext("ai", "field label: name of an AI connection", "Name")}
                  id="ai-provider-form-name"
                  required
                />
                <.input
                  field={@form[:adapter]}
                  type="select"
                  label={dpgettext("ai", "field label: API type of an AI connection", "Adapter")}
                  options={registry_options(Adapter.adapters())}
                  id="ai-provider-form-adapter"
                />
                <.input
                  field={@form[:thinking_dialect]}
                  type="select"
                  label={
                    dpgettext(
                      "ai",
                      "field label: how an AI connection sends the thinking setting",
                      "Thinking dialect"
                    )
                  }
                  prompt={dgettext("ai", "None (thinking setting not sent)")}
                  options={registry_options(ThinkingDialect.dialects())}
                  id="ai-provider-form-thinking_dialect"
                />
                <.input
                  field={@form[:sampler_dialect]}
                  type="select"
                  label={
                    dpgettext(
                      "ai",
                      "field label: how an AI connection names sampler settings",
                      "Sampler dialect"
                    )
                  }
                  prompt={dgettext("ai", "Generic (canonical names: vLLM, TabbyAPI, others)")}
                  options={registry_options(SamplerDialect.dialects())}
                  id="ai-provider-form-sampler_dialect"
                >
                  <:hint>
                    {dgettext(
                      "ai",
                      "How sampler settings are named on the wire. llama.cpp renames repetition penalties and converts dynamic temperature; OpenAI (strict) sends only the parameters OpenAI accepts."
                    )}
                  </:hint>
                </.input>
                <.input
                  field={@form[:base_url]}
                  type="text"
                  label={
                    dpgettext("ai", "field label: base URL of an AI connection's API", "Base URL")
                  }
                  id="ai-provider-form-base_url"
                  placeholder="http://localhost:8080/v1"
                  required
                />
                <.input
                  type="password"
                  name="provider[api_key]"
                  id="ai-provider-form-api_key"
                  label={dgettext("ai", "API key (leave blank to keep the stored key)")}
                  value={@api_key_input.value}
                />
                <.input
                  field={@form[:priority]}
                  type="select"
                  label={dpgettext("ai", "field label: AI connection selection priority", "Priority")}
                  options={Enum.map(1..5, &{Format.number(&1), &1})}
                  id="ai-provider-form-priority"
                />
                <.input
                  field={@form[:request_timeout_ms]}
                  type="number"
                  label={
                    dpgettext(
                      "ai",
                      "field label: AI connection request timeout in milliseconds",
                      "Request timeout (ms)"
                    )
                  }
                  id="ai-provider-form-request_timeout_ms"
                  min="1"
                />
                <.input
                  field={@form[:max_concurrency]}
                  type="number"
                  label={
                    dpgettext(
                      "ai",
                      "field label: AI connection concurrency limit",
                      "Max concurrent generations"
                    )
                  }
                  id="ai-provider-form-max_concurrency"
                  min="1"
                />
                <.editor
                  name="provider[extra_headers]"
                  id="ai-provider-form-extra_headers"
                  label={
                    dpgettext(
                      "ai",
                      "field label: extra HTTP headers of an AI connection",
                      "Extra headers (JSON object)"
                    )
                  }
                  rows={3}
                  language="json"
                  line_numbers
                  value={@headers_json}
                  errors={translate_errors(@form.errors, :extra_headers)}
                />
                <.editor
                  name="provider[extra_body]"
                  id="ai-provider-form-extra_body"
                  label={
                    dpgettext(
                      "ai",
                      "field label: extra request body of an AI connection",
                      "Extra body (JSON object)"
                    )
                  }
                  rows={3}
                  language="json"
                  line_numbers
                  value={@body_json}
                  errors={translate_errors(@form.errors, :extra_body)}
                />
                <.input
                  :if={prompt_progress?(@form[:adapter].value)}
                  field={@form[:prompt_progress]}
                  type="checkbox"
                  label={dgettext("ai", "Report prompt progress (llama.cpp and TabbyAPI only)")}
                  id="ai-provider-form-prompt_progress"
                />
                <.input
                  field={@form[:enabled]}
                  type="checkbox"
                  label={dpgettext("ai", "field label: AI connection is switched on", "Enabled")}
                  id="ai-provider-form-enabled"
                />
                <.form_actions>
                  <:start>
                    <.button
                      id="test-ai-provider"
                      phx-click="test_connection"
                      disabled={@testing_connection?}
                    >
                      <.lucide name="plug-zap" />
                      {if @testing_connection?,
                        do: dpgettext("ai", "button: connection test in progress", "Testing…"),
                        else:
                          dpgettext(
                            "ai",
                            "button: check that an AI connection answers",
                            "Test connection"
                          )}
                    </.button>
                  </:start>
                  <.button patch={
                    if @editing_provider,
                      do: ~p"/ai/providers/#{@editing_provider.id}/edit",
                      else: ~p"/ai/providers"
                  }>
                    {dpgettext("ai", "button: discard edits to the AI connection form", "Cancel")}
                  </.button>
                  <.button type="submit" variant="primary">
                    {dpgettext("ai", "button: save the AI connection form", "Save")}
                  </.button>
                </.form_actions>
              </.form>
            </.pane_section>

            <.pane_section :if={@editing_provider} id="ai-links-section">
              <.section_header>
                {dpgettext("ai", "heading: models linked to an AI connection", "Model connections")}
              </.section_header>

              <p :if={@model_options == []} class="ai-links-empty">
                {dgettext("ai", "Create an AI model first.")}
                <.link navigate={~p"/ai/models/new"}>
                  {dpgettext("ai", "link: create an AI model", "New model")}
                </.link>
              </p>

              <p :if={@links == []} id="ai-links-empty" class="ai-links-empty">
                {dgettext("ai", "No models linked to this connection yet")}
              </p>

              <div class="ai-links-list">
                <%!--
              A plain `:for`, not a stream: each row owns its own form state, and the list is one
              connection's links. `<.disclosure>` keeps a row the user expanded open across the
              `phx-change` re-render; rows start collapsed.
            --%>
                <.disclosure :for={link <- @links} id={"ai-links-#{link.id}"} class="ai-link-row">
                  <:title>{link.model.name}</:title>
                  <:summary_extra>
                    <span class="ai-link-row-id">{ProviderModel.effective_model_id(link)}</span>
                    <span class="ai-link-row-meta">
                      {dpgettext(
                        "ai",
                        "badge: a model link's traffic weight and use count",
                        "weight %{weight} · used %{use_count}x",
                        weight: Format.number(link.weight),
                        use_count: Format.number(link.use_count)
                      )}
                    </span>
                    <.badge :if={!link.enabled}>
                      {dpgettext("ai", "badge: a model link switched off", "disabled")}
                    </.badge>
                    <.badge :if={link.api_model_id_override not in [nil, ""]}>
                      {dpgettext("ai", "badge: a model link overrides the API model id", "override")}
                    </.badge>
                  </:summary_extra>

                  <.form
                    for={@link_forms[link.id]}
                    id={"ai-link-form-#{link.id}"}
                    class="ai-link-form"
                    phx-hook="UnsavedChanges"
                    data-saved={is_nil(@link_forms[link.id].action)}
                    phx-change="validate_link"
                    phx-submit="save_link"
                  >
                    <input type="hidden" name="link_id" value={link.id} />
                    <.link_fields form={@link_forms[link.id]} body_json={@link_body_json[link.id]} />
                    <.form_actions>
                      <:start>
                        <.button
                          danger
                          phx-click="delete_link"
                          phx-value-id={link.id}
                          data-confirm={unlink_confirm(link.model.name, @editing_provider.name)}
                        >
                          <.lucide name="trash" />
                          {dpgettext(
                            "ai",
                            "button: remove a model's link to this connection",
                            "Unlink"
                          )}
                        </.button>
                      </:start>
                      <.button
                        id={"edit-ai-link-model-#{link.id}"}
                        navigate={~p"/ai/models/#{link.ai_model_id}/edit"}
                      >
                        <.lucide name="pencil" />
                        {dpgettext("ai", "button: open the linked AI model's editor", "Edit model")}
                      </.button>
                      <.button
                        id={"test-ai-link-#{link.id}"}
                        phx-click="test_link"
                        phx-value-id={link.id}
                        disabled={@testing_link_id == link.id}
                      >
                        <.lucide name="send" />
                        {if @testing_link_id == link.id,
                          do: dpgettext("ai", "button: test message in progress", "Sending…"),
                          else:
                            dpgettext(
                              "ai",
                              "button: send a test message through a model link",
                              "Send test message"
                            )}
                      </.button>
                      <.button phx-click="toggle_link" phx-value-id={link.id}>
                        {if link.enabled,
                          do: dpgettext("ai", "button: switch a model link off", "Disable"),
                          else: dpgettext("ai", "button: switch a model link on", "Enable")}
                      </.button>
                      <.button type="submit" variant="primary">
                        {dpgettext("ai", "button: save a model link's settings", "Save")}
                      </.button>
                    </.form_actions>
                  </.form>
                </.disclosure>

                <.disclosure id="ai-link-new" class="ai-link-row">
                  <:title>
                    <.lucide name="plus" />
                    {dpgettext(
                      "ai",
                      "heading: form linking a model to this connection",
                      "Link a model"
                    )}
                  </:title>

                  <.form
                    for={@new_link_form}
                    id="ai-link-form"
                    class="ai-link-form"
                    phx-hook="UnsavedChanges"
                    data-saved={is_nil(@new_link_form.action)}
                    phx-change="validate_new_link"
                    phx-submit="create_link"
                  >
                    <.input
                      field={@new_link_form[:ai_model_id]}
                      type="select"
                      label={
                        dpgettext("ai", "field label: AI model to link to a connection", "Model")
                      }
                      options={@model_options}
                      prompt={dpgettext("ai", "option: no AI model chosen to link", "Choose a model")}
                      id="ai-link-form-ai_model_id"
                      required
                    />
                    <.link_fields form={@new_link_form} body_json={@new_link_body_json} />
                    <.form_actions>
                      <.button type="submit" variant="primary">
                        {dpgettext("ai", "button: link the chosen model to this connection", "Link")}
                      </.button>
                    </.form_actions>
                  </.form>
                </.disclosure>
              </div>

              <%!-- Shown once: after the first run the section stays and its Refresh re-runs it. --%>
              <button
                :if={@discovery == :idle}
                type="button"
                id="discover-models"
                class="ai-provider-link"
                phx-click="discover"
              >
                <.lucide name="search" />
                {dpgettext("ai", "button: list the models an AI connection offers", "Discover models")}
              </button>
            </.pane_section>

            <%!--
              A plain `:for`, not a stream: these are transient wire entries with no Ecto id, and
              `phx-update="stream"` needs stable server-assigned dom ids. A wire id may contain `/`
              (`google/gemma-4-31b`), which is legal in a dom id and in an attribute selector.
            --%>
            <.pane_section :if={@editing_provider && @discovery != :idle} id="ai-discovery">
              <.section_header>
                {dpgettext(
                  "ai",
                  "heading: models a connection's API lists",
                  "Models this connection advertises"
                )}
                <:actions>
                  <.button
                    id="refresh-discovery"
                    phx-click="discover"
                    disabled={@discovery == :loading}
                  >
                    <.lucide name="refresh-cw" />
                    {dpgettext("ai", "button: list the connection's models again", "Refresh")}
                  </.button>
                </:actions>
              </.section_header>

              <p :if={@discovery == :loading} class="ai-discovery-note">
                {dpgettext(
                  "ai",
                  "status: listing an AI connection's models is in progress",
                  "Querying %{models_url}…",
                  models_url: @editing_provider.base_url <> "/models"
                )}
              </p>

              <p :if={match?({:error, _reason}, @discovery)} class="ai-discovery-error">
                {discovery_error(elem(@discovery, 1))}
              </p>

              <p :if={@discovery == :loaded and @discovered == []} class="ai-discovery-note">
                {dgettext("ai", "This connection advertises no models.")}
              </p>

              <ul :if={@discovered != []} class="ai-discovery-list">
                <li
                  :for={entry <- @discovered}
                  id={"ai-discovered-#{entry.id}"}
                  class="ai-discovery-row"
                >
                  <div class="ai-discovery-row-text">
                    <span class="ai-discovery-row-name">{entry.name}</span>
                    <span class="ai-discovery-row-id">{entry.id}</span>
                    <span :if={entry.attrs != %{}} class="ai-discovery-row-facts">
                      {discovery_facts(entry.attrs)}
                    </span>
                  </div>
                  <.badge :if={entry.model_id}>
                    {dpgettext("ai", "badge: a discovered model already exists as a model", "known")}
                  </.badge>
                  <.button
                    :if={is_nil(entry.model_id)}
                    variant="primary"
                    id={"ai-discovered-add-#{entry.id}"}
                    phx-click="add_discovered"
                    phx-value-id={entry.id}
                  >
                    <.lucide name="download" />
                    {dpgettext(
                      "ai",
                      "button: create a model from a discovered one and link it",
                      "Add"
                    )}
                  </.button>
                  <.button
                    :if={
                      is_nil(entry.model_id) and
                        entry.attrs["completion_mode"] not in ["embedding", "classifier"]
                    }
                    id={"ai-discovered-add-embedding-#{entry.id}"}
                    phx-click="add_discovered"
                    phx-value-id={entry.id}
                    phx-value-as="embedding"
                    title={
                      dgettext(
                        "ai",
                        "Add it as an embedding model, for Vector lore, when the server doesn't say it embeds"
                      )
                    }
                  >
                    {dpgettext(
                      "ai",
                      "button: add a discovered model as an embedding model",
                      "Add as embedding"
                    )}
                  </.button>
                  <.button
                    :if={
                      is_nil(entry.model_id) and
                        entry.attrs["completion_mode"] not in ["embedding", "classifier"]
                    }
                    id={"ai-discovered-add-classifier-#{entry.id}"}
                    phx-click="add_discovered"
                    phx-value-id={entry.id}
                    phx-value-as="classifier"
                    title={
                      dgettext(
                        "ai",
                        "Add it as a classifier model, for Expressions: a GoEmotions classifier served with --pooling rank"
                      )
                    }
                  >
                    {dpgettext(
                      "ai",
                      "button: add a discovered model as a classifier model",
                      "Add as classifier"
                    )}
                  </.button>
                  <.button
                    :if={entry.model_id && !entry.linked?}
                    variant="primary"
                    phx-click="link_discovered"
                    phx-value-model-id={entry.model_id}
                  >
                    <.lucide name="link" />
                    {dpgettext("ai", "button: link an existing model to this connection", "Link")}
                  </.button>
                  <span :if={entry.linked?} class="ai-discovery-done">
                    {dpgettext(
                      "ai",
                      "status: a discovered model is linked to this connection",
                      "Linked"
                    )}
                  </span>
                </li>
              </ul>
            </.pane_section>
          </div>
        </:editor>
      </.pane_layout>
      <AIOwnership.transfer_modal
        :if={@transfer}
        id="ai-provider-transfer-modal"
        transfer={@transfer}
        row={@editing_provider}
        kind={:connection}
      />
      <MythweaverWeb.Sudo.modal :if={@sudo_prompt} prompt={@sudo_prompt} />
    </Layouts.app>
    """
  end
end
