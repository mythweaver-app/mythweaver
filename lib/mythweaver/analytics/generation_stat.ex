defmodule Mythweaver.Analytics.GenerationStat do
  @moduledoc """
  One finished run of a generation job, kept after the job row is pruned (`Mythweaver.Jobs.prune/0`),
  or one direct call (`job_id` nil, `Mythweaver.Analytics.record_call/1`): an embedding (`tag: :embedding`) or a classifier expression (`tag: :expression`):
  who ran it, on which model and connection, how it ended, what it used, and when its first token
  came. A retried job runs again and adds a second row.

  `prompt_tokens` and `completion_tokens` come from the backend's usage report, so they are nil for
  a run that reported none (a stopped stream). `cost` is the provider's charge when it reports one
  (OpenRouter), else an estimate at the model's per-Mtok prices with `cost_estimated` set (the rule
  `Mythweaver.Generation.Server` applies to a message body), else nil. Only `Mythweaver.Analytics`
  writes rows; no field is castable.
  """

  use Mythweaver.Schema

  alias Mythweaver.Accounts.User
  alias Mythweaver.AI.Model
  alias Mythweaver.AI.Provider
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Jobs.Job

  @statuses [:completed, :review, :failed, :canceled, :interrupted]

  schema "generation_stats" do
    field :job_id, Ecto.UUID
    field :tag, Ecto.Enum, values: Ecto.Enum.values(Job, :tag) ++ [:embedding]
    field :origin, Ecto.Enum, values: [:interactive, :background]
    field :status, Ecto.Enum, values: @statuses
    field :prompt_tokens, :integer
    field :completion_tokens, :integer
    field :cached_tokens, :integer
    field :cost, :decimal
    field :cost_estimated, :boolean, default: false
    field :started_at, :utc_datetime_usec
    field :first_token_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    belongs_to :user, User
    belongs_to :chat, Chat
    belongs_to :model, Model, foreign_key: :ai_model_id
    belongs_to :provider, Provider

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "The statuses a run can end in."
  def statuses, do: @statuses
end
