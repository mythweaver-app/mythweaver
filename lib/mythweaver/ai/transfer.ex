defmodule Mythweaver.AI.Transfer do
  @moduledoc """
  Moves a user's AI connections and models to the site (`user_id` nil).

  A link only joins a connection and a model of the same owner (`Mythweaver.AI`), and a site row
  references only site rows (`Mythweaver.Ownership`). So a move takes along what must stay together
  and removes, in the same transaction, what the site may not hold:

    * moving a connection moves every model linked to it as well; those models' links to the old
      owner's other connections are removed;
    * moving a model alone removes all of its links (relink it to a site connection);
    * the moved models' caption models that are not the site's.

  A site row is everyone's to reference, so no other owner's reference to a moved row breaks. Names
  are unique per owner: `{:error, {:name_taken, names}}` refuses a move that would collide with a
  site row. `impact/1` counts each kind first, so the editor can warn.

  `Mythweaver.AI.transfer/3` is the authorized entry point.
  """

  import Ecto.Query

  alias Mythweaver.AI.Model
  alias Mythweaver.AI.Provider
  alias Mythweaver.AI.ProviderModel
  alias Mythweaver.Repo

  @typedoc "How many rows of each kind a move changes or removes."
  @type impact :: %{models: non_neg_integer(), links: non_neg_integer(), caption_models: non_neg_integer()}

  @doc """
  What moving `row` (a connection or a model) to the site would change, by kind, and the names it
  would collide on (`[]` when none).
  """
  @spec impact(Provider.t() | Model.t()) :: {impact(), [String.t()]}
  def impact(row) do
    {providers, models} = moving(row)

    counts =
      Map.new(fallout(providers, models), fn {kind, query, _action} -> {kind, Repo.aggregate(query, :count)} end)

    {Map.put(counts, :models, length(models) - if(match?(%Model{}, row), do: 1, else: 0)),
     collisions(providers, models)}
  end

  @doc "Moves `row` and what goes with it to the site. Returns the moved row."
  @spec run(Provider.t() | Model.t()) ::
          {:ok, Provider.t() | Model.t()} | {:error, {:name_taken, [String.t()]} | term()}
  def run(row) do
    {providers, models} = moving(row)

    case collisions(providers, models) do
      [] ->
        Repo.transact(fn ->
          for {_kind, query, action} <- fallout(providers, models), do: apply_action(query, action)

          Repo.update_all(from(p in Provider, where: p.id in ^providers), set: [user_id: nil])
          Repo.update_all(from(m in Model, where: m.id in ^models), set: [user_id: nil])

          {:ok, Repo.get!(row.__struct__, row.id)}
        end)

      names ->
        {:error, {:name_taken, names}}
    end
  end

  # `{provider_ids, model_ids}` that move together.
  defp moving(%Provider{id: id}) do
    {[id], Repo.all(from(pm in ProviderModel, where: pm.provider_id == ^id, select: pm.ai_model_id, distinct: true))}
  end

  defp moving(%Model{id: id}), do: {[], [id]}

  defp collisions(providers, models) do
    taken = fn schema, ids ->
      from(r in schema, where: r.id in ^ids, select: r.name)
      |> Repo.all()
      |> Enum.filter(fn name ->
        Repo.exists?(from(o in schema, where: o.name == ^name and o.id not in ^ids and is_nil(o.user_id)))
      end)
    end

    Enum.sort(taken.(Provider, providers) ++ taken.(Model, models))
  end

  defp fallout(providers, models) do
    [
      {:links, from(pm in ProviderModel, where: pm.ai_model_id in ^models and pm.provider_id not in ^providers),
       :delete},
      # A moved model's caption model that is not the site's and does not move along.
      {:caption_models,
       from(m in Model,
         join: c in Model,
         on: c.id == m.caption_model_id,
         where: m.id in ^models and c.id not in ^models and not is_nil(c.user_id)
       ), {:set, caption_model_id: nil}}
    ]
  end

  # By id, so the joined query above never reaches UPDATE itself.
  defp apply_action(query, :delete), do: Repo.delete_all(by_ids(query))
  defp apply_action(query, {:set, set}), do: Repo.update_all(by_ids(query), set: set)

  defp by_ids(query) do
    ids = Repo.all(select(query, [r], r.id))
    from(t in table_of(query), where: t.id in ^ids)
  end

  defp table_of(query), do: Ecto.Queryable.to_query(query).from.source |> elem(1)
end
