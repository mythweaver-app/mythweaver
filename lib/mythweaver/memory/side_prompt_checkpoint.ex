defmodule Mythweaver.Memory.SidePromptCheckpoint do
  @moduledoc """
  How far a side prompt has run in one chat: `last_position` is the `Messages.Message.position` its
  last run covered. Interval triggers count messages after it. Only `Mythweaver.Memory` writes it.
  A set row's run (`side_prompt_set_row_id`) keeps its own checkpoint; nil is the side prompt run
  individually.
  """

  use Mythweaver.Schema

  import Ecto.Changeset

  alias Mythweaver.Chats.Chat
  alias Mythweaver.Memory.SidePrompt
  alias Mythweaver.Memory.SidePromptSetRow

  @type t :: %__MODULE__{}

  schema "side_prompt_checkpoints" do
    field :last_position, :integer

    belongs_to :chat, Chat
    belongs_to :side_prompt, SidePrompt
    belongs_to :side_prompt_set_row, SidePromptSetRow

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(checkpoint, attrs) do
    checkpoint
    |> cast(attrs, [:chat_id, :side_prompt_id, :side_prompt_set_row_id, :last_position])
    |> validate_required([:chat_id, :side_prompt_id, :last_position])
    |> unique_constraint([:chat_id, :side_prompt_id, :side_prompt_set_row_id],
      name: :side_prompt_checkpoints_chat_side_prompt_row_index
    )
  end
end
