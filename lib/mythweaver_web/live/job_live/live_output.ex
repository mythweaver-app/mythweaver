defmodule MythweaverWeb.JobLive.LiveOutput do
  @moduledoc """
  A running job's received text on the Jobs page (`Mythweaver.Jobs.live_output/2`): the reasoning
  and the reply so far, each scrolled to its newest text. Re-read on every update, which
  `MythweaverWeb.JobLive` sends once a second while the panel is open; a tick carries only `id`, so
  it reuses the `job` row from the last parent render and costs no job query. A LiveComponent so that
  refresh does not re-insert the job's stream row.
  """
  use MythweaverWeb, :live_component

  alias Mythweaver.Format
  alias Mythweaver.Jobs

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    output = Jobs.live_output(socket.assigns.scope, socket.assigns.job) || %{content: "", reasoning: ""}
    {:ok, assign(socket, output: output)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      div:scope {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .job-live-output-label {
        font-size: var(--font-size-0);
        font-weight: 600;
        color: var(--muted-foreground);
      }

      .job-live-output-empty {
        margin: 0;
        color: var(--muted-foreground);
      }

      /* `column-reverse` keeps the scroll pinned to the newest text as it grows. */
      .job-live-output-text {
        display: flex;
        flex-direction: column-reverse;
        max-block-size: 20rem;
        overflow: auto;
        background: var(--surface-1);
        padding: var(--size-2);
        border-radius: var(--radius-2);
      }

      .job-live-output-text pre {
        margin: 0;
        white-space: pre-wrap;
        overflow-wrap: anywhere;
      }
    </style>
    <div id={@id} class="job-live-output">
      <p
        :if={@output.content == "" and @output.reasoning == ""}
        id={"#{@id}-empty"}
        class="job-live-output-empty"
      >
        {dpgettext(
          "jobs",
          "empty state: a running job's live output before any token arrived",
          "No tokens received yet."
        )}
      </p>
      <span :if={@output.reasoning != ""} class="job-live-output-label">
        {character_count_label(:reasoning, String.length(@output.reasoning))}
      </span>
      <div :if={@output.reasoning != ""} class="job-live-output-text">
        <pre id={"#{@id}-reasoning"}>{@output.reasoning}</pre>
      </div>
      <span :if={@output.content != ""} class="job-live-output-label">
        {character_count_label(:reply, String.length(@output.content))}
      </span>
      <div :if={@output.content != ""} class="job-live-output-text">
        <pre id={"#{@id}-content"}>{@output.content}</pre>
      </div>
    </div>
    """
  end

  defp character_count_label(:reasoning, n) do
    dpngettext(
      "jobs",
      "heading: a running job's reasoning text so far, with its length",
      "Reasoning (%{character_count} character)",
      "Reasoning (%{character_count} characters)",
      n,
      character_count: Format.number(n)
    )
  end

  defp character_count_label(:reply, n) do
    dpngettext(
      "jobs",
      "heading: a running job's reply text so far, with its length",
      "Reply (%{character_count} character)",
      "Reply (%{character_count} characters)",
      n,
      character_count: Format.number(n)
    )
  end
end
