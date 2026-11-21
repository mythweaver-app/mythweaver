defmodule MythweaverWeb.MainChatLive.Members do
  @moduledoc """
  The chat settings' Members tab and the "who I play" controls for `MainChatLive`, which routes
  every name in `events/0` here: invites, member model sources, membership toggles, player rows and
  character locks (taking, releasing, playing as). It also owns who the viewer posts as
  (`poster_id/1`, `follow_poster/2`, `keep_poster/2`), the composer form that follows it
  (`assign_composer_form/2`), and the locks and members the settings show (`assign_locks/1`,
  `assign_members/1`, `invite_form/1`).
  """
  use Gettext, backend: Mythweaver.Gettext

  import MythweaverWeb.Flash, only: [flash_unauthorized: 1]
  import Phoenix.Component, only: [assign: 2, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Messages
  alias MythweaverWeb.MainChatLive.ChatRefresh

  @events ~w(invite_member set_member_model_source set_member_model remove_member save_membership
             assign_players add_player_row remove_player_row take_character release_character play_as)

  def events, do: @events

  def handle_event("invite_member", %{"invite" => %{"handle" => handle} = params}, socket) do
    role = if params["role"] == "editor", do: :editor, else: :guest
    source = if params["model_source"] == "own", do: :own, else: :owner
    %{current_scope: scope, selected_chat: chat} = socket.assigns

    case Chats.invite(scope, chat, String.trim(handle), role, source) do
      {:ok, _member} ->
        {:noreply,
         socket
         |> assign(member_invite_form: invite_form())
         |> assign_members()
         |> put_flash(:info, invite_sent_flash(handle))}

      {:error, reason} ->
        {:noreply, socket |> assign(member_invite_form: invite_form(params)) |> put_flash(:error, invite_error(reason))}
    end
  end

  def handle_event("set_member_model_source", %{"member_id" => id, "model_source" => value}, socket) do
    source = if value == "own", do: :own, else: :owner

    case Chats.set_model_source(socket.assigns.current_scope, id, source) do
      {:ok, _member} -> {:noreply, assign_members(socket)}
      {:error, :unauthorized} -> {:noreply, flash_unauthorized(socket)}
      {:error, :not_found} -> {:noreply, assign_members(socket)}
    end
  end

  def handle_event("set_member_model", %{"member_model" => %{"ai_model_id" => id}}, socket) do
    %{current_scope: scope, selected_chat: chat} = socket.assigns

    case Chats.set_member_model(scope, chat, if(id not in [nil, ""], do: id)) do
      {:ok, member} ->
        {:noreply, assign(socket, viewer_member: member)}

      {:error, :not_available} ->
        {:noreply, put_flash(socket, :error, dgettext("chat", "That model isn't available to you."))}

      {:error, _reason} ->
        {:noreply, flash_unauthorized(socket)}
    end
  end

  def handle_event("remove_member", %{"id" => id}, socket) do
    case Chats.remove_member(socket.assigns.current_scope, id) do
      {:ok, _member} ->
        {:noreply,
         socket |> ChatRefresh.refresh_selected(socket.assigns.selected_chat) |> assign_locks() |> assign_members()}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}

      {:error, :not_found} ->
        {:noreply, assign_members(socket)}
    end
  end

  # The Members tab's toggles save on every change. Checkboxes post `"true"`/`"false"`; LiveView also
  # posts `_unused_*` markers for untouched inputs, so only the known toggles are read.
  def handle_event("save_membership", %{"membership" => params}, socket) do
    old_poster = poster_id(socket.assigns)
    chat = socket.assigns.selected_chat
    known = Chat.guest_permissions(chat)

    perms =
      for {key, value} <- params["guest_permissions"] || %{},
          Map.has_key?(known, key),
          into: %{},
          do: {key, value == "true"}

    attrs =
      params
      |> Map.take(["guests_bring_characters", "free_switching", "turn_mode"])
      |> Map.put("guest_permissions", Map.merge(known, perms))

    case Chats.update_membership_settings(socket.assigns.current_scope, chat, attrs) do
      {:ok, _chat} ->
        {:noreply, socket |> ChatRefresh.refresh_selected(chat) |> after_lock_change(old_poster)}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, dgettext("chat", "Could not save the member settings"))}
    end
  end

  # Without free switching the owner and editors set each player row's characters.
  def handle_event("assign_players", params, socket) do
    old_poster = poster_id(socket.assigns)
    %{current_scope: scope, selected_chat: chat} = socket.assigns

    rows = for {user_id, ids} <- params["players"] || %{}, lock_holder?(socket.assigns, user_id), do: {user_id, ids}

    result =
      Enum.reduce_while(rows, :ok, fn {user_id, ids}, :ok ->
        posted = ids |> List.wrap() |> Enum.reject(&(&1 == ""))

        if MapSet.new(posted) == MapSet.new(held_by(socket.assigns, user_id)) do
          {:cont, :ok}
        else
          case Chats.assign_characters(scope, chat, user_id, posted) do
            {:ok, _held} -> {:cont, :ok}
            error -> {:halt, error}
          end
        end
      end)

    # A row whose last character was unticked stays until it is removed.
    emptied = for {user_id, ids} <- rows, List.wrap(ids) |> Enum.all?(&(&1 == "")), do: user_id
    added = Enum.uniq(socket.assigns.player_rows_added ++ emptied)

    {:noreply,
     socket
     |> assign(player_rows_added: added)
     |> after_lock_change(old_poster)
     |> lock_error(result)}
  end

  def handle_event("add_player_row", %{"player" => %{"user_id" => uid}}, socket) do
    added = socket.assigns.player_rows_added

    if lock_holder?(socket.assigns, uid) and uid not in added,
      do: {:noreply, assign(socket, player_rows_added: added ++ [uid])},
      else: {:noreply, socket}
  end

  def handle_event("add_player_row", _params, socket), do: {:noreply, socket}

  def handle_event("remove_player_row", %{"user_id" => uid}, socket) do
    old_poster = poster_id(socket.assigns)
    %{current_scope: scope, selected_chat: chat} = socket.assigns

    if lock_holder?(socket.assigns, uid) do
      result = with {:ok, _held} <- Chats.assign_characters(scope, chat, uid, []), do: :ok

      {:noreply,
       socket
       |> assign(player_rows_added: List.delete(socket.assigns.player_rows_added, uid))
       |> after_lock_change(old_poster)
       |> lock_error(result)}
    else
      {:noreply, socket}
    end
  end

  # Free switching: take any character (alongside whoever else plays it), or let go of one held.
  def handle_event("take_character", %{"character_id" => character_id}, socket) do
    old_poster = poster_id(socket.assigns)
    chat = socket.assigns.selected_chat

    with %{} = character <- chat_character(chat, character_id),
         :ok <- Chats.lock(socket.assigns.current_scope, chat, character) do
      {:noreply,
       socket
       |> after_lock_change(old_poster)
       |> put_flash(:info, now_play_flash(character.name))}
    else
      nil -> {:noreply, socket}
      {:error, _reason} -> {:noreply, flash_unauthorized(socket)}
    end
  end

  def handle_event("release_character", %{"character_id" => character_id}, socket) do
    old_poster = poster_id(socket.assigns)
    :ok = Chats.unlock(socket.assigns.current_scope, socket.assigns.selected_chat, character_id)
    {:noreply, after_lock_change(socket, old_poster)}
  end

  # The one "who I play" control. A held character becomes who this tab posts as, and for the owner
  # also the chat's player character, so their `You` badge follows. Holding none, a manager sets the
  # chat's player character, whom the owner then posts as (`poster_id/4`).
  def handle_event("play_as", %{"character_id" => character_id}, socket) do
    %{my_locks: held, role: role, selected_chat: chat} = socket.assigns

    cond do
      chat == nil ->
        {:noreply, socket}

      character_id in held ->
        socket = assign(socket, posting_as: character_id)

        if role == :owner and chat.player_character_id != character_id,
          do: {:noreply, set_player_character(socket, chat, character_id)},
          else: {:noreply, socket}

      held == [] ->
        {:noreply, set_player_character(socket, chat, character_id)}

      true ->
        {:noreply, socket}
    end
  end

  @doc "The Members tab's invite form, blank or holding refused `params`."
  def invite_form(params \\ %{"handle" => "", "role" => "guest", "model_source" => "owner"}),
    do: to_form(params, as: :invite)

  @doc """
  The settings' Members tab: the chat's members and, for lock assignment, who may hold a character
  (the owner and the accepted members). Loaded only while the settings are open.
  """
  def assign_members(%{assigns: %{settings_form: %{}, selected_chat: %Chat{} = chat}} = socket) do
    members = Chats.list_members(socket.assigns.current_scope, chat)
    owner = Mythweaver.Accounts.get_user(chat.user_id)
    accepted = for %{status: :accepted, user: user} <- members, do: user

    assign(socket,
      members: members,
      lock_holders: for(user <- List.wrap(owner) ++ accepted, do: {holder_label(user), user.id})
    )
  end

  def assign_members(socket), do: assign(socket, members: [], lock_holders: [])

  defp holder_label(%{nickname: nil, handle: handle}), do: "@" <> handle
  defp holder_label(%{nickname: nickname, handle: handle}), do: "#{nickname} (@#{handle})"

  @doc """
  The composer form for `chat`. The landing and an assistant thread compose for Mythweaver: no
  draft, no player. A role-play chat's one draft is the owner's: a member's composer starts empty
  and saves none.
  """
  def assign_composer_form(socket, chat) when is_nil(chat) or chat.kind == :assistant,
    do: assign(socket, composer_form: to_form(%{"content" => ""}, as: :composer), composer_text: "")

  def assign_composer_form(socket, chat) do
    cond do
      poster_id(socket.assigns) == nil ->
        assign(socket, composer_form: nil, composer_text: "")

      socket.assigns.role == :owner ->
        content = Messages.draft_content(socket.assigns.current_scope, chat)
        assign(socket, composer_form: to_form(%{"content" => content}, as: :composer), composer_text: content || "")

      true ->
        assign(socket, composer_form: to_form(%{"content" => ""}, as: :composer), composer_text: "")
    end
  end

  @doc """
  The character the viewer posts as: `posting_as` when they hold it, else the first character they
  hold (`Chats.locks/1`); holding none, the owner plays the chat's player character and a member
  nobody (`Messages.send_message/5`).
  """
  def poster_id(%{role: role, my_locks: held, posting_as: as, selected_chat: chat}), do: poster_id(role, held, as, chat)

  @doc "`poster_id/1` from its parts, for a template that holds them as separate assigns."
  def poster_id(_role, [first | _] = held, as, _chat), do: if(as in held, do: as, else: first)
  def poster_id(:owner, [], _as, %Chat{player_character_id: id}), do: id
  def poster_id(_role, _held, _as, _chat), do: nil

  @doc """
  Rebuilds the composer form when the viewer goes from posting as nobody to a character, or back.
  Switching between two characters keeps the composer's text and leaves the editor alone. `old`:
  `poster_id/1` before the change.
  """
  def follow_poster(socket, old) do
    if is_binary(old) == is_binary(poster_id(socket.assigns)),
      do: socket,
      else: assign_composer_form(socket, socket.assigns.selected_chat)
  end

  # Routed through `Chats.update_chat/2` because it preloads `:participants` before building the
  # changeset; `Chat.update_changeset/2`'s `validate_player_is_participant/1` reads
  # `get_field(changeset, :participants)` and would raise `KeyError` on an un-preloaded struct.
  defp set_player_character(socket, chat, character_id) do
    case Chats.update_chat(socket.assigns.current_scope, chat, %{"player_character_id" => character_id}) do
      {:ok, _updated} ->
        reloaded = Chats.get_chat(socket.assigns.current_scope, chat.id)
        old_poster = poster_id(socket.assigns)

        # No re-stream: each message's `You` badge is stamped at send time
        # (`Message.author_is_player`), so past messages keep the character played back then.
        socket
        |> assign(selected_chat: reloaded)
        |> follow_poster(old_poster)
        |> ChatRefresh.refresh_chats()
        |> put_flash(:info, now_playing_flash(reloaded))

      {:error, :unauthorized} ->
        flash_unauthorized(socket)

      {:error, %Ecto.Changeset{}} ->
        put_flash(socket, :error, dgettext("chat", "Could not set the player character"))
    end
  end

  @doc """
  Every lock of the open role-play chat (`Chats.locks/1`) and the ids the viewer holds, in
  speaking order.
  """
  def assign_locks(%{assigns: %{selected_chat: %Chat{kind: :roleplay} = chat}} = socket) do
    locks = Chats.locks(chat)
    viewer = socket.assigns.current_scope.user.id

    my_locks =
      for %{character_id: id} <- chat.participants,
          Enum.any?(Map.get(locks, id, []), &(&1.id == viewer)),
          do: id

    assign(socket, locks: locks, my_locks: my_locks)
  end

  def assign_locks(socket), do: assign(socket, locks: %{}, my_locks: [])

  @doc """
  Keeps the viewer on the character they posted as when it is still theirs, so a lock gained
  earlier in speaking order does not switch them.
  """
  def keep_poster(socket, old_poster) do
    if old_poster in socket.assigns.my_locks,
      do: assign(socket, posting_as: old_poster),
      else: socket
  end

  # After the open chat's locks or membership settings changed here: re-read the locks (and the
  # Members tab), and rebuild the composer when the viewer gained or lost a character to post as.
  defp after_lock_change(socket, old_poster) do
    socket
    |> assign_locks()
    |> keep_poster(old_poster)
    |> assign_members()
    |> follow_poster(old_poster)
  end

  # The character ids `user_id` holds in the open chat's `locks`.
  defp held_by(%{locks: locks}, user_id),
    do: for({id, holders} <- locks, Enum.any?(holders, &(&1.id == user_id)), do: id)

  # Whether `user_id` may hold characters in the open chat (the Members tab's `lock_holders`).
  defp lock_holder?(%{lock_holders: holders}, user_id), do: Enum.any?(holders, &(elem(&1, 1) == user_id))

  # The flash for a failed player-row change; `:ok` leaves the socket alone.
  defp lock_error(socket, :ok), do: socket
  defp lock_error(socket, {:error, :unauthorized}), do: flash_unauthorized(socket)

  defp lock_error(socket, {:error, _reason}),
    do: put_flash(socket, :error, dgettext("chat", "Could not assign those characters"))

  # The participant `Character` of `chat` with `character_id`, or nil.
  defp chat_character(%Chat{participants: participants}, character_id),
    do: Enum.find_value(participants, &(&1.character_id == character_id && &1.character))

  defp invite_error(:unknown_handle) do
    gettext_comment("Flash when the handle typed into a chat invite matches no user.")
    dpgettext("chat", "status: flash when a chat invite names an unknown handle", "Nobody has that handle")
  end

  defp invite_error(:self) do
    gettext_comment("Flash when the viewer types their own handle into a chat invite.")
    dpgettext("chat", "status: flash when the viewer tries to invite themselves to a chat", "You can't invite yourself")
  end

  defp invite_error(:already_member), do: dgettext("chat", "They are already in this chat or invited")
  defp invite_error(:quota_exceeded), do: dgettext("chat", "You have too many pending invites")
  defp invite_error(_reason), do: dgettext("chat", "You can't invite people to this chat")

  defp now_playing_flash(%{player_character: %{name: name}}) do
    gettext_comment("Flash after the chat owner picks which character they play.")

    dpgettext(
      "chat",
      "status: flash after the chat owner picks the character they play",
      "Now playing as %{character_name}",
      character_name: name
    )
  end

  defp now_playing_flash(_chat) do
    gettext_comment("Flash after the chat owner picks a player character whose name is not loaded.")
    dgettext("chat", "Now playing as this character")
  end

  defp invite_sent_flash(handle) do
    gettext_comment("Flash after a chat invite is sent; %{user_handle} is the invited user's handle, without the @.")

    dpgettext("chat", "status: flash after a chat invite is sent", "Invite sent to @%{user_handle}",
      user_handle: handle |> String.trim() |> String.trim_leading("@")
    )
  end

  defp now_play_flash(character_name) do
    gettext_comment("Flash after a member claims a character to play in a shared chat.")

    dpgettext("chat", "status: flash after the viewer claims a character to play", "You now play %{character_name}",
      character_name: character_name
    )
  end
end
