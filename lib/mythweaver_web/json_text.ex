defmodule MythweaverWeb.JSONText do
  @moduledoc """
  Round-trips JSON through a text field. `decode_map/1`/`encode/1` handle a free-form map: only the
  JSON-object shape is checked here; scalar-only fields are validated downstream by
  `Mythweaver.AI.ScalarMap.validate/2`. `decode_value/1`/`encode_value/1` handle any JSON term, with
  bare text standing for a string, for variable values.
  """

  @doc "`{map, true}` for an object or blank text (blank means \"no extras\"); `{%{}, false}` otherwise."
  def decode_map(raw) when is_binary(raw) do
    if String.trim(raw) == "" do
      {%{}, true}
    else
      case Jason.decode(raw) do
        {:ok, map} when is_map(map) -> {map, true}
        _ -> {%{}, false}
      end
    end
  end

  @doc "Decodes `raw` into `attrs[key]`; `{attrs, true}` on success, `{attrs without key, false}` when it does not parse."
  @spec put_map(map(), String.t(), String.t()) :: {map(), boolean()}
  def put_map(attrs, key, raw) do
    case decode_map(raw) do
      {map, true} -> {Map.put(attrs, key, map), true}
      {_map, false} -> {Map.delete(attrs, key), false}
    end
  end

  @doc "Comma-separated text as trimmed, non-blank strings."
  @spec split_list(String.t() | nil) :: [String.t()]
  def split_list(text) do
    (text || "")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc "A literal `\"{}\"` for an empty/nil map, so an untouched box round-trips as empty."
  def encode(map) when map == %{} or is_nil(map), do: "{}"
  def encode(map), do: Jason.encode!(map, pretty: true)

  @doc "Text as a JSON term; text that is not JSON is taken as a plain string."
  def decode_value(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, value} -> value
      {:error, _} -> text
    end
  end

  @doc """
  The inverse of `decode_value/1`: a string that would not decode as JSON shows bare, so `calm` stays
  `calm`; every other value (including a string like `"42"` that would decode) is JSON-encoded, so the
  text decodes back to exactly the same value.
  """
  def encode_value(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, _} -> Jason.encode!(value)
      {:error, _} -> value
    end
  end

  def encode_value(value), do: Jason.encode!(value, pretty: true)
end
