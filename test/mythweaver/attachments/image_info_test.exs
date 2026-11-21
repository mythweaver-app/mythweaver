defmodule Mythweaver.Attachments.ImageInfoTest do
  use ExUnit.Case, async: true

  alias Mythweaver.Attachments.ImageInfo

  defp png,
    do:
      Base.decode64!("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")

  test "PNG" do
    assert ImageInfo.parse(png()) == {:ok, %{content_type: "image/png", width: 1, height: 1}}
  end

  test "GIF is refused" do
    assert ImageInfo.parse("GIF89a" <> <<3::little-16, 5::little-16>> <> <<0::56>>) == {:error, :unsupported_type}
  end

  test "JPEG walks segments to the start-of-frame" do
    jpeg = <<0xFF, 0xD8, 0xFF, 0xE0, 16::16, 0::112, 0xFF, 0xC0, 17::16, 8, 7::16, 9::16, 0::72>>
    assert ImageInfo.parse(jpeg) == {:ok, %{content_type: "image/jpeg", width: 9, height: 7}}
  end

  test "a JPEG cut off before its start-of-frame is still a JPEG, without dimensions" do
    assert ImageInfo.parse(<<0xFF, 0xD8, 0xFF, 0xE0, 200::16, 0::80>>) ==
             {:ok, %{content_type: "image/jpeg", width: nil, height: nil}}
  end

  test "extended WebP" do
    webp = "RIFF" <> <<0::32>> <> "WEBP" <> "VP8X" <> <<10::little-32, 0, 0::24, 99::little-24, 49::little-24>>
    assert ImageInfo.parse(webp) == {:ok, %{content_type: "image/webp", width: 100, height: 50}}
  end

  test "SVG and other text are refused" do
    assert ImageInfo.parse(~s(<svg xmlns="http://www.w3.org/2000/svg"></svg>)) == {:error, :unsupported_type}
    assert ImageInfo.parse("hello") == {:error, :unsupported_type}
  end
end
