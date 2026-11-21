defmodule MythweaverWeb.AIModelLive do
  @moduledoc """
  AI model editor: the model list on the left, with the switch back to connections in its header,
  and the selected model's form on the right. Lists the models the viewer may edit (their own, plus
  the site's for an admin); a new model is the site's when an admin creates it, else the user's.

  Same shape as `MythweaverWeb.AIProviderLive`. `:index` selects nothing: the editor pane shows a
  placeholder until a model is picked. A personal model's editor ends with its Sharing section
  (`MythweaverWeb.SharePanel`, which also sets each share's AI mode).

  The form carries the whole default sampler through `<.inputs_for>` on the `:sampler` embed, so
  `cast_embed` consumes the nested params unchanged. Four of the sampler fields are not plain scalars
  and so are fieldless inputs whose raw text lives in assigns, parsed here before the changeset sees
  them: `stop_sequences` (a comma list), `dry_sequence_breakers` (a JSON list), `logit_bias` and
  `extra` (JSON objects). `sampler_order` lives in its own assign, reordered by dragging its rows
  (the shared `SortableList` hook, which pushes the full order as `sampler_order_reorder`) and never
  read back from the form params. The model's own `extra_body` (a JSON object) is handled
  like `extra`. A site model's editor, for a holder of `site.ai.manage`, also has a "Who may use
  it" form (`"save_model_groups"`, `AI.set_model_groups/3`) below the main form.
  """

  use MythweaverWeb, :live_view

  import MythweaverWeb.AI.HFCompare
  import MythweaverWeb.BulkComponents
  import MythweaverWeb.Pane
  import MythweaverWeb.TagFields
  import MythweaverWeb.TagFilter

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.AI.HuggingFace
  alias Mythweaver.AI.Model
  alias Mythweaver.AI.SamplerParams
  alias Mythweaver.Format
  alias Mythweaver.Jobs
  alias Mythweaver.Permissions
  alias Mythweaver.Prompts
  alias MythweaverWeb.AIOwnership
  alias MythweaverWeb.Bulk
  alias MythweaverWeb.Bulk.Field
  alias MythweaverWeb.Bulk.Spec
  alias MythweaverWeb.EnumLabels
  alias MythweaverWeb.JSONText
  alias MythweaverWeb.LiveSync
  alias Phoenix.HTML.Form

  on_mount MythweaverWeb.AIAccess
  on_mount MythweaverWeb.Sudo

  # Below this many `sampler.max_tokens` a thinking model can spend the whole budget reasoning.
  @thinking_token_floor 1024

  # Fieldless sampler inputs: `form.params` holds them already parsed, so a rebuild drops them and
  # `normalize_params/2` re-reads the raw text from assigns.
  @fieldless_sampler ~w(stop_sequences extra dry_sequence_breakers logit_bias sampler_order)

  # What "Neutralize samplers" sets: every truncation and penalty off, temperature 1. Like
  # SillyTavern's, it leaves max tokens, seed, stops, thinking, DRY/XTC sub-parameters, breakers,
  # logit bias, order and `extra` alone.
  @neutral_sampler %{
    "temperature" => "1",
    "top_p" => "1",
    "top_k" => "0",
    "min_p" => "0",
    "top_a" => "0",
    "typical_p" => "1",
    "repetition_penalty" => "1",
    "frequency_penalty" => "0",
    "presence_penalty" => "0",
    "top_n_sigma" => "0",
    "dry_multiplier" => "0",
    "xtc_probability" => "0",
    "dynatemp_low" => "",
    "dynatemp_high" => "",
    "dynatemp_exponent" => ""
  }

  defp sampler_label(:penalties),
    do: dpgettext("ai", "option: sampler stage in the sampler order", "Repetition penalties")

  defp sampler_label(:dry), do: dpgettext("ai", "option: sampler stage in the sampler order", "DRY")
  defp sampler_label(:top_n_sigma), do: dpgettext("ai", "option: sampler stage in the sampler order", "Top nσ")
  defp sampler_label(:top_k), do: dpgettext("ai", "option: sampler stage in the sampler order", "Top k")
  defp sampler_label(:typ_p), do: dpgettext("ai", "option: sampler stage in the sampler order", "Typical p")
  defp sampler_label(:top_p), do: dpgettext("ai", "option: sampler stage in the sampler order", "Top p")
  defp sampler_label(:min_p), do: dpgettext("ai", "option: sampler stage in the sampler order", "Min p")
  defp sampler_label(:xtc), do: dpgettext("ai", "option: sampler stage in the sampler order", "XTC")
  defp sampler_label(:temperature), do: dpgettext("ai", "option: sampler stage in the sampler order", "Temperature")

  defp completion_mode_label(:chat), do: dpgettext("ai", "option: AI model completion mode", "Chat")
  defp completion_mode_label(:text), do: dpgettext("ai", "option: AI model completion mode", "Text completion")
  defp completion_mode_label(:embedding), do: dpgettext("ai", "option: AI model completion mode", "Embedding")
  defp completion_mode_label(:classifier), do: dpgettext("ai", "option: AI model completion mode", "Classifier")

  # The model list's short mode tag, after the connection count.
  defp completion_mode_meta(:chat), do: dpgettext("ai", "badge: AI model completion mode in the model list", "chat")
  defp completion_mode_meta(:text), do: dpgettext("ai", "badge: AI model completion mode in the model list", "text")

  defp completion_mode_meta(:embedding),
    do: dpgettext("ai", "badge: AI model completion mode in the model list", "embedding")

  defp completion_mode_meta(:classifier),
    do: dpgettext("ai", "badge: AI model completion mode in the model list", "classifier")

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: dpgettext("ai", "page title: AI model editor", "AI models"),
       form: nil,
       editing_model: nil,
       stop_sequences_input: "",
       sampler_extra_json: "{}",
       dry_sequence_breakers_input: "",
       logit_bias_json: "{}",
       sampler_order: [],
       extra_body_json: "{}",
       thinking_budget_warning?: false,
       hf_lookup: :idle,
       hf_compare: nil,
       selected_id: nil,
       new_owner: "personal",
       model_group_ids: nil,
       group_options: [],
       transfer: nil
     )
     |> stream_configure(:models, dom_id: &"ai-models-#{&1.id}")
     |> assign_filter()
     |> assign_tag_filter()
     |> stream_models()
     |> Bulk.attach([bulk_spec()])
     |> LiveSync.attach_editor([:ai, :prompts, :tags], &sync/2)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  # Clears what `assign_editor/3` sets; resetting `hf_lookup` drops a lookup still in flight.
  defp apply_action(socket, :index, _params) do
    socket
    |> assign(
      form: nil,
      editing_model: nil,
      selected_id: nil,
      transfer: nil,
      hf_lookup: :idle,
      hf_compare: nil
    )
    |> stream_models()
  end

  defp apply_action(socket, :new, _params) do
    socket = assign(socket, new_owner: "personal", transfer: nil)

    socket
    |> assign_editor(%Model{}, new_owner(socket))
    |> stream_models()
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case AI.get_editable_model(socket.assigns.current_scope, id) do
      nil ->
        socket
        |> put_flash(:error, not_found_flash())
        |> push_patch(to: ~p"/ai/models")

      model ->
        socket
        |> assign(transfer: nil)
        |> assign_editor(model, model.user_id)
        |> stream_models()
    end
  end

  # The form for `model` (an unsaved `%Model{}` for the new form), its fieldless inputs' text and its
  # caption pickers. It resets the Hugging Face state, so a lookup still in flight for another form
  # is dropped by `handle_async/3` instead of landing on this one.
  defp assign_editor(socket, %Model{} = model, owner) do
    scope = socket.assigns.current_scope
    sampler = model.sampler || %SamplerParams{}
    # The groups allowed to run a saved site model, for a site manager; nil hides the form.
    group_ids =
      if model.id && is_nil(model.user_id) && Scope.can?(scope, "site.ai.manage"), do: AI.model_group_ids(model)

    socket
    |> assign(
      editing_model: if(model.id, do: model),
      hf_lookup: :idle,
      hf_compare: nil,
      stop_sequences_input: Enum.join(sampler.stop_sequences, ", "),
      sampler_extra_json: JSONText.encode(sampler.extra),
      dry_sequence_breakers_input: encode_breakers(sampler.dry_sequence_breakers),
      logit_bias_json: JSONText.encode(sampler.logit_bias),
      sampler_order: sampler.sampler_order,
      extra_body_json: JSONText.encode(model.extra_body),
      caption_model_options: AI.caption_model_options(scope, owner, model.id),
      caption_prompt_options: Enum.map(Prompts.list_prompts(scope, :caption), &{&1.name, &1.id}),
      selected_id: model.id,
      model_group_ids: group_ids,
      group_options: if(group_ids, do: Permissions.group_options(), else: [])
    )
    |> assign_form(AI.change_model(model))
    |> assign_tag_fields(:item, if(model.id, do: model), owner)
  end

  defp sync(socket, kinds) do
    scope = socket.assigns.current_scope

    socket
    |> then(&if(:tags in kinds, do: refresh_graph(&1), else: &1))
    |> stream_models()
    |> refresh_caption_options()
    |> LiveSync.sync_open(:editing_model,
      fetch: &AI.get_editable_model(scope, &1),
      clean?: LiveSync.clean?(socket.assigns.form),
      reload: fn s, fresh ->
        {lookup, compare} = {s.assigns.hf_lookup, s.assigns.hf_compare}

        s
        |> assign_editor(fresh, fresh.user_id)
        |> assign(hf_lookup: lookup, hf_compare: compare)
      end,
      force: :tags in kinds,
      gone: ~p"/ai/models",
      gone_message:
        (
          gettext_comment("Flash shown when the AI model open in the editor was deleted or moved by someone else.")
          dgettext("ai", "The AI model was deleted or moved elsewhere.")
        )
    )
  end

  defp refresh_caption_options(%{assigns: %{form: nil}} = socket), do: socket

  defp refresh_caption_options(socket) do
    scope = socket.assigns.current_scope

    {owner, id} =
      case socket.assigns.editing_model do
        %Model{} = model -> {model.user_id, model.id}
        nil -> {new_owner(socket), nil}
      end

    assign(socket,
      caption_model_options: AI.caption_model_options(scope, owner, id),
      caption_prompt_options: Enum.map(Prompts.list_prompts(scope, :caption), &{&1.name, &1.id})
    )
  end

  # The owner the new form's model would get: the Owner choice decides for a scope offered one.
  defp new_owner(socket) do
    {:ok, owner} = AI.new_owner(socket.assigns.current_scope, site: socket.assigns.new_owner == "site")
    owner
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, socket |> assign_filter(params) |> assign_tag_filter(params) |> stream_models()}
  end

  def handle_event("validate", %{"model" => params} = all, socket) do
    socket = socket |> put_owner_choice(AIOwnership.owner_choice(all)) |> put_tag_params(:item, all["tags"])
    {attrs, json_errors} = normalize_params(params, socket)

    {:noreply,
     socket
     |> assign_form(validate_changeset(socket, attrs, json_errors))
     |> assign_raw(params)}
  end

  def handle_event("save", %{"model" => params} = all, socket) do
    socket = socket |> put_owner_choice(AIOwnership.owner_choice(all)) |> put_tag_params(:item, all["tags"])
    {attrs, json_errors} = normalize_params(params, socket)

    if json_errors == [] do
      save_model(socket, attrs, params)
    else
      {:noreply,
       socket
       |> assign_form(validate_changeset(socket, attrs, json_errors))
       |> assign_raw(params)
       |> put_flash(:error, save_failed_flash())}
    end
  end

  def handle_event("save_model_groups", params, %{assigns: %{editing_model: %Model{} = model}} = socket) do
    ids = params |> get_in(["groups", "ids"]) |> List.wrap() |> Enum.reject(&(&1 == ""))

    case AI.set_model_groups(socket.assigns.current_scope, model, ids) do
      :ok ->
        {:noreply,
         socket |> put_flash(:info, groups_saved_flash()) |> assign(model_group_ids: AI.model_group_ids(model))}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case AI.get_editable_model(socket.assigns.current_scope, id) do
      nil ->
        {:noreply, socket}

      model ->
        result = AI.delete_model(socket.assigns.current_scope, model)
        {:noreply, MythweaverWeb.HandOff.after_delete(socket, result, model.name, ~p"/ai/models")}
    end
  end

  def handle_event("prepare_transfer", _params, %{assigns: %{editing_model: %Model{} = model}} = socket),
    do: {:noreply, AIOwnership.prepare(socket, model)}

  def handle_event("cancel_transfer", _params, socket), do: {:noreply, assign(socket, transfer: nil)}

  def handle_event("transfer", params, %{assigns: %{editing_model: %Model{} = model, transfer: %{}}} = socket),
    do: {:noreply, AIOwnership.run(socket, model, &~p"/ai/models/#{&1.id}/edit", params)}

  def handle_event("sampler_neutralize", _params, socket) do
    {:noreply,
     socket
     |> rebuild_form(%{"sampler" => @neutral_sampler})
     |> put_flash(:info, neutralized_flash())}
  end

  def handle_event("sampler_order_customize", _params, socket) do
    {:noreply, socket |> assign(sampler_order: SamplerParams.default_sampler_order()) |> rebuild_form(%{})}
  end

  def handle_event("sampler_order_reset", _params, socket) do
    {:noreply, socket |> assign(sampler_order: []) |> rebuild_form(%{})}
  end

  # A drag's `ids` must be a permutation of the current order; anything else is ignored.
  def handle_event("sampler_order_reorder", %{"ids" => ids}, socket) when is_list(ids) do
    order = socket.assigns.sampler_order
    by_name = Map.new(order, &{Atom.to_string(&1), &1})
    reordered = Enum.map(ids, &Map.get(by_name, &1))

    if Enum.sort(reordered) == Enum.sort(order) do
      {:noreply, socket |> assign(sampler_order: reordered) |> rebuild_form(%{})}
    else
      {:noreply, socket}
    end
  end

  # `start_async` for the same reason as `AIProviderLive`'s "discover": up to four Hub API calls
  # plus a tokenizer download must not block the LiveView. The field value is read from the
  # changeset, where a pasted URL is already normalized to `owner/name`.
  def handle_event("fill_from_hf", _params, socket) do
    case Ecto.Changeset.get_field(socket.assigns.form.source, :tokenizer) do
      input when input in [nil, ""] ->
        {:noreply,
         assign(socket,
           hf_lookup: {:error, :no_repo}
         )}

      input ->
        {:noreply,
         socket
         |> assign(hf_lookup: {:loading, input}, hf_compare: nil)
         |> start_async(:hf_lookup, Mythweaver.Locale.carry(fn -> HuggingFace.lookup(input) end))}
    end
  end

  # Rows are looked up by key in server-held state, never taken from the client.
  def handle_event(_event, _params, %{assigns: %{hf_compare: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("hf_toggle_row", %{"key" => key}, socket) do
    {:noreply, update_rows(socket, &if(&1.key == key, do: %{&1 | apply?: not &1.apply?}, else: &1))}
  end

  def handle_event("hf_copy_missing", _params, socket) do
    {:noreply, update_rows(socket, &if(HuggingFace.blank?(&1.current), do: %{&1 | apply?: true}, else: &1))}
  end

  def handle_event("hf_copy_all", _params, socket) do
    {:noreply, update_rows(socket, &if(HuggingFace.changed?(&1), do: %{&1 | apply?: true}, else: &1))}
  end

  def handle_event("hf_toggle_unchanged", _params, socket) do
    {:noreply, update(socket, :hf_compare, &%{&1 | show_unchanged?: not &1.show_unchanged?})}
  end

  def handle_event("close_hf_compare", _params, socket) do
    {:noreply, assign(socket, hf_compare: nil)}
  end

  def handle_event("hf_apply", _params, socket) do
    rows = socket.assigns.hf_compare.rows
    applied = Enum.count(rows, &(&1.apply? and HuggingFace.changed?(&1)))

    {:noreply,
     socket
     |> rebuild_form(HuggingFace.form_params(rows))
     |> assign(hf_compare: nil)
     |> put_flash(:info, hf_applied_flash(applied))}
  end

  # Merges `patch` over the form's current params so unsaved edits survive, then validates, so the
  # result carries an action and reads as unsaved. The fieldless inputs are dropped from the base:
  # `form.params` holds them already parsed, and `normalize_params/2` re-reads their raw text from
  # assigns when the keys are absent.
  defp rebuild_form(socket, patch) do
    params =
      socket.assigns.form.params
      |> Map.delete("extra_body")
      |> Map.update("sampler", %{}, &Map.drop(&1, @fieldless_sampler))
      |> Map.merge(patch, fn
        "sampler", base, sampler -> Map.merge(base, sampler)
        _key, _base, value -> value
      end)

    {attrs, json_errors} = normalize_params(params, socket)
    assign_form(socket, validate_changeset(socket, attrs, json_errors))
  end

  @impl true
  def handle_async(:hf_lookup, result, socket) do
    if match?({:loading, _}, socket.assigns.hf_lookup) do
      {:noreply, hf_result(socket, result)}
    else
      {:noreply, socket}
    end
  end

  defp hf_result(socket, {:ok, {:ok, meta}}) do
    model = Ecto.Changeset.apply_changes(socket.assigns.form.source)

    assign(socket,
      hf_lookup: :idle,
      hf_compare: %{
        source: meta.source,
        tokenizer: meta.tokenizer,
        rows: HuggingFace.compare(meta, model),
        show_unchanged?: false
      }
    )
  end

  defp hf_result(socket, {:ok, {:error, reason}}), do: assign(socket, hf_lookup: {:error, reason})

  # A raise or exit inside the task arrives here; without this clause it would crash the page.
  defp hf_result(socket, {:exit, _reason}), do: assign(socket, hf_lookup: {:error, :crashed})

  defp hf_message(:no_repo), do: dgettext("ai", "Paste a Hugging Face model page or owner/name first.")
  defp hf_message(:crashed), do: dpgettext("ai", "status: the Hugging Face model lookup crashed", "The lookup crashed.")
  defp hf_message(:invalid_repo), do: dgettext("ai", "Paste a Hugging Face model page or owner/name.")

  defp hf_message({:not_found, repo}),
    do:
      dgettext(
        "ai",
        "Hugging Face has no public model %{model_repo}. If it is gated or private, set HF_TOKEN and restart.",
        model_repo: repo
      )

  defp hf_message({:no_tokenizer, repo}),
    do: dgettext("ai", "%{model_repo} has no tokenizer.json, and neither does its base model.", model_repo: repo)

  defp hf_message({:http_error, repo, status}),
    do:
      dgettext("ai", "Hugging Face answered HTTP %{http_status} for %{model_repo}.",
        http_status: status,
        model_repo: repo
      )

  defp hf_message({:transport_error, message}) do
    gettext_comment("%{error_detail} is the network error's own text, in English.")
    dgettext("ai", "Could not reach Hugging Face (%{error_detail}).", error_detail: message)
  end

  defp hf_message({:invalid_tokenizer, repo}),
    do: dgettext("ai", "The tokenizer.json in %{model_repo} could not be loaded.", model_repo: repo)

  defp hf_message({:too_large, repo}),
    do:
      dgettext("ai", "The tokenizer.json in %{model_repo} is larger than %{limit_megabytes}.",
        model_repo: repo,
        limit_megabytes: Format.megabytes(64)
      )

  defp hf_message({:io_error, repo}),
    do: dgettext("ai", "The tokenizer.json for %{model_repo} could not be saved to the cache.", model_repo: repo)

  defp not_found_flash do
    gettext_comment("Flash when the AI model in the address no longer exists or is not yours.")
    dpgettext("ai", "status: flash when an AI model could not be found", "Model not found")
  end

  defp save_failed_flash do
    gettext_comment("Flash when a form did not save because of invalid fields.")
    dgettext("ai", "Could not save — see the highlighted fields")
  end

  defp saved_flash(name) do
    gettext_comment("Flash after an AI model was saved.")
    dpgettext("ai", "status: flash after saving an AI model", "%{model_name} saved", model_name: name)
  end

  defp tags_failed_flash(name) do
    gettext_comment("Flash when an AI model saved but its tags could not be written.")
    dgettext("ai", "%{model_name} saved, but its tags did not", model_name: name)
  end

  defp groups_saved_flash do
    gettext_comment("Flash after saving which groups may use a site model.")
    dpgettext("ai", "status: the groups allowed to use a site model were saved", "Saved")
  end

  defp neutralized_flash do
    gettext_comment("Flash after Neutralize samplers reset the sampler fields in the form, not yet saved.")
    dgettext("ai", "Samplers neutralized — Save to keep them")
  end

  defp hf_applied_flash(applied) do
    gettext_comment("Flash after applying Hugging Face values to the model form, not yet saved.")

    dngettext(
      "ai",
      "Applied %{field_count} field from Hugging Face — Save to keep them",
      "Applied %{field_count} fields from Hugging Face — Save to keep them",
      applied,
      field_count: Format.number(applied)
    )
  end

  defp delete_confirm(name) do
    gettext_comment("Confirm dialog before deleting an AI model.")
    dgettext("ai", "Delete %{model_name}? Its provider links go with it.", model_name: name)
  end

  defp update_rows(socket, fun) do
    update(socket, :hf_compare, &%{&1 | rows: Enum.map(&1.rows, fun)})
  end

  defp save_model(socket, attrs, params) do
    result =
      case socket.assigns.editing_model do
        nil ->
          opts = [site: socket.assigns.new_owner == "site"]
          AI.create_model(socket.assigns.current_scope, attrs, [followups: tag_followups(socket, :item, opts)] ++ opts)

        model ->
          AI.update_model(socket.assigns.current_scope, model, attrs)
      end

    case result do
      {:ok, model} ->
        socket =
          case save_tags(socket, :item, model) do
            {:ok, socket} -> put_flash(socket, :info, saved_flash(model.name))
            {:error, _what, socket} -> put_flash(socket, :error, tags_failed_flash(model.name))
          end

        {:noreply, push_patch(socket, to: ~p"/ai/models/#{model.id}/edit")}

      {:held, hold} ->
        path =
          case socket.assigns.editing_model do
            nil -> ~p"/ai/models"
            model -> ~p"/ai/models/#{model.id}/edit"
          end

        {:noreply, socket |> flash_held(hold) |> push_patch(to: path)}

      {:error, :hold_limit} ->
        {:noreply, flash_hold_limit(socket)}

      {:error, :quota_exceeded} ->
        {:noreply, flash_quota(socket, "quota.ai_models")}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign_form(changeset)
         |> assign_raw(params)
         |> put_flash(:error, save_failed_flash())}
    end
  end

  defp validate_changeset(socket, attrs, json_errors) do
    changeset =
      socket
      |> target_model()
      |> AI.change_model(attrs)
      |> Map.put(:action, :validate)

    Enum.reduce(json_errors, changeset, fn
      :sampler, cs -> Ecto.Changeset.add_error(cs, :sampler, dgettext_noop("errors", "extra must be a JSON object"))
      :extra_body, cs -> Ecto.Changeset.add_error(cs, :extra_body, dgettext_noop("errors", "must be a JSON object"))
    end)
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket,
      form: to_form(changeset),
      thinking_budget_warning?: thinking_budget_warning?(changeset)
    )
  end

  # Keys on `sampler.max_tokens`, the wire limit. An unset limit (server default) never warns.
  defp thinking_budget_warning?(changeset) do
    Ecto.Changeset.get_field(changeset, :supports_thinking) == true and
      match?(
        %SamplerParams{max_tokens: n} when is_integer(n) and n < @thinking_token_floor,
        Ecto.Changeset.get_field(changeset, :sampler)
      )
  end

  defp target_model(socket), do: socket.assigns.editing_model || %Model{user_id: new_owner(socket)}

  # A changed Owner on the new form changes which caption models it may pick and whether it shows
  # site tags.
  defp put_owner_choice(%{assigns: %{editing_model: nil, new_owner: old}} = socket, choice) when choice != old do
    socket = assign(socket, new_owner: choice)

    owner = new_owner(socket)

    socket
    |> assign(caption_model_options: AI.caption_model_options(socket.assigns.current_scope, owner, nil))
    |> put_owner(:item, owner)
  end

  defp put_owner_choice(socket, _choice), do: socket

  defp bulk_spec do
    %Spec{
      name: :models,
      tag_kind: :ai_model,
      count_label:
        &dpngettext(
          "ai",
          "count phrase: AI models affected by a bulk action",
          "%{model_count} model",
          "%{model_count} models",
          &1,
          model_count: Mythweaver.Format.number(&1)
        ),
      ids: & &1.assigns.models_ids,
      get: &AI.get_editable_model/2,
      update: &AI.update_model/3,
      delete: &AI.delete_model/2,
      title: & &1.name,
      refresh: &stream_models/1,
      open_id: & &1.assigns.selected_id,
      index_path: ~p"/ai/models",
      edit_path: &~p"/ai/models/#{&1}/edit",
      fields: [
        %Field{
          key: :completion_mode,
          label: dpgettext("ai", "field label: AI model completion mode", "Completion mode"),
          type: :select,
          options: Field.enum_options(Model, :completion_mode, [:embedding, :classifier])
        },
        %Field{
          key: :supports_images,
          label: dpgettext("ai", "field label: AI model reads images itself", "Supports images"),
          type: :checkbox
        },
        %Field{
          key: :supports_files,
          label: dpgettext("ai", "field label: AI model reads PDF files itself", "Reads PDFs"),
          type: :checkbox
        },
        %Field{
          key: :supports_audio,
          label: dpgettext("ai", "field label: AI model hears audio itself", "Hears audio"),
          type: :checkbox
        },
        %Field{
          key: :supports_video,
          label: dpgettext("ai", "field label: AI model watches video itself", "Watches video"),
          type: :checkbox
        },
        %Field{
          key: :supports_tools,
          label: dpgettext("ai", "field label: AI model can call tools", "Supports tools"),
          type: :checkbox
        },
        %Field{
          key: :supports_thinking,
          label: dpgettext("ai", "field label: AI model returns separate reasoning", "Supports thinking"),
          type: :checkbox
        },
        %Field{
          key: :continue_prefill,
          label:
            dpgettext(
              "ai",
              "field label: AI model continues a message by assistant prefill",
              "Continue by assistant prefill"
            ),
          type: :checkbox
        },
        %Field{
          key: :image_detail,
          label: dpgettext("ai", "field label: image detail hint an AI model sends", "Image detail"),
          type: :select,
          options: Field.enum_options(Model, :image_detail),
          prompt: dpgettext("ai", "option: image detail hint left to the backend", "Default")
        },
        %Field{
          key: :inline_image_limit,
          label: dgettext("ai", "Messages with images sent inline"),
          type: :number,
          min: 0
        },
        %Field{
          key: :inline_audio_limit,
          label: dgettext("ai", "Messages with audio sent inline"),
          type: :number,
          min: 0
        },
        %Field{
          key: :inline_video_limit,
          label: dgettext("ai", "Messages with video sent inline"),
          type: :number,
          min: 0
        },
        %Field{
          key: :inline_document_limit,
          label: dgettext("ai", "Messages with documents sent in full"),
          type: :number,
          min: 0
        },
        %Field{
          key: :caption_max_tokens,
          label: dpgettext("ai", "field label: longest description an AI model writes", "Caption max tokens"),
          type: :number,
          min: 1
        },
        %Field{
          key: :chat_first_token_seconds,
          label:
            dpgettext("ai", "field label: chat time limit for the first token, in seconds", "Chat: first token (s)"),
          type: :number,
          min: 0
        },
        %Field{
          key: :chat_stall_seconds,
          label: dpgettext("ai", "field label: chat time limit for silence, in seconds", "Chat: stall (s)"),
          type: :number,
          min: 0
        },
        %Field{
          key: :chat_deadline_seconds,
          label: dpgettext("ai", "field label: chat total time limit, in seconds", "Chat: total (s)"),
          type: :number,
          min: 0
        },
        %Field{
          key: :background_first_token_seconds,
          label:
            dpgettext(
              "ai",
              "field label: background job time limit for the first token, in seconds",
              "Background: first token (s)"
            ),
          type: :number,
          min: 0
        },
        %Field{
          key: :background_stall_seconds,
          label:
            dpgettext("ai", "field label: background job time limit for silence, in seconds", "Background: stall (s)"),
          type: :number,
          min: 0
        },
        %Field{
          key: :background_deadline_seconds,
          label: dpgettext("ai", "field label: background job total time limit, in seconds", "Background: total (s)"),
          type: :number,
          min: 0
        }
      ]
    }
  end

  defp stream_models(socket) do
    models = filter_tagged(socket, AI.list_editable_models(socket.assigns.current_scope), :ai_model)
    stream_search(socket, :models, models, &[&1.name, &1.api_model_id])
  end

  # Returns `{attrs, json_errors}`. Breakers and logit bias text that does not parse goes to the
  # changeset raw, so `cast` reports it on the field itself.
  defp normalize_params(params, socket) do
    raw = raw_inputs(params, socket)

    {sampler, extra_ok?} =
      params
      |> Map.get("sampler", %{})
      |> Map.put("stop_sequences", JSONText.split_list(raw.stop_sequences_input))
      |> Map.put("dry_sequence_breakers", decode_breakers(raw.dry_sequence_breakers_input))
      |> Map.put("logit_bias", decode_bias(raw.logit_bias_json))
      |> Map.put("sampler_order", Enum.map(socket.assigns.sampler_order, &Atom.to_string/1))
      |> JSONText.put_map("extra", raw.sampler_extra_json)

    {attrs, body_ok?} =
      params
      |> Map.put("sampler", sampler)
      |> JSONText.put_map("extra_body", raw.extra_body_json)

    {attrs, for({key, false} <- [sampler: extra_ok?, extra_body: body_ok?], do: key)}
  end

  defp decode_breakers(raw) do
    if String.trim(raw) == "" do
      []
    else
      case Jason.decode(raw) do
        {:ok, list} when is_list(list) -> list
        _ -> raw
      end
    end
  end

  defp decode_bias(raw) do
    case JSONText.decode_map(raw) do
      {map, true} -> map
      {_map, false} -> raw
    end
  end

  defp encode_breakers([]), do: ""
  defp encode_breakers(breakers), do: Jason.encode!(breakers)

  # The raw text of the fieldless inputs, kept in assigns so it survives the `phx-change` re-render:
  # the payload's, or what assigns already hold when a partial payload omits a key.
  defp raw_inputs(params, socket) do
    sampler = Map.get(params, "sampler", %{})
    assigns = socket.assigns

    %{
      stop_sequences_input: Map.get(sampler, "stop_sequences", assigns.stop_sequences_input),
      sampler_extra_json: Map.get(sampler, "extra", assigns.sampler_extra_json),
      dry_sequence_breakers_input: Map.get(sampler, "dry_sequence_breakers", assigns.dry_sequence_breakers_input),
      logit_bias_json: Map.get(sampler, "logit_bias", assigns.logit_bias_json),
      extra_body_json: params["extra_body"] || assigns.extra_body_json
    }
  end

  defp assign_raw(socket, params), do: assign(socket, raw_inputs(params, socket))

  defp checked?(field), do: Form.normalize_value("checkbox", field.value)

  # The tag default a blank time-limit field keeps, as the field's placeholder.
  defp default_seconds(tag, key) do
    case Jobs.tag_options(tag)[key] do
      nil -> dpgettext("ai", "placeholder: a job time limit with no default", "No limit")
      ms -> Format.number(div(ms, 1000))
    end
  end

  ## Hints with inline markup

  defp api_model_id_hint do
    gettext_comment("The placeholders are code examples: the request key and two model ids.")

    rich(
      dgettext(
        "ai",
        "The exact model id the backend expects, sent as %{model_key} with every request (%{example_id}, %{example_routed_id}). A connection link can override it when one backend names the same model differently.",
        model_key: code("model"),
        example_id: code("gemma-4"),
        example_routed_id: code("anthropic/claude-sonnet-4.5")
      )
    )
  end

  defp tokenizer_hint do
    gettext_comment("%{fill_button} is the name of the button next to the field, in italics.")

    rich(
      dgettext(
        "ai",
        "The Hugging Face repo whose tokenizer counts this model's tokens, for the lore budget, prompt section sizes and cost estimates; without one, counts are estimated. %{fill_button} also reads the repo's context window, capabilities and recommended sampler values.",
        fill_button: em(fill_from_hf_label())
      )
    )
  end

  defp fill_from_hf_label, do: dpgettext("ai", "button: fill model fields from Hugging Face", "Fill from Hugging Face")

  defp completion_mode_hint do
    gettext_comment(
      "%{chat}, %{text_completion}, %{embedding} and %{classifier} are the mode option names in bold; %{chat_endpoint}, %{text_endpoint} and %{server_flags} are code."
    )

    rich(
      dgettext(
        "ai",
        "%{chat} sends the prompt as role-tagged messages to %{chat_endpoint}, and the backend applies the model's chat template. %{text_completion} sends one flat prompt to %{text_endpoint}, for base models or a template written into the prompt itself. %{embedding} turns text into vectors for Vector lore entries; it can't reply in chats. %{classifier} is a GoEmotions sequence classifier served like an embedding model (llama-server %{server_flags}), for the Expressions classifier setting; it can't reply in chats either. A model switches modes only while nothing uses it in a way the new mode can't serve.",
        chat: strong(completion_mode_label(:chat)),
        chat_endpoint: code("/chat/completions"),
        text_completion: strong(completion_mode_label(:text)),
        text_endpoint: code("/completions"),
        embedding: strong(completion_mode_label(:embedding)),
        classifier: strong(completion_mode_label(:classifier)),
        server_flags: code("--embedding --pooling rank")
      )
    )
  end

  defp caption_model_hint do
    gettext_comment("The placeholders are the code markers the model reads instead of each attachment.")

    rich(
      dgettext(
        "ai",
        "A model that describes images, audio and video this one can't take; it reads the descriptions instead. With none, they appear as %{image_marker}, %{audio_marker} or %{video_marker}.",
        image_marker: code("[Image]"),
        audio_marker: code("[Audio: name]"),
        video_marker: code("[Video: name]")
      )
    )
  end

  defp image_detail_hint do
    gettext_comment(
      "%{low}, %{high} and %{auto} are the detail values in bold; %{not_sent} is the select's blank option, in italics."
    )

    rich(
      dgettext(
        "ai",
        "The detail hint OpenAI-style backends read with each image: %{low} is a fixed 85 tokens per image, %{high} reads fine detail for many more, %{auto} lets the backend choose. %{not_sent} leaves it out, for backends that reject it.",
        low: strong(dpgettext("ai", "option: image detail value named inside a sentence", "low")),
        high: strong(dpgettext("ai", "option: image detail value named inside a sentence", "high")),
        auto: strong(dpgettext("ai", "option: image detail value named inside a sentence", "auto")),
        not_sent: em(image_detail_prompt())
      )
    )
  end

  defp image_detail_prompt, do: dpgettext("ai", "option: image detail hint left out of requests", "Not sent")

  defp supports_thinking_hint do
    gettext_comment("%{reasoning_field} is the response field name, as code.")

    rich(
      dgettext(
        "ai",
        "The backend returns the model's reasoning in its own field (%{reasoning_field}), shown apart from the reply. For a model that thinks inline in its text, set the reasoning prefix and suffix instead.",
        reasoning_field: code("reasoning_content")
      )
    )
  end

  defp thinking_warning do
    gettext_comment(
      "Warning under Supports thinking when the response token limit is low. Response tokens and Extra request body are field names."
    )

    dgettext(
      "ai",
      "Thinking tokens come out of Response tokens. Below %{token_floor} a thinking model can spend them all reasoning and reply with nothing. Raise Response tokens, or cap reasoning in Extra request body (llama.cpp: thinking_budget_tokens).",
      token_floor: Format.number(@thinking_token_floor)
    )
  end

  defp reasoning_prefix_hint do
    gettext_comment("%{open_tag} is an example tag, as code.")

    rich(
      dgettext(
        "ai",
        "The tag that opens inline thinking, such as %{open_tag}. A reply that starts with it is reasoning up to the suffix, shown apart from the reply text. Leave both tags empty for a model without inline thinking.",
        open_tag: code("<think>")
      )
    )
  end

  defp reasoning_suffix_hint do
    gettext_comment("%{close_tag} and %{gemma_close_tag} are example tags, as code.")

    rich(
      dgettext(
        "ai",
        "The tag that closes inline thinking, such as %{close_tag} (Gemma 4 raw output: %{gemma_close_tag}). A block that never closes is all reasoning.",
        close_tag: code("</think>"),
        gemma_close_tag: code("<channel|>")
      )
    )
  end

  defp extra_body_hint do
    gettext_comment("%{example_key} is a request body key, as code.")

    rich(
      dgettext(
        "ai",
        "A JSON object merged into every request body, for backend-specific keys this form has no field for, such as %{example_key}. The connection's extra body overrides it, then the link's.",
        example_key: code("chat_template_kwargs")
      )
    )
  end

  defp background_deadline_hint do
    gettext_comment("%{caption_seconds} is a number of seconds.")

    dgettext(
      "ai",
      "The longest a memory or caption job may run. By default memory jobs have no limit and captions stop at %{caption_seconds} s.",
      caption_seconds: default_seconds(:caption, :deadline_ms)
    )
  end

  defp max_tokens_hint do
    gettext_comment("%{request_key} is the request key, as code.")

    rich(
      dgettext(
        "ai",
        "The most tokens one reply may generate, sent as %{request_key}: the backend cuts the reply off there. Lower it to keep replies short, quicker and cheaper, and to leave a model less room to ramble or write other characters' turns; raise it if replies end mid-sentence. A thinking model spends its reasoning from the same budget, so give it room. Empty lets the backend decide, which can mean thousands of tokens.",
        request_key: code("max_tokens")
      )
    )
  end

  defp top_k_hint do
    gettext_comment("%{k} is the sampler's variable name k, in italics.")

    rich(
      dgettext(
        "ai",
        "Chooses only among the %{k} likeliest tokens. 0 turns it off; small values are safer but more repetitive.",
        k: em("k")
      )
    )
  end

  defp sequence_breakers_hint do
    gettext_comment("%{example_list} is an example JSON list, as code.")

    rich(
      dgettext(
        "ai",
        "Strings that end a repeated phrase for DRY's count. JSON list, e.g. %{example_list}; empty uses the backend's default.",
        example_list: code(~S(["\n", ":", "\"", "*"]))
      )
    )
  end

  defp skip_special_tokens_hint do
    gettext_comment("%{example_token} is an example special token, as code.")

    rich(
      dgettext(
        "ai",
        "Off, the reply keeps the model's special tokens (such as %{example_token}) in its text. vLLM.",
        example_token: code("<|im_end|>")
      )
    )
  end

  defp logit_bias_hint do
    gettext_comment("%{false_value} is the JSON value false, as code.")

    rich(
      dgettext(
        "ai",
        "Token id or text → bias from -100 to 100; %{false_value} bans. Text keys work only on llama.cpp; other backends get the numeric token ids only.",
        false_value: code("false")
      )
    )
  end

  defp thinking_hint do
    gettext_comment("%{off} and %{backend_default} are the select's option names, in italics.")

    rich(
      dgettext(
        "ai",
        "How hard a reasoning model thinks before it replies, translated for the backend by the connection's thinking dialect, and ignored when the connection has none. %{off} disables thinking where the backend allows it; %{backend_default} sends nothing.",
        off: em(dpgettext("ai", "option: thinking effort switched off", "Off")),
        backend_default: em(backend_default_label())
      )
    )
  end

  defp backend_default_label, do: dpgettext("ai", "option: leave a sampler setting to the backend", "Backend default")

  defp stop_sequences_hint do
    gettext_comment("%{end_tag} and %{hash_marks} are example stop strings, as code.")

    rich(
      dgettext(
        "ai",
        "Strings that end a reply where they appear, such as %{end_tag} or %{hash_marks}. They are sent to the backend and also enforced here, on top of the speaker-name stop strings in Settings.",
        end_tag: code("</s>"),
        hash_marks: code("###")
      )
    )
  end

  defp switch_options,
    do: [
      {dpgettext("ai", "option: a sampler switch is on", "On"), true},
      {dpgettext("ai", "option: a sampler switch is off", "Off"), false}
    ]

  @impl true
  def render(assigns) do
    ~H"""
    <%!--
      `lower-bound="none"`: rules here may reach inside `<.input>`'s own template,
      which is a nested-component root carrying `phx-r` that the default exclusive bound cuts off.
      With no lower bound every element carrying this block's scope marker is a scope root,
      including slot children of `<.form>` (e.g. `.ai-model-form-tokenizer`).
    --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      /* The editor slot's root. `pane_layout`'s `<section>` carries no marker from this block, so
         without it `<.form>` (which carries none either) would sit outside this scope. */
      div.ai-model-editor-body:scope {
        display: contents;
      }

      .ai-model-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .ai-model-form label {
        display: block;
      }

      .ai-model-form-sampler,
      .ai-model-form-timeouts {
        border: 1px solid var(--border-grey);
        border-radius: var(--radius-2);
        padding: var(--size-2);
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .ai-model-form-sampler legend,
      .ai-model-form-timeouts legend {
        padding-inline: var(--size-1);
        color: var(--muted-foreground);
      }

      .ai-model-form-warning {
        margin: 0;
        font-size: 0.85rem;
        color: var(--destructive);
      }

      .ai-model-form-tokenizer {
        display: flex;
        align-items: flex-end;
        gap: var(--size-2);
      }

      .ai-model-form-tokenizer > :first-child {
        flex: 1 1 auto;
        min-inline-size: 0;
      }

      .ai-model-form-hf-error {
        margin: 0;
        font-size: 0.85rem;
        color: var(--destructive);
      }

      .ai-model-form-sampler-neutralize {
        align-self: flex-start;
      }

      .ai-model-form-sampler-note {
        margin: 0;
        font-size: 0.85rem;
        color: var(--muted-foreground);
      }

      .ai-model-form-sampler-order {
        list-style: none;
        margin: 0;
        padding: 0;
        max-inline-size: 24rem;
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
      }

      .ai-model-form-sampler-order li {
        display: flex;
        align-items: center;
        gap: var(--size-2);
      }

      .ai-model-form-sampler-order-name {
        flex: 1 1 auto;
      }
    </style>
    <Layouts.app flash={@flash} current_scope={@current_scope} search={:ai}>
      <.pane_layout>
        <:list
          id="ai-models-nav"
          label={dpgettext("ai", "aria label: list of AI models", "AI models")}
        >
          <.pane_header title={dpgettext("ai", "heading: list of AI models", "Models")}>
            <:switch id="pane-switch-connections" navigate={~p"/ai/providers"}>
              <.lucide name="plug" /> {dpgettext(
                "ai",
                "link: switch to the AI connection editor",
                "Connections"
              )}
            </:switch>
          </.pane_header>

          <.pane_actions>
            <.button variant="primary" patch={~p"/ai/models/new"} id="new-ai-model">
              <.lucide name="plus" /> {dpgettext("ai", "button: create an AI model", "New model")}
            </.button>
            <.bulk_toggle bulk={@bulk} id="models-bulk-toggle" />
          </.pane_actions>
          <.bulk_bar bulk={@bulk} id="models-bulk" />

          <.pane_search
            id="ai-model-filter"
            form={@filter_form}
            placeholder={dpgettext("ai", "placeholder: search AI models", "Name or model id")}
          >
            <.tag_filter
              id="ai-model-filter-tags"
              values={@tag_filter}
              vocabulary={@tag_vocabulary}
              errors={@tag_filter_errors}
              invalid={@tag_filter_invalid}
            />
          </.pane_search>

          <.pane_items
            :let={model}
            id="ai-models"
            rows={@streams.models}
            bulk={@bulk}
            bulk_list="models"
            patch={fn model -> ~p"/ai/models/#{model.id}/edit" end}
            selected_id={@selected_id}
            empty?={@models_empty?}
            empty={
              if @query == "" and @tag_filter == [],
                do: dpgettext("ai", "empty state: no AI models exist", "No AI models yet"),
                else: dgettext("ai", "No models match this search")
            }
          >
            <span class="pane-item-name">{model.name}</span>
            <span class="pane-item-meta">
              {dpngettext(
                "ai",
                "status: number of AI connections linking an AI model, and its completion mode",
                "%{connection_count} connection · %{completion_mode}",
                "%{connection_count} connections · %{completion_mode}",
                model.connection_count,
                connection_count: Format.number(model.connection_count),
                completion_mode: completion_mode_meta(model.completion_mode)
              )}
            </span>
            <span
              :if={
                model.supports_images or model.supports_files or model.supports_audio or
                  model.supports_video or
                  model.supports_tools or model.supports_thinking or
                  AIOwnership.personal_badge?(model, @current_scope)
              }
              class="pane-item-badges"
            >
              <.badge
                :if={AIOwnership.personal_badge?(model, @current_scope)}
                id={"ai-models-personal-#{model.id}"}
              >
                {dpgettext("ai", "badge: a personal AI model", "personal")}
              </.badge>
              <.badge :if={model.supports_images}>
                {dpgettext("ai", "badge: an AI model reads images", "images")}
              </.badge>
              <.badge :if={model.supports_files}>
                {dpgettext("ai", "badge: an AI model reads PDF files", "files")}
              </.badge>
              <.badge :if={model.supports_audio}>
                {dpgettext("ai", "badge: an AI model hears audio", "audio")}
              </.badge>
              <.badge :if={model.supports_video}>
                {dpgettext("ai", "badge: an AI model watches video", "video")}
              </.badge>
              <.badge :if={model.supports_tools}>
                {dpgettext("ai", "badge: an AI model can call tools", "tools")}
              </.badge>
              <.badge :if={model.supports_thinking}>
                {dpgettext("ai", "badge: an AI model returns separate reasoning", "thinking")}
              </.badge>
            </span>
          </.pane_items>
        </:list>

        <:editor id="ai-model-editor">
          <.pane_placeholder :if={@live_action == :index} id="ai-model-placeholder">
            {dgettext("ai", "Select a model, or create a new one.")}
          </.pane_placeholder>
          <div :if={@live_action != :index} class="ai-model-editor-body">
            <.panel_header sticky>
              {if @editing_model,
                do: @editing_model.name,
                else: dpgettext("ai", "heading: form creating an AI model", "New model")}
              <:actions :if={@editing_model}>
                <.pane_export
                  id="export-ai-model"
                  kind={:ai_model}
                  item={@editing_model}
                  current_scope={@current_scope}
                />
                <.pane_delete
                  id="delete-ai-model"
                  phx-click="delete"
                  phx-value-id={@editing_model.id}
                  confirm={delete_confirm(@editing_model.name)}
                >
                  {dpgettext("ai", "button: delete this AI model", "Delete")}
                </.pane_delete>
              </:actions>
            </.panel_header>

            <.pane_section>
              <.changed_elsewhere
                :if={@changed_elsewhere?}
                id="ai-model-changed-elsewhere"
                patch={@live_sync_path}
              />
              <.form
                for={@form}
                id="ai-model-form"
                class="ai-model-form"
                phx-hook="UnsavedChanges"
                data-saved={is_nil(@form.action)}
                phx-change="validate"
                phx-submit="save"
              >
                <AIOwnership.owner_select
                  :if={is_nil(@editing_model) and AI.owner_choice?(@current_scope)}
                  id="ai-model-form-owner"
                  value={@new_owner}
                  kind={:model}
                />
                <AIOwnership.owner_line
                  :if={@editing_model && Scope.can?(@current_scope, "site.ai.manage")}
                  id="ai-model-owner"
                  row={@editing_model}
                  kind={:model}
                />
                <.input
                  field={@form[:name]}
                  type="text"
                  label={dpgettext("ai", "field label: display name of an AI model", "Name")}
                  id="ai-model-form-name"
                  required
                >
                  <:hint>
                    {dgettext(
                      "ai",
                      "The name this model goes by in pickers and lists. It is never sent to the backend."
                    )}
                  </:hint>
                </.input>
                <.input
                  :if={
                    if @editing_model, do: is_nil(@editing_model.user_id), else: @new_owner == "site"
                  }
                  field={@form[:site_visibility]}
                  type="select"
                  label={
                    dpgettext(
                      "ai",
                      "field label: what non-admins see of a site AI model",
                      "Visible to users"
                    )
                  }
                  id="ai-model-form-site_visibility"
                  options={[
                    {dpgettext("ai", "option: non-admins see all of a site AI model", "Everything"),
                     "readable"},
                    {dpgettext(
                       "ai",
                       "option: non-admins see only a site AI model's name",
                       "Only names (runtime-only)"
                     ), "runtime_only"}
                  ]}
                >
                  <:hint>
                    {dgettext(
                      "ai",
                      "What users who are not admins see of this model. Only names: never its API model id, sampler, extras, reasoning tags, tokenizer, notes, time limits or caption prompt, in the assistant or exports; it still runs. Admins always see everything."
                    )}
                  </:hint>
                </.input>
                <.input
                  field={@form[:api_model_id]}
                  type="text"
                  label={dpgettext("ai", "field label: model id sent to the backend", "API model id")}
                  id="ai-model-form-api_model_id"
                  required
                >
                  <:hint>
                    {api_model_id_hint()}
                  </:hint>
                </.input>
                <div class="ai-model-form-tokenizer">
                  <.input
                    field={@form[:tokenizer]}
                    type="text"
                    label={
                      dpgettext(
                        "ai",
                        "field label: Hugging Face repo of an AI model's tokenizer",
                        "Tokenizer (Hugging Face repo)"
                      )
                    }
                    id="ai-model-form-tokenizer"
                    placeholder={dgettext("ai", "Qwen/Qwen3-8B or a huggingface.co link")}
                  >
                    <:hint>
                      {tokenizer_hint()}
                    </:hint>
                  </.input>
                  <.button
                    id="ai-model-form-hf-fill"
                    phx-click="fill_from_hf"
                    disabled={match?({:loading, _}, @hf_lookup)}
                  >
                    <.lucide name="sparkles" />
                    {if match?({:loading, _}, @hf_lookup),
                      do: dpgettext("ai", "button: Hugging Face lookup in progress", "Fetching…"),
                      else: fill_from_hf_label()}
                  </.button>
                </div>
                <p
                  :if={match?({:error, _}, @hf_lookup)}
                  id="ai-model-form-hf-error"
                  class="ai-model-form-hf-error"
                  role="status"
                >
                  {hf_message(elem(@hf_lookup, 1))}
                </p>
                <.input
                  field={@form[:completion_mode]}
                  type="select"
                  label={dpgettext("ai", "field label: AI model completion mode", "Completion mode")}
                  options={
                    for mode <- [:chat, :text, :embedding, :classifier],
                        do: {completion_mode_label(mode), Atom.to_string(mode)}
                  }
                  id="ai-model-form-completion_mode"
                >
                  <:hint>
                    {completion_mode_hint()}
                  </:hint>
                </.input>
                <.input
                  field={@form[:context_window]}
                  type="number"
                  label={
                    dpgettext(
                      "ai",
                      "field label: how many tokens an AI model reads at once",
                      "Context window"
                    )
                  }
                  id="ai-model-form-context_window"
                  min="1"
                >
                  <:hint>
                    {dgettext(
                      "ai",
                      "How many tokens the model can read at once, prompt and reply together. Recorded for reference: prompts are not yet trimmed to fit it."
                    )}
                  </:hint>
                </.input>
                <.input
                  field={@form[:prompt_cost_per_mtok]}
                  type="number"
                  label={
                    dpgettext(
                      "ai",
                      "field label: AI model price per million prompt tokens",
                      "Prompt cost per Mtok"
                    )
                  }
                  id="ai-model-form-prompt_cost_per_mtok"
                  step="any"
                  min="0"
                >
                  <:hint>
                    {dgettext(
                      "ai",
                      "Dollars per million prompt tokens, used to estimate a reply's cost when the connection reports no charge of its own. Leave both costs empty to skip estimates. For an embedding model, this prices the text it embeds."
                    )}
                  </:hint>
                </.input>
                <.input
                  field={@form[:completion_cost_per_mtok]}
                  type="number"
                  label={
                    dpgettext(
                      "ai",
                      "field label: AI model price per million completion tokens",
                      "Completion cost per Mtok"
                    )
                  }
                  id="ai-model-form-completion_cost_per_mtok"
                  step="any"
                  min="0"
                >
                  <:hint>
                    {dgettext(
                      "ai",
                      "Dollars per million generated tokens, reasoning included, used like the prompt cost when the connection reports no charge. Unused by embedding models."
                    )}
                  </:hint>
                </.input>
                <.input
                  field={@form[:supports_images]}
                  type="checkbox"
                  label={
                    dpgettext("ai", "field label: AI model reads images itself", "Supports images")
                  }
                  id="ai-model-form-supports_images"
                >
                  <:hint>
                    {dgettext(
                      "ai",
                      "The model reads images itself, so chat images are sent to it inline. Off, it reads them only as text descriptions written by a caption model."
                    )}
                  </:hint>
                </.input>
                <.input
                  field={@form[:supports_files]}
                  type="checkbox"
                  label={
                    dpgettext("ai", "field label: AI model reads PDF files itself", "Reads PDFs")
                  }
                  id="ai-model-form-supports_files"
                >
                  <:hint>
                    {dgettext(
                      "ai",
                      "PDFs are sent to the model as files. Off, it reads their extracted text."
                    )}
                  </:hint>
                </.input>
                <.input
                  field={@form[:inline_document_limit]}
                  type="number"
                  label={dgettext("ai", "Messages with documents sent in full")}
                  id="ai-model-form-inline_document_limit"
                  min="0"
                >
                  <:hint>
                    {dgettext(
                      "ai",
                      "How many of the chat's newest messages with documents send them in full (as PDFs to a model that reads them, else as their text); older ones go as a short summary, written once by this model. Empty sends them all."
                    )}
                  </:hint>
                </.input>
                <.input
                  field={@form[:supports_audio]}
                  type="checkbox"
                  label={dpgettext("ai", "field label: AI model hears audio itself", "Hears audio")}
                  id="ai-model-form-supports_audio"
                >
                  <:hint>
                    {dgettext(
                      "ai",
                      "Audio clips are sent to the model. Off, it sees only [Audio: name]."
                    )}
                  </:hint>
                </.input>
                <.input
                  :if={checked?(@form[:supports_audio])}
                  field={@form[:inline_audio_limit]}
                  type="number"
                  min="0"
                  label={dgettext("ai", "Messages with audio sent inline")}
                  id="ai-model-form-inline_audio_limit"
                >
                  <:hint>
                    {dgettext(
                      "ai",
                      "How many of the chat's newest messages with audio send their clips to the model; older clips go as their descriptions. Empty sends them all."
                    )}
                  </:hint>
                </.input>
                <.input
                  field={@form[:supports_video]}
                  type="checkbox"
                  label={
                    dpgettext("ai", "field label: AI model watches video itself", "Watches video")
                  }
                  id="ai-model-form-supports_video"
                >
                  <:hint>
                    {dgettext(
                      "ai",
                      "Video clips are sent to the model, every visible clip with every reply. Off, it sees only [Video: name]."
                    )}
                  </:hint>
                </.input>
                <.input
                  :if={checked?(@form[:supports_video])}
                  field={@form[:inline_video_limit]}
                  type="number"
                  min="0"
                  label={dgettext("ai", "Messages with video sent inline")}
                  id="ai-model-form-inline_video_limit"
                >
                  <:hint>
                    {dgettext(
                      "ai",
                      "How many of the chat's newest messages with video send their clips to the model; older clips go as their descriptions. Empty sends them all."
                    )}
                  </:hint>
                </.input>
                <%!-- A model that cannot take images, audio or video can have another model describe
                     them first; a vision model has its own caption prompt and limits for when it describes. --%>
                <.input
                  :if={
                    not (checked?(@form[:supports_images]) and checked?(@form[:supports_audio]) and
                           checked?(@form[:supports_video]))
                  }
                  field={@form[:caption_model_id]}
                  type="select"
                  label={
                    dpgettext(
                      "ai",
                      "field label: model that describes media for an AI model",
                      "Describe images, audio and video with"
                    )
                  }
                  prompt={dpgettext("ai", "option: no caption model chosen", "None")}
                  options={@caption_model_options}
                  id="ai-model-form-caption_model_id"
                >
                  <:hint>
                    {caption_model_hint()}
                  </:hint>
                </.input>
                <%= if checked?(@form[:supports_images]) do %>
                  <.input
                    field={@form[:caption_prompt_id]}
                    type="select"
                    label={
                      dpgettext(
                        "ai",
                        "field label: prompt an AI model follows to describe images",
                        "Caption prompt"
                      )
                    }
                    prompt={
                      dpgettext(
                        "ai",
                        "option: the built-in caption instruction, no prompt chosen",
                        "Built-in instruction"
                      )
                    }
                    options={@caption_prompt_options}
                    id="ai-model-form-caption_prompt_id"
                  >
                    <:hint>
                      {dgettext(
                        "ai",
                        "The prompt this model follows when it describes an image for another model or an avatar. The built-in instruction asks for one short, objective paragraph."
                      )}
                    </:hint>
                  </.input>
                  <.input
                    field={@form[:inline_image_limit]}
                    type="number"
                    label={dgettext("ai", "Messages with images sent inline")}
                    id="ai-model-form-inline_image_limit"
                    min="0"
                  >
                    <:hint>
                      {dgettext(
                        "ai",
                        "How many of the chat's newest messages with images send their images to the model, every image of each; older ones go as their descriptions, so a long chat does not re-send every picture. Empty sends them all."
                      )}
                    </:hint>
                  </.input>
                  <.input
                    field={@form[:image_detail]}
                    type="select"
                    label={
                      dpgettext(
                        "ai",
                        "field label: image detail hint an AI model sends",
                        "Image detail"
                      )
                    }
                    prompt={image_detail_prompt()}
                    options={
                      for detail <- [:low, :auto, :high],
                          do: {EnumLabels.label(Model, :image_detail, detail), detail}
                    }
                    id="ai-model-form-image_detail"
                  >
                    <:hint>
                      {image_detail_hint()}
                    </:hint>
                  </.input>
                <% end %>
                <.input
                  field={@form[:caption_max_tokens]}
                  type="number"
                  label={
                    dpgettext(
                      "ai",
                      "field label: longest description an AI model writes",
                      "Caption max tokens"
                    )
                  }
                  id="ai-model-form-caption_max_tokens"
                  min="1"
                >
                  <:hint>
                    {dgettext(
                      "ai",
                      "The longest a description or summary this model writes may run. Longer descriptions cost more and take up more of the reading model's prompt."
                    )}
                  </:hint>
                </.input>
                <.input
                  field={@form[:supports_tools]}
                  type="checkbox"
                  label={dpgettext("ai", "field label: AI model can call tools", "Supports tools")}
                  id="ai-model-form-supports_tools"
                >
                  <:hint>
                    {dgettext(
                      "ai",
                      "Records that the model can call tools (functions). Informational for now: replies do not use tools yet."
                    )}
                  </:hint>
                </.input>
                <.input
                  field={@form[:supports_thinking]}
                  type="checkbox"
                  label={
                    dpgettext(
                      "ai",
                      "field label: AI model returns separate reasoning",
                      "Supports thinking"
                    )
                  }
                  id="ai-model-form-supports_thinking"
                >
                  <:hint>
                    {supports_thinking_hint()}
                  </:hint>
                </.input>
                <p
                  :if={@thinking_budget_warning?}
                  id="ai-model-form-thinking-warning"
                  class="ai-model-form-warning"
                  role="status"
                >
                  {thinking_warning()}
                </p>
                <.input
                  field={@form[:continue_prefill]}
                  type="checkbox"
                  label={
                    dpgettext(
                      "ai",
                      "field label: AI model continues a message by assistant prefill",
                      "Continue by assistant prefill"
                    )
                  }
                  id="ai-model-form-continue_prefill"
                >
                  <:hint>
                    {dgettext(
                      "ai",
                      "Continue sends the unfinished message as a trailing assistant turn for the model to extend word for word, instead of instructing it to carry on. Chat models only, and the backend must continue a final assistant message (llama.cpp and Claude do)."
                    )}
                  </:hint>
                </.input>
                <.input
                  field={@form[:reasoning_prefix]}
                  type="text"
                  label={
                    dpgettext(
                      "ai",
                      "field label: tag opening an AI model's inline reasoning",
                      "Reasoning prefix"
                    )
                  }
                  id="ai-model-form-reasoning_prefix"
                  placeholder="<think>"
                >
                  <:hint>
                    {reasoning_prefix_hint()}
                  </:hint>
                </.input>
                <.input
                  field={@form[:reasoning_suffix]}
                  type="text"
                  label={
                    dpgettext(
                      "ai",
                      "field label: tag closing an AI model's inline reasoning",
                      "Reasoning suffix"
                    )
                  }
                  id="ai-model-form-reasoning_suffix"
                  placeholder="</think>"
                >
                  <:hint>
                    {reasoning_suffix_hint()}
                  </:hint>
                </.input>
                <.editor
                  field={@form[:notes]}
                  label={
                    dpgettext(
                      "ai",
                      "field label: the owner's private notes about an AI model",
                      "Notes"
                    )
                  }
                  rows={3}
                  id="ai-model-form-notes"
                  language="markdown"
                  spellcheck
                >
                  <:hint>
                    {dgettext("ai", "Your own notes about this model. They are never sent anywhere.")}
                  </:hint>
                </.editor>
                <.editor
                  name="model[extra_body]"
                  id="ai-model-form-extra_body"
                  label={
                    dpgettext(
                      "ai",
                      "field label: extra JSON request body of an AI model",
                      "Extra request body"
                    )
                  }
                  rows={3}
                  language="json"
                  line_numbers
                  value={@extra_body_json}
                  errors={translate_errors(@form.errors, :extra_body)}
                >
                  <:hint>
                    {extra_body_hint()}
                  </:hint>
                </.editor>

                <fieldset class="ai-model-form-timeouts">
                  <legend>
                    {dpgettext("ai", "heading: an AI model's generation time limits", "Time limits")}
                  </legend>
                  <p class="ai-model-form-sampler-note">
                    {dgettext(
                      "ai",
                      "Seconds. Chat covers replies, regenerates, continues, refines and the assistant; background covers memory work and image captions. Empty keeps the default shown, 0 means no limit. The connection's request timeout still ends a request that sends nothing at all for that long. Embedding models ignore these."
                    )}
                  </p>
                  <.field_row id="ai-model-form-timeouts-row">
                    <:field>
                      <.input
                        field={@form[:chat_first_token_seconds]}
                        type="number"
                        label={
                          dpgettext(
                            "ai",
                            "field label: chat time limit for the first token",
                            "Chat: first token"
                          )
                        }
                        id="ai-model-form-chat_first_token_seconds"
                        min="0"
                        placeholder={default_seconds(:reply, :first_token_ms)}
                      >
                        <:hint>
                          {dgettext(
                            "ai",
                            "How long a reply may wait for its first token, prompt processing included, before it stops."
                          )}
                        </:hint>
                      </.input>
                    </:field>
                    <:field>
                      <.input
                        field={@form[:chat_stall_seconds]}
                        type="number"
                        label={
                          dpgettext("ai", "field label: chat time limit for silence", "Chat: stall")
                        }
                        id="ai-model-form-chat_stall_seconds"
                        min="0"
                        placeholder={default_seconds(:reply, :idle_ms)}
                      >
                        <:hint>
                          {dgettext("ai", "How long a reply may go silent after its first token.")}
                        </:hint>
                      </.input>
                    </:field>
                    <:field>
                      <.input
                        field={@form[:chat_deadline_seconds]}
                        type="number"
                        label={dpgettext("ai", "field label: chat total time limit", "Chat: total")}
                        id="ai-model-form-chat_deadline_seconds"
                        min="0"
                        placeholder={default_seconds(:reply, :deadline_ms)}
                      >
                        <:hint>{dgettext("ai", "The longest a reply may run in all.")}</:hint>
                      </.input>
                    </:field>
                    <:field>
                      <.input
                        field={@form[:background_first_token_seconds]}
                        type="number"
                        label={
                          dpgettext(
                            "ai",
                            "field label: background job time limit for the first token",
                            "Background: first token"
                          )
                        }
                        id="ai-model-form-background_first_token_seconds"
                        min="0"
                        placeholder={default_seconds(:memory, :first_token_ms)}
                      >
                        <:hint>
                          {dgettext(
                            "ai",
                            "As for chat, for memory and caption jobs, whose prompts are often larger."
                          )}
                        </:hint>
                      </.input>
                    </:field>
                    <:field>
                      <.input
                        field={@form[:background_stall_seconds]}
                        type="number"
                        label={
                          dpgettext(
                            "ai",
                            "field label: background job time limit for silence",
                            "Background: stall"
                          )
                        }
                        id="ai-model-form-background_stall_seconds"
                        min="0"
                        placeholder={default_seconds(:memory, :idle_ms)}
                      >
                        <:hint>{dgettext("ai", "As for chat, for memory and caption jobs.")}</:hint>
                      </.input>
                    </:field>
                    <:field>
                      <.input
                        field={@form[:background_deadline_seconds]}
                        type="number"
                        label={
                          dpgettext(
                            "ai",
                            "field label: background job total time limit",
                            "Background: total"
                          )
                        }
                        id="ai-model-form-background_deadline_seconds"
                        min="0"
                        placeholder={default_seconds(:memory, :deadline_ms)}
                      >
                        <:hint>
                          {background_deadline_hint()}
                        </:hint>
                      </.input>
                    </:field>
                  </.field_row>
                </fieldset>

                <.inputs_for :let={sampler} field={@form[:sampler]}>
                  <fieldset class="ai-model-form-sampler">
                    <legend>
                      {dpgettext(
                        "ai",
                        "heading: an AI model's default sampler settings",
                        "Default sampler"
                      )}
                    </legend>
                    <div class="ai-model-form-sampler-neutralize">
                      <.button
                        type="button"
                        variant="secondary"
                        size="sm"
                        id="ai-model-form-sampler-neutralize"
                        phx-click="sampler_neutralize"
                      >
                        {dpgettext(
                          "ai",
                          "button: reset sampler truncation and penalties to neutral",
                          "Neutralize samplers"
                        )}
                      </.button>
                    </div>
                    <.field_row id="ai-model-form-sampler-row">
                      <:field>
                        <.input
                          field={sampler[:max_tokens]}
                          type="number"
                          label={
                            dpgettext(
                              "ai",
                              "field label: most tokens one reply may generate",
                              "Response tokens"
                            )
                          }
                          id="ai-model-form-sampler-max_tokens"
                          min="1"
                        >
                          <:hint>
                            {max_tokens_hint()}
                          </:hint>
                        </.input>
                      </:field>
                      <:field>
                        <.input
                          field={sampler[:temperature]}
                          type="number"
                          label={dpgettext("ai", "field label: sampler temperature", "Temperature")}
                          id="ai-model-form-sampler-temperature"
                          step="any"
                          min="0"
                          max="5"
                        >
                          <:hint>
                            {dgettext(
                              "ai",
                              "How random each word choice is. Lower is focused and predictable, higher varied and creative; 0 always picks the likeliest token. Around 0.7 to 1.0 suits role-play."
                            )}
                          </:hint>
                        </.input>
                      </:field>
                      <:field>
                        <.input
                          field={sampler[:top_p]}
                          type="number"
                          label={
                            dpgettext("ai", "field label: sampler nucleus sampling cutoff", "Top p")
                          }
                          id="ai-model-form-sampler-top_p"
                          step="any"
                          min="0"
                          max="1"
                        >
                          <:hint>
                            {dgettext(
                              "ai",
                              "Nucleus sampling: chooses only among the likeliest tokens whose probabilities add up to this. 1 turns it off; lower values cut unlikely words."
                            )}
                          </:hint>
                        </.input>
                      </:field>
                      <:field>
                        <.input
                          field={sampler[:top_k]}
                          type="number"
                          label={dpgettext("ai", "field label: sampler top-k cutoff", "Top k")}
                          id="ai-model-form-sampler-top_k"
                          min="0"
                        >
                          <:hint>
                            {top_k_hint()}
                          </:hint>
                        </.input>
                      </:field>
                      <:field>
                        <.input
                          field={sampler[:min_p]}
                          type="number"
                          label={dpgettext("ai", "field label: sampler min-p cutoff", "Min p")}
                          id="ai-model-form-sampler-min_p"
                          step="any"
                          min="0"
                          max="1"
                        >
                          <:hint>
                            {dgettext(
                              "ai",
                              "Drops tokens less likely than this fraction of the top token's probability, so it cuts more when the model is sure. 0.05 to 0.1 is common for local models; 0 turns it off."
                            )}
                          </:hint>
                        </.input>
                      </:field>
                      <:field>
                        <.input
                          field={sampler[:top_a]}
                          type="number"
                          label={dpgettext("ai", "field label: sampler top-a cutoff", "Top a")}
                          id="ai-model-form-sampler-top_a"
                          step="any"
                          min="0"
                          max="1"
                        >
                          <:hint>
                            {dgettext(
                              "ai",
                              "Drops tokens whose probability is below this value times the square of the top token's. Rarely needed; 0 turns it off. Read by OpenRouter and TabbyAPI, not llama.cpp."
                            )}
                          </:hint>
                        </.input>
                      </:field>
                      <:field>
                        <.input
                          field={sampler[:typical_p]}
                          type="number"
                          label={
                            dpgettext("ai", "field label: sampler typical-p cutoff", "Typical p")
                          }
                          id="ai-model-form-sampler-typical_p"
                          step="any"
                          min="0"
                          max="1"
                        >
                          <:hint>
                            {dgettext(
                              "ai",
                              "Locally typical sampling: keeps tokens about as surprising as the model expects, cutting both the bland and the bizarre. 1 turns it off. Not sent to OpenAI or OpenRouter."
                            )}
                          </:hint>
                        </.input>
                      </:field>
                      <:field>
                        <.input
                          field={sampler[:repetition_penalty]}
                          type="number"
                          label={
                            dpgettext(
                              "ai",
                              "field label: sampler repetition penalty",
                              "Repetition penalty"
                            )
                          }
                          id="ai-model-form-sampler-repetition_penalty"
                          step="any"
                          min="0"
                          max="4"
                        >
                          <:hint>
                            {dgettext(
                              "ai",
                              "Makes tokens that already appeared less likely, to curb loops. 1 turns it off; 1.05 to 1.15 is typical, and higher can garble names and wording. Mainly read by local backends."
                            )}
                          </:hint>
                        </.input>
                      </:field>
                      <:field>
                        <.input
                          field={sampler[:frequency_penalty]}
                          type="number"
                          label={
                            dpgettext(
                              "ai",
                              "field label: sampler frequency penalty",
                              "Frequency penalty"
                            )
                          }
                          id="ai-model-form-sampler-frequency_penalty"
                          step="any"
                          min="-2"
                          max="2"
                        >
                          <:hint>
                            {dgettext(
                              "ai",
                              "OpenAI-style: penalizes a token more each time it has appeared, reducing repeated words. 0 turns it off."
                            )}
                          </:hint>
                        </.input>
                      </:field>
                      <:field>
                        <.input
                          field={sampler[:presence_penalty]}
                          type="number"
                          label={
                            dpgettext(
                              "ai",
                              "field label: sampler presence penalty",
                              "Presence penalty"
                            )
                          }
                          id="ai-model-form-sampler-presence_penalty"
                          step="any"
                          min="-2"
                          max="2"
                        >
                          <:hint>
                            {dgettext(
                              "ai",
                              "OpenAI-style: penalizes any token that has appeared at all, nudging the model toward new words and topics. 0 turns it off."
                            )}
                          </:hint>
                        </.input>
                      </:field>
                      <:field>
                        <.input
                          field={sampler[:repetition_penalty_range]}
                          type="number"
                          label={
                            dpgettext(
                              "ai",
                              "field label: how far back the repetition penalty looks",
                              "Repetition penalty range"
                            )
                          }
                          id="ai-model-form-sampler-repetition_penalty_range"
                          min="0"
                        >
                          <:hint>
                            {dgettext(
                              "ai",
                              "How many of the most recent tokens the repetition penalty looks at. Backends differ on what 0 means: off, or the whole context."
                            )}
                          </:hint>
                        </.input>
                      </:field>
                    </.field_row>
                    <fieldset class="ai-model-form-sampler">
                      <legend>{dpgettext("ai", "heading: DRY sampler settings", "DRY")}</legend>
                      <.field_row id="ai-model-form-sampler-dry-row">
                        <:field>
                          <.input
                            field={sampler[:dry_multiplier]}
                            type="number"
                            label={
                              dpgettext("ai", "field label: DRY sampler multiplier", "Multiplier")
                            }
                            id="ai-model-form-sampler-dry_multiplier"
                            step="any"
                            min="0"
                          >
                            <:hint>
                              {dgettext(
                                "ai",
                                "\"Don't repeat yourself\": penalizes a token that would extend a phrase already in the context, growing with the phrase's length. The strongest cure for loops on local models; 0 turns it off, 0.8 is a common start. llama.cpp and TabbyAPI."
                              )}
                            </:hint>
                          </.input>
                        </:field>
                        <:field>
                          <.input
                            field={sampler[:dry_base]}
                            type="number"
                            label={dpgettext("ai", "field label: DRY sampler base", "Base")}
                            id="ai-model-form-sampler-dry_base"
                            step="any"
                            min="1"
                          >
                            <:hint>
                              {dgettext(
                                "ai",
                                "How fast the penalty grows with each extra repeated token. 1.75 is the usual value."
                              )}
                            </:hint>
                          </.input>
                        </:field>
                        <:field>
                          <.input
                            field={sampler[:dry_allowed_length]}
                            type="number"
                            label={
                              dpgettext(
                                "ai",
                                "field label: DRY sampler allowed repeat length",
                                "Allowed length"
                              )
                            }
                            id="ai-model-form-sampler-dry_allowed_length"
                            min="0"
                          >
                            <:hint>
                              {dgettext(
                                "ai",
                                "The longest repeat left unpenalized, so names and set phrases still work. 2 is the usual value."
                              )}
                            </:hint>
                          </.input>
                        </:field>
                        <:field>
                          <.input
                            field={sampler[:dry_penalty_last_n]}
                            type="number"
                            label={
                              dpgettext(
                                "ai",
                                "field label: how far back the DRY sampler looks",
                                "Penalty range"
                              )
                            }
                            id="ai-model-form-sampler-dry_penalty_last_n"
                            min="0"
                          >
                            <:hint>
                              {dgettext(
                                "ai",
                                "How many recent tokens DRY scans for repeats. 0 means the whole context."
                              )}
                            </:hint>
                          </.input>
                        </:field>
                        <:field size="wide">
                          <.input
                            type="text"
                            name="model[sampler][dry_sequence_breakers]"
                            id="ai-model-form-sampler-dry_sequence_breakers"
                            label={
                              dpgettext(
                                "ai",
                                "field label: strings that break a DRY repeat",
                                "Sequence breakers"
                              )
                            }
                            value={@dry_sequence_breakers_input}
                            errors={translate_errors(sampler.errors, :dry_sequence_breakers)}
                          >
                            <:hint>
                              {sequence_breakers_hint()}
                            </:hint>
                          </.input>
                        </:field>
                      </.field_row>
                    </fieldset>
                    <fieldset class="ai-model-form-sampler">
                      <legend>{dpgettext("ai", "heading: XTC sampler settings", "XTC")}</legend>
                      <.field_row id="ai-model-form-sampler-xtc-row">
                        <:field>
                          <.input
                            field={sampler[:xtc_threshold]}
                            type="number"
                            label={dpgettext("ai", "field label: XTC sampler threshold", "Threshold")}
                            id="ai-model-form-sampler-xtc_threshold"
                            step="any"
                            min="0"
                            max="1"
                          >
                            <:hint>
                              {dgettext(
                                "ai",
                                "\"Exclude top choices\": when several tokens are at least this likely, all but the least likely of them are removed, steering away from the most predictable wording. 0.1 is a common start. llama.cpp and TabbyAPI."
                              )}
                            </:hint>
                          </.input>
                        </:field>
                        <:field>
                          <.input
                            field={sampler[:xtc_probability]}
                            type="number"
                            label={
                              dpgettext("ai", "field label: XTC sampler probability", "Probability")
                            }
                            id="ai-model-form-sampler-xtc_probability"
                            step="any"
                            min="0"
                            max="1"
                          >
                            <:hint>
                              {dgettext(
                                "ai",
                                "How often XTC acts on a token. 0 turns it off; 0.5 is a common start."
                              )}
                            </:hint>
                          </.input>
                        </:field>
                      </.field_row>
                    </fieldset>
                    <fieldset class="ai-model-form-sampler">
                      <legend>
                        {dpgettext(
                          "ai",
                          "heading: dynamic temperature sampler settings",
                          "Dynamic temperature"
                        )}
                      </legend>
                      <.field_row id="ai-model-form-sampler-dynatemp-row">
                        <:field>
                          <.input
                            field={sampler[:dynatemp_low]}
                            type="number"
                            label={
                              dpgettext("ai", "field label: dynamic temperature minimum", "Minimum")
                            }
                            id="ai-model-form-sampler-dynatemp_low"
                            step="any"
                            min="0"
                            max="5"
                          >
                            <:hint>
                              {dgettext(
                                "ai",
                                "The temperature used when the model is sure. Replaces Temperature when both are set; llama.cpp gets the midpoint ± half the range."
                              )}
                            </:hint>
                          </.input>
                        </:field>
                        <:field>
                          <.input
                            field={sampler[:dynatemp_high]}
                            type="number"
                            label={
                              dpgettext("ai", "field label: dynamic temperature maximum", "Maximum")
                            }
                            id="ai-model-form-sampler-dynatemp_high"
                            step="any"
                            min="0"
                            max="5"
                          >
                            <:hint>
                              {dgettext(
                                "ai",
                                "The temperature used when the model is unsure, so creativity rises where many words fit."
                              )}
                            </:hint>
                          </.input>
                        </:field>
                        <:field>
                          <.input
                            field={sampler[:dynatemp_exponent]}
                            type="number"
                            label={
                              dpgettext("ai", "field label: dynamic temperature exponent", "Exponent")
                            }
                            id="ai-model-form-sampler-dynatemp_exponent"
                            step="any"
                            min="0"
                            max="10"
                          >
                            <:hint>
                              {dgettext(
                                "ai",
                                "How the temperature moves between the two; 1 is linear, higher stays near the minimum longer."
                              )}
                            </:hint>
                          </.input>
                        </:field>
                      </.field_row>
                    </fieldset>
                    <fieldset class="ai-model-form-sampler">
                      <legend>
                        {dpgettext("ai", "heading: token-level sampler settings", "Token control")}
                      </legend>
                      <.field_row id="ai-model-form-sampler-tokens-row">
                        <:field>
                          <.input
                            field={sampler[:top_n_sigma]}
                            type="number"
                            label={
                              dpgettext("ai", "field label: sampler top-n-sigma cutoff", "Top nσ")
                            }
                            id="ai-model-form-sampler-top_n_sigma"
                            step="any"
                            min="0"
                          >
                            <:hint>
                              {dgettext(
                                "ai",
                                "Keeps only tokens within this many standard deviations of the top token's score, which stays stable at high temperature. 0 turns it off. llama.cpp only."
                              )}
                            </:hint>
                          </.input>
                        </:field>
                        <:field>
                          <.input
                            field={sampler[:ignore_eos]}
                            type="select"
                            label={
                              dpgettext(
                                "ai",
                                "field label: forbid the end-of-sequence token",
                                "Ban EOS token"
                              )
                            }
                            prompt={backend_default_label()}
                            options={switch_options()}
                            id="ai-model-form-sampler-ignore_eos"
                          >
                            <:hint>
                              {dgettext(
                                "ai",
                                "On, the model may not end its reply, so every reply runs to the response token limit or a stop sequence. llama.cpp, vLLM and TabbyAPI."
                              )}
                            </:hint>
                          </.input>
                        </:field>
                        <:field>
                          <.input
                            field={sampler[:skip_special_tokens]}
                            type="select"
                            label={
                              dpgettext(
                                "ai",
                                "field label: drop special tokens from reply text",
                                "Skip special tokens"
                              )
                            }
                            prompt={backend_default_label()}
                            options={switch_options()}
                            id="ai-model-form-sampler-skip_special_tokens"
                          >
                            <:hint>
                              {skip_special_tokens_hint()}
                            </:hint>
                          </.input>
                        </:field>
                      </.field_row>
                      <.editor
                        name="model[sampler][logit_bias]"
                        id="ai-model-form-sampler-logit_bias"
                        label={dpgettext("ai", "field label: per-token sampling bias", "Logit bias")}
                        rows={3}
                        language="json"
                        value={@logit_bias_json}
                        errors={translate_errors(sampler.errors, :logit_bias)}
                      >
                        <:hint>
                          {logit_bias_hint()}
                        </:hint>
                      </.editor>
                    </fieldset>
                    <fieldset class="ai-model-form-sampler">
                      <legend>
                        {dpgettext(
                          "ai",
                          "heading: order llama.cpp applies samplers in",
                          "Sampler order"
                        )}
                      </legend>
                      <p class="ai-model-form-sampler-note">
                        {dgettext(
                          "ai",
                          "The order llama.cpp applies its samplers in; other backends ignore it. Moving Temperature last, for instance, makes it reshape only what Min p and the others keep."
                        )}
                      </p>
                      <%= if @sampler_order == [] do %>
                        <p class="ai-model-form-sampler-note">
                          {dpgettext(
                            "ai",
                            "status: no custom sampler order set",
                            "Backend default order"
                          )}
                        </p>
                        <div class="ai-model-form-sampler-neutralize">
                          <.button
                            size="sm"
                            id="ai-model-form-sampler-order-customize"
                            phx-click="sampler_order_customize"
                          >
                            {dpgettext("ai", "button: set a custom sampler order", "Customize order")}
                          </.button>
                        </div>
                      <% else %>
                        <ol
                          id="ai-model-form-sampler-order"
                          class="ai-model-form-sampler-order"
                          phx-hook="SortableList"
                          data-sortable-event="sampler_order_reorder"
                        >
                          <li
                            :for={name <- @sampler_order}
                            id={"ai-model-form-sampler-order-#{name}"}
                            data-id={name}
                          >
                            <.drag_handle />
                            <span class="ai-model-form-sampler-order-name">{sampler_label(name)}</span>
                            <input type="hidden" name="model[sampler][sampler_order][]" value={name} />
                          </li>
                        </ol>
                        <div class="ai-model-form-sampler-neutralize">
                          <.button
                            size="sm"
                            id="ai-model-form-sampler-order-reset"
                            phx-click="sampler_order_reset"
                          >
                            {dpgettext(
                              "ai",
                              "button: drop the custom sampler order",
                              "Use backend order"
                            )}
                          </.button>
                        </div>
                      <% end %>
                    </fieldset>
                    <.field_row id="ai-model-form-sampler-misc-row">
                      <:field>
                        <.input
                          field={sampler[:thinking]}
                          type="select"
                          label={
                            dpgettext(
                              "ai",
                              "field label: reasoning effort of a thinking model",
                              "Thinking"
                            )
                          }
                          prompt={backend_default_label()}
                          options={SamplerParams.thinking_options()}
                          id="ai-model-form-sampler-thinking"
                        >
                          <:hint>
                            {thinking_hint()}
                          </:hint>
                        </.input>
                      </:field>
                      <:field>
                        <.input
                          field={sampler[:seed]}
                          type="number"
                          label={dpgettext("ai", "field label: sampler random seed", "Seed")}
                          id="ai-model-form-sampler-seed"
                        >
                          <:hint>
                            {dgettext(
                              "ai",
                              "Fixes the random seed, so the same prompt and settings give the same reply where the backend supports it. Empty picks a new seed every time."
                            )}
                          </:hint>
                        </.input>
                      </:field>
                      <:field size="wide">
                        <.input
                          type="text"
                          name="model[sampler][stop_sequences]"
                          id="ai-model-form-sampler-stop_sequences"
                          label={
                            dpgettext(
                              "ai",
                              "field label: strings that end a reply, comma separated",
                              "Stop sequences (comma separated)"
                            )
                          }
                          value={@stop_sequences_input}
                        >
                          <:hint>
                            {stop_sequences_hint()}
                          </:hint>
                        </.input>
                      </:field>
                    </.field_row>
                    <.editor
                      name="model[sampler][extra]"
                      id="ai-model-form-sampler-extra"
                      label={
                        dpgettext(
                          "ai",
                          "field label: extra JSON sampler keys",
                          "Extra sampler params"
                        )
                      }
                      rows={3}
                      language="json"
                      line_numbers
                      value={@sampler_extra_json}
                      errors={translate_errors(@form.errors, :sampler)}
                    >
                      <:hint>
                        {dgettext(
                          "ai",
                          "A JSON object of sampler keys passed to the backend verbatim, for knobs this form lacks (mirostat, adaptive-P, grammar). A key here wins over the matching field above."
                        )}
                      </:hint>
                    </.editor>
                  </fieldset>
                </.inputs_for>

                <.tag_fields
                  id="ai-model-form-tags"
                  prefix="tags"
                  field={@tag_fields.item}
                  vocabulary={@tag_vocabulary}
                />

                <.form_actions>
                  <.button patch={
                    if @editing_model,
                      do: ~p"/ai/models/#{@editing_model.id}/edit",
                      else: ~p"/ai/models"
                  }>
                    {dpgettext("ai", "button: discard edits to the AI model form", "Cancel")}
                  </.button>
                  <.button type="submit" variant="primary">
                    {dpgettext("ai", "button: save the AI model form", "Save")}
                  </.button>
                </.form_actions>
              </.form>
            </.pane_section>

            <.form
              :if={@model_group_ids}
              for={%{}}
              as={:groups}
              id="ai-model-groups-form"
              phx-submit="save_model_groups"
            >
              <.input
                name="groups[ids][]"
                type="select"
                multiple
                label={
                  dpgettext(
                    "ai",
                    "field label: groups allowed to run a site AI model",
                    "Who may use it"
                  )
                }
                options={@group_options}
                value={@model_group_ids}
                id="ai-model-groups-form-ids"
              >
                <:hint>
                  {dgettext("ai", "Leave empty for everyone allowed to use site models.")}
                </:hint>
              </.input>
              <.form_actions>
                <.button type="submit" variant="primary">
                  {dpgettext("ai", "button: save which groups may use a site AI model", "Save")}
                </.button>
              </.form_actions>
            </.form>

            <.hf_compare :if={@hf_compare} compare={@hf_compare} />
            <.live_component
              :if={@editing_model}
              module={MythweaverWeb.SharePanel}
              id="ai-model-share"
              current_scope={@current_scope}
              item={@editing_model}
            />
          </div>
        </:editor>
      </.pane_layout>
      <AIOwnership.transfer_modal
        :if={@transfer}
        id="ai-model-transfer-modal"
        transfer={@transfer}
        row={@editing_model}
        kind={:model}
      />
      <MythweaverWeb.Sudo.modal :if={@sudo_prompt} prompt={@sudo_prompt} />
    </Layouts.app>
    """
  end
end
