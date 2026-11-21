defmodule Mythweaver.Memory.TopicSuggestion do
  @moduledoc """
  A topic Memory Assistance suggested and the user approved, pending until its topical clip is saved.

  Approving a topic-suggestions review stores one row per kept topic and queues its topical clip
  draft; saving that draft deletes the row, while discarding it leaves the topic available from
  the Topical tab (`Mythweaver.Memory.Clips.draft_topic_suggestion/3`). A topic is stored once per book
  (case-insensitively). `lore_book_id` is the book the clip goes to; `record_id` and `message_ids`
  are the memory and scene that prompted it. `drafting?` is virtual, set by
  `Mythweaver.Memory.Clips.list_topic_suggestions/2`: whether a draft for it is queued, running or in
  review. Only `Mythweaver.Memory.Clips` writes these rows: `changeset/2` casts nothing.
  """

  use Mythweaver.Schema

  import Ecto.Changeset

  alias Mythweaver.Chats.Chat
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Memory.Record

  @type t :: %__MODULE__{}

  schema "memory_topic_suggestions" do
    field :topic, :string
    field :keywords, {:array, :string}, default: []
    field :message_ids, {:array, Ecto.UUID}, default: []
    field :drafting?, :boolean, virtual: true, default: false

    belongs_to :chat, Chat
    belongs_to :book, LoreBook, foreign_key: :lore_book_id
    belongs_to :record, Record
    belongs_to :job, Job

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(suggestion, attrs), do: cast(suggestion, attrs, [])
end
