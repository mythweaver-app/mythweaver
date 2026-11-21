defmodule MythweaverWeb.ModerationReportLive do
  @moduledoc """
  The review queues, one tab each: users' reports (`/moderation/reports`, `"moderation.reports"`),
  content the moderation rules flagged (`/moderation/flagged`) and content held for review
  (`/moderation/held`), both `"moderation.review"`. Each lists its open items on the left, oldest
  first, and the selected one on the right with what can be done about it.

  A report: open the content (`Mythweaver.Moderation.Lookup.path/1`), dismiss it, take a listing
  down (`Mythweaver.Catalog.takedown/3`, with a reason its owner is told), delete the content
  (`Lookup.delete/3`, after the password prompt: `MythweaverWeb.Sudo`), or go to the accountable
  account's record to warn or suspend it, carrying the report id so the sanction resolves it. A
  held item (`Mythweaver.Moderation.Holds`): read what it would save (an edit's current and
  proposed text side by side) and the rules' findings, then approve (it saves as its submitter) or
  reject it with a reason its submitter is told.

  Every moderation change (`Mythweaver.Moderation.subscribe/0`) reloads the lists and the open
  item; one resolved elsewhere closes with a flash.
  """
  use MythweaverWeb, :live_view

  import MythweaverWeb.Pane

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Catalog
  alias Mythweaver.Catalog.Listing
  alias Mythweaver.Moderation
  alias Mythweaver.Moderation.Hold
  alias Mythweaver.Moderation.Holds
  alias Mythweaver.Moderation.Lookup
  alias Mythweaver.Moderation.Report
  alias Mythweaver.Moderation.Reports
  alias MythweaverWeb.ModerationNav

  on_mount {MythweaverWeb.UserAuth, {:require_any_permission, ["moderation.reports", "moderation.review"]}}
  on_mount MythweaverWeb.Sudo

  @mark "\u{F0010}"

  @queues %{
    index: "reports",
    show: "reports",
    flagged: "flagged",
    show_flagged: "flagged",
    held: "held",
    show_held: "held"
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Moderation.subscribe()

    {:ok,
     socket
     |> assign(
       page_title: queue_title("reports"),
       queue: nil,
       report: nil,
       hold: nil,
       hold_user: nil,
       selected_id: nil,
       takedown_form: takedown_form(),
       reject_form: reject_form(),
       reports_empty?: true,
       holds_empty?: true
     )
     |> stream_configure(:reports, dom_id: &"reports-#{&1.id}")
     |> stream_configure(:holds, dom_id: &"held-#{&1.id}")
     |> stream(:reports, [])
     |> stream(:holds, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    action = socket.assigns.live_action
    queue = Map.fetch!(@queues, action)

    if Scope.can?(socket.assigns.current_scope, queue_key(queue)) do
      socket =
        if socket.assigns.queue == queue,
          do: socket,
          else: assign(socket, queue: queue, page_title: queue_title(queue), reports_ids: nil)

      {:noreply, apply_action(socket, action, params)}
    else
      {:noreply,
       socket
       |> flash_unauthorized()
       |> push_navigate(to: ModerationNav.home(socket.assigns.current_scope) || ~p"/")}
    end
  end

  defp queue_key("reports"), do: "moderation.reports"
  defp queue_key(_queue), do: "moderation.review"

  defp queue_title("reports"), do: dpgettext("moderation", "page title: queue of users' reports", "Reports")

  defp queue_title("flagged"),
    do: dpgettext("moderation", "page title: queue of content the rules flagged", "Flagged content")

  defp queue_title("held"), do: dpgettext("moderation", "page title: queue of content held for review", "Held content")

  defp apply_action(socket, action, _params) when action in [:index, :flagged] do
    socket
    |> assign(report: nil, selected_id: nil)
    |> stream_reports()
  end

  defp apply_action(socket, :held, _params) do
    socket
    |> assign(hold: nil, hold_user: nil, selected_id: nil)
    |> stream_holds()
  end

  defp apply_action(socket, action, %{"id" => id}) when action in [:show, :show_flagged] do
    case open_report(socket, id) do
      nil ->
        close(socket)

      report ->
        socket
        |> assign(report: report, selected_id: report.id, takedown_form: takedown_form())
        |> stream_reports()
    end
  end

  defp apply_action(socket, :show_held, %{"id" => id}) do
    case Holds.get(socket.assigns.current_scope, id) do
      nil ->
        close(socket)

      hold ->
        socket
        |> assign(
          hold: hold,
          hold_user: Accounts.get_user(hold.user_id),
          selected_id: hold.id,
          reject_form: reject_form()
        )
        |> stream_holds()
    end
  end

  @impl true
  def handle_info({Moderation, :changed}, %{assigns: %{queue: "held"}} = socket) do
    socket = stream_holds(socket)

    case socket.assigns.hold do
      nil ->
        {:noreply, socket}

      %Hold{id: id} ->
        case Holds.get(socket.assigns.current_scope, id) do
          nil -> {:noreply, close(socket)}
          hold -> {:noreply, assign(socket, hold: hold)}
        end
    end
  end

  def handle_info({Moderation, :changed}, socket) do
    socket = stream_reports(socket)

    case socket.assigns.report do
      nil ->
        {:noreply, socket}

      %Report{id: id} ->
        case open_report(socket, id) do
          nil -> {:noreply, close(socket)}
          report -> {:noreply, assign(socket, report: report)}
        end
    end
  end

  @impl true
  # A click or sudo replay that lands after the item was resolved elsewhere.
  def handle_event(event, _params, %{assigns: %{report: nil}} = socket)
      when event in ["dismiss", "takedown", "delete_content"], do: {:noreply, close(socket)}

  def handle_event(event, _params, %{assigns: %{hold: nil}} = socket) when event in ["approve_hold", "reject_hold"],
    do: {:noreply, close(socket)}

  def handle_event("approve_hold", _params, socket) do
    case Holds.approve(socket.assigns.current_scope, socket.assigns.hold.id) do
      {:ok, _row} ->
        {:noreply, done(socket, approved_flash())}

      {:error, {:apply_failed, reason}} ->
        {:noreply,
         socket
         |> close()
         |> put_flash(:error, apply_failed_flash(reason))}

      {:error, :not_found} ->
        {:noreply, close(socket)}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}
    end
  end

  def handle_event("reject_hold", %{"reject" => %{"reason" => reason} = params}, socket) do
    case Holds.reject(socket.assigns.current_scope, socket.assigns.hold.id, reason) do
      {:ok, _hold} ->
        {:noreply, done(socket, rejected_flash())}

      {:error, :reason_required} ->
        {:noreply,
         socket
         |> assign(reject_form: reject_form(params))
         |> put_flash(:error, reject_reason_flash())}

      {:error, :not_found} ->
        {:noreply, close(socket)}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}
    end
  end

  def handle_event("dismiss", _params, socket) do
    case Reports.dismiss(socket.assigns.current_scope, socket.assigns.report.id) do
      {:ok, _report} ->
        {:noreply, done(socket, dismissed_flash())}

      {:error, :not_found} ->
        {:noreply, close(socket)}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}
    end
  end

  def handle_event("takedown", %{"takedown" => %{"reason" => reason} = params}, socket) do
    report = socket.assigns.report

    case Catalog.takedown(socket.assigns.current_scope, %Listing{id: report.subject_id}, reason) do
      :ok ->
        {:noreply, done(socket, taken_down_flash())}

      {:error, :reason_required} ->
        {:noreply,
         socket
         |> assign(takedown_form: takedown_form(params))
         |> put_flash(:error, takedown_reason_flash())}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, listing_gone_flash())}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}
    end
  end

  def handle_event("delete_content", params, socket) do
    %Report{subject_type: type, subject_id: id} = socket.assigns.report

    case Lookup.delete(socket.assigns.current_scope, type, id) do
      {:ok, :deleted} ->
        {:noreply, done(socket, deleted_flash(type))}

      {:error, :sudo_required} ->
        {:noreply, MythweaverWeb.Sudo.require(socket, "delete_content", params)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, already_gone_flash())}

      {:error, reason} ->
        {:noreply, ModerationNav.delete_refused(socket, reason)}
    end
  end

  defp open_report(socket, id) do
    case Reports.get(socket.assigns.current_scope, id) do
      %Report{status: :open} = report -> report
      _ -> nil
    end
  end

  # The open item was acted on here: clear it first, so the `:changed` broadcast that action sent
  # does not also flash it as resolved elsewhere.
  defp done(socket, message) do
    socket
    |> assign(report: nil, hold: nil, hold_user: nil, selected_id: nil)
    |> put_flash(:info, message)
    |> push_patch(to: queue_path(socket.assigns.queue))
  end

  defp close(socket) do
    socket
    |> assign(report: nil, hold: nil, hold_user: nil, selected_id: nil)
    |> put_flash(:error, if(socket.assigns.queue == "held", do: decided_flash(), else: resolved_flash()))
    |> push_patch(to: queue_path(socket.assigns.queue))
  end

  defp queue_path("reports"), do: ~p"/moderation/reports"
  defp queue_path("flagged"), do: ~p"/moderation/flagged"
  defp queue_path("held"), do: ~p"/moderation/held"

  defp item_path("reports", id), do: ~p"/moderation/reports/#{id}"
  defp item_path("flagged", id), do: ~p"/moderation/flagged/#{id}"
  defp item_path("held", id), do: ~p"/moderation/held/#{id}"

  defp stream_reports(socket) do
    source = if socket.assigns.queue == "flagged", do: :rule, else: :user
    stream_rows(socket, :reports, Reports.list_open(socket.assigns.current_scope, source))
  end

  defp stream_holds(socket) do
    holds = Holds.list(socket.assigns.current_scope)

    socket
    |> assign(holds_empty?: holds == [])
    |> stream(:holds, holds, reset: true)
  end

  defp takedown_form(params \\ %{"reason" => ""}), do: to_form(params, as: :takedown)
  defp reject_form(params \\ %{"reason" => ""}), do: to_form(params, as: :reject)

  defp type_label(:listing), do: dpgettext("moderation", "badge: type of reported item", "Listing")
  defp type_label(:user), do: dpgettext("moderation", "badge: type of reported item", "Account")
  defp type_label(:message), do: dpgettext("moderation", "badge: type of reported item", "Message")
  defp type_label(type), do: ModerationNav.subject_label(type)

  defp reported_heading(:listing), do: dpgettext("moderation", "heading: the reported item", "Reported listing")
  defp reported_heading(:user), do: dpgettext("moderation", "heading: the reported item", "Reported account")
  defp reported_heading(:message), do: dpgettext("moderation", "heading: the reported item", "Reported message")
  defp reported_heading(:chat), do: dpgettext("moderation", "heading: the reported item", "Reported chat")
  defp reported_heading(:character), do: dpgettext("moderation", "heading: the reported item", "Reported character")
  defp reported_heading(:lore_book), do: dpgettext("moderation", "heading: the reported item", "Reported lore book")
  defp reported_heading(:lore_entry), do: dpgettext("moderation", "heading: the reported item", "Reported lore entry")

  defp reported_heading(:ai_provider),
    do: dpgettext("moderation", "heading: the reported item", "Reported AI connection")

  defp reported_heading(:ai_model), do: dpgettext("moderation", "heading: the reported item", "Reported AI model")
  defp reported_heading(:prompt), do: dpgettext("moderation", "heading: the reported item", "Reported prompt")
  defp reported_heading(:block), do: dpgettext("moderation", "heading: the reported item", "Reported prompt block")
  defp reported_heading(:outlet), do: dpgettext("moderation", "heading: the reported item", "Reported outlet")

  defp delete_button(:message), do: dpgettext("moderation", "button: delete the reported item", "Delete message")
  defp delete_button(:chat), do: dpgettext("moderation", "button: delete the reported item", "Delete chat")
  defp delete_button(:character), do: dpgettext("moderation", "button: delete the reported item", "Delete character")
  defp delete_button(:lore_book), do: dpgettext("moderation", "button: delete the reported item", "Delete lore book")
  defp delete_button(:lore_entry), do: dpgettext("moderation", "button: delete the reported item", "Delete lore entry")

  defp delete_button(:ai_provider),
    do: dpgettext("moderation", "button: delete the reported item", "Delete AI connection")

  defp delete_button(:ai_model), do: dpgettext("moderation", "button: delete the reported item", "Delete AI model")
  defp delete_button(:prompt), do: dpgettext("moderation", "button: delete the reported item", "Delete prompt")
  defp delete_button(:block), do: dpgettext("moderation", "button: delete the reported item", "Delete prompt block")
  defp delete_button(:outlet), do: dpgettext("moderation", "button: delete the reported item", "Delete outlet")

  defp delete_confirm(:message) do
    gettext_comment("Confirm dialog before a moderator deletes reported content.")
    dpgettext("moderation", "heading: confirm dialog before deleting the reported item", "Delete this message?")
  end

  defp delete_confirm(:chat) do
    gettext_comment("Confirm dialog before a moderator deletes reported content.")
    dpgettext("moderation", "heading: confirm dialog before deleting the reported item", "Delete this chat?")
  end

  defp delete_confirm(:character) do
    gettext_comment("Confirm dialog before a moderator deletes reported content.")
    dpgettext("moderation", "heading: confirm dialog before deleting the reported item", "Delete this character?")
  end

  defp delete_confirm(:lore_book) do
    gettext_comment("Confirm dialog before a moderator deletes reported content.")
    dpgettext("moderation", "heading: confirm dialog before deleting the reported item", "Delete this lore book?")
  end

  defp delete_confirm(:lore_entry) do
    gettext_comment("Confirm dialog before a moderator deletes reported content.")
    dpgettext("moderation", "heading: confirm dialog before deleting the reported item", "Delete this lore entry?")
  end

  defp delete_confirm(:ai_provider) do
    gettext_comment("Confirm dialog before a moderator deletes reported content.")
    dpgettext("moderation", "heading: confirm dialog before deleting the reported item", "Delete this AI connection?")
  end

  defp delete_confirm(:ai_model) do
    gettext_comment("Confirm dialog before a moderator deletes reported content.")
    dpgettext("moderation", "heading: confirm dialog before deleting the reported item", "Delete this AI model?")
  end

  defp delete_confirm(:prompt) do
    gettext_comment("Confirm dialog before a moderator deletes reported content.")
    dpgettext("moderation", "heading: confirm dialog before deleting the reported item", "Delete this prompt?")
  end

  defp delete_confirm(:block) do
    gettext_comment("Confirm dialog before a moderator deletes reported content.")
    dpgettext("moderation", "heading: confirm dialog before deleting the reported item", "Delete this prompt block?")
  end

  defp delete_confirm(:outlet) do
    gettext_comment("Confirm dialog before a moderator deletes reported content.")
    dpgettext("moderation", "heading: confirm dialog before deleting the reported item", "Delete this outlet?")
  end

  defp deleted_flash(:message) do
    gettext_comment("Flash after a moderator deletes reported content.")
    dpgettext("moderation", "status: a moderator deleted the reported item", "Message deleted")
  end

  defp deleted_flash(:chat) do
    gettext_comment("Flash after a moderator deletes reported content.")
    dpgettext("moderation", "status: a moderator deleted the reported item", "Chat deleted")
  end

  defp deleted_flash(:character) do
    gettext_comment("Flash after a moderator deletes reported content.")
    dpgettext("moderation", "status: a moderator deleted the reported item", "Character deleted")
  end

  defp deleted_flash(:lore_book) do
    gettext_comment("Flash after a moderator deletes reported content.")
    dpgettext("moderation", "status: a moderator deleted the reported item", "Lore book deleted")
  end

  defp deleted_flash(:lore_entry) do
    gettext_comment("Flash after a moderator deletes reported content.")
    dpgettext("moderation", "status: a moderator deleted the reported item", "Lore entry deleted")
  end

  defp deleted_flash(:ai_provider) do
    gettext_comment("Flash after a moderator deletes reported content.")
    dpgettext("moderation", "status: a moderator deleted the reported item", "AI connection deleted")
  end

  defp deleted_flash(:ai_model) do
    gettext_comment("Flash after a moderator deletes reported content.")
    dpgettext("moderation", "status: a moderator deleted the reported item", "AI model deleted")
  end

  defp deleted_flash(:prompt) do
    gettext_comment("Flash after a moderator deletes reported content.")
    dpgettext("moderation", "status: a moderator deleted the reported item", "Prompt deleted")
  end

  defp deleted_flash(:block) do
    gettext_comment("Flash after a moderator deletes reported content.")
    dpgettext("moderation", "status: a moderator deleted the reported item", "Prompt block deleted")
  end

  defp deleted_flash(:outlet) do
    gettext_comment("Flash after a moderator deletes reported content.")
    dpgettext("moderation", "status: a moderator deleted the reported item", "Outlet deleted")
  end

  defp action_label(:create), do: dpgettext("moderation", "badge: held content is new", "New")
  defp action_label(:update), do: dpgettext("moderation", "badge: held content is an edit", "Edit")
  defp action_label(:import), do: dpgettext("moderation", "badge: held content is an import", "Import")

  defp status_label(:scanning),
    do: dpgettext("moderation", "status: held content the rules are still checking", "Checking")

  defp status_label(:review),
    do: dpgettext("moderation", "status: held content waiting for a moderator", "Waiting for review")

  defp finding_action("approve"), do: dpgettext("moderation", "badge: what a moderation rule decided", "Approve")
  defp finding_action("flag"), do: dpgettext("moderation", "badge: what a moderation rule decided", "Flag")
  defp finding_action("reject"), do: dpgettext("moderation", "badge: what a moderation rule decided", "Reject")
  defp finding_action(action), do: action

  # A translation whose one placeholder is bound to `@mark`, split so the template renders a
  # component where the translation puts it.
  defp around_mark(text), do: text |> String.split(@mark) |> Enum.intersperse(:mark)

  defp report_title(report) do
    gettext_comment("Title of a report: the reported item's type (e.g. \"Message\"), then the start of its text.")

    dpgettext("moderation", "heading: type and text of the reported item", "%{item_type}: %{reported_text}",
      item_type: type_label(report.subject_type),
      reported_text: excerpt(report.snapshot, 120)
    )
  end

  defp reporter_meta(%Report{reporter: %{handle: handle}}) do
    dpgettext("moderation", "status: who filed a report, followed by when", "By @%{reporter_handle},",
      reporter_handle: handle
    )
  end

  defp reporter_meta(_report),
    do: dpgettext("moderation", "status: the rules filed a report, followed by when", "By automated rules,")

  defp submitted_by do
    gettext_comment("Who submitted held content; the placeholder is a link to their @handle, the time follows.")

    dpgettext("moderation", "status: who submitted held content", "Submitted by %{account_handle}",
      account_handle: @mark
    )
  end

  defp subject_account do
    gettext_comment("The account a report is about; the placeholder is a link to its @handle.")

    dpgettext("moderation", "status: the account a report is about", "Account: %{account_handle}",
      account_handle: @mark
    )
  end

  defp reported_by do
    gettext_comment("Who filed a report; the placeholder is a link to their @handle, the time follows.")
    dpgettext("moderation", "status: who filed a report", "Reported by %{reporter_handle}", reporter_handle: @mark)
  end

  defp resolved_flash do
    gettext_comment("Flash when the open report was resolved by another moderator.")
    dgettext("moderation", "That report is already resolved")
  end

  defp decided_flash do
    gettext_comment("Flash when the open held content was approved or rejected by another moderator.")
    dgettext("moderation", "That item is already decided")
  end

  defp approved_flash do
    gettext_comment("Flash after a moderator approves held content, which is then saved.")
    dpgettext("moderation", "status: a moderator approved held content", "Approved and saved")
  end

  defp apply_failed_flash(reason) do
    gettext_comment("Flash when approved held content could not be saved; the placeholder says why.")
    dgettext("moderation", "It could not be saved: %{error_reason}", error_reason: Holds.message(reason))
  end

  defp rejected_flash do
    gettext_comment("Flash after a moderator rejects held content.")
    dpgettext("moderation", "status: a moderator rejected held content", "Rejected")
  end

  defp reject_reason_flash do
    gettext_comment("Flash when a moderator rejects held content without a reason.")
    dgettext("moderation", "Say why it is rejected; its submitter is told")
  end

  defp dismissed_flash do
    gettext_comment("Flash after a moderator dismisses a report.")
    dpgettext("moderation", "status: a moderator dismissed a report", "Report dismissed")
  end

  defp taken_down_flash do
    gettext_comment("Flash after a moderator takes a reported catalog listing down.")
    dpgettext("moderation", "status: a moderator took a reported catalog listing down", "Listing taken down")
  end

  defp takedown_reason_flash do
    gettext_comment("Flash when a moderator takes a catalog listing down without a reason.")
    dgettext("moderation", "Say why it is taken down; its owner is told")
  end

  defp listing_gone_flash do
    gettext_comment("Flash when the catalog listing being taken down is already gone.")
    dgettext("moderation", "That listing is already gone")
  end

  defp already_gone_flash do
    gettext_comment("Flash when the reported content a moderator deletes is already gone.")
    dpgettext("moderation", "status: the reported item is already gone", "It is already gone")
  end

  # An edit shows each changed field's current and proposed text; anything else, every field.
  defp hold_rows(%Hold{action: :update, previous: previous, fields: fields}) do
    proposed = Map.new(fields)
    previous |> Enum.sort() |> Enum.map(fn {label, old} -> {label, old, Map.get(proposed, label, "")} end)
  end

  defp hold_rows(%Hold{fields: fields}), do: Enum.map(fields, fn {label, text} -> {label, nil, text} end)

  defp deletable?(%Report{subject_type: type}), do: type not in [:listing, :user]

  defp excerpt(text, length) do
    if String.length(text) > length, do: String.slice(text, 0, length) <> "…", else: text
  end

  defp record_path(user_id), do: ~p"/moderation/users/#{user_id}/record"

  defp can_open?(scope, %Report{subject_type: :user, subject_user: %{} = user}),
    do: Moderation.authorize_record(scope, user) == :ok

  defp can_open?(_scope, %Report{subject_type: :user}), do: false
  defp can_open?(scope, %Report{}), do: Scope.can?(scope, "moderation.content.view")

  attr :id, :string, required: true
  attr :findings, :list, required: true

  # One row per rule finding: rule, action, field, excerpt and reason.
  defp findings(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      ul:scope {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
        margin: 0;
        padding: 0;
        list-style: none;
      }

      .finding-head {
        display: flex;
        flex-wrap: wrap;
        gap: var(--size-2);
        font-weight: 600;
      }

      .finding-text {
        margin: 0;
        white-space: pre-wrap;
        overflow-wrap: anywhere;
        color: var(--muted-foreground);
      }
    </style>
    <ul id={@id}>
      <li :for={{finding, i} <- Enum.with_index(@findings)} id={"#{@id}-#{i}"}>
        <div class="finding-head">
          <span>{finding["rule"]}</span>
          <span>{finding_action(finding["action"])}</span>
          <span :if={finding["field"]}>{finding["field"]}</span>
        </div>
        <p :if={finding["excerpt"]} class="finding-text">…{finding["excerpt"]}…</p>
        <p :if={finding["reason"]} class="finding-text">{finding["reason"]}</p>
      </li>
    </ul>
    """
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        delete?: Scope.can?(assigns.current_scope, "moderation.content.delete"),
        sanction?: Scope.can?(assigns.current_scope, "moderation.accounts.sanction"),
        reports?: Scope.can?(assigns.current_scope, "moderation.reports"),
        review?: Scope.can?(assigns.current_scope, "moderation.review")
      )

    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      /* The editor slot's root. `pane_layout`'s `<section>` carries no marker from this block, so
         without it `<.form>` (which carries none either) would sit outside this scope. */
      div.report-editor-body:scope {
        display: contents;
      }

      .report-text {
        margin: 0;
        white-space: pre-wrap;
        overflow-wrap: anywhere;
      }

      .report-meta {
        margin: 0;
        color: var(--muted-foreground);
      }

      .report-actions {
        display: flex;
        flex-wrap: wrap;
        gap: var(--size-2);
      }

      .report-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      div.report-queues:scope {
        flex: none;
        padding: var(--panel-gap) var(--panel-gap) 0;
      }

      .report-field {
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
        padding-block: var(--size-2);
      }

      .report-field-label {
        margin: 0;
        font-weight: 600;
      }
    </style>

    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <ModerationNav.nav current_scope={@current_scope} active="reports" />
      <div class="report-queues">
        <.tabs
          id="review"
          label={
            dpgettext(
              "moderation",
              "aria label: tabs choosing a moderation review queue",
              "Review queue"
            )
          }
          active={@queue}
        >
          <:tab :if={@reports?} name="reports" patch={~p"/moderation/reports"}>
            {dpgettext("moderation", "tab: queue of users' reports", "Reports")}
          </:tab>
          <:tab :if={@review?} name="flagged" patch={~p"/moderation/flagged"}>
            {dpgettext("moderation", "tab: queue of content the rules flagged", "Flagged")}
          </:tab>
          <:tab :if={@review?} name="held" patch={~p"/moderation/held"}>
            {dpgettext("moderation", "tab: queue of content held for review", "Held")}
          </:tab>
        </.tabs>
      </div>
      <.pane_layout :if={@queue == "held"}>
        <:list id="held-nav" label={queue_title("held")}>
          <.pane_header title={
            dpgettext("moderation", "heading: queue of content held for review", "Held")
          } />
          <.pane_items
            :let={hold}
            id="held"
            rows={@streams.holds}
            empty?={@holds_empty?}
            empty={
              dpgettext(
                "moderation",
                "empty state: no content held for review",
                "Nothing is waiting for review"
              )
            }
            selected_id={@selected_id}
            patch={fn hold -> ~p"/moderation/held/#{hold.id}" end}
          >
            <span class="pane-item-name">{hold.title}</span>
            <span class="pane-item-meta">
              {ModerationNav.subject_label(hold.kind)} · {action_label(hold.action)} · {status_label(
                hold.status
              )}
            </span>
            <span class="pane-item-meta">
              <.local_time id={"held-#{hold.id}-time"} at={hold.inserted_at} />
            </span>
          </.pane_items>
        </:list>
        <:editor id="held-editor">
          <.pane_placeholder :if={is_nil(@hold)} id="held-placeholder">
            {dgettext("moderation", "Select held content to review it.")}
          </.pane_placeholder>
          <div :if={@hold} class="report-editor-body">
            <.panel_header sticky>
              <span id="held-title">{@hold.title}</span>
            </.panel_header>

            <.pane_section>
              <p class="report-meta">
                {ModerationNav.subject_label(@hold.kind)} · {action_label(@hold.action)} · {status_label(
                  @hold.status
                )} ·
                <%= for part <- around_mark(submitted_by()) do %>
                  <%= if part == :mark do %>
                    <.link navigate={record_path(@hold.user_id)} id="held-submitter-link">
                      {ModerationNav.handle(@hold_user)}
                    </.link>
                  <% else %>
                    {part}
                  <% end %>
                <% end %>
                <.local_time id="held-time" at={@hold.inserted_at} />
              </p>
            </.pane_section>

            <.pane_section :if={@hold.findings != []} id="held-findings">
              <.section_header>
                {dpgettext("moderation", "heading: what the moderation rules found", "Rule findings")}
              </.section_header>
              <.findings id="held-findings-list" findings={@hold.findings} />
            </.pane_section>

            <.pane_section id="held-fields">
              <.section_header>
                {if @hold.action == :update,
                  do: dpgettext("moderation", "heading: the edits held for review", "Changes"),
                  else: dpgettext("moderation", "heading: the content held for review", "Content")}
              </.section_header>
              <div :for={{label, old, new} <- hold_rows(@hold)} class="report-field">
                <p class="report-field-label">{label}</p>
                <%= if @hold.action == :update do %>
                  <p class="report-meta">
                    {dpgettext(
                      "moderation",
                      "heading: a field's saved text, before the held edit",
                      "Current"
                    )}
                  </p>
                  <p class="report-text">{old}</p>
                  <p class="report-meta">
                    {dpgettext("moderation", "heading: a field's text in the held edit", "Proposed")}
                  </p>
                <% end %>
                <p class="report-text">{new}</p>
              </div>
            </.pane_section>

            <.pane_section>
              <div class="report-actions">
                <.button id="held-approve" variant="primary" phx-click="approve_hold">
                  <.lucide name="check" />
                  {dpgettext("moderation", "button: approve and save the held content", "Approve")}
                </.button>
                <.button
                  :if={
                    @sanction? && @hold_user &&
                      Moderation.sanctionable(@current_scope, @hold_user) == :ok
                  }
                  id="held-sanction"
                  navigate={record_path(@hold.user_id)}
                >
                  <.lucide name="shield-alert" />
                  {dpgettext(
                    "moderation",
                    "button: open the owner's record to warn or suspend them",
                    "Warn or suspend"
                  )}
                </.button>
              </div>
            </.pane_section>

            <.pane_section>
              <.section_header>
                {dpgettext("moderation", "heading: form that rejects held content", "Reject")}
              </.section_header>
              <.form
                for={@reject_form}
                id="held-reject-form"
                class="report-form"
                phx-submit="reject_hold"
              >
                <.editor
                  field={@reject_form[:reason]}
                  id="held-reject-reason"
                  label={
                    dpgettext(
                      "moderation",
                      "field label: why held content is rejected",
                      "Why (its submitter is told)"
                    )
                  }
                />
                <.form_actions>
                  <.button type="submit" variant="primary" danger>
                    {dpgettext("moderation", "button: reject the held content", "Reject")}
                  </.button>
                </.form_actions>
              </.form>
            </.pane_section>
          </div>
        </:editor>
      </.pane_layout>
      <.pane_layout :if={@queue != "held"}>
        <:list id="reports-nav" label={queue_title(@queue)}>
          <.pane_header title={
            if @queue == "flagged",
              do: dpgettext("moderation", "heading: queue of content the rules flagged", "Flagged"),
              else: dpgettext("moderation", "heading: queue of users' reports", "Reports")
          } />
          <.pane_items
            :let={report}
            id="reports"
            rows={@streams.reports}
            empty?={@reports_empty?}
            empty={
              if @queue == "flagged",
                do:
                  dpgettext("moderation", "empty state: the rules flagged nothing", "Nothing flagged"),
                else: dpgettext("moderation", "empty state: no open reports", "No open reports")
            }
            selected_id={@selected_id}
            patch={fn report -> item_path(@queue, report.id) end}
          >
            <span class="pane-item-name">{type_label(report.subject_type)}</span>
            <span class="pane-item-meta">{excerpt(report.snapshot, 80)}</span>
            <span class="pane-item-meta">
              {reporter_meta(report)}
              <.local_time id={"reports-#{report.id}-time"} at={report.inserted_at} />
            </span>
          </.pane_items>
        </:list>
        <:editor id="report-editor">
          <.pane_placeholder :if={is_nil(@report)} id="report-placeholder">
            {dgettext("moderation", "Select a report to review it.")}
          </.pane_placeholder>
          <div :if={@report} class="report-editor-body">
            <.panel_header sticky>
              {report_title(@report)}
            </.panel_header>

            <.pane_section>
              <.section_header>
                {reported_heading(@report.subject_type)}
              </.section_header>
              <p id="report-snapshot" class="report-text">{@report.snapshot}</p>
              <p :if={@report.subject_user} id="report-subject" class="report-meta">
                <%= for part <- around_mark(subject_account()) do %>
                  <%= if part == :mark do %>
                    <.link navigate={record_path(@report.subject_user.id)} id="report-subject-link">
                      @{@report.subject_user.handle}
                    </.link>
                  <% else %>
                    {part}
                  <% end %>
                <% end %>
              </p>
            </.pane_section>

            <.pane_section>
              <.section_header>
                {dpgettext("moderation", "heading: why the report was filed", "Reason")}
              </.section_header>
              <p id="report-reason" class="report-text">{@report.reason}</p>
              <p class="report-meta">
                <%= if @report.reporter do %>
                  <%= for part <- around_mark(reported_by()) do %>
                    <%= if part == :mark do %>
                      <.link navigate={record_path(@report.reporter.id)} id="report-reporter-link">
                        @{@report.reporter.handle}
                      </.link>
                    <% else %>
                      {part}
                    <% end %>
                  <% end %>
                <% else %>
                  <span id="report-reporter-link">
                    {dpgettext(
                      "moderation",
                      "status: the rules filed a report",
                      "Reported by automated rules"
                    )}
                  </span>
                <% end %>
                <.local_time id="report-time" at={@report.inserted_at} />
              </p>
            </.pane_section>

            <.pane_section :if={@report.findings != []} id="report-findings">
              <.section_header>
                {dpgettext("moderation", "heading: what the moderation rules found", "Rule findings")}
              </.section_header>
              <.findings id="report-findings-list" findings={@report.findings} />
            </.pane_section>

            <.pane_section>
              <div class="report-actions">
                <.button
                  :if={can_open?(@current_scope, @report)}
                  id="report-open"
                  navigate={Lookup.path({@report.subject_type, @report.subject_id})}
                >
                  <.lucide name="eye" />
                  {dpgettext("moderation", "button: open the reported item", "Open")}
                </.button>
                <.button
                  :if={
                    @sanction? && @report.subject_user &&
                      Moderation.sanctionable(@current_scope, @report.subject_user) == :ok
                  }
                  id="report-sanction"
                  navigate={
                    ~p"/moderation/users/#{@report.subject_user_id}/record?report=#{@report.id}"
                  }
                >
                  <.lucide name="shield-alert" />
                  {dpgettext(
                    "moderation",
                    "button: open the owner's record to warn or suspend them",
                    "Warn or suspend"
                  )}
                </.button>
                <.button
                  :if={@delete? && deletable?(@report)}
                  id="report-delete-content"
                  danger
                  phx-click="delete_content"
                  data-confirm={delete_confirm(@report.subject_type)}
                >
                  <.lucide name="trash" /> {delete_button(@report.subject_type)}
                </.button>
                <.button id="report-dismiss" phx-click="dismiss">
                  <.lucide name="x" /> {dpgettext(
                    "moderation",
                    "button: dismiss the report",
                    "Dismiss"
                  )}
                </.button>
              </div>
            </.pane_section>

            <.pane_section :if={@delete? && @report.subject_type == :listing}>
              <.section_header>
                {dpgettext(
                  "moderation",
                  "heading: form that takes a reported catalog listing down",
                  "Take the listing down"
                )}
              </.section_header>
              <.form
                for={@takedown_form}
                id="report-takedown"
                class="report-form"
                phx-submit="takedown"
              >
                <.editor
                  field={@takedown_form[:reason]}
                  id="report-takedown-reason"
                  label={
                    dpgettext(
                      "moderation",
                      "field label: why a catalog listing is taken down",
                      "Why (its owner is told)"
                    )
                  }
                />
                <.form_actions>
                  <.button type="submit" variant="primary" danger>
                    {dpgettext("moderation", "button: take the catalog listing down", "Take down")}
                  </.button>
                </.form_actions>
              </.form>
            </.pane_section>
          </div>
        </:editor>
      </.pane_layout>
      <MythweaverWeb.Sudo.modal :if={@sudo_prompt} prompt={@sudo_prompt} />
    </Layouts.app>
    """
  end
end
