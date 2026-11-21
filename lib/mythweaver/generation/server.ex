defmodule Mythweaver.Generation.Server do
  @moduledoc """
  Owns one in-flight reply: assembles the prompt, starts the streamed completion, folds deltas into
  the target body, and finalizes it exactly once. One Server is one reply; the per-chat lock and the
  reply queue belong to `Mythweaver.Generation.Conductor`, which starts and monitors it.

  Supervised rather than run inside the LiveView so refreshing or closing the tab that asked for the
  reply neither aborts it nor leaves a half-written body nobody finalizes.

  The streamed text is held in memory and written to the body on a debounce
  (`Messages.write_debounce_ms/0` after the last token) and at finalize. Exits are trapped, so a
  supervisor shutdown still runs `terminate/2`. Two cases leave the body `generating`: a hard kill
  (`:kill`, which skips `terminate/2` and loses the unflushed tail) and a crash between `target_body/1`
  and the end of `handle_continue/2`. `Messages.finalize_interrupted_bodies/0` settles either one at
  the next boot.

  A generation that ends with no text (a blank reply, an error or stop before the first token, a
  continue that added nothing) keeps nothing: `Messages.discard_generation/3` drops its swipe, and
  the message too when no other swipe has text, and any error reaches the chat's tabs as
  `{:generation_discarded, chat_id, error}` instead.
  """

  use GenServer, restart: :temporary
  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.AI.Completion
  alias Mythweaver.AI.Model
  alias Mythweaver.AI.ProviderModel
  alias Mythweaver.AI.StreamEvent
  alias Mythweaver.Attachments
  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Attachments.Captions
  alias Mythweaver.Format
  alias Mythweaver.Generation.Overlap
  alias Mythweaver.Generation.OwnName
  alias Mythweaver.Generation.StopStrings
  alias Mythweaver.Injections
  alias Mythweaver.Jobs
  alias Mythweaver.Lore.Activation
  alias Mythweaver.Memory
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message
  alias Mythweaver.Messages.PromptSnapshot
  alias Mythweaver.Notifications
  alias Mythweaver.Prompts.Builder
  alias Mythweaver.Prompts.ContextLimit
  alias Mythweaver.Prompts.Transcript
  alias Mythweaver.Scripts
  alias Mythweaver.Sharing.Protected
  alias Mythweaver.Sharing.Visibility
  alias Mythweaver.Templates
  alias Mythweaver.Tokenizer
  alias Mythweaver.Variables

  # How often a reply waiting on captions rechecks them, catching deleted images and missed broadcasts.
  @caption_recheck_ms Application.compile_env(:mythweaver, :caption_recheck_ms, 5_000)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      # The scope the reply runs as (the chat owner's, `Mythweaver.Chats.run_scope/2`) and the asker's
      # own, whom the reply notifies.
      scope: Keyword.fetch!(opts, :scope),
      initiator: Keyword.get(opts, :initiator) || Keyword.fetch!(opts, :scope),
      # Whose models, keys and quota the reply spends (`Chats.spend_scope/2`).
      spend_scope: Keyword.get(opts, :spend_scope) || Keyword.fetch!(opts, :scope),
      chat: Keyword.fetch!(opts, :chat),
      character: Keyword.fetch!(opts, :character),
      prompt: Keyword.fetch!(opts, :prompt),
      model: Keyword.fetch!(opts, :model),
      mode: Keyword.fetch!(opts, :mode),
      guide: Keyword.get(opts, :guide),
      # The attachments sent with the guide or refine: ids from the caller, reloaded on every
      # `:start` pass into `guide_attachments`.
      guide_attachment_ids: Keyword.get(opts, :guide_attachment_ids, []),
      guide_attachments: [],
      # A refine's editing instructions; nil otherwise.
      refine: Keyword.get(opts, :refine),
      # Started by a Lua script (`mw.generation.*`); its own scripts see `event.script_triggered`.
      script_triggered?: Keyword.get(opts, :script_triggered, false),
      # The notification kind to send on success (`Mythweaver.Notifications`); nil sends none.
      notify: Keyword.get(opts, :notify),
      message: nil,
      body: nil,
      ref: nil,
      snapshot: nil,
      job_id: nil,
      content: "",
      reasoning: nil,
      flush_timer: nil,
      # A continue's original text and reasoning; the stream is appended to them.
      prefix: nil,
      reasoning_base: nil,
      # The build's `{secret, label, source}` triples (`Protected.pairs/1`); the accumulated reasoning
      # with every protected value scrubbed (`reasoning_redacted`, what a viewer lacking
      # `site.hidden.view` sees) and with only share-protected ones scrubbed
      # (`reasoning_share_redacted`, what a `site.hidden.view` holder sees), each nil when there is
      # nothing to scrub; a continue's source keeps its own.
      protected: [],
      reasoning_redacted: nil,
      reasoning_redacted_base: nil,
      reasoning_share_redacted: nil,
      reasoning_share_redacted_base: nil,
      # Set when the request goes out, not when the job is queued: queue wait is not generation time.
      started_at: nil,
      # Spent only when the reply finishes successfully; a stop or error keeps them armed.
      applied_injection_ids: [],
      # Whether a token has bumped the chat's activity, and whether tokens since then owe a bump.
      activity_touched?: false,
      activity_owed?: false,
      flush_ms: Messages.write_debounce_ms(),
      # Image captions this reply waits for (`caption_gate/2`); settled once it stops waiting.
      awaiting_captions: nil,
      caption_timer: nil,
      captions_settled?: false,
      # `OwnName.pattern/2`, set when the reply starts; nil keeps the responder's `Name:` prefixes.
      own_name: nil
    }

    {:ok, state, {:continue, :start}}
  end

  # The DB writes and the HTTP kickoff happen here, not in `init/1`, so `start_link/1` returns to the
  # caller immediately and a slow first byte never blocks the LiveView's `handle_event/3`.
  #
  # Everything that does not need the body, the snapshot's attrs included, is built before
  # `target_body/1` creates it, which keeps the window where a crash strands a `generating` row small.
  # The snapshot is written after the request is in flight but before any stream event is handled, so
  # its `:request` update always finds the row. Counting sections is a few NIF calls: the lore pass
  # already loaded the model's tokenizer.
  #
  # A regenerate or refine leaves the reply it replaces out of both the lore scan and the transcript:
  # the model writes an alternative to it, not a continuation of it. A refine sees the replaced text
  # only through `anchors.refine`. The replaced (or continued) message's own attachments still reach
  # the prompt, after the history (`Builder.context/3`'s `:reply`).
  #
  # A model that cannot see images first waits for the descriptions of the images sent since the
  # responder last spoke, of the guide's attachments and of the replaced message's own
  # (`caption_gate/4`), until each one settles, so its prompt carries them; nothing is written while
  # it waits. Old pending captions outside that window are not waited for.
  #
  # Chat history is trimmed oldest-first to the context limit (`ContextLimit.for_reply/2`). A prompt
  # over the limit even without history is refused before any request: the reply ends with an error and
  # no job is queued.
  @impl true
  def handle_continue(:start, state) do
    all = Messages.list_messages(state.chat)
    # Reloaded every pass, so captions that settled mid-wait are current.
    reply = reply_message(all, state.mode)
    messages = without_swiped(all, state.mode)
    # Reloaded every pass, so a description that just finished, or an attachment removed meanwhile, is current.
    guide_attachments = load_guide_attachments(state)
    state = %{state | guide_attachments: guide_attachments}

    case caption_gate(state, messages, guide_attachments, reply) do
      {:wait, state} -> {:noreply, state}
      {:go, state} -> start_reply(state, messages, reply)
    end
  end

  defp reply_message(_all, :new), do: nil
  defp reply_message(all, {_kind, %Message{id: id}}), do: Enum.find(all, &(&1.id == id))

  defp load_guide_attachments(%{guide_attachment_ids: []}), do: []

  defp load_guide_attachments(state) do
    found = Attachments.get_attachments(state.scope, state.guide_attachment_ids)
    for id <- state.guide_attachment_ids, %Attachment{status: :ready} = a <- [found[id]], do: a
  end

  defp start_reply(state, messages, reply) do
    context_limit = ContextLimit.for_reply(state.scope, state.model)
    tag_graph = Mythweaver.Tags.graph(state.chat.user_id)

    # Its decision details are stored in the prompt snapshot: the initiator's language.
    lore =
      localized(state, fn ->
        Activation.resolve(state.scope, state.chat,
          commit: true,
          model: state.model,
          context_limit: context_limit,
          messages: messages,
          character: state.character,
          tag_graph: tag_graph
        )
      end)

    # Script writes (block toggles, lore edits) take effect from the next generation: this reply's
    # prompt and lore are already resolved.
    run_lore_scripts(state, lore)

    context =
      Builder.context(state.scope, state.chat,
        character: state.character,
        messages: messages,
        lore: lore,
        model: state.model,
        continue: continued(state.mode),
        guide: state.guide,
        guide_attachments: state.guide_attachments,
        reply: reply,
        refine: refined(state),
        attach_images: Model.sees_images?(state.model),
        inline_limits: Model.inline_limits(state.model),
        attach_files: Model.reads_files?(state.model),
        attach_audio: Model.hears_audio?(state.model),
        attach_video: Model.watches_video?(state.model),
        context_limit: context_limit,
        tag_graph: tag_graph
      )

    describe_aged_out(state, messages)

    # Its notices, template errors and hidden-content labels reach the user: the initiator's language.
    case localized(state, fn -> Builder.build(state.prompt, context) end) do
      %{context: %{overflow?: true} = report} = built -> refuse(state, built, lore, report)
      built -> send_reply(state, built, lore, context)
    end
  end

  defp send_reply(state, built, lore, context) do
    writes = Templates.State.writes(built.state)
    # The same commit point as lore's `commit: true` above: a later stop or error rolls neither back.
    :ok = Variables.apply_writes(state.chat.id, writes)

    input =
      built.segments
      |> Builder.render_segments(state.model, context)
      |> Attachments.inline_attachments(state.model)
      |> StopStrings.put(state.model, StopStrings.for_reply(state.scope, state.chat, state.character))
      |> Map.put(:thinking, state.prompt.thinking)

    snapshot_attrs =
      state.prompt
      |> PromptSnapshot.build_attrs(built, lore, state.model)
      |> Map.put(:variable_writes, writes)

    {message, body} = target_body(state)
    state = state |> with_protected(built) |> seed_continuation()

    tag = job_tag(state.mode)
    script? = state.script_triggered? not in [nil, false]
    label = localized(state, fn -> job_label(tag, state.character.name, script?) end)

    {:ok, ref, job_id} =
      Jobs.stream_async(state.spend_scope, state.model, input, self(),
        tag: tag,
        chat_id: state.chat.id,
        label: label,
        prompt_name: state.prompt.name,
        protected: state.protected
      )

    {:ok, snapshot} =
      Messages.create_prompt_snapshot(
        body,
        Map.merge(snapshot_attrs, %{ai_model_id: state.model.id, tokenizer: state.model.tokenizer})
      )

    {:noreply,
     %{
       state
       | message: message,
         body: body,
         ref: ref,
         job_id: job_id,
         snapshot: snapshot,
         applied_injection_ids: for(%{status: :applied, id: id} <- built.injections, do: id),
         own_name: OwnName.pattern(state.scope, state.character)
     }}
  end

  # The fixed parts of the prompt alone overflow the context limit. Variable writes are not applied and
  # injections stay armed (only success spends them); lore was committed above, as on any error.
  defp refuse(state, built, lore, report) do
    snapshot_attrs = PromptSnapshot.build_attrs(state.prompt, built, lore, state.model)

    {message, body} = target_body(state)
    state = %{(state |> with_protected(built) |> seed_continuation()) | message: message, body: body}

    {:ok, snapshot} =
      Messages.create_prompt_snapshot(
        body,
        Map.merge(snapshot_attrs, %{ai_model_id: state.model.id, tokenizer: state.model.tokenizer})
      )

    error = localized(state, fn -> overflow_message(report) end)

    if empty?(state, ended_attrs(state, error).content) do
      discard(state, error)
      {:stop, :normal, %{state | body: %{body | generating: false}, snapshot: snapshot}}
    else
      {:ok, body} = Messages.finalize_body(body, ended_attrs(state, error))
      {:ok, snapshot} = Messages.put_snapshot_response(snapshot, %{error: error})

      settle_activity(state, false)
      Messages.broadcast_generation_finished(state.chat.id, message.id)

      {:stop, :normal, %{state | body: body, snapshot: snapshot}}
    end
  end

  defp overflow_message(%{limit: limit, used: used, reserve: reserve}) do
    gettext_comment("Shown as a reply's error when the prompt cannot fit the model's context window.")

    dgettext(
      "chat",
      "The prompt is too long for the %{token_limit}-token context limit even without chat history: about %{used_tokens} tokens, with %{reserved_tokens} kept free for the reply.",
      token_limit: Format.number(limit),
      used_tokens: Format.number(used),
      reserved_tokens: Format.number(reserve)
    )
  end

  # Text stored on a reply or broadcast to its chat is written in the initiator's language.
  defp localized(state, fun), do: Mythweaver.Locale.with_user_locale(state.initiator, fun)

  defp stopped_text, do: dpgettext("chat", "status: a reply that was stopped before it finished", "Stopped.")

  # A model reads attachments past its inline limits (`Model.inline_limits/1`) as their
  # descriptions. Those that have none are described by that same model in the background, so a
  # later reply reads them; this one goes out without waiting. An image, audio or video limit ages
  # out only what the model takes natively; a document limit ages out documents for any chat model,
  # which summarizes them. A text-mode model writes no summaries: its old documents stay full text.
  defp describe_aged_out(%{model: %Model{} = model} = state, messages) do
    limits = Model.inline_limits(model)
    within = Transcript.within_limits(messages, limits)

    aged =
      for m <- messages,
          a <- Message.loaded_attachments(m),
          a.status == :ready,
          is_integer(limits[a.kind]),
          Model.describes?(model, a.kind),
          not MapSet.member?(within, a.id),
          do: {m, a}

    Captions.request_aged_out(state.spend_scope, state.chat, aged, model)
  end

  @impl true
  def handle_info({:ai_stream, ref, %StreamEvent.Request{} = event}, %{ref: ref} = state) do
    {:ok, snapshot} = Messages.put_snapshot_request(state.snapshot, %{url: event.url, body: event.body})
    {:noreply, %{state | snapshot: snapshot, started_at: System.monotonic_time(:millisecond)}}
  end

  def handle_info({:ai_stream, ref, %StreamEvent.Delta{text: text}}, %{ref: ref} = state),
    do: {:noreply, streamed(%{state | content: state.content <> text})}

  def handle_info({:ai_stream, ref, %StreamEvent.Reasoning{text: text}}, %{ref: ref} = state) do
    state = %{state | reasoning: (state.reasoning || "") <> text}
    {:noreply, streamed(with_redactions(state))}
  end

  # The terminal result tuple carries `finish_reason` too; acting on both would finalize twice.
  def handle_info({:ai_stream, ref, %StreamEvent.Done{}}, %{ref: ref} = state), do: {:noreply, state}

  def handle_info({:ai_stream, ref, {:ok, %Completion{} = completion, %ProviderModel{} = link}}, %{ref: ref} = state) do
    # `completion.text` and `completion.reasoning` are the adapter's fully assembled strings and are
    # authoritative for both columns, so a dropped delta cannot leave a truncated body behind. Scripts
    # may rewrite the stored content; the snapshot keeps what the model actually sent.
    content = full_content(%{state | content: completion.text}, true)

    %{text: content} =
      Scripts.run(state.scope, :ai_generation, state.chat, %{
        "text" => content,
        "message_id" => state.message.id,
        "character_id" => state.character.id,
        "mode" => mode_name(state.mode),
        "script_triggered" => state.script_triggered?
      })

    if empty?(state, content) do
      # Nothing to keep: the reply is discarded, its injections stay armed, and the batch it began
      # (extra swipes) is dropped as after a failure.
      discard(
        state,
        localized(state, fn ->
          gettext_comment("Shown when a reply was discarded because the model sent back nothing.")
          dgettext("chat", "%{character_name} replied with no text.", character_name: state.character.name)
        end)
      )

      {:stop, :normal, %{state | body: %{state.body | generating: false}}}
    else
      finish(state, completion, link, content)
    end
  end

  def handle_info({:ai_stream, ref, {:error, reason}}, %{ref: ref} = state) do
    error = localized(state, fn -> error_message(reason) end)

    if empty?(state, full_content(state, true)) do
      discard(state, error)
      {:stop, :normal, %{state | body: %{state.body | generating: false}}}
    else
      {:ok, body} = Messages.finalize_body(state.body, ended_attrs(state, error))

      {:ok, snapshot} =
        Messages.put_snapshot_response(state.snapshot, %{
          error: error,
          text: full_content(state, true),
          http_body: http_body(reason)
        })

      settle_activity(state, false)
      Messages.broadcast_generation_finished(state.chat.id, state.message.id)

      {:stop, :normal, %{state | body: body, snapshot: snapshot}}
    end
  end

  def handle_info(:flush, state) do
    :ok =
      Messages.save_streamed_body(
        state.body,
        full_content(state),
        full_reasoning(state),
        state.reasoning_redacted,
        state.reasoning_share_redacted
      )

    {:noreply, %{state | flush_timer: nil}}
  end

  def handle_info({:caption_finished, id}, %{awaiting_captions: %MapSet{} = awaiting} = state) do
    awaiting = MapSet.delete(awaiting, id)

    if MapSet.size(awaiting) == 0,
      do: settle_captions(state),
      else: {:noreply, %{state | awaiting_captions: awaiting}}
  end

  # Rechecks what the reply still waits for: a deleted image or a missed broadcast must not hold it.
  def handle_info(:caption_recheck, %{awaiting_captions: %MapSet{} = awaiting} = state) do
    case Captions.pending_attachment_ids(MapSet.to_list(awaiting)) do
      [] ->
        settle_captions(state)

      pending ->
        timer = Process.send_after(self(), :caption_recheck, @caption_recheck_ms)
        {:noreply, %{state | awaiting_captions: MapSet.new(pending), caption_timer: timer}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Cancellation path. A `:normal` stop after finalization lands here too, where the `generating`
  # guard makes it a no-op. The job queue kills the streaming task (Req's streaming fold has no
  # cooperative stop, so killing it mid-request closes the socket, which is what aborting a
  # completion means) or drops the job if it is still queued. A job that already ended is
  # `{:error, :not_found}`, which needs nothing.
  @impl true
  def terminate(_reason, %{body: %{generating: true} = body} = state) do
    if state.job_id, do: Jobs.cancel(state.scope, state.job_id)

    if empty?(state, full_content(state, true)) do
      discard(state, nil)
    else
      stopped = localized(state, &stopped_text/0)
      attrs = state |> ended_attrs(stopped) |> Map.merge(cost_attrs(state, nil, nil, nil))

      Messages.finalize_body(body, attrs)

      if state.snapshot,
        do: Messages.put_snapshot_response(state.snapshot, %{error: stopped, text: full_content(state, true)})

      settle_activity(state, false)
      Messages.broadcast_generation_finished(state.chat.id, state.message.id)
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp finish(state, completion, link, content) do
    {:ok, body} =
      Messages.finalize_body(
        state.body,
        Map.merge(
          %{
            content: content,
            reasoning: full_reasoning(%{state | reasoning: completion.reasoning}),
            reasoning_redacted: redacted_reasoning(%{state | reasoning: completion.reasoning}),
            reasoning_share_redacted: share_redacted_reasoning(%{state | reasoning: completion.reasoning}),
            finish_reason: completion.finish_reason,
            prompt_tokens: completion.prompt_tokens,
            completion_tokens: completion.completion_tokens,
            total_tokens: completion.total_tokens,
            generation_ms: elapsed_ms(state),
            provider_model_id: link.id
          },
          cost_attrs(
            %{state | content: completion.text, reasoning: completion.reasoning},
            completion.cost,
            completion.prompt_tokens,
            completion.completion_tokens
          )
        )
      )

    :ok = Injections.spend(state.chat.id, state.applied_injection_ids)

    {:ok, snapshot} =
      Messages.put_snapshot_response(state.snapshot, %{
        text: completion.text,
        reasoning: completion.reasoning,
        finish_reason: completion.finish_reason,
        model: completion.model,
        usage: completion.raw
      })

    settle_activity(state, completion.text not in [nil, ""] or completion.reasoning not in [nil, ""])
    # Before the broadcast: listeners (tests included) treat it as the end of the server's DB work.
    Mythweaver.Expressions.classify_later(state.scope, state.chat.id, state.message.id, body.id)
    Memory.Auto.check(state.scope, state.chat.id)
    if state.notify, do: Notifications.reply_finished(state.initiator, state.notify, state.chat, state.character, body)
    Messages.broadcast_generation_finished(state.chat.id, state.message.id)

    {:stop, {:shutdown, {:replied, state.message.id}}, %{state | body: body, content: body.content, snapshot: snapshot}}
  end

  # A generation that produced no text: a blank reply, or a continue that added nothing to its source.
  defp empty?(%{prefix: nil}, content), do: Messages.blank?(content)
  defp empty?(%{prefix: prefix}, content), do: String.trim(content || "") == String.trim(prefix)

  # Leaves nothing behind (`Messages.discard_generation/3`): the swipe goes, and the message too when
  # no other swipe has text. `error`, unless the user stopped it, reaches the chat's tabs as a notice,
  # since there is no swipe left to show it on.
  defp discard(state, error) do
    {:ok, _} = Messages.discard_generation(state.scope, state.body, restore_body_id(state))
    if error, do: Messages.broadcast_generation_discarded(state.chat.id, error)
    Messages.broadcast_generation_finished(state.chat.id, state.message.id)
  end

  # The swipe that was active before a regenerate, continue or refine took its place.
  defp restore_body_id(%{mode: {_kind, %Message{} = message}}) do
    case Message.active_body(message) do
      nil -> nil
      body -> body.id
    end
  end

  defp restore_body_id(_state), do: nil

  # Subscribes before querying, so a caption finishing between the two cannot be missed. Messages
  # hidden from the AI never reach the prompt, so their attachments are neither described nor waited
  # for. The reply waits for the descriptions of the images, audio and video sent since the responder
  # last spoke, of the guide's attachments and of the replaced or continued message's own, until each
  # one settles; those nobody described (sent while no participant could describe them) are queued
  # first, with the responder's own caption model. Only the kinds its model cannot take are waited
  # for. Only Stop ends the wait early.
  defp caption_gate(%{captions_settled?: true} = state, _messages, _guide_attachments, _reply), do: {:go, state}

  defp caption_gate(state, messages, guide_attachments, reply) do
    kinds = for k <- [:image, :audio, :video], not takes_kind?(state.model, k), do: k

    window = Captions.reply_window(messages, state.character) ++ List.wrap(reply)

    ids =
      for(
        m <- window,
        m.visible_to_ai,
        a <- Message.loaded_attachments(m),
        a.kind in kinds,
        do: a.id
      ) ++ for(a <- guide_attachments, a.kind in kinds, do: a.id)

    if ids == [] do
      {:go, %{state | captions_settled?: true}}
    else
      :ok = Attachments.subscribe(state.chat.id)
      _queued = Captions.request_for_reply(state.spend_scope, state.chat, messages, state.character, state.model, reply)

      _queued =
        Captions.request_for_guide(state.spend_scope, state.chat, guide_attachments, state.character, state.model)

      case Captions.pending_attachment_ids(ids) do
        [] ->
          Attachments.unsubscribe(state.chat.id)
          {:go, %{state | captions_settled?: true}}

        pending ->
          timer = Process.send_after(self(), :caption_recheck, @caption_recheck_ms)
          {:wait, %{state | awaiting_captions: MapSet.new(pending), caption_timer: timer}}
      end
    end
  end

  defp takes_kind?(model, :image), do: Model.sees_images?(model)
  defp takes_kind?(model, :audio), do: Model.hears_audio?(model)
  defp takes_kind?(model, :video), do: Model.watches_video?(model)

  # `:start` lists the messages again, so the fresh descriptions are what the prompt reads.
  defp settle_captions(state) do
    Process.cancel_timer(state.caption_timer)
    Attachments.unsubscribe(state.chat.id)

    {:noreply, %{state | awaiting_captions: nil, caption_timer: nil, captions_settled?: true}, {:continue, :start}}
  end

  # A token arrived: tell every tab the accumulated text, then push the debounced write back.
  defp streamed(state) do
    Messages.broadcast_body_delta(
      state.chat.id,
      state.message.id,
      state.body.id,
      full_content(state),
      full_reasoning(state),
      state.reasoning_redacted,
      state.reasoning_share_redacted
    )

    state |> schedule_flush() |> note_tokens()
  end

  # Debounce: every token pushes the write back, so a steady stream writes nothing until it pauses
  # for `flush_ms` or finalizes.
  defp schedule_flush(state) do
    if state.flush_timer, do: Process.cancel_timer(state.flush_timer)
    %{state | flush_timer: Process.send_after(self(), :flush, state.flush_ms)}
  end

  # Generated tokens bump the chat's activity stamp (the picker's unread dot) twice at most: on the
  # first token, so the dot appears while the reply streams, and at finalize when tokens came after
  # it, so a chat read mid-reply is unread again. Each bump is a write, plus a mark-read write in
  # every tab showing the chat, so it must not scale with the reply's length.
  defp note_tokens(%{activity_touched?: false} = state) do
    :ok = Messages.touch_activity(state.chat.id)
    %{state | activity_touched?: true}
  end

  defp note_tokens(state), do: %{state | activity_owed?: true}

  # `produced?`: the final result carries text. Covers an adapter that delivered no deltas at all.
  defp settle_activity(state, produced?) do
    if state.activity_owed? or (produced? and not state.activity_touched?),
      do: Messages.touch_activity(state.chat.id)
  end

  # Only the error and stop paths write these: the stream is over, so a pending repeat is settled.
  defp ended_attrs(state, error) do
    %{
      content: full_content(state, true),
      reasoning: full_reasoning(state),
      reasoning_redacted: state.reasoning_redacted,
      reasoning_share_redacted: state.reasoning_share_redacted,
      error: error,
      generation_ms: elapsed_ms(state)
    }
  end

  defp elapsed_ms(%{started_at: nil}), do: nil
  defp elapsed_ms(%{started_at: t}), do: System.monotonic_time(:millisecond) - t

  # The provider's charge wins. Otherwise estimate: provider token counts when reported, else the
  # snapshot's per-section prompt count and a tokenizer count of what this generation produced.
  defp cost_attrs(_state, %Decimal{} = cost, _prompt_tokens, _completion_tokens),
    do: %{cost: cost, cost_estimated: false}

  defp cost_attrs(state, nil, prompt_tokens, completion_tokens) do
    prompt = prompt_tokens || prompt_estimate(state)
    completion = completion_tokens || completion_estimate(state)

    case Model.estimate_cost(state.model, prompt, completion) do
      nil -> %{}
      cost -> %{cost: cost, cost_estimated: true}
    end
  end

  defp prompt_estimate(%{snapshot: nil}), do: 0
  defp prompt_estimate(%{snapshot: snapshot}), do: Enum.reduce(snapshot.sections, 0, &(&1["tokens"] + &2))

  # Only what this generation streamed (`content`/`reasoning`, never a continue's `prefix`/
  # `reasoning_base`): reasoning is billed as output too.
  defp completion_estimate(state) do
    {tokens, _kind} = Tokenizer.count(state.model, (state.content || "") <> (state.reasoning || ""))
    tokens
  end

  defp continued({:continue, message}), do: message
  defp continued(_mode), do: nil

  defp refined(%{mode: {:refine, message}, refine: instructions}),
    do: %{instructions: instructions, text: Message.active_content(message)}

  defp refined(_state), do: nil

  defp without_swiped(messages, {kind, %{id: id}}) when kind in [:swipe, :refine],
    do: Enum.reject(messages, &(&1.id == id))

  defp without_swiped(messages, _mode), do: messages

  defp seed_continuation(%{mode: {:continue, message}} = state) do
    source = Message.active_body(message)

    state = %{
      state
      | prefix: source.content,
        reasoning_base: source.reasoning,
        reasoning_redacted_base: source.reasoning_redacted,
        reasoning_share_redacted_base: source.reasoning_share_redacted
    }

    with_redactions(state)
  end

  defp seed_continuation(state), do: state

  # Prefill and text continue the token stream itself, so a raw join is right. A nudged chat reply is a
  # separate utterance and gets SillyTavern's default `continue_postfix` space. The responder's own
  # `Name:` prefixes come out of the generated part only, never the continued message's text, and so
  # does a restart of the continued text's ending (`Overlap`). `done?` is false mid-stream, when a
  # possible restart is held back.
  defp full_content(state, done? \\ false)

  defp full_content(%{prefix: nil, content: content, own_name: own_name}, _done?),
    do: content && OwnName.strip(content, own_name)

  defp full_content(%{prefix: prefix, content: content, model: model, own_name: own_name}, done?) do
    spaced? = model.completion_mode == :chat and not model.continue_prefill
    new = OwnName.strip(content || "", own_name, spaced?)
    stitch(prefix, Overlap.trim(prefix, new, done?), spaced?)
  end

  defp stitch(prefix, "", _spaced?), do: prefix
  defp stitch(prefix, nil, _spaced?), do: prefix

  defp stitch(prefix, new, true) do
    if prefix =~ ~r/\s\z/ or new =~ ~r/\A\s/, do: prefix <> new, else: prefix <> " " <> new
  end

  defp stitch(prefix, new, false), do: prefix <> new

  defp full_reasoning(%{reasoning_base: nil, reasoning: reasoning}), do: reasoning
  defp full_reasoning(%{reasoning_base: base, reasoning: reasoning}) when reasoning in [nil, ""], do: base
  defp full_reasoning(%{reasoning_base: base, reasoning: reasoning}), do: base <> "\n\n" <> reasoning

  defp with_protected(state, built), do: %{state | protected: Protected.pairs(built.protected_values)}

  defp with_redactions(state),
    do: %{
      state
      | reasoning_redacted: redacted_reasoning(state),
        reasoning_share_redacted: share_redacted_reasoning(state)
    }

  # The reasoning a scope lacking `site.hidden.view` sees: `full_reasoning/1` with every protected
  # value of the build replaced by its label, over a continue source's own redacted reasoning. Nil
  # when neither this build nor the source protected anything, so readers fall back to `reasoning`.
  defp redacted_reasoning(state),
    do: scrubbed_reasoning(state, state.reasoning_redacted_base, Protected.hidden_pairs(state.protected, false))

  # What a `site.hidden.view` holder sees: only share-protected values scrubbed, since a share has no
  # admin bypass. Nil when neither this build nor the source had any.
  defp share_redacted_reasoning(state),
    do: scrubbed_reasoning(state, state.reasoning_share_redacted_base, Protected.hidden_pairs(state.protected, true))

  defp scrubbed_reasoning(_state, nil, []), do: nil

  defp scrubbed_reasoning(state, base, pairs) do
    case full_reasoning(%{state | reasoning_base: base || state.reasoning_base}) do
      nil -> nil
      reasoning -> Protected.scrub(reasoning, markdown_labels(pairs))
    end
  end

  # Chat reasoning renders as markdown, where a bare `[label]` would read as a link: escape the brackets.
  defp markdown_labels(pairs),
    do: Enum.map(pairs, fn {secret, label} -> {secret, String.replace(label, ["[", "]"], &("\\" <> &1))} end)

  defp job_tag(:new), do: :reply
  defp job_tag({:swipe, _message}), do: :regenerate
  defp job_tag({:continue, _message}), do: :continue
  defp job_tag({:refine, _message}), do: :refine

  defp job_label(:reply, name, false),
    do:
      dpgettext("chat", "heading: job that writes a character's reply", "Reply — %{character_name}",
        character_name: name
      )

  defp job_label(:reply, name, true),
    do:
      dpgettext(
        "chat",
        "heading: job that writes a character's reply, started by a script",
        "Reply — %{character_name} (script)", character_name: name)

  defp job_label(:regenerate, name, false),
    do:
      dpgettext("chat", "heading: job that regenerates a character's reply", "Regenerate — %{character_name}",
        character_name: name
      )

  defp job_label(:regenerate, name, true),
    do:
      dpgettext(
        "chat",
        "heading: job that regenerates a character's reply, started by a script",
        "Regenerate — %{character_name} (script)", character_name: name)

  defp job_label(:continue, name, false),
    do:
      dpgettext("chat", "heading: job that continues a character's reply", "Continue — %{character_name}",
        character_name: name
      )

  defp job_label(:continue, name, true),
    do:
      dpgettext(
        "chat",
        "heading: job that continues a character's reply, started by a script",
        "Continue — %{character_name} (script)", character_name: name)

  defp job_label(:refine, name, false),
    do:
      dpgettext("chat", "heading: job that rewrites a character's reply", "Refine — %{character_name}",
        character_name: name
      )

  defp job_label(:refine, name, true),
    do:
      dpgettext(
        "chat",
        "heading: job that rewrites a character's reply, started by a script",
        "Refine — %{character_name} (script)", character_name: name)

  defp mode_name(:new), do: "new"
  defp mode_name({:swipe, _message}), do: "regenerate"
  defp mode_name({:continue, _message}), do: "continue"
  defp mode_name({:refine, _message}), do: "refine"

  defp run_lore_scripts(_state, %{activated: []}), do: :ok

  # A book hidden from the replying scope is not announced to its scripts, by name or entry.
  defp run_lore_scripts(state, lore) do
    activated =
      if Visibility.view_hidden?(state.scope),
        do: lore.activated,
        else: Enum.reject(lore.activated, &Visibility.book_hidden?(&1.book))

    books =
      activated
      |> Enum.map(& &1.book)
      |> Enum.uniq_by(& &1.id)
      |> Enum.map(&%{"id" => &1.id, "name" => &1.name})

    entries = Enum.map(activated, &%{"id" => &1.entry.id, "name" => &1.entry.name, "book_id" => &1.book.id})

    Scripts.run(state.scope, :lore_activated, state.chat, %{
      "character_id" => state.character.id,
      "books" => books,
      "entries" => entries,
      "script_triggered" => state.script_triggered?
    })

    :ok
  end

  # Links the new swipe to the attachments sent with its guide or refine; a swipe of an existing
  # message is re-announced after the link, so tabs pick both up.
  defp target_body(state) do
    {message, body} = new_body(state)
    :ok = Attachments.link_body!(body, state.guide_attachments)

    case state.mode do
      :new -> {message, body}
      _swipe -> reannounce(state, message, body)
    end
  end

  defp new_body(%{mode: :new} = state) do
    {:ok, message} = Messages.create_generating_message(state.chat, state.character.id, state.guide)
    {message, List.first(message.bodies)}
  end

  defp new_body(%{mode: {:swipe, message}} = state) do
    {:ok, body} = Messages.add_generating_body(message, state.guide)
    {message, body}
  end

  defp new_body(%{mode: {:continue, message}} = state) do
    {:ok, body} = Messages.add_continuing_body(message, Message.active_body(message), state.guide)
    {message, body}
  end

  defp new_body(%{mode: {:refine, message}} = state) do
    {:ok, body} = Messages.add_refining_body(message, Message.active_body(message), state.refine)
    {message, body}
  end

  # Re-announcing the message, not `{:generation_finished, …}`: subscribers `stream_insert` it in
  # place and so pick up the new, empty active body.
  defp reannounce(state, message, body) do
    reloaded = Messages.get_message!(state.scope, message.id)
    Messages.broadcast_message_created(state.chat.id, reloaded)
    {reloaded, body}
  end

  defp error_message({:invalid_request, reason}) when reason in [:missing_messages, :missing_prompt],
    do: dgettext("chat", "The assembled prompt was empty.")

  # The connection's and the job queue's own reasons (`:canceled` → "Stopped.", `:timeout`,
  # `:no_tokens`, `:stalled`, `{:guard, …}`, HTTP and transport failures) share one wording.
  defp error_message(reason), do: Jobs.error_message(reason)

  defp http_body({:http_error, _status, body}), do: body
  defp http_body(_reason), do: nil
end
