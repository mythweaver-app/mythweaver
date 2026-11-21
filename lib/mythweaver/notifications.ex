defmodule Mythweaver.Notifications do
  @moduledoc """
  Tells a user something happened, through every channel in `@channels`
  (`Mythweaver.Notifications.Channel`): in-app (`Channels.InApp`, a browser popup and a sound in the
  user's open tabs) and Web Push (`Channels.Push`, to the devices the user enabled, when no app tab
  has focus; only while `WebPush.configured?/0`).

  What notifies is the caller's call; whether and how is the user's, from the `notifications.*`
  settings: `notifications.muted` silences everything, and each kind has its own channel toggles.
  The kinds are a finished reply (`reply_finished/5`, from `Mythweaver.Generation.Server`) and a
  memory draft parked for review (`memory_review/1`, from `Mythweaver.Jobs.finish/3`).

  ## Inbox

  `notify/2` also stores each notification (`Notification`) in the user's inbox (`inbox/1`), muted
  or not: the settings only decide popups, sounds and push. A reply is stored only while its chat is
  unread and is deleted when the chat is read (`clear_chat_replies/2`, from `Messages.mark_read/2`)
  or after 7 days. Error toasts are kept for 24 hours (`record_error/2`, from
  `MythweaverWeb.NotificationsHook`).

  Items that ask something of the user (`needs_action?/1`) stay until it is done or the user
  dismisses that one item; "Clear all" (`dismiss_all/1`) leaves them. A memory review lasts until
  its job leaves `:review` (`clear_review/1`, from `Mythweaver.Jobs`), a ready consolidation tier
  (`consolidation_ready/4`, from `Mythweaver.Memory.Consolidation.check_ready/2`) until the tier is
  no longer ready. A share invite (`share_invite/3`, from `Mythweaver.Sharing`) lasts until it is
  accepted or declined (`clear_share/1`) or the share goes, a chat invite (`chat_invite/3`, from
  `Mythweaver.Chats.invite/4`) until it is answered (`clear_chat_invite/1`) or the member row goes;
  a share's end (`share_ended/3`) and a hand-off to the user (`handed_off/4`) are kept for 7 days.
  Rows also go with their chat, message, job, book, share or chat member. Every change reaches the
  user's open tabs as `{Notifications, :inbox_changed}`
  on `topic/1`.

  A push device is one browser's subscription (`PushSubscription`), at most 10 per user: enabling
  another drops the least recently used.
  """

  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Query

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.Attachments
  alias Mythweaver.Characters
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Chats.Member
  alias Mythweaver.Jobs
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Locale
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Notifications.Channels
  alias Mythweaver.Notifications.Notification
  alias Mythweaver.Notifications.PushSubscription
  alias Mythweaver.Notifications.Text
  alias Mythweaver.Notifications.WebPush
  alias Mythweaver.Repo
  alias Mythweaver.Settings
  alias Mythweaver.Sharing
  alias Mythweaver.Sharing.Items
  alias Mythweaver.Sharing.Share

  @reply_kinds [:new_message, :regenerate, :continue]
  @kinds @reply_kinds ++ [:memory_review]
  @action_kinds [:memory_review, :consolidation_ready, :share_invite, :chat_invite]
  @channels [Channels.InApp, Channels.Push]
  @excerpt_length 160
  @max_devices 10
  @reply_ttl_days 7
  @share_ended_ttl_days 7
  @error_ttl_hours 24
  @inbox_limit 50

  @type kind_preferences :: %{popup: boolean(), sound: boolean(), push: boolean()}
  @type preferences :: %{
          muted: boolean(),
          push_preview: boolean(),
          new_message: kind_preferences(),
          regenerate: kind_preferences(),
          continue: kind_preferences(),
          memory_review: kind_preferences()
        }

  @doc "One user's notification topic."
  def topic(user_id), do: "user:#{user_id}:notifications"

  @doc "Subscribes the caller to the scope user's `topic/1`."
  def subscribe(%Scope{user: %{id: user_id}}), do: Phoenix.PubSub.subscribe(Mythweaver.PubSub, topic(user_id))

  @doc "The scope user's notification settings, in one query."
  @spec preferences(Scope.t()) :: preferences()
  def preferences(%Scope{} = scope) do
    keys =
      ["notifications.muted", "notifications.push_preview"] ++
        for(kind <- @kinds, channel <- ~w(popup sound push), do: key(kind, channel))

    values = Settings.get_many(scope, keys)

    Map.new(@kinds, fn kind ->
      {kind, %{popup: values[key(kind, "popup")], sound: values[key(kind, "sound")], push: values[key(kind, "push")]}}
    end)
    |> Map.merge(%{muted: values["notifications.muted"], push_preview: values["notifications.push_preview"]})
  end

  defp key(kind, channel), do: "notifications.#{kind}.#{channel}"

  @doc """
  Where opening `notification` goes: the chat, a memory review's Reviews tab or a ready tier's
  Consolidate tab. An error toast, a share item and a chat invite go nowhere (an invite is answered
  in place).
  """
  @spec path(Notification.t()) :: String.t() | nil
  def path(%Notification{kind: :memory_review, chat_id: id}), do: "/chats/#{id}/memory?tab=reviews"
  def path(%Notification{kind: :consolidation_ready, chat_id: id}), do: "/chats/#{id}/memory?tab=consolidate"
  def path(%Notification{kind: :moderation_warning}), do: "/warnings"

  def path(%Notification{kind: kind})
      when kind in [
             :error,
             :share_invite,
             :chat_invite,
             :share_ended,
             :handed_off,
             :listing_taken_down,
             :submission_approved,
             :submission_rejected
           ], do: nil

  def path(%Notification{chat_id: id}), do: "/chats/#{id}"

  @doc "Whether `notification` asks the user to act (a review): only its own dismissal removes it."
  @spec needs_action?(Notification.t()) :: boolean()
  def needs_action?(%Notification{kind: kind}), do: kind in @action_kinds

  @doc """
  Stores `notification` in the scope user's inbox, then delivers it through every channel unless the
  scope user muted notifications.
  """
  @spec notify(Scope.t(), Notification.t()) :: :ok
  def notify(%Scope{} = scope, %Notification{} = notification) do
    :ok = store(scope, notification)
    prefs = preferences(scope)

    if !prefs.muted do
      Enum.each(@channels, & &1.deliver(scope, notification, prefs))
    end

    :ok
  end

  # A reply is stored only while its chat is unread for the recipient, by their own cursor
  # (`Chats.read_state/2`). It locks the row holding that cursor (the chat for the owner, the member
  # row for a member), ordering this against `Messages.mark_read/2`'s update of the same row: either
  # the chat reads as read here and nothing is stored, or the mark-read runs after this commit and
  # deletes the new row.
  defp store(%Scope{user: %{id: user_id}}, %Notification{kind: kind, chat_id: chat_id} = n) when kind in @reply_kinds do
    expires_at = DateTime.add(DateTime.utc_now(:second), @reply_ttl_days, :day)

    {:ok, stored?} =
      Repo.transact(fn ->
        activity = Chats.read_state(user_id, chat_id)

        if unread?(activity) do
          Repo.insert!(%{n | user_id: user_id, expires_at: expires_at})
          {:ok, true}
        else
          {:ok, false}
        end
      end)

    if stored?, do: broadcast_changed(user_id), else: :ok
  end

  defp store(%Scope{user: %{id: user_id}}, %Notification{kind: :memory_review} = n) do
    Repo.insert!(%{n | user_id: user_id, expires_at: nil})
    broadcast_changed(user_id)
  end

  defp unread?({%DateTime{}, nil}), do: true
  defp unread?({%DateTime{} = activity, %DateTime{} = read}), do: DateTime.before?(read, activity)
  defp unread?(_), do: false

  @doc "Keeps the error toast `text` in the scope user's inbox for 24 hours."
  @spec record_error(Scope.t(), String.t()) :: :ok
  def record_error(%Scope{user: %{id: user_id}}, text) when is_binary(text) do
    Repo.insert!(%Notification{
      user_id: user_id,
      kind: :error,
      title: text,
      expires_at: DateTime.add(DateTime.utc_now(:second), @error_ttl_hours, :hour)
    })

    broadcast_changed(user_id)
  end

  @doc "The scope user's unexpired inbox items, newest first, at most 50."
  @spec inbox(Scope.t()) :: [Notification.t()]
  def inbox(%Scope{user: %{id: user_id}}) do
    from(n in live_query(user_id), order_by: [desc: n.inserted_at, desc: n.id], limit: @inbox_limit)
    |> Repo.all()
  end

  @doc "How many unexpired notifications the scope user's inbox holds; error toasts do not count."
  @spec inbox_count(Scope.t()) :: non_neg_integer()
  def inbox_count(%Scope{user: %{id: user_id}}) do
    from(n in live_query(user_id), where: n.kind != :error) |> Repo.aggregate(:count)
  end

  defp live_query(user_id) do
    now = DateTime.utc_now(:second)
    from(n in Notification, where: n.user_id == ^user_id and (is_nil(n.expires_at) or n.expires_at > ^now))
  end

  @doc "Deletes one of the scope user's inbox items."
  @spec dismiss(Scope.t(), String.t()) :: :ok | {:error, :not_found}
  def dismiss(%Scope{user: %{id: user_id}}, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {1, _} <- Repo.delete_all(from(n in Notification, where: n.id == ^id and n.user_id == ^user_id)) do
      broadcast_changed(user_id)
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Empties the scope user's inbox of everything but the items that need action (`needs_action?/1`)."
  @spec dismiss_all(Scope.t()) :: :ok
  def dismiss_all(%Scope{user: %{id: user_id}}) do
    {count, _} =
      Repo.delete_all(from(n in Notification, where: n.user_id == ^user_id and n.kind not in @action_kinds))

    if count > 0, do: broadcast_changed(user_id), else: :ok
  end

  @doc "Deletes `user_id`'s reply notifications for `chat_id`: the chat was read."
  @spec clear_chat_replies(Ecto.UUID.t() | nil, Ecto.UUID.t()) :: :ok
  def clear_chat_replies(user_id, chat_id) when is_binary(user_id) do
    {count, _} =
      Repo.delete_all(
        from(n in Notification, where: n.user_id == ^user_id and n.chat_id == ^chat_id and n.kind in @reply_kinds)
      )

    if count > 0, do: broadcast_changed(user_id), else: :ok
  end

  def clear_chat_replies(_user_id, _chat_id), do: :ok

  @doc "Deletes the review notification of the memory job `job_id`: it left `:review`."
  @spec clear_review(Ecto.UUID.t()) :: :ok
  def clear_review(job_id) do
    {_, user_ids} =
      Repo.delete_all(
        from(n in Notification, where: n.job_id == ^job_id and n.kind == :memory_review, select: n.user_id)
      )

    user_ids |> Enum.uniq() |> Enum.each(&broadcast_changed/1)
  end

  @doc """
  Keeps one inbox item for each of `tiers`, the ready tiers of `book`, opening `chat`'s Consolidate
  tab, and deletes the scope user's items for the book's other tiers: those were consolidated or no
  longer have enough sources. A tier already in the inbox keeps its item. A nil `chat` (no chat of the
  user's keeps its memories in `book`) stores nothing.
  """
  @spec consolidation_ready(Scope.t(), LoreBook.t(), Chat.t() | nil, [1..6]) :: :ok
  def consolidation_ready(%Scope{user: %{id: user_id}}, %LoreBook{id: book_id} = book, chat, tiers) do
    {cleared, _} =
      Repo.delete_all(
        from(n in Notification,
          where: n.user_id == ^user_id and n.kind == :consolidation_ready and n.lore_book_id == ^book_id,
          where: n.tier not in ^tiers
        )
      )

    now = DateTime.utc_now(:second)

    rows =
      Locale.with_user_locale(user_id, fn ->
        for tier <- tiers, chat != nil do
          %{
            id: Mythweaver.Schema.generate_id(),
            user_id: user_id,
            kind: :consolidation_ready,
            chat_id: chat.id,
            lore_book_id: book_id,
            tier: tier,
            title: consolidation_title(tier, chat),
            body: Text.ready_body(tier, book.name),
            inserted_at: now
          }
        end
      end)

    {added, _} =
      Repo.insert_all(Notification, rows,
        on_conflict: :nothing,
        conflict_target: {:unsafe_fragment, "(user_id, lore_book_id, tier) WHERE kind = 'consolidation_ready'"}
      )

    if cleared + added > 0, do: broadcast_changed(user_id), else: :ok
  end

  @doc ~S|What a ready `tier` of `chat`'s memory book says: "Ready to consolidate an Arc — Chat"|
  @spec consolidation_title(1..6, Chat.t()) :: String.t()
  def consolidation_title(tier, %Chat{} = chat), do: Text.ready_title(tier, Chat.title(chat))

  @doc """
  Puts `share`'s invite to edit or use `item` in the invitee's inbox, from `inviter`. Stored only: no
  popup, sound or push.
  """
  @spec share_invite(User.t(), Share.t(), struct()) :: :ok
  def share_invite(inviter, share, item) do
    Repo.insert!(
      Locale.with_user_locale(share.user_id, fn ->
        %Notification{
          user_id: share.user_id,
          kind: :share_invite,
          share_id: share.id,
          title: Text.invite_title(share.item_type, invite_access(share), inviter, item.name)
        }
      end)
    )

    broadcast_changed(share.user_id)
  end

  defp invite_access(%Share{role: :subscriber, visibility: :readable}), do: :use_read_only
  defp invite_access(%Share{role: :subscriber}), do: :use
  defp invite_access(%Share{}), do: :edit

  defp share_access(%Share{role: :subscriber}), do: :use
  defp share_access(%Share{}), do: :edit

  @doc "Deletes the invite item of `share_id`: it was answered."
  @spec clear_share(Ecto.UUID.t()) :: :ok
  def clear_share(share_id) do
    {_, user_ids} =
      Repo.delete_all(
        from(n in Notification, where: n.share_id == ^share_id and n.kind == :share_invite, select: n.user_id)
      )

    user_ids |> Enum.uniq() |> Enum.each(&broadcast_changed/1)
  end

  @doc """
  Puts `member`'s invite into `chat` in the invitee's inbox, from `inviter`. Stored only: no popup,
  sound or push.
  """
  @spec chat_invite(User.t(), Member.t(), Chat.t()) :: :ok
  def chat_invite(%User{} = inviter, member, %Chat{} = chat) do
    Repo.insert!(
      Locale.with_user_locale(member.user_id, fn ->
        %Notification{
          user_id: member.user_id,
          kind: :chat_invite,
          chat_member_id: member.id,
          title: chat_invite_title(member.role, inviter, Chat.title(chat))
        }
      end)
    )

    broadcast_changed(member.user_id)
  end

  defp chat_invite_title(:editor, inviter, chat_title) do
    gettext_comment("Notification title in the inbox when someone invites the user to edit a chat with them.")

    dgettext("notifications", "%{inviter_name} (@%{inviter_handle}) invited you to edit the chat “%{chat_title}”",
      inviter_name: User.display_name(inviter),
      inviter_handle: inviter.handle,
      chat_title: chat_title
    )
  end

  defp chat_invite_title(_role, inviter, chat_title) do
    gettext_comment("Notification title in the inbox when someone invites the user to join a chat.")

    dgettext("notifications", "%{inviter_name} (@%{inviter_handle}) invited you to join the chat “%{chat_title}”",
      inviter_name: User.display_name(inviter),
      inviter_handle: inviter.handle,
      chat_title: chat_title
    )
  end

  @doc "Deletes the invite item of the chat member `member_id`: it was answered or withdrawn."
  @spec clear_chat_invite(Ecto.UUID.t()) :: :ok
  def clear_chat_invite(member_id) do
    {_, user_ids} =
      Repo.delete_all(
        from(n in Notification, where: n.chat_member_id == ^member_id and n.kind == :chat_invite, select: n.user_id)
      )

    user_ids |> Enum.uniq() |> Enum.each(&broadcast_changed/1)
  end

  @doc """
  Tells `share`'s user they can no longer edit or use `item`, for 7 days. Stored only. `reason`:
  `:removed`, `:left`, `:deleted`, `:account_deleted`, `:moved_to_site`, `:unpublished` or
  `:taken_down` (a catalog subscription's listing went).
  """
  @spec share_ended(Share.t(), struct(), Sharing.reason()) :: :ok
  def share_ended(share, item, reason) do
    Repo.insert!(
      Locale.with_user_locale(share.user_id, fn ->
        %Notification{
          user_id: share.user_id,
          kind: :share_ended,
          title: Text.ended_title(share.item_type, share_access(share), item.name),
          body: share_ended_body(reason),
          expires_at: DateTime.add(DateTime.utc_now(:second), @share_ended_ttl_days, :day)
        }
      end)
    )

    broadcast_changed(share.user_id)
  end

  # Notification bodies under “You can no longer use/edit …”: why the user lost access.
  defp share_ended_body(:removed) do
    gettext_comment("Notification body: the user lost access to a shared item because its owner removed them.")

    dpgettext(
      "notifications",
      "status: notification body, the owner of a shared item removed the user from it",
      "The owner removed you."
    )
  end

  defp share_ended_body(:left) do
    gettext_comment("Notification body: the user lost access to a shared item because they left the share.")
    dpgettext("notifications", "status: notification body, the user left a shared item", "You left it.")
  end

  defp share_ended_body(:deleted) do
    gettext_comment("Notification body: the user lost access to a shared item because it was deleted.")

    dpgettext(
      "notifications",
      "status: notification body, a shared item the user had access to was deleted",
      "It was deleted."
    )
  end

  defp share_ended_body(:account_deleted) do
    gettext_comment("Notification body: the user lost access to a shared item because its owner's account was deleted.")
    dgettext("notifications", "Its owner's account was deleted.")
  end

  defp share_ended_body(:moved_to_site) do
    gettext_comment("Notification body: the user lost access to a shared item because it became a site item.")
    dgettext("notifications", "It moved to the site.")
  end

  defp share_ended_body(:unpublished) do
    gettext_comment("Notification body: the user lost access to a catalog item because it was unpublished.")

    dpgettext(
      "notifications",
      "status: notification body, a catalog item the user had access to was unpublished",
      "It was unpublished."
    )
  end

  defp share_ended_body(:taken_down) do
    gettext_comment("Notification body: the user lost access to a catalog item because a moderator took it down.")
    dgettext("notifications", "It was removed by a moderator.")
  end

  @doc """
  Tells `user_id` a moderator took down their catalog listing `title` (`Mythweaver.Catalog.takedown/3`)
  for `reason`. Kept 7 days, stored only.
  """
  @spec listing_taken_down(Ecto.UUID.t(), String.t(), String.t()) :: :ok
  def listing_taken_down(user_id, title, reason) do
    Repo.insert!(
      Locale.with_user_locale(user_id, fn ->
        gettext_comment(
          "Notification title in the inbox when a moderator takes down the user's catalog listing; the body is the moderator's reason."
        )

        %Notification{
          user_id: user_id,
          kind: :listing_taken_down,
          title:
            dgettext("notifications", "Your catalog listing “%{listing_title}” was taken down", listing_title: title),
          body: reason,
          expires_at: DateTime.add(DateTime.utc_now(:second), @share_ended_ttl_days, :day)
        }
      end)
    )

    broadcast_changed(user_id)
  end

  @doc """
  Tells `user_id` their content `title`, held for review (`Mythweaver.Moderation.Holds`), was approved
  and saved. Kept 7 days, stored only.
  """
  @spec submission_approved(Ecto.UUID.t(), String.t()) :: :ok
  def submission_approved(user_id, title) do
    Repo.insert!(
      Locale.with_user_locale(user_id, fn ->
        %Notification{
          user_id: user_id,
          kind: :submission_approved,
          title: approved_title(title),
          body: approved_body(),
          expires_at: DateTime.add(DateTime.utc_now(:second), @share_ended_ttl_days, :day)
        }
      end)
    )

    broadcast_changed(user_id)
  end

  defp approved_title(title) do
    gettext_comment("Notification title in the inbox when content held for moderator review was approved.")

    dpgettext(
      "notifications",
      "notification title: content held for moderator review was approved",
      "“%{content_title}” was approved",
      content_title: title
    )
  end

  defp approved_body do
    gettext_comment("Notification body under “… was approved”.")

    dpgettext(
      "notifications",
      "status: notification body, approved content held for review is now saved",
      "It is saved now."
    )
  end

  @doc """
  Tells `user_id` their content `title`, held for review, was not approved, for `reason`. Kept 7
  days, stored only.
  """
  @spec submission_rejected(Ecto.UUID.t(), String.t(), String.t()) :: :ok
  def submission_rejected(user_id, title, reason) do
    Repo.insert!(
      Locale.with_user_locale(user_id, fn ->
        gettext_comment(
          "Notification title in the inbox when content held for moderator review was rejected; the body is the moderator's reason."
        )

        %Notification{
          user_id: user_id,
          kind: :submission_rejected,
          title:
            dpgettext(
              "notifications",
              "notification title: content held for moderator review was not approved",
              "“%{content_title}” was not approved",
              content_title: title
            ),
          body: reason,
          expires_at: DateTime.add(DateTime.utc_now(:second), @share_ended_ttl_days, :day)
        }
      end)
    )

    broadcast_changed(user_id)
  end

  @doc """
  Tells `user_id` a moderator warned them for `reason` (`Mythweaver.Moderation.Sanctions.warn/4`).
  Kept 7 days, stored only; the warning page is where it is acknowledged.
  """
  @spec moderation_warning(Ecto.UUID.t(), String.t()) :: :ok
  def moderation_warning(user_id, reason) do
    Repo.insert!(
      Locale.with_user_locale(user_id, fn ->
        gettext_comment(
          "Notification title in the inbox when a moderator warns the user; the body is the moderator's reason."
        )

        %Notification{
          user_id: user_id,
          kind: :moderation_warning,
          title:
            dpgettext("notifications", "notification title: a moderator warned the user", "A moderator warned you"),
          body: reason,
          expires_at: DateTime.add(DateTime.utc_now(:second), @share_ended_ttl_days, :day)
        }
      end)
    )

    broadcast_changed(user_id)
  end

  @doc """
  Tells `user_id` that `from` gave them `item` of `type` (`Mythweaver.Sharing.hand_off/3`): they own
  it now. Kept 7 days, stored only.
  """
  @spec handed_off(Ecto.UUID.t(), User.t(), Items.root_type(), struct()) :: :ok
  def handed_off(user_id, %User{} = from, type, item) do
    Repo.insert!(
      Locale.with_user_locale(user_id, fn ->
        %Notification{
          user_id: user_id,
          kind: :handed_off,
          title: Text.owned_title(type, item.name),
          body: handed_off_body(from),
          expires_at: DateTime.add(DateTime.utc_now(:second), @share_ended_ttl_days, :day)
        }
      end)
    )

    broadcast_changed(user_id)
  end

  defp handed_off_body(from) do
    gettext_comment("Notification body under “You now own …”: who handed the item over.")

    dgettext("notifications", "%{giver_name} (@%{giver_handle}) gave it to you.",
      giver_name: User.display_name(from),
      giver_handle: from.handle
    )
  end

  @doc "Tells `user_id`'s open tabs their inbox changed: `{Notifications, :inbox_changed}` on `topic/1`."
  @spec broadcast_changed(Ecto.UUID.t() | nil) :: :ok
  def broadcast_changed(user_id) when is_binary(user_id),
    do: Phoenix.PubSub.broadcast(Mythweaver.PubSub, topic(user_id), {__MODULE__, :inbox_changed})

  def broadcast_changed(nil), do: :ok

  @doc "Deletes expired inbox items. Reads already skip them; this only frees the rows."
  @spec prune() :: :ok
  def prune do
    now = DateTime.utc_now(:second)
    Repo.delete_all(from(n in Notification, where: n.expires_at <= ^now))
    :ok
  end

  @doc """
  The notification kind of a reply mode, the conductor's (`{tag, message_id}`) or the server's
  (`{tag, %Message{}}`) alike.
  """
  @spec reply_kind(:new | {:swipe | :refine | :continue, term()}) :: Notification.kind()
  def reply_kind(:new), do: :new_message
  def reply_kind({:swipe, _}), do: :regenerate
  def reply_kind({:refine, _}), do: :regenerate
  def reply_kind({:continue, _}), do: :continue

  @doc """
  Notifies the scope user that `character`'s reply `body` in `chat` finished, with the character's
  avatar as its picture.
  """
  @spec reply_finished(Scope.t(), Notification.kind(), Chat.t(), Character.t(), map()) :: :ok
  def reply_finished(%Scope{} = scope, kind, %Chat{} = chat, %Character{} = character, body)
      when kind in @reply_kinds do
    notification =
      Locale.with_user_locale(scope, fn ->
        %Notification{
          id: Mythweaver.Schema.generate_id(),
          kind: kind,
          chat_id: chat.id,
          message_id: body.message_id,
          title: reply_title(kind, character.name, Chat.title(chat)),
          body: excerpt(body.content),
          icon: Attachments.url(Characters.preload_avatar(scope, character).avatar, :avatar)
        }
      end)

    notify(scope, notification)
  end

  @doc """
  Notifies `job`'s initiator that its memory draft awaits review. A job with no initiator or chat,
  or whose chat is gone or no longer theirs, notifies no one.
  """
  @spec memory_review(Job.t()) :: :ok
  def memory_review(%Job{chat_id: chat_id} = job) when is_binary(chat_id) do
    with %Scope{} = scope <- Jobs.initiator_scope(job),
         %Chat{} = chat <- Chats.get_chat(scope, chat_id) do
      notification =
        Locale.with_user_locale(scope, fn ->
          %Notification{
            id: Mythweaver.Schema.generate_id(),
            kind: :memory_review,
            chat_id: chat.id,
            job_id: job.id,
            title: review_title(Chat.title(chat)),
            body: review_body(job.label)
          }
        end)

      notify(scope, notification)
    else
      _ -> :ok
    end
  end

  def memory_review(%Job{}), do: :ok

  defp review_title(chat_title) do
    gettext_comment(
      "Notification title (popup, inbox, push) when a memory draft of a chat waits for the user's review."
    )

    dgettext("notifications", "Memory to review — %{chat_title}", chat_title: chat_title)
  end

  defp review_body(nil) do
    gettext_comment("Notification body under “Memory to review”, when the draft has no name.")
    dgettext("notifications", "A memory draft is waiting for your review.")
  end

  defp review_body(job_label) do
    gettext_comment("Notification body under “Memory to review”; the placeholder is the memory draft's name.")
    dgettext("notifications", "%{draft_name} is waiting for your review.", draft_name: job_label)
  end

  @doc """
  Saves the scope user's push device: `subscription` is the browser's `PushSubscription.toJSON()`
  (`"endpoint"`, `"keys" => %{"p256dh", "auth"}`), `label` names the device. An endpoint already
  saved, by anyone, is updated and becomes this user's: that browser now signs in as them. Then only
  the user's 10 most recently used devices are kept.
  """
  @spec subscribe_device(Scope.t(), map(), String.t()) :: {:ok, PushSubscription.t()} | {:error, Ecto.Changeset.t()}
  def subscribe_device(%Scope{user: %{id: user_id}}, subscription, label) do
    keys = if is_map(subscription["keys"]), do: subscription["keys"], else: %{}

    changeset =
      PushSubscription.changeset(%PushSubscription{user_id: user_id}, %{
        endpoint: subscription["endpoint"],
        p256dh: keys["p256dh"],
        auth: keys["auth"],
        label: label
      })

    Repo.transact(fn ->
      with {:ok, device} <-
             Repo.insert(changeset,
               on_conflict: {:replace, [:user_id, :p256dh, :auth, :label, :last_failure, :updated_at]},
               conflict_target: :endpoint,
               returning: true
             ) do
        keep = from(d in devices_query(user_id), limit: @max_devices, select: d.id)
        Repo.delete_all(from(d in PushSubscription, where: d.user_id == ^user_id and d.id not in subquery(keep)))
        {:ok, device}
      end
    end)
  end

  @doc "The scope user's push devices, most recently used first."
  @spec list_devices(Scope.t()) :: [PushSubscription.t()]
  def list_devices(%Scope{user: %{id: user_id}}), do: Repo.all(devices_query(user_id))

  # Recency: the last successful push, or the last (re)subscribe, whichever is later.
  defp devices_query(user_id) do
    from(d in PushSubscription,
      where: d.user_id == ^user_id,
      order_by: [desc: fragment("greatest(?, ?)", d.last_success_at, d.updated_at), desc: d.id]
    )
  end

  @doc "Removes one of the scope user's push devices."
  @spec remove_device(Scope.t(), Ecto.UUID.t()) :: :ok | {:error, :not_found}
  def remove_device(%Scope{user: %{id: user_id}}, id) do
    case Repo.delete_all(from(d in PushSubscription, where: d.id == ^id and d.user_id == ^user_id)) do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  end

  @doc "Sends a test push to one of the scope user's devices, now, and records the result."
  @spec test_device(Scope.t(), Ecto.UUID.t()) :: :ok | :gone | {:error, :not_found | term()}
  def test_device(%Scope{user: %{id: user_id}}, id) do
    case Repo.one(from(d in PushSubscription, where: d.id == ^id and d.user_id == ^user_id)) do
      nil ->
        {:error, :not_found}

      device ->
        payload =
          Locale.with_user_locale(user_id, fn ->
            gettext_comment("Push notification body sent when the user taps “test” on one of their push devices.")

            %{
              id: Mythweaver.Schema.generate_id(),
              title: Mythweaver.Branding.name(),
              body: dgettext("notifications", "Push notifications work on %{device_name}.", device_name: device.label),
              icon: "/images/icons/icon-192.png",
              path: "/settings"
            }
          end)

        push_to_device(device, payload, ttl: 60, urgency: :high)
    end
  end

  @doc """
  Pushes `payload` to `device` (`WebPush.push/3`) and records the result on it: a success stamps
  `last_success_at`, a failure sets `last_failure`, and a device the push service no longer knows is
  deleted. `Channels.Push` and `test_device/2` send through it.
  """
  @spec push_to_device(PushSubscription.t(), map(), keyword()) :: :ok | :gone | {:error, term()}
  def push_to_device(%PushSubscription{id: id} = device, payload, opts) do
    device_query = from(d in PushSubscription, where: d.id == ^id)
    result = WebPush.push(device, payload, opts)

    case result do
      :ok -> Repo.update_all(device_query, set: [last_success_at: DateTime.utc_now(:second), last_failure: nil])
      :gone -> Repo.delete_all(device_query)
      {:error, reason} -> Repo.update_all(device_query, set: [last_failure: failure(reason)])
    end

    result
  end

  defp failure(status) when is_integer(status), do: "The push service answered #{status}."
  defp failure(%{__exception__: true} = error), do: String.slice(Exception.message(error), 0, 255)
  defp failure(reason), do: String.slice(inspect(reason), 0, 255)

  defp reply_title(:new_message, character_name, chat_title) do
    gettext_comment("Notification title (popup, inbox, push) when a character's reply in a chat finished.")

    dpgettext(
      "notifications",
      "notification title: a character's reply in a chat finished",
      "%{character_name} replied — %{chat_title}",
      character_name: character_name,
      chat_title: chat_title
    )
  end

  defp reply_title(:regenerate, character_name, chat_title) do
    gettext_comment(
      "Notification title (popup, inbox, push) when a regenerated reply (a swipe) of a character finished."
    )

    dgettext("notifications", "New swipe from %{character_name} — %{chat_title}",
      character_name: character_name,
      chat_title: chat_title
    )
  end

  defp reply_title(:continue, character_name, chat_title) do
    gettext_comment("Notification title (popup, inbox, push) when a character finished continuing their reply.")

    dpgettext(
      "notifications",
      "notification title: a character finished continuing their reply in a chat",
      "%{character_name} continued — %{chat_title}",
      character_name: character_name,
      chat_title: chat_title
    )
  end

  defp excerpt(content) do
    text = (content || "") |> String.replace(~r/\s+/u, " ") |> String.trim()

    cond do
      text == "" ->
        gettext_comment("Notification body when a finished reply is empty.")
        dgettext("notifications", "The reply has no text.")

      String.length(text) > @excerpt_length ->
        String.slice(text, 0, @excerpt_length) <> "…"

      true ->
        text
    end
  end
end
