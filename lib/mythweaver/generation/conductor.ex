defmodule Mythweaver.Generation.Conductor do
  @moduledoc """
  One chat's turn-taking: the reply queue, the single in-flight `Mythweaver.Generation.Server`, and
  auto mode. Registered under `Mythweaver.Generation.Registry` by chat id, so it is the per-chat lock:
  replies run strictly one after another and never interleave in the transcript.

  It does not stop itself when idle. Staying alive avoids a start/stop race on the registry key, and
  an idle conductor holds no DB work. Every state change broadcasts `{:turn_state, status}` on
  `Mythweaver.Messages.topic/1`; a queued turn whose pre-flight fails broadcasts
  `{:turn_error, %{character_id:, reason:}}` and turns auto mode off, so a broken configuration cannot
  spin. Auto mode is runtime state only and is off after a restart.

  `:stop` ends the reply in flight, turns auto mode off, and pauses the queue with its order kept;
  `:resume`, `:enqueue` or `:respond` unpauses it. `:cancel` clears everything.

  A reply or regenerate that succeeds fans out into `generation.swipes_per_generation` swipes: the
  extra ones jump the queue as regenerations of the same message, and a failed or stopped one drops
  the rest of its batch. The conductor tells each reply whether it notifies
  (`Mythweaver.Notifications`): a fanned-out batch notifies once, from its last swipe.

  Every queue entry carries the `Mythweaver.Accounts.Scope` of the user who asked for it, and its
  reply runs as the chat's owner on that user's behalf (`Mythweaver.Chats.run_scope/2`: the owner's
  models, prompts, lore, scripts and quota; the job and the notification are the asker's). Auto
  mode's ticks are asked for by the user who turned it on (`auto_scope`). Each stored scope is
  rebuilt from the database (`fresh_scope/1`) before it is used, so changed permissions applies to
  turns already queued; the entries of a deleted user, or of one no longer in the chat, are dropped,
  and a deleted user's auto mode ends.

  With `turn_mode: :round`, a human message (`:respond`) or a skip (`:skip`) queues the reply
  strategy's round only once every user holding a character lock has posted or skipped since the
  last AI message (`TurnPolicy.waiting/3`). Skips are runtime state (`skipped`), cleared when a round
  starts or a reply lands. Characters held by a lock are never picked by automatic turns.
  """

  use GenServer, restart: :temporary

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Generation
  alias Mythweaver.Generation.Server
  alias Mythweaver.Generation.TurnPolicy
  alias Mythweaver.Messages
  alias Mythweaver.Notifications

  @registry Mythweaver.Generation.Registry
  @supervisor Mythweaver.Generation.Supervisor

  @type status :: %{
          chat_id: Ecto.UUID.t() | nil,
          speaking: Ecto.UUID.t() | nil,
          queue: [%{id: pos_integer(), character_id: Ecto.UUID.t()}],
          auto?: boolean(),
          paused?: boolean()
        }

  def start_link(opts) do
    chat_id = Keyword.fetch!(opts, :chat_id)
    GenServer.start_link(__MODULE__, chat_id, name: {:via, Registry, {@registry, chat_id}})
  end

  @impl true
  def init(chat_id) do
    {:ok,
     %{
       chat_id: chat_id,
       queue: [],
       current: nil,
       auto?: false,
       auto_scope: nil,
       paused?: false,
       timer: nil,
       skipped: MapSet.new()
     }}
  end

  @impl true
  def handle_call({:enqueue, entries}, _from, state) do
    {:reply, :ok, enqueue(state, entries)}
  end

  def handle_call({:respond, scope}, _from, state) do
    case Chats.get_chat(state.chat_id) do
      nil -> {:reply, :ok, advance(state)}
      chat -> {:reply, :ok, start_round(state, chat, scope)}
    end
  end

  def handle_call({:skip, %Scope{user: %{id: user_id}} = scope}, _from, state) do
    case Chats.get_chat(state.chat_id) do
      %{turn_mode: :round} = chat ->
        {:reply, :ok, start_round(%{state | skipped: MapSet.put(state.skipped, user_id)}, chat, scope)}

      _any ->
        {:reply, :ok, state}
    end
  end

  # An entry's `guide` slot holds the text `Generation.prepare/6` takes: the guide, or for a refine
  # its instructions; `guide_attachment_ids` the attachments sent with it. `script?` marks a request
  # a Lua script made (`Generation` option `:script`).
  def handle_call(
        {tag, _scope, _message_id, _guide, _guide_attachment_ids, _script?},
        _from,
        %{current: current, queue: queue} = state
      )
      when tag in [:regenerate, :continue, :refine] and (current != nil or queue != []) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({tag, scope, message_id, guide, guide_attachment_ids, script?}, _from, state)
      when tag in [:regenerate, :continue, :refine] do
    case Messages.get_message(scope, message_id) do
      %{author_character_id: id} when not is_nil(id) ->
        entry = %{
          character_id: id,
          mode: {mode_for(tag), message_id},
          guide: guide,
          guide_attachment_ids: guide_attachment_ids,
          script?: script?,
          scope: scope
        }

        {:reply, :ok, state |> push([entry]) |> advance()}

      _ ->
        {:reply, {:error, :not_character_authored}, state}
    end
  end

  def handle_call(:stop, _from, %{current: nil} = state), do: {:reply, {:error, :not_generating}, state}

  def handle_call(:stop, _from, state) do
    queue = drop_extra_swipes(state.queue)

    state =
      state
      |> stop_current()
      |> cancel_timer()
      |> Map.merge(%{queue: queue, auto?: false, auto_scope: nil, paused?: queue != []})

    {:reply, :ok, broadcast(state)}
  end

  def handle_call(:resume, _from, state), do: {:reply, :ok, advance(%{state | paused?: false})}

  def handle_call(:cancel, _from, %{current: nil, queue: [], auto?: false} = state) do
    {:reply, {:error, :not_generating}, state}
  end

  def handle_call(:cancel, _from, state) do
    state =
      state
      |> stop_current()
      |> cancel_timer()
      |> Map.merge(%{queue: [], auto?: false, auto_scope: nil, paused?: false})

    {:reply, :ok, broadcast(state)}
  end

  def handle_call({:dequeue, id}, _from, state) do
    queue = Enum.reject(state.queue, &(&1.id == id))
    {:reply, :ok, advance(%{state | queue: queue, paused?: state.paused? and queue != []})}
  end

  def handle_call(:clear_queue, _from, state) do
    {:reply, :ok, advance(%{state | queue: [], paused?: false})}
  end

  def handle_call({:set_auto, scope, true}, _from, state) do
    state = %{state | auto?: true, auto_scope: scope}
    state = if idle?(state) and state.timer == nil, do: schedule_tick(state), else: state
    {:reply, :ok, broadcast(state)}
  end

  def handle_call({:set_auto, _scope, false}, _from, state) do
    {:reply, :ok, state |> cancel_timer() |> Map.merge(%{auto?: false, auto_scope: nil}) |> broadcast()}
  end

  def handle_call(:status, _from, state), do: {:reply, status(state), state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{current: %{ref: ref} = current} = state) do
    state = %{state | current: nil}

    state =
      case reason do
        {:shutdown, {:replied, message_id}} ->
          push_front(%{state | skipped: MapSet.new()}, extra_swipes(current, message_id))

        _ ->
          %{state | queue: drop_extra_swipes(state.queue)}
      end

    {:noreply, advance(state)}
  end

  def handle_info({:auto_tick, token}, %{timer: {_tref, token}} = state) do
    state = %{state | timer: nil}

    cond do
      not state.auto? or not idle?(state) ->
        {:noreply, state}

      fresh_scope(state.auto_scope) == nil ->
        {:noreply, broadcast(%{state | auto?: false, auto_scope: nil})}

      chat = Chats.get_chat(state.chat_id) ->
        case TurnPolicy.round(chat, Messages.list_messages(chat), :auto, Map.keys(Chats.locks(chat))) do
          [] ->
            {:noreply, schedule_tick(state, chat)}

          ids ->
            {:noreply, state |> push(new_entries(ids, state.auto_scope)) |> advance()}
        end

      true ->
        {:noreply, broadcast(%{state | auto?: false})}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A human message or skip: the reply strategy's round, queued as `scope`'s, unless a `:round` chat
  # still waits on a lock holder.
  defp start_round(state, chat, scope) do
    messages = Messages.list_messages(chat)
    locks = Chats.locks(chat)
    holders = locks |> Map.values() |> List.flatten() |> Enum.map(& &1.id) |> Enum.uniq()

    if chat.turn_mode == :round and TurnPolicy.waiting(holders, messages, state.skipped) != [] do
      state
    else
      queued = MapSet.new(state.queue, & &1.character_id)

      entries =
        chat
        |> TurnPolicy.round(messages, :player, Map.keys(locks))
        |> Enum.reject(&MapSet.member?(queued, &1))
        |> new_entries(scope)

      enqueue(%{state | skipped: MapSet.new()}, entries)
    end
  end

  defp enqueue(state, entries), do: %{state | paused?: false} |> push(entries) |> advance()

  defp push(state, entries), do: %{state | queue: state.queue ++ with_ids(entries)}

  defp push_front(state, entries), do: %{state | queue: with_ids(entries) ++ state.queue}

  defp with_ids(entries), do: Enum.map(entries, &Map.put(&1, :id, System.unique_integer([:positive, :monotonic])))

  defp new_entries(character_ids, scope),
    do: Enum.map(character_ids, &%{character_id: &1, mode: :new, guide: nil, guide_attachment_ids: [], scope: scope})

  # A stopped, failed or cancelled reply drops whatever is left of its batch.
  defp drop_extra_swipes(queue), do: Enum.reject(queue, &Map.get(&1, :extra_swipe?, false))

  # `terminate/2` finalizes the body as stopped and broadcasts `:generation_finished`.
  defp stop_current(%{current: nil} = state), do: state

  defp stop_current(%{current: %{pid: pid, ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    stop_server(pid)
    %{state | current: nil}
  end

  # How many extra swipes a turn fans out into once it succeeds, decided when it starts (so the
  # `:DOWN` that follows needs no database read): `n - 1` for a new reply or a regenerate; none for
  # continues, refines, script requests, the extra swipes themselves, or replies as the player's own
  # character.
  defp extra_swipe_count(chat, scope, %{mode: mode} = entry) do
    if (mode == :new or match?({:swipe, _}, mode)) and not Map.get(entry, :extra_swipe?, false) and
         not Map.get(entry, :script?, false) and chat.player_character_id != entry.character_id do
      max(Mythweaver.Settings.get(scope, "generation.swipes_per_generation") - 1, 0)
    else
      0
    end
  end

  # Only the batch's last swipe notifies, with the kind of the reply that fanned out.
  defp extra_swipes(%{entry: entry, extra_swipes: count}, message_id) do
    for i <- 1..count//1 do
      %{
        character_id: entry.character_id,
        mode: {:swipe, message_id},
        guide: entry.guide,
        guide_attachment_ids: Map.get(entry, :guide_attachment_ids, []),
        script?: false,
        scope: entry.scope,
        extra_swipe?: true,
        notify: if(i == count, do: Notifications.reply_kind(entry.mode))
      }
    end
  end

  # A stopped reply leaves the queue waiting, in order, until `:resume` or a new request.
  defp advance(%{paused?: true} = state), do: broadcast(state)

  defp advance(%{current: nil, queue: [entry | rest]} = state) do
    state = %{state | queue: rest}

    case Chats.get_chat(state.chat_id) do
      nil ->
        broadcast(%{cancel_timer(state) | queue: [], auto?: false})

      chat ->
        scope = member_scope(entry.scope, chat)
        run_scope = scope && Chats.run_scope(scope, chat)
        # Read before the reply starts, so nothing races the reply's end for the database.
        swipes = run_scope && extra_swipe_count(chat, run_scope, entry)

        case run_scope && start_turn(chat, %{entry | scope: run_scope}, scope, swipes) do
          nil ->
            advance(state)

          {:ok, pid} ->
            current = %{pid: pid, ref: Process.monitor(pid), entry: entry, extra_swipes: swipes}
            broadcast(%{state | current: current})

          :skip ->
            advance(state)

          {:error, reason} ->
            broadcast_event(state, {:turn_error, %{character_id: entry.character_id, reason: reason}})
            advance(%{cancel_timer(state) | auto?: false})
        end
    end
  end

  defp advance(%{current: nil, queue: [], auto?: true, timer: nil} = state) do
    state |> schedule_tick() |> broadcast()
  end

  defp advance(state), do: broadcast(state)

  # The stored scope rebuilt (`fresh_scope/1`), while its user is still the chat's owner or member.
  defp member_scope(scope, chat) do
    with %Scope{} = scope <- fresh_scope(scope), role when role != nil <- Chats.role(scope, chat), do: scope
  end

  # `entry.scope` is the scope the reply runs as (`Chats.run_scope/2`); `initiator` the asker's own,
  # whom it notifies and whose `Chats.spend_scope/3` decides whose models and quota the reply spends.
  # `:skip` covers rows that vanished while queued (a deleted character or swiped message); there is
  # nothing to report and nothing to generate.
  defp start_turn(chat, entry, initiator, swipes) do
    with %{} = character <- turn_character(chat, entry),
         {:ok, mode} <- resolve_mode(entry.scope, entry.mode, Map.get(entry, :extra_swipe?, false)),
         {:ok, opts} <-
           Generation.prepare(
             entry.scope,
             chat,
             character,
             mode,
             entry.guide,
             Map.get(entry, :guide_attachment_ids, []),
             Chats.spend_scope(initiator, chat, entry.scope)
           ),
         opts = Keyword.merge(opts, initiator: initiator, script_triggered: Map.get(entry, :script?, false)),
         opts = Keyword.put(opts, :notify, notify_kind(entry, swipes)),
         {:ok, pid} <- DynamicSupervisor.start_child(@supervisor, {Server, opts}) do
      {:ok, pid}
    else
      nil -> :skip
      :skip -> :skip
      {:error, reason} -> {:error, reason}
    end
  end

  # A participant's character as the chat loads it (a member's own character too, which the owner's
  # scope cannot look up); any other only when the scope may use it.
  defp turn_character(chat, entry) do
    Enum.find_value(chat.participants, &(&1.character_id == entry.character_id && &1.character)) ||
      Characters.get_character(entry.scope, entry.character_id)
  end

  # The notification kind a reply sends on success, or nil: a reply that fans out leaves it to its
  # batch's last swipe.
  defp notify_kind(_entry, swipes) when swipes > 0, do: nil
  defp notify_kind(%{extra_swipe?: true} = entry, _swipes), do: entry.notify
  defp notify_kind(entry, _swipes), do: Notifications.reply_kind(entry.mode)

  defp mode_for(:regenerate), do: :swipe
  defp mode_for(:continue), do: :continue
  defp mode_for(:refine), do: :refine

  # An extra swipe is skipped once its message is no longer last, e.g. a player posted meanwhile.
  defp resolve_mode(_scope, :new, _extra_swipe?), do: {:ok, :new}

  defp resolve_mode(scope, {kind, message_id}, extra_swipe?) when kind in [:swipe, :continue, :refine] do
    case Messages.get_message(scope, message_id) do
      nil -> :skip
      message -> if extra_swipe? and not Messages.last_message?(scope, message), do: :skip, else: {:ok, {kind, message}}
    end
  end

  defp stop_server(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  @doc """
  `scope` rebuilt from its user's current row, so a role change since it was stored applies; nil when
  the user is gone.
  """
  @spec fresh_scope(Scope.t() | nil) :: Scope.t() | nil
  def fresh_scope(%Scope{user: %{id: id}}) do
    case Accounts.get_user(id) do
      nil -> nil
      user -> Scope.for_user(user)
    end
  end

  def fresh_scope(_scope), do: nil

  defp idle?(state), do: state.current == nil and state.queue == []

  defp schedule_tick(state), do: schedule_tick(state, Chats.get_chat(state.chat_id))

  defp schedule_tick(state, nil), do: %{state | auto?: false}

  defp schedule_tick(state, chat) do
    token = make_ref()
    tref = Process.send_after(self(), {:auto_tick, token}, chat.auto_mode_delay * 1000)
    %{state | timer: {tref, token}}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: {tref, _token}} = state) do
    Process.cancel_timer(tref)
    %{state | timer: nil}
  end

  defp status(state) do
    %{
      chat_id: state.chat_id,
      speaking: state.current && state.current.entry.character_id,
      queue: Enum.map(state.queue, &Map.take(&1, [:id, :character_id])),
      auto?: state.auto?,
      paused?: state.paused?
    }
  end

  defp broadcast(state) do
    broadcast_event(state, {:turn_state, status(state)})
    state
  end

  defp broadcast_event(state, event) do
    Phoenix.PubSub.broadcast(Mythweaver.PubSub, Messages.topic(state.chat_id), event)
  end
end
