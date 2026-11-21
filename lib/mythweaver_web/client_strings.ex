defmodule MythweaverWeb.ClientStrings do
  @moduledoc """
  UI text rendered by JavaScript, translated on the server.

  `catalog/0` is encoded into `<body data-client-strings>` by the root layout and read by
  `assets/js/i18n.ts` (`t/2`, `tn/3`). `job_progress/0` goes on the job progress hook's own element,
  since colocated hooks cannot import app modules. A value is a template with `%{name}`
  placeholders, or for a plural a map from CLDR plural category (`"one"`, `"few"`, `"other"`, …)
  to one: each placeholder is bound to itself here, so the template survives translation and the
  client fills it in.
  """
  use Gettext, backend: Mythweaver.Gettext

  alias Localize.Number.PluralRule.Cardinal

  @doc "Strings for `assets/js/**`, keyed as `i18n.ts`'s callers name them."
  @spec catalog() :: %{String.t() => String.t() | %{String.t() => String.t()}}
  def catalog do
    %{
      "unsaved_changes" => unsaved_changes(),
      "tag_remove" =>
        dpgettext("tags", "aria label: button that removes this tag from the field", "Remove %{tag_name}",
          tag_name: "%{tag_name}"
        ),
      "chart_tokens" =>
        plural(
          &dpngettext(
            "ai",
            "unit: exact token total in a usage chart tooltip",
            "%{token_count} token",
            "%{token_count} tokens",
            &1,
            token_count: "%{token_count}"
          )
        ),
      "chart_runs" =>
        plural(
          &dpngettext(
            "ai",
            "unit: exact run total in a usage chart tooltip",
            "%{run_count} run",
            "%{run_count} runs",
            &1,
            run_count: "%{run_count}"
          )
        ),
      "chart_tokens_per_second" =>
        dpgettext("ai", "unit: generation speed in a usage chart tooltip", "%{speed} tokens/s", speed: "%{speed}"),
      "chart_median" => dpgettext("ai", "column header: median value row in a usage chart tooltip", "Median"),
      "chart_95th_percentile" =>
        dpgettext(
          "ai",
          "tooltip: 95th percentile of a usage chart range; the value is a formatted amount such as 1.2 s",
          "95th percentile %{percentile_value}",
          percentile_value: "%{percentile_value}"
        ),
      "chart_total" => dpgettext("ai", "column header: sum row in a usage chart tooltip", "Total")
    }
  end

  @doc "Strings for the job progress hook (`MythweaverWeb.CoreComponents.JobProgress`)."
  @spec job_progress() :: %{String.t() => String.t() | %{String.t() => String.t()}}
  def job_progress do
    %{
      "queued" => dpgettext("jobs", "status: generation job waiting in the queue", "Queued"),
      "queued_at" =>
        dpgettext(
          "jobs",
          "status: generation job waiting in the queue, with its place in line",
          "Queued #%{queue_position}",
          queue_position: "%{queue_position}"
        ),
      "reading_prompt" => dpgettext("jobs", "status: model is reading the prompt before it writes", "Reading prompt"),
      "writing" => dpgettext("jobs", "status: model is writing the reply", "Writing"),
      "prompt_progress" =>
        plural(
          &dpngettext(
            "jobs",
            "progress: prompt tokens read so far out of the total",
            "%{done_tokens} / %{total_tokens} prompt token",
            "%{done_tokens} / %{total_tokens} prompt tokens",
            &1,
            done_tokens: "%{done_tokens}",
            total_tokens: "%{total_tokens}"
          )
        ),
      "eta" =>
        dpgettext(
          "jobs",
          "progress: estimated time left while the prompt is read; the duration is a short clock like 1:05",
          "~%{duration} left (est.)",
          duration: "%{duration}"
        ),
      "overdue" =>
        dpgettext("jobs", "progress: the prompt is taking longer than the estimate", "longer than usual (est.)"),
      "tokens_written" =>
        plural(
          &dpngettext("jobs", "progress: tokens written so far", "~%{token_count} token", "~%{token_count} tokens", &1,
            token_count: "%{token_count}"
          )
        ),
      "speed" => dpgettext("jobs", "unit: generation speed", "%{speed} tok/s", speed: "%{speed}")
    }
  end

  defp unsaved_changes do
    gettext_comment("Confirm dialog shown before leaving or closing a form that has unsaved edits.")
    gettext("You have unsaved changes. Discard them?")
  end

  # One template per CLDR plural category of the UI language (plurals follow the text, not the
  # regional format), from the first number in 0..200 that falls in it. Gettext picks the form by
  # that number, so each category gets its own. Some languages (pl) put only fractions in "other",
  # which Gettext's whole-number forms don't cover; the counts shown are whole, so there "other" is
  # only `tn`'s fallback and takes 100's form.
  defp plural(fun) do
    locale = Mythweaver.Locale.language_tag()

    0..200
    |> Enum.reduce(%{}, fn n, acc ->
      category = Cardinal.plural_rule(n, locale)
      Map.put_new_lazy(acc, Atom.to_string(category), fn -> fun.(n) end)
    end)
    |> Map.put_new_lazy("other", fn -> fun.(100) end)
  end
end
