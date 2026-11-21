defmodule Mythweaver.Schema do
  @moduledoc """
  The base every persisted schema in this app uses instead of `Ecto.Schema` directly.

  Sets primary keys to use V7 UUIDs with `precision: :monotonic`.

  `precision: :monotonic` rather than the default `:millisecond`, because
  several queries already use `id` as a creation-order tiebreak and plain
  millisecond precision would randomize it within a millisecond

  Monotonic encodes sub-millisecond order in the 12 `rand_a` bits and advances a
  shared `:atomics` counter, so ids are strictly increasing per node: one
  compare-exchange per insert, which is not measurable against the surrounding
  query.

  Timestamps are not set here, most use :utc_datetime, but a few locations use
  :utc_datetime_usec. Not all tables need timestamps either

  Embedded schemas keep `use Ecto.Schema`: they have no primary key to generate.

      defmodule Mythweaver.Thing do
        use Mythweaver.Schema

        schema "things" do
          timestamps(type: :utc_datetime)
        end
      end
  """

  @uuid_options [version: 7, precision: :monotonic]

  @doc """
  A primary key of the same version `use Mythweaver.Schema` autogenerates.

  For the rare `Repo.insert_all/3` path, which bypasses schema autogeneration and so would otherwise
  reach for `Ecto.UUID.generate/0`, whose default is v4. One definition of the version, so a bulk
  insert cannot drift from every other row in the table.
  """
  @spec generate_id() :: Ecto.UUID.t()
  def generate_id, do: Ecto.UUID.generate(@uuid_options)

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema

      @primary_key {:id, Ecto.UUID, autogenerate: unquote(@uuid_options)}
      @foreign_key_type Ecto.UUID
    end
  end
end
