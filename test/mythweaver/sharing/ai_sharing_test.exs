defmodule Mythweaver.Sharing.AISharingTest do
  use Mythweaver.DataCase

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.AI.ProviderModel
  alias Mythweaver.Analytics.GenerationStat
  alias Mythweaver.Assistant.Tools
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Permissions
  alias Mythweaver.Permissions.Quota
  alias Mythweaver.Sharing

  setup do
    %{owner: ai_user!(), sub: ai_user!()}
  end

  defp ai_user! do
    scope = scope!(%{role: :user})
    :ok = Permissions.put_grant!(scope.user, "ai.connections.create", :allow)
    rescope(scope)
  end

  defp rescope(scope), do: Scope.for_user(Accounts.get_user(scope.user.id))

  defp handle(scope), do: "@" <> scope.user.handle

  defp provider!(scope, name) do
    {:ok, provider} =
      AI.create_provider(scope, %{name: name, adapter: :openai_compatible, base_url: "http://localhost:8080/v1"})

    provider
  end

  defp model!(scope) do
    {:ok, model} =
      AI.create_model(scope, %{name: "Shared #{System.unique_integer([:positive])}", api_model_id: "secret-id"})

    model
  end

  defp share!(owner, sub, model, opts) do
    {:ok, share} = Sharing.invite(owner, model, handle(sub), [role: :subscriber] ++ opts)
    {:ok, share} = Sharing.accept(sub, share.id)
    share
  end

  defp owner_key!(owner) do
    :ok = Permissions.put_grant!(owner.user, "sharing.ai.owner_key", :allow)
    rescope(owner)
  end

  defp chat!(scope, model) do
    {:ok, a} = Characters.create_character(scope, %{name: "A"})
    {:ok, b} = Characters.create_character(scope, %{name: "B"})

    {:ok, chat} =
      Chats.create_chat(scope, %{
        participants: [%{character_id: a.id}, %{character_id: b.id}],
        player_character_id: a.id,
        ai_model_id: model.id
      })

    chat
  end

  test "owner-key invites need sharing.ai.owner_key", %{owner: owner, sub: sub} do
    model = model!(owner)
    assert {:error, :unauthorized} = Sharing.invite(owner, model, handle(sub), ai_mode: :owner_key)
    assert {:error, :unauthorized} = Sharing.invite(owner, model, handle(sub), token_limit_per_day: 5)

    owner = owner_key!(owner)

    assert {:ok, %{ai_mode: :owner_key, token_limit_per_day: 5}} =
             Sharing.invite(owner, model, handle(sub), ai_mode: :owner_key, token_limit_per_day: 5)

    {:ok, character} = Characters.create_character(owner, %{name: "C"})
    assert {:error, :unauthorized} = Sharing.invite(owner, character, handle(sub), ai_mode: :own_key)
  end

  test "set_ai_mode/4 follows the invite rules", %{owner: owner, sub: sub} do
    model = model!(owner)
    share = share!(owner, sub, model, [])
    assert share.ai_mode == :own_key
    assert {:error, :unauthorized} = Sharing.set_ai_mode(owner, share.id, :owner_key, nil)
    assert {:error, :unauthorized} = Sharing.set_ai_mode(sub, share.id, :own_key, nil)

    owner = owner_key!(owner)
    assert {:ok, %{ai_mode: :owner_key, token_limit_per_day: 10}} = Sharing.set_ai_mode(owner, share.id, :owner_key, 10)
  end

  test "an own-key subscriber's run picks only their own link", %{owner: owner, sub: sub} do
    model = model!(owner)
    {:ok, _} = AI.link_model(owner, provider!(owner, "Owner's"), model)
    mine = provider!(sub, "Mine")
    assert {:error, :unauthorized} = AI.link_model(sub, mine, model)

    share!(owner, sub, model, [])
    assert {:ok, %ProviderModel{}} = AI.link_model(sub, mine, model)

    for _ <- 1..3 do
      assert {:ok, %{provider: %{name: "Mine"}}} = AI.next_provider_model(model, sub.user.id)
    end

    for _ <- 1..3 do
      assert {:ok, %{provider: %{name: "Owner's"}}} = AI.next_provider_model(model, owner.user.id)
    end
  end

  test "an owner-key subscriber's run uses the owner's link until the permission goes", %{owner: owner, sub: sub} do
    owner = owner_key!(owner)
    model = model!(owner)
    {:ok, _} = AI.link_model(owner, provider!(owner, "Owner's"), model)

    assert {:error, :no_provider} = AI.next_provider_model(model, sub.user.id)
    share!(owner, sub, model, ai_mode: :owner_key)
    assert {:ok, %{provider: %{name: "Owner's"}}} = AI.next_provider_model(model, sub.user.id)

    :ok = Permissions.put_grant!(owner.user, "sharing.ai.owner_key", :deny)
    name = model.name
    assert {:error, {:owner_key_withdrawn, ^name}} = AI.next_provider_model(model, sub.user.id)

    assert Mythweaver.Jobs.error_message({:owner_key_withdrawn, name}) ==
             "The owner no longer shares their connection for #{name}."
  end

  test "an owner-key token limit refuses once the day's tokens reach it", %{owner: owner, sub: sub} do
    owner = owner_key!(owner)
    model = model!(owner)
    provider = provider!(owner, "Owner's")
    {:ok, _} = AI.link_model(owner, provider, model)
    share!(owner, sub, model, ai_mode: :owner_key, token_limit_per_day: 100)

    stat = fn tokens ->
      Repo.insert!(%GenerationStat{
        user_id: sub.user.id,
        ai_model_id: model.id,
        provider_id: provider.id,
        job_id: Mythweaver.Schema.generate_id(),
        tag: :reply,
        origin: :interactive,
        status: :completed,
        prompt_tokens: tokens,
        completion_tokens: 0,
        finished_at: DateTime.utc_now()
      })
    end

    stat.(60)
    assert :ok = Quota.check_spend(sub, model, sub.user.id)
    stat.(40)
    assert {:error, :quota_exceeded} = Quota.check_spend(sub, model, sub.user.id)
    assert :ok = Quota.check_spend(owner, model, owner.user.id)
  end

  test "removing the share clears the subscriber's chat model and own link", %{owner: owner, sub: sub} do
    model = model!(owner)
    share = share!(owner, sub, model, [])
    {:ok, link} = AI.link_model(sub, provider!(sub, "Mine"), model)
    chat = chat!(sub, model)
    assert chat.ai_model_id == model.id

    assert {:ok, impact} = Sharing.remove(owner, share.id)
    assert impact[:chat_models] == 1
    assert impact[:model_links] == 1
    assert Chats.get_chat!(chat.id).ai_model_id == nil
    refute Repo.get(ProviderModel, link.id)
  end

  test "the assistant hides a Runtime-only subscriber's api_model_id", %{owner: owner, sub: sub} do
    model = model!(owner)
    share!(owner, sub, model, visibility: :runtime_only)
    {:ok, tool} = Tools.fetch("list_models")

    assert {:ok, %{"models" => rows}} = Tools.run(sub, tool, %{})
    row = Enum.find(rows, &(&1["id"] == model.id))
    assert row["api_model_id"] == nil
    assert row["content_hidden"] == true

    assert {:ok, %{"models" => rows}} = Tools.run(owner, tool, %{})
    assert Enum.find(rows, &(&1["id"] == model.id))["api_model_id"] == "secret-id"
  end
end
