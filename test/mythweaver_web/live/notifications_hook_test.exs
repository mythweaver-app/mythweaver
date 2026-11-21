defmodule MythweaverWeb.NotificationsHookTest do
  use MythweaverWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message
  alias Mythweaver.Notifications
  alias Mythweaver.Notifications.Focus
  alias Mythweaver.Notifications.Notification

  setup :register_and_log_in_user

  defp broadcast(user, kind, channels, icon \\ nil) do
    chat_id = Mythweaver.Schema.generate_id()
    notification = %Notification{id: "n-#{kind}", kind: kind, title: "t", body: "b", chat_id: chat_id, icon: icon}

    Phoenix.PubSub.broadcast(
      Mythweaver.PubSub,
      Notifications.topic(user.id),
      {Notifications, :in_app, notification, channels}
    )

    chat_id
  end

  test "any page pushes the user's notifications to the client", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    chat_id = broadcast(user, :regenerate, %{popup: true, sound: false})
    path = "/chats/#{chat_id}"
    refute has_element?(view, "#flash-info")

    assert_push_event(view, "notify", %{
      id: "n-regenerate",
      kind: "regenerate",
      path: ^path,
      popup: true,
      sound: false,
      icon: "/favicon.ico"
    })

    broadcast(user, :new_message, %{popup: false, sound: true}, "/uploads/a.png")

    assert_push_event(view, "notify", %{
      kind: "new_message",
      popup: false,
      sound: "/audio/new.mp3",
      icon: "/uploads/a.png"
    })

    # A memory review opens the chat's Reviews tab, and says so in the page's flash with a link.
    chat_id = broadcast(user, :memory_review, %{popup: false, sound: false})
    review = "/chats/#{chat_id}/memory?tab=reviews"

    assert_push_event(view, "notify", %{kind: "memory_review", path: ^review, sound: false})
    assert has_element?(view, "#flash-memory_review a.flash-action[href='#{review}']", "Review")
  end

  test "a page reports its focus; the user counts as looking while any page has it",
       %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/settings")
    {:ok, other, _html} = live(conn, ~p"/jobs")
    refute Focus.focused?(user.id)

    view |> element("#notifications") |> render_hook("app_focus", %{focused: true})
    assert Focus.focused?(user.id)

    other |> element("#notifications") |> render_hook("app_focus", %{focused: false})
    assert Focus.focused?(user.id)

    # A page that goes away takes its focus with it.
    ref = Process.monitor(view.pid)
    GenServer.stop(view.pid)
    assert_receive {:DOWN, ^ref, :process, _, _}
    refute Focus.focused?(user.id)
  end

  describe "inbox" do
    setup %{scope: scope} do
      {:ok, c1} = Characters.create_character(scope, %{name: "Ciri"})
      {:ok, c2} = Characters.create_character(scope, %{name: "Yen"})

      {:ok, chat} =
        Chats.create_chat(scope, %{name: "Inbox", participants: [%{character_id: c1.id}, %{character_id: c2.id}]})

      chat = Chats.get_chat!(chat.id)
      {:ok, message} = Messages.send_message(scope, chat, c1.id, "Hi")
      :ok = Notifications.reply_finished(scope, :new_message, chat, c1, Message.active_body(message))
      [reply] = Notifications.inbox(scope)
      %{reply: reply}
    end

    test "the bell counts notifications and the panel lists every item", %{conn: conn, scope: scope, reply: reply} do
      :ok = Notifications.record_error(scope, "It broke")
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#notification-bell-badge", "1")
      assert has_element?(view, "#notification-bell[data-unread]")
      assert has_element?(view, "#notification-bell-compact[data-unread]")
      assert has_element?(view, "#notification-inbox-items-#{reply.id}", reply.title)
      assert has_element?(view, "#notification-inbox-items li[data-kind='error']", "It broke")
    end

    test "dismissing an item removes it and its count", %{conn: conn, reply: reply} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> element("#notification-inbox-items-#{reply.id} .notification-inbox-dismiss") |> render_click()
      _ = :sys.get_state(view.pid)

      refute has_element?(view, "#notification-inbox-items-#{reply.id}")
      refute has_element?(view, "#notification-bell-badge")
      refute has_element?(view, "#notification-bell[data-unread]")
      refute has_element?(view, "#notification-bell-compact[data-unread]")
      assert has_element?(view, "#notification-inbox-empty")
    end

    test "an item stored elsewhere arrives live", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      :ok = Notifications.record_error(scope, "Late")
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#notification-inbox-items li[data-kind='error']", "Late")
    end

    test "an error toast is kept once per appearance; other toasts are not", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      send(view.pid, {MythweaverWeb.CommandPalette, :flash, :error, "Boom"})
      render(view)
      send(view.pid, {MythweaverWeb.CommandPalette, :flash, :error, "Boom"})
      render(view)
      send(view.pid, {MythweaverWeb.CommandPalette, :flash, :info, "Fine"})
      render(view)

      titles = for %Notification{kind: :error, title: title} <- Notifications.inbox(scope), do: title
      assert titles == ["Boom"]
      refute Enum.any?(Notifications.inbox(scope), &(&1.title == "Fine"))
    end
  end
end
