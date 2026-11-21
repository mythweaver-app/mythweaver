defmodule Mythweaver.Moderation.Fingerprint do
  @moduledoc """
  One signal an account was seen with (`Mythweaver.Moderation.Fingerprints`): a client IP address,
  user agent, Accept-Language, device cookie or browser fingerprint hash, with when it was first and
  last seen and how often. Rows go a year after `last_seen_at`.

  `geo` is GeoLite2 data for an `:ip` row (`Mythweaver.Moderation.GeoIP.lookup/1`, string keys),
  set by `Fingerprints.record/2` on each sighting; nil for other kinds and without a database.
  """

  use Mythweaver.Schema

  alias Mythweaver.Accounts.User

  @type t :: %__MODULE__{}
  @type kind :: :ip | :user_agent | :language | :device | :fingerprint

  schema "account_fingerprints" do
    field :kind, Ecto.Enum, values: [:ip, :user_agent, :language, :device, :fingerprint]
    field :value, :string
    field :first_seen_at, :utc_datetime
    field :last_seen_at, :utc_datetime
    field :seen_count, :integer, default: 1
    field :geo, :map

    belongs_to :user, User
  end
end
