defmodule Mythweaver.Lore.EntryEmbedding do
  @moduledoc """
  A Vector lore entry's stored embedding under one embedding model (`ai_model_id`), with the SHA-256
  of the `content` it was made from, so an edited entry reads as stale until it is re-embedded.

  Only `Mythweaver.Lore.Embeddings` writes rows, through `Repo.insert_all/3`, so there is no
  changeset.

  The `embedding` column is deliberately an unsized `vector` with no HNSW index:

    * one table serves embedding models of any dimension, keyed by `ai_model_id`;
    * HNSW needs a fixed size;
    * every query is restricted to one resolve's candidate entries and scan-window bodies, so an
      exact `<=>` scan over a few hundred rows is what's wanted anyway.

  `Mythweaver.Lore.MessageEmbedding` is laid out the same way for the same reasons.
  """

  use Mythweaver.Schema

  alias Mythweaver.AI.Model
  alias Mythweaver.Lore.LoreEntry
  alias Pgvector.Ecto.Vector

  @type t :: %__MODULE__{}

  schema "lore_entry_embeddings" do
    field :content_hash, :binary
    field :embedding, Vector

    belongs_to :entry, LoreEntry, foreign_key: :lore_entry_id
    belongs_to :model, Model, foreign_key: :ai_model_id

    timestamps(type: :utc_datetime)
  end
end
