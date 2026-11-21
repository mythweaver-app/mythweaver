defmodule MythweaverWeb.UploadController do
  @moduledoc """
  Serves locally stored attachments (`Mythweaver.Attachments.Storage.Local`) at `/uploads/<token>`,
  a sealed key and expiry (`Local.open/1`). The link is the credential, not a session, so a browser,
  an image proxy or a CDN fetching on its behalf all get the same answer; who may see a file is
  decided where the link is rendered (`Mythweaver.Attachments.url/2`). The key is looked up rather
  than joined onto the root, so only a recorded, ready attachment is ever read. Images behind an
  image proxy are only for the proxy (`Attachments.served_directly?/2`). Anything else (a
  malformed, forged or expired token, an unknown key, an image asked for around its proxy) is a
  plain 404, which reveals nothing.

  A response fetched by an image proxy or CDN for itself (it sends the origin secret) is `public`;
  any other is `private`, so a shared cache never keeps a reader's file. Either is cached only until
  the link expires.
  `nosniff` keeps a browser from treating a stored file as anything but its type; a text document
  is served as UTF-8. The link names no file, so the response does: an unrecognised `:file` (always
  `application/octet-stream`) downloads under its own filename, and anything else opens in place
  under it.
  """

  use MythweaverWeb, :controller

  alias Mythweaver.Attachments
  alias Mythweaver.Attachments.Storage.Local

  def show(conn, %{"token" => token}) do
    with {:ok, key, expires_at} <- Local.open(token),
         %{} = attachment <- Attachments.get_local_by_key(key),
         true <- Attachments.served_directly?(attachment, origin_secret(conn)) do
      conn
      |> put_resp_content_type(attachment.content_type, charset(attachment.content_type))
      |> put_disposition(attachment)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header(
        "cache-control",
        "#{cache_scope(conn)}, max-age=#{expires_at - System.os_time(:second)}, immutable"
      )
      |> send_file(200, Local.path(attachment.key))
    else
      _ -> send_resp(conn, 404, "Not Found")
    end
  end

  defp cache_scope(conn), do: if(origin_secret(conn), do: "public", else: "private")

  defp origin_secret(conn), do: conn |> get_req_header("x-mythweaver-origin-secret") |> List.first()

  defp charset("text/" <> _), do: "utf-8"
  defp charset(_type), do: nil

  defp put_disposition(conn, %{kind: kind, filename: name}) when is_binary(name) and name != "" do
    type = if kind == :file, do: "attachment", else: "inline"
    encoded = URI.encode(name, &URI.char_unreserved?/1)
    put_resp_header(conn, "content-disposition", ~s(#{type}; filename="download"; filename*=UTF-8''#{encoded}))
  end

  defp put_disposition(conn, %{kind: :file}), do: put_resp_header(conn, "content-disposition", "attachment")
  defp put_disposition(conn, _attachment), do: conn
end
