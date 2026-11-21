defmodule Mythweaver.Bundle.CodecTest do
  use ExUnit.Case, async: true

  alias Mythweaver.AI.Model
  alias Mythweaver.AI.SamplerParams
  alias Mythweaver.Bundle.Codec
  alias Mythweaver.Characters.Character

  test "every field exists on its schema" do
    for kind <- Codec.kinds() do
      schema_fields = Codec.schema(kind).__schema__(:fields)

      for field <- Codec.fields(kind) do
        assert field in schema_fields, "#{inspect(kind)}: #{field} is not a field of #{inspect(Codec.schema(kind))}"
      end
    end
  end

  test "character dump/attrs round trip" do
    row = %Character{name: "Ava", description: "Tall", talkativeness: 0.5, avatar_updates_appearance: true}
    data = Codec.dump(:character, row, %{})

    assert data["name"] == "Ava"
    assert data["talkativeness"] == 0.5
    attrs = Codec.attrs(:character, Map.put(data, "future_field", 1))
    refute Map.has_key?(attrs, "future_field")

    changeset = Ecto.Changeset.cast(%Character{}, attrs, Codec.fields(:character))
    assert Ecto.Changeset.apply_changes(changeset).description == "Tall"
  end

  test "ai_model dump/attrs round trip" do
    row = %Model{
      name: "M",
      api_model_id: "x/y",
      completion_mode: :text,
      prompt_cost_per_mtok: Decimal.new("1.25"),
      image_detail: :high,
      extra_body: %{"a" => 1}
    }

    data = Codec.dump(:ai_model, row, %{})
    assert data["completion_mode"] == "text"
    assert data["prompt_cost_per_mtok"] == "1.25"
    refute Map.has_key?(data, "caption_model_id")

    model = Model.changeset(%Model{}, Codec.attrs(:ai_model, data)) |> Ecto.Changeset.apply_changes()
    assert model.completion_mode == :text
    assert Decimal.equal?(model.prompt_cost_per_mtok, Decimal.new("1.25"))
    assert model.image_detail == :high
    assert model.extra_body == %{"a" => 1}
  end

  test "value/1 conversions" do
    assert Codec.value(nil) == nil
    assert Codec.value(true) == true
    assert Codec.value(:foo) == "foo"
    assert Codec.value(Decimal.new("2.5")) == "2.5"
    assert Codec.value(~U[2026-01-02 03:04:05Z]) == "2026-01-02T03:04:05Z"
    assert Codec.value(~N[2026-01-02 03:04:05]) == "2026-01-02T03:04:05"
    assert Codec.value([:a, %{b: :c}]) == ["a", %{"b" => "c"}]
    assert Codec.sampler(nil) == nil
    assert %{"temperature" => 0.7} = sampler = Codec.sampler(%SamplerParams{temperature: 0.7})
    refute Map.has_key?(sampler, "top_p")
  end
end
