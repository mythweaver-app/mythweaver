defmodule Mythweaver.Memory.Record do
  @moduledoc """
  The memory metadata of one managed lore entry (SillyTavern-MemoryBooks' entry flags), one row per
  entry: what kind of memory it is, which messages it covers, and what consolidated it.

  `tier` is 0 for a scene memory and 1..6 for a consolidation (`Arc` … `Epic`); clips and side prompts
  have none. `range_start`/`range_end` are message `position`s. `sequence` numbers the entry within
  its book and tier and feeds the title's numbering token; titles are never parsed back.

  `scene_fingerprint` and `written_fingerprint` are sha256 hex digests of the scene text used and of
  the content as written, so a regeneration or rollback can tell whether the source or the entry
  changed since. `sources` (through `RecordSource`) are a consolidation's inputs.

  `canonical_id` marks a character's copy of a scene memory: the chat's own memory it copies, written
  into a character memory book and filtered to its characters. In the chat it was made in, a copy
  activates only on its character's turn, instead of the chat's memory (`Mythweaver.Lore.Activation`).
  A copy is never regenerated on its own; regenerating the chat's memory refreshes it.

  A *shared copy* lives in its canonical memory's own book (the chat's book chosen as a character
  book). It shares the canonical's sequence, and everything that counts or gathers a book's memories
  skips it (`without_shared_copies/1`): the canonical already stands for the memory there. It is
  consolidated, and restored, along with its canonical.

  Not castable from user input: only `Mythweaver.Memory` writes these rows.
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias Mythweaver.Chats.Chat
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Memory.Profile
  alias Mythweaver.Memory.RecordSource
  alias Mythweaver.Memory.SidePrompt
  alias Mythweaver.Memory.SidePromptSetRow
  alias Mythweaver.Prompts.Prompt

  @type t :: %__MODULE__{}

  schema "memory_records" do
    field :kind, Ecto.Enum, values: [:memory, :consolidation, :clip, :topical_clip, :side_prompt]
    field :tier, :integer
    field :sequence, :integer
    field :range_start, :integer
    field :range_end, :integer
    field :scene_fingerprint, :string
    field :written_fingerprint, :string
    field :disabled_by_consolidation, :boolean, default: false
    field :version, :integer
    field :snapshot, :map, default: %{}

    belongs_to :entry, LoreEntry, foreign_key: :lore_entry_id
    belongs_to :book, LoreBook, foreign_key: :lore_book_id
    belongs_to :chat, Chat
    belongs_to :consolidated_into, __MODULE__
    belongs_to :profile, Profile
    belongs_to :prompt, Prompt
    belongs_to :side_prompt, SidePrompt
    belongs_to :canonical, __MODULE__
    # The side prompt set row a `:side_prompt` record ran for; nil for an individual side prompt.
    belongs_to :side_prompt_set_row, SidePromptSetRow

    many_to_many :sources, __MODULE__,
      join_through: RecordSource,
      join_keys: [record_id: :id, source_id: :id]

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :lore_entry_id,
      :lore_book_id,
      :chat_id,
      :kind,
      :tier,
      :sequence,
      :range_start,
      :range_end,
      :scene_fingerprint,
      :written_fingerprint,
      :consolidated_into_id,
      :disabled_by_consolidation,
      :profile_id,
      :prompt_id,
      :side_prompt_id,
      :version,
      :snapshot,
      :canonical_id,
      :side_prompt_set_row_id
    ])
    |> validate_required([:lore_entry_id, :kind])
    |> validate_tier()
    |> assoc_constraint(:entry)
    |> unique_constraint(:lore_entry_id)
  end

  defp validate_tier(changeset) do
    case get_field(changeset, :kind) do
      :memory ->
        changeset |> validate_required([:tier]) |> validate_inclusion(:tier, [0])

      :consolidation ->
        changeset |> validate_required([:tier]) |> validate_inclusion(:tier, 1..6)

      _other ->
        validate_inclusion(changeset, :tier, [nil], message: dgettext_noop("errors", "must be empty for this kind"))
    end
  end

  @doc """
  `query` (records as its first binding) without shared copies: copies kept in their canonical
  memory's own book.
  """
  @spec without_shared_copies(Ecto.Queryable.t()) :: Ecto.Query.t()
  def without_shared_copies(query) do
    from(r in query,
      left_join: canonical in __MODULE__,
      on: canonical.id == r.canonical_id and canonical.lore_book_id == r.lore_book_id,
      where: is_nil(canonical.id)
    )
  end

  @doc "The shared copies (see the moduledoc) of the records `ids`."
  @spec shared_copies([Ecto.UUID.t()]) :: Ecto.Query.t()
  def shared_copies(ids) do
    from(r in __MODULE__,
      join: canonical in __MODULE__,
      on: canonical.id == r.canonical_id and canonical.lore_book_id == r.lore_book_id,
      where: canonical.id in ^ids
    )
  end
end
