defmodule MythweaverWeb.UserLoginLive do
  @moduledoc """
  The login page. The form validates nothing live: submit flips `phx-trigger-action`, and the browser
  posts to `UserSessionController.create/2`, which writes the session cookie. When auto-login is
  available (at most one account), it also offers to continue without logging in.
  """
  use MythweaverWeb, :live_view

  alias Mythweaver.Accounts

  @impl true
  def mount(_params, _session, socket) do
    cond do
      socket.assigns.current_scope ->
        {:ok, push_navigate(socket, to: ~p"/")}

      not Accounts.any_users?() and not Accounts.auto_login_enabled?() ->
        {:ok, push_navigate(socket, to: ~p"/setup")}

      true ->
        email = Phoenix.Flash.get(socket.assigns.flash, :email)

        {:ok,
         assign(socket,
           page_title: dpgettext("accounts", "page title: sign-in page", "Log in"),
           form: to_form(%{"email" => email}, as: "user"),
           trigger_submit: false,
           auto_login?: Accounts.auto_login_available?(),
           # Posted with the form for the login's account fingerprints (`MythweaverWeb.Signals`).
           fingerprint: if(connected?(socket), do: get_connect_params(socket)["fingerprint"])
         )}
    end
  end

  @impl true
  def handle_event("submit", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      /* The slot's root. A `<.form>` passed into `Layouts.auth`'s slot carries no scope marker, so
         without this wrapper none of the rules below would reach it. */
      div.login-body:scope {
        display: contents;
      }

      .auth-title {
        margin: 0 0 var(--size-3);
        font-size: var(--font-size-4);
      }

      .auth-form label {
        display: block;
      }

      .auth-form .input {
        margin-block-end: var(--size-2);
      }

      .auth-form-actions {
        margin-block-start: var(--size-2);
      }

      .auth-alternative {
        margin-block-start: var(--size-3);
        padding-block-start: var(--size-3);
        border-block-start: 1px solid var(--border);
      }

      /* A fixed layer behind the card that repaints the page's `:root` background (base.css) and
         drifts its glows. Only `transform` animates, so the gradients are not repainted per frame.
         A negative z-index paints it over the root canvas but under the card. */
      .login-backdrop {
        position: fixed;
        inset: 0;
        z-index: -1;
        overflow: hidden;
        pointer-events: none;
        background-color: var(--background);
      }

      .login-backdrop::before,
      .login-backdrop::after {
        content: "";
        position: absolute;
        will-change: transform;
        animation: login-drift-sides 45s ease-in-out infinite alternate;
      }

      /* The side and top glows, oversized a little so the drift never bares an edge. */
      .login-backdrop::before {
        inset: -6%;
        background: var(--gradient-background);
      }

      /* The top highlight; oversized only sideways so it stays pinned to the top edge. */
      .login-backdrop::after {
        inset: 0 -8%;
        background: var(--background-highlight);
        animation-name: login-drift-highlight;
        animation-duration: 31s;
      }

      @keyframes login-drift-sides {
        from {
          transform: translate(-3%, 2%) scale(1);
        }
        to {
          transform: translate(3%, -2%) scale(1.06);
        }
      }

      @keyframes login-drift-highlight {
        from {
          transform: translateX(-5%) scaleX(0.95);
          filter: brightness(80%);
          opacity: 0.8;
        }
        to {
          transform: translateX(5%) scaleX(1.08);
          opacity: 1;
          filter: brightness(105%);
        }
      }

      @media (prefers-reduced-motion: reduce) {
        .login-backdrop::before,
        .login-backdrop::after {
          animation: none;
        }
      }
    </style>

    <Layouts.auth flash={@flash}>
      <div class="login-body">
        <div class="login-backdrop" aria-hidden="true"></div>
        <h1 class="auth-title">
          {dpgettext(
            "accounts",
            "heading: sign-in page, with the site's name",
            "Log in to %{site_name}",
            site_name: Mythweaver.Branding.name()
          )}
        </h1>
        <.form
          for={@form}
          id="login-form"
          class="auth-form"
          action={~p"/users/log-in"}
          phx-submit="submit"
          phx-trigger-action={@trigger_submit}
        >
          <.input
            field={@form[:email]}
            type="email"
            label={dpgettext("accounts", "field label: account email address", "Email")}
            id="login-form-email"
            autocomplete="username"
            required
            phx-mounted={JS.focus()}
          />
          <.input
            field={@form[:password]}
            type="password"
            label={dpgettext("accounts", "field label: account password", "Password")}
            id="login-form-password"
            autocomplete="current-password"
          />
          <.input
            field={@form[:remember_me]}
            type="checkbox"
            label={
              dpgettext(
                "accounts",
                "field label: keep the sign-in after the browser closes",
                "Remember me"
              )
            }
            id="login-form-remember_me"
          />
          <input type="hidden" name="user[fingerprint]" value={@fingerprint} />
          <div class="auth-form-actions">
            <.button type="submit" variant="primary" block id="login-form-submit">
              {dpgettext("accounts", "button: submit the sign-in form", "Log in")}
            </.button>
          </div>
        </.form>
        <div :if={@auto_login?} class="auth-alternative">
          <.button navigate={~p"/"} block id="auto-login-continue">
            {dpgettext(
              "accounts",
              "button: enter the app as the auto-login account without signing in",
              "Continue without logging in"
            )}
          </.button>
        </div>
      </div>
    </Layouts.auth>
    """
  end
end
