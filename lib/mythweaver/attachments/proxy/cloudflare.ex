defmodule Mythweaver.Attachments.Proxy.Cloudflare do
  @moduledoc """
  Cloudflare Image Resizing URLs: `<zone_url>/cdn-cgi/image/<options>/<source>`. Config: `zone_url`,
  the origin of a zone with Image Transformations enabled.

  The source is the object's sealed link, so the origin (`/uploads`, or the S3 presigned link)
  checks it when Cloudflare fetches; over local storage `/uploads` also wants the
  `x-mythweaver-origin-secret` header (`uploads_origin_secret`), which a request-header Transform
  Rule adds to what the zone forwards. Cloudflare caches the result under the full link, which
  expires with it; Cloudflare has no signature of its own on transformation URLs, so checking the
  link at the edge needs the zone's own token rule (WAF `is_timed_hmac_valid_v0`, Pro plan and up).
  """

  @behaviour Mythweaver.Attachments.Proxy

  @impl true
  def url(source, _key, {w, h, fit}, _expires_at, cfg) do
    fit = if fit == :cover, do: "cover", else: "scale-down"
    height = if h, do: "height=#{h},", else: ""
    "#{String.trim_trailing(cfg[:zone_url], "/")}/cdn-cgi/image/width=#{w},#{height}fit=#{fit},format=auto/#{source}"
  end

  # Cloudflare re-encodes whatever it serves through `/cdn-cgi/image/`; the original is the source.
  @impl true
  def original_url(source, _key, _expires_at, _cfg), do: source

  @impl true
  def stills?, do: false

  # `format` writes AVIF, WebP or JPEG only.
  @impl true
  def png_url(_source, _key, _expires_at, _cfg), do: nil
end
