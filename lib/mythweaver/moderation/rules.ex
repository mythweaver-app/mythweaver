defmodule Mythweaver.Moderation.Rules do
  @moduledoc """
  The content-moderation rules (`Mythweaver.Moderation.Rule`), edited on `/moderation/rules` by
  `"moderation.rules.manage"` holders. Every write is logged and calls
  `Mythweaver.Moderation.broadcast_changed/0`. `enabled_for/1` is the scanner's unscoped read.
  """

  import Ecto.Query

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Moderation
  alias Mythweaver.Moderation.Log
  alias Mythweaver.Moderation.Modes
  alias Mythweaver.Moderation.Rule
  alias Mythweaver.Repo

  @key "moderation.rules.manage"

  @doc "Every rule, by name."
  @spec list_rules(Scope.t()) :: {:ok, [Rule.t()]} | {:error, :unauthorized}
  def list_rules(%Scope{} = scope) do
    with :ok <- Scope.authorize(scope, @key) do
      {:ok, Repo.all(from(r in Rule, order_by: [asc: r.name, asc: r.id]))}
    end
  end

  @doc "The rule `id`."
  @spec get_rule(Scope.t(), String.t()) :: {:ok, Rule.t()} | {:error, :unauthorized | :not_found}
  def get_rule(%Scope{} = scope, id) do
    with :ok <- Scope.authorize(scope, @key),
         {:ok, id} <- cast_id(id),
         %Rule{} = rule <- Repo.get(Rule, id) do
      {:ok, rule}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc "A changeset for editing `rule`."
  @spec change_rule(Rule.t(), map()) :: Ecto.Changeset.t()
  def change_rule(%Rule{} = rule, attrs \\ %{}), do: Rule.changeset(rule, attrs)

  @doc "Creates a rule."
  @spec create_rule(Scope.t(), map()) :: {:ok, Rule.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def create_rule(%Scope{} = scope, attrs) do
    with :ok <- Scope.authorize(scope, @key),
         {:ok, rule} <- %Rule{} |> Rule.changeset(attrs) |> Repo.insert() do
      logged(scope, :rule_created, rule)
    end
  end

  @doc "Updates `rule`."
  @spec update_rule(Scope.t(), Rule.t(), map()) :: {:ok, Rule.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def update_rule(%Scope{} = scope, %Rule{} = rule, attrs) do
    with :ok <- Scope.authorize(scope, @key),
         {:ok, rule} <- rule |> Rule.changeset(attrs) |> Repo.update() do
      logged(scope, :rule_updated, rule)
    end
  end

  @doc "Deletes `rule`."
  @spec delete_rule(Scope.t(), Rule.t()) :: {:ok, Rule.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def delete_rule(%Scope{} = scope, %Rule{} = rule) do
    with :ok <- Scope.authorize(scope, @key),
         {:ok, rule} <- Repo.delete(rule) do
      logged(scope, :rule_deleted, rule)
    end
  end

  @doc "The enabled rules for the content type `type`, by name (unscoped: the scanner's read)."
  @spec enabled_for(Modes.type()) :: [Rule.t()]
  def enabled_for(type) do
    Repo.all(
      from(r in Rule,
        where: r.enabled and ^type in r.content_types,
        order_by: [asc: r.name, asc: r.id]
      )
    )
  end

  defp logged(scope, action, rule) do
    :ok = Log.record(scope, action, :moderation_rule, rule.id, nil, %{"name" => rule.name})
    Moderation.broadcast_changed()
    {:ok, rule}
  end

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end
end
