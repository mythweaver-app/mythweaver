defmodule MythweaverWeb.CatalogLiveTest do
  use MythweaverWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Catalog
  alias Mythweaver.Characters
  alias Mythweaver.Moderation.Report
  alias Mythweaver.Repo
  alias Mythweaver.Sharing

  setup do
    publisher = register_user!(%{role: :user})
    subscriber = register_user!(%{role: :user})
    {:ok, character} = Characters.create_character(Scope.for_user(publisher), %{name: "Aqua", description: "Secret"})
    %{publisher: publisher, subscriber: subscriber, character: character}
  end

  defp publish!(%{publisher: publisher, character: character}, attrs \\ %{}) do
    {:ok, listing} =
      Catalog.publish(Scope.for_user(publisher), character, Map.merge(%{title: "Aqua", visibility: :readable}, attrs))

    listing
  end

  test "the owner publishes from the share panel and the listing appears on /catalog", ctx do
    %{publisher: publisher, character: character} = ctx
    conn = log_in_user(build_conn(), publisher)
    {:ok, view, _html} = live(conn, ~p"/characters/#{character.id}/edit")

    assert has_element?(view, "#character-share-publish-title[value='Aqua']")

    view
    |> form("#character-share-publish",
      listing: %{title: "Aqua the Goddess", summary: "Useless", tags: "Fantasy, comedy", visibility: "readable"}
    )
    |> render_submit()

    listing = Catalog.listing_for(character)
    assert listing.tags == ["fantasy", "comedy"]
    assert has_element?(view, "#character-share-listing a[href='/catalog/#{listing.id}']")
    refute has_element?(view, "#character-share-publish")

    view |> form("#character-share-release", release: %{notes: "More water"}) |> render_submit()
    assert Catalog.listing_for(character).current_release.version == 2

    view |> element("#character-share-catalog-visibility") |> render_change(%{visibility: "runtime_only"})
    assert Catalog.listing_for(character).visibility == :runtime_only

    {:ok, catalog, _html} = live(conn, ~p"/catalog")
    assert has_element?(catalog, "#listings-#{listing.id}", "Aqua the Goddess")

    catalog |> form("#catalog-filter", %{tag: "comedy"}) |> render_change()
    assert has_element?(catalog, "#listings-#{listing.id}")
    catalog |> form("#catalog-filter", %{query: "nothing like it"}) |> render_change()
    refute has_element?(catalog, "#listings-#{listing.id}")
    assert render(catalog) =~ "No listings match these filters"

    view |> element("#character-share-unpublish") |> render_click()
    assert has_element?(view, "#character-share-unpublish-confirm", "No subscriber")
    view |> element("#character-share-unpublish-confirm-button") |> render_click()
    refute Catalog.listing_for(character)
    assert has_element?(view, "#character-share-publish")
  end

  test "another user subscribes from the detail page and the item shows on /shared", ctx do
    listing = publish!(ctx)
    conn = log_in_user(build_conn(), ctx.subscriber)

    {:ok, view, _html} = live(conn, ~p"/catalog/#{listing.id}")
    assert has_element?(view, "#catalog-subscribe", "Subscribe")
    refute has_element?(view, "#catalog-card-description")
    refute has_element?(view, "#catalog-clone")

    view |> element("#catalog-subscribe") |> render_click()
    share = Catalog.subscription(Scope.for_user(ctx.subscriber), listing)
    assert has_element?(view, "#catalog-subscribe", "Unsubscribe")
    assert has_element?(view, "#catalog-card-description", "Secret")
    assert has_element?(view, "#catalog-clone")

    {:ok, shared, _html} = live(conn, ~p"/shared")
    assert has_element?(shared, "#shares-#{share.id}", "Aqua")

    view |> element("#catalog-subscribe") |> render_click()
    refute Catalog.subscription(Scope.for_user(ctx.subscriber), listing)
    assert Sharing.list_received(Scope.for_user(ctx.subscriber)) == []
  end

  test "a subscriber reports a listing and its publisher", ctx do
    listing = publish!(ctx)
    {:ok, view, _html} = live(log_in_user(build_conn(), ctx.subscriber), ~p"/catalog/#{listing.id}")

    view |> element("#catalog-report") |> render_click()
    view |> form("#report-form", report: %{reason: "Stolen art"}) |> render_submit()
    refute has_element?(view, "#report-modal")

    view |> element("#catalog-report-publisher") |> render_click()
    view |> form("#report-form", report: %{reason: "Spammer"}) |> render_submit()

    reports = Repo.all(from(r in Report, where: r.reporter_id == ^ctx.subscriber.id, order_by: r.inserted_at))

    assert [
             %Report{subject_type: :listing, subject_id: listing_id, status: :open, reason: "Stolen art"},
             %Report{subject_type: :user, subject_id: publisher_id, reason: "Spammer"}
           ] = Enum.sort_by(reports, & &1.subject_type)

    assert listing_id == listing.id
    assert publisher_id == ctx.publisher.id
  end

  test "with reporting off for Everyone, a listing offers no report buttons", ctx do
    listing = publish!(ctx)
    :ok = Mythweaver.Permissions.put_grant!(:everyone, "reports.create", :deny)
    {:ok, view, _html} = live(log_in_user(build_conn(), ctx.subscriber), ~p"/catalog/#{listing.id}")

    refute has_element?(view, "#catalog-report")
    refute has_element?(view, "#catalog-report-publisher")
  end

  test "a catalog.feature holder features and unfeatures a listing", ctx do
    listing = publish!(ctx)
    {:ok, view, _html} = live(log_in_user(build_conn(), register_user!()), ~p"/catalog/#{listing.id}")

    view |> element("#catalog-feature") |> render_click()
    assert has_element?(view, "#catalog-feature[aria-pressed='true']", "Unfeature")
    view |> element("#catalog-feature") |> render_click()
    assert has_element?(view, "#catalog-feature", "Feature")
    refute Repo.get(Catalog.Listing, listing.id).featured

    {:ok, other, _html} = live(log_in_user(build_conn(), ctx.subscriber), ~p"/catalog/#{listing.id}")
    refute has_element?(other, "#catalog-feature")
  end

  test "the top bar links to the catalog", ctx do
    {:ok, view, _html} = live(log_in_user(build_conn(), ctx.subscriber), ~p"/")
    assert has_element?(view, "#nav-catalog[href='/catalog']")
  end
end
