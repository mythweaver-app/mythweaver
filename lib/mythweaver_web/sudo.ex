defmodule MythweaverWeb.Sudo do
  @moduledoc """
  Sudo mode for LiveViews: sensitive changes (`Mythweaver.Accounts.sudo?/1`) ask for the password
  once per 15 minutes.

  Mount with `on_mount MythweaverWeb.Sudo` and render `<MythweaverWeb.Sudo.modal :if={@sudo_prompt}
  prompt={@sudo_prompt} />` inside the layout. A handler whose context call returns
  `{:error, :sudo_required}` returns `{:noreply, MythweaverWeb.Sudo.require(socket, event, params)}`:
  the modal opens, and once the password is confirmed the session enters sudo mode, the scope is
  refreshed and the original event is replayed through the LiveView's own `handle_event/3`.
  """
  use MythweaverWeb, :html

  import MythweaverWeb.CoreComponents.Modal, except: [modal: 1]

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.Throttle
  alias Mythweaver.Format
  alias MythweaverWeb.CoreComponents.Modal
  alias Phoenix.LiveView.Socket

  def on_mount(:default, _params, _session, socket) do
    {:cont,
     socket
     |> Phoenix.Component.assign(sudo_prompt: nil)
     |> Phoenix.LiveView.attach_hook(:sudo, :handle_event, &handle_event/3)}
  end

  @doc """
  Opens the password prompt; `event` and `params` replay once it is confirmed, through `replay`
  (default: the LiveView's `handle_event/3`; pass a hook's handler for an event a hook owns).
  """
  @spec require(
          Socket.t(),
          String.t(),
          map(),
          (String.t(), map(), Socket.t() -> tuple()) | nil
        ) :: Socket.t()
  def require(socket, event, params, replay \\ nil) do
    Phoenix.Component.assign(socket,
      sudo_prompt: %{
        event: event,
        params: params,
        replay: replay,
        form: to_form(%{"password" => ""}, as: :sudo),
        error: nil
      }
    )
  end

  defp handle_event("sudo_confirm", %{"sudo" => %{"password" => password}}, socket) do
    %{event: event, params: params, replay: replay} = prompt = socket.assigns.sudo_prompt
    replay = replay || fn event, params, socket -> socket.view.handle_event(event, params, socket) end

    case Accounts.enter_sudo(socket.assigns.current_scope, password) do
      {:ok, scope} ->
        socket = Phoenix.Component.assign(socket, current_scope: scope, sudo_prompt: nil)
        {_reply, socket} = replay.(event, params, socket)
        {:halt, socket}

      {:error, reason} ->
        {:halt, Phoenix.Component.assign(socket, sudo_prompt: %{prompt | error: error_text(reason)})}
    end
  end

  defp handle_event("sudo_cancel", _params, socket), do: {:halt, Phoenix.Component.assign(socket, sudo_prompt: nil)}

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp error_text(:invalid_password),
    do: dpgettext("accounts", "status: sudo prompt error when the entered password is wrong", "That password is wrong.")

  defp error_text(:no_password), do: dgettext("accounts", "Set a password in Account settings first.")
  defp error_text({:throttled, seconds}), do: throttled(Throttle.wait(seconds))

  defp throttled({:seconds, seconds}) do
    dngettext(
      "accounts",
      "Too many tries. Try again in %{wait_seconds} second.",
      "Too many tries. Try again in %{wait_seconds} seconds.",
      seconds,
      wait_seconds: Format.number(seconds)
    )
  end

  defp throttled({:minutes, minutes}) do
    dngettext(
      "accounts",
      "Too many tries. Try again in %{wait_minutes} minute.",
      "Too many tries. Try again in %{wait_minutes} minutes.",
      minutes,
      wait_minutes: Format.number(minutes)
    )
  end

  attr :prompt, :map, required: true

  def modal(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      .sudo-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .sudo-text {
        margin: 0;
      }

      .sudo-error {
        margin: 0;
        color: var(--destructive);
      }

      .sudo-actions {
        display: flex;
        justify-content: flex-end;
        gap: var(--size-2);
      }
    </style>
    <Modal.modal
      id="sudo-modal"
      title={
        dpgettext(
          "accounts",
          "heading: password prompt before a sensitive change",
          "Confirm it's you"
        )
      }
      on_cancel="sudo_cancel"
    >
      <.form for={@prompt.form} id="sudo-form" class="sudo-form" phx-submit="sudo_confirm">
        <p class="sudo-text">
          {dgettext(
            "accounts",
            "Enter your password to continue. You won't be asked again for 15 minutes."
          )}
        </p>
        <.input
          field={@prompt.form[:password]}
          type="password"
          label={dpgettext("accounts", "field label: the account's current password", "Password")}
          id="sudo-form-password"
          autocomplete="current-password"
          required
        />
        <p :if={@prompt.error} id="sudo-error" class="sudo-error">{@prompt.error}</p>
        <div class="sudo-actions">
          <.button type="button" phx-click={JS.dispatch("modal:close", to: "#sudo-modal")}>
            {dpgettext("accounts", "button: close the password prompt without confirming", "Cancel")}
          </.button>
          <.button type="submit" variant="primary" id="sudo-confirm">
            {dpgettext("accounts", "button: confirm the password and continue the change", "Continue")}
          </.button>
        </div>
      </.form>
    </Modal.modal>
    """
  end
end
