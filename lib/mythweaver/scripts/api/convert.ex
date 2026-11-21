defmodule Mythweaver.Scripts.API.Convert do
  @moduledoc """
  Value conversion between host records and Lua, plus the host API's return contract: a success
  returns the value, a domain refusal returns `nil, "<reason>"`, and a malformed call raises. Also
  installs a module's functions.
  """

  @doc "Sets each of `functions`' names under `path` to `call.(name, args, state)`."
  def install_functions(lua, path, functions, call) do
    Enum.reduce(Map.keys(functions), lua, fn name, lua ->
      Lua.set!(lua, path ++ [name], fn args, state -> call.(name, args, state) end)
    end)
  end

  @doc """
  Lua-ready data: atoms other than `nil`/`true`/`false` become strings, `DateTime`s ISO 8601, and
  lists and maps are converted recursively with string keys. Structs must be mapped to plain maps
  of their listed fields first; one reaching here raises.
  """
  def to_lua(value) when value in [nil, true, false], do: value
  def to_lua(value) when is_atom(value), do: Atom.to_string(value)
  def to_lua(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def to_lua(%Decimal{} = value), do: Decimal.to_float(value)
  def to_lua(value) when is_list(value), do: Enum.map(value, &to_lua/1)

  def to_lua(value) when is_map(value) and not is_struct(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), to_lua(v)} end)

  def to_lua(value) when is_binary(value) or is_number(value), do: value

  @doc """
  Elixir data from a Lua argument: a table whose keys are exactly `1..n` becomes a list, any other
  table a string-keyed map. Scalars pass through.
  """
  def from_lua(%Lua{} = state, {:tref, _} = value), do: state |> Lua.decode!(value) |> from_decoded()
  def from_lua(_state, value), do: value

  @doc """
  Elixir data from an already-decoded Lua value (`Lua.eval!` results / `Lua.decode!` output):
  sequence tables become lists, other tables string-keyed maps.
  """
  def from_decoded(pairs) when is_list(pairs) do
    pairs = Enum.sort_by(pairs, &elem(&1, 0))

    if Enum.map(pairs, &elem(&1, 0)) == Enum.to_list(1..length(pairs)//1) do
      Enum.map(pairs, fn {_, v} -> from_decoded(v) end)
    else
      Map.new(pairs, fn {k, v} -> {key(k), from_decoded(v)} end)
    end
  end

  def from_decoded(value), do: value

  @doc """
  Whether `value` (from `from_decoded/1`) is plain data that can leave its VM: `nil`, booleans,
  numbers, strings, and lists and string-keyed maps of them. Functions, userdata and leftover table
  references are not.
  """
  def plain?(value) when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value), do: true
  def plain?(value) when is_list(value), do: Enum.all?(value, &plain?/1)

  def plain?(value) when is_map(value) and not is_struct(value),
    do: Enum.all?(value, fn {k, v} -> is_binary(k) and plain?(v) end)

  def plain?(_value), do: false

  defp key(k) when is_float(k) and k == trunc(k), do: k |> trunc() |> Integer.to_string()
  defp key(k), do: to_string(k)

  @doc "A Lua table argument as a string-keyed map; an empty table is `%{}`."
  def fields!(state, {:tref, _} = value, usage) do
    case from_lua(state, value) do
      [] -> %{}
      map when is_map(map) -> map
      _ -> usage!(usage)
    end
  end

  def fields!(_state, _value, usage), do: usage!(usage)

  @doc "Returns `value` to Lua."
  def ok(state, value), do: Lua.encode_list!(state, [to_lua(value)])

  @doc "Returns `nil, reason` to Lua."
  def refuse(state, reason), do: Lua.encode_list!(state, [nil, reason_string(reason)])

  @doc """
  `fun.(value)` to Lua for `{:ok, value}`; `nil, reason` for `{:error, reason}`, and
  `nil, "held_for_review"` for a write held for moderator review.
  """
  def reply({:ok, value}, state, fun), do: ok(state, fun.(value))
  def reply({:held, _hold}, state, _fun), do: refuse(state, :held_for_review)
  def reply({:error, reason}, state, _fun), do: refuse(state, reason)

  defp reason_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_string(reason) when is_binary(reason), do: reason

  defp reason_string(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, k -> opts |> Keyword.get(String.to_existing_atom(k), k) |> to_string() end)
    end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(List.wrap(messages), &"#{field}: #{inspect_message(&1)}") end)
    |> Enum.join("; ")
  end

  defp reason_string(reason), do: inspect(reason)

  defp inspect_message(message) when is_binary(message), do: message
  defp inspect_message(message), do: inspect(message)

  @doc "Raises the script's error for a malformed call."
  @spec usage!(String.t()) :: no_return()
  def usage!(text), do: raise(Lua.RuntimeException, "usage: " <> text)

  @doc "`getter.(id)` for a well-formed UUID string; `nil` otherwise, since `Repo.get` raises on one."
  def fetch(id, getter) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> getter.(id)
      :error -> nil
    end
  end

  def fetch(_id, _getter), do: nil
end
