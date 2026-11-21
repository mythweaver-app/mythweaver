defmodule MythweaverWeb.TagFields do
  @moduledoc """
  The tag fields of an editor form, and the socket state behind them.

  State lives in `socket.assigns.tag_fields`, a map from a key (`:item` on a pane editor; `:book` and
  `:entry` on the lore page; `:chat` on the chat page) to one form's fields, so two forms on one page
  stay apart. Shared `tag_vocabulary` and `tag_graph` assigns hold the viewer's suggestions and
  rules.

  A site item edited by a content manager gets two lists, "Site tags" (everyone sees them) and "My
  tags"; anything else gets one "Tags" list of the viewer's own. Values are kept normalized; an
  invalid chip stays as typed, marked, with its message under its list, and `save_tags/3` then
  refuses to write.

  Wiring: `assign_tag_fields/4` when the form loads, `put_tag_params/3` in its validate handler,
  `save_tags/3` after the item itself saved, and `tag_fields/1` in the form.
  """

  use Phoenix.Component
  use Gettext, backend: Mythweaver.Gettext

  import MythweaverWeb.CoreComponents.TagInput, only: [tag_input: 1]

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Tags
  alias Mythweaver.Tags.Graph
  alias MythweaverWeb.CoreComponents.OwnerSelect
  alias Phoenix.LiveView.Socket

  @type field :: %{
          owner_id: Ecto.UUID.t() | nil,
          site?: boolean(),
          site: [String.t()],
          mine: [String.t()],
          invalid: [String.t()],
          errors: %{site: [String.t()], mine: [String.t()]},
          implied: [String.t()]
        }

  @doc """
  Loads the tag fields under `key` for `item` (nil: a new one) owned by `owner_id`, and refreshes
  the viewer's `tag_graph` and `tag_vocabulary`.
  """
  @spec assign_tag_fields(Socket.t(), atom(), struct() | nil, Ecto.UUID.t() | nil) :: Socket.t()
  def assign_tag_fields(socket, key, item, owner_id) do
    scope = socket.assigns.current_scope
    graph = Tags.graph(scope.user.id)
    values = if item, do: Tags.item_tags(scope, item), else: %{site: [], mine: []}

    field = %{
      owner_id: owner_id,
      site?: site?(scope, owner_id) and not match?(%Chat{}, item),
      site: values.site,
      mine: values.mine,
      invalid: [],
      errors: %{site: [], mine: []},
      implied: []
    }

    socket
    |> assign(tag_graph: graph, tag_vocabulary: Tags.vocabulary(scope.user.id, graph))
    |> put_field(key, field)
  end

  defp site?(scope, owner_id), do: owner_id == nil and Scope.can?(scope, "site.content.manage")

  @doc "Re-decides whether a new form shows site tags after its Owner choice changed."
  @spec put_owner(Socket.t(), atom(), Ecto.UUID.t() | nil) :: Socket.t()
  def put_owner(socket, key, owner_id) do
    field = socket.assigns.tag_fields[key]
    put_field(socket, key, %{field | owner_id: owner_id, site?: site?(socket.assigns.current_scope, owner_id)})
  end

  @doc """
  On a new item's form (`editing_key`'s assign nil), a changed Owner `choice`: stores it in
  `:new_owner` and moves the `:item` tag field to the owner a new `schema` row gets.
  """
  @spec put_new_owner(Socket.t(), atom(), module(), String.t() | nil) :: Socket.t()
  def put_new_owner(socket, editing_key, schema, choice) do
    if is_nil(socket.assigns[editing_key]) and choice != socket.assigns.new_owner,
      do:
        socket
        |> assign(new_owner: choice)
        |> put_owner(:item, OwnerSelect.tag_owner(socket.assigns.current_scope, schema, choice)),
      else: socket
  end

  @doc """
  Takes a validate event's tag lists (`%{"site" => [...], "mine" => [...]}`; nil or a missing list
  keeps the current values), normalizing each value and marking invalid ones.
  """
  @spec put_tag_params(Socket.t(), atom(), map() | nil) :: Socket.t()
  def put_tag_params(socket, _key, nil), do: socket

  def put_tag_params(socket, key, params) when is_map(params) do
    field = socket.assigns.tag_fields[key]

    {field, invalid} =
      Enum.reduce([:site, :mine], {field, []}, fn list, {acc, invalid} ->
        case Map.fetch(params, Atom.to_string(list)) do
          {:ok, raws} ->
            {values, bad, errors} = Tags.normalize_list(raws)
            {%{acc | list => values, errors: Map.put(acc.errors, list, errors)}, invalid ++ bad}

          :error ->
            {acc, invalid ++ Enum.filter(Map.fetch!(acc, list), &(&1 in acc.invalid))}
        end
      end)

    put_field(socket, key, %{field | invalid: invalid})
  end

  # Stores `field` with its implied tags recomputed from both lists.
  defp put_field(socket, key, field) do
    valid = Enum.reject(field.site ++ field.mine, &(&1 in field.invalid))
    %{implied: implied} = Graph.display(socket.assigns.tag_graph, valid)
    fields = Map.get(socket.assigns, :tag_fields, %{})
    assign(socket, :tag_fields, Map.put(fields, key, %{field | implied: implied}))
  end

  @doc """
  Writes the fields under `key` onto the saved `item` and reloads them. `{:error, "its tags",
  socket}` when a value is invalid or a write is refused; the caller's flash names the item.
  """
  @spec save_tags(Socket.t(), atom(), struct()) :: {:ok, Socket.t()} | {:error, String.t(), Socket.t()}
  def save_tags(socket, key, item) do
    scope = socket.assigns.current_scope
    field = socket.assigns.tag_fields[key]

    if field.errors.site != [] or field.errors.mine != [] do
      {:error, "its tags", socket}
    else
      site = if field.site? and item.user_id == nil, do: [Tags.set_item_tags(scope, item, :site, field.site)], else: []
      results = [Tags.set_item_tags(scope, item, :mine, field.mine) | site]

      if Enum.all?(results, &(&1 == :ok)),
        do: {:ok, assign_tag_fields(socket, key, item, item.user_id)},
        else: {:error, "its tags", socket}
    end
  end

  @doc """
  The tag writes a held create (`Mythweaver.Moderation.Holds`) runs once approved: the fields under
  `key` as `{Mythweaver.Tags, :set_item_tags, [:row, domain, texts]}` followups, site tags only for
  a site item (`create_opts` carry `site: true`). Invalid values are dropped, as `save_tags/3` would
  refuse them.
  """
  @spec tag_followups(Socket.t(), atom(), keyword()) :: [{module(), atom(), list()}]
  def tag_followups(socket, key, create_opts) do
    socket.assigns
    |> Map.get(:tag_fields, %{})
    |> Map.get(key)
    |> case do
      nil ->
        []

      field ->
        valid = &Enum.reject(&1, fn text -> text in field.invalid end)

        site =
          if field.site? and create_opts[:site],
            do: [{Tags, :set_item_tags, [:row, :site, valid.(field.site)]}],
            else: []

        [{Tags, :set_item_tags, [:row, :mine, valid.(field.mine)]} | site]
    end
  end

  @doc "Drops the fields under `key` (a closed form)."
  @spec drop_tag_fields(Socket.t(), atom()) :: Socket.t()
  def drop_tag_fields(socket, key),
    do: assign(socket, :tag_fields, Map.delete(Map.get(socket.assigns, :tag_fields, %{}), key))

  attr :id, :string, required: true
  attr :prefix, :string, default: "tags", doc: "the params key the lists post under, e.g. \"lore_entry[tags]\""
  attr :field, :map, required: true, doc: "one `tag_fields` entry"
  attr :vocabulary, :list, required: true

  @doc ~s(One "Tags" list, or "Site tags" and "My tags" on a site item a content manager edits.)
  def tag_fields(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      :scope {
        display: flex;
        flex-direction: column;
        gap: var(--size-3);
      }
    </style>
    <div id={@id} class="tag-fields">
      <.tag_input
        :if={@field.site?}
        id={"#{@id}-site"}
        name={"#{@prefix}[site][]"}
        label={dpgettext("tags", "field label: site-wide tags of an item", "Site tags")}
        values={@field.site}
        vocabulary={@vocabulary}
        invalid={@field.invalid}
        errors={@field.errors.site}
      >
        <:hint>
          {dpgettext(
            "tags",
            "field label: hint under an item's site-wide tags, who sees them",
            "Everyone sees these."
          )}
        </:hint>
      </.tag_input>
      <.tag_input
        id={"#{@id}-mine"}
        name={"#{@prefix}[mine][]"}
        label={
          if(@field.site?,
            do: dpgettext("tags", "field label: the viewer's own tags of a site item", "My tags"),
            else: dpgettext("tags", "field label: the viewer's own tags of an item", "Tags")
          )
        }
        values={@field.mine}
        vocabulary={@vocabulary}
        invalid={@field.invalid}
        errors={@field.errors.mine}
        implied={@field.implied}
      >
        <:hint :if={@field.site?}>
          {dpgettext(
            "tags",
            "field label: hint under the viewer's own tags of a site item, who sees them",
            "Only you see these."
          )}
        </:hint>
      </.tag_input>
    </div>
    """
  end
end
