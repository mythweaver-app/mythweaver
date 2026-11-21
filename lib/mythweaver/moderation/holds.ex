defmodule Mythweaver.Moderation.Holds do
  @moduledoc """
  Content held for review (`Mythweaver.Moderation.Hold`, kept in `Mythweaver.Moderation.Store`): a
  restrictive-mode create, text edit or import (`Mythweaver.Moderation.Gate`) waits here, unsaved,
  until the rules approve it (`release/1`), reject it or let it expire (`discard/3`), or a
  `"moderation.review"` holder decides (`approve/2`, `reject/3`). Its submitter lists and withdraws
  their own (`list_own/1`, `withdraw/2`).

  Applying a hold calls the original context function again as its submitter, with moderation off
  (`Gate.unmoderated/1`), so ownership, quota and constraint checks run on the current data: a stale
  hold fails cleanly. Every decision is logged and notifies the submitter; every change broadcasts
  `Mythweaver.Moderation.broadcast_changed/0` and the submitter's `broadcast_submissions_changed/1`.
  """

  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.Moderation
  alias Mythweaver.Moderation.Gate
  alias Mythweaver.Moderation.Hold
  alias Mythweaver.Moderation.Log
  alias Mythweaver.Moderation.Scan
  alias Mythweaver.Moderation.Scanner
  alias Mythweaver.Moderation.Store
  alias Mythweaver.Moderation.Subject
  alias Mythweaver.Notifications
  alias Mythweaver.Repo

  @review "moderation.review"

  @doc """
  Holds a write for `scope`'s user and starts the rules on it. `attrs`: `kind`, `action`,
  `target_id`, `title`, `fields`, `op`, and optionally `type`, `previous` and `followups`.
  """
  @spec submit(Scope.t(), map()) :: {:held, Hold.t()} | {:error, :hold_limit}
  def submit(%Scope{user: %User{id: uid}}, attrs) do
    followups = Map.get(attrs, :followups, [])

    hold = %Hold{
      id: Mythweaver.Schema.generate_id(),
      type: Map.get(attrs, :type) || Subject.type(attrs.kind),
      kind: attrs.kind,
      action: attrs.action,
      user_id: uid,
      target_id: attrs.target_id,
      title: attrs.title,
      op: attrs.op,
      followups: followups,
      fields: attrs.fields,
      previous: Map.get(attrs, :previous, %{}),
      inserted_at: DateTime.utc_now(),
      bytes: :erlang.external_size(attrs.op) + :erlang.external_size(followups)
    }

    with :ok <- Store.put_hold(hold) do
      broadcast(uid)

      :ok =
        Scanner.scan_later(%Scan{
          hold_id: hold.id,
          type: hold.type,
          subject_type: hold.kind,
          subject_id: hold.target_id,
          action: hold.action,
          title: hold.title,
          fields: hold.fields,
          snapshot: Subject.join(hold.fields),
          user_id: uid
        })

      {:held, Store.get_hold(hold.id) || hold}
    end
  end

  @doc "Saves `hold` as its submitter; `{:ok, row}` is the saved row."
  @spec apply(Hold.t()) :: {:ok, struct()} | {:error, term()}
  def apply(%Hold{op: {module, function, args}} = hold) do
    with %User{} = user <- Accounts.get_user(hold.user_id) || {:error, :submitter_gone},
         scope = Scope.for_user(user),
         {:ok, args} <- resolve_rows(args) do
      Gate.unmoderated(fn ->
        case Kernel.apply(module, function, [scope | args]) do
          {:ok, result} ->
            row = saved_row(result)

            Enum.each(hold.followups, fn {m, f, a} ->
              Kernel.apply(m, f, [scope | Enum.map(a, &replace_row(&1, row))])
            end)

            {:ok, row}

          {:error, reason} ->
            {:error, reason}

          other ->
            {:error, other}
        end
      end)
    end
  end

  defp saved_row(%{record: row}), do: row
  defp saved_row(row), do: row

  defp replace_row(:row, row), do: row
  defp replace_row(arg, _row), do: arg

  defp resolve_rows(args) do
    Enum.reduce_while(args, {:ok, []}, fn
      {:row, schema, id}, {:ok, acc} ->
        case Repo.get(schema, id) do
          nil -> {:halt, {:error, :not_found}}
          row -> {:cont, {:ok, [row | acc]}}
        end

      arg, {:ok, acc} ->
        {:cont, {:ok, [arg | acc]}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  @doc "Saves the hold `hold_id` because every rule passed (a no-op when it is already gone)."
  @spec release(String.t()) :: :ok
  def release(hold_id) do
    case Store.take_hold(hold_id) do
      {:ok, hold} ->
        case apply(hold) do
          {:ok, row} ->
            :ok =
              Log.record_system(:hold_approved, hold.kind, row.id, hold.user_id, %{
                "title" => hold.title,
                "automatic" => true
              })

            :ok = Notifications.submission_approved(hold.user_id, hold.title)

          {:error, reason} ->
            :ok = Notifications.submission_rejected(hold.user_id, hold.title, save_failed(hold, reason))
        end

        broadcast(hold.user_id)

      :error ->
        :ok
    end
  end

  @doc "Discards a taken hold the rules rejected or that expired, telling its submitter `reason`."
  @spec discard(Hold.t(), :rejected | :expired, String.t()) :: :ok
  def discard(%Hold{} = hold, why, reason) when why in [:rejected, :expired] do
    :ok =
      Log.record_system(:hold_rejected, hold.kind, hold.target_id, hold.user_id, %{
        "title" => hold.title,
        "reason" => reason,
        "automatic" => true
      })

    :ok = Notifications.submission_rejected(hold.user_id, hold.title, reason)
    broadcast(hold.user_id)
  end

  @doc "Every hold, oldest first (`\"moderation.review\"`)."
  @spec list(Scope.t()) :: [Hold.t()]
  def list(%Scope{} = scope), do: if(Scope.can?(scope, @review), do: Store.list_holds(), else: [])

  @doc "The hold `id`, or nil (also without `\"moderation.review\"`)."
  @spec get(Scope.t(), String.t()) :: Hold.t() | nil
  def get(%Scope{} = scope, id), do: if(Scope.can?(scope, @review), do: Store.get_hold(id))

  @doc "A moderator saves the hold `id`."
  @spec approve(Scope.t(), String.t()) ::
          {:ok, struct()} | {:error, :unauthorized | :not_found | {:apply_failed, term()}}
  def approve(%Scope{} = scope, id) do
    with :ok <- Scope.authorize(scope, @review),
         {:ok, hold} <- take(id) do
      result =
        case apply(hold) do
          {:ok, row} ->
            :ok = Log.record(scope, :hold_approved, hold.kind, row.id, hold.user_id, %{"title" => hold.title})
            :ok = Notifications.submission_approved(hold.user_id, hold.title)
            {:ok, row}

          {:error, reason} ->
            :ok = Notifications.submission_rejected(hold.user_id, hold.title, save_failed(hold, reason))

            {:error, {:apply_failed, reason}}
        end

      broadcast(hold.user_id)
      result
    end
  end

  @doc "A moderator discards the hold `id` for `reason`, which its submitter is told."
  @spec reject(Scope.t(), String.t(), String.t() | nil) ::
          {:ok, Hold.t()} | {:error, :unauthorized | :not_found | :reason_required}
  def reject(%Scope{} = scope, id, reason) do
    reason = String.trim(reason || "")

    with :ok <- Scope.authorize(scope, @review),
         :ok <- if(reason == "", do: {:error, :reason_required}, else: :ok),
         {:ok, hold} <- take(id) do
      :ok =
        Log.record(scope, :hold_rejected, hold.kind, hold.target_id, hold.user_id, %{
          "title" => hold.title,
          "reason" => reason
        })

      :ok = Notifications.submission_rejected(hold.user_id, hold.title, reason)
      broadcast(hold.user_id)
      {:ok, hold}
    end
  end

  @doc "The scope user's own holds, oldest first."
  @spec list_own(Scope.t()) :: [Hold.t()]
  def list_own(%Scope{user: %User{id: uid}}), do: Store.list_user_holds(uid)
  def list_own(_scope), do: []

  @doc "Withdraws the scope user's own hold `id`, unsaved."
  @spec withdraw(Scope.t(), String.t()) :: :ok | {:error, :not_found}
  def withdraw(%Scope{user: %User{id: uid}}, id) do
    with %Hold{user_id: ^uid} <- Store.get_hold(id),
         {:ok, _hold} <- take(id) do
      broadcast(uid)
    else
      _ -> {:error, :not_found}
    end
  end

  # The submitter's notification body, in their language.
  defp save_failed(hold, reason) do
    Mythweaver.Locale.with_user_locale(hold.user_id, fn ->
      dgettext("moderation", "It could not be saved: %{error_reason}", error_reason: message(reason))
    end)
  end

  @doc "The text of a reason a hold could not be saved."
  @spec message(term()) :: String.t()
  def message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&translate_error/1)
    |> Enum.map_join(", ", fn {field, errors} -> "#{field} #{Enum.join(List.flatten([errors]), ", ")}" end)
  end

  def message(:unauthorized), do: dgettext("errors", "you may no longer do that")
  def message(:quota_exceeded), do: dgettext("errors", "you are at your limit")
  def message(:not_found), do: dgettext("errors", "what it changed no longer exists")
  def message(:submitter_gone), do: dgettext("errors", "its account was deleted")
  def message(reason) when is_binary(reason), do: reason
  def message(reason), do: inspect(reason)

  # As `MythweaverWeb.CoreComponents.translate_error/1`: changeset messages are `errors` msgids.
  defp translate_error({msg, opts}) do
    if count = opts[:count],
      do: Gettext.dngettext(Mythweaver.Gettext, "errors", msg, msg, count, opts),
      else: Gettext.dgettext(Mythweaver.Gettext, "errors", msg, opts)
  end

  defp take(id) do
    case Store.take_hold(id) do
      {:ok, hold} -> {:ok, hold}
      :error -> {:error, :not_found}
    end
  end

  defp broadcast(user_id) do
    Moderation.broadcast_changed()
    Moderation.broadcast_submissions_changed(user_id)
  end
end
