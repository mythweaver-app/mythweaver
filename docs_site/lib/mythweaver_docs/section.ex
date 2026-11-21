defmodule MythweaverDocs.Section do
  @moduledoc "A directory of `docs/`: its `index.md` (`index`, which gives `title` and `order`) and its pages."

  @type t :: %__MODULE__{}

  defstruct [:key, :title, :order, :index, pages: []]
end
