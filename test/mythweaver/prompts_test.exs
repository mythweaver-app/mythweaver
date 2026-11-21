defmodule Mythweaver.PromptsTest do
  use Mythweaver.DataCase

  alias Mythweaver.AI
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Prompts
  alias Mythweaver.Prompts.Binding

  setup do
    %{scope: scope!()}
  end

  describe "block kinds" do
    test "a template block needs content; a chat-history block drops it", %{scope: scope} do
      assert {:error, changeset} = Prompts.create_block(scope, %{name: "Empty"})
      assert "can't be blank" in errors_on(changeset).content

      assert {:ok, block} = Prompts.create_block(scope, %{name: "History", kind: :chat_history, content: "x"})
      assert block.kind == :chat_history
      assert block.content == nil
    end

    test "content that does not parse as a template is rejected", %{scope: scope} do
      assert {:error, changeset} = Prompts.create_block(scope, %{name: "Broken", content: "{% if %}"})
      assert [message] = errors_on(changeset).content
      assert message =~ "has invalid template syntax: line 1"
    end
  end

  describe "duplicate_prompt/1" do
    test "increments a trailing number and brings the blocks along", %{scope: scope} do
      source = prompt(scope, "Scene 3")
      for name <- ~w(A B), do: {:ok, _} = Prompts.add_block(scope, source, block(scope, name))

      assert {:ok, copy} = Prompts.duplicate_prompt(scope, source)
      assert copy.name == "Scene 4"
      assert positions(copy) == [{0, "A"}, {1, "B"}]
    end

    test "appends a 2 when there is no trailing number", %{scope: scope} do
      assert {:ok, copy} = Prompts.duplicate_prompt(scope, prompt(scope, "Narrator"))
      assert copy.name == "Narrator 2"
    end

    test "skips a candidate name that is already taken", %{scope: scope} do
      source = prompt(scope, "Scene 3")
      prompt(scope, "Scene 4")

      assert {:ok, copy} = Prompts.duplicate_prompt(scope, source)
      assert copy.name == "Scene 5"
    end

    test "does not copy bindings", %{scope: scope} do
      source = prompt(scope, "Bound 1")
      {:ok, _} = Prompts.bind_prompt(scope, source, :global)

      assert {:ok, copy} = Prompts.duplicate_prompt(scope, source)
      assert Prompts.list_bindings(scope, copy) == []
    end
  end

  describe "reorder_blocks/2" do
    test "rewrites positions densely from the given order", %{scope: scope} do
      prompt = prompt(scope, "Ordered")
      [a, b, c] = Enum.map(~w(A B C), &block(scope, &1))
      for blk <- [a, b, c], do: {:ok, _} = Prompts.add_block(scope, prompt, blk)

      assert {:ok, _} = Prompts.reorder_blocks(scope, prompt, [c.id, a.id, b.id])

      assert positions(prompt) == [{0, "C"}, {1, "A"}, {2, "B"}]
    end

    test "refuses a list that is not a permutation of the prompt's blocks", %{scope: scope} do
      prompt = prompt(scope, "Ordered")
      a = block(scope, "A")
      b = block(scope, "B")
      {:ok, _} = Prompts.add_block(scope, prompt, a)
      {:ok, _} = Prompts.add_block(scope, prompt, b)

      assert Prompts.reorder_blocks(scope, prompt, [a.id]) == {:error, :not_a_permutation}
      assert Prompts.reorder_blocks(scope, prompt, [a.id, a.id]) == {:error, :not_a_permutation}
      assert positions(prompt) == [{0, "A"}, {1, "B"}]
    end
  end

  describe "remove_block/1" do
    test "closes the gap it leaves behind", %{scope: scope} do
      prompt = prompt(scope, "Ordered")
      [a, b, c] = Enum.map(~w(A B C), &block(scope, &1))
      for blk <- [a, b, c], do: {:ok, _} = Prompts.add_block(scope, prompt, blk)

      middle = Enum.find(Prompts.list_prompt_blocks(prompt), &(&1.block_id == b.id))
      assert {:ok, _} = Prompts.remove_block(scope, middle)

      assert positions(prompt) == [{0, "A"}, {1, "C"}]
    end
  end

  describe "resolve_prompt/1" do
    # A plain user: chats are owned, so only that owner's prompts bind to them.
    setup do
      scope = scope!(%{role: :user})
      hero = character(scope, "Hero")
      foil = character(scope, "Foil")
      chat = chat(scope, [hero, foil])

      {:ok, provider} =
        AI.create_provider(scope, %{name: "conn-#{unique()}", base_url: "http://localhost:8080"})

      {:ok, model} = AI.create_model(scope, %{name: "model-#{unique()}", api_model_id: "m"})

      %{scope: scope, hero: hero, foil: foil, chat: chat, provider: provider, model: model}
    end

    # Without a chat a build names its owner (`:owner_id`); otherwise only site prompts apply.
    test "connection beats global", %{provider: provider, scope: scope} do
      bind(scope, "global one", :global)
      specific = bind(scope, "connection one", :connection, provider_id: provider.id)

      assert Prompts.resolve_prompt(%{owner_id: scope.user.id, provider: provider}).id == specific.id
    end

    test "model beats connection", %{provider: provider, model: model, scope: scope} do
      bind(scope, "connection one", :connection, provider_id: provider.id)
      specific = bind(scope, "model one", :model, ai_model_id: model.id)

      assert Prompts.resolve_prompt(%{owner_id: scope.user.id, provider: provider, model: model}).id == specific.id
    end

    test "character beats model", %{model: model, foil: foil, scope: scope} do
      bind(scope, "model one", :model, ai_model_id: model.id)
      specific = bind(scope, "character one", :character, character_id: foil.id)

      assert Prompts.resolve_prompt(%{owner_id: scope.user.id, model: model, character: foil}).id == specific.id
    end

    test "chat beats character", %{chat: chat, foil: foil, scope: scope} do
      bind(scope, "character one", :character, character_id: foil.id)
      specific = bind(scope, "chat one", :chat, chat_id: chat.id)

      assert Prompts.resolve_prompt(%{chat: chat, character: foil}).id == specific.id
    end

    test "character in chat beats chat", %{chat: chat, foil: foil, scope: scope} do
      bind(scope, "chat one", :chat, chat_id: chat.id)
      specific = bind(scope, "cic one", :character_in_chat, character_id: foil.id, chat_id: chat.id)

      assert Prompts.resolve_prompt(%{chat: chat, character: foil}).id == specific.id
    end

    test "a scope matching nothing resolves to nil", %{chat: chat, foil: foil} do
      assert Prompts.resolve_prompt(%{chat: chat, character: foil}) == nil
    end

    test "a disabled prompt is never resolved, however specific its binding", %{
      chat: chat,
      foil: foil,
      scope: scope
    } do
      fallback = bind(scope, "global one", :global)

      disabled = prompt(scope, "disabled one", %{enabled: false})
      {:ok, _} = Prompts.bind_prompt(scope, disabled, :character_in_chat, character_id: foil.id, chat_id: chat.id)

      assert Prompts.resolve_prompt(%{chat: chat, character: foil}).id == fallback.id
    end

    test "a tie within one specificity level resolves to the alphabetically first, repeatably",
         %{chat: chat, scope: scope} do
      first = bind(scope, "aaa chat", :chat, chat_id: chat.id)
      bind(scope, "zzz chat", :chat, chat_id: chat.id)

      for _ <- 1..5 do
        assert Prompts.resolve_prompt(%{chat: chat}).id == first.id
      end
    end

    test "the winning prompt arrives with its blocks in position order", %{chat: chat, scope: scope} do
      winner = bind(scope, "chat one", :chat, chat_id: chat.id)
      [a, b] = Enum.map(~w(A B), &block(scope, &1))
      {:ok, _} = Prompts.add_block(scope, winner, b)
      {:ok, _} = Prompts.add_block(scope, winner, a)

      resolved = Prompts.resolve_prompt(%{chat: chat})

      assert Enum.map(resolved.prompt_blocks, & &1.block.name) == ["B", "A"]
    end

    test "a malformed target degrades to no match instead of raising", %{chat: chat, scope: scope} do
      winner = bind(scope, "global one", :global)

      # A caller hands `resolve_prompt/1` whatever it has; an unusable target must behave like an absent
      # one, so one bad key cannot take resolution down.
      assert Prompts.resolve_prompt(%{owner_id: scope.user.id, character: %{no_id: true}}).id == winner.id
      assert Prompts.resolve_prompt(%{chat: chat, character: 42}).id == winner.id
      assert Prompts.resolve_prompt(%{owner_id: scope.user.id, provider: :not_a_provider}).id == winner.id
    end

    test "a prompt whose purpose is not roleplay is never resolved, however specific its binding", %{
      chat: chat,
      foil: foil,
      scope: scope
    } do
      fallback = bind(scope, "global one", :global)
      memory = bind(scope, "cic one", :character_in_chat, character_id: foil.id, chat_id: chat.id)
      {:ok, _} = Prompts.update_prompt(scope, memory, %{purpose: :memory})

      assert Prompts.resolve_prompt(%{chat: chat, character: foil}).id == fallback.id
    end
  end

  describe "set_chat_prompt/2" do
    setup do
      %{scope: scope!(%{role: :user})}
    end

    test "collapses the chat's :chat bindings to the one chosen", %{scope: scope} do
      chat = chat(scope, [character(scope, "A"), character(scope, "B")])
      p1 = bind(scope, "First", :chat, chat_id: chat.id)
      p2 = bind(scope, "Second", :chat, chat_id: chat.id)
      assert Prompts.chat_prompt_id(chat) == p1.id

      assert {:ok, :ok} = Prompts.set_chat_prompt(chat, p2.id)

      bindings =
        Mythweaver.Repo.all(from(b in Binding, where: b.scope == :chat and b.chat_id == ^chat.id))

      assert [%{prompt_id: id}] = bindings
      assert id == p2.id
    end

    test "refuses a prompt that is not roleplay and keeps the current binding", %{scope: scope} do
      chat = chat(scope, [character(scope, "A"), character(scope, "B")])
      current = bind(scope, "Current", :chat, chat_id: chat.id)
      memory = prompt(scope, "Memory", %{purpose: :memory})

      assert {:error, :not_roleplay} = Prompts.set_chat_prompt(chat, memory.id)
      assert Prompts.chat_prompt_id(chat) == current.id
    end
  end

  describe "prompt purpose" do
    test "bind_prompt/3 refuses a prompt that is not roleplay", %{scope: scope} do
      memory = prompt(scope, "Memory", %{purpose: :memory})

      assert {:error, :not_roleplay} = Prompts.bind_prompt(scope, memory, :global)
      assert Prompts.list_bindings(scope, memory) == []
    end

    test "list_prompts/1 filters by purpose; list_prompts/0 lists every purpose", %{scope: scope} do
      roleplay = prompt(scope, "Roleplay")
      memory = prompt(scope, "Memory", %{purpose: :memory})

      assert Enum.map(Prompts.list_prompts(scope, :roleplay), & &1.id) == [roleplay.id]
      assert Enum.map(Prompts.list_prompts(scope, :memory), & &1.id) == [memory.id]
      assert Enum.map(Prompts.list_prompts(scope), & &1.id) == [memory.id, roleplay.id]
    end
  end

  describe "outlet keys" do
    test "two outlets cannot share a key", %{scope: scope} do
      _first = outlet(scope, "ending")

      assert {:error, changeset} = Prompts.create_outlet(scope, %{key: "ending", name: "Ending again"})
      assert "has already been taken" in errors_on(changeset).key
    end

    test "a key with uppercase or spaces is rejected", %{scope: scope} do
      assert {:error, changeset} = Prompts.create_outlet(scope, %{key: "Ending", name: "Ending"})
      assert errors_on(changeset).key != []

      assert {:error, changeset} = Prompts.create_outlet(scope, %{key: "the ending", name: "Ending"})
      assert errors_on(changeset).key != []
    end
  end

  describe "ownership" do
    setup %{scope: admin} do
      %{admin: admin, user: scope!(%{role: :user}), other: scope!(%{role: :user})}
    end

    test "a user's rows are their own: listed and editable by them, invisible to others and admins",
         %{admin: admin, user: user, other: other} do
      own = prompt(user, "Mine")
      block = block(user, "My block")
      outlet = outlet(user, "mine")

      assert own.user_id == user.user.id
      assert Enum.map(Prompts.list_editable_prompts(user), & &1.id) == [own.id]
      assert {:ok, _} = Prompts.update_prompt(user, own, %{name: "Still mine"})

      for scope <- [admin, other] do
        assert Prompts.get_prompt(scope, own.id) == nil
        assert Prompts.get_block(scope, block.id) == nil
        assert Prompts.get_outlet(scope, outlet.id) == nil
        refute own.id in Enum.map(Prompts.list_prompts(scope), & &1.id)
        assert {:error, :unauthorized} = Prompts.update_prompt(scope, own, %{name: "Taken"})
        assert {:error, :unauthorized} = Prompts.delete_block(scope, block)
        assert {:error, :unauthorized} = Prompts.update_outlet(scope, outlet, %{name: "Taken"})
      end
    end

    test "a site row is usable by a user but not editable", %{admin: admin, user: user} do
      site = prompt(admin, "Site", %{}, site: true)
      site_block = block(admin, "Site block", %{}, site: true)

      assert site.user_id == nil
      assert Prompts.get_prompt(user, site.id).id == site.id
      assert Prompts.get_block(user, site_block.id).id == site_block.id
      refute site.id in Enum.map(Prompts.list_editable_prompts(user), & &1.id)
      assert {:error, :unauthorized} = Prompts.update_prompt(user, site, %{name: "Mine now"})
      assert {:error, :unauthorized} = Prompts.add_block(user, site, site_block)
      assert {:error, :unauthorized} = Prompts.bind_prompt(user, site, :global)
    end

    test "names are unique per owner, not site-wide", %{admin: admin, user: user, other: other} do
      prompt(admin, "Narrator", %{}, site: true)
      prompt(user, "Narrator")
      prompt(other, "Narrator")

      assert {:error, changeset} = Prompts.create_prompt(user, %{name: "Narrator"})
      assert "has already been taken" in errors_on(changeset).name
    end

    test "a prompt includes only site blocks or its owner's", %{admin: admin, user: user, other: other} do
      own = prompt(user, "Mine")

      assert {:ok, _} = Prompts.add_block(user, own, block(admin, "Site", %{}, site: true))
      assert {:ok, _} = Prompts.add_block(user, own, block(user, "Own"))
      assert {:error, :unauthorized} = Prompts.add_block(user, own, block(other, "Theirs"))
      # A site prompt takes no personal block, not even its editor's.
      assert {:error, :unauthorized} =
               Prompts.add_block(admin, prompt(admin, "Site", %{}, site: true), block(user, "Own 2"))
    end

    test "duplicating a site prompt gives the user their own copy with site blocks kept",
         %{admin: admin, user: user} do
      site = prompt(admin, "Act 3", %{}, site: true)
      {:ok, _} = Prompts.add_block(admin, site, block(admin, "Shared", %{}, site: true))

      assert {:ok, copy} = Prompts.duplicate_prompt(user, site)
      assert copy.user_id == user.user.id
      # Names are probed against the copy's owner, who has no "Act 4" yet.
      assert copy.name == "Act 4"
      assert Enum.map(copy.prompt_blocks, & &1.block.name) == ["Shared"]
    end

    test "duplicating keeps only the blocks the copy's owner may reference", %{admin: admin, user: user} do
      own = prompt(user, "Mine")
      {:ok, _} = Prompts.add_block(user, own, block(user, "Personal"))
      {:ok, _} = Prompts.add_block(user, own, block(admin, "Shared", %{}, site: true))

      # A site content manager without the create permission copying one of their own personal
      # prompts (e.g. kept from before the permission was revoked) gets a site prompt, which may hold
      # site blocks only.
      permissions = user.permissions |> Map.put("site.content.manage", true) |> Map.put("content.prompts.create", false)
      assert {:ok, copy} = Prompts.duplicate_prompt(%{user | permissions: permissions}, own)
      assert copy.user_id == nil
      assert Enum.map(copy.prompt_blocks, & &1.block.name) == ["Shared"]
    end

    test "a binding target must be usable by the prompt's owner", %{admin: admin, user: user, other: other} do
      other_chat = chat(other, [character(other, "A"), character(other, "B")])
      own_chat = chat(user, [character(user, "C"), character(user, "D")])
      own = prompt(user, "Mine")

      assert {:error, :unauthorized} = Prompts.bind_prompt(user, own, :chat, chat_id: other_chat.id)
      assert {:ok, _} = Prompts.bind_prompt(user, own, :chat, chat_id: own_chat.id)
      # A site prompt binds to site targets only; a chat is always someone's.
      assert {:error, :unauthorized} =
               Prompts.bind_prompt(admin, prompt(admin, "Site", %{}, site: true), :chat, chat_id: own_chat.id)
    end

    test "set_chat_prompt/2 refuses another user's prompt and accepts a site one",
         %{admin: admin, user: user, other: other} do
      chat = chat(user, [character(user, "A"), character(user, "B")])

      assert {:error, :unauthorized} = Prompts.set_chat_prompt(chat, prompt(other, "Theirs").id)
      assert Prompts.chat_prompt_id(chat) == nil

      site = prompt(admin, "Site", %{}, site: true)
      assert {:ok, :ok} = Prompts.set_chat_prompt(chat, site.id)
      assert Prompts.chat_prompt_id(chat) == site.id
    end

    test "resolve_prompt/1 ignores other users' prompts and prefers the owner's own on a tie",
         %{admin: admin, user: user, other: other} do
      chat = chat(user, [character(user, "A"), character(user, "B")])
      site = bind(admin, "aaa site", :global, [], site: true)
      bind(other, "aaa other", :global)

      assert Prompts.resolve_prompt(%{chat: chat}).id == site.id

      own = bind(user, "zzz own", :global)
      assert Prompts.resolve_prompt(%{chat: chat}).id == own.id
      assert Prompts.resolve_prompt(%{chat: chat.id}).id == own.id
      # Specificity still comes first: a more specific site binding beats the owner's global one.
      {:ok, model} = AI.create_model(admin, %{name: "model-#{unique()}", api_model_id: "m"}, site: true)
      specific = bind(admin, "zzz site model", :model, [ai_model_id: model.id], site: true)
      assert Prompts.resolve_prompt(%{chat: chat, model: model}).id == specific.id
      # No chat: site prompts only.
      assert Prompts.resolve_prompt(%{}).id == site.id
      assert Prompts.resolve_prompt(%{owner_id: other.user.id}).name == "aaa other"
    end

    test "an outlet key resolves to the owner's outlet before the site's", %{admin: admin, user: user, other: other} do
      site = outlet(admin, "ending", %{}, site: true)
      own = outlet(user, "ending")
      outlet(other, "ending")

      assert Prompts.get_outlet_by_key(user.user.id, "ending").id == own.id
      assert Prompts.get_outlet_by_key(nil, "ending").id == site.id
      assert Prompts.get_outlet_by_key(user.user.id, "missing") == nil
      assert [%{id: id}] = Prompts.list_outlets(user)
      assert id == own.id
      assert Enum.map(Prompts.list_outlets(admin), & &1.id) == [site.id]
    end
  end

  ## Helpers

  defp unique, do: System.unique_integer([:positive])

  defp positions(prompt) do
    prompt
    |> Prompts.list_prompt_blocks()
    |> Enum.map(&{&1.position, &1.block.name})
  end

  defp bind(scope, name, level, ids \\ [], opts \\ []) do
    prompt = prompt(scope, name, %{}, opts)
    {:ok, _} = Prompts.bind_prompt(scope, prompt, level, ids)
    prompt
  end

  defp prompt(scope, name, attrs \\ %{}, opts \\ []) do
    {:ok, prompt} = Prompts.create_prompt(scope, Map.merge(%{name: name}, attrs), opts)
    prompt
  end

  defp block(scope, name, attrs \\ %{}, opts \\ []) do
    {:ok, block} = Prompts.create_block(scope, Map.merge(%{name: name, content: "#{name} content"}, attrs), opts)
    block
  end

  defp outlet(scope, key, attrs \\ %{}, opts \\ []) do
    {:ok, outlet} =
      Prompts.create_outlet(scope, Map.merge(%{key: key, name: String.capitalize(key)}, attrs), opts)

    outlet
  end

  defp character(scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: "#{name}-#{unique()}"})
    character
  end

  defp chat(scope, [player | _] = characters) do
    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: "chat-#{unique()}",
        participants: Enum.map(characters, &%{character_id: &1.id}),
        player_character_id: player.id
      })

    Chats.get_chat!(chat.id)
  end
end
