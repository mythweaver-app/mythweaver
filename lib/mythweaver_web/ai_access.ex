defmodule MythweaverWeb.AIAccess do
  @moduledoc """
  Who reaches the AI connection and model editors (`AIProviderLive`, `AIModelLive`): an admin, or a
  user the `"ai.personal_providers"` setting lets add their own (`Mythweaver.AI.can_add?/1`). Mounted
  as `on_mount MythweaverWeb.AIAccess`; anyone else is redirected to `/`. The nav and the command
  palette ask `allowed?/1` the same question.
  """

  use MythweaverWeb, :verified_routes

  alias Mythweaver.AI

  @doc "Whether `scope` may open the AI editors."
  def allowed?(scope), do: scope != nil and AI.can_add?(scope)

  def on_mount(:default, _params, _session, socket) do
    if allowed?(socket.assigns.current_scope) do
      {:cont, socket}
    else
      {:halt,
       socket
       |> MythweaverWeb.Flash.flash_unauthorized()
       |> Phoenix.LiveView.redirect(to: ~p"/")}
    end
  end
end
