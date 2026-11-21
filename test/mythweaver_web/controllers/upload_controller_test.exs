defmodule MythweaverWeb.UploadControllerTest do
  # Not async: the proxy cases change the application's attachments config.
  use MythweaverWeb.ConnCase

  alias Mythweaver.Attachments
  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Attachments.Storage.Local

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
       )

  setup do
    {:ok, attachment} = Attachments.store_binary(@png)
    %{attachment: attachment, url: Attachments.url(attachment, :full)}
  end

  defp put_config(changes) do
    original = Application.get_env(:mythweaver, Attachments)
    Application.put_env(:mythweaver, Attachments, Keyword.merge(original, changes))
    on_exit(fn -> Application.put_env(:mythweaver, Attachments, original) end)
  end

  test "a sealed link serves the file without a session, cacheable until it expires", %{conn: conn, url: url} do
    "/uploads/" <> token = url
    {:ok, _key, exp} = Local.open(token)
    conn = get(conn, url)

    assert response(conn, 200) == @png
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert get_resp_header(conn, "set-cookie") == []
    assert ["private, max-age=" <> rest] = get_resp_header(conn, "cache-control")
    assert {max_age, ", immutable"} = Integer.parse(rest)
    assert_in_delta max_age, exp - System.os_time(:second), 2
  end

  test "a bare key, an altered or expired token is a 404", %{conn: conn, attachment: a, url: url} do
    now = System.os_time(:second)
    "/uploads/" <> token = url
    <<first, rest::binary>> = token
    altered = "/uploads/" <> <<if(first == ?A, do: ?B, else: ?A)>> <> rest

    for path <- ["/uploads/" <> a.key, altered, Local.signed_url(a.key, now - 20, now - 1)] do
      assert conn |> get(path) |> response(404)
    end
  end

  test "a sealed key with no ready local attachment is a 404", %{conn: conn} do
    exp = System.os_time(:second) + 60
    assert conn |> get(Local.signed_url("attachments/../../etc/passwd", 0, exp)) |> response(404)
  end

  test "behind xi only the proxy serves images; other kinds still load here", %{conn: conn, url: url} do
    put_config(proxy: :xtandard)
    {:ok, notes} = Attachments.store_binary("# Notes", filename: "notes.md", kinds: Attachment.kinds())

    assert conn |> get(url) |> response(404)
    assert build_conn() |> get(Attachments.url(notes, :full)) |> response(200) == "# Notes"
  end

  test "behind Cloudflare or Fastly an image needs the CDN's origin secret", %{conn: conn, url: url} do
    for proxy <- [:cloudflare, :fastly] do
      put_config(proxy: proxy, uploads_origin_secret: "s3cret")

      assert conn |> get(url) |> response(404)
      assert conn |> put_req_header("x-mythweaver-origin-secret", "wrong") |> get(url) |> response(404)
      conn = build_conn() |> put_req_header("x-mythweaver-origin-secret", "s3cret") |> get(url)
      assert response(conn, 200) == @png
      assert ["public, max-age=" <> _] = get_resp_header(conn, "cache-control")
    end
  end

  test "a file opens or downloads under its own name; a text document is UTF-8", %{conn: conn} do
    kinds = Attachment.kinds()
    {:ok, file} = Attachments.store_binary(<<0, 1, 2>>, filename: "rêve.zip", kinds: kinds)
    resp = get(conn, Attachments.url(file, :full))

    assert response(resp, 200) == <<0, 1, 2>>
    assert get_resp_header(resp, "content-type") == ["application/octet-stream"]

    assert get_resp_header(resp, "content-disposition") ==
             [~s(attachment; filename="download"; filename*=UTF-8''r%C3%AAve.zip)]

    {:ok, notes} = Attachments.store_binary("# Notes", filename: "notes.md", kinds: kinds)
    resp = get(build_conn(), Attachments.url(notes, :full))
    assert get_resp_header(resp, "content-type") == ["text/markdown; charset=utf-8"]
    assert get_resp_header(resp, "content-disposition") == [~s(inline; filename="download"; filename*=UTF-8''notes.md)]
  end
end
