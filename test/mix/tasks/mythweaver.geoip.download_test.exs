defmodule Mix.Tasks.Mythweaver.Geoip.DownloadTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Mythweaver.Geoip.Download
  alias Mythweaver.Moderation.GeoIP

  @vars ~w(MYTHWEAVER_MAXMIND_ACCOUNT_ID MYTHWEAVER_MAXMIND_LICENSE_KEY)

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)
    end)

    dir = Path.join(System.tmp_dir!(), "mythweaver-geoip-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    %{dir: dir}
  end

  test "without credentials it skips and writes nothing", %{dir: dir} do
    System.put_env("MYTHWEAVER_MAXMIND_ACCOUNT_ID", "  ")

    assert :ok = Download.run(["--dir", dir])

    assert_received {:mix_shell, :info, [message]}
    assert message =~ "skipping the GeoLite2 download"
    refute File.exists?(dir)
  end

  test "downloads each edition with basic auth and skips fresh files on the next run", %{dir: dir} do
    put_credentials()
    test = self()

    Req.Test.stub(GeoIP, fn conn ->
      ["geoip", "databases", edition, "download"] = conn.path_info
      send(test, {:request, edition, Plug.Conn.get_req_header(conn, "authorization")})
      Plug.Conn.send_resp(conn, 200, tarball(edition))
    end)

    Download.run(["--dir", dir])

    expected_auth = ["Basic " <> Base.encode64("id:key")]

    for edition <- ~w(GeoLite2-City GeoLite2-ASN) do
      assert_received {:request, ^edition, ^expected_auth}
      assert File.read!(Path.join(dir, "#{edition}.mmdb")) == "#{edition}-bytes"
    end

    refute File.exists?(Path.join(dir, "GeoLite2-City.mmdb.tmp"))

    Download.run(["--dir", dir])

    refute_received {:request, _, _}
    assert_received {:mix_shell, :info, ["GeoIP: GeoLite2-City is less than a day old" <> _]}
  end

  test "a refused licence key raises naming both variables", %{dir: dir} do
    put_credentials()
    Req.Test.stub(GeoIP, &Plug.Conn.send_resp(&1, 401, "Unauthorized"))

    error = assert_raise Mix.Error, fn -> Download.run(["--dir", dir]) end
    assert error.message =~ "MYTHWEAVER_MAXMIND_ACCOUNT_ID"
    assert error.message =~ "MYTHWEAVER_MAXMIND_LICENSE_KEY"
  end

  defp put_credentials do
    System.put_env("MYTHWEAVER_MAXMIND_ACCOUNT_ID", "id")
    System.put_env("MYTHWEAVER_MAXMIND_LICENSE_KEY", " key ")
  end

  # The layout MaxMind ships: one dated directory holding the database beside its licence files.
  defp tarball(edition) do
    path = Path.join(System.tmp_dir!(), "geoip-#{System.unique_integer([:positive])}.tar.gz")

    :ok =
      :erl_tar.create(
        String.to_charlist(path),
        [
          {~c"#{edition}_20261110/LICENSE.txt", "licence"},
          {~c"#{edition}_20261110/#{edition}.mmdb", "#{edition}-bytes"}
        ],
        [:compressed]
      )

    body = File.read!(path)
    File.rm!(path)
    body
  end
end
