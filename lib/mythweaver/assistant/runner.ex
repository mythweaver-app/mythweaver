defmodule Mythweaver.Assistant.Runner do
  @moduledoc """
  One assistant run: a reply turn or a one-round compaction. A reply turn makes up to #{8}
  rounds of request → streamed reply → tool calls, each round a new Mythweaver message. Read tools
  run at once and the next round follows; a write or input tool ends the run, and
  `Mythweaver.Assistant` starts a new one once the user decides. A compaction (`:compact`) streams
  one summary message (`Context.compaction/3`, `Messages.create_assistant_summary/1`) and never
  parses tool calls.

  One runner per chat, registered as `{:assistant, chat_id}` in `Mythweaver.Generation.Registry`
  under `Mythweaver.Generation.Supervisor`, so it outlives the LiveView. The streaming, debounce
  and finalize mirror `Mythweaver.Generation.Server`; no `PromptSnapshot` is written. Exits are
  trapped, so a stop still finalizes the body in `terminate/2`; a hard kill leaves it `generating`
  for `Messages.finalize_interrupted_bodies/0` at the next boot.

  A model that cannot see images first waits (at most #{div(120_000, 1000)}s) for the thread's
  pending image captions, as `Generation.Server` does, so its prompt reads their descriptions.
  """

  use GenServer, restart: :temporary

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI.Completion
  alias Mythweaver.AI.Model
  alias Mythweaver.AI.ProviderModel
  alias Mythweaver.AI.StreamEvent
  alias Mythweaver.Assistant
  alias Mythweaver.Assistant.Context
  alias Mythweaver.Assistant.TextProtocol
  alias Mythweaver.Assistant.ToolCall
  alias Mythweaver.Assistant.Tools
  alias Mythweaver.Attachments
  alias Mythweaver.Attachments.Captions
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Jobs
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message
  alias Mythweaver.Repo
  alias Mythweaver.Tokenizer

  @max_rounds 8
  @caption_wait_ms 120_000

  @doc "The most rounds one run makes before it stops and asks for a new message."
  def max_rounds, do: @max_rounds

  @doc "Starts the chat's runner for a reply turn or a compaction; `{:error, :busy}` when one is already running."
  @spec start(Scope.t(), Chat.t(), Model.t(), :reply | :compact) :: :ok | {:error, :busy}
  def start(scope, chat, model, mode \\ :reply) when mode in [:reply, :compact] do
    case DynamicSupervisor.start_child(
           Mythweaver.Generation.Supervisor,
           {__MODULE__, scope: scope, chat: chat, model: model, mode: mode}
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> {:error, :busy}
    end
  end

  @doc "The chat's registered name."
  def name(chat_id), do: {:via, Registry, {Mythweaver.Generation.Registry, {:assistant, chat_id}}}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: name(Keyword.fetch!(opts, :chat).id))

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    chat = Keyword.fetch!(opts, :chat)
    model = Keyword.fetch!(opts, :model)

    state =
      reset(%{
        scope: Keyword.fetch!(opts, :scope),
        chat: chat,
        model: model,
        mode: Keyword.get(opts, :mode, :reply),
        protocol: if(model.supports_tools, do: :native, else: :text),
        round: 1,
        flush_ms: Messages.write_debounce_ms(),
        awaiting_captions: nil,
        caption_timer: nil
      })

    Assistant.broadcast_state(chat.id, true)
    {:ok, state, {:continue, :captions}}
  end

  defp reset(state) do
    Map.merge(state, %{
      message: nil,
      body: nil,
      ref: nil,
      job_id: nil,
      content: "",
      reasoning: nil,
      flush_timer: nil,
      started_at: nil,
      activity_touched?: false
    })
  end

  # Subscribes before querying, so a caption finishing between the two cannot be missed.
  @impl true
  def handle_continue(:captions, state) do
    ids =
      if Model.sees_images?(state.model) do
        []
      else
        for m <- Messages.list_messages(state.chat),
            m.visible_to_ai,
            Enum.any?(Message.loaded_attachments(m), &(&1.kind == :image)),
            do: m.id
      end

    with [_ | _] <- ids,
         :ok <- Attachments.subscribe(state.chat.id),
         [_ | _] = pending <- Captions.pending_ids(ids) do
      timer = Process.send_after(self(), :caption_wait_timeout, @caption_wait_ms)
      {:noreply, %{state | awaiting_captions: MapSet.new(pending), caption_timer: timer}}
    else
      _ -> settle_captions(state)
    end
  end

  def handle_continue(:round, %{mode: :compact} = state) do
    input = Context.compaction(state.scope, state.chat, state.model)
    {:ok, message} = Messages.create_assistant_summary(state.chat)
    stream_round(state, input, message, "Mythweaver summary")
  end

  def handle_continue(:round, state) do
    input = Context.build(state.scope, state.chat, state.model, state.protocol)
    {:ok, message} = Messages.create_assistant_reply(state.chat)
    stream_round(state, input, message, "Mythweaver")
  end

  defp stream_round(state, input, message, label) do
    {:ok, ref, job_id} =
      Jobs.stream_async(state.scope, state.model, input, self(),
        tag: :assistant,
        chat_id: state.chat.id,
        label: label
      )

    {:noreply, %{state | message: message, body: List.first(message.bodies), ref: ref, job_id: job_id}}
  end

  @impl true
  def handle_info({:ai_stream, ref, %StreamEvent.Request{}}, %{ref: ref} = state),
    do: {:noreply, %{state | started_at: System.monotonic_time(:millisecond)}}

  def handle_info({:ai_stream, ref, %StreamEvent.Delta{text: text}}, %{ref: ref} = state),
    do: {:noreply, streamed(%{state | content: state.content <> text})}

  def handle_info({:ai_stream, ref, %StreamEvent.Reasoning{text: text}}, %{ref: ref} = state),
    do: {:noreply, streamed(%{state | reasoning: (state.reasoning || "") <> text})}

  def handle_info({:ai_stream, ref, %StreamEvent.Done{}}, %{ref: ref} = state), do: {:noreply, state}

  def handle_info({:ai_stream, ref, {:ok, %Completion{} = completion, %ProviderModel{} = link}}, %{ref: ref} = state) do
    cancel_flush(state)

    {visible, calls} =
      case {state.mode, state.protocol} do
        {:compact, _} -> {completion.text || "", []}
        {:reply, :native} -> {completion.text || "", completion.tool_calls}
        {:reply, :text} -> text_calls(completion)
      end

    {:ok, body} =
      Messages.finalize_body(
        state.body,
        Map.merge(
          %{
            content: visible,
            reasoning: completion.reasoning,
            finish_reason: completion.finish_reason,
            prompt_tokens: completion.prompt_tokens,
            completion_tokens: completion.completion_tokens,
            total_tokens: completion.total_tokens,
            generation_ms: elapsed_ms(state),
            provider_model_id: link.id
          },
          Map.merge(cost_attrs(state, completion), empty_summary(state, visible))
        )
      )

    records = record_calls(state, calls)
    open? = Enum.any?(records, &(&1.status in [:pending, :awaiting_input]))
    capped? = records != [] and not open? and state.round >= @max_rounds

    body =
      if capped? do
        {:ok, body} =
          Messages.finalize_body(body, %{
            error: "Mythweaver stopped after #{@max_rounds} tool rounds. Send a message to continue."
          })

        body
      else
        body
      end

    if not state.activity_touched? and (visible != "" or records != []), do: Messages.touch_activity(state.chat.id)
    if records != [], do: Assistant.broadcast_tool_calls(state.chat.id, state.message.id)
    Messages.broadcast_generation_finished(state.chat.id, state.message.id)

    state = %{state | body: body}

    if records == [] or open? or capped? do
      {:stop, :normal, state}
    else
      {:noreply, reset(%{state | round: state.round + 1}), {:continue, :round}}
    end
  end

  def handle_info({:ai_stream, ref, {:error, reason}}, %{ref: ref} = state) do
    cancel_flush(state)
    content = visible(state)

    {:ok, body} =
      Messages.finalize_body(state.body, %{
        content: content,
        reasoning: state.reasoning,
        error: Mythweaver.Locale.with_user_locale(state.scope, fn -> Jobs.error_message(reason) end),
        generation_ms: elapsed_ms(state)
      })

    Messages.broadcast_generation_finished(state.chat.id, state.message.id)
    {:stop, :normal, %{state | body: body}}
  end

  def handle_info(:flush, %{body: %{}} = state) do
    :ok = Messages.save_streamed_body(state.body, visible(state), state.reasoning)
    {:noreply, %{state | flush_timer: nil}}
  end

  def handle_info({:caption_finished, id}, %{awaiting_captions: %MapSet{} = awaiting} = state) do
    awaiting = MapSet.delete(awaiting, id)

    if MapSet.size(awaiting) == 0,
      do: settle_captions(state),
      else: {:noreply, %{state | awaiting_captions: awaiting}}
  end

  # Waited long enough: the reply goes out, and an image still undescribed reads as `[Image]`.
  def handle_info(:caption_wait_timeout, %{awaiting_captions: %MapSet{}} = state), do: settle_captions(state)

  def handle_info(_message, state), do: {:noreply, state}

  defp settle_captions(state) do
    if state.caption_timer, do: Process.cancel_timer(state.caption_timer)
    Attachments.unsubscribe(state.chat.id)
    {:noreply, %{state | awaiting_captions: nil, caption_timer: nil}, {:continue, :round}}
  end

  @impl true
  def terminate(_reason, state) do
    case state do
      %{body: %{generating: true} = body} ->
        if state.job_id, do: Jobs.cancel(state.scope, state.job_id)

        Messages.finalize_body(body, %{
          content: visible(state),
          reasoning: state.reasoning,
          error: Mythweaver.Locale.with_user_locale(state.scope, fn -> Jobs.error_message(:canceled) end),
          generation_ms: elapsed_ms(state)
        })

        Messages.broadcast_generation_finished(state.chat.id, state.message.id)

      _ ->
        :ok
    end

    Assistant.broadcast_state(state.chat.id, false)
    :ok
  end

  # Inserts the reply's calls in order. Read tools run now; writes wait for approval and the key
  # form for the user. An unknown tool or undecodable arguments fail at once.
  defp record_calls(state, calls) do
    now = DateTime.utc_now()

    calls
    |> Enum.with_index()
    |> Enum.map(fn {call, position} ->
      attrs = outcome(state.scope, call)

      %ToolCall{
        chat_id: state.chat.id,
        message_id: state.message.id,
        position: position,
        call_id: call.id,
        name: call.name,
        inserted_at: now,
        updated_at: now
      }
      |> Ecto.Changeset.change(attrs)
      |> Repo.insert!()
    end)
  end

  defp outcome(scope, call) do
    case {Tools.fetch(call.name), Jason.decode(call.arguments || "")} do
      {:error, _} ->
        %{status: :failed, arguments: decoded_or_empty(call.arguments), error: "Unknown tool"}

      {{:ok, _tool}, {:ok, args}} when not is_map(args) ->
        %{status: :failed, arguments: %{}, error: "Arguments were not valid JSON."}

      {{:ok, _tool}, {:error, _}} ->
        if String.trim(call.arguments || "") == "",
          do: outcome(scope, %{call | arguments: "{}"}),
          else: %{status: :failed, arguments: %{}, error: "Arguments were not valid JSON."}

      {{:ok, %{kind: :read} = tool}, {:ok, args}} ->
        case Tools.run(scope, tool, args) do
          {:ok, result} -> %{status: :succeeded, arguments: args, result: result}
          {:error, result} -> %{status: :failed, arguments: args, result: result}
        end

      {{:ok, %{kind: :write}}, {:ok, args}} ->
        %{status: :pending, arguments: args}

      # The input tool's `run` checks its arguments; the card opens only when they hold up.
      {{:ok, %{kind: :input} = tool}, {:ok, args}} ->
        case Tools.run(scope, tool, args) do
          {:ok, _checked} -> %{status: :awaiting_input, arguments: args}
          {:error, result} -> %{status: :failed, arguments: args, result: result}
        end
    end
  end

  # A backend with its own tool-call parser (llama.cpp's for tool-trained models) turns the text
  # protocol's `<tool_call>` blocks into `tool_calls` itself, leaving no blocks in the text.
  defp text_calls(%Completion{} = completion) do
    case TextProtocol.parse(completion.text || "") do
      {visible, []} -> {visible, completion.tool_calls}
      parsed -> parsed
    end
  end

  defp decoded_or_empty(arguments) do
    case Jason.decode(arguments || "") do
      {:ok, %{} = args} -> args
      _ -> %{}
    end
  end

  defp streamed(state) do
    Messages.broadcast_body_delta(state.chat.id, state.message.id, state.body.id, visible(state), state.reasoning)

    if state.flush_timer, do: Process.cancel_timer(state.flush_timer)
    state = %{state | flush_timer: Process.send_after(self(), :flush, state.flush_ms)}

    if state.activity_touched? do
      state
    else
      :ok = Messages.touch_activity(state.chat.id)
      %{state | activity_touched?: true}
    end
  end

  defp cancel_flush(%{flush_timer: nil}), do: :ok
  defp cancel_flush(%{flush_timer: timer}), do: Process.cancel_timer(timer)

  defp empty_summary(%{mode: :compact}, visible) do
    if String.trim(visible) == "", do: %{error: "The model returned an empty summary."}, else: %{}
  end

  defp empty_summary(_state, _visible), do: %{}

  defp visible(%{mode: :compact, content: content}), do: content
  defp visible(%{protocol: :text, content: content}), do: TextProtocol.visible_streaming(content)
  defp visible(%{content: content}), do: content

  defp elapsed_ms(%{started_at: nil}), do: nil
  defp elapsed_ms(%{started_at: t}), do: System.monotonic_time(:millisecond) - t

  # The provider's charge wins; else an estimate from the reported (or counted) tokens.
  defp cost_attrs(_state, %Completion{cost: %Decimal{} = cost}), do: %{cost: cost, cost_estimated: false}

  defp cost_attrs(state, %Completion{} = completion) do
    completion_tokens =
      completion.completion_tokens ||
        elem(Tokenizer.count(state.model, (completion.text || "") <> (completion.reasoning || "")), 0)

    case Model.estimate_cost(state.model, completion.prompt_tokens || 0, completion_tokens) do
      nil -> %{}
      cost -> %{cost: cost, cost_estimated: true}
    end
  end
end
