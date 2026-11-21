defmodule MythweaverWeb.ContentAccess do
  @moduledoc """
  Who reaches each content editor: a site content manager, or a user holding that area's create
  permission (`Mythweaver.Ownership.can_create?/2`). Areas: `:characters`, `:lore`, `:prompts`
  (prompts, blocks, outlets), `:scripts`, `:variables` (global variables) and `:memory` (memory
  profiles, side prompts, side prompt sets). An accepted editor of a shared item in an area
  (`Mythweaver.Sharing`) reaches it too. Each editor then lists only what the viewer may edit.
  Mounted as `on_mount {MythweaverWeb.ContentAccess, area}`; anyone else is redirected to `/`. The
  nav and the command palette ask `allowed?/2` the same question.
  """

  use MythweaverWeb, :verified_routes

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Characters.Character
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Memory.Profile
  alias Mythweaver.Ownership
  alias Mythweaver.Prompts.Prompt
  alias Mythweaver.Scripts.Script
  alias Mythweaver.Sharing
  alias Mythweaver.Sharing.Items
  alias Mythweaver.Tags.Tag
  alias Mythweaver.Variables.Variable

  @areas %{
    characters: Character,
    lore: LoreBook,
    prompts: Prompt,
    scripts: Script,
    tags: Tag,
    variables: Variable,
    memory: Profile
  }

  @type area :: :characters | :lore | :prompts | :scripts | :tags | :variables | :memory

  @doc "Whether `scope` may open `area`'s editors."
  @spec allowed?(Scope.t() | nil, area()) :: boolean()
  def allowed?(scope, area) do
    Ownership.can_create?(scope, Map.fetch!(@areas, area)) or
      Sharing.edits_any?(scope, Map.get(Items.areas(), area, []))
  end

  @doc "Whether `scope` may open any content editor."
  @spec any?(Scope.t() | nil) :: boolean()
  def any?(scope), do: Enum.any?(Map.keys(@areas), &allowed?(scope, &1))

  def on_mount(area, _params, _session, socket) do
    if allowed?(socket.assigns.current_scope, area) do
      {:cont, socket}
    else
      {:halt,
       socket
       |> MythweaverWeb.Flash.flash_unauthorized()
       |> Phoenix.LiveView.redirect(to: ~p"/")}
    end
  end
end
