defmodule Mythweaver.Attachments.FileInfo do
  @moduledoc """
  What an uploaded file is: its attachment `kind` and the content type it is stored and served as.

  `parse/2` decides from the file's first bytes (images through `ImageInfo`, with dimensions), and
  only text documents also need the filename's extension, since plain text has no magic bytes.
  `claimed/2` maps a browser's declared type for a presigned upload, which `parse/2` later re-checks
  against the stored object. Anything unrecognised is a `:file` served as
  `application/octet-stream`, so an upload can never become HTML or script on this origin.
  """

  import Bitwise

  alias Mythweaver.Attachments.ImageInfo

  @type kind :: :image | :document | :audio | :video | :file
  @type info :: %{
          kind: kind(),
          content_type: String.t(),
          width: pos_integer() | nil,
          height: pos_integer() | nil
        }

  @octet "application/octet-stream"
  # `Mythweaver.Attachments`' head size: a head this long may end mid-character.
  @head_bytes 262_144

  @doc "The kind and content type of a file starting with `head`, named `filename`. Never fails."
  @spec parse(binary(), String.t() | nil) :: {:ok, info()}
  def parse(head, filename) do
    case ImageInfo.parse(head) do
      {:ok, image} -> {:ok, Map.put(image, :kind, :image)}
      {:error, _} -> head |> sniff(filename) |> info()
    end
  end

  defp info({kind, type}), do: {:ok, %{kind: kind, content_type: type, width: nil, height: nil}}

  defp sniff("%PDF-" <> _, _filename), do: {:document, "application/pdf"}
  defp sniff("ID3" <> _, _filename), do: {:audio, "audio/mpeg"}
  defp sniff(<<0xFF, b, _::binary>>, _filename) when (b &&& 0xE0) == 0xE0, do: {:audio, "audio/mpeg"}
  defp sniff(<<"RIFF", _::binary-4, "WAVE", _::binary>>, _filename), do: {:audio, "audio/wav"}
  defp sniff("OggS" <> _, _filename), do: {:audio, "audio/ogg"}
  defp sniff("fLaC" <> _, _filename), do: {:audio, "audio/flac"}
  defp sniff(<<_::binary-4, "ftyp", "M4A ", _::binary>>, _filename), do: {:audio, "audio/mp4"}
  defp sniff(<<_::binary-4, "ftyp", "qt  ", _::binary>>, _filename), do: {:video, "video/quicktime"}
  defp sniff(<<_::binary-4, "ftyp", _brand::binary-4, _::binary>>, _filename), do: {:video, "video/mp4"}
  defp sniff(<<0x1A, 0x45, 0xDF, 0xA3, _::binary>>, _filename), do: {:video, "video/webm"}

  defp sniff(head, filename) do
    case text_type(filename) do
      nil -> {:file, @octet}
      type -> if text?(head), do: {:document, type}, else: {:file, @octet}
    end
  end

  defp text_type(filename) when is_binary(filename) do
    filename
    |> Path.extname()
    |> String.downcase()
    |> case do
      ".txt" -> "text/plain"
      ext when ext in [".md", ".markdown"] -> "text/markdown"
      _ -> nil
    end
  end

  defp text_type(nil), do: nil

  defp text?(head) do
    not String.contains?(head, <<0>>) and
      (String.valid?(head) or (byte_size(head) == @head_bytes and valid_after_cut?(head)))
  end

  # A full head may cut a multi-byte character short: up to 3 trailing bytes.
  defp valid_after_cut?(head), do: Enum.any?(1..3, &String.valid?(binary_part(head, 0, byte_size(head) - &1)))

  @audio %{
    "audio/mpeg" => "audio/mpeg",
    "audio/mp3" => "audio/mpeg",
    "audio/wav" => "audio/wav",
    "audio/x-wav" => "audio/wav",
    "audio/wave" => "audio/wav",
    "audio/ogg" => "audio/ogg",
    "audio/flac" => "audio/flac",
    "audio/x-flac" => "audio/flac",
    "audio/mp4" => "audio/mp4",
    "audio/x-m4a" => "audio/mp4"
  }
  @video ~w(video/mp4 video/webm video/quicktime)
  @images ~w(image/png image/jpeg image/webp)

  @doc """
  The kind and content type a presigned upload is reserved as, from the browser's `client_type`
  and `filename`. Anything unrecognised is `{:file, "application/octet-stream"}`.
  """
  @spec claimed(String.t() | nil, String.t() | nil) :: {kind(), String.t()}
  def claimed(client_type, filename) do
    cond do
      client_type in @images -> {:image, client_type}
      client_type == "application/pdf" -> {:document, "application/pdf"}
      Map.has_key?(@audio, client_type) -> {:audio, @audio[client_type]}
      client_type in @video -> {:video, client_type}
      type = text_type(filename) -> {:document, type}
      client_type == "text/plain" -> {:document, "text/plain"}
      client_type in ["text/markdown", "text/x-markdown"] -> {:document, "text/markdown"}
      true -> {:file, @octet}
    end
  end
end
