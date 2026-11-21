defmodule Mythweaver.Catalog do
  @moduledoc """
  The catalog: root items their owners publish for anyone to subscribe to.

  A published item has one **mirror**, a frozen copy of its closure: ordinary rows owned by the
  publisher, marked `frozen_listing_id` (their `Mythweaver.Catalog.Listing`) and `mirror_of_id`
  (the live row each copies), made by `Mythweaver.Sharing.Clone.mirror/5`. `Mythweaver.Ownership`
  never counts them among the publisher's own rows and refuses to edit or delete them; only this
  module writes them. Each release (`release/3`) updates the mirror in place from the live item, so
  subscribers follow the latest release; older releases keep only their `Mythweaver.Catalog.Release`
  row.

  A subscription is a `:subscriber` `Mythweaver.Sharing.Share` of the mirror root with
  `catalog_listing_id` set and the listing's visibility, accepted on creation: grants, fallout,
  toggles, `/shared`, Clone and revocation work on it as on any share. A listing never shows who
  subscribed, only `subscriber_count`.

  Unpublishing (`unpublish/2`, or deleting the live item) and a moderator's takedown (`takedown/3`)
  end every subscription (`:unpublished` / `:taken_down`), then delete the mirror and the listing.
  Handing the live item off (`Mythweaver.Sharing.hand_off/3`) moves its listing to the new owner.
  Publishing needs `"catalog.publish"`, featuring `"catalog.feature"`, takedowns
  `"moderation.content.delete"`, and seeing taken-down listings `"moderation.content.view"`.
  """

  import Ecto.Query

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.Attachments
  alias Mythweaver.Attachments.CharacterAttachment
  alias Mythweaver.Catalog.Listing
  alias Mythweaver.Catalog.Release
  alias Mythweaver.Changes
  alias Mythweaver.Chats
  alias Mythweaver.Expressions.Outfit
  alias Mythweaver.Expressions.Sprite
  alias Mythweaver.Memory.SidePromptSetRow
  alias Mythweaver.Moderation
  alias Mythweaver.Moderation.Log
  alias Mythweaver.Moderation.Reports
  alias Mythweaver.Notifications
  alias Mythweaver.Repo
  alias Mythweaver.Sharing
  alias Mythweaver.Sharing.Clone
  alias Mythweaver.Sharing.Closure
  alias Mythweaver.Sharing.Fallout
  alias Mythweaver.Sharing.Grant
  alias Mythweaver.Sharing.Items
  alias Mythweaver.Sharing.Share

  @types Items.root_types() -- [:ai_model]

  # Mirror rows are deleted referrers first, so no foreign key between them blocks a delete.
  @delete_order [
    :side_prompt_set,
    :side_prompt,
    :memory_profile,
    :character,
    :lore_book,
    :lore_pool,
    :lore_entry,
    :prompt,
    :block,
    :outlet,
    :script,
    :expression_profile,
    :ai_model
  ]

  @doc "The root types that can be published."
  @spec types() :: [Items.root_type()]
  def types, do: @types

  ## Reading

  @doc """
  Listings anyone may browse: not taken down, featured first, then newest. `opts`: `:search` (over
  title, summary and tags, case-insensitively), `:type` (an item type) and `:tag`.
  """
  @spec list_listings(Scope.t() | nil, keyword()) :: [Listing.t()]
  def list_listings(_scope, opts \\ []) do
    from(l in Listing,
      where: is_nil(l.hidden_at),
      order_by: [desc: l.featured, desc: l.published_at, desc: l.id],
      preload: [:owner, :current_release]
    )
    |> filter_search(opts[:search])
    |> filter_type(opts[:type])
    |> filter_tag(opts[:tag])
    |> Repo.all()
  end

  defp filter_search(query, term) when is_binary(term) and term != "" do
    like = "%" <> String.replace(term, ~r/[\\%_]/, "\\\\\\0") <> "%"

    where(
      query,
      [l],
      ilike(l.title, ^like) or ilike(l.summary, ^like) or
        fragment("EXISTS (SELECT 1 FROM unnest(?) AS t WHERE t ILIKE ?)", l.tags, ^like)
    )
  end

  defp filter_search(query, _term), do: query

  defp filter_type(query, type) when type in @types, do: where(query, [l], l.item_type == ^type)
  defp filter_type(query, _type), do: query

  defp filter_tag(query, tag) when is_binary(tag) and tag != "", do: where(query, [l], ^String.downcase(tag) in l.tags)

  defp filter_tag(query, _tag), do: query

  @doc """
  The listing `id` with its owner and releases (newest first), or nil. A taken-down listing is shown
  only to its owner and moderators.
  """
  @spec get_listing(Scope.t() | nil, String.t()) :: Listing.t() | nil
  def get_listing(scope, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Listing{} = listing <- Repo.get(Listing, id),
         true <- is_nil(listing.hidden_at) or owner?(scope, listing) or moderator?(scope) do
      Repo.preload(listing, [:owner, :current_release, :releases])
    else
      _ -> nil
    end
  end

  @doc "The listing of the live root `item`, or nil when it is not published."
  @spec listing_for(struct()) :: Listing.t() | nil
  def listing_for(%{id: id} = item) when is_binary(id) do
    case Items.type_of(item) do
      type when type in @types ->
        Repo.one(from(l in Listing, where: l.item_type == ^type and l.item_id == ^id, preload: :current_release))

      _ ->
        nil
    end
  end

  def listing_for(_item), do: nil

  @doc "The scope user's subscription share of `listing`, or nil."
  @spec subscription(Scope.t() | nil, Listing.t()) :: Share.t() | nil
  def subscription(%Scope{user: %User{id: uid}}, %Listing{id: id}),
    do: Repo.one(from(s in Share, where: s.catalog_listing_id == ^id and s.user_id == ^uid))

  def subscription(_scope, _listing), do: nil

  ## Publishing

  @doc """
  Publishes the scope user's own root `item` with `attrs` (`title`, `summary`, `tags`,
  `visibility`): creates its mirror, the listing and release 1, in one transaction.

  `{:error, :unauthorized}` without `"catalog.publish"`, for another owner's or a site item, a type
  that cannot be published (`types/0`) or a side prompt whose prompt is another user's;
  `{:error, changeset}` for invalid attrs or an item already published.
  """
  @spec publish(Scope.t(), struct(), map()) ::
          {:ok, Listing.t()} | {:error, :unauthorized | Ecto.Changeset.t() | term()}
  def publish(%Scope{user: %User{id: uid}} = scope, %{id: id, user_id: uid} = item, attrs) when is_binary(id) do
    type = Items.type_of(item)
    listing_id = Mythweaver.Schema.generate_id()

    changeset =
      Listing.changeset(%Listing{id: listing_id, item_type: type, item_id: id, owner_id: uid}, attrs)

    with true <- (type in @types and is_nil(item.frozen_listing_id)) || {:error, :unauthorized},
         :ok <- Scope.authorize(scope, "catalog.publish"),
         {:ok, _} <- Ecto.Changeset.apply_action(changeset, :insert),
         {:ok, files} <- Clone.mirror_files(scope, item) do
      result =
        Repo.transact(fn ->
          {mirror_id, _copies, _replaced} = Clone.mirror(scope, item, listing_id, %{}, files)
          if is_nil(mirror_id), do: Repo.rollback(:unauthorized)

          with {:ok, listing} <-
                 changeset
                 |> Ecto.Changeset.change(mirror_id: mirror_id, published_at: DateTime.utc_now(:second))
                 |> Repo.insert() do
            {:ok, put_release(listing, uid, nil)}
          end
        end)

      if match?({:error, _}, result), do: Attachments.delete_orphaned(for {_old, new} <- files, do: new.id)
      result
    end
  end

  def publish(_scope, _item, _attrs), do: {:error, :unauthorized}

  @doc """
  Releases the live item of the scope user's own `listing` as its next version with `notes`: the
  mirror's rows still reached are updated in place, new ones copied, and those the item no longer
  reaches deleted after `Mythweaver.Sharing.Fallout` removes subscribers' references to them, as a
  revoke would; then every subscription's grants are rebuilt.
  """
  @spec release(Scope.t(), Listing.t(), String.t() | nil) :: {:ok, Listing.t()} | {:error, :unauthorized | term()}
  def release(%Scope{user: %User{id: uid}} = scope, %Listing{owner_id: uid, hidden_at: nil} = listing, notes) do
    listing = Repo.get!(Listing, listing.id)

    with %{user_id: ^uid} = item <- Items.get(listing.item_type, listing.item_id),
         {:ok, files} <- Clone.mirror_files(scope, item) do
      shares = subscriptions(listing)

      result =
        Repo.transact(fn ->
          user_ids = Enum.map(shares, & &1.user_id)
          before = Closure.grant_sets(user_ids)
          existing = mirror_rows(listing.id)
          {mirror_id, copies, replaced} = Clone.mirror(scope, item, listing.id, existing, files)
          if mirror_id != listing.mirror_id, do: Repo.rollback(:unauthorized)

          gone = existing |> Map.drop(Map.keys(copies)) |> Enum.group_by(&elem(elem(&1, 0), 0), &elem(&1, 1))
          delete_children(gone)
          Enum.each(shares, &Closure.rebuild/1)
          now = Closure.grant_sets(user_ids)

          chats =
            for {user_id, set} <- before,
                lost = lost(set, now[user_id]),
                lost != %{},
                do: {user_id, Fallout.run(user_id, lost)}

          orphaned = delete_rows(gone)
          {:ok, {put_release(listing, uid, notes), chats, replaced ++ orphaned}}
        end)

      case result do
        {:ok, {listing, chats, replaced}} ->
          Attachments.delete_orphaned(replaced)
          for {user_id, chat_ids} <- chats, do: :ok = Chats.announce_updated(user_id, chat_ids)
          Changes.broadcast(Items.kinds(), [uid | Enum.map(shares, & &1.user_id)])
          {:ok, listing}

        {:error, reason} ->
          Attachments.delete_orphaned(for {_old, new} <- files, do: new.id)
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unauthorized}
    end
  end

  def release(_scope, _listing, _notes), do: {:error, :unauthorized}

  # Records the listing's next release and makes it current.
  defp put_release(listing, uid, notes) do
    version = (Repo.one(from(r in Release, where: r.listing_id == ^listing.id, select: max(r.version))) || 0) + 1
    release = Repo.insert!(%Release{listing_id: listing.id, version: version, notes: notes, published_by_id: uid})

    listing
    |> Ecto.Changeset.change(current_release_id: release.id)
    |> Repo.update!()
    |> Map.put(:current_release, release)
  end

  # The mirror's rows, as `Mythweaver.Sharing.Clone.mirror/5` takes them.
  defp mirror_rows(listing_id) do
    rows =
      for type <- @delete_order,
          {live, id} <-
            Repo.all(
              from(r in Items.schema(type), where: r.frozen_listing_id == ^listing_id, select: {r.mirror_of_id, r.id})
            ),
          into: %{},
          do: {{type, live}, id}

    characters = for {{:character, _live}, id} <- rows, do: id
    sets = for {{:side_prompt_set, _live}, id} <- rows, do: id

    children =
      Enum.map(Repo.all(from(o in Outfit, where: o.character_id in ^characters, select: {o.mirror_of_id, o.id})), fn
        {live, id} -> {{:outfit, live}, id}
      end) ++
        Enum.map(Repo.all(from(s in Sprite, where: s.character_id in ^characters, select: {s.mirror_of_id, s.id})), fn
          {live, id} -> {{:sprite, live}, id}
        end) ++
        Enum.map(
          Repo.all(from(r in SidePromptSetRow, where: r.side_prompt_set_id in ^sets, select: {r.mirror_of_id, r.id})),
          fn {live, id} -> {{:set_row, live}, id} end
        )

    Map.merge(rows, Map.new(children))
  end

  # Children a release no longer copies; deleting them clears what pointed at them.
  defp delete_children(gone) do
    Repo.delete_all(from(s in Sprite, where: s.id in ^Map.get(gone, :sprite, [])))
    Repo.delete_all(from(o in Outfit, where: o.id in ^Map.get(gone, :outfit, [])))
    Repo.delete_all(from(r in SidePromptSetRow, where: r.id in ^Map.get(gone, :set_row, [])))
  end

  # Deletes mirror rows by type (`%{type => ids}`), referrers first; returns the attachments their
  # characters linked, now orphaned.
  defp delete_rows(by_type) do
    characters = Map.get(by_type, :character, [])

    files =
      Repo.all(from(ca in CharacterAttachment, where: ca.character_id in ^characters, select: ca.attachment_id)) ++
        Repo.all(from(s in Sprite, where: s.character_id in ^characters, select: s.attachment_id))

    for type <- @delete_order,
        ids = Map.get(by_type, type, []),
        ids != [],
        do: Repo.delete_all(from(r in Items.schema(type), where: r.id in ^ids))

    Enum.uniq(files)
  end

  defp subscriptions(%Listing{id: id}),
    do: Repo.all(from(s in Share, where: s.catalog_listing_id == ^id and s.status == :accepted))

  # What a user held in `before` and no longer holds in `now`, by type.
  defp lost(before, now) do
    before
    |> MapSet.difference(now)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  ## Subscriptions

  @doc """
  Subscribes the scope user to `listing`: an accepted subscriber share of its mirror root with the
  listing's visibility, its grants built. Not one's own listing, nor a taken-down one.
  """
  @spec subscribe(Scope.t(), Listing.t()) :: {:ok, Share.t()} | {:error, :unauthorized | :already_subscribed}
  def subscribe(%Scope{user: %User{id: uid}}, %Listing{id: id}) do
    with %Listing{hidden_at: nil, owner_id: owner} = listing when owner != uid <- Repo.get(Listing, id),
         nil <- Repo.get_by(Share, item_type: listing.item_type, item_id: listing.mirror_id, user_id: uid) do
      share =
        Repo.insert!(%Share{
          item_type: listing.item_type,
          item_id: listing.mirror_id,
          owner_id: owner,
          user_id: uid,
          role: :subscriber,
          visibility: listing.visibility,
          status: :accepted,
          accepted_at: DateTime.utc_now(:second),
          catalog_listing_id: listing.id
        })

      :ok = Closure.rebuild(share)
      :ok = refresh_count(listing.id)
      Changes.broadcast(Items.kinds(), [owner, uid])
      {:ok, share}
    else
      %Share{} -> {:error, :already_subscribed}
      _ -> {:error, :unauthorized}
    end
  end

  def subscribe(_scope, _listing), do: {:error, :unauthorized}

  @doc "Ends the scope user's subscription to `listing` (`Mythweaver.Sharing.leave/2`)."
  @spec unsubscribe(Scope.t(), Listing.t()) :: {:ok, %{atom() => pos_integer()}} | {:error, :not_found}
  def unsubscribe(scope, %Listing{} = listing) do
    case subscription(scope, listing) do
      %Share{id: share_id} -> Sharing.leave(scope, share_id)
      nil -> {:error, :not_found}
    end
  end

  @doc "Recounts `listing_id`'s `subscriber_count` (after a subscription starts or ends)."
  @spec refresh_count(Ecto.UUID.t()) :: :ok
  def refresh_count(listing_id) do
    count = Repo.aggregate(from(s in Share, where: s.catalog_listing_id == ^listing_id), :count)
    Repo.update_all(from(l in Listing, where: l.id == ^listing_id), set: [subscriber_count: count])

    :ok
  end

  @doc """
  Sets the visibility of the scope user's own `listing` and of every subscription to it, rebuilding
  their grants.
  """
  @spec set_visibility(Scope.t(), Listing.t(), :readable | :runtime_only) ::
          {:ok, Listing.t()} | {:error, :unauthorized}
  def set_visibility(%Scope{user: %User{id: uid}}, %Listing{owner_id: uid} = listing, visibility)
      when visibility in [:readable, :runtime_only] do
    {:ok, {listing, shares}} =
      Repo.transact(fn ->
        listing = listing |> Ecto.Changeset.change(visibility: visibility) |> Repo.update!()
        Repo.update_all(from(s in Share, where: s.catalog_listing_id == ^listing.id), set: [visibility: visibility])
        shares = subscriptions(listing)
        Enum.each(shares, &Closure.rebuild/1)
        {:ok, {listing, shares}}
      end)

    Changes.broadcast(Items.kinds(), [uid | Enum.map(shares, & &1.user_id)])
    {:ok, listing}
  end

  def set_visibility(_scope, _listing, _visibility), do: {:error, :unauthorized}

  ## Ending a listing

  @doc """
  What unpublishing the scope user's own `listing` would remove from its subscribers' content: the
  `Mythweaver.Sharing.impact/2` of every subscription, summed per kind.
  """
  @spec unpublish_impact(Scope.t(), Listing.t()) :: {:ok, %{atom() => pos_integer()}} | {:error, :unauthorized}
  def unpublish_impact(%Scope{user: %User{id: uid}} = scope, %Listing{owner_id: uid} = listing) do
    impact =
      Enum.reduce(subscriptions(listing), %{}, fn share, acc ->
        {:ok, counts} = Sharing.impact(scope, share.id)
        Map.merge(acc, counts, fn _kind, a, b -> a + b end)
      end)

    {:ok, impact}
  end

  def unpublish_impact(_scope, _listing), do: {:error, :unauthorized}

  @doc """
  Unpublishes the scope user's own `listing`: ends every subscription (`:unpublished`, with the
  fallout of a revoke), then deletes the mirror and the listing.
  """
  @spec unpublish(Scope.t(), Listing.t()) :: :ok | {:error, :unauthorized}
  def unpublish(%Scope{user: %User{id: uid}}, %Listing{owner_id: uid} = listing), do: end_listing(listing, :unpublished)
  def unpublish(_scope, _listing), do: {:error, :unauthorized}

  @doc """
  Takes `listing` down (`"moderation.content.delete"`; an owner's listing only by an owner): ends it
  as `unpublish/2` does (`:taken_down`), tells its owner why (`reason`, required) in their inbox,
  marks its open reports actioned and writes the moderation log.
  """
  @spec takedown(Scope.t(), Listing.t(), String.t()) ::
          :ok | {:error, :unauthorized | :not_found | :reason_required}
  def takedown(%Scope{user: %User{}} = scope, %Listing{id: id}, reason) when is_binary(reason) do
    reason = String.trim(reason)

    with :ok <- Scope.authorize(scope, "moderation.content.delete"),
         :ok <- if(reason == "", do: {:error, :reason_required}, else: :ok),
         %Listing{} = listing <- Repo.get(Listing, id) |> Repo.preload(:owner),
         :ok <- Moderation.authorize_owned_by(scope, listing.owner) do
      :ok = end_listing(listing, :taken_down)
      :ok = Notifications.listing_taken_down(listing.owner_id, listing.title, reason)
      :ok = Reports.resolve_subject(scope, :listing, listing.id)

      :ok =
        Log.record(scope, :taken_down, :listing, listing.id, listing.owner_id, %{
          "reason" => reason,
          "title" => listing.title
        })

      Moderation.broadcast_changed()
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def takedown(_scope, _listing, _reason), do: {:error, :unauthorized}

  @doc "Unpublishes the listing of the live item `type`/`id`, if any (before the item is deleted)."
  @spec unpublish_item(Items.type(), Ecto.UUID.t()) :: :ok
  def unpublish_item(type, id) when type in @types do
    case Repo.one(from(l in Listing, where: l.item_type == ^type and l.item_id == ^id)) do
      nil -> :ok
      listing -> end_listing(listing, :unpublished)
    end
  end

  def unpublish_item(_type, _id), do: :ok

  @doc """
  Gives the listing of the live item `type`/`id`, if any, to `owner_id` with its mirror rows and
  subscriptions, inside `Mythweaver.Sharing.hand_off/3`'s transaction (before the grants are rebuilt).
  """
  @spec move_listing(Items.type(), Ecto.UUID.t(), Ecto.UUID.t()) :: :ok
  def move_listing(type, id, owner_id) when type in @types do
    case Repo.one(from(l in Listing, where: l.item_type == ^type and l.item_id == ^id, select: l.id)) do
      nil ->
        :ok

      listing_id ->
        Repo.update_all(from(l in Listing, where: l.id == ^listing_id), set: [owner_id: owner_id])

        for t <- @delete_order,
            do:
              Repo.update_all(from(r in Items.schema(t), where: r.frozen_listing_id == ^listing_id),
                set: [user_id: owner_id]
              )

        shares = from(s in Share, where: s.catalog_listing_id == ^listing_id, select: s.id)
        Repo.update_all(from(g in Grant, where: g.share_id in subquery(shares)), set: [owner_id: owner_id])
        Repo.update_all(from(s in Share, where: s.catalog_listing_id == ^listing_id), set: [owner_id: owner_id])
        :ok
    end
  end

  def move_listing(_type, _id, _owner_id), do: :ok

  # Ends every subscription with `reason`, then deletes the mirror and the listing.
  defp end_listing(%Listing{} = listing, reason) do
    :ok = Sharing.revoke_all(listing.item_type, listing.mirror_id, reason)

    {:ok, files} =
      Repo.transact(fn ->
        rows = Enum.group_by(mirror_rows(listing.id), &elem(elem(&1, 0), 0), &elem(&1, 1))
        files = delete_rows(rows)
        Repo.delete_all(from(l in Listing, where: l.id == ^listing.id))
        {:ok, files}
      end)

    Attachments.delete_orphaned(files)
  end

  ## Moderation

  @doc "Features or unfeatures `listing` (`\"catalog.feature\"`)."
  @spec feature(Scope.t(), Listing.t(), boolean()) :: {:ok, Listing.t()} | {:error, :unauthorized}
  def feature(scope, %Listing{} = listing, featured?) when is_boolean(featured?) do
    with :ok <- Scope.authorize(scope, "catalog.feature"),
         do: {:ok, listing |> Ecto.Changeset.change(featured: featured?) |> Repo.update!()}
  end

  defp owner?(%Scope{user: %User{id: uid}}, %Listing{owner_id: uid}), do: true
  defp owner?(_scope, _listing), do: false

  defp moderator?(%Scope{} = scope), do: Scope.can?(scope, "moderation.content.view")
  defp moderator?(_scope), do: false
end
