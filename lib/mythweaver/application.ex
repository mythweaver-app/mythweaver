defmodule Mythweaver.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Mythweaver.Accounts.Throttle
  alias Mythweaver.Jobs
  alias Mythweaver.Lore.EmbeddingRegistry
  alias Mythweaver.Lore.EmbeddingSupervisor
  alias Mythweaver.Messages.CleanupRegistry
  alias Mythweaver.Messages.CleanupSupervisor
  alias Mythweaver.Messages.DraftBuffer
  alias Mythweaver.Moderation.GeoIP
  alias Mythweaver.Moderation.Pruner
  alias Mythweaver.Moderation.Store
  alias Mythweaver.Notifications.Focus
  alias Mythweaver.Notifications.PushSupervisor
  alias Mythweaver.Scripts.CallbackStore
  alias Mythweaver.Templates.TaskSupervisor

  @impl true
  def start(_type, _args) do
    # A misconfigured storage or image proxy fails at boot, naming the env var, not on first upload.
    Mythweaver.Attachments.validate_config!()
    MythweaverWeb.ClientIp.load_config!()

    # Parsed tokenizers are NIF handles, so the cache lives in memory for the VM's lifetime and is
    # owned by the application process rather than any request.
    Mythweaver.Tokenizer.create_cache()
    # A script's tag and data for background work it started (`Mythweaver.Scripts.CallbackStore`).
    CallbackStore.create_table()
    # Images the remote image proxy fetched, until their links expire (`MythweaverWeb.RemoteImage`).
    MythweaverWeb.RemoteImage.create_table()

    # The vault before the Repo: loading a provider decrypts its API key.
    # GeoLite2 lookups for account fingerprints; none without a downloaded database.
    children =
      [MythweaverWeb.Telemetry, Mythweaver.Vault, Mythweaver.Repo] ++
        interrupted_bodies_sweep() ++
        [
          {DNSCluster, query: Application.get_env(:mythweaver, :dns_cluster_query) || :ignore},
          {Phoenix.PubSub, name: Mythweaver.PubSub},
          Throttle
        ] ++
        moderation_pruner() ++
        GeoIP.child_specs() ++
        [
          # Composer drafts, written on a debounce; after Repo so its shutdown flush can still write.
          DraftBuffer,
          # Each running job's received text (`Jobs.LiveOutput`), registered by its runner task.
          {Registry, keys: :unique, name: Jobs.LiveOutput},
          # Every generation runs here, unlinked from whoever asked for it, so a failed generation
          # cannot take a connected socket down with it. `Jobs.Scheduler` starts and kills them.
          {Task.Supervisor, name: Jobs.TaskSupervisor},
          Jobs.Scheduler,
          # One generation server per chat, named through the registry, so a generation outlives the
          # LiveView that started it and two clicks cannot interleave two replies into one transcript.
          {Registry, keys: :unique, name: Mythweaver.Generation.Registry},
          {DynamicSupervisor, name: Mythweaver.Generation.Supervisor, strategy: :one_for_one},
          # Template renders run here, each in its own heap-capped, timed process, so an untrusted
          # template cannot exhaust the caller's memory or hang a generation.
          {Task.Supervisor, name: TaskSupervisor},
          # Document text extraction (`Attachments.DocumentText`), heap-capped and timed the same way.
          {Task.Supervisor, name: Mythweaver.Attachments.TaskSupervisor},
          # Import file parsing (`Import.parse/2`), heap-capped and timed.
          {Task.Supervisor, name: Mythweaver.Import.TaskSupervisor},
          # Lua script runs, each in its own heap-capped, CPU-traced process (`Scripts.Sandbox`).
          {Task.Supervisor, name: Mythweaver.Scripts.TaskSupervisor},
          # Background lore and message embedding (`Lore.Embeddings`).
          {Registry, keys: :unique, name: EmbeddingRegistry},
          {Task.Supervisor, name: EmbeddingSupervisor},
          # Direct classifier-model expression calls (`Expressions.Encoder`).
          {Task.Supervisor, name: Mythweaver.Expressions.TaskSupervisor},
          # Old messages' cleanup (`Messages.Cleanup`).
          {Registry, keys: :unique, name: CleanupRegistry},
          {Task.Supervisor, name: CleanupSupervisor},
          # Which users have an app tab in focus, and the Web Push sends (`Mythweaver.Notifications`).
          {Registry, keys: :duplicate, name: Focus},
          {Task.Supervisor, name: PushSupervisor},
          # The remote image proxy's fetches (`MythweaverWeb.RemoteImage`), at most 8 at once.
          {Task.Supervisor, name: MythweaverWeb.RemoteImage.TaskSupervisor, max_children: 8},
          # Content held for moderator review lives only here, in memory (`Mythweaver.Moderation.Store`),
          # and rule scans run in the task supervisor (`Mythweaver.Moderation.Scanner`).
          {Task.Supervisor, name: Mythweaver.Moderation.TaskSupervisor},
          Store,
          # Start to serve requests, typically the last entry
          MythweaverWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Mythweaver.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Deletes account fingerprints a year after they were last seen (`Mythweaver.Moderation.Pruner`).
  # Off in tests, where it would race the SQL sandbox.
  defp moderation_pruner do
    if Application.get_env(:mythweaver, :moderation_pruner, true), do: [Pruner], else: []
  end

  # No generation survives a restart, so a body still `generating` at boot was stranded by a hard kill
  # or a crash; this marks each one "Interrupted.", marks every job left queued or running
  # `:interrupted`, and prunes old finished jobs. Off in tests, where it would race the SQL sandbox.
  # Single-node only: on several nodes it would clobber another node's live generation.
  defp interrupted_bodies_sweep do
    if Application.get_env(:mythweaver, :finalize_interrupted_bodies_on_boot, true),
      do: [
        {Task,
         fn ->
           Mythweaver.Messages.finalize_interrupted_bodies()
           Jobs.interrupt_stale()
           Jobs.prune()
           Mythweaver.Notifications.prune()
           Mythweaver.Attachments.sweep_orphans()
         end}
      ],
      else: []
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MythweaverWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
