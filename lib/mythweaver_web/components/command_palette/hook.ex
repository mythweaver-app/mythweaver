defmodule MythweaverWeb.CommandPalette.Hook do
  @moduledoc """
  Attached to every LiveView by the router's `live_session`: turns the command palette's
  `{MythweaverWeb.CommandPalette, :flash, kind, message}` into the page's flash, since a
  LiveComponent's own `put_flash` shows only when it navigates.
  """

  import Phoenix.LiveView, only: [attach_hook: 4, put_flash: 3]

  def on_mount(:default, _params, _session, socket) do
    {:cont, attach_hook(socket, :command_palette_flash, :handle_info, &flash/2)}
  end

  defp flash({MythweaverWeb.CommandPalette, :flash, kind, message}, socket),
    do: {:halt, put_flash(socket, kind, message)}

  defp flash(_message, socket), do: {:cont, socket}
end
