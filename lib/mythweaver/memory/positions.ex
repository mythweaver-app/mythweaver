defmodule Mythweaver.Memory.Positions do
  @moduledoc """
  Moves the message positions memory has stored when a split renumbers a chat's transcript.

  Splitting the message at `p` into `1 + d` pieces moves every later message up by `d`. A stored range
  *start* moves when it is `> p`; a range *end* (or a "processed through" mark) moves when it is
  `>= p`, so a range that ended at `p` still covers every piece of `p`.

  Job `label`s ("Memory #3–#5") are historical text and are left alone.
  """

  import Ecto.Query, warn: false

  alias Mythweaver.Jobs.Job
  alias Mythweaver.Memory.ChatSettings
  alias Mythweaver.Memory.Record
  alias Mythweaver.Memory.SidePromptCheckpoint
  alias Mythweaver.Repo

  @doc "Shifts chat `chat_id`'s stored positions for a split at `position` by `shift`. Run inside the caller's transaction."
  @spec shift!(Ecto.UUID.t(), integer(), pos_integer()) :: :ok
  def shift!(chat_id, position, shift) when is_integer(position) and is_integer(shift) and shift > 0 do
    for schema <- [Record, Job] do
      Repo.update_all(
        from(x in schema, where: x.chat_id == ^chat_id and x.range_start > ^position),
        inc: [range_start: shift]
      )

      Repo.update_all(
        from(x in schema, where: x.chat_id == ^chat_id and x.range_end >= ^position),
        inc: [range_end: shift]
      )
    end

    Repo.update_all(
      from(s in ChatSettings, where: s.chat_id == ^chat_id and s.highest_processed >= ^position),
      inc: [highest_processed: shift]
    )

    Repo.update_all(
      from(c in SidePromptCheckpoint, where: c.chat_id == ^chat_id and c.last_position >= ^position),
      inc: [last_position: shift]
    )

    rewrite(Record, :snapshot, chat_id, &shift_snapshot(&1, position, shift))
    rewrite(Job, :params, chat_id, &shift_params(&1, position, shift))

    :ok
  end

  defp rewrite(schema, field, chat_id, fun) do
    from(x in schema, where: x.chat_id == ^chat_id, select: {x.id, field(x, ^field)})
    |> Repo.all()
    |> Enum.each(fn {id, map} ->
      case fun.(map) do
        ^map -> :ok
        shifted -> Repo.update_all(from(x in schema, where: x.id == ^id), set: [{field, shifted}])
      end
    end)
  end

  defp shift_snapshot(snapshot, p, d) do
    snapshot
    |> update_present("range", fn
      [first, last] -> [start_pos(first, p, d), end_pos(last, p, d)]
      other -> other
    end)
    |> update_present("messages", &shift_range(&1, p, d))
  end

  defp shift_params(params, p, d) do
    params =
      case params do
        %{"start" => first, "end" => last} when is_integer(first) and is_integer(last) ->
          %{params | "start" => start_pos(first, p, d), "end" => end_pos(last, p, d)}

        _ ->
          params
      end

    params
    |> update_present("messages", &shift_range(&1, p, d))
    |> update_present("snapshot", fn
      %{} = snapshot -> update_present(snapshot, "messages", &shift_range(&1, p, d))
      other -> other
    end)
  end

  defp update_present(map, key, fun) do
    case map do
      %{^key => value} -> %{map | key => fun.(value)}
      _ -> map
    end
  end

  defp shift_range(%{"start" => first, "end" => last} = range, p, d),
    do: %{range | "start" => start_pos(first, p, d), "end" => end_pos(last, p, d)}

  defp shift_range(other, _p, _d), do: other

  defp start_pos(value, p, d) when is_integer(value) and value > p, do: value + d
  defp start_pos(value, _p, _d), do: value

  defp end_pos(value, p, d) when is_integer(value) and value >= p, do: value + d
  defp end_pos(value, _p, _d), do: value
end
