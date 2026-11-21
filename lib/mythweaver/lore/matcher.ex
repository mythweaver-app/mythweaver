defmodule Mythweaver.Lore.Matcher do
  @moduledoc """
  Keyword matching for lore entries: literal and `/regex/flags` keywords against a scan-window
  haystack. Pure: no Repo access, no state.

  A key is a regex only in SillyTavern's shape: `/source/flags` with JavaScript's flags
  (`gimsuy`) and no unescaped `/` inside. `g` and `y` mean nothing to a match test and are dropped;
  `i`, `m`, `s` and `u` mean the same in PCRE. A slash inside a regex key must be escaped (`\\/`), as
  in SillyTavern; anything else (`/r/roleplay`, `/x/v`, `/x/1`) is a literal. A key in that shape
  whose source doesn't compile (`/(dragon/i`) fails `LoreEntry` validation.

  Whole-word matching puts a boundary around single-word literals. With `boundary: :ascii` (the
  default, SillyTavern's) every character outside `[A-Za-z0-9_]` ends a word, so Japanese or Chinese
  keys match inside sentences; `:unicode` uses Unicode word characters.

  Vector (semantic) activation lives in `Mythweaver.Lore.Embeddings` and `Mythweaver.Lore.Activation`'s vector gate.
  """

  @regex_keyword ~r{\A/((?:\\.|[^\\/])+)/([gimsuy]*)\z}s

  @doc "Compiles a keyword into `{:regex, Regex.t()}` or `{:literal, String.t()}`."
  @spec compile(String.t(), keyword()) :: {:regex, Regex.t()} | {:literal, String.t()}
  def compile(keyword, opts) do
    case parse_regex(keyword) do
      {:ok, regex} -> {:regex, regex}
      # Invalid regexes are rejected by `LoreEntry`'s changeset at write time, so falling back to
      # a literal here is only a safety net.
      {:error, _reason} -> {:literal, keyword}
      :literal -> compile_literal(keyword, opts)
    end
  end

  @doc """
  Parses a `/source/flags` keyword. `:literal` when `keyword` is not in that form; otherwise the
  compiled regex, or the compile error. The flags written in the keyword override both
  `case_sensitive` and `whole_words`.
  """
  @spec parse_regex(String.t()) :: {:ok, Regex.t()} | {:error, term()} | :literal
  def parse_regex(keyword) do
    case Regex.run(@regex_keyword, keyword, capture: :all_but_first) do
      [source, flags] -> Regex.compile(source, String.replace(flags, ["g", "y"], ""))
      nil -> :literal
    end
  end

  @doc "Whether `keyword` matches `haystack`. A caller matching many haystacks compiles once instead."
  @spec match?(String.t(), String.t(), keyword()) :: boolean()
  def match?(haystack, keyword, opts) do
    case_sensitive? = Keyword.get(opts, :case_sensitive, false)

    case compile(keyword, opts) do
      {:literal, _} = literal when not case_sensitive? ->
        compiled_match?(literal, haystack, String.downcase(haystack), false)

      compiled ->
        compiled_match?(compiled, haystack, haystack, case_sensitive?)
    end
  end

  @doc """
  Whether a `compile/2` result matches `haystack`. `{:literal, _}` carries no case-sensitivity
  setting, so `case_sensitive?` applies it; a case-insensitive literal compares against `lowered`
  (`String.downcase(haystack)`), which a caller matching many keywords computes once.
  """
  @spec compiled_match?({:regex, Regex.t()} | {:literal, String.t()}, String.t(), String.t(), boolean()) ::
          boolean()
  def compiled_match?({:regex, regex}, haystack, _lowered, _case_sensitive?), do: Regex.match?(regex, haystack)
  def compiled_match?({:literal, literal}, haystack, _lowered, true), do: String.contains?(haystack, literal)

  def compiled_match?({:literal, literal}, _haystack, lowered, false),
    do: String.contains?(lowered, String.downcase(literal))

  # Whole-word matching of a single-word keyword is a boundary regex that depends only on the
  # keyword and the opts, so it is built once here and returned as `{:regex, _}`; a caller may
  # compile once and match many haystacks. `{:literal, _}` is returned only when the comparison
  # really is `String.contains?/2`: multi-word keys skip boundary logic (same as upstream
  # SillyTavern), as does `whole_words: false`.
  defp compile_literal(keyword, opts) do
    if Keyword.get(opts, :whole_words, true) and not multi_word?(keyword) do
      # Flags rather than pre-downcasing: UTF-8 mode and Unicode case folding.
      flags = if Keyword.get(opts, :case_sensitive, false), do: "u", else: "iu"

      boundary =
        case Keyword.get(opts, :boundary, :ascii) do
          :ascii -> "[^A-Za-z0-9_]"
          :unicode -> "\\W"
        end

      {:regex, Regex.compile!("(?:^|#{boundary})" <> Regex.escape(keyword) <> "(?:$|#{boundary})", flags)}
    else
      {:literal, keyword}
    end
  end

  defp multi_word?(keyword), do: Regex.match?(~r/\s/u, keyword)
end
