defmodule Mythweaver.Moderation.Pruner do
  @moduledoc """
  Deletes account fingerprints a year after they were last seen (`Mythweaver.Moderation.Fingerprints.prune/1`):
  and MCP call log rows after 90 days (`Mythweaver.MCP.prune_calls/0`): a minute after boot, then daily. Off in tests (`:moderation_pruner`).
  """

  use GenServer

  alias Mythweaver.MCP
  alias Mythweaver.Moderation.Fingerprints

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.send_after(self(), :prune, to_timeout(minute: 1))
    {:ok, nil}
  end

  @impl true
  def handle_info(:prune, state) do
    Fingerprints.prune()
    MCP.prune_calls()
    Process.send_after(self(), :prune, to_timeout(day: 1))
    {:noreply, state}
  end
end
