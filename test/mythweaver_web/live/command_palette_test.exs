defmodule MythweaverWeb.CommandPaletteTest do
  # Not async: command scripts run in a `start_async` task that reaches the DB through the shared
  # sandbox.
  use MythweaverWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.Attachments
  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Memory
  alias Mythweaver.Messages
  alias Mythweaver.Prompts
  alias Mythweaver.Scripts

  setup :register_and_log_in_user

  defp character!(scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: "#{name}-#{System.unique_integer([:positive])}"})
    character
  end

  defp chat!(scope, user) do
    [player, bot] = [character!(scope, "Player"), character!(scope, "Bot")]

    {:ok, chat} =
      Chats.create_chat(Scope.for_user(user), %{
        name: "chat-#{System.unique_integer([:positive])}",
        participants: [%{character_id: player.id}, %{character_id: bot.id}],
        player_character_id: player.id
      })

    chat
  end

  defp command!(scope, name, body) do
    {:ok, script} = Scripts.create_script(scope, %{name: name, trigger: :command, body: body})
    script
  end

  defp open(view, recent \\ []), do: view |> element("#command-palette") |> render_hook("toggle", %{"recent" => recent})
  defp query(view, text), do: view |> form("#command-palette-form", %{"query" => text}) |> render_change()

  defp key(view, key, shift \\ false),
    do: view |> element("#command-palette-dialog") |> render_hook("key", %{"key" => key, "shift" => shift})

  defp type_arg(view, i, text),
    do: view |> form("#command-palette-args", %{"args" => %{"#{i}" => text}}) |> render_change()

  test "an edit command picks an item, then opens its page", %{scope: scope, conn: conn} do
    {:ok, model} = AI.create_model(scope, %{name: "Gemma", api_model_id: "gemma-4"})
    {:ok, view, _html} = live(conn, ~p"/characters/new")

    open(view)
    query(view, "model")
    assert has_element?(view, "[data-command-id='ai_model.edit']")

    query(view, "model edit")
    assert has_element?(view, "#command-palette-result-0[data-command-id='ai_model.edit']")
    key(view, "Enter")

    assert has_element?(view, "#command-palette-arg-0")
    assert has_element?(view, "#command-palette-suggestion-0", "Gemma")

    key(view, "Enter")
    assert_redirect(view, "/ai/models/#{model.id}/edit")
  end

  test "generate reply offers the player as a speaker; play as does not", %{scope: scope, conn: conn, user: user} do
    chat = Chats.get_chat!(chat!(scope, user).id)
    player = Enum.find(chat.participants, &(&1.character_id == chat.player_character_id)).character
    bot = Enum.find(chat.participants, &(&1.character_id != chat.player_character_id)).character
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    open(view)
    query(view, "generate reply")
    key(view, "Enter")
    assert has_element?(view, "#command-palette-suggestions", player.name)
    assert has_element?(view, "#command-palette-suggestions .command-palette-detail", "You")
    assert has_element?(view, "#command-palette-suggestions", bot.name)

    key(view, "Escape")
    query(view, "play as")
    key(view, "Enter")
    refute has_element?(view, "#command-palette-suggestions", player.name)
    assert has_element?(view, "#command-palette-suggestions", bot.name)
  end

  test "character pickers list unmuted first in panel order; toggle mute keeps panel order",
       %{scope: scope, conn: conn, user: user} do
    [player, a, b, c] = for name <- ~w(Player A B C), do: character!(scope, name)

    {:ok, chat} =
      Chats.create_chat(Scope.for_user(user), %{
        name: "chat-#{System.unique_integer([:positive])}",
        participants: for(ch <- [player, a, b, c], do: %{character_id: ch.id}),
        player_character_id: player.id
      })

    chat = Chats.get_chat!(chat.id)
    by_char = Map.new(chat.participants, &{&1.character_id, &1})
    {:ok, _} = Chats.reorder_participants(scope, chat, for(ch <- [player, c, b, a], do: by_char[ch.id].id))
    {:ok, _} = Chats.update_participant(scope, by_char[b.id], %{muted: true})
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    assert_order = fn characters ->
      for {ch, i} <- Enum.with_index(characters),
          do: assert(has_element?(view, "#command-palette-suggestion-#{i}", ch.name))

      refute has_element?(view, "#command-palette-suggestion-#{length(characters)}")
    end

    open(view)
    query(view, "generate reply")
    key(view, "Enter")
    assert_order.([player, c, a, b])

    key(view, "Escape")
    query(view, "play as")
    key(view, "Enter")
    assert_order.([c, a, b])

    key(view, "Escape")
    query(view, "toggle mute")
    view |> element("[data-command-id='chat.toggle_mute']") |> render_click()
    assert_order.([c, b, a])
  end

  test "recent commands come first, marked", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/characters/new")

    open(view, ["jobs.open"])
    assert has_element?(view, "#command-palette-result-0[data-command-id='jobs.open'] .command-palette-recent")
    refute has_element?(view, "#command-palette-result-1 .command-palette-recent")
  end

  test "Escape goes back to the list, then closes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/characters/new")

    open(view)
    query(view, "character edit")
    key(view, "Enter")
    assert has_element?(view, "#command-palette-arg-0")

    key(view, "Escape")
    assert has_element?(view, "#command-palette-results")
    assert has_element?(view, "#command-palette-input[value='character edit']")

    key(view, "Escape")
    refute has_element?(view, "#command-palette-dialog")
  end

  test "chat commands appear only on a chat page and run its events", %{scope: scope, conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/characters/new")
    open(view)
    refute has_element?(view, "[data-command-id='chat.variables']")

    chat = chat!(scope, user)
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    open(view)
    query(view, "chat: variables")
    key(view, "Enter")

    refute has_element?(view, "#command-palette-dialog")
    assert has_element?(view, "#chat-variables")
  end

  test "the muted participants commands hide, show and toggle muted rows", %{scope: scope, conn: conn, user: user} do
    chat = Chats.get_chat!(chat!(scope, user).id)
    bot = Enum.find(chat.participants, &(&1.character_id != chat.player_character_id))
    {:ok, _} = Chats.update_participant(scope, bot, %{muted: true})
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    run = fn id ->
      open(view)
      query(view, "muted participants")
      view |> element("[data-command-id='#{id}']") |> render_click()
    end

    run.("chat.hide_muted")
    assert_push_event(view, "hide_muted", %{hide: true})
    assert has_element?(view, "#participant-#{bot.id}[hidden]")

    run.("chat.show_muted")
    assert_push_event(view, "hide_muted", %{hide: false})
    refute has_element?(view, "#participant-#{bot.id}[hidden]")

    run.("chat.toggle_muted_visibility")
    assert_push_event(view, "hide_muted", %{hide: true})
    assert has_element?(view, "#participant-#{bot.id}[hidden]")
  end

  test "a Lua command gets its entity argument and shows its notice", %{scope: scope, conn: conn} do
    ana = character!(scope, "Ana")
    command!(scope, "Greet", "---@param who character Who\nreturn \"Hello \" .. event.args.who.name")
    {:ok, view, _html} = live(conn, ~p"/characters/new")

    open(view)
    query(view, "greet")
    key(view, "Enter")
    type_arg(view, 0, ana.name)
    key(view, "Enter")
    render_async(view)

    assert has_element?(view, "#flash-info", "Hello #{ana.name}")
    refute has_element?(view, "#command-palette-dialog")
  end

  test "a Lua command's bad argument keeps the palette open with the error", %{scope: scope, conn: conn} do
    command!(scope, "Count", "---@param n integer N\nreturn n")
    {:ok, view, _html} = live(conn, ~p"/characters/new")

    open(view)
    query(view, "count")
    key(view, "Enter")
    type_arg(view, 0, "abc")
    key(view, "Enter")

    assert has_element?(view, "#command-palette-dialog")
    assert has_element?(view, "#command-palette-args", "Must be a whole number.")
  end

  test "a Lua command with a participant parameter is offered only in a chat", %{scope: scope, conn: conn, user: user} do
    script = command!(scope, "Nudge", "---@param who participant Who\nreturn nil")
    selector = "[data-command-id='script:#{script.id}']"

    {:ok, view, _html} = live(conn, ~p"/characters/new")
    open(view)
    refute has_element?(view, selector)

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat!(scope, user).id}")
    open(view)
    assert has_element?(view, selector)
  end

  test "a quick reply is offered only in a chat and asks the composer for its text", %{
    scope: scope,
    conn: conn,
    user: user
  } do
    {:ok, script} = Scripts.create_script(scope, %{name: "Wave", trigger: :quick_reply, body: "return nil"})
    selector = "[data-command-id='quick_reply:#{script.id}']"
    id = script.id

    {:ok, view, _html} = live(conn, ~p"/characters/new")
    open(view)
    refute has_element?(view, selector)

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat!(scope, user).id}")
    open(view)
    query(view, "quick reply")
    assert has_element?(view, selector)
    key(view, "Enter")

    assert_push_event(view, "quick_reply:collect", %{id: ^id})
  end

  describe "chat: caption image" do
    defp png,
      do:
        Base.decode64!(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        )

    # A non-vision chat model whose caption model can see; each request's body comes to the test.
    defp captioner!(scope, chat) do
      {:ok, provider} =
        AI.create_provider(scope, %{name: "Local", adapter: :openai_compatible, base_url: "http://x/v1"})

      {:ok, joy} = AI.create_model(scope, %{name: "JoyCaption", api_model_id: "joycaption", supports_images: true})
      {:ok, sky} = AI.create_model(scope, %{name: "Skyfall", api_model_id: "skyfall", caption_model_id: joy.id})
      for m <- [joy, sky], do: {:ok, _} = AI.link_model(scope, provider, m)
      {:ok, _} = Chats.update_chat(scope, chat, %{"ai_model_id" => sky.id})
      test = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:caption_body, Jason.decode!(raw)})
        frame = Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => %{"content" => "Red and gold"}}]})
        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce(["data: #{frame}\n\n", "data: [DONE]\n\n"], conn, fn chunk, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, chunk)
          conn
        end)
      end)
    end

    defp start_caption(view) do
      open(view)
      query(view, "caption image")
      key(view, "Enter")

      view
      |> file_input("#command-palette-args", :palette_image, [%{name: "fox.png", content: png(), type: "image/png"}])
      |> render_upload("fox.png")
    end

    test "stages the uploaded image in the composer, described with the prompt",
         %{conn: conn, user: user, scope: scope} = context do
      Req.Test.set_req_test_to_shared(context)
      chat = chat!(scope, user)
      captioner!(scope, chat)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      :ok = Attachments.subscribe(chat.id)

      start_caption(view)
      assert has_element?(view, "#command-palette-arg-0", "fox.png")

      key(view, "Enter")
      type_arg(view, 1, "Name the colours.")
      key(view, "Enter")
      refute has_element?(view, "#command-palette-dialog")

      assert_receive {:caption_body, body}, 2_000
      assert [%{"content" => [%{"text" => "Name the colours."}, %{"type" => "image_url"}]}] = body["messages"]

      assert_receive {:caption_finished, id}, 2_000
      assert has_element?(view, "#composer-attachment-description-#{id}[data-value='Red and gold']")
    end

    test "leaving the command deletes the image it uploaded", %{scope: scope, conn: conn, user: user} do
      chat = chat!(scope, user)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      start_caption(view)
      assert [_stored] = Mythweaver.Repo.all(Attachment)

      key(view, "Escape")
      assert Mythweaver.Repo.all(Attachment) == []

      # Back in the list: the command again, then closing the palette.
      query(view, "caption image")
      key(view, "Enter")

      view
      |> file_input("#command-palette-args", :palette_image, [%{name: "fox.png", content: png(), type: "image/png"}])
      |> render_upload("fox.png")

      assert [_stored] = Mythweaver.Repo.all(Attachment)

      key(view, "Escape")
      key(view, "Escape")
      refute has_element?(view, "#command-palette-dialog")
      assert Mythweaver.Repo.all(Attachment) == []
    end
  end

  describe "chat memory commands" do
    setup %{scope: scope, user: user} do
      chat = Chats.get_chat!(chat!(scope, user).id)

      for text <- ~w(one two three four) do
        {:ok, _} = Messages.post_message(scope, chat, {:character, chat.player_character_id}, text)
      end

      {:ok, prompt} = Prompts.create_prompt(scope, %{name: "Side: Palette", purpose: :side_prompt})
      {:ok, tracker} = Memory.create_side_prompt(scope, %{name: "Tracker", prompt_id: prompt.id})
      {:ok, other} = Memory.create_side_prompt(scope, %{name: "Wardrobe", prompt_id: prompt.id, enabled: false})
      %{chat: chat, tracker: tracker, other: other}
    end

    # Picks the command by id, then answers each parameter in turn ("" leaves an optional one blank).
    defp palette(view, id, args \\ []) do
      open(view)
      view |> element("[data-command-id='#{id}']") |> render_click()

      args
      |> Enum.with_index()
      |> Enum.each(fn {text, i} ->
        type_arg(view, i, text)
        key(view, "Enter")
      end)
    end

    test "create memory opens the panel on the checked span", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      [_, second, third, _] = Messages.list_messages(chat)
      for m <- [second, third], do: view |> element("#message-select-#{m.id}") |> render_click()

      palette(view, "chat.memory.create")

      assert_patch(view, ~p"/chats/#{chat.id}/memory?start=2&end=3")
      assert has_element?(view, "#memory-create-start[value='2']")
      assert has_element?(view, "#memory-create-end[value='3']")
    end

    test "scene and catch-up open the panel with their fields filled", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      palette(view, "chat.memory.scene", ["2", "4"])
      {path, _flash} = assert_redirect(view)
      {:ok, view, _html} = live(conn, path)
      assert has_element?(view, "#memory-create-start[value='2']")
      assert has_element?(view, "#memory-create-end[value='4']")

      palette(view, "chat.memory.catchup", ["1", "4", "10"])
      {:ok, view, _html} = live(conn, view |> assert_redirect() |> elem(0))
      assert has_element?(view, "#memory-catchup-start[value='1']")
      assert has_element?(view, "#memory-catchup-end[value='4']")
      assert has_element?(view, "#memory-catchup-chunk[value='10']")
    end

    test "next memory runs in place, without opening the panel", %{scope: scope, conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      {:ok, _} = Memory.set_highest_processed(scope, chat, 3)
      palette(view, "chat.memory.next")
      refute has_element?(view, "#memory-create-start")
      assert has_element?(view, "#flash-error", "Every message is already processed.")
    end

    test "run side prompt prefills only the picked side prompt's row",
         %{conn: conn, chat: chat, tracker: tracker, other: other} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      palette(view, "chat.memory.run_side_prompt", [tracker.name, "2", "3"])
      {:ok, view, _html} = live(conn, view |> assert_redirect() |> elem(0))

      assert has_element?(view, "#memory-side-start-#{tracker.id}[value='2']")
      assert has_element?(view, "#memory-side-end-#{tracker.id}[value='3']")
      assert has_element?(view, "#memory-side-start-#{other.id}[value='']")
    end

    test "side prompts switch on and off, one or all", %{
      scope: scope,
      conn: conn,
      chat: chat,
      tracker: tracker,
      other: other
    } do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      # Each command is replayed to the LiveView as a message; `render/1` queues behind it, so the
      # write has happened before the database is read.
      palette(view, "chat.memory.disable_side_prompt", [tracker.name])
      _ = render(view)
      refute Memory.get_side_prompt(scope, tracker.id).enabled
      assert has_element?(view, "#flash-info", "Tracker disabled.")

      palette(view, "chat.memory.enable_all_side_prompts")
      _ = render(view)
      assert Memory.get_side_prompt(scope, tracker.id).enabled and Memory.get_side_prompt(scope, other.id).enabled
      assert has_element?(view, "#flash-info", "2 side prompts enabled.")

      palette(view, "chat.memory.disable_all_side_prompts")
      _ = render(view)
      refute Memory.get_side_prompt(scope, tracker.id).enabled or Memory.get_side_prompt(scope, other.id).enabled

      palette(view, "chat.memory.enable_side_prompt", [other.name])
      _ = render(view)
      assert Memory.get_side_prompt(scope, other.id).enabled
      refute Memory.get_side_prompt(scope, tracker.id).enabled
    end

    test "the processed boundary shows, sets and clears", %{scope: scope, conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      palette(view, "chat.memory.highest")
      assert has_element?(view, "#flash-info", "No messages have been processed.")

      palette(view, "chat.memory.set_highest", ["3"])
      assert Memory.chat_settings(scope, chat).highest_processed == 2
      palette(view, "chat.memory.highest")
      assert has_element?(view, "#flash-info", "Processed through #3.")

      palette(view, "chat.memory.clear_highest")
      assert Memory.chat_settings(scope, chat).highest_processed == nil
    end

    test "out-of-range numbers are refused before anything changes", %{scope: scope, conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      palette(view, "chat.memory.set_highest", ["2147483648"])
      assert has_element?(view, "#flash-error", "Message numbers start at 1.")
      assert Memory.chat_settings(scope, chat).highest_processed == nil

      palette(view, "chat.memory.scene", ["4", "2"])
      assert has_element?(view, "#flash-error", "Start must not be after End.")

      palette(view, "chat.memory.catchup", ["1", "4", "2"])
      assert has_element?(view, "#flash-error", "Chunk size must be 5 to 250 messages.")

      palette(view, "chat.memory.create")
      assert has_element?(view, "#flash-error", "Check the messages to make a memory of first.")
    end
  end

  describe "chat: go to message" do
    setup %{scope: scope, user: user} do
      chat = Chats.get_chat!(chat!(scope, user).id)

      for i <- 1..120 do
        {:ok, _} = Messages.post_message(scope, chat, {:character, chat.player_character_id}, "m#{i}")
      end

      %{chat: chat, messages: Messages.list_messages(chat)}
    end

    defp row_ids(view) do
      view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("#messages > li") |> LazyHTML.attribute("id")
    end

    test "an unloaded message loads a page around it and is scrolled to", %{
      conn: conn,
      chat: chat,
      messages: messages
    } do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      target = Enum.at(messages, 9)
      refute has_element?(view, "#messages-#{target.id}")

      palette(view, "chat.jump", ["10"])

      assert_push_event(view, "scroll_to_message", %{id: id})
      assert id == "messages-#{target.id}"
      ids = row_ids(view)
      assert hd(ids) == "messages-#{hd(messages).id}"
      assert List.last(ids) == "messages-#{Enum.at(messages, 33).id}"
      assert has_element?(view, "#messages[data-has-older='false'][data-has-newer='true']")
      assert has_element?(view, "#jump-to-latest")

      # Near the newest end the page fills from above, and live appends resume.
      palette(view, "chat.jump", ["110"])
      assert_push_event(view, "scroll_to_message", %{})
      ids = row_ids(view)
      assert hd(ids) == "messages-#{Enum.at(messages, 70).id}"
      assert List.last(ids) == "messages-#{List.last(messages).id}"
      assert has_element?(view, "#messages[data-has-older='true'][data-has-newer='false']")
    end

    test "a loaded message keeps the window", %{conn: conn, chat: chat, messages: messages} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      before = row_ids(view)

      palette(view, "chat.jump", ["100"])

      assert_push_event(view, "scroll_to_message", %{id: id})
      assert id == "messages-#{Enum.at(messages, 99).id}"
      assert row_ids(view) == before
    end

    test "a number with no message is refused", %{scope: scope, conn: conn, chat: chat, messages: messages} do
      {:ok, _} = Messages.delete_message(scope, Enum.at(messages, 4))
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      before = row_ids(view)

      for number <- ["5", "121"] do
        palette(view, "chat.jump", [number])
        assert has_element?(view, "#flash-error", "This chat has no message ##{number}.")
      end

      palette(view, "chat.jump", ["0"])
      assert has_element?(view, "#flash-error", "Message numbers start at 1.")
      refute_push_event(view, "scroll_to_message", %{})
      assert row_ids(view) == before
    end
  end

  describe "keyboard shortcuts" do
    setup %{scope: scope, user: user} do
      chat = Chats.get_chat!(chat!(scope, user).id)
      bot_id = Enum.find(chat.participants, &(&1.character_id != chat.player_character_id)).character_id
      %{chat: chat, bot_id: bot_id}
    end

    defp shortcut(view, id), do: view |> element("#command-palette") |> render_hook("shortcut", %{"id" => id})

    defp say(scope, chat, character_id, text) do
      {:ok, message} = Messages.post_message(scope, chat, {:character, character_id}, text)
      message
    end

    test "edit last opens the newest message's editor", %{scope: scope, conn: conn, chat: chat, bot_id: bot_id} do
      message = say(scope, chat, bot_id, "Hello")
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      shortcut(view, "chat.edit_last")
      assert has_element?(view, "#message-edit-form-#{message.id}")
    end

    test "edit last player message skips later replies, and says when there is none",
         %{scope: scope, conn: conn, chat: chat, bot_id: bot_id} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      _ = say(scope, chat, bot_id, "Hello")
      shortcut(view, "chat.edit_last_player")
      assert has_element?(view, "#flash-error", "You haven't sent a message in this chat yet.")

      mine = say(scope, chat, chat.player_character_id, "Hi")
      assert mine.author_is_player
      reply = say(scope, chat, bot_id, "Well met")
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      shortcut(view, "chat.edit_last_player")
      assert has_element?(view, "#message-edit-form-#{mine.id}")
      refute has_element?(view, "#message-edit-form-#{reply.id}")
    end

    test "swipe prev and next move between the last message's swipes",
         %{scope: scope, conn: conn, chat: chat, bot_id: bot_id} do
      message = say(scope, chat, bot_id, "One")
      {:ok, _} = Messages.add_body(message, %{content: "Two"})
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      shortcut(view, "chat.swipe_prev")
      assert has_element?(view, "#messages-#{message.id} .chat-message-swipe-count", "1 / 2")
      shortcut(view, "chat.swipe_next")
      assert has_element?(view, "#messages-#{message.id} .chat-message-swipe-count", "2 / 2")
    end

    test "swipe next on the newest swipe of a reply generates a new one",
         %{scope: scope, conn: conn, chat: chat, bot_id: bot_id} = context do
      Req.Test.set_req_test_to_shared(context)
      {:ok, model} = AI.create_model(scope, %{name: "Gemma", api_model_id: "gemma-4"})

      {:ok, provider} =
        AI.create_provider(scope, %{name: "Local", adapter: :openai_compatible, base_url: "http://x/v1"})

      {:ok, _} = AI.link_model(scope, provider, model)
      {:ok, prompt} = Prompts.create_prompt(scope, %{name: "Default"})
      {:ok, block} = Prompts.create_block(scope, %{name: "Sys", content: "Be brief."})
      {:ok, _} = Prompts.add_block(scope, prompt, block)
      {:ok, _} = Prompts.bind_prompt(scope, prompt, :global)

      Req.Test.stub(Mythweaver.AI, fn conn ->
        frame = Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => %{"content" => "pong"}}]})
        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce(["data: #{frame}\n\n", "data: [DONE]\n\n"], conn, fn chunk, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, chunk)
          conn
        end)
      end)

      message = say(scope, chat, bot_id, "One")
      {:ok, _} = Messages.add_body(message, %{content: "Two"})
      :ok = Messages.subscribe(chat)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      shortcut(view, "chat.swipe_next")
      assert_receive {:generation_finished, _id}, 2_000
      assert length(Messages.get_message!(scope, message.id).bodies) == 3
    end

    test "refine rewrites the last reply from the composer text, and asks for some first",
         %{scope: scope, conn: conn, chat: chat, bot_id: bot_id} do
      say(scope, chat, bot_id, "One")
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      shortcut(view, "chat.refine")
      assert has_element?(view, "#flash-error", "Type editing instructions in the composer first.")
    end

    test "unknown and param-taking ids do nothing", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      shortcut(view, "nope")
      shortcut(view, "chat.generate")
      refute has_element?(view, "#flash-error")
      refute has_element?(view, "#command-palette-dialog")
    end

    test "palette rows show their shortcut", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      open(view)
      query(view, "regenerate")
      assert has_element?(view, "[data-command-id='chat.regenerate'] .shortcut-key")
      query(view, "settings")
      refute has_element?(view, "[data-command-id='chat.settings'] .shortcut")
    end
  end

  test "the shortcut help is on every page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/characters/new")

    assert has_element?(view, "#shortcut-help #shortcut-help-regenerate")
    assert has_element?(view, "#shortcut-help #shortcut-help-palette")
  end

  describe "cleanup commands" do
    test "a user cleans their own chats", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/characters/new")
      open(view)
      query(view, "cleanup")

      refute has_element?(view, "[data-command-id='cleanup.all']")
      view |> element("[data-command-id='cleanup.mine']") |> render_click()
      render_async(view)

      assert has_element?(view, "#flash-info", "Cleaned up")
    end

    test "an owner also cleans every chat" do
      conn = log_in_user(build_conn(), register_user!(%{role: :owner}))
      {:ok, view, _html} = live(conn, ~p"/characters/new")
      open(view)
      query(view, "cleanup")

      assert has_element?(view, "[data-command-id='cleanup.mine']")
      view |> element("[data-command-id='cleanup.all']") |> render_click()
      render_async(view)

      assert has_element?(view, "#flash-info", "Cleaned up")
    end
  end
end
