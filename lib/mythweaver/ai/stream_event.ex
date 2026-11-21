defmodule Mythweaver.AI.StreamEvent do
  @moduledoc """
  The events an adapter's `stream/3` passes to `on_event` (`Mythweaver.AI.Provider.Adapter`,
  "Streaming event contract"). Each is its own struct; consumers match on the struct, never on a
  `:type` field.
  """

  alias Mythweaver.AI.StreamEvent

  @type t ::
          StreamEvent.Request.t()
          | StreamEvent.Delta.t()
          | StreamEvent.Reasoning.t()
          | StreamEvent.Done.t()
          | StreamEvent.PromptProgress.t()
end
