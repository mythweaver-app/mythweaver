defmodule Mythweaver.Import.Text do
  @moduledoc false
  # Small helpers shared by the import parsers: macro conversion that threads the list of
  # unconverted macro names, and tolerant readers for loosely typed JSON values.

  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.Import.Macros

  @doc "Converts ST macros to Liquid, appending any unconverted names to `names`. `opts` go to `Macros.to_liquid/2`."
  @spec convert(String.t() | nil, [String.t()], keyword()) :: {String.t(), [String.t()]}
  def convert(text, names, opts \\ []) do
    {out, new} = Macros.to_liquid(text, opts)
    {out, names ++ new}
  end

  @max_foreign_bytes 65_536

  @doc """
  The keys of `map` an import didn't map, kept so an export can write them back: every key not in
  `mapped` and not starting with `_`, minus empty maps and values whose JSON is over 64 KiB (each
  warned about under `name`). Returns `{kept, warnings}`.
  """
  @spec foreign(map(), [String.t()], String.t()) :: {map(), [String.t()]}
  def foreign(map, mapped, name) when is_map(map) do
    Enum.reduce(map, {%{}, []}, fn {key, value}, {kept, warnings} ->
      cond do
        not is_binary(key) or key in mapped or String.starts_with?(key, "_") or value == %{} ->
          {kept, warnings}

        byte_size(Jason.encode!(value)) > @max_foreign_bytes ->
          warning =
            dgettext("import_export", "'%{item_name}': %{field_key} was too large to keep.",
              item_name: name,
              field_key: key
            )

          {kept, warnings ++ [warning]}

        true ->
          {Map.put(kept, key, value), warnings}
      end
    end)
  end

  def foreign(_map, _mapped, _name), do: {%{}, []}

  @spec blank?(term()) :: boolean()
  def blank?(value) when is_binary(value), do: String.trim(value) == ""
  def blank?(_value), do: true

  @spec string(term()) :: String.t() | nil
  def string(value) when is_binary(value), do: value
  def string(_value), do: nil

  @spec strings(term()) :: [String.t()]
  def strings(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  def strings(_other), do: []

  @spec map(term()) :: map()
  def map(value) when is_map(value), do: value
  def map(_value), do: %{}

  @spec stem(String.t()) :: String.t()
  def stem(filename), do: filename |> Path.basename() |> Path.rootname()

  @spec pos_int(term()) :: pos_integer() | nil
  def pos_int(value) when is_integer(value) and value > 0, do: value
  def pos_int(_value), do: nil

  @spec non_neg_int(term(), integer()) :: non_neg_integer()
  def non_neg_int(value, _default) when is_integer(value) and value >= 0, do: value
  def non_neg_int(_value, default), do: default

  @spec bool(term()) :: boolean() | nil
  def bool(value) when is_boolean(value), do: value
  def bool(_value), do: nil

  @doc "The single warning listing every unconverted macro, or none."
  @spec macro_warnings([String.t()]) :: [String.t()]
  def macro_warnings([]), do: []

  def macro_warnings(names) do
    listed =
      names
      |> Enum.uniq()
      |> Enum.map_join(", ", fn
        "unparseable template" ->
          dpgettext("import_export", "unit: list item for a template that could not be parsed", "unparseable template")

        name ->
          "{{#{name}}}"
      end)

    gettext_comment("Import warning; the placeholder is a comma-separated list of SillyTavern macros like {{user}}.")
    [dgettext("import_export", "Left as literal text (no equivalent): %{macro_list}", macro_list: listed)]
  end
end
