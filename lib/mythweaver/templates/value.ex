defmodule Mythweaver.Templates.Value do
  @moduledoc """
  Normalizes a Liquid value into a JSON term, the only shape a stored variable can hold.
  """

  @spec to_json(term()) :: term()
  def to_json(value) when is_binary(value) or is_integer(value) or is_float(value), do: value
  def to_json(value) when is_boolean(value) or is_nil(value), do: value
  def to_json(%Decimal{} = value), do: Decimal.to_float(value)
  def to_json(value) when is_list(value), do: Enum.map(value, &to_json/1)

  def to_json(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {k, v} -> {to_string(k), to_json(v)} end)
  end

  def to_json(value) do
    to_string(value)
  rescue
    Protocol.UndefinedError -> inspect(value)
  end
end
