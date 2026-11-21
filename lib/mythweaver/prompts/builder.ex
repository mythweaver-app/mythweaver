defmodule Mythweaver.Prompts.Builder do
  @moduledoc """
  Builds one prompt for one model. It is the only prompt builder in this app.

  There is deliberately no text-completion builder and no chat-completion builder. A prompt is an
  ordered list of resolved segments; `render/3` is the *only* place the two wire formats diverge, and
  it diverges in ten lines. SillyTavern maintains two full assemblers (`openai.js` for role-bearing
  messages, `script.js` for a flat story string) and their behavior drifts; AikoBots resolved the same
  duplication by deleting text completion outright. Neither is acceptable here: the user picks a model,
  not a builder, so `Mythweaver.AI.Model.completion_mode` alone decides the shape.

  The output is exactly what `Mythweaver.AI.stream/3` and `Mythweaver.Jobs.stream_async/4` accept:
  `%{messages: [%Mythweaver.AI.Request.Message{}]}` for a `:chat` model, `%{prompt: "..."}` for a
  `:text` model. Nothing in the AI layer changes to support prompts.

  Templates (`Mythweaver.Templates`) render here with one `Mythweaver.Templates.State` threaded
  through, so a variable written or `assign`ed early is visible later. Before any block, every
  participant's and the player's description renders once (seeing raw descriptions), then every
  activated lore entry (seeing rendered descriptions), built-in slots in `Lore.Settings.slots/0` order
  and then custom outlets by key; their output becomes `anchors.*.description`, `anchors.lore.<slot>`
  and `outlets.<key>`. Each slot's chat injections (`Mythweaver.Injections`) render right after that
  slot's lore and join it. The `at_depth` slot is never an anchor: its lore and injections go inside
  the chat-history segment, SillyTavern-style, `depth` lines from its end. Then only template blocks
  render. Chat history and continued text are stored, already-final text and never render. With a
  context limit (`Mythweaver.Prompts.ContextLimit`), chat history keeps its newest turns that fit after
  everything else and the reply reserve. Lore *matching* still scans raw `entry.content`; only the
  injected text is rendered. `build/2` returns the final state, whose variable writes only
  `Mythweaver.Generation.Server` commits, so inspecting a prompt changes nothing.

  Protected lore (a forced, content-hidden or share-protected book's,
  `Mythweaver.Sharing.Visibility.protected_for?/2` for the chat owner) and a protected character's
  description and appearance reach templates only as a `Mythweaver.Sharing.Protected` token,
  swapped back for its text once every block has rendered, so no template can transform or copy it.
  A role-play prompt also carries every forced entry no block placed, in one `:forced_lore` system
  segment at the top.

  `render_user_text/4` is the send-time path: a human-typed message renders once against the same
  prepared descriptions and lore, with its author as `anchors.character`, read-only, and its output is
  what gets stored.
  """

  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI.Model
  alias Mythweaver.AI.Request
  alias Mythweaver.Attachments
  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Injections
  alias Mythweaver.Injections.Injection
  alias Mythweaver.Lore.Activation
  alias Mythweaver.Lore.Settings
  alias Mythweaver.Memory
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message
  alias Mythweaver.Prompts.Anchor
  alias Mythweaver.Prompts.AttachmentRef
  alias Mythweaver.Prompts.ContextLimit
  alias Mythweaver.Prompts.Prompt
  alias Mythweaver.Prompts.Standard
  alias Mythweaver.Prompts.Transcript
  alias Mythweaver.Schema
  alias Mythweaver.Sharing
  alias Mythweaver.Sharing.Protected
  alias Mythweaver.Sharing.Visibility
  alias Mythweaver.Templates
  alias Mythweaver.Variables

  @type segment :: %{
          role: :system | :user | :assistant,
          content: String.t(),
          block_id: Ecto.UUID.t() | nil,
          source: :template | :chat_history | :forced_lore,
          turns:
            [
              %{
                required(:role) => :user | :assistant,
                required(:content) => String.t(),
                optional(:images) => [Attachment.t()]
              }
            ]
            | nil,
          errors: [String.t()]
        }

  @type lore_render :: %{
          optional(Ecto.UUID.t()) => %{text: String.t(), errors: [String.t()], placed: boolean()}
        }

  @type depth_item :: %{depth: non_neg_integer(), role: :system | :user | :assistant, content: String.t()}

  @typedoc "What became of one injection. `depth`/`role` are set only for `:at_depth` injections."
  @type injection_report :: %{
          id: Ecto.UUID.t(),
          key: String.t(),
          position: atom(),
          depth: non_neg_integer() | nil,
          role: :system | :user | :assistant | nil,
          status: :applied | :disabled | :spent | :condition_false | :not_placed,
          text: String.t() | nil,
          errors: [String.t()]
        }

  @type built :: %{
          segments: [segment()],
          state: Templates.State.t(),
          lore: lore_render(),
          errors: [String.t()],
          injections: [injection_report()],
          context: ContextLimit.report() | nil,
          owner_id: Ecto.UUID.t() | nil,
          protected_values: [%{label: String.t(), text: String.t(), source: :site | :share}]
        }

  # SillyTavern's `default_continue_nudge_prompt`, verbatim.
  @continue_nudge "[Continue your last message without repeating its original content.]"

  @doc """
  The resolved, ordered, non-empty segments of `prompt` under `context`; `build/2` without its state.
  """
  @spec segments(Prompt.t(), Anchor.context()) :: [segment()]
  def segments(%Prompt{} = prompt, context), do: build(prompt, context).segments

  @doc """
  Builds `prompt` under `context`.

  Descriptions, then lore, render once before any block (see the moduledoc). Returns:

    * `segments`: the resolved, ordered, non-empty segments. Skips a block whose `enabled` is false,
      whose membership `enabled` is false, and any block that renders blank (an empty lore slot or an
      unset character field must not emit a stray blank system message)
    * `state`: the template state after the last template rendered
    * `lore`: each activated entry's rendered text and errors, by entry id; `placed: false` for an
      `at_depth` entry when no chat-history block takes it
    * `errors`: description render errors
    * `injections`: one report per context injection, in slot order: applied, or why it was skipped.
      An applied `at_depth` injection with no chat-history block to land in is `:not_placed`
    * `context`: the context-limit fit (`Mythweaver.Prompts.ContextLimit.report/0`), or `nil` when
      the context carries no `:context_limit`
    * `owner_id`: the chat owner the build protected values for (the context's `:owner_id`)
    * `protected_values`: every protected value the build revealed or emitted, labelled for
      `Mythweaver.Sharing.Protected.scrub/2`: a runtime-only site or share-protected character's
      description and appearance, a content-hidden or share-protected book's rendered entries, and
      the text of each section whose block is hidden in `prompt` (`block_source/3`). `source` is
      `:share` when the value is share-protected for the chat owner
      (`Mythweaver.Sharing.Visibility.share_protected?/2`), shown to no viewer, else `:site`, shown
      to `site.hidden.view` holders. `[]` when nothing is protected

  A template that fails to render falls back to its raw text and reports its errors; it never fails
  the build.
  """
  @spec build(Prompt.t(), Anchor.context()) :: built()
  def build(%Prompt{} = prompt, context) do
    state =
      Map.get(context, :templates) ||
        Templates.State.new(%{"anchors" => %{"lore" => %{}}, "outlets" => %{}}, %{chat: %{}, global: %{}}, nil)

    rendered =
      prompt.prompt_blocks
      |> Enum.sort_by(& &1.position)
      |> Enum.filter(&(&1.enabled and &1.block.enabled))
      |> drop_toggled_off(Map.get(context, :owner_id))

    context = Map.put(context, :card_prompts, card_prompt_plan(prompt, rendered, context))
    {state, lore_render, errors, depth_items, reports, protected, labels} = prepare(context, state)

    {segments, {state, protected, labels}} =
      Enum.map_reduce(rendered, {state, protected, labels}, &segment(&1.block, &2, context))

    history_modes = for %{source: :chat_history, turns: mode} <- segments, do: mode
    history? = history_modes != []

    # Templates saw only tokens for protected lore and characters; now every template is done, the
    # text goes back in.
    placed = placed_ids(segments, depth_items, history?)
    segments = Enum.map(segments, &reveal_segment(&1, protected))
    depth_items = Enum.map(depth_items, &%{&1 | content: Protected.reveal(&1.content, protected)})
    reports = Enum.map(reports, &reveal_report(&1, protected))

    {segments, lore_render, forced_ids} = forced_fallback(prompt, context, placed, history?, segments, lore_render)

    history = history(context, Enum.uniq(history_modes))
    {kept, report} = fit_history(segments, history, history_modes, depth_items, context)
    segments = Enum.map(segments, &fill_history(&1, history, kept, depth_items))

    {lore_render, reports} =
      if history?,
        do: {lore_render, reports},
        else: unplace_depth(context, lore_render, reports, forced_ids)

    segments = Enum.reject(segments, &(String.trim(&1.content) == ""))

    %{
      segments: segments,
      state: state,
      lore: lore_render,
      errors: errors,
      injections: reports,
      context: report,
      owner_id: Map.get(context, :owner_id),
      protected_values: protected_values(protected, labels, prompt, segments, Map.get(context, :owner_id))
    }
  end

  # The chat owner's subscriber toggles (`Mythweaver.Sharing.set_toggle/3`): a block they don't own
  # and switched off leaves the build.
  defp drop_toggled_off(memberships, owner_id) do
    ids = for %{block: %{user_id: u, id: id}} <- memberships, u != owner_id, uniq: true, do: id
    off = Sharing.toggles(owner_id, :block, ids)
    Enum.reject(memberships, &(Map.get(off, &1.block.id) == false and &1.block.user_id != owner_id))
  end

  # Where the responder's card prompts go, SillyTavern-style: `%{main: plan, post_history: plan}`,
  # each `{:replace, block_id, text}` (the first block tagged with that `role_tag`, when it renders
  # and doesn't forbid overrides), `{:add, text}` (the prompt has no tagged block, or the character
  # says `:add`: the text joins the lore slots) or nil (the tagged block is off or forbids it, so
  # the card's text is unused). `rendered` is the prompt's memberships that render. Only a
  # role-play prompt carries card text; a caption or memory prompt never does.
  defp card_prompt_plan(%Prompt{purpose: :roleplay} = prompt, rendered, context) do
    case card_texts(Map.get(context, :character)) do
      [] ->
        %{}

      texts ->
        character = context.character
        memberships = Enum.sort_by(prompt.prompt_blocks, & &1.position)
        rendering = MapSet.new(rendered, & &1.block.id)

        Map.new(texts, fn {tag, text} ->
          plan =
            case Enum.find(memberships, &(&1.block.role_tag == tag)) do
              _any when character.card_prompt_mode == :add ->
                {:add, text}

              nil ->
                {:add, text}

              %{block: block} ->
                if(MapSet.member?(rendering, block.id) and not block.forbid_overrides, do: {:replace, block.id, text})
            end

          {tag, plan}
        end)
    end
  end

  defp card_prompt_plan(_prompt, _rendered, _context), do: %{}

  # The responder's non-blank card prompts, `[{tag, text}]`.
  defp card_texts(%Character{} = character) do
    for {tag, field} <- [main: :system_prompt, post_history: :post_history_instructions],
        text = Map.get(character, field),
        is_binary(text) and String.trim(text) != "",
        do: {tag, text}
  end

  defp card_texts(_none), do: []

  # A protected responder's card prompt goes in as a token, like its description.
  defp protect_card_text("", _label, _context, protected, labels), do: {"", protected, labels}

  defp protect_card_text(text, label, context, protected, labels) do
    character = Map.get(context, :character)

    if Map.has_key?(Map.get(context, :character_tokens, %{}), character.id) do
      id = Schema.generate_id()
      source = label_source(character, Map.get(context, :owner_id))

      {Protected.token(id), Map.put(protected, id, Protected.reveal(text, protected)),
       Map.put(labels, id, {"[Hidden: #{character.name}'s #{label}]", source})}
    else
      {text, protected, labels}
    end
  end

  @card_prompt_labels %{main: "system prompt", post_history: "post-history instructions"}

  # Each labelled protected value, then the text of every template section whose block is hidden in
  # `prompt` for the chat owner; chat history is what was said, never the block's content.
  defp protected_values(protected, labels, prompt, segments, owner_id) do
    hidden =
      for %{block: block} <- prompt.prompt_blocks,
          source = block_source(block, prompt, owner_id),
          into: %{},
          do: {block.id, {block.name, source}}

    values =
      for {id, {label, source}} <- labels,
          text = Map.get(protected, id),
          is_binary(text) and String.trim(text) != "",
          do: %{label: label, text: text, source: source}

    sections =
      for %{source: :template, block_id: block_id, content: content} <- segments,
          {name, source} = Map.get(hidden, block_id, {nil, nil}),
          source != nil,
          do: %{label: hidden_block_label(name), text: content, source: source}

    Enum.uniq(values ++ sections)
  end

  @doc """
  Whether `block`'s content is hidden in `prompt` when it builds for `owner_id`'s chat, and by whose
  rule: `:share` when the block or the prompt is share-protected for the owner
  (`Mythweaver.Sharing.Visibility.share_protected?/2`), `:site` when either is content-hidden, else nil.
  """
  @spec block_source(struct(), Prompt.t() | nil, Ecto.UUID.t() | nil) :: :share | :site | nil
  def block_source(block, prompt, owner_id) do
    share? = fn row -> row != nil and Visibility.share_protected?(row, owner_id) end

    cond do
      share?.(block) or share?.(prompt) ->
        :share

      Visibility.block_hidden_for?(nil, block, prompt) ->
        :site

      true ->
        nil
    end
  end

  # The protected entries a template or (with a chat-history block to land in) a depth item placed.
  defp placed_ids(segments, depth_items, history?) do
    from_templates = for %{source: :template, content: content} <- segments, do: Protected.ids(content)
    from_depth = if history?, do: Enum.map(depth_items, &Protected.ids(&1.content)), else: []
    Enum.reduce(from_templates ++ from_depth, MapSet.new(), &MapSet.union/2)
  end

  defp reveal_segment(%{source: :template} = segment, protected),
    do: %{segment | content: Protected.reveal(segment.content, protected)}

  defp reveal_segment(segment, _protected), do: segment

  defp reveal_report(%{text: text} = report, protected) when is_binary(text),
    do: %{report | text: Protected.reveal(text, protected)}

  defp reveal_report(report, _protected), do: report

  # A role-play reply always carries forced lore. Whatever no block placed (an anchor or outlet no
  # template reads, or `at_depth` lore with no chat history to land in) goes into one system segment
  # at the top. `{segments, lore_render, ids}`: `ids` are the entries it took, empty when none.
  defp forced_fallback(%Prompt{purpose: :roleplay}, context, placed, history?, segments, lore_render) do
    unplaced =
      for decision <- Map.get(Map.get(context, :lore) || %{}, :activated, []),
          decision.book.forced,
          if(decision.slot == "at_depth", do: not history?, else: decision.entry.id not in placed),
          text = get_in(lore_render, [decision.entry.id, :text]),
          text not in [nil, ""],
          do: {decision.entry.id, text}

    case unplaced do
      [] ->
        {segments, lore_render, MapSet.new()}

      unplaced ->
        segment = %{
          role: :system,
          block_id: nil,
          source: :forced_lore,
          content: Enum.map_join(unplaced, "\n", &elem(&1, 1)),
          turns: nil,
          errors: []
        }

        ids = MapSet.new(unplaced, &elem(&1, 0))
        lore_render = Enum.reduce(ids, lore_render, fn id, acc -> Map.update!(acc, id, &%{&1 | placed: true}) end)
        {[segment | segments], lore_render, ids}
    end
  end

  defp forced_fallback(_prompt, _context, _placed, _history?, segments, lore_render),
    do: {segments, lore_render, MapSet.new()}

  # Chat history is what was said, never a template: its stored text is already final. The lines and
  # each speaker-roles mode's turns come from `Transcript.entries/3`'s filter, so they all have equal
  # length and order. `reply` is the reply message's own media (`Transcript.reply_media/2`), or nil.
  defp history(_context, []), do: %{lines: [], turns: %{}, reply: nil}

  defp history(context, modes) do
    messages = context |> Map.get(:messages, []) |> List.wrap()
    caption_template = Map.get(context, :caption_template)

    player_id =
      case Map.get(context, :chat) do
        %Chat{player_character_id: id} -> id
        _ -> nil
      end

    inline_limits = Map.get(context, :inline_limits, %{})
    # The reply's media counts toward the limits as the newest message.
    within = Transcript.within_limits(messages ++ List.wrap(Map.get(context, :reply)), inline_limits)

    media = [
      attach_images: Map.get(context, :attach_images, false),
      inline_limits: inline_limits,
      within: within,
      attach_files: Map.get(context, :attach_files, false),
      attach_audio: Map.get(context, :attach_audio, false),
      attach_video: Map.get(context, :attach_video, false),
      caption_template: caption_template
    ]

    %{
      lines: Transcript.lines(messages, Keyword.take(media, [:caption_template, :inline_limits, :within])),
      turns:
        Map.new(modes, fn mode ->
          {mode,
           Transcript.turns(
             messages,
             Map.get(context, :character),
             media ++ [speaker_roles: mode, player_id: player_id]
           )}
        end),
      reply: Transcript.reply_media(Map.get(context, :reply), media)
    }
  end

  # `{kept, report}`: how many of the newest history entries go out. Without a limit, all of them. With
  # one, template blocks, depth items and the reply's media (once per history segment, as they are
  # inserted) and the continue/cue tail are fixed, and history fills what is left. An entry costs what
  # every history segment sends of it, in that segment's speaker roles.
  defp fit_history(segments, history, modes, depth_items, context) do
    case Map.get(context, :context_limit) do
      nil ->
        {length(history.lines), nil}

      %ContextLimit{model: model} = cl ->
        reply_texts =
          case {history.reply, model.completion_mode} do
            {nil, _mode} -> []
            {%{turn: turn}, :chat} -> for _mode <- modes, do: turn.content
            {%{line: line}, :text} -> for _mode <- modes, do: line
          end

        fixed_texts =
          for(%{source: source, content: content} <- segments, source in [:template, :forced_lore], do: content) ++
            for(_mode <- modes, item <- depth_items, do: item.content) ++
            reply_texts ++
            tail_texts(model, context)

        copies =
          case model.completion_mode do
            :chat -> Enum.map(modes, &Map.fetch!(history.turns, &1))
            :text -> Enum.map(modes, fn _mode -> Enum.map(history.lines, &%{content: &1}) end)
          end

        entries =
          Enum.zip_with(copies, fn sent ->
            %{
              content: Enum.map_join(sent, "\n", & &1.content),
              images: Enum.flat_map(sent, &Map.get(&1, :images, [])),
              files: Enum.flat_map(sent, &Map.get(&1, :files, []))
            }
          end)

        fixed_attachments =
          case model.completion_mode do
            :chat ->
              reply_parts =
                case history.reply do
                  nil -> []
                  %{turn: turn} -> Map.get(turn, :images, []) ++ Map.get(turn, :files, [])
                end

              native_guide_attachments(context) ++
                for(_mode <- modes, a <- reply_parts, do: a)

            :text ->
              []
          end

        ContextLimit.fit(cl, fixed_texts, entries, fixed_attachments)
    end
  end

  defp tail_texts(%Model{completion_mode: :chat} = model, context),
    do: model |> chat_tail(context) |> Enum.map(& &1.content)

  defp tail_texts(%Model{completion_mode: :text}, context), do: [text_tail(context)]

  # `at_depth` lore and injections land between the kept lines, counted from the end of what is kept.
  # The reply's own media go last, directly before the reply.
  defp fill_history(%{source: :chat_history, turns: mode} = segment, history, kept, depth_items) do
    %{
      segment
      | content:
          history.lines
          |> Enum.take(-kept)
          |> insert_at_depth(depth_items, & &1.content)
          |> append_reply(history.reply, & &1.line)
          |> Enum.join("\n"),
        turns:
          history.turns
          |> Map.fetch!(mode)
          |> Enum.take(-kept)
          |> insert_at_depth(depth_items, &%{role: &1.role, content: &1.content})
          |> append_reply(history.reply, & &1.turn)
    }
  end

  defp fill_history(segment, _history, _kept, _depth_items), do: segment

  defp append_reply(items, nil, _pick), do: items
  defp append_reply(items, reply, pick), do: items ++ [pick.(reply)]

  # No chat-history block: `at_depth` content had nowhere to go, unless forced lore took it.
  defp unplace_depth(context, lore_render, reports, forced_ids) do
    lore_render =
      context
      |> slot_decisions("at_depth")
      |> Enum.reject(&(&1.entry.id in forced_ids))
      |> Enum.reduce(lore_render, fn decision, acc ->
        Map.replace_lazy(acc, decision.entry.id, &%{&1 | placed: false})
      end)

    reports =
      Enum.map(reports, fn
        %{position: :at_depth, status: :applied} = report -> %{report | status: :not_placed}
        report -> report
      end)

    {lore_render, reports}
  end

  @doc """
  Renders human-typed message text once, for storing in place of the template.

  `anchors.character` is the message's author, looked up among the chat's participants by
  `author_id` (`nil` when there is none or it is not a participant), never the default responder: a
  message saying `{{ anchors.character.name }}` names whoever is speaking. The `char` alias names the
  AI character instead, as SillyTavern's `{{char}}` does: the author when a non-player participant
  speaks, else the first participant character who isn't the player (`Chat.responder/1`), else nil.

  Text with no Liquid markup returns untouched without building a context. Otherwise it renders against
  `context/3` (lore resolved with `commit: false`) after the same description and lore pass `build/2`
  runs. Message templates are read-only: their variable writes are discarded and reported as a notice.
  A render error is `{:error, message}`, so the caller can refuse to save rather than store the raw
  template. `{:error, :unauthorized}` when `scope` may not act on `chat`.
  """
  @spec render_user_text(Scope.t(), Chat.t(), Ecto.UUID.t() | nil, String.t()) ::
          {:ok, String.t(), [String.t()]} | {:error, String.t() | :unauthorized}
  def render_user_text(%Scope{} = scope, %Chat{} = chat, author_id, source) do
    with :ok <- Chats.authorize(scope, chat, :post) do
      if Templates.template?(source),
        do: render_template_text(scope, chat, author_id, source),
        else: {:ok, source, []}
    end
  end

  @doc """
  `render_user_text/4` for several texts by one author, sharing one context: each renders against the
  same state (writes discarded, no notices). Plain texts return untouched without a context. The
  first render error is `{:error, message}`.
  """
  @spec render_texts(Scope.t(), Chat.t(), Ecto.UUID.t() | nil, [String.t()]) ::
          {:ok, [String.t()]} | {:error, String.t() | :unauthorized}
  def render_texts(%Scope{} = scope, %Chat{} = chat, author_id, sources) do
    with :ok <- Chats.authorize(scope, chat, :post) do
      if Enum.any?(sources, &Templates.template?/1),
        do: render_all(message_state(scope, chat, author_id), sources),
        else: {:ok, sources}
    end
  end

  defp render_all(state, sources) do
    sources
    |> Enum.reduce_while([], fn source, acc ->
      case render_message(source, state) do
        {:ok, text, _state} -> {:cont, [text | acc]}
        {:error, _message} = error -> {:halt, error}
      end
    end)
    |> case do
      {:error, _message} = error -> error
      texts -> {:ok, Enum.reverse(texts)}
    end
  end

  defp render_template_text(scope, chat, author_id, source) do
    state = message_state(scope, chat, author_id)

    with {:ok, text, after_state} <- render_message(source, state) do
      notices =
        if length(after_state.writes) > length(state.writes),
          do: [dgettext("prompts", "Variable writes in messages are ignored.")],
          else: []

      {:ok, text, notices}
    end
  end

  # Quoted protected lore or character text is saved as neither its token nor its text.
  defp render_message(source, state) do
    case Templates.render(source, state) do
      {text, after_state, []} -> {:ok, Protected.strip(text), after_state}
      {_text, _state, errors} -> {:error, Enum.join(errors, "; ")}
    end
  end

  # The state a message by `author_id` renders against: `context/3` after the description and lore pass.
  defp message_state(scope, chat, author_id) do
    author = participant(chat, author_id)
    context = context(scope, chat, character: author)
    {state, _lore, _errors, _depth_items, _reports, _protected, _labels} = prepare(context, context.templates)
    %{state | data: Map.put(state.data, "char", message_char(chat, author))}
  end

  defp message_char(%Chat{} = chat, author) do
    case author do
      %Character{id: id, name: name} when id != chat.player_character_id -> name
      _ -> with %Character{name: name} <- Chat.responder(chat), do: name
    end
  end

  defp participant(_chat, nil), do: nil

  defp participant(%Chat{} = chat, id) do
    chat
    |> Chat.characters()
    |> Enum.find(&match?(%Character{id: ^id}, &1))
  end

  @doc """
  `segments/2` rendered for `model`.

  `:chat` → `%{messages: [%Request.Message{}]}`, adjacent same-role segments joined with `"\\n"` so a run
  of system blocks becomes one system message rather than six. The `:chat_history` segment expands into
  one message per turn (the responder's lines as bare `assistant`, everyone else's as `user` prefixed
  `"Name: "`), and those turns join the same same-role-run squash.

  `:text` → `%{prompt: binary}`, every segment's content joined with `"\\n\\n"` and roles dropped; history
  stays flat `"Name: line"` rows. Roles carry no meaning in a flat completion, and inventing `"System:"`
  prefixes would put words in the model's mouth that the user never typed. The prompt ends with a
  `"\\n\\nResponder:"` cue when there is a responding character: a flat prompt that ends on an instruction
  gives the model no turn to take, and it stops immediately with an empty completion.

  Continuing (`context.continue` set): in `:chat` the continued text is a trailing `assistant` turn,
  followed by a system nudge unless `model.continue_prefill` asks for a raw prefill. In `:text` the
  prompt ends on `"\\n\\nResponder: text"` with no closing cue, so the model extends the line itself.
  """
  @spec render(Prompt.t(), Model.t(), Anchor.context()) ::
          %{messages: [Request.Message.t()]} | %{prompt: String.t()}
  def render(%Prompt{} = prompt, %Model{} = model, context),
    do: render_segments(segments(prompt, context), model, context)

  @doc """
  `render/3` from already-resolved `segments/2` output, for callers that also need the resolved
  segments, so anchors resolve once.
  """
  @spec render_segments([segment()], Model.t(), Anchor.context()) ::
          %{messages: [Request.Message.t()]} | %{prompt: String.t()}
  def render_segments(resolved, %Model{} = model, context) do
    case model.completion_mode do
      :chat -> %{messages: resolved |> messages(chat_tail(model, context)) |> put_guide_attachments(context)}
      :text -> %{prompt: Enum.map_join(resolved, "\n\n", & &1.content) <> text_tail(context)}
    end
  end

  defp chat_tail(model, context) do
    case Map.get(context, :continue) do
      nil -> []
      text when model.continue_prefill -> [%{role: :assistant, content: text}]
      text -> [%{role: :assistant, content: text}, %{role: :system, content: @continue_nudge}]
    end
  end

  # The guide's attachments that the model takes natively ride on the prompt's last user turn.
  defp put_guide_attachments(messages, context) do
    case native_guide_attachments(context) do
      [] ->
        messages

      native ->
        refs = Enum.map(native, &%AttachmentRef{attachment: &1})

        case last_index(messages, :user) do
          nil -> insert_attachment_turn(messages, refs, Map.get(context, :continue))
          i -> List.update_at(messages, i, fn m -> %{m | content: content_parts(m.content) ++ refs} end)
        end
    end
  end

  defp native_guide_attachments(context),
    do: Enum.filter(Map.get(context, :guide_attachments, []), &Transcript.native?(&1, context))

  defp content_parts(""), do: []
  defp content_parts(text) when is_binary(text), do: [%Request.Text{text: text}]
  defp content_parts(parts) when is_list(parts), do: parts

  # No user turn: a new one at the end, or before a continue's trailing assistant text.
  defp insert_attachment_turn(messages, refs, nil), do: messages ++ [%Request.Message{role: :user, content: refs}]

  defp insert_attachment_turn(messages, refs, _continue),
    do:
      List.insert_at(messages, last_index(messages, :assistant) || length(messages), %Request.Message{
        role: :user,
        content: refs
      })

  defp last_index(messages, role),
    do: messages |> Enum.with_index() |> Enum.reverse() |> Enum.find_value(fn {m, i} -> m.role == role && i end)

  defp text_tail(%{continue: text, character: %{name: name}}) when is_binary(text) and is_binary(name) and name != "",
    do: "\n\n#{name}: #{text}"

  defp text_tail(context), do: cue(context)

  defp cue(%{character: %{name: name}}) when is_binary(name) and name != "", do: "\n\n#{name}:"
  defp cue(_context), do: ""

  @doc """
  Builds the context map `segments/2` and `render/3` need, from a chat.

  The map's `:owner_id` is the chat's owner (the scope's user for an unsaved chat): what is
  share-protected is decided for them (`Mythweaver.Sharing.Visibility.protected_for?/2`), whoever builds.

  `opts`:

    * `:character`: the responding character (default the first participant that is not the player)
    * `:messages`: default `Mythweaver.Messages.list_messages/1`
    * `:lore`: default `Mythweaver.Lore.Activation.resolve(scope, chat, commit: false, model: model,
      context_limit: context_limit, character: character)`, so character-bound books follow the
      chat's Group cards setting and the lore budget is a share of the same context limit
    * `:tag_graph`: the chat owner's `Mythweaver.Tags.graph/1` (default: loaded here), for the
      anchors' tags and that default lore result
    * `:model`: the responding model, whose tokenizer sizes that default lore result's budget
      (default `nil`, an estimate)
    * `:outlets`: default the custom outlets of that same lore result, as `%{key => [decision]}`
    * `:variables`: default `Mythweaver.Variables.values(chat.id)`: what templates read as
      `vars`/`globals`
    * `:continue`: the message being continued (default `nil`), removed from `:messages` and
      rendered at the prompt's tail. Lore still resolves against the full list, so its text triggers.
    * `:injections`: default `Mythweaver.Injections.list_injections(scope, chat.id)`: every injection,
      disabled and spent ones included, so `build/2` can report why each was skipped
    * `:guide`: this generation's outline (default `nil`), exposed as `anchors.guide`; plain text,
      never rendered as a template
    * `:guide_attachments`: the attachments sent with the guide, of any kind and already `:ready`
      (default `[]`). Each adds its text line to `anchors.guide.text`, or to
      `anchors.refine.instructions` when `:refine` is given: an image its description line, any
      other kind its `Mythweaver.Attachments.file_line/2` unless the model receives it natively. A
      chat model also gets every one that `Mythweaver.Prompts.Transcript.native?/2` as a part on the
      prompt's last user turn
    * `:refine`: a refine's `%{instructions:, text:}` (default `nil`): the user's editing
      instructions and the text being rewritten, exposed as `anchors.refine`; plain text
    * `:reply`: the message a regenerate, continue or refine writes (default `nil`). Its ready
      attachments, never its text, close every chat-history segment
      (`Mythweaver.Prompts.Transcript.reply_media/2`). The caller leaves it out of `:messages`; a
      continue's `:continue` message is removed anyway
    * `:memory`: a memory-book job's string-keyed data (default `nil`), exposed as `anchors.memory`
      (`Mythweaver.Prompts.Anchor.memory_catalog/0`). When given, `:injections` defaults to `[]` and
      `:lore` to `Mythweaver.Lore.Activation.empty/0`: a memory prompt summarizes the chat, it does
      not activate lore or spend injections
    * `:memory_counts`: `anchors.memory_counts`, entries per tier in the chat's memory book (default
      `Mythweaver.Memory.counts/1`)
    * `:attach_images`: whether chat-history turns carry their images as image parts (default
      `false`: images appear as `[Image: …]` description lines). Only for a model that
      `Mythweaver.AI.Model.sees_images?/1`; the parts hold attachments, not bytes, until
      `Mythweaver.Attachments.inline_attachments/1` reads them
    * `:inline_limits`: per-kind counts of the newest messages whose attachments go in full
      (`Mythweaver.AI.Model.inline_limits/1`; default `%{}`, all); older images go as description lines
    * `:attach_files`: whether chat-history turns carry their PDFs as file parts (default `false`:
      a PDF appears as its `[Document: …]` text). Only for a model that
      `Mythweaver.AI.Model.reads_files?/1`; like images, the parts hold attachments until inlined
    * `:attach_audio`: whether chat-history turns carry their audio clips as audio parts (default
      `false`: `[Audio: …]` lines). Only for a model that `Mythweaver.AI.Model.hears_audio?/1`
    * `:attach_video`: whether chat-history turns carry their video clips as video parts (default
      `false`: `[Video: …]` lines). Only for a model that `Mythweaver.AI.Model.watches_video?/1`
    * `:caption_template`: the Liquid source for description lines (default the scope's
      `images.caption_template` setting; `nil` is the built-in `[Image: …]` line)
    * `:context_limit`: a `Mythweaver.Prompts.ContextLimit` (default `nil`); when set, chat history
      is trimmed oldest-first to fit (only replies pass one)

  `commit: false` on the lore resolve is deliberate: building a prompt for inspection must not persist
  sticky/cooldown state. A caller that is really generating passes its own already-committed result in
  `:lore`, and its outlets come from that result rather than a second activation pass.

  Raises `Mythweaver.UnauthorizedError` unless `scope` may act on `chat`. An unsaved chat (`id`
  nil: an avatar's caption, which has no chat) holds nothing to authorize; its caller supplies
  every chat-bound option.
  """
  @spec context(Scope.t(), Chat.t(), keyword()) :: Anchor.context()
  def context(%Scope{} = scope, %Chat{} = chat, opts \\ []) do
    if chat.id != nil and Chats.authorize(scope, chat, :inspect) != :ok, do: raise(Mythweaver.UnauthorizedError)

    messages = Keyword.get_lazy(opts, :messages, fn -> Messages.list_messages(chat) end)
    memory = Keyword.get(opts, :memory)
    memory_counts = Keyword.get_lazy(opts, :memory_counts, fn -> Memory.counts(chat) end)

    character = Keyword.get_lazy(opts, :character, fn -> Chat.responder(chat) end)

    tag_graph = Keyword.get_lazy(opts, :tag_graph, fn -> Mythweaver.Tags.graph(chat.user_id) end)

    tags =
      Keyword.get_lazy(opts, :tags, fn ->
        Mythweaver.Tags.anchor_tags(chat, [character, chat.player_character], tag_graph)
      end)

    lore =
      Keyword.get_lazy(opts, :lore, fn ->
        if memory,
          do: Activation.empty(),
          else:
            Activation.resolve(
              scope,
              chat,
              [commit: false, messages: messages, character: character, tag_graph: tag_graph] ++
                Keyword.take(opts, [:model, :context_limit])
            )
      end)

    continued = Keyword.get(opts, :continue)
    continue_text = continued && Message.active_content(continued)
    guide_attachments = Keyword.get(opts, :guide_attachments, [])
    messages = without(messages, continued)
    variables = Keyword.get_lazy(opts, :variables, fn -> Variables.values(chat.id) end)
    owner_id = chat.user_id || (scope.user && scope.user.id)
    character_tokens = character_tokens([character, chat.player_character | Chat.characters(chat)], owner_id)

    caption_template =
      Keyword.get_lazy(opts, :caption_template, fn -> Mythweaver.Settings.get(scope, "images.caption_template") end)

    lines =
      guide_lines(
        guide_attachments,
        Keyword.take(opts, [:attach_images, :attach_files, :attach_audio, :attach_video]),
        caption_template,
        %{user: name_of(chat.player_character), char: name_of(character)}
      )

    {guide, refine} =
      case Keyword.get(opts, :refine) do
        nil -> {join_lines(Keyword.get(opts, :guide), lines), nil}
        %{instructions: i} = r -> {Keyword.get(opts, :guide), %{r | instructions: join_lines(i, lines)}}
      end

    %{
      chat: chat,
      owner_id: owner_id,
      character: character,
      player_character: chat.player_character,
      tags: tags,
      messages: messages,
      lore: lore,
      outlets: Keyword.get_lazy(opts, :outlets, fn -> Activation.outlet_decisions(lore) end),
      continue: continue_text,
      guide: guide,
      guide_attachments: guide_attachments,
      reply: Keyword.get(opts, :reply),
      refine: refine,
      variables: variables,
      injections:
        Keyword.get_lazy(opts, :injections, fn ->
          if memory, do: [], else: Injections.list_injections(scope, chat.id)
        end),
      memory: memory,
      memory_counts: memory_counts,
      attach_images: Keyword.get(opts, :attach_images, false),
      inline_limits: Keyword.get(opts, :inline_limits, %{}),
      attach_files: Keyword.get(opts, :attach_files, false),
      attach_audio: Keyword.get(opts, :attach_audio, false),
      attach_video: Keyword.get(opts, :attach_video, false),
      caption_template: caption_template,
      context_limit: Keyword.get(opts, :context_limit),
      character_tokens: character_tokens,
      templates:
        Templates.State.new(
          %{
            "anchors" =>
              Anchor.data(%{
                chat: chat,
                character: character,
                player_character: chat.player_character,
                tags: tags,
                messages: messages,
                guide: guide,
                refine: refine,
                continue: continue_text,
                memory: memory,
                memory_counts: memory_counts,
                caption_template: caption_template,
                character_tokens: character_tokens
              }),
            "outlets" => %{}
          },
          variables,
          chat.id
        )
    }
  end

  defp without(messages, nil), do: messages
  defp without(messages, %Message{id: id}), do: Enum.reject(messages, &(&1.id == id))

  # A fresh token id for each protected character's (`Visibility.protected_for?/2` for the chat owner)
  # appearance and raw description: what templates see of them (the description until descriptions have
  # rendered).
  defp character_tokens(characters, owner_id) do
    for %Character{} = character <- characters,
        Visibility.protected_for?(character, owner_id),
        into: %{},
        do: {character.id, %{"description" => Schema.generate_id(), "appearance" => Schema.generate_id()}}
  end

  # One text line per guide attachment: an image's description (a vision model gets it too), any
  # other kind its file line unless the model receives it natively and so already reads its content.
  defp guide_lines(attachments, flags, template, vars) do
    for a <- attachments, line = guide_line(a, flags, template, vars), line != nil, do: line
  end

  defp guide_line(%Attachment{kind: :image} = a, _flags, template, vars),
    do: Attachments.describe_line(a, template, vars)

  defp guide_line(a, flags, _template, _vars),
    do: if(!Transcript.native?(a, flags), do: Attachments.file_line(a, :full))

  defp join_lines(text, []), do: text

  defp join_lines(text, lines) do
    [text || "" | lines]
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.join("\n")
  end

  defp name_of(%Character{name: name}) when is_binary(name), do: name
  defp name_of(_character), do: ""

  # Descriptions, then lore and injections, each rendered once with `state` threaded through; shared by
  # `build/2` and `render_user_text/4` so a message sees exactly what a block would. `protected` maps
  # each token id to its text, every token inside it already revealed; `labels` names the ids of
  # content-hidden values, which `protected_values/4` lists.
  defp prepare(context, state) do
    {state, errors, protected, labels} = render_descriptions(context, state)

    {state, lore_render, lore_errors, depth_items, reports, protected, labels} =
      render_lore(context, state, protected, labels)

    {state, lore_render, errors ++ lore_errors, depth_items, reports, protected, labels}
  end

  # Each character's description renders with `anchors.character` as that character, so a card that
  # names itself (SillyTavern's `{{char}}`, imported as `{{ anchors.character.name }}`) still does when
  # another character replies and the card is joined. Without that, joined cards would name the
  # responder, and change with every speaker. The player's description keeps the responder, as
  # SillyTavern's persona does.
  #
  # A protected character's description renders from its own text, but later templates see it, like
  # its appearance, only through a fresh token (`character_tokens/1`).
  defp render_descriptions(%{chat: %Chat{} = chat} = context, state) do
    participants = Chat.characters(chat)
    player = Map.get(context, :player_character)
    tokens = Map.get(context, :character_tokens, %{})

    characters =
      (participants ++ [Map.get(context, :character), player])
      |> Enum.filter(&is_struct(&1, Character))
      |> Enum.uniq_by(& &1.id)

    {rendered, {state, errors}} =
      characters
      |> Enum.filter(&(is_binary(&1.description) and String.trim(&1.description) != ""))
      |> Enum.map_reduce({state, []}, fn character, {state, errors} ->
        {text, state, render_errors} = render_description(character, player, tokens, state)
        # An error can quote the template's source, so a protected description reports only that it failed.
        named =
          if Map.has_key?(tokens, character.id),
            do: Enum.map(render_errors, fn _ -> "#{character.name}'s description did not render" end),
            else: Enum.map(render_errors, &"#{character.name}'s description: #{&1}")

        {{character.id, String.trim(text)}, {state, [named | errors]}}
      end)

    errors = errors |> Enum.reverse() |> Enum.concat()
    rendered = Map.new(rendered)
    rendered_tokens = Map.new(tokens, fn {id, fields} -> {id, %{fields | "description" => Schema.generate_id()}} end)

    {protected, labels} =
      character_protected(characters, tokens, rendered_tokens, rendered, Map.get(context, :owner_id))

    anchors =
      context
      |> Map.take([
        :chat,
        :character,
        :player_character,
        :tags,
        :messages,
        :guide,
        :refine,
        :continue,
        :memory,
        :memory_counts
      ])
      |> Map.put(:character_tokens, rendered_tokens)
      |> Anchor.data(rendered)

    {put_in_anchors(state, anchors), errors, protected, labels}
  end

  defp render_descriptions(_context, state), do: {state, [], %{}, %{}}

  defp render_description(%Character{id: id} = character, %Character{id: id}, _tokens, state),
    do: Templates.render(character.description, state)

  defp render_description(%Character{} = character, player, tokens, state) do
    anchors = Map.get(state.data, "anchors", %{})
    as_subject = put_in_anchors(state, Map.put(anchors, "character", Anchor.character(character, player, tokens)))
    {text, after_state, errors} = Templates.render(character.description, as_subject)
    restored = put_in_anchors(after_state, Map.put(after_state.data["anchors"], "character", anchors["character"]))
    {text, restored, errors}
  end

  # `{protected, labels}` for the protected characters: each one's raw description and appearance
  # (behind the tokens descriptions saw), then its rendered description (behind `rendered_tokens`),
  # with the raw tokens it quotes revealed. Each label is `{label, source}` (`label_source/2`).
  defp character_protected(characters, tokens, rendered_tokens, rendered, owner_id) do
    protected_characters =
      for character <- characters,
          Map.has_key?(tokens, character.id),
          do: {character, label_source(character, owner_id)}

    raw =
      for {character, source} <- protected_characters,
          {field, text} <- [{"description", character.description}, {"appearance", character.appearance}],
          is_binary(text) and String.trim(text) != "",
          do: {tokens[character.id][field], text, {character_label(character, field), source}}

    raw_texts = Map.new(raw, fn {id, text, _label} -> {id, text} end)

    described =
      for {character, source} <- protected_characters,
          text = rendered[character.id],
          do:
            {rendered_tokens[character.id]["description"], Protected.reveal(text, raw_texts),
             {character_label(character, "description"), source}}

    values = raw ++ described

    {Map.new(values, fn {id, text, _label} -> {id, text} end),
     Map.new(values, fn {id, _text, label} -> {id, label} end)}
  end

  defp character_label(%Character{name: name}, field), do: "[Hidden: #{name}'s #{field}]"

  # Whose rule protects `row` in `owner_id`'s chat: `:share` when it is share-protected
  # (`Visibility.share_protected?/2`, shown to no viewer), else `:site` (shown to `site.hidden.view`).
  defp label_source(row, owner_id), do: if(Visibility.share_protected?(row, owner_id), do: :share, else: :site)

  defp put_in_anchors(state, anchors), do: %{state | data: Map.put(state.data, "anchors", anchors)}

  # Entry by entry, so one broken entry falls back alone. Slots first in `Settings.slots/0` order, each
  # slot's lore and then its injections, then custom outlets by key; every activated entry renders,
  # whether or not a block reads its group, so its variable writes always apply. `at_depth` collects
  # depth items for the chat-history segment instead of an anchor.
  #
  # A protected entry's (`Visibility.protected_for?/2` of its book, for the chat owner) anchor and
  # outlet text is its `Protected.token/1`, so later templates cannot read or transform it; `protected`
  # (seeded with the characters') maps each token's id to its text for `build/2` to reveal, and
  # `labels` gains a content-hidden or share-protected entry's `{label, source}`.
  # An entry's rendered text quotes character tokens revealed; its anchor keeps them.
  defp render_lore(context, state, protected, labels) do
    injections = Map.get(context, :injections, [])

    outlet_groups = context |> Map.get(:outlets) |> Kernel.||(%{}) |> Enum.sort_by(&elem(&1, 0))

    acc = %{
      state: state,
      rendered: %{},
      protected: protected,
      labels: labels,
      owner_id: Map.get(context, :owner_id),
      # Book id → whether it is share-protected for the owner, asked once per book.
      shared: %{},
      lore: %{},
      outlets: %{},
      depth: [],
      reports: [],
      # Errors of templates no entry or block owns: an added card prompt's.
      errors: []
    }

    acc = Enum.reduce(Settings.slots(), acc, &render_slot(&1, context, injections, &2))
    acc = Enum.reduce(outlet_groups, acc, &render_outlet/2)
    acc = Enum.reduce(Map.get(context, :card_prompts, %{}), acc, &add_card_prompt(&1, context, &2))

    data =
      acc.state.data
      |> Map.update("anchors", %{"lore" => acc.lore}, &Map.put(&1, "lore", acc.lore))
      |> Map.put("outlets", acc.outlets)

    {%{acc.state | data: data}, acc.rendered, Enum.reverse(acc.errors), acc.depth, Enum.reverse(acc.reports),
     acc.protected, acc.labels}
  end

  # A card prompt with no block to replace renders where SillyTavern's card fields go: the system
  # prompt ahead of the before-character lore, the post-history instructions ahead of the
  # `post_history` outlet. Its errors join the build's, named like a description's.
  defp add_card_prompt({tag, {:add, text}}, context, acc) do
    state = %{acc.state | data: Map.put(acc.state.data, "original", "")}
    {rendered, state, errors} = Templates.render(text, state)
    state = %{state | data: Map.delete(state.data, "original")}
    label = @card_prompt_labels[tag]

    {rendered, protected, labels} =
      protect_card_text(String.trim(rendered), label, context, acc.protected, acc.labels)

    acc = %{
      acc
      | state: state,
        protected: protected,
        labels: labels,
        errors: Enum.reverse(card_prompt_errors(errors, label, context), acc.errors)
    }

    case tag do
      :main ->
        %{acc | lore: Map.put(acc.lore, "before_character", join_texts([rendered, acc.lore["before_character"] || ""]))}

      :post_history ->
        %{
          acc
          | outlets: Map.put(acc.outlets, "post_history", join_texts([rendered, acc.outlets["post_history"] || ""]))
        }
    end
  end

  defp add_card_prompt(_plan, _context, acc), do: acc

  # An error can quote the template's source, so a protected responder's reports only that it failed.
  defp card_prompt_errors(errors, label, context) do
    character = Map.get(context, :character)

    if Map.has_key?(Map.get(context, :character_tokens, %{}), character.id),
      do: Enum.map(errors, fn _ -> "#{character.name}'s #{label} did not render" end),
      else: Enum.map(errors, &"#{character.name}'s #{label}: #{&1}")
  end

  defp render_slot(slot, context, injections, acc) do
    decisions = slot_decisions(context, slot)
    {lore_texts, acc} = render_decisions(decisions, acc)

    {applied, acc} =
      injections
      |> Enum.filter(&(Atom.to_string(&1.position) == slot))
      |> render_injections(acc)

    if slot == "at_depth" do
      lore_items =
        for {decision, %{text: text}} <- Enum.zip(decisions, lore_texts),
            text != "",
            do: %{depth: decision.depth, role: decision.entry.role, content: text}

      injection_items =
        for {injection, text} <- applied,
            text != "",
            do: %{depth: injection.depth, role: injection.role, content: text}

      %{acc | depth: acc.depth ++ lore_items ++ injection_items}
    else
      case join_texts(Enum.map(lore_texts, & &1.anchor) ++ Enum.map(applied, &elem(&1, 1))) do
        "" -> acc
        value -> %{acc | lore: Map.put(acc.lore, slot, value)}
      end
    end
  end

  defp render_outlet({key, decisions}, acc) do
    {texts, acc} = render_decisions(decisions, acc)

    texts
    |> Enum.map(& &1.anchor)
    |> join_texts()
    |> case do
      "" -> acc
      value -> %{acc | outlets: Map.put(acc.outlets, key, value)}
    end
  end

  # Each decision's `%{anchor, text}`: `text` is its trimmed render, `anchor` what templates see of it.
  defp render_decisions(decisions, acc) do
    Enum.map_reduce(decisions, acc, fn decision, acc ->
      {anchor, state, errors} = Templates.render(decision.entry.content || "", acc.state)
      anchor = String.trim(anchor)
      text = Protected.reveal(anchor, acc.protected)
      rendered = Map.put(acc.rendered, decision.entry.id, %{text: text, errors: errors, placed: true})
      acc = %{acc | state: state, rendered: rendered}
      {shared?, acc} = book_shared?(decision.book, acc)

      if (shared? or Visibility.protected?(decision.book)) and text != "" do
        protected = Map.put(acc.protected, decision.entry.id, text)
        labels = put_lore_label(acc.labels, decision, shared?)
        {%{anchor: Protected.token(decision.entry.id), text: text}, %{acc | protected: protected, labels: labels}}
      else
        {%{anchor: anchor, text: text}, acc}
      end
    end)
  end

  defp book_shared?(book, acc) do
    case Map.fetch(acc.shared, book.id) do
      {:ok, shared?} ->
        {shared?, acc}

      :error ->
        shared? = Visibility.share_protected?(book, acc.owner_id)
        {shared?, %{acc | shared: Map.put(acc.shared, book.id, shared?)}}
    end
  end

  # A forced book's lore is protected but readable, so it gets no label.
  defp put_lore_label(labels, %{book: book, entry: entry}, shared?) do
    cond do
      shared? -> Map.put(labels, entry.id, {hidden_lore_label(book.name), :share})
      Visibility.book_hidden?(book) -> Map.put(labels, entry.id, {hidden_lore_label(nil), :site})
      Visibility.content_hidden?(book) -> Map.put(labels, entry.id, {hidden_lore_label(book.name), :site})
      true -> labels
    end
  end

  # What stands in for hidden text wherever it would be shown; `PromptSnapshot` writes the same.
  defp hidden_block_label(name),
    do:
      dpgettext("chat", "status: stands in for a hidden prompt block's text", "[Hidden block: %{block_name}]",
        block_name: name
      )

  defp hidden_lore_label(nil), do: dpgettext("chat", "status: stands in for hidden lore's text", "[Hidden lore]")

  defp hidden_lore_label(book_name),
    do:
      dpgettext("chat", "status: stands in for hidden lore's text", "[Hidden lore: %{book_name}]", book_name: book_name)

  # `{applied, acc}`: each applied injection with its rendered text, in input order.
  defp render_injections(injections, acc) do
    Enum.flat_map_reduce(injections, acc, fn injection, acc ->
      case injection_skip(injection, acc.state) do
        {status, errors} ->
          {[], report(acc, injection, status, nil, errors)}

        nil ->
          {text, state, errors} = Templates.render(injection.content || "", acc.state)
          text = String.trim(text)
          {[{injection, text}], report(%{acc | state: state}, injection, :applied, text, errors)}
      end
    end)
  end

  # Why `injection` does not render, as `{status, errors}`; `nil` when it does. A condition renders
  # against the current state, and the state it leaves behind is discarded.
  defp injection_skip(%Injection{} = injection, state) do
    cond do
      not injection.enabled ->
        {:disabled, []}

      Injection.spent?(injection) ->
        {:spent, []}

      is_nil(injection.condition) ->
        nil

      true ->
        case Templates.condition(injection.condition, state) do
          {:ok, true} -> nil
          {:ok, false} -> {:condition_false, []}
          {:error, errors} -> {:condition_false, errors}
        end
    end
  end

  defp report(acc, injection, status, text, errors) do
    {depth, role} =
      if injection.position == :at_depth, do: {injection.depth, injection.role}, else: {nil, nil}

    report = %{
      id: injection.id,
      key: injection.key,
      position: injection.position,
      depth: depth,
      role: role,
      status: status,
      text: text,
      errors: errors
    }

    %{acc | reports: [report | acc.reports]}
  end

  defp join_texts(texts), do: texts |> Enum.reject(&(&1 == "")) |> Enum.join("\n")

  defp slot_decisions(context, slot) do
    case Map.get(context, :lore) do
      %{by_slot: by_slot} -> Map.get(by_slot, slot, [])
      _ -> []
    end
  end

  # A placeholder: `build/2` fills chat history in once every template is known, so it can fit. Until
  # then `turns` holds the block's speaker-roles mode.
  defp segment(%{kind: :chat_history} = block, acc, _context) do
    mode = Map.get(block, :speaker_roles) || :responder
    {%{role: block.role, block_id: block.id, source: :chat_history, content: "", turns: mode, errors: []}, acc}
  end

  defp segment(block, {state, protected, labels}, context) do
    replacement =
      Enum.find_value(Map.get(context, :card_prompts, %{}), fn
        {tag, {:replace, id, text}} when id == block.id -> {tag, text}
        _other -> nil
      end)

    {content, state, errors, protected, labels} =
      case replacement do
        nil ->
          {text, state, errors} = Templates.render(block.content || "", state)
          {String.trim(text), state, errors, protected, labels}

        {tag, text} ->
          {card_text, suffix_text, state, errors} = replace_block(block, text, state)

          {card_text, protected, labels} =
            protect_card_text(card_text, @card_prompt_labels[tag], context, protected, labels)

          {join_texts([card_text, suffix_text]), state, errors, protected, labels}
      end

    segment = %{
      role: block.role,
      block_id: block.id,
      source: :template,
      content: content,
      turns: nil,
      errors: errors
    }

    {segment, {state, protected, labels}}
  end

  # A card prompt in place of its tagged block, `{{ original }}` reading the block's own text:
  # `{card_text, suffix_text, state, errors}`. A post-history block keeps its trailing `post_history`
  # outlet, rendered on its own so its lore stays outside a protected card's token.
  defp replace_block(block, text, state) do
    {own, suffix} = Standard.split_post_history(block.content || "")
    {original, state, own_errors} = Templates.render(own, state)

    state = %{state | data: Map.put(state.data, "original", String.trim(original))}
    {rendered, state, errors} = Templates.render(text, state)
    state = %{state | data: Map.delete(state.data, "original")}
    {suffix_text, state, suffix_errors} = Templates.render(suffix, state)

    {String.trim(rendered), String.trim(suffix_text), state, own_errors ++ errors ++ suffix_errors}
  end

  # Depth 0 lands after the last entry, depth 1 before it; a depth past the start lands first. Equal
  # depths keep input order: lore first, then injections by `order`.
  defp insert_at_depth(entries, [], _to_entry), do: entries

  defp insert_at_depth(entries, depth_items, to_entry) do
    count = length(entries)
    by_index = Enum.group_by(depth_items, &max(count - &1.depth, 0), to_entry)

    entries
    |> Enum.with_index()
    |> Enum.flat_map(fn {entry, index} -> Map.get(by_index, index, []) ++ [entry] end)
    |> Kernel.++(Map.get(by_index, count, []))
  end

  # One message per role *run*, not per block: every OpenAI-compatible endpoint tolerates repeats, but a
  # single system message is what providers expect and what SillyTavern's `squash_system_messages` emits.
  defp messages(segments, tail) do
    segments
    |> Enum.flat_map(fn
      %{turns: turns} when is_list(turns) -> turns
      segment -> [%{role: segment.role, content: segment.content}]
    end)
    |> Kernel.++(tail)
    |> Enum.chunk_by(& &1.role)
    |> Enum.map(fn [%{role: role} | _] = run ->
      %Request.Message{role: role, content: run_content(run)}
    end)
  end

  # A run with no images stays one string. With images it becomes content parts: each item's text, then
  # its images and files, adjacent text joined with "\n" exactly as the string form, blank text dropped.
  defp run_content(run) do
    if Enum.any?(run, &(Map.get(&1, :images, []) != [] or Map.get(&1, :files, []) != [])) do
      run
      |> Enum.flat_map(fn item ->
        [%Request.Text{text: item.content}] ++
          Enum.map(Map.get(item, :images, []), &%AttachmentRef{attachment: &1}) ++
          Enum.map(Map.get(item, :files, []), &%AttachmentRef{attachment: &1})
      end)
      |> Enum.chunk_by(& &1.__struct__)
      |> Enum.flat_map(fn
        [%Request.Text{} | _] = texts -> [%Request.Text{text: Enum.map_join(texts, "\n", & &1.text)}]
        refs -> refs
      end)
      |> Enum.reject(&match?(%Request.Text{text: ""}, &1))
    else
      Enum.map_join(run, "\n", & &1.content)
    end
  end
end
