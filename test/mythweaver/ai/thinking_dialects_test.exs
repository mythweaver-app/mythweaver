defmodule Mythweaver.AI.ThinkingDialectsTest do
  use ExUnit.Case, async: true

  alias Mythweaver.AI.Provider
  alias Mythweaver.AI.Provider.ThinkingDialect
  alias Mythweaver.AI.ProviderModel
  alias Mythweaver.AI.SamplerParams
  alias Mythweaver.AI.ThinkingDialects.LlamaCpp
  alias Mythweaver.AI.ThinkingDialects.OpenAI
  alias Mythweaver.AI.ThinkingDialects.OpenRouter

  describe "LlamaCpp.body/2" do
    test ":none disables reasoning with no budget" do
      assert LlamaCpp.body(:none, %SamplerParams{max_tokens: 2048}) == %{"reasoning_effort" => "none"}
    end

    test "a level sends the effort plus a budget as a ratio of max_tokens" do
      assert LlamaCpp.body(:medium, %SamplerParams{max_tokens: 2048}) ==
               %{"reasoning_effort" => "medium", "reasoning_budget_tokens" => 1024}
    end

    test "without max_tokens the budget stays unrestricted" do
      assert LlamaCpp.body(:low, %SamplerParams{}) == %{"reasoning_effort" => "low"}
    end

    test "the budget never floors to 0, which llama.cpp reads as end-immediately" do
      assert LlamaCpp.body(:minimal, %SamplerParams{max_tokens: 5})["reasoning_budget_tokens"] == 1
    end
  end

  test "OpenRouter nests the effort under reasoning" do
    assert OpenRouter.body(:none, %SamplerParams{}) == %{"reasoning" => %{"effort" => "none"}}
  end

  test "OpenAI sends the level verbatim as reasoning_effort" do
    assert OpenAI.body(:xhigh, %SamplerParams{}) == %{"reasoning_effort" => "xhigh"}
  end

  test "thinking_dialect enums stay in lockstep with ThinkingDialect.dialects/0" do
    registered = ThinkingDialect.dialects() |> Map.keys() |> Enum.sort()

    assert Enum.sort(Ecto.Enum.values(Provider, :thinking_dialect)) == registered
    assert Enum.sort(Ecto.Enum.values(ProviderModel, :thinking_dialect)) == registered
  end
end
