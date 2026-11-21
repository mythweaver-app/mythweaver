defmodule Mythweaver.Attachments.Proxy.Fastly do
  @moduledoc """
  Fastly Image Optimizer query parameters. Config: `base_url`, a Fastly service fronting the object
  store (`<base_url>/<key>`); unset, the parameters go on the object's own signed link, which must
  then already be served through Fastly (local storage behind a Fastly service; an S3 presigned
  link is not, so S3 needs `base_url`).

  With `base_url` the link carries no signature: Fastly has none of its own on Image Optimizer URLs,
  so expiring them needs the service's own token check (VCL token authentication). Over local
  storage `/uploads` serves images only to requests carrying the `x-mythweaver-origin-secret` header
  (`uploads_origin_secret`), which the service's VCL sets on what it forwards.
  """

  @behaviour Mythweaver.Attachments.Proxy

  @impl true
  def url(source, key, {w, h, fit}, _expires_at, cfg) do
    fit = if fit == :cover, do: "crop", else: "bounds"
    height = if h, do: "&height=#{h}", else: ""
    query(source, key, cfg, "width=#{w}#{height}&fit=#{fit}&auto=webp")
  end

  # Image Optimizer re-encodes what it serves; the original is the source.
  @impl true
  def original_url(source, _key, _expires_at, _cfg), do: source

  @impl true
  def stills?, do: false

  @impl true
  def png_url(source, key, _expires_at, cfg), do: query(source, key, cfg, "format=png")

  defp query(source, key, cfg, params) do
    base = if b = cfg[:base_url], do: "#{String.trim_trailing(b, "/")}/#{key}", else: source
    separator = if String.contains?(base, "?"), do: "&", else: "?"
    base <> separator <> params
  end
end
