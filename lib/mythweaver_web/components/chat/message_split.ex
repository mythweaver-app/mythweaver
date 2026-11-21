defmodule MythweaverWeb.Chat.MessageSplit do
  @moduledoc """
  The in-row split editor (`MythweaverWeb.MainChatLive.SplitEditor` owns its state). A message's
  paragraphs (`Mythweaver.Messages.Segment.paragraphs/1`) are listed in order with a divider before
  each paragraph a new piece starts at; the gaps between the others are where a divider can go.

  For a split into messages every divider carries +/− controls and a picker for the piece below it:
  an author, or Scratchpad to cut it into a scratchpad of this message. A split to a scratchpad has
  exactly one divider: everything below it is cut off into the scratchpad.

  Dividers move by dragging their grip (or arrow keys on it): the `.SplitDrag` hook only previews
  the landing gap and pushes `move_split_divider`; the server re-renders every divider.
  """

  use MythweaverWeb, :html

  attr(:split, :map, required: true)

  def split_editor(assigns) do
    %{split: split} = assigns

    assigns =
      assign(assigns,
        id: split.message_id,
        count: length(split.segments),
        by_boundary: split.dividers |> Enum.with_index() |> Map.new(fn {d, k} -> {d.boundary, {d, k}} end),
        messages?: split.target == :messages,
        removable?: match?([_, _ | _], split.dividers)
      )

    ~H"""
    <%!--
      `lower-bound="none"`: the segments and dividers sit inside `<.form>`'s inner block, past its
      `phx-r` root. Every element carrying this block's marker is then a scope root, so the root
      rule is class-qualified.
    --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      div.message-split:scope {
        position: relative;
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .message-split-segment {
        white-space: pre-wrap;
        overflow-wrap: anywhere;
      }

      .message-split-gap {
        block-size: var(--size-2);
      }

      .message-split-divider {
        display: flex;
        align-items: center;
        gap: var(--size-2);
        padding-block: var(--size-1);
        margin-block-start: var(--size-1);
        border-top: 2px dashed var(--primary-accent);
      }

      .message-split-handle {
        display: inline-flex;
        align-items: center;
        padding: var(--size-1);
        border: none;
        border-radius: var(--radius-2);
        background: none;
        color: var(--primary-accent);
        cursor: grab;
        touch-action: none;

        &:active {
          cursor: grabbing;
        }

        &:focus-visible {
          outline: 2px solid var(--ring);
        }
      }

      .message-split-control {
        display: inline-flex;
        align-items: center;
        padding: var(--size-1);
        border: none;
        background: none;
        color: var(--muted-foreground);
        cursor: pointer;

        &:hover {
          color: var(--foreground);
        }
      }

      .message-split-author {
        margin-inline-start: auto;
      }

      .message-split-indicator {
        position: absolute;
        inset-inline: 0;
        block-size: 2px;
        background: var(--primary-accent);
        pointer-events: none;
        transform: translateY(-1px);
      }

      .message-split-actions {
        display: flex;
        justify-content: flex-end;
        gap: var(--size-2);
      }

      @media (--coarse) {
        .message-split-handle {
          min-inline-size: var(--touch-target);
          min-block-size: var(--touch-target);
          justify-content: center;
        }
      }
    </style>
    <div id={"message-split-editor-#{@id}"} class="message-split" phx-hook=".SplitDrag">
      <.form
        for={@split.form}
        id={"message-split-form-#{@id}"}
        phx-change="change_split"
        phx-submit="confirm_split"
      >
        <%= for {segment, i} <- Enum.with_index(@split.segments) do %>
          <%= if i >= 1 do %>
            <%= case @by_boundary[i] do %>
              <% {divider, k} -> %>
                <div class="message-split-divider" data-split-divider data-boundary={i} data-index={k}>
                  <button
                    type="button"
                    class="message-split-handle"
                    id={"message-split-handle-#{@id}-#{k}"}
                    data-split-handle
                    data-index={k}
                    aria-label={dgettext("chat", "Drag to move the split (arrow keys move it)")}
                    title={dgettext("chat", "Drag to move the split (arrow keys move it)")}
                  >
                    <.lucide name="grip-horizontal" />
                  </button>
                  <button
                    :if={@messages? and i + 1 < @count and not Map.has_key?(@by_boundary, i + 1)}
                    type="button"
                    class="message-split-control"
                    id={"message-split-add-#{@id}-#{k}"}
                    phx-click="add_split_divider"
                    phx-value-index={k}
                    aria-label={
                      dpgettext(
                        "chat",
                        "aria label: button that adds a message split below this one",
                        "Add a split below"
                      )
                    }
                    title={
                      dpgettext(
                        "chat",
                        "tooltip: button that adds a message split below this one",
                        "Add a split below"
                      )
                    }
                  >
                    <.lucide name="plus" />
                  </button>
                  <button
                    :if={@messages? and @removable?}
                    type="button"
                    class="message-split-control"
                    id={"message-split-remove-#{@id}-#{k}"}
                    phx-click="remove_split_divider"
                    phx-value-index={k}
                    aria-label={
                      dpgettext(
                        "chat",
                        "aria label: button that removes this message split",
                        "Remove this split"
                      )
                    }
                    title={
                      dpgettext(
                        "chat",
                        "tooltip: button that removes this message split",
                        "Remove this split"
                      )
                    }
                  >
                    <.lucide name="minus" />
                  </button>
                  <div :if={@messages?} class="message-split-author">
                    <.input
                      type="select"
                      id={"message-split-author-#{@id}-#{k}"}
                      name={"split[authors][#{k}]"}
                      value={author_value(divider.author_id)}
                      options={[
                        {dpgettext(
                           "chat",
                           "option: keep the author of a split message piece",
                           "No change"
                         ), ""},
                        {dpgettext(
                           "chat",
                           "option: cut a split message piece off into a scratchpad",
                           "Scratchpad"
                         ), "scratchpad"}
                        | @split.author_options
                      ]}
                      aria-label={
                        dgettext("chat", "Author of the piece below, or Scratchpad to cut it off")
                      }
                    />
                  </div>
                </div>
              <% nil -> %>
                <div class="message-split-gap" data-boundary={i}></div>
            <% end %>
          <% end %>
          <div
            class="message-split-segment"
            id={"message-split-segment-#{@id}-#{i}"}
            data-segment={i}
            phx-no-format
          >{segment}</div>
        <% end %>
        <div class="message-split-actions">
          <.button size="sm" id={"message-split-cancel-#{@id}"} phx-click="cancel_split">
            {dpgettext("chat", "button: close the message split editor", "Cancel")}
          </.button>
          <.button variant="primary" size="sm" type="submit" id={"message-split-confirm-#{@id}"}>
            {if @messages?,
              do: dpgettext("chat", "button: split a message into several", "Split"),
              else:
                dpgettext(
                  "chat",
                  "button: move the selected text of a message to a scratchpad",
                  "Move to scratchpad"
                )}
          </.button>
        </div>
      </.form>
      <div
        id={"message-split-indicator-#{@id}"}
        class="message-split-indicator"
        phx-update="ignore"
        hidden
      >
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".SplitDrag">
      // Previews where a dragged divider would land and tells the server; it never moves a node the
      // server renders. A divider lands only on a gap no other divider holds.
      export default {
        mounted() {
          this.drag = null;
          this.el.addEventListener("pointerdown", (e) => {
            const handle = e.target.closest("[data-split-handle]");
            if (!handle || e.button !== 0) return;
            e.preventDefault();
            handle.setPointerCapture(e.pointerId);
            const boundary = this.boundaryOf(handle);
            this.drag = {
              index: Number(handle.dataset.index),
              from: boundary,
              to: boundary,
            };
          });
          this.el.addEventListener("pointermove", (e) => {
            if (!this.drag) return;
            const gap = this.nearest(e.clientY, this.drag.index);
            if (!gap) return;
            this.drag.to = gap.boundary;
            this.indicator().style.top = `${gap.y}px`;
            this.indicator().hidden = false;
          });
          const end = () => {
            if (!this.drag) return;
            const { index, from, to } = this.drag;
            this.drag = null;
            this.indicator().hidden = true;
            if (to !== from)
              this.pushEvent("move_split_divider", { index, boundary: to });
          };
          this.el.addEventListener("pointerup", end);
          this.el.addEventListener("pointercancel", end);
          this.el.addEventListener("keydown", (e) => {
            const handle = e.target.closest("[data-split-handle]");
            if (!handle || (e.key !== "ArrowUp" && e.key !== "ArrowDown")) return;
            e.preventDefault();
            const index = Number(handle.dataset.index);
            const from = this.boundaryOf(handle);
            const free = this.free(index);
            const to =
              e.key === "ArrowUp"
                ? free.filter((b) => b < from).pop()
                : free.find((b) => b > from);
            if (to !== undefined)
              this.pushEvent("move_split_divider", { index, boundary: to });
          });
        },
        boundaryOf(handle) {
          return Number(handle.closest("[data-split-divider]").dataset.boundary);
        },
        indicator() {
          return this.el.querySelector(".message-split-indicator");
        },
        segments() {
          return [...this.el.querySelectorAll("[data-segment]")];
        },
        // Gaps 1..n-1 not held by a divider other than `index`.
        free(index) {
          const taken = new Set(
            [...this.el.querySelectorAll("[data-split-divider]")]
              .filter((d) => Number(d.dataset.index) !== index)
              .map((d) => Number(d.dataset.boundary)),
          );
          const free = [];
          for (let g = 1; g < this.segments().length; g++)
            if (!taken.has(g)) free.push(g);
          return free;
        },
        // The free gap nearest the pointer, and its offset from the editor's top.
        nearest(clientY, index) {
          const segments = this.segments();
          const top = this.el.getBoundingClientRect().top;
          let best = null;
          for (const g of this.free(index)) {
            const y =
              (segments[g - 1].getBoundingClientRect().bottom +
                segments[g].getBoundingClientRect().top) /
              2;
            const distance = Math.abs(clientY - y);
            if (!best || distance < best.distance)
              best = { boundary: g, y: y - top, distance };
          }
          return best;
        },
      };
    </script>
    """
  end

  defp author_value(nil), do: ""
  defp author_value(:scratchpad), do: "scratchpad"
  defp author_value(id), do: id
end
