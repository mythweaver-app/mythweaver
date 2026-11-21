defmodule Mythweaver.Notifications.Channels.InApp do
  @moduledoc """
  Delivers to the user's open tabs: a broadcast on `Mythweaver.Notifications.topic/1` that
  `MythweaverWeb.NotificationsHook` turns into a browser popup and/or a sound.
  """

  @behaviour Mythweaver.Notifications.Channel

  alias Mythweaver.Notifications

  @impl true
  def deliver(scope, notification, prefs) do
    %{popup: popup?, sound: sound?} = Map.fetch!(prefs, notification.kind)

    if popup? or sound? do
      Phoenix.PubSub.broadcast(
        Mythweaver.PubSub,
        Notifications.topic(scope.user.id),
        {Notifications, :in_app, notification, %{popup: popup?, sound: sound?}}
      )
    end

    :ok
  end
end
