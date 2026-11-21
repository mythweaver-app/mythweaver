defmodule MythweaverWeb.CoreComponents.JobProgress do
  @moduledoc """
  Live progress for one queued or running job: its phase (`Queued #N` → `Reading prompt` →
  `Writing`), an elapsed clock, a prompt-processing bar and an output token count with tokens/sec.

  The server renders the phase as a fallback and carries the row's timestamps in `data-*`
  attributes. The `.JobProgress` hook owns the rest: it ticks the clock every second, and takes the
  LiveView's pushed `"job_progress"` events (`Mythweaver.Jobs.broadcast_progress/1`'s payload) and
  `"job_queue"` events (`%{positions: Jobs.queue_positions(scope)}`), each filtered to this job's id.

  The hook's text comes translated from `MythweaverWeb.ClientStrings.job_progress/0` in
  `data-strings` (colocated hooks cannot import `assets/js/i18n.ts`); its numbers are formatted in
  the regional format (`<html data-locale>`) and its plurals picked in the UI language
  (`<html lang>`). `phase_label/2`, the server fallback, uses the same msgids.

  The prompt bar is exact when the backend reports prompt progress; otherwise it is the history
  estimate (`expected_first_token_ms`), labeled `(est.)`. The hook only sets text, `hidden`, `value`
  and `max` on the four children, so the scoped CSS keeps applying.
  """

  use Phoenix.Component
  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.Format
  alias Mythweaver.Jobs.Job

  attr :id, :string, required: true, doc: "unique per element; `phx-hook` requires it"
  attr :job, Job, required: true, doc: "a queued or running job"
  attr :position, :integer, default: nil, doc: "1-based queue position"

  def job_progress(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      div.job-progress:scope {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: var(--size-1) var(--size-2);
        font-size: var(--font-size-0);
        color: var(--muted-foreground);
      }

      .job-progress-phase {
        font-weight: 600;
        color: var(--primary-accent);
      }

      .job-progress-clock {
        font-variant-numeric: tabular-nums;
      }

      .job-progress-bar {
        inline-size: 8rem;
        block-size: 4px;
      }

      .job-progress-bar[hidden] {
        display: none;
      }
    </style>

    <div
      id={@id}
      class="job-progress"
      phx-hook=".JobProgress"
      phx-update="ignore"
      data-job-id={@job.id}
      data-status={@job.status}
      data-queued-at={DateTime.to_iso8601(@job.inserted_at)}
      data-started-at={@job.started_at && DateTime.to_iso8601(@job.started_at)}
      data-first-token-at={@job.first_token_at && DateTime.to_iso8601(@job.first_token_at)}
      data-expected-ms={@job.expected_first_token_ms}
      data-position={@position}
      data-strings={Jason.encode!(MythweaverWeb.ClientStrings.job_progress())}
    >
      <span class="job-progress-phase">{phase_label(@job, @position)}</span>
      <span class="job-progress-clock"></span>
      <progress class="job-progress-bar" hidden></progress>
      <span class="job-progress-detail"></span>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".JobProgress">
      const fmt = (ms) => {
        const s = Math.max(0, Math.floor(ms / 1000));
        return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
      };

      const since = (iso, now) => (iso ? now - new Date(iso).getTime() : 0);

      const formats = () => document.documentElement.dataset.locale || undefined;
      const language = () => document.documentElement.lang || undefined;

      const fill = (template, bindings) =>
        template.replace(/%\{(\w+)\}/g, (match, name) =>
          name in bindings ? String(bindings[name]) : match,
        );

      export default {
        mounted() {
          this.strings = JSON.parse(this.el.dataset.strings ?? "{}");
          this.number = new Intl.NumberFormat(formats());
          this.speed = new Intl.NumberFormat(formats(), {
            minimumFractionDigits: 1,
            maximumFractionDigits: 1,
          });
          this.plurals = new Intl.PluralRules(language());
          this.live = { tokens: null, tps: null, prompt: null };
          this.handleEvent("job_progress", (p) => {
            if (p.id !== this.el.dataset.jobId) return;
            this.live = {
              tokens: p.tokens,
              tps: p.tokens_per_second,
              prompt: p.prompt,
            };
            this.render();
          });
          this.handleEvent("job_queue", ({ positions }) => {
            const n = positions[this.el.dataset.jobId];
            if (n == null) delete this.el.dataset.position;
            else this.el.dataset.position = n;
            this.render();
          });
          // Also re-reads `dataset` each tick, so attribute patches apply whether or not `updated`
          // fires on this `phx-update="ignore"` container.
          this.timer = setInterval(() => this.render(), 1000);
          this.render();
        },
        updated() {
          this.render();
        },
        destroyed() {
          clearInterval(this.timer);
        },
        t(key, bindings = {}) {
          const template = this.strings[key];
          return typeof template === "string" ? fill(template, bindings) : key;
        },
        // A plural template picked by `n`'s CLDR category, falling back to "other".
        tn(key, n, bindings) {
          const forms = this.strings[key] ?? {};
          const template = forms[this.plurals.select(n)] ?? forms.other;
          return template ? fill(template, bindings) : key;
        },
        render() {
          const d = this.el.dataset;
          const phase = this.el.querySelector(".job-progress-phase");
          const clock = this.el.querySelector(".job-progress-clock");
          const bar = this.el.querySelector(".job-progress-bar");
          const detail = this.el.querySelector(".job-progress-detail");
          const now = Date.now();
          bar.hidden = true;

          if (d.status === "queued") {
            phase.textContent = d.position
              ? this.t("queued_at", {
                  queue_position: this.number.format(Number(d.position)),
                })
              : this.t("queued");
            clock.textContent = fmt(since(d.queuedAt, now));
            detail.textContent = "";
            return;
          }

          const elapsed = since(d.startedAt, now);
          clock.textContent = fmt(elapsed);

          if (!d.firstTokenAt) {
            phase.textContent = this.t("reading_prompt");
            const prompt = this.live.prompt;
            const expected = Number(d.expectedMs);

            if (prompt && prompt.total > 0) {
              bar.hidden = false;
              bar.max = prompt.total;
              bar.value = prompt.done;
              detail.textContent = this.tn("prompt_progress", prompt.total, {
                done_tokens: this.number.format(prompt.done),
                total_tokens: this.number.format(prompt.total),
              });
            } else if (expected > 0) {
              bar.hidden = false;
              bar.max = 1;
              bar.value = Math.min(elapsed / expected, 0.95);
              const left = expected - elapsed;
              detail.textContent =
                left > 0 ? this.t("eta", { duration: fmt(left) }) : this.t("overdue");
            } else {
              detail.textContent = "";
            }
            return;
          }

          phase.textContent = this.t("writing");
          const { tokens, tps } = this.live;
          detail.textContent =
            tokens == null
              ? ""
              : this.tn("tokens_written", tokens, {
                  token_count: this.number.format(tokens),
                }) +
                (tps == null
                  ? ""
                  : ` · ${this.t("speed", { speed: this.speed.format(tps) })}`);
        },
      };
    </script>
    """
  end

  defp phase_label(%Job{status: :queued}, nil),
    do: dpgettext("jobs", "status: generation job waiting in the queue", "Queued")

  defp phase_label(%Job{status: :queued}, position) do
    dpgettext(
      "jobs",
      "status: generation job waiting in the queue, with its place in line",
      "Queued #%{queue_position}",
      queue_position: Format.number(position)
    )
  end

  defp phase_label(%Job{first_token_at: nil}, _position),
    do: dpgettext("jobs", "status: model is reading the prompt before it writes", "Reading prompt")

  defp phase_label(%Job{}, _position), do: dpgettext("jobs", "status: model is writing the reply", "Writing")
end
