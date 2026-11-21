defmodule Mythweaver.Scripts.API.Injections do
  @moduledoc """
  `mw.injections.*`: the current chat's injections, as its injections panel edits them.

  An injection is named by its id or its key (keys are unique per chat and can never look like an
  id). Fields are the panel's: `key`, `content` (a Liquid template), `position` (a lore slot or
  `"at_depth"`), `depth`, `role`, `condition`, `enabled`, `uses` (successful replies it lasts for)
  and `order`. A Lua table cannot hold nil, so `false` clears `uses` (lasts until removed) or
  `condition`.
  """

  use Gettext, backend: Mythweaver.Gettext

  import Mythweaver.Scripts.API.Convert

  alias Mythweaver.Injections
  alias Mythweaver.Injections.Injection

  @fields [:id, :key, :content, :position, :depth, :role, :condition, :enabled, :uses, :remaining, :order]
  @clearable ["uses", "condition"]

  @functions %{
    list:
      {"mw.injections.list()",
       dgettext_noop("scripts", "Every injection in the chat, spent and disabled ones included, in application order.")},
    get: {"mw.injections.get(key_or_id)", dgettext_noop("scripts", "The injection with this key or id.")},
    create:
      {"mw.injections.create(fields)",
       dgettext_noop(
         "scripts",
         ~s(Creates an injection from fields such as {key = "mood", content = "Rain falls.", uses = 3}; returns it.)
       )},
    update:
      {"mw.injections.update(key_or_id, fields)",
       dgettext_noop("scripts", "Updates the injection's given fields; returns it.")},
    set_enabled:
      {"mw.injections.set_enabled(key_or_id, enabled)",
       dgettext_noop("scripts", "Turns the injection on or off; returns true.")},
    rearm:
      {"mw.injections.rearm(key_or_id)",
       dgettext_noop("scripts", "Restores a limited injection's remaining replies to its uses; returns it.")},
    delete: {"mw.injections.delete(key_or_id)", dgettext_noop("scripts", "Deletes the injection; returns true.")},
    clean_up:
      {"mw.injections.clean_up()", dgettext_noop("scripts", "Deletes the chat's spent injections; returns how many.")}
  }

  @usage Map.new(@functions, fn {name, {signature, _info}} -> {name, signature} end)

  @doc "The installed functions' signatures and descriptions, by name."
  def functions, do: @functions

  def install(lua, ctx), do: install_functions(lua, [:mw, :injections], @functions, &call(&1, ctx, &2, &3))

  @doc "An injection's Lua table; `active` is whether it applies to the next generation."
  def to_table(%Injection{} = injection),
    do: injection |> Map.take(@fields) |> Map.put(:active, Injection.active?(injection))

  defp call(:list, ctx, [], state), do: ok(state, Enum.map(list(ctx), &to_table/1))
  defp call(:get, ctx, [ref], state) when is_binary(ref), do: with_injection(ctx, ref, state, &ok(state, to_table(&1)))

  defp call(:create, ctx, [fields], state) do
    attrs = attrs!(state, fields, :create)
    ctx.scope |> Injections.create_injection(ctx.chat.id, attrs) |> reply(state, &to_table/1)
  end

  defp call(:update, ctx, [ref, fields], state) when is_binary(ref) do
    attrs = attrs!(state, fields, :update)

    with_injection(ctx, ref, state, fn injection ->
      ctx.scope |> Injections.update_injection(injection, attrs) |> reply(state, &to_table/1)
    end)
  end

  defp call(:set_enabled, ctx, [ref, enabled?], state) when is_binary(ref) and is_boolean(enabled?) do
    with_injection(ctx, ref, state, fn injection ->
      ctx.scope |> Injections.update_injection(injection, %{enabled: enabled?}) |> reply(state, fn _ -> true end)
    end)
  end

  defp call(:rearm, ctx, [ref], state) when is_binary(ref) do
    with_injection(ctx, ref, state, &(Injections.rearm(ctx.scope, &1) |> reply(state, fn i -> to_table(i) end)))
  end

  defp call(:delete, ctx, [ref], state) when is_binary(ref) do
    with_injection(ctx, ref, state, &(Injections.delete_injection(ctx.scope, &1) |> reply(state, fn _ -> true end)))
  end

  defp call(:clean_up, ctx, [], state), do: ctx.scope |> Injections.clean_up(ctx.chat.id) |> reply(state, & &1)

  defp call(name, _ctx, _args, _state), do: usage!(@usage[name])

  defp attrs!(state, fields, name) do
    state
    |> fields!(fields, @usage[name])
    |> Map.new(fn
      {key, false} when key in @clearable -> {key, nil}
      pair -> pair
    end)
  end

  defp list(ctx), do: Injections.list_injections(ctx.scope, ctx.chat.id)

  defp with_injection(ctx, ref, state, fun) do
    case Enum.find(list(ctx), &(&1.id == ref or &1.key == ref)) do
      nil -> refuse(state, :not_found)
      injection -> fun.(injection)
    end
  end
end
