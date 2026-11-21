defmodule Mythweaver.Accounts.Throttle do
  @moduledoc """
  Slows down password guessing. Keys are `{:login_email, normalized_email}`, `{:login_ip, ip}` and
  `{:password, user_id}`. Each kind allows a few free attempts; after them every attempt waits
  `min(30 * 2 ** (attempts - free), 900)` seconds from the last counted one. A key's count is
  forgotten 900 seconds after its last counted attempt.

  An attempt counts before the password is checked (`attempt/1`): the count is reserved atomically,
  so parallel guesses can't all pass while one slow verify runs. A refused attempt doesn't count.
  The caller then `clear/1`s the keys a success forgives, or `release/1`s the reservation on keys
  it keeps (a shared IP's count); a failed attempt simply stays counted.

  State lives in a public ETS table owned by this process, per node, and resets on restart.
  """
  use GenServer

  @table __MODULE__
  @free %{login_email: 5, login_ip: 20, password: 5}
  @forget_after 900
  @max_wait 900
  @sweep_every to_timeout(minute: 1)

  @type key :: {:login_email | :login_ip | :password, term()}

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_every)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = now() - @forget_after
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", cutoff}], [true]}])
    Process.send_after(self(), :sweep, @sweep_every)
    {:noreply, state}
  end

  @doc """
  Counts an attempt on every key in `keys`, before the password is checked: `:ok`, or, when any key
  must still wait, `{:error, {:throttled, seconds}}` with the longest wait and nothing counted.
  """
  @spec attempt(key() | [key()]) :: :ok | {:error, {:throttled, pos_integer()}}
  def attempt(keys) when is_list(keys) do
    now = now()

    keys
    |> Enum.map(&reserve(&1, now))
    |> Enum.max(fn -> 0 end)
    |> case do
      0 ->
        Enum.each(keys, &:ets.update_element(@table, &1, {3, now}))

      seconds ->
        Enum.each(keys, &release/1)
        {:error, {:throttled, seconds}}
    end
  end

  def attempt(key), do: attempt([key])

  @doc "Takes back one attempt counted on each key (a success that keeps the key's earlier count)."
  @spec release(key() | [key()]) :: :ok
  def release(keys) when is_list(keys), do: Enum.each(keys, &release/1)

  def release(key) do
    :ets.update_counter(@table, key, {2, -1, 0, 0}, {key, 0, now()})
    :ok
  end

  @doc "Forgets a key's attempts."
  @spec clear(key() | [key()]) :: :ok
  def clear(keys) when is_list(keys), do: Enum.each(keys, &clear/1)

  def clear(key) do
    :ets.delete(@table, key)
    :ok
  end

  @doc "How long `seconds` reads to a person: whole seconds under a minute, else minutes rounded up."
  @spec wait(pos_integer()) :: {:seconds, pos_integer()} | {:minutes, pos_integer()}
  def wait(seconds) when seconds < 60, do: {:seconds, seconds}
  def wait(seconds), do: {:minutes, div(seconds + 59, 60)}

  # Counts one attempt on `key` and returns how long it must still wait (0: go ahead). The counter
  # is bumped atomically, so concurrent attempts each see a different count before theirs.
  defp reserve({kind, _} = key, now) do
    :ets.select_delete(@table, [{{key, :_, :"$1"}, [{:"=<", :"$1", now - @forget_after}], [true]}])
    [count, last] = :ets.update_counter(@table, key, [{2, 1}, {3, 0}], {key, 0, now})
    before = count - 1
    free = Map.fetch!(@free, kind)

    if before < free,
      do: 0,
      else: max(min(30 * 2 ** (before - free), @max_wait) - (now - last), 0)
  end

  defp now, do: System.monotonic_time(:second)
end
