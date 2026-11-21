defmodule Mythweaver.Export.Png do
  @moduledoc """
  PNG chunk writing for character card exports: `embed/2` adds `tEXt` chunks (where cards keep their
  JSON) to an image, and `placeholder/0` is the image for a character without an avatar.
  """

  @signature <<137, 80, 78, 71, 13, 10, 26, 10>>
  @width 400
  @height 600
  @gray 128

  @doc "A 400×600 solid `#808080` RGB PNG."
  @spec placeholder() :: binary()
  def placeholder do
    row = <<0>> <> :binary.copy(<<@gray, @gray, @gray>>, @width)

    IO.iodata_to_binary([
      @signature,
      chunk("IHDR", <<@width::32, @height::32, 8, 2, 0, 0, 0>>),
      chunk("IDAT", :zlib.compress(:binary.copy(row, @height))),
      chunk("IEND", <<>>)
    ])
  end

  @doc """
  `png` with a `tEXt` chunk (`keyword <> <<0>> <> text`) per `{keyword, text}` inserted, in order,
  just before `IEND`. `png` must be a well-formed PNG (`Mythweaver.Import.Png.strip_text/1`'s output
  or `placeholder/0`).
  """
  @spec embed(binary(), [{String.t(), binary()}]) :: binary()
  def embed(<<@signature, rest::binary>>, texts) do
    {chunks, iend} = split_iend(rest, [])
    texts = Enum.map(texts, fn {keyword, text} -> chunk("tEXt", keyword <> <<0>> <> text) end)
    IO.iodata_to_binary([@signature, chunks, texts, iend])
  end

  defp split_iend(<<0::32, "IEND", crc::32, _rest::binary>>, acc), do: {Enum.reverse(acc), <<0::32, "IEND", crc::32>>}

  defp split_iend(<<len::32, type::binary-4, data::binary-size(len), crc::32, rest::binary>>, acc),
    do: split_iend(rest, [<<len::32, type::binary, data::binary, crc::32>> | acc])

  defp chunk(type, data), do: <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>
end
