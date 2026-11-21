defmodule MythweaverWeb.MainChatLiveTest do
  use MythweaverWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.Assistant.Prompt
  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Member
  alias Mythweaver.Injections
  alias Mythweaver.Jobs
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Jobs.Scheduler
  alias Mythweaver.Lore
  alias Mythweaver.Lore.Embeddings
  alias Mythweaver.Memory
  alias Mythweaver.Memory.CharacterBooks
  alias Mythweaver.Memory.Scene
  alias Mythweaver.Memory.TopicSuggestion
  alias Mythweaver.Messages
  alias Mythweaver.Messages.DraftBuffer
  alias Mythweaver.Messages.Message
  alias Mythweaver.Messages.MessageBody
  alias Mythweaver.Moderation.Report
  alias Mythweaver.Notifications.Notification
  alias Mythweaver.Prompts
  alias Mythweaver.Repo
  alias Mythweaver.Scripts
  alias Mythweaver.Scripts.CallbackStore
  alias Mythweaver.Settings
  alias Mythweaver.Settings.Setting
  alias Mythweaver.Variables
  alias MythweaverWeb.CommandPalette.Commands
  alias MythweaverWeb.MainChatLive.MessageWindow

  setup :register_and_log_in_user

  defp character(scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: name})
    character
  end

  defp create_chat(user, name, c1, c2, player_id) do
    {:ok, chat} =
      Chats.create_chat(Scope.for_user(user), %{
        name: name,
        participants: [%{character_id: c1.id}, %{character_id: c2.id}],
        player_character_id: player_id
      })

    chat
  end

  defp add_message(chat, character, content) do
    {:ok, message} =
      Messages.create_message(chat, %{
        author_is_character: true,
        author_character_id: character.id,
        bodies: [%{content: content}]
      })

    message
  end

  setup %{user: user, scope: scope} do
    c1 = character(scope, "Alice")
    c2 = character(scope, "Bob")

    chat = create_chat(user, "Alpha Chat", c1, c2, c1.id)
    add_message(chat, c1, "Hello there")

    empty_chat = create_chat(user, "Empty Chat", c1, c2, c1.id)

    second_chat = create_chat(user, "Zeta Chat", c1, c2, c1.id)
    add_message(second_chat, c2, "Greetings traveler")

    %{c1: c1, c2: c2, chat: chat, empty_chat: empty_chat, second_chat: second_chat}
  end

  test "picker lists chats by name", %{conn: conn, chat: chat, second_chat: second_chat} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, ".chat-picker-link", chat.name)
    assert has_element?(view, ".chat-picker-link", second_chat.name)
  end

  test "bulk deletes the chats selected, leaving the open one's page", %{
    conn: conn,
    scope: scope,
    chat: chat,
    empty_chat: empty_chat,
    second_chat: second_chat
  } do
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    view |> element("#chats-bulk-toggle") |> render_click()
    view |> element("#bulk-chats-#{chat.id}") |> render_click()
    view |> element("#bulk-chats-#{second_chat.id}") |> render_click()
    view |> element("#chats-bulk-delete") |> render_click()

    assert_patch(view, ~p"/")
    assert Enum.map(Chats.list_chats(scope), & &1.id) == [empty_chat.id]
  end

  test "root auto-selects the first chat when none was opened, and renders its messages", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#messages")
    assert render(view) =~ "Hello there"
    assert render(view) =~ "Alice"
  end

  test "root reopens the chat last opened, even after leaving the page",
       %{conn: conn, chat: chat, second_chat: second_chat} do
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    render_patch(view, ~p"/chats/#{second_chat.id}")

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, ".chat-picker-link--active", second_chat.name)
    assert render(view) =~ "Greetings traveler"
  end

  test "a message's time carries the UTC instant for the client hook to localize",
       %{conn: conn, chat: chat} do
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    render_submit(element(view, "#message-composer"), %{composer: %{content: "What time is it?"}})
    message = chat |> Messages.list_messages() |> List.last()
    iso = DateTime.to_iso8601(message.inserted_at)

    assert has_element?(view, "#message-time-#{message.id}[phx-hook][datetime='#{iso}']")
  end

  test "empty chat shows the no-messages state", %{conn: conn, empty_chat: empty_chat} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element(".chat-picker-link", empty_chat.name) |> render_click()

    assert has_element?(view, ".chat-messages-empty", "No messages yet")
  end

  test "participants rail lists both characters and badges the player character",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, ".chat-participant-name", "Alice")
    assert has_element?(view, ".chat-participant-name", "Bob")
    assert has_element?(view, ".chat-participant .badge", "You")
  end

  test "a character renamed elsewhere repaints the participants rail",
       %{conn: conn, scope: scope, chat: chat, c2: c2} do
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    bob = Enum.find(Chats.get_chat(chat.id).participants, &(&1.character_id == c2.id))

    {:ok, _} = Characters.update_character(scope, c2, %{name: "Renamed"})

    assert has_element?(view, "#participant-#{bob.id} .chat-participant-name", "Renamed")
  end

  test "the play-as button moves the player to that row and brands only later messages",
       %{conn: conn, chat: chat, c1: c1, c2: c2} do
    alice_message = List.first(Messages.list_messages(chat))
    bob_message = add_message(chat, c2, "Bob speaks")

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    bob = Enum.find(Chats.get_chat(chat.id).participants, &(&1.character_id == c2.id))
    alice = Enum.find(Chats.get_chat(chat.id).participants, &(&1.character_id == c1.id))

    assert has_element?(view, "#participant-#{alice.id} .badge", "You")
    assert has_element?(view, "#messages-#{alice_message.id} .badge", "You")
    refute has_element?(view, "#messages-#{bob_message.id} .badge", "You")

    view |> element("#play-as-#{bob.id}") |> render_click()

    assert Chats.get_chat(chat.id).player_character_id == c2.id
    assert has_element?(view, "#participant-#{bob.id} .badge", "You")
    assert has_element?(view, "#play-as-#{bob.id}[disabled]")
    refute has_element?(view, "#participant-#{alice.id} .badge", "You")

    # History keeps who the user played as at the time; only messages sent from now on follow Bob.
    assert has_element?(view, "#messages-#{alice_message.id} .badge", "You")
    refute has_element?(view, "#messages-#{bob_message.id} .badge", "You")

    render_submit(element(view, "#message-composer"), %{composer: %{content: "Now as Bob"}})
    new_message = chat |> Messages.list_messages() |> List.last()
    assert has_element?(view, "#messages-#{new_message.id} .badge", "You")
  end

  test "playing as a muted participant unmutes it", %{conn: conn, scope: scope, chat: chat, c2: c2} do
    bob = Enum.find(Chats.get_chat(chat.id).participants, &(&1.character_id == c2.id))
    {:ok, _} = Chats.update_participant(scope, bob, %{muted: true})

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    assert has_element?(view, "#participant-#{bob.id}.chat-participant--muted")

    view |> element("#play-as-#{bob.id}") |> render_click()

    refute Enum.find(Chats.get_chat(chat.id).participants, &(&1.id == bob.id)).muted
    refute has_element?(view, "#participant-#{bob.id}.chat-participant--muted")
  end

  test "the add-character header button adds the selected characters to the chat",
       %{scope: scope, conn: conn, chat: chat} do
    c3 = character(scope, "Carol")

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    refute has_element?(view, "#add-participant-form")
    assert has_element?(view, ~s(.chat-participants header #add-participant[aria-label="Add characters"]))

    view |> element("#add-participant") |> render_click()

    assert has_element?(view, "#add-participant-modal #add-participant-form")

    view
    |> form("#add-participant-form", %{"character_ids" => [c3.id]})
    |> render_submit()

    refute has_element?(view, "#add-participant-form")

    added = Enum.find(Chats.get_chat(chat.id).participants, &(&1.character_id == c3.id))
    assert added
    assert has_element?(view, "#participant-#{added.id} .chat-participant-name", "Carol")
  end

  test "the remove button drops the character and clears the player attribution when it was theirs",
       %{scope: scope, conn: conn, chat: chat, c1: c1, c2: c2} do
    c3 = character(scope, "Carol")
    {:ok, _} = Chats.add_participants(scope, chat, [c3.id])

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    alice = Enum.find(Chats.get_chat(chat.id).participants, &(&1.character_id == c1.id))
    assert has_element?(view, "#participant-#{alice.id} .badge", "You")
    assert has_element?(view, "#message-composer")

    view |> element("#remove-participant-#{alice.id}") |> render_click()

    reloaded = Chats.get_chat(chat.id)

    assert Enum.sort(Enum.map(reloaded.participants, & &1.character_id)) ==
             Enum.sort([c2.id, c3.id])

    refute has_element?(view, "#participant-#{alice.id}")

    # `remove_participant/1` clears `player_character_id` when the removed character was the player,
    # so the composer has no author to send as and no participant carries the `You` badge. Alice's
    # past message keeps its badge: she was the player when it was sent.
    assert reloaded.player_character_id == nil
    refute has_element?(view, "#message-composer")
    refute has_element?(view, ".chat-participant .badge", "You")
    [alice_message] = Messages.list_messages(chat)
    assert has_element?(view, "#messages-#{alice_message.id} .badge", "You")
  end

  test "removing is refused when the chat would drop below two participants",
       %{conn: conn, chat: chat, c2: c2} do
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    bob = Enum.find(Chats.get_chat(chat.id).participants, &(&1.character_id == c2.id))

    view |> element("#remove-participant-#{bob.id}") |> render_click()

    assert length(Chats.get_chat(chat.id).participants) == 2
    assert has_element?(view, "#participant-#{bob.id}")
    assert has_element?(view, "#flash-error")
  end

  test "the edit-character icon navigates to that character's edit form",
       %{conn: conn, chat: chat, c2: c2} do
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    bob = Enum.find(Chats.get_chat(chat.id).participants, &(&1.character_id == c2.id))

    view |> element("#edit-character-#{bob.id}") |> render_click()

    assert_redirect(view, ~p"/characters/#{c2.id}/edit")
  end

  test "clicking a picker link patches to that chat and swaps messages",
       %{conn: conn, second_chat: second_chat} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element(".chat-picker-link", second_chat.name) |> render_click()

    assert has_element?(view, ".chat-picker-link--active", second_chat.name)
    assert render(view) =~ "Greetings traveler"
    assert_patch(view, ~p"/chats/#{second_chat.id}")
  end

  test "a late event from the previous chat stays out of the newly selected one",
       %{conn: conn, chat: chat, second_chat: second_chat} do
    [message_of_a] = Messages.list_messages(chat)
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    render_patch(view, ~p"/chats/#{second_chat.id}")

    # What an event already in flight on the old topic looks like once it lands.
    Messages.broadcast_message_created(second_chat.id, message_of_a)

    refute has_element?(view, "#messages-#{message_of_a.id}")
  end

  test "direct navigation to a chat id selects that chat", %{conn: conn, second_chat: second_chat} do
    {:ok, view, _html} = live(conn, ~p"/chats/#{second_chat.id}")

    assert has_element?(view, ".chat-picker-link--active", second_chat.name)
    assert render(view) =~ "Greetings traveler"
  end

  test "swipe toolbar flips the active body", %{conn: conn, chat: chat} do
    [message] = Messages.list_messages(chat)
    {:ok, _} = Messages.add_body(message, %{content: "swipe two"})

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "button[phx-click='swipe_next']")
    assert has_element?(view, ".chat-message-swipe-count", "2 / 2")
    assert render(view) =~ "swipe two"

    html = render_click(element(view, "button[phx-click='swipe_prev']"))
    assert html =~ "Hello there"
    assert has_element?(view, ".chat-message-swipe-count", "1 / 2")
    refute has_element?(view, "button[phx-click='swipe_prev'][disabled]")
    refute has_element?(view, "button[phx-click='swipe_next'][disabled]")

    html = render_click(element(view, "button[phx-click='swipe_prev']"))
    assert html =~ "swipe two"
    assert has_element?(view, ".chat-message-swipe-count", "2 / 2")
  end

  test "each post carries its author, swipe count and newest swipe's origin for user stylesheets",
       %{conn: conn, chat: chat, c2: c2} do
    [mine] = Messages.list_messages(chat)
    {:ok, _} = Messages.add_body(mine, %{content: "edited"})
    theirs = add_message(chat, c2, "Hi Alice")

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    # Swiping back to the first leaves `data-type` on the newest swipe.
    render_click(element(view, "#messages-#{mine.id} button[phx-click='swipe_prev']"))

    assert has_element?(
             view,
             "li#messages-#{mine.id}.you[data-name='Alice'][data-type='edit'][data-swipe-count='2']"
           )

    assert has_element?(
             view,
             "li#messages-#{theirs.id}:not(.you)[data-name='Bob'][data-type='original'][data-swipe-count='1']"
           )
  end

  defp body_contents(chat) do
    chat
    |> Messages.list_messages()
    |> Enum.map(&(&1.bodies |> List.first() |> Map.fetch!(:content)))
  end

  test "submitting the composer sends a message attributed to the player character",
       %{conn: conn, chat: chat, c1: c1} do
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    render_submit(element(view, "#message-composer"), %{composer: %{content: "Well met"}})

    assert render(view) =~ "Well met"
    assert body_contents(chat) == ["Hello there", "Well met"]

    sent = chat |> Messages.list_messages() |> List.last()
    assert sent.author_is_character
    assert sent.author_character_id == c1.id
  end

  describe "quick replies" do
    defp quick_reply!(scope, name, body) do
      {:ok, script} = Scripts.create_script(scope, %{name: name, trigger: :quick_reply, body: body})
      script
    end

    defp run_quick_reply(view, script, text) do
      render_hook(element(view, "#message-composer-row"), "quick_reply", %{"id" => script.id, "text" => text})
      render_async(view)
    end

    test "a {\"message\", text} return sends the text as Send does", %{scope: scope, conn: conn, chat: chat} do
      wave = quick_reply!(scope, "Wave", ~s|return {"message", event.text .. " *waves*"}|)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      assert has_element?(view, "#quick-reply-#{wave.id}", "Wave")

      run_quick_reply(view, wave, "Hi")

      assert body_contents(chat) == ["Hello there", "Hi *waves*"]
      assert_push_event(view, "composer_sent", %{content: "Hi *waves*"})
    end

    test "a string return replaces the composer text and sends nothing", %{scope: scope, conn: conn, chat: chat} do
      shout = quick_reply!(scope, "Shout", "return event.text:upper()")
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      run_quick_reply(view, shout, "hi")

      assert_push_event(view, "composer:set_text", %{value: "HI"})
      assert body_contents(chat) == ["Hello there"]
    end

    test "a {\"clear\"} return empties the composer and sends nothing", %{scope: scope, conn: conn, chat: chat} do
      clear = quick_reply!(scope, "Clear", ~s|return {"clear"}|)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      run_quick_reply(view, clear, "hi")

      assert_push_event(view, "composer:set_text", %{value: ""})
      assert body_contents(chat) == ["Hello there"]
    end

    test "a new quick reply appears in the toolbar without a reload", %{scope: scope, conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      refute has_element?(view, "#quick-replies")

      script = quick_reply!(scope, "Late", "return nil")
      assert has_element?(view, "#quick-reply-#{script.id}", "Late")
    end
  end

  describe "composer images" do
    defp png,
      do:
        Base.decode64!(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        )

    defp attach_fox(view) do
      input =
        file_input(view, "#message-composer", :composer_files, [%{name: "fox.png", content: png(), type: "image/png"}])

      render_upload(input, "fox.png")
      input
    end

    test "an attached image is sent with the message, text or not", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      attach_fox(view)
      assert has_element?(view, "#composer-attachments figure")
      render_submit(element(view, "#message-composer"), %{composer: %{content: "Look"}})

      sent = chat |> Messages.list_messages() |> List.last()
      assert Message.active_content(sent) == "Look"
      assert has_element?(view, "#message-attachments-#{sent.id} img")
      refute has_element?(view, "#composer-attachments")

      attach_fox(view)
      render_submit(element(view, "#message-composer"), %{composer: %{content: ""}})

      image_only = chat |> Messages.list_messages() |> List.last()
      assert image_only.id != sent.id
      assert Message.active_content(image_only) == ""
      assert has_element?(view, "#message-attachments-#{image_only.id} img")
    end

    test "the attach button is gone without any upload permission", %{scope: scope, conn: conn, chat: chat} do
      for kind <- Attachment.kinds(),
          do: :ok = Mythweaver.Permissions.put_grant!(scope.user, Mythweaver.Attachments.upload_permission(kind), :deny)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      refute has_element?(view, "#composer-attach")
    end

    test "a denied kind is refused with a permission message", %{scope: scope, conn: conn, chat: chat} do
      :ok = Mythweaver.Permissions.put_grant!(scope.user, "uploads.documents", :deny)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      assert has_element?(view, "#composer-attach")

      view
      |> file_input("#message-composer", :composer_files, [
        %{name: "fox.pdf", content: pdf_with_text("Hello fox"), type: "application/pdf"}
      ])
      |> render_upload("fox.pdf")

      assert render(view) =~ "permission to upload that kind of file"
      refute has_element?(view, "#composer-attachments figure.chat-composer-file")
    end

    test "a PDF and an MP3 attach as files and are sent as a document link and a player", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      input =
        file_input(view, "#message-composer", :composer_files, [
          %{name: "fox.pdf", content: pdf_with_text("Hello fox"), type: "application/pdf"},
          %{name: "howl.mp3", content: "ID3" <> <<4, 0, 0, 0, 0, 0>>, type: "audio/mpeg"}
        ])

      render_upload(input, "fox.pdf")
      pdf_id = staged_id()
      render_upload(input, "howl.mp3")
      mp3_id = staged_id()

      assert has_element?(view, "#composer-attachment-#{pdf_id}.chat-composer-file")
      assert has_element?(view, "#composer-attachment-#{mp3_id}.chat-composer-file")
      refute has_element?(view, "#composer-attachment-describe-#{pdf_id}")

      render_submit(element(view, "#message-composer"), %{composer: %{content: "Read"}})

      assert has_element?(view, "#attachment-link-#{pdf_id}.chat-attachment-file")
      assert has_element?(view, "#attachment-#{mp3_id} audio")
      assert %Attachment{kind: :document, page_count: 1} = Mythweaver.Repo.get!(Attachment, pdf_id)
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

    test "caption_image adopts only the user's own staged upload", %{scope: scope, conn: conn, chat: chat} do
      path = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-fox.png")
      File.write!(path, png())
      on_exit(fn -> File.rm(path) end)

      other = Scope.for_user(register_user!(%{role: :user}))
      {:ok, theirs} = Mythweaver.Attachments.store_file(other, path)
      {:ok, mine} = Mythweaver.Attachments.store_file(scope, path)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_hook(view, "caption_image", %{"attachment_id" => theirs.id})
      refute has_element?(view, "#composer-attachments figure")

      render_hook(view, "caption_image", %{"attachment_id" => mine.id})
      assert has_element?(view, "#composer-attachments figure")

      render_hook(view, "remove_composer_attachment", %{"id" => theirs.id})
      assert Mythweaver.Repo.get(Attachment, theirs.id)
    end

    test "with S3 storage the browser uploads straight to the bucket", %{conn: conn, chat: chat} do
      original = Application.get_env(:mythweaver, Mythweaver.Attachments)

      Application.put_env(
        :mythweaver,
        Mythweaver.Attachments,
        Keyword.merge(original,
          storage: :s3,
          s3: [
            bucket: "mw",
            region: "us-east-1",
            endpoint_url: "http://s3.test",
            access_key_id: "minio",
            secret_access_key: "minio123"
          ]
        )
      )

      on_exit(fn -> Application.put_env(:mythweaver, Mythweaver.Attachments, original) end)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      input =
        file_input(view, "#message-composer", :composer_files, [%{name: "fox.png", content: png(), type: "image/png"}])

      assert {:ok, %{entries: entries}} = preflight_upload(input)
      assert [%{uploader: "S3", url: "http://s3.test/mw", fields: %{"policy" => _}}] = Map.values(entries)
    end

    # The newest attachment: the one the composer just stored. v7 ids sort by creation.
    defp staged_id do
      Attachment |> Mythweaver.Repo.all() |> Enum.max_by(& &1.id) |> Map.fetch!(:id)
    end

    defp describe_in_composer(view, id, text) do
      view
      |> element("#message-composer")
      |> render_change(%{
        "_target" => ["attachment_descriptions", id],
        "attachment_descriptions" => %{id => text},
        "composer" => %{"content" => ""}
      })
    end

    test "a description typed for a pending image is sent with it", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      attach_fox(view)
      id = staged_id()
      assert has_element?(view, "#composer-attachment-description-#{id}")

      describe_in_composer(view, id, "A red fox")
      render_submit(element(view, "#message-composer"), %{composer: %{content: "Look"}})

      sent = chat |> Messages.list_messages() |> List.last()
      assert [%{id: ^id, description: "A red fox", caption_status: :done}] = sent.attachments
    end

    # A non-vision chat model ("Skyfall") whose caption model is "JoyCaption", both on one connection.
    defp captioner!(scope, chat) do
      {:ok, provider} =
        AI.create_provider(scope, %{name: "Local", adapter: :openai_compatible, base_url: "http://x/v1"})

      {:ok, joy} = AI.create_model(scope, %{name: "JoyCaption", api_model_id: "joycaption", supports_images: true})
      {:ok, sky} = AI.create_model(scope, %{name: "Skyfall", api_model_id: "skyfall", caption_model_id: joy.id})
      for m <- [joy, sky], do: {:ok, _} = AI.link_model(scope, provider, m)
      {:ok, _} = Chats.update_chat(scope, chat, %{"ai_model_id" => sky.id})
      :ok
    end

    test "a failed description does not hold Send", %{scope: scope, conn: conn, chat: chat} = context do
      Req.Test.set_req_test_to_shared(context)
      captioner!(scope, chat)
      Req.Test.stub(Mythweaver.AI, &Plug.Conn.send_resp(&1, 500, "down"))

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      Mythweaver.Attachments.subscribe(chat.id)
      attach_fox(view)
      id = staged_id()
      assert_receive {:caption_finished, ^id}, 2_000
      assert has_element?(view, "#composer-attachment-#{id} .chat-attachment-status", "Description failed")

      render_submit(element(view, "#message-composer"), %{composer: %{content: "Look"}})
      assert body_contents(chat) == ["Hello there", "Look"]
    end

    test "with images.review_captions off, nothing is described before Send and Send never waits",
         %{scope: scope, conn: conn, chat: chat} = context do
      Req.Test.set_req_test_to_shared(context)
      test = self()
      captioner!(scope, chat)
      :ok = Mythweaver.Settings.put(scope, :user, "images.review_captions", false)

      Req.Test.stub(Mythweaver.AI, fn conn ->
        send(test, {:caption_request, self()})
        Plug.Conn.send_resp(conn, 500, "down")
      end)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      attach_fox(view)
      refute_receive {:caption_request, _}, 200

      render_submit(element(view, "#message-composer"), %{composer: %{content: "Look"}})
      assert body_contents(chat) == ["Hello there", "Look"]
    end

    test "Send waits for a pending description, which can then be edited",
         %{scope: scope, conn: conn, chat: chat, c2: c2} =
           context do
      Req.Test.set_req_test_to_shared(context)
      test = self()
      captioner!(scope, chat)

      # The caption request blocks until the test releases it, so the description stays pending.
      Req.Test.stub(Mythweaver.AI, fn conn ->
        send(test, {:caption_request, self()})
        assert_receive :release, 5_000
        frame = Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => %{"content" => "A red fox"}}]})
        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce(["data: #{frame}\n\n", "data: [DONE]\n\n"], conn, fn chunk, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, chunk)
          conn
        end)
      end)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      Mythweaver.Attachments.subscribe(chat.id)
      attach_fox(view)
      id = staged_id()
      assert_receive {:caption_request, captioner}
      assert has_element?(view, "#composer-attachment-#{id} .chat-attachment-status")

      render_submit(element(view, "#message-composer"), %{composer: %{content: "Look"}})
      assert body_contents(chat) == ["Hello there"]

      send(captioner, :release)
      assert_receive {:caption_finished, ^id}, 2_000
      assert has_element?(view, "#composer-attachment-description-#{id}[data-value='A red fox']")

      describe_in_composer(view, id, "A red fox in snow")
      render_submit(element(view, "#message-composer"), %{composer: %{content: "Look"}})

      sent =
        chat
        |> Messages.list_messages()
        |> Enum.find(&(&1.author_character_id != c2.id and Message.active_content(&1) == "Look"))

      assert [%{description: "A red fox in snow", caption_status: :done, described_by_model_id: nil}] = sent.attachments
    end

    test "a sent image's description can be edited", %{scope: scope, conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      attach_fox(view)
      id = staged_id()
      render_submit(element(view, "#message-composer"), %{composer: %{content: "Look"}})

      view |> element("#attachment-description-edit-#{id}") |> render_click()

      view
      |> form("#attachment-description-form-#{id}", %{"description" => "A sleeping fox"})
      |> render_submit()

      refute has_element?(view, "#attachment-description-form-#{id}")
      assert Mythweaver.Attachments.get_attachment(scope, id).description == "A sleeping fox"
      assert render(view) =~ "A sleeping fox"
    end

    # Answers every caption request with `text`, sending its decoded body to the test.
    defp stub_caption(text) do
      test = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:caption_body, Jason.decode!(raw)})
        frame = Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => %{"content" => text}}]})
        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce(["data: #{frame}\n\n", "data: [DONE]\n\n"], conn, fn chunk, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, chunk)
          conn
        end)
      end)
    end

    defp question_text(body) do
      %{"content" => [%{"type" => "text", "text" => text} | _]} = List.last(body["messages"])
      text
    end

    test "Ask… sends a one-off question about a staged image", %{scope: scope, conn: conn, chat: chat} = context do
      Req.Test.set_req_test_to_shared(context)
      captioner!(scope, chat)
      stub_caption("Yes, it is night")
      :ok = Mythweaver.Settings.put(scope, :user, "images.auto_caption", false)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      Mythweaver.Attachments.subscribe(chat.id)
      :ok = Mythweaver.Jobs.subscribe(scope)
      attach_fox(view)
      id = staged_id()
      refute_received {:caption_body, _}

      view |> element("#composer-attachment-ask-#{id}") |> render_click()
      assert has_element?(view, "#caption-question-modal")

      view |> form("#caption-question-form", %{"question" => "Is it night?"}) |> render_submit()
      refute has_element?(view, "#caption-question-modal")
      assert_receive {:caption_body, body}, 2_000
      assert question_text(body) == "Is it night?"
      assert_receive {:caption_finished, ^id}, 2_000
      assert_receive {:job_changed, %{tag: :caption, status: :completed}}, 2_000
    end

    test "with images.ask_every_time on, Describe asks first", %{scope: scope, conn: conn, chat: chat} = context do
      Req.Test.set_req_test_to_shared(context)
      captioner!(scope, chat)
      stub_caption("A fox")
      :ok = Mythweaver.Settings.put(scope, :user, "images.ask_every_time", true)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      Mythweaver.Attachments.subscribe(chat.id)
      :ok = Mythweaver.Jobs.subscribe(scope)
      attach_fox(view)
      id = staged_id()
      # The upload's own automatic description asks too.
      assert has_element?(view, "#caption-question-modal")
      render_hook(view, "cancel_caption_question", %{})
      refute has_element?(view, "#caption-question-modal")

      view |> element("#composer-attachment-describe-#{id}") |> render_click()
      assert has_element?(view, "#caption-question-modal")
      refute_received {:caption_body, _}

      view |> form("#caption-question-form", %{"question" => ""}) |> render_submit()
      assert_receive {:caption_body, body}, 2_000
      assert question_text(body) == AI.Model.default_caption_prompt()
      assert_receive {:caption_finished, ^id}, 2_000
      assert_receive {:job_changed, %{tag: :caption, status: :completed}}, 2_000
    end

    test "with images.review_results on, a sent image's caption is reviewed in place",
         %{scope: scope, conn: conn, chat: chat} = context do
      Req.Test.set_req_test_to_shared(context)
      captioner!(scope, chat)
      stub_caption("A caption")
      :ok = Mythweaver.Settings.put(scope, :user, "images.review_captions", false)
      :ok = Mythweaver.Settings.put(scope, :user, "images.review_results", true)
      :ok = Mythweaver.Jobs.subscribe(scope)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      attach_fox(view)
      id = staged_id()
      render_submit(element(view, "#message-composer"), %{composer: %{content: "Look"}})
      assert_receive {:job_changed, %{tag: :caption, status: :review}}, 2_000

      assert has_element?(view, "#attachment-review-form-#{id}")
      view |> form("#attachment-review-form-#{id}", %{"text" => "Edited"}) |> render_submit()

      refute has_element?(view, "#attachment-review-form-#{id}")
      assert %{caption_status: :done, description: "Edited"} = Mythweaver.Attachments.get_attachment(scope, id)
    end

    test "a script's image request shows in every tab; the image it brings carries the tag and data",
         %{scope: scope, conn: conn, chat: chat} do
      {:ok, _} =
        Mythweaver.Scripts.create_script(scope, %{
          name: "Tagged-#{System.unique_integer([:positive])}",
          trigger: :image_described,
          body: ~S'return event.text .. " #" .. tostring(event.tag) .. " for " .. event.data.who'
        })

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      {:ok, other, _html} = live(conn, ~p"/chats/#{chat.id}")

      {:ok, callback} = CallbackStore.put("letter", %{"who" => "Geralt"})
      Mythweaver.Attachments.request_image(chat.id, "Show the letter.", callback)
      assert has_element?(view, "#image-request-modal #image-request-prompt", "Show the letter.")
      assert has_element?(other, "#image-request-modal")

      attach_fox(view)
      refute has_element?(view, "#image-request-modal")
      refute has_element?(other, "#image-request-modal")

      id = staged_id()
      describe_in_composer(view, id, "A folded letter")
      render_submit(element(view, "#message-composer"), %{composer: %{content: "Here"}})

      assert Mythweaver.Attachments.get_attachment(scope, id).description == "A folded letter #letter for Geralt"
    end

    test "dismissing a request closes it in every tab, and a newer one replaces it", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      {:ok, other, _html} = live(conn, ~p"/chats/#{chat.id}")

      Mythweaver.Attachments.request_image(chat.id, "First", nil)
      Mythweaver.Attachments.request_image(chat.id, "Second", nil)
      assert has_element?(view, "#image-request-prompt", "Second")

      render_hook(view, "dismiss_image_request", %{})
      refute has_element?(view, "#image-request-modal")
      refute has_element?(other, "#image-request-modal")
    end

    test "mw.characters.set_avatar's request makes the chosen image the character's avatar",
         %{scope: scope, conn: conn, chat: chat, c2: c2} = context do
      Req.Test.set_req_test_to_shared(context)
      Req.Test.stub(Mythweaver.AI, &Plug.Conn.send_resp(&1, 500, "down"))
      {:ok, _} = AI.create_model(scope, %{name: "Eyes", api_model_id: "eyes", supports_images: true}, site: true)

      set_avatar = fn args ->
        {:ok, script} =
          Scripts.create_script(scope, %{
            name: "Avatar-#{System.unique_integer([:positive])}",
            trigger: :command,
            body: ~s|return tostring(mw.characters.set_avatar("#{c2.id}"#{args}))|
          })

        assert {:ok, "true", []} = Scripts.run_command(scope, script.id, chat, %{})
      end

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      set_avatar.(", nil, false")
      assert has_element?(view, "#image-request-prompt", "an avatar for #{c2.name}")
      attach_fox(view)

      refute has_element?(view, "#image-request-modal")
      refute has_element?(view, "#composer-attachments")
      avatar = Characters.preload_avatar(scope, c2) |> Map.fetch!(:avatar)
      assert avatar.caption_status == :none

      # Described by default: the caption starts as soon as the avatar is set.
      set_avatar.(~s|, "Your portrait?"|)
      assert has_element?(view, "#image-request-prompt", "Your portrait?")
      attach_fox(view)

      new_avatar = Characters.preload_avatar(scope, c2) |> Map.fetch!(:avatar)
      assert new_avatar.id != avatar.id
      assert new_avatar.caption_status in [:pending, :failed]
    end

    test "an edit swaps a message's images without a new swipe", %{scope: scope, conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      attach_fox(view)
      old = staged_id()
      render_submit(element(view, "#message-composer"), %{composer: %{content: "Look"}})
      sent = chat |> Messages.list_messages() |> List.last()

      render_click(element(view, "#message-edit-#{sent.id}"))
      assert has_element?(view, "#message-edit-attachment-#{old}")

      view
      |> file_input("#message-edit-files-form", :edit_files, [%{name: "b.png", content: png(), type: "image/png"}])
      |> render_upload("b.png")

      new = staged_id()
      assert has_element?(view, "#message-edit-attachment-#{new}")
      render_click(element(view, "#message-edit-attachment-remove-#{old}"))
      render_submit(element(view, "#message-edit-form-#{sent.id}"), %{message_body: %{content: "Look"}})

      edited = Messages.get_message!(scope, sent.id)
      assert [%{id: ^new}] = edited.attachments
      assert length(edited.bodies) == 1
      refute Mythweaver.Repo.get(Attachment, old)
      assert has_element?(view, "#message-attachments-#{sent.id} #attachment-#{new}")
    end

    test "in a chat whose model sees images, Describe uses that model",
         %{scope: scope, conn: conn, chat: chat} = context do
      Req.Test.set_req_test_to_shared(context)
      test = self()

      {:ok, provider} =
        AI.create_provider(scope, %{name: "Local", adapter: :openai_compatible, base_url: "http://x/v1"})

      {:ok, joy} = AI.create_model(scope, %{name: "Joy", api_model_id: "joy", supports_images: true})
      {:ok, _} = AI.link_model(scope, provider, joy)

      Req.Test.stub(Mythweaver.AI, fn conn ->
        send(test, {:caption_request, self()})
        assert_receive :release, 5_000
        Plug.Conn.send_resp(conn, 500, "down")
      end)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      attach_fox(view)
      id = staged_id()
      render_submit(element(view, "#message-composer"), %{composer: %{content: "Look"}})
      {:ok, _} = Chats.update_chat(scope, chat, %{"ai_model_id" => joy.id})
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      Mythweaver.Attachments.subscribe(chat.id)

      html = render_click(element(view, "#attachment-caption-#{id}"))
      refute html =~ "No model in this chat can"
      assert %Attachment{caption_status: :pending} = Mythweaver.Repo.get!(Attachment, id)

      assert_receive {:caption_request, captioner}
      send(captioner, :release)
      assert_receive {:caption_finished, ^id}, 2_000
    end
  end

  test "typing persists a draft without adding it to the transcript",
       %{scope: scope, conn: conn, chat: chat} do
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    render_change(element(view, "#message-composer"), %{composer: %{content: "half typed"}})

    assert Messages.draft_content(scope, chat) == "half typed"
    refute Messages.get_draft(chat)

    :ok = DraftBuffer.flush(chat.id)
    assert hd(Messages.get_draft(chat).bodies).content == "half typed"
    assert body_contents(chat) == ["Hello there"]
  end

  test "a new mount resumes the persisted draft", %{conn: conn, chat: chat} do
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    render_change(element(view, "#message-composer"), %{composer: %{content: "half typed"}})

    {:ok, resumed, _html} = live(conn, ~p"/chats/#{chat.id}")
    assert render(resumed) =~ "half typed"
  end

  test "switching the player keeps the composer's draft", %{scope: scope, conn: conn, chat: chat, c2: c2} do
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    render_change(element(view, "#message-composer"), %{composer: %{content: "half typed"}})

    bob = Enum.find(Chats.get_chat(chat.id).participants, &(&1.character_id == c2.id))
    view |> element("#play-as-#{bob.id}") |> render_click()

    assert Messages.draft_content(scope, chat) == "half typed"
    {:ok, resumed, _html} = live(conn, ~p"/chats/#{chat.id}")
    assert render(resumed) =~ "half typed"
  end

  test "sending clears the draft", %{scope: scope, conn: conn, chat: chat} do
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    render_change(element(view, "#message-composer"), %{composer: %{content: "half typed"}})
    render_submit(element(view, "#message-composer"), %{composer: %{content: "half typed"}})

    assert Messages.draft_content(scope, chat) == ""
    assert body_contents(chat) == ["Hello there", "half typed"]

    :ok = DraftBuffer.flush(chat.id)
    assert Messages.get_draft(chat) == nil
  end

  test "submitting blank content is a no-op", %{conn: conn, chat: chat} do
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    render_submit(element(view, "#message-composer"), %{composer: %{content: "   "}})

    assert body_contents(chat) == ["Hello there"]
  end

  test "a sent message is broadcast to every LiveView on the chat", %{conn: conn, chat: chat} do
    {:ok, sender, _html} = live(conn, ~p"/chats/#{chat.id}")
    {:ok, watcher, _html} = live(conn, ~p"/chats/#{chat.id}")

    render_submit(element(sender, "#message-composer"), %{composer: %{content: "Well met"}})

    assert render(watcher) =~ "Well met"
  end

  test "a chat without a player character shows a notice instead of the composer",
       %{scope: scope, conn: conn, chat: chat} do
    {:ok, chat} = Chats.update_chat(scope, chat, %{player_character_id: nil})

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    refute has_element?(view, "#message-composer")
    assert has_element?(view, ".chat-composer-notice")
  end

  test "the sending tab is told it owns the append", %{conn: conn, chat: chat} do
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    render_submit(element(view, "#message-composer"), %{composer: %{content: "Well met"}})

    assert_push_event(view, "message_appended", %{own: true})
  end

  test "a receiving tab is told it does not own the append", %{conn: conn, chat: chat} do
    {:ok, sender, _html} = live(conn, ~p"/chats/#{chat.id}")
    {:ok, watcher, _html} = live(conn, ~p"/chats/#{chat.id}")

    render_submit(element(sender, "#message-composer"), %{composer: %{content: "Well met"}})

    assert render(watcher) =~ "Well met"
    assert_push_event(watcher, "message_appended", %{own: false})
  end

  test "the page title follows the open chat", %{conn: conn, chat: chat} do
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    assert page_title(view) == "Alpha Chat • Mythweaver"

    render_click(element(view, ".chat-picker-link", "Zeta Chat"))
    assert page_title(view) == "Zeta Chat"
  end

  test "other senders' messages signal an arrival; the tab's own sends do not",
       %{conn: conn, scope: scope, chat: chat, c2: c2} do
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    {:ok, _} = Messages.send_message(scope, chat, c2.id, "from elsewhere")
    assert_push_event(view, "message_arrived", %{})

    render_submit(element(view, "#message-composer"), %{composer: %{content: "mine"}})
    refute_push_event(view, "message_arrived", %{})
  end

  test "a reply signals its arrival when it finishes, and a continue never does",
       %{conn: conn, scope: scope, chat: chat, c2: c2} do
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    {:ok, reply} = Messages.create_generating_message(chat, c2.id)
    refute_push_event(view, "message_arrived", %{})

    Messages.broadcast_generation_finished(chat.id, reply.id)
    assert_push_event(view, "message_arrived", %{})

    [%{id: id} | _] = Messages.list_messages(chat)
    earlier = Messages.get_message!(scope, id)
    {:ok, _} = Messages.add_continuing_body(earlier, Message.active_body(earlier))
    Messages.broadcast_message_created(chat.id, Messages.get_message!(scope, id))
    Messages.broadcast_generation_finished(chat.id, id)
    refute_push_event(view, "message_arrived", %{})
  end

  test "selecting a chat requests a scroll reset", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert_push_event(view, "scroll_to_bottom", %{})
  end

  test "typing is shown to other tabs only", %{conn: conn, chat: chat} do
    {:ok, typer, _html} = live(conn, ~p"/chats/#{chat.id}")
    {:ok, watcher, _html} = live(conn, ~p"/chats/#{chat.id}")

    render_hook(element(typer, "#message-composer-row"), "typing")

    assert has_element?(watcher, ".chat-typing-indicator", "Alice is typing")
    refute has_element?(watcher, "#chat-typing-ai")
    refute has_element?(typer, ".chat-typing-indicator", "Alice is typing")
  end

  test "stopping typing clears the indicator", %{conn: conn, chat: chat} do
    {:ok, typer, _html} = live(conn, ~p"/chats/#{chat.id}")
    {:ok, watcher, _html} = live(conn, ~p"/chats/#{chat.id}")

    render_hook(element(typer, "#message-composer-row"), "typing")
    assert has_element?(watcher, ".chat-typing-indicator", "Alice is typing")

    render_hook(element(typer, "#message-composer-row"), "stop_typing")

    refute has_element?(watcher, ".chat-typing-indicator", "Alice is typing")
  end

  test "sending clears the indicator in other tabs", %{conn: conn, chat: chat} do
    {:ok, typer, _html} = live(conn, ~p"/chats/#{chat.id}")
    {:ok, watcher, _html} = live(conn, ~p"/chats/#{chat.id}")

    render_hook(element(typer, "#message-composer-row"), "typing")
    assert has_element?(watcher, ".chat-typing-indicator", "Alice is typing")

    render_submit(element(typer, "#message-composer"), %{composer: %{content: "Well met"}})

    assert render(watcher) =~ "Well met"
    refute has_element?(watcher, ".chat-typing-indicator", "Alice is typing")
  end

  test "the typing TTL clears the indicator", %{conn: conn, chat: chat, c1: c1} do
    {:ok, typer, _html} = live(conn, ~p"/chats/#{chat.id}")
    {:ok, watcher, _html} = live(conn, ~p"/chats/#{chat.id}")

    render_hook(element(typer, "#message-composer-row"), "typing")
    assert has_element?(watcher, ".chat-typing-indicator", "Alice is typing")

    send(watcher.pid, {:typing_expired, c1.id})

    refute has_element?(watcher, ".chat-typing-indicator", "Alice is typing")
  end

  test "the new-chat header button opens the create modal", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    refute has_element?(view, "#chat-form")
    assert has_element?(view, ~s(.chat-picker header #new-chat[aria-label="New chat"]))

    view |> element("#new-chat") |> render_click()

    assert has_element?(view, "#new-chat-modal #chat-form")
    assert has_element?(view, "#chat-form-participants")
  end

  test "creating a chat from the modal adds it to the rail", %{conn: conn, user: user, c1: c1, c2: c2} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#new-chat") |> render_click()

    view
    |> form("#chat-form", chat: %{name: "Guild Hall", participant_ids: [c1.id, c2.id]})
    |> render_submit()

    refute has_element?(view, "#chat-form")
    assert has_element?(view, ".chat-picker-link", "Guild Hall")

    created = Enum.find(Chats.list_chats(Scope.for_user(user)), &(&1.name == "Guild Hall"))

    assert created.participants |> Enum.map(& &1.character_id) |> Enum.sort() ==
             Enum.sort([c1.id, c2.id])
  end

  test "a chat created with a character's greeting opens on it",
       %{conn: conn, user: user, scope: scope, c1: c1, c2: c2} do
    {:ok, _c2} = Characters.update_character(scope, c2, %{first_message: "Welcome, {{ anchors.player.name }}."})
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#new-chat") |> render_click()

    view
    |> form("#chat-form", chat: %{name: "Greeted", participant_ids: [c1.id, c2.id]})
    |> render_change(%{"chat" => %{"player_character_id" => c1.id}})

    assert has_element?(view, "#chat-form-greeting option[value='#{c2.id}']")
    refute has_element?(view, "#chat-form-greeting option[value='#{c1.id}']")

    view
    |> form("#chat-form")
    |> render_submit(%{"chat" => %{"player_character_id" => c1.id, "greeting" => c2.id}})

    created = Enum.find(Chats.list_chats(Scope.for_user(user)), &(&1.name == "Greeted"))
    assert [message] = Messages.list_messages(created)
    assert message.author_character_id == c2.id
    assert Message.active_content(message) == "Welcome, Alice."
  end

  test "a chat created with the narrator's greeting opens on it", %{conn: conn, user: user, c1: c1, c2: c2} do
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#new-chat") |> render_click()
    refute has_element?(view, "#chat-form-greeting-text")

    view
    |> form("#chat-form", chat: %{name: "Narrated", participant_ids: [c1.id, c2.id]})
    |> render_change(%{"chat" => %{"greeting" => "custom"}})

    assert has_element?(view, "#chat-form-greeting-text")

    view
    |> form("#chat-form")
    |> render_submit(%{"chat" => %{"greeting" => "custom", "greeting_text" => "Rain falls."}})

    created = Enum.find(Chats.list_chats(Scope.for_user(user)), &(&1.name == "Narrated"))
    assert [%{author_is_character: false, author_name: "Narrator"} = message] = Messages.list_messages(created)
    assert Message.active_content(message) == "Rain falls."
  end

  test "a group chat created with every character's greeting opens on one message each",
       %{conn: conn, user: user, scope: scope, c1: c1, c2: c2} do
    {:ok, c2} = Characters.update_character(scope, c2, %{first_message: "Bob here."})
    {:ok, c3} = Characters.create_character(scope, %{name: "Cora", first_message: "Cora here."})
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#new-chat") |> render_click()
    refute has_element?(view, "#chat-form-greeting option[value='all']")

    view
    |> form("#chat-form", chat: %{name: "Gathered", participant_ids: [c1.id, c2.id, c3.id]})
    |> render_change(%{"chat" => %{"player_character_id" => c1.id}})

    assert has_element?(view, "#chat-form-greeting option[value='all']")

    view
    |> form("#chat-form")
    |> render_submit(%{"chat" => %{"player_character_id" => c1.id, "greeting" => "all"}})

    created = Enum.find(Chats.list_chats(Scope.for_user(user)), &(&1.name == "Gathered"))
    assert [first, second] = Messages.list_messages(created)
    assert {first.author_character_id, Message.active_content(first)} == {c2.id, "Bob here."}
    assert {second.author_character_id, Message.active_content(second)} == {c3.id, "Cora here."}
  end

  test "one participant keeps the create modal open and creates nothing", %{conn: conn, user: user, c1: c1} do
    {:ok, view, _html} = live(conn, ~p"/")
    before = length(Chats.list_chats(Scope.for_user(user)))

    view |> element("#new-chat") |> render_click()

    html =
      view
      |> form("#chat-form", chat: %{name: "Solo", participant_ids: [c1.id]})
      |> render_submit()

    assert html =~ "must have at least 2 participants"
    assert has_element?(view, "#chat-form")
    assert length(Chats.list_chats(Scope.for_user(user))) == before
  end

  test "the settings route renames the chat and Save closes the modal",
       %{conn: conn, second_chat: second_chat} do
    {:ok, view, _html} = live(conn, ~p"/chats/#{second_chat.id}/settings")

    assert has_element?(view, "#chat-settings-modal #chat-settings-form")

    view |> form("#chat-settings-form", settings: %{name: "Zeta Renamed"}) |> render_submit()

    assert_patch(view, ~p"/chats/#{second_chat.id}")
    assert Chats.get_chat(second_chat.id).name == "Zeta Renamed"
    assert has_element?(view, ".chat-picker-link", "Zeta Renamed")
    assert page_title(view) == "Zeta Renamed"
    refute has_element?(view, "#chat-settings-form")
  end

  test "Group cards defaults to swap and saves join all", %{conn: conn, second_chat: second_chat} do
    {:ok, view, _html} = live(conn, ~p"/chats/#{second_chat.id}/settings")

    assert has_element?(view, "#chat-settings-form-group_cards option[value='swap'][selected]")

    view |> form("#chat-settings-form", settings: %{group_cards: "join_all"}) |> render_submit()

    assert Chats.get_chat(second_chat.id).group_cards == :join_all
  end

  test "chat settings save tags and the picker filters chats by tag",
       %{conn: conn, scope: scope, chat: chat, second_chat: second_chat} do
    {:ok, view, _html} = live(conn, ~p"/chats/#{second_chat.id}/settings")

    assert has_element?(view, "#chat-settings-form-tags-mine")

    view
    |> form("#chat-settings-form")
    |> render_submit(%{"tags" => %{"mine" => ["", "Campaign:One"]}})

    assert Mythweaver.Tags.item_tags(scope, Chats.get_chat(second_chat.id)).mine == ["campaign:one"]

    refute has_element?(view, "#chat-filter")
    view |> element("#chat-search-toggle") |> render_click()
    view |> form("#chat-filter") |> render_change(%{"query" => "", "tag_filter" => ["campaign:one"]})

    assert has_element?(view, "#chats-#{second_chat.id}")
    refute has_element?(view, "#chats-#{chat.id}")

    view |> form("#chat-filter") |> render_change(%{"query" => "", "tag_filter" => ["campaign:two"]})
    assert has_element?(view, ".chat-picker-empty", "No matching chats")

    # Closing the search clears its filter.
    view |> element("#chat-search-toggle") |> render_click()
    refute has_element?(view, "#chat-filter")
    assert has_element?(view, "#chats-#{chat.id}")
  end

  test "deleting the selected chat removes it and selects another", %{conn: conn, chat: chat} do
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}/settings")

    view |> element("#chat-settings-delete") |> render_click()

    assert Chats.get_chat(chat.id) == nil
    refute has_element?(view, "a.chat-picker-link[href='/chats/#{chat.id}']")
    refute has_element?(view, ".chat-picker-link", chat.name)
    assert has_element?(view, ".chat-picker-link--active")
  end

  test "the owner's chat settings link to the export page; the chat window doesn't", %{conn: conn, chat: chat} do
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    refute has_element?(view, "#chat-settings-export")

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}/settings")
    assert has_element?(view, ~s(#chat-settings-export[href="/export?kind=chat&item=#{chat.id}"]))
  end

  describe "chat settings" do
    test "the header button opens the modal on its own route", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      view |> element("#chat-settings-button") |> render_click()

      assert_patch(view, ~p"/chats/#{chat.id}/settings")
      assert has_element?(view, "#chat-settings-modal")
    end

    test "Apply keeps the modal open and applies every field",
         %{scope: scope, conn: conn, chat: chat, c2: c2} do
      c3 = character(scope, "Cara")
      {:ok, book} = Mythweaver.Lore.create_book(scope, %{name: "Book"})
      {:ok, prompt} = Prompts.create_prompt(scope, %{name: "P"})
      {:ok, model} = AI.create_model(scope, %{name: "M", api_model_id: "m"})

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}/settings")

      # The player select only offers selected participants, so pick them first, as a user would.
      view
      |> form("#chat-settings-form", settings: %{participant_ids: [c2.id, c3.id]})
      |> render_change()

      view
      |> form("#chat-settings-form",
        settings: %{
          participant_ids: [c2.id, c3.id],
          player_character_id: c3.id,
          lore_book_ids: [book.id],
          prompt_id: prompt.id,
          ai_model_id: model.id
        }
      )
      |> render_submit(%{intent: "apply"})

      assert has_element?(view, "#chat-settings-form")

      reloaded = Chats.get_chat(chat.id)
      assert MapSet.new(reloaded.participants, & &1.character_id) == MapSet.new([c2.id, c3.id])
      assert reloaded.player_character_id == c3.id
      assert reloaded.ai_model_id == model.id
      assert Mythweaver.Lore.chat_book_ids(chat) == [book.id]
      assert Prompts.chat_prompt_id(chat) == prompt.id
      assert Prompts.resolve_prompt(%{chat: chat}).id == prompt.id
    end

    test "player choices are the participants plus the live selection",
         %{scope: scope, conn: conn, chat: chat, c1: c1, c2: c2} do
      c3 = character(scope, "Cara")
      c4 = character(scope, "Dmitri")
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}/settings")

      player = "#chat-settings-form-player_character_id option"
      assert has_element?(view, "#{player}[value='#{c1.id}']")
      assert has_element?(view, "#{player}[value='#{c2.id}']")
      refute has_element?(view, "#{player}[value='#{c3.id}']")

      view
      |> form("#chat-settings-form", settings: %{participant_ids: [c1.id, c2.id, c3.id]})
      |> render_change()

      assert has_element?(view, "#{player}[value='#{c3.id}']")
      refute has_element?(view, "#{player}[value='#{c4.id}']")
    end

    test "one participant is rejected, changes nothing and opens the Participants tab",
         %{conn: conn, chat: chat, c1: c1} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}/settings")
      assert has_element?(view, "#chat-settings-tab-basics[aria-selected='true']")

      html =
        view
        |> form("#chat-settings-form", settings: %{participant_ids: [c1.id]})
        |> render_submit()

      assert html =~ "must have at least 2 participants"
      assert has_element?(view, "#chat-settings-form")
      assert length(Chats.get_chat(chat.id).participants) == 2
      assert has_element?(view, "#chat-settings-tab-participants[aria-selected='true'][data-invalid]")
      refute has_element?(view, "#chat-settings-panel-participants[hidden]")
      assert has_element?(view, "#chat-settings-panel-basics[hidden]")
    end

    test "switching tabs keeps unsaved edits, and Save writes every tab",
         %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}/settings")

      view |> form("#chat-settings-form", settings: %{name: "Renamed"}) |> render_change()
      view |> element("#chat-settings-tab-replies") |> render_click()
      assert has_element?(view, "#chat-settings-panel-basics[hidden]")
      refute has_element?(view, "#chat-settings-panel-replies[hidden]")
      assert has_element?(view, "#chat-settings-form-name[value='Renamed']")

      view |> form("#chat-settings-form", settings: %{max_turns: "3"}) |> render_submit()
      reloaded = Chats.get_chat(chat.id)
      assert {reloaded.name, reloaded.max_turns} == {"Renamed", 3}
    end

    test "emptied lore books and prompt clear the bindings", %{scope: scope, conn: conn, chat: chat} do
      {:ok, book} = Mythweaver.Lore.create_book(scope, %{name: "Book"})
      {:ok, prompt} = Prompts.create_prompt(scope, %{name: "P"})
      {:ok, _} = Mythweaver.Lore.bind_book_to_chat(book, chat.id)
      {:ok, :ok} = Prompts.set_chat_prompt(chat, prompt.id)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}/settings")

      view
      |> form("#chat-settings-form", settings: %{lore_book_ids: [""], prompt_id: ""})
      |> render_submit(%{intent: "apply"})

      assert Mythweaver.Lore.chat_book_ids(chat) == []
      assert Prompts.chat_prompt_id(chat) == nil
    end

    test "the form is guarded and flags only renders of saved values",
         %{conn: conn, chat: chat, c1: c1, c2: c2} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}/settings")

      guarded = "#chat-settings-form[phx-hook='UnsavedChanges']"
      assert has_element?(view, "#{guarded}[data-saved]")

      view |> form("#chat-settings-form", settings: %{name: "Edited"}) |> render_change()
      assert has_element?(view, guarded)
      refute has_element?(view, "#{guarded}[data-saved]")

      view |> form("#chat-settings-form", settings: %{participant_ids: [c1.id]}) |> render_submit()
      refute has_element?(view, "#{guarded}[data-saved]")

      view
      |> form("#chat-settings-form", settings: %{name: "Edited", participant_ids: [c1.id, c2.id]})
      |> render_submit(%{intent: "apply"})

      assert has_element?(view, "#{guarded}[data-saved]")
    end

    test "participant picker filters by name and tag without dropping hidden selections",
         %{scope: scope, conn: conn, chat: chat, c1: c1, c2: c2} do
      c3 = character(scope, "Cara")
      {:ok, _} = Mythweaver.Tags.create_tag(scope, %{"text" => "character:samus", "parent_texts" => ["series:metroid"]})
      :ok = Mythweaver.Tags.set_item_tags(scope, c3, :mine, ["character:samus"])
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}/settings")

      view
      |> form("#chat-settings-form", settings: %{participant_ids: [c1.id, c2.id, c3.id]})
      |> render_change()

      picker = "chat-settings-form-participant_ids"
      filter = &render_change(element(view, &1), %{picker => &2})

      filter.("##{picker}-query", %{"query" => "car"})
      assert has_element?(view, "##{picker}-option-#{c1.id}[hidden]")
      refute has_element?(view, "##{picker}-option-#{c3.id}[hidden]")
      assert has_element?(view, "##{picker}-count", "3 selected")

      filter.("##{picker}-query", %{"query" => ""})
      render_click(element(view, "##{picker}-tags-toggle"))
      # The chip names the tag's implied parent.
      filter.("##{picker}-tags input[data-tag-sentinel]", %{"tag_filter" => ["", "series:metroid"]})
      assert has_element?(view, "##{picker}-option-#{c1.id}[hidden]")
      refute has_element?(view, "##{picker}-option-#{c3.id}[hidden]")

      # Hidden checked boxes still post.
      view |> form("#chat-settings-form") |> render_submit(%{intent: "apply"})

      assert MapSet.new(Chats.get_chat(chat.id).participants, & &1.character_id) ==
               MapSet.new([c1.id, c2.id, c3.id])

      # Closing the tag filter clears its chips.
      render_click(element(view, "##{picker}-tags-toggle"))
      refute has_element?(view, "##{picker}-tag-filter")
      refute has_element?(view, "##{picker}-option-#{c1.id}[hidden]")
    end

    test "checked only shows the rows checked when turned on, and keeps one unchecked after",
         %{scope: scope, conn: conn, chat: chat, c1: c1, c2: c2} do
      c3 = character(scope, "Cara")
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}/settings")
      picker = "chat-settings-form-participant_ids"

      render_click(element(view, "##{picker}-checked-only"))
      assert has_element?(view, "##{picker}-checked-only[aria-pressed=true]")
      assert has_element?(view, "##{picker}-option-#{c3.id}[hidden]")
      refute has_element?(view, "##{picker}-option-#{c1.id}[hidden]")

      # Unchecking c1 leaves its row in place, to check again.
      view
      |> form("#chat-settings-form", settings: %{participant_ids: [c2.id]})
      |> render_change()

      refute has_element?(view, "##{picker}-option-#{c1.id}[hidden]")
      refute has_element?(view, "##{picker}-#{c1.id}[checked]")

      render_click(element(view, "##{picker}-checked-only"))
      refute has_element?(view, "##{picker}-option-#{c3.id}[hidden]")
    end
  end

  describe "generation" do
    # A trimmed llama.cpp stream (reasoning, content, finish, usage, sentinel), one HTTP chunk per frame.
    @chat_frames [
      ~s(data: {"choices":[{"finish_reason":null,"index":0,"delta":{"reasoning_content":"Hmm"}}]}\n\n),
      ~s(data: {"choices":[{"finish_reason":null,"index":0,"delta":{"content":"po"}}]}\n\n),
      ~s(data: {"choices":[{"finish_reason":null,"index":0,"delta":{"content":"ng"}}]}\n\n),
      ~s(data: {"choices":[{"finish_reason":"stop","index":0,"delta":{}}]}\n\n),
      ~s(data: {"choices":[],"usage":{"completion_tokens":31,"prompt_tokens":18,"total_tokens":49}}\n\n),
      "data: [DONE]\n\n"
    ]

    setup context do
      # The AI task is spawned by the generation GenServer, outside the LiveView's `$callers` chain.
      Req.Test.set_req_test_to_shared(context)
      generation_setup(context.scope)
      :ok
    end

    # A reachable model plus a globally bound prompt: the two pre-flight requirements of
    # `Mythweaver.Generation.generate/3`.
    defp generation_setup(scope, content \\ "Be brief.") do
      {:ok, model} = AI.create_model(scope, %{name: "Gemma 4", api_model_id: "gemma-4"})

      {:ok, provider} =
        AI.create_provider(scope, %{
          name: "Local",
          adapter: :openai_compatible,
          base_url: "http://localhost:8080/v1"
        })

      {:ok, _link} = AI.link_model(scope, provider, model)

      {:ok, prompt} = Prompts.create_prompt(scope, %{name: "Default"})
      {:ok, block} = Prompts.create_block(scope, %{name: "Sys", content: content})
      {:ok, _} = Prompts.add_block(scope, prompt, block)
      {:ok, _binding} = Prompts.bind_prompt(scope, prompt, :global)

      :ok
    end

    defp stub_chat_stream do
      Req.Test.stub(Mythweaver.AI, fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce(@chat_frames, conn, fn frame, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, frame)
          conn
        end)
      end)
    end

    # The generation writes and broadcasts from another process, so the rendered result arrives after
    # the click returns. There is no `start_async` in this LiveView, so `render_async/1` does not apply.
    defp eventually(fun, tries \\ 50) do
      fun.()
    rescue
      error ->
        if tries > 0 do
          Process.sleep(10)
          eventually(fun, tries - 1)
        else
          reraise(error, __STACKTRACE__)
        end
    end

    defp bot_participant(chat, bot) do
      chat |> Chats.get_chat!() |> Map.fetch!(:participants) |> Enum.find(&(&1.character_id == bot.id))
    end

    test "the sparkle button streams a reply into the transcript", %{
      conn: conn,
      chat: chat,
      c2: bot
    } do
      stub_chat_stream()
      participant = bot_participant(chat.id, bot)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_click(element(view, "#generate-#{participant.id}"))

      eventually(fn -> assert render(view) =~ "pong" end)

      generated = chat |> Messages.list_messages() |> List.last()
      assert generated.author_character_id == bot.id
      body = Enum.find(generated.bodies, & &1.active)
      assert body.content == "pong"
      assert body.generating == false
      assert body.reasoning == "Hmm"

      eventually(fn ->
        assert has_element?(view, "#reasoning-#{generated.id}", "Hmm")
        refute has_element?(view, "#reasoning-#{generated.id}[open]")
      end)
    end

    test "the player's row has a sparkle button that writes a reply as the player", %{
      conn: conn,
      chat: chat,
      c1: player
    } do
      stub_chat_stream()
      participant = bot_participant(chat.id, player)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_click(element(view, "#generate-#{participant.id}"))

      eventually(fn -> assert render(view) =~ "pong" end)

      generated = chat |> Messages.list_messages() |> List.last()
      assert generated.author_character_id == player.id
      assert Enum.find(generated.bodies, & &1.active).content == "pong"
    end

    test "the Thinking region is open while only reasoning streams, then collapses", %{
      conn: conn,
      chat: chat,
      c2: bot
    } do
      {:ok, message} = Messages.create_generating_message(chat, bot.id)
      [body] = message.bodies
      Messages.save_streamed_body(body, "", "Pondering")

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      assert has_element?(view, "#reasoning-#{message.id}[open]")

      Messages.broadcast_body_delta(chat.id, message.id, body.id, "Hi", "Pondering")

      eventually(fn ->
        refute has_element?(view, "#reasoning-#{message.id}[open]")
        assert has_element?(view, "#messages-#{message.id}", "Hi")
      end)

      assert has_element?(view, "#reasoning-#{message.id}", "Pondering")
    end

    test "the reasoning shown is the redacted one unless the viewer holds site.hidden.view", %{
      conn: conn,
      user: user,
      chat: chat,
      c2: bot
    } do
      Mythweaver.Permissions.put_grant!(user, "site.hidden.view", :deny)
      {:ok, message} = Messages.create_generating_message(chat, bot.id)
      [body] = message.bodies
      Messages.save_streamed_body(body, "", "Pondering Zanzibar", "Pondering (hidden)")

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      assert has_element?(view, "#reasoning-#{message.id}", "Pondering (hidden)")

      Messages.broadcast_body_delta(chat.id, message.id, body.id, "Hi", "Musing Zanzibar", "Musing (hidden)")
      eventually(fn -> assert has_element?(view, "#reasoning-#{message.id}", "Musing (hidden)") end)
      refute render(view) =~ "Zanzibar"

      Mythweaver.Permissions.put_grant!(user, "site.hidden.view", :allow)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      assert has_element?(view, "#reasoning-#{message.id}", "Pondering Zanzibar")

      Messages.broadcast_body_delta(chat.id, message.id, body.id, "Hi", "Musing Zanzibar", "Musing (hidden)")
      eventually(fn -> assert has_element?(view, "#reasoning-#{message.id}", "Musing Zanzibar") end)
    end

    test "a streaming reply renders open markdown closed, with the in-flight cursor", %{
      conn: conn,
      chat: chat,
      c2: bot
    } do
      {:ok, message} = Messages.create_generating_message(chat, bot.id)
      [body] = message.bodies
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      Messages.broadcast_body_delta(chat.id, message.id, body.id, ~s(She says "**hel), "")

      eventually(fn ->
        assert has_element?(view, "#message-body-#{message.id} strong", "hel")
        assert has_element?(view, "#message-body-#{message.id} .md-caret")
      end)
    end

    test "a streamed token costs the chat view no queries", %{conn: conn, chat: chat, c2: bot} do
      {:ok, message} = Messages.create_generating_message(chat, bot.id)
      [body] = message.bodies
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      # The first frame seeds the view's streaming cache with one `get_message/2`.
      Messages.broadcast_body_delta(chat.id, message.id, body.id, "Once", "")
      eventually(fn -> assert has_element?(view, "#messages-#{message.id}", "Once") end)

      test = self()
      pid = view.pid
      handler = "view-queries-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:mythweaver, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if self() == pid, do: send(test, {:view_query, meta.source, meta.query})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      Messages.broadcast_body_delta(chat.id, message.id, body.id, "Once upon", "")
      eventually(fn -> assert has_element?(view, "#messages-#{message.id}", "Once upon") end)

      refute_receive {:view_query, _source, _query}, 50
    end

    test "a delta still pending at finish never repaints the finished reply", %{conn: conn, chat: chat, c2: bot} do
      {:ok, message} = Messages.create_generating_message(chat, bot.id)
      [body] = message.bodies
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      Messages.broadcast_body_delta(chat.id, message.id, body.id, "Once", "")
      Messages.broadcast_body_delta(chat.id, message.id, body.id, "Once upon a stale", "")
      {:ok, _} = Messages.finalize_body(body, %{content: "Once upon a time"})
      Messages.broadcast_generation_finished(chat.id, message.id)
      send(view.pid, :close_body_delta_frame)

      eventually(fn -> assert has_element?(view, "#messages-#{message.id}", "Once upon a time") end)
      refute has_element?(view, "#messages-#{message.id}", "stale")
    end

    test "a watching tab sees the reply too", %{conn: conn, chat: chat, c2: bot, user: user} do
      stub_chat_stream()
      participant = bot_participant(chat.id, bot)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      {:ok, watcher, _html} = live(log_in_user(build_conn(), user), ~p"/chats/#{chat.id}")

      render_click(element(view, "#generate-#{participant.id}"))

      eventually(fn -> assert render(watcher) =~ "pong" end)
    end

    test "reply actions appear once the reply finishes, without a reload", %{
      conn: conn,
      chat: chat,
      c2: bot
    } do
      stub_chat_stream()
      participant = bot_participant(chat.id, bot)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_click(element(view, "#generate-#{participant.id}"))

      eventually(fn -> assert render(view) =~ "pong" end)
      generated = chat |> Messages.list_messages() |> List.last()

      eventually(fn -> assert has_element?(view, "#messages[data-generating='false']") end)
      assert has_element?(view, "#regenerate-#{generated.id}")
      assert has_element?(view, "#continue-#{generated.id}")
    end

    test "the footer shows costs rounded up to the cent and the generation time", %{conn: conn, chat: chat, c2: bot} do
      finished = fn attrs ->
        {:ok, message} = Messages.create_generating_message(chat, bot.id)
        {:ok, _} = Messages.finalize_body(hd(message.bodies), Map.put(attrs, :content, "Hi"))
        message
      end

      estimated = finished.(%{cost: Decimal.new("0.0323"), cost_estimated: true, generation_ms: 1500})
      tiny = finished.(%{cost: Decimal.new("0.0099")})
      dollars = finished.(%{cost: Decimal.new("1.2301")})
      free = finished.(%{cost: Decimal.new("0")})

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      assert has_element?(view, "#messages-#{estimated.id} .chat-message-stats", "≈$0.04")
      assert has_element?(view, "#messages-#{estimated.id} .chat-message-stats", "1.5s")
      assert has_element?(view, "#messages-#{tiny.id} .chat-message-stats", "<$0.01")
      assert has_element?(view, "#messages-#{dollars.id} .chat-message-stats", "$1.24")
      assert has_element?(view, "#messages-#{free.id} .chat-message-stats", "$0.00")
    end

    test "the footer hides stats a message does not have", %{conn: conn, chat: chat, c2: bot} do
      finished = fn attrs ->
        {:ok, message} = Messages.create_generating_message(chat, bot.id)
        {:ok, _} = Messages.finalize_body(hd(message.bodies), Map.put(attrs, :content, "Hi"))
        message
      end

      timed = finished.(%{generation_ms: 1500})
      bare = finished.(%{})

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      assert has_element?(view, "#messages-#{timed.id} .chat-message-stat", "Time")
      refute has_element?(view, "#messages-#{timed.id} .chat-message-stat", "Tokens")
      refute has_element?(view, "#messages-#{timed.id} .chat-message-stat", "Cost")
      refute has_element?(view, "#messages-#{timed.id} .chat-message-stats", "—")
      refute has_element?(view, "#messages-#{bare.id} .chat-message-stats")
    end

    test "regenerate adds a second, active body", %{scope: scope, conn: conn, chat: chat, c1: author} do
      stub_chat_stream()
      message = chat |> Messages.list_messages() |> List.first()

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_click(element(view, "#regenerate-#{message.id}"))

      eventually(fn -> assert render(view) =~ "pong" end)

      reloaded = Messages.get_message!(scope, message.id)
      assert reloaded.author_character_id == author.id
      assert length(reloaded.bodies) == 2
      assert Enum.find(reloaded.bodies, & &1.active).content == "pong"
      assert has_element?(view, ".chat-message-swipe-count", "2 / 2")
    end

    test "continue adds a swipe holding the original text plus the continuation", %{
      scope: scope,
      conn: conn,
      chat: chat
    } do
      stub_chat_stream()
      message = chat |> Messages.list_messages() |> List.first()

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_click(element(view, "#continue-#{message.id}"))

      eventually(fn -> assert has_element?(view, ".chat-message-swipe-count", "2 / 2") end)

      eventually(fn ->
        assert Enum.find(Messages.get_message!(scope, message.id).bodies, & &1.active).generating == false
      end)

      assert Enum.find(Messages.get_message!(scope, message.id).bodies, & &1.active).content == "Hello there pong"
    end

    test "regenerating or continuing an earlier message is refused", %{scope: scope, conn: conn, chat: chat, c2: bot} do
      first = chat |> Messages.list_messages() |> List.first()
      add_message(chat, bot, "Later")

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      for action <- ~w[regenerate continue] do
        render_click(element(view, "##{action}-#{first.id}"))
        assert has_element?(view, "#flash-error")
      end

      assert [_] = Messages.get_message!(scope, first.id).bodies
    end

    test "a backend failing before any text drops the reply and flashes the error", %{
      conn: conn,
      chat: chat,
      c2: bot
    } do
      Req.Test.stub(Mythweaver.AI, &Plug.Conn.send_resp(&1, 500, "boom"))
      participant = bot_participant(chat.id, bot)
      before = Messages.list_messages(chat)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_click(element(view, "#generate-#{participant.id}"))

      eventually(fn -> assert has_element?(view, "#flash-error", "HTTP 500") end)
      refute has_element?(view, ".chat-message-error")
      assert length(Messages.list_messages(chat)) == length(before)
    end

    test "the per-participant settings (model and talkativeness) are saved and shown", %{
      scope: scope,
      conn: conn,
      chat: chat,
      c2: bot
    } do
      participant = bot_participant(chat.id, bot)
      {:ok, other} = AI.create_model(scope, %{name: "Qwen 3", api_model_id: "qwen-3"})

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      refute has_element?(view, "#participant-model-#{participant.id}")

      render_click(element(view, "#edit-connection-#{participant.id}"))
      assert has_element?(view, "#participant-settings-form[phx-hook='UnsavedChanges'][data-saved]")

      render_submit(element(view, "#participant-settings-form"), %{
        "participant_id" => participant.id,
        "ai_model_id" => other.id,
        "talkativeness" => "0.8"
      })

      saved = Chats.get_participant(participant.id)
      assert saved.ai_model_id == other.id
      assert saved.talkativeness == 0.8
      assert has_element?(view, "#participant-model-#{participant.id}", "Qwen 3")
      refute has_element?(view, "#participant-settings-form")
    end

    test "a participant model equal to the chat's model is not shown", %{
      scope: scope,
      conn: conn,
      chat: chat,
      c2: bot
    } do
      participant = bot_participant(chat.id, bot)
      {:ok, model} = AI.create_model(scope, %{name: "Qwen 3", api_model_id: "qwen-3"})
      {:ok, _} = Chats.update_chat(scope, chat, %{ai_model_id: model.id})
      {:ok, _} = Chats.update_participant(scope, participant, %{ai_model_id: model.id})

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      refute has_element?(view, "#participant-model-#{participant.id}")
    end

    test "a player message triggers the chat's reply strategy", %{scope: scope, conn: conn, chat: chat} do
      stub_chat_stream()
      {:ok, _} = Chats.update_chat(scope, chat, %{reply_strategy: :list})

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_submit(element(view, "#message-composer"), %{"composer" => %{"content" => "hi"}})

      eventually(fn -> assert render(view) =~ "pong" end)
      Mythweaver.Generation.cancel(scope, chat)
    end

    test "auto mode toggles and the queue popup opens empty", %{scope: scope, conn: conn, chat: chat} do
      # Hangs, so an auto tick cannot finish a reply before the cancel below.
      Req.Test.stub(Mythweaver.AI, fn conn ->
        Process.sleep(:infinity)
        conn
      end)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_click(element(view, "#auto-mode-toggle"))
      eventually(fn -> assert has_element?(view, ~s(#auto-mode-toggle[aria-pressed="true"])) end)

      render_click(element(view, "#queue-button"))
      assert has_element?(view, "#turn-queue-modal")
      assert has_element?(view, "#turn-queue-empty")

      assert Mythweaver.Generation.cancel(scope, chat) == :ok
      eventually(fn -> assert has_element?(view, ~s(#auto-mode-toggle[aria-pressed="false"])) end)
    end

    test "the header's Stop button stops the reply and pauses the queue", %{
      scope: scope,
      conn: conn,
      chat: chat,
      c2: bot
    } do
      test = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        send(test, :request_hanging)
        Process.sleep(:infinity)
        conn
      end)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      refute has_element?(view, "#stop-generation")

      # Not the sparkle twice: while the bot speaks, that button is its Stop.
      assert :ok = Mythweaver.Generation.generate(scope, Chats.get_chat!(chat.id), bot)
      assert :ok = Mythweaver.Generation.generate(scope, Chats.get_chat!(chat.id), bot)
      assert_receive :request_hanging
      eventually(fn -> assert has_element?(view, "#stop-generation") end)
      eventually(fn -> assert has_element?(view, "[id^='chat-reply-progress-'][data-status='running']") end)

      render_click(element(view, "#stop-generation"))

      eventually(fn ->
        refute has_element?(view, "#stop-generation")
        assert has_element?(view, "#resume-queue")
        refute has_element?(view, "[id^='chat-reply-progress-']")
      end)

      assert %{queue: [_], paused?: true} = Mythweaver.Generation.status(scope, chat)

      render_click(element(view, "#resume-queue"))
      assert_receive :request_hanging
      eventually(fn -> assert has_element?(view, "#stop-generation") end)

      assert Mythweaver.Generation.cancel(scope, chat) == :ok
    end

    test "deleting the chat mid-reply leaves every view on it running", %{scope: scope, conn: conn, chat: chat, c2: bot} do
      test = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        send(test, :request_hanging)
        Process.sleep(:infinity)
        conn
      end)

      {:ok, deleter, _html} = live(conn, ~p"/chats/#{chat.id}/settings")
      {:ok, watcher, _html} = live(conn, ~p"/chats/#{chat.id}")
      refs = Enum.map([deleter, watcher], &Process.monitor(&1.pid))

      assert :ok = Mythweaver.Generation.generate(scope, Chats.get_chat!(chat.id), bot)
      assert_receive :request_hanging
      eventually(fn -> assert has_element?(watcher, "#stop-generation") end)

      deleter |> element("#chat-settings-delete") |> render_click()

      for ref <- refs, do: refute_receive({:DOWN, ^ref, _, _, _}, 200)
    end

    test "a generating character shows as typing in every tab until the reply ends",
         %{scope: scope, conn: conn, chat: chat, c2: bot} do
      test = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        send(test, :request_hanging)
        Process.sleep(:infinity)
        conn
      end)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      {:ok, watcher, _html} = live(conn, ~p"/chats/#{chat.id}")

      assert :ok = Mythweaver.Generation.generate(scope, Chats.get_chat!(chat.id), bot)
      assert_receive :request_hanging

      eventually(fn ->
        assert has_element?(view, ".chat-typing-indicator", "Bob is typing")
        assert has_element?(view, ".chat-typing-indicator #chat-typing-ai")
        assert has_element?(watcher, ".chat-typing-indicator", "Bob is typing")
        assert has_element?(watcher, ".chat-typing-indicator #chat-typing-ai")
      end)

      # A player typing elsewhere joins the speaker rather than replacing it.
      render_hook(element(view, "#message-composer-row"), "typing")
      assert has_element?(watcher, ".chat-typing-indicator", "Alice and Bob are typing")

      assert Mythweaver.Generation.cancel(scope, chat) == :ok

      eventually(fn ->
        refute has_element?(view, ".chat-typing-indicator")
        refute has_element?(watcher, ".chat-typing-indicator", "Bob")
        refute has_element?(watcher, "#chat-typing-ai")
      end)
    end
  end

  describe "guided generations" do
    setup context do
      Req.Test.set_req_test_to_shared(context)
      generation_setup(context.scope, "Be brief. {{ anchors.guide.text }}{{ anchors.refine.instructions }}")
      stub_chat_stream()
      :ok
    end

    defp type_guide(view, text) do
      render_change(element(view, "#message-composer"), %{composer: %{content: text}})
    end

    defp newest_active_body(chat) do
      chat |> Messages.list_messages() |> List.last() |> Map.fetch!(:bodies) |> Enum.find(& &1.active)
    end

    test "composer text guides a sparkle reply, then joins input history and leaves the composer",
         %{scope: scope, conn: conn, chat: chat, c2: bot} do
      participant = bot_participant(chat.id, bot)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      refute has_element?(view, "#composer-guide-hint")
      type_guide(view, "Tom sits down.")
      assert has_element?(view, "#composer-guide-hint")

      render_click(element(view, "#generate-#{participant.id}"))
      eventually(fn -> assert %{generating: false, content: "pong"} = newest_active_body(chat) end)

      assert newest_active_body(chat).guide == "Tom sits down."
      assert_push_event(view, "composer_guided", %{content: "Tom sits down."})
      refute has_element?(view, "#composer-guide-hint")
      assert Messages.draft_content(scope, chat) == ""
    end

    test "an empty composer sends no guide", %{conn: conn, chat: chat, c2: bot} do
      participant = bot_participant(chat.id, bot)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      type_guide(view, "   ")
      refute has_element?(view, "#composer-guide-hint")

      render_click(element(view, "#generate-#{participant.id}"))
      eventually(fn -> assert %{generating: false, content: "pong"} = newest_active_body(chat) end)

      assert newest_active_body(chat).guide == nil
      refute_push_event(view, "composer_guided", %{})
    end

    test "a guided regenerate shows its guide in the swipe inspector", %{conn: conn, chat: chat} do
      message = chat |> Messages.list_messages() |> List.first()
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      type_guide(view, "Shorter.")
      render_click(element(view, "#regenerate-#{message.id}"))
      eventually(fn -> assert %{generating: false, content: "pong"} = newest_active_body(chat) end)

      body = newest_active_body(chat)
      assert %{origin: :regenerate, guide: "Shorter."} = body

      eventually(fn -> assert has_element?(view, "#swipe-history-#{message.id}") end)
      render_click(element(view, "#swipe-history-#{message.id}"))
      assert has_element?(view, "#swipe-guide-#{body.id}", "Shorter.")
    end

    test "a staged audio clip guides a regenerate, leaves the composer and shows in the swipe inspector",
         %{conn: conn, chat: chat} do
      message = chat |> Messages.list_messages() |> List.first()
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      view
      |> file_input("#message-composer", :composer_files, [
        %{name: "howl.mp3", content: "ID3" <> <<4, 0, 0, 0, 0, 0>>, type: "audio/mpeg"}
      ])
      |> render_upload("howl.mp3")

      assert has_element?(view, "#composer-guide-hint")

      render_click(element(view, "#regenerate-#{message.id}"))
      eventually(fn -> assert %{generating: false, content: "pong"} = newest_active_body(chat) end)

      body = newest_active_body(chat)
      assert [%{kind: :audio, filename: "howl.mp3", id: clip_id}] = body.guide_attachments
      refute has_element?(view, "#composer-attachments")

      eventually(fn -> assert has_element?(view, "#swipe-history-#{message.id}") end)
      render_click(element(view, "#swipe-history-#{message.id}"))
      assert has_element?(view, "#swipe-guide-file-#{body.id}-#{clip_id}", "howl.mp3")
    end

    test "the refine button rewrites the last reply with the composer text", %{conn: conn, chat: chat} do
      message = chat |> Messages.list_messages() |> List.first()
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      type_guide(view, "Make it rhyme.")
      render_click(element(view, "#refine-#{message.id}"))
      eventually(fn -> assert %{generating: false, content: "pong"} = newest_active_body(chat) end)

      assert %{origin: :refine, guide: "Make it rhyme."} = newest_active_body(chat)
      assert_push_event(view, "composer_guided", %{content: "Make it rhyme."})
      assert [%{tag: :refine}] = Mythweaver.Repo.all(Job)
    end

    test "the refine button with an empty composer flashes and adds no swipe", %{scope: scope, conn: conn, chat: chat} do
      message = chat |> Messages.list_messages() |> List.first()
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_click(element(view, "#refine-#{message.id}"))

      assert has_element?(view, "#flash-error", "Type editing instructions")
      assert [_] = Messages.get_message!(scope, message.id).bodies
    end

    defp open_annotation(view, message, text, s, e) do
      render_hook(element(view, "#clip-selection"), "open_annotation", %{
        "message_id" => message.id,
        "text" => text,
        "start" => s,
        "end" => e
      })
    end

    # Submits the popup as the browser does: the clicked button's name and value ride along.
    defp annotate(view, note, button) do
      view
      |> form("#annotation-form", annotation: %{note: note})
      |> put_submitter("#annotation-#{button}")
      |> render_submit()
    end

    test "annotations and the composer text rewrite the last reply", %{conn: conn, chat: chat} do
      message = chat |> Messages.list_messages() |> List.first()
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      open_annotation(view, message, "Hello", 0, 5)
      assert has_element?(view, "#annotation-popover")
      annotate(view, "", "quick-reject")
      assert has_element?(view, "#message-annotations-#{message.id} li[data-action=reject]")
      refute has_element?(view, "#annotation-popover")

      open_annotation(view, message, "there", 6, 11)
      annotate(view, "Make it warmer.", "save")
      assert has_element?(view, "#message-annotations-#{message.id} li[data-action=note]")

      type_guide(view, "Keep it short.")
      render_click(element(view, "#annotations-rewrite"))
      eventually(fn -> assert %{origin: :refine, generating: false} = newest_active_body(chat) end)

      assert newest_active_body(chat).guide ==
               "Notes on passages of the message, each quoted from it:\n\n" <>
                 "1. \"Hello\"\n   Remove this passage entirely. Do not replace it with something similar.\n\n" <>
                 "2. \"there\"\n   Note: Make it warmer.\n\n" <>
                 "General instructions:\nKeep it short."

      assert_push_event(view, "composer_guided", %{content: "Keep it short."})
      refute has_element?(view, "#message-annotations-#{message.id}")
    end

    test "a blank note is refused", %{conn: conn, chat: chat} do
      message = chat |> Messages.list_messages() |> List.first()
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      open_annotation(view, message, "Hello", 0, 5)
      annotate(view, "  ", "save")

      assert has_element?(view, "#annotation-error")
      assert has_element?(view, "#annotation-popover")
      refute has_element?(view, "#message-annotations-#{message.id}")
    end

    test "the popup's Rewrite saves its note and rewrites", %{conn: conn, chat: chat} do
      message = chat |> Messages.list_messages() |> List.first()
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      open_annotation(view, message, "Hello", 0, 5)
      annotate(view, "Shorter.", "rewrite")
      eventually(fn -> assert %{origin: :refine, generating: false} = newest_active_body(chat) end)

      assert newest_active_body(chat).guide ==
               "Notes on passages of the message, each quoted from it:\n\n1. \"Hello\"\n   Note: Shorter."

      refute has_element?(view, "#annotation-popover")
    end

    test "only the latest reply can be annotated", %{conn: conn, chat: chat, c2: c2} do
      message = chat |> Messages.list_messages() |> List.first()
      add_message(chat, c2, "Second")
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      open_annotation(view, message, "Hello", 0, 5)

      assert has_element?(view, "#flash-error", "Only the latest reply can be annotated.")
      refute has_element?(view, "#annotation-popover")
    end

    test "editing the message drops its notes", %{scope: scope, conn: conn, chat: chat} do
      message = chat |> Messages.list_messages() |> List.first()
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      open_annotation(view, message, "Hello", 0, 5)
      annotate(view, "", "quick-reject")
      assert has_element?(view, "#message-annotations-#{message.id}")

      {:ok, _} = Messages.add_edited_body(scope, message, %{content: "Changed"})
      render(view)

      refute has_element?(view, "#message-annotations-#{message.id}")
    end
  end

  describe "participant rail" do
    test "dragging reorders the rendered participants", %{conn: conn, chat: chat} do
      ids = Enum.map(Chats.get_chat!(chat.id).participants, & &1.id)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_hook(element(view, "#participants-list"), "reorder_participants", %{"ids" => Enum.reverse(ids)})

      rendered =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#participants-list > li")
        |> LazyHTML.attribute("data-id")

      assert rendered == Enum.reverse(ids)
    end

    test "the mute button toggles a participant's muted state", %{conn: conn, chat: chat, c2: bot} do
      participant = chat.id |> Chats.get_chat!() |> Map.fetch!(:participants) |> Enum.find(&(&1.character_id == bot.id))
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_click(element(view, "#mute-participant-#{participant.id}"))

      assert has_element?(view, ~s(#mute-participant-#{participant.id}[aria-pressed="true"]))
      assert Chats.get_participant(participant.id).muted
    end

    test "a mute in one tab shows in every other tab on the chat", %{conn: conn, chat: chat, c2: bot} do
      participant = chat.id |> Chats.get_chat!() |> Map.fetch!(:participants) |> Enum.find(&(&1.character_id == bot.id))
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      {:ok, other, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_click(element(view, "#mute-participant-#{participant.id}"))

      assert has_element?(other, ~s(#mute-participant-#{participant.id}[aria-pressed="true"]))
    end

    test "mute all toggles every bot, then unmutes them", %{conn: conn, chat: chat, c2: bot} do
      participant = chat.id |> Chats.get_chat!() |> Map.fetch!(:participants) |> Enum.find(&(&1.character_id == bot.id))
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_click(element(view, "#mute-all-participants"))
      assert has_element?(view, ~s(#mute-all-participants[aria-pressed="true"]))
      assert Chats.get_participant(participant.id).muted

      render_click(element(view, "#mute-all-participants"))
      assert has_element?(view, ~s(#mute-all-participants[aria-pressed="false"]))
      refute Chats.get_participant(participant.id).muted
    end

    test "mute all acts only on the characters the search shows", %{scope: scope, conn: conn, chat: chat, c2: bob} do
      carol = character(scope, "Carol")
      {:ok, _} = Chats.add_participants(scope, Chats.get_chat!(chat.id), [carol.id])
      :ok = Mythweaver.Tags.set_item_tags(scope, bob, :mine, ["series:zelda"])
      participants = Chats.get_chat!(chat.id).participants
      bob_p = Enum.find(participants, &(&1.character_id == bob.id))
      carol_p = Enum.find(participants, &(&1.character_id == carol.id))
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_click(element(view, "#participant-search-toggle"))
      render_change(element(view, "#participant-filter"), %{"query" => "", "tag_filter" => ["", "series:zelda"]})
      assert has_element?(view, ~s(#mute-all-participants[aria-label="Mute shown characters"]))

      render_click(element(view, "#mute-all-participants"))
      assert Chats.get_participant(bob_p.id).muted
      refute Chats.get_participant(carol_p.id).muted
      assert has_element?(view, ~s(#mute-all-participants[aria-pressed="true"]))

      render_click(element(view, "#mute-all-participants"))
      refute Chats.get_participant(bob_p.id).muted
      refute Chats.get_participant(carol_p.id).muted
    end

    test "mute all is disabled while the search shows no bot", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_click(element(view, "#participant-search-toggle"))
      render_change(element(view, "#participant-filter"), %{"query" => "Alice", "tag_filter" => [""]})

      assert has_element?(view, "#mute-all-participants[disabled]")
    end

    test "hide muted hides only muted rows and keeps drag reordering", %{conn: conn, chat: chat, c2: bot} do
      participants = Chats.get_chat!(chat.id).participants
      ids = Enum.map(participants, & &1.id)
      bot_p = Enum.find(participants, &(&1.character_id == bot.id))
      player_p = Enum.find(participants, &(&1.character_id == chat.player_character_id))
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_click(element(view, "#mute-participant-#{bot_p.id}"))
      render_click(element(view, "#hide-muted-participants"))
      assert_push_event(view, "hide_muted", %{hide: true})
      assert has_element?(view, "#participant-#{bot_p.id}[hidden]")
      refute has_element?(view, "#participant-#{player_p.id}[hidden]")

      render_hook(element(view, "#participants-list"), "reorder_participants", %{"ids" => Enum.reverse(ids)})

      rendered =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#participants-list > li")
        |> LazyHTML.attribute("data-id")

      assert rendered == Enum.reverse(ids)

      render_click(element(view, "#hide-muted-participants"))
      assert_push_event(view, "hide_muted", %{hide: false})
      refute has_element?(view, "#participants-list > li[hidden]")
    end

    test "the browser's stored hide-muted choice is restored and kept across chats",
         %{conn: conn, scope: scope, chat: chat, second_chat: second_chat, c2: bot} do
      [first, second] =
        for c <- [chat, second_chat] do
          participant = Enum.find(Chats.get_chat!(c.id).participants, &(&1.character_id == bot.id))
          {:ok, muted} = Chats.update_participant(scope, participant, %{muted: true})
          muted
        end

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      assert has_element?(view, ~s(#chat-participants[phx-hook][data-hide-muted="false"]))
      refute has_element?(view, "#participant-#{first.id}[hidden]")

      render_hook(element(view, "#chat-participants"), "set_hide_muted", %{"hide" => true})
      assert_push_event(view, "hide_muted", %{hide: true})
      assert has_element?(view, "#participant-#{first.id}[hidden]")
      assert has_element?(view, ~s(#hide-muted-participants[aria-pressed="true"]))

      render_patch(view, ~p"/chats/#{second_chat.id}")
      assert has_element?(view, ~s(#chat-participants[data-hide-muted="true"]))
      assert has_element?(view, "#participant-#{second.id}[hidden]")
    end

    test "search filters rows by name and tag, under hide-muted, and closing it clears the filter",
         %{conn: conn, scope: scope, chat: chat, c1: alice, c2: bob} do
      participants = Chats.get_chat!(chat.id).participants
      alice_p = Enum.find(participants, &(&1.character_id == alice.id))
      bob_p = Enum.find(participants, &(&1.character_id == bob.id))
      {:ok, _} = Mythweaver.Tags.create_tag(scope, %{"text" => "character:samus", "parent_texts" => ["series:metroid"]})
      :ok = Mythweaver.Tags.set_item_tags(scope, alice, :mine, ["character:samus"])
      :ok = Mythweaver.Tags.set_item_tags(scope, bob, :mine, ["series:zelda"])
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      refute has_element?(view, "#participant-filter")

      render_click(element(view, "#participant-search-toggle"))
      filter = &render_change(element(view, "#participant-filter"), %{"query" => &1, "tag_filter" => ["" | &2]})

      # A parent implied through a tag counts, as in the lists' tag filters.
      filter.("", ["series:metroid"])
      refute has_element?(view, "#participant-#{alice_p.id}[hidden]")
      assert has_element?(view, "#participant-#{bob_p.id}[hidden]")

      filter.("BO", [])
      assert has_element?(view, "#participant-#{alice_p.id}[hidden]")
      refute has_element?(view, "#participant-#{bob_p.id}[hidden]")

      # Bob matches, but hide-muted still hides him.
      render_click(element(view, "#mute-participant-#{bob_p.id}"))
      render_click(element(view, "#hide-muted-participants"))
      filter.("", ["-series:metroid"])
      assert has_element?(view, "#participant-#{bob_p.id}[hidden]")
      assert has_element?(view, "#participant-#{alice_p.id}[hidden]")
      assert has_element?(view, "#participants-no-match")

      # A character added while filtering is matched against its own tags.
      carol = character(scope, "Carol")
      :ok = Mythweaver.Tags.set_item_tags(scope, carol, :mine, ["series:zelda"])
      render_click(view, "open_add_participant", %{})
      render_submit(element(view, "#add-participant-form"), %{"character_ids" => [carol.id]})
      carol_p = Enum.find(Chats.get_chat!(chat.id).participants, &(&1.character_id == carol.id))
      refute has_element?(view, "#participant-#{carol_p.id}[hidden]")

      render_click(element(view, "#participant-search-toggle"))
      refute has_element?(view, "#participant-filter")
      refute has_element?(view, "#participant-#{alice_p.id}[hidden]")
      assert has_element?(view, "#participant-#{bob_p.id}[hidden]")
    end

    test "the add modal keeps its checked characters across a search",
         %{conn: conn, scope: scope, chat: chat} do
      dora = character(scope, "Dora")
      eve = character(scope, "Eve")
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      render_click(view, "open_add_participant", %{})

      view |> form("#add-participant-form", %{"character_ids" => [dora.id]}) |> render_change()

      render_change(element(view, "#add-participant-characters-query"), %{
        "add-participant-characters" => %{"query" => "eve"}
      })

      assert has_element?(view, "#add-participant-characters-#{dora.id}[checked]")

      render_submit(form(view, "#add-participant-form"))

      ids = Enum.map(Chats.get_chat!(chat.id).participants, & &1.character_id)
      assert dora.id in ids
      refute eve.id in ids
    end
  end

  describe "message edit, visibility, and delete" do
    defp only_message(chat) do
      [message] = Messages.list_messages(chat)
      message
    end

    defp swipe_contents(scope, id), do: Enum.map(Messages.get_message!(scope, id).bodies, & &1.content)

    defp open_edit(view, id), do: render_click(element(view, "#message-edit-#{id}"))

    defp submit_edit(view, id, content) do
      render_submit(element(view, "#message-edit-form-#{id}"), %{message_body: %{content: content}})
    end

    test "edit saves the text as a new active swipe", %{scope: scope, conn: conn, chat: chat} do
      %{id: id} = message = only_message(chat)
      {:ok, _} = Messages.add_body(message, %{content: "swipe two"})
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      open_edit(view, id)
      assert has_element?(view, "#message-edit-form-content-#{id}", "swipe two")

      submit_edit(view, id, "edited two")

      refute has_element?(view, "#message-edit-form-#{id}")
      assert has_element?(view, "#messages-#{id}", "edited two")
      assert has_element?(view, "#messages-#{id} .chat-message-swipe-count", "3 / 3")
      assert swipe_contents(scope, id) == ["Hello there", "swipe two", "edited two"]
    end

    test "editing a single-body player message adds a second swipe", %{scope: scope, conn: conn, chat: chat} do
      %{id: id} = only_message(chat)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      open_edit(view, id)
      submit_edit(view, id, "Hello again")

      assert has_element?(view, "#messages-#{id} .chat-message-swipe-count", "2 / 2")
      assert swipe_contents(scope, id) == ["Hello there", "Hello again"]
    end

    test "Save edits overwrites the shown swipe instead of adding one",
         %{scope: scope, conn: conn, chat: chat} do
      %{id: id} = message = only_message(chat)
      {:ok, _} = Messages.add_body(message, %{content: "swipe two"})
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      open_edit(view, id)

      view
      |> form("#message-edit-form-#{id}", %{message_body: %{content: "swipe two, fixed"}})
      |> put_submitter("#message-edit-in-place-#{id}")
      |> render_submit()

      refute has_element?(view, "#message-edit-form-#{id}")
      assert has_element?(view, "#messages-#{id} .chat-message-swipe-count", "2 / 2")
      assert swipe_contents(scope, id) == ["Hello there", "swipe two, fixed"]
    end

    test "the avatar column takes its cap from the appearance.avatar_max_* settings",
         %{scope: scope, conn: conn, chat: chat} do
      :ok = Settings.put(scope, :user, "appearance.avatar_max_width", 200)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      assert has_element?(view, "#chat-messages[style*='--avatar-max-w: 200px']")
      assert has_element?(view, "#chat-messages[style*='--avatar-max-h: 400px']")
    end

    test "an edited body renders as markdown", %{conn: conn, chat: chat} do
      %{id: id} = only_message(chat)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      open_edit(view, id)
      submit_edit(view, id, ~s(*waves* "Hi"))

      assert has_element?(view, "#message-body-#{id} em", "waves")
      assert has_element?(view, "#message-body-#{id} .md-dialogue", ~s("Hi"))
    end

    test "double-clicking the body opens the editor at the clicked offset", %{
      conn: conn,
      chat: chat
    } do
      %{id: id} = only_message(chat)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_hook(element(view, "#message-body-#{id}"), "edit_message", %{
        "message_id" => id,
        "caret" => 3
      })

      assert has_element?(view, "#message-edit-form-content-#{id}[data-caret='3']", "Hello there")
      refute has_element?(view, "#message-edit-form-content-#{id}[data-caret-end]")
    end

    test "double-clicking with text selected opens the editor with that text selected", %{
      conn: conn,
      chat: chat
    } do
      %{id: id} = only_message(chat)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_hook(element(view, "#message-body-#{id}"), "edit_message", %{
        "message_id" => id,
        "selection" => [6, 11]
      })

      assert has_element?(view, "#message-edit-form-content-#{id}[data-caret='6'][data-caret-end='11']")
    end

    test "an empty or reversed selection opens the editor without an offset", %{conn: conn, chat: chat} do
      %{id: id} = only_message(chat)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_hook(element(view, "#message-body-#{id}"), "edit_message", %{
        "message_id" => id,
        "selection" => [5, 5]
      })

      assert has_element?(view, "#message-edit-form-content-#{id}")
      refute has_element?(view, "#message-edit-form-content-#{id}[data-caret]")
    end

    test "the edit button opens the editor with no caret offset", %{conn: conn, chat: chat} do
      %{id: id} = only_message(chat)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      open_edit(view, id)

      assert has_element?(view, "#message-edit-form-content-#{id}")
      refute has_element?(view, "#message-edit-form-content-#{id}[data-caret]")
    end

    test "a non-integer caret opens the editor without an offset", %{conn: conn, chat: chat} do
      %{id: id} = only_message(chat)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_hook(element(view, "#message-body-#{id}"), "edit_message", %{
        "message_id" => id,
        "caret" => "x"
      })

      assert has_element?(view, "#message-edit-form-content-#{id}")
      refute has_element?(view, "#message-edit-form-content-#{id}[data-caret]")
    end

    test "saving unchanged text closes the form without a new swipe", %{scope: scope, conn: conn, chat: chat} do
      %{id: id} = only_message(chat)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      open_edit(view, id)
      submit_edit(view, id, "Hello there")

      refute has_element?(view, "#message-edit-form-#{id}")
      assert swipe_contents(scope, id) == ["Hello there"]
    end

    test "cancel restores the body", %{conn: conn, chat: chat} do
      %{id: id} = only_message(chat)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      open_edit(view, id)
      refute has_element?(view, "#messages-#{id} .chat-message-body")

      render_click(element(view, "#message-edit-cancel-#{id}"))

      refute has_element?(view, "#message-edit-form-#{id}")
      assert has_element?(view, "#messages-#{id} .chat-message-body", "Hello there")
    end

    test "blank save keeps the form open and adds no swipe", %{scope: scope, conn: conn, chat: chat} do
      %{id: id} = only_message(chat)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      open_edit(view, id)
      submit_edit(view, id, "")

      assert has_element?(view, "#message-edit-form-#{id}")
      assert swipe_contents(scope, id) == ["Hello there"]
    end

    test "delete removes the message behind a confirm", %{scope: scope, conn: conn, chat: chat} do
      %{id: id} = only_message(chat)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_click(element(view, "#message-delete-#{id}"))
      assert has_element?(view, "#delete-confirm-modal")
      assert Messages.get_message(scope, id)
      render_click(element(view, "#delete-confirm"))

      refute has_element?(view, "#delete-confirm-modal")
      refute has_element?(view, "#messages-#{id}")
      assert Messages.get_message(scope, id) == nil
      assert has_element?(view, ".chat-messages-empty")
    end

    test "the delete dialog lists the memory a deletion rolls back", %{scope: scope, conn: conn, chat: chat, c2: c2} do
      second = add_message(chat, c2, "Second")
      add_message(chat, c2, "Third")
      :ok = Mythweaver.Settings.put(scope, :site, "memory.rollback_enabled", true)
      book = Memory.ensure_book(scope, Chats.get_chat!(chat.id))
      {:ok, entry} = Lore.create_entry(scope, %{name: "[001] - The inn", content: "Met.", keywords: ["inn"]}, [book.id])

      Mythweaver.Repo.insert!(%Mythweaver.Memory.Record{
        lore_entry_id: entry.id,
        lore_book_id: book.id,
        chat_id: chat.id,
        kind: :memory,
        tier: 0,
        sequence: 1,
        range_start: 0,
        range_end: 2
      })

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      render_click(element(view, "#message-delete-#{second.id}"))

      assert has_element?(view, "#delete-confirm-memories", "[001] - The inn")
      render_click(element(view, "#delete-cancel"))
      refute has_element?(view, "#delete-confirm-modal")
      assert Messages.get_message(scope, second.id)
    end

    test "the eye button hides the message from the AI and shows it again", %{scope: scope, conn: conn, chat: chat} do
      %{id: id} = only_message(chat)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      assert has_element?(view, "#message-visibility-#{id}[aria-pressed='false']")
      render_click(element(view, "#message-visibility-#{id}"))

      assert has_element?(view, "#messages-#{id}.chat-message-hidden")
      assert has_element?(view, "#message-visibility-#{id}[aria-pressed='true']")
      refute Messages.get_message!(scope, id).visible_to_ai

      render_click(element(view, "#message-visibility-#{id}"))

      refute has_element?(view, "#messages-#{id}.chat-message-hidden")
      assert Messages.get_message!(scope, id).visible_to_ai
    end

    test "the author picker renames the author in every tab without adding a swipe", %{
      scope: scope,
      conn: conn,
      chat: chat
    } do
      %{id: id} = only_message(chat)
      swipes = length(Messages.get_message!(scope, id).bodies)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      {:ok, other, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_click(element(view, "#message-reattribute-#{id}"))
      refute has_element?(view, "#message-reattribute-name-#{id}")

      render_change(element(view, "#message-reattribute-form-#{id}"), %{reattribute: %{author: "other", name: ""}})
      assert has_element?(view, "#message-reattribute-name-#{id}")

      render_submit(element(view, "#message-reattribute-form-#{id}"), %{
        reattribute: %{author: "other", name: "Narrator"}
      })

      refute has_element?(view, "#message-reattribute-form-#{id}")
      assert has_element?(view, "#messages-#{id} .chat-message-author", "Narrator")
      assert has_element?(other, "#messages-#{id} .chat-message-author", "Narrator")
      assert length(Messages.get_message!(scope, id).bodies) == swipes
    end

    test "the expression picker shows the picked sprite in place of the portrait", %{
      scope: scope,
      conn: conn,
      chat: chat,
      c1: c1
    } do
      %{id: id} = only_message(chat)
      {:ok, attachment} = Mythweaver.Attachments.store_binary(png(), filename: "joy.png")
      {:ok, _} = Mythweaver.Expressions.add_sprites(scope, c1, nil, [{"joy", attachment}])
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      refute has_element?(view, "#messages-#{id} .chat-message-sprite")

      render_click(element(view, "#message-expression-#{id}"))
      assert has_element?(view, "#message-expression-select-#{id} option[value='joy']")

      render_submit(element(view, "#message-expression-form-#{id}"), %{message_id: id, expression: "joy"})

      refute has_element?(view, "#message-expression-form-#{id}")
      assert has_element?(view, "#messages-#{id} .chat-message-sprite img")
      assert %{expression: "joy", expression_source: :manual} = Message.active_body(Messages.get_message!(scope, id))

      # "Classify again" needs a classifier model.
      render_click(element(view, "#message-expression-#{id}"))
      assert render_click(element(view, "#message-expression-reclassify-#{id}")) =~ "Set a classifier model"
    end

    test "a classified message shows its emotion breakdown, strongest first, in the aside and the phone details",
         %{scope: scope, conn: conn, chat: chat} do
      %{id: id} = only_message(chat)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      refute has_element?(view, "#message-emotions-#{id}-toggle")

      body = Message.active_body(Messages.get_message!(scope, id))

      {:ok, _} =
        body
        |> MessageBody.expression_changeset(%{
          expression: "elated",
          expression_scores: %{"joy" => 83, "excitement" => 81, "anger" => 0, "sadness" => 2},
          expression_source: :classified
        })
        |> Mythweaver.Repo.update()

      Messages.broadcast_message_updated(chat.id, Messages.get_message!(scope, id))

      for popover <- ["message-emotions-#{id}", "message-details-emotions-#{id}"] do
        assert has_element?(view, "##{popover}-toggle[popovertarget='#{popover}'][interestfor='#{popover}']")
        assert has_element?(view, "##{popover}[popover] strong", "elated")
      end

      labels =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#message-emotions-#{id} li > span:first-child")
        |> Enum.map(&LazyHTML.text/1)

      assert labels == ["joy", "excitement", "sadness"]
    end

    test "a message id from another chat is ignored", %{scope: scope, conn: conn, chat: chat, second_chat: second_chat} do
      [other] = Messages.list_messages(second_chat)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_hook(view, "delete_message", %{"message_id" => other.id})
      render_hook(view, "toggle_message_visibility", %{"message_id" => other.id})

      assert %{visible_to_ai: true} = Messages.get_message(scope, other.id)
    end
  end

  describe "bulk selection" do
    setup %{chat: chat, c2: c2} do
      [first] = Messages.list_messages(chat)
      second = add_message(chat, c2, "Second")
      %{first: first, second: second}
    end

    defp select_messages(view, messages) do
      Enum.each(messages, &render_click(element(view, "#message-select-#{&1.id}")))
    end

    test "checking a message shows the panel; unchecking the last hides it", %{
      conn: conn,
      chat: chat,
      first: first
    } do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      refute has_element?(view, "#message-bulk-actions")

      select_messages(view, [first])
      assert has_element?(view, "#message-bulk-actions")

      select_messages(view, [first])
      refute has_element?(view, "#message-bulk-actions")
    end

    test "a shift-click range adds its loaded rows to the selection", %{
      conn: conn,
      chat: chat,
      c2: c2,
      first: m1,
      second: m2
    } do
      [m3, m4, m5] = for n <- 3..5, do: add_message(chat, c2, "Message #{n}")
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      select_messages(view, [m5])

      # Rows already selected stay so, and an id the chat does not hold is ignored.
      render_hook(view, "select_message_range", %{
        "ids" => [m2.id, m3.id, m4.id, m5.id, Mythweaver.Schema.generate_id()]
      })

      assert has_element?(view, ".chat-bulk-count", "4 selected")
      assert has_element?(view, "#message-select-#{m3.id}[checked]")
      refute has_element?(view, "#message-select-#{m1.id}[checked]")
    end

    test "the hide button hides a mixed selection, then shows it again", %{
      scope: scope,
      conn: conn,
      chat: chat,
      first: first,
      second: second
    } do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      select_messages(view, [first, second])
      assert has_element?(view, "#bulk-toggle-visibility[aria-pressed='false']")

      {:ok, _} = Messages.set_visible_to_ai(scope, first, false)
      assert has_element?(view, "#bulk-toggle-visibility[aria-pressed='mixed']")

      render_click(element(view, "#bulk-toggle-visibility"))

      for m <- [first, second] do
        assert has_element?(view, "#messages-#{m.id}.chat-message-hidden")
        refute Messages.get_message!(scope, m.id).visible_to_ai
      end

      assert has_element?(view, "#bulk-toggle-visibility[aria-pressed='true']")

      render_click(element(view, "#bulk-toggle-visibility"))

      for m <- [first, second] do
        refute has_element?(view, "#messages-#{m.id}.chat-message-hidden")
        assert Messages.get_message!(scope, m.id).visible_to_ai
      end

      assert has_element?(view, "#bulk-toggle-visibility[aria-pressed='false']")
    end

    test "delete removes every selected message behind a confirm", %{
      scope: scope,
      conn: conn,
      chat: chat,
      first: first,
      second: second
    } do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      select_messages(view, [first, second])

      render_click(element(view, "#bulk-delete-messages"))
      assert has_element?(view, "#delete-confirm-modal")
      render_click(element(view, "#delete-confirm"))

      for m <- [first, second] do
        refute has_element?(view, "#messages-#{m.id}")
        assert Messages.get_message(scope, m.id) == nil
      end

      refute has_element?(view, "#message-bulk-actions")
    end

    test "select all checks every message so bulk actions reach them all", %{
      scope: scope,
      conn: conn,
      chat: chat,
      first: first,
      second: second
    } do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      select_messages(view, [first])

      render_click(element(view, "#bulk-select-all"))
      assert has_element?(view, "#message-select-#{second.id}[checked]")

      render_click(element(view, "#bulk-toggle-visibility"))
      for m <- [first, second], do: refute(Messages.get_message!(scope, m.id).visible_to_ai)
    end

    test "cancel unchecks every row without touching the messages", %{
      scope: scope,
      conn: conn,
      chat: chat,
      first: first,
      second: second
    } do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      select_messages(view, [first, second])

      # Hiding re-renders the rows, so their boxes carry `checked` before the cancel.
      render_click(element(view, "#bulk-toggle-visibility"))
      for m <- [first, second], do: assert(has_element?(view, "#message-select-#{m.id}[checked]"))

      render_click(element(view, "#bulk-clear-selection"))

      refute has_element?(view, "#message-bulk-actions")

      for m <- [first, second] do
        refute has_element?(view, "#message-select-#{m.id}[checked]")
        refute Messages.get_message!(scope, m.id).visible_to_ai
      end
    end
  end

  describe "swipe inspector" do
    # The setup chat's only message, edited once: swipe #1 the original, #2 its active edit.
    defp edited_message(scope, chat) do
      [%{id: id}] = Messages.list_messages(chat)

      {:ok, message} =
        Messages.add_edited_body(scope, Messages.get_message!(scope, id), %{"content" => "Hello there, friend"})

      [orig, edit] = message.bodies
      %{id: id, orig: orig, edit: edit}
    end

    defp timeline_ids(view) do
      view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("#swipe-timeline > li") |> LazyHTML.attribute("id")
    end

    test "the history button appears only with more than one swipe", %{conn: conn, chat: chat} do
      [%{id: id}] = Messages.list_messages(chat)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      refute has_element?(view, "#swipe-history-#{id}")
    end

    test "opens on a newest-first timeline with the active edit labelled", %{scope: scope, conn: conn, chat: chat} do
      %{id: id, orig: orig, edit: edit} = edited_message(scope, chat)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_click(element(view, "#swipe-history-#{id}"))

      assert has_element?(view, "#swipe-inspector-modal")
      assert timeline_ids(view) == ["swipe-row-#{edit.id}", "swipe-row-#{orig.id}"]
      assert has_element?(view, "#swipe-row-#{edit.id}.swipe-row--active")
      assert has_element?(view, "#swipe-row-#{edit.id}", "Edit of #1")

      # The active swipe opens expanded; the rest stay collapsed.
      assert has_element?(view, "#swipe-toggle-#{edit.id}[aria-expanded='true']")
      assert has_element?(view, "#swipe-toggle-#{orig.id}[aria-expanded='false']")
    end

    test "expanding shows full text and the diff against the source", %{scope: scope, conn: conn, chat: chat} do
      %{id: id, orig: orig, edit: edit} = edited_message(scope, chat)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      render_click(element(view, "#swipe-history-#{id}"))

      assert has_element?(view, "#swipe-toggle-#{edit.id}[aria-expanded='true']")
      assert has_element?(view, "#swipe-text-#{edit.id}", "Hello there, friend")

      render_click(element(view, "#swipe-diff-toggle-#{edit.id}"))
      assert has_element?(view, "#swipe-diff-#{edit.id} ins", ", friend")

      render_click(element(view, "#swipe-toggle-#{orig.id}"))
      assert has_element?(view, "#swipe-text-#{orig.id}", "Hello there")
      refute has_element?(view, "#swipe-diff-toggle-#{orig.id}")

      # Expansion is exclusive: opening the original collapsed the edit.
      assert has_element?(view, "#swipe-toggle-#{edit.id}[aria-expanded='false']")
      refute has_element?(view, "#swipe-diff-#{edit.id}")

      render_click(element(view, "#swipe-toggle-#{orig.id}"))
      refute has_element?(view, "#swipe-toggle-#{orig.id}[aria-expanded='true']")
    end

    test "Make active switches the message's active swipe", %{scope: scope, conn: conn, chat: chat} do
      %{id: id, orig: orig} = edited_message(scope, chat)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      render_click(element(view, "#swipe-history-#{id}"))

      render_click(element(view, "#swipe-toggle-#{orig.id}"))
      render_click(element(view, "#swipe-activate-#{orig.id}"))

      assert has_element?(view, "#swipe-row-#{orig.id}.swipe-row--active")
      assert has_element?(view, "#messages-#{id} .chat-message-swipe-count", "1 / 2")
      assert Enum.find(Messages.get_message!(scope, id).bodies, & &1.active).id == orig.id
    end

    test "a new swipe made elsewhere appears in the open inspector", %{scope: scope, conn: conn, chat: chat} do
      %{id: id} = edited_message(scope, chat)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      render_click(element(view, "#swipe-history-#{id}"))

      {:ok, message} = Messages.add_edited_body(scope, Messages.get_message!(scope, id), %{"content" => "Third"})
      third = List.last(message.bodies)

      assert [first | _] = ids = timeline_ids(view)
      assert length(ids) == 3
      assert first == "swipe-row-#{third.id}"
    end

    test "closing removes the modal", %{scope: scope, conn: conn, chat: chat} do
      %{id: id} = edited_message(scope, chat)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      render_click(element(view, "#swipe-history-#{id}"))

      render_hook(view, "close_swipe_inspector", %{})

      refute has_element?(view, "#swipe-inspector-modal")
    end
  end

  describe "prompt inspector" do
    # A snapshot on the setup chat's only reply: two sections, one carrying a hidden-content book's
    # entry, and a request body that repeats that entry's text.
    setup %{chat: chat} do
      [message] = Messages.list_messages(chat)
      body = List.first(message.bodies)

      {:ok, snapshot} =
        Messages.create_prompt_snapshot(body, %{
          tokenizer: nil,
          sections: [
            %{
              block_name: "Main",
              source: "template",
              role: "system",
              content: "Be brief.",
              tokens: 3,
              estimated: true,
              template_errors: ["Template syntax error: line 1, column 1: boom"]
            },
            %{
              block_name: "Lore",
              source: "template",
              role: "system",
              content: "SECRET LORE",
              tokens: 5,
              estimated: true
            }
          ],
          lore: %{
            activated: [
              %{
                entry_id: "entry-1",
                entry_name: "Hidden",
                book_name: "Vault",
                content_hidden: true,
                slot: "before_character",
                reason: "constant",
                tokens: 5,
                content: "SECRET LORE",
                template_errors: ["boom"]
              },
              %{
                entry_id: "entry-2",
                entry_name: "Open",
                book_name: "Atlas",
                content_hidden: false,
                slot: "after_character",
                reason: "constant",
                effective_order: 7,
                pass: 2,
                tokens: 1,
                content: "x",
                template_errors: ["Template took longer than 1000 ms."]
              }
            ],
            rejected: [],
            budget: %{limit: 2048, used: 5, overflowed: false, estimated: true},
            passes: 1
          },
          variable_writes: [
            %{scope: "chat", key: "mood", value: "tense"},
            %{scope: "global", key: "gone", value: nil}
          ],
          template_errors: ["Bob's description: boom"],
          injections: [
            %{key: "short", position: "after_author_note", status: "applied", text: "Be brief.", template_errors: []}
          ]
        })

      {:ok, _} =
        Messages.put_snapshot_request(snapshot, %{
          url: "http://localhost/v1/chat/completions",
          body: %{messages: [%{role: "system", content: "Be brief.\nSECRET LORE"}]}
        })

      %{message: message}
    end

    test "the button appears only on a swipe with a snapshot",
         %{conn: conn, chat: chat, message: message, second_chat: second_chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      assert has_element?(view, "#prompt-inspector-#{message.id}")

      [other] = Messages.list_messages(second_chat)
      {:ok, view, _html} = live(conn, ~p"/chats/#{second_chat.id}")
      refute has_element?(view, "#prompt-inspector-#{other.id}")
    end

    test "itemizes sections, showing hidden lore to an admin", %{conn: conn, chat: chat, message: message} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_click(element(view, "#prompt-inspector-#{message.id}"))

      assert has_element?(view, "#prompt-inspector-modal")
      assert has_element?(view, "#prompt-summary")

      assert view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("#prompt-sections > li") |> Enum.count() ==
               2

      render_click(element(view, "#prompt-section-toggle-1"))
      assert has_element?(view, "#prompt-section-text-1", "SECRET LORE")

      render_click(element(view, "#prompt-view-request"))
      assert has_element?(view, "#prompt-request")

      render_click(element(view, "#prompt-view-lore"))
      assert has_element?(view, "#prompt-lore-activated", "Hidden")
      assert has_element?(view, "#prompt-lore-error-entry-2-0")
      assert has_element?(view, "#prompt-lore-error-entry-1-0")

      # Grouped under each slot, in injection order, with each entry's order and pass.
      slots =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#prompt-lore-activated > section")
        |> Enum.map(&LazyHTML.attribute(&1, "id"))
        |> List.flatten()

      assert slots == ["prompt-lore-slot-before_character", "prompt-lore-slot-after_character"]
      assert has_element?(view, "#prompt-lore-slot-after_character #prompt-lore-entry-2", "order 7")
      assert has_element?(view, "#prompt-lore-slot-after_character #prompt-lore-entry-2", "pass 2")
      assert has_element?(view, "#prompt-lore-budget", "1 pass")

      render_hook(view, "close_prompt_inspector", %{})
      refute has_element?(view, "#prompt-inspector-modal")
    end

    test "shows the context limit, how much history was trimmed and the cached prompt", %{
      conn: conn,
      scope: scope,
      chat: chat,
      message: message
    } do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      render_click(element(view, "#prompt-inspector-#{message.id}"))
      refute has_element?(view, "#prompt-context")
      refute has_element?(view, "#prompt-context-trimmed")
      refute has_element?(view, "#prompt-cached")

      body = List.first(message.bodies)

      scope
      |> Messages.get_prompt_snapshot(body.id)
      |> Ecto.Changeset.change(
        response: %{"text" => "pong", "usage" => %{"prompt_tokens_details" => %{"cached_tokens" => 15}}},
        context: %{
          "limit" => 4096,
          "reserve" => 512,
          "used" => 3000,
          "kept" => 4,
          "trimmed" => 3,
          "estimated" => true,
          "overflow" => false
        }
      )
      |> Mythweaver.Repo.update!()

      body |> Ecto.Changeset.change(prompt_tokens: 20) |> Mythweaver.Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      render_click(element(view, "#prompt-inspector-#{message.id}"))
      assert has_element?(view, "#prompt-context", "≈3,000/4,096 · 512 reserved")
      assert has_element?(view, "#prompt-context-trimmed", "3 older messages")
      assert has_element?(view, "#prompt-cached", "15")
      assert has_element?(view, "#prompt-cached-share", "75%")
      assert has_element?(view, "#prompt-context-full", "73% full")

      # Sections 3 + 5, overhead 20 - 8, then the reserve; nothing for the unfilled rest.
      assert has_element?(view, "#prompt-chart-overhead[style*='--tokens: 12']")
      assert has_element?(view, "#prompt-chart-reserve[style*='--tokens: 512']")
      refute has_element?(view, "#prompt-chart-unfilled")
      assert has_element?(view, "#prompt-chart-reserve-popup", "Reserved for the reply")
      assert has_element?(view, "#prompt-chart-reserve-popup", "512 tokens · 96.2%")
      assert has_element?(view, "#prompt-chart-caption", "≈20 of 4,096 tokens filled · 512 reserved for the reply")
    end

    test "the context bar shows each section without a limit", %{conn: conn, chat: chat, message: message} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      render_click(element(view, "#prompt-inspector-#{message.id}"))

      assert has_element?(view, "#prompt-chart-section-0[style*='--tokens: 3']")
      assert has_element?(view, "#prompt-chart-section-1[style*='--tokens: 5']")
      refute has_element?(view, "#prompt-chart-reserve")
      refute has_element?(view, "#prompt-context-full")
      assert has_element?(view, "#prompt-chart-caption", "≈8 tokens across 2 sections")
    end

    test "shows the images a section sent inline, and marks one since deleted", %{scope: scope, chat: chat} = ctx do
      [message] = Messages.list_messages(chat)
      body = List.first(message.bodies)
      snapshot = Messages.get_prompt_snapshot(scope, body.id)

      png =
        Base.decode64!(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        )

      {:ok, kept} = Mythweaver.Attachments.store_binary(png)
      gone = Mythweaver.Schema.generate_id()

      history = %{
        "block_name" => "History",
        "source" => "chat_history",
        "role" => "user",
        "content" => "Look",
        "tokens" => 171,
        "estimated" => true,
        "images" => 2,
        "image_tokens" => 170,
        "inline_images" => [%{"id" => kept.id, "tokens" => 85}, %{"id" => gone, "tokens" => 85}]
      }

      snapshot |> Ecto.Changeset.change(sections: snapshot.sections ++ [history]) |> Mythweaver.Repo.update!()

      {:ok, view, _html} = live(ctx.conn, ~p"/chats/#{chat.id}")
      render_click(element(view, "#prompt-inspector-#{message.id}"))
      render_click(element(view, "#prompt-section-toggle-2"))

      assert has_element?(view, "#prompt-section-image-2-1 img")
      assert has_element?(view, "#prompt-section-image-2-1 figcaption", "≈85 tokens")
      refute has_element?(view, "#prompt-section-image-2-2 img")
      assert has_element?(view, "#prompt-section-image-2-2 figcaption", "since deleted")
    end

    test "shows template errors under their section and the variable writes", %{
      conn: conn,
      chat: chat,
      message: message
    } do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      render_click(element(view, "#prompt-inspector-#{message.id}"))

      assert has_element?(view, "#prompt-section-0 #prompt-section-error-0-0", "Template syntax error")
      assert has_element?(view, "#prompt-template-error-0", "Bob's description: boom")

      render_click(element(view, "#prompt-view-variables"))
      assert has_element?(view, "#prompt-variable-write-0", "mood")
      assert has_element?(view, "#prompt-variable-write-0", ~s("tense"))
      assert has_element?(view, "#prompt-variable-write-1", "deleted")
    end

    test "the injections view lists what applied", %{conn: conn, chat: chat, message: message} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      render_click(element(view, "#prompt-inspector-#{message.id}"))

      render_click(element(view, "#prompt-view-injections"))
      assert has_element?(view, "#prompt-injection-0", "short")
      assert has_element?(view, "#prompt-injection-0", "Be brief.")
      assert has_element?(view, "#prompt-injection-0", "applied")
    end
  end

  describe "message templates" do
    defp active_content(message), do: Enum.find(message.bodies, & &1.active).content

    test "a sent template is stored rendered and recalled raw", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_submit(element(view, "#message-composer"), %{composer: %{content: "Hi {{ anchors.participants }}"}})

      assert [_setup, sent] = Messages.list_messages(chat)
      assert active_content(sent) == "Hi Alice, Bob"
      assert has_element?(view, "#messages-#{sent.id}", "Hi Alice, Bob")

      refute Enum.any?(Messages.list_messages(chat), fn m -> Enum.any?(m.bodies, &(&1.content =~ "{{")) end)
      # Input history stores what the user typed, not the rendered text; the id names the row that
      # replaces the composer's provisional copy.
      sent_id = sent.id
      assert_push_event(view, "composer_sent", %{content: "Hi {{ anchors.participants }}", message_id: ^sent_id})
      assert_push_event(view, "composer_submitted", %{})
    end

    test "a template that does not parse is not sent", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_submit(element(view, "#message-composer"), %{composer: %{content: "{% if %}"}})

      assert [_setup] = Messages.list_messages(chat)
      assert has_element?(view, "#flash-error", "Message not sent: Template syntax error")
      refute_push_event(view, "composer_sent", %{})
      # The composer hook takes this, with no `composer_sent` before it, as a refusal.
      assert_push_event(view, "composer_submitted", %{})
    end

    test "variable writes are dropped with a notice", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_submit(element(view, "#message-composer"), %{composer: %{content: "{% setvar x = 1 %}hello"}})

      assert [_setup, sent] = Messages.list_messages(chat)
      assert active_content(sent) == "hello"
      assert has_element?(view, "#flash-info", "Variable writes in messages are ignored.")
      assert Variables.values(chat.id).chat == %{}
    end

    test "anchors.character names the sender, on send and on edit",
         %{scope: scope, conn: conn, chat: chat, second_chat: second_chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_submit(element(view, "#message-composer"), %{
        composer: %{content: "My name is {{ anchors.character.name }}"}
      })

      assert [_setup, sent] = Messages.list_messages(chat)
      assert active_content(sent) == "My name is Alice"

      # Bob is not the player; an edit of his message still renders as him.
      [%{id: id}] = Messages.list_messages(second_chat)
      {:ok, view, _html} = live(conn, ~p"/chats/#{second_chat.id}")
      render_click(element(view, "#message-edit-#{id}"))

      render_submit(element(view, "#message-edit-form-#{id}"), %{
        message_body: %{content: "I am {{ anchors.character.name }}"}
      })

      assert active_content(Messages.get_message!(scope, id)) == "I am Bob"
    end

    test "a saved edit is stored rendered", %{scope: scope, conn: conn, chat: chat} do
      [%{id: id}] = Messages.list_messages(chat)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_click(element(view, "#message-edit-#{id}"))
      render_submit(element(view, "#message-edit-form-#{id}"), %{message_body: %{content: "{{ anchors.chat.name }}"}})

      assert active_content(Messages.get_message!(scope, id)) == "Alpha Chat"
    end

    test "a user_message script rewrites the sent text", %{scope: scope, conn: conn, chat: chat} do
      {:ok, _} =
        Scripts.create_script(scope, %{name: "Bang", trigger: :user_message, body: ~s(return event.text .. "!")})

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_submit(element(view, "#message-composer"), %{composer: %{content: "hello"}})

      assert [_setup, sent] = Messages.list_messages(chat)
      assert active_content(sent) == "hello!"
    end

    test "a blank send stays a no-op under a script that appends text", %{scope: scope, conn: conn, chat: chat} do
      {:ok, _} =
        Scripts.create_script(scope, %{name: "Bang", trigger: :user_message, body: ~s(return event.text .. "!")})

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_submit(element(view, "#message-composer"), %{composer: %{content: "  "}})

      assert [_setup] = Messages.list_messages(chat)
    end

    @tag :capture_log
    test "a failing script flashes and the original text is sent", %{scope: scope, conn: conn, chat: chat} do
      {:ok, _} = Scripts.create_script(scope, %{name: "Boom", trigger: :user_message, body: ~s|error("boom")|})
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_submit(element(view, "#message-composer"), %{composer: %{content: "hello"}})

      assert [_setup, sent] = Messages.list_messages(chat)
      assert active_content(sent) == "hello"
      assert has_element?(view, "#flash-error", ~s(Script "Boom" failed))
    end
  end

  describe "inline scripts" do
    defp send_composer(view, content),
      do: render_submit(element(view, "#message-composer"), %{composer: %{content: content}})

    test "a block's return value replaces it", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      send_composer(view, ~S|Hi {! return "there" !}|)

      assert body_contents(chat) == ["Hello there", "Hi there"]
      assert_push_event(view, "composer_sent", %{content: ~S|Hi {! return "there" !}|})
    end

    test "a block that leaves nothing posts nothing and clears the composer", %{scope: scope, conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      render_change(element(view, "#message-composer"), %{composer: %{content: "draft"}})
      :ok = DraftBuffer.flush(chat.id)

      source = "{! for _, m in ipairs(mw.messages.list()) do mw.messages.delete(m.id) end !}"
      send_composer(view, source)

      assert body_contents(chat) == []
      assert Messages.draft_content(scope, chat) == ""
      assert Messages.get_draft(chat) == nil
      assert_push_event(view, "composer_sent", %{content: ^source, message_id: nil})
    end

    test "a block that does not parse blocks the send", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      send_composer(view, "Hi {! return ( !}")

      assert body_contents(chat) == ["Hello there"]
      assert has_element?(view, "#flash-error", "Message not sent: inline script 1")
      refute_push_event(view, "composer_sent", %{})
    end

    @tag :capture_log
    test "a runtime error stops at that block and posts nothing", %{conn: conn, chat: chat, c2: c2} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      send_composer(view, ~s|A {! error("boom") !} {! mw.messages.create("#{c2.id}", "ran") !}|)

      assert body_contents(chat) == ["Hello there"]
      assert has_element?(view, "#flash-error", "inline script 1 failed")
      refute_push_event(view, "composer_sent", %{})
    end

    test "a block in a false branch does not run", %{conn: conn, chat: chat, c2: c2} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      send_composer(view, ~s|{% if false %}{! mw.messages.create("#{c2.id}", "ran") !}{% endif %}ok|)

      assert body_contents(chat) == ["Hello there", "ok"]
    end
  end

  describe "chat variables" do
    test "create, list, and delete from the header modal", %{scope: scope, conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_click(element(view, "#chat-variables-button"))
      assert has_element?(view, "#chat-variables")
      assert has_element?(view, "#chat-variables-empty")

      view
      |> element("#chat-variable-form")
      |> render_submit(%{"variable" => %{"key" => "mood", "value" => ~s("calm")}})

      assert Variables.values(chat.id).chat == %{"mood" => "calm"}
      [variable] = Variables.list_chat_variables(scope, chat.id)
      assert has_element?(view, "#chat-variable-#{variable.id}", "calm")

      render_click(element(view, "#delete-chat-variable-#{variable.id}"))
      refute has_element?(view, "#chat-variable-#{variable.id}")
      assert Variables.list_chat_variables(scope, chat.id) == []
    end

    test "editing keeps a JSON value's type", %{scope: scope, conn: conn, chat: chat} do
      {:ok, variable} = Variables.create_variable(scope, chat.id, %{key: "hp", value: 10})
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_click(element(view, "#chat-variables-button"))
      render_click(element(view, "#edit-chat-variable-#{variable.id}"))
      assert has_element?(view, "#chat-variable-form-value[data-value='10']")

      view
      |> element("#chat-variable-form")
      |> render_submit(%{"variable" => %{"key" => "hp", "value" => "9"}})

      assert Variables.get_variable!(variable.id).value == 9
    end

    test "an invalid key is reported and saves nothing", %{scope: scope, conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      render_click(element(view, "#chat-variables-button"))

      html =
        view
        |> element("#chat-variable-form")
        |> render_submit(%{"variable" => %{"key" => "bad key", "value" => "1"}})

      assert html =~ "must start with a letter or underscore"
      assert Variables.list_chat_variables(scope, chat.id) == []
    end

    test "a generation's writes appear while the modal is open", %{scope: scope, conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      render_click(element(view, "#chat-variables-button"))

      :ok = Variables.apply_writes(chat.id, [%{"scope" => "chat", "key" => "seen", "value" => true}])

      [variable] = Variables.list_chat_variables(scope, chat.id)
      _ = render(view)
      assert has_element?(view, "#chat-variable-#{variable.id}", "true")
    end
  end

  describe "injections" do
    test "create from the header modal; the badge counts active ones", %{scope: scope, conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      refute has_element?(view, "#chat-injections-count")

      render_click(element(view, "#chat-injections-button"))
      assert has_element?(view, "#chat-injections")
      assert has_element?(view, "#chat-injections-empty")

      view
      |> element("#chat-injection-form")
      |> render_submit(%{
        injection: %{key: "short", content: "Be brief.", position: "after_author_note", uses: "1"}
      })

      assert [%{uses: 1, remaining: 1} = injection] = Injections.list_injections(scope, chat.id)
      assert has_element?(view, "#chat-injection-#{injection.id}", "1 of 1 left")
      assert has_element?(view, "#chat-injections-count", "1")

      render_click(element(view, "#toggle-chat-injection-#{injection.id}"))
      assert [%{enabled: false}] = Injections.list_injections(scope, chat.id)
      refute has_element?(view, "#chat-injections-count")
      assert has_element?(view, "#chat-injection-#{injection.id}", "disabled")
    end

    test "the depth fields show only for an at_depth position", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      render_click(element(view, "#chat-injections-button"))
      refute has_element?(view, "#chat-injection-form-depth")

      view
      |> element("#chat-injection-form")
      |> render_change(%{injection: %{position: "at_depth"}})

      assert has_element?(view, "#chat-injection-form-depth")
      assert has_element?(view, "#chat-injection-form-role")
    end

    test "a spent injection can be re-armed or cleaned up", %{scope: scope, conn: conn, chat: chat} do
      {:ok, spent} = Injections.create_injection(scope, chat.id, %{key: "once", content: "x", uses: 1})
      {:ok, off} = Injections.create_injection(scope, chat.id, %{key: "off", content: "y", uses: 1, enabled: false})
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      render_click(element(view, "#chat-injections-button"))
      refute has_element?(view, "#clean-up-chat-injections")

      :ok = Injections.spend(chat.id, [spent.id])
      _ = render(view)
      assert has_element?(view, "#chat-injection-#{spent.id}", "spent")
      refute has_element?(view, "#chat-injections-count")

      render_click(element(view, "#rearm-chat-injection-#{spent.id}"))
      assert has_element?(view, "#chat-injection-#{spent.id}", "1 of 1 left")
      assert has_element?(view, "#chat-injections-count", "1")

      :ok = Injections.spend(chat.id, [spent.id])
      _ = render(view)
      render_click(element(view, "#clean-up-chat-injections"))
      refute has_element?(view, "#chat-injection-#{spent.id}")
      assert has_element?(view, "#chat-injection-#{off.id}")
      assert [%{id: off_id}] = Injections.list_injections(scope, chat.id)
      assert off_id == off.id
    end

    test "an invalid condition is reported and saves nothing", %{scope: scope, conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      render_click(element(view, "#chat-injections-button"))

      html =
        view
        |> element("#chat-injection-form")
        |> render_submit(%{injection: %{key: "k", content: "x", condition: "vars.x =="}})

      assert html =~ "is not a valid Liquid condition"
      assert Injections.list_injections(scope, chat.id) == []
    end
  end

  describe "lazy transcript" do
    # Adds `n` messages after the setup chat's one, so the chat holds `n + 1`. Returns them oldest first.
    defp fill!(chat, character, n), do: Enum.map(1..n, &add_message(chat, character, "m#{&1}"))

    defp row_ids(view) do
      view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("#messages > li") |> LazyHTML.attribute("id")
    end

    defp load_older(view, times), do: for(_ <- 1..times, do: render_hook(view, "load_older_messages", %{}))

    # The setup message plus enough to page past the cap, with the window then scrolled to the top.
    defp capped_view(conn, chat, c2) do
      page = MessageWindow.page_size()
      total = MessageWindow.max_loaded() + page + 10
      messages = fill!(chat, c2, total - 1)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      assert_push_event(view, "scroll_to_bottom", %{})
      load_older(view, div(total, page))
      {view, messages}
    end

    test "a chat opens on its newest page", %{conn: conn, chat: chat, c2: c2} do
      messages = fill!(chat, c2, 119)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      ids = row_ids(view)
      assert length(ids) == MessageWindow.page_size()
      assert List.last(ids) == "messages-#{List.last(messages).id}"
      assert has_element?(view, "#messages[data-has-older='true']")
      refute has_element?(view, "#jump-to-latest")
    end

    test "loading older prepends pages until the start", %{conn: conn, chat: chat, c2: c2} do
      [first] = Messages.list_messages(chat)
      fill!(chat, c2, 119)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_hook(view, "load_older_messages", %{})
      assert length(row_ids(view)) == 2 * MessageWindow.page_size()

      render_hook(view, "load_older_messages", %{})
      ids = row_ids(view)
      assert length(ids) == 120
      assert hd(ids) == "messages-#{first.id}"
      assert has_element?(view, "#messages[data-has-older='false']")
    end

    test "the window is capped, unloading the newest rows", %{conn: conn, chat: chat, c2: c2} do
      {view, messages} = capped_view(conn, chat, c2)

      assert length(row_ids(view)) == MessageWindow.max_loaded()
      assert has_element?(view, "#messages[data-has-newer='true']")
      assert has_element?(view, "#jump-to-latest")
      refute has_element?(view, "#messages-#{List.last(messages).id}")
    end

    test "live messages wait while the bottom is unloaded; jumping loads the latest", %{
      scope: scope,
      conn: conn,
      chat: chat,
      c2: c2
    } do
      {view, _messages} = capped_view(conn, chat, c2)

      {:ok, late} = Messages.send_message(scope, chat, c2.id, "late")
      refute has_element?(view, "#messages-#{late.id}")
      assert length(row_ids(view)) == MessageWindow.max_loaded()

      render_click(element(view, "#jump-to-latest"))

      ids = row_ids(view)
      assert length(ids) == MessageWindow.page_size()
      assert List.last(ids) == "messages-#{late.id}"
      assert has_element?(view, "#messages[data-has-newer='false']")
      refute has_element?(view, "#jump-to-latest")
      assert_push_event(view, "scroll_to_bottom", %{})
    end

    test "loading newer brings unloaded rows back and unloads the oldest", %{conn: conn, chat: chat, c2: c2} do
      {view, _messages} = capped_view(conn, chat, c2)
      all = Messages.list_messages(chat)
      page = MessageWindow.page_size()
      max = MessageWindow.max_loaded()
      assert hd(row_ids(view)) == "messages-#{hd(all).id}"

      render_hook(view, "load_newer_messages", %{})

      ids = row_ids(view)
      assert length(ids) == max
      assert hd(ids) == "messages-#{Enum.at(all, page).id}"
      assert List.last(ids) == "messages-#{Enum.at(all, page + max - 1).id}"
    end

    test "an update to an unloaded message does not insert its row", %{scope: scope, conn: conn, chat: chat, c2: c2} do
      [oldest] = Messages.list_messages(chat)
      fill!(chat, c2, 119)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      {:ok, _} = Messages.add_edited_body(scope, Messages.get_message!(scope, oldest.id), %{"content" => "changed"})

      refute has_element?(view, "#messages-#{oldest.id}")
      assert length(row_ids(view)) == MessageWindow.page_size()
    end

    test "select all selects only the loaded rows", %{conn: conn, chat: chat, c2: c2} do
      newest = chat |> fill!(c2, 119) |> List.last()
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_click(element(view, "#message-select-#{newest.id}"))
      render_click(element(view, "#bulk-select-all"))
      render_click(element(view, "#bulk-toggle-visibility"))

      assert chat |> Messages.list_messages() |> Enum.count(&(not &1.visible_to_ai)) == MessageWindow.page_size()
    end

    test "sending your own message snaps back to the latest", %{conn: conn, chat: chat, c2: c2} do
      {view, _messages} = capped_view(conn, chat, c2)

      render_submit(element(view, "#message-composer"), %{composer: %{content: "mine"}})

      mine = chat |> Messages.list_messages() |> List.last()
      assert active_body_content(mine) == "mine"
      ids = row_ids(view)
      assert length(ids) == MessageWindow.page_size()
      assert List.last(ids) == "messages-#{mine.id}"
      assert has_element?(view, "#messages[data-has-newer='false']")
      assert_push_event(view, "scroll_to_bottom", %{})
    end

    defp active_body_content(message), do: Enum.find(message.bodies, & &1.active).content
  end

  describe "embedding status" do
    # "dragon" texts embed to [1, 0], the rest to [0, 1]; each request's input goes to the test.
    defp stub_embeddings do
      test = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        input = Jason.decode!(raw)["input"]
        send(test, {:embed, input})

        data =
          input
          |> Enum.with_index()
          |> Enum.map(fn {text, i} ->
            %{"index" => i, "embedding" => if(text =~ ~r/dragon/i, do: [1.0, 0.0], else: [0.0, 1.0])}
          end)

        Req.Test.json(conn, %{"data" => data, "usage" => %{"prompt_tokens" => 7}})
      end)
    end

    # The user's embedding model, set as their `lore.embedding_model`.
    defp embedder!(scope) do
      {:ok, provider} =
        AI.create_provider(scope, %{
          name: "Embeddings",
          adapter: :openai_compatible,
          base_url: "http://localhost:8080/v1"
        })

      {:ok, model} = AI.create_model(scope, %{name: "Embedder", api_model_id: "embed-1", completion_mode: :embedding})
      {:ok, _link} = AI.link_model(scope, provider, model)
      :ok = Settings.put(scope, :user, "lore.embedding_model", model.id)
      AI.get_model!(model.id)
    end

    defp bound_book!(scope, chat) do
      {:ok, book} = Lore.create_book(scope, %{name: "Bestiary"})
      {:ok, _} = Lore.bind_book_to_chat(book, chat.id)
      book
    end

    defp lore_entry!(scope, book, attrs) do
      attrs = Map.merge(%{name: "Dragons", content: "Dragons hoard gold", keywords: []}, attrs)
      {:ok, entry} = Lore.create_entry(scope, attrs, [book.id])
      entry
    end

    test "a message shows pending until its body is embedded", %{conn: conn, scope: scope, chat: chat} do
      stub_embeddings()
      model = embedder!(scope)
      lore_entry!(scope, bound_book!(scope, chat), %{activation: :vector})
      [message] = Messages.list_messages(chat)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      assert has_element?(view, "#message-embedding-#{message.id}[data-embedded='false'][title^='Not embedded yet']")

      assert :ok = Embeddings.embed_messages(scope, chat, model)
      assert_received {:embed, ["Hello there"]}
      :sys.get_state(view.pid)

      assert has_element?(
               view,
               "#message-embedding-#{message.id}[data-embedded='true'][title='Embedded for vector lore']"
             )
    end

    test "swiping back to an embedded body shows it embedded", %{conn: conn, scope: scope, chat: chat} do
      stub_embeddings()
      model = embedder!(scope)
      lore_entry!(scope, bound_book!(scope, chat), %{activation: :vector})
      [message] = Messages.list_messages(chat)
      :ok = Embeddings.embed_messages(scope, chat, model)
      {:ok, _swipe} = Messages.add_body(message, %{content: "Hello again"})

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      assert has_element?(view, "#message-embedding-#{message.id}[data-embedded='false']")

      view |> element("#messages-#{message.id} .chat-message-swipe--prev") |> render_click()
      assert has_element?(view, "#message-embedding-#{message.id}[data-embedded='true']")
    end

    test "a chat without Vector entries shows no icon", %{conn: conn, scope: scope, chat: chat} do
      embedder!(scope)
      lore_entry!(scope, bound_book!(scope, chat), %{activation: :keyword, keywords: ["dragon"]})
      [message] = Messages.list_messages(chat)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      assert has_element?(view, "#messages-#{message.id}")
      refute has_element?(view, "#message-embedding-#{message.id}")
    end
  end

  describe "unread marker" do
    defp unread(chat_id), do: "a.chat-picker-link--unread[href='/chats/#{chat_id}']"

    # The file's setup messages are raw `create_message/2` inserts, which record no activity.
    setup %{chat: chat, second_chat: second_chat} do
      :ok = Messages.touch_activity(chat.id)
      :ok = Messages.touch_activity(second_chat.id)
      :ok
    end

    test "marks other unread chats, never the open or an empty one",
         %{conn: conn, chat: chat, empty_chat: empty_chat, second_chat: second_chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      assert has_element?(view, unread(second_chat.id))
      refute has_element?(view, unread(chat.id))
      refute has_element?(view, unread(empty_chat.id))
      assert Chats.get_chat!(chat.id).last_read_at
    end

    test "opening a chat clears its marker", %{conn: conn, chat: chat, second_chat: second_chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      render_patch(view, ~p"/chats/#{second_chat.id}")
      refute has_element?(view, unread(second_chat.id))

      render_patch(view, ~p"/chats/#{chat.id}")
      refute has_element?(view, unread(second_chat.id))
      refute has_element?(view, unread(chat.id))
    end

    test "a message in another chat marks it live",
         %{scope: scope, conn: conn, chat: chat, c2: c2, second_chat: second_chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{second_chat.id}")
      render_patch(view, ~p"/chats/#{chat.id}")
      refute has_element?(view, unread(second_chat.id))

      {:ok, _} = Messages.send_message(scope, second_chat, c2.id, "ping")
      assert has_element?(view, unread(second_chat.id))
    end

    test "a message in the open chat counts as read", %{scope: scope, conn: conn, chat: chat, c2: c2} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      {:ok, _} = Messages.send_message(scope, chat, c2.id, "hi")
      refute has_element?(view, unread(chat.id))
      refute Map.has_key?(Messages.unread_chats(scope), chat.id)
    end

    test "opening a chat in another tab clears its marker here",
         %{conn: conn, chat: chat, second_chat: second_chat} do
      {:ok, tab_a, _html} = live(conn, ~p"/chats/#{chat.id}")
      assert has_element?(tab_a, unread(second_chat.id))

      {:ok, _tab_b, _html} = live(conn, ~p"/chats/#{second_chat.id}")
      refute has_element?(tab_a, unread(second_chat.id))
    end

    test "a read older than the newest activity it saw leaves the marker", %{
      conn: conn,
      chat: chat,
      second_chat: second_chat
    } do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      earlier = DateTime.utc_now()
      later = DateTime.add(earlier, 1, :second)

      # Another tab read the chat at `earlier`; its broadcast lands after newer activity's.
      send(view.pid, {:chat_activity, second_chat.id, later})
      send(view.pid, {:chat_read, second_chat.id, earlier})
      assert has_element?(view, unread(second_chat.id))

      send(view.pid, {:chat_read, second_chat.id, later})
      refute has_element?(view, unread(second_chat.id))
    end
  end

  describe "chat list across windows" do
    test "a chat created in one window appears in the others", %{
      conn: conn,
      chat: chat,
      second_chat: second_chat,
      c1: c1,
      c2: c2
    } do
      {:ok, a, _} = live(conn, ~p"/chats/#{chat.id}")
      {:ok, b, _} = live(conn, ~p"/chats/#{second_chat.id}")

      a |> element("#new-chat") |> render_click()

      a
      |> form("#chat-form", chat: %{name: "Guild Hall", participant_ids: [c1.id, c2.id]})
      |> render_submit()

      assert has_element?(b, ".chat-picker-link", "Guild Hall")
    end

    test "a rename in one window updates the list in windows on other chats", %{
      conn: conn,
      chat: chat,
      second_chat: second_chat
    } do
      {:ok, a, _} = live(conn, ~p"/chats/#{second_chat.id}/settings")
      {:ok, b, _} = live(conn, ~p"/chats/#{chat.id}")

      a |> form("#chat-settings-form", settings: %{name: "Zeta Renamed"}) |> render_submit()

      assert has_element?(b, ".chat-picker-link", "Zeta Renamed")
      refute has_element?(b, ".chat-picker-link", "Zeta Chat")
    end

    test "deleting a chat moves windows on it to the index and drops it everywhere", %{
      conn: conn,
      chat: chat,
      second_chat: second_chat
    } do
      {:ok, deleter, _} = live(conn, ~p"/chats/#{chat.id}/settings")
      {:ok, watcher, _} = live(conn, ~p"/chats/#{chat.id}")
      {:ok, other, _} = live(conn, ~p"/chats/#{second_chat.id}")

      deleter |> element("#chat-settings-delete") |> render_click()

      assert_patch(watcher, ~p"/")

      for view <- [watcher, other] do
        refute has_element?(view, "a.chat-picker-link[href='/chats/#{chat.id}']")
      end

      assert has_element?(watcher, ".chat-picker-link--active")
      assert has_element?(other, ".chat-picker-link--active", "Zeta Chat")
    end
  end

  test "a ready consolidation tier flashes a link to the Consolidate tab, kept beside a later review notice",
       %{conn: conn, chat: chat, user: user} do
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    Phoenix.PubSub.broadcast(
      Mythweaver.PubSub,
      Mythweaver.Memory.topic(chat.id),
      {:consolidation_ready, %{book_id: Mythweaver.Schema.generate_id(), tier: 1}}
    )

    consolidate = "/chats/#{chat.id}/memory?tab=consolidate"
    assert has_element?(view, "#flash-consolidation", "Ready to consolidate an Arc")
    assert has_element?(view, "#flash-consolidation a.flash-action[href='#{consolidate}']", "Consolidate")

    # Saving a memory announces the tier, then its follow-up jobs park for review: the review
    # notice must not replace the consolidation one.
    review = %Notification{
      id: "n-review",
      kind: :memory_review,
      title: "Memory to review",
      body: "b",
      chat_id: chat.id
    }

    Phoenix.PubSub.broadcast(
      Mythweaver.PubSub,
      Mythweaver.Notifications.topic(user.id),
      {Mythweaver.Notifications, :in_app, review, %{popup: false, sound: false}}
    )

    assert has_element?(view, "#flash-memory_review a.flash-action", "Review")
    assert has_element?(view, "#flash-consolidation a.flash-action[href='#{consolidate}']", "Consolidate")

    # Each closes on its own.
    view |> element("#flash-consolidation .flash-close") |> render_click()
    refute has_element?(view, "#flash-consolidation")
    assert has_element?(view, "#flash-memory_review")
  end

  test "a prompt flash outlives opening and closing the memory modal, but not its own close",
       %{conn: conn, chat: chat} do
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    Phoenix.PubSub.broadcast(
      Mythweaver.PubSub,
      Mythweaver.Memory.topic(chat.id),
      {:consolidation_ready, %{book_id: Mythweaver.Schema.generate_id(), tier: 1}}
    )

    assert has_element?(view, "#flash-consolidation")
    send(view.pid, {MythweaverWeb.CommandPalette, :flash, :info, "Passing"})
    assert has_element?(view, "#flash-info")

    render_patch(view, ~p"/chats/#{chat.id}/memory")
    render_patch(view, ~p"/chats/#{chat.id}")

    assert has_element?(view, "#flash-consolidation", "Ready to consolidate an Arc")
    refute has_element?(view, "#flash-info")

    view |> element("#flash-consolidation .flash-close") |> render_click()
    render_patch(view, ~p"/chats/#{chat.id}/memory")
    refute has_element?(view, "#flash-consolidation")
  end

  describe "memory panel" do
    @memory_json ~s({"title": "Inn", "content": "They met at the inn.", "keywords": ["inn"]})

    setup %{chat: chat, c1: c1, c2: c2, scope: scope} = context do
      # Memory jobs run in scheduler-spawned tasks, outside the LiveView's `$callers` chain.
      Req.Test.set_req_test_to_shared(context)
      on_exit(fn -> await_jobs_idle(100) end)
      :ok = Jobs.subscribe(scope)

      {:ok, model} = AI.create_model(scope, %{name: "Gemma 4", api_model_id: "gemma-4"})

      {:ok, provider} =
        AI.create_provider(scope, %{name: "Local", adapter: :openai_compatible, base_url: "http://localhost:8080/v1"})

      {:ok, _link} = AI.link_model(scope, provider, model)
      {:ok, prompt} = Prompts.create_prompt(scope, %{name: "Memory: Test", purpose: :memory})
      {:ok, block} = Prompts.create_block(scope, %{name: "Scene", role: :user, content: "{{ anchors.memory.scene }}"})
      {:ok, _} = Prompts.add_block(scope, prompt, block)

      {:ok, profile} =
        Memory.create_profile(scope, %{name: "Default", ai_model_id: model.id, memory_prompt_id: prompt.id})

      {:ok, _} = Memory.set_default_profile(scope, profile)

      add_message(chat, c2, "Welcome to the inn")
      add_message(chat, c1, "Thanks")

      Req.Test.stub(Mythweaver.AI, &memory_reply/1)
      :ok
    end

    defp memory_reply(conn) do
      frames = [
        "data: #{Jason.encode!(%{choices: [%{index: 0, delta: %{content: @memory_json}, finish_reason: nil}]})}\n\n",
        ~s(data: {"choices":[{"finish_reason":"stop","index":0,"delta":{}}]}\n\n),
        "data: [DONE]\n\n"
      ]

      Enum.reduce(frames, Plug.Conn.send_chunked(conn, 200), fn frame, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, frame)
        conn
      end)
    end

    defp await_jobs_idle(0) do
      %{running: running, queued: queued} = Scheduler.status()
      Enum.each(running ++ queued, &Scheduler.cancel/1)
    end

    defp await_jobs_idle(tries) do
      case Scheduler.status() do
        %{running: [], queued: []} -> :ok
        _busy -> Process.sleep(10) && await_jobs_idle(tries - 1)
      end
    end

    defp await_job_status(status) do
      receive do
        {:job_changed, %{status: ^status} = job} -> job
      after
        2000 -> flunk("no job reached #{status}")
      end
    end

    test "opens prefilled with the next unprocessed range", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}/memory")

      assert has_element?(view, "#memory-create-form")
      assert has_element?(view, "#memory-create-start[value='1']")
      assert has_element?(view, "#memory-create-end[value='3']")
    end

    test "the chat's memory settings sit on their own tab, not with the controls", %{
      scope: scope,
      conn: conn,
      chat: chat
    } do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}/memory")
      refute has_element?(view, "#memory-settings-form")

      view |> element("#memory-tab-settings") |> render_click()
      assert_patch(view, ~p"/chats/#{chat.id}/memory?tab=settings")
      refute has_element?(view, "#memory-create-form")

      view
      |> form("#memory-settings-form", memory_settings: %{auto_enabled: "true"})
      |> render_submit()

      assert Memory.chat_settings(scope, Chats.get_chat!(chat.id)).auto_enabled
      assert has_element?(view, "#memory-settings-form")

      # The automatic-memory fields show the memory.auto_* setting they follow when blank.
      assert has_element?(view, "#memory-settings-interval[placeholder='Default (30)']")
      assert has_element?(view, "#memory-settings-trigger option[value='']", "Default (Every N messages)")

      view |> form("#memory-settings-form", memory_settings: %{auto_interval: "12"}) |> render_submit()
      assert Memory.chat_settings(scope, Chats.get_chat!(chat.id)).auto_interval == 12

      view
      |> form("#memory-settings-form", memory_settings: %{auto_interval: "", auto_trigger: ""})
      |> render_submit()

      assert %{auto_interval: nil, auto_trigger: nil} = Memory.chat_settings(scope, Chats.get_chat!(chat.id))
    end

    test "the memory settings form flags only renders of saved values", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}/memory?tab=settings")

      guarded = "#memory-settings-form[phx-hook='UnsavedChanges']"
      assert has_element?(view, "#{guarded}[data-saved]")

      view |> form("#memory-settings-form", memory_settings: %{auto_interval: "12"}) |> render_change()
      assert has_element?(view, guarded)
      refute has_element?(view, "#{guarded}[data-saved]")

      view |> form("#memory-settings-form", memory_settings: %{auto_interval: "12"}) |> render_submit()
      assert has_element?(view, "#{guarded}[data-saved]")
    end

    test "a user's book pickers offer only books they may edit", %{scope: admin} do
      user = register_user!(%{role: :user})
      user_scope = Scope.for_user(user)
      {:ok, site} = Mythweaver.Lore.create_book(admin, %{name: "Site memories"}, site: true)
      {:ok, own} = Mythweaver.Lore.create_book(user_scope, %{name: "Own memories"})
      [c1, c2] = [character(user_scope, "Their Alice"), character(user_scope, "Their Bob")]

      {:ok, chat} =
        Chats.create_chat(user_scope, %{
          name: "Their chat",
          participants: [%{character_id: c1.id}, %{character_id: c2.id}],
          player_character_id: c1.id
        })

      {:ok, view, _html} = live(log_in_user(build_conn(), user), ~p"/chats/#{chat.id}/memory?tab=settings")

      assert has_element?(view, "#memory-settings-book option[value='#{own.id}']")
      refute has_element?(view, "#memory-settings-book option[value='#{site.id}']")
    end

    test "a solo chat's memory book locks to its character", %{scope: scope, conn: conn, chat: chat, c2: c2} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}/memory?tab=settings")
      refute has_element?(view, "#memory-tab-characters")
      refute has_element?(view, "#memory-settings-cast")

      view |> element("#memory-character-lock-#{c2.id}", "Lock this book to Bob") |> render_click()
      assert render(view) =~ "Locked."
      book_id = Memory.chat_settings(scope, Chats.get_chat!(chat.id)).memory_book_id
      assert CharacterBooks.character_lock(scope, c2.id).lore_book_id == book_id
      assert has_element?(view, "#memory-settings-book[disabled]")
      assert has_element?(view, "#memory-settings-locked", "Locked to Bob")

      view |> element("#memory-character-lock-#{c2.id}", "Unlock from Bob") |> render_click()
      assert render(view) =~ "Unlocked."
      refute CharacterBooks.character_lock(scope, c2.id)
      refute has_element?(view, "#memory-settings-book[disabled]")
    end

    test "a group chat picks character books, locks one, and sets the present cast",
         %{scope: scope, conn: conn, c1: c1, c2: c2} do
      c3 = character(scope, "Cleo")

      {:ok, group} =
        Chats.create_chat(scope, %{
          name: "Group",
          participants: Enum.map([c1, c2, c3], &%{character_id: &1.id}),
          player_character_id: c1.id
        })

      {:ok, book} = Mythweaver.Lore.create_book(scope, %{name: "Bob's memories"})
      {:ok, view, _html} = live(conn, ~p"/chats/#{group.id}/memory?tab=characters")
      settings = fn -> Memory.chat_settings(scope, Chats.get_chat!(group.id)) end
      assert has_element?(view, "#memory-character-books-empty")

      add = fn character, lock ->
        view |> element("#memory-character-book-new") |> render_click()

        view
        |> form("#memory-character-book-form",
          memory_character_book: %{character_id: character.id, book_id: book.id, lock: lock}
        )
        |> render_submit()
      end

      add.(c2, "false")
      assert settings.().character_book_ids == %{c2.id => book.id}
      assert has_element?(view, "#memory-character-book-#{c2.id}", "Bob's memories")

      # Character books are not part of the settings form: saving the cast leaves them alone.
      render_patch(view, ~p"/chats/#{group.id}/memory?tab=settings")
      view |> form("#memory-settings-form", memory_settings: %{cast_ids: [c3.id]}) |> render_submit()
      assert settings.().cast_ids == [c3.id]
      assert settings.().character_book_ids == %{c2.id => book.id}
      render_patch(view, ~p"/chats/#{group.id}/memory?tab=characters")

      view |> element("#memory-character-lock-#{c2.id}", "Lock") |> render_click()
      assert CharacterBooks.character_lock(scope, c2.id).lore_book_id == book.id
      assert has_element?(view, "#memory-character-book-#{c2.id} .memory-badge", "Locked")
      assert has_element?(view, "#memory-character-lock-#{c2.id}", "Unlock")

      add.(c3, "true")
      assert CharacterBooks.character_lock(scope, c3.id).lore_book_id == book.id
      refute has_element?(view, "#memory-character-book-new")

      view |> element("#memory-character-book-delete-#{c2.id}") |> render_click()
      refute CharacterBooks.character_lock(scope, c2.id)
      refute Map.has_key?(settings.().character_book_ids, c2.id)
      refute has_element?(view, "#memory-character-book-#{c2.id}")

      view |> element("#memory-character-book-new") |> render_click()

      view
      |> form("#memory-character-book-form", memory_character_book: %{character_id: "", book_id: book.id})
      |> render_submit()

      assert has_element?(view, "#memory-character-book-error")
    end

    test "additional context entries list only the set ones and add or remove at once",
         %{scope: scope, conn: conn, chat: chat} do
      book = Memory.ensure_book(scope, chat)
      a = lore_entry!(scope, book, %{name: "Inn", keywords: ["inn"]})
      b = lore_entry!(scope, book, %{name: "Road", keywords: ["road"]})
      context_ids = fn -> Memory.chat_settings(scope, Chats.get_chat!(chat.id)).context_entry_ids end

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}/memory?tab=context")
      assert has_element?(view, "#memory-context-empty")

      view |> element("#memory-context-new") |> render_click()
      view |> form("#memory-context-form", memory_context: %{entry_ids: [a.id]}) |> render_submit()
      assert context_ids.() == [a.id]
      assert has_element?(view, "#memory-context-entry-#{a.id}")
      refute has_element?(view, "#memory-context-entry-#{b.id}")

      # Saving the settings form leaves the list alone.
      render_patch(view, ~p"/chats/#{chat.id}/memory?tab=settings")
      view |> form("#memory-settings-form", memory_settings: %{auto_interval: "12"}) |> render_submit()
      assert context_ids.() == [a.id]
      render_patch(view, ~p"/chats/#{chat.id}/memory?tab=context")

      view |> element("#memory-context-delete-#{a.id}") |> render_click()
      assert context_ids.() == []
      assert has_element?(view, "#memory-context-empty")
    end

    test "a lock whose book is no longer editable shows as broken until unlocked",
         %{scope: scope, conn: conn, chat: chat, c1: c1, c2: c2} do
      c3 = character(scope, "Cleo")

      {:ok, group} =
        Chats.create_chat(scope, %{
          name: "Group",
          participants: Enum.map([c1, c2, c3], &%{character_id: &1.id}),
          player_character_id: c1.id
        })

      group = Chats.get_chat!(group.id)
      {:ok, book} = Mythweaver.Lore.create_book(scope, %{name: "Bob's memories"})
      settings = Memory.chat_settings(scope, group)
      {:ok, _} = Memory.update_chat_settings(scope, settings, %{"character_book_ids" => %{c2.id => book.id}})
      {:ok, _} = CharacterBooks.lock_character_book(scope, group, c2.id)

      # The book goes to another user: Bob's lock, which follows him into the solo chat too, breaks.
      other = register_user!(%{role: :user})
      book |> Ecto.Changeset.change(user_id: other.id) |> Mythweaver.Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/chats/#{group.id}/memory?tab=characters")
      assert has_element?(view, "#memory-character-lock-broken-#{c2.id}", "no longer available")
      refute has_element?(view, "#memory-character-lock-broken-#{c3.id}")

      {:ok, solo_view, _html} = live(conn, ~p"/chats/#{chat.id}/memory?tab=settings")
      assert has_element?(solo_view, "#memory-settings-lock-broken", "no longer available")
      refute has_element?(solo_view, "#memory-settings-locked")

      view |> element("#memory-character-lock-#{c2.id}", "Unlock") |> render_click()
      assert render(view) =~ "Unlocked."
      refute has_element?(view, "#memory-character-lock-broken-#{c2.id}")
    end

    test "creating without review saves an entry and draws the boundary", %{scope: scope, conn: conn, chat: chat} do
      :ok = Mythweaver.Settings.put(scope, :site, "memory.show_previews", false)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}/memory")

      view
      |> form("#memory-create-form", memory_create: %{start: "1", end: "3", previous_count: "0"})
      |> render_submit()

      await_job_status(:completed)
      assert has_element?(view, "#memory-boundary", "Processed through #3")

      view |> element("#memory-tab-entries") |> render_click()
      assert has_element?(view, "[id^='memory-entry-']", "[001] - Inn")
    end

    test "the Memory button's meter counts toward the next automatic memory", %{scope: scope, conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      refute has_element?(view, "#chat-memory-progress")

      {:ok, _} =
        Memory.update_chat_settings(scope, Memory.chat_settings(scope, chat), %{
          auto_enabled: true,
          auto_interval: 50,
          auto_buffer: 0
        })

      Memory.broadcast_changed(chat.id)
      count = length(Messages.list_messages(chat))
      assert has_element?(view, "#chat-memory-progress[aria-valuenow='#{count}'][aria-valuemax='50']")

      {:ok, _} = Messages.send_message(scope, chat, chat.player_character_id, "One more")
      assert has_element?(view, "#chat-memory-progress[aria-valuenow='#{count + 1}']")
      assert has_element?(view, "#chat-memory-button[title='#{49 - count} messages until the next automatic memory']")
    end

    test "a running memory job is listed in progress", %{scope: scope, conn: conn, chat: chat} do
      test = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        send(test, :request_hanging)
        Process.sleep(:infinity)
        conn
      end)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}/memory")
      refute has_element?(view, "#memory-active-jobs")

      view
      |> form("#memory-create-form", memory_create: %{start: "1", end: "3", previous_count: "0"})
      |> render_submit()

      assert_receive :request_hanging, 2_000
      %{id: id} = Jobs.list_jobs(scope, chat_id: chat.id, statuses: [:running]) |> hd()

      eventually(fn -> assert has_element?(view, "#memory-active-jobs #memory-job-progress-#{id}") end)
      assert Jobs.cancel(scope, id) == :ok
    end

    test "a review job renders a card, and saving it completes the job", %{scope: scope, conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}/memory?tab=reviews")
      {:ok, job} = Memory.create_memory(scope, Chats.get_chat!(chat.id), 0, 2)
      await_job_status(:review)

      assert has_element?(view, "#memory-review-#{job.id}")
      assert has_element?(view, "#chat-memory-reviews", "1")
      # The reply as the model sent it, for copying a value it wrote outside its JSON.
      assert has_element?(view, "#memory-review-raw-text-#{job.id}", ~s("keywords": ["inn"]))

      # The draft's keywords are chips; one added (the TagInput hook posts the list on change) shows.
      assert has_element?(view, "#memory-review-keywords-#{job.id}-chips li[data-tag='inn']")
      keywords = %{"review" => %{"keywords" => ["", "inn", "tavern"]}}
      view |> form("#memory-review-#{job.id}") |> render_change(keywords)
      assert has_element?(view, "#memory-review-keywords-#{job.id}-chips li[data-tag='tavern']")

      view
      |> form("#memory-review-#{job.id}", review: %{title: "Edited", content: "C"})
      |> render_submit(keywords)

      assert Jobs.get_job(scope, job.id).status == :completed
      refute has_element?(view, "#memory-review-#{job.id}")
      view |> element("#memory-tab-entries") |> render_click()
      assert has_element?(view, "[id^='memory-entry-']", "[001] - Edited")
    end

    test "a review refused because its messages changed offers Save anyway, which saves it",
         %{scope: scope, conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}/memory?tab=reviews")
      {:ok, job} = Memory.create_memory(scope, Chats.get_chat!(chat.id), 0, 2)
      await_job_status(:review)

      [first | _] = Messages.list_messages(chat)
      {:ok, _} = Messages.add_edited_body(scope, first, %{content: "Something else happened."})

      refute has_element?(view, "#memory-review-force-#{job.id}")
      view |> form("#memory-review-#{job.id}") |> render_submit()
      assert has_element?(view, "#memory-review-error-#{job.id}")
      assert has_element?(view, "#memory-review-force-#{job.id}")

      view |> form("#memory-review-#{job.id}") |> render_submit(%{"ignore_changes" => "true"})

      assert Jobs.get_job(scope, job.id).status == :completed
      refute has_element?(view, "#memory-review-#{job.id}")
    end

    test "#bulk-create-memory opens the panel on the selected span", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      [_first, second, third] = Messages.list_messages(chat)

      for message <- [second, third] do
        view |> element("#message-select-#{message.id}") |> render_click()
      end

      view |> element("#bulk-create-memory") |> render_click()

      assert_patch(view, ~p"/chats/#{chat.id}/memory?start=2&end=3")
      assert has_element?(view, "#memory-create-start[value='2']")
      refute has_element?(view, "#message-bulk-actions")
    end

    defp text_reply(text) do
      Req.Test.stub(Mythweaver.AI, fn conn ->
        frames = [
          "data: #{Jason.encode!(%{choices: [%{index: 0, delta: %{content: text}, finish_reason: nil}]})}\n\n",
          "data: [DONE]\n\n"
        ]

        Enum.reduce(frames, Plug.Conn.send_chunked(conn, 200), fn frame, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, frame)
          conn
        end)
      end)
    end

    defp saved_memories!(scope, chat, ranges) do
      for {first, last} <- ranges do
        {:ok, _job} = Memory.create_memory(scope, chat, first, last, review: false)
        await_job_status(:completed)
      end

      Memory.list_records(scope, Memory.chat_settings(scope, chat).memory_book_id)
    end

    defp set_profile_prompt!(scope, field, purpose) do
      {:ok, prompt} = Prompts.create_prompt(scope, %{name: "Test #{purpose}", purpose: purpose})

      {:ok, block} =
        Prompts.create_block(scope, %{name: "Material #{purpose}", role: :user, content: "{{ anchors.memory.kind }}"})

      {:ok, _} = Prompts.add_block(scope, prompt, block)
      {:ok, _} = Memory.update_profile(scope, Memory.default_profile(scope), %{field => prompt.id})
    end

    test "the Consolidate tab queues a reviewed consolidation that saves the kept summary", %{
      scope: scope,
      conn: conn,
      chat: chat
    } do
      chat = Chats.get_chat!(chat.id)
      [one, two] = saved_memories!(scope, chat, [{0, 0}, {1, 2}])
      set_profile_prompt!(scope, :consolidation_prompt_id, :consolidation)

      text_reply(
        Jason.encode!(%{
          summaries: [%{title: "Arrival", summary: "They arrived.", keywords: ["inn"], member_ids: ["001", "002"]}],
          unassigned_items: []
        })
      )

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}/memory?tab=consolidate")
      assert has_element?(view, "#memory-consolidate-sources-#{one.id}[checked]")
      assert has_element?(view, "#memory-consolidate-sources-#{two.id}[checked]")
      assert has_element?(view, "#memory-consolidate-passes", "1 pass")

      view |> form("#memory-consolidate-form") |> render_submit()
      %{id: job_id} = await_job_status(:review)

      view |> element("#memory-tab-reviews") |> render_click()
      assert has_element?(view, "#memory-review-candidate-#{job_id}-0", "[001] - Inn")

      view
      |> form("#memory-review-#{job_id}", review: %{candidates: %{"0" => %{title: "Edited arc"}}})
      |> render_submit()

      assert Jobs.get_job(scope, job_id).status == :completed
      view |> element("#memory-tab-entries") |> render_click()
      assert has_element?(view, "[id^='memory-entry-']", "[ARC 001] - Edited arc")
      assert has_element?(view, "#memory-entry-#{one.id}", "Disabled")
      refute has_element?(view, "#memory-entry-regenerate-#{one.id}")
    end

    test "the Consolidate tab keeps the sources the picker posts", %{scope: scope, conn: conn, chat: chat} do
      [one, two] = saved_memories!(scope, Chats.get_chat!(chat.id), [{0, 0}, {1, 2}])
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}/memory?tab=consolidate")

      view
      |> form("#memory-consolidate-form", memory_consolidate: %{sources: [one.id]})
      |> render_change()

      assert has_element?(view, "#memory-consolidate-sources-#{one.id}[checked]")
      refute has_element?(view, "#memory-consolidate-sources-#{two.id}[checked]")
    end

    test "the Entries tab lists the newest memory first", %{scope: scope, conn: conn, chat: chat} do
      [older, newer] = saved_memories!(scope, Chats.get_chat!(chat.id), [{0, 0}, {1, 2}])

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}/memory?tab=entries")

      ids =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("li.memory-entry")
        |> LazyHTML.attribute("id")

      assert ids == ["memory-entry-#{newer.id}", "memory-entry-#{older.id}"]
    end

    test "compacting an entry reviews the draft beside the original", %{scope: scope, conn: conn, chat: chat} do
      [record] = saved_memories!(scope, Chats.get_chat!(chat.id), [{0, 2}])
      set_profile_prompt!(scope, :compaction_prompt_id, :compaction)
      text_reply("  Met at the inn.  ")

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}/memory?tab=entries")
      view |> element("#memory-entry-compact-#{record.id}") |> render_click()
      %{id: job_id} = await_job_status(:review)

      view |> element("#memory-tab-reviews") |> render_click()
      assert has_element?(view, "#memory-review-original-#{job_id}", "They met at the inn.")
      assert has_element?(view, "#memory-review-#{job_id}", "tokens")

      view |> form("#memory-review-#{job_id}") |> render_submit()
      assert Lore.get_entry!(record.lore_entry_id).content == "Met at the inn."
    end

    test "Regenerate over the token warning asks first, then queues on confirm", %{scope: scope, conn: conn, chat: chat} do
      [record] = saved_memories!(scope, Chats.get_chat!(chat.id), [{0, 2}])
      # Below the setting's 1000 floor (stored directly, past validation), so every prompt is over it.
      Mythweaver.Repo.insert!(%Setting{values: %{"memory.token_warning_threshold" => 1}})
      memory_jobs = fn -> Jobs.list_jobs(scope, tags: [:memory]) end
      before = length(memory_jobs.())

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}/memory?tab=entries")
      view |> element("#memory-entry-regenerate-#{record.id}") |> render_click()
      assert has_element?(view, "#memory-regenerate-warning")
      assert length(memory_jobs.()) == before

      view |> element("#memory-entry-regenerate-confirm") |> render_click()
      assert Enum.any?(memory_jobs.(), &(&1.params["record_id"] == record.id))
    end

    test "a clip selection opens the dialog, and saving it creates a clip", %{scope: scope, conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      [first | _] = Messages.list_messages(chat)

      view
      |> element("#clip-selection")
      |> render_hook("clip_selection", %{"text" => " the\ninn ", "message_id" => first.id})

      assert has_element?(view, "#clip-dialog")
      assert has_element?(view, "#clip-title")

      view |> form("#clip-form", clip: %{title: "Places", activation: "keyword"}) |> render_submit()

      refute has_element?(view, "#clip-dialog")
      [record] = Memory.list_records(scope, Memory.chat_settings(scope, chat).memory_book_id)
      assert record.kind == :clip
      assert record.entry.content == "=== Places ===\n\n- the inn\n\n=== END Places ==="
      assert record.entry.keywords == ["Places"]
    end

    test "the topical tab's picker queues a clip of just the picked messages", %{scope: scope, conn: conn, chat: chat} do
      set_profile_prompt!(scope, :topical_clip_prompt_id, :topical_clip)
      text_reply("Clip text.")
      [first, second, third] = Messages.list_messages(chat)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}/memory?tab=topical")

      view
      |> form("#memory-topical-form",
        memory_topical: %{topic: "Inn", include_memories: "false", include_messages: "true"}
      )
      |> render_change()

      view
      |> form("#memory-topical-form", memory_topical: %{message_mode: "pick"})
      |> render_change()

      refute has_element?(view, "#memory-topical-start")
      assert has_element?(view, "#memory-picker")
      view |> form("#memory-picker-form", memory_picker: %{query: ""}) |> render_change()
      assert has_element?(view, "#memory-picker-result-#{second.id}")

      view |> element("#memory-picker-toggle-#{first.id}") |> render_click()
      view |> element("#memory-picker-toggle-#{third.id}") |> render_click()
      assert has_element?(view, "#memory-topical-picked", "2 messages picked: #1, #3")

      view |> form("#memory-topical-form") |> render_submit()

      assert %{id: id} = await_job_status(:review)
      job = Jobs.get_job(scope, id)
      assert job.tag == :topical_clip
      assert Enum.sort(job.params["messages"]["message_ids"]) == Enum.sort([first.id, third.id])
    end

    test "a shift-click range in the topical picker picks every shown message in it", %{conn: conn, chat: chat} do
      [first, second, _third] = Messages.list_messages(chat)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}/memory?tab=topical")

      view
      |> form("#memory-topical-form",
        memory_topical: %{topic: "Inn", include_memories: "false", include_messages: "true"}
      )
      |> render_change()

      view |> form("#memory-topical-form", memory_topical: %{message_mode: "pick"}) |> render_change()
      view |> form("#memory-picker-form", memory_picker: %{query: ""}) |> render_change()

      # An id the picker does not show is ignored.
      view
      |> element("#memory-picker-results")
      |> render_hook("memory_picker_select_range", %{
        "ids" => [first.id, second.id, Mythweaver.Schema.generate_id()]
      })

      assert has_element?(view, "#memory-topical-picked", "2 messages picked: #1, #2")
      assert has_element?(view, "#memory-picker-toggle-#{second.id}[checked]")
    end

    test "Extract opens the topical picker searched for the text with its message picked", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      message = Enum.find(Messages.list_messages(chat), &(Scene.content(&1) =~ "inn"))

      view
      |> element("#clip-selection")
      |> render_hook("clip_extract", %{"text" => " the inn ", "message_id" => message.id})

      assert_patch(
        view,
        ~p"/chats/#{chat.id}/memory?#{%{tab: "topical", extract: "the inn", extract_message: message.id}}"
      )

      assert has_element?(view, "#memory-topical-topic[value='the inn']")
      assert has_element?(view, "#memory-picker-result-#{message.id}")
      assert has_element?(view, "#memory-topical-picked", "1 message picked: ##{message.position + 1}")
    end

    test "the topical tab lists pending topic suggestions to draft or dismiss", %{scope: scope, conn: conn, chat: chat} do
      chat = Chats.get_chat!(chat.id)
      [record] = saved_memories!(scope, chat, [{0, 2}])
      set_profile_prompt!(scope, :topical_clip_prompt_id, :topical_clip)
      text_reply("Clip text.")
      message_ids = Enum.map(Messages.list_messages(chat), & &1.id)
      inn = topic_suggestion!(chat, record, "The inn", ["inn", "tavern"], message_ids)
      cellar = topic_suggestion!(chat, record, "The cellar", [], [])

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}/memory?tab=topical")
      assert has_element?(view, "#memory-topic-suggestions", "Suggested topics")
      assert has_element?(view, "#memory-topic-suggestion-#{inn.id}", "inn, tavern")
      assert has_element?(view, "#memory-topic-suggestion-#{inn.id}", Lore.get_book!(record.lore_book_id).name)

      view |> element("#memory-topic-suggestion-draft-#{inn.id}") |> render_click()
      assert [job] = Jobs.list_jobs(scope, tags: [:topical_clip])
      assert job.params["suggestion_id"] == inn.id
      assert job.params["snapshot"]["messages"]["message_ids"] == message_ids
      assert has_element?(view, "#memory-topic-suggestion-draft-#{inn.id}[disabled]", "Drafting…")
      await_job_status(:review)

      view |> element("#memory-topic-suggestion-dismiss-#{cellar.id}") |> render_click()
      refute has_element?(view, "#memory-topic-suggestion-#{cellar.id}")
      assert has_element?(view, "#memory-topic-suggestion-#{inn.id}")
    end

    defp topic_suggestion!(chat, record, topic, keywords, message_ids) do
      Mythweaver.Repo.insert!(%TopicSuggestion{
        chat_id: chat.id,
        lore_book_id: record.lore_book_id,
        topic: topic,
        keywords: keywords,
        record_id: record.id,
        message_ids: message_ids
      })
    end

    test "a chat set to a side prompt set lists its rows on the side tab and runs them", %{
      scope: scope,
      conn: conn,
      chat: chat
    } do
      {:ok, prompt} = Prompts.create_prompt(scope, %{name: "Side: NPC", purpose: :side_prompt})
      {:ok, side} = Memory.create_side_prompt(scope, %{name: "NPC", prompt_id: prompt.id, macros: ["npc"]})

      {:ok, set} =
        Memory.create_side_prompt_set(scope, %{
          name: "Cast",
          rows: [%{side_prompt_id: side.id, label: "Alice", macro_values: %{"npc" => "Alice"}}]
        })

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}/memory?tab=settings")
      refute has_element?(view, "#memory-settings-side-set")
      view |> form("#memory-settings-form", memory_settings: %{side_prompt_set_mode: "set"}) |> render_change()

      view
      |> form("#memory-settings-form", memory_settings: %{side_prompt_set_mode: "set", side_prompt_set_id: set.id})
      |> render_submit()

      assert %{side_prompt_set_mode: :set} = Memory.chat_settings(scope, Chats.get_chat!(chat.id))

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}/memory?tab=side")
      assert has_element?(view, "#memory-side-macro-#{side.id}-npc")
      [row] = Memory.get_editable_side_prompt_set(scope, set.id).rows
      assert has_element?(view, "#memory-side-set-row-#{row.id}", "Alice")

      # A manual run without the macro is refused inline.
      view |> form("#memory-side-#{side.id}") |> render_submit()
      assert has_element?(view, "#memory-side-error-#{side.id}", "Fill in every macro this side prompt uses.")

      view |> element("#memory-side-run-row-#{row.id}") |> render_click()
      assert %{tag: :side_prompt, id: id} = await_job_status(:queued)
      assert %{"set_row_id" => row_id, "macros" => %{"npc" => "Alice"}} = Jobs.get_job(scope, id).params
      assert row_id == row.id
    end
  end

  describe "Mythweaver assistant" do
    # A fresh admin with no role-play chats, logged in, so `/` is the landing. The runner and its AI
    # task run under the generation supervisor, outside the test's `$callers`.
    setup context do
      Req.Test.set_req_test_to_shared(context)
      owner = Mythweaver.DataCase.scope!()
      %{conn: log_in_user(Phoenix.ConnTest.build_conn(), owner.user), owner: owner}
    end

    defp assistant_chat!(scope) do
      {:ok, chat} = Mythweaver.Assistant.create_chat(scope)
      chat
    end

    defp tool_model!(scope, attrs \\ %{}) do
      {:ok, provider} =
        AI.create_provider(scope, %{
          name: "Local-#{System.unique_integer([:positive])}",
          adapter: :openai_compatible,
          base_url: "http://localhost:8080/v1"
        })

      {:ok, model} =
        AI.create_model(
          scope,
          Map.merge(
            %{name: "Gemma-#{System.unique_integer([:positive])}", api_model_id: "g", supports_tools: true},
            attrs
          )
        )

      {:ok, _link} = AI.link_model(scope, provider, model)
      provider
    end

    defp sse(conn, delta) do
      conn = Plug.Conn.send_chunked(conn, 200)

      Enum.reduce(
        [
          "data: #{Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => delta}]})}\n\n",
          ~s(data: {"choices":[{"finish_reason":"stop","index":0,"delta":{}}]}\n\n),
          "data: [DONE]\n\n"
        ],
        conn,
        fn frame, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, frame)
          conn
        end
      )
    end

    # Answers with `name`'s call until a tool result is in the request, then with `text`.
    defp stub_tool_then_text(name, arguments, text) do
      Req.Test.stub(Mythweaver.AI, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        if Enum.any?(Jason.decode!(raw)["messages"], &(&1["role"] == "tool")) do
          sse(conn, %{"content" => text})
        else
          call = %{"index" => 0, "id" => "c1", "function" => %{"name" => name, "arguments" => Jason.encode!(arguments)}}
          sse(conn, %{"tool_calls" => [call]})
        end
      end)
    end

    defp await_runner(chat) do
      case Registry.lookup(Mythweaver.Generation.Registry, {:assistant, chat.id}) do
        [{pid, _}] ->
          ref = Process.monitor(pid)
          assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000

        [] ->
          :ok
      end
    end

    defp only_call(chat), do: chat.id |> Mythweaver.Assistant.list_tool_calls() |> Map.values() |> List.flatten()

    test "with no role-play chats, / is the landing, and sending opens a thread", %{conn: conn, owner: owner} do
      tool_model!(owner)
      Req.Test.stub(Mythweaver.AI, &sse(&1, %{"content" => "Hello from Mythweaver"}))

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#assistant-landing")
      refute has_element?(view, "#assistant-model-notice")

      view |> form("#message-composer", composer: %{content: "Hi"}) |> render_submit()
      [chat] = Chats.list_chats(owner, :assistant)
      assert_patch(view, ~p"/chats/#{chat.id}")
      await_runner(chat)

      assert has_element?(view, "#chats-#{chat.id} .chat-picker-kind")
      assert has_element?(view, "#assistant-messages", "Hello from Mythweaver")
      assert has_element?(view, "#assistant-messages .assistant-message.you", "Hi")
    end

    test "the landing says when no model can run Mythweaver", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#assistant-model-notice")
      assert has_element?(view, "#composer-send[disabled]")
      refute has_element?(view, "#composer-attach")
    end

    test "the landing gear picks the model the first message's thread runs on", %{conn: conn, owner: owner} do
      tool_model!(owner, %{api_model_id: "a"})
      tool_model!(owner, %{api_model_id: "b"})
      b = Enum.find(AI.list_models(owner), &(&1.api_model_id == "b"))
      test = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:model, Jason.decode!(raw)["model"]})
        sse(conn, %{"content" => "Hi"})
      end)

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#assistant-model-notice")

      view |> element("#assistant-landing-settings") |> render_click()

      view
      |> form("#assistant-landing-settings-form", assistant_landing: %{ai_model_id: b.id})
      |> render_change()

      refute has_element?(view, "#assistant-model-notice")
      assert has_element?(view, "#assistant-landing-settings", b.name)

      view |> form("#message-composer", composer: %{content: "Hi"}) |> render_submit()
      [chat] = Chats.list_chats(owner, :assistant)
      assert chat.ai_model_id == b.id
      await_runner(chat)
      assert_receive {:model, "b"}
    end

    test "the thread's settings modal saves its name and model", %{conn: conn, owner: owner} do
      tool_model!(owner)
      tool_model!(owner, %{api_model_id: "b"})
      b = Enum.find(AI.list_models(owner), &(&1.api_model_id == "b"))
      chat = assistant_chat!(owner)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      view |> element("#assistant-settings-button") |> render_click()
      assert_patch(view, ~p"/chats/#{chat.id}/settings")
      assert has_element?(view, "#assistant-settings-modal")

      view
      |> form("#assistant-settings-form", assistant_settings: %{name: "Setup help", ai_model_id: b.id})
      |> render_submit()

      assert_patch(view, ~p"/chats/#{chat.id}")
      assert %{ai_model_id: model_id, name: "Setup help"} = Chats.get_chat(chat.id)
      assert model_id == b.id
      refute has_element?(view, "#assistant-settings-modal")
    end

    test "approving a pending create_characters card creates it and links to it", %{conn: conn, owner: owner} do
      tool_model!(owner)
      chat = assistant_chat!(owner)
      stub_tool_then_text("create_characters", %{"items" => [%{"name" => "Test Bard"}]}, "Created.")
      {:ok, _} = Mythweaver.Assistant.send_message(owner, chat, "Make a bard")
      await_runner(chat)
      [call] = only_call(chat)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      view |> element("#tool-call-approve-#{call.id}") |> render_click()
      await_runner(chat)

      [bard] = Characters.list_characters(owner) |> Enum.filter(&(&1.name == "Test Bard"))
      assert has_element?(view, "#tool-call-open-#{call.id}[href='/characters/#{bard.id}/edit']")
      assert has_element?(view, "#tool-call-#{call.id} .tool-card-character", "Test Bard")
      assert has_element?(view, "#assistant-messages", "Created.")
    end

    test "Compact streams a summary message into the thread", %{conn: conn, owner: owner} do
      tool_model!(owner)
      chat = assistant_chat!(owner)

      Req.Test.stub(Mythweaver.AI, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        last = List.last(Jason.decode!(raw)["messages"])["content"]

        if last == Prompt.compaction_request(),
          do: sse(conn, %{"content" => "SUMMARY-TEXT"}),
          else: sse(conn, %{"content" => "Hello"})
      end)

      {:ok, _} = Mythweaver.Assistant.send_message(owner, chat, "Hi")
      await_runner(chat)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      view |> element("#assistant-compact") |> render_click()
      await_runner(chat)

      assert has_element?(view, "#assistant-messages .assistant-message.summary", "SUMMARY-TEXT")
    end

    test "a batch delete card names each row before approval and deletes them on approve", %{conn: conn, owner: owner} do
      tool_model!(owner)
      chat = assistant_chat!(owner)
      {:ok, castle} = Characters.create_character(owner, %{name: "Castle Guard"})
      {:ok, river} = Characters.create_character(owner, %{name: "River Witch"})
      stub_tool_then_text("delete_characters", %{"ids" => [castle.id, river.id]}, "Deleted.")
      {:ok, _} = Mythweaver.Assistant.send_message(owner, chat, "Delete both")
      await_runner(chat)
      [call] = only_call(chat)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      assert has_element?(view, "#tool-call-#{call.id} .tool-card-summary", "Delete 2 characters")
      assert has_element?(view, "#tool-call-preview-#{call.id} li", "Castle Guard")
      assert has_element?(view, "#tool-call-preview-#{call.id} li", "River Witch")

      view |> element("#tool-call-approve-#{call.id}") |> render_click()
      await_runner(chat)

      refute Characters.get_character(owner, castle.id)
      refute Characters.get_character(owner, river.id)
      refute has_element?(view, "#tool-call-preview-#{call.id}")
      assert has_element?(view, "#assistant-messages", "Deleted.")
    end

    test "the key card saves the key onto the connection", %{conn: conn, owner: owner} do
      provider = tool_model!(owner)
      chat = assistant_chat!(owner)
      stub_tool_then_text("request_api_key", %{"connection_id" => provider.id}, "Saved.")
      {:ok, _} = Mythweaver.Assistant.send_message(owner, chat, "Set the key")
      await_runner(chat)
      [call] = only_call(chat)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      view |> form("#tool-call-key-form-#{call.id}", key: %{api_key: "sk-test"}) |> render_submit()
      await_runner(chat)

      assert AI.get_provider(owner, provider.id).api_key == "sk-test"
      refute render(view) =~ "sk-test"
    end

    test "the shared composer attaches an image that reaches a vision model", %{conn: conn, owner: owner} do
      tool_model!(owner, %{supports_images: true})
      chat = assistant_chat!(owner)
      test = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:request, Jason.decode!(raw)})
        sse(conn, %{"content" => "A fox."})
      end)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      assert has_element?(view, "#assistant-chat #composer-attach")

      view
      |> file_input("#message-composer", :composer_files, [%{name: "fox.png", content: png(), type: "image/png"}])
      |> render_upload("fox.png")

      view |> form("#message-composer", composer: %{content: "What is this?"}) |> render_submit()
      await_runner(chat)

      assert_received {:request, %{"messages" => messages}}

      assert [%{"type" => "text", "text" => "What is this?"}, %{"type" => "image_url"}] =
               List.last(Enum.filter(messages, &(&1["role"] == "user")))["content"]

      assert has_element?(view, "#assistant-messages", "A fox.")
      assert has_element?(view, "#assistant-messages .assistant-message.you img")
    end

    test "the command palette offers no chat commands on a thread", %{owner: owner} do
      chat = assistant_chat!(owner)
      ids = fn chat -> owner |> Commands.list(chat) |> Enum.map(& &1.id) end
      assert ids.(chat) == ids.(nil)
    end
  end

  describe "reporting" do
    # `chat` with `guest` and `other` as accepted guests, logged in as `guest`; a message from
    # the owner and one from the guest.
    setup %{user: owner, chat: chat, c1: c1} do
      owner_scope = Scope.for_user(owner)
      guest = register_user!(%{role: :user})
      other = register_user!(%{role: :user})

      for member <- [guest, other] do
        {:ok, invite} = Chats.invite(owner_scope, chat, member.handle, :guest)
        {:ok, _} = Chats.accept_invite(Scope.for_user(member), invite.id)
      end

      [owner_message, guest_message] =
        for author <- [owner, guest] do
          {:ok, message} =
            Messages.create_message(chat, %{
              author_is_character: true,
              author_character_id: c1.id,
              bodies: [%{content: "From #{author.handle}"}]
            })

          # `author_user_id` is set only by `Messages.send_message/5`, which would start a reply.
          message |> Ecto.Changeset.change(author_user_id: author.id) |> Repo.update!()
        end

      ai_message = add_message(chat, c1, "An AI line")

      %{
        guest: guest,
        other: other,
        guest_conn: log_in_user(build_conn(), guest),
        owner_message: owner_message,
        guest_message: guest_message,
        ai_message: ai_message
      }
    end

    defp member_id(chat, user), do: Repo.get_by!(Member, chat_id: chat.id, user_id: user.id).id

    test "a guest reports others' messages but not their own", context do
      {:ok, view, _html} = live(context.guest_conn, ~p"/chats/#{context.chat.id}")

      assert has_element?(view, "#message-report-#{context.owner_message.id}")
      assert has_element?(view, "#message-report-#{context.ai_message.id}")
      refute has_element?(view, "#message-report-#{context.guest_message.id}")
    end

    test "submitting the dialog files one message report; a repeat is refused", context do
      %{guest: guest, owner_message: message} = context
      {:ok, view, _html} = live(context.guest_conn, ~p"/chats/#{context.chat.id}")

      view |> element("#message-report-#{message.id}") |> render_click()
      view |> form("#report-form", report: %{reason: "x"}) |> render_submit()

      refute has_element?(view, "#report-modal")

      assert [%Report{subject_type: :message, subject_id: subject_id, reporter_id: reporter_id}] =
               Repo.all(Report)

      assert {subject_id, reporter_id} == {message.id, guest.id}

      view |> element("#message-report-#{message.id}") |> render_click()
      html = view |> form("#report-form", report: %{reason: "again"}) |> render_submit()

      assert html =~ "You have already reported this"
      assert Repo.aggregate(Report, :count) == 1
    end

    test "an editor sees Report on member rows except the viewer's own, filing a :user report", context do
      %{chat: chat, guest: guest, other: other} = context
      # Only an owner or editor opens the settings' member list.
      Member
      |> Repo.get_by!(chat_id: chat.id, user_id: guest.id)
      |> Ecto.Changeset.change(role: :editor)
      |> Repo.update!()

      {:ok, view, _html} = live(context.guest_conn, ~p"/chats/#{chat.id}/settings")
      render_click(view, "chat_settings_tab", %{"tab" => "members"})

      refute has_element?(view, "#chat-member-report-#{member_id(chat, guest)}")

      view |> element("#chat-member-report-#{member_id(chat, other)}") |> render_click()
      view |> form("#report-form", report: %{reason: "x"}) |> render_submit()

      assert [%Report{subject_type: :user, subject_id: subject_id}] =
               Repo.all(Report)

      assert subject_id == other.id
    end

    test "without reports.create no message offers Report", context do
      Mythweaver.Permissions.put_grant!(context.guest, "reports.create", :deny)
      {:ok, view, _html} = live(context.guest_conn, ~p"/chats/#{context.chat.id}")

      refute has_element?(view, "[id^=message-report-]")
    end
  end
end
