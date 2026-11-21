defmodule Mythweaver.Tags.Tag do
  @moduledoc """
  One tag row of one domain: the site's (`user_id` nil) or one user's own.

  Identity is the canonical text (`text/1`): the site and a user may both hold a `lotr` row, and
  search, display, siblings and parents treat them as one tag. `ideal` is the row's sibling (the
  tag shown in its place) and `parents` the tags it implies; both are rows of the same domain.

  The virtual `text`, `ideal_text` and `parent_texts` are what the `/tags` form edits;
  `Mythweaver.Tags` resolves them to rows. `usage_count` is filled by `Tags.list_editable_tags/1`.
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Accounts.User
  alias Mythweaver.Tags
  alias Mythweaver.Tags.TagParent

  schema "tags" do
    field :namespace, :string, default: ""
    field :name, :string

    field :text, :string, virtual: true
    field :ideal_text, :string, virtual: true
    field :parent_texts, {:array, :string}, virtual: true, default: []
    field :usage_count, :integer, virtual: true

    # nil: a site tag. Set by `Mythweaver.Tags` from `Mythweaver.Ownership`; never cast.
    belongs_to :user, User
    belongs_to :ideal, __MODULE__

    many_to_many :parents, __MODULE__,
      join_through: TagParent,
      join_keys: [tag_id: :id, parent_tag_id: :id]

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(tag, attrs) do
    tag
    |> cast(attrs, [:text, :ideal_text, :parent_texts])
    |> validate_required([:text], message: dgettext_noop("errors", "needs a name"))
    |> put_text()
    |> update_change(:ideal_text, &blank_to_nil/1)
    |> update_change(:parent_texts, fn texts -> Enum.reject(texts, &(blank_to_nil(&1) == nil)) end)
    |> unique_constraint(:text,
      name: :tags_user_id_namespace_name_index,
      message: dgettext_noop("errors", "already exists; make one a sibling of the other instead")
    )
  end

  defp put_text(changeset) do
    case get_change(changeset, :text) do
      nil ->
        changeset

      text ->
        case Tags.normalize(text) do
          {:ok, {namespace, name, canonical}} ->
            changeset
            |> put_change(:namespace, namespace)
            |> put_change(:name, name)
            |> put_change(:text, canonical)

          {:error, message} ->
            add_error(changeset, :text, message)
        end
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(text), do: if(String.trim(text) != "", do: text)

  @doc "The canonical text of a row: `name`, or `namespace:name` when namespaced."
  @spec text(%__MODULE__{} | %{namespace: String.t(), name: String.t()}) :: String.t()
  def text(%{namespace: "", name: name}), do: name
  def text(%{namespace: namespace, name: name}), do: namespace <> ":" <> name
end
