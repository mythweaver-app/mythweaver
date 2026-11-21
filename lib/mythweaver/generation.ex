defmodule Mythweaver.Generation do
  @moduledoc """
  Sequences a reply: responder → prompt → lore → assembly → streamed completion → persisted message.

  Each chat has one `Mythweaver.Generation.Conductor`, registered under
  `Mythweaver.Generation.Registry`, that owns the reply queue and runs one
  `Mythweaver.Generation.Server` (one reply) at a time. A generation outlives the LiveView that
  asked for it, and queued replies never interleave in one transcript. Which characters reply after
  a player message, or on an auto-mode tick, is `Mythweaver.Generation.TurnPolicy`. Progress reaches
  every connected tab over `Mythweaver.Messages.topic/1`.

  Every public function takes the caller's `Mythweaver.Accounts.Scope` first and authorizes it on
  the chat (`Mythweaver.Chats.authorize/3`: `:generate` for replies and the queue, `:regenerate` for
  swipes, continues and refines, `:post` for `skip_turn/2`, `:manage` for auto mode and `cancel/2`,
  `:read` for the status).

  A reply runs as the chat's owner (`Mythweaver.Chats.run_scope/2`): the owner's models, prompts,
  lore, scripts and quota, whoever asked. The asker stays its initiator: its job is theirs and its
  notification goes to them.
  """

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.AI.Model
  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Characters
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Chats.Member
  alias Mythweaver.Generation.Conductor
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message
  alias Mythweaver.Permissions.Quota
  alias Mythweaver.Prompts

  @registry Mythweaver.Generation.Registry
  @supervisor Mythweaver.Generation.Supervisor
  @idle %{chat_id: nil, speaking: nil, queue: [], auto?: false, paused?: false}

  @doc """
  Queues a reply from `character` in `chat`, behind any reply already running or queued.

  `character` may be the player: the player's lines are usually typed, but asking for one lets the AI
  speak for them. Automatic turns (`respond/2`, auto mode) still never pick the player.

  Model and prompt are resolved first as a pre-flight, so a misconfiguration surfaces as an error the
  caller can flash rather than as a queued turn that fails later.

  opts: `:guide`, outline text for this generation only (blank is no guide). A guide on a prompt
  with no block that reads `anchors.guide` is refused with `:no_guide_block`, so it is never dropped
  silently. `:guide_attachments`: attachments of any kind sent with the guide for this generation
  only, linked to its swipe; refused like a guide on such a prompt. `:script`: `true` marks the generation as started
  by a Lua script; its scripts see `event.script_triggered`.
  """
  @spec generate(Scope.t(), Chat.t(), Character.t(), keyword()) ::
          :ok | {:error, :unauthorized | :no_model | :ambiguous_model | :no_prompt | :no_guide_block}
  def generate(%Scope{} = scope, %Chat{} = chat, %Character{} = character, opts \\ []) do
    guide = guide(opts)
    attachment_ids = guide_attachment_ids(opts)

    with :ok <- Chats.authorize(scope, chat, :generate),
         run_scope = Chats.run_scope(scope, chat),
         spend_scope = Chats.spend_scope(scope, chat, run_scope),
         {:ok, _opts} <- prepare(run_scope, chat, character, :new, guide, attachment_ids, spend_scope) do
      entry = %{
        character_id: character.id,
        mode: :new,
        guide: guide,
        guide_attachment_ids: attachment_ids,
        script?: Keyword.get(opts, :script, false),
        scope: scope
      }

      GenServer.call(conductor(chat.id), {:enqueue, [entry]})
    end
  end

  @doc """
  Runs the chat's reply strategy after a player message, queuing whoever it selects. With
  `turn_mode: :round` nobody is queued until every user holding a character lock has posted or
  skipped (`skip_turn/2`) since the last AI message.
  """
  @spec respond(Scope.t(), Chat.t()) :: :ok | {:error, :unauthorized}
  def respond(%Scope{} = scope, %Chat{} = chat) do
    with :ok <- Chats.authorize(scope, chat, :generate), do: GenServer.call(conductor(chat.id), {:respond, scope})
  end

  @doc """
  Passes the scope user's turn in a `turn_mode: :round` chat: the round counts them as having
  posted, and replies start once nobody else is awaited. The skip lives in the chat's conductor
  only (lost on restart) and ends with the round. A no-op in `:any` mode.
  """
  @spec skip_turn(Scope.t(), Chat.t()) :: :ok | {:error, :unauthorized}
  def skip_turn(%Scope{} = scope, %Chat{} = chat) do
    with :ok <- Chats.authorize(scope, chat, :post), do: GenServer.call(conductor(chat.id), {:skip, scope})
  end

  @doc """
  Regenerates `message` (the chat's newest) into a new active swipe, speaking as its original
  character author. An older message is refused with `:not_last`: everything after it was generated
  from the text being replaced. Refused with `:busy` while anything is running or queued, since a swipe
  of a message mid-round would race it.

  opts: `:guide`, outline text for this generation only (blank is no guide). `:guide_attachments`,
  `:script`: as for `generate/4`.
  """
  @spec regenerate(Scope.t(), Chat.t(), Message.t(), keyword()) ::
          :ok
          | {:error,
             :unauthorized
             | :busy
             | :no_model
             | :ambiguous_model
             | :no_prompt
             | :no_guide_block
             | :not_character_authored
             | :not_last}
  def regenerate(%Scope{} = scope, %Chat{} = chat, %Message{} = message, opts \\ []),
    do:
      request_swipe(
        scope,
        chat,
        message,
        :swipe,
        guide(opts),
        guide_attachment_ids(opts),
        Keyword.get(opts, :script, false)
      )

  @doc """
  Continues `message` (the chat's newest) as its author, player included, into a new active swipe
  holding the original text plus the continuation. Refused with `:busy` like `regenerate/4`.

  opts: `:guide`, outline text for this generation only (blank is no guide). `:guide_attachments`: as
  for `generate/4`.
  """
  @spec continue(Scope.t(), Chat.t(), Message.t(), keyword()) ::
          :ok
          | {:error,
             :unauthorized
             | :busy
             | :no_model
             | :ambiguous_model
             | :no_prompt
             | :no_guide_block
             | :not_character_authored
             | :not_last
             | :empty}
  def continue(%Scope{} = scope, %Chat{} = chat, %Message{} = message, opts \\ []),
    do: request_swipe(scope, chat, message, :continue, guide(opts), guide_attachment_ids(opts), false)

  @doc """
  Rewrites `message` (the chat's newest) into a new active swipe following the user's editing
  `instructions`. The chat's prompt renders the history without `message` plus `anchors.refine`
  (the instructions and `message`'s current text); a prompt with no block that reads it is refused
  with `:no_refine_block`. Refused with `:busy` like `regenerate/4`.

  opts: `:guide_attachments`, attachments of any kind sent with the instructions, linked to the
  new swipe; each adds its line to `anchors.refine.instructions`, and a model that takes its kind
  gets it as a part too.
  """
  @spec refine(Scope.t(), Chat.t(), Message.t(), String.t() | nil, keyword()) ::
          :ok
          | {:error,
             :unauthorized
             | :busy
             | :no_model
             | :ambiguous_model
             | :no_prompt
             | :no_refine_block
             | :not_character_authored
             | :not_last
             | :empty
             | :no_instructions}
  def refine(%Scope{} = scope, %Chat{} = chat, %Message{} = message, instructions, opts \\ []),
    do: request_swipe(scope, chat, message, :refine, guide(guide: instructions), guide_attachment_ids(opts), false)

  # Regenerate, continue and refine share their refusals and pre-flight; only the mode differs.
  # `text` is the guide, or a refine's instructions; `attachment_ids` the attachments sent with it.
  defp request_swipe(scope, chat, message, kind, text, attachment_ids, script?)
       when kind in [:swipe, :continue, :refine] do
    with :ok <- Chats.authorize(scope, chat, :regenerate),
         do: check_swipe(scope, chat, message, kind, text, attachment_ids, script?)
  end

  defp check_swipe(scope, chat, message, kind, text, attachment_ids, script?) do
    cond do
      not (message.author_is_character and message.author_character_id != nil) ->
        {:error, :not_character_authored}

      not Messages.last_message?(scope, message) ->
        {:error, :not_last}

      kind in [:continue, :refine] and String.trim(Message.active_content(message) || "") == "" ->
        {:error, :empty}

      kind == :refine and text == nil ->
        {:error, :no_instructions}

      true ->
        character = Characters.get_character!(message.author_character_id)
        run_scope = Chats.run_scope(scope, chat)
        spend_scope = Chats.spend_scope(scope, chat, run_scope)

        with {:ok, _opts} <- prepare(run_scope, chat, character, {kind, message}, text, attachment_ids, spend_scope) do
          GenServer.call(conductor(chat.id), {conductor_tag(kind), scope, message.id, text, attachment_ids, script?})
        end
    end
  end

  defp conductor_tag(:swipe), do: :regenerate
  defp conductor_tag(:continue), do: :continue
  defp conductor_tag(:refine), do: :refine

  @doc """
  Stops everything for `chat`: aborts the in-flight reply (keeping whatever already streamed), clears
  the queue and its pause, and turns auto mode off. Used when a chat is deleted; the UI's Stop is
  `stop/2`.
  """
  @spec cancel(Scope.t(), Chat.t()) :: :ok | {:error, :unauthorized | :not_generating}
  def cancel(%Scope{} = scope, %Chat{} = chat) do
    with :ok <- Chats.authorize(scope, chat, :manage), do: call_running(chat.id, :cancel)
  end

  @doc """
  Stops the reply in flight (keeping whatever already streamed), turns auto mode off, and pauses the
  queue with its order kept. `resume/2`, `generate/4` or `respond/2` starts it again.
  """
  @spec stop(Scope.t(), Chat.t()) :: :ok | {:error, :unauthorized | :not_generating}
  def stop(%Scope{} = scope, %Chat{} = chat) do
    with :ok <- Chats.authorize(scope, chat, :generate), do: call_running(chat.id, :stop)
  end

  @doc "Unpauses a queue left waiting by `stop/2` and starts its next entry."
  @spec resume(Scope.t(), Chat.t()) :: :ok | {:error, :unauthorized}
  def resume(%Scope{} = scope, %Chat{} = chat) do
    with :ok <- Chats.authorize(scope, chat, :generate), do: GenServer.call(conductor(chat.id), :resume)
  end

  @doc "Removes one waiting entry (by its queue id) from the chat's reply queue."
  @spec dequeue(Scope.t(), Chat.t(), pos_integer()) :: :ok | {:error, :unauthorized}
  def dequeue(%Scope{} = scope, %Chat{} = chat, entry_id) do
    with :ok <- Chats.authorize(scope, chat, :generate), do: GenServer.call(conductor(chat.id), {:dequeue, entry_id})
  end

  @doc "Empties the chat's reply queue without touching the reply in flight."
  @spec clear_queue(Scope.t(), Chat.t()) :: :ok | {:error, :unauthorized}
  def clear_queue(%Scope{} = scope, %Chat{} = chat) do
    with :ok <- Chats.authorize(scope, chat, :generate), do: GenServer.call(conductor(chat.id), :clear_queue)
  end

  @doc """
  Turns auto mode on or off: while on, bots keep replying every `chat.auto_mode_delay` seconds, with
  `scope` as the initiator of every tick's replies.
  """
  @spec set_auto(Scope.t(), Chat.t(), boolean()) :: :ok | {:error, :unauthorized}
  def set_auto(%Scope{} = scope, %Chat{} = chat, on?) when is_boolean(on?) do
    with :ok <- Chats.authorize(scope, chat, :manage), do: GenServer.call(conductor(chat.id), {:set_auto, scope, on?})
  end

  @doc """
  Who is speaking, who is queued, and whether auto mode is on: the `{:turn_state, _}` payload.
  Raises `Mythweaver.UnauthorizedError` unless the scope may read `chat`.
  """
  @spec status(Scope.t(), Chat.t()) :: Conductor.status()
  def status(%Scope{} = scope, %Chat{} = chat) do
    authorize!(scope, chat)

    case lookup(chat.id) do
      nil -> @idle
      pid -> GenServer.call(pid, :status)
    end
  end

  @doc "Whether a reply is currently being generated for `chat`. Raises like `status/2`."
  @spec generating?(Scope.t(), Chat.t()) :: boolean()
  def generating?(%Scope{} = scope, %Chat{} = chat), do: status(scope, chat).speaking != nil

  @doc """
  The model `character` speaks with in `chat`. For a member whose `model_source` is `:own`
  (`Mythweaver.Chats.Member`), their own per-chat pick, else their `AI.default_model/1`; the chat's
  and participants' models are the owner's and are ignored, and reading the chat is enough (an
  attach-only guest still captions). Otherwise most specific rung first: the participant's own
  override, then the chat's, then `AI.default_model/1` (the `ai.default_model` setting, else the
  single reachable model `scope` may run). A rung naming a model `scope` may not run
  (`AI.usable?/2`: another user's, or a site model the settings withhold) counts as unset.
  """
  @spec model_for(Scope.t(), Chat.t(), Character.t()) ::
          {:ok, Model.t()} | {:error, :unauthorized | :no_model | :ambiguous_model}
  def model_for(%Scope{} = scope, %Chat{} = chat, %Character{} = character), do: model_resolver(scope, chat).(character)

  @doc """
  `model_for/3` for any number of `chat`'s characters: reads the scope's member row and checks
  access once, then resolves each character like `model_for/3`. An `:own` member's model is the
  same for every character, so it is resolved once too.
  """
  @spec model_resolver(Scope.t(), Chat.t()) ::
          (Character.t() -> {:ok, Model.t()} | {:error, :unauthorized | :no_model | :ambiguous_model})
  def model_resolver(%Scope{} = scope, %Chat{} = chat) do
    case Chats.member_for(scope, chat) do
      %Member{model_source: :own} = member ->
        result = own_model(scope, chat, member)
        fn %Character{} -> result end

      _ ->
        case Chats.authorize(scope, chat, :generate) do
          :ok -> &chat_model(scope, chat, &1)
          error -> fn %Character{} -> error end
        end
    end
  end

  defp own_model(scope, chat, member) do
    with :ok <- Chats.authorize(scope, chat, :read) do
      model = member.ai_model_id && AI.get_model(scope, member.ai_model_id)

      if model && model.completion_mode in Model.text_modes(),
        do: {:ok, model},
        else: AI.default_model(scope)
    end
  end

  defp chat_model(scope, chat, %Character{} = character) do
    participant = Enum.find(chat.participants, &(&1.character_id == character.id))

    cond do
      participant && participant.ai_model_id && AI.usable?(scope, participant.model) -> {:ok, participant.model}
      chat.ai_model_id && AI.usable?(scope, chat.model) -> {:ok, chat.model}
      true -> AI.default_model(scope)
    end
  end

  @doc false
  # The Server's start options, or the reason a reply cannot start. Shared by the pre-flight here
  # and the conductor's actual start. `scope` is the scope the reply runs as (`Chats.run_scope/2`);
  # `text` is the guide, or for a refine its instructions; `attachment_ids` the attachments sent with it;
  # `spend_scope` (`Chats.spend_scope/2`) is whose models, keys and quota the reply spends.
  @spec prepare(
          Scope.t(),
          Chat.t(),
          Character.t(),
          :new | {:swipe, Message.t()} | {:continue, Message.t()} | {:refine, Message.t()},
          String.t() | nil,
          [Ecto.UUID.t()],
          Scope.t()
        ) ::
          {:ok, keyword()}
          | {:error,
             :unauthorized
             | :no_model
             | :ambiguous_model
             | :quota_exceeded
             | :no_prompt
             | :no_guide_block
             | :no_refine_block}
  def prepare(%Scope{} = scope, chat, character, mode, text, attachment_ids, %Scope{} = spend_scope) do
    with {:ok, model} <- model_for(spend_scope, chat, character),
         :ok <- Quota.check_spend(spend_scope, model, AI.run_owner(spend_scope, chat)),
         {:ok, prompt} <- resolve_prompt(chat, character, model) do
      opts = [
        scope: scope,
        spend_scope: spend_scope,
        chat: chat,
        character: character,
        prompt: prompt,
        model: model,
        mode: mode
      ]

      case mode do
        {:refine, _message} ->
          if reads_anchor?(prompt, "anchors.refine"),
            do: {:ok, opts ++ [guide: nil, guide_attachment_ids: attachment_ids, refine: text]},
            else: {:error, :no_refine_block}

        _mode ->
          if (text != nil or attachment_ids != []) and not reads_anchor?(prompt, "anchors.guide"),
            do: {:error, :no_guide_block},
            else: {:ok, opts ++ [guide: text, guide_attachment_ids: attachment_ids]}
      end
    end
  end

  # Blank is no guide; otherwise the text is kept as typed.
  defp guide(opts) do
    case Keyword.get(opts, :guide) do
      nil -> nil
      text -> if String.trim(text) != "", do: text
    end
  end

  defp guide_attachment_ids(opts),
    do: for(%Attachment{status: :ready, id: id} <- Keyword.get(opts, :guide_attachments, []), do: id)

  defp reads_anchor?(prompt, anchor) do
    Enum.any?(
      prompt.prompt_blocks,
      &(&1.enabled and &1.block.enabled and &1.block.kind == :template and
          String.contains?(&1.block.content || "", anchor))
    )
  end

  defp authorize!(scope, chat) do
    with {:error, :unauthorized} <- Chats.authorize(scope, chat, :read), do: raise(Mythweaver.UnauthorizedError)
  end

  defp lookup(chat_id) do
    case Registry.lookup(@registry, chat_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  # A call to the chat's conductor only when one is running: nothing to stop otherwise.
  defp call_running(chat_id, request) do
    case lookup(chat_id) do
      nil -> {:error, :not_generating}
      pid -> GenServer.call(pid, request)
    end
  end

  defp conductor(chat_id) do
    with nil <- lookup(chat_id) do
      case DynamicSupervisor.start_child(@supervisor, {Conductor, chat_id: chat_id}) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end
    end
  end

  defp resolve_prompt(chat, character, model) do
    case Prompts.resolve_prompt(%{chat: chat, character: character, model: model}) do
      nil -> {:error, :no_prompt}
      prompt -> {:ok, prompt}
    end
  end
end
