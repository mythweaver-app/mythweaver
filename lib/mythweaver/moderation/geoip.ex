defmodule Mythweaver.Moderation.GeoIP do
  @moduledoc """
  MaxMind GeoLite2 City and ASN lookups for IP fingerprints (`Fingerprints.record/2`), shown on an
  account's moderation record.

  The databases are files in `dir/0`, fetched by `mix mythweaver.geoip.download`. Each one present
  at boot gets a `:locus` loader (`child_specs/0`), which re-reads the file when its mtime changes
  (checked every 30 s), so a re-download is picked up live; a database that first appears after
  boot needs a restart. With neither file there are no loaders, `lookup/1` returns nil and
  `enabled?/0` is false, so nothing shows GeoIP.
  """

  @databases [
    city: {:mythweaver_geoip_city, "GeoLite2-City.mmdb"},
    asn: {:mythweaver_geoip_asn, "GeoLite2-ASN.mmdb"}
  ]

  @attribution "This product includes GeoLite2 data created by MaxMind, available from https://www.maxmind.com."

  @doc "The MaxMind editions `mix mythweaver.geoip.download` fetches, saved as `<edition>.mmdb`."
  @spec editions() :: [String.t()]
  def editions, do: ["GeoLite2-City", "GeoLite2-ASN"]

  @doc "Where the databases live: `:geoip_dir` (`MYTHWEAVER_GEOIP_DIR`), else `priv/geoip`."
  @spec dir() :: Path.t()
  def dir, do: Application.get_env(:mythweaver, :geoip_dir) || Application.app_dir(:mythweaver, "priv/geoip")

  @doc "A loader for each database file present in `dir/0`."
  @spec child_specs() :: [Supervisor.child_spec()]
  def child_specs do
    for {id, path} <- present() do
      :locus.loader_child_spec(id, String.to_charlist(path))
    end
  end

  @doc "Whether either database is loaded."
  @spec enabled?() :: boolean()
  def enabled? do
    Enum.any?(@databases, fn {_, {id, _}} -> match?({:ok, _}, :locus.get_info(id)) end)
  end

  @doc "Waits until every loader `child_specs/0` would start has loaded its database."
  @spec await(timeout()) :: :ok
  def await(timeout) do
    for {id, _} <- present(), do: {:ok, _} = :locus.await_loader(id, timeout)
    :ok
  end

  @doc """
  What the databases know about `ip`, with string keys (it is stored in a JSON column): `"country"`
  (ISO code), `"country_name"`, `"region"`, `"city"`, `"asn"`, `"org"`. Unknown fields are left out;
  nil when nothing is known, no database is loaded or `ip` is not an address.
  """
  @spec lookup(String.t()) :: map() | nil
  def lookup(ip) do
    city = entry(:city, ip)
    asn = entry(:asn, ip)

    geo =
      %{
        "country" => get_in(city, ["country", "iso_code"]),
        "country_name" => get_in(city, ["country", "names", "en"]),
        "region" => city |> get_in(["subdivisions"]) |> first() |> get_in(["names", "en"]),
        "city" => get_in(city, ["city", "names", "en"]),
        "asn" => get_in(asn, ["autonomous_system_number"]),
        "org" => get_in(asn, ["autonomous_system_organization"])
      }
      |> Map.reject(fn {_, value} -> is_nil(value) end)

    if geo != %{}, do: geo
  end

  @doc """
  One line for a stored geo map: the place (city, region, country code) and the network
  (`AS<number> <org>`), joined by " · ". Nil for nil or an empty map.
  """
  @spec label(map() | nil) :: String.t() | nil
  def label(nil), do: nil

  def label(geo) do
    place = Enum.join(Enum.reject([geo["city"], geo["region"], geo["country"]], &is_nil/1), ", ")
    network = if geo["asn"], do: String.trim("AS#{geo["asn"]} #{geo["org"]}")

    case Enum.reject([place, network], &(&1 in [nil, ""])) do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  @doc "The credit GeoLite2's licence requires wherever its data is shown."
  @spec attribution() :: String.t()
  def attribution, do: @attribution

  defp present do
    for {_, {id, file}} <- @databases,
        path = Path.join(dir(), file),
        File.regular?(path),
        do: {id, path}
  end

  defp entry(database, ip) do
    {id, _} = @databases[database]

    case :locus.lookup(id, ip) do
      {:ok, entry} -> entry
      _ -> nil
    end
  end

  defp first([head | _]), do: head
  defp first(_), do: nil
end
