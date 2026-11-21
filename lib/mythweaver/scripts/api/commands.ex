defmodule Mythweaver.Scripts.API.Commands do
  @moduledoc """
  `mw.commands.*`: command palette scripts called like functions. The called command runs in its
  own sandbox with the caller's event (only `args` replaced), trigger and permissions; see
  `Mythweaver.Scripts.call_command/3`.
  """

  use Gettext, backend: Mythweaver.Gettext

  import Mythweaver.Scripts.API.Convert

  alias Mythweaver.Scripts

  @functions %{
    run:
      {"mw.commands.run(name [, args])",
       dgettext_noop(
         "scripts",
         ~s[Runs the enabled command script with this name as if picked from the command palette, with args a table by ---@param name (an entity is its id or its record table), and returns what it returns. It runs with this script's event, trigger and permissions. nil, "not_found" for no such command; nil, "<param>: <problem>" for a bad argument; nil, "too_deep" past 3 nested calls. A failing command fails this call.]
       )}
  }

  @usage Map.new(@functions, fn {name, {signature, _info}} -> {name, signature} end)

  @doc "The installed functions' signatures and descriptions, by name."
  def functions, do: @functions

  def install(lua, ctx), do: install_functions(lua, [:mw, :commands], @functions, &call(&1, ctx, &2, &3))

  defp call(:run, ctx, [name], state) when is_binary(name), do: run(name, %{}, ctx, state)
  defp call(:run, ctx, [name, nil], state) when is_binary(name), do: run(name, %{}, ctx, state)

  defp call(:run, ctx, [name, {:tref, _} = args], state) when is_binary(name) do
    raw = state |> fields!(args, @usage.run) |> Map.new(fn {k, v} -> {k, text!(v)} end)
    run(name, raw, ctx, state)
  end

  defp call(name, _ctx, _args, _state), do: usage!(@usage[name])

  # The palette's raw text for one argument, which `Command.cast_args/4` then casts.
  defp text!(value) when is_binary(value), do: value
  defp text!(value) when is_integer(value), do: Integer.to_string(value)
  defp text!(value) when is_float(value) and value == trunc(value), do: value |> trunc() |> Integer.to_string()
  defp text!(value) when is_float(value), do: Float.to_string(value)
  defp text!(value) when is_boolean(value), do: Atom.to_string(value)
  defp text!(%{"id" => id}) when is_binary(id), do: id
  defp text!(_value), do: usage!(@usage.run)

  defp run(name, raw, ctx, state) do
    case Scripts.call_command(name, raw, ctx) do
      {:error, :too_deep} ->
        refuse(state, :too_deep)

      {:error, :not_found} ->
        refuse(state, :not_found)

      {:error, {:unknown_params, [param | _]}} ->
        raise Lua.RuntimeException, ~s(mw.commands.run: "#{name}" has no parameter "#{param}")

      {:error, {:args, errors}} ->
        refuse(state, errors |> Enum.sort() |> Enum.map_join("; ", fn {k, v} -> "#{k}: #{v}" end))

      {:ok, values, lines} ->
        state = print(state, name, lines)
        plain = Enum.map(values, &from_decoded/1)

        if Enum.all?(plain, &plain?/1) do
          Lua.encode_list!(state, Enum.map(plain, &to_lua/1))
        else
          raise Lua.RuntimeException,
                ~s(mw.commands.run: "#{name}" returned a function or other value that cannot leave its script; return nil, booleans, numbers, strings or tables of them)
        end

      {:failed, message, lines} ->
        print(state, name, lines)
        raise Lua.RuntimeException, ~s(mw.commands.run: "#{name}" failed: #{message})
    end
  end

  # Through the caller's own `print`, so its line cap covers the called command's lines too.
  defp print(state, name, lines) do
    Enum.reduce(lines, state, fn line, state ->
      {_, state} = Lua.call_function!(state, [:print], ["[#{name}] " <> line])
      state
    end)
  end
end
