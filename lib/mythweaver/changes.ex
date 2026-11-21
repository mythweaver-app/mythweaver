defmodule Mythweaver.Changes do
  @moduledoc """
  Announces writes to owned rows so every open view of them re-reads. One topic per kind and owner:
  `"changes:site:<kind>"` for site rows (`user_id` nil), `"user:<id>:changes:<kind>"` for one user's
  own. `subscribe/2` joins the scope's own topic and the site's for each kind, so a user's personal
  writes reach that user (the `Mythweaver.Ownership` rule), plus the users their accepted shares
  reach (`Mythweaver.Sharing.after_change/1`, which first rebuilds those shares' grants, so a shared
  item's closure follows the write). The message is `{Mythweaver.Changes, kind}`: nothing is
  carried, receivers re-read through their own scope.

  Broadcast only after the write commits; a caller wrapping notifying calls in its own transaction
  broadcasts again after it.
  """

  alias Mythweaver.Accounts.Scope

  @pubsub Mythweaver.PubSub
  @kinds [:characters, :lore, :prompts, :ai, :memory, :tags, :scripts, :variables, :accounts, :settings]
  @shared_kinds [:characters, :lore, :prompts, :scripts, :memory, :ai]

  @type kind ::
          :characters
          | :lore
          | :prompts
          | :ai
          | :memory
          | :tags
          | :scripts
          | :variables
          | :accounts
          | :settings
  @type owner :: Ecto.UUID.t() | nil

  @doc "The topic for `kind` writes to `owner`'s rows (nil: the site's)."
  @spec topic(kind(), owner()) :: String.t()
  def topic(kind, nil) when kind in @kinds, do: "changes:site:#{kind}"
  def topic(kind, user_id) when kind in @kinds and is_binary(user_id), do: "user:#{user_id}:changes:#{kind}"

  @doc "Subscribes the caller to the scope user's own and the site's topic for each of `kinds`."
  @spec subscribe(Scope.t(), [kind()]) :: :ok
  def subscribe(%Scope{user: %{id: id}}, kinds) do
    for kind <- kinds, owner <- [id, nil], do: :ok = Phoenix.PubSub.subscribe(@pubsub, topic(kind, owner))
    :ok
  end

  @doc """
  Sends `{Mythweaver.Changes, kind}` to each owner's topic for each kind, and, for a kind shared
  items announce, to the users the owners' shares reach.
  """
  @spec broadcast(kind() | [kind()], owner() | [owner()]) :: :ok
  def broadcast(kinds, owners) do
    # Not List.wrap/1: List.wrap(nil) == [], and nil is the site owner.
    owners = if is_list(owners), do: Enum.uniq(owners), else: [owners]
    kinds = List.wrap(kinds)

    audience =
      if Enum.any?(kinds, &(&1 in @shared_kinds)), do: Mythweaver.Sharing.after_change(owners), else: []

    for kind <- kinds, owner <- Enum.uniq(owners ++ audience) do
      Phoenix.PubSub.broadcast(@pubsub, topic(kind, owner), {__MODULE__, kind})
    end

    :ok
  end

  @doc "Passes `result` through, broadcasting `kind` to the returned row's owner on `{:ok, %{user_id: _}}`."
  @spec notify(result, kind()) :: result when result: term()
  def notify({:ok, %{user_id: owner}} = result, kind) do
    broadcast(kind, owner)
    result
  end

  def notify(result, _kind), do: result

  @doc "Passes `result` through, broadcasting on `:ok` or `{:ok, _}` to the given owners."
  @spec notify(result, kind() | [kind()], owner() | [owner()]) :: result when result: term()
  def notify(:ok, kinds, owners) do
    broadcast(kinds, owners)
    :ok
  end

  def notify({:ok, _} = result, kinds, owners) do
    broadcast(kinds, owners)
    result
  end

  def notify(result, _kinds, _owners), do: result

  @doc """
  Passes `result` through, broadcasting `kind` on `:ok` to `user_id`'s own topic only: a per-user
  preference about rows (a character favorite) changes nothing a share reaches.
  """
  @spec notify_own(result, kind(), Ecto.UUID.t()) :: result when result: term()
  def notify_own(:ok, kind, user_id) when is_binary(user_id) do
    Phoenix.PubSub.broadcast(@pubsub, topic(kind, user_id), {__MODULE__, kind})
    :ok
  end

  def notify_own(result, _kind, _user_id), do: result
end
