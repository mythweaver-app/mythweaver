defmodule MythweaverWeb.CoreComponents.AvatarImage do
  @moduledoc """
  A character's avatar `<img>` with a `srcset` of its preset's widths
  (`Mythweaver.Attachments.srcset/2`), so the browser picks a file for the box's CSS width and the
  screen's density; `<.avatar_placeholder>` when there is no image.

  The `<img>` is this component's root and carries `phx-r`, so a caller's scoped `img` rule must sit
  in a `lower-bound="none"` block.
  """

  use Phoenix.Component

  import MythweaverWeb.CoreComponents.AvatarPlaceholder, only: [avatar_placeholder: 1]

  alias Mythweaver.Attachments
  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Characters.Character

  attr :avatar, :any,
    required: true,
    doc:
      "a `Character` (its loaded `avatar`) or an avatar `Attachment`; anything else (nil, `NotLoaded`) shows the placeholder"

  attr :preset, :atom, required: true, values: [:avatar, :portrait, :sprite]

  attr :sizes, :string,
    required: true,
    doc: "the `<img>` `sizes`: the box's CSS width in px, `auto, <px>` with `loading=\"lazy\"`"

  attr :alt, :string, default: ""
  attr :loading, :string, default: nil, values: [nil, "lazy"]

  @doc "The avatar at `preset`, or the placeholder."
  def avatar_image(assigns) do
    attachment = attachment(assigns.avatar)

    assigns =
      assign(assigns,
        src: Attachments.url(attachment, assigns.preset),
        srcset: Attachments.srcset(attachment, assigns.preset)
      )

    ~H"""
    <img
      :if={@src}
      src={@src}
      srcset={@srcset}
      sizes={@srcset && @sizes}
      alt={@alt}
      loading={@loading}
    />
    <.avatar_placeholder :if={!@src} />
    """
  end

  defp attachment(%Character{avatar: %Attachment{} = attachment}), do: attachment
  defp attachment(%Attachment{} = attachment), do: attachment
  defp attachment(_avatar), do: nil
end
