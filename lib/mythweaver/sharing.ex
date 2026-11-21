defmodule Mythweaver.Sharing do
  @moduledoc """
  Sharing an item with another account. An **editor** edits the item and its parts
  (`Mythweaver.Sharing.Closure`) but never deletes it, and may use what it references; a
  **subscriber** only uses all of it. A subscriber share is `:readable` (may inspect its protected
  content) or `:runtime_only` (never sees it; `Mythweaver.Sharing.Visibility.share_protected?/2`).
  The owner invites (by handle, needing `"sharing.invite"`, at most `"quota.pending_invites"`
  waiting at once) either role and removes any share; an editor may invite and remove Runtime-only
  subscribers only, and only the owner changes a share's visibility. The share list is shown to the
  owner and the item's editors. Root types are `Mythweaver.Sharing.Items.root_types/0`, personal
  rows only.

  An invite is a `:pending` `Share` and a `:share_invite` item in the invitee's inbox. Accepting it
  builds the share's `Mythweaver.Sharing.Grant`s, which `Mythweaver.Ownership` joins; the grants are
  rebuilt after every write of an owner who has accepted shares (`after_change/1`, from
  `Mythweaver.Changes.broadcast/2`), so a closure follows its item.

  Removing an editor, deleting a shared item, deleting its owner's account or moving it to the site
  ends the share. The user loses every row no other share still grants, and
  `Mythweaver.Sharing.Fallout` removes their own references to those rows; nothing is copied, and
  their chats keep the messages of a lost character under its name. They get a `:share_ended`
  inbox notice. An owner who deletes an item with accepted editors, or whose account goes, gives it
  to one of them instead (`hand_off/3`).
  """

  import Ecto.Query

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.Changes
  alias Mythweaver.Chats
  alias Mythweaver.Lore.BookEntry
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Notifications
  alias Mythweaver.Permissions.Quota
  alias Mythweaver.Repo
  alias Mythweaver.Scripts.Script
  alias Mythweaver.Sharing.Closure
  alias Mythweaver.Sharing.Fallout
  alias Mythweaver.Sharing.Grant
  alias Mythweaver.Sharing.HandOff
  alias Mythweaver.Sharing.Items
  alias Mythweaver.Sharing.OptOut
  alias Mythweaver.Sharing.Share
  alias Mythweaver.Sharing.Toggle

  @type reason :: :removed | :left | :deleted | :account_deleted | :moved_to_site | :unpublished | :taken_down

  ## Grants

  @doc "Whether `user_id` holds one of `accesses` grants on `row` (false for a type sharing does not know)."
  @spec granted?(Ecto.UUID.t() | nil, struct() | map(), [:edit | :use]) :: boolean()
  def granted?(user_id, %schema{id: id}, accesses) when is_binary(user_id) and is_binary(id) do
    case Items.type_of(schema) do
      nil -> false
      type -> Repo.exists?(where(granted_ids(user_id, type, accesses), [g], g.item_id == ^id))
    end
  end

  def granted?(_user_id, _row, _accesses), do: false

  @doc "The ids of `type` rows `user_id` holds one of `accesses` grants on, as a query."
  @spec granted_ids(Ecto.UUID.t(), Items.type(), [:edit | :use]) :: Ecto.Query.t()
  def granted_ids(user_id, type, accesses) do
    from(g in Grant,
      where: g.user_id == ^user_id and g.item_type == ^type and g.access in ^accesses,
      select: g.item_id
    )
  end

  @doc "Whether `scope` holds an `:edit` grant on any row of `types`."
  @spec edits_any?(Scope.t() | nil, [Items.type()]) :: boolean()
  def edits_any?(%Scope{user: %User{id: uid}}, [_ | _] = types) do
    Repo.exists?(from(g in Grant, where: g.user_id == ^uid and g.item_type in ^types and g.access == :edit))
  end

  def edits_any?(_scope, _types), do: false

  ## Shares

  @doc """
  The shares of `item`, users preloaded, oldest first: every one for its owner, the pending and
  accepted ones for one of its editors, none for anyone else.
  """
  @spec list_shares(Scope.t(), struct()) :: [Share.t()]
  def list_shares(%Scope{user: %User{id: uid}}, %{id: id, user_id: owner_id} = item) when is_binary(owner_id) do
    case Items.type_of(item) do
      nil ->
        []

      type ->
        base = from(s in Share, where: s.item_type == ^type and s.item_id == ^id)
        ordered = from(s in base, order_by: [asc: s.inserted_at, asc: s.id], preload: :user)

        cond do
          owner_id == uid ->
            Repo.all(ordered)

          Repo.exists?(where(base, [s], s.user_id == ^uid and s.status == :accepted)) ->
            Repo.all(where(ordered, [s], s.status != :declined))

          true ->
            []
        end
    end
  end

  def list_shares(_scope, _item), do: []

  @doc """
  Invites the account with `handle` to `item`. Options: `role:` (`:editor`, the default, or
  `:subscriber`) and `visibility:` (`:runtime_only`, the default, or `:readable`; subscribers only).
  An AI model also takes `ai_mode:` (`:own_key`, the default, or `:owner_key`, which only an owner
  holding `"sharing.ai.owner_key"` may choose) and, with `:owner_key` only, `token_limit_per_day:`
  (a positive integer, or nil for none); other types refuse both.
  The owner may send any invite; a user holding an `:edit` grant on `item` may invite Runtime-only
  subscribers only. A declined share is asked again; the invitee finds the invite in their inbox.
  """
  @spec invite(Scope.t(), struct(), String.t(), keyword()) ::
          {:ok, Share.t()} | {:error, :unauthorized | :unknown_handle | :self | :already_shared | :quota_exceeded}
  def invite(scope, item, handle, opts \\ [])

  def invite(%Scope{user: %User{id: uid} = inviter} = scope, %{user_id: owner_id} = item, handle, opts)
      when is_binary(owner_id) do
    type = Items.type_of(item)
    role = Keyword.get(opts, :role, :editor)
    visibility = Keyword.get(opts, :visibility, :runtime_only)
    ai_mode = Keyword.get(opts, :ai_mode, if(type == :ai_model, do: :own_key))
    token_limit = Keyword.get(opts, :token_limit_per_day)

    allowed? =
      role in [:editor, :subscriber] and visibility in [:readable, :runtime_only] and Items.root?(type) and
        Scope.can?(scope, "sharing.invite") and ai_mode_allowed?(scope, owner_id, type, ai_mode, token_limit) and
        (owner_id == uid or
           (role == :subscriber and visibility == :runtime_only and ai_mode != :owner_key and
              granted?(uid, item, [:edit])))

    if allowed? do
      fields = %{role: role, visibility: visibility, ai_mode: ai_mode, token_limit_per_day: token_limit}

      case Accounts.get_user_by_handle(handle) do
        nil -> {:error, :unknown_handle}
        %User{id: ^uid} -> {:error, :self}
        %User{id: ^owner_id} -> {:error, :already_shared}
        invitee -> do_invite(scope, inviter, item, type, invitee, fields)
      end
    else
      {:error, :unauthorized}
    end
  end

  def invite(_scope, _item, _handle, _opts), do: {:error, :unauthorized}

  # A model's AI mode: `:own_key`, or `:owner_key` for an owner holding `"sharing.ai.owner_key"`, the
  # token limit only with it. Other types take neither.
  defp ai_mode_allowed?(_scope, _owner_id, type, nil, nil) when type != :ai_model, do: true
  defp ai_mode_allowed?(_scope, _owner_id, :ai_model, :own_key, nil), do: true

  defp ai_mode_allowed?(%Scope{user: %User{id: uid}} = scope, uid, :ai_model, :owner_key, limit),
    do: (is_nil(limit) or (is_integer(limit) and limit > 0)) and Scope.can?(scope, "sharing.ai.owner_key")

  defp ai_mode_allowed?(_scope, _owner_id, _type, _mode, _limit), do: false

  defp do_invite(scope, inviter, item, type, invitee, fields) do
    existing = Repo.get_by(Share, item_type: type, item_id: item.id, user_id: invitee.id)
    %{role: role, ai_mode: ai_mode, token_limit_per_day: token_limit} = fields
    visibility = if role == :editor, do: :runtime_only, else: fields.visibility

    with :ok <- if(existing && existing.status != :declined, do: {:error, :already_shared}, else: :ok),
         :ok <- Quota.check_pending_invites(scope) do
      share =
        case existing do
          nil ->
            Repo.insert!(%Share{
              item_type: type,
              item_id: item.id,
              owner_id: item.user_id,
              user_id: invitee.id,
              invited_by_id: inviter.id,
              role: role,
              visibility: visibility,
              ai_mode: ai_mode,
              token_limit_per_day: token_limit
            })

          declined ->
            declined
            |> Ecto.Changeset.change(
              status: :pending,
              invited_by_id: inviter.id,
              accepted_at: nil,
              role: role,
              visibility: visibility,
              ai_mode: ai_mode,
              token_limit_per_day: token_limit
            )
            |> Repo.update!()
        end

      :ok = Notifications.share_invite(inviter, share, item)
      announce(share)
      {:ok, share}
    end
  end

  @doc """
  Sets the visibility of `share_id`, a subscriber share of one of the scope user's own items, and
  rebuilds its grants.
  """
  @spec set_visibility(Scope.t(), String.t(), :readable | :runtime_only) ::
          {:ok, Share.t()} | {:error, :not_found | :unauthorized}
  def set_visibility(%Scope{user: %User{id: uid}}, share_id, visibility)
      when visibility in [:readable, :runtime_only] do
    case find_share(share_id) do
      {:ok, %Share{role: :subscriber, owner_id: ^uid} = share} ->
        share = share |> Ecto.Changeset.change(visibility: visibility) |> Repo.update!()
        :ok = Closure.rebuild(share)
        Changes.broadcast(Items.kinds(), [share.owner_id, share.user_id])
        {:ok, share}

      {:ok, _share} ->
        {:error, :unauthorized}

      error ->
        error
    end
  end

  def set_visibility(_scope, _share_id, _visibility), do: {:error, :unauthorized}

  @doc """
  Sets the AI mode and token limit of `share_id`, a share of one of the scope user's own AI models,
  by `invite/4`'s rules (`:owner_key` needs `"sharing.ai.owner_key"`; the limit goes with it only).
  """
  @spec set_ai_mode(Scope.t(), String.t(), :own_key | :owner_key, pos_integer() | nil) ::
          {:ok, Share.t()} | {:error, :not_found | :unauthorized}
  def set_ai_mode(%Scope{user: %User{id: uid}} = scope, share_id, mode, token_limit) do
    case find_share(share_id) do
      {:ok, %Share{item_type: :ai_model, owner_id: ^uid} = share} ->
        if ai_mode_allowed?(scope, uid, :ai_model, mode, token_limit) do
          share =
            share |> Ecto.Changeset.change(ai_mode: mode, token_limit_per_day: token_limit) |> Repo.update!()

          announce(share)
          {:ok, share}
        else
          {:error, :unauthorized}
        end

      {:ok, _share} ->
        {:error, :unauthorized}

      error ->
        error
    end
  end

  def set_ai_mode(_scope, _share_id, _mode, _token_limit), do: {:error, :unauthorized}

  @doc """
  Ends the scope user's own accepted or pending share `share_id`: they leave the item. Its owner
  gets no notice.
  """
  @spec leave(Scope.t(), String.t()) :: {:ok, %{atom() => pos_integer()}} | {:error, :not_found}
  def leave(%Scope{user: %User{id: uid}}, share_id) do
    case find_share(share_id) do
      {:ok, %Share{user_id: ^uid} = share} -> revoke(share, :left)
      _ -> {:error, :not_found}
    end
  end

  def leave(_scope, _share_id), do: {:error, :not_found}

  @doc "Whether `user_id` may read `row`'s protected content: their own row, or an `:edit` or `:readable` grant."
  @spec readable?(Ecto.UUID.t() | nil, struct()) :: boolean()
  def readable?(user_id, %{user_id: user_id}) when is_binary(user_id), do: true
  def readable?(_user_id, %{user_id: nil}), do: false

  def readable?(user_id, %schema{id: id}) when is_binary(user_id) and is_binary(id) do
    case Items.type_of(schema) do
      nil -> false
      type -> Repo.exists?(where(readable_ids(user_id, type), [g], g.item_id == ^id))
    end
  end

  def readable?(_user_id, _row), do: false

  @doc "The ids of `type` rows `user_id` holds an `:edit` or `:readable` grant on, as a query."
  @spec readable_ids(Ecto.UUID.t(), Items.type()) :: Ecto.Query.t()
  def readable_ids(user_id, type) do
    from(g in Grant,
      where: g.user_id == ^user_id and g.item_type == ^type and (g.access == :edit or g.visibility == :readable),
      select: g.item_id
    )
  end

  @doc "Accepts the scope user's pending invite `share_id`: they become an editor or subscriber of its item."
  @spec accept(Scope.t(), String.t()) :: {:ok, Share.t()} | {:error, :not_found}
  def accept(%Scope{} = scope, share_id) do
    with {:ok, share} <- pending_for(scope, share_id) do
      {:ok, share} =
        Repo.transact(fn ->
          share =
            share
            |> Ecto.Changeset.change(status: :accepted, accepted_at: DateTime.utc_now(:second))
            |> Repo.update!()

          :ok = Closure.rebuild(share)
          {:ok, share}
        end)

      :ok = Notifications.clear_share(share.id)
      announce(share)
      {:ok, share}
    end
  end

  @doc "Declines the scope user's pending invite `share_id`; its owner may invite them again."
  @spec decline(Scope.t(), String.t()) :: {:ok, Share.t()} | {:error, :not_found}
  def decline(%Scope{} = scope, share_id) do
    with {:ok, share} <- pending_for(scope, share_id) do
      share = share |> Ecto.Changeset.change(status: :declined) |> Repo.update!()
      :ok = Notifications.clear_share(share.id)
      announce(share)
      {:ok, share}
    end
  end

  defp pending_for(%Scope{user: %User{id: uid}}, share_id) do
    with {:ok, id} <- Ecto.UUID.cast(share_id),
         %Share{} = share <-
           Repo.one(from(s in Share, where: s.id == ^id and s.user_id == ^uid and s.status == :pending)) do
      {:ok, share}
    else
      _ -> {:error, :not_found}
    end
  end

  defp pending_for(_scope, _share_id), do: {:error, :not_found}

  @doc """
  What removing `share_id` would remove from its user's content: a count per
  `Mythweaver.Sharing.Fallout` kind, zeros dropped. The item's owner may ask about any of its shares,
  an editor of the item about its subscriber shares.
  """
  @spec impact(Scope.t(), String.t()) :: {:ok, %{atom() => pos_integer()}} | {:error, :not_found}
  def impact(%Scope{} = scope, share_id) do
    with {:ok, share} <- removable_share(scope, share_id) do
      if share.status == :accepted do
        {:ok, Fallout.impact(share.user_id, lost_without(share))}
      else
        {:ok, %{}}
      end
    end
  end

  @doc """
  Ends `share_id` (cancels it, if still pending): any share of the scope user's own items, or a
  subscriber share of an item the scope user edits.
  """
  @spec remove(Scope.t(), String.t()) :: {:ok, %{atom() => pos_integer()}} | {:error, :not_found}
  def remove(%Scope{} = scope, share_id) do
    with {:ok, share} <- removable_share(scope, share_id), do: revoke(share, :removed)
  end

  defp removable_share(%Scope{user: %User{id: uid}}, share_id) do
    case find_share(share_id) do
      {:ok, %Share{owner_id: ^uid} = share} ->
        {:ok, share}

      {:ok, %Share{role: :subscriber} = share} ->
        edits? =
          Repo.exists?(
            from(g in Grant,
              where:
                g.user_id == ^uid and g.item_type == ^share.item_type and g.item_id == ^share.item_id and
                  g.access == :edit
            )
          )

        if edits?, do: {:ok, share}, else: {:error, :not_found}

      _ ->
        {:error, :not_found}
    end
  end

  defp removable_share(_scope, _share_id), do: {:error, :not_found}

  defp find_share(share_id) do
    with {:ok, id} <- Ecto.UUID.cast(share_id),
         %Share{} = share <- Repo.get(Share, id) do
      {:ok, share}
    else
      _ -> {:error, :not_found}
    end
  end

  ## Hooks for the item contexts

  @doc """
  Ends every share of the item `type`/`id` (before it is deleted). A deleted item's catalog listing
  is unpublished first (`Mythweaver.Catalog.unpublish_item/2`).
  """
  @spec revoke_all(Items.type(), Ecto.UUID.t(), reason()) :: :ok
  def revoke_all(type, id, reason) do
    if reason == :deleted, do: :ok = Mythweaver.Catalog.unpublish_item(type, id)

    for share <- Repo.all(from(s in Share, where: s.item_type == ^type and s.item_id == ^id)),
        do: {:ok, _} = revoke(share, reason)

    :ok
  end

  @doc "Ends every share of `user_id`'s items (before the account is deleted)."
  @spec revoke_owned_by(Ecto.UUID.t(), reason()) :: :ok
  def revoke_owned_by(user_id, reason) do
    for share <- Repo.all(from(s in Share, where: s.owner_id == ^user_id)), do: {:ok, _} = revoke(share, reason)
    :ok
  end

  @doc """
  Deletes every share of the item `type`/`id`, which is becoming a site item every account may use:
  nothing of its editors' is removed, they only get the notice. Its catalog listing is unpublished.
  """
  @spec drop_all(Items.type(), Ecto.UUID.t()) :: :ok
  def drop_all(type, id) do
    :ok = Mythweaver.Catalog.unpublish_item(type, id)
    item = Items.get(type, id)

    for share <- Repo.all(from(s in Share, where: s.item_type == ^type and s.item_id == ^id)) do
      Repo.delete!(share)
      if share.status == :accepted and item, do: :ok = Notifications.share_ended(share, item, :moved_to_site)
      announce(share)
    end

    :ok
  end

  @doc """
  Rebuilds the grants of every accepted share of `owner_ids` (their items may have changed) and
  returns the users those shares reach, for `Mythweaver.Changes` to tell as well.
  """
  @spec after_change([Ecto.UUID.t() | nil]) :: [Ecto.UUID.t()]
  def after_change(owner_ids) do
    case Enum.reject(owner_ids, &is_nil/1) do
      [] ->
        []

      ids ->
        shares = Repo.all(from(s in Share, where: s.owner_id in ^ids and s.status == :accepted))
        Enum.each(shares, &Closure.rebuild/1)
        shares |> Enum.map(& &1.user_id) |> Enum.uniq()
    end
  end

  @doc "The `name` of the `schema` row `id`, unscoped, or nil: a saved reference the viewer cannot list."
  @spec reference_label(module(), Ecto.UUID.t() | nil) :: String.t() | nil
  def reference_label(_schema, nil), do: nil
  def reference_label(schema, id), do: Repo.one(from(r in schema, where: r.id == ^id, select: r.name))

  ## Hand-off

  @doc """
  The accepted editors of `item`, oldest first (earliest `accepted_at`, then `inserted_at`): who may
  receive it from its owner (`hand_off/3`).
  """
  @spec editors(struct()) :: [User.t()]
  def editors(%{id: id} = item) when is_binary(id) do
    case Items.type_of(item) do
      nil ->
        []

      type ->
        Repo.all(
          from(s in Share,
            join: u in assoc(s, :user),
            where: s.item_type == ^type and s.item_id == ^id and s.role == :editor and s.status == :accepted,
            order_by: [asc: s.accepted_at, asc: s.inserted_at, asc: s.id],
            select: u
          )
        )
    end
  end

  def editors(_item), do: []

  @doc "The editor `hand_off/3` gives `item` to by default: the first of `editors/1`, or nil."
  @spec oldest_editor(struct()) :: User.t() | nil
  def oldest_editor(item), do: item |> editors() |> List.first()

  @doc """
  For an item's delete: with accepted editors, gives `item` to `opts[:to]` (a user id) or else the
  oldest editor instead of deleting it, `{:ok, {:handed_off, user}}`; without, runs `delete`.
  """
  @spec hand_off_or(Scope.t(), struct(), keyword(), (-> result)) ::
          result | {:ok, {:handed_off, User.t()}} | {:error, :unauthorized | {:needs_share, struct()}}
        when result: term()
  def hand_off_or(scope, item, opts, delete) do
    case editors(item) do
      [] ->
        delete.()

      [oldest | _] ->
        with {:ok, user} <- hand_off(scope, item, Keyword.get(opts, :to) || oldest.id),
             do: {:ok, {:handed_off, user}}
    end
  end

  @doc """
  Gives the scope user's own root `item` to `user_id`, one of its accepted editors, who owns it from
  then on. In one transaction: the root and its parts (a book's entries and the pools holding only
  them) change owner; the recipient's share goes; every other share of the item names the recipient
  as its owner and its grants are rebuilt. The old owner keeps nothing: `Mythweaver.Sharing.Fallout`
  removes their references to what moved, as a lost share would, and the item loses the references
  its new owner may not use (`Mythweaver.Sharing.HandOff`); anyone else who loses a grant by it gets
  the same fallout. The recipient gets a `:handed_off` inbox notice; the other editors and subscribers
  none (the item stays theirs to use).

  A side prompt whose prompt the recipient could not use refuses: `{:error, {:needs_share, prompt}}`.
  """
  @spec hand_off(Scope.t(), struct(), Ecto.UUID.t()) ::
          {:ok, User.t()} | {:error, :unauthorized | {:needs_share, struct()}}
  def hand_off(%Scope{user: %User{id: uid} = giver}, %{id: id, user_id: uid} = item, user_id) do
    type = Items.type_of(item)

    with true <- Items.root?(type),
         {:ok, user_id} <- Ecto.UUID.cast(user_id),
         %Share{} = share <-
           Repo.one(
             from(s in Share,
               where:
                 s.item_type == ^type and s.item_id == ^id and s.user_id == ^user_id and s.role == :editor and
                   s.status == :accepted,
               preload: :user
             )
           ) do
      case HandOff.blocking_prompt(type, item, share) do
        nil -> do_hand_off(giver, type, item, share)
        prompt -> {:error, {:needs_share, prompt}}
      end
    else
      _ -> {:error, :unauthorized}
    end
  end

  def hand_off(_scope, _item, _user_id), do: {:error, :unauthorized}

  @doc """
  Hands each of `user`'s root items that has accepted editors to its oldest editor (before the
  account is deleted). An item that refuses (`hand_off/3`) is left to go with the account.
  """
  @spec hand_off_owned_by(User.t()) :: :ok
  def hand_off_owned_by(%User{id: uid} = user) do
    scope = Scope.for_user(user)

    items =
      Repo.all(
        from(s in Share,
          where: s.owner_id == ^uid and s.role == :editor and s.status == :accepted,
          distinct: true,
          select: {s.item_type, s.item_id}
        )
      )

    for {type, id} <- items,
        item = Items.get(type, id),
        match?(%{user_id: ^uid}, item),
        editor = oldest_editor(item),
        do: hand_off(scope, item, editor.id)

    :ok
  end

  defp do_hand_off(giver, type, item, %Share{user: recipient} = share) do
    old = giver.id
    new = recipient.id
    moved = for {t, i, :edit} <- Closure.of(type, item.id, old), do: {t, i}
    moved_by_type = group(moved)

    # Everyone a share of the old owner reaches may lose a grant by the move (the recipient most).
    watched =
      Repo.all(from(s in Share, where: s.owner_id == ^old and s.status == :accepted, distinct: true, select: s.user_id))

    {:ok, chats} =
      Repo.transact(fn ->
        before = Closure.grant_sets(watched)

        for {t, ids} <- moved_by_type,
            do:
              Repo.update_all(from(r in Items.schema(t), where: r.id in ^ids and r.user_id == ^old),
                set: [user_id: new]
              )

        Repo.delete!(share)
        others = from(s in Share, where: s.item_type == ^type and s.item_id == ^item.id, select: s.id)
        Repo.update_all(from(g in Grant, where: g.share_id in subquery(others)), set: [owner_id: new])
        Repo.update_all(others, set: [owner_id: new])
        :ok = HandOff.strip(type, item.id, moved_by_type, new)
        :ok = Mythweaver.Catalog.move_listing(type, item.id, new)
        after_change([old, new])

        owned = MapSet.new(moved)
        now = Closure.grant_sets(watched)

        lost =
          for user_id <- watched, into: %{old => moved_by_type} do
            {user_id,
             before
             |> Map.fetch!(user_id)
             |> MapSet.difference(Map.fetch!(now, user_id))
             |> MapSet.difference(owned)
             |> group()}
          end

        chats = for {user_id, rows} <- lost, rows != %{}, do: {user_id, Fallout.run(user_id, rows)}
        :ok = Notifications.handed_off(new, giver, type, item)
        {:ok, chats}
      end)

    for {user_id, chat_ids} <- chats, do: :ok = Chats.announce_updated(user_id, chat_ids)
    Changes.broadcast(Items.kinds(), [old, new])
    {:ok, recipient}
  end

  ## Revocation

  defp revoke(%Share{status: :accepted} = share, reason) do
    item = Items.get(share.item_type, share.item_id)

    {:ok, {impact, chat_ids}} =
      Repo.transact(fn ->
        before = Closure.grant_sets([share.user_id])[share.user_id]
        Repo.delete!(share)
        lost = group(MapSet.difference(before, Closure.grant_sets([share.user_id])[share.user_id]))
        impact = Fallout.impact(share.user_id, lost)
        chat_ids = Fallout.run(share.user_id, lost)
        if item, do: :ok = Notifications.share_ended(share, item, reason)
        {:ok, {impact, chat_ids}}
      end)

    if share.catalog_listing_id, do: :ok = Mythweaver.Catalog.refresh_count(share.catalog_listing_id)

    :ok = Chats.announce_updated(share.user_id, chat_ids)
    Notifications.broadcast_changed(share.user_id)
    Changes.broadcast(Items.kinds(), [share.owner_id, share.user_id])
    {:ok, impact}
  end

  defp revoke(%Share{} = share, _reason) do
    Repo.delete!(share)
    Notifications.broadcast_changed(share.user_id)
    announce(share)
    {:ok, %{}}
  end

  # What `share`'s user would lose without it.
  defp lost_without(share) do
    others = from(g in Grant, where: g.user_id == ^share.user_id and g.share_id != ^share.id)
    kept = MapSet.new(Repo.all(from(g in others, select: {g.item_type, g.item_id})))

    from(g in Grant, where: g.share_id == ^share.id, select: {g.item_type, g.item_id})
    |> Repo.all()
    |> MapSet.new()
    |> MapSet.difference(kept)
    |> group()
  end

  defp group(set), do: Enum.group_by(set, &elem(&1, 0), &elem(&1, 1))

  defp announce(%Share{} = share), do: Changes.broadcast(Items.kind(share.item_type), [share.owner_id, share.user_id])

  ## Received

  @doc """
  The scope user's accepted shares, owners preloaded, each with its item, by item name: what
  `/shared` lists. A share whose item is gone is left out.
  """
  @spec list_received(Scope.t()) :: [{Share.t(), struct()}]
  def list_received(%Scope{user: %User{id: uid}}) do
    shares = Repo.all(from(s in Share, where: s.user_id == ^uid and s.status == :accepted, preload: :owner))

    items =
      shares
      |> Enum.group_by(& &1.item_type, & &1.item_id)
      |> Enum.flat_map(fn {type, ids} ->
        for item <- Repo.all(from(i in Items.schema(type), where: i.id in ^ids)), do: {{type, item.id}, item}
      end)
      |> Map.new()

    shares
    |> Enum.flat_map(fn share ->
      case Map.fetch(items, {share.item_type, share.item_id}) do
        {:ok, item} -> [{share, item}]
        :error -> []
      end
    end)
    |> Enum.sort_by(fn {share, item} -> {String.downcase(item.name || ""), share.id} end)
  end

  def list_received(_scope), do: []

  @doc "Whether the scope user has accepted any share."
  @spec received_any?(Scope.t() | nil) :: boolean()
  def received_any?(%Scope{user: %User{id: uid}}),
    do: Repo.exists?(from(s in Share, where: s.user_id == ^uid and s.status == :accepted))

  def received_any?(_scope), do: false

  ## Site content

  @doc """
  Every site root item, of each root type in `Mythweaver.Sharing.Items.root_types/0` order, by name:
  whether the scope user opted out of it (`opt_out/2`), and whether it is a forced lore book, which
  no one may opt out of.
  """
  @spec list_site_items(Scope.t() | nil) :: [
          %{type: Items.root_type(), item: struct(), opted_out?: boolean(), forced?: boolean()}
        ]
  def list_site_items(scope) do
    opted =
      case scope do
        %Scope{user: %User{id: uid}} ->
          MapSet.new(Repo.all(from(o in OptOut, where: o.user_id == ^uid, select: {o.item_type, o.item_id})))

        _ ->
          MapSet.new()
      end

    for type <- Items.root_types(),
        item <-
          Repo.all(
            from(i in Items.schema(type),
              where: is_nil(i.user_id),
              order_by: [asc: fragment("lower(?)", i.name), asc: i.id]
            )
          ) do
      %{
        type: type,
        item: item,
        opted_out?: MapSet.member?(opted, {type, item.id}),
        forced?: match?(%LoreBook{forced: true}, item)
      }
    end
  end

  @doc """
  Stops the scope user using the site root `item`: `Mythweaver.Ownership` leaves it out of what they
  may use and of their chats' resolution, and `Mythweaver.Sharing.Fallout` removes their references
  to it and its site parts (a book's entries no other site book they keep holds), as a lost share
  would. Returns that impact. A forced lore book refuses.
  """
  @spec opt_out(Scope.t(), struct()) :: {:ok, %{atom() => pos_integer()}} | {:error, :forced | :unauthorized}
  def opt_out(scope, item) do
    with {:ok, uid, type} <- opt_out_target(scope, item) do
      {:ok, {impact, chat_ids}} =
        Repo.transact(fn ->
          Repo.insert!(%OptOut{user_id: uid, item_type: type, item_id: item.id},
            on_conflict: :nothing,
            conflict_target: [:user_id, :item_type, :item_id]
          )

          lost = opt_out_lost(uid, type, item.id)
          impact = Fallout.impact(uid, lost)
          {:ok, {impact, Fallout.run(uid, lost)}}
        end)

      :ok = Chats.announce_updated(uid, chat_ids)
      Changes.broadcast(Items.kinds(), [uid])
      {:ok, impact}
    end
  end

  @doc "Uses the site root `item` again after `opt_out/2`; what the opt-out removed stays removed."
  @spec opt_in(Scope.t(), struct()) :: :ok
  def opt_in(%Scope{user: %User{id: uid}}, %{id: id, user_id: nil} = item) do
    type = Items.type_of(item)

    if Items.root?(type) do
      Repo.delete_all(from(o in OptOut, where: o.user_id == ^uid and o.item_type == ^type and o.item_id == ^id))
      Changes.broadcast(Items.kind(type), [uid])
    end

    :ok
  end

  def opt_in(_scope, _item), do: :ok

  @doc "What `opt_out/2` of `item` would remove from the scope user's content: a count per `Fallout` kind."
  @spec opt_out_impact(Scope.t(), struct()) :: {:ok, %{atom() => pos_integer()}} | {:error, :forced | :unauthorized}
  def opt_out_impact(scope, item) do
    with {:ok, uid, type} <- opt_out_target(scope, item),
         do: {:ok, Fallout.impact(uid, opt_out_lost(uid, type, item.id))}
  end

  defp opt_out_target(%Scope{user: %User{id: uid}}, %{id: id} = item) when is_binary(id) do
    type = Items.type_of(item)

    case Items.root?(type) && Items.get(type, id) do
      %LoreBook{user_id: nil, forced: true} -> {:error, :forced}
      %{user_id: nil} -> {:ok, uid, type}
      _ -> {:error, :unauthorized}
    end
  end

  defp opt_out_target(_scope, _item), do: {:error, :unauthorized}

  # What `uid` loses without the site item `type`/`id`: the item, and a book's site entries no other
  # site book `uid` keeps holds.
  defp opt_out_lost(uid, :lore_book, id) do
    kept_books =
      from(b in LoreBook,
        where: is_nil(b.user_id) and b.id != ^id and b.id not in subquery(OptOut.ids(uid, :lore_book)),
        select: b.id
      )

    kept_entries = from(be in BookEntry, where: be.lore_book_id in subquery(kept_books), select: be.lore_entry_id)

    entries =
      Repo.all(
        from(e in LoreEntry,
          join: be in BookEntry,
          on: be.lore_entry_id == e.id and be.lore_book_id == ^id,
          where: is_nil(e.user_id) and e.id not in subquery(kept_entries),
          select: e.id
        )
      )

    %{lore_book: [id], lore_entry: entries}
  end

  defp opt_out_lost(_uid, type, id), do: %{type => [id]}

  ## Toggles

  @doc """
  Switches the lore entry, block or script `row` on or off for the scope user alone
  (`Mythweaver.Sharing.Toggle`), without cloning it. Only rows reached through a share or the site
  take toggles: the user's own row refuses (`:own`), as does an entry of a forced site book
  (`:forced`). Announces the row's kind to the user only.
  """
  @spec set_toggle(Scope.t(), struct(), boolean()) ::
          {:ok, Toggle.t()} | {:error, :own | :forced | :unauthorized}
  def set_toggle(scope, row, enabled?) when is_boolean(enabled?) do
    with {:ok, uid, type} <- toggle_target(scope, row) do
      hash = if type == :script and enabled?, do: Script.consent_hash(row)

      toggle =
        Repo.insert!(%Toggle{user_id: uid, item_type: type, item_id: row.id, enabled: enabled?, consent_hash: hash},
          on_conflict: [set: [enabled: enabled?, consent_hash: hash, updated_at: DateTime.utc_now(:second)]],
          conflict_target: [:user_id, :item_type, :item_id],
          returning: true
        )

      Changes.broadcast(Items.kind(type), [uid])
      {:ok, toggle}
    end
  end

  @doc """
  `user_id`'s toggle on `script` as `{enabled, consent_hash}`, or nil when untoggled. The script
  was consented to unchanged when it is `{true, Script.consent_hash(script)}`.
  """
  @spec script_toggle(Ecto.UUID.t() | nil, Script.t()) :: {boolean(), String.t() | nil} | nil
  def script_toggle(user_id, _script) when not is_binary(user_id), do: nil

  def script_toggle(user_id, %Script{id: id}) do
    Repo.one(
      from(t in Toggle,
        where: t.user_id == ^user_id and t.item_type == :script and t.item_id == ^id,
        select: {t.enabled, t.consent_hash}
      )
    )
  end

  @doc "Drops the scope user's toggle on `row`, so its default state applies again."
  @spec clear_toggle(Scope.t(), struct()) :: :ok | {:error, :own | :forced | :unauthorized}
  def clear_toggle(scope, row) do
    with {:ok, uid, type} <- toggle_target(scope, row) do
      Repo.delete_all(from(t in Toggle, where: t.user_id == ^uid and t.item_type == ^type and t.item_id == ^row.id))

      Changes.broadcast(Items.kind(type), [uid])
      :ok
    end
  end

  @doc "`user_id`'s toggles on the `type` rows `ids`, as `%{id => enabled}`; untoggled ids are absent."
  @spec toggles(Ecto.UUID.t() | nil, Toggle.item_type(), [Ecto.UUID.t()]) :: %{Ecto.UUID.t() => boolean()}
  def toggles(user_id, _type, _ids) when not is_binary(user_id), do: %{}
  def toggles(_user_id, _type, []), do: %{}

  def toggles(user_id, type, ids) do
    from(t in Toggle,
      where: t.user_id == ^user_id and t.item_type == ^type and t.item_id in ^ids,
      select: {t.item_id, t.enabled}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp toggle_target(%Scope{user: %User{id: uid}}, %schema{id: id, user_id: owner_id} = row) when is_binary(id) do
    type = Items.type_of(schema)

    cond do
      type not in [:lore_entry, :block, :script] -> {:error, :unauthorized}
      owner_id == uid -> {:error, :own}
      type == :lore_entry and MapSet.member?(forced_entries([id]), id) -> {:error, :forced}
      is_nil(owner_id) or granted?(uid, row, [:edit, :use]) -> {:ok, uid, type}
      true -> {:error, :unauthorized}
    end
  end

  defp toggle_target(_scope, _row), do: {:error, :unauthorized}

  @doc "Which of the lore entries `ids` sit in a forced site book, so no one may toggle them."
  @spec forced_entries([Ecto.UUID.t()]) :: MapSet.t(Ecto.UUID.t())
  def forced_entries([]), do: MapSet.new()

  def forced_entries(ids) do
    from(be in BookEntry,
      join: b in LoreBook,
      on: b.id == be.lore_book_id,
      where: be.lore_entry_id in ^ids and is_nil(b.user_id) and b.forced,
      distinct: true,
      select: be.lore_entry_id
    )
    |> Repo.all()
    |> MapSet.new()
  end
end
