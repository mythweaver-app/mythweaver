defmodule MythweaverWeb.PromptPreview do
  @moduledoc """
  The prompt and block editors' "Preview" panel: pick a chat and who replies, then see every section
  the prompt renders for it, with template errors, without generating anything
  (`Mythweaver.Prompts.Preview`).

  Both editors share this module: `assign_preview/1` on navigation, `update_preview/2` for the
  `"preview_options"` event, `run_preview/2` for `"preview"`, `set_preview_view/2` for
  `"preview_view"`, and `prompt_preview/1` to render. The result shows either one card per section
  (`:blocks`), the whole prompt as the single string a text-completion model receives (`:text`), or
  what became of each of the chat's injections (`:injections`).
  The selected chat and mode survive navigation between prompts or blocks, so comparing two of them
  against the same chat takes one click each.
  """

  use MythweaverWeb, :html

  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Prompts.Preview
  alias Mythweaver.Prompts.Prompt
  alias Phoenix.HTML.Form
  alias Phoenix.LiveView.Socket

  @doc "Refreshes the chat list and clears any previous result; keeps the chosen chat if it still exists."
  @spec assign_preview(Socket.t()) :: Socket.t()
  def assign_preview(socket) do
    scope = socket.assigns.current_scope
    chats = Chats.list_chats(scope, :roleplay)
    current = socket.assigns[:preview_chat]
    chat = (current && Enum.find(chats, &(&1.id == current.id))) || List.first(chats)

    character_id =
      if current && chat && chat.id == current.id,
        do: socket.assigns[:preview_character_id] || "",
        else: ""

    socket
    |> assign(
      preview_chats: Enum.map(chats, &{Chat.title(&1), &1.id}),
      preview_result: nil,
      preview_view: socket.assigns[:preview_view] || :blocks
    )
    |> select(chat, character_id)
  end

  @doc "Handles the panel's `phx-change`: a new chat resets who replies to its default responder."
  @spec update_preview(Socket.t(), map()) :: Socket.t()
  def update_preview(socket, params) do
    chat_id = params["chat_id"]
    current = socket.assigns.preview_chat

    if current && current.id == chat_id do
      select(socket, current, params["character_id"] || "")
    else
      chat = chat_id && Chats.get_chat(socket.assigns.current_scope, chat_id)
      socket |> assign(preview_result: nil) |> select(chat, "")
    end
  end

  @doc "Renders `prompt` against the selected chat and assigns the result."
  @spec run_preview(Socket.t(), Prompt.t()) :: Socket.t()
  def run_preview(socket, %Prompt{} = prompt) do
    case socket.assigns.preview_chat do
      nil ->
        socket

      chat ->
        # Reloaded so the preview sees the chat's current messages and participants.
        scope = socket.assigns.current_scope
        chat = Chats.get_chat!(scope, chat.id)

        character =
          Enum.find_value(chat.participants, &(&1.character_id == socket.assigns.preview_character_id && &1.character))

        assign(socket, preview_chat: chat, preview_result: Preview.run(scope, prompt, chat, character))
    end
  end

  @doc ~s(Handles the `"preview_view"` click: `"blocks"`, `"text"` or `"injections"`; anything else is ignored.)
  @spec set_preview_view(Socket.t(), String.t()) :: Socket.t()
  def set_preview_view(socket, "blocks"), do: assign(socket, preview_view: :blocks)
  def set_preview_view(socket, "text"), do: assign(socket, preview_view: :text)
  def set_preview_view(socket, "injections"), do: assign(socket, preview_view: :injections)
  def set_preview_view(socket, _view), do: socket

  defp select(socket, chat, character_id) do
    assign(socket,
      preview_chat: chat,
      preview_character_id: character_id,
      preview_form: to_form(%{"chat_id" => chat && chat.id, "character_id" => character_id}, as: :preview)
    )
  end

  attr :id, :string, required: true, doc: "prefix for every id in the panel"
  attr :chats, :list, required: true, doc: "`{label, id}` options"
  attr :chat, :any, required: true, doc: "the selected `Chat`, or nil"
  attr :form, Form, required: true
  attr :result, :any, required: true, doc: "a redacted `PromptSnapshot`, or nil before the first run"
  attr :unnamed, :string, default: nil, doc: ~s(section label when a block has no name yet; nil means "Unsaved block")

  attr :view, :atom,
    default: :blocks,
    doc: ":blocks (one card per section), :text (the flat prompt) or :injections (each injection's outcome)"

  def prompt_preview(assigns) do
    assigns =
      assign(assigns,
        character_options: character_options(assigns.chat),
        lore_errors: lore_errors(assigns.result)
      )

    ~H"""
    <%!-- `lower-bound="none"`: `.prompt-preview-input` styles reach inside `<.input>`'s template. --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      div:scope {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .prompt-preview-hint {
        margin: 0;
        color: var(--muted-foreground);
      }

      .prompt-preview-form {
        display: flex;
        flex-wrap: wrap;
        align-items: end;
        gap: var(--size-2);
      }

      .prompt-preview-form label {
        display: block;
      }

      .prompt-preview-input {
        display: block;
        font: inherit;
        color: var(--foreground);
        background: var(--surface-2);
        border: 1px solid var(--input);
        border-radius: var(--radius-2);
        padding: var(--size-1) var(--size-2);
      }

      .prompt-preview-toolbar {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        justify-content: space-between;
        gap: var(--size-2);
        margin-block-end: var(--size-2);
      }

      .prompt-preview-views {
        display: inline-flex;
        gap: var(--size-1);
      }

      .prompt-preview-list {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
        margin: 0;
        padding: 0;
        list-style: none;
      }

      .prompt-preview-section {
        border: 1px solid var(--border-grey);
        border-radius: var(--radius-2);
      }

      .prompt-preview-head {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: var(--size-2);
        padding: var(--size-1) var(--size-2);
      }

      .prompt-preview-name {
        font-weight: 600;
      }

      .prompt-preview-tokens {
        margin-inline-start: auto;
        color: var(--muted-foreground);
      }

      .prompt-preview-text {
        margin: 0;
        padding: var(--size-2);
        border-block-start: 1px solid var(--border-grey);
        white-space: pre-wrap;
        overflow-wrap: anywhere;
        max-block-size: 40dvh;
        overflow: auto;
      }

      .prompt-preview-error {
        margin: 0;
        padding: 0 var(--size-2) var(--size-1);
        font-size: 0.85rem;
        color: var(--destructive);
        overflow-wrap: anywhere;
      }
    </style>
    <div id={@id}>
      <p :if={@chats == []} class="prompt-preview-hint">
        {dgettext("prompts", "Create a chat to preview against.")}
      </p>

      <.form
        :if={@chats != []}
        for={@form}
        id={"#{@id}-form"}
        class="prompt-preview-form"
        phx-change="preview_options"
        phx-submit="preview"
      >
        <.input
          field={@form[:chat_id]}
          type="select"
          label={dpgettext("prompts", "field label: chat a prompt preview renders against", "Chat")}
          options={@chats}
          id={"#{@id}-form-chat_id"}
          class="prompt-preview-input"
        />
        <.input
          field={@form[:character_id]}
          type="select"
          label={
            dpgettext("prompts", "field label: character a prompt preview replies as", "Reply as")
          }
          prompt={
            dpgettext(
              "prompts",
              "option: preview replies as the chat's default responder",
              "Default responder"
            )
          }
          options={@character_options}
          id={"#{@id}-form-character_id"}
          class="prompt-preview-input"
        />
        <.button type="submit" id={"#{@id}-run"} variant="primary">
          <.lucide name="eye" /> {dpgettext("prompts", "button: render the prompt preview", "Preview")}
        </.button>
      </.form>

      <div :if={@result} id={"#{@id}-result"}>
        <div class="prompt-preview-toolbar">
          <p class="prompt-preview-hint">
            {dgettext(
              "prompts",
              "Rendered for %{chat_name}; lore is not committed and variable writes are discarded.",
              chat_name:
                @chat.name || dpgettext("prompts", "heading: chat without a name", "Untitled")
            )}
          </p>
          <div
            class="prompt-preview-views"
            role="group"
            aria-label={
              dpgettext(
                "prompts",
                "aria label: buttons that switch the prompt preview view",
                "Preview mode"
              )
            }
          >
            <.button
              :for={
                {label, view} <- [
                  {dpgettext("prompts", "button: prompt preview view, one card per block", "Blocks"),
                   :blocks},
                  {dpgettext("prompts", "button: prompt preview view, the flat prompt text", "Text"),
                   :text},
                  {dpgettext(
                     "prompts",
                     "button: prompt preview view, each injection's outcome",
                     "Injections"
                   ), :injections}
                ]
              }
              size="sm"
              id={"#{@id}-view-#{view}"}
              phx-click="preview_view"
              phx-value-view={view}
              aria-pressed={to_string(@view == view)}
            >
              {label}
            </.button>
          </div>
        </div>
        <p
          :for={{error, i} <- Enum.with_index(@result.template_errors ++ @lore_errors)}
          id={"#{@id}-error-#{i}"}
          class="prompt-preview-error"
        >
          {error}
        </p>
        <p :if={@result.sections == []} id={"#{@id}-empty"} class="prompt-preview-hint">
          {dgettext("prompts", "Renders nothing for this chat.")}
        </p>
        <ol :if={@view == :blocks} id={"#{@id}-sections"} class="prompt-preview-list">
          <li
            :for={{section, i} <- Enum.with_index(@result.sections)}
            id={"#{@id}-section-#{i}"}
            class="prompt-preview-section"
          >
            <div class="prompt-preview-head">
              <span class="prompt-preview-name">
                {section["block_name"] || @unnamed ||
                  dpgettext(
                    "prompts",
                    "heading: preview section of a block that has no name yet",
                    "Unsaved block"
                  )}
              </span>
              <.badge>{section["source"]}</.badge>
              <span>{section["role"]}</span>
              <span class="prompt-preview-tokens">{token_estimate(section["tokens"])}</span>
            </div>
            <p
              :for={{error, e} <- Enum.with_index(section["template_errors"])}
              id={"#{@id}-section-#{i}-error-#{e}"}
              class="prompt-preview-error"
            >
              {error}
            </p>
            <%!-- `phx-no-format`: pre-wrap would render any whitespace the formatter adds. --%>
            <div id={"#{@id}-section-#{i}-text"} class="prompt-preview-text" phx-no-format>{section["content"]}</div>
          </li>
        </ol>
        <div :if={@view == :text} class="prompt-preview-section">
          <div class="prompt-preview-head">
            <span class="prompt-preview-name">
              {dgettext("prompts", "The prompt as one text-completion string")}
            </span>
            <span class="prompt-preview-tokens">
              {token_estimate(Enum.reduce(@result.sections, 0, &(&1["tokens"] + &2)))}
            </span>
          </div>
          <%!-- `phx-no-format`: pre-wrap would render any whitespace the formatter adds. --%>
          <div id={"#{@id}-text"} class="prompt-preview-text" phx-no-format>{@result.request["prompt"]}</div>
        </div>
        <ol :if={@view == :injections} id={"#{@id}-injections"} class="prompt-preview-list">
          <li :if={@result.injections == []} class="prompt-preview-hint">
            {dgettext("prompts", "No injections in this chat.")}
          </li>
          <li
            :for={{injection, i} <- Enum.with_index(@result.injections)}
            id={"#{@id}-injection-#{i}"}
            class="prompt-preview-section"
          >
            <div class="prompt-preview-head">
              <span class="prompt-preview-name">{injection["key"]}</span>
              <.badge>
                {injection_position(injection["position"], injection["depth"])}
              </.badge>
              <span :if={injection["role"]}>{injection["role"]}</span>
              <.badge>{injection["status"]}</.badge>
            </div>
            <p
              :for={{error, e} <- Enum.with_index(List.wrap(injection["template_errors"]))}
              id={"#{@id}-injection-#{i}-error-#{e}"}
              class="prompt-preview-error"
            >
              {error}
            </p>
            <%!-- `phx-no-format`: pre-wrap would render any whitespace the formatter adds. --%>
            <div :if={injection["text"]} class="prompt-preview-text" phx-no-format>{injection["text"]}</div>
          </li>
        </ol>
      </div>
    </div>
    """
  end

  defp token_estimate(tokens) do
    dpngettext(
      "prompts",
      "unit: estimated token count of prompt text",
      "≈%{token_count} token",
      "≈%{token_count} tokens",
      tokens,
      token_count: Mythweaver.Format.number(tokens)
    )
  end

  defp injection_position(position, nil), do: position

  defp injection_position(position, depth) do
    gettext_comment("Badge on a preview injection: its position code (untranslated, e.g. at_depth) and its depth.")

    dpgettext(
      "prompts",
      "badge: where a prompt injection is inserted, with its depth",
      "%{injection_position} · depth %{injection_depth}",
      injection_position: position,
      injection_depth: Mythweaver.Format.number(depth)
    )
  end

  defp character_options(nil), do: []

  defp character_options(chat) do
    for p <- chat.participants do
      if p.character_id == chat.player_character_id,
        do: {player_option(p.character.name), p.character_id},
        else: {p.character.name, p.character_id}
    end
  end

  # Lore errors live on each activated entry, not on a section; hidden entries' were already dropped.
  defp lore_errors(nil), do: []

  defp lore_errors(result) do
    for entry <- Map.get(result.lore, "activated", []),
        error <- Map.get(entry, "template_errors", []),
        do: lore_error(entry["entry_name"], error)
  end

  defp player_option(character_name) do
    dpgettext("prompts", "option: the chat's player character, by name", "%{character_name} (player)",
      character_name: character_name
    )
  end

  defp lore_error(entry_name, error) do
    gettext_comment("A lore entry's template error in the prompt preview; the error is the template engine's message.")

    dpgettext(
      "prompts",
      "status: template error of a lore entry in the prompt preview",
      "%{entry_name}: %{template_error}",
      entry_name: entry_name,
      template_error: error
    )
  end
end
