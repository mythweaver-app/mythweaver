defmodule MythweaverWeb.CoreComponents.LocalTime do
  @moduledoc """
  A timestamp in the reader's own timezone and locale: `local_time/1` renders a `<time>` carrying
  the UTC ISO-8601 value, and the `.LocalTime` hook rewrites its text with `Intl.DateTimeFormat`
  in the page's regional format (`<html data-locale>`) on mount and on every patch. The full date, time and zone name go in
  the `title` tooltip.

  The server text is a UTC fallback in the viewer's locale (Localize, with the zone named, so it
  never passes for local time). It is what
  LiveViewTest sees, and it stays hidden (its width kept, so nothing shifts) until the hook has
  run. The hook reads the `datetime` attribute, never the text, so a localized value is not
  re-parsed. The root is the `<time>` itself; `class` passes through `:rest` for a caller's layout.
  """

  use Phoenix.Component

  attr :id, :string, required: true, doc: "unique per element; `phx-hook` requires it"
  attr :at, DateTime, required: true

  attr :format, :atom,
    values: [:minutes, :seconds, :full],
    default: :minutes,
    doc: "`:minutes` month, day and time; `:seconds` adds seconds; `:full` adds the year too"

  attr :rest, :global

  def local_time(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      time:scope:not([data-localized]) {
        visibility: hidden;
      }
    </style>

    <time
      id={@id}
      phx-hook=".LocalTime"
      datetime={DateTime.to_iso8601(@at)}
      data-format={@format}
      {@rest}
    >
      {fallback(@at, @format)}
    </time>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".LocalTime">
      const OPTIONS = {
        minutes: {
          month: "short",
          day: "numeric",
          hour: "numeric",
          minute: "2-digit",
        },
        seconds: {
          month: "short",
          day: "numeric",
          hour: "numeric",
          minute: "2-digit",
          second: "2-digit",
        },
        full: {
          year: "numeric",
          month: "short",
          day: "numeric",
          hour: "numeric",
          minute: "2-digit",
          second: "2-digit",
        },
      };

      export default {
        mounted() {
          this.updated();
        },
        // A patch resets the text to the UTC fallback and drops `data-localized`; this runs before
        // paint and restores both.
        updated() {
          const at = new Date(this.el.dateTime);
          // Leave the UTC fallback visible rather than an "Invalid Date".
          if (Number.isNaN(at.getTime())) {
            this.el.dataset.localized = "";
            return;
          }
          const options = OPTIONS[this.el.dataset.format] ?? OPTIONS.minutes;
          // The regional format, `<html data-locale>` (`Mythweaver.Locale`), so dates match the
          // server-formatted numbers; it also picks 12h or 24h.
          const locale = document.documentElement.dataset.locale || undefined;
          this.el.textContent = new Intl.DateTimeFormat(locale, options).format(at);
          this.el.title = new Intl.DateTimeFormat(locale, {
            dateStyle: "full",
            timeStyle: "long",
          }).format(at);
          this.el.dataset.localized = "";
        },
      };
    </script>
    """
  end

  # In the viewer's locale; the `z` keeps "UTC" visible.
  defp fallback(at, format) do
    at
    |> DateTime.shift_zone!("Etc/UTC")
    |> Localize.DateTime.to_string!(format: skeleton(format), locale: Localize.get_locale())
  end

  defp skeleton(:minutes), do: :MMMdjmz
  defp skeleton(:seconds), do: :MMMdjmsz
  defp skeleton(:full), do: :yMMMdjmsz
end
