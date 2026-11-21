defmodule Mythweaver.LoreTest do
  use Mythweaver.DataCase

  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Lore
  alias Mythweaver.Lore.BookCharacter
  alias Mythweaver.Lore.BookChat
  alias Mythweaver.Lore.BookEntry
  alias Mythweaver.Lore.EntryState
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Lore.PoolEntry
  alias Mythweaver.Lore.Settings
  alias Mythweaver.Memory.SidePrompt
  alias Mythweaver.Prompts

  setup do
    %{scope: scope!()}
  end

  describe "create_entry/3" do
    test "an entry with no books is created unlinked", %{scope: scope} do
      assert {:ok, entry} = Lore.create_entry(scope, %{name: "Orphan", content: "nobody", keywords: ["x"]}, [])

      assert Enum.map(Lore.list_tree(scope).unlinked, & &1.id) == [entry.id]
    end

    test "creates the entry and one membership per book id", %{scope: scope} do
      a = book(scope, "A")
      b = book(scope, "B")

      entry = entry(scope, "Shared", [a.id, b.id])

      assert Enum.map(entry.books, & &1.id) |> Enum.sort() == Enum.sort([a.id, b.id])
    end

    test "without an order each membership lands at the top of its own book", %{scope: scope} do
      a = book(scope, "A")
      b = book(scope, "B")
      _ = entry(scope, "Existing", [a.id], %{}, %{order: 40})

      shared = entry(scope, "Shared", [a.id, b.id])

      assert membership_order(a, shared) == 41
      assert membership_order(b, shared) == 1
    end
  end

  describe "remove_entry_from_book/2" do
    test "removing the only membership leaves the entry unlinked", %{scope: scope} do
      a = book(scope, "A")
      entry = entry(scope, "Only", [a.id])

      assert {:ok, _} = Lore.remove_entry_from_book(scope, a, entry)

      assert Enum.map(Lore.list_tree(scope).unlinked, & &1.id) == [entry.id]
    end

    test "drops one of two memberships and the entry survives with the other", %{scope: scope} do
      a = book(scope, "A")
      b = book(scope, "B")
      entry = entry(scope, "Shared", [a.id, b.id])

      assert {:ok, _} = Lore.remove_entry_from_book(scope, a, entry)

      reloaded = Lore.get_entry!(entry.id)
      assert Enum.map(reloaded.books, & &1.id) == [b.id]
    end
  end

  describe "set_entry_books/2" do
    test "an empty list unlinks the entry", %{scope: scope} do
      a = book(scope, "A")
      b = book(scope, "B")
      entry = entry(scope, "Shared", [a.id, b.id])

      assert {:ok, :ok} = Lore.set_entry_books(scope, entry, [])

      assert Lore.get_entry!(entry.id).books == []
    end

    test "diffs memberships to exactly the given ids", %{scope: scope} do
      a = book(scope, "A")
      b = book(scope, "B")
      c = book(scope, "C")
      entry = entry(scope, "Shared", [a.id, b.id])

      assert {:ok, :ok} = Lore.set_entry_books(scope, entry, [b.id, c.id])

      reloaded = Lore.get_entry!(entry.id)
      assert Enum.map(reloaded.books, & &1.id) |> Enum.sort() == Enum.sort([b.id, c.id])
    end
  end

  describe "delete_book/1" do
    test "succeeds while it exclusively owns entries, leaving them unlinked", %{scope: scope} do
      a = book(scope, "A")
      entry = entry(scope, "Only", [a.id])

      assert {:ok, %LoreBook{}} = Lore.delete_book(scope, a)

      assert Lore.get_book(scope, a.id) == nil
      assert %LoreEntry{} = Lore.get_entry(scope, entry.id)
      assert Enum.map(Lore.list_tree(scope).unlinked, & &1.id) == [entry.id]
    end
  end

  describe "reorder_book_entries/2" do
    test "renumbers this book only; a shared entry keeps its order elsewhere", %{scope: scope} do
      a = book(scope, "A")
      b = book(scope, "B")
      shared = entry(scope, "Shared", [a.id, b.id], %{}, %{order: 50})
      other = entry(scope, "Other", [a.id], %{}, %{order: 10})

      assert {:ok, :ok} = Lore.reorder_book_entries(scope, a, [other.id, shared.id])

      assert membership_order(a, other) == 2
      assert membership_order(a, shared) == 1
      assert membership_order(b, shared) == 50
    end
  end

  describe "set_membership_order/3" do
    test "rejects a negative order", %{scope: scope} do
      a = book(scope, "A")
      entry = entry(scope, "E", [a.id])

      assert {:error, %Ecto.Changeset{}} = Lore.set_membership_order(scope, a, entry.id, -1)
    end
  end

  describe "place_entry/5" do
    setup %{scope: scope} do
      a = book(scope, "A")
      b = book(scope, "B")
      %{a: a, b: b, entry: entry(scope, "Moved", [a.id])}
    end

    test "moving A to B leaves only B", %{a: a, b: b, entry: entry, scope: scope} do
      assert {:ok, :placed} = Lore.place_entry(scope, entry.id, a.id, b.id, false, [entry.id])
      assert book_ids(entry) == [b.id]
    end

    test "copying A to B keeps both", %{a: a, b: b, entry: entry, scope: scope} do
      assert {:ok, :placed} = Lore.place_entry(scope, entry.id, a.id, b.id, true, [entry.id])
      assert book_ids(entry) == Enum.sort([a.id, b.id])
    end

    test "moving to Unlinked unlinks; moving from Unlinked links", %{a: a, b: b, entry: entry, scope: scope} do
      assert {:ok, :placed} = Lore.place_entry(scope, entry.id, a.id, nil, false, [])
      assert book_ids(entry) == []

      assert {:ok, :placed} = Lore.place_entry(scope, entry.id, nil, b.id, false, [entry.id])
      assert book_ids(entry) == [b.id]
    end

    test "renumbers the target from ordered ids", %{a: a, b: b, entry: entry, scope: scope} do
      top = entry(scope, "Top", [b.id], %{}, %{order: 9})

      assert {:ok, :placed} = Lore.place_entry(scope, entry.id, a.id, b.id, false, [top.id, entry.id])
      assert membership_order(b, top) == 2
      assert membership_order(b, entry) == 1
    end

    test "stale ordered ids still place the entry, at the top of the book", %{a: a, b: b, entry: entry, scope: scope} do
      top = entry(scope, "Top", [b.id], %{}, %{order: 9})

      assert {:ok, :placed} = Lore.place_entry(scope, entry.id, a.id, b.id, false, [entry.id])
      assert membership_order(b, entry) == 10
      assert membership_order(b, top) == 9
    end

    test "a missing book is not found", %{a: a, entry: entry, scope: scope} do
      assert {:error, :not_found} = Lore.place_entry(scope, entry.id, a.id, Mythweaver.Schema.generate_id(), false, [])
      assert book_ids(entry) == [a.id]
    end
  end

  describe "list_tree/0" do
    test "books by name with entries by order, book counts, and unlinked entries", %{scope: scope} do
      b = book(scope, "B", %{order_adjustment: 5})
      a = book(scope, "A")
      low = entry(scope, "Low", [b.id], %{}, %{order: 1})
      shared = entry(scope, "Shared", [a.id, b.id], %{}, %{order: 3})
      loose = entry(scope, "Loose", [])

      assert %{books: [%{book: %{id: a_id}}, %{book: %{id: b_id}, entries: b_rows}], unlinked: [%{id: loose_id}]} =
               Lore.list_tree(scope)

      assert {a_id, b_id, loose_id} == {a.id, b.id, loose.id}
      assert Enum.map(b_rows, &{&1.entry.id, &1.book_count}) == [{shared.id, 2}, {low.id, 1}]
    end
  end

  describe "books_for_chat/1" do
    setup %{scope: scope} do
      hero = character(scope, "Hero")
      foil = character(scope, "Foil")
      %{chat: chat(scope, [hero, foil]), hero: hero, foil: foil}
    end

    test "includes a global book", %{chat: chat, scope: scope} do
      global = book(scope, "Global", %{global: true})
      _unbound = book(scope, "Unbound")

      assert ids(Lore.books_for_chat(chat)) == [global.id]
    end

    test "includes a chat-bound book", %{chat: chat, scope: scope} do
      bound = book(scope, "Bound")
      _unbound = book(scope, "Unbound")
      {:ok, _} = Lore.bind_book_to_chat(bound, chat.id)

      assert ids(Lore.books_for_chat(chat)) == [bound.id]
    end

    test "includes a book bound to a participating character", %{chat: chat, foil: foil, scope: scope} do
      bound = book(scope, "CharBound")
      other = character(scope, "Stranger")
      _unrelated = book(scope, "StrangerBound")
      {:ok, _} = Lore.bind_book_to_character(bound, foil.id)
      {:ok, _} = Lore.bind_book_to_character(book(scope, "Elsewhere"), other.id)

      assert ids(Lore.books_for_chat(chat)) == [bound.id]
    end

    test "excludes a chat binding that has been disabled", %{chat: chat, scope: scope} do
      bound = book(scope, "Bound")
      {:ok, binding} = Lore.bind_book_to_chat(bound, chat.id)

      assert {:ok, _} = Lore.set_binding_enabled(scope, binding, false)
      assert Lore.books_for_chat(chat) == []
    end

    test "excludes a character binding that has been disabled", %{chat: chat, hero: hero, scope: scope} do
      bound = book(scope, "CharBound")
      {:ok, binding} = Lore.bind_book_to_character(bound, hero.id)

      assert {:ok, _} = Lore.set_binding_enabled(scope, binding, false)
      assert Lore.books_for_chat(chat) == []
    end

    test "excludes a book bound to an unrelated chat", %{chat: chat, scope: scope} do
      elsewhere = chat(scope, [character(scope, "A"), character(scope, "B")])
      bound = book(scope, "Bound")
      {:ok, _} = Lore.bind_book_to_chat(bound, elsewhere.id)

      assert Lore.books_for_chat(chat) == []
      assert ids(Lore.books_for_chat(elsewhere)) == [bound.id]
    end

    test "includes both of two books bound to the same chat", %{chat: chat, scope: scope} do
      first = book(scope, "First")
      second = book(scope, "Second")
      {:ok, _} = Lore.bind_book_to_chat(first, chat.id)
      {:ok, _} = Lore.bind_book_to_chat(second, chat.id)

      assert ids(Lore.books_for_chat(chat)) == Enum.sort([first.id, second.id])
    end
  end

  describe "LoreEntry changeset validation" do
    test "a keyword entry needs at least one keyword", %{scope: scope} do
      a = book(scope, "A")

      assert {:error, changeset} =
               Lore.create_entry(scope, %{name: "Bare", content: "x", keywords: []}, [a.id])

      assert %{keywords: [_]} = errors_on(changeset)
    end

    test "an uncompilable regex keyword is rejected, naming its source", %{scope: scope} do
      a = book(scope, "A")

      assert {:error, changeset} =
               Lore.create_entry(scope, %{name: "Bad", content: "x", keywords: ["/(/"]}, [a.id])

      assert %{keywords: [message]} = errors_on(changeset)
      assert message =~ "/(/"
    end

    test "a valid regex keyword passes", %{scope: scope} do
      a = book(scope, "A")

      assert {:ok, entry} =
               Lore.create_entry(
                 scope,
                 %{name: "Good", content: "x", keywords: ["/dr[ao]gon/i"]},
                 [a.id]
               )

      assert entry.keywords == ["/dr[ao]gon/i"]
    end

    test "content that does not parse as a template is rejected", %{scope: scope} do
      a = book(scope, "A")

      assert {:error, changeset} =
               Lore.create_entry(scope, %{name: "Broken", content: "{{ x", keywords: ["x"]}, [a.id])

      assert [message] = errors_on(changeset).content
      assert message =~ "has invalid template syntax"
    end
  end

  describe "import-only fields" do
    test "the shared changeset ignores kind and foreign; import: true casts them", %{scope: scope} do
      b = book(scope, "B")

      assert {:ok, %{kind: :lore, foreign: %{}}} =
               Lore.update_book(scope, b, %{"kind" => "card", "foreign" => %{"x" => 1}})

      assert {:ok, %{kind: :card, foreign: %{"x" => 1}}} =
               Lore.update_book(scope, b, %{"kind" => "card", "foreign" => %{"x" => 1}}, import: true)

      e = entry(scope, "E", [b.id])
      assert {:ok, %{foreign: %{}}} = Lore.update_entry(scope, e, %{"foreign" => %{"x" => 1}})
      assert {:ok, %{foreign: %{"x" => 1}}} = Lore.update_entry(scope, e, %{"foreign" => %{"x" => 1}}, import: true)

      assert {:ok, %{foreign: %{"y" => 2}}} =
               Lore.create_entry(scope, %{name: "F", content: "c", keywords: ["f"], foreign: %{"y" => 2}}, [b.id], %{},
                 import: true
               )

      assert {:ok, %{kind: :card}} = Lore.create_book(scope, %{name: "C", kind: :card}, import: true)
      assert {:ok, %{kind: :lore}} = Lore.create_book(scope, %{name: "D", kind: :card})
    end

    test "import foreign must be a map with string keys", %{scope: scope} do
      assert {:error, changeset} = Lore.create_book(scope, %{name: "B", foreign: %{x: 1}}, import: true)
      assert %{foreign: ["is invalid"]} = errors_on(changeset)
      assert {:error, changeset} = Lore.create_book(scope, %{name: "B", foreign: []}, import: true)
      assert %{foreign: [_]} = errors_on(changeset)
    end

    test "find_usable_book_by_name/2 finds a site book for a plain user, preferring the user's own" do
      admin = scope!()
      user = scope!(%{role: :user})
      site = book(admin, "World", %{}, site: true)
      _theirs = book(scope!(), "World")

      assert Lore.find_usable_book_by_name(user, "World").id == site.id
      own = book(user, "World")
      assert Lore.find_usable_book_by_name(user, "World").id == own.id
      assert Lore.find_usable_book_by_name(user, "world") == nil
    end

    test "find_usable_book_by_name/2 skips a hidden site book unless the scope may view it" do
      admin = scope!()
      user = scope!(%{role: :user})
      hidden = book(admin, "Vault", %{site_visibility: :hidden}, site: true)

      assert Lore.find_usable_book_by_name(user, "Vault") == nil
      assert Lore.find_usable_book_by_name(admin, "Vault").id == hidden.id
    end
  end

  describe "record_activations/3 and entry_states/1" do
    test "stores sticky/cooldown horizons relative to the message count", %{scope: scope} do
      a = book(scope, "A")
      chat = chat(scope, [character(scope, "Hero"), character(scope, "Foil")])
      entry = entry(scope, "Timed", [a.id], %{sticky: 2, cooldown: 3})

      assert :ok = Lore.record_activations(chat, [entry], 5)

      assert %{sticky_until: 7, cooldown_until: 10, last_activated_at_count: 5} =
               Map.fetch!(Lore.entry_states(chat), entry.id)
    end

    test "upserts rather than duplicating on a second call", %{scope: scope} do
      a = book(scope, "A")
      chat = chat(scope, [character(scope, "Hero"), character(scope, "Foil")])
      entry = entry(scope, "Timed", [a.id], %{sticky: 2, cooldown: 3})

      assert :ok = Lore.record_activations(chat, [entry], 5)
      assert :ok = Lore.record_activations(chat, [entry], 9)

      assert %{sticky_until: 11, cooldown_until: 14, last_activated_at_count: 9} =
               Map.fetch!(Lore.entry_states(chat), entry.id)

      assert Repo.aggregate(from(s in EntryState, where: s.chat_id == ^chat.id), :count) == 1
    end

    test "is a no-op for an empty entry list", %{scope: scope} do
      chat = chat(scope, [character(scope, "Hero"), character(scope, "Foil")])

      assert :ok = Lore.record_activations(chat, [], 3)
      assert Lore.entry_states(chat) == %{}
    end
  end

  describe "set_book_chats/2" do
    test "drops unwanted bindings, adds new ones, and keeps a kept row's enabled flag", %{scope: scope} do
      book = book(scope, "Bound")
      [keep, drop, add] = for _ <- 1..3, do: chat(scope, [character(scope, "A"), character(scope, "B")])
      {:ok, kept} = Lore.bind_book_to_chat(book, keep.id)
      {:ok, _} = Lore.set_binding_enabled(scope, kept, false)
      {:ok, _} = Lore.bind_book_to_chat(book, drop.id)

      assert {:ok, :ok} = Lore.set_book_chats(scope, book, [keep.id, add.id])

      rows = Repo.all(from(bc in BookChat, where: bc.lore_book_id == ^book.id))
      assert rows |> Enum.map(& &1.chat_id) |> Enum.sort() == Enum.sort([keep.id, add.id])
      assert Enum.find(rows, &(&1.chat_id == keep.id)).enabled == false
    end

    test "keeps bindings to other users' chats and ignores their ids", %{scope: scope} do
      other = scope!()
      book = book(scope, "Shared", %{}, site: true)
      theirs = chat(other, [character(scope, "A", site: true), character(scope, "B", site: true)])
      also_theirs = chat(other, [character(scope, "C", site: true), character(scope, "D", site: true)])
      {:ok, _} = Lore.bind_book_to_chat(book, theirs.id)

      assert {:ok, :ok} = Lore.set_book_chats(scope, book, [also_theirs.id])

      assert Repo.all(from(bc in BookChat, where: bc.lore_book_id == ^book.id, select: bc.chat_id)) == [theirs.id]
    end
  end

  describe "set_book_characters/3" do
    test "an editor's save keeps the owner's bindings to characters the editor cannot see" do
      owner = scope!(%{role: :user})
      editor = scope!(%{role: :user})
      book = book(owner, "Shared")
      {:ok, owners} = Characters.create_character(owner, %{name: "Owner's"})
      {:ok, _} = Lore.bind_book_to_character(book, owners.id)
      {:ok, share} = Mythweaver.Sharing.invite(owner, book, "@" <> editor.user.handle)
      {:ok, _} = Mythweaver.Sharing.accept(editor, share.id)

      assert {:ok, :ok} = Lore.set_book_characters(editor, book, [])

      assert Repo.all(from(bc in BookCharacter, where: bc.lore_book_id == ^book.id, select: bc.character_id)) ==
               [owners.id]
    end
  end

  describe "ownership" do
    setup do
      %{user: scope!(%{role: :user}), other: scope!(%{role: :user})}
    end

    test "a user's own book and entries are theirs alone", %{scope: admin, user: user, other: other} do
      book = book(user, "Mine")
      entry = entry(user, "Secret", [book.id])
      unlinked = entry(user, "Loose", [])

      assert book.user_id == user.user.id
      assert entry.user_id == user.user.id and unlinked.user_id == user.user.id
      assert ids(Lore.list_books(user)) == [book.id]
      assert Lore.list_tree(user).unlinked |> ids() == [unlinked.id]

      for scope <- [admin, other] do
        assert Lore.get_book(scope, book.id) == nil
        assert Lore.get_entry(scope, entry.id) == nil
        refute book.id in ids(Lore.list_books(scope))
        assert {:error, :unauthorized} = Lore.update_book(scope, book, %{name: "Taken"})
        assert {:error, :unauthorized} = Lore.update_entry(scope, entry, %{name: "Taken"})
        assert {:error, :unauthorized} = Lore.create_entry(scope, %{name: "In", content: "x"}, [book.id])
      end
    end

    test "a site book is usable by a user but not editable", %{scope: admin, user: user} do
      site = book(admin, "Site", %{}, site: true)

      assert Lore.get_book(user, site.id).id == site.id
      assert Lore.get_editable_book(user, site.id) == nil
      assert site.id in ids(Lore.list_usable_books(user))
      refute site.id in ids(Lore.list_books(user))
      assert {:error, :unauthorized} = Lore.update_book(user, site, %{name: "Taken"})
      assert {:error, :unauthorized} = Lore.create_entry(user, %{name: "In", content: "x"}, [site.id])
    end

    test "a hidden site book and its entry are invisible to a user, not an admin", %{scope: admin, user: user} do
      hidden = book(admin, "Vault", %{site_visibility: :hidden}, site: true)
      secret = entry(admin, "Secret", [hidden.id])

      refute hidden.id in ids(Lore.list_usable_books(user))
      assert Lore.get_book(user, hidden.id) == nil
      refute secret.id in ids(Lore.list_usable_entries(user))
      assert Lore.get_entry(user, secret.id) == nil

      assert hidden.id in ids(Lore.list_usable_books(admin))
      assert Lore.get_book(admin, hidden.id).id == hidden.id
      assert secret.id in ids(Lore.list_usable_entries(admin))
      assert Lore.get_entry(admin, secret.id).id == secret.id
    end

    test "a names-only site book is listed, but its entries are not offered for their content",
         %{scope: admin, user: user} do
      names_only = book(admin, "Atlas", %{site_visibility: :runtime_only}, site: true)
      fact = entry(admin, "Fact", [names_only.id])

      assert names_only.id in ids(Lore.list_usable_books(user))
      assert Lore.get_entry(user, fact.id).id == fact.id
      refute fact.id in ids(Lore.list_usable_entries(user))
    end

    test "a user cannot bind a hidden site book to their chat", %{scope: admin, user: user} do
      hidden = book(admin, "Vault", %{site_visibility: :hidden}, site: true)
      chat = chat(user, [character(user, "A"), character(user, "B")])

      assert Lore.set_chat_books(chat, [hidden.id]) == {:error, :unauthorized}
      assert Lore.bind_book_to_chat(hidden, chat.id) == {:error, :unauthorized}
    end

    test "only site books can be hidden or forced", %{user: user} do
      changeset = LoreBook.changeset(%LoreBook{user_id: user.user.id}, %{name: "x", forced: true})
      assert "only site books can be forced" in errors_on(changeset).forced

      changeset = LoreBook.changeset(%LoreBook{user_id: user.user.id}, %{name: "x", site_visibility: :hidden})
      assert "only site books can be hidden from users" in errors_on(changeset).site_visibility
    end

    test "memberships join only rows of one owner", %{scope: admin, user: user} do
      site = book(admin, "Site", %{}, site: true)
      own = book(user, "Own")
      entry = entry(user, "Mine", [own.id])
      {:ok, site_pool} = Lore.create_pool(admin, %{name: "Site pool"}, site: true)
      {:ok, own_pool} = Lore.create_pool(user, %{name: "Own pool"})

      assert {:error, :unauthorized} = Lore.create_entry(admin, %{name: "Mixed", content: "x"}, [site.id, own.id])
      assert {:error, :unauthorized} = Lore.set_entry_books(user, entry, [own.id, site.id])
      assert {:error, :unauthorized} = Lore.set_entry_pools(user, entry, [site_pool.id])
      assert {:ok, :ok} = Lore.set_entry_pools(user, entry, [own_pool.id])
      assert {:error, :not_found} = Lore.place_entry(user, entry.id, own.id, site.id, false, [])
      assert {:error, :not_found} = Lore.place_entry(admin, entry.id, own.id, site.id, false, [])
    end

    test "set_pool_memberships updates only the entry's own memberships", %{user: user, other: other} do
      own = book(user, "Own")
      entry = entry(user, "Mine", [own.id])
      {:ok, changed} = Lore.create_pool(user, %{name: "Changed"})
      {:ok, outside} = Lore.create_pool(user, %{name: "Outside"})
      {:ok, :ok} = Lore.set_entry_pools(user, entry, [changed.id])
      membership = fn pool -> Repo.get_by(PoolEntry, lore_entry_id: entry.id, lore_pool_id: pool.id) end

      assert {:ok, :ok} =
               Lore.set_pool_memberships(user, entry, %{
                 changed.id => %{weight: 7, override: true, scored: true},
                 outside.id => %{weight: 3}
               })

      assert %{weight: 7, override: true, scored: true} = membership.(changed)
      assert membership.(outside) == nil
      assert {:error, :unauthorized} = Lore.set_pool_memberships(other, entry, %{changed.id => %{weight: 1}})
      assert %{weight: 7} = membership.(changed)
    end

    test "bindings and character filters reference only what the owner may use",
         %{scope: admin, user: user, other: other} do
      site_book = book(admin, "Site", %{}, site: true)
      own_book = book(user, "Own")
      site_char = character(admin, "Site hero", site: true)
      own_char = character(user, "Own hero")
      their_char = character(other, "Their hero")
      entry = entry(user, "Mine", [own_book.id])

      assert {:error, :unauthorized} = Lore.set_book_characters(admin, site_book, [own_char.id])
      assert {:ok, :ok} = Lore.set_book_characters(admin, site_book, [site_char.id])
      assert {:ok, :ok} = Lore.set_book_characters(user, own_book, [site_char.id, own_char.id])
      assert {:error, :unauthorized} = Lore.set_book_characters(user, own_book, [their_char.id])
      assert {:error, :unauthorized} = Lore.set_entry_filter_characters(user, entry, [their_char.id])
      assert {:ok, :ok} = Lore.set_entry_filter_characters(user, entry, [own_char.id, site_char.id])

      their_chat = chat(other, [site_char, their_char])
      assert {:error, :unauthorized} = Lore.bind_book_to_chat(own_book, their_chat.id)
      assert {:error, :unauthorized} = Lore.set_chat_books(their_chat, [own_book.id])
      assert {:ok, _} = Lore.set_chat_books(their_chat, [site_book.id])
    end

    test "a chat book belongs to the chat's owner", %{scope: admin, user: user} do
      chat = chat(user, [character(admin, "A", site: true), character(admin, "B", site: true)])

      assert {:ok, book} = Lore.create_chat_book(user, chat, %{name: "Memories"})
      assert book.user_id == user.user.id
      assert Lore.chat_book_ids(chat) == [book.id]
    end

    test "a user's chat binding of a site book is hidden from and locked to the admin",
         %{scope: admin, user: user} do
      site = book(admin, "Site", %{}, site: true)
      chat = chat(user, [character(admin, "A", site: true), character(admin, "B", site: true)])
      {:ok, binding} = Lore.bind_book_to_chat(site, chat.id)

      assert Lore.get_editable_book(admin, site.id).book_chats == []
      assert Lore.get_book_chat(admin, binding.id) == nil
      assert {:error, :unauthorized} = Lore.set_binding_enabled(admin, binding, false)
      assert Repo.get!(BookChat, binding.id).enabled

      assert [%{id: id, chat: %{name: name}}] = Lore.get_book(user, site.id).book_chats
      assert id == binding.id and name == chat.name

      own = chat(admin, [character(admin, "C"), character(admin, "D")])
      {:ok, mine} = Lore.bind_book_to_chat(site, own.id)
      assert [%{id: mine_id}] = Lore.get_editable_book(admin, site.id).book_chats
      assert mine_id == mine.id

      assert {:ok, %BookChat{enabled: false}} =
               Lore.set_binding_enabled(admin, Lore.get_book_chat(admin, mine.id), false)
    end
  end

  describe "transfer_book/3" do
    setup %{scope: admin} do
      user = scope!(%{role: :user})
      book = book(admin, "Vault")
      other = book(admin, "Atlas")
      entry = entry(admin, "Secret", [book.id, other.id])
      {:ok, pool} = Lore.create_pool(admin, %{name: "Pool"})
      {:ok, :ok} = Lore.set_entry_pools(admin, entry, [pool.id])

      mine = character(admin, "Mine")
      site = character(admin, "Site", site: true)
      {:ok, _} = Lore.bind_book_to_character(book, mine.id)
      {:ok, _} = Lore.bind_book_to_character(book, site.id)

      {:ok, prompt} = Prompts.create_prompt(admin, %{name: "Side", purpose: :side_prompt}, site: true)

      side =
        Repo.insert!(%SidePrompt{name: "Watch", prompt_id: prompt.id, target_book_id: book.id, user_id: admin.user.id})

      %{user: user, book: book, other: other, entry: entry, mine: mine, site_character: site, side: side}
    end

    test "making a personal book the site's counts, then removes, every link the site may not hold",
         %{scope: admin} = ctx do
      assert {:ok, impact} = Lore.transfer_impact(admin, ctx.book, :site)

      assert impact == %{
               entries: 1,
               other_books: 1,
               pools: 1,
               entry_filters: 0,
               character_bindings: 1,
               memory_settings: 0,
               character_locks: 0,
               side_prompts: 1,
               topic_suggestions: 0,
               tag_filters: 0,
               book_tag_filters: 0,
               rule_chats: 0,
               rule_characters: 0
             }

      refute ctx.book.id in ids(Lore.list_usable_books(ctx.user))

      assert {:ok, %{user_id: nil}} = Lore.transfer_book(admin, ctx.book, :site)
      assert Repo.reload!(ctx.entry).user_id == nil
      assert book_ids(ctx.entry) == [ctx.book.id]
      assert Repo.all(from(pe in Lore.PoolEntry, where: pe.lore_entry_id == ^ctx.entry.id)) == []

      assert Repo.all(from(bc in BookCharacter, where: bc.lore_book_id == ^ctx.book.id, select: bc.character_id)) ==
               [ctx.site_character.id]

      assert Repo.reload!(ctx.side).target_book_id == nil
      assert ctx.book.id in ids(Lore.list_usable_books(ctx.user))
    end

    test "an entry moved to the site loses a tag filter naming a personal tag", %{scope: admin} = ctx do
      {:ok, :ok} = Lore.set_entry_filter_tags(admin, ctx.entry, ["series:metroid"])

      assert {:ok, %{tag_filters: 1}} = Lore.transfer_impact(admin, ctx.book, :site)
      assert {:ok, %{user_id: nil}} = Lore.transfer_book(admin, ctx.book, :site)
      assert Repo.all(from(ef in Lore.EntryFilterTag, where: ef.lore_entry_id == ^ctx.entry.id)) == []
    end

    test "a rule condition naming a personal character loses its target", %{scope: admin} = ctx do
      params = %{
        "rules" => %{
          "0" => %{
            "enabled" => "true",
            "conditions" => %{"0" => %{"kind" => "character_present", "character_id" => ctx.mine.id}}
          }
        }
      }

      assert {:ok, _} = Lore.set_book_rules(admin, ctx.book, params)
      assert {:ok, %{rule_characters: 1, rule_chats: 0}} = Lore.transfer_impact(admin, ctx.book, :site)
      assert {:ok, %{user_id: nil}} = Lore.transfer_book(admin, ctx.book, :site)
      assert [%Lore.BookRuleCondition{character_id: nil}] = Repo.all(Lore.BookRuleCondition)
    end

    test "only an admin moves its own book, never a site book, and never to personal", %{scope: admin} = ctx do
      own = book(ctx.user, "Diary")
      assert Lore.transfer_book(ctx.user, own, :site) == {:error, :unauthorized}

      {:ok, site} = Lore.transfer_book(admin, ctx.book, :site)
      assert Lore.transfer_book(admin, site, :site) == {:error, :same_owner}
      # A runtime atom: the compiler already knows no clause takes `:personal`.
      personal = String.to_existing_atom("personal")
      assert_raise FunctionClauseError, fn -> Lore.transfer_book(admin, site, personal) end
      assert_raise FunctionClauseError, fn -> Lore.transfer_impact(admin, site, personal) end
    end
  end

  describe "set_book_rules/3" do
    test "a site book may not name a chat", %{scope: admin} do
      site = book(admin, "Atlas", %{}, site: true)
      own = chat(admin, [character(admin, "C"), character(admin, "D")])

      params = %{
        "rules" => %{
          "0" => %{"enabled" => "true", "conditions" => %{"0" => %{"kind" => "chat", "chat_id" => own.id}}}
        }
      }

      assert {:error, changeset} = Lore.set_book_rules(admin, site, params)
      [rule] = Ecto.Changeset.get_change(changeset, :rules)
      [condition] = Ecto.Changeset.get_change(rule, :conditions)
      assert %{chat_id: ["is not a chat this book may name"]} = errors_on(condition)
    end

    test "replaces the saved rules even when the given book holds stale ones", %{scope: scope} do
      book = book(scope, "Rules")
      ref = character(scope, "R")

      rule = fn id ->
        %{"enabled" => "true", "conditions" => %{"0" => %{"kind" => "character_present", "character_id" => id}}}
      end

      assert {:ok, _} = Lore.set_book_rules(scope, book, %{"rules" => %{"0" => rule.(ref.id)}})
      book = Repo.preload(Repo.reload!(book), rules: :conditions)
      Enum.each(book.rules, &Repo.delete!/1)

      assert {:ok, _} = Lore.set_book_rules(scope, book, %{"rules" => %{"0" => rule.(ref.id)}})
      assert [%Lore.BookRule{} = saved] = Repo.all(Lore.BookRule)
      refute saved.id in Enum.map(book.rules, & &1.id)
    end

    test "a condition may not name another user's chat or character", %{scope: scope} do
      other = scope!(%{role: :user})
      book = book(scope, "Mine")
      theirs = character(other, "Theirs")
      their_chat = chat(other, [theirs, character(other, "Also")])

      condition = fn c -> %{"rules" => %{"0" => %{"enabled" => "true", "conditions" => %{"0" => c}}}} end

      assert {:error, changeset} =
               Lore.set_book_rules(scope, book, condition.(%{"kind" => "chat", "chat_id" => their_chat.id}))

      assert %{chat_id: ["is not a chat this book may name"]} = condition_errors(changeset)

      assert {:error, changeset} =
               Lore.set_book_rules(
                 scope,
                 book,
                 condition.(%{"kind" => "character_present", "character_id" => theirs.id})
               )

      assert %{character_id: ["is not a character this book may name"]} = condition_errors(changeset)
    end

    test "another user may not set a book's rules", %{scope: scope} do
      book = book(scope, "Mine")
      params = %{"rules" => %{"0" => %{"enabled" => "true", "conditions" => %{"0" => %{"kind" => "chat"}}}}}
      assert Lore.set_book_rules(scope!(%{role: :user}), book, params) == {:error, :unauthorized}
    end
  end

  describe "LoreEntry.outlet" do
    test "enum values stay in lockstep with Settings.outlets/0" do
      assert Ecto.Enum.values(LoreEntry, :outlet) == Settings.outlets()
    end
  end

  ## Helpers

  defp condition_errors(changeset) do
    [rule] = Ecto.Changeset.get_change(changeset, :rules)
    [condition] = Ecto.Changeset.get_change(rule, :conditions)
    errors_on(condition)
  end

  defp ids(books), do: books |> Enum.map(& &1.id) |> Enum.sort()

  defp book(scope, name, attrs \\ %{}, opts \\ []) do
    {:ok, book} = Lore.create_book(scope, Map.merge(%{name: name}, attrs), opts)
    book
  end

  defp entry(scope, name, book_ids, attrs \\ %{}, membership_attrs \\ %{}) do
    defaults = %{name: name, content: "#{name} content", keywords: [name]}
    {:ok, entry} = Lore.create_entry(scope, Map.merge(defaults, attrs), book_ids, membership_attrs)
    entry
  end

  defp membership_order(book, entry) do
    Repo.get_by!(BookEntry, lore_book_id: book.id, lore_entry_id: entry.id).order
  end

  defp book_ids(entry) do
    Repo.all(from(be in BookEntry, where: be.lore_entry_id == ^entry.id, select: be.lore_book_id)) |> Enum.sort()
  end

  defp character(scope, name, opts \\ []) do
    {:ok, character} = Characters.create_character(scope, %{name: name}, opts)
    character
  end

  defp chat(scope, [player | _] = characters) do
    {:ok, chat} =
      Chats.create_chat(scope, %{
        name: "chat-#{System.unique_integer([:positive])}",
        participants: Enum.map(characters, &%{character_id: &1.id}),
        player_character_id: player.id
      })

    Chats.get_chat!(chat.id)
  end
end
