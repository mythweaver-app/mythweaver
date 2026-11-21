defmodule Mythweaver.Format do
  @moduledoc """
  Numbers, money, durations, sizes, dates and lists as the viewer reads them: CLDR formats in the
  current Localize locale (`Mythweaver.Locale`). Every call passes the locale explicitly, since some
  Localize formatters default to `:en` rather than the process locale. Instants shown in the UI use
  `<.local_time>` instead, which formats in the browser's time zone.

  Bind the result into a translated sentence as a placeholder; never interpolate a raw number.
  """

  @doc "`1234.5` → `\"1,234.5\"` in en. `opts` pass to `Localize.Number.to_string!/2` (`fractional_digits`, …)."
  @spec number(number() | Decimal.t(), keyword()) :: String.t()
  def number(n, opts \\ []), do: Localize.Number.to_string!(n, Keyword.put(opts, :locale, locale()))

  @doc "A fraction as a percentage: `0.42` → `\"42%\"` in en."
  @spec percent(number() | Decimal.t(), keyword()) :: String.t()
  def percent(fraction, opts \\ []), do: number(fraction, Keyword.put(opts, :format, :percent))

  @doc """
  A USD amount: `1.5` → `\"$1.50\"` in en; nil → `\"—\"`; more than zero but under a cent →
  `\"<$0.01\"`. `opts` may carry `rounding_mode` (chat costs round up, `:ceiling`).
  """
  @spec money(number() | Decimal.t() | nil, keyword()) :: String.t()
  def money(amount, opts \\ [])
  def money(nil, _opts), do: "—"

  def money(amount, opts) do
    if positive?(amount) and below_cent?(amount),
      do: "<" <> money(0.01),
      else: number(amount, Keyword.put(opts, :currency, :USD))
  end

  @doc "Milliseconds as seconds: `1234` → `\"1.2s\"` in en. `opts`: `format` (`:narrow`), `fractional_digits` (1)."
  @spec seconds(number(), keyword()) :: String.t()
  def seconds(ms, opts \\ []) do
    (ms / 1000)
    |> Localize.Unit.new!("second")
    |> Localize.Unit.to_string!(
      format: opts[:format] || :narrow,
      fractional_digits: opts[:fractional_digits] || 1,
      locale: locale()
    )
  end

  @doc ~s{A duration in milliseconds: seconds under a minute (`"4.2s"`), else `"2m 5s"` in en.}
  @spec duration_ms(number()) :: String.t()
  def duration_ms(ms) when ms < 60_000, do: seconds(ms, fractional_digits: 1)

  def duration_ms(ms) do
    ms
    |> trunc()
    |> div(1000)
    |> Localize.Duration.new_from_seconds()
    |> Localize.Duration.to_string!(format: :narrow, locale: locale())
  end

  @doc "A byte count in the largest fitting unit: `2_400_000` → `\"2.4 MB\"` in en."
  @spec bytes(non_neg_integer()) :: String.t()
  def bytes(n) do
    n
    |> Localize.Unit.new!("byte")
    |> Localize.Unit.to_string!(humanize: true, format: :short, locale: locale())
  end

  @doc "Megabytes: `20` → `\"20 MB\"` in en."
  @spec megabytes(number()) :: String.t()
  def megabytes(n) do
    n
    |> Localize.Unit.new!("megabyte")
    |> Localize.Unit.to_string!(format: :short, locale: locale())
  end

  @doc "A date: `~D[2026-01-05]` → `\"Jan 5, 2026\"` in en."
  @spec date(Date.t()) :: String.t()
  def date(%Date{} = d), do: Localize.Date.to_string!(d, format: :medium, locale: locale())

  @doc """
  An instant in UTC with its zone named, for text built on the server without the viewer's time
  zone (a ban refusal): `\"Jan 5, 2026, 3:04 PM UTC\"` in en. UI instants use `<.local_time>`.
  """
  @spec datetime_utc(DateTime.t()) :: String.t()
  def datetime_utc(%DateTime{} = dt) do
    dt
    |> DateTime.shift_zone!("Etc/UTC")
    |> Localize.DateTime.to_string!(format: :yMMMdjmz, locale: locale())
  end

  @doc ~s(Item names as a conjunction list: `["a", "b", "c"]` → `"a, b, and c"` in en.)
  @spec list([String.t()]) :: String.t()
  def list(items), do: Localize.List.to_string!(items, locale: locale())

  defp locale, do: Localize.get_locale()

  defp positive?(%Decimal{} = d), do: Decimal.gt?(d, 0)
  defp positive?(n), do: n > 0

  defp below_cent?(%Decimal{} = d), do: Decimal.lt?(d, Decimal.new("0.01"))
  defp below_cent?(n), do: n < 0.01
end
