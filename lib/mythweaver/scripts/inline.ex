max_blocks = 10

defmodule Mythweaver.Scripts.Inline do
  @moduledoc """
  `{! … !}` blocks in a composer message: Lua that runs once when the message is sent.

  `prepare/1` pulls the blocks out of the raw typed text, before Liquid renders, and leaves a
  marker in each block's place, so Lua containing `{{`/`{%` is never touched by Liquid and a
  variable's value can never inject a script. After rendering, `present/2` says which markers
  survived (a block inside a false `{% if %}` branch does not run) and `fill/2` swaps each marker
  for its block's value. The first `!}` after a `{!` closes it; there is no escape. A message holds
  at most #{max_blocks} blocks.
  """

  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.Scripts.Sandbox

  @max_blocks max_blocks

  # Unicode private use: never typed by accident, so the typed source may not contain them. Distinct
  # open and close characters keep a marker from forming across two neighbours (`…1<close>2<open>…`).
  # Not U+E000/U+E001, which `Mythweaver.Sharing.Protected` (and search and import macros) use:
  # `Protected.strip/1` would delete these markers while a message renders.
  @open "\u{E010}"
  @close "\u{E011}"

  @doc """
  Splits `source` into a `template` with a marker per block and the blocks' Lua `scripts`, in
  source order. Every block is syntax-checked; the first error is returned. `:none` when there is
  no `{!`.
  """
  @spec prepare(String.t()) ::
          :none | {:ok, %{template: String.t(), scripts: [String.t()]}} | {:error, String.t()}
  def prepare(source) when is_binary(source) do
    cond do
      not String.contains?(source, "{!") ->
        :none

      reserved = Enum.find([@open, @close], &String.contains?(source, &1)) ->
        <<codepoint::utf8>> = reserved

        {:error,
         dgettext("errors", "the message contains the reserved character U+%{codepoint_hex}",
           codepoint_hex: Integer.to_string(codepoint, 16)
         )}

      true ->
        with {:ok, template, scripts} <- extract(source, 1, [], []),
             :ok <- check(scripts) do
          {:ok, %{template: template, scripts: scripts}}
        end
    end
  end

  defp extract(rest, i, template, scripts) do
    case :binary.match(rest, "{!") do
      :nomatch ->
        {:ok, IO.iodata_to_binary([template, rest]), Enum.reverse(scripts)}

      {_start, 2} when i > @max_blocks ->
        {:error,
         dgettext("errors", "a message may hold at most %{max_scripts} inline scripts",
           max_scripts: Mythweaver.Format.number(@max_blocks)
         )}

      {start, 2} ->
        before = binary_part(rest, 0, start)
        after_open = binary_part(rest, start + 2, byte_size(rest) - start - 2)

        case :binary.match(after_open, "!}") do
          :nomatch ->
            {:error,
             dgettext("errors", "inline script %{script_number} has no closing !}",
               script_number: Mythweaver.Format.number(i)
             )}

          {close, 2} ->
            body = binary_part(after_open, 0, close)
            rest = binary_part(after_open, close + 2, byte_size(after_open) - close - 2)
            extract(rest, i + 1, [template, before, marker(i)], [body | scripts])
        end
    end
  end

  defp check(scripts) do
    scripts
    |> Enum.with_index(1)
    |> Enum.find_value(:ok, fn {body, i} ->
      case Sandbox.parse(body) do
        {:ok, _} ->
          nil

        {:error, errors} ->
          gettext_comment("lua_errors is the Lua parser's own error text, joined with semicolons")

          {:error,
           dgettext("errors", "inline script %{script_number}: %{lua_errors}",
             script_number: Mythweaver.Format.number(i),
             lua_errors: Enum.join(errors, "; ")
           )}
      end
    end)
  end

  @doc "The block indices in `1..count` whose marker still appears in `rendered`, ascending."
  @spec present(String.t(), non_neg_integer()) :: [pos_integer()]
  def present(rendered, count) when is_binary(rendered) and is_integer(count) and count >= 0 do
    Enum.filter(1..count//1, &String.contains?(rendered, marker(&1)))
  end

  @doc """
  Replaces every copy of each block's marker in `rendered` with `values[i]`. A Liquid loop can
  repeat a marker; that block ran once and every copy gets its value.
  """
  @spec fill(String.t(), %{pos_integer() => String.t()}) :: String.t()
  def fill(rendered, values) when is_binary(rendered) and is_map(values) do
    Enum.reduce(values, rendered, fn {i, value}, text -> String.replace(text, marker(i), value) end)
  end

  defp marker(i), do: @open <> Integer.to_string(i) <> @close
end
