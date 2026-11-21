defmodule MythweaverWeb.Chat.Scratchpads do
  @moduledoc """
  The scratchpad dock between the message log and the composer: one card per
  `Mythweaver.Messages.Scratchpad`, oldest first. A card names the message its text was cut from,
  shows the text (or its edit form) and offers Append (back onto that message's current swipe),
  Edit and Discard (confirmed inline). A card whose message was deleted can only be edited or
  discarded. `MythweaverWeb.MainChatLive.ScratchpadPanel` handles the events.
  """

  use MythweaverWeb, :html

  alias Mythweaver.Format

  attr(:scratchpads, :list, required: true)
  attr(:edit, :map, default: nil, doc: "`%{id, form}` of the card open for editing, or nil")
  attr(:discarding_id, :any, default: nil, doc: "id of the card asking to confirm a discard")

  def scratchpads(assigns) do
    ~H"""
    <%!-- `lower-bound="none"`: the edit form's contents sit inside `<.form>`'s `phx-r` root. --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      section.chat-scratchpads:scope {
        flex: none;
        max-block-size: 40dvh;
        overflow-y: auto;
        border-top: 1px solid var(--border);
        background: var(--surface-2);
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
        padding: var(--size-2);
      }

      .scratchpad {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
        padding: var(--size-2) var(--size-3);
        border: 1px dashed var(--border);
        border-radius: var(--radius-2);
        background: var(--surface-3);
      }

      .scratchpad-header {
        display: flex;
        align-items: center;
        gap: var(--size-2);
        font-size: var(--font-size-0);
        color: var(--muted-foreground);
      }

      .scratchpad-title {
        font-weight: 600;
        text-transform: uppercase;
        letter-spacing: 0.05em;
      }

      .scratchpad-actions {
        display: flex;
        align-items: center;
        gap: var(--size-1);
        margin-inline-start: auto;
      }

      .scratchpad-text {
        overflow-wrap: anywhere;
      }

      .scratchpad-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .scratchpad-form-actions,
      .scratchpad-confirm {
        display: flex;
        align-items: center;
        justify-content: flex-end;
        gap: var(--size-2);
      }

      .scratchpad-confirm span {
        margin-inline-end: auto;
      }
    </style>
    <section
      :if={@scratchpads != []}
      id="scratchpads"
      class="chat-scratchpads"
      aria-label={dpgettext("chat", "aria label: dock of scratchpad cards", "Scratchpads")}
    >
      <article :for={s <- @scratchpads} id={"scratchpad-#{s.id}"} class="scratchpad">
        <header class="scratchpad-header">
          <span class="scratchpad-title">
            {dpgettext("chat", "heading: card holding text cut from a message", "Scratchpad")}
          </span>
          <span :if={s.message}>
            {dpgettext(
              "chat",
              "status: message a scratchpad was cut from, by number and author",
              "from #%{message_number} · %{author_name}",
              message_number: Format.number(s.message.position + 1),
              author_name: author_name(s.message)
            )}
          </span>
          <span :if={s.message == nil}>
            {dpgettext(
              "chat",
              "status: the message a scratchpad was cut from was deleted",
              "Its message was deleted"
            )}
          </span>
          <div
            :if={not editing?(s, @edit) and @discarding_id != s.id}
            class="scratchpad-actions"
            role="group"
            aria-label={
              dpgettext("chat", "aria label: button group on a scratchpad card", "Scratchpad actions")
            }
          >
            <.button
              size="sm"
              id={"scratchpad-append-#{s.id}"}
              phx-click="append_scratchpad"
              phx-value-id={s.id}
              disabled={s.message == nil}
              title={dgettext("chat", "Append to the end of its message")}
            >
              <.lucide name="clipboard-paste" /> {dpgettext(
                "chat",
                "button: append a scratchpad to its message",
                "Append"
              )}
            </.button>
            <.button
              size="sm"
              icon
              id={"scratchpad-edit-#{s.id}"}
              phx-click="edit_scratchpad"
              phx-value-id={s.id}
              aria-label={
                dpgettext(
                  "chat",
                  "aria label: icon button that edits this scratchpad",
                  "Edit scratchpad"
                )
              }
              title={dpgettext("chat", "tooltip: icon button that edits this scratchpad", "Edit")}
            >
              <.lucide name="pencil" />
            </.button>
            <.button
              size="sm"
              icon
              id={"scratchpad-discard-#{s.id}"}
              phx-click="ask_discard_scratchpad"
              phx-value-id={s.id}
              aria-label={
                dpgettext(
                  "chat",
                  "aria label: icon button that discards this scratchpad",
                  "Discard scratchpad"
                )
              }
              title={
                dpgettext("chat", "tooltip: icon button that discards this scratchpad", "Discard")
              }
            >
              <.lucide name="trash" />
            </.button>
          </div>
        </header>

        <div :if={@discarding_id == s.id} class="scratchpad-confirm" role="alert">
          <span>{discard_question()}</span>
          <.button
            size="sm"
            id={"scratchpad-discard-cancel-#{s.id}"}
            phx-click="cancel_discard_scratchpad"
          >
            {dpgettext("chat", "button: cancel discarding a scratchpad", "Keep")}
          </.button>
          <.button
            size="sm"
            danger
            id={"scratchpad-discard-confirm-#{s.id}"}
            phx-click="discard_scratchpad"
            phx-value-id={s.id}
          >
            {dpgettext("chat", "button: confirm discarding a scratchpad", "Discard")}
          </.button>
        </div>

        <.form
          :if={editing?(s, @edit)}
          for={@edit.form}
          id={"scratchpad-form-#{s.id}"}
          class="scratchpad-form"
          phx-submit="save_scratchpad"
        >
          <.editor
            field={@edit.form[:content]}
            id={"scratchpad-form-content-#{s.id}"}
            language="markdown"
            rows={4}
            max_rows={16}
            spellcheck
            autofocus
          />
          <div class="scratchpad-form-actions">
            <.button
              size="sm"
              id={"scratchpad-edit-cancel-#{s.id}"}
              phx-click="cancel_scratchpad_edit"
            >
              {dpgettext("chat", "button: close the scratchpad edit form", "Cancel")}
            </.button>
            <.button variant="primary" size="sm" type="submit" id={"scratchpad-edit-save-#{s.id}"}>
              {dpgettext("chat", "button: save the scratchpad edit form", "Save")}
            </.button>
          </div>
        </.form>

        <div :if={not editing?(s, @edit)} class="scratchpad-text"><.markdown text={s.content} /></div>
      </article>
    </section>
    """
  end

  defp discard_question do
    gettext_comment("Inline confirmation shown on a scratchpad card after its Discard button is pressed.")

    dpgettext("chat", "status: confirm question before discarding a scratchpad", "Discard this scratchpad?")
  end

  defp editing?(scratchpad, edit), do: edit != nil and edit.id == scratchpad.id

  @doc "A message's author name: its character's, else the stored name; \"Unknown\" when its character is gone."
  def author_name(%{author_is_character: true, author_character: %{name: name}}), do: name

  def author_name(%{author_is_character: true}),
    do: dpgettext("chat", "status: author of a message whose character is gone", "Unknown")

  def author_name(%{author_name: name}), do: name
end
