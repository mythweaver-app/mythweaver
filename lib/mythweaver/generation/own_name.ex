defmodule Mythweaver.Generation.OwnName do
  @moduledoc """
  Removes the replying character's own `Name:` from the start of a reply's lines, as SillyTavern
  does unless "Show {{char}}: in responses" is on (`cleanUpMessage`, `allow_name2_display`): the
  history shows other speakers' lines as `Name: text`, so models often prefix their own.

  The `generation.trim_own_name` setting turns it off. Like SillyTavern it matches `Name:` at the
  start of the text or after a newline, with the whitespace that follows; `Name:` mid-line stays.
  Text that continues a line (a raw continue) matches only after a newline.
  """

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Characters.Character
  alias Mythweaver.Settings

  @opaque t :: %{line_start: Regex.t(), after_newline: Regex.t()}

  @doc "The patterns for `responder`'s name, or nil when `scope` keeps names or the name is blank."
  @spec pattern(Scope.t(), Character.t()) :: t | nil
  def pattern(%Scope{} = scope, %Character{name: name}) do
    if is_binary(name) and String.trim(name) != "" and Settings.get(scope, "generation.trim_own_name") do
      name = Regex.escape(name)
      %{line_start: Regex.compile!("(^|\\n)#{name}:\\s*"), after_newline: Regex.compile!("(\\n)#{name}:\\s*")}
    end
  end

  @doc """
  `text` without the name prefixes `pattern/2` matches; unchanged for a nil pattern. `line_start?`
  false means `text` continues a line, so its very start is not a line start.
  """
  @spec strip(String.t(), t | nil, boolean()) :: String.t()
  def strip(text, pattern, line_start? \\ true)
  def strip(text, nil, _line_start?), do: text
  def strip(text, %{line_start: regex}, true), do: Regex.replace(regex, text, "\\1")
  def strip(text, %{after_newline: regex}, false), do: Regex.replace(regex, text, "\\1")
end
