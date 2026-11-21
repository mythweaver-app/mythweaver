defmodule MythweaverWeb.ExpressionProfileLive do
  @moduledoc """
  Expression rule profiles (`Mythweaver.Expressions.Profile`): the profile list on the left, the
  selected profile's rules on the right. A rule is a derived expression label: a combination of
  emotions that score close together, or ranges every listed emotion's score must fall in. Rules
  and their emotions are `embeds_many`, added and removed with the sort/drop params.
  """
  use MythweaverWeb, :live_view

  import MythweaverWeb.Pane

  alias Mythweaver.Expressions
  alias Mythweaver.Expressions.Profile
  alias MythweaverWeb.CoreComponents.OwnerSelect
  alias MythweaverWeb.LiveSync

  on_mount {MythweaverWeb.ContentAccess, :characters}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: dpgettext("characters", "page title: expression rule profiles", "Expression rules"),
       form: nil,
       editing_profile: nil,
       new_owner: "personal",
       selected_id: nil
     )
     |> stream_configure(:profiles, dom_id: &"expression-profiles-#{&1.id}")
     |> stream_profiles()
     |> LiveSync.attach_editor([:characters], &sync/2)}
  end

  defp sync(socket, _kinds) do
    scope = socket.assigns.current_scope

    socket
    |> stream_profiles()
    |> LiveSync.sync_open(:editing_profile,
      fetch: &Expressions.get_editable_profile(scope, &1),
      clean?: LiveSync.clean?(socket.assigns.form),
      reload: &assign(&1, form: profile_form(Expressions.change_profile(&2)), editing_profile: &2),
      gone: ~p"/characters/expression-profiles",
      gone_message:
        (
          gettext_comment(
            "Flash shown when the expression profile open in the editor was deleted or moved by someone else."
          )

          dgettext("characters", "The expression profile was deleted or moved elsewhere.")
        )
    )
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(form: nil, editing_profile: nil, selected_id: nil)
    |> stream_profiles()
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(
      form: profile_form(Expressions.change_profile(%Profile{rules: []})),
      editing_profile: nil,
      new_owner: "personal",
      selected_id: nil
    )
    |> stream_profiles()
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Expressions.get_editable_profile(socket.assigns.current_scope, id) do
      nil ->
        socket
        |> put_flash(:error, not_found_flash())
        |> push_patch(to: ~p"/characters/expression-profiles")

      profile ->
        socket
        |> assign(
          form: profile_form(Expressions.change_profile(profile)),
          editing_profile: profile,
          selected_id: profile.id
        )
        |> stream_profiles()
    end
  end

  defp profile_form(changeset), do: to_form(changeset, as: :expression_profile)

  @impl true
  def handle_event("validate", %{"expression_profile" => params} = all, socket) do
    changeset =
      (socket.assigns.editing_profile || %Profile{rules: []})
      |> Expressions.change_profile(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: profile_form(changeset), new_owner: OwnerSelect.choice(all))}
  end

  def handle_event("save", %{"expression_profile" => params} = all, socket) do
    scope = socket.assigns.current_scope

    result =
      case socket.assigns.editing_profile do
        nil -> Expressions.create_profile(scope, params, OwnerSelect.create_opts(OwnerSelect.choice(all)))
        profile -> Expressions.update_profile(scope, profile, params)
      end

    case result do
      {:ok, profile} ->
        {:noreply,
         socket
         |> put_flash(:info, saved_flash(profile.name))
         |> push_patch(to: ~p"/characters/expression-profiles/#{profile.id}/edit")}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(form: profile_form(changeset))
         |> put_flash(:error, save_failed_flash())}
    end
  end

  def handle_event("delete", _params, %{assigns: %{editing_profile: %Profile{} = profile}} = socket) do
    {:ok, _} = Expressions.delete_profile(socket.assigns.current_scope, profile)

    {:noreply,
     socket
     |> put_flash(:info, deleted_flash(profile.name))
     |> push_patch(to: ~p"/characters/expression-profiles")}
  end

  defp stream_profiles(socket) do
    profiles = Expressions.list_editable_profiles(socket.assigns.current_scope)

    socket
    |> assign(profiles_empty?: profiles == [])
    |> stream(:profiles, profiles, reset: true)
  end

  defp range?(rule), do: to_string(rule[:kind].value) == "range"

  defp errors(field), do: Enum.map(field.errors, &translate_error/1)

  defp not_found_flash do
    gettext_comment("Flash when the expression profile in the URL does not exist or cannot be edited.")

    dpgettext(
      "characters",
      "status: flash when an expression rule profile could not be found",
      "Expression profile not found"
    )
  end

  defp saved_flash(profile_name) do
    gettext_comment("Flash after an expression rule profile is saved.")

    dpgettext("characters", "status: flash after saving an expression rule profile", "%{profile_name} saved",
      profile_name: profile_name
    )
  end

  defp save_failed_flash do
    gettext_comment("Flash when saving an editor form fails validation; the invalid fields are highlighted.")
    dgettext("characters", "Could not save — see the highlighted fields")
  end

  defp deleted_flash(profile_name) do
    gettext_comment("Flash after an expression rule profile is deleted.")

    dpgettext("characters", "status: flash after deleting an expression rule profile", "%{profile_name} deleted",
      profile_name: profile_name
    )
  end

  defp delete_confirm(profile_name) do
    gettext_comment("Confirm dialog before deleting an expression rule profile.")

    dgettext(
      "characters",
      "Delete %{profile_name}? Characters using it fall back to the default profile.",
      profile_name: profile_name
    )
  end

  defp base_labels_hint do
    gettext_comment(
      "The list holds the classifier's fixed emotion identifiers (joy, anger, …), which stay untranslated."
    )

    dgettext(
      "characters",
      "Emotions the classifier rates: %{emotion_labels}, plus each character's custom expressions.",
      emotion_labels: Enum.join(Expressions.base_labels(), ", ")
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      div.expression-profile-editor-body:scope {
        display: contents;
      }

      .expression-profile-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .expression-profile-rule {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
        padding: var(--size-2);
        border: 1px solid var(--border);
        border-radius: var(--radius-2);
      }

      .expression-profile-row {
        display: flex;
        flex-wrap: wrap;
        gap: var(--size-2);
        align-items: flex-end;
      }

      .expression-profile-condition {
        display: flex;
        flex-wrap: wrap;
        gap: var(--size-2);
        align-items: flex-end;
        padding-inline-start: var(--size-3);
      }

      .expression-profile-errors {
        margin: 0;
        color: var(--destructive);
      }

      .expression-profile-hint {
        color: var(--muted-foreground);
      }
    </style>

    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.pane_layout>
        <:list
          id="expression-profiles-nav"
          label={dpgettext("characters", "page title: expression rule profiles", "Expression rules")}
        >
          <.pane_header title={
            dpgettext("characters", "page title: expression rule profiles", "Expression rules")
          }>
            <:switch id="pane-switch-characters" navigate={~p"/characters"}>
              <.lucide name="users" />
              {dpgettext("characters", "link: switch to the characters pane", "Characters")}
            </:switch>
          </.pane_header>
          <.pane_actions>
            <.button
              variant="primary"
              patch={~p"/characters/expression-profiles/new"}
              id="new-expression-profile"
            >
              <.lucide name="plus" />
              {dpgettext("characters", "button: create an expression rule profile", "New profile")}
            </.button>
          </.pane_actions>
          <.pane_items
            :let={profile}
            id="expression-profiles"
            rows={@streams.profiles}
            empty?={@profiles_empty?}
            empty={
              dpgettext(
                "characters",
                "empty state: list of expression rule profiles",
                "No expression profiles yet"
              )
            }
            selected_id={@selected_id}
            patch={fn profile -> ~p"/characters/expression-profiles/#{profile.id}/edit" end}
          >
            <span class="pane-item-name">{profile.name}</span>
          </.pane_items>
        </:list>
        <:editor id="expression-profile-editor">
          <.pane_placeholder :if={@live_action == :index} id="expression-profile-placeholder">
            {dgettext("characters", "Select an expression profile, or create a new one.")}
          </.pane_placeholder>
          <div :if={@live_action != :index} class="expression-profile-editor-body">
            <.panel_header sticky>
              {if @editing_profile,
                do: @editing_profile.name,
                else:
                  dpgettext(
                    "characters",
                    "heading: unsaved new expression profile",
                    "New expression profile"
                  )}
              <:actions :if={@editing_profile}>
                <.pane_delete
                  id="delete-expression-profile"
                  phx-click="delete"
                  confirm={delete_confirm(@editing_profile.name)}
                >
                  {dpgettext("characters", "button: delete this expression rule profile", "Delete")}
                </.pane_delete>
              </:actions>
            </.panel_header>

            <.pane_section>
              <.changed_elsewhere
                :if={@changed_elsewhere?}
                id="expression-profile-changed-elsewhere"
                patch={@live_sync_path}
              />
              <.form
                for={@form}
                id="expression-profile-form"
                class="expression-profile-form"
                phx-hook="UnsavedChanges"
                data-saved={is_nil(@form.action)}
                phx-change="validate"
                phx-submit="save"
              >
                <.owner_select
                  :if={is_nil(@editing_profile)}
                  id="expression-profile-form-owner"
                  scope={@current_scope}
                  schema={Profile}
                  value={@new_owner}
                />
                <.input
                  field={@form[:name]}
                  type="text"
                  label={
                    dpgettext("characters", "field label: name of an expression rule profile", "Name")
                  }
                  id="expression-profile-form-name"
                  required
                />

                <.section_header>
                  {dpgettext("characters", "heading: rules of an expression profile", "Rules")}
                </.section_header>
                <p :for={msg <- errors(@form[:rules])} class="expression-profile-errors">{msg}</p>
                <.inputs_for :let={rule} field={@form[:rules]}>
                  <div class="expression-profile-rule" id={"expression-profile-rule-#{rule.index}"}>
                    <input type="hidden" name="expression_profile[rules_sort][]" value={rule.index} />
                    <div class="expression-profile-row">
                      <.input
                        field={rule[:name]}
                        type="text"
                        label={
                          dpgettext(
                            "characters",
                            "field label: expression an expression rule produces",
                            "Expression"
                          )
                        }
                        placeholder={
                          dpgettext(
                            "characters",
                            "placeholder: example expression rule name",
                            "e.g. elated"
                          )
                        }
                        id={"expression-profile-rule-#{rule.index}-name"}
                      />
                      <.input
                        field={rule[:kind]}
                        type="select"
                        label={
                          dpgettext("characters", "field label: kind of expression rule", "Kind")
                        }
                        options={[
                          {dpgettext("characters", "option: kind of expression rule", "Combination"),
                           "combination"},
                          {dpgettext("characters", "option: kind of expression rule", "Range"),
                           "range"}
                        ]}
                        id={"expression-profile-rule-#{rule.index}-kind"}
                      />
                      <.input
                        :if={!range?(rule)}
                        field={rule[:max_difference]}
                        type="number"
                        min="0"
                        max="100"
                        label={dgettext("characters", "Max difference between emotions, %")}
                        id={"expression-profile-rule-#{rule.index}-max_difference"}
                      />
                      <.input
                        field={rule[:enabled]}
                        type="checkbox"
                        label={dpgettext("characters", "toggle: expression rule enabled", "Enabled")}
                        id={"expression-profile-rule-#{rule.index}-enabled"}
                      />
                      <.button
                        size="sm"
                        danger
                        type="button"
                        name="expression_profile[rules_drop][]"
                        value={rule.index}
                        phx-click={JS.dispatch("change")}
                        id={"expression-profile-rule-#{rule.index}-remove"}
                      >
                        <.lucide name="trash" />
                        {dpgettext("characters", "button: remove an expression rule", "Remove rule")}
                      </.button>
                    </div>
                    <p :for={msg <- errors(rule[:conditions])} class="expression-profile-errors">
                      {msg}
                    </p>
                    <.inputs_for :let={c} field={rule[:conditions]}>
                      <div
                        class="expression-profile-condition"
                        id={"expression-profile-rule-#{rule.index}-condition-#{c.index}"}
                      >
                        <input
                          type="hidden"
                          name={rule.name <> "[conditions_sort][]"}
                          value={c.index}
                        />
                        <.input
                          field={c[:label]}
                          type="text"
                          label={
                            dpgettext(
                              "characters",
                              "field label: emotion in an expression rule condition",
                              "Emotion"
                            )
                          }
                          placeholder={
                            dpgettext("characters", "placeholder: example emotion label", "e.g. joy")
                          }
                          id={"expression-profile-rule-#{rule.index}-condition-#{c.index}-label"}
                        />
                        <.input
                          :if={range?(rule)}
                          field={c[:min]}
                          type="number"
                          min="0"
                          max="100"
                          label={
                            dpgettext(
                              "characters",
                              "field label: minimum emotion score percent",
                              "Min %"
                            )
                          }
                          id={"expression-profile-rule-#{rule.index}-condition-#{c.index}-min"}
                        />
                        <.input
                          :if={range?(rule)}
                          field={c[:max]}
                          type="number"
                          min="0"
                          max="100"
                          label={
                            dpgettext(
                              "characters",
                              "field label: maximum emotion score percent",
                              "Max %"
                            )
                          }
                          id={"expression-profile-rule-#{rule.index}-condition-#{c.index}-max"}
                        />
                        <.button
                          size="sm"
                          icon
                          type="button"
                          name={rule.name <> "[conditions_drop][]"}
                          value={c.index}
                          phx-click={JS.dispatch("change")}
                          id={"expression-profile-rule-#{rule.index}-condition-#{c.index}-remove"}
                          aria-label={
                            dpgettext(
                              "characters",
                              "aria label: remove an emotion condition from a rule",
                              "Remove emotion"
                            )
                          }
                        >
                          <.lucide name="x" />
                        </.button>
                      </div>
                    </.inputs_for>
                    <input type="hidden" name={rule.name <> "[conditions_drop][]"} />
                    <.button
                      size="sm"
                      type="button"
                      name={rule.name <> "[conditions_sort][]"}
                      value="new"
                      phx-click={JS.dispatch("change")}
                      id={"expression-profile-rule-#{rule.index}-add-condition"}
                    >
                      <.lucide name="plus" />
                      {dpgettext(
                        "characters",
                        "button: add an emotion condition to a rule",
                        "Add emotion"
                      )}
                    </.button>
                  </div>
                </.inputs_for>
                <input type="hidden" name="expression_profile[rules_drop][]" />

                <p class="expression-profile-hint" id="expression-profile-base-labels">
                  {base_labels_hint()}
                </p>

                <.form_actions>
                  <:start>
                    <.button
                      size="sm"
                      type="button"
                      id="expression-profile-add-rule"
                      name="expression_profile[rules_sort][]"
                      value="new"
                      phx-click={JS.dispatch("change")}
                    >
                      <.lucide name="plus" />
                      {dpgettext(
                        "characters",
                        "button: add a rule to an expression profile",
                        "Add rule"
                      )}
                    </.button>
                  </:start>
                  <.button patch={
                    if @editing_profile,
                      do: ~p"/characters/expression-profiles/#{@editing_profile.id}/edit",
                      else: ~p"/characters/expression-profiles"
                  }>
                    {dpgettext("characters", "button: discard edits to the open form", "Cancel")}
                  </.button>
                  <.button type="submit" variant="primary">
                    {dpgettext("characters", "button: save the expression rule profile", "Save")}
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
end
