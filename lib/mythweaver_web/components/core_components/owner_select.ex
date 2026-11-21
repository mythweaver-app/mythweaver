defmodule MythweaverWeb.CoreComponents.OwnerSelect do
  @moduledoc """
  The Owner select of a new-item form: what anyone creates is their own by default, and a holder of
  the item schema's site permission may pick a site item instead; anyone else gets no select. It
  submits `"owner"` outside the item's params: read it with `choice/1`, pass `create_opts/1` to the
  context's create function and use `new_owner/3` wherever the form validates against the new
  item's owner.
  """

  use Phoenix.Component
  use Gettext, backend: Mythweaver.Gettext

  import MythweaverWeb.CoreComponents, only: [input: 1]
  import MythweaverWeb.CoreComponents.FieldRow, only: [field_row: 1]

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Characters.Character
  alias Mythweaver.Expressions
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Lore.LorePool
  alias Mythweaver.Memory
  alias Mythweaver.Ownership
  alias Mythweaver.Prompts.Block
  alias Mythweaver.Prompts.Outlet
  alias Mythweaver.Prompts.Prompt
  alias Mythweaver.Scripts.Script
  alias Mythweaver.Variables.Variable

  @type choice :: String.t()

  attr :id, :string, required: true, doc: "the select's id; its row is `<id>-row`"
  attr :scope, Scope, required: true
  attr :schema, :atom, required: true, doc: "the item schema, for its site permission and hint"
  attr :value, :string, required: true, doc: ~s(the current choice, `"personal"` or `"site"`)
  slot :inner_block, doc: "more hint text, after the default"

  def owner_select(assigns) do
    ~H"""
    <.field_row :if={Scope.can?(@scope, Ownership.site_permission(@schema))} id={"#{@id}-row"}>
      <:field>
        <.input
          name="owner"
          value={@value}
          type="select"
          label={pgettext("field label: who owns a new item", "Owner")}
          id={@id}
          options={[
            {pgettext("option: owner of a new item, the creator alone", "Personal (only me)"),
             "personal"},
            {pgettext("option: owner of a new item, the whole site", "Site (every user)"), "site"}
          ]}
        >
          <:hint>
            {owner_hint(@schema)} {render_slot(@inner_block)}
          </:hint>
        </.input>
      </:field>
    </.field_row>
    """
  end

  defp owner_hint(Character),
    do:
      gettext(
        "A personal character is yours alone, unless you share it. A site character can be used by every user, and only site managers edit it."
      )

  defp owner_hint(Expressions.Profile),
    do:
      gettext(
        "A personal expression profile is yours alone, unless you share it. A site expression profile can be used by every user, and only site managers edit it."
      )

  defp owner_hint(Variable),
    do:
      gettext(
        "A personal variable is yours alone, unless you share it. A site variable can be used by every user, and only site managers edit it."
      )

  defp owner_hint(LoreBook),
    do:
      gettext(
        "A personal book is yours alone, unless you share it. A site book can be used by every user, and only site managers edit it."
      )

  defp owner_hint(LorePool),
    do:
      gettext(
        "A personal pool is yours alone, unless you share it. A site pool can be used by every user, and only site managers edit it."
      )

  defp owner_hint(Memory.Profile),
    do:
      gettext(
        "A personal memory profile is yours alone, unless you share it. A site memory profile can be used by every user, and only site managers edit it."
      )

  defp owner_hint(Block),
    do:
      gettext(
        "A personal block is yours alone, unless you share it. A site block can be used by every user, and only site managers edit it."
      )

  defp owner_hint(Prompt),
    do:
      gettext(
        "A personal prompt is yours alone, unless you share it. A site prompt can be used by every user, and only site managers edit it."
      )

  defp owner_hint(Outlet),
    do:
      gettext(
        "A personal outlet is yours alone, unless you share it. A site outlet can be used by every user, and only site managers edit it."
      )

  defp owner_hint(Script),
    do:
      gettext(
        "A personal script is yours alone, unless you share it. A site script can be used by every user, and only site managers edit it."
      )

  defp owner_hint(Memory.SidePrompt),
    do:
      gettext(
        "A personal side prompt is yours alone, unless you share it. A site side prompt can be used by every user, and only site managers edit it."
      )

  defp owner_hint(Memory.SidePromptSet),
    do:
      gettext(
        "A personal side prompt set is yours alone, unless you share it. A site side prompt set can be used by every user, and only site managers edit it."
      )

  @doc ~s(The Owner choice in a new-item form's params: `"site"`, else `"personal"`.)
  @spec choice(map()) :: choice()
  def choice(%{"owner" => "site"}), do: "site"
  def choice(_params), do: "personal"

  @doc "The create function options for `choice`."
  @spec create_opts(choice()) :: keyword()
  def create_opts(choice), do: [site: choice == "site"]

  @doc "The owner a new `schema` item of `choice` gets (`Ownership.new_owner/3`), nil when `scope` may not create one."
  @spec new_owner(Scope.t(), module(), choice()) :: Ecto.UUID.t() | nil
  def new_owner(scope, schema, choice) do
    case Ownership.new_owner(scope, schema, create_opts(choice)) do
      {:ok, owner} -> owner
      {:error, :unauthorized} -> nil
    end
  end

  @doc "The owner a new `schema` item of `choice` gives its tag fields: `Ownership.new_owner/3`'s, else `scope`'s user."
  @spec tag_owner(Scope.t(), module(), choice()) :: Ecto.UUID.t() | nil
  def tag_owner(scope, schema, choice) do
    case Ownership.new_owner(scope, schema, create_opts(choice)) do
      {:ok, owner} -> owner
      {:error, _} -> scope.user.id
    end
  end

  @doc "Whether `row` is a site row; for a new one (nil), whether `choice` makes it the site's."
  @spec site_row?(map() | nil, Scope.t(), module(), choice()) :: boolean()
  def site_row?(nil, scope, schema, choice),
    do: match?({:ok, nil}, Ownership.new_owner(scope, schema, create_opts(choice)))

  def site_row?(%{user_id: user_id}, _scope, _schema, _choice), do: is_nil(user_id)
end
