defmodule Mythweaver.Moderation.Sanctions do
  @moduledoc """
  Warnings and bans.

  A warning (`warn/4`, `"moderation.accounts.sanction"`) goes to the account's inbox and, until
  acknowledged (`acknowledge_warnings/1`), keeps it on the warning page (`MythweaverWeb.ModerationGate`).

  A ban (`ban/3`, sudo mode) is one `Mythweaver.Moderation.Ban` row per target: the account
  itself (`"moderation.accounts.sanction"`; deletes every session token, so all its browsers are
  logged out) and any of its recent device ids, browser fingerprints and IP addresses
  (`"moderation.fingerprints"`). It lasts for one of `duration_options/0`, or for good. `active_ban/2`
  is what login (`UserSessionController`), every browser request (`MythweaverWeb.BanGate`), every
  LiveView mount (`ModerationGate`) and MCP (`Mythweaver.MCP.authenticate/2`) check. Owners are never
  sanctioned, nor is the moderator themself; network bans never apply to owners, and a moderator
  cannot ban a value they were seen with themselves.
  """

  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Query

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.Accounts.UserToken
  alias Mythweaver.Format
  alias Mythweaver.Moderation
  alias Mythweaver.Moderation.Ban
  alias Mythweaver.Moderation.Fingerprints
  alias Mythweaver.Moderation.Log
  alias Mythweaver.Moderation.Report
  alias Mythweaver.Moderation.Reports
  alias Mythweaver.Moderation.Warning
  alias Mythweaver.Notifications
  alias Mythweaver.Repo

  @durations [{"1d", 1}, {"3d", 3}, {"7d", 7}, {"30d", 30}, {"90d", 90}, {"365d", 365}, {"permanent", nil}]

  @value_kinds %{"device" => :device, "fingerprint" => :fingerprint, "ip" => :ip}

  @doc "The ban form's durations: `{label, value}`."
  @spec duration_options() :: [{String.t(), String.t()}]
  def duration_options, do: for({value, days} <- @durations, do: {duration_label(days), value})

  defp duration_label(nil), do: dpgettext("moderation", "option: how long a ban lasts", "Permanent")
  defp duration_label(365), do: dpgettext("moderation", "option: how long a ban lasts", "1 year")

  defp duration_label(days) do
    dpngettext("moderation", "option: how long a ban lasts", "%{day_count} day", "%{day_count} days", days,
      day_count: Format.number(days)
    )
  end

  ## Bans

  @doc """
  Bans `user` per `params` (the form's string keys): `"reason"`, `"duration"` (a
  `duration_options/0` value), `"account"` (`"true"` suspends the account), `"values"`
  (`"<device|fingerprint|ip>:<value>"` strings, values `user` was seen with) and an optional
  `"report_id"` the ban resolves. Returns the bans and `tokens`, which the caller disconnects
  (`MythweaverWeb.UserAuth.disconnect_sessions/1`). `tokens` are the sessions to disconnect: the
  account's (deleted) for an account ban, plus every session of each account seen with a banned
  value; `ModerationGate` refuses their remount.
  """
  @spec ban(Scope.t(), User.t(), map()) ::
          {:ok, %{bans: [Ban.t()], tokens: [UserToken.t()]}}
          | {:error,
             :sudo_required
             | :unauthorized
             | :self
             | :owner
             | :no_targets
             | :own_signal
             | :unknown_value
             | Ecto.Changeset.t()}
  def ban(%Scope{user: %User{} = actor_user} = actor, %User{} = user, params) when is_map(params) do
    account? = params["account"] in ["true", true]
    values = params["values"] |> List.wrap() |> Enum.map(&parse_value/1)

    with :ok <- Accounts.authorize_sudo(actor),
         :ok <- if(account? or values != [], do: :ok, else: {:error, :no_targets}),
         :ok <- Moderation.sanctionable(actor, user),
         :ok <- authorize_account(actor, user, account?),
         :ok <- authorize_values(actor, user, values),
         {:ok, ends_at} <- ends_at(params) do
      reason = params["reason"]
      report_id = report_about(params["report_id"], user.id)

      targets = if(account?, do: [{:account, nil}], else: []) ++ values

      changesets =
        for {kind, value} <- targets do
          %Ban{
            kind: kind,
            value: value,
            user_id: user.id,
            issued_by_id: actor_user.id,
            ends_at: ends_at,
            report_id: report_id
          }
          |> Ban.changeset(%{reason: reason})
        end

      case Enum.find(changesets, &(not &1.valid?)) do
        nil -> insert_bans(actor, user, changesets, account?, values, report_id)
        changeset -> {:error, %{changeset | action: :insert}}
      end
    end
  end

  defp insert_bans(actor, user, changesets, account?, values, report_id) do
    {:ok, result} =
      Repo.transact(fn ->
        bans = Enum.map(changesets, &Repo.insert!/1)
        tokens = if account?, do: Accounts.session_tokens(user), else: []
        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens, & &1.id)))
        {:ok, %{bans: bans, tokens: tokens}}
      end)

    for ban <- result.bans do
      :ok =
        Log.record(actor, :banned, :ban, ban.id, user.id, %{
          "kind" => to_string(ban.kind),
          "value" => ban.value,
          "reason" => ban.reason,
          "ends_at" => ban.ends_at && DateTime.to_iso8601(ban.ends_at)
        })
    end

    :ok = Reports.resolve(actor, report_id)
    Moderation.broadcast_changed()

    tokens =
      result.tokens ++ Enum.flat_map(Fingerprints.user_ids_with(values), &Accounts.session_tokens(%User{id: &1}))

    {:ok, %{result | tokens: tokens}}
  end

  defp parse_value(string) when is_binary(string) do
    case String.split(string, ":", parts: 2) do
      [kind, value] when value != "" -> {Map.get(@value_kinds, kind), value}
      _ -> {nil, string}
    end
  end

  defp parse_value(other), do: {nil, other}

  defp authorize_account(_actor, _user, false), do: :ok

  defp authorize_account(actor, _user, true), do: Scope.authorize(actor, "moderation.accounts.sanction")

  defp authorize_values(_actor, _user, []), do: :ok

  defp authorize_values(%Scope{user: actor_user} = actor, user, values) do
    with :ok <- Scope.authorize(actor, "moderation.fingerprints") do
      Enum.reduce_while(values, :ok, fn
        {nil, _value}, _acc ->
          {:halt, {:error, :unknown_value}}

        {kind, value}, _acc ->
          cond do
            not Fingerprints.owns_value?(user.id, kind, value) -> {:halt, {:error, :unknown_value}}
            Fingerprints.owns_value?(actor_user.id, kind, value) -> {:halt, {:error, :own_signal}}
            true -> {:cont, :ok}
          end
      end)
    end
  end

  defp ends_at(params) do
    case List.keyfind(@durations, params["duration"], 0) do
      {_value, nil} ->
        {:ok, nil}

      {_value, days} ->
        {:ok, DateTime.add(DateTime.utc_now(:second), days, :day)}

      nil ->
        changeset =
          %Ban{}
          |> Ban.changeset(%{reason: params["reason"]})
          |> Ecto.Changeset.add_error(:ends_at, dgettext_noop("errors", "is not a valid duration"))

        {:error, %{changeset | action: :insert}}
    end
  end

  # An open report about `user_id`, else nil: a sanction resolves only its own account's report.
  defp report_about(id, user_id) when is_binary(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         true <-
           Repo.exists?(from(r in Report, where: r.id == ^id and r.status == :open and r.subject_user_id == ^user_id)) do
      id
    else
      _ -> nil
    end
  end

  defp report_about(_id, _user_id), do: nil

  @doc "Lifts the active ban `ban_id` (sudo mode; an account ban needs sanction, others fingerprints)."
  @spec lift_ban(Scope.t(), String.t()) :: {:ok, Ban.t()} | {:error, :sudo_required | :unauthorized | :not_found}
  def lift_ban(%Scope{user: %User{id: uid}} = actor, ban_id) do
    now = DateTime.utc_now(:second)

    with :ok <- Accounts.authorize_sudo(actor),
         {:ok, id} <- Ecto.UUID.cast(ban_id) |> found(),
         %Ban{} = ban <- Repo.get(Ban, id),
         :ok <- Scope.authorize(actor, kind_key(ban.kind)),
         true <- Ban.active?(ban, now) do
      ban = ban |> Ecto.Changeset.change(lifted_at: now, lifted_by_id: uid) |> Repo.update!()

      :ok =
        Log.record(actor, :ban_lifted, :ban, ban.id, ban.user_id, %{
          "kind" => to_string(ban.kind),
          "value" => ban.value
        })

      Moderation.broadcast_changed()
      {:ok, ban}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end

  defp found({:ok, id}), do: {:ok, id}
  defp found(:error), do: {:error, :not_found}

  defp kind_key(:account), do: "moderation.accounts.sanction"
  defp kind_key(_kind), do: "moderation.fingerprints"

  @doc "Whether `scope` may list and lift bans of `kind`."
  @spec can_list?(Scope.t(), Ban.kind()) :: boolean()
  def can_list?(scope, kind), do: Scope.can?(scope, kind_key(kind))

  @doc """
  The newest 500 bans of `kind`, `:active` ones or `:all`, with `:user`, `:issued_by` and
  `:lifted_by`; `[]` when `scope` may not list that kind.
  """
  @spec list_bans(Scope.t(), Ban.kind(), :active | :all) :: [Ban.t()]
  def list_bans(%Scope{} = scope, kind, state) when state in [:active, :all] do
    if kind in Ban.kinds() and can_list?(scope, kind) do
      Ban
      |> where([b], b.kind == ^kind)
      |> filter_state(state)
      |> order_by([b], desc: b.inserted_at, desc: b.id)
      |> limit(500)
      |> preload([:user, :issued_by, :lifted_by])
      |> Repo.all()
    else
      []
    end
  end

  defp filter_state(query, :all), do: query

  defp filter_state(query, :active) do
    now = DateTime.utc_now(:second)
    where(query, [b], is_nil(b.lifted_at) and (is_nil(b.ends_at) or b.ends_at > ^now))
  end

  @doc "Every ban issued against `user_id` (the account or values seen on it), newest first."
  @spec bans_for(Ecto.UUID.t()) :: [Ban.t()]
  def bans_for(user_id) do
    Repo.all(
      from(b in Ban,
        where: b.user_id == ^user_id,
        order_by: [desc: b.inserted_at, desc: b.id],
        preload: [:user, :issued_by, :lifted_by]
      )
    )
  end

  @doc """
  The ban in force on `user` or any of `signals`' IP, device and browser fingerprint, account bans
  first; nil when none. Owners answer only to account bans, which never name an owner.
  """
  @spec active_ban(User.t(), map()) :: Ban.t() | nil
  def active_ban(%User{} = user, signals) do
    now = DateTime.utc_now(:second)

    matches =
      if user.role == :owner do
        dynamic([b], b.kind == :account and b.user_id == ^user.id)
      else
        for kind <- Fingerprints.linking_kinds(),
            value = signals[kind],
            is_binary(value),
            reduce: dynamic([b], b.kind == :account and b.user_id == ^user.id) do
          acc -> dynamic([b], ^acc or (b.kind == ^kind and b.value == ^value))
        end
      end

    Repo.one(
      from(b in Ban,
        where: ^matches,
        where: is_nil(b.lifted_at) and (is_nil(b.ends_at) or b.ends_at > ^now),
        order_by: [fragment("CASE ? WHEN 'account' THEN 0 ELSE 1 END", b.kind), desc: b.inserted_at],
        limit: 1
      )
    )
  end

  @doc "What a banned login or request is told."
  @spec refusal_message(Ban.t()) :: String.t()
  def refusal_message(%Ban{kind: :account, ends_at: nil, reason: reason}) do
    gettext_comment(
      "Flash on the login page when a permanently suspended account signs in or is logged out; the reason is what the moderator wrote."
    )

    dgettext("moderation", "Your account is suspended: %{reason_text}", reason_text: reason)
  end

  def refusal_message(%Ban{kind: :account, ends_at: ends_at, reason: reason}) do
    gettext_comment(
      "Flash on the login page when a suspended account signs in or is logged out; the date is when the suspension ends, the reason is what the moderator wrote."
    )

    dgettext("moderation", "Your account is suspended until %{ends_at}: %{reason_text}",
      ends_at: Format.datetime_utc(ends_at),
      reason_text: reason
    )
  end

  def refusal_message(%Ban{}) do
    gettext_comment("Flash on the login page when the device, browser or network is banned.")
    dgettext("moderation", "Logins from this device or network are blocked.")
  end

  ## Warnings

  @doc """
  Warns `user` for `reason`, optionally resolving `report_id`. The caller disconnects `user`'s
  sessions (`MythweaverWeb.UserAuth.disconnect_users/1`), so open tabs remount onto the warning page.
  """
  @spec warn(Scope.t(), User.t(), String.t(), String.t() | nil) ::
          {:ok, Warning.t()} | {:error, :unauthorized | :self | :owner | Ecto.Changeset.t()}
  def warn(%Scope{user: %User{id: uid}} = actor, %User{} = user, reason, report_id \\ nil) do
    report_id = report_about(report_id, user.id)

    with :ok <- Scope.authorize(actor, "moderation.accounts.sanction"),
         :ok <- Moderation.sanctionable(actor, user),
         {:ok, warning} <-
           %Warning{user_id: user.id, issued_by_id: uid, report_id: report_id}
           |> Warning.changeset(%{reason: reason})
           |> Repo.insert() do
      :ok = Notifications.moderation_warning(user.id, warning.reason)
      :ok = Log.record(actor, :warned, :user, user.id, user.id, %{"reason" => warning.reason})
      :ok = Reports.resolve(actor, report_id)
      Moderation.broadcast_changed()
      {:ok, warning}
    end
  end

  @doc "`user_id`'s unacknowledged warnings, oldest first."
  @spec pending_warnings(Ecto.UUID.t()) :: [Warning.t()]
  def pending_warnings(user_id) do
    pending_query(user_id) |> order_by([w], asc: w.inserted_at, asc: w.id) |> Repo.all()
  end

  @doc "Whether `user_id` has an unacknowledged warning."
  @spec pending_warnings?(Ecto.UUID.t()) :: boolean()
  def pending_warnings?(user_id), do: Repo.exists?(pending_query(user_id))

  defp pending_query(user_id), do: from(w in Warning, where: w.user_id == ^user_id and is_nil(w.acknowledged_at))

  @doc "Every warning `user_id` got, newest first, with `:issued_by`."
  @spec warnings_for(Ecto.UUID.t()) :: [Warning.t()]
  def warnings_for(user_id) do
    Repo.all(
      from(w in Warning,
        where: w.user_id == ^user_id,
        order_by: [desc: w.inserted_at, desc: w.id],
        preload: :issued_by
      )
    )
  end

  @doc "Acknowledges every pending warning of the scope's user."
  @spec acknowledge_warnings(Scope.t()) :: :ok
  def acknowledge_warnings(%Scope{user: %User{id: uid}}) do
    {count, _} = Repo.update_all(pending_query(uid), set: [acknowledged_at: DateTime.utc_now(:second)])
    if count > 0, do: Moderation.broadcast_changed()
    :ok
  end
end
