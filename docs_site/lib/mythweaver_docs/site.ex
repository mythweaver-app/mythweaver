defmodule MythweaverDocs.Site do
  @moduledoc """
  Everything `MythweaverDocs.Content.load!/1` found: the home page, the sections in nav order,
  every page in reading order (home, then each section's index and pages), pages by permalink, and
  the non-Markdown files (relative paths) copied verbatim.
  """

  @type t :: %__MODULE__{}

  defstruct [:home, sections: [], reading_order: [], by_permalink: %{}, assets: []]
end
