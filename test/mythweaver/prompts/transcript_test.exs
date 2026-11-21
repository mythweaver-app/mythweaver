defmodule Mythweaver.Prompts.TranscriptTest do
  use Mythweaver.DataCase

  alias Mythweaver.Attachments
  alias Mythweaver.Attachments.Captions
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Messages
  alias Mythweaver.Prompts.Builder
  alias Mythweaver.Prompts.Transcript
  alias Mythweaver.Settings

  defp png,
    do:
      Base.decode64!("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")

  defp unique, do: System.unique_integer([:positive])

  setup do
    scope = scope!()

    [player, bot] =
      for n <- ["Ann", "Bot"], do: elem(Characters.create_character(scope, %{name: "#{n}#{unique()}"}), 1)

    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: "c#{unique()}",
        participants: [%{character_id: player.id}, %{character_id: bot.id}],
        player_character_id: player.id
      })

    chat = Chats.get_chat!(chat.id)
    {:ok, image} = Attachments.store_binary(png())
    image = Captions.put_manual_description(scope, chat.id, image, "a red fox")
    {:ok, _} = Messages.send_message(scope, chat, player.id, "Look", attachments: [image])

    %{scope: scope, chat: chat, player: player, bot: bot}
  end

  defp image_line(ctx, opts) do
    [entry] = Transcript.entries(Messages.list_messages(ctx.chat), ctx.bot, opts)
    entry.content |> String.split("\n") |> List.last()
  end

  test "the caption template renders each image line with caption, user and char", ctx do
    assert image_line(ctx, caption_template: "{{ user }} shows {{ char }}: {{ caption }}") ==
             "#{ctx.player.name} shows #{ctx.bot.name}: a red fox"

    assert image_line(ctx, caption_template: nil) == "[Image: a red fox]"
    assert image_line(ctx, []) == "[Image: a red fox]"
  end

  test "a template that fails to render falls back to the built-in line", ctx do
    assert image_line(ctx, caption_template: "{% if %}{{ caption }}") == "[Image: a red fox]"
  end

  test "chat turns and text lines use the template too", ctx do
    messages = Messages.list_messages(ctx.chat)
    template = "<{{ caption }}>"

    assert [%{content: content}] = Transcript.turns(messages, ctx.bot, caption_template: template)
    assert content =~ "<a red fox>"
    assert [line] = Transcript.lines(messages, caption_template: template)
    assert line =~ "<a red fox>"
  end

  test "the builder context reads the scope's setting", ctx do
    assert Builder.context(ctx.scope, ctx.chat).caption_template == nil
    :ok = Settings.put(ctx.scope, :user, "images.caption_template", "[Pic: {{ caption }}]")
    assert Builder.context(ctx.scope, ctx.chat).caption_template == "[Pic: {{ caption }}]"
  end

  describe "non-image attachments" do
    setup ctx do
      kinds = Attachments.Attachment.kinds()
      {:ok, pdf} = Attachments.store_binary(pdf_with_text("Hello fox"), filename: "fox.pdf", kinds: kinds)
      {:ok, mp3} = Attachments.store_binary("ID3" <> <<4, 0, 0, 0, 0, 0>>, filename: "howl.mp3", kinds: kinds)
      {:ok, mp4} = Attachments.store_binary(<<0, 0, 0, 24, "ftypisom", 0::32>>, filename: "run.mp4", kinds: kinds)

      {:ok, _} =
        Messages.send_message(ctx.scope, ctx.chat, ctx.player.id, "Read this", attachments: [pdf, mp3, mp4])

      %{pdf: pdf, mp3: mp3, mp4: mp4, messages: Messages.list_messages(ctx.chat)}
    end

    test "a document's extracted text and an audio line follow the message text", ctx do
      [_image, %{content: content, files: [_, _, _]}] = Transcript.entries(ctx.messages, ctx.bot)

      assert content ==
               "Read this\n[Document: fox.pdf]\nHello fox\n[/Document]\n[Audio: howl.mp3]\n[Video: run.mp4]"
    end

    test "attach_files, attach_audio and attach_video each send their kind instead of its line", ctx do
      pdf_id = ctx.pdf.id
      mp3_id = ctx.mp3.id
      mp4_id = ctx.mp4.id

      assert [_, %{files: [%{id: ^pdf_id}], content: content}] =
               Transcript.turns(ctx.messages, ctx.bot, attach_files: true)

      refute content =~ "[Document:"
      assert content =~ "[Audio: howl.mp3]\n[Video: run.mp4]"

      assert [_, %{files: [%{id: ^mp4_id}], content: content}] =
               Transcript.turns(ctx.messages, ctx.bot, attach_video: true)

      assert content =~ "[Audio: howl.mp3]"
      refute content =~ "[Video:"

      assert [_, %{files: [%{id: ^pdf_id}, %{id: ^mp3_id}, %{id: ^mp4_id}], content: content}] =
               Transcript.turns(ctx.messages, ctx.bot, attach_files: true, attach_audio: true, attach_video: true)

      assert content =~ ~r/Read this$/
    end
  end

  # A one-page PDF with real xref offsets, so it opens without recovery.
  defp pdf_with_text(text) do
    stream = "BT /F1 12 Tf 72 720 Td (#{text}) Tj ET"

    objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
      "<< /Length #{byte_size(stream)} >>\nstream\n#{stream}\nendstream",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"
    ]

    {body, offsets} =
      objects
      |> Enum.with_index(1)
      |> Enum.reduce({"%PDF-1.4\n", []}, fn {object, i}, {acc, offsets} ->
        {acc <> "#{i} 0 obj\n#{object}\nendobj\n", [byte_size(acc) | offsets]}
      end)

    xref =
      "xref\n0 #{length(objects) + 1}\n0000000000 65535 f \n" <>
        Enum.map_join(Enum.reverse(offsets), "", &(String.pad_leading("#{&1}", 10, "0") <> " 00000 n \n"))

    body <> xref <> "trailer\n<< /Size #{length(objects) + 1} /Root 1 0 R >>\nstartxref\n#{byte_size(body)}\n%%EOF\n"
  end
end
