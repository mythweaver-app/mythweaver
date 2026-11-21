defmodule Mythweaver.Moderation.Report do
  @moduledoc """
  A report of moderated content (`Mythweaver.Moderation.Reports`). A `source: :user` report is a
  user's report of a catalog listing, an account or a chat message, with its `reporter`; a
  `source: :rule` report is opened by the content-moderation rules (`Reports.flag/5`) on a chat, a
  message or saved content, has no reporter, and lists the rule hits in `findings` (string-keyed
  maps: `"rule"`, `"action"`, `"field"`, `"excerpt"`, `"reason"`). A subject has at most one open
  rule report; a later match updates it.

  `subject_id` names a row of `subject_type`'s table (no FK); `snapshot` is the subject's text when it
  was reported, so the report still reads after the subject changes or goes. `subject_user` is the
  account answerable for it. `status` moves `:open` → `:dismissed` or `:actioned`.
  """

  use Mythweaver.Schema

  import Ecto.Changeset

  alias Mythweaver.Accounts.User

  @type t :: %__MODULE__{}
  @type subject_type ::
          :listing
          | :user
          | :message
          | :chat
          | :character
          | :lore_book
          | :lore_entry
          | :ai_provider
          | :ai_model
          | :prompt
          | :block
          | :outlet

  @subject_types [
    :listing,
    :user,
    :message,
    :chat,
    :character,
    :lore_book,
    :lore_entry,
    :ai_provider,
    :ai_model,
    :prompt,
    :block,
    :outlet
  ]

  schema "moderation_reports" do
    field :subject_type, Ecto.Enum, values: @subject_types
    field :source, Ecto.Enum, values: [:user, :rule], default: :user
    field :findings, {:array, :map}, default: []
    field :subject_id, Ecto.UUID
    field :snapshot, :string
    field :reason, :string
    field :status, Ecto.Enum, values: [:open, :dismissed, :actioned], default: :open
    field :resolved_at, :utc_datetime

    belongs_to :reporter, User
    belongs_to :subject_user, User
    belongs_to :resolved_by, User

    timestamps(type: :utc_datetime)
  end

  @doc "Every subject type a report may name."
  @spec subject_types() :: [subject_type()]
  def subject_types, do: @subject_types

  @doc "A changeset for the reporter's reason."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(report, attrs) do
    report
    |> cast(attrs, [:reason])
    |> validate_required([:reason])
    |> validate_length(:reason, max: 2000)
    |> unique_constraint([:reporter_id, :subject_type, :subject_id], name: :moderation_reports_one_open_index)
  end
end
