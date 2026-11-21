defmodule Mythweaver.AnalyticsTest do
  use Mythweaver.DataCase, async: true

  alias Mythweaver.AI
  alias Mythweaver.Analytics
  alias Mythweaver.Analytics.GenerationStat
  alias Mythweaver.Jobs.Job

  defp model!(scope, name \\ "Gemma") do
    {:ok, model} =
      AI.create_model(scope, %{name: "#{name}-#{System.unique_integer([:positive])}", api_model_id: "gemma-4"})

    model
  end

  # One finished run, through the same writer `Jobs` uses. `finished_at` defaults to now.
  defp run!(scope, model, attrs \\ %{}) do
    finished = Map.get(attrs, :finished_at, DateTime.utc_now())

    job =
      struct!(
        %Job{
          id: Mythweaver.Schema.generate_id(),
          user_id: scope.user.id,
          ai_model_id: model && model.id,
          tag: :reply,
          origin: :interactive,
          status: :completed,
          usage: %{"prompt_tokens" => 100, "completion_tokens" => 20},
          started_at: DateTime.add(finished, -10, :second),
          first_token_at: DateTime.add(finished, -8, :second),
          finished_at: finished
        },
        Map.delete(attrs, :finished_at)
      )

    :ok = Analytics.record_runs([job])
  end

  describe "overview/2" do
    test "sums tokens and cost per day and model, most-used model first" do
      scope = scope!()
      small = model!(scope, "Small")
      big = model!(scope, "Big")

      run!(scope, small)
      run!(scope, big, %{usage: %{"prompt_tokens" => 500, "completion_tokens" => 50, "cost" => 0.0125}})
      run!(scope, big, %{usage: %{"prompt_tokens" => 300, "completion_tokens" => 30, "cost" => 2}})

      overview = Analytics.overview(scope, days: 7)

      assert [%{key: big_key, color: 1}, %{key: small_key, color: 2}] = overview.models
      assert big_key == big.id and small_key == small.id

      assert %{prompt_tokens: 800, completion_tokens: 80, runs: 2, cost: 2.0125} =
               Enum.find(overview.daily, &(&1.model == big.id))

      assert %{prompt_tokens: 100, cost: nil} = Enum.find(overview.daily, &(&1.model == small.id))
      assert %{runs: 3, prompt_tokens: 900, completion_tokens: 100, costed_runs: 2} = overview.totals
      assert length(overview.days) == 7
    end

    test "estimates cost at the model's prices when the provider reports none" do
      scope = scope!()

      {:ok, priced} =
        AI.update_model(scope, model!(scope), %{prompt_cost_per_mtok: "2", completion_cost_per_mtok: "10"})

      run!(scope, priced, %{usage: %{"prompt_tokens" => 1_000_000, "completion_tokens" => 100_000}})
      run!(scope, priced, %{usage: %{"prompt_tokens" => 1_000_000, "completion_tokens" => 0, "cost" => 0.5}})

      assert Repo.all(from(s in GenerationStat, select: {s.cost, s.cost_estimated}, order_by: s.cost)) == [
               {Decimal.new("0.5"), false},
               {Decimal.new("3"), true}
             ]

      assert %{cost: 3.5, costed_runs: 2, estimated_runs: 1} = Analytics.overview(scope).totals
    end

    test "counts cached prompt tokens only over the runs that reported them" do
      scope = scope!()
      model = model!(scope)
      run!(scope, model, %{usage: %{"prompt_tokens" => 100, "prompt_tokens_details" => %{"cached_tokens" => 80}}})
      run!(scope, model, %{usage: %{"prompt_tokens" => 50, "prompt_tokens_details" => %{"cached_tokens" => 0}}})
      # No cache report: its prompt tokens are neither cached nor uncached.
      run!(scope, model, %{usage: %{"prompt_tokens" => 40}})

      overview = Analytics.overview(scope)

      assert %{prompt_tokens: 190, cached_tokens: 80, cache_reported_tokens: 150} = overview.totals
      assert [%{prompt_tokens: 190, cached_tokens: 80, cache_reported_tokens: 150}] = overview.models
      assert [%{cached_tokens: 80, cache_reported_tokens: 150}] = overview.daily
    end

    test "a run with no usage report counts as a run with no tokens" do
      scope = scope!()
      run!(scope, model!(scope), %{status: :canceled, usage: nil, first_token_at: nil})

      assert %{runs: 1, prompt_tokens: 0, completion_tokens: 0, cost: nil, ttft_p50: nil} =
               Analytics.overview(scope).totals
    end

    test "groups a deleted model's runs as one \"Deleted model\"" do
      scope = scope!()
      run!(scope, nil)

      assert [%{key: "deleted", name: "Deleted model"}] = Analytics.overview(scope).models
    end

    test "buckets runs by the reader's local day" do
      scope = scope!()
      yesterday = Date.add(Date.utc_today(), -1)
      # 03:00 UTC is still the previous evening in Denver (UTC-6 or -7).
      {:ok, at} = DateTime.new(yesterday, ~T[03:00:00.000000], "Etc/UTC")
      run!(scope, model!(scope), %{finished_at: at})

      assert [%{day: ^yesterday}] = Analytics.overview(scope, timezone: "UTC").daily

      denver_day = Date.add(yesterday, -1)
      assert [%{day: ^denver_day}] = Analytics.overview(scope, timezone: "America/Denver").daily
    end

    test "leaves out runs older than the range" do
      scope = scope!()
      model = model!(scope)
      run!(scope, model, %{finished_at: DateTime.add(DateTime.utc_now(), -10, :day)})

      assert Analytics.overview(scope, days: 7).totals.runs == 0
      assert Analytics.overview(scope, days: 30).totals.runs == 1
    end

    test "an unknown range falls back to the default" do
      assert length(Analytics.overview(scope!(), days: 12).days) == Analytics.default_range()
    end

    test "latency counts only runs with output, and speed only runs that decoded for a second" do
      scope = scope!()
      model = model!(scope)
      now = DateTime.utc_now()

      # Time to first token 1, 2 and 3 s; 100 tokens over 10 s.
      for ttft <- [1, 2, 3] do
        run!(scope, model, %{
          started_at: DateTime.add(now, -(ttft + 10), :second),
          first_token_at: DateTime.add(now, -10, :second),
          finished_at: now,
          usage: %{"completion_tokens" => 100}
        })
      end

      # Time to first token 2 s, but a half-second decode: its 2000 tokens/s is left out.
      for _ <- 1..3 do
        run!(scope, model, %{
          started_at: DateTime.add(now, -2500, :millisecond),
          first_token_at: DateTime.add(now, -500, :millisecond),
          finished_at: now,
          usage: %{"completion_tokens" => 1000}
        })
      end

      # Failed runs are left out of both; counted, they would move the medians to 2.5 s and
      # 1005 tokens/s.
      for _ <- 1..4, do: run!(scope, model, %{status: :failed, started_at: DateTime.add(now, -58, :second)})

      assert [%{ttft_p50: ttft_p50, tps_p50: tps_p50}] = Analytics.overview(scope).latency
      assert_in_delta ttft_p50, 2000, 1
      assert_in_delta tps_p50, 10.0, 0.01
    end

    test "counts outcomes per job type" do
      scope = scope!()
      model = model!(scope)
      run!(scope, model)
      run!(scope, model, %{status: :failed})
      run!(scope, model, %{tag: :memory, origin: :background})

      assert Enum.sort(Analytics.overview(scope).outcomes) ==
               Enum.sort([
                 %{tag: :reply, status: :completed, count: 1},
                 %{tag: :reply, status: :failed, count: 1},
                 %{tag: :memory, status: :completed, count: 1}
               ])
    end

    test "shows a user only their own runs; an admin may ask for everyone's" do
      admin = scope!()
      user = scope!(%{role: :user})
      run!(admin, model!(admin))
      run!(user, model!(user))

      assert Analytics.overview(user).totals.runs == 1
      assert Analytics.overview(user, all_users: true).totals.runs == 1
      assert Analytics.overview(admin).totals.runs == 1

      assert %{all_users: true, totals: %{runs: 2}} = Analytics.overview(admin, all_users: true)
    end
  end

  describe "timezone/1" do
    test "keeps a zone Postgres knows and falls back to UTC otherwise" do
      assert Analytics.timezone("America/Denver") == "America/Denver"
      assert Analytics.timezone("Mars/Olympus_Mons") == "UTC"
      assert Analytics.timezone("'; DROP TABLE users; --") == "UTC"
      assert Analytics.timezone(nil) == "UTC"
    end
  end

  describe "record_call/1" do
    defp embedding!(scope, model, usage) do
      now = DateTime.utc_now()

      :ok =
        Analytics.record_call(%{
          tag: :embedding,
          scope: scope,
          model: model,
          link: nil,
          chat_id: nil,
          origin: :background,
          status: :completed,
          usage: usage,
          started_at: DateTime.add(now, -1, :second),
          finished_at: now
        })
    end

    test "writes a job-less row priced at the model's prompt cost, or the reported charge" do
      scope = scope!()
      {:ok, priced} = AI.update_model(scope, model!(scope), %{prompt_cost_per_mtok: "2000"})

      embedding!(scope, priced, %{"prompt_tokens" => 7})

      assert [%GenerationStat{job_id: nil, tag: :embedding, origin: :background, prompt_tokens: 7} = stat] =
               Repo.all(GenerationStat)

      assert {stat.cost, stat.cost_estimated} == {Decimal.new("0.014"), true}

      Repo.delete_all(GenerationStat)
      embedding!(scope, priced, %{"prompt_tokens" => 7, "cost" => 0.002})
      assert [%GenerationStat{cost: cost, cost_estimated: false}] = Repo.all(GenerationStat)
      assert Decimal.equal?(cost, Decimal.new("0.002"))
    end

    test "a failed call costs nothing and a userless scope records nothing" do
      scope = scope!()
      {:ok, priced} = AI.update_model(scope, model!(scope), %{prompt_cost_per_mtok: "2000"})

      embedding!(scope, priced, %{})
      assert [%GenerationStat{cost: nil, cost_estimated: false, prompt_tokens: nil}] = Repo.all(GenerationStat)

      embedding!(%{scope | user: nil}, priced, %{"prompt_tokens" => 7})
      assert Repo.aggregate(GenerationStat, :count) == 1
    end
  end
end
