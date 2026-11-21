defmodule MythweaverWeb.Chat.SwipeInspector do
  @moduledoc """
  The swipe-history modal opened from a message footer: every swipe of one message on a git-style
  vertical rail, newest on top, the active one highlighted. Each row shows its origin and clamps its
  text to three lines; expanding it reveals the full text, a Make active button, and for edits,
  continues and refines a word-level diff against the swipe it was derived from.

  `#N` is the 1-based position in `message.bodies` (`Messages.bodies_query/0` order), so it matches
  the footer's `N / M` counter.
  """

  use MythweaverWeb, :html

  attr :inspector, :map, required: true

  def swipe_inspector(assigns) do
    %{message: message, expanded: expanded, diff: diff} = assigns.inspector
    bodies = message.bodies
    numbered = Enum.with_index(bodies, 1)
    by_id = Map.new(bodies, &{&1.id, &1})

    rows =
      for {body, n} <- Enum.reverse(numbered) do
        {body, n, body.id == expanded, MapSet.member?(diff, body.id), diffable?(body, by_id)}
      end

    assigns =
      assign(assigns,
        rows: rows,
        by_id: by_id,
        number_by_id: Map.new(numbered, fn {body, n} -> {body.id, n} end),
        generating?: Enum.any?(bodies, & &1.generating)
      )

    ~H"""
    <%!-- `lower-bound="none"`: the content lives inside `<.modal>`'s slot, a nested component root. --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      /* The `<ol>` is a slot root carrying this block's scope marker, so it must be `ol:scope`. */
      ol:scope {
        list-style: none;
        margin: 0;
        padding: 0;
      }

      .swipe-row {
        position: relative;
        padding-inline-start: var(--size-5);
        padding-block-end: var(--size-1);
      }

      /* The rail: one segment per row, trimmed at both ends so it stops at the end dots. */
      .swipe-row::before {
        content: "";
        position: absolute;
        inset-inline-start: calc(var(--size-2) - 1px);
        top: 0;
        bottom: 0;
        inline-size: 2px;
        background: var(--border-grey);
      }

      .swipe-row:first-child::before {
        top: var(--size-3);
      }

      .swipe-row:last-child::before {
        bottom: auto;
        height: var(--size-3);
      }

      .swipe-row:only-child::before {
        display: none;
      }

      /* The commit dot, centered on the rail. */
      .swipe-row::after {
        content: "";
        position: absolute;
        inset-inline-start: calc(var(--size-2) - 0.375rem);
        top: calc(var(--size-3) - 0.375rem);
        inline-size: 0.75rem;
        block-size: 0.75rem;
        box-sizing: border-box;
        border-radius: 50%;
        background: var(--card);
        border: 2px solid var(--muted-foreground);
      }

      .swipe-row--active::after {
        background: var(--primary-accent);
        border-color: var(--primary-accent);
      }

      /* Always 1px so expanding does not shift the row; only the expanded row's border shows. */
      .swipe-row-card {
        border: 1px solid transparent;
        border-radius: var(--radius-2);
      }

      .swipe-row--expanded .swipe-row-card {
        border-color: var(--border-grey);
      }

      /* The toggle and the expanded row's actions side by side; buttons cannot nest, so the
         header (not the toggle) carries the row's background. */
      .swipe-row-header {
        display: flex;
        align-items: center;
        gap: var(--size-2);
        border-radius: var(--radius-2);
        padding: var(--size-2);
      }

      .swipe-row--expanded .swipe-row-header {
        border-bottom-left-radius: 0;
        border-bottom-right-radius: 0;
      }

      .swipe-row--active .swipe-row-header {
        background: var(--surface-4);
      }

      .swipe-row-header:has(.swipe-row-toggle:hover) {
        background: var(--surface-5);
      }

      .swipe-row-toggle {
        display: flex;
        flex: 1 1 auto;
        flex-direction: column;
        gap: var(--size-1);
        min-inline-size: 0;
        text-align: start;
        background: none;
        border: 0;
        padding: var(--size-2);
        color: inherit;
        font: inherit;
        cursor: pointer;
      }

      .swipe-row-head {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: var(--size-2);
        font-size: 0.85rem;
        color: var(--muted-foreground);
      }

      .swipe-row-number,
      .swipe-row-origin {
        color: var(--foreground);
        font-weight: 600;
      }

      .swipe-row-preview {
        display: -webkit-box;
        -webkit-box-orient: vertical;
        -webkit-line-clamp: 3;
        line-clamp: 3;
        overflow: hidden;
        white-space: pre-wrap;
        overflow-wrap: anywhere;
      }

      .swipe-row-detail {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
        padding: var(--size-2);
      }

      .swipe-row-actions {
        display: flex;
        flex: none;
        gap: var(--size-2);
        padding-inline-end: var(--size-2);
      }

      .swipe-row-text {
        white-space: pre-wrap;
        overflow-wrap: anywhere;
        padding: var(--size-2);
      }

      .swipe-row-guide {
        margin: 0;
        white-space: pre-wrap;
        color: var(--muted-foreground);
        font-size: 0.85rem;
      }

      .swipe-row-guide-attachments {
        display: flex;
        flex-wrap: wrap;
        gap: var(--size-2);
      }

      .swipe-row-guide-attachments img {
        display: block;
        block-size: 64px;
        inline-size: auto;
        border-radius: var(--radius-2);
      }

      .swipe-row-guide-file {
        display: inline-flex;
        align-items: center;
        gap: var(--size-1);
        color: var(--muted-foreground);
      }

      .swipe-row-error {
        margin: 0;
        color: var(--destructive);
      }
    </style>

    <.modal
      id="swipe-inspector-modal"
      title={dpgettext("chat", "heading: modal listing every swipe of a message", "Swipe history")}
      on_cancel="close_swipe_inspector"
      class="modal--wide"
    >
      <ol id="swipe-timeline" class="swipe-timeline">
        <li
          :for={{body, n, expanded?, diff?, diffable?} <- @rows}
          id={"swipe-row-#{body.id}"}
          class={["swipe-row", body.active && "swipe-row--active", expanded? && "swipe-row--expanded"]}
        >
          <div class="swipe-row-card">
            <div class="swipe-row-header">
              <button
                type="button"
                id={"swipe-toggle-#{body.id}"}
                class="swipe-row-toggle"
                phx-click="toggle_swipe"
                phx-value-body_id={body.id}
                aria-expanded={to_string(expanded?)}
              >
                <span class="swipe-row-head">
                  <span class="swipe-row-number">{swipe_number(n)}</span>
                  <span class="swipe-row-origin">{origin_label(body, @number_by_id)}</span>
                  <.badge :if={
                    (body.guide != nil or guide_attachments(body) != []) and body.origin != :refine
                  }>
                    {dpgettext("chat", "badge: swipe written with a guide", "Guided")}
                  </.badge>
                  <.badge :if={body.active}>
                    {dpgettext("chat", "badge: the swipe currently shown", "Active")}
                  </.badge>
                  <.local_time id={"swipe-time-#{body.id}"} at={body.inserted_at} format={:seconds} />
                  <span :if={body.completion_tokens}>
                    {dpgettext("chat", "unit: tokens a swipe's reply used", "%{token_count} tok",
                      token_count: Mythweaver.Format.number(body.completion_tokens)
                    )}
                  </span>
                </span>
                <span :if={not expanded?} class="swipe-row-preview">{swipe_preview(body)}</span>
              </button>

              <div :if={expanded?} class="swipe-row-actions">
                <.button
                  :if={diffable?}
                  id={"swipe-diff-toggle-#{body.id}"}
                  phx-click="toggle_swipe_diff"
                  phx-value-body_id={body.id}
                  aria-pressed={to_string(diff?)}
                >
                  <.lucide name="git-compare" />
                  {if diff?,
                    do:
                      dpgettext(
                        "chat",
                        "button: show a swipe's plain text instead of its diff",
                        "Show text"
                      ),
                    else:
                      dpgettext("chat", "button: show a swipe's diff against its source", "Show diff")}
                </.button>
                <.button
                  :if={not body.active}
                  id={"swipe-activate-#{body.id}"}
                  phx-click="activate_swipe"
                  phx-value-body_id={body.id}
                  disabled={@generating?}
                >
                  {dpgettext("chat", "button: make this swipe the shown one", "Make active")}
                </.button>
              </div>
            </div>

            <div :if={expanded?} class="swipe-row-detail">
              <%!--
              `phx-no-format`: `.swipe-row-text` is `pre-wrap`, so any whitespace the formatter adds
              between these tags would render as text.
            --%>
              <p :if={body.guide} id={"swipe-guide-#{body.id}"} class="swipe-row-guide" phx-no-format>{guide_line(body)}</p>
              <div
                :if={guide_attachments(body) != []}
                id={"swipe-guide-attachments-#{body.id}"}
                class="swipe-row-guide-attachments"
              >
                <%= for a <- guide_attachments(body) do %>
                  <img
                    :if={a.kind == :image}
                    id={"swipe-guide-image-#{body.id}-#{a.id}"}
                    src={Mythweaver.Attachments.url(a, :thumb)}
                    alt={
                      a.description || a.filename ||
                        dpgettext(
                          "chat",
                          "alt text: image attached to a swipe's guide",
                          "Guide image"
                        )
                    }
                  />
                  <span
                    :if={a.kind != :image}
                    id={"swipe-guide-file-#{body.id}-#{a.id}"}
                    class="swipe-row-guide-file"
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
                    {a.filename ||
                      dpgettext(
                        "chat",
                        "alt text: unnamed file attached to a swipe's guide",
                        "Attachment"
                      )}
                  </span>
                <% end %>
              </div>
              <.word_diff
                :if={diff? and diffable?}
                id={"swipe-diff-#{body.id}"}
                class="swipe-row-text"
                old={@by_id[body.source_body_id].content}
                new={body.content}
              />
              <div
                :if={not (diff? and diffable?)}
                id={"swipe-text-#{body.id}"}
                class="swipe-row-text"
                phx-no-format
              >{body.content}</div>
              <p :if={body.error} class="swipe-row-error">{body.error}</p>
            </div>
          </div>
        </li>
      </ol>
    </.modal>
    """
  end

  defp swipe_number(n),
    do:
      dpgettext("chat", "badge: position of a swipe in its history", "#%{swipe_number}",
        swipe_number: Mythweaver.Format.number(n)
      )

  defp guide_line(%{origin: :refine, guide: guide}),
    do:
      dpgettext("chat", "status: refine instructions the user gave for a swipe", "Instructions: %{refine_instructions}",
        refine_instructions: guide
      )

  defp guide_line(%{guide: guide}),
    do: dpgettext("chat", "status: guidance the user gave for a swipe", "Guide: %{swipe_guide}", swipe_guide: guide)

  defp origin_label(%{origin: :original}, _numbers), do: dpgettext("chat", "status: how a swipe came about", "Original")

  defp origin_label(%{origin: :regenerate}, _numbers),
    do: dpgettext("chat", "status: how a swipe came about", "Regeneration")

  defp origin_label(%{origin: origin} = body, numbers) do
    case Map.fetch(numbers, body.source_body_id) do
      {:ok, k} -> derived_label(origin, Mythweaver.Format.number(k))
      :error -> derived_label(origin)
    end
  end

  defp derived_label(:edit, k),
    do:
      dpgettext(
        "chat",
        "status: how a swipe came about, with the swipe number it came from",
        "Edit of #%{swipe_number}", swipe_number: k)

  defp derived_label(:continue, k),
    do:
      dpgettext(
        "chat",
        "status: how a swipe came about, with the swipe number it came from",
        "Continue of #%{swipe_number}", swipe_number: k)

  defp derived_label(:refine, k),
    do:
      dpgettext(
        "chat",
        "status: how a swipe came about, with the swipe number it came from",
        "Refine of #%{swipe_number}", swipe_number: k)

  defp derived_label(:split, k),
    do:
      dpgettext(
        "chat",
        "status: how a swipe came about, with the swipe number it came from",
        "Split of #%{swipe_number}", swipe_number: k)

  defp derived_label(:merge, k),
    do:
      dpgettext(
        "chat",
        "status: how a swipe came about, with the swipe number it came from",
        "Merge of #%{swipe_number}", swipe_number: k)

  defp derived_label(:append, k),
    do:
      dpgettext(
        "chat",
        "status: how a swipe came about, with the swipe number it came from",
        "Scratchpad append of #%{swipe_number}", swipe_number: k)

  defp derived_label(:edit), do: dpgettext("chat", "status: how a swipe came about", "Edit")
  defp derived_label(:continue), do: dpgettext("chat", "status: how a swipe came about", "Continue")
  defp derived_label(:refine), do: dpgettext("chat", "status: how a swipe came about", "Refine")
  defp derived_label(:split), do: dpgettext("chat", "status: how a swipe came about", "Split")
  defp derived_label(:merge), do: dpgettext("chat", "status: how a swipe came about", "Merge")
  defp derived_label(:append), do: dpgettext("chat", "status: how a swipe came about", "Scratchpad append")

  defp guide_attachments(%{guide_attachments: list}) when is_list(list), do: list
  defp guide_attachments(_body), do: []

  defp diffable?(body, by_id),
    do: body.origin in [:edit, :continue, :refine, :split, :merge, :append] and Map.has_key?(by_id, body.source_body_id)

  defp swipe_preview(%{generating: true}), do: dpgettext("chat", "status: a swipe still being written", "Generating…")

  defp swipe_preview(body) do
    cond do
      String.trim(body.content || "") != "" -> body.content
      body.error -> body.error
      true -> dpgettext("chat", "empty state: a swipe with no text", "(empty)")
    end
  end
end
