defmodule Mythweaver.Memory.Tiers do
  @moduledoc """
  Memory tier names: tier 0 is a scene memory, 1..6 are consolidation tiers (Arc through Epic).

  `name/1` and `plural/2` are the English names prompts use; `label/1` is the name shown in the
  UI, in the viewer's language.
  """

  use Gettext, backend: Mythweaver.Gettext

  @names %{0 => "Memory", 1 => "Arc", 2 => "Chapter", 3 => "Book", 4 => "Legend", 5 => "Series", 6 => "Epic"}

  @doc "The English name of `tier`, for prompts."
  @spec name(0..6) :: String.t()
  def name(tier) when is_map_key(@names, tier), do: Map.fetch!(@names, tier)

  @doc ~S|The lowercased noun for `count` entries of `tier`: "memory", "memories", "arcs", "series".|
  @spec plural(0..6, non_neg_integer()) :: String.t()
  def plural(tier, 1), do: tier |> name() |> String.downcase()
  def plural(0, _count), do: "memories"
  def plural(5, _count), do: "series"
  def plural(tier, _count), do: String.downcase(name(tier)) <> "s"

  @doc "The display name of `tier` in the current locale (tier 0, a scene memory, included)."
  @spec label(0..6) :: String.t()
  def label(0), do: dpgettext("memory", "memory tier name", "Memory")
  def label(1), do: dpgettext("memory", "memory tier name", "Arc")
  def label(2), do: dpgettext("memory", "memory tier name", "Chapter")
  def label(3), do: dpgettext("memory", "memory tier name", "Book")
  def label(4), do: dpgettext("memory", "memory tier name", "Legend")
  def label(5), do: dpgettext("memory", "memory tier name", "Series")
  def label(6), do: dpgettext("memory", "memory tier name", "Epic")
end
