defmodule MythweaverWeb.MainChatLive.MembershipTest do
  use MythweaverWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Messages
  alias Mythweaver.Notifications

  setup %{conn: conn} do
    owner = register_user!(%{role: :user, nickname: "Owner"})
    owner_scope = Scope.for_user(owner)
    guest = register_user!(%{role: :user, nickname: "Guest"})
    {chat, a, b} = chat!(owner_scope, "Tavern")

    %{conn: conn, owner: owner, owner_scope: owner_scope, guest: guest, chat: chat, a: a, b: b}
  end

  defp chat!(scope, name) do
    [a, b] =
      for n <- ["A", "B"] do
        {:ok, c} = Characters.create_character(scope, %{name: "#{n}-#{System.unique_integer([:positive])}"})
        c
      end

    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: name,
        participants: [%{character_id: a.id}, %{character_id: b.id}],
        player_character_id: a.id
      })

    {Chats.get_chat(chat.id), a, b}
  end

  defp join!(owner_scope, chat, user, role) do
    {:ok, member} = Chats.invite(owner_scope, chat, user.handle, role)
    {:ok, _} = Chats.accept_invite(Scope.for_user(user), member.id)
    :ok
  end

  defp participant_id(chat, character), do: Enum.find(chat.participants, &(&1.character_id == character.id)).id

  describe "as a guest" do
    setup %{owner_scope: owner_scope, chat: chat, guest: guest, conn: conn} do
      join!(owner_scope, chat, guest, :guest)
      %{conn: log_in_user(conn, guest)}
    end

    test "the chat opens without the owner's tools", %{conn: conn, chat: chat, owner_scope: owner_scope, a: a} do
      {:ok, message} = Messages.send_message(owner_scope, chat, a.id, "Hello from the owner")
      {:ok, view, html} = live(conn, ~p"/chats/#{chat.id}")

      assert html =~ "Tavern"
      assert render(view) =~ "Hello from the owner"

      for id <- ~w(chat-settings-button chat-memory-button chat-variables-button chat-injections-button
                   chat-jobs-button auto-mode-toggle add-participant) do
        refute has_element?(view, "##{id}"), "#{id} shown to a guest"
      end

      refute has_element?(view, "#prompt-inspector-#{message.id}")
      refute has_element?(view, "#message-edit-#{message.id}")
      refute has_element?(view, "#message-delete-#{message.id}")
      refute has_element?(view, "#message-select-#{message.id}")
      refute has_element?(view, "#play-as-#{participant_id(chat, a)}")

      # No character yet: the composer explains how to get one.
      assert has_element?(view, "#chat-composer-notice", "Ask the owner for a character.")

      # Pushed by hand, the panels' events are ignored rather than loading (or crashing on) them.
      render_click(view, "open_chat_variables", %{})
      render_click(view, "open_prompt_inspector", %{"message_id" => message.id})
      refute has_element?(view, "#prompt-inspector")
      assert render(view) =~ "Hello from the owner"
    end

    test "the settings and memory routes stay closed", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}/settings")
      refute has_element?(view, "#chat-settings-modal")

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}/memory")
      refute has_element?(view, "#memory-modal")
    end

    test "with free switching the guest takes a character and posts as it", ctx do
      %{conn: conn, chat: chat, owner_scope: owner_scope, guest: guest, b: b} = ctx
      {:ok, _} = Chats.update_membership_settings(owner_scope, chat, %{"free_switching" => true})
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      assert has_element?(view, "#chat-composer-notice", "Take a character to post.")
      row = participant_id(chat, b)

      view |> element("#take-character-#{row}") |> render_click()

      assert [%{id: guest_id}] = Chats.locks(chat)[b.id]
      assert guest_id == guest.id
      assert has_element?(view, "#participant-holders-#{row}-toggle")
      assert has_element?(view, "#participant-holders-#{row} li", "@#{guest.handle}")
      assert has_element?(view, "#release-character-#{row}")
      refute has_element?(view, "#chat-composer-notice")
      assert has_element?(view, "#message-composer")

      view |> element("#release-character-#{row}") |> render_click()
      assert Chats.locks(chat) == %{}
      refute has_element?(view, "#participant-holders-#{row}-toggle")
      assert has_element?(view, "#chat-composer-notice", "Take a character to post.")
    end

    test "a guest's own messages keep their edit and delete controls", ctx do
      %{conn: conn, chat: chat, owner_scope: owner_scope, guest: guest, b: b} = ctx
      {:ok, _} = Chats.update_membership_settings(owner_scope, chat, %{"free_switching" => true})
      guest_scope = Scope.for_user(guest)
      :ok = Chats.lock(guest_scope, Chats.get_chat(chat.id), b)
      {:ok, mine} = Messages.send_message(guest_scope, Chats.get_chat(chat.id), b.id, "Mine")

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      assert has_element?(view, "#message-edit-#{mine.id}")
      assert has_element?(view, "#message-delete-#{mine.id}")
    end

    test "a guest holding several characters picks who they post as", ctx do
      %{conn: conn, chat: chat, owner_scope: owner_scope, guest: guest, a: a, b: b} = ctx
      {:ok, _} = Chats.assign_characters(owner_scope, chat, guest.id, [a.id, b.id])
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      [row_a, row_b] = [participant_id(chat, a), participant_id(chat, b)]

      assert has_element?(view, "#play-as-#{row_a}")
      assert has_element?(view, "#play-as-#{row_b}")
      assert has_element?(view, "#participant-#{row_a}.chat-participant--player")
      assert has_element?(view, "#chat-composer-poster", a.name)

      view |> element("#play-as-#{row_b}") |> render_click()
      assert has_element?(view, "#participant-#{row_b}.chat-participant--player")
      refute has_element?(view, "#participant-#{row_a}.chat-participant--player")
      assert has_element?(view, "#chat-composer-poster", b.name)

      view |> form("#message-composer", composer: %{content: "As B"}) |> render_submit()
      assert [%{author_character_id: author, author_user_id: author_user}] = Messages.list_messages(chat)
      assert author == b.id and author_user == guest.id
      # A guest's pick is theirs alone: the chat's player character stays the owner's.
      assert Chats.get_chat(chat.id).player_character_id == a.id
    end

    test "an :own guest's model pick shows in every one of their tabs", ctx do
      %{conn: conn, chat: chat, owner_scope: owner_scope, guest: guest} = ctx
      guest_scope = Scope.for_user(guest)
      {:ok, _} = Chats.set_model_source(owner_scope, Chats.member_for(guest_scope, chat).id, :own)

      {:ok, provider} =
        AI.create_provider(guest_scope, %{name: "P-Guest", adapter: :openai_compatible, base_url: "http://x/v1"})

      {:ok, model} = AI.create_model(guest_scope, %{name: "Guest model", api_model_id: "m"})
      {:ok, _} = AI.link_model(guest_scope, provider, model)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      {:ok, other, _html} = live(log_in_user(build_conn(), guest), ~p"/chats/#{chat.id}")

      view |> form("#member-model-form", member_model: %{ai_model_id: model.id}) |> render_change()

      assert Chats.member_for(guest_scope, chat).ai_model_id == model.id

      for v <- [view, other],
          do: assert(has_element?(v, ~s(#member-model-form-ai_model_id option[selected][value="#{model.id}"])))
    end
  end

  describe "as the owner" do
    setup %{conn: conn, owner: owner} do
      %{conn: log_in_user(conn, owner)}
    end

    test "the Members tab invites a guest by handle into their inbox", %{conn: conn, chat: chat, guest: guest} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}/settings")

      view |> element("#chat-settings-tab-members") |> render_click()
      assert has_element?(view, "#chat-members-empty")

      view
      |> form("#chat-members-invite", invite: %{handle: "@" <> guest.handle, role: "guest"})
      |> render_submit()

      assert has_element?(view, "#chat-members li", "@#{guest.handle}")
      assert has_element?(view, "#chat-members li", "Invited")
      assert [%{kind: :chat_invite}] = Notifications.inbox(Scope.for_user(guest))
    end

    test "the Members tab saves toggles, assigns players and removes members", ctx do
      %{conn: conn, chat: chat, owner_scope: owner_scope, owner: owner, guest: guest, a: a, b: b} = ctx
      join!(owner_scope, chat, guest, :guest)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}/settings")
      view |> element("#chat-settings-tab-members") |> render_click()

      # A browser also posts `_unused_*` markers for untouched inputs; they must not fail the save.
      view
      |> form("#chat-membership-form", membership: %{guest_permissions: %{run_scripts: "true"}, turn_mode: "round"})
      |> render_change(%{"membership" => %{"guest_permissions" => %{"_unused_edit_own" => ""}}})

      reloaded = Chats.get_chat(chat.id)
      assert reloaded.turn_mode == :round
      assert Chat.guest_permissions(reloaded)["run_scripts"]

      refute has_element?(view, "#chat-players-form")

      view |> form("#chat-players-add", player: %{user_id: guest.id}) |> render_submit()
      assert has_element?(view, "#chat-player-#{guest.id}")

      view
      |> form("#chat-players-form")
      |> render_change(%{"players" => %{guest.id => ["", a.id, b.id]}})

      assert Chats.locks_of(Scope.for_user(guest), chat) == [a.id, b.id]

      # Another row may share a character; an untouched row is not rewritten.
      view |> form("#chat-players-add", player: %{user_id: owner.id}) |> render_submit()

      view
      |> form("#chat-players-form")
      |> render_change(%{"players" => %{guest.id => ["", a.id, b.id], owner.id => ["", b.id]}})

      assert chat |> Chats.locks() |> Map.fetch!(b.id) |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.sort([guest.id, owner.id])

      view |> element("#chat-player-remove-#{owner.id}") |> render_click()
      refute has_element?(view, "#chat-player-#{owner.id}")
      assert Chats.locks_of(owner_scope, chat) == []

      [member] = Chats.list_members(owner_scope, reloaded)
      view |> element("#chat-member-remove-#{member.id}") |> render_click()

      assert Chats.list_members(owner_scope, reloaded) == []
      assert Chats.locks(chat) == %{}
    end

    test "round mode offers Skip turn to a player holding a character", ctx do
      %{conn: conn, chat: chat, owner_scope: owner_scope, a: a} = ctx
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      refute has_element?(view, "#skip-turn")

      {:ok, _} =
        Chats.update_membership_settings(owner_scope, chat, %{"free_switching" => true, "turn_mode" => "round"})

      :ok = Chats.lock(owner_scope, Chats.get_chat(chat.id), a)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      view |> element("#skip-turn") |> render_click()
      assert render(view) =~ "Turn skipped"
    end

    test "playing as a held character also makes it the chat's player character", ctx do
      %{conn: conn, chat: chat, owner_scope: owner_scope, owner: owner, a: a, b: b} = ctx
      {:ok, _} = Chats.assign_characters(owner_scope, chat, owner.id, [a.id, b.id])
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      row_b = participant_id(chat, b)

      view |> element("#play-as-#{row_b}") |> render_click()

      assert Chats.get_chat(chat.id).player_character_id == b.id
      assert has_element?(view, "#play-as-#{row_b}[aria-pressed=true]")
      assert has_element?(view, "#chat-composer-poster", b.name)

      view |> form("#message-composer", composer: %{content: "As B"}) |> render_submit()
      assert [%{author_character_id: author, author_is_player: true}] = Messages.list_messages(chat)
      assert author == b.id
    end
  end
end
