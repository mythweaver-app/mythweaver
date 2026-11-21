defmodule Mythweaver.NotificationsTest do
  use Mythweaver.DataCase, async: true

  alias Mythweaver.Attachments
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message
  alias Mythweaver.Notifications
  alias Mythweaver.Notifications.Notification
  alias Mythweaver.Repo
  alias Mythweaver.Settings

  setup do
    scope = scope!()
    :ok = Notifications.subscribe(scope)
    %{scope: scope}
  end

  defp notify(scope) do
    Notifications.notify(scope, %Notification{
      id: "n1",
      kind: :continue,
      title: "t",
      body: "b",
      chat_id: Mythweaver.Schema.generate_id()
    })
  end

  describe "notify/2" do
    test "delivers in-app with both channels on by default", %{scope: scope} do
      assert :ok = notify(scope)
      assert_receive {Notifications, :in_app, %Notification{id: "n1"}, %{popup: true, sound: true}}
    end

    test "carries the kind's own toggles", %{scope: scope} do
      :ok = Settings.put(scope, :user, "notifications.continue.popup", false)

      notify(scope)
      assert_receive {Notifications, :in_app, %{id: "n1"}, %{popup: false, sound: true}}
    end

    test "sends nothing when the kind has every channel off", %{scope: scope} do
      :ok = Settings.put(scope, :user, "notifications.continue.popup", false)
      :ok = Settings.put(scope, :user, "notifications.continue.sound", false)

      notify(scope)
      refute_receive {Notifications, _, _, _}, 100
    end

    test "mute silences every kind", %{scope: scope} do
      :ok = Settings.put(scope, :user, "notifications.muted", true)

      notify(scope)
      refute_receive {Notifications, _, _, _}, 100
    end
  end

  describe "reply_finished/5" do
    setup %{scope: scope} do
      {:ok, character} = Characters.create_character(scope, %{name: "Geralt-#{System.unique_integer([:positive])}"})
      %{chat: %Chat{id: Mythweaver.Schema.generate_id(), name: nil}, character: character}
    end

    test "titles the reply and collapses its text into a capped excerpt", ctx do
      content = "Line one\n\n  line two " <> String.duplicate("é", 200)

      Notifications.reply_finished(ctx.scope, :new_message, ctx.chat, ctx.character, %{
        message_id: "m1",
        content: content
      })

      assert_receive {Notifications, :in_app, %Notification{} = n, _}
      assert n.title == "#{ctx.character.name} replied — Untitled chat"
      assert n.message_id == "m1"
      assert String.starts_with?(n.body, "Line one line two é")
      assert String.length(n.body) == 161
      assert String.ends_with?(n.body, "…")
      # No avatar: the client falls back to the app icon.
      assert n.icon == nil
    end

    test "a blank reply says so", ctx do
      Notifications.reply_finished(ctx.scope, :continue, ctx.chat, ctx.character, %{message_id: "m1", content: " \n "})

      assert_receive {Notifications, :in_app, %Notification{body: "The reply has no text."}, _}
    end

    test "the character's avatar is the picture, even when the caller has not loaded it", ctx do
      png =
        Base.decode64!(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        )

      {:ok, avatar} = Attachments.store_binary(png)
      :ok = Attachments.set_avatar(ctx.scope, ctx.character, avatar, describe: false)

      Notifications.reply_finished(ctx.scope, :regenerate, ctx.chat, ctx.character, %{message_id: "m1", content: "x"})

      assert_receive {Notifications, :in_app, %Notification{icon: icon}, _}
      assert icon == Attachments.url(Mythweaver.Repo.reload!(avatar), :avatar)
    end
  end

  defp reply!(ctx), do: :ok = Notifications.reply_finished(ctx.scope, :new_message, ctx.chat, ctx.character, ctx.body)

  describe "inbox" do
    setup %{scope: scope} do
      {:ok, c1} = Characters.create_character(scope, %{name: "Ciri"})
      {:ok, c2} = Characters.create_character(scope, %{name: "Yen"})

      {:ok, chat} =
        Chats.create_chat(scope, %{name: "Inbox", participants: [%{character_id: c1.id}, %{character_id: c2.id}]})

      chat = Chats.get_chat!(chat.id)
      {:ok, message} = Messages.send_message(scope, chat, c1.id, "Hi")
      %{chat: chat, character: c1, body: Message.active_body(message)}
    end

    test "a reply in an unread chat is stored and announced", ctx do
      chat_id = ctx.chat.id
      reply!(ctx)

      assert [%Notification{kind: :new_message, chat_id: ^chat_id}] = Notifications.inbox(ctx.scope)
      assert Notifications.inbox_count(ctx.scope) == 1
      assert_receive {Notifications, :inbox_changed}
    end

    test "a reply in a chat already read is not stored", ctx do
      :ok = Messages.mark_read(ctx.scope, ctx.chat)
      reply!(ctx)

      assert Notifications.inbox(ctx.scope) == []
    end

    test "reading the chat deletes its replies and nothing else", ctx do
      reply!(ctx)
      :ok = Notifications.record_error(ctx.scope, "x")
      assert_receive {Notifications, :inbox_changed}
      assert_receive {Notifications, :inbox_changed}

      :ok = Messages.mark_read(ctx.scope, ctx.chat)

      assert [%Notification{kind: :error, title: "x"}] = Notifications.inbox(ctx.scope)
      assert Notifications.inbox_count(ctx.scope) == 0
      assert_receive {Notifications, :inbox_changed}
    end

    test "mute silences the channels but still stores", ctx do
      :ok = Settings.put(ctx.scope, :user, "notifications.muted", true)
      reply!(ctx)

      assert [%Notification{}] = Notifications.inbox(ctx.scope)
      refute_receive {Notifications, :in_app, _, _}, 100
    end

    test "an expired item is not listed, and prune deletes it", %{scope: scope} do
      Repo.insert!(%Notification{
        user_id: scope.user.id,
        kind: :error,
        title: "old",
        expires_at: DateTime.add(DateTime.utc_now(:second), -1)
      })

      assert Notifications.inbox(scope) == []
      assert Notifications.prune() == :ok
      assert Repo.aggregate(Notification, :count) == 0
    end

    test "only the owner can dismiss an item", ctx do
      reply!(ctx)
      [%Notification{id: id}] = Notifications.inbox(ctx.scope)

      assert Notifications.dismiss(scope!(), id) == {:error, :not_found}
      assert Notifications.dismiss(ctx.scope, "junk") == {:error, :not_found}
      assert Notifications.dismiss(ctx.scope, id) == :ok
      assert Notifications.inbox(ctx.scope) == []
    end

    test "clear all leaves the items waiting on the user", ctx do
      reply!(ctx)
      :ok = Notifications.record_error(ctx.scope, "x")

      review = %Notification{
        id: Mythweaver.Schema.generate_id(),
        kind: :memory_review,
        title: "r",
        chat_id: ctx.chat.id
      }

      :ok = Notifications.notify(ctx.scope, review)

      assert Notifications.dismiss_all(ctx.scope) == :ok
      assert [%Notification{kind: :memory_review} = kept] = Notifications.inbox(ctx.scope)

      assert Notifications.dismiss(ctx.scope, kept.id) == :ok
      assert Notifications.inbox(ctx.scope) == []
    end

    test "deleting the chat takes its replies and tells the inbox", ctx do
      reply!(ctx)
      assert_receive {Notifications, :inbox_changed}

      {:ok, _} = Chats.delete_chat(ctx.scope, ctx.chat)

      assert Notifications.inbox(ctx.scope) == []
      assert_receive {Notifications, :inbox_changed}
    end
  end
end
