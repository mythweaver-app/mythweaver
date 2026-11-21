defmodule MythweaverWeb.Chat.MessageAnnotations do
  @moduledoc """
  Rewrite notes on the chat's last character reply (`MythweaverWeb.MainChatLive.Annotations` owns
  their state).

  `annotation_layer/1` is rendered once beside the message list. It holds the popup for the
  passage being annotated, a manual popover tethered by CSS anchor positioning to a proxy element
  (`#annotation-anchor`) that the `.MessageAnnotations` hook moves over the passage's last line, and
  paints every passage with the CSS Custom Highlight API. Without anchor positioning the hook
  places the popup itself. `annotation_panel/1` lists the saved notes under the message's body,
  which is also how assistive tech reads them: the highlights are presentational only.
  """

  use MythweaverWeb, :html

  @quick_actions [
    %{action: :reject, id: "reject", icon: "ban"},
    %{action: :emphasize, id: "emphasize", icon: "megaphone"},
    %{action: :expand, id: "expand", icon: "unfold-vertical"},
    %{action: :shorten, id: "shorten", icon: "fold-vertical"},
    %{action: :keep, id: "keep", icon: "lock"}
  ]

  attr(:annotations, :map, default: nil, doc: "the `:annotations` assign, or nil")

  def annotation_layer(assigns) do
    Iconex.hint(:lucide, ~w[ban megaphone unfold-vertical fold-vertical lock])

    annotations = assigns.annotations

    ranges =
      case annotations do
        nil ->
          []

        %{items: items, draft: draft} ->
          saved = Enum.map(items, &%{start: &1.start, end: &1.end, action: &1.action})

          if draft,
            do: saved ++ [%{start: draft.start, end: draft.end, action: "draft"}],
            else: saved
      end

    assigns =
      assign(assigns,
        ranges: ranges,
        draft: annotations && annotations.draft,
        quick_actions: @quick_actions
      )

    ~H"""
    <%!--
      `lower-bound="none"`: the popup's fields sit inside `<.form>`'s inner block, past its `phx-r`
      root. Every element carrying this block's marker is then a scope root, so root rules are
      class-qualified.
    --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      div.chat-annotation-layer:scope {
        display: contents;
      }

      .chat-annotation-anchor {
        position: fixed;
        anchor-name: --annotation;
        pointer-events: none;
      }

      /* The UA box of a popover is `inset: 0; margin: auto`. */
      .chat-annotation-popover {
        inset: auto;
        margin: var(--size-1);
        padding: 0;
        color: var(--foreground);
        inline-size: min(28rem, calc(100vw - 2 * var(--size-2)));
        background: var(--surface-6);
        border: 1px solid var(--border);
        border-radius: var(--radius-3);
        box-shadow: var(--elevation-lg);
      }

      .chat-annotation-popover[data-wide] {
        inline-size: min(44rem, calc(100vw - 2 * var(--size-2)));
      }

      /* Only while open: on the bare class it would override the closed state's `display: none`. */
      .chat-annotation-popover:popover-open {
        display: flex;
        flex-direction: column;
      }

      @supports (anchor-name: --a) {
        .chat-annotation-popover {
          position-anchor: --annotation;
          position-area: block-end span-inline-end;
          position-try-fallbacks:
            flip-block,
            flip-inline,
            flip-block flip-inline;
        }

        /* Nearly full width: centred across the viewport (`span-all` alone would centre on the
           anchor, then shift to fit), flipping only above or below. */
        @media (--phone) {
          .chat-annotation-popover,
          .chat-annotation-popover[data-wide] {
            position-area: block-end span-all;
            justify-self: center;
            position-try-fallbacks: flip-block;
            inline-size: calc(100vw - 2 * var(--panel-gap));
          }
        }
      }

      .chat-annotation-header,
      .chat-annotation-footer {
        display: flex;
        align-items: center;
        gap: var(--size-1);
        padding: var(--size-2) var(--size-3);
      }

      .chat-annotation-header {
        border-block-end: 1px solid var(--border);
      }

      .chat-annotation-footer {
        border-block-start: 1px solid var(--border);
      }

      .chat-annotation-quote {
        flex: 1;
        min-inline-size: 0;
        color: var(--muted-foreground);
        white-space: nowrap;
        overflow: hidden;
        text-overflow: ellipsis;
      }

      .chat-annotation-popover[data-wide] .chat-annotation-quote {
        white-space: normal;
        max-block-size: 8lh;
        overflow-y: auto;
      }

      .chat-annotation-body {
        padding: var(--size-2) var(--size-3);
      }

      .chat-annotation-error {
        margin: 0;
        padding: 0 var(--size-3) var(--size-2);
        color: var(--destructive);
      }

      .chat-annotation-tool {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        padding: var(--size-1);
        border: 0;
        background: none;
        color: var(--muted-foreground);
        cursor: pointer;
      }

      .chat-annotation-tool:hover {
        color: var(--foreground);
      }

      .chat-annotation-popover:not([data-wide]) .chat-annotation-shrink,
      .chat-annotation-popover[data-wide] .chat-annotation-grow {
        display: none;
      }

      .chat-annotation-rewrite {
        margin-inline-start: auto;
      }

      @media (--coarse) {
        .chat-annotation-tool,
        .chat-annotation-footer .button {
          min-inline-size: var(--touch-target);
        }
      }
    </style>
    <%!-- Highlights paint inside the message bodies, outside this component's scope. --%>
    <style :type={MythweaverWeb.ColocatedCSS}>
      ::highlight(mw-annotation) {
        background-color: color-mix(in oklab, var(--guide) 30%, transparent);
        text-decoration: underline dotted;
      }

      ::highlight(mw-annotation-draft) {
        background-color: color-mix(in oklab, var(--guide) 50%, transparent);
      }

      ::highlight(mw-annotation-reject) {
        background-color: color-mix(in oklab, var(--destructive) 25%, transparent);
        text-decoration: line-through;
      }

      ::highlight(mw-annotation-emphasize) {
        background-color: color-mix(in oklab, var(--primary-accent) 35%, transparent);
        text-decoration: underline;
      }
    </style>
    <%!-- Every draft transition changes `data-ranges`, so the hook's `updated()` runs on each. --%>
    <div
      id="message-annotations-layer"
      class="chat-annotation-layer"
      phx-hook=".MessageAnnotations"
      data-message-id={@annotations && @annotations.message_id}
      data-ranges={Jason.encode!(@ranges)}
    >
      <span
        id="annotation-anchor"
        class="chat-annotation-anchor"
        aria-hidden="true"
        phx-mounted={JS.ignore_attributes(["style"])}
      ></span>
      <%!-- Manual, not auto: light dismiss would close it on a click the server never hears of. --%>
      <dialog
        :if={@draft}
        id="annotation-popover"
        popover="manual"
        class="chat-annotation-popover"
        aria-label={
          dpgettext(
            "chat",
            "aria label: popup for writing a rewrite note on a selected passage",
            "Annotate passage"
          )
        }
        phx-mounted={JS.ignore_attributes(["style", "data-wide"])}
      >
        <.form for={@draft.form} id="annotation-form" phx-submit="save_annotation">
          <div class="chat-annotation-header">
            <span class="chat-annotation-quote" title={@draft.quote}>“{@draft.quote}”</span>
            <button
              type="button"
              class="chat-annotation-tool"
              data-annotation-expand
              aria-label={
                dpgettext(
                  "chat",
                  "aria label: icon button that enlarges the annotation popup",
                  "Expand"
                )
              }
              title={
                dpgettext("chat", "tooltip: icon button that enlarges the annotation popup", "Expand")
              }
            >
              <span class="chat-annotation-grow"><.lucide name="maximize-2" /></span>
              <span class="chat-annotation-shrink"><.lucide name="minimize-2" /></span>
            </button>
            <button
              type="button"
              id="annotation-close"
              class="chat-annotation-tool"
              phx-click="close_annotation"
              aria-label={
                dpgettext("chat", "aria label: icon button that closes the annotation popup", "Close")
              }
              title={
                dpgettext("chat", "tooltip: icon button that closes the annotation popup", "Close")
              }
            >
              <.lucide name="x" />
            </button>
          </div>
          <div class="chat-annotation-body">
            <.editor
              field={@draft.form[:note]}
              id="annotation-form-note"
              language="markdown"
              rows={4}
              max_rows={12}
              placeholder={
                dpgettext("chat", "placeholder: rewrite note on a selected passage", "Add a comment…")
              }
              spellcheck
            />
          </div>
          <p :if={@draft.error} id="annotation-error" class="chat-annotation-error" role="alert">
            {@draft.error}
          </p>
          <div class="chat-annotation-footer">
            <.button
              :for={quick <- @quick_actions}
              type="submit"
              icon
              size="sm"
              id={"annotation-quick-#{quick.id}"}
              name="annotation[action]"
              value={quick.id}
              aria-label={action_label(quick.action)}
              title={action_label(quick.action)}
            >
              <.lucide name={quick.icon} />
            </.button>
            <.button
              type="submit"
              size="sm"
              id="annotation-rewrite"
              class="chat-annotation-rewrite"
              name="annotation[action]"
              value="rewrite"
              title={dgettext("chat", "Save and rewrite the message with all notes")}
            >
              <.lucide name="sparkles" /> {dpgettext(
                "chat",
                "button: save the note and rewrite the message",
                "Rewrite"
              )}
            </.button>
            <.button
              type="submit"
              variant="primary"
              size="sm"
              id="annotation-save"
              name="annotation[action]"
              value="note"
            >
              {dpgettext("chat", "button: save the rewrite note", "Save")}
            </.button>
          </div>
        </.form>
      </dialog>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".MessageAnnotations">
      // Paints the annotated passages of `data-message-id`'s body (`data-ranges`: character offsets
      // into its rendered text, as `Range.toString()` counts them) with the Custom Highlight API,
      // and tethers the popup to the draft passage: `#annotation-anchor` is moved over the passage's
      // last line box and CSS anchor positioning places the popover. Without anchor support the
      // popover is placed here.
      const GAP = 4;
      const NAMES = [
        "mw-annotation",
        "mw-annotation-draft",
        "mw-annotation-reject",
        "mw-annotation-emphasize",
      ];
      const ANCHORED = CSS.supports("anchor-name: --a");

      const clamp = (n, min, max) => Math.min(Math.max(n, min), max);

      export default {
        mounted() {
          this.anchor = this.el.querySelector("#annotation-anchor");
          this.onPlace = () => this.place();
          this.observer = new MutationObserver(() => {
            this.paint();
            this.place();
          });
          // Element scrolls do not bubble, so listen in the capture phase.
          window.addEventListener("scroll", this.onPlace, {
            capture: true,
            passive: true,
          });
          window.addEventListener("resize", this.onPlace);
          this.onClick = (e) => {
            if (!e.target.closest("[data-annotation-expand]")) return;
            const popover = this.popover();
            if (!popover) return;
            popover.toggleAttribute("data-wide");
            this.place();
          };
          // A manual popover has no Escape dismissal of its own.
          this.onKeydown = (e) => {
            const popover = this.popover();
            if (e.key !== "Escape" || !popover?.matches(":popover-open")) return;
            e.preventDefault();
            this.pushEvent("close_annotation", {});
          };
          this.el.addEventListener("click", this.onClick);
          this.el.addEventListener("keydown", this.onKeydown);
          this.sync();
        },
        updated() {
          this.sync();
        },
        destroyed() {
          window.removeEventListener("scroll", this.onPlace, { capture: true });
          window.removeEventListener("resize", this.onPlace);
          this.observer.disconnect();
          if (window.CSS?.highlights)
            NAMES.forEach((name) => CSS.highlights.delete(name));
        },
        popover() {
          return this.el.querySelector("#annotation-popover");
        },
        entries() {
          return JSON.parse(this.el.dataset.ranges || "[]");
        },
        body() {
          const id = this.el.dataset.messageId;
          return id ? document.getElementById(`message-body-${id}`) : null;
        },
        sync() {
          // Body patches recreate text nodes, which detaches the painted ranges.
          const list = document.getElementById("messages");
          if (list !== this.list) {
            this.observer.disconnect();
            this.list = list;
            if (list) {
              this.observer.observe(list, {
                childList: true,
                subtree: true,
                characterData: true,
              });
            }
          }
          this.paint();
          this.place();

          const popover = this.popover();
          const draft = this.entries().find((e) => e.action === "draft");
          const key = draft ? `${draft.start}:${draft.end}` : null;
          if (popover && !popover.matches(":popover-open")) {
            popover.showPopover();
            this.focusNote(popover);
          } else if (popover && key !== this.draftKey) {
            // Another passage opened in the popup still showing: its note starts blank. The editor
            // keeps its own text, so it is cleared here.
            popover
              .querySelector("#annotation-form-note")
              ?.dispatchEvent(
                new CustomEvent("rich-input:replace", { detail: { value: "" } }),
              );
            this.focusNote(popover);
          }
          this.draftKey = key;
        },
        // The editor mounts while the popover is still hidden, so it cannot take focus itself.
        focusNote(popover) {
          requestAnimationFrame(() => {
            const content =
              popover.querySelector(".cm-content") ||
              popover.querySelector("[contenteditable]");
            content?.focus();
          });
        },
        // The text-node `Range` covering `[start, end)` of `body`'s text, or null when it is shorter.
        rangeAt(body, start, end) {
          const walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT);
          const range = document.createRange();
          let pos = 0;
          let started = false;
          let node;
          while ((node = walker.nextNode())) {
            const len = node.data.length;
            if (!started && start < pos + len) {
              range.setStart(node, start - pos);
              started = true;
            }
            if (started && end <= pos + len) {
              range.setEnd(node, end - pos);
              return range;
            }
            pos += len;
          }
          return null;
        },
        paint() {
          if (!window.CSS?.highlights) return;
          NAMES.forEach((name) => CSS.highlights.delete(name));
          const body = this.body();
          if (!body) return;
          const groups = {};
          for (const entry of this.entries()) {
            const range = this.rangeAt(body, entry.start, entry.end);
            if (!range) continue;
            const name =
              {
                draft: "mw-annotation-draft",
                reject: "mw-annotation-reject",
                emphasize: "mw-annotation-emphasize",
              }[entry.action] || "mw-annotation";
            (groups[name] ||= []).push(range);
          }
          for (const [name, ranges] of Object.entries(groups)) {
            const highlight = new Highlight(...ranges);
            // The draft paints over saved notes it overlaps.
            if (name === "mw-annotation-draft") highlight.priority = 1;
            CSS.highlights.set(name, highlight);
          }
        },
        place() {
          const popover = this.popover();
          if (!popover) return;
          const body = this.body();
          const draft = this.entries().find((e) => e.action === "draft");
          const range = body && draft && this.rangeAt(body, draft.start, draft.end);
          const rects = range ? range.getClientRects() : [];
          const last = rects[rects.length - 1];
          // The body is gone: the anchor stays where it was.
          if (!last) return;

          // A passage scrolled out of the list leaves the popup at the list's edge.
          const list = document.getElementById("messages");
          const bounds = list
            ? list.getBoundingClientRect()
            : { top: 0, bottom: window.innerHeight };
          const top = clamp(last.top, bounds.top, bounds.bottom);
          const bottom = clamp(last.bottom, bounds.top, bounds.bottom);
          const style = this.anchor.style;
          style.left = `${last.left}px`;
          style.top = `${top}px`;
          style.width = `${last.width}px`;
          style.height = `${bottom - top}px`;

          if (ANCHORED) return;
          const { offsetWidth: w, offsetHeight: h } = popover;
          const left = clamp(last.left, GAP, window.innerWidth - w - GAP);
          const below = bottom + GAP;
          const y = below + h > window.innerHeight ? top - h - GAP : below;
          popover.style.left = `${left}px`;
          popover.style.top = `${clamp(y, GAP, window.innerHeight - h - GAP)}px`;
        },
      };
    </script>
    """
  end

  attr(:annotations, :map, required: true)
  attr(:message_id, :string, required: true)

  def annotation_panel(assigns) do
    # Each item's icon is picked at runtime; the compiler only sees literals.
    Iconex.hint(:lucide, ~w[message-square-text ban megaphone unfold-vertical fold-vertical lock])

    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      section:scope {
        margin-block-start: var(--size-2);
        padding: var(--size-2);
        border: 1px solid var(--border);
        border-radius: var(--radius-2);
        background: var(--surface-2);
      }

      ol {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
        margin: 0;
        padding: 0;
        list-style: none;
      }

      li {
        display: grid;
        grid-template-columns: auto 1fr auto;
        gap: var(--size-2);
        align-items: start;
      }

      .chat-annotation-text {
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
        min-inline-size: 0;
      }

      q {
        display: -webkit-box;
        -webkit-box-orient: vertical;
        -webkit-line-clamp: 2;
        line-clamp: 2;
        overflow: hidden;
      }

      li[data-action="reject"] q {
        text-decoration: line-through;
      }

      .chat-annotation-action {
        font-size: var(--font-size-0);
        color: var(--muted-foreground);
      }

      p {
        margin: 0;
        white-space: pre-wrap;
        overflow-wrap: anywhere;
      }

      .chat-annotation-icon {
        color: var(--muted-foreground);
        padding-block-start: 0.2em;
      }

      .chat-annotation-remove {
        display: inline-flex;
        padding: var(--size-1);
        border: 0;
        background: none;
        color: var(--muted-foreground);
        cursor: pointer;
      }

      .chat-annotation-remove:hover {
        color: var(--foreground);
      }

      .chat-annotations-actions {
        display: flex;
        justify-content: flex-end;
        gap: var(--size-2);
        margin-block-start: var(--size-2);
      }

      @media (--coarse) {
        .chat-annotation-remove {
          min-inline-size: var(--touch-target);
          min-block-size: var(--touch-target);
          justify-content: center;
          align-items: center;
        }
      }
    </style>
    <section
      id={"message-annotations-#{@message_id}"}
      class="chat-annotations"
      aria-label={
        dpgettext("chat", "aria label: list of rewrite notes on a message", "Rewrite notes")
      }
    >
      <ol>
        <li
          :for={item <- @annotations.items}
          id={"message-annotation-#{item.id}"}
          data-action={item.action}
        >
          <span class="chat-annotation-icon"><.lucide name={action_icon(item.action)} /></span>
          <div class="chat-annotation-text">
            <q>{item.quote}</q>
            <span class="chat-annotation-action">{action_label(item.action)}</span>
            <p :if={item.note}>{item.note}</p>
          </div>
          <button
            type="button"
            class="chat-annotation-remove"
            phx-click="remove_annotation"
            phx-value-id={item.id}
            aria-label={
              dpgettext(
                "chat",
                "aria label: icon button that removes this rewrite note",
                "Remove note"
              )
            }
            title={
              dpgettext("chat", "tooltip: icon button that removes this rewrite note", "Remove note")
            }
          >
            <.lucide name="x" />
          </button>
        </li>
      </ol>
      <div class="chat-annotations-actions">
        <.button size="sm" id="annotations-discard" phx-click="discard_annotations">
          {dpgettext("chat", "button: discard every rewrite note on the message", "Discard notes")}
        </.button>
        <.button variant="primary" size="sm" id="annotations-rewrite" phx-click="rewrite_annotations">
          <.lucide name="pencil-sparkles" /> {dpgettext(
            "chat",
            "button: rewrite the message following its notes",
            "Rewrite with notes"
          )}
        </.button>
      </div>
    </section>
    """
  end

  defp action_icon(:note), do: "message-square-text"
  defp action_icon(action), do: Enum.find(@quick_actions, &(&1.action == action)).icon

  defp action_label(:note), do: dpgettext("chat", "status: rewrite note kind, a free comment", "Note")

  defp action_label(:reject), do: dpgettext("chat", "status: rewrite note kind, drop the passage", "Reject entirely")

  defp action_label(:emphasize), do: dpgettext("chat", "status: rewrite note kind, stress the passage", "Emphasize")

  defp action_label(:expand), do: dpgettext("chat", "status: rewrite note kind, lengthen the passage", "Expand")

  defp action_label(:shorten), do: dpgettext("chat", "status: rewrite note kind, shorten the passage", "Shorten")

  defp action_label(:keep),
    do: dpgettext("chat", "status: rewrite note kind, keep the passage word for word", "Keep verbatim")
end
