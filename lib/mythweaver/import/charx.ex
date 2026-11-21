defmodule Mythweaver.Import.Charx do
  @moduledoc """
  Reads a CHARX file: a zip (possibly with a prefix before the first local header) holding
  `card.json` and assets. The first `icon` asset (preferring `name == "main"`) stored inside the zip
  becomes the avatar; every other asset is dropped with a warning. Only `card.json` and the chosen
  icon are ever inflated, so other entries cost nothing however large they unzip.
  """

  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.Format
  alias Mythweaver.Import.Card
  alias Mythweaver.Import.Text

  @prefixes ["embeded://", "embedded://", "__asset:"]

  @spec card(binary()) :: {:ok, Card.t()} | {:error, String.t()}
  def card(bytes) do
    bytes = strip_prefix(bytes)

    with {:ok, files} <- extract(bytes, ["card.json"]),
         {:ok, raw} <- fetch_card(files),
         {:ok, json} <- decode(raw),
         {:ok, card} <- Card.normalize(json) do
      assets = json |> Text.map() |> Map.get("data") |> Text.map() |> Map.get("assets")
      assets = if is_list(assets), do: Enum.filter(assets, &is_map/1), else: []
      {avatar, used} = avatar(assets, bytes)
      extra = length(assets) - used

      warnings =
        if extra > 0,
          do:
            card.warnings ++
              [
                dpngettext(
                  "import_export",
                  "status: import warning, a character card's extra assets were ignored",
                  "Ignored %{asset_count} extra asset.",
                  "Ignored %{asset_count} extra assets.",
                  extra,
                  asset_count: Format.number(extra)
                )
              ],
          else: card.warnings

      {:ok, %{card | avatar: avatar, warnings: warnings}}
    end
  end

  defp strip_prefix(bytes) do
    case :binary.match(bytes, "PK\x03\x04") do
      {pos, _len} -> binary_part(bytes, pos, byte_size(bytes) - pos)
      :nomatch -> bytes
    end
  end

  # Inflates only the entries named `names`, as `%{name => data}`.
  defp extract(bytes, names) do
    case :zip.unzip(bytes, [:memory, {:file_list, Enum.map(names, &String.to_charlist/1)}]) do
      {:ok, files} -> {:ok, Map.new(files, fn {name, data} -> {to_string(name), data} end)}
      _error -> {:error, invalid()}
    end
  catch
    _kind, _reason -> {:error, invalid()}
  end

  defp invalid, do: dgettext("import_export", "This isn't a valid CHARX file.")

  defp fetch_card(files) do
    case Map.fetch(files, "card.json") do
      {:ok, raw} -> {:ok, raw}
      :error -> {:error, dgettext("import_export", "This CHARX file has no card.json.")}
    end
  end

  defp decode(raw) do
    case Jason.decode(raw) do
      {:ok, json} when is_map(json) -> {:ok, json}
      _bad -> {:error, dgettext("import_export", "This file isn't valid JSON.")}
    end
  end

  # Returns the avatar bytes (or nil) and how many assets it used (0 or 1). The zip's directory
  # picks the first icon actually stored, so only that one entry is inflated.
  defp avatar(assets, bytes) do
    stored = entry_names(bytes)

    assets
    |> Enum.filter(&(&1["type"] == "icon" and is_binary(local_path(&1["uri"]))))
    |> Enum.sort_by(&if(&1["name"] == "main", do: 0, else: 1))
    |> Enum.find_value(fn icon ->
      path = local_path(icon["uri"])
      Enum.find([path, String.trim_leading(path, "/")], &MapSet.member?(stored, &1))
    end)
    |> case do
      nil ->
        {nil, 0}

      name ->
        case extract(bytes, [name]) do
          {:ok, %{^name => data}} -> {data, 1}
          _missing -> {nil, 0}
        end
    end
  end

  # The names in the zip's central directory; reading it inflates nothing.
  defp entry_names(bytes) do
    case :zip.list_dir(bytes) do
      {:ok, entries} ->
        MapSet.new(for {:zip_file, name, _info, _comment, _offset, _size} <- entries, do: to_string(name))

      _error ->
        MapSet.new()
    end
  catch
    _kind, _reason -> MapSet.new()
  end

  defp local_path(uri) when is_binary(uri) do
    Enum.find_value(@prefixes, fn prefix ->
      if String.starts_with?(uri, prefix), do: String.replace_prefix(uri, prefix, "")
    end)
  end

  defp local_path(_uri), do: nil
end
