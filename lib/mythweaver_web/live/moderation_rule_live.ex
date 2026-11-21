defmodule MythweaverWeb.ModerationRuleLive do
  @moduledoc """
  The content-moderation rules editor (`/moderation/rules`, `"moderation.rules.manage"`): the regex
  and webhook rules (`Mythweaver.Moderation.Rules`) every moderated save is checked against, in the
  two-pane editor shape. Reloads on `Mythweaver.Moderation.broadcast_changed/0`.
  """
  use MythweaverWeb, :live_view

  import MythweaverWeb.Pane

  alias Mythweaver.Moderation
  alias Mythweaver.Moderation.Rule
  alias Mythweaver.Moderation.Rules
  alias MythweaverWeb.ModerationNav
  alias Phoenix.HTML.Form

  on_mount {MythweaverWeb.UserAuth, {:require_permission, "moderation.rules.manage"}}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Moderation.subscribe()

    {:ok,
     socket
     |> assign(
       page_title: dpgettext("moderation", "page title: moderation rules editor", "Moderation rules"),
       selected_id: nil,
       rule: nil,
       form: nil
     )
     |> stream_configure(:moderation_rules, dom_id: &"moderation-rules-#{&1.id}")
     |> stream_rules()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(rule: nil, selected_id: nil, form: nil)
    |> stream_rules()
  end

  defp apply_action(socket, :new, _params) do
    assign(socket, rule: nil, selected_id: nil, form: to_form(Rules.change_rule(%Rule{kind: :regex})))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Rules.get_rule(socket.assigns.current_scope, id) do
      {:ok, rule} ->
        assign(socket, rule: rule, selected_id: rule.id, form: to_form(Rules.change_rule(rule)))

      {:error, _} ->
        socket
        |> put_flash(:error, not_found_flash())
        |> push_patch(to: ~p"/moderation/rules")
    end
  end

  @impl true
  def handle_event("validate", %{"rule" => params}, socket) do
    changeset = Rules.change_rule(socket.assigns.rule || %Rule{}, with_types(params))
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"rule" => params}, socket) do
    scope = socket.assigns.current_scope
    params = with_types(params)

    result =
      case socket.assigns.rule do
        nil -> Rules.create_rule(scope, params)
        rule -> Rules.update_rule(scope, rule, params)
      end

    case result do
      {:ok, rule} ->
        {:noreply,
         socket
         |> put_flash(:info, saved_flash(rule))
         |> stream_rules()
         |> push_patch(to: ~p"/moderation/rules/#{rule.id}/edit")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}

      {:error, :unauthorized} ->
        {:noreply, MythweaverWeb.Flash.flash_unauthorized(socket)}
    end
  end

  def handle_event("delete", _params, socket) do
    case Rules.delete_rule(socket.assigns.current_scope, socket.assigns.rule) do
      {:ok, rule} ->
        {:noreply,
         socket
         |> put_flash(:info, deleted_flash(rule))
         |> stream_delete(:moderation_rules, rule)
         |> push_patch(to: ~p"/moderation/rules")}

      {:error, :unauthorized} ->
        {:noreply, MythweaverWeb.Flash.flash_unauthorized(socket)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, delete_failed_flash())}
    end
  end

  @impl true
  def handle_info({Moderation, :changed}, socket), do: {:noreply, stream_rules(socket)}

  # A multiple select with nothing chosen posts no key at all.
  defp with_types(params), do: Map.put_new(params, "content_types", [])

  defp stream_rules(socket) do
    rules =
      case Rules.list_rules(socket.assigns.current_scope) do
        {:ok, rules} -> rules
        {:error, _} -> []
      end

    socket
    |> assign(moderation_rules_empty?: rules == [])
    |> stream(:moderation_rules, rules, reset: true)
  end

  defp kind_label(:regex), do: dpgettext("moderation", "option: kind of moderation rule", "Regex")
  defp kind_label(:webhook), do: dpgettext("moderation", "option: kind of moderation rule", "Webhook")

  defp type_options do
    [
      {dpgettext("moderation", "option: content type a moderation rule checks", "Chats and messages"), :chats},
      {dpgettext("moderation", "option: content type a moderation rule checks", "Characters"), :characters},
      {dpgettext("moderation", "option: content type a moderation rule checks", "Lore books and entries"), :lore},
      {dpgettext("moderation", "option: content type a moderation rule checks", "AI connections and models"), :ai},
      {dpgettext("moderation", "option: content type a moderation rule checks", "Prompts, blocks and outlets"),
       :prompts}
    ]
  end

  defp not_found_flash do
    gettext_comment("Flash when the moderation rule in the link no longer exists.")
    dpgettext("moderation", "status: the moderation rule in the link no longer exists", "Rule not found")
  end

  defp saved_flash(rule) do
    gettext_comment("Flash after a moderation rule is saved.")
    dpgettext("moderation", "status: a moderation rule was saved", "%{rule_name} saved", rule_name: rule.name)
  end

  defp deleted_flash(rule) do
    gettext_comment("Flash after a moderation rule is deleted.")
    dpgettext("moderation", "status: a moderation rule was deleted", "%{rule_name} deleted", rule_name: rule.name)
  end

  defp delete_failed_flash do
    gettext_comment("Flash when a moderator's delete (of an item or a rule) fails.")
    dpgettext("moderation", "status: deleting the item failed", "Could not delete it")
  end

  defp delete_confirm(rule) do
    gettext_comment("Confirm dialog before a moderation rule is deleted.")

    dpgettext("moderation", "heading: confirm dialog before deleting a moderation rule", "Delete %{rule_name}?",
      rule_name: rule.name
    )
  end

  defp callback_notice do
    gettext_comment(
      "Shown under the webhook verdict field when the server has no callback URL; the placeholder is an environment variable name."
    )

    dgettext("moderation", "Callback mode needs %{env_var} on the server", env_var: "MODERATION_CALLBACK_URL")
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        type_options: type_options(),
        kind: assigns.form && Form.input_value(assigns.form, :kind) |> to_kind(),
        callback_url: Moderation.callback_url()
      )

    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      div.moderation-rule-editor-body:scope {
        display: contents;
      }

      .moderation-rule-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .moderation-rule-notice {
        margin: 0;
        color: var(--muted-foreground);
        font-size: var(--font-size-0);
      }
    </style>

    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <ModerationNav.nav current_scope={@current_scope} active="rules" />
      <.pane_layout>
        <:list
          id="moderation-rules-nav"
          label={dpgettext("moderation", "aria label: list of moderation rules", "Moderation rules")}
        >
          <.pane_header title={dpgettext("moderation", "heading: list of moderation rules", "Rules")} />
          <.pane_actions>
            <.button variant="primary" patch={~p"/moderation/rules/new"} id="new-moderation-rule">
              <.lucide name="plus" /> {dpgettext(
                "moderation",
                "button: create a moderation rule",
                "New rule"
              )}
            </.button>
          </.pane_actions>
          <.pane_items
            :let={rule}
            id="moderation-rules"
            rows={@streams.moderation_rules}
            empty?={@moderation_rules_empty?}
            empty={dpgettext("moderation", "empty state: no moderation rules", "No rules yet")}
            selected_id={@selected_id}
            patch={fn rule -> ~p"/moderation/rules/#{rule.id}/edit" end}
          >
            <span class="pane-item-name">{rule.name}</span>
            <span class="pane-item-meta">
              {kind_label(rule.kind)}{if rule.enabled,
                do: "",
                else: " · " <> dpgettext("moderation", "status: moderation rule turned off", "Off")}
            </span>
          </.pane_items>
        </:list>
        <:editor id="moderation-rule-editor">
          <.pane_placeholder :if={@live_action == :index} id="moderation-rule-placeholder">
            {dgettext("moderation", "Select a rule, or create a new one.")}
          </.pane_placeholder>
          <div :if={@live_action != :index} class="moderation-rule-editor-body">
            <.panel_header sticky>
              {if @rule,
                do: @rule.name,
                else: dpgettext("moderation", "heading: moderation rule not saved yet", "New rule")}
              <:actions :if={@rule}>
                <.pane_delete
                  id="delete-moderation-rule"
                  phx-click="delete"
                  confirm={delete_confirm(@rule)}
                >
                  {dpgettext("moderation", "button: delete this moderation rule", "Delete")}
                </.pane_delete>
              </:actions>
            </.panel_header>

            <.pane_section>
              <.form
                for={@form}
                id="moderation-rule-form"
                class="moderation-rule-form"
                phx-hook="UnsavedChanges"
                data-saved={is_nil(@form.action)}
                phx-change="validate"
                phx-submit="save"
              >
                <.input
                  field={@form[:name]}
                  type="text"
                  label={dpgettext("moderation", "field label: name of a moderation rule", "Name")}
                  id="moderation-rule-form-name"
                  required
                />
                <.input
                  field={@form[:kind]}
                  type="select"
                  label={dpgettext("moderation", "field label: kind of moderation rule", "Kind")}
                  id="moderation-rule-form-kind"
                  options={[{kind_label(:regex), :regex}, {kind_label(:webhook), :webhook}]}
                />
                <.input
                  field={@form[:enabled]}
                  type="checkbox"
                  label={dpgettext("moderation", "toggle: moderation rule is on", "Enabled")}
                  id="moderation-rule-form-enabled"
                />
                <.input
                  field={@form[:content_types]}
                  type="select"
                  multiple
                  label={
                    dpgettext(
                      "moderation",
                      "field label: content types a moderation rule checks",
                      "Content types"
                    )
                  }
                  id="moderation-rule-form-content_types"
                  options={@type_options}
                />

                <%= if @kind == :regex do %>
                  <.input
                    field={@form[:pattern]}
                    type="text"
                    label={
                      dpgettext("moderation", "field label: regex of a moderation rule", "Pattern")
                    }
                    id="moderation-rule-form-pattern"
                  />
                  <.input
                    field={@form[:case_sensitive]}
                    type="checkbox"
                    label={
                      dpgettext(
                        "moderation",
                        "toggle: moderation rule regex matches case",
                        "Case sensitive"
                      )
                    }
                    id="moderation-rule-form-case_sensitive"
                  />
                  <.input
                    field={@form[:regex_action]}
                    type="select"
                    label={
                      dpgettext(
                        "moderation",
                        "field label: what a regex moderation rule does on a match",
                        "On a match"
                      )
                    }
                    id="moderation-rule-form-regex_action"
                    options={[
                      {dpgettext(
                         "moderation",
                         "option: what a regex moderation rule does on a match",
                         "Flag for review"
                       ), :flag},
                      {dpgettext(
                         "moderation",
                         "option: what a regex moderation rule does on a match",
                         "Reject"
                       ), :reject}
                    ]}
                  />
                <% end %>

                <%= if @kind == :webhook do %>
                  <.input
                    field={@form[:url]}
                    type="url"
                    label={
                      dpgettext("moderation", "field label: URL of a webhook moderation rule", "URL")
                    }
                    id="moderation-rule-form-url"
                  />
                  <.input
                    field={@form[:secret]}
                    type="password"
                    value=""
                    label={
                      dpgettext(
                        "moderation",
                        "field label: secret that signs a moderation webhook request",
                        "Signing secret (optional)"
                      )
                    }
                    id="moderation-rule-form-secret"
                    autocomplete="off"
                  >
                    <:hint>{dgettext("moderation", "Leave blank to keep the current secret.")}</:hint>
                  </.input>
                  <.input
                    :if={@rule && @rule.secret}
                    field={@form[:clear_secret]}
                    type="checkbox"
                    label={
                      dpgettext(
                        "moderation",
                        "toggle: remove the moderation webhook's signing secret",
                        "Remove the secret"
                      )
                    }
                    id="moderation-rule-form-clear_secret"
                  />
                  <.input
                    field={@form[:webhook_mode]}
                    type="select"
                    label={
                      dpgettext(
                        "moderation",
                        "field label: how a moderation webhook returns its verdict",
                        "Verdict"
                      )
                    }
                    id="moderation-rule-form-webhook_mode"
                    options={[
                      {dpgettext(
                         "moderation",
                         "option: how a moderation webhook returns its verdict",
                         "In the response (sync)"
                       ), :sync},
                      {dpgettext(
                         "moderation",
                         "option: how a moderation webhook returns its verdict",
                         "Later, by callback"
                       ), :callback}
                    ]}
                  />
                  <p
                    :if={is_nil(@callback_url)}
                    id="moderation-rule-callback-notice"
                    class="moderation-rule-notice"
                  >
                    {callback_notice()}
                  </p>
                  <.input
                    field={@form[:timeout_ms]}
                    type="number"
                    label={
                      dpgettext(
                        "moderation",
                        "field label: timeout of a moderation webhook request, in milliseconds",
                        "Request timeout (ms)"
                      )
                    }
                    id="moderation-rule-form-timeout_ms"
                    min="1000"
                    max="60000"
                  />
                  <.input
                    field={@form[:callback_timeout_minutes]}
                    type="number"
                    label={
                      dpgettext(
                        "moderation",
                        "field label: how long a moderation webhook callback may take, in minutes",
                        "Callback timeout (minutes)"
                      )
                    }
                    id="moderation-rule-form-callback_timeout_minutes"
                    min="1"
                    max="10080"
                  />
                <% end %>

                <.form_actions>
                  <.button patch={
                    if @rule,
                      do: ~p"/moderation/rules/#{@rule.id}/edit",
                      else: ~p"/moderation/rules"
                  }>
                    {dpgettext("moderation", "button: discard edits to the moderation rule", "Cancel")}
                  </.button>
                  <.button type="submit" variant="primary">
                    {dpgettext("moderation", "button: save the moderation rule", "Save")}
                  </.button>
                </.form_actions>
              </.form>
            </.pane_section>
          </div>
        </:editor>
      </.pane_layout>
    </Layouts.app>
    """
  end

  defp to_kind(kind) when kind in [:regex, :webhook], do: kind
  defp to_kind("regex"), do: :regex
  defp to_kind("webhook"), do: :webhook
  defp to_kind(_), do: nil
end
