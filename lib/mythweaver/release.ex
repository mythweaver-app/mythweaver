defmodule Mythweaver.Release do
  @moduledoc """
  Tasks for a `mix release`, where Mix is not available. Run them through the release's `eval`
  (the `rel/overlays/bin` wrappers do):

      bin/mythweaver eval "Mythweaver.Release.migrate()"   # bin/migrate
      bin/mythweaver eval "Mythweaver.Release.seed()"      # bin/seed

  - `migrate/0` runs every pending migration; run it before starting a new version.
  - `rollback/2` migrates one repo down to `version`.
  - `seed/0` loads the built-in content a fresh install needs: the default prompt (only while no
    prompt exists, since `prompts.exs` replaces every prompt), then the memory, caption and
    expression seeds, which upsert their own rows and are safe to re-run. It never runs
    `priv/repo/dev_seeds.exs`, which deletes chats and characters to load sample data.
  """

  alias Mythweaver.Prompts.Prompt

  @app :mythweaver

  @spec migrate() :: :ok
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @spec rollback(module(), integer()) :: :ok
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
    :ok
  end

  @spec seed() :: :ok
  def seed do
    # The seeds go through the contexts, which need PubSub, the Vault and the Repo running.
    {:ok, _} = Application.ensure_all_started(@app)
    dir = Application.app_dir(@app, "priv/repo/seeds")

    if Mythweaver.Repo.aggregate(Prompt, :count) == 0 do
      Code.require_file("prompts.exs", dir)
    end

    for file <- ~w(memory.exs captions.exs expressions.exs), do: Code.require_file(file, dir)
    :ok
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app, do: Application.load(@app)
end
