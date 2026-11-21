defmodule Mythweaver.Attachments.CaptionsTest do
  use Mythweaver.DataCase

  alias Mythweaver.AI
  alias Mythweaver.Analytics.GenerationStat
  alias Mythweaver.Attachments
  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Attachments.Captions
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Jobs
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Messages
  alias Mythweaver.Prompts
  alias Mythweaver.Scripts.CallbackStore
  alias Mythweaver.Settings

  defp png,
    do:
      Base.decode64!("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")

  defp unique, do: System.unique_integer([:positive])

  setup do
    scope = scope!()

    {:ok, provider} =
      AI.create_provider(scope, %{name: "P#{unique()}", adapter: :openai_compatible, base_url: "http://x/v1"},
        site: true
      )

    {:ok, joy} =
      AI.create_model(scope, %{name: "Joy#{unique()}", api_model_id: "joy", supports_images: true}, site: true)

    {:ok, sky} =
      AI.create_model(scope, %{name: "Sky#{unique()}", api_model_id: "sky", caption_model_id: joy.id}, site: true)

    for m <- [joy, sky], do: {:ok, _} = AI.link_model(scope, provider, m)

    [player, bot] =
      for n <- ["Player", "Bot"], do: elem(Characters.create_character(scope, %{name: "#{n}#{unique()}"}), 1)

    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: "c#{unique()}",
        participants: [%{character_id: player.id}, %{character_id: bot.id}],
        player_character_id: player.id,
        ai_model_id: sky.id
      })

    {:ok, image} = Attachments.store_binary(png())
    # Every caption job in these tests runs for real against this stub; `await_captions/1` waits
    # for them, so none outlives its test.
    stub_caption("A caption")
    :ok = Jobs.subscribe(scope)

    %{
      scope: scope,
      chat: Chats.get_chat!(chat.id),
      player: player,
      bot: bot,
      joy: joy,
      sky: sky,
      provider: provider,
      image: image
    }
  end

  # Each request's decoded body is sent to the test as `{:caption_body, body}`.
  defp stub_caption(text) do
    test = self()

    Req.Test.stub(Mythweaver.AI, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:caption_body, Jason.decode!(raw)})

      frames = [
        "data: " <> Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => %{"content" => text}}]}) <> "\n\n",
        ~s(data: {"choices":[{"finish_reason":"stop","index":0,"delta":{}}]}\n\n),
        "data: [DONE]\n\n"
      ]

      conn = Plug.Conn.send_chunked(conn, 200)

      Enum.reduce(frames, conn, fn frame, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, frame)
        conn
      end)
    end)
  end

  defp await_captions(0), do: :ok

  defp await_captions(n) do
    assert_receive {:job_changed, %{tag: :caption, status: status}} when status in [:completed, :failed, :canceled],
                   2_000

    await_captions(n - 1)
  end

  defp job(ctx),
    do: %Job{
      params: %{"attachment_id" => ctx.image.id, "chat_id" => ctx.chat.id},
      ai_model_id: ctx.joy.id,
      user_id: ctx.scope.user.id
    }

  test "a caption job finishing after the player wrote a description leaves it alone", ctx do
    pending = ctx.image |> Ecto.Changeset.change(caption_status: :pending) |> Repo.update!()
    Captions.put_manual_description(ctx.scope, ctx.chat.id, pending, "Mine")

    assert {:ok, _} = Captions.put_description(ctx.scope, job(ctx), "The model's")
    assert %Attachment{description: "Mine", caption_status: :done, described_by_model_id: nil} = Repo.reload!(ctx.image)
  end

  test "a blank manual description clears it so the image is captioned again", ctx do
    described = Captions.put_manual_description(ctx.scope, ctx.chat.id, ctx.image, "Mine")

    assert %Attachment{description: nil, caption_status: :none} =
             Captions.put_manual_description(ctx.scope, ctx.chat.id, described, "  ")
  end

  test "sending does not recaption an image that already has a description", ctx do
    described = Captions.put_manual_description(ctx.scope, ctx.chat.id, ctx.image, "Mine")
    {:ok, _} = Messages.send_message(ctx.scope, ctx.chat, ctx.player.id, "Look", attachments: [described])

    assert Repo.aggregate(Job, :count) == 0
    assert Repo.reload!(ctx.image).description == "Mine"
  end

  test "a caption started in the composer that finishes after send refreshes the sent message", ctx do
    pending = ctx.image |> Ecto.Changeset.change(caption_status: :pending) |> Repo.update!()
    {:ok, message} = Messages.send_message(ctx.scope, ctx.chat, ctx.player.id, "Look", attachments: [pending])
    :ok = Messages.subscribe(ctx.chat)

    {:ok, _} = Captions.put_description(ctx.scope, job(ctx), "A red fox")

    message_id = message.id
    assert_receive {:message_updated, %{id: ^message_id, attachments: [%{description: "A red fox"}]}}
  end

  describe "a caption job that never reaches its own failure path" do
    test "canceling it releases the image", ctx do
      test = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        send(test, :caption_request)
        Process.sleep(:infinity)
        conn
      end)

      :ok = Attachments.subscribe(ctx.chat.id)
      {:ok, pending} = Captions.request_staged(ctx.scope, ctx.chat, ctx.image)
      assert pending.caption_status == :pending
      assert_receive :caption_request, 2_000

      [%Job{id: job_id}] = Repo.all(Job)
      :ok = Jobs.cancel(ctx.scope, job_id)

      image_id = ctx.image.id
      assert_receive {:caption_finished, ^image_id}, 2_000
      assert %Attachment{caption_status: :failed, caption_error: "Stopped."} = Repo.reload!(ctx.image)
    end

    test "a restart interrupting it releases the image", ctx do
      pending = ctx.image |> Ecto.Changeset.change(caption_status: :pending) |> Repo.update!()

      Repo.insert!(%Job{
        tag: :caption,
        origin: :interactive,
        status: :running,
        label: "Caption image",
        chat_id: ctx.chat.id,
        ai_model_id: ctx.joy.id,
        user_id: ctx.scope.user.id,
        params: %{"attachment_id" => pending.id, "chat_id" => ctx.chat.id}
      })

      Jobs.interrupt_stale()

      assert %Attachment{caption_status: :failed, caption_error: "Interrupted."} = Repo.reload!(ctx.image)
    end
  end

  describe "which caption model" do
    setup ctx do
      {:ok, joy2} =
        AI.create_model(ctx.scope, %{name: "Joy2#{unique()}", api_model_id: "joy2", supports_images: true}, site: true)

      {:ok, sky2} =
        AI.create_model(ctx.scope, %{name: "Sky2#{unique()}", api_model_id: "sky2", caption_model_id: joy2.id},
          site: true
        )

      for m <- [joy2, sky2], do: {:ok, _} = AI.link_model(ctx.scope, ctx.provider, m)
      bot = Enum.find(ctx.chat.participants, &(&1.character_id == ctx.bot.id))
      {:ok, _} = Chats.update_participant(ctx.scope, bot, %{ai_model_id: sky2.id})
      %{chat: Chats.get_chat!(ctx.chat.id), joy2: joy2}
    end

    test "the replying character's own caption model is preferred", ctx do
      joy_id = ctx.joy.id
      joy2_id = ctx.joy2.id
      assert {:ok, %{id: ^joy_id}} = Captions.captioner_for(ctx.scope, ctx.chat, ctx.player)
      assert {:ok, %{id: ^joy2_id}} = Captions.captioner_for(ctx.scope, ctx.chat, ctx.bot)
      # No reply in view: the other participants come before the player.
      assert {:ok, %{id: ^joy2_id}} = Captions.captioner_for(ctx.scope, ctx.chat)
    end

    test "an image sent with no captioner is described with the responder's before it replies", ctx do
      {:ok, _} = Chats.update_chat(ctx.scope, ctx.chat, %{"ai_model_id" => nil})
      bot = Enum.find(ctx.chat.participants, &(&1.character_id == ctx.bot.id))
      {:ok, _} = Chats.update_participant(ctx.scope, bot, %{ai_model_id: nil})
      chat = Chats.get_chat!(ctx.chat.id)
      {:ok, message} = Messages.send_message(ctx.scope, chat, ctx.player.id, "Look", attachments: [ctx.image])
      assert Repo.aggregate(Job, :count) == 0

      {:ok, _} = Chats.update_participant(ctx.scope, bot, %{ai_model_id: ctx.sky.id})
      chat = Chats.get_chat!(ctx.chat.id)
      image_id = ctx.image.id

      assert [^image_id] =
               Captions.request_for_reply(
                 ctx.scope,
                 chat,
                 [Messages.get_message!(ctx.scope, message.id)],
                 ctx.bot,
                 ctx.sky
               )

      await_captions(1)
      assert %Attachment{description: "A caption", described_by_model_id: joy_id} = Repo.reload!(ctx.image)
      assert joy_id == ctx.joy.id
    end
  end

  describe "images.default_caption_model" do
    test "picks the site default caption model, falling back to the first by name", ctx do
      {:ok, zed} =
        AI.create_model(ctx.scope, %{name: "Zed#{unique()}", api_model_id: "zed", supports_images: true}, site: true)

      {:ok, _} = AI.link_model(ctx.scope, ctx.provider, zed)
      joy_id = ctx.joy.id
      zed_id = zed.id

      assert {:ok, %{id: ^joy_id}} = AI.default_caption_model(ctx.scope)

      :ok = Settings.put(ctx.scope, :site, "images.default_caption_model", zed.id)
      assert {:ok, %{id: ^zed_id}} = AI.default_caption_model(ctx.scope)

      assert {:error, "is not an option"} =
               Settings.put(ctx.scope, :site, "images.default_caption_model", ctx.sky.id)

      :ok = Settings.put(ctx.scope, :site, "images.default_caption_model", "")
      assert Settings.get(ctx.scope, "images.default_caption_model") == nil

      :ok = Settings.put(ctx.scope, :site, "images.default_caption_model", zed.id)
      {:ok, _} = AI.delete_model(ctx.scope, zed)
      assert {:ok, %{id: ^joy_id}} = AI.default_caption_model(ctx.scope)
    end
  end

  describe "messages hidden from the AI" do
    test "are skipped when captioning on send, before a reply, and for the whole chat", ctx do
      {:ok, _} = Chats.update_chat(ctx.scope, ctx.chat, %{"ai_model_id" => nil})
      chat = Chats.get_chat!(ctx.chat.id)
      {:ok, message} = Messages.send_message(ctx.scope, chat, ctx.player.id, "Look", attachments: [ctx.image])
      {:ok, _} = Messages.set_visible_to_ai(ctx.scope, message, false)
      {:ok, _} = Chats.update_chat(ctx.scope, chat, %{"ai_model_id" => ctx.sky.id})
      chat = Chats.get_chat!(ctx.chat.id)
      hidden = Messages.get_message!(ctx.scope, message.id)

      assert :ok = Captions.request_for_message(ctx.scope, chat, hidden)
      assert [] = Captions.request_for_reply(ctx.scope, chat, [hidden], ctx.bot, ctx.sky)
      assert {:ok, 0} = Captions.request_all(ctx.scope, chat)
      assert Repo.aggregate(Job, :count) == 0
    end
  end

  test "describe-all queues every undescribed image in the chat", ctx do
    {:ok, _} = Chats.update_chat(ctx.scope, ctx.chat, %{"ai_model_id" => nil})
    chat = Chats.get_chat!(ctx.chat.id)
    {:ok, other} = Attachments.store_binary(png())
    other = Captions.put_manual_description(ctx.scope, chat.id, other, "Already described")
    {:ok, _} = Messages.send_message(ctx.scope, chat, ctx.player.id, "One", attachments: [ctx.image])
    {:ok, _} = Messages.send_message(ctx.scope, chat, ctx.player.id, "Two", attachments: [other])
    {:ok, _} = Chats.update_chat(ctx.scope, chat, %{"ai_model_id" => ctx.sky.id})

    assert {:ok, 1} = Captions.request_all(ctx.scope, Chats.get_chat!(chat.id))
    await_captions(1)
    assert Repo.reload!(ctx.image).description == "A caption"
    assert Repo.reload!(other).description == "Already described"
  end

  test "in a chat whose model sees images, a person's request is described by that model", ctx do
    {:ok, _} = Chats.update_chat(ctx.scope, ctx.chat, %{"ai_model_id" => nil})
    chat = Chats.get_chat!(ctx.chat.id)
    {:ok, _} = Messages.send_message(ctx.scope, chat, ctx.player.id, "Look", attachments: [ctx.image])
    {:ok, _} = Chats.update_chat(ctx.scope, chat, %{"ai_model_id" => ctx.joy.id})
    chat = Chats.get_chat!(chat.id)
    joy_id = ctx.joy.id

    assert :ok = Captions.request(ctx.scope, chat, ctx.image.id)
    assert [%Job{tag: :caption, ai_model_id: ^joy_id}] = Repo.all(Job)
    await_captions(1)

    {:ok, other} = Attachments.store_binary(png())
    {:ok, _} = Messages.send_message(ctx.scope, chat, ctx.player.id, "More", attachments: [other])
    assert {:ok, 1} = Captions.request_all(ctx.scope, chat)
    await_captions(1)

    {:ok, blind} = AI.create_model(ctx.scope, %{name: "Blind#{unique()}", api_model_id: "blind"}, site: true)
    {:ok, _} = AI.link_model(ctx.scope, ctx.provider, blind)
    {:ok, _} = Chats.update_chat(ctx.scope, chat, %{"ai_model_id" => blind.id})

    assert {:error, :no_captioner} = Captions.request(ctx.scope, Chats.get_chat!(chat.id), ctx.image.id)
  end

  test "a caption the worker saves is recorded as a finished run", ctx do
    {:ok, _} = Captions.request_staged(ctx.scope, ctx.chat, ctx.image)
    await_captions(1)

    assert [%GenerationStat{tag: :caption, status: :completed}] =
             Repo.all(GenerationStat)
  end

  test "an AI-generated image is described by the site default even when no participant has a captioner",
       ctx do
    {:ok, _} = Chats.update_chat(ctx.scope, ctx.chat, %{"ai_model_id" => nil})
    chat = Chats.get_chat!(ctx.chat.id)
    {:ok, message} = Messages.send_message(ctx.scope, chat, ctx.bot.id, "Here")
    {:ok, generated} = Attachments.store_binary(png(), source: :generated)

    {:ok, _} = Messages.attach_images(ctx.scope, chat, message, [generated])
    await_captions(1)

    assert {:ok, %{id: default_id}} = AI.default_caption_model(ctx.scope)
    assert %Attachment{description: "A caption", described_by_model_id: ^default_id} = Repo.reload!(generated)
  end

  describe "avatars" do
    test "the description fills a blank appearance and replaces the previous avatar's", ctx do
      stub_caption("A tall woman")
      :ok = Attachments.set_avatar(ctx.scope, ctx.bot, ctx.image)
      await_captions(1)
      assert Characters.get_character!(ctx.bot.id).appearance == "A tall woman"

      stub_caption("A short man")
      {:ok, second} = Attachments.store_binary(png())
      :ok = Attachments.set_avatar(ctx.scope, Characters.get_character!(ctx.bot.id), second)
      await_captions(1)
      assert Characters.get_character!(ctx.bot.id).appearance == "A short man"
    end

    test "an appearance someone wrote is kept", ctx do
      {:ok, character} = Characters.update_character(ctx.scope, ctx.bot, %{appearance: "Hand-written"})
      :ok = Attachments.set_avatar(ctx.scope, character, ctx.image)
      await_captions(1)

      assert Characters.get_character!(character.id).appearance == "Hand-written"
      assert Repo.reload!(ctx.image).description == "A caption"
    end

    test "the character editor's description stays on the attachment, whatever Appearance holds", ctx do
      {:ok, character} = Characters.update_character(ctx.scope, ctx.bot, %{appearance: "Hand-written"})

      stub_caption("A tall woman")
      assert {:ok, job_id} = Captions.describe_avatar(ctx.scope, character, ctx.image)
      assert_receive {:job_changed, %{id: ^job_id, status: :completed}}, 2_000

      assert %Attachment{caption_status: :done, description: "A tall woman"} = Repo.reload!(ctx.image)
      assert Characters.get_character!(character.id).appearance == "Hand-written"
    end

    test "the new-character form's avatar is described with no character, asking the person's question", ctx do
      assert {:ok, job_id} = Captions.describe_avatar(ctx.scope, nil, ctx.image, instruction: "Who is this?")
      assert_receive {:caption_body, body}, 2_000
      assert_receive {:job_changed, %{id: ^job_id, status: :completed}}, 2_000

      assert %{"content" => [%{"type" => "text", "text" => "Who is this?"}, _image]} = List.last(body["messages"])
      assert Repo.reload!(ctx.image).description == "A caption"
    end

    test "describing in the editor needs edit rights on the character", ctx do
      user = scope!(%{role: :user})
      assert {:error, :unauthorized} = Captions.describe_avatar(user, ctx.bot, ctx.image)
    end
  end

  describe "the caption request" do
    test "renders the captioner's caption prompt against the chat, image last, capped", ctx do
      {:ok, _} = Messages.send_message(ctx.scope, ctx.chat, ctx.player.id, "We reach the old bridge")

      {:ok, history} =
        Prompts.create_block(ctx.scope, %{name: "H#{unique()}", kind: :chat_history, role: :user}, site: true)

      {:ok, ask} =
        Prompts.create_block(ctx.scope, %{name: "A#{unique()}", role: :user, content: "Describe it."}, site: true)

      {:ok, prompt} = Prompts.create_prompt(ctx.scope, %{name: "Cap#{unique()}", purpose: :caption}, site: true)
      for block <- [history, ask], do: {:ok, _} = Prompts.add_block(ctx.scope, prompt, block)
      {:ok, _} = AI.update_model(ctx.scope, ctx.joy, %{caption_prompt_id: prompt.id, caption_max_tokens: 120})

      {:ok, _} = Captions.request_staged(ctx.scope, ctx.chat, ctx.image)
      assert_receive {:caption_body, body}, 2_000
      await_captions(1)

      assert body["max_tokens"] == 120
      assert inspect(body["messages"]) =~ "We reach the old bridge"

      assert %{"role" => "user", "content" => [%{"type" => "text", "text" => text}, %{"type" => "image_url"}]} =
               List.last(body["messages"])

      assert text =~ "Describe it."
      assert %Job{prompt_name: name} = Enum.find(Repo.all(Job), &(&1.tag == :caption))
      assert name == prompt.name
    end

    test "with no caption prompt is the built-in instruction and the image alone", ctx do
      {:ok, _} = Captions.request_staged(ctx.scope, ctx.chat, ctx.image)
      assert_receive {:caption_body, body}, 2_000
      await_captions(1)

      assert [%{"role" => "user", "content" => [%{"type" => "text", "text" => text}, %{"type" => "image_url"}]}] =
               body["messages"]

      assert text == AI.Model.default_caption_prompt()
      assert body["max_tokens"] == 300
      assert %Job{prompt_name: nil} = Enum.find(Repo.all(Job), &(&1.tag == :caption))
    end

    test "an avatar renders the site's avatar caption prompt with no chat, never the captioner's own", ctx do
      caption_prompt! = fn content ->
        {:ok, ask} = Prompts.create_block(ctx.scope, %{name: "A#{unique()}", role: :user, content: content}, site: true)
        {:ok, prompt} = Prompts.create_prompt(ctx.scope, %{name: "Cap#{unique()}", purpose: :caption}, site: true)
        {:ok, _} = Prompts.add_block(ctx.scope, prompt, ask)
        prompt
      end

      scene = caption_prompt!.("Describe the image shared in this chat.")
      avatar = caption_prompt!.("Describe {{ anchors.character.name }}.")
      {:ok, captioner} = AI.default_caption_model(ctx.scope)
      {:ok, _} = AI.update_model(ctx.scope, captioner, %{caption_prompt_id: scene.id})
      :ok = Settings.put(ctx.scope, :site, "images.avatar_caption_prompt", avatar.id)

      :ok = Attachments.set_avatar(ctx.scope, ctx.bot, ctx.image)
      assert_receive {:caption_body, body}, 2_000
      await_captions(1)

      assert %{"content" => [%{"text" => text}, %{"type" => "image_url"}]} = List.last(body["messages"])
      assert text =~ "Describe #{ctx.bot.name}."
      assert Characters.get_character!(ctx.bot.id).appearance == "A caption"

      # Unset, an avatar gets the built-in instruction, not the captioner's chat prompt.
      :ok = Settings.put(ctx.scope, :site, "images.avatar_caption_prompt", nil)
      {:ok, second} = Attachments.store_binary(png())
      :ok = Attachments.set_avatar(ctx.scope, Characters.get_character!(ctx.bot.id), second)
      assert_receive {:caption_body, body}, 2_000
      await_captions(1)

      assert %{"content" => [%{"text" => text}, _image]} = List.last(body["messages"])
      assert text == AI.Model.default_caption_prompt()
    end

    test "a staged image's instruction replaces the caption prompt; a blank one does not", ctx do
      {:ok, ask} =
        Prompts.create_block(ctx.scope, %{name: "A#{unique()}", role: :user, content: "Describe it."}, site: true)

      {:ok, prompt} = Prompts.create_prompt(ctx.scope, %{name: "Cap#{unique()}", purpose: :caption}, site: true)
      {:ok, _} = Prompts.add_block(ctx.scope, prompt, ask)
      {:ok, _} = AI.update_model(ctx.scope, ctx.joy, %{caption_prompt_id: prompt.id})

      {:ok, _} = Captions.request_staged(ctx.scope, ctx.chat, ctx.image, instruction: " Name the colours. ")
      assert_receive {:caption_body, body}, 2_000
      await_captions(1)

      assert [
               %{
                 "role" => "user",
                 "content" => [%{"type" => "text", "text" => "Name the colours."}, %{"type" => "image_url"}]
               }
             ] =
               body["messages"]

      {:ok, _} = Captions.request_staged(ctx.scope, ctx.chat, ctx.image, instruction: "  ")
      assert_receive {:caption_body, body}, 2_000
      await_captions(1)

      assert [%{"content" => [%{"type" => "text", "text" => text}, _image]}] = body["messages"]
      assert text =~ "Describe it."
    end

    test "a caption prompt must have the caption purpose", ctx do
      {:ok, roleplay} = Prompts.create_prompt(ctx.scope, %{name: "RP#{unique()}"}, site: true)
      assert {:error, changeset} = AI.update_model(ctx.scope, ctx.joy, %{caption_prompt_id: roleplay.id})
      assert "must be a caption prompt" in errors_on(changeset).caption_prompt_id
    end
  end

  test "images past a vision model's inline limit are described at most a batch per reply, newest first",
       ctx do
    {:ok, _} = Chats.update_chat(ctx.scope, ctx.chat, %{"ai_model_id" => nil})
    chat = Chats.get_chat!(ctx.chat.id)
    batch = Captions.aged_out_batch()
    images = for _ <- 1..(batch + 2), do: elem(Attachments.store_binary(png()), 1)
    {:ok, message} = Messages.send_message(ctx.scope, chat, ctx.player.id, "Many", attachments: images)
    message = Messages.get_message!(ctx.scope, message.id)

    :ok = Captions.request_aged_out(ctx.scope, chat, Enum.map(message.attachments, &{message, &1}), ctx.joy)
    await_captions(batch)

    {older, newest} = Enum.split(message.attachments, 2)
    assert Enum.all?(older, &(Repo.reload!(&1).caption_status == :none))
    assert Enum.all?(newest, &(Repo.reload!(&1).caption_status == :done))
  end

  describe "the image_described trigger" do
    # Scripts log a warning on failure by design.
    @describetag :capture_log

    defp script!(scope, body) do
      {:ok, script} =
        Mythweaver.Scripts.create_script(scope, %{name: "S#{unique()}", trigger: :image_described, body: body})

      script
    end

    test "sees a model caption with its tag and data, and its rewrite is saved before anyone hears of it",
         ctx do
      script!(ctx.scope, ~S'''
      local d = event.data
      if not d then return nil end
      return event.text:upper() .. "|" .. (event.tag or "") .. "|" .. d.who .. "|" .. d.items[2] .. "|" .. event.by
      ''')

      {:ok, _} = Messages.send_message(ctx.scope, ctx.chat, ctx.player.id, "Look", attachments: [ctx.image])
      await_captions(1)
      :ok = Attachments.subscribe(ctx.chat.id)

      {:ok, callback} = CallbackStore.put("outfit", %{"who" => "Geralt", "items" => ["cloak", "sword"]})
      :ok = Captions.request(ctx.scope, ctx.chat, ctx.image.id, callback: callback)
      image_id = ctx.image.id
      assert_receive {:caption_finished, ^image_id}, 2_000

      # Read when the announcement arrives: a waiting reply would see exactly this.
      assert Repo.reload!(ctx.image).description == "A CAPTION|outfit|Geralt|sword|model"
      assert Repo.reload!(ctx.image).described_by_model_id == ctx.joy.id
      await_captions(1)
    end

    test "a person's edit runs it; composer typing waits for the send", ctx do
      script!(ctx.scope, ~S'return event.by .. ":" .. event.text')

      staged = Captions.put_manual_description(ctx.scope, ctx.chat.id, ctx.image, "typed", scripts?: false)
      assert staged.description == "typed"

      {:ok, message} = Messages.send_message(ctx.scope, ctx.chat, ctx.player.id, "Look", attachments: [staged])
      assert Repo.reload!(ctx.image).description == "typed"
      :ok = Captions.described_on_send(ctx.scope, ctx.chat, message)
      assert Repo.reload!(ctx.image).description == "person:typed"

      assert {:ok, _} = Captions.edit_description(ctx.scope, ctx.chat, ctx.image.id, "edited")
      assert Repo.reload!(ctx.image).description == "person:edited"
    end

    test "cannot loop: set_description inside it does not rerun it, and it cannot recaption its own image",
         ctx do
      script!(ctx.scope, ~S'''
      mw.images.set_description(event.image_id, event.text .. "+")
      local _, reason = mw.images.caption(event.image_id)
      return event.text .. "+" .. reason
      ''')

      {:ok, _} = Messages.send_message(ctx.scope, ctx.chat, ctx.player.id, "Look", attachments: [ctx.image])
      await_captions(1)

      assert Repo.reload!(ctx.image).description == "A caption+same_image"
      assert Repo.aggregate(Job, :count) == 1
    end
  end

  describe "images.auto_caption off" do
    test "sending and a new avatar queue nothing; asking still describes", ctx do
      :ok = Settings.put(ctx.scope, :user, "images.auto_caption", false)
      {:ok, _} = Messages.send_message(ctx.scope, ctx.chat, ctx.player.id, "Look", attachments: [ctx.image])
      {:ok, avatar} = Attachments.store_binary(png())
      :ok = Attachments.set_avatar(ctx.scope, ctx.bot, avatar)
      assert Repo.aggregate(Job, :count) == 0

      :ok = Captions.request(ctx.scope, ctx.chat, ctx.image.id)
      await_captions(1)
      assert Repo.aggregate(Job, :count) == 1
      assert Repo.reload!(ctx.image).description == "A caption"
    end
  end

  test "a sent image's one-off question replaces the caption prompt", ctx do
    :ok = Settings.put(ctx.scope, :user, "images.auto_caption", false)
    {:ok, _} = Messages.send_message(ctx.scope, ctx.chat, ctx.player.id, "Look", attachments: [ctx.image])

    :ok = Captions.request(ctx.scope, ctx.chat, ctx.image.id, instruction: "What colour is the fox?")
    assert_receive {:caption_body, body}, 2_000
    await_captions(1)

    assert %{"content" => [%{"type" => "text", "text" => "What colour is the fox?"}, _image]} =
             List.last(body["messages"])
  end

  describe "images.review_results" do
    setup ctx do
      :ok = Settings.put(ctx.scope, :user, "images.review_results", true)
      :ok = Attachments.subscribe(ctx.chat.id)
      :ok
    end

    defp held!(ctx) do
      {:ok, message} = Messages.send_message(ctx.scope, ctx.chat, ctx.player.id, "Look", attachments: [ctx.image])
      assert_receive {:job_changed, %{tag: :caption, status: :review}}, 2_000
      {message, Repo.one!(from j in Job, where: j.status == :review)}
    end

    test "holds a sent image's caption, and a waiting reply keeps waiting", ctx do
      {message, job} = held!(ctx)

      assert %Attachment{caption_status: :review, description: nil} = Repo.reload!(ctx.image)
      assert job.result["text"] == "A caption"
      assert Captions.pending_ids([message.id]) == [ctx.image.id]
      assert Jobs.review_count(ctx.scope, ctx.chat.id) == 0
      refute_received {:caption_finished, _}
      assert %{} = reviews = Captions.reviews(ctx.scope, ctx.chat)
      assert reviews[ctx.image.id].id == job.id
    end

    test "approving saves the edited text and releases the reply", ctx do
      {message, job} = held!(ctx)

      assert {:error, :blank} = Captions.approve(ctx.scope, job, "  ")
      assert {:ok, _} = Captions.approve(ctx.scope, job, " Edited ")

      image_id = ctx.image.id
      assert_receive {:caption_finished, ^image_id}
      assert %Attachment{caption_status: :done, description: "Edited"} = Repo.reload!(ctx.image)
      assert Repo.reload!(job).status == :completed
      assert Captions.pending_ids([message.id]) == []
      assert {:error, :not_in_review} = Captions.approve(ctx.scope, Repo.reload!(job), "Again")
    end

    test "discarding drops it and the image is undescribed again", ctx do
      {_message, job} = held!(ctx)

      assert :ok = Captions.discard(ctx.scope, job)
      assert %Attachment{caption_status: :none, description: nil} = Repo.reload!(ctx.image)
      assert Repo.reload!(job).status == :canceled
    end

    test "redescribing runs it again and holds the new text", ctx do
      {_message, job} = held!(ctx)

      assert :ok = Captions.retry(ctx.scope, job)
      assert Repo.reload!(ctx.image).caption_status in [:pending, :review]
      assert_receive {:job_changed, %{tag: :caption, status: :review}}, 2_000
      assert Repo.reload!(ctx.image).caption_status == :review
    end

    test "a description someone writes supersedes the held one", ctx do
      {_message, job} = held!(ctx)

      {:ok, _} = Captions.edit_description(ctx.scope, ctx.chat, ctx.image.id, "Mine")
      assert Repo.reload!(job).status == :canceled
      assert Repo.reload!(ctx.image).description == "Mine"
    end

    test "a composer image is never held", ctx do
      {:ok, _} = Captions.request_staged(ctx.scope, ctx.chat, ctx.image)
      await_captions(1)
      assert %Attachment{caption_status: :done, description: "A caption"} = Repo.reload!(ctx.image)
    end
  end

  describe "avatar descriptions" do
    test "a user's own character is described with the site captioner", ctx do
      user = scope!(%{role: :user})
      :ok = Jobs.subscribe(user)
      {:ok, character} = Characters.create_character(user, %{name: "Mine#{unique()}"})

      :ok = Attachments.set_avatar(user, character, ctx.image)
      await_captions(1)
      assert Characters.get_character!(character.id).appearance == "A caption"
    end

    test "images.avatar_updates_appearance off leaves a new avatar undescribed; the character's own flag wins",
         ctx do
      :ok = Settings.put(ctx.scope, :user, "images.avatar_updates_appearance", false)
      :ok = Attachments.set_avatar(ctx.scope, ctx.bot, ctx.image)
      assert Repo.aggregate(Job, :count) == 0
      assert Characters.get_character!(ctx.bot.id).appearance == nil

      {:ok, bot} = Characters.update_character(ctx.scope, ctx.bot, %{avatar_updates_appearance: true})
      {:ok, second} = Attachments.store_binary(png())
      :ok = Attachments.set_avatar(ctx.scope, bot, second)
      await_captions(1)
      assert Characters.get_character!(ctx.bot.id).appearance == "A caption"
    end

    test "with images.review_results on, an avatar's description is not held", ctx do
      :ok = Settings.put(ctx.scope, :user, "images.review_results", true)

      :ok = Attachments.set_avatar(ctx.scope, ctx.bot, ctx.image)
      await_captions(1)

      assert %Attachment{caption_status: :done, description: "A caption"} = Repo.reload!(ctx.image)
      assert Characters.get_character!(ctx.bot.id).appearance == "A caption"
    end
  end
end
