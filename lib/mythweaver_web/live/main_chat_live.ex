defmodule MythweaverWeb.MainChatLive do
  use MythweaverWeb, :live_view

  import MythweaverWeb.Chat.Assistant
  import MythweaverWeb.Chat.CaptionQuestion
  import MythweaverWeb.Chat.ChatPicker
  import MythweaverWeb.Chat.ChatSettings
  import MythweaverWeb.Chat.DeleteConfirm
  import MythweaverWeb.Chat.ImageRequest
  import MythweaverWeb.Chat.Injections
  import MythweaverWeb.Chat.MemoryPanel
  import MythweaverWeb.Chat.Messages
  import MythweaverWeb.Chat.Participants
  import MythweaverWeb.Chat.PromptInspector
  import MythweaverWeb.Chat.SwipeInspector
  import MythweaverWeb.Chat.TurnQueue
  import MythweaverWeb.Chat.UnreadBadge
  import MythweaverWeb.Chat.Variables
  import MythweaverWeb.TagFields
  import MythweaverWeb.TagFilter

  alias Mythweaver.Assistant
  alias Mythweaver.Attachments
  alias Mythweaver.Attachments.Captions
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Expressions
  alias Mythweaver.Format
  alias Mythweaver.Generation
  alias Mythweaver.Greetings
  alias Mythweaver.Injections
  alias Mythweaver.Jobs
  alias Mythweaver.Lore
  alias Mythweaver.Memory
  alias Mythweaver.Messages
  alias Mythweaver.Messages.DraftBuffer
  alias Mythweaver.Messages.Message
  alias Mythweaver.Notifications
  alias Mythweaver.Prompts
  alias Mythweaver.Prompts.Completions
  alias Mythweaver.Scripts
  alias Mythweaver.Settings
  alias Mythweaver.Sharing.Visibility
  alias Mythweaver.Tags.Graph
  alias Mythweaver.Variables
  alias MythweaverWeb.Bulk
  alias MythweaverWeb.Bulk.Field
  alias MythweaverWeb.Bulk.Spec
  alias MythweaverWeb.Chat.Access
  alias MythweaverWeb.Chat.ChatSettings
  alias MythweaverWeb.LiveSync
  alias MythweaverWeb.MainChatLive.Annotations
  alias MythweaverWeb.MainChatLive.AssistantChat
  alias MythweaverWeb.MainChatLive.ChatRefresh
  alias MythweaverWeb.MainChatLive.ClipDialog
  alias MythweaverWeb.MainChatLive.Composer
  alias MythweaverWeb.MainChatLive.InjectionsPanel
  alias MythweaverWeb.MainChatLive.Members
  alias MythweaverWeb.MainChatLive.MemoryCommands
  alias MythweaverWeb.MainChatLive.MemoryPanel
  alias MythweaverWeb.MainChatLive.MessageActions
  alias MythweaverWeb.MainChatLive.MessageWindow
  alias MythweaverWeb.MainChatLive.ScratchpadPanel
  alias MythweaverWeb.MainChatLive.Selection
  alias MythweaverWeb.MainChatLive.SplitEditor
  alias MythweaverWeb.MainChatLive.Swipes
  alias MythweaverWeb.MainChatLive.VariablesPanel
  alias MythweaverWeb.Pane
  alias MythweaverWeb.ReportModal
  alias MythweaverWeb.TagFilter
  alias MythweaverWeb.Uploads
  alias Phoenix.HTML.Form

  @variable_events VariablesPanel.events()
  @injection_events InjectionsPanel.events()
  @memory_events MemoryPanel.events()
  @clip_events ClipDialog.events()
  @split_events SplitEditor.events()
  @annotation_events Annotations.events()
  @scratchpad_events ScratchpadPanel.events()
  @swipe_events Swipes.events()
  @message_action_events MessageActions.events()
  @selection_events Selection.events()
  @memory_command_events MemoryCommands.events()
  @assistant_events AssistantChat.events()
  @composer_events Composer.events()
  @member_events Members.events()

  # Must exceed the composer hook's 2s ping interval so a continuously typing user stays
  # visible; it is also what makes a closed or crashed tab stop showing as typing.
  @typing_ttl_ms 5_000

  # Streaming rows repaint at most once per frame: the first delta of a burst paints at once and
  # opens a frame; the newest delta per message that lands inside the frame paints when it closes.
  @body_delta_frame_ms 50

  @idle_turn_state %{chat_id: nil, speaking: nil, queue: [], auto?: false, paused?: false}

  @impl true
  def mount(_params, _session, socket) do
    all_chats = Chats.list_chats(socket.assigns.current_scope)
    chats = Enum.filter(all_chats, &(&1.kind == :roleplay))
    characters = Characters.list_characters(socket.assigns.current_scope)

    if connected?(socket) do
      Messages.subscribe_activity(socket.assigns.current_scope)
      Chats.subscribe(socket.assigns.current_scope)
      Jobs.subscribe(socket.assigns.current_scope)
    end

    {:ok,
     socket
     |> assign(
       chats: chats,
       all_chats: all_chats,
       # Chats others invited the user into (`Chats.list_member_chats/1`): the picker's "Shared with me".
       shared_chats: Chats.list_member_chats(socket.assigns.current_scope),
       assistant_running?: false,
       assistant_cards: %{calls: %{}, characters: %{}},
       assistant_model_error: nil,
       # The landing gear's model pick (nil: the default). It lasts for the LiveView's life and names
       # the model of every thread the landing or the picker's "+" creates.
       assistant_model_id: nil,
       # The landing settings modal's form (nil: closed) and an assistant thread's settings modal's.
       assistant_landing_form: nil,
       assistant_settings_form: nil,
       assistant_model_options: [],
       assistant_default_label: dpgettext("chat", "option: the default model of the assistant", "Default"),
       selected_chat: nil,
       # The open report dialog (`MythweaverWeb.ReportModal`), for a message or a chat member.
       reporting: nil,
       # The viewer's `Chats.role/2` in the open chat: `:owner`, `:editor` or `:guest` (nil without one).
       role: nil,
       # The viewer's accepted `Chats.Member` row in the open chat (`Chats.member_for/2`; nil for the
       # owner), whose `model_source` `:own` offers "My model" in the tools sheet.
       viewer_member: nil,
       # The open chat's character locks (`Chats.locks/1`, character id => holders), the ids the
       # viewer holds (speaking order), and which of those this tab posts as (nil: the first).
       locks: %{},
       my_locks: [],
       posting_as: nil,
       # Members tab: users added as player rows that hold nothing yet.
       player_rows_added: [],
       # The open chat's members (`Chats.list_members/2`), loaded with the settings' Members tab.
       members: [],
       lock_holders: [],
       member_invite_form: nil,
       # A guest's own characters, loaded when they open "Bring a character".
       own_characters: [],
       messages_empty?: false,
       message_window: %MessageWindow{},
       embedding_status: MessageWindow.embedding_off(),
       composer_form: nil,
       composer_text: "",
       own_message_id: nil,
       typing: %{},
       unread_chats: %{},
       streaming_messages: %{},
       body_delta_frame?: false,
       pending_body_deltas: %{},
       # Ids of other senders' new replies still generating; each signals `message_arrived` on finish.
       pending_arrivals: MapSet.new(),
       # A `?message=` deep link (search hits), opened once the transcript first loads.
       pending_jump: nil,
       # message id => visible_to_ai; cached because stream rows are not enumerable.
       selected_messages: %{},
       editing_message_id: nil,
       reattributing: nil,
       expression_picker: nil,
       edit_form: nil,
       # The attachments the message being edited will have on save (`Messages.set_attachments/4`).
       edit_attachments: [],
       edit_caret: nil,
       edit_body_id: nil,
       template_completions: nil,
       page_title: dpgettext("chat", "page title: chat list with no chat open", "Chats"),
       chat_form: nil,
       chat_form_choices: nil,
       chat_greeters: Greetings.index(characters),
       chat_form_completions: nil,
       settings_form: nil,
       settings_tab: "basics",
       lore_book_options: Enum.map(Lore.list_usable_books(socket.assigns.current_scope), &{&1.name, &1.id}),
       prompt_options: Enum.map(Prompts.list_prompts(socket.assigns.current_scope, :roleplay), &{&1.name, &1.id}),
       adding_participant?: false,
       adding_participant_ids: [],
       turn_state: @idle_turn_state,
       queue_open?: false,
       delete_confirm: nil,
       swipe_inspector: nil,
       prompt_inspector: nil,
       chat_variables: nil,
       chat_injections: nil,
       injection_count: 0,
       job_count: 0,
       reply_job: nil,
       queue_positions: %{},
       review_count: 0,
       memory_panel: nil,
       clip_draft: nil,
       split: nil,
       annotations: nil,
       scratchpads: [],
       scratchpad_edit: nil,
       discarding_scratchpad_id: nil,
       memory_boundary: nil,
       memory_progress: nil,
       hide_muted?: false,
       # The participants rail's name and tag filter (`participant_search?` opens it), and the
       # participants' expanded character tags it matches, loaded only while it has tag chips.
       participant_search?: false,
       participant_tags: %{},
       editing_participant: nil,
       # `{name, id}` of the open participant's outfits, for its settings modal.
       participant_outfit_options: [],
       character_options: Characters.character_options(characters),
       model_options: Mythweaver.AI.model_options(socket.assigns.current_scope),
       # `AI.default_model/1`'s id (nil when none resolves), so a participant row names its model
       # only when it overrides what the chat would otherwise use.
       default_model_id: default_model_id(socket.assigns.current_scope),
       # Images uploaded in the composer, stored but not sent yet (oldest first), so they can be
       # described while the message is written.
       composer_attachments: [],
       # `CallbackStore` keys for composer images, by attachment id: from a script's
       # `mw.images.request`, whose tag and data come back on the image's `image_described` run.
       composer_image_callbacks: %{},
       # The open `mw.images.request` dialog (`%{id:, prompt:, callback:}`), or nil.
       image_request: nil,
       editing_attachment_id: nil,
       # The open "Ask…" dialog (`%{target: {:staged, ids} | {:sent, id}}`), or nil.
       caption_question: nil,
       # Held caption jobs (`images.review_results`) of the open chat, by attachment id.
       caption_reviews: %{},
       quick_replies: Scripts.list_quick_replies(socket.assigns.current_scope),
       # The chat a running quick reply belongs to; nil when none is running.
       quick_reply_chat_id: nil,
       # Without any `uploads.*` permission the composer shows no attach button or drop target.
       can_attach?: Attachments.uploadable_kinds(socket.assigns.current_scope) != []
     )
     |> assign_image_settings()
     |> assign_avatar_settings()
     |> assign(chat_search?: false)
     |> Pane.assign_filter()
     |> assign_tag_filter()
     |> assign_participant_filter()
     |> ChatRefresh.assign_visible_chats()
     |> stream(:messages, [])
     |> Uploads.allow_files(:composer_files, Composer.attachment_limit(),
       progress: &Composer.composer_upload_progress/3
     )
     |> Uploads.allow_files(:edit_files, Composer.attachment_limit(), progress: &Composer.edit_upload_progress/3)
     |> Bulk.attach([chats_spec()])
     |> LiveSync.attach(
       [:scripts, :characters, :ai, :prompts, :lore, :memory, :tags, :settings],
       &sync_shared/2
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    previous = socket.assigns.selected_chat

    scope = socket.assigns.current_scope

    # `/` reopens the chat last opened (in any tab or session), else the first role-play chat.
    chat =
      case params["id"] do
        nil ->
          last = Chats.last_opened_chat_id(scope)
          (last && Chats.get_chat(scope, last)) || List.first(socket.assigns.chats)

        id ->
          Chats.get_chat(scope, id)
      end

    changed? = previous == nil or chat == nil or previous.id != chat.id

    if connected?(socket) and changed? and previous != nil do
      Phoenix.PubSub.unsubscribe(Mythweaver.PubSub, Messages.topic(previous.id))
      Phoenix.PubSub.unsubscribe(Mythweaver.PubSub, Memory.topic(previous.id))
      Attachments.unsubscribe(previous.id)
    end

    if connected?(socket) and changed? and chat != nil do
      Chats.mark_opened(scope, chat)
      Messages.subscribe(chat)
      Phoenix.PubSub.subscribe(Mythweaver.PubSub, Memory.topic(chat.id))
      Attachments.subscribe(chat.id)
      # Backfills what the chat is still missing: imported messages, a changed model, new Vector entries.
      Lore.Embeddings.sync_chat_later(chat.id)
    end

    socket =
      if changed? do
        if chat, do: Messages.mark_read(socket.assigns.current_scope, chat)

        Enum.each(socket.assigns.typing, fn {_id, {_name, timer}} ->
          Process.cancel_timer(timer)
        end)

        socket
        |> cancel_composer_files()
        |> discard_composer_attachments()
        |> MessageActions.drop_edit()
        |> assign(
          typing: %{},
          streaming_messages: %{},
          pending_body_deltas: %{},
          pending_arrivals: MapSet.new(),
          pending_jump: jump_target(params["message"]),
          selected_messages: %{},
          queue_open?: false,
          delete_confirm: nil,
          editing_message_id: nil,
          reattributing: nil,
          expression_picker: nil,
          edit_form: nil,
          edit_caret: nil,
          editing_participant: nil,
          adding_participant?: false,
          adding_participant_ids: [],
          swipe_inspector: nil,
          prompt_inspector: nil,
          chat_variables: nil,
          chat_injections: nil,
          memory_panel: nil,
          assistant_landing_form: nil,
          clip_draft: nil,
          split: nil,
          annotations: nil,
          scratchpads: (chat && Messages.list_scratchpads(socket.assigns.current_scope, chat)) || [],
          scratchpad_edit: nil,
          discarding_scratchpad_id: nil,
          memory_boundary: chat && Memory.boundary_position(socket.assigns.current_scope, chat),
          template_completions: chat && Completions.template(socket.assigns.current_scope, chat.id)
        )
        |> assign(selected_chat: chat, posting_as: nil, player_rows_added: [])
        |> MessageWindow.open()
        |> then(fn socket ->
          # Read once per page; activity broadcasts keep it current from here (`:chat_activity`).
          if previous == nil,
            do: assign(socket, unread_chats: Messages.unread_chats(socket.assigns.current_scope)),
            else: socket
        end)
        |> tap(fn socket ->
          # The transcript follows the reply that switches chats (`MessageWindow.open/1`). The dead
          # render never loads it: the connected mount does, and the page would show it unscrolled.
          if chat && connected?(socket), do: send(self(), {:load_messages, chat.id})
        end)
      else
        socket
      end

    {role, viewer_member} = if chat, do: Chats.viewer(scope, chat), else: {nil, nil}

    {:noreply,
     socket
     |> assign(selected_chat: chat, role: role, viewer_member: viewer_member)
     |> Members.assign_locks()
     |> ChatRefresh.assign_participant_tags()
     |> assign(page_title: page_title(chat))
     |> assign_chat_state(chat)
     |> Members.assign_composer_form(chat)
     |> assign_settings_form(chat)
     |> assign_memory_panel(chat, params)}
  end

  defp page_title(nil), do: dpgettext("chat", "page title: chat list with no chat open", "Chats")
  defp page_title(chat), do: Chat.title(chat)

  # A `?message=` id worth looking up: a well-formed UUID, else nothing.
  defp jump_target(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp jump_target(_id), do: nil

  # Only a role-play chat shows the messages column and the participants rail.
  defp roleplay?(%Chat{kind: :roleplay}), do: true
  defp roleplay?(_chat), do: false

  # `.UnreadBadge` counts each `message_arrived` while the tab is away, loaded row or not. A new reply's
  # row is created when generation starts, while the sender is usually still looking, so it counts
  # when it finishes; a continue or refine re-announces an existing message and never counts.
  defp arrival(socket, _message, true = _own?), do: socket

  defp arrival(socket, message, false = _own?) do
    case Message.active_body(message) do
      %{generating: true, origin: :original} -> update(socket, :pending_arrivals, &MapSet.put(&1, message.id))
      %{generating: true} -> socket
      _ -> push_event(socket, "message_arrived", %{})
    end
  end

  defp finish_arrival(socket, message_id) do
    if MapSet.member?(socket.assigns.pending_arrivals, message_id) do
      socket
      |> update(:pending_arrivals, &MapSet.delete(&1, message_id))
      |> push_event("message_arrived", %{})
    else
      socket
    end
  end

  # The open chat's badges, held captions, reply job and turn state; their idle values with no chat
  # or an assistant thread. With no chat the landing needs to know whether the assistant can run;
  # an assistant thread needs its runner state and tool cards.
  defp assign_chat_state(socket, nil) do
    socket |> assign_idle_chat_state() |> AssistantChat.assign_assistant_models()
  end

  defp assign_chat_state(socket, %Chat{kind: :assistant} = chat) do
    scope = socket.assigns.current_scope

    socket
    |> assign_idle_chat_state()
    |> assign(
      assistant_running?: Assistant.running?(scope, chat),
      assistant_cards: Assistant.tool_cards(scope, chat)
    )
    |> AssistantChat.assign_assistant_models()
  end

  # A guest (`Chats.authorize/3` gives them no `:inspect`) sees no injections, jobs or memory meter:
  # their counts are never loaded.
  defp assign_chat_state(%{assigns: %{role: :guest}} = socket, chat) do
    scope = socket.assigns.current_scope

    socket
    |> assign_idle_chat_state()
    |> assign(turn_state: Generation.status(scope, chat))
  end

  defp assign_chat_state(socket, chat) do
    scope = socket.assigns.current_scope

    socket
    |> assign(
      injection_count: Injections.count_active(scope, chat.id),
      job_count: Jobs.active_count(scope, chat.id),
      review_count: Jobs.review_count(scope, chat.id),
      caption_reviews: Captions.reviews(scope, chat),
      reply_job: reply_job(scope, chat.id),
      queue_positions: Jobs.queue_positions(scope),
      turn_state: Generation.status(scope, chat)
    )
    |> assign_memory_progress()
  end

  defp assign_idle_chat_state(socket) do
    assign(socket,
      injection_count: 0,
      job_count: 0,
      review_count: 0,
      caption_reviews: %{},
      reply_job: nil,
      queue_positions: %{},
      turn_state: @idle_turn_state,
      memory_progress: nil
    )
  end

  # The Memory button's meter toward the next automatic memory; nil hides it.
  defp assign_memory_progress(%{assigns: %{selected_chat: %{} = chat}} = socket),
    do: assign(socket, memory_progress: Memory.Auto.progress(socket.assigns.current_scope, chat))

  defp assign_memory_progress(socket), do: assign(socket, memory_progress: nil)

  # The chat's queued or running reply. One at most: `Generation.Server` is per chat.
  defp reply_job(scope, chat_id) do
    Jobs.list_jobs(scope, chat_id: chat_id, statuses: [:queued, :running], tags: Jobs.chat_tags())
    |> List.first()
  end

  # The memory modal is route-driven too: it exists only at `/chats/:id/memory` with a role-play chat,
  # for whoever may inspect it (never a guest).
  defp assign_memory_panel(socket, %Chat{kind: :assistant}, _params), do: assign(socket, memory_panel: nil)
  defp assign_memory_panel(%{assigns: %{role: :guest}} = socket, _chat, _params), do: assign(socket, memory_panel: nil)

  defp assign_memory_panel(%{assigns: %{live_action: :memory}} = socket, %{id: _} = chat, params),
    do: MemoryPanel.open(socket, chat, params)

  defp assign_memory_panel(socket, _chat, _params), do: assign(socket, memory_panel: nil)

  # The settings modal is route-driven: it exists only at `/chats/:id/settings`, for a role-play
  # chat's owner and editors, or an assistant thread's owner (its name and model).
  defp assign_settings_form(%{assigns: %{live_action: :settings}} = socket, %Chat{kind: :assistant} = chat) do
    assign(socket,
      settings_form: nil,
      assistant_settings_form: assistant_settings_form(Assistant.change_chat(chat))
    )
  end

  defp assign_settings_form(socket, %Chat{kind: :assistant}),
    do: assign(socket, settings_form: nil, assistant_settings_form: nil)

  defp assign_settings_form(%{assigns: %{live_action: :settings, role: role}} = socket, %{id: _} = chat)
       when role in [:owner, :editor] do
    socket
    |> assign(
      settings_form: to_form(Chats.change_settings(chat), as: :settings),
      settings_tab: "basics",
      assistant_settings_form: nil
    )
    |> assign(member_invite_form: Members.invite_form())
    |> Members.assign_members()
    |> assign_tag_fields(:chat, chat, chat.user_id)
  end

  defp assign_settings_form(socket, _chat),
    do: assign(socket, settings_form: nil, assistant_settings_form: nil, members: [])

  # The poster's name above the composer, only when the viewer has several characters to post as.
  defp poster_label(%{my_locks: [_, _ | _]} = assigns), do: poster(assigns) && poster(assigns).name
  defp poster_label(_assigns), do: nil

  # The poster's `Character`, for the typing indicator.
  defp poster(assigns) do
    id = Members.poster_id(assigns)
    id && Enum.find_value(assigns.selected_chat.participants, &(&1.character_id == id && &1.character))
  end

  # What the viewer may do in the open role-play chat, for the chat components.
  defp chat_access(scope, %Chat{} = chat, role), do: Access.new(scope, chat, role)

  # Each checked character of the guest's own joins the chat; the first refusal stops and is flashed.
  defp bring_characters(socket, chat, ids) do
    scope = socket.assigns.current_scope
    characters = Enum.filter(socket.assigns.own_characters, &(&1.id in ids))

    result =
      Enum.reduce_while(characters, {:ok, 0}, fn character, {:ok, n} ->
        case Chats.bring_character(scope, chat, character) do
          {:ok, _participant} -> {:cont, {:ok, n + 1}}
          {:error, reason} -> {:halt, {:error, reason, n}}
        end
      end)

    socket =
      socket
      |> assign(adding_participant?: false, adding_participant_ids: [], own_characters: [])
      |> ChatRefresh.refresh_selected(chat)
      |> ChatRefresh.assign_participant_tags()

    case result do
      {:ok, n} ->
        put_flash(socket, :info, brought_flash(n))

      {:error, :unauthorized, _n} ->
        flash_unauthorized(socket)

      {:error, _reason, _n} ->
        put_flash(socket, :error, dgettext("chat", "Could not bring that character into this chat"))
    end
  end

  defp brought_flash(n) do
    gettext_comment("Flash after a guest brings their own characters into a shared chat.")

    dpngettext(
      "chat",
      "status: flash after a guest brings their own characters into a shared chat",
      "Brought %{character_count} character",
      "Brought %{character_count} characters",
      n,
      character_count: Format.number(n)
    )
  end

  @impl true
  # A guest may not inspect (`Chats.authorize/3`'s `:inspect`): the inspectors, variables, injections,
  # memory and clip panels never open or load for them.
  def handle_event(event, _params, %{assigns: %{role: :guest}} = socket)
      when event in ["open_swipe_inspector", "open_prompt_inspector"] or event in @variable_events or
             event in @injection_events or event in @memory_events or event in @clip_events, do: {:noreply, socket}

  def handle_event(event, params, socket) when event in @variable_events,
    do: VariablesPanel.handle_event(event, params, socket)

  def handle_event(event, params, socket) when event in @injection_events,
    do: InjectionsPanel.handle_event(event, params, socket)

  def handle_event(event, params, socket) when event in @memory_events,
    do: MemoryPanel.handle_event(event, params, socket)

  def handle_event(event, params, socket) when event in @clip_events, do: ClipDialog.handle_event(event, params, socket)

  # Opening a split closes an open edit and annotation popup first; `edit_message` closes an open
  # split in turn.
  def handle_event(event, params, socket) when event in @split_events,
    do:
      SplitEditor.handle_event(
        event,
        params,
        if(event == "open_split", do: socket |> MessageActions.close_edit() |> Annotations.close_draft(), else: socket)
      )

  def handle_event(event, params, socket) when event in @annotation_events,
    do: Annotations.handle_event(event, params, socket)

  def handle_event(event, params, socket) when event in @scratchpad_events,
    do: ScratchpadPanel.handle_event(event, params, socket)

  def handle_event(event, params, socket) when event in @swipe_events, do: Swipes.handle_event(event, params, socket)

  def handle_event(event, params, socket) when event in @message_action_events,
    do: MessageActions.handle_event(event, params, socket)

  def handle_event(event, params, socket) when event in @selection_events,
    do: Selection.handle_event(event, params, socket)

  def handle_event(event, params, socket) when event in @memory_command_events,
    do: MemoryCommands.handle_event(event, params, socket)

  def handle_event(event, params, socket) when event in @assistant_events,
    do: AssistantChat.handle_event(event, params, socket)

  def handle_event(event, params, socket) when event in @composer_events,
    do: Composer.handle_event(event, params, socket)

  def handle_event(event, params, socket) when event in @member_events, do: Members.handle_event(event, params, socket)

  def handle_event("load_older_messages", _params, socket), do: {:reply, %{}, MessageWindow.load_older(socket)}

  def handle_event("load_newer_messages", _params, socket), do: {:reply, %{}, MessageWindow.load_newer(socket)}

  def handle_event("jump_to_latest", _params, socket),
    do: {:noreply, socket |> MessageWindow.load_latest() |> push_event("scroll_to_bottom", %{})}

  # `number` is a display number (`#N`, position + 1). The hook scrolls after the patch that loads it.
  def handle_event("jump_to_message", %{"number" => number}, %{assigns: %{selected_chat: %{}}} = socket) do
    with {display, ""} when display in 1..2_147_483_647//1 <- Integer.parse(to_string(number)),
         {:ok, socket, message} <- MessageWindow.load_around(socket, display - 1) do
      {:noreply, push_event(socket, "scroll_to_message", %{id: "messages-#{message.id}"})}
    else
      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           dgettext("chat", "This chat has no message #%{message_number}.", message_number: to_string(number))
         )}
    end
  end

  # Only a participant of the open chat can be asked to reply.
  def handle_event("generate_reply", %{"character_id" => character_id}, socket) do
    chat = socket.assigns.selected_chat

    with %{} <- chat,
         %{character: character} <- Enum.find(chat.participants, &(&1.character_id == character_id)) do
      case Generation.generate(socket.assigns.current_scope, chat, character, guide_opts(socket)) do
        :ok -> {:noreply, spend_guide(socket)}
        {:error, reason} -> {:noreply, put_flash(socket, :error, AssistantChat.generation_error(reason))}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("regenerate", %{"message_id" => message_id}, socket),
    do: generate_for_message(socket, message_id, &Generation.regenerate(&1, &2, &3, guide_opts(socket)))

  def handle_event("continue", %{"message_id" => message_id}, socket),
    do: generate_for_message(socket, message_id, &Generation.continue(&1, &2, &3, guide_opts(socket)))

  # The composer text is the editing instructions, and its staged attachments go with them; an empty
  # composer is flashed `:no_instructions` (the button is hidden then, so only a race reaches it).
  def handle_event("refine_message", %{"message_id" => message_id}, socket),
    do:
      generate_for_message(
        socket,
        message_id,
        &Generation.refine(&1, &2, &3, current_guide(socket), Keyword.take(guide_opts(socket), [:guide_attachments]))
      )

  # The notes on passages of the last reply, plus the composer's text as general instructions.
  def handle_event("rewrite_annotations", _params, socket), do: rewrite_annotations(socket)

  # `{:error, :not_generating}` is ignored: the queue draining between render and click is a race,
  # not a user error, and the conductor's `{:turn_state, _}` broadcast is what updates every tab.
  def handle_event("stop_generation", _params, socket) do
    Generation.stop(socket.assigns.current_scope, socket.assigns.selected_chat)
    {:noreply, socket}
  end

  def handle_event("toggle_auto_mode", _params, socket) do
    :ok =
      Generation.set_auto(socket.assigns.current_scope, socket.assigns.selected_chat, !socket.assigns.turn_state.auto?)

    {:noreply, socket}
  end

  def handle_event("open_queue", _params, socket), do: {:noreply, assign(socket, queue_open?: true)}
  def handle_event("close_queue", _params, socket), do: {:noreply, assign(socket, queue_open?: false)}

  def handle_event("dequeue", %{"id" => id}, socket) do
    case Integer.parse(id) do
      {entry_id, ""} -> :ok = Generation.dequeue(socket.assigns.current_scope, socket.assigns.selected_chat, entry_id)
      _ -> :ok
    end

    {:noreply, socket}
  end

  def handle_event("clear_queue", _params, socket) do
    :ok = Generation.clear_queue(socket.assigns.current_scope, socket.assigns.selected_chat)
    {:noreply, socket}
  end

  def handle_event("resume_queue", _params, socket) do
    :ok = Generation.resume(socket.assigns.current_scope, socket.assigns.selected_chat)
    {:noreply, socket}
  end

  def handle_event("toggle_mute", %{"id" => id}, socket) do
    chat = socket.assigns.selected_chat

    case chat_participant(socket, id) do
      nil ->
        {:noreply, socket}

      participant ->
        case Chats.update_participant(socket.assigns.current_scope, participant, %{"muted" => !participant.muted}) do
          {:ok, _} ->
            {:noreply, ChatRefresh.refresh_selected(socket, chat)}

          {:error, :unauthorized} ->
            {:noreply, flash_unauthorized(socket)}

          {:error, %Ecto.Changeset{}} ->
            {:noreply, put_flash(socket, :error, dgettext("chat", "Could not update the participant"))}
        end
    end
  end

  # Mutes the shown bots when any is unmuted, else unmutes them.
  def handle_event("toggle_mute_all", _params, socket) do
    case socket.assigns.selected_chat do
      nil ->
        {:noreply, socket}

      chat ->
        %{participant_filter: filter, participant_tags: tags, tag_graph: graph} = socket.assigns

        case mute_targets(chat, filtered_participants(chat, filter, tags, graph)) do
          [] ->
            {:noreply, socket}

          targets ->
            mute? = Enum.any?(targets, &(not &1.muted))
            ids = Enum.map(targets, & &1.id)
            {:ok, updated} = Chats.set_participants_muted(socket.assigns.current_scope, chat, ids, mute?)
            {:noreply, assign(socket, selected_chat: updated)}
        end
    end
  end

  def handle_event("toggle_hide_muted", _params, socket),
    do: {:noreply, put_hide_muted(socket, !socket.assigns.hide_muted?)}

  # From the participants hook, restoring the browser's stored choice, and the palette's show/hide.
  def handle_event("set_hide_muted", %{"hide" => hide?}, socket) when is_boolean(hide?),
    do: {:noreply, put_hide_muted(socket, hide?)}

  # A refused order (a participant added or removed in another tab mid-drag) re-renders the server
  # order, which snaps the dragged DOM back.
  def handle_event("reorder_participants", %{"ids" => ids}, socket) when is_list(ids) do
    chat = socket.assigns.selected_chat

    case chat && Chats.reorder_participants(socket.assigns.current_scope, chat, ids) do
      {:ok, reordered} -> {:noreply, assign(socket, selected_chat: reordered)}
      {:error, :unauthorized} -> {:noreply, flash_unauthorized(socket)}
      {:error, :not_a_permutation} -> {:noreply, ChatRefresh.refresh_selected(socket, chat)}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("open_participant_settings", %{"id" => id}, socket) do
    case chat_participant(socket, id) do
      nil ->
        {:noreply, socket}

      participant ->
        outfits = Expressions.list_outfits(socket.assigns.current_scope, participant.character)

        {:noreply,
         assign(socket,
           editing_participant: participant,
           participant_outfit_options: Enum.map(outfits, &{&1.name, &1.id})
         )}
    end
  end

  def handle_event("close_participant_settings", _params, socket) do
    {:noreply, assign(socket, editing_participant: nil)}
  end

  def handle_event("save_participant_settings", %{"participant_id" => id} = params, socket) do
    attrs = Map.take(params, ["ai_model_id", "talkativeness", "outfit_id"])

    socket =
      case chat_participant(socket, id) do
        nil ->
          socket

        participant ->
          case Chats.update_participant(socket.assigns.current_scope, participant, attrs) do
            {:ok, _participant} ->
              socket
              |> assign(editing_participant: nil)
              |> ChatRefresh.refresh_selected(socket.assigns.selected_chat)

            {:error, :unauthorized} ->
              flash_unauthorized(socket)

            {:error, %Ecto.Changeset{}} ->
              put_flash(socket, :error, dgettext("chat", "Could not save the character's settings"))
          end
      end

    {:noreply, socket}
  end

  def handle_event("typing", _params, socket) do
    chat = socket.assigns.selected_chat

    if chat && chat.kind == :roleplay do
      with %{} = character <- poster(socket.assigns), do: Messages.broadcast_typing(chat, character.id, character.name)
    end

    {:noreply, socket}
  end

  def handle_event("stop_typing", _params, socket) do
    chat = socket.assigns.selected_chat

    if chat && chat.kind == :roleplay do
      with id when is_binary(id) <- Members.poster_id(socket.assigns), do: Messages.broadcast_typing_stopped(chat, id)
    end

    {:noreply, socket}
  end

  def handle_event("new_chat", _params, socket) do
    {:noreply,
     socket
     |> assign(chat_form_completions: Completions.template(socket.assigns.current_scope, nil))
     |> assign_chat_form(Chats.change_new_chat())}
  end

  def handle_event("close_chat_modal", _params, socket) do
    {:noreply, close_chat_form(socket)}
  end

  def handle_event("validate_chat", %{"chat" => params}, socket) do
    changeset = Chats.change_new_chat(normalize_participants(params))
    {:noreply, assign_chat_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("save_chat", %{"chat" => params}, socket) do
    case Chats.create_chat(socket.assigns.current_scope, normalize_participants(params)) do
      {:ok, chat} ->
        {:noreply,
         socket
         |> close_chat_form()
         |> put_flash(:info, saved_flash(chat))
         |> greet(chat)
         |> ChatRefresh.refresh_chats()
         |> ChatRefresh.refresh_selected(chat)}

      {:error, :quota_exceeded} ->
        {:noreply, flash_quota(socket, "quota.chats")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign_chat_form(changeset)
         |> put_flash(:error, invalid_flash())}
    end
  end

  def handle_event("validate_settings", %{"settings" => params} = all, socket) do
    changeset = Chats.change_settings(socket.assigns.selected_chat, params)

    {:noreply,
     socket
     |> assign(settings_form: to_form(Map.put(changeset, :action, :validate), as: :settings))
     |> put_tag_params(:chat, all["tags"])}
  end

  def handle_event("chat_settings_tab", %{"tab" => tab}, socket) do
    if tab in ChatSettings.tab_names(),
      do: {:noreply, assign(socket, settings_tab: tab)},
      else: {:noreply, socket}
  end

  # Round mode: pass this round so the reply needn't wait on the viewer's post.
  def handle_event("skip_turn", _params, socket) do
    case Generation.skip_turn(socket.assigns.current_scope, socket.assigns.selected_chat) do
      :ok ->
        {:noreply, put_flash(socket, :info, dpgettext("chat", "status: the viewer's turn was skipped", "Turn skipped"))}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}
    end
  end

  def handle_event("save_settings", %{"settings" => params} = all, socket) do
    old = socket.assigns.selected_chat
    old_poster = Members.poster_id(socket.assigns)

    case Chats.update_settings(socket.assigns.current_scope, old, params) do
      {:ok, chat} ->
        socket =
          socket
          |> assign(selected_chat: chat)
          |> ChatRefresh.assign_participant_tags()
          |> Members.follow_poster(old_poster)
          # The submit carries the chips too, so a Save before any change event still writes them.
          |> put_tag_params(:chat, all["tags"])

        {socket, tags_error} =
          case save_tags(socket, :chat, chat) do
            {:ok, socket} -> {socket, nil}
            {:error, _what, socket} -> {socket, true}
          end

        socket = ChatRefresh.refresh_chats(socket)

        socket =
          if tags_error,
            do:
              put_flash(
                socket,
                :error,
                dgettext("chat", "%{chat_title} saved, but its tags did not", chat_title: Chat.title(chat))
              ),
            else: socket

        case {Map.get(all, "intent", "save"), tags_error} do
          {"apply", nil} ->
            {:noreply,
             socket
             |> assign(settings_form: to_form(Chats.change_settings(chat), as: :settings))
             |> put_flash(:info, dpgettext("chat", "status: chat settings were applied", "Settings applied"))}

          {"apply", _} ->
            {:noreply, assign(socket, settings_form: to_form(Chats.change_settings(chat), as: :settings))}

          {_, nil} ->
            {:noreply,
             socket
             |> put_flash(:info, saved_flash(chat))
             |> push_patch(to: ~p"/chats/#{chat.id}")}

          _ ->
            {:noreply, push_patch(socket, to: ~p"/chats/#{chat.id}")}
        end

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}

      {:error, %Ecto.Changeset{} = changeset} ->
        form = to_form(changeset, as: :settings)

        {:noreply,
         socket
         |> assign(settings_form: form, settings_tab: ChatSettings.error_tab(form, socket.assigns.settings_tab))
         |> put_flash(:error, invalid_flash())}
    end
  end

  def handle_event("close_chat_settings", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/chats/#{socket.assigns.selected_chat.id}")}
  end

  def handle_event(
        "validate_assistant_settings",
        %{"assistant_settings" => params},
        %{assigns: %{selected_chat: %Chat{kind: :assistant} = chat}} = socket
      ) do
    changeset = Map.put(Assistant.change_chat(chat, params), :action, :validate)
    {:noreply, assign(socket, assistant_settings_form: assistant_settings_form(changeset))}
  end

  def handle_event(
        "save_assistant_settings",
        %{"assistant_settings" => params},
        %{assigns: %{selected_chat: %Chat{kind: :assistant} = chat}} = socket
      ) do
    case Assistant.update_chat(socket.assigns.current_scope, chat, params) do
      {:ok, chat} ->
        {:noreply,
         socket
         |> ChatRefresh.refresh_selected(chat)
         |> ChatRefresh.refresh_chats()
         |> put_flash(:info, saved_flash(chat))
         |> push_patch(to: ~p"/chats/#{chat.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(assistant_settings_form: assistant_settings_form(changeset))
         |> put_flash(:error, invalid_flash())}

      {:error, _reason} ->
        {:noreply, flash_unauthorized(socket)}
    end
  end

  # No error branch: every `chat_id` foreign key is `on_delete: :delete_all`, so deleting a chat
  # cannot be refused. Deleting the *selected* chat must move the viewer off it, otherwise the
  # messages column renders a struct whose rows are gone; `push_patch(to: ~p"/")` re-enters
  # `handle_params/3`, which re-selects against the already-refreshed list.
  def handle_event("delete_chat", %{"id" => id}, socket) do
    case Chats.get_chat(socket.assigns.current_scope, id) do
      nil ->
        {:noreply, socket |> close_chat_form() |> assign(settings_form: nil) |> ChatRefresh.refresh_chats()}

      chat ->
        # A running conductor or assistant turn would otherwise keep generating against the deleted chat.
        if chat.kind == :assistant,
          do: Assistant.stop(socket.assigns.current_scope, chat),
          else: Generation.cancel(socket.assigns.current_scope, chat)

        {:ok, _} = Chats.delete_chat(socket.assigns.current_scope, chat)
        selected = socket.assigns.selected_chat

        socket =
          socket
          |> close_chat_form()
          |> assign(settings_form: nil)
          |> ChatRefresh.refresh_chats()
          |> put_flash(:info, chat_deleted_flash(chat))

        if selected && selected.id == chat.id do
          {:noreply, push_patch(socket, to: ~p"/")}
        else
          {:noreply, socket}
        end
    end
  end

  # A guest's add modal ("Bring a character", while `guests_bring_characters` is on) offers only
  # their own characters (`Chats.bring_character/3`).
  def handle_event("open_add_participant", _params, %{assigns: %{role: :guest}} = socket) do
    uid = socket.assigns.current_scope.user.id
    own = for c <- Characters.list_characters(socket.assigns.current_scope), c.user_id == uid, do: c
    {:noreply, assign(socket, adding_participant?: true, adding_participant_ids: [], own_characters: own)}
  end

  def handle_event("open_add_participant", _params, socket) do
    {:noreply, assign(socket, adding_participant?: true, adding_participant_ids: [])}
  end

  def handle_event("close_add_participant", _params, socket) do
    {:noreply, assign(socket, adding_participant?: false, adding_participant_ids: [])}
  end

  # The picker's boxes reset to the server's `checked` on every re-render (a search keystroke
  # included), so the server keeps the live selection.
  def handle_event("validate_add_participants", params, socket) do
    ids = params |> Map.get("character_ids", []) |> List.wrap() |> Enum.reject(&(&1 == ""))
    {:noreply, assign(socket, adding_participant_ids: ids)}
  end

  # The picker always posts a `""` sentinel, dropped here; a missing key (an event pushed without
  # one) is an empty list too, which just closes.
  def handle_event("add_participants", params, socket) do
    ids = params |> Map.get("character_ids", []) |> List.wrap() |> Enum.reject(&(&1 == ""))

    case {socket.assigns.selected_chat, ids, socket.assigns.role} do
      {chat, ids, _role} when chat == nil or ids == [] ->
        {:noreply, assign(socket, adding_participant?: false, adding_participant_ids: [])}

      {chat, ids, :guest} ->
        {:noreply, bring_characters(socket, chat, ids)}

      {chat, ids, _role} ->
        case Chats.add_participants(socket.assigns.current_scope, chat, ids) do
          {:ok, added} ->
            {:noreply,
             socket
             |> assign(adding_participant?: false, adding_participant_ids: [])
             |> ChatRefresh.refresh_selected(chat)
             |> ChatRefresh.refresh_chats()
             |> put_flash(:info, added_flash(length(added)))}

          {:error, :unauthorized} ->
            {:noreply, flash_unauthorized(socket)}

          {:error, %Ecto.Changeset{}} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               dgettext("chat", "Could not add — those characters may already be in this chat")
             )}
        end
    end
  end

  # `Chats.remove_participant/1` owns both rules this handler relies on: it refuses below two
  # participants, and it clears the chat's `player_character_id` in the same transaction when the
  # removed character was the player. The composer form is refreshed for that reason, since it is
  # nil without a player character.
  def handle_event("remove_participant", %{"id" => id}, socket) do
    chat = socket.assigns.selected_chat
    participant = chat_participant(socket, id)

    case participant do
      nil ->
        {:noreply, socket}

      participant ->
        name = participant.character.name

        case Chats.remove_participant(socket.assigns.current_scope, participant) do
          {:ok, _removed} ->
            socket = ChatRefresh.refresh_selected(socket, chat)

            {:noreply,
             socket
             |> Members.assign_composer_form(socket.assigns.selected_chat)
             |> ChatRefresh.refresh_chats()
             |> put_flash(:info, dgettext("chat", "%{character_name} removed from this chat", character_name: name))}

          {:error, :unauthorized} ->
            {:noreply, flash_unauthorized(socket)}

          {:error, :minimum_participants} ->
            {:noreply,
             put_flash(socket, :error, dgettext("chat", "A chat needs at least two participants — add one first"))}
        end
    end
  end

  def handle_event("filter", params, socket) do
    {:noreply, socket |> Pane.assign_filter(params) |> assign_tag_filter(params) |> ChatRefresh.assign_visible_chats()}
  end

  # The picker's search toggle. Closing it clears the filter, so a hidden search never narrows the list.
  def handle_event("toggle_chat_search", _params, socket) do
    if socket.assigns.chat_search? do
      {:noreply,
       socket
       |> assign(chat_search?: false)
       |> Pane.assign_filter()
       |> assign_tag_filter()
       |> ChatRefresh.assign_visible_chats()}
    else
      {:noreply, assign(socket, chat_search?: true)}
    end
  end

  def handle_event("filter_participants", params, socket),
    do: {:noreply, socket |> assign_participant_filter(params) |> ChatRefresh.assign_participant_tags()}

  # The participants rail's search toggle; closing it clears the filter, as the picker's does.
  def handle_event("toggle_participant_search", _params, socket) do
    if socket.assigns.participant_search? do
      {:noreply,
       socket
       |> assign(participant_search?: false)
       |> assign_participant_filter()
       |> ChatRefresh.assign_participant_tags()}
    else
      {:noreply, assign(socket, participant_search?: true)}
    end
  end

  defp assign_participant_filter(socket, params \\ %{}) do
    query = params["query"] || ""
    filter = Map.merge(TagFilter.parse(params), %{query: query, form: to_form(%{"query" => query})})
    assign(socket, participant_filter: filter)
  end

  # The participant ids the filter hides: no name match or a failed tag chip. Hide-muted hides on
  # its own; a row shows only when neither hides it.
  defp filtered_participants(%Chat{participants: participants}, filter, tags, graph) do
    shown =
      participants
      |> Pane.search(filter.query, &[&1.character.name])
      |> Enum.filter(&Graph.matches?(graph, Map.get(tags, &1.character_id, MapSet.new()), filter.predicates))
      |> MapSet.new(& &1.id)

    for p <- participants, not MapSet.member?(shown, p.id), into: MapSet.new(), do: p.id
  end

  defp chats_spec do
    %Spec{
      name: :chats,
      tag_kind: :chat,
      count_label:
        &dpngettext(
          "chat",
          "count phrase: chats affected by a bulk action",
          "%{chat_count} chat",
          "%{chat_count} chats",
          &1,
          chat_count: Mythweaver.Format.number(&1)
        ),
      # Bulk actions cover role-play chats only; assistant threads are listed but never selectable.
      ids: &for(c <- &1.assigns.visible_chats, c.kind == :roleplay, do: c.id),
      get: &Chats.get_chat/2,
      update: &Chats.update_chat/3,
      # Cancel first, as `delete_chat`: a running conductor would keep generating against it.
      delete: fn scope, chat ->
        Generation.cancel(scope, chat)
        Chats.delete_chat(scope, chat)
      end,
      title: &Chat.title/1,
      refresh: &ChatRefresh.refresh_chats/1,
      open_id: &(&1.assigns.selected_chat && &1.assigns.selected_chat.id),
      index_path: ~p"/",
      edit_path: &~p"/chats/#{&1}",
      fields: [
        %Field{
          key: :reply_strategy,
          label: dpgettext("chat", "field label: chat reply strategy", "Reply strategy"),
          type: :select,
          options: Field.enum_options(Chat, :reply_strategy)
        },
        %Field{
          key: :group_cards,
          label: dpgettext("chat", "field label: chat group card handling", "Group cards"),
          type: :select,
          options: Field.enum_options(Chat, :group_cards)
        },
        %Field{
          key: :allow_self_responses,
          label: dpgettext("chat", "field label: chat allows a character to answer itself", "Allow self responses")
        },
        %Field{
          key: :max_turns,
          label: dpgettext("chat", "field label: chat max turns", "Max turns"),
          type: :number,
          min: 1
        },
        %Field{
          key: :auto_mode_delay,
          label: dpgettext("chat", "field label: chat auto mode delay", "Auto mode delay"),
          type: :number,
          min: 1,
          max: 999
        },
        %Field{
          key: :ai_model_id,
          label: dpgettext("chat", "field label: AI model of a chat", "Model"),
          type: :select,
          options: &Mythweaver.AI.model_options/1,
          prompt: dpgettext("chat", "option: no model picked, use the default", "Default")
        }
      ]
    }
  end

  # A write elsewhere to something this screen caches (`MythweaverWeb.LiveSync`). Chat-bound state
  # syncs through the `Chats` topics; this re-reads the shared option lists and the open chat.
  defp sync_shared(socket, kinds) do
    scope = socket.assigns.current_scope

    socket
    |> then(&if(:scripts in kinds, do: assign(&1, quick_replies: Scripts.list_quick_replies(scope)), else: &1))
    |> then(&if(:characters in kinds, do: sync_characters(&1), else: &1))
    |> then(&if(:ai in kinds, do: sync_models(&1), else: &1))
    |> then(
      &if(:ai in kinds or :settings in kinds,
        do: &1 |> assign(default_model_id: default_model_id(scope)) |> maybe_assign_assistant_models(),
        else: &1
      )
    )
    |> then(
      &if(:prompts in kinds,
        do: assign(&1, prompt_options: Enum.map(Prompts.list_prompts(scope, :roleplay), fn p -> {p.name, p.id} end)),
        else: &1
      )
    )
    |> then(
      &if(:lore in kinds,
        do: assign(&1, lore_book_options: Enum.map(Lore.list_usable_books(scope), fn b -> {b.name, b.id} end)),
        else: &1
      )
    )
    |> then(&if(Enum.any?([:memory, :lore, :prompts], fn k -> k in kinds end), do: MemoryPanel.reload(&1), else: &1))
    |> then(
      &if(:tags in kinds,
        do:
          &1
          |> TagFilter.refresh_graph()
          |> ChatRefresh.assign_visible_chats()
          |> ChatRefresh.assign_participant_tags(),
        else: &1
      )
    )
  end

  # Message rows render `author_character` from a per-row preload, so a rename or avatar change of
  # one of the open chat's characters repaints the loaded transcript.
  defp sync_characters(socket) do
    characters = Characters.list_characters(socket.assigns.current_scope)

    socket =
      socket
      |> assign(character_options: Characters.character_options(characters), chat_greeters: Greetings.index(characters))
      |> refresh_chat_form()
      |> ChatRefresh.refresh_chats()

    case socket.assigns.selected_chat do
      %Chat{} = old ->
        socket = ChatRefresh.refresh_selected(socket, old)
        new = socket.assigns.selected_chat

        if new && author_keys(old) != author_keys(new) do
          Enum.reduce(MessageWindow.loaded_messages(socket), socket, fn message, socket ->
            MessageWindow.restream(socket, Map.get(socket.assigns.streaming_messages, message.id, message))
          end)
        else
          socket
        end

      _ ->
        socket
    end
  end

  # An open new-chat form follows who has greetings now.
  defp refresh_chat_form(%{assigns: %{chat_form: %Form{source: changeset}}} = socket),
    do: assign_chat_form(socket, changeset)

  defp refresh_chat_form(socket), do: socket

  # The new-chat form and its choices: "You play as" among the picked participants, and a greeting by
  # one of the others who has some for a chat this size (`Greetings.choices/3`).
  defp assign_chat_form(socket, changeset) do
    ids = changeset |> Ecto.Changeset.get_field(:participants) |> List.wrap() |> Enum.map(& &1.character_id)
    player_id = Ecto.Changeset.get_field(changeset, :player_character_id)
    names = Map.new(socket.assigns.character_options, fn {name, id} -> {id, name} end)
    named = fn ids -> for id <- ids, {:ok, name} <- [Map.fetch(names, id)], do: {name, id} end

    options = [
      {dpgettext("chat", "option: greeting of a new chat", "No greeting"), ""}
      | Enum.map(
          Greetings.choices(socket.assigns.chat_greeters, ids, player_id),
          &{greeting_label(&1, names), &1}
        )
    ]

    assign(socket,
      chat_form: to_form(changeset),
      chat_form_choices: %{players: named.(Enum.uniq(ids)), greetings: options}
    )
  end

  defp greeting_label("all", _names),
    do: dpgettext("chat", "option: greeting of a new chat", "Every character (one message each)")

  defp greeting_label("random", _names), do: dpgettext("chat", "option: greeting of a new chat", "A random character")

  defp greeting_label("custom", _names),
    do: dpgettext("chat", "option: greeting of a new chat", "Narrator (write it below)")

  defp greeting_label(id, names), do: Map.fetch!(names, id)

  defp close_chat_form(socket), do: assign(socket, chat_form: nil, chat_form_choices: nil, chat_form_completions: nil)

  # The chat is created either way; a greeting that could not be posted is only reported.
  defp greet(socket, chat) do
    case Greetings.post(socket.assigns.current_scope, chat) do
      :none ->
        socket

      {:ok, _message} ->
        socket

      {:error, reason} ->
        put_flash(socket, :error, greeting_error(Chat.title(chat), reason))
    end
  end

  defp greeting_error(chat_title, :no_greeting) do
    gettext_comment("Flash after a new chat was created but its greeting message could not be posted.")

    dgettext("chat", "%{chat_title} was created, but its greeting was not posted: there was no greeting to post",
      chat_title: chat_title
    )
  end

  defp greeting_error(chat_title, reason) when is_binary(reason) do
    gettext_comment(
      "Flash after a new chat was created but its greeting message could not be posted; %{error_reason} is the reason, already a phrase."
    )

    dgettext("chat", "%{chat_title} was created, but its greeting was not posted: %{error_reason}",
      chat_title: chat_title,
      error_reason: reason
    )
  end

  defp greeting_error(chat_title, _reason) do
    gettext_comment("Flash after a new chat was created but its greeting message could not be saved.")

    dgettext("chat", "%{chat_title} was created, but its greeting was not posted: it could not be saved",
      chat_title: chat_title
    )
  end

  defp sync_models(socket) do
    scope = socket.assigns.current_scope

    socket = assign(socket, model_options: Mythweaver.AI.model_options(scope))

    case socket.assigns.selected_chat do
      %Chat{} = chat -> ChatRefresh.refresh_selected(socket, chat)
      _ -> socket
    end
  end

  # Only the landing and assistant threads show the assistant's model state.
  defp maybe_assign_assistant_models(%{assigns: %{selected_chat: nil}} = socket),
    do: AssistantChat.assign_assistant_models(socket)

  defp maybe_assign_assistant_models(%{assigns: %{selected_chat: %Chat{kind: :assistant}}} = socket),
    do: AssistantChat.assign_assistant_models(socket)

  defp maybe_assign_assistant_models(socket), do: socket

  defp assistant_settings_form(changeset), do: to_form(changeset, as: :assistant_settings)

  # The landing pick's name, else the default's label.
  defp assistant_model_label(options, id, default_label) do
    Enum.find_value(options, default_label, fn
      {name, ^id} when not is_nil(id) -> name
      _ -> nil
    end)
  end

  defp author_keys(chat) do
    [chat.player_character | Enum.map(chat.participants, & &1.character)]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&{&1.id, &1.name, avatar_id(&1)})
    |> Enum.sort()
  end

  defp avatar_id(%{avatar: %{id: id}}), do: id
  defp avatar_id(_character), do: nil

  # The participants select posts `["id1", "id2"]`; `cast_assoc(:participants, ...)` needs
  # `[%{"character_id" => "id1"}, …]`. A missing key yields `[]`, which `create_changeset/2`
  # rejects with its existing "must have at least 2 participants" error rather than crashing.
  defp normalize_participants(params) do
    ids = params |> Map.get("participant_ids", []) |> List.wrap() |> Enum.reject(&(&1 == ""))

    Map.put(params, "participants", Enum.map(ids, &%{"character_id" => &1}))
  end

  defp default_model_id(scope) do
    case Mythweaver.AI.default_model(scope) do
      {:ok, model} -> model.id
      {:error, _} -> nil
    end
  end

  # The composer text and attachments are this click's guide; `Generation` treats blank text as no
  # guide. A click that starts spends them (`spend_guide/1`).
  defp current_guide(socket), do: socket.assigns.composer_text

  defp current_guide_attachments(socket), do: for(%{status: :ready} = a <- socket.assigns.composer_attachments, do: a)

  defp guide_opts(socket), do: [guide: current_guide(socket), guide_attachments: current_guide_attachments(socket)]

  defp guided?(text, attachments), do: String.trim(text) != "" or Enum.any?(attachments, &(&1.status == :ready))

  # A guided click that started spends what guided it, like a send: the text joins input history
  # (`composer_guided`, which also empties the editor), the draft is cleared and the staged
  # attachments go. Only unfinished uploads stay. An unguided click changes nothing.
  defp spend_guide(socket) do
    %{current_scope: scope, selected_chat: chat, composer_text: text, composer_attachments: attachments} =
      socket.assigns

    if guided?(text, attachments) do
      if socket.assigns.role == :owner do
        :ok = DraftBuffer.discard(scope, chat.id)
        {:ok, nil} = Messages.upsert_draft(scope, chat, "")
      end

      kept = Enum.reject(attachments, &(&1.status == :ready))

      socket
      |> assign(
        composer_form: to_form(%{"content" => ""}, as: :composer),
        composer_text: "",
        composer_attachments: kept,
        composer_image_callbacks: Map.take(socket.assigns.composer_image_callbacks, Enum.map(kept, & &1.id))
      )
      |> push_event("composer_guided", %{content: text})
    else
      socket
    end
  end

  # A message of the open chat regenerated, continued or refined; a refusal is flashed. `started`
  # runs on the socket once the generation was accepted.
  defp generate_for_message(socket, message_id, generate, started \\ & &1) do
    case Swipes.chat_message(socket, message_id) do
      %Message{} = message ->
        case generate.(socket.assigns.current_scope, socket.assigns.selected_chat, message) do
          :ok -> {:noreply, socket |> spend_guide() |> started.()}
          {:error, reason} -> {:noreply, put_flash(socket, :error, AssistantChat.generation_error(reason))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # A refusal (`:busy`, `:not_last`, …) keeps the notes for another try.
  defp rewrite_annotations(%{assigns: %{annotations: %{items: [_ | _]} = annotations}} = socket) do
    instructions = Annotations.instructions(annotations.items, current_guide(socket))

    generate_for_message(
      socket,
      annotations.message_id,
      &Generation.refine(&1, &2, &3, instructions, Keyword.take(guide_opts(socket), [:guide_attachments])),
      &Annotations.discard/1
    )
  end

  defp rewrite_annotations(socket), do: {:noreply, socket}

  # `hide_muted` has the participants hook store the choice in the browser.
  defp put_hide_muted(socket, hide?) do
    socket
    |> assign(hide_muted?: hide?)
    |> push_event("hide_muted", %{hide: hide?})
  end

  defp cancel_composer_files(socket) do
    Enum.reduce(socket.assigns.uploads.composer_files.entries, socket, &cancel_upload(&2, :composer_files, &1.ref))
  end

  # Unsent composer images belong to nobody once the composer lets go of them.
  defp discard_composer_attachments(socket) do
    Attachments.delete_unlinked(socket.assigns.current_scope, Enum.map(socket.assigns.composer_attachments, & &1.id))
    assign(socket, composer_attachments: [], composer_image_callbacks: %{}, image_request: nil)
  end

  defp assign_image_settings(socket) do
    values =
      Settings.get_many(
        socket.assigns.current_scope,
        ~w(images.review_captions images.auto_caption images.ask_every_time)
      )

    assign(socket,
      # Images are described as they upload and Send waits for every pending description.
      review_descriptions?: values["images.review_captions"],
      auto_caption?: values["images.auto_caption"],
      ask_captions?: values["images.ask_every_time"]
    )
  end

  # A held caption's figcaption shows its review form, so the message re-renders with the reviews.
  defp reload_caption_review(socket, job_id) do
    scope = socket.assigns.current_scope
    socket = assign(socket, caption_reviews: Captions.reviews(scope, socket.assigns.selected_chat))

    case Jobs.get_job(scope, job_id) do
      %{params: %{"message_id" => message_id}} when is_binary(message_id) ->
        MessageActions.restream_message(socket, message_id)

      _ ->
        socket
    end
  end

  @impl true
  # Only the open assistant thread's runner state and tool cards are tracked.
  def handle_info({:assistant_state, chat_id, running?}, socket) do
    if current_chat?(socket, chat_id),
      do: {:noreply, assign(socket, assistant_running?: running?)},
      else: {:noreply, socket}
  end

  def handle_info(
        {:tool_calls_changed, message_id},
        %{assigns: %{selected_chat: %Chat{kind: :assistant} = chat}} = socket
      ) do
    {:noreply,
     socket
     |> assign(assistant_cards: Assistant.tool_cards(socket.assigns.current_scope, chat))
     |> MessageActions.restream_message(message_id)}
  end

  def handle_info({:tool_calls_changed, _message_id}, socket), do: {:noreply, socket}

  # A command palette chat command runs the same event as its button; search jumps the same way.
  def handle_info({MythweaverWeb.CommandPalette, :chat_event, event, params}, socket),
    do: handle_event(event, params, socket)

  def handle_info({MythweaverWeb.Search, :chat_event, event, params}, socket), do: handle_event(event, params, socket)

  def handle_info({:caption_finished, id}, socket) do
    if Enum.any?(socket.assigns.composer_attachments, &(&1.id == id)) do
      case Attachments.get_attachment(socket.assigns.current_scope, id) do
        nil -> {:noreply, update(socket, :composer_attachments, &Enum.reject(&1, fn a -> a.id == id end))}
        attachment -> {:noreply, Composer.replace_staged(socket, attachment)}
      end
    else
      {:noreply, socket}
    end
  end

  # A script asked for an image (`mw.images.request`); a newer request replaces an open one.
  def handle_info({:image_requested, request}, socket), do: {:noreply, assign(socket, image_request: request)}

  def handle_info({:image_request_closed, id}, %{assigns: %{image_request: %{id: id}}} = socket),
    do: {:noreply, assign(socket, image_request: nil)}

  def handle_info({:image_request_closed, _id}, socket), do: {:noreply, socket}

  # `handle_params/3` sent it on opening the chat. A switch since then, or a jump that already filled
  # the window (`load_around/2`), leaves nothing to load. A `?message=` link loads around that
  # message instead of the latest page, when it is a non-draft message of this chat.
  def handle_info(
        {:load_messages, chat_id},
        %{assigns: %{selected_chat: %{id: chat_id}, message_window: %{loading?: true}}} = socket
      ) do
    jump = socket.assigns.pending_jump
    socket = assign(socket, pending_jump: nil)

    with id when is_binary(id) <- jump,
         %{chat_id: ^chat_id, draft: false} = message <- Messages.get_message(socket.assigns.current_scope, id),
         {:ok, socket, message} <- MessageWindow.load_around(socket, message.position) do
      {:noreply, push_event(socket, "scroll_to_message", %{id: "messages-#{message.id}"})}
    else
      _ -> {:noreply, socket |> MessageWindow.load_latest() |> push_event("scroll_to_bottom", %{})}
    end
  end

  def handle_info({:load_messages, _chat_id}, socket), do: {:noreply, socket}

  def handle_info(
        {:message_created, %{chat_id: chat_id} = message},
        %{assigns: %{selected_chat: %{id: chat_id}}} = socket
      ) do
    own? = socket.assigns.own_message_id == message.id

    {socket, outcome} =
      socket
      |> assign(
        messages_empty?: false,
        own_message_id: nil,
        streaming_messages: Map.delete(socket.assigns.streaming_messages, message.id)
      )
      |> forget_typing(message.author_character_id)
      |> refresh_swipe_inspector(message)
      |> MessageWindow.receive_created(message, own?)

    socket =
      case outcome do
        :appended -> push_event(socket, "message_appended", %{own: own?})
        :reloaded -> push_event(socket, "scroll_to_bottom", %{})
        _ -> socket
      end

    {:noreply, socket |> arrival(message, own?) |> assign_memory_progress()}
  end

  # If this tab is editing the message, the form stays open: the render keys off `editing_message_id`.
  # The lore preview refreshes because an edit or a visibility change alters what lore scanning sees.
  # A streaming row keeps its cached bodies: the row read from the DB lags the stream.
  def handle_info(
        {:message_updated, %{chat_id: chat_id} = message},
        %{assigns: %{selected_chat: %{id: chat_id}}} = socket
      ) do
    selected = socket.assigns.selected_messages

    selected =
      if Map.has_key?(selected, message.id),
        do: Map.put(selected, message.id, message.visible_to_ai),
        else: selected

    {message, streaming} =
      case Map.fetch(socket.assigns.streaming_messages, message.id) do
        {:ok, cached} ->
          message = %{message | bodies: cached.bodies}
          {message, Map.put(socket.assigns.streaming_messages, message.id, message)}

        :error ->
          {message, socket.assigns.streaming_messages}
      end

    {:noreply,
     socket
     |> assign(selected_messages: selected, streaming_messages: streaming)
     |> refresh_swipe_inspector(message)
     |> SplitEditor.refresh(message)
     |> Annotations.refresh(message)
     |> MessageWindow.restream(message)
     |> assign_memory_progress()}
  end

  def handle_info(
        {:message_deleted, %{chat_id: chat_id} = message},
        %{assigns: %{selected_chat: %{id: chat_id}}} = socket
      ) do
    socket =
      if socket.assigns.editing_message_id == message.id,
        do: MessageActions.drop_edit(socket),
        else: socket

    socket =
      case socket.assigns.reattributing do
        %{message_id: id} when id == message.id -> assign(socket, reattributing: nil)
        _ -> socket
      end

    socket =
      case socket.assigns.expression_picker do
        %{message_id: id} when id == message.id -> assign(socket, expression_picker: nil)
        _ -> socket
      end

    socket =
      case socket.assigns.swipe_inspector do
        %{message: %{id: id}} when id == message.id -> assign(socket, swipe_inspector: nil)
        _ -> socket
      end

    # No other refresh: the button is hidden while generating, so an open snapshot is final.
    socket =
      case socket.assigns.prompt_inspector do
        %{body: %{message_id: id}} when id == message.id -> assign(socket, prompt_inspector: nil)
        _ -> socket
      end

    # A scratchpad cut from it is now orphaned (`on_delete: :nilify_all`), which its card shows.
    socket =
      if Enum.any?(socket.assigns.scratchpads, &(&1.message_id == message.id)),
        do: assign_scratchpads(socket),
        else: socket

    {:noreply,
     socket
     |> assign(
       streaming_messages: Map.delete(socket.assigns.streaming_messages, message.id),
       selected_messages: Map.delete(socket.assigns.selected_messages, message.id),
       messages_empty?: not Messages.has_messages?(socket.assigns.current_scope, socket.assigns.selected_chat)
     )
     |> SplitEditor.drop(message.id)
     |> Annotations.drop(message.id)
     |> MessageWindow.delete(message)
     |> assign_memory_progress()}
  end

  # Scratchpad cards show their message's `#N`, which a split may have moved.
  def handle_info({:messages_split, %{chat_id: chat_id} = split}, %{assigns: %{selected_chat: %{id: chat_id}}} = socket) do
    {:noreply,
     socket
     |> SplitEditor.drop(split.message_id)
     |> Annotations.drop(split.message_id)
     |> MessageWindow.receive_split(split.position, split.shift)
     |> assign_scratchpads()}
  end

  def handle_info({:messages_split, _split}, socket), do: {:noreply, socket}

  def handle_info({:bodies_embedded, body_ids}, socket), do: {:noreply, MessageWindow.bodies_embedded(socket, body_ids)}

  def handle_info({:scratchpads_changed, chat_id}, %{assigns: %{selected_chat: %{id: chat_id}}} = socket),
    do: {:noreply, assign_scratchpads(socket)}

  def handle_info({:scratchpads_changed, _chat_id}, socket), do: {:noreply, socket}

  # The previous chat's events still in flight after a switch, or a stale broadcast.
  def handle_info({event, %Message{}}, socket) when event in [:message_created, :message_updated, :message_deleted],
    do: {:noreply, socket}

  def handle_info({:body_delta, %{message_id: id} = delta}, socket) do
    if socket.assigns.body_delta_frame? do
      {:noreply, assign(socket, pending_body_deltas: Map.put(socket.assigns.pending_body_deltas, id, delta))}
    else
      {:noreply, socket |> show_body_delta(delta) |> open_body_delta_frame()}
    end
  end

  def handle_info(:close_body_delta_frame, socket) do
    pending = socket.assigns.pending_body_deltas

    if map_size(pending) == 0 do
      {:noreply, assign(socket, body_delta_frame?: false)}
    else
      socket = assign(socket, pending_body_deltas: %{})

      {:noreply,
       pending
       |> Map.values()
       |> Enum.reduce(socket, &show_body_delta(&2, &1))
       |> open_body_delta_frame()}
    end
  end

  # A reply that produced no text left no swipe to show its error on.
  def handle_info({:generation_discarded, chat_id, error}, socket) do
    if current_chat?(socket, chat_id),
      do: {:noreply, put_flash(socket, :error, error)},
      else: {:noreply, socket}
  end

  def handle_info({:generation_finished, message_id}, socket) do
    # A delta still pending at finish would repaint the finalized row with stale text.
    socket = assign(socket, pending_body_deltas: Map.delete(socket.assigns.pending_body_deltas, message_id))
    streaming = Map.delete(socket.assigns.streaming_messages, message_id)

    case Messages.get_message(socket.assigns.current_scope, message_id) do
      nil ->
        {:noreply,
         assign(socket,
           streaming_messages: streaming,
           pending_arrivals: MapSet.delete(socket.assigns.pending_arrivals, message_id)
         )}

      message ->
        if current_chat?(socket, message.chat_id) do
          {:noreply,
           socket
           |> assign(streaming_messages: streaming)
           |> refresh_swipe_inspector(message)
           |> MessageWindow.restream(message)
           |> assign_memory_progress()
           |> finish_arrival(message_id)}
        else
          {:noreply, socket}
        end
    end
  end

  # Some window changed a chat's settings, participants, members or locks; the event arrives for every
  # chat on the app-wide topic, so a window on another chat refreshes only its list. For the open chat,
  # the composer is rebuilt only when it appears or disappears, so a half-typed message survives every
  # other change. A member removed from the open chat (it no longer reads) is sent to the landing.
  # Stream rows render their controls once, so a changed role or guest toggle reloads the transcript.
  def handle_info({:chat_updated, chat_id}, %{assigns: %{selected_chat: %{id: chat_id} = old}} = socket) do
    old_poster = Members.poster_id(socket.assigns)
    old_access = {socket.assigns.role, Chat.guest_permissions(old)}
    socket = socket |> ChatRefresh.refresh_selected(old) |> ChatRefresh.refresh_chats()

    case socket.assigns.selected_chat do
      nil ->
        {:noreply, socket |> put_flash(:info, access_lost_flash(Chat.title(old))) |> push_patch(to: ~p"/")}

      new ->
        {role, viewer_member} = Chats.viewer(socket.assigns.current_scope, new)

        socket =
          socket
          |> assign(page_title: page_title(new), role: role, viewer_member: viewer_member)
          |> Members.assign_locks()
          |> Members.keep_poster(old_poster)
          |> Members.assign_members()
          |> Members.follow_poster(old_poster)

        if {role, Chat.guest_permissions(new)} == old_access,
          do: {:noreply, socket},
          else: {:noreply, socket |> assign_chat_state(new) |> MessageWindow.load_latest()}
    end
  end

  def handle_info({:chat_updated, _chat_id}, socket), do: {:noreply, ChatRefresh.refresh_chats(socket)}

  # Another window created a chat.
  def handle_info({:chat_created, _chat_id}, socket), do: {:noreply, ChatRefresh.refresh_chats(socket)}

  # Another window deleted the chat this one shows (or removed this member from it): leave it, as the
  # deleting window does, once the list no longer holds it so `handle_params/3`'s `List.first/1`
  # cannot re-pick it.
  def handle_info({:chat_deleted, chat_id}, %{assigns: %{selected_chat: %{id: chat_id} = chat}} = socket) do
    gone =
      if socket.assigns.role != :owner and Chats.get_chat(chat_id),
        do: access_lost_flash(Chat.title(chat)),
        else: chat_gone_flash(Chat.title(chat))

    {:noreply,
     socket
     |> ChatRefresh.refresh_chats()
     |> put_flash(:info, gone)
     |> push_patch(to: ~p"/")}
  end

  def handle_info({:chat_deleted, _chat_id}, socket), do: {:noreply, ChatRefresh.refresh_chats(socket)}

  # Activity in the open chat is being watched, so it is read on arrival; the `:chat_read` that
  # `mark_read/2` broadcasts then clears the dot in every other tab. The map is patched from the
  # payloads, never re-read: a read clears a dot only if it covers the newest activity this tab has
  # seen, so an activity and a read from different processes may arrive in either order.
  def handle_info({:chat_activity, chat_id, at}, socket) do
    case socket.assigns.selected_chat do
      %{id: ^chat_id} = chat -> Messages.mark_read(socket.assigns.current_scope, chat)
      _ -> :ok
    end

    unread = Map.update(socket.assigns.unread_chats, chat_id, at, &Enum.max([&1, at], DateTime))
    {:noreply, assign(socket, unread_chats: unread)}
  end

  def handle_info({:chat_read, chat_id, read_at}, socket) do
    unread =
      case socket.assigns.unread_chats do
        %{^chat_id => at} = unread -> if DateTime.after?(at, read_at), do: unread, else: Map.delete(unread, chat_id)
        unread -> unread
      end

    {:noreply, assign(socket, unread_chats: unread)}
  end

  # A conductor's broadcast for the previous chat can land after a switch.
  def handle_info(
        {:turn_state, %{chat_id: chat_id} = turn_state},
        %{assigns: %{selected_chat: %{id: chat_id}}} = socket
      ) do
    {:noreply, assign(socket, turn_state: turn_state)}
  end

  def handle_info({:turn_state, _turn_state}, socket), do: {:noreply, socket}

  def handle_info({:turn_error, %{reason: reason}}, socket) do
    {:noreply, put_flash(socket, :error, AssistantChat.generation_error(reason))}
  end

  def handle_info({:typing, character_id, character_name}, socket) do
    timer = Process.send_after(self(), {:typing_expired, character_id}, @typing_ttl_ms)

    case socket.assigns.typing do
      %{^character_id => {_name, old_timer}} -> Process.cancel_timer(old_timer)
      _ -> :ok
    end

    {:noreply, assign(socket, typing: Map.put(socket.assigns.typing, character_id, {character_name, timer}))}
  end

  def handle_info({event, character_id}, socket) when event in [:typing_stopped, :typing_expired],
    do: {:noreply, forget_typing(socket, character_id)}

  # A generation's `{% setvar %}` or another tab changed this chat's variables. Completions and the
  # list refresh; a half-typed form is left alone.
  def handle_info({:variables_changed, chat_id}, %{assigns: %{selected_chat: %{id: chat_id}}} = socket) do
    socket = assign(socket, template_completions: Completions.template(socket.assigns.current_scope, chat_id))

    case socket.assigns.chat_variables do
      %{} = panel ->
        {:noreply,
         assign(socket,
           chat_variables: %{panel | variables: Variables.list_chat_variables(socket.assigns.current_scope, chat_id)}
         )}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_info({:variables_changed, _chat_id}, socket), do: {:noreply, socket}

  # A generation spent injections, or another tab changed them. The badge and the list refresh; a
  # half-typed form is left alone.
  def handle_info({:injections_changed, chat_id}, %{assigns: %{selected_chat: %{id: chat_id}}} = socket) do
    socket = assign(socket, injection_count: Injections.count_active(socket.assigns.current_scope, chat_id))

    case socket.assigns.chat_injections do
      %{} = panel ->
        {:noreply,
         assign(socket,
           chat_injections: %{panel | injections: Injections.list_injections(socket.assigns.current_scope, chat_id)}
         )}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_info({:injections_changed, _chat_id}, socket), do: {:noreply, socket}

  # The header's jobs badge counts the selected chat's queued, running and review jobs; the memory
  # badge its review jobs. An open memory modal follows its chat's memory jobs.
  def handle_info({:job_changed, %{chat_id: chat_id} = job}, %{assigns: %{selected_chat: %{id: chat_id}}} = socket) do
    socket =
      assign(socket,
        job_count: Jobs.active_count(socket.assigns.current_scope, chat_id),
        review_count: Jobs.review_count(socket.assigns.current_scope, chat_id)
      )

    socket =
      if job.tag in Jobs.chat_tags(),
        do: assign(socket, reply_job: reply_job(socket.assigns.current_scope, chat_id)),
        else: socket

    socket = if job.tag == :caption, do: reload_caption_review(socket, job.id), else: socket

    {:noreply, if(job.tag in Jobs.memory_tags(), do: MemoryPanel.reload(socket), else: socket)}
  end

  def handle_info({:job_changed, _job}, socket), do: {:noreply, socket}

  def handle_info({:job_queue, positions}, socket), do: {:noreply, assign(socket, queue_positions: positions)}

  def handle_info(
        {:job_progress, %{chat_id: chat_id} = payload},
        %{assigns: %{selected_chat: %{id: chat_id}}} = socket
      ), do: {:noreply, push_event(socket, "job_progress", payload)}

  def handle_info({:job_progress, _payload}, socket), do: {:noreply, socket}

  # A memory save, boundary edit or settings change. The divider moves by repainting the rows it
  # leaves and lands on.
  def handle_info({:memory_changed, chat_id}, %{assigns: %{selected_chat: %{id: chat_id} = chat}} = socket) do
    old = socket.assigns.memory_boundary
    new = Memory.boundary_position(socket.assigns.current_scope, chat)

    socket =
      if old == new do
        socket
      else
        [old, new]
        |> Enum.reject(&is_nil/1)
        |> Enum.flat_map(&Messages.list_messages_between(socket.assigns.current_scope, chat, &1, &1))
        |> Enum.reduce(assign(socket, memory_boundary: new), fn message, socket ->
          MessageWindow.restream(socket, Map.get(socket.assigns.streaming_messages, message.id, message))
        end)
      end

    {:noreply, socket |> assign_memory_progress() |> MemoryPanel.reload()}
  end

  def handle_info({:memory_changed, _chat_id}, socket), do: {:noreply, socket}

  # A watched tier of this chat's memory book reached its minimum. Only announced, with a link to
  # the Consolidate tab: consolidating stays the user's call (that tab shows the same notice, and the
  # inbox keeps it until the tier is consolidated). Its own flash entry: the saves that announce it
  # go on to queue jobs whose review notices would otherwise replace it.
  def handle_info({:consolidation_ready, %{tier: tier}}, %{assigns: %{selected_chat: %{id: chat_id} = chat}} = socket) do
    {:noreply,
     put_flash(socket, :consolidation, %{
       message: Notifications.consolidation_title(tier, chat),
       action: dpgettext("chat", "button: open the memory tab to consolidate a tier", "Consolidate"),
       path: ~p"/chats/#{chat_id}/memory?tab=consolidate"
     })}
  end

  def handle_info({:consolidation_ready, _payload}, socket), do: {:noreply, socket}

  # A consolidation saved without a preview skipped some of its sources.
  def handle_info({:consolidation_left_out, %{count: n}}, socket) do
    {:noreply,
     put_flash(
       socket,
       :info,
       dngettext(
         "chat",
         "A consolidation left out %{entry_count} entry. They stay unconsolidated for the next pass.",
         "A consolidation left out %{entry_count} entries. They stay unconsolidated for the next pass.",
         n,
         entry_count: Format.number(n)
       )
     )}
  end

  # A memory reminder (`Mythweaver.Memory.Reminders`); the flash stays until it is closed.
  def handle_info({:memory_reminder, %{mode: :manual, count: n}}, socket),
    do:
      {:noreply,
       put_flash(
         socket,
         :info,
         dngettext(
           "chat",
           "%{message_count} message since the last memory. Open Memory to create one.",
           "%{message_count} messages since the last memory. Open Memory to create one.",
           n, message_count: Format.number(n))
       )}

  def handle_info({:memory_reminder, %{mode: :auto, count: n}}, socket) do
    {:noreply,
     put_flash(
       socket,
       :info,
       dngettext(
         "chat",
         "%{message_count} message since the last memory; automatic memories have fallen behind.",
         "%{message_count} messages since the last memory; automatic memories have fallen behind.",
         n,
         message_count: Format.number(n)
       )
     )}
  end

  # The annotation popup's Rewrite saved its note and asks for the rewrite in a fresh pass.
  def handle_info(:rewrite_annotations, socket), do: rewrite_annotations(socket)

  @impl true
  def handle_async(:quick_reply, {:ok, result}, socket) do
    chat_id = socket.assigns.quick_reply_chat_id
    socket = assign(socket, quick_reply_chat_id: nil)

    socket =
      if current_chat?(socket, chat_id),
        do: Composer.apply_quick_reply(socket, result),
        else:
          put_flash(
            socket,
            :info,
            dgettext("chat", "The quick reply finished after you left its chat; its result was dropped.")
          )

    {:noreply, socket}
  end

  def handle_async(:quick_reply, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(quick_reply_chat_id: nil)
     |> put_flash(:error, dgettext("chat", "The quick reply script crashed."))}
  end

  # Patches the cached message from the payload instead of re-reading the row per token: the DB only
  # catches up on the Server's debounce. One `get_message/1` per stream (or when a new swipe body
  # appears) seeds the cache, since `stream_insert/3` needs the full preloaded struct. A message
  # that is gone (its chat was deleted mid-reply) only leaves the cache.
  defp show_body_delta(socket, %{message_id: id, body_id: body_id} = delta) do
    cache = socket.assigns.streaming_messages

    message =
      case Map.fetch(cache, id) do
        {:ok, cached} ->
          if Enum.any?(cached.bodies, &(&1.id == body_id)),
            do: cached,
            else: Messages.get_message(socket.assigns.current_scope, id)

        :error ->
          Messages.get_message(socket.assigns.current_scope, id)
      end

    cond do
      message == nil -> assign(socket, streaming_messages: Map.delete(cache, id))
      current_chat?(socket, message.chat_id) -> apply_body_delta(socket, message, delta)
      true -> socket
    end
  end

  defp open_body_delta_frame(socket) do
    Process.send_after(self(), :close_body_delta_frame, @body_delta_frame_ms)
    assign(socket, body_delta_frame?: true)
  end

  # Both reasoning texts ride the cached body; the row builder picks which one this viewer sees.
  defp apply_body_delta(socket, %Message{id: id, bodies: bodies} = message, %{body_id: body_id} = delta) do
    bodies =
      Enum.map(bodies, fn
        %{id: ^body_id} = body ->
          %{
            body
            | content: delta.content,
              reasoning: delta.reasoning,
              reasoning_redacted: delta.reasoning_redacted,
              reasoning_share_redacted: delta.reasoning_share_redacted
          }

        body ->
          body
      end)

    message = %{message | bodies: bodies}

    # A regenerate from another tab or auto mode drops an open edit or split rather than leaving an
    # editor over a streaming body.
    socket =
      if socket.assigns.editing_message_id == id,
        do: MessageActions.drop_edit(socket),
        else: socket

    socket
    |> SplitEditor.drop(id)
    |> Annotations.drop(id)
    |> assign(streaming_messages: Map.put(socket.assigns.streaming_messages, id, message))
    |> MessageWindow.restream(message)
  end

  defp current_chat?(socket, chat_id), do: match?(%{id: ^chat_id}, socket.assigns.selected_chat)

  # Re-lists the open chat's scratchpads; an open edit or discard prompt on one now gone closes.
  defp assign_scratchpads(%{assigns: %{selected_chat: %{} = chat}} = socket) do
    scratchpads = Messages.list_scratchpads(socket.assigns.current_scope, chat)
    ids = MapSet.new(scratchpads, & &1.id)

    socket
    |> assign(scratchpads: scratchpads)
    |> then(fn s ->
      if s.assigns.scratchpad_edit && not MapSet.member?(ids, s.assigns.scratchpad_edit.id),
        do: assign(s, scratchpad_edit: nil),
        else: s
    end)
    |> then(fn s ->
      if s.assigns.discarding_scratchpad_id && not MapSet.member?(ids, s.assigns.discarding_scratchpad_id),
        do: assign(s, discarding_scratchpad_id: nil),
        else: s
    end)
  end

  defp assign_scratchpads(socket), do: socket

  defp access_lost_flash(chat_title) do
    gettext_comment("Flash when the viewer was removed from the open chat or lost access to it.")
    dgettext("chat", "You no longer have access to %{chat_title}", chat_title: chat_title)
  end

  defp saved_flash(chat) do
    gettext_comment("Flash after a chat or its settings are saved.")

    dpgettext("chat", "status: flash after a chat or its settings are saved", "%{chat_title} saved",
      chat_title: Chat.title(chat)
    )
  end

  defp chat_deleted_flash(chat) do
    gettext_comment("Flash after the viewer deletes a chat.")
    dpgettext("chat", "status: flash after a chat is deleted", "%{chat_title} deleted", chat_title: Chat.title(chat))
  end

  defp chat_gone_flash(chat_title) do
    gettext_comment("Flash when the open chat was deleted, by its owner or in another window.")

    dpgettext("chat", "status: flash when the open chat was deleted elsewhere", "%{chat_title} was deleted",
      chat_title: chat_title
    )
  end

  defp added_flash(n) do
    gettext_comment("Flash after characters are added to a chat.")

    dpngettext(
      "chat",
      "status: flash after characters are added to a chat",
      "Added %{character_count} character",
      "Added %{character_count} characters",
      n,
      character_count: Format.number(n)
    )
  end

  defp invalid_flash do
    gettext_comment("Flash when a chat form has errors; the fields with errors are highlighted.")
    dgettext("chat", "Could not save — see the highlighted fields")
  end

  defp chat_participant(socket, id) do
    case socket.assigns.selected_chat do
      %{participants: participants} -> Enum.find(participants, &(&1.id == id))
      _ -> nil
    end
  end

  defp forget_typing(socket, character_id) do
    case socket.assigns.typing do
      %{^character_id => {_name, timer}} = typing ->
        Process.cancel_timer(timer)
        assign(socket, typing: Map.delete(typing, character_id))

      _ ->
        socket
    end
  end

  # Player keystrokes from other tabs, plus the character the conductor is generating for. The
  # speaker comes from `turn_state`, so every tab (the originating one included) shows it for the
  # whole reply. Keyed by character id so an AI-written player turn never lists the player twice.
  defp typing_names(typing, turn_state, chat) do
    typers = Map.new(typing, fn {id, {name, _timer}} -> {id, name} end)

    typers =
      case speaker_name(turn_state, chat) do
        nil -> typers
        name -> Map.put(typers, turn_state.speaking, name)
      end

    typers |> Map.values() |> Enum.sort()
  end

  # The generating character's name, or nil when nobody speaks or the speaker has left the chat
  # (the indicator names who is typing; it does not report errors).
  defp speaker_name(%{speaking: speaking}, chat) when not is_nil(speaking) and not is_nil(chat),
    do: Chat.participant_name(chat, speaking)

  defp speaker_name(_turn_state, _chat), do: nil

  # Body deltas deliberately do not refresh it: the generating row shows a placeholder until the
  # `:generation_finished` reload, so the modal does not re-render per token.
  defp refresh_swipe_inspector(
         %{assigns: %{swipe_inspector: %{message: %{id: id}} = inspector}} = socket,
         %{id: id} = message
       ) do
    assign(socket, swipe_inspector: %{inspector | message: message})
  end

  defp refresh_swipe_inspector(socket, _message), do: socket

  # The chat avatars' size cap (`appearance.avatar_max_*`): the custom properties `Chat.Messages`
  # reads, and the width its avatar images' `sizes` names.
  defp assign_avatar_settings(socket) do
    %{"appearance.avatar_max_width" => w, "appearance.avatar_max_height" => h} =
      Settings.get_many(socket.assigns.current_scope, ["appearance.avatar_max_width", "appearance.avatar_max_height"])

    assign(socket, avatar_style: "--avatar-max-w: #{w}px; --avatar-max-h: #{h}px", avatar_max_width: w)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      /* `div.chat-layout:scope`, not a bare `:scope`: this block's marker lands on every root tag,
         and a hidden hook element at the root once became a growing grid that took half the
         height beside a short chat.

         Each side column is a custom property, so a hidden rail only zeroes its track and the
         areas never change. */
      div.chat-layout:scope {
        --picker-col: 18rem;
        --rail-col: 30rem;
        display: grid;
        grid-template-columns: var(--picker-col) minmax(0, 1fr) var(--rail-col);
        grid-template-areas: "picker body participants";
        flex: 1 1 auto;
        min-height: 0;
        overflow: hidden;
      }

      /* The rail owns the participants grid area and scrolls its contents. */
      .chat-rail {
        grid-area: participants;
        display: flex;
        flex-direction: column;
        min-height: 0;
        overflow-y: auto;
      }

      /* Tablet: the picker becomes a drawer (its toggle is in the chat header). The participants
         rail stays, narrowed to at most 40% so the chat keeps the larger share. */
      @media (--tablet) {
        div.chat-layout:scope {
          --picker-col: 0px;
          --rail-col: min(30rem, 40%);
        }
      }

      /* Phone: the participants rail becomes a drawer too. */
      @media (--phone) {
        div.chat-layout:scope {
          --rail-col: 0px;
        }
        .chat-rail {
          display: contents;
        }
      }

      /* No participants rail beside the landing or an assistant thread, and a rail hidden from its
         header (`.RailCollapse`) gives its column to the body. */
      div.chat-wide:scope,
      div.chat-layout[data-participants-collapsed]:scope {
        --rail-col: 0px;
      }
      div.chat-layout[data-picker-collapsed]:scope {
        --picker-col: 0px;
      }
    </style>
    <%!-- Global: these reach the drawer toggles inside other components. Each rail hides its own
         root and hide button; the body components keep their own gap beside a hidden rail. --%>
    <style :type={MythweaverWeb.ColocatedCSS}>
      /* A collapsed rail's drawer toggles stand in as its "show" button. */
      .chat-layout[data-picker-collapsed]
        .button.drawer-toggle[popovertarget="chat-picker"],
      .chat-layout[data-participants-collapsed]
        .button.drawer-toggle[popovertarget="chat-participants"] {
        display: inline-flex;
      }
      .chat-layout[data-participants-collapsed] > .chat-rail {
        display: none;
      }
      /* Phone: the participants drawer lives inside the rail, which must stay a box-less wrapper. */
      @media (--phone) {
        .chat-layout[data-participants-collapsed] > .chat-rail {
          display: contents;
        }
      }
    </style>
    <Layouts.app flash={@flash} current_scope={@current_scope} chat={@selected_chat}>
      <.unread_badge :if={@selected_chat} chat_id={@selected_chat.id} />
      <script :type={Phoenix.LiveView.ColocatedHook} name=".RailCollapse">
        // Hides the chat picker or participants rail from its header button and keeps that per
        // browser in localStorage. While a rail is hidden, its drawer toggle shows on desktop too and
        // brings it back in flow instead of opening the drawer; below the rail's breakpoint (where it
        // is a drawer, `--drawer-active: 1`) the toggle opens the drawer as always. Focus moves to
        // the button that undoes each step.
        const RAILS = {
          picker: {
            attr: "data-picker-collapsed",
            key: "mythweaver:chat-picker-collapsed",
            id: "chat-picker",
          },
          participants: {
            attr: "data-participants-collapsed",
            key: "mythweaver:chat-participants-collapsed",
            id: "chat-participants",
          },
        };

        // Storage can be blocked (privacy modes); the rail then just isn't remembered.
        const stored = (key) => {
          try {
            return localStorage.getItem(key) === "1";
          } catch {
            return false;
          }
        };
        const store = (key, collapsed) => {
          try {
            if (collapsed) localStorage.setItem(key, "1");
            else localStorage.removeItem(key);
          } catch {}
        };

        const drawerMode = (id) => {
          const el = document.getElementById(id);
          return (
            !!el &&
            getComputedStyle(el).getPropertyValue("--drawer-active").trim() === "1"
          );
        };

        export default {
          mounted() {
            for (const rail of Object.values(RAILS)) {
              if (stored(rail.key)) this.el.setAttribute(rail.attr, "");
            }

            this.onClick = (event) => {
              const hide = event.target.closest("[data-rail-collapse]");
              const rail = hide && RAILS[hide.dataset.railCollapse];
              if (rail) {
                this.el.setAttribute(rail.attr, "");
                store(rail.key, true);
                this.el
                  .querySelector(`.drawer-toggle[popovertarget="${rail.id}"]`)
                  ?.focus();
                return;
              }

              const toggle = event.target.closest("button[popovertarget]");
              const target = toggle?.getAttribute("popovertarget");
              const shown = Object.values(RAILS).find((r) => r.id === target);
              if (!shown || !this.el.hasAttribute(shown.attr) || drawerMode(shown.id))
                return;

              // A cancelled click skips the button's popover invocation.
              event.preventDefault();
              this.el.removeAttribute(shown.attr);
              store(shown.key, false);
              this.el
                .querySelector(`[data-rail-collapse][aria-controls="${shown.id}"]`)
                ?.focus();
            };
            this.el.addEventListener("click", this.onClick, true);
          },

          destroyed() {
            this.el.removeEventListener("click", this.onClick, true);
          },
        };
      </script>
      <div
        id="chat-layout"
        class={["chat-layout", !roleplay?(@selected_chat) && "chat-wide"]}
        phx-hook=".RailCollapse"
        phx-mounted={JS.ignore_attributes(["data-picker-collapsed", "data-participants-collapsed"])}
      >
        <.chat_picker
          chats={@visible_chats}
          shared_chats={@visible_shared_chats}
          filter_form={@filter_form}
          search?={@chat_search?}
          filtering?={@query != "" or @tag_filter != []}
          tag_filter={@tag_filter}
          tag_filter_errors={@tag_filter_errors}
          tag_filter_invalid={@tag_filter_invalid}
          tag_vocabulary={@tag_vocabulary}
          selected_id={@selected_chat && @selected_chat.id}
          form={@chat_form}
          form_choices={@chat_form_choices}
          form_completions={@chat_form_completions}
          character_options={@character_options}
          unread_ids={@unread_chats}
          bulk={@bulk}
          viewer_id={@current_scope.user.id}
          tag_graph={@tag_graph}
        />
        <.assistant_landing
          :if={@selected_chat == nil}
          form={@composer_form}
          model_error={@assistant_model_error}
          model_notice={
            @assistant_model_error && AssistantChat.assistant_error(@assistant_model_error)
          }
          settings_form={@assistant_landing_form}
          model_options={@assistant_model_options}
          default_label={@assistant_default_label}
          model_label={
            assistant_model_label(
              @assistant_model_options,
              @assistant_model_id,
              @assistant_default_label
            )
          }
        />
        <.assistant_chat
          :if={@selected_chat && @selected_chat.kind == :assistant}
          chat={@selected_chat}
          messages={@streams.messages}
          empty?={@messages_empty?}
          loading?={@message_window.loading?}
          has_older?={@message_window.older?}
          running?={@assistant_running?}
          cards={@assistant_cards}
          form={@composer_form}
          upload={if @can_attach?, do: @uploads.composer_files}
          composer_attachments={@composer_attachments}
        />
        <.messages
          :if={roleplay?(@selected_chat)}
          chat={@selected_chat}
          messages={@streams.messages}
          empty?={@messages_empty?}
          loading?={@message_window.loading?}
          has_older?={@message_window.older?}
          has_newer?={@message_window.newer?}
          embedding_status={@embedding_status}
          view_hidden?={Visibility.view_hidden?(@current_scope)}
          form={@composer_form}
          upload={
            if @can_attach? and chat_access(@current_scope, @selected_chat, @role).attach?,
              do: @uploads.composer_files
          }
          composer_attachments={@composer_attachments}
          editing_attachment_id={@editing_attachment_id}
          caption_reviews={@caption_reviews}
          can_send?={@composer_form != nil}
          composer_notice={Composer.composer_notice(@role, @selected_chat)}
          access={chat_access(@current_scope, @selected_chat, @role)}
          viewer_member={@viewer_member}
          model_options={@model_options}
          skip_turn?={@selected_chat.turn_mode == :round and @my_locks != []}
          poster_name={poster_label(assigns)}
          typing={typing_names(@typing, @turn_state, @selected_chat)}
          ai_typing?={speaker_name(@turn_state, @selected_chat) != nil}
          generating?={@turn_state.speaking != nil}
          turn_state={@turn_state}
          editing_id={@editing_message_id}
          edit_form={@edit_form}
          avatar_style={@avatar_style}
          avatar_max_width={@avatar_max_width}
          edit_attachments={@edit_attachments}
          edit_upload={
            if @can_attach? and chat_access(@current_scope, @selected_chat, @role).attach?,
              do: @uploads.edit_files
          }
          edit_caret={@edit_caret}
          selected={@selected_messages}
          reattributing={@reattributing}
          expression_picker={@expression_picker}
          split={@split}
          annotations={@annotations}
          scratchpads={@scratchpads}
          scratchpad_edit={@scratchpad_edit}
          discarding_scratchpad_id={@discarding_scratchpad_id}
          injection_count={@injection_count}
          job_count={@job_count}
          review_count={@review_count}
          reply_job={@reply_job}
          queue_positions={@queue_positions}
          memory_boundary={@memory_boundary}
          memory_progress={@memory_progress}
          guided?={guided?(@composer_text, @composer_attachments)}
          refinable?={String.trim(@composer_text) != ""}
          completions={@template_completions}
          quick_replies={
            if chat_access(@current_scope, @selected_chat, @role).run_scripts?,
              do: @quick_replies,
              else: []
          }
          quick_reply_running?={@quick_reply_chat_id != nil}
        />
        <div :if={roleplay?(@selected_chat)} class="chat-rail">
          <.participants
            chat={@selected_chat}
            character_options={
              if @role == :guest,
                do: Enum.map(@own_characters, &{&1.name, &1.id}),
                else: @character_options
            }
            access={chat_access(@current_scope, @selected_chat, @role)}
            locks={@locks}
            my_locks={@my_locks}
            poster_id={Members.poster_id(@role, @my_locks, @posting_as, @selected_chat)}
            adding_participant?={@adding_participant?}
            turn_state={@turn_state}
            editing_participant={@editing_participant}
            participant_outfit_options={@participant_outfit_options}
            model_options={@model_options}
            default_model_id={@default_model_id}
            hide_muted?={@hide_muted?}
            guided?={guided?(@composer_text, @composer_attachments)}
            search?={@participant_search?}
            filter={@participant_filter}
            filtered_out={
              filtered_participants(
                @selected_chat,
                @participant_filter,
                @participant_tags,
                @tag_graph
              )
            }
            tag_vocabulary={@tag_vocabulary}
            adding_ids={@adding_participant_ids}
            viewer_id={@current_scope.user.id}
            tag_graph={@tag_graph}
          />
        </div>
      </div>
      <.chat_settings
        :if={@settings_form}
        chat={@selected_chat}
        current_scope={@current_scope}
        form={@settings_form}
        tab={@settings_tab}
        character_options={@character_options}
        model_options={@model_options}
        lore_book_options={@lore_book_options}
        prompt_options={@prompt_options}
        tag_field={@tag_fields.chat}
        tag_vocabulary={@tag_vocabulary}
        viewer_id={@current_scope.user.id}
        can_report={Mythweaver.Accounts.Scope.can?(@current_scope, "reports.create")}
        tag_graph={@tag_graph}
        role={@role}
        members={@members}
        invite_form={@member_invite_form}
        locks={@locks}
        lock_holders={@lock_holders}
        player_rows_added={@player_rows_added}
      />
      <.assistant_settings
        :if={@assistant_settings_form}
        chat={@selected_chat}
        form={@assistant_settings_form}
        model_options={@assistant_model_options}
        default_label={@assistant_default_label}
      />
      <.turn_queue
        :if={@queue_open? && @selected_chat}
        chat={@selected_chat}
        turn_state={@turn_state}
      />
      <.delete_confirm :if={@delete_confirm} confirm={@delete_confirm} />
      <.swipe_inspector :if={@swipe_inspector} inspector={@swipe_inspector} />
      <.prompt_inspector :if={@prompt_inspector} inspector={@prompt_inspector} />
      <.image_request
        :if={@image_request && @selected_chat}
        request={@image_request}
        input_id={@uploads.composer_files.ref}
      />
      <.caption_question :if={@caption_question && @selected_chat} question={@caption_question} />
      <.chat_variables :if={@chat_variables} panel={@chat_variables} />
      <.memory_panel
        :if={@memory_panel}
        chat={@selected_chat}
        panel={@memory_panel}
        queue_positions={@queue_positions}
        viewer_id={@current_scope.user.id}
        tag_graph={@tag_graph}
        tag_vocabulary={@tag_vocabulary}
      />
      <.clip_dialog :if={@clip_draft} draft={@clip_draft} />
      <.chat_injections
        :if={@chat_injections}
        panel={@chat_injections}
        completions={@template_completions}
      />
      <ReportModal.report_modal :if={@reporting} reporting={@reporting} />
    </Layouts.app>
    """
  end
end
