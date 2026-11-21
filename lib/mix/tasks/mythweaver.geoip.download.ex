defmodule Mix.Tasks.Mythweaver.Geoip.Download do
  @shortdoc "Downloads the GeoLite2 City and ASN databases for moderation"

  @moduledoc """
  Downloads MaxMind's GeoLite2 City and ASN databases, which add places and networks to the IP
  addresses on an account's moderation record (`Mythweaver.Moderation.GeoIP`).

      MYTHWEAVER_MAXMIND_ACCOUNT_ID=… MYTHWEAVER_MAXMIND_LICENSE_KEY=… mix mythweaver.geoip.download

  Without both variables it downloads nothing and exits normally, so `mix setup` and builds never
  fail on it; the app then shows no GeoIP data.

  A file less than a day old is kept: GeoLite accounts get 30 downloads a day. The licence wants
  data no older than 30 days, so re-run it at least that often.

  ## Options

    * `--dir` - where to save the `.mmdb` files (`MYTHWEAVER_GEOIP_DIR`, else `priv/geoip`)
    * `--force` - download even when a file is less than a day old
  """

  use Mix.Task

  alias Mythweaver.Moderation.GeoIP

  @fresh_seconds 24 * 60 * 60

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [dir: :string, force: :boolean])
    dir = opts[:dir] || System.get_env("MYTHWEAVER_GEOIP_DIR") || "priv/geoip"

    case credentials() do
      nil ->
        Mix.shell().info(
          "GeoIP: MYTHWEAVER_MAXMIND_ACCOUNT_ID and MYTHWEAVER_MAXMIND_LICENSE_KEY are not both set; " <>
            "skipping the GeoLite2 download. Moderation pages show no GeoIP data."
        )

        :ok

      credentials ->
        {:ok, _} = Application.ensure_all_started(:req)
        File.mkdir_p!(dir)
        Enum.each(GeoIP.editions(), &download(&1, Path.join(dir, "#{&1}.mmdb"), credentials, opts))
    end
  end

  defp credentials do
    account = "MYTHWEAVER_MAXMIND_ACCOUNT_ID" |> System.get_env("") |> String.trim()
    key = "MYTHWEAVER_MAXMIND_LICENSE_KEY" |> System.get_env("") |> String.trim()
    if account != "" and key != "", do: {account, key}
  end

  defp download(edition, dest, {account, key}, opts) do
    if fresh?(dest) and !opts[:force] do
      Mix.shell().info("GeoIP: #{edition} is less than a day old; skipping (--force downloads anyway).")
    else
      # MaxMind redirects to a presigned R2 URL; Req drops the auth header on that cross-host hop.
      # `decode_body: false` keeps Req from unpacking the tarball itself.
      [
        url: "https://download.maxmind.com/geoip/databases/#{edition}/download?suffix=tar.gz",
        auth: {:basic, "#{account}:#{key}"},
        decode_body: false,
        retry: :transient,
        receive_timeout: 120_000
      ]
      |> Keyword.merge(Application.get_env(:mythweaver, :geoip_req_options, []))
      |> Req.get()
      |> save(edition, dest)
    end
  end

  defp save({:ok, %Req.Response{status: 200, body: body}}, edition, dest) do
    with {:ok, files} <- :erl_tar.extract({:binary, body}, [:compressed, :memory]),
         {_, mmdb} <- Enum.find(files, fn {name, _} -> name |> to_string() |> String.ends_with?(".mmdb") end) do
      # Renamed into place, so the running app's loader never reads a half-written file.
      File.write!(dest <> ".tmp", mmdb)
      File.rename!(dest <> ".tmp", dest)
      Mix.shell().info("GeoIP: #{edition} saved to #{dest}")
    else
      _ -> Mix.raise("GeoIP: the #{edition} download held no .mmdb file.")
    end
  end

  defp save({:ok, %Req.Response{status: 401}}, edition, _dest) do
    Mix.raise(
      "GeoIP: MaxMind refused the credentials for #{edition} (HTTP 401); " <>
        "check MYTHWEAVER_MAXMIND_ACCOUNT_ID and MYTHWEAVER_MAXMIND_LICENSE_KEY."
    )
  end

  defp save({:ok, %Req.Response{status: status}}, edition, _dest) do
    Mix.raise("GeoIP: downloading #{edition} failed with HTTP #{status}.")
  end

  defp save({:error, exception}, edition, _dest) do
    Mix.raise("GeoIP: downloading #{edition} failed: #{Exception.message(exception)}")
  end

  defp fresh?(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> System.os_time(:second) - mtime < @fresh_seconds
      {:error, _} -> false
    end
  end
end
