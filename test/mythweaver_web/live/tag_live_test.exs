defmodule MythweaverWeb.TagLiveTest do
  use MythweaverWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Mythweaver.Tags
  alias Mythweaver.Tags.Tag

  setup :register_and_log_in_user

  defp tag!(scope, attrs, opts \\ []) do
    {:ok, tag} = Tags.create_tag(scope, Map.new(attrs), opts)
    tag
  end

  test "index selects nothing when there are no tags", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tags")
    assert has_element?(view, "#tag-placeholder")
  end

  test "creates a tag from the new form", %{scope: scope, conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tags/new")
    assert has_element?(view, ".top-bar-nav a[href='/tags']")

    view
    |> form("#tag-form", tag: %{text: "Series:Metroid"})
    |> render_submit()

    assert [created] = Tags.list_editable_tags(scope)
    assert Tag.text(created) == "series:metroid"
    assert_patch(view, "/tags/#{created.id}/edit")
    assert view |> element("#tags-#{created.id}") |> render() =~ "metroid"
    assert has_element?(view, "#tags-#{created.id} .tag-chip", "series")
  end

  test "keeps the chosen sibling and saves it", %{scope: scope, conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tags/new")

    view
    |> form("#tag-form", tag: %{text: "lotr"})
    |> render_submit(%{"tag" => %{"ideal_text" => ["", "series:lotr"]}})

    lotr = Enum.find(Tags.list_editable_tags(scope), &(Tag.text(&1) == "lotr"))
    assert Tag.text(lotr.ideal) == "series:lotr"
  end

  test "a parent cycle renders the loop error", %{scope: scope, conn: conn} do
    x = tag!(scope, text: "x", parent_texts: ["y"])
    y = Enum.find(Tags.list_editable_tags(scope), &(Tag.text(&1) == "y"))

    {:ok, view, _html} = live(conn, ~p"/tags/#{y.id}/edit")

    html =
      view
      |> form("#tag-form", tag: %{text: "y"})
      |> render_submit(%{"tag" => %{"parent_texts" => ["", "x"]}})

    assert html =~ "x would loop back to this tag"
    assert Tags.get_editable_tag(scope, y.id).parents == []
    assert has_element?(view, "#tag-children", "x")
    assert [_] = Tags.get_editable_tag(scope, x.id).parents
  end

  test "deletes a tag", %{scope: scope, conn: conn} do
    tag = tag!(scope, text: "gone")
    {:ok, view, _html} = live(conn, ~p"/tags/#{tag.id}/edit")

    view |> element("#tag-delete") |> render_click()

    assert_patch(view, ~p"/tags")
    assert has_element?(view, "#tag-placeholder")
    assert Tags.get_editable_tag(scope, tag.id) == nil
  end

  test "lists the items carrying the tag itself", %{scope: scope, conn: conn} do
    tag = tag!(scope, [text: "series:metroid"], site: true)
    tag!(scope, [text: "metroid", ideal_text: "series:metroid"], site: true)
    {:ok, samus} = Mythweaver.Characters.create_character(scope, %{name: "Samus"}, site: true)
    {:ok, ridley} = Mythweaver.Characters.create_character(scope, %{name: "Ridley"}, site: true)
    {:ok, book} = Mythweaver.Lore.create_book(scope, %{name: "Planets"}, site: true)

    {:ok, zebes} =
      Mythweaver.Lore.create_entry(scope, %{"name" => "Zebes", "content" => "c", "keywords" => ["z"]}, [book.id], %{})

    :ok = Tags.set_item_tags(scope, samus, :site, ["series:metroid"])
    :ok = Tags.set_item_tags(scope, zebes, :site, ["series:metroid"])
    :ok = Tags.set_item_tags(scope, ridley, :site, ["metroid"])

    {:ok, view, _html} = live(conn, ~p"/tags/#{tag.id}/edit")

    assert has_element?(view, "#tagged-#{samus.id} a[href='/characters/#{samus.id}/edit']", "Samus")
    assert has_element?(view, "#tagged-#{zebes.id} a[href='/lore/entries/#{zebes.id}/edit']", "Zebes")
    refute has_element?(view, "#tagged-#{ridley.id}")
  end

  test "bulk edit sets the sibling and adds and removes parents on each tag", %{scope: scope, conn: conn} do
    a = tag!(scope, text: "a", parent_texts: ["keep", "drop"])
    b = tag!(scope, text: "b")

    {:ok, view, _html} = live(conn, ~p"/tags/#{a.id}/edit")
    view |> element("#tags-bulk-toggle") |> render_click()
    view |> element("#bulk-tags-#{a.id}") |> render_click()
    view |> element("#bulk-tags-#{b.id}") |> render_click()
    view |> element("#tags-bulk-edit-tags") |> render_click()

    view
    |> element("#bulk-edit-form")
    |> render_change(%{"_target" => ["bulk", "add_parents"], "bulk" => %{"add_parents" => ["", "new"]}})

    assert has_element?(view, "#bulk-edit-form-apply-add_parents[checked]")

    html =
      view
      |> element("#bulk-edit-form")
      |> render_submit(%{
        "bulk" => %{
          "apply_ideal_text" => "true",
          "ideal_text" => ["", "shown"],
          "apply_add_parents" => "true",
          "add_parents" => ["", "new"],
          "apply_remove_parents" => "true",
          "remove_parents" => ["", "drop"]
        }
      })

    assert html =~ "Updated 2 tags."

    for {tag, parents} <- [{a, ["keep", "new"]}, {b, ["new"]}] do
      saved = Tags.get_editable_tag(scope, tag.id)
      assert Tag.text(saved.ideal) == "shown"
      assert saved.parents |> Enum.map(&Tag.text/1) |> Enum.sort() == parents
    end
  end

  test "bulk delete removes the selected tags", %{scope: scope, conn: conn} do
    a = tag!(scope, text: "a")
    b = tag!(scope, text: "b")
    keep = tag!(scope, text: "keep")

    {:ok, view, _html} = live(conn, ~p"/tags/#{keep.id}/edit")
    view |> element("#tags-bulk-toggle") |> render_click()
    view |> element("#bulk-tags-#{a.id}") |> render_click()
    view |> element("#bulk-tags-#{b.id}") |> render_click()
    assert view |> element("#tags-bulk-delete") |> render_click() =~ "Deleted 2 tags."

    assert Tags.get_editable_tag(scope, a.id) == nil
    assert Tags.get_editable_tag(scope, b.id) == nil
    assert Tags.get_editable_tag(scope, keep.id)
  end
end
