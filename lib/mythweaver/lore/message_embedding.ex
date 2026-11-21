defmodule Mythweaver.Lore.MessageEmbedding do
  @moduledoc """
  A message body's stored embedding under one embedding model (`ai_model_id`), with the SHA-256 of
  the `content` it was made from. Keyed by body, not message, because each swipe has its own text.

  Only `Mythweaver.Lore.Embeddings` writes rows, through `Repo.insert_all/3`, so there is no
  changeset. The column layout (unsized `vector`, no HNSW index) is explained in
  `Mythweaver.Lore.EntryEmbedding`'s moduledoc.
  """

  use Mythweaver.Schema

  alias Mythweaver.AI.Model
  alias Mythweaver.Messages.MessageBody
  alias Pgvector.Ecto.Vector

  @type t :: %__MODULE__{}

  schema "message_body_embeddings" do
    field :content_hash, :binary
    field :embedding, Vector

    belongs_to :body, MessageBody, foreign_key: :message_body_id
    belongs_to :model, Model, foreign_key: :ai_model_id

    timestamps(type: :utc_datetime)
  end
end
