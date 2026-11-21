defmodule Mythweaver.Memory.Title do
  @moduledoc """
  Memory entry titles from a profile's `title_format` (scene memories) or
  `consolidation_title_format` (arcs and up).

  Macros: `{{title}}`, `{{scene}}` (`"#a–#b"`), `{{char}}` (the chat's non-player participants),
  `{{chat}}`, `{{present}}` (the scene's speakers), `{{user}}` (the player's name or ""),
  `{{messages}}`, `{{profile}}`, `{{tier}}` (a consolidation's tier name in capitals, `ARC`),
  `{{date}}` and `{{time}}` (UTC). The format's first numbering token (`[000]`, where a label may lead
  it, as in `[ARC 000]`; `(000)`; `{000}`; `#000`; or a bare `000` standing as its own word) takes
  the sequence, zero-padded to its zero count. A format without a token gets no number. Tokens are
  read from the format before macros are substituted, so zeros in a title or a date never take the
  number. Control characters are removed last.
  """

  @macros ~w(title scene char chat present user messages profile tier date time)
  @token ~r/\[(?:[^\[\]\d]*\s)?(0+)\]|\((0+)\)|\{(0+)\}|#(0+)|(?<![\w#])(0+)(?!\w)/

  @doc "`format` with `vars` (atom keys, one per macro, plus `:sequence`) substituted."
  @spec format(String.t(), map()) :: String.t()
  def format(format, vars) do
    now = Map.get_lazy(vars, :now, &DateTime.utc_now/0)

    values =
      vars
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.put_new("date", now |> DateTime.to_date() |> Date.to_iso8601())
      |> Map.put_new("time", now |> DateTime.to_time() |> Calendar.strftime("%H:%M"))

    format
    |> number(Map.get(vars, :sequence))
    |> then(
      &Regex.replace(~r/\{\{\s*(\w+)\s*\}\}/, &1, fn whole, name ->
        if name in @macros, do: to_string(values[name] || ""), else: whole
      end)
    )
    |> then(&Regex.replace(~r/[\x{0}-\x{1F}\x{7F}-\x{9F}]/u, &1, ""))
  end

  defp number(text, nil), do: text

  defp number(text, sequence) do
    Regex.replace(
      @token,
      text,
      fn whole, a, b, c, d, e ->
        zeros = Enum.find([a, b, c, d, e], &(&1 != ""))
        String.replace(whole, zeros, sequence |> Integer.to_string() |> String.pad_leading(byte_size(zeros), "0"))
      end,
      global: false
    )
  end
end
