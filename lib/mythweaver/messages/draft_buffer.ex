defmodule Mythweaver.Messages.DraftBuffer do
  @moduledoc """
  Holds composer drafts in memory and writes each through `Mythweaver.Messages.upsert_draft/3`, as
  the scope that buffered it, `Messages.write_debounce_ms/0` after its last edit. Pending drafts are
  flushed on shutdown (exits are trapped). Keyed by chat id; only the chat's owner buffers or
  discards one (`Mythweaver.Messages.authorize_draft/2`). A write that fails (chat deleted, or its
  player gone, meanwhile) is logged and dropped, never retried, so it cannot crash the buffer and lose
  the others.
  """
  use GenServer

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Messages

  require Logger

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Buffers `content` (blank included: a cleared composer deletes the draft on flush)."
  @spec put(Scope.t(), Chat.t(), String.t()) :: :ok | {:error, :unauthorized}
  def put(%Scope{} = scope, %Chat{} = chat, content) do
    with :ok <- Messages.authorize_draft(scope, chat),
         do: GenServer.cast(__MODULE__, {:put, scope, chat, content})
  end

  @doc "`{:ok, content}` for a pending draft, `:error` when nothing is buffered."
  def fetch(chat_id), do: GenServer.call(__MODULE__, {:fetch, chat_id})

  @doc "Drops a pending draft without writing it."
  @spec discard(Scope.t(), Ecto.UUID.t()) :: :ok | {:error, :unauthorized}
  def discard(%Scope{} = scope, chat_id) do
    with :ok <- Messages.authorize_draft(scope, chat_id),
         do: GenServer.call(__MODULE__, {:discard, chat_id})
  end

  @doc "Writes a pending draft now. `:ok` whether or not one was pending."
  def flush(chat_id), do: GenServer.call(__MODULE__, {:flush, chat_id})

  @impl true
  def init(:ok) do
    Process.flag(:trap_exit, true)
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:put, scope, chat, content}, drafts) do
    key = chat.id
    cancel(drafts[key])

    ref = make_ref()
    timer = Process.send_after(self(), {:write, key, ref}, Messages.write_debounce_ms())
    entry = %{scope: scope, chat: chat, content: content, ref: ref, timer: timer}

    {:noreply, Map.put(drafts, key, entry)}
  end

  @impl true
  def handle_call({:fetch, key}, _from, drafts) do
    reply =
      case drafts do
        %{^key => entry} -> {:ok, entry.content}
        _ -> :error
      end

    {:reply, reply, drafts}
  end

  def handle_call({:discard, key}, _from, drafts) do
    {entry, drafts} = Map.pop(drafts, key)
    cancel(entry)
    {:reply, :ok, drafts}
  end

  def handle_call({:flush, key}, _from, drafts) do
    {entry, drafts} = Map.pop(drafts, key)

    if entry do
      cancel(entry)
      write(entry)
    end

    {:reply, :ok, drafts}
  end

  # A `ref` mismatch is a stale timer: its message was already queued when a later `put` cancelled it.
  @impl true
  def handle_info({:write, key, ref}, drafts) do
    case drafts do
      %{^key => %{ref: ^ref} = entry} ->
        write(entry)
        {:noreply, Map.delete(drafts, key)}

      _ ->
        {:noreply, drafts}
    end
  end

  def handle_info(_message, drafts), do: {:noreply, drafts}

  @impl true
  def terminate(_reason, drafts) do
    Enum.each(drafts, fn {_key, entry} -> write(entry) end)
  end

  defp cancel(nil), do: :ok
  defp cancel(entry), do: Process.cancel_timer(entry.timer)

  defp write(entry) do
    case Messages.upsert_draft(entry.scope, entry.chat, entry.content) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("Dropping buffered draft: #{inspect(reason)}")
    end
  rescue
    e -> Logger.warning("Dropping buffered draft: " <> Exception.message(e))
  end
end
