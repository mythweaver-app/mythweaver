defmodule Mythweaver.Sharing.Protected do
  @moduledoc """
  Placeholder tokens that stand in for protected content inside template state.

  `Mythweaver.Prompts.Builder` gives templates `token/1` instead of a protected value's text
  (`Mythweaver.Sharing.Visibility.protected_for?/2`), so no filter, `contains` or `setvar` can transform, test or
  copy the text. After every template has rendered, `reveal/2` swaps each whole token back for its
  text. The delimiters are private-use code points, which Liquid's case and strip filters leave
  unchanged, and the id matches in any case; a slicing filter can still cut a token, so stray
  delimiters are dropped.

  `scrub/2` is the read-side counterpart: a value the build revealed, found verbatim in text a
  viewer without access is shown (a snapshot, reasoning that quotes the prompt), becomes its label.
  `pairs/1` keeps each value's source (`:site` or `:share`), and `hidden_pairs/2` picks the ones a
  viewer may not read.
  """

  @open "\u{E000}"
  @close "\u{E001}"
  # Case-insensitive: a case filter changes the id's hex digits, never its meaning.
  @token ~r/\x{E000}([0-9a-f-]{36})\x{E001}/iu
  @delimiter ~r/[\x{E000}\x{E001}]/u

  @doc "The placeholder for the entry with `entry_id`."
  @spec token(Ecto.UUID.t()) :: String.t()
  def token(entry_id), do: @open <> entry_id <> @close

  @doc "`text` with every whole token replaced by its entry's text in `protected` (blank if absent)."
  @spec reveal(String.t(), %{Ecto.UUID.t() => String.t()}) :: String.t()
  def reveal(text, protected) when is_binary(text) do
    @token
    |> Regex.replace(text, fn _whole, id -> Map.get(protected, String.downcase(id), "") end)
    |> then(&Regex.replace(@delimiter, &1, ""))
  end

  @doc "`text` with every token, whole or cut, removed."
  @spec strip(String.t()) :: String.t()
  def strip(text), do: reveal(text, %{})

  @doc "The entry ids of the whole tokens in `text`."
  @spec ids(String.t()) :: MapSet.t(Ecto.UUID.t())
  def ids(text) when is_binary(text) do
    @token
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> MapSet.new(&String.downcase/1)
  end

  @doc """
  `value` (a string, or maps and lists holding strings) with each `{secret, label}` pair's secret
  replaced by its label wherever it appears verbatim. Longest secrets go first, so a value that
  contains another is replaced whole; blank secrets are ignored.
  """
  @spec scrub(term(), [{String.t(), String.t()}]) :: term()
  def scrub(value, pairs) do
    pairs =
      pairs
      |> Enum.reject(fn {secret, _label} -> not is_binary(secret) or String.trim(secret) == "" end)
      |> Enum.uniq()
      |> Enum.sort_by(&(-String.length(elem(&1, 0))))

    if pairs == [], do: value, else: do_scrub(value, pairs)
  end

  @typedoc "A protected value with its label and whose rule protects it."
  @type source_pair :: {String.t(), String.t(), :site | :share}

  @doc "`Mythweaver.Prompts.Builder.build/2`'s `protected_values` as `{secret, label, source}` triples."
  @spec pairs([%{label: String.t(), text: String.t(), source: :site | :share}]) :: [source_pair()]
  def pairs(values), do: Enum.map(values, &{&1.text, &1.label, &1.source})

  @doc """
  The `scrub/2` pairs of `pairs` (from `pairs/1`) a viewer may not read: every `:share` one, since a
  share has no admin bypass, and the `:site` ones unless `view_hidden?` (`site.hidden.view`).
  """
  @spec hidden_pairs([source_pair()], boolean()) :: [{String.t(), String.t()}]
  def hidden_pairs(pairs, view_hidden?) do
    for {secret, label, source} <- pairs, source == :share or not view_hidden?, do: {secret, label}
  end

  defp do_scrub(text, pairs) when is_binary(text),
    do: Enum.reduce(pairs, text, fn {secret, label}, acc -> String.replace(acc, secret, label) end)

  defp do_scrub(map, pairs) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {k, do_scrub(v, pairs)} end)

  defp do_scrub(list, pairs) when is_list(list), do: Enum.map(list, &do_scrub(&1, pairs))
  defp do_scrub(other, _pairs), do: other
end
