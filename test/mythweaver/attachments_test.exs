defmodule Mythweaver.AttachmentsTest do
  use Mythweaver.DataCase

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI.Model
  alias Mythweaver.AI.Request
  alias Mythweaver.Attachments
  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Attachments.CharacterAttachment
  alias Mythweaver.Attachments.Proxy
  alias Mythweaver.Attachments.Storage.Local
  alias Mythweaver.Attachments.Storage.S3
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Messages

  defp png,
    do:
      Base.decode64!("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")

  defp unique, do: System.unique_integer([:positive])

  defp put_config(changes) do
    original = Application.get_env(:mythweaver, Attachments)
    Application.put_env(:mythweaver, Attachments, Keyword.merge(original, changes))
    on_exit(fn -> Application.put_env(:mythweaver, Attachments, original) end)
  end

  # The storage key an `/uploads` link seals.
  defp local_key("/uploads/" <> token) do
    {:ok, key, _expires_at} = Local.open(token)
    key
  end

  defp query(url), do: url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

  defp xi_config(overrides \\ []) do
    Keyword.merge(
      [
        base_url: "http://img",
        source_prefix: "xi://uploads/",
        key: "736563726574",
        salt: "68656C6C6F",
        encryption_key: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
      ],
      overrides
    )
  end

  defp tmp_file!(name, content) do
    path = Path.join(System.tmp_dir!(), "#{unique()}-#{name}")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp stored!(attrs \\ []) do
    {:ok, attachment} = Attachments.store_binary(png(), attrs)
    attachment
  end

  defp file_of(%Attachment{key: key}), do: Path.join(Local.root(), key)

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

  setup do
    %{scope: scope!()}
  end

  defp character!(scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: "#{name}-#{unique()}"})
    character
  end

  defp chat!(scope, [player | _] = characters) do
    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: "chat-#{unique()}",
        participants: Enum.map(characters, &%{character_id: &1.id}),
        player_character_id: player.id
      })

    Chats.get_chat!(chat.id)
  end

  describe "store_file/2" do
    test "stores a sniffed image locally and links it under /uploads", %{scope: scope} do
      path = tmp_file!("fox.png", png())

      assert {:ok, %Attachment{status: :ready, storage: :local, width: 1, height: 1} = a} =
               Attachments.store_file(scope, path, filename: "fox.png")

      assert String.ends_with?(a.key, ".png")
      assert File.read!(file_of(a)) == png()
      assert local_key(Attachments.url(a, :thumb)) == a.key
    end

    test "refuses a non-image whatever its name, writing nothing", %{scope: scope} do
      before = Repo.aggregate(Attachment, :count)
      assert Attachments.store_file(scope, tmp_file!("fox.png", "not an image at all")) == {:error, :unsupported_type}
      assert Repo.aggregate(Attachment, :count) == before
    end

    test "refuses a file over the size limit", %{scope: scope} do
      put_config(max_upload_bytes: 10)
      assert Attachments.store_file(scope, tmp_file!("fox.png", png())) == {:error, :too_large}
    end

    test "stores a PDF as a document with its text, when documents are accepted", %{scope: scope} do
      path = tmp_file!("fox.pdf", pdf_with_text("Hello fox"))

      assert {:ok, %Attachment{kind: :document, content_type: "application/pdf", page_count: 1} = a} =
               Attachments.store_file(scope, path, filename: "fox.pdf", kinds: Attachment.kinds())

      assert a.text_content =~ "Hello fox"
      assert String.ends_with?(a.key, ".pdf")
      assert Attachments.store_file(scope, path, filename: "fox.pdf") == {:error, :unsupported_type}
    end

    @tag :capture_log
    test "an unreadable PDF is still stored, with no text", %{scope: scope} do
      path = tmp_file!("bad.pdf", "%PDF-1.4 garbage")

      assert {:ok, %Attachment{kind: :document, text_content: nil, page_count: nil} = a} =
               Attachments.store_file(scope, path, filename: "bad.pdf", kinds: Attachment.kinds())

      assert Attachments.file_line(a) == "[Document: bad.pdf (no readable text)]"
    end

    test "stores unknown bytes as an octet-stream file linked directly, not through the proxy", %{scope: scope} do
      path = tmp_file!("blob.exe", <<0>> <> :crypto.strong_rand_bytes(64))

      assert {:ok, %Attachment{kind: :file, content_type: "application/octet-stream"} = a} =
               Attachments.store_file(scope, path, filename: "blob.exe", kinds: Attachment.kinds())

      put_config(proxy: :xtandard)
      assert local_key(Attachments.url(a, :thumb)) == a.key
    end

    test "an image's :original link is its stored bytes: through xi when configured, else the storage link" do
      a = stored!()
      put_config(proxy: :xtandard, xtandard: xi_config(base_url: "http://img"))

      assert Attachments.url(a, :original) =~ ~r"^http://img/[\w-]+/raw:1/exp:\d+/enc/"
      refute Attachments.url(a, :original) =~ a.key
      assert String.starts_with?(Attachments.url(a, :inline), "http://img/")

      put_config(proxy: :none)
      assert local_key(Attachments.url(a, :original)) == a.key
    end

    test "each kind needs its upload permission; generated images need none", %{scope: scope} do
      :ok = Mythweaver.Permissions.put_grant!(scope.user, "uploads.documents", :deny)
      scope = Scope.for_user(scope.user)
      kinds = Attachment.kinds()
      pdf_path = tmp_file!("fox.pdf", pdf_with_text("Hello fox"))

      assert Attachments.uploadable_kinds(scope) == [:image, :audio, :video, :file]
      assert Attachments.store_file(scope, pdf_path, filename: "fox.pdf", kinds: kinds) == {:error, :not_permitted}

      # A kind the call does not accept stays `:unsupported_type`, whatever the permissions.
      assert Attachments.store_file(scope, pdf_path, filename: "fox.pdf") == {:error, :unsupported_type}
      assert {:ok, %Attachment{kind: :image}} = Attachments.store_file(scope, tmp_file!("fox.png", png()), kinds: kinds)

      :ok = Mythweaver.Permissions.put_grant!(scope.user, "uploads.images", :deny)
      scope = Scope.for_user(scope.user)
      assert Attachments.store_file(scope, tmp_file!("fox.png", png())) == {:error, :not_permitted}
      assert {:ok, %Attachment{kind: :image}} = Attachments.store_binary(png())
    end
  end

  describe "scrub_data_urls/1" do
    test "omits input_audio bytes, keeping the format" do
      assert Attachments.scrub_data_urls(%{"input_audio" => %{"data" => "AAAA", "format" => "mp3"}}) ==
               %{"input_audio" => %{"data" => "[4 bytes omitted]", "format" => "mp3"}}
    end
  end

  describe "orphans" do
    test "sweep_orphans/0 deletes only old attachments nothing links", %{scope: scope} do
      old = stored!()

      Repo.update_all(from(a in Attachment, where: a.id == ^old.id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -2, :day)]
      )

      linked = stored!()

      Repo.update_all(from(a in Attachment, where: a.id == ^linked.id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -2, :day)]
      )

      :ok = Attachments.set_avatar(scope, character!(scope, "Linked"), linked)

      fresh = stored!()

      Attachments.sweep_orphans()

      refute Repo.get(Attachment, old.id)
      refute File.exists?(file_of(old))
      assert Repo.get(Attachment, linked.id)
      assert Repo.get(Attachment, fresh.id)
    end

    test "replacing an avatar deletes the old one", %{scope: scope} do
      character = character!(scope, "Avatar")
      first = stored!()
      second = stored!()

      :ok = Attachments.set_avatar(scope, character, first)
      :ok = Attachments.set_avatar(scope, character, second)

      assert [%CharacterAttachment{attachment_id: id}] =
               Repo.all(from l in CharacterAttachment, where: l.character_id == ^character.id)

      assert id == second.id
      refute Repo.get(Attachment, first.id)
      refute File.exists?(file_of(first))
      assert Characters.preload_avatar(scope, Repo.get!(Characters.Character, character.id)).avatar.id == second.id
    end

    test "deleting a message deletes its attachments", %{scope: scope} do
      [hero, foil] = [character!(scope, "Hero"), character!(scope, "Foil")]
      chat = chat!(scope, [hero, foil])
      fox = stored!()
      {:ok, message} = Messages.send_message(scope, chat, hero.id, "Look", attachments: [fox])

      {:ok, _} = Messages.delete_message(scope, message)

      refute Repo.get(Attachment, fox.id)
      refute File.exists?(file_of(fox))
    end

    test "merging messages keeps the absorbed message's attachments on the survivor", %{scope: scope} do
      [hero, foil] = [character!(scope, "Hero"), character!(scope, "Foil")]
      chat = chat!(scope, [hero, foil])
      fox = stored!()
      {:ok, first} = Messages.send_message(scope, chat, hero.id, "One")
      {:ok, second} = Messages.send_message(scope, chat, hero.id, "Two", attachments: [fox])

      {:ok, merged} = Messages.merge_messages(scope, chat, [first.id, second.id])

      assert merged.id == first.id
      assert [%Attachment{id: id}] = merged.attachments
      assert id == fox.id
    end
  end

  describe "unlinked uploads" do
    test "only the uploader may adopt or delete a staged image", %{scope: scope} do
      other = scope!(%{role: :user})
      {:ok, fox} = Attachments.store_file(scope, tmp_file!("fox.png", png()), filename: "fox.png")
      assert fox.uploaded_by_id == scope.user.id

      refute Attachments.get_unlinked_image(other, fox.id)
      :ok = Attachments.delete_unlinked(other, [fox.id])
      assert Repo.get(Attachment, fox.id)
      assert File.exists?(file_of(fox))

      assert %Attachment{id: id} = Attachments.get_unlinked_image(scope, fox.id)
      assert id == fox.id
      :ok = Attachments.delete_unlinked(scope, [fox.id])
      refute Repo.get(Attachment, fox.id)
    end

    test "an image with no uploader is adopted by nobody", %{scope: scope} do
      generated = stored!()
      assert generated.uploaded_by_id == nil
      refute Attachments.get_unlinked_image(scope, generated.id)
    end

    test "deleting a user clears the uploader of their uploads, adoptable by nobody", %{scope: scope} do
      user = scope!(%{role: :user})
      {:ok, fox} = Attachments.store_file(user, tmp_file!("fox.png", png()))

      {:ok, _} = Mythweaver.Accounts.delete_user(scope, user.user)

      assert Repo.get!(Attachment, fox.id).uploaded_by_id == nil
      refute Attachments.get_unlinked_image(scope, fox.id)
    end
  end

  describe "avatar ownership" do
    test "a user sets their own character's avatar but not a site or another user's", %{scope: admin} do
      user = scope!(%{role: :user})
      other = scope!(%{role: :user})
      {:ok, mine} = Characters.create_character(user, %{name: "Mine-#{unique()}"})
      {:ok, theirs} = Characters.create_character(other, %{name: "Theirs-#{unique()}"})
      site = character!(admin, "Site")

      assert :ok = Attachments.set_avatar(user, mine, stored!(), describe: false)
      assert :ok = Attachments.remove_avatar(user, mine)
      assert {:error, :unauthorized} = Attachments.set_avatar(user, site, stored!(), describe: false)
      assert {:error, :unauthorized} = Attachments.set_avatar(user, theirs, stored!(), describe: false)
      assert {:error, :unauthorized} = Attachments.set_avatar(admin, mine, stored!(), describe: false)
      assert {:error, :unauthorized} = Attachments.remove_avatar(user, site)
      assert :ok = Attachments.set_avatar(admin, site, stored!(), describe: false)
    end
  end

  describe "signed links" do
    test "a local link seals its key until it expires, and is stable within a window" do
      a = stored!()
      url = Attachments.url(a, :thumb)
      "/uploads/" <> token = url
      now = System.os_time(:second)

      assert url == Attachments.url(a, :full)
      refute url =~ a.key
      assert {:ok, key, exp} = Local.open(token)
      assert key == a.key
      assert (exp - now) in 86_400..172_800
      refute Attachments.url(stored!(), :thumb) == url

      # One flipped byte anywhere fails the tag.
      raw = Base.url_decode64!(token, padding: false)

      for i <- [0, 12, 28, byte_size(raw) - 1] do
        <<head::binary-size(^i), byte, rest::binary>> = raw
        assert Local.open(Base.url_encode64(head <> <<Bitwise.bxor(byte, 1)>> <> rest, padding: false)) == :error
      end

      assert Local.open("not a token") == :error
      "/uploads/" <> expired = Local.signed_url(a.key, now - 20, now - 1)
      assert Local.open(expired) == :error
    end

    test "validate_config!/0 refuses an unsigned or unencrypted xi and an S3 window past 7 days of validity" do
      put_config(proxy: :xtandard, xtandard: [base_url: "http://img", source_prefix: "xi://uploads/"])
      assert_raise ArgumentError, ~r/MYTHWEAVER_XI_KEY/, &Attachments.validate_config!/0

      put_config(proxy: :xtandard, xtandard: xi_config(encryption_key: "abcd"))
      assert_raise ArgumentError, ~r/MYTHWEAVER_XI_ENCRYPTION_KEY/, &Attachments.validate_config!/0

      put_config(proxy: :xtandard, xtandard: xi_config())
      assert Attachments.validate_config!() == :ok

      put_config(proxy: :cloudflare, cloudflare: [zone_url: "https://zone"], uploads_origin_secret: nil)
      assert_raise ArgumentError, ~r/MYTHWEAVER_UPLOADS_ORIGIN_SECRET/, &Attachments.validate_config!/0

      put_config(uploads_origin_secret: "s3cret")
      assert Attachments.validate_config!() == :ok

      put_config(
        proxy: :none,
        storage: :s3,
        link_window_seconds: 302_401,
        s3: [bucket: "b", access_key_id: "k", secret_access_key: "s"]
      )

      assert_raise ArgumentError, ~r/302400/, &Attachments.validate_config!/0
    end

    test "an image's srcset lists its preset's widths through the proxy; none without one" do
      a = stored!()
      put_config(proxy: :xtandard, xtandard: xi_config())
      candidates = a |> Attachments.srcset(:portrait) |> String.split(", ") |> Enum.map(&String.split(&1, " "))

      assert Enum.map(candidates, &List.last/1) == ~w(192w 300w 420w 600w 900w 1200w)

      assert for([url, _] <- candidates, do: Regex.run(~r"rs:fill-down:(\d+):(\d+)", url, capture: :all_but_first)) ==
               [~w(192 256), ~w(300 400), ~w(420 560), ~w(600 800), ~w(900 1200), ~w(1200 1600)]

      assert hd(hd(candidates)) == Attachments.url(a, :portrait)
      assert Attachments.srcset(a, :avatar) =~ ~r/^\S+ 96w, \S+ 160w$/

      put_config(proxy: :none)
      assert Attachments.srcset(a, :portrait) == nil
      assert Attachments.srcset(nil, :portrait) == nil
    end
  end

  describe "browser_origins/0" do
    test "local storage with no proxy is same-origin; an absolute proxy link adds its origin" do
      assert Attachments.browser_origins() == []

      put_config(proxy: :xtandard, xtandard: xi_config(base_url: "http://Browser:4081/img"))
      assert Attachments.browser_origins() == ["http://browser:4081"]
    end
  end

  describe "model_image/1" do
    setup do
      put_config(
        proxy: :xtandard,
        xtandard: xi_config(base_url: "http://browser:4081", internal_url: "http://xi-cache")
      )
    end

    test "is the proxy's :model rendition, fetched at the internal address" do
      a = stored!()
      test = self()

      Req.Test.stub(Proxy, fn conn ->
        send(test, {:fetched, conn.host, conn.request_path})
        conn |> Plug.Conn.put_resp_content_type("image/webp", nil) |> Plug.Conn.send_resp(200, "scaled")
      end)

      assert {:ok, %{media_type: "image/webp", data: "scaled"}} = Attachments.model_image(a)
      assert_received {:fetched, "xi-cache", path}
      assert path =~ "/rs:fit:2048:2048:0/"
    end

    @tag :capture_log
    test "falls back to the original when the proxy fails or answers with an unsendable type" do
      a = stored!()

      Req.Test.stub(Proxy, &Plug.Conn.send_resp(&1, 502, "down"))
      assert {:ok, %{media_type: "image/png", data: data}} = Attachments.model_image(a)
      assert data == png()

      Req.Test.stub(Proxy, fn conn ->
        conn |> Plug.Conn.put_resp_content_type("image/gif", nil) |> Plug.Conn.send_resp(200, "gif")
      end)

      assert {:ok, %{media_type: "image/png"}} = Attachments.model_image(a)
    end

    test "with no proxy is the original, and a stored GIF is never sent" do
      put_config(proxy: :none)
      a = stored!()
      assert {:ok, %{media_type: "image/png", data: data}} = Attachments.model_image(a)
      assert data == png()

      assert Attachments.model_image(%{a | content_type: "image/gif"}) == {:error, :unsupported_type}
    end
  end

  describe "png/1" do
    setup do
      put_config(proxy: :xtandard, xtandard: xi_config(base_url: "/img", internal_url: "http://xi-cache"))
    end

    test "a PNG is its own bytes, with no proxy request" do
      a = stored!()
      Req.Test.stub(Proxy, fn _conn -> flunk("the proxy was asked for a PNG") end)
      assert Attachments.png(a) == {:ok, png()}
    end

    test "another image is the proxy's unresized PNG, fetched at the internal address" do
      a = %{stored!() | content_type: "image/jpeg"}
      test = self()

      Req.Test.stub(Proxy, fn conn ->
        send(test, {:fetched, conn.host, conn.request_path})
        conn |> Plug.Conn.put_resp_content_type("image/png", nil) |> Plug.Conn.send_resp(200, png())
      end)

      assert Attachments.png?(a)
      assert Attachments.png(a) == {:ok, png()}
      assert_received {:fetched, "xi-cache", path}
      assert path =~ ~r"^/[\w-]+/f:png/exp:\d+/enc/"
    end

    @tag :capture_log
    test "fails when the proxy fails or answers with something that isn't a PNG" do
      a = %{stored!() | content_type: "image/jpeg"}

      Req.Test.stub(Proxy, &Plug.Conn.send_resp(&1, 502, "down"))
      assert Attachments.png(a) == {:error, {:http_error, 502}}

      Req.Test.stub(Proxy, fn conn ->
        conn |> Plug.Conn.put_resp_content_type("image/png", nil) |> Plug.Conn.send_resp(200, "not a png")
      end)

      assert {:error, _} = Attachments.png(a)
    end

    test "is unsupported without a proxy that writes PNG, and for a file that isn't an image" do
      a = %{stored!() | content_type: "image/jpeg"}

      for proxy <- [:none, :cloudflare] do
        put_config(proxy: proxy, cloudflare: [zone_url: "https://zone"])
        refute Attachments.png?(a)
        assert Attachments.png(a) == {:error, :unsupported}
      end

      put_config(proxy: :xtandard)
      refute Attachments.png?(%{a | kind: :document, content_type: "application/pdf"})
    end
  end

  describe "still_url/2" do
    defp attachment(kind, type, status \\ :ready),
      do: %Attachment{status: status, kind: kind, content_type: type, storage: :local, key: "attachments/x.bin"}

    test "is a proxied still of a video or a PDF, when the proxy renders stills" do
      put_config(proxy: :xtandard, xtandard: xi_config())

      for a <- [attachment(:video, "video/mp4"), attachment(:document, "application/pdf")] do
        url = Attachments.still_url(a, :thumb)
        assert String.starts_with?(url, "http://img/")
        assert url =~ "/rs:fit:320:320:0/"
      end

      assert Attachments.still_url(attachment(:document, "text/markdown"), :thumb) == nil
      assert Attachments.still_url(attachment(:image, "image/png"), :thumb) == nil
      assert Attachments.still_url(attachment(:video, "video/mp4", :pending), :thumb) == nil
    end

    test "is nil with a proxy that renders no stills" do
      put_config(proxy: :none)
      assert Attachments.still_url(attachment(:video, "video/mp4"), :thumb) == nil
    end
  end

  describe "refresh_blurhash/1" do
    setup do
      put_config(proxy: :xtandard, xtandard: xi_config(internal_url: "http://xi-cache"))
    end

    test "stores the hash xi's /info reports, asked at the internal address" do
      a = stored!()
      test = self()

      Req.Test.stub(Proxy, fn conn ->
        send(test, {:fetched, conn.host, conn.request_path})
        Req.Test.json(conn, %{"blurhash" => "LEHV6nWB2yk8pyo0adR*.7kCMdnj"})
      end)

      assert {:ok, %Attachment{blurhash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj"}} = Attachments.refresh_blurhash(a)
      assert_received {:fetched, "xi-cache", "/info/" <> _ = path}
      assert path =~ "/bh:4:3/"
      assert Repo.get!(Attachment, a.id).blurhash == "LEHV6nWB2yk8pyo0adR*.7kCMdnj"
    end

    @tag :capture_log
    test "a failed request leaves the hash unset" do
      a = stored!()
      Req.Test.stub(Proxy, &Plug.Conn.send_resp(&1, 502, "down"))

      assert {:error, _} = Attachments.refresh_blurhash(a)
      assert Repo.get!(Attachment, a.id).blurhash == nil
    end

    test "skips proxies without /info, and anything but an image" do
      assert Attachments.refresh_blurhash(%{stored!() | kind: :document}) == :skipped

      put_config(proxy: :none)
      assert Attachments.refresh_blurhash(stored!()) == :skipped
    end
  end

  test "image_tokens/1 follows OpenAI's tile rule" do
    tokens = &Attachments.image_tokens(%Attachment{width: &1, height: &2})

    assert tokens.(512, 300) == 85
    # Short side 768: 768×768, 2×2 tiles.
    assert tokens.(1000, 1000) == 765
    # Fit into 2048 (2048×1024), then short side 768 (1536×768): 3×2 tiles.
    assert tokens.(4000, 2000) == 1105
    assert Attachments.image_tokens(%Attachment{}) == 765
    # Low detail: always the flat 85, whatever the size.
    assert Attachments.image_tokens(%Attachment{width: 4000, height: 2000}, :low) == 85
  end

  test "image_part/2 carries the model's image_detail, and none when unset" do
    a = stored!()
    assert {:ok, %Request.Image{detail: :low}} = Attachments.image_part(a, %Model{image_detail: :low})
    assert {:ok, part} = Attachments.image_part(a, %Model{})
    assert part.detail == nil
  end

  describe "presigned S3 uploads" do
    @endpoint "http://s3.test"
    @bucket "mw"

    setup do
      put_config(
        storage: :s3,
        s3: [
          bucket: @bucket,
          region: "us-east-1",
          endpoint_url: @endpoint,
          access_key_id: "minio",
          secret_access_key: "minio123"
        ]
      )
    end

    defp stub_object(bytes) do
      test_pid = self()

      Req.Test.stub(S3, fn conn ->
        send(test_pid, {:s3, conn.method, conn.request_path})

        case conn.method do
          "HEAD" ->
            conn |> Plug.Conn.put_resp_header("content-length", "#{byte_size(bytes)}") |> Plug.Conn.send_resp(200, "")

          "GET" ->
            Plug.Conn.send_resp(conn, 206, bytes)

          "DELETE" ->
            Plug.Conn.send_resp(conn, 204, "")
        end
      end)
    end

    test "prepare reserves a pending row and a POST form; finalize checks the object", %{scope: scope} do
      assert {:ok, %{attachment_id: id, url: url, fields: fields}} =
               Attachments.prepare_presigned_upload(scope, "image/png", byte_size(png()))

      assert url == "#{@endpoint}/#{@bucket}"
      assert Map.has_key?(fields, "policy")
      assert %Attachment{status: :pending, key: key} = Repo.get!(Attachment, id)
      assert fields["key"] == key

      stub_object(png())

      assert {:ok, %Attachment{status: :ready, width: 1, filename: "fox.png"} = a} =
               Attachments.finalize_presigned_upload(scope, id, "fox.png")

      url = Attachments.url(a, :thumb)
      window_start = div(System.os_time(:second), 86_400) * 86_400
      date = window_start |> DateTime.from_unix!() |> Calendar.strftime("%Y%m%dT%H%M%SZ")

      assert String.starts_with?(url, "#{@endpoint}/#{@bucket}/#{key}?")
      assert %{"X-Amz-Expires" => "172800", "X-Amz-Date" => ^date, "X-Amz-Signature" => _} = query(url)
    end

    test "finalize deletes an object that is not the claimed type", %{scope: scope} do
      {:ok, %{attachment_id: id}} = Attachments.prepare_presigned_upload(scope, "image/png", byte_size(png()))
      stub_object("GIF89a" <> <<1::little-16, 1::little-16>> <> <<0::56>>)

      assert Attachments.finalize_presigned_upload(scope, id, "fox.png") == {:error, :unsupported_type}
      assert_received {:s3, "DELETE", _}
      refute Repo.get(Attachment, id)
    end

    test "prepare refuses types that are not accepted images", %{scope: scope} do
      assert Attachments.prepare_presigned_upload(scope, "image/svg+xml", 10) == {:error, :unsupported_type}
    end

    test "a denied kind is refused at prepare, and smuggled in as a :file is refused at finalize",
         %{scope: scope} do
      :ok = Mythweaver.Permissions.put_grant!(scope.user, "uploads.documents", :deny)
      scope = Scope.for_user(scope.user)
      kinds = Attachment.kinds()
      pdf = pdf_with_text("Hello fox")

      assert Attachments.prepare_presigned_upload(scope, "application/pdf", 10, filename: "fox.pdf", kinds: kinds) ==
               {:error, :not_permitted}

      {:ok, %{attachment_id: id}} =
        Attachments.prepare_presigned_upload(scope, "application/octet-stream", byte_size(pdf),
          filename: "fox.bin",
          kinds: kinds
        )

      stub_object(pdf)
      assert Attachments.finalize_presigned_upload(scope, id, "fox.bin") == {:error, :not_permitted}
      refute Repo.get(Attachment, id)
    end
  end

  describe "restore_description/2" do
    test "saves a non-blank description as done and leaves blank ones alone" do
      attachment = stored!()

      assert {:ok, %Attachment{description: "A fox", caption_status: :done}} =
               Attachments.restore_description(attachment, "A fox")

      assert %Attachment{description: "A fox", caption_status: :done} = Repo.get!(Attachment, attachment.id)

      other = stored!()
      assert {:ok, ^other} = Attachments.restore_description(other, "  ")
      assert %Attachment{caption_status: :none, description: nil} = Repo.get!(Attachment, other.id)
    end
  end
end
