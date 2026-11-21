defmodule Mythweaver.VariablesTest do
  use Mythweaver.DataCase

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Messages
  alias Mythweaver.Variables

  setup do
    %{scope: scope!()}
  end

  describe "create_variable/3" do
    test "stores and reloads any JSON value", %{scope: scope} do
      chat = chat!(scope)

      for {value, i} <- Enum.with_index(["s", 42, 1.5, false, "", [1, "a"], %{"a" => [1]}]) do
        {:ok, variable} = Variables.create_variable(scope, chat.id, %{key: "v#{i}", value: value})
        assert Variables.get_variable!(variable.id).value == value
      end
    end

    test "a global variable needs an admin" do
      assert Variables.create_variable(%Scope{}, nil, %{key: "g", value: 1}) == {:error, :unauthorized}
    end

    test "a missing value is an error, a non-JSON one too", %{scope: scope} do
      assert {:error, changeset} = Variables.create_variable(scope, nil, %{key: "k"})
      assert %{value: ["can't be blank"]} = errors_on(changeset)

      assert {:error, changeset} = Variables.create_variable(scope, nil, %{key: "k", value: %{a: 1}})
      assert %{value: ["is invalid"]} = errors_on(changeset)

      assert {:error, changeset} = Variables.create_variable(scope, nil, %{key: "", value: "x"})
      assert %{key: ["can't be blank"]} = errors_on(changeset)
    end

    test "keys are unique per chat and among globals, and must be identifiers", %{scope: scope} do
      chat = chat!(scope)
      other = chat!(scope)

      {:ok, _} = Variables.create_variable(scope, chat.id, %{key: "hp", value: 1})
      assert {:error, changeset} = Variables.create_variable(scope, chat.id, %{key: "hp", value: 2})
      assert %{key: ["is already taken"]} = errors_on(changeset)

      assert {:ok, _} = Variables.create_variable(scope, other.id, %{key: "hp", value: 3})
      assert {:ok, _} = Variables.create_variable(scope, nil, %{key: "hp", value: 4})
      assert {:error, changeset} = Variables.create_variable(scope, nil, %{key: "hp", value: 5})
      assert %{key: ["is already taken"]} = errors_on(changeset)

      assert {:error, changeset} = Variables.create_variable(scope, chat.id, %{key: "bad key", value: 1})
      assert %{key: [message]} = errors_on(changeset)
      assert message =~ "must start with a letter or underscore"
    end
  end

  describe "apply_writes/2" do
    test "the last write per key wins and a nil write deletes", %{scope: scope} do
      chat = chat!(scope)
      {:ok, _} = Variables.create_variable(scope, chat.id, %{key: "gone", value: 1})

      :ok =
        Variables.apply_writes(chat.id, [
          write("chat", "mood", "calm"),
          write("chat", "mood", "tense"),
          write("chat", "gone", nil),
          write("global", "mood", "global")
        ])

      assert Variables.values(chat.id) == %{chat: %{"mood" => "tense"}, global: %{"mood" => "global"}}
      assert length(Variables.list_chat_variables(scope, chat.id)) == 1
      assert length(Variables.list_global_variables(scope)) == 1
    end

    test "updates an existing row in place", %{scope: scope} do
      chat = chat!(scope)
      {:ok, variable} = Variables.create_variable(scope, chat.id, %{key: "hp", value: 10})

      :ok = Variables.apply_writes(chat.id, [write("chat", "hp", 9)])

      assert Variables.get_variable!(variable.id).value == 9
    end

    test "announces chat and global changes", %{scope: scope} do
      chat = chat!(scope)
      Messages.subscribe(chat)
      Mythweaver.Changes.subscribe(scope, [:variables])

      :ok = Variables.apply_writes(chat.id, [write("chat", "a", 1), write("global", "b", 2)])

      chat_id = chat.id
      assert_receive {:variables_changed, ^chat_id}
      assert_receive {Mythweaver.Changes, :variables}
    end

    test "a user's own global writes reach only that user's topic" do
      a = scope!(%{role: :user})
      b = scope!(%{role: :user})
      chat = chat!(a)
      Mythweaver.Changes.subscribe(b, [:variables])

      :ok = Variables.apply_writes(chat.id, [write("global", "b", 2)])
      {:ok, _} = Variables.create_variable(a, nil, %{key: "mood", value: "mine"})
      refute_receive {Mythweaver.Changes, :variables}, 100

      Mythweaver.Changes.subscribe(a, [:variables])
      :ok = Variables.apply_writes(chat.id, [write("global", "b", 3)])
      assert_receive {Mythweaver.Changes, :variables}
    end
  end

  describe "global ownership" do
    test "a user creates and edits their own; site globals are admin-only", %{scope: admin} do
      user = scope!(%{role: :user})
      other = scope!(%{role: :user})
      {:ok, site} = Variables.create_variable(admin, nil, %{key: "mood", value: "site"}, site: true)
      {:ok, own} = Variables.create_variable(user, nil, %{key: "mood", value: "mine"})

      assert own.user_id == user.user.id
      assert is_nil(site.user_id)
      assert Enum.map(Variables.list_global_variables(user), & &1.id) == [own.id]

      assert Enum.map(Variables.list_usable_global_variables(user), & &1.id) |> Enum.sort() ==
               Enum.sort([own.id, site.id])

      assert Variables.list_global_variables(other) == []
      refute Enum.any?(Variables.list_global_variables(admin), &(&1.id == own.id))
      assert Variables.get_global_variable(user, site.id) == nil
      assert Variables.get_global_variable(admin, own.id) == nil

      assert Variables.update_variable(user, site, %{value: "x"}) == {:error, :unauthorized}
      assert Variables.update_variable(admin, own, %{value: "x"}) == {:error, :unauthorized}
      assert Variables.delete_variable(other, own) == {:error, :unauthorized}
      assert {:ok, %{value: "new"}} = Variables.update_variable(user, own, %{value: "new"})
    end

    test "a chat reads site globals overlaid by its owner's; writes go to the owner's own", %{scope: admin} do
      user = scope!(%{role: :user})
      other = scope!(%{role: :user})
      {:ok, site} = Variables.create_variable(admin, nil, %{key: "mood", value: "site"}, site: true)
      {:ok, _} = Variables.create_variable(admin, nil, %{key: "time", value: "noon"}, site: true)
      {:ok, _} = Variables.create_variable(user, nil, %{key: "mood", value: "mine"})
      {:ok, _} = Variables.create_variable(other, nil, %{key: "secret", value: 1})
      chat = chat!(user)

      assert Variables.values(chat.id).global == %{"mood" => "mine", "time" => "noon"}

      :ok = Variables.apply_writes(chat.id, [write("global", "time", "dusk"), write("global", "new", true)])

      assert Variables.get_variable!(Enum.find(Variables.list_global_variables(admin), &(&1.key == "time")).id).value ==
               "noon"

      assert Variables.get_variable!(site.id).value == "site"
      assert Variables.values(chat.id).global == %{"mood" => "mine", "time" => "dusk", "new" => true}

      assert Enum.map(Variables.list_global_variables(user), &{&1.key, &1.value}) ==
               [{"mood", "mine"}, {"new", true}, {"time", "dusk"}]

      :ok = Variables.apply_writes(chat.id, [write("global", "time", nil)])
      assert Variables.values(chat.id).global["time"] == "noon"
    end
  end

  defp write(level, key, value), do: %{"scope" => level, "key" => key, "value" => value}

  defp chat!(scope) do
    [player, other] =
      for _ <- 1..2 do
        {:ok, c} = Characters.create_character(scope, %{name: "c-#{System.unique_integer([:positive])}"})
        c
      end

    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: "chat-#{System.unique_integer([:positive])}",
        participants: [%{character_id: player.id}, %{character_id: other.id}],
        player_character_id: player.id
      })

    chat
  end
end
