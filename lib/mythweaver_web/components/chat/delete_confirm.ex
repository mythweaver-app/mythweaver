defmodule MythweaverWeb.Chat.DeleteConfirm do
  @moduledoc """
  The confirmation dialog before deleting one message or a bulk selection. Besides the usual
  question it lists what memory rollback would undo (`Mythweaver.Memory.Rollback.preview/2`):
  memories and consolidations deleted, side-prompt entries restored.
  """

  use MythweaverWeb, :html

  alias Mythweaver.Format

  attr(:confirm, :map, required: true, doc: "`%{count: n, preview: Rollback.preview/2 result}`")

  def delete_confirm(assigns) do
    %{memories: memories, consolidations: consolidations, side_prompts: side_prompts} =
      assigns.confirm.preview

    groups = [
      {"delete-confirm-memories",
       dpgettext("chat", "heading: memories that deleting messages removes", "Memories deleted"), memories},
      {"delete-confirm-consolidations",
       dpgettext(
         "chat",
         "heading: memory consolidations that deleting messages removes",
         "Consolidations deleted"
       ), consolidations},
      {"delete-confirm-side-prompts",
       dpgettext(
         "chat",
         "heading: side prompt entries that deleting messages restores",
         "Side prompts restored"
       ), side_prompts}
    ]

    assigns =
      assign(assigns,
        rollback?: Enum.any?(groups, fn {_id, _heading, records} -> records != [] end),
        groups: groups
      )

    ~H"""
    <%!--
      `lower-bound="none"`: the content lives inside `<.modal>`'s slot, a nested component root. Each
      top-level tag of the slot carries this block's scope marker, so it is a scope root and needs a
      tag-qualified `:scope` rule; a bare class would match nothing.
    --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      p.delete-confirm-text:scope {
        margin: 0;
      }

      section.delete-confirm-rollback:scope {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
        margin-top: var(--size-3);
      }

      .delete-confirm-heading {
        margin: 0;
        font-size: var(--font-size-1);
        color: var(--muted-foreground);
      }

      .delete-confirm-list {
        margin: 0;
        padding-inline-start: var(--size-4);
      }

      .delete-confirm-range {
        color: var(--muted-foreground);
        margin-inline-start: var(--size-2);
      }

      div.delete-confirm-actions:scope {
        display: flex;
        justify-content: flex-end;
        gap: var(--size-2);
        margin-top: var(--size-3);
      }
    </style>

    <.modal
      id="delete-confirm-modal"
      title={title(@confirm.count)}
      on_cancel="cancel_delete"
    >
      <p class="delete-confirm-text">
        {question(@confirm.count)}
      </p>

      <section :if={@rollback?} id="delete-confirm-rollback" class="delete-confirm-rollback">
        <div :for={{id, heading, records} <- @groups} :if={records != []} id={id}>
          <h3 class="delete-confirm-heading">{heading}</h3>
          <ul class="delete-confirm-list">
            <li :for={record <- records} class="delete-confirm-item">
              {record.entry.name}
              <span :if={record.range_start && record.range_end} class="delete-confirm-range">
                {range(record)}
              </span>
            </li>
          </ul>
        </div>
      </section>

      <%!-- `autofocus`: `showModal()` focuses it on open, so Enter deletes. --%>
      <div class="delete-confirm-actions">
        <.button id="delete-cancel" phx-click="cancel_delete">
          {dpgettext("chat", "button: keep the messages and close the delete dialog", "Cancel")}
        </.button>
        <.button id="delete-confirm" variant="primary" danger phx-click="confirm_delete" autofocus>
          {dpgettext("chat", "button: confirm deleting messages", "Delete")}
        </.button>
      </div>
    </.modal>
    """
  end

  defp title(1), do: dpgettext("chat", "heading: dialog confirming deletion of one message", "Delete message")

  defp title(n),
    do:
      dpngettext(
        "chat",
        "heading: dialog confirming deletion of selected messages",
        "Delete %{message_count} message",
        "Delete %{message_count} messages",
        n, message_count: Format.number(n))

  defp question(1) do
    gettext_comment("Confirm dialog shown before deleting a single message.")
    dgettext("chat", "Delete this message and all its swipes?")
  end

  defp question(_n) do
    gettext_comment("Confirm dialog shown before deleting several selected messages.")
    dgettext("chat", "Delete the selected messages and all their swipes?")
  end

  defp range(record),
    do:
      dpgettext("chat", "unit: range of message numbers a memory covers", "#%{first_message}–#%{last_message}",
        first_message: Format.number(record.range_start + 1),
        last_message: Format.number(record.range_end + 1)
      )
end
