defmodule MythweaverWeb.Chat.Assistant do
  @moduledoc """
  "Chat with Mythweaver" (`Mythweaver.Assistant`) in the chat body column: the landing shown when
  the viewer has no chat selected (`assistant_landing/1`), an assistant thread (`assistant_chat/1`),
  and the tool-call cards under each reply (`tool_card/1`): Approve/Reject for a write, the API key
  form for `request_api_key`, an Open link and a character row for a finished call. Both compose
  with role-play chats' composer (`MythweaverWeb.Chat.Composer`); the landing's has no file
  picker, since staged files belong to a thread. The landing's gear picks the model the first
  message's thread runs on; an open thread's name and model are edited in its settings modal
  (`assistant_settings/1`).
  """

  use MythweaverWeb, :html

  import MythweaverWeb.Chat.Composer

  alias Mythweaver.Assistant
  alias Mythweaver.Assistant.Tools
  alias Mythweaver.Attachments
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Messages.Message

  attr :form, :any, required: true, doc: "the composer form (`as: :composer`)"
  attr :model_error, :atom, default: nil, doc: "why no model can run the assistant (`Assistant.model/2`), or nil"
  attr :model_notice, :string, default: nil, doc: "the text shown for `model_error`"

  attr :settings_form, :any,
    default: nil,
    doc: "the landing settings form (`as: :assistant_landing`); nil closes the modal"

  attr :model_options, :list, default: [], doc: "`Assistant.model_options/1`"
  attr :default_label, :string, default: nil, doc: "the model select's blank option; defaults to \"Default\""
  attr :model_label, :string, default: nil, doc: "the gear button's label: the picked model; defaults to \"Default\""

  def assistant_landing(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      section:scope {
        grid-area: body;
        display: flex;
        flex-direction: column;
        justify-content: center;
        align-items: center;
        gap: var(--size-3);
        padding: var(--size-6);
        margin: var(--panel-gap) var(--panel-gap) var(--panel-gap) 0;
        background: var(--card);
        border: 1px solid var(--border);
        border-radius: var(--radius-3);
        box-shadow: var(--elevation-lg);
        overflow-y: auto;
      }

      .assistant-landing-title {
        margin: 0;
        font-size: var(--font-size-5);
      }

      .assistant-landing-lead {
        margin: 0;
        color: var(--muted-foreground);
        text-align: center;
      }

      .assistant-landing-notice {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        justify-content: center;
        gap: var(--size-2);
        max-inline-size: 40rem;
        margin: 0;
        padding: var(--size-2) var(--size-3);
        border: 1px solid var(--border);
        border-radius: var(--radius-2);
        background: var(--surface-2);
        text-align: center;
      }

      .assistant-landing-form {
        inline-size: min(48rem, 100%);
        border: 1px solid var(--border);
        border-radius: var(--radius-3);
        background: var(--surface-4);
        overflow: hidden;
      }

      .assistant-landing-options {
        display: flex;
        justify-content: flex-end;
        inline-size: min(48rem, 100%);
      }

      .assistant-landing-settings-help {
        margin: 0;
        color: var(--muted-foreground);
        font-size: var(--font-size-0);
      }

      .assistant-landing-bar {
        display: none;
      }

      /* Tablets and phones: the picker is a drawer, opened from the bar above the title. */
      @media (--tablet) {
        section:scope {
          margin: var(--panel-gap);
        }
        .assistant-landing-bar {
          display: flex;
          align-self: stretch;
        }
      }

      @media (--phone) {
        section:scope {
          padding: var(--size-3);
        }
      }

      /* The chat picker hidden from its header (`.RailCollapse`): the bar carries its show toggle,
         and the body keeps its own gap where the picker's margin was. */
      .chat-layout[data-picker-collapsed] section:scope > .assistant-landing-bar {
        display: flex;
        align-self: stretch;
      }
      .chat-layout[data-picker-collapsed] section:scope {
        margin-inline-start: var(--panel-gap);
      }
    </style>
    <section
      id="assistant-landing"
      class="chat-body"
      aria-label={pgettext("aria label: the assistant chat landing", "Chat with Mythweaver")}
    >
      <div class="assistant-landing-bar">
        <.drawer_toggle
          for="chat-picker"
          breakpoint="tablet"
          label={pgettext("aria label: button that opens the chat list", "Chats")}
          icon={false}
          id="assistant-landing-picker-toggle"
        >
          <.lucide name="panel-left" /> {pgettext("button: open the chat list", "Chats")}
        </.drawer_toggle>
      </div>
      <h1 class="assistant-landing-title">
        {pgettext("heading: the assistant chat landing", "Chat with Mythweaver")}
      </h1>
      <p class="assistant-landing-lead">
        {gettext("Ask me to set up a connection, build a character, write lore or start a chat.")}
      </p>
      <p :if={@model_error} id="assistant-model-notice" class="assistant-landing-notice">
        <span>{@model_notice}</span>
        <.button variant="primary" size="sm" navigate={~p"/ai/providers/new"}>
          {pgettext("button: go create an AI connection", "Add a connection")}
        </.button>
        <.button size="sm" navigate={~p"/settings/models"}>
          {pgettext("button: go to the model settings", "Settings")}
        </.button>
      </p>
      <div class="assistant-landing-form">
        <.composer
          form={@form}
          placeholder={
            pgettext("placeholder: message to the Mythweaver assistant", "Message Mythweaver…")
          }
          editor_id="assistant-composer-content"
          send_disabled?={@model_error != nil}
        />
      </div>
      <div class="assistant-landing-options">
        <.button
          size="sm"
          id="assistant-landing-settings"
          phx-click="open_assistant_landing_settings"
          title={
            pgettext("tooltip: open the assistant conversation settings", "Conversation settings")
          }
        >
          <.lucide name="settings" /> {@model_label || default_model_label()}
        </.button>
      </div>
      <.modal
        :if={@settings_form}
        id="assistant-landing-settings-modal"
        title={pgettext("heading: assistant conversation settings dialog", "Conversation settings")}
        on_cancel="close_assistant_landing_settings"
      >
        <.form
          for={@settings_form}
          id="assistant-landing-settings-form"
          phx-change="assistant_landing_settings"
        >
          <.input
            field={@settings_form[:ai_model_id]}
            type="select"
            label={pgettext("field label: model an assistant conversation runs on", "Model")}
            prompt={@default_label || default_model_label()}
            options={@model_options}
            id="assistant-landing-settings-form-ai_model_id"
          />
          <p class="assistant-landing-settings-help">
            {gettext(
              "Runs the conversation your next message starts. Change it later in the conversation's settings."
            )}
          </p>
          <.form_actions>
            <.button
              type="button"
              variant="primary"
              id="assistant-landing-settings-done"
              phx-click={JS.dispatch("modal:close", to: "#assistant-landing-settings-modal")}
            >
              {pgettext("button: close the settings dialog", "Done")}
            </.button>
          </.form_actions>
        </.form>
      </.modal>
    </section>
    """
  end

  attr :chat, Chat, required: true
  attr :messages, :any, required: true
  attr :empty?, :boolean, default: false
  attr :loading?, :boolean, default: false, doc: "the thread is still being read (`MessageWindow.open/1`)"
  attr :has_older?, :boolean, default: false
  attr :running?, :boolean, default: false
  attr :cards, :map, required: true, doc: "`Mythweaver.Assistant.tool_cards/2`"
  attr :form, :any, required: true, doc: "the composer form (`as: :composer`)"
  attr :upload, :any, default: nil, doc: "the composer's file upload; nil hides the picker"
  attr :composer_attachments, :list, default: []

  def assistant_chat(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      section:scope {
        grid-area: body;
        display: flex;
        flex-direction: column;
        overflow: hidden;
        margin: var(--panel-gap) var(--panel-gap) var(--panel-gap) 0;
        background: var(--card);
        border: 1px solid var(--border);
        border-radius: var(--radius-3);
        box-shadow: var(--elevation-lg);
      }

      .assistant-scroll {
        flex: 1 1 auto;
        min-height: 0;
        overflow-y: auto;
        padding: var(--size-3);
      }

      .assistant-messages {
        list-style: none;
        margin: 0 auto;
        padding: 0;
        max-inline-size: 52rem;
        display: flex;
        flex-direction: column;
        gap: var(--size-3);
      }

      .assistant-message {
        padding: var(--size-2) var(--size-3);
        border-radius: var(--radius-3);
        background: var(--surface-2);

        &.you {
          align-self: flex-end;
          max-inline-size: 80%;
          background: color-mix(
            in oklab,
            var(--primary-accent) 12%,
            var(--surface-2)
          );
        }

        &.summary {
          border-inline-start: 3px solid var(--primary-accent);
          background: var(--surface-1);
        }
      }

      .assistant-message-author {
        font-size: var(--font-size-0);
        font-weight: 600;
        color: var(--muted-foreground);
      }

      .assistant-message-reasoning {
        margin: 0 0 var(--size-1);
        padding-left: var(--size-2);
        border-left: 2px solid var(--border);
        font-size: var(--font-size-0);
        color: var(--muted-foreground);

        & summary {
          cursor: pointer;
          user-select: none;
        }
      }

      .assistant-message-attachments {
        display: flex;
        flex-wrap: wrap;
        gap: var(--size-2);
        margin-block-start: var(--size-2);

        & img {
          display: block;
          max-block-size: 160px;
          max-inline-size: 240px;
          border-radius: var(--radius-2);
          object-fit: cover;
        }

        & audio,
        & video {
          max-inline-size: 100%;
        }
      }

      .assistant-message-file {
        display: inline-flex;
        align-items: center;
        gap: var(--size-2);
        padding: var(--size-2) var(--size-3);
        border: 1px solid var(--border);
        border-radius: var(--radius-2);
        color: var(--foreground);
        text-decoration: none;
      }

      .assistant-message-file--preview {
        flex-direction: column;
        align-items: flex-start;
      }

      /* White behind the page: a PDF with a transparent background stays readable in dark mode. */
      img.assistant-message-preview {
        display: block;
        max-block-size: 12rem;
        max-inline-size: 100%;
        inline-size: auto;
        border-radius: var(--radius-1);
        background: white;
      }

      .assistant-message-error {
        margin: var(--size-1) 0 0;
        color: var(--destructive);
      }

      .assistant-empty {
        margin: var(--size-6) auto;
        color: var(--muted-foreground);
        text-align: center;
      }

      .assistant-older {
        display: flex;
        justify-content: center;
        margin-block-end: var(--size-2);
      }

      .assistant-composer {
        flex: 0 0 auto;
        border-top: 1px solid var(--border);
        background: var(--surface-4);
      }

      @media (--tablet) {
        section:scope {
          margin: var(--panel-gap);
        }
      }

      /* The chat picker hidden from its header (`.RailCollapse`): keep a gap where its margin was. */
      .chat-layout[data-picker-collapsed] section:scope {
        margin-inline-start: var(--panel-gap);
      }
    </style>
    <section
      id="assistant-chat"
      class="chat-body"
      aria-label={pgettext("aria label: an assistant conversation", "Mythweaver conversation")}
    >
      <.panel_header>
        {Chat.title(@chat)}
        <:actions>
          <.drawer_toggle
            for="chat-picker"
            breakpoint="tablet"
            label={pgettext("aria label: button that opens the chat list", "Chats")}
            id="assistant-chat-picker-toggle"
          >
            <.lucide name="panel-left" />
          </.drawer_toggle>
          <.button
            size="sm"
            id="assistant-compact"
            phx-click="compact_assistant"
            disabled={@running? or @empty?}
            title={
              gettext(
                "Summarize the thread so far; Mythweaver then reads the summary instead of the older messages"
              )
            }
          >
            <.lucide name="shrink" /> {pgettext("button: summarize the assistant thread", "Compact")}
          </.button>
          <.button :if={@running?} size="sm" danger id="assistant-stop" phx-click="stop_assistant">
            {pgettext("button: stop the assistant's reply", "Stop")}
          </.button>
          <.button
            size="sm"
            icon
            id="assistant-settings-button"
            patch={~p"/chats/#{@chat.id}/settings"}
            aria-label={
              pgettext(
                "aria label: open the assistant conversation settings",
                "Conversation settings"
              )
            }
            title={
              pgettext("tooltip: open the assistant conversation settings", "Conversation settings")
            }
          >
            <.lucide name="settings" />
          </.button>
          <.button
            size="sm"
            icon
            id="assistant-delete"
            phx-click="delete_chat"
            phx-value-id={@chat.id}
            data-confirm={delete_confirm()}
            aria-label={
              pgettext("aria label: delete the assistant conversation", "Delete conversation")
            }
            title={pgettext("tooltip: delete the assistant conversation", "Delete conversation")}
          >
            <.lucide name="trash" />
          </.button>
        </:actions>
      </.panel_header>
      <div id="assistant-scroll" class="assistant-scroll" phx-hook=".AssistantScroll">
        <div :if={@has_older?} class="assistant-older">
          <.button size="sm" id="assistant-load-older" phx-click="load_older_messages">
            {pgettext("button: load older assistant messages", "Load older")}
          </.button>
        </div>
        <p :if={@loading?} id="assistant-loading" class="assistant-empty" role="status">
          <.lucide name="loader" /> {pgettext("status: assistant messages loading", "Loading…")}
        </p>
        <p :if={@empty? and not @loading?} id="assistant-empty" class="assistant-empty">
          {gettext("Ask Mythweaver anything about setting up your stories.")}
        </p>
        <ol id="assistant-messages" class="assistant-messages" phx-update="stream">
          <li
            :for={{dom_id, message} <- @messages}
            id={dom_id}
            class={[
              "assistant-message",
              message.author_is_player && "you",
              message.summary && "summary"
            ]}
          >
            <% body = Message.active_body(message) %>
            <% generating? = (body && body.generating) || false %>
            <div class="assistant-message-author">
              {cond do
                message.summary ->
                  pgettext("badge: author line of a thread summary message", "Summary")

                message.author_is_player ->
                  pgettext("badge: author line of the user's own message", "You")

                true ->
                  Message.assistant_author()
              end}
            </div>
            <%!-- As in role-play chats: `open` is server-driven (expanded while only reasoning has
               streamed, collapsed once reply text lands) until the user toggles it, after which
              `.ReasoningToggle` keeps their choice over the patch every streamed token brings. --%>
            <details
              :if={body && body.reasoning not in [nil, ""]}
              id={"assistant-reasoning-#{message.id}"}
              class="assistant-message-reasoning"
              open={generating? and body.content in [nil, ""]}
              phx-hook=".ReasoningToggle"
            >
              <summary>{pgettext("toggle: show the model's reasoning", "Thinking")}</summary>
              <.markdown text={body.reasoning} streaming={generating?} />
            </details>
            <.markdown
              id={"assistant-text-#{message.id}"}
              text={(body && body.content) || ""}
              streaming={generating?}
              caret={generating?}
            />
            <div
              :if={Message.loaded_attachments(message) != []}
              class="assistant-message-attachments"
            >
              <%= for a <- Message.loaded_attachments(message) do %>
                <%= case a.kind do %>
                  <% :image -> %>
                    <a
                      id={"attachment-#{a.id}"}
                      href={Attachments.url(a, :original)}
                      target="_blank"
                      rel="noopener"
                    >
                      <img
                        src={Attachments.url(a, :thumb)}
                        alt={
                          a.description || a.filename ||
                            pgettext("alt text: an attached image", "Image")
                        }
                      />
                    </a>
                  <% :audio -> %>
                    <audio
                      id={"attachment-#{a.id}"}
                      controls
                      preload="metadata"
                      src={Attachments.url(a, :full)}
                    ></audio>
                  <% :video -> %>
                    <video
                      id={"attachment-#{a.id}"}
                      controls
                      preload="metadata"
                      src={Attachments.url(a, :full)}
                      poster={Attachments.still_url(a, :inline)}
                    ></video>
                  <% _ -> %>
                    <% preview = Attachments.still_url(a, :thumb) %>
                    <a
                      id={"attachment-#{a.id}"}
                      class={["assistant-message-file", preview && "assistant-message-file--preview"]}
                      href={Attachments.url(a, :full)}
                      target="_blank"
                      rel="noopener"
                    >
                      <img
                        :if={preview}
                        class="assistant-message-preview"
                        src={preview}
                        alt=""
                        loading="lazy"
                      />
                      <.lucide name="file-text" /> {a.filename ||
                        pgettext("link: an attached file without a name", "File")}
                    </a>
                <% end %>
              <% end %>
            </div>
            <p :if={body && body.error} class="assistant-message-error">{body.error}</p>
            <.tool_card
              :for={call <- Map.get(@cards.calls, message.id, [])}
              call={call}
              characters={@cards.characters}
              preview={Map.get(@cards.previews, call.id, [])}
            />
          </li>
        </ol>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".AssistantScroll">
        // Keeps the thread pinned to the newest message while the reader is at the bottom.
        const NEAR_PX = 80;

        export default {
          mounted() {
            this.pinned = true;
            this.el.addEventListener("scroll", () => {
              this.pinned =
                this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight <=
                NEAR_PX;
            });
            this.handleEvent("scroll_to_bottom", () => this.toBottom());
            this.toBottom();
          },
          updated() {
            if (this.pinned) this.toBottom();
          },
          toBottom() {
            this.el.scrollTop = this.el.scrollHeight;
            this.pinned = true;
          },
        };
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ReasoningToggle">
        // A summary click (or Enter/Space on it) is the user's choice; it outlasts the server's `open`,
        // which each streamed token patches back.
        export default {
          mounted() {
            this.el.querySelector("summary").addEventListener("click", () => {
              this.chosen = !this.el.open;
            });
          },
          updated() {
            if (this.chosen !== undefined) this.el.open = this.chosen;
          },
        };
      </script>
      <div class="assistant-composer">
        <.composer
          chat={@chat}
          form={@form}
          upload={@upload}
          composer_attachments={@composer_attachments}
          placeholder={
            pgettext("placeholder: message to the Mythweaver assistant", "Message Mythweaver…")
          }
          editor_id="assistant-composer-content"
          send_disabled?={@running?}
        />
      </div>
    </section>
    """
  end

  attr :chat, Chat, required: true
  attr :form, :any, required: true, doc: "the settings form (`as: :assistant_settings`)"
  attr :model_options, :list, default: [], doc: "`Assistant.model_options/1`"
  attr :default_label, :string, default: nil, doc: "the model select's blank option; defaults to \"Default\""

  @doc "An assistant thread's settings modal: its name and the model it runs on."
  def assistant_settings(assigns) do
    ~H"""
    <%!-- `lower-bound="none"`: the form sits in `<.modal>`'s slot, a nested component root. --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      .assistant-settings-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }
    </style>
    <div class="assistant-settings">
      <.modal
        id="assistant-settings-modal"
        title={pgettext("heading: assistant conversation settings dialog", "Conversation settings")}
        on_cancel="close_chat_settings"
      >
        <.form
          for={@form}
          id="assistant-settings-form"
          class="assistant-settings-form"
          phx-hook="UnsavedChanges"
          data-saved={is_nil(@form.action)}
          phx-change="validate_assistant_settings"
          phx-submit="save_assistant_settings"
        >
          <.input
            field={@form[:name]}
            type="text"
            label={pgettext("field label: name of an assistant conversation", "Name")}
            id="assistant-settings-form-name"
          />
          <.input
            field={@form[:ai_model_id]}
            type="select"
            label={pgettext("field label: model an assistant conversation runs on", "Model")}
            prompt={@default_label || default_model_label()}
            options={@model_options}
            id="assistant-settings-form-ai_model_id"
          />
          <.form_actions>
            <.button patch={~p"/chats/#{@chat.id}"} id="assistant-settings-cancel">
              {pgettext("button: close the form without saving", "Cancel")}
            </.button>
            <.button type="submit" variant="primary" id="assistant-settings-save">
              {pgettext("button: save the open form", "Save")}
            </.button>
          </.form_actions>
        </.form>
      </.modal>
    </div>
    """
  end

  attr :call, :any, required: true
  attr :characters, :map, default: %{}
  attr :preview, :list, default: [], doc: "what a pending call would touch (`Tool` `preview`)"

  def tool_card(assigns) do
    # Runtime-picked by `icon/2`; the Iconex compiler only sees literals.
    Iconex.hint(:lucide, ~w[search pencil-line key-round circle-check circle-x ban loader])

    call = assigns.call

    tool =
      case Tools.fetch(call.name) do
        {:ok, tool} -> tool
        :error -> nil
      end

    result = call.result || %{}

    shown =
      for id <- Assistant.character_ids(call),
          %{} = character <- [Map.get(assigns.characters, id)],
          do: {character, character_changes(call, id)}

    assigns =
      assign(assigns,
        summary: summary(tool, call),
        icon: icon(tool, call.status),
        result: result,
        shown: shown,
        open_path: open_path(result),
        details: Jason.encode!(%{arguments: call.arguments, result: call.result}, pretty: true),
        failed: batch_failures(result),
        key_form: to_form(%{}, as: :key)
      )

    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      div.tool-card:scope {
        margin-block-start: var(--size-2);
        padding: var(--size-2);
        border: 1px solid var(--border);
        border-radius: var(--radius-2);
        background: var(--surface-1);
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .tool-card-head {
        display: flex;
        align-items: center;
        gap: var(--size-2);
      }

      .tool-card-summary {
        flex: 1 1 auto;
      }

      .tool-card-status {
        font-size: var(--font-size-00);
        text-transform: uppercase;
        color: var(--muted-foreground);
      }

      .tool-card-actions {
        display: flex;
        gap: var(--size-2);
        align-items: center;
      }

      .tool-card-muted {
        margin: 0;
        color: var(--muted-foreground);
      }

      .tool-card-character {
        display: flex;
        align-items: center;
        gap: var(--size-2);
      }

      .tool-card-avatar {
        inline-size: 2.5rem;
        block-size: 2.5rem;
        border-radius: 50%;
        overflow: hidden;
        flex: 0 0 auto;

        & img {
          inline-size: 100%;
          block-size: 100%;
          object-fit: cover;
        }
      }

      .tool-card-preview {
        margin: 0;
        padding-inline-start: var(--size-4);
        max-block-size: 12rem;
        overflow: auto;

        & li {
          overflow-wrap: anywhere;
        }
      }

      .tool-card-details pre {
        margin: 0;
        max-block-size: 20rem;
        overflow: auto;
        font-size: var(--font-size-0);
        white-space: pre-wrap;
      }
    </style>
    <div id={"tool-call-#{@call.id}"} class="tool-card" data-status={@call.status}>
      <div class="tool-card-head">
        <.lucide name={@icon} />
        <span class="tool-card-summary">{@summary}</span>
        <span class="tool-card-status">{status_label(@call.status)}</span>
      </div>

      <ul :if={@preview != []} id={"tool-call-preview-#{@call.id}"} class="tool-card-preview">
        <li :for={line <- @preview}>{line}</li>
      </ul>

      <div :if={@call.status == :pending} class="tool-card-actions">
        <.button
          size="sm"
          variant="primary"
          id={"tool-call-approve-#{@call.id}"}
          phx-click="approve_tool_call"
          phx-value-id={@call.id}
        >
          {pgettext("button: allow the assistant's tool call", "Approve")}
        </.button>
        <.button
          size="sm"
          id={"tool-call-reject-#{@call.id}"}
          phx-click="reject_tool_call"
          phx-value-id={@call.id}
        >
          {pgettext("button: refuse the assistant's tool call", "Reject")}
        </.button>
      </div>

      <.form
        :if={@call.status == :awaiting_input}
        for={@key_form}
        id={"tool-call-key-form-#{@call.id}"}
        phx-submit="submit_api_key"
        class="tool-card-key-form"
      >
        <input type="hidden" name="call_id" value={@call.id} />
        <.input
          type="password"
          field={@key_form[:api_key]}
          id={"tool-call-key-form-#{@call.id}-api_key"}
          label={pgettext("field label: API key of an AI connection", "API key")}
        />
        <div class="tool-card-actions">
          <.button size="sm" variant="primary" type="submit">
            {pgettext("button: save the open form", "Save")}
          </.button>
          <.button size="sm" phx-click="dismiss_api_key" phx-value-id={@call.id}>
            {pgettext("button: close the form without saving", "Cancel")}
          </.button>
        </div>
        <p class="tool-card-muted">
          {gettext("The key goes straight to the connection; Mythweaver never sees it.")}
        </p>
      </.form>

      <div :for={{character, changed} <- @shown} class="tool-card-character">
        <div class="tool-card-avatar">
          <.avatar_image avatar={character} preset={:avatar} sizes="40px" />
        </div>
        <div>
          <strong>{character.name}</strong>
          <p :if={changed != []} class="tool-card-muted">{changed_text(changed)}</p>
        </div>
      </div>

      <div :if={@call.status == :succeeded and @open_path} class="tool-card-actions">
        <.button size="sm" navigate={@open_path} id={"tool-call-open-#{@call.id}"}>
          {pgettext("button: open what the tool call made or changed", "Open")}
        </.button>
      </div>

      <p :if={@call.status in [:failed, :rejected]} class="tool-card-muted">
        {@result["error"] || @call.error}
      </p>

      <div :if={@failed != []} id={"tool-call-failed-#{@call.id}"}>
        <p class="tool-card-muted">
          {batch_counts(length(List.wrap(@result["done"])), length(@failed))}
        </p>
        <ul class="tool-card-preview">
          <li :for={line <- @failed}>{line}</li>
        </ul>
      </div>

      <details class="tool-card-details">
        <summary>
          {pgettext("toggle: show a tool call's raw arguments and result", "Details")}
        </summary>
        <pre>{@details}</pre>
      </details>
    </div>
    """
  end

  # A batch call's per-row failures (`Mythweaver.Assistant.Tools.Batch`), one line each.
  defp batch_failures(%{"failed" => [_ | _] = failed}) do
    for f <- failed, is_map(f) do
      who =
        f["name"] || f["id"] ||
          pgettext("status: unnamed row of a batch tool call", "Item %{item_position}",
            item_position: Mythweaver.Format.number((f["index"] || 0) + 1)
          )

      pgettext("status: one failed row of a batch tool call", "%{item_title}: %{error_message}",
        item_title: who,
        error_message: f["error"]
      )
    end
  end

  defp batch_failures(_result), do: []

  defp summary(nil, call),
    do:
      if(call.name == "",
        do: pgettext("status: tool call whose name can't be read", "Unreadable tool call"),
        else: call.name
      )

  defp summary(tool, call) do
    tool.summary.(call.arguments || %{})
  rescue
    _ -> call.name
  end

  defp icon(_tool, :succeeded), do: "circle-check"
  defp icon(_tool, :failed), do: "circle-x"
  defp icon(_tool, :rejected), do: "ban"
  defp icon(_tool, :running), do: "loader"
  defp icon(%{kind: :input}, _status), do: "key-round"
  defp icon(%{kind: :write}, _status), do: "pencil-line"
  defp icon(_tool, _status), do: "search"

  defp status_label(:pending), do: pgettext("status: assistant tool call", "Needs approval")
  defp status_label(:awaiting_input), do: pgettext("status: assistant tool call", "Needs input")
  defp status_label(:running), do: pgettext("status: assistant tool call", "Running")
  defp status_label(:succeeded), do: pgettext("status: assistant tool call", "Done")
  defp status_label(:failed), do: pgettext("status: assistant tool call", "Failed")
  defp status_label(:rejected), do: pgettext("status: assistant tool call", "Rejected")

  defp default_model_label, do: pgettext("option: use the default model for the assistant", "Default")

  defp delete_confirm do
    gettext_comment("Confirm dialog before deleting an assistant conversation.")
    pgettext("status: confirm dialog before deleting an assistant conversation", "Delete this conversation?")
  end

  defp changed_text(fields) do
    gettext_comment("Under a character a tool call touched; the placeholder is a comma-separated list of field names.")

    pgettext("status: fields a tool call changed on a character", "Changed: %{field_list}",
      field_list: Enum.join(fields, ", ")
    )
  end

  defp batch_counts(done, failed) do
    gettext("%{done_count} done, %{failed_count} not done:",
      done_count: Mythweaver.Format.number(done),
      failed_count: Mythweaver.Format.number(failed)
    )
  end

  # The page of what the call made or changed: its own `path`, or a batch's single done row's.
  defp open_path(%{"path" => path}) when is_binary(path), do: path
  defp open_path(%{"done" => [%{"path" => path}]}) when is_binary(path), do: path
  defp open_path(_result), do: nil

  # The fields the call's item for this character set: an update's by id, a create's by the name
  # it was created with.
  defp character_changes(%{name: name, arguments: %{"items" => items}} = call, id) when is_list(items) do
    created = Enum.find(List.wrap((call.result || %{})["done"]), &(&1["id"] == id))

    item =
      Enum.find(items, fn item ->
        is_map(item) and
          if(name == "create_characters", do: created && item["name"] == created["name"], else: item["id"] == id)
      end)

    if item,
      do: item |> Map.keys() |> Kernel.--(["id"]) |> Enum.map(&(&1 |> String.replace("_", " ") |> String.capitalize())),
      else: []
  end

  defp character_changes(_call, _id), do: []
end
