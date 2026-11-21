defmodule Mythweaver.SharingTest do
  use Mythweaver.DataCase

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Lore
  alias Mythweaver.Lore.BookCharacter
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Memory
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message
  alias Mythweaver.Notifications
  alias Mythweaver.Ownership
  alias Mythweaver.Permissions
  alias Mythweaver.Prompts
  alias Mythweaver.Scripts
  alias Mythweaver.Sharing
  alias Mythweaver.Sharing.Grant
  alias Mythweaver.Sharing.Share
  alias Mythweaver.Sharing.Visibility
  alias Mythweaver.Tags

  setup do
    %{owner: scope!(%{role: :user}), editor: scope!(%{role: :user})}
  end

  defp character!(scope, name \\ "Hero") do
    {:ok, character} = Characters.create_character(scope, %{name: name, description: "d"})
    character
  end

  defp handle(scope), do: "@" <> scope.user.handle

  defp shared!(owner, editor, item) do
    {:ok, share} = Sharing.invite(owner, item, handle(editor))
    {:ok, share} = Sharing.accept(editor, share.id)
    share
  end

  defp chat!(scope, characters) do
    {:ok, chat} =
      Chats.create_chat(scope, %{"participants" => Enum.map(characters, &%{"character_id" => &1.id})})

    chat
  end

  defp rescope(scope), do: Scope.for_user(Accounts.get_user(scope.user.id))

  describe "invite/3" do
    test "finds the invitee by handle in any case and puts the invite in their inbox", %{owner: owner, editor: editor} do
      character = character!(owner)

      assert {:ok, %Share{status: :pending} = share} =
               Sharing.invite(owner, character, "  @" <> String.upcase(editor.user.handle) <> " ")

      assert [%{kind: :share_invite, share_id: share_id} = item] = Notifications.inbox(editor)
      assert share_id == share.id
      assert Notifications.needs_action?(item)
    end

    test "refuses unknown handles, oneself, a second invite and non-owners", %{owner: owner, editor: editor} do
      character = character!(owner)

      assert {:error, :unknown_handle} = Sharing.invite(owner, character, "@nobody_has_this")
      assert {:error, :self} = Sharing.invite(owner, character, handle(owner))
      assert {:ok, _} = Sharing.invite(owner, character, handle(editor))
      assert {:error, :already_shared} = Sharing.invite(owner, character, handle(editor))
      assert {:error, :unauthorized} = Sharing.invite(editor, character, handle(owner))
    end

    test "needs sharing.invite and respects the pending invite limit", %{owner: owner, editor: editor} do
      character = character!(owner)
      third = scope!(%{role: :user})

      :ok = Permissions.put_grant!(owner.user, "quota.pending_invites", 1)
      limited = rescope(owner)
      assert {:ok, _} = Sharing.invite(limited, character, handle(editor))
      assert {:error, :quota_exceeded} = Sharing.invite(limited, character, handle(third))

      :ok = Permissions.put_grant!(owner.user, "sharing.invite", :deny)
      assert {:error, :unauthorized} = Sharing.invite(rescope(owner), character, handle(third))
    end
  end

  describe "accept/2" do
    test "makes the invitee an editor who cannot delete", %{owner: owner, editor: editor} do
      character = character!(owner)
      shared!(owner, editor, character)

      assert %{id: id} = Characters.get_editable_character(editor, character.id)
      assert id == character.id
      assert {:ok, _} = Characters.update_character(editor, character, %{description: "edited"})
      assert {:error, :unauthorized} = Characters.delete_character(editor, character)
      assert Notifications.inbox(editor) == []
    end

    test "lets the editor use what the item references, following later writes", %{owner: owner, editor: editor} do
      character = character!(owner)
      {:ok, book} = Lore.create_book(owner, %{name: "Lore"})
      {:ok, entry} = Lore.create_entry(owner, %{name: "Cave", content: "c", keywords: ["cave"]}, [book.id])
      {:ok, _} = Lore.bind_book_to_character(book, character.id)
      shared!(owner, editor, character)

      assert Lore.get_book(editor, book.id)
      assert Lore.get_entry(editor, entry.id)
      refute Lore.get_editable_book(editor, book.id)

      {:ok, later} = Lore.create_entry(owner, %{name: "Lake", content: "l", keywords: ["lake"]}, [book.id])
      assert Lore.get_entry(editor, later.id)

      refute Lore.get_book(scope!(%{role: :user}), book.id)
    end
  end

  test "decline/2 grants nothing and the owner may invite again", %{owner: owner, editor: editor} do
    character = character!(owner)
    {:ok, share} = Sharing.invite(owner, character, handle(editor))

    assert {:ok, %Share{status: :declined}} = Sharing.decline(editor, share.id)
    assert Repo.aggregate(from(g in Grant, where: g.user_id == ^editor.user.id), :count) == 0
    assert {:ok, %Share{id: id, status: :pending}} = Sharing.invite(owner, character, handle(editor))
    assert id == share.id
  end

  test "remove/2 takes the item out of the editor's chats and keeps their messages", %{owner: owner, editor: editor} do
    character = character!(owner)
    share = shared!(owner, editor, character)
    chat = chat!(editor, [character, character!(editor, "Mine"), character!(editor, "Also mine")])

    {:ok, message} =
      Messages.create_message(Chats.get_chat!(chat.id), %{
        author_is_character: true,
        author_character_id: character.id,
        bodies: [%{content: "Hello"}]
      })

    :ok = Tags.set_item_tags(editor, character, :mine, ["favourite"])

    assert {:ok, %{participants: 1, taggings: 1}} = Sharing.impact(owner, share.id)
    assert {:ok, _} = Sharing.remove(owner, share.id)

    assert length(Chats.get_chat!(chat.id).participants) == 2

    assert %Message{author_is_character: false, author_character_id: nil, author_name: "Hero"} =
             Repo.get(Message, message.id)

    refute Characters.get_character(editor, character.id)
    assert [%{kind: :share_ended}] = Notifications.inbox(editor)
  end

  describe "deleting a shared item" do
    test "ends its shares first, even while it sits in the subscriber's chat", %{owner: owner, editor: editor} do
      character = character!(owner)
      subscribe!(owner, editor, character, :runtime_only)
      chat = chat!(editor, [character, character!(editor, "A"), character!(editor, "B")])

      assert {:ok, %Characters.Character{}} = Characters.delete_character(owner, character)
      assert length(Chats.get_chat!(chat.id).participants) == 2
    end

    test "without editors is still refused while it sits in the owner's own chat", %{owner: owner, editor: editor} do
      character = character!(owner)
      share = subscribe!(owner, editor, character, :runtime_only)
      chat!(owner, [character, character!(owner, "Other")])

      assert {:error, :in_use} = Characters.delete_character(owner, character)
      assert Repo.get(Share, share.id)
    end

    test "deleting the owner's account succeeds while their character sits in the subscriber's chat",
         %{owner: owner, editor: editor} do
      character = character!(owner)
      subscribe!(owner, editor, character, :runtime_only)
      chat = chat!(editor, [character, character!(editor, "A"), character!(editor, "B")])

      assert {:ok, _} = Accounts.delete_user(scope!(), owner.user)
      assert length(Chats.get_chat!(chat.id).participants) == 2
    end
  end

  describe "hand-off" do
    test "deleting an item with two editors gives it to the oldest", %{owner: owner, editor: editor} do
      second = scope!(%{role: :user})
      character = character!(owner)
      {:ok, book} = Lore.create_book(owner, %{name: "Owner's lore"})
      {:ok, _} = Lore.bind_book_to_character(book, character.id)
      first_share = shared!(owner, editor, character)
      second_share = shared!(owner, second, character)
      later = DateTime.add(first_share.accepted_at, 60)
      Repo.update_all(from(s in Share, where: s.id == ^second_share.id), set: [accepted_at: later])
      chat = chat!(owner, [character, character!(owner, "Other")])

      assert Sharing.oldest_editor(character).id == editor.user.id
      assert {:ok, {:handed_off, recipient}} = Characters.delete_character(owner, character)
      assert recipient.id == editor.user.id

      assert Repo.reload!(character).user_id == editor.user.id
      refute Repo.get(Share, first_share.id)
      assert Repo.reload!(second_share).owner_id == editor.user.id
      assert Characters.get_editable_character(second, character.id)
      refute Characters.get_character(owner, character.id)

      assert [participant] = Chats.get_chat!(chat.id).participants
      refute participant.character_id == character.id
      refute Repo.exists?(from(bc in BookCharacter, where: bc.character_id == ^character.id))

      assert [%{kind: :handed_off, title: title}] = Notifications.inbox(editor)
      assert title =~ "You now own the character “Hero”"
    end

    test "the owner may pick the editor", %{owner: owner, editor: editor} do
      second = scope!(%{role: :user})
      {:ok, prompt} = Prompts.create_prompt(owner, %{name: "Shared prompt"})
      shared!(owner, editor, prompt)
      shared!(owner, second, prompt)

      assert {:ok, {:handed_off, recipient}} = Prompts.delete_prompt(owner, prompt, to: second.user.id)
      assert recipient.id == second.user.id
      assert Repo.reload!(prompt).user_id == second.user.id
    end

    test "a side prompt whose prompt the editor may not use refuses", %{owner: owner, editor: editor} do
      {:ok, prompt} = Prompts.create_prompt(owner, %{name: "Tracker prompt", purpose: :side_prompt})
      {:ok, side_prompt} = Memory.create_side_prompt(owner, %{name: "Tracker", prompt_id: prompt.id})
      shared!(owner, editor, side_prompt)

      assert {:error, {:needs_share, %{id: prompt_id}}} = Memory.delete_side_prompt(owner, side_prompt)
      assert prompt_id == prompt.id
      assert Repo.reload!(side_prompt).user_id == owner.user.id

      subscribe!(owner, editor, prompt, :runtime_only)
      assert {:ok, {:handed_off, _}} = Memory.delete_side_prompt(owner, side_prompt)
      assert Repo.reload!(side_prompt).user_id == editor.user.id
    end

    test "deleting the owner's account hands their shared items off", %{owner: owner, editor: editor} do
      {:ok, book} = Lore.create_book(owner, %{name: "Lore"})
      {:ok, entry} = Lore.create_entry(owner, %{name: "Cave", content: "c", keywords: ["cave"]}, [book.id])
      shared!(owner, editor, book)

      assert {:ok, _} = Accounts.delete_user(scope!(), owner.user)
      assert Repo.reload!(book).user_id == editor.user.id
      assert Repo.reload!(entry).user_id == editor.user.id
    end
  end

  describe "what runs on its own" do
    test "the owner's default memory profile does not become the editor's", %{owner: owner, editor: editor} do
      {:ok, profile} = Memory.create_profile(owner, %{name: "Mine"})
      {:ok, profile} = Memory.set_default_profile(owner, profile)
      shared!(owner, editor, profile)

      assert Memory.get_profile(editor, profile.id)
      refute Memory.default_profile(editor)
    end

    test "a shared enabled script runs in the editor's chats only once toggled on", %{owner: owner, editor: editor} do
      {:ok, script} =
        Scripts.create_script(owner, %{name: "Shout", trigger: :user_message, body: ~s(return "shouted")})

      {:ok, command} = Scripts.create_script(owner, %{name: "cmd", trigger: :command, body: ~s(return "c")})

      shared!(owner, editor, script)
      shared!(owner, editor, command)
      chat = chat!(editor, [character!(editor, "A"), character!(editor, "B")])
      run = fn -> Scripts.run(editor, :user_message, Chats.get_chat!(chat.id), %{"text" => "x"}) end

      assert Scripts.get_script!(editor, script.id)
      assert %{text: "x", errors: []} = run.()
      assert Scripts.list_commands(editor) == []

      assert {:ok, _} = Sharing.set_toggle(editor, script, true)
      assert {:ok, _} = Sharing.set_toggle(editor, command, true)

      assert %{text: "shouted"} = run.()
      assert [%{script: %{id: id}}] = Scripts.list_commands(editor)
      assert id == command.id

      assert :ok = Sharing.clear_toggle(editor, script)
      assert %{text: "x"} = run.()
    end

    test "a shared script that changed since it was enabled stops until enabled again", %{
      owner: owner,
      editor: editor
    } do
      {:ok, script} =
        Scripts.create_script(owner, %{name: "Shout", trigger: :user_message, body: ~s(return "shouted")})

      shared!(owner, editor, script)
      chat = chat!(editor, [character!(editor, "A"), character!(editor, "B")])
      run = fn -> Scripts.run(editor, :user_message, Chats.get_chat!(chat.id), %{"text" => "x"}) end

      assert {:ok, _} = Sharing.set_toggle(editor, script, true)
      assert %{text: "shouted"} = run.()
      card = Sharing.Items.card(editor, Repo.reload!(script))
      assert card.switches[script.id] == true
      refute card.consent_changed?

      # Non-ASCII, so the SQL and Elixir hashes must agree on the encoding too.
      assert {:ok, _} = Scripts.update_script(owner, script, %{body: ~s(return "changé")})
      assert %{text: "x"} = run.()

      card = Sharing.Items.card(editor, Repo.reload!(script))
      assert card.switches[script.id] == false
      assert card.consent_changed?

      assert {:ok, _} = Sharing.set_toggle(editor, Repo.reload!(script), true)
      assert %{text: "changé"} = run.()
    end
  end

  describe "toggles" do
    test "a toggle on one's own row is refused", %{owner: owner} do
      {:ok, script} = Scripts.create_script(owner, %{name: "Mine", trigger: :user_message, body: "return nil"})
      {:ok, block} = Prompts.create_block(owner, %{name: "Mine", content: "x"})

      assert {:error, :own} = Sharing.set_toggle(owner, script, false)
      assert {:error, :own} = Sharing.set_toggle(owner, block, false)
    end

    test "a row neither shared nor the site's is refused", %{owner: owner, editor: editor} do
      {:ok, block} = Prompts.create_block(owner, %{name: "Private", content: "x"})
      assert {:error, :unauthorized} = Sharing.set_toggle(editor, block, false)
    end

    test "an entry of a forced site book is refused" do
      admin = scope!()
      user = scope!(%{role: :user})
      {:ok, book} = Lore.create_book(admin, %{name: "Rules-#{System.unique_integer()}", forced: true}, site: true)
      {:ok, entry} = Lore.create_entry(admin, %{name: "Rule", content: "r", keywords: ["r"]}, [book.id])

      assert {:error, :forced} = Sharing.set_toggle(user, Repo.reload!(entry), false)
    end

    test "losing a share deletes the toggles of its rows", %{owner: owner, editor: editor} do
      {:ok, prompt} = Prompts.create_prompt(owner, %{name: "P"})
      {:ok, block} = Prompts.create_block(owner, %{name: "B", content: "x"})
      {:ok, _} = Prompts.add_block(owner, prompt, block)
      share = shared!(owner, editor, prompt)

      assert {:ok, _} = Sharing.set_toggle(editor, block, false)
      assert Sharing.toggles(editor.user.id, :block, [block.id]) == %{block.id => false}

      assert {:ok, impact} = Sharing.remove(owner, share.id)
      refute Map.has_key?(impact, :toggles)
      assert Sharing.toggles(editor.user.id, :block, [block.id]) == %{}
    end
  end

  test "a row may reference what is shared to its owner, nothing else of another user's", %{
    owner: owner,
    editor: editor
  } do
    {:ok, shared_block} = Prompts.create_block(editor, %{name: "Shared", content: "x"})
    {:ok, private_block} = Prompts.create_block(editor, %{name: "Private", content: "y"})
    shared!(editor, owner, shared_block)

    assert Ownership.reference_ok?(owner.user.id, shared_block)
    refute Ownership.reference_ok?(owner.user.id, private_block)
  end

  test "an editor's new block for a shared prompt is the prompt owner's, usable but not editable by the editor", %{
    owner: owner,
    editor: editor
  } do
    {:ok, prompt} = Prompts.create_prompt(owner, %{name: "Shared prompt"})
    shared!(owner, editor, prompt)

    assert {:ok, block} = Prompts.create_block(editor, %{name: "New", content: "x"}, for_prompt: prompt)
    assert block.user_id == owner.user.id
    assert {:ok, _} = Prompts.add_block(editor, prompt, block)

    assert [%{block_id: block_id}] = Prompts.get_prompt(owner, prompt.id).prompt_blocks
    assert block_id == block.id
    assert Prompts.get_block(editor, block.id)
    refute Prompts.get_editable_block(editor, block.id)
  end

  test "a block for a prompt the scope may not edit is refused", %{owner: owner, editor: editor} do
    {:ok, prompt} = Prompts.create_prompt(owner, %{name: "Private prompt"})

    assert {:error, :unauthorized} = Prompts.create_block(editor, %{name: "New", content: "x"}, for_prompt: prompt)
  end

  test "rebuilding a share keeps unchanged grants and only adds what is new", %{owner: owner, editor: editor} do
    {:ok, prompt} = Prompts.create_prompt(owner, %{name: "Shared prompt"})
    {:ok, first} = Prompts.create_block(owner, %{name: "First", content: "x"})
    {:ok, _} = Prompts.add_block(owner, prompt, first)
    share = shared!(owner, editor, prompt)
    grants = fn -> Repo.all(from(g in Grant, where: g.share_id == ^share.id)) |> Map.new(&{&1.item_id, &1.id}) end
    before = grants.()

    assert :ok = Sharing.Closure.rebuild(Repo.reload!(share))
    assert grants.() == before

    {:ok, second} = Prompts.create_block(owner, %{name: "Second", content: "y"})
    {:ok, _} = Prompts.add_block(owner, prompt, second)
    after_add = grants.()

    assert Map.take(after_add, Map.keys(before)) == before
    assert Map.has_key?(after_add, second.id)
  end

  describe "subscribers" do
    setup %{owner: owner, editor: editor} do
      character = character!(owner)
      shared!(owner, editor, character)
      %{character: character, third: scope!(%{role: :user})}
    end

    defp subscribe!(inviter, scope, item, visibility) do
      {:ok, share} = Sharing.invite(inviter, item, handle(scope), role: :subscriber, visibility: visibility)
      {:ok, share} = Sharing.accept(scope, share.id)
      share
    end

    test "the owner invites a Readable subscriber; an editor only a Runtime-only one", ctx do
      %{owner: owner, editor: editor, character: character, third: third} = ctx

      assert {:error, :unauthorized} =
               Sharing.invite(editor, character, handle(third), role: :subscriber, visibility: :readable)

      assert {:error, :unauthorized} = Sharing.invite(editor, character, handle(third), role: :editor)

      assert {:ok, %Share{role: :subscriber, visibility: :runtime_only, invited_by_id: invited_by}} =
               Sharing.invite(editor, character, handle(third), role: :subscriber)

      assert invited_by == editor.user.id
      assert [%{title: title}] = Notifications.inbox(third)
      assert title =~ "invited you to use"

      fourth = scope!(%{role: :user})

      assert {:ok, %Share{visibility: :readable}} =
               Sharing.invite(owner, character, handle(fourth), role: :subscriber, visibility: :readable)

      assert [%{title: readable_title}] = Notifications.inbox(fourth)
      assert readable_title =~ "(read-only)"
    end

    test "a subscriber uses but never edits the item", %{owner: owner, character: character, third: third} do
      subscribe!(owner, third, character, :runtime_only)

      assert Characters.get_character(third, character.id)
      refute Characters.get_editable_character(third, character.id)

      assert Repo.all(from(g in Grant, where: g.user_id == ^third.user.id, select: g.access))
             |> Enum.all?(&(&1 == :use))
    end

    test "only the owner changes a subscriber share's visibility", ctx do
      %{owner: owner, editor: editor, character: character, third: third} = ctx
      share = subscribe!(owner, third, character, :runtime_only)

      assert {:error, :unauthorized} = Sharing.set_visibility(editor, share.id, :readable)
      assert {:error, :unauthorized} = Sharing.set_visibility(third, share.id, :readable)
      refute Sharing.readable?(third.user.id, character)

      assert {:ok, %Share{visibility: :readable}} = Sharing.set_visibility(owner, share.id, :readable)
      assert Sharing.readable?(third.user.id, character)
    end

    test "an editor removes a subscriber but not another editor", ctx do
      %{owner: owner, editor: editor, character: character, third: third} = ctx
      sub = subscribe!(editor, third, character, :runtime_only)
      other_editor = scope!(%{role: :user})
      editor_share = shared!(owner, other_editor, character)

      assert {:error, :not_found} = Sharing.remove(editor, editor_share.id)
      assert {:ok, _} = Sharing.remove(editor, sub.id)
      refute Characters.get_character(third, character.id)
    end

    test "leave/2 ends the share like remove and tells only the leaver", ctx do
      %{owner: owner, editor: editor, character: character, third: third} = ctx
      share = subscribe!(owner, third, character, :runtime_only)
      owner_inbox = Notifications.inbox(owner)

      assert {:error, :not_found} = Sharing.leave(editor, share.id)
      assert {:ok, _} = Sharing.leave(third, share.id)
      refute Characters.get_character(third, character.id)
      refute Repo.get(Share, share.id)
      assert Repo.aggregate(from(g in Grant, where: g.user_id == ^third.user.id), :count) == 0
      assert [%{kind: :share_ended, body: "You left it."}] = Notifications.inbox(third)
      assert Notifications.inbox(owner) == owner_inbox
    end

    test "a Runtime-only subscriber never reads protected content, even with site.hidden.view", ctx do
      %{owner: owner, editor: editor, character: character, third: third} = ctx
      subscribe!(owner, third, character, :runtime_only)
      viewer = %{third | permissions: Map.put(third.permissions, "site.hidden.view", true)}

      assert Visibility.content_hidden_for?(third, character)
      assert Visibility.content_hidden_for?(viewer, character)
      assert Visibility.share_protected?(character, third.user.id)
      refute Visibility.content_hidden_for?(owner, character)
      refute Visibility.content_hidden_for?(editor, character)

      reader = scope!(%{role: :user})
      subscribe!(owner, reader, character, :readable)
      refute Visibility.content_hidden_for?(reader, character)
      refute Visibility.protected_for?(character, reader.user.id)
    end

    test "a Runtime-only subscriber's lore entries are not readable", %{owner: owner, third: third} do
      {:ok, book} = Lore.create_book(owner, %{name: "B"})
      {:ok, entry} = Lore.create_entry(owner, %{name: "E", content: "secret", keywords: ["e"]}, [book.id])
      subscribe!(owner, third, book, :runtime_only)
      entry = Repo.get!(LoreEntry, entry.id)

      assert Visibility.entry_content_hidden_for?(third, entry)
      assert [] == LoreEntry |> Visibility.readable_entries(third) |> where(id: ^entry.id) |> Repo.all()
      refute Visibility.entry_content_hidden_for?(owner, entry)
    end
  end
end
