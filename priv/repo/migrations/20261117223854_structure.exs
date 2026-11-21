defmodule Mythweaver.Repo.Migrations.Structure do
  use Ecto.Migration

  # Every migration through 20261117223854, squashed into priv/repo/structure.sql. This file takes
  # that last migration's version, so a database that ran the originals has it recorded and skips
  # it, and an empty one runs it. The release has no psql, and `execute/1` sends one statement, so
  # the whole file runs as one PL/pgSQL EXECUTE (which accepts several statements) inside the
  # migration's transaction.
  def up do
    sql = File.read!(Application.app_dir(:mythweaver, "priv/repo/structure.sql"))
    execute("DO $do$ BEGIN EXECUTE $structure$#{sql}$structure$; END $do$")
  end

  def down do
    raise Ecto.MigrationError, "the squashed structure can't be rolled back; drop the database"
  end
end
