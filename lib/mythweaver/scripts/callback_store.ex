defmodule Mythweaver.Scripts.CallbackStore do
  @moduledoc """
  What a script attaches to background work it starts, held until the work reports back: the
  `tag` and `data` given to `mw.images.caption` or `mw.images.request`, returned as the
  `image_described` event's `tag` and `data`.

  An ETS table that lives as long as the VM: only an opaque key travels with the job or the image
  request, and a restart forgets every entry (the event then carries nil). Entries are dropped
  after `@ttl_ms`, swept on each `put/2`, since one may be read more than once (a model caption,
  then a person's edit of it on send) and never has a natural last read.
  """

  @table __MODULE__
  @ttl_ms to_timeout(hour: 6)
  @max_data_bytes 64 * 1024

  @doc "Creates the table. Called once at boot by `Mythweaver.Application`."
  def create_table do
    _ = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ok
  end

  @doc """
  Stores `tag` and `data` and returns the key that carries them; `nil` when both are nil.
  `{:error, :data_too_large}` when `data` encodes to more than 64 KB.
  """
  @spec put(String.t() | nil, term()) :: {:ok, String.t() | nil} | {:error, :data_too_large}
  def put(nil, nil), do: {:ok, nil}

  def put(tag, data) do
    if :erlang.external_size(data) > @max_data_bytes do
      {:error, :data_too_large}
    else
      now = System.monotonic_time(:millisecond)
      :ets.select_delete(@table, [{{:_, :_, :_, :"$1"}, [{:<, :"$1", now - @ttl_ms}], [true]}])
      key = Mythweaver.Schema.generate_id()
      true = :ets.insert(@table, {key, tag, data, now})
      {:ok, key}
    end
  end

  @doc "The `tag` and `data` stored under `key`; both nil for no key, or one expired or forgotten."
  @spec fetch(String.t() | nil) :: %{tag: String.t() | nil, data: term()}
  def fetch(nil), do: %{tag: nil, data: nil}

  def fetch(key) do
    case :ets.lookup(@table, key) do
      [{^key, tag, data, _at}] -> %{tag: tag, data: data}
      [] -> %{tag: nil, data: nil}
    end
  end
end
