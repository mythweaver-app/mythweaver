defmodule MythweaverWeb.CatalogLive do
  @moduledoc """
  The catalog (`Mythweaver.Catalog`): published listings on the left (`Catalog.list_listings/2`,
  featured first, then newest), narrowed by a search over title, summary and tags, a type and a tag;
  the selected listing on the right (`/catalog/:id`).

  The detail shows the mirror root's card (`Mythweaver.Sharing.Items.card/2`: its protected fields
  only once the viewer may read them, i.e. subscribed to a Readable listing), the summary, tags and
  release history. The viewer subscribes (`Catalog.subscribe/2`) or unsubscribes
  (`Catalog.unsubscribe/2`); a Readable subscription can be cloned
  (`Mythweaver.Sharing.Clone.clone/2` of the mirror root), which opens the copy's editor. Anyone but
  the publisher may report the listing or its publisher (`MythweaverWeb.ReportModal`), and a
  `"catalog.feature"` holder features or unfeatures it (`Catalog.feature/3`).

  Re-reads on every shared item kind's broadcast, so a subscription, release or takedown elsewhere
  shows at once; a selected listing that is gone patches to the index.
  """

  use MythweaverWeb, :live_view

  import MythweaverWeb.Pane

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.Catalog
  alias Mythweaver.Format
  alias Mythweaver.Sharing.Clone
  alias Mythweaver.Sharing.Items
  alias MythweaverWeb.ItemFields
  alias MythweaverWeb.LiveSync
  alias MythweaverWeb.ReportModal

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: catalog_title(), selected: nil, selected_id: nil, reporting: nil)
     |> stream_configure(:listings, dom_id: &"listings-#{&1.id}")
     |> assign_filter(%{}, [:query, :type, :tag])
     |> stream_listings()
     |> LiveSync.attach(Items.kinds(), &sync/2)}
  end

  defp sync(socket, _kinds) do
    socket = stream_listings(socket)

    case socket.assigns.selected do
      nil -> socket
      %{listing: listing} -> show(socket, listing.id)
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(selected: nil, selected_id: nil, reporting: nil)
    |> stream_listings()
  end

  defp apply_action(socket, :show, %{"id" => id}), do: show(socket, id)

  defp show(socket, id) do
    scope = socket.assigns.current_scope

    with %{} = listing <- Catalog.get_listing(scope, id),
         %{} = mirror <- Items.get(listing.item_type, listing.mirror_id) do
      assign(socket,
        selected_id: listing.id,
        selected: %{
          listing: listing,
          card: Items.card(scope, mirror),
          subscription: Catalog.subscription(scope, listing),
          owner?: listing.owner_id == scope.user.id,
          clonable?: Clone.clonable?(scope, mirror)
        }
      )
    else
      _ ->
        socket
        |> assign(selected: nil, selected_id: nil, reporting: nil)
        |> put_flash(:error, listing_not_found_flash())
        |> push_patch(to: ~p"/catalog")
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, socket |> assign_filter(params, [:query, :type, :tag]) |> stream_listings()}
  end

  def handle_event("subscribe", _params, socket) do
    with_listing(socket, fn listing ->
      case Catalog.subscribe(socket.assigns.current_scope, listing) do
        {:ok, _share} ->
          gettext_comment("Flash after the viewer subscribes to a catalog listing.")

          socket
          |> put_flash(
            :info,
            dpgettext("sharing", "status: viewer subscribed to a catalog listing", "Subscribed to %{listing_title}",
              listing_title: listing.title
            )
          )
          |> refresh()

        {:error, _reason} ->
          gettext_comment("Flash when the viewer may not subscribe to a catalog listing.")

          socket
          |> put_flash(:error, dgettext("sharing", "You can't subscribe to this"))
          |> refresh()
      end
    end)
  end

  def handle_event("unsubscribe", _params, socket) do
    with_listing(socket, fn listing ->
      case Catalog.unsubscribe(socket.assigns.current_scope, listing) do
        {:ok, _impact} ->
          gettext_comment("Flash after the viewer unsubscribes from a catalog listing.")

          socket
          |> put_flash(
            :info,
            dpgettext(
              "sharing",
              "status: viewer unsubscribed from a catalog listing",
              "Unsubscribed from %{listing_title}",
              listing_title: listing.title
            )
          )
          |> refresh()

        {:error, _reason} ->
          refresh(socket)
      end
    end)
  end

  def handle_event("clone", _params, socket) do
    case socket.assigns.selected do
      %{card: %{item: item}} ->
        case Clone.clone(socket.assigns.current_scope, item) do
          {:ok, copy} ->
            {:noreply,
             socket
             |> put_flash(:info, cloned_message(item, copy))
             |> push_navigate(to: Items.edit_path(Items.type_of(copy), copy.id))}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, clone_error_message(reason))}
        end

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("feature", _params, socket) do
    with_listing(socket, fn listing ->
      case Catalog.feature(socket.assigns.current_scope, listing, !listing.featured) do
        {:ok, _listing} ->
          refresh(socket)

        {:error, _reason} ->
          gettext_comment("Flash when the viewer may not feature catalog listings.")

          socket
          |> put_flash(
            :error,
            dpgettext("sharing", "status: featuring a catalog listing refused", "You can't feature listings")
          )
          |> refresh()
      end
    end)
  end

  def handle_event("open_report", %{"kind" => "listing"}, socket) do
    with_listing(
      socket,
      &ReportModal.open(
        socket,
        :listing,
        &1.id,
        dpgettext("sharing", "heading: report dialog for a catalog listing", "Report %{listing_title}",
          listing_title: &1.title
        )
      )
    )
  end

  def handle_event("open_report", %{"kind" => "user"}, socket) do
    with_listing(
      socket,
      &ReportModal.open(
        socket,
        :user,
        &1.owner_id,
        dpgettext("sharing", "heading: report dialog for a listing's publisher", "Report @%{user_handle}",
          user_handle: &1.owner.handle
        )
      )
    )
  end

  def handle_event("open_report", _params, socket), do: {:noreply, socket}

  def handle_event("close_report", _params, socket), do: {:noreply, ReportModal.close(socket)}

  def handle_event("report", %{"report" => params}, socket), do: {:noreply, ReportModal.submit(socket, params)}

  defp with_listing(socket, fun) do
    case socket.assigns.selected do
      %{listing: listing} -> {:noreply, fun.(listing)}
      nil -> {:noreply, socket}
    end
  end

  defp refresh(socket) do
    socket = stream_listings(socket)

    case socket.assigns.selected do
      %{listing: listing} -> show(socket, listing.id)
      nil -> socket
    end
  end

  defp catalog_title, do: dpgettext("sharing", "page title: the catalog of published listings", "Catalog")

  defp listing_not_found_flash do
    gettext_comment("Flash when the catalog listing in the URL no longer exists or isn't visible.")
    dpgettext("sharing", "status: catalog listing missing", "Listing not found")
  end

  defp stream_listings(socket) do
    %{query: query, type: type, tag: tag} = socket.assigns
    listings = Catalog.list_listings(socket.assigns.current_scope, search: query, type: type_param(type), tag: tag)

    socket
    |> assign(listings_empty?: listings == [], tag_options: tag_options(socket))
    |> stream(:listings, listings, reset: true)
  end

  defp type_param(type), do: Enum.find(Catalog.types(), &(Atom.to_string(&1) == type))

  defp type_options, do: Enum.map(Catalog.types(), &{type_option(&1), &1})

  defp tag_options(socket) do
    socket.assigns.current_scope
    |> Catalog.list_listings()
    |> Enum.flat_map(& &1.tags)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp type_label(:character), do: dpgettext("sharing", "badge: kind of a catalog listing's item", "character")
  defp type_label(:lore_book), do: dpgettext("sharing", "badge: kind of a catalog listing's item", "lore book")
  defp type_label(:prompt), do: dpgettext("sharing", "badge: kind of a catalog listing's item", "prompt")
  defp type_label(:block), do: dpgettext("sharing", "badge: kind of a catalog listing's item", "prompt block")
  defp type_label(:outlet), do: dpgettext("sharing", "badge: kind of a catalog listing's item", "outlet")
  defp type_label(:script), do: dpgettext("sharing", "badge: kind of a catalog listing's item", "script")

  defp type_label(:memory_profile),
    do: dpgettext("sharing", "badge: kind of a catalog listing's item", "memory profile")

  defp type_label(:side_prompt), do: dpgettext("sharing", "badge: kind of a catalog listing's item", "side prompt")

  defp type_label(:side_prompt_set),
    do: dpgettext("sharing", "badge: kind of a catalog listing's item", "side prompt set")

  defp type_option(:character), do: dpgettext("sharing", "option: catalog listing item kind filter", "Character")
  defp type_option(:lore_book), do: dpgettext("sharing", "option: catalog listing item kind filter", "Lore book")
  defp type_option(:prompt), do: dpgettext("sharing", "option: catalog listing item kind filter", "Prompt")
  defp type_option(:block), do: dpgettext("sharing", "option: catalog listing item kind filter", "Prompt block")
  defp type_option(:outlet), do: dpgettext("sharing", "option: catalog listing item kind filter", "Outlet")
  defp type_option(:script), do: dpgettext("sharing", "option: catalog listing item kind filter", "Script")

  defp type_option(:memory_profile),
    do: dpgettext("sharing", "option: catalog listing item kind filter", "Memory profile")

  defp type_option(:side_prompt), do: dpgettext("sharing", "option: catalog listing item kind filter", "Side prompt")

  defp type_option(:side_prompt_set),
    do: dpgettext("sharing", "option: catalog listing item kind filter", "Side prompt set")

  defp published_by(type, owner) do
    bindings = [publisher: publisher(owner)]

    case type do
      :character ->
        dpgettext(
          "sharing",
          "status: catalog listing byline for a character",
          "Character published by %{publisher}.",
          bindings
        )

      :lore_book ->
        dgettext("sharing", "Lore book published by %{publisher}.", bindings)

      :prompt ->
        dpgettext(
          "sharing",
          "status: catalog listing byline for a prompt",
          "Prompt published by %{publisher}.",
          bindings
        )

      :block ->
        dgettext("sharing", "Prompt block published by %{publisher}.", bindings)

      :outlet ->
        dpgettext(
          "sharing",
          "status: catalog listing byline for a prompt outlet",
          "Outlet published by %{publisher}.",
          bindings
        )

      :script ->
        dpgettext(
          "sharing",
          "status: catalog listing byline for a script",
          "Script published by %{publisher}.",
          bindings
        )

      :memory_profile ->
        dgettext("sharing", "Memory profile published by %{publisher}.", bindings)

      :side_prompt ->
        dgettext("sharing", "Side prompt published by %{publisher}.", bindings)

      :side_prompt_set ->
        dgettext("sharing", "Side prompt set published by %{publisher}.", bindings)
    end
  end

  defp publisher(%User{nickname: nil, handle: handle}),
    do:
      dpgettext("sharing", "status: publisher of a catalog listing, by handle", "@%{user_handle}", user_handle: handle)

  defp publisher(%User{nickname: nickname, handle: handle}),
    do:
      dpgettext(
        "sharing",
        "status: publisher of a catalog listing, name and handle",
        "%{user_nickname} (@%{user_handle})", user_nickname: nickname, user_handle: handle)

  defp version_text(version),
    do:
      dpgettext("sharing", "badge: release version of a catalog listing", "v%{version_number}",
        version_number: Format.number(version)
      )

  defp version(%{current_release: %{version: version}}), do: version_text(version)
  defp version(_listing), do: nil

  defp subscribers(n),
    do:
      dpngettext(
        "sharing",
        "badge: subscriber total of a catalog listing",
        "%{subscriber_count} subscriber",
        "%{subscriber_count} subscribers",
        n, subscriber_count: Format.number(n))

  defp visibility_text(:readable),
    do: dpgettext("sharing", "badge: catalog listing visibility, contents can be inspected", "Readable")

  defp visibility_text(:runtime_only),
    do: dpgettext("sharing", "badge: catalog listing visibility, use only", "Runtime-only")

  defp featured_text, do: dpgettext("sharing", "badge: catalog listing featured by the site", "Featured")

  # Independent badges, separated by a middle dot.
  defp badges(list), do: list |> Enum.reject(&is_nil/1) |> Enum.join(" · ")

  defp list_title(listing), do: badges([listing.title, if(listing.featured, do: featured_text())])

  defp list_meta(listing),
    do:
      badges([
        type_label(listing.item_type),
        publisher(listing.owner),
        subscribers(listing.subscriber_count),
        version(listing)
      ])

  defp about_meta(listing),
    do:
      badges([
        visibility_text(listing.visibility),
        subscribers(listing.subscriber_count),
        version(listing),
        if(listing.featured, do: featured_text())
      ])

  defp unsubscribe_confirm(listing) do
    gettext_comment("Confirm dialog before the viewer unsubscribes from a catalog listing.")

    dgettext("sharing", "Unsubscribe from %{listing_title}? You lose it and whatever of yours uses it.",
      listing_title: listing.title
    )
  end

  defp subscribed_hint(subscription) do
    gettext_comment("%{shared_link} is a link with the text \"Shared with me\" to the viewer's shares page.")

    rich(
      dgettext("sharing", "You are subscribed; it is listed under %{shared_link}.",
        shared_link:
          navigate_link(
            dpgettext("sharing", "link: the viewer's shares page", "Shared with me"),
            ~p"/shared/#{subscription.id}"
          )
      )
    )
  end

  defp hidden_hint(%{visibility: :readable}), do: dgettext("sharing", "Subscribe to read everything it holds.")

  defp hidden_hint(%{item_type: type}) do
    gettext_comment(
      "%{field_list} is a list of the item's protected field names, e.g. \"description and personality\"."
    )

    dgettext("sharing", "Runtime-only: subscribers' models use its %{field_list}, but nobody can read them.",
      field_list: ItemFields.protected_labels(type)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- `lower-bound="none"`: rules reach the `<img>` root of `<.avatar_image>`. --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      /* The editor slot's root; see AGENTS.md (CSS). */
      div.catalog-editor-body:scope {
        display: contents;
      }

      .catalog-about,
      .catalog-hint,
      .catalog-summary {
        margin: 0;
      }

      .catalog-summary {
        white-space: pre-wrap;
      }

      .catalog-hint {
        color: var(--muted-foreground);
        font-size: 0.875rem;
      }

      .catalog-avatar {
        inline-size: 10rem;

        & img {
          display: block;
          inline-size: 100%;
          border-radius: var(--radius-3);
        }
      }

      .catalog-tags {
        display: flex;
        flex-wrap: wrap;
        gap: var(--size-1);
        margin: 0;
        padding: 0;
        list-style: none;

        & li {
          padding: 0 var(--size-2);
          border: 1px solid var(--border);
          border-radius: var(--radius-round);
          font-size: 0.875rem;
        }
      }

      .catalog-list {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
        margin: 0;
        padding: 0;
        list-style: none;
      }

      .catalog-release-head {
        display: flex;
        gap: var(--size-2);
        align-items: baseline;
        font-weight: var(--font-weight-6);
      }

      .catalog-release-notes {
        margin: 0;
        white-space: pre-wrap;
      }
    </style>
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.pane_layout>
        <:list id="catalog-nav" label={catalog_title()}>
          <.pane_header title={catalog_title()} />
          <.pane_search
            id="catalog-filter"
            form={@filter_form}
            placeholder={
              dpgettext("sharing", "placeholder: search catalog listings", "Title, summary or tag")
            }
          >
            <.input
              field={@filter_form[:type]}
              type="select"
              label={dpgettext("sharing", "field label: catalog filter by item kind", "Type")}
              id="catalog-filter-type"
              prompt={dpgettext("sharing", "option: catalog filter, any item kind", "All types")}
              options={type_options()}
            />
            <.input
              field={@filter_form[:tag]}
              type="select"
              label={dpgettext("sharing", "field label: catalog filter by tag", "Tag")}
              id="catalog-filter-tag"
              prompt={dpgettext("sharing", "option: catalog filter, any tag", "All tags")}
              options={@tag_options}
            />
          </.pane_search>
          <.pane_items
            :let={listing}
            id="listings"
            rows={@streams.listings}
            empty?={@listings_empty?}
            empty={
              if {@query, @type, @tag} == {"", "", ""},
                do:
                  dpgettext(
                    "sharing",
                    "empty state: catalog has no listings",
                    "Nothing is published yet"
                  ),
                else:
                  dpgettext(
                    "sharing",
                    "empty state: no catalog listings match the filters",
                    "No listings match these filters"
                  )
            }
            selected_id={@selected_id}
            patch={fn listing -> ~p"/catalog/#{listing.id}" end}
          >
            <span class="pane-item-name">
              {list_title(listing)}
            </span>
            <span class="pane-item-meta">
              {list_meta(listing)}
            </span>
          </.pane_items>
        </:list>
        <:editor id="catalog-editor">
          <div :if={is_nil(@selected)} class="catalog-editor-body">
            <.pane_placeholder id="catalog-placeholder">
              {dpgettext(
                "sharing",
                "empty state: no catalog listing selected",
                "Select a listing to see what it offers."
              )}
            </.pane_placeholder>
          </div>
          <div :if={@selected} class="catalog-editor-body">
            <.panel_header sticky>
              {@selected.listing.title}
              <:actions>
                <.button
                  :if={@selected.card.readable? and @selected.clonable?}
                  size="sm"
                  id="catalog-clone"
                  phx-click="clone"
                >
                  <.lucide name="copy" />
                  {dpgettext(
                    "sharing",
                    "button: clone a catalog listing's item into the viewer's own",
                    "Clone"
                  )}
                </.button>
                <.button
                  :if={!@selected.owner? and is_nil(@selected.subscription)}
                  size="sm"
                  variant="primary"
                  id="catalog-subscribe"
                  phx-click="subscribe"
                >
                  <.lucide name="plus" />
                  {dpgettext("sharing", "button: subscribe to a catalog listing", "Subscribe")}
                </.button>
                <.button
                  :if={@selected.subscription}
                  size="sm"
                  danger
                  id="catalog-subscribe"
                  phx-click="unsubscribe"
                  data-confirm={unsubscribe_confirm(@selected.listing)}
                >
                  {dpgettext("sharing", "button: unsubscribe from a catalog listing", "Unsubscribe")}
                </.button>
                <.button
                  :if={Scope.can?(@current_scope, "catalog.feature")}
                  size="sm"
                  id="catalog-feature"
                  phx-click="feature"
                  aria-pressed={to_string(@selected.listing.featured)}
                >
                  <.lucide name="star" /> {if @selected.listing.featured,
                    do: dpgettext("sharing", "button: stop featuring a catalog listing", "Unfeature"),
                    else: dpgettext("sharing", "button: feature a catalog listing", "Feature")}
                </.button>
                <.button
                  :if={!@selected.owner? and Scope.can?(@current_scope, "reports.create")}
                  size="sm"
                  id="catalog-report"
                  phx-click="open_report"
                  phx-value-kind="listing"
                  phx-value-id={@selected.listing.id}
                >
                  <.lucide name="flag" />
                  {dpgettext("sharing", "button: report a catalog listing", "Report")}
                </.button>
                <.button
                  :if={!@selected.owner? and Scope.can?(@current_scope, "reports.create")}
                  size="sm"
                  id="catalog-report-publisher"
                  phx-click="open_report"
                  phx-value-kind="user"
                  phx-value-id={@selected.listing.owner_id}
                >
                  <.lucide name="user-x" />
                  {dpgettext(
                    "sharing",
                    "button: report a catalog listing's publisher",
                    "Report publisher"
                  )}
                </.button>
              </:actions>
            </.panel_header>
            <.pane_section id="catalog-about">
              <p class="catalog-about">
                {published_by(@selected.listing.item_type, @selected.listing.owner)} {about_meta(
                  @selected.listing
                )}
              </p>
              <p :if={@selected.subscription} id="catalog-subscribed" class="catalog-hint">
                {subscribed_hint(@selected.subscription)}
              </p>
              <p :if={@selected.listing.summary} id="catalog-summary" class="catalog-summary">
                {@selected.listing.summary}
              </p>
              <ul :if={@selected.listing.tags != []} id="catalog-tags" class="catalog-tags">
                <li :for={tag <- @selected.listing.tags}>{tag}</li>
              </ul>
              <.button
                :if={@selected.owner?}
                id="catalog-edit"
                navigate={Items.edit_path(@selected.listing.item_type, @selected.listing.item_id)}
              >
                <.lucide name="pencil" />
                {dpgettext("sharing", "button: open the listed item's editor", "Open editor")}
              </.button>
            </.pane_section>
            <.pane_section id="catalog-card">
              <.section_header>{@selected.card.item.name}</.section_header>
              <div :if={:avatar in Items.fields(@selected.listing.item_type)} class="catalog-avatar">
                <.avatar_image
                  avatar={@selected.card.item}
                  preset={:portrait}
                  sizes="160px"
                  alt={@selected.card.item.name}
                />
              </div>
              <ItemFields.item_fields
                id="catalog-card"
                type={@selected.listing.item_type}
                row={@selected.card.item}
                readable?={@selected.card.readable?}
                hidden_hint={hidden_hint(@selected.listing)}
              />
              <ul :if={@selected.card.parts != []} id="catalog-parts" class="catalog-list">
                <li :for={{part, _readable?} <- @selected.card.parts} id={"catalog-part-#{part.id}"}>
                  {part.name}
                </li>
              </ul>
            </.pane_section>
            <.pane_section id="catalog-releases">
              <.section_header>
                {dpgettext("sharing", "heading: release history of a catalog listing", "Releases")}
              </.section_header>
              <ul class="catalog-list">
                <li :for={release <- @selected.listing.releases} id={"catalog-release-#{release.id}"}>
                  <span class="catalog-release-head">
                    {version_text(release.version)}
                    <.local_time
                      id={"catalog-release-#{release.id}-at"}
                      at={release.inserted_at}
                      format={:full}
                      class="catalog-hint"
                    />
                  </span>
                  <p :if={release.notes} class="catalog-release-notes">{release.notes}</p>
                </li>
              </ul>
            </.pane_section>
          </div>
        </:editor>
      </.pane_layout>
      <ReportModal.report_modal :if={@reporting} reporting={@reporting} />
    </Layouts.app>
    """
  end
end
