defmodule Mythweaver.MCP.Token do
  @moduledoc """
  A personal access token an MCP client sends as `Authorization: Bearer <secret>`. Only the
  secret's SHA-256 is stored (`token_hash`), with its last four characters (`hint`) to tell tokens
  apart. `access` `:read_only` exposes only reading tools; `:full` every MCP tool, but without
  site administration; `:site` is everything `:full` has plus the owner's administration and
  moderation permissions.
  """
  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Accounts.User

  schema "mcp_tokens" do
    field :name, :string
    field :access, Ecto.Enum, values: [:read_only, :full, :site], default: :read_only
    field :token_hash, :binary, redact: true
    field :hint, :string
    field :last_used_at, :utc_datetime

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc "Casts the user-editable fields; `user_id`, `token_hash`, `hint` and `last_used_at` are set in code."
  def changeset(token, attrs) do
    token
    |> cast(attrs, [:name, :access])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :access])
    |> validate_length(:name, max: 80)
    |> unique_constraint(:name,
      name: :mcp_tokens_user_id_name_index,
      message: dgettext_noop("errors", "is already used by another token")
    )
  end
end
