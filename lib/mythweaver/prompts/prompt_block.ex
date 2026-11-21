defmodule Mythweaver.Prompts.PromptBlock do
  @moduledoc """
  One block's membership in one prompt, carrying its position and per-prompt enablement.

  Exactly the role `Mythweaver.Lore.BookEntry` plays for a shared lore entry: the block is reusable, and
  everything prompt-specific about it lives here.

  `position` is a dense 0-based integer within one prompt, assigned by `Mythweaver.Prompts`, never by
  the user.
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Prompts.Block
  alias Mythweaver.Prompts.Prompt

  schema "prompt_prompt_blocks" do
    field :position, :integer
    field :enabled, :boolean, default: true

    belongs_to :prompt, Prompt
    belongs_to :block, Block

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(prompt_block, attrs) do
    prompt_block
    |> cast(attrs, [:prompt_id, :block_id, :position, :enabled])
    |> validate_required([:prompt_id, :block_id, :position])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> assoc_constraint(:prompt)
    |> assoc_constraint(:block)
    |> unique_constraint([:prompt_id, :block_id],
      name: :prompt_prompt_blocks_prompt_id_block_id_index,
      message: dgettext_noop("errors", "is already in this prompt")
    )
  end
end
