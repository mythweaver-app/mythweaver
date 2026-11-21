defmodule MythweaverWeb.TagFilter do
  @moduledoc """
  A list's tag filter: chips in its `pane_search` form, ANDed together (`-tag` excludes, `ns:*` any
  tag in a namespace), matched against each item's expanded tags in the viewer's view.

  Wiring: `assign_tag_filter/2` in `mount` and in the `"filter"` handler, `filter_tagged/3` on the
  list before `Pane.stream_search/4`, and `tag_filter/1` inside `pane_search`.
  """

  use Phoenix.Component
  use Gettext, backend: Mythweaver.Gettext

  import MythweaverWeb.CoreComponents.TagInput, only: [tag_input: 1]

  alias Mythweaver.Tags
  alias Mythweaver.Tags.Tagging
  alias Phoenix.LiveView.Socket

  @doc """
  Assigns `tag_filter` (the chips), `tag_predicates`, `tag_filter_errors` and `tag_filter_invalid`
  from a filter event's params, and the viewer's `tag_graph`/`tag_vocabulary` when missing.
  """
  @spec assign_tag_filter(Socket.t(), map()) :: Socket.t()
  def assign_tag_filter(socket, params \\ %{}) do
    %{values: values, predicates: predicates, errors: errors, invalid: invalid} = parse(params)
    viewer = socket.assigns.current_scope.user.id

    socket
    |> assign(tag_filter: values, tag_predicates: predicates, tag_filter_errors: errors, tag_filter_invalid: invalid)
    |> assign_new(:tag_graph, fn -> Tags.graph(viewer) end)
    |> then(&assign_new(&1, :tag_vocabulary, fn -> Tags.vocabulary(viewer, &1.assigns.tag_graph) end))
  end

  @doc "Reloads the viewer's `tag_graph` and `tag_vocabulary` (after a tag or tag rule changed)."
  @spec refresh_graph(Socket.t()) :: Socket.t()
  def refresh_graph(socket) do
    viewer = socket.assigns.current_scope.user.id
    graph = Tags.graph(viewer)
    assign(socket, tag_graph: graph, tag_vocabulary: Tags.vocabulary(viewer, graph))
  end

  @doc """
  A filter event's chips (`params["tag_filter"]`, `""` dropped): the `values` as typed, the valid
  ones' `predicates`, and the invalid ones (`invalid`) with their `"raw: message"` `errors`.
  """
  @spec parse(map()) :: %{
          values: [String.t()],
          predicates: [Tags.predicate()],
          errors: [String.t()],
          invalid: [String.t()]
        }
  def parse(params) do
    values = params["tag_filter"] |> List.wrap() |> Enum.reject(&(&1 == ""))
    {predicates, errors} = Tags.parse_predicates(values)

    %{
      values: values,
      predicates: predicates,
      errors: Enum.map(errors, fn {raw, message} -> Tags.problem_text(raw, message) end),
      invalid: Enum.map(errors, &elem(&1, 0))
    }
  end

  @doc "The `kind` items that pass the current tag filter (all of them when it is empty)."
  @spec filter_tagged(Socket.t(), [struct()], Tagging.kind()) :: [struct()]
  def filter_tagged(socket, items, kind) do
    %{current_scope: scope, tag_graph: graph, tag_predicates: predicates} = socket.assigns
    Tags.filter_items(items, kind, scope.user.id, graph, predicates)
  end

  attr :id, :string, required: true
  attr :values, :list, required: true
  attr :vocabulary, :list, required: true
  attr :errors, :list, default: []
  attr :invalid, :list, default: []
  attr :name, :string, default: "tag_filter[]"
  attr :input_attrs, :list, default: []

  @doc "The filter's chip input, posting `name` (default `tag_filter[]`) with the surrounding form."
  def tag_filter(assigns) do
    ~H"""
    <.tag_input
      id={@id}
      name={@name}
      label={dpgettext("tags", "field label: tag filter of a list", "Tags")}
      mode="filter"
      placeholder="series:metroid  -color:red  character:*"
      values={@values}
      vocabulary={@vocabulary}
      errors={@errors}
      invalid={@invalid}
      input_attrs={@input_attrs}
    />
    """
  end
end
