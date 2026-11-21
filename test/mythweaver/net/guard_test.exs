defmodule Mythweaver.Net.GuardTest do
  use ExUnit.Case, async: true

  alias Mythweaver.Net.Guard

  defmodule Echo do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%{request_path: "/stream"} = conn, _opts) do
      conn = send_chunked(conn, 200)
      {:ok, conn} = chunk(conn, "a")
      {:ok, conn} = chunk(conn, "b")
      {:ok, conn} = chunk(conn, "c")
      conn
    end

    def call(%{request_path: "/big"} = conn, _opts), do: send_resp(conn, 200, String.duplicate("x", 100))
    def call(conn, _opts), do: send_resp(conn, 200, conn |> get_req_header("host") |> Enum.join())
  end

  # A loopback server; `private: :allow` (or a fun) lets the guard reach it for real.
  defp serve!(ip) do
    pid = start_supervised!({Bandit, plug: Echo, ip: ip, port: 0, startup_log: false})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end

  defp received_data(acc) do
    receive do
      {:data, data} -> received_data(acc <> data)
    after
      0 -> acc
    end
  end

  defp guarded(url, opts), do: [url: url, retry: false] |> Req.new() |> Guard.attach(opts)

  describe "guard" do
    test "public?/1 refuses private, local and mapped addresses" do
      for ip <- [
            {127, 0, 0, 1},
            {10, 1, 2, 3},
            {169, 254, 169, 254},
            {100, 64, 0, 1},
            {0, 0, 0, 0, 0, 0, 0, 1},
            {0xFD00, 0, 0, 0, 0, 0, 0, 1},
            {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}
          ] do
        refute Guard.public?(ip), inspect(ip)
      end

      assert Guard.public?({93, 184, 216, 34})
    end

    test "an IP literal on a private address is refused before connecting" do
      assert {:error, %Guard.Error{reason: :private_address, host: "127.0.0.1"}} =
               [url: "http://127.0.0.1:1/x", retry: false]
               |> Req.new()
               |> Guard.attach(private: :deny, max_body: 10)
               |> Req.get()
    end

    test "a name resolving to a private address is refused" do
      assert {:error, %Guard.Error{reason: :private_address, host: "localhost"}} =
               [url: "http://localhost:1/x", retry: false]
               |> Req.new()
               |> Guard.attach(private: :deny, max_body: 10)
               |> Req.get()
    end

    test "connects to the address it checked, naming the host in Host" do
      port = serve!({127, 0, 0, 1})

      assert {:ok, %Req.Response{status: 200, body: body}} =
               "http://localhost:#{port}/host" |> guarded(private: :allow, max_body: 1000) |> Req.get()

      assert body == "localhost:#{port}"
    end

    test "a private policy fun is asked once the host turns out private" do
      port = serve!({127, 0, 0, 1})
      test = self()

      policy = fn ->
        send(test, :asked)
        :allow
      end

      assert {:ok, %{status: 200}} =
               "http://127.0.0.1:#{port}/" |> guarded(private: policy, max_body: 1000) |> Req.get()

      assert_received :asked
    end

    test "an into fun receives the streamed body" do
      port = serve!({127, 0, 0, 1})
      test = self()

      into = fn {:data, data}, acc ->
        send(test, {:data, data})
        {:cont, acc}
      end

      assert {:ok, %{status: 200}} =
               "http://127.0.0.1:#{port}/stream" |> guarded(private: :allow, max_body: 1000) |> Req.get(into: into)

      assert received_data("") == "abc"
    end

    test "a buffered body over max_body is refused" do
      port = serve!({127, 0, 0, 1})

      assert {:error, %Guard.Error{reason: :too_large, host: "127.0.0.1"}} =
               "http://127.0.0.1:#{port}/big" |> guarded(private: :allow, max_body: 10) |> Req.get()
    end

    test "an IPv6 address is reached over IPv6" do
      loopback = {0, 0, 0, 0, 0, 0, 0, 1}

      # Some CI hosts have no IPv6 loopback.
      with {:ok, socket} <- :gen_tcp.listen(0, [:inet6, ip: loopback]) do
        :gen_tcp.close(socket)
        port = serve!(loopback)

        assert {:ok, %{status: 200, body: body}} =
                 "http://[::1]:#{port}/host" |> guarded(private: :allow, max_body: 1000) |> Req.get()

        assert body == "[::1]:#{port}"
      end
    end
  end
end
