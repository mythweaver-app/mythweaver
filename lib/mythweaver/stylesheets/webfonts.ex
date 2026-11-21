defmodule Mythweaver.Stylesheets.Webfonts do
  @moduledoc """
  The font services whose stylesheet URLs a restricted user sheet may `@import`
  (`Mythweaver.Stylesheets.Policy`, while `appearance.allow_third_party_fonts` is on).

  A URL matches only as an exact `https` stylesheet URL on the service's own host, default port and
  no userinfo; any query string and fragment are allowed. Adding a service means one `@providers`
  entry, one `@sources` entry (the origins its stylesheets and font files load from, which
  `MythweaverWeb.ContentSecurityPolicy` grants) plus one `match/1` clause, e.g. Adobe Fonts: host
  `use.typekit.net`, path `/<kit id>.css`.
  """

  @providers [google: "Google Fonts"]

  @sources %{
    google: %{style: ["https://fonts.googleapis.com"], font: ["https://fonts.gstatic.com"]}
  }

  @doc "The display names of the permitted providers, in `@providers` order."
  @spec names() :: [String.t()]
  def names, do: Keyword.values(@providers)

  @doc "The origins every permitted provider's stylesheets (`style`) and font files (`font`) load from."
  @spec csp_sources() :: %{style: [String.t()], font: [String.t()]}
  def csp_sources do
    Enum.reduce(Keyword.keys(@providers), %{style: [], font: []}, fn provider, acc ->
      %{style: style, font: font} = Map.fetch!(@sources, provider)
      %{style: acc.style ++ style, font: acc.font ++ font}
    end)
  end

  @doc "The provider serving the stylesheet at `url`, or `nil` when `url` is not a permitted font stylesheet."
  @spec provider(String.t()) :: atom() | nil
  def provider(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", userinfo: nil, port: 443, host: host} = uri} when is_binary(host) ->
        match(%{uri | host: String.downcase(host, :ascii)})

      _ ->
        nil
    end
  end

  # One clause per provider in `@providers`: the exact stylesheet URLs it serves.
  defp match(%URI{host: "fonts.googleapis.com", path: path}) when path in ["/css", "/css2"], do: :google
  defp match(_uri), do: nil
end
