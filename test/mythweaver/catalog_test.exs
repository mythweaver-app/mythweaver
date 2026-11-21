defmodule Mythweaver.CatalogTest do
  use Mythweaver.DataCase

  alias Mythweaver.Catalog
  alias Mythweaver.Catalog.Listing
  alias Mythweaver.Characters
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats
  alias Mythweaver.Lore
  alias Mythweaver.Lore.BookCharacter
  alias Mythweaver.Lore.BookChat
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Moderation.Report
  alias Mythweaver.Moderation.Reports
  alias Mythweaver.Notifications
  alias Mythweaver.Prompts.Block
  alias Mythweaver.Prompts.Preview
  alias Mythweaver.Sharing
  alias Mythweaver.Sharing.Clone
  alias Mythweaver.Sharing.Share

  setup do
    publisher = scope!(%{role: :user})
    {:ok, character} = Characters.create_character(publisher, %{name: "Hero", description: "brave"})
    {:ok, book} = Lore.create_book(publisher, %{name: "Hero lore"})
    {:ok, _entry} = Lore.create_entry(publisher, %{name: "Cave", content: "dark", keywords: ["cave"]}, [book.id])
    {:ok, _} = Lore.bind_book_to_character(book, character.id)

    %{publisher: publisher, subscriber: scope!(%{role: :user}), character: character, book: book}
  end

  defp publish!(scope, item, attrs \\ %{}) do
    {:ok, listing} = Catalog.publish(scope, item, Map.merge(%{title: "Hero", visibility: :readable}, attrs))
    listing
  end

  defp mirror_of(listing, type), do: Repo.one!(from(r in type, where: r.frozen_listing_id == ^listing.id))

  defp mirror_book(listing), do: mirror_of(listing, LoreBook)

  defp chat!(scope, characters) do
    {:ok, chat} =
      Chats.create_chat(scope, %{"participants" => Enum.map(characters, &%{"character_id" => &1.id})})

    Chats.get_chat!(chat.id)
  end

  defp description_for(scope, chat, character) do
    block = %Block{name: "Probe", kind: :template, role: :system, content: "{{ anchors.character.description }}"}
    %{sections: [%{"content" => content} | _]} = Preview.run(scope, Preview.block_prompt(scope, block), chat, character)
    content
  end

  describe "publish/3" do
    test "makes a mirror the publisher never sees among their own rows", %{publisher: publisher, character: character} do
      listing = publish!(publisher, character)
      mirror = Repo.get!(Character, listing.mirror_id)

      assert mirror.mirror_of_id == character.id
      assert mirror.frozen_listing_id == listing.id
      assert mirror.name == "Hero"
      assert listing.current_release.version == 1

      assert mirror_book(listing).name == "Hero lore"
      assert [%LoreEntry{name: "Cave"}] = Repo.all(from(e in LoreEntry, where: e.frozen_listing_id == ^listing.id))

      assert [%{id: id}] = Characters.list_characters(publisher)
      assert id == character.id
      assert [%{id: ^id}] = Characters.list_editable_characters(publisher)
      assert [%{id: book_id}] = Lore.list_books(publisher)
      refute book_id == mirror_book(listing).id
    end

    test "needs catalog.publish, the owner, and one listing per item", %{publisher: publisher, character: character} do
      other = scope!(%{role: :user})
      assert {:error, :unauthorized} = Catalog.publish(other, character, %{title: "Mine"})

      denied = %{publisher | permissions: Map.put(publisher.permissions, "catalog.publish", false)}
      assert {:error, :unauthorized} = Catalog.publish(denied, character, %{title: "Hero"})

      publish!(publisher, character)
      assert {:error, %Ecto.Changeset{} = changeset} = Catalog.publish(publisher, character, %{title: "Again"})
      assert "is already published" in errors_on(changeset).item_type
    end
  end

  describe "subscribing" do
    test "a subscriber can use the mirror character in a chat", ctx do
      %{publisher: publisher, subscriber: subscriber, character: character} = ctx
      listing = publish!(publisher, character)

      assert {:ok, %Share{role: :subscriber, status: :accepted, visibility: :readable}} =
               Catalog.subscribe(subscriber, listing)

      assert {:error, :already_subscribed} = Catalog.subscribe(subscriber, listing)
      assert {:error, :unauthorized} = Catalog.subscribe(publisher, listing)
      assert Repo.reload!(listing).subscriber_count == 1

      mirror = Characters.get_character(subscriber, listing.mirror_id)
      refute Characters.get_character(subscriber, character.id)
      {:ok, own} = Characters.create_character(subscriber, %{name: "Me"})
      chat = chat!(subscriber, [mirror, own])

      assert Enum.any?(chat.participants, &(&1.character_id == mirror.id))
      assert description_for(subscriber, chat, mirror) == "brave"

      assert {:ok, _} = Catalog.unsubscribe(subscriber, listing)
      assert Repo.reload!(listing).subscriber_count == 0
      refute Characters.get_character(subscriber, listing.mirror_id)
    end
  end

  describe "release/3" do
    test "a release carries live edits to subscribers; a dropped book goes with its chat binding", ctx do
      %{publisher: publisher, subscriber: subscriber, character: character, book: book} = ctx
      listing = publish!(publisher, character)
      {:ok, _} = Catalog.subscribe(subscriber, listing)
      mirror = Characters.get_character(subscriber, listing.mirror_id)
      {:ok, own} = Characters.create_character(subscriber, %{name: "Me"})
      chat = chat!(subscriber, [mirror, own])
      dropped = mirror_book(listing)
      {:ok, _} = Lore.bind_book_to_chat(dropped, chat.id)

      {:ok, _} = Characters.update_character(publisher, character, %{description: "braver"})
      assert description_for(subscriber, chat, mirror) == "brave"

      Repo.delete_all(
        from(bc in BookCharacter, where: bc.character_id == ^character.id and bc.lore_book_id == ^book.id)
      )

      assert {:ok, %Listing{} = released} = Catalog.release(publisher, listing, "Sharper")
      assert released.current_release.version == 2
      assert released.current_release.notes == "Sharper"

      chat = Chats.get_chat!(chat.id)
      assert Repo.get!(Character, listing.mirror_id).description == "braver"
      assert description_for(subscriber, chat, mirror) == "braver"
      refute Repo.get(LoreBook, dropped.id)
      refute Repo.exists?(from(bc in BookChat, where: bc.chat_id == ^chat.id))
      assert Enum.any?(chat.participants, &(&1.character_id == mirror.id))
    end

    test "only the owner releases", %{publisher: publisher, subscriber: subscriber, character: character} do
      listing = publish!(publisher, character)
      assert {:error, :unauthorized} = Catalog.release(subscriber, listing, nil)
    end
  end

  describe "mirror rows" do
    test "an edit or delete of a mirror row is refused", ctx do
      %{publisher: publisher, subscriber: subscriber, character: character} = ctx
      listing = publish!(publisher, character)
      {:ok, _} = Catalog.subscribe(subscriber, listing)
      mirror = Repo.get!(Character, listing.mirror_id)

      assert {:error, :unauthorized} = Characters.update_character(publisher, mirror, %{description: "x"})
      assert {:error, :unauthorized} = Characters.update_character(subscriber, mirror, %{description: "x"})
      assert {:error, :unauthorized} = Mythweaver.Ownership.authorize_delete(publisher, mirror)
      assert Repo.reload!(mirror).description == "brave"
    end
  end

  describe "ending a listing" do
    test "unpublishing revokes, freezes the subscriber's chat and deletes the mirror", ctx do
      %{publisher: publisher, subscriber: subscriber, character: character} = ctx
      listing = publish!(publisher, character)
      {:ok, _} = Catalog.subscribe(subscriber, listing)
      mirror = Characters.get_character(subscriber, listing.mirror_id)
      {:ok, a} = Characters.create_character(subscriber, %{name: "A"})
      {:ok, b} = Characters.create_character(subscriber, %{name: "B"})
      chat = chat!(subscriber, [mirror, a, b])

      assert {:ok, impact} = Catalog.unpublish_impact(publisher, listing)
      assert impact != %{}
      assert {:error, :unauthorized} = Catalog.unpublish(subscriber, listing)
      assert :ok = Catalog.unpublish(publisher, listing)

      refute Repo.get(Listing, listing.id)
      refute Repo.get(Character, mirror.id)
      refute Repo.exists?(from(b in LoreBook, where: b.frozen_listing_id == ^listing.id))
      refute Repo.exists?(from(s in Share, where: s.user_id == ^subscriber.user.id))
      assert length(Chats.get_chat!(chat.id).participants) == 2
      assert Enum.any?(Notifications.inbox(subscriber), &(&1.body == "It was unpublished."))
      assert Repo.get(Character, character.id)
    end

    test "deleting the live item unpublishes it first", %{publisher: publisher, character: character} do
      listing = publish!(publisher, character)
      assert {:ok, _} = Characters.delete_character(publisher, character)
      refute Repo.get(Listing, listing.id)
      refute Repo.get(Character, listing.mirror_id)
    end

    test "a takedown needs moderation.content.delete and tells the owner", ctx do
      %{publisher: publisher, subscriber: subscriber, character: character} = ctx
      listing = publish!(publisher, character)
      {:ok, _} = Catalog.subscribe(subscriber, listing)
      {:ok, report} = Reports.report(subscriber, :listing, listing.id, "Spam")

      assert {:error, :unauthorized} = Catalog.takedown(subscriber, listing, "spam")
      assert {:error, :unauthorized} = Catalog.takedown(publisher, listing, "spam")

      assert :ok = Catalog.takedown(scope!(), listing, "spam")
      assert %Report{status: :actioned} = Repo.get(Report, report.id)
      refute Repo.get(Listing, listing.id)
      refute Repo.get(Character, listing.mirror_id)
      assert Enum.any?(Notifications.inbox(subscriber), &(&1.body == "It was removed by a moderator."))
      assert [%{kind: :listing_taken_down, body: "spam"}] = Notifications.inbox(publisher)
    end

    test "only an owner takes down an owner's listing" do
      owner = scope!(%{role: :owner})
      {:ok, character} = Characters.create_character(owner, %{name: "Owner hero"})
      listing = publish!(owner, character)

      assert Catalog.takedown(scope!(), listing, "spam") == {:error, :unauthorized}
      assert Repo.get(Listing, listing.id)
    end

    test "a takedown needs a reason", %{publisher: publisher, character: character} do
      listing = publish!(publisher, character)

      assert Catalog.takedown(scope!(), listing, "  ") == {:error, :reason_required}
      assert Repo.get(Listing, listing.id)
    end
  end

  describe "browsing and moderation" do
    test "lists listings featured first and filters them", %{publisher: publisher, character: character, book: book} do
      first = publish!(publisher, character, %{title: "Hero", tags: ["Fantasy"]})
      second = publish!(publisher, book, %{title: "Caves", summary: "Underground"})
      moderator = scope!()

      assert [%{id: a}, %{id: b}] = Catalog.list_listings(nil)
      assert {a, b} == {second.id, first.id}

      assert {:ok, _} = Catalog.feature(moderator, first, true)
      assert {:error, :unauthorized} = Catalog.feature(publisher, second, true)
      assert [%{id: ^b}, %{id: ^a}] = Catalog.list_listings(nil)

      assert [%{id: ^a}] = Catalog.list_listings(nil, search: "underground")
      assert [%{id: ^b}] = Catalog.list_listings(nil, tag: "fantasy")
      assert [%{id: ^b}] = Catalog.list_listings(nil, type: :character)
      assert %Listing{releases: [%{version: 1}]} = Catalog.get_listing(nil, first.id)
    end
  end

  describe "cloning from a listing" do
    test "a Readable listing's clone records the live item and the release", ctx do
      %{publisher: publisher, subscriber: subscriber, character: character} = ctx
      listing = publish!(publisher, character)
      {:ok, _} = Catalog.subscribe(subscriber, listing)
      mirror = Characters.get_character(subscriber, listing.mirror_id)

      assert {:ok, %Character{} = copy} = Clone.clone(subscriber, mirror)
      assert copy.user_id == subscriber.user.id
      assert copy.cloned_from_id == character.id
      assert copy.cloned_from_release_id == listing.current_release_id
      assert is_nil(copy.frozen_listing_id) and is_nil(copy.mirror_of_id)
      assert [_] = Repo.all(from(b in LoreBook, where: b.user_id == ^subscriber.user.id))
    end
  end

  describe "hand-off" do
    test "moves the listing and its mirror to the new owner", ctx do
      %{publisher: publisher, subscriber: subscriber, character: character} = ctx
      editor = scope!(%{role: :user})
      {:ok, share} = Sharing.invite(publisher, character, "@" <> editor.user.handle)
      {:ok, _} = Sharing.accept(editor, share.id)
      listing = publish!(publisher, character)
      {:ok, _} = Catalog.subscribe(subscriber, listing)

      assert {:ok, {:handed_off, _}} = Characters.delete_character(publisher, character)
      assert Repo.reload!(listing).owner_id == editor.user.id
      assert Repo.get!(Character, listing.mirror_id).user_id == editor.user.id
      assert Characters.get_character(subscriber, listing.mirror_id)
    end
  end
end
