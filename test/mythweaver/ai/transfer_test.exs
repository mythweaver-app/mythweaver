defmodule Mythweaver.AI.TransferTest do
  use Mythweaver.DataCase

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.AI.Model
  alias Mythweaver.AI.Provider
  alias Mythweaver.AI.ProviderModel
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat

  defp unique, do: System.unique_integer([:positive])

  defp provider!(scope, opts \\ []) do
    {:ok, provider} =
      AI.create_provider(
        scope,
        %{name: "P-#{unique()}", adapter: :openai_compatible, base_url: "http://localhost:8080/v1"},
        opts
      )

    provider
  end

  defp model!(scope, opts \\ []) do
    {:ok, model} = AI.create_model(scope, %{name: "M-#{unique()}", api_model_id: "gemma-4"}, opts)
    model
  end

  defp chat!(scope, model) do
    {:ok, a} = Characters.create_character(scope, %{name: "A-#{unique()}"})
    {:ok, b} = Characters.create_character(scope, %{name: "B-#{unique()}"})

    {:ok, chat} =
      Chats.create_chat(scope, %{
        participants: [%{character_id: a.id}, %{character_id: b.id}],
        player_character_id: a.id,
        ai_model_id: model.id
      })

    chat
  end

  describe "creating" do
    test "a site manager's connection and model are their own unless site is asked for" do
      admin = scope!()

      assert %Provider{user_id: nil} = provider!(admin, site: true)
      assert %Provider{user_id: uid} = provider!(admin)
      assert uid == admin.user.id
      assert %Model{user_id: ^uid} = model!(admin)
      assert %Model{user_id: nil} = model!(admin, site: true)
    end

    test "without ai.connections.create a site manager's default is the site; site needs site.ai.manage" do
      :ok = Mythweaver.Permissions.put_grant!(:everyone, "ai.connections.create", :deny)
      admin = scope!()
      user = scope!(%{role: :user})

      assert {:ok, %Provider{user_id: nil}} = AI.create_provider(admin, %{name: "X", base_url: "http://x"})
      assert AI.create_provider(user, %{name: "Y", base_url: "http://y"}, site: true) == {:error, :unauthorized}
    end
  end

  describe "transfer/3" do
    test "a connection moves with its models, which leave the old owner's other connections" do
      admin = scope!()
      mine = provider!(admin)
      other = provider!(admin)
      model = model!(admin)
      {:ok, _} = AI.link_model(admin, mine, model)
      {:ok, _} = AI.link_model(admin, other, model)

      assert {:ok, {%{models: 1, links: 1}, []}} = AI.transfer_impact(admin, mine, :site)
      assert {:ok, %Provider{user_id: nil}} = AI.transfer(admin, mine, :site)

      assert Repo.get!(Model, model.id).user_id == nil
      assert [%ProviderModel{provider_id: provider_id}] = Repo.all_by(ProviderModel, ai_model_id: model.id)
      assert provider_id == mine.id
    end

    test "a moved model drops a personal caption model" do
      admin = scope!()
      caption = model!(admin)
      model = model!(admin)
      model = model |> Ecto.Changeset.change(caption_model_id: caption.id) |> Repo.update!()

      assert {:ok, {%{caption_models: 1}, []}} = AI.transfer_impact(admin, model, :site)
      assert {:ok, %Model{user_id: nil, caption_model_id: nil}} = AI.transfer(admin, model, :site)
    end

    test "moving to the site keeps the old owner's references" do
      admin = scope!()
      model = model!(admin)
      chat = chat!(admin, model)

      assert {:ok, %Model{user_id: nil}} = AI.transfer(admin, model, :site)
      assert Repo.get!(Chat, chat.id).ai_model_id == model.id
    end

    test "a name the site already has refuses the move" do
      admin = scope!()
      {:ok, own} = AI.create_model(admin, %{name: "Same", api_model_id: "x"})
      {:ok, _} = AI.create_model(admin, %{name: "Same", api_model_id: "x"}, site: true)

      assert {:ok, {_impact, ["Same"]}} = AI.transfer_impact(admin, own, :site)
      assert AI.transfer(admin, own, :site) == {:error, {:name_taken, ["Same"]}}
      assert Repo.get!(Model, own.id).user_id == admin.user.id
    end

    test "needs site.ai.manage and sudo mode, and never makes a site row personal" do
      user = scope!(%{role: :user})
      own = model!(user)
      admin = scope!()
      mine = model!(admin)
      site = model!(admin, site: true)

      assert AI.transfer(user, own, :site) == {:error, :unauthorized}
      assert AI.transfer(%{admin | sudo_until: nil}, mine, :site) == {:error, :sudo_required}
      assert AI.transfer(admin, site, :site) == {:error, :same_owner}
      # A runtime atom: the compiler already knows no clause takes `:personal`.
      assert_raise FunctionClauseError, fn -> AI.transfer(admin, site, String.to_existing_atom("personal")) end
      assert Scope.can?(admin, "site.ai.manage")
    end
  end
end
