defmodule Mythweaver.StallingPlug do
  @moduledoc """
  A real HTTP endpoint (served by Bandit in a test) that streams one content delta and then goes
  silent. `Req.Test` delivers a stub's chunks only after the plug returns, so it cannot model a
  stream that stalls after a token; this can.

  Opts: `:test`, the pid told `{:chunk_sent, handler_pid}` once the delta is out. The connection is
  held until the handler receives `:release`, or for 5 s.
  """
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    conn = Plug.Conn.send_chunked(conn, 200)
    frame = Jason.encode!(%{choices: [%{index: 0, delta: %{content: "Hi"}, finish_reason: nil}]})
    {:ok, conn} = Plug.Conn.chunk(conn, "data: " <> frame <> "\n\n")
    send(opts[:test], {:chunk_sent, self()})

    receive do
      :release -> conn
    after
      5_000 -> conn
    end
  end
end
