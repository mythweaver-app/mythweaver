defmodule Mythweaver.Scripts.API.Dice do
  @moduledoc """
  `mw.roll`: dice in `Mythweaver.Dice`'s grammar, the same one the Liquid `roll` filter uses.
  """

  use Gettext, backend: Mythweaver.Gettext

  import Mythweaver.Scripts.API.Convert, only: [usage!: 1, ok: 2]

  alias Mythweaver.Dice

  @usage "mw.roll(dice)"

  @functions %{
    roll: {@usage, dgettext_noop("scripts", ~s(Rolls dice such as "2d6+1", "d6" or "D20" and returns the total.))}
  }

  @doc "The installed functions' signatures and descriptions, by name."
  def functions, do: @functions

  def install(lua, _ctx) do
    Lua.set!(lua, [:mw, :roll], fn args, state -> roll(args, state) end)
  end

  defp roll([dice], state) when is_binary(dice) do
    case Dice.roll(dice) do
      {:ok, total} -> ok(state, total)
      :error -> usage!(@usage)
    end
  end

  defp roll(_args, _state), do: usage!(@usage)
end
