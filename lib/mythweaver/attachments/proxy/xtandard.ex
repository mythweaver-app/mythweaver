defmodule Mythweaver.Attachments.Proxy.Xtandard do
  @moduledoc """
  [xtandard-image](https://me.xantiagoma.com/xtandard-image/) ("xi") URLs, in its canonical
  dialect: `<base_url>/<signature>/<processing>/exp:<expires_at>/enc/<token>`, and its metadata
  queries, `<base_url>/info/<signature>/<options>/exp:<expires_at>/enc/<token>`. An original is
  `raw:1` in place of the processing: the stored bytes, untouched.

  Config: `base_url`, hex `key` and `salt` (xi's `XI_SIGNING_KEYS`/`XI_SIGNING_SALTS`; required: an
  unsigned xi would resize any source, at any size, for anyone), hex `encryption_key` (xi's
  `XI_ENCRYPTION_KEYS`; 16, 24 or 32 bytes, picking AES-128, -192 or -256) and `source_prefix`.
  With `source_prefix` set, xi fetches `source_prefix <> key` (e.g. `"xi://uploads/"`, its
  `uploads` filesystem source) instead of the signed link, which is the only way it can reach
  locally stored objects (their links are relative). `internal_url` is read by
  `Mythweaver.Attachments`, not here.

  The source travels encrypted (`enc/`), so a URL does not reveal where the bytes live. Its IV is
  derived from the source (an HMAC under the encryption key), not random: one source gives one URL
  per link window, so browsers and nginx can cache it, while two sources never share an IV.

  Every URL carries `exp:` (signed with the rest), so xi answers 404 after `expires_at`; its
  responses should not outlive that either (`XI_CACHE_HEADERS_TTL`). `g:sm` on xi's `full` image
  crops to detected faces, falling back to libvips attention when it finds none.

  ## Why not the xtandard_image library

    1. It is not on Hex: it installs only as a git dependency (`github: "xantiagoma/xtandard-image",
       sparse: "clients/elixir"`). It is ZeroVer and versioned with the server, so a minor bump may
       break its API.
    2. Its `enc/` tokens use a random IV, which gives a new URL on every render and defeats browser
       and nginx caching. Its alternative is one fixed IV per key, the same for every source, whose
       shared `xi://uploads/attachments/` prefix makes every URL's first cipher block identical.
       This module derives a per-source IV from an HMAC instead.
    3. The app builds four URL shapes and one `/info` query, a few dozen lines. The typed builders
       over hundreds of options would go unused.
    4. Wire compatibility is still checked against upstream: `proxy_test.exs` runs vectors from the
       official clients' shared conformance fixture (`clients/spec/conformance.json`, tag v0.1.1).
  """

  @behaviour Mythweaver.Attachments.Proxy

  @impl true
  def url(source, key, {w, h, fit}, expires_at, cfg) do
    processing =
      case fit do
        # `fill-down` crops to the box's aspect ratio even from a source smaller than the box;
        # plain `fill` without enlarging would not.
        :cover -> "rs:fill-down:#{w}:#{h}:0/g:sm"
        # A 0 height reads as "whatever the width makes it".
        :contain -> "rs:fit:#{w}:#{h || 0}:0"
      end

    base(cfg) <> signed_path(processing, source, key, expires_at, cfg)
  end

  # `raw:1`: xi streams the stored bytes untouched (no resize, no format negotiation), behind the
  # same signature, expiry and encrypted source as every other URL.
  @impl true
  def original_url(source, key, expires_at, cfg), do: base(cfg) <> signed_path("raw:1", source, key, expires_at, cfg)

  @impl true
  def stills?, do: true

  # `f:png` with no resize: the whole image, re-encoded.
  @impl true
  def png_url(source, key, expires_at, cfg), do: base(cfg) <> signed_path("f:png", source, key, expires_at, cfg)

  @doc """
  xi's `/info` URL for `source` with `options` (e.g. `"bh:4:3"`, a 4×3-component blurhash). The
  signature covers the path after it, not the `/info` prefix.
  """
  @spec info_url(String.t(), String.t(), String.t(), integer(), keyword()) :: String.t()
  def info_url(source, key, options, expires_at, cfg),
    do: base(cfg) <> "/info" <> signed_path(options, source, key, expires_at, cfg)

  # `/<signature>/<options>/exp:<expires_at>/enc/<token>`; the signature covers what follows it.
  defp signed_path(options, source, key, expires_at, cfg) do
    path = "/" <> options <> "/exp:#{expires_at}/enc/" <> encrypt(src(source, key, cfg), cfg[:encryption_key])
    "/" <> sign(path, cfg[:key], cfg[:salt]) <> path
  end

  defp src(source, key, cfg), do: if(prefix = cfg[:source_prefix], do: prefix <> key, else: source)

  defp base(cfg), do: String.trim_trailing(cfg[:base_url], "/")

  @doc "xi's URL signature for `path`: HMAC-SHA256 over `salt <> path`, url-safe base64."
  @spec sign(String.t(), String.t(), String.t()) :: String.t()
  def sign(path, key, salt) when is_binary(key) and is_binary(salt) do
    :hmac
    |> :crypto.mac(:sha256, Base.decode16!(key, case: :mixed), Base.decode16!(salt, case: :mixed) <> path)
    |> Base.url_encode64(padding: false)
  end

  @doc "xi's `enc/` token for `src` under hex `encryption_key`, with an IV derived from `src`."
  @spec encrypt(String.t(), String.t()) :: String.t()
  def encrypt(src, encryption_key) when is_binary(encryption_key) do
    key = Base.decode16!(encryption_key, case: :mixed)
    seal(src, key, :hmac |> :crypto.mac(:sha256, key, src) |> binary_part(0, 16))
  end

  @doc "`base64url(iv <> AES-CBC(key, iv, PKCS#7(src)))`, unpadded; `key` raw, 16, 24 or 32 bytes."
  @spec seal(String.t(), binary(), <<_::128>>) :: String.t()
  def seal(src, key, <<_::binary-size(16)>> = iv) do
    pad = 16 - rem(byte_size(src), 16)
    ciphertext = :crypto.crypto_one_time(cipher(byte_size(key)), key, iv, src <> :binary.copy(<<pad>>, pad), true)
    Base.url_encode64(iv <> ciphertext, padding: false)
  end

  defp cipher(16), do: :aes_128_cbc
  defp cipher(24), do: :aes_192_cbc
  defp cipher(32), do: :aes_256_cbc
end
