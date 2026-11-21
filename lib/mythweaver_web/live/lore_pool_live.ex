defmodule MythweaverWeb.LorePoolLive do
  @moduledoc """
  Lore pool editor: the pool list on the left, the selected pool's form and its members on the
  right. `:index` selects nothing: the editor pane shows a placeholder until a pool is picked.

  A pool caps how many of its entries activate in one prompt (`Mythweaver.Lore.LorePool`). Entries
  join a pool, and set their weight and flags in it, from the entry form (`MythweaverWeb.Lore.EntryForm`);
  the member list here links to each entry's editor.

  The pools stream carries an explicit `dom_id` because the default (`pools-<id>`) does not match
  the `lore-pools-<id>` id contract. It lists only pools the scope may edit (`Lore.list_pools/1`).
  """

  use MythweaverWeb, :live_view

  import MythweaverWeb.Pane

  alias Mythweaver.Lore
  alias Mythweaver.Lore.LorePool
  alias Mythweaver.Ownership
  alias MythweaverWeb.CoreComponents.OwnerSelect
  alias MythweaverWeb.LiveSync

  on_mount {MythweaverWeb.ContentAccess, :lore}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: dpgettext("lore", "page title: list of lore pools", "Lore pools"),
       form: nil,
       editing_pool: nil,
       new_owner: "personal",
       selected_id: nil
     )
     |> stream_configure(:pools, dom_id: &"lore-pools-#{&1.id}")
     |> assign_filter()
     |> stream_pools()
     |> LiveSync.attach_editor([:lore], &sync/2)}
  end

  defp sync(socket, _kinds) do
    scope = socket.assigns.current_scope

    socket
    |> stream_pools()
    |> LiveSync.sync_open(:editing_pool,
      fetch: &Lore.get_pool(scope, &1),
      clean?: LiveSync.clean?(socket.assigns.form),
      reload: fn s, fresh -> assign(s, form: to_form(Lore.change_pool(fresh)), editing_pool: fresh) end,
      gone: ~p"/lore/pools",
      gone_message:
        (
          gettext_comment("Flash shown when the pool open in the editor was deleted or moved by someone else.")
          dgettext("lore", "The pool was deleted or moved elsewhere.")
        )
    )
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(
      form: nil,
      editing_pool: nil,
      selected_id: nil,
      page_title: dpgettext("lore", "page title: list of lore pools", "Lore pools")
    )
    |> stream_pools()
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(
      form: to_form(Lore.change_pool(%LorePool{})),
      editing_pool: nil,
      new_owner: "personal",
      selected_id: nil,
      page_title: dpgettext("lore", "page title: create a lore pool", "New pool")
    )
    |> stream_pools()
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Lore.get_pool(socket.assigns.current_scope, id) do
      nil ->
        socket
        |> put_flash(:error, pool_not_found())
        |> push_patch(to: ~p"/lore/pools")

      pool ->
        socket
        |> assign(
          form: to_form(Lore.change_pool(pool)),
          editing_pool: pool,
          selected_id: pool.id,
          page_title: pool.name
        )
        |> stream_pools()
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, socket |> assign_filter(params) |> stream_pools()}
  end

  def handle_event("validate", %{"lore_pool" => params} = all, socket) do
    changeset =
      (socket.assigns.editing_pool || %LorePool{})
      |> Lore.change_pool(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset), new_owner: OwnerSelect.choice(all))}
  end

  def handle_event("save", %{"lore_pool" => params} = all, socket) do
    scope = socket.assigns.current_scope

    result =
      case socket.assigns.editing_pool do
        nil -> Lore.create_pool(scope, params, OwnerSelect.create_opts(OwnerSelect.choice(all)))
        pool -> Lore.update_pool(scope, pool, params)
      end

    case result do
      {:ok, pool} ->
        {:noreply,
         socket
         |> put_flash(:info, saved_flash(pool.name))
         |> push_patch(to: ~p"/lore/pools/#{pool.id}/edit")}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(:error, save_failed_flash())}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Lore.get_pool(scope, id) do
      nil ->
        {:noreply, socket}

      pool ->
        result = Lore.delete_pool(scope, pool)
        {:noreply, MythweaverWeb.HandOff.after_delete(socket, result, pool.name, ~p"/lore/pools")}
    end
  end

  defp stream_pools(socket) do
    stream_search(socket, :pools, Lore.list_pools(socket.assigns.current_scope), &[&1.name, &1.description])
  end

  defp members(%LorePool{pool_entries: members}), do: Enum.sort_by(members, &String.downcase(&1.entry.name))

  defp pool_not_found do
    gettext_comment("Flash when the lore pool in the URL does not exist or is not visible.")
    dpgettext("lore", "status: flash when the lore pool in the URL is not found", "Pool not found")
  end

  defp saved_flash(pool_name) do
    gettext_comment("Flash after a lore pool is saved.")
    dpgettext("lore", "status: flash after saving a lore pool", "%{pool_name} saved", pool_name: pool_name)
  end

  defp save_failed_flash do
    gettext_comment("Flash when saving an editor form fails validation; the invalid fields are highlighted.")
    dgettext("lore", "Could not save — see the highlighted fields")
  end

  defp delete_confirm(pool_name) do
    gettext_comment("Confirm dialog before deleting a lore pool.")

    dgettext("lore", "Delete %{pool_name}? Its entries stay; they just leave the pool.", pool_name: pool_name)
  end

  defp pool_meta(pool) do
    n = length(pool.pool_entries)

    dngettext(
      "lore",
      "%{entry_count} entry · admits %{max_activations}",
      "%{entry_count} entries · admits %{max_activations}",
      n,
      entry_count: Mythweaver.Format.number(n),
      max_activations: Mythweaver.Format.number(pool.max_activations)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!--
      `lower-bound="none"`: rules here may reach inside `<.input>`'s own template,
      which is a nested-component root carrying `phx-r` that the default exclusive bound cuts off.
    --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      /* The editor slot's root. `pane_layout`'s `<section>` carries no marker from this block, so
         without it `<.form>` and the members would sit outside this scope. */
      div.lore-pool-editor-body:scope {
        display: contents;
      }

      .lore-pool-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .lore-pool-hint {
        margin: 0;
        color: var(--muted-foreground);
      }

      .lore-pool-members {
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
        margin: 0;
        padding: 0;
        list-style: none;
      }

      .lore-pool-member {
        display: grid;
        grid-template-columns: minmax(0, 1fr) auto auto;
        gap: var(--size-2);
        align-items: center;
      }

      .lore-pool-member a {
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }

      .lore-pool-member-weight {
        color: var(--muted-foreground);
        font-variant-numeric: tabular-nums;
      }

      .lore-pool-member-flags {
        display: flex;
        gap: var(--size-1);
      }
    </style>
    <Layouts.app flash={@flash} current_scope={@current_scope} search={:lore}>
      <.pane_layout>
        <:list
          id="lore-pools-nav"
          label={dpgettext("lore", "aria label: list of lore pools", "Lore pools")}
        >
          <.pane_header title={dpgettext("lore", "heading: list of lore pools", "Pools")}>
            <:switch id="pane-switch-lore" navigate={~p"/lore"}>
              <.lucide name="book-open" /> {dpgettext(
                "lore",
                "link: switch to the lore books list",
                "Books"
              )}
            </:switch>
          </.pane_header>
          <.pane_actions>
            <.button variant="primary" size="sm" patch={~p"/lore/pools/new"} id="new-lore-pool">
              <.lucide name="plus" /> {dpgettext("lore", "button: create a lore pool", "New pool")}
            </.button>
          </.pane_actions>
          <.pane_search
            id="lore-pool-filter"
            form={@filter_form}
            placeholder={dpgettext("lore", "placeholder: search lore pools", "Name or description")}
          />
          <.pane_items
            :let={pool}
            id="lore-pools"
            rows={@streams.pools}
            empty?={@pools_empty?}
            empty={
              if @query == "",
                do: dpgettext("lore", "empty state: no lore pools exist", "No pools yet"),
                else:
                  dpgettext(
                    "lore",
                    "empty state: no lore pools match the search",
                    "No pools match this search"
                  )
            }
            selected_id={@selected_id}
            patch={fn pool -> ~p"/lore/pools/#{pool.id}/edit" end}
          >
            <span class="pane-item-name">{pool.name}</span>
            <span class="pane-item-meta">
              {pool_meta(pool)}
            </span>
          </.pane_items>
        </:list>
        <:editor id="lore-pool-editor">
          <.pane_placeholder :if={@live_action == :index} id="lore-pool-placeholder">
            {dgettext("lore", "Select a pool, or create a new one.")}
          </.pane_placeholder>
          <div :if={@live_action != :index} class="lore-pool-editor-body">
            <.panel_header sticky>
              {if @editing_pool,
                do: @editing_pool.name,
                else: dpgettext("lore", "heading: create a lore pool", "New pool")}
              <:actions :if={@editing_pool && Ownership.deletable?(@current_scope, @editing_pool)}>
                <.pane_delete
                  id="delete-lore-pool"
                  confirm={delete_confirm(@editing_pool.name)}
                  phx-click="delete"
                  phx-value-id={@editing_pool.id}
                >
                  {dpgettext("lore", "button: delete this lore pool", "Delete")}
                </.pane_delete>
              </:actions>
            </.panel_header>

            <.pane_section>
              <p class="lore-pool-hint">
                {dgettext(
                  "lore",
                  "A pool limits how many of its entries can activate in one prompt. When more of them match than it admits, a weighted draw picks the winners; each entry's weight and flags are set in its own editor, under Pools."
                )}
              </p>
              <.changed_elsewhere
                :if={@changed_elsewhere?}
                id="lore-pool-changed-elsewhere"
                patch={@live_sync_path}
              />
              <.form
                for={@form}
                id="lore-pool-form"
                class="lore-pool-form"
                phx-hook="UnsavedChanges"
                data-saved={is_nil(@form.action)}
                phx-change="validate"
                phx-submit="save"
              >
                <.owner_select
                  :if={is_nil(@editing_pool)}
                  id="lore-pool-form-owner"
                  scope={@current_scope}
                  schema={LorePool}
                  value={@new_owner}
                />
                <.input
                  field={@form[:name]}
                  type="text"
                  label={dpgettext("lore", "field label: name of a lore pool", "Name")}
                  id="lore-pool-form-name"
                  required
                />
                <.input
                  field={@form[:max_activations]}
                  type="number"
                  min="1"
                  label={
                    dpgettext(
                      "lore",
                      "field label: how many entries of a lore pool may be active at once",
                      "Admits (entries active at once)"
                    )
                  }
                  id="lore-pool-form-max_activations"
                  required
                />
                <.editor
                  field={@form[:description]}
                  label={dpgettext("lore", "field label: description of a lore pool", "Description")}
                  rows={2}
                  id="lore-pool-form-description"
                  language="markdown"
                  spellcheck
                />
                <.form_actions>
                  <.button patch={
                    if @editing_pool,
                      do: ~p"/lore/pools/#{@editing_pool.id}/edit",
                      else: ~p"/lore/pools"
                  }>
                    {dpgettext("lore", "button: discard edits to the open form", "Cancel")}
                  </.button>
                  <.button type="submit" variant="primary">
                    {dpgettext("lore", "button: save the open form", "Save")}
                  </.button>
                </.form_actions>
              </.form>
            </.pane_section>

            <.pane_section :if={@editing_pool} id="lore-pool-members-section">
              <.section_header>
                {dpgettext("lore", "heading: entries in a lore pool", "Entries")}
              </.section_header>
              <p
                :if={@editing_pool.pool_entries == []}
                id="lore-pool-members-empty"
                class="lore-pool-hint"
              >
                {dgettext("lore", "No entries yet. Add one from its editor's Pools field.")}
              </p>
              <ul
                :if={@editing_pool.pool_entries != []}
                id="lore-pool-members"
                class="lore-pool-members"
              >
                <li
                  :for={member <- members(@editing_pool)}
                  id={"lore-pool-member-#{member.entry.id}"}
                  class="lore-pool-member"
                >
                  <.link navigate={~p"/lore/entries/#{member.entry.id}/edit"}>{member.entry.name}</.link>
                  <span class="lore-pool-member-weight">
                    {dpgettext(
                      "lore",
                      "unit: draw weight of an entry in a lore pool",
                      "weight %{pool_weight}",
                      pool_weight: Mythweaver.Format.number(member.weight)
                    )}
                  </span>
                  <span class="lore-pool-member-flags">
                    <.badge :if={member.override}>
                      {dpgettext("lore", "badge: pool entry overrides the pool limit", "Override")}
                    </.badge>
                    <.badge :if={member.scored}>
                      {dpgettext("lore", "badge: pool entry is scored in the draw", "Scored")}
                    </.badge>
                  </span>
                </li>
              </ul>
            </.pane_section>
          </div>
        </:editor>
      </.pane_layout>
    </Layouts.app>
    """
  end
end
