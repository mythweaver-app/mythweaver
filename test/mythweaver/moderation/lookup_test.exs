defmodule Mythweaver.Moderation.LookupTest do
  use Mythweaver.DataCase

  alias Mythweaver.Characters
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats
  alias Mythweaver.Lore
  alias Mythweaver.Messages
  alias Mythweaver.Moderation.LogEntry
  alias Mythweaver.Moderation.Lookup
  alias Mythweaver.Moderation.Report
  alias Mythweaver.Moderation.Reports
  alias Mythweaver.Sharing
  alias Mythweaver.Sharing.Share

  defp character!(scope, name \\ "Hero", opts \\ []) do
    {:ok, character} = Characters.create_character(scope, %{name: name}, opts)
    character
  end

  defp chat!(owner) do
    [a, b] = [character!(owner, "Ann"), character!(owner, "Bea")]

    {:ok, chat} =
      Chats.create_chat(owner, %{
        name: "Tavern",
        player_character_id: a.id,
        participants: [%{character_id: a.id}, %{character_id: b.id}]
      })

    chat
  end

  describe "resolve/2" do
    test "an @handle and an email in any case name the account" do
      user = scope!(%{role: :user}).user

      assert Lookup.resolve(scope!(), "  @" <> user.handle) == {:ok, {:user, user.id}}
      assert Lookup.resolve(scope!(), String.upcase(user.email)) == {:ok, {:user, user.id}}
    end

    test "a bare id names whichever row has it, and an unknown one nothing" do
      chat = chat!(scope!(%{role: :user}))

      assert Lookup.resolve(scope!(), chat.id) == {:ok, {:chat, chat.id}}
      assert Lookup.resolve(scope!(), Mythweaver.Schema.generate_id()) == {:error, :not_found}
    end

    test "a link to an editor or a chat page names its row" do
      owner = scope!(%{role: :user})
      {:ok, book} = Lore.create_book(owner, %{name: "Lore"})
      {:ok, entry} = Lore.create_entry(owner, %{name: "Cave", content: "dark", keywords: ["cave"]}, [book.id])
      chat = chat!(owner)

      assert Lookup.resolve(scope!(), "https://example.com/lore/#{book.id}/entries/#{entry.id}/edit") ==
               {:ok, {:lore_entry, entry.id}}

      assert Lookup.resolve(scope!(), "/chats/#{chat.id}/settings") == {:ok, {:chat, chat.id}}
    end

    test "needs one of the record keys" do
      user = scope!(%{role: :user})
      assert Lookup.resolve(user, "@" <> user.user.handle) == {:error, :unauthorized}
    end
  end

  test "fetch/4 writes one :viewed entry" do
    moderator = scope!()
    owner = scope!(%{role: :user})
    chat = chat!(owner)

    assert {:ok, %{type: :chat, chat: %{id: chat_id}}} = Lookup.fetch(moderator, :chat, chat.id)
    assert chat_id == chat.id

    assert [%LogEntry{action: :viewed, subject_type: :chat, subject_id: subject_id} = entry] = Repo.all(LogEntry)
    assert subject_id == chat.id
    assert entry.actor_id == moderator.user.id
    assert entry.target_user_id == owner.user.id
  end

  describe "delete/3" do
    test "a shared character goes for everyone instead of passing to its editor" do
      owner = scope!(%{role: :user})
      editor = scope!(%{role: :user})
      character = character!(owner)
      {:ok, share} = Sharing.invite(owner, character, "@" <> editor.user.handle)
      {:ok, share} = Sharing.accept(editor, share.id)

      assert {:ok, :deleted} = Lookup.delete(scope!(), :character, character.id)

      refute Repo.get(Character, character.id)
      refute Repo.get(Share, share.id)
    end

    test "leaves site rows to the site's editors" do
      site = character!(scope!(), "Site hero", site: true)

      assert {:error, :site_row} = Lookup.delete(scope!(), :character, site.id)
      assert Repo.get(Character, site.id)
    end

    test "needs moderation.content.delete" do
      character = character!(scope!(%{role: :user}))
      moderator = scope!()
      denied = %{moderator | permissions: Map.put(moderator.permissions, "moderation.content.delete", false)}

      assert {:error, :unauthorized} = Lookup.delete(denied, :character, character.id)
      assert Repo.get(Character, character.id)
    end
  end

  describe "owners' rows and permissions" do
    test "a non-owner moderator neither views nor deletes an owner's chat, and nothing is logged" do
      chat = chat!(scope!(%{role: :owner}))

      assert Lookup.fetch(scope!(), :chat, chat.id) == {:error, :unauthorized}
      assert Lookup.delete(scope!(), :chat, chat.id) == {:error, :unauthorized}
      assert Repo.all(LogEntry) == []
      assert Chats.get_chat(chat.id)
    end

    test "fetch/4 needs moderation.content.view" do
      chat = chat!(scope!(%{role: :user}))
      moderator = scope!()
      denied = %{moderator | permissions: Map.put(moderator.permissions, "moderation.content.view", false)}

      assert Lookup.fetch(denied, :chat, chat.id) == {:error, :unauthorized}
    end
  end

  describe "delete/3 and reports" do
    setup do
      owner = scope!(%{role: :user})
      chat = chat!(owner)
      guest = scope!(%{role: :user})
      {:ok, member} = Chats.invite(owner, chat, guest.user.handle, :guest)
      {:ok, _} = Chats.accept_invite(guest, member.id)
      chat = Chats.get_chat(chat.id)
      [a | _] = Enum.map(chat.participants, & &1.character_id)
      {:ok, message} = Messages.send_message(owner, chat, a, "rude words")
      {:ok, report} = Reports.report(guest, :message, message.id, "rude")
      %{chat: chat, message: message, report: report}
    end

    test "deleting a chat actions its messages' open reports", %{chat: chat, report: report} do
      assert {:ok, :deleted} = Lookup.delete(scope!(), :chat, chat.id)
      assert Repo.get!(Report, report.id).status == :actioned
    end

    test "deleting a message actions its open report and logs the delete", %{message: message, report: report} do
      assert {:ok, :deleted} = Lookup.delete(scope!(), :message, message.id)
      assert Repo.get!(Report, report.id).status == :actioned
      assert [%LogEntry{action: :deleted, subject_type: :message}] = Repo.all(LogEntry)
    end
  end

  test "a character in its owner's chat is not deleted and keeps its shares" do
    owner = scope!(%{role: :user})
    chat = chat!(owner)
    [character_id | _] = Enum.map(Chats.get_chat(chat.id).participants, & &1.character_id)
    character = Repo.get!(Character, character_id)
    editor = scope!(%{role: :user})
    {:ok, share} = Sharing.invite(owner, character, "@" <> editor.user.handle)
    {:ok, share} = Sharing.accept(editor, share.id)

    assert Lookup.delete(scope!(), :character, character.id) == {:error, :in_use}
    assert Repo.get(Share, share.id)
    assert Repo.get(Character, character.id)
  end
end
