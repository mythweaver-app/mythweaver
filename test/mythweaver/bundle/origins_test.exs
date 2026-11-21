defmodule Mythweaver.Bundle.OriginsTest do
  use Mythweaver.DataCase, async: true

  alias Mythweaver.AI
  alias Mythweaver.Bundle.Origin
  alias Mythweaver.Bundle.Origins
  alias Mythweaver.Characters
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats
  alias Mythweaver.Schema

  defp character!(scope, name, opts \\ []) do
    {:ok, character} = Characters.create_character(scope, %{name: name}, opts)
    character
  end

  defp chat!(scope, [player | _] = characters) do
    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: "chat-#{System.unique_integer([:positive])}",
        participants: Enum.map(characters, &%{character_id: &1.id}),
        player_character_id: player.id
      })

    chat
  end

  defp model!(scope, name) do
    {:ok, model} = AI.create_model(scope, %{name: name, api_model_id: "gemma-4"})
    model
  end

  defp touch!(%Character{} = character, seconds_ago) do
    at = DateTime.add(DateTime.utc_now(:second), -seconds_ago)
    {1, _} = Repo.update_all(from(c in Character, where: c.id == ^character.id), set: [updated_at: at])
  end

  describe "uid_for/2 and uids_for/2" do
    test "a row without an origin is its own uid; one with an origin carries it" do
      scope = scope!(%{role: :user})
      plain = character!(scope, "Plain")
      imported = character!(scope, "Imported")
      uid = Schema.generate_id()
      :ok = Origins.record!(:character, imported.id, uid)

      assert Origins.uid_for(:character, plain.id) == plain.id
      assert Origins.uid_for(:character, imported.id) == uid
      assert Origins.uid_for(:lore_book, imported.id) == imported.id

      assert Origins.uids_for(:character, [plain.id, imported.id, plain.id]) == %{
               plain.id => plain.id,
               imported.id => uid
             }

      assert Origins.uids_for(:character, []) == %{}
    end
  end

  describe "record!/3" do
    test "is a no-op when the record is the uid, and replaces an earlier origin" do
      scope = scope!(%{role: :user})
      character = character!(scope, "Aria")

      :ok = Origins.record!(:character, character.id, character.id)
      assert Repo.aggregate(Origin, :count) == 0

      first = Schema.generate_id()
      second = Schema.generate_id()
      :ok = Origins.record!(:character, character.id, first)
      :ok = Origins.record!(:character, character.id, second)

      assert [%Origin{kind: :character, origin_id: ^second}] = Repo.all(Origin)
    end
  end

  describe "match/3" do
    test "matches by id and by recorded origin, among rows the scope may use" do
      scope = scope!(%{role: :user})
      other = scope!(%{role: :user})
      own = character!(scope, "Own")
      imported = character!(scope, "Imported")
      theirs = character!(other, "Theirs")
      uid = Schema.generate_id()
      :ok = Origins.record!(:character, imported.id, uid)

      assert Origins.match(scope, :character, own.id).id == own.id
      assert Origins.match(scope, :character, uid).id == imported.id
      assert Origins.match(scope, :character, theirs.id) == nil
      assert Origins.match(scope, :character, Schema.generate_id()) == nil
      assert Origins.match(scope, :lore_book, own.id) == nil
      assert Origins.match(scope, :character, "not-a-uuid") == nil
    end

    test "prefers a row the scope may edit, then the latest updated_at" do
      admin = scope!()
      scope = scope!(%{role: :user})
      site = character!(admin, "Site", site: true)
      older = character!(scope, "Older")
      newer = character!(scope, "Newer")
      assert site.user_id == nil

      :ok = Origins.record!(:character, older.id, site.id)
      :ok = Origins.record!(:character, newer.id, site.id)
      touch!(site, 0)
      touch!(older, 100)
      touch!(newer, 50)

      assert Origins.match(scope, :character, site.id).id == newer.id

      touch!(older, 10)
      assert Origins.match(scope, :character, site.id).id == older.id

      # The site row is usable but only an admin may edit it, so for the admin it wins.
      assert Origins.match(admin, :character, site.id).id == site.id
    end

    test "matches only role-play chats the scope owns" do
      scope = scope!(%{role: :user})
      other = scope!(%{role: :user})
      chat = chat!(scope, [character!(scope, "A"), character!(scope, "B")])
      theirs = chat!(other, [character!(other, "C"), character!(other, "D")])
      uid = Schema.generate_id()
      :ok = Origins.record!(:chat, theirs.id, uid)

      assert Origins.match(scope, :chat, chat.id).id == chat.id
      assert Origins.match(scope, :chat, theirs.id) == nil
      assert Origins.match(scope, :chat, uid) == nil
      assert Origins.match(other, :chat, uid).id == theirs.id

      {:ok, assistant} = Chats.create_assistant_chat(scope, %{})
      assert Origins.match(scope, :chat, assistant.id) == nil
    end

    test "matches AI models the scope may run" do
      scope = scope!(%{role: :user})
      other = scope!(%{role: :user})
      model = model!(scope, "Mine")
      theirs = model!(other, "Theirs")

      assert Origins.match(scope, :ai_model, model.id).id == model.id
      assert Origins.match(scope, :ai_model, theirs.id) == nil
    end
  end
end
