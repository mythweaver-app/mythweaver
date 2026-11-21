defmodule Mythweaver.Attachments.Proxy do
  @moduledoc """
  Behaviour every image-proxy URL builder satisfies, and the registry of them.

  The app never resizes an image itself: a page asks for a named preset (`presets/0`) and the active
  proxy (`config :mythweaver, Mythweaver.Attachments, proxy: …`) turns the object's signed link into
  a link that serves it at that size. `:none` returns the original and lets CSS scale it.
  `Mythweaver.Attachments.url(attachment, :original)` is the stored bytes, unresized, through
  `original_url/4`: a proxy that can pass them through unchanged (xtandard-image) keeps them behind
  its own signed URL, the others return the storage link. A proxy that also renders stills
  (`stills?/0`) turns a video into a frame and a PDF into its first page, at the same presets
  (`Mythweaver.Attachments.still_url/2`). One that re-encodes to PNG (`png_url/4`) also turns any
  image into a PNG at its own size (`Mythweaver.Attachments.png/1`, for PNG character cards).

  Add a proxy by writing the module and adding one `{atom, module}` pair to `@proxies` below; its
  settings live under the same atom in the attachments config.
  """

  alias Mythweaver.Attachments.Proxy.Cloudflare
  alias Mythweaver.Attachments.Proxy.Fastly
  alias Mythweaver.Attachments.Proxy.None
  alias Mythweaver.Attachments.Proxy.Xtandard

  @typedoc """
  A box to scale into. A `nil` height bounds the width only, and needs `:contain`. `:cover` fills the
  box and crops the overflow, keeping the box's aspect ratio; from a source smaller than the box, the
  proxy may send it smaller than the box, at the same ratio.
  """
  @type size ::
          {width :: pos_integer(), height :: pos_integer() | nil, fit :: :cover | :contain}

  @doc """
  The URL that serves `source` (the object's signed storage link, whose storage key is `key`) at
  `size`, until `expires_at` (unix seconds) where the proxy can enforce it. `config` is the proxy's
  own keyword list.
  """
  @callback url(source :: String.t(), key :: String.t(), size(), expires_at :: integer(), config :: keyword()) ::
              String.t()

  @doc """
  The URL that serves `source` unresized and unconverted, byte for byte, until `expires_at`. A proxy
  that cannot pass bytes through returns `source`, the storage link.
  """
  @callback original_url(source :: String.t(), key :: String.t(), expires_at :: integer(), config :: keyword()) ::
              String.t()

  @doc "Whether the proxy renders a still of a video (a frame it picks) and of a PDF (its first page)."
  @callback stills?() :: boolean()

  @doc """
  The URL that serves `source` re-encoded as a PNG, unresized, until `expires_at`; `nil` from a
  proxy that can't (Cloudflare's `format` writes only AVIF, WebP and JPEG).
  """
  @callback png_url(source :: String.t(), key :: String.t(), expires_at :: integer(), config :: keyword()) ::
              String.t() | nil

  @proxies %{none: None, xtandard: Xtandard, cloudflare: Cloudflare, fastly: Fastly}

  @presets %{
    avatar: {96, 96, :cover},
    portrait: {192, 256, :cover},
    # An expression sprite in a portrait's box: the whole figure, never cropped.
    sprite: {192, 256, :contain},
    thumb: {320, 320, :contain},
    # An image in a chat message: as wide as its figure allows (30rem; 480 px at the phones' 16 px
    # root) at 2x density, and as tall as that makes it, since the figure caps only the width.
    inline: {960, nil, :contain},
    full: {2048, 2048, :contain},
    # What a vision model is sent (`Mythweaver.Attachments.model_image/1`): the 2048 px box OpenAI
    # scales into anyway, which keeps requests small and per-tile token costs bounded.
    model: {2048, 2048, :contain}
  }

  # The widths a `srcset` offers per preset (`Mythweaver.Attachments.srcset/2`), each at the
  # preset's aspect ratio: from the preset's own width up to its largest box at 4x density.
  # :avatar boxes are at most 40px (2.5rem); :portrait and :sprite at most 300px (a chat message's aside).
  @srcset_widths %{
    avatar: [96, 160],
    portrait: [192, 300, 420, 600, 900, 1200],
    sprite: [192, 300, 420, 600, 900, 1200]
  }

  @doc "The implementation module for a registered proxy atom."
  def module_for(proxy) when is_map_key(@proxies, proxy), do: Map.fetch!(@proxies, proxy)

  @doc "The full `%{atom => module}` registry."
  def proxies, do: @proxies

  @doc "The named sizes the app asks for; `srcset_sizes/1` scales :avatar, :portrait and :sprite to its srcset widths."
  def presets, do: @presets

  @doc "A preset's size; raises on an unknown name."
  def preset!(name) when is_map_key(@presets, name), do: Map.fetch!(@presets, name)
  def preset!(name), do: raise(ArgumentError, "unknown image preset: #{inspect(name)}")

  @doc """
  A preset's `srcset` candidates, `{width, size}`, each `size` the preset's box scaled to `width`
  (so the same aspect ratio and fit). Raises for a preset with no srcset widths.
  """
  @spec srcset_sizes(atom()) :: [{pos_integer(), size()}]
  def srcset_sizes(name) when is_map_key(@srcset_widths, name) do
    {w, h, fit} = preset!(name)
    for width <- Map.fetch!(@srcset_widths, name), do: {width, {width, h && div(h * width, w), fit}}
  end

  def srcset_sizes(name), do: raise(ArgumentError, "no srcset widths for image preset: #{inspect(name)}")
end
