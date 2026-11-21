defmodule Mythweaver.Attachments.Attachment do
  @moduledoc """
  One stored file: where its bytes live (`storage` + `key`), what it is (sniffed `content_type`,
  pixel `width`/`height`), and, for images a non-vision model cannot see, a text `description`
  written by a caption model (`caption_status`, `described_by`). `caption_status` `:review` is a
  finished caption held for a person, see `Mythweaver.Attachments.Captions.approve/3`.

  `status` is `:pending` only between a browser-direct (presigned) upload being prepared and
  `Mythweaver.Attachments.finalize_presigned_upload/3` checking the object; everything else is
  `:ready`. `source` separates player uploads from AI-generated images.

  An attachment knows nothing about its owner: owners link through join tables
  (`MessageAttachment`, `CharacterAttachment`, `BodyAttachment` for a guided swipe's images), and
  an attachment no join row points at is an orphan
  `Mythweaver.Attachments.sweep_orphans/0` removes. `uploaded_by` is the user whose request stored it
  (`nil` for AI-generated images, rows from before the column, and deleted uploaders); it gates who
  may adopt or delete the attachment while it is still unlinked, and plays no part once linked.
  `kind` is one of five: `:image` (sniffed by `ImageInfo`, with dimensions), `:document` (a PDF or
  a text/Markdown file, its text extracted into `text_content` on upload; `page_count` for PDFs),
  `:audio` and `:video` (played in chat; either may be sent to a model natively), and `:file`
  (anything unrecognised, always stored as `application/octet-stream`).

  No field is castable from user input: only `Mythweaver.Attachments` writes rows, through
  `changeset/2`. `storage` must list exactly `Mythweaver.Attachments.Storage.backends/0`'s keys.
  """

  use Mythweaver.Schema

  import Ecto.Changeset

  alias Mythweaver.Accounts.User
  alias Mythweaver.AI.Model

  @type t :: %__MODULE__{}
  @type kind :: :image | :document | :audio | :video | :file

  schema "attachments" do
    field :kind, Ecto.Enum, values: [:image, :document, :audio, :video, :file]
    field :source, Ecto.Enum, values: [:upload, :generated], default: :upload
    field :status, Ecto.Enum, values: [:pending, :ready], default: :pending
    field :storage, Ecto.Enum, values: [:local, :s3]
    field :key, :string
    field :content_type, :string
    field :byte_size, :integer
    field :width, :integer
    field :height, :integer
    field :blurhash, :string
    field :filename, :string
    field :text_content, :string
    field :page_count, :integer
    field :description, :string
    field :caption_status, Ecto.Enum, values: [:none, :pending, :review, :done, :failed], default: :none
    field :caption_error, :string

    belongs_to :described_by, Model, foreign_key: :described_by_model_id
    belongs_to :uploaded_by, User

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Every attachment kind."
  def kinds, do: Ecto.Enum.values(__MODULE__, :kind)

  @doc "Every write; `Mythweaver.Attachments` builds `attrs`, never a user."
  def changeset(attachment, attrs) do
    attachment
    |> change(attrs)
    |> validate_required([:kind, :source, :status, :storage, :key, :content_type])
    |> unique_constraint(:key)
    |> foreign_key_constraint(:described_by_model_id)
    |> foreign_key_constraint(:uploaded_by_id)
  end
end
