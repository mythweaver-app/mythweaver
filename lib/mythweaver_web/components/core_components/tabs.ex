defmodule MythweaverWeb.CoreComponents.Tabs do
  @moduledoc """
  The app's tab bar, `tabs/1`, and the panel a tab controls, `tab_panel/1`.

  A tab with `patch` is a link, for a tab the URL holds; one with `navigate` is a link to another
  LiveView (the moderation panel's sections); one with neither is a button sending the bar's
  `on_select` event with `%{"tab" => name}`, for a tab kept in an assign (a form whose patch would
  drop unsaved edits). Each `<:tab>`'s inner block is its label, so a badge or icon goes there.

  Ids derive from the bar's `id`: the tablist is `<id>-tabs`, each tab `<id>-tab-<name>`, and a
  `tab_panel/1` given the same `tabs` id is `<id>-panel-<name>`. Panels are the caller's: pass
  `panels` only when every tab's panel is rendered, so each `aria-controls` names a real element.

  Labels never break: the tabs wrap onto another row, and on phones scroll sideways instead.
  """

  use Phoenix.Component

  attr :id, :string, required: true, doc: "the prefix of every id (see the moduledoc)"
  attr :label, :string, required: true, doc: "the tablist's accessible name"
  attr :active, :string, required: true, doc: "the selected tab's `name`"
  attr :on_select, :string, default: nil, doc: "event sent by a tab without `patch`"
  attr :target, :any, default: nil, doc: "phx-target for the on_select buttons"
  attr :panels, :boolean, default: false, doc: "every tab's `tab_panel/1` is rendered"

  slot :tab, required: true do
    attr :name, :string, required: true
    attr :patch, :string, doc: "makes the tab a link"
    attr :navigate, :string, doc: "makes the tab a link to another LiveView"
    attr :invalid, :boolean, doc: "its panel holds a field showing an error"
  end

  def tabs(assigns) do
    ~H"""
    <%!-- `lower-bound="none"`: a link tab is `<.link>`'s root, which the default bound cuts off. --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      nav:scope {
        display: flex;
        flex-wrap: wrap;
        gap: var(--size-1);
        border-bottom: 1px solid var(--border-grey);
      }

      .tab {
        flex: none;
        display: inline-flex;
        align-items: center;
        gap: var(--size-1);
        padding: var(--size-1) var(--size-2);
        border: 0;
        border-bottom: 2px solid transparent;
        background: none;
        color: var(--muted-foreground);
        font: inherit;
        text-decoration: none;
        white-space: nowrap;
        cursor: pointer;
      }

      .tab[aria-selected="true"] {
        color: var(--primary-accent);
        border-bottom-color: var(--primary-accent);
      }

      .tab[data-invalid] {
        color: var(--destructive);
      }

      @media (--phone) {
        nav:scope {
          flex-wrap: nowrap;
          overflow-x: auto;
          scrollbar-width: none;
        }
      }
    </style>
    <nav id={"#{@id}-tabs"} class="tabs" role="tablist" aria-label={@label}>
      <%= for tab <- @tab do %>
        <.link
          :if={tab[:navigate]}
          navigate={tab.navigate}
          {tab_attrs(@id, tab, @active, @panels)}
        >
          {render_slot(tab)}
        </.link>
        <.link
          :if={tab[:patch] && !tab[:navigate]}
          patch={tab.patch}
          {tab_attrs(@id, tab, @active, @panels)}
        >
          {render_slot(tab)}
        </.link>
        <button
          :if={!tab[:patch] && !tab[:navigate]}
          type="button"
          phx-click={@on_select}
          phx-target={@target}
          phx-value-tab={tab.name}
          {tab_attrs(@id, tab, @active, @panels)}
        >
          {render_slot(tab)}
        </button>
      <% end %>
    </nav>
    """
  end

  defp tab_attrs(id, tab, active, panels?) do
    [
      id: "#{id}-tab-#{tab.name}",
      class: "tab",
      role: "tab",
      "aria-selected": to_string(tab.name == active),
      "aria-controls": panels? && "#{id}-panel-#{tab.name}",
      "data-invalid": tab[:invalid] == true
    ]
  end

  attr :tabs, :string, required: true, doc: "the `id` of the `tabs/1` bar"
  attr :name, :string, required: true, doc: "the tab this panel belongs to"
  attr :active, :string, required: true, doc: "the selected tab's `name`; any other panel is `hidden`"
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def tab_panel(assigns) do
    ~H"""
    <div
      id={"#{@tabs}-panel-#{@name}"}
      class={@class}
      role="tabpanel"
      aria-labelledby={"#{@tabs}-tab-#{@name}"}
      hidden={@name != @active}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end
end
