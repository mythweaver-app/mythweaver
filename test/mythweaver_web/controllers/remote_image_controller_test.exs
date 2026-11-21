defmodule MythweaverWeb.RemoteImageControllerTest do
  use MythweaverWeb.ConnCase, async: true

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Settings
  alias MythweaverWeb.RemoteImage

  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13>>

  # Fetched images are cached by URL, so each test proxies its own.
  defp url!, do: "https://images.example/#{System.unique_integer([:positive])}.png"

  defp stub!(type, body) do
    Req.Test.stub(MythweaverWeb.RemoteImageController, fn conn ->
      conn |> Plug.Conn.put_resp_content_type(type, nil) |> Plug.Conn.send_resp(200, body)
    end)
  end

  defp mode!(mode) do
    admin = Scope.for_user(register_user!())
    assert :ok = Settings.put(admin, :site, "appearance.remote_images", mode)
  end

  describe "show" do
    test "proxies an image", %{conn: conn} do
      stub!("image/png", @png)
      conn = get(conn, RemoteImage.path(url!()))

      assert response(conn, 200) == @png
      assert [type] = get_resp_header(conn, "content-type")
      assert type =~ "image/png"
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert ["private" <> _] = get_resp_header(conn, "cache-control")
      assert get_resp_header(conn, "set-cookie") == []
    end

    test "serves a repeat request from the cache", %{conn: conn} do
      test = self()

      Req.Test.stub(MythweaverWeb.RemoteImageController, fn conn ->
        send(test, :fetched)
        conn |> Plug.Conn.put_resp_content_type("image/png", nil) |> Plug.Conn.send_resp(200, @png)
      end)

      path = RemoteImage.path(url!())
      assert conn |> get(path) |> response(200) == @png
      assert build_conn() |> get(path) |> response(200) == @png
      assert_received :fetched
      refute_received :fetched
    end

    test "answers 503 while every fetch slot is busy", %{conn: conn} do
      test = self()

      Req.Test.stub(MythweaverWeb.RemoteImageController, fn conn ->
        send(test, {:started, self()})

        receive do
          :go -> conn |> Plug.Conn.put_resp_content_type("image/png", nil) |> Plug.Conn.send_resp(200, @png)
        end
      end)

      # `MythweaverWeb.RemoteImage.TaskSupervisor` runs at most 8.
      busy = for _ <- 1..8, do: Task.async(fn -> get(build_conn(), RemoteImage.path(url!())) end)

      fetchers =
        for _ <- busy do
          assert_receive {:started, pid}, 5_000
          pid
        end

      assert conn |> get(RemoteImage.path(url!())) |> response(503)

      Enum.each(fetchers, &send(&1, :go))
      for task <- busy, do: assert(task |> Task.await() |> response(200) == @png)
    end

    test "refuses SVG", %{conn: conn} do
      stub!("image/svg+xml", "<svg></svg>")
      assert conn |> get(RemoteImage.path(url!())) |> response(404) == "Not Found"
    end

    test "refuses a forged token", %{conn: conn} do
      assert conn |> get("/remote-images/forged") |> response(404) == "Not Found"
    end

    test "off: not found", %{conn: conn} do
      mode!(:off)
      stub!("image/png", @png)
      assert conn |> get(RemoteImage.path(url!())) |> response(404)
    end

    test "direct: redirects to the image", %{conn: conn} do
      mode!(:direct)
      url = url!()
      assert conn |> get(RemoteImage.path(url)) |> redirected_to(302) == url
    end
  end
end
