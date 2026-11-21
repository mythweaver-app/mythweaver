defmodule MythweaverWeb.ItemFields do
  @moduledoc """
  One row's plain fields as a definition list, for the catalog's card (`MythweaverWeb.CatalogLive`),
  a share's card (`MythweaverWeb.SharedLive`) and the moderation lookup
  (`MythweaverWeb.ModerationLookupLive`). By default: `Mythweaver.Sharing.Items.fields/1` without the
  name, avatar, tags and children, then `Items.protected_fields/1` when `readable?`. Each field is
  `<id>-<field>`; `hidden_hint` explains withheld protected fields as `<id>-hidden`.
  """

  use Phoenix.Component
  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.Sharing.Items
  alias MythweaverWeb.EnumLabels

  attr :id, :string, required: true
  attr :type, :atom, required: true
  attr :row, :any, required: true
  attr :readable?, :boolean, required: true
  attr :fields, :list, default: nil, doc: "the fields to show; nil: the type's card fields"
  attr :hidden_hint, :string, default: nil, doc: "shown when protected fields are withheld"

  def item_fields(assigns) do
    assigns =
      assign(assigns,
        fields: assigns.fields || default_fields(assigns.type, assigns.readable?),
        schema: assigns.row.__struct__
      )

    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      dl.item-fields:scope {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
        margin: 0;
      }

      .item-field {
        & dt {
          color: var(--muted-foreground);
          font-size: 0.875rem;
        }

        & dd {
          margin: 0;
          white-space: pre-wrap;
          overflow-wrap: anywhere;
        }
      }

      .item-fields-empty {
        color: var(--muted-foreground);
      }

      p.item-fields-hint:scope {
        margin: 0;
        color: var(--muted-foreground);
        font-size: 0.875rem;
      }
    </style>
    <dl class="item-fields">
      <div :for={field <- @fields} id={"#{@id}-#{field}"} class="item-field">
        <dt>{EnumLabels.field_label(@schema, field)}</dt>
        <dd :if={value(@schema, field, Map.get(@row, field))}>
          {value(@schema, field, Map.get(@row, field))}
        </dd>
        <dd :if={!value(@schema, field, Map.get(@row, field))} class="item-fields-empty">
          {pgettext("empty state: an item field with no value", "None")}
        </dd>
      </div>
    </dl>
    <p
      :if={@hidden_hint && !@readable? && Items.protected_fields(@type) != []}
      id={"#{@id}-hidden"}
      class="item-fields-hint"
    >
      {@hidden_hint}
    </p>
    """
  end

  defp default_fields(type, readable?) do
    Enum.reject(Items.fields(type), &(&1 in [:name, :avatar, :tags, :entries, :blocks])) ++
      if(readable?, do: Items.protected_fields(type), else: [])
  end

  @doc """
  The `field` value of a `schema` row as text, or nil when empty. An enum value reads as its
  `MythweaverWeb.EnumLabels.label/3`.
  """
  @spec value(module(), atom(), term()) :: String.t() | nil
  def value(schema, field, atom) when is_atom(atom) and atom not in [nil, true, false],
    do: EnumLabels.label(schema, field, atom)

  def value(_schema, _field, value), do: value(value)

  defp value(nil), do: nil
  defp value(""), do: nil
  defp value([]), do: nil
  defp value(true), do: pgettext("status: a yes/no item field that is on", "Yes")
  defp value(false), do: pgettext("status: a yes/no item field that is off", "No")
  defp value(list) when is_list(list), do: Enum.join(list, ", ")

  defp value(%_{} = struct) do
    if String.Chars.impl_for(struct),
      do: to_string(struct),
      else: struct |> Map.from_struct() |> Map.delete(:__meta__) |> value()
  end

  defp value(map) when is_map(map) do
    case Map.reject(map, fn {_key, v} -> is_nil(v) end) do
      empty when map_size(empty) == 0 -> nil
      present -> Jason.encode!(present, pretty: true)
    end
  end

  defp value(other), do: to_string(other)

  @doc "The protected fields of `type`, lowercased, as one `Mythweaver.Format.list/1` string, for a runtime-only hint."
  @spec protected_labels(atom()) :: String.t()
  def protected_labels(type) do
    schema = Items.schema(type)

    type
    |> Items.protected_fields()
    |> Enum.map(&String.downcase(EnumLabels.field_label(schema, &1)))
    |> Mythweaver.Format.list()
  end
end
