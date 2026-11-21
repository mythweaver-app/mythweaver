defmodule MythweaverWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as components and LiveViews.

  This can be used in your application as:

      use MythweaverWeb, :html

  The definitions below will be executed for every LiveView,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  def static_paths, do: ~w(assets audio fonts images favicon.ico robots.txt manifest.webmanifest sw.js)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Phoenix.Controller
      import Phoenix.LiveView.Router

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]
      use Gettext, backend: Mythweaver.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # Translation
      use Gettext, backend: Mythweaver.Gettext

      import Iconex, only: [lucide: 1]
      import MythweaverWeb.CoreComponents
      import MythweaverWeb.CoreComponents.AvatarImage, only: [avatar_image: 1]

      import MythweaverWeb.CoreComponents.AvatarPlaceholder,
        only: [avatar_placeholder: 1, avatar_placeholder_sprite: 1]

      import MythweaverWeb.CoreComponents.Badge, only: [badge: 1]
      import MythweaverWeb.CoreComponents.Button, only: [button: 1]
      import MythweaverWeb.CoreComponents.ChangedElsewhere, only: [changed_elsewhere: 1]
      import MythweaverWeb.CoreComponents.Disclosure, only: [disclosure: 1]
      import MythweaverWeb.CoreComponents.DragHandle, only: [drag_handle: 1]
      import MythweaverWeb.CoreComponents.Drawer, only: [drawer_toggle: 1]
      import MythweaverWeb.CoreComponents.Editor, only: [editor: 1]
      import MythweaverWeb.CoreComponents.FieldRow, only: [field_row: 1]
      import MythweaverWeb.CoreComponents.FormActions, only: [form_actions: 1]
      import MythweaverWeb.CoreComponents.Header, only: [panel_header: 1, section_header: 1]
      import MythweaverWeb.CoreComponents.JobProgress, only: [job_progress: 1]
      import MythweaverWeb.CoreComponents.LocalTime, only: [local_time: 1]
      import MythweaverWeb.CoreComponents.Markdown, only: [markdown: 1]
      import MythweaverWeb.CoreComponents.Modal, only: [modal: 1]
      import MythweaverWeb.CoreComponents.OwnerSelect, only: [owner_select: 1]
      import MythweaverWeb.CoreComponents.RadialMenu, only: [radial_layout: 1, radial_menu: 1]
      import MythweaverWeb.CoreComponents.Tabs, only: [tabs: 1, tab_panel: 1]
      import MythweaverWeb.CoreComponents.TagInput, only: [tag_chip: 1, tag_input: 1]
      import MythweaverWeb.CoreComponents.WordDiff, only: [word_diff: 1]

      import MythweaverWeb.Flash,
        only: [
          flash_unauthorized: 1,
          unauthorized_message: 0,
          flash_quota: 2,
          flash_held: 2,
          flash_hold_limit: 1,
          cloned_message: 2,
          clone_error_message: 1
        ]

      # Inline markup inside translated sentences
      import MythweaverWeb.RichText, only: [rich: 1, code: 1, em: 1, strong: 1, kbd: 1, navigate_link: 2]

      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components
      alias MythweaverWeb.Layouts

      # Common modules used in templates
      alias Phoenix.LiveView.JS

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: MythweaverWeb.Endpoint,
        router: MythweaverWeb.Router,
        statics: MythweaverWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
