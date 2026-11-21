defmodule MythweaverWeb.Chat.MemoryPanel do
  @moduledoc """
  The chat's memory modal, routed at `/chats/:id/memory` (state in
  `MythweaverWeb.MainChatLive.MemoryPanel`). Tabs:

    * Memory: status, the processed boundary, and the create and catch-up forms (controls only)
    * Reviews: each draft awaiting review (memory, consolidation, compaction, topical clip, side
      prompt), editable before saving
    * Entries: the records of the chat's memory book, newest first within each kind and tier, with
      regenerate and compact
    * Consolidate: consolidating eligible records of a book into the next tier
    * Topical clip: gathering one topic from a book's memories and a message range into one entry
    * Side prompts: each side prompt's on/off switch, a manual run, and how far it has run here
    * Settings: the chat's memory settings (book, profile, automatic memories, auto-hide, context,
      character memory books and their locks, and the present cast)
  """

  use MythweaverWeb, :html

  alias Mythweaver.Format
  alias Mythweaver.Memory
  alias Mythweaver.Memory.Scene
  alias Mythweaver.Memory.Tiers

  attr :chat, :any, required: true
  attr :panel, :map, required: true, doc: "the `memory_panel` assign"
  attr :queue_positions, :map, default: %{}, doc: "`Jobs.queue_positions/0`"
  attr :viewer_id, :string, required: true, doc: "`current_scope.user.id`, for the pickers' tag filter"
  attr :tag_graph, :any, required: true
  attr :tag_vocabulary, :list, default: []

  def memory_panel(assigns) do
    ~H"""
    <%!-- `lower-bound="none"`: the content lives inside `<.modal>`'s slot and `<.input>`'s internals. --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      div.memory-body:scope {
        display: flex;
        flex-direction: column;
        gap: var(--size-3);
      }

      /* The tab bar alone sets the modal's width (`modal--fit`): every other child fills it but
         contributes no width. */
      div.memory-body:scope > :not([role="tablist"]) {
        contain: inline-size;
      }

      .memory-active-job {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: var(--size-2);
      }

      .memory-section,
      .memory-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .memory-section-title {
        margin: 0;
        font-size: 0.95rem;
      }

      .memory-status {
        display: grid;
        grid-template-columns: max-content 1fr;
        gap: var(--size-1) var(--size-3);
        margin: 0;
      }

      .memory-status dt {
        margin: 0;
        color: var(--muted-foreground);
      }

      .memory-form label {
        display: block;
      }

      .memory-row {
        display: flex;
        flex-wrap: wrap;
        gap: var(--size-2);
        align-items: flex-end;
      }

      .memory-field {
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
      }

      .memory-help {
        margin: 0;
        color: var(--muted-foreground);
        font-size: 0.85rem;
      }

      .memory-fieldset {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
        margin: 0;
        padding: var(--size-2);
        border: 1px solid var(--border);
        border-radius: var(--radius-2);
      }

      .memory-actions {
        display: flex;
        flex-wrap: wrap;
        justify-content: flex-end;
        gap: var(--size-2);
        align-items: center;
      }

      .memory-error {
        margin: 0;
        color: var(--destructive);
      }

      .memory-warning {
        display: flex;
        flex-wrap: wrap;
        gap: var(--size-2);
        align-items: center;
        padding: var(--size-2);
        border: 1px solid var(--primary-accent);
        border-radius: var(--radius-2);
      }

      .memory-empty {
        margin: 0;
        color: var(--muted-foreground);
      }

      .memory-picker-results {
        list-style: none;
        margin: 0;
        padding: 0;
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
        max-height: 24rem;
        overflow-y: auto;
      }

      .memory-picker-row {
        display: flex;
        gap: var(--size-2);
        align-items: center;
      }

      .memory-picker-excerpt,
      .memory-picker-full {
        margin: 0;
        white-space: pre-wrap;
      }

      .memory-badge {
        padding: 0 var(--size-1);
        border: 1px solid var(--border-grey);
        border-radius: var(--radius-2);
        font-size: var(--font-size-0);
        color: var(--muted-foreground);
      }

      .memory-card {
        padding: var(--size-2);
        border: 1px solid var(--border-grey);
        border-radius: var(--radius-2);
      }

      .memory-list {
        list-style: none;
        margin: 0;
        padding: 0;
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
      }

      .memory-entry {
        display: flex;
        flex-wrap: wrap;
        align-items: baseline;
        gap: var(--size-2);
        padding: var(--size-1) var(--size-2);
        border: 1px solid var(--border-grey);
        border-radius: var(--radius-2);
      }

      .memory-entry > .memory-warning,
      .memory-entry > .memory-error {
        flex-basis: 100%;
      }

      .memory-entry-title {
        flex: 1 1 auto;
        min-width: 0;
        font-weight: 600;
        overflow-wrap: anywhere;
      }

      .memory-entry-meta {
        color: var(--muted-foreground);
        font-size: 0.85rem;
      }

      .memory-compare {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(16rem, 1fr));
        gap: var(--size-3);
      }

      .memory-original {
        max-height: 24rem;
        overflow: auto;
        padding: var(--size-2);
        white-space: pre-wrap;
        overflow-wrap: anywhere;
        border: 1px solid var(--border-grey);
        border-radius: var(--radius-2);
        color: var(--muted-foreground);
      }

      .memory-raw {
        font-family: var(--font-monospace-code, ui-monospace, monospace);
        font-size: var(--font-size-0);
      }
    </style>

    <.modal
      id="memory-modal"
      title={dpgettext("memory", "heading: chat memory modal", "Memory")}
      on_cancel="close_memory"
      class="modal--fit"
    >
      <div class="memory-body">
        <.tabs
          id="memory"
          label={dpgettext("memory", "aria label: tab list of the chat memory modal", "Memory")}
          active={@panel.tab}
        >
          <:tab
            :for={{tab, label} <- memory_tabs()}
            :if={tab != "characters" or group_characters?(@panel)}
            name={tab}
            patch={~p"/chats/#{@chat.id}/memory?tab=#{tab}"}
          >
            {label}
            <.badge :if={tab == "reviews" and @panel.reviews != []}>{length(@panel.reviews)}</.badge>
          </:tab>
        </.tabs>

        <section :if={@panel.active_jobs != []} id="memory-active-jobs" class="memory-section">
          <h3 class="memory-section-title">
            {dpgettext("memory", "heading: memory jobs currently running", "In progress")}
          </h3>
          <div
            :for={job <- @panel.active_jobs}
            id={"memory-active-job-#{job.id}"}
            class="memory-active-job"
          >
            <span>{job.label}</span>
            <.job_progress
              id={"memory-job-progress-#{job.id}"}
              job={job}
              position={@queue_positions[job.id]}
            />
          </div>
        </section>

        <.memory_tab
          :if={@panel.tab == "memory"}
          panel={@panel}
          viewer_id={@viewer_id}
          tag_graph={@tag_graph}
          tag_vocabulary={@tag_vocabulary}
        />
        <.reviews_tab :if={@panel.tab == "reviews"} panel={@panel} />
        <.entries_tab :if={@panel.tab == "entries"} panel={@panel} />
        <.consolidate_tab :if={@panel.tab == "consolidate" and @panel.consolidate} panel={@panel} />
        <.topical_tab :if={@panel.tab == "topical" and @panel.topical} panel={@panel} />
        <.side_tab :if={@panel.tab == "side" and @panel.side} panel={@panel} />
        <.characters_tab :if={@panel.tab == "characters"} panel={@panel} />
        <.context_tab
          :if={@panel.tab == "context"}
          panel={@panel}
          viewer_id={@viewer_id}
          tag_graph={@tag_graph}
          tag_vocabulary={@tag_vocabulary}
        />
        <.settings_tab
          :if={@panel.tab == "settings"}
          panel={@panel}
          viewer_id={@viewer_id}
          tag_graph={@tag_graph}
          tag_vocabulary={@tag_vocabulary}
        />
      </div>
    </.modal>
    """
  end

  attr :draft, :map, required: true, doc: "the `clip_draft` assign (`MythweaverWeb.MainChatLive.ClipDialog`)"

  @doc "The clip dialog: saves highlighted message text as a line of a new or existing clip."
  def clip_dialog(assigns) do
    assigns = assign(assigns, new?: assigns.draft.form[:target].value in [nil, "new"])

    ~H"""
    <%!-- `lower-bound="none"`: the content lives inside `<.modal>`'s slot and `<.input>`'s internals. --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      div.clip-body:scope {
        display: flex;
        flex-direction: column;
      }

      .clip-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .clip-activation {
        display: flex;
        gap: var(--size-3);
        margin: 0;
        padding: 0;
        border: none;
      }

      .clip-activation legend {
        padding: 0;
        margin-bottom: var(--size-1);
      }

      .clip-activation label {
        display: inline-flex;
        gap: var(--size-1);
        align-items: center;
      }

      .clip-error {
        margin: 0;
        color: var(--destructive);
      }

      .clip-actions {
        display: flex;
        justify-content: flex-end;
        gap: var(--size-2);
      }
    </style>
    <.modal
      id="clip-dialog"
      title={dpgettext("memory", "heading: dialog that saves highlighted text as a clip", "Clip")}
      on_cancel="close_clip"
    >
      <div class="clip-body">
        <.form
          for={@draft.form}
          id="clip-form"
          class="clip-form"
          phx-change="clip_change"
          phx-submit="clip_save"
        >
          <.editor
            field={@draft.form[:text]}
            label={dpgettext("memory", "field label: text of a clip", "Text")}
            language="markdown"
            spellcheck
            rows={4}
            id="clip-text"
          />
          <.input
            field={@draft.form[:target]}
            type="select"
            label={
              dpgettext("memory", "field label: clip the highlighted text is added to", "Add to")
            }
            options={[
              {dpgettext("memory", "option: add the highlighted text to a new clip", "New clip"),
               "new"}
              | Enum.map(@draft.clips, &{&1.entry.name, &1.id})
            ]}
            id="clip-target"
          />
          <.input
            :if={@new?}
            field={@draft.form[:title]}
            type="text"
            label={dpgettext("memory", "field label: title of a new clip", "Title")}
            id="clip-title"
          />
          <%!-- Radios are written out: `<.input>` has no radio type. --%>
          <fieldset :if={@new?} class="clip-activation">
            <legend>
              {dpgettext("memory", "field label: how a new clip is activated", "Activation")}
            </legend>
            <label :for={{value, label} <- clip_activation_options()}>
              <input
                type="radio"
                name={@draft.form[:activation].name}
                value={value}
                checked={@draft.form[:activation].value == value}
                id={"clip-activation-#{value}"}
              />
              {label}
            </label>
          </fieldset>
          <p :if={@draft.error} id="clip-error" class="clip-error">{@draft.error}</p>
          <div class="clip-actions">
            <.button id="clip-cancel" phx-click="close_clip">
              {dpgettext("memory", "button: close the clip dialog", "Cancel")}
            </.button>
            <.button type="submit" id="clip-save" variant="primary">
              <.lucide name="scissors" /> {dpgettext("memory", "button: save the clip", "Save clip")}
            </.button>
          </div>
        </.form>
      </div>
    </.modal>
    """
  end

  attr :panel, :map, required: true
  attr :viewer_id, :string, required: true
  attr :tag_graph, :any, required: true
  attr :tag_vocabulary, :list, default: []

  defp memory_tab(assigns) do
    ~H"""
    <section class="memory-section" id="memory-status">
      <dl class="memory-status">
        <dt>{dpgettext("memory", "field label: memory book of the chat", "Book")}</dt>
        <dd id="memory-status-book">
          {(@panel.book && @panel.book.name) ||
            dpgettext(
              "memory",
              "status: chat has no memory book yet",
              "None yet (created on first save)"
            )}
        </dd>
        <dt>{dpgettext("memory", "field label: memory profile of the chat", "Profile")}</dt>
        <dd id="memory-status-profile">
          {(@panel.profile && @panel.profile.name) ||
            dpgettext("memory", "status: chat has no memory profile", "None")}
        </dd>
        <dt>
          {dpgettext("memory", "field label: how far the chat's memory has processed", "Processed")}
        </dt>
        <dd id="memory-status-processed">
          {if @panel.settings.highest_processed,
            do:
              dpgettext(
                "memory",
                "status: last message number the chat's memory covers",
                "Processed through #%{message_number}",
                message_number: Format.number(@panel.settings.highest_processed + 1)
              ),
            else:
              dpgettext(
                "memory",
                "status: chat memory has processed no messages",
                "Nothing processed yet"
              )}
        </dd>
      </dl>
      <.form
        for={@panel.boundary_form}
        id="memory-boundary-form"
        class="memory-row"
        phx-submit="memory_boundary"
      >
        <.input
          field={@panel.boundary_form[:number]}
          type="number"
          min="1"
          label={
            dpgettext(
              "memory",
              "field label: message number the memory processed boundary is set to",
              "Processed through #"
            )
          }
          id="memory-boundary-number"
        />
        <.button type="submit" id="memory-boundary-save">
          {dpgettext("memory", "button: set the memory processed boundary", "Set")}
        </.button>
        <.button id="memory-boundary-clear" phx-click="memory_boundary_clear">
          {dpgettext("memory", "button: clear the memory processed boundary", "Clear")}
        </.button>
      </.form>
    </section>

    <section class="memory-section">
      <h3 class="memory-section-title">
        {dpgettext(
          "memory",
          "heading: form that creates a memory from a message range",
          "Create a memory"
        )}
      </h3>
      <.form
        for={@panel.create_form}
        id="memory-create-form"
        class="memory-form"
        phx-change="memory_validate_create"
        phx-submit="memory_create"
      >
        <div class="memory-row">
          <.input
            field={@panel.create_form[:start]}
            type="number"
            min="1"
            label={dpgettext("memory", "field label: first message number of a range", "From #")}
            id="memory-create-start"
          />
          <.input
            field={@panel.create_form[:end]}
            type="number"
            min="1"
            label={dpgettext("memory", "field label: last message number of a range", "To #")}
            id="memory-create-end"
          />
          <.input
            field={@panel.create_form[:previous_count]}
            type="number"
            min="0"
            max="7"
            label={
              dpgettext(
                "memory",
                "field label: how many earlier memories a new memory is given as context",
                "Previous memories"
              )
            }
            id="memory-create-previous"
          />
        </div>
        <.live_component
          module={MythweaverWeb.MultiSelect}
          id="memory-create-participants"
          name="memory_create[participant_ids][]"
          label={
            dpgettext(
              "memory",
              "field label: characters present in a new memory",
              "Present (none selected: whoever speaks)"
            )
          }
          options={@panel.participant_options}
          selected={@panel.create_form[:participant_ids].value || []}
          empty={
            dpgettext("memory", "empty state: chat has no participants to pick", "No participants")
          }
          tag_kind={:character}
          viewer_id={@viewer_id}
          tag_graph={@tag_graph}
          tag_vocabulary={@tag_vocabulary}
        />
        <p :if={@panel.create_error} id="memory-create-error" class="memory-error">
          {@panel.create_error}
        </p>
        <.token_warning
          :if={@panel.warning}
          id="memory-token-warning"
          tokens={@panel.warning.tokens}
          threshold={@panel.prefs.token_warning_threshold}
        >
          <.button id="memory-create-confirm" variant="primary" phx-click="memory_create_confirm">
            {dpgettext("memory", "button: create a memory despite the token warning", "Create anyway")}
          </.button>
        </.token_warning>
        <div class="memory-actions">
          <.button
            id="memory-next"
            phx-click="memory_next"
            title={
              dpgettext(
                "memory",
                "tooltip: button that creates a memory of the next scene",
                "From the boundary to the latest message"
              )
            }
          >
            <.lucide name="skip-forward" />
            {dpgettext(
              "memory",
              "button: create a memory of the scene after the boundary",
              "Next scene"
            )}
          </.button>
          <.button type="submit" id="memory-create" variant="primary">
            <.lucide name="brain" /> {dpgettext("memory", "button: create a memory", "Create")}
          </.button>
        </div>
      </.form>
    </section>

    <section class="memory-section">
      <h3 class="memory-section-title">
        {dpgettext(
          "memory",
          "heading: form that writes memories for a range of past messages",
          "Catch up"
        )}
      </h3>
      <.form
        for={@panel.catchup_form}
        id="memory-catchup-form"
        class="memory-form"
        phx-submit="memory_catchup"
      >
        <div class="memory-row">
          <.input
            field={@panel.catchup_form[:start]}
            type="number"
            min="1"
            label={dpgettext("memory", "field label: first message number of a range", "From #")}
            id="memory-catchup-start"
          />
          <.input
            field={@panel.catchup_form[:end]}
            type="number"
            min="1"
            label={dpgettext("memory", "field label: last message number of a range", "To #")}
            id="memory-catchup-end"
          />
          <.input
            field={@panel.catchup_form[:chunk]}
            type="number"
            min="5"
            max="250"
            label={
              dpgettext(
                "memory",
                "field label: messages each catch-up memory covers",
                "Messages per memory"
              )
            }
            id="memory-catchup-chunk"
          />
        </div>
        <p :if={@panel.catchup_error} id="memory-catchup-error" class="memory-error">
          {@panel.catchup_error}
        </p>
        <div class="memory-actions">
          <.button type="submit" id="memory-catchup-run">
            {dpgettext("memory", "button: write memories for a range of past messages", "Catch up")}
          </.button>
        </div>
      </.form>
    </section>
    """
  end

  attr :panel, :map, required: true
  attr :viewer_id, :string, required: true
  attr :tag_graph, :any, required: true
  attr :tag_vocabulary, :list, default: []

  defp settings_tab(assigns) do
    solo_lock = if assigns.panel.solo?, do: Enum.find(assigns.panel.character_rows, & &1.lock)
    assigns = assign(assigns, solo_lock: solo_lock)

    ~H"""
    <section class="memory-section">
      <h3 class="memory-section-title">
        {dpgettext(
          "memory",
          "heading: memory settings of the open chat",
          "This chat's memory settings"
        )}
      </h3>
      <.form
        for={@panel.settings_form}
        id="memory-settings-form"
        class="memory-form"
        phx-hook="UnsavedChanges"
        data-saved={is_nil(@panel.settings_form.action)}
        phx-change="memory_validate_settings"
        phx-submit="memory_save_settings"
      >
        <div class="memory-field">
          <.input
            field={@panel.settings_form[:memory_book_id]}
            type="select"
            label={
              dpgettext(
                "memory",
                "field label: lore book a chat's memories are saved to",
                "Memory book"
              )
            }
            prompt={
              dpgettext(
                "memory",
                "option: make a memory book for the chat on the first save",
                "Create automatically"
              )
            }
            options={@panel.book_options}
            id="memory-settings-book"
            aria-describedby="memory-settings-book-help"
            disabled={@solo_lock != nil}
          />
          <p id="memory-settings-book-help" class="memory-help">
            {dgettext(
              "memory",
              "The lore book this chat's memories are saved to. Create automatically makes one, bound to this chat, on the first save."
            )}
          </p>
          <p
            :if={@solo_lock && not @solo_lock.broken?}
            id="memory-settings-locked"
            class="memory-help"
          >
            {dgettext(
              "memory",
              "Locked to %{character_name}: this book follows %{character_name} into your other chats.",
              character_name: @solo_lock.name
            )}
          </p>
          <p
            :if={@solo_lock && @solo_lock.broken?}
            id="memory-settings-lock-broken"
            class="memory-error"
          >
            {dgettext("memory", "The locked book is no longer available. Unlock to choose another.")}
          </p>
          <div :for={row <- @panel.character_rows} :if={@panel.solo?} class="memory-actions">
            <.lock_button
              row={row}
              lock_label={
                dgettext("memory", "Lock this book to %{character_name}", character_name: row.name)
              }
              unlock_label={
                dpgettext(
                  "memory",
                  "button: unlock the chat's memory book from its character",
                  "Unlock from %{character_name}",
                  character_name: row.name
                )
              }
            />
          </div>
        </div>
        <div :if={not @panel.solo? and @panel.bot_options != []} class="memory-field">
          <.live_component
            module={MythweaverWeb.MultiSelect}
            id="memory-settings-cast"
            name="memory_settings[cast_ids][]"
            label={
              dpgettext(
                "memory",
                "field label: characters in every memory of a group chat",
                "Always present (silent witnesses)"
              )
            }
            options={@panel.bot_options}
            selected={@panel.settings_form[:cast_ids].value || []}
            errors={picker_errors(@panel.settings_form, :cast_ids)}
            empty={
              dpgettext("memory", "empty state: chat has no characters to pick", "No characters")
            }
            tag_kind={:character}
            viewer_id={@viewer_id}
            tag_graph={@tag_graph}
            tag_vocabulary={@tag_vocabulary}
          />
          <p id="memory-settings-cast-help" class="memory-help">
            {dgettext(
              "memory",
              "Characters present in every new memory of this chat besides whoever speaks: the memory names them, is filtered to them, and is copied into their character books."
            )}
          </p>
        </div>
        <div class="memory-field">
          <.input
            field={@panel.settings_form[:profile_id]}
            type="select"
            label={dpgettext("memory", "field label: memory profile of the chat", "Profile")}
            prompt={dpgettext("memory", "option: use the default memory profile", "Default")}
            options={@panel.profile_options}
            id="memory-settings-profile"
            aria-describedby="memory-settings-profile-help"
          />
          <p id="memory-settings-profile-help" class="memory-help">
            {dgettext(
              "memory",
              "The model, prompts and entry settings this chat's memories use. Default uses your default memory profile."
            )}
          </p>
        </div>
        <div class="memory-field">
          <.input
            field={@panel.settings_form[:auto_enabled]}
            type="checkbox"
            label={
              dpgettext(
                "memory",
                "toggle: write memories of the chat automatically",
                "Create memories automatically"
              )
            }
            id="memory-settings-auto"
            aria-describedby="memory-settings-auto-help"
          />
          <p id="memory-settings-auto-help" class="memory-help">
            {dgettext(
              "memory",
              "Write a memory of the newest scene by itself whenever the trigger below is reached."
            )}
          </p>
        </div>
        <.field_row id="memory-settings-auto-row" align="start">
          <:field class="memory-field">
            <.input
              field={@panel.settings_form[:auto_trigger]}
              type="select"
              label={dpgettext("memory", "field label: what starts an automatic memory", "Trigger")}
              prompt={default_trigger_prompt(@panel.prefs.auto_trigger)}
              options={trigger_options()}
              id="memory-settings-trigger"
              aria-describedby="memory-settings-trigger-help"
            />
            <p id="memory-settings-trigger-help" class="memory-help">
              {dgettext(
                "memory",
                "What starts an automatic memory: a count of new messages, or their tokens. Default follows the setting on /settings/memory."
              )}
            </p>
          </:field>
          <:field class="memory-field">
            <.input
              field={@panel.settings_form[:auto_interval]}
              type="number"
              label={
                dpgettext(
                  "memory",
                  "field label: new messages that start an automatic memory",
                  "Interval"
                )
              }
              placeholder={
                dpgettext(
                  "memory",
                  "placeholder: blank uses the default automatic memory interval",
                  "Default (%{message_count})",
                  message_count: Format.number(@panel.prefs.auto_interval)
                )
              }
              id="memory-settings-interval"
              aria-describedby="memory-settings-interval-help"
            />
            <p id="memory-settings-interval-help" class="memory-help">
              {dgettext(
                "memory",
                "With the message trigger, how many new messages past the boundary (buffer not counted) make a memory. Blank follows /settings/memory."
              )}
            </p>
          </:field>
          <:field class="memory-field">
            <.input
              field={@panel.settings_form[:auto_buffer]}
              type="number"
              label={
                dpgettext(
                  "memory",
                  "field label: newest messages an automatic memory leaves out",
                  "Buffer"
                )
              }
              placeholder={
                dpgettext(
                  "memory",
                  "placeholder: blank uses the default automatic memory buffer",
                  "Default (%{message_count})",
                  message_count: Format.number(@panel.prefs.auto_buffer)
                )
              }
              id="memory-settings-buffer"
              aria-describedby="memory-settings-buffer-help"
            />
            <p id="memory-settings-buffer-help" class="memory-help">
              {dgettext(
                "memory",
                "How many of the newest messages an automatic memory leaves out of its scene. Blank follows /settings/memory."
              )}
            </p>
          </:field>
          <:field class="memory-field">
            <.input
              field={@panel.settings_form[:auto_token_threshold]}
              type="number"
              label={
                dpgettext(
                  "memory",
                  "field label: new tokens that start an automatic memory",
                  "Token threshold"
                )
              }
              placeholder={
                dpgettext(
                  "memory",
                  "placeholder: blank uses the default automatic memory token threshold",
                  "Default (%{token_count})",
                  token_count: Format.number(@panel.prefs.auto_token_threshold)
                )
              }
              id="memory-settings-tokens"
              aria-describedby="memory-settings-tokens-help"
            />
            <p id="memory-settings-tokens-help" class="memory-help">
              {dgettext(
                "memory",
                "With the token trigger, how many tokens of new messages past the boundary (buffer not counted) make a memory. Blank follows /settings/memory."
              )}
            </p>
          </:field>
        </.field_row>
        <.field_row id="memory-settings-hide-row" align="start">
          <:field class="memory-field">
            <.input
              field={@panel.settings_form[:auto_hide]}
              type="select"
              label={
                dpgettext(
                  "memory",
                  "field label: which processed messages are hidden from the AI",
                  "Auto-hide processed messages"
                )
              }
              options={auto_hide_options()}
              id="memory-settings-hide"
              aria-describedby="memory-settings-hide-help"
            />
            <p id="memory-settings-hide-help" class="memory-help">
              {dgettext(
                "memory",
                "After a memory is saved, hide the messages it covers from the AI: every processed message, or only the scene just saved."
              )}
            </p>
          </:field>
          <:field class="memory-field">
            <.input
              field={@panel.settings_form[:leave_unhidden]}
              type="number"
              label={
                dpgettext(
                  "memory",
                  "field label: newest processed messages auto-hide keeps visible",
                  "Leave unhidden"
                )
              }
              id="memory-settings-unhidden"
              aria-describedby="memory-settings-unhidden-help"
            />
            <p id="memory-settings-unhidden-help" class="memory-help">
              {dgettext(
                "memory",
                "How many of the newest processed messages auto-hide leaves visible to the AI."
              )}
            </p>
          </:field>
        </.field_row>
        <fieldset
          :if={@panel.side_prompt_list != []}
          id="memory-settings-side-targets"
          class="memory-fieldset"
          aria-describedby="memory-settings-side-targets-help"
        >
          <legend>
            {dpgettext(
              "memory",
              "field label: book each side prompt saves to in this chat",
              "Side prompt books"
            )}
          </legend>
          <p id="memory-settings-side-targets-help" class="memory-help">
            {dgettext(
              "memory",
              "The book each side prompt saves its new entries to in this chat. Side prompt's own target uses the book the side prompt names."
            )}
          </p>
          <.input
            :for={side <- @panel.side_prompt_list}
            type="select"
            name={"memory_settings[side_prompt_book_ids][#{side.id}]"}
            value={(@panel.settings_form[:side_prompt_book_ids].value || %{})[side.id]}
            label={side.name}
            prompt={
              dpgettext(
                "memory",
                "option: side prompt saves to the book it names itself",
                "Side prompt's own target"
              )
            }
            options={@panel.book_options}
            id={"memory-settings-side-target-#{side.id}"}
          />
        </fieldset>
        <div class="memory-row">
          <.input
            field={@panel.settings_form[:side_prompt_set_mode]}
            type="select"
            label={
              dpgettext(
                "memory",
                "field label: which side prompts run automatically in the chat",
                "Side prompts that run automatically"
              )
            }
            options={side_prompt_set_mode_options()}
            id="memory-settings-side-set-mode"
          />
          <.input
            :if={to_string(@panel.settings_form[:side_prompt_set_mode].value) == "set"}
            field={@panel.settings_form[:side_prompt_set_id]}
            type="select"
            label={
              dpgettext(
                "memory",
                "field label: side prompt set that runs automatically",
                "Side prompt set"
              )
            }
            prompt={dpgettext("memory", "option: no side prompt set picked yet", "Pick a set")}
            options={@panel.side_prompt_set_options}
            id="memory-settings-side-set"
          />
        </div>
        <.form_actions>
          <.button type="submit" id="memory-settings-save" variant="primary">
            {dpgettext("memory", "button: save the chat's memory settings", "Save settings")}
          </.button>
        </.form_actions>
      </.form>
    </section>
    """
  end

  # A picker has no `field`, so this is `input/1`'s `used_input?` gate: no errors on a pristine form.
  defp picker_errors(form, name) do
    field = form[name]
    if used_input?(field), do: Enum.map(field.errors, &translate_error/1), else: []
  end

  # Character books are a group chat's: a solo chat locks its own memory book under Settings.
  defp group_characters?(panel), do: not panel.solo? and panel.character_rows != []

  attr :panel, :map, required: true

  # Only the characters with a setup (a chat choice, a lock or both) are listed; the add form offers
  # the rest. Adds and deletes save at once.
  defp characters_tab(assigns) do
    panel = assigns.panel

    assigns =
      assign(assigns,
        rows: Enum.filter(panel.character_rows, &(&1.lock || &1.book_id)),
        available: for(row <- panel.character_rows, !(row.lock || row.book_id), do: {row.name, row.id}),
        book_names: Map.new(panel.book_options, fn {name, id} -> {id, name} end)
      )

    ~H"""
    <p :if={not group_characters?(@panel)} id="memory-characters-solo" class="memory-empty">
      {dgettext(
        "memory",
        "Only group chats have character books. A solo chat locks its memory book to its character under Settings."
      )}
    </p>
    <section :if={group_characters?(@panel)} id="memory-characters" class="memory-section">
      <h3 class="memory-section-title">
        {dpgettext(
          "memory",
          "heading: per-character memory books of a group chat",
          "Character memory books"
        )}
      </h3>
      <p id="memory-characters-help" class="memory-help">
        {dgettext(
          "memory",
          "Each new memory is also copied into the book of every character in it (every character, when none of them speaks), filtered to that character; on that character's turn the copy stands in for the shared memory. The chat's own memory book may be one. Lock a character to its book to carry the book into your other chats with them."
        )}
      </p>
      <p :if={@rows == []} id="memory-character-books-empty" class="memory-empty">
        {dpgettext("memory", "empty state: group chat has no character books", "No character books")}
      </p>
      <ul :if={@rows != []} id="memory-character-books" class="memory-list">
        <li :for={row <- @rows} id={"memory-character-book-#{row.id}"} class="memory-entry">
          <span class="memory-entry-title">{row.name}</span>
          <span class="memory-entry-meta">
            {@book_names[(row.lock && row.lock.lore_book_id) || row.book_id] ||
              dpgettext(
                "memory",
                "status: character book that was deleted or is unreadable",
                "Unavailable book"
              )}
          </span>
          <span :if={row.lock} class="memory-badge">
            {dpgettext("memory", "badge: character book locked to its character", "Locked")}
          </span>
          <.lock_button
            row={row}
            lock_label={dpgettext("memory", "button: lock a character to its book", "Lock")}
            unlock_label={dpgettext("memory", "button: unlock a character from its book", "Unlock")}
          />
          <.button
            id={"memory-character-book-delete-#{row.id}"}
            icon
            danger
            phx-click="memory_character_book_delete"
            phx-value-character-id={row.id}
            data-confirm={remove_character_book_confirm(row)}
            aria-label={
              dpgettext(
                "memory",
                "aria label: icon button that removes a character's memory book",
                "Remove %{character_name}'s character book",
                character_name: row.name
              )
            }
          >
            <.lucide name="trash" />
          </.button>
          <p :if={row.broken?} id={"memory-character-lock-broken-#{row.id}"} class="memory-error">
            {dgettext("memory", "The locked book is no longer available. Unlock to choose another.")}
          </p>
        </li>
      </ul>
      <div :if={is_nil(@panel.character_book_form) and @available != []} class="memory-actions">
        <.button size="sm" id="memory-character-book-new" phx-click="memory_character_book_new">
          <.lucide name="plus" />
          {dpgettext("memory", "button: add a character memory book", "Add character book")}
        </.button>
      </div>
      <.form
        :if={@panel.character_book_form}
        for={@panel.character_book_form}
        id="memory-character-book-form"
        class="memory-form memory-card"
        phx-change="memory_character_book_change"
        phx-submit="memory_character_book_add"
      >
        <div class="memory-row">
          <.input
            field={@panel.character_book_form[:character_id]}
            type="select"
            label={dpgettext("memory", "field label: character a memory book is for", "Character")}
            prompt={dpgettext("memory", "option: no character picked yet", "Pick a character")}
            options={@available}
            id="memory-character-book-form-character"
          />
          <.input
            field={@panel.character_book_form[:book_id]}
            type="select"
            label={dpgettext("memory", "field label: lore book a character's memories go to", "Book")}
            prompt={dpgettext("memory", "option: no book picked yet", "Pick a book")}
            options={@panel.book_options}
            id="memory-character-book-form-book"
          />
        </div>
        <.input
          field={@panel.character_book_form[:lock]}
          type="checkbox"
          label={dpgettext("memory", "toggle: lock the character to this book", "Lock to this book")}
          id="memory-character-book-form-lock"
        />
        <p class="memory-help">
          {dgettext("memory", "A locked book follows the character into your other chats.")}
        </p>
        <p :if={@panel.character_book_error} id="memory-character-book-error" class="memory-error">
          {@panel.character_book_error}
        </p>
        <div class="memory-actions">
          <.button id="memory-character-book-cancel" phx-click="memory_character_book_cancel">
            {dpgettext("memory", "button: cancel adding a character book", "Cancel")}
          </.button>
          <.button type="submit" variant="primary" id="memory-character-book-add">
            {dpgettext("memory", "button: add the character book", "Add")}
          </.button>
        </div>
      </.form>
    </section>
    """
  end

  attr :panel, :map, required: true
  attr :viewer_id, :string, required: true
  attr :tag_graph, :any, required: true
  attr :tag_vocabulary, :list, default: []

  # Only the set entries are listed, in their saved order; ids whose entry is gone or unreadable
  # stay listed so they can still be removed.
  defp context_tab(assigns) do
    panel = assigns.panel
    names = Map.new(panel.entry_options, fn {name, id} -> {id, name} end)

    assigns =
      assign(assigns,
        rows: Enum.map(panel.settings.context_entry_ids, &{&1, names[&1]}),
        available: Enum.reject(panel.entry_options, fn {_, id} -> id in panel.settings.context_entry_ids end)
      )

    ~H"""
    <section id="memory-context" class="memory-section">
      <h3 class="memory-section-title">
        {dpgettext(
          "memory",
          "heading: lore entries sent with every memory request of the chat",
          "Additional context entries"
        )}
      </h3>
      <p id="memory-context-help" class="memory-help">
        {dgettext("memory", "Lore entries sent with every memory request for this chat.")}
      </p>
      <p :if={@rows == []} id="memory-context-empty" class="memory-empty">
        {dpgettext("memory", "empty state: chat has no memory context entries", "No context entries")}
      </p>
      <ul :if={@rows != []} id="memory-context-entries" class="memory-list">
        <li :for={{id, name} <- @rows} id={"memory-context-entry-#{id}"} class="memory-entry">
          <span class="memory-entry-title">
            {name ||
              dpgettext(
                "memory",
                "status: context entry that was deleted or is unreadable",
                "Unavailable entry"
              )}
          </span>
          <.button
            id={"memory-context-delete-#{id}"}
            icon
            danger
            phx-click="memory_context_delete"
            phx-value-id={id}
            aria-label={remove_context_entry_label(name)}
          >
            <.lucide name="trash" />
          </.button>
        </li>
      </ul>
      <div :if={is_nil(@panel.context_form) and @available != []} class="memory-actions">
        <.button size="sm" id="memory-context-new" phx-click="memory_context_new">
          <.lucide name="plus" />
          {dpgettext("memory", "button: add memory context entries", "Add context entries")}
        </.button>
      </div>
      <.form
        :if={@panel.context_form}
        for={@panel.context_form}
        id="memory-context-form"
        class="memory-form memory-card"
        phx-change="memory_context_change"
        phx-submit="memory_context_add"
      >
        <.live_component
          module={MythweaverWeb.MultiSelect}
          id="memory-context-picker"
          name="memory_context[entry_ids][]"
          label={dpgettext("memory", "field label: lore entries to add as memory context", "Entries")}
          options={@available}
          selected={@panel.context_form[:entry_ids].value || []}
          empty={dpgettext("memory", "empty state: no lore entries to pick", "No lore entries")}
          tag_kind={:lore_entry}
          viewer_id={@viewer_id}
          tag_graph={@tag_graph}
          tag_vocabulary={@tag_vocabulary}
        />
        <p :if={@panel.context_error} id="memory-context-error" class="memory-error">
          {@panel.context_error}
        </p>
        <div class="memory-actions">
          <.button id="memory-context-cancel" phx-click="memory_context_cancel">
            {dpgettext("memory", "button: cancel adding context entries", "Cancel")}
          </.button>
          <.button type="submit" variant="primary" id="memory-context-add">
            {dpgettext("memory", "button: add the picked context entries", "Add")}
          </.button>
        </div>
      </.form>
    </section>
    """
  end

  attr :row, :map, required: true, doc: "a `character_rows` entry"
  attr :lock_label, :string, required: true
  attr :unlock_label, :string, required: true

  defp lock_button(assigns) do
    Iconex.hint(:lucide, ~w[lock lock-open])

    ~H"""
    <.button
      type="button"
      size="sm"
      id={"memory-character-lock-#{@row.id}"}
      phx-click={if @row.lock, do: "memory_character_unlock", else: "memory_character_lock"}
      phx-value-character-id={@row.id}
    >
      <.lucide name={if @row.lock, do: "lock-open", else: "lock"} />
      {if @row.lock, do: @unlock_label, else: @lock_label}
    </.button>
    """
  end

  attr :id, :string, required: true
  attr :tokens, :integer, required: true
  attr :threshold, :integer, required: true
  slot :inner_block, required: true, doc: "the confirm button"

  defp token_warning(assigns) do
    ~H"""
    <div id={@id} class="memory-warning">
      <span>
        {dngettext(
          "memory",
          "This memory request is about %{token_count} token, over the %{threshold_tokens} token warning.",
          "This memory request is about %{token_count} tokens, over the %{threshold_tokens} token warning.",
          @tokens,
          token_count: Format.number(@tokens),
          threshold_tokens: Format.number(@threshold)
        )}
      </span>
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp trigger_options do
    [
      {dpgettext("memory", "option: automatic memory trigger", "Every N messages"), :messages},
      {dpgettext("memory", "option: automatic memory trigger", "Token threshold"), :tokens}
    ]
  end

  defp default_trigger_prompt(:messages),
    do: dpgettext("memory", "option: use the default automatic memory trigger", "Default (Every N messages)")

  defp default_trigger_prompt(:tokens),
    do: dpgettext("memory", "option: use the default automatic memory trigger", "Default (Token threshold)")

  defp auto_hide_options do
    [
      {dpgettext("memory", "option: auto-hide processed messages", "Off"), :none},
      {dpgettext("memory", "option: auto-hide processed messages", "All processed"), :all},
      {dpgettext("memory", "option: auto-hide processed messages", "Last scene only"), :last}
    ]
  end

  defp side_prompt_set_mode_options do
    [
      {dpgettext("memory", "option: which side prompts run automatically", "Default"), :default},
      {dpgettext(
         "memory",
         "option: which side prompts run automatically",
         "Individually enabled side prompts"
       ), :individual},
      {dpgettext("memory", "option: which side prompts run automatically", "A set"), :set}
    ]
  end

  defp memory_tabs do
    [
      {"memory", dpgettext("memory", "tab: memory status and create forms", "Memory")},
      {"reviews", dpgettext("memory", "tab: memory drafts awaiting review", "Reviews")},
      {"entries", dpgettext("memory", "tab: records of the chat's memory book", "Entries")},
      {"consolidate", dpgettext("memory", "tab: consolidate memories into the next tier", "Consolidate")},
      {"topical", dpgettext("memory", "tab: gather one topic into a clip", "Topical clip")},
      {"side", dpgettext("memory", "tab: side prompts of the chat", "Side prompts")},
      {"characters", dpgettext("memory", "tab: per-character memory books", "Character books")},
      {"context", dpgettext("memory", "tab: lore entries sent with memory requests", "Context")},
      {"settings", dpgettext("memory", "tab: the chat's memory settings", "Settings")}
    ]
  end

  defp clip_activation_options do
    [
      {"keyword", dpgettext("memory", "option: how a new clip is activated", "By keyword (the title)")},
      {"constant", dpgettext("memory", "option: how a new clip is activated", "Always")}
    ]
  end

  defp remove_context_entry_label(nil),
    do: dpgettext("memory", "aria label: icon button that removes an unavailable context entry", "Remove entry")

  defp remove_context_entry_label(name),
    do:
      dpgettext("memory", "aria label: icon button that removes a context entry", "Remove %{entry_name}",
        entry_name: name
      )

  defp remove_character_book_confirm(%{lock: nil} = row) do
    gettext_comment("Confirm dialog before removing a character's memory book from a group chat.")

    dpgettext(
      "memory",
      "status: confirm dialog before removing a character's memory book from a group chat",
      "Remove %{character_name}'s character book?",
      character_name: row.name
    )
  end

  defp remove_character_book_confirm(row) do
    gettext_comment(
      "Confirm dialog before removing a character's memory book from a group chat, when the character is locked to that book."
    )

    dgettext(
      "memory",
      "Remove %{character_name}'s character book? This also unlocks %{character_name} in your other chats.",
      character_name: row.name
    )
  end

  defp source_names_line(names) do
    gettext_comment("%{source_names} is a comma-separated list of memory entry names.")

    dpgettext(
      "memory",
      "field label: memory entries a consolidation summary was built from",
      "From: %{source_names}",
      source_names: names
    )
  end

  attr :panel, :map, required: true

  defp reviews_tab(assigns) do
    ~H"""
    <p :if={@panel.reviews == []} id="memory-reviews-empty" class="memory-empty">
      {dpgettext("memory", "empty state: no memory drafts awaiting review", "Nothing to review")}
    </p>
    <.form
      :for={job <- @panel.reviews}
      for={%{}}
      as={:review}
      id={"memory-review-#{job.id}"}
      class="memory-form memory-card"
      phx-change="memory_review_change"
      phx-submit="memory_review_save"
    >
      <h3 class="memory-section-title">{job.label}</h3>
      <input type="hidden" name="job_id" value={job.id} />
      <.memory_review :if={job.tag == :memory} job={job} edits={@panel.review_edits[job.id] || %{}} />
      <.consolidation_review
        :if={job.tag == :consolidation}
        job={job}
        names={@panel.review_details[job.id].names}
        edits={@panel.review_edits[job.id] || %{}}
      />
      <.compaction_review
        :if={job.tag == :compaction}
        job={job}
        details={@panel.review_details[job.id]}
      />
      <.assistance_review
        :if={job.tag == :memory_assistance}
        job={job}
        current={@panel.review_details[job.id].current}
        edits={@panel.review_edits[job.id] || %{}}
      />
      <.editor
        :if={job.tag in [:topical_clip, :side_prompt]}
        name="review[content]"
        value={job.result["content"]}
        label={
          dpgettext("memory", "field label: text of a topical clip or side prompt draft", "Draft")
        }
        language="markdown"
        spellcheck
        rows={10}
        id={"memory-review-content-#{job.id}"}
      />
      <p :if={@panel.review_errors[job.id]} id={"memory-review-error-#{job.id}"} class="memory-error">
        {@panel.review_errors[job.id]}
      </p>
      <%!-- A memory whose messages changed while it was written can still be kept as drafted;
      Regenerate instead summarizes them as they are now. --%>
      <div
        :if={job.tag == :memory and MapSet.member?(@panel.review_forceable, job.id)}
        class="memory-actions"
      >
        <.button
          type="submit"
          size="sm"
          name="ignore_changes"
          value="true"
          id={"memory-review-force-#{job.id}"}
          data-confirm={save_anyway_confirm()}
        >
          <.lucide name="save" />
          {dpgettext("memory", "button: save a memory draft whose messages changed", "Save anyway")}
        </.button>
      </div>
      <%!-- The model's reply as it came back: a value it wrote as prose outside its JSON is lost from
      the draft above, but can be copied from here. --%>
      <details
        :if={(job.raw_output || "") != ""}
        id={"memory-review-raw-#{job.id}"}
        class="memory-section"
      >
        <summary>
          {dpgettext("memory", "button: show the model's raw reply for a draft", "View raw response")}
        </summary>
        <div id={"memory-review-raw-text-#{job.id}"} class="memory-original memory-raw" phx-no-format>{job.raw_output}</div>
      </details>
      <div class="memory-actions">
        <.button
          id={"memory-review-discard-#{job.id}"}
          danger
          phx-click="memory_review_discard"
          phx-value-id={job.id}
          data-confirm={discard_draft_confirm()}
        >
          {dpgettext("memory", "button: discard a memory draft", "Discard")}
        </.button>
        <.button
          id={"memory-review-regenerate-#{job.id}"}
          phx-click="memory_review_regenerate"
          phx-value-id={job.id}
        >
          <.lucide name="refresh-cw" />
          {dpgettext("memory", "button: write a memory draft again", "Regenerate")}
        </.button>
        <.button
          type="submit"
          id={"memory-review-save-#{job.id}"}
          variant="primary"
          data-confirm={left_out_confirm(job)}
        >
          <.lucide name="check" /> {dpgettext(
            "memory",
            "button: save a reviewed memory draft",
            "Save"
          )}
        </.button>
      </div>
    </.form>
    """
  end

  attr :job, :map, required: true
  attr :edits, :map, required: true, doc: "the form's last posted `review` params (`review_edits`)"

  defp memory_review(assigns) do
    ~H"""
    <.input
      type="text"
      name="review[title]"
      value={@job.result["title"]}
      label={dpgettext("memory", "field label: title of a memory draft", "Title")}
      id={"memory-review-title-#{@job.id}"}
    />
    <.editor
      name="review[content]"
      value={@job.result["content"]}
      label={dpgettext("memory", "field label: text of a memory draft", "Content")}
      language="markdown"
      spellcheck
      rows={6}
      id={"memory-review-content-#{@job.id}"}
    />
    <.tag_input
      id={"memory-review-keywords-#{@job.id}"}
      name="review[keywords][]"
      mode="keywords"
      label={dpgettext("memory", "field label: keywords of a memory draft", "Keywords")}
      values={keyword_values(@edits["keywords"], @job.result["keywords"])}
    />
    """
  end

  attr :job, :map, required: true
  attr :names, :map, required: true, doc: "source record id => entry name"
  attr :edits, :map, required: true, doc: "the form's last posted `review` params (`review_edits`)"

  defp consolidation_review(assigns) do
    ~H"""
    <section :if={(@job.result["unassigned"] || []) != []} class="memory-section">
      <h4 class="memory-section-title">
        {dpgettext(
          "memory",
          "heading: source records a consolidation left out, with their count",
          "Left out (%{record_count})",
          record_count: Format.number(length(@job.result["unassigned"]))
        )}
      </h4>
      <ul id={"memory-review-unassigned-#{@job.id}"} class="memory-list">
        <li :for={item <- @job.result["unassigned"]}>
          <strong>{@names[item["record_id"]] || deleted_label()}</strong>
          <span :if={item["reason"] != ""} class="memory-entry-meta">— {item["reason"]}</span>
        </li>
      </ul>
    </section>
    <section
      :for={{candidate, i} <- Enum.with_index(@job.result["candidates"])}
      id={"memory-review-candidate-#{@job.id}-#{i}"}
      class="memory-form memory-card"
    >
      <.input
        type="checkbox"
        name={"review[candidates][#{i}][keep]"}
        checked
        label={dpgettext("memory", "toggle: keep this consolidation summary", "Keep this summary")}
        id={"memory-review-keep-#{@job.id}-#{i}"}
      />
      <.input
        type="text"
        name={"review[candidates][#{i}][title]"}
        value={candidate["title"]}
        label={dpgettext("memory", "field label: title of a consolidation summary", "Title")}
        id={"memory-review-title-#{@job.id}-#{i}"}
      />
      <.editor
        name={"review[candidates][#{i}][summary]"}
        value={candidate["summary"]}
        label={dpgettext("memory", "field label: text of a consolidation summary", "Summary")}
        language="markdown"
        spellcheck
        rows={6}
        id={"memory-review-summary-#{@job.id}-#{i}"}
      />
      <.tag_input
        id={"memory-review-keywords-#{@job.id}-#{i}"}
        name={"review[candidates][#{i}][keywords][]"}
        mode="keywords"
        label={dpgettext("memory", "field label: keywords of a consolidation summary", "Keywords")}
        values={
          keyword_values(
            get_in(@edits, ["candidates", to_string(i), "keywords"]),
            candidate["keywords"]
          )
        }
      />
      <p class="memory-entry-meta">
        {source_names_line(
          Enum.map_join(candidate["source_ids"], ", ", &(@names[&1] || deleted_label()))
        )}
      </p>
      <div class="memory-actions">
        <.button
          size="sm"
          type="button"
          id={"memory-review-regenerate-candidate-#{@job.id}-#{i}"}
          phx-click="memory_review_regenerate_candidate"
          phx-value-id={@job.id}
          phx-value-index={i}
        >
          <.lucide name="refresh-cw" />
          {dpgettext(
            "memory",
            "button: write one consolidation summary again",
            "Regenerate this summary"
          )}
        </.button>
      </div>
    </section>
    """
  end

  attr :job, :map, required: true
  attr :current, :map, required: true, doc: "candidate record id => its current content, nil when gone"
  attr :edits, :map, required: true, doc: "the form's last posted `review` params (`review_edits`)"

  defp assistance_review(assigns) do
    ~H"""
    <p :if={@job.result["applied"]} id={"memory-review-applied-#{@job.id}"} class="memory-entry-meta">
      {dngettext(
        "memory",
        "Added %{line_count} clip line automatically.",
        "Added %{line_count} clip lines automatically.",
        @job.result["applied"],
        line_count: Format.number(@job.result["applied"])
      )}
    </p>
    <section
      :for={{candidate, i} <- Enum.with_index(@job.result["candidates"] || [])}
      id={"memory-review-assist-#{@job.id}-#{i}"}
      class="memory-form memory-card"
    >
      <.input
        type="checkbox"
        name={"review[candidates][#{i}][keep]"}
        checked
        label={dpgettext("memory", "toggle: keep this suggested clip update", "Keep this update")}
        id={"memory-review-assist-keep-#{@job.id}-#{i}"}
      />
      <h4 class="memory-section-title">
        {candidate["title"]}
        <span class="memory-entry-meta">
          {if candidate["type"] == "topical",
            do: dpgettext("memory", "badge: kind of clip a suggested update is for", "Topical clip"),
            else: dpgettext("memory", "badge: kind of clip a suggested update is for", "Clip")}
        </span>
      </h4>
      <%= if candidate["type"] == "topical" do %>
        <.editor
          name={"review[candidates][#{i}][text]"}
          value={candidate["text"]}
          label={
            dpgettext("memory", "field label: suggested new text of a topical clip", "Revised clip")
          }
          language="markdown"
          spellcheck
          rows={8}
          id={"memory-review-assist-text-#{@job.id}-#{i}"}
        />
        <details>
          <summary>
            {dpgettext("memory", "button: show the current text of a topical clip", "Current")}
          </summary>
          <div class="memory-original" phx-no-format>{@current[candidate["record_id"]] || dpgettext("memory", "status: clip entry that was deleted", "(the entry is gone)")}</div>
        </details>
      <% else %>
        <.input
          type="text"
          name={"review[candidates][#{i}][text]"}
          value={candidate["text"]}
          label={dpgettext("memory", "field label: suggested line to add to a clip", "New clip line")}
          id={"memory-review-assist-text-#{@job.id}-#{i}"}
        />
        <p class="memory-entry-meta">
          {dpgettext(
            "memory",
            "field label: message a suggested clip line comes from",
            "From message #%{message_number}",
            message_number: candidate["message_number"]
          )}
        </p>
      <% end %>
    </section>
    <section
      :if={(@job.result["topics"] || []) != [] or @job.params["pass"] == "suggest"}
      id={"memory-review-topics-#{@job.id}"}
      class="memory-section"
    >
      <h4 class="memory-section-title">
        {dpgettext("memory", "heading: topical clips the model suggests", "Suggested topical clips")}
      </h4>
      <div
        :for={{topic, j} <- Enum.with_index(@job.result["topics"] || [])}
        id={"memory-review-topic-#{@job.id}-#{j}"}
        class="memory-form memory-card"
      >
        <.input
          type="checkbox"
          name={"review[topics][#{j}][keep]"}
          checked
          label={
            dpgettext(
              "memory",
              "toggle: create this suggested topical clip",
              "Create this topical clip"
            )
          }
          id={"memory-review-topic-keep-#{@job.id}-#{j}"}
        />
        <.input
          type="text"
          name={"review[topics][#{j}][topic]"}
          value={topic["topic"]}
          label={dpgettext("memory", "field label: topic of a topical clip", "Topic")}
          id={"memory-review-topic-topic-#{@job.id}-#{j}"}
        />
        <.tag_input
          id={"memory-review-topic-keywords-#{@job.id}-#{j}"}
          name={"review[topics][#{j}][keywords][]"}
          mode="keywords"
          label={dpgettext("memory", "field label: keywords of a topical clip", "Keywords")}
          values={
            keyword_values(get_in(@edits, ["topics", to_string(j), "keywords"]), topic["keywords"])
          }
        />
      </div>
      <div id={"memory-review-topic-new-#{@job.id}"} class="memory-form memory-card">
        <p class="memory-entry-meta">
          {dpgettext("memory", "heading: add a topic to the suggested topical clips", "Add a topic")}
        </p>
        <.input
          type="text"
          name="review[topics][new][topic]"
          value=""
          label={dpgettext("memory", "field label: topic of a topical clip", "Topic")}
          id={"memory-review-topic-new-topic-#{@job.id}"}
        />
        <.tag_input
          id={"memory-review-topic-new-keywords-#{@job.id}"}
          name="review[topics][new][keywords][]"
          mode="keywords"
          label={dpgettext("memory", "field label: keywords of a topical clip", "Keywords")}
          placeholder={
            dpgettext(
              "memory",
              "placeholder: topical clip keywords default to the topic",
              "Default: the topic"
            )
          }
          values={keyword_values(get_in(@edits, ["topics", "new", "keywords"]), [])}
        />
      </div>
    </section>
    """
  end

  defp left_out_confirm(%{tag: :consolidation, result: %{"unassigned" => [_ | _] = items}}) do
    gettext_comment("Confirm dialog when saving a consolidation draft that left some source entries out.")

    dngettext(
      "memory",
      "%{entry_count} source entry is left out and stays unconsolidated. Save anyway?",
      "%{entry_count} source entries are left out and stay unconsolidated. Save anyway?",
      length(items),
      entry_count: Format.number(length(items))
    )
  end

  defp left_out_confirm(_job), do: nil

  defp save_anyway_confirm do
    gettext_comment("Confirm dialog when saving a memory draft whose messages changed while it was being written.")

    dgettext(
      "memory",
      "Save this memory anyway? It summarizes the messages as they were when it was written."
    )
  end

  defp discard_draft_confirm do
    gettext_comment("Confirm dialog before discarding a memory draft awaiting review.")
    dpgettext("memory", "status: confirm dialog before discarding a memory draft", "Discard this draft?")
  end

  defp deleted_label, do: dpgettext("memory", "status: source memory entry that was deleted", "(deleted)")

  # A review's keyword chips: what its form last posted (empty sentinel dropped), else the draft's.
  defp keyword_values(posted, _draft) when is_list(posted), do: Enum.reject(posted, &(&1 == ""))
  defp keyword_values(_posted, draft), do: List.wrap(draft)

  attr :job, :map, required: true
  attr :details, :map, required: true, doc: "`original`, `original_tokens`, `draft_tokens`"

  defp compaction_review(assigns) do
    ~H"""
    <div class="memory-compare">
      <section class="memory-section">
        <h4 class="memory-section-title">
          {dpgettext("memory", "heading: original text of an entry being compacted", "Original")}
          <span class="memory-entry-meta">{token_count(@details.original_tokens)}</span>
        </h4>
        <%!-- Inline: the box keeps the content's own line breaks (pre-wrap). --%>
        <div id={"memory-review-original-#{@job.id}"} class="memory-original" phx-no-format>{@details.original || dpgettext("memory", "status: clip entry that was deleted", "(the entry is gone)")}</div>
      </section>
      <section class="memory-section">
        <h4 class="memory-section-title">
          {dpgettext("memory", "heading: compacted draft of an entry", "Draft")}
          <span class="memory-entry-meta">{token_count(@details.draft_tokens)}</span>
        </h4>
        <.editor
          name="review[content]"
          value={@job.result["content"]}
          language="markdown"
          spellcheck
          rows={8}
          id={"memory-review-content-#{@job.id}"}
        />
      </section>
    </div>
    """
  end

  attr :panel, :map, required: true

  defp entries_tab(assigns) do
    # `list_records/2` runs oldest first; the newest memory leads each group.
    groups = assigns.panel.records |> Enum.chunk_by(&{&1.kind, &1.tier}) |> Enum.map(&Enum.reverse/1)
    assigns = assign(assigns, groups: groups)

    ~H"""
    <p :if={@panel.records == []} id="memory-entries-empty" class="memory-empty">
      {dpgettext("memory", "empty state: chat's memory book has no records", "No memories yet")}
    </p>
    <section :for={[first | _] = records <- @groups} class="memory-section">
      <h3 class="memory-section-title">{group_name(first)}</h3>
      <ul class="memory-list">
        <li :for={record <- records} id={"memory-entry-#{record.id}"} class="memory-entry">
          <span class="memory-entry-title">{record.entry.name}</span>
          <span :if={record.range_start} class="memory-entry-meta">
            {dpgettext(
              "memory",
              "status: message range a memory entry covers",
              "#%{first_message_number}–#%{last_message_number}",
              first_message_number: Format.number(record.range_start + 1),
              last_message_number: Format.number(record.range_end + 1)
            )}
          </span>
          <span class="memory-entry-meta">
            {if Memory.record_enabled?(record),
              do: dpgettext("memory", "status: memory entry", "Enabled"),
              else: dpgettext("memory", "status: memory entry", "Disabled")}
          </span>
          <span :if={record.consolidated_into_id} class="memory-entry-meta">
            {dpgettext("memory", "status: memory entry merged into a higher tier", "Consolidated")}
          </span>
          <span :if={record.canonical_id} class="memory-entry-meta">
            {dpgettext(
              "memory",
              "badge: memory entry copied into a character's book",
              "Character copy"
            )}
          </span>
          <.button
            :if={
              record.kind in [:memory, :consolidation, :side_prompt] and
                is_nil(record.consolidated_into_id) and not is_nil(record.chat_id) and
                is_nil(record.canonical_id)
            }
            size="sm"
            id={"memory-entry-regenerate-#{record.id}"}
            phx-click="memory_entry_regenerate"
            phx-value-id={record.id}
          >
            <.lucide name="refresh-cw" />
            {dpgettext("memory", "button: write a memory entry again", "Regenerate")}
          </.button>
          <.button
            size="sm"
            id={"memory-entry-compact-#{record.id}"}
            phx-click="memory_entry_compact"
            phx-value-id={record.id}
          >
            <.lucide name="shrink" /> {dpgettext(
              "memory",
              "button: shorten a memory entry",
              "Compact"
            )}
          </.button>
          <.button
            size="sm"
            id={"memory-entry-edit-#{record.id}"}
            navigate={~p"/lore/#{record.lore_book_id}/entries/#{record.lore_entry_id}/edit"}
          >
            <.lucide name="pencil" /> {dpgettext("memory", "button: edit a memory entry", "Edit")}
          </.button>
          <.token_warning
            :if={@panel.regenerate_warning && @panel.regenerate_warning.record_id == record.id}
            id="memory-regenerate-warning"
            tokens={@panel.regenerate_warning.tokens}
            threshold={@panel.prefs.token_warning_threshold}
          >
            <.button
              id="memory-entry-regenerate-confirm"
              variant="primary"
              size="sm"
              phx-click="memory_entry_regenerate_confirm"
              phx-value-id={record.id}
            >
              {dpgettext(
                "memory",
                "button: write a memory entry again despite the token warning",
                "Regenerate anyway"
              )}
            </.button>
          </.token_warning>
        </li>
      </ul>
    </section>
    """
  end

  attr :panel, :map, required: true

  defp consolidate_tab(assigns) do
    assigns = assign(assigns, state: assigns.panel.consolidate)

    ~H"""
    <p :if={@state.ready != []} id="memory-consolidate-ready" class="memory-warning">
      {ready_to_consolidate(@state.ready)}
    </p>
    <.form
      for={@state.form}
      id="memory-consolidate-form"
      class="memory-form"
      phx-change="memory_consolidate_change"
      phx-submit="memory_consolidate_run"
    >
      <div class="memory-row">
        <.input
          field={@state.form[:book_id]}
          type="select"
          label={
            dpgettext(
              "memory",
              "field label: lore book whose entries are consolidated",
              "Source book"
            )
          }
          options={@state.book_options}
          id="memory-consolidate-book"
        />
        <.input
          field={@state.form[:tier]}
          type="select"
          label={
            dpgettext("memory", "field label: memory tier to consolidate into", "Consolidate into")
          }
          options={for tier <- 1..6, do: {consolidate_into_option(tier), tier}}
          id="memory-consolidate-tier"
        />
        <.input
          field={@state.form[:prompt_id]}
          type="select"
          label={dpgettext("memory", "field label: prompt used to consolidate memories", "Prompt")}
          options={@state.prompt_options}
          id="memory-consolidate-prompt"
        />
      </div>
      <div class="memory-row">
        <.input
          field={@state.form[:max_entries]}
          type="number"
          min="1"
          label={
            dpgettext(
              "memory",
              "field label: entries sent in one consolidation pass",
              "Max entries per pass"
            )
          }
          id="memory-consolidate-max-entries"
        />
        <.input
          field={@state.form[:token_budget]}
          type="number"
          min="1"
          label={
            dpgettext(
              "memory",
              "field label: tokens sent in one consolidation pass",
              "Token budget per pass"
            )
          }
          id="memory-consolidate-token-budget"
        />
      </div>
      <.input
        field={@state.form[:disable_sources]}
        type="checkbox"
        label={
          dpgettext(
            "memory",
            "toggle: disable source entries after consolidating them",
            "Disable the sources once consolidated"
          )
        }
        id="memory-consolidate-disable"
      />
      <.live_component
        module={MythweaverWeb.MultiSelect}
        id="memory-consolidate-sources"
        name="memory_consolidate[sources][]"
        label={dpgettext("memory", "field label: memory entries to consolidate", "Sources")}
        options={Enum.map(@state.eligible, &{source_label(&1), &1.id})}
        selected={MapSet.to_list(@state.selected)}
        empty={nothing_to_consolidate(@state.tier)}
      />
      <p :if={@state.error} id="memory-consolidate-error" class="memory-error">{@state.error}</p>
      <div class="memory-actions">
        <span id="memory-consolidate-passes" class="memory-entry-meta">
          {dpngettext(
            "memory",
            "status: number of passes a consolidation run takes",
            "%{pass_count} pass",
            "%{pass_count} passes",
            @state.passes,
            pass_count: Format.number(@state.passes)
          )}
        </span>
        <.button type="submit" id="memory-consolidate-run" variant="primary">
          <.lucide name="layers" />
          {dpgettext("memory", "button: consolidate the picked memory entries", "Consolidate")}
        </.button>
      </div>
    </.form>
    """
  end

  attr :panel, :map, required: true

  defp topical_tab(assigns) do
    assigns = assign(assigns, state: assigns.panel.topical)

    ~H"""
    <section
      :if={@panel.topic_suggestions != []}
      id="memory-topic-suggestions"
      class="memory-section"
    >
      <h3 class="memory-section-title">
        {dpgettext(
          "memory",
          "heading: topics the model suggests for topical clips",
          "Suggested topics"
        )}
      </h3>
      <ul class="memory-list">
        <li
          :for={suggestion <- @panel.topic_suggestions}
          id={"memory-topic-suggestion-#{suggestion.id}"}
          class="memory-entry"
        >
          <span class="memory-entry-title">{suggestion.topic}</span>
          <span :if={suggestion.keywords != []} class="memory-entry-meta">
            {Enum.join(suggestion.keywords, ", ")}
          </span>
          <span class="memory-entry-meta">{suggestion.book.name}</span>
          <.button
            size="sm"
            id={"memory-topic-suggestion-draft-#{suggestion.id}"}
            phx-click="memory_topic_suggestion_draft"
            phx-value-id={suggestion.id}
            disabled={suggestion.drafting?}
          >
            <.lucide name="scissors" />
            {if suggestion.drafting?,
              do:
                dpgettext("memory", "status: suggested topic being drafted into a clip", "Drafting…"),
              else: dpgettext("memory", "button: draft a clip from a suggested topic", "Draft")}
          </.button>
          <.button
            size="sm"
            id={"memory-topic-suggestion-dismiss-#{suggestion.id}"}
            phx-click="memory_topic_suggestion_dismiss"
            phx-value-id={suggestion.id}
            data-confirm={dismiss_topic_confirm(suggestion.topic)}
          >
            <.lucide name="x" /> {dpgettext("memory", "button: dismiss a suggested topic", "Dismiss")}
          </.button>
        </li>
      </ul>
      <p
        :if={@panel.topic_suggestions_error}
        id="memory-topic-suggestions-error"
        class="memory-error"
      >
        {@panel.topic_suggestions_error}
      </p>
    </section>
    <.form
      for={@state.form}
      id="memory-topical-form"
      class="memory-form"
      phx-change="memory_topical_change"
      phx-submit="memory_topical_run"
    >
      <div class="memory-row">
        <.input
          field={@state.form[:book_id]}
          type="select"
          label={dpgettext("memory", "field label: lore book a topical clip is saved to", "Book")}
          options={@state.book_options}
          prompt={
            if @state.book_options == [],
              do:
                dpgettext(
                  "memory",
                  "option: the chat's memory book, made when the clip is saved",
                  "Chat memory book (created on save)"
                )
          }
          id="memory-topical-book"
        />
        <.input
          field={@state.form[:target_record_id]}
          type="select"
          label={dpgettext("memory", "field label: topical clip to update", "Clip")}
          prompt={dpgettext("memory", "option: create a new topical clip", "New topical clip")}
          options={@state.target_options}
          id="memory-topical-target"
        />
      </div>
      <div class="memory-row">
        <.input
          field={@state.form[:topic]}
          type="text"
          label={dpgettext("memory", "field label: topic of a topical clip", "Topic")}
          placeholder={
            dpgettext("memory", "placeholder: example topic of a topical clip", "e.g. Mira's sword")
          }
          id="memory-topical-topic"
        />
        <.tag_input
          id="memory-topical-keywords"
          name="memory_topical[keywords][]"
          mode="keywords"
          label={dpgettext("memory", "field label: keywords of a topical clip", "Keywords")}
          placeholder={
            dpgettext(
              "memory",
              "placeholder: topical clip keywords default to the topic",
              "Default: the topic"
            )
          }
          values={@state.params["keywords"]}
        />
      </div>
      <.input
        :if={@state.target}
        field={@state.form[:rebuild]}
        type="checkbox"
        label={
          dgettext(
            "memory",
            "Rebuild from every picked source (otherwise only new and changed ones are sent)"
          )
        }
        id="memory-topical-rebuild"
      />
      <section id="memory-topical-sources" class="memory-section">
        <.input
          field={@state.form[:include_memories]}
          type="checkbox"
          label={
            dpgettext("memory", "toggle: use memories as topical clip sources", "Include memories")
          }
          id="memory-topical-include-memories"
        />
        <.live_component
          :if={@state.include_memories}
          module={MythweaverWeb.MultiSelect}
          id="memory-topical-memories"
          name="memory_topical[sources][]"
          label={
            dpgettext("memory", "field label: memories used as topical clip sources", "Memories")
          }
          options={
            Enum.map(
              @state.sources,
              &{topical_source_label(&1, MapSet.member?(@state.covered, &1.id)), &1.id}
            )
          }
          selected={MapSet.to_list(@state.selected)}
          empty={
            dpgettext(
              "memory",
              "empty state: lore book has no memories to pick",
              "No memories in this book yet"
            )
          }
        />
      </section>
      <section class="memory-section">
        <.input
          field={@state.form[:include_messages]}
          type="checkbox"
          label={
            dpgettext(
              "memory",
              "toggle: use chat messages as topical clip sources",
              "Include chat messages"
            )
          }
          id="memory-topical-include-messages"
        />
        <.input
          :if={@state.include_messages}
          field={@state.form[:message_mode]}
          type="select"
          label={
            dpgettext(
              "memory",
              "field label: how chat messages are chosen for a topical clip",
              "Messages"
            )
          }
          options={[
            {dpgettext("memory", "option: chat messages chosen as a range", "A range"), "range"},
            {dpgettext("memory", "option: chat messages chosen one by one", "Picked messages"),
             "pick"}
          ]}
          id="memory-topical-message-mode"
        />
        <div :if={@state.include_messages and @state.message_mode == "range"} class="memory-row">
          <.input
            field={@state.form[:start]}
            type="number"
            min="1"
            label={dpgettext("memory", "field label: first message number of a range", "From #")}
            id="memory-topical-start"
          />
          <.input
            field={@state.form[:end]}
            type="number"
            min="1"
            label={dpgettext("memory", "field label: last message number of a range", "To #")}
            id="memory-topical-end"
          />
        </div>
        <p :if={@state.include_messages and @state.message_mode == "pick"} id="memory-topical-picked">
          {picked_summary(@state.picked)}
        </p>
      </section>
      <p :if={@state.error} id="memory-topical-error" class="memory-error">{@state.error}</p>
      <div class="memory-actions">
        <.button type="submit" id="memory-topical-run" variant="primary">
          <.lucide name="scissors" />
          {if @state.target,
            do: dpgettext("memory", "button: update the picked topical clip", "Update clip"),
            else: dpgettext("memory", "button: create a new topical clip", "Create clip")}
        </.button>
      </div>
    </.form>
    <section
      :if={@state.include_messages and @state.message_mode == "pick"}
      id="memory-picker"
      class="memory-section"
    >
      <.form
        for={
          to_form(
            %{"query" => @state.picker.query, "hidden_only" => to_string(@state.picker.hidden_only)},
            as: :memory_picker
          )
        }
        id="memory-picker-form"
        class="memory-row"
        phx-change="memory_picker_search"
        phx-submit="memory_picker_search"
      >
        <.input
          name="memory_picker[query]"
          value={@state.picker.query}
          type="search"
          label={dpgettext("memory", "field label: search chat messages to pick", "Search messages")}
          id="memory-picker-query"
          phx-debounce="300"
        />
        <.input
          name="memory_picker[hidden_only]"
          value={to_string(@state.picker.hidden_only)}
          checked={@state.picker.hidden_only}
          type="checkbox"
          label={
            dpgettext(
              "memory",
              "toggle: list only messages hidden from the AI",
              "Hidden messages only"
            )
          }
          id="memory-picker-hidden-only"
        />
      </.form>
      <ul
        id="memory-picker-results"
        class="memory-picker-results"
        phx-hook="RangeSelect"
        data-range-event="memory_picker_select_range"
      >
        <li :for={message <- @state.picker.results} id={"memory-picker-result-#{message.id}"}>
          <label class="memory-picker-row">
            <input
              type="checkbox"
              id={"memory-picker-toggle-#{message.id}"}
              checked={Map.has_key?(@state.picked, message.id)}
              phx-click="memory_picker_toggle"
              phx-value-id={message.id}
              data-range-id={message.id}
            />
            <strong>#{Format.number(message.position + 1)} {Scene.author(message)}</strong>
            <span :if={not message.visible_to_ai} class="memory-badge">
              {dpgettext("memory", "badge: message hidden from the AI", "Hidden")}
            </span>
          </label>
          <p class="memory-picker-excerpt">{String.slice(Scene.content(message), 0, 160)}</p>
          <details>
            <summary>
              {dpgettext("memory", "button: show a message's full text", "Full text")}
            </summary>
            <p class="memory-picker-full">{Scene.content(message)}</p>
          </details>
        </li>
      </ul>
      <div class="memory-actions">
        <.button
          :if={@state.picker.more?}
          type="button"
          size="sm"
          id="memory-picker-more"
          phx-click="memory_picker_more"
        >
          {dpgettext("memory", "button: load more search results", "More")}
        </.button>
        <.button
          type="button"
          size="sm"
          id="memory-picker-select-loaded"
          phx-click="memory_picker_select_loaded"
        >
          {dpgettext("memory", "button: pick every listed message", "Pick all shown")}
        </.button>
        <.button type="button" size="sm" id="memory-picker-clear" phx-click="memory_picker_clear">
          {dpgettext("memory", "button: unpick every message", "Clear picks")}
        </.button>
      </div>
    </section>
    <.form
      for={@state.combine_form}
      id="memory-combine-form"
      class="memory-form memory-section"
      phx-submit="memory_combine_run"
      phx-hook="RangeSelect"
    >
      <h3>{dpgettext("memory", "heading: merge several topical clips into one", "Combine clips")}</h3>
      <p :if={@state.clips == []} class="memory-empty">
        {dpgettext(
          "memory",
          "empty state: lore book has no topical clips",
          "No topical clips in this book yet"
        )}
      </p>
      <label :for={{record, enabled?} <- @state.clips} class="memory-picker-row">
        <input
          type="checkbox"
          name="memory_combine[record_ids][]"
          value={record.id}
          id={"memory-combine-source-#{record.id}"}
          data-range-id={record.id}
          checked={record.id in (@state.combine_form.params["record_ids"] || [])}
        />
        {if enabled?,
          do: record.entry.name,
          else:
            dpgettext(
              "memory",
              "option: topical clip that is turned off",
              "%{clip_name} (off)",
              clip_name: record.entry.name
            )}
      </label>
      <.input
        field={@state.combine_form[:title]}
        type="text"
        label={dpgettext("memory", "field label: title of the combined clip", "Title")}
        id="memory-combine-title"
      />
      <.input
        field={@state.combine_form[:disable_originals]}
        type="checkbox"
        label={
          dpgettext(
            "memory",
            "toggle: disable the clips that were combined",
            "Disable the original clips after saving"
          )
        }
        id="memory-combine-disable"
      />
      <p :if={@state.combine_error} id="memory-combine-error" class="memory-error">
        {@state.combine_error}
      </p>
      <div class="memory-actions">
        <.button type="submit" id="memory-combine-run" variant="primary">
          <.lucide name="combine" />
          {dpgettext("memory", "button: combine the picked topical clips", "Combine")}
        </.button>
      </div>
    </.form>
    """
  end

  attr :panel, :map, required: true

  defp side_tab(assigns) do
    assigns = assign(assigns, side: assigns.panel.side)

    ~H"""
    <section id="memory-side" class="memory-section">
      <div class="memory-actions">
        <.button size="sm" id="memory-side-manage" navigate={~p"/memory/side-prompts"}>
          <.lucide name="settings" />
          {dpgettext("memory", "button: open the side prompt list", "Manage side prompts")}
        </.button>
        <.button size="sm" id="memory-side-manage-sets" navigate={~p"/memory/side-prompt-sets"}>
          <.lucide name="list-ordered" />
          {dpgettext("memory", "button: open the side prompt set list", "Manage sets")}
        </.button>
      </div>
      <p :if={@side.set == :missing} id="memory-side-set-missing" class="memory-error">
        {dgettext(
          "memory",
          "This chat's side prompt set is gone, so no side prompts run automatically. Pick another in Settings."
        )}
      </p>
      <div :if={match?(%{rows: _}, @side.set)} id="memory-side-set" class="memory-form memory-card">
        <div class="memory-entry">
          <span class="memory-entry-title">
            {dpgettext(
              "memory",
              "heading: side prompt set the chat runs",
              "Set: %{set_name}",
              set_name: @side.set.name
            )}
          </span>
          <span class="memory-entry-meta">
            {dgettext("memory", "Runs after memories and on intervals in this chat")}
          </span>
        </div>
        <p :if={@side.set.rows == []} class="memory-empty">
          {dpgettext("memory", "empty state: side prompt set has no rows", "This set has no rows.")}
        </p>
        <div :for={row <- @side.set.rows} class="memory-entry" id={"memory-side-set-row-#{row.id}"}>
          <span class="memory-entry-title">{row_name(row)}</span>
          <span class="memory-entry-meta">{row.side_prompt.name}</span>
          <.button
            size="sm"
            id={"memory-side-run-row-#{row.id}"}
            phx-click="memory_side_run_row"
            phx-value-id={row.id}
          >
            <.lucide name="play" /> {dpgettext(
              "memory",
              "button: run one row of a side prompt set",
              "Run"
            )}
          </.button>
        </div>
        <p :if={@side.set_error} id="memory-side-set-error" class="memory-error">{@side.set_error}</p>
        <div class="memory-actions">
          <.button
            :if={@side.set.rows != []}
            id="memory-side-run-set"
            variant="primary"
            phx-click="memory_side_run_set"
          >
            <.lucide name="play" />
            {dpgettext("memory", "button: run every row of a side prompt set", "Run every row")}
          </.button>
        </div>
      </div>
      <p :if={@side.side_prompts == []} id="memory-side-empty" class="memory-empty">
        {dpgettext("memory", "empty state: user has no side prompts", "No side prompts yet")}
      </p>
      <.form
        :for={side_prompt <- @side.side_prompts}
        for={%{}}
        as={:memory_side}
        id={"memory-side-#{side_prompt.id}"}
        class="memory-form memory-card"
        phx-submit="memory_side_run"
      >
        <input type="hidden" name="memory_side[id]" value={side_prompt.id} />
        <div class="memory-entry">
          <.button
            size="sm"
            id={"memory-side-toggle-#{side_prompt.id}"}
            phx-click="memory_side_toggle"
            phx-value-id={side_prompt.id}
            aria-pressed={to_string(side_prompt.enabled)}
            title={
              dpgettext(
                "memory",
                "tooltip: on/off switch of a side prompt",
                "Turns this side prompt on or off in every chat"
              )
            }
          >
            <.lucide name="power" />
            {if side_prompt.enabled,
              do: dpgettext("memory", "toggle: side prompt is on", "On"),
              else: dpgettext("memory", "toggle: side prompt is off", "Off")}
          </.button>
          <span class="memory-entry-title">{side_prompt.name}</span>
          <span class="memory-entry-meta">{side_triggers(side_prompt)}</span>
          <span id={"memory-side-checkpoint-#{side_prompt.id}"} class="memory-entry-meta">
            {case @side.checkpoints[side_prompt.id] do
              nil ->
                dpgettext(
                  "memory",
                  "status: side prompt has not run in this chat",
                  "Not run in this chat yet"
                )

              position ->
                dpgettext(
                  "memory",
                  "status: last message a side prompt has run through",
                  "Run through #%{message_number}",
                  message_number: Format.number(position + 1)
                )
            end}
          </span>
        </div>
        <div :if={side_prompt.macros != []} class="memory-row">
          <.input
            :for={name <- side_prompt.macros}
            type="text"
            name={"memory_side[macros][#{name}]"}
            value=""
            label={"{{ #{name} }}"}
            id={"memory-side-macro-#{side_prompt.id}-#{name}"}
          />
        </div>
        <div class="memory-row">
          <.input
            type="number"
            name="memory_side[start]"
            value={get_in(@side.prefill, [side_prompt.id, :start]) || ""}
            min="1"
            label={dpgettext("memory", "field label: first message number of a range", "From #")}
            placeholder={
              dpgettext(
                "memory",
                "placeholder: side prompt range starts after its last run",
                "After the last run"
              )
            }
            id={"memory-side-start-#{side_prompt.id}"}
          />
          <.input
            type="number"
            name="memory_side[end]"
            value={get_in(@side.prefill, [side_prompt.id, :end]) || ""}
            min="1"
            label={dpgettext("memory", "field label: last message number of a range", "To #")}
            placeholder={
              dpgettext(
                "memory",
                "placeholder: side prompt range ends at the latest message",
                "Latest"
              )
            }
            id={"memory-side-end-#{side_prompt.id}"}
          />
          <.button type="submit" id={"memory-side-run-#{side_prompt.id}"} variant="primary">
            <.lucide name="play" /> {dpgettext("memory", "button: run a side prompt now", "Run")}
          </.button>
        </div>
        <p
          :if={@side.errors[side_prompt.id]}
          id={"memory-side-error-#{side_prompt.id}"}
          class="memory-error"
        >
          {@side.errors[side_prompt.id]}
        </p>
      </.form>
    </section>
    """
  end

  defp row_name(row) do
    case String.trim(row.label || "") do
      "" -> row.side_prompt.name
      label -> label
    end
  end

  defp side_triggers(%{run_after_memory: true, run_on_interval: true, interval: interval}) do
    dpngettext(
      "memory",
      "status: when a side prompt runs automatically",
      "After each memory · Every %{message_count} message",
      "After each memory · Every %{message_count} messages",
      interval,
      message_count: Format.number(interval)
    )
  end

  defp side_triggers(%{run_after_memory: true}),
    do: dpgettext("memory", "status: when a side prompt runs automatically", "After each memory")

  defp side_triggers(%{run_on_interval: true, interval: interval}) do
    dpngettext(
      "memory",
      "status: when a side prompt runs automatically",
      "Every %{message_count} message",
      "Every %{message_count} messages",
      interval,
      message_count: Format.number(interval)
    )
  end

  defp side_triggers(_side_prompt),
    do: dpgettext("memory", "status: side prompt never runs automatically", "Manual only")

  defp picked_summary(picked) when map_size(picked) == 0,
    do:
      dpngettext(
        "memory",
        "status: how many chat messages are picked for a topical memory",
        "%{message_count} message picked",
        "%{message_count} messages picked",
        0, message_count: Format.number(0))

  defp picked_summary(picked) do
    count = map_size(picked)
    numbers = picked |> Map.values() |> Enum.sort() |> Enum.map_join(", ", &"##{Format.number(&1)}")

    gettext_comment("%{message_numbers} is a comma-separated list of message numbers such as #3, #7.")

    dpngettext(
      "memory",
      "status: how many chat messages are picked for a topical memory, and which",
      "%{message_count} message picked: %{message_numbers}",
      "%{message_count} messages picked: %{message_numbers}",
      count,
      message_count: Format.number(count),
      message_numbers: numbers
    )
  end

  defp topical_source_label(record, true) do
    gettext_comment("%{tier_name} is a memory tier name such as Memory, Arc or Chapter.")

    dpgettext(
      "memory",
      "option: memory entry offered as a topical clip source, already in the clip",
      "%{tier_name}: %{entry_label} (already in this clip)",
      tier_name: Tiers.label(record.tier),
      entry_label: source_label(record)
    )
  end

  defp topical_source_label(record, false) do
    gettext_comment("%{tier_name} is a memory tier name such as Memory, Arc or Chapter.")

    dpgettext(
      "memory",
      "option: memory entry offered as a topical clip source",
      "%{tier_name}: %{entry_label}",
      tier_name: Tiers.label(record.tier),
      entry_label: source_label(record)
    )
  end

  defp source_label(%{range_start: nil, entry: entry}), do: entry.name

  defp source_label(%{entry: entry} = record) do
    dpgettext(
      "memory",
      "option: memory entry name with the message range it covers",
      "%{entry_name} (#%{first_message_number}–#%{last_message_number})",
      entry_name: entry.name,
      first_message_number: Format.number(record.range_start + 1),
      last_message_number: Format.number(record.range_end + 1)
    )
  end

  defp group_name(%{kind: kind, tier: tier}) when kind in [:memory, :consolidation], do: Tiers.label(tier)
  defp group_name(%{kind: :clip}), do: dpgettext("memory", "heading: group of clip entries", "Clips")

  defp group_name(%{kind: :topical_clip}),
    do: dpgettext("memory", "heading: group of topical clip entries", "Topical clips")

  defp group_name(%{kind: :side_prompt}),
    do: dpgettext("memory", "heading: group of side prompt entries", "Side prompts")

  defp token_count(tokens) do
    dpngettext(
      "memory",
      "unit: token count of a text",
      "%{token_count} token",
      "%{token_count} tokens",
      tokens,
      token_count: Format.number(tokens)
    )
  end

  defp dismiss_topic_confirm(topic) do
    gettext_comment("Confirm dialog before dismissing a topic the model suggested for a topical clip.")
    dgettext("memory", "Dismiss the suggested topic “%{topic_name}”?", topic_name: topic)
  end

  defp ready_to_consolidate(tiers) do
    gettext_comment("%{tier_names} is a list of memory tier names such as Arc and Chapter.")

    dpgettext(
      "memory",
      "status: memory tiers that have enough entries to consolidate",
      "Ready to consolidate: %{tier_names}",
      tier_names: tiers |> Enum.map(&Tiers.label/1) |> Format.list()
    )
  end

  defp consolidate_into_option(1),
    do: dpgettext("memory", "option: memory tier to consolidate into", "Arc (from memories)")

  defp consolidate_into_option(2),
    do: dpgettext("memory", "option: memory tier to consolidate into", "Chapter (from arcs)")

  defp consolidate_into_option(3),
    do: dpgettext("memory", "option: memory tier to consolidate into", "Book (from chapters)")

  defp consolidate_into_option(4),
    do: dpgettext("memory", "option: memory tier to consolidate into", "Legend (from books)")

  defp consolidate_into_option(5),
    do: dpgettext("memory", "option: memory tier to consolidate into", "Series (from legends)")

  defp consolidate_into_option(6),
    do: dpgettext("memory", "option: memory tier to consolidate into", "Epic (from series)")

  defp nothing_to_consolidate(1),
    do:
      dpgettext("memory", "empty state: no entries to consolidate into the tier", "Nothing to consolidate into Arc yet")

  defp nothing_to_consolidate(2),
    do:
      dpgettext(
        "memory",
        "empty state: no entries to consolidate into the tier",
        "Nothing to consolidate into Chapter yet"
      )

  defp nothing_to_consolidate(3),
    do:
      dpgettext(
        "memory",
        "empty state: no entries to consolidate into the tier",
        "Nothing to consolidate into Book yet"
      )

  defp nothing_to_consolidate(4),
    do:
      dpgettext(
        "memory",
        "empty state: no entries to consolidate into the tier",
        "Nothing to consolidate into Legend yet"
      )

  defp nothing_to_consolidate(5),
    do:
      dpgettext(
        "memory",
        "empty state: no entries to consolidate into the tier",
        "Nothing to consolidate into Series yet"
      )

  defp nothing_to_consolidate(6),
    do:
      dpgettext(
        "memory",
        "empty state: no entries to consolidate into the tier",
        "Nothing to consolidate into Epic yet"
      )
end
