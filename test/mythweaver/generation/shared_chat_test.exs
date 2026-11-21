defmodule Mythweaver.Generation.SharedChatTest do
  # Not `async: true`: the generation GenServers and their AI tasks share the sandbox owner.
  use Mythweaver.DataCase

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.Analytics.GenerationStat
  alias Mythweaver.Attachments
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Generation
  alias Mythweaver.Jobs
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Messages
  alias Mythweaver.Messages.PromptSnapshot
  alias Mythweaver.Permissions
  alias Mythweaver.Prompts

  @frames [
    ~s(data: {"choices":[{"finish_reason":null,"index":0,"delta":{"content":"po"}}]}\n\n),
    ~s(data: {"choices":[{"finish_reason":null,"index":0,"delta":{"content":"ng"}}]}\n\n),
    ~s(data: {"choices":[{"finish_reason":"stop","index":0,"delta":{}}]}\n\n),
    ~s(data: {"choices":[],"usage":{"completion_tokens":3,"prompt_tokens":5,"total_tokens":8}}\n\n),
    "data: [DONE]\n\n"
  ]

  setup context do
    Req.Test.set_req_test_to_shared(context)

    Req.Test.stub(Mythweaver.AI, fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)

      Enum.reduce(@frames, conn, fn frame, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, frame)
        conn
      end)
    end)

    owner = scope!(%{role: :user})
    [player, bot, hero] = Enum.map(["Player", "Bot", "Hero"], &character!(owner, &1))

    {:ok, chat} =
      Chats.create_chat(owner, %{
        name: "Shared-#{unique()}",
        participants: Enum.map([player, bot, hero], &%{character_id: &1.id}),
        player_character_id: player.id
      })

    guest = scope!(%{role: :user})
    {:ok, member} = Chats.invite(owner, chat, guest.user.handle, :guest)
    {:ok, _} = Chats.accept_invite(guest, member.id)

    %{owner: owner, guest: guest, chat: Chats.get_chat(chat.id), player: player, bot: bot, hero: hero}
  end

  defp unique, do: System.unique_integer([:positive])

  defp png,
    do:
      Base.decode64!("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")

  defp character!(scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: "#{name}-#{unique()}"})
    character
  end

  defp idle?(scope, chat), do: match?(%{speaking: nil, queue: []}, Generation.status(scope, chat))

  defp own_model!(scope, opts \\ [], attrs \\ %{}) do
    {:ok, provider} =
      AI.create_provider(
        scope,
        %{name: "P-#{unique()}", adapter: :openai_compatible, base_url: "http://localhost:8080/v1"},
        opts
      )

    {:ok, model} = AI.create_model(scope, Map.merge(%{name: "M-#{unique()}", api_model_id: "gemma-4"}, attrs), opts)
    {:ok, _} = AI.link_model(scope, provider, model)
    model
  end

  defp global_prompt!(scope, opts \\ []) do
    {:ok, prompt} = Prompts.create_prompt(scope, %{name: "Prompt-#{unique()}"}, opts)
    {:ok, block} = Prompts.create_block(scope, %{name: "Sys-#{unique()}", content: "Be brief."}, opts)
    {:ok, _} = Prompts.add_block(scope, prompt, block)
    {:ok, _} = Prompts.bind_prompt(scope, prompt, :global)
    prompt
  end

  describe "a member's reply runs as the chat's owner" do
    test "on the owner's model, charged to the owner, attributed to the guest", ctx do
      %{owner: owner, guest: guest, chat: chat, bot: bot} = ctx
      model = own_model!(owner)
      global_prompt!(owner)
      :ok = Messages.subscribe(chat)
      :ok = Jobs.subscribe(guest)

      # The guest has no model of their own: only the owner's run resolves one.
      assert {:error, _} = AI.default_model(guest)
      assert :ok = Generation.generate(guest, chat, bot)

      assert_receive {:message_created, message}
      assert_receive {:generation_finished, _}
      assert_receive {:job_changed, %{status: :completed, id: job_id}}

      body = Messages.get_message!(owner, message.id).bodies |> Enum.find(& &1.active)
      assert body.content == "pong"
      assert Repo.get_by!(PromptSnapshot, message_body_id: body.id).ai_model_id == model.id

      assert %Job{user_id: guest_id} = Repo.get!(Job, job_id)
      assert guest_id == guest.user.id

      assert [%GenerationStat{user_id: stat_user, ai_model_id: stat_model}] =
               Repo.all(from(s in GenerationStat, where: s.job_id == ^job_id))

      assert stat_user == owner.user.id and stat_model == model.id
    end

    test "the owner's spent budget refuses the guest; the guest's own does not count", ctx do
      %{owner: owner, guest: guest, chat: chat, bot: bot} = ctx
      admin = scope!()
      site = own_model!(admin, site: true)
      global_prompt!(admin, site: true)
      {:ok, _} = Chats.update_chat(owner, chat, %{ai_model_id: site.id})
      chat = Chats.get_chat(chat.id)

      :ok = Permissions.put_grant!(guest.user, "quota.spend_per_day", 0)
      guest = Scope.for_user(guest.user)

      assert {:ok, _opts} =
               Generation.prepare(
                 Chats.run_scope(guest, chat),
                 chat,
                 bot,
                 :new,
                 nil,
                 [],
                 Chats.spend_scope(guest, chat)
               )

      :ok = Permissions.put_grant!(owner.user, "quota.spend_per_day", 0)
      assert Generation.generate(guest, chat, bot) == {:error, :quota_exceeded}
    end
  end

  describe "turn_mode :round" do
    setup %{owner: owner, guest: guest, chat: chat, player: player, hero: hero} do
      own_model!(owner)
      global_prompt!(owner)
      {:ok, _} = Chats.update_chat(owner, chat, %{reply_strategy: :list})
      {:ok, chat} = Chats.update_membership_settings(owner, Chats.get_chat(chat.id), %{turn_mode: :round})
      {:ok, _} = Chats.assign_characters(owner, chat, owner.user.id, [player.id])
      {:ok, _} = Chats.assign_characters(owner, chat, guest.user.id, [hero.id])
      :ok = Messages.subscribe(chat)
      %{chat: Chats.get_chat(chat.id)}
    end

    test "waits until both locked humans posted, and never speaks for a held character", ctx do
      %{owner: owner, guest: guest, chat: chat, bot: bot} = ctx

      {:ok, _} = Messages.send_message(owner, chat, nil, "My turn")
      assert :ok = Generation.respond(owner, chat)
      assert idle?(owner, chat)

      {:ok, said} = Messages.send_message(guest, chat, nil, "And mine")
      assert said.author_character_id == ctx.hero.id
      assert :ok = Generation.respond(guest, chat)

      assert_receive {:generation_finished, _}
      assert [_, _, %{author_character_id: author}] = Messages.list_messages(chat)
      assert author == bot.id
      Generation.cancel(owner, chat)
    end

    test "a skip counts as the skipper's post", %{owner: owner, guest: guest, chat: chat} do
      {:ok, _} = Messages.send_message(owner, chat, nil, "Anyone?")
      assert :ok = Generation.respond(owner, chat)
      assert idle?(owner, chat)

      assert Generation.skip_turn(scope!(), chat) == {:error, :unauthorized}
      assert :ok = Generation.skip_turn(guest, chat)

      assert_receive {:generation_finished, _}
      assert length(Messages.list_messages(chat)) == 2
      Generation.cancel(owner, chat)
    end

    test "waits for one post per holder, whichever of their characters it is", ctx do
      %{owner: owner, guest: guest, chat: chat, bot: bot, hero: hero} = ctx
      extra = character!(owner, "Extra")
      {:ok, _} = Chats.add_participants(owner, chat, [extra.id])
      chat = Chats.get_chat(chat.id)
      {:ok, _} = Chats.assign_characters(owner, chat, guest.user.id, [hero.id, extra.id])

      {:ok, _} = Messages.send_message(owner, chat, nil, "My turn")
      assert :ok = Generation.respond(owner, chat)
      assert idle?(owner, chat)

      {:ok, said} = Messages.send_message(guest, chat, extra.id, "As the extra")
      assert said.author_character_id == extra.id
      assert :ok = Generation.respond(guest, chat)

      assert_receive {:generation_finished, _}
      assert [_, _, %{author_character_id: author}] = Messages.list_messages(chat)
      assert author == bot.id
      Generation.cancel(owner, chat)
    end
  end

  describe "a member's model source" do
    test "an :own guest's reply runs on the guest's model, attributed to the guest", ctx do
      %{owner: owner, guest: guest, chat: chat, bot: bot} = ctx
      owner_model = own_model!(owner)
      {:ok, _} = Chats.update_chat(owner, chat, %{ai_model_id: owner_model.id})
      global_prompt!(owner)
      guest_model = own_model!(guest)

      member = Chats.member_for(guest, chat)
      {:ok, _} = Chats.set_model_source(owner, member.id, :own)
      {:ok, _} = Chats.set_member_model(guest, chat, guest_model.id)
      chat = Chats.get_chat(chat.id)

      :ok = Jobs.subscribe(guest)
      :ok = Messages.subscribe(chat)
      assert :ok = Generation.generate(guest, chat, bot)
      assert_receive {:job_changed, %{status: :completed, id: job_id}}, 5_000
      assert_receive {:generation_finished, _}, 5_000

      assert %Job{user_id: user_id, ai_model_id: model_id} = Repo.get!(Job, job_id)
      assert user_id == guest.user.id
      assert model_id == guest_model.id
    end

    test "an :owner guest's reply runs on the chat's model", ctx do
      %{owner: owner, guest: guest, chat: chat, bot: bot} = ctx
      owner_model = own_model!(owner)
      {:ok, _} = Chats.update_chat(owner, chat, %{ai_model_id: owner_model.id})
      global_prompt!(owner)
      own_model!(guest)
      chat = Chats.get_chat(chat.id)

      :ok = Jobs.subscribe(guest)
      :ok = Messages.subscribe(chat)
      assert :ok = Generation.generate(guest, chat, bot)
      assert_receive {:job_changed, %{status: :completed, id: job_id}}, 5_000
      assert_receive {:generation_finished, _}, 5_000

      assert %Job{user_id: user_id, ai_model_id: model_id} = Repo.get!(Job, job_id)
      assert user_id == guest.user.id
      assert model_id == owner_model.id
    end

    test "an :own guest's reply describes images with the guest's caption model, not the owner's", ctx do
      %{owner: owner, guest: guest, chat: chat, player: player, bot: bot} = ctx
      # The owner's model sees images, so on the owner's side nothing would be described.
      owner_model = own_model!(owner, [], %{supports_images: true})
      {:ok, _} = Chats.update_chat(owner, chat, %{ai_model_id: owner_model.id})
      global_prompt!(owner)
      guest_captioner = own_model!(guest, [], %{supports_images: true})
      guest_model = own_model!(guest, [], %{caption_model_id: guest_captioner.id})

      member = Chats.member_for(guest, chat)
      {:ok, _} = Chats.set_model_source(owner, member.id, :own)
      {:ok, _} = Chats.set_member_model(guest, chat, guest_model.id)
      chat = Chats.get_chat(chat.id)

      {:ok, image} = Attachments.store_binary(png())
      {:ok, _} = Messages.send_message(owner, chat, player.id, "Look", attachments: [image])
      assert Repo.all(from(j in Job, where: j.tag == :caption)) == []

      :ok = Messages.subscribe(chat)
      assert :ok = Generation.generate(guest, chat, bot)
      assert_receive {:generation_finished, _}, 5_000

      assert [%Job{user_id: user_id, ai_model_id: captioner_id}] = Repo.all(from(j in Job, where: j.tag == :caption))
      assert user_id == guest.user.id
      assert captioner_id == guest_captioner.id
    end
  end
end
