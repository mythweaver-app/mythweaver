defmodule MythweaverWeb.SharedLive do
  @moduledoc """
  What other accounts share with the viewer (`Mythweaver.Sharing.list_received/1`): the accepted
  shares on the left, the selected one on the right (`/shared/:id`, a share id). An editor share
  links to the item's editor; a subscriber share shows a read-only card of the item
  (`Mythweaver.Sharing.Items.card/2`): its `Items.fields/1` always, its `Items.protected_fields/1`
  only when the viewer may read them (a Readable share). Either can be left
  (`Mythweaver.Sharing.leave/2`). A Readable card can be cloned (`Mythweaver.Sharing.Clone.clone/2`),
  which opens the copy's editor.

  `:index` shows the site's content (`Mythweaver.Sharing.list_site_items/1`) instead: each row can be
  hidden for the viewer after confirming what that removes (`Sharing.opt_out_impact/2`,
  `Sharing.opt_out/2`) or restored (`Sharing.opt_in/2`), except a forced book, cloned when the
  viewer may read it, and expanded into the same card as a share's.

  On every card the viewer switches the entries, blocks and scripts they don't own on or off for
  themselves (`Sharing.set_toggle/3`), except a forced book's entries. A script card lists the
  `mw.*` APIs its body uses (`Mythweaver.Scripts.capabilities/1`), even to a Runtime-only viewer,
  and enabling a shared script first confirms them. A shared script that changed since the viewer
  enabled it is off again (`Sharing.consented?/2`) and says so, so turning it back on asks again.

  An AI model's share also says whose connection the viewer's runs use. In `:own_key` mode the viewer
  links the model to their own connections (`Mythweaver.AI.link_model/4`) and removes those links
  (`AI.delete_link/2`); in `:owner_key` mode it names the owner and the share's daily token limit.

  Re-reads on every shared item kind's broadcast, so an item changed, a share ended or a visibility
  switched elsewhere shows at once; a selected share that ended patches to the index.
  """

  use MythweaverWeb, :live_view

  import MythweaverWeb.Pane

  alias Mythweaver.Accounts.User
  alias Mythweaver.AI
  alias Mythweaver.Format
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Sharing
  alias Mythweaver.Sharing.Clone
  alias Mythweaver.Sharing.Fallout
  alias Mythweaver.Sharing.Items
  alias Mythweaver.Sharing.Visibility
  alias MythweaverWeb.ItemFields
  alias MythweaverWeb.LiveSync

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: shared_title(),
       received: [],
       selected: nil,
       card: nil,
       selected_id: nil,
       confirming: nil,
       clonable?: false,
       site_card: nil,
       ai_links: nil
     )
     |> stream_configure(:shares, dom_id: &"shares-#{&1.id}")
     |> assign_filter()
     |> stream_shares()
     |> load_site_items()
     |> LiveSync.attach(Items.kinds(), &sync/2)}
  end

  defp sync(socket, _kinds) do
    socket = socket |> stream_shares() |> load_site_items() |> refresh_site_card()

    case socket.assigns.selected do
      nil ->
        socket

      %{id: id} ->
        case find(socket, id) do
          nil -> socket |> put_flash(:info, share_ended_flash()) |> push_patch(to: ~p"/shared")
          entry -> select(socket, entry)
        end
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(selected: nil, card: nil, selected_id: nil, ai_links: nil)
    |> stream_shares()
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    socket = stream_shares(socket)

    case find(socket, id) do
      nil -> socket |> put_flash(:error, share_not_found_flash()) |> push_patch(to: ~p"/shared")
      entry -> select(socket, entry)
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, socket |> assign_filter(params) |> stream_shares()}
  end

  def handle_event("leave", %{"id" => id}, socket) do
    case {find(socket, id), Sharing.leave(socket.assigns.current_scope, id)} do
      {%{item: item}, {:ok, _impact}} ->
        gettext_comment("Flash after the viewer leaves an item someone shared with them.")

        {:noreply,
         socket
         |> put_flash(
           :info,
           dpgettext("sharing", "status: viewer left a share", "You left %{item_name}", item_name: item.name)
         )
         |> push_patch(to: ~p"/shared")}

      _ ->
        {:noreply, socket |> put_flash(:error, share_not_found_flash()) |> push_patch(to: ~p"/shared")}
    end
  end

  def handle_event("clone_share", _params, socket) do
    case socket.assigns.selected do
      %{type: type, item: item} -> clone(socket, type, item)
      nil -> {:noreply, socket}
    end
  end

  def handle_event("clone_site", params, socket) do
    case find_site(socket, params) do
      %{type: type, item: item} -> clone(socket, type, item)
      nil -> {:noreply, put_flash(socket, :error, item_gone_flash())}
    end
  end

  def handle_event("prepare_opt_out", params, socket) do
    with %{item: item} = site <- find_site(socket, params),
         {:ok, impact} <- Sharing.opt_out_impact(socket.assigns.current_scope, item) do
      {:noreply, assign(socket, confirming: {site.type, item.id, impact})}
    else
      _ -> {:noreply, socket |> assign(confirming: nil) |> load_site_items()}
    end
  end

  def handle_event("cancel_opt_out", _params, socket) do
    {:noreply, assign(socket, confirming: nil)}
  end

  def handle_event("opt_out", params, socket) do
    socket = assign(socket, confirming: nil)

    case find_site(socket, params) do
      %{item: item} ->
        case Sharing.opt_out(socket.assigns.current_scope, item) do
          {:ok, _impact} ->
            gettext_comment("Flash after the viewer hides a site item from their lists.")

            {:noreply,
             socket
             |> put_flash(
               :info,
               dpgettext("sharing", "status: site item hidden for the viewer", "%{item_name} is hidden",
                 item_name: item.name
               )
             )
             |> load_site_items()}

          {:error, _reason} ->
            gettext_comment("Flash when the viewer may not hide a site item.")

            {:noreply,
             socket
             |> put_flash(:error, dpgettext("sharing", "status: hiding a site item refused", "You can't hide that"))
             |> load_site_items()}
        end

      nil ->
        {:noreply, load_site_items(socket)}
    end
  end

  def handle_event("opt_in", params, socket) do
    case find_site(socket, params) do
      %{item: item} ->
        :ok = Sharing.opt_in(socket.assigns.current_scope, item)
        gettext_comment("Flash after the viewer restores a hidden site item to their lists.")

        {:noreply,
         socket
         |> put_flash(
           :info,
           dpgettext("sharing", "status: hidden site item restored for the viewer", "%{item_name} is back",
             item_name: item.name
           )
         )
         |> load_site_items()}

      nil ->
        {:noreply, load_site_items(socket)}
    end
  end

  def handle_event("expand_site", params, socket) do
    case {find_site(socket, params), socket.assigns.site_card} do
      {%{type: type, item: %{id: id}}, %{type: type, id: id}} -> {:noreply, assign(socket, site_card: nil)}
      {%{type: type, item: item}, _open} -> {:noreply, assign(socket, site_card: site_card(socket, type, item))}
      {nil, _open} -> {:noreply, assign(socket, site_card: nil)}
    end
  end

  def handle_event("toggle", %{"type" => type, "id" => id, "enabled" => enabled}, socket)
      when type in ["lore_entry", "block", "script"] do
    row = with {:ok, id} <- Ecto.UUID.cast(id), do: Items.get(String.to_existing_atom(type), id)

    case row && Sharing.set_toggle(socket.assigns.current_scope, row, enabled == "true") do
      {:ok, _toggle} ->
        {:noreply, refresh_cards(socket)}

      _ ->
        gettext_comment("Flash when the viewer may not switch a shared entry, block or script on or off.")

        {:noreply,
         socket
         |> put_flash(:error, dpgettext("sharing", "status: switching a shared row refused", "You can't switch that"))
         |> refresh_cards()}
    end
  end

  def handle_event("connect", %{"connect" => %{"provider_id" => id}}, socket) do
    scope = socket.assigns.current_scope

    with %{type: :ai_model, item: model} <- socket.assigns.selected,
         {:ok, id} <- Ecto.UUID.cast(id),
         %AI.Provider{} = provider <- AI.get_provider(scope, id),
         {:ok, _link} <- AI.link_model(scope, provider, model) do
      gettext_comment("Flash after the viewer links a shared AI model to one of their connections.")

      {:noreply,
       socket
       |> put_flash(
         :info,
         dpgettext(
           "sharing",
           "status: shared AI model linked to a connection",
           "Connected %{model_name} to %{provider_name}",
           model_name: model.name,
           provider_name: provider.name
         )
       )
       |> refresh_cards()}
    else
      _ ->
        gettext_comment("Flash when linking a shared AI model to a connection fails.")

        {:noreply,
         socket
         |> put_flash(
           :error,
           dpgettext("sharing", "status: linking a shared AI model failed", "Could not connect that")
         )
         |> refresh_cards()}
    end
  end

  def handle_event("unlink", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with %{links: links} <- socket.assigns.ai_links,
         %AI.ProviderModel{} = link <- Enum.find(links, &(&1.id == id)),
         {:ok, _link} <- AI.delete_link(scope, link) do
      gettext_comment("Flash after the viewer removes a shared AI model's link to one of their connections.")

      {:noreply,
       socket
       |> put_flash(
         :info,
         dpgettext("sharing", "status: connection link removed", "Removed %{provider_name}",
           provider_name: link.provider.name
         )
       )
       |> refresh_cards()}
    else
      _ ->
        gettext_comment("Flash when removing a shared AI model's connection link fails.")

        {:noreply,
         socket
         |> put_flash(
           :error,
           dpgettext("sharing", "status: removing a connection link failed", "Could not remove that")
         )
         |> refresh_cards()}
    end
  end

  # The open cards again, after a toggle: the selected share's and the expanded site item's.
  defp refresh_cards(socket) do
    socket =
      case socket.assigns.selected do
        nil -> socket
        entry -> select(socket, entry)
      end

    refresh_site_card(socket)
  end

  defp refresh_site_card(socket) do
    case socket.assigns.site_card do
      %{type: type, id: id} ->
        case Enum.find(socket.assigns.site_items, &(&1.type == type and &1.item.id == id)) do
          %{item: item} -> assign(socket, site_card: site_card(socket, type, item))
          nil -> assign(socket, site_card: nil)
        end

      nil ->
        socket
    end
  end

  defp site_card(socket, type, item),
    do: %{type: type, id: item.id, card: Items.card(socket.assigns.current_scope, item)}

  defp clone(socket, type, item) do
    case Clone.clone(socket.assigns.current_scope, item) do
      {:ok, copy} ->
        {:noreply,
         socket
         |> put_flash(:info, cloned_message(item, copy))
         |> push_navigate(to: Items.edit_path(type, copy.id))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, clone_error_message(reason))}
    end
  end

  defp shared_title,
    do: dpgettext("sharing", "page title: items other accounts share with the viewer", "Shared with me")

  defp share_ended_flash do
    gettext_comment("Flash when the share the viewer has open ends elsewhere.")
    dpgettext("sharing", "status: open share ended", "That share has ended")
  end

  defp share_not_found_flash do
    gettext_comment("Flash when the share in the URL or being left no longer exists.")
    dpgettext("sharing", "status: share missing", "Share not found")
  end

  defp item_gone_flash do
    gettext_comment("Flash when the site item to clone no longer exists.")
    dpgettext("sharing", "status: site item missing", "That item is gone")
  end

  defp find(socket, id), do: Enum.find(socket.assigns.received, &(&1.id == id))

  defp find_site(socket, %{"type" => type, "id" => id}),
    do: Enum.find(socket.assigns.site_items, &(Atom.to_string(&1.type) == type and &1.item.id == id))

  defp find_site(_socket, _params), do: nil

  # The site's root items the viewer may see (a hidden book only with `site.hidden.view`), each with
  # whether it may clone it.
  defp load_site_items(socket) do
    scope = socket.assigns.current_scope

    items =
      for site <- Sharing.list_site_items(scope),
          not match?(%LoreBook{site_visibility: :hidden}, site.item) or Visibility.view_hidden?(scope),
          do: Map.put(site, :clonable?, Clone.clonable?(scope, site.item))

    assign(socket, site_items: items)
  end

  defp impact_sentence(impact) when map_size(impact) == 0, do: dgettext("sharing", "Nothing of yours uses it.")

  defp impact_sentence(impact) do
    parts =
      impact
      |> Enum.sort()
      |> Enum.map(fn {kind, n} -> Fallout.label(kind, n) end)
      |> Format.list()

    gettext_comment(
      "Confirmation before hiding a site item. %{impact_list} is a list of counted things, e.g. \"2 chat participants and 1 tag\"."
    )

    dgettext("sharing", "Also removes from your content: %{impact_list}.", impact_list: parts)
  end

  defp select(socket, %{share: share, item: item} = entry) do
    scope = socket.assigns.current_scope
    card = if share.role == :subscriber, do: Items.card(scope, item)

    assign(socket,
      selected: entry,
      card: card,
      selected_id: entry.id,
      clonable?: Clone.clonable?(scope, item),
      ai_links: ai_links(scope, entry)
    )
  end

  # An own-key model's links from the viewer's connections, and the viewer's other connections it
  # may still connect to; nil for anything else.
  defp ai_links(scope, %{type: :ai_model, share: %{ai_mode: :own_key}, item: model}) do
    links = AI.list_own_links(scope, model)
    linked = MapSet.new(links, & &1.provider_id)

    options =
      for provider <- AI.list_providers(scope),
          provider.user_id == scope.user.id and not MapSet.member?(linked, provider.id),
          do: {provider.name, provider.id}

    %{links: links, options: options, form: to_form(%{"provider_id" => ""}, as: :connect)}
  end

  defp ai_links(_scope, _entry), do: nil

  defp limit_text(nil),
    do: dpgettext("sharing", "status: shared AI model without a daily token limit", "No daily limit")

  defp limit_text(limit),
    do:
      dpngettext(
        "sharing",
        "status: daily token limit of a shared AI model",
        "Daily limit: %{token_limit} token",
        "Daily limit: %{token_limit} tokens",
        limit, token_limit: Format.number(limit))

  defp stream_shares(socket) do
    received =
      for {share, item} <- Sharing.list_received(socket.assigns.current_scope),
          do: %{id: share.id, share: share, item: item, type: share.item_type}

    socket
    |> assign(received: received)
    |> stream_search(:shares, received, &[&1.item.name, &1.share.owner.handle, &1.share.owner.nickname])
  end

  defp type_label(:character), do: dpgettext("sharing", "badge: kind of a shared item", "character")
  defp type_label(:lore_book), do: dpgettext("sharing", "badge: kind of a shared item", "lore book")
  defp type_label(:prompt), do: dpgettext("sharing", "badge: kind of a shared item", "prompt")
  defp type_label(:block), do: dpgettext("sharing", "badge: kind of a shared item", "prompt block")
  defp type_label(:outlet), do: dpgettext("sharing", "badge: kind of a shared item", "outlet")
  defp type_label(:script), do: dpgettext("sharing", "badge: kind of a shared item", "script")
  defp type_label(:memory_profile), do: dpgettext("sharing", "badge: kind of a shared item", "memory profile")
  defp type_label(:side_prompt), do: dpgettext("sharing", "badge: kind of a shared item", "side prompt")
  defp type_label(:side_prompt_set), do: dpgettext("sharing", "badge: kind of a shared item", "side prompt set")
  defp type_label(:ai_model), do: dpgettext("sharing", "badge: kind of a shared item", "AI model")

  defp shared_by(type, owner) do
    bindings = [owner_name: User.display_name(owner), owner_handle: owner.handle]

    case type do
      :character -> dgettext("sharing", "Character shared by %{owner_name} (@%{owner_handle}).", bindings)
      :lore_book -> dgettext("sharing", "Lore book shared by %{owner_name} (@%{owner_handle}).", bindings)
      :prompt -> dgettext("sharing", "Prompt shared by %{owner_name} (@%{owner_handle}).", bindings)
      :block -> dgettext("sharing", "Prompt block shared by %{owner_name} (@%{owner_handle}).", bindings)
      :outlet -> dgettext("sharing", "Outlet shared by %{owner_name} (@%{owner_handle}).", bindings)
      :script -> dgettext("sharing", "Script shared by %{owner_name} (@%{owner_handle}).", bindings)
      :memory_profile -> dgettext("sharing", "Memory profile shared by %{owner_name} (@%{owner_handle}).", bindings)
      :side_prompt -> dgettext("sharing", "Side prompt shared by %{owner_name} (@%{owner_handle}).", bindings)
      :side_prompt_set -> dgettext("sharing", "Side prompt set shared by %{owner_name} (@%{owner_handle}).", bindings)
      :ai_model -> dgettext("sharing", "AI model shared by %{owner_name} (@%{owner_handle}).", bindings)
    end
  end

  defp role_text(%{role: :editor}), do: dpgettext("sharing", "badge: viewer's role on a share", "Editor")

  defp role_text(%{role: :subscriber, visibility: :readable}),
    do: dpgettext("sharing", "badge: viewer's role and visibility on a share", "Subscriber, Readable")

  defp role_text(%{role: :subscriber, visibility: :runtime_only}),
    do: dpgettext("sharing", "badge: viewer's role and visibility on a share", "Subscriber, Runtime-only")

  defp role_sentence(%{role: :editor}),
    do: dpgettext("sharing", "status: viewer's role on a share, as a sentence", "Editor.")

  defp role_sentence(%{role: :subscriber, visibility: :readable}),
    do: dpgettext("sharing", "status: viewer's role and visibility on a share, as a sentence", "Subscriber, Readable.")

  defp role_sentence(%{role: :subscriber, visibility: :runtime_only}),
    do:
      dpgettext(
        "sharing",
        "status: viewer's role and visibility on a share, as a sentence",
        "Subscriber, Runtime-only."
      )

  defp hidden_hint(type) do
    gettext_comment(
      "%{field_list} is a list of the item's protected field names, e.g. \"description and personality\"."
    )

    dgettext("sharing", "Runtime-only: the model uses its %{field_list}, but you can't see them.",
      field_list: ItemFields.protected_labels(type)
    )
  end

  defp required_by_site,
    do: dpgettext("sharing", "status: site item the viewer can't hide or switch off", "Required by the site")

  defp site_meta(%{opted_out?: true, type: type}),
    do:
      dpgettext("sharing", "status: kind of a site item the viewer hid", "%{item_kind} · Hidden",
        item_kind: type_label(type)
      )

  defp site_meta(%{type: type}), do: type_label(type)

  defp hide_label, do: dpgettext("sharing", "button: hide a site item from the viewer's lists", "Hide")

  defp clone_label, do: dpgettext("sharing", "button: clone a shared or site item into the viewer's own", "Clone")

  defp connect_label,
    do:
      dpgettext(
        "sharing",
        "button: link a shared AI model to one of the viewer's connections",
        "Connect to my connection"
      )

  defp parts_heading(:lore_book), do: dpgettext("sharing", "heading: entries of a shared lore book", "Entries")
  defp parts_heading(_prompt), do: dpgettext("sharing", "heading: blocks of a shared prompt", "Blocks")

  defp leave_confirm(item) do
    gettext_comment("Confirm dialog before the viewer leaves a share.")
    dgettext("sharing", "Leave %{item_name}? You lose it and whatever of yours uses it.", item_name: item.name)
  end

  defp no_connections_hint do
    gettext_comment("%{add_link} is a link with the text \"Add one\" to the new AI connection page.")

    rich(
      dgettext("sharing", "You have no connections of your own. %{add_link} to run it.",
        add_link: navigate_link(dpgettext("sharing", "link: add a new AI connection", "Add one"), ~p"/ai/providers/new")
      )
    )
  end

  attr :type, :atom, required: true
  attr :row, :any, required: true
  attr :state, :any, required: true, doc: "`true`, `false` or `:forced` (`Items.card/2`'s switches)"
  attr :capabilities, :list, default: []

  # The viewer's own on/off switch over a row they don't own (`Sharing.set_toggle/3`). Enabling a
  # shared script first confirms what it may reach.
  defp toggle_switch(%{state: :forced} = assigns) do
    ~H"""
    <span id={"toggle-#{@type}-#{@row.id}"} class="shared-hint">{required_by_site()}</span>
    """
  end

  defp toggle_switch(assigns) do
    ~H"""
    <.button
      size="sm"
      id={"toggle-#{@type}-#{@row.id}"}
      phx-click="toggle"
      phx-value-type={@type}
      phx-value-id={@row.id}
      phx-value-enabled={to_string(!@state)}
      aria-pressed={to_string(@state)}
      data-confirm={enable_confirm(@type, @row, @state, @capabilities)}
    >
      <.lucide name={if @state, do: "toggle-right", else: "toggle-left"} />
      {switch_label(@type, @state)}
    </.button>
    """
  end

  defp switch_label(:script, true),
    do: dpgettext("sharing", "button: turn off a shared script for the viewer", "Disable")

  defp switch_label(:script, false),
    do: dpgettext("sharing", "button: turn on a shared script for the viewer", "Enable")

  defp switch_label(_type, true), do: dpgettext("sharing", "toggle: shared entry or block is on for the viewer", "On")

  defp switch_label(_type, false),
    do: dpgettext("sharing", "toggle: shared entry or block is off for the viewer", "Off")

  defp enable_confirm(:script, %{user_id: owner}, false, capabilities) when is_binary(owner) do
    case capabilities do
      [] ->
        gettext_comment("Confirm dialog before the viewer enables a shared script that uses no mw APIs.")
        dgettext("sharing", "This script uses none of the mw APIs. Enable it?")

      list ->
        gettext_comment(
          "Confirm dialog before the viewer enables a shared script. %{api_list} is a list of Lua API names, e.g. \"mw.chat and mw.vars\"."
        )

        dgettext("sharing", "This script will be able to: %{api_list}. Enable it?", api_list: Format.list(list))
    end
  end

  defp enable_confirm(_type, _row, _state, _capabilities), do: nil

  defp capabilities_text([]),
    do: dpgettext("sharing", "status: shared script reaches none of the Lua APIs", "Uses: no mw APIs")

  defp capabilities_text(list) do
    gettext_comment("%{api_list} is a list of Lua API names a script uses, e.g. \"mw.chat and mw.vars\".")
    dpgettext("sharing", "status: Lua APIs a shared script reaches", "Uses: %{api_list}", api_list: Format.list(list))
  end

  attr :id, :string, required: true
  attr :type, :atom, required: true
  attr :card, :map, required: true

  # What a script reaches (`Scripts.capabilities/1`), shown even to a Runtime-only viewer, and the
  # viewer's switch over it.
  defp script_access(assigns) do
    ~H"""
    <div :if={@type == :script} class="site-item-actions">
      <span id={"#{@id}-capabilities"} class="shared-hint">
        {capabilities_text(@card.capabilities)}
      </span>
      <span :if={@card.consent_changed?} id={"#{@id}-changed"} class="shared-hint">
        {dgettext("sharing", "Changed since you enabled it. Enable it again to run it.")}
      </span>
      <.toggle_switch
        :if={Map.has_key?(@card.switches, @card.item.id)}
        type={:script}
        row={@card.item}
        state={@card.switches[@card.item.id]}
        capabilities={@card.capabilities}
      />
    </div>
    <div
      :if={@type == :block and Map.has_key?(@card.switches, @card.item.id)}
      class="site-item-actions"
    >
      <.toggle_switch type={:block} row={@card.item} state={@card.switches[@card.item.id]} />
    </div>
    """
  end

  attr :card, :map, required: true

  # A book's entries or a prompt's blocks, each with the viewer's switch.
  defp card_parts(assigns) do
    ~H"""
    <ul class="shared-parts">
      <li :for={{part, readable?} <- @card.parts} id={"shared-part-#{part.id}"} class="shared-part">
        <div class="site-item-head">
          <span class="shared-part-name">{part.name}</span>
          <.toggle_switch
            :if={Map.has_key?(@card.switches, part.id)}
            type={Items.type_of(part)}
            row={part}
            state={@card.switches[part.id]}
          />
        </div>
        <ItemFields.item_fields
          id={"shared-part-#{part.id}"}
          type={Items.type_of(part)}
          row={part}
          readable?={readable?}
          hidden_hint={hidden_hint(Items.type_of(part))}
        />
      </li>
    </ul>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- `lower-bound="none"`: rules reach the `<img>` root of `<.avatar_image>`. --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      /* The editor slot's root; see AGENTS.md (CSS). */
      div.shared-editor-body:scope {
        display: contents;
      }

      .shared-fields {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
        margin: 0;
      }

      .shared-empty {
        color: var(--muted-foreground);
      }

      .shared-hint,
      .shared-about {
        margin: 0;
      }

      .shared-hint {
        color: var(--muted-foreground);
        font-size: 0.875rem;
      }

      .shared-avatar {
        inline-size: 10rem;

        & img {
          display: block;
          inline-size: 100%;
          border-radius: var(--radius-3);
        }
      }

      .shared-tags {
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

      .shared-parts {
        display: flex;
        flex-direction: column;
        gap: var(--size-3);
        margin: 0;
        padding: 0;
        list-style: none;
      }

      .shared-part {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
        padding: var(--size-2) var(--size-3);
        border: 1px solid var(--border);
        border-radius: var(--radius-2);
      }

      .shared-part-name {
        font-weight: var(--font-weight-6);
      }

      .site-item-head,
      .site-item-actions,
      .site-item-confirm {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: var(--size-2);
        margin: 0;
      }

      .site-item-head {
        justify-content: space-between;
      }
    </style>
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.pane_layout>
        <:list id="shares-nav" label={shared_title()}>
          <.pane_header title={shared_title()} />
          <.pane_search
            id="shares-filter"
            form={@filter_form}
            placeholder={
              dpgettext(
                "sharing",
                "placeholder: search shares by item name or owner",
                "Name or owner"
              )
            }
          />
          <.pane_items
            :let={entry}
            id="shares"
            rows={@streams.shares}
            empty?={@shares_empty?}
            empty={
              if @query == "",
                do:
                  dpgettext(
                    "sharing",
                    "empty state: nothing shared with the viewer",
                    "Nothing is shared with you yet"
                  ),
                else:
                  dpgettext(
                    "sharing",
                    "empty state: no shares match the search",
                    "No shares match this search"
                  )
            }
            selected_id={@selected_id}
            patch={fn entry -> ~p"/shared/#{entry.id}" end}
          >
            <span class="pane-item-name">{entry.item.name}</span>
            <span class="pane-item-meta">
              {dpgettext(
                "sharing",
                "status: kind, owner handle and viewer's role of a share",
                "%{item_kind} · @%{owner_handle} · %{share_role}",
                item_kind: type_label(entry.type),
                owner_handle: entry.share.owner.handle,
                share_role: role_text(entry.share)
              )}
            </span>
          </.pane_items>
        </:list>
        <:editor id="shared-editor">
          <div :if={is_nil(@selected)} class="shared-editor-body">
            <.panel_header sticky>
              {dpgettext("sharing", "heading: the site's own shared content", "Site content")}
            </.panel_header>
            <.pane_section id="site-content">
              <p class="shared-hint">
                {dgettext(
                  "sharing",
                  "Everyone may use the site's content. Hide what you don't want in your lists; Restore brings it back."
                )}
              </p>
              <p :if={@site_items == []} class="shared-empty">
                {dpgettext(
                  "sharing",
                  "empty state: the site has no shared content",
                  "The site has no content."
                )}
              </p>
              <ul id="site-items" class="shared-parts">
                <li
                  :for={site <- @site_items}
                  id={"site-item-#{site.type}-#{site.item.id}"}
                  class="shared-part"
                >
                  <div class="site-item-head">
                    <span>
                      <span class="shared-part-name">{site.item.name}</span>
                      <span class="shared-hint">
                        {site_meta(site)}
                      </span>
                    </span>
                    <span class="site-item-actions">
                      <span :if={site.forced?} class="shared-hint">{required_by_site()}</span>
                      <.button
                        :if={not site.forced? and not site.opted_out?}
                        size="sm"
                        id={"site-opt-out-#{site.type}-#{site.item.id}"}
                        phx-click="prepare_opt_out"
                        phx-value-type={site.type}
                        phx-value-id={site.item.id}
                      >
                        <.lucide name="eye-off" /> {hide_label()}
                      </.button>
                      <.button
                        :if={site.opted_out?}
                        size="sm"
                        id={"site-opt-out-#{site.type}-#{site.item.id}"}
                        phx-click="opt_in"
                        phx-value-type={site.type}
                        phx-value-id={site.item.id}
                      >
                        <.lucide name="eye" />
                        {dpgettext(
                          "sharing",
                          "button: show a hidden site item in the viewer's lists again",
                          "Restore"
                        )}
                      </.button>
                      <.button
                        :if={site.clonable?}
                        size="sm"
                        id={"site-clone-#{site.type}-#{site.item.id}"}
                        phx-click="clone_site"
                        phx-value-type={site.type}
                        phx-value-id={site.item.id}
                      >
                        <.lucide name="copy" /> {clone_label()}
                      </.button>
                      <.button
                        size="sm"
                        id={"site-expand-#{site.type}-#{site.item.id}"}
                        phx-click="expand_site"
                        phx-value-type={site.type}
                        phx-value-id={site.item.id}
                        aria-expanded={
                          to_string(
                            match?(
                              %{type: t, id: id} when t == site.type and id == site.item.id,
                              @site_card
                            )
                          )
                        }
                      >
                        <.lucide name="chevrons-up-down" />
                        {dpgettext("sharing", "button: expand a site item's details", "Details")}
                      </.button>
                    </span>
                  </div>
                  <p
                    :if={match?({t, id, _} when t == site.type and id == site.item.id, @confirming)}
                    class="site-item-confirm"
                  >
                    <span>{impact_sentence(elem(@confirming, 2))}</span>
                    <.button
                      size="sm"
                      danger
                      id={"site-opt-out-confirm-#{site.type}-#{site.item.id}"}
                      phx-click="opt_out"
                      phx-value-type={site.type}
                      phx-value-id={site.item.id}
                    >
                      {hide_label()}
                    </.button>
                    <.button size="sm" phx-click="cancel_opt_out">
                      {dpgettext(
                        "sharing",
                        "button: keep the site item, dismiss the hide confirmation",
                        "Cancel"
                      )}
                    </.button>
                  </p>
                  <div
                    :if={
                      match?(
                        %{type: t, id: id} when t == site.type and id == site.item.id,
                        @site_card
                      )
                    }
                    id={"site-card-#{site.type}-#{site.item.id}"}
                    class="shared-fields"
                  >
                    <ItemFields.item_fields
                      id="shared-card"
                      type={site.type}
                      row={@site_card.card.item}
                      readable?={@site_card.card.readable?}
                      hidden_hint={hidden_hint(site.type)}
                    />
                    <.script_access id="shared-card" type={site.type} card={@site_card.card} />
                    <.card_parts :if={@site_card.card.parts != []} card={@site_card.card} />
                  </div>
                </li>
              </ul>
            </.pane_section>
            <.pane_placeholder id="shared-placeholder">
              {dpgettext(
                "sharing",
                "empty state: no share selected",
                "Select something shared with you."
              )}
            </.pane_placeholder>
          </div>
          <div :if={@selected} class="shared-editor-body">
            <.panel_header sticky>
              {@selected.item.name}
              <:actions>
                <.button
                  :if={@card && @card.readable? && @clonable?}
                  size="sm"
                  id="shared-clone"
                  phx-click="clone_share"
                >
                  <.lucide name="copy" /> {clone_label()}
                </.button>
                <.button
                  size="sm"
                  danger
                  id="shared-leave"
                  phx-click="leave"
                  phx-value-id={@selected.id}
                  data-confirm={leave_confirm(@selected.item)}
                >
                  {dpgettext("sharing", "button: leave a share someone gave the viewer", "Leave")}
                </.button>
              </:actions>
            </.panel_header>
            <.pane_section id="shared-about">
              <p class="shared-about">
                {shared_by(@selected.type, @selected.share.owner)} {role_sentence(@selected.share)}
              </p>
              <.button
                :if={@selected.share.role == :editor}
                variant="primary"
                id="shared-edit"
                navigate={Items.edit_path(@selected.type, @selected.item.id)}
              >
                <.lucide name="pencil" />
                {dpgettext("sharing", "button: open the shared item's editor", "Open editor")}
              </.button>
            </.pane_section>
            <.pane_section :if={@card} id="shared-card">
              <div :if={:avatar in Items.fields(@selected.type)} class="shared-avatar">
                <.avatar_image
                  avatar={@card.item}
                  preset={:portrait}
                  sizes="160px"
                  alt={@card.item.name}
                />
              </div>
              <ul :if={@card.tags != []} id="shared-card-tags" class="shared-tags">
                <li :for={tag <- @card.tags}>{tag}</li>
              </ul>
              <ItemFields.item_fields
                id="shared-card"
                type={@selected.type}
                row={@card.item}
                readable?={@card.readable?}
                hidden_hint={hidden_hint(@selected.type)}
              />
              <.script_access id="shared-card" type={@selected.type} card={@card} />
            </.pane_section>
            <.pane_section :if={@selected.type == :ai_model} id="shared-ai">
              <.section_header>
                {dpgettext(
                  "sharing",
                  "heading: whose connection a shared AI model runs on",
                  "Connection"
                )}
              </.section_header>
              <div :if={@selected.share.ai_mode == :owner_key} class="shared-fields">
                <p id="shared-ai-mode" class="shared-about">
                  {dpgettext(
                    "sharing",
                    "status: shared AI model runs on its owner's connection",
                    "Runs on @%{owner_handle}'s connection.",
                    owner_handle: @selected.share.owner.handle
                  )}
                </p>
                <p id="shared-ai-limit" class="shared-hint">
                  {limit_text(@selected.share.token_limit_per_day)}
                </p>
              </div>
              <div :if={@ai_links} class="shared-fields">
                <p id="shared-ai-mode" class="shared-about">
                  {dgettext("sharing", "Runs on your own connection: connect one of yours to use it.")}
                </p>
                <ul id="shared-links" class="shared-parts">
                  <li :for={link <- @ai_links.links} id={"shared-link-#{link.id}"} class="shared-part">
                    <div class="site-item-head">
                      <span class="shared-part-name">{link.provider.name}</span>
                      <.button
                        size="sm"
                        danger
                        id={"shared-unlink-#{link.id}"}
                        phx-click="unlink"
                        phx-value-id={link.id}
                      >
                        {dpgettext(
                          "sharing",
                          "button: remove the link from the viewer's connection to a shared AI model",
                          "Remove"
                        )}
                      </.button>
                    </div>
                  </li>
                </ul>
                <p :if={@ai_links.links == []} id="shared-links-empty" class="shared-empty">
                  {dgettext("sharing", "None of your connections runs it yet.")}
                </p>
                <.form
                  :if={@ai_links.options != []}
                  for={@ai_links.form}
                  id="shared-connect"
                  class="site-item-actions"
                  phx-submit="connect"
                >
                  <.input
                    field={@ai_links.form[:provider_id]}
                    type="select"
                    id="shared-connect-provider"
                    aria-label={connect_label()}
                    options={@ai_links.options}
                  />
                  <.button type="submit" variant="primary">{connect_label()}</.button>
                </.form>
                <p
                  :if={@ai_links.options == [] and @ai_links.links == []}
                  id="shared-connect-none"
                  class="shared-hint"
                >
                  {no_connections_hint()}
                </p>
              </div>
            </.pane_section>
            <.pane_section :if={@card && @card.parts != []} id="shared-parts">
              <.section_header>
                {parts_heading(@selected.type)}
              </.section_header>
              <.card_parts card={@card} />
            </.pane_section>
          </div>
        </:editor>
      </.pane_layout>
    </Layouts.app>
    """
  end
end
