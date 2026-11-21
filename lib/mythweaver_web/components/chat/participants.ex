defmodule MythweaverWeb.Chat.Participants do
  @moduledoc """
  The participants roster: the characters in the selected chat, marking which one the player
  controls.

  Each row is a rich control: drag handle, avatar, name, `You` marker, queue position, and a
  right-aligned icon-button toolbar (queue a reply / stop, mute, take or release, play-as, per-chat
  settings, remove, edit the character).
  Rows are dragged by their `<.drag_handle>` to set the chat's speaking order (the shared
  `SortableList` hook, `assets/js/hooks/sortable_list.ts`, which pushes the full DOM order as
  `reorder_participants`).

  The header carries mute-all, hide-muted and search toggles and the add-characters button.
  Mute-all acts on the bots the search keeps (`mute_targets/2`: the bots not in `filtered_out`),
  ignoring hide-muted, which hides exactly the rows an unmute targets.
  Hide-muted is per-browser view state: the `.HideMuted` hook keeps it in `localStorage` and
  restores it when the view connects (and reconnects). The search (`participant-filter`, opened by
  `"toggle_participant_search"`, posting `"filter_participants"`) narrows the rows by character
  name and by the characters' tags, as the lists' tag filters do; the caller passes the ids it
  rules out as `filtered_out`. Both use the `hidden` attribute rather than filtering the rows, so
  the dragged DOM order stays a full permutation that `Chats.reorder_participants/2` accepts, and a
  row shows only when neither hides it.

  In a shared chat a row whose character is held shows a players icon whose popover lists everyone
  holding it (`Chats.locks/1`), on hover or tap, so many players never crowd the name;
  with free switching the viewer takes any character, alongside whoever else plays it
  (`"take_character"`), and lets go of their own one at a time (`"release_character"`). Play-as
  (`"play_as"`) is the one "who I play" control: on a held character it picks who this tab posts
  as (for the owner also the chat's player character); holding none, a manager picks the chat's
  player character. Controls follow `access` (`MythweaverWeb.Chat.Access`): a guest sees no
  reorder, mute, per-chat settings, remove or edit, and play-as only on characters they hold, and,
  while the chat lets guests bring characters, the add button is "Bring a character" over their
  own characters.

  Lives in the `grid-area: participants` rail (`.chat-rail` in `main_chat_live.ex`), which owns the
  grid area and scrolls, so this panel is a flex child rather than a grid item.
  """

  use MythweaverWeb, :html

  import MythweaverWeb.Pane, only: [pane_search: 1]
  import MythweaverWeb.TagFilter, only: [tag_filter: 1]

  alias Mythweaver.Accounts.User
  alias Mythweaver.Chats.Chat
  alias MythweaverWeb.Chat.Access

  attr :chat, :any, default: nil
  attr :character_options, :list, default: [], doc: "{name, id} pairs for every character"
  attr :adding_participant?, :boolean, default: false, doc: "true renders the open add modal"
  attr :adding_ids, :list, default: [], doc: "character ids checked in the open add modal"
  attr :viewer_id, :string, default: nil, doc: "`current_scope.user.id`, for the add modal's tag filter"
  attr :tag_graph, :any, default: nil, doc: "the viewer's `Mythweaver.Tags.Graph`"
  attr :access, Access, default: %Access{}, doc: "what the viewer may do here"
  attr :locks, :map, default: %{}, doc: "`Chats.locks/1`: character id => holders (`[User]`)"
  attr :my_locks, :list, default: [], doc: "character ids the viewer holds, speaking order"
  attr :poster_id, :any, default: nil, doc: "the character the viewer posts as (marked You)"

  attr :turn_state, :map,
    default: %{speaking: nil, queue: [], auto?: false, paused?: false},
    doc: "`Mythweaver.Generation.status/1`: who speaks, who is queued, whether auto mode is on"

  attr :editing_participant, :any, default: nil, doc: "participant whose settings modal is open"
  attr :model_options, :list, default: [], doc: "{name, id} pairs for every AI model"

  attr :participant_outfit_options, :list,
    default: [],
    doc: "{name, id} pairs of the open participant's character's outfits (expression sets)"

  attr :default_model_id, :any,
    default: nil,
    doc: "`AI.default_model/1`'s id; a row shows its model only when it differs from the fallback"

  attr :hide_muted?, :boolean, default: false, doc: "true hides muted rows (stored per browser)"
  attr :guided?, :boolean, default: false, doc: "composer text will guide a sparkle click"
  attr :search?, :boolean, default: false, doc: "the name and tag filter is open"

  attr :filter, :map,
    default: nil,
    doc: "the filter's state: `form` (its `query`), the tag chips' `values`, `errors` and `invalid`"

  attr :filtered_out, :any, default: MapSet.new(), doc: "a MapSet of the participant ids the filter hides"
  attr :tag_vocabulary, :list, default: [], doc: "the tag filter's suggestions"

  def participants(assigns) do
    # Toolbar icons are picked at runtime; the Iconex compiler only sees literals.
    Iconex.hint(:lucide, ~w[square sparkles volume-2 volume-x eye eye-off])

    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      /* The header stays put while the rows scroll, so the root is a column flex container and the
         scrolling sits on `.chat-participants-scroll`. Mirrors `.chat-picker-scroll`. */
      aside:scope {
        flex: 1 1 auto;
        min-height: 0;
        display: flex;
        flex-direction: column;
        border: 1px solid var(--border);
        border-radius: var(--radius-3);
        margin: var(--panel-gap);
        background: var(--card);
        box-shadow: var(--elevation-lg);
      }

      .chat-participants-scroll {
        flex: 1 1 auto;
        min-height: 0;
        overflow-y: auto;
      }

      .chat-participants-list {
        list-style: none;
        margin: 0;
        padding: 0;
      }

      /*
        `auto auto minmax(0, 1fr) auto`: handle, avatar and toolbar size to content, the name column
        absorbs the rest and truncates. A flex row would let a long name shove the toolbar out of the
        panel.
      */
      .chat-participant {
        anchor-scope: --chat-participant-holders;
        display: grid;
        grid-template-columns: auto auto minmax(0, 1fr) auto;
        align-items: center;
        gap: var(--size-2);
        padding: var(--size-2) var(--size-3);
        border-bottom: 1px solid var(--border-grey);
      }

      .chat-participant--muted .chat-participant-main {
        opacity: 0.6;
      }

      .chat-participant:last-child {
        border-bottom: 0;
      }

      /*
        Same picture as `.chat-message-avatar` in messages.ex: the character's avatar image when it
        has one, else `<.avatar_placeholder>`.
      */
      .chat-participant-avatar {
        --dimensions: 2.5rem;
        --avatar-radius: var(--radius-round);
        width: var(--dimensions);
        height: var(--dimensions);
        border-radius: var(--avatar-radius);
      }

      .chat-participant--player .chat-participant-avatar {
        outline: 2px solid var(--ring);
        outline-offset: 2px;
      }

      .chat-participant-main {
        min-width: 0;
      }

      .chat-participant-identity {
        display: flex;
        align-items: center;
        gap: var(--size-1);
      }

      .chat-participant-name {
        overflow: hidden;
        white-space: nowrap;
        text-overflow: ellipsis;
      }

      /* Interest (hover, focus, long press) shows who plays the character; a tap or click opens it
         until dismissed (`interestfor` plus `popovertarget`, as the emotion breakdown does). An
         icon rather than the handles, which crowd the name out once several users share it. */
      .chat-participant-holders-toggle {
        anchor-name: --chat-participant-holders;
        --interest-delay-start: 0.15s;
        --interest-delay-end: 0.2s;
        interest-delay-start: var(--interest-delay-start);
        interest-delay-end: var(--interest-delay-end);
        display: inline-flex;
        flex-shrink: 0;
        padding: 0;
        border: 0;
        background: none;
        color: var(--muted-foreground);
        font: inherit;
        font-size: 0.9rem;
        cursor: help;
      }

      .chat-participant-holders-toggle:hover,
      .chat-participant-holders-toggle:focus-visible {
        color: var(--foreground);
      }

      .chat-participant-holders-toggle:focus-visible {
        outline: 2px solid var(--ring);
        outline-offset: 2px;
        border-radius: var(--radius-1);
      }

      /* In the top layer, so the rail's scroller and the phone drawer do not clip it. Without
         anchor positioning the UA centers it, which still reads fine. */
      .chat-participant-holders {
        margin: var(--size-1);
        inline-size: max-content;
        max-inline-size: min(20rem, calc(100vw - 2 * var(--size-2)));
        padding: var(--size-2) var(--size-3);
        border: 1px solid var(--border);
        border-radius: var(--radius-2);
        background: var(--surface-8);
        color: var(--foreground);
        box-shadow: var(--elevation-md);
        font-size: 0.8rem;
        line-height: 1.4;
      }

      @supports (anchor-name: --a) {
        .chat-participant-holders {
          inset: auto;
          position-anchor: --chat-participant-holders;
          position-area: block-end span-inline-end;
          position-try-fallbacks:
            flip-block,
            flip-inline,
            flip-block flip-inline;
        }
      }

      .chat-participant-holders-title {
        margin: 0 0 var(--size-1);
        color: var(--muted-foreground);
      }

      .chat-participant-holders-list {
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
        margin: 0;
        padding: 0;
        list-style: none;
      }

      .chat-participant-holders-list li {
        padding: 0;
      }

      .chat-participant-holders-handle {
        color: var(--muted-foreground);
      }

      .chat-participant-meta {
        margin: 0;
        color: var(--muted-foreground);
        font-size: 0.8rem;
      }

      /*
        `flex-wrap` so the toolbar's buttons wrap to a second line inside the row instead of
        overflowing the rail.
      */
      .chat-participant-actions {
        display: flex;
        flex-wrap: wrap;
        justify-content: flex-end;
        align-items: center;
        gap: var(--size-1);
      }

      /* Coarse pointers: six 44px actions fill the drawer, which left the name column no width, so
         the name vanished and the badges spilled over the buttons. The actions take their own line
         under the name instead, starting below the avatar. */
      @media (--coarse) {
        .chat-participant {
          grid-template-columns: auto auto minmax(0, 1fr);
          row-gap: 0;
        }

        .chat-participant-actions {
          grid-column: 2 / -1;
          justify-content: flex-start;
        }

        /* The player list opens by tap here, so its icon gets a full touch target. */
        .chat-participant-holders-toggle {
          align-items: center;
          justify-content: center;
          min-inline-size: var(--touch-target);
          min-block-size: var(--touch-target);
          font-size: 1rem;
        }
      }

      /* Transparent secondary variant, matching `.chat-message-swipe` in messages.ex. */
      .chat-participant-action {
        padding: var(--size-1);
        border: 0;
        border-radius: var(--radius-2);
        background: none;
        color: var(--muted-foreground);
        font: inherit;
        line-height: 0;
        cursor: pointer;
      }

      .chat-participant-action:hover:not(:disabled) {
        color: var(--foreground);
        background: var(--surface-5);
      }

      /* Destructive hover, so the remove button reads differently from its inert siblings. Ordered
         after the generic hover rule, which it overrides at equal specificity. */
      .chat-participant-action--danger:hover:not(:disabled) {
        color: var(--destructive-foreground);
        background: var(--destructive);
      }

      /* The composer holds a guide this sparkle will follow; kept on hover, like `--danger`. */
      .chat-participant-action--guided,
      .chat-participant-action--guided:hover:not(:disabled) {
        color: var(--guide);
      }

      .chat-participant-action:disabled {
        opacity: 0.4;
        cursor: default;
      }

      /*
        The active player's play-as button is disabled (clicking it is a no-op) but reads as "on"
        rather than "unavailable": full opacity, tinted `--primary-accent`. Keyed on `aria-pressed`, not on
        the row class, so genuinely-inert siblings in the same row stay dimmed.
      */
      .chat-participant-action[aria-pressed="true"]:disabled {
        opacity: 1;
        color: var(--primary-accent);
      }

      /* A root tag of `panel_header`'s `:actions` slot, so it is itself a scope root: `:scope`. */
      div.chat-participants-tools:scope {
        display: flex;
        gap: var(--size-1);
      }

      div.chat-participants-tools:scope
        .chat-participant-action[aria-pressed="true"] {
        color: var(--primary-accent);
      }

      /* `.chat-participant { display: grid }` outranks the UA `[hidden] { display: none }`. */
      .chat-participant[hidden] {
        display: none;
      }

      .chat-participants-no-match {
        margin: 0;
        padding: var(--size-2) var(--size-3);
        color: var(--muted-foreground);
      }
    </style>

    <%!--
      A second block, `lower-bound="none"`: the form is rendered through `<.modal>`'s slot and
      `<.input>`'s internals, the edit-character `<.link>` renders an `<a>` and `<.avatar_image>`
      the avatar's `<img>`. All are component roots carrying `phx-r` that the block above's bound cuts
      off. With no lower bound this block's marker also lands on the `<aside>`, so every rule here
      is scoped to a descendant class, never to the root.
    --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      /* A drawer here: its drawer toggle, not the hide button, puts it away. */
      @media (--phone) {
        .button.rail-collapse {
          display: none;
        }
      }

      /* `<.avatar_image>`'s `<img>`, a component root the first block's bound stops at. */
      .chat-participant-avatar img {
        inline-size: 100%;
        block-size: 100%;
        object-fit: cover;
        border-radius: inherit;
      }

      /* `.chat-participant-action` for the `<a>`: the first block's rules stop at its `phx-r`, so
         without this it would take the reset's link color and no padding. */
      a.chat-participant-action {
        display: inline-block;
        padding: var(--size-1);
        border-radius: var(--radius-2);
        color: var(--muted-foreground);
        line-height: 0;
      }

      a.chat-participant-action:hover {
        color: var(--foreground);
        background: var(--surface-5);
      }

      /* `:is(button, a)` matches `a.chat-participant-action`'s specificity, which would otherwise
         keep the edit-character link `inline-block` and off-centre. */
      @media (--coarse) {
        :is(button, a).chat-participant-action {
          display: inline-flex;
          align-items: center;
          justify-content: center;
          min-inline-size: var(--touch-target);
          min-block-size: var(--touch-target);
        }
      }

      .add-participant-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .add-participant-form label {
        display: block;
      }
    </style>

    <aside
      id="chat-participants"
      class="chat-participants drawer drawer--end drawer--phone"
      popover
      data-drawer-swipe
      aria-label={dpgettext("chat", "aria label: drawer listing a chat's characters", "Participants")}
      phx-hook=".HideMuted"
      data-hide-muted={to_string(@hide_muted?)}
    >
      <.panel_header>
        {dpgettext("chat", "heading: list of a chat's characters", "Participants")}
        <:actions :if={@chat != nil}>
          <div
            class="chat-participants-tools"
            role="group"
            aria-label={
              dpgettext(
                "chat",
                "aria label: toolbar over the chat's character list",
                "Participant tools"
              )
            }
          >
            <button
              :if={@chat.participants != [] and @access.manage?}
              type="button"
              class="chat-participant-action"
              id="mute-all-participants"
              phx-click="toggle_mute_all"
              disabled={mute_targets(@chat, @filtered_out) == []}
              aria-pressed={to_string(all_muted?(@chat, @filtered_out))}
              aria-label={
                mute_all_label(all_muted?(@chat, @filtered_out), MapSet.size(@filtered_out) > 0)
              }
            >
              <.lucide name={if all_muted?(@chat, @filtered_out), do: "volume-x", else: "volume-2"} />
            </button>
            <button
              :if={@chat.participants != []}
              type="button"
              class="chat-participant-action"
              id="hide-muted-participants"
              phx-click="toggle_hide_muted"
              aria-pressed={to_string(@hide_muted?)}
              aria-label={
                if @hide_muted?,
                  do:
                    dpgettext(
                      "chat",
                      "aria label: show muted characters in the list",
                      "Show muted characters"
                    ),
                  else:
                    dpgettext(
                      "chat",
                      "aria label: hide muted characters from the list",
                      "Hide muted characters"
                    )
              }
            >
              <.lucide name={if @hide_muted?, do: "eye-off", else: "eye"} />
            </button>
            <button
              :if={@chat.participants != []}
              type="button"
              class="chat-participant-action"
              id="participant-search-toggle"
              phx-click="toggle_participant_search"
              aria-pressed={to_string(@search?)}
              aria-controls="participant-filter"
              aria-label={
                if @search?,
                  do:
                    dpgettext(
                      "chat",
                      "aria label: close the participant search",
                      "Close participant search"
                    ),
                  else:
                    dpgettext(
                      "chat",
                      "aria label: open the participant search",
                      "Search participants"
                    )
              }
              title={
                if @search?,
                  do: dpgettext("chat", "tooltip: close the participant search", "Close search"),
                  else:
                    dpgettext(
                      "chat",
                      "tooltip: open the participant search",
                      "Search participants by name or tag"
                    )
              }
            >
              <.lucide name="search" />
            </button>
            <%!-- Disabled, not hidden, when every character is already in: it explains itself. --%>
            <.button
              :if={@access.manage?}
              icon
              size="sm"
              id="add-participant"
              phx-click="open_add_participant"
              disabled={available_options(@chat, @character_options) == []}
              aria-label={
                dpgettext("chat", "aria label: add characters to the chat", "Add characters")
              }
              title={dpgettext("chat", "tooltip: add characters to the chat", "Add characters")}
            >
              <.lucide name="user-plus" />
            </.button>
            <.button
              :if={@access.role == :guest and @chat.guests_bring_characters}
              icon
              size="sm"
              id="bring-character"
              phx-click="open_add_participant"
              aria-label={
                dpgettext(
                  "chat",
                  "aria label: guest brings own character into the chat",
                  "Bring a character"
                )
              }
              title={
                dpgettext(
                  "chat",
                  "tooltip: guest brings own character into the chat",
                  "Bring a character of your own"
                )
              }
            >
              <.lucide name="user-plus" />
            </.button>
            <%!-- Handled by `.RailCollapse` on `#chat-layout`, client-side only. --%>
            <.button
              icon
              size="sm"
              id="chat-participants-collapse"
              class="rail-collapse"
              data-rail-collapse="participants"
              aria-controls="chat-participants"
              aria-label={
                dpgettext("chat", "aria label: collapse the participants rail", "Hide participants")
              }
              title={
                dpgettext("chat", "tooltip: collapse the participants rail", "Hide participants")
              }
            >
              <.lucide name="panel-right-close" />
            </.button>
          </div>
        </:actions>
      </.panel_header>

      <div class="chat-participants-scroll">
        <%!-- `phx-mounted`: opening the search puts the cursor in its name box. --%>
        <div
          :if={@search? && @filter && @chat != nil && @chat.participants != []}
          id="participant-search"
          phx-mounted={JS.focus(to: "#participant-filter-query")}
        >
          <.pane_search
            id="participant-filter"
            form={@filter.form}
            event="filter_participants"
            placeholder={
              dpgettext(
                "chat",
                "placeholder: search participants by character name",
                "Character name"
              )
            }
          >
            <.tag_filter
              id="participant-filter-tags"
              values={@filter.values}
              vocabulary={@tag_vocabulary}
              errors={@filter.errors}
              invalid={@filter.invalid}
            />
          </.pane_search>
        </div>

        <p :if={@chat == nil || @chat.participants == []} class="chat-participants-empty">
          {dpgettext("chat", "empty state: chat has no participants", "No participants")}
        </p>

        <p
          :if={@chat != nil && filtered_empty?(@chat, @hide_muted?, @filtered_out)}
          id="participants-no-match"
          class="chat-participants-no-match"
        >
          {dpgettext(
            "chat",
            "empty state: no participant matches the search",
            "No participants match"
          )}
        </p>

        <%!-- Every slot of a participant's radial menu, so a row shows the actions it lacks
           dimmed. Keep in step with the `data-radial-slot`s on the row's controls. --%>
        <.radial_layout :if={@chat != nil} id="participant-radial-layout">
          <:item
            index={0}
            label={dpgettext("chat", "menu item: queue a reply from this character", "Queue a reply")}
          >
            <.lucide name="sparkles" />
          </:item>
          <:item
            index={1}
            label={dpgettext("chat", "menu item: post as this character", "Play as this character")}
          >
            <.lucide name="user-round" />
          </:item>
          <:item index={2} label={dgettext("chat", "Take this character (free switching)")}>
            <.lucide name="user-round-plus" />
          </:item>
          <:item
            index={3}
            label={
              dpgettext(
                "chat",
                "menu item: this character's per-chat settings",
                "Settings in this chat"
              )
            }
          >
            <.lucide name="link" />
          </:item>
          <:item
            index={4}
            label={
              dpgettext(
                "chat",
                "menu item: remove this character from the chat",
                "Remove from this chat"
              )
            }
          >
            <.lucide name="badge-x" />
          </:item>
          <:item
            index={5}
            label={
              dpgettext(
                "chat",
                "menu item: mute this character in automatic replies",
                "Mute in automatic replies"
              )
            }
          >
            <.lucide name="volume-2" />
          </:item>
          <:item
            index={7}
            label={dpgettext("chat", "menu item: edit this character", "Edit character")}
          >
            <.lucide name="user-round-pen" />
          </:item>
        </.radial_layout>

        <ul
          :if={@chat != nil && @chat.participants != []}
          class="chat-participants-list"
          id="participants-list"
          phx-hook={@access.manage? && "SortableList"}
          data-sortable-event="reorder_participants"
        >
          <li
            :for={participant <- @chat.participants}
            class={[
              "chat-participant",
              participant.character_id == @poster_id && "chat-participant--player",
              participant.muted && "chat-participant--muted"
            ]}
            id={"participant-#{participant.id}"}
            data-id={participant.id}
            data-radial-menu={participant.character.name}
            data-radial-layout="participant-radial-layout"
            hidden={
              (@hide_muted? && participant.muted) || MapSet.member?(@filtered_out, participant.id)
            }
          >
            <.drag_handle :if={@access.manage?} />
            <div class="chat-participant-avatar" aria-hidden="true">
              <.avatar_image avatar={participant.character} preset={:avatar} sizes="40px" />
            </div>

            <div class="chat-participant-main">
              <div class="chat-participant-identity">
                <span class="chat-participant-name">{participant.character.name}</span>
                <.badge :if={participant.character_id == @poster_id}>
                  {dpgettext("chat", "badge: the character this viewer posts as", "You")}
                </.badge>
                <%= if holders = @locks[participant.character_id] do %>
                  <button
                    type="button"
                    class="chat-participant-holders-toggle"
                    id={"participant-holders-#{participant.id}-toggle"}
                    interestfor={"participant-holders-#{participant.id}"}
                    popovertarget={"participant-holders-#{participant.id}"}
                    popovertargetaction="show"
                    aria-label={who_plays(participant)}
                  >
                    <.lucide name="users" />
                  </button>
                  <div
                    id={"participant-holders-#{participant.id}"}
                    class="chat-participant-holders"
                    popover="auto"
                    aria-label={who_plays(participant)}
                  >
                    <p class="chat-participant-holders-title">
                      {dpgettext("chat", "heading: users who play this character", "Played by")}
                    </p>
                    <ul class="chat-participant-holders-list">
                      <li :for={user <- holders}>
                        {User.display_name(user)}
                        <span :if={user.nickname} class="chat-participant-holders-handle">
                          @{user.handle}
                        </span>
                      </li>
                    </ul>
                  </div>
                <% end %>
                <.badge
                  :if={queue_position(@turn_state, participant.character_id)}
                  id={"queue-badge-#{participant.id}"}
                >
                  {dpgettext(
                    "chat",
                    "badge: place of a character in the reply queue",
                    "#%{queue_position}",
                    queue_position:
                      Mythweaver.Format.number(queue_position(@turn_state, participant.character_id))
                  )}
                </.badge>
              </div>
              <p
                :if={model_override(participant, @chat, @default_model_id)}
                class="chat-participant-meta"
                id={"participant-model-#{participant.id}"}
              >
                {model_override(participant, @chat, @default_model_id)}
              </p>
            </div>

            <div
              class="chat-participant-actions"
              role="group"
              aria-label={
                dpgettext(
                  "chat",
                  "aria label: toolbar of one chat character",
                  "Actions for %{character_name}",
                  character_name: participant.character.name
                )
              }
            >
              <%!--
                Every row, player included: the player's lines are usually typed, but this lets the AI
                speak for them. Clicking queues a reply behind whatever is running (manual clicks stack,
                as in AikoBots); only the row currently speaking flips to Stop.
              --%>
              <button
                :if={@access.generate?}
                type="button"
                class={[
                  "chat-participant-action",
                  @guided? && !speaking?(@turn_state, participant) &&
                    "chat-participant-action--guided"
                ]}
                id={"generate-#{participant.id}"}
                data-radial-item
                data-radial-slot="0"
                phx-click={
                  if speaking?(@turn_state, participant),
                    do: "stop_generation",
                    else: "generate_reply"
                }
                phx-value-character_id={participant.character_id}
                aria-label={generate_label(@turn_state, participant, @guided?)}
                title={generate_label(@turn_state, participant, @guided?)}
              >
                <.lucide name={if speaking?(@turn_state, participant), do: "square", else: "sparkles"} />
              </button>

              <%!-- Muting removes the character from automatic turn selection, not from the scene. --%>
              <button
                :if={participant.character_id != @chat.player_character_id and @access.manage?}
                type="button"
                class="chat-participant-action"
                id={"mute-participant-#{participant.id}"}
                data-radial-item
                data-radial-slot="5"
                phx-click="toggle_mute"
                phx-value-id={participant.id}
                aria-pressed={to_string(participant.muted)}
                aria-label={mute_label(participant)}
                title={mute_label(participant)}
              >
                <.lucide name={if participant.muted, do: "volume-x", else: "volume-2"} />
              </button>

              <%!-- Free switching: take any character (shared with its other players), or let go of one of yours. --%>
              <button
                :if={@chat.free_switching and @access.post? and participant.character_id in @my_locks}
                type="button"
                class="chat-participant-action"
                id={"release-character-#{participant.id}"}
                data-radial-item
                data-radial-slot="2"
                phx-click="release_character"
                phx-value-character_id={participant.character_id}
                aria-label={stop_playing(participant)}
                title={stop_playing(participant)}
              >
                <.lucide name="user-round-minus" />
              </button>
              <button
                :if={
                  @chat.free_switching and @access.post? and
                    participant.character_id not in @my_locks
                }
                type="button"
                class="chat-participant-action"
                id={"take-character-#{participant.id}"}
                data-radial-item
                data-radial-slot="2"
                phx-click="take_character"
                phx-value-character_id={participant.character_id}
                aria-label={play(participant)}
                title={play(participant)}
              >
                <.lucide name="user-round-plus" />
              </button>
              <%!--
                Who the viewer plays: on a held character, who this tab posts as (the owner's pick
                also becomes the chat's player character); holding none, a manager picks the chat's
                player character. Pressed on the one in play: the poster, else the player character.
              --%>
              <button
                :if={participant.character_id in @my_locks or (@my_locks == [] and @access.manage?)}
                type="button"
                class="chat-participant-action"
                id={"play-as-#{participant.id}"}
                data-radial-item
                data-radial-slot="1"
                phx-click="play_as"
                phx-value-character_id={participant.character_id}
                disabled={participant.character_id == (@poster_id || @chat.player_character_id)}
                aria-pressed={
                  to_string(participant.character_id == (@poster_id || @chat.player_character_id))
                }
                aria-label={play_as(participant)}
                title={play_as(participant)}
              >
                <.lucide name="user-round" />
              </button>

              <%!--
                Per-chat settings for this character: the model override (falls back to the chat's
                model, then to the `ai.default_model` setting, `Mythweaver.Generation.model_for/3`)
                and the talkativeness override.
              --%>
              <button
                :if={@access.manage?}
                type="button"
                class="chat-participant-action"
                id={"edit-connection-#{participant.id}"}
                data-radial-item
                data-radial-slot="3"
                phx-click="open_participant_settings"
                phx-value-id={participant.id}
                aria-label={edit_settings(participant)}
                title={edit_settings(participant)}
              >
                <.lucide name="link" />
              </button>

              <%!--
                Last in the toolbar because it is the destructive action. `data-confirm` is the
                standard LiveView guard used by every other delete control in the app
                (`ChatSettings`' delete button, `CharacterLive`'s). Not disabled at the two-participant
                floor: `Chats.remove_participant/1` owns that rule and its refusal is surfaced as a
                flash, which explains the constraint instead of silently greying the control out.
              --%>
              <button
                :if={@access.manage?}
                type="button"
                class="chat-participant-action chat-participant-action--danger"
                id={"remove-participant-#{participant.id}"}
                data-radial-item
                data-radial-slot="4"
                data-radial-danger
                phx-click="remove_participant"
                phx-value-id={participant.id}
                data-confirm={remove_confirm(participant)}
                aria-label={remove_label(participant)}
                title={remove_label(participant)}
              >
                <.lucide name="badge-x" />
              </button>
              <.link
                :if={@access.manage?}
                navigate={~p"/characters/#{participant.character_id}/edit"}
                class="chat-participant-action"
                id={"edit-character-#{participant.id}"}
                data-radial-item
                data-radial-slot="7"
                aria-label={edit_label(participant)}
                title={edit_label(participant)}
              >
                <.lucide name="user-round-pen" />
              </.link>
            </div>
          </li>
        </ul>
      </div>

      <.modal
        :if={@adding_participant? && @chat != nil}
        id="add-participant-modal"
        title={
          if @access.manage?,
            do: dpgettext("chat", "heading: modal adding characters to a chat", "Add characters"),
            else:
              dpgettext(
                "chat",
                "heading: modal where a guest brings a character",
                "Bring a character"
              )
        }
        on_cancel="close_add_participant"
      >
        <form
          id="add-participant-form"
          class="add-participant-form"
          phx-change="validate_add_participants"
          phx-submit="add_participants"
        >
          <.live_component
            module={MythweaverWeb.MultiSelect}
            id="add-participant-characters"
            name="character_ids[]"
            label={dpgettext("chat", "field label: characters to add to a chat", "Characters")}
            options={available_options(@chat, @character_options)}
            selected={@adding_ids}
            empty={
              if @access.manage?,
                do: dgettext("chat", "Every character is already here"),
                else: dgettext("chat", "You have no characters to bring")
            }
            tag_kind={:character}
            viewer_id={@viewer_id}
            tag_graph={@tag_graph}
            tag_vocabulary={@tag_vocabulary}
          />

          <.form_actions>
            <.button phx-click="close_add_participant">
              {dpgettext("chat", "button: close the add-characters modal", "Cancel")}
            </.button>
            <.button variant="primary" type="submit">
              {dpgettext("chat", "button: add the chosen characters to the chat", "Add")}
            </.button>
          </.form_actions>
        </form>
      </.modal>

      <.modal
        :if={@editing_participant != nil}
        id="participant-settings-modal"
        title={
          dpgettext(
            "chat",
            "heading: per-chat settings of one character",
            "Settings for this character"
          )
        }
        on_cancel="close_participant_settings"
      >
        <%!-- No `phx-change`: the controls always show the saved values, hence the fixed `data-saved`. --%>
        <form
          id="participant-settings-form"
          class="add-participant-form"
          phx-hook="UnsavedChanges"
          data-saved
          phx-submit="save_participant_settings"
        >
          <input type="hidden" name="participant_id" value={@editing_participant.id} />
          <%!-- The blank option is what clears the override back to the chat default. --%>
          <.input
            type="select"
            name="ai_model_id"
            id="participant-settings-model"
            label={dpgettext("chat", "field label: model a chat character replies with", "Model")}
            options={[
              {dpgettext("chat", "option: character uses the chat's model", "Chat default"), ""}
              | @model_options
            ]}
            value={@editing_participant.ai_model_id || ""}
            disabled={@access.role != :owner}
          />
          <%!-- Which expression set this character's sprites come from in this chat. --%>
          <.input
            type="select"
            name="outfit_id"
            id="participant-settings-outfit"
            label={dpgettext("chat", "field label: expression set of a chat character", "Outfit")}
            options={[
              {dpgettext("chat", "option: character's default outfit", "Default"), ""}
              | @participant_outfit_options
            ]}
            value={@editing_participant.outfit_id || ""}
          />
          <%!-- Blank clears the override back to the character's own talkativeness. --%>
          <.input
            type="number"
            name="talkativeness"
            id="participant-settings-talkativeness"
            label={
              dgettext("chat", "Talkativeness (blank = character default, %{default_talkativeness})",
                default_talkativeness:
                  Mythweaver.Format.number(@editing_participant.character.talkativeness)
              )
            }
            min="0"
            max="1"
            step="0.05"
            value={@editing_participant.talkativeness}
          />

          <.form_actions>
            <%!-- Dismisses through the modal, so unsaved edits are asked about like Escape or ×. --%>
            <.button
              id="participant-settings-cancel"
              phx-click={JS.dispatch("modal:close", to: "#participant-settings-modal")}
            >
              {dpgettext("chat", "button: close a character's per-chat settings", "Cancel")}
            </.button>
            <.button variant="primary" type="submit">
              {dpgettext("chat", "button: save a character's per-chat settings", "Save")}
            </.button>
          </.form_actions>
        </form>
      </.modal>
    </aside>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".HideMuted">
      // The show/hide-muted choice belongs to the browser, across reloads and chats. The server
      // starts every view showing them; this restores the stored choice once the view (re)connects,
      // hiding the rows at once so the round trip does not flash them, and stores every change the
      // server confirms (`hide_muted`, from the button or the command palette).
      const KEY = "mythweaver:show-muted-participants";

      function stored() {
        try {
          return localStorage.getItem(KEY);
        } catch {
          return null;
        }
      }

      export default {
        mounted() {
          this.handleEvent("hide_muted", ({ hide }) => {
            try {
              localStorage.setItem(KEY, String(!hide));
            } catch {
              // Quota or privacy mode: the choice then lasts only for this view.
            }
          });
          this.restore();
        },
        reconnected() {
          this.restore();
        },
        restore() {
          const show = stored();
          if (show === null) return;
          const hide = show === "false";
          if (hide === (this.el.dataset.hideMuted === "true")) return;
          this.el
            .querySelectorAll(".chat-participant--muted")
            .forEach((row) => (row.hidden = hide));
          this.pushEvent("set_hide_muted", { hide });
        },
      };
    </script>
    """
  end

  defp speaking?(turn_state, participant), do: turn_state.speaking == participant.character_id

  defp generate_label(turn_state, participant, guided?) do
    cond do
      speaking?(turn_state, participant) ->
        dpgettext("chat", "aria label: stop the reply being written", "Stop generating")

      guided? ->
        dgettext("chat", "Queue a guided reply from %{character_name}", character_name: participant.character.name)

      true ->
        dgettext("chat", "Queue a reply from %{character_name}", character_name: participant.character.name)
    end
  end

  defp mute_label(%{muted: true, character: character}),
    do: dgettext("chat", "Unmute %{character_name} in automatic replies", character_name: character.name)

  defp mute_label(%{character: character}),
    do: dgettext("chat", "Mute %{character_name} in automatic replies", character_name: character.name)

  defp who_plays(p),
    do:
      dpgettext("chat", "aria label: list of users who play this character", "Who plays %{character_name}",
        character_name: p.character.name
      )

  defp stop_playing(p),
    do:
      dpgettext("chat", "aria label: release a character under free switching", "Stop playing %{character_name}",
        character_name: p.character.name
      )

  defp play(p),
    do:
      dpgettext("chat", "aria label: take a character under free switching", "Play %{character_name}",
        character_name: p.character.name
      )

  defp play_as(p),
    do:
      dpgettext("chat", "aria label: post as this character", "Play as %{character_name}",
        character_name: p.character.name
      )

  defp edit_settings(p),
    do: dgettext("chat", "Edit %{character_name}'s settings in this chat", character_name: p.character.name)

  defp remove_confirm(p) do
    gettext_comment("Confirm dialog before removing a character from a chat.")
    dgettext("chat", "Remove %{character_name} from this chat?", character_name: p.character.name)
  end

  defp remove_label(p),
    do: dgettext("chat", "Remove %{character_name} from this chat", character_name: p.character.name)

  defp edit_label(p),
    do:
      dpgettext("chat", "aria label: open this character's editor", "Edit %{character_name}",
        character_name: p.character.name
      )

  # The participant's own model name, or nil when it has none or it matches what the reply would
  # use anyway (the chat's model, else the default model).
  defp model_override(%{model: %{id: id, name: name}}, chat, default_model_id) do
    if id != (chat.ai_model_id || default_model_id), do: name
  end

  defp model_override(_participant, _chat, _default_model_id), do: nil

  # The filter hides at least one row and, with hide-muted, every row is hidden.
  defp filtered_empty?(%{participants: participants}, hide_muted?, filtered_out) do
    MapSet.size(filtered_out) > 0 and
      Enum.all?(participants, &((hide_muted? && &1.muted) || MapSet.member?(filtered_out, &1.id)))
  end

  @doc "The bots the mute-all toggle acts on: every non-player participant the search filter keeps."
  def mute_targets(chat, filtered_out), do: Enum.reject(Chat.bots(chat), &MapSet.member?(filtered_out, &1.id))

  # True only when the toggle has at least one target and every one is muted.
  defp all_muted?(chat, filtered_out) do
    case mute_targets(chat, filtered_out) do
      [] -> false
      targets -> Enum.all?(targets, & &1.muted)
    end
  end

  defp mute_all_label(true, true),
    do: dpgettext("chat", "aria label: unmute every character the search shows", "Unmute shown characters")

  defp mute_all_label(false, true),
    do: dpgettext("chat", "aria label: mute every character the search shows", "Mute shown characters")

  defp mute_all_label(true, false),
    do: dpgettext("chat", "aria label: unmute every character in the chat", "Unmute all characters")

  defp mute_all_label(false, false),
    do: dpgettext("chat", "aria label: mute every character in the chat", "Mute all characters")

  # 1-based position of the character's first waiting entry, or nil when it is not queued.
  defp queue_position(turn_state, character_id) do
    case Enum.find_index(turn_state.queue, &(&1.character_id == character_id)) do
      nil -> nil
      i -> i + 1
    end
  end

  # Characters not already in the chat. Derived rather than assigned so the list cannot go stale
  # against the rows rendered right above it.
  defp available_options(nil, _options), do: []

  defp available_options(chat, options) do
    taken = MapSet.new(chat.participants, & &1.character_id)
    Enum.reject(options, fn {_name, id} -> MapSet.member?(taken, id) end)
  end
end
