defmodule Mythweaver.Scripts.API.Prompts do
  @moduledoc """
  `mw.prompts.*` and `mw.blocks.*`: prompt switches, per-prompt block membership switches, and a
  block's own switch.
  """

  use Gettext, backend: Mythweaver.Gettext

  import Mythweaver.Scripts.API.Convert

  alias Mythweaver.Prompts
  alias Mythweaver.Prompts.Prompt

  @functions %{
    list:
      {"mw.prompts.list()",
       dgettext_noop(
         "scripts",
         "Every prompt the user may use (own and site) with its blocks: {id, name, enabled, purpose, site_visibility, blocks = {{id, name, enabled, block_enabled, site_visibility}}}."
       )},
    set_enabled:
      {"mw.prompts.set_enabled(prompt_id, enabled)",
       dgettext_noop("scripts", "Turns a prompt on or off; returns true.")},
    set_block_enabled:
      {"mw.prompts.set_block_enabled(prompt_id, block_id, enabled)",
       dgettext_noop("scripts", "Turns a block on or off in this prompt only (its membership switch); returns true.")},
    block_set_enabled:
      {"mw.blocks.set_enabled(block_id, enabled)",
       dgettext_noop("scripts", "Turns a block on or off in every prompt that holds it (its own switch); returns true.")}
  }

  @usage Map.new(@functions, fn {name, {signature, _info}} -> {name, signature} end)

  @doc "The installed functions' signatures and descriptions, by name."
  def functions, do: @functions

  def install(lua, ctx) do
    lua
    |> set([:mw, :prompts, :list], :list, ctx)
    |> set([:mw, :prompts, :set_enabled], :set_enabled, ctx)
    |> set([:mw, :prompts, :set_block_enabled], :set_block_enabled, ctx)
    |> set([:mw, :blocks, :set_enabled], :block_set_enabled, ctx)
  end

  defp set(lua, path, name, ctx), do: Lua.set!(lua, path, fn args, state -> call(name, ctx, args, state) end)

  @doc "A prompt's Lua table; `prompt_blocks` must be loaded with their blocks."
  def to_table(%Prompt{} = prompt) do
    %{
      id: prompt.id,
      name: prompt.name,
      enabled: prompt.enabled,
      purpose: prompt.purpose,
      site_visibility: prompt.site_visibility,
      blocks:
        Enum.map(prompt.prompt_blocks, fn membership ->
          %{
            id: membership.block_id,
            name: membership.block.name,
            enabled: membership.enabled,
            block_enabled: membership.block.enabled,
            site_visibility: membership.block.site_visibility
          }
        end)
    }
  end

  defp call(:list, ctx, [], state), do: ok(state, Enum.map(Prompts.list_prompts(ctx.scope), &to_table/1))

  defp call(:set_enabled, ctx, [id, enabled?], state) when is_binary(id) and is_boolean(enabled?) do
    with_prompt(ctx, id, state, fn prompt ->
      Prompts.update_prompt(ctx.scope, prompt, %{enabled: enabled?}) |> toggled(state)
    end)
  end

  defp call(:set_block_enabled, ctx, [id, block_id, enabled?], state)
       when is_binary(id) and is_binary(block_id) and is_boolean(enabled?) do
    with_prompt(ctx, id, state, fn prompt ->
      prompt
      |> Prompts.list_prompt_blocks()
      |> Enum.find(&(&1.block_id == block_id))
      |> case do
        nil -> refuse(state, :not_found)
        membership -> Prompts.update_block_membership(ctx.scope, membership, %{enabled: enabled?}) |> toggled(state)
      end
    end)
  end

  defp call(:block_set_enabled, ctx, [id, enabled?], state) when is_binary(id) and is_boolean(enabled?) do
    case fetch(id, &Prompts.get_block(ctx.scope, &1)) do
      nil -> refuse(state, :not_found)
      block -> Prompts.update_block(ctx.scope, block, %{enabled: enabled?}) |> toggled(state)
    end
  end

  defp call(name, _ctx, _args, _state), do: usage!(@usage[name])

  defp with_prompt(ctx, id, state, fun) do
    case fetch(id, &Prompts.get_prompt(ctx.scope, &1)) do
      nil -> refuse(state, :not_found)
      prompt -> fun.(prompt)
    end
  end

  defp toggled(result, state), do: reply(result, state, fn _ -> true end)
end
