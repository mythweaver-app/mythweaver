defmodule Mythweaver.Moderation.GeoIPTest do
  use ExUnit.Case, async: true

  alias Mythweaver.Moderation.GeoIP

  # MaxMind's public test databases (`test/fixtures/geoip`, `config/test.exs`).
  test "lookup/1 reads place from City and network from ASN" do
    assert %{"country" => "GB", "country_name" => "United Kingdom", "region" => "England", "city" => "London"} =
             GeoIP.lookup("81.2.69.142")

    assert %{"asn" => 1221, "org" => "Telstra Pty Ltd"} = GeoIP.lookup("1.128.0.1")
  end

  test "lookup/1 is nil for an address neither database knows, or not an address" do
    assert GeoIP.lookup("203.0.113.9") == nil
    assert GeoIP.lookup("not-an-ip") == nil
  end

  test "label/1 joins place and network, leaving out what is missing" do
    london = %{"city" => "London", "region" => "England", "country" => "GB"}
    telstra = %{"asn" => 1221, "org" => "Telstra Pty Ltd"}

    assert GeoIP.label(london) == "London, England, GB"
    assert GeoIP.label(telstra) == "AS1221 Telstra Pty Ltd"
    assert GeoIP.label(Map.merge(london, telstra)) == "London, England, GB · AS1221 Telstra Pty Ltd"
    assert GeoIP.label(%{"country" => "AU", "asn" => 1221}) == "AU · AS1221"
    assert GeoIP.label(%{}) == nil
    assert GeoIP.label(nil) == nil
  end
end
