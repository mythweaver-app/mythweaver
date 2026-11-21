defmodule Mythweaver.Memory.RecordSource do
  @moduledoc "One source of a consolidation: `record_id` was consolidated from `source_id`."

  use Mythweaver.Schema

  import Ecto.Changeset

  alias Mythweaver.Memory.Record

  schema "memory_record_sources" do
    belongs_to :record, Record
    belongs_to :source, Record

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(record_source, attrs) do
    record_source
    |> cast(attrs, [:record_id, :source_id])
    |> validate_required([:record_id, :source_id])
    |> unique_constraint([:record_id, :source_id])
  end
end
