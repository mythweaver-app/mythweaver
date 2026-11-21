defmodule Mythweaver.Jobs.Job do
  @moduledoc """
  One generation request as `Mythweaver.Jobs` tracks it: what kind it is (`tag`), whether a person is
  waiting on it (`origin`), and where it got to (`status`). `prompt_name` is the name of the prompt
  that built the request, copied when the job was built; nil when no named prompt was used (the
  assistant, a caption's built-in instruction).

  No field is castable from user input. Only `Mythweaver.Jobs` writes rows, through
  `create_changeset/2` and `status_changeset/2`.
  """

  use Mythweaver.Schema

  import Ecto.Changeset

  alias Mythweaver.Accounts.User
  alias Mythweaver.AI.Model
  alias Mythweaver.AI.Provider
  alias Mythweaver.Chats.Chat

  @tags [
    :reply,
    :regenerate,
    :continue,
    :refine,
    :memory,
    :side_prompt,
    :consolidation,
    :compaction,
    :topical_clip,
    :memory_assistance,
    :caption,
    :expression,
    :assistant
  ]
  @statuses [:queued, :running, :review, :completed, :failed, :canceled, :interrupted]

  schema "generation_jobs" do
    field :tag, Ecto.Enum, values: @tags
    field :origin, Ecto.Enum, values: [:interactive, :background]
    field :status, Ecto.Enum, values: @statuses
    field :label, :string
    field :prompt_name, :string
    field :params, :map, default: %{}
    field :result, :map
    field :raw_output, :string
    field :error, :string
    field :attempts, :integer, default: 0
    field :range_start, :integer
    field :range_end, :integer
    field :usage, :map
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :first_token_at, :utc_datetime_usec
    field :expected_first_token_ms, :integer

    belongs_to :chat, Chat
    belongs_to :model, Model, foreign_key: :ai_model_id
    belongs_to :provider, Provider
    belongs_to :parent, __MODULE__
    belongs_to :user, User

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The fields a new row is created with; `Mythweaver.Jobs` builds `attrs`, never a user."
  def create_changeset(job, attrs) do
    job
    |> change(attrs)
    |> validate_required([:tag, :origin, :status, :label])
    |> foreign_key_constraint(:chat_id)
    |> foreign_key_constraint(:ai_model_id)
    |> foreign_key_constraint(:parent_id)
  end

  @doc "A status transition and whatever it records (`result`, `error`, timestamps, …)."
  def status_changeset(job, attrs) do
    job
    |> change(attrs)
    |> validate_required([:status])
  end
end
