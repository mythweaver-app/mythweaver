defmodule MythweaverWeb.UserLive do
  @moduledoc """
  Users admin, the moderation panel's Users section (`/moderation/users`): the account list on the
  left, the selected account's form on the right, with links to the account's content
  (`MythweaverWeb.UserDataLive`) and moderation record (`MythweaverWeb.ModerationAccountLive`). Holders of
  `"users.manage"` reach it (`UserAuth.on_mount({:require_permission, "users.manage"}, …)`). An owner
  may add, edit, re-role, reset the password of, or delete any other account; any other holder may do
  so for any non-owner and cannot grant `:owner` (`Accounts.can_manage?/2`,
  `Accounts.assignable_roles/1`). Nobody may change their own role
  or delete themselves. `:index` selects nothing: the editor pane shows a placeholder until a user
  is picked.

  A passwordless current user (the auto-login admin) cannot add accounts: auto-login stops once a
  second account exists, which would lock them out.

  A `"groups.manage"` holder also sees the account's groups and its own permission overrides
  (`MythweaverWeb.PermissionGrid`). Role changes, password resets, deletion and permission changes
  ask for the viewer's password first (`MythweaverWeb.Sudo`).
  """
  use MythweaverWeb, :live_view

  import MythweaverWeb.BulkComponents
  import MythweaverWeb.Pane

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.Moderation
  alias Mythweaver.Permissions
  alias Mythweaver.Permissions.Catalog
  alias MythweaverWeb.Bulk
  alias MythweaverWeb.Bulk.Field
  alias MythweaverWeb.Bulk.Spec
  alias MythweaverWeb.LiveSync
  alias MythweaverWeb.PermissionGrid
  alias MythweaverWeb.UserAuth

  on_mount {MythweaverWeb.UserAuth, {:require_permission, "users.manage"}}
  on_mount MythweaverWeb.Sudo

  @live_opts [hash_password: false, validate_unique: false]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: dpgettext("admin", "page title: user accounts editor", "Users"),
       form: nil,
       password_form: nil,
       editing_user: nil,
       selected_id: nil,
       assignable_roles: Accounts.assignable_roles(socket.assigns.current_scope),
       manageable?: true,
       groups: [],
       user_group_ids: [],
       user_grants: %{},
       user_locked_key: nil
     )
     |> stream_configure(:users, dom_id: &"users-#{&1.id}")
     |> assign_filter()
     |> stream_users()
     |> attach_hook(:sudo_bulk, :handle_event, &sudo_bulk/3)
     |> Bulk.attach([bulk_spec()])
     |> LiveSync.attach_editor([:accounts], &sync/2)}
  end

  defp sync(socket, _kinds) do
    scope = socket.assigns.current_scope

    socket =
      socket
      |> stream_users()
      |> LiveSync.sync_open(:editing_user,
        fetch: &Accounts.get_user/1,
        clean?: LiveSync.clean?(socket.assigns.form),
        reload:
          &assign(&1,
            form: to_form(Accounts.change_user_profile(&2)),
            editing_user: &2,
            manageable?: Accounts.can_manage?(scope, &2)
          ),
        gone: ~p"/moderation/users",
        gone_message:
          (
            gettext_comment("Flash shown when the user open in the editor was deleted or moved by someone else.")
            dgettext("admin", "The user was deleted or moved elsewhere.")
          ),
        ignore: [:hashed_password]
      )

    if socket.assigns.editing_user, do: assign_permissions(socket), else: socket
  end

  # Bulk deletes and role changes need sudo mode; ask once up front rather than failing every row.
  # Attached before `Bulk.attach/2`, so it sees the event first; the replay goes to Bulk's hook.
  defp sudo_bulk(event, params, socket) when event in ["bulk_delete", "bulk_edit_save"] do
    if Accounts.sudo?(socket.assigns.current_scope),
      do: {:cont, socket},
      else: {:halt, MythweaverWeb.Sudo.require(socket, event, params, &Bulk.handle_event/3)}
  end

  defp sudo_bulk(_event, _params, socket), do: {:cont, socket}

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(form: nil, password_form: nil, editing_user: nil, selected_id: nil, manageable?: true)
    |> stream_users()
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(
      form: to_form(Accounts.change_user_registration(%User{}, %{}, @live_opts)),
      password_form: nil,
      editing_user: nil,
      selected_id: nil,
      manageable?: true
    )
    |> stream_users()
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Accounts.get_user(id) do
      nil ->
        socket
        |> put_flash(:error, not_found_flash())
        |> push_patch(to: ~p"/moderation/users")

      user ->
        socket
        |> assign(
          form: to_form(Accounts.change_user_profile(user)),
          password_form: to_form(Accounts.change_user_password(user, %{}, hash_password: false)),
          editing_user: user,
          selected_id: user.id,
          manageable?: Accounts.can_manage?(socket.assigns.current_scope, user)
        )
        |> assign_permissions()
        |> stream_users()
    end
  end

  defp assign_permissions(socket) do
    scope = socket.assigns.current_scope
    user = socket.assigns.editing_user

    if Scope.can?(scope, "groups.manage") do
      locked =
        case Permissions.held_rows_ok(scope, user) do
          :ok -> nil
          {:error, {:not_held, key}} -> key
        end

      assign(socket,
        groups: Enum.reject(Permissions.list_groups(scope), &(&1.system_key == :everyone)),
        user_group_ids: Permissions.group_ids(user),
        user_grants: Permissions.grants_for(user),
        user_locked_key: locked
      )
    else
      socket
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, socket |> assign_filter(params) |> stream_users()}
  end

  def handle_event("validate", %{"user" => params}, socket) do
    changeset =
      case socket.assigns.editing_user do
        nil -> Accounts.change_user_registration(%User{}, params, @live_opts)
        user -> Accounts.change_user_profile(user, params, validate_unique: false)
      end

    changeset = if params["role"], do: User.role_changeset(changeset, params["role"]), else: changeset

    {:noreply, assign(socket, form: to_form(Map.put(changeset, :action, :validate)))}
  end

  def handle_event("save", %{"user" => params} = event_params, socket) do
    scope = socket.assigns.current_scope
    editing = socket.assigns.editing_user

    result =
      case editing do
        nil -> Accounts.create_user(scope, params)
        user -> Accounts.update_user(scope, user, params)
      end

    case result do
      {:ok, user} ->
        if editing && user.role != editing.role,
          do: UserAuth.disconnect_sessions(Accounts.session_tokens(user))

        {:noreply,
         socket
         |> maybe_refresh_scope(user)
         |> put_flash(:info, saved_flash(user))
         |> push_patch(to: ~p"/moderation/users/#{user.id}/edit")}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}

      {:error, :sudo_required} ->
        {:noreply, MythweaverWeb.Sudo.require(socket, "save", event_params)}

      {:error, :own_role} ->
        {:noreply, put_flash(socket, :error, own_role_flash())}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(:error, invalid_flash())}
    end
  end

  def handle_event("validate_password", %{"user" => params}, socket) do
    changeset =
      socket.assigns.editing_user
      |> Accounts.change_user_password(params, hash_password: false)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, password_form: to_form(changeset))}
  end

  def handle_event("reset_password", %{"user" => params} = event_params, socket) do
    case Accounts.reset_user_password(socket.assigns.current_scope, socket.assigns.editing_user, params) do
      {:ok, {user, tokens}} ->
        UserAuth.disconnect_sessions(tokens)

        {:noreply,
         socket
         |> assign(password_form: to_form(Accounts.change_user_password(user, %{}, hash_password: false)))
         |> put_flash(:info, password_reset_flash())}

      {:error, :self} ->
        {:noreply, put_flash(socket, :error, own_password_flash())}

      {:error, :sudo_required} ->
        {:noreply, MythweaverWeb.Sudo.require(socket, "reset_password", event_params)}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}

      {:error, changeset} ->
        {:noreply, assign(socket, password_form: to_form(changeset))}
    end
  end

  def handle_event("delete", %{"id" => id} = params, socket) do
    case Accounts.get_user(id) do
      nil ->
        {:noreply, socket}

      user ->
        case Accounts.delete_user(socket.assigns.current_scope, user) do
          {:ok, {user, tokens}} ->
            UserAuth.disconnect_sessions(tokens)

            {:noreply,
             socket
             |> put_flash(:info, deleted_flash(user))
             |> push_patch(to: ~p"/moderation/users")}

          {:error, :self} ->
            {:noreply, put_flash(socket, :error, own_delete_flash())}

          {:error, :sudo_required} ->
            {:noreply, MythweaverWeb.Sudo.require(socket, "delete", params)}

          {:error, :unauthorized} ->
            {:noreply, flash_unauthorized(socket)}
        end
    end
  end

  # The picker's boxes reset to the server's `checked` on every re-render (a search keystroke
  # included), so the server keeps the live selection.
  def handle_event("validate_groups", params, socket) do
    {:noreply, assign(socket, user_group_ids: posted_group_ids(params))}
  end

  def handle_event("save_groups", params, socket) do
    user = socket.assigns.editing_user
    ids = posted_group_ids(params)

    case Permissions.set_user_groups(socket.assigns.current_scope, user, ids) do
      {:ok, user} ->
        UserAuth.disconnect_users([user])
        {:noreply, socket |> assign_permissions() |> put_flash(:info, groups_saved_flash())}

      {:error, :sudo_required} ->
        {:noreply, MythweaverWeb.Sudo.require(socket, "save_groups", params)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, PermissionGrid.error_text(reason))}
    end
  end

  def handle_event("save_grants", params, socket) do
    user = socket.assigns.editing_user

    case Permissions.set_user_grants(socket.assigns.current_scope, user, PermissionGrid.to_grants(params)) do
      {:ok, user} ->
        UserAuth.disconnect_users([user])
        {:noreply, socket |> assign_permissions() |> put_flash(:info, permissions_saved_flash())}

      {:error, :sudo_required} ->
        {:noreply, MythweaverWeb.Sudo.require(socket, "save_grants", params)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, PermissionGrid.error_text(reason))}
    end
  end

  defp self?(%{user: %User{id: id}}, %User{id: id}), do: true
  defp self?(_scope, _user), do: false

  defp maybe_refresh_scope(socket, user) do
    if self?(socket.assigns.current_scope, user),
      do: assign(socket, current_scope: %{socket.assigns.current_scope | user: user}),
      else: socket
  end

  defp bulk_spec do
    %Spec{
      name: :users,
      count_label:
        &dpngettext(
          "admin",
          "count phrase: user accounts affected by a bulk action",
          "%{user_count} user",
          "%{user_count} users",
          &1,
          user_count: Mythweaver.Format.number(&1)
        ),
      ids: & &1.assigns.users_ids,
      get: fn _scope, id -> Accounts.get_user(id) end,
      update: &Accounts.update_user/3,
      delete: &delete_user/2,
      title: &User.display_name/1,
      refresh: &stream_users/1,
      open_id: & &1.assigns.selected_id,
      index_path: ~p"/moderation/users",
      edit_path: &~p"/moderation/users/#{&1}/edit",
      fields: [
        %Field{
          key: :role,
          label: dpgettext("admin", "field label: role of a user account", "Role"),
          type: :select,
          options: fn scope -> role_options(Accounts.assignable_roles(scope)) end
        }
      ]
    }
  end

  defp delete_user(scope, user) do
    with {:ok, {user, tokens}} <- Accounts.delete_user(scope, user) do
      UserAuth.disconnect_sessions(tokens)
      {:ok, user}
    end
  end

  defp stream_users(socket) do
    stream_search(socket, :users, Accounts.list_users(), fn user ->
      [user.email, user.handle, user.nickname || ""]
    end)
  end

  defp role_label(:owner), do: dpgettext("admin", "option: role of a user account", "Owner")
  defp role_label(:user), do: dpgettext("admin", "option: role of a user account", "User")

  defp role_options(roles), do: Enum.map(roles, &{role_label(&1), &1})

  defp not_found_flash do
    gettext_comment("Flash when the user account in the link no longer exists.")
    dpgettext("admin", "status: the user account in the link no longer exists", "User not found")
  end

  defp saved_flash(user) do
    gettext_comment("Flash after a user account is saved.")
    dpgettext("admin", "status: a user account was saved", "%{user_name} saved", user_name: User.display_name(user))
  end

  defp deleted_flash(user) do
    gettext_comment("Flash after a user account is deleted.")
    dpgettext("admin", "status: a user account was deleted", "%{user_name} deleted", user_name: User.display_name(user))
  end

  defp own_role_flash do
    gettext_comment("Flash when an admin tries to change their own role.")
    dgettext("admin", "You can't change your own role")
  end

  defp invalid_flash do
    gettext_comment("Flash when the user account form has errors.")
    dgettext("admin", "Could not save — see the highlighted fields")
  end

  defp password_reset_flash do
    gettext_comment("Flash after an admin resets another account's password.")
    dpgettext("admin", "status: an admin reset an account's password", "Password reset")
  end

  defp own_password_flash do
    gettext_comment("Flash when an admin tries to reset their own password here.")
    dgettext("admin", "Change your own password in Account settings")
  end

  defp own_delete_flash do
    gettext_comment("Flash when an admin tries to delete their own account.")
    dgettext("admin", "You can't delete your own account")
  end

  defp groups_saved_flash do
    gettext_comment("Flash after a user account's permission groups are saved.")
    dpgettext("admin", "status: a user account's permission groups were saved", "Groups saved")
  end

  defp permissions_saved_flash do
    gettext_comment("Flash after permissions are saved.")
    dpgettext("admin", "status: permissions were saved", "Permissions saved")
  end

  defp delete_confirm(user) do
    gettext_comment("Confirm dialog before a user account is deleted.")

    dpgettext("admin", "heading: confirm dialog before deleting a user account", "Delete %{user_name}?",
      user_name: User.display_name(user)
    )
  end

  defp passwordless_notice do
    gettext_comment(
      "Shown to the passwordless auto-login admin on the new-user form; the placeholder links to the account settings page."
    )

    rich(
      dgettext(
        "admin",
        "Set a password in %{settings_link} before adding users — auto-login stops once a second account exists.",
        settings_link:
          navigate_link(
            dpgettext("admin", "link: the viewer's account settings page", "Account settings"),
            ~p"/users/settings"
          )
      )
    )
  end

  defp own_role_notice(user) do
    gettext_comment(
      "Shown instead of the role field when an admin edits their own account; the placeholder is the role name."
    )

    dgettext("admin", "Role: %{role_name}. You can't change your own role.", role_name: role_label(user.role))
  end

  defp locked_notice(key) do
    gettext_comment(
      "Shown on an account that holds a permission the viewer lacks; the placeholder is that permission's name."
    )

    dgettext(
      "admin",
      "This account holds \"%{permission_name}\", which you don't hold, so you can't change its permissions.",
      permission_name: Catalog.fetch!(key).label
    )
  end

  # Which of the editor header's moderation links the scope sees for `user` (nil: none).
  defp moderation_flags(scope, user, manageable?) do
    can? = &Scope.can?(scope, &1)
    record? = user != nil and Moderation.authorize_record(scope, user) == :ok

    %{
      editing_self?: self?(scope, user),
      content?: record? and manageable? and can?.("moderation.content.view"),
      lookup?: record?,
      # A ban needs a target the scope may sanction: never an owner or the moderator themself.
      ban?:
        record? and Moderation.sanctionable(scope, user) == :ok and
          (can?.("moderation.accounts.sanction") or can?.("moderation.fingerprints"))
    }
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, moderation_flags(assigns.current_scope, assigns.editing_user, assigns.manageable?))

    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      /* The editor slot's root. `pane_layout`'s `<section>` carries no marker from this block, so
         without it `<.form>` (which carries none either) would sit outside this scope. */
      div.user-editor-body:scope {
        display: contents;
      }

      .user-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .user-form label {
        display: block;
      }

      .user-notice {
        margin: 0;
      }
    </style>

    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <MythweaverWeb.ModerationNav.nav current_scope={@current_scope} active="users" />
      <.pane_layout>
        <:list id="users-nav" label={dpgettext("admin", "aria label: list of user accounts", "Users")}>
          <.pane_header title={dpgettext("admin", "heading: list of user accounts", "Users")} />
          <.pane_actions>
            <.button variant="primary" patch={~p"/moderation/users/new"} id="new-user">
              <.lucide name="plus" /> {dpgettext("admin", "button: create a user account", "New user")}
            </.button>
            <.bulk_toggle bulk={@bulk} id="users-bulk-toggle" />
          </.pane_actions>
          <.bulk_bar bulk={@bulk} id="users-bulk" />
          <.pane_search
            id="user-filter"
            form={@filter_form}
            placeholder={
              dpgettext(
                "admin",
                "placeholder: search field over the user accounts list",
                "Email, handle or nickname"
              )
            }
          />
          <.pane_items
            :let={user}
            bulk={@bulk}
            bulk_list="users"
            id="users"
            rows={@streams.users}
            empty?={@users_empty?}
            empty={
              if @query == "",
                do: dpgettext("admin", "empty state: no user accounts", "No users yet"),
                else:
                  dpgettext(
                    "admin",
                    "empty state: no user account matches the search",
                    "No users match this search"
                  )
            }
            selected_id={@selected_id}
            patch={fn user -> ~p"/moderation/users/#{user.id}/edit" end}
          >
            <span class="pane-item-name">{User.display_name(user)}</span>
            <span :if={user.nickname} class="pane-item-meta">@{user.handle}</span>
            <span class="pane-item-meta">{user.email}</span>
            <span class="pane-item-meta">{role_label(user.role)}</span>
          </.pane_items>
        </:list>
        <:editor id="user-editor">
          <.pane_placeholder :if={@live_action == :index} id="user-placeholder">
            {dgettext("admin", "Select a user, or create a new one.")}
          </.pane_placeholder>
          <div :if={@live_action != :index} class="user-editor-body">
            <.panel_header sticky>
              {if @editing_user,
                do: User.display_name(@editing_user),
                else: dpgettext("admin", "heading: user account not saved yet", "New user")}
              <:actions :if={@editing_user}>
                <.button
                  :if={@content?}
                  size="sm"
                  navigate={~p"/moderation/users/#{@editing_user.id}/data"}
                  id="user-open-data"
                >
                  <.lucide name="folder-open" />
                  {dpgettext("admin", "button: open this account's chats and content", "Content")}
                </.button>
                <.button
                  :if={@lookup?}
                  size="sm"
                  navigate={~p"/moderation/users/#{@editing_user.id}/record"}
                  id="user-lookup"
                >
                  <.lucide name="search" />
                  {dpgettext("admin", "button: open this account's moderation record", "Lookup")}
                </.button>
                <.button
                  :if={@ban?}
                  size="sm"
                  danger
                  navigate={~p"/moderation/users/#{@editing_user.id}/record#account-bans"}
                  id="user-ban"
                >
                  <.lucide name="ban" />
                  {dpgettext(
                    "admin",
                    "button: open the ban form on this account's moderation record",
                    "Ban"
                  )}
                </.button>
                <.pane_delete
                  :if={@manageable? && !@editing_self?}
                  id="delete-user"
                  phx-click="delete"
                  phx-value-id={@editing_user.id}
                  confirm={delete_confirm(@editing_user)}
                >
                  {dpgettext("admin", "button: delete this user account", "Delete")}
                </.pane_delete>
              </:actions>
            </.panel_header>

            <%= cond do %>
              <% @editing_user && not @manageable? -> %>
                <.pane_section>
                  <p id="user-owner-notice" class="user-notice">
                    {dgettext("admin", "Only an owner can change an owner's account.")}
                  </p>
                </.pane_section>
              <% is_nil(@editing_user) and is_nil(@current_scope.user.hashed_password) -> %>
                <.pane_section>
                  <p id="users-passwordless-notice" class="user-notice">
                    {passwordless_notice()}
                  </p>
                </.pane_section>
              <% true -> %>
                <.pane_section>
                  <.changed_elsewhere
                    :if={@changed_elsewhere?}
                    id="user-changed-elsewhere"
                    patch={@live_sync_path}
                  />
                  <.form
                    for={@form}
                    id="user-form"
                    class="user-form"
                    phx-hook="UnsavedChanges"
                    data-saved={is_nil(@form.action)}
                    phx-change="validate"
                    phx-submit="save"
                  >
                    <.input
                      field={@form[:email]}
                      type="email"
                      label={
                        dpgettext("admin", "field label: email address of a user account", "Email")
                      }
                      id="user-form-email"
                      required
                    />
                    <.input
                      field={@form[:handle]}
                      type="text"
                      label={dpgettext("admin", "field label: handle of a user account", "Handle")}
                      id="user-form-handle"
                      autocomplete="off"
                      required
                    />
                    <.input
                      field={@form[:nickname]}
                      type="text"
                      label={
                        dpgettext(
                          "admin",
                          "field label: nickname of a user account",
                          "Nickname (optional)"
                        )
                      }
                      id="user-form-nickname"
                    />
                    <%= if @editing_self? do %>
                      <p id="user-role-self" class="user-notice">
                        {own_role_notice(@editing_user)}
                      </p>
                    <% else %>
                      <.input
                        field={@form[:role]}
                        type="select"
                        label={dpgettext("admin", "field label: role of a user account", "Role")}
                        id="user-form-role"
                        options={role_options(@assignable_roles)}
                      />
                    <% end %>
                    <%= if is_nil(@editing_user) do %>
                      <.input
                        field={@form[:password]}
                        type="password"
                        label={
                          dpgettext(
                            "admin",
                            "field label: new account password, with its minimum length",
                            "Password (at least 12 characters)"
                          )
                        }
                        id="user-form-password"
                        autocomplete="new-password"
                        required
                      />
                      <.input
                        field={@form[:password_confirmation]}
                        type="password"
                        label={
                          dpgettext(
                            "admin",
                            "field label: repeat the new account's password",
                            "Confirm password"
                          )
                        }
                        id="user-form-password_confirmation"
                        autocomplete="new-password"
                        required
                      />
                    <% end %>
                    <.form_actions>
                      <.button patch={
                        if @editing_user,
                          do: ~p"/moderation/users/#{@editing_user.id}/edit",
                          else: ~p"/moderation/users"
                      }>
                        {dpgettext("admin", "button: discard edits to the user account", "Cancel")}
                      </.button>
                      <.button type="submit" variant="primary">
                        {dpgettext("admin", "button: save the user account", "Save")}
                      </.button>
                    </.form_actions>
                  </.form>
                </.pane_section>
            <% end %>

            <%= if @editing_user && @manageable? do %>
              <.pane_section :if={@editing_self?}>
                <p class="user-notice">
                  <.link navigate={~p"/users/settings"} id="user-settings-link">
                    {dgettext("admin", "Change your password in Account settings")}
                  </.link>
                </p>
              </.pane_section>
              <.pane_section :if={!@editing_self?}>
                <.section_header>
                  {dpgettext(
                    "admin",
                    "heading: form that resets another account's password",
                    "Reset password"
                  )}
                </.section_header>
                <.form
                  for={@password_form}
                  id="user-password-form"
                  class="user-form"
                  phx-change="validate_password"
                  phx-submit="reset_password"
                >
                  <.input
                    field={@password_form[:password]}
                    type="password"
                    label={
                      dpgettext(
                        "admin",
                        "field label: new password for another account",
                        "New password"
                      )
                    }
                    id="user-password-form-password"
                    autocomplete="new-password"
                    required
                  />
                  <.input
                    field={@password_form[:password_confirmation]}
                    type="password"
                    label={
                      dpgettext(
                        "admin",
                        "field label: repeat the new password for another account",
                        "Confirm new password"
                      )
                    }
                    id="user-password-form-password_confirmation"
                    autocomplete="new-password"
                    required
                  />
                  <.form_actions>
                    <.button type="submit" variant="primary">
                      {dpgettext(
                        "admin",
                        "button: reset another account's password",
                        "Reset password"
                      )}
                    </.button>
                  </.form_actions>
                </.form>
              </.pane_section>
            <% end %>

            <%= if @editing_user && @manageable? && Scope.can?(@current_scope, "groups.manage") do %>
              <.pane_section :if={@user_locked_key}>
                <p id="user-locked-notice" class="user-notice">
                  {locked_notice(@user_locked_key)}
                </p>
              </.pane_section>
              <.pane_section>
                <.section_header>
                  {dpgettext(
                    "admin",
                    "heading: permission groups a user account belongs to",
                    "Groups"
                  )}
                </.section_header>
                <.form
                  for={%{}}
                  as={:groups}
                  id="user-groups-form"
                  class="user-form"
                  phx-change="validate_groups"
                  phx-submit="save_groups"
                >
                  <.live_component
                    module={MythweaverWeb.MultiSelect}
                    id="user-groups"
                    name="groups[]"
                    label={
                      dpgettext(
                        "admin",
                        "field label: permission groups a user account belongs to",
                        "Groups"
                      )
                    }
                    options={Enum.map(@groups, &{&1.name, &1.id})}
                    selected={@user_group_ids}
                    empty={dpgettext("admin", "empty state: no permission groups", "No groups yet")}
                  />
                  <.form_actions>
                    <.button type="submit" variant="primary" id="user-groups-save">
                      {dpgettext(
                        "admin",
                        "button: save the account's permission groups",
                        "Save groups"
                      )}
                    </.button>
                  </.form_actions>
                </.form>
              </.pane_section>
              <.pane_section>
                <.section_header>
                  {dpgettext(
                    "admin",
                    "heading: a user account's own permission overrides",
                    "Overrides"
                  )}
                </.section_header>
                <PermissionGrid.grid
                  id="user-grants-form"
                  event="save_grants"
                  grants={@user_grants}
                  scope={@current_scope}
                  disabled={@user_locked_key != nil}
                />
              </.pane_section>
            <% end %>
          </div>
        </:editor>
      </.pane_layout>
      <MythweaverWeb.Sudo.modal :if={@sudo_prompt} prompt={@sudo_prompt} />
    </Layouts.app>
    """
  end

  # The groups picker always posts a `""` sentinel.
  defp posted_group_ids(params), do: params |> Map.get("groups", []) |> List.wrap() |> Enum.reject(&(&1 == ""))
end
