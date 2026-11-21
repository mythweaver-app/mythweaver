defmodule Mythweaver.Bundle.Origin do
  @moduledoc """
  The bundle uid an imported row was written from (`Mythweaver.Bundle.Origins`).

  One row per `(kind, record_id)`. `origin_id` is the uid the row carried in the file, which a later
  export reuses as the row's own uid, so identity survives instance → instance → instance chains.
  """

  use Mythweaver.Schema

  @type t :: %__MODULE__{}

  schema "origins" do
    field :kind, Ecto.Enum,
      values: [
        :character,
        :lore_book,
        :lore_entry,
        :lore_pool,
        :prompt,
        :prompt_block,
        :ai_model,
        :script,
        :memory_profile,
        :side_prompt,
        :side_prompt_set,
        :chat
      ]

    field :record_id, Ecto.UUID
    field :origin_id, Ecto.UUID

    timestamps(type: :utc_datetime)
  end
end
