defmodule Mythweaver.Moderation do
  @moduledoc """
  The moderation panel's shared pieces. Reports (`Mythweaver.Moderation.Reports`), warnings and bans
  (`Sanctions`), account fingerprints (`Fingerprints`), lookup of any content (`Lookup`) and the
  moderation log (`Log`) are their own modules; this one holds what they share: the panel's PubSub
  topic and who may open an account's moderation record.

  Every report create or resolve, warning, ban, lift and moderator delete calls `broadcast_changed/0`,
  so every open moderation screen reloads.

  Content moderation (`Moderation.Modes`, `Moderation.Gate`, `Moderation.Holds`, `Moderation.Rules`,
  `Moderation.Scanner`) reads its settings through `config/1`; a submitter's own held items change
  on `user_topic/1` (`broadcast_submissions_changed/1`).
  """

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User

  @record_keys [
    "moderation.accounts.sanction",
    "moderation.fingerprints",
    "moderation.content.view",
    "moderation.reports"
  ]

  @doc "The PubSub topic every moderation screen listens on."
  @spec topic() :: String.t()
  def topic, do: "moderation"

  @doc "Subscribes the caller to `topic/0`."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Mythweaver.PubSub, topic())

  @doc "Tells every moderation screen to reload: `{Mythweaver.Moderation, :changed}`."
  @spec broadcast_changed() :: :ok
  def broadcast_changed, do: Phoenix.PubSub.broadcast(Mythweaver.PubSub, topic(), {__MODULE__, :changed})

  @doc "The content-moderation setting `key` (`config :mythweaver, Mythweaver.Moderation`)."
  @spec config(atom()) :: term()
  def config(key), do: :mythweaver |> Application.get_env(__MODULE__, []) |> Keyword.get(key)

  @doc "The public base URL webhook callbacks reach, or nil when unset or blank."
  @spec callback_url() :: String.t() | nil
  def callback_url do
    case config(:callback_url) do
      url when is_binary(url) -> if String.trim(url) != "", do: String.trim_trailing(url, "/")
      _ -> nil
    end
  end

  @doc "The PubSub topic a submitter's held items change on."
  @spec user_topic(Ecto.UUID.t()) :: String.t()
  def user_topic(user_id), do: "moderation:user:#{user_id}"

  @doc "Subscribes the caller to `user_topic/1`."
  @spec subscribe_user(Ecto.UUID.t()) :: :ok | {:error, term()}
  def subscribe_user(user_id), do: Phoenix.PubSub.subscribe(Mythweaver.PubSub, user_topic(user_id))

  @doc "Tells `user_id`'s open submission lists to reload: `{Mythweaver.Moderation, :submissions_changed}`."
  @spec broadcast_submissions_changed(Ecto.UUID.t()) :: :ok
  def broadcast_submissions_changed(user_id),
    do: Phoenix.PubSub.broadcast(Mythweaver.PubSub, user_topic(user_id), {__MODULE__, :submissions_changed})

  @doc "The keys any of which opens an account's moderation record (and the lookup page)."
  @spec record_keys() :: [String.t()]
  def record_keys, do: @record_keys

  @doc "`:ok` when `scope` may open `user`'s moderation record: any `record_keys/0`, and only owners open owners."
  @spec authorize_record(Scope.t(), User.t()) :: :ok | {:error, :unauthorized}
  def authorize_record(%Scope{} = scope, %User{} = user) do
    if Enum.any?(@record_keys, &Scope.can?(scope, &1)) and (Scope.owner?(scope) or user.role != :owner),
      do: :ok,
      else: {:error, :unauthorized}
  end

  @doc "`:ok` unless `owner` is an owner-role account and `scope` is not an owner."
  @spec authorize_owned_by(Scope.t(), User.t() | nil) :: :ok | {:error, :unauthorized}
  def authorize_owned_by(%Scope{} = scope, %User{role: :owner}),
    do: if(Scope.owner?(scope), do: :ok, else: {:error, :unauthorized})

  def authorize_owned_by(%Scope{}, _owner), do: :ok

  @doc "`:ok` when `user` may be warned or suspended by `scope`: never an owner, never oneself."
  @spec sanctionable(Scope.t(), User.t()) :: :ok | {:error, :unauthorized | :self | :owner}
  def sanctionable(%Scope{}, %User{role: :owner}), do: {:error, :owner}
  def sanctionable(%Scope{user: %User{id: id}}, %User{id: id}), do: {:error, :self}
  def sanctionable(%Scope{user: %User{}}, %User{}), do: :ok
  def sanctionable(_scope, _user), do: {:error, :unauthorized}
end
