defmodule Mythweaver.Attachments.ImageInfo do
  @moduledoc """
  Content type and pixel dimensions of an image, read from its first bytes.

  Decided by magic bytes only: a client's declared type and a file's extension are never trusted.
  Only PNG, JPEG and WebP are recognised: every vision API accepts all three. GIF is refused (several
  vision APIs reject it, and animation is lost on the way), and SVG is refused on purpose: served
  from this origin it is script, not an image.

  A JPEG whose start-of-frame marker lies past the bytes given is still a JPEG; its dimensions come
  back `nil`.
  """

  import Bitwise

  @type info :: %{content_type: String.t(), width: pos_integer() | nil, height: pos_integer() | nil}

  @spec parse(binary()) :: {:ok, info()} | {:error, :unsupported_type}
  def parse(<<0x89, "PNG\r\n", 0x1A, "\n", _len::32, "IHDR", w::32, h::32, _::binary>>), do: ok("image/png", w, h)

  def parse(<<"RIFF", _::32, "WEBP", chunk::binary-size(4), _size::32, data::binary>>), do: webp(chunk, data)

  def parse(<<0xFF, 0xD8, rest::binary>>), do: jpeg(rest)

  def parse(_), do: {:error, :unsupported_type}

  # Lossy: 3-byte frame tag, 3-byte start code, then 14-bit little-endian width and height.
  defp webp("VP8 ", <<_tag::24, 0x9D, 0x01, 0x2A, w::little-16, h::little-16, _::binary>>),
    do: ok("image/webp", w &&& 0x3FFF, h &&& 0x3FFF)

  # Lossless: signature byte, then width-1 and height-1 packed as 14 + 14 bits.
  defp webp("VP8L", <<0x2F, bits::little-32, _::binary>>),
    do: ok("image/webp", (bits &&& 0x3FFF) + 1, (bits >>> 14 &&& 0x3FFF) + 1)

  # Extended: flags, 3 reserved bytes, then 24-bit width-1 and height-1.
  defp webp("VP8X", <<_flags, _reserved::24, w::little-24, h::little-24, _::binary>>),
    do: ok("image/webp", w + 1, h + 1)

  defp webp(_chunk, _data), do: {:error, :unsupported_type}

  # Fill bytes before a marker.
  defp jpeg(<<0xFF, 0xFF, rest::binary>>), do: jpeg(<<0xFF, rest::binary>>)

  # Standalone markers (TEM, RSTn) carry no length.
  defp jpeg(<<0xFF, marker, rest::binary>>) when marker == 0x01 or marker in 0xD0..0xD7, do: jpeg(rest)

  defp jpeg(<<0xFF, marker, _len::16, _precision, h::16, w::16, _::binary>>)
       when marker in 0xC0..0xCF and marker not in [0xC4, 0xC8, 0xCC], do: ok("image/jpeg", w, h)

  defp jpeg(<<0xFF, _marker, len::16, rest::binary>>) when len >= 2 do
    skip = len - 2

    case rest do
      <<_::binary-size(^skip), next::binary>> -> jpeg(next)
      _ -> {:ok, %{content_type: "image/jpeg", width: nil, height: nil}}
    end
  end

  defp jpeg(_), do: {:ok, %{content_type: "image/jpeg", width: nil, height: nil}}

  defp ok(type, w, h), do: {:ok, %{content_type: type, width: positive(w), height: positive(h)}}

  defp positive(n) when n > 0, do: n
  defp positive(_), do: nil
end
