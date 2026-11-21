defmodule MythweaverWeb.GroupLive do
  @moduledoc """
  Groups and their permissions: the group list on the left, the selected group's form, members and
  permission grid (`MythweaverWeb.PermissionGrid`) on the right. Holders of `"groups.manage"` reach
  it as the moderation panel's Groups section (`/moderation/groups`).
  The system groups (Everyone, Administrators) cannot be deleted, and Everyone has no member
  list: it holds every account implicitly. Every change goes through `Mythweaver.Permissions`, whose
  Discord rule refuses keys the viewer does not hold; the affected users' sessions are then
  disconnected, so their next mount resolves the new permissions. `:index` selects nothing: the
  editor pane shows a placeholder until a group is picked.
  """
  use MythweaverWeb, :live_view

  import MythweaverWeb.Pane

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.User
  alias Mythweaver.Permissions
  alias Mythweaver.Permissions.Catalog
  alias Mythweaver.Permissions.Group
  alias MythweaverWeb.LiveSync
  alias MythweaverWeb.PermissionGrid
  alias MythweaverWeb.UserAuth

  on_mount {MythweaverWeb.UserAuth, {:require_permission, "groups.manage"}}
  on_mount MythweaverWeb.Sudo

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: dpgettext("admin", "page title: permission groups editor", "Groups"),
       selected_id: nil,
       group: nil,
       form: nil,
       grants: %{},
       member_ids: [],
       member_options: [],
       locked_key: nil
     )
     |> stream_configure(:groups, dom_id: &"groups-#{&1.id}")
     |> stream_groups()
     |> LiveSync.attach_editor([:accounts], &sync/2)}
  end

  defp sync(socket, _kinds) do
    scope = socket.assigns.current_scope

    socket =
      socket
      |> stream_groups()
      |> LiveSync.sync_open(:group,
        fetch: &Permissions.get_group(scope, &1),
        clean?: LiveSync.clean?(socket.assigns.form),
        reload: &assign(&1, group: &2, form: to_form(Permissions.change_group(&2))),
        gone: ~p"/moderation/groups",
        gone_message:
          (
            gettext_comment("Flash shown when the group open in the editor was deleted or moved by someone else.")
            dgettext("admin", "The group was deleted or moved elsewhere.")
          )
      )

    if socket.assigns.group, do: assign_group_state(socket), else: socket
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(
      group: nil,
      selected_id: nil,
      form: nil,
      grants: %{},
      member_ids: [],
      locked_key: nil
    )
    |> stream_groups()
  end

  defp apply_action(socket, :new, _params) do
    assign(socket,
      group: nil,
      selected_id: nil,
      form: to_form(Permissions.change_group(%Group{})),
      grants: %{},
      member_ids: [],
      locked_key: nil
    )
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Permissions.get_group(socket.assigns.current_scope, id) do
      nil ->
        socket
        |> put_flash(:error, not_found_flash())
        |> push_patch(to: ~p"/moderation/groups")

      group ->
        socket
        |> assign(group: group, selected_id: group.id, form: to_form(Permissions.change_group(group)))
        |> assign_group_state()
    end
  end

  defp assign_group_state(socket) do
    group = socket.assigns.group

    locked_key =
      case Permissions.held_rows_ok(socket.assigns.current_scope, group) do
        :ok -> nil
        {:error, {:not_held, key}} -> key
      end

    assign(socket,
      grants: Permissions.grants_for(group),
      member_ids: if(group.system_key == :everyone, do: [], else: Enum.map(Permissions.list_members(group), & &1.id)),
      member_options: Enum.map(Accounts.list_users(), &{member_label(&1), &1.id}),
      locked_key: locked_key
    )
  end

  # Nickname plus handle, so two members sharing a nickname stay distinguishable; never the email.
  defp member_label(%User{nickname: nil, handle: handle}), do: "@#{handle}"
  defp member_label(%User{nickname: nickname, handle: handle}), do: "#{nickname} (@#{handle})"

  @impl true
  def handle_event("validate", %{"group" => params}, socket) do
    changeset = Permissions.change_group(socket.assigns.group || %Group{}, params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"group" => params} = event_params, socket) do
    scope = socket.assigns.current_scope

    result =
      case socket.assigns.group do
        nil -> Permissions.create_group(scope, params)
        group -> Permissions.update_group(scope, group, params)
      end

    case result do
      {:ok, group} ->
        {:noreply,
         socket
         |> put_flash(:info, saved_flash(group))
         |> stream_groups()
         |> push_patch(to: ~p"/moderation/groups/#{group.id}/edit")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}

      {:error, :sudo_required} ->
        {:noreply, MythweaverWeb.Sudo.require(socket, "save", event_params)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, PermissionGrid.error_text(reason))}
    end
  end

  def handle_event("delete", params, socket) do
    group = socket.assigns.group
    members = Permissions.affected_users(group)

    case Permissions.delete_group(socket.assigns.current_scope, group) do
      {:ok, group} ->
        UserAuth.disconnect_users(members)

        {:noreply,
         socket
         |> put_flash(:info, deleted_flash(group))
         |> stream_delete(:groups, group)
         |> push_patch(to: ~p"/moderation/groups")}

      {:error, :sudo_required} ->
        {:noreply, MythweaverWeb.Sudo.require(socket, "delete", params)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, PermissionGrid.error_text(reason))}
    end
  end

  # The picker's boxes reset to the server's `checked` on every re-render (a search keystroke
  # included), so the server keeps the live selection.
  def handle_event("validate_members", params, socket) do
    {:noreply, assign(socket, member_ids: posted_ids(params))}
  end

  def handle_event("save_members", params, socket) do
    group = socket.assigns.group
    before = Permissions.affected_users(group)
    ids = posted_ids(params)

    case Permissions.set_group_members(socket.assigns.current_scope, group, ids) do
      {:ok, group} ->
        UserAuth.disconnect_users(Enum.uniq_by(before ++ Permissions.affected_users(group), & &1.id))
        {:noreply, socket |> assign_group_state() |> put_flash(:info, members_saved_flash())}

      {:error, :sudo_required} ->
        {:noreply, MythweaverWeb.Sudo.require(socket, "save_members", params)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, PermissionGrid.error_text(reason))}
    end
  end

  def handle_event("save_grants", params, socket) do
    group = socket.assigns.group

    case Permissions.set_group_grants(socket.assigns.current_scope, group, PermissionGrid.to_grants(params)) do
      {:ok, group} ->
        UserAuth.disconnect_users(Permissions.affected_users(group))
        {:noreply, socket |> assign_group_state() |> put_flash(:info, permissions_saved_flash())}

      {:error, :sudo_required} ->
        {:noreply, MythweaverWeb.Sudo.require(socket, "save_grants", params)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, PermissionGrid.error_text(reason))}
    end
  end

  defp stream_groups(socket) do
    groups = Permissions.list_groups(socket.assigns.current_scope)

    socket
    |> assign(groups_empty?: groups == [])
    |> stream(:groups, groups, reset: true)
  end

  defp not_found_flash do
    gettext_comment("Flash when the permission group in the link no longer exists.")
    dpgettext("admin", "status: the permission group in the link no longer exists", "Group not found")
  end

  defp saved_flash(group) do
    gettext_comment("Flash after a permission group is saved.")
    dpgettext("admin", "status: a permission group was saved", "%{group_name} saved", group_name: group.name)
  end

  defp deleted_flash(group) do
    gettext_comment("Flash after a permission group is deleted.")
    dpgettext("admin", "status: a permission group was deleted", "%{group_name} deleted", group_name: group.name)
  end

  defp members_saved_flash do
    gettext_comment("Flash after a permission group's members are saved.")
    dpgettext("admin", "status: a permission group's members were saved", "Members saved")
  end

  defp permissions_saved_flash do
    gettext_comment("Flash after permissions are saved.")
    dpgettext("admin", "status: permissions were saved", "Permissions saved")
  end

  defp delete_confirm(group) do
    gettext_comment("Confirm dialog before a permission group is deleted.")

    dpgettext("admin", "heading: confirm dialog before deleting a permission group", "Delete %{group_name}?",
      group_name: group.name
    )
  end

  defp locked_notice(key) do
    gettext_comment(
      "Shown on a permission group that holds a permission the viewer lacks; the placeholder is that permission's name."
    )

    dgettext("admin", "This group holds \"%{permission_name}\", which you don't hold, so you can't change it.",
      permission_name: Catalog.fetch!(key).label
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      div.group-editor-body:scope {
        display: contents;
      }

      .group-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .group-notice {
        margin: 0;
      }
    </style>

    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <MythweaverWeb.ModerationNav.nav current_scope={@current_scope} active="groups" />
      <.pane_layout>
        <:list
          id="groups-nav"
          label={dpgettext("admin", "aria label: list of permission groups", "Groups")}
        >
          <.pane_header title={dpgettext("admin", "heading: list of permission groups", "Groups")} />
          <.pane_actions>
            <.button variant="primary" patch={~p"/moderation/groups/new"} id="new-group">
              <.lucide name="plus" /> {dpgettext(
                "admin",
                "button: create a permission group",
                "New group"
              )}
            </.button>
          </.pane_actions>
          <.pane_items
            :let={group}
            id="groups"
            rows={@streams.groups}
            empty?={@groups_empty?}
            empty={dpgettext("admin", "empty state: no permission groups", "No groups yet")}
            selected_id={@selected_id}
            patch={fn group -> ~p"/moderation/groups/#{group.id}/edit" end}
          >
            <span class="pane-item-name">{group.name}</span>
            <span :if={group.system_key} class="pane-item-meta">
              {dpgettext("admin", "badge: built-in permission group", "System")}
            </span>
          </.pane_items>
        </:list>
        <:editor id="group-editor">
          <.pane_placeholder :if={@live_action == :index} id="group-placeholder">
            {dgettext("admin", "Select a group, or create a new one.")}
          </.pane_placeholder>
          <div :if={@live_action != :index} class="group-editor-body">
            <.panel_header sticky>
              {if @group,
                do: @group.name,
                else: dpgettext("admin", "heading: permission group not saved yet", "New group")}
              <:actions :if={@group && is_nil(@group.system_key) && is_nil(@locked_key)}>
                <.pane_delete id="delete-group" phx-click="delete" confirm={delete_confirm(@group)}>
                  {dpgettext("admin", "button: delete this permission group", "Delete")}
                </.pane_delete>
              </:actions>
            </.panel_header>

            <.pane_section :if={@locked_key}>
              <p id="group-locked-notice" class="group-notice">
                {locked_notice(@locked_key)}
              </p>
            </.pane_section>

            <.pane_section>
              <.changed_elsewhere
                :if={@changed_elsewhere?}
                id="group-changed-elsewhere"
                patch={@live_sync_path}
              />
              <.form
                for={@form}
                id="group-form"
                class="group-form"
                phx-hook="UnsavedChanges"
                data-saved={is_nil(@form.action)}
                phx-change="validate"
                phx-submit="save"
              >
                <.input
                  field={@form[:name]}
                  type="text"
                  label={dpgettext("admin", "field label: name of a permission group", "Name")}
                  id="group-form-name"
                  required
                />
                <.input
                  field={@form[:description]}
                  type="text"
                  label={
                    dpgettext(
                      "admin",
                      "field label: description of a permission group",
                      "Description (optional)"
                    )
                  }
                  id="group-form-description"
                />
                <.form_actions>
                  <.button patch={
                    if @group,
                      do: ~p"/moderation/groups/#{@group.id}/edit",
                      else: ~p"/moderation/groups"
                  }>
                    {dpgettext("admin", "button: discard edits to the permission group", "Cancel")}
                  </.button>
                  <.button type="submit" variant="primary" disabled={@locked_key != nil}>
                    {dpgettext("admin", "button: save the permission group", "Save")}
                  </.button>
                </.form_actions>
              </.form>
            </.pane_section>

            <.pane_section :if={@group && @group.system_key != :everyone}>
              <.section_header>
                {dpgettext("admin", "heading: members of a permission group", "Members")}
              </.section_header>
              <.form
                for={%{}}
                as={:members}
                id="group-members-form"
                class="group-form"
                phx-change="validate_members"
                phx-submit="save_members"
              >
                <.live_component
                  module={MythweaverWeb.MultiSelect}
                  id="group-members"
                  name="members[]"
                  label={dpgettext("admin", "field label: members of a permission group", "Members")}
                  options={@member_options}
                  selected={@member_ids}
                  empty={
                    dpgettext(
                      "admin",
                      "empty state: no accounts to add to a permission group",
                      "No accounts yet"
                    )
                  }
                  disabled={@locked_key != nil}
                />
                <.form_actions>
                  <.button
                    type="submit"
                    variant="primary"
                    id="group-members-save"
                    disabled={@locked_key != nil}
                  >
                    {dpgettext("admin", "button: save the permission group's members", "Save members")}
                  </.button>
                </.form_actions>
              </.form>
            </.pane_section>

            <.pane_section :if={@group && @group.system_key == :everyone}>
              <p id="group-everyone-notice" class="group-notice">
                {dgettext(
                  "admin",
                  "Everyone holds every account; its permissions apply to all users."
                )}
              </p>
            </.pane_section>

            <.pane_section :if={@group}>
              <.section_header>
                {dpgettext("admin", "heading: permissions of a permission group", "Permissions")}
              </.section_header>
              <PermissionGrid.grid
                id="group-grants"
                event="save_grants"
                grants={@grants}
                scope={@current_scope}
                disabled={@locked_key != nil}
              />
            </.pane_section>
          </div>
        </:editor>
      </.pane_layout>
      <MythweaverWeb.Sudo.modal :if={@sudo_prompt} prompt={@sudo_prompt} />
    </Layouts.app>
    """
  end

  # The members picker always posts a `""` sentinel.
  defp posted_ids(params), do: params |> Map.get("members", []) |> List.wrap() |> Enum.reject(&(&1 == ""))
end
