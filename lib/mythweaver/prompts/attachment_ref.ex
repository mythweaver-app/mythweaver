defmodule Mythweaver.Prompts.AttachmentRef do
  @moduledoc """
  `Mythweaver.Prompts.Builder`'s placeholder for an attachment part not read yet (an image, a PDF,
  an audio clip or a video clip). `Mythweaver.Attachments.inline_attachments/2` replaces each one
  with a `Mythweaver.AI.Request.Image`, `Request.File`, `Request.Audio` or `Request.Video` (or its
  text line); it never reaches an adapter, which has no clause for it.
  """

  alias Mythweaver.Attachments.Attachment

  @enforce_keys [:attachment]
  defstruct [:attachment]

  @type t :: %__MODULE__{attachment: Attachment.t()}
end
