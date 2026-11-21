defmodule MythweaverWeb.ReportModal do
  @moduledoc """
  The report dialog (`Mythweaver.Moderation.Reports.report/4`) for a catalog listing, an account or a
  chat message. The host LiveView holds the `reporting` assign (`open/4`, `close/1`), handles
  `"open_report"`, `"close_report"` and `"report"` (`submit/2`), and renders `report_modal/1` while
  `reporting` is set.
  """

  use MythweaverWeb, :html

  import Phoenix.LiveView, only: [put_flash: 3]

  alias Mythweaver.Moderation.Reports
  alias Phoenix.LiveView.Socket

  @doc "Opens the dialog for `kind` `id`, headed `title`."
  @spec open(Socket.t(), :listing | :user | :message, String.t(), String.t()) ::
          Socket.t()
  def open(socket, kind, id, title) when kind in [:listing, :user, :message] do
    assign(socket, reporting: %{kind: kind, id: id, title: title, form: to_form(%{"reason" => ""}, as: :report)})
  end

  @doc "Closes the dialog."
  @spec close(Socket.t()) :: Socket.t()
  def close(socket), do: assign(socket, reporting: nil)

  @doc "Files the report from the dialog's `params`; a blank or too-long reason keeps it open with errors."
  @spec submit(Socket.t(), map()) :: Socket.t()
  def submit(%{assigns: %{reporting: %{kind: kind, id: id} = reporting}} = socket, %{"reason" => reason} = params) do
    case Reports.report(socket.assigns.current_scope, kind, id, reason) do
      {:ok, _report} ->
        socket |> close() |> put_flash(:info, reported_flash())

      {:error, :already_reported} ->
        socket |> close() |> put_flash(:info, already_reported_flash())

      {:error, %Ecto.Changeset{} = changeset} ->
        form = to_form(params, as: :report, errors: changeset.errors, action: :validate)
        assign(socket, reporting: %{reporting | form: form})

      {:error, _reason} ->
        socket |> close() |> put_flash(:error, report_refused_flash())
    end
  end

  def submit(socket, _params), do: close(socket)

  defp reported_flash do
    gettext_comment("Flash after someone files a report about a listing, an account or a message.")
    dgettext("moderation", "Thanks, a moderator will look at it")
  end

  defp already_reported_flash do
    gettext_comment("Flash when someone reports a listing, an account or a message they already reported.")
    dgettext("moderation", "You have already reported this")
  end

  defp report_refused_flash do
    gettext_comment("Flash when a report cannot be filed (reporting is off, or the item is the reporter's own).")
    dpgettext("moderation", "status: a report could not be filed", "You can't report this")
  end

  attr :reporting, :map, required: true

  @doc "The dialog: a reason and Report."
  def report_modal(assigns) do
    ~H"""
    <.modal id="report-modal" title={@reporting.title} on_cancel="close_report">
      <.form for={@reporting.form} id="report-form" phx-submit="report">
        <.editor
          field={@reporting.form[:reason]}
          id="report-form-reason"
          label={dgettext("moderation", "What is wrong with it?")}
        />
        <.form_actions>
          <.button type="button" phx-click={JS.dispatch("modal:close", to: "#report-modal")}>
            {dpgettext("moderation", "button: close the report dialog without reporting", "Cancel")}
          </.button>
          <.button type="submit" variant="primary" id="report-form-submit">
            {dpgettext("moderation", "button: file the report from the report dialog", "Report")}
          </.button>
        </.form_actions>
      </.form>
    </.modal>
    """
  end
end
