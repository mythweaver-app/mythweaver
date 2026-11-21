defmodule MythweaverWeb.MainChatLive.MemoryPanel do
  @moduledoc """
  State and events of the chat's memory modal (`MythweaverWeb.Chat.MemoryPanel`), routed at
  `/chats/:id/memory`. One assign, `memory_panel`, holds the chat's memory settings, profile,
  preferences, book, records and review jobs plus the tab's forms; it is nil while the modal is closed.

  Display numbers in forms are message positions plus one, as the transcript shows them.
  """
  use MythweaverWeb, :verified_routes
  use Gettext, backend: Mythweaver.Gettext

  import Phoenix.Component, only: [assign: 2, to_form: 2]
  import Phoenix.LiveView, only: [push_patch: 2, put_flash: 3]

  alias Mythweaver.AI
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Format
  alias Mythweaver.Jobs
  alias Mythweaver.Lore
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Memory
  alias Mythweaver.Memory.CharacterBooks
  alias Mythweaver.Memory.Clips
  alias Mythweaver.Memory.Consolidation
  alias Mythweaver.Memory.Scene
  alias Mythweaver.Memory.SidePrompts
  alias Mythweaver.Messages
  alias Mythweaver.Prompts
  alias Mythweaver.Tokenizer

  @tabs ~w(memory reviews entries consolidate topical side characters context settings)

  # The review tags whose drafts the Reviews tab can edit.
  @review_tags [:memory, :consolidation, :compaction, :topical_clip, :side_prompt, :memory_assistance]

  @events ~w(close_memory memory_create memory_validate_create memory_create_confirm memory_next memory_catchup
             memory_boundary memory_boundary_clear memory_validate_settings memory_save_settings
             memory_review_change memory_review_save memory_review_regenerate memory_review_discard
             memory_review_regenerate_candidate
             memory_entry_regenerate memory_entry_regenerate_confirm memory_entry_compact
             memory_consolidate_change memory_consolidate_run
             memory_topical_change memory_topical_run memory_side_toggle memory_side_run
             memory_picker_search memory_picker_more memory_picker_toggle memory_picker_select_range
             memory_picker_select_loaded memory_picker_clear memory_combine_run memory_character_lock
             memory_character_unlock memory_character_book_new memory_character_book_change
             memory_character_book_add memory_character_book_cancel memory_character_book_delete
             memory_context_new memory_context_change memory_context_add memory_context_cancel
             memory_context_delete
             memory_side_run_row memory_side_run_set
             memory_topic_suggestion_draft memory_topic_suggestion_dismiss)

  def events, do: @events

  @doc "Opens (or, already open, re-tabs and re-prefills) the panel from the route's query params."
  def open(socket, chat, params) do
    scope = socket.assigns.current_scope
    tab = if params["tab"] in @tabs, do: params["tab"], else: "memory"

    panel =
      case socket.assigns.memory_panel do
        %{chat_id: id} = panel when id == chat.id -> with_tab_state(scope, %{panel | tab: tab}, chat, panel)
        _closed -> with_tab_state(scope, load(scope, chat, tab), chat, nil)
      end

    panel =
      case {display_number(params["start"]), display_number(params["end"])} do
        {{:ok, first}, {:ok, last}} ->
          %{panel | create_form: create_form(first, last, panel.prefs.default_previous_count), warning: nil}

        _ ->
          panel
      end

    panel =
      case {display_number(params["catchup_start"]), display_number(params["catchup_end"]),
            count(params["catchup_chunk"])} do
        {{:ok, first}, {:ok, last}, {:ok, chunk}} ->
          %{panel | catchup_form: catchup_form(first, last, chunk), catchup_error: nil}

        _ ->
          panel
      end

    panel =
      case {panel.side, side_prefill(params, panel.side_prompt_list)} do
        {%{} = side, %{} = prefill} -> %{panel | side: Map.put(side, :prefill, prefill)}
        _ -> panel
      end

    panel = with_extract(panel, scope, chat, params)

    assign(socket, memory_panel: panel)
  end

  # "Extract" from highlighted text: a new picked-messages clip about the text, the picker searched
  # for it, and the highlighted message picked.
  defp with_extract(%{tab: "topical", topical: %{} = state} = panel, scope, chat, %{"extract" => extract} = params)
       when is_binary(extract) and extract != "" do
    {results, more?} = Messages.search_messages(scope, chat, extract, offset: 0)
    form_params = %{"topic" => extract, "include_messages" => "true", "message_mode" => "pick"}
    state = topical_state(scope, panel, form_params, state)

    picked =
      with id when is_binary(id) <- params["extract_message"],
           {:ok, id} <- Ecto.UUID.cast(id),
           %{chat_id: chat_id} = message when chat_id == chat.id <- Messages.get_message(scope, id) do
        %{message.id => message.position + 1}
      else
        _ -> %{}
      end

    picker = %{query: extract, hidden_only: false, results: results, more?: more?}
    %{panel | topical: %{state | picker: picker, picked: picked}}
  end

  defp with_extract(panel, _scope, _chat, _params), do: panel

  defp picker_search(socket, chat, query, hidden_only, offset),
    do: Messages.search_messages(socket.assigns.current_scope, chat, query, hidden_only: hidden_only, offset: offset)

  defp put_topical(%{assigns: %{memory_panel: panel}} = socket, state),
    do: assign(socket, memory_panel: %{panel | topical: state})

  @doc "Re-reads the open panel's data after a memory or job change; half-typed settings survive."
  def reload(%{assigns: %{memory_panel: %{} = panel, selected_chat: %{} = chat}} = socket) do
    scope = socket.assigns.current_scope
    fresh = load(scope, chat, panel.tab)

    assign(socket,
      memory_panel:
        with_tab_state(
          scope,
          %{
            fresh
            | settings_form: if(panel.settings_form.source.action, do: panel.settings_form, else: fresh.settings_form),
              catchup_form: panel.catchup_form,
              character_book_form: panel.character_book_form,
              character_book_error: panel.character_book_error,
              context_form: panel.context_form,
              context_error: panel.context_error,
              warning: panel.warning,
              regenerate_warning: panel.regenerate_warning,
              create_error: panel.create_error,
              catchup_error: panel.catchup_error,
              review_errors: panel.review_errors,
              review_forceable: panel.review_forceable,
              review_edits: Map.take(panel.review_edits, Enum.map(fresh.reviews, & &1.id)),
              topic_suggestions_error: panel.topic_suggestions_error
          },
          chat,
          panel
        )
    )
  end

  def reload(socket), do: socket

  def handle_event("close_memory", _params, %{assigns: %{selected_chat: %{} = chat}} = socket),
    do: {:noreply, push_patch(socket, to: ~p"/chats/#{chat.id}")}

  def handle_event(
        "memory_create",
        %{"memory_create" => params},
        %{assigns: %{memory_panel: %{} = panel, selected_chat: %{} = chat}} = socket
      ) do
    with {:ok, first} <- display_number(params["start"]),
         {:ok, last} <- display_number(params["end"]),
         {:ok, previous} <- count(params["previous_count"]) do
      participant_ids = Enum.reject(params["participant_ids"] || [], &(&1 == ""))
      create(socket, panel, chat, first, last, previous, false, participant_ids)
    else
      :error ->
        {:noreply,
         assign(socket,
           memory_panel: %{
             panel
             | create_error: error_message(:bad_numbers),
               create_form: to_form(params, as: :memory_create)
           }
         )}
    end
  end

  # Feeds the live picker selection back, so a re-render keeps the boxes the user checked.
  def handle_event(
        "memory_validate_create",
        %{"memory_create" => params},
        %{assigns: %{memory_panel: %{} = panel}} = socket
      ) do
    params = Map.update(params, "participant_ids", [], &(&1 |> List.wrap() |> Enum.reject(fn id -> id == "" end)))
    {:noreply, assign(socket, memory_panel: %{panel | create_form: to_form(params, as: :memory_create)})}
  end

  def handle_event(
        "memory_create_confirm",
        _params,
        %{assigns: %{memory_panel: %{warning: %{} = warning} = panel, selected_chat: %{} = chat}} = socket
      ),
      do:
        create(socket, panel, chat, warning.first, warning.last, warning.previous_count, true, warning.participant_ids)

  def handle_event("memory_next", _params, %{assigns: %{memory_panel: %{} = panel, selected_chat: %{} = chat}} = socket) do
    case Memory.next_range(socket.assigns.current_scope, chat) do
      {first, last} ->
        create(socket, panel, chat, first, last, panel.prefs.default_previous_count, false, [])

      :none ->
        {:noreply,
         assign(socket,
           memory_panel: %{panel | create_error: all_processed_message()}
         )}
    end
  end

  # From the command palette, with the panel closed: queue the next scene directly and report by flash.
  def handle_event("memory_next", _params, %{assigns: %{memory_panel: nil, selected_chat: %{} = chat}} = socket) do
    scope = socket.assigns.current_scope

    with {first, last} <- Memory.next_range(scope, chat),
         {:ok, job} <-
           Memory.create_memory(scope, chat, first, last,
             previous_count: Memory.preferences(scope).default_previous_count,
             participant_ids: []
           ) do
      {:noreply, put_flash(socket, :info, queued(job.label))}
    else
      :none ->
        {:noreply, put_flash(socket, :error, all_processed_message())}

      {:confirm, tokens} ->
        gettext_comment("Flash when the next-scene command would send more tokens than the warning limit.")

        {:noreply,
         put_flash(
           socket,
           :error,
           dngettext(
             "memory",
             "The next scene is about %{token_count} token, over the warning limit. Create it from the memory dialog to confirm.",
             "The next scene is about %{token_count} tokens, over the warning limit. Create it from the memory dialog to confirm.",
             tokens,
             token_count: Format.number(tokens)
           )
         )}

      {:error, :unauthorized} ->
        unauthorized(socket)

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event(
        "memory_catchup",
        %{"memory_catchup" => params},
        %{assigns: %{memory_panel: %{} = panel, selected_chat: %{} = chat}} = socket
      ) do
    form = to_form(params, as: :memory_catchup)

    result =
      with {:ok, first} <- display_number(params["start"]),
           {:ok, last} <- display_number(params["end"]),
           {:ok, chunk} <- count(params["chunk"]) do
        Memory.catch_up(socket.assigns.current_scope, chat, first, last, chunk)
      else
        :error -> {:error, :bad_numbers}
      end

    case result do
      {:ok, jobs} ->
        gettext_comment("Flash after catch-up memories were queued for a message range.")

        {:noreply,
         socket
         |> assign(memory_panel: %{panel | catchup_form: form, catchup_error: nil})
         |> put_flash(
           :info,
           dpngettext(
             "memory",
             "status: flash after catch-up memories were queued",
             "Catch-up queued: %{memory_count} memory",
             "Catch-up queued: %{memory_count} memories",
             length(jobs),
             memory_count: Format.number(length(jobs))
           )
         )}

      {:error, :unauthorized} ->
        unauthorized(socket)

      {:error, reason} ->
        {:noreply, assign(socket, memory_panel: %{panel | catchup_form: form, catchup_error: error_message(reason)})}
    end
  end

  def handle_event(
        "memory_boundary",
        %{"memory_boundary" => %{"number" => number}},
        %{assigns: %{memory_panel: %{}, selected_chat: %{} = chat}} = socket
      ) do
    case display_number(number) do
      {:ok, position} ->
        {:ok, _} = Memory.set_highest_processed(socket.assigns.current_scope, chat, position)
        {:noreply, reload(socket)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "memory_boundary_clear",
        _params,
        %{assigns: %{memory_panel: %{}, selected_chat: %{} = chat}} = socket
      ) do
    {:ok, _} = Memory.set_highest_processed(socket.assigns.current_scope, chat, nil)
    {:noreply, reload(socket)}
  end

  def handle_event(
        "memory_validate_settings",
        %{"memory_settings" => params},
        %{assigns: %{memory_panel: %{} = panel}} = socket
      ) do
    changeset = panel.settings |> Memory.change_chat_settings(settings_attrs(params)) |> Map.put(:action, :validate)
    {:noreply, assign(socket, memory_panel: %{panel | settings_form: to_form(changeset, as: :memory_settings)})}
  end

  def handle_event(
        "memory_save_settings",
        %{"memory_settings" => params},
        %{assigns: %{memory_panel: %{} = panel, selected_chat: %{} = chat}} = socket
      ) do
    scope = socket.assigns.current_scope

    case Memory.update_chat_settings(scope, panel.settings, settings_attrs(params)) do
      {:ok, _settings} ->
        Memory.broadcast_changed(chat.id)
        fresh = load(scope, chat, panel.tab)

        {:noreply,
         socket
         |> assign(memory_panel: fresh)
         |> put_flash(:info, settings_saved_flash())}

      {:error, :unauthorized} ->
        unauthorized(socket)

      {:error, changeset} ->
        {:noreply, assign(socket, memory_panel: %{panel | settings_form: to_form(changeset, as: :memory_settings)})}
    end
  end

  def handle_event(event, %{"character-id" => id}, %{assigns: %{memory_panel: %{}, selected_chat: %{} = chat}} = socket)
      when event in ~w(memory_character_lock memory_character_unlock) do
    scope = socket.assigns.current_scope

    {result, flash} =
      if event == "memory_character_lock",
        do: {CharacterBooks.lock_character_book(scope, chat, id), locked_flash()},
        else: {CharacterBooks.unlock_character_book(scope, chat, id), unlocked_flash()}

    case result do
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
      _ok -> {:noreply, socket |> reload() |> put_flash(:info, flash)}
    end
  end

  def handle_event("memory_character_book_new", _params, %{assigns: %{memory_panel: %{} = panel}} = socket) do
    form = to_form(%{"character_id" => "", "book_id" => "", "lock" => "false"}, as: :memory_character_book)
    {:noreply, assign(socket, memory_panel: %{panel | character_book_form: form, character_book_error: nil})}
  end

  def handle_event(
        "memory_character_book_change",
        %{"memory_character_book" => params},
        %{assigns: %{memory_panel: %{} = panel}} = socket
      ),
      do:
        {:noreply,
         assign(socket, memory_panel: %{panel | character_book_form: to_form(params, as: :memory_character_book)})}

  def handle_event("memory_character_book_cancel", _params, %{assigns: %{memory_panel: %{} = panel}} = socket),
    do: {:noreply, assign(socket, memory_panel: %{panel | character_book_form: nil, character_book_error: nil})}

  def handle_event(
        "memory_character_book_add",
        %{"memory_character_book" => params},
        %{assigns: %{memory_panel: %{} = panel, selected_chat: %{} = chat}} = socket
      ) do
    form = to_form(params, as: :memory_character_book)
    refuse = &{:noreply, assign(socket, memory_panel: %{panel | character_book_form: form, character_book_error: &1})}

    if params["character_id"] in [nil, ""] or params["book_id"] in [nil, ""] do
      refuse.(dgettext("memory", "Pick a character and a book."))
    else
      scope = socket.assigns.current_scope

      case CharacterBooks.assign_character_book(
             scope,
             chat,
             params["character_id"],
             params["book_id"],
             params["lock"] == "true"
           ) do
        {:ok, _settings} ->
          {:noreply,
           socket
           |> assign(memory_panel: %{panel | character_book_form: nil, character_book_error: nil})
           |> reload()
           |> put_flash(:info, character_book_added_flash())}

        {:error, :unauthorized} ->
          unauthorized(socket)

        {:error, :not_found} ->
          refuse.(dgettext("memory", "That character is no longer in this chat."))

        {:error, %Ecto.Changeset{}} ->
          refuse.(dgettext("memory", "Pick a character and a book."))
      end
    end
  end

  def handle_event(
        "memory_character_book_delete",
        %{"character-id" => id},
        %{assigns: %{memory_panel: %{}, selected_chat: %{} = chat}} = socket
      ) do
    case CharacterBooks.remove_character_book(socket.assigns.current_scope, chat, id) do
      :ok ->
        {:noreply, socket |> reload() |> put_flash(:info, character_book_removed_flash())}

      {:error, :unauthorized} ->
        unauthorized(socket)
    end
  end

  def handle_event("memory_context_new", _params, %{assigns: %{memory_panel: %{} = panel}} = socket) do
    form = to_form(%{"entry_ids" => []}, as: :memory_context)
    {:noreply, assign(socket, memory_panel: %{panel | context_form: form, context_error: nil})}
  end

  # The picker's own filter keys (`memory-context-picker[...]`) ride along in `params`; only the
  # selection matters. `MultiSelect` needs it sent back as `selected`.
  def handle_event(
        "memory_context_change",
        %{"memory_context" => params},
        %{assigns: %{memory_panel: %{} = panel}} = socket
      ), do: {:noreply, assign(socket, memory_panel: %{panel | context_form: context_form(params)})}

  def handle_event("memory_context_cancel", _params, %{assigns: %{memory_panel: %{} = panel}} = socket),
    do: {:noreply, assign(socket, memory_panel: %{panel | context_form: nil, context_error: nil})}

  def handle_event(
        "memory_context_add",
        %{"memory_context" => params},
        %{assigns: %{memory_panel: %{} = panel, selected_chat: %{} = chat}} = socket
      ) do
    form = context_form(params)
    refuse = &{:noreply, assign(socket, memory_panel: %{panel | context_form: form, context_error: &1})}

    case form[:entry_ids].value do
      [] ->
        refuse.(dgettext("memory", "Pick at least one entry."))

      picked ->
        scope = socket.assigns.current_scope
        settings = Memory.chat_settings(scope, chat)
        ids = settings.context_entry_ids ++ (Enum.uniq(picked) -- settings.context_entry_ids)

        case Memory.update_chat_settings(scope, settings, %{"context_entry_ids" => ids}) do
          {:ok, _settings} ->
            Memory.broadcast_changed(chat.id)

            {:noreply,
             socket
             |> assign(memory_panel: %{panel | context_form: nil, context_error: nil})
             |> reload()
             |> put_flash(:info, context_entries_added_flash())}

          {:error, :unauthorized} ->
            unauthorized(socket)

          {:error, _changeset} ->
            refuse.(dgettext("memory", "Could not add those entries."))
        end
    end
  end

  def handle_event(
        "memory_context_delete",
        %{"id" => id},
        %{assigns: %{memory_panel: %{}, selected_chat: %{} = chat}} = socket
      ) do
    scope = socket.assigns.current_scope
    settings = Memory.chat_settings(scope, chat)

    case Memory.update_chat_settings(scope, settings, %{
           "context_entry_ids" => List.delete(settings.context_entry_ids, id)
         }) do
      {:ok, _settings} ->
        Memory.broadcast_changed(chat.id)
        {:noreply, socket |> reload() |> put_flash(:info, context_entry_removed_flash())}

      {:error, :unauthorized} ->
        unauthorized(socket)

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, context_entry_remove_failed_flash())}
    end
  end

  # Review ids are looked up in the panel's own list, which is this chat's review jobs, so a crafted
  # id cannot reach another chat's job.
  # `ignore_changes` is the Save anyway button, offered once a save was refused because the source
  # changed.
  def handle_event("memory_review_save", %{"job_id" => id} = params, %{assigns: %{memory_panel: %{} = panel}} = socket) do
    case Enum.find(panel.reviews, &(&1.id == id)) do
      %{} = job ->
        opts = if params["ignore_changes"] == "true", do: [ignore_changes: true], else: []

        socket.assigns.current_scope
        |> Memory.approve(job, params["review"] || %{}, opts)
        |> review_result(socket, panel, id, saved_message(job.tag))

      nil ->
        {:noreply, socket}
    end
  end

  # A review form's last posted values, so its keyword chips show what was added or removed. Only
  # the chips read them; its other fields keep their typed text through a re-render on their own.
  def handle_event(
        "memory_review_change",
        %{"job_id" => id} = params,
        %{assigns: %{memory_panel: %{} = panel}} = socket
      ) do
    if Enum.any?(panel.reviews, &(&1.id == id)),
      do:
        {:noreply,
         assign(socket, memory_panel: %{panel | review_edits: Map.put(panel.review_edits, id, params["review"] || %{})})},
      else: {:noreply, socket}
  end

  def handle_event(event, %{"id" => id}, %{assigns: %{memory_panel: %{} = panel}} = socket)
      when event in ~w(memory_review_regenerate memory_review_discard) do
    case Enum.find(panel.reviews, &(&1.id == id)) do
      %{} = job ->
        scope = socket.assigns.current_scope

        result =
          if event == "memory_review_discard", do: Memory.discard(scope, job), else: Jobs.retry(scope, job.id)

        review_result(result, socket, panel, id, nil)

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "memory_review_regenerate_candidate",
        %{"id" => id, "index" => index},
        %{assigns: %{memory_panel: %{} = panel}} = socket
      ) do
    with %{} = job <- Enum.find(panel.reviews, &(&1.id == id)),
         {n, ""} <- Integer.parse(index) do
      socket.assigns.current_scope
      |> Consolidation.regenerate_candidate(job, n)
      |> review_result(socket, panel, id, regenerating_summary_flash())
    else
      _other -> {:noreply, socket}
    end
  end

  # Record ids are looked up in the chat book's own records.
  def handle_event(event, %{"id" => id}, %{assigns: %{memory_panel: %{} = panel, selected_chat: %{} = chat}} = socket)
      when event in ~w(memory_entry_regenerate memory_entry_regenerate_confirm memory_entry_compact) do
    case Enum.find(panel.records, &(&1.id == id)) do
      %{} = record when event == "memory_entry_compact" ->
        case Memory.compact(socket.assigns.current_scope, chat, record) do
          {:ok, job} -> {:noreply, put_flash(socket, :info, queued(job.label))}
          {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
        end

      %{} = record ->
        regenerate(socket, panel, chat, record, event == "memory_entry_regenerate_confirm")

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "memory_consolidate_change",
        %{"memory_consolidate" => params},
        %{assigns: %{memory_panel: %{consolidate: %{} = state} = panel, selected_chat: %{} = chat}} = socket
      ) do
    state = consolidate_state(socket.assigns.current_scope, chat, panel, params, state)
    {:noreply, assign(socket, memory_panel: %{panel | consolidate: %{state | error: nil}})}
  end

  def handle_event(
        "memory_consolidate_run",
        %{"memory_consolidate" => params},
        %{assigns: %{memory_panel: %{consolidate: %{} = state} = panel, selected_chat: %{} = chat}} = socket
      ) do
    scope = socket.assigns.current_scope
    state = consolidate_state(scope, chat, panel, params, state)

    result =
      case state.book_id && Lore.get_book(scope, state.book_id) do
        %LoreBook{} = book ->
          Consolidation.consolidate(
            scope,
            chat,
            book,
            state.tier,
            Enum.filter(Enum.map(state.eligible, & &1.id), &(&1 in state.selected)),
            prompt_id: state.prompt_id,
            disable_sources: state.disable_sources,
            max_entries: state.max_entries,
            token_budget: state.token_budget
          )

        nil ->
          {:error, :no_sources}
      end

    case result do
      {:ok, jobs} ->
        gettext_comment("Flash after a consolidation run was queued.")

        {:noreply,
         socket
         |> assign(memory_panel: %{panel | consolidate: state})
         |> put_flash(
           :info,
           dpngettext(
             "memory",
             "status: flash after consolidation passes were queued",
             "Consolidation queued: %{pass_count} pass",
             "Consolidation queued: %{pass_count} passes",
             length(jobs),
             pass_count: Format.number(length(jobs))
           )
         )}

      {:error, :unauthorized} ->
        unauthorized(socket)

      {:error, reason} ->
        {:noreply, assign(socket, memory_panel: %{panel | consolidate: %{state | error: error_message(reason)}})}
    end
  end

  def handle_event(
        "memory_topical_change",
        %{"memory_topical" => params},
        %{assigns: %{memory_panel: %{topical: %{} = state} = panel}} = socket
      ) do
    state = topical_state(socket.assigns.current_scope, panel, params, state)
    {:noreply, assign(socket, memory_panel: %{panel | topical: %{state | error: nil}})}
  end

  def handle_event(
        "memory_topical_run",
        %{"memory_topical" => params},
        %{assigns: %{memory_panel: %{topical: %{} = state} = panel, selected_chat: %{} = chat}} = socket
      ) do
    scope = socket.assigns.current_scope
    state = topical_state(scope, panel, params, state)

    result =
      with {:ok, range} <- topical_range(state) do
        Clips.topical_clip(
          scope,
          chat,
          [
            book_id: state.book_id,
            topic: state.params["topic"],
            keywords: state.params["keywords"],
            target_record_id: state.target && state.target.id,
            include_memories: state.include_memories,
            record_ids: Enum.filter(Enum.map(state.sources, & &1.id), &MapSet.member?(state.selected, &1)),
            include_messages: state.include_messages,
            rebuild: state.rebuild
          ] ++ range
        )
      end

    case result do
      {:ok, job} ->
        gettext_comment(
          "Flash after a topical clip job was queued; %{job_label} is the job's name, such as Topical clip — Mira's sword."
        )

        {:noreply,
         socket
         |> assign(memory_panel: %{panel | topical: state})
         |> put_flash(
           :info,
           dgettext("memory", "%{job_label} queued: review it under Reviews", job_label: job.label)
         )}

      {:error, :unauthorized} ->
        unauthorized(socket)

      {:error, reason} ->
        {:noreply, assign(socket, memory_panel: %{panel | topical: %{state | error: topical_error(reason, state)}})}
    end
  end

  # The message picker changes only the topical state; it never reloads the panel.
  def handle_event(
        "memory_picker_search",
        params,
        %{assigns: %{memory_panel: %{topical: %{} = state}, selected_chat: %{} = chat}} = socket
      ) do
    params = params["memory_picker"] || params
    query = params["query"] || ""
    hidden_only = params["hidden_only"] == "true"
    {results, more?} = picker_search(socket, chat, query, hidden_only, 0)
    picker = %{query: query, hidden_only: hidden_only, results: results, more?: more?}
    {:noreply, put_topical(socket, %{state | picker: picker})}
  end

  def handle_event(
        "memory_picker_more",
        _params,
        %{assigns: %{memory_panel: %{topical: %{picker: picker} = state}, selected_chat: %{} = chat}} = socket
      ) do
    {results, more?} = picker_search(socket, chat, picker.query, picker.hidden_only, length(picker.results))
    {:noreply, put_topical(socket, %{state | picker: %{picker | results: picker.results ++ results, more?: more?}})}
  end

  def handle_event("memory_picker_toggle", %{"id" => id}, %{assigns: %{memory_panel: %{topical: %{} = state}}} = socket) do
    case Enum.find(state.picker.results, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      message ->
        picked =
          if Map.has_key?(state.picked, id),
            do: Map.delete(state.picked, id),
            else: Map.put(state.picked, id, message.position + 1)

        {:noreply, put_topical(socket, %{state | picked: picked})}
    end
  end

  # A shift-click range from the `RangeSelect` hook (assets/js/hooks/range_select.ts): pick every
  # listed result that is shown.
  def handle_event(
        "memory_picker_select_range",
        %{"ids" => ids},
        %{assigns: %{memory_panel: %{topical: %{} = state}}} = socket
      )
      when is_list(ids) do
    ids = MapSet.new(ids)
    picked = for m <- state.picker.results, m.id in ids, into: state.picked, do: {m.id, m.position + 1}
    {:noreply, put_topical(socket, %{state | picked: picked})}
  end

  def handle_event(
        "memory_picker_select_loaded",
        _params,
        %{assigns: %{memory_panel: %{topical: %{} = state}}} = socket
      ) do
    picked = Enum.reduce(state.picker.results, state.picked, &Map.put(&2, &1.id, &1.position + 1))
    {:noreply, put_topical(socket, %{state | picked: picked})}
  end

  def handle_event("memory_picker_clear", _params, %{assigns: %{memory_panel: %{topical: %{} = state}}} = socket),
    do: {:noreply, put_topical(socket, %{state | picked: %{}})}

  def handle_event(
        "memory_combine_run",
        params,
        %{assigns: %{memory_panel: %{topical: %{} = state} = panel, selected_chat: %{} = chat}} = socket
      ) do
    params = params["memory_combine"] || %{}
    ids = Enum.reject(params["record_ids"] || [], &(&1 == ""))
    disable? = params["disable_originals"] == "true"

    result =
      Clips.combine_clips(socket.assigns.current_scope, chat,
        book_id: state.book_id,
        record_ids: ids,
        title: params["title"],
        disable_originals: disable?
      )

    case result do
      {:ok, _job} ->
        state = %{state | combine_form: combine_form(%{}), combine_error: nil}

        {:noreply,
         socket
         |> assign(memory_panel: %{panel | topical: state})
         |> put_flash(:info, combining_clips_flash())}

      {:error, reason} ->
        state = %{state | combine_form: combine_form(params), combine_error: error_message(reason)}
        {:noreply, assign(socket, memory_panel: %{panel | topical: state})}
    end
  end

  def handle_event(
        "memory_topic_suggestion_draft",
        %{"id" => id},
        %{assigns: %{memory_panel: %{} = panel, selected_chat: %{} = chat}} = socket
      ) do
    case Clips.draft_topic_suggestion(socket.assigns.current_scope, chat, id) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> assign(memory_panel: %{panel | topic_suggestions_error: nil})
         |> reload()
         |> put_flash(:info, drafting_clip_flash())}

      {:error, reason} ->
        {:noreply, assign(socket, memory_panel: %{panel | topic_suggestions_error: suggestion_error(reason)})}
    end
  end

  def handle_event(
        "memory_topic_suggestion_dismiss",
        %{"id" => id},
        %{assigns: %{memory_panel: %{} = panel, selected_chat: %{} = chat}} = socket
      ) do
    case Clips.dismiss_topic_suggestion(socket.assigns.current_scope, chat, id) do
      :ok ->
        {:noreply, socket |> assign(memory_panel: %{panel | topic_suggestions_error: nil}) |> reload()}

      {:error, reason} ->
        {:noreply, assign(socket, memory_panel: %{panel | topic_suggestions_error: suggestion_error(reason)})}
    end
  end

  # Side prompt ids are looked up in the tab's own list.
  def handle_event("memory_side_toggle", %{"id" => id}, %{assigns: %{memory_panel: %{side: %{} = side}}} = socket) do
    case Enum.find(side.side_prompts, &(&1.id == id)) do
      %{} = side_prompt ->
        case Memory.update_side_prompt(socket.assigns.current_scope, side_prompt, %{enabled: !side_prompt.enabled}) do
          {:ok, _} ->
            {:noreply, reload(socket)}

          {:error, :unauthorized} ->
            unauthorized(socket)

          {:error, _changeset} ->
            gettext_comment("Flash when turning a side prompt on or off failed.")

            {:noreply,
             put_flash(
               socket,
               :error,
               dpgettext(
                 "memory",
                 "status: flash after turning a side prompt on or off failed",
                 "Could not update %{side_prompt_name}",
                 side_prompt_name: side_prompt.name
               )
             )}
        end

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "memory_side_run",
        %{"memory_side" => %{"id" => id} = params},
        %{assigns: %{memory_panel: %{side: %{} = side} = panel, selected_chat: %{} = chat}} = socket
      ) do
    case Enum.find(side.side_prompts, &(&1.id == id)) do
      %{} = side_prompt ->
        result =
          with {:ok, range} <- side_range(params) do
            SidePrompts.run(
              socket.assigns.current_scope,
              chat,
              side_prompt,
              [trigger: :manual, macros: side_macros(params)] ++ range
            )
          end

        case result do
          {:ok, job} ->
            side = %{side | errors: Map.delete(side.errors, id)}
            {:noreply, socket |> assign(memory_panel: %{panel | side: side}) |> put_flash(:info, queued(job.label))}

          {:error, :unauthorized} ->
            unauthorized(socket)

          {:error, reason} ->
            side = %{side | errors: Map.put(side.errors, id, error_message(reason))}
            {:noreply, assign(socket, memory_panel: %{panel | side: side})}
        end

      nil ->
        {:noreply, socket}
    end
  end

  # Set rows are looked up in the set the tab resolved.
  def handle_event(
        "memory_side_run_row",
        %{"id" => id},
        %{assigns: %{memory_panel: %{side: %{set: %{rows: rows}} = side} = panel, selected_chat: %{} = chat}} = socket
      ) do
    case Enum.find(rows, &(&1.id == id)) do
      %{} = row ->
        socket.assigns.current_scope
        |> SidePrompts.run(chat, row.side_prompt, trigger: :manual, set_row: row)
        |> side_set_result(socket, panel, side)

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "memory_side_run_set",
        _params,
        %{assigns: %{memory_panel: %{side: %{set: %{} = set} = side} = panel, selected_chat: %{} = chat}} = socket
      ) do
    socket.assigns.current_scope
    |> SidePrompts.run_set(chat, set)
    |> side_set_result(socket, panel, side)
  end

  # A closed panel, or no chat selected.
  def handle_event(event, _params, socket) when event in @events, do: {:noreply, socket}

  defp create(socket, panel, chat, first, last, previous, confirm?, participant_ids) do
    form = create_form(first, last, previous, participant_ids)

    case Memory.create_memory(socket.assigns.current_scope, chat, first, last,
           previous_count: previous,
           confirm_tokens: confirm?,
           participant_ids: participant_ids
         ) do
      {:ok, job} ->
        {:noreply,
         socket
         |> assign(memory_panel: %{panel | create_form: form, warning: nil, create_error: nil})
         |> put_flash(:info, queued(job.label))}

      {:confirm, tokens} ->
        warning = %{
          tokens: tokens,
          first: first,
          last: last,
          previous_count: previous,
          participant_ids: participant_ids
        }

        {:noreply, assign(socket, memory_panel: %{panel | create_form: form, warning: warning, create_error: nil})}

      {:error, :unauthorized} ->
        unauthorized(socket)

      {:error, reason} ->
        {:noreply,
         assign(socket, memory_panel: %{panel | create_form: form, warning: nil, create_error: error_message(reason)})}
    end
  end

  defp regenerate(socket, panel, chat, record, confirm?) do
    case Memory.regenerate(socket.assigns.current_scope, chat, record, confirm_tokens: confirm?) do
      {:ok, job} ->
        {:noreply,
         socket
         |> assign(memory_panel: %{panel | regenerate_warning: nil})
         |> put_flash(:info, queued(job.label))}

      {:confirm, tokens} ->
        {:noreply, assign(socket, memory_panel: %{panel | regenerate_warning: %{record_id: record.id, tokens: tokens}})}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  defp load(scope, chat, tab) do
    settings = Memory.chat_settings(scope, chat)
    prefs = Memory.preferences(scope)
    book = settings.memory_book_id && Lore.get_book(scope, settings.memory_book_id)

    {first, last} =
      case Memory.next_range(scope, chat) do
        {first, last} -> {first, last}
        :none -> {nil, nil}
      end

    reviews =
      scope |> Jobs.list_jobs(chat_id: chat.id, statuses: [:review]) |> Enum.filter(&(&1.tag in @review_tags))

    bots = Chat.bots(chat)
    locks = CharacterBooks.character_locks(scope, Enum.map(bots, & &1.character_id))

    %{
      tab: tab,
      chat_id: chat.id,
      settings: settings,
      prefs: prefs,
      profile:
        case Memory.profile_for(scope, chat) do
          {:ok, profile} -> profile
          _ -> nil
        end,
      book: book,
      records: Memory.list_records(scope, book && book.id),
      reviews: reviews,
      review_details: Map.new(reviews, &{&1.id, review_details(scope, &1)}),
      # Approved Memory Assistance topics, pending until their topical clip is saved.
      topic_suggestions: Clips.list_topic_suggestions(scope, chat),
      topic_suggestions_error: nil,
      # Oldest first, so the running job leads (`list_jobs/1` is newest first).
      active_jobs:
        scope
        |> Jobs.list_jobs(chat_id: chat.id, statuses: [:queued, :running], tags: Jobs.memory_tags())
        |> Enum.reverse(),
      create_form: create_form(first, last, prefs.default_previous_count),
      catchup_form: catchup_form(nil, nil, 30),
      # The inline add forms under Settings' character books and Additional Context lists.
      character_book_form: nil,
      character_book_error: nil,
      context_form: nil,
      context_error: nil,
      boundary_form: to_form(%{"number" => display(settings.highest_processed)}, as: :memory_boundary),
      settings_form: to_form(Memory.change_chat_settings(settings), as: :memory_settings),
      consolidate: nil,
      topical: nil,
      side: nil,
      warning: nil,
      regenerate_warning: nil,
      create_error: nil,
      catchup_error: nil,
      review_errors: %{},
      # Reviews whose save was refused because their source changed: they offer Save anyway.
      review_forceable: MapSet.new(),
      # Each review form's last `phx-change` params (`memory_review_change`), by job id.
      review_edits: %{},
      profile_options: Enum.map(Memory.list_usable_profiles(scope), &{&1.name, &1.id}),
      book_options: Enum.map(Memory.list_memory_books(scope), &{&1.name, &1.id}),
      participant_options:
        Enum.map(chat.participants, &{Chat.participant_name(chat, &1.character_id), &1.character_id}),
      bot_options: Enum.map(bots, &{Chat.participant_name(chat, &1.character_id), &1.character_id}),
      character_rows:
        Enum.map(bots, fn bot ->
          lock = locks[bot.character_id]

          %{
            id: bot.character_id,
            name: Chat.participant_name(chat, bot.character_id),
            lock: lock,
            broken?: lock != nil and CharacterBooks.lock_broken?(scope, lock),
            book_id: settings.character_book_ids[bot.character_id]
          }
        end),
      solo?: length(bots) == 1,
      side_prompt_list: Memory.list_chat_side_prompts(chat),
      side_prompt_set_options: Enum.map(Memory.list_usable_side_prompt_sets(scope), &{&1.name, &1.id}),
      entry_options: Enum.map(Lore.list_usable_entries(scope), &{&1.name, &1.id})
    }
  end

  # What a review card shows besides the draft: source titles for a consolidation, the original
  # entry and both token counts for a compaction.
  defp review_details(scope, %{tag: :consolidation, result: result}) do
    ids =
      Enum.flat_map(result["candidates"] || [], & &1["source_ids"]) ++
        Enum.map(result["unassigned"] || [], & &1["record_id"])

    %{names: Memory.record_names(scope, ids)}
  end

  defp review_details(scope, %{tag: :compaction} = job) do
    model = job.ai_model_id && AI.get_model(scope, job.ai_model_id)
    original = with %{entry: entry} <- Memory.get_record(scope, job.params["record_id"]), do: entry.content

    %{
      original: original,
      original_tokens: tokens(model, original),
      draft_tokens: tokens(model, job.result["content"])
    }
  end

  defp review_details(scope, %{tag: :memory_assistance, result: result}) do
    ids = for %{"record_id" => id} <- result["candidates"] || [], do: id
    records = Memory.get_records(scope, ids)

    %{
      current:
        Map.new(
          ids,
          &{&1,
           case records[&1] do
             %{entry: %{content: c}} -> c
             _ -> nil
           end}
        )
    }
  end

  defp review_details(_scope, _job), do: %{}

  defp tokens(model, text), do: model |> Tokenizer.count(text) |> elem(0)

  # Tab state is built only while its tab shows; `previous` is the panel being replaced, whose state
  # the rebuilt one carries forward.
  defp with_tab_state(scope, panel, chat, previous) do
    panel
    |> with_consolidate(scope, chat, previous && previous.consolidate)
    |> with_topical(scope, previous && previous.topical)
    |> with_side(scope, chat, previous && previous.side)
  end

  # The Consolidate tab's state. `previous` is the state being replaced: with the same book and tier
  # its ticks survive (newly eligible sources start ticked), and posted `"sources"` replace them.
  defp with_consolidate(%{tab: "consolidate"} = panel, scope, chat, previous),
    do: %{panel | consolidate: consolidate_state(scope, chat, panel, (previous && previous.params) || %{}, previous)}

  defp with_consolidate(panel, _scope, _chat, _previous), do: panel

  defp with_topical(%{tab: "topical"} = panel, scope, previous),
    do: %{panel | topical: topical_state(scope, panel, (previous && previous.params) || %{}, previous)}

  defp with_topical(panel, _scope, _previous), do: panel

  # The Side prompts tab: every side prompt the chat's owner may use, its checkpoint in this chat,
  # per-row run errors, and the side prompt set the chat runs (`SidePrompts.chat_set/2`).
  defp with_side(%{tab: "side"} = panel, scope, chat, previous) do
    side = %{
      side_prompts: Memory.list_chat_side_prompts(chat),
      checkpoints: SidePrompts.checkpoints(scope, chat),
      set: SidePrompts.chat_set(scope, chat),
      set_error: nil,
      errors: (previous && previous.errors) || %{},
      prefill: (previous && previous.prefill) || %{}
    }

    %{panel | side: side}
  end

  defp with_side(panel, _scope, _chat, _previous), do: panel

  # Blank start/end fall back to `SidePrompts.run/3`'s defaults.
  defp side_range(params) do
    Enum.reduce_while([start: params["start"], end: params["end"]], {:ok, []}, fn {key, value}, {:ok, range} ->
      case {String.trim(value || ""), display_number(value)} do
        {"", _blank} -> {:cont, {:ok, range}}
        {_text, {:ok, position}} -> {:cont, {:ok, [{key, position} | range]}}
        {_text, :error} -> {:halt, {:error, :bad_numbers}}
      end
    end)
  end

  # A blank macro posts "", which `SidePrompts.run/4` counts as missing.
  defp side_macros(params), do: Map.get(params, "macros", %{})

  defp side_set_result(result, socket, panel, side) do
    case result do
      {:ok, queued} ->
        info = if is_list(queued), do: side_runs_queued(length(queued)), else: queued(queued.label)

        {:noreply,
         socket
         |> assign(memory_panel: %{panel | side: %{side | set_error: nil}})
         |> put_flash(:info, info)}

      {:error, :unauthorized} ->
        unauthorized(socket)

      {:error, reason} ->
        {:noreply, assign(socket, memory_panel: %{panel | side: %{side | set_error: error_message(reason)}})}
    end
  end

  defp consolidate_state(scope, chat, panel, params, previous) do
    book_options = Enum.map(Memory.record_books(scope), &{&1.name, &1.id})
    book_ids = Enum.map(book_options, &elem(&1, 1))
    book_id = Enum.find([params["book_id"], panel.book && panel.book.id, List.first(book_ids)], &(&1 in book_ids))

    tier =
      case Integer.parse(to_string(params["tier"] || "1")) do
        {n, ""} when n in 1..6 -> n
        _ -> 1
      end

    eligible = if book_id, do: Consolidation.eligible(scope, book_id, tier), else: []
    prompt_options = Enum.map(Prompts.list_prompts(scope, :consolidation), &{&1.name, &1.id})
    prompt_ids = Enum.map(prompt_options, &elem(&1, 1))

    prompt_id =
      Enum.find([params["prompt_id"], panel.profile && panel.profile.consolidation_prompt_id], &(&1 in prompt_ids))

    prefs = Memory.preferences(scope)
    max_entries = positive(params["max_entries"], prefs.consolidation_max_entries)
    token_budget = positive(params["token_budget"], prefs.consolidation_token_budget)
    disable_sources = params["disable_sources"] != "false"
    same? = previous != nil and previous.book_id == book_id and previous.tier == tier

    selected =
      selected_sources(eligible, params, if(same?, do: {Enum.map(previous.eligible, & &1.id), previous.selected}))

    model =
      with %{} = profile <- panel.profile,
           {:ok, model} <- Memory.model_for(scope, chat, profile),
           do: model,
           else: (_ -> nil)

    passes =
      eligible
      |> Enum.filter(&MapSet.member?(selected, &1.id))
      |> Consolidation.batches(max_entries, token_budget, model)
      |> length()

    form_params = %{
      "book_id" => book_id,
      "tier" => to_string(tier),
      "prompt_id" => prompt_id,
      "max_entries" => to_string(max_entries),
      "token_budget" => to_string(token_budget),
      "disable_sources" => to_string(disable_sources)
    }

    %{
      params: form_params,
      form: to_form(form_params, as: :memory_consolidate),
      book_id: book_id,
      tier: tier,
      prompt_id: prompt_id,
      max_entries: max_entries,
      token_budget: token_budget,
      disable_sources: disable_sources,
      eligible: eligible,
      selected: selected,
      passes: passes,
      ready: Consolidation.ready_tiers(scope, panel.book),
      book_options: book_options,
      prompt_options: prompt_options,
      error: previous && previous.error
    }
  end

  # The Topical clip tab's state. Picking a target clip fills in its topic and keywords; its snapshot
  # tells which sources it already covers (shown as such, and skipped unless rebuilding).
  defp topical_state(scope, panel, params, previous) do
    book_options = topical_book_options(scope, panel.book)
    book_ids = Enum.map(book_options, &elem(&1, 1))
    book_id = Enum.find([params["book_id"], panel.book && panel.book.id, List.first(book_ids)], &(&1 in book_ids))
    targets = Clips.topical_clips(scope, book_id)
    target = Enum.find(targets, &(&1.id == params["target_record_id"]))
    retargeted? = previous == nil or previous.book_id != book_id or record_id(previous.target) != record_id(target)
    sources = Clips.topical_sources(scope, book_id)
    rebuild = params["rebuild"] == "true"
    known = (target && !rebuild && target.snapshot["sources"]) || %{}

    {topic, keywords} =
      if retargeted? and target,
        do: {target.snapshot["topic"] || target.entry.name, target.entry.keywords},
        else: {params["topic"] || "", Enum.reject(List.wrap(params["keywords"]), &(&1 == ""))}

    form_params = %{
      "book_id" => book_id,
      "target_record_id" => target && target.id,
      "topic" => topic,
      "keywords" => keywords,
      "include_memories" => to_string(params["include_memories"] != "false"),
      "include_messages" => to_string(params["include_messages"] == "true"),
      "start" => params["start"] || "",
      "end" => params["end"] || "",
      "message_mode" => if(params["message_mode"] == "pick", do: "pick", else: "range"),
      "rebuild" => to_string(rebuild)
    }

    %{
      params: form_params,
      form: to_form(form_params, as: :memory_topical),
      book_id: book_id,
      target: target,
      sources: sources,
      selected:
        selected_sources(
          sources,
          params,
          if(previous && previous.book_id == book_id, do: {Enum.map(previous.sources, & &1.id), previous.selected})
        ),
      covered: MapSet.new(for s <- sources, known[s.id] == Scene.sha256(s.entry.content), do: s.id),
      include_memories: form_params["include_memories"] == "true",
      include_messages: form_params["include_messages"] == "true",
      rebuild: rebuild,
      book_options: book_options,
      target_options: Enum.map(targets, &{&1.entry.name, &1.id}),
      message_mode: if(params["message_mode"] == "pick", do: "pick", else: "range"),
      picked: (previous && previous.picked) || %{},
      picker: (previous && previous.picker) || %{query: "", hidden_only: false, results: [], more?: false},
      error: previous && previous.error,
      # The Combine clips form: the book's topical clips, with whether each is still enabled.
      clips: Enum.map(targets, &{&1, Memory.record_enabled?(&1)}),
      combine_form: (previous && previous.combine_form) || combine_form(%{}),
      combine_error: previous && previous.combine_error
    }
  end

  defp combine_form(params) do
    to_form(
      %{
        "record_ids" => params["record_ids"] || [],
        "title" => params["title"] || "",
        "disable_originals" => params["disable_originals"] || "true"
      },
      as: :memory_combine
    )
  end

  # Books with memory records, plus the chat's own book even before it holds any.
  defp topical_book_options(scope, book) do
    books = Memory.record_books(scope)
    books = if book && not Enum.any?(books, &(&1.id == book.id)), do: [book | books], else: books
    Enum.map(books, &{&1.name, &1.id})
  end

  defp record_id(nil), do: nil
  defp record_id(record), do: record.id

  defp topical_range(%{include_messages: false}), do: {:ok, []}

  defp topical_range(%{message_mode: "pick", picked: picked}) when picked == %{}, do: {:error, :empty_scene}
  defp topical_range(%{message_mode: "pick", picked: picked}), do: {:ok, [message_ids: Map.keys(picked)]}

  defp topical_range(%{params: params}) do
    with {:ok, first} <- display_number(params["start"]),
         {:ok, last} <- display_number(params["end"]) do
      {:ok, [start: first, end: last]}
    else
      :error -> {:error, :bad_numbers}
    end
  end

  defp topical_error(:no_sources, %{target: %{}}),
    do: dgettext("memory", "Nothing new or changed since this clip was written: pick more sources, or rebuild.")

  defp topical_error(:no_sources, _state), do: dgettext("memory", "Pick at least one memory, or include messages.")
  defp topical_error(:not_found, _state), do: dgettext("memory", "That topical clip is gone.")

  defp topical_error(:no_topic, _state),
    do: dpgettext("memory", "status: error when a topical memory has no topic", "Enter a topic.")

  defp topical_error(reason, _state), do: error_message(reason)

  # Ticks over `eligible`. `previous` is `{listed_ids, selected}` from the state being replaced when it
  # listed the same book (and tier): its ticks survive and newly listed sources start ticked. With
  # nil, every source starts ticked. Posted `"sources"` (the picker's list, after its `""` sentinel)
  # replace the ticks.
  defp selected_sources(eligible, params, previous) do
    ids = Enum.map(eligible, & &1.id)

    cond do
      previous == nil ->
        MapSet.new(ids)

      is_list(params["sources"]) ->
        params["sources"]
        |> Enum.reject(&(&1 == ""))
        |> MapSet.new()
        |> MapSet.intersection(MapSet.new(ids))

      true ->
        {listed, selected} = previous
        known = MapSet.new(listed)
        ids |> Enum.filter(&(MapSet.member?(selected, &1) or not MapSet.member?(known, &1))) |> MapSet.new()
    end
  end

  defp positive(value, default) do
    case Integer.parse(to_string(value || "")) do
      {n, ""} when n >= 1 -> n
      _ -> default
    end
  end

  defp saved_message(:consolidation) do
    gettext_comment("Flash after a reviewed consolidation draft was saved.")
    dpgettext("memory", "status: a consolidation draft was saved", "Consolidation saved")
  end

  defp saved_message(:compaction) do
    gettext_comment("Flash after a reviewed compaction draft was saved over its entry.")
    dpgettext("memory", "status: a compaction draft was saved", "Entry compacted")
  end

  defp saved_message(:topical_clip) do
    gettext_comment("Flash after a reviewed topical clip draft was saved.")
    dpgettext("memory", "status: a topical clip draft was saved", "Topical clip saved")
  end

  defp saved_message(:side_prompt) do
    gettext_comment("Flash after a reviewed side prompt draft was saved.")
    dpgettext("memory", "status: a side prompt draft was saved", "Side prompt saved")
  end

  defp saved_message(:memory_assistance) do
    gettext_comment("Flash after the reviewed memory assistance updates were applied.")
    dpgettext("memory", "status: memory assistance updates were applied", "Memory assistance applied.")
  end

  defp saved_message(_tag) do
    gettext_comment("Flash after a reviewed memory draft was saved.")
    dpgettext("memory", "status: a memory draft was saved", "Memory saved")
  end

  defp queued(label) do
    gettext_comment("Flash after a memory job was queued; %{job_label} is the job's name, such as Memory #3–#12.")
    dpgettext("memory", "status: a memory job was queued", "%{job_label} queued", job_label: label)
  end

  defp side_runs_queued(n) do
    gettext_comment("Flash after every row of a side prompt set was queued.")

    dngettext(
      "memory",
      "%{run_count} side prompt run queued",
      "%{run_count} side prompt runs queued",
      n,
      run_count: Format.number(n)
    )
  end

  defp all_processed_message do
    gettext_comment("Shown, in the memory dialog or as a flash, when no message is left to write a memory of.")
    dgettext("memory", "Every message is already processed.")
  end

  defp settings_saved_flash do
    gettext_comment("Flash after the chat's memory settings were saved.")
    dpgettext("memory", "status: memory settings were saved", "Memory settings saved")
  end

  defp character_book_removed_flash do
    gettext_comment("Flash after a character's memory book was removed from a group chat.")
    dpgettext("memory", "status: flash after removing a character's memory book from a chat", "Character book removed.")
  end

  defp context_entry_removed_flash do
    gettext_comment("Flash after a lore entry was removed from the chat's memory context.")

    dpgettext(
      "memory",
      "status: flash after removing an entry from the chat's memory context",
      "Context entry removed."
    )
  end

  defp context_entry_remove_failed_flash do
    gettext_comment("Flash when removing a memory context entry failed.")
    dgettext("memory", "Could not remove that entry.")
  end

  defp locked_flash do
    gettext_comment("Flash after a character was locked to its memory book.")
    dpgettext("memory", "status: a character was locked to its memory book", "Locked.")
  end

  defp unlocked_flash do
    gettext_comment("Flash after a character was unlocked from its memory book.")
    dpgettext("memory", "status: a character was unlocked from its memory book", "Unlocked.")
  end

  defp character_book_added_flash do
    gettext_comment("Flash after a character memory book was added to a group chat.")
    dpgettext("memory", "status: a character memory book was added", "Character book added.")
  end

  defp context_entries_added_flash do
    gettext_comment("Flash after lore entries were added to the chat's memory context.")
    dpgettext("memory", "status: memory context entries were added", "Context entries added.")
  end

  defp regenerating_summary_flash do
    gettext_comment("Flash after one summary of a consolidation draft was sent to be written again.")
    dpgettext("memory", "status: one consolidation summary is being written again", "Regenerating that summary.")
  end

  defp combining_clips_flash do
    gettext_comment("Flash after a job that combines topical clips was queued.")
    dgettext("memory", "Combining clips; the draft will appear in Reviews.")
  end

  defp drafting_clip_flash do
    gettext_comment("Flash after a suggested topic was sent to be drafted into a topical clip.")
    dgettext("memory", "Drafting that topical clip; it will appear in Reviews.")
  end

  defp create_form(first, last, previous, participant_ids \\ []) do
    to_form(
      %{
        "start" => display(first),
        "end" => display(last),
        "previous_count" => to_string(previous),
        "participant_ids" => participant_ids
      },
      as: :memory_create
    )
  end

  defp catchup_form(first, last, chunk),
    do: to_form(%{"start" => display(first), "end" => display(last), "chunk" => to_string(chunk)}, as: :memory_catchup)

  defp context_form(params),
    do: to_form(%{"entry_ids" => Enum.reject(params["entry_ids"] || [], &(&1 == ""))}, as: :memory_context)

  defp side_prefill(params, side_prompts) do
    with id when is_binary(id) <- params["side_prompt_id"],
         true <- Enum.any?(side_prompts, &(&1.id == id)),
         {:ok, start} <- optional_display_number(params["side_start"]),
         {:ok, finish} <- optional_display_number(params["side_end"]) do
      %{id => %{start: display(start), end: display(finish)}}
    else
      _ -> %{}
    end
  end

  defp optional_display_number(value) do
    if String.trim(value || "") == "", do: {:ok, nil}, else: display_number(value)
  end

  defp display(nil), do: ""
  defp display(position), do: to_string(position + 1)

  # A display number ("#4") to a position (3).
  defp display_number(value) do
    case Integer.parse(to_string(value || "")) do
      # Positions are int4 columns; a larger number would fail in the database.
      {n, ""} when n in 1..2_147_483_647//1 -> {:ok, n - 1}
      _ -> :error
    end
  end

  defp count(value) do
    case Integer.parse(to_string(value || "")) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> :error
    end
  end

  # A side prompt left on its own target posts "".
  defp settings_attrs(params) do
    params
    |> Map.update("side_prompt_book_ids", %{}, &Map.reject(&1, fn {_id, book} -> book == "" end))
    |> drop_blanks("cast_ids")
  end

  # The present cast renders only in group chats, so an absent key stays unchanged; an emptied
  # multi-select posts only its hidden "" sentinel.
  defp drop_blanks(params, key) do
    case params do
      %{^key => list} when is_list(list) -> %{params | key => Enum.reject(list, &(&1 == ""))}
      _absent -> params
    end
  end

  defp put_review_error(panel, id, reason) do
    forceable =
      if reason == :changed, do: MapSet.put(panel.review_forceable, id), else: MapSet.delete(panel.review_forceable, id)

    %{panel | review_errors: Map.put(panel.review_errors, id, error_message(reason)), review_forceable: forceable}
  end

  # A review that saved, was regenerated or was discarded drops its error and its form's edits.
  defp clear_review_error(panel, id),
    do: %{
      panel
      | review_errors: Map.delete(panel.review_errors, id),
        review_forceable: MapSet.delete(panel.review_forceable, id),
        review_edits: Map.delete(panel.review_edits, id)
    }

  # A review action's outcome: on success its card's error clears and the panel reloads (with `info`
  # flashed, if any); a refusal flashes, and any other error shows on the review's card.
  defp review_result({:ok, _}, socket, panel, id, info) do
    socket = socket |> assign(memory_panel: clear_review_error(panel, id)) |> reload()
    {:noreply, if(info, do: put_flash(socket, :info, info), else: socket)}
  end

  defp review_result({:error, :unauthorized}, socket, _panel, _id, _info), do: unauthorized(socket)

  defp review_result({:error, reason}, socket, panel, id, _info),
    do: {:noreply, assign(socket, memory_panel: put_review_error(panel, id, reason))}

  defp unauthorized(socket), do: {:noreply, put_flash(socket, :error, error_message(:unauthorized))}

  @doc "The fixed message shown for a memory error."
  def error_message(:quota_exceeded),
    do: dgettext("memory", "You've spent today's budget on the site's AI connections.")

  def error_message(:overlap), do: dgettext("memory", "Those messages overlap an existing memory.")
  def error_message(:empty_scene), do: dgettext("memory", "No messages to summarize in that range.")
  def error_message(:no_profile), do: dgettext("memory", "No memory profile: create one and make it the default.")
  def error_message(:no_model), do: dgettext("memory", "No model: set one on the memory profile or the chat.")
  def error_message(:missing_macros), do: dgettext("memory", "Fill in every macro this side prompt uses.")

  def error_message(:ambiguous_model),
    do:
      dgettext(
        "memory",
        "Several models could be the default: pick one on the memory profile, or set a default model in Settings."
      )

  def error_message(:no_prompt), do: dgettext("memory", "The memory profile has no prompt for this job.")
  def error_message(:too_few), do: dgettext("memory", "Pick at least two topical clips.")
  def error_message(:no_title), do: dpgettext("memory", "status: error when a memory has no title", "Enter a title.")
  def error_message(:changed), do: dgettext("memory", "The source changed since this was generated.")

  def error_message(:invalid),
    do: dgettext("memory", "The draft needs a title and content (and keywords for keyword activation).")

  def error_message(:invalid_chunk), do: dgettext("memory", "Chunk size must be 5 to 250 messages.")

  def error_message(:bad_numbers),
    do: dpgettext("memory", "status: error when the message numbers for a memory are missing", "Enter message numbers.")

  def error_message(:not_retryable), do: dgettext("memory", "This job cannot be regenerated.")
  def error_message(:not_found), do: dgettext("memory", "This review is no longer pending.")
  def error_message(:no_sources), do: dgettext("memory", "Pick at least one source.")

  def error_message(:ineligible),
    do: dgettext("memory", "A picked source is no longer eligible: reload and pick again.")

  def error_message(:consolidated),
    do: dgettext("memory", "Already consolidated: regenerate the consolidation instead.")

  def error_message(:source_missing), do: dgettext("memory", "Its source messages or entries are gone.")
  def error_message(:not_regenerable), do: dgettext("memory", "This kind of entry cannot be regenerated.")
  def error_message(:nothing_kept), do: dgettext("memory", "Keep at least one summary, or discard the draft.")
  def error_message(:unparseable), do: dgettext("memory", "That is still not valid JSON for this job.")
  def error_message(:not_correctable), do: dgettext("memory", "Only a failed memory or consolidation can be corrected.")

  def error_message(:empty),
    do: dpgettext("memory", "status: error when a memory draft has no content", "The draft is empty.")

  def error_message(:invalid_participants),
    do: dgettext("memory", "Pick present characters from this chat's participants.")

  def error_message(:unauthorized), do: MythweaverWeb.Flash.unauthorized_message()

  def error_message(:copy), do: dgettext("memory", "This is a character's copy; regenerate the chat's memory instead.")

  def error_message(:no_book), do: dgettext("memory", "Pick a character book first.")
  def error_message(:busy), do: dgettext("memory", "A draft for that topic is already in progress.")

  def error_message(reason) do
    gettext_comment("%{error_detail} is the internal error term, shown verbatim.")
    dpgettext("memory", "status: a memory action failed", "Failed: %{error_detail}", error_detail: inspect(reason))
  end

  # `:not_found` here means the suggestion, not a review.
  defp suggestion_error(:not_found), do: dgettext("memory", "That topic is no longer pending.")
  defp suggestion_error(reason), do: error_message(reason)
end
