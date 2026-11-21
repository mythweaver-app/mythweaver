defmodule Mythweaver.AI.ModelGroup do
  @moduledoc """
  One permission group allowed to run a site model. A site model with no rows is open to everyone
  holding `ai.site_models.use`. Rows are written only by `Mythweaver.AI.set_model_groups/3`, so
  there is no changeset.
  """

  use Mythweaver.Schema

  alias Mythweaver.AI.Model
  alias Mythweaver.Permissions.Group

  @primary_key false
  schema "ai_model_groups" do
    belongs_to :ai_model, Model
    belongs_to :group, Group
  end
end
