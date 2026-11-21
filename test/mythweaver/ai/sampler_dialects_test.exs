defmodule Mythweaver.AI.SamplerDialectsTest do
  use ExUnit.Case, async: true

  alias Mythweaver.AI.Provider
  alias Mythweaver.AI.Provider.SamplerDialect
  alias Mythweaver.AI.ProviderModel
  alias Mythweaver.AI.SamplerDialects.Generic
  alias Mythweaver.AI.SamplerDialects.LlamaCpp
  alias Mythweaver.AI.SamplerDialects.OpenAI
  alias Mythweaver.AI.SamplerDialects.OpenRouter
  alias Mythweaver.AI.SamplerParams

  @order [:temperature | SamplerParams.default_sampler_order() -- [:temperature]]

  defp sampler do
    %SamplerParams{
      temperature: 0.7,
      top_p: 0.9,
      top_k: 40,
      min_p: 0.05,
      top_a: 0.2,
      typical_p: 0.9,
      repetition_penalty: 1.1,
      repetition_penalty_range: 256,
      frequency_penalty: 0.1,
      presence_penalty: 0.2,
      max_tokens: 300,
      seed: 7,
      stop_sequences: ["\n\n"],
      dry_multiplier: 0.8,
      dry_sequence_breakers: ["\n"],
      skip_special_tokens: false,
      ignore_eos: true,
      dynatemp_low: 0.5,
      dynatemp_high: 1.5,
      sampler_order: @order,
      logit_bias: %{"shiver" => false, "123" => 5, "456" => false}
    }
  end

  test "sampler_dialect enums stay in lockstep with SamplerDialect.dialects/0" do
    registered = SamplerDialect.dialects() |> Map.keys() |> Enum.sort()

    assert Enum.sort(Ecto.Enum.values(Provider, :sampler_dialect)) == registered
    assert Enum.sort(Ecto.Enum.values(ProviderModel, :sampler_dialect)) == registered
  end

  test "nil is the generic dialect" do
    assert SamplerDialect.module_for(nil) == Generic
  end

  describe "LlamaCpp.body/1" do
    test "renames penalties, converts dynamic temperature and keeps text logit bias" do
      body = LlamaCpp.body(sampler())

      assert body["repeat_penalty"] == 1.1
      assert body["repeat_last_n"] == 256
      refute Map.has_key?(body, "repetition_penalty")
      refute Map.has_key?(body, "top_a")
      refute Map.has_key?(body, "skip_special_tokens")
      refute Map.has_key?(body, "dynatemp_low")
      assert body["typical_p"] == 0.9
      assert body["temperature"] == 1.0
      assert body["dynatemp_range"] == 0.5
      assert body["ignore_eos"] == true
      assert ["temperature" | _] = body["samplers"]
      assert length(body["samplers"]) == 9
      assert body["logit_bias"] == %{"shiver" => false, "123" => 5, "456" => false}
    end

    test "a plain temperature passes through without a dynamic range" do
      assert LlamaCpp.body(%SamplerParams{temperature: 0.7}) == %{"temperature" => 0.7}
    end
  end

  test "OpenAI keeps only OpenAI's parameters and numeric logit bias" do
    assert OpenAI.body(sampler()) == %{
             "temperature" => 0.7,
             "top_p" => 0.9,
             "frequency_penalty" => 0.1,
             "presence_penalty" => 0.2,
             "max_tokens" => 300,
             "seed" => 7,
             "stop" => ["\n\n"],
             "logit_bias" => %{"123" => 5, "456" => -100}
           }
  end

  test "OpenRouter keeps its documented extras and drops the rest" do
    body = OpenRouter.body(sampler())

    assert body["top_a"] == 0.2
    assert body["repetition_penalty"] == 1.1
    assert body["min_p"] == 0.05
    assert body["top_k"] == 40
    refute Map.has_key?(body, "dry_multiplier")
    refute Map.has_key?(body, "typical_p")
    refute Map.has_key?(body, "samplers")
  end

  test "Generic sends canonical names and numeric logit bias, false as -100" do
    body = Generic.body(sampler())

    assert body["repetition_penalty"] == 1.1
    assert body["repetition_penalty_range"] == 256
    assert body["dynatemp_low"] == 0.5
    assert body["temperature"] == 0.7
    assert body["skip_special_tokens"] == false
    assert body["dry_sequence_breakers"] == ["\n"]
    assert body["stop"] == ["\n\n"]
    assert ["temperature" | _] = body["samplers"]
    assert body["logit_bias"] == %{"123" => 5, "456" => -100}
  end

  test "Generic sends no logit_bias when only text keys are set" do
    refute Map.has_key?(Generic.body(%SamplerParams{logit_bias: %{"shiver" => false}}), "logit_bias")
  end

  describe "LlamaCpp.adjust_body/2" do
    test "text mode rewrites a json_schema response_format to llama.cpp's json_schema" do
      body = %{
        "response_format" => %{
          "type" => "json_schema",
          "json_schema" => %{"name" => "x", "schema" => %{"type" => "object"}}
        }
      }

      assert LlamaCpp.adjust_body(body, :text) == %{"json_schema" => %{"type" => "object"}}
      assert LlamaCpp.adjust_body(body, :chat) == body
    end

    test "text mode turns json_object into a schema, open when it has none" do
      assert LlamaCpp.adjust_body(%{"response_format" => %{"type" => "json_object"}}, :text) ==
               %{"json_schema" => %{}}

      assert LlamaCpp.adjust_body(%{"response_format" => %{"type" => "json_object", "schema" => %{"a" => 1}}}, :text) ==
               %{"json_schema" => %{"a" => 1}}
    end

    test "an explicit json_schema key wins and response_format is left alone" do
      body = %{"json_schema" => %{"b" => 1}, "response_format" => %{"type" => "json_object"}}
      assert LlamaCpp.adjust_body(body, :text) == body
    end
  end
end
