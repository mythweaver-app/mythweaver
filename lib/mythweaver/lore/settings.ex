defmodule Mythweaver.Lore.Settings do
  @moduledoc """
  The structural lore constants: outlets, placements, injection slots, and the outlet and placement
  an entry gets when it picks none.

  The tunable activation defaults are the `lore.*` keys in `Mythweaver.Settings`. An entry's `nil`
  `scan_depth` falls back to its book's, then to `lore.scan_depth`; `case_sensitive` and
  `match_whole_words` go entry, then setting.
  """

  @doc "Outlet assigned to entries that do not pick one."
  def default_outlet, do: :character

  @doc "Placement assigned to entries that do not pick one."
  def default_placement, do: :before

  @doc "Known outlets; the select option source and `LoreEntry.outlet`'s enum values."
  def outlets, do: [:character, :examples, :author_note, :at_depth, :custom]

  @doc "Known placements; `at_depth` ignores this axis."
  def placements, do: [:before, :after]

  @doc """
  Injection slots in injection order: the outlet/placement pairs flattened to the strings
  `LoreEntry.slot/1` produces. `at_depth` contributes one slot because its placement is ignored.

  `:custom` contributes no slot: a custom entry is addressed by its outlet key, see
  `Lore.Activation.outlets/2`.
  """
  def slots,
    do:
      ~w(before_character after_character before_examples after_examples at_depth before_author_note after_author_note)

  @doc """
  The slots rendered into `anchors.lore.<slot>`: every slot but `at_depth`, whose content goes inside
  chat history instead.
  """
  def anchor_slots, do: slots() -- ["at_depth"]
end
