defmodule MythweaverWeb.JobLive do
  @moduledoc """
  The generation job queue (`Mythweaver.Jobs`): every reply, regenerate, continue and memory job,
  newest first, live.

  The left pane picks the scope: "All", or one chat (`?chat=<id>`, which the chat header's Jobs
  button links to). Each row counts the jobs that still need something (queued, running, review).
  The main pane's header stops every queued and running job in that scope, or only its memory jobs.
  Below it, `?status=<status>` narrows the list to one status and `?kind=memory` to memory jobs.

  Rows can be canceled while queued or running, retried (memory jobs that failed, were canceled or
  were interrupted; a scene memory also as "Retry memory only", which skips its after-memory side
  prompts), opened for review, dismissed once finished, and expanded to show the model's raw
  output. A running row's "Live output" shows the text received so far
  (`MythweaverWeb.JobLive.LiveOutput`), refreshed once a second while any is open, to tell a slow
  job from a stuck one. Each row's meta line names the prompt that built the request, when there
  was one.
  """
  use MythweaverWeb, :live_view

  import MythweaverWeb.Pane, only: [pane_layout: 1, pane_header: 1, pane_items: 1, pane_section: 1]

  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Format
  alias Mythweaver.Jobs
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Memory
  alias MythweaverWeb.JobLive.LiveOutput
  alias MythweaverWeb.MainChatLive.MemoryPanel

  @live_refresh_ms 1000

  # Display order; the URL carries the status atom's name, matched against this list.
  @statuses [:queued, :running, :review, :completed, :failed, :canceled, :interrupted]

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket) do
      Jobs.subscribe(scope)
      Chats.subscribe(scope)
    end

    {:ok,
     socket
     |> assign(
       page_title: dpgettext("jobs", "page title: generation job queue", "Jobs"),
       chat_id: nil,
       chat: nil,
       status: nil,
       kind: :all,
       raw_open: MapSet.new(),
       live_open: MapSet.new(),
       live_tick: nil,
       finished_ids: MapSet.new(),
       chats: list_chats(scope),
       counts: Jobs.active_counts(scope),
       correct_form: to_form(%{}, as: :correct),
       queue_positions: if(connected?(socket), do: Jobs.queue_positions(scope), else: %{})
     )
     |> put_job_ids(MapSet.new())
     |> stream_configure(:job_chats, dom_id: &"job-chats-#{&1.id}")
     |> stream_configure(:jobs, dom_id: &"jobs-#{&1.id}")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    chat = params["chat"] && Enum.find(socket.assigns.chats, &(&1.id == params["chat"]))
    status = Enum.find(@statuses, &(Atom.to_string(&1) == params["status"]))
    kind = if params["kind"] == "memory", do: :memory, else: :all

    {:noreply,
     socket
     |> assign(chat: chat, chat_id: chat && chat.id, status: status, kind: kind)
     |> assign(filter_form: to_form(%{"status" => status && Atom.to_string(status)}, as: :filter))
     |> assign_kind_paths()
     |> stream_chats()
     |> stream_jobs()}
  end

  @impl true
  def handle_event("filter", %{"filter" => %{"status" => status}}, socket) do
    {:noreply, push_patch(socket, to: jobs_path(socket.assigns, status: blank_to_nil(status)))}
  end

  def handle_event("stop_all", _params, socket) do
    count =
      Jobs.cancel_all(socket.assigns.current_scope, Jobs.chat_tags() ++ Jobs.worker_tags(),
        chat_id: socket.assigns.chat_id
      )

    {:noreply, put_flash(socket, :info, stopped_message(count, :all))}
  end

  def handle_event("stop_memory", _params, socket) do
    count = Jobs.cancel_all(socket.assigns.current_scope, Jobs.memory_tags(), chat_id: socket.assigns.chat_id)
    {:noreply, put_flash(socket, :info, stopped_message(count, :memory))}
  end

  def handle_event("cancel", %{"id" => id}, socket) do
    with_job(socket, id, fn _job ->
      case Jobs.cancel(socket.assigns.current_scope, id) do
        :ok -> socket
        {:error, :unauthorized} -> flash_unauthorized(socket)
        {:error, :not_found} -> put_flash(socket, :error, already_finished_message())
      end
    end)
  end

  def handle_event("retry", %{"id" => id}, socket) do
    with_job(socket, id, fn _job -> retry(socket, id, %{}) end)
  end

  def handle_event("retry_memory", %{"id" => id}, socket) do
    with_job(socket, id, fn _job -> retry(socket, id, %{"skip_side_prompts" => true}) end)
  end

  def handle_event("dismiss", %{"id" => id}, socket) do
    with_job(socket, id, fn job ->
      case Jobs.dismiss(socket.assigns.current_scope, job.id) do
        {:ok, _job} -> remove_job(socket, job.id)
        {:error, :unauthorized} -> flash_unauthorized(socket)
        {:error, :not_found} -> put_flash(socket, :error, not_dismissable_message())
      end
    end)
  end

  def handle_event("dismiss_all", _params, socket) do
    Jobs.dismiss_all(socket.assigns.current_scope, list_opts(socket.assigns))
    {:noreply, Enum.reduce(socket.assigns.finished_ids, socket, &remove_job(&2, &1))}
  end

  def handle_event("toggle_raw", %{"id" => id}, socket) do
    with_job(socket, id, fn job ->
      socket |> assign(raw_open: toggle(socket.assigns.raw_open, job.id)) |> stream_insert(:jobs, job)
    end)
  end

  def handle_event("toggle_live", %{"id" => id}, socket) do
    with_job(socket, id, fn job ->
      socket
      |> assign(live_open: toggle(socket.assigns.live_open, job.id))
      |> schedule_live_refresh()
      |> stream_insert(:jobs, job)
    end)
  end

  # A failed memory or consolidation whose reply was malformed: the hand-fixed reply becomes a
  # review draft, approved in the chat's memory panel like any other.
  def handle_event("correct", %{"correct" => %{"id" => id, "text" => text}}, socket) do
    with_job(socket, id, fn job ->
      case Memory.correct(socket.assigns.current_scope, job, text) do
        {:ok, job} ->
          socket = put_flash(socket, :info, sent_to_review_message())
          if job.chat_id, do: push_navigate(socket, to: ~p"/chats/#{job.chat_id}/memory?tab=reviews"), else: socket

        {:error, :unauthorized} ->
          flash_unauthorized(socket)

        {:error, reason} ->
          put_flash(socket, :error, MemoryPanel.error_message(reason))
      end
    end)
  end

  @impl true
  def handle_info({:job_changed, %{id: id}}, socket) do
    scope = socket.assigns.current_scope
    socket = socket |> assign(counts: Jobs.active_counts(scope)) |> stream_chats()

    with %Job{} = job <- Jobs.get_job(scope, id),
         true <- shown?(job, socket.assigns) do
      live_open =
        if job.status == :running, do: socket.assigns.live_open, else: MapSet.delete(socket.assigns.live_open, id)

      {:noreply,
       socket
       |> assign(live_open: live_open)
       |> put_job_ids(MapSet.put(socket.assigns.job_ids, job.id))
       |> put_finished(job)
       |> stream_insert(:jobs, job, at: 0)}
    else
      _ -> {:noreply, remove_job(socket, id)}
    end
  end

  def handle_info({:job_progress, %{id: id} = payload}, socket) do
    if MapSet.member?(socket.assigns.job_ids, id),
      do: {:noreply, push_event(socket, "job_progress", payload)},
      else: {:noreply, socket}
  end

  # Stream rows of other jobs do not re-render, so their hooks take the positions as an event.
  def handle_info({:job_queue, positions}, socket) do
    {:noreply, socket |> assign(queue_positions: positions) |> push_event("job_queue", %{positions: positions})}
  end

  def handle_info(:refresh_live, socket) do
    Enum.each(socket.assigns.live_open, &send_update(LiveOutput, id: live_output_id(&1)))
    {:noreply, socket |> assign(live_tick: nil) |> schedule_live_refresh()}
  end

  def handle_info({:chat_deleted, chat_id}, %{assigns: %{chat_id: chat_id}} = socket) do
    socket = assign(socket, chats: list_chats(socket.assigns.current_scope), chat: nil, chat_id: nil)
    {:noreply, push_patch(socket, to: jobs_path(socket.assigns, []))}
  end

  def handle_info({event, _chat_id}, socket) when event in [:chat_created, :chat_updated, :chat_deleted] do
    chats = list_chats(socket.assigns.current_scope)
    chat = socket.assigns.chat_id && Enum.find(chats, &(&1.id == socket.assigns.chat_id))
    {:noreply, socket |> assign(chats: chats, chat: chat) |> stream_chats()}
  end

  # Ids arrive from the client, so only a job this page is showing is acted on.
  defp with_job(socket, id, fun) do
    case MapSet.member?(socket.assigns.job_ids, id) && Jobs.get_job(socket.assigns.current_scope, id) do
      %Job{} = job -> {:noreply, fun.(job)}
      _gone -> {:noreply, remove_job(socket, id)}
    end
  end

  defp retry(socket, id, overrides) do
    case Jobs.retry(socket.assigns.current_scope, id, overrides) do
      {:ok, _job} -> socket
      {:error, :unauthorized} -> flash_unauthorized(socket)
      {:error, :no_model} -> put_flash(socket, :error, no_model_message())
      {:error, :quota_exceeded} -> flash_quota(socket, "quota.spend_per_day")
      {:error, :not_retryable} -> put_flash(socket, :error, not_retryable_message())
    end
  end

  defp stopped_message(0, :all) do
    gettext_comment("Flash after Stop all on the jobs page when nothing was queued or running.")
    dpgettext("jobs", "status: flash after stopping all jobs when none was running", "No jobs to stop")
  end

  defp stopped_message(0, :memory) do
    gettext_comment("Flash after Stop memory jobs on the jobs page when none was queued or running.")
    dgettext("jobs", "No memory jobs to stop")
  end

  defp stopped_message(count, :all) do
    gettext_comment("Flash after Stop all on the jobs page.")

    dpngettext(
      "jobs",
      "status: flash after stopping all jobs",
      "Stopped %{job_count} job",
      "Stopped %{job_count} jobs",
      count,
      job_count: Format.number(count)
    )
  end

  defp stopped_message(count, :memory) do
    gettext_comment("Flash after Stop memory jobs on the jobs page.")

    dpngettext(
      "jobs",
      "status: flash after stopping memory jobs",
      "Stopped %{job_count} memory job",
      "Stopped %{job_count} memory jobs",
      count,
      job_count: Format.number(count)
    )
  end

  defp already_finished_message do
    gettext_comment("Error flash when canceling a job that finished meanwhile.")
    dgettext("jobs", "That job has already finished")
  end

  defp not_dismissable_message do
    gettext_comment("Error flash when dismissing a job that is still queued or running.")
    dgettext("jobs", "Only a finished job can be dismissed")
  end

  defp sent_to_review_message do
    gettext_comment("Flash after a hand-corrected job output is sent to memory review.")
    dpgettext("jobs", "status: flash after a job's output is sent to memory review", "Sent to review")
  end

  defp no_model_message do
    gettext_comment("Error flash when retrying a job whose AI model was deleted.")
    dgettext("jobs", "That job's model no longer exists")
  end

  defp not_retryable_message do
    gettext_comment("Error flash when retrying a job that cannot be retried.")
    dgettext("jobs", "That job cannot be retried")
  end

  defp stop_all_confirm(nil) do
    gettext_comment("Confirm dialog before stopping every queued and running job.")
    dgettext("jobs", "Stop every queued and running job?")
  end

  defp stop_all_confirm(chat) do
    gettext_comment("Confirm dialog before stopping every queued and running job of one chat.")
    dgettext("jobs", "Stop every queued and running job in %{chat_title}?", chat_title: chat.name)
  end

  defp list_chats(scope), do: Enum.map(Chats.list_chats(scope), &%{id: &1.id, name: Chat.title(&1)})

  # The nav rows: "All" first, then every chat. Re-streamed whenever a count or filter changes,
  # because each row's link carries the current filters.
  defp stream_chats(socket) do
    %{chats: chats, counts: counts} = socket.assigns

    all = %{
      id: "all",
      chat_id: nil,
      name: dpgettext("jobs", "menu item: jobs of every chat", "All"),
      count: counts |> Map.values() |> Enum.sum()
    }

    chat_rows = Enum.map(chats, &%{id: &1.id, chat_id: &1.id, name: &1.name, count: Map.get(counts, &1.id, 0)})
    rows = Enum.map([all | chat_rows], &Map.put(&1, :path, jobs_path(socket.assigns, chat: &1.chat_id)))
    stream(socket, :job_chats, rows, reset: true)
  end

  defp assign_kind_paths(socket) do
    assign(socket,
      kind_all_path: jobs_path(socket.assigns, kind: :all),
      kind_memory_path: jobs_path(socket.assigns, kind: :memory)
    )
  end

  defp stream_jobs(socket) do
    jobs = Jobs.list_jobs(socket.assigns.current_scope, list_opts(socket.assigns))

    socket
    |> put_job_ids(MapSet.new(jobs, & &1.id))
    |> assign(finished_ids: for(job <- jobs, terminal?(job), into: MapSet.new(), do: job.id))
    |> stream(:jobs, jobs, reset: true)
  end

  defp list_opts(assigns) do
    [
      chat_id: assigns.chat_id,
      statuses: assigns.status && [assigns.status],
      tags: if(assigns.kind == :memory, do: Jobs.memory_tags())
    ]
  end

  defp shown?(%Job{} = job, assigns) do
    (assigns.chat_id == nil or job.chat_id == assigns.chat_id) and
      (assigns.status == nil or job.status == assigns.status) and
      (assigns.kind == :all or memory?(job))
  end

  defp remove_job(socket, id) do
    socket
    |> assign(
      raw_open: MapSet.delete(socket.assigns.raw_open, id),
      live_open: MapSet.delete(socket.assigns.live_open, id),
      finished_ids: MapSet.delete(socket.assigns.finished_ids, id)
    )
    |> put_job_ids(MapSet.delete(socket.assigns.job_ids, id))
    |> stream_delete_by_dom_id(:jobs, "jobs-#{id}")
  end

  # The ids on screen: the stream itself is not enumerable, and client-sent ids are checked here.
  defp put_job_ids(socket, ids), do: assign(socket, job_ids: ids, jobs_empty?: MapSet.size(ids) == 0)

  defp toggle(set, id), do: if(MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id))

  # One timer while any live panel is open; it stops rescheduling once none is.
  defp schedule_live_refresh(%{assigns: %{live_tick: nil, live_open: open}} = socket) do
    if MapSet.size(open) > 0,
      do: assign(socket, live_tick: Process.send_after(self(), :refresh_live, @live_refresh_ms)),
      else: socket
  end

  defp schedule_live_refresh(socket), do: socket

  defp live_output_id(job_id), do: "job-live-output-#{job_id}"

  # The shown jobs "Dismiss all" removes; it shows only while there is one.
  defp put_finished(socket, %Job{} = job) do
    finished = socket.assigns.finished_ids
    finished = if terminal?(job), do: MapSet.put(finished, job.id), else: MapSet.delete(finished, job.id)
    assign(socket, finished_ids: finished)
  end

  # `/jobs` with the current scope and filters, `overrides` replacing some of them.
  defp jobs_path(assigns, overrides) do
    current = [chat: assigns.chat_id, status: assigns.status, kind: assigns.kind != :all && assigns.kind]

    query =
      current
      |> Keyword.merge(overrides)
      |> Enum.reject(fn {_key, value} -> value in [nil, false, :all] end)

    if query == [], do: ~p"/jobs", else: ~p"/jobs?#{query}"
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp status_options do
    [
      {dpgettext("jobs", "option: no job status filter", "Any status"), ""}
      | Enum.map(@statuses, &{status_label(&1), &1})
    ]
  end

  defp status_label(:queued), do: dpgettext("jobs", "status: generation job", "Pending")
  defp status_label(:running), do: dpgettext("jobs", "status: generation job", "Running")
  defp status_label(:review), do: dpgettext("jobs", "status: generation job", "Awaiting review")
  defp status_label(:completed), do: dpgettext("jobs", "status: generation job", "Completed")
  defp status_label(:failed), do: dpgettext("jobs", "status: generation job", "Failed")
  defp status_label(:canceled), do: dpgettext("jobs", "status: generation job", "Canceled")
  defp status_label(:interrupted), do: dpgettext("jobs", "status: generation job", "Interrupted")

  defp tag_label(:reply), do: dpgettext("jobs", "option: kind of generation job", "Reply")
  defp tag_label(:regenerate), do: dpgettext("jobs", "option: kind of generation job", "Regenerate")
  defp tag_label(:continue), do: dpgettext("jobs", "option: kind of generation job", "Continue")
  defp tag_label(:refine), do: dpgettext("jobs", "option: kind of generation job", "Refine")
  defp tag_label(:memory), do: dpgettext("jobs", "option: kind of generation job", "Memory")
  defp tag_label(:side_prompt), do: dpgettext("jobs", "option: kind of generation job", "Side prompt")
  defp tag_label(:consolidation), do: dpgettext("jobs", "option: kind of generation job", "Consolidation")
  defp tag_label(:compaction), do: dpgettext("jobs", "option: kind of generation job", "Compaction")
  defp tag_label(:topical_clip), do: dpgettext("jobs", "option: kind of generation job", "Topical clip")

  defp tag_label(:memory_assistance), do: dpgettext("jobs", "option: kind of generation job", "Memory assistance")

  defp tag_label(:caption), do: dpgettext("jobs", "option: kind of generation job", "Caption")
  defp tag_label(:expression), do: dpgettext("jobs", "option: kind of generation job", "Expression")
  defp tag_label(:assistant), do: dpgettext("jobs", "option: kind of generation job", "Assistant")

  defp active?(%Job{status: status}), do: status in [:queued, :running]
  defp terminal?(%Job{status: status}), do: status in Jobs.terminal_statuses()
  defp memory?(%Job{tag: tag}), do: tag in Jobs.memory_tags()
  defp retryable?(%Job{status: status} = job), do: memory?(job) and status in [:failed, :canceled, :interrupted]

  # Where a held job is reviewed: the chat's memory reviews, the chat itself for a held image
  # caption, the character's editor for a held avatar description.
  defp review_path(%Job{chat_id: chat_id} = job) when is_binary(chat_id) do
    cond do
      memory?(job) -> ~p"/chats/#{chat_id}/memory?tab=reviews"
      job.tag == :caption -> ~p"/chats/#{chat_id}"
      true -> nil
    end
  end

  defp review_path(%Job{tag: :caption, params: %{"character_id" => id}}) when is_binary(id),
    do: ~p"/characters/#{id}/edit"

  defp review_path(_job), do: nil

  # Only these tags JSON-parse their reply, so only their malformed output can be fixed by hand.
  defp correctable?(%Job{} = job),
    do: job.status == :failed and job.tag in [:memory, :consolidation] and is_binary(job.raw_output)

  defp duration(%Job{started_at: %DateTime{} = started, finished_at: %DateTime{} = finished}) do
    seconds = DateTime.diff(finished, started)

    if seconds < 60,
      do: Format.seconds(seconds * 1000, fractional_digits: 0),
      else: Format.duration_ms(seconds * 1000)
  end

  defp duration(%Job{}), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      div.jobs-body:scope {
        display: contents;
      }

      /* Other pane screens get this gap from `pane_actions`/`pane_search` above the rows; this list
         sits straight under the header. */
      div.job-chats-body:scope {
        padding-top: var(--size-2);
      }

      .jobs-header-actions {
        display: flex;
        gap: var(--size-2);
      }

      .jobs-toolbar {
        display: flex;
        flex-wrap: wrap;
        align-items: flex-end;
        justify-content: space-between;
        gap: var(--size-2) var(--size-3);
      }

      .jobs-filter-form {
        min-inline-size: 12rem;
      }

      .jobs-filter-form label {
        display: block;
      }

      .jobs-kind {
        display: flex;
        gap: var(--size-1);
      }

      .jobs-count {
        margin-inline-start: auto;
        min-inline-size: 1.5em;
        text-align: center;
      }

      .job-chats-row {
        display: flex;
        align-items: center;
        gap: var(--size-2);
      }

      .jobs-empty {
        margin: 0;
        color: var(--muted-foreground);
      }

      .jobs-list {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
        list-style: none;
        margin: 0;
        padding: 0;
      }

      .jobs-row {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
        padding: var(--size-2) var(--size-3);
        border: 1px solid var(--border);
        border-radius: var(--radius-2);
        background: var(--surface-2);
      }

      .jobs-row[data-status="running"] {
        border-color: color-mix(in oklab, var(--primary-accent) 50%, var(--border));
      }

      .jobs-row-head {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: var(--size-2);
      }

      .jobs-label {
        font-weight: 600;
        overflow-wrap: anywhere;
      }

      .jobs-tag {
        font-size: var(--font-size-0);
        color: var(--muted-foreground);
        padding: 0 var(--size-1);
        border: 1px solid var(--border);
        border-radius: var(--radius-1);
      }

      .jobs-status {
        font-size: var(--font-size-0);
        font-weight: 600;
        padding: 0.1rem 0.5rem;
        border-radius: var(--radius-round);
        color: var(--muted-foreground);
        background: var(--surface-4);
      }

      .jobs-status[data-status="running"],
      .jobs-status[data-status="review"] {
        color: var(--primary-accent);
        background: color-mix(in oklab, var(--primary-accent) 15%, transparent);
      }

      .jobs-status[data-status="failed"] {
        color: var(--destructive);
        background: color-mix(in oklab, var(--destructive) 15%, transparent);
      }

      .jobs-status[data-status="completed"] {
        color: var(--foreground);
      }

      .jobs-row-meta {
        display: flex;
        flex-wrap: wrap;
        gap: var(--size-1) var(--size-3);
        color: var(--muted-foreground);
        font-size: var(--font-size-0);
      }

      .jobs-error {
        margin: 0;
        color: var(--destructive);
        overflow-wrap: anywhere;
      }

      .jobs-row-actions {
        display: flex;
        flex-wrap: wrap;
        justify-content: flex-end;
        gap: var(--size-2);
        margin-inline-start: auto;
      }

      .jobs-raw {
        margin: 0;
        max-block-size: 20rem;
        overflow: auto;
        white-space: pre-wrap;
        background: var(--surface-1);
        padding: var(--size-2);
        border-radius: var(--radius-2);
      }

      @media (--phone) {
        .jobs-filter-form {
          min-inline-size: 0;
          flex: 1 1 100%;
        }
        .jobs-header-actions {
          flex-wrap: wrap;
          justify-content: flex-end;
        }
      }
    </style>

    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.pane_layout>
        <:list
          id="job-chats-nav"
          label={dpgettext("jobs", "aria label: list of chats to filter jobs by", "Job scope")}
        >
          <.pane_header title={dpgettext("jobs", "heading: generation job queue", "Jobs")} />
          <div class="job-chats-body">
            <.pane_items
              :let={row}
              id="job-chats"
              rows={@streams.job_chats}
              empty?={false}
              empty=""
              selected_id={@chat_id || "all"}
              patch={& &1.path}
            >
              <span class="job-chats-row">
                <span class="pane-item-name">{row.name}</span>
                <.badge :if={row.count > 0} class="jobs-count" id={"job-chats-#{row.id}-count"}>
                  {row.count}
                </.badge>
              </span>
            </.pane_items>
          </div>
        </:list>
        <:editor id="jobs-main">
          <div class="jobs-body">
            <.panel_header sticky>
              {if @chat,
                do: @chat.name,
                else: dpgettext("jobs", "heading: jobs of every chat", "All jobs")}
              <:actions>
                <div class="jobs-header-actions">
                  <.button
                    size="sm"
                    danger
                    id="jobs-stop-all"
                    phx-click="stop_all"
                    data-confirm={stop_all_confirm(@chat)}
                  >
                    <.lucide name="octagon-x" /> {dpgettext(
                      "jobs",
                      "button: stop every queued and running job",
                      "Stop all"
                    )}
                  </.button>
                  <.button
                    :if={MapSet.size(@finished_ids) > 0}
                    size="sm"
                    id="jobs-dismiss-all"
                    phx-click="dismiss_all"
                  >
                    <.lucide name="x" /> {dpgettext(
                      "jobs",
                      "button: remove every finished job from the list",
                      "Dismiss all"
                    )}
                  </.button>
                  <.button size="sm" id="jobs-stop-memory" phx-click="stop_memory">
                    <.lucide name="brain" /> {dpgettext(
                      "jobs",
                      "button: stop every queued and running memory job",
                      "Stop memory jobs"
                    )}
                  </.button>
                </div>
              </:actions>
            </.panel_header>

            <.pane_section>
              <div class="jobs-toolbar">
                <.form
                  for={@filter_form}
                  id="jobs-filter-form"
                  class="jobs-filter-form"
                  phx-change="filter"
                  phx-submit="filter"
                >
                  <.input
                    field={@filter_form[:status]}
                    type="select"
                    label={dpgettext("jobs", "field label: filter jobs by status", "Status")}
                    options={status_options()}
                    id="jobs-filter-form-status"
                  />
                </.form>
                <div
                  class="jobs-kind"
                  role="group"
                  aria-label={dpgettext("jobs", "aria label: filter jobs by kind", "Job kind")}
                >
                  <.button
                    size="sm"
                    id="jobs-kind-all"
                    patch={@kind_all_path}
                    aria-pressed={to_string(@kind == :all)}
                  >
                    {dpgettext("jobs", "button: show jobs of every kind", "All jobs")}
                  </.button>
                  <.button
                    size="sm"
                    id="jobs-kind-memory"
                    patch={@kind_memory_path}
                    aria-pressed={to_string(@kind == :memory)}
                  >
                    {dpgettext("jobs", "button: show only memory jobs", "Memory only")}
                  </.button>
                </div>
              </div>
            </.pane_section>

            <.pane_section>
              <p :if={@jobs_empty?} id="jobs-empty" class="jobs-empty">
                {if @status || @kind == :memory,
                  do: dgettext("jobs", "No jobs match these filters."),
                  else:
                    dpgettext("jobs", "empty state: jobs list with no jobs at all", "No jobs yet.")}
              </p>

              <ul id="jobs" class="jobs-list" phx-update="stream">
                <li
                  :for={{dom_id, job} <- @streams.jobs}
                  id={dom_id}
                  class="jobs-row"
                  data-status={job.status}
                >
                  <div class="jobs-row-head">
                    <span class="jobs-status" data-status={job.status}>{status_label(job.status)}</span>
                    <span class="jobs-label">{job.label}</span>
                    <span class="jobs-tag">{tag_label(job.tag)}</span>
                    <div class="jobs-row-actions">
                      <.button
                        :if={active?(job)}
                        size="sm"
                        danger
                        id={"job-cancel-#{job.id}"}
                        phx-click="cancel"
                        phx-value-id={job.id}
                      >
                        {dpgettext("jobs", "button: cancel a queued or running job", "Cancel")}
                      </.button>
                      <.button
                        :if={job.status == :running}
                        size="sm"
                        id={"job-live-#{job.id}"}
                        phx-click="toggle_live"
                        phx-value-id={job.id}
                        aria-expanded={to_string(MapSet.member?(@live_open, job.id))}
                      >
                        <.lucide name="radio" /> {dpgettext(
                          "jobs",
                          "button: show the text a running job has received so far",
                          "Live output"
                        )}
                      </.button>
                      <.button
                        :if={retryable?(job)}
                        size="sm"
                        id={"job-retry-#{job.id}"}
                        phx-click="retry"
                        phx-value-id={job.id}
                      >
                        {dpgettext("jobs", "button: run a failed job again", "Retry")}
                      </.button>
                      <.button
                        :if={retryable?(job) and job.tag == :memory}
                        size="sm"
                        id={"job-retry-memory-#{job.id}"}
                        phx-click="retry_memory"
                        phx-value-id={job.id}
                        title={
                          dgettext("jobs", "Retry without running the after-memory side prompts")
                        }
                      >
                        {dpgettext(
                          "jobs",
                          "button: run a failed scene memory again without its side prompts",
                          "Retry memory only"
                        )}
                      </.button>
                      <.button
                        :if={job.status == :review and review_path(job) != nil}
                        size="sm"
                        variant="primary"
                        id={"job-review-#{job.id}"}
                        navigate={review_path(job)}
                      >
                        {dpgettext("jobs", "button: open a held job's result for review", "Review")}
                      </.button>
                      <.button
                        :if={job.raw_output}
                        size="sm"
                        id={"job-raw-#{job.id}"}
                        phx-click="toggle_raw"
                        phx-value-id={job.id}
                        aria-expanded={to_string(MapSet.member?(@raw_open, job.id))}
                      >
                        {dpgettext(
                          "jobs",
                          "button: show the model's raw output of a job",
                          "Raw output"
                        )}
                      </.button>
                      <.button
                        :if={terminal?(job)}
                        size="sm"
                        id={"job-dismiss-#{job.id}"}
                        phx-click="dismiss"
                        phx-value-id={job.id}
                      >
                        {dpgettext("jobs", "button: remove a finished job from the list", "Dismiss")}
                      </.button>
                    </div>
                  </div>
                  <div class="jobs-row-meta">
                    <.link :if={job.chat && !@chat_id} navigate={~p"/chats/#{job.chat.id}"}>
                      {Chat.title(job.chat)}
                    </.link>
                    <span :if={job.range_start && job.range_end}>
                      {dpgettext(
                        "jobs",
                        "status: range of chat messages a job covers",
                        "Messages #%{first_message}–#%{last_message}",
                        first_message: Format.number(job.range_start + 1),
                        last_message: Format.number(job.range_end + 1)
                      )}
                    </span>
                    <span>
                      {if job.provider,
                        do: job.provider.name,
                        else:
                          dpgettext(
                            "jobs",
                            "status: job not yet assigned a provider",
                            "No provider yet"
                          )}
                    </span>
                    <span :if={job.prompt_name} id={"job-prompt-#{job.id}"}>
                      {dpgettext(
                        "jobs",
                        "field label: prompt that built the job's request",
                        "Prompt: %{prompt_name}",
                        prompt_name: job.prompt_name
                      )}
                    </span>
                    <span>
                      {dpgettext(
                        "jobs",
                        "field label: when the job was queued, a time follows",
                        "Queued"
                      )}
                      <.local_time id={"job-queued-#{job.id}"} at={job.inserted_at} format={:seconds} />
                    </span>
                    <span :if={job.started_at}>
                      {dpgettext(
                        "jobs",
                        "field label: when the job started, a time follows",
                        "Started"
                      )}
                      <.local_time id={"job-started-#{job.id}"} at={job.started_at} format={:seconds} />
                    </span>
                    <span :if={job.finished_at}>
                      {dpgettext(
                        "jobs",
                        "field label: when the job finished, a time follows",
                        "Finished"
                      )}
                      <.local_time
                        id={"job-finished-#{job.id}"}
                        at={job.finished_at}
                        format={:seconds}
                      />
                    </span>
                    <span :if={duration(job)}>
                      {dpgettext(
                        "jobs",
                        "field label: how long the job ran; the duration is like 4s or 2m 5s",
                        "Took %{duration}",
                        duration: duration(job)
                      )}
                    </span>
                  </div>
                  <.job_progress
                    :if={active?(job)}
                    id={"job-progress-#{job.id}"}
                    job={job}
                    position={@queue_positions[job.id]}
                  />
                  <.live_component
                    :if={job.status == :running and MapSet.member?(@live_open, job.id)}
                    module={LiveOutput}
                    id={live_output_id(job.id)}
                    job={job}
                    scope={@current_scope}
                  />
                  <p :if={job.error} class="jobs-error">{job.error}</p>
                  <.form
                    :if={correctable?(job) && MapSet.member?(@raw_open, job.id)}
                    for={@correct_form}
                    id={"job-correct-form-#{job.id}"}
                    phx-submit="correct"
                  >
                    <input type="hidden" name="correct[id]" value={job.id} />
                    <.editor
                      name="correct[text]"
                      value={job.raw_output}
                      language="json"
                      rows={8}
                      label={
                        dpgettext(
                          "jobs",
                          "field label: hand-corrected job output",
                          "Corrected output"
                        )
                      }
                      id={"job-correct-text-#{job.id}"}
                    />
                    <.button type="submit" variant="primary" size="sm" id={"job-correct-#{job.id}"}>
                      {dpgettext(
                        "jobs",
                        "button: send corrected job output to memory review",
                        "Send to review"
                      )}
                    </.button>
                  </.form>
                  <pre
                    :if={!correctable?(job) && job.raw_output && MapSet.member?(@raw_open, job.id)}
                    class="jobs-raw"
                  >{job.raw_output}</pre>
                </li>
              </ul>
            </.pane_section>
          </div>
        </:editor>
      </.pane_layout>
    </Layouts.app>
    """
  end
end
