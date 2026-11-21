defmodule MythweaverWeb.ScriptLive do
  @moduledoc """
  Lua script manager: the script list on the left, the selected script's form and run status on the
  right. Scripts are the site's or the user's own (`Mythweaver.Scripts`). The run status records only
  runs in chats of users who may edit the script, so a site script's status reflects admins' chats
  only and never another user's chat content. `:index` selects nothing: the editor pane shows a
  placeholder until a script is picked.

  The form checks the unsaved body as it changes (`Scripts.check/2`: a missing closing `return`
  warns at once; Validate also confirms a clean body), and the Test section runs it against sample
  text without changing any data (`Scripts.test_run/3`).
  """
  use MythweaverWeb, :live_view

  import MythweaverWeb.BulkComponents
  import MythweaverWeb.Pane
  import MythweaverWeb.TagFields
  import MythweaverWeb.TagFilter

  alias Mythweaver.Ownership
  alias Mythweaver.Scripts
  alias Mythweaver.Scripts.Script
  alias MythweaverWeb.Bulk
  alias MythweaverWeb.Bulk.Field
  alias MythweaverWeb.Bulk.Spec
  alias MythweaverWeb.CoreComponents.OwnerSelect
  alias MythweaverWeb.LiveSync

  on_mount {MythweaverWeb.ContentAccess, :scripts}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: dpgettext("scripts", "page title: list of Lua scripts", "Scripts"),
       form: nil,
       editing_script: nil,
       new_owner: "personal",
       selected_id: nil,
       dependency_options: [],
       check: %{errors: [], warnings: []},
       checked?: false,
       test_form: to_form(%{"text" => sample_text()}, as: :test),
       test_result: nil,
       testing?: false,
       trigger_names:
         Script.trigger_options()
         |> Map.new(fn {name, trigger} -> {trigger, name} end)
         |> Map.put(
           :inline,
           dpgettext("scripts", "heading: inline {! !} script blocks in a sent message", "Inline, in a sent message")
         ),
       common_event_fields: Scripts.common_event_fields(),
       event_reference: Scripts.event_reference()
     )
     |> stream_configure(:scripts, dom_id: &"scripts-#{&1.id}")
     |> assign_filter()
     |> assign_tag_filter()
     |> stream_scripts()
     |> Bulk.attach([bulk_spec()])
     |> LiveSync.attach_editor([:scripts, :tags], &sync/2)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(
      form: nil,
      editing_script: nil,
      selected_id: nil,
      dependency_options: [],
      check: %{errors: [], warnings: []},
      checked?: false,
      test_result: nil
    )
    |> stream_scripts()
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(editing_script: nil, selected_id: nil, new_owner: "personal")
    |> assign_form(Scripts.new_script(socket.assigns.current_scope))
    |> assign_tag_fields(:item, nil, OwnerSelect.tag_owner(socket.assigns.current_scope, Script, "personal"))
    |> stream_scripts()
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Scripts.get_script(socket.assigns.current_scope, id) do
      nil ->
        socket
        |> put_flash(:error, not_found_flash())
        |> push_patch(to: ~p"/scripts")

      script ->
        socket
        |> assign(editing_script: script, selected_id: script.id)
        |> assign_form(script)
        |> assign_tag_fields(:item, script, script.user_id)
        |> stream_scripts()
    end
  end

  defp assign_form(socket, script) do
    socket
    |> assign(
      form: to_form(Scripts.change_script(script)),
      dependency_options: Scripts.dependency_options(socket.assigns.current_scope, script, script.trigger),
      test_result: nil
    )
    |> assign_check(false)
  end

  # Warnings show as the body changes; `checked?` marks an explicit Validate, the only time "no
  # problems" is said. A blank body is not checked: every new script would open with a warning.
  defp assign_check(socket, checked?) do
    {body, trigger} = draft(socket)

    check =
      if String.trim(body) == "", do: %{errors: [], warnings: []}, else: Scripts.check(body, trigger)

    assign(socket, check: check, checked?: checked?)
  end

  # The body and trigger as last typed, saved or not.
  defp draft(socket) do
    changeset = socket.assigns.form.source
    {Ecto.Changeset.get_field(changeset, :body) || "", Ecto.Changeset.get_field(changeset, :trigger)}
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, socket |> assign_filter(params) |> assign_tag_filter(params) |> stream_scripts()}
  end

  def handle_event("validate", %{"script" => params} = all, socket) do
    socket = put_new_owner(socket, :editing_script, Script, OwnerSelect.choice(all))
    script = target_script(socket)
    changeset = script |> Scripts.change_script(params) |> Map.put(:action, :validate)
    trigger = Ecto.Changeset.get_field(changeset, :trigger)

    {:noreply,
     socket
     |> assign(
       form: to_form(changeset),
       dependency_options: Scripts.dependency_options(socket.assigns.current_scope, script, trigger)
     )
     |> assign_check(false)
     |> put_tag_params(:item, all["tags"])}
  end

  def handle_event("check_script", _params, socket) do
    {:noreply, assign_check(socket, true)}
  end

  def handle_event("test_change", %{"test" => params}, socket) do
    {:noreply, assign(socket, test_form: to_form(params, as: :test))}
  end

  # Async, so a slow script (up to the sandbox's wall-clock limit) leaves the page responsive.
  def handle_event("run_test", %{"test" => %{"text" => text} = params}, socket) do
    {body, trigger} = draft(socket)
    scope = socket.assigns.current_scope

    {:noreply,
     socket
     |> assign(test_form: to_form(params, as: :test), testing?: true)
     |> start_async(
       :test_run,
       Mythweaver.Locale.carry(fn ->
         Map.merge(Scripts.test_run(scope, body, trigger, text), %{input: text, trigger: trigger})
       end)
     )}
  end

  def handle_event("save", %{"script" => params} = all, socket) do
    socket = put_tag_params(socket, :item, all["tags"])

    result =
      case socket.assigns.editing_script do
        nil ->
          Scripts.create_script(socket.assigns.current_scope, params, OwnerSelect.create_opts(OwnerSelect.choice(all)))

        script ->
          Scripts.update_script(socket.assigns.current_scope, script, params)
      end

    case result do
      {:ok, script} ->
        socket =
          case save_tags(socket, :item, script) do
            {:ok, socket} -> put_flash(socket, :info, saved_flash(script.name))
            {:error, _what, socket} -> put_flash(socket, :error, tags_failed_flash(script.name))
          end

        {:noreply, push_patch(socket, to: ~p"/scripts/#{script.id}/edit")}

      {:error, :quota_exceeded} ->
        {:noreply, flash_quota(socket, "quota.scripts")}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(:error, save_failed_flash())}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Scripts.get_script(socket.assigns.current_scope, id) do
      nil ->
        {:noreply, socket}

      script ->
        result = Scripts.delete_script(socket.assigns.current_scope, script)
        {:noreply, MythweaverWeb.HandOff.after_delete(socket, result, script.name, ~p"/scripts")}
    end
  end

  # A run recorded its status, or a script or tag changed elsewhere.
  defp sync(socket, kinds) do
    scope = socket.assigns.current_scope
    socket = if :tags in kinds, do: refresh_graph(socket), else: socket

    socket
    |> stream_scripts()
    |> LiveSync.sync_open(:editing_script,
      fetch: &Scripts.get_script(scope, &1),
      clean?: LiveSync.clean?(socket.assigns.form),
      reload: &reload_script/2,
      gone: ~p"/scripts",
      gone_message:
        (
          gettext_comment("Flash shown when the script open in the editor was deleted or moved by someone else.")
          dgettext("scripts", "The script was deleted or moved elsewhere.")
        ),
      ignore: [:last_error, :last_error_at, :last_success_at],
      force: :tags in kinds
    )
  end

  # Not `assign_form/2`: it clears the test result.
  defp reload_script(socket, fresh) do
    socket
    |> assign(
      editing_script: fresh,
      form: to_form(Scripts.change_script(fresh)),
      dependency_options: Scripts.dependency_options(socket.assigns.current_scope, fresh, fresh.trigger)
    )
    |> assign_check(false)
    |> assign_tag_fields(:item, fresh, fresh.user_id)
  end

  @impl true
  def handle_async(:test_run, {:ok, result}, socket) do
    {:noreply, assign(socket, test_result: result, testing?: false)}
  end

  def handle_async(:test_run, {:exit, reason}, socket) do
    gettext_comment(
      "Shown as the test result when the script's test run process crashed; the reason is the raw Erlang exit reason."
    )

    error =
      dpgettext("scripts", "status: a script test run crashed", "Test crashed: %{exit_reason}",
        exit_reason: Exception.format_exit(reason)
      )

    result = %{result: {:error, error}, lines: [], input: nil, trigger: nil}
    {:noreply, assign(socket, test_result: result, testing?: false)}
  end

  defp target_script(socket),
    do:
      socket.assigns.editing_script ||
        Scripts.new_script(socket.assigns.current_scope, OwnerSelect.create_opts(socket.assigns.new_owner))

  defp bulk_spec do
    %Spec{
      name: :scripts,
      tag_kind: :script,
      count_label:
        &dpngettext(
          "scripts",
          "count phrase: Lua scripts affected by a bulk action",
          "%{script_count} script",
          "%{script_count} scripts",
          &1,
          script_count: Mythweaver.Format.number(&1)
        ),
      ids: & &1.assigns.scripts_ids,
      get: &Scripts.get_script/2,
      update: &Scripts.update_script/3,
      delete: &Scripts.delete_script/2,
      title: & &1.name,
      refresh: &stream_scripts/1,
      open_id: & &1.assigns.selected_id,
      index_path: ~p"/scripts",
      edit_path: &~p"/scripts/#{&1}/edit",
      fields: [
        %Field{key: :enabled, label: dpgettext("scripts", "toggle: Lua script runs on its trigger", "Enabled")},
        %Field{
          key: :priority,
          label: dpgettext("scripts", "field label: run order of a Lua script", "Priority"),
          type: :number,
          step: 1
        }
      ]
    }
  end

  defp stream_scripts(socket) do
    scripts = filter_tagged(socket, Scripts.list_scripts(socket.assigns.current_scope), :script)
    stream_search(socket, :scripts, scripts, &[&1.name, &1.description])
  end

  defp failing?(%Script{last_error_at: nil}), do: false
  defp failing?(%Script{last_success_at: nil}), do: true
  defp failing?(%Script{last_error_at: error, last_success_at: success}), do: DateTime.after?(error, success)

  defp current_trigger?(form, trigger), do: to_string(form[:trigger].value) == Atom.to_string(trigger)

  # A picker has no `field`, so this is `input/1`'s `used_input?` gate: no errors on a pristine form.
  defp picker_errors(form, name) do
    field = form[name]
    if used_input?(field), do: Enum.map(field.errors, &translate_error/1), else: []
  end

  # Lore scripts' return values are ignored, so only an error or a clean run matters; a command's
  # return is the notice it shows, and a quick reply's what happens to the composer.
  defp test_outcome(%{result: {:error, _}}), do: :failed
  defp test_outcome(%{trigger: :lore_activated}), do: :ignored
  defp test_outcome(%{trigger: :command, result: {:ok, notice}}) when notice in [nil, ""], do: :quiet
  defp test_outcome(%{trigger: :command}), do: :notice
  defp test_outcome(%{trigger: :quick_reply, result: {:ok, nil}}), do: :qr_none
  defp test_outcome(%{trigger: :quick_reply, result: {:ok, :clear}}), do: :qr_clear
  defp test_outcome(%{trigger: :quick_reply, result: {:ok, {:input, _}}}), do: :qr_input
  defp test_outcome(%{trigger: :quick_reply, result: {:ok, {:message, _}}}), do: :qr_message
  defp test_outcome(%{result: {:ok, text}, input: text}), do: :unchanged
  defp test_outcome(_result), do: :changed

  defp trigger_label(:ai_generation), do: dpgettext("scripts", "badge: script trigger, an AI reply", "AI reply")
  defp trigger_label(:user_message), do: dpgettext("scripts", "badge: script trigger, a user message", "User message")
  defp trigger_label(:lore_activated), do: dpgettext("scripts", "badge: script trigger, lore activated", "Lore")
  defp trigger_label(:image_described), do: dpgettext("scripts", "badge: script trigger, an image described", "Image")
  defp trigger_label(:command), do: dpgettext("scripts", "badge: script trigger, a palette command", "Command")

  defp trigger_label(:quick_reply),
    do: dpgettext("scripts", "badge: script trigger, a quick reply button", "Quick reply")

  defp sample_text do
    gettext_comment("Default sample text in the script test form; the asterisks mark a roleplay action.")
    dgettext("scripts", "Hello there! *waves* How are you today?")
  end

  defp not_found_flash do
    gettext_comment("Flash when the script in the address no longer exists or cannot be edited.")
    dpgettext("scripts", "status: flash, the Lua script to edit was not found", "Script not found")
  end

  defp saved_flash(script_name) do
    gettext_comment("Flash after a Lua script was saved.")
    dpgettext("scripts", "status: flash after a Lua script was saved", "%{script_name} saved", script_name: script_name)
  end

  defp tags_failed_flash(script_name) do
    gettext_comment("Flash when a Lua script was saved but writing its tags failed.")
    dgettext("scripts", "%{script_name} saved, but its tags did not", script_name: script_name)
  end

  defp save_failed_flash do
    gettext_comment("Flash when the Lua script form has errors.")
    dgettext("scripts", "Could not save — see the highlighted fields")
  end

  defp delete_confirm(script_name) do
    gettext_comment("Confirm dialog before deleting a Lua script.")

    dpgettext("scripts", "button: confirm dialog, delete a Lua script", "Delete %{script_name}?",
      script_name: script_name
    )
  end

  defp test_note do
    gettext_comment("Hint in the script test section. The placeholders are Lua code, shown as code and not translated.")

    rich(
      dgettext(
        "scripts",
        "Runs the script above, saved or not, with this text as %{event_text} and empty sample values for the other fields. Nothing is changed: %{mw_functions} functions that need a chat or change data return %{test_run_result}.",
        event_text: code("event.text"),
        mw_functions: code("mw.*"),
        test_run_result: code(~s(nil, "test_run"))
      )
    )
  end

  defp return_value_text(returns) do
    gettext_comment("Script reference: what a trigger's return value does. The second placeholder is that description.")

    rich(
      dpgettext(
        "scripts",
        "field label: what a script trigger's return value does",
        "%{return_value_label} %{return_description}",
        return_value_label:
          strong(dpgettext("scripts", "field label: script reference, return value of a trigger", "Return value:")),
        return_description: returns
      )
    )
  end

  @host_tables ~w(messages images generation memory characters prompts blocks lore vars globals injections commands roll)
  @regex_functions ~w(test match match_all replace split escape)

  defp host_functions_text do
    gettext_comment(
      "Script reference footer. %{host_tables} and %{regex_functions} are comma-separated lists of Lua function names, %{refusal} and %{print_function} are Lua code, %{replacement_syntax} is the literal replacement syntax; none are translated."
    )

    rich(
      dgettext(
        "scripts",
        "Host functions: %{host_tables}. A refusal returns %{refusal}; a wrong argument fails the script. Regular expressions (PCRE): %{regex_functions}. Flags: i m s x U. Replacement strings use %{replacement_syntax}. %{print_function} shows its arguments with the run's script errors.",
        host_tables: Enum.map_join(@host_tables, ", ", &code("mw." <> &1)),
        refusal: code("nil, reason"),
        regex_functions: Enum.map_join(@regex_functions, ", ", &code("regex." <> &1)),
        replacement_syntax: "$1, ${name}, $$",
        print_function: code("print(...)")
      )
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      /* The editor slot's root. `pane_layout`'s `<section>` carries no marker from this block, so
         without it `<.form>` (which carries none either) would sit outside this scope. */
      div.script-editor-body:scope {
        display: contents;
      }

      span.script-disabled:scope {
        color: var(--muted-foreground);
      }

      .script-failed {
        color: var(--destructive);
      }

      .script-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .script-form label {
        display: block;
      }

      .script-reference summary,
      .script-test summary {
        cursor: pointer;
        font-weight: 600;
      }

      .script-reference p,
      .script-reference h4,
      .script-reference dt,
      .script-reference dd {
        margin: 0;
      }

      .script-reference > * + *,
      .script-test > * + * {
        margin-block-start: var(--size-2);
      }

      .script-reference dl {
        display: grid;
        gap: var(--size-1);
        margin: 0;
      }

      .script-reference dd {
        color: var(--muted-foreground);
        font-size: 0.85rem;
      }

      .script-reference-type {
        margin-inline-start: var(--size-2);
        color: var(--muted-foreground);
        font-family: var(--font-monospace-code, ui-monospace, monospace);
        font-size: 0.85rem;
      }

      .script-reference-trigger {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
        padding: var(--size-2) var(--size-3);
        border-inline-start: 2px solid var(--border);
      }

      .script-reference-trigger.current {
        border-inline-start-color: var(--primary-accent);
      }

      .script-reference-trigger h4 {
        display: flex;
        align-items: center;
        gap: var(--size-2);
      }

      .script-reference pre {
        margin: 0;
        padding: var(--size-2);
        background: var(--surface-1);
        border-radius: var(--radius-2);
        white-space: pre-wrap;
      }

      .script-status p {
        margin: 0;
      }

      .script-status pre {
        white-space: pre-wrap;
        color: var(--destructive);
        background: var(--surface-1);
        padding: var(--size-2);
        border-radius: var(--radius-2);
      }

      .script-check,
      .script-test-result {
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
      }

      .script-check p,
      .script-test-result p,
      .script-test-note {
        display: flex;
        align-items: baseline;
        gap: var(--size-2);
        margin: 0;
      }

      .script-test-note {
        display: block;
        color: var(--muted-foreground);
      }

      .script-check-error {
        color: var(--destructive);
      }

      .script-check-warning .iconex,
      .script-check-ok .iconex {
        flex: none;
        color: var(--primary-accent);
      }

      .script-test-result pre {
        margin: 0;
        white-space: pre-wrap;
        background: var(--surface-1);
        padding: var(--size-2);
        border-radius: var(--radius-2);
      }

      .script-test-result pre.script-test-error {
        color: var(--destructive);
      }
    </style>

    <Layouts.app flash={@flash} current_scope={@current_scope} search={:scripts}>
      <.pane_layout>
        <:list
          id="scripts-nav"
          label={dpgettext("scripts", "aria label: list of Lua scripts", "Scripts")}
        >
          <.pane_header title={dpgettext("scripts", "heading: list of Lua scripts", "Scripts")} />
          <.pane_actions>
            <.button variant="primary" patch={~p"/scripts/new"} id="new-script">
              <.lucide name="plus" /> {dpgettext(
                "scripts",
                "button: create a Lua script",
                "New script"
              )}
            </.button>
            <.bulk_toggle bulk={@bulk} id="scripts-bulk-toggle" />
          </.pane_actions>
          <.bulk_bar bulk={@bulk} id="scripts-bulk" />
          <.pane_search
            id="script-filter"
            form={@filter_form}
            placeholder={
              dpgettext("scripts", "placeholder: search Lua scripts", "Name or description")
            }
          >
            <.tag_filter
              id="script-filter-tags"
              values={@tag_filter}
              vocabulary={@tag_vocabulary}
              errors={@tag_filter_errors}
              invalid={@tag_filter_invalid}
            />
          </.pane_search>
          <.pane_items
            :let={script}
            bulk={@bulk}
            bulk_list="scripts"
            id="scripts"
            rows={@streams.scripts}
            empty?={@scripts_empty?}
            empty={
              if @query == "" and @tag_filter == [],
                do: dpgettext("scripts", "empty state: no Lua scripts exist", "No scripts yet"),
                else:
                  dpgettext(
                    "scripts",
                    "empty state: no Lua scripts match the search",
                    "No scripts match this search"
                  )
            }
            selected_id={@selected_id}
            patch={fn script -> ~p"/scripts/#{script.id}/edit" end}
          >
            <span class={["pane-item-name", !script.enabled && "script-disabled"]}>{script.name}</span>
            <span class="pane-item-badges">
              <.badge>{trigger_label(script.trigger)}</.badge>
              <span
                :if={failing?(script)}
                class="script-failed"
                role="img"
                aria-label={
                  dpgettext(
                    "scripts",
                    "aria label: icon, the script's last run failed",
                    "Last run failed"
                  )
                }
              >
                <.lucide name="circle-alert" />
              </span>
            </span>
          </.pane_items>
        </:list>
        <:editor id="script-editor">
          <.pane_placeholder :if={@live_action == :index} id="script-placeholder">
            {dgettext("scripts", "Select a script, or create a new one.")}
          </.pane_placeholder>
          <div :if={@live_action != :index} class="script-editor-body">
            <.panel_header sticky>
              {if @editing_script,
                do: @editing_script.name,
                else: dpgettext("scripts", "heading: form for a new Lua script", "New script")}
              <:actions :if={@editing_script}>
                <.pane_export
                  id="export-script"
                  kind={:script}
                  item={@editing_script}
                  current_scope={@current_scope}
                />
                <.live_component
                  :if={Ownership.deletable?(@current_scope, @editing_script)}
                  module={MythweaverWeb.HandOff}
                  id="script-handoff"
                  thing="script"
                  current_scope={@current_scope}
                  item={@editing_script}
                  delete={&Scripts.delete_script/3}
                  index={~p"/scripts"}
                  delete_id="delete-script"
                  confirm={delete_confirm(@editing_script.name)}
                />
              </:actions>
            </.panel_header>
            <.live_component
              :if={@editing_script}
              module={MythweaverWeb.Lineage}
              id="script-lineage-line"
              thing="script"
              current_scope={@current_scope}
              item={@editing_script}
            />

            <.pane_section :if={@editing_script}>
              <div id="script-status" class="script-status">
                <p>
                  {dpgettext(
                    "scripts",
                    "field label: when the script last ran without error",
                    "Last success:"
                  )}
                  <.local_time
                    :if={@editing_script.last_success_at}
                    id="script-last-success"
                    at={@editing_script.last_success_at}
                    format={:full}
                  />
                  <span :if={is_nil(@editing_script.last_success_at)}>
                    {dpgettext("scripts", "status: the script has never run without error", "Never")}
                  </span>
                </p>
                <p>
                  {dpgettext("scripts", "field label: when the script last failed", "Last error:")}
                  <.local_time
                    :if={@editing_script.last_error_at}
                    id="script-last-error-at"
                    at={@editing_script.last_error_at}
                    format={:full}
                  />
                  <span :if={is_nil(@editing_script.last_error_at)}>
                    {dpgettext("scripts", "status: the script has never failed", "None")}
                  </span>
                </p>
                <pre :if={@editing_script.last_error} id="script-last-error">{@editing_script.last_error}</pre>
              </div>
            </.pane_section>

            <.pane_section>
              <.changed_elsewhere
                :if={@changed_elsewhere?}
                id="script-changed-elsewhere"
                patch={@live_sync_path}
              />
              <.form
                for={@form}
                id="script-form"
                class="script-form"
                phx-hook="UnsavedChanges"
                data-saved={is_nil(@form.action)}
                phx-change="validate"
                phx-submit="save"
              >
                <.owner_select
                  :if={is_nil(@editing_script)}
                  id="script-form-owner"
                  scope={@current_scope}
                  schema={Script}
                  value={@new_owner}
                />
                <.input
                  field={@form[:name]}
                  type="text"
                  label={dpgettext("scripts", "field label: name of a Lua script", "Name")}
                  id="script-form-name"
                  required
                />
                <.input
                  field={@form[:description]}
                  type="text"
                  label={
                    dpgettext("scripts", "field label: description of a Lua script", "Description")
                  }
                  id="script-form-description"
                />
                <.input
                  field={@form[:trigger]}
                  type="select"
                  label={dpgettext("scripts", "field label: event that runs a Lua script", "Trigger")}
                  id="script-form-trigger"
                  options={Script.trigger_options()}
                />
                <p :if={current_trigger?(@form, :command)} id="script-command-note">
                  {dgettext(
                    "scripts",
                    ~S[Runs from the command palette (Cmd-P / Ctrl-P) as "lua: <name>". Declare its inputs with ---@param lines at the top; see the event reference below.]
                  )}
                </p>
                <p :if={current_trigger?(@form, :quick_reply)} id="script-quick-reply-note">
                  {dgettext(
                    "scripts",
                    ~S[Shows as a button named after this script above the chat composer, and in the command palette as "quick reply: <name>". Gets the composer text as event.text; see the event reference below.]
                  )}
                </p>
                <.input
                  field={@form[:priority]}
                  type="number"
                  label={
                    if current_trigger?(@form, :quick_reply),
                      do:
                        dpgettext(
                          "scripts",
                          "field label: order of quick reply buttons",
                          "Priority (higher shows first)"
                        ),
                      else:
                        dpgettext(
                          "scripts",
                          "field label: run order of a Lua script",
                          "Priority (higher runs first)"
                        )
                  }
                  id="script-form-priority"
                />
                <.input
                  field={@form[:enabled]}
                  type="checkbox"
                  label={dpgettext("scripts", "toggle: Lua script runs on its trigger", "Enabled")}
                  id="script-form-enabled"
                />
                <.input
                  :if={OwnerSelect.site_row?(@editing_script, @current_scope, Script, @new_owner)}
                  field={@form[:site_visibility]}
                  type="select"
                  label={
                    dpgettext(
                      "scripts",
                      "field label: how much of a site Lua script users see",
                      "Visible to users"
                    )
                  }
                  id="script-form-site_visibility"
                  options={[
                    {dpgettext("scripts", "option: users see all of a site Lua script", "Everything"),
                     "readable"},
                    {dpgettext(
                       "scripts",
                       "option: users see only a site Lua script's name",
                       "Only names (runtime-only)"
                     ), "runtime_only"}
                  ]}
                >
                  <:hint>
                    {dgettext(
                      "scripts",
                      "What users who are not admins see of this script. Only names: never its body, in the assistant, scripts or exports; it still runs. Admins always see everything."
                    )}
                  </:hint>
                </.input>
                <.live_component
                  module={MythweaverWeb.MultiSelect}
                  id="script-form-dependency_ids"
                  name="script[dependency_ids][]"
                  label={
                    dpgettext("scripts", "field label: scripts this script runs after", "Runs after")
                  }
                  options={@dependency_options}
                  selected={@form[:dependency_ids].value || []}
                  errors={picker_errors(@form, :dependency_ids)}
                  empty={
                    dpgettext(
                      "scripts",
                      "empty state: no other scripts to depend on",
                      "No other scripts"
                    )
                  }
                  tag_kind={:script}
                  viewer_id={@current_scope.user.id}
                  tag_graph={@tag_graph}
                  tag_vocabulary={@tag_vocabulary}
                />
                <.editor
                  field={@form[:body]}
                  id="script-form-body"
                  label={dpgettext("scripts", "field label: Lua source of a script", "Script")}
                  language="lua"
                  completions={Scripts.Completions.lua(@form[:trigger].value)}
                  line_numbers
                  rows={16}
                  max_rows={40}
                />
                <div
                  :if={@checked? or @check.warnings != []}
                  id="script-check"
                  class="script-check"
                  role="status"
                >
                  <p
                    :if={@checked? and @check.errors == [] and @check.warnings == []}
                    id="script-check-ok"
                    class="script-check-ok"
                  >
                    <.lucide name="circle-check" />
                    {dpgettext(
                      "scripts",
                      "status: script check found no errors or warnings",
                      "No problems found."
                    )}
                  </p>
                  <p
                    :for={error <- if(@checked?, do: @check.errors, else: [])}
                    class="script-check-error"
                  >
                    <.lucide name="circle-x" /> {error}
                  </p>
                  <p :for={warning <- @check.warnings} class="script-check-warning">
                    <.lucide name="triangle-alert" /> {warning}
                  </p>
                </div>
                <.tag_fields
                  id="script-form-tags"
                  prefix="tags"
                  field={@tag_fields.item}
                  vocabulary={@tag_vocabulary}
                />
                <.form_actions>
                  <.button id="validate-script" phx-click="check_script">
                    {dpgettext("scripts", "button: check the script for errors", "Validate")}
                  </.button>
                  <.button patch={
                    if @editing_script,
                      do: ~p"/scripts/#{@editing_script.id}/edit",
                      else: ~p"/scripts"
                  }>
                    {dpgettext("scripts", "button: cancel editing the open form", "Cancel")}
                  </.button>
                  <.button type="submit" variant="primary">
                    {dpgettext("scripts", "button: save the open form", "Save")}
                  </.button>
                </.form_actions>
              </.form>
            </.pane_section>

            <.pane_section>
              <%!-- `ignore_attributes`: every `validate` re-renders the page, which would close it. --%>
              <details
                id="script-test"
                class="script-test"
                phx-mounted={JS.ignore_attributes(["open"])}
              >
                <summary>
                  {dpgettext(
                    "scripts",
                    "heading: section that test-runs the script",
                    "Test the script"
                  )}
                </summary>
                <p class="script-test-note">
                  {test_note()}
                </p>
                <.form
                  for={@test_form}
                  id="script-test-form"
                  class="script-form"
                  phx-change="test_change"
                  phx-submit="run_test"
                >
                  <.editor
                    field={@test_form[:text]}
                    id="script-test-form-text"
                    label={
                      dpgettext(
                        "scripts",
                        "field label: text a script test run gets as event.text",
                        "Sample text"
                      )
                    }
                    rows={3}
                    max_rows={10}
                  />
                  <.form_actions>
                    <.button type="submit" id="run-script-test" disabled={@testing?}>
                      {if @testing?,
                        do: dpgettext("scripts", "status: script test run in progress", "Running…"),
                        else: dpgettext("scripts", "button: run the script test", "Run test")}
                    </.button>
                  </.form_actions>
                </.form>
                <div
                  :if={@test_result}
                  id="script-test-result"
                  class="script-test-result"
                  role="status"
                >
                  <%= case test_outcome(@test_result) do %>
                    <% :failed -> %>
                      <p class="script-check-error">
                        <.lucide name="circle-x" />
                        {dpgettext(
                          "scripts",
                          "status: script test run failed; its error follows",
                          "The script failed:"
                        )}
                      </p>
                      <pre id="script-test-error" class="script-test-error">{elem(@test_result.result, 1)}</pre>
                    <% :ignored -> %>
                      <p id="script-test-ignored" class="script-check-ok">
                        <.lucide name="circle-check" />
                        {dgettext(
                          "scripts",
                          "Ran without errors. This trigger ignores return values."
                        )}
                      </p>
                    <% :quiet -> %>
                      <p id="script-test-quiet" class="script-check-ok">
                        <.lucide name="circle-check" /> {dgettext(
                          "scripts",
                          "Ran without errors; no notice."
                        )}
                      </p>
                    <% :notice -> %>
                      <p class="script-check-ok">
                        <.lucide name="circle-check" /> {dgettext(
                          "scripts",
                          "Ran without errors; it shows:"
                        )}
                      </p>
                      <pre id="script-test-notice">{elem(@test_result.result, 1)}</pre>
                    <% :qr_none -> %>
                      <p id="script-test-qr-none" class="script-check-ok">
                        <.lucide name="circle-check" />
                        {dgettext("scripts", "Ran without errors; the composer is left alone.")}
                      </p>
                    <% :qr_clear -> %>
                      <p id="script-test-qr-clear" class="script-check-ok">
                        <.lucide name="circle-check" />
                        {dgettext("scripts", "Ran without errors; the composer is emptied.")}
                      </p>
                    <% :qr_input -> %>
                      <p class="script-check-ok">
                        <.lucide name="circle-check" />
                        {dpgettext(
                          "scripts",
                          "status: quick reply test result; the new composer text follows",
                          "The composer becomes:"
                        )}
                      </p>
                      <pre id="script-test-qr-input">{elem(elem(@test_result.result, 1), 1)}</pre>
                    <% :qr_message -> %>
                      <p class="script-check-ok">
                        <.lucide name="circle-check" />
                        {dpgettext(
                          "scripts",
                          "status: quick reply test result; the message it sends follows",
                          "It sends this message:"
                        )}
                      </p>
                      <pre id="script-test-qr-message">{elem(elem(@test_result.result, 1), 1)}</pre>
                    <% :unchanged -> %>
                      <p id="script-test-unchanged" class="script-check-ok">
                        <.lucide name="circle-check" />
                        {dgettext("scripts", "Ran without errors; the text is unchanged.")}
                      </p>
                    <% :changed -> %>
                      <p class="script-check-ok">
                        <.lucide name="circle-check" />
                        {dpgettext(
                          "scripts",
                          "status: script test result; the rewritten text follows",
                          "The text becomes:"
                        )}
                      </p>
                      <pre id="script-test-output">{elem(@test_result.result, 1)}</pre>
                  <% end %>
                  <div :if={@test_result.lines != []} id="script-test-printed">
                    <p>
                      {dpgettext(
                        "scripts",
                        "field label: lines a script test run printed",
                        "Printed:"
                      )}
                    </p>
                    <pre>{Enum.join(@test_result.lines, "\n")}</pre>
                  </div>
                </div>
              </details>
            </.pane_section>

            <.pane_section>
              <%!-- `ignore_attributes`: every `validate` re-renders the page, which would close it. --%>
              <details
                id="script-event-reference"
                class="script-reference"
                phx-mounted={JS.ignore_attributes(["open"])}
              >
                <summary>
                  {rich(
                    dgettext("scripts", "Script reference: the %{event_table} table",
                      event_table: code("event")
                    )
                  )}
                </summary>
                <p>
                  {rich(
                    dgettext(
                      "scripts",
                      "Each run gets a global %{event_table} table describing what fired it. Every event has:",
                      event_table: code("event")
                    )
                  )}
                </p>
                <dl>
                  <div :for={{name, type, description} <- @common_event_fields}>
                    <dt>
                      <code>event.{name}</code> <span class="script-reference-type">{type}</span>
                    </dt>
                    <dd>{description}</dd>
                  </div>
                </dl>
                <section
                  :for={event <- @event_reference}
                  id={"script-event-reference-#{event.trigger}"}
                  class={[
                    "script-reference-trigger",
                    current_trigger?(@form, event.trigger) && "current"
                  ]}
                >
                  <h4>
                    {@trigger_names[event.trigger]}
                    <.badge :if={current_trigger?(@form, event.trigger)}>
                      {dpgettext("scripts", "badge: this trigger is the open script's", "this script")}
                    </.badge>
                  </h4>
                  <p>{event.summary}</p>
                  <dl :if={event.fields != []}>
                    <div :for={{name, type, description} <- event.fields}>
                      <dt>
                        <code>event.{name}</code> <span class="script-reference-type">{type}</span>
                      </dt>
                      <dd>{description}</dd>
                    </div>
                  </dl>
                  <p>{return_value_text(event.returns)}</p>
                  <pre :if={event.example}><code>{event.example}</code></pre>
                </section>
                <p>
                  {host_functions_text()}
                </p>
              </details>
            </.pane_section>
            <.live_component
              :if={@editing_script}
              module={MythweaverWeb.SharePanel}
              id="script-share"
              current_scope={@current_scope}
              item={@editing_script}
            />
          </div>
        </:editor>
      </.pane_layout>
    </Layouts.app>
    """
  end
end
