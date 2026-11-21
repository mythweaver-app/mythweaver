defmodule MythweaverWeb.Chat.Composer do
  @moduledoc """
  The message composer every chat surface shares: the markdown (or, with `completions`, liquid)
  editor, the paperclip file picker with drop and image paste, the staged attachments with their
  describe controls, quick replies, the clear button, shell-style sent-message history (Alt+↑/↓),
  type-anywhere focus (a printable key pressed outside any field lands in the editor) and the send
  button. Role-play chats (`MythweaverWeb.Chat.Messages`) and Mythweaver assistant
  threads (`MythweaverWeb.Chat.Assistant`) render it; only one is on a page at a time, so its ids
  are fixed (`#message-composer`, `#composer-*`), except the editor's (`editor_id`): the editor's
  hook reads its language, placeholder and completions only when it mounts, so each surface gives
  it its own id and switching between them mounts a fresh one.

  The form posts `phx-change="save_draft"` and `phx-submit="send_message"` with params under
  `composer`, and the `.MessageComposer` hook pushes `typing`/`stop_typing` and `quick_reply`;
  `MythweaverWeb.MainChatLive` handles them for both kinds of chat.
  """

  use MythweaverWeb, :html

  alias Mythweaver.Attachments
  alias Mythweaver.Format
  alias Mythweaver.Scripts.Completions
  alias MythweaverWeb.Uploads

  @icon_marker "\u{F0003}"

  attr(:chat, :any,
    default: nil,
    doc: "the open chat (its id resets history navigation); nil on the landing"
  )

  attr(:form, :any, required: true, doc: "`to_form(%{\"content\" => …}, as: :composer)`")

  attr(:upload, :any,
    default: nil,
    doc: "the composer's file upload (`@uploads.composer_files`); nil hides the picker"
  )

  attr(:composer_attachments, :list,
    default: [],
    doc: "files uploaded in the composer, not sent yet"
  )

  attr(:quick_replies, :list, default: [], doc: "enabled quick reply scripts, in toolbar order")

  attr(:quick_reply_running?, :boolean,
    default: false,
    doc: "a quick reply is running; its buttons are disabled"
  )

  attr(:completions, :map,
    default: nil,
    doc: "template completions; when set the editor is `liquid` (with inline Lua), else `markdown`"
  )

  attr(:guided?, :boolean,
    default: false,
    doc: "show the hint that the text and attachments guide the next reply"
  )

  attr(:refinable?, :boolean,
    default: false,
    doc: "the text would steer a refine; the hint names its button"
  )

  attr(:placeholder, :string,
    default: nil,
    doc: "the editor's placeholder; nil shows \"Write a message…\""
  )

  attr(:send_disabled?, :boolean, default: false)

  attr(:editor_id, :string,
    default: "message-composer-content",
    doc: "the editor's id; one per surface (see the moduledoc). The shortcut keys' composer check reads the default"
  )

  def composer(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      /* `lower-bound="none"`: these rules reach `<.form>`'s, `<.editor>`'s and `<.button>`'s roots,
         which carry `phx-r`. Every root rule is tag-qualified for the same reason. */
      /* `position: relative` anchors the visually hidden file input inside the composer. Without
         it the input hangs off the page itself, and when the phone composer is collapsed its
         `overflow: hidden` does not clip it, so it lengthened the document and let the page scroll. */
      div.chat-composer-body:scope {
        position: relative;
        width: 100%;
      }

      .chat-attachment-status {
        display: inline-flex;
        align-items: center;
        gap: var(--size-1);
      }

      .chat-composer-hint {
        margin: var(--size-1) 0 0;
        font-size: 0.8rem;
        color: var(--muted-foreground);
        text-align: center;

        .iconex {
          color: var(--guide);
        }
      }

      .chat-composer-row {
        display: flex;
        gap: var(--size-2);
        width: 100%;
      }

      .chat-composer-row > div {
        flex: 1 1 auto;
        min-width: 0;
      }

      /* Quick reply buttons, above everything else in the composer. */
      .chat-quick-replies {
        display: flex;
        flex-wrap: wrap;
        gap: var(--size-1);
        padding: var(--size-2) var(--size-4) 0;
      }

      /* Images picked for the next send. */
      .chat-composer-attachments {
        display: flex;
        flex-wrap: wrap;
        align-items: flex-start;
        gap: var(--size-2);
        padding: var(--size-2) var(--size-4) 0;
      }

      /* Each pending image: thumbnail, its describe controls, then its description editor. */
      .chat-composer-attachments figure {
        position: relative;
        display: flex;
        flex-direction: column;
        place-items: stretch;
        gap: var(--size-1);
        inline-size: min(200px, 100%);
        margin: 0;
      }

      .chat-composer-attachments img {
        inline-size: 100%;
        block-size: 120px;
        object-fit: cover;
        border-radius: var(--radius-2);
      }

      .chat-composer-attachments progress {
        inline-size: 100%;
        block-size: 4px;
      }

      .chat-composer-attachments figcaption,
      .chat-composer-upload-error {
        font-size: var(--font-size-0);
        color: var(--destructive);
      }

      figcaption.chat-composer-attachment-caption {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: var(--size-1);
        color: var(--muted-foreground);
      }

      div.chat-composer-attachment-description {
        font-size: var(--font-size-0);
      }

      .chat-composer-upload-error {
        margin: var(--size-2) var(--size-4) 0;
      }

      .chat-composer-attachment-remove {
        position: absolute;
        inset-block-start: var(--size-1);
        inset-inline-end: var(--size-1);
        display: grid;
        place-items: center;
        padding: 2px;
        border: none;
        border-radius: var(--radius-round);
        background: var(--card);
        color: var(--foreground);
        cursor: pointer;
      }

      /* A staged non-image: its icon and name in a chip, the remove button at its end. */
      figure.chat-composer-file {
        flex-direction: row;
        align-items: center;
        inline-size: auto;
        padding: var(--size-2) var(--size-7) var(--size-2) var(--size-3);
        border: 1px solid var(--border);
        border-radius: var(--radius-2);
        color: var(--foreground);
      }

      .chat-composer-file-name,
      .chat-composer-upload-name {
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }

      .chat-composer-upload-name {
        display: inline-flex;
        align-items: center;
        gap: var(--size-1);
      }

      figure.chat-composer-file .chat-composer-attachment-remove {
        inset-block-start: 50%;
        translate: 0 -50%;
      }

      /* The paperclip, left of the editor: a `<.button>` the `.MessageComposer` hook turns into a
         click on the hidden file input. Its own border, sized like the clear button. */
      .chat-composer-attach {
        flex: 0 0 auto;
        align-self: center;
        margin-inline-start: var(--size-3);
        padding: var(--size-2);
        font-size: 0.9rem;
      }

      .chat-composer-file-input {
        position: absolute;
        inline-size: 1px;
        block-size: 1px;
        overflow: hidden;
        clip-path: inset(50%);
      }

      div.chat-composer-input {
        background: var(--card);
        border: none;
        border-radius: 0;
        padding: var(--size-4);
        height: 100%;
      }

      /* `<.editor>`'s ring is `:focus-within`, which clicks match too; here it shows only when
         `.MessageComposer` saw Tab move focus into the row (`data-keyboard-focus`). */
      div.chat-composer-row:not([data-keyboard-focus])
        div.chat-composer-input:focus-within {
        outline: none;
      }

      /* The send button and its history pair, touching. `div.` outranks `.chat-composer-row > div`. */
      div.chat-composer-toolbar {
        display: flex;
        align-items: stretch;
        flex: 0 0 auto;
        margin: var(--size-4);
        height: min-content;
        align-self: center;
      }

      .chat-composer-history {
        display: flex;
        flex-direction: column;
      }

      /* `<.button>` roots: reachable because this block has no lower bound. Each button overlaps
         its right (and the lower history button its upper) neighbour by 1px so shared borders draw
         once; only the group's outer corners stay rounded. */
      .chat-composer-clear {
        padding-inline: var(--size-2);
        font-size: 0.9rem;
        border-start-end-radius: 0;
        border-end-end-radius: 0;
        margin-inline-end: -1px;
      }

      .chat-composer-history-button {
        flex: 1 1 0;
        padding-block: 0;
        font-size: 0.8rem;
        border-radius: 0;
        margin-inline-end: -1px;

        & + & {
          margin-block-start: -1px;
        }
      }

      .chat-composer-send {
        padding: var(--size-3);
        font-size: 1.1rem;
        border-start-start-radius: 0;
        border-end-start-radius: 0;
      }

      @media (--coarse) {
        /* Touch keyboards have no easy Shift+Enter, so Enter adds a line and Send sends. */
        div.chat-composer-input {
          --rich-input-enter: newline;
        }

        .chat-composer-history-button {
          min-inline-size: var(--touch-target);
          min-block-size: var(--touch-target);
        }
      }

      /* Phones: the composer is one 44px-tall row beside a one-line editor. Clear is hidden to give
         the editor width (select-all + delete remains); the history pair takes over the group's
         left corners and shares one touch target's height, each half a target tall but a full one
         wide. */
      @media (--phone) {
        div.chat-composer-toolbar {
          margin: var(--size-2);
        }
        div.chat-composer-input {
          padding: var(--size-2) var(--size-3);
        }
        .chat-composer-attach {
          margin-inline-start: var(--size-2);
        }
        .chat-composer-clear {
          display: none;
        }
        .chat-composer-history-button {
          min-block-size: calc(var(--touch-target) / 2);
          border-start-start-radius: var(--radius-2);
          border-end-start-radius: var(--radius-2);
        }
        .chat-composer-send {
          padding: var(--size-2);
        }
      }

      /* While a send is in flight LiveView marks the form `phx-submit-loading`: Send dims and
         shows the wait cursor, so a tap on a slow link visibly took. */
      form.phx-submit-loading .chat-composer-send {
        opacity: 0.55;
        cursor: progress;
      }
    </style>
    <div class="chat-composer-body">
      <.form
        for={@form}
        id="message-composer"
        phx-change="save_draft"
        phx-submit="send_message"
      >
        <div
          :if={@quick_replies != []}
          id="quick-replies"
          class="chat-quick-replies"
          role="toolbar"
          aria-label={
            dpgettext("chat", "aria label: toolbar of quick reply script buttons", "Quick replies")
          }
          data-running={to_string(@quick_reply_running?)}
        >
          <%!-- Clicks are the `.MessageComposer` hook's, which sends the live composer text and
          disables the buttons at once; `data-running` is what they settle to once the server answers. --%>
          <.button
            :for={qr <- @quick_replies}
            size="sm"
            id={"quick-reply-#{qr.id}"}
            data-quick-reply-id={qr.id}
            title={qr.description}
            disabled={@quick_reply_running?}
          >
            {qr.name}
          </.button>
        </div>
        <div
          :if={@composer_attachments != [] or (@upload && @upload.entries != [])}
          id="composer-attachments"
          class="chat-composer-attachments"
        >
          <figure
            :for={a <- @composer_attachments}
            :if={a.kind == :image}
            id={"composer-attachment-#{a.id}"}
          >
            <img
              src={Attachments.url(a, :thumb)}
              alt={
                a.filename ||
                  dpgettext("chat", "alt text: attached image without a file name", "Image")
              }
            />
            <button
              type="button"
              class="chat-composer-attachment-remove"
              phx-click="remove_composer_attachment"
              phx-value-id={a.id}
              aria-label={
                if a.filename,
                  do:
                    dpgettext(
                      "chat",
                      "aria label: button that removes this attachment from the composer",
                      "Remove %{file_name}",
                      file_name: a.filename
                    ),
                  else:
                    dpgettext(
                      "chat",
                      "aria label: button that removes an unnamed image from the composer",
                      "Remove image"
                    )
              }
              title={
                dpgettext(
                  "chat",
                  "tooltip: button that removes an attachment from the composer",
                  "Remove"
                )
              }
            >
              <.lucide name="x" />
            </button>
            <figcaption class="chat-composer-attachment-caption">
              <span :if={a.caption_status == :pending} class="chat-attachment-status">
                <.lucide name="loader" /> {dpgettext(
                  "chat",
                  "status: caption model is describing an image",
                  "Describing…"
                )}
              </span>
              <span
                :if={a.caption_status == :failed}
                class="chat-attachment-status"
                title={a.caption_error}
              >
                {dpgettext(
                  "chat",
                  "status: caption model failed to describe an image",
                  "Description failed"
                )}
              </span>
              <.button
                :if={a.caption_status != :pending}
                size="sm"
                id={"composer-attachment-describe-#{a.id}"}
                phx-click="describe_composer_attachment"
                phx-value-id={a.id}
                title={dgettext("chat", "Have the caption model describe this image now")}
              >
                <.lucide name="sparkles" /> {if a.description,
                  do:
                    dpgettext(
                      "chat",
                      "button: describe an already described image again",
                      "Redescribe"
                    ),
                  else:
                    dpgettext("chat", "button: have the caption model describe an image", "Describe")}
              </.button>
              <.button
                :if={a.caption_status != :pending}
                size="sm"
                id={"composer-attachment-ask-#{a.id}"}
                phx-click="ask_caption"
                phx-value-id={a.id}
                phx-value-target="staged"
                title={dgettext("chat", "Ask the caption model a question about this image")}
              >
                <.lucide name="message-square" /> {dpgettext(
                  "chat",
                  "button: ask the caption model about an image",
                  "Ask…"
                )}
              </.button>
            </figcaption>
            <.editor
              name={"attachment_descriptions[#{a.id}]"}
              value={a.description || ""}
              id={"composer-attachment-description-#{a.id}"}
              class="chat-composer-attachment-description"
              rows={2}
              max_rows={6}
              debounce="500"
              placeholder={
                dpgettext(
                  "chat",
                  "placeholder: description of an attached image",
                  "Describe this image"
                )
              }
            />
          </figure>
          <figure
            :for={a <- @composer_attachments}
            :if={a.kind != :image}
            id={"composer-attachment-#{a.id}"}
            class="chat-composer-file"
          >
            <%= case a.kind do %>
              <% :document -> %>
                <.lucide name="file-text" />
              <% :audio -> %>
                <.lucide name="music" />
              <% :video -> %>
                <.lucide name="video" />
              <% _ -> %>
                <.lucide name="file" />
            <% end %>
            <span class="chat-composer-file-name">{a.filename}</span>
            <button
              type="button"
              class="chat-composer-attachment-remove"
              phx-click="remove_composer_attachment"
              phx-value-id={a.id}
              aria-label={
                if a.filename,
                  do:
                    dpgettext(
                      "chat",
                      "aria label: button that removes this attachment from the composer",
                      "Remove %{file_name}",
                      file_name: a.filename
                    ),
                  else:
                    dpgettext(
                      "chat",
                      "aria label: button that removes an unnamed file from the composer",
                      "Remove file"
                    )
              }
              title={
                dpgettext(
                  "chat",
                  "tooltip: button that removes an attachment from the composer",
                  "Remove"
                )
              }
            >
              <.lucide name="x" />
            </button>
          </figure>
          <figure
            :for={entry <- (@upload && @upload.entries) || []}
            id={"composer-upload-#{entry.ref}"}
          >
            <.live_img_preview :if={String.starts_with?(entry.client_type, "image/")} entry={entry} />
            <span
              :if={!String.starts_with?(entry.client_type, "image/")}
              class="chat-composer-upload-name"
            >
              <.lucide name="file" /> {entry.client_name}
            </span>
            <progress value={entry.progress} max="100">{Format.percent(entry.progress / 100)}</progress>
            <figcaption :for={error <- upload_errors(@upload, entry)}>
              {Uploads.error_text(error)}
            </figcaption>
            <button
              type="button"
              class="chat-composer-attachment-remove"
              phx-click="cancel_composer_file"
              phx-value-ref={entry.ref}
              aria-label={
                dpgettext(
                  "chat",
                  "aria label: button that removes this attachment from the composer",
                  "Remove %{file_name}",
                  file_name: entry.client_name
                )
              }
              title={
                dpgettext(
                  "chat",
                  "tooltip: button that removes an attachment from the composer",
                  "Remove"
                )
              }
            >
              <.lucide name="x" />
            </button>
          </figure>
        </div>
        <p
          :for={error <- (@upload && upload_errors(@upload)) || []}
          class="chat-composer-upload-error"
        >
          {Uploads.error_text(error)}
        </p>
        <div
          class="chat-composer-row"
          id="message-composer-row"
          phx-hook=".MessageComposer"
          phx-drop-target={@upload && @upload.ref}
          data-chat-id={@chat && @chat.id}
        >
          <.button
            :if={@upload}
            icon
            id="composer-attach"
            class="chat-composer-attach"
            aria-label={
              dpgettext(
                "chat",
                "aria label: button that opens the file picker in the composer",
                "Attach files"
              )
            }
            title={dgettext("chat", "Attach files (or drop them, or paste images, into the message)")}
          >
            <.lucide name="paperclip" />
          </.button>
          <.live_file_input :if={@upload} upload={@upload} class="chat-composer-file-input" />
          <.editor
            field={@form[:content]}
            id={@editor_id}
            class="chat-composer-input"
            language={if @completions, do: "liquid", else: "markdown"}
            spellcheck
            completions={composer_completions(@completions)}
            rows={2}
            max_rows={10}
            placeholder={
              @placeholder ||
                dpgettext("chat", "placeholder: chat message composer", "Write a message…")
            }
            debounce="300"
            submit_on_enter
          />
          <div
            class="chat-composer-toolbar"
            role="group"
            aria-label={dpgettext("chat", "aria label: composer button group for sending", "Send")}
          >
            <.button
              icon
              id="composer-clear"
              class="chat-composer-clear"
              aria-label={
                dpgettext(
                  "chat",
                  "aria label: icon button that empties the composer",
                  "Clear message"
                )
              }
              title={
                dpgettext("chat", "tooltip: icon button that empties the composer", "Clear message")
              }
            >
              <.lucide name="x" />
            </.button>
            <div class="chat-composer-history">
              <.button
                icon
                size="sm"
                id="composer-history-prev"
                class="chat-composer-history-button"
                aria-label={
                  dpgettext(
                    "chat",
                    "aria label: button that recalls the previous sent message",
                    "Previous sent message"
                  )
                }
                title={
                  dpgettext(
                    "chat",
                    "tooltip: button that recalls the previous sent message",
                    "Previous sent message (Alt+↑)"
                  )
                }
                aria-keyshortcuts="Alt+ArrowUp"
              >
                <.lucide name="chevron-up" />
              </.button>
              <.button
                icon
                size="sm"
                id="composer-history-next"
                class="chat-composer-history-button"
                aria-label={
                  dpgettext(
                    "chat",
                    "aria label: button that recalls the next sent message",
                    "Next sent message"
                  )
                }
                title={
                  dpgettext(
                    "chat",
                    "tooltip: button that recalls the next sent message",
                    "Next sent message (Alt+↓)"
                  )
                }
                aria-keyshortcuts="Alt+ArrowDown"
              >
                <.lucide name="chevron-down" />
              </.button>
            </div>
            <.button
              variant="primary"
              icon
              type="submit"
              id="composer-send"
              class="chat-composer-send"
              aria-label={
                dpgettext(
                  "chat",
                  "aria label: icon button that sends the composed message",
                  "Send message"
                )
              }
              disabled={@send_disabled?}
            >
              <.lucide name="send" />
            </.button>
          </div>
        </div>
        <p :if={@guided?} id="composer-guide-hint" class="chat-composer-hint">
          <.lucide name="sparkles" />
          <.guide_hint refinable?={@refinable?} />
        </p>
      </.form>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".MessageComposer">
        // Shell-style history of sent messages, oldest first, shared by every chat and tab.
        // Drafts never land here: only the server's `composer_sent` and `composer_guided` pushes append.
        const HISTORY_KEY = "mythweaver:composer-history";
        const HISTORY_LIMIT = 200;
        const EDITABLE =
          "input, textarea, select, [contenteditable='true'], [contenteditable=''], .cm-editor";
        // How long a sent message's provisional row waits for its real row before going anyway.
        const PENDING_ROW_MS = 10000;

        function loadHistory() {
          try {
            const parsed = JSON.parse(localStorage.getItem(HISTORY_KEY) ?? "[]");
            return Array.isArray(parsed)
              ? parsed.filter((e) => typeof e === "string")
              : [];
          } catch {
            return [];
          }
        }

        function pushHistory(text) {
          if (typeof text !== "string" || text.trim() === "") return;
          const entries = loadHistory();
          // `ignoredups`: resending the newest entry does not grow the list.
          if (entries[entries.length - 1] === text) return;
          entries.push(text);
          try {
            localStorage.setItem(
              HISTORY_KEY,
              JSON.stringify(entries.slice(-HISTORY_LIMIT)),
            );
          } catch {
            // Quota or privacy mode: history is a convenience, the send already succeeded.
          }
        }

        export default {
          mounted() {
            // Keyboard-only focus ring (see `div.chat-composer-input:focus-within`): remember
            // whether the last navigation input was Tab or a pointer, and mark the row on focus.
            this.tabbed = false;
            this.onTab = (e) => {
              if (e.key === "Tab") this.tabbed = true;
            };
            this.onPointer = () => {
              this.tabbed = false;
            };
            document.addEventListener("keydown", this.onTab, true);
            document.addEventListener("pointerdown", this.onPointer, true);
            this.el.addEventListener("focusin", () => {
              if (this.tabbed) this.el.setAttribute("data-keyboard-focus", "");
            });
            this.el.addEventListener("focusout", () =>
              this.el.removeAttribute("data-keyboard-focus"),
            );
            // The server never renders the attribute; without this a patch would strip it.
            this.js().ignoreAttributes(this.el, ["data-keyboard-focus"]);
            // Leading-edge throttle: the first keystroke pings immediately, then at most once
            // per 2s while typing continues. The server TTL is 5s, so a continuously typing
            // user never expires. A `phx-keyup` + `phx-throttle` binding cannot be used here:
            // the editor's `phx-debounce` would win over `phx-throttle`, so it would fire at 5s.
            this.lastTypingPing = 0;
            this.typing = false;
            this.el.addEventListener("input", (e) => {
              // The editor's hidden textarea; CodeMirror's own contenteditable input also bubbles.
              if (!(e.target instanceof HTMLTextAreaElement)) return;
              if (e.target.value.trim() === "") {
                if (this.typing) {
                  this.typing = false;
                  this.lastTypingPing = 0;
                  this.pushEvent("stop_typing", {});
                }
                return;
              }
              const now = Date.now();
              if (now - this.lastTypingPing < 2000) return;
              this.lastTypingPing = now;
              this.typing = true;
              this.pushEvent("typing", {});
            });
            // Each submit, in order: its text and the provisional row shown for it. The server
            // answers sends in order, so `composer_sent`/`composer_submitted` settle the oldest.
            this.pendingSends = [];
            this.el.closest("form").addEventListener("submit", () => {
              // The server clears the indicator from the `{:message_created, …}` broadcast,
              // so only the throttle needs resetting for the next keystroke.
              this.typing = false;
              this.lastTypingPing = 0;
              this.showPending(this.current());
            });

            // History navigation. `index` is null on the live line, else a position in
            // `entries`, a snapshot taken when leaving the live line; `scratch` is the live
            // line's text, restored on stepping past the newest entry.
            this.index = null;
            this.entries = [];
            this.scratch = "";
            this.chatId = this.el.dataset.chatId;
            this.prev = this.el.querySelector("#composer-history-prev");
            this.next = this.el.querySelector("#composer-history-next");
            // The server never renders `disabled`; without this a patch would strip it.
            this.js().ignoreAttributes(this.prev, ["disabled"]);
            this.js().ignoreAttributes(this.next, ["disabled"]);
            this.prev.addEventListener("click", () => this.older());
            this.next.addEventListener("click", () => this.newer());
            const clear = this.el.querySelector("#composer-clear");
            // Undoable like any edit; also leaves history navigation for the live line.
            clear.addEventListener("click", () => {
              this.setText("");
              this.resetHistory();
            });
            // Tapping a toolbar button must not blur the editor or close a touch keyboard.
            const keepFocus = (e) => e.preventDefault();
            for (const b of [this.prev, this.next, clear])
              b.addEventListener("mousedown", keepFocus);

            // Attachments. The paperclip opens the hidden file input; a click from a user
            // gesture keeps the browser's permission to show the file picker.
            this.fileInput = this.el.querySelector("input[type=file]");
            this.el
              .querySelector("#composer-attach")
              ?.addEventListener("click", () => this.fileInput?.click());
            // Capture phase, `preventDefault` only: CodeMirror skips a default-prevented event
            // (it would otherwise insert a dropped file's bytes as text), while the drop still
            // bubbles to LiveView's `phx-drop-target` handler, which uploads it.
            this.el.addEventListener(
              "drop",
              (e) => {
                if (this.fileInput && e.dataTransfer?.files.length) e.preventDefault();
              },
              true,
            );
            // A pasted image (screenshot, "Copy image") is attached; a paste that carries text
            // stays an ordinary text paste.
            this.el.addEventListener(
              "paste",
              (e) => {
                const data = e.clipboardData;
                const images = [...(data?.files ?? [])].filter((f) =>
                  f.type.startsWith("image/"),
                );
                if (
                  !this.fileInput ||
                  images.length === 0 ||
                  data.types.includes("text/plain")
                )
                  return;
                e.preventDefault();
                const files = new DataTransfer();
                images.forEach((f) => files.items.add(f));
                this.upload(this.fileInput.name, files.files);
              },
              true,
            );
            // Capture phase: CodeMirror binds Alt-ArrowUp/Down (move line) on its content DOM,
            // which sits below this row, so this listener runs first and can swallow the key.
            this.onHistoryKey = (e) => {
              if (!e.altKey || e.ctrlKey || e.metaKey || e.shiftKey) return;
              if (e.key !== "ArrowUp" && e.key !== "ArrowDown") return;
              const editor = this.el.querySelector(".chat-composer-input");
              if (!editor || !editor.contains(e.target)) return;
              e.preventDefault();
              e.stopPropagation();
              if (e.key === "ArrowUp") this.older();
              else this.newer();
            };
            this.el.addEventListener("keydown", this.onHistoryKey, true);
            this.handleEvent("composer_sent", ({ content, message_id }) => {
              pushHistory(content);
              this.resetHistory();
              const send = this.pendingSends[0];
              if (send) Object.assign(send, { sent: true, messageId: message_id });
            });
            // A guided click spent the composer: its text joins history like a send, then the editor empties.
            this.handleEvent("composer_guided", ({ content }) => {
              pushHistory(content);
              this.setText("");
              this.resetHistory();
            });
            // Closes every send: a refused one drops its row and gives the text back.
            this.handleEvent("composer_submitted", () => {
              const send = this.pendingSends.shift();
              if (!send) return;
              if (!send.sent) {
                send.row?.remove();
                this.restore(send.text);
              } else if (send.row && send.messageId) {
                this.dropWhenListed(send.row, send.messageId);
              } else {
                send.row?.remove();
              }
            });
            // Quick replies run on the live text, not the server's debounced copy. Their toolbar
            // sits outside this row, so the listeners go on the form.
            this.form = this.el.closest("form");
            this.runQuickReply = (id) => {
              // Disabled at once, so a tap shows and cannot repeat on a slow link; the server's
              // answer settles them to whether a quick reply really is running (it may refuse).
              const buttons = this.form.querySelectorAll("[data-quick-reply-id]");
              buttons.forEach((b) => (b.disabled = true));
              this.pushEvent("quick_reply", { id, text: this.current() }, () => {
                const running =
                  this.form.querySelector("#quick-replies")?.dataset.running === "true";
                this.form
                  .querySelectorAll("[data-quick-reply-id]")
                  .forEach((b) => (b.disabled = running));
              });
            };
            this.onQuickReply = (e) => {
              const b = e.target.closest("[data-quick-reply-id]");
              if (b && !b.disabled) this.runQuickReply(b.dataset.quickReplyId);
            };
            this.onQuickReplyDown = (e) => {
              if (e.target.closest("[data-quick-reply-id]")) e.preventDefault();
            };
            this.form.addEventListener("click", this.onQuickReply);
            this.form.addEventListener("mousedown", this.onQuickReplyDown);
            // The command palette's entry asks for the text the same way.
            this.handleEvent("quick_reply:collect", ({ id }) => this.runQuickReply(id));
            this.handleEvent("composer:set_text", ({ value }) => {
              this.setText(value);
              this.resetHistory();
            });
            // Type anywhere: a printable key pressed outside any field moves focus to the editor and lands there.
            this.onTypeAnywhere = (e) => {
              if (e.defaultPrevented || e.isComposing) return;
              if (
                (e.metaKey || e.ctrlKey || e.altKey) &&
                !e.getModifierState("AltGraph")
              )
                return;
              if ([...e.key].length !== 1 || e.key === " ") return;
              if (document.activeElement?.closest(EDITABLE)) return;
              if (document.querySelector("dialog[open], [popover]:popover-open"))
                return;
              this.el
                .querySelector(".chat-composer-input")
                ?.dispatchEvent(new CustomEvent("rich-input:focus"));
            };
            document.addEventListener("keydown", this.onTypeAnywhere);
            this.syncButtons();
          },
          updated() {
            // Each chat loads its own draft, so a half-finished navigation must not carry over.
            if (this.el.dataset.chatId !== this.chatId) {
              this.chatId = this.el.dataset.chatId;
              this.resetHistory();
              // The rows belong to the chat left behind; their sends still settle in order.
              for (const send of this.pendingSends) {
                send.row?.remove();
                send.row = null;
                send.text = null;
              }
            }
          },
          destroyed() {
            document.removeEventListener("keydown", this.onTab, true);
            document.removeEventListener("keydown", this.onTypeAnywhere);
            document.removeEventListener("pointerdown", this.onPointer, true);
            this.el.removeEventListener("keydown", this.onHistoryKey, true);
            this.form.removeEventListener("click", this.onQuickReply);
            this.form.removeEventListener("mousedown", this.onQuickReplyDown);
          },
          current() {
            return this.el.querySelector(".chat-composer-input textarea").value;
          },
          // An undoable edit through the editor, so the draft save and typing ping both run.
          setText(value) {
            this.el
              .querySelector(".chat-composer-input")
              .dispatchEvent(
                new CustomEvent("rich-input:replace", { detail: { value } }),
              );
          },
          // Shows `text` as a provisional row (`#message-pending-template`, from `Chat.Messages`;
          // the assistant chat has none) and empties the editor. Every submit is queued, even a
          // blank one, so the server's answers line up with their sends.
          showPending(text) {
            const send = { text, sent: false, messageId: null, row: null };
            this.pendingSends.push(send);
            if (text.trim() === "") return;
            const template = document.getElementById("message-pending-template");
            const list = document.getElementById("messages-pending");
            if (template && list) {
              send.row = template.content.firstElementChild.cloneNode(true);
              send.row.querySelector("[data-pending-text]").textContent = text;
              list.append(send.row);
            }
            // After LiveView's own submit listener, which runs later (it is not on the form), has
            // read the form.
            setTimeout(() => this.setText(""));
          },
          // A refused send's text goes back, ahead of anything typed since.
          restore(text) {
            if (text === null) return;
            const now = this.current();
            if (now === text) return;
            this.setText(now === "" ? text : `${text}\n${now}`);
          },
          // The sent message's row (`messages-<id>`) replaces the provisional one. A window paged
          // away from the newest message never lists it, so the row goes after a while regardless.
          dropWhenListed(row, id) {
            const list = document.getElementById("messages");
            const listed = () => document.getElementById(`messages-${id}`);
            if (!list || listed()) return row.remove();
            const observer = new MutationObserver(() => {
              if (!listed()) return;
              observer.disconnect();
              row.remove();
            });
            observer.observe(list, { childList: true });
            setTimeout(() => {
              observer.disconnect();
              row.remove();
            }, PENDING_ROW_MS);
          },
          older() {
            if (this.index === null) {
              this.entries = loadHistory();
              if (this.entries.length === 0) return;
              this.scratch = this.current();
              this.index = this.entries.length - 1;
            } else if (this.index > 0) {
              this.index--;
            } else {
              return;
            }
            this.setText(this.entries[this.index]);
            this.syncButtons();
          },
          // An edit to a recalled entry is dropped on stepping away; only the live line is kept.
          newer() {
            if (this.index === null) return;
            if (this.index < this.entries.length - 1) {
              this.index++;
              this.setText(this.entries[this.index]);
            } else {
              this.index = null;
              this.setText(this.scratch);
            }
            this.syncButtons();
          },
          resetHistory() {
            this.index = null;
            this.entries = [];
            this.scratch = "";
            this.syncButtons();
          },
          syncButtons() {
            this.prev.disabled =
              this.index === 0 || (this.index === null && loadHistory().length === 0);
            this.next.disabled = this.index === null;
          },
        };
      </script>
    </div>
    """
  end

  attr(:refinable?, :boolean, required: true)

  # The refine button's icon sits mid-sentence, so the translated sentence is split at its marker.
  defp guide_hint(%{refinable?: false} = assigns) do
    ~H"""
    {dgettext(
      "chat",
      "A reply, regenerate or continue click will take the composer's text and attachments as a guide."
    )}
    """
  end

  defp guide_hint(assigns) do
    gettext_comment("%{refine_icon} is replaced by the refine button's pencil icon; keep it where the button is named.")

    [before, after_icon] =
      dgettext(
        "chat",
        "A reply, regenerate or continue click will take the composer's text and attachments as a guide; the %{refine_icon} button on the last reply rewrites it following the text and attachments.",
        refine_icon: @icon_marker
      )
      |> String.split(@icon_marker, parts: 2)

    assigns = assign(assigns, before: before, after_icon: after_icon)

    ~H"""
    {@before}<.lucide name="pencil-sparkles" />{@after_icon}
    """
  end

  # Only the composer runs `{! … !}` blocks, so only it gets Lua completion and hover inside them.
  defp composer_completions(nil), do: nil

  defp composer_completions(completions), do: Map.put(completions, :inline_lua, Completions.lua(:inline))
end
