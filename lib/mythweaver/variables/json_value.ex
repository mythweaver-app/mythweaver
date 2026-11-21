defmodule Mythweaver.Variables.JSONValue do
  @moduledoc """
  Any JSON term (string, number, boolean, list, or string-keyed map) stored in a `jsonb` column.

  Ecto's `:map` only accepts maps; a variable is as often a bare string or number.
  """

  use Ecto.Type

  @impl true
  def type, do: :map

  @impl true
  def cast(value), do: if(json?(value), do: {:ok, value}, else: :error)

  @impl true
  def dump(value), do: {:ok, value}

  @impl true
  def load(value), do: {:ok, value}

  defp json?(value) when is_binary(value) or is_number(value) or is_boolean(value), do: true
  defp json?(value) when is_list(value), do: Enum.all?(value, &json?/1)

  defp json?(value) when is_map(value) and not is_struct(value),
    do: Enum.all?(value, fn {k, v} -> is_binary(k) and json?(v) end)

  defp json?(_value), do: false
end
