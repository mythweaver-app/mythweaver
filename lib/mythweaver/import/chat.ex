defmodule Mythweaver.Import.Chat do
  @moduledoc """
  Parses a SillyTavern `.jsonl` chat: an optional header line, then one message per line.

  Speakers are keyed by trimmed name alone; every speaker (the player included) is just a
  character to map. ST's `is_user` only picks the default player. Message text is stored as
  rendered, so it is never macro-converted. The header's `chat_metadata.mythweaver` (a Mythweaver
  export's bundle) is passed on as `embedded` for `Mythweaver.Import.Embedded.resolve/1`.
  """

  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.Format
  alias Mythweaver.Import.Embedded
  alias Mythweaver.Import.Text

  @type body :: %{content: String.t(), reasoning: String.t() | nil}

  @type message :: %{
          speaker: non_neg_integer(),
          inserted_at: DateTime.t(),
          visible_to_ai: boolean(),
          bodies: [body()],
          active: non_neg_integer()
        }

  @type speaker :: %{
          key: non_neg_integer(),
          name: String.t(),
          narrator?: boolean(),
          count: pos_integer()
        }

  @type t :: %{
          kind: :chat,
          name: String.t(),
          player_name: String.t() | nil,
          speakers: [speaker()],
          messages: [message()],
          warnings: [String.t()],
          unconverted: [String.t()],
          embedded: map() | nil
        }

  @months %{
    "jan" => 1,
    "feb" => 2,
    "mar" => 3,
    "apr" => 4,
    "may" => 5,
    "jun" => 6,
    "jul" => 7,
    "aug" => 8,
    "sep" => 9,
    "oct" => 10,
    "nov" => 11,
    "dec" => 12
  }

  @spec parse(binary(), String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(bytes, filename) do
    with {:ok, objects} <- decode_lines(bytes) do
      {header, messages} = split_header(objects)

      if messages == [] do
        {:error, dgettext("import_export", "This chat has no messages.")}
      else
        {:ok, build(header, messages, Text.stem(filename))}
      end
    end
  end

  defp decode_lines(bytes) do
    bytes
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reject(fn {line, _n} -> String.trim(line) == "" end)
    |> Enum.reduce_while({:ok, []}, fn {line, n}, {:ok, acc} ->
      case Jason.decode(line) do
        {:ok, object} when is_map(object) ->
          {:cont, {:ok, [object | acc]}}

        _bad ->
          {:halt,
           {:error, dgettext("import_export", "Line %{line_number} isn't valid JSON.", line_number: Format.number(n))}}
      end
    end)
    |> case do
      {:ok, objects} -> {:ok, Enum.reverse(objects)}
      error -> error
    end
  end

  defp split_header([first | rest] = all) do
    if (Map.has_key?(first, "user_name") or Map.has_key?(first, "chat_metadata")) and
         not Map.has_key?(first, "mes") do
      {first, rest}
    else
      {%{}, all}
    end
  end

  defp split_header([]), do: {%{}, []}

  defp build(header, raw_messages, name) do
    names = Enum.map(raw_messages, &speaker_name/1)
    unique_names = Enum.uniq(names)
    keys = unique_names |> Enum.with_index() |> Map.new()
    named = Enum.zip(raw_messages, names)

    fallback = timestamp(header["create_date"]) || usec(DateTime.utc_now())

    {messages, _prev} =
      Enum.map_reduce(named, nil, fn {raw, speaker}, prev ->
        time = timestamp(raw["send_date"]) || prev || fallback
        {message(raw, Map.fetch!(keys, speaker), time), time}
      end)

    by_speaker = Enum.group_by(named, &elem(&1, 1), &elem(&1, 0))

    speakers =
      for speaker <- unique_names do
        own = Map.fetch!(by_speaker, speaker)

        %{
          key: Map.fetch!(keys, speaker),
          name: speaker,
          narrator?: Enum.any?(own, &(Text.map(&1["extra"])["type"] == "narrator")),
          count: length(own)
        }
      end

    images = Enum.count(raw_messages, &image?/1)

    warnings =
      if images > 0,
        do: [
          dpngettext(
            "import_export",
            "status: import warning, a chat's images were not imported",
            "%{image_count} image wasn't imported.",
            "%{image_count} images weren't imported.",
            images,
            image_count: Format.number(images)
          )
        ],
        else: []

    %{
      kind: :chat,
      name: name,
      player_name: player_name(header, raw_messages),
      speakers: speakers,
      messages: messages,
      warnings: warnings,
      unconverted: [],
      embedded: Embedded.extract(header["chat_metadata"])
    }
  end

  defp speaker_name(raw) do
    case Text.string(raw["name"]) do
      nil -> "Unknown"
      name -> if String.trim(name) == "", do: "Unknown", else: String.trim(name)
    end
  end

  defp message(raw, key, time) do
    bodies = bodies(raw)
    active = active(raw, bodies)
    extra = Text.map(raw["extra"])
    swipe_info = if is_list(raw["swipe_info"]), do: raw["swipe_info"], else: []

    bodies =
      Enum.with_index(bodies, fn content, index ->
        reasoning =
          if index == active do
            Text.string(extra["reasoning"])
          else
            swipe_info
            |> Enum.at(index)
            |> Text.map()
            |> Map.get("extra")
            |> Text.map()
            |> Map.get("reasoning")
            |> Text.string()
          end

        %{content: content, reasoning: reasoning}
      end)

    %{
      speaker: key,
      inserted_at: time,
      visible_to_ai: raw["is_system"] != true,
      bodies: bodies,
      active: active
    }
  end

  defp bodies(%{"swipes" => [_ | _] = swipes} = raw) do
    if Enum.all?(swipes, &is_binary/1), do: swipes, else: [Text.string(raw["mes"]) || ""]
  end

  defp bodies(raw), do: [Text.string(raw["mes"]) || ""]

  defp active(raw, bodies) do
    count = length(bodies)

    case raw["swipe_id"] do
      id when is_integer(id) and id >= 0 and id < count -> id
      _other -> Enum.find_index(bodies, &(&1 == raw["mes"])) || count - 1
    end
  end

  defp image?(raw) do
    extra = Text.map(raw["extra"])
    Enum.any?(["image", "inline_image", "media"], &(extra[&1] not in [nil, false, "", []]))
  end

  defp player_name(header, raw_messages) do
    if Text.blank?(header["user_name"]) do
      user_names = for %{"is_user" => true} = raw <- raw_messages, do: speaker_name(raw)

      case user_names do
        [] ->
          nil

        _some ->
          counts = Enum.frequencies(user_names)
          user_names |> Enum.uniq() |> Enum.max_by(&counts[&1])
      end
    else
      String.trim(header["user_name"])
    end
  end

  @doc """
  Parses a `send_date` / `create_date` into a UTC `DateTime` with microsecond precision 6, or
  `nil` when unrecognized. Accepts Unix milliseconds (integer or digit string), ISO 8601 (no offset
  means UTC), ST's `2024-1-5 @14h 30m 12s 345ms`, and `January 5, 2024 2:30pm`.
  """
  @spec timestamp(term()) :: DateTime.t() | nil
  def timestamp(value) when is_integer(value), do: from_ms(value)

  def timestamp(value) when is_binary(value) do
    value = String.trim(value)

    if value =~ ~r/\A\d+\z/ do
      from_ms(String.to_integer(value))
    else
      iso(value) || st_format(value) || human(value)
    end
  end

  def timestamp(_value), do: nil

  defp from_ms(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, dt} -> usec(dt)
      {:error, _} -> nil
    end
  end

  defp iso(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        usec(dt)

      {:error, _} ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive} -> naive |> DateTime.from_naive!("Etc/UTC") |> usec()
          {:error, _} -> nil
        end
    end
  end

  defp st_format(value) do
    case Regex.run(
           ~r/(\d{4})-(\d{1,2})-(\d{1,2}) ?@(\d{1,2})h ?(\d{1,2})m ?(\d{1,2})s(?: ?(\d{1,3})ms)?/,
           value,
           capture: :all_but_first
         ) do
      [y, mo, d, h, mi, s | ms] ->
        [y, mo, d, h, mi, s] = Enum.map([y, mo, d, h, mi, s], &String.to_integer/1)
        naive(y, mo, d, h, mi, s, millis(ms) * 1000)

      nil ->
        nil
    end
  end

  defp millis([digits]) when digits != "", do: String.to_integer(digits)
  defp millis(_none), do: 0

  defp human(value) do
    case Regex.run(~r/([A-Za-z]+)\s(\d{1,2}),\s(\d{4})\s(\d{1,2}):(\d{1,2})(am|pm)/i, value, capture: :all_but_first) do
      [month, d, y, h, mi, meridiem] ->
        month = Map.get(@months, month |> String.downcase() |> String.slice(0, 3))
        h = String.to_integer(h)

        if month && h in 1..12 do
          h = rem(h, 12) + if(String.downcase(meridiem) == "pm", do: 12, else: 0)
          naive(String.to_integer(y), month, String.to_integer(d), h, String.to_integer(mi), 0, 0)
        end

      nil ->
        nil
    end
  end

  defp naive(y, mo, d, h, mi, s, us) do
    case NaiveDateTime.new(y, mo, d, h, mi, s, {us, 6}) do
      {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
      {:error, _} -> nil
    end
  end

  defp usec(%DateTime{microsecond: {us, _precision}} = dt), do: %{dt | microsecond: {us, 6}}
end
