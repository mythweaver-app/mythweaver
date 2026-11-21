defmodule Mythweaver.Moderation.Scan do
  @moduledoc """
  One run of the moderation rules over some content (`Mythweaver.Moderation.Scanner`): a held item
  (`hold_id`) or a saved row (`subject_type`/`subject_id`). `fields` are the `{label, text}` pairs
  rules read and `snapshot` the text a report keeps. `awaiting` maps each callback-mode webhook rule
  still to answer to `{deadline_ms, rule_name}`; while it is non-empty the scan waits in
  `Mythweaver.Moderation.Store`. `chat_id` is set for message scans.
  """

  @type t :: %__MODULE__{}

  defstruct [
    :id,
    :type,
    :subject_type,
    :subject_id,
    :hold_id,
    :user_id,
    :title,
    :snapshot,
    :chat_id,
    action: :scan,
    fields: [],
    findings: [],
    awaiting: %{}
  ]
end
