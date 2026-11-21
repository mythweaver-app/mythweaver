defmodule Mythweaver.AI.SamplerParamsTest do
  use ExUnit.Case, async: true

  import Mythweaver.DataCase, only: [errors_on: 1]

  alias Mythweaver.AI.SamplerParams

  defp changeset(attrs), do: SamplerParams.changeset(%SamplerParams{}, attrs)

  describe "sampler_order" do
    test "must list all nine samplers exactly once" do
      order = SamplerParams.default_sampler_order()

      assert changeset(%{sampler_order: order}).valid?
      assert changeset(%{sampler_order: []}).valid?

      assert %{sampler_order: ["must list every sampler exactly once"]} =
               errors_on(changeset(%{sampler_order: tl(order)}))

      assert %{sampler_order: ["must list every sampler exactly once"]} =
               errors_on(changeset(%{sampler_order: [hd(order) | tl(order)] ++ [hd(order)]}))
    end

    test "loads from the strings the form and the jsonb column carry" do
      strings = Enum.map(SamplerParams.default_sampler_order(), &Atom.to_string/1)

      assert Ecto.Changeset.get_field(changeset(%{"sampler_order" => strings}), :sampler_order) ==
               SamplerParams.default_sampler_order()
    end
  end

  describe "dynamic temperature" do
    test "the minimum and maximum are set together" do
      assert %{dynatemp_high: ["must be set together with the dynamic temperature minimum"]} =
               errors_on(changeset(%{dynatemp_low: 0.5}))

      assert %{dynatemp_low: ["must be set together with the dynamic temperature maximum"]} =
               errors_on(changeset(%{dynatemp_high: 1.5}))
    end

    test "the minimum may not exceed the maximum" do
      assert %{dynatemp_high: ["must be at least the minimum"]} =
               errors_on(changeset(%{dynatemp_low: 1.5, dynatemp_high: 0.5}))

      assert changeset(%{dynatemp_low: 0.5, dynatemp_high: 0.5}).valid?
    end

    test "an exponent needs a range" do
      assert %{dynatemp_exponent: ["needs a dynamic temperature range"]} =
               errors_on(changeset(%{dynatemp_exponent: 1.0}))
    end
  end

  test "logit bias values are numbers in -100..100 or false" do
    message = ["values must be numbers from -100 to 100, or false to ban"]

    assert %{logit_bias: ^message} = errors_on(changeset(%{logit_bias: %{"x" => true}}))
    assert %{logit_bias: ^message} = errors_on(changeset(%{logit_bias: %{"x" => 200}}))
    assert %{logit_bias: ^message} = errors_on(changeset(%{logit_bias: %{" " => 1}}))
    assert changeset(%{logit_bias: %{"x" => false, "123" => -100, "y" => 2.5}}).valid?
  end

  test "dry sequence breakers must be non-empty" do
    assert %{dry_sequence_breakers: ["breakers must be non-empty strings"]} =
             errors_on(changeset(%{dry_sequence_breakers: ["\n", ""]}))
  end

  test "set_values/1 keeps zeros and false but drops unset and empty values" do
    assert SamplerParams.set_values(%SamplerParams{
             temperature: 0.0,
             ignore_eos: false,
             thinking: :high,
             extra: %{"a" => 1}
           }) == %{temperature: 0.0, ignore_eos: false}
  end
end
