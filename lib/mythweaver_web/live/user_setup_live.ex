defmodule MythweaverWeb.UserSetupLive do
  @moduledoc """
  First-run setup: creates the first account, then logs it in. Only reachable while no account
  exists; the save goes through `Accounts.register_first_user/1`, which refuses once one does.

  On success the form flips `phx-trigger-action` and the browser posts the typed email and password
  to `UserSessionController.create/2` (`_action=registered`), which writes the session cookie.
  """
  use MythweaverWeb, :live_view

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.User

  @live_opts [hash_password: false, validate_unique: false]

  @impl true
  def mount(_params, _session, socket) do
    if Accounts.any_users?() do
      {:ok, push_navigate(socket, to: ~p"/users/log-in")}
    else
      {:ok,
       assign(socket,
         page_title:
           dpgettext("accounts", "page title: first-run setup, with the site's name", "Set up %{site_name}",
             site_name: Mythweaver.Branding.name()
           ),
         form: to_form(Accounts.change_user_registration(%User{}, %{}, @live_opts)),
         trigger_submit: false
       )}
    end
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    changeset =
      %User{}
      |> Accounts.change_user_registration(params, @live_opts)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"user" => params}, socket) do
    case Accounts.register_first_user(params) do
      {:ok, user} ->
        {:noreply,
         assign(socket,
           trigger_submit: true,
           form: to_form(Accounts.change_user_registration(user, %{}, @live_opts))
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}

      {:error, :already_set_up} ->
        {:noreply,
         socket
         |> put_flash(:error, already_set_up())
         |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  defp already_set_up do
    gettext_comment("Flash when the first-run setup form is sent after another first account was already created.")

    dpgettext(
      "accounts",
      "status: first-run setup already done, with the site's name",
      "%{site_name} is already set up",
      site_name: Mythweaver.Branding.name()
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      h1.auth-title:scope {
        margin: 0 0 var(--size-1);
        font-size: var(--font-size-4);
      }

      p.auth-lead:scope {
        margin: 0 0 var(--size-3);
        color: var(--muted-foreground);
      }

      form.auth-form:scope {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .auth-form label {
        display: block;
      }

      .auth-form-actions {
        margin-block-start: var(--size-2);
      }
    </style>

    <Layouts.auth flash={@flash}>
      <h1 class="auth-title">
        {dpgettext(
          "accounts",
          "heading: first-run setup, with the site's name",
          "Welcome to %{site_name}",
          site_name: Mythweaver.Branding.name()
        )}
      </h1>
      <p class="auth-lead">
        {dgettext("accounts", "Create the first account. Every account is an administrator.")}
      </p>
      <.form
        for={@form}
        id="setup-form"
        class="auth-form"
        action={~p"/users/log-in?_action=registered"}
        method="post"
        phx-change="validate"
        phx-submit="save"
        phx-trigger-action={@trigger_submit}
      >
        <.input
          field={@form[:email]}
          type="email"
          label={dpgettext("accounts", "field label: account email address", "Email")}
          id="setup-form-email"
          autocomplete="username"
          required
          phx-mounted={JS.focus()}
        />
        <.input
          field={@form[:handle]}
          type="text"
          label={dpgettext("accounts", "field label: account's unique public handle", "Handle")}
          id="setup-form-handle"
          autocomplete="off"
          required
        />
        <.input
          field={@form[:nickname]}
          type="text"
          label={
            dpgettext(
              "accounts",
              "field label: account's optional display name",
              "Nickname (optional)"
            )
          }
          id="setup-form-nickname"
        />
        <.input
          field={@form[:password]}
          type="password"
          label={
            dpgettext(
              "accounts",
              "field label: new account password, with its minimum length",
              "Password (at least 12 characters)"
            )
          }
          id="setup-form-password"
          autocomplete="new-password"
          required
        />
        <.input
          field={@form[:password_confirmation]}
          type="password"
          label={dpgettext("accounts", "field label: repeat the new password", "Confirm password")}
          id="setup-form-password_confirmation"
          autocomplete="new-password"
          required
        />
        <div class="auth-form-actions">
          <.button type="submit" variant="primary" block>
            {dpgettext("accounts", "button: create the first account", "Create account")}
          </.button>
        </div>
      </.form>
    </Layouts.auth>
    """
  end
end
