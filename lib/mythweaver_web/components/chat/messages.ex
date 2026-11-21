defmodule MythweaverWeb.Chat.Messages do
  @moduledoc """
  The chat body column (`grid-area: body`): the header (auto-mode toggle, reply-queue button,
  resume button while the queue is paused, settings link, and at the far right a red Stop button
  while a reply is in flight), the float under it (a right-docked
  bulk-action panel (tri-state hide from AI, merge, delete, cancel) shown while any message's
  selection checkbox is checked), the scrolling message list of
  forum-style message posts (metadata aside; header with selection checkbox, serial, edit (inline
  editor, saved as a new swipe; double-click the body to edit at that spot, Escape saves)/
  visibility to the AI (hidden posts dim)/split into messages/merge into the previous/delete; footer
  with swipes (plus swipe-history and prompt-inspector buttons), regenerate, continue and split the
  end into a scratchpad (latest message)), the scratchpad dock, the typing indicator, and the
  composer form.

  Every control follows `access` (`MythweaverWeb.Chat.Access`), so a chat guest sees only what the
  server would accept: no settings, memory, variables, injections, jobs, auto mode, selection,
  reattribution, merge, scratchpads, clipping or inspectors; edit and delete on their own messages
  per the guest toggles; swipes and regenerate per `regenerate`. Without a character to post as the
  composer is replaced by `composer_notice`; in round mode a lock holder gets Skip turn.

  Each post's `<li>` carries hooks for user stylesheets only; the app's own CSS never reads them:
  `data-name` (the author's display name), the class `you` (the player's own posts:
  `author_is_player`), `data-type` (the newest swipe's `MessageBody.origin`: `original`, `edit`,
  `regenerate`, `continue`, `refine`, `split`, `merge`, `append`) and `data-swipe-count`. It also
  carries `data-character` (`author_is_character`), which the `.ClipSelection` hook reads to offer
  annotating the last reply.
  """

  use MythweaverWeb, :html

  import MythweaverWeb.Chat.Composer
  import MythweaverWeb.Chat.MessageAnnotations
  import MythweaverWeb.Chat.MessageSplit
  import MythweaverWeb.Chat.Scratchpads

  alias Mythweaver.Attachments
  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Chats.Member
  alias Mythweaver.Expressions.Sprite
  alias Mythweaver.Format
  alias Mythweaver.Messages.Message
  alias Mythweaver.Messages.PromptSnapshot
  alias MythweaverWeb.Chat.Access

  attr :chat, :any, default: nil
  attr :messages, :any, required: true
  attr :empty?, :boolean, default: false
  attr :loading?, :boolean, default: false, doc: "the transcript is still being read (`MessageWindow.open/1`)"
  attr :has_older?, :boolean, default: false, doc: "older messages exist above the loaded window"
  attr :has_newer?, :boolean, default: false, doc: "newer messages exist below the loaded window"
  attr :form, :any, default: nil
  attr :upload, :any, default: nil, doc: "the composer's file upload (`@uploads.composer_files`)"
  attr :composer_attachments, :list, default: [], doc: "images uploaded in the composer, not sent yet"
  attr :editing_attachment_id, :any, default: nil, doc: "the sent image whose description is being edited"
  attr :caption_reviews, :map, default: %{}, doc: "held caption jobs by attachment id (Captions.reviews/2)"
  attr :can_send?, :boolean, default: false
  attr :composer_notice, :string, default: nil, doc: "shown instead of the composer when `can_send?` is false"

  attr :access, Access,
    default: %Access{},
    doc: "what the viewer may do here (`MythweaverWeb.Chat.Access`); a control shows only when allowed"

  attr :viewer_member, :any,
    default: nil,
    doc: "the viewer's `Chats.member_for/2` row; with `model_source: :own` the tools sheet offers My model"

  attr :model_options, :list, default: [], doc: "`AI.model_options/1` of the viewer, for My model"

  attr :skip_turn?, :boolean, default: false, doc: "round mode with the viewer holding a character: offer Skip turn"
  attr :poster_name, :string, default: nil, doc: "shown above the composer when the viewer holds several characters"
  attr :typing, :list, default: []
  attr :ai_typing?, :boolean, default: false, doc: "one of `typing` is a character generating a reply"
  attr :generating?, :boolean, default: false, doc: "true while this chat has a reply in flight"

  attr :turn_state, :map,
    default: %{speaking: nil, queue: [], auto?: false, paused?: false},
    doc: "`Mythweaver.Generation.status/1`: who speaks, who is queued, whether auto mode is on"

  attr :editing_id, :any, default: nil, doc: "id of the message open in the edit form"
  attr :edit_form, :any, default: nil
  attr :avatar_style, :string, default: nil, doc: "`--avatar-max-w`/`--avatar-max-h` for the avatar column"
  attr :avatar_max_width, :integer, default: 300, doc: "the avatar column's max width in px, for `sizes`"
  attr :edit_attachments, :list, default: [], doc: "the attachments the message being edited will have on save"
  attr :edit_upload, :any, default: nil, doc: "the edit form's file upload (@uploads.edit_files)"

  attr :edit_caret, :any,
    default: nil,
    doc: "`{offset, selection_end | nil}` to place in the edit editor (double-click edit), or nil"

  attr :selected, :map, default: %{}, doc: "selected message ids => visible_to_ai"
  attr :split, :map, default: nil, doc: "the open split editor (`MainChatLive.SplitEditor`), or nil"

  attr :annotations, :map,
    default: nil,
    doc: "pending rewrite notes on the last reply (`MainChatLive.Annotations`), or nil"

  attr :reattributing, :map, default: nil, doc: "the message whose author is being changed inline, or nil"

  attr :expression_picker, :map,
    default: nil,
    doc: "the message whose expression is being picked inline (`%{message_id:, labels:, current:}`), or nil"

  attr :scratchpads, :list, default: [], doc: "the chat's scratchpads, oldest first"
  attr :scratchpad_edit, :map, default: nil, doc: "the scratchpad open in its edit form, or nil"
  attr :discarding_scratchpad_id, :any, default: nil, doc: "id of the scratchpad asking to confirm a discard"
  attr :injection_count, :integer, default: 0, doc: "the chat's active (enabled, unspent) injections"
  attr :job_count, :integer, default: 0, doc: "the chat's queued, running and review jobs"
  attr :review_count, :integer, default: 0, doc: "the chat's memory jobs awaiting review"
  attr :reply_job, :any, default: nil, doc: "the chat's queued or running reply job"
  attr :queue_positions, :map, default: %{}, doc: "`Jobs.queue_positions/0`"
  attr :memory_boundary, :integer, default: nil, doc: "position the processed-memory divider follows"

  attr :memory_progress, :map,
    default: nil,
    doc: "`Mythweaver.Memory.Auto.progress/2` for the Memory button's meter; nil hides it"

  attr :guided?, :boolean,
    default: false,
    doc: "composer text or attachments will guide sparkle/regenerate/continue clicks"

  attr :refinable?, :boolean, default: false, doc: "composer text would steer a refine; shows the refine button"

  attr :completions, :map,
    default: nil,
    doc: "template completions for the composer and edit editors; the composer adds inline Lua's"

  attr :quick_replies, :list, default: [], doc: "enabled quick reply scripts, in toolbar order"
  attr :quick_reply_running?, :boolean, default: false, doc: "a quick reply is running; its buttons are disabled"

  attr :embedding_status, :map,
    default: %{on?: false, embedded: MapSet.new()},
    doc: "`Mythweaver.Lore.Embeddings.status/3` over the loaded rows' active bodies; `on?` shows the icons"

  attr :view_hidden?, :boolean,
    default: false,
    doc: "the viewer holds `site.hidden.view` (`Visibility.view_hidden?/1`): reasoning is shown unredacted"

  def messages(assigns) do
    # Runtime-picked icons (auto mode, message visibility, embedding status); the Iconex compiler
    # only sees literals.
    Iconex.hint(:lucide, ~w[play pause eye eye-off waypoints circle-dashed])

    assigns = assign(assigns, :bulk_hidden, bulk_hidden_state(assigns.selected))

    ~H"""
    <%!--
      `lower-bound="none"`: the composer styles `<.input>`'s internals, and that wrapper is a
      nested-component root carrying `phx-r`, which the default exclusive bound would cut off.
      With no lower bound every element carrying this block's scope marker is a scope root,
      including `<.form>`'s inner block root, so the root rule is qualified as `section:scope`.
    --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      /* `--chat-message-header-size` is the sticky message header's height, read by that header,
         by the sticky aside column that parks under it, and by the bulk-action panel that floats
         below it. `1lh` resolves where it is used; all three sit in the same inherited
         line-height. The header never wraps (see `.chat-message-meta`), so one line is exact. */
      section:scope {
        --chat-message-header-size: calc(2 * var(--size-2) + 1lh + 1px);
        grid-area: body;
        display: flex;
        flex-direction: column;
        overflow: hidden;
        background: var(--card);
        border: 1px solid var(--border);
        border-radius: var(--radius-3);
        margin: var(--panel-gap) 0;
        box-shadow: var(--elevation-lg);
      }

      .chat-messages-list {
        flex: 1 1 auto;
        overflow-y: auto;
        list-style: none;
        margin: 0;
        padding: 0;
        display: flex;
        flex-direction: column;
        scrollbar-color: var(--primary-accent) var(--surface-4);
        scrollbar-width: thin;
        overflow-anchor: none;
      }

      .chat-message {
        --chat-message-content-max: 60rem;
        /* The avatar's widest: `--avatar-max-w`, narrowed so its 3:4 box stays within `--avatar-max-h`
           (the `appearance.avatar_max_*` settings, set on the section by `MainChatLive`). */
        --chat-avatar-max: min(
          var(--avatar-max-w, 300px),
          var(--avatar-max-h, 400px) * 3 / 4
        );
        --chat-avatar-column: calc(var(--chat-avatar-max) + 2 * var(--size-2) + 1px);
        display: grid;
        /* The avatar column: 8rem (less if the cap is smaller), growing into whatever the body column
           can't use past its `--chat-message-content-max`, until the avatar reaches its cap (plus the
           aside's padding and border). It never takes width the body could use. */
        grid-template-columns:
          clamp(
            min(8rem, var(--chat-avatar-column)),
            100% - var(--chat-message-content-max),
            var(--chat-avatar-column)
          )
          minmax(0, 1fr);
        grid-template-areas:
          "h h"
          "s b";
        align-items: stretch;
        width: 100%;
        border-top: 1px solid var(--border-grey);
        padding: 0;

        &:first-child {
          border-top: none;
        }

        &:last-child {
          border-bottom: 1px solid var(--border-grey);
        }
      }

      .chat-message-aside {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
        padding: var(--size-2);
        border-inline-end: 1px solid var(--border-grey);
        align-self: start;
        height: 100%;
        grid-area: s;
      }

      /* The aside stretches to the post's height; this inner column is what sticks, parked under
         the sticky header plus the aside's own `--size-2` padding. */
      .chat-message-aside-sticky {
        position: sticky;
        top: calc(var(--chat-message-header-size) + var(--size-2));
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .chat-message-avatar {
        --avatar-radius: var(--radius-2);
        width: 100%;
        aspect-ratio: 3 / 4;
        /* A flex item with `aspect-ratio` would otherwise grow to its image's natural height, and
           the image would not be cropped. */
        min-block-size: 0;
        border-radius: var(--avatar-radius);
      }

      .chat-message-avatar img {
        inline-size: 100%;
        block-size: 100%;
        object-fit: cover;
        /* A file that isn't 3:4 (originals from the `:none` proxy, one another proxy didn't crop)
           keeps the top of the portrait, where the face usually is. */
        object-position: top;
        border-radius: inherit;
      }

      /* An expression sprite is a whole figure, often on a transparent background: never cropped,
         nothing painted behind it. */
      .chat-message-sprite img {
        object-fit: contain;
        object-position: center;
        background: none;
      }

      .chat-message-stats {
        margin: 0;
        display: grid;
        gap: var(--size-1);
        font-size: 0.75rem;
        color: var(--muted-foreground);
      }

      .chat-message-stat {
        display: flex;
        justify-content: space-between;
        gap: var(--size-1);
      }

      .chat-message-stat dt,
      .chat-message-stat dd {
        margin: 0;
      }

      .chat-message-stat dd {
        color: var(--foreground);
        font-variant-numeric: tabular-nums;
      }

      /* Background bookkeeping, not an alert: as quiet as the stats. `anchor-scope` keeps each
         row's breakdown tethered to its own icon, though every icon shares the anchor name. */
      .chat-message-indicators {
        anchor-scope: --chat-message-emotion;
        display: flex;
        align-items: center;
        gap: var(--size-2);
        font-size: 0.75rem;
        color: var(--muted-foreground);
      }

      .chat-message-embedding {
        display: flex;
      }

      /* Interest (hover, focus, long press) shows the breakdown; a tap or click opens it until
         dismissed (`interestfor` plus `popovertarget`, as the account menu does). */
      .chat-message-emotion {
        anchor-name: --chat-message-emotion;
        --interest-delay-start: 0.15s;
        --interest-delay-end: 0.2s;
        interest-delay-start: var(--interest-delay-start);
        interest-delay-end: var(--interest-delay-end);
        display: flex;
        padding: 0;
        border: 0;
        background: none;
        color: inherit;
        font: inherit;
        cursor: help;
      }

      .chat-message-emotion:hover,
      .chat-message-emotion:focus-visible {
        color: var(--foreground);
      }

      .chat-message-emotion:focus-visible {
        outline: 2px solid var(--ring);
        outline-offset: 2px;
        border-radius: var(--radius-1);
      }

      /* In the top layer, so neither the post's `overflow: hidden` nor the phone's `<details>`
         clips it. Without anchor positioning the UA centers it, which still reads fine. */
      .chat-message-emotions {
        margin: var(--size-1);
        inline-size: max-content;
        min-inline-size: 12rem;
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
        .chat-message-emotions {
          inset: auto;
          position-anchor: --chat-message-emotion;
          position-area: block-end span-inline-end;
          position-try-fallbacks:
            flip-block,
            flip-inline,
            flip-block flip-inline;
        }
      }

      .chat-message-emotions-title {
        margin: 0 0 var(--size-1);
        color: var(--muted-foreground);
      }

      .chat-message-emotions-title strong {
        color: var(--foreground);
      }

      .chat-message-emotions-list {
        margin: 0;
        padding: 0;
        list-style: none;
        display: grid;
        grid-template-columns: max-content minmax(4rem, 1fr) max-content;
        align-items: center;
        gap: var(--size-1) var(--size-2);
      }

      .chat-message-emotions-list li {
        display: contents;
      }

      .chat-message-emotions-bar {
        block-size: 0.4rem;
        border-radius: var(--radius-round);
        background: var(--surface-3);
        overflow: hidden;
      }

      .chat-message-emotions-bar span {
        display: block;
        block-size: 100%;
        inline-size: var(--pct);
        background: var(--primary-accent);
      }

      .chat-message-emotions-pct {
        font-variant-numeric: tabular-nums;
        text-align: end;
      }

      .chat-message-emotions-empty {
        margin: 0;
        color: var(--muted-foreground);
      }

      /* Grid stretch makes the post at least as tall as the aside; the footer sits at its bottom. */
      .chat-message-post {
        min-width: 0;
        display: flex;
        flex-direction: column;
        overflow: hidden;
        grid-area: b;
      }

      .chat-message-header {
        position: sticky;
        top: 0;
        z-index: 1;
        box-sizing: border-box;
        block-size: var(--chat-message-header-size);
        background: var(--surface-4);
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: var(--size-2);
        padding: 0 var(--size-2);
        border-bottom: 1px solid var(--border-grey);
        white-space: nowrap;
        grid-area: h;
      }

      /* Reduced motion: a header and avatar column that hold still while the text slides past them
         are themselves motion against the scroll, so both scroll with their post instead. */
      @media (prefers-reduced-motion: reduce) {
        .chat-message-header,
        .chat-message-aside-sticky {
          position: static;
        }
      }

      /* Single line. When space runs out the time gives way first (its much larger shrink weight),
         then the author name; both end in an ellipsis. Serial, badge and actions keep their width. */
      .chat-message-meta {
        display: flex;
        align-items: baseline;
        gap: var(--size-2);
        min-width: 0;
        overflow: hidden;

        & > * {
          flex: none;
        }

        & > :is(.chat-message-author, .chat-message-time) {
          min-width: 0;
          overflow: hidden;
          text-overflow: ellipsis;
        }

        & > .chat-message-author {
          flex: 0 1 auto;
        }

        & > .chat-message-time {
          flex: 0 1000 auto;
        }
      }

      .chat-message-crud {
        flex: none;
      }

      .chat-message-serial {
        font-variant-numeric: tabular-nums;
        color: var(--muted-foreground);
        font-weight: 600;
      }

      .chat-message-author {
        font-weight: 600;
      }

      .chat-message-reattribute {
        display: flex;
        align-items: center;
        gap: var(--size-1);
        min-width: 0;

        & :is(select, input) {
          font-size: inherit;
          max-inline-size: 12rem;
          padding-block: 0;
        }
      }

      .chat-message-time {
        font-size: 0.75rem;
        color: var(--muted-foreground);
      }

      .chat-message-content {
        flex: 1 1 auto;
        padding: var(--size-2) var(--size-3);
        max-inline-size: var(--chat-message-content-max);
      }

      .chat-message-body {
        overflow-wrap: anywhere;
      }

      /* `place-items: stretch` undoes the reset (`assets/css/reset.css`), which centers a
         `figure`'s content and so shrinks the description controls and editor to their content
         width. */
      .chat-message-attachments {
        /* Sent images: a wrapping grid of thumbnails, each with its description controls. */
        display: flex;
        flex-wrap: wrap;
        gap: var(--size-2);
        margin-block-start: var(--size-2);

        figure {
          --max-inline-size: 30rem;
          display: flex;
          flex-direction: column;
          place-items: stretch;
          gap: var(--size-1);
          max-inline-size: var(--max-inline-size);
          margin: 0;

          &:has([open]) {
            max-inline-size: 100%;
          }
        }

        img {
          display: block;
          max-inline-size: var(--max-inline-size);
          block-size: auto;
          border-radius: var(--radius-2);
        }

        figcaption {
          display: flex;
          flex-direction: column;
          align-items: flex-start;
          gap: var(--size-2);
          font-size: var(--font-size-0);
          color: var(--muted-foreground);
        }

        .filename-and-controls {
          display: flex;
          justify-content: space-between;
          width: 100%;
        }

        details {
          width: 100%;
        }

        /* Sent audio, video and other files: players, or a chip linking to the file. */
        audio,
        video {
          max-inline-size: var(--max-inline-size);
        }

        video {
          max-block-size: 20rem;
        }
      }

      /* The edit form's attachments: what the message will have on save, uploads in flight, and
         the paperclip that adds more. */
      .chat-message-edit-attachments {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: var(--size-2);
        margin-block-end: var(--size-2);
      }

      .chat-message-edit-attachments figure {
        position: relative;
        display: flex;
        align-items: center;
        gap: var(--size-1);
        margin: 0;
      }

      .chat-message-edit-attachments img {
        display: block;
        block-size: 96px;
        inline-size: auto;
        object-fit: cover;
        border-radius: var(--radius-2);
      }

      .chat-message-edit-attachment-remove {
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

      .chat-message-edit-file-input {
        position: absolute;
        inline-size: 1px;
        block-size: 1px;
        overflow: hidden;
        clip-path: inset(50%);
      }

      .chat-attachment-status {
        display: inline-flex;
        align-items: center;
        gap: var(--size-1);
      }

      .chat-attachment-caption {
        padding: var(--size-1);
        border: none;
        background: none;
        color: inherit;
        cursor: pointer;
      }

      /* The first icon button after the status takes the free space, pushing the pair right. */
      .chat-attachment-caption:first-of-type {
        margin-inline-start: auto;
      }

      .chat-attachment-file {
        display: inline-flex;
        align-items: center;
        gap: var(--size-2);
        padding: var(--size-2) var(--size-3);
        border: 1px solid var(--border);
        border-radius: var(--radius-2);
        color: var(--foreground);
      }

      .chat-attachment-file {
        align-self: flex-start;
        text-decoration: none;
      }

      .chat-attachment-file--preview {
        flex-direction: column;
        align-items: flex-start;
      }

      /* White behind the page: a PDF with a transparent background stays readable in dark mode. */
      img.chat-attachment-preview {
        display: block;
        max-block-size: 12rem;
        max-inline-size: 100%;
        inline-size: auto;
        border-radius: var(--radius-1);
        background: white;
      }

      .chat-attachment-name {
        overflow-wrap: anywhere;
      }

      .chat-attachment-description-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
        inline-size: 100%;
      }

      .chat-attachment-description-actions {
        display: flex;
        justify-content: flex-end;
        gap: var(--size-1);
      }

      .chat-message-edit {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      /* `scroll-margin-top`: the editor opens with its cursor clear of the sticky message header. */
      div.chat-message-edit-input {
        background: var(--card);
        border: 1px solid var(--border);
        scroll-margin-top: calc(var(--chat-message-header-size) + var(--size-2));
      }

      .chat-message-edit-actions {
        display: flex;
        justify-content: flex-end;
        gap: var(--size-2);
      }

      .chat-message-reasoning {
        margin: 0 0 var(--size-1);
        padding-left: var(--size-2);
        border-left: 2px solid var(--border);
        color: var(--muted-foreground);
        font-size: 0.85rem;
      }

      .chat-message-reasoning-summary {
        cursor: pointer;
        user-select: none;
      }

      .chat-message-reasoning-text {
        margin-top: var(--size-1);
        overflow-wrap: anywhere;
      }

      .chat-message-error {
        margin: var(--size-1) 0 0;
        font-size: 0.8rem;
        color: var(--destructive);
      }

      .chat-message-footer {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: var(--size-2);
        min-block-size: 2rem;
        padding: 0 var(--size-2);
      }

      /* Controls stay visible but dimmed until the post is hovered or holds focus. */
      .chat-message-crud,
      .chat-message-swipes,
      .chat-message-replies {
        display: flex;
        align-items: center;
        gap: var(--size-1);
        opacity: 0.2;
        transition: opacity 150ms ease;
      }

      /* Keeps the reply actions right-aligned when the post has no swipe group. */
      .chat-message-replies {
        margin-inline-start: auto;
      }

      .chat-message:hover
        :is(.chat-message-crud, .chat-message-swipes, .chat-message-replies),
      .chat-message:focus-within
        :is(.chat-message-crud, .chat-message-swipes, .chat-message-replies) {
        opacity: 1;
      }

      .chat-message-action,
      .chat-message-swipe {
        background: none;
        border: 0;
        padding: var(--size-1);
        color: var(--muted-foreground);
        cursor: pointer;
        border-radius: var(--radius-2);
        line-height: 0;
      }

      .chat-message-action:hover:not(:disabled),
      .chat-message-swipe:hover:not(:disabled):not([aria-disabled="true"]) {
        color: var(--foreground);
        background: var(--surface-5);
      }

      /* The composer holds a guide these clicks will follow. The flag sits on the stream container,
         so streamed rows pick it up without re-rendering; after the hover rule so the tint holds. */
      .chat-messages-list[data-guided="true"] .chat-message-guidable {
        color: var(--guide);
      }

      /* Refine rewrites with the composer text as instructions, so it exists only while there is
         some; `display: none` also keeps it out of the tab order. */
      .chat-message-refine {
        display: none;
      }

      .chat-messages-list[data-refinable="true"] .chat-message-refine {
        display: inline-block;
      }

      /* Hidden from the AI: the post dims, and the eye-off toggle stays fully visible so the state
         reads without hovering. */
      .chat-message-hidden :is(.chat-message-aside, .chat-message-post) {
        opacity: 0.5;
      }

      .chat-message-hidden .chat-message-crud {
        opacity: 1;
      }

      /* Regenerate and continue apply only to the newest message (`Generation` refuses older ones
         with `:not_last`); swipes stay navigable everywhere. The last loaded row is not the newest
         while newer messages are unloaded. The chat-wide generating gate sits on the container:
         stream rows are not re-rendered when `@generating?` flips. */
      .chat-message:not(:last-child) .chat-message-replies,
      .chat-messages-list[data-has-newer="true"] .chat-message-replies,
      .chat-messages-list[data-generating="true"] .chat-message-replies {
        display: none;
      }

      .chat-message-swipe:disabled {
        opacity: 0.4;
        cursor: default;
      }

      .chat-message-swipe-count {
        font-size: 0.7rem;
        color: var(--muted-foreground);
        min-width: 2.5ch;
        text-align: center;
      }

      .chat-messages-empty {
        flex: 1 1 auto;
        display: flex;
        align-items: center;
        justify-content: center;
        gap: var(--size-1);
        color: var(--muted-foreground);
      }

      /* A fast load swaps the transcript in before it shows. */
      #messages-loading {
        animation: chat-messages-loading-in 200ms 150ms both;
      }

      @keyframes chat-messages-loading-in {
        from {
          opacity: 0;
        }
      }

      .chat-jump-latest {
        flex: none;
        display: flex;
        align-items: center;
        justify-content: center;
        gap: var(--size-1);
        width: 100%;
        padding: var(--size-1) var(--size-3);
        border: 0;
        border-top: 1px solid var(--border);
        background: var(--surface-4);
        color: var(--primary-accent);
        font-size: 0.85rem;
        cursor: pointer;
      }

      .chat-jump-latest:hover {
        background: var(--surface-5);
      }

      /* Messages the composer just sent (`.MessageComposer`), dimmed until their rows land in the
         list. Capped, so a long one never pushes the list away; empty most of the time. */
      .chat-messages-pending {
        flex: none;
        max-block-size: 30%;
        overflow: hidden;
        margin: 0;
        padding: 0;
        list-style: none;
      }

      .chat-messages-pending:not(:has(> li)) {
        display: none;
      }

      .chat-message-pending {
        opacity: 0.6;
      }

      .chat-message-pending-text {
        white-space: pre-wrap;
      }

      .chat-composer {
        flex: 0 0 auto;
        width: 100%;
        border-top: 1px solid var(--border);
        background: var(--surface-4);
      }

      /* Phones: the composer waits at the bottom of the chat with its top edge `--composer-peek`
         showing (below the typing indicator and reply progress, which stay visible) until swiped up
         (the `EdgeReveal` hook sets `data-reveal-bottom` on `<html>`) or focused. It stays in flow,
         so while shown the list above shrinks and `.MessagesScroll` keeps the newest message in
         view. */
      @media (--phone) {
        .chat-composer {
          --edge-reveal: on;
          --composer-peek: 3px;
        }

        .chat-composer div.chat-composer-body {
          max-block-size: var(--composer-peek);
          overflow: hidden;
        }

        :root[data-reveal-bottom="shown"]
          section:scope
          .chat-composer
          div.chat-composer-body,
        .chat-composer:focus-within div.chat-composer-body {
          max-block-size: none;
          overflow: visible;
        }
      }

      .chat-composer-notice {
        margin: 0;
        color: var(--muted-foreground);
        font-size: 0.85rem;
        text-align: center;
      }

      .chat-composer-poster {
        margin: 0;
        color: var(--muted-foreground);
        font-size: 0.85rem;
      }

      .chat-reply-progress {
        padding: var(--size-1) var(--size-4) 0;
      }

      .chat-typing-indicator {
        display: flex;
        align-items: center;
        gap: var(--size-1);
        min-height: 1.25rem;
        padding: var(--size-2);
        color: var(--muted-foreground);
        font-size: 0.8rem;
        font-style: italic;
      }

      /* `:actions` of the chat's `panel_header`. The bulk panel inside it hangs off the header's
         bottom edge: this wrapper is static, so `.chat-header-float`'s containing block is the
         header. */
      .chat-messages-tools {
        display: flex;
        align-items: center;
        gap: var(--size-2);
      }

      /* Floats over the transcript directly under the header; `z-index` lifts it above the
         `position: relative` message rows that follow it in the DOM. It spans the full width, so it
         passes clicks through and only its children take them. */
      .chat-header-float {
        position: absolute;
        top: 100%;
        left: 0;
        right: 0;
        z-index: 2;
        display: flex;
        flex-direction: column;
        pointer-events: none;

        & > * {
          pointer-events: auto;
        }
      }

      /* Docked at the right, below the sticky message
         header that parks at the top of the list, so neither covers it. No `font-size` here: the
         margin's `1lh` must match the message header's line. */
      .chat-bulk-actions {
        align-self: flex-end;
        display: flex;
        flex-direction: column;
        align-items: stretch;
        gap: var(--size-1);
        margin: calc(var(--chat-message-header-size) + var(--size-3)) var(--size-3) 0
          0;
        padding: var(--size-2);
        background: var(--surface-5);
        border: 1px solid var(--border-grey);
        border-radius: var(--radius-3);
        box-shadow: var(--elevation-lg);
      }

      .chat-bulk-count {
        color: var(--muted-foreground);
        font-size: 0.85rem;
        text-align: center;
      }

      .chat-message-select {
        margin: 0;
        accent-color: var(--primary-accent);
        opacity: 50%;

        &:checked {
          opacity: 100%;
        }
      }

      .chat-message:has(.chat-message-select:checked) {
        background: color-mix(in oklab, var(--primary-accent) 7%, var(--surface-5));
      }

      /* The row a palette jump landed on fades from an accent tint (`.MessagesScroll`). */
      .chat-message-jumped {
        animation: chat-message-jumped 2s ease-out;
      }

      @keyframes chat-message-jumped {
        from {
          background: color-mix(
            in oklab,
            var(--primary-accent) 22%,
            var(--surface-5)
          );
        }
      }

      /* The Memory button's meter toward the next automatic memory: a hairline along its bottom
         edge, inside the border and its rounded corners. */
      .chat-memory-button {
        position: relative;
        overflow: hidden;
      }

      .chat-memory-progress-text {
        font-size: 0.6rem;
      }
      .chat-memory-progress {
        position: absolute;
        inset-inline: 0;
        inset-block-end: 0;
        block-size: 2px;
        background: var(--border-grey);
      }

      .chat-memory-progress::after {
        content: "";
        position: absolute;
        inset: 0;
        background: var(--primary-accent);
        transform-origin: left;
        transform: scaleX(var(--memory-progress));
        transition: transform 300ms ease;
      }

      @media (prefers-reduced-motion: reduce) {
        .chat-memory-progress::after {
          transition: none;
        }
      }

      .memory-boundary {
        grid-column: 1 / -1;
        margin: 0 var(--size-3) var(--size-2);
        padding-top: var(--size-1);
        border-top: 1px dashed var(--primary-accent);
        color: var(--primary-accent);
        font-size: 0.8rem;
        text-align: center;
        box-shadow: 0 -1px 0 var(--border);
      }

      /* A box-less wrapper: the toolbar is a manual popover in the top layer, tethered to the anchor
         the `.ClipSelection` hook moves over the selection's end. */
      div.chat-clip-selection {
        display: contents;
      }

      .chat-clip-selection-anchor {
        position: fixed;
        anchor-name: --clip-selection;
        pointer-events: none;
      }

      /* The UA box of a popover is `inset: 0; margin: auto` with a border and background. */
      .chat-clip-selection-toolbar {
        inset: auto;
        margin: var(--size-1);
        padding: 0;
        border: 0;
        background: none;
        overflow: visible;
      }

      .chat-clip-selection-toolbar:popover-open {
        display: flex;
        gap: var(--size-1);
      }

      .chat-clip-selection-toolbar .button {
        box-shadow: var(--elevation-md);
        background: var(--surface-5);
      }

      @supports (anchor-name: --a) {
        .chat-clip-selection-toolbar {
          position-anchor: --clip-selection;
          position-area: block-end span-inline-end;
          position-try-fallbacks:
            flip-block,
            flip-inline,
            flip-block flip-inline;
        }
      }

      /* Tablet: the picker is a drawer, so the body needs its own left margin (the participants
         rail keeps its own); phones lose the rail too. */
      @media (--tablet) {
        section:scope {
          margin-inline-start: var(--panel-gap);
        }
      }

      @media (--phone) {
        section:scope {
          margin-inline: var(--panel-gap);
        }
      }

      /* Desktop: the sheet's buttons sit in the header row as before. At ≤ 64rem the body column
         (beside the participants rail) is too narrow for them, so they move into the ⋯ sheet. */
      .chat-tools-more {
        display: contents;
        --drawer-padding: var(--size-3);
      }

      .chat-tools-more:popover-open {
        gap: var(--size-2);
      }

      .chat-tools-more:popover-open .button {
        justify-content: flex-start;
      }

      /* Tablets and phones: Stop is the header's one action beside the drawer toggles, as a bare
         icon so a short title keeps the bar to one line. */
      @media (--tablet) {
        .chat-stop-label {
          display: none;
        }

        .chat-stop {
          padding: var(--size-1);
          line-height: 0;
        }

        .chat-messages-tools {
          gap: var(--size-1);
        }
      }

      @media (--coarse) {
        .chat-stop {
          min-inline-size: var(--touch-target);
        }
      }

      /* Touch: no hover, so a message's controls stay out of the way until it is tapped (focused).
         `display: none`, not opacity, so the tap that reveals them cannot land on one. */
      @media (--touch) {
        .chat-message:not(:focus-within)
          :is(.chat-message-crud, .chat-message-swipes, .chat-message-replies) {
          display: none;
        }

        .chat-message:focus {
          outline: none;
        }

        .chat-message:focus-within {
          background: var(--surface-2);
        }
      }

      /* Coarse pointers: 44px controls, so the header row grows instead of overflowing. After the
         `section:scope` rule so the header-size override wins by order. */
      @media (--coarse) {
        section:scope {
          --chat-message-header-size: calc(var(--touch-target) + 1px);
        }

        .chat-message-header {
          block-size: auto;
          min-block-size: var(--chat-message-header-size);
          flex-wrap: wrap;
        }

        .chat-message-crud {
          margin-inline-start: auto;
        }

        .chat-message-action,
        .chat-message-swipe {
          display: inline-flex;
          align-items: center;
          justify-content: center;
          min-inline-size: var(--touch-target);
          min-block-size: var(--touch-target);
        }

        /* The breakdown opens by tap here, so its icon gets a full touch target. */
        .chat-message-emotion {
          align-items: center;
          justify-content: center;
          min-inline-size: var(--touch-target);
          min-block-size: var(--touch-target);
          font-size: 1rem;
        }
      }

      /* Phones: no avatar column; a small round avatar sits beside the name and the stats move
         below the body into a collapsed `<details>`. */
      .chat-message-mini-avatar,
      .chat-message-details {
        display: none;
      }

      @media (--phone) {
        .chat-message {
          grid-template-columns: minmax(0, 1fr);
          grid-template-areas:
            "h"
            "b";
        }

        .chat-message-aside {
          display: none;
        }

        .chat-message-mini-avatar {
          --avatar-radius: var(--radius-round);
          display: inline-block;
          align-self: center;
          inline-size: 1.5rem;
          block-size: 1.5rem;
        }

        .chat-message-mini-avatar img {
          display: block;
          inline-size: 100%;
          block-size: 100%;
          object-fit: cover;
          border-radius: var(--radius-round);
        }

        .chat-message-details {
          display: block;
          padding: 0 var(--size-2) var(--size-1);
          font-size: 0.75rem;
          color: var(--muted-foreground);
        }

        .chat-message-details summary {
          cursor: pointer;
        }
      }

      /* The body leaves its margins to the rails beside it; with a rail hidden from its header
         (`.RailCollapse`) it keeps its own gap. */
      .chat-layout[data-picker-collapsed] section:scope {
        margin-inline-start: var(--panel-gap);
      }
      .chat-layout[data-participants-collapsed] section:scope {
        margin-inline-end: var(--panel-gap);
      }
    </style>

    <%!-- `RangeSelect`: shift-click on a message's select box selects a range (`select_message_range`). --%>
    <section
      id="chat-messages"
      class="chat-messages"
      style={@avatar_style}
      aria-label={dpgettext("chat", "aria label: the chat's message list", "Messages")}
      phx-hook="RangeSelect"
      data-range-event="select_message_range"
    >
      <.panel_header>
        {@chat && Chat.title(@chat)}
        <:actions :if={@chat}>
          <div class="chat-messages-tools">
            <.drawer_toggle
              for="chat-picker"
              breakpoint="tablet"
              label={dpgettext("chat", "aria label: open the chat list drawer", "Chats")}
              id="chat-picker-toggle"
            >
              <.lucide name="panel-left" />
            </.drawer_toggle>
            <.drawer_toggle
              for="chat-participants"
              breakpoint="phone"
              label={dpgettext("chat", "aria label: open the participants drawer", "Participants")}
              id="chat-participants-toggle"
            >
              <.lucide name="users" />
            </.drawer_toggle>
            <.button
              :if={@turn_state.paused? and @access.generate?}
              size="sm"
              id="resume-queue"
              phx-click="resume_queue"
            >
              <.lucide name="step-forward" /> {dpgettext(
                "chat",
                "button: resume the paused reply queue",
                "Resume"
              )}
            </.button>
            <div
              :if={
                @access.generate? or @access.inspect? or @access.manage? or
                  own_models?(@viewer_member)
              }
              id="chat-tools-more"
              class="chat-tools-more drawer drawer--bottom drawer--tablet"
              popover
              data-drawer-actions
              aria-label={
                dpgettext("chat", "aria label: drawer of more chat tools", "More chat tools")
              }
            >
              <.button
                :if={@access.manage?}
                size="sm"
                id="auto-mode-toggle"
                phx-click="toggle_auto_mode"
                aria-pressed={to_string(@turn_state.auto?)}
              >
                <.lucide name={if @turn_state.auto?, do: "pause", else: "play"} />
                {dpgettext("chat", "button: toggle automatic replies", "Auto")}
              </.button>
              <.button :if={@access.generate?} size="sm" id="queue-button" phx-click="open_queue">
                <.lucide name="list-ordered" /> {dpgettext(
                  "chat",
                  "button: open the reply queue",
                  "Queue"
                )}
                <.badge :if={@turn_state.queue != []}>
                  {Format.number(length(@turn_state.queue))}
                </.badge>
              </.button>
              <.button
                :if={@access.inspect?}
                size="sm"
                id="chat-variables-button"
                phx-click="open_chat_variables"
              >
                <.lucide name="variable" /> {dpgettext(
                  "chat",
                  "button: open the chat's variables",
                  "Variables"
                )}
              </.button>
              <.button
                :if={@access.inspect?}
                size="sm"
                id="chat-injections-button"
                phx-click="open_chat_injections"
              >
                <.lucide name="syringe" /> {dpgettext(
                  "chat",
                  "button: open the chat's injections",
                  "Injections"
                )}
                <.badge :if={@injection_count > 0} id="chat-injections-count">
                  {Format.number(@injection_count)}
                </.badge>
              </.button>
              <.button
                :if={@access.inspect?}
                size="sm"
                id="chat-jobs-button"
                navigate={~p"/jobs?chat=#{@chat.id}"}
              >
                <.lucide name="list-checks" /> {dpgettext(
                  "chat",
                  "button: open the chat's jobs",
                  "Jobs"
                )}
                <.badge :if={@job_count > 0} id="chat-jobs-count">{Format.number(@job_count)}</.badge>
              </.button>
              <.button
                :if={@access.inspect?}
                size="sm"
                id="chat-memory-button"
                class="chat-memory-button"
                patch={~p"/chats/#{@chat.id}/memory"}
                title={memory_progress_title(@memory_progress)}
              >
                <.lucide name="brain" /> {dpgettext(
                  "chat",
                  "button: open the chat's memory",
                  "Memory"
                )}
                <span :if={@memory_progress} class="chat-memory-progress-text">{memory_progress_text(
                  @memory_progress
                )}</span>
                <.badge :if={@review_count > 0} id="chat-memory-reviews">
                  {Format.number(@review_count)}
                </.badge>
                <span
                  :if={@memory_progress}
                  id="chat-memory-progress"
                  class="chat-memory-progress"
                  role="progressbar"
                  aria-label={
                    dpgettext(
                      "chat",
                      "aria label: progress toward the next automatic memory",
                      "Next automatic memory"
                    )
                  }
                  aria-valuemin="0"
                  aria-valuemax={@memory_progress.total}
                  aria-valuenow={@memory_progress.done}
                  style={"--memory-progress: #{@memory_progress.done / @memory_progress.total}"}
                ></span>
              </.button>
              <.button
                :if={@access.manage?}
                size="sm"
                patch={~p"/chats/#{@chat.id}/settings"}
                id="chat-settings-button"
              >
                <.lucide name="settings" /> {dpgettext(
                  "chat",
                  "button: open the chat's settings",
                  "Settings"
                )}
              </.button>
              <.form
                :if={own_models?(@viewer_member)}
                for={%{}}
                as={:member_model}
                id="member-model-form"
                phx-change="set_member_model"
              >
                <.input
                  name="member_model[ai_model_id]"
                  type="select"
                  label={
                    dpgettext("chat", "field label: model this member's replies use", "My model")
                  }
                  options={[
                    {dpgettext("chat", "option: member uses their default model", "My default model"),
                     ""}
                    | @model_options
                  ]}
                  value={@viewer_member.ai_model_id || ""}
                  id="member-model-form-ai_model_id"
                />
              </.form>
            </div>
            <.drawer_toggle
              :if={
                @access.generate? or @access.inspect? or @access.manage? or
                  own_models?(@viewer_member)
              }
              for="chat-tools-more"
              breakpoint="tablet"
              label={dpgettext("chat", "aria label: drawer of more chat tools", "More chat tools")}
              id="chat-tools-more-toggle"
            >
              <.lucide name="ellipsis" />
            </.drawer_toggle>
            <.button
              :if={@turn_state.speaking != nil and @access.generate?}
              size="sm"
              danger
              id="stop-generation"
              class="chat-stop"
              phx-click="stop_generation"
              aria-label={
                dpgettext("chat", "aria label: stop the reply being written", "Stop generating")
              }
              aria-keyshortcuts="Escape"
              title={
                dpgettext(
                  "chat",
                  "tooltip: stop the reply being written, with its shortcut",
                  "Stop generating (Esc)"
                )
              }
            >
              <.lucide name="square" /><span class="chat-stop-label">{dpgettext(
                "chat",
                "button: stop the reply being written",
                "Stop"
              )}</span>
            </.button>
            <div :if={@selected != %{}} class="chat-header-float">
              <div
                id="message-bulk-actions"
                class="chat-bulk-actions"
                role="toolbar"
                aria-label={
                  dpgettext(
                    "chat",
                    "aria label: toolbar for the selected messages",
                    "Selected messages"
                  )
                }
              >
                <span class="chat-bulk-count">
                  {dpngettext(
                    "chat",
                    "status: how many messages are selected",
                    "%{message_count} selected",
                    "%{message_count} selected",
                    map_size(@selected),
                    message_count: Format.number(map_size(@selected))
                  )}
                </span>
                <.button
                  size="sm"
                  id="bulk-select-all"
                  phx-click="select_all_messages"
                  title={
                    dpgettext(
                      "chat",
                      "tooltip: select every loaded message",
                      "Select every loaded message"
                    )
                  }
                >
                  <.lucide name="check-check" /> {dpgettext(
                    "chat",
                    "button: select every loaded message",
                    "Select all"
                  )}
                </.button>
                <.button
                  size="sm"
                  id="bulk-toggle-visibility"
                  phx-click="bulk_toggle_visibility"
                  aria-pressed={@bulk_hidden}
                  title={bulk_visibility_title(@bulk_hidden)}
                >
                  <.lucide name="eye-off" /> {dpgettext(
                    "chat",
                    "button: hide the selected messages from the AI",
                    "Hide from AI"
                  )}
                </.button>
                <.button
                  size="sm"
                  id="bulk-create-memory"
                  phx-click="bulk_create_memory"
                  title={dgettext("chat", "Create a memory of the selected span")}
                >
                  <.lucide name="brain" /> {dpgettext(
                    "chat",
                    "button: create a memory of the selected messages",
                    "Create memory"
                  )}
                </.button>
                <.button
                  size="sm"
                  id="bulk-merge-messages"
                  phx-click="bulk_merge_messages"
                  title={dgettext("chat", "Merge the selected messages into the first")}
                >
                  <.lucide name="merge" /> {dpgettext(
                    "chat",
                    "button: merge the selected messages",
                    "Merge"
                  )}
                </.button>
                <.button
                  size="sm"
                  danger
                  id="bulk-delete-messages"
                  phx-click="bulk_delete_messages"
                >
                  <.lucide name="trash" /> {dpgettext(
                    "chat",
                    "button: delete the selected messages",
                    "Delete"
                  )}
                </.button>
                <.button
                  size="sm"
                  id="bulk-clear-selection"
                  phx-click="clear_message_selection"
                  title={dpgettext("chat", "tooltip: clear the message selection", "Uncheck all")}
                >
                  <.lucide name="x" /> {dpgettext(
                    "chat",
                    "button: clear the message selection",
                    "Cancel"
                  )}
                </.button>
              </div>
            </div>
          </div>
        </:actions>
      </.panel_header>

      <div :if={@chat == nil} class="chat-messages-empty">
        {dpgettext("chat", "empty state: no chat is open", "Select a chat")}
      </div>

      <div
        :if={@chat != nil and @loading?}
        id="messages-loading"
        class="chat-messages-empty"
        role="status"
      >
        <.lucide name="loader" /> {dpgettext(
          "chat",
          "status: the chat's messages are loading",
          "Loading messages…"
        )}
      </div>

      <div :if={@chat != nil and @empty? and not @loading?} class="chat-messages-empty">
        {dpgettext("chat", "empty state: chat has no messages", "No messages yet")}
      </div>

      <%!-- The edit form's file input, outside the stream so a row's restream never replaces it. The form itself always renders: a sibling that came and went before #messages made morphdom move the list, which resets its scroll to the top. --%>
      <.form
        for={%{}}
        as={:edit_files}
        id="message-edit-files-form"
        phx-change="validate_edit_files"
      >
        <.live_file_input
          :if={@editing_id && @edit_upload}
          upload={@edit_upload}
          class="chat-message-edit-file-input"
        />
      </.form>

      <%!-- Every slot of a message's radial menu, so a row shows the actions it lacks dimmed.
         Keep in step with the `data-radial-slot`s on the row's controls. --%>
      <.radial_layout :if={@chat != nil} id="message-radial-layout">
        <:item index={0} label={dpgettext("chat", "menu item: edit this message", "Edit message")}>
          <.lucide name="pencil" />
        </:item>
        <:item index={1} label={dgettext("chat", "Rewrite with the composer text as instructions")}>
          <.lucide name="pencil-sparkles" />
        </:item>
        <:item
          index={2}
          label={
            dpgettext("chat", "menu item: continue writing this message", "Continue this message")
          }
        >
          <.lucide name="fast-forward" />
        </:item>
        <:item
          index={4}
          label={dpgettext("chat", "menu item: show this message's next swipe", "Next swipe")}
        >
          <.lucide name="chevron-right" />
        </:item>
        <:item
          index={5}
          label={dpgettext("chat", "menu item: change this message's author", "Change author")}
        >
          <.lucide name="user-pen" />
        </:item>
        <:item
          index={6}
          label={dpgettext("chat", "menu item: set this message's expression", "Set expression")}
        >
          <.lucide name="face-slightly-smiling" />
        </:item>
        <:item
          index={7}
          label={dpgettext("chat", "menu item: hide this message from the AI", "Hide from AI")}
        >
          <.lucide name="eye" />
        </:item>
        <:item index={8} label={dpgettext("chat", "menu item: delete this message", "Delete message")}>
          <.lucide name="trash" />
        </:item>
        <:item index={9} label={dpgettext("chat", "menu item: report this message", "Report message")}>
          <.lucide name="flag" />
        </:item>
        <:item
          index={10}
          label={
            dpgettext("chat", "menu item: inspect the prompt this reply was sent", "Inspect prompt")
          }
        >
          <.lucide name="scan-search" />
        </:item>
        <:item
          index={11}
          label={dpgettext("chat", "menu item: open this message's swipe history", "Swipe history")}
        >
          <.lucide name="list-clock" />
        </:item>
        <:item
          index={12}
          label={dpgettext("chat", "menu item: show this message's previous swipe", "Previous swipe")}
        >
          <.lucide name="chevron-left" />
        </:item>
        <:item
          index={13}
          label={
            dpgettext("chat", "menu item: split this message into several", "Split into messages")
          }
        >
          <.lucide name="scissors-line-dashed" />
        </:item>
        <:item
          index={14}
          label={
            dpgettext(
              "chat",
              "menu item: merge this message into the one before",
              "Merge into previous message"
            )
          }
        >
          <.lucide name="arrow-up-to-line" />
        </:item>
        <:item
          index={15}
          label={dpgettext("chat", "menu item: regenerate this reply", "Regenerate this reply")}
        >
          <.lucide name="rotate-ccw" />
        </:item>
      </.radial_layout>

      <ol
        :if={@chat != nil}
        id="messages"
        class="chat-messages-list"
        phx-update="stream"
        data-generating={to_string(@generating?)}
        data-has-older={to_string(@has_older?)}
        data-has-newer={to_string(@has_newer?)}
        data-guided={to_string(@guided?)}
        data-refinable={to_string(@refinable?)}
        phx-hook=".MessagesScroll"
      >
        <%!-- `row` resolves the active body and what derives from it once per render. --%>
        <%= for {dom_id, message} <- @messages, row <- [row(message, @embedding_status, @view_hidden?)] do %>
          <li
            id={dom_id}
            class={[
              "chat-message",
              not message.visible_to_ai && "chat-message-hidden",
              message.author_is_player && "you"
            ]}
            data-name={author_name(message)}
            data-type={row.last_origin}
            data-swipe-count={row.swipe_count}
            data-character={to_string(message.author_is_character)}
            tabindex="-1"
            data-radial-menu={
              dpgettext("chat", "aria label: radial menu of a message", "Message by %{author_name}",
                author_name: author_name(message)
              )
            }
            data-radial-slots="16"
            data-radial-layout="message-radial-layout"
          >
            <header class="chat-message-header">
              <div class="chat-message-meta">
                <input
                  :if={@access.manage?}
                  type="checkbox"
                  id={"message-select-#{message.id}"}
                  class="chat-message-select"
                  phx-click="toggle_message_selection"
                  phx-value-message_id={message.id}
                  data-range-id={message.id}
                  checked={Map.has_key?(@selected, message.id)}
                  aria-label={
                    dpgettext("chat", "aria label: checkbox selecting a message", "Select message")
                  }
                />
                <span class="chat-message-serial">{serial(message)}</span>
                <%= cond do %>
                  <% reattributing?(message, @reattributing) -> %>
                    <.form
                      for={@reattributing.form}
                      id={"message-reattribute-form-#{message.id}"}
                      class="chat-message-reattribute"
                      phx-change="change_reattribute"
                      phx-submit="save_reattribute"
                    >
                      <.input
                        type="select"
                        field={@reattributing.form[:author]}
                        id={"message-reattribute-author-#{message.id}"}
                        options={
                          @reattributing.author_options ++
                            [
                              {dpgettext(
                                 "chat",
                                 "option: author not in the list, type a name",
                                 "Other…"
                               ), "other"}
                            ]
                        }
                        aria-label={dpgettext("chat", "aria label: author of a message", "Author")}
                      />
                      <.input
                        :if={@reattributing.form[:author].value == "other"}
                        type="text"
                        field={@reattributing.form[:name]}
                        id={"message-reattribute-name-#{message.id}"}
                        placeholder={
                          dpgettext("chat", "placeholder: name of a message's author", "Author name")
                        }
                        aria-label={
                          dpgettext("chat", "aria label: name of a message's author", "Author name")
                        }
                      />
                      <button
                        type="submit"
                        class="chat-message-action"
                        id={"message-reattribute-save-#{message.id}"}
                        aria-label={
                          dpgettext("chat", "aria label: save a message's new author", "Save author")
                        }
                      >
                        <.lucide name="check" />
                      </button>
                      <button
                        type="button"
                        class="chat-message-action"
                        id={"message-reattribute-cancel-#{message.id}"}
                        phx-click="cancel_reattribute"
                        aria-label={
                          dpgettext(
                            "chat",
                            "aria label: cancel changing a message's author",
                            "Cancel"
                          )
                        }
                      >
                        <.lucide name="x" />
                      </button>
                    </.form>
                  <% expression_picking?(message, @expression_picker) -> %>
                    <.form
                      for={%{}}
                      id={"message-expression-form-#{message.id}"}
                      class="chat-message-reattribute"
                      phx-submit="set_expression"
                    >
                      <input type="hidden" name="message_id" value={message.id} />
                      <%= if @expression_picker.labels == [] do %>
                        <span id={"message-expression-empty-#{message.id}"}>
                          {no_sprites(message.author_character_id)}
                        </span>
                      <% else %>
                        <.input
                          type="select"
                          name="expression"
                          id={"message-expression-select-#{message.id}"}
                          options={[
                            {dpgettext(
                               "chat",
                               "option: message shows the portrait, no expression",
                               "Portrait (no expression)"
                             ), ""}
                            | Enum.map(@expression_picker.labels, &{&1, &1})
                          ]}
                          value={@expression_picker.current || ""}
                          aria-label={
                            dpgettext("chat", "aria label: expression of a message", "Expression")
                          }
                        />
                        <button
                          type="submit"
                          class="chat-message-action"
                          id={"message-expression-save-#{message.id}"}
                          aria-label={
                            dpgettext(
                              "chat",
                              "aria label: save a message's expression",
                              "Set expression"
                            )
                          }
                        >
                          <.lucide name="check" />
                        </button>
                      <% end %>
                      <button
                        type="button"
                        class="chat-message-action"
                        id={"message-expression-reclassify-#{message.id}"}
                        phx-click="reclassify_expression"
                        phx-value-message_id={message.id}
                        aria-label={
                          dpgettext(
                            "chat",
                            "aria label: classify a message's expression again",
                            "Classify again"
                          )
                        }
                        title={
                          dpgettext(
                            "chat",
                            "tooltip: classify a message's expression again",
                            "Classify again"
                          )
                        }
                      >
                        <.lucide name="refresh-cw" />
                      </button>
                      <button
                        type="button"
                        class="chat-message-action"
                        id={"message-expression-cancel-#{message.id}"}
                        phx-click="close_expression_picker"
                        aria-label={
                          dpgettext("chat", "aria label: close the expression picker", "Cancel")
                        }
                      >
                        <.lucide name="x" />
                      </button>
                    </.form>
                  <% true -> %>
                    <span class="chat-message-mini-avatar" aria-hidden="true">
                      <.avatar_image
                        avatar={message.author_character}
                        preset={:avatar}
                        sizes="24px"
                        loading="lazy"
                      />
                    </span>
                    <span class="chat-message-author">{author_name(message)}</span>
                    <%!-- Who the user played as when this was sent, not now: switching play-as never re-brands history. --%>
                    <.badge :if={message.author_is_player}>
                      {dpgettext("chat", "badge: message the viewer sent", "You")}
                    </.badge>
                <% end %>

                <.local_time
                  id={"message-time-#{message.id}"}
                  class="chat-message-time"
                  at={message.inserted_at}
                />
              </div>

              <div
                :if={
                  not row.generating? and not editing?(message, @editing_id) and
                    not splitting?(message, @split) and not reattributing?(message, @reattributing) and
                    not expression_picking?(message, @expression_picker)
                }
                class="chat-message-crud"
                role="group"
                aria-label={
                  dpgettext("chat", "aria label: toolbar of one message", "Message actions")
                }
              >
                <button
                  :if={Access.message?(@access, :edit, message)}
                  type="button"
                  class="chat-message-action"
                  id={"message-edit-#{message.id}"}
                  data-radial-item
                  data-radial-slot="0"
                  phx-click="edit_message"
                  phx-value-message_id={message.id}
                  aria-label={dpgettext("chat", "aria label: edit this message", "Edit message")}
                  title={dpgettext("chat", "tooltip: edit this message", "Edit")}
                >
                  <.lucide name="pencil" />
                </button>
                <button
                  :if={@access.manage?}
                  type="button"
                  class="chat-message-action"
                  id={"message-reattribute-#{message.id}"}
                  data-radial-item
                  data-radial-slot="5"
                  phx-click="open_reattribute"
                  phx-value-message_id={message.id}
                  aria-label={
                    dpgettext("chat", "aria label: change this message's author", "Change author")
                  }
                  title={dgettext("chat", "Change author (does not add a swipe)")}
                >
                  <.lucide name="user-pen" />
                </button>
                <button
                  :if={message.author_is_character && message.author_character_id && @access.manage?}
                  type="button"
                  class="chat-message-action"
                  id={"message-expression-#{message.id}"}
                  data-radial-item
                  data-radial-slot="6"
                  phx-click="open_expression_picker"
                  phx-value-message_id={message.id}
                  aria-label={
                    dpgettext("chat", "aria label: set this message's expression", "Set expression")
                  }
                  title={
                    dpgettext("chat", "tooltip: set this message's expression", "Set expression")
                  }
                >
                  <.lucide name="face-slightly-smiling" />
                </button>
                <button
                  :if={Access.message?(@access, :edit, message)}
                  type="button"
                  class="chat-message-action"
                  id={"message-visibility-#{message.id}"}
                  data-radial-item
                  data-radial-slot="7"
                  phx-click="toggle_message_visibility"
                  phx-value-message_id={message.id}
                  aria-pressed={to_string(not message.visible_to_ai)}
                  aria-label={
                    dpgettext("chat", "aria label: hide this message from the AI", "Hide from AI")
                  }
                  title={
                    if message.visible_to_ai,
                      do: dgettext("chat", "Visible to the AI (click to hide)"),
                      else: dgettext("chat", "Hidden from the AI (click to show)")
                  }
                >
                  <.lucide name={if message.visible_to_ai, do: "eye", else: "eye-off"} />
                </button>
                <button
                  :if={Access.message?(@access, :edit, message)}
                  type="button"
                  class="chat-message-action"
                  id={"message-split-open-#{message.id}"}
                  data-radial-item
                  data-radial-slot="13"
                  phx-click="open_split"
                  phx-value-message_id={message.id}
                  phx-value-target="messages"
                  aria-label={
                    dpgettext(
                      "chat",
                      "aria label: split this message into several",
                      "Split into messages"
                    )
                  }
                  title={
                    dpgettext(
                      "chat",
                      "tooltip: split this message into several",
                      "Split into messages"
                    )
                  }
                >
                  <.lucide name="scissors-line-dashed" />
                </button>
                <button
                  :if={@access.manage?}
                  type="button"
                  class="chat-message-action"
                  id={"message-merge-#{message.id}"}
                  data-radial-item
                  data-radial-slot="14"
                  phx-click="merge_into_previous"
                  phx-value-message_id={message.id}
                  aria-label={
                    dpgettext(
                      "chat",
                      "aria label: merge this message into the one before",
                      "Merge into previous message"
                    )
                  }
                  title={
                    dpgettext(
                      "chat",
                      "tooltip: merge this message into the one before",
                      "Merge into previous message"
                    )
                  }
                >
                  <.lucide name="arrow-up-to-line" />
                </button>
                <button
                  :if={Access.message?(@access, :delete, message)}
                  type="button"
                  class="chat-message-action"
                  id={"message-delete-#{message.id}"}
                  data-radial-item
                  data-radial-slot="8"
                  data-radial-danger
                  phx-click="delete_message"
                  phx-value-message_id={message.id}
                  aria-label={dpgettext("chat", "aria label: delete this message", "Delete message")}
                  title={dpgettext("chat", "tooltip: delete this message", "Delete message")}
                >
                  <.lucide name="trash" />
                </button>
                <button
                  :if={Access.message?(@access, :report, message)}
                  type="button"
                  class="chat-message-action"
                  id={"message-report-#{message.id}"}
                  data-radial-item
                  data-radial-slot="9"
                  phx-click="open_report"
                  phx-value-kind="message"
                  phx-value-id={message.id}
                  aria-label={dpgettext("chat", "aria label: report this message", "Report message")}
                  title={dpgettext("chat", "tooltip: report this message", "Report message")}
                >
                  <.lucide name="flag" />
                </button>
              </div>
            </header>

            <aside class="chat-message-aside">
              <div class="chat-message-aside-sticky">
                <div
                  :if={row.sprite}
                  class="chat-message-avatar chat-message-sprite"
                  aria-hidden="true"
                >
                  <.avatar_image
                    avatar={row.sprite}
                    preset={:sprite}
                    sizes={"auto, #{@avatar_max_width}px"}
                    loading="lazy"
                  />
                </div>
                <div :if={!row.sprite} class="chat-message-avatar" aria-hidden="true">
                  <.avatar_image
                    avatar={message.author_character}
                    preset={:portrait}
                    sizes={"auto, #{@avatar_max_width}px"}
                    loading="lazy"
                  />
                </div>
                <.message_stat_list
                  stats={row.stats}
                  embedding={row.embedding}
                  embedding_id={"message-embedding-#{message.id}"}
                  emotions={row.emotions}
                  emotions_id={"message-emotions-#{message.id}"}
                />
              </div>
            </aside>

            <article class="chat-message-post">
              <div class="chat-message-content" data-radial-native>
                <%!-- `open` is server-driven: expanded while only reasoning has streamed, collapsed once
                   reply text lands. Once the user toggles it, `.ReasoningToggle` keeps their choice
                   over the patches every streamed token brings. --%>
                <details
                  :if={row.reasoning not in [nil, ""]}
                  id={"reasoning-#{message.id}"}
                  class="chat-message-reasoning"
                  open={row.reasoning_open?}
                  phx-hook=".ReasoningToggle"
                >
                  <summary class="chat-message-reasoning-summary">
                    {dpgettext("chat", "heading: the model's reasoning before its reply", "Thinking")}
                  </summary>
                  <div class="chat-message-reasoning-text">
                    <.markdown text={row.reasoning} streaming={row.generating?} />
                  </div>
                </details>

                <div
                  :if={not editing?(message, @editing_id) and not splitting?(message, @split)}
                  id={"message-body-#{message.id}"}
                  class="chat-message-body"
                  phx-hook=".MessageBodyEdit"
                  data-message-id={message.id}
                  data-editable={
                    to_string(not row.generating? and Access.message?(@access, :edit, message))
                  }
                >
                  <.markdown
                    id={"message-text-#{message.id}"}
                    text={row.content}
                    streaming={row.generating?}
                    caret={row.generating?}
                  />
                </div>

                <.annotation_panel
                  :if={
                    annotating?(message, @annotations) and not editing?(message, @editing_id) and
                      not splitting?(message, @split)
                  }
                  annotations={@annotations}
                  message_id={message.id}
                />

                <div
                  :if={
                    Message.loaded_attachments(message) != [] and not editing?(message, @editing_id)
                  }
                  id={"message-attachments-#{message.id}"}
                  class="chat-message-attachments"
                >
                  <figure
                    :for={a <- Message.loaded_attachments(message)}
                    id={"attachment-#{a.id}"}
                    class={attachment_figure_class(a.kind)}
                  >
                    <%= case a.kind do %>
                      <% :image -> %>
                        <a href={Attachments.url(a, :original)} target="_blank" rel="noopener">
                          <img
                            id={"attachment-image-#{a.id}"}
                            phx-hook={a.blurhash && "Blurhash"}
                            data-blurhash={a.blurhash}
                            src={Attachments.url(a, :inline)}
                            alt={
                              a.description || a.filename ||
                                dpgettext("chat", "alt text: image attached to a message", "Image")
                            }
                            width={a.width}
                            height={a.height}
                            loading="lazy"
                          />
                        </a>
                      <% :audio -> %>
                        <audio controls preload="metadata" src={Attachments.url(a, :full)}></audio>
                      <% :video -> %>
                        <video
                          controls
                          preload="metadata"
                          src={Attachments.url(a, :full)}
                          poster={Attachments.still_url(a, :inline)}
                        ></video>
                      <% :document -> %>
                        <% preview = Attachments.still_url(a, :thumb) %>
                        <a
                          id={"attachment-link-#{a.id}"}
                          class={["chat-attachment-file", preview && "chat-attachment-file--preview"]}
                          href={Attachments.url(a, :full)}
                          target="_blank"
                          rel="noopener"
                        >
                          <img
                            :if={preview}
                            class="chat-attachment-preview"
                            src={preview}
                            alt=""
                            loading="lazy"
                          />
                          <.lucide name="file-text" /> {a.filename ||
                            dpgettext(
                              "chat",
                              "alt text: unnamed document attached to a message",
                              "Document"
                            )}
                        </a>
                      <% :file -> %>
                        <a
                          id={"attachment-link-#{a.id}"}
                          class="chat-attachment-file"
                          href={Attachments.url(a, :full)}
                          download={a.filename || ""}
                        >
                          <.lucide name="file" /> {a.filename ||
                            dpgettext("chat", "alt text: unnamed file attached to a message", "File")}
                        </a>
                    <% end %>
                    <figcaption :if={a.kind != :file}>
                      <div class="filename-and-controls">
                        <span :if={a.kind in [:audio, :video, :document]} class="chat-attachment-name">
                          {a.filename}
                        </span>
                        <div class="media-button-row">
                          <button
                            type="button"
                            id={"attachment-description-edit-#{a.id}"}
                            class="chat-attachment-caption"
                            phx-click="edit_attachment_description"
                            phx-value-attachment_id={a.id}
                            phx-value-message_id={message.id}
                            aria-label={
                              dpgettext(
                                "chat",
                                "aria label: edit an attachment's description",
                                "Edit description"
                              )
                            }
                            title={
                              dpgettext(
                                "chat",
                                "tooltip: edit an attachment's description",
                                "Edit description"
                              )
                            }
                          >
                            <.lucide name="pencil" />
                          </button>
                          <button
                            type="button"
                            id={"attachment-ask-#{a.id}"}
                            class="chat-attachment-caption"
                            phx-click="ask_caption"
                            phx-value-id={a.id}
                            phx-value-target="sent"
                            aria-label={ask_about_label(a.kind)}
                            title={ask_about_label(a.kind)}
                          >
                            <.lucide name="message-square" />
                          </button>
                          <button
                            type="button"
                            id={"attachment-caption-#{a.id}"}
                            class="chat-attachment-caption"
                            phx-click="caption_attachment"
                            phx-value-attachment_id={a.id}
                            aria-label={describe_again_label(a.kind)}
                            title={describe_again_label(a.kind)}
                          >
                            <.lucide name="refresh-cw" />
                          </button>
                        </div>
                      </div>
                      <%= cond do %>
                        <% @editing_attachment_id == a.id -> %>
                          <.form
                            for={to_form(%{"description" => a.description || ""})}
                            id={"attachment-description-form-#{a.id}"}
                            class="chat-attachment-description-form"
                            phx-submit="save_attachment_description"
                          >
                            <input type="hidden" name="attachment_id" value={a.id} />
                            <input type="hidden" name="message_id" value={message.id} />
                            <.editor
                              name="description"
                              value={a.description || ""}
                              id={"attachment-description-#{a.id}"}
                              rows={3}
                              placeholder={describe_placeholder(a.kind)}
                              autofocus
                            />
                            <div class="chat-attachment-description-actions">
                              <.button
                                size="sm"
                                id={"attachment-description-cancel-#{a.id}"}
                                phx-click="cancel_attachment_description"
                                phx-value-message_id={message.id}
                              >
                                {dpgettext(
                                  "chat",
                                  "button: cancel editing an attachment's description",
                                  "Cancel"
                                )}
                              </.button>
                              <.button size="sm" variant="primary" type="submit">
                                {dpgettext("chat", "button: save an attachment's description", "Save")}
                              </.button>
                            </div>
                          </.form>
                        <% a.caption_status == :review -> %>
                          <%= if job = @caption_reviews[a.id] do %>
                            <.form
                              for={%{}}
                              as={:caption_review}
                              id={"attachment-review-form-#{a.id}"}
                              class="chat-attachment-description-form"
                              phx-submit="approve_caption"
                            >
                              <input type="hidden" name="job_id" value={job.id} />
                              <input type="hidden" name="message_id" value={message.id} />
                              <.editor
                                name="text"
                                value={job.result["text"] || ""}
                                id={"attachment-review-#{a.id}"}
                                rows={3}
                              />
                              <div class="chat-attachment-description-actions">
                                <.button
                                  size="sm"
                                  id={"attachment-review-discard-#{a.id}"}
                                  phx-click="discard_caption"
                                  phx-value-job_id={job.id}
                                  phx-value-message_id={message.id}
                                >
                                  {dpgettext(
                                    "chat",
                                    "button: discard a proposed attachment description",
                                    "Discard"
                                  )}
                                </.button>
                                <.button
                                  size="sm"
                                  id={"attachment-review-retry-#{a.id}"}
                                  phx-click="retry_caption"
                                  phx-value-job_id={job.id}
                                  phx-value-message_id={message.id}
                                >
                                  {dpgettext(
                                    "chat",
                                    "button: describe an attachment again",
                                    "Redescribe"
                                  )}
                                </.button>
                                <.button
                                  size="sm"
                                  variant="primary"
                                  type="submit"
                                  id={"attachment-review-save-#{a.id}"}
                                >
                                  {dpgettext(
                                    "chat",
                                    "button: approve a proposed attachment description",
                                    "Save"
                                  )}
                                </.button>
                              </div>
                            </.form>
                          <% else %>
                            <span class="chat-attachment-status">
                              {dpgettext(
                                "chat",
                                "status: attachment description waiting for review",
                                "Description ready for review…"
                              )}
                            </span>
                          <% end %>
                        <% a.caption_status == :pending -> %>
                          <span class="chat-attachment-status">
                            <.lucide name="loader" />
                            {dpgettext(
                              "chat",
                              "status: attachment description being written",
                              "Describing…"
                            )}
                          </span>
                        <% true -> %>
                          <details :if={a.caption_status == :done}>
                            <summary>
                              {dpgettext(
                                "chat",
                                "heading: an attachment's description",
                                "Description"
                              )}
                            </summary>
                            {a.description}
                          </details>
                          <span
                            :if={a.caption_status == :failed}
                            class="chat-attachment-status"
                            title={a.caption_error}
                          >
                            {dpgettext(
                              "chat",
                              "status: attachment description failed",
                              "Description failed"
                            )}
                          </span>
                      <% end %>
                    </figcaption>
                  </figure>
                </div>

                <.split_editor :if={splitting?(message, @split)} split={@split} />

                <div
                  :if={editing?(message, @editing_id)}
                  id={"message-edit-attachments-#{message.id}"}
                  class="chat-message-edit-attachments"
                >
                  <figure :for={a <- @edit_attachments} id={"message-edit-attachment-#{a.id}"}>
                    <img
                      :if={a.kind == :image}
                      src={Attachments.url(a, :thumb)}
                      alt={
                        a.description || a.filename ||
                          dpgettext("chat", "alt text: image attached to a message", "Image")
                      }
                    />
                    <span :if={a.kind != :image}>
                      <.lucide name="file" /> {a.filename ||
                        dpgettext("chat", "alt text: unnamed file attached to a message", "File")}
                    </span>
                    <button
                      type="button"
                      id={"message-edit-attachment-remove-#{a.id}"}
                      class="chat-message-edit-attachment-remove"
                      phx-click="remove_edit_attachment"
                      phx-value-id={a.id}
                      aria-label={
                        dpgettext(
                          "chat",
                          "aria label: remove an attachment from the edited message",
                          "Remove"
                        )
                      }
                      title={
                        dpgettext(
                          "chat",
                          "tooltip: remove an attachment from the edited message",
                          "Remove"
                        )
                      }
                    >
                      <.lucide name="x" />
                    </button>
                  </figure>
                  <figure
                    :for={entry <- (@edit_upload && @edit_upload.entries) || []}
                    id={"message-edit-upload-#{entry.ref}"}
                  >
                    <.live_img_preview
                      :if={String.starts_with?(entry.client_type, "image/")}
                      entry={entry}
                    />
                    <span :if={!String.starts_with?(entry.client_type, "image/")}>
                      <.lucide name="file" /> {entry.client_name}
                    </span>
                    <progress value={entry.progress} max="100">{Format.percent(entry.progress / 100)}</progress>
                    <span :for={error <- upload_errors(@edit_upload, entry)}>
                      {MythweaverWeb.Uploads.error_text(error)}
                    </span>
                    <button
                      type="button"
                      class="chat-message-edit-attachment-remove"
                      phx-click="cancel_edit_file"
                      phx-value-ref={entry.ref}
                      aria-label={
                        dpgettext(
                          "chat",
                          "aria label: cancel uploading a file",
                          "Remove %{file_name}",
                          file_name: entry.client_name
                        )
                      }
                      title={
                        dpgettext(
                          "chat",
                          "tooltip: remove an attachment from the edited message",
                          "Remove"
                        )
                      }
                    >
                      <.lucide name="x" />
                    </button>
                  </figure>
                  <.button
                    :if={@edit_upload}
                    type="button"
                    icon
                    size="sm"
                    id={"message-edit-attach-#{message.id}"}
                    phx-click={JS.dispatch("click", to: "##{@edit_upload.ref}")}
                    aria-label={
                      dpgettext(
                        "chat",
                        "aria label: attach files to the edited message",
                        "Attach files"
                      )
                    }
                    title={
                      dpgettext("chat", "tooltip: attach files to the edited message", "Attach files")
                    }
                  >
                    <.lucide name="paperclip" />
                  </.button>
                </div>

                <.form
                  :if={editing?(message, @editing_id)}
                  for={@edit_form}
                  id={"message-edit-form-#{message.id}"}
                  class="chat-message-edit"
                  phx-submit="save_message_edit"
                >
                  <.editor
                    field={@edit_form[:content]}
                    id={"message-edit-form-content-#{message.id}"}
                    class="chat-message-edit-input"
                    language="liquid"
                    spellcheck
                    completions={@completions}
                    rows={6}
                    max_rows={24}
                    autofocus
                    caret={@edit_caret && elem(@edit_caret, 0)}
                    caret_end={@edit_caret && elem(@edit_caret, 1)}
                    submit_on_escape
                  />
                  <div class="chat-message-edit-actions">
                    <.button
                      size="sm"
                      id={"message-edit-cancel-#{message.id}"}
                      phx-click="cancel_message_edit"
                    >
                      {dpgettext("chat", "button: cancel editing a message", "Cancel")}
                    </.button>
                    <.button
                      size="sm"
                      type="submit"
                      name="edit_mode"
                      value="in_place"
                      id={"message-edit-in-place-#{message.id}"}
                      title={
                        dpgettext(
                          "chat",
                          "tooltip: save a message edit over the shown swipe",
                          "Overwrite the shown swipe"
                        )
                      }
                    >
                      {dpgettext(
                        "chat",
                        "button: save a message edit over the shown swipe",
                        "Save edits"
                      )}
                    </.button>
                    <.button
                      variant="primary"
                      size="sm"
                      type="submit"
                      id={"message-edit-save-#{message.id}"}
                    >
                      {dpgettext(
                        "chat",
                        "button: save a message edit as a new swipe",
                        "Create new swipe"
                      )}
                    </.button>
                  </div>
                </.form>

                <p :if={row.error} class="chat-message-error" role="status">
                  {row.error}
                </p>
              </div>

              <details
                :if={row.stats != [] || row.embedding || row.emotions}
                id={"message-details-#{message.id}"}
                class="chat-message-details"
                phx-mounted={JS.ignore_attributes(["open"])}
              >
                <summary>
                  {dpgettext("chat", "heading: a message's stats and details", "Details")}
                </summary>
                <.message_stat_list
                  stats={row.stats}
                  embedding={row.embedding}
                  emotions={row.emotions}
                  emotions_id={"message-details-emotions-#{message.id}"}
                />
              </details>

              <footer class="chat-message-footer">
                <div
                  :if={
                    row.swipes? and not editing?(message, @editing_id) and
                      not splitting?(message, @split)
                  }
                  class="chat-message-swipes"
                  role="group"
                  aria-label={dpgettext("chat", "aria label: a message's swipe controls", "Swipes")}
                >
                  <button
                    type="button"
                    class="chat-message-swipe chat-message-swipe--prev"
                    id={"swipe-prev-#{message.id}"}
                    data-radial-item
                    data-radial-slot="12"
                    phx-click="swipe_prev"
                    phx-value-message_id={message.id}
                    disabled={row.swipe_count == 1 or not @access.regenerate?}
                    aria-label={
                      dpgettext(
                        "chat",
                        "aria label: show this message's previous swipe",
                        "Previous swipe"
                      )
                    }
                  >
                    <.lucide name="chevron-left" />
                  </button>

                  <span class="chat-message-swipe-count">
                    {dpgettext(
                      "chat",
                      "status: shown swipe out of all swipes",
                      "%{swipe_number} / %{swipe_count}",
                      swipe_number: Format.number(row.active_index + 1),
                      swipe_count: Format.number(row.swipe_count)
                    )}
                  </span>

                  <button
                    type="button"
                    class="chat-message-swipe chat-message-swipe--next"
                    id={"swipe-next-#{message.id}"}
                    data-radial-item
                    data-radial-slot="4"
                    phx-click="swipe_next"
                    phx-value-message_id={message.id}
                    disabled={row.active_index == row.swipe_count - 1 or not @access.regenerate?}
                    aria-label={
                      dpgettext("chat", "aria label: show this message's next swipe", "Next swipe")
                    }
                  >
                    <.lucide name="chevron-right" />
                  </button>

                  <button
                    :if={row.swipe_count > 1 and @access.inspect?}
                    type="button"
                    class="chat-message-swipe"
                    id={"swipe-history-#{message.id}"}
                    data-radial-item
                    data-radial-slot="11"
                    phx-click="open_swipe_inspector"
                    phx-value-message_id={message.id}
                    aria-label={
                      dpgettext(
                        "chat",
                        "aria label: open this message's swipe history",
                        "Swipe history"
                      )
                    }
                    title={
                      dpgettext("chat", "tooltip: open this message's swipe history", "Swipe history")
                    }
                  >
                    <.lucide name="list-clock" />
                  </button>

                  <button
                    :if={row.snapshot? and @access.inspect?}
                    type="button"
                    class="chat-message-swipe"
                    id={"prompt-inspector-#{message.id}"}
                    data-radial-item
                    data-radial-slot="10"
                    phx-click="open_prompt_inspector"
                    phx-value-message_id={message.id}
                    aria-label={
                      dpgettext(
                        "chat",
                        "aria label: inspect the prompt this reply was sent",
                        "Inspect prompt"
                      )
                    }
                    title={
                      dpgettext(
                        "chat",
                        "tooltip: inspect the prompt this reply was sent",
                        "Inspect prompt"
                      )
                    }
                  >
                    <.lucide name="scan-search" />
                  </button>
                </div>

                <%!--
                Only while the chat is idle: a regenerate mid-stream would race the running generation,
                and flipping the active body while it writes would hide the text being written. The
                chat-idle gate is the `#messages` container's `data-generating` (CSS), because stream
                rows are not re-rendered when `@generating?` flips; the per-message gates stay here.
                CSS also shows the group on the newest message only.
              --%>
                <div
                  :if={
                    message.author_is_character and not row.generating? and @access.regenerate? and
                      not editing?(message, @editing_id) and not splitting?(message, @split)
                  }
                  class="chat-message-replies"
                  role="group"
                  aria-label={
                    dpgettext("chat", "aria label: toolbar of reply actions", "Reply actions")
                  }
                >
                  <button
                    type="button"
                    class="chat-message-action chat-message-guidable"
                    id={"regenerate-#{message.id}"}
                    data-radial-item
                    data-radial-slot="15"
                    phx-click="regenerate"
                    phx-value-message_id={message.id}
                    aria-label={
                      dpgettext("chat", "aria label: regenerate this reply", "Regenerate this reply")
                    }
                    title={
                      dpgettext("chat", "tooltip: regenerate this reply", "Regenerate this reply")
                    }
                  >
                    <.lucide name="rotate-ccw" />
                  </button>
                  <button
                    type="button"
                    class="chat-message-action chat-message-continue chat-message-guidable"
                    id={"continue-#{message.id}"}
                    data-radial-item
                    data-radial-slot="2"
                    phx-click="continue"
                    phx-value-message_id={message.id}
                    aria-label={
                      dpgettext(
                        "chat",
                        "aria label: continue writing this message",
                        "Continue this message"
                      )
                    }
                    title={
                      dpgettext(
                        "chat",
                        "tooltip: continue writing this message",
                        "Continue (adds a swipe)"
                      )
                    }
                  >
                    <.lucide name="fast-forward" />
                  </button>
                  <button
                    type="button"
                    class="chat-message-action chat-message-refine chat-message-guidable"
                    id={"refine-#{message.id}"}
                    data-radial-item
                    data-radial-slot="1"
                    phx-click="refine_message"
                    phx-value-message_id={message.id}
                    aria-label={dgettext("chat", "Rewrite with the composer text as instructions")}
                    title={dgettext("chat", "Rewrite with the composer text as instructions")}
                  >
                    <.lucide name="pencil-sparkles" />
                  </button>
                  <button
                    :if={@access.manage?}
                    type="button"
                    class="chat-message-action"
                    id={"split-scratchpad-#{message.id}"}
                    phx-click="open_split"
                    phx-value-message_id={message.id}
                    phx-value-target="scratchpad"
                    aria-label={dgettext("chat", "Split the end into a scratchpad")}
                    title={dgettext("chat", "Split the end into a scratchpad")}
                  >
                    <.lucide name="notepad-text-dashed" />
                  </button>
                </div>
              </footer>
            </article>
            <div
              :if={@memory_boundary != nil and message.position == @memory_boundary}
              class="memory-boundary"
              id="memory-boundary"
            >
              {dpgettext(
                "chat",
                "status: last message memory has processed",
                "Processed through #%{message_number}",
                message_number: Format.number(message.position + 1)
              )}
            </div>
          </li>
        <% end %>
      </ol>

      <%!-- The hook owns this element: it shows, hides and places the toolbar, so patches leave it alone. --%>
      <div
        :if={@chat != nil and @access.manage?}
        id="clip-selection"
        class="chat-clip-selection"
        phx-hook=".ClipSelection"
        phx-update="ignore"
      >
        <span id="clip-selection-anchor" class="chat-clip-selection-anchor" aria-hidden="true"></span>
        <div
          id="clip-selection-toolbar"
          class="chat-clip-selection-toolbar"
          popover="manual"
          role="group"
          aria-label={dpgettext("chat", "aria label: toolbar for selected text", "Selection actions")}
        >
          <.button
            size="sm"
            icon
            id="clip-selection-button"
            aria-label={
              dpgettext("chat", "aria label: clip the selected text", "Clip the selected text")
            }
            title={dpgettext("chat", "tooltip: clip the selected text", "Clip")}
          >
            <.lucide name="scissors" />
          </.button>
          <.button
            size="sm"
            icon
            id="clip-selection-extract"
            aria-label={dgettext("chat", "Find messages for a topical clip")}
            title={dpgettext("chat", "tooltip: find messages for a topical clip", "Extract")}
          >
            <.lucide name="text-search" />
          </.button>
          <.button
            size="sm"
            icon
            id="clip-selection-annotate"
            aria-label={
              dpgettext(
                "chat",
                "aria label: annotate selected text for a rewrite",
                "Annotate for a rewrite"
              )
            }
            title={dpgettext("chat", "tooltip: annotate selected text for a rewrite", "Annotate")}
            hidden
          >
            <.lucide name="message-square-plus" />
          </.button>
        </div>
      </div>

      <.annotation_layer :if={@chat != nil} annotations={@annotations} />

      <button
        :if={@chat != nil and @has_newer?}
        type="button"
        id="jump-to-latest"
        class="chat-jump-latest"
        phx-click="jump_to_latest"
      >
        <.lucide name="arrow-down" /> {dgettext("chat", "Newer messages not shown. Jump to latest")}
      </button>

      <.scratchpads
        :if={@chat != nil}
        scratchpads={@scratchpads}
        edit={@scratchpad_edit}
        discarding_id={@discarding_scratchpad_id}
      />

      <script :type={Phoenix.LiveView.ColocatedHook} name=".MessagesScroll">
        const NEAR_BOTTOM_PX = 40;
        // Fetch the next page this far before the loaded edge, so it lands before the user reaches it.
        const LOAD_EDGE_PX = 600;
        // Matches `.chat-message-jumped`'s animation.
        const JUMP_FLASH_MS = 2000;
        // A tap's compatibility mouse events follow its touchstart within this long.
        const TAP_MS = 1000;
        // Fields a tap must still focus at its press (the keyboard and caret come from it).
        const TEXT_ENTRY =
          'input:not([type="checkbox"], [type="radio"], [type="button"], [type="submit"]), textarea, select, [contenteditable]';

        export default {
          mounted() {
            this.atBottom = true;
            this.loading = false;
            this.el.addEventListener(
              "scroll",
              () => {
                this.atBottom =
                  this.nearBottom(NEAR_BOTTOM_PX) && !this.flag("hasNewer");
                this.maybeLoad();
              },
              { passive: true },
            );
            // Streaming patches the in-flight row in place, which fires no hook event; follow any
            // growth while pinned. A page load moves the view itself, so pinning waits for it. An open
            // message editor keeps its own cursor in view, so its redraws (cursor blinks, typing) are
            // not growth: following them down would scroll the cursor offscreen.
            const inEditor = (node) =>
              (node.nodeType === Node.ELEMENT_NODE
                ? node
                : node.parentElement
              )?.closest(".cm-editor");
            this.observer = new MutationObserver((records) => {
              if (!this.atBottom || this.loading) return;
              if (records.every((r) => inEditor(r.target))) return;
              this.scrollToBottom();
            });
            this.observer.observe(this.el, {
              childList: true,
              subtree: true,
              characterData: true,
            });
            // The composer grows with its text and shrinks the list from below. Keep the list's
            // bottom edge where it was, so the growing composer never hides the last row's
            // controls: pinned stays pinned, otherwise the view shifts by the height it lost.
            this.height = this.el.clientHeight;
            this.resizeObserver = new ResizeObserver(() => {
              const lost = this.height - this.el.clientHeight;
              this.height = this.el.clientHeight;
              if (lost === 0 || this.loading) return;
              if (this.atBottom) this.scrollToBottom();
              else this.el.scrollTop += lost;
            });
            this.resizeObserver.observe(this.el);
            this.scrollToBottom();
            this.maybeLoad();
            this.handleEvent("scroll_to_bottom", () => {
              this.scrollToBottom();
              this.maybeLoad();
            });
            // Dispatched after the patch that inserted the message, so scrollHeight already
            // includes it. `own` forces the sender's tab down even when scrolled up; the observer
            // handles the pinned case.
            this.handleEvent("message_appended", ({ own }) => {
              if (own) this.scrollToBottom();
            });
            // A palette jump (`jump_to_message`), dispatched after the patch that loaded its row.
            this.handleEvent("scroll_to_message", ({ id }) => this.scrollToMessage(id));
            // Touch shows a message's controls while it holds focus (`(--touch)` CSS). A tap focuses
            // at its mousedown, before its click is hit-tested, so the reveal would push the row's
            // content down under the finger and the click would miss (Details, a link, the select
            // box). An unfocused row therefore skips the press focus and takes focus after the click.
            this.el.addEventListener(
              "touchstart",
              () => {
                this.touchAt = Date.now();
              },
              { passive: true, capture: true },
            );
            const tapped = () => Date.now() - (this.touchAt ?? 0) < TAP_MS;
            this.el.addEventListener("mousedown", (e) => {
              if (!tapped() || e.target.closest(TEXT_ENTRY)) return;
              const row = e.target.closest(".chat-message");
              if (row && !row.matches(":focus-within")) e.preventDefault();
            });
            this.el.addEventListener("click", (e) => {
              if (!tapped()) return;
              const row = e.target.closest(".chat-message");
              if (row && !row.contains(document.activeElement))
                row.focus({ preventScroll: true });
            });
          },
          destroyed() {
            this.observer.disconnect();
            this.resizeObserver.disconnect();
          },
          flag(name) {
            return this.el.dataset[name] === "true";
          },
          nearBottom(px) {
            return (
              this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight <= px
            );
          },
          maybeLoad() {
            if (this.loading) return;
            if (this.flag("hasOlder") && this.el.scrollTop <= LOAD_EDGE_PX) {
              this.load("load_older_messages", this.el.firstElementChild);
            } else if (this.flag("hasNewer") && this.nearBottom(LOAD_EDGE_PX)) {
              this.load("load_newer_messages", this.el.lastElementChild);
            }
          },
          // The reply resolves after its patch: hold the edge row where it was, so neither the new
          // page nor the unloaded far end moves what the user is reading. Then check again, for
          // short pages.
          load(event, anchor) {
            this.loading = true;
            const anchorTop = anchor ? anchor.getBoundingClientRect().top : 0;
            this.pushEvent(event, {})
              .then(() => {
                if (anchor && anchor.isConnected) {
                  this.el.scrollTop += anchor.getBoundingClientRect().top - anchorTop;
                }
                this.loading = false;
                this.maybeLoad();
              })
              .catch(() => {
                this.loading = false;
              });
          },
          scrollToBottom() {
            this.el.scrollTop = this.el.scrollHeight;
            this.atBottom = true;
          },
          // Centres the row, or tops it when it is taller than the list, then flashes it. Unpins
          // first, so the observer does not follow the patch back down. The scroll event that
          // follows pages in more rows around it as usual.
          scrollToMessage(id) {
            const row = document.getElementById(id);
            if (!row || !this.el.contains(row)) return;
            this.atBottom = false;
            const offset =
              row.getBoundingClientRect().top - this.el.getBoundingClientRect().top;
            const slack = Math.max(0, (this.el.clientHeight - row.offsetHeight) / 2);
            this.el.scrollTop += offset - slack;
            this.js().transition(row, "chat-message-jumped", { time: JUMP_FLASH_MS });
          },
        };
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ClipSelection">
        // Shows the selection toolbar just past the end of a text selection that lies inside one
        // message body: a manual popover in the top layer, tethered by CSS anchor positioning to
        // `#clip-selection-anchor`, which is moved over the selection's last line box (without
        // anchor support the toolbar is placed here). Scissors sends the text for the clip dialog,
        // extract opens the topical clip picker searched for it, and annotate (on the chat's last
        // character reply only) opens a rewrite note on the passage. A manual popover with no
        // autofocus descendant takes no focus, so showing it keeps the selection.
        const GAP_PX = 4;

        export default {
          mounted() {
            this.anchor = this.el.querySelector("#clip-selection-anchor");
            this.toolbar = this.el.querySelector("#clip-selection-toolbar");
            this.button = this.el.querySelector("#clip-selection-button");
            this.extract = this.el.querySelector("#clip-selection-extract");
            this.annotate = this.el.querySelector("#clip-selection-annotate");
            this.anchored = CSS.supports("anchor-name: --a");
            this.onChange = () => this.place();
            // Element scrolls do not bubble, so listen in the capture phase.
            document.addEventListener("selectionchange", this.onChange);
            window.addEventListener("scroll", this.onChange, true);
            window.addEventListener("resize", this.onChange);
            this.bind(this.button, "clip_selection");
            this.bind(this.extract, "clip_extract");
            this.annotate.addEventListener("mousedown", (e) => e.preventDefault());
            this.annotate.addEventListener("click", () => {
              const clip = this.selection();
              if (!clip || !this.annotatable(clip.body)) return;
              const { range, body } = clip;
              this.pushEvent("open_annotation", {
                message_id: clip.messageId,
                text: clip.text,
                start: this.textOffset(body, range.startContainer, range.startOffset),
                end: this.textOffset(body, range.endContainer, range.endOffset),
              });
              window.getSelection().removeAllRanges();
              this.hide();
            });
          },
          bind(button, event) {
            // A mousedown would collapse the selection before the click reads it.
            button.addEventListener("mousedown", (e) => e.preventDefault());
            button.addEventListener("click", () => {
              const clip = this.selection();
              if (!clip) return;
              this.pushEvent(event, { text: clip.text, message_id: clip.messageId });
              window.getSelection().removeAllRanges();
              this.hide();
            });
          },
          destroyed() {
            document.removeEventListener("selectionchange", this.onChange);
            window.removeEventListener("scroll", this.onChange, true);
            window.removeEventListener("resize", this.onChange);
          },
          hide() {
            if (this.toolbar.matches(":popover-open")) this.toolbar.hidePopover();
          },
          // The selection's text, message id, body and range, when it starts and ends in one body.
          selection() {
            const sel = window.getSelection();
            if (!sel || sel.isCollapsed || sel.rangeCount === 0) return null;
            const text = sel.toString();
            if (text.trim() === "") return null;
            const body = this.bodyOf(sel.anchorNode);
            if (!body || body !== this.bodyOf(sel.focusNode)) return null;
            return {
              text,
              body,
              messageId: body.dataset.messageId,
              range: sel.getRangeAt(0),
            };
          },
          bodyOf(node) {
            const el =
              node && (node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement);
            const body = el && el.closest(".chat-message-body");
            const list = document.getElementById("messages");
            return body && list && list.contains(body) ? body : null;
          },
          // The chat's last reply, by a character, idle and not being edited: the same gate as the
          // CSS that shows `.chat-message-replies`.
          annotatable(body) {
            const row = body.closest(".chat-message");
            const list = document.getElementById("messages");
            return (
              !!row &&
              !!list &&
              row === list.lastElementChild &&
              row.dataset.character === "true" &&
              list.dataset.generating !== "true" &&
              list.dataset.hasNewer !== "true" &&
              body.dataset.editable === "true"
            );
          },
          // Characters of `body`'s rendered text before `(node, offset)`, as `Range.toString()`
          // counts them; the `.MessageAnnotations` hook maps them back to text nodes.
          textOffset(body, node, offset) {
            const range = document.createRange();
            range.setStart(body, 0);
            range.setEnd(node, offset);
            return range.toString().length;
          },
          place() {
            const clip = this.selection();
            const list = document.getElementById("messages");
            const rects = clip ? clip.range.getClientRects() : [];
            const end = rects[rects.length - 1];
            const bounds = list && list.getBoundingClientRect();
            // Hidden once the selection's end scrolls out of the message list.
            if (!end || end.bottom < bounds.top || end.top > bounds.bottom) {
              this.hide();
              return;
            }
            this.annotate.hidden = !this.annotatable(clip.body);
            const anchor = this.anchor.style;
            anchor.left = `${end.left}px`;
            anchor.top = `${end.top}px`;
            anchor.width = `${end.width}px`;
            anchor.height = `${end.height}px`;
            if (!this.toolbar.matches(":popover-open")) this.toolbar.showPopover();
            if (this.anchored) return;
            const { offsetWidth: w, offsetHeight: h } = this.toolbar;
            const left = Math.min(end.right + GAP_PX, window.innerWidth - w - GAP_PX);
            const below = end.bottom + GAP_PX;
            const top = below + h > window.innerHeight ? end.top - h - GAP_PX : below;
            this.toolbar.style.left = `${Math.max(GAP_PX, left)}px`;
            this.toolbar.style.top = `${top}px`;
          },
        };
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".MessageBodyEdit">
        // How long a text selection captured at a press stays usable for the double-click it began. The
        // double-click's first press collapses the selection before `dblclick` fires, so it is read then.
        const SELECTION_TTL_MS = 800;

        export default {
          mounted() {
            this.el.addEventListener("pointerdown", () => {
              const selection = this.selectionOffsets();
              if (selection) this.pressed = { selection, at: Date.now() };
            });
            this.el.addEventListener("dblclick", (e) => {
              if (this.el.dataset.editable !== "true") return;
              const pressed = this.pressed;
              this.pressed = null;
              const selection =
                pressed && Date.now() - pressed.at < SELECTION_TTL_MS
                  ? pressed.selection
                  : null;
              this.pushEvent(
                "edit_message",
                selection
                  ? { message_id: this.el.dataset.messageId, selection }
                  : {
                      message_id: this.el.dataset.messageId,
                      caret: this.caretOffset(e.clientX, e.clientY),
                    },
              );
            });
          },
          // `[from, to]` source offsets of a non-empty selection wholly inside this body, else null.
          selectionOffsets() {
            const sel = window.getSelection();
            if (!sel || sel.isCollapsed || sel.rangeCount === 0) return null;
            const range = sel.getRangeAt(0);
            const from = this.sourceOffset(range.startContainer, range.startOffset);
            const to = this.sourceOffset(range.endContainer, range.endOffset);
            return from === null || to === null || to <= from ? null : [from, to];
          },
          caretOffset(x, y) {
            let node, offset;
            if (document.caretPositionFromPoint) {
              const p = document.caretPositionFromPoint(x, y);
              if (p) [node, offset] = [p.offsetNode, p.offset];
            } else if (document.caretRangeFromPoint) {
              const r = document.caretRangeFromPoint(x, y);
              if (r) [node, offset] = [r.startContainer, r.startOffset];
            }
            return this.sourceOffset(node, offset);
          },
          // A DOM position as an offset into the message's markdown source, in UTF-16 units (the editor's
          // position unit): every rendered text run carries its source offset as `data-o`
          // (`MythweaverWeb.Markdown`). A position outside any run gives null; the editor clamps an
          // offset past the end.
          sourceOffset(node, offset) {
            if (!node || !this.el.contains(node)) return null;
            let run;
            if (node.nodeType === Node.TEXT_NODE) {
              run = node.parentElement.closest("[data-o]");
              if (!run || !this.el.contains(run)) return null;
              const range = document.createRange();
              range.setStart(run, 0);
              range.setEnd(node, offset);
              return Number(run.dataset.o) + range.toString().length;
            }
            // An element position (past a line's last run): the end of the last run before it.
            const before = offset > 0 ? node.childNodes[offset - 1] : null;
            if (!before || before.nodeType !== Node.ELEMENT_NODE) return null;
            run = before.matches("[data-o]")
              ? before
              : [...before.querySelectorAll("[data-o]")].pop();
            return run ? Number(run.dataset.o) + run.textContent.length : null;
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

      <%!-- What the composer just sent, shown at once by `.MessageComposer` (`composer.ex`) until
      its own row lands in the list above. The hook owns the list, so patches leave it alone. --%>
      <ol
        :if={@chat != nil and @can_send?}
        id="messages-pending"
        class="chat-messages-pending"
        phx-update="ignore"
        aria-live="polite"
      >
      </ol>
      <.pending_message_template
        :if={@chat != nil and @can_send?}
        chat={@chat}
        avatar_max_width={@avatar_max_width}
      />

      <div
        :if={@chat != nil}
        id="chat-composer"
        class="chat-composer"
        phx-hook="EdgeReveal"
        data-edge="bottom"
      >
        <div :if={@typing != []} class="chat-typing-indicator" aria-live="polite">
          <.lucide :if={@ai_typing?} id="chat-typing-ai" name="sparkles" />
          <span>{typing_label(@typing)}</span>
        </div>
        <div :if={@reply_job} class="chat-reply-progress">
          <.job_progress
            id={"chat-reply-progress-#{@reply_job.id}"}
            job={@reply_job}
            position={@queue_positions[@reply_job.id]}
          />
        </div>

        <p :if={!@can_send?} id="chat-composer-notice" class="chat-composer-notice">
          {@composer_notice ||
            dgettext("chat", "Assign a player character to this chat to send messages.")}
        </p>

        <%!-- Round mode: the reply waits for every player; passing lets it go without this one's post. --%>
        <div :if={@skip_turn?} class="chat-composer-turn">
          <.button
            size="sm"
            id="skip-turn"
            phx-click="skip_turn"
            title={dgettext("chat", "Pass this round: the reply need not wait for your message")}
          >
            <.lucide name="skip-forward" /> {dpgettext("chat", "button: pass this round", "Skip turn")}
          </.button>
        </div>

        <p :if={@can_send? and @poster_name} id="chat-composer-poster" class="chat-composer-poster">
          {posting_as(@poster_name)}
        </p>

        <.composer
          :if={@can_send?}
          chat={@chat}
          form={@form}
          upload={@upload}
          composer_attachments={@composer_attachments}
          quick_replies={@quick_replies}
          quick_reply_running?={@quick_reply_running?}
          completions={@completions}
          guided?={@guided?}
          refinable?={@refinable?}
        />
      </div>
    </section>
    """
  end

  defp own_models?(%Member{model_source: :own}), do: true
  defp own_models?(_member), do: false

  attr :chat, Chat, required: true
  attr :avatar_max_width, :integer, required: true

  # A sent message's row as the composer shows it before the server's: the player's avatar and
  # name, "Sending…" where the time goes, and the typed text as plain text (it is rendered on save).
  defp pending_message_template(assigns) do
    player =
      Enum.find_value(assigns.chat.participants, &(&1.character_id == assigns.chat.player_character_id && &1.character))

    assigns = assign(assigns, player: player)

    ~H"""
    <template id="message-pending-template">
      <li class="chat-message you chat-message-pending">
        <header class="chat-message-header">
          <div class="chat-message-meta">
            <span class="chat-message-mini-avatar" aria-hidden="true">
              <.avatar_image avatar={@player} preset={:avatar} sizes="24px" loading="lazy" />
            </span>
            <span class="chat-message-author">
              {(@player && @player.name) ||
                dpgettext("chat", "status: author of a message the viewer is sending", "You")}
            </span>
            <.badge>{dpgettext("chat", "badge: message the viewer sent", "You")}</.badge>
            <span class="chat-message-time">
              {dpgettext("chat", "status: a message on its way to the server", "Sending…")}
            </span>
          </div>
        </header>
        <aside class="chat-message-aside">
          <div class="chat-message-aside-sticky">
            <div class="chat-message-avatar" aria-hidden="true">
              <.avatar_image
                avatar={@player}
                preset={:portrait}
                sizes={"auto, #{@avatar_max_width}px"}
                loading="lazy"
              />
            </div>
          </div>
        </aside>
        <article class="chat-message-post">
          <div class="chat-message-content">
            <div class="chat-message-body chat-message-pending-text" data-pending-text></div>
          </div>
        </article>
      </li>
    </template>
    """
  end

  # A message's stats, embedding icon and emotion breakdown: in the aside on wider screens, in the
  # phone-only `.chat-message-details` below the body. Only the aside's copy carries the embedding
  # id; each copy's breakdown popover needs its own `emotions_id`.
  attr :stats, :list, required: true, doc: "`message_stats/1`'s `{label, value, title}` rows"
  attr :embedding, :atom, default: nil, doc: "`:embedded`, `:pending` or nil (no icon)"
  attr :embedding_id, :string, default: nil
  attr :emotions, :map, default: nil, doc: "`emotions/1`'s breakdown, or nil (no icon)"
  attr :emotions_id, :string, default: nil, doc: "the breakdown popover's id; required with `emotions`"

  defp message_stat_list(assigns) do
    ~H"""
    <dl :if={@stats != []} class="chat-message-stats">
      <div :for={{label, value, title} <- @stats} class="chat-message-stat">
        <dt>{label}</dt>
        <dd title={title}>{value}</dd>
      </div>
    </dl>
    <div :if={@embedding || @emotions} class="chat-message-indicators">
      <span
        :if={@embedding}
        class="chat-message-embedding"
        id={@embedding_id}
        data-embedded={to_string(@embedding == :embedded)}
        title={
          if @embedding == :embedded,
            do:
              dpgettext(
                "chat",
                "tooltip: message is embedded for vector lore matching",
                "Embedded for vector lore"
              ),
            else: dgettext("chat", "Not embedded yet: vector lore can't match this message")
        }
      >
        <.lucide name={if @embedding == :embedded, do: "waypoints", else: "circle-dashed"} />
      </span>
      <%= if @emotions do %>
        <button
          type="button"
          class="chat-message-emotion"
          id={"#{@emotions_id}-toggle"}
          interestfor={@emotions_id}
          popovertarget={@emotions_id}
          popovertargetaction="show"
          aria-label={
            dpgettext("chat", "aria label: a message's emotion scores", "Emotion breakdown")
          }
        >
          <.lucide name="drama" />
        </button>
        <div
          id={@emotions_id}
          class="chat-message-emotions"
          popover="auto"
          aria-label={
            dpgettext("chat", "aria label: a message's emotion scores", "Emotion breakdown")
          }
        >
          <p class="chat-message-emotions-title">
            <%= if @emotions.expression do %>
              {expression_title(@emotions.expression)}
            <% else %>
              {dpgettext(
                "chat",
                "status: message shows the portrait, no expression",
                "Portrait (no expression)"
              )}
            <% end %>
            {if @emotions.source == :manual,
              do: dpgettext("chat", "status: expression was chosen by hand", "· set by hand")}
          </p>
          <ol :if={@emotions.top != []} class="chat-message-emotions-list">
            <li :for={{label, pct} <- @emotions.top}>
              <span>{label}</span>
              <span class="chat-message-emotions-bar"><span style={"--pct: #{pct}%"}></span></span>
              <span class="chat-message-emotions-pct">{Format.percent(pct / 100)}</span>
            </li>
          </ol>
          <p :if={@emotions.top == []} class="chat-message-emotions-empty">
            {dgettext("chat", "No emotion scored above %{zero_percent}.",
              zero_percent: Format.percent(0)
            )}
          </p>
        </div>
      <% end %>
    </div>
    """
  end

  defp posting_as(poster_name) do
    gettext_comment("%{character_name} is the character the viewer posts as, shown in bold.")

    rich(
      dpgettext("chat", "status: character the viewer's next message is posted as", "Posting as %{character_name}",
        character_name: strong(poster_name)
      )
    )
  end

  # Everything a message row derives from its active swipe, resolved once per row render
  # (the streaming row re-renders on every token). A viewer without `site.hidden.view` sees the
  # swipe's redacted reasoning when it has one, as `MainChatLive`'s streamed deltas do.
  defp row(message, embedding_status, view_hidden?) do
    body = Message.active_body(message)
    generating? = match?(%{generating: true}, body)
    content = body && body.content
    count = length(message.bodies)

    %{
      generating?: generating?,
      embedding: embedding(embedding_status, body),
      content: content,
      reasoning: body && shown_reasoning(body, view_hidden?),
      reasoning_open?: generating? and content in [nil, ""],
      error: body && body.error,
      # `bodies_query/0` preloads only the snapshot's id; a body built in memory has it unloaded.
      snapshot?: match?(%{prompt_snapshot: %PromptSnapshot{}}, body),
      stats: message_stats(body),
      swipe_count: count,
      # Bodies are ordered oldest first (`bodies_query/0`), so the last is the newest swipe.
      last_origin: message.bodies |> List.last() |> then(&(&1 && &1.origin)),
      active_index: Enum.find_index(message.bodies, & &1.active) || 0,
      # A character reply always shows its swipe bar (even at 1 / 1) so every reply has the same footer.
      swipes?: not generating? and (message.author_is_character or count > 1),
      # The expression sprite shown in place of the portrait. A body built in memory has it unloaded.
      sprite: sprite(body),
      emotions: emotions(body)
    }
  end

  # A share has no admin bypass, so a `site.hidden.view` holder still sees share-protected values scrubbed.
  defp shown_reasoning(%{reasoning_redacted: redacted}, false) when is_binary(redacted), do: redacted
  defp shown_reasoning(%{reasoning_share_redacted: redacted}, true) when is_binary(redacted), do: redacted
  defp shown_reasoning(body, _view_hidden?), do: body.reasoning

  defp sprite(%{expression_sprite: %Sprite{attachment: %Attachment{status: :ready} = attachment}}), do: attachment
  defp sprite(_body), do: nil

  # The classifier's scores behind the expression, strongest first (the 8 above 0%), with the shown
  # expression and whether it was set by hand. nil until the body was classified.
  defp emotions(%{expression_scores: %{} = scores} = body) when map_size(scores) > 0 do
    top =
      scores
      |> Enum.filter(fn {_label, pct} -> is_number(pct) and pct >= 1 end)
      |> Enum.sort_by(fn {label, pct} -> {-pct, label} end)
      |> Enum.take(8)

    %{expression: body.expression, source: body.expression_source, top: top}
  end

  defp emotions(_body), do: nil

  # nil hides the icon: the chat has no Vector lore, or the body is one `Lore.Embeddings` never embeds
  # (generating or blank).
  defp embedding(%{on?: true, embedded: embedded}, %{generating: false, content: content} = body)
       when is_binary(content) do
    cond do
      String.trim(content) == "" -> nil
      MapSet.member?(embedded, body.id) -> :embedded
      true -> :pending
    end
  end

  defp embedding(_status, _body), do: nil

  defp editing?(message, editing_id), do: editing_id != nil and message.id == editing_id

  defp ask_about_label(:image),
    do:
      dpgettext(
        "chat",
        "aria label: button that asks the caption model about an image attachment",
        "Ask about this image"
      )

  defp ask_about_label(:audio), do: dgettext("chat", "Ask about this audio clip")

  defp ask_about_label(:video),
    do:
      dpgettext(
        "chat",
        "aria label: button that asks the caption model about a video attachment",
        "Ask about this video"
      )

  defp ask_about_label(:document),
    do:
      dpgettext(
        "chat",
        "aria label: button that asks the caption model about a document attachment",
        "Ask about this document"
      )

  defp describe_again_label(:image),
    do: dpgettext("chat", "aria label: describe an attachment again", "Describe image again")

  defp describe_again_label(:audio),
    do: dpgettext("chat", "aria label: describe an attachment again", "Describe audio clip again")

  defp describe_again_label(:video),
    do: dpgettext("chat", "aria label: describe an attachment again", "Describe video again")

  defp describe_again_label(:document),
    do: dpgettext("chat", "aria label: describe an attachment again", "Describe document again")

  defp describe_placeholder(:image),
    do: dpgettext("chat", "placeholder: description of an attachment", "Describe this image")

  defp describe_placeholder(:audio),
    do: dpgettext("chat", "placeholder: description of an attachment", "Describe this audio clip")

  defp describe_placeholder(:video),
    do: dpgettext("chat", "placeholder: description of an attachment", "Describe this video")

  defp describe_placeholder(:document),
    do: dpgettext("chat", "placeholder: description of an attachment", "Describe this document")

  defp no_sprites(character_id) do
    gettext_comment("%{add_sprites_link} is a link to the character's editor, worded by the next entry.")

    rich(
      dgettext("chat", "No sprites for this character. %{add_sprites_link}",
        add_sprites_link:
          navigate_link(
            dpgettext("chat", "link: open the character editor to add sprites", "Add some"),
            ~p"/characters/#{character_id}/edit"
          )
      )
    )
  end

  defp expression_title(expression) do
    gettext_comment("%{expression_name} is the expression label, shown in bold.")

    rich(
      dpgettext("chat", "status: character expression shown on a message", "Expression: %{expression_name}",
        expression_name: strong(expression)
      )
    )
  end

  defp attachment_figure_class(kind) when kind in [:audio, :video], do: "chat-attachment-media"
  defp attachment_figure_class(kind) when kind in [:document, :file], do: "chat-attachment-filefig"
  defp attachment_figure_class(_image), do: nil

  defp reattributing?(message, r), do: r != nil and message.id == r.message_id

  defp expression_picking?(message, picker), do: picker != nil and message.id == picker.message_id

  defp splitting?(message, split), do: split != nil and message.id == split.message_id

  defp annotating?(message, annotations),
    do: annotations != nil and annotations.message_id == message.id and annotations.items != []

  defp serial(%{position: nil}), do: "#—"

  defp serial(%{position: position}),
    do:
      dpgettext("chat", "badge: a message's number in the chat", "#%{message_number}",
        message_number: Format.number(position + 1)
      )

  # `aria-pressed` of the bulk hide button: pressed when every selected message is hidden.
  defp bulk_hidden_state(selected) do
    visible = Map.values(selected)

    cond do
      Enum.all?(visible) -> "false"
      not Enum.any?(visible) -> "true"
      true -> "mixed"
    end
  end

  defp bulk_visibility_title("false"), do: dgettext("chat", "Hide selected from the AI")
  defp bulk_visibility_title("mixed"), do: dgettext("chat", "Some selected are hidden (click to hide all)")
  defp bulk_visibility_title("true"), do: dgettext("chat", "Hidden from the AI (click to show)")

  # The aside's `{label, value, title}` rows, one per figure the active swipe recorded.
  defp message_stats(body) do
    for {_label, value, _title} = stat <- [
          {dpgettext("chat", "field label: tokens a message's reply used", "Tokens"), format_tokens(body), nil},
          {dpgettext("chat", "field label: what a message's reply cost", "Cost"), format_cost(body), cost_title(body)},
          {dpgettext("chat", "field label: how long a message's reply took", "Time"), format_duration(body), nil}
        ],
        value,
        do: stat
  end

  defp format_tokens(%{completion_tokens: tokens}) when is_integer(tokens), do: Format.number(tokens)
  defp format_tokens(_body), do: nil

  defp format_cost(%{cost: %Decimal{} = cost, cost_estimated: true}), do: "≈" <> money(cost)
  defp format_cost(%{cost: %Decimal{} = cost}), do: money(cost)
  defp format_cost(_body), do: nil

  # A nonzero charge under a cent shows as under a cent; anything else is dollars rounded up to the
  # cent, so a shown figure never understates the charge. A reported zero stays "$0.00".
  defp money(cost), do: Format.money(cost, rounding_mode: :ceiling)

  defp cost_title(%{cost_estimated: true}), do: dgettext("chat", "Estimated from the model's per-Mtok prices")
  defp cost_title(_body), do: nil

  defp format_duration(%{generation_ms: ms}) when is_integer(ms), do: Format.duration_ms(ms)
  defp format_duration(_body), do: nil

  defp memory_progress_title(nil), do: nil

  defp memory_progress_title(%{done: total, total: total}),
    do: dpgettext("chat", "tooltip: automatic memory is due to run for this chat", "Automatic memory due")

  defp memory_progress_title(%{unit: :messages, done: done, total: total}) do
    n = total - done

    dngettext(
      "chat",
      "%{message_count} message until the next automatic memory",
      "%{message_count} messages until the next automatic memory",
      n,
      message_count: Format.number(n)
    )
  end

  defp memory_progress_title(%{unit: :tokens, done: done, total: total}) do
    n = total - done

    dngettext(
      "chat",
      "About %{token_count} token until the next automatic memory",
      "About %{token_count} tokens until the next automatic memory",
      n,
      token_count: Format.number(n)
    )
  end

  defp memory_progress_text(%{done: done, total: total}) do
    dpgettext(
      "chat",
      "status: messages or tokens done toward the next automatic memory",
      "(%{done_amount}/%{total_amount})",
      done_amount: Format.number(done),
      total_amount: Format.number(total)
    )
  end

  # The empty case is unreachable: the indicator is rendered under `:if={@typing != []}`.
  defp typing_label([name]),
    do: dpgettext("chat", "status: one person is typing in the chat", "%{person_name} is typing…", person_name: name)

  defp typing_label([a, b]),
    do: dgettext("chat", "%{first_name} and %{second_name} are typing…", first_name: a, second_name: b)

  defp typing_label([a, b | rest]) do
    others = length(rest)

    dngettext(
      "chat",
      "%{first_name}, %{second_name} and %{other_count} other are typing…",
      "%{first_name}, %{second_name} and %{other_count} others are typing…",
      others,
      first_name: a,
      second_name: b,
      other_count: Format.number(others)
    )
  end
end
