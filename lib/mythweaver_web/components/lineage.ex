defmodule MythweaverWeb.Lineage do
  @moduledoc """
  The "Cloned from …" line under a cloned item's editor header (`#<thing>-lineage`,
  `Mythweaver.Sharing.Clone` sets `cloned_from_type`/`cloned_from_id`): the source's name while it
  exists and the viewer may use it, else "a removed item". Renders nothing for an item that is no
  clone.

  Attrs: `id`, `thing` (the id prefix, e.g. `"character"`), `current_scope`, `item`.
  """

  use MythweaverWeb, :live_component

  alias Mythweaver.Ownership
  alias Mythweaver.Sharing.Items

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(id: assigns.id, thing: assigns.thing)
     |> assign(source: source(assigns.current_scope, assigns.item))}
  end

  defp source(scope, %{cloned_from_type: type, cloned_from_id: id}) when not is_nil(type) and is_binary(id) do
    case Items.get(type, id) do
      nil -> :removed
      row -> if Ownership.usable?(scope, row), do: row.name, else: :removed
    end
  end

  defp source(_scope, _item), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      div:scope.lineage {
        display: contents;
      }

      p {
        margin: 0;
        padding: var(--size-1) var(--size-3);
        color: var(--muted-foreground);
        font-size: 0.875rem;
      }
    </style>
    <div id={@id} class="lineage">
      <p :if={@source} id={"#{@thing}-lineage"}>
        {if @source == :removed,
          do: gettext("Cloned from a removed item"),
          else:
            pgettext("status: the item this one was copied from", "Cloned from %{source_name}",
              source_name: @source
            )}
      </p>
    </div>
    """
  end
end
