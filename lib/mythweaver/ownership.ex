defmodule Mythweaver.Ownership do
  @moduledoc """
  The one ownership rule every owned table follows (AI connections and models, characters, lore,
  prompts, scripts, global variables, memory profiles and side prompts, tags).

  A row's `user_id` nil is the site's: holders of the schema's site permission edit it
  (`"site.ai.manage"` for AI connections and models, `"site.content.manage"` for the rest). A row
  with a `user_id` is that user's own: they see, edit, use and delete it; a user creates one when it
  holds the schema's create permission (e.g. `"content.characters.create"`). What anyone creates is
  their own by default, site managers included; a site row is created only on request (`site: true`
  to `new_owner/3`), or by a site-permission holder without the create permission. Site managers get no
  access to another user's rows. Who may *use* the site's rows is the caller's policy (content:
  everyone; AI models: `"ai.site_models.use"`), so `usable/3` and `usable?/3` take it as a boolean.

  A personal row is also reached through an access grant (`Mythweaver.Sharing`, for the types
  `Mythweaver.Sharing.Items` knows): an `:edit` grant edits it (deleting only a part, such as a
  shared book's entries: `authorize_delete/2`), a `:use` grant uses it. A row references site rows,
  rows of its own owner and rows shared to its owner (`reference_ok?/2`). A user may opt out of a
  site root item (`Mythweaver.Sharing.opt_out/2`): `usable/3` and `for_owner/2` leave it out for them.

  Runtime resolution (a generation, a prompt build, lore activation, script triggers, memory jobs)
  filters by the *chat owner*, not the caller: `for_owner/2`, which includes what is shared to the
  owner. What is picked without the owner choosing it (automatic side prompts, the default memory
  profile) uses `owned_or_site/2`, which does not. Enabled scripts use `for_owner/2`, but a shared
  script runs only once its user toggled it on (`Mythweaver.Sharing.set_toggle/3`).

  A catalog mirror row (`Mythweaver.Catalog`, `frozen_listing_id` set) is its publisher's but never
  one of its own rows: the own-row clauses leave it out, and `authorize_edit/2`/`authorize_delete/2`
  refuse it. Subscribers reach it through their grants; `Mythweaver.Catalog` writes it directly.
  """

  import Ecto.Query

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.AI
  alias Mythweaver.Characters.Character
  alias Mythweaver.Expressions.Profile
  alias Mythweaver.Lore
  alias Mythweaver.Memory
  alias Mythweaver.Prompts
  alias Mythweaver.Scripts.Script
  alias Mythweaver.Sharing
  alias Mythweaver.Sharing.Items
  alias Mythweaver.Sharing.OptOut
  alias Mythweaver.Tags.Tag
  alias Mythweaver.Variables.Variable

  @site_ai [AI.Provider, AI.Model]
  @site_content [
    Character,
    Lore.LoreBook,
    Lore.LoreEntry,
    Lore.LorePool,
    Prompts.Prompt,
    Prompts.Block,
    Prompts.Outlet,
    Script,
    Variable,
    Memory.Profile,
    Memory.SidePrompt,
    Memory.SidePromptSet,
    Profile,
    Tag
  ]

  @doc "The permission that edits `schema`'s site rows."
  @spec site_permission(module()) :: String.t()
  def site_permission(schema) when schema in @site_ai, do: "site.ai.manage"
  def site_permission(schema) when schema in @site_content, do: "site.content.manage"
  def site_permission(schema), do: raise(ArgumentError, "#{inspect(schema)} has no owner rule")

  @doc "The permission that creates a user's own `schema` rows."
  @spec create_permission(module()) :: String.t()
  def create_permission(Character), do: "content.characters.create"
  def create_permission(schema) when schema in [Lore.LoreBook, Lore.LoreEntry, Lore.LorePool], do: "content.lore.create"

  def create_permission(schema) when schema in [Prompts.Prompt, Prompts.Block, Prompts.Outlet],
    do: "content.prompts.create"

  def create_permission(Script), do: "content.scripts.create"
  def create_permission(Variable), do: "content.variables.create"
  def create_permission(Tag), do: "content.tags.create"

  def create_permission(schema) when schema in [Memory.Profile, Memory.SidePrompt, Memory.SidePromptSet],
    do: "content.memory.create"

  def create_permission(Profile), do: "content.characters.create"

  def create_permission(schema) when schema in @site_ai, do: "ai.connections.create"
  def create_permission(schema), do: raise(ArgumentError, "#{inspect(schema)} has no owner rule")

  @doc """
  Who owns a `schema` row `scope` creates: `{:ok, user_id}` (its own) for a holder of its create
  permission, else `{:ok, nil}` (the site) for a holder of its site permission, else
  `{:error, :unauthorized}`. With `site: true`, the site's: `{:ok, nil}` for a holder of the site
  permission only.
  """
  @spec new_owner(Scope.t(), module(), keyword()) :: {:ok, Ecto.UUID.t() | nil} | {:error, :unauthorized}
  def new_owner(%Scope{} = scope, schema, opts \\ []) do
    site_manager? = Scope.can?(scope, site_permission(schema))

    cond do
      Keyword.get(opts, :site, false) -> if site_manager?, do: {:ok, nil}, else: {:error, :unauthorized}
      match?(%Scope{user: %User{}}, scope) and Scope.can?(scope, create_permission(schema)) -> {:ok, scope.user.id}
      site_manager? -> {:ok, nil}
      true -> {:error, :unauthorized}
    end
  end

  @doc "Whether `scope` may create `schema` rows (`new_owner/2` succeeds)."
  @spec can_create?(Scope.t() | nil, module()) :: boolean()
  def can_create?(%Scope{} = scope, schema), do: match?({:ok, _}, new_owner(scope, schema))
  def can_create?(nil, _schema), do: false

  @doc """
  `:ok` when `scope` may edit `row`: a site row for a site-permission holder, its own row for its
  owner, a row it holds an `:edit` grant on.
  """
  @spec authorize_edit(Scope.t(), %{user_id: Ecto.UUID.t() | nil}) :: :ok | {:error, :unauthorized}
  def authorize_edit(_scope, %{frozen_listing_id: listing_id}) when is_binary(listing_id), do: {:error, :unauthorized}

  def authorize_edit(%Scope{} = scope, %{user_id: nil} = row),
    do: Scope.authorize(scope, site_permission(row.__struct__))

  def authorize_edit(%Scope{user: %User{id: id}}, %{user_id: id}), do: :ok

  def authorize_edit(%Scope{user: %User{id: id}}, row) do
    if Sharing.granted?(id, row, [:edit]), do: :ok, else: {:error, :unauthorized}
  end

  def authorize_edit(_scope, _row), do: {:error, :unauthorized}

  @doc """
  `:ok` when `scope` may delete `row`: a site row for a site-permission holder, its own row for its
  owner, and a part (`Mythweaver.Sharing.Items.part_types/0`) it holds an `:edit` grant on. An editor
  never deletes a shared item itself.
  """
  @spec authorize_delete(Scope.t(), %{user_id: Ecto.UUID.t() | nil}) :: :ok | {:error, :unauthorized}
  def authorize_delete(_scope, %{frozen_listing_id: listing_id}) when is_binary(listing_id), do: {:error, :unauthorized}

  def authorize_delete(%Scope{} = scope, %{user_id: nil} = row),
    do: Scope.authorize(scope, site_permission(row.__struct__))

  def authorize_delete(%Scope{user: %User{id: id}}, %{user_id: id}), do: :ok

  def authorize_delete(%Scope{user: %User{id: id}}, row) do
    if Items.type_of(row) in Items.part_types() and Sharing.granted?(id, row, [:edit]),
      do: :ok,
      else: {:error, :unauthorized}
  end

  def authorize_delete(_scope, _row), do: {:error, :unauthorized}

  @doc "Whether `scope` may delete `row` (`authorize_delete/2`)."
  @spec deletable?(Scope.t(), %{user_id: Ecto.UUID.t() | nil}) :: boolean()
  def deletable?(scope, row), do: authorize_delete(scope, row) == :ok

  @doc """
  Rows `scope` may edit: its own, those it holds an `:edit` grant on, plus the site's for a holder of
  the schema's site permission.
  """
  @spec editable(Ecto.Queryable.t(), Scope.t()) :: Ecto.Query.t()
  def editable(query, %Scope{} = scope) do
    site = if Scope.can?(scope, site_permission(schema_of(query))), do: :all, else: :none
    owned_by(query, scope, site, [:edit])
  end

  defp schema_of(query), do: Ecto.Queryable.to_query(query).from.source |> elem(1)

  @doc """
  Rows `scope` may use: its own and those shared to it, plus the site's when `site?` (content: always)
  except those it opted out of (`Mythweaver.Sharing.opt_out/2`).
  """
  @spec usable(Ecto.Queryable.t(), Scope.t(), boolean()) :: Ecto.Query.t()
  def usable(query, %Scope{} = scope, site? \\ true),
    do: owned_by(query, scope, if(site?, do: :kept, else: :none), [:edit, :use])

  @doc "Whether `scope` may use `row`, under the same rule as `usable/3`."
  @spec usable?(Scope.t(), %{user_id: Ecto.UUID.t() | nil}, boolean()) :: boolean()
  def usable?(scope, row, site? \\ true)
  def usable?(%Scope{user: %User{id: id}}, %{user_id: id}, _site?), do: true
  def usable?(%Scope{}, %{user_id: nil}, site?), do: site?
  def usable?(%Scope{user: %User{id: id}}, row, _site?), do: Sharing.granted?(id, row, [:edit, :use])
  def usable?(%Scope{}, %{}, _site?), do: false

  @doc """
  Site rows `owner_id` did not opt out of, plus its own and those shared to it (nil: site rows only).
  For runtime resolution by chat owner.
  """
  @spec for_owner(Ecto.Queryable.t(), Ecto.UUID.t() | nil) :: Ecto.Query.t()
  def for_owner(query, nil), do: where(query, [r], is_nil(r.user_id))
  def for_owner(query, owner_id), do: where(query, ^reach(query, owner_id, :kept, [:edit, :use]))

  @doc """
  Site rows plus exactly `owner_id`'s own (nil: site rows only), never what is shared to it: for what
  runs or is picked without the owner choosing it.
  """
  @spec owned_or_site(Ecto.Queryable.t(), Ecto.UUID.t() | nil) :: Ecto.Query.t()
  def owned_or_site(query, nil), do: where(query, [r], is_nil(r.user_id))

  def owned_or_site(query, owner_id) do
    own = own(query, owner_id)
    where(query, ^dynamic([r], is_nil(r.user_id) or ^own))
  end

  @doc "Rows of exactly `owner_id` (nil: the site's), never catalog mirrors."
  @spec owned_exactly(Ecto.Queryable.t(), Ecto.UUID.t() | nil) :: Ecto.Query.t()
  def owned_exactly(query, nil), do: where(query, [r], is_nil(r.user_id))
  def owned_exactly(query, owner_id), do: where(query, ^own(query, owner_id))

  # `owner_id`'s own rows: those it owns, less its catalog mirrors where the table has them.
  defp own(query, owner_id) do
    if mirrored?(schema_of(query)),
      do: dynamic([r], r.user_id == ^owner_id and is_nil(r.frozen_listing_id)),
      else: dynamic([r], r.user_id == ^owner_id)
  end

  defp mirrored?(schema) when is_atom(schema) and schema != nil,
    do: function_exported?(schema, :__schema__, 1) and :frozen_listing_id in schema.__schema__(:fields)

  defp mirrored?(_schema), do: false

  @doc """
  Whether a row owned by `owner_id` may reference `target`: a site row, one of its own owner's, or
  one shared to its owner.
  """
  @spec reference_ok?(Ecto.UUID.t() | nil, %{user_id: Ecto.UUID.t() | nil}) :: boolean()
  def reference_ok?(_owner_id, %{user_id: nil}), do: true
  def reference_ok?(owner_id, %{user_id: owner_id}), do: true
  def reference_ok?(nil, _target), do: false
  def reference_ok?(owner_id, target), do: Sharing.granted?(owner_id, target, [:edit, :use])

  @doc """
  An `order_by` term ranking rows `owner_id`'s own first, then the site's, then those shared to it:
  the tie-break wherever one row of a name or key wins.
  """
  @spec owner_rank(Ecto.UUID.t() | nil) :: Ecto.Query.dynamic_expr()
  def owner_rank(nil), do: dynamic([r], fragment("CASE WHEN ? IS NULL THEN 1 ELSE 2 END", r.user_id))

  def owner_rank(owner_id) do
    dynamic(
      [r],
      fragment(
        "CASE WHEN ? = ? THEN 0 WHEN ? IS NULL THEN 1 ELSE 2 END",
        r.user_id,
        type(^owner_id, Ecto.UUID),
        r.user_id
      )
    )
  end

  defp owned_by(query, %Scope{user: %User{id: uid}}, site, accesses),
    do: where(query, ^reach(query, uid, site, accesses))

  defp owned_by(query, %Scope{}, :none, _accesses), do: where(query, false)
  defp owned_by(query, %Scope{}, _site, _accesses), do: for_owner(query, nil)

  # One condition, so it ANDs with whatever the caller's query already filters on: `uid`'s own rows,
  # the site's (`site`: `:all`, `:kept` without those `uid` opted out of, or `:none`), and rows `uid`
  # holds one of `accesses` grants on.
  defp reach(query, uid, site, accesses) do
    type = Items.type_of(schema_of(query))
    mine = own(query, uid)

    own =
      cond do
        site == :none ->
          mine

        site == :kept and Items.root?(type) ->
          dynamic([r], (is_nil(r.user_id) and r.id not in subquery(OptOut.ids(uid, type))) or ^mine)

        true ->
          dynamic([r], is_nil(r.user_id) or ^mine)
      end

    case type do
      nil -> own
      type -> dynamic([r], ^own or r.id in subquery(Sharing.granted_ids(uid, type, accesses)))
    end
  end
end
