defmodule Mythweaver.Tags.Graph do
  @moduledoc """
  One viewer's resolved tag rules, pure: siblings (`ideal`) and parents.

  Built by `Mythweaver.Tags.graph/1` from the site's rules and the viewer's own. A viewer's sibling
  rule for a text overwrites the site's for the same text; parent pairs from both domains union.
  Parent pairs are stored with both ends already mapped through `ideal/2`, self-pairs dropped.

  Rules from different domains may still form a cycle (a site rule against a user's own), so every
  walk keeps a visited set and stops at the first repeat.
  """

  alias Mythweaver.Tags

  defstruct ideal: %{}, parents: %{}

  @type t :: %__MODULE__{ideal: %{String.t() => String.t()}, parents: %{String.t() => MapSet.t()}}
  @type domain :: :site | :own
  @type predicate :: {:include | :exclude, {:tag, String.t()} | {:namespace, String.t()}}

  @doc "A graph from `{domain, text, ideal_text}` sibling and `{domain, child, parent}` parent rows."
  @spec new([{domain(), String.t(), String.t()}], [{domain(), String.t(), String.t()}]) :: t()
  def new(siblings, parents) do
    {site, own} = Enum.split_with(siblings, &(elem(&1, 0) == :site))
    ideal = Map.new(site ++ own, fn {_domain, text, ideal} -> {text, ideal} end)
    graph = %__MODULE__{ideal: ideal}
    Enum.reduce(parents, graph, fn {_domain, child, parent}, acc -> put_parent(acc, child, parent) end)
  end

  @doc "The text `text` displays as: its sibling chain followed to the end."
  @spec ideal(t(), String.t()) :: String.t()
  def ideal(%__MODULE__{ideal: map}, text), do: follow(map, text, MapSet.new([text]))

  defp follow(map, text, seen) do
    case Map.fetch(map, text) do
      {:ok, next} -> if MapSet.member?(seen, next), do: text, else: follow(map, next, MapSet.put(seen, next))
      :error -> text
    end
  end

  @doc "Every ancestor of `ideal(text)`, excluding it."
  @spec ancestors(t(), String.t()) :: MapSet.t()
  def ancestors(%__MODULE__{} = graph, text) do
    start = ideal(graph, text)
    graph |> walk([start], MapSet.new([start])) |> MapSet.delete(start)
  end

  defp walk(_graph, [], seen), do: seen

  defp walk(graph, [text | rest], seen) do
    next = graph.parents |> Map.get(text, MapSet.new()) |> Enum.reject(&MapSet.member?(seen, &1))
    walk(graph, rest ++ next, Enum.reduce(next, seen, &MapSet.put(&2, &1)))
  end

  @doc "An item's expanded set: the ideal of each hard tag plus every ancestor of those."
  @spec expand(t(), [String.t()]) :: MapSet.t()
  def expand(%__MODULE__{} = graph, texts) do
    Enum.reduce(texts, MapSet.new(), fn text, acc ->
      acc |> MapSet.put(ideal(graph, text)) |> MapSet.union(ancestors(graph, text))
    end)
  end

  @doc "What an editor shows under hard tags `texts`: the implied tags not already among their ideals."
  @spec display(t(), [String.t()]) :: %{implied: [String.t()]}
  def display(%__MODULE__{} = graph, texts) do
    hard = MapSet.new(texts, &ideal(graph, &1))
    implied = graph |> expand(texts) |> MapSet.difference(hard) |> MapSet.to_list() |> Tags.sort()
    %{implied: implied}
  end

  @doc "Texts with a sibling rule that resolves to `ideal(text)`, excluding that ideal."
  @spec aliases(t(), String.t()) :: [String.t()]
  def aliases(%__MODULE__{} = graph, text) do
    target = ideal(graph, text)

    graph.ideal
    |> Map.keys()
    |> Enum.filter(&(&1 != target and ideal(graph, &1) == target))
    |> Tags.sort()
  end

  @doc "Texts with a direct parent pair onto `ideal(text)`."
  @spec children(t(), String.t()) :: [String.t()]
  def children(%__MODULE__{} = graph, text) do
    target = ideal(graph, text)

    graph.parents
    |> Enum.filter(fn {_child, parents} -> MapSet.member?(parents, target) end)
    |> Enum.map(&elem(&1, 0))
    |> Tags.sort()
  end

  @doc "The graph with `text`'s sibling rule set to `ideal_text` (nil: removed)."
  @spec put_ideal(t(), String.t(), String.t() | nil) :: t()
  def put_ideal(%__MODULE__{} = graph, text, nil), do: %{graph | ideal: Map.delete(graph.ideal, text)}
  def put_ideal(%__MODULE__{} = graph, text, ideal_text), do: %{graph | ideal: Map.put(graph.ideal, text, ideal_text)}

  @doc "The graph with the parent pair `child` → `parent` added (both ends mapped through `ideal/2`)."
  @spec put_parent(t(), String.t(), String.t()) :: t()
  def put_parent(%__MODULE__{} = graph, child, parent) do
    {child, parent} = {ideal(graph, child), ideal(graph, parent)}

    if child == parent,
      do: graph,
      else: %{graph | parents: Map.update(graph.parents, child, MapSet.new([parent]), &MapSet.put(&1, parent))}
  end

  @doc "Whether making `ideal_text` the sibling of `text` loops back to `text`."
  @spec sibling_cycle?(t(), String.t(), String.t()) :: boolean()
  def sibling_cycle?(%__MODULE__{} = graph, text, ideal_text) do
    ideal_text == text or chain_reaches?(Map.delete(graph.ideal, text), ideal_text, text, MapSet.new([ideal_text]))
  end

  defp chain_reaches?(map, current, target, seen) do
    case Map.fetch(map, current) do
      {:ok, ^target} ->
        true

      {:ok, next} ->
        if MapSet.member?(seen, next), do: false, else: chain_reaches?(map, next, target, MapSet.put(seen, next))

      :error ->
        false
    end
  end

  @doc "Whether the parent pair `child` → `parent` loops back: same ideal, or `child` is already an ancestor of `parent`."
  @spec parent_cycle?(t(), String.t(), String.t()) :: boolean()
  def parent_cycle?(%__MODULE__{} = graph, child, parent) do
    child_ideal = ideal(graph, child)
    child_ideal == ideal(graph, parent) or MapSet.member?(ancestors(graph, parent), child_ideal)
  end

  @doc "Whether an item with `expanded` tags satisfies every predicate (excludes negate)."
  @spec matches?(t(), MapSet.t(), [predicate()]) :: boolean()
  def matches?(%__MODULE__{} = graph, expanded, predicates) do
    Enum.all?(predicates, fn
      {:include, test} -> hit?(graph, expanded, test)
      {:exclude, test} -> not hit?(graph, expanded, test)
    end)
  end

  defp hit?(graph, expanded, {:tag, text}), do: MapSet.member?(expanded, ideal(graph, text))
  defp hit?(_graph, expanded, {:namespace, ns}), do: Enum.any?(expanded, &(Tags.namespace(&1) == ns))
end
