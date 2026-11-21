defmodule Mythweaver.Notifications.PushSubscription do
  @moduledoc """
  One browser that receives the user's notifications by Web Push: the browser's `PushSubscription`
  (`endpoint` plus its `p256dh` and `auth` keys, encrypted at rest with `Mythweaver.Encrypted.Binary`)
  and a `label` naming the device ("Chrome on Android"). Only `Mythweaver.Notifications` writes it;
  `last_success_at` and `last_failure` are set by sends, never cast.

  The endpoint must be an `https` URL on a named host: the server posts to it, so a loopback or
  bare-IP address is refused. The keys must be what a browser sends: an uncompressed P-256 point and
  a 16-byte secret, url-safe base64.
  """

  use Gettext, backend: Mythweaver.Gettext
  use Mythweaver.Schema

  import Ecto.Changeset

  alias Mythweaver.Accounts.User
  alias Mythweaver.Encrypted.Binary

  schema "push_subscriptions" do
    belongs_to :user, User

    field :endpoint, :string
    field :p256dh, Binary, redact: true
    field :auth, Binary, redact: true
    field :label, :string
    field :last_success_at, :utc_datetime
    field :last_failure, :string

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc "A subscription from the browser's `PushSubscription.toJSON()` fields and a label."
  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:endpoint, :p256dh, :auth, :label])
    |> update_change(:label, &String.slice(String.trim(&1), 0, 80))
    |> update_change(:p256dh, &String.trim_trailing(&1, "="))
    |> update_change(:auth, &String.trim_trailing(&1, "="))
    |> validate_required([:endpoint, :p256dh, :auth, :label])
    |> validate_length(:endpoint, max: 2048)
    |> validate_change(:endpoint, &endpoint_error/2)
    |> validate_key(:p256dh, &match?(<<4, _::binary-size(64)>>, &1))
    |> validate_key(:auth, &(byte_size(&1) == 16))
    |> unique_constraint(:endpoint)
  end

  defp endpoint_error(:endpoint, endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        if host == "localhost" or match?({:ok, _}, :inet.parse_address(String.to_charlist(host))),
          do: [endpoint: dgettext_noop("errors", "must name a push service host")],
          else: []

      _ ->
        [endpoint: dgettext_noop("errors", "must be an https URL")]
    end
  end

  defp validate_key(changeset, field, valid?) do
    validate_change(changeset, field, fn ^field, value ->
      case Base.url_decode64(value, padding: false) do
        {:ok, key} -> if valid?.(key), do: [], else: [{field, dgettext_noop("errors", "is not a valid push key")}]
        :error -> [{field, dgettext_noop("errors", "is not url-safe base64")}]
      end
    end)
  end
end
