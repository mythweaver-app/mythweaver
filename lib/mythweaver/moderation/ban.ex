defmodule Mythweaver.Moderation.Ban do
  @moduledoc """
  One ban (`Mythweaver.Moderation.Sanctions`): an `:account` suspension (`value` nil), or a ban of
  one `:device` cookie, browser `:fingerprint` hash or `:ip` address (`value` set). `user` is the
  suspended account, or the account the value was seen on. A ban ends at `ends_at` (nil: never) or
  when lifted.
  """

  use Mythweaver.Schema

  import Ecto.Changeset

  alias Mythweaver.Accounts.User
  alias Mythweaver.Moderation.Report

  @type t :: %__MODULE__{}
  @type kind :: :account | :device | :fingerprint | :ip

  @kinds [:account, :device, :fingerprint, :ip]

  schema "moderation_bans" do
    field :kind, Ecto.Enum, values: @kinds
    field :value, :string
    field :reason, :string
    field :ends_at, :utc_datetime
    field :lifted_at, :utc_datetime

    belongs_to :user, User
    belongs_to :issued_by, User
    belongs_to :lifted_by, User
    belongs_to :report, Report

    timestamps(type: :utc_datetime)
  end

  @doc "Every ban kind."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "A changeset for the ban's reason."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(ban, attrs) do
    ban
    |> cast(attrs, [:reason])
    |> validate_required([:reason])
    |> validate_length(:reason, max: 2000)
    |> check_constraint(:value, name: :value_matches_kind)
  end

  @doc "Whether `ban` is in force at `now`: not lifted and not past its end."
  @spec active?(t(), DateTime.t()) :: boolean()
  def active?(%__MODULE__{lifted_at: lifted_at, ends_at: ends_at}, now) do
    is_nil(lifted_at) and (is_nil(ends_at) or DateTime.after?(ends_at, now))
  end
end
