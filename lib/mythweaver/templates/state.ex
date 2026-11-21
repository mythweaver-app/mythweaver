defmodule Mythweaver.Templates.State do
  @moduledoc """
  What one prompt assembly's templates read and write, threaded from template to template.

  `data` is the read-only root hash (`anchors`, `outlets`), plus the SillyTavern aliases `char`
  (`anchors.character.name`, unless `data` sets its own) and `user` (`anchors.player.name`) that
  `to_liquid/1` derives. `chat_vars`/`global_vars` start as
  the stored variables and absorb `{% setvar %}`/`{% setglobalvar %}` writes as they render, so a
  later template sees an earlier one's write. `assigns` carries Liquid `{% assign %}` values the same
  way. `writes` records every variable write for `Mythweaver.Variables.apply_writes/2`; nothing is
  persisted here. `seed` keeps the `pick` filter stable per chat.
  """

  defstruct data: %{}, chat_vars: %{}, global_vars: %{}, assigns: %{}, writes: [], seed: nil

  @type write :: %{String.t() => term()}
  @type t :: %__MODULE__{
          data: map(),
          chat_vars: %{optional(String.t()) => term()},
          global_vars: %{optional(String.t()) => term()},
          assigns: map(),
          writes: [write()],
          seed: term()
        }

  @spec new(map(), %{chat: map(), global: map()}, term()) :: t()
  def new(data, %{chat: chat, global: global}, seed) do
    %__MODULE__{data: data, chat_vars: chat, global_vars: global, seed: seed}
  end

  @doc "The variable writes, oldest first."
  @spec writes(t()) :: [write()]
  def writes(%__MODULE__{writes: writes}), do: Enum.reverse(writes)

  @doc """
  Records a write and applies it to the scope's map; a `nil` value deletes the key.
  """
  @spec put(t(), :chat | :global, String.t(), term()) :: t()
  def put(%__MODULE__{} = state, scope, key, value) do
    write = %{"scope" => Atom.to_string(scope), "key" => key, "value" => value}
    state = %{state | writes: [write | state.writes]}

    case scope do
      :chat -> %{state | chat_vars: put_or_delete(state.chat_vars, key, value)}
      :global -> %{state | global_vars: put_or_delete(state.global_vars, key, value)}
    end
  end

  @doc false
  @spec to_liquid(t()) :: map()
  def to_liquid(%__MODULE__{} = state) do
    state.data
    |> Map.put_new_lazy("char", fn -> get_in(state.data, ["anchors", "character", "name"]) end)
    |> Map.put_new_lazy("user", fn -> get_in(state.data, ["anchors", "player", "name"]) end)
    |> Map.merge(variable_hash(state))
  end

  @doc false
  # `vars` lets a chat variable shadow a global one of the same key; `globals` reaches past it.
  @spec variable_hash(t()) :: map()
  def variable_hash(%__MODULE__{} = state) do
    %{"vars" => Map.merge(state.global_vars, state.chat_vars), "globals" => state.global_vars}
  end

  defp put_or_delete(map, key, nil), do: Map.delete(map, key)
  defp put_or_delete(map, key, value), do: Map.put(map, key, value)
end
