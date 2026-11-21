defmodule MythweaverWeb.ClientIp do
  @moduledoc """
  The client's IP address behind the app's own reverse proxies.

  A request whose peer is a trusted proxy (`config :mythweaver, :trusted_proxies`, CIDR strings; set
  from `MYTHWEAVER_TRUSTED_PROXIES`, default loopback only) is attributed to the rightmost
  `x-forwarded-for` entry that is not itself trusted: everything left of it was written by the client
  and can be forged. Any other peer is the client. A trusted address is never returned, so a
  misconfigured proxy records no IP rather than linking every account through it.
  """

  import Bitwise

  @doc """
  Parses the configured trusted proxies once and stores them for `client_ip/2`. Raises
  `ArgumentError`, naming `MYTHWEAVER_TRUSTED_PROXIES`, when an entry does not parse.
  """
  @spec load_config!() :: :ok
  def load_config! do
    parsed =
      Enum.map(configured(), fn entry ->
        case parse_cidr(entry) do
          :error ->
            raise ArgumentError, "MYTHWEAVER_TRUSTED_PROXIES: #{inspect(entry)} is not an IP address or CIDR range"

          cidr ->
            cidr
        end
      end)

    :persistent_term.put({__MODULE__, :trusted}, parsed)
  end

  @doc "The client IP of `conn`, or nil."
  @spec from_conn(Plug.Conn.t()) :: String.t() | nil
  def from_conn(%Plug.Conn{remote_ip: ip, req_headers: headers}), do: client_ip(ip, headers)

  @doc "The client IP for a request from `peer` with `headers`, formatted, or nil."
  @spec client_ip(:inet.ip_address() | nil, [{String.t(), String.t()}]) :: String.t() | nil
  def client_ip(nil, _headers), do: nil

  def client_ip(peer, headers) do
    peer = unmap(peer)
    proxies = trusted()

    if trusted?(peer, proxies) do
      headers
      |> Enum.filter(fn {name, _} -> name == "x-forwarded-for" end)
      |> Enum.map_join(",", &elem(&1, 1))
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reverse()
      |> forwarded_client(proxies)
    else
      format(peer)
    end
  end

  defp forwarded_client([], _proxies), do: nil

  defp forwarded_client([entry | rest], proxies) do
    case :inet.parse_strict_address(String.to_charlist(entry)) do
      {:ok, ip} ->
        ip = unmap(ip)
        if trusted?(ip, proxies), do: forwarded_client(rest, proxies), else: format(ip)

      {:error, _} ->
        nil
    end
  end

  defp format(ip), do: ip |> :inet.ntoa() |> to_string()

  defp unmap({0, 0, 0, 0, 0, 0xFFFF, a, b}), do: {a >>> 8, a &&& 255, b >>> 8, b &&& 255}
  defp unmap(ip), do: ip

  defp configured, do: Application.get_env(:mythweaver, :trusted_proxies, [])

  defp trusted, do: :persistent_term.get({__MODULE__, :trusted}, [])

  defp trusted?(ip, proxies), do: Enum.any?(proxies, &in_cidr?(ip, &1))

  defp parse_cidr(entry) when is_binary(entry) do
    {address, prefix} =
      case String.split(String.trim(entry), "/", parts: 2) do
        [address] -> {address, nil}
        [address, prefix] -> {address, prefix}
      end

    with {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(address)),
         bits = bits(ip),
         {:ok, prefix} <- parse_prefix(prefix, bits) do
      {to_integer(ip), bits, prefix}
    else
      _ -> :error
    end
  end

  defp parse_cidr(_entry), do: :error

  defp parse_prefix(nil, bits), do: {:ok, bits}

  defp parse_prefix(prefix, bits) do
    case Integer.parse(prefix) do
      {n, ""} when n >= 0 and n <= bits -> {:ok, n}
      _ -> :error
    end
  end

  defp in_cidr?(ip, {net, bits, prefix}) do
    bits(ip) == bits and to_integer(ip) >>> (bits - prefix) == net >>> (bits - prefix)
  end

  defp bits(ip) when tuple_size(ip) == 4, do: 32
  defp bits(ip) when tuple_size(ip) == 8, do: 128

  defp to_integer({a, b, c, d}), do: a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d

  defp to_integer(ip) when tuple_size(ip) == 8,
    do: ip |> Tuple.to_list() |> Enum.reduce(0, fn part, acc -> acc <<< 16 ||| part end)
end
