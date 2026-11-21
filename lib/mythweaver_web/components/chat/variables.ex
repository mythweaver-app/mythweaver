defmodule MythweaverWeb.Chat.Variables do
  @moduledoc """
  The chat variables modal opened from the chat header: every variable in the chat (what templates
  read as `vars` and write with `{% setvar %}`), each editable and deletable, plus a form that creates
  a new one or edits the selected one.

  A value box holds JSON (`42`, `true`, `[1, 2]`, `{"a": 1}`, `"quoted"`); text that is not JSON is
  stored as a plain string (`MythweaverWeb.JSONText.decode_value/1`).
  """

  use MythweaverWeb, :html

  alias MythweaverWeb.JSONText

  attr(:panel, :map,
    required: true,
    doc: "`%{variables: [Variable.t()], form: Phoenix.HTML.Form.t(), value_text: String.t(), editing_id: id | nil}`"
  )

  def chat_variables(assigns) do
    ~H"""
    <%!-- `lower-bound="none"`: the content lives inside `<.modal>`'s slot and `<.input>`'s internals. --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      div.chat-variables-body:scope {
        display: flex;
        flex-direction: column;
        gap: var(--size-3);
      }

      .chat-variable-list {
        list-style: none;
        margin: 0;
        padding: 0;
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
      }

      .chat-variable-row {
        display: flex;
        align-items: baseline;
        gap: var(--size-2);
        padding: var(--size-2);
        border: 1px solid var(--border-grey);
        border-radius: var(--radius-2);
      }

      .chat-variable-row[aria-current="true"] {
        border-color: var(--primary-accent);
      }

      .chat-variable-key {
        flex: 0 0 auto;
        font-weight: 600;
      }

      .chat-variable-value {
        flex: 1 1 auto;
        min-width: 0;
        margin: 0;
        white-space: pre-wrap;
        overflow-wrap: anywhere;
        max-block-size: 10rem;
        overflow: auto;
        font-family: var(--font-monospace-code, ui-monospace, monospace);
        font-size: 0.85rem;
      }

      .chat-variables-empty {
        margin: 0;
        color: var(--muted-foreground);
      }

      .chat-variable-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .chat-variable-form-heading {
        margin: 0;
        font-size: 0.9rem;
      }

      @media (--phone) {
        .chat-variable-row {
          flex-wrap: wrap;
        }
      }
    </style>

    <.modal
      id="chat-variables"
      title={dpgettext("variables", "heading: dialog listing a chat's variables", "Variables")}
      on_cancel="close_chat_variables"
      class="modal--wide"
    >
      <div class="chat-variables-body">
        <p :if={@panel.variables == []} id="chat-variables-empty" class="chat-variables-empty">
          {dpgettext("variables", "empty state: chat variables list", "No variables in this chat")}
        </p>

        <ul :if={@panel.variables != []} id="chat-variable-list" class="chat-variable-list">
          <li
            :for={variable <- @panel.variables}
            id={"chat-variable-#{variable.id}"}
            class="chat-variable-row"
            aria-current={to_string(@panel.editing_id == variable.id)}
          >
            <span class="chat-variable-key">{variable.key}</span>
            <pre class="chat-variable-value" phx-no-format>{JSONText.encode_value(variable.value)}</pre>
            <.button
              id={"edit-chat-variable-#{variable.id}"}
              icon
              phx-click="edit_chat_variable"
              phx-value-id={variable.id}
              aria-label={
                dpgettext(
                  "variables",
                  "aria label: icon button that edits this chat variable",
                  "Edit %{variable_key}",
                  variable_key: variable.key
                )
              }
            >
              <.lucide name="pencil" />
            </.button>
            <.button
              id={"delete-chat-variable-#{variable.id}"}
              icon
              danger
              phx-click="delete_chat_variable"
              phx-value-id={variable.id}
              data-confirm={delete_confirm(variable.key)}
              aria-label={
                dpgettext(
                  "variables",
                  "aria label: icon button that deletes this chat variable",
                  "Delete %{variable_key}",
                  variable_key: variable.key
                )
              }
            >
              <.lucide name="trash" />
            </.button>
          </li>
        </ul>

        <.form
          for={@panel.form}
          id="chat-variable-form"
          class="chat-variable-form"
          phx-hook="UnsavedChanges"
          data-saved={is_nil(@panel.form.action)}
          phx-change="validate_chat_variable"
          phx-submit="save_chat_variable"
        >
          <h3 class="chat-variable-form-heading">
            {if @panel.editing_id,
              do:
                dpgettext(
                  "variables",
                  "heading: form editing an existing chat variable",
                  "Edit variable"
                ),
              else: dpgettext("variables", "heading: form creating a chat variable", "New variable")}
          </h3>
          <.input
            field={@panel.form[:key]}
            type="text"
            label={dpgettext("variables", "field label: name of a chat variable", "Key")}
            id="chat-variable-form-key"
          />
          <.editor
            name="variable[value]"
            label={
              dpgettext(
                "variables",
                "field label: value of a chat variable",
                "Value (JSON, or plain text)"
              )
            }
            id="chat-variable-form-value"
            language="json"
            line_numbers
            value={@panel.value_text}
            errors={translate_errors(@panel.form.errors, :value)}
            rows={4}
          />
          <.form_actions>
            <.button id="new-chat-variable" phx-click="new_chat_variable">
              <.lucide name="plus" /> {dpgettext(
                "variables",
                "button: start a new chat variable",
                "New variable"
              )}
            </.button>
            <.button type="submit" id="save-chat-variable" variant="primary">
              <.lucide name="check" /> {dpgettext(
                "variables",
                "button: save the chat variable form",
                "Save"
              )}
            </.button>
          </.form_actions>
        </.form>
      </div>
    </.modal>
    """
  end

  defp delete_confirm(key) do
    gettext_comment("Confirm dialog before deleting a chat or global variable; the placeholder is its key.")

    dpgettext("variables", "status: confirm dialog before deleting a variable", "Delete %{variable_key}?",
      variable_key: key
    )
  end
end
