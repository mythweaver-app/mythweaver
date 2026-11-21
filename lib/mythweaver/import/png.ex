defmodule Mythweaver.Import.Png do
  @moduledoc """
  Reads the `tEXt` chunks of a PNG, where character cards keep their JSON (`chara` for V1/V2,
  `ccv3` for V3, each base64-encoded). CRCs are not checked. The avatar is the PNG without its text
  chunks, so the card JSON (often most of the file) is not stored again with the image.
  """

  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.Import.Card

  @signature <<137, 80, 78, 71, 13, 10, 26, 10>>
  @text_chunks ~w(tEXt zTXt iTXt)

  defp invalid, do: dgettext("import_export", "This isn't a valid PNG file.")

  @doc "Every `tEXt` chunk as `keyword => text`; the first chunk wins on a repeated keyword."
  @spec text_chunks(binary()) :: {:ok, %{String.t() => binary()}} | {:error, String.t()}
  def text_chunks(bytes) do
    with {:ok, texts, _image} <- split(bytes), do: {:ok, texts}
  end

  @doc "The PNG without its `tEXt`/`zTXt`/`iTXt` chunks."
  @spec strip_text(binary()) :: {:ok, binary()} | {:error, String.t()}
  def strip_text(bytes) do
    with {:ok, _texts, image} <- split(bytes), do: {:ok, image}
  end

  @doc "The normalized character card in a PNG, with the PNG minus its text chunks as the avatar."
  @spec card(binary()) :: {:ok, Card.t()} | {:error, String.t()}
  def card(bytes) do
    with {:ok, chunks, image} <- split(bytes),
         {:ok, encoded} <- card_chunk(chunks),
         {:ok, json} <- decode(encoded),
         {:ok, card} <- Card.normalize(json) do
      {:ok, %{card | avatar: image}}
    end
  end

  # The `tEXt` texts, and the PNG rebuilt from every chunk but `tEXt`/`zTXt`/`iTXt`.
  defp split(<<@signature, rest::binary>>), do: walk(rest, %{}, [@signature])
  defp split(_bytes), do: {:error, invalid()}

  defp walk(<<0::32, "IEND", crc::32, _rest::binary>>, texts, kept),
    do: {:ok, texts, IO.iodata_to_binary(Enum.reverse([<<0::32, "IEND", crc::32>> | kept]))}

  defp walk(<<len::32, type::binary-4, data::binary-size(len), crc::32, rest::binary>>, texts, kept) do
    texts = if type == "tEXt", do: put_text(texts, data), else: texts
    kept = if type in @text_chunks, do: kept, else: [<<len::32, type::binary, data::binary, crc::32>> | kept]
    walk(rest, texts, kept)
  end

  defp walk(_bytes, _texts, _kept), do: {:error, invalid()}

  defp put_text(acc, data) do
    case :binary.split(data, <<0>>) do
      [keyword, text] -> Map.put_new(acc, keyword, text)
      _no_separator -> acc
    end
  end

  defp card_chunk(chunks) do
    by_key = Map.new(chunks, fn {key, value} -> {String.downcase(key), value} end)

    case by_key["ccv3"] || by_key["chara"] do
      nil -> {:error, dgettext("import_export", "This PNG has no character card in it.")}
      encoded -> {:ok, encoded}
    end
  end

  defp decode(encoded) do
    trimmed = String.trim(encoded)

    with {:ok, raw} <- base64(trimmed),
         {:ok, json} when is_map(json) <- Jason.decode(raw) do
      {:ok, json}
    else
      _bad -> {:error, dgettext("import_export", "This PNG's character card isn't valid JSON.")}
    end
  end

  defp base64(text) do
    case Base.decode64(text, ignore: :whitespace) do
      {:ok, raw} -> {:ok, raw}
      :error -> Base.decode64(text, ignore: :whitespace, padding: false)
    end
  end
end
