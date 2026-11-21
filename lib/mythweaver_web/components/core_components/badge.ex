defmodule MythweaverWeb.CoreComponents.Badge do
  @moduledoc """
  A small pill label used to annotate an entity (e.g. the "You" marker on the
  current player's character in the participants list and on their messages).
  """

  use Phoenix.Component

  attr :class, :string, default: ""
  attr :rest, :global, doc: "arbitrary HTML attributes (e.g. id, aria-label)"
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      :scope {
        font-size: 0.75rem;
        padding: 0.1rem 0.4rem;
        border-radius: 4px;
        background: var(--primary);
        color: var(--primary-foreground);
      }
    </style>
    <span class={["badge", @class]} {@rest}>{render_slot(@inner_block)}</span>
    """
  end
end
