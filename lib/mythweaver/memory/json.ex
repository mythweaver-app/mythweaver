defmodule Mythweaver.Memory.JSON do
  @moduledoc """
  Tolerant JSON for model replies. Models wrap JSON in prose, code fences and `<think>` blocks, and
  leave comments and trailing commas in it; `decode/1` digs the object out and repairs those.

  `memory/1` and `consolidation/1` validate a decoded map against the memory and consolidation
  reply contracts.
  """

  @doc """
  The first JSON object in `text`. Candidates, in order: every fenced block's body, the first
  balanced `{…}`, the whole text. Each is stripped of comments and trailing commas before decoding.
  """
  @spec decode(String.t() | nil) :: {:ok, map()} | {:error, :unparseable}
  def decode(text) when is_binary(text) do
    text = clean(text)

    Enum.find_value(candidates(text), {:error, :unparseable}, fn candidate ->
      candidate
      |> repair()
      |> Jason.decode()
      |> case do
        {:ok, %{} = map} -> {:ok, map}
        _other -> nil
      end
    end)
  end

  def decode(_text), do: {:error, :unparseable}

  @doc """
  A scene memory: `title` and `content` non-blank strings, `keywords` a list or a comma string
  (required, as STMB requires it; it may be empty). A reply whose keywords are missing or not a
  list is invalid, so the one repair retry asks again rather than saving a memory nothing activates.
  """
  @spec memory(map()) :: {:ok, %{String.t() => term()}} | {:error, :invalid}
  def memory(%{} = map) do
    with {:ok, title} <- text(map["title"]),
         {:ok, content} <- text(map["content"]),
         {:ok, keywords} <- keywords_field(map["keywords"]) do
      {:ok, %{"title" => title, "content" => content, "keywords" => keywords}}
    end
  end

  def memory(_other), do: {:error, :invalid}

  @doc """
  A consolidation: `summaries` a non-empty list of maps, each with `title`, `summary`, `keywords` and
  `member_ids`. `unassigned` carries `unassigned_items` when it is a list of maps.
  """
  @spec consolidation(map()) :: {:ok, %{String.t() => list()}} | {:error, :invalid}
  def consolidation(%{"summaries" => [_ | _] = summaries} = map) do
    summaries
    |> Enum.reduce_while([], fn summary, acc ->
      case summary(summary) do
        {:ok, summary} -> {:cont, [summary | acc]}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:error, _reason} = error ->
        error

      summaries ->
        unassigned = map |> Map.get("unassigned_items") |> List.wrap() |> Enum.filter(&is_map/1)
        {:ok, %{"summaries" => Enum.reverse(summaries), "unassigned" => unassigned}}
    end
  end

  def consolidation(_other), do: {:error, :invalid}

  @doc """
  A Memory Assistance clip review: a map of clip uid to suggestion text. Entries whose value is not
  a string are dropped.
  """
  @spec clip_review(term()) :: {:ok, %{String.t() => String.t()}} | {:error, :invalid}
  def clip_review(%{} = map), do: {:ok, for({uid, text} <- map, is_binary(text), into: %{}, do: {uid, text})}
  def clip_review(_other), do: {:error, :invalid}

  @doc """
  Memory Assistance topic suggestions: exactly one key, `"topics"`, holding a list of
  `%{"topic", "keywords"}`. Items without a non-blank topic are dropped, empty keywords become
  `[topic]`, and topics matching (case-insensitively) one of `existing` or an earlier item are
  dropped. At most 5 are kept.
  """
  @spec clip_suggestions(term(), [String.t()]) :: {:ok, [map()]} | {:error, :invalid}
  def clip_suggestions(map, existing \\ [])

  def clip_suggestions(%{"topics" => topics} = map, existing) when is_list(topics) and map_size(map) == 1 do
    seen = MapSet.new(existing, &String.downcase(String.trim(&1)))

    {kept, _seen} =
      Enum.reduce(topics, {[], seen}, fn item, {kept, seen} ->
        with %{} <- item,
             {:ok, topic} <- text(item["topic"]),
             key = String.downcase(topic),
             false <- MapSet.member?(seen, key) do
          keywords = with [] <- keywords(item["keywords"]), do: [topic]
          {[%{"topic" => topic, "keywords" => keywords} | kept], MapSet.put(seen, key)}
        else
          _skip -> {kept, seen}
        end
      end)

    {:ok, kept |> Enum.reverse() |> Enum.take(5)}
  end

  def clip_suggestions(_other, _existing), do: {:error, :invalid}

  defp summary(%{"member_ids" => ids} = summary) when is_list(ids) do
    with {:ok, title} <- text(summary["title"]),
         {:ok, text} <- text(summary["summary"]) do
      {:ok,
       %{
         "title" => title,
         "summary" => text,
         "keywords" => keywords(summary["keywords"]),
         "member_ids" => Enum.map(ids, &to_string/1)
       }}
    end
  end

  defp summary(_other), do: {:error, :invalid}

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :invalid}
      text -> {:ok, text}
    end
  end

  defp text(_value), do: {:error, :invalid}

  defp keywords_field(value) when is_list(value) or is_binary(value), do: {:ok, keywords(value)}
  defp keywords_field(_value), do: {:error, :invalid}

  @doc """
  A keyword list from a model reply or a form: a list (a chip input's, empty entries dropped) or a
  comma-separated string; each keyword trimmed, blanks dropped. Anything else is `[]`.
  """
  @spec keywords(term()) :: [String.t()]
  def keywords(list) when is_list(list),
    do: list |> Enum.filter(&is_binary/1) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  def keywords(text) when is_binary(text), do: text |> String.split(",") |> keywords()
  def keywords(_other), do: []

  ## Cleaning

  defp clean(text) do
    text = Regex.replace(~r/<think>.*?<\/think>/s, text, "")

    text
    |> String.replace_prefix("\uFEFF", "")
    |> String.replace("\r\n", "\n")
    |> then(&Regex.replace(~r/[\x00-\x08\x0B-\x1F\x7F]/, &1, ""))
  end

  defp candidates(text) do
    fenced = ~r/```[A-Za-z]*[ \t]*\n?(.*?)```/s |> Regex.scan(text, capture: :all_but_first) |> List.flatten()
    fenced ++ List.wrap(balanced(text)) ++ [text]
  end

  # The first `{` through its matching `}`, braces inside strings ignored; nil when unbalanced.
  defp balanced(text) do
    case :binary.match(text, "{") do
      {start, _} ->
        rest = binary_part(text, start, byte_size(text) - start)

        case scan(rest, 0, 0, false) do
          nil -> nil
          length -> binary_part(rest, 0, length)
        end

      :nomatch ->
        nil
    end
  end

  defp scan(<<>>, _at, _depth, _string?), do: nil
  defp scan(<<"\\", _c, rest::binary>>, at, depth, true), do: scan(rest, at + 2, depth, true)
  defp scan(<<"\"", rest::binary>>, at, depth, string?), do: scan(rest, at + 1, depth, not string?)
  defp scan(<<"{", rest::binary>>, at, depth, false), do: scan(rest, at + 1, depth + 1, false)
  defp scan(<<"}", _rest::binary>>, at, 1, false), do: at + 1
  defp scan(<<"}", rest::binary>>, at, depth, false), do: scan(rest, at + 1, depth - 1, false)
  defp scan(<<_c, rest::binary>>, at, depth, string?), do: scan(rest, at + 1, depth, string?)

  ## Repair: comments and trailing commas outside strings

  defp repair(text), do: text |> repair([]) |> Enum.reverse() |> IO.iodata_to_binary()

  defp repair(<<>>, acc), do: acc
  defp repair(<<"\"", rest::binary>>, acc), do: string(rest, ["\"" | acc])

  defp repair(<<"//", rest::binary>>, acc) do
    case :binary.split(rest, "\n") do
      [_comment, rest] -> repair(rest, ["\n" | acc])
      [_comment] -> acc
    end
  end

  defp repair(<<"/*", rest::binary>>, acc) do
    case :binary.split(rest, "*/") do
      [_comment, rest] -> repair(rest, acc)
      [_comment] -> acc
    end
  end

  defp repair(<<",", rest::binary>>, acc) do
    if String.starts_with?(String.trim_leading(rest), ["}", "]"]),
      do: repair(rest, acc),
      else: repair(rest, ["," | acc])
  end

  defp repair(<<c, rest::binary>>, acc), do: repair(rest, [c | acc])

  defp string(<<>>, acc), do: acc
  defp string(<<"\\", c, rest::binary>>, acc), do: string(rest, [c, "\\" | acc])
  defp string(<<"\"", rest::binary>>, acc), do: repair(rest, ["\"" | acc])
  defp string(<<c, rest::binary>>, acc), do: string(rest, [c | acc])
end
