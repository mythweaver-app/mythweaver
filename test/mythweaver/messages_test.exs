defmodule Mythweaver.MessagesTest do
  use Mythweaver.DataCase

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Attachments.BodyAttachment
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message
  alias Mythweaver.Messages.MessageBody
  alias Mythweaver.Moderation.Report
  alias Mythweaver.Moderation.Rules
  alias Mythweaver.Schema

  defp character(scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: name})
    character
  end

  defp setup_chat do
    scope = scope!()
    c1 = character(scope, "Alice")
    c2 = character(scope, "Bob")

    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: "Test Chat",
        participants: [%{character_id: c1.id}, %{character_id: c2.id}]
      })

    %{scope: scope, chat: chat, c1: c1, c2: c2}
  end

  describe "create_message/2" do
    setup do
      setup_chat()
    end

    test "with a character author and one body succeeds", %{chat: chat, c1: c1} do
      assert {:ok, %Message{} = message} =
               Messages.create_message(chat, %{
                 author_is_character: true,
                 author_character_id: c1.id,
                 bodies: [%{content: "Hello there"}]
               })

      assert message.author_is_character == true
      assert message.author_character_id == c1.id
      assert message.position == 0
      assert length(message.bodies) == 1
      assert [%MessageBody{active: true}] = message.bodies
    end

    test "with a string author succeeds", %{chat: chat} do
      assert {:ok, %Message{} = message} =
               Messages.create_message(chat, %{
                 author_is_character: false,
                 author_name: "Narrator",
                 bodies: [%{content: "A dark night."}]
               })

      assert message.author_character_id == nil
      assert message.author_name == "Narrator"
    end

    test "character author without a character id fails", %{chat: chat} do
      assert {:error, changeset} =
               Messages.create_message(chat, %{
                 author_is_character: true,
                 bodies: [%{content: "hi"}]
               })

      assert %{author_character_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "string author with a character id fails", %{chat: chat, c1: c1} do
      assert {:error, changeset} =
               Messages.create_message(chat, %{
                 author_is_character: false,
                 author_name: "Narrator",
                 author_character_id: c1.id,
                 bodies: [%{content: "hi"}]
               })

      assert %{author_character_id: ["must be blank for a string author"]} = errors_on(changeset)
    end

    test "without bodies fails", %{chat: chat, c1: c1} do
      assert {:error, changeset} =
               Messages.create_message(chat, %{
                 author_is_character: true,
                 author_character_id: c1.id
               })

      assert errors_on(changeset)[:bodies]
    end

    test "assigns sequential positions per chat", %{chat: chat, c1: c1} do
      assert {:ok, %Message{position: 0}} =
               Messages.create_message(chat, %{
                 author_is_character: true,
                 author_character_id: c1.id,
                 bodies: [%{content: "first"}]
               })

      assert {:ok, %Message{position: 1}} =
               Messages.create_message(chat, %{
                 author_is_character: true,
                 author_character_id: c1.id,
                 bodies: [%{content: "second"}]
               })
    end

    test "concurrent inserts take distinct positions", %{chat: chat, c1: c1} do
      results =
        1..2
        |> Enum.map(fn n ->
          Task.async(fn ->
            Messages.create_message(chat, %{
              author_is_character: true,
              author_character_id: c1.id,
              bodies: [%{content: "racer #{n}"}]
            })
          end)
        end)
        |> Task.await_many()

      assert [{:ok, first}, {:ok, second}] = results
      assert first.position != second.position
    end
  end

  describe "bodies and swipes" do
    setup do
      %{chat: chat, c1: c1} = ctx = setup_chat()

      {:ok, message} =
        Messages.create_message(chat, %{
          author_is_character: true,
          author_character_id: c1.id,
          bodies: [%{content: "original"}]
        })

      Map.put(ctx, :message, message)
    end

    test "add_body/2 adds an active body and deactivates the prior one", %{scope: scope, message: message} do
      assert {:ok, %MessageBody{active: true} = body} =
               Messages.add_body(message, %{content: "regenerated"})

      reloaded = Messages.get_message!(scope, message.id)
      assert length(reloaded.bodies) == 2
      active = Enum.filter(reloaded.bodies, & &1.active)
      assert [%MessageBody{id: active_id}] = active
      assert active_id == body.id
    end

    test "add_body/2 with blank content rolls back and keeps prior active", %{scope: scope, message: message} do
      [original] = message.bodies

      assert {:error, changeset} = Messages.add_body(message, %{content: ""})
      assert errors_on(changeset)[:content]

      reloaded = Messages.get_message!(scope, message.id)
      assert length(reloaded.bodies) == 1
      assert [%MessageBody{id: id, active: true}] = reloaded.bodies
      assert id == original.id
    end

    test "set_active_body/1 flips which body is active", %{scope: scope, message: message} do
      {:ok, _new_body} = Messages.add_body(message, %{content: "regenerated"})

      reloaded = Messages.get_message!(scope, message.id)
      inactive = Enum.find(reloaded.bodies, &(not &1.active))

      assert {:ok, _} = Messages.set_active_body(scope, inactive)

      after_swap = Messages.get_message!(scope, message.id)
      active = Enum.filter(after_swap.bodies, & &1.active)
      assert [%MessageBody{id: active_id}] = active
      assert active_id == inactive.id
    end
  end

  describe "streamed generation bodies" do
    setup do
      setup_chat()
    end

    test "create_generating_message/2 yields a visible blank generating body", %{chat: chat, c1: c1} do
      assert {:ok, %Message{} = message} = Messages.create_generating_message(chat, c1.id)

      assert [%MessageBody{content: "", active: true, generating: true}] = message.bodies
      assert [%Message{id: listed_id}] = Messages.list_messages(chat)
      assert listed_id == message.id
    end

    test "save_streamed_body/3 writes content and reasoning", %{scope: scope, chat: chat, c1: c1} do
      {:ok, message} = Messages.create_generating_message(chat, c1.id)
      [body] = message.bodies

      assert :ok = Messages.save_streamed_body(body, "Hello", "Hm")

      assert [%MessageBody{content: "Hello", reasoning: "Hm", generating: true}] =
               Messages.get_message!(scope, message.id).bodies
    end

    test "an error-only finalize keeps streamed content and reasoning", %{scope: scope, chat: chat, c1: c1} do
      {:ok, message} = Messages.create_generating_message(chat, c1.id)
      [body] = message.bodies

      Messages.save_streamed_body(body, "Hi", "Hm")
      {:ok, _} = Messages.finalize_body(body, %{error: "Stopped."})

      assert [
               %MessageBody{
                 content: "Hi",
                 reasoning: "Hm",
                 generating: false,
                 error: "Stopped."
               }
             ] = Messages.get_message!(scope, message.id).bodies
    end

    test "finalize_body/2 records provenance and clears generating", %{chat: chat, c1: c1} do
      {:ok, message} = Messages.create_generating_message(chat, c1.id)
      [body] = message.bodies

      assert {:ok, %MessageBody{} = finalized} =
               Messages.finalize_body(body, %{
                 content: "Hello",
                 finish_reason: "stop",
                 total_tokens: 49
               })

      assert finalized.generating == false
      assert finalized.finish_reason == "stop"
      assert finalized.total_tokens == 49
      assert finalized.content == "Hello"
    end

    test "add_generating_body/1 becomes the active swipe", %{scope: scope, chat: chat, c1: c1} do
      {:ok, message} =
        Messages.create_message(chat, %{
          author_is_character: true,
          author_character_id: c1.id,
          bodies: [%{content: "first take"}]
        })

      [original] = message.bodies

      assert {:ok, %MessageBody{active: true, generating: true} = body} =
               Messages.add_generating_body(message)

      reloaded = Messages.get_message!(scope, message.id)
      assert length(reloaded.bodies) == 2
      assert [%MessageBody{id: active_id}] = Enum.filter(reloaded.bodies, & &1.active)
      assert active_id == body.id
      assert Enum.find(reloaded.bodies, &(&1.id == original.id)).active == false
    end

    test "add_continuing_body/2 is an active generating swipe seeded from the source", %{
      scope: scope,
      chat: chat,
      c1: c1
    } do
      {:ok, message} =
        Messages.create_message(chat, %{
          author_is_character: true,
          author_character_id: c1.id,
          bodies: [%{content: "first take"}]
        })

      [original] = message.bodies
      {:ok, original} = Messages.finalize_body(original, %{reasoning: "Hm"})

      assert {:ok, %MessageBody{} = body} = Messages.add_continuing_body(message, original)
      assert %{active: true, generating: true, content: "first take", reasoning: "Hm"} = body

      reloaded = Messages.get_message!(scope, message.id)
      assert length(reloaded.bodies) == 2
      assert Enum.find(reloaded.bodies, &(&1.id == original.id)).active == false
    end

    test "last_message?/1 is true only for the newest message", %{scope: scope, chat: chat, c1: c1} do
      {:ok, first} = Messages.send_message(scope, chat, c1.id, "one")
      {:ok, second} = Messages.send_message(scope, chat, c1.id, "two")

      assert Messages.last_message?(scope, second)
      refute Messages.last_message?(scope, first)
    end

    test "broadcast_body_delta/5 and broadcast_generation_finished/2 reach the caller", %{
      chat: chat,
      c1: c1
    } do
      :ok = Messages.subscribe(chat)
      {:ok, message} = Messages.create_generating_message(chat, c1.id)
      [body] = message.bodies

      assert_receive {:message_created, %Message{}}

      Messages.broadcast_body_delta(chat.id, message.id, body.id, "Hel", "Hm")

      assert_receive {:body_delta, %{message_id: id, body_id: body_id, content: "Hel", reasoning: "Hm"}}
      assert id == message.id
      assert body_id == body.id

      Messages.broadcast_generation_finished(chat.id, message.id)
      assert_receive {:generation_finished, ^id}
    end

    test "finalize_interrupted_bodies/0 drops stranded bodies with no text and marks the rest interrupted", %{
      scope: scope,
      chat: chat,
      c1: c1
    } do
      {:ok, blank} = Messages.create_generating_message(chat, c1.id)
      {:ok, partial} = Messages.create_generating_message(chat, c1.id)
      :ok = Messages.save_streamed_body(hd(partial.bodies), "Half a repl", nil)

      {:ok, swiped} = Messages.send_message(scope, chat, c1.id, "first take")
      {:ok, _body} = Messages.add_generating_body(swiped)

      assert :ok = Messages.finalize_interrupted_bodies()

      assert Messages.get_message(scope, blank.id) == nil

      assert [%MessageBody{generating: false, error: "Interrupted.", content: "Half a repl"}] =
               Messages.get_message!(scope, partial.id).bodies

      assert [%MessageBody{content: "first take", active: true}] = Messages.get_message!(scope, swiped.id).bodies
    end
  end

  describe "swipe origin" do
    setup do
      %{chat: chat, c1: c1} = ctx = setup_chat()

      {:ok, message} =
        Messages.create_message(chat, %{
          author_is_character: true,
          author_character_id: c1.id,
          bodies: [%{content: "first take"}]
        })

      Map.put(ctx, :message, message)
    end

    test "a created message's body is an unsourced original", %{message: message} do
      assert [%MessageBody{origin: :original, source_body_id: nil}] = message.bodies
    end

    test "an edit is sourced from the previously active swipe", %{scope: scope, message: message} do
      [original] = message.bodies

      {:ok, edited} = Messages.add_edited_body(scope, message, %{"content" => "second take"})

      assert %{origin: :edit, source_body_id: source_id} = Enum.find(edited.bodies, & &1.active)
      assert source_id == original.id
    end

    test "an edit after swiping back is sourced from the swiped-to body, not the latest", %{
      scope: scope,
      message: message
    } do
      [first] = message.bodies
      {:ok, edited} = Messages.add_edited_body(scope, message, %{"content" => "second take"})
      # Reloaded so `first` reads `active: false`; a stale `active: true` struct makes no change.
      {:ok, _} = Messages.set_active_body(scope, Enum.find(edited.bodies, &(&1.id == first.id)))

      {:ok, edited} =
        Messages.add_edited_body(scope, Messages.get_message!(scope, message.id), %{"content" => "third take"})

      assert Enum.find(edited.bodies, & &1.active).source_body_id == first.id
    end

    test "a regeneration has no source", %{message: message} do
      assert {:ok, %MessageBody{origin: :regenerate, source_body_id: nil}} = Messages.add_generating_body(message)
    end

    test "a continue is sourced from the swipe it continues", %{message: message} do
      [source] = message.bodies

      assert {:ok, %MessageBody{origin: :continue, source_body_id: source_id}} =
               Messages.add_continuing_body(message, source)

      assert source_id == source.id
    end
  end

  describe "update_message/2" do
    setup do
      %{chat: chat, c1: c1} = ctx = setup_chat()

      {:ok, message} =
        Messages.create_message(chat, %{
          author_is_character: true,
          author_character_id: c1.id,
          bodies: [%{content: "original"}]
        })

      Map.put(ctx, :message, message)
    end

    test "toggles visible_to_ai", %{message: message} do
      assert {:ok, %Message{visible_to_ai: false}} =
               Messages.update_message(message, %{visible_to_ai: false})
    end

    test "set_visible_to_ai/2 persists the flag and broadcasts :message_updated", %{scope: scope, message: message} do
      %{id: id, chat_id: chat_id} = message
      Messages.subscribe(%Chat{id: chat_id})

      assert {:ok, %Message{visible_to_ai: false} = hidden} = Messages.set_visible_to_ai(scope, message, false)
      assert_receive {:message_updated, %Message{id: ^id, visible_to_ai: false}}

      assert {:ok, %Message{visible_to_ai: true}} = Messages.set_visible_to_ai(scope, hidden, true)
      assert Messages.get_message!(scope, id).visible_to_ai
    end

    test "rejects an inconsistent author", %{message: message} do
      assert {:error, changeset} =
               Messages.update_message(message, %{author_is_character: false})

      assert %{author_character_id: ["must be blank for a string author"]} = errors_on(changeset)
    end
  end

  describe "list_messages/1, get_message/1, delete_message/1" do
    setup do
      setup_chat()
    end

    test "list_messages/1 orders by position with preloads", %{chat: chat, c1: c1} do
      {:ok, _m0} =
        Messages.create_message(chat, %{
          author_is_character: true,
          author_character_id: c1.id,
          bodies: [%{content: "first"}]
        })

      {:ok, _m1} =
        Messages.create_message(chat, %{
          author_is_character: true,
          author_character_id: c1.id,
          bodies: [%{content: "second"}]
        })

      messages = Messages.list_messages(chat)
      assert Enum.map(messages, & &1.position) == [0, 1]
      assert Enum.all?(messages, &Ecto.assoc_loaded?(&1.bodies))
      assert Enum.all?(messages, &Ecto.assoc_loaded?(&1.author_character))
    end

    test "list_messages/1 orders bodies by insertion", %{chat: chat, c1: c1} do
      {:ok, message} =
        Messages.create_message(chat, %{
          author_is_character: true,
          author_character_id: c1.id,
          bodies: [%{content: "first"}]
        })

      {:ok, _} = Messages.add_body(message, %{content: "second"})

      [msg] = Messages.list_messages(chat)
      assert Enum.map(msg.bodies, & &1.content) == ["first", "second"]
    end

    test "get_message/1 returns nil for a missing id", %{scope: scope} do
      assert Messages.get_message(scope, Schema.generate_id()) == nil
    end

    test "get_messages/2 returns the scope's messages by position, skipping others", %{scope: scope, chat: chat} do
      other = scope!()
      [eve, finn] = [character(other, "Eve"), character(other, "Finn")]

      {:ok, their_chat} =
        Chats.create_chat(other, %{name: "Theirs", participants: [%{character_id: eve.id}, %{character_id: finn.id}]})

      [first, second, theirs] =
        for {target, content} <- [{chat, "one"}, {chat, "two"}, {their_chat, "theirs"}] do
          {:ok, message} =
            Messages.create_message(target, %{
              author_is_character: false,
              author_name: "N",
              bodies: [%{content: content}]
            })

          message
        end

      found = Messages.get_messages(scope, [second.id, theirs.id, Schema.generate_id(), "not-a-uuid", first.id])

      assert Enum.map(found, & &1.id) == [first.id, second.id]
      assert Enum.all?(found, &Ecto.assoc_loaded?(&1.bodies))
      assert Messages.get_messages(scope, []) == []
    end

    test "delete_message/1 removes the message and its bodies", %{scope: scope, chat: chat, c1: c1} do
      {:ok, message} =
        Messages.create_message(chat, %{
          author_is_character: true,
          author_character_id: c1.id,
          bodies: [%{content: "doomed"}]
        })

      assert {:ok, _} = Messages.delete_message(scope, message)
      assert Messages.get_message(scope, message.id) == nil

      assert Repo.aggregate(
               from(b in MessageBody, where: b.message_id == ^message.id),
               :count
             ) == 0
    end

    test "delete_message/1 broadcasts :message_deleted", %{scope: scope, chat: chat, c1: c1} do
      {:ok, %{id: id} = message} =
        Messages.create_message(chat, %{
          author_is_character: true,
          author_character_id: c1.id,
          bodies: [%{content: "doomed"}]
        })

      Messages.subscribe(chat)
      assert {:ok, _} = Messages.delete_message(scope, message)
      assert_receive {:message_deleted, %{id: ^id}}
    end

    test "add_edited_body/2 appends a new active swipe and keeps the old ones", %{scope: scope, chat: chat, c1: c1} do
      {:ok, %{id: id} = message} =
        Messages.create_message(chat, %{
          author_is_character: true,
          author_character_id: c1.id,
          bodies: [%{content: "one"}]
        })

      {:ok, _} = Messages.add_body(message, %{content: "two"})
      Messages.subscribe(chat)

      assert {:ok, %Message{} = updated} = Messages.add_edited_body(scope, message, %{"content" => "edited"})
      assert Enum.map(updated.bodies, & &1.content) == ["one", "two", "edited"]
      assert Enum.map(updated.bodies, & &1.active) == [false, false, true]
      assert_receive {:message_updated, %{id: ^id}}
    end

    test "add_edited_body/2 rejects blank content and adds no swipe", %{scope: scope, chat: chat, c1: c1} do
      {:ok, message} =
        Messages.create_message(chat, %{
          author_is_character: true,
          author_character_id: c1.id,
          bodies: [%{content: "one"}]
        })

      assert {:error, changeset} = Messages.add_edited_body(scope, message, %{"content" => ""})
      assert errors_on(changeset).content == ["can't be blank"]

      assert [%{content: "one", active: true}] = Messages.get_message!(scope, message.id).bodies
    end

    test "update_edited_body/4 saves into the given swipe and keeps the others", %{scope: scope, chat: chat, c1: c1} do
      {:ok, %{id: id} = message} =
        Messages.create_message(chat, %{
          author_is_character: true,
          author_character_id: c1.id,
          bodies: [%{content: "one"}]
        })

      {:ok, two} = Messages.add_body(message, %{content: "two"})
      message = Messages.get_message!(scope, id)
      Messages.subscribe(chat)

      assert {:ok, %Message{} = updated} = Messages.update_edited_body(scope, message, two.id, %{"content" => "two!"})
      assert Enum.map(updated.bodies, & &1.content) == ["one", "two!"]
      assert Message.active_body(updated).id == two.id
      assert_receive {:message_updated, %{id: ^id}}
    end

    test "update_edited_body/4 saves into the edited swipe, not the active one", %{scope: scope, chat: chat, c1: c1} do
      {:ok, %{id: id, bodies: [one]} = message} =
        Messages.create_message(chat, %{
          author_is_character: true,
          author_character_id: c1.id,
          bodies: [%{content: "one"}]
        })

      {:ok, two} = Messages.add_body(message, %{content: "two"})
      message = Messages.get_message!(scope, id)
      assert Message.active_body(message).id == two.id

      assert {:ok, updated} = Messages.update_edited_body(scope, message, one.id, %{"content" => "one!"})
      assert Enum.map(updated.bodies, &{&1.id, &1.content}) == [{one.id, "one!"}, {two.id, "two"}]
      assert Message.active_body(updated).id == two.id
    end

    test "update_edited_body/4 is not_found for a body the message lacks", %{scope: scope, chat: chat, c1: c1} do
      {:ok, message} =
        Messages.create_message(chat, %{
          author_is_character: true,
          author_character_id: c1.id,
          bodies: [%{content: "one"}]
        })

      assert {:error, :not_found} =
               Messages.update_edited_body(scope, message, Ecto.UUID.generate(), %{"content" => "x"})
    end

    test "update_edited_body/4 rejects blank content and leaves the swipe", %{scope: scope, chat: chat, c1: c1} do
      {:ok, %{bodies: [one]} = message} =
        Messages.create_message(chat, %{
          author_is_character: true,
          author_character_id: c1.id,
          bodies: [%{content: "one"}]
        })

      assert {:error, changeset} = Messages.update_edited_body(scope, message, one.id, %{"content" => ""})
      assert errors_on(changeset).content == ["can't be blank"]

      assert [%{content: "one", active: true}] = Messages.get_message!(scope, message.id).bodies
    end

    test "update_edited_body/4 refuses while a swipe is generating", %{scope: scope, chat: chat, c1: c1} do
      {:ok, message} = Messages.create_generating_message(chat, c1.id)
      message = Messages.get_message!(scope, message.id)

      assert {:error, :generating} =
               Messages.update_edited_body(scope, message, Message.active_body(message).id, %{"content" => "typed"})
    end
  end

  describe "character deletion" do
    test "reattributes authored messages to a verbatim string author" do
      %{scope: scope, chat: chat} = setup_chat()
      author = character(scope, "Aqua")

      {:ok, message} =
        Messages.create_message(chat, %{
          author_is_character: true,
          author_character_id: author.id,
          bodies: [%{content: "line"}]
        })

      assert {:ok, _} = Characters.delete_character(scope, author)

      reloaded = Messages.get_message!(scope, message.id)
      assert reloaded.author_is_character == false
      assert reloaded.author_name == "Aqua"
      assert reloaded.author_character_id == nil
      assert length(reloaded.bodies) == 1
    end
  end

  describe "author_is_player" do
    setup do
      %{scope: scope, chat: chat, c1: c1} = ctx = setup_chat()
      {:ok, chat} = Chats.update_chat(scope, Chats.get_chat!(chat.id), %{player_character_id: c1.id})
      %{ctx | chat: chat}
    end

    test "is stamped from the player at send time and survives a play-as switch", %{
      scope: scope,
      chat: chat,
      c1: c1,
      c2: c2
    } do
      {:ok, as_alice} = Messages.send_message(scope, chat, c1.id, "I am Alice")
      {:ok, from_bob} = Messages.send_message(scope, chat, c2.id, "I am Bob")
      assert as_alice.author_is_player
      refute from_bob.author_is_player

      {:ok, chat} = Chats.update_chat(scope, Chats.get_chat!(chat.id), %{player_character_id: c2.id})
      {:ok, as_bob} = Messages.send_message(scope, chat, c2.id, "Now I play Bob")
      {:ok, from_alice} = Messages.send_message(scope, chat, c1.id, "Alice, as a bot")

      assert as_bob.author_is_player
      refute from_alice.author_is_player
      assert Messages.get_message!(scope, as_alice.id).author_is_player
      refute Messages.get_message!(scope, from_bob.id).author_is_player
    end

    test "a generated message written as the player is the player's", %{chat: chat, c1: c1, c2: c2} do
      {:ok, as_player} = Messages.create_generating_message(chat, c1.id)
      {:ok, from_bot} = Messages.create_generating_message(chat, c2.id)

      assert as_player.author_is_player
      refute from_bot.author_is_player
    end

    test "a string author is never the player", %{chat: chat} do
      {:ok, message} =
        Messages.create_message(chat, %{
          author_is_character: false,
          author_name: "Narrator",
          bodies: [%{content: "Night."}]
        })

      refute message.author_is_player
    end

    test "a chat with no player brands nobody", %{scope: scope, c1: c1, c2: c2} do
      {:ok, chat} =
        Chats.create_chat(scope, %{name: "Spectated", participants: [%{character_id: c1.id}, %{character_id: c2.id}]})

      {:ok, message} = Messages.send_message(scope, chat, c1.id, "Hello")
      refute message.author_is_player
    end
  end

  describe "reattribute_message/3" do
    setup do
      %{scope: scope, chat: chat, c1: c1} = ctx = setup_chat()
      {:ok, _} = Chats.update_chat(scope, Chats.get_chat!(chat.id), %{player_character_id: c1.id})
      %{ctx | chat: Chats.get_chat!(chat.id)}
    end

    test "moves a player message to a name without adding a swipe or dropping its You badge", %{
      scope: scope,
      chat: chat,
      c1: c1
    } do
      {:ok, message} = Messages.send_message(scope, chat, c1.id, "Hello")
      {:ok, _} = Messages.add_body(message, %{content: "Hi"})
      message = Messages.get_message!(scope, message.id)
      active_id = Message.active_body(message).id
      Messages.subscribe(chat)

      assert {:ok, moved} = Messages.reattribute_message(scope, chat, message, {:name, " Narrator "})

      assert %Message{author_is_character: false, author_character_id: nil, author_name: "Narrator"} = moved
      assert moved.author_is_player
      assert length(moved.bodies) == 2
      assert Message.active_body(moved).id == active_id
      assert_receive {:message_updated, %Message{author_name: "Narrator"}}
    end

    test "never brands a message as the player's by moving it onto the player", %{scope: scope, chat: chat, c1: c1} do
      {:ok, message} =
        Messages.create_message(chat, %{
          author_is_character: false,
          author_name: "Narrator",
          bodies: [%{content: "Night."}]
        })

      assert {:ok, moved} = Messages.reattribute_message(scope, chat, message, {:character, c1.id})
      assert %Message{author_is_character: true, author_name: nil, author_is_player: false} = moved
      assert moved.author_character_id == c1.id
    end

    test "refuses a character that is not in the chat", %{scope: scope, chat: chat, c1: c1} do
      {:ok, message} = Messages.send_message(scope, chat, c1.id, "Hello")
      outsider = character(scope, "Carol")

      assert {:error, :not_participant} = Messages.reattribute_message(scope, chat, message, {:character, outsider.id})
      assert Messages.get_message!(scope, message.id).author_character_id == c1.id
    end

    test "refuses a blank name", %{scope: scope, chat: chat, c1: c1} do
      {:ok, message} = Messages.send_message(scope, chat, c1.id, "Hello")

      assert {:error, %Ecto.Changeset{} = changeset} = Messages.reattribute_message(scope, chat, message, {:name, "  "})
      assert %{author_name: _} = errors_on(changeset)
    end

    test "refuses while a body is generating", %{scope: scope, chat: chat, c1: c1} do
      {:ok, message} = Messages.create_generating_message(chat, c1.id)
      assert {:error, :generating} = Messages.reattribute_message(scope, chat, message, {:name, "Narrator"})
    end
  end

  describe "paged transcript" do
    setup do
      %{scope: scope, chat: chat, c1: c1} = ctx = setup_chat()
      for i <- 0..4, do: {:ok, _} = Messages.send_message(scope, chat, c1.id, "m#{i}")
      ctx
    end

    defp positions({page, more?}), do: {Enum.map(page, & &1.position), more?}

    test "list_messages_page/2 pages from the newest end and in both directions", %{scope: scope, chat: chat} do
      assert positions(Messages.list_messages_page(scope, chat, limit: 2)) == {[3, 4], true}
      assert positions(Messages.list_messages_page(scope, chat, before: 3, limit: 2)) == {[1, 2], true}
      assert positions(Messages.list_messages_page(scope, chat, before: 1, limit: 2)) == {[0], false}
      assert positions(Messages.list_messages_page(scope, chat, after: 1, limit: 2)) == {[2, 3], true}
      assert positions(Messages.list_messages_page(scope, chat, after: 3, limit: 5)) == {[4], false}
    end

    test "list_messages_page/2 preloads like list_messages/1", %{scope: scope, chat: chat} do
      {[message], _} = Messages.list_messages_page(scope, chat, limit: 1)
      assert [%MessageBody{content: "m4"}] = message.bodies
      assert message.author_character.name == "Alice"
    end

    test "an empty chat has no page" do
      %{scope: scope, chat: chat} = setup_chat()
      assert Messages.list_messages_page(scope, chat, limit: 2) == {[], false}
    end

    test "a scope that may not act on the chat gets no page", %{chat: chat} do
      assert Messages.list_messages_page(%Scope{}, chat, []) == {[], false}
    end

    test "drafts never appear in a page", %{scope: scope, chat: chat, c2: c2} do
      {:ok, chat} = Chats.update_chat(scope, Chats.get_chat!(chat.id), %{player_character_id: c2.id})
      {:ok, _draft} = Messages.upsert_draft(scope, chat, "unsent")

      assert positions(Messages.list_messages_page(scope, chat, limit: 10)) == {[0, 1, 2, 3, 4], false}
      assert positions(Messages.list_messages_page(scope, chat, after: 2, limit: 10)) == {[3, 4], false}
      assert Enum.map(Messages.list_messages_between(scope, chat, 0, 4), & &1.position) == [0, 1, 2, 3, 4]
    end

    test "list_messages_between/3 is inclusive", %{scope: scope, chat: chat} do
      assert Enum.map(Messages.list_messages_between(scope, chat, 1, 3), & &1.position) == [1, 2, 3]
    end

    test "window_edge/5 walks inward from either edge", %{scope: scope, chat: chat} do
      assert [{_, 4}, {_, 3}] = Messages.window_edge(scope, chat, 0, 4, :newest, 2)
      assert [{_, 0}, {_, 1}] = Messages.window_edge(scope, chat, 0, 4, :oldest, 2)
      assert [{_, 3}, {_, 2}] = Messages.window_edge(scope, chat, 1, 3, :newest, 2)
    end
  end

  describe "unread tracking" do
    setup do
      setup_chat()
    end

    test "a sent message is unread until mark_read", %{scope: scope, chat: chat, c1: c1} do
      {:ok, _} = Messages.send_message(scope, chat, c1.id, "hi")
      assert Map.has_key?(Messages.unread_chats(scope), chat.id)

      assert Messages.mark_read(scope, chat) == :ok
      refute Map.has_key?(Messages.unread_chats(scope), chat.id)
    end

    test "a message after mark_read is unread again; a draft is not", %{scope: scope, chat: chat, c1: c1, c2: c2} do
      {:ok, _} = Messages.send_message(scope, chat, c1.id, "hi")
      :ok = Messages.mark_read(scope, chat)

      {:ok, chat} = Chats.update_chat(scope, Chats.get_chat!(chat.id), %{player_character_id: c2.id})
      {:ok, _} = Messages.upsert_draft(scope, chat, "x")
      refute Map.has_key?(Messages.unread_chats(scope), chat.id)

      {:ok, _} = Messages.send_message(scope, chat, c1.id, "again")
      assert Map.has_key?(Messages.unread_chats(scope), chat.id)
    end

    test "a message reusing a deleted message's position is unread", %{scope: scope, chat: chat, c1: c1} do
      for i <- 1..3, do: {:ok, _} = Messages.send_message(scope, chat, c1.id, "m#{i}")
      {:ok, newest} = Messages.send_message(scope, chat, c1.id, "newest")
      :ok = Messages.mark_read(scope, chat)

      {:ok, _} = Messages.delete_message(scope, newest)
      {:ok, reused} = Messages.send_message(scope, chat, c1.id, "reused")

      assert reused.position == newest.position
      assert Map.has_key?(Messages.unread_chats(scope), chat.id)
    end

    test "mark_read on an empty chat is a no-op", %{scope: scope, chat: chat} do
      assert Messages.mark_read(scope, chat) == :ok
      refute Map.has_key?(Messages.unread_chats(scope), chat.id)
      assert Chats.get_chat!(chat.id).last_read_at == nil
    end

    test "broadcasts activity on send and read only when the cursor moves, with their stamps",
         %{scope: scope, chat: chat, c1: c1} do
      chat_id = chat.id
      Messages.subscribe_activity(scope)

      {:ok, _} = Messages.send_message(scope, chat, c1.id, "hi")
      assert_receive {:chat_activity, ^chat_id, %DateTime{} = at}
      assert Messages.unread_chats(scope) == %{chat_id => at}

      :ok = Messages.mark_read(scope, chat)
      assert_receive {:chat_read, ^chat_id, ^at}

      :ok = Messages.mark_read(scope, chat)
      refute_receive {:chat_read, _, _}
    end

    test "another user hears nothing of this chat's activity", %{scope: scope, chat: chat, c1: c1} do
      Messages.subscribe_activity(scope!())

      {:ok, _} = Messages.send_message(scope, chat, c1.id, "hi")
      :ok = Messages.mark_read(scope, chat)
      refute_receive {:chat_activity, _, _}
      refute_receive {:chat_read, _, _}
    end
  end

  describe "drafts" do
    setup do
      setup_chat()
    end

    test "a chat keeps one draft whoever plays, and sending clears it", %{
      scope: scope,
      chat: chat,
      c1: c1,
      c2: c2
    } do
      {:ok, chat} = Chats.update_chat(scope, Chats.get_chat!(chat.id), %{player_character_id: c1.id})
      {:ok, _} = Messages.upsert_draft(scope, chat, "first")

      {:ok, chat} = Chats.update_chat(scope, Chats.get_chat!(chat.id), %{player_character_id: c2.id})
      {:ok, _} = Messages.upsert_draft(scope, chat, "second")

      assert Repo.aggregate(from(m in Message, where: m.chat_id == ^chat.id and m.draft), :count) == 1
      assert Messages.draft_content(scope, chat) == "second"

      {:ok, _} = Messages.send_message(scope, chat, c2.id, "sent")
      assert Messages.get_draft(chat) == nil
    end
  end

  describe "import_transcript/2" do
    setup do
      %{scope: scope, chat: chat, c1: c1} = ctx = setup_chat()
      {:ok, chat} = Chats.update_chat(scope, chat, %{player_character_id: c1.id})
      %{ctx | chat: chat}
    end

    test "appends messages after existing ones with bodies, authors and times", %{chat: chat, c1: c1, c2: c2} do
      {:ok, _} =
        Messages.create_message(chat, %{
          author_is_character: true,
          author_character_id: c2.id,
          bodies: [%{content: "Existing"}]
        })

      t1 = ~U[2024-01-02 03:04:05.123000Z]
      t2 = ~U[2024-01-02 03:05:00.000000Z]
      t3 = ~U[2024-01-02 03:06:00.000000Z]

      assert :ok =
               Messages.import_transcript(chat, [
                 %{
                   author_character_id: c1.id,
                   author_name: nil,
                   visible_to_ai: true,
                   inserted_at: t1,
                   bodies: [%{content: "Hi", reasoning: nil}],
                   active: 0
                 },
                 %{
                   author_character_id: c2.id,
                   author_name: nil,
                   visible_to_ai: true,
                   inserted_at: t2,
                   bodies: [%{content: "One", reasoning: nil}, %{content: "Two", reasoning: "thought"}],
                   active: 1
                 },
                 %{
                   author_character_id: nil,
                   author_name: "Narrator",
                   visible_to_ai: false,
                   inserted_at: t3,
                   bodies: [%{content: "Aside", reasoning: nil}],
                   active: 0
                 }
               ])

      assert [_, m1, m2, m3] = Messages.list_messages(chat)
      assert Enum.map([m1, m2, m3], & &1.position) == [1, 2, 3]

      assert m1.author_is_player and m1.author_is_character
      assert m1.author_character_id == c1.id
      assert m1.inserted_at == t1
      assert m1.visible_to_ai

      refute m2.author_is_player
      assert m2.author_character_id == c2.id
      assert [%{content: "One", active: false}, %{content: "Two", active: true, reasoning: "thought"}] = m2.bodies
      assert Message.active_content(m2) == "Two"

      refute m3.author_is_character
      refute m3.author_is_player
      assert m3.author_name == "Narrator"
      refute m3.visible_to_ai
      assert m3.inserted_at == t3
      assert [%MessageBody{origin: :original, generating: false, active: true}] = m3.bodies
    end

    test "persists body metadata and links message and body attachments", %{chat: chat, c2: c2} do
      png =
        Base.decode64!(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        )

      {:ok, image} = Mythweaver.Attachments.store_binary(png)
      body_image = image
      at = ~U[2024-01-02 03:04:05.000000Z]
      later = ~U[2024-01-02 03:09:00.000000Z]

      assert :ok =
               Messages.import_transcript(chat, [
                 %{
                   author_character_id: c2.id,
                   author_name: nil,
                   visible_to_ai: true,
                   inserted_at: at,
                   attachments: [image],
                   bodies: [
                     %{content: "One", reasoning: nil},
                     %{
                       content: "Two",
                       origin: :regenerate,
                       guide: "be brief",
                       finish_reason: "stop",
                       prompt_tokens: 10,
                       completion_tokens: 5,
                       total_tokens: 15,
                       cost: Decimal.new("0.25"),
                       cost_estimated: true,
                       generation_ms: 900,
                       error: nil,
                       inserted_at: later,
                       attachments: [body_image]
                     }
                   ],
                   active: 1
                 }
               ])

      [message] = Messages.list_messages(chat)
      [one, two] = message.bodies
      assert %{origin: :original, cost_estimated: false} = one

      assert %{origin: :regenerate, guide: "be brief", finish_reason: "stop", prompt_tokens: 10} = two
      assert %{completion_tokens: 5, total_tokens: 15, cost_estimated: true, generation_ms: 900} = two
      assert Decimal.equal?(two.cost, Decimal.new("0.25"))
      assert DateTime.compare(two.inserted_at, later) == :eq
      assert Mythweaver.Attachments.message_attachment_ids(message.id) == [image.id]

      assert Repo.exists?(
               from l in BodyAttachment, where: l.message_body_id == ^two.id and l.attachment_id == ^body_image.id
             )
    end
  end

  describe "search_messages/4" do
    setup do
      setup_chat()
    end

    defp say!(chat, author, content, attrs \\ %{}) do
      {:ok, message} =
        Messages.create_message(
          chat,
          Map.merge(%{author_is_character: true, author_character_id: author.id, bodies: [%{content: content}]}, attrs)
        )

      message
    end

    test "matches body text case-insensitively and speaker names", %{scope: scope, chat: chat, c1: c1, c2: c2} do
      tea = say!(chat, c1, "I love Green TEA")
      _other = say!(chat, c1, "Nothing here")
      bob = say!(chat, c2, "Hello")

      assert {[%{id: id}], false} = Messages.search_messages(scope, chat, "green tea")
      assert id == tea.id
      assert {[%{id: ^id}], false} = Messages.search_messages(scope, chat, "  green tea  ")
      assert {[%{id: bob_id}], false} = Messages.search_messages(scope, chat, "bob")
      assert bob_id == bob.id

      {:ok, narrator} =
        Messages.create_message(chat, %{author_is_character: false, author_name: "Narrator", bodies: [%{content: "x"}]})

      assert {[%{id: narrator_id}], false} = Messages.search_messages(scope, chat, "narr")
      assert narrator_id == narrator.id
      assert {all, false} = Messages.search_messages(scope, chat, "")
      assert length(all) == 4
    end

    test "treats % and _ literally", %{scope: scope, chat: chat, c1: c1} do
      percent = say!(chat, c1, "100% sure")
      _plain = say!(chat, c1, "100 sure")
      _under = say!(chat, c1, "a_b")

      assert {[%{id: id}], false} = Messages.search_messages(scope, chat, "100%")
      assert id == percent.id
      assert {[], false} = Messages.search_messages(scope, chat, "0_s")
    end

    test "hidden_only returns only hidden messages", %{scope: scope, chat: chat, c1: c1} do
      hidden = say!(chat, c1, "secret word", %{visible_to_ai: false})
      _shown = say!(chat, c1, "public word")

      assert {[%{id: id}], false} = Messages.search_messages(scope, chat, "word", hidden_only: true)
      assert id == hidden.id
    end

    test "the 51st match sets more? and offset pages on", %{scope: scope, chat: chat, c1: c1} do
      for n <- 1..51, do: say!(chat, c1, "match #{n}")

      assert {page, true} = Messages.search_messages(scope, chat, "match")
      assert length(page) == 50
      assert hd(page).position == 0
      assert {[last], false} = Messages.search_messages(scope, chat, "match", offset: 50)
      assert last.position == 50
    end

    test "another user's chat returns nothing", %{chat: chat, c1: c1} do
      say!(chat, c1, "hi")
      assert {[], false} = Messages.search_messages(scope!(), chat, "")
    end
  end

  describe "content moderation" do
    test "a scanned user's sent message that matches a rule gets a rule report" do
      %{scope: scope, chat: chat, c1: c1} = setup_chat()
      :ok = Mythweaver.Permissions.put_grant!(scope.user, "moderation.chats.permissive", :allow)
      scope = Scope.for_user(scope.user)

      {:ok, _rule} =
        Rules.create_rule(scope!(), %{
          "name" => "Words",
          "kind" => "regex",
          "content_types" => ["chats"],
          "pattern" => "forbidden"
        })

      {:ok, clean} = Messages.send_message(scope, chat, c1.id, "hello")
      {:ok, message} = Messages.send_message(scope, chat, c1.id, "a forbidden line")

      reports = Repo.all(Report)
      assert [%{source: :rule, subject_type: :message, subject_id: id, snapshot: "a forbidden line"}] = reports
      assert id == message.id
      refute Enum.any?(reports, &(&1.subject_id == clean.id))
    end
  end
end
