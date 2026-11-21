defmodule MythweaverWeb.CommandPalette do
  @moduledoc """
  The command palette (Cmd-P on macOS, Ctrl-P elsewhere), rendered on every page by
  `Layouts.app`. It lists `MythweaverWeb.CommandPalette.Commands` filtered by a fuzzy query,
  recently used first; a command with parameters then asks for each one, with suggestions under
  the focused input.

  It runs in the host LiveView's process, so it navigates with `push_navigate/2` and reaches the
  host with `send(self(), …)`: `{__MODULE__, :flash, kind, message}` (handled for every LiveView
  by `MythweaverWeb.CommandPalette.Hook`) and `{__MODULE__, :chat_event, event, params}` (handled
  by `MainChatLive`, the only page that passes a `chat`).

  The client only opens it, forwards navigation keys, moves focus on request, and keeps the
  history (command ids, newest first) in `localStorage`.
  """

  use MythweaverWeb, :live_component

  alias Mythweaver.Attachments
  alias Mythweaver.Scripts
  alias MythweaverWeb.CommandPalette.Commands
  alias MythweaverWeb.CommandPalette.Fuzzy
  alias MythweaverWeb.CommandPalette.Suggestions
  alias MythweaverWeb.Shortcuts
  alias MythweaverWeb.Uploads

  @history_limit 20
  @suggestion_limit 50

  @closed [
    open?: false,
    recent: [],
    commands: [],
    query: "",
    results: [],
    selected: 0,
    mode: :list,
    command: nil,
    fields: [],
    focused: 0,
    candidates: %{},
    suggestions: [],
    suggestion: 0,
    # Images this palette stored that no command has taken yet; deleted when it closes.
    uploaded: []
  ]

  # An `:image` parameter's file, picked or pasted, stored as soon as it arrives.
  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(@closed)
     |> Uploads.allow_images(:palette_image, 1, progress: &upload_progress/3)}
  end

  # A chat switch while open would leave commands bound to the old chat's choices.
  @impl true
  def update(assigns, socket) do
    old_id = chat_id(socket.assigns[:chat])
    socket = assign(socket, chat: assigns[:chat], current_scope: assigns[:current_scope])

    if socket.assigns.open? and chat_id(socket.assigns.chat) != old_id,
      do: {:ok, close(socket)},
      else: {:ok, socket}
  end

  defp chat_id(nil), do: nil
  defp chat_id(chat), do: chat.id

  @impl true
  def handle_event("toggle", _params, %{assigns: %{current_scope: nil}} = socket), do: {:noreply, socket}

  def handle_event("toggle", params, socket) do
    if socket.assigns.open? do
      {:noreply, close(socket)}
    else
      recent = for(id <- List.wrap(params["recent"]), is_binary(id), do: id) |> Enum.take(@history_limit)

      {:noreply,
       socket
       |> assign(@closed)
       |> assign(
         open?: true,
         recent: recent,
         commands: Commands.list(socket.assigns.current_scope, socket.assigns.chat)
       )
       |> compute_results()}
    end
  end

  def handle_event("shortcut", _params, %{assigns: %{current_scope: nil}} = socket), do: {:noreply, socket}

  def handle_event("shortcut", %{"id" => id}, socket) when is_binary(id) do
    case Commands.get(socket.assigns.current_scope, socket.assigns.chat, id) do
      nil -> {:noreply, socket}
      command -> {:noreply, socket |> assign(command: command) |> execute(%{})}
    end
  end

  def handle_event("close", _params, socket), do: {:noreply, close(socket)}

  def handle_event("query", %{"query" => query}, socket) when is_binary(query) do
    {:noreply, socket |> assign(query: query) |> compute_results()}
  end

  def handle_event("choose", %{"index" => index}, socket) do
    case index(index, length(socket.assigns.results)) do
      nil -> {:noreply, socket}
      i -> {:noreply, socket |> assign(selected: i) |> list_enter()}
    end
  end

  def handle_event("focus_field", %{"index" => index}, socket) do
    case index(index, length(socket.assigns.fields)) do
      nil -> {:noreply, socket}
      i -> {:noreply, socket |> assign(focused: i) |> load_candidates(i) |> refilter()}
    end
  end

  def handle_event("args", params, %{assigns: %{mode: :args}} = socket) do
    socket = reject_invalid_uploads(socket)
    texts = if is_map(params["args"]), do: params["args"], else: %{}

    fields =
      socket.assigns.fields
      |> Enum.with_index()
      |> Enum.map(fn {field, i} ->
        case texts[Integer.to_string(i)] do
          text when is_binary(text) and text != field.text -> %{field | text: text, value: nil, error: nil}
          _ -> field
        end
      end)

    focused =
      case params["_target"] do
        ["args", i] -> index(i, length(fields)) || socket.assigns.focused
        _ -> socket.assigns.focused
      end

    {:noreply, socket |> assign(fields: fields, focused: focused) |> load_candidates(focused) |> refilter()}
  end

  def handle_event("args", _params, socket), do: {:noreply, socket}

  def handle_event("pick", %{"index" => index}, socket) do
    case index(index, length(socket.assigns.suggestions)) do
      nil -> {:noreply, socket}
      i -> {:noreply, socket |> assign(suggestion: i) |> accept() |> advance()}
    end
  end

  def handle_event("key", %{"key" => key} = params, socket) do
    {:reply, %{}, key(socket.assigns.mode, key, params["shift"] == true, socket)}
  end

  defp key(:list, "ArrowDown", _shift, socket),
    do: assign(socket, selected: step(socket.assigns.selected, 1, length(socket.assigns.results)))

  defp key(:list, "ArrowUp", _shift, socket),
    do: assign(socket, selected: step(socket.assigns.selected, -1, length(socket.assigns.results)))

  defp key(:list, "Enter", _shift, socket), do: list_enter(socket)
  defp key(:list, "Escape", _shift, socket), do: close(socket)

  defp key(:args, "ArrowDown", _shift, socket),
    do: assign(socket, suggestion: step(socket.assigns.suggestion, 1, length(socket.assigns.suggestions)))

  defp key(:args, "ArrowUp", _shift, socket),
    do: assign(socket, suggestion: step(socket.assigns.suggestion, -1, length(socket.assigns.suggestions)))

  defp key(:args, "Tab", false, socket) do
    socket = if acceptable?(socket), do: accept(socket), else: socket
    focus(socket, min(socket.assigns.focused + 1, length(socket.assigns.fields) - 1))
  end

  defp key(:args, "Tab", true, socket), do: focus(socket, max(socket.assigns.focused - 1, 0))

  defp key(:args, "Enter", _shift, socket) do
    socket = if acceptable?(socket), do: accept(socket), else: socket
    advance(socket)
  end

  defp key(:args, "Escape", _shift, socket) do
    socket
    |> discard_uploads()
    |> assign(mode: :list, command: nil, fields: [], focused: 0, candidates: %{}, suggestions: [], suggestion: 0)
    |> push_event("command_palette:focus", %{id: "command-palette-input"})
  end

  defp key(_mode, _key, _shift, socket), do: socket

  defp step(_current, _delta, 0), do: 0
  defp step(current, delta, count), do: Integer.mod(current + delta, count)

  # A phx-value arrives as a string; anything else or out of range is ignored.
  defp index(value, count) when is_binary(value) do
    case Integer.parse(value) do
      {i, ""} when i >= 0 and i < count -> i
      _ -> nil
    end
  end

  defp index(_value, _count), do: nil

  defp close(socket), do: socket |> discard_uploads() |> assign(@closed)

  defp discard_uploads(socket) do
    socket =
      Enum.reduce(socket.assigns.uploads.palette_image.entries, socket, &cancel_upload(&2, :palette_image, &1.ref))

    Attachments.delete_unlinked(socket.assigns.current_scope, socket.assigns.uploaded)
    assign(socket, uploaded: [])
  end

  # A finished upload is stored at once and fills the `:image` field, replacing an earlier pick.
  defp upload_progress(:palette_image, %{done?: true} = entry, socket) do
    case {image_field(socket), Uploads.consume_image(socket, entry)} do
      {{field, i}, {:ok, attachment}} ->
        Attachments.delete_unlinked(socket.assigns.current_scope, socket.assigns.uploaded)
        field = %{field | text: entry.client_name, value: attachment.id, error: nil}

        {:noreply, assign(socket, fields: List.replace_at(socket.assigns.fields, i, field), uploaded: [attachment.id])}

      {nil, {:ok, attachment}} ->
        Attachments.delete_unlinked(socket.assigns.current_scope, [attachment.id])
        {:noreply, socket}

      {found, {:error, reason}} ->
        {:noreply, put_image_error(socket, found, Uploads.error_text(reason))}
    end
  end

  defp upload_progress(:palette_image, _entry, socket), do: {:noreply, socket}

  # Too large, the wrong type or one too many: dropped, with the reason on the field.
  defp reject_invalid_uploads(socket) do
    upload = socket.assigns.uploads.palette_image
    errors = upload_errors(upload) ++ Enum.flat_map(upload.entries, &upload_errors(upload, &1))

    socket =
      Enum.reduce(upload.entries, socket, &if(&1.valid?, do: &2, else: cancel_upload(&2, :palette_image, &1.ref)))

    case errors do
      [] -> socket
      [reason | _] -> put_image_error(socket, image_field(socket), Uploads.error_text(reason))
    end
  end

  defp put_image_error(socket, nil, _message), do: socket

  defp put_image_error(socket, {field, i}, message),
    do: assign(socket, fields: List.replace_at(socket.assigns.fields, i, %{field | error: message}))

  defp image_field(socket) do
    socket.assigns.fields |> Enum.with_index() |> Enum.find(fn {field, _i} -> field.param.type == :image end)
  end

  defp compute_results(socket) do
    %{commands: commands, recent: recent, query: query} = socket.assigns
    rank = recent |> Enum.with_index() |> Map.new()

    results =
      if String.trim(query) == "" do
        {recents, rest} = Enum.split_with(commands, &Map.has_key?(rank, &1.id))

        Enum.map(Enum.sort_by(recents, &rank[&1.id]), &result(&1, [], true)) ++
          Enum.map(rest, &result(&1, [], false))
      else
        commands
        |> Enum.with_index()
        |> Enum.flat_map(fn {command, i} ->
          case Fuzzy.match(query, command.title) do
            nil ->
              []

            {score, indices} ->
              [{{-score, Map.get(rank, command.id, 1000), i}, result(command, indices, Map.has_key?(rank, command.id))}]
          end
        end)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(&elem(&1, 1))
      end

    assign(socket, results: results, selected: 0)
  end

  defp result(command, indices, recent?) do
    %{command: command, segments: Fuzzy.segments(command.title, indices), recent?: recent?}
  end

  defp list_enter(socket) do
    case Enum.at(socket.assigns.results, socket.assigns.selected) do
      nil ->
        socket

      %{command: %{params: []} = command} ->
        socket |> assign(command: command) |> execute(%{})

      %{command: command} ->
        fields = Enum.map(command.params, &%{param: &1, text: "", value: nil, error: nil})

        socket
        |> assign(mode: :args, command: command, fields: fields, candidates: %{})
        |> focus(0)
    end
  end

  defp focus(socket, i) do
    socket
    |> assign(focused: i)
    |> load_candidates(i)
    |> refilter()
    |> push_event("command_palette:focus", %{id: "command-palette-arg-#{i}"})
  end

  defp load_candidates(socket, i) do
    case {Map.has_key?(socket.assigns.candidates, i), Enum.at(socket.assigns.fields, i)} do
      {false, %{param: param}} ->
        assign(socket,
          candidates:
            Map.put(
              socket.assigns.candidates,
              i,
              Suggestions.candidates(socket.assigns.current_scope, param, socket.assigns.chat)
            )
        )

      _ ->
        socket
    end
  end

  defp refilter(socket) do
    %{fields: fields, focused: focused, candidates: candidates} = socket.assigns

    suggestions =
      case {Enum.at(fields, focused), Map.get(candidates, focused)} do
        {%{text: text}, list} when is_list(list) ->
          list
          |> Enum.flat_map(fn candidate ->
            case Fuzzy.match(text, candidate.label) do
              nil -> []
              {score, indices} -> [{-score, Map.put(candidate, :segments, Fuzzy.segments(candidate.label, indices))}]
            end
          end)
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.take(@suggestion_limit)
          |> Enum.map(&elem(&1, 1))

        _ ->
          []
      end

    assign(socket, suggestions: suggestions, suggestion: 0)
  end

  # A highlighted suggestion replaces the field only while it holds typed text, not a pick.
  defp acceptable?(socket) do
    %{fields: fields, focused: focused, candidates: candidates, suggestions: suggestions} = socket.assigns
    is_list(candidates[focused]) and suggestions != [] and Enum.at(fields, focused).value == nil
  end

  defp accept(socket) do
    %{fields: fields, focused: focused, suggestions: suggestions, suggestion: suggestion} = socket.assigns

    case Enum.at(suggestions, suggestion) do
      nil ->
        socket

      %{value: value, label: label} ->
        fields = List.update_at(fields, focused, &%{&1 | text: label, value: value, error: nil})

        socket
        |> assign(fields: fields)
        # The client keeps a focused input's value, so the accepted label is set from there.
        |> push_event("command_palette:value", %{id: "command-palette-arg-#{focused}", value: label})
    end
  end

  defp advance(socket) do
    %{fields: fields, focused: focused} = socket.assigns
    blank = for {field, i} <- Enum.with_index(fields), String.trim(field.text) == "", do: {field, i}

    case Enum.find(blank, fn {_field, i} -> i > focused end) ||
           Enum.find(blank, fn {field, _i} -> not field.param.optional? end) do
      {_field, i} -> focus(socket, i)
      nil -> submit(socket)
    end
  end

  defp submit(socket) do
    socket =
      socket.assigns.fields
      |> Enum.with_index()
      |> Enum.reduce(socket, fn {field, i}, socket ->
        if field.value == nil and String.trim(field.text) != "", do: load_candidates(socket, i), else: socket
      end)

    %{fields: fields, candidates: candidates, uploads: uploads} = socket.assigns
    uploading? = uploads.palette_image.entries != []

    resolved =
      fields |> Enum.with_index() |> Enum.map(fn {field, i} -> resolve(field, candidates[i], uploading?) end)

    if Enum.all?(resolved, &match?({:ok, _}, &1)) do
      values = fields |> Enum.zip(resolved) |> Map.new(fn {field, {:ok, value}} -> {field.param.name, value} end)
      execute(socket, values)
    else
      errors = fields |> Enum.zip(resolved) |> Map.new(fn {field, result} -> {field.param.name, failure(result)} end)
      show_errors(socket, errors)
    end
  end

  defp failure({:error, message}), do: message
  defp failure({:ok, _}), do: nil

  defp resolve(field, candidates, uploading?) do
    text = String.trim(field.text)

    cond do
      field.value != nil and (is_list(candidates) or field.param.type == :image) ->
        {:ok, field.value}

      field.param.type == :image and uploading? ->
        {:error,
         dpgettext(
           "commands",
           "status: error under a palette image parameter whose upload is unfinished",
           "Still uploading."
         )}

      text == "" or field.param.type == :image ->
        if field.param.optional?,
          do: {:ok, nil},
          else:
            {:error, dpgettext("commands", "status: error under a required palette parameter left blank", "Required.")}

      is_list(candidates) ->
        case Enum.filter(candidates, &(String.downcase(String.trim(&1.label)) == String.downcase(text))) do
          [only] -> {:ok, only.value}
          _ -> {:error, dgettext("commands", "Pick one from the list.")}
        end

      true ->
        {:ok, field.text}
    end
  end

  defp show_errors(socket, errors) do
    fields = Enum.map(socket.assigns.fields, &%{&1 | error: errors[&1.param.name]})
    socket = assign(socket, fields: fields)

    case Enum.find_index(fields, & &1.error) do
      nil -> socket
      i -> focus(socket, i)
    end
  end

  defp execute(socket, values) do
    %{command: command, chat: chat} = socket.assigns

    case command.run.(values, chat) do
      {:navigate, path} ->
        socket |> close() |> push_navigate(to: path)

      # The command takes over the palette's uploads (`chat: caption image` stages its image).
      {:chat_event, event, params} ->
        send(self(), {__MODULE__, :chat_event, event, params})
        socket |> assign(uploaded: []) |> close()

      {:error, message} ->
        send(self(), {__MODULE__, :flash, :error, message})
        close(socket)

      {:task, fun} ->
        socket |> close() |> start_async(:run_task, Mythweaver.Locale.carry(fun))

      {:script, script_id} ->
        scope = socket.assigns.current_scope

        case Scripts.Command.cast_args(scope, command.params, values, chat) do
          {:ok, args} ->
            socket
            |> close()
            |> start_async(
              :run_command,
              Mythweaver.Locale.carry(fn -> Scripts.run_command(scope, script_id, chat, args) end)
            )

          {:error, errors} ->
            show_errors(socket, errors)
        end
    end
  end

  @impl true
  def handle_async(:run_command, {:ok, {:ok, notice, printed}}, socket) do
    [notice | printed]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> case do
      "" -> :ok
      message -> send(self(), {__MODULE__, :flash, :info, message})
    end

    {:noreply, socket}
  end

  def handle_async(:run_command, {:ok, {:error, message, printed}}, socket) do
    send(self(), {__MODULE__, :flash, :error, Enum.join(printed ++ [message], " ")})
    {:noreply, socket}
  end

  def handle_async(:run_command, {:ok, {:error, :unauthorized}}, socket) do
    send(self(), {__MODULE__, :flash, :error, unauthorized_message()})
    {:noreply, socket}
  end

  def handle_async(:run_command, {:exit, _reason}, socket) do
    send(self(), {__MODULE__, :flash, :error, script_crashed_message()})
    {:noreply, socket}
  end

  def handle_async(:run_task, {:ok, {:ok, message}}, socket) do
    send(self(), {__MODULE__, :flash, :info, message})
    {:noreply, socket}
  end

  def handle_async(:run_task, {:ok, {:error, message}}, socket) do
    send(self(), {__MODULE__, :flash, :error, message})
    {:noreply, socket}
  end

  def handle_async(:run_task, {:exit, _reason}, socket) do
    send(self(), {__MODULE__, :flash, :error, task_failed_message()})
    {:noreply, socket}
  end

  defp script_crashed_message do
    gettext_comment("Error flash when a Lua command script run from the command palette crashes.")
    dpgettext("commands", "status: flash after a palette command script crashed", "The command script crashed.")
  end

  defp task_failed_message do
    gettext_comment("Error flash when a built-in palette command that runs in the background (a cleanup) crashes.")
    dpgettext("commands", "status: flash after a background palette command crashed", "The command failed.")
  end

  defp hint(%{type: :string}), do: dpgettext("commands", "placeholder: palette parameter that takes free text", "Text")

  defp hint(%{type: :integer}),
    do: dpgettext("commands", "placeholder: palette parameter that takes a whole number", "Whole number")

  defp hint(%{type: :number}), do: dpgettext("commands", "placeholder: palette parameter that takes a number", "Number")

  defp hint(_param),
    do: dpgettext("commands", "placeholder: palette parameter with suggestions to filter", "Type to filter")

  defp field_label(%{label: label, optional?: true}) do
    gettext_comment("%{parameter_label} is the parameter's own label, e.g. \"Start\".")

    dpgettext("commands", "field label: an optional parameter of a palette command", "%{parameter_label} (optional)",
      parameter_label: label
    )
  end

  defp field_label(%{label: label}), do: label

  defp file_text(field, upload) do
    case upload.entries do
      [%{progress: progress} | _] ->
        dpgettext("commands", "status: palette image upload in progress", "Uploading… %{upload_percent}",
          upload_percent: Mythweaver.Format.percent(progress / 100)
        )

      [] when field.value != nil ->
        field.text

      [] ->
        dpgettext(
          "commands",
          "button: palette image parameter with no image yet, opens the file picker",
          "Choose an image…"
        )
    end
  end

  # The footer's key hints: `kbd` holds the key name, rendered as `<kbd>`.
  defp run_hint do
    gettext_comment("%{enter_key} is the Enter key's name in a <kbd> chip.")

    rich(
      dpgettext("commands", "tooltip: palette footer, the key that runs the command", "Run %{enter_key}",
        enter_key: kbd(dpgettext("commands", "keyboard key: enter", "enter"))
      )
    )
  end

  defp back_hint do
    gettext_comment("%{escape_key} is the Escape key's name in a <kbd> chip.")

    rich(
      dpgettext("commands", "tooltip: palette footer, the key that goes back to the command list", "Back %{escape_key}",
        escape_key: kbd(dpgettext("commands", "keyboard key: escape", "esc"))
      )
    )
  end

  defp next_hint do
    gettext_comment("%{tab_key} is the Tab key's name in a <kbd> chip.")

    rich(
      dpgettext("commands", "tooltip: palette footer, the key that moves to the next parameter", "Next %{tab_key}",
        tab_key: kbd(dpgettext("commands", "keyboard key: tab", "tab"))
      )
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      /* Every marked element is a scope root here, so the component root is named outright. */
      div.command-palette:scope {
        display: contents;
      }

      dialog.command-palette-dialog {
        margin: 12dvh auto auto;
        padding: 0;
        border: 0;
        background: none;
        inline-size: min(40rem, calc(100vw - 2 * var(--panel-gap)));
        max-inline-size: min(40rem, calc(100vw - 2 * var(--panel-gap)));
        color: var(--foreground);
      }

      .command-palette-dialog::backdrop {
        background: oklch(0 0 0 / 0.25);
      }

      .command-palette-panel {
        display: flex;
        flex-direction: column;
        max-block-size: 70dvh;
        background: var(--surface-4);
        border: 1px solid var(--border);
        border-radius: var(--radius-3);
        box-shadow: var(--elevation-2xl);
        overflow: hidden;
      }

      .command-palette-query {
        border-block-end: 1px solid var(--border);
      }

      .command-palette-input {
        display: block;
        inline-size: 100%;
        border: 0;
        background: transparent;
        font: inherit;
        font-size: var(--font-size-3);
        padding: var(--size-3);
        color: var(--foreground);
        outline: none;
      }

      .command-palette-list {
        list-style: none;
        margin: 0;
        padding: var(--size-1);
        overflow-y: auto;
        flex: 1 1 auto;
      }

      .command-palette-row,
      .command-palette-note {
        display: flex;
        justify-content: flex-start;
        align-items: center;
        gap: var(--size-2);
        padding: var(--size-2) var(--size-3);
        border-radius: var(--radius-2);
      }

      .command-palette-row .shortcut {
        margin-inline-start: auto;
      }

      .command-palette-row .command-palette-recent {
        margin-inline-start: var(--size-2);
      }

      .command-palette-note {
        justify-content: space-between;
      }

      .command-palette-row {
        cursor: pointer;
      }

      .command-palette-row:hover {
        background: var(--surface-6);
      }

      .command-palette-row[aria-selected="true"] {
        background: var(--surface-7);
      }

      .command-palette-match {
        color: var(--primary-accent);
        font-weight: 600;
      }

      .command-palette-recent,
      .command-palette-detail,
      .command-palette-note {
        color: var(--muted-foreground);
      }

      .command-palette-command,
      .command-palette-field {
        padding: var(--size-2) var(--size-3);
      }

      .command-palette-command {
        border-block-end: 1px solid var(--border);
      }

      .command-palette-command p {
        margin: var(--size-1) 0 0;
        color: var(--muted-foreground);
      }

      .command-palette-field label {
        display: grid;
        grid-template-columns: 10rem 1fr;
        align-items: center;
        gap: var(--size-2);
      }

      .command-palette-file {
        display: block;
        inline-size: 100%;
        text-align: start;
        font: inherit;
        color: var(--foreground);
        background: var(--surface-2);
        border: 1px solid var(--input);
        border-radius: var(--radius-2);
        padding: var(--size-2);
        cursor: pointer;
      }

      .command-palette-file--empty {
        color: var(--muted-foreground);
      }

      .command-palette-file-input {
        display: none;
      }

      .command-palette-args {
        border-block-end: 1px solid var(--border);
        padding-block: var(--size-1);
      }

      .command-palette-footer {
        border-block-start: 1px solid var(--border);
        display: flex;
        justify-content: flex-end;
        gap: var(--size-3);
        padding: var(--size-2) var(--size-3);
        font-size: var(--font-size-0);
        color: var(--muted-foreground);
      }

      .command-palette-footer kbd {
        font: inherit;
        opacity: 0.8;
      }

      @media (--phone) {
        dialog.command-palette-dialog {
          margin-block-start: calc(var(--panel-gap) + env(safe-area-inset-top));
        }
        .command-palette-field label {
          grid-template-columns: minmax(0, 1fr);
        }
        .command-palette-footer {
          flex-wrap: wrap;
        }
      }

      /* Keyboard chips mean nothing without a keyboard. */
      @media (--touch) {
        .command-palette-row .shortcut {
          display: none;
        }
      }
    </style>

    <div id="command-palette" class="command-palette" phx-hook=".CommandPalette" phx-target={@myself}>
      <dialog
        :if={@open?}
        id="command-palette-dialog"
        class="command-palette-dialog"
        phx-hook=".CommandPaletteDialog"
        phx-target={@myself}
        aria-label={
          dpgettext("commands", "aria label: the command palette dialog", "Command palette")
        }
      >
        <div class="command-palette-panel">
          <%= if @mode == :list do %>
            <.form
              for={%{}}
              id="command-palette-form"
              class="command-palette-query"
              phx-change="query"
              phx-target={@myself}
            >
              <.input
                type="text"
                name="query"
                value={@query}
                id="command-palette-input"
                class="command-palette-input"
                placeholder={
                  dpgettext(
                    "commands",
                    "placeholder: command palette search box",
                    "Execute a command…"
                  )
                }
                autocomplete="off"
              />
            </.form>
            <ul id="command-palette-results" class="command-palette-list" role="listbox">
              <li
                :for={{result, i} <- Enum.with_index(@results)}
                id={"command-palette-result-#{i}"}
                class="command-palette-row"
                role="option"
                aria-selected={"#{i == @selected}"}
                data-command-id={result.command.id}
                phx-click="choose"
                phx-value-index={i}
                phx-target={@myself}
              >
                <span class="command-palette-title" phx-no-format><%= for {text, matched?} <- result.segments do %><%= if matched? do %><span class="command-palette-match">{text}</span><% else %>{text}<% end %><% end %></span>
                <Shortcuts.keys keys={Shortcuts.keys_for_command(result.command.id)} />
                <span
                  :if={result.recent?}
                  class="command-palette-recent"
                  title={
                    dpgettext(
                      "commands",
                      "tooltip: icon on a palette command used recently",
                      "Recently used"
                    )
                  }
                >
                  <.lucide name="rotate-ccw-clock" />
                </span>
              </li>
              <li :if={@results == []} id="command-palette-empty" class="command-palette-note">
                {dpgettext(
                  "commands",
                  "empty state: no palette command matches the search",
                  "No matching commands"
                )}
              </li>
            </ul>
            <footer class="command-palette-footer">
              <span>{run_hint()}</span>
            </footer>
          <% else %>
            <header class="command-palette-command">
              <strong>{@command.title}</strong>
              <p :if={@command.description}>{@command.description}</p>
            </header>
            <.form
              for={%{}}
              id="command-palette-args"
              class="command-palette-args"
              phx-change="args"
              phx-target={@myself}
            >
              <div :for={{field, i} <- Enum.with_index(@fields)} class="command-palette-field">
                <%= if field.param.type == :image do %>
                  <div>
                    <label for={"command-palette-arg-#{i}"}>
                      <span>{field_label(field.param)}</span>
                      <button
                        type="button"
                        id={"command-palette-arg-#{i}"}
                        class={[
                          "command-palette-file",
                          field.value == nil && "command-palette-file--empty"
                        ]}
                        data-file-pick
                        data-empty={"#{field.value == nil}"}
                        phx-focus="focus_field"
                        phx-value-index={i}
                        phx-target={@myself}
                      >
                        {file_text(field, @uploads.palette_image)}
                      </button>
                    </label>
                    <.error :for={message <- List.wrap(field.error)}>{message}</.error>
                  </div>
                  <.live_file_input
                    upload={@uploads.palette_image}
                    class="command-palette-file-input"
                  />
                <% else %>
                  <.input
                    type="text"
                    name={"args[#{i}]"}
                    value={field.text}
                    id={"command-palette-arg-#{i}"}
                    label={field_label(field.param)}
                    placeholder={hint(field.param)}
                    errors={List.wrap(field.error)}
                    autocomplete="off"
                    phx-focus="focus_field"
                    phx-value-index={i}
                    phx-target={@myself}
                  />
                <% end %>
              </div>
            </.form>
            <ul id="command-palette-suggestions" class="command-palette-list" role="listbox">
              <%= case @candidates[@focused] do %>
                <% :free -> %>
                  <li id="command-palette-hint" class="command-palette-note">
                    {dpgettext(
                      "commands",
                      "empty state: palette parameter that takes typed text",
                      "Type a value"
                    )}
                  </li>
                <% :upload -> %>
                  <li id="command-palette-upload-hint" class="command-palette-note">
                    {dgettext("commands", "Choose a PNG, JPEG or WebP image, or paste one")}
                  </li>
                <% _list -> %>
                  <li
                    :for={{suggestion, i} <- Enum.with_index(@suggestions)}
                    id={"command-palette-suggestion-#{i}"}
                    class="command-palette-row"
                    role="option"
                    aria-selected={"#{i == @suggestion}"}
                    phx-click="pick"
                    phx-value-index={i}
                    phx-target={@myself}
                  >
                    <span class="command-palette-title" phx-no-format><%= for {text, matched?} <- suggestion.segments do %><%= if matched? do %><span class="command-palette-match">{text}</span><% else %>{text}<% end %><% end %></span>
                    <span :if={suggestion.detail} class="command-palette-detail">{suggestion.detail}</span>
                  </li>
                  <li
                    :if={@suggestions == []}
                    id="command-palette-no-match"
                    class="command-palette-note"
                  >
                    {dpgettext(
                      "commands",
                      "empty state: no suggestion matches a palette parameter's text",
                      "No matches"
                    )}
                  </li>
              <% end %>
            </ul>
            <footer class="command-palette-footer">
              <span>{back_hint()}</span>
              <span>{next_hint()}</span>
              <span>{run_hint()}</span>
            </footer>
          <% end %>
        </div>
      </dialog>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".CommandPalette">
        const HISTORY_KEY = "mythweaver:command-palette-history";

        function history() {
          try {
            const list = JSON.parse(localStorage.getItem(HISTORY_KEY) || "[]");
            return Array.isArray(list)
              ? list.filter((id) => typeof id === "string")
              : [];
          } catch (_e) {
            return [];
          }
        }

        export default {
          mounted() {
            // `MythweaverWeb.Shortcuts`' listener owns Mod-P and dispatches this.
            this.onToggle = () =>
              this.pushEventTo(this.el, "toggle", { recent: history() });
            window.addEventListener("shortcuts:palette", this.onToggle);
          },
          destroyed() {
            window.removeEventListener("shortcuts:palette", this.onToggle);
          },
        };
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".CommandPaletteDialog">
        const HISTORY_KEY = "mythweaver:command-palette-history";
        const HISTORY_LIMIT = 20;
        const KEYS = ["ArrowUp", "ArrowDown", "Enter", "Tab", "Escape"];

        function remember(id) {
          let list = [];
          try {
            const stored = JSON.parse(localStorage.getItem(HISTORY_KEY) || "[]");
            if (Array.isArray(stored))
              list = stored.filter((s) => typeof s === "string");
          } catch (_e) {}
          list = [id, ...list.filter((s) => s !== id)].slice(0, HISTORY_LIMIT);
          localStorage.setItem(HISTORY_KEY, JSON.stringify(list));
        }

        function focusEnd(input) {
          if (!input) return;
          input.focus();
          const end = input.value.length;
          input.setSelectionRange?.(end, end);
        }

        export default {
          mounted() {
            this.previous = document.activeElement;
            // See `MythweaverWeb.CoreComponents.Modal`: opened from the client so it is modal,
            // and `open` survives patches.
            this.el.showModal();
            this.js().ignoreAttributes(this.el, ["open"]);
            focusEnd(this.el.querySelector("#command-palette-input"));

            // Escape is a palette key (back, then close), not the dialog's own cancel.
            this.el.addEventListener("cancel", (e) => e.preventDefault());
            this.el.addEventListener("close", () =>
              this.pushEventTo(this.el, "close", {}),
            );
            const fileInput = () =>
              this.el.querySelector("input[type=file][name=palette_image]");

            this.el.addEventListener("click", (e) => {
              if (e.target === this.el) return this.el.close();
              const row = e.target.closest("[data-command-id]");
              if (row) remember(row.dataset.commandId);
              if (e.target.closest("[data-file-pick]")) fileInput()?.click();
            });

            // A pasted image fills an image parameter; a text paste into a text field stays one.
            this.el.addEventListener("paste", (e) => {
              const input = fileInput();
              const data = e.clipboardData;
              const images = [...(data?.files ?? [])].filter((f) =>
                f.type.startsWith("image/"),
              );
              if (!input || images.length === 0) return;
              const typing =
                e.target.matches?.("input[type=text]") &&
                data.types.includes("text/plain");
              if (typing) return;
              e.preventDefault();
              const files = new DataTransfer();
              files.items.add(images[0]);
              this.upload(input.name, files.files);
            });

            this.el.addEventListener("keydown", (e) => {
              if (e.isComposing || !KEYS.includes(e.key)) return;
              e.preventDefault();
              e.stopPropagation();

              // Enter on an image parameter with nothing chosen yet opens the file picker.
              if (
                e.key === "Enter" &&
                e.target.matches?.('[data-file-pick][data-empty="true"]')
              )
                return fileInput()?.click();

              if (e.key === "Enter") {
                const row = this.el.querySelector(
                  '[data-command-id][aria-selected="true"]',
                );
                if (row) remember(row.dataset.commandId);
              }

              this.pushEventTo(
                this.el,
                "key",
                { key: e.key, shift: e.shiftKey },
                () => {
                  this.el
                    .querySelector('[aria-selected="true"]')
                    ?.scrollIntoView({ block: "nearest" });
                },
              );
            });

            this.handleEvent("command_palette:focus", ({ id }) =>
              focusEnd(document.getElementById(id)),
            );
            this.handleEvent("command_palette:value", ({ id, value }) => {
              const input = document.getElementById(id);
              if (input) input.value = value;
            });
          },
          destroyed() {
            if (this.previous?.isConnected) this.previous.focus();
          },
        };
      </script>
    </div>
    """
  end
end
