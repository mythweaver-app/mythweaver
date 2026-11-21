defmodule Mythweaver.Scripts.API.Memory do
  @moduledoc """
  `mw.memory.*`: queue and manage Memory Book work for the current chat.

  As with `mw.generation.*`, the job-queueing functions (`create`, `next`, `catch_up`,
  `run_side_prompt`) are refused with `nil, "not_allowed"` outside `user_message`, `command`,
  `quick_reply` and inline scripts.
  """

  use Gettext, backend: Mythweaver.Gettext

  import Mythweaver.Scripts.API.Convert

  alias Mythweaver.Memory
  alias Mythweaver.Memory.SidePrompts

  @functions %{
    create:
      {"mw.memory.create(start, finish)",
       dgettext_noop(
         "scripts",
         ~s(Queues a memory for the inclusive display-message range. Returns its job, or nil and a context reason.)
       )},
    next:
      {"mw.memory.next()",
       dgettext_noop(
         "scripts",
         ~s(Queues a memory for every unprocessed message. Returns its job, or nil, "empty_scene" when none remain.)
       )},
    catch_up:
      {"mw.memory.catch_up(start, finish, chunk)",
       dgettext_noop(
         "scripts",
         "Queues consecutive memory jobs over the inclusive display-message range; chunk must be 5 through 250. Returns the jobs."
       )},
    run_side_prompt:
      {"mw.memory.run_side_prompt(side_prompt_id [, start [, finish]])",
       dgettext_noop(
         "scripts",
         ~s(Queues a side prompt over the optional inclusive display-message range. Omitted endpoints use its checkpoint/latest defaults; unknown ids return nil, "not_found".)
       )},
    set_side_prompt_enabled:
      {"mw.memory.set_side_prompt_enabled(side_prompt_id_or_all, enabled)",
       dgettext_noop(
         "scripts",
         ~s(Enables or disables one global side prompt, or every prompt for the literal "all". Returns how many changed.)
       )},
    highest:
      {"mw.memory.highest()",
       dgettext_noop("scripts", "The processed boundary as a display-message number, or nil when it is clear.")},
    set_highest:
      {"mw.memory.set_highest(number_or_nil)",
       dgettext_noop(
         "scripts",
         "Sets the processed boundary from a positive display-message number, or clears it with nil. Returns true."
       )}
  }

  @usage Map.new(@functions, fn {name, {signature, _info}} -> {name, signature} end)

  # Message positions are int4 columns; a larger display number is a usage error, not a DB error.
  @max_display 2_147_483_647

  # The functions that queue LLM jobs follow `mw.generation`'s rule: never from inside a generation
  # or an image description, so a reply or caption cannot fan out into paid memory jobs.
  @queueing [:create, :next, :catch_up, :run_side_prompt]
  @queueing_triggers [:user_message, :inline, :command, :quick_reply]

  @doc "The installed functions' signatures and descriptions, by name."
  def functions, do: @functions

  def install(lua, ctx), do: install_functions(lua, [:mw, :memory], @functions, &call(&1, ctx, &2, &3))

  defp call(name, %{trigger: trigger}, _args, state) when name in @queueing and trigger not in @queueing_triggers,
    do: refuse(state, :not_allowed)

  defp call(:create, ctx, [start, finish], state) do
    {first, last} = range!(start, finish, :create)
    create(ctx, first, last, state)
  end

  defp call(:next, ctx, [], state) do
    case Memory.next_range(ctx.scope, ctx.chat) do
      :none -> refuse(state, :empty_scene)
      {first, last} -> create(ctx, first, last, state)
    end
  end

  defp call(:catch_up, ctx, [start, finish, chunk], state) do
    {first, last} = range!(start, finish, :catch_up)
    chunk = positive_int!(chunk, :catch_up)
    queue(state, fn -> Memory.catch_up(ctx.scope, ctx.chat, first, last, chunk) end)
  end

  defp call(:run_side_prompt, ctx, [id | endpoints], state) when is_binary(id) and length(endpoints) <= 2 do
    opts = side_range!(endpoints)

    case fetch(id, &Memory.get_side_prompt(ctx.scope, &1)) do
      nil ->
        refuse(state, :not_found)

      side_prompt ->
        queue(state, fn -> SidePrompts.run(ctx.scope, ctx.chat, side_prompt, [trigger: :script] ++ opts) end)
    end
  end

  defp call(:set_side_prompt_enabled, ctx, [id, enabled], state) when is_binary(id) and is_boolean(enabled) do
    prompts =
      if id == "all",
        do: Memory.list_side_prompts(ctx.scope),
        else: fetch(id, &Memory.get_side_prompt(ctx.scope, &1))

    if is_nil(prompts) do
      refuse(state, :not_found)
    else
      results =
        prompts
        |> List.wrap()
        |> Enum.reject(&(&1.enabled == enabled))
        |> Enum.map(&Memory.update_side_prompt(ctx.scope, &1, %{enabled: enabled}))

      case Enum.find(results, &match?({:error, _}, &1)) do
        nil -> ok(state, length(results))
        {:error, reason} -> refuse(state, reason)
      end
    end
  end

  defp call(:highest, ctx, [], state) do
    ok(state, display(Memory.chat_settings(ctx.scope, ctx.chat).highest_processed))
  end

  defp call(:set_highest, ctx, [nil], state), do: set_highest(ctx, nil, state)

  defp call(:set_highest, ctx, [number], state) do
    set_highest(ctx, positive_int!(number, :set_highest) - 1, state)
  end

  defp call(name, _ctx, _args, _state), do: usage!(@usage[name])

  defp set_highest(ctx, position, state) do
    ctx.scope |> Memory.set_highest_processed(ctx.chat, position) |> reply(state, fn _ -> true end)
  end

  defp create(ctx, first, last, state) do
    queue(state, fn -> Memory.create_memory(ctx.scope, ctx.chat, first, last, origin: :background) end)
  end

  defp queue(state, fun) do
    case fun.() do
      {:ok, jobs} when is_list(jobs) -> ok(state, Enum.map(jobs, &job_table/1))
      {:ok, job} -> ok(state, job_table(job))
      {:error, reason} -> refuse(state, reason)
      {:confirm, _tokens} -> raise "background memory command unexpectedly requested confirmation"
    end
  end

  defp job_table(job) do
    %{
      id: job.id,
      tag: job.tag,
      status: job.status,
      label: job.label,
      range_start: display(job.range_start),
      range_end: display(job.range_end)
    }
  end

  defp side_range!([]), do: []
  defp side_range!([nil]), do: []
  defp side_range!([start]), do: [start: positive_int!(start, :run_side_prompt) - 1]
  defp side_range!([start, nil]), do: [start: positive_int!(start, :run_side_prompt) - 1]

  defp side_range!([start, finish]) do
    {first, last} = range!(start, finish, :run_side_prompt)
    [start: first, end: last]
  end

  defp range!(start, finish, name) do
    first = positive_int!(start, name)
    last = positive_int!(finish, name)
    if first <= last, do: {first - 1, last - 1}, else: usage!(@usage[name])
  end

  defp positive_int!(value, _name) when is_integer(value) and value in 1..@max_display, do: value

  defp positive_int!(value, _name)
       when is_float(value) and value >= 1 and value <= @max_display and value == trunc(value), do: trunc(value)

  defp positive_int!(_value, name), do: usage!(@usage[name])

  defp display(nil), do: nil
  defp display(position), do: position + 1
end
