defmodule MythweaverWeb.FieldCompaction do
  @moduledoc """
  The Compact button on an unsaved form field (a lore entry's Content, a character's Description).
  The field's current text goes through the default memory profile's compaction prompt
  (`Mythweaver.Memory.compact_text/2`), and the rewrite replaces the field unsaved, so the person
  reviews it and then saves or cancels.

  The LiveView keeps the pending compaction in one assign (`%{id:, target:}`, nil when none), is
  subscribed to `Mythweaver.Jobs`, and passes the job's terminal `{:job_changed, …}` to `finish/4`
  (match it with `finished?/1`). `target` names what the form showed when the compaction was queued;
  a rewrite that comes back after the form moved on to something else is dropped.
  """

  use Gettext, backend: Mythweaver.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Mythweaver.Jobs
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Memory
  alias Phoenix.LiveView.Socket

  @doc "Whether a `:job_changed` status ends the job."
  defguard finished?(status) when status in [:completed, :failed, :canceled, :interrupted]

  @doc """
  Queues a compaction of `attrs` (`Memory.compact_text/2`: `:title`, `:content`, `:kind`) and keeps
  it in `key` for `target`; flashes why when it cannot start.
  """
  @spec start(Socket.t(), atom(), term(), map()) :: Socket.t()
  def start(socket, key, target, attrs) do
    case Memory.compact_text(socket.assigns.current_scope, attrs) do
      {:ok, job} -> socket |> assign(key, %{id: job.id, target: target}) |> put_flash(:info, compacting_message())
      {:error, reason} -> put_flash(socket, :error, error_message(reason))
    end
  end

  @doc """
  Ends the compaction in `key`. A completed rewrite goes through `put_text.(socket, text)` while the
  form still shows its `target` (`current`); a failed or stopped one is flashed.
  """
  @spec finish(Socket.t(), atom(), term(), (Socket.t(), String.t() -> Socket.t())) :: Socket.t()
  def finish(socket, key, current, put_text) do
    %{id: id, target: target} = Map.fetch!(socket.assigns, key)
    socket = assign(socket, key, nil)

    case Jobs.get_job(socket.assigns.current_scope, id) do
      %Job{status: :completed, result: %{"content" => text}} when is_binary(text) ->
        if target == current,
          do: socket |> put_text.(text) |> put_flash(:info, compacted_message()),
          else: socket

      %Job{status: :canceled} ->
        put_flash(socket, :info, stopped_message())

      job ->
        put_flash(socket, :error, failed_message(job && job.error))
    end
  end

  defp compacting_message do
    gettext_comment("Flash shown while a form field's text is being shortened by the AI (compaction).")
    pgettext("status: AI compaction of a form field has started", "Compacting…")
  end

  defp compacted_message do
    gettext_comment(
      "Flash shown when the shortened text replaced the form field, still unsaved; \"Save\" is the form's button."
    )

    pgettext("status: flash after a form field's text was compacted", "Compacted. Review, then Save.")
  end

  defp stopped_message do
    gettext_comment("Flash shown when a form field's compaction was stopped before it finished.")
    pgettext("status: AI compaction of a form field was stopped", "Compaction stopped.")
  end

  defp failed_message(nil) do
    gettext_comment("Flash shown when a form field's compaction finished without returning any text.")
    gettext("Compaction failed: no text came back")
  end

  defp failed_message(error) do
    gettext_comment("Flash shown when a form field's compaction failed; the placeholder is the job's error message.")

    pgettext("status: flash after a form field's compaction failed", "Compaction failed: %{error_message}",
      error_message: error
    )
  end

  defp error_message(:quota_exceeded) do
    gettext_comment("Flash shown when a compaction cannot start because the user's daily AI budget is spent.")
    gettext("You've spent today's budget on the site's AI connections.")
  end

  defp error_message(:empty), do: pgettext("status: compaction refused, the field is empty", "Nothing to compact.")
  defp error_message(:no_profile), do: gettext("No memory profile is set.")
  defp error_message(:no_prompt), do: gettext("The memory profile has no compaction prompt.")
  defp error_message(:no_model), do: gettext("No model is available for compaction.")
  defp error_message(:ambiguous_model), do: gettext("Choose a default model or set one on the memory profile.")
end
