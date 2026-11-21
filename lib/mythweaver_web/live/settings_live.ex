defmodule MythweaverWeb.SettingsLive do
  @moduledoc """
  The settings page (`Mythweaver.Settings`): a category tree with search on the left, one row per
  setting on the right (label and description, the control, a "Modified" badge and reset when this
  level overrides it). A section with a `grid` shows its settings as a table instead, a cell per
  setting with its reset (and, at the Site level, lock) beside the control. Every signed-in user
  edits their own (User) level; admins switch to the Site level, where they also lock
  user-overridable settings.

  Each control is its own `phx-change` form (or a toggle button pushing the same `"set"`), so a
  change saves at once.

  The Notifications category at the User level also shows `MythweaverWeb.PushDevices` while Web
  Push is configured, whose events (`"push_*"`) this LiveView handles.
  """
  use MythweaverWeb, :live_view

  import MythweaverWeb.Pane

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Messages.Cleanup
  alias Mythweaver.Notifications
  alias Mythweaver.Notifications.WebPush
  alias Mythweaver.Settings
  alias Mythweaver.Stylesheets
  alias MythweaverWeb.LiveSync
  alias MythweaverWeb.NotificationsHook
  alias MythweaverWeb.PushDevices
  alias Phoenix.HTML.Form

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign_filter()
     |> assign(
       page_title: dpgettext("settings", "page title: settings page", "Settings"),
       push_state: nil,
       push_devices: [],
       push_testing: MapSet.new(),
       cleanup_running?: false
     )
     |> LiveSync.attach([:settings], fn socket, _kinds -> load(socket) end)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    scope = socket.assigns.current_scope
    level = if params["level"] == "site" and Scope.can?(scope, "site.settings.manage"), do: :site, else: :user

    {:noreply,
     socket
     |> assign(level: level, requested_category: params["category"])
     |> load()}
  end

  @impl true
  def handle_event("set", %{"setting" => %{"key" => key, "value" => value}}, socket) do
    socket.assigns.current_scope
    |> Settings.put(socket.assigns.level, key, value)
    |> respond(socket, key)
  end

  def handle_event("reset", %{"key" => key}, socket) do
    socket.assigns.current_scope
    |> Settings.reset(socket.assigns.level, key)
    |> respond(socket, key)
  end

  def handle_event("lock", %{"setting" => %{"key" => key, "users_may_change" => may_change}}, socket) do
    socket.assigns.current_scope
    |> Settings.lock(key, may_change != "true")
    |> respond(socket, key)
  end

  def handle_event("filter", params, socket) do
    {:noreply, socket |> assign_filter(params) |> assign_groups()}
  end

  def handle_event("push_state", %{"status" => status} = params, socket) when is_binary(status) do
    endpoint = if is_binary(params["endpoint"]), do: params["endpoint"]
    {:noreply, assign(socket, push_state: %{"status" => status, "endpoint" => endpoint})}
  end

  def handle_event("push_subscribe", %{"subscription" => %{} = subscription, "label" => label}, socket)
      when is_binary(label) do
    case Notifications.subscribe_device(socket.assigns.current_scope, subscription, label) do
      {:ok, _device} ->
        {:reply, %{ok: true}, load_devices(socket)}

      {:error, _changeset} ->
        {:reply, %{ok: false}, put_flash(socket, :error, message(:push_rejected))}
    end
  end

  def handle_event("push_unsubscribe", %{"endpoint" => endpoint}, socket) do
    case Enum.find(socket.assigns.push_devices, &(&1.endpoint == endpoint)) do
      nil -> {:noreply, socket}
      device -> remove_device(socket, device.id)
    end
  end

  def handle_event("push_remove", %{"id" => id}, socket), do: remove_device(socket, id)

  def handle_event("push_test", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    {:noreply,
     socket
     |> assign(push_testing: MapSet.put(socket.assigns.push_testing, id))
     |> start_async({:push_test, id}, Mythweaver.Locale.carry(fn -> Notifications.test_device(scope, id) end))}
  end

  def handle_event("cleanup_now", _params, %{assigns: %{cleanup_running?: true}} = socket), do: {:noreply, socket}

  def handle_event("cleanup_now", _params, socket) do
    scope = socket.assigns.current_scope
    level = socket.assigns.level

    {:noreply,
     socket
     |> assign(cleanup_running?: true)
     |> start_async(
       :cleanup,
       Mythweaver.Locale.carry(fn ->
         if level == :site, do: Cleanup.clean_up_all(scope), else: Cleanup.clean_up_mine(scope)
       end)
     )}
  end

  @impl true
  def handle_async({:push_test, id}, result, socket) do
    socket =
      case result do
        {:ok, :ok} ->
          put_flash(socket, :info, message(:test_sent))

        {:ok, :gone} ->
          put_flash(socket, :error, message(:device_gone))

        {:ok, {:error, :not_found}} ->
          put_flash(socket, :error, message(:device_missing))

        {:ok, {:error, _reason}} ->
          put_flash(socket, :error, message(:test_failed))

        {:exit, _reason} ->
          put_flash(socket, :error, message(:test_failed))
      end

    {:noreply, socket |> assign(push_testing: MapSet.delete(socket.assigns.push_testing, id)) |> load_devices()}
  end

  def handle_async(:cleanup, result, socket) do
    socket = assign(socket, cleanup_running?: false)

    socket =
      case result do
        {:ok, {:ok, stats}} -> put_flash(socket, :info, Cleanup.summary(stats))
        {:ok, {:error, :unauthorized}} -> put_flash(socket, :error, message(:cleanup_unauthorized))
        {:exit, _reason} -> put_flash(socket, :error, message(:cleanup_failed))
      end

    {:noreply, socket}
  end

  # Already gone counts as removed.
  defp remove_device(socket, id) do
    _ = Notifications.remove_device(socket.assigns.current_scope, id)
    {:noreply, load_devices(socket)}
  end

  defp message(:push_rejected) do
    gettext_comment("Flash on the settings page when the server refuses this browser's push subscription.")
    dgettext("settings", "This browser's push subscription was not accepted.")
  end

  defp message(:test_sent) do
    gettext_comment("Flash after sending a test push notification to one of the user's devices.")
    dpgettext("settings", "status: flash after sending a test push notification", "Test notification sent.")
  end

  defp message(:device_gone) do
    gettext_comment("Flash when a test push finds the device unsubscribed; the device is removed from the list.")
    dgettext("settings", "That device no longer accepts push notifications, so it was removed.")
  end

  defp message(:device_missing) do
    gettext_comment("Flash when a test push is asked for a device that was already removed.")
    dpgettext("settings", "status: flash when testing a push device that was already removed", "That device is gone.")
  end

  defp message(:test_failed) do
    gettext_comment("Flash when sending a test push notification fails.")
    dgettext("settings", "The test notification could not be sent.")
  end

  defp message(:cleanup_unauthorized) do
    gettext_comment("Flash when someone without the permission runs the site-wide chat cleanup.")
    dgettext("settings", "You can't clean up every user's chats.")
  end

  defp message(:cleanup_failed) do
    gettext_comment("Flash when a chat cleanup started from the settings page crashes.")
    dpgettext("settings", "status: flash when the site-wide chat cleanup crashed", "The cleanup failed.")
  end

  defp message(:unauthorized) do
    gettext_comment("Flash when a setting change, reset or lock is refused for lack of permission.")
    dgettext("settings", "You can't change that setting.")
  end

  defp setting_error(setting_name, reason) do
    gettext_comment(
      "Flash when a setting value is refused: the setting's name, then the reason, a short lowercase phrase such as \"must be at least 1\"."
    )

    dpgettext("settings", "status: a setting change was refused, with the reason", "%{setting_name}: %{error_reason}",
      setting_name: setting_name,
      error_reason: reason
    )
  end

  defp load_devices(%{assigns: %{push_panel?: true}} = socket),
    do: assign(socket, push_devices: Notifications.list_devices(socket.assigns.current_scope))

  defp load_devices(socket), do: assign(socket, push_devices: [])

  # A language or regional format change re-renders everything, `<html lang>` included, so it
  # reloads the page: both are set by `MythweaverWeb.Locale` once per request.
  defp respond(:ok, socket, key)
       when key in [
              "appearance.language",
              "appearance.default_language",
              "appearance.locale",
              "appearance.default_locale"
            ], do: {:noreply, redirect(socket, to: settings_path("appearance", socket.assigns.level))}

  defp respond(:ok, socket, _key), do: {:noreply, load(socket)}

  defp respond({:error, :unauthorized}, socket, _key),
    do: {:noreply, socket |> put_flash(:error, message(:unauthorized)) |> load()}

  defp respond({:error, message}, socket, key) do
    label = Enum.find_value(socket.assigns.entries, key, &(&1.key == key && &1.label))
    {:noreply, socket |> put_flash(:error, setting_error(label, message)) |> load()}
  end

  # Re-reads every entry at the current level, then the tree and the editor's groups.
  defp load(socket) do
    entries = Settings.entries(socket.assigns.current_scope, socket.assigns.level)
    visible = MapSet.new(entries, & &1.category)
    categories = Enum.filter(Settings.categories(), &MapSet.member?(visible, &1.id))

    category =
      Enum.find(categories, &(&1.id == socket.assigns.requested_category)) || List.first(categories)

    socket
    |> assign(entries: entries, categories: categories, category: category && category.id)
    |> assign(tint: Settings.get_many(socket.assigns.current_scope, Layouts.tint_keys()))
    |> assign(
      custom_style_imports:
        Layouts.custom_style_imports(socket.assigns.current_scope, socket.assigns[:safe_mode?] == true)
    )
    |> assign_groups()
  end

  # The editor's rows as `[%{category, sections: [%{section, entries}]}]`: the current category, or
  # every match across categories while searching. Then the push devices, when their panel shows.
  defp assign_groups(socket) do
    %{entries: entries, categories: categories, category: category, query: query} = socket.assigns

    entries =
      if searching?(query),
        do: search(entries, query, &[&1.label, &1.description, &1.key]),
        else: Enum.filter(entries, &(&1.category == category))

    by_section = Enum.group_by(entries, &{&1.category, &1.section})

    groups =
      for cat <- categories,
          sections =
            for(
              sec <- cat.sections,
              rows = Map.get(by_section, {cat.id, sec.id}, []),
              rows != [],
              do: %{section: sec, entries: rows}
            ),
          sections != [],
          do: %{category: cat, sections: sections}

    socket
    |> assign(
      groups: groups,
      push_panel?:
        socket.assigns.level == :user and category == "notifications" and not searching?(query) and
          WebPush.configured?()
    )
    |> load_devices()
  end

  defp searching?(query), do: String.trim(to_string(query)) != ""

  defp settings_path(category, :user), do: ~p"/settings/#{category}"
  defp settings_path(category, :site), do: ~p"/settings/#{category}?level=site"

  defp dom(key), do: String.replace(key, ".", "-")

  defp value_form(entry), do: to_form(%{"key" => entry.key, "value" => form_value(entry)}, as: :setting)

  defp lock_form(entry), do: to_form(%{"key" => entry.key, "users_may_change" => !entry.locked?}, as: :setting)

  defp form_value(%{type: :select, value: value}), do: to_string(value)
  defp form_value(%{type: :multi_select, value: values}), do: Enum.map(values, &to_string/1)

  defp form_value(%{type: type, value: value})
       when type in [
              :model,
              :side_prompt_set,
              :expression_profile,
              :caption_prompt,
              :language,
              :locale,
              :template,
              :css
            ], do: value || ""

  defp form_value(%{type: :origins, value: values}), do: Enum.join(values, " ")

  defp form_value(%{value: value}), do: value

  defp form_options(options), do: Enum.map(options, fn {value, label} -> {label, to_string(value)} end)

  @impl true
  def render(assigns) do
    ~H"""
    <%!--
      `lower-bound="none"`: the tree's links are `<.link>` roots, which the default exclusive bound
      would cut off, leaving them in the global link colour. Root rules are tag-qualified.
    --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      div.settings-tree:scope {
        padding: 0 var(--size-1) var(--size-2);
      }

      .settings-tree-summary {
        display: flex;
        align-items: center;
        gap: var(--size-2);
        padding: var(--size-1) var(--size-2);
        border-radius: var(--radius-2);
        cursor: pointer;
        list-style: none;
      }

      .settings-tree-summary::-webkit-details-marker {
        display: none;
      }

      .settings-tree-chevron {
        flex: none;
        line-height: 0;
        color: var(--muted-foreground);
        transition: transform 0.15s;
      }

      details[open] > .settings-tree-summary .settings-tree-chevron {
        transform: rotate(90deg);
      }

      .settings-tree-category {
        flex: 1;
        min-inline-size: 0;
        overflow-wrap: anywhere;
        color: inherit;
        font-weight: 600;
        text-decoration: none;
      }

      .settings-tree-children {
        list-style: none;
        margin: 0;
        padding: 0 0 0 var(--size-4);
      }

      .settings-tree-section {
        display: flex;
        padding: 0 var(--size-2);
        border-radius: var(--radius-2);
      }

      .settings-tree-section > a {
        flex: 1;
        min-inline-size: 0;
        padding: var(--size-1) 0;
        overflow-wrap: anywhere;
        color: inherit;
        text-decoration: none;
      }

      .settings-tree-summary:hover,
      .settings-tree-section:hover {
        background: var(--surface-4);
      }

      .settings-tree-summary[aria-current="page"] {
        background-color: color-mix(in oklab, var(--primary-accent) 13%, transparent);
        color: var(--primary-accent);
      }

      div.settings-editor-body:scope {
        display: contents;
      }

      .settings-groups {
        display: flex;
        flex-direction: column;
        gap: var(--size-4);
        padding: var(--size-3) var(--size-4) var(--size-6);
      }

      .settings-group {
        display: flex;
        flex-direction: column;
        gap: var(--size-4);
      }

      .settings-category-label {
        margin: 0;
        color: var(--muted-foreground);
        font-size: 0.85rem;
        text-transform: uppercase;
        letter-spacing: 0.04em;
      }

      /* Clear of the sticky panel header when a tree link scrolls a section into view. */
      .settings-section {
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
        scroll-margin-block-start: var(--size-9);
      }

      .settings-empty,
      .settings-section-description {
        margin: 0;
        color: var(--muted-foreground);
      }

      .settings-section-description {
        font-size: 0.9rem;
      }
    </style>

    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <span
        id="custom-styles-sync"
        hidden
        phx-hook=".CustomStylesSync"
        data-imports={@custom_style_imports}
      ></span>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".CustomStylesSync">
        // The root layout's `<style id="custom-styles">` is never patched; after a save changes a sheet's
        // version, point its `@import`s at the new URLs so the page restyles without a reload.
        export default {
          updated() {
            const style = document.getElementById("custom-styles");
            if (style && style.textContent !== this.el.dataset.imports)
              style.textContent = this.el.dataset.imports;
          },
        };
      </script>
      <.pane_layout>
        <:list
          id="settings-nav"
          label={dpgettext("settings", "aria label: settings navigation list", "Settings")}
        >
          <.pane_header title={dpgettext("settings", "heading: settings page", "Settings")} />
          <.pane_search
            id="settings-search"
            form={@filter_form}
            placeholder={
              dpgettext("settings", "placeholder: search field for settings", "Search settings…")
            }
          />

          <div id="settings-tree" class="settings-tree">
            <details
              :for={cat <- @categories}
              id={"settings-tree-#{cat.id}"}
              open={cat.id == @category}
            >
              <summary class="settings-tree-summary" aria-current={cat.id == @category && "page"}>
                <span class="settings-tree-chevron" aria-hidden="true"><.lucide name="chevron-right" /></span>
                <.link patch={settings_path(cat.id, @level)} class="settings-tree-category">{cat.label}</.link>
              </summary>
              <ul class="settings-tree-children">
                <li
                  :for={sec <- cat.sections}
                  id={"settings-tree-#{cat.id}-#{sec.id}"}
                  class="settings-tree-section"
                >
                  <.link patch={settings_path(cat.id, @level) <> "#settings-section-#{cat.id}-#{sec.id}"}>
                    {sec.label}
                  </.link>
                </li>
              </ul>
            </details>
          </div>
        </:list>

        <:editor id="settings-editor">
          <div class="settings-editor-body">
            <.panel_header sticky>
              {if searching?(@query),
                do: dpgettext("settings", "heading: settings search results", "Search results"),
                else:
                  Enum.find_value(
                    @categories,
                    dpgettext("settings", "heading: settings page", "Settings"),
                    &(&1.id == @category && &1.label)
                  )}
              <:actions :if={Scope.can?(@current_scope, "site.settings.manage")}>
                <.tabs
                  id="settings-level"
                  label={
                    dpgettext(
                      "settings",
                      "aria label: tabs that switch between user and site settings",
                      "Settings level"
                    )
                  }
                  active={to_string(@level)}
                >
                  <:tab
                    :for={
                      {level, label} <- [
                        user: dpgettext("settings", "tab: settings for your own account", "User"),
                        site: dpgettext("settings", "tab: settings for the whole site", "Site")
                      ]
                    }
                    name={to_string(level)}
                    patch={settings_path(@category, level)}
                  >
                    {label}
                  </:tab>
                </.tabs>
              </:actions>
            </.panel_header>

            <div class="settings-groups">
              <p :if={@groups == []} id="settings-empty" class="settings-empty">
                {dpgettext(
                  "settings",
                  "empty state: settings search found nothing",
                  "No matching settings."
                )}
              </p>

              <div :for={group <- @groups} class="settings-group">
                <h2 :if={searching?(@query)} class="settings-category-label">
                  {group.category.label}
                </h2>
                <section
                  :for={%{section: sec, entries: rows} <- group.sections}
                  id={"settings-section-#{group.category.id}-#{sec.id}"}
                  class="settings-section"
                >
                  <.section_header>{sec.label}</.section_header>
                  <p :if={sec[:description]} class="settings-section-description">
                    {sec.description}
                  </p>
                  <%= if sec[:grid] do %>
                    <.setting_grid
                      id={"settings-grid-#{group.category.id}-#{sec.id}"}
                      grid={sec.grid}
                      entries={rows}
                      level={@level}
                    />
                  <% else %>
                    <%= for entry <- rows do %>
                      <.setting_row entry={entry} level={@level} tint={@tint} />
                      <.cleanup_now
                        :if={entry.key == "cleanup.automatic"}
                        level={@level}
                        running?={@cleanup_running?}
                        allowed?={@level == :user or Scope.can?(@current_scope, "site.cleanup.run")}
                      />
                    <% end %>
                  <% end %>
                </section>
              </div>

              <PushDevices.panel
                :if={@push_panel?}
                public_key={WebPush.public_key()}
                devices={@push_devices}
                state={@push_state}
                testing={@push_testing}
              />
            </div>
          </div>
        </:editor>
      </.pane_layout>
    </Layouts.app>
    """
  end

  attr :level, :atom, required: true
  attr :running?, :boolean, required: true
  attr :allowed?, :boolean, required: true

  defp cleanup_now(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="inclusive">
      div.settings-cleanup:scope {
        display: grid;
        grid-template-columns: minmax(0, 1fr) auto;
        gap: var(--size-1) var(--size-4);
        align-items: center;
        padding: var(--size-2) 0;
        border-block-end: 1px solid var(--border-grey);
      }

      .settings-cleanup-text {
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
        min-inline-size: 0;
      }

      .settings-cleanup-title {
        font-weight: 600;
      }

      .settings-cleanup-description {
        margin: 0;
        color: var(--muted-foreground);
        font-size: 0.9rem;
      }
    </style>
    <div :if={@allowed?} id="settings-cleanup" class="settings-cleanup">
      <div class="settings-cleanup-text">
        <span class="settings-cleanup-title">
          {if @level == :site,
            do: dpgettext("settings", "heading: cleanup of every user's chats", "Clean up all chats"),
            else: dpgettext("settings", "heading: cleanup of your own chats", "Clean up my chats")}
        </span>
        <p class="settings-cleanup-description">
          {if @level == :site,
            do: dgettext("settings", "Cleans every user's chats now, with the Site values below."),
            else:
              dgettext(
                "settings",
                "Cleans your chats now, with the values below, whether or not automatic cleanup is on."
              )}
        </p>
      </div>
      <.button id="settings-cleanup-now" size="sm" phx-click="cleanup_now" disabled={@running?}>
        <.lucide name="brush-cleaning" />
        {if @running?,
          do: dpgettext("settings", "status: chat cleanup running", "Cleaning…"),
          else: dpgettext("settings", "button: run chat cleanup now", "Clean up now")}
      </.button>
    </div>
    """
  end

  attr :entry, :map, required: true
  attr :level, :atom, required: true
  attr :tint, :map, required: true, doc: "the viewer's effective tint settings, by key, for the tint sliders"

  defp setting_row(assigns) do
    entry = assigns.entry

    assigns =
      assign(assigns,
        dom: dom(entry.key),
        form: value_form(entry),
        lock_form: lock_form(entry),
        blocked?: entry.type == :css and Stylesheets.blocked?(entry.value, entry[:restriction])
      )

    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="inclusive">
      div.settings-row:scope {
        display: grid;
        grid-template-columns: minmax(0, 1fr) auto;
        gap: var(--size-1) var(--size-4);
        align-items: center;
        padding: var(--size-2) 0;
        border-block-end: 1px solid var(--border-grey);
      }

      .settings-row-text {
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
        min-inline-size: 0;
      }

      .settings-row-title {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: var(--size-2);
        font-weight: 600;
      }

      .settings-row-description,
      .settings-row-locked {
        margin: 0;
        color: var(--muted-foreground);
        font-size: 0.9rem;
      }

      .settings-row-controls {
        display: flex;
        flex-direction: column;
        align-items: flex-end;
        gap: var(--size-1);
      }

      .settings-row-control {
        display: flex;
        align-items: center;
        gap: var(--size-2);
      }

      div.settings-row-template:scope {
        grid-template-columns: minmax(0, 1fr);
      }

      div.settings-row-template:scope .settings-row-controls {
        align-items: stretch;
      }

      div.settings-row-template:scope .settings-row-control > form {
        flex: 1;
        min-inline-size: 0;
      }

      @media (--phone) {
        div.settings-row:scope {
          grid-template-columns: minmax(0, 1fr);
        }
        .settings-row-controls {
          align-items: flex-start;
        }
      }
    </style>
    <div
      id={"settings-#{@dom}"}
      class={["settings-row", @entry.type in [:template, :css] && "settings-row-template"]}
    >
      <div class="settings-row-text">
        <span class="settings-row-title">
          {@entry.label}
          <.badge :if={@entry.modified?} id={"setting-#{@dom}-modified"}>
            {dpgettext("settings", "badge: setting overridden at this level", "Modified")}
          </.badge>
        </span>
        <p class="settings-row-description">{@entry.description}</p>
        <p
          :if={@level == :user and @entry.locked?}
          id={"setting-#{@dom}-locked"}
          class="settings-row-locked"
        >
          <.lucide name="lock" /> {dpgettext(
            "settings",
            "status: setting locked by an admin",
            "Locked by an admin"
          )}
        </p>
        <p :if={@blocked?} id={"setting-#{@dom}-blocked"} class="settings-row-locked">
          <.lucide name="shield-alert" />
          {dgettext(
            "settings",
            "Not applied: it loads outside files, which the site no longer allows."
          )}
        </p>
      </div>

      <div class="settings-row-controls">
        <div class="settings-row-control">
          <.reset_button entry={@entry} dom={@dom} />
          <.form for={@form} id={"setting-#{@dom}-form"} phx-change="set" phx-submit="set">
            <.control form={@form} entry={@entry} dom={@dom} tint={@tint} />
          </.form>
        </div>

        <.form
          :if={@level == :site and :user in @entry.levels}
          for={@lock_form}
          id={"setting-#{@dom}-lock-form"}
          phx-change="lock"
        >
          <input type="hidden" name="setting[key]" value={@entry.key} />
          <.input
            field={@lock_form[:users_may_change]}
            type="checkbox"
            id={"setting-#{@dom}-users-may-change"}
            label={
              dpgettext(
                "settings",
                "field label: checkbox letting users override a site setting",
                "Users may change"
              )
            }
          />
        </.form>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :grid, :map, required: true
  attr :entries, :list, required: true
  attr :level, :atom, required: true

  # Rows and columns with no entry (filtered out by a search, or a setting that is not available)
  # are left out.
  defp setting_grid(assigns) do
    cells = Map.new(assigns.entries, &{&1.cell, &1})
    columns = Enum.filter(assigns.grid.columns, fn col -> Enum.any?(assigns.entries, &(elem(&1.cell, 1) == col.id)) end)
    rows = Enum.filter(assigns.grid.rows, fn row -> Enum.any?(columns, &Map.has_key?(cells, {row.id, &1.id})) end)

    assigns = assign(assigns, cells: cells, rows: rows, columns: columns)

    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="inclusive">
      table.settings-grid:scope {
        inline-size: 100%;
        border-collapse: collapse;
        background: none;
        box-shadow: none;
        border: 0;
      }

      /* The reset shades table headers; this table sits flat on its panel. */
      thead,
      tbody,
      tr,
      th,
      td {
        background: none;
      }

      th,
      td {
        padding: var(--size-2) 0;
        border: none;
        border-block-end: 1px solid var(--border-grey);
        vertical-align: middle;
      }

      thead :where(th, td) {
        padding-block-start: 0;
        color: var(--muted-foreground);
        font-size: 0.85rem;
        font-weight: 600;
        border-block-end: 0;
      }

      .settings-grid-column {
        inline-size: 1%;
        padding-inline-start: var(--size-4);
        white-space: nowrap;
        text-align: center;
      }

      tbody th {
        text-align: start;
        font-weight: normal;
      }

      .settings-grid-row-label {
        display: block;
        font-weight: 600;
      }

      .settings-grid-row-description {
        margin: 0;
        color: var(--muted-foreground);
        font-size: 0.9rem;
      }

      @media (--phone) {
        table.settings-grid:scope {
          display: block;
          overflow-x: auto;
        }
      }
    </style>
    <table id={@id} class="settings-grid">
      <thead>
        <tr>
          <td></td>
          <th :for={col <- @columns} scope="col" class="settings-grid-column">{col.label}</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={row <- @rows} id={"#{@id}-#{row.id}"}>
          <th scope="row">
            <span class="settings-grid-row-label">{row.label}</span>
            <p :if={row[:description]} class="settings-grid-row-description">{row.description}</p>
          </th>
          <td :for={col <- @columns} class="settings-grid-column">
            <.setting_cell
              :for={entry <- List.wrap(@cells[{row.id, col.id}])}
              entry={entry}
              control={col.control}
              level={@level}
            />
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  attr :entry, :map, required: true
  attr :control, :atom, required: true, values: [:checkbox, :speaker]
  attr :level, :atom, required: true

  defp setting_cell(assigns) do
    entry = assigns.entry
    assigns = assign(assigns, dom: dom(entry.key), form: value_form(entry))

    ~H"""
    <%!-- Its own block: the grid's styles stop at this component's root. --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      /* The control sits in the middle track, under its column heading; reset and lock sit to its
         right, so they never shift it. */
      span.settings-grid-cell:scope {
        display: grid;
        grid-template-columns: 4rem max-content 4rem;
        align-items: center;
        gap: var(--size-1);
      }

      .settings-grid-cell-control {
        grid-column: 2;
        display: flex;
        gap: var(--size-1);
      }

      .settings-grid-cell-extras {
        grid-column: 3;
        display: flex;
        align-items: center;
        gap: var(--size-1);
      }
    </style>
    <span id={"settings-#{@dom}"} class="settings-grid-cell" title={@entry.description}>
      <span class="settings-grid-cell-control">
        <%= if @control == :speaker do %>
          <.button
            size="sm"
            icon
            id={"setting-#{@dom}-value"}
            aria-label={@entry.label}
            aria-pressed={to_string(@entry.value)}
            disabled={!@entry.editable?}
            phx-click={JS.push("set", value: %{setting: %{key: @entry.key, value: !@entry.value}})}
          >
            <.lucide :if={@entry.value} name="volume-2" />
            <.lucide :if={!@entry.value} name="volume-x" />
          </.button>
          <%!-- Plays even with the sound off or locked: it only previews it. --%>
          <.button
            size="sm"
            icon
            id={"setting-#{@dom}-play"}
            aria-label={
              dpgettext(
                "settings",
                "aria label: icon button that plays a notification sound preview",
                "Play the %{setting_name} preview",
                setting_name: @entry.label
              )
            }
            title={
              dpgettext("settings", "tooltip: play a notification sound preview", "Play this sound")
            }
            phx-click={
              JS.dispatch("notifications:play",
                detail: %{src: NotificationsHook.sound_path(elem(@entry.cell, 0))}
              )
            }
          >
            <.lucide name="play" />
          </.button>
        <% else %>
          <.form for={@form} id={"setting-#{@dom}-form"} phx-change="set" phx-submit="set">
            <.control form={@form} entry={@entry} dom={@dom} />
          </.form>
        <% end %>
      </span>
      <span class="settings-grid-cell-extras">
        <.lucide :if={@level == :user and @entry.locked?} name="lock" />
        <.reset_button entry={@entry} dom={@dom} />
        <.button
          :if={@level == :site and :user in @entry.levels}
          size="sm"
          icon
          id={"setting-#{@dom}-lock"}
          aria-label={
            dpgettext(
              "settings",
              "aria label: icon button that locks a setting so users read the site value",
              "Lock %{setting_name} for users",
              setting_name: @entry.label
            )
          }
          aria-pressed={to_string(@entry.locked?)}
          title={
            if @entry.locked?,
              do:
                dpgettext(
                  "settings",
                  "tooltip: lock button while users read the site value",
                  "Locked: users read the site value"
                ),
              else:
                dpgettext(
                  "settings",
                  "tooltip: lock button while users may change the setting",
                  "Users may change"
                )
          }
          phx-click={
            JS.push("lock",
              value: %{setting: %{key: @entry.key, users_may_change: to_string(@entry.locked?)}}
            )
          }
        >
          <.lucide :if={@entry.locked?} name="lock" />
          <.lucide :if={!@entry.locked?} name="lock-open" />
        </.button>
      </span>
    </span>
    """
  end

  attr :entry, :map, required: true
  attr :dom, :string, required: true

  # Always rendered, hidden while there is nothing to reset: inserted on the first save, it would sit
  # before the form, and LiveView's patch moves the keyed form past it, which blurs whatever control
  # in it has focus (a slider mid-drag, the editor mid-typing).
  defp reset_button(assigns) do
    ~H"""
    <.button
      hidden={!(@entry.modified? and @entry.editable?)}
      size="sm"
      icon
      id={"setting-#{@dom}-reset"}
      phx-click="reset"
      phx-value-key={@entry.key}
      aria-label={
        dpgettext(
          "settings",
          "aria label: icon button that resets a setting to the inherited value",
          "Reset %{setting_name}",
          setting_name: @entry.label
        )
      }
      title={dpgettext("settings", "tooltip: reset a setting to the inherited value", "Reset")}
    >
      <.lucide name="rotate-ccw" />
    </.button>
    """
  end

  attr :form, Form, required: true
  attr :entry, :map, required: true
  attr :dom, :string, required: true
  attr :tint, :map, default: %{}

  defp control(%{entry: %{type: :boolean}} = assigns) do
    ~H"""
    <input type="hidden" name="setting[key]" value={@entry.key} />
    <.input
      field={@form[:value]}
      type="checkbox"
      id={"setting-#{@dom}-value"}
      disabled={!@entry.editable?}
      aria-label={@entry.label}
    />
    """
  end

  # A tint slider (`control: :hue` sets `--tint-h`, `:tint_strength` `--tint-strength`) previews on the
  # whole page while dragging; after each save's re-render it shows the viewer's effective value
  # again, which differs from the slider at the Site level under a user override.
  defp control(%{entry: %{control: control}} = assigns) when control in [:hue, :tint_strength] do
    {property, suffix} = if control == :hue, do: {"--tint-h", "°"}, else: {"--tint-strength", "%"}
    assigns = assign(assigns, property: property, suffix: suffix, control: control)

    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      span.settings-tint:scope {
        display: flex;
        align-items: center;
        gap: var(--size-2);
      }

      .settings-tint-slider {
        appearance: none;
        inline-size: max(10rem, min(20vw, 15rem));
        block-size: var(--size-3);
        margin: 0;
        border-radius: var(--radius-round);
        cursor: pointer;
      }

      .settings-tint-slider-hue {
        background: linear-gradient(
          to right,
          oklch(0.6 0.2 0),
          oklch(0.6 0.2 60),
          oklch(0.6 0.2 120),
          oklch(0.6 0.2 180),
          oklch(0.6 0.2 240),
          oklch(0.6 0.2 300),
          oklch(0.6 0.2 360)
        );
        background: linear-gradient(
          to right in oklch longer hue,
          oklch(0.6 0.2 0),
          oklch(0.6 0.2 0)
        );
      }

      /* Grey at 0%, then ever more of the current hue. */
      .settings-tint-slider-tint_strength {
        background: linear-gradient(
          to right,
          oklch(0.6 0 var(--tint-h)),
          oklch(0.6 0.2 var(--tint-h))
        );
      }

      .settings-tint-slider:disabled {
        cursor: not-allowed;
        opacity: 0.6;
      }

      .settings-tint-slider::-webkit-slider-thumb {
        appearance: none;
        inline-size: 1.25rem;
        block-size: 1.25rem;
        border-radius: var(--radius-round);
        background: oklch(0.6 0.2 var(--tint-h));
        border: 2px solid var(--background);
        box-shadow: var(--elevation-xs);
      }

      .settings-tint-slider::-moz-range-thumb {
        inline-size: 1.25rem;
        block-size: 1.25rem;
        border-radius: var(--radius-round);
        background: oklch(0.6 0.2 var(--tint-h));
        border: 2px solid var(--background);
        box-shadow: var(--elevation-xs);
      }

      .settings-tint-value {
        min-inline-size: 4ch;
        font-variant-numeric: tabular-nums;
        text-align: end;
      }

      @media (--phone) {
        .settings-tint-slider {
          inline-size: min(max(10rem, min(20vw, 15rem)), 100%);
        }
      }
    </style>
    <input type="hidden" name="setting[key]" value={@entry.key} />
    <span class="settings-tint">
      <input
        type="range"
        id={"setting-#{@dom}-value"}
        class={["settings-tint-slider", "settings-tint-slider-#{@control}"]}
        name="setting[value]"
        value={@form[:value].value}
        min={@entry.min}
        max={@entry.max}
        step="1"
        disabled={!@entry.editable?}
        aria-label={@entry.label}
        phx-debounce="250"
        phx-hook=".TintSlider"
        data-property={@property}
        data-suffix={@suffix}
        data-effective={@tint[@entry.key]}
        data-output={"setting-#{@dom}-output"}
      />
      <output id={"setting-#{@dom}-output"} for={"setting-#{@dom}-value"} class="settings-tint-value">
        {@form[:value].value}{@suffix}
      </output>
    </span>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".TintSlider">
      // Sets the `<html>` custom property (`data-property`) every color token is built on: while the
      // slider is focused, the slider's value; otherwise the viewer's effective one from the server.
      export default {
        mounted() {
          this.el.addEventListener("input", () => {
            this.sync();
            const output = document.getElementById(this.el.dataset.output);
            if (output)
              output.textContent = `${this.el.value}${this.el.dataset.suffix}`;
          });
          this.el.addEventListener("blur", () => this.sync());
          this.sync();
        },
        updated() {
          this.sync();
        },
        sync() {
          const focused = document.activeElement === this.el;
          const value = focused ? this.el.value : this.el.dataset.effective;
          document.documentElement.style.setProperty(this.el.dataset.property, value);
        },
      };
    </script>
    """
  end

  defp control(%{entry: %{type: :integer}} = assigns) do
    ~H"""
    <input type="hidden" name="setting[key]" value={@entry.key} />
    <.input
      field={@form[:value]}
      type="number"
      id={"setting-#{@dom}-value"}
      min={@entry[:min]}
      max={@entry[:max]}
      step="1"
      disabled={!@entry.editable?}
      phx-debounce="blur"
      aria-label={@entry.label}
    />
    """
  end

  defp control(%{entry: %{type: :origins}} = assigns) do
    ~H"""
    <input type="hidden" name="setting[key]" value={@entry.key} />
    <.input
      field={@form[:value]}
      type="text"
      id={"setting-#{@dom}-value"}
      disabled={!@entry.editable?}
      phx-debounce="blur"
      aria-label={@entry.label}
      placeholder="https://use.typekit.net"
    />
    """
  end

  defp control(%{entry: %{type: type}} = assigns)
       when type in [:select, :model, :side_prompt_set, :expression_profile, :caption_prompt, :language, :locale] do
    assigns = assign(assigns, prompt: select_prompt(assigns.entry))

    ~H"""
    <input type="hidden" name="setting[key]" value={@entry.key} />
    <.input
      field={@form[:value]}
      type="select"
      id={"setting-#{@dom}-value"}
      prompt={@prompt}
      options={form_options(@entry.options)}
      disabled={!@entry.editable?}
      aria-label={@entry.label}
    />
    """
  end

  defp control(%{entry: %{type: :multi_select}} = assigns) do
    ~H"""
    <input type="hidden" name="setting[key]" value={@entry.key} />
    <%!-- Hidden "": an emptied multi-select posts no key at all. --%>
    <input type="hidden" name="setting[value][]" value="" />
    <.input
      field={@form[:value]}
      type="select"
      multiple
      id={"setting-#{@dom}-value"}
      options={form_options(@entry.options)}
      disabled={!@entry.editable?}
      aria-label={@entry.label}
    />
    """
  end

  # No read-only form: a `:css` entry is shown only where it is editable (the site sheet to admins at
  # the site level, the user's own to that user).
  defp control(%{entry: %{type: :css}} = assigns) do
    ~H"""
    <input type="hidden" name="setting[key]" value={@entry.key} />
    <.editor
      name="setting[value]"
      value={@form[:value].value}
      id={"setting-#{@dom}-value"}
      language="css"
      rows={8}
      max_rows={30}
      debounce="500"
      line_numbers
      placeholder=":root { --tint-c: 0.05; }"
    />
    """
  end

  defp control(%{entry: %{type: :template}} = assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      pre.settings-template-readonly:scope {
        white-space: pre-wrap;
        margin: 0;
        max-inline-size: none;
      }
    </style>
    <input type="hidden" name="setting[key]" value={@entry.key} />
    <.editor
      :if={@entry.editable?}
      name="setting[value]"
      value={@form[:value].value}
      id={"setting-#{@dom}-value"}
      language="liquid"
      rows={3}
      debounce="500"
      placeholder={@entry[:placeholder]}
    />
    <pre :if={!@entry.editable?} id={"setting-#{@dom}-value"} class="settings-template-readonly">{@entry.value || dpgettext("settings", "status: template setting with no override, built-in text in use", "Default")}</pre>
    """
  end

  # The blank choice a select offers, if any. An unset embedding model means no embeddings, not a
  # fallback pick.
  defp select_prompt(%{type: :select}), do: nil

  defp select_prompt(%{type: :model, models: :embedding}),
    do: dpgettext("settings", "option: no embedding model", "None")

  # Unset means no classification at all, not a fallback pick.
  defp select_prompt(%{type: :model, key: "expressions.classifier_model"}),
    do: dpgettext("settings", "option: no expression classifier model", "None (expressions off)")

  defp select_prompt(%{type: :model}),
    do: dpgettext("settings", "option: no fixed model, pick one automatically", "Automatic")

  defp select_prompt(%{type: :side_prompt_set}),
    do: dpgettext("settings", "option: no side prompt set", "None (individual side prompts)")

  defp select_prompt(%{type: :expression_profile}),
    do: dpgettext("settings", "option: no expression rule profile", "None (base emotions only)")

  defp select_prompt(%{type: :caption_prompt}),
    do: dpgettext("settings", "option: no caption prompt, use the built-in instruction", "Built-in instruction")

  defp select_prompt(%{type: :language, key: "appearance.language"}),
    do: dpgettext("settings", "option: no fixed language, follow the browser", "Match my browser")

  defp select_prompt(%{type: :language}) do
    dpgettext(
      "settings",
      "option: no site default language, use the built-in one",
      "Built-in default (%{language_name})",
      language_name: Mythweaver.Locale.display_name("en")
    )
  end

  defp select_prompt(%{type: :locale, key: "appearance.locale"}),
    do: dpgettext("settings", "option: no fixed regional format, follow the browser", "Match my browser")

  defp select_prompt(%{type: :locale}) do
    dpgettext(
      "settings",
      "option: no site default regional format, use the built-in one",
      "Built-in default (%{locale_name})",
      locale_name: Mythweaver.Locale.display_name(Localize.default_locale())
    )
  end
end
