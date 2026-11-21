defmodule Mythweaver.Moderation.LogEntry do
  @moduledoc """
  One row of the moderation log (`Mythweaver.Moderation.Log`): a moderation action, or a look at
  private content, by `actor` (nil: an automatic outcome, `Log.record_system/5`) on `subject_type`/`subject_id`, answerable to `target_user`.
  """

  use Mythweaver.Schema

  alias Mythweaver.Accounts.User

  @type t :: %__MODULE__{}
  @type action ::
          :viewed
          | :report_dismissed
          | :warned
          | :banned
          | :ban_lifted
          | :deleted
          | :taken_down
          | :hold_approved
          | :hold_rejected
          | :rule_created
          | :rule_updated
          | :rule_deleted

  schema "moderation_log" do
    field :action, Ecto.Enum,
      values: [
        :viewed,
        :report_dismissed,
        :warned,
        :banned,
        :ban_lifted,
        :deleted,
        :taken_down,
        :hold_approved,
        :hold_rejected,
        :rule_created,
        :rule_updated,
        :rule_deleted
      ]

    field :subject_type, Ecto.Enum,
      values: [
        :user,
        :chat,
        :message,
        :listing,
        :report,
        :ban,
        :ai_provider,
        :character,
        :lore_book,
        :lore_entry,
        :lore_pool,
        :prompt,
        :block,
        :outlet,
        :script,
        :memory_profile,
        :side_prompt,
        :side_prompt_set,
        :ai_model,
        :expression_profile,
        :import,
        :moderation_rule
      ]

    field :subject_id, Ecto.UUID
    field :details, :map, default: %{}

    belongs_to :actor, User
    belongs_to :target_user, User

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
