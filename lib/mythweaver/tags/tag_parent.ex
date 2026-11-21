defmodule Mythweaver.Tags.TagParent do
  @moduledoc """
  One parent pair: every item carrying `tag` also counts as carrying `parent_tag`. Both rows are of
  one domain. Parents are never copied onto items; `Mythweaver.Tags.Graph` expands them on read.
  """

  use Mythweaver.Schema

  alias Mythweaver.Tags.Tag

  schema "tag_parents" do
    belongs_to :tag, Tag
    belongs_to :parent_tag, Tag

    timestamps(type: :utc_datetime)
  end
end
