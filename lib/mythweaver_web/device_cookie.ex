defmodule MythweaverWeb.DeviceCookie do
  @moduledoc """
  Gives every browser a long-lived signed device id (`_mythweaver_device`), assigned as `:device_id`
  and copied into the session so LiveViews (`MythweaverWeb.Signals.from_socket/2`) read it too.
  Account fingerprints and device bans (`Mythweaver.Moderation`) key on it. Login renews the session,
  so the next request puts the id back.
  """

  @behaviour Plug

  import Plug.Conn

  @cookie "_mythweaver_device"
  @max_age 400 * 24 * 60 * 60

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = fetch_cookies(conn, signed: [@cookie])

    {conn, id} =
      case conn.cookies[@cookie] do
        id when is_binary(id) ->
          if id =~ ~r/\A[A-Za-z0-9_-]{22}\z/, do: {conn, id}, else: new_device(conn)

        _ ->
          new_device(conn)
      end

    conn = assign(conn, :device_id, id)
    if get_session(conn, :device_id) == id, do: conn, else: put_session(conn, :device_id, id)
  end

  defp new_device(conn) do
    id = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

    conn =
      put_resp_cookie(conn, @cookie, id, sign: true, max_age: @max_age, same_site: "Lax", http_only: true)

    {conn, id}
  end
end
