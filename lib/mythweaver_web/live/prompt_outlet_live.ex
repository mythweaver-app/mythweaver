defmodule MythweaverWeb.PromptOutletLive do
  @moduledoc """
  Custom outlet editor: the outlet list on the left, the selected outlet's form on the right.
  `:index` selects nothing: the editor pane shows a placeholder until an outlet is picked.
  Outlets are the named injection points a lore entry can target.

  The outlets stream carries an explicit `dom_id` because the default
  (`outlets-<id>`) does not match the `prompt-outlets-<id>` id contract.
  """

  use MythweaverWeb, :live_view

  import MythweaverWeb.Pane

  alias Mythweaver.Ownership
  alias Mythweaver.Prompts
  alias Mythweaver.Prompts.Outlet
  alias MythweaverWeb.CoreComponents.OwnerSelect
  alias MythweaverWeb.LiveSync

  on_mount {MythweaverWeb.ContentAccess, :prompts}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: dpgettext("prompts", "page title: list of custom prompt outlets", "Custom outlets"),
       form: nil,
       editing_outlet: nil,
       new_owner: "personal",
       selected_id: nil
     )
     |> stream_configure(:outlets, dom_id: &"prompt-outlets-#{&1.id}")
     |> assign_filter()
     |> stream_outlets()
     |> LiveSync.attach_editor([:prompts], &sync/2)}
  end

  defp sync(socket, _kinds) do
    scope = socket.assigns.current_scope
    form = socket.assigns.form

    socket
    |> stream_outlets()
    |> LiveSync.sync_open(:editing_outlet,
      fetch: &Prompts.get_editable_outlet(scope, &1),
      clean?: LiveSync.clean?(form),
      reload: fn s, fresh ->
        assign(s, form: to_form(Prompts.change_outlet(fresh)), editing_outlet: fresh)
      end,
      gone: ~p"/prompts/outlets",
      gone_message:
        (
          gettext_comment("Flash shown when the outlet open in the editor was deleted or moved by someone else.")
          dgettext("prompts", "The outlet was deleted or moved elsewhere.")
        )
    )
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(form: nil, editing_outlet: nil, selected_id: nil)
    |> stream_outlets()
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(
      form: to_form(Prompts.change_outlet(%Outlet{})),
      editing_outlet: nil,
      new_owner: "personal",
      selected_id: nil
    )
    |> stream_outlets()
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Prompts.get_editable_outlet(socket.assigns.current_scope, id) do
      nil ->
        socket
        |> put_flash(:error, not_found_flash())
        |> push_patch(to: ~p"/prompts/outlets")

      outlet ->
        socket
        |> assign(
          form: to_form(Prompts.change_outlet(outlet)),
          editing_outlet: outlet,
          selected_id: outlet.id
        )
        |> stream_outlets()
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, socket |> assign_filter(params) |> stream_outlets()}
  end

  def handle_event("validate", %{"outlet" => params} = all, socket) do
    changeset =
      socket
      |> target_outlet()
      |> Prompts.change_outlet(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset), new_owner: OwnerSelect.choice(all))}
  end

  def handle_event("save", %{"outlet" => params} = all, socket) do
    result =
      case socket.assigns.editing_outlet do
        nil ->
          Prompts.create_outlet(socket.assigns.current_scope, params, OwnerSelect.create_opts(OwnerSelect.choice(all)))

        outlet ->
          Prompts.update_outlet(socket.assigns.current_scope, outlet, params)
      end

    case result do
      {:ok, outlet} ->
        {:noreply,
         socket
         |> put_flash(:info, saved_flash(outlet.name))
         |> push_patch(to: ~p"/prompts/outlets/#{outlet.id}/edit")}

      {:held, hold} ->
        path =
          case socket.assigns.editing_outlet do
            nil -> ~p"/prompts/outlets"
            outlet -> ~p"/prompts/outlets/#{outlet.id}/edit"
          end

        {:noreply, socket |> flash_held(hold) |> push_patch(to: path)}

      {:error, :hold_limit} ->
        {:noreply, flash_hold_limit(socket)}

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
    case Prompts.get_editable_outlet(socket.assigns.current_scope, id) do
      nil ->
        {:noreply, socket}

      outlet ->
        result = Prompts.delete_outlet(socket.assigns.current_scope, outlet)
        {:noreply, MythweaverWeb.HandOff.after_delete(socket, result, outlet.name, ~p"/prompts/outlets")}
    end
  end

  defp target_outlet(socket), do: socket.assigns.editing_outlet || %Outlet{}

  defp not_found_flash do
    gettext_comment("Flash when the outlet in the address no longer exists or cannot be edited.")
    dpgettext("prompts", "status: flash, the custom outlet to edit was not found", "Outlet not found")
  end

  defp saved_flash(outlet_name) do
    gettext_comment("Flash after a custom outlet was saved.")

    dpgettext("prompts", "status: flash after a custom outlet was saved", "%{outlet_name} saved",
      outlet_name: outlet_name
    )
  end

  defp save_failed_flash do
    gettext_comment("Flash when saving an editor form fails validation; the invalid fields are highlighted.")
    dgettext("prompts", "Could not save — see the highlighted fields")
  end

  defp delete_confirm(outlet_name) do
    gettext_comment("Confirm dialog before deleting a custom outlet.")

    dpgettext("prompts", "button: confirm dialog, delete a custom outlet", "Delete %{outlet_name}?",
      outlet_name: outlet_name
    )
  end

  defp stream_outlets(socket) do
    stream_search(
      socket,
      :outlets,
      Prompts.list_editable_outlets(socket.assigns.current_scope),
      &[&1.name, &1.key, &1.description]
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
         without it `<.form>` and the hint would sit outside this scope. */
      div.prompt-outlet-editor-body:scope {
        display: contents;
      }

      .prompt-outlet-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .prompt-outlet-form label {
        display: block;
      }

      .prompt-outlet-hint {
        margin: 0;
        color: var(--muted-foreground);
      }
    </style>
    <Layouts.app flash={@flash} current_scope={@current_scope} search={:prompts}>
      <.pane_layout>
        <:list
          id="prompt-outlets-nav"
          label={dpgettext("prompts", "aria label: list of custom prompt outlets", "Custom outlets")}
        >
          <.pane_header title={
            dpgettext("prompts", "heading: list of custom prompt outlets", "Custom outlets")
          }>
            <:switch id="pane-switch-prompts" navigate={~p"/prompts"}>
              <.lucide name="messages-square" /> {dpgettext(
                "prompts",
                "link: switch to the prompts list",
                "Prompts"
              )}
            </:switch>
            <:switch id="pane-switch-blocks" navigate={~p"/prompts/blocks"}>
              <.lucide name="blocks" /> {dpgettext(
                "prompts",
                "link: switch to the prompt blocks list",
                "Blocks"
              )}
            </:switch>
          </.pane_header>
          <.pane_actions>
            <.button variant="primary" patch={~p"/prompts/outlets/new"} id="new-prompt-outlet">
              <.lucide name="plus" /> {dpgettext(
                "prompts",
                "button: create a custom prompt outlet",
                "New outlet"
              )}
            </.button>
          </.pane_actions>
          <.pane_search
            id="prompt-outlet-filter"
            form={@filter_form}
            placeholder={
              dpgettext(
                "prompts",
                "placeholder: search custom prompt outlets",
                "Name, key, or description"
              )
            }
          />
          <.pane_items
            :let={outlet}
            id="prompt-outlets"
            rows={@streams.outlets}
            empty?={@outlets_empty?}
            empty={
              if @query == "",
                do:
                  dpgettext(
                    "prompts",
                    "empty state: no custom prompt outlets exist",
                    "No custom outlets yet"
                  ),
                else:
                  dpgettext(
                    "prompts",
                    "empty state: no custom prompt outlets match the search",
                    "No outlets match this search"
                  )
            }
            selected_id={@selected_id}
            patch={fn outlet -> ~p"/prompts/outlets/#{outlet.id}/edit" end}
          >
            <span class="pane-item-name">{outlet.name}</span>
            <span class="pane-item-meta">{outlet.key}</span>
          </.pane_items>
        </:list>
        <:editor id="prompt-outlet-editor">
          <.pane_placeholder :if={@live_action == :index} id="prompt-outlet-placeholder">
            {dgettext("prompts", "Select an outlet, or create a new one.")}
          </.pane_placeholder>
          <div :if={@live_action != :index} class="prompt-outlet-editor-body">
            <.panel_header sticky>
              {if @editing_outlet,
                do: @editing_outlet.name,
                else:
                  dpgettext("prompts", "heading: form for a new custom prompt outlet", "New outlet")}
              <:actions :if={@editing_outlet}>
                <.live_component
                  :if={Ownership.deletable?(@current_scope, @editing_outlet)}
                  module={MythweaverWeb.HandOff}
                  id="prompt-outlet-handoff"
                  thing="prompt-outlet"
                  current_scope={@current_scope}
                  item={@editing_outlet}
                  delete={&Prompts.delete_outlet/3}
                  index={~p"/prompts/outlets"}
                  delete_id="delete-prompt-outlet"
                  confirm={delete_confirm(@editing_outlet.name)}
                />
              </:actions>
            </.panel_header>
            <.live_component
              :if={@editing_outlet}
              module={MythweaverWeb.Lineage}
              id="prompt-outlet-lineage-line"
              thing="prompt-outlet"
              current_scope={@current_scope}
              item={@editing_outlet}
            />

            <.pane_section>
              <p class="prompt-outlet-hint">
                {dgettext(
                  "prompts",
                  "A custom outlet is a named injection point. A lore entry set to the Custom outlet targets one by key, and a prompt block renders whatever activated into it."
                )}
              </p>
              <.changed_elsewhere
                :if={@changed_elsewhere?}
                id="prompt-outlet-changed-elsewhere"
                patch={@live_sync_path}
              />
              <.form
                for={@form}
                id="prompt-outlet-form"
                class="prompt-outlet-form"
                phx-hook="UnsavedChanges"
                data-saved={is_nil(@form.action)}
                phx-change="validate"
                phx-submit="save"
              >
                <.owner_select
                  :if={is_nil(@editing_outlet)}
                  id="prompt-outlet-form-owner"
                  scope={@current_scope}
                  schema={Outlet}
                  value={@new_owner}
                />
                <.input
                  field={@form[:key]}
                  type="text"
                  label={
                    dpgettext(
                      "prompts",
                      "field label: stable key of a custom prompt outlet",
                      "Key (stable id: lowercase, numbers, underscores)"
                    )
                  }
                  id="prompt-outlet-form-key"
                  required
                />
                <.input
                  field={@form[:name]}
                  type="text"
                  label={dpgettext("prompts", "field label: name of a custom prompt outlet", "Name")}
                  id="prompt-outlet-form-name"
                  required
                />
                <.editor
                  field={@form[:description]}
                  label={
                    dpgettext(
                      "prompts",
                      "field label: description of a custom prompt outlet",
                      "Description"
                    )
                  }
                  rows={2}
                  id="prompt-outlet-form-description"
                  language="markdown"
                  spellcheck
                />
                <.form_actions>
                  <.button patch={
                    if @editing_outlet,
                      do: ~p"/prompts/outlets/#{@editing_outlet.id}/edit",
                      else: ~p"/prompts/outlets"
                  }>
                    {dpgettext("prompts", "button: cancel editing the open form", "Cancel")}
                  </.button>
                  <.button type="submit" variant="primary">
                    {dpgettext("prompts", "button: save the open form", "Save")}
                  </.button>
                </.form_actions>
              </.form>
            </.pane_section>
            <.live_component
              :if={@editing_outlet}
              module={MythweaverWeb.SharePanel}
              id="prompt-outlet-share"
              current_scope={@current_scope}
              item={@editing_outlet}
            />
          </div>
        </:editor>
      </.pane_layout>
    </Layouts.app>
    """
  end
end
