defmodule Mythweaver.Chats.MembershipTest do
  use Mythweaver.DataCase

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Chats.CharacterLock
  alias Mythweaver.Chats.Member
  alias Mythweaver.Chats.Participant
  alias Mythweaver.Generation
  alias Mythweaver.Messages
  alias Mythweaver.Messages.DraftBuffer
  alias Mythweaver.Notifications
  alias Mythweaver.Permissions

  @actions [:read, :post, :regenerate, :generate, :run_scripts, :attach, :manage, :inspect, :delete]

  setup do
    owner = scope!(%{role: :user})
    chat = chat!(owner, "Tavern")
    %{owner: owner, chat: chat}
  end

  defp character!(scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: name})
    character
  end

  defp chat!(owner, name) do
    [a, b] = [character!(owner, "A-#{name}"), character!(owner, "B-#{name}")]

    {:ok, chat} =
      Chats.create_chat(owner, %{
        name: name,
        player_character_id: a.id,
        participants: [%{character_id: a.id}, %{character_id: b.id}]
      })

    Chats.get_chat(chat.id)
  end

  defp rescope(%Scope{user: user}), do: user.id |> Accounts.get_user() |> Scope.for_user()

  defp member!(owner, chat, role) do
    user = scope!(%{role: :user})
    {:ok, member} = Chats.invite(owner, chat, user.user.handle, role)
    {:ok, _} = Chats.accept_invite(user, member.id)
    user
  end

  defp model!(scope) do
    {:ok, model} = AI.create_model(scope, %{name: "M-#{System.unique_integer([:positive])}", api_model_id: "m"})
    model
  end

  defp allowed(scope, chat), do: for(a <- @actions, Chats.authorize(scope, chat, a) == :ok, do: a)

  defp free_switching!(owner, chat) do
    {:ok, chat} = Chats.update_membership_settings(owner, chat, %{free_switching: true})
    chat
  end

  describe "authorize/3 and role/2" do
    setup %{owner: owner, chat: chat} do
      %{editor: member!(owner, chat, :editor), guest: member!(owner, chat, :guest), stranger: scope!()}
    end

    test "each role's actions with the default guest toggles", ctx do
      %{owner: owner, editor: editor, guest: guest, stranger: stranger, chat: chat} = ctx

      assert allowed(owner, chat) == @actions
      assert allowed(editor, chat) == @actions -- [:delete]
      assert allowed(guest, chat) == [:read, :post, :regenerate, :generate, :attach]
      assert allowed(stranger, chat) == []
      assert allowed(guest, chat.id) == allowed(guest, chat)

      assert Chats.role(owner, chat) == :owner
      assert Chats.role(editor, chat) == :editor
      assert Chats.role(guest, chat.id) == :guest
      assert Chats.role(stranger, chat) == nil
    end

    test "guests edit and delete only their own messages, while the toggles allow", ctx do
      %{owner: owner, editor: editor, guest: guest, chat: chat} = ctx
      [a, b] = Enum.map(chat.participants, & &1.character_id)

      {:ok, _} = Chats.assign_characters(owner, chat, guest.user.id, [b])
      {:ok, own} = Messages.send_message(guest, chat, a, "mine")
      {:ok, theirs} = Messages.send_message(owner, chat, a, "the owner's")
      assert own.author_user_id == guest.user.id

      for tag <- [:edit_message, :delete_message] do
        assert Chats.authorize(guest, chat, {tag, own}) == :ok
        assert Chats.authorize(guest, chat, {tag, theirs}) == {:error, :unauthorized}
        assert Chats.authorize(editor, chat, {tag, own}) == :ok
        assert Chats.authorize(owner, chat, {tag, own}) == :ok
      end

      {:ok, _} =
        Chats.update_chat(owner, chat, %{
          guest_permissions: %{"edit_own" => false, "regenerate" => false, "run_scripts" => true}
        })

      chat = Chats.get_chat(chat.id)
      assert Chats.authorize(guest, chat, {:edit_message, own}) == {:error, :unauthorized}
      assert Chats.authorize(guest, chat, {:delete_message, own}) == :ok
      assert allowed(guest, chat) == [:read, :post, :generate, :run_scripts, :attach]
    end

    test "a message of another chat is refused, for the owner too", %{owner: owner, chat: chat} do
      other = chat!(owner, "Elsewhere")
      {:ok, message} = Messages.send_message(owner, other, hd(other.participants).character_id, "hi")

      assert Chats.authorize(owner, chat, {:edit_message, message}) == {:error, :unauthorized}
    end

    test "guests may not change the chat's settings", %{guest: guest, editor: editor, chat: chat} do
      assert {:error, :unauthorized} = Chats.update_chat(guest, chat, %{name: "Mine now"})
      assert {:ok, _} = Chats.update_chat(editor, chat, %{name: "Renamed"})
      assert {:error, :unauthorized} = Chats.delete_chat(editor, chat)
    end
  end

  describe "invites" do
    test "an invite reaches the inbox; accepting lists the chat", %{owner: owner, chat: chat} do
      guest = scope!(%{role: :user})
      :ok = Chats.subscribe(guest)

      assert {:ok, %Member{status: :pending, role: :guest} = member} =
               Chats.invite(owner, chat, "@" <> String.upcase(guest.user.handle), :guest)

      assert [%{kind: :chat_invite, chat_member_id: member_id} = item] = Notifications.inbox(guest)
      assert member_id == member.id
      assert Notifications.needs_action?(item)
      assert Chats.list_member_chats(guest) == []
      refute Chats.get_chat(guest, chat.id)

      assert {:ok, %Member{status: :accepted}} = Chats.accept_invite(guest, member.id)
      assert Notifications.inbox(guest) == []
      assert [%{id: id, user: %{id: owner_id}}] = Chats.list_member_chats(guest)
      assert id == chat.id and owner_id == owner.user.id
      assert Chats.get_chat(guest, chat.id)
      assert Chats.list_chats(guest) == []

      chat_id = chat.id
      assert_receive {:chat_updated, ^chat_id}
    end

    test "decline leaves the chat unlisted and allows a new invite", %{owner: owner, chat: chat} do
      guest = scope!(%{role: :user})
      {:ok, member} = Chats.invite(owner, chat, guest.user.handle, :guest)

      assert {:ok, %Member{status: :declined}} = Chats.decline_invite(guest, member.id)
      assert Notifications.inbox(guest) == []
      assert Chats.list_member_chats(guest) == []
      assert {:error, :not_found} = Chats.accept_invite(guest, member.id)
      assert {:ok, %Member{status: :pending}} = Chats.invite(owner, chat, guest.user.handle, :editor)
    end

    test "refuses unknown handles, oneself, the owner, repeats and strangers", %{owner: owner, chat: chat} do
      editor = member!(owner, chat, :editor)
      guest = scope!(%{role: :user})

      assert {:error, :unknown_handle} = Chats.invite(owner, chat, "nobody_has_this", :guest)
      assert {:error, :self} = Chats.invite(owner, chat, owner.user.handle, :guest)
      assert {:error, :already_member} = Chats.invite(editor, chat, owner.user.handle, :guest)
      assert {:error, :already_member} = Chats.invite(owner, chat, editor.user.handle, :guest)
      assert {:error, :unauthorized} = Chats.invite(scope!(), chat, guest.user.handle, :guest)
    end

    test "an editor invites guests only", %{owner: owner, chat: chat} do
      editor = member!(owner, chat, :editor)
      other = scope!(%{role: :user})

      assert {:error, :unauthorized} = Chats.invite(editor, chat, other.user.handle, :editor)
      assert {:ok, %Member{role: :guest}} = Chats.invite(editor, chat, other.user.handle, :guest)
    end

    test "a guest invites nobody", %{owner: owner, chat: chat} do
      guest = member!(owner, chat, :guest)
      assert {:error, :unauthorized} = Chats.invite(guest, chat, scope!().user.handle, :guest)
    end

    test "needs chats.invite and counts toward the pending invite limit", %{owner: owner, chat: chat} do
      [second, third] = [scope!(%{role: :user}), scope!(%{role: :user})]

      :ok = Permissions.put_grant!(owner.user, "quota.pending_invites", 1)
      limited = rescope(owner)
      assert {:ok, _} = Chats.invite(limited, chat, second.user.handle, :guest)
      assert {:error, :quota_exceeded} = Chats.invite(limited, chat, third.user.handle, :guest)

      :ok = Permissions.put_grant!(owner.user, "chats.invite", :deny)
      assert {:error, :unauthorized} = Chats.invite(rescope(owner), chat, third.user.handle, :guest)
    end
  end

  describe "locks, posting and brought characters" do
    setup %{owner: owner, chat: chat} do
      [a, b] = Enum.map(chat.participants, & &1.character_id)
      %{a: a, b: b, guest: member!(owner, chat, :guest)}
    end

    test "a guest posts only as the character they hold", %{owner: owner, chat: chat, guest: guest, a: a, b: b} do
      assert Messages.send_message(guest, chat, a, "hello") == {:error, :no_character}
      assert Chats.lock(guest, chat, b) == {:error, :not_allowed}

      chat = free_switching!(owner, chat)
      assert Chats.lock(guest, chat, b) == :ok
      assert Chats.locks_of(guest, chat) == [b]
      assert %{^b => [%{id: guest_id}]} = Chats.locks(chat)
      assert guest_id == guest.user.id

      # A character the caller names but does not hold falls back to their own; the owner's draft
      # survives a guest's send.
      {:ok, _draft} = Messages.upsert_draft(owner, chat, "half a thought")
      assert {:ok, said} = Messages.send_message(guest, chat, a, "hello")
      assert said.author_character_id == b and said.author_user_id == guest.user.id
      assert Messages.get_draft(chat)
      assert Messages.upsert_draft(guest, chat, "mine now") == {:error, :unauthorized}
      assert DraftBuffer.put(guest, chat, "mine now") == {:error, :unauthorized}
      assert_raise Mythweaver.UnauthorizedError, fn -> Messages.draft_content(guest, chat) end

      # The owner without a lock posts as the character named (the player), clearing the draft.
      assert {:ok, %{author_character_id: ^a}} = Messages.send_message(owner, chat, a, "welcome")
      refute Messages.get_draft(chat)
    end

    test "free switching shares a character and releases one at a time", ctx do
      %{owner: owner, chat: chat, guest: guest, a: a, b: b} = ctx
      chat = free_switching!(owner, chat)
      other = member!(owner, chat, :guest)

      assert Chats.lock(guest, chat, b) == :ok
      assert Chats.lock(other, chat, b) == :ok
      assert Chats.lock(scope!(), chat, a) == {:error, :not_allowed}

      assert chat |> Chats.locks() |> Map.fetch!(b) |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.sort([guest.user.id, other.user.id])

      assert Chats.lock(guest, chat, a) == :ok
      assert Chats.lock(guest, chat, a) == :ok
      assert Chats.locks_of(guest, chat) == [a, b]

      assert Chats.unlock(guest, chat, b) == :ok
      assert Chats.locks_of(guest, chat) == [a]
      assert Chats.locks_of(other, chat) == [b]

      assert Chats.unlock(guest, chat, a) == :ok
      assert Chats.locks_of(guest, chat) == []
      assert Messages.send_message(guest, chat, a, "hi") == {:error, :no_character}
    end

    test "a user holds several characters and a character several users", ctx do
      %{owner: owner, chat: chat, guest: guest, a: a, b: b} = ctx
      editor = member!(owner, chat, :editor)

      assert Chats.assign_characters(editor, chat, guest.user.id, [b, a, b]) == {:ok, [a, b]}
      assert {:ok, [b]} = Chats.assign_characters(editor, chat, owner.user.id, [b])

      assert chat |> Chats.locks() |> Map.fetch!(b) |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.sort([guest.user.id, owner.user.id])

      assert {:ok, %{author_character_id: ^b}} = Messages.send_message(guest, chat, b, "as b")
      assert {:ok, %{author_character_id: ^a}} = Messages.send_message(guest, chat, nil, "first held")

      assert Chats.assign_characters(editor, chat, guest.user.id, [b]) == {:ok, [b]}
      assert Chats.locks_of(guest, chat) == [b]
      assert Chats.assign_characters(editor, chat, guest.user.id, []) == {:ok, []}
      assert Chats.locks_of(guest, chat) == []
      assert Chats.locks_of(owner, chat) == [b]

      outsider = character!(owner, "Outsider")
      assert Chats.assign_characters(editor, chat, guest.user.id, [outsider.id]) == {:error, :not_allowed}
      assert Chats.assign_characters(editor, chat, scope!().user.id, [a]) == {:error, :not_allowed}
      assert Chats.assign_characters(guest, chat, guest.user.id, [a]) == {:error, :unauthorized}
      assert Chats.update_membership_settings(guest, chat, %{free_switching: true}) == {:error, :unauthorized}
    end

    test "a guest brings their own character when the chat allows it", %{owner: owner, chat: chat, guest: guest} do
      wanderer = character!(guest, "Wanderer")
      assert Chats.bring_character(guest, chat, wanderer) == {:error, :not_allowed}

      {:ok, chat} = Chats.update_membership_settings(owner, chat, %{guests_bring_characters: true})
      assert Chats.bring_character(guest, chat, character!(owner, "Owner's")) == {:error, :not_found}
      assert Chats.bring_character(scope!(), chat, wanderer) == {:error, :not_allowed}

      guest_id = guest.user.id
      assert {:ok, %Participant{added_by_id: ^guest_id}} = Chats.bring_character(guest, chat, wanderer)
      assert Enum.any?(Chats.get_chat(chat.id).participants, &(&1.character_id == wanderer.id))
      assert {:error, %Ecto.Changeset{}} = Chats.bring_character(guest, chat, wanderer)
    end

    test "removing a participant drops its lock", %{owner: owner, chat: chat, guest: guest} do
      extra = character!(owner, "Extra")
      {:ok, _} = Chats.add_participants(owner, chat, [extra.id])
      {:ok, _} = Chats.assign_characters(owner, chat, guest.user.id, [extra.id])

      participant = Enum.find(Chats.get_chat(chat.id).participants, &(&1.character_id == extra.id))
      {:ok, _} = Chats.remove_participant(owner, participant)
      assert Chats.locks(chat) == %{}
    end
  end

  describe "leaving and removal" do
    test "leaving drops the membership, the lock and the guest's own characters", %{owner: owner, chat: chat} do
      guest = member!(owner, chat, :guest)
      brought = character!(guest, "Wanderer")

      Repo.insert!(%Participant{chat_id: chat.id, character_id: brought.id, added_by_id: guest.user.id, position: 9})
      Repo.insert!(%CharacterLock{chat_id: chat.id, character_id: brought.id, user_id: guest.user.id})
      {:ok, said} = Messages.send_message(guest, chat, brought.id, "Hello there")
      :ok = Chats.subscribe(guest)

      assert {:ok, _member} = Chats.leave(guest, chat)

      chat_id = chat.id
      assert_receive {:chat_deleted, ^chat_id}
      assert Chats.list_member_chats(guest) == []
      assert Chats.role(guest, chat) == nil
      refute Repo.get_by(CharacterLock, chat_id: chat.id)
      refute Enum.any?(Chats.get_chat(chat.id).participants, &(&1.character_id == brought.id))
      assert length(Chats.get_chat(chat.id).participants) == 2

      kept = Messages.get_message(owner, said.id)
      assert kept.author_name == "Wanderer"
      assert kept.author_character_id == nil
    end

    test "the owner cannot leave its own chat", %{owner: owner, chat: chat} do
      assert {:error, :not_found} = Chats.leave(owner, chat)
    end

    test "an editor removes guests, never another editor", %{owner: owner, chat: chat} do
      editor = member!(owner, chat, :editor)
      other_editor = member!(owner, chat, :editor)
      guest = member!(owner, chat, :guest)
      members = Map.new(Chats.list_members(owner, chat), &{&1.user_id, &1.id})

      assert {:error, :unauthorized} = Chats.remove_member(editor, members[other_editor.user.id])
      assert {:error, :unauthorized} = Chats.remove_member(guest, members[editor.user.id])
      assert {:ok, _} = Chats.remove_member(editor, members[guest.user.id])
      assert Chats.role(guest, chat) == nil
      assert {:ok, _} = Chats.remove_member(owner, members[other_editor.user.id])
      assert Chats.role(other_editor, chat) == nil
    end

    test "withdrawing a pending invite clears it from the inbox", %{owner: owner, chat: chat} do
      invitee = scope!(%{role: :user})
      {:ok, member} = Chats.invite(owner, chat, invitee.user.handle, :guest)

      assert {:ok, _} = Chats.remove_member(owner, member.id)
      assert Notifications.inbox(invitee) == []
    end
  end

  describe "per-person read state" do
    setup %{owner: owner, chat: chat} do
      guest = member!(owner, chat, :guest)
      {:ok, message} = Messages.send_message(owner, chat, chat.player_character_id, "Hi")
      %{guest: guest, character: character!(owner, "Replier"), body: Messages.Message.active_body(message)}
    end

    defp reply!(scope, ctx),
      do: :ok = Notifications.reply_finished(scope, :new_message, ctx.chat, ctx.character, ctx.body)

    test "owner and guest read independently", %{owner: owner, guest: guest, chat: chat} do
      assert Map.has_key?(Messages.unread_chats(owner), chat.id)
      assert Map.has_key?(Messages.unread_chats(guest), chat.id)

      :ok = Messages.mark_read(guest, chat)
      refute Map.has_key?(Messages.unread_chats(guest), chat.id)
      assert Map.has_key?(Messages.unread_chats(owner), chat.id)

      :ok = Messages.touch_activity(chat.id)
      :ok = Messages.mark_read(owner, chat)
      refute Map.has_key?(Messages.unread_chats(owner), chat.id)
      assert Map.has_key?(Messages.unread_chats(guest), chat.id)
    end

    test "a member's reply is stored by their own cursor, even after the owner read", ctx do
      :ok = Messages.mark_read(ctx.owner, ctx.chat)
      reply!(ctx.owner, ctx)
      reply!(ctx.guest, ctx)

      assert Notifications.inbox(ctx.owner) == []
      assert [%{chat_id: chat_id}] = Notifications.inbox(ctx.guest)
      assert chat_id == ctx.chat.id
    end

    test "a member reading clears only their own replies", ctx do
      reply!(ctx.owner, ctx)
      reply!(ctx.guest, ctx)

      :ok = Messages.mark_read(ctx.guest, ctx.chat)
      assert Notifications.inbox(ctx.guest) == []
      assert [_] = Notifications.inbox(ctx.owner)
    end
  end

  describe "an editor's settings" do
    setup %{owner: owner, chat: chat} do
      %{editor: member!(owner, chat, :editor)}
    end

    test "may not bind the owner's private lore book or prompt", %{owner: owner, chat: chat, editor: editor} do
      {:ok, book} = Mythweaver.Lore.create_book(owner, %{name: "Secret"})
      {:ok, prompt} = Mythweaver.Prompts.create_prompt(owner, %{name: "Secret"})

      assert Chats.update_settings(editor, chat, %{"lore_book_ids" => [book.id]}) == {:error, :unauthorized}
      assert Chats.update_settings(editor, chat, %{"prompt_id" => prompt.id}) == {:error, :unauthorized}

      assert {:ok, _} = Chats.update_settings(owner, chat, %{"lore_book_ids" => [book.id]})
    end

    test "may not add the owner's private character", %{owner: owner, chat: chat, editor: editor} do
      secret = character!(owner, "Secret")
      ids = Enum.map(chat.participants, & &1.character_id) ++ [secret.id]

      assert {:error, %Ecto.Changeset{} = cs} = Chats.update_settings(editor, chat, %{"participant_ids" => ids})
      assert errors_on(cs).participant_ids != []
    end

    test "keeps a private book already bound when saving other settings", %{
      owner: owner,
      chat: chat,
      editor: editor
    } do
      {:ok, book} = Mythweaver.Lore.create_book(owner, %{name: "Secret"})
      {:ok, _} = Chats.update_settings(owner, chat, %{"lore_book_ids" => [book.id]})
      chat = Chats.get_chat(chat.id)

      assert {:ok, renamed} = Chats.update_settings(editor, chat, %{"name" => "Renamed"})
      assert renamed.name == "Renamed"
      assert Mythweaver.Lore.chat_book_ids(renamed) == [book.id]
    end
  end

  describe "model source" do
    test "only the owner changes the chat's model", %{owner: owner, chat: chat} do
      editor = member!(owner, chat, :editor)
      model = model!(owner)

      assert {:error, cs} = Chats.update_settings(editor, chat, %{"ai_model_id" => model.id})
      assert errors_on(cs).ai_model_id == ["can only be changed by the chat's owner"]

      assert {:ok, updated} = Chats.update_settings(owner, chat, %{"ai_model_id" => model.id})
      assert updated.ai_model_id == model.id
    end

    test "an :own guest runs on their own model and spends their own", %{owner: owner, chat: chat} do
      guest = scope!(%{role: :user})
      {:ok, member} = Chats.invite(owner, chat, guest.user.handle, :guest, :own)
      {:ok, _} = Chats.accept_invite(guest, member.id)
      model = model!(guest)
      [character | _] = Enum.map(chat.participants, & &1.character)

      assert {:ok, %Member{model_source: :own}} = Chats.set_member_model(guest, chat, model.id)
      assert {:ok, chosen} = Generation.model_for(guest, chat, character)
      assert chosen.id == model.id
      assert AI.run_owner(guest, chat) == guest.user.id
      assert Chats.spend_scope(guest, chat).user.id == guest.user.id

      assert {:ok, %Member{model_source: :owner, ai_model_id: nil}} =
               Chats.set_model_source(owner, member.id, :owner)

      assert AI.run_owner(guest, chat) == owner.user.id
      assert Chats.spend_scope(guest, chat).user.id == owner.user.id
      assert Chats.set_member_model(guest, chat, model.id) == {:error, :unauthorized}
    end

    test "an :own guest's model pick is announced only on the guest's own topic", %{owner: owner, chat: chat} do
      guest = scope!(%{role: :user})
      {:ok, member} = Chats.invite(owner, chat, guest.user.handle, :guest, :own)
      {:ok, _} = Chats.accept_invite(guest, member.id)
      model = model!(guest)
      :ok = Chats.subscribe(owner)
      :ok = Chats.subscribe(guest)

      assert {:ok, %Member{ai_model_id: model_id}} = Chats.set_member_model(guest, chat, model.id)
      assert model_id == model.id

      chat_id = chat.id
      assert_receive {:chat_updated, ^chat_id}
      refute_receive {:chat_updated, ^chat_id}
    end

    test "spend_scope/3 reuses the run scope it is given", %{owner: owner, chat: chat} do
      guest = member!(owner, chat, :guest)
      run_scope = Chats.run_scope(guest, chat)

      assert Chats.spend_scope(guest, chat, run_scope) == run_scope
      assert Chats.spend_scope(owner, chat, Chats.run_scope(owner, chat)) == owner
    end

    test "only the owner sets a member's model source", %{owner: owner, chat: chat} do
      editor = member!(owner, chat, :editor)
      guest = scope!(%{role: :user})
      {:ok, member} = Chats.invite(editor, chat, guest.user.handle, :guest, :own)

      assert Repo.reload!(member).model_source == :owner
      assert Chats.set_model_source(editor, member.id, :own) == {:error, :unauthorized}
    end
  end

  describe "viewer/2" do
    test "is role/2 and member_for/2 at once", %{owner: owner, chat: chat} do
      editor = member!(owner, chat, :editor)
      stranger = scope!(%{role: :user})

      assert Chats.viewer(owner, chat) == {:owner, nil}
      assert Chats.member_for(owner, chat) == nil
      assert {:editor, %Member{role: :editor} = member} = Chats.viewer(editor, chat)
      assert member == Chats.member_for(editor, chat)
      assert Chats.viewer(stranger, chat) == {nil, nil}

      for scope <- [owner, editor, stranger],
          do: assert(elem(Chats.viewer(scope, chat), 0) == Chats.role(scope, chat))
    end
  end
end
