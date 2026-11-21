defmodule Mythweaver.Prompts.ContextLimitTest do
  use Mythweaver.DataCase

  alias Mythweaver.AI.Model
  alias Mythweaver.AI.SamplerParams
  alias Mythweaver.Prompts.ContextLimit
  alias Mythweaver.Settings

  setup do
    %{scope: scope!()}
  end

  describe "for_reply/2" do
    test "no window and no setting means no trimming", %{scope: scope} do
      assert ContextLimit.for_reply(scope, %Model{}) == nil
    end

    test "the limit is the smaller of the window and the setting", %{scope: scope} do
      assert %ContextLimit{limit: 8000} = ContextLimit.for_reply(scope, %Model{context_window: 8000})

      :ok = Settings.put(scope, :user, "generation.max_context", 2000)

      assert %ContextLimit{limit: 2000} = ContextLimit.for_reply(scope, %Model{})
      assert %ContextLimit{limit: 2000} = ContextLimit.for_reply(scope, %Model{context_window: 8000})
      assert %ContextLimit{limit: 1500} = ContextLimit.for_reply(scope, %Model{context_window: 1500})
    end

    test "the reserve is the model's response tokens, else 1024", %{scope: scope} do
      assert %ContextLimit{reserve: 1024} = ContextLimit.for_reply(scope, %Model{context_window: 8000})

      assert %ContextLimit{reserve: 1024} =
               ContextLimit.for_reply(scope, %Model{context_window: 8000, sampler: %SamplerParams{}})

      assert %ContextLimit{reserve: 300} =
               ContextLimit.for_reply(scope, %Model{context_window: 8000, sampler: %SamplerParams{max_tokens: 300}})
    end

    test "trims in the generation.trim_step setting's steps", %{scope: scope} do
      assert %ContextLimit{step: 10} = ContextLimit.for_reply(scope, %Model{context_window: 8000})
      :ok = Settings.put(scope, :user, "generation.trim_step", 4)
      assert %ContextLimit{step: 4} = ContextLimit.for_reply(scope, %Model{context_window: 8000})
    end
  end

  describe "fit/3" do
    # 3300 characters estimate to 1000 tokens.
    setup do
      %{
        cl: %ContextLimit{limit: 4000, reserve: 500, model: %Model{}},
        entries: for(i <- 1..6, do: %{content: String.duplicate("#{i}", 3300), images: []})
      }
    end

    test "keeps the newest entries that leave the reserve", %{cl: cl, entries: entries} do
      # 3 entries + "x": 3001 + 300 + 128 = 3429, leaving 571 >= 500; a fourth does not fit.
      assert {3, report} = ContextLimit.fit(cl, ["x"], entries)

      assert %{kept: 3, trimmed: 3, used: 3001, limit: 4000, reserve: 500, overflow?: false, estimated?: true} =
               report
    end

    test "stops at the first entry that does not fit, so the kept entries stay a newest suffix", %{cl: cl} do
      entries = [
        %{content: "small", images: []},
        %{content: String.duplicate("x", 13_200), images: []},
        %{content: "newest", images: []}
      ]

      assert {1, %{trimmed: 2}} = ContextLimit.fit(cl, [], entries)
    end

    test "fixed text alone over the limit overflows with nothing kept", %{entries: entries} do
      cl = %ContextLimit{limit: 1000, reserve: 500, model: %Model{}}

      assert {0, %{overflow?: true, kept: 0, trimmed: 6, used: 2000}} =
               ContextLimit.fit(cl, [String.duplicate("x", 6600)], entries)
    end
  end

  describe "fit/3 in steps" do
    # 330 characters estimate to 100 tokens; 1500 holds twelve (1200 + 120 + 128) but not thirteen.
    defp entries(n), do: for(_ <- 1..n, do: %{content: String.duplicate("x", 330), images: []})
    defp cl(step), do: %ContextLimit{limit: 1500, reserve: 0, model: %Model{}, step: step}

    test "the first kept entry stays at a multiple of the step while the chat grows" do
      starts =
        for total <- 20..23 do
          {kept, report} = ContextLimit.fit(cl(5), [], entries(total))
          assert report.used == kept * 100
          total - kept
        end

      # Twelve fit throughout: the start holds at 10 for three replies, then jumps to 15.
      assert starts == [10, 10, 10, 15]
    end

    test "a step of 1 keeps all that fits, and nothing is trimmed while everything fits" do
      assert {12, %{trimmed: 8}} = ContextLimit.fit(cl(1), [], entries(20))
      assert {12, %{trimmed: 0}} = ContextLimit.fit(cl(5), [], entries(12))
    end

    test "the step shrinks to half of what fits" do
      # Twelve fit, so a step of 50 acts as 6: the start rounds from 8 up to 12.
      assert {8, %{trimmed: 12}} = ContextLimit.fit(cl(50), [], entries(20))
    end
  end
end
