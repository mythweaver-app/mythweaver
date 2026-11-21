defmodule Mythweaver.Analytics do
  @moduledoc """
  Usage history for the analytics page: one `GenerationStat` per finished job run, written by
  `Mythweaver.Jobs` when a run ends (`record_runs/1`), and the aggregates the page charts
  (`overview/2`).

  A stat belongs to whoever pays for the run: a chat job's chat owner (a member's reply spends the
  owner's quota, `Mythweaver.Chats.run_scope/2`), else the job's initiator. A user sees their own runs; an admin may ask for every
  user's (`all_users: true`), which a non-admin's request ignores. Days are the reader's local days:
  `timezone/1` checks a browser-reported zone name against Postgres before any query uses it.
  """

  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Query

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI.Model
  alias Mythweaver.AI.ProviderModel
  alias Mythweaver.Analytics.GenerationStat
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Repo
  alias Mythweaver.Schema

  @ranges [7, 30, 90]
  @default_range 30
  @chart_colors 8

  @type model_key :: String.t()
  @type overview :: %{
          days: [Date.t()],
          timezone: String.t(),
          all_users: boolean(),
          models: [
            %{
              key: model_key(),
              name: String.t(),
              color: pos_integer(),
              prompt_tokens: non_neg_integer(),
              completion_tokens: non_neg_integer(),
              cached_tokens: non_neg_integer(),
              cache_reported_tokens: non_neg_integer()
            }
          ],
          daily: [
            %{
              day: Date.t(),
              model: model_key(),
              runs: non_neg_integer(),
              prompt_tokens: non_neg_integer(),
              completion_tokens: non_neg_integer(),
              cached_tokens: non_neg_integer(),
              cache_reported_tokens: non_neg_integer(),
              cost: float() | nil
            }
          ],
          latency: [
            %{model: model_key(), ttft_p50: float() | nil, ttft_p95: float() | nil, tps_p50: float() | nil}
          ],
          outcomes: [%{tag: atom(), status: atom(), count: pos_integer()}],
          totals: %{
            runs: non_neg_integer(),
            prompt_tokens: non_neg_integer(),
            completion_tokens: non_neg_integer(),
            cached_tokens: non_neg_integer(),
            cache_reported_tokens: non_neg_integer(),
            cost: float() | nil,
            costed_runs: non_neg_integer(),
            estimated_runs: non_neg_integer(),
            ttft_p50: float() | nil,
            tps_p50: float() | nil
          }
        }

  @doc "The day ranges `overview/2` accepts."
  def ranges, do: @ranges

  @doc "The range `overview/2` uses when given none, or one it does not accept."
  def default_range, do: @default_range

  @doc """
  Records one stat per job in `jobs` that just ended a run, for the chat's owner when the job has an
  owned chat and otherwise for its initiator. Jobs without an initiator or a `finished_at` are
  skipped.
  """
  @spec record_runs([Job.t()]) :: :ok
  def record_runs(jobs) do
    now = DateTime.utc_now()
    jobs = for %Job{user_id: user_id, finished_at: %DateTime{}} = job <- jobs, user_id != nil, do: job
    model_ids = for %Job{ai_model_id: id} <- jobs, id != nil, uniq: true, do: id
    chat_ids = for %Job{chat_id: id} <- jobs, id != nil, uniq: true, do: id

    models =
      if model_ids == [], do: %{}, else: Map.new(Repo.all(from(m in Model, where: m.id in ^model_ids)), &{&1.id, &1})

    owners =
      if chat_ids == [],
        do: %{},
        else:
          Map.new(
            Repo.all(from(c in Chat, where: c.id in ^chat_ids and not is_nil(c.user_id), select: {c.id, c.user_id}))
          )

    rows =
      for job <- jobs do
        usage = job.usage || %{}
        prompt_tokens = count(usage["prompt_tokens"])
        completion_tokens = count(usage["completion_tokens"])
        {cost, estimated} = cost(usage["cost"], models[job.ai_model_id], prompt_tokens, completion_tokens)

        %{
          id: Schema.generate_id(),
          job_id: job.id,
          user_id: Map.get(owners, job.chat_id, job.user_id),
          chat_id: job.chat_id,
          ai_model_id: job.ai_model_id,
          provider_id: job.provider_id,
          tag: job.tag,
          origin: job.origin,
          status: job.status,
          prompt_tokens: prompt_tokens,
          completion_tokens: completion_tokens,
          cached_tokens: count(get_in(usage, ["prompt_tokens_details", "cached_tokens"])),
          cost: cost,
          cost_estimated: estimated,
          started_at: job.started_at,
          first_token_at: job.first_token_at,
          finished_at: job.finished_at,
          inserted_at: now
        }
      end

    if rows != [], do: Repo.insert_all(GenerationStat, rows)
    :ok
  end

  @doc """
  Records one direct, job-less model call as a stat with `job_id` nil: an embedding call
  (`Mythweaver.AI.embed/2`, `tag: :embedding`) or a classifier call (`Mythweaver.AI.classify/2`,
  `tag: :expression`). Its cost follows `record_runs/1`'s rule with no completion tokens, so a failed
  call (`usage: %{}`) costs nothing. A scope without a user records nothing.
  """
  @spec record_call(%{
          tag: :embedding | :expression,
          scope: Scope.t(),
          model: Model.t(),
          link: ProviderModel.t() | nil,
          chat_id: Ecto.UUID.t() | nil,
          origin: :interactive | :background,
          status: :completed | :failed,
          usage: map(),
          started_at: DateTime.t(),
          finished_at: DateTime.t()
        }) :: :ok
  def record_call(%{scope: %Scope{user: nil}}), do: :ok

  def record_call(%{scope: %Scope{user: user}, model: %Model{} = model, link: link, usage: usage} = call) do
    prompt_tokens = count(usage["prompt_tokens"])
    {cost, estimated} = cost(usage["cost"], model, prompt_tokens, nil)

    Repo.insert_all(GenerationStat, [
      %{
        id: Schema.generate_id(),
        job_id: nil,
        user_id: user.id,
        chat_id: call.chat_id,
        ai_model_id: model.id,
        provider_id: link && link.provider_id,
        tag: call.tag,
        origin: call.origin,
        status: call.status,
        prompt_tokens: prompt_tokens,
        completion_tokens: nil,
        cached_tokens: nil,
        cost: cost,
        cost_estimated: estimated,
        started_at: call.started_at,
        first_token_at: nil,
        finished_at: call.finished_at,
        inserted_at: DateTime.utc_now()
      }
    ])

    :ok
  end

  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(value) when is_float(value) and value >= 0, do: round(value)
  defp count(_value), do: nil

  # The provider's charge wins; otherwise an estimate at the model's prices, as for a message body.
  defp cost(reported, _model, _prompt, _completion) when is_integer(reported), do: {Decimal.new(reported), false}
  defp cost(reported, _model, _prompt, _completion) when is_float(reported), do: {Decimal.from_float(reported), false}
  defp cost(_reported, nil, _prompt, _completion), do: {nil, false}
  defp cost(_reported, _model, nil, nil), do: {nil, false}

  defp cost(_reported, model, prompt, completion) do
    case Model.estimate_cost(model, prompt || 0, completion || 0) do
      nil -> {nil, false}
      estimate -> {estimate, true}
    end
  end

  @doc """
  `name` if Postgres knows it as a time zone (`pg_timezone_names`), else `"UTC"`. The browser
  reports the name (`Intl.DateTimeFormat().resolvedOptions().timeZone`), so it is untrusted input.
  """
  @spec timezone(term()) :: String.t()
  def timezone(name) when is_binary(name) and byte_size(name) <= 64 do
    case Repo.query!("SELECT name FROM pg_timezone_names WHERE name = $1 LIMIT 1", [name]) do
      %{rows: [[^name]]} -> name
      _none -> "UTC"
    end
  end

  def timezone(_name), do: "UTC"

  @doc """
  The analytics page's data for the last `:days` local days (one of `ranges/0`), today included.

  Options: `:days`, `:timezone` (already checked by `timezone/1`; default `"UTC"`), and
  `:all_users` (admins only). `models` is ordered by total tokens, most first, gives each model
  its chart color (`--chart-1`…`--chart-8`) and sums its tokens; a deleted model's runs are grouped
  as "Deleted model". `cached_tokens` are prompt tokens the backend served from its prompt cache
  (`prompt_tokens_details.cached_tokens`), and `cache_reported_tokens` the prompt tokens of the runs
  that reported that count at all, so `cache_reported_tokens - cached_tokens` were processed afresh
  and the rest of `prompt_tokens` is unknown either way. `totals.costed_runs` counts the runs with
  any cost, and `estimated_runs` those whose cost is an estimate. Latency counts only runs that
  produced output (`:completed`, `:review`), and tokens/second only those that decoded for at
  least a second.
  """
  @spec overview(Scope.t(), keyword()) :: overview()
  def overview(%Scope{} = scope, opts \\ []) do
    days = if opts[:days] in @ranges, do: opts[:days], else: @default_range
    tz = Keyword.get(opts, :timezone, "UTC")
    all_users = opts[:all_users] == true and Scope.can?(scope, "analytics.all.view")

    today = local_today(tz)
    first = Date.add(today, 1 - days)
    runs = scope |> runs_query(all_users, first, tz) |> subquery()

    daily = daily(runs)
    models = models(daily)

    %{
      days: Enum.to_list(Date.range(first, today)),
      timezone: tz,
      all_users: all_users,
      models: models,
      daily: Enum.map(daily, &Map.drop(&1, [:model_id, :model_name])),
      latency: latency(runs),
      outcomes: outcomes(runs),
      totals: totals(runs)
    }
  end

  defp local_today(tz) do
    %{rows: [[today]]} = Repo.query!("SELECT (now() AT TIME ZONE $1)::date", [tz])
    today
  end

  # `finished_at` is a UTC timestamp without zone: `AT TIME ZONE 'UTC'` makes it a timestamptz, and
  # the second `AT TIME ZONE` turns that into the reader's wall-clock time. The range bound runs the
  # other way, from the first local midnight to UTC, so the index on `finished_at` still applies.
  defp runs_query(scope, all_users, first, tz) do
    from(s in GenerationStat,
      left_join: m in assoc(s, :model),
      where: s.finished_at >= fragment("(?::date::timestamp AT TIME ZONE ?) AT TIME ZONE 'UTC'", ^first, ^tz),
      select: %{
        day: fragment("((? AT TIME ZONE 'UTC') AT TIME ZONE ?)::date", s.finished_at, ^tz),
        model_id: s.ai_model_id,
        model_name: m.name,
        tag: s.tag,
        status: s.status,
        prompt_tokens: s.prompt_tokens,
        completion_tokens: s.completion_tokens,
        cached_tokens: s.cached_tokens,
        cost: s.cost,
        cost_estimated: s.cost_estimated,
        ttft_ms:
          fragment(
            "CASE WHEN ? IN ('completed', 'review') THEN EXTRACT(EPOCH FROM (? - ?)) * 1000 END",
            s.status,
            s.first_token_at,
            s.started_at
          ),
        tps:
          fragment(
            "CASE WHEN ? IN ('completed', 'review') AND ? > 0 AND EXTRACT(EPOCH FROM (? - ?)) >= 1 THEN ? / EXTRACT(EPOCH FROM (? - ?)) END",
            s.status,
            s.completion_tokens,
            s.finished_at,
            s.first_token_at,
            s.completion_tokens,
            s.finished_at,
            s.first_token_at
          )
      }
    )
    |> owned_by(scope, all_users)
  end

  defp owned_by(query, _scope, true), do: query
  defp owned_by(query, %Scope{user: %{id: user_id}}, false), do: where(query, [s], s.user_id == ^user_id)
  defp owned_by(query, _scope, false), do: where(query, false)

  defp daily(runs) do
    from(r in runs,
      group_by: [r.day, r.model_id, r.model_name],
      order_by: [r.day, r.model_name],
      select: %{
        day: r.day,
        model_id: r.model_id,
        model_name: r.model_name,
        runs: count(),
        prompt_tokens: coalesce(sum(r.prompt_tokens), 0),
        completion_tokens: coalesce(sum(r.completion_tokens), 0),
        cached_tokens: coalesce(sum(r.cached_tokens), 0),
        cache_reported_tokens: coalesce(filter(sum(r.prompt_tokens), not is_nil(r.cached_tokens)), 0),
        cost: sum(r.cost)
      }
    )
    |> Repo.all()
    |> Enum.map(&Map.merge(&1, %{model: model_key(&1.model_id), cost: to_float(&1.cost)}))
  end

  @token_fields [:prompt_tokens, :completion_tokens, :cached_tokens, :cache_reported_tokens]

  defp models(daily) do
    daily
    |> Enum.group_by(& &1.model)
    |> Enum.map(fn {key, [row | _] = rows} ->
      sums = Map.new(@token_fields, fn field -> {field, Enum.sum_by(rows, &Map.fetch!(&1, field))} end)

      name =
        row.model_name ||
          dpgettext("ai", "status: name shown for usage of an AI model that was deleted", "Deleted model")

      Map.merge(sums, %{key: key, name: name})
    end)
    |> Enum.sort_by(&{-(&1.prompt_tokens + &1.completion_tokens), &1.name})
    |> Enum.with_index(fn model, i -> Map.put(model, :color, rem(i, @chart_colors) + 1) end)
  end

  defp latency(runs) do
    from(r in runs,
      group_by: r.model_id,
      having: count(r.ttft_ms) > 0,
      select: %{
        model_id: r.model_id,
        ttft_p50: fragment("percentile_cont(0.5) WITHIN GROUP (ORDER BY ?)", r.ttft_ms),
        ttft_p95: fragment("percentile_cont(0.95) WITHIN GROUP (ORDER BY ?)", r.ttft_ms),
        tps_p50: fragment("percentile_cont(0.5) WITHIN GROUP (ORDER BY ?)", r.tps)
      }
    )
    |> Repo.all()
    |> Enum.map(fn row ->
      %{
        model: model_key(row.model_id),
        ttft_p50: to_float(row.ttft_p50),
        ttft_p95: to_float(row.ttft_p95),
        tps_p50: to_float(row.tps_p50)
      }
    end)
  end

  defp outcomes(runs) do
    from(r in runs,
      group_by: [r.tag, r.status],
      order_by: [r.tag, r.status],
      select: %{tag: r.tag, status: r.status, count: count()}
    )
    |> Repo.all()
  end

  defp totals(runs) do
    from(r in runs,
      select: %{
        runs: count(),
        prompt_tokens: coalesce(sum(r.prompt_tokens), 0),
        completion_tokens: coalesce(sum(r.completion_tokens), 0),
        cached_tokens: coalesce(sum(r.cached_tokens), 0),
        cache_reported_tokens: coalesce(filter(sum(r.prompt_tokens), not is_nil(r.cached_tokens)), 0),
        cost: sum(r.cost),
        costed_runs: count(r.cost),
        estimated_runs: filter(count(), r.cost_estimated),
        ttft_p50: fragment("percentile_cont(0.5) WITHIN GROUP (ORDER BY ?)", r.ttft_ms),
        tps_p50: fragment("percentile_cont(0.5) WITHIN GROUP (ORDER BY ?)", r.tps)
      }
    )
    |> Repo.one()
    |> then(&%{&1 | cost: to_float(&1.cost)})
  end

  defp model_key(nil), do: "deleted"
  defp model_key(id), do: id

  defp to_float(nil), do: nil
  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_float(n), do: n
end
