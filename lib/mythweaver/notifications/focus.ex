defmodule Mythweaver.Notifications.Focus do
  @moduledoc """
  Which users are looking at the app right now, so `Channels.Push` does not push to someone who is.

  Each connected LiveView registers its process under the user's id (`MythweaverWeb.NotificationsHook`)
  and records what its page's `.Notifications` hook reports: whether the tab is visible and has focus.
  An entry vanishes with its process. Per node: with several nodes a tab on another node is not seen.
  """

  @doc "Registers the calling process as one of `user_id`'s pages, not yet focused."
  @spec register(Ecto.UUID.t()) :: :ok
  def register(user_id), do: put(user_id, false)

  @doc "Records whether the calling process's page has focus."
  @spec put(Ecto.UUID.t(), boolean()) :: :ok
  def put(user_id, focused?) when is_boolean(focused?) do
    # `update_value/3` is for unique registries only; a user has many pages.
    Registry.unregister(__MODULE__, user_id)
    {:ok, _} = Registry.register(__MODULE__, user_id, focused?)
    :ok
  end

  @doc "Whether any of `user_id`'s pages has focus."
  @spec focused?(Ecto.UUID.t()) :: boolean()
  def focused?(user_id), do: Enum.any?(Registry.lookup(__MODULE__, user_id), fn {_pid, focused?} -> focused? end)
end
