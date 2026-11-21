defmodule Mythweaver.Bundle.SQLite do
  @moduledoc false
  # The SQL side of `Mythweaver.Bundle`: an in-memory database built from a bundle, and the fixed
  # reads of one. Validating the rows read is `Bundle.decode/1`'s job.

  alias Exqlite.Sqlite3

  @application_id 1_297_699_912
  @version 1
  @tables ~w(blobs items messages meta)

  @schema """
  PRAGMA application_id = #{@application_id};
  PRAGMA user_version = #{@version};
  CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
  CREATE TABLE items (uid TEXT PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL, root INTEGER NOT NULL, position INTEGER NOT NULL, data TEXT NOT NULL);
  CREATE TABLE messages (chat_uid TEXT NOT NULL, position INTEGER NOT NULL, data TEXT NOT NULL, PRIMARY KEY (chat_uid, position));
  CREATE TABLE blobs (uid TEXT PRIMARY KEY, kind TEXT NOT NULL, content_type TEXT NOT NULL, filename TEXT, description TEXT, bytes BLOB NOT NULL);
  """

  @type rows :: %{meta: [list()], items: [list()], messages: [list()], blobs: [list()]}

  @doc false
  # Database bytes holding `rows`, each list already in its table's column order (`@schema`).
  @spec write(rows()) :: binary()
  def write(rows) do
    {:ok, db} = Sqlite3.open(":memory:")

    try do
      :ok = Sqlite3.execute(db, @schema)
      :ok = Sqlite3.execute(db, "BEGIN")
      insert(db, "INSERT INTO meta (key, value) VALUES (?1, ?2)", rows.meta)

      insert(
        db,
        "INSERT INTO items (uid, kind, name, root, position, data) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        rows.items
      )

      insert(db, "INSERT INTO messages (chat_uid, position, data) VALUES (?1, ?2, ?3)", rows.messages)

      insert(
        db,
        "INSERT INTO blobs (uid, kind, content_type, filename, description, bytes) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        Enum.map(rows.blobs, &List.update_at(&1, 5, fn bytes -> {:blob, bytes} end))
      )

      :ok = Sqlite3.execute(db, "COMMIT")
      {:ok, bytes} = Sqlite3.serialize(db, "main")
      bytes
    after
      Sqlite3.close(db)
    end
  end

  defp insert(db, sql, rows) do
    {:ok, statement} = Sqlite3.prepare(db, sql)

    try do
      Enum.each(rows, fn row ->
        :ok = Sqlite3.bind(statement, row)
        :done = Sqlite3.step(db, statement)
        :ok = Sqlite3.reset(statement)
      end)
    after
      Sqlite3.release(db, statement)
    end
  end

  @doc false
  # The rows of database `bytes`, or `{:error, :newer}` for a format version past this one and
  # `{:error, :invalid}` for anything that isn't a sound bundle database. Only fixed statements run,
  # with `trusted_schema` off, and a schema carrying triggers or views is refused outright.
  @spec read(binary()) :: {:ok, rows()} | {:error, :newer | :invalid}
  def read(bytes) do
    {:ok, db} = Sqlite3.open(":memory:")

    try do
      with :ok <- Sqlite3.execute(db, "PRAGMA trusted_schema = OFF"),
           :ok <- Sqlite3.deserialize(db, "main", bytes),
           {:ok, [[@application_id]]} <- all(db, "PRAGMA application_id"),
           {:ok, [[version]]} when is_integer(version) <- all(db, "PRAGMA user_version"),
           :ok <- check_version(version),
           {:ok, [["ok"]]} <- all(db, "PRAGMA quick_check"),
           {:ok, schema} <- all(db, "SELECT type, name FROM sqlite_schema"),
           :ok <- check_schema(schema),
           {:ok, meta} <- all(db, "SELECT key, value FROM meta ORDER BY key"),
           {:ok, items} <- all(db, "SELECT uid, kind, name, root, position, data FROM items ORDER BY position, rowid"),
           {:ok, messages} <- all(db, "SELECT chat_uid, position, data FROM messages ORDER BY chat_uid, position"),
           {:ok, blobs} <- all(db, "SELECT uid, kind, content_type, filename, description, bytes FROM blobs") do
        {:ok, %{meta: meta, items: items, messages: messages, blobs: blobs}}
      else
        {:error, :newer} -> {:error, :newer}
        _other -> {:error, :invalid}
      end
    after
      Sqlite3.close(db)
    end
  end

  defp check_version(version) when version > @version, do: {:error, :newer}
  defp check_version(@version), do: :ok
  defp check_version(_version), do: {:error, :invalid}

  defp check_schema(schema) do
    tables = for [type, name] <- schema, type == "table", do: name

    cond do
      Enum.any?(schema, fn [type, _name] -> type in ["trigger", "view"] end) -> {:error, :invalid}
      Enum.all?(@tables, &(&1 in tables)) -> :ok
      true -> {:error, :invalid}
    end
  end

  defp all(db, sql) do
    with {:ok, statement} <- Sqlite3.prepare(db, sql) do
      try do
        Sqlite3.fetch_all(db, statement)
      after
        Sqlite3.release(db, statement)
      end
    end
  end
end
