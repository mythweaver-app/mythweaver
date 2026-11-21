defmodule MythweaverWeb.ClientIpTest do
  use ExUnit.Case, async: true

  alias MythweaverWeb.ClientIp

  @loopback {127, 0, 0, 1}

  test "an untrusted peer is the client, whatever it forwards" do
    assert ClientIp.client_ip({198, 51, 100, 4}, [{"x-forwarded-for", "1.2.3.4"}]) == "198.51.100.4"
  end

  test "behind a trusted proxy the rightmost forwarded entry is the client" do
    headers = [{"x-forwarded-for", "9.9.9.9, 203.0.113.7"}]
    assert ClientIp.client_ip(@loopback, headers) == "203.0.113.7"
  end

  test "trusted entries in the forwarded chain are skipped" do
    headers = [{"x-forwarded-for", "203.0.113.7, 127.0.0.1"}]
    assert ClientIp.client_ip(@loopback, headers) == "203.0.113.7"
  end

  test "a trusted peer without a forwarded header records no address" do
    assert ClientIp.client_ip(@loopback, []) == nil
  end

  test "an unparseable forwarded entry records no address" do
    assert ClientIp.client_ip(@loopback, [{"x-forwarded-for", "203.0.113.7, not-an-ip"}]) == nil
  end

  test "an IPv4-mapped IPv6 peer is reported as IPv4" do
    assert ClientIp.client_ip({0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7107}, []) == "203.0.113.7"
  end

  test "no peer is no address" do
    assert ClientIp.client_ip(nil, [{"x-forwarded-for", "203.0.113.7"}]) == nil
  end
end

defmodule MythweaverWeb.ClientIpConfigTest do
  # Changes the global `:trusted_proxies` env, so it must not run alongside other tests.
  use ExUnit.Case, async: false

  alias MythweaverWeb.ClientIp

  setup do
    previous = Application.get_env(:mythweaver, :trusted_proxies)

    on_exit(fn ->
      Application.put_env(:mythweaver, :trusted_proxies, previous)
      ClientIp.load_config!()
    end)
  end

  test "a CIDR range trusts the proxies inside it" do
    headers = [{"x-forwarded-for", "203.0.113.7"}]
    assert ClientIp.client_ip({10, 1, 2, 3}, headers) == "10.1.2.3"

    Application.put_env(:mythweaver, :trusted_proxies, ["127.0.0.0/8", "10.0.0.0/8"])
    ClientIp.load_config!()

    assert ClientIp.client_ip({10, 1, 2, 3}, headers) == "203.0.113.7"
    assert ClientIp.client_ip({11, 1, 2, 3}, headers) == "11.1.2.3"
  end

  test "a malformed entry raises, naming the env var" do
    for entry <- ["10.0.0.0/33", "not-an-ip", "10.0.0.0/8x"] do
      Application.put_env(:mythweaver, :trusted_proxies, [entry])
      assert_raise ArgumentError, ~r/MYTHWEAVER_TRUSTED_PROXIES/, fn -> ClientIp.load_config!() end
    end
  end

  test "IPv6 ranges are trusted" do
    Application.put_env(:mythweaver, :trusted_proxies, ["10.0.0.0/8", "::1", "fd00::/8"])
    assert ClientIp.load_config!() == :ok

    headers = [{"x-forwarded-for", "203.0.113.7"}]
    assert ClientIp.client_ip({0xFD00, 0, 0, 0, 0, 0, 0, 1}, headers) == "203.0.113.7"
    assert ClientIp.client_ip({0xFE00, 0, 0, 0, 0, 0, 0, 1}, headers) == "fe00::1"
  end
end
