defmodule MythweaverWeb.Bulk.Selection do
  @moduledoc """
  Pure row-selection arithmetic over a `MapSet` of ids, shared by every selectable list. `listed`
  is the ids the list currently shows: only those can be added.
  """

  @doc "Removes `id` if selected; adds it if listed; otherwise leaves the selection alone."
  @spec toggle(MapSet.t(), term(), [term()]) :: MapSet.t()
  def toggle(selected, id, listed) do
    cond do
      MapSet.member?(selected, id) -> MapSet.delete(selected, id)
      id in listed -> MapSet.put(selected, id)
      true -> selected
    end
  end

  @doc "Adds every id of `ids` that is listed (a shift-click range)."
  @spec add_range(MapSet.t(), [term()], [term()]) :: MapSet.t()
  def add_range(selected, ids, listed) do
    listed = MapSet.new(listed)
    MapSet.union(selected, for(id <- ids, MapSet.member?(listed, id), into: MapSet.new(), do: id))
  end

  @doc "Clears the selection when every listed id is selected; otherwise selects them all."
  @spec toggle_all(MapSet.t(), [term()]) :: MapSet.t()
  def toggle_all(selected, listed) do
    if all_selected?(selected, listed),
      do: MapSet.new(),
      else: MapSet.union(selected, MapSet.new(listed))
  end

  @doc "Whether `listed` is non-empty and every id in it is selected."
  @spec all_selected?(MapSet.t(), [term()]) :: boolean()
  def all_selected?(_selected, []), do: false
  def all_selected?(selected, listed), do: Enum.all?(listed, &MapSet.member?(selected, &1))
end
