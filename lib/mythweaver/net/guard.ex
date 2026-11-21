defmodule Mythweaver.Net.Guard do
  @moduledoc """
  An SSRF guard for outbound requests to user-supplied URLs.

  `attach/2` turns off redirects, resolves the host once, refuses private and local addresses
  (unless the `:private` policy allows them), connects to the very address it checked (so a second
  DNS answer can't rebind it) and caps the response body.

  The connection is the guard's own: it replaces Req's adapter with a one-shot HTTP/1 `Mint`
  connection to the checked IP, sending the URL's host for `Host`, SNI and certificate checks. It
  never touches a Finch pool, so a user-chosen host costs no pool and no atom. From the request
  options it honors `:receive_timeout` (per read, default 15 s), `:request_timeout` (whole
  response, default none) and `connect_options: [timeout: ms]` (default 30 s); the request body
  must be iodata or nil and `into` nil or a 2-arity fun.

  Only the real `Req.Finch` adapter is guarded: `Req.Test` stubs swap the adapter for `Req.Plug`
  and never touch the network.
  """

  alias Mythweaver.Net.Guard.Error

  @doc """
  Adds the guard to `req`. Options:

    * `private` (required): `:allow`, `:deny`, or a 0-arity fun returning one of them, asked only
      when the host resolves to a private or local address.
    * `max_body` (bytes, required): the cap on a buffered body.
    * `max_stream` (bytes, default `max_body`): the cap on what an `into:` fun receives.
  """
  @spec attach(Req.Request.t(), keyword()) :: Req.Request.t()
  def attach(%Req.Request{} = req, opts) do
    private = Keyword.fetch!(opts, :private)
    max_body = Keyword.fetch!(opts, :max_body)
    true = private in [:allow, :deny] or is_function(private, 0)

    req
    |> Req.merge(redirect: false)
    |> Req.Request.put_private(:mythweaver_guard,
      private: private,
      max_body: max_body,
      max_stream: Keyword.get(opts, :max_stream, max_body)
    )
    # Appended so it runs after `put_base_url` and sees the final host.
    |> Req.Request.append_request_steps(mythweaver_guard: &guard/1)
    # Prepended so the buffered body is handed back (`into: nil`) before `decompress_body`.
    |> Req.Request.prepend_response_steps(mythweaver_body_cap: &body_cap/1)
  end

  @doc false
  def guard(%Req.Request{adapter: Req.Finch} = request) do
    opts = request.private.mythweaver_guard
    host = request.url.host || ""
    request = Req.Request.put_private(request, :mythweaver_host, host)
    charlist = String.to_charlist(host)

    ips =
      case :inet.parse_address(charlist) do
        {:ok, ip} -> [ip]
        {:error, _} -> resolve(charlist)
      end

    check(request, host, ips, opts)
  end

  def guard(request), do: request

  defp resolve(charlist) do
    for family <- [:inet, :inet6], {:ok, ips} <- [:inet.getaddrs(charlist, family)], ip <- ips, do: ip
  end

  defp check(request, host, [], _opts), do: {request, %Error{reason: :unresolvable, host: host}}

  defp check(request, host, ips, opts) do
    if Enum.all?(ips, &public?/1) or allowed?(opts[:private]) do
      request |> pin(ips) |> cap_body(opts)
    else
      {request, %Error{reason: :private_address, host: host}}
    end
  end

  defp allowed?(:allow), do: true
  defp allowed?(:deny), do: false
  defp allowed?(policy) when is_function(policy, 0), do: allowed?(policy.())

  # IPv4 first, as a plain `:gen_tcp` connect would.
  defp pin(request, ips) do
    ip = Enum.find(ips, &(tuple_size(&1) == 4)) || hd(ips)

    request
    |> Req.Request.put_private(:mythweaver_ip, ip)
    |> Map.replace!(:adapter, __MODULE__)
  end

  defp cap_body(%{into: nil} = request, opts) do
    max = opts[:max_body]

    into = fn {:data, data}, {req, resp} ->
      body = if is_binary(resp.body), do: resp.body, else: ""

      if byte_size(body) + byte_size(data) > max,
        do: {:halt, {req, Req.Response.put_private(resp, :mythweaver_oversize, true)}},
        else: {:cont, {req, %{resp | body: body <> data}}}
    end

    request
    |> Req.Request.put_private(:mythweaver_buffered, true)
    |> Map.replace!(:into, into)
  end

  defp cap_body(%{into: fun} = request, opts) when is_function(fun, 2) do
    max = opts[:max_stream]

    into = fn {:data, data}, {req, resp} ->
      total = Req.Response.get_private(resp, :mythweaver_bytes, 0) + byte_size(data)

      if total > max,
        do: {:halt, {req, Req.Response.put_private(resp, :mythweaver_oversize, true)}},
        else: fun.({:data, data}, {req, Req.Response.put_private(resp, :mythweaver_bytes, total)})
    end

    Map.replace!(request, :into, into)
  end

  defp cap_body(%{into: into}, _opts),
    do: raise(ArgumentError, "Mythweaver.Net.Guard supports into: nil or a 2-arity fun, got: #{inspect(into)}")

  # Req's adapter call once `pin/2` makes this module the adapter; `cap_body/2` has made `into` a fun.
  @doc false
  def run(%Req.Request{url: url, into: into} = request) do
    connect = Req.Request.get_option(request, :connect_options, [])
    ip = request.private.mythweaver_ip

    connect_opts = [
      hostname: request.private.mythweaver_host,
      mode: :passive,
      protocols: [:http1],
      transport_opts: [timeout: Keyword.get(connect, :timeout, 30_000), inet6: tuple_size(ip) == 8]
    ]

    timeouts = {
      Req.Request.get_option(request, :receive_timeout, 15_000),
      deadline(Req.Request.get_option(request, :request_timeout, :infinity))
    }

    case Mint.HTTP.connect(scheme(url.scheme), ip, url.port, connect_opts) do
      {:ok, conn} ->
        case Mint.HTTP.request(conn, method(request.method), target(url), headers(request), body(request.body)) do
          {:ok, conn, ref} ->
            {conn, result} = receive_response(conn, ref, into, {request, Req.Response.new()}, timeouts)
            Mint.HTTP.close(conn)
            result

          {:error, conn, error} ->
            Mint.HTTP.close(conn)
            {request, normalize_error(error)}
        end

      {:error, error} ->
        {request, normalize_error(error)}
    end
  end

  defp receive_response(conn, ref, into, acc, timeouts) do
    case recv(conn, timeouts) do
      {:ok, conn, responses} ->
        case handle_responses(responses, ref, into, acc) do
          {:cont, acc} -> receive_response(conn, ref, into, acc, timeouts)
          state -> {conn, result(state, acc, nil)}
        end

      # A body that runs until the server closes ends in `:done` just before the error.
      {:error, conn, error, responses} ->
        {conn, responses |> handle_responses(ref, into, acc) |> result(acc, error)}
    end
  end

  defp recv(conn, {receive_timeout, deadline}) do
    case recv_timeout(receive_timeout, deadline) do
      :expired -> {:error, conn, %Req.TransportError{reason: :timeout}, []}
      timeout -> Mint.HTTP.recv(conn, 0, timeout)
    end
  end

  defp result({:done, acc}, _acc, _error), do: acc
  defp result({:error, error}, {request, _resp}, _error), do: {request, normalize_error(error)}
  defp result({:cont, {request, _resp}}, _acc, error), do: {request, normalize_error(error)}

  # `{:done, acc}` also stands for `into` halting: either way nothing more is read.
  defp handle_responses(responses, ref, into, acc) do
    Enum.reduce_while(responses, {:cont, acc}, fn
      # Clearing the headers lets a final response's replace an informational (1xx) one's.
      {:status, ^ref, status}, {:cont, {req, resp}} ->
        {:cont, {:cont, {req, %{resp | status: status, headers: %{}}}}}

      # `:headers` after the body are the trailers, which nothing here reads.
      {:headers, ^ref, fields}, {:cont, {req, %{headers: headers} = resp}} when map_size(headers) == 0 ->
        {:cont, {:cont, {req, %{resp | headers: Req.Response.new(headers: fields).headers}}}}

      {:data, ^ref, data}, {:cont, acc} ->
        case into.({:data, data}, acc) do
          {:cont, acc} -> {:cont, {:cont, acc}}
          {:halt, acc} -> {:halt, {:done, acc}}
        end

      {:done, ^ref}, {:cont, acc} ->
        {:halt, {:done, acc}}

      {:error, ^ref, error}, _state ->
        {:halt, {:error, error}}

      _other, state ->
        {:cont, state}
    end)
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(ms) when is_integer(ms), do: System.monotonic_time(:millisecond) + ms

  defp recv_timeout(receive_timeout, :infinity), do: receive_timeout

  defp recv_timeout(receive_timeout, deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      left when left <= 0 -> :expired
      left -> min(receive_timeout, left)
    end
  end

  defp scheme("http"), do: :http
  defp scheme("https"), do: :https
  defp scheme(other), do: raise(ArgumentError, "Mythweaver.Net.Guard supports http and https, got: #{inspect(other)}")

  defp method(method), do: method |> to_string() |> String.upcase()

  defp target(%URI{path: path, query: query}) do
    path = if path in [nil, ""], do: "/", else: path
    if query, do: path <> "?" <> query, else: path
  end

  defp headers(request), do: for({name, values} <- request.headers, value <- List.wrap(values), do: {name, value})

  defp body(body) when is_nil(body) or is_binary(body) or is_list(body), do: body

  defp body(body),
    do: raise(ArgumentError, "Mythweaver.Net.Guard supports an iodata or nil body, got: #{inspect(body)}")

  defp normalize_error(%Mint.TransportError{reason: reason}), do: %Req.TransportError{reason: reason}
  defp normalize_error(%Mint.HTTPError{reason: reason}), do: %Req.HTTPError{protocol: :http1, reason: reason}
  defp normalize_error(error), do: error

  @doc false
  def body_cap({req, resp}) do
    req = if req.private[:mythweaver_buffered], do: %{req | into: nil}, else: req

    if Req.Response.get_private(resp, :mythweaver_oversize),
      do: {req, %Error{reason: :too_large, host: req.private[:mythweaver_host]}},
      else: {req, resp}
  end

  @doc "Whether `ip` is a public internet address (not private, local, reserved or multicast)."
  @spec public?(:inet.ip_address()) :: boolean()
  def public?({0, _, _, _}), do: false
  def public?({10, _, _, _}), do: false
  def public?({100, b, _, _}) when b in 64..127, do: false
  def public?({127, _, _, _}), do: false
  def public?({169, 254, _, _}), do: false
  def public?({172, b, _, _}) when b in 16..31, do: false
  def public?({192, 0, 0, _}), do: false
  def public?({192, 168, _, _}), do: false
  def public?({198, b, _, _}) when b in 18..19, do: false
  def public?({a, _, _, _}) when a >= 224, do: false
  def public?({_, _, _, _}), do: true
  def public?({0, 0, 0, 0, 0, 0, 0, 0}), do: false
  def public?({0, 0, 0, 0, 0, 0, 0, 1}), do: false
  def public?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: public?(embedded(hi, lo))
  def public?({0x64, 0xFF9B, 0, 0, 0, 0, hi, lo}), do: public?(embedded(hi, lo))
  def public?({a, _, _, _, _, _, _, _}) when a in 0xFC00..0xFDFF, do: false
  def public?({a, _, _, _, _, _, _, _}) when a in 0xFE80..0xFEBF, do: false
  def public?({a, _, _, _, _, _, _, _}) when a in 0xFF00..0xFFFF, do: false
  def public?({_, _, _, _, _, _, _, _}), do: true

  defp embedded(hi, lo), do: {div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)}
end
