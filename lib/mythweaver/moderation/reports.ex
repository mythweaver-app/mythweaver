defmodule Mythweaver.Moderation.Reports do
  @moduledoc """
  Reports of catalog listings, accounts and chat messages (`Mythweaver.Moderation.Report`). Holders
  of `"reports.create"` (Everyone by default) may report what they can see; `"moderation.reports"`
  holders list and dismiss them. A report
  becomes `:actioned` when a moderator acts on its subject: a takedown, a deleted message
  (`resolve_subject/3`), or a warning or ban issued from it (`resolve/2`).

  A reporter has at most one open report per subject. The content-moderation rules open `source:
  :rule` reports (`flag/5`), at most one open per subject, which `"moderation.review"` holders list,
  read and dismiss.
  """

  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Query

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.Catalog.Listing
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Messages.Message
  alias Mythweaver.Moderation
  alias Mythweaver.Moderation.Log
  alias Mythweaver.Moderation.Report
  alias Mythweaver.Repo

  @subject_types [:listing, :user, :message]

  @doc """
  Reports `subject_type`/`subject_id` for `reason` (`"reports.create"`). Nobody reports their own
  listing, account or message; a message only by someone who can read its chat.
  """
  @spec report(Scope.t(), Report.subject_type(), String.t(), String.t()) ::
          {:ok, Report.t()} | {:error, :unauthorized | :not_found | :already_reported | Ecto.Changeset.t()}
  def report(%Scope{user: %User{id: uid}} = scope, subject_type, subject_id, reason)
      when subject_type in @subject_types do
    with :ok <- Scope.authorize(scope, "reports.create"),
         {:ok, id} <- cast_id(subject_id),
         {:ok, subject_user_id, snapshot} <- subject(scope, subject_type, id),
         :ok <- not_reported(uid, subject_type, id) do
      %Report{
        reporter_id: uid,
        subject_type: subject_type,
        subject_id: id,
        subject_user_id: subject_user_id,
        snapshot: snapshot
      }
      |> Report.changeset(%{reason: reason})
      |> Repo.insert()
      |> case do
        {:ok, report} ->
          Moderation.broadcast_changed()
          {:ok, report}

        {:error, changeset} ->
          if Keyword.has_key?(changeset.errors, :reporter_id),
            do: {:error, :already_reported},
            else: {:error, changeset}
      end
    end
  end

  def report(_scope, _subject_type, _subject_id, _reason), do: {:error, :unauthorized}

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp subject(%Scope{user: %User{id: uid}}, :listing, id) do
    case Repo.get(Listing, id) do
      %Listing{owner_id: ^uid} -> {:error, :unauthorized}
      %Listing{} = listing -> {:ok, listing.owner_id, listing.title}
      _ -> {:error, :not_found}
    end
  end

  defp subject(%Scope{user: %User{id: uid}}, :user, id) do
    case Accounts.get_user(id) do
      nil -> {:error, :not_found}
      %User{id: ^uid} -> {:error, :unauthorized}
      user -> {:ok, user.id, "@" <> user.handle}
    end
  end

  defp subject(%Scope{user: %User{id: uid}} = scope, :message, id) do
    with %Message{} = message <- Repo.get(Message, id),
         :ok <- Chats.authorize(scope, message.chat_id, :read),
         false <- message.author_user_id == uid do
      message = Repo.preload(message, [:author_character, :author_user, :bodies])

      accountable =
        message.author_user_id ||
          (message.chat_id && Repo.one(from(c in Chat, where: c.id == ^message.chat_id, select: c.user_id)))

      {:ok, accountable, String.slice("#{author(message)}: #{Message.active_content(message)}", 0, 4000)}
    else
      nil -> {:error, :not_found}
      _ -> {:error, :unauthorized}
    end
  end

  @doc "Who wrote `message` (with `:author_character` and `:author_user` loaded), for display."
  @spec author(Message.t()) :: String.t()
  def author(%Message{author_name: name}) when is_binary(name) and name != "", do: name
  def author(%Message{author_character: %{name: name}}), do: name
  def author(%Message{author_user: %User{handle: handle}}), do: "@" <> handle

  def author(%Message{}),
    do: dpgettext("moderation", "status: author name of a reported message with no known author", "Unknown")

  defp not_reported(uid, type, id) do
    open? =
      Repo.exists?(
        from(r in Report,
          where: r.reporter_id == ^uid and r.subject_type == ^type and r.subject_id == ^id and r.status == :open
        )
      )

    if open?, do: {:error, :already_reported}, else: :ok
  end

  @doc """
  Opens (or, while one is open, updates) the rules' report on `subject_type`/`subject_id`: `findings`
  are the rule hits, `snapshot` the text they read. System-only: no scope.
  """
  @spec flag(Report.subject_type(), Ecto.UUID.t(), Ecto.UUID.t() | nil, String.t(), [map()]) :: :ok
  def flag(subject_type, subject_id, subject_user_id, snapshot, findings) do
    now = DateTime.utc_now(:second)

    Repo.insert!(
      %Report{
        source: :rule,
        reporter_id: nil,
        subject_type: subject_type,
        subject_id: subject_id,
        subject_user_id: subject_user_id,
        snapshot: String.slice(snapshot || "", 0, 20_000),
        reason: flag_reason(findings),
        findings: findings,
        inserted_at: now,
        updated_at: now
      },
      on_conflict: {:replace, [:snapshot, :reason, :findings, :subject_user_id, :updated_at]},
      conflict_target: {:unsafe_fragment, "(subject_type, subject_id) WHERE status = 'open' AND source = 'rule'"}
    )

    Moderation.broadcast_changed()
    :ok
  end

  @doc "One line per finding (`rule: reason or excerpt`), noting when any rule recommends removal."
  @spec flag_reason([map()]) :: String.t()
  # A stored report reason read by every moderator: written in the site's default language.
  def flag_reason(findings) do
    lines = Enum.map_join(findings, "\n", &"#{&1["rule"]}: #{&1["reason"] || &1["excerpt"]}")

    text =
      if Enum.any?(findings, &(&1["action"] == "reject")),
        do: Mythweaver.Locale.with_user_locale(nil, fn -> recommend_removal(lines) end),
        else: lines

    String.slice(text, 0, 2000)
  end

  defp recommend_removal(lines) do
    gettext_comment(
      "Report reason for moderators; the placeholder is one \"rule: reason\" line per rule finding, as the rules wrote them."
    )

    dpgettext(
      "moderation",
      "status: report reason written by the automated moderation rules",
      "Rules recommend removal. %{finding_lines}",
      finding_lines: lines
    )
  end

  @doc """
  Every open report of `source`, oldest first: users' reports (`:user`, `"moderation.reports"`) or
  the rules' (`:rule`, `"moderation.review"`); `[]` without the key.
  """
  @spec list_open(Scope.t(), :user | :rule) :: [Report.t()]
  def list_open(%Scope{} = scope, source) when source in [:user, :rule] do
    if Scope.can?(scope, source_key(source)) do
      Repo.all(
        from(r in Report,
          where: r.status == :open and r.source == ^source,
          order_by: [asc: r.inserted_at, asc: r.id],
          preload: [:reporter, :subject_user]
        )
      )
    else
      []
    end
  end

  @doc "The permission that reads and dismisses reports of `source`."
  @spec source_key(:user | :rule) :: String.t()
  def source_key(:user), do: "moderation.reports"
  def source_key(:rule), do: "moderation.review"

  @doc "The report `id`, or nil (also without its source's key, `source_key/1`)."
  @spec get(Scope.t(), String.t()) :: Report.t() | nil
  def get(%Scope{} = scope, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Report{} = report <- Repo.get(Report, id),
         true <- Scope.can?(scope, source_key(report.source)) do
      Repo.preload(report, [:reporter, :subject_user, :resolved_by])
    else
      _ -> nil
    end
  end

  @doc "Dismisses the open report `id`."
  @spec dismiss(Scope.t(), String.t()) :: {:ok, Report.t()} | {:error, :unauthorized | :not_found}
  def dismiss(%Scope{user: %User{id: uid}} = scope, id) do
    with {:ok, id} <- cast_id(id),
         %Report{status: :open} = report <- Repo.get(Report, id),
         :ok <- Scope.authorize(scope, source_key(report.source)) do
      report =
        report
        |> Ecto.Changeset.change(status: :dismissed, resolved_by_id: uid, resolved_at: DateTime.utc_now(:second))
        |> Repo.update!()

      :ok = Log.record(scope, :report_dismissed, :report, report.id, report.subject_user_id)
      Moderation.broadcast_changed()
      {:ok, report}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Marks the open report `report_id` (nil: none) `:actioned` by the scope's user. Only called by
  actions that authorized themselves.
  """
  @spec resolve(Scope.t(), String.t() | nil) :: :ok
  def resolve(_scope, nil), do: :ok

  def resolve(%Scope{} = scope, report_id) do
    case Ecto.UUID.cast(report_id) do
      {:ok, id} -> action(scope, from(r in Report, where: r.id == ^id and r.status == :open))
      :error -> :ok
    end
  end

  @doc "Marks every open report on `subject_type`/`subject_id` `:actioned` by the scope's user."
  @spec resolve_subject(Scope.t(), Report.subject_type(), Ecto.UUID.t()) :: :ok
  def resolve_subject(%Scope{} = scope, subject_type, subject_id) do
    action(
      scope,
      from(r in Report, where: r.subject_type == ^subject_type and r.subject_id == ^subject_id and r.status == :open)
    )
  end

  @doc "Marks every open report of the messages `message_ids` actioned (their chat was deleted)."
  @spec resolve_messages(Scope.t(), [Ecto.UUID.t()]) :: :ok
  def resolve_messages(_scope, []), do: :ok

  def resolve_messages(%Scope{} = scope, message_ids) do
    action(
      scope,
      from(r in Report, where: r.status == :open and r.subject_type == :message and r.subject_id in ^message_ids)
    )
  end

  defp action(%Scope{user: %User{id: uid}}, query) do
    {count, _} =
      Repo.update_all(query,
        set: [status: :actioned, resolved_by_id: uid, resolved_at: DateTime.utc_now(:second)]
      )

    if count > 0, do: Moderation.broadcast_changed()
    :ok
  end

  @doc "The newest 50 reports about `user_id`'s listings, account and messages; `[]` without `\"moderation.reports\"`."
  @spec about_user(Scope.t(), Ecto.UUID.t()) :: [Report.t()]
  def about_user(%Scope{} = scope, user_id) do
    if Scope.can?(scope, "moderation.reports") do
      Repo.all(
        from(r in Report,
          where: r.subject_user_id == ^user_id,
          order_by: [desc: r.inserted_at, desc: r.id],
          limit: 50,
          preload: :reporter
        )
      )
    else
      []
    end
  end
end
