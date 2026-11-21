defmodule Mythweaver.Attachments.FileInfoTest do
  use ExUnit.Case, async: true

  alias Mythweaver.Attachments.FileInfo

  @png <<0x89, "PNG\r\n", 0x1A, "\n", 13::32, "IHDR", 4::32, 3::32, 0::40>>

  defp parsed(head, filename \\ nil) do
    {:ok, %{kind: kind, content_type: type}} = FileInfo.parse(head, filename)
    {kind, type}
  end

  describe "parse/2" do
    test "recognises each kind by its magic bytes" do
      assert {:ok, %{kind: :image, content_type: "image/png", width: 4, height: 3}} = FileInfo.parse(@png, "x.bin")
      assert parsed("%PDF-1.4\n%…") == {:document, "application/pdf"}
      assert parsed("ID3" <> <<4, 0, 0>>) == {:audio, "audio/mpeg"}
      assert parsed(<<0xFF, 0xFB, 0x90, 0x00>>) == {:audio, "audio/mpeg"}
      assert parsed(<<"RIFF", 0::32, "WAVEfmt ">>) == {:audio, "audio/wav"}
      assert parsed("OggS" <> <<0>>) == {:audio, "audio/ogg"}
      assert parsed("fLaC" <> <<0>>) == {:audio, "audio/flac"}
      assert parsed(<<0, 0, 0, 24, "ftypisom", 0::32>>) == {:video, "video/mp4"}
      assert parsed(<<0, 0, 0, 24, "ftypM4A ", 0::32>>) == {:audio, "audio/mp4"}
      assert parsed(<<0, 0, 0, 24, "ftypqt  ", 0::32>>) == {:video, "video/quicktime"}
      assert parsed(<<0x1A, 0x45, 0xDF, 0xA3, 0x9F>>) == {:video, "video/webm"}
    end

    test "text is a document only with a text extension and valid UTF-8" do
      assert parsed("hello", "notes.md") == {:document, "text/markdown"}
      assert parsed("hello", "NOTES.TXT") == {:document, "text/plain"}
      assert parsed("hello", nil) == {:file, "application/octet-stream"}
      assert parsed("<html>", "page.html") == {:file, "application/octet-stream"}
      assert parsed(<<0, 1, 2>>, "x.txt") == {:file, "application/octet-stream"}
      assert parsed(<<0xC3, 0x28>>, "x.txt") == {:file, "application/octet-stream"}
    end

    test "a full head cut inside a multi-byte character is still text" do
      head = String.duplicate("a", 262_143) <> <<0xC3>>
      assert parsed(head, "long.txt") == {:document, "text/plain"}
      refute String.valid?(head)
    end
  end

  describe "claimed/2" do
    test "maps browser claims, aliases included, and refuses the rest as a file" do
      assert FileInfo.claimed("image/webp", "a.webp") == {:image, "image/webp"}
      assert FileInfo.claimed("application/pdf", "a.pdf") == {:document, "application/pdf"}
      assert FileInfo.claimed("audio/x-wav", "a.wav") == {:audio, "audio/wav"}
      assert FileInfo.claimed("audio/mp3", "a.mp3") == {:audio, "audio/mpeg"}
      assert FileInfo.claimed("video/webm", "a.webm") == {:video, "video/webm"}
      assert FileInfo.claimed("application/octet-stream", "notes.md") == {:document, "text/markdown"}
      assert FileInfo.claimed("text/x-markdown", nil) == {:document, "text/markdown"}
      assert FileInfo.claimed("text/html", "x.html") == {:file, "application/octet-stream"}
      assert FileInfo.claimed("image/svg+xml", "x.svg") == {:file, "application/octet-stream"}
    end
  end
end
