defmodule MythweaverWeb.RemoteImage do
  @moduledoc """
  Sealed, expiring `/remote-images/` links for the remote images markdown shows
  (`MythweaverWeb.Markdown`), served by `MythweaverWeb.RemoteImageController`, and the proxy's
  fetch behind them.

  The token seals `<<expires_at::64, url::binary>>` the way `Mythweaver.Attachments.Storage.Local`
  seals upload links: AES-256-GCM with a deterministic nonce, so one URL gives one token. Links
  expire at the end of tomorrow (UTC), so a message's HTML is identical across re-renders within a
  day.

  `fetch/2` downloads through `Mythweaver.Net.Guard` (no private addresses, no redirects, at most
  10 MB) in a task of `MythweaverWeb.RemoteImage.TaskSupervisor`, whose `max_children` caps how
  many run at once; the task is killed at a 20 s deadline. Images it fetched are kept in an ETS
  table (`create_table/0`, owned by the application) until their link expires, at most 64 MB in
  all; the entries closest to expiring make room first.
  """

  alias Mythweaver.Net.Guard
  alias Plug.Crypto.KeyGenerator
  alias Plug.Crypto.Keys

  @aad "mythweaver remote image v1"
  @table __MODULE__
  @max_cache 64 * 1024 * 1024
  @max_body 10 * 1024 * 1024
  @deadline 20_000
  @types ~w(image/png image/jpeg image/gif image/webp image/avif)

  @doc "The proxied path for the remote image `url`."
  @spec path(String.t()) :: String.t()
  def path(url) when is_binary(url) do
    expires_at = (div(System.os_time(:second), 86_400) + 2) * 86_400
    "/remote-images/" <> seal(url, expires_at)
  end

  @doc """
  The URL a `path/1` token seals and when it expires (Unix seconds), or `:error` for a malformed,
  forged, altered or expired token.
  """
  @spec open(String.t()) :: {:ok, String.t(), integer()} | :error
  def open(token) when is_binary(token) do
    with {:ok, <<nonce::binary-12, tag::binary-16, ciphertext::binary>>} <- Base.url_decode64(token, padding: false),
         <<expires_at::64, url::binary>> <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, cipher_key(), nonce, ciphertext, @aad, tag, false),
         true <- expires_at > System.os_time(:second) do
      {:ok, url, expires_at}
    else
      _ -> :error
    end
  end

  @doc """
  The image at `url` as `{:ok, media_type, body}`, from the cache or fetched and cached until
  `expires_at` (Unix seconds). Only PNG, JPEG, GIF, WebP and AVIF are returned: SVG can carry
  script. `:busy` when every fetch slot is taken, `:error` for anything else.
  """
  @spec fetch(String.t(), integer()) :: {:ok, String.t(), binary()} | :busy | :error
  def fetch(url, expires_at) when is_binary(url) and is_integer(expires_at) do
    key = :crypto.hash(:sha256, url)

    case cached(key) do
      {:ok, _type, _body} = hit -> hit
      :miss -> download(url, key, expires_at)
    end
  end

  @doc "Creates the image cache's table; the calling process owns it."
  @spec create_table() :: :ok
  def create_table do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    :ets.insert(@table, {:bytes, 0})
    :ok
  end

  defp download(url, key, expires_at) do
    caller = self()
    ref = make_ref()

    task = Mythweaver.Locale.carry(fn -> send(caller, {ref, get(url)}) end)

    case Task.Supervisor.start_child(__MODULE__.TaskSupervisor, task) do
      {:ok, pid} ->
        result = await(pid, ref)
        put(result, key, expires_at)
        result

      {:error, :max_children} ->
        :busy
    end
  end

  defp await(pid, ref) do
    monitor = Process.monitor(pid)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        :error
    after
      @deadline ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])

        # It may have answered just before the kill.
        receive do
          {^ref, _result} -> :ok
        after
          0 -> :ok
        end

        :error
    end
  end

  defp get(url) do
    [
      url: url,
      retry: false,
      connect_options: [timeout: 5_000],
      receive_timeout: 10_000,
      request_timeout: 15_000,
      decode_body: false,
      user_agent: "Mythweaver image proxy",
      headers: [accept: "image/avif,image/webp,image/png,image/jpeg,image/gif"]
    ]
    |> Req.new()
    |> Req.merge(Application.get_env(:mythweaver, :remote_image_req_options, []))
    |> Guard.attach(private: :deny, max_body: @max_body)
    |> Req.get()
    |> case do
      {:ok, %Req.Response{status: 200, body: body} = resp} when is_binary(body) ->
        type = media_type(resp)
        if type in @types, do: {:ok, type, body}, else: :error

      _ ->
        :error
    end
  end

  defp media_type(resp) do
    case Req.Response.get_header(resp, "content-type") do
      [value | _] -> value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()
      [] -> nil
    end
  end

  # -- Cache: `{key, expires_at, size, type, body}` rows plus a `{:bytes, total}` counter. ---------

  defp cached(key) do
    case :ets.lookup(@table, key) do
      [{^key, expires_at, _size, type, body}] ->
        if expires_at > System.os_time(:second) do
          {:ok, type, body}
        else
          evict(key)
          :miss
        end

      [] ->
        :miss
    end
  end

  defp put({:ok, type, body}, key, expires_at) when byte_size(body) <= @max_cache do
    size = byte_size(body)
    make_room(size)
    if :ets.insert_new(@table, {key, expires_at, size, type, body}), do: :ets.update_counter(@table, :bytes, size)
    :ok
  end

  defp put(_result, _key, _expires_at), do: :ok

  defp make_room(size) do
    over = :ets.lookup_element(@table, :bytes, 2) + size - @max_cache

    if over > 0 do
      @table
      |> :ets.select([{{:"$1", :"$2", :_, :_, :_}, [], [{{:"$2", :"$1"}}]}])
      |> Enum.sort()
      |> Enum.reduce_while(over, fn {_expires_at, key}, left ->
        if left > 0, do: {:cont, left - evict(key)}, else: {:halt, left}
      end)
    end
  end

  # `take` rather than `delete`, so only the process that removed a row uncounts it. Returns the
  # bytes freed.
  defp evict(key) do
    case :ets.take(@table, key) do
      [{^key, _expires_at, size, _type, _body}] ->
        :ets.update_counter(@table, :bytes, -size)
        size

      [] ->
        0
    end
  end

  defp seal(url, expires_at) do
    plaintext = <<expires_at::64, url::binary>>
    nonce = :hmac |> :crypto.mac(:sha256, nonce_key(), plaintext) |> binary_part(0, 12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, cipher_key(), nonce, plaintext, @aad, 16, true)

    Base.url_encode64(nonce <> tag <> ciphertext, padding: false)
  end

  defp cipher_key, do: derive("remote image links cipher")
  defp nonce_key, do: derive("remote image links nonce")

  defp derive(salt) do
    :mythweaver
    |> Application.fetch_env!(MythweaverWeb.Endpoint)
    |> Keyword.fetch!(:secret_key_base)
    |> KeyGenerator.generate(salt, cache: Keys)
  end
end
