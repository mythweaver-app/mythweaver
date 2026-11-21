defmodule MythweaverWeb.SidePromptLive do
  @moduledoc """
  Side prompt manager: the side prompt list on the left, the selected side prompt's form on the
  right. A side prompt is a `:side_prompt`-purpose prompt plus when it runs (after each memory,
  every N messages, or by hand from the chat's memory panel) and the lore entry it maintains.
  `:index` selects nothing: the editor pane shows a placeholder until a side prompt is picked.

  Open to anyone `MythweaverWeb.ContentAccess` admits: the list holds side prompts the scope may edit
  (`Mythweaver.Ownership`), and the book and profile pickers those it may use.
  """
  use MythweaverWeb, :live_view

  import MythweaverWeb.BulkComponents
  import MythweaverWeb.Pane

  alias Mythweaver.Lore
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Memory
  alias Mythweaver.Memory.SidePrompt
  alias Mythweaver.Ownership
  alias Mythweaver.Prompts
  alias Mythweaver.Prompts.Prompt
  alias MythweaverWeb.Bulk
  alias MythweaverWeb.Bulk.Field
  alias MythweaverWeb.Bulk.Spec
  alias MythweaverWeb.CoreComponents.OwnerSelect
  alias MythweaverWeb.EnumLabels
  alias MythweaverWeb.JSONText
  alias MythweaverWeb.LiveSync
  alias MythweaverWeb.ReferenceOptions
  alias Phoenix.HTML.FormField

  on_mount {MythweaverWeb.ContentAccess, :memory}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: dpgettext("memory", "page title: list of side prompts", "Side prompts"),
       form: nil,
       editing_side_prompt: nil,
       new_owner: "personal",
       selected_id: nil,
       kept_options: %{}
     )
     |> assign_options()
     |> stream_configure(:side_prompts, dom_id: &"side-prompts-#{&1.id}")
     |> assign_filter()
     |> stream_side_prompts()
     |> Bulk.attach([bulk_spec()])
     |> LiveSync.attach_editor([:memory, :prompts, :lore], &sync/2)}
  end

  defp assign_options(socket) do
    scope = socket.assigns.current_scope

    assign(socket,
      prompt_options: Enum.map(Prompts.list_prompts(scope, :side_prompt), &{&1.name, &1.id}),
      book_options: Enum.map(Lore.list_usable_books(scope), &{&1.name, &1.id}),
      profile_options: Enum.map(Memory.list_usable_profiles(scope), &{&1.name, &1.id})
    )
  end

  defp sync(socket, _kinds) do
    scope = socket.assigns.current_scope

    socket
    |> assign_options()
    |> stream_side_prompts()
    |> LiveSync.sync_open(:editing_side_prompt,
      fetch: &Memory.get_editable_side_prompt(scope, &1),
      clean?: LiveSync.clean?(socket.assigns.form),
      reload: &assign(&1, form: to_form(Memory.change_side_prompt(&2)), editing_side_prompt: &2),
      gone: ~p"/memory/side-prompts",
      gone_message:
        (
          gettext_comment("Flash shown when the side prompt open in the editor was deleted or moved by someone else.")
          dgettext("memory", "The side prompt was deleted or moved elsewhere.")
        )
    )
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(form: nil, editing_side_prompt: nil, selected_id: nil, kept_options: %{})
    |> stream_side_prompts()
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(
      form: to_form(Memory.change_side_prompt(%SidePrompt{})),
      editing_side_prompt: nil,
      new_owner: "personal",
      selected_id: nil,
      kept_options: %{}
    )
    |> stream_side_prompts()
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    edit(socket, Memory.get_editable_side_prompt(socket.assigns.current_scope, id))
  end

  defp edit(socket, nil) do
    socket
    |> put_flash(:error, not_found_flash())
    |> push_patch(to: ~p"/memory/side-prompts")
  end

  defp edit(socket, side_prompt) do
    socket
    |> assign(
      form: to_form(Memory.change_side_prompt(side_prompt)),
      editing_side_prompt: side_prompt,
      selected_id: side_prompt.id,
      kept_options: kept_options(socket, side_prompt)
    )
    |> stream_side_prompts()
  end

  # Saved references the selects would not list (rows of a shared side prompt's owner the editor
  # cannot see), offered by name so saving does not silently clear them.
  defp kept_options(socket, side_prompt) do
    %{prompt_options: prompts, book_options: books, profile_options: profiles} = socket.assigns

    ReferenceOptions.kept(side_prompt, [
      {:prompt_id, Prompt, prompts},
      {:target_book_id, LoreBook, books},
      {:profile_id, Memory.Profile, profiles}
    ])
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, socket |> assign_filter(params) |> stream_side_prompts()}
  end

  def handle_event("validate", %{"side_prompt" => params} = all, socket) do
    changeset =
      socket
      |> target_side_prompt()
      |> Memory.change_side_prompt(attrs(params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset), new_owner: OwnerSelect.choice(all))}
  end

  def handle_event("save", %{"side_prompt" => params} = all, socket) do
    result =
      case socket.assigns.editing_side_prompt do
        nil ->
          Memory.create_side_prompt(
            socket.assigns.current_scope,
            attrs(params),
            OwnerSelect.create_opts(OwnerSelect.choice(all))
          )

        side_prompt ->
          Memory.update_side_prompt(socket.assigns.current_scope, side_prompt, attrs(params))
      end

    case result do
      {:ok, side_prompt} ->
        {:noreply,
         socket
         |> put_flash(:info, saved_flash(side_prompt.name))
         |> push_patch(to: ~p"/memory/side-prompts/#{side_prompt.id}/edit")}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(:error, save_failed_flash())}
    end
  end

  def handle_event("delete", _params, %{assigns: %{editing_side_prompt: %SidePrompt{} = side_prompt}} = socket) do
    result = Memory.delete_side_prompt(socket.assigns.current_scope, side_prompt)
    {:noreply, MythweaverWeb.HandOff.after_delete(socket, result, side_prompt.name, ~p"/memory/side-prompts")}
  end

  # Macros are typed comma-separated; keywords arrive as a chip list, which the changeset trims.
  defp attrs(params), do: Map.replace_lazy(params, "macros", &JSONText.split_list/1)

  defp target_side_prompt(socket), do: socket.assigns.editing_side_prompt || %SidePrompt{}

  defp stream_side_prompts(socket) do
    stream_search(socket, :side_prompts, Memory.list_side_prompts(socket.assigns.current_scope), &[&1.name])
  end

  defp bulk_spec do
    %Spec{
      name: :side_prompts,
      count_label:
        &dpngettext(
          "memory",
          "count phrase: side prompts affected by a bulk action",
          "%{side_prompt_count} side prompt",
          "%{side_prompt_count} side prompts",
          &1,
          side_prompt_count: Mythweaver.Format.number(&1)
        ),
      ids: & &1.assigns.side_prompts_ids,
      get: &Memory.get_editable_side_prompt/2,
      update: &Memory.update_side_prompt/3,
      delete: &Memory.delete_side_prompt/2,
      title: & &1.name,
      refresh: &stream_side_prompts/1,
      open_id: & &1.assigns.selected_id,
      index_path: ~p"/memory/side-prompts",
      edit_path: &~p"/memory/side-prompts/#{&1}/edit",
      fields: [
        %Field{key: :enabled, label: enabled_label()},
        %Field{key: :run_after_memory, label: run_after_memory_label()},
        %Field{key: :run_on_interval, label: run_on_interval_label()},
        %Field{key: :interval, label: interval_label(), type: :number, min: 1},
        %Field{key: :previous_memories, label: previous_memories_label(), type: :number, min: 0, max: 7},
        %Field{
          key: :profile_id,
          label: profile_label(),
          type: :select,
          options: fn scope -> Enum.map(Memory.list_usable_profiles(scope), &{&1.name, &1.id}) end,
          prompt: profile_prompt()
        },
        %Field{key: :use_context, label: use_context_label()},
        %Field{
          key: :target_book_id,
          label: target_book_label(),
          type: :select,
          options: fn scope -> Enum.map(Lore.list_usable_books(scope), &{&1.name, &1.id}) end,
          prompt: target_book_prompt()
        },
        %Field{
          key: :activation,
          label: field_label(:activation),
          type: :select,
          options: Field.enum_options(SidePrompt, :activation)
        },
        %Field{
          key: :outlet,
          label: field_label(:outlet),
          type: :select,
          options: Field.enum_options(SidePrompt, :outlet, [:custom])
        },
        %Field{
          key: :placement,
          label: field_label(:placement),
          type: :select,
          options: Field.enum_options(SidePrompt, :placement)
        },
        %Field{key: :prevent_recursion, label: prevent_recursion_label()},
        %Field{key: :exclude_recursion, label: exclude_recursion_label()},
        %Field{key: :ignore_budget, label: ignore_budget_label()},
        %Field{key: :save_versions, label: save_versions_label()}
      ]
    }
  end

  defp enum_options(field), do: EnumLabels.values(SidePrompt, field)

  defp enabled_label, do: dpgettext("memory", "toggle: side prompt runs automatically", "Enabled")

  defp run_after_memory_label, do: dgettext("memory", "After each saved memory, over the memory's messages")

  defp run_on_interval_label, do: dpgettext("memory", "toggle: side prompt runs every few messages", "Every N messages")

  defp interval_label, do: dpgettext("memory", "field label: messages between side prompt runs", "Messages")

  defp previous_memories_label,
    do: dpgettext("memory", "field label: earlier memories a side prompt reads", "Previous memories")

  defp profile_label,
    do: dpgettext("memory", "field label: memory profile whose model a side prompt uses", "Profile (model)")

  defp profile_prompt,
    do: dpgettext("memory", "option: side prompt uses the chat's memory profile", "The chat's profile")

  defp use_context_label,
    do:
      dpgettext(
        "memory",
        "toggle: side prompt reads the chat's memory context entries",
        "Include the chat's Additional Context"
      )

  defp target_book_label, do: dpgettext("memory", "field label: lore book a side prompt saves to", "Lore book")

  defp target_book_prompt,
    do: dpgettext("memory", "option: side prompt saves to the chat's memory book", "The chat's memory book")

  defp field_label(:activation),
    do: dpgettext("memory", "field label: how a side prompt's entry is activated", "Activation")

  defp field_label(:outlet), do: dpgettext("memory", "field label: where a side prompt's entry is inserted", "Outlet")

  defp field_label(:placement),
    do: dpgettext("memory", "field label: side prompt entry placement around its outlet", "Placement")

  defp prevent_recursion_label, do: dpgettext("memory", "toggle: entry a side prompt writes", "Prevent recursion")

  defp exclude_recursion_label, do: dpgettext("memory", "toggle: entry a side prompt writes", "Exclude from recursion")

  defp ignore_budget_label, do: dpgettext("memory", "toggle: entry a side prompt writes", "Ignore the lore budget")

  defp save_versions_label, do: dgettext("memory", "Keep numbered versions (needs versioning on in Memory settings)")

  defp not_found_flash do
    gettext_comment("Flash when the side prompt being opened no longer exists or is not editable.")
    dpgettext("memory", "status: side prompt was not found", "Side prompt not found")
  end

  defp saved_flash(name) do
    gettext_comment("Flash after a side prompt was saved.")
    dpgettext("memory", "status: a side prompt was saved", "%{side_prompt_name} saved", side_prompt_name: name)
  end

  defp save_failed_flash do
    gettext_comment("Flash when saving an editor form fails validation; the invalid fields are highlighted.")
    dgettext("memory", "Could not save — see the highlighted fields")
  end

  defp delete_confirm(name) do
    gettext_comment("Confirm dialog before deleting a side prompt.")

    dpgettext(
      "memory",
      "heading: confirm dialog before deleting a side prompt",
      "Delete %{side_prompt_name}?",
      side_prompt_name: name
    )
  end

  defp macros_label do
    gettext_comment("%{macro_syntax} is the literal macro syntax {{ name }}, left untranslated.")

    dgettext("memory", "Runtime macros, comma separated, used as %{macro_syntax}", macro_syntax: "{{ name }}")
  end

  defp keywords_value(%FormField{value: keywords}) when is_list(keywords), do: Enum.join(keywords, ", ")
  defp keywords_value(%FormField{value: keywords}), do: keywords

  # The keyword chips: the changeset's list, which has dropped the chip input's empty sentinel.
  defp keyword_values(form), do: Ecto.Changeset.get_field(form.source, :keywords) || []

  @impl true
  def render(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      div.side-prompt-editor-body:scope {
        display: contents;
      }

      .side-prompt-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .side-prompt-form label {
        display: block;
      }

      .side-prompt-form h3 {
        margin: var(--size-2) 0 0;
        font-size: 0.95rem;
      }

      .side-prompt-row {
        display: flex;
        flex-wrap: wrap;
        gap: var(--size-2);
        align-items: flex-end;
      }
    </style>

    <Layouts.app flash={@flash} current_scope={@current_scope} search={:memory}>
      <.pane_layout>
        <:list
          id="side-prompts-nav"
          label={dpgettext("memory", "aria label: list of side prompts", "Side prompts")}
        >
          <.pane_header title={dpgettext("memory", "heading: side prompts page", "Side prompts")}>
            <:switch navigate={~p"/memory/profiles"} id="memory-profiles-link">
              {dpgettext("memory", "link: memory profiles page", "Profiles")}
            </:switch>
            <:switch navigate={~p"/memory/side-prompt-sets"} id="side-prompt-sets-link">
              {dpgettext("memory", "link: side prompt sets page", "Sets")}
            </:switch>
            <:switch navigate={~p"/settings/memory"} id="memory-settings-link">
              {dpgettext("memory", "link: memory settings page", "Settings")}
            </:switch>
          </.pane_header>
          <.pane_actions>
            <.button variant="primary" patch={~p"/memory/side-prompts/new"} id="new-side-prompt">
              <.lucide name="plus" />
              {dpgettext("memory", "button: create a side prompt", "New side prompt")}
            </.button>
            <.bulk_toggle bulk={@bulk} id="side-prompts-bulk-toggle" />
          </.pane_actions>
          <.bulk_bar bulk={@bulk} id="side-prompts-bulk" />
          <.pane_search
            id="side-prompt-filter"
            form={@filter_form}
            placeholder={dpgettext("memory", "placeholder: search side prompts by name", "Name")}
          />
          <.pane_items
            :let={side_prompt}
            bulk={@bulk}
            bulk_list="side_prompts"
            id="side-prompts"
            rows={@streams.side_prompts}
            empty?={@side_prompts_empty?}
            empty={
              if @query == "",
                do:
                  dpgettext("memory", "empty state: user has no side prompts", "No side prompts yet"),
                else:
                  dpgettext(
                    "memory",
                    "empty state: no side prompts match the search",
                    "No side prompts match this search"
                  )
            }
            selected_id={@selected_id}
            patch={fn side_prompt -> ~p"/memory/side-prompts/#{side_prompt.id}/edit" end}
          >
            <span class="pane-item-name">{side_prompt.name}</span>
            <span :if={!side_prompt.enabled} class="pane-item-badges">
              <.badge>{dpgettext("memory", "badge: side prompt is turned off", "Off")}</.badge>
            </span>
          </.pane_items>
        </:list>
        <:editor id="side-prompt-editor">
          <.pane_placeholder :if={@live_action == :index} id="side-prompt-placeholder">
            {dgettext("memory", "Select a side prompt, or create a new one.")}
          </.pane_placeholder>
          <div :if={@live_action != :index} class="side-prompt-editor-body">
            <.panel_header sticky>
              {if @editing_side_prompt,
                do: @editing_side_prompt.name,
                else: dpgettext("memory", "heading: side prompt being created", "New side prompt")}
              <:actions :if={@editing_side_prompt}>
                <.pane_export
                  id="export-side-prompt"
                  kind={:side_prompt}
                  item={@editing_side_prompt}
                  current_scope={@current_scope}
                />
                <.live_component
                  :if={Ownership.deletable?(@current_scope, @editing_side_prompt)}
                  module={MythweaverWeb.HandOff}
                  id="side-prompt-handoff"
                  thing="side-prompt"
                  current_scope={@current_scope}
                  item={@editing_side_prompt}
                  delete={&Memory.delete_side_prompt/3}
                  index={~p"/memory/side-prompts"}
                  delete_id="delete-side-prompt"
                  confirm={delete_confirm(@editing_side_prompt.name)}
                />
              </:actions>
            </.panel_header>
            <.live_component
              :if={@editing_side_prompt}
              module={MythweaverWeb.Lineage}
              id="side-prompt-lineage-line"
              thing="side-prompt"
              current_scope={@current_scope}
              item={@editing_side_prompt}
            />

            <.pane_section>
              <.changed_elsewhere
                :if={@changed_elsewhere?}
                id="side-prompt-changed-elsewhere"
                patch={@live_sync_path}
              />
              <.form
                for={@form}
                id="side-prompt-form"
                class="side-prompt-form"
                phx-hook="UnsavedChanges"
                data-saved={is_nil(@form.action)}
                phx-change="validate"
                phx-submit="save"
              >
                <.owner_select
                  :if={is_nil(@editing_side_prompt)}
                  id="side-prompt-form-owner"
                  scope={@current_scope}
                  schema={SidePrompt}
                  value={@new_owner}
                />
                <.input
                  field={@form[:name]}
                  type="text"
                  label={dpgettext("memory", "field label: name of a side prompt", "Name")}
                  id="side-prompt-form-name"
                  required
                />
                <.input
                  field={@form[:prompt_id]}
                  type="select"
                  label={dpgettext("memory", "field label: prompt a side prompt runs", "Prompt")}
                  prompt={dpgettext("memory", "option: no prompt picked yet", "Pick a prompt")}
                  options={ReferenceOptions.with_kept(@prompt_options, @kept_options[:prompt_id])}
                  id="side-prompt-form-prompt"
                />
                <.input
                  field={@form[:enabled]}
                  type="checkbox"
                  label={enabled_label()}
                  id="side-prompt-form-enabled"
                />
                <.input
                  field={@form[:macros]}
                  type="text"
                  value={keywords_value(@form[:macros])}
                  label={macros_label()}
                  id="side-prompt-form-macros"
                />

                <h3>{dpgettext("memory", "heading: when a side prompt runs", "When it runs")}</h3>
                <.input
                  field={@form[:run_after_memory]}
                  type="checkbox"
                  label={run_after_memory_label()}
                  id="side-prompt-form-after-memory"
                />
                <div class="side-prompt-row">
                  <.input
                    field={@form[:run_on_interval]}
                    type="checkbox"
                    label={run_on_interval_label()}
                    id="side-prompt-form-on-interval"
                  />
                  <.input
                    field={@form[:interval]}
                    type="number"
                    min="1"
                    label={interval_label()}
                    id="side-prompt-form-interval"
                  />
                </div>

                <h3>{dpgettext("memory", "heading: what a side prompt reads", "What it reads")}</h3>
                <div class="side-prompt-row">
                  <.input
                    field={@form[:previous_memories]}
                    type="number"
                    min="0"
                    max="7"
                    label={previous_memories_label()}
                    id="side-prompt-form-previous-memories"
                  />
                  <.input
                    field={@form[:profile_id]}
                    type="select"
                    label={profile_label()}
                    prompt={profile_prompt()}
                    options={ReferenceOptions.with_kept(@profile_options, @kept_options[:profile_id])}
                    id="side-prompt-form-profile"
                  />
                </div>
                <.input
                  field={@form[:use_context]}
                  type="checkbox"
                  label={use_context_label()}
                  id="side-prompt-form-use-context"
                />

                <h3>
                  {dpgettext(
                    "memory",
                    "heading: the entry a side prompt writes",
                    "The entry it writes"
                  )}
                </h3>
                <div class="side-prompt-row">
                  <.input
                    field={@form[:target_book_id]}
                    type="select"
                    label={target_book_label()}
                    prompt={target_book_prompt()}
                    options={
                      ReferenceOptions.with_kept(@book_options, @kept_options[:target_book_id])
                    }
                    id="side-prompt-form-target-book"
                  />
                  <.input
                    field={@form[:title]}
                    type="text"
                    label={
                      dpgettext(
                        "memory",
                        "field label: title of a side prompt's entry, blank uses the name",
                        "Entry title (blank: the name)"
                      )
                    }
                    id="side-prompt-form-title"
                  />
                </div>
                <.tag_input
                  id="side-prompt-form-keywords"
                  name="side_prompt[keywords][]"
                  mode="keywords"
                  label={
                    dpgettext("memory", "field label: keywords of a side prompt's entry", "Keywords")
                  }
                  placeholder={
                    dpgettext(
                      "memory",
                      "placeholder: keyword chip input",
                      "Type a keyword, then Enter or comma"
                    )
                  }
                  values={keyword_values(@form)}
                />
                <div class="side-prompt-row">
                  <.input
                    field={@form[:activation]}
                    type="select"
                    label={field_label(:activation)}
                    options={enum_options(:activation)}
                    id="side-prompt-form-activation"
                  />
                  <.input
                    field={@form[:outlet]}
                    type="select"
                    label={field_label(:outlet)}
                    options={enum_options(:outlet)}
                    id="side-prompt-form-outlet"
                  />
                  <.input
                    field={@form[:placement]}
                    type="select"
                    label={field_label(:placement)}
                    options={enum_options(:placement)}
                    id="side-prompt-form-placement"
                  />
                </div>
                <div class="side-prompt-row">
                  <.input
                    field={@form[:custom_outlet]}
                    type="text"
                    label={
                      dpgettext(
                        "memory",
                        "field label: custom outlet name of a side prompt's entry",
                        "Custom outlet"
                      )
                    }
                    id="side-prompt-form-custom-outlet"
                  />
                  <.input
                    field={@form[:depth]}
                    type="number"
                    label={
                      dpgettext(
                        "memory",
                        "field label: depth a side prompt's entry is inserted at",
                        "Depth"
                      )
                    }
                    id="side-prompt-form-depth"
                  />
                  <.input
                    field={@form[:order]}
                    type="number"
                    label={
                      dpgettext(
                        "memory",
                        "field label: insertion order of a side prompt's entry",
                        "Order"
                      )
                    }
                    id="side-prompt-form-order"
                  />
                </div>
                <.input
                  field={@form[:prevent_recursion]}
                  type="checkbox"
                  label={prevent_recursion_label()}
                  id="side-prompt-form-prevent-recursion"
                />
                <.input
                  field={@form[:exclude_recursion]}
                  type="checkbox"
                  label={exclude_recursion_label()}
                  id="side-prompt-form-exclude-recursion"
                />
                <.input
                  field={@form[:ignore_budget]}
                  type="checkbox"
                  label={ignore_budget_label()}
                  id="side-prompt-form-ignore-budget"
                />
                <.input
                  field={@form[:save_versions]}
                  type="checkbox"
                  label={save_versions_label()}
                  id="side-prompt-form-save-versions"
                />
                <.form_actions>
                  <.button patch={
                    if @editing_side_prompt,
                      do: ~p"/memory/side-prompts/#{@editing_side_prompt.id}/edit",
                      else: ~p"/memory/side-prompts"
                  }>
                    {dpgettext("memory", "button: cancel editing a side prompt", "Cancel")}
                  </.button>
                  <.button type="submit" variant="primary">
                    {dpgettext("memory", "button: save a side prompt", "Save")}
                  </.button>
                </.form_actions>
              </.form>
            </.pane_section>
            <.live_component
              :if={@editing_side_prompt}
              module={MythweaverWeb.SharePanel}
              id="side-prompt-share"
              current_scope={@current_scope}
              item={@editing_side_prompt}
            />
          </div>
        </:editor>
      </.pane_layout>
    </Layouts.app>
    """
  end
end
