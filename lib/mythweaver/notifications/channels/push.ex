defmodule Mythweaver.Notifications.Channels.Push do
  @moduledoc """
  Delivers by Web Push to every device the user enabled (`Mythweaver.Notifications.PushSubscription`),
  so a notification reaches a closed tab or an installed phone app. Skipped when push is not
  configured (`WebPush.configured?/0`), the kind's `push` setting is off, or one of the user's
  pages has focus (`Mythweaver.Notifications.Focus`): someone looking at the app is not pushed to.

  The sends run in `Mythweaver.Notifications.PushSupervisor`, so `notify/2` never waits on a push
  service. The payload's `id` is the notification's, which the in-app popup also uses as its
  `tag`, so a hidden tab's popup and the push show as one notification.
  """

  @behaviour Mythweaver.Notifications.Channel

  alias Mythweaver.Notifications
  alias Mythweaver.Notifications.Focus
  alias Mythweaver.Notifications.WebPush

  @reply_ttl 60 * 60
  @review_ttl 24 * 60 * 60

  @impl true
  def deliver(scope, notification, prefs) do
    with true <- WebPush.configured?(),
         %{push: true} <- Map.fetch!(prefs, notification.kind),
         false <- Focus.focused?(scope.user.id),
         [_ | _] = devices <- Notifications.list_devices(scope) do
      payload = %{
        id: notification.id,
        title: notification.title,
        body: if(prefs.push_preview, do: notification.body, else: ""),
        icon: notification.icon || "/images/icons/icon-192.png",
        path: Notifications.path(notification)
      }

      opts = options(notification)

      {:ok, _} =
        Task.Supervisor.start_child(Notifications.PushSupervisor, fn ->
          Enum.each(devices, &Notifications.push_to_device(&1, payload, opts))
        end)
    end

    :ok
  end

  # Topic: a newer push for the same chat and kind replaces one the device has not received yet
  # (url-safe base64 of the chat id, 22 characters, behind a one-letter kind prefix).
  defp options(%{kind: :memory_review} = n), do: [ttl: @review_ttl, urgency: :normal, topic: topic("m", n)]
  defp options(n), do: [ttl: @reply_ttl, urgency: :high, topic: topic("r", n)]

  defp topic(prefix, n), do: prefix <> Base.url_encode64(Ecto.UUID.dump!(n.chat_id), padding: false)
end
