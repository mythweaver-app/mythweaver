defmodule MythweaverWeb.LoreBookLiveTest do
  use MythweaverWeb.ConnCase

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Lore
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Memory.Record
  alias Mythweaver.Prompts
  alias Mythweaver.Repo
  alias Mythweaver.Schema

  setup :register_and_log_in_user

  defp book(scope, name, attrs \\ %{}, opts \\ []) do
    {:ok, book} = Lore.create_book(scope, Map.merge(%{name: name}, attrs), opts)
    book
  end

  # `order` is a membership field, so it is split off and applied to every book's membership.
  defp entry(scope, name, book_ids, attrs \\ %{}) do
    {order, attrs} = Map.pop(attrs, :order)

    {:ok, entry} =
      Lore.create_entry(
        scope,
        Map.merge(%{name: name, content: "#{name} content", keywords: ["dragon"]}, attrs),
        book_ids,
        if(order, do: %{order: order}, else: %{})
      )

    entry
  end

  defp book_orders(scope, book) do
    Enum.map(Lore.list_entries_in_book(scope, book), fn e ->
      {e.name, Enum.find(e.book_entries, &(&1.lore_book_id == book.id)).order}
    end)
  end

  defp character(scope, name) do
    {:ok, character} = Characters.create_character(scope, %{name: name})
    character
  end

  defp chat(scope, user, name) do
    a = character(scope, "Alice-#{System.unique_integer([:positive])}")
    b = character(scope, "Bob-#{System.unique_integer([:positive])}")

    {:ok, chat} =
      Chats.create_chat(Scope.for_user(user), %{
        name: name,
        participants: [%{character_id: a.id}, %{character_id: b.id}],
        player_character_id: a.id
      })

    Chats.get_chat!(chat.id)
  end

  # The entry form posts every field on submit, so a partial params map would clear unrelated
  # columns. These are the defaults every entry test starts from.
  defp entry_params(overrides) do
    Map.merge(
      %{
        "name" => "Dragons",
        "content" => "Dragons hoard gold",
        "activation" => "keyword",
        "keywords" => ["dragon"],
        "secondary_keywords" => [],
        "secondary_logic" => "and_any",
        "outlet" => "character",
        "placement" => "before",
        "depth" => "",
        "probability" => "100",
        "sticky" => "",
        "cooldown" => "",
        "delay" => "",
        "case_sensitive" => "",
        "match_whole_words" => "",
        "scan_depth" => "",
        "exclude_recursion" => "false",
        "prevent_recursion" => "false",
        "ignore_budget" => "false",
        "character_filter_mode" => "off"
      },
      overrides
    )
  end

  # Fills `#lore-entry-form` with `params` and submits or changes it. The keyword lists are chip
  # inputs whose hidden fields the TagInput hook fills, which `form/3` cannot set, so they go as the
  # event's own params, each led by the chip input's empty sentinel.
  defp submit_entry(view, params), do: entry_event(view, params, &render_submit/2)
  defp change_entry(view, params), do: entry_event(view, params, &render_change/2)

  defp entry_event(view, params, render) do
    {lists, fields} = Map.split(params, ["keywords", "secondary_keywords"])
    lists = Map.new(lists, fn {key, keywords} -> {key, ["" | keywords]} end)
    view |> form("#lore-entry-form", lore_entry: fields) |> render.(%{"lore_entry" => lists})
  end

  defp memberships(entry_id) do
    Repo.all(from(be in Lore.BookEntry, where: be.lore_entry_id == ^entry_id))
  end

  defp pool_membership(entry, pool), do: Repo.get_by!(Lore.PoolEntry, lore_entry_id: entry.id, lore_pool_id: pool.id)

  test "index selects nothing and lists every book", %{scope: scope, conn: conn} do
    book(scope, "Bestiary")
    book(scope, "Geography")
    [first, second] = Lore.list_books(scope)

    {:ok, view, _html} = live(conn, ~p"/lore")

    assert has_element?(view, "#lore-book-placeholder")
    refute has_element?(view, "#lore-book-form")
    assert has_element?(view, "#lore-tree-folder-#{first.id}")
    assert has_element?(view, "#lore-tree-folder-#{second.id}")
    refute has_element?(view, "#lore-tree-folder-#{first.id} summary[aria-current='page']")
    refute has_element?(view, "#lore-tree-folder-#{second.id} summary[aria-current='page']")
    assert has_element?(view, ".top-bar-nav a[href='/lore']")
  end

  test "the open book is marked current in the tree", %{scope: scope, conn: conn} do
    book(scope, "Bestiary")
    book(scope, "Geography")
    [first, second] = Lore.list_books(scope)

    {:ok, view, _html} = live(conn, ~p"/lore/#{first.id}/edit")

    assert has_element?(view, "#lore-tree-folder-#{first.id} summary[aria-current='page']")
    refute has_element?(view, "#lore-tree-folder-#{second.id} summary[aria-current='page']")
  end

  test "index selects nothing when there are no books", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/lore")
    assert has_element?(view, "#lore-book-placeholder")
  end

  test "creates a book from the new form, round-tripping every attribute", %{scope: scope, conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/lore/new")
    view |> form("#lore-book-form", %{"owner" => "site", "lore_book" => %{"name" => "Bestiary"}}) |> render_change()

    view
    |> form("#lore-book-form",
      owner: "site",
      lore_book: %{
        name: "Bestiary",
        description: "Monsters of the realm",
        priority: "5",
        order_adjustment: "-25",
        token_budget: "500",
        scan_depth: "7",
        # Every boolean is submitted opposite to its schema default, so a dropped field cannot
        # masquerade as a successful round trip.
        global: "true",
        recursive: "false",
        site_visibility: "runtime_only",
        forced: "true"
      }
    )
    |> render_submit()

    assert [created] = Lore.list_books(scope)
    reloaded = Lore.get_book!(created.id)
    assert reloaded.user_id == nil

    assert reloaded.name == "Bestiary"
    assert reloaded.description == "Monsters of the realm"
    assert reloaded.priority == 5
    assert reloaded.order_adjustment == -25
    assert reloaded.token_budget == 500
    assert reloaded.scan_depth == 7
    assert reloaded.global == true
    assert reloaded.recursive == false
    assert reloaded.site_visibility == :runtime_only
    assert reloaded.forced == true

    assert_patch(view, "/lore/#{created.id}/edit")
    assert has_element?(view, "#lore-tree-folder-#{created.id} summary[aria-current='page']")
  end

  test "an admin's new book is personal by default, marked in the tree and without site controls",
       %{scope: scope, conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/lore/new")
    refute has_element?(view, "#lore-book-form-site_visibility")
    refute has_element?(view, "#lore-book-form-forced")

    view |> form("#lore-book-form", %{"owner" => "site", "lore_book" => %{"name" => "Notes"}}) |> render_change()
    assert has_element?(view, "#lore-book-form-site_visibility")
    assert has_element?(view, "#lore-book-form-forced")

    view |> form("#lore-book-form", %{"owner" => "personal", "lore_book" => %{"name" => "Notes"}}) |> render_change()
    refute has_element?(view, "#lore-book-form-site_visibility")
    refute has_element?(view, "#lore-book-form-forced")

    view |> form("#lore-book-form", %{"owner" => "personal", "lore_book" => %{"name" => "Notes"}}) |> render_submit()
    {:ok, site} = Lore.create_book(scope, %{name: "Shared"}, site: true)

    assert [%{name: "Notes"} = own] = Enum.filter(Lore.list_books(scope), &(&1.user_id != nil))
    assert own.user_id == scope.user.id

    {:ok, view, _html} = live(conn, ~p"/lore/#{own.id}/edit")
    assert has_element?(view, "#lore-tree-personal-#{own.id}")
    refute has_element?(view, "#lore-tree-personal-#{site.id}")
    refute has_element?(view, "#lore-book-form-owner")
  end

  test "an admin moves their own book to the site after a warning naming what breaks, and never back", %{
    scope: scope,
    conn: conn
  } do
    vault = book(scope, "Vault")
    {:ok, hero} = Mythweaver.Characters.create_character(scope, %{name: "Hero"})
    {:ok, _} = Lore.bind_book_to_character(vault, hero.id)

    {:ok, view, _html} = live(conn, ~p"/lore/#{vault.id}/edit")
    assert has_element?(view, "#lore-tree-personal-#{vault.id}")

    view |> element("#lore-book-transfer", "Make site book") |> render_click()
    assert has_element?(view, "#lore-book-transfer-warnings li", "Bindings to personal characters are removed: 1.")
    assert Lore.get_book!(vault.id).user_id == scope.user.id

    view |> element("#lore-book-transfer-confirm") |> render_click()
    assert Lore.get_book!(vault.id).user_id == nil
    refute has_element?(view, "#lore-tree-personal-#{vault.id}")
    assert has_element?(view, "#lore-book-owner-label", "Site book")
    refute has_element?(view, "#lore-book-transfer")
  end

  test "invalid submission keeps the form open and creates nothing", %{scope: scope, conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/lore/new")

    view |> form("#lore-book-form", lore_book: %{name: ""}) |> render_submit()

    assert has_element?(view, "#lore-book-form")
    assert Lore.list_books(scope) == []
  end

  # Mirrors `LoreBook.changeset/2`. `order_adjustment` is the one that must stay signed: a bare
  # `min="1"` here would make every negative adjustment unenterable.
  test "numeric book fields carry bounds matching their changeset rules", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/lore/new")

    for field <- ~w(token_budget scan_depth) do
      assert has_element?(view, "#lore-book-form-#{field}[type='number'][min='1']")
    end

    assert has_element?(
             view,
             "#lore-book-form-order_adjustment[type='number'][min='-10000'][max='10000']"
           )
  end

  test "edits an existing book and stays on it", %{scope: scope, conn: conn} do
    bestiary = book(scope, "Bestiary")

    {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/edit")

    view |> form("#lore-book-form", lore_book: %{name: "Renamed"}) |> render_submit()

    assert_patch(view, "/lore/#{bestiary.id}/edit")
    assert Lore.get_book!(bestiary.id).name == "Renamed"
    assert has_element?(view, "#lore-book-form-name[value='Renamed']")
  end

  test "deletes a book with no entries", %{scope: scope, conn: conn} do
    bestiary = book(scope, "Bestiary")

    {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/edit")

    view |> element("#delete-lore-book") |> render_click()

    assert_patch(view, ~p"/lore")
    assert has_element?(view, "#lore-book-placeholder")
    refute has_element?(view, "#lore-tree-folder-#{bestiary.id}")
    assert Lore.get_book(scope, bestiary.id) == nil
  end

  test "deleting a book that exclusively owns entries leaves them unlinked", %{scope: scope, conn: conn} do
    bestiary = book(scope, "Bestiary")
    dragons = entry(scope, "Dragons", [bestiary.id])

    {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/edit")

    view |> element("#delete-lore-book") |> render_click()

    assert Lore.get_book(scope, bestiary.id) == nil
    assert has_element?(view, "#lore-tree-unlinked-#{dragons.id}")
  end

  test "editing an unknown book id flashes not found instead of crashing", %{scope: scope, conn: conn} do
    # A syntactically valid UUID: a malformed one would fail to cast rather than miss the row.
    unknown = Schema.generate_id()

    # Cold mount: `apply_action(:edit)`'s `push_patch(to: ~p"/lore")` during the initial
    # `handle_params` is delivered as a live redirect carrying the flash.
    assert {:error, {:live_redirect, %{to: "/lore", flash: flash}}} =
             live(conn, ~p"/lore/#{unknown}/edit")

    assert flash["error"] == "Lore book not found"

    # Warm patch from a real book's page: the not-found patch lands on `/lore`, which selects
    # nothing.
    real = book(scope, "Bestiary")
    {:ok, view, _html} = live(conn, ~p"/lore/#{real.id}/edit")
    render_patch(view, ~p"/lore/#{unknown}/edit")

    assert_patch(view, ~p"/lore")
    assert has_element?(view, "#lore-book-placeholder")
    assert render(view) =~ "Lore book not found"
  end

  describe "as a user" do
    test "lists and edits only their own books; a site book does not open", %{scope: admin} do
      user = register_user!(%{role: :user})
      conn = log_in_user(Phoenix.ConnTest.build_conn(), user)
      site = book(admin, "Site")
      own = book(Scope.for_user(user), "Own")

      {:ok, view, _html} = live(conn, ~p"/lore/#{own.id}/edit")
      assert has_element?(view, "#lore-tree-folder-#{own.id}")
      refute has_element?(view, "#lore-tree-folder-#{site.id}")

      assert {:error, {:live_redirect, %{to: "/lore", flash: flash}}} = live(conn, ~p"/lore/#{site.id}/edit")
      assert flash["error"] == "Lore book not found"
    end

    test "a user's own book offers no visibility or forcing controls" do
      user = register_user!(%{role: :user})
      conn = log_in_user(Phoenix.ConnTest.build_conn(), user)
      own = book(Scope.for_user(user), "Own")

      {:ok, view, _html} = live(conn, ~p"/lore/#{own.id}/edit")
      assert has_element?(view, "#lore-book-form")
      refute has_element?(view, "#lore-book-form-site_visibility")
      refute has_element?(view, "#lore-book-form-forced")
    end
  end

  describe "lore tree" do
    test "renders a folder per book and an Unlinked folder for bookless entries", %{scope: scope, conn: conn} do
      bestiary = book(scope, "Bestiary")
      loose = entry(scope, "Loose", [])

      {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/edit")

      assert has_element?(view, "#lore-tree-folder-#{bestiary.id}")
      assert has_element?(view, "#lore-tree-folder-unlinked #lore-tree-unlinked-#{loose.id}")
    end

    test "an entry in two books shows in both, each marked as shared", %{scope: scope, conn: conn} do
      b1 = book(scope, "Bestiary")
      b2 = book(scope, "Geography")
      e = entry(scope, "Dragons", [b1.id, b2.id])

      {:ok, view, _html} = live(conn, ~p"/lore/#{b1.id}/edit")

      assert has_element?(view, "#lore-tree-#{b1.id}-#{e.id} [aria-label='In 2 books']")
      assert has_element?(view, "#lore-tree-#{b2.id}-#{e.id} [aria-label='In 2 books']")
    end

    test "a drop moves the entry between folders; a copy drop keeps it in both", %{scope: scope, conn: conn} do
      b1 = book(scope, "Bestiary")
      b2 = book(scope, "Geography")
      e = entry(scope, "Dragons", [b1.id])

      {:ok, view, _html} = live(conn, ~p"/lore/#{b1.id}/edit")

      render_hook(view, "place_entry", %{
        "entry_id" => e.id,
        "from" => b1.id,
        "to" => b2.id,
        "copy" => false,
        "ids" => [e.id]
      })

      assert has_element?(view, "#lore-tree-#{b2.id}-#{e.id}")
      refute has_element?(view, "#lore-tree-#{b1.id}-#{e.id}")
      # The open book's table follows the tree.
      refute has_element?(view, "#lore-entries-#{e.id}")

      render_hook(view, "place_entry", %{
        "entry_id" => e.id,
        "from" => b2.id,
        "to" => b1.id,
        "copy" => true,
        "ids" => [e.id]
      })

      assert has_element?(view, "#lore-tree-#{b1.id}-#{e.id}")
      assert has_element?(view, "#lore-tree-#{b2.id}-#{e.id}")
    end

    test "a drop into Unlinked removes the entry from its book", %{scope: scope, conn: conn} do
      b1 = book(scope, "Bestiary")
      e = entry(scope, "Dragons", [b1.id])

      {:ok, view, _html} = live(conn, ~p"/lore/#{b1.id}/edit")
      render_hook(view, "place_entry", %{"entry_id" => e.id, "from" => b1.id, "to" => "", "copy" => false, "ids" => []})

      assert has_element?(view, "#lore-tree-unlinked-#{e.id}")
      assert memberships(e.id) == []
    end

    test "a drop of a deleted entry flashes instead of crashing", %{scope: scope, conn: conn} do
      b1 = book(scope, "Bestiary")
      {:ok, view, _html} = live(conn, ~p"/lore/#{b1.id}/edit")

      render_hook(view, "place_entry", %{
        "entry_id" => Schema.generate_id(),
        "from" => "",
        "to" => b1.id,
        "copy" => false,
        "ids" => []
      })

      assert render(view) =~ "That entry or book no longer exists"
    end

    test "a search replaces the tree with matching books and entries", %{scope: scope, conn: conn} do
      b1 = book(scope, "Bestiary")
      e = entry(scope, "Wyverns", [b1.id])
      other = entry(scope, "Griffons", [])

      {:ok, view, _html} = live(conn, ~p"/lore/#{b1.id}/edit")
      refute has_element?(view, "#lore-search-results")

      view |> form("#lore-book-filter", %{query: "wyv"}) |> render_change()

      assert has_element?(view, "#lore-tree[hidden]")
      assert has_element?(view, "#lore-search-results #lore-search-entry-#{e.id}")
      refute has_element?(view, "#lore-search-entry-#{other.id}")
    end
  end

  describe "entry editor" do
    test "a new entry with no books saves unlinked and opens its editor", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/lore/entries/new")

      submit_entry(view, entry_params(%{}))

      [entry] = Repo.all(LoreEntry)
      assert_patch(view, ~p"/lore/entries/#{entry.id}/edit")
      assert has_element?(view, "#lore-tree-unlinked-#{entry.id}")
      assert memberships(entry.id) == []
    end

    test "?book= preselects that book", %{scope: scope, conn: conn} do
      b1 = book(scope, "Bestiary")

      {:ok, view, _html} = live(conn, ~p"/lore/entries/new?#{[book: b1.id]}")

      assert has_element?(view, "#lore-entry-form-books-#{b1.id}[checked]")
    end

    test "deleting from the entry editor goes back to /lore", %{scope: scope, conn: conn} do
      e = entry(scope, "Loose", [])

      {:ok, view, _html} = live(conn, ~p"/lore/entries/#{e.id}/edit")
      view |> element("#delete-lore-entry") |> render_click()

      # `/lore` is `:index`, which selects nothing: the editor pane shows the placeholder.
      assert_patch(view, ~p"/lore")
      assert has_element?(view, "#lore-book-placeholder")
      refute has_element?(view, "#lore-tree-unlinked-#{e.id}")
      assert Lore.get_entry(scope, e.id) == nil
    end

    test "an unknown entry id flashes not found", %{scope: scope, conn: conn} do
      b1 = book(scope, "Bestiary")
      {:ok, view, _html} = live(conn, ~p"/lore/#{b1.id}/edit")

      render_patch(view, ~p"/lore/entries/#{Schema.generate_id()}/edit")

      assert render(view) =~ "Lore entry not found"
    end

    test "the memory group turns an entry into an Arc of the picked memories", %{scope: scope, conn: conn} do
      saga = book(scope, "Saga")
      memory = entry(scope, "001 - Scene", [saga.id])
      arc = entry(scope, "[ARC 001] - Arc", [saga.id])
      {:ok, _} = Mythweaver.Memory.mark_as_memories(scope, saga, [memory.id, arc.id])
      source = Repo.get_by!(Record, lore_entry_id: memory.id)

      {:ok, view, _html} = live(conn, ~p"/lore/entries/#{arc.id}/edit")
      assert has_element?(view, "#lore-entry-form-memory:not([open])")
      refute has_element?(view, "#lore-entry-form-memory-sources")

      params = entry_params(%{"name" => arc.name, "memory" => %{"tier" => "1", "sequence" => "1"}})
      change_entry(view, params)
      assert has_element?(view, "#lore-entry-form-memory-sources-option-#{source.id}")

      refute has_element?(
               view,
               "#lore-entry-form-memory-sources-option-#{Repo.get_by!(Record, lore_entry_id: arc.id).id}"
             )

      params = put_in(params, ["memory", "source_ids"], [source.id])
      submit_entry(view, params)
      assert_patch(view, ~p"/lore/entries/#{arc.id}/edit")

      record = Repo.get_by!(Record, lore_entry_id: arc.id)
      assert %Record{kind: :consolidation, tier: 1, sequence: 1} = record
      assert Repo.get!(Record, source.id).consolidated_into_id == record.id
      assert has_element?(view, "#lore-entry-form-memory-sources-#{source.id}[checked]")
    end

    test "Compact replaces the form's Content unsaved, keeping its other edits",
         %{scope: scope, conn: conn} = context do
      Req.Test.set_req_test_to_shared(context)
      :ok = Mythweaver.Jobs.subscribe(scope)
      compaction_profile!(scope)
      test = self()

      Req.Test.stub(Mythweaver.AI, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:request, body})
        stream_reply(conn, "Short.")
      end)

      bestiary = book(scope, "Bestiary")
      dragons = entry(scope, "Dragons", [bestiary.id])

      {:ok, view, _html} = live(conn, ~p"/lore/entries/#{dragons.id}/edit")

      params = entry_params(%{"name" => "Wyrms", "content" => "Long wordy text.", "books" => [bestiary.id]})
      change_entry(view, params)
      view |> element("#lore-entry-form-compact") |> render_click()
      assert has_element?(view, "#lore-entry-form-compact[disabled]")

      assert_receive {:job_changed, %{status: :completed}}, 2000
      assert_received {:request, body}
      assert body =~ "Long wordy text."

      assert has_element?(view, "#lore-entry-form-content[data-value='Short.']")
      assert has_element?(view, "#lore-entry-form-name[value='Wyrms']")
      assert has_element?(view, "#lore-entry-form:not([data-saved])")
      refute has_element?(view, "#lore-entry-form-compact[disabled]")
      assert Lore.get_entry!(dragons.id).content == "Dragons content"
    end

    test "Diff shows a saved entry's stored Content against the form's; a new entry has none",
         %{scope: scope, conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/lore/entries/new")
      refute has_element?(view, "#lore-entry-form-diff-toggle")

      dragons = entry(scope, "Dragons", [])
      {:ok, view, _html} = live(conn, ~p"/lore/entries/#{dragons.id}/edit")
      refute has_element?(view, "#lore-entry-form-diff")

      view |> element("#lore-entry-form-diff-toggle") |> render_click()
      params = entry_params(%{"name" => "Dragons", "content" => "Dragons hoard"})
      change_entry(view, params)

      assert has_element?(view, "#lore-entry-form-diff ins", "hoard")
      assert has_element?(view, "#lore-entry-form-diff del", "content")
      assert has_element?(view, "#lore-entry-form-diff-toggle[aria-pressed='true']")

      view |> element("#lore-entry-form-diff-toggle") |> render_click()
      refute has_element?(view, "#lore-entry-form-diff")
    end

    test "the Content's token count shows above the box and follows edits", %{scope: scope, conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/lore/entries/new")
      assert has_element?(view, "#lore-entry-form-content-tokens", "0 tokens")

      dragons = entry(scope, "Dragons", [])
      {:ok, view, _html} = live(conn, ~p"/lore/entries/#{dragons.id}/edit")

      # No model here, so the count is the estimate.
      saved = "≈#{Mythweaver.Tokenizer.estimate(dragons.content)} tokens"
      assert has_element?(view, "#lore-entry-form-content-tokens", saved)

      longer = String.duplicate("Dragons hoard gold beneath the mountain. ", 20)
      change_entry(view, entry_params(%{"content" => longer}))

      assert has_element?(view, "#lore-entry-form-content-tokens", "≈#{Mythweaver.Tokenizer.estimate(longer)} tokens")
    end

    test "Compact with no memory profile flashes why", %{scope: scope, conn: conn} do
      dragons = entry(scope, "Dragons", [])

      {:ok, view, _html} = live(conn, ~p"/lore/entries/#{dragons.id}/edit")

      assert view |> element("#lore-entry-form-compact") |> render_click() =~ "No memory profile is set."
    end

    test "a save elsewhere reloads the untouched entry editor", %{scope: scope, conn: conn} do
      dragons = entry(scope, "Dragons", [])

      {:ok, view, _html} = live(conn, ~p"/lore/entries/#{dragons.id}/edit")
      {:ok, _entry} = Lore.update_entry(scope, dragons, %{content: "Rewritten"})

      assert has_element?(view, "#lore-entry-form-content[data-value='Rewritten']")
      refute has_element?(view, "#lore-changed-elsewhere")
    end

    test "a save elsewhere flags an edited entry and keeps its edits", %{scope: scope, conn: conn} do
      dragons = entry(scope, "Dragons", [])

      {:ok, view, _html} = live(conn, ~p"/lore/entries/#{dragons.id}/edit")
      change_entry(view, entry_params(%{"name" => "Typed"}))
      {:ok, _entry} = Lore.update_entry(scope, dragons, %{content: "Rewritten"})

      assert has_element?(view, "#lore-changed-elsewhere")
      assert has_element?(view, "#lore-entry-form-name[value='Typed']")

      view |> element("#lore-changed-elsewhere-reload") |> render_click()

      assert_patch(view, ~p"/lore/entries/#{dragons.id}/edit")
      assert has_element?(view, "#lore-entry-form-content[data-value='Rewritten']")
      refute has_element?(view, "#lore-changed-elsewhere")
    end

    test "an entry deleted elsewhere closes its editor", %{scope: scope, conn: conn} do
      dragons = entry(scope, "Dragons", [])

      {:ok, view, _html} = live(conn, ~p"/lore/entries/#{dragons.id}/edit")
      {:ok, _entry} = Lore.delete_entry(scope, dragons)

      assert_patch(view, ~p"/lore")
      assert has_element?(view, "#lore-book-placeholder")
    end

    test "a save elsewhere reloads the book's open inline entry row", %{scope: scope, conn: conn} do
      bestiary = book(scope, "Bestiary")
      dragons = entry(scope, "Dragons", [bestiary.id])

      {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/entries/#{dragons.id}/edit")
      {:ok, _entry} = Lore.update_entry(scope, dragons, %{content: "Rewritten"})

      assert has_element?(view, "#lore-entry-form-content[data-value='Rewritten']")
    end

    test "a pool member's weight and flags save from its pool row; a blank weight keeps the stored one",
         %{scope: scope, conn: conn} do
      {:ok, pool} = Lore.create_pool(scope, %{name: "Weather"})
      rain = entry(scope, "Rain", [])
      {:ok, :ok} = Lore.set_entry_pools(scope, rain, [pool.id])

      {:ok, view, _html} = live(conn, ~p"/lore/entries/#{rain.id}/edit")
      assert has_element?(view, "#lore-entry-form-pool-#{pool.id}-weight[value='100']")

      settings = %{pool.id => %{"weight" => "7", "override" => "true", "scored" => "false"}}
      params = entry_params(%{"name" => "Rain", "pools" => [pool.id], "pool_settings" => settings})
      change_entry(view, params)
      submit_entry(view, params)

      assert %{weight: 7, override: true, scored: false} = pool_membership(rain, pool)

      submit_entry(view, put_in(params, ["pool_settings", pool.id, "weight"], ""))

      assert %{weight: 7, override: true} = pool_membership(rain, pool)
    end

    test "picking a pool shows its row with the default weight", %{scope: scope, conn: conn} do
      {:ok, pool} = Lore.create_pool(scope, %{name: "Weather"})
      rain = entry(scope, "Rain", [])

      {:ok, view, _html} = live(conn, ~p"/lore/entries/#{rain.id}/edit")
      refute has_element?(view, "#lore-entry-form-pool-settings")

      change_entry(view, entry_params(%{"name" => "Rain", "pools" => [pool.id]}))

      assert has_element?(view, "#lore-entry-form-pool-#{pool.id}-weight[value='100']")
      refute has_element?(view, "#lore-entry-form-pool-#{pool.id}-override[checked]")
    end

    test "New pool creates a pool of the entry's owner and picks it, joined on save", %{scope: scope, conn: conn} do
      rain = entry(scope, "Rain", [])

      {:ok, view, _html} = live(conn, ~p"/lore/entries/#{rain.id}/edit")
      view |> element("#lore-entry-form-new-pool") |> render_click()
      assert has_element?(view, "#lore-entry-new-pool-modal")

      view |> form("#lore-entry-new-pool-form", lore_pool: %{name: ""}) |> render_submit()
      assert has_element?(view, "#lore-entry-new-pool-modal")
      assert Lore.list_pools(scope) == []

      view |> form("#lore-entry-new-pool-form", lore_pool: %{name: "Moods", max_activations: "2"}) |> render_submit()

      assert [%{name: "Moods", max_activations: 2} = pool] = Lore.list_pools(scope)
      assert pool.user_id == scope.user.id
      refute has_element?(view, "#lore-entry-new-pool-modal")
      assert has_element?(view, "#lore-entry-form-pools-#{pool.id}[checked]")
      assert has_element?(view, "#lore-entry-form-pool-#{pool.id}-weight[value='100']")
      refute has_element?(view, "#lore-entry-form[data-saved]")
      assert Repo.get_by(Lore.PoolEntry, lore_entry_id: rain.id) == nil

      submit_entry(view, entry_params(%{"name" => "Rain", "pools" => [pool.id]}))

      assert %{weight: 100} = pool_membership(rain, pool)
    end

    test "an editor of a shared book gets no New pool, and creating one is refused", %{scope: scope, conn: conn} do
      owner = Mythweaver.DataCase.scope!(%{role: :user})
      shared = book(owner, "Shared")
      rain = entry(owner, "Rain", [shared.id])
      {:ok, share} = Mythweaver.Sharing.invite(owner, shared, "@" <> scope.user.handle)
      {:ok, _share} = Mythweaver.Sharing.accept(scope, share.id)

      {:ok, view, _html} = live(conn, ~p"/lore/entries/#{rain.id}/edit")
      assert has_element?(view, "#lore-entry-form-pools")
      refute has_element?(view, "#lore-entry-form-new-pool")

      render_hook(view, "create_entry_pool", %{"lore_pool" => %{"name" => "Moods"}})

      assert Lore.list_pools(scope) == []
      assert Lore.list_pools(owner) == []
    end

    test "the list header switches to the pool editor", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/lore")
      assert has_element?(view, "#pane-switch-pools[href='/lore/pools']")
    end

    test "a card book's editor carries the Card book badge; a lore book's does not", %{scope: scope, conn: conn} do
      card = book(scope, "Ann (card)", %{kind: :card}, import: true)
      lore = book(scope, "Bestiary")

      {:ok, view, _html} = live(conn, ~p"/lore/#{card.id}/edit")
      assert has_element?(view, "#lore-book-card-badge", "Card book")

      {:ok, view, _html} = live(conn, ~p"/lore/#{lore.id}/edit")
      refute has_element?(view, "#lore-book-card-badge")
    end
  end

  # A linked model and a default memory profile whose compaction prompt sends the entry's content.
  defp compaction_profile!(scope) do
    {:ok, provider} =
      Mythweaver.AI.create_provider(scope, %{
        name: "Local-#{System.unique_integer([:positive])}",
        adapter: :openai_compatible,
        base_url: "http://localhost:8080/v1"
      })

    {:ok, model} = Mythweaver.AI.create_model(scope, %{name: "Gemma", api_model_id: "gemma-4"})
    {:ok, _link} = Mythweaver.AI.link_model(scope, provider, model)

    {:ok, prompt} = Prompts.create_prompt(scope, %{name: "Compact", purpose: :compaction})

    {:ok, block} =
      Prompts.create_block(scope, %{name: "Material", role: :user, content: "{{ anchors.memory.entry.content }}"})

    {:ok, _} = Prompts.add_block(scope, prompt, block)

    {:ok, profile} =
      Mythweaver.Memory.create_profile(scope, %{name: "Default", ai_model_id: model.id, compaction_prompt_id: prompt.id})

    {:ok, _profile} = Mythweaver.Memory.set_default_profile(scope, profile)
  end

  defp stream_reply(conn, text) do
    frames = [
      "data: #{Jason.encode!(%{choices: [%{index: 0, delta: %{content: text}, finish_reason: nil}]})}\n\n",
      ~s(data: {"choices":[{"finish_reason":"stop","index":0,"delta":{}}]}\n\n),
      "data: [DONE]\n\n"
    ]

    Enum.reduce(frames, Plug.Conn.send_chunked(conn, 200), fn frame, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, frame)
      conn
    end)
  end

  describe "entries and bindings" do
    test "shows a row per entry in the book", %{scope: scope, conn: conn} do
      bestiary = book(scope, "Bestiary")
      dragons = entry(scope, "Dragons", [bestiary.id])
      griffons = entry(scope, "Griffons", [bestiary.id])

      {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/edit")

      assert has_element?(view, "#lore-entries-#{dragons.id}")
      assert has_element?(view, "#lore-entries-#{griffons.id}")
    end

    test "creates an entry from its keyword chips with exactly one membership",
         %{conn: conn, scope: scope} do
      bestiary = book(scope, "Bestiary")

      {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/entries/new")

      submit_entry(view, entry_params(%{"keywords" => ["dragon", "hoard"]}))

      assert [created] = Lore.list_entries(scope)
      assert created.keywords == ["dragon", "hoard"]

      assert [membership] = memberships(created.id)
      assert membership.lore_book_id == bestiary.id

      assert_patch(view, "/lore/#{bestiary.id}/entries/#{created.id}/edit")
      assert has_element?(view, "#lore-entries-#{created.id}")
    end

    test "blank and whitespace-only keyword elements are dropped", %{scope: scope, conn: conn} do
      bestiary = book(scope, "Bestiary")

      {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/entries/new")

      submit_entry(view, entry_params(%{"keywords" => ["dragon", "", "  ", " hoard "]}))

      assert [created] = Lore.list_entries(scope)
      assert created.keywords == ["dragon", "hoard"]
    end

    test "outlet and placement round-trip through the form", %{scope: scope, conn: conn} do
      bestiary = book(scope, "Bestiary")

      {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/entries/new")

      submit_entry(view, entry_params(%{"outlet" => "author_note", "placement" => "after"}))

      assert [created] = Lore.list_entries(scope)
      assert created.outlet == :author_note
      assert created.placement == :after
      assert LoreEntry.slot(created) == "after_author_note"
    end

    test "a rejected save keeps the form, flashes, and marks the offending field", %{scope: scope, conn: conn} do
      bestiary = book(scope, "Bestiary")

      {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/entries/new")

      submit_entry(view, entry_params(%{"scan_depth" => "0"}))

      assert Lore.list_entries(scope) == []
      assert has_element?(view, "#flash-error")
      assert has_element?(view, "#lore-entry-form-scan_depth[aria-invalid='true']")
      assert has_element?(view, "#lore-entry-form")
    end

    # The `min`/`max` attributes are a client-side mirror of `LoreEntry.changeset/2`. A floor that
    # disagrees with the changeset is worse than none: it either blocks a legal value outright
    # (`probability: 0`) or promises a value the server then rejects.
    test "numeric entry fields carry bounds matching their changeset rules", %{scope: scope, conn: conn} do
      bestiary = book(scope, "Bestiary")

      {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/entries/new")

      # greater_than: 0. Blank means "inherit", so the floor is 1
      for field <- ~w(scan_depth sticky cooldown delay) do
        assert has_element?(view, "#lore-entry-form-#{field}[type='number'][min='1']")
      end

      # greater_than_or_equal_to: 0. Zero is a legal value here
      for field <- ~w(depth) do
        assert has_element?(view, "#lore-entry-form-#{field}[type='number'][min='0']")
      end

      # 0..100 inclusive; probability: 0 is a supported "never activates" setting
      assert has_element?(
               view,
               "#lore-entry-form-probability[type='number'][min='0'][max='100']"
             )
    end

    test "editing shows the keywords as chips and saves a changed list", %{scope: scope, conn: conn} do
      bestiary = book(scope, "Bestiary")
      dragons = entry(scope, "Dragons", [bestiary.id], %{keywords: ["dragon", "hoard"]})

      {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/entries/#{dragons.id}/edit")

      assert has_element?(view, "#lore-entry-form-keywords-chips li[data-tag='dragon']")
      assert has_element?(view, "#lore-entry-form-keywords-chips li[data-tag='hoard']")

      submit_entry(view, entry_params(%{"keywords" => ["wyvern", "lair"], "name" => "Dragons"}))

      assert Lore.get_entry!(dragons.id).keywords == ["wyvern", "lair"]
    end

    test "remove_from_book on the entry's only book unlinks it", %{scope: scope, conn: conn} do
      bestiary = book(scope, "Bestiary")
      dragons = entry(scope, "Dragons", [bestiary.id])

      {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/edit")

      view
      |> element("#lore-entries-#{dragons.id} button[phx-click=remove_from_book]")
      |> render_click()

      refute has_element?(view, "#lore-entries-#{dragons.id}")
      assert has_element?(view, "#lore-tree-unlinked-#{dragons.id}")
      assert memberships(dragons.id) == []
    end

    test "remove_from_book drops the row when the entry is in two books", %{scope: scope, conn: conn} do
      bestiary = book(scope, "Bestiary")
      archive = book(scope, "Archive")
      dragons = entry(scope, "Dragons", [bestiary.id, archive.id])

      {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/edit")

      view
      |> element("#lore-entries-#{dragons.id} button[phx-click=remove_from_book]")
      |> render_click()

      refute has_element?(view, "#lore-entries-#{dragons.id}")
      assert Lore.get_entry(scope, dragons.id) != nil
      assert [remaining] = memberships(dragons.id)
      assert remaining.lore_book_id == archive.id
    end

    test "the row checkbox switches the entry off in this book only, and back on", %{scope: scope, conn: conn} do
      bestiary = book(scope, "Bestiary")
      archive = book(scope, "Archive")
      dragons = entry(scope, "Dragons", [bestiary.id, archive.id])

      {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/edit")
      view |> element("#lore-entries-#{dragons.id}-in-book") |> render_click()

      refute has_element?(view, "#lore-entries-#{dragons.id}-in-book[checked]")
      assert has_element?(view, "#lore-entries-#{dragons.id}.lore-entry-row--off")
      by_book = Map.new(memberships(dragons.id), &{&1.lore_book_id, &1.enabled})
      assert by_book == %{bestiary.id => false, archive.id => true}
      # The tree dims the row in that book only.
      assert has_element?(view, "#lore-tree-#{bestiary.id}-#{dragons.id}.lore-tree-entry--off")
      refute has_element?(view, "#lore-tree-#{archive.id}-#{dragons.id}.lore-tree-entry--off")

      view |> element("#lore-entries-#{dragons.id}-in-book") |> render_click()
      assert has_element?(view, "#lore-entries-#{dragons.id}-in-book[checked]")
      assert Enum.all?(memberships(dragons.id), & &1.enabled)
    end

    test "rows start collapsed; the chevron opens the shared form inside the row and closes it", %{
      scope: scope,
      conn: conn
    } do
      bestiary = book(scope, "Bestiary")
      dragons = entry(scope, "Dragons", [bestiary.id])

      {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/edit")
      refute has_element?(view, "#lore-entry-form")

      view |> element("#lore-entries-#{dragons.id}-expand") |> render_click()
      assert_patch(view, ~p"/lore/#{bestiary.id}/entries/#{dragons.id}/edit")
      assert has_element?(view, "#lore-entries-#{dragons.id} #lore-entry-form")

      # Typing updates the open row's form through `send_update/2` (`InlineEntryForm`), which
      # LiveViewTest does not patch into an already-inserted stream row, so the inline form's
      # validation is not asserted here.

      view |> element("#lore-entries-#{dragons.id}-expand") |> render_click()
      assert_patch(view, ~p"/lore/#{bestiary.id}/edit")
      refute has_element?(view, "#lore-entry-form")
    end

    test "dragging renumbers the book's entries serially from the bottom, whatever they were", %{
      scope: scope,
      conn: conn
    } do
      bestiary = book(scope, "Bestiary")

      [a, b, c] =
        for {name, order} <- [{"A", 900}, {"B", 50}, {"C", 7}], do: entry(scope, name, [bestiary.id], %{order: order})

      {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/edit")
      render_hook(view, "reorder_entries", %{"ids" => [c.id, a.id, b.id]})

      assert book_orders(scope, Lore.get_book!(bestiary.id)) == [{"C", 3}, {"A", 2}, {"B", 1}]
    end

    test "the order cell sets this book's membership order and refuses a negative one", %{scope: scope, conn: conn} do
      bestiary = book(scope, "Bestiary")
      archive = book(scope, "Archive")
      dragons = entry(scope, "Dragons", [bestiary.id, archive.id], %{order: 5})

      {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/edit")

      view |> form("#lore-entries-#{dragons.id}-order-form", %{order: "42"}) |> render_submit()
      assert book_orders(scope, Lore.get_book!(bestiary.id)) == [{"Dragons", 42}]
      assert book_orders(scope, Lore.get_book!(archive.id)) == [{"Dragons", 5}]

      html = view |> form("#lore-entries-#{dragons.id}-order-form", %{order: "-1"}) |> render_submit()
      assert html =~ "Order must be a whole number, 0 or more"
      assert book_orders(scope, Lore.get_book!(bestiary.id)) == [{"Dragons", 42}]
    end

    test "a column sort reorders the rows for viewing only and turns dragging off", %{scope: scope, conn: conn} do
      bestiary = book(scope, "Bestiary")
      [a, b] = for {name, order} <- [{"Zeta", 2}, {"Alpha", 1}], do: entry(scope, name, [bestiary.id], %{order: order})

      {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/edit")
      assert has_element?(view, "#lore-entries[data-sortable-disabled='false']")

      view |> element("#lore-entries-sort-name") |> render_click()
      assert has_element?(view, "#lore-entries[data-sortable-disabled='true']")
      assert has_element?(view, "#lore-entries-sorted")

      # A drop sent anyway (a stale tab) is refused while the sort is shown.
      render_hook(view, "reorder_entries", %{"ids" => [b.id, a.id]})

      assert book_orders(scope, Lore.get_book!(bestiary.id)) == [{"Zeta", 2}, {"Alpha", 1}]

      view |> element("#lore-entries-clear-sort") |> render_click()
      assert has_element?(view, "#lore-entries[data-sortable-disabled='false']")
    end

    test "remove_from_book closes the open form for that entry", %{scope: scope, conn: conn} do
      bestiary = book(scope, "Bestiary")
      archive = book(scope, "Archive")
      dragons = entry(scope, "Dragons", [bestiary.id, archive.id])

      {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/entries/#{dragons.id}/edit")

      view
      |> element("#lore-entries-#{dragons.id} button[phx-click=remove_from_book]")
      |> render_click()

      assert_patch(view, ~p"/lore/#{bestiary.id}/edit")
      assert Enum.map(memberships(dragons.id), & &1.lore_book_id) == [archive.id]
    end

    test "delete_entry removes the row and the record", %{scope: scope, conn: conn} do
      bestiary = book(scope, "Bestiary")
      dragons = entry(scope, "Dragons", [bestiary.id])

      {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/edit")

      view
      |> element("#lore-entries-#{dragons.id} button[phx-click=delete_entry]")
      |> render_click()

      refute has_element?(view, "#lore-entries-#{dragons.id}")
      assert Lore.get_entry(scope, dragons.id) == nil
    end

    test "collapsed rows show no entry content, so a hidden-content book leaks none", %{scope: scope, conn: conn} do
      locked = book(scope, "Locked", %{site_visibility: :runtime_only}, site: true)
      hidden = entry(scope, "Hidden", [locked.id], %{content: "the secret hoard"})

      {:ok, view, _html} = live(conn, ~p"/lore/#{locked.id}/edit")

      assert has_element?(view, "#lore-entries-#{hidden.id}", "Hidden")
      refute has_element?(view, "#lore-entries-#{hidden.id}", "the secret hoard")
    end

    test "bindings form binds and unbinds a chat", %{scope: scope, conn: conn, user: user} do
      bestiary = book(scope, "Bestiary")
      tavern = chat(scope, user, "Tavern")

      {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/edit")

      view
      |> form("#lore-book-bindings-form")
      |> render_change(%{"chats" => [tavern.id], "characters" => []})

      assert Enum.map(Lore.books_for_chat(tavern), & &1.id) == [bestiary.id]

      view
      |> form("#lore-book-bindings-form")
      |> render_change(%{"chats" => [], "characters" => []})

      assert Lore.books_for_chat(tavern) == []
    end

    test "bindings form binds and unbinds a character", %{scope: scope, conn: conn} do
      bestiary = book(scope, "Bestiary")
      knight = character(scope, "Knight")
      bound? = fn -> Repo.get_by(Lore.BookCharacter, lore_book_id: bestiary.id, character_id: knight.id) end

      {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/edit")

      view
      |> form("#lore-book-bindings-form")
      |> render_change(%{"chats" => [], "characters" => [knight.id]})

      assert bound?.()
      assert has_element?(view, "#lore-book-bindings-form-characters-#{knight.id}[checked]")

      view
      |> form("#lore-book-bindings-form")
      |> render_change(%{"chats" => [], "characters" => []})

      refute bound?.()
    end

    test "toggling a chat binding off drops the book from the chat but keeps the row",
         %{conn: conn, scope: scope, user: user} do
      bestiary = book(scope, "Bestiary")
      tavern = chat(scope, user, "Tavern")

      {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/edit")

      view
      |> form("#lore-book-bindings-form")
      |> render_change(%{"chats" => [tavern.id], "characters" => []})

      binding = Repo.get_by!(Lore.BookChat, lore_book_id: bestiary.id, chat_id: tavern.id)
      assert has_element?(view, "#lore-binding-chat-#{binding.id}")

      view
      |> element("#lore-binding-chat-#{binding.id} input[phx-click=toggle_binding]")
      |> render_click()

      assert Lore.books_for_chat(tavern) == []
      assert Lore.get_book_chat(scope, binding.id).enabled == false
      assert has_element?(view, "#lore-binding-chat-#{binding.id}")
    end

    test "the rules form saves a rule naming a chat and shows it", %{scope: scope, conn: conn, user: user} do
      bestiary = book(scope, "Bestiary")
      tavern = chat(scope, user, "Tavern")

      {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/edit")

      view
      |> form("#lore-book-rules-form")
      |> render_submit(%{
        "lore_book_rules" => %{
          "rules" => %{
            "0" => %{"enabled" => "true", "conditions" => %{"0" => %{"kind" => "chat", "chat_id" => tavern.id}}}
          }
        }
      })

      assert [%{lore_book_id: book_id}] = Repo.all(Lore.BookRule)
      assert book_id == bestiary.id
      assert has_element?(view, "#lore-book-rule-0-condition-0-chat_id")
      tavern_id = tavern.id
      assert [%{kind: :chat, chat_id: ^tavern_id}] = Repo.all(Lore.BookRuleCondition)
      assert has_element?(view, "#lore-book-rules-form[data-saved]")
    end

    test "the rules form adds a rule and a condition without showing errors early", %{scope: scope, conn: conn} do
      bestiary = book(scope, "Bestiary")
      {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/edit")

      html = view |> form("#lore-book-rules-form") |> render_change(%{"lore_book_rules" => %{"rules_sort" => ["new"]}})
      assert has_element?(view, "#lore-book-rule-0-add-condition")
      refute html =~ "add at least one condition"

      view
      |> form("#lore-book-rules-form")
      |> render_change(%{
        "lore_book_rules" => %{"rules" => %{"0" => %{"enabled" => "true", "conditions_sort" => ["new"]}}}
      })

      assert has_element?(view, "#lore-book-rule-0-condition-0-kind")
    end

    test "dropping the only rule deletes it", %{scope: scope, conn: conn, user: user} do
      bestiary = book(scope, "Bestiary")
      tavern = chat(scope, user, "Tavern")
      rule = %{"enabled" => "true", "conditions" => %{"0" => %{"kind" => "chat", "chat_id" => tavern.id}}}
      {:ok, _} = Lore.set_book_rules(scope, bestiary, %{"rules" => %{"0" => rule}})

      {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/edit")

      view
      |> form("#lore-book-rules-form")
      |> render_submit(%{"lore_book_rules" => %{"rules_drop" => ["0"]}})

      assert Repo.all(Lore.BookRule) == []
    end

    test "an edited rules form flags rules saved elsewhere", %{scope: scope, conn: conn, user: user} do
      bestiary = book(scope, "Bestiary")
      tavern = chat(scope, user, "Tavern")
      {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/edit")

      view |> form("#lore-book-rules-form") |> render_change(%{"lore_book_rules" => %{"rules_sort" => ["new"]}})

      rule = %{"enabled" => "true", "conditions" => %{"0" => %{"kind" => "chat", "chat_id" => tavern.id}}}
      {:ok, _} = Lore.set_book_rules(scope, Repo.reload!(bestiary), %{"rules" => %{"0" => rule}})

      assert has_element?(view, "#lore-changed-elsewhere")
    end

    test "an admin's editor hides a user's chat binding of a site book", %{conn: conn, scope: scope} do
      bestiary = book(scope, "Bestiary", %{}, site: true)
      user = register_user!(%{role: :user})
      secret = chat(Scope.for_user(user), user, "Their Secret Den")
      {:ok, binding} = Lore.bind_book_to_chat(bestiary, secret.id)

      {:ok, view, html} = live(conn, ~p"/lore/#{bestiary.id}/edit")

      refute html =~ "Their Secret Den"
      refute has_element?(view, "#lore-binding-chat-#{binding.id}")
    end

    test "tri-state case_sensitive persists nil, true, and false", %{scope: scope, conn: conn} do
      bestiary = book(scope, "Bestiary")

      for {submitted, expected} <- [{"", nil}, {"true", true}, {"false", false}] do
        {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/entries/new")

        submit_entry(view, entry_params(%{"name" => "Entry #{inspect(expected)}", "case_sensitive" => submitted}))

        created = Enum.find(Lore.list_entries(scope), &(&1.name == "Entry #{inspect(expected)}"))
        assert created, "expected an entry for case_sensitive=#{inspect(submitted)}"
        assert created.case_sensitive == expected
      end
    end

    test "the custom outlet select appears only when Custom is selected", %{scope: scope, conn: conn} do
      bestiary = book(scope, "Bestiary")
      {:ok, _} = Prompts.create_outlet(scope, %{key: "ending", name: "Ending"})

      {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/entries/new")

      refute has_element?(view, "#lore-entry-form-custom_outlet")

      change_entry(view, entry_params(%{"outlet" => "custom"}))

      assert has_element?(view, "#lore-entry-form-custom_outlet")
      # A custom outlet is one named insertion point, so before/after is meaningless (same as at_depth).
      assert has_element?(view, "#lore-entry-form-placement[disabled]")

      # Placement is disabled in the custom state, and `form/2` refuses disabled params, so switching back
      # omits it.
      change_entry(view, entry_params(%{"outlet" => "author_note"}) |> Map.delete("placement"))

      refute has_element?(view, "#lore-entry-form-custom_outlet")
      refute has_element?(view, "#lore-entry-form-placement[disabled]")

      # And at_depth greys Placement out too, for the same reason.
      change_entry(view, entry_params(%{"outlet" => "at_depth"}))

      assert has_element?(view, "#lore-entry-form-placement[disabled]")
      refute has_element?(view, "#lore-entry-form-custom_outlet")
    end

    test "a custom entry round-trips its outlet key", %{scope: scope, conn: conn} do
      bestiary = book(scope, "Bestiary")
      {:ok, outlet} = Prompts.create_outlet(scope, %{key: "ending", name: "Ending"})

      {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/entries/new")

      # The select only exists once Custom is chosen, and `form/2` refuses params with no matching input.
      change_entry(view, entry_params(%{"outlet" => "custom"}))
      submit_entry(view, custom_entry_params(%{"custom_outlet" => outlet.key}))

      assert [created] = Lore.list_entries(scope)
      assert created.outlet == :custom
      assert created.custom_outlet == outlet.key
      assert LoreEntry.slot(created) == "custom:ending"
    end

    test "a custom entry with no outlet is rejected", %{scope: scope, conn: conn} do
      bestiary = book(scope, "Bestiary")
      {:ok, _} = Prompts.create_outlet(scope, %{key: "ending", name: "Ending"})

      {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/entries/new")

      change_entry(view, entry_params(%{"outlet" => "custom"}))
      submit_entry(view, custom_entry_params(%{"custom_outlet" => ""}))

      assert Lore.list_entries(scope) == []
      assert has_element?(view, "#lore-entry-form-custom_outlet[aria-invalid='true']")
    end

    # Once Custom is selected the Placement select is disabled, and `form/2` refuses to submit a param
    # whose input is disabled, so a custom submission omits it. The schema default (`:before`) satisfies
    # `validate_required`, and `slot/1` ignores it for `:custom` anyway.
    defp custom_entry_params(overrides) do
      %{"outlet" => "custom"}
      |> Map.merge(overrides)
      |> entry_params()
      |> Map.delete("placement")
    end
  end

  describe "row selection" do
    test "selected rows are marked as memories, badged, and unmarked", %{scope: scope, conn: conn} do
      bestiary = book(scope, "Bestiary")
      dragons = entry(scope, "Dragons", [bestiary.id])
      wyverns = entry(scope, "Wyverns", [bestiary.id])
      griffins = entry(scope, "Griffins", [bestiary.id])
      memories = from(r in Record, where: r.lore_book_id == ^bestiary.id and r.kind == :memory)

      {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/edit")
      refute has_element?(view, "#lore-entries-selection")

      view |> element("#lore-entries-#{dragons.id}-select") |> render_click()
      view |> element("#lore-entries-#{wyverns.id}-select") |> render_click()

      assert has_element?(view, "#lore-entries-selection", "2 selected")
      assert has_element?(view, "#lore-entries-#{dragons.id}-select[checked]")
      refute has_element?(view, "#lore-entries-#{griffins.id}-select[checked]")
      # The in-book switch is a separate checkbox, untouched by selection.
      assert has_element?(view, "#lore-entries-#{dragons.id}-in-book[checked]")

      assert view |> element("#lore-entries-mark-memories") |> render_click() =~ "Marked 2 entries as memories."
      assert has_element?(view, "#lore-entries-#{dragons.id}-memory.lore-entry-memory-badge", "Memory")
      assert has_element?(view, "#lore-entries-#{wyverns.id}-memory", "Memory")
      refute has_element?(view, "#lore-entries-#{griffins.id}-memory")
      assert Repo.aggregate(memories, :count) == 2

      assert view |> element("#lore-entries-mark-memories") |> render_click() =~
               "No entries were marked as memories; 2 already were memories."

      assert view |> element("#lore-entries-unmark-memories") |> render_click() =~ "Unmarked 2 memories."
      refute has_element?(view, "#lore-entries-#{dragons.id}-memory")
      assert Repo.aggregate(memories, :count) == 0
      assert Repo.get(LoreEntry, dragons.id)

      view |> element("#lore-entries-selection-clear") |> render_click()
      refute has_element?(view, "#lore-entries-selection")
      refute has_element?(view, "#lore-entries-#{dragons.id}-select[checked]")
    end

    test "hide disabled memories hides only memories switched off in the book", %{scope: scope, conn: conn} do
      saga = book(scope, "Saga")
      off_memory = entry(scope, "Off memory", [saga.id])
      on_memory = entry(scope, "On memory", [saga.id])
      off_plain = entry(scope, "Off plain", [saga.id])
      {:ok, _} = Mythweaver.Memory.mark_as_memories(scope, saga, [off_memory.id, on_memory.id])
      {:ok, _} = Lore.set_membership_enabled(scope, saga, off_memory.id, false)
      {:ok, _} = Lore.set_membership_enabled(scope, saga, off_plain.id, false)

      {:ok, view, _html} = live(conn, ~p"/lore/#{saga.id}/edit")
      assert has_element?(view, "#lore-entries-hide-disabled-memories[aria-pressed='false']")
      assert has_element?(view, "#lore-entries-#{off_memory.id}")

      view |> element("#lore-entries-hide-disabled-memories") |> render_click()
      assert has_element?(view, "#lore-entries-hide-disabled-memories[aria-pressed='true']")
      refute has_element?(view, "#lore-entries-#{off_memory.id}")
      assert has_element?(view, "#lore-entries-#{on_memory.id}")
      assert has_element?(view, "#lore-entries-#{off_plain.id}")

      view |> element("#lore-entries-hide-disabled-memories") |> render_click()
      assert has_element?(view, "#lore-entries-hide-disabled-memories[aria-pressed='false']")
      assert has_element?(view, "#lore-entries-#{off_memory.id}")
    end

    test "a shift-click range adds its rows to the selection", %{scope: scope, conn: conn} do
      bestiary = book(scope, "Bestiary")
      archive = book(scope, "Archive")
      [a, b, c, d, e] = for name <- ~w(A B C D E), do: entry(scope, name, [bestiary.id])
      elsewhere = entry(scope, "Scrolls", [archive.id])

      range = fn view, entries ->
        view
        |> element("#lore-entries-table")
        |> render_hook("select_entry_range", %{"ids" => Enum.map(entries, & &1.id)})
      end

      selected? = fn view, entry -> has_element?(view, "#lore-entries-#{entry.id}-select[checked]") end

      {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/edit")
      view |> element("#lore-entries-#{e.id}-select") |> render_click()

      # Rows already selected stay so, and an entry the book's table does not list is ignored.
      range.(view, [b, c, d, e, elsewhere])
      assert has_element?(view, "#lore-entries-selection", "4 selected")
      assert Enum.map([a, b, c, d, e], &selected?.(view, &1)) == [false, true, true, true, true]
    end

    test "select all toggles every row; another book starts with nothing selected", %{scope: scope, conn: conn} do
      bestiary = book(scope, "Bestiary")
      archive = book(scope, "Archive")
      dragons = entry(scope, "Dragons", [bestiary.id])
      wyverns = entry(scope, "Wyverns", [bestiary.id])
      entry(scope, "Scrolls", [archive.id])

      {:ok, view, _html} = live(conn, ~p"/lore/#{bestiary.id}/edit")
      view |> element("#lore-entries-select-all") |> render_click()

      assert has_element?(view, "#lore-entries-selection", "2 selected")
      assert has_element?(view, "#lore-entries-select-all[checked]")
      assert has_element?(view, "#lore-entries-#{dragons.id}-select[checked]")
      assert has_element?(view, "#lore-entries-#{wyverns.id}-select[checked]")

      view |> element("#lore-entries-select-all") |> render_click()
      refute has_element?(view, "#lore-entries-selection")
      refute has_element?(view, "#lore-entries-#{wyverns.id}-select[checked]")

      view |> element("#lore-entries-#{dragons.id}-select") |> render_click()
      assert has_element?(view, "#lore-entries-selection", "1 selected")

      render_patch(view, ~p"/lore/#{archive.id}/edit")
      refute has_element?(view, "#lore-entries-selection")

      render_patch(view, ~p"/lore/#{bestiary.id}/edit")
      refute has_element?(view, "#lore-entries-#{dragons.id}-select[checked]")
    end
  end

  describe "bulk select" do
    test "deletes a book and an entry together", %{scope: scope, conn: conn} do
      keep = book(scope, "Atlas")
      doomed = book(scope, "Bestiary")
      loose = entry(scope, "Loose", [])
      {:ok, view, _html} = live(conn, ~p"/lore/#{keep.id}/edit")

      view |> element("#lore-bulk-toggle") |> render_click()
      view |> element("#bulk-lore_books-#{doomed.id}") |> render_click()
      view |> element("#bulk-lore_entries-#{loose.id}") |> render_click()
      html = view |> element("#lore-bulk-delete") |> render_click()

      assert html =~ "Deleted 1 book. Deleted 1 entry."
      assert Lore.get_editable_book(scope, doomed.id) == nil
      assert Lore.get_editable_entry(scope, loose.id) == nil
      assert Lore.get_editable_book(scope, keep.id)
    end

    test "edits the ticked field of every selected entry", %{scope: scope, conn: conn} do
      atlas = book(scope, "Atlas")
      a = entry(scope, "A", [])
      b = entry(scope, "B", [])
      {:ok, view, _html} = live(conn, ~p"/lore/#{atlas.id}/edit")

      view |> element("#lore-bulk-toggle") |> render_click()
      view |> element("#bulk-lore_entries-#{a.id}") |> render_click()
      view |> element("#bulk-lore_entries-#{b.id}") |> render_click()
      view |> element("#lore-bulk-edit-lore_entries") |> render_click()

      html =
        view
        |> form("#bulk-edit-form", bulk: %{apply_prevent_recursion: "true", prevent_recursion: "true"})
        |> render_submit()

      assert html =~ "Updated 2 entries."
      assert Lore.get_editable_entry(scope, a.id).prevent_recursion
      assert Lore.get_editable_entry(scope, b.id).prevent_recursion
    end
  end
end
