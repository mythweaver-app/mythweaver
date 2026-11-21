defmodule Mythweaver.Chats do
  @moduledoc "The Chats context."

  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Query, warn: false

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.AI
  alias Mythweaver.AI.Model
  alias Mythweaver.Changes
  alias Mythweaver.Characters
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats.CharacterLock
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Chats.Member
  alias Mythweaver.Chats.Participant
  alias Mythweaver.Expressions.Outfit
  alias Mythweaver.Lore
  alias Mythweaver.Messages.Message
  alias Mythweaver.Moderation.Gate
  alias Mythweaver.Notifications
  alias Mythweaver.Ownership
  alias Mythweaver.Permissions.Quota
  alias Mythweaver.Prompts
  alias Mythweaver.Repo

  @doc """
  The chat-list topic of one user: `{:chat_created, chat_id}`, `{:chat_updated, chat_id}` (settings,
  participants, player, mute, order, members) and `{:chat_deleted, chat_id}` of their own chats and
  of the chats they are an accepted member of (`audience/1`); a member who leaves or is removed
  hears `{:chat_deleted, chat_id}`. Nobody else hears about a chat, and an unowned chat's events
  reach only its members.
  """
  def topic(user_id), do: "user:#{user_id}:chats"

  @doc "Subscribes the caller to `topic/1` for the scope's user."
  def subscribe(%Scope{user: %User{id: user_id}}), do: Phoenix.PubSub.subscribe(Mythweaver.PubSub, topic(user_id))

  @doc "The scope's own chats of every kind. Nobody, admins included, lists another user's chats."
  @spec list_chats(Scope.t()) :: [Chat.t()]
  def list_chats(%Scope{user: %User{id: user_id}}) do
    Repo.all(
      from(c in Chat,
        where: c.user_id == ^user_id,
        order_by: [asc_nulls_first: c.name, asc: c.id],
        preload: ^chat_preloads()
      )
    )
  end

  def list_chats(%Scope{}), do: []

  @doc """
  The scope's own chats of one kind: role-play chats by name, assistant threads most recently
  active first.
  """
  @spec list_chats(Scope.t(), :roleplay | :assistant) :: [Chat.t()]
  def list_chats(%Scope{user: %User{id: user_id}}, kind) when kind in [:roleplay, :assistant] do
    order =
      case kind do
        :roleplay -> [asc_nulls_first: dynamic([c], c.name), asc: dynamic([c], c.id)]
        :assistant -> [desc_nulls_last: dynamic([c], c.last_activity_at), desc: dynamic([c], c.id)]
      end

    Repo.all(
      from(c in Chat,
        where: c.user_id == ^user_id and c.kind == ^kind,
        order_by: ^order,
        preload: ^chat_preloads()
      )
    )
  end

  def list_chats(%Scope{}, _kind), do: []

  @doc "`{title, id}` select options for the scope's own role-play chats."
  def chat_options(%Scope{} = scope), do: for(chat <- list_chats(scope, :roleplay), do: {Chat.title(chat), chat.id})

  @doc """
  The chats the scope's user is an accepted member of (`Member`), by name, each with its owner
  (`:user`) loaded. Their own chats are `list_chats/1`'s.
  """
  @spec list_member_chats(Scope.t()) :: [Chat.t()]
  def list_member_chats(%Scope{user: %User{id: user_id}}) do
    Repo.all(
      from(c in Chat,
        join: m in Member,
        on: m.chat_id == c.id,
        where: m.user_id == ^user_id and m.status == :accepted,
        order_by: [asc_nulls_first: c.name, asc: c.id],
        preload: ^[:user | chat_preloads()]
      )
    )
  end

  def list_member_chats(%Scope{}), do: []

  @doc """
  The chat's pending and accepted members in invite order, each with `:user` loaded; `[]` unless
  the scope may `:manage` the chat.
  """
  @spec list_members(Scope.t(), Chat.t()) :: [Member.t()]
  def list_members(%Scope{} = scope, %Chat{id: chat_id} = chat) do
    if authorize(scope, chat, :manage) == :ok do
      Repo.all(
        from(m in Member,
          where: m.chat_id == ^chat_id and m.status != :declined,
          order_by: [asc: m.inserted_at, asc: m.id],
          preload: :user
        )
      )
    else
      []
    end
  end

  @doc """
  Invites the account with `handle` into the role-play `chat` as `role` (`:editor` or `:guest`).
  Needs `:manage` on the chat and `"chats.invite"`; a chat editor may invite guests only. Counts
  toward `"quota.pending_invites"`. A declined member is asked again; the invitee finds the invite
  in their inbox (`Notifications.chat_invite/3`). `model_source` (`Member`) is whose models the
  member's replies and captions spend; only the owner sets it, and an editor's invite always stores
  `:owner`.
  """
  @spec invite(Scope.t(), Chat.t(), String.t(), :editor | :guest, :owner | :own) ::
          {:ok, Member.t()}
          | {:error, :unauthorized | :unknown_handle | :self | :already_member | :quota_exceeded}
  def invite(scope, chat, handle, role, model_source \\ :owner)

  def invite(
        %Scope{user: %User{id: uid} = inviter} = scope,
        %Chat{kind: :roleplay, user_id: owner_id} = chat,
        handle,
        role,
        model_source
      )
      when role in [:editor, :guest] and model_source in [:owner, :own] and is_binary(owner_id) and is_binary(handle) do
    inviter_role = role(scope, chat)

    allowed? =
      Scope.can?(scope, "chats.invite") and (inviter_role == :owner or (inviter_role == :editor and role == :guest))

    if allowed? do
      case Accounts.get_user_by_handle(handle) do
        nil ->
          {:error, :unknown_handle}

        %User{id: ^uid} ->
          {:error, :self}

        %User{id: ^owner_id} ->
          {:error, :already_member}

        invitee ->
          do_invite(scope, inviter, chat, invitee, role, if(inviter_role == :owner, do: model_source, else: :owner))
      end
    else
      {:error, :unauthorized}
    end
  end

  def invite(_scope, _chat, _handle, _role, _model_source), do: {:error, :unauthorized}

  defp do_invite(scope, inviter, chat, invitee, role, model_source) do
    existing = Repo.get_by(Member, chat_id: chat.id, user_id: invitee.id)

    with :ok <- if(existing && existing.status != :declined, do: {:error, :already_member}, else: :ok),
         :ok <- Quota.check_pending_invites(scope) do
      member =
        case existing do
          nil ->
            Repo.insert!(%Member{
              chat_id: chat.id,
              user_id: invitee.id,
              invited_by_id: inviter.id,
              role: role,
              model_source: model_source
            })

          declined ->
            declined
            |> Ecto.Changeset.change(
              status: :pending,
              invited_by_id: inviter.id,
              accepted_at: nil,
              role: role,
              model_source: model_source,
              ai_model_id: nil
            )
            |> Repo.update!()
        end

      :ok = Notifications.chat_invite(inviter, member, chat)
      broadcast({:ok, member}, :chat_updated, chat)
    end
  end

  @doc "Accepts the scope user's pending chat invite `member_id`: the chat joins their `list_member_chats/1`."
  @spec accept_invite(Scope.t(), String.t()) :: {:ok, Member.t()} | {:error, :not_found}
  def accept_invite(%Scope{} = scope, member_id) do
    with {:ok, member} <- pending_for(scope, member_id) do
      member =
        member
        |> Ecto.Changeset.change(status: :accepted, accepted_at: DateTime.utc_now(:second))
        |> Repo.update!()

      :ok = Notifications.clear_chat_invite(member.id)
      broadcast({:ok, member}, :chat_updated, member.chat_id)
    end
  end

  @doc "Declines the scope user's pending chat invite `member_id`; they may be invited again."
  @spec decline_invite(Scope.t(), String.t()) :: {:ok, Member.t()} | {:error, :not_found}
  def decline_invite(%Scope{} = scope, member_id) do
    with {:ok, member} <- pending_for(scope, member_id) do
      member = member |> Ecto.Changeset.change(status: :declined) |> Repo.update!()
      :ok = Notifications.clear_chat_invite(member.id)
      broadcast({:ok, member}, :chat_updated, member.chat_id)
    end
  end

  defp pending_for(%Scope{user: %User{id: uid}}, member_id) do
    with {:ok, id} <- Ecto.UUID.cast(member_id),
         %Member{} = member <-
           Repo.one(from(m in Member, where: m.id == ^id and m.user_id == ^uid and m.status == :pending)) do
      {:ok, member}
    else
      _ -> {:error, :not_found}
    end
  end

  defp pending_for(_scope, _member_id), do: {:error, :not_found}

  @doc """
  Removes the member `member_id` (pending or accepted) from its chat (`end_membership/2`). Needs
  `:manage`; a chat editor may remove guests only, never another editor (nor the owner, who is no
  member).
  """
  @spec remove_member(Scope.t(), String.t()) :: {:ok, Member.t()} | {:error, :not_found | :unauthorized}
  def remove_member(%Scope{} = scope, member_id) do
    with {:ok, id} <- Ecto.UUID.cast(member_id),
         %Member{} = member <- Repo.one(from(m in Member, where: m.id == ^id and m.status != :declined, preload: :chat)) do
      remover = role(scope, member.chat)

      if remover == :owner or (remover == :editor and member.role == :guest),
        do: end_membership(member, member.chat),
        else: {:error, :unauthorized}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "The scope user leaves `chat`, as an accepted or pending member (`end_membership/2`)."
  @spec leave(Scope.t(), Chat.t() | Ecto.UUID.t()) :: {:ok, Member.t()} | {:error, :not_found}
  def leave(%Scope{user: %User{id: uid}}, %Chat{id: chat_id} = chat) do
    case Repo.one(from(m in Member, where: m.chat_id == ^chat_id and m.user_id == ^uid and m.status != :declined)) do
      nil -> {:error, :not_found}
      member -> end_membership(member, chat)
    end
  end

  def leave(%Scope{} = scope, chat_id) when is_binary(chat_id) do
    case Repo.get(Chat, chat_id) do
      nil -> {:error, :not_found}
      chat -> leave(scope, chat)
    end
  end

  def leave(_scope, _chat), do: {:error, :not_found}

  # The member row goes with their lock, and the characters they brought leave the chat
  # (`detach_characters/2`; their messages keep the names). The departing user's lists drop the
  # chat (`:chat_deleted`), everyone else's refresh it.
  defp end_membership(%Member{user_id: user_id} = member, %Chat{id: chat_id} = chat) do
    listeners = audience(chat_id, chat.user_id) -- [user_id]

    brought =
      Repo.all(
        from(ch in Character,
          join: p in Participant,
          on: p.character_id == ch.id,
          where: p.chat_id == ^chat_id and p.added_by_id == ^user_id
        )
      )

    {:ok, _} =
      Repo.transaction(fn ->
        Repo.delete_all(from(l in CharacterLock, where: l.chat_id == ^chat_id and l.user_id == ^user_id))
        detach_characters(chat, brought)
        Repo.delete!(member)
      end)

    # A pending invite's inbox item went with the row (FK cascade); its inbox still has to hear.
    if member.status == :pending, do: Notifications.broadcast_changed(user_id)
    announce([user_id], :chat_deleted, chat_id)
    announce(listeners, :chat_updated, chat_id)
    {:ok, member}
  end

  @doc "System lookup, no owner check; web code uses `get_chat!/2`."
  def get_chat!(id), do: Chat |> Repo.get!(id) |> Repo.preload(chat_preloads())

  @doc "Like `get_chat!/1`, raising `Mythweaver.UnauthorizedError` unless the scope may read the chat."
  @spec get_chat!(Scope.t(), Ecto.UUID.t()) :: Chat.t()
  def get_chat!(%Scope{} = scope, id) do
    chat = get_chat!(id)
    if authorize(scope, chat, :read) == :ok, do: chat, else: raise(Mythweaver.UnauthorizedError)
  end

  @doc "System lookup, no owner check; web code resolving a client-supplied id uses `get_chat/2`."
  def get_chat(id), do: Chat |> Repo.get(id) |> Repo.preload(chat_preloads())

  @doc "The chat when the scope may read it (its owner or an accepted member), else nil."
  @spec get_chat(Scope.t(), Ecto.UUID.t()) :: Chat.t() | nil
  def get_chat(%Scope{} = scope, id) do
    chat = get_chat(id)
    if chat && authorize(scope, chat, :read) == :ok, do: chat
  end

  @doc """
  Stamps `chat` as the one its owner opened last (`last_opened_at`), for `last_opened_chat_id/1`.
  Not a settings change: no `updated_at`, no broadcast. A member opening it stamps nothing.
  """
  @spec mark_opened(Scope.t(), Chat.t()) :: :ok | {:error, :unauthorized}
  def mark_opened(%Scope{} = scope, %Chat{id: id} = chat) do
    with :ok <- authorize(scope, chat, :read) do
      if role(scope, chat) == :owner,
        do: Repo.update_all(from(c in Chat, where: c.id == ^id), set: [last_opened_at: DateTime.utc_now()])

      :ok
    end
  end

  @doc "The id of the scope's own chat opened last (`mark_opened/2`), of any kind; nil when none was."
  @spec last_opened_chat_id(Scope.t()) :: Ecto.UUID.t() | nil
  def last_opened_chat_id(%Scope{user: %User{id: user_id}}) do
    Repo.one(
      from(c in Chat,
        where: c.user_id == ^user_id and not is_nil(c.last_opened_at),
        order_by: [desc: c.last_opened_at, desc: c.id],
        limit: 1,
        select: c.id
      )
    )
  end

  def last_opened_chat_id(%Scope{}), do: nil

  @typedoc """
  What `authorize/3` checks. `:manage` covers settings, participants, prompt, lore, model, memory
  settings, injections, variables, locks and members; `:inspect` the prompt inspector, lore panel,
  memory panel, variables and jobs.
  """
  @type action ::
          :read
          | :post
          | {:edit_message, Message.t()}
          | {:delete_message, Message.t()}
          | :regenerate
          | :generate
          | :run_scripts
          | :attach
          | :manage
          | :inspect
          | :delete

  @actions [:read, :post, :regenerate, :generate, :run_scripts, :attach, :manage, :inspect, :delete]

  # The guest toggle (`Chat.guest_permissions/1`) each guest-gated action reads.
  @guest_toggles %{regenerate: "regenerate", generate: "trigger_replies", run_scripts: "run_scripts", attach: "attach"}

  @doc """
  `:ok` when the scope may take `action` on the chat, by its `role/2`: the owner may do everything,
  a chat editor everything but `:delete`, a guest `:read` and `:post`, `:regenerate`, `:generate`,
  `:run_scripts` and `:attach` while the chat's guest toggle for it is on, and
  `{:edit_message, message}` / `{:delete_message, message}` on their own messages (`author_user_id`)
  while `"edit_own"` / `"delete_own"` is on. Anyone else, admins included, gets
  `{:error, :unauthorized}`, as does a message of another chat. `nil` (no chat, i.e. global config)
  needs `site.content.manage`.
  """
  @spec authorize(Scope.t(), Chat.t() | Ecto.UUID.t() | nil, action()) :: :ok | {:error, :unauthorized}
  def authorize(%Scope{} = scope, nil, action) when action in @actions or is_tuple(action),
    do: Scope.authorize(scope, "site.content.manage")

  def authorize(%Scope{} = scope, chat_id, action) when is_binary(chat_id) do
    case Repo.get(Chat, chat_id) do
      nil -> {:error, :unauthorized}
      chat -> authorize(scope, chat, action)
    end
  end

  def authorize(%Scope{} = scope, %Chat{} = chat, action) when action in @actions or is_tuple(action) do
    if allowed?(role(scope, chat), chat, scope, action), do: :ok, else: {:error, :unauthorized}
  end

  @doc """
  `authorize/3`'s rule for a `role/2` the caller already has (a LiveView computes it once), without
  touching the database: whether `role` may take `action` on `chat` as `scope`.
  """
  @spec permits?(:owner | :editor | :guest | nil, Chat.t(), Scope.t(), action()) :: boolean()
  def permits?(role, %Chat{} = chat, %Scope{} = scope, action), do: allowed?(role, chat, scope, action) == true

  defp allowed?(nil, _chat, _scope, _action), do: false

  defp allowed?(_role, %Chat{id: chat_id}, _scope, {tag, %Message{chat_id: id}})
       when tag in [:edit_message, :delete_message] and id != chat_id, do: false

  defp allowed?(:owner, _chat, _scope, _action), do: true
  defp allowed?(:editor, _chat, _scope, action), do: action != :delete
  defp allowed?(:guest, _chat, _scope, action) when action in [:read, :post], do: true

  defp allowed?(:guest, chat, scope, {:edit_message, message}),
    do: own_message?(scope, message) and Chat.guest_permissions(chat)["edit_own"]

  defp allowed?(:guest, chat, scope, {:delete_message, message}),
    do: own_message?(scope, message) and Chat.guest_permissions(chat)["delete_own"]

  defp allowed?(:guest, chat, _scope, action) when is_map_key(@guest_toggles, action),
    do: Chat.guest_permissions(chat)[@guest_toggles[action]]

  defp allowed?(:guest, _chat, _scope, _action), do: false

  defp own_message?(%Scope{user: %User{id: uid}}, %Message{author_user_id: uid}) when is_binary(uid), do: true
  defp own_message?(_scope, _message), do: false

  @doc """
  The scope's role in the chat: `:owner`, `:editor` or `:guest` (an accepted `Member`), or nil.
  """
  @spec role(Scope.t(), Chat.t() | Ecto.UUID.t()) :: :owner | :editor | :guest | nil
  def role(%Scope{user: %User{id: uid}}, %Chat{user_id: uid}) when is_binary(uid), do: :owner

  def role(%Scope{user: %User{id: uid}}, %Chat{id: chat_id}) when is_binary(uid) and is_binary(chat_id),
    do: member_role(uid, chat_id)

  def role(%Scope{} = scope, chat_id) when is_binary(chat_id) do
    case Repo.get(Chat, chat_id) do
      nil -> nil
      chat -> role(scope, chat)
    end
  end

  def role(_scope, _chat), do: nil

  @doc """
  The scope's `role/2` in `chat` and its `member_for/2` row, read once: `{:owner, nil}` for the
  owner, `{member.role, member}` for an accepted member, `{nil, nil}` otherwise.
  """
  @spec viewer(Scope.t(), Chat.t()) :: {:owner | :editor | :guest | nil, Member.t() | nil}
  def viewer(%Scope{user: %User{id: uid}}, %Chat{user_id: uid}) when is_binary(uid), do: {:owner, nil}

  def viewer(%Scope{} = scope, %Chat{} = chat) do
    case member_for(scope, chat) do
      %Member{role: role} = member -> {role, member}
      nil -> {nil, nil}
    end
  end

  defp member_role(user_id, chat_id) do
    Repo.one(
      from(m in Member,
        where: m.chat_id == ^chat_id and m.user_id == ^user_id and m.status == :accepted,
        select: m.role
      )
    )
  end

  @doc """
  The scope a chat's AI work runs as when `scope` asks for it: the chat owner's, carrying `scope`'s
  user as `initiator_id`, so models, prompts, lore, scripts and quota are the owner's while the
  jobs stay attributed to whoever asked. `scope` itself for the owner, an unowned chat, or a gone
  owner. Authorization is the caller's.
  """
  @spec run_scope(Scope.t(), Chat.t() | Ecto.UUID.t()) :: Scope.t()
  def run_scope(%Scope{} = scope, %Chat{user_id: owner_id}), do: owner_run_scope(scope, owner_id)

  def run_scope(%Scope{} = scope, chat_id) when is_binary(chat_id), do: owner_run_scope(scope, owner_id(chat_id))

  defp owner_run_scope(scope, nil), do: scope
  defp owner_run_scope(%Scope{user: %User{id: id}} = scope, id), do: scope

  defp owner_run_scope(%Scope{} = scope, owner_id) do
    case Accounts.get_user(owner_id) do
      nil -> scope
      owner -> %{Scope.for_user(owner) | initiator_id: Scope.initiator_id(scope)}
    end
  end

  @doc """
  Whose models, keys and quota a member's reply or caption spends: `scope` itself for the chat's
  owner and for an accepted member with `model_source: :own`, else `run_scope/2`. Prompts, lore,
  scripts and memory stay `run_scope/2`'s either way. Authorization is the caller's.
  """
  @spec spend_scope(Scope.t(), Chat.t() | Ecto.UUID.t()) :: Scope.t()
  def spend_scope(%Scope{} = scope, chat), do: if(spends_own?(scope, chat), do: scope, else: run_scope(scope, chat))

  @doc "`spend_scope/2` for a caller that already holds `run_scope`, `run_scope/2` for the same `scope` and `chat`."
  @spec spend_scope(Scope.t(), Chat.t() | Ecto.UUID.t(), Scope.t()) :: Scope.t()
  def spend_scope(%Scope{} = scope, chat, %Scope{} = run_scope),
    do: if(spends_own?(scope, chat), do: scope, else: run_scope)

  @doc "Whether `scope` spends its own models in `chat`: it is the owner, or an accepted `:own` member."
  @spec spends_own?(Scope.t(), Chat.t() | Ecto.UUID.t()) :: boolean()
  def spends_own?(%Scope{user: %User{id: uid}}, %Chat{user_id: uid}) when is_binary(uid), do: true
  def spends_own?(%Scope{user: %User{id: uid}}, %Chat{id: chat_id}) when is_binary(uid), do: own_member?(uid, chat_id)

  def spends_own?(%Scope{user: %User{id: uid}}, chat_id) when is_binary(uid) and is_binary(chat_id),
    do: owner_id(chat_id) == uid or own_member?(uid, chat_id)

  def spends_own?(_scope, _chat), do: false

  defp own_member?(user_id, chat_id) do
    Repo.exists?(
      from(m in Member,
        where: m.chat_id == ^chat_id and m.user_id == ^user_id and m.status == :accepted and m.model_source == :own
      )
    )
  end

  @doc "The scope user's accepted member row in `chat`; nil for the owner and non-members."
  @spec member_for(Scope.t(), Chat.t() | Ecto.UUID.t()) :: Member.t() | nil
  def member_for(%Scope{user: %User{id: uid}}, %Chat{user_id: uid}) when is_binary(uid), do: nil
  def member_for(%Scope{} = scope, %Chat{id: chat_id}), do: member_for(scope, chat_id)

  def member_for(%Scope{user: %User{id: uid}}, chat_id) when is_binary(chat_id) do
    Repo.one(from(m in Member, where: m.chat_id == ^chat_id and m.user_id == ^uid and m.status == :accepted))
  end

  def member_for(_scope, _chat), do: nil

  @doc """
  Sets member `member_id`'s `model_source` (`Member`). Only the chat's owner may; switching to
  `:owner` also clears the member's own model pick.
  """
  @spec set_model_source(Scope.t(), String.t(), :owner | :own) ::
          {:ok, Member.t()} | {:error, :not_found | :unauthorized}
  def set_model_source(%Scope{} = scope, member_id, source) when source in [:owner, :own] do
    with {:ok, id} <- Ecto.UUID.cast(member_id),
         %Member{} = member <- Repo.one(from(m in Member, where: m.id == ^id, preload: :chat)) do
      if role(scope, member.chat) == :owner do
        changes = if source == :owner, do: [model_source: :owner, ai_model_id: nil], else: [model_source: :own]

        member
        |> Ecto.Changeset.change(changes)
        |> Repo.update()
        |> broadcast(:chat_updated, member.chat)
      else
        {:error, :unauthorized}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Sets the scope user's own model pick in `chat` (nil: their default model). Only for an accepted
  member with `model_source: :own`; the model must be one the scope may use, in a text mode. Only
  that member's own windows hear of it (`:chat_updated` on their `topic/1`): no one else's view
  shows the pick.
  """
  @spec set_member_model(Scope.t(), Chat.t(), Ecto.UUID.t() | nil) ::
          {:ok, Member.t()} | {:error, :not_found | :unauthorized | :not_available}
  def set_member_model(%Scope{} = scope, %Chat{} = chat, model_id) do
    with %Member{} = member <- member_for(scope, chat) || {:error, :not_found},
         :ok <- if(member.model_source == :own, do: :ok, else: {:error, :unauthorized}),
         :ok <- member_model_available(scope, model_id),
         {:ok, member} <- member |> Ecto.Changeset.change(ai_model_id: model_id) |> Repo.update() do
      announce([member.user_id], :chat_updated, chat.id)
      {:ok, member}
    end
  end

  defp member_model_available(_scope, nil), do: :ok

  defp member_model_available(scope, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Model{completion_mode: mode} <- AI.get_model(scope, id),
         true <- mode in Model.text_modes() do
      :ok
    else
      _ -> {:error, :not_available}
    end
  end

  @doc """
  The chat's character locks: each held character's id with the users playing it, sorted by
  handle.
  """
  @spec locks(Chat.t() | Ecto.UUID.t()) :: %{Ecto.UUID.t() => [User.t()]}
  def locks(%Chat{id: chat_id}), do: locks(chat_id)

  def locks(chat_id) when is_binary(chat_id) do
    from(l in CharacterLock,
      join: u in assoc(l, :user),
      where: l.chat_id == ^chat_id,
      order_by: [asc: u.handle],
      select: {l.character_id, u}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @doc "The ids of the characters the scope's user holds in `chat` (`CharacterLock`), in speaking order."
  @spec locks_of(Scope.t(), Chat.t() | Ecto.UUID.t()) :: [Ecto.UUID.t()]
  def locks_of(%Scope{} = scope, %Chat{id: chat_id}), do: locks_of(scope, chat_id)
  def locks_of(%Scope{user: %User{id: uid}}, chat_id) when is_binary(chat_id), do: held_ids(chat_id, uid)
  def locks_of(_scope, _chat), do: []

  defp held_ids(chat_id, user_id) do
    Repo.all(
      from(l in CharacterLock,
        join: p in Participant,
        on: p.chat_id == l.chat_id and p.character_id == l.character_id,
        where: l.chat_id == ^chat_id and l.user_id == ^user_id,
        order_by: [asc: p.position, asc: p.id],
        select: l.character_id
      )
    )
  end

  @doc """
  Takes `character` for the scope's user in `chat` (with `free_switching` on), alongside whoever
  else plays it and the user's other characters; taking one already held is a no-op. Needs
  `:post`, and the character must be a participant; else `{:error, :not_allowed}`.
  """
  @spec lock(Scope.t(), Chat.t(), Character.t() | Ecto.UUID.t()) :: :ok | {:error, :not_allowed}
  def lock(%Scope{user: %User{id: uid}} = scope, %Chat{free_switching: true} = chat, character) do
    character_id = id_of(character)

    if authorize(scope, chat, :post) == :ok and participant?(chat.id, character_id) do
      insert_locks(chat.id, uid, [character_id])
      broadcast({:ok, nil}, :chat_updated, chat)
      :ok
    else
      {:error, :not_allowed}
    end
  end

  def lock(_scope, _chat, _character), do: {:error, :not_allowed}

  @doc "Releases the scope user's lock on `character` in `chat`, if they hold it."
  @spec unlock(Scope.t(), Chat.t(), Character.t() | Ecto.UUID.t()) :: :ok
  def unlock(%Scope{user: %User{id: uid}}, %Chat{id: chat_id} = chat, character) do
    character_id = id_of(character)

    {deleted, _} =
      Repo.delete_all(
        from(l in CharacterLock,
          where: l.chat_id == ^chat_id and l.user_id == ^uid and l.character_id == ^character_id
        )
      )

    if deleted > 0, do: broadcast({:ok, nil}, :chat_updated, chat)
    :ok
  end

  def unlock(_scope, _chat, _character), do: :ok

  @doc """
  Sets the characters `user_id` plays in `chat` to `character_ids`, leaving other holders of those
  characters alone; `[]` clears the user's locks. Returns the user's held ids in speaking order.
  Needs `:manage`; the user must be the chat's owner or an accepted member and every id a
  participant, else `{:error, :not_allowed}`.
  """
  @spec assign_characters(Scope.t(), Chat.t(), Ecto.UUID.t(), [Ecto.UUID.t()]) ::
          {:ok, [Ecto.UUID.t()]} | {:error, :unauthorized | :not_allowed}
  def assign_characters(%Scope{} = scope, %Chat{} = chat, user_id, character_ids) do
    ids = Enum.uniq(character_ids)

    with :ok <- authorize(scope, chat, :manage),
         true <- user_id == chat.user_id or member_role(user_id, chat.id) != nil,
         true <- all_participants?(chat.id, ids) do
      Repo.transaction(fn ->
        Repo.delete_all(
          from(l in CharacterLock,
            where: l.chat_id == ^chat.id and l.user_id == ^user_id and l.character_id not in ^ids
          )
        )

        insert_locks(chat.id, user_id, ids)
      end)

      broadcast({:ok, held_ids(chat.id, user_id)}, :chat_updated, chat)
    else
      false -> {:error, :not_allowed}
      {:error, _reason} = error -> error
    end
  end

  defp all_participants?(_chat_id, []), do: true

  defp all_participants?(chat_id, ids) do
    Enum.all?(ids, &match?({:ok, _}, Ecto.UUID.cast(&1))) and
      Repo.aggregate(from(p in Participant, where: p.chat_id == ^chat_id and p.character_id in ^ids), :count) ==
        length(ids)
  end

  defp insert_locks(_chat_id, _user_id, []), do: :ok

  defp insert_locks(chat_id, user_id, character_ids) do
    now = DateTime.utc_now(:second)

    rows =
      for character_id <- character_ids do
        %{
          id: Mythweaver.Schema.generate_id(),
          chat_id: chat_id,
          character_id: character_id,
          user_id: user_id,
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(CharacterLock, rows, on_conflict: :nothing, conflict_target: [:chat_id, :character_id, :user_id])
    :ok
  end

  defp participant?(chat_id, character_id) when is_binary(character_id),
    do: Repo.exists?(from(p in Participant, where: p.chat_id == ^chat_id and p.character_id == ^character_id))

  defp participant?(_chat_id, _character_id), do: false

  defp id_of(%Character{id: id}), do: id
  defp id_of(id) when is_binary(id), do: id
  defp id_of(_other), do: nil

  @doc """
  Adds the scope user's own `character` to `chat` (`Participant.added_by_id`), usable in that chat
  only; their messages keep it if it later leaves (`detach_characters/2`). Needs the chat's
  `guests_bring_characters` and an accepted membership (the owner adds characters through
  `add_participants/3`); else `{:error, :not_allowed}`. Another user's character is
  `{:error, :not_found}`; one already in the chat a `character_id` changeset error.
  """
  @spec bring_character(Scope.t(), Chat.t(), Character.t() | Ecto.UUID.t()) ::
          {:ok, Participant.t()} | {:error, :not_allowed | :not_found | Ecto.Changeset.t()}
  def bring_character(
        %Scope{user: %User{id: uid}} = scope,
        %Chat{kind: :roleplay, guests_bring_characters: true} = chat,
        character
      ) do
    with true <- role(scope, chat) in [:guest, :editor] || {:error, :not_allowed},
         %Character{user_id: ^uid} = own <- own_character(id_of(character)) || {:error, :not_found} do
      %Participant{chat_id: chat.id, position: next_position(chat.id), added_by_id: uid}
      |> Participant.changeset(%{"character_id" => own.id})
      |> Repo.insert()
      |> broadcast(:chat_updated, chat)
    else
      %Character{} -> {:error, :not_found}
      error -> error
    end
  end

  def bring_character(_scope, _chat, _character), do: {:error, :not_allowed}

  defp own_character(id) when is_binary(id), do: Repo.get(Character, id)
  defp own_character(_id), do: nil

  @doc """
  Updates the chat's sharing settings: `guest_permissions`, `guests_bring_characters`,
  `free_switching` and `turn_mode`. Needs `:manage`.
  """
  @spec update_membership_settings(Scope.t(), Chat.t(), map()) ::
          {:ok, Chat.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def update_membership_settings(%Scope{} = scope, %Chat{} = chat, attrs) do
    with :ok <- authorize(scope, chat, :manage) do
      chat
      |> Chat.membership_changeset(attrs)
      |> Repo.update()
      |> broadcast(:chat_updated, chat)
    end
  end

  defp chat_preloads, do: [:player_character, :model, participants: [:model, character: :avatar]]

  @doc """
  Creates a chat owned by the scope's user. nil creates an unowned chat; used by seeds and data-layer
  tests only. The next first account adopts it (`adopt_unowned/1`).
  """
  def create_chat(%Scope{user: %User{id: user_id}} = scope, attrs) do
    with :ok <- Quota.check_count(scope, "quota.chats", Chat),
         do: insert_chat(scope, %Chat{user_id: user_id}, attrs)
  end

  def create_chat(nil, attrs), do: insert_chat(nil, %Chat{}, attrs)

  defp insert_chat(scope, %Chat{} = chat, attrs) do
    chat
    |> Chat.create_changeset(attrs)
    |> validate_participant_characters(scope, chat.user_id)
    |> validate_usable_model(scope, chat.user_id)
    |> Repo.insert()
    |> case do
      {:ok, chat} = result -> scope |> Gate.scan_result(result) |> broadcast(:chat_created, chat)
      error -> error
    end
  end

  @doc """
  Creates a "Chat with Mythweaver" thread owned by the scope's user: no participants, no player.
  It counts toward `quota.chats`.
  """
  @spec create_assistant_chat(Scope.t(), map()) :: {:ok, Chat.t()} | {:error, :quota_exceeded | Ecto.Changeset.t()}
  def create_assistant_chat(%Scope{user: %User{id: user_id}} = scope, attrs \\ %{}) do
    with :ok <- Quota.check_count(scope, "quota.chats", Chat) do
      %Chat{user_id: user_id}
      |> Chat.assistant_changeset(attrs)
      |> validate_usable_model(scope, user_id, [:chat])
      |> Repo.insert()
      |> case do
        {:ok, chat} -> broadcast({:ok, Repo.preload(chat, chat_preloads())}, :chat_created, chat)
        error -> error
      end
    end
  end

  @doc """
  Gives every unowned chat to `user`. No broadcast: it runs only when the first account is created,
  so no LiveView is listing chats.
  """
  def adopt_unowned(%User{id: id}) do
    Repo.update_all(from(c in Chat, where: is_nil(c.user_id)), set: [user_id: id])
    :ok
  end

  @doc """
  Updates the chat. A character made the player is unmuted in the same transaction.
  """
  @spec update_chat(Scope.t(), Chat.t(), map()) :: {:ok, Chat.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def update_chat(%Scope{} = scope, %Chat{} = chat, attrs) do
    {changeset, modes, prepare} =
      case chat.kind do
        :assistant -> {&Chat.assistant_changeset/2, [:chat], & &1}
        :roleplay -> {&Chat.update_changeset/2, Model.text_modes(), &Repo.preload(&1, :participants)}
      end

    with :ok <- authorize(scope, chat, :manage) do
      Repo.transaction(fn ->
        chat
        |> prepare.()
        |> changeset.(attrs)
        |> validate_usable_model(scope, chat.user_id, modes)
        |> Repo.update()
        |> Repo.ok_or_rollback()
        |> tap(&unmute_player/1)
      end)
      |> then(&Gate.scan_result(scope, &1, chat))
      |> broadcast(:chat_updated, chat)
    end
  end

  # The player is never muted: mute only applies to characters the AI speaks for.
  defp unmute_player(%Chat{player_character_id: nil}), do: :ok

  defp unmute_player(%Chat{id: chat_id, player_character_id: player_id}) do
    Repo.update_all(
      from(p in Participant, where: p.chat_id == ^chat_id and p.character_id == ^player_id and p.muted),
      set: [muted: false]
    )

    :ok
  end

  @spec delete_chat(Scope.t(), Chat.t()) :: {:ok, Chat.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def delete_chat(%Scope{} = scope, %Chat{} = chat) do
    with :ok <- authorize(scope, chat, :delete) do
      # The members and pending invitees lose their rows with the chat (FK cascade): ask now.
      listeners = audience(chat.id, chat.user_id)
      invitees = Repo.all(from(m in Member, where: m.chat_id == ^chat.id and m.status == :pending, select: m.user_id))
      result = Repo.delete(chat)

      with {:ok, _} <- result do
        announce(listeners, :chat_deleted, chat.id)
        # The rows went with the chat (FK cascade); the inbox still has to hear of it.
        Enum.each([chat.user_id | invitees], &Notifications.broadcast_changed/1)
      end

      result
    end
  end

  def change_chat(%Chat{} = chat, attrs \\ %{}) do
    chat
    |> Repo.preload(:participants)
    |> Chat.update_changeset(attrs)
  end

  @doc "Changeset for a not-yet-inserted chat; unlike `change_chat/2` this casts participants."
  def change_new_chat(attrs \\ %{}), do: Chat.create_changeset(%Chat{participants: []}, attrs)

  @settings_types %{
    name: :string,
    ai_model_id: Ecto.UUID,
    player_character_id: Ecto.UUID,
    participant_ids: {:array, Ecto.UUID},
    lore_book_ids: {:array, Ecto.UUID},
    prompt_id: Ecto.UUID,
    reply_strategy: Ecto.ParameterizedType.init(Ecto.Enum, values: Chat.reply_strategies()),
    allow_self_responses: :boolean,
    max_turns: :integer,
    auto_mode_delay: :integer,
    group_cards: Ecto.ParameterizedType.init(Ecto.Enum, values: Chat.group_cards_modes())
  }

  @doc """
  Schemaless changeset over everything the chat settings modal edits. `chat` must have
  `:participants` preloaded (as `get_chat/1` does).
  """
  def change_settings(%Chat{} = chat, attrs \\ %{}) do
    data = %{
      name: chat.name,
      ai_model_id: chat.ai_model_id,
      player_character_id: chat.player_character_id,
      participant_ids: Enum.map(chat.participants, & &1.character_id),
      lore_book_ids: Lore.chat_book_ids(chat),
      prompt_id: Prompts.chat_prompt_id(chat),
      reply_strategy: chat.reply_strategy,
      allow_self_responses: chat.allow_self_responses,
      max_turns: chat.max_turns,
      auto_mode_delay: chat.auto_mode_delay,
      group_cards: chat.group_cards
    }

    # The form posts a hidden "" so an emptied multi-select still sends its key.
    attrs =
      Enum.reduce(["participant_ids", "lore_book_ids"], attrs, fn key, acc ->
        case acc do
          %{^key => ids} when is_list(ids) -> Map.put(acc, key, Enum.reject(ids, &(&1 == "")))
          _ -> acc
        end
      end)

    {data, @settings_types}
    |> Ecto.Changeset.cast(attrs, Map.keys(@settings_types))
    |> validate_settings()
  end

  defp validate_settings(cs) do
    ids = Ecto.Changeset.get_field(cs, :participant_ids) || []
    player = Ecto.Changeset.get_field(cs, :player_character_id)

    cs =
      if length(ids) < 2,
        do:
          Ecto.Changeset.add_error(cs, :participant_ids, dgettext_noop("errors", "must have at least 2 participants")),
        else: cs

    cs =
      if player && player not in ids,
        do:
          Ecto.Changeset.add_error(
            cs,
            :player_character_id,
            dgettext_noop("errors", "must be a participant of the chat")
          ),
        else: cs

    Chat.validate_turn_settings(cs)
  end

  @doc "Applies `change_settings/2` in one transaction; returns the fully preloaded chat."
  def update_settings(%Scope{} = scope, %Chat{} = chat, attrs) do
    cs = change_settings(chat, attrs)
    actor = actor(scope, chat.user_id)

    with :ok <- authorize(scope, chat, :manage),
         {:ok, s} <- Ecto.Changeset.apply_action(cs, :update) do
      Repo.transaction(fn ->
        ids = s.participant_ids

        Repo.delete_all(from(p in Participant, where: p.chat_id == ^chat.id and p.character_id not in ^ids))
        Repo.delete_all(from(l in CharacterLock, where: l.chat_id == ^chat.id and l.character_id not in ^ids))

        current = Enum.map(chat.participants, & &1.character_id)

        for id <- ids, id not in current do
          Repo.ok_or_rollback(add_participant(chat, %{"character_id" => id}, actor))
        end

        chat
        |> Repo.preload(:participants, force: true)
        |> Chat.update_changeset(%{
          name: s.name,
          ai_model_id: s.ai_model_id,
          player_character_id: s.player_character_id,
          reply_strategy: s.reply_strategy,
          allow_self_responses: s.allow_self_responses,
          max_turns: s.max_turns,
          auto_mode_delay: s.auto_mode_delay,
          group_cards: s.group_cards
        })
        |> validate_usable_model(scope, chat.user_id)
        |> Repo.update()
        |> Repo.ok_or_rollback()
        |> unmute_player()

        Repo.ok_or_rollback(Lore.set_chat_books(chat, s.lore_book_ids, actor))
        Repo.ok_or_rollback(Prompts.set_chat_prompt(chat, s.prompt_id, actor))
      end)
      |> case do
        {:ok, _} ->
          Changes.broadcast([:lore, :prompts], chat.user_id)
          broadcast({:ok, get_chat(chat.id)}, :chat_updated, chat)

        {:error, %Ecto.Changeset{} = inner} ->
          {:error, merge_errors(cs, inner)}

        {:error, :not_roleplay} ->
          {:error,
           Ecto.Changeset.add_error(
             %{cs | action: :validate},
             :prompt_id,
             dgettext_noop("errors", "is not a roleplay prompt")
           )}

        {:error, :unauthorized} ->
          {:error, :unauthorized}
      end
    end
  end

  defp merge_errors(cs, inner) do
    Enum.reduce(inner.errors, %{cs | action: :validate}, fn {field, {msg, opts}}, acc ->
      field =
        case field do
          :character_id -> :participant_ids
          :lore_book_id -> :lore_book_ids
          f -> if Map.has_key?(@settings_types, f), do: f
        end

      if field, do: Ecto.Changeset.add_error(acc, field, msg, opts), else: acc
    end)
  end

  @doc """
  Adds one participant at the end of the chat's speaking order. The character must be usable by the
  chat's owner (`Mythweaver.Characters.usable_by?/2`) and, given `actor` (a chat editor who is not
  the owner), by `actor` too, else a `character_id` error.
  """
  def add_participant(%Chat{} = chat, attrs \\ %{}, actor \\ nil) do
    %Participant{chat_id: chat.id, position: next_position(chat.id)}
    |> Participant.changeset(attrs)
    |> validate_usable_character(chat.user_id, actor)
    |> Repo.insert()
  end

  # A new chat's participants (and so its player, who must be one) are characters its owner may use.
  defp validate_participant_characters(cs, scope, owner_id) do
    case Ecto.Changeset.get_change(cs, :participants) do
      nil ->
        cs

      participants ->
        Ecto.Changeset.put_change(
          cs,
          :participants,
          Enum.map(participants, &(&1 |> validate_usable_character(owner_id) |> validate_usable_model(scope, owner_id)))
        )
    end
  end

  # The scope a chat editor's newly chosen rows must also be usable by: nil for the chat's owner,
  # whose usable rows are already the rule.
  defp actor(%Scope{user: %User{id: id}}, id), do: nil
  defp actor(%Scope{} = scope, _owner_id), do: scope

  defp validate_usable_character(cs, owner_id, actor \\ nil) do
    Ecto.Changeset.validate_change(cs, :character_id, fn :character_id, id ->
      if Characters.usable_by?(owner_id, id) and
           (is_nil(actor) or Character |> Ownership.usable(actor) |> where([c], c.id == ^id) |> Repo.exists?()),
         do: [],
         else: [character_id: dgettext_noop("errors", "is not available")]
    end)
  end

  # A chat's or participant's model is the site's or the chat owner's own, never another user's, and
  # only the owner picks it. Given the acting `scope` (nil for seeds and data-layer callers), a
  # newly chosen one must also be usable by it (`AI.usable?/2`, so a site model's groups apply).
  defp validate_usable_model(cs, scope, owner_id, modes \\ Model.text_modes()) do
    Ecto.Changeset.validate_change(cs, :ai_model_id, fn :ai_model_id, id ->
      cond do
        scope && scope.user.id != owner_id ->
          [ai_model_id: dgettext_noop("errors", "can only be changed by the chat's owner")]

        usable_model?(scope, owner_id, id, modes) ->
          []

        true ->
          [ai_model_id: dgettext_noop("errors", "is not available")]
      end
    end)
  end

  defp usable_model?(scope, owner_id, id, modes) do
    model =
      Repo.one(from(m in Ownership.for_owner(Model, owner_id), where: m.id == ^id and m.completion_mode in ^modes))

    model != nil and (is_nil(scope) or AI.usable?(scope, model))
  end

  defp next_position(chat_id) do
    Repo.one(from(p in Participant, where: p.chat_id == ^chat_id, select: coalesce(max(p.position), -1))) + 1
  end

  @doc """
  Rewrites the chat's speaking order from `participant_ids`, which must be a permutation of the
  chat's current participant ids; anything else returns `{:error, :not_a_permutation}`.

  Single pass: the `(chat_id, position)` index is not unique, so rows cannot collide mid-renumber.
  """
  def reorder_participants(%Scope{} = scope, %Chat{} = chat, participant_ids) when is_list(participant_ids) do
    with :ok <- authorize(scope, chat, :manage) do
      current = Repo.all(from(p in Participant, where: p.chat_id == ^chat.id, select: p.id))

      if Enum.sort(participant_ids) == Enum.sort(current) do
        {:ok, :ok} =
          Repo.transaction(fn ->
            for {id, i} <- Enum.with_index(participant_ids),
                do: Repo.update_all(from(p in Participant, where: p.id == ^id), set: [position: i])

            :ok
          end)

        broadcast({:ok, get_chat(chat.id)}, :chat_updated, chat)
      else
        {:error, :not_a_permutation}
      end
    end
  end

  @doc """
  Updates one participant's per-chat settings: `:ai_model_id`, `:muted`, `:talkativeness` and
  `:outfit_id`. A blank string clears the nullable ones (`:ai_model_id`, `:talkativeness`,
  `:outfit_id`) so the chat or character default (or the Default expression set) takes over. The
  model must be the site's or the chat owner's own, else an `ai_model_id` error; the outfit must be
  one of the participant's character's, else an `outfit_id` error.
  """
  def update_participant(%Scope{} = scope, %Participant{} = participant, attrs) do
    with :ok <- authorize(scope, participant.chat_id, :manage) do
      owner_id = owner_id(participant.chat_id)

      participant
      |> Participant.changeset(attrs)
      |> validate_usable_model(scope, owner_id)
      |> validate_outfit()
      |> Repo.update()
      |> broadcast(:chat_updated, participant.chat_id)
    end
  end

  defp validate_outfit(changeset) do
    character_id = Ecto.Changeset.get_field(changeset, :character_id)

    case Ecto.Changeset.get_change(changeset, :outfit_id) do
      nil ->
        changeset

      outfit_id ->
        if Repo.exists?(from(o in Outfit, where: o.id == ^outfit_id and o.character_id == ^character_id)),
          do: changeset,
          else:
            Ecto.Changeset.add_error(changeset, :outfit_id, dgettext_noop("errors", "is not this character's outfit"))
    end
  end

  @doc """
  Sets `muted` on the participants of `chat` whose ids are in `participant_ids`, never the player
  character (who is never auto-selected and has no mute control). Ids not in the chat are ignored.
  Returns the reloaded chat.
  """
  def set_participants_muted(%Scope{} = scope, %Chat{} = chat, participant_ids, muted?)
      when is_list(participant_ids) and is_boolean(muted?) do
    with :ok <- authorize(scope, chat, :manage) do
      base = from(p in Participant, where: p.chat_id == ^chat.id and p.id in ^participant_ids)

      query =
        case chat.player_character_id do
          nil -> base
          player_id -> from(p in base, where: p.character_id != ^player_id)
        end

      Repo.update_all(query, set: [muted: muted?, updated_at: DateTime.utc_now(:second)])
      broadcast({:ok, get_chat(chat.id)}, :chat_updated, chat)
    end
  end

  def get_participant(id), do: Participant |> Repo.get(id) |> Repo.preload([:character, :model])

  @doc """
  Adds several characters to a chat in one transaction. Rolls back on the first rejection, so a
  partially-applied selection is impossible; returns `{:error, changeset}` carrying that
  rejection (a duplicate character yields the `chat_participants` unique-index error).

  An empty list is a no-op returning `{:ok, []}`.
  """
  def add_participants(%Scope{} = scope, %Chat{} = chat, character_ids) when is_list(character_ids) do
    with :ok <- authorize(scope, chat, :manage) do
      Repo.transaction(fn ->
        Enum.map(
          character_ids,
          &Repo.ok_or_rollback(add_participant(chat, %{"character_id" => &1}, actor(scope, chat.user_id)))
        )
      end)
      |> broadcast(:chat_updated, chat)
    end
  end

  @doc "Whether `character` participates in any chat (deletion is refused while true)."
  def character_in_chat?(%Character{} = character) do
    Repo.exists?(from(p in Participant, where: p.character_id == ^character.id))
  end

  @doc "Whether `character` participates in a chat of its own owner (a site character: in any chat)."
  def character_in_owner_chats?(%Character{user_id: nil} = character), do: character_in_chat?(character)

  def character_in_owner_chats?(%Character{id: id, user_id: owner}) do
    Repo.exists?(
      from(p in Participant,
        join: c in Chat,
        on: c.id == p.chat_id,
        where: p.character_id == ^id and c.user_id == ^owner
      )
    )
  end

  @doc """
  Takes `characters` out of every chat of `owner_id` (the owner can no longer use them), or out of
  one `%Chat{}` only (a member who brought them left it): their messages there keep their names
  (`Messages.detach_character/2`), the player rung is cleared, and the participant rows go even
  below two participants; such a chat cannot reply until one is added. Announces nothing (it runs
  inside the caller's transaction): pass the returned chat ids to `announce_updated/2` after the
  commit.
  """
  @spec detach_characters(Ecto.UUID.t() | Chat.t(), [Character.t()]) :: [Ecto.UUID.t()]
  def detach_characters(_owner_or_chat, []), do: []

  def detach_characters(%Chat{id: chat_id}, characters) do
    character_ids = Enum.map(characters, & &1.id)

    chat_ids =
      Repo.all(
        from(p in Participant,
          where: p.chat_id == ^chat_id and p.character_id in ^character_ids,
          distinct: true,
          select: p.chat_id
        )
      )

    detach_from(chat_ids, characters)
  end

  def detach_characters(owner_id, characters) when is_binary(owner_id) do
    character_ids = Enum.map(characters, & &1.id)

    chat_ids =
      Repo.all(
        from(p in Participant,
          join: c in Chat,
          on: c.id == p.chat_id,
          where: c.user_id == ^owner_id and p.character_id in ^character_ids,
          distinct: true,
          select: c.id
        )
      )

    detach_from(chat_ids, characters)
  end

  defp detach_from(chat_ids, characters) do
    character_ids = Enum.map(characters, & &1.id)
    Enum.each(characters, &Mythweaver.Messages.detach_character(&1, chat_ids))

    Repo.update_all(from(c in Chat, where: c.id in ^chat_ids and c.player_character_id in ^character_ids),
      set: [player_character_id: nil]
    )

    Repo.delete_all(from(p in Participant, where: p.chat_id in ^chat_ids and p.character_id in ^character_ids))
    Repo.delete_all(from(l in CharacterLock, where: l.chat_id in ^chat_ids and l.character_id in ^character_ids))
    chat_ids
  end

  @doc "Tells `owner_id`'s and the members' chat-list viewers and each chat's viewers that `chat_ids` changed."
  @spec announce_updated(Ecto.UUID.t(), [Ecto.UUID.t()]) :: :ok
  def announce_updated(owner_id, chat_ids) do
    Enum.each(chat_ids, &broadcast({:ok, nil}, :chat_updated, %Chat{id: &1, user_id: owner_id}))
  end

  @doc """
  Removes a participant. Refuses (`{:error, :minimum_participants}`) if the chat would drop
  below two participants. If the removed participant is the chat's player character, the
  chat's `player_character_id` is cleared in the same transaction.
  """
  def remove_participant(%Scope{} = scope, %Participant{} = participant) do
    with :ok <- authorize(scope, participant.chat_id, :manage), do: do_remove_participant(participant)
  end

  defp do_remove_participant(participant) do
    Repo.transaction(fn ->
      count =
        Repo.aggregate(
          from(p in Participant, where: p.chat_id == ^participant.chat_id),
          :count
        )

      if count <= 2 do
        Repo.rollback(:minimum_participants)
      else
        chat = Repo.get!(Chat, participant.chat_id)

        if chat.player_character_id == participant.character_id do
          chat |> Ecto.Changeset.change(player_character_id: nil) |> Repo.update!()
        end

        Repo.delete_all(
          from(l in CharacterLock,
            where: l.chat_id == ^participant.chat_id and l.character_id == ^participant.character_id
          )
        )

        Repo.delete!(participant)
      end
    end)
    |> broadcast(:chat_updated, participant.chat_id)
  end

  # The chat-list viewers of the owner and every accepted member refresh their list; viewers of the
  # chat itself also reload it, so none acts on a participant row that is gone or sends as the
  # previous player. Passes `result` through; only a success is announced.
  defp broadcast({:ok, _} = result, event, %Chat{id: chat_id, user_id: owner}) do
    announce(audience(chat_id, owner), event, chat_id)
    result
  end

  defp broadcast({:ok, _} = result, event, chat_id) when is_binary(chat_id) do
    owner = owner_id(chat_id)
    broadcast(result, event, %Chat{id: chat_id, user_id: owner})
  end

  defp broadcast(result, _event, _chat), do: result

  defp announce(user_ids, event, chat_id),
    do: Enum.each(user_ids, &Phoenix.PubSub.broadcast(Mythweaver.PubSub, topic(&1), {event, chat_id}))

  @doc "The `user_id` of chat `chat_id`, or nil when there is no such chat."
  @spec owner_id(Ecto.UUID.t()) :: Ecto.UUID.t() | nil
  def owner_id(chat_id) when is_binary(chat_id),
    do: Repo.one(from(c in Chat, where: c.id == ^chat_id, select: c.user_id))

  @doc """
  Who hears about `chat_id` on their own per-user topics (`topic/1`,
  `Mythweaver.Messages.activity_topic/1`): its owner and every accepted member. An unowned chat has
  no owner to tell.
  """
  @spec audience(Ecto.UUID.t()) :: [Ecto.UUID.t()]
  def audience(chat_id) when is_binary(chat_id), do: audience(chat_id, owner_id(chat_id))

  defp audience(chat_id, owner) do
    members =
      Repo.all(from(m in Member, where: m.chat_id == ^chat_id and m.status == :accepted, select: m.user_id))

    if owner, do: [owner | members], else: members
  end

  # An accepted member's cursor; nil (never read) counts as when they joined.
  defmacrop member_cursor(m), do: quote(do: coalesce(unquote(m).last_read_at, unquote(m).accepted_at))

  @doc """
  Every chat `user_id` reads as owner or accepted member, as rows `%{chat_id:, last_activity_at:,
  read_at:}` where `read_at` is that user's own read cursor: the owner's is `chats.last_read_at`, a
  member's their `chat_members.last_read_at` (nil: their `accepted_at`). Each person reads apart.
  """
  @spec read_cursors_query(Ecto.UUID.t()) :: Ecto.Query.t()
  def read_cursors_query(user_id) do
    members =
      from(m in Member,
        join: c in Chat,
        on: c.id == m.chat_id,
        where: m.user_id == ^user_id and m.status == :accepted,
        select: %{
          chat_id: c.id,
          last_activity_at: c.last_activity_at,
          read_at: type(member_cursor(m), :utc_datetime_usec)
        }
      )

    from(c in Chat,
      where: c.user_id == ^user_id,
      select: %{chat_id: c.id, last_activity_at: c.last_activity_at, read_at: c.last_read_at},
      union_all: ^members
    )
  end

  @doc """
  `user_id`'s `{last_activity_at, read_at}` in `chat_id` (see `read_cursors_query/1`), or nil when
  they neither own it nor are an accepted member. Locks the row holding the cursor (`FOR UPDATE`),
  so inside a transaction it orders against `Mythweaver.Messages.mark_read/2`.
  """
  @spec read_state(Ecto.UUID.t(), Ecto.UUID.t()) :: {DateTime.t() | nil, DateTime.t() | nil} | nil
  def read_state(user_id, chat_id) do
    owned =
      from(c in Chat,
        where: c.id == ^chat_id and c.user_id == ^user_id,
        lock: "FOR UPDATE",
        select: {c.last_activity_at, c.last_read_at}
      )

    Repo.one(owned) ||
      Repo.one(
        from(m in Member,
          join: c in Chat,
          on: c.id == m.chat_id,
          where: m.chat_id == ^chat_id and m.user_id == ^user_id and m.status == :accepted,
          # `c0` is the member row (Ecto names aliases by table): its cursor is what mark_read moves.
          lock: "FOR UPDATE OF c0",
          select: {c.last_activity_at, type(member_cursor(m), :utc_datetime_usec)}
        )
      )
  end

  @doc """
  Advances `user_id`'s own read cursor in `chat_id` to its `last_activity_at`; never backwards.
  Returns the new cursor, or nil when it did not move.
  """
  @spec advance_read_cursor(Ecto.UUID.t(), Ecto.UUID.t()) :: DateTime.t() | nil
  def advance_read_cursor(user_id, chat_id) do
    owned =
      from(c in Chat,
        where:
          c.id == ^chat_id and c.user_id == ^user_id and not is_nil(c.last_activity_at) and
            (is_nil(c.last_read_at) or c.last_read_at < c.last_activity_at),
        select: c.last_read_at,
        update: [set: [last_read_at: c.last_activity_at]]
      )

    member =
      from(m in Member,
        join: c in Chat,
        on: c.id == m.chat_id,
        where:
          m.chat_id == ^chat_id and m.user_id == ^user_id and m.status == :accepted and
            not is_nil(c.last_activity_at) and member_cursor(m) < c.last_activity_at,
        select: m.last_read_at,
        update: [set: [last_read_at: c.last_activity_at]]
      )

    case Repo.update_all(owned, []) do
      {1, [read_at]} ->
        read_at

      _ ->
        case Repo.update_all(member, []) do
          {1, [read_at]} -> read_at
          _ -> nil
        end
    end
  end
end
