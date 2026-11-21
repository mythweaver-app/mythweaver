defmodule Mythweaver.Scripts.API.Variables do
  @moduledoc """
  `mw.vars.*` and `mw.globals.*`: the variables templates read as `vars` and `globals`.

  `mw.vars.*` are the current chat's variables. `mw.globals.*` read what the run's user's chats read
  (site globals overlaid by their own) and write that user's own globals, never the site's, as
  `{% setglobalvar %}` does. A `nil` value deletes. Values are plain data: strings, numbers,
  booleans, and tables of them.
  """

  use Gettext, backend: Mythweaver.Gettext

  import Mythweaver.Scripts.API.Convert

  alias Mythweaver.Variables

  @functions %{
    vars_get: {"mw.vars.get(key)", dgettext_noop("scripts", "The chat variable's value, or nil when it is unset.")},
    vars_set:
      {"mw.vars.set(key, value)",
       dgettext_noop("scripts", "Sets the chat variable, as {% setvar %} does; nil deletes it. Returns true.")},
    vars_list: {"mw.vars.list()", dgettext_noop("scripts", "Every chat variable, as a table of key = value.")},
    globals_get:
      {"mw.globals.get(key)",
       dgettext_noop("scripts", "The global variable's value as your chats read it, or nil when it is unset.")},
    globals_set:
      {"mw.globals.set(key, value)",
       dgettext_noop(
         "scripts",
         "Sets your own global variable, as {% setglobalvar %} does; nil deletes it. Returns true."
       )},
    globals_list:
      {"mw.globals.list()",
       dgettext_noop("scripts", "Every global variable your chats read, as a table of key = value.")}
  }

  @usage Map.new(@functions, fn {name, {signature, _info}} -> {name, signature} end)

  @doc "The installed functions' signatures and descriptions, by name."
  def functions, do: @functions

  def install(lua, ctx) do
    Enum.reduce(@functions, lua, fn {name, {signature, _info}}, lua ->
      path = signature |> String.split("(", parts: 2) |> hd() |> String.split(".")
      Lua.set!(lua, path, fn args, state -> call(name, ctx, args, state) end)
    end)
  end

  defp call(:vars_list, ctx, [], state), do: ok(state, chat_values(ctx))
  defp call(:vars_get, ctx, [key], state) when is_binary(key), do: ok(state, chat_values(ctx)[key])
  defp call(:globals_list, ctx, [], state), do: ok(state, Variables.global_values(ctx.scope))
  defp call(:globals_get, ctx, [key], state) when is_binary(key), do: ok(state, Variables.global_values(ctx.scope)[key])

  # A trailing nil may not arrive as an argument: `set(key)` is `set(key, nil)`.
  defp call(name, ctx, [key], state) when name in [:vars_set, :globals_set], do: call(name, ctx, [key, nil], state)

  defp call(name, ctx, [key, value], state) when name in [:vars_set, :globals_set] and is_binary(key) do
    value = from_lua(state, value)
    if not plain?(value), do: usage!(@usage[name])
    chat_id = if name == :vars_set, do: ctx.chat.id

    case Variables.put_value(ctx.scope, chat_id, key, value) do
      :ok -> ok(state, true)
      {:error, reason} -> refuse(state, reason)
    end
  end

  defp call(name, _ctx, _args, _state), do: usage!(@usage[name])

  defp chat_values(ctx), do: Map.new(Variables.list_chat_variables(ctx.scope, ctx.chat.id), &{&1.key, &1.value})
end
