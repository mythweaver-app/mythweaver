defmodule MythweaverWeb.Signals do
  @moduledoc """
  The fingerprint signals of a request or a LiveView socket (`Mythweaver.Moderation.Fingerprints`):
  client IP (`MythweaverWeb.ClientIp`), user agent, Accept-Language (requests only), device id
  (`MythweaverWeb.DeviceCookie`) and browser fingerprint hash (`assets/js/fingerprint.ts`). Every
  value may be nil.
  """

  import Phoenix.LiveView, only: [get_connect_info: 2, get_connect_params: 1]

  alias MythweaverWeb.ClientIp
  alias Phoenix.LiveView.Socket

  @max_bytes 1024

  @type t :: %{
          ip: String.t() | nil,
          user_agent: String.t() | nil,
          language: String.t() | nil,
          device: String.t() | nil,
          fingerprint: String.t() | nil
        }

  @doc "The signals of `conn`, with the browser `fingerprint` it posted (or nil)."
  @spec from_conn(Plug.Conn.t(), String.t() | nil) :: t()
  def from_conn(%Plug.Conn{} = conn, fingerprint) do
    build(
      ClientIp.from_conn(conn),
      conn |> Plug.Conn.get_req_header("user-agent") |> List.first(),
      conn |> Plug.Conn.get_req_header("accept-language") |> List.first(),
      conn.assigns[:device_id],
      fingerprint
    )
  end

  @doc "The signals of a connected LiveView `socket` and its `session`."
  @spec from_socket(Socket.t(), map()) :: t()
  def from_socket(socket, session) do
    ip =
      case get_connect_info(socket, :peer_data) do
        %{address: address} -> ClientIp.client_ip(address, get_connect_info(socket, :x_headers) || [])
        _ -> nil
      end

    params = get_connect_params(socket) || %{}

    build(ip, get_connect_info(socket, :user_agent), nil, session["device_id"], params["fingerprint"])
  end

  defp build(ip, user_agent, language, device, fingerprint) do
    %{
      ip: ip,
      user_agent: truncate(user_agent),
      language: truncate(language),
      device: truncate(device),
      fingerprint: if(is_binary(fingerprint) and fingerprint =~ ~r/\A[0-9a-f]{32}\z/, do: fingerprint)
    }
  end

  defp truncate(value) when is_binary(value) and value != "" do
    if String.valid?(value), do: utf8_prefix(value, @max_bytes)
  end

  defp truncate(_value), do: nil

  # The longest prefix of whole codepoints within `max` bytes (the unique index's row limit).
  defp utf8_prefix(value, max) when byte_size(value) <= max, do: value

  defp utf8_prefix(value, max) do
    prefix = binary_part(value, 0, max)
    if String.valid?(prefix), do: prefix, else: utf8_prefix(value, max - 1)
  end
end
