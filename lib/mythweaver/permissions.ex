defmodule Mythweaver.Permissions do
  @moduledoc """
  Groups and permission grants, resolved into `Mythweaver.Accounts.Scope.permissions` once per scope.

  Keys come from `Mythweaver.Permissions.Catalog`. A grant sits on a group or a user. Resolution per
  key (`effective/1`):

    * a value set on the user ("explicit") beats every group;
    * flags: among the Everyone group and the user's groups any deny beats any allow; unset
      everywhere is off;
    * limits: the most generous group value wins (unlimited beats any number); unset everywhere is
      unlimited.

  Owners hold every flag and no limit, without a query.
  """

  import Ecto.Query

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.Changes
  alias Mythweaver.Permissions.Catalog
  alias Mythweaver.Permissions.Grant
  alias Mythweaver.Permissions.Group
  alias Mythweaver.Permissions.Member
  alias Mythweaver.Repo

  @type value :: boolean() | non_neg_integer() | :unlimited

  @doc "Every catalog key's effective value for `user`."
  @spec effective(User.t()) :: %{String.t() => value()}
  def effective(%User{role: :owner}) do
    Map.new(Catalog.kinds(), fn
      {key, :flag} -> {key, true}
      {key, :limit} -> {key, :unlimited}
    end)
  end

  def effective(%User{id: uid}) do
    rows =
      Repo.all(
        from(g in Grant,
          left_join: grp in Group,
          on: grp.id == g.group_id,
          where:
            g.user_id == ^uid or grp.system_key == :everyone or
              g.group_id in subquery(from(m in Member, where: m.user_id == ^uid, select: m.group_id)),
          select: {not is_nil(g.user_id), g.key, g.effect, g.limit_value}
        )
      )

    {explicit, inherited} = Enum.split_with(rows, &elem(&1, 0))
    explicit = Map.new(explicit, fn {_, key, effect, limit} -> {key, {effect, limit}} end)
    inherited = Enum.group_by(inherited, &elem(&1, 1), fn {_, _, effect, limit} -> {effect, limit} end)

    Map.new(Catalog.kinds(), fn {key, kind} ->
      {key, resolve(kind, Map.fetch(explicit, key), Map.get(inherited, key, []))}
    end)
  end

  defp resolve(:flag, {:ok, {effect, _}}, _groups), do: effect == :allow

  defp resolve(:flag, :error, groups) do
    effects = Enum.map(groups, &elem(&1, 0))
    :deny not in effects and :allow in effects
  end

  defp resolve(:limit, {:ok, {_, limit}}, _groups), do: limit || :unlimited
  defp resolve(:limit, :error, []), do: :unlimited

  defp resolve(:limit, :error, groups) do
    limits = Enum.map(groups, &elem(&1, 1))
    if nil in limits, do: :unlimited, else: Enum.max(limits)
  end

  @doc "The system group with `system_key` (`:everyone` or `:administrators`)."
  @spec system_group!(:everyone | :administrators) :: Group.t()
  def system_group!(system_key), do: Repo.get_by!(Group, system_key: system_key)

  @doc """
  Adds `user` to `group` (a `Group` or a system key) with no authorization check. For migrations,
  first-user setup paths and tests only; the UI goes through the scoped functions.
  """
  @spec add_member!(Group.t() | :administrators, User.t()) :: :ok
  def add_member!(:administrators, user), do: add_member!(system_group!(:administrators), user)

  def add_member!(%Group{id: group_id}, %User{id: user_id}) do
    Repo.insert!(%Member{group_id: group_id, user_id: user_id}, on_conflict: :nothing)
    :ok
  end

  @doc """
  Sets `key` on `holder` (a `Group`, a system key or a `User`) with no authorization check: `:allow`,
  `:deny`, an integer limit, `:unlimited`, or nil to unset. Tests only, like `add_member!/2`.
  """
  @spec put_grant!(Group.t() | User.t() | :everyone | :administrators, String.t(), atom() | integer() | nil) :: :ok
  def put_grant!(system_key, key, value) when system_key in [:everyone, :administrators],
    do: put_grant!(system_group!(system_key), key, value)

  def put_grant!(holder, key, value) do
    holder_field = holder_field(holder)
    Repo.delete_all(from(g in Grant, where: field(g, ^holder_field) == ^holder.id and g.key == ^key))

    if value != nil do
      attrs =
        case value do
          effect when effect in [:allow, :deny] -> %{key: key, effect: effect}
          :unlimited -> %{key: key, limit_value: nil}
          limit when is_integer(limit) -> %{key: key, limit_value: limit}
        end

      %Grant{}
      |> Map.put(holder_field, holder.id)
      |> Grant.changeset(attrs)
      |> Repo.insert!()
    end

    :ok
  end

  ## Management (`"groups.manage"`)
  #
  # Every function below takes the acting scope first and refuses, in order: a scope without
  # `"groups.manage"` (`:unauthorized`); for a user target, an owner target unless the actor is an
  # owner (`:unauthorized`); then Discord's rule (`{:not_held, key}`): a non-owner may set only keys
  # it holds itself (`may_set?/3`), and may not change a group or user whose current allow or limit
  # rows include one it could not set.

  @type grant_value :: :allow | :deny | :unlimited | non_neg_integer() | nil
  @type error :: :unauthorized | :sudo_required | :system_group | {:not_held, String.t()} | {:invalid, String.t()}

  @doc "Every group, system groups first (Everyone, Administrators), then by name."
  @spec list_groups(Scope.t()) :: [Group.t()]
  def list_groups(%Scope{} = scope) do
    if Scope.can?(scope, "groups.manage") do
      Repo.all(
        from(g in Group,
          order_by: [
            asc: is_nil(g.system_key),
            asc: fragment("? = 'administrators'", g.system_key),
            asc: fragment("lower(?)", g.name)
          ]
        )
      )
    else
      []
    end
  end

  @doc "`{name, id}` options for every group in `list_groups/1`'s order, with no permission check; for pickers."
  @spec group_options() :: [{String.t(), Ecto.UUID.t()}]
  def group_options do
    Repo.all(
      from(g in Group,
        order_by: [
          asc: is_nil(g.system_key),
          asc: fragment("? = 'administrators'", g.system_key),
          asc: fragment("lower(?)", g.name)
        ],
        select: {g.name, g.id}
      )
    )
  end

  @doc "A group by id, or nil (also for a scope without `\"groups.manage\"`)."
  @spec get_group(Scope.t(), String.t()) :: Group.t() | nil
  def get_group(%Scope{} = scope, id) do
    with true <- Scope.can?(scope, "groups.manage"), {:ok, id} <- Ecto.UUID.cast(id) do
      Repo.get(Group, id)
    else
      _ -> nil
    end
  end

  def change_group(%Group{} = group, attrs \\ %{}), do: Group.changeset(group, attrs)

  @spec create_group(Scope.t(), map()) :: {:ok, Group.t()} | {:error, Ecto.Changeset.t() | error()}
  def create_group(%Scope{} = scope, attrs) do
    with :ok <- Scope.authorize(scope, "groups.manage"), :ok <- Accounts.authorize_sudo(scope) do
      %Group{} |> Group.changeset(attrs) |> Repo.insert() |> Changes.notify(:accounts, nil)
    end
  end

  @spec update_group(Scope.t(), Group.t(), map()) :: {:ok, Group.t()} | {:error, Ecto.Changeset.t() | error()}
  def update_group(%Scope{} = scope, %Group{} = group, attrs) do
    with :ok <- authorize_holder(scope, group), :ok <- Accounts.authorize_sudo(scope) do
      group |> Group.changeset(attrs) |> Repo.update() |> Changes.notify(:accounts, nil)
    end
  end

  @doc "Deletes a group (never a system group); its grants and memberships cascade."
  @spec delete_group(Scope.t(), Group.t()) :: {:ok, Group.t()} | {:error, Ecto.Changeset.t() | error()}
  def delete_group(%Scope{} = scope, %Group{} = group) do
    with :ok <- authorize_holder(scope, group),
         :ok <- not_system(group),
         :ok <- Accounts.authorize_sudo(scope) do
      group |> Repo.delete() |> Changes.notify(:accounts, nil)
    end
  end

  @doc """
  Sets a group's grants from the permission form: `%{key => value}` where a flag's value is
  `"allow"`, `"deny"` or `""` (unset), and a limit's `"unlimited"`, `""` (unset) or a non-negative
  integer string. Keys absent from `grants` keep their rows. Changes apply in one transaction.
  """
  @spec set_group_grants(Scope.t(), Group.t(), map()) :: {:ok, Group.t()} | {:error, error()}
  def set_group_grants(%Scope{} = scope, %Group{} = group, grants) do
    with :ok <- authorize_holder(scope, group),
         do: scope |> put_grants(group, grants) |> Changes.notify(:accounts, nil)
  end

  @doc "`set_group_grants/3` for one user's own (explicit) grants."
  @spec set_user_grants(Scope.t(), User.t(), map()) :: {:ok, User.t()} | {:error, error()}
  def set_user_grants(%Scope{} = scope, %User{} = user, grants) do
    with :ok <- authorize_holder(scope, user),
         do: scope |> put_grants(user, grants) |> Changes.notify(:accounts, [nil, user.id])
  end

  @doc """
  Replaces a group's members with `user_ids` (never for Everyone). Every allow or limit row the group
  holds must be one the actor could set (`may_set?/3`).
  """
  @spec set_group_members(Scope.t(), Group.t(), [Ecto.UUID.t()]) :: {:ok, Group.t()} | {:error, error()}
  def set_group_members(%Scope{} = scope, %Group{} = group, user_ids) do
    with :ok <- authorize_holder(scope, group),
         :ok <- if(group.system_key == :everyone, do: {:error, :system_group}, else: :ok) do
      wanted = Repo.all(from(u in User, where: u.id in ^valid_ids(user_ids), select: u.id))
      current = Repo.all(from(m in Member, where: m.group_id == ^group.id, select: m.user_id))
      changed = (wanted -- current) ++ (current -- wanted)
      owners = Repo.all(from(u in User, where: u.id in ^changed and u.role == :owner, select: u.id))

      cond do
        owners != [] and not Scope.owner?(scope) ->
          {:error, :unauthorized}

        Accounts.authorize_sudo(scope) != :ok ->
          {:error, :sudo_required}

        true ->
          Repo.transact(fn ->
            Repo.delete_all(from(m in Member, where: m.group_id == ^group.id and m.user_id in ^(current -- wanted)))
            Enum.each(wanted -- current, &Repo.insert!(%Member{group_id: group.id, user_id: &1}, on_conflict: :nothing))
            {:ok, group}
          end)
          |> Changes.notify(:accounts, nil)
      end
    end
  end

  @doc """
  Replaces `user`'s groups with `group_ids` (Everyone is implicit and ignored). Every group added or
  removed must pass the same rule as `set_group_members/3`.
  """
  @spec set_user_groups(Scope.t(), User.t(), [Ecto.UUID.t()]) :: {:ok, User.t()} | {:error, error()}
  def set_user_groups(%Scope{} = scope, %User{} = user, group_ids) do
    with :ok <- authorize_holder(scope, user) do
      everyone = system_group!(:everyone).id
      wanted = Repo.all(from(g in Group, where: g.id in ^valid_ids(group_ids), select: g.id)) -- [everyone]
      current = group_ids(user)
      changed = Repo.all(from(g in Group, where: g.id in ^((wanted -- current) ++ (current -- wanted))))

      with :ok <- Enum.reduce_while(changed, :ok, &halt_on_error(held_rows_ok(scope, &1), &2)),
           :ok <- Accounts.authorize_sudo(scope) do
        Repo.transact(fn ->
          Repo.delete_all(from(m in Member, where: m.user_id == ^user.id and m.group_id in ^(current -- wanted)))
          Enum.each(wanted -- current, &Repo.insert!(%Member{group_id: &1, user_id: user.id}, on_conflict: :nothing))
          {:ok, user}
        end)
        |> Changes.notify(:accounts, [nil, user.id])
      end
    end
  end

  @doc "A group's member users, by handle (Everyone: every user)."
  @spec list_members(Group.t()) :: [User.t()]
  def list_members(%Group{system_key: :everyone}), do: Repo.all(from(u in User, order_by: u.handle))

  def list_members(%Group{id: id}) do
    Repo.all(from(u in User, join: m in Member, on: m.user_id == u.id, where: m.group_id == ^id, order_by: u.handle))
  end

  @doc "Ids of the groups `user` is a member of (Everyone not included)."
  @spec group_ids(User.t()) :: [Ecto.UUID.t()]
  def group_ids(%User{id: id}), do: Repo.all(from(m in Member, where: m.user_id == ^id, select: m.group_id))

  @doc "A holder's grant rows by key."
  @spec grants_for(Group.t() | User.t()) :: %{String.t() => Grant.t()}
  def grants_for(holder) do
    field = holder_field(holder)
    Repo.all(from(g in Grant, where: field(g, ^field) == ^holder.id)) |> Map.new(&{&1.key, &1})
  end

  @doc "A grant row's value: `:allow`, `:deny`, `:unlimited` or an integer."
  @spec grant_value(Grant.t()) :: grant_value()
  def grant_value(%Grant{effect: effect}) when effect != nil, do: effect
  def grant_value(%Grant{limit_value: nil}), do: :unlimited
  def grant_value(%Grant{limit_value: limit}), do: limit

  @doc """
  Whether `scope` may set `key` to `value` (Discord's rule): an owner anything; otherwise a flag only
  when `scope` holds it, and a limit only up to `scope`'s own (unset or unlimited only when `scope`'s
  is unlimited).
  """
  @spec may_set?(Scope.t(), String.t(), grant_value()) :: boolean()
  def may_set?(%Scope{} = scope, key, value) do
    cond do
      Scope.owner?(scope) -> true
      Catalog.flag?(key) -> Scope.can?(scope, key)
      true -> limit_within?(Scope.limit(scope, key), value)
    end
  end

  defp limit_within?(:unlimited, _value), do: true
  defp limit_within?(own, value) when is_integer(value), do: value <= own
  defp limit_within?(_own, _value), do: false

  @doc "The first allow or limit row of `holder` that `scope` could not set, as `{:not_held, key}`, else `:ok`."
  @spec held_rows_ok(Scope.t(), Group.t() | User.t()) :: :ok | {:error, {:not_held, String.t()}}
  def held_rows_ok(%Scope{} = scope, holder) do
    holder
    |> grants_for()
    |> Map.values()
    |> Enum.sort_by(& &1.key)
    |> Enum.reject(&(&1.effect == :deny))
    |> Enum.find_value(:ok, fn grant ->
      if not may_set?(scope, grant.key, grant_value(grant)), do: {:error, {:not_held, grant.key}}
    end)
  end

  @doc """
  Users whose sessions a change to `holder` affects: a group's members (Everyone: every user), or
  the user itself.
  """
  @spec affected_users(Group.t() | User.t()) :: [User.t()]
  def affected_users(%Group{} = group), do: list_members(group)
  def affected_users(%User{} = user), do: [user]

  defp authorize_holder(scope, holder) do
    cond do
      not Scope.can?(scope, "groups.manage") -> {:error, :unauthorized}
      match?(%User{role: :owner}, holder) and not Scope.owner?(scope) -> {:error, :unauthorized}
      true -> held_rows_ok(scope, holder)
    end
  end

  defp not_system(%Group{system_key: nil}), do: :ok
  defp not_system(%Group{}), do: {:error, :system_group}

  defp put_grants(scope, holder, grants) do
    current = grants_for(holder)

    with {:ok, parsed} <- parse_grants(grants) do
      changes = Enum.reject(parsed, fn {key, value} -> value == (current[key] && grant_value(current[key])) end)

      with :ok <- Enum.reduce_while(changes, :ok, &halt_on_error(may_set_change(scope, &1), &2)),
           :ok <- Accounts.authorize_sudo(scope) do
        Repo.transact(fn ->
          Enum.each(changes, fn {key, value} -> put_grant!(holder, key, value) end)
          {:ok, holder}
        end)
      end
    end
  end

  defp may_set_change(scope, {key, value}),
    do: if(may_set?(scope, key, value), do: :ok, else: {:error, {:not_held, key}})

  defp halt_on_error(:ok, acc), do: {:cont, acc}
  defp halt_on_error(error, _acc), do: {:halt, error}

  defp parse_grants(grants) do
    Enum.reduce_while(grants, {:ok, []}, fn {key, raw}, {:ok, acc} ->
      case parse_value(Catalog.get(key), raw) do
        {:ok, value} -> {:cont, {:ok, [{key, value} | acc]}}
        :error -> {:halt, {:error, {:invalid, key}}}
      end
    end)
  end

  defp parse_value(nil, _raw), do: :error
  defp parse_value(_entry, ""), do: {:ok, nil}
  defp parse_value(%{kind: :flag}, "allow"), do: {:ok, :allow}
  defp parse_value(%{kind: :flag}, "deny"), do: {:ok, :deny}
  defp parse_value(%{kind: :limit}, "unlimited"), do: {:ok, :unlimited}

  defp parse_value(%{kind: :limit}, raw) when is_binary(raw) do
    case Integer.parse(String.trim(raw)) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_value(_entry, _raw), do: :error

  defp valid_ids(ids) do
    ids
    |> Enum.flat_map(fn id ->
      case Ecto.UUID.cast(id) do
        {:ok, id} -> [id]
        :error -> []
      end
    end)
    |> Enum.uniq()
  end

  defp holder_field(%Group{}), do: :group_id
  defp holder_field(%User{}), do: :user_id
end
