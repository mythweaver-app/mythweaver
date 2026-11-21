defmodule Mythweaver.ChatsTest do
  use Mythweaver.DataCase

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Schema

  setup do
    %{scope: scope!()}
  end

  defp character(scope, name, opts \\ []) do
    {:ok, character} = Characters.create_character(scope, %{name: name}, opts)
    character
  end

  defp owned_chat!(scope, owner, name) do
    [c1, c2] = [character(scope, "A-#{name}", site: true), character(scope, "B-#{name}", site: true)]

    {:ok, chat} =
      Chats.create_chat(owner, %{name: name, participants: [%{character_id: c1.id}, %{character_id: c2.id}]})

    chat
  end

  describe "ownership" do
    setup %{scope: scope} do
      me = scope!()
      other = scope!(%{nickname: "Other"})

      %{
        me: me,
        mine: owned_chat!(scope, me, "Mine"),
        theirs: owned_chat!(scope, other, "Theirs"),
        unowned: owned_chat!(scope, nil, "Loose")
      }
    end

    test "list_chats/1 returns only the scope's own chats, for an admin too", %{me: me, mine: mine} do
      assert Scope.can?(me, "users.manage")
      assert Enum.map(Chats.list_chats(me), & &1.id) == [mine.id]
    end

    test "chat_options/1 lists only the scope's own chats by title", %{me: me, mine: mine} do
      assert Chats.chat_options(me) == [{"Mine", mine.id}]
    end

    test "an admin cannot open or act on another user's or an unowned chat",
         %{me: me, theirs: theirs, unowned: unowned} do
      refute Chats.get_chat(me, theirs.id)
      assert Chats.authorize(me, theirs, :read) == {:error, :unauthorized}
      assert Chats.authorize(me, unowned.id, :read) == {:error, :unauthorized}
    end

    test "authorize/3 refuses a user-less scope and admits the owner", %{me: me, mine: mine} do
      assert Chats.authorize(%Scope{}, mine, :read) == {:error, :unauthorized}
      assert Chats.authorize(me, mine.id, :delete) == :ok
    end
  end

  describe "create_chat/1" do
    test "with two participants succeeds", %{scope: scope} do
      c1 = character(scope, "Aqua")
      c2 = character(scope, "Kazuma")

      assert {:ok, %Chat{} = chat} =
               Chats.create_chat(scope, %{
                 name: "Tavern",
                 participants: [%{character_id: c1.id}, %{character_id: c2.id}]
               })

      assert chat.name == "Tavern"
      assert length(chat.participants) == 2
    end

    test "with one participant fails the minimum", %{scope: scope} do
      c1 = character(scope, "Aqua")

      assert {:error, changeset} =
               Chats.create_chat(scope, %{participants: [%{character_id: c1.id}]})

      assert "must have at least 2 participants" in errors_on(changeset).participants
    end

    test "with the same character twice violates the unique constraint", %{scope: scope} do
      c1 = character(scope, "Aqua")

      assert {:error, changeset} =
               Chats.create_chat(scope, %{
                 participants: [%{character_id: c1.id}, %{character_id: c1.id}]
               })

      refute changeset.valid?
    end

    test "with player_character_id among participants persists it", %{scope: scope} do
      c1 = character(scope, "Aqua")
      c2 = character(scope, "Kazuma")

      assert {:ok, %Chat{} = chat} =
               Chats.create_chat(scope, %{
                 player_character_id: c1.id,
                 participants: [%{character_id: c1.id}, %{character_id: c2.id}]
               })

      assert chat.player_character_id == c1.id
    end

    test "with player_character_id not among participants fails", %{scope: scope} do
      c1 = character(scope, "Aqua")
      c2 = character(scope, "Kazuma")
      outsider = character(scope, "Darkness")

      assert {:error, changeset} =
               Chats.create_chat(scope, %{
                 player_character_id: outsider.id,
                 participants: [%{character_id: c1.id}, %{character_id: c2.id}]
               })

      assert %{player_character_id: ["must be a participant of the chat"]} =
               errors_on(changeset)
    end

    test "refuses a greeting by the player, by an outsider, or a blank narrator's message", %{scope: scope} do
      c1 = character(scope, "Aqua")
      c2 = character(scope, "Kazuma")
      outsider = character(scope, "Darkness")
      base = %{player_character_id: c1.id, participants: [%{character_id: c1.id}, %{character_id: c2.id}]}

      for greeter <- [c1.id, outsider.id] do
        assert {:error, changeset} = Chats.create_chat(scope, Map.put(base, :greeting, greeter))
        assert %{greeting: ["must be one of the chat's characters other than the player"]} = errors_on(changeset)
      end

      assert {:error, changeset} = Chats.create_chat(scope, Map.merge(base, %{greeting: "custom", greeting_text: " "}))
      assert %{greeting_text: ["write the narrator's message"]} = errors_on(changeset)

      assert {:ok, %Chat{greeting: greeting}} = Chats.create_chat(scope, Map.put(base, :greeting, c2.id))
      assert greeting == c2.id
    end
  end

  describe "assistant chats" do
    test "create_assistant_chat/1 needs no participants and counts toward quota.chats" do
      user = scope!(%{role: :user})
      :ok = Mythweaver.Permissions.put_grant!(user.user, "quota.chats", 1)
      user = Scope.for_user(user.user)

      assert {:ok, %Chat{kind: :assistant, participants: [], player_character_id: nil}} =
               Chats.create_assistant_chat(user)

      assert Chats.create_assistant_chat(user) == {:error, :quota_exceeded}
    end

    test "list_chats/2 splits the scope's chats by kind", %{scope: scope} do
      roleplay = owned_chat!(scope, scope, "Tavern")
      {:ok, older} = Chats.create_assistant_chat(scope)
      {:ok, newer} = Chats.create_assistant_chat(scope)

      assert Enum.map(Chats.list_chats(scope, :roleplay), & &1.id) == [roleplay.id]
      assert Enum.map(Chats.list_chats(scope, :assistant), & &1.id) == [newer.id, older.id]
      assert Chats.chat_options(scope) == [{"Tavern", roleplay.id}]
    end

    test "an assistant chat's model must be a chat-mode model, and blank clears it", %{scope: scope} do
      {:ok, text} = Mythweaver.AI.create_model(scope, %{name: "Text", api_model_id: "t", completion_mode: :text})
      {:ok, chat_model} = Mythweaver.AI.create_model(scope, %{name: "Chat", api_model_id: "c"})

      assert {:error, cs} = Chats.create_assistant_chat(scope, %{ai_model_id: text.id})
      assert "is not available" in errors_on(cs).ai_model_id

      {:ok, chat} = Chats.create_assistant_chat(scope, %{ai_model_id: chat_model.id})
      assert chat.ai_model_id == chat_model.id

      assert {:error, cs} = Mythweaver.Assistant.update_chat(scope, chat, %{ai_model_id: text.id})
      assert "is not available" in errors_on(cs).ai_model_id

      assert {:ok, %Chat{ai_model_id: nil, kind: :assistant}} =
               Mythweaver.Assistant.update_chat(scope, chat, %{"ai_model_id" => ""})
    end
  end

  describe "add_participant/2" do
    setup %{scope: scope} do
      c1 = character(scope, "Aqua")
      c2 = character(scope, "Kazuma")

      {:ok, chat} =
        Chats.create_chat(scope, %{participants: [%{character_id: c1.id}, %{character_id: c2.id}]})

      %{chat: chat, c1: c1, c2: c2}
    end

    test "adds a third participant", %{chat: chat, scope: scope} do
      c3 = character(scope, "Megumin")
      assert {:ok, _} = Chats.add_participant(chat, %{character_id: c3.id})
      assert length(Chats.get_chat!(chat.id).participants) == 3
    end

    test "rejects a character already present", %{chat: chat, c1: c1} do
      assert {:error, changeset} = Chats.add_participant(chat, %{character_id: c1.id})
      refute changeset.valid?
    end
  end

  describe "remove_participant/1" do
    test "removes a participant when above the minimum", %{scope: scope} do
      c1 = character(scope, "Aqua")
      c2 = character(scope, "Kazuma")
      c3 = character(scope, "Megumin")

      {:ok, chat} =
        Chats.create_chat(scope, %{
          participants: [
            %{character_id: c1.id},
            %{character_id: c2.id},
            %{character_id: c3.id}
          ]
        })

      [p | _] = chat.participants
      assert {:ok, _} = Chats.remove_participant(scope, p)
      assert length(Chats.get_chat!(chat.id).participants) == 2
    end

    test "refuses to drop below two participants", %{scope: scope} do
      c1 = character(scope, "Aqua")
      c2 = character(scope, "Kazuma")

      {:ok, chat} =
        Chats.create_chat(scope, %{participants: [%{character_id: c1.id}, %{character_id: c2.id}]})

      [p | _] = chat.participants
      assert {:error, :minimum_participants} = Chats.remove_participant(scope, p)
    end

    test "clears player_character_id when removing the player participant", %{scope: scope} do
      c1 = character(scope, "Aqua")
      c2 = character(scope, "Kazuma")
      c3 = character(scope, "Megumin")

      {:ok, chat} =
        Chats.create_chat(scope, %{
          player_character_id: c1.id,
          participants: [
            %{character_id: c1.id},
            %{character_id: c2.id},
            %{character_id: c3.id}
          ]
        })

      player_p = Enum.find(chat.participants, &(&1.character_id == c1.id))
      assert {:ok, _} = Chats.remove_participant(scope, player_p)
      assert Chats.get_chat!(chat.id).player_character_id == nil
    end
  end

  describe "update_chat/2" do
    setup %{scope: scope} do
      c1 = character(scope, "Aqua")
      c2 = character(scope, "Kazuma")

      {:ok, chat} =
        Chats.create_chat(scope, %{
          name: "Tavern",
          participants: [%{character_id: c1.id}, %{character_id: c2.id}]
        })

      %{chat: chat, c1: c1, c2: c2}
    end

    test "changes the name", %{chat: chat, scope: scope} do
      assert {:ok, %Chat{} = updated} = Chats.update_chat(scope, chat, %{name: "Guild"})
      assert updated.name == "Guild"
    end

    test "rejects player_character_id that is not a participant", %{chat: chat, scope: scope} do
      outsider = character(scope, "Darkness")

      assert {:error, changeset} =
               Chats.update_chat(scope, chat, %{player_character_id: outsider.id})

      assert %{player_character_id: ["must be a participant of the chat"]} =
               errors_on(changeset)
    end

    test "unmutes a muted participant made the player, leaving the others", %{chat: chat, scope: scope, c1: c1, c2: c2} do
      chat = Chats.get_chat!(chat.id)
      for p <- chat.participants, do: {:ok, _} = Chats.update_participant(scope, p, %{muted: true})

      assert {:ok, _} = Chats.update_chat(scope, chat, %{player_character_id: c1.id})

      reloaded = Chats.get_chat!(chat.id)
      assert reloaded.player_character_id == c1.id
      assert Map.new(reloaded.participants, &{&1.character_id, &1.muted}) == %{c1.id => false, c2.id => true}
    end
  end

  describe "get_chat!/1 and get_chat/1" do
    test "get_chat!/1 preloads participants and player_character", %{scope: scope} do
      c1 = character(scope, "Aqua")
      c2 = character(scope, "Kazuma")

      {:ok, chat} =
        Chats.create_chat(scope, %{
          player_character_id: c1.id,
          participants: [%{character_id: c1.id}, %{character_id: c2.id}]
        })

      loaded = Chats.get_chat!(chat.id)
      assert loaded.player_character.id == c1.id
      assert Enum.all?(loaded.participants, &(&1.character.__struct__ == Characters.Character))
    end

    test "get_chat/1 returns nil for an unknown id" do
      assert Chats.get_chat(Schema.generate_id()) == nil
    end
  end

  describe "delete_chat/1" do
    test "deletes the chat and cascades participants", %{scope: scope} do
      c1 = character(scope, "Aqua")
      c2 = character(scope, "Kazuma")

      {:ok, chat} =
        Chats.create_chat(scope, %{participants: [%{character_id: c1.id}, %{character_id: c2.id}]})

      assert {:ok, %Chat{}} = Chats.delete_chat(scope, chat)
      assert Chats.get_chat(chat.id) == nil
    end
  end

  test "deleting a character that is a participant is refused", %{scope: scope} do
    c1 = character(scope, "Aqua")
    c2 = character(scope, "Kazuma")

    {:ok, _chat} =
      Chats.create_chat(scope, %{participants: [%{character_id: c1.id}, %{character_id: c2.id}]})

    assert {:error, :in_use} = Characters.delete_character(scope, c1)
  end

  describe "speaking order" do
    setup %{scope: scope} do
      [a, b, c] = Enum.map(~w[Aqua Kazuma Megumin], &character(scope, &1))

      {:ok, chat} =
        Chats.create_chat(scope, %{participants: Enum.map([a, b, c], &%{character_id: &1.id})})

      %{chat: Chats.get_chat!(chat.id), characters: [a, b, c]}
    end

    test "create_chat/1 numbers participants in submitted order", %{chat: chat, characters: chars} do
      assert Enum.map(chat.participants, & &1.position) == [0, 1, 2]
      assert Enum.map(chat.participants, & &1.character_id) == Enum.map(chars, & &1.id)
    end

    test "add_participant/2 appends after the current maximum", %{chat: chat, scope: scope} do
      d = character(scope, "Darkness")
      assert {:ok, p} = Chats.add_participant(chat, %{"character_id" => d.id})
      assert p.position == 3
      assert List.last(Chats.get_chat!(chat.id).participants).character_id == d.id
    end

    test "reorder_participants/2 persists a permutation", %{chat: chat, scope: scope} do
      [pa, pb, pc] = Enum.map(chat.participants, & &1.id)
      assert {:ok, reordered} = Chats.reorder_participants(scope, chat, [pc, pa, pb])
      assert Enum.map(reordered.participants, & &1.id) == [pc, pa, pb]
      assert Enum.map(Chats.get_chat!(chat.id).participants, & &1.id) == [pc, pa, pb]
    end

    test "reorder_participants/2 refuses a non-permutation", %{chat: chat, scope: scope} do
      [pa, pb, pc] = ids = Enum.map(chat.participants, & &1.id)
      assert {:error, :not_a_permutation} = Chats.reorder_participants(scope, chat, [pa, pb])
      assert {:error, :not_a_permutation} = Chats.reorder_participants(scope, chat, [pa, pa, pc])
      assert Enum.map(Chats.get_chat!(chat.id).participants, & &1.id) == ids
    end
  end

  describe "set_participants_muted/4" do
    test "mutes only the given participants, never the player, then unmutes them", %{scope: scope} do
      [a, b, c] = Enum.map(~w[Aqua Kazuma Megumin], &character(scope, &1))

      {:ok, chat} =
        Chats.create_chat(scope, %{
          player_character_id: a.id,
          participants: Enum.map([a, b, c], &%{character_id: &1.id})
        })

      chat = Chats.get_chat!(chat.id)
      [pa, pb, pc] = Enum.map([a, b, c], fn ch -> Enum.find(chat.participants, &(&1.character_id == ch.id)) end)

      assert {:ok, muted} = Chats.set_participants_muted(scope, chat, [pa.id, pb.id], true)
      assert Map.new(muted.participants, &{&1.character_id, &1.muted}) == %{a.id => false, b.id => true, c.id => false}

      assert {:ok, unmuted} = Chats.set_participants_muted(scope, muted, [pb.id, pc.id], false)
      assert Enum.all?(unmuted.participants, &(not &1.muted))
    end
  end

  describe "update_settings/2 turn fields" do
    setup %{scope: scope} do
      [a, b] = Enum.map(~w[Aqua Kazuma], &character(scope, &1))

      {:ok, chat} =
        Chats.create_chat(scope, %{participants: Enum.map([a, b], &%{character_id: &1.id})})

      %{chat: Chats.get_chat!(chat.id)}
    end

    test "rejects a zero max_turns", %{chat: chat, scope: scope} do
      assert {:error, cs} =
               Chats.update_settings(scope, chat, %{"reply_strategy" => "list", "max_turns" => "0"})

      assert errors_on(cs).max_turns != []
    end

    test "persists reply strategy and max turns", %{chat: chat, scope: scope} do
      assert {:ok, updated} =
               Chats.update_settings(scope, chat, %{"reply_strategy" => "list", "max_turns" => "2"})

      assert updated.reply_strategy == :list
      assert updated.max_turns == 2
    end
  end

  describe "broadcasts" do
    test "create, update and delete are announced on the owner's topic; failures are not", %{scope: scope} do
      :ok = Chats.subscribe(scope)
      c1 = character(scope, "Aqua")
      c2 = character(scope, "Kazuma")

      {:ok, chat} =
        Chats.create_chat(scope, %{participants: [%{character_id: c1.id}, %{character_id: c2.id}]})

      id = chat.id
      assert_receive {:chat_created, ^id}

      {:ok, chat} = Chats.update_chat(scope, chat, %{name: "Guild"})
      assert_receive {:chat_updated, ^id}

      outsider = character(scope, "Darkness")
      {:error, _} = Chats.update_chat(scope, chat, %{player_character_id: outsider.id})
      refute_receive {:chat_updated, _}, 50

      {:ok, _} = Chats.delete_chat(scope, chat)
      assert_receive {:chat_deleted, ^id}
    end

    test "another user hears nothing of this user's chats", %{scope: scope} do
      :ok = Chats.subscribe(scope!())
      c1 = character(scope, "Aqua")
      c2 = character(scope, "Kazuma")

      {:ok, chat} =
        Chats.create_chat(scope, %{participants: [%{character_id: c1.id}, %{character_id: c2.id}]})

      [p | _] = chat.participants
      {:ok, _} = Chats.update_participant(scope, p, %{muted: true})
      {:ok, _} = Chats.delete_chat(scope, chat)
      refute_receive {_event, _chat_id}
    end
  end

  describe "participant ownership" do
    test "a chat accepts only characters its owner may use", %{scope: admin} do
      user = scope!(%{role: :user})
      other = scope!(%{role: :user})
      site = character(admin, "Site", site: true)
      mine = character(user, "Mine")
      theirs = character(other, "Theirs")

      assert {:error, cs} =
               Chats.create_chat(user, %{participants: [%{character_id: mine.id}, %{character_id: theirs.id}]})

      assert [_, %{errors: [character_id: {"is not available", _}]}] = cs.changes.participants

      assert {:ok, chat} =
               Chats.create_chat(user, %{
                 participants: [%{character_id: mine.id}, %{character_id: site.id}],
                 player_character_id: mine.id
               })

      assert {:error, %{errors: [character_id: _]}} = Chats.add_participant(chat, %{"character_id" => theirs.id})
      assert {:error, _} = Chats.add_participants(user, chat, [theirs.id])

      chat = Chats.get_chat!(chat.id)
      attrs = %{"participant_ids" => [mine.id, site.id, theirs.id], "player_character_id" => mine.id}
      assert {:error, %Ecto.Changeset{} = cs} = Chats.update_settings(user, chat, attrs)
      assert cs.errors[:participant_ids]

      # A site chat (unowned) takes no user's character.
      assert {:error, _} = Chats.create_chat(nil, %{participants: [%{character_id: site.id}, %{character_id: mine.id}]})
    end

    test "a chat and its participants accept only models the chat's owner may use", %{scope: admin} do
      user = scope!(%{role: :user})
      other = scope!(%{role: :user})
      {:ok, theirs} = Mythweaver.AI.create_model(other, %{name: "Theirs", api_model_id: "x"})
      {:ok, mine} = Mythweaver.AI.create_model(user, %{name: "Mine", api_model_id: "x"})

      {:ok, site} =
        Mythweaver.AI.create_model(admin, %{name: "Site#{System.unique_integer()}", api_model_id: "x"}, site: true)

      [a, b] = [character(user, "A"), character(user, "B")]
      participants = [%{character_id: a.id}, %{character_id: b.id}]

      assert {:error, cs} = Chats.create_chat(user, %{participants: participants, ai_model_id: theirs.id})
      assert "is not available" in errors_on(cs).ai_model_id

      assert {:error, cs} =
               Chats.create_chat(user, %{
                 participants: [%{character_id: a.id, ai_model_id: theirs.id}, %{character_id: b.id}]
               })

      assert [%{errors: [ai_model_id: {"is not available", _}]}, _] = cs.changes.participants
      assert Chats.list_chats(user) == []

      {:ok, chat} = Chats.create_chat(user, %{participants: participants, ai_model_id: mine.id})
      chat = Chats.get_chat!(chat.id)

      assert {:error, cs} = Chats.update_settings(user, chat, %{"ai_model_id" => theirs.id})
      assert cs.errors[:ai_model_id]
      assert {:error, cs} = Chats.update_chat(user, chat, %{ai_model_id: theirs.id})
      assert "is not available" in errors_on(cs).ai_model_id
      assert Repo.reload!(chat).ai_model_id == mine.id

      [p | _] = chat.participants
      assert {:error, cs} = Chats.update_participant(user, p, %{ai_model_id: theirs.id})
      assert "is not available" in errors_on(cs).ai_model_id
      assert Repo.reload!(p).ai_model_id == nil
      assert {:ok, %{ai_model_id: id}} = Chats.update_participant(user, p, %{ai_model_id: site.id})
      assert id == site.id
    end

    test "a chat and its participants refuse an embedding model" do
      user = scope!(%{role: :user})

      {:ok, embedder} =
        Mythweaver.AI.create_model(user, %{name: "Embed", api_model_id: "e", completion_mode: :embedding})

      {:ok, mine} = Mythweaver.AI.create_model(user, %{name: "Mine", api_model_id: "x"})
      [a, b] = [character(user, "A"), character(user, "B")]
      participants = [%{character_id: a.id}, %{character_id: b.id}]

      assert {:error, cs} = Chats.create_chat(user, %{participants: participants, ai_model_id: embedder.id})
      assert "is not available" in errors_on(cs).ai_model_id

      assert {:error, cs} =
               Chats.create_chat(user, %{
                 participants: [%{character_id: a.id, ai_model_id: embedder.id}, %{character_id: b.id}]
               })

      assert [%{errors: [ai_model_id: {"is not available", _}]}, _] = cs.changes.participants

      {:ok, chat} = Chats.create_chat(user, %{participants: participants, ai_model_id: mine.id})
      chat = Chats.get_chat!(chat.id)
      assert {:error, cs} = Chats.update_chat(user, chat, %{ai_model_id: embedder.id})
      assert "is not available" in errors_on(cs).ai_model_id

      [p | _] = chat.participants
      assert {:error, cs} = Chats.update_participant(user, p, %{ai_model_id: embedder.id})
      assert "is not available" in errors_on(cs).ai_model_id
    end
  end
end
