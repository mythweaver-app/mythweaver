defmodule Mythweaver.Permissions.QuotaTest do
  use Mythweaver.DataCase

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.AI.ProviderModel
  alias Mythweaver.Analytics.GenerationStat
  alias Mythweaver.Attachments
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Generation
  alias Mythweaver.Permissions
  alias Mythweaver.Prompts

  defp unique, do: System.unique_integer([:positive])

  defp limited!(key, limit) do
    scope = scope!(%{role: :user})
    :ok = Permissions.put_grant!(scope.user, key, limit)
    Scope.for_user(scope.user)
  end

  defp model!(scope, opts \\ []) do
    {:ok, provider} =
      AI.create_provider(
        scope,
        %{
          name: "P-#{unique()}",
          adapter: :openai_compatible,
          base_url: "http://localhost:8080/v1"
        },
        opts
      )

    {:ok, model} = AI.create_model(scope, %{name: "M-#{unique()}", api_model_id: "gemma-4"}, opts)
    {:ok, _} = AI.link_model(scope, provider, model)
    model
  end

  defp character!(scope) do
    {:ok, character} = Characters.create_character(scope, %{name: "C-#{unique()}"})
    character
  end

  defp chat!(scope, model) do
    player = character!(scope)
    bot = character!(scope)

    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: "chat-#{unique()}",
        participants: [%{character_id: player.id}, %{character_id: bot.id}],
        player_character_id: player.id,
        ai_model_id: model.id
      })

    {Chats.get_chat!(chat.id), bot}
  end

  defp spent!(scope, model, cost) do
    Repo.insert!(%GenerationStat{
      user_id: scope.user.id,
      ai_model_id: model.id,
      provider_id:
        Repo.one(from(pm in ProviderModel, where: pm.ai_model_id == ^model.id, select: pm.provider_id, limit: 1)),
      job_id: Mythweaver.Schema.generate_id(),
      tag: :reply,
      origin: :interactive,
      status: :completed,
      prompt_tokens: 1_000_000,
      completion_tokens: 40,
      cost: cost && Decimal.new(cost),
      finished_at: DateTime.utc_now()
    })
  end

  describe "spending per day" do
    setup do
      admin = scope!()
      {:ok, prompt} = Prompts.create_prompt(admin, %{name: "Prompt-#{unique()}"}, site: true)
      {:ok, block} = Prompts.create_block(admin, %{name: "Sys-#{unique()}", content: "Be brief."}, site: true)
      {:ok, _} = Prompts.add_block(admin, prompt, block)
      {:ok, _} = Prompts.bind_prompt(admin, prompt, :global)
      %{admin: admin}
    end

    test "a spent limit refuses the site's models but never the user's own", %{admin: admin} do
      user = limited!("quota.spend_per_day", 100)
      site = model!(admin, site: true)
      {chat, bot} = chat!(user, site)

      # Tokens alone cost nothing: only a run's cost counts.
      spent!(user, site, nil)
      spent!(user, site, "0.99")
      assert {:ok, _} = Generation.prepare(user, chat, bot, :new, nil, [], user)

      spent!(user, site, "0.01")
      assert Generation.prepare(user, chat, bot, :new, nil, [], user) == {:error, :quota_exceeded}

      own = model!(user)
      {own_chat, own_bot} = chat!(user, own)
      spent!(user, own, "50")
      assert {:ok, _} = Generation.prepare(user, own_chat, own_bot, :new, nil, [], user)
    end
  end

  test "a count limit refuses the next own row" do
    user = limited!("quota.characters", 1)

    assert {:ok, _} = Characters.create_character(user, %{name: "One"})
    assert Characters.create_character(user, %{name: "Two"}) == {:error, :quota_exceeded}
  end

  test "an upload limit refuses a file past it" do
    user = limited!("quota.upload_bytes", 1)
    path = Path.join(System.tmp_dir!(), "#{unique()}-fox.png")

    File.write!(
      path,
      Base.decode64!("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")
    )

    on_exit(fn -> File.rm(path) end)

    assert Attachments.store_file(user, path) == {:error, :quota_exceeded}
  end
end
