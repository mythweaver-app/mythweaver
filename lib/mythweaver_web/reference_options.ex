defmodule MythweaverWeb.ReferenceOptions do
  @moduledoc """
  Keeps a reference select from silently changing a saved value the viewer cannot see: a shared
  item's editor may not see every row its owner referenced, so the saved row is offered by name.
  """

  @doc """
  `options` with `kept` (`{label, id}`) prepended unless `id` is already an option value (option
  groups included). `nil` leaves `options` as they are.
  """
  @spec with_kept(list(), {String.t(), term()} | nil) :: list()
  def with_kept(options, nil), do: options

  def with_kept(options, {_label, id} = kept) do
    if member?(options, id), do: options, else: [kept | options]
  end

  @doc """
  The `kept` map for `row`: for each `{field, schema, options}` whose saved id is set and not among
  `options`, `field => {name, id}` (the name by `Mythweaver.Sharing.reference_label/2`).
  """
  @spec kept(struct(), [{atom(), module(), list()}]) :: %{atom() => {String.t(), term()}}
  def kept(row, references) do
    for {field, schema, options} <- references,
        id = Map.fetch!(row, field),
        is_binary(id) and not member?(options, id),
        name = Mythweaver.Sharing.reference_label(schema, id),
        is_binary(name),
        into: %{},
        do: {field, {name, id}}
  end

  @doc "Whether `id` is an option value in `options` (option groups included)."
  @spec member?(list(), term()) :: boolean()
  def member?(options, id), do: Enum.any?(options, &value?(&1, id))

  defp value?({_group, options}, id) when is_list(options), do: member?(options, id)
  defp value?({_label, value}, id), do: value == id
  defp value?(opts, id) when is_list(opts), do: opts[:value] == id
  defp value?(value, id), do: value == id
end
