defmodule MythweaverWeb.NotificationsHook do
  @moduledoc """
  Attached to every LiveView by the router's `live_session`: subscribes the page to the user's
  `Mythweaver.Notifications.topic/1` and pushes each in-app notification to the client as a
  `"notify"` event, which the `.Notifications` hook in `MythweaverWeb.Layouts.app/1` turns into a
  browser popup and/or a sound. A popup is skipped while an app tab has focus; `path` is where
  clicking the popup goes. A memory review also flashes on the page with a Review link, so a
  person looking at the app is told without being interrupted.

  The prompt flashes (`@prompt_keys`: a memory review, a ready consolidation tier) outlive live
  patches, which clear the whole flash: closing the memory modal must not take a prompt that just
  arrived. They leave when closed or when their timer runs out (`Layouts.flash_group/1`); the inbox
  keeps the prompt itself.

  It also registers the page in `Mythweaver.Notifications.Focus` and records the hook's
  `"app_focus"` reports there, so Web Push skips a user who is looking at the app.

  And it feeds the notifications inbox: each `:error` flash the page shows is kept in the inbox
  (`Mythweaver.Notifications.record_error/2`, once per appearance), and `{Notifications,
  :inbox_changed}` refreshes the layout's `MythweaverWeb.NotificationBell`s and
  `MythweaverWeb.NotificationInbox`.
  """

  use MythweaverWeb, :verified_routes
  use Gettext, backend: Mythweaver.Gettext

  import Phoenix.LiveView,
    only: [attach_hook: 4, connected?: 1, push_event: 3, put_flash: 3, put_private: 3, send_update: 2]

  alias Mythweaver.Notifications
  alias Mythweaver.Notifications.Focus
  alias Mythweaver.Notifications.Notification
  alias MythweaverWeb.NotificationBell
  alias MythweaverWeb.NotificationInbox

  @prompt_keys [:memory_review, :consolidation]

  def on_mount(:default, _params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket) and scope do
      Notifications.subscribe(scope)
      Focus.register(scope.user.id)
    end

    {:cont,
     socket
     |> attach_hook(:notifications, :handle_info, &deliver/2)
     |> attach_hook(:notifications_focus, :handle_event, &focus/3)
     |> attach_hook(:notifications_prompts, :handle_params, &keep_prompts/3)
     |> attach_hook(:notifications_toasts, :after_render, &after_render/1)}
  end

  defp after_render(socket), do: socket |> record_error_toast() |> track_prompts()

  # The prompt flashes as of the last render: a close or a timer clears one through a render first,
  # so a value still here when a patch arrives was cleared by the patch alone.
  defp track_prompts(socket) do
    prompts =
      for key <- @prompt_keys, value = Phoenix.Flash.get(socket.assigns.flash, key), into: %{}, do: {key, value}

    put_private(socket, :notifications_prompts, prompts)
  end

  defp keep_prompts(_params, _uri, socket) do
    socket =
      Enum.reduce(socket.private[:notifications_prompts] || %{}, socket, fn {key, value}, socket ->
        if Phoenix.Flash.get(socket.assigns.flash, key), do: socket, else: put_flash(socket, key, value)
      end)

    {:cont, socket}
  end

  # Every `put_flash` lands in the LiveView's flash, so reading it after each render catches them
  # all. A value is recorded once per appearance: re-renders and a repeat of the same text record
  # nothing until the flash clears. The dead render skips it, or a redirect's flash would count twice.
  defp record_error_toast(socket) do
    error = Phoenix.Flash.get(socket.assigns.flash, :error)
    scope = socket.assigns.current_scope

    cond do
      error == socket.private[:notifications_error] ->
        socket

      is_nil(error) ->
        put_private(socket, :notifications_error, nil)

      connected?(socket) and scope != nil ->
        :ok = Notifications.record_error(scope, flash_text(error))
        put_private(socket, :notifications_error, error)

      true ->
        socket
    end
  end

  defp flash_text(%{message: message}), do: message
  defp flash_text(message) when is_binary(message), do: message

  defp focus("app_focus", %{"focused" => focused?}, socket) when is_boolean(focused?) do
    if scope = socket.assigns.current_scope, do: Focus.put(scope.user.id, focused?)
    {:halt, socket}
  end

  defp focus(_event, _params, socket), do: {:cont, socket}

  defp deliver({Notifications, :in_app, %Notification{} = n, %{popup: popup?, sound: sound?}}, socket) do
    {:halt,
     socket
     |> flash(n)
     |> push_event("notify", %{
       id: n.id,
       kind: Atom.to_string(n.kind),
       title: n.title,
       body: n.body,
       path: Notifications.path(n),
       icon: n.icon || ~p"/favicon.ico",
       popup: popup?,
       sound: sound? && sound_path(n.kind)
     })}
  end

  defp deliver({Notifications, :inbox_changed}, socket) do
    count = Notifications.inbox_count(socket.assigns.current_scope)
    send_update(NotificationBell, id: "notification-bell", count: count)
    send_update(NotificationBell, id: "notification-bell-compact", count: count)
    send_update(NotificationInbox, id: "notification-inbox", reload: true)
    {:halt, socket}
  end

  defp deliver(_message, socket), do: {:cont, socket}

  defp flash(socket, %Notification{kind: :memory_review} = n),
    do:
      put_flash(socket, :memory_review, %{
        message: n.title,
        action: dpgettext("notifications", "button: open a memory draft waiting for review", "Review"),
        path: Notifications.path(n)
      })

  defp flash(socket, _notification), do: socket

  @doc "The sound a notification of `kind` plays; the settings page previews it."
  def sound_path(:new_message), do: ~p"/audio/new.mp3"
  def sound_path(:regenerate), do: ~p"/audio/regen.mp3"
  def sound_path(:continue), do: ~p"/audio/continue.mp3"
  def sound_path(:memory_review), do: ~p"/audio/newmem.mp3"
end
