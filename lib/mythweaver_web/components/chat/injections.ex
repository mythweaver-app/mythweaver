defmodule MythweaverWeb.Chat.Injections do
  @moduledoc """
  The chat injections modal opened from the chat header: every injection in the chat (prompt text
  outside the prompt's blocks, see `Mythweaver.Injections`), each editable, toggleable, re-armable once
  spent, and deletable, plus a form that creates a new one or edits the selected one.
  """

  use MythweaverWeb, :html

  alias Mythweaver.Format
  alias Mythweaver.Injections.Injection

  attr(:panel, :map,
    required: true,
    doc: "`%{injections: [Injection.t()], form: Phoenix.HTML.Form.t(), editing_id: id | nil}`"
  )

  attr(:completions, :map, default: nil)

  def chat_injections(assigns) do
    # Runtime-picked toggle icon; the Iconex compiler only sees literals.
    Iconex.hint(:lucide, ~w[eye eye-off])

    assigns =
      assign(assigns,
        any_spent?: Enum.any?(assigns.panel.injections, &Injection.spent?/1),
        at_depth?: to_string(assigns.panel.form[:position].value) == "at_depth"
      )

    ~H"""
    <%!-- `lower-bound="none"`: the content lives inside `<.modal>`'s slot and `<.input>`'s internals. --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      div.chat-injections-body:scope {
        display: flex;
        flex-direction: column;
        gap: var(--size-3);
      }

      .chat-injection-list {
        list-style: none;
        margin: 0;
        padding: 0;
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
      }

      .chat-injection-row {
        display: flex;
        align-items: center;
        gap: var(--size-2);
        padding: var(--size-2);
        border: 1px solid var(--border-grey);
        border-radius: var(--radius-2);
      }

      .chat-injection-row[aria-current="true"] {
        border-color: var(--primary-accent);
      }

      .chat-injection-row[data-active="false"] .chat-injection-summary {
        opacity: 0.6;
      }

      .chat-injection-summary {
        flex: 1 1 auto;
        min-width: 0;
        display: flex;
        flex-wrap: wrap;
        align-items: baseline;
        gap: var(--size-2);
      }

      .chat-injection-key {
        font-weight: 600;
      }

      .chat-injection-meta {
        color: var(--muted-foreground);
        font-size: 0.85rem;
      }

      .chat-injections-toolbar {
        display: flex;
        justify-content: flex-end;
      }

      .chat-injections-empty {
        margin: 0;
        color: var(--muted-foreground);
      }

      .chat-injection-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .chat-injection-form-heading {
        margin: 0;
        font-size: 0.9rem;
      }

      @media (--phone) {
        .chat-injection-row {
          flex-wrap: wrap;
        }
      }
    </style>

    <.modal
      id="chat-injections"
      title={dpgettext("chat", "heading: dialog listing a chat's prompt injections", "Injections")}
      on_cancel="close_chat_injections"
      class="modal--wide"
    >
      <div class="chat-injections-body">
        <p :if={@panel.injections == []} id="chat-injections-empty" class="chat-injections-empty">
          {dpgettext("chat", "empty state: chat injections list", "No injections in this chat")}
        </p>

        <div :if={@any_spent?} class="chat-injections-toolbar">
          <.button id="clean-up-chat-injections" phx-click="clean_up_chat_injections">
            <.lucide name="brush-cleaning" /> {dpgettext(
              "chat",
              "button: delete every spent injection",
              "Clean up spent"
            )}
          </.button>
        </div>

        <ul :if={@panel.injections != []} id="chat-injection-list" class="chat-injection-list">
          <li
            :for={injection <- @panel.injections}
            id={"chat-injection-#{injection.id}"}
            class="chat-injection-row"
            aria-current={to_string(@panel.editing_id == injection.id)}
            data-active={to_string(Injection.active?(injection))}
          >
            <span class="chat-injection-summary">
              <span class="chat-injection-key">{injection.key}</span>
              <span class="chat-injection-meta">{position_label(injection)}</span>
              <span class="chat-injection-meta">{lifetime_label(injection)}</span>
              <.badge :if={!injection.enabled}>
                {dpgettext("chat", "badge: injection switched off", "disabled")}
              </.badge>
              <.badge :if={Injection.spent?(injection)}>
                {dpgettext("chat", "badge: injection that has used up its replies", "spent")}
              </.badge>
            </span>
            <.button
              id={"edit-chat-injection-#{injection.id}"}
              icon
              phx-click="edit_chat_injection"
              phx-value-id={injection.id}
              aria-label={
                dpgettext(
                  "chat",
                  "aria label: icon button that edits this injection",
                  "Edit %{injection_key}",
                  injection_key: injection.key
                )
              }
            >
              <.lucide name="pencil" />
            </.button>
            <.button
              id={"toggle-chat-injection-#{injection.id}"}
              icon
              phx-click="toggle_chat_injection"
              phx-value-id={injection.id}
              aria-pressed={to_string(injection.enabled)}
              aria-label={
                if injection.enabled,
                  do:
                    dpgettext(
                      "chat",
                      "aria label: toggle that switches this injection off",
                      "Disable %{injection_key}",
                      injection_key: injection.key
                    ),
                  else:
                    dpgettext(
                      "chat",
                      "aria label: toggle that switches this injection on",
                      "Enable %{injection_key}",
                      injection_key: injection.key
                    )
              }
            >
              <.lucide name={if injection.enabled, do: "eye", else: "eye-off"} />
            </.button>
            <.button
              :if={Injection.spent?(injection)}
              id={"rearm-chat-injection-#{injection.id}"}
              icon
              phx-click="rearm_chat_injection"
              phx-value-id={injection.id}
              aria-label={
                dpgettext(
                  "chat",
                  "aria label: icon button that restores a spent injection's replies",
                  "Re-arm %{injection_key}",
                  injection_key: injection.key
                )
              }
            >
              <.lucide name="rotate-ccw" />
            </.button>
            <.button
              id={"delete-chat-injection-#{injection.id}"}
              icon
              danger
              phx-click="delete_chat_injection"
              phx-value-id={injection.id}
              data-confirm={delete_confirm(injection.key)}
              aria-label={
                dpgettext(
                  "chat",
                  "aria label: icon button that deletes this injection",
                  "Delete %{injection_key}",
                  injection_key: injection.key
                )
              }
            >
              <.lucide name="trash" />
            </.button>
          </li>
        </ul>

        <.form
          for={@panel.form}
          id="chat-injection-form"
          class="chat-injection-form"
          phx-hook="UnsavedChanges"
          data-saved={is_nil(@panel.form.action)}
          phx-change="validate_chat_injection"
          phx-submit="save_chat_injection"
        >
          <h3 class="chat-injection-form-heading">
            {if @panel.editing_id,
              do: dpgettext("chat", "heading: form editing an existing injection", "Edit injection"),
              else: dpgettext("chat", "heading: form creating an injection", "New injection")}
          </h3>
          <.input
            field={@panel.form[:key]}
            type="text"
            label={dpgettext("chat", "field label: name of an injection", "Key")}
            id="chat-injection-form-key"
          />
          <.editor
            field={@panel.form[:content]}
            label={dpgettext("chat", "field label: injection text template", "Text (Liquid)")}
            id="chat-injection-form-content"
            language="liquid"
            spellcheck
            completions={@completions}
            rows={4}
          />
          <.field_row id="chat-injection-form-placement-row">
            <:field>
              <.input
                field={@panel.form[:position]}
                type="select"
                label={
                  dpgettext("chat", "field label: where an injection's text is inserted", "Position")
                }
                id="chat-injection-form-position"
                options={position_options()}
              />
            </:field>
            <:field :if={@at_depth?}>
              <.input
                field={@panel.form[:depth]}
                type="number"
                label={
                  dpgettext(
                    "chat",
                    "field label: injection insertion depth",
                    "Depth (0 = after the last message)"
                  )
                }
                id="chat-injection-form-depth"
                min="0"
              />
            </:field>
            <:field :if={@at_depth?}>
              <.input
                field={@panel.form[:role]}
                type="select"
                label={
                  dpgettext(
                    "chat",
                    "field label: message role of an injection inserted at depth",
                    "Role"
                  )
                }
                id="chat-injection-form-role"
                options={[
                  {dpgettext("chat", "option: message role of an injection", "System"), :system},
                  {dpgettext("chat", "option: message role of an injection", "User"), :user},
                  {dpgettext("chat", "option: message role of an injection", "Assistant"), :assistant}
                ]}
              />
            </:field>
          </.field_row>
          <.input
            field={@panel.form[:condition]}
            type="text"
            label={
              dpgettext(
                "chat",
                "field label: condition template deciding whether an injection applies",
                "Condition (Liquid, optional)"
              )
            }
            id="chat-injection-form-condition"
            placeholder={~s(vars.mood == "tense")}
          />
          <.field_row id="chat-injection-form-lifetime-row">
            <:field>
              <.input
                field={@panel.form[:uses]}
                type="number"
                label={dgettext("chat", "Lasts for N replies (blank = until removed)")}
                id="chat-injection-form-uses"
                min="1"
              />
            </:field>
            <:field>
              <.input
                field={@panel.form[:order]}
                type="number"
                label={dpgettext("chat", "field label: sort order among injections", "Order")}
                id="chat-injection-form-order"
                min="0"
              />
            </:field>
          </.field_row>
          <.input
            field={@panel.form[:enabled]}
            type="checkbox"
            label={dpgettext("chat", "toggle: whether an injection is active", "Enabled")}
            id="chat-injection-form-enabled"
          />
          <.form_actions>
            <.button id="new-chat-injection" phx-click="new_chat_injection">
              <.lucide name="plus" /> {dpgettext(
                "chat",
                "button: start a new injection",
                "New injection"
              )}
            </.button>
            <.button type="submit" id="save-chat-injection" variant="primary">
              <.lucide name="check" /> {dpgettext("chat", "button: save the injection form", "Save")}
            </.button>
          </.form_actions>
        </.form>
      </div>
    </.modal>
    """
  end

  defp delete_confirm(key) do
    gettext_comment("Confirm dialog shown before deleting a chat injection; the placeholder is its key.")

    dpgettext("chat", "status: confirm dialog before deleting a chat injection", "Delete %{injection_key}?",
      injection_key: key
    )
  end

  defp position_options do
    Enum.map(
      [
        :before_character,
        :after_character,
        :before_examples,
        :after_examples,
        :at_depth,
        :before_author_note,
        :after_author_note
      ],
      &{position_name(&1), &1}
    )
  end

  defp position_name(:before_character),
    do: dpgettext("chat", "option: where an injection's text is inserted", "Before character")

  defp position_name(:after_character),
    do: dpgettext("chat", "option: where an injection's text is inserted", "After character")

  defp position_name(:before_examples),
    do: dpgettext("chat", "option: where an injection's text is inserted", "Before examples")

  defp position_name(:after_examples),
    do: dpgettext("chat", "option: where an injection's text is inserted", "After examples")

  defp position_name(:at_depth),
    do: dpgettext("chat", "option: where an injection's text is inserted", "In chat history, at depth")

  defp position_name(:before_author_note),
    do: dpgettext("chat", "option: where an injection's text is inserted", "Before author's note")

  defp position_name(:after_author_note),
    do: dpgettext("chat", "option: where an injection's text is inserted", "After author's note")

  defp position_label(%Injection{position: :at_depth} = injection),
    do:
      dpgettext(
        "chat",
        "status: injection inserted in the chat history at a depth",
        "In chat history, at depth · depth %{message_depth}", message_depth: Format.number(injection.depth))

  defp position_label(%Injection{position: position}), do: position_name(position)

  defp lifetime_label(%Injection{uses: nil}),
    do: dpgettext("chat", "status: injection that lasts until removed", "until removed")

  defp lifetime_label(%Injection{} = injection) do
    if Injection.spent?(injection),
      do: dpgettext("chat", "status: injection that has used up its replies", "spent"),
      else:
        dpgettext(
          "chat",
          "status: replies an injection has left",
          "%{remaining_replies} of %{total_replies} left",
          remaining_replies: Format.number(injection.remaining),
          total_replies: Format.number(injection.uses)
        )
  end
end
