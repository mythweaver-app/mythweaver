defmodule Mythweaver.Variables.Variable do
  @moduledoc """
  One named JSON value, read by templates through `vars`/`globals` and written by `{% setvar %}` /
  `{% setglobalvar %}`. A `nil` `chat_id` makes it global; a global's `user_id` is its owner (nil: the
  site's, see `Mythweaver.Variables`). Keys are unique per chat, and per owner among globals.
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Accounts.User
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Variables.JSONValue

  @type t :: %__MODULE__{}

  @key_format ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  schema "variables" do
    field :key, :string
    field :value, JSONValue

    belongs_to :chat, Chat
    belongs_to :user, User

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(variable, attrs) do
    variable
    |> cast(attrs, [:key])
    # A separate cast so `empty_values: []` keeps `""` a value instead of nil, while a blank key
    # still casts to nil and fails `validate_required`.
    |> cast(attrs, [:value], empty_values: [])
    |> validate_required([:key])
    # Not `validate_required`: `""` and `false` are legal values.
    |> validate_value_present()
    |> validate_length(:key, max: 64)
    |> validate_format(:key, @key_format,
      message:
        dgettext_noop(
          "errors",
          "must start with a letter or underscore and contain only letters, digits, and underscores"
        )
    )
    |> unique_constraint(:key, name: :variables_chat_key_index, message: dgettext_noop("errors", "is already taken"))
    |> unique_constraint(:key, name: :variables_global_key_index, message: dgettext_noop("errors", "is already taken"))
  end

  defp validate_value_present(changeset) do
    if is_nil(get_field(changeset, :value)) and not Keyword.has_key?(changeset.errors, :value),
      do: add_error(changeset, :value, dgettext_noop("errors", "can't be blank")),
      else: changeset
  end
end
