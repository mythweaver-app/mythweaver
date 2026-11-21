defmodule Mythweaver.Scripts.API.Generation do
  @moduledoc """
  `mw.generation.*`: queue replies in the current chat, marked as script-triggered.

  Only `user_message`, `command`, `quick_reply` and inline scripts may call these. A script running inside a generation
  (`ai_generation`, `lore_activated`) is refused with `nil, "not_allowed"`, so an AI reply can never
  start another one and script-started generations cannot chain. A call that exits (the conductor
  unreachable) returns `nil, "unavailable"`.
  """

  use Gettext, backend: Mythweaver.Gettext

  import Mythweaver.Scripts.API.Convert

  alias Mythweaver.Generation
  alias Mythweaver.Scripts.API.Messages

  @functions %{
    generate:
      {"mw.generation.generate(character_id [, guide])",
       dgettext_noop(
         "scripts",
         ~s(Queues a reply from a participant, steered by the optional guide. true, or nil and a reason such as "busy". user_message, inline, command and quick_reply scripts only.)
       )},
    regenerate:
      {"mw.generation.regenerate(message_id [, guide])",
       dgettext_noop(
         "scripts",
         ~s(Queues a new version of the last AI reply, steered by the optional guide. true, or nil and a reason such as "not_last". user_message, inline, command and quick_reply scripts only.)
       )}
  }

  @usage Map.new(@functions, fn {name, {signature, _info}} -> {name, signature} end)

  @doc "The installed functions' signatures and descriptions, by name."
  def functions, do: @functions

  def install(lua, ctx), do: install_functions(lua, [:mw, :generation], @functions, &call(&1, ctx, &2, &3))

  defp call(name, %{trigger: trigger}, _args, state)
       when name in [:generate, :regenerate] and trigger not in [:user_message, :inline, :command, :quick_reply],
       do: refuse(state, :not_allowed)

  defp call(:generate, ctx, [character_id | guide], state) when is_binary(character_id) do
    guide = guide!(guide, :generate)

    case Enum.find(ctx.chat.participants, &(&1.character_id == character_id)) do
      %{character: character} ->
        attempt(state, fn -> Generation.generate(ctx.scope, ctx.chat, character, guide: guide, script: true) end)

      nil ->
        refuse(state, :not_in_chat)
    end
  end

  defp call(:regenerate, ctx, [message_id | guide], state) when is_binary(message_id) do
    guide = guide!(guide, :regenerate)

    case Messages.in_chat(ctx.scope, ctx.chat, message_id) do
      nil ->
        refuse(state, :not_found)

      message ->
        attempt(state, fn -> Generation.regenerate(ctx.scope, ctx.chat, message, guide: guide, script: true) end)
    end
  end

  defp call(name, _ctx, _args, _state), do: usage!(@usage[name])

  defp guide!([], _name), do: nil
  defp guide!([guide], _name) when is_nil(guide) or is_binary(guide), do: guide
  defp guide!(_, name), do: usage!(@usage[name])

  defp attempt(state, fun) do
    case fun.() do
      :ok -> ok(state, true)
      {:error, reason} -> refuse(state, reason)
    end
  catch
    :exit, _ -> refuse(state, :unavailable)
  end
end
