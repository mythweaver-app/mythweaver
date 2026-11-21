defmodule Mythweaver.Moderation.Modes do
  @moduledoc """
  Which content-moderation mode a scope's account is in for each content type, from the
  `"Content moderation"` permission flags (`Mythweaver.Permissions.Catalog`).

  `:exempt` (no flag, the default) saves as usual; `:permissive` saves, then the moderation rules
  scan the saved text in the background and open an automated report on a match; `:restrictive`
  keeps a holdable item's create or text edit in memory (`Mythweaver.Moderation.Holds`) until the
  rules or a moderator approve it. The restrictive flag wins over the permissive one; chats have no
  restrictive flag. Owners are always exempt (they hold every flag), and a deny on any group exempts
  through the usual deny-beats-allow resolution.
  """

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User

  @type type :: :chats | :characters | :lore | :ai | :prompts
  @type mode :: :exempt | :permissive | :restrictive

  @types [:chats, :characters, :lore, :ai, :prompts]
  @holdable_types [:characters, :lore, :ai, :prompts]

  @keys %{
    chats: {"moderation.chats.permissive", nil},
    characters: {"moderation.characters.permissive", "moderation.characters.restrictive"},
    lore: {"moderation.lore.permissive", "moderation.lore.restrictive"},
    ai: {"moderation.ai.permissive", "moderation.ai.restrictive"},
    prompts: {"moderation.prompts.permissive", "moderation.prompts.restrictive"}
  }

  @doc "Every content type, in display order."
  @spec types() :: [type()]
  def types, do: @types

  @doc "The content types that have a restrictive (hold) mode."
  @spec holdable_types() :: [type()]
  def holdable_types, do: @holdable_types

  @doc "The scope's mode for `type`; a nil scope, a scope without a user and an owner are `:exempt`."
  @spec mode(Scope.t() | nil, type()) :: mode()
  def mode(%Scope{user: %User{role: role}} = scope, type) when role != :owner do
    {permissive, restrictive} = Map.fetch!(@keys, type)

    cond do
      restrictive && Scope.can?(scope, restrictive) -> :restrictive
      Scope.can?(scope, permissive) -> :permissive
      true -> :exempt
    end
  end

  def mode(_scope, _type), do: :exempt

  @doc "Whether the scope is restrictive for any content type."
  @spec any_restrictive?(Scope.t() | nil) :: boolean()
  def any_restrictive?(scope), do: Enum.any?(@holdable_types, &(mode(scope, &1) == :restrictive))
end
