defmodule Mythweaver.AI.ScalarMap do
  @moduledoc """
  Validation for the free-form JSON maps this context splices straight into request bodies.

  `SamplerParams.extra`, `Provider.extra_headers`, and the `extra_body` layers (model, connection,
  link) are all merged verbatim into an outgoing request. A value `Jason.encode/1` cannot handle
  would raise at request time, far from the edit that introduced it, so the shape is checked at
  the changeset instead.

  `validate/2` is scalar-only: headers must be strings on the wire and sampler extras are flat
  sampler params. `validate_json/2` accepts nested JSON, for `extra_body` (e.g.
  `chat_template_kwargs`).
  """

  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  @message dgettext_noop("errors", "values must be scalars or lists of scalars")
  @json_message dgettext_noop("errors", "values must be JSON (scalars, lists, or objects)")

  @doc """
  Requires every value in `field` to be a number, boolean, string, or a list of those.

  Passes unchanged when the field is unset or empty, and when the field already carries an error
  (a cast failure has nothing worth re-checking).
  """
  def validate(changeset, field) do
    check(changeset, field, @message, fn map -> Enum.all?(map, fn {_key, value} -> scalar_or_list?(value) end) end)
  end

  @doc """
  Requires every value in `field` to be JSON-encodable: a number, boolean, string, `nil`, a list of
  those, or a map of those, recursively.

  Same short-circuits as `validate/2`.
  """
  def validate_json(changeset, field), do: check(changeset, field, @json_message, &json?/1)

  defp check(changeset, field, message, valid?) do
    case get_field(changeset, field) do
      map when map == %{} -> changeset
      map when is_map(map) -> if valid?.(map), do: changeset, else: add_error(changeset, field, message)
      _other -> changeset
    end
  end

  defp json?(value) when is_nil(value) or is_number(value) or is_boolean(value), do: true
  defp json?(value) when is_binary(value), do: true
  defp json?(value) when is_list(value), do: Enum.all?(value, &json?/1)

  defp json?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn {k, v} -> (is_binary(k) or is_atom(k)) and json?(v) end)
  end

  defp json?(_value), do: false

  defp scalar_or_list?(value) when is_list(value), do: Enum.all?(value, &scalar?/1)
  defp scalar_or_list?(value), do: scalar?(value)

  defp scalar?(value), do: is_number(value) or is_boolean(value) or is_binary(value)
end
