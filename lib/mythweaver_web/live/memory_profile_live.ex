defmodule MythweaverWeb.MemoryProfileLive do
  @moduledoc """
  Memory profile manager: the profile list on the left, the selected profile's form on the right. A
  profile names the model and prompts memory jobs use and the lore-entry settings every memory it
  writes gets. Each owner may have one default profile; a chat without its own profile uses its
  owner's default, else the site's. `:index` selects nothing: the editor pane shows a placeholder
  until a profile is picked.

  Open to anyone `MythweaverWeb.ContentAccess` admits: the list holds the profiles the scope may edit
  (`Mythweaver.Ownership`).
  """
  use MythweaverWeb, :live_view

  import MythweaverWeb.BulkComponents
  import MythweaverWeb.Pane

  alias Mythweaver.AI
  alias Mythweaver.Memory
  alias Mythweaver.Memory.Profile
  alias Mythweaver.Ownership
  alias Mythweaver.Prompts
  alias Mythweaver.Prompts.Prompt
  alias MythweaverWeb.Bulk
  alias MythweaverWeb.Bulk.Field
  alias MythweaverWeb.Bulk.Spec
  alias MythweaverWeb.CoreComponents.OwnerSelect
  alias MythweaverWeb.EnumLabels
  alias MythweaverWeb.LiveSync
  alias MythweaverWeb.ReferenceOptions

  on_mount {MythweaverWeb.ContentAccess, :memory}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: dpgettext("memory", "page title: list of memory profiles", "Memory profiles"),
       form: nil,
       editing_profile: nil,
       new_owner: "personal",
       selected_id: nil,
       kept_options: %{}
     )
     |> assign_options()
     |> stream_configure(:memory_profiles, dom_id: &"memory-profiles-#{&1.id}")
     |> assign_filter()
     |> stream_profiles()
     |> Bulk.attach([bulk_spec()])
     |> LiveSync.attach_editor([:memory, :ai, :prompts], &sync/2)}
  end

  defp assign_options(socket) do
    scope = socket.assigns.current_scope
    assign(socket, model_options: AI.model_options(scope), prompt_options: prompt_options(scope))
  end

  defp sync(socket, kinds) do
    scope = socket.assigns.current_scope
    socket = if Enum.any?([:ai, :prompts], &(&1 in kinds)), do: assign_options(socket), else: socket

    socket
    |> stream_profiles()
    |> LiveSync.sync_open(:editing_profile,
      fetch: &Memory.get_editable_profile(scope, &1),
      clean?: LiveSync.clean?(socket.assigns.form),
      reload: &assign(&1, form: to_form(Memory.change_profile(&2)), editing_profile: &2),
      gone: ~p"/memory/profiles",
      gone_message:
        (
          gettext_comment(
            "Flash shown when the memory profile open in the editor was deleted or moved by someone else."
          )

          dgettext("memory", "The memory profile was deleted or moved elsewhere.")
        )
    )
  end

  # Each prompt select lists only prompts of its purpose; a purpose several fields share is read once.
  defp prompt_options(scope) do
    purposes = Profile.prompt_purposes()

    by_purpose =
      purposes
      |> Keyword.values()
      |> Enum.uniq()
      |> Map.new(fn purpose -> {purpose, Enum.map(Prompts.list_prompts(scope, purpose), &{&1.name, &1.id})} end)

    Map.new(purposes, fn {field, purpose} -> {field, Map.fetch!(by_purpose, purpose)} end)
  end

  # The prompt selects in form order: field, label, blank choice, input id.
  defp prompt_fields do
    none = dpgettext("memory", "option: no prompt picked for this memory profile job", "None")

    [
      {:memory_prompt_id, dpgettext("memory", "field label: memory profile prompt", "Memory prompt"), none,
       "memory-profile-form-memory-prompt"},
      {:group_memory_prompt_id, dpgettext("memory", "field label: memory profile prompt", "Group memory prompt"),
       dpgettext("memory", "option: group chats use the memory prompt", "Same as memory prompt"),
       "memory-profile-form-group-memory-prompt"},
      {:consolidation_prompt_id, dpgettext("memory", "field label: memory profile prompt", "Consolidation prompt"),
       none, "memory-profile-form-consolidation-prompt"},
      {:compaction_prompt_id, dpgettext("memory", "field label: memory profile prompt", "Compaction prompt"), none,
       "memory-profile-form-compaction-prompt"},
      {:topical_clip_prompt_id, dpgettext("memory", "field label: memory profile prompt", "Topical clip prompt"), none,
       "memory-profile-form-topical-clip-prompt"},
      {:character_memory_prompt_id,
       dpgettext("memory", "field label: memory profile prompt", "Character memory prompt"), none,
       "memory-profile-form-character-memory-prompt"},
      {:clip_review_prompt_id, dpgettext("memory", "field label: memory profile prompt", "Memory assistance prompt"),
       none, "memory-profile-form-clip-review-prompt"},
      {:clip_suggestions_prompt_id,
       dpgettext("memory", "field label: memory profile prompt", "Topic suggestions prompt"), none,
       "memory-profile-form-clip-suggestions-prompt"},
      {:combine_clips_prompt_id, dpgettext("memory", "field label: memory profile prompt", "Combine clips prompt"),
       none, "memory-profile-form-combine-clips-prompt"}
    ]
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(form: nil, editing_profile: nil, selected_id: nil, kept_options: %{})
    |> stream_profiles()
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(
      form: to_form(Memory.change_profile(%Profile{})),
      editing_profile: nil,
      new_owner: "personal",
      selected_id: nil,
      kept_options: %{}
    )
    |> stream_profiles()
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    edit(socket, Memory.get_editable_profile(socket.assigns.current_scope, id))
  end

  defp edit(socket, nil) do
    socket
    |> put_flash(:error, profile_not_found_flash())
    |> push_patch(to: ~p"/memory/profiles")
  end

  defp edit(socket, profile) do
    socket
    |> assign(form: to_form(Memory.change_profile(profile)), editing_profile: profile, selected_id: profile.id)
    |> assign(kept_options: kept_options(socket, profile))
    |> stream_profiles()
  end

  # Saved references the selects would not list (rows of a shared profile's owner the editor cannot
  # see), offered by name so saving does not silently clear them.
  defp kept_options(socket, profile) do
    %{model_options: models, prompt_options: prompts} = socket.assigns
    prompt_refs = Enum.map(Profile.prompt_purposes(), fn {field, _} -> {field, Prompt, prompts[field]} end)
    ReferenceOptions.kept(profile, [{:ai_model_id, AI.Model, models} | prompt_refs])
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, socket |> assign_filter(params) |> stream_profiles()}
  end

  def handle_event("validate", %{"profile" => params} = all, socket) do
    changeset =
      socket
      |> target_profile()
      |> Memory.change_profile(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset), new_owner: OwnerSelect.choice(all))}
  end

  def handle_event("save", %{"profile" => params} = all, socket) do
    result =
      case socket.assigns.editing_profile do
        nil ->
          Memory.create_profile(socket.assigns.current_scope, params, OwnerSelect.create_opts(OwnerSelect.choice(all)))

        profile ->
          Memory.update_profile(socket.assigns.current_scope, profile, params)
      end

    case result do
      {:ok, profile} ->
        {:noreply,
         socket
         |> put_flash(:info, saved_flash(profile.name))
         |> push_patch(to: ~p"/memory/profiles/#{profile.id}/edit")}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(:error, save_failed_flash())}
    end
  end

  def handle_event("set_default", _params, %{assigns: %{editing_profile: %Profile{} = profile}} = socket) do
    {:ok, profile} = Memory.set_default_profile(socket.assigns.current_scope, profile)

    {:noreply,
     socket
     |> assign(editing_profile: profile)
     |> put_flash(:info, default_flash(profile.name))
     |> stream_profiles()}
  end

  def handle_event("delete", _params, %{assigns: %{editing_profile: %Profile{} = profile}} = socket) do
    result = Memory.delete_profile(socket.assigns.current_scope, profile)
    {:noreply, MythweaverWeb.HandOff.after_delete(socket, result, profile.name, ~p"/memory/profiles")}
  end

  defp target_profile(socket), do: socket.assigns.editing_profile || %Profile{}

  defp stream_profiles(socket) do
    stream_search(socket, :memory_profiles, Memory.list_profiles(socket.assigns.current_scope), &[&1.name])
  end

  defp bulk_spec do
    %Spec{
      name: :memory_profiles,
      count_label:
        &dpngettext(
          "memory",
          "count phrase: memory profiles affected by a bulk action",
          "%{profile_count} profile",
          "%{profile_count} profiles",
          &1,
          profile_count: Mythweaver.Format.number(&1)
        ),
      ids: & &1.assigns.memory_profiles_ids,
      get: &Memory.get_editable_profile/2,
      update: &Memory.update_profile/3,
      delete: &Memory.delete_profile/2,
      title: & &1.name,
      refresh: &stream_profiles/1,
      open_id: & &1.assigns.selected_id,
      index_path: ~p"/memory/profiles",
      edit_path: &~p"/memory/profiles/#{&1}/edit",
      fields: [
        %Field{
          key: :ai_model_id,
          label: dpgettext("memory", "field label: model a memory profile uses", "Model"),
          type: :select,
          options: &AI.model_options/1,
          prompt: dpgettext("memory", "option: memory profile uses the chat's model", "Chat model")
        },
        %Field{
          key: :max_tokens,
          label: dpgettext("memory", "field label: most tokens a memory response may use", "Max tokens"),
          type: :number,
          min: 0
        },
        %Field{
          key: :structured_output,
          label: dpgettext("memory", "toggle: ask the model for JSON", "Request structured JSON output")
        },
        %Field{
          key: :activation,
          label: field_label(:activation),
          type: :select,
          options: Field.enum_options(Profile, :activation)
        },
        %Field{
          key: :outlet,
          label: field_label(:outlet),
          type: :select,
          options: Field.enum_options(Profile, :outlet, [:custom])
        },
        %Field{
          key: :placement,
          label: field_label(:placement),
          type: :select,
          options: Field.enum_options(Profile, :placement)
        },
        %Field{
          key: :depth,
          label: dpgettext("memory", "field label: depth a memory entry is inserted at", "Depth"),
          type: :number,
          min: 0
        },
        %Field{
          key: :order_mode,
          label: dpgettext("memory", "field label: how memory entries are ordered", "Order"),
          type: :select,
          options: order_mode_options()
        },
        %Field{
          key: :prevent_recursion,
          label: dpgettext("memory", "toggle: memory entry", "Prevent recursion")
        },
        %Field{
          key: :exclude_recursion,
          label: dpgettext("memory", "toggle: memory entry", "Exclude from recursion")
        },
        %Field{
          key: :character_aware,
          label: dgettext("memory", "Limit each memory to the characters who spoke in it")
        }
      ]
    }
  end

  defp enum_options(field), do: EnumLabels.values(Profile, field)

  defp order_mode_options do
    [
      {dpgettext("memory", "option: how memory entries are ordered", "By sequence"), :auto},
      {dpgettext("memory", "option: how memory entries are ordered", "Fixed"), :manual}
    ]
  end

  defp profile_not_found_flash do
    gettext_comment("Flash when the memory profile being opened no longer exists or is not editable.")
    dpgettext("memory", "status: memory profile was not found", "Profile not found")
  end

  defp saved_flash(name) do
    gettext_comment("Flash after a memory profile was saved.")
    dpgettext("memory", "status: a memory profile was saved", "%{profile_name} saved", profile_name: name)
  end

  defp save_failed_flash do
    gettext_comment("Flash when saving an editor form fails validation; the invalid fields are highlighted.")
    dgettext("memory", "Could not save — see the highlighted fields")
  end

  defp default_flash(name) do
    gettext_comment("Flash after a memory profile was made the default.")
    dgettext("memory", "%{profile_name} is now the default", profile_name: name)
  end

  defp delete_confirm(name) do
    gettext_comment("Confirm dialog before deleting a memory profile.")

    dpgettext(
      "memory",
      "heading: confirm dialog before deleting a memory profile",
      "Delete %{profile_name}?",
      profile_name: name
    )
  end

  defp field_label(:activation), do: dpgettext("memory", "field label: how memory entries are activated", "Activation")
  defp field_label(:outlet), do: dpgettext("memory", "field label: where memory entries are inserted", "Outlet")

  defp field_label(:placement),
    do: dpgettext("memory", "field label: memory entry placement around its outlet", "Placement")

  defp title_format_help do
    gettext_comment(
      "Every placeholder is a code snippet shown as code: %{title_tag} and %{tier_tag} are literal template tags, the others example number tokens. %{tier_examples} are literal tier tokens, left untranslated."
    )

    rich(
      dgettext(
        "memory",
        "The first number token (%{bracket_number}, %{tier_number}, %{paren_number}, %{brace_number}, %{hash_number} or a bare %{bare_number}) takes the entry's number. %{title_tag} is the title the model wrote; %{tier_tag} is a consolidation's type (%{tier_examples}).",
        bracket_number: code("[000]"),
        tier_number: code("[ARC 000]"),
        paren_number: code("(000)"),
        brace_number: code("{000}"),
        hash_number: code("#000"),
        bare_number: code("000"),
        title_tag: code("{{title}}"),
        tier_tag: code("{{tier}}"),
        tier_examples: "ARC, CHAPTER, BOOK…"
      )
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      div.memory-profile-editor-body:scope {
        display: contents;
      }

      .memory-profile-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .memory-profile-form label {
        display: block;
      }

      .memory-profile-row {
        display: flex;
        flex-wrap: wrap;
        gap: var(--size-2);
        align-items: flex-end;
      }

      .memory-profile-help {
        margin: 0;
        color: var(--muted-foreground);
        font-size: 0.85rem;
      }
    </style>

    <Layouts.app flash={@flash} current_scope={@current_scope} search={:memory}>
      <.pane_layout>
        <:list
          id="memory-profiles-nav"
          label={dpgettext("memory", "aria label: list of memory profiles", "Memory profiles")}
        >
          <.pane_header title={dpgettext("memory", "heading: memory section", "Memory")}>
            <:switch navigate={~p"/memory/side-prompts"} id="memory-side-prompts-link">
              {dpgettext("memory", "link: memory section side prompts page", "Side prompts")}
            </:switch>
            <:switch navigate={~p"/settings/memory"} id="memory-settings-link">
              {dpgettext("memory", "link: memory settings page", "Settings")}
            </:switch>
          </.pane_header>
          <.pane_actions>
            <.button variant="primary" patch={~p"/memory/profiles/new"} id="new-memory-profile">
              <.lucide name="plus" />
              {dpgettext("memory", "button: create a memory profile", "New profile")}
            </.button>
            <.bulk_toggle bulk={@bulk} id="memory-profiles-bulk-toggle" />
          </.pane_actions>
          <.bulk_bar bulk={@bulk} id="memory-profiles-bulk" />
          <.pane_search
            id="memory-profile-filter"
            form={@filter_form}
            placeholder={dpgettext("memory", "placeholder: search memory profiles by name", "Name")}
          />
          <.pane_items
            :let={profile}
            bulk={@bulk}
            bulk_list="memory_profiles"
            id="memory-profiles"
            rows={@streams.memory_profiles}
            empty?={@memory_profiles_empty?}
            empty={
              if @query == "",
                do:
                  dpgettext(
                    "memory",
                    "empty state: user has no memory profiles",
                    "No memory profiles yet"
                  ),
                else:
                  dpgettext(
                    "memory",
                    "empty state: no memory profiles match the search",
                    "No profiles match this search"
                  )
            }
            selected_id={@selected_id}
            patch={fn profile -> ~p"/memory/profiles/#{profile.id}/edit" end}
          >
            <span class="pane-item-name">{profile.name}</span>
            <span :if={profile.default} class="pane-item-badges">
              <.badge>{dpgettext("memory", "badge: the default memory profile", "Default")}</.badge>
            </span>
          </.pane_items>
        </:list>
        <:editor id="memory-profile-editor">
          <.pane_placeholder :if={@live_action == :index} id="memory-profile-placeholder">
            {dgettext("memory", "Select a memory profile, or create a new one.")}
          </.pane_placeholder>
          <div :if={@live_action != :index} class="memory-profile-editor-body">
            <.panel_header sticky>
              {if @editing_profile,
                do: @editing_profile.name,
                else: dpgettext("memory", "heading: memory profile being created", "New profile")}
              <:actions :if={@editing_profile}>
                <.pane_export
                  id="export-memory-profile"
                  kind={:memory_profile}
                  item={@editing_profile}
                  current_scope={@current_scope}
                />
                <.button
                  :if={!@editing_profile.default}
                  size="sm"
                  id="memory-profile-default"
                  phx-click="set_default"
                >
                  <.lucide name="star" />
                  {dpgettext("memory", "button: make this the default memory profile", "Make default")}
                </.button>
                <.live_component
                  :if={Ownership.deletable?(@current_scope, @editing_profile)}
                  module={MythweaverWeb.HandOff}
                  id="memory-profile-handoff"
                  thing="memory-profile"
                  current_scope={@current_scope}
                  item={@editing_profile}
                  delete={&Memory.delete_profile/3}
                  index={~p"/memory/profiles"}
                  delete_id="delete-memory-profile"
                  confirm={delete_confirm(@editing_profile.name)}
                />
              </:actions>
            </.panel_header>
            <.live_component
              :if={@editing_profile}
              module={MythweaverWeb.Lineage}
              id="memory-profile-lineage-line"
              thing="memory-profile"
              current_scope={@current_scope}
              item={@editing_profile}
            />

            <.pane_section>
              <.changed_elsewhere
                :if={@changed_elsewhere?}
                id="memory-profile-changed-elsewhere"
                patch={@live_sync_path}
              />
              <.form
                for={@form}
                id="memory-profile-form"
                class="memory-profile-form"
                phx-hook="UnsavedChanges"
                data-saved={is_nil(@form.action)}
                phx-change="validate"
                phx-submit="save"
              >
                <.owner_select
                  :if={is_nil(@editing_profile)}
                  id="memory-profile-form-owner"
                  scope={@current_scope}
                  schema={Profile}
                  value={@new_owner}
                />
                <.input
                  field={@form[:name]}
                  type="text"
                  label={dpgettext("memory", "field label: name of a memory profile", "Name")}
                  id="memory-profile-form-name"
                  required
                />
                <.input
                  field={@form[:ai_model_id]}
                  type="select"
                  label={dpgettext("memory", "field label: model a memory profile uses", "Model")}
                  prompt={
                    dpgettext("memory", "option: memory profile uses the chat's model", "Chat model")
                  }
                  options={ReferenceOptions.with_kept(@model_options, @kept_options[:ai_model_id])}
                  id="memory-profile-form-model"
                />
                <.input
                  :for={{field, label, prompt, id} <- prompt_fields()}
                  field={@form[field]}
                  type="select"
                  label={label}
                  prompt={prompt}
                  options={ReferenceOptions.with_kept(@prompt_options[field], @kept_options[field])}
                  id={id}
                />
                <div class="memory-profile-row">
                  <.input
                    field={@form[:temperature]}
                    type="number"
                    step="0.05"
                    label={
                      dpgettext(
                        "memory",
                        "field label: memory profile temperature, blank uses the model's",
                        "Temperature (blank: model's)"
                      )
                    }
                    id="memory-profile-form-temperature"
                  />
                  <.input
                    field={@form[:max_tokens]}
                    type="number"
                    min="0"
                    label={
                      dpgettext(
                        "memory",
                        "field label: most tokens a memory response may use",
                        "Max tokens"
                      )
                    }
                    id="memory-profile-form-max-tokens"
                    aria-describedby="memory-profile-form-max-tokens-help"
                  />
                </div>
                <p id="memory-profile-form-max-tokens-help" class="memory-profile-help">
                  {dgettext(
                    "memory",
                    "Most tokens a memory response may use; 0 uses the model's own response limit."
                  )}
                </p>
                <.input
                  field={@form[:structured_output]}
                  type="checkbox"
                  label={
                    dpgettext(
                      "memory",
                      "toggle: ask the model for JSON",
                      "Request structured JSON output"
                    )
                  }
                  id="memory-profile-form-structured"
                />
                <div class="memory-profile-row">
                  <.input
                    field={@form[:title_format]}
                    type="text"
                    label={
                      dpgettext(
                        "memory",
                        "field label: title format of memory entries",
                        "Title format"
                      )
                    }
                    id="memory-profile-form-title-format"
                  />
                  <.input
                    field={@form[:consolidation_title_format]}
                    type="text"
                    label={
                      dpgettext(
                        "memory",
                        "field label: title format of consolidated entries",
                        "Consolidation title format"
                      )
                    }
                    id="memory-profile-form-consolidation-title-format"
                  />
                </div>
                <p class="memory-profile-help">
                  {title_format_help()}
                </p>
                <div class="memory-profile-row">
                  <.input
                    field={@form[:activation]}
                    type="select"
                    label={field_label(:activation)}
                    options={enum_options(:activation)}
                    id="memory-profile-form-activation"
                  />
                  <.input
                    field={@form[:outlet]}
                    type="select"
                    label={field_label(:outlet)}
                    options={enum_options(:outlet)}
                    id="memory-profile-form-outlet"
                  />
                  <.input
                    field={@form[:placement]}
                    type="select"
                    label={field_label(:placement)}
                    options={enum_options(:placement)}
                    id="memory-profile-form-placement"
                  />
                </div>
                <div class="memory-profile-row">
                  <.input
                    field={@form[:custom_outlet]}
                    type="text"
                    label={
                      dpgettext(
                        "memory",
                        "field label: custom outlet name of memory entries",
                        "Custom outlet"
                      )
                    }
                    id="memory-profile-form-custom-outlet"
                  />
                  <.input
                    field={@form[:depth]}
                    type="number"
                    label={
                      dpgettext("memory", "field label: depth a memory entry is inserted at", "Depth")
                    }
                    id="memory-profile-form-depth"
                  />
                </div>
                <div class="memory-profile-row">
                  <.input
                    field={@form[:order_mode]}
                    type="select"
                    label={
                      dpgettext("memory", "field label: how memory entries are ordered", "Order")
                    }
                    options={order_mode_options()}
                    id="memory-profile-form-order-mode"
                  />
                  <.input
                    field={@form[:order]}
                    type="number"
                    label={
                      dpgettext("memory", "field label: fixed order of memory entries", "Fixed order")
                    }
                    id="memory-profile-form-order"
                  />
                </div>
                <.input
                  field={@form[:prevent_recursion]}
                  type="checkbox"
                  label={dpgettext("memory", "toggle: memory entry", "Prevent recursion")}
                  id="memory-profile-form-prevent-recursion"
                />
                <.input
                  field={@form[:exclude_recursion]}
                  type="checkbox"
                  label={dpgettext("memory", "toggle: memory entry", "Exclude from recursion")}
                  id="memory-profile-form-exclude-recursion"
                />
                <.input
                  field={@form[:character_aware]}
                  type="checkbox"
                  label={dgettext("memory", "Limit each memory to the characters who spoke in it")}
                  id="memory-profile-form-character-aware"
                />
                <.form_actions>
                  <.button patch={
                    if @editing_profile,
                      do: ~p"/memory/profiles/#{@editing_profile.id}/edit",
                      else: ~p"/memory/profiles"
                  }>
                    {dpgettext("memory", "button: cancel editing a memory profile", "Cancel")}
                  </.button>
                  <.button type="submit" variant="primary">
                    {dpgettext("memory", "button: save a memory profile", "Save")}
                  </.button>
                </.form_actions>
              </.form>
            </.pane_section>
            <.live_component
              :if={@editing_profile}
              module={MythweaverWeb.SharePanel}
              id="memory-profile-share"
              current_scope={@current_scope}
              item={@editing_profile}
            />
          </div>
        </:editor>
      </.pane_layout>
    </Layouts.app>
    """
  end
end
