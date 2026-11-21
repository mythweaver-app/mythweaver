defmodule Mythweaver.Moderation.Warning do
  @moduledoc """
  A moderator's warning to an account (`Mythweaver.Moderation.Sanctions.warn/4`). Until
  `acknowledged_at` is set the account sees only the warning page (`MythweaverWeb.ModerationGate`).
  """

  use Mythweaver.Schema

  import Ecto.Changeset

  alias Mythweaver.Accounts.User
  alias Mythweaver.Moderation.Report

  @type t :: %__MODULE__{}

  schema "moderation_warnings" do
    field :reason, :string
    field :acknowledged_at, :utc_datetime

    belongs_to :user, User
    belongs_to :issued_by, User
    belongs_to :report, Report

    timestamps(type: :utc_datetime)
  end

  @doc "A changeset for the warning's reason."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(warning, attrs) do
    warning
    |> cast(attrs, [:reason])
    |> validate_required([:reason])
    |> validate_length(:reason, max: 2000)
  end
end
