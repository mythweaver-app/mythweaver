defmodule Mythweaver.Sharing.CloneTest do
  use Mythweaver.DataCase

  alias Mythweaver.Attachments
  alias Mythweaver.Characters
  alias Mythweaver.Characters.Character
  alias Mythweaver.Lore
  alias Mythweaver.Lore.BookCharacter
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Sharing
  alias Mythweaver.Sharing.Clone

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
       )

  setup do
    %{owner: scope!(%{role: :user}), reader: scope!(%{role: :user})}
  end

  defp character!(scope, name \\ "Hero") do
    {:ok, character} = Characters.create_character(scope, %{name: name, description: "secret"})
    character
  end

  defp subscribe!(owner, scope, item, visibility) do
    {:ok, share} = Sharing.invite(owner, item, "@" <> scope.user.handle, role: :subscriber, visibility: visibility)
    {:ok, share} = Sharing.accept(scope, share.id)
    share
  end

  test "a Readable subscriber clones a character, linking a book it may only use", %{owner: owner, reader: reader} do
    character = character!(owner)
    subscribe!(owner, reader, character, :readable)

    # A third user's book bound to the character, shared to the reader Runtime-only.
    third = scope!(%{role: :user})
    subscribe!(owner, third, character, :runtime_only)
    {:ok, book} = Lore.create_book(third, %{name: "Third's lore"})
    {:ok, _} = Lore.bind_book_to_character(book, character.id)
    subscribe!(third, reader, book, :runtime_only)

    assert {:ok, %Character{} = copy} = Clone.clone(reader, character)
    assert copy.user_id == reader.user.id
    assert copy.id != character.id
    assert copy.description == "secret"
    assert {copy.cloned_from_type, copy.cloned_from_id} == {:character, character.id}

    assert [%BookCharacter{lore_book_id: book_id}] =
             Repo.all(from(bc in BookCharacter, where: bc.character_id == ^copy.id))

    assert book_id == book.id
    refute Repo.exists?(from(b in LoreBook, where: b.user_id == ^reader.user.id))
  end

  test "a Runtime-only subscriber may not clone", %{owner: owner, reader: reader} do
    character = character!(owner)
    subscribe!(owner, reader, character, :runtime_only)

    assert {:error, :unauthorized} = Clone.clone(reader, character)
    assert {:error, :unauthorized} = Clone.clone(owner, character)
  end

  test "a cloned lore book copies its entries", %{owner: owner, reader: reader} do
    {:ok, book} = Lore.create_book(owner, %{name: "Atlas"})
    {:ok, cave} = Lore.create_entry(owner, %{name: "Cave", content: "dark", keywords: ["cave"]}, [book.id])
    {:ok, _lake} = Lore.create_entry(owner, %{name: "Lake", content: "wet", keywords: ["lake"]}, [book.id])
    subscribe!(owner, reader, book, :readable)

    assert {:ok, %LoreBook{} = copy} = Clone.clone(reader, book)
    assert copy.name == "Atlas"
    assert {copy.cloned_from_type, copy.cloned_from_id} == {:lore_book, book.id}

    entries = Lore.list_entries_in_book(reader, copy)
    assert entries |> Enum.map(&{&1.name, &1.content}) |> Enum.sort() == [{"Cave", "dark"}, {"Lake", "wet"}]
    assert Enum.all?(entries, &(&1.user_id == reader.user.id))
    refute Enum.any?(entries, &(&1.id == cave.id))

    assert {:ok, again} = Clone.clone(reader, book)
    assert again.name == "Atlas 2"
  end

  test "a cloned character's avatar is a new attachment with the same bytes", %{owner: owner, reader: reader} do
    character = character!(owner)
    path = Path.join(System.tmp_dir!(), "clone-#{System.unique_integer([:positive])}.png")
    File.write!(path, @png)
    {:ok, avatar} = Attachments.store_file(owner, path, filename: "hero.png")
    :ok = Attachments.set_avatar(owner, character, avatar, describe: false)
    subscribe!(owner, reader, character, :readable)

    assert {:ok, copy} = Clone.clone(reader, character)
    copy_avatar = Characters.preload_avatar(reader, copy).avatar

    assert copy_avatar.id != avatar.id
    assert copy_avatar.uploaded_by_id == reader.user.id
    assert Attachments.read(copy_avatar) == {:ok, @png}

    {:ok, _} = Characters.delete_character(owner, character)
    assert Attachments.read(copy_avatar) == {:ok, @png}
  end
end
