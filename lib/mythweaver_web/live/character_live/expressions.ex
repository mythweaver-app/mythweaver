defmodule MythweaverWeb.CharacterLive.Expressions do
  @moduledoc """
  The character editor's Expressions section (`Mythweaver.Expressions`): the expression settings
  (rule profile, fallback label, custom labels), outfit tabs, sprite uploads (one by one, named
  like `joy.png`, or a SillyTavern ZIP pack) and the grid of labels with their sprites.

  Every write goes through `Mythweaver.Expressions`, which announces `:characters`; the parent's
  LiveSync bumps `revision`, and `update/2` re-reads everything, the character included, so the
  section never trusts a stale copy.
  """
  use MythweaverWeb, :live_component

  alias Mythweaver.Attachments
  alias Mythweaver.Characters
  alias Mythweaver.Expressions
  alias Mythweaver.Format
  alias Mythweaver.Ownership
  alias MythweaverWeb.Uploads

  @max_notices 20

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(outfit_id: nil, target_label: nil, notices: [], settings_form: nil)
     |> Uploads.allow_images(:sprites, 100, auto_upload: true, progress: &sprite_progress/3)
     |> allow_upload(:sprite_pack,
       accept: ~w(.zip),
       max_entries: 1,
       max_file_size: 200_000_000,
       auto_upload: true,
       progress: &pack_progress/3
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, Map.take(assigns, [:id, :current_scope, :revision]))
    scope = socket.assigns.current_scope
    character = Characters.get_editable_character(scope, assigns.character.id) || assigns.character
    reset_form? = is_nil(socket.assigns.settings_form) or socket.assigns[:character_id] != character.id

    socket
    |> assign(character: character, character_id: character.id)
    |> then(&if(reset_form?, do: assign(&1, settings_form: fresh_form(character), target_label: nil), else: &1))
    |> reload()
    |> then(&{:ok, &1})
  end

  defp fresh_form(character), do: to_form(Expressions.change_settings(character))

  defp reload(socket) do
    %{current_scope: scope, character: character} = socket.assigns
    outfits = Expressions.list_outfits(scope, character)
    sprites = Expressions.list_sprites(scope, character)
    profile = Expressions.effective_profile(scope, character)
    labels = Expressions.labels(character, profile)
    outfit_id = if Enum.any?(outfits, &(&1.id == socket.assigns.outfit_id)), do: socket.assigns.outfit_id

    rule_names = if profile, do: MapSet.new(profile.rules, & &1.name), else: MapSet.new()
    # Labels left only by their sprites (a removed custom label) keep a card until the sprites go.
    leftover = sprites |> Enum.map(& &1.label) |> Enum.uniq() |> Kernel.--(labels) |> Enum.sort()

    assign(socket,
      outfits: outfits,
      sprites: sprites,
      outfit_id: outfit_id,
      labels: labels,
      grid_labels: labels ++ leftover,
      rule_names: rule_names,
      custom_labels: MapSet.new(character.expression_labels),
      profile_options:
        for(p <- Expressions.list_profiles(scope), Ownership.reference_ok?(character.user_id, p), do: {p.name, p.id})
    )
  end

  @impl true
  def handle_event("validate_settings", %{"character" => params}, socket) do
    changeset =
      socket.assigns.character
      |> Expressions.change_settings(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, settings_form: to_form(changeset))}
  end

  def handle_event("save_settings", %{"character" => params}, socket) do
    case Expressions.update_settings(socket.assigns.current_scope, socket.assigns.character, params) do
      {:ok, character} ->
        {:noreply, socket |> assign(character: character, settings_form: fresh_form(character)) |> reload()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, settings_form: to_form(changeset))}

      {:error, :unauthorized} ->
        {:noreply, notice(socket, cannot_edit_notice())}
    end
  end

  def handle_event("remove_label", %{"label" => label}, socket) do
    character = socket.assigns.character
    labels = List.delete(character.expression_labels, label)

    case Expressions.update_settings(socket.assigns.current_scope, character, %{expression_labels: labels}) do
      {:ok, character} ->
        {:noreply, socket |> assign(character: character, settings_form: fresh_form(character)) |> reload()}

      {:error, _} ->
        {:noreply, notice(socket, remove_label_failed_notice(label))}
    end
  end

  def handle_event("select_outfit", %{"tab" => "default"}, socket), do: {:noreply, assign(socket, outfit_id: nil)}

  def handle_event("select_outfit", %{"tab" => id}, socket) do
    if Enum.any?(socket.assigns.outfits, &(&1.id == id)),
      do: {:noreply, assign(socket, outfit_id: id)},
      else: {:noreply, socket}
  end

  def handle_event("create_outfit", %{"name" => name}, socket) do
    case Expressions.create_outfit(socket.assigns.current_scope, socket.assigns.character, name) do
      {:ok, outfit} ->
        {:noreply, socket |> assign(outfit_id: outfit.id) |> reload()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, notice(socket, outfit_error(changeset))}

      {:error, :unauthorized} ->
        {:noreply, notice(socket, cannot_edit_notice())}
    end
  end

  def handle_event("delete_outfit", _params, socket) do
    case Enum.find(socket.assigns.outfits, &(&1.id == socket.assigns.outfit_id)) do
      nil ->
        {:noreply, socket}

      outfit ->
        {:ok, _} = Expressions.delete_outfit(socket.assigns.current_scope, outfit)
        {:noreply, socket |> assign(outfit_id: nil) |> reload()}
    end
  end

  def handle_event("delete_sprite", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.sprites, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      sprite ->
        {:ok, _} = Expressions.delete_sprite(socket.assigns.current_scope, sprite)
        {:noreply, reload(socket)}
    end
  end

  def handle_event("target_label", %{"label" => label}, socket), do: {:noreply, assign(socket, target_label: label)}
  def handle_event("clear_target", _params, socket), do: {:noreply, assign(socket, target_label: nil)}

  # Picking files starts a new batch: the last batch's notices go.
  def handle_event("validate_uploads", _params, socket), do: {:noreply, assign(socket, notices: [])}

  defp sprite_progress(:sprites, %{done?: true} = entry, socket) do
    case Uploads.consume_image(socket, entry) do
      {:ok, attachment} -> {:noreply, add_uploaded(socket, entry.client_name, attachment)}
      {:error, reason} -> {:noreply, notice(socket, file_notice(entry.client_name, Uploads.error_text(reason)))}
    end
  end

  defp sprite_progress(:sprites, _entry, socket), do: {:noreply, socket}

  # A file named after a known label goes there; else to the label whose Add was clicked; else a
  # valid name becomes a new custom label.
  defp add_uploaded(socket, name, attachment) do
    %{current_scope: scope, character: character, labels: labels, target_label: target} = socket.assigns

    parsed =
      case Expressions.label_from_filename(name) do
        {:ok, label} -> label
        :error -> nil
      end

    label =
      cond do
        parsed in labels -> parsed
        target -> target
        true -> parsed
      end

    with label when is_binary(label) <- label,
         {:ok, _} <- Expressions.add_sprites(scope, character, socket.assigns.outfit_id, [{label, attachment}]) do
      reload(socket)
    else
      nil ->
        Attachments.delete_unlinked(scope, [attachment.id])
        notice(socket, dgettext("characters", "%{file_name}: no expression in the file name", file_name: name))

      {:error, _} ->
        Attachments.delete_unlinked(scope, [attachment.id])
        notice(socket, dgettext("characters", "%{file_name}: could not be added", file_name: name))
    end
  end

  defp pack_progress(:sprite_pack, %{done?: true} = entry, socket) do
    %{current_scope: scope, character: character, outfit_id: outfit_id} = socket.assigns

    result =
      consume_uploaded_entry(socket, entry, fn %{path: path} ->
        {:ok, Expressions.import_pack(scope, character, path, outfit_id)}
      end)

    {:noreply, socket |> notices(pack_notices(result)) |> reload()}
  end

  defp pack_progress(:sprite_pack, _entry, socket), do: {:noreply, socket}

  defp pack_notices({:ok, %{added: added, outfits: outfits, new_labels: new_labels, skipped: skipped}}) do
    [imported_notice(added)] ++
      if(outfits == [], do: [], else: [new_outfits_notice(outfits)]) ++
      if(new_labels == [], do: [], else: [new_expressions_notice(new_labels)]) ++
      if(skipped == [], do: [], else: [skipped_notice(skipped)])
  end

  defp pack_notices({:error, :invalid_zip}), do: [dgettext("characters", "That file isn't a ZIP archive")]

  defp pack_notices({:error, :too_large}),
    do: [
      dgettext("characters", "The pack is too large (at most %{file_limit} files, %{size_limit} unpacked)",
        file_limit: Format.number(1000),
        size_limit: Format.megabytes(500)
      )
    ]

  defp pack_notices({:error, _}), do: [dgettext("characters", "Could not import the pack")]

  defp notice(socket, text), do: notices(socket, [text])

  defp notices(socket, texts), do: assign(socket, notices: Enum.take(socket.assigns.notices ++ texts, -@max_notices))

  defp cannot_edit_notice, do: dgettext("characters", "You can't edit this character")

  defp remove_label_failed_notice(label) do
    gettext_comment("Shown in the sprite panel when removing an expression label from the character failed.")

    dpgettext(
      "characters",
      "status: removing an expression label from a character failed",
      "Could not remove %{expression_label}",
      expression_label: label
    )
  end

  defp imported_notice(added) do
    gettext_comment("Shown in the sprite panel after a sprite pack ZIP was imported.")

    dpngettext(
      "characters",
      "status: sprites imported from a sprite pack",
      "Imported %{sprite_count} sprite",
      "Imported %{sprite_count} sprites",
      added,
      sprite_count: Format.number(added)
    )
  end

  defp new_outfits_notice(outfits) do
    gettext_comment(
      "Shown in the sprite panel after a sprite pack import; %{outfit_names} is a list of outfit names, such as \"Casual and Formal\"."
    )

    dpgettext("characters", "status: outfits created by a sprite pack import", "New outfits: %{outfit_names}",
      outfit_names: Format.list(outfits)
    )
  end

  defp new_expressions_notice(new_labels) do
    gettext_comment(
      "Shown in the sprite panel after a sprite pack import; %{expression_labels} is a list of expression labels, such as \"happy and sad\"."
    )

    dpgettext(
      "characters",
      "status: expression labels added by a sprite pack import",
      "New expressions: %{expression_labels}",
      expression_labels: Format.list(new_labels)
    )
  end

  defp skipped_notice(skipped) do
    gettext_comment(
      "Shown in the sprite panel after a sprite pack import; %{file_names} is a list of the pack's file names that were not imported."
    )

    dpgettext("characters", "status: files a sprite pack import skipped", "Skipped: %{file_names}",
      file_names: Format.list(skipped)
    )
  end

  defp file_notice(file_name, upload_error) do
    gettext_comment(
      "Shown under the sprite drop zone when an uploaded file is refused; the error is a sentence fragment such as \"File is too large\"."
    )

    dpgettext("characters", "status: a sprite file upload was refused", "%{file_name}: %{upload_error}",
      file_name: file_name,
      upload_error: upload_error
    )
  end

  defp outfit_error(changeset) do
    case changeset.errors do
      [{:name, error} | _] ->
        gettext_comment(
          "Shown when a new outfit is refused; the error is a validation message such as \"can't be blank\"."
        )

        dpgettext("characters", "status: a new outfit was refused because of its name", "Outfit name %{error_message}",
          error_message: translate_error(error)
        )

      [{_field, error} | _] ->
        dgettext("characters", "The outfit could not be created: %{error_message}",
          error_message: translate_error(error)
        )

      [] ->
        dgettext("characters", "The outfit could not be created.")
    end
  end

  defp delete_outfit_confirm(outfits, outfit_id) do
    gettext_comment("Confirm dialog before deleting the open outfit tab of a character.")

    dgettext("characters", "Delete outfit %{outfit_name} and its sprites?",
      outfit_name: Enum.find_value(outfits, &(&1.id == outfit_id && &1.name))
    )
  end

  defp label_values(form), do: Ecto.Changeset.get_field(form.source, :expression_labels) || []

  defp sprites_of(sprites, outfit_id, label), do: Expressions.sprites_for(sprites, outfit_id, label)

  @impl true
  def render(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      section:scope {
        padding: var(--size-3);
      }

      .character-expressions-body {
        display: flex;
        flex-direction: column;
        gap: var(--size-3);
        margin-block-start: var(--size-3);
      }

      .character-expressions-settings {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .character-outfits {
        display: flex;
        flex-wrap: wrap;
        align-items: flex-end;
        gap: var(--size-2);
      }

      .character-outfit-form {
        display: flex;
        align-items: flex-end;
        gap: var(--size-1);
      }

      /* Drop zone, like the avatar's: LiveView adds `phx-drop-target-active` while a file is over it. */
      div.character-sprites-drop {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
        padding: var(--size-3);
        border: 2px dashed var(--border);
        border-radius: var(--radius-2);
      }

      div.character-sprites-drop.phx-drop-target-active {
        border-color: var(--primary-accent);
        background: var(--surface-3);
      }

      .character-sprites-drop label,
      .character-sprites-drop input[type="file"] {
        max-inline-size: 100%;
      }

      .character-sprites-target {
        display: inline-flex;
        align-items: center;
        gap: var(--size-1);
      }

      .character-sprites-notice {
        margin: 0;
        color: var(--muted-foreground);
      }

      .character-sprites-error {
        margin: 0;
        color: var(--destructive);
      }

      .character-sprite-grid {
        display: grid;
        grid-template-columns: repeat(auto-fill, minmax(14rem, 1fr));
        gap: var(--size-2);
      }

      .character-sprite-card {
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
        padding: var(--size-2);
        border: 1px solid var(--border);
        border-radius: var(--radius-2);
      }

      .character-sprite-card[data-empty] {
        opacity: 0.6;
      }

      .character-sprite-card[data-target] {
        border-color: var(--primary-accent);
      }

      .character-sprite-card-head {
        display: flex;
        align-items: center;
        gap: var(--size-1);
      }

      .character-sprite-card-name {
        flex: 1 1 auto;
        font-weight: 600;
        overflow-wrap: anywhere;
      }

      .character-sprite-thumbs {
        display: flex;
        flex-wrap: wrap;
        gap: var(--size-1);
      }

      .character-sprite-thumb {
        position: relative;
        inline-size: 96px;
        block-size: 128px;
      }

      .character-sprite-thumb button {
        position: absolute;
        inset-block-start: 2px;
        inset-inline-end: 2px;
      }

      .character-sprite-add {
        align-self: flex-start;
        display: inline-flex;
        align-items: center;
        gap: var(--size-1);
        padding: var(--size-1) var(--size-2);
        border: 1px solid var(--border);
        border-radius: var(--radius-2);
        font-size: 0.85rem;
        cursor: pointer;
      }

      .character-sprite-icon {
        border: 0;
        background: none;
        color: var(--muted-foreground);
        cursor: pointer;
        padding: 2px;
      }
    </style>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      /* `<.avatar_image>`'s `<img>` is its own root, past the default lower bound. */
      .character-sprite-thumb img {
        inline-size: 96px;
        block-size: 128px;
        object-fit: contain;
        border-radius: var(--radius-2);
        background: var(--surface-2);
      }
    </style>
    <section id={@id} class="character-expressions">
      <.disclosure id={"#{@id}-details"} class="character-expressions-details">
        <:title>
          {dpgettext("characters", "heading: character expression sprites section", "Expressions")}
        </:title>
        <div class="character-expressions-body">
          <.form
            for={@settings_form}
            id="character-expressions-form"
            class="character-expressions-settings"
            phx-change="validate_settings"
            phx-submit="save_settings"
            phx-target={@myself}
            phx-hook="UnsavedChanges"
            data-saved={is_nil(@settings_form.action)}
          >
            <.input
              field={@settings_form[:expression_profile_id]}
              type="select"
              id="character-expressions-form-expression_profile_id"
              label={
                dpgettext(
                  "characters",
                  "field label: expression rule profile of a character",
                  "Rule profile"
                )
              }
              options={[
                {dpgettext(
                   "characters",
                   "option: use the expression rule profile from settings",
                   "Default (settings)"
                 ), ""}
                | @profile_options
              ]}
            />
            <.input
              field={@settings_form[:fallback_expression]}
              type="select"
              id="character-expressions-form-fallback_expression"
              label={dgettext("characters", "Fallback expression (when nothing matches)")}
              options={@labels}
            />
            <.tag_input
              id="character-expressions-form-expression_labels"
              name="character[expression_labels][]"
              mode="keywords"
              label={
                dpgettext(
                  "characters",
                  "field label: character's custom expression labels",
                  "Custom expressions"
                )
              }
              placeholder={
                dpgettext(
                  "characters",
                  "placeholder: add a custom expression label",
                  "Type a label, then Enter"
                )
              }
              values={label_values(@settings_form)}
            />
            <.form_actions>
              <.button type="submit" variant="primary" id="character-expressions-save">
                {dpgettext("characters", "button: save character expression settings", "Save")}
              </.button>
            </.form_actions>
          </.form>

          <div class="character-outfits">
            <.tabs
              id="character-outfits"
              label={
                dpgettext("characters", "aria label: tabs of a character's sprite outfits", "Outfits")
              }
              active={@outfit_id || "default"}
              on_select="select_outfit"
              target={@myself}
            >
              <:tab name="default">
                <.lucide name="shirt" /> {dpgettext(
                  "characters",
                  "tab: default sprite set of a character",
                  "Default"
                )}
              </:tab>
              <:tab :for={outfit <- @outfits} name={outfit.id}>{outfit.name}</:tab>
            </.tabs>
            <form
              id="character-outfit-form"
              class="character-outfit-form"
              phx-submit="create_outfit"
              phx-target={@myself}
            >
              <.input
                type="text"
                name="name"
                id="character-outfit-form-name"
                value=""
                placeholder={
                  dpgettext("characters", "placeholder: name of a new sprite outfit", "New outfit")
                }
              />
              <.button type="submit" size="sm" id="character-outfit-add">
                <.lucide name="plus" /> {dpgettext(
                  "characters",
                  "button: create a sprite outfit",
                  "Add outfit"
                )}
              </.button>
            </form>
            <.button
              :if={@outfit_id}
              danger
              size="sm"
              id="delete-outfit"
              phx-click="delete_outfit"
              phx-target={@myself}
              data-confirm={delete_outfit_confirm(@outfits, @outfit_id)}
            >
              <.lucide name="trash" />
              {dpgettext("characters", "button: delete the open sprite outfit", "Delete outfit")}
            </.button>
          </div>

          <form id="character-sprites-upload" phx-change="validate_uploads" phx-target={@myself}>
            <div class="character-sprites-drop" phx-drop-target={@uploads.sprites.ref}>
              <label for={@uploads.sprites.ref}>
                {dgettext("characters", "Add sprites (named like joy.png, joy-2.png)")}
                <.live_file_input upload={@uploads.sprites} />
              </label>
              <label for={@uploads.sprite_pack.ref}>
                <.lucide name="file-archive" />
                {dpgettext(
                  "characters",
                  "field label: upload a zip of sprites",
                  "Import sprite pack (.zip)"
                )}
                <.live_file_input upload={@uploads.sprite_pack} />
              </label>
              <span :if={@target_label} class="character-sprites-target" id="character-sprites-target">
                {dpgettext(
                  "characters",
                  "status: expression label new sprites are added to",
                  "Adding to: %{expression_label}",
                  expression_label: @target_label
                )}
                <button
                  type="button"
                  class="character-sprite-icon"
                  phx-click="clear_target"
                  phx-target={@myself}
                  aria-label={dgettext("characters", "Stop adding to this expression")}
                >
                  <.lucide name="x" />
                </button>
              </span>
              <p
                :for={
                  error <-
                    upload_errors(@uploads.sprites) ++
                      Enum.flat_map(@uploads.sprites.entries, &upload_errors(@uploads.sprites, &1)) ++
                      upload_errors(@uploads.sprite_pack) ++
                      Enum.flat_map(
                        @uploads.sprite_pack.entries,
                        &upload_errors(@uploads.sprite_pack, &1)
                      )
                }
                class="character-sprites-error"
              >
                {Uploads.error_text(error)}
              </p>
              <p :for={text <- @notices} class="character-sprites-notice">{text}</p>
            </div>
          </form>

          <div id="character-sprite-grid" class="character-sprite-grid">
            <div
              :for={label <- @grid_labels}
              id={"sprite-label-#{label}"}
              class="character-sprite-card"
              data-empty={sprites_of(@sprites, @outfit_id, label) == []}
              data-target={@target_label == label}
            >
              <div class="character-sprite-card-head">
                <span class="character-sprite-card-name">{label}</span>
                <.badge :if={MapSet.member?(@rule_names, label)}>
                  {dpgettext("characters", "badge: expression label from a rule profile", "rule")}
                </.badge>
                <.badge :if={MapSet.member?(@custom_labels, label)}>
                  {dpgettext("characters", "badge: custom expression label of a character", "custom")}
                </.badge>
                <button
                  :if={MapSet.member?(@custom_labels, label)}
                  type="button"
                  class="character-sprite-icon"
                  id={"remove-label-#{label}"}
                  phx-click="remove_label"
                  phx-value-label={label}
                  phx-target={@myself}
                  aria-label={
                    dpgettext(
                      "characters",
                      "aria label: remove a custom expression label",
                      "Remove the %{expression_label} expression",
                      expression_label: label
                    )
                  }
                  title={
                    dgettext("characters", "Remove this expression (its sprites stay until deleted)")
                  }
                >
                  <.lucide name="x" />
                </button>
              </div>
              <div class="character-sprite-thumbs">
                <div
                  :for={sprite <- sprites_of(@sprites, @outfit_id, label)}
                  class="character-sprite-thumb"
                >
                  <.avatar_image avatar={sprite.attachment} preset={:sprite} sizes="96px" alt={label} />
                  <button
                    type="button"
                    class="character-sprite-icon"
                    id={"delete-sprite-#{sprite.id}"}
                    phx-click="delete_sprite"
                    phx-value-id={sprite.id}
                    phx-target={@myself}
                    aria-label={
                      dpgettext(
                        "characters",
                        "aria label: delete one expression sprite image",
                        "Delete sprite"
                      )
                    }
                  >
                    <.lucide name="x" />
                  </button>
                </div>
              </div>
              <label
                for={@uploads.sprites.ref}
                class="character-sprite-add"
                id={"add-sprite-#{label}"}
                phx-click="target_label"
                phx-value-label={label}
                phx-target={@myself}
              >
                <.lucide name="plus" /> {dpgettext(
                  "characters",
                  "button: add a sprite to this expression",
                  "Add"
                )}
              </label>
            </div>
          </div>
        </div>
      </.disclosure>
    </section>
    """
  end
end
