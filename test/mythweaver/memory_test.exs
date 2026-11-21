defmodule Mythweaver.MemoryTest do
  use Mythweaver.DataCase

  alias Mythweaver.AI
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Jobs
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Lore
  alias Mythweaver.Memory
  alias Mythweaver.Memory.Record
  alias Mythweaver.Memory.SidePrompts
  alias Mythweaver.Memory.Workers
  alias Mythweaver.Messages
  alias Mythweaver.Prompts

  setup do
    %{scope: scope!()}
  end

  describe "profile_for/1" do
    test "prefers the chat's profile, then the default, then errors", %{scope: scope} do
      chat = chat!(scope)
      assert Memory.profile_for(scope, chat) == {:error, :no_profile}

      default = profile!(scope, "Default")
      {:ok, default} = Memory.set_default_profile(scope, default)
      assert Memory.profile_for(scope, chat) == {:ok, default}

      chosen = profile!(scope, "Chosen")
      {:ok, _} = Memory.update_chat_settings(scope, Memory.chat_settings(scope, chat), %{profile_id: chosen.id})
      assert Memory.profile_for(scope, chat) == {:ok, chosen}

      {:ok, _} = Memory.delete_profile(scope, chosen)
      assert Memory.profile_for(scope, chat) == {:ok, default}
    end
  end

  describe "set_default_profile/1" do
    test "leaves exactly one default", %{scope: scope} do
      first = profile!(scope, "First")
      second = profile!(scope, "Second")

      {:ok, _} = Memory.set_default_profile(scope, first)
      {:ok, _} = Memory.set_default_profile(scope, second)

      assert [%{id: id}] = Enum.filter(Memory.list_profiles(scope), & &1.default)
      assert id == second.id
    end
  end

  describe "prompt purposes" do
    test "a profile rejects a prompt of another purpose", %{scope: scope} do
      roleplay = prompt!(scope, "Roleplay", :roleplay)

      assert {:error, changeset} = Memory.create_profile(scope, %{name: "Bad", memory_prompt_id: roleplay.id})
      assert "must be a memory prompt" in errors_on(changeset).memory_prompt_id

      memory = prompt!(scope, "Summary", :memory)
      assert {:ok, _} = Memory.create_profile(scope, %{name: "Good", memory_prompt_id: memory.id})
    end

    test "a side prompt needs a side-prompt prompt", %{scope: scope} do
      roleplay = prompt!(scope, "Roleplay", :roleplay)

      assert {:error, changeset} = Memory.create_side_prompt(scope, %{name: "Tracker", prompt_id: roleplay.id})
      assert "must be a side prompt" in errors_on(changeset).prompt_id
    end
  end

  describe "counts/1" do
    test "counts the records of the chat's memory book per tier", %{scope: scope} do
      chat = chat!(scope)
      assert Memory.counts(chat)["tier0"] == 0

      {:ok, book} = Lore.create_book(scope, %{name: "Memories"})
      {:ok, other_book} = Lore.create_book(scope, %{name: "Elsewhere"})
      {:ok, _} = Memory.update_chat_settings(scope, Memory.chat_settings(scope, chat), %{memory_book_id: book.id})

      for _ <- 1..3, do: record!(scope, book, chat, :memory, 0)
      for _ <- 1..2, do: record!(scope, book, chat, :consolidation, 1)
      record!(scope, book, chat, :consolidation, 6)
      record!(scope, book, chat, :clip, nil)
      record!(scope, book, chat, :topical_clip, nil)
      record!(scope, book, chat, :side_prompt, nil)
      record!(scope, other_book, chat, :memory, 0)

      assert Memory.counts(chat) == %{
               "tier0" => 3,
               "tier1" => 2,
               "tier2" => 0,
               "tier3" => 0,
               "tier4" => 0,
               "tier5" => 0,
               "tier6" => 1,
               "clips" => 2,
               "side_prompts" => 1
             }
    end
  end

  describe "create_memory/5 attribution" do
    test "the job belongs to its initiator, and the worker refuses it once they are gone", %{scope: scope} do
      chat = Chats.get_chat!(chat!(scope).id)
      for text <- ~w(Hello Again), do: {:ok, _} = Messages.send_message(scope, chat, chat.player_character_id, text)

      # No provider is linked, so the scheduler fails the job at submit instead of running it. A site
      # model: the job outlives its initiator, not the model.
      {:ok, model} = AI.create_model(scope, %{name: "Unlinked", api_model_id: "unlinked"}, site: true)
      prompt = prompt!(scope, "Summary", :memory)

      {:ok, profile} =
        Memory.create_profile(scope, %{name: "Default", ai_model_id: model.id, memory_prompt_id: prompt.id})

      {:ok, _} = Memory.set_default_profile(scope, profile)

      assert {:ok, job} = Memory.create_memory(scope, chat, 0, 1, confirm_tokens: true)
      assert job.user_id == scope.user.id

      Repo.delete!(scope.user)
      job = Repo.get!(Job, job.id)

      assert Workers.Scene.build(job) == {:error, :no_initiator}
      assert Jobs.error_message(:no_initiator) == "The user who started this job no longer exists."
    end

    test "a chat editor's job runs on the owner's model and stays the editor's", %{scope: admin} do
      owner = scope!(%{role: :user})
      chat = Chats.get_chat!(chat!(admin, owner).id)
      for text <- ~w(Hello Again), do: {:ok, _} = Messages.send_message(owner, chat, chat.player_character_id, text)

      # The owner's own private model, which the editor could not run as themselves.
      {:ok, model} = AI.create_model(owner, %{name: "Owner's", api_model_id: "owners"})
      prompt = prompt!(owner, "Summary", :memory)

      {:ok, profile} =
        Memory.create_profile(owner, %{name: "Owner's", ai_model_id: model.id, memory_prompt_id: prompt.id})

      {:ok, _} = Memory.set_default_profile(owner, profile)

      editor = scope!(%{role: :user})
      {:ok, member} = Chats.invite(owner, chat, editor.user.handle, :editor)
      {:ok, _} = Chats.accept_invite(editor, member.id)
      assert AI.get_model(editor, model.id) == nil

      assert {:ok, job} = Memory.create_memory(editor, chat, 0, 1, confirm_tokens: true)
      assert job.user_id == editor.user.id
      assert job.ai_model_id == model.id
      assert {:ok, _input, _prompt_name} = Workers.Scene.build(Repo.get!(Job, job.id))
    end
  end

  describe "a user's own memory book" do
    setup %{scope: scope} do
      user = scope!(%{role: :user})
      chat = chat!(scope, user)
      {:ok, global} = Lore.create_book(scope, %{name: "Global"}, site: true)
      %{user: user, chat: chat, global: global}
    end

    test "the chat's owner owns and writes it, but not a site book", %{user: user, chat: chat, global: global} do
      book = Memory.ensure_book(user, chat)

      assert book.user_id == user.user.id
      assert Memory.authorize_book(user, book.id) == :ok
      assert {:ok, entry} = Lore.create_entry(user, %{name: "m", content: "x", activation: :constant}, [book.id])
      assert entry.user_id == user.user.id
      assert {:error, :unauthorized} = Lore.create_entry(user, %{name: "g", content: "x"}, [global.id])
      assert Memory.authorize_book(user, global.id) == {:error, :unauthorized}
    end

    test "the chat's owner may pick only their own book, not a site book nor another user's",
         %{scope: admin, user: user, chat: chat, global: global} do
      other = scope!(%{role: :user})
      {:ok, theirs} = Lore.create_book(other, %{name: "Theirs"})
      {:ok, own} = Lore.create_book(user, %{name: "Own"})
      settings = Memory.chat_settings(user, chat)
      side_prompt_id = Ecto.UUID.generate()

      assert {:error, :unauthorized} = Memory.update_chat_settings(user, settings, %{memory_book_id: theirs.id})
      assert {:error, :unauthorized} = Memory.update_chat_settings(user, settings, %{memory_book_id: global.id})

      assert {:error, :unauthorized} =
               Memory.update_chat_settings(user, settings, %{side_prompt_book_ids: %{side_prompt_id => global.id}})

      assert {:ok, _} = Memory.update_chat_settings(user, settings, %{memory_book_id: own.id})
      assert Enum.map(Memory.list_memory_books(user), & &1.id) == [own.id]
      assert global.id in Enum.map(Memory.list_memory_books(admin), & &1.id)
    end

    test "a site book left in the settings is neither used nor listed", %{scope: admin, user: user, chat: chat} do
      {:ok, global} = Lore.create_book(admin, %{name: "Shared memories"}, site: true)
      admin_chat = chat!(admin)
      record!(admin, global, admin_chat, :memory, 0)

      user
      |> Memory.chat_settings(chat)
      |> Ecto.Changeset.change(memory_book_id: global.id)
      |> Repo.update!()

      assert Memory.list_records(user, global.id) == []
      assert Memory.counts(chat)["tier0"] == 0
      assert [_record] = Memory.list_records(admin, global.id)

      book = Memory.ensure_book(user, chat)
      assert book.id != global.id
      assert book.user_id == user.user.id
    end
  end

  describe "an admin's site memory book" do
    test "an admin may pick a site book and the chat keeps it", %{scope: admin} do
      chat = chat!(admin)
      {:ok, global} = Lore.create_book(admin, %{name: "Site memories"}, site: true)

      assert {:ok, _} =
               Memory.update_chat_settings(admin, Memory.chat_settings(admin, chat), %{memory_book_id: global.id})

      assert Memory.ensure_book(admin, chat).id == global.id
    end
  end

  describe "profile and side prompt ownership" do
    test "a user's own profile is theirs alone; site profiles are usable but not editable", %{scope: admin} do
      user = scope!(%{role: :user})
      other = scope!(%{role: :user})
      site = profile!(admin, "Site", site: true)
      {:ok, own} = Memory.create_profile(user, %{name: "Mine"})

      assert own.user_id == user.user.id
      assert Enum.map(Memory.list_profiles(user), & &1.id) == [own.id]
      assert Enum.map(Memory.list_usable_profiles(user), & &1.id) |> Enum.sort() == Enum.sort([own.id, site.id])
      assert Memory.get_profile(other, own.id) == nil
      assert Memory.get_profile(admin, own.id) == nil
      assert {:error, :unauthorized} = Memory.update_profile(admin, own, %{name: "Taken"})
      assert {:error, :unauthorized} = Memory.update_profile(user, site, %{name: "Taken"})
    end

    test "profiles reference only usable prompts", %{scope: admin} do
      user = scope!(%{role: :user})
      other = scope!(%{role: :user})
      {:ok, theirs} = Prompts.create_prompt(other, %{name: "Theirs", purpose: :memory})
      site = prompt!(admin, "Site", :memory, site: true)

      assert {:error, changeset} = Memory.create_profile(user, %{name: "Bad", memory_prompt_id: theirs.id})
      assert "is not available" in errors_on(changeset).memory_prompt_id
      assert {:ok, _} = Memory.create_profile(user, %{name: "Good", memory_prompt_id: site.id})
    end

    test "profiles refuse an embedding model", %{scope: admin} do
      user = scope!(%{role: :user})

      {:ok, embedder} =
        Mythweaver.AI.create_model(
          admin,
          %{name: "Embed#{System.unique_integer()}", api_model_id: "e", completion_mode: :embedding},
          site: true
        )

      assert {:error, changeset} = Memory.create_profile(user, %{name: "Bad", ai_model_id: embedder.id})
      assert "is not available" in errors_on(changeset).ai_model_id
    end

    test "profile_for prefers the owner's default over the site's, and ignores another user's", %{scope: admin} do
      user = scope!(%{role: :user})
      chat = chat!(admin, user)
      {:ok, site} = Memory.set_default_profile(admin, profile!(admin, "Site", site: true))

      assert Memory.profile_for(user, chat) == {:ok, site}

      {:ok, own} = Memory.set_default_profile(user, elem(Memory.create_profile(user, %{name: "Mine"}), 1))
      assert Memory.profile_for(user, chat) == {:ok, own}
      assert Memory.default_profile(admin).id == site.id

      other = scope!(%{role: :user})
      {:ok, theirs} = Memory.create_profile(other, %{name: "Theirs"})
      settings = Memory.chat_settings(user, chat)
      assert {:error, :unauthorized} = Memory.update_chat_settings(user, settings, %{profile_id: theirs.id})
    end

    test "side prompts in a chat are the site's and the chat owner's only", %{scope: admin} do
      user = scope!(%{role: :user})
      other = scope!(%{role: :user})
      chat = chat!(admin, user)
      site_prompt = prompt!(admin, "S", :side_prompt, site: true)
      {:ok, site} = Memory.create_side_prompt(admin, %{name: "Site", prompt_id: site_prompt.id}, site: true)
      {:ok, own} = Memory.create_side_prompt(user, %{name: "Own", prompt_id: prompt!(user, "O", :side_prompt).id})

      {:ok, theirs} =
        Memory.create_side_prompt(other, %{name: "Theirs", prompt_id: prompt!(other, "T", :side_prompt).id})

      assert Enum.map(Memory.list_chat_side_prompts(chat), & &1.id) == [own.id, site.id]
      assert Enum.map(Memory.list_side_prompts(user), & &1.id) == [own.id]
      assert {:error, :unauthorized} = SidePrompts.run(user, chat, theirs)

      {:ok, book} = Lore.create_book(other, %{name: "Their book"})

      assert {:error, changeset} = Memory.update_side_prompt(user, own, %{target_book_id: book.id})
      assert "is not available" in errors_on(changeset).target_book_id
    end
  end

  describe "import_records/3" do
    test "writes records for unrecorded members and wires consolidations, canonicals and sources", %{scope: scope} do
      chat = chat!(scope)
      {:ok, book} = Lore.create_book(scope, %{name: "Memories"})
      {:ok, elsewhere} = Lore.create_book(scope, %{name: "Elsewhere"})

      entry = fn name, book_id ->
        {:ok, e} = Lore.create_entry(scope, %{name: name, content: "x", activation: :constant}, [book_id])
        e
      end

      a = entry.("A", book.id)
      b = entry.("B", book.id)
      arc = entry.("Arc", book.id)
      outsider = entry.("Out", elsewhere.id)
      existing = record!(scope, book, chat, :memory, 0)

      specs = [
        %{
          entry_id: a.id,
          kind: :memory,
          tier: 0,
          sequence: 4,
          range_start: 0,
          range_end: 3,
          chat_id: chat.id,
          disabled_by_consolidation: true,
          consolidated_into_entry_id: arc.id,
          snapshot: %{"k" => 1}
        },
        %{
          entry_id: b.id,
          kind: :memory,
          tier: 0,
          sequence: nil,
          canonical_entry_id: a.id,
          consolidated_into_entry_id: arc.id
        },
        %{entry_id: arc.id, kind: :consolidation, tier: 1, sequence: nil, source_entry_ids: [a.id, b.id]},
        %{entry_id: outsider.id, kind: :memory, tier: 0, sequence: 1},
        %{entry_id: existing.lore_entry_id, kind: :memory, tier: 0, sequence: 9}
      ]

      assert {:ok, 3} = Memory.import_records(scope, book, specs)

      ra = Repo.get_by!(Record, lore_entry_id: a.id)
      rb = Repo.get_by!(Record, lore_entry_id: b.id)
      rarc = Repo.get_by!(Record, lore_entry_id: arc.id) |> Repo.preload(:sources)

      assert %{sequence: 4, range_start: 0, range_end: 3, chat_id: chat_id, disabled_by_consolidation: true} = ra
      assert chat_id == chat.id
      assert ra.snapshot == %{"k" => 1}
      assert ra.consolidated_into_id == rarc.id and rb.consolidated_into_id == rarc.id
      assert rb.canonical_id == ra.id
      assert rb.sequence == 5
      assert %{kind: :consolidation, tier: 1} = rarc
      assert Enum.sort(Enum.map(rarc.sources, & &1.id)) == Enum.sort([ra.id, rb.id])
      refute Repo.get_by(Record, lore_entry_id: outsider.id)
      assert Repo.get!(Record, existing.id).sequence == existing.sequence
    end

    test "refuses a book the scope can't edit", %{scope: scope} do
      {:ok, book} = Lore.create_book(scope, %{name: "Site"}, site: true)
      user = scope!(%{role: :user})
      assert {:error, :unauthorized} = Memory.import_records(user, book, [])
    end
  end

  describe "restore_progress/2" do
    test "sets highest_processed", %{scope: scope} do
      chat = chat!(scope)
      settings = Memory.chat_settings(scope, chat)
      assert :ok = Memory.restore_progress(settings, 7)
      assert Memory.chat_settings(scope, chat).highest_processed == 7
    end
  end

  defp chat!(scope, owner \\ nil) do
    owner = owner || scope

    characters =
      for name <- ~w(Player Responder) do
        {:ok, character} = Characters.create_character(scope, %{name: name}, site: true)
        character
      end

    {:ok, chat} =
      Chats.create_chat(owner, %{
        name: "Memory chat",
        participants: Enum.map(characters, &%{character_id: &1.id}),
        player_character_id: hd(characters).id
      })

    chat
  end

  defp profile!(scope, name, opts \\ []) do
    {:ok, profile} = Memory.create_profile(scope, %{name: name}, opts)
    profile
  end

  defp prompt!(scope, name, purpose, opts \\ []) do
    {:ok, prompt} = Prompts.create_prompt(scope, %{name: name, purpose: purpose}, opts)
    prompt
  end

  defp record!(scope, book, chat, kind, tier) do
    {:ok, entry} = Lore.create_entry(scope, %{name: "Entry", content: "Text", activation: :constant}, [book.id])

    %Record{}
    |> Record.changeset(%{lore_entry_id: entry.id, lore_book_id: book.id, chat_id: chat.id, kind: kind, tier: tier})
    |> Repo.insert!()
  end
end
