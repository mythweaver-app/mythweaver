defmodule Mythweaver.Notifications.Channel do
  @moduledoc """
  A way to deliver a notification to a user. `Mythweaver.Notifications.notify/2` calls every channel
  in its `@channels` (unless the user muted them all), and each channel decides from `preferences`
  whether, and how, it delivers: `Channels.InApp` from each kind's `popup`/`sound`, `Channels.Push`
  from its `push`. A new channel adds its own `"notifications.<kind>.<channel>"` settings, reads them
  in `Mythweaver.Notifications.preferences/1`, and registers in `@channels`; callers do not change.
  """

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Notifications.Notification

  @callback deliver(Scope.t(), Notification.t(), Mythweaver.Notifications.preferences()) :: :ok
end
