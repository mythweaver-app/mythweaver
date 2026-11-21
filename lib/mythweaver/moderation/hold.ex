defmodule Mythweaver.Moderation.Hold do
  @moduledoc """
  A create, text edit or import held for review (`Mythweaver.Moderation.Holds`), kept only in
  `Mythweaver.Moderation.Store`'s memory: never written to storage, lost on restart.

  `op` is the `{module, function, args}` that saves it, without the leading scope; in `args`,
  `{:row, schema, id}` stands for that row reloaded at apply time. `followups` are run after a
  successful `op` in the same form, with the atom `:row` standing for the saved row. `previous` maps
  each changed text field's label to its old value (updates only). `kind` is a holdable
  `Mythweaver.Moderation.Subject` kind or `:import`; `status` is `:scanning` while rules run and
  `:review` once a moderator must decide.
  """

  @type t :: %__MODULE__{}

  defstruct [
    :id,
    :type,
    :kind,
    :action,
    :user_id,
    :target_id,
    :title,
    :op,
    :inserted_at,
    followups: [],
    fields: [],
    previous: %{},
    findings: [],
    status: :scanning,
    bytes: 0
  ]
end
