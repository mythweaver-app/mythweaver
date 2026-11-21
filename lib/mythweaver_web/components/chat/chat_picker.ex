defmodule MythweaverWeb.Chat.ChatPicker do
  @moduledoc """
  The chat picker rail (`grid-area: picker`): navigation links for the viewer's own chats of every
  kind in one list by name, with the selected one highlighted, and assistant threads
  (`Mythweaver.Assistant`) marked by a trailing star. The header holds the bulk toggle, a search
  toggle (`chat-search-toggle`, `"toggle_chat_search"`), a "New Mythweaver conversation" button and
  a "New chat" button; the create modal and a pinned Import button follow. Bulk selection covers
  role-play chats only: in select mode an assistant thread stays a plain link. A "Shared with me"
  section (`chat-picker-shared`) lists the chats others invited the viewer into
  (`Mythweaver.Chats.list_member_chats/1`), each with its owner's handle, outside bulk selection.
  The name and tag filter (`chat-filter`) sits above the list while the search is open; the caller
  passes the already-filtered `chats` and `shared_chats` and clears the filter on close.
  """

  use MythweaverWeb, :html

  import MythweaverWeb.BulkComponents
  import MythweaverWeb.Pane, only: [pane_search: 1]
  import MythweaverWeb.TagFilter, only: [tag_filter: 1]

  alias Mythweaver.Chats.Chat

  attr(:chats, :list, required: true)

  attr(:shared_chats, :list,
    default: [],
    doc: "chats the viewer is a member of, owner (`:user`) loaded"
  )

  attr(:selected_id, :string, default: nil)
  attr(:form, :any, default: nil, doc: "chat changeset form; non-nil renders the open modal")
  attr(:character_options, :list, default: [])
  attr(:form_choices, :map, default: nil, doc: "with `form`: `%{players:, greetings:}`")

  attr(:form_completions, :map,
    default: nil,
    doc: "with `form`: the greeting editor's template completions"
  )

  attr(:unread_ids, :map,
    required: true,
    doc: "unread chats' ids as keys (`Messages.unread_chats/1`)"
  )

  attr(:bulk, :any, required: true, doc: "the page's `MythweaverWeb.Bulk` state (`chats` list)")
  attr(:filter_form, :any, required: true, doc: "the `pane_search` form (`Pane.assign_filter/1`)")
  attr(:search?, :boolean, default: false, doc: "the name and tag filter is open")
  attr(:filtering?, :boolean, default: false, doc: "a name query or tag chip narrows `chats`")
  attr(:tag_filter, :list, default: [])
  attr(:tag_filter_errors, :list, default: [])
  attr(:tag_filter_invalid, :list, default: [])
  attr(:tag_vocabulary, :list, default: [])

  attr(:viewer_id, :string,
    required: true,
    doc: "`current_scope.user.id`, for the picker's tag filter"
  )

  attr(:tag_graph, :any, required: true, doc: "the viewer's `Mythweaver.Tags.Graph`")

  def chat_picker(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="inclusive">
      /* The footer is pinned to the bottom of the rail, so the root is a column flex container
         and the scrolling moved off it onto `.chat-picker-scroll`; a sticky footer inside a
         scrolling root scrolls away.

         `nav:scope`, not a bare `:scope`: this block's marker lands on *every* root tag of the
         template, and `<.form>`'s inner-block root (`.chat-form-actions`) is one of them, so an
         unqualified root rule would paint the rail's panel styling onto the button row. */
      nav:scope {
        grid-area: picker;
        display: flex;
        flex-direction: column;
        margin: var(--panel-gap);
        border: 1px solid var(--border);
        border-radius: var(--radius-3);
        background: var(--card);
        box-shadow: var(--elevation-lg);
      }

      .chat-picker-scroll {
        flex: 1 1 auto;
        min-height: 0;
        overflow-y: auto;
      }

      .chat-picker-list {
        list-style: none;
        margin: 0;
        padding: 0;
      }

      .chat-picker-item {
        padding: var(--size-2);
      }

      .chat-picker-link {
        display: block;
        padding: var(--size-1) var(--size-2);
        text-decoration: none;
        color: var(--muted-foreground);
        border-radius: var(--radius-2);
        transition:
          background-color 250ms ease,
          color 250ms ease;
        font-weight: 450;
        /* One line, clipped with an ellipsis: a long chat name must not wrap the rail. */
        white-space: nowrap;
        overflow: hidden;
        text-overflow: ellipsis;

        &.chat-picker-link--active {
          background-color: color-mix(
            in oklab,
            var(--primary-accent) 13%,
            transparent
          );
          color: var(--primary-accent);
          font-weight: 600;
        }

        &.chat-picker-link--unread {
          color: var(--foreground);
        }
      }
      .chat-picker-empty {
        padding: 0.75rem;
        color: var(--muted-foreground);
        font-style: italic;
      }

      .chat-picker-heading {
        margin: var(--size-3) var(--size-2) 0;
        padding: 0 var(--size-2);
        font-size: var(--font-size-0);
        font-weight: 600;
        text-transform: uppercase;
        letter-spacing: 0.04em;
        color: var(--muted-foreground);
      }

      span.chat-picker-owner:scope {
        flex: 0 0 auto;
        font-size: var(--font-size-0);
        color: var(--muted-foreground);
      }

      /* A link row: the title takes the room and clips; an assistant thread's star sits at the
         right edge. The spans are the link slot's own root tags, so each is a scope root here and
         is reached with `:scope`, not a bare class. */
      a.chat-picker-link {
        display: flex;
        align-items: center;
        gap: var(--size-1);
      }

      span.chat-picker-title:scope {
        flex: 1 1 auto;
        min-inline-size: 0;
        overflow: hidden;
        text-overflow: ellipsis;
      }

      span.chat-picker-kind:scope {
        flex: 0 0 auto;
        display: inline-flex;
        color: var(--guide);
      }

      @media (--coarse) {
        .chat-picker-link {
          min-block-size: var(--touch-target);
        }
      }

      /* Hidden from its header (`.RailCollapse` on `#chat-layout`); still opens as a drawer. */
      .chat-layout[data-picker-collapsed] nav:scope:not(:popover-open) {
        display: none;
      }
    </style>

    <%!--
      A second block, `lower-bound="none"`: the form is rendered through `<.modal>`'s slot and
      `<.input>`'s internals, and the hide button through `<.panel_header>`'s, all nested component
      roots carrying `phx-r` that the block above's inclusive bound cuts off. With no lower bound
      this block's marker also lands on the `<nav>`, so every rule here is scoped to a class, never
      to the root.
    --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      /* A drawer here: its drawer toggle, not the hide button, puts it away. */
      @media (--tablet) {
        .button.rail-collapse {
          display: none;
        }
      }

      .chat-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .chat-form label {
        display: block;
      }

      .chat-form-actions {
        display: flex;
        justify-content: flex-end;
        gap: var(--size-2);
        align-items: center;
      }
    </style>

    <nav
      id="chat-picker"
      class="chat-picker drawer drawer--start drawer--tablet"
      popover
      data-drawer-swipe
      aria-label={dpgettext("chat", "aria label: sidebar listing the viewer's chats", "Chats")}
    >
      <.panel_header>
        {dpgettext("chat", "heading: sidebar listing the viewer's chats", "Chats")}
        <:actions>
          <.bulk_toggle bulk={@bulk} id="chats-bulk-toggle" notext={true} />
          <.button
            icon
            size="sm"
            id="chat-search-toggle"
            phx-click="toggle_chat_search"
            aria-label={
              dpgettext(
                "chat",
                "aria label: icon button that opens the chat name and tag filter",
                "Search chats"
              )
            }
            aria-controls="chat-filter"
            aria-expanded={to_string(@search?)}
            title={
              if(@search?,
                do:
                  dpgettext(
                    "chat",
                    "tooltip: icon button that closes the chat filter",
                    "Close search"
                  ),
                else:
                  dpgettext(
                    "chat",
                    "tooltip: icon button that opens the chat name and tag filter",
                    "Search chats"
                  )
              )
            }
          >
            <.lucide name="search" />
          </.button>
          <.button
            icon
            size="sm"
            id="new-assistant-chat"
            phx-click="new_assistant_chat"
            aria-label={
              dpgettext(
                "chat",
                "aria label: icon button that starts a chat with the built-in assistant",
                "New Mythweaver conversation"
              )
            }
            title={
              dpgettext(
                "chat",
                "tooltip: icon button that starts a chat with the built-in assistant",
                "New Mythweaver conversation"
              )
            }
          >
            <.lucide name="sparkles" />
          </.button>
          <.button
            icon
            size="sm"
            id="new-chat"
            phx-click="new_chat"
            aria-label={
              dpgettext("chat", "aria label: icon button that creates a role-play chat", "New chat")
            }
            title={
              dpgettext("chat", "tooltip: icon button that creates a role-play chat", "New chat")
            }
          >
            <.lucide name="square-pen" />
          </.button>
          <%!-- Handled by `.RailCollapse` on `#chat-layout`, client-side only. --%>
          <.button
            icon
            size="sm"
            id="chat-picker-collapse"
            class="rail-collapse"
            data-rail-collapse="picker"
            aria-controls="chat-picker"
            aria-label={
              dpgettext(
                "chat",
                "aria label: icon button that collapses the chat sidebar",
                "Hide chats"
              )
            }
            title={
              dpgettext("chat", "tooltip: icon button that collapses the chat sidebar", "Hide chats")
            }
          >
            <.lucide name="panel-left-close" />
          </.button>
        </:actions>
      </.panel_header>

      <.bulk_bar bulk={@bulk} id="chats-bulk" />

      <div class="chat-picker-scroll">
        <%!-- `phx-mounted`: opening the search puts the cursor in its name box. --%>
        <div :if={@search?} id="chat-search" phx-mounted={JS.focus(to: "#chat-filter-query")}>
          <.pane_search
            id="chat-filter"
            form={@filter_form}
            placeholder={dpgettext("chat", "placeholder: filter chats by name", "Chat name")}
          >
            <.tag_filter
              id="chat-filter-tags"
              values={@tag_filter}
              vocabulary={@tag_vocabulary}
              errors={@tag_filter_errors}
              invalid={@tag_filter_invalid}
            />
          </.pane_search>
        </div>

        <p :if={@chats == [] and @shared_chats == []} class="chat-picker-empty">
          {if @filtering?,
            do: dpgettext("chat", "empty state: chat filter matches nothing", "No matching chats"),
            else: dpgettext("chat", "empty state: viewer has no chats", "No chats yet")}
        </p>

        <ul
          :if={@chats != []}
          id="chat-picker-list"
          class="chat-picker-list"
          phx-hook="RangeSelect"
          data-range-event="bulk_range"
        >
          <li :for={chat <- @chats} id={"chats-#{chat.id}"} class="chat-picker-item">
            <.bulk_check
              :if={@bulk.active? and chat.kind == :roleplay}
              bulk={@bulk}
              list="chats"
              id={chat.id}
              class="chat-picker-link"
            >
              {Chat.title(chat)}
            </.bulk_check>
            <.link
              :if={!@bulk.active? or chat.kind != :roleplay}
              patch={~p"/chats/#{chat.id}"}
              class={[
                "chat-picker-link",
                chat.id == @selected_id && "chat-picker-link--active",
                (chat.id != @selected_id and Map.has_key?(@unread_ids, chat.id)) &&
                  "chat-picker-link--unread"
              ]}
            >
              <span class="chat-picker-title">{Chat.title(chat)}</span>
              <span
                :if={chat.kind == :assistant}
                class="chat-picker-kind"
                title={
                  dpgettext(
                    "chat",
                    "tooltip: icon marking a chat with the built-in assistant",
                    "Mythweaver conversation"
                  )
                }
                aria-label={
                  dpgettext(
                    "chat",
                    "aria label: icon marking a chat with the built-in assistant",
                    "Mythweaver conversation"
                  )
                }
                role="img"
              >
                <.lucide name="sparkles" />
              </span>
            </.link>
          </li>
        </ul>

        <section
          :if={@shared_chats != []}
          id="chat-picker-shared"
          aria-labelledby="chat-picker-shared-heading"
        >
          <h3 id="chat-picker-shared-heading" class="chat-picker-heading">
            {dpgettext("chat", "heading: chats other people shared with the viewer", "Shared with me")}
          </h3>
          <ul id="chat-picker-shared-list" class="chat-picker-list">
            <li :for={chat <- @shared_chats} id={"shared-chats-#{chat.id}"} class="chat-picker-item">
              <.link
                patch={~p"/chats/#{chat.id}"}
                class={[
                  "chat-picker-link",
                  chat.id == @selected_id && "chat-picker-link--active",
                  (chat.id != @selected_id and Map.has_key?(@unread_ids, chat.id)) &&
                    "chat-picker-link--unread"
                ]}
              >
                <span class="chat-picker-title">{Chat.title(chat)}</span>
                <span :if={chat.user} class="chat-picker-owner">@{chat.user.handle}</span>
              </.link>
            </li>
          </ul>
        </section>
      </div>

      <%!-- Gated on `@form` so the `<dialog>` is only in the DOM while open: the hook opens it on mount. --%>
      <.modal
        :if={@form}
        id="new-chat-modal"
        title={dpgettext("chat", "heading: dialog creating a role-play chat", "New chat")}
        on_cancel="close_chat_modal"
      >
        <.form
          for={@form}
          id="chat-form"
          class="chat-form"
          phx-change="validate_chat"
          phx-submit="save_chat"
        >
          <.input
            field={@form[:name]}
            type="text"
            label={dpgettext("chat", "field label: name of a chat", "Name")}
            id="chat-form-name"
          />
          <%!--
            Create only: `update_changeset/2` never casts `:participants`, so offering this control
            while editing would silently discard the selection.
          --%>
          <.live_component
            module={MythweaverWeb.MultiSelect}
            id="chat-form-participants"
            name="chat[participant_ids][]"
            label={
              dpgettext(
                "chat",
                "field label: characters taking part in a new chat",
                "Participants (pick at least 2)"
              )
            }
            options={@character_options}
            selected={selected_participant_ids(@form)}
            errors={participant_errors(@form)}
            empty={
              dpgettext("chat", "empty state: no characters to add to a chat", "No characters yet")
            }
            tag_kind={:character}
            viewer_id={@viewer_id}
            tag_graph={@tag_graph}
            tag_vocabulary={@tag_vocabulary}
          />
          <.input
            field={@form[:player_character_id]}
            type="select"
            label={
              dpgettext("chat", "field label: character the viewer plays in a chat", "You play as")
            }
            prompt={dpgettext("chat", "option: pick the viewer's character later", "Choose later")}
            options={@form_choices.players}
            id="chat-form-player"
          />
          <.input
            field={@form[:greeting]}
            type="select"
            label={dpgettext("chat", "field label: opening message of a new chat", "Greeting")}
            options={@form_choices.greetings}
            id="chat-form-greeting"
          />
          <.editor
            :if={@form[:greeting].value == "custom"}
            field={@form[:greeting_text]}
            label={
              dpgettext(
                "chat",
                "field label: custom opening narrator message of a new chat",
                "Narrator's message"
              )
            }
            rows={4}
            id="chat-form-greeting-text"
            language="liquid"
            spellcheck
            completions={@form_completions}
          />
          <div class="chat-form-actions">
            <.button phx-click="close_chat_modal">
              {dpgettext("chat", "button: close the new chat dialog", "Cancel")}
            </.button>
            <.button variant="primary" type="submit">
              {dpgettext("chat", "button: create the new chat", "Create")}
            </.button>
          </div>
        </.form>
      </.modal>
    </nav>
    """
  end

  # The picker has no `field`, so its selection only survives a `phx-change` re-render if it is
  # read back out of the changeset the change built.
  defp selected_participant_ids(form) do
    form.source
    |> Ecto.Changeset.get_field(:participants)
    |> List.wrap()
    |> Enum.map(& &1.character_id)
  end

  # The picker has no `field`, so it misses `input/1`'s `used_input?` gate and would otherwise show
  # the changeset's errors on a pristine form. Nothing acts on the participants until a change or a
  # submit sets `:action`, so key the display on that instead.
  defp participant_errors(%{source: %{action: nil}}), do: []

  defp participant_errors(form), do: translate_errors(form.source.errors, :participants)
end
