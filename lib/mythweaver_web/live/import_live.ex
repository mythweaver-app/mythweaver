defmodule MythweaverWeb.ImportLive do
  @moduledoc """
  The `/import` page: drop SillyTavern and Character Card files, review what each one holds, and
  import them one by one through `Mythweaver.Import`.

  Each dropped file is parsed as soon as it finishes uploading and kept server-side in `@items`
  (a plain list, since every item carries its parsed file). Chats get speaker → character
  selects; presets get an optional model whose samplers the preset overwrites; Mythweaver bundles
  get a Replace / Copy / Skip select per item (`Mythweaver.Import.Review`).
  """
  use MythweaverWeb, :live_view

  alias Mythweaver.AI
  alias Mythweaver.AI.Model
  alias Mythweaver.Characters
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Import
  alias Mythweaver.Import.Review

  # Import files, not images: a card PNG carries its JSON (lore books included), so it can be well
  # over the image upload limit, and a Mythweaver bundle carries whole chats with their images. The
  # avatar taken from a card is still held to the image limit, without the card text (`Import.Png`).
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Memory.Profile
  alias Mythweaver.Memory.SidePrompt
  alias Mythweaver.Memory.SidePromptSet
  alias Mythweaver.Prompts.Prompt
  alias Mythweaver.Scripts.Script
  alias MythweaverWeb.LiveSync

  @max_file_bytes 200_000_000

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(
       page_title: dpgettext("import_export", "page title: import files", "Import"),
       items: [],
       characters: Characters.list_characters(scope),
       models: AI.list_editable_models(scope)
     )
     |> allow_upload(:import_files,
       accept: ~w(.png .json .jsonl .charx .mythweaver),
       max_entries: 20,
       max_file_size: @max_file_bytes,
       auto_upload: true,
       progress: &handle_progress/3
     )
     |> LiveSync.attach([:characters, :ai], &sync/2)}
  end

  defp sync(socket, _kinds) do
    scope = socket.assigns.current_scope

    assign(socket,
      characters: Characters.list_characters(scope),
      models: AI.list_editable_models(scope)
    )
  end

  defp handle_progress(:import_files, %{done?: true} = entry, socket) do
    bytes = consume_uploaded_entry(socket, entry, fn %{path: path} -> {:ok, File.read!(path)} end)
    parsed = Import.parse(entry.client_name, bytes)

    item = %{
      id: entry.ref,
      filename: entry.client_name,
      parsed: parsed,
      defaults: defaults(socket.assigns.current_scope, parsed),
      result: nil,
      held: nil,
      error: nil
    }

    {:noreply, update(socket, :items, &(&1 ++ [item]))}
  end

  defp handle_progress(:import_files, _entry, socket), do: {:noreply, socket}

  # Default select values for a chat: the player speaker, and each speaker's mapping.
  defp defaults(scope, {:ok, %{kind: :chat} = chat}) do
    player =
      Enum.find(chat.speakers, List.first(chat.speakers), &(&1.name == chat.player_name))

    speakers =
      Map.new(chat.speakers, fn speaker ->
        value =
          case Characters.find_character_by_name(scope, speaker.name) do
            %{id: id} -> "character:#{id}"
            nil when speaker.narrator? -> "name_only"
            nil -> "create"
          end

        {speaker.key, value}
      end)

    %{player: player && player.key, speakers: speakers}
  end

  defp defaults(scope, {:ok, %{kind: :bundle, bundle: bundle}}), do: %{review: Review.review(scope, bundle)}

  defp defaults(_scope, _parsed), do: %{}

  @impl true
  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("remove_item", %{"id" => id}, socket) do
    {:noreply, update(socket, :items, fn items -> Enum.reject(items, &(&1.id == id)) end)}
  end

  def handle_event("import", %{"import" => %{"id" => id} = params}, socket) do
    case Enum.find(socket.assigns.items, &(&1.id == id)) do
      %{parsed: {:ok, parsed}, result: nil, held: nil} = item ->
        item = run_import(socket.assigns.current_scope, item, parsed, params)

        items = Enum.map(socket.assigns.items, &if(&1.id == id, do: item, else: &1))
        {:noreply, assign(socket, items: items)}

      _ ->
        {:noreply, socket}
    end
  end

  defp run_import(scope, item, parsed, params) do
    case Import.import(scope, parsed, import_opts(parsed, params)) do
      {:ok, result} -> %{item | result: result, error: nil}
      {:held, hold} -> %{item | held: hold, error: nil}
      {:error, message} -> %{item | error: message}
    end
  end

  defp import_opts(%{kind: :chat} = chat, params) do
    speaker_params = params["speakers"] || %{}

    speakers =
      Map.new(chat.speakers, fn speaker ->
        {speaker.key, speaker_choice(speaker_params[to_string(speaker.key)])}
      end)

    [player: parse_key(params["player"]), speakers: speakers]
  end

  defp import_opts(%{kind: :preset}, params) do
    case params["model_id"] do
      id when is_binary(id) and id != "" -> [model_id: id]
      _ -> [model_id: nil]
    end
  end

  defp import_opts(%{kind: :bundle}, params) do
    decisions =
      for {uid, value} <- params["decisions"] || %{},
          decision = decision(value),
          into: %{},
          do: {uid, decision}

    [decisions: decisions]
  end

  defp import_opts(_parsed, _params), do: []

  defp speaker_choice("character:" <> id), do: {:character, id}
  defp speaker_choice("name_only"), do: :name_only
  defp speaker_choice(_), do: :create

  defp decision("replace"), do: :replace
  defp decision("copy"), do: :copy
  defp decision("skip"), do: :skip
  defp decision(_), do: nil

  defp parse_key(value) when is_binary(value) do
    case Integer.parse(value) do
      {key, ""} -> key
      _ -> nil
    end
  end

  defp parse_key(_), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      /* The page is one panel. Its root is the scope root, so it needs `:scope`; the class keeps
         slot content (also scope roots, e.g. inside `<.form>`) from matching. */
      div.import-page:scope {
        margin: var(--panel-gap);
        border: 1px solid var(--border);
        border-radius: var(--radius-3);
        background: var(--card);
        box-shadow: var(--elevation-lg);
        overflow-y: auto;
      }

      .import-body {
        display: flex;
        flex-direction: column;
        gap: var(--size-4);
        padding: var(--size-4);
      }

      .import-drop {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
        padding: var(--size-6);
        border: 1px dashed var(--border);
        border-radius: var(--radius-2);
        text-align: center;
      }

      .import-items {
        display: flex;
        flex-direction: column;
        gap: var(--size-3);
        margin: 0;
        padding: 0;
        list-style: none;
      }

      .import-item {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
        padding: var(--size-3);
        border: 1px solid var(--border);
        border-radius: var(--radius-2);
      }

      .import-item-head {
        display: flex;
        flex-wrap: wrap;
        gap: var(--size-2);
        align-items: baseline;
      }

      .import-item-kind,
      .import-item-summary,
      .import-warnings {
        color: var(--muted-foreground);
      }

      .import-error {
        color: var(--destructive);
      }

      /* Inside `<.form>` the row is slot content, a scope root of its own: hence `:scope`. */
      .import-item-actions,
      div.import-item-actions:scope {
        display: flex;
        gap: var(--size-2);
      }

      @media (--phone) {
        .import-item-actions,
        div.import-item-actions:scope {
          flex-wrap: wrap;
        }
      }
    </style>

    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="import-page">
        <.panel_header>
          {dpgettext("import_export", "heading: import files", "Import")}
          <:actions>
            <.button size="sm" navigate={~p"/export"} id="import-open-export">
              {dpgettext("import_export", "link: open the export page", "Export…")}
            </.button>
          </:actions>
        </.panel_header>
        <div class="import-body">
          <p>
            {dgettext(
              "import_export",
              "SillyTavern characters, chats (.jsonl), lore books and Chat Completion presets, Character Card V1–V3 files (PNG, JSON, CHARX), and Mythweaver bundles (.mythweaver)."
            )}
          </p>

          <form id="import-upload-form" phx-change="validate_upload" phx-submit="validate_upload">
            <div class="import-drop" phx-drop-target={@uploads.import_files.ref}>
              <span>{dgettext("import_export", "Drop files here or choose them")}</span>
              <.live_file_input upload={@uploads.import_files} />
            </div>
            <p :for={err <- upload_errors(@uploads.import_files)} class="import-error">
              {upload_error_text(err)}
            </p>
            <%= for entry <- @uploads.import_files.entries do %>
              <p :for={err <- upload_errors(@uploads.import_files, entry)} class="import-error">
                {dpgettext(
                  "import_export",
                  "status: upload error for one file",
                  "%{file_name}: %{upload_error}",
                  file_name: entry.client_name,
                  upload_error: upload_error_text(err)
                )}
              </p>
            <% end %>
          </form>

          <ul id="import-items" class="import-items">
            <li :for={item <- @items} id={"import-item-#{item.id}"} class="import-item">
              <div class="import-item-head">
                <strong>{item.filename}</strong>
                <span :if={match?({:ok, _}, item.parsed)} class="import-item-kind">
                  {kind_label(elem(item.parsed, 1).kind)}
                </span>
              </div>

              <%= case item.parsed do %>
                <% {:error, message} -> %>
                  <p class="import-error">{message}</p>
                  <div class="import-item-actions">
                    <.button type="button" phx-click="remove_item" phx-value-id={item.id}>
                      {remove_label()}
                    </.button>
                  </div>
                <% {:ok, parsed} -> %>
                  <p class="import-item-summary">{summary(parsed)}</p>
                  <ul :if={parsed.warnings != []} class="import-warnings">
                    <li :for={warning <- parsed.warnings}>{warning}</li>
                  </ul>

                  <.form
                    :if={is_nil(item.result) and is_nil(item.held)}
                    for={%{}}
                    as={:import}
                    id={"import-item-form-#{item.id}"}
                    phx-submit="import"
                  >
                    <input type="hidden" name="import[id]" value={item.id} />

                    <%= if parsed.kind == :chat do %>
                      <.input
                        type="select"
                        name="import[player]"
                        id={"import-item-#{item.id}-player"}
                        label={
                          dpgettext(
                            "import_export",
                            "field label: speaker who is the player in an imported chat",
                            "Player"
                          )
                        }
                        options={Enum.map(parsed.speakers, &{&1.name, &1.key})}
                        value={item.defaults.player}
                      />
                      <.input
                        :for={speaker <- parsed.speakers}
                        type="select"
                        name={"import[speakers][#{speaker.key}]"}
                        id={"import-item-#{item.id}-speaker-#{speaker.key}"}
                        label={speaker_label(speaker)}
                        options={speaker_options(@characters)}
                        value={item.defaults.speakers[speaker.key]}
                      />
                    <% end %>

                    <.input
                      :if={parsed.kind == :preset}
                      type="select"
                      name="import[model_id]"
                      id={"import-item-#{item.id}-model"}
                      label={
                        dpgettext(
                          "import_export",
                          "field label: model whose samplers an imported preset overwrites",
                          "Model samplers"
                        )
                      }
                      options={[
                        {dpgettext(
                           "import_export",
                           "option: import a preset without changing any model",
                           "Don't change any model's samplers"
                         ), ""}
                        | Enum.map(@models, &{&1.name, &1.id})
                      ]}
                      value=""
                    />

                    <%= if parsed.kind == :bundle do %>
                      <.input
                        :for={row <- item.defaults.review}
                        type="select"
                        name={"import[decisions][#{row.uid}]"}
                        id={"import-item-#{item.id}-decision-#{row.uid}"}
                        label={decision_label(row)}
                        options={Enum.map(row.options, &{Review.labels()[&1], Atom.to_string(&1)})}
                        value={Atom.to_string(row.default)}
                      />
                    <% end %>

                    <p :if={item.error} class="import-error">{item.error}</p>

                    <div class="import-item-actions">
                      <.button variant="primary" type="submit" id={"import-item-submit-#{item.id}"}>
                        {dpgettext("import_export", "button: import this file", "Import")}
                      </.button>
                      <.button type="button" phx-click="remove_item" phx-value-id={item.id}>
                        {remove_label()}
                      </.button>
                    </div>
                  </.form>

                  <p :if={item.held} id={"import-item-#{item.id}-held"} class="import-item-summary">
                    {dpgettext(
                      "import_export",
                      "status: imported file held for moderation",
                      "Waiting for moderator review"
                    )}
                  </p>

                  <%= if item.result do %>
                    <ul :if={item.result.warnings != []} class="import-warnings">
                      <li :for={warning <- item.result.warnings}>{warning}</li>
                    </ul>
                    <div class="import-item-actions">
                      <.button navigate={open_path(item.result)} id={"import-item-open-#{item.id}"}>
                        {dpgettext("import_export", "button: open the item just imported", "Open")}
                      </.button>
                    </div>
                  <% end %>
              <% end %>
            </li>
          </ul>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp remove_label, do: dpgettext("import_export", "button: remove a file from the import list", "Remove")

  defp upload_error_text(:not_accepted),
    do: dgettext("import_export", "Only PNG, CHARX, JSON, JSONL and Mythweaver bundle files can be imported")

  defp upload_error_text(:too_large),
    do:
      dgettext("import_export", "File is larger than %{limit_megabytes}",
        limit_megabytes: Mythweaver.Format.megabytes(div(@max_file_bytes, 1_000_000))
      )

  defp upload_error_text(:too_many_files), do: dpgettext("import_export", "status: upload error", "Too many files")

  defp upload_error_text(_other), do: dpgettext("import_export", "status: upload error", "Upload failed")

  defp speaker_label(speaker) do
    dpngettext(
      "import_export",
      "field label: imported chat speaker, with how many messages they wrote",
      "%{speaker_name} (%{message_count} message)",
      "%{speaker_name} (%{message_count} messages)",
      speaker.count,
      speaker_name: speaker.name,
      message_count: Mythweaver.Format.number(speaker.count)
    )
  end

  defp speaker_options(characters) do
    [
      {dpgettext("import_export", "option: create a character for an imported chat speaker", "Create new character"),
       "create"},
      {dpgettext("import_export", "option: keep an imported chat speaker as a name only", "Name only (no character)"),
       "name_only"}
    ] ++
      Enum.map(characters, &{&1.name, "character:#{&1.id}"})
  end

  defp kind_label(:character), do: dpgettext("import_export", "badge: kind of an imported file", "Character card")
  defp kind_label(:lore_book), do: dpgettext("import_export", "badge: kind of an imported file", "Lore book")
  defp kind_label(:chat), do: dpgettext("import_export", "badge: kind of an imported file", "Chat")
  defp kind_label(:preset), do: dpgettext("import_export", "badge: kind of an imported file", "Chat Completion preset")
  defp kind_label(:bundle), do: dpgettext("import_export", "badge: kind of an imported file", "Mythweaver bundle")

  defp decision_label(%{match: nil} = row),
    do:
      dpgettext("import_export", "field label: import decision for a bundle item", "%{item_kind} · %{item_name}",
        item_kind: Review.kind_label(row.kind),
        item_name: row.name
      )

  defp decision_label(%{match: match} = row),
    do:
      dgettext("import_export", "%{item_kind} · %{item_name} — matches %{match_name}",
        item_kind: Review.kind_label(row.kind),
        item_name: row.name,
        match_name: match.name
      )

  defp summary(%{kind: :character} = character) do
    book_entries = if character.book, do: length(character.book.entries), else: 0
    card_entries = length(character.card_fields)

    gettext_comment("Summary of an imported character card; the placeholders are counts like “3 card entries”.")

    dpgettext(
      "import_export",
      "status: summary of an imported character card",
      "%{character_name}: %{card_entry_total}, %{lore_entry_total}",
      character_name: character.name,
      card_entry_total:
        dpngettext(
          "import_export",
          "unit: card entries in an imported character",
          "%{entry_count} card entry",
          "%{entry_count} card entries",
          card_entries,
          entry_count: Mythweaver.Format.number(card_entries)
        ),
      lore_entry_total:
        dpngettext(
          "import_export",
          "unit: lore entries in an imported character",
          "%{entry_count} lore entry",
          "%{entry_count} lore entries",
          book_entries,
          entry_count: Mythweaver.Format.number(book_entries)
        )
    )
  end

  defp summary(%{kind: :lore_book} = book) do
    n = length(book.entries)

    dpngettext(
      "import_export",
      "status: summary of an imported lore book",
      "%{entry_count} entry",
      "%{entry_count} entries",
      n,
      entry_count: Mythweaver.Format.number(n)
    )
  end

  defp summary(%{kind: :chat, messages: messages}) do
    times = Enum.map(messages, & &1.inserted_at)
    first = Enum.min(times, DateTime)
    last = Enum.max(times, DateTime)
    n = length(messages)

    dpngettext(
      "import_export",
      "status: summary of an imported chat",
      "%{message_count} message, %{date_range}",
      "%{message_count} messages, %{date_range}",
      n,
      message_count: Mythweaver.Format.number(n),
      date_range:
        dpgettext(
          "import_export",
          "date range: first to last message of the imported chat",
          "%{start_date} to %{end_date}",
          start_date: Mythweaver.Format.date(DateTime.to_date(first)),
          end_date: Mythweaver.Format.date(DateTime.to_date(last))
        )
    )
  end

  defp summary(%{kind: :preset} = preset) do
    keys = preset.sampler |> Map.keys() |> Enum.map_join(", ", &to_string/1)
    n = length(preset.blocks)

    if keys == "",
      do:
        dpngettext(
          "import_export",
          "status: summary of an imported preset",
          "%{block_count} block",
          "%{block_count} blocks",
          n,
          block_count: Mythweaver.Format.number(n)
        ),
      else:
        dpngettext(
          "import_export",
          "status: summary of an imported preset with sampler values",
          "%{block_count} block; samplers: %{sampler_keys}",
          "%{block_count} blocks; samplers: %{sampler_keys}",
          n,
          block_count: Mythweaver.Format.number(n),
          sampler_keys: keys
        )
  end

  defp summary(%{kind: :bundle, bundle: bundle}) do
    bundle.items
    |> Enum.frequencies_by(&Review.kind_label(&1.kind))
    |> Enum.sort()
    |> Enum.map_join(", ", fn {label, n} ->
      dpgettext(
        "import_export",
        "unit: how many items of one kind an imported bundle holds",
        "%{item_kind}: %{item_total}",
        item_kind: label,
        item_total: Mythweaver.Format.number(n)
      )
    end)
  end

  defp open_path(%{kind: :character, record: record}), do: ~p"/characters/#{record.id}/edit"
  defp open_path(%{kind: :lore_book, record: record}), do: ~p"/lore/#{record.id}/edit"
  defp open_path(%{kind: :chat, record: record}), do: ~p"/chats/#{record.id}"
  defp open_path(%{kind: :preset, record: record}), do: ~p"/prompts/#{record.id}/edit"

  defp open_path(%{kind: :bundle, record: record}) do
    case record do
      %Character{} -> ~p"/characters/#{record.id}/edit"
      %LoreBook{} -> ~p"/lore/#{record.id}/edit"
      %Prompt{} -> ~p"/prompts/#{record.id}/edit"
      %Model{} -> ~p"/ai/models/#{record.id}/edit"
      %Script{} -> ~p"/scripts/#{record.id}/edit"
      %Profile{} -> ~p"/memory/profiles/#{record.id}/edit"
      %SidePrompt{} -> ~p"/memory/side-prompts/#{record.id}/edit"
      %SidePromptSet{} -> ~p"/memory/side-prompt-sets/#{record.id}/edit"
      %Chat{} -> ~p"/chats/#{record.id}"
    end
  end
end
