defmodule MythweaverWeb.SubmissionLive do
  @moduledoc """
  The signed-in user's content waiting for moderator review (`/submissions`): every hold of theirs
  (`Mythweaver.Moderation.Holds.list_own/1`), with a Withdraw that drops it unsaved. Reloads on
  `Mythweaver.Moderation.broadcast_submissions_changed/1`, so a decision or a new hold shows at once.
  """
  use MythweaverWeb, :live_view

  alias Mythweaver.Moderation
  alias Mythweaver.Moderation.Holds
  alias MythweaverWeb.ModerationNav

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Moderation.subscribe_user(socket.assigns.current_scope.user.id)

    {:ok,
     socket
     |> assign(page_title: dpgettext("sharing", "page title: the user's submissions awaiting review", "Submissions"))
     |> stream_configure(:submissions, dom_id: &"submissions-#{&1.id}")
     |> stream_submissions()}
  end

  @impl true
  def handle_event("withdraw", %{"id" => id}, socket) do
    case Holds.withdraw(socket.assigns.current_scope, id) do
      :ok ->
        gettext_comment("Flash after the user withdrew a submission from moderator review.")

        {:noreply,
         socket
         |> put_flash(:info, dpgettext("sharing", "status: submission withdrawn", "Withdrawn"))
         |> stream_submissions()}

      {:error, :not_found} ->
        gettext_comment("Flash when withdrawing a submission a moderator already approved or rejected.")

        {:noreply,
         socket
         |> put_flash(
           :error,
           dpgettext("sharing", "status: submission already approved or rejected", "It was already decided")
         )
         |> stream_submissions()}
    end
  end

  @impl true
  def handle_info({Moderation, :submissions_changed}, socket), do: {:noreply, stream_submissions(socket)}

  defp stream_submissions(socket) do
    holds = Holds.list_own(socket.assigns.current_scope)

    socket
    |> assign(submissions_empty?: holds == [])
    |> stream(:submissions, holds, reset: true)
  end

  defp action_label(:create), do: dpgettext("sharing", "badge: submission adds new content", "New")
  defp action_label(:update), do: dpgettext("sharing", "badge: submission edits existing content", "Edit")
  defp action_label(:import), do: dpgettext("sharing", "badge: submission comes from an import", "Import")

  defp status_label(:scanning), do: dpgettext("sharing", "status: submission being scanned automatically", "Checking")
  defp status_label(:review), do: dpgettext("sharing", "status: submission awaiting review", "Waiting for a moderator")

  defp withdraw_confirm(title) do
    gettext_comment("Confirm dialog before withdrawing a submission from review.")
    dgettext("sharing", "Withdraw “%{submission_title}”? It is discarded unsaved.", submission_title: title)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      div.submissions:scope {
        flex: 1 1 auto;
        min-block-size: 0;
        overflow-y: auto;
        margin: var(--panel-gap);
        background: var(--card);
        border: 1px solid var(--border);
        border-radius: var(--radius-3);
        box-shadow: var(--elevation-lg);
      }

      .submissions-body {
        display: flex;
        flex-direction: column;
        gap: var(--size-3);
        padding: var(--size-3);
      }

      .submissions-list {
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
        margin: 0;
        padding: 0;
        list-style: none;
      }

      .submissions-row {
        display: flex;
        flex-wrap: wrap;
        align-items: baseline;
        gap: var(--size-1) var(--size-2);
        padding: var(--size-2) 0;
        border-bottom: 1px solid var(--border);
      }

      .submissions-title {
        font-weight: 600;
      }

      .submissions-meta {
        color: var(--muted-foreground);
        font-size: 0.875rem;
      }

      .submissions-withdraw {
        margin-inline-start: auto;
      }

      .submissions-empty {
        margin: 0;
        color: var(--muted-foreground);
      }
    </style>
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="submissions">
        <.panel_header sticky>
          {dpgettext("sharing", "heading: the user's submissions awaiting review", "Submissions")}
        </.panel_header>
        <div class="submissions-body">
          <p :if={@submissions_empty?} id="submissions-empty" class="submissions-empty">
            {dgettext("sharing", "Nothing is waiting for review")}
          </p>
          <ul id="submissions" class="submissions-list" phx-update="stream">
            <li :for={{id, hold} <- @streams.submissions} id={id} class="submissions-row">
              <span class="submissions-title">{hold.title}</span>
              <span class="submissions-meta">
                {ModerationNav.subject_label(hold.kind)} · {action_label(hold.action)} · {status_label(
                  hold.status
                )}
              </span>
              <.local_time id={"#{id}-at"} at={hold.inserted_at} class="submissions-meta" />
              <span class="submissions-withdraw">
                <.button
                  size="sm"
                  id={"#{id}-withdraw"}
                  phx-click="withdraw"
                  phx-value-id={hold.id}
                  data-confirm={withdraw_confirm(hold.title)}
                >
                  {dpgettext("sharing", "button: withdraw a submission from review", "Withdraw")}
                </.button>
              </span>
            </li>
          </ul>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
