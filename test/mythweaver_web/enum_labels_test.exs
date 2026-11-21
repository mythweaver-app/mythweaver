defmodule MythweaverWeb.EnumLabelsTest do
  use ExUnit.Case, async: true

  alias Mythweaver.Sharing.Items
  alias MythweaverWeb.EnumLabels

  test "every value of every covered enum field has a label" do
    for {schema, field} <- EnumLabels.covered(), value <- Ecto.Enum.values(schema, field) do
      assert is_binary(EnumLabels.label(schema, field, value)), "#{inspect(schema)}.#{field} #{value}"
    end
  end

  test "values/2 lists every value with its label" do
    for {schema, field} <- EnumLabels.covered() do
      assert Enum.map(EnumLabels.values(schema, field), &elem(&1, 1)) == Ecto.Enum.values(schema, field)
    end
  end

  test "every field a shared item's card shows has a label" do
    for type <- [:lore_entry | Items.root_types()],
        field <- (Items.fields(type) -- [:name, :avatar, :tags, :entries, :blocks]) ++ Items.protected_fields(type) do
      assert is_binary(EnumLabels.field_label(Items.schema(type), field)), "#{type}.#{field}"
    end
  end

  test "every skip reason has a label" do
    for reason <- [:unauthorized, :in_use, :sudo_required] do
      assert is_binary(EnumLabels.skip_reason(reason))
    end
  end
end
