defmodule MythweaverWeb.CoreComponents.WordDiff do
  @moduledoc """
  A word-level diff of two texts (`Mythweaver.Messages.WordDiff`): insertions highlighted green,
  deletions red and struck through, whitespace kept. The swipe inspector and the lore entry form's
  Diff both render it.
  """

  use Phoenix.Component

  alias Mythweaver.Messages.WordDiff

  attr :id, :string, required: true
  attr :old, :string, required: true
  attr :new, :string, required: true
  attr :class, :any, default: nil, doc: "layout hook for the caller"

  def word_diff(assigns) do
    assigns = assign(assigns, :chunks, WordDiff.diff(assigns.old, assigns.new))

    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      div:scope {
        white-space: pre-wrap;
        overflow-wrap: anywhere;
      }

      ins {
        background: oklch(0.6 0.15 145 / 0.3);
        text-decoration: none;
      }

      del {
        background: oklch(0.6 0.2 25 / 0.3);
        text-decoration: line-through;
      }
    </style>
    <div id={@id} class={["word-diff", @class]} phx-no-format><%= for {op, chunk} <- @chunks do %><%= case op do %><% :eq -> %>{chunk}<% :ins -> %><ins>{chunk}</ins><% :del -> %><del>{chunk}</del><% end %><% end %></div>
    """
  end
end
