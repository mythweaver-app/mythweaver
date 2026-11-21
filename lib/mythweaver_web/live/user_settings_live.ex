defmodule MythweaverWeb.UserSettingsLive do
  @moduledoc """
  The signed-in user's own account: email, handle and nickname, the password, and MCP access tokens.
  Changing the email asks for the current password when there is one. The password form validates
  live, then posts to `UserSessionController.update_password/2`, which expires every other session
  and logs this one back in. A passwordless user (the auto-login admin) sets a first password here.
  Creating an MCP token needs sudo; its secret is shown once, until dismissed.
  """
  use MythweaverWeb, :live_view

  import MythweaverWeb.Pane

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Format
  alias Mythweaver.MCP
  alias Mythweaver.MCP.Token
  alias MythweaverWeb.LiveSync

  on_mount MythweaverWeb.Sudo

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    {:ok,
     socket
     |> assign(
       page_title: dpgettext("accounts", "page title: account settings page", "Account settings"),
       trigger_submit: false,
       changed_elsewhere?: false
     )
     |> assign_user(user)
     |> assign(mcp_token_form: to_form(MCP.change_token(%Token{})), mcp_secret: nil)
     |> stream_configure(:mcp_tokens, dom_id: &"mcp-tokens-#{&1.id}")
     |> assign_mcp_tokens()
     |> LiveSync.attach([:accounts], &sync/2)}
  end

  defp sync(socket, _kinds) do
    socket = assign_mcp_tokens(socket)
    held = socket.assigns.current_scope.user
    fresh = Accounts.get_user(held.id)

    cond do
      is_nil(fresh) -> socket
      not LiveSync.changed?(held, fresh, [:hashed_password]) -> socket
      is_nil(socket.assigns.profile_form.action) -> assign_user(socket, fresh)
      true -> assign(socket, changed_elsewhere?: true)
    end
  end

  defp assign_user(socket, user) do
    assign(socket,
      current_scope: %{socket.assigns.current_scope | user: user},
      has_password?: not is_nil(user.hashed_password),
      profile_form: to_form(Accounts.change_user_profile(user)),
      password_form: to_form(Accounts.change_user_password(user, %{}, hash_password: false))
    )
  end

  defp assign_mcp_tokens(socket) do
    scope = socket.assigns.current_scope
    tokens = MCP.list_tokens(scope)

    socket
    |> assign(mcp_tokens_empty?: tokens == [], mcp_calls: MCP.list_calls(scope, Enum.map(tokens, & &1.id)))
    |> stream(:mcp_tokens, tokens, reset: true)
  end

  @impl true
  def handle_event("validate_profile", %{"user" => params}, socket) do
    changeset =
      socket.assigns.current_scope.user
      |> Accounts.change_user_profile(params, validate_unique: false)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, profile_form: to_form(changeset))}
  end

  def handle_event("save_profile", %{"user" => params}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.update_user_profile(user, params["current_password"], params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign_user(user)
         |> assign(changed_elsewhere?: false)
         |> put_flash(:info, message(:account_saved))}

      {:error, changeset} ->
        {:noreply, assign(socket, profile_form: to_form(changeset))}
    end
  end

  def handle_event("reload_profile", _params, socket) do
    case Accounts.get_user(socket.assigns.current_scope.user.id) do
      nil -> {:noreply, socket}
      user -> {:noreply, socket |> assign_user(user) |> assign(changed_elsewhere?: false)}
    end
  end

  def handle_event("validate_password", %{"user" => params}, socket) do
    {:noreply, assign(socket, password_form: to_form(password_changeset(socket, params, :validate)))}
  end

  def handle_event("save_password", %{"user" => params}, socket) do
    changeset = password_changeset(socket, params, :insert)

    if changeset.valid? do
      {:noreply, assign(socket, password_form: to_form(changeset), trigger_submit: true)}
    else
      {:noreply, assign(socket, password_form: to_form(changeset))}
    end
  end

  def handle_event("validate_mcp_token", %{"token" => params}, socket) do
    changeset = %Token{} |> MCP.change_token(params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, mcp_token_form: to_form(changeset))}
  end

  def handle_event("create_mcp_token", %{"token" => params} = event_params, socket) do
    case MCP.create_token(socket.assigns.current_scope, params) do
      {:ok, _token, secret} ->
        {:noreply,
         socket
         |> assign(mcp_secret: secret, mcp_token_form: to_form(MCP.change_token(%Token{})))
         |> assign_mcp_tokens()
         |> put_flash(:info, message(:token_created))}

      {:error, :sudo_required} ->
        {:noreply, MythweaverWeb.Sudo.require(socket, "create_mcp_token", event_params)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, message(:mcp_off))}

      {:error, changeset} ->
        {:noreply, assign(socket, mcp_token_form: to_form(changeset))}
    end
  end

  def handle_event("dismiss_mcp_secret", _params, socket) do
    {:noreply, assign(socket, mcp_secret: nil)}
  end

  def handle_event("revoke_mcp_token", %{"id" => id}, socket) do
    _ = MCP.revoke_token(socket.assigns.current_scope, id)
    {:noreply, assign_mcp_tokens(socket)}
  end

  defp message(:account_saved) do
    gettext_comment("Flash after saving the profile form on the account settings page.")
    dpgettext("accounts", "status: the account profile was saved", "Account saved")
  end

  defp message(:token_created) do
    gettext_comment("Flash after creating an MCP access token; its secret shows once below.")
    dpgettext("accounts", "status: a new MCP access token was created", "Token created")
  end

  defp message(:mcp_off) do
    gettext_comment("Flash when creating an MCP token while an administrator has turned MCP off for the account.")
    dgettext("accounts", "MCP access is turned off for your account.")
  end

  defp revoke_confirm(token_name) do
    gettext_comment("Confirm dialog before revoking an MCP access token.")
    dgettext("accounts", "Revoke %{token_name}? Clients using it stop working.", token_name: token_name)
  end

  defp mcp_intro do
    gettext_comment(
      "The endpoint is the server's MCP URL and the header is the literal HTTP header Authorization: Bearer <token>, both shown as code."
    )

    rich(
      dgettext(
        "accounts",
        "Connect AI clients such as Claude, Cursor or Codex to Mythweaver over MCP. The endpoint is %{endpoint}; clients send %{auth_header}. A read-only token sees only reading tools. A full-access token can use every tool but never your site administration or moderation permissions; a site token, if you hold them, can. Write tools run as soon as the client calls them.",
        endpoint: code(url(~p"/mcp")),
        auth_header: code("Authorization: Bearer <token>")
      )
    )
  end

  defp access_label(:read_only), do: dpgettext("accounts", "status: access level of an MCP token", "Read only")
  defp access_label(:full), do: dpgettext("accounts", "status: access level of an MCP token", "Full access")
  defp access_label(:site), do: dpgettext("accounts", "status: access level of an MCP token", "Full access + site")

  defp access_options(scope) do
    options = [
      {dpgettext("accounts", "option: access level of a new MCP token", "Read only"), "read_only"},
      {dpgettext("accounts", "option: access level of a new MCP token", "Full access"), "full"}
    ]

    if MCP.site_access?(scope),
      do:
        options ++
          [
            {dpgettext(
               "accounts",
               "option: access level of a new MCP token",
               "Full access, including site administration"
             ), "site"}
          ],
      else: options
  end

  # Only a save checks the current password, so typing never counts as a failed attempt.
  defp password_changeset(socket, params, action) do
    changeset = Accounts.change_user_password(socket.assigns.current_scope.user, params, hash_password: false)

    changeset =
      if action == :insert,
        do: Accounts.validate_current_password(changeset, params["current_password"]),
        else: changeset

    Map.put(changeset, :action, action)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      div.user-settings:scope {
        flex: 1 1 auto;
        min-height: 0;
        overflow-y: auto;
        margin: var(--panel-gap);
        background: var(--card);
        border: 1px solid var(--border);
        border-radius: var(--radius-3);
        box-shadow: var(--elevation-lg);
      }

      .user-settings-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
        max-inline-size: 32rem;
      }

      .user-settings-form label {
        display: block;
      }

      .mcp-intro,
      .mcp-token-secret {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
        max-inline-size: 48rem;
        margin-block-end: var(--size-3);
      }

      .mcp-config-example {
        overflow-x: auto;
        padding: var(--size-2);
        background: var(--surface-1);
        border-radius: var(--radius-2);
        font-size: var(--font-size-0);
      }

      .mcp-tokens {
        list-style: none;
        padding: 0;
        margin-block: var(--size-3) 0;
      }

      .mcp-tokens li {
        display: flex;
        gap: var(--size-2);
        align-items: center;
        padding-block: var(--size-1);
      }

      .mcp-token-name {
        font-weight: 600;
      }

      .mcp-token-meta {
        flex: 1 1 auto;
        color: var(--muted-foreground);
        font-size: var(--font-size-0);
      }
    </style>

    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="user-settings">
        <.panel_header sticky>
          {dpgettext("accounts", "heading: account settings page", "Account settings")}
          <:actions :if={MythweaverWeb.ModerationNav.home(@current_scope)}>
            <.button
              size="sm"
              navigate={MythweaverWeb.ModerationNav.home(@current_scope)}
              id="moderation-link"
            >
              <.lucide name="shield" /> {dpgettext(
                "accounts",
                "button: open the moderation pages",
                "Moderation"
              )}
            </.button>
          </:actions>
        </.panel_header>
        <.pane_section>
          <.section_header>
            {dpgettext("accounts", "heading: account profile section", "Profile")}
          </.section_header>
          <.changed_elsewhere
            :if={@changed_elsewhere?}
            id="profile-changed-elsewhere"
            phx-click="reload_profile"
          />
          <.form
            for={@profile_form}
            id="profile-form"
            class="user-settings-form"
            phx-hook="UnsavedChanges"
            data-saved={is_nil(@profile_form.action)}
            phx-change="validate_profile"
            phx-submit="save_profile"
          >
            <.input
              field={@profile_form[:email]}
              type="email"
              label={dpgettext("accounts", "field label: account email address", "Email")}
              id="profile-form-email"
              autocomplete="username"
              required
            />
            <.input
              field={@profile_form[:handle]}
              type="text"
              label={dpgettext("accounts", "field label: account's unique public handle", "Handle")}
              id="profile-form-handle"
              autocomplete="off"
              required
            />
            <.input
              field={@profile_form[:nickname]}
              type="text"
              label={
                dpgettext(
                  "accounts",
                  "field label: account's optional display name",
                  "Nickname (optional)"
                )
              }
              id="profile-form-nickname"
            />
            <.input
              :if={@has_password?}
              field={@profile_form[:current_password]}
              type="password"
              label={
                dpgettext(
                  "accounts",
                  "field label: current password, asked for only when the email changes",
                  "Current password (needed to change email)"
                )
              }
              id="profile-form-current_password"
              autocomplete="current-password"
              value=""
            />
            <.form_actions>
              <.button type="submit" variant="primary" id="profile-form-save">
                {dpgettext("accounts", "button: save the account profile form", "Save")}
              </.button>
            </.form_actions>
          </.form>
        </.pane_section>
        <.pane_section>
          <.section_header>
            {if @has_password?,
              do:
                dpgettext(
                  "accounts",
                  "heading: section for changing the account password",
                  "Change password"
                ),
              else:
                dpgettext(
                  "accounts",
                  "heading: section for setting a first account password",
                  "Set a password"
                )}
          </.section_header>
          <.form
            for={@password_form}
            id="password-form"
            class="user-settings-form"
            action={~p"/users/update-password"}
            method="post"
            phx-change="validate_password"
            phx-submit="save_password"
            phx-trigger-action={@trigger_submit}
          >
            <.input
              :if={@has_password?}
              field={@password_form[:current_password]}
              type="password"
              label={
                dpgettext(
                  "accounts",
                  "field label: the account's current password",
                  "Current password"
                )
              }
              id="password-form-current_password"
              autocomplete="current-password"
              required
            />
            <.input
              field={@password_form[:password]}
              type="password"
              label={
                dpgettext(
                  "accounts",
                  "field label: new account password, with its minimum length",
                  "New password (at least 12 characters)"
                )
              }
              id="password-form-password"
              autocomplete="new-password"
              required
            />
            <.input
              field={@password_form[:password_confirmation]}
              type="password"
              label={
                dpgettext("accounts", "field label: repeat the new password", "Confirm new password")
              }
              id="password-form-password_confirmation"
              autocomplete="new-password"
              required
            />
            <.form_actions>
              <.button type="submit" variant="primary" id="password-form-save">
                {if @has_password?,
                  do:
                    dpgettext(
                      "accounts",
                      "button: save the changed account password",
                      "Change password"
                    ),
                  else: dpgettext("accounts", "button: save a first account password", "Set password")}
              </.button>
            </.form_actions>
          </.form>
        </.pane_section>
        <.pane_section>
          <.section_header>
            {dpgettext("accounts", "heading: account section for MCP access tokens", "MCP access")}
          </.section_header>
          <%= if Scope.can?(@current_scope, "mcp.use") do %>
            <div class="mcp-intro">
              <p>{mcp_intro()}</p>
              <pre id="mcp-config-example" class="mcp-config-example" phx-no-curly-interpolation>{"mcpServers": {"mythweaver": {"type": "http", "url": "<%= url(~p"/mcp") %>", "headers": {"Authorization": "Bearer YOUR_TOKEN"}}}}</pre>
            </div>
            <.form
              for={@mcp_token_form}
              id="mcp-token-form"
              class="user-settings-form"
              phx-change="validate_mcp_token"
              phx-submit="create_mcp_token"
            >
              <.input
                field={@mcp_token_form[:name]}
                type="text"
                label={
                  dpgettext("accounts", "field label: name of a new MCP access token", "Token name")
                }
                id="mcp-token-form-name"
                required
              />
              <.input
                field={@mcp_token_form[:access]}
                type="select"
                label={
                  dpgettext("accounts", "field label: access level of a new MCP token", "Access")
                }
                id="mcp-token-form-access"
                options={access_options(@current_scope)}
              />
              <.form_actions>
                <.button type="submit" variant="primary" id="mcp-token-form-save">
                  {dpgettext("accounts", "button: create an MCP access token", "Create token")}
                </.button>
              </.form_actions>
            </.form>
          <% else %>
            <p id="mcp-disabled">
              {dgettext(
                "accounts",
                "MCP access is turned off for this account by an administrator. Existing tokens are listed so you can revoke them."
              )}
            </p>
          <% end %>
          <div :if={@mcp_secret} id="mcp-token-secret" class="mcp-token-secret">
            <p>{dgettext("accounts", "Copy this token now; it is not shown again.")}</p>
            <.input
              type="text"
              name="mcp_secret"
              id="mcp-token-secret-value"
              value={@mcp_secret}
              readonly
            />
            <div>
              <.button phx-click="dismiss_mcp_secret" id="mcp-token-secret-done">
                {dpgettext("accounts", "button: hide the new MCP token secret", "Done")}
              </.button>
            </div>
          </div>
          <p :if={@mcp_tokens_empty?} id="mcp-tokens-empty">
            {dpgettext("accounts", "empty state: no MCP access tokens", "No tokens yet.")}
          </p>
          <ul id="mcp-tokens" class="mcp-tokens" phx-update="stream">
            <li :for={{dom_id, token} <- @streams.mcp_tokens} id={dom_id}>
              <span class="mcp-token-name">{token.name}</span>
              <span class="mcp-token-meta">
                {dpgettext(
                  "accounts",
                  "status: an MCP token's access level and last characters, then its creation date follows",
                  "%{access_level} · …%{token_hint} · created",
                  access_level: access_label(token.access),
                  token_hint: token.hint
                )}
                <.local_time id={"#{dom_id}-created"} at={token.inserted_at} format={:full} />
                <%= if token.last_used_at do %>
                  {dpgettext(
                    "accounts",
                    "status: when an MCP token was last used, its date follows",
                    "· last used"
                  )}
                  <.local_time id={"#{dom_id}-used"} at={token.last_used_at} />
                <% else %>
                  {dpgettext(
                    "accounts",
                    "status: an MCP token that was never used",
                    "· last used never"
                  )}
                <% end %>
              </span>
              <details :if={@mcp_calls[token.id]} id={"mcp-token-calls-#{token.id}"}>
                <summary>
                  {dpgettext(
                    "accounts",
                    "heading: an MCP token's recent tool calls, with how many are listed",
                    "Recent calls (%{call_count})",
                    call_count: Format.number(length(@mcp_calls[token.id]))
                  )}
                </summary>
                <ul>
                  <li :for={call <- @mcp_calls[token.id]} id={"mcp-call-#{call.id}"}>
                    {call.tool} · {call.outcome} ·
                    <.local_time id={"mcp-call-#{call.id}-at"} at={call.inserted_at} />
                  </li>
                </ul>
              </details>
              <.button
                size="sm"
                danger
                phx-click="revoke_mcp_token"
                phx-value-id={token.id}
                id={"revoke-#{dom_id}"}
                data-confirm={revoke_confirm(token.name)}
              >
                {dpgettext("accounts", "button: revoke an MCP access token", "Revoke")}
              </.button>
            </li>
          </ul>
        </.pane_section>
      </div>
      <MythweaverWeb.Sudo.modal :if={@sudo_prompt} prompt={@sudo_prompt} />
    </Layouts.app>
    """
  end
end
