defmodule MythweaverWeb.CharacterLive do
  @moduledoc """
  Character editor: the character list on the left, the selected character's form on the right.
  `:index` selects nothing: the editor pane shows a placeholder until a character is picked.

  A new avatar is stored as it uploads (`staged_avatar`) and described at once
  (`Captions.describe_avatar/4`) when `images.auto_caption` is on and the form's
  `avatar_updates_appearance` (else the setting) says Appearance follows the avatar, since that is
  all the description is for. It goes into the form's unsaved Appearance ("Describe avatar" always
  fills it), with Revert to put back what was there; Save makes the image the character's avatar
  along with the rest of the form.

  Compact rewrites the form's Description through the default memory profile's compaction prompt
  (`MythweaverWeb.FieldCompaction`); the rewrite replaces the field unsaved, for review then Save.

  The header star toggles the open character as one of the user's favorites
  (`Characters.set_favorite/3`); favorites list first, each with a star.
  """
  use MythweaverWeb, :live_view

  # Re-importing Iconex replaces `html_helpers`' `only: [lucide: 1]`, so both are listed.
  import Iconex, only: [carbon: 1, lucide: 1]
  import MythweaverWeb.BulkComponents
  import MythweaverWeb.Pane
  import MythweaverWeb.TagFields
  import MythweaverWeb.TagFilter

  alias Mythweaver.Attachments
  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Attachments.Captions
  alias Mythweaver.Characters
  alias Mythweaver.Characters.Character
  alias Mythweaver.Format
  alias Mythweaver.Ownership
  alias Mythweaver.Prompts.Completions
  alias Mythweaver.Settings
  alias MythweaverWeb.Bulk
  alias MythweaverWeb.Bulk.Field
  alias MythweaverWeb.Bulk.Spec
  alias MythweaverWeb.CoreComponents.OwnerSelect
  alias MythweaverWeb.FieldCompaction
  alias MythweaverWeb.LiveSync
  alias MythweaverWeb.Uploads
  alias Phoenix.HTML.Form
  alias Phoenix.LiveView.JS

  require FieldCompaction

  on_mount {MythweaverWeb.ContentAccess, :characters}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Mythweaver.Jobs.subscribe(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(
       page_title: dpgettext("characters", "page title: character list and editor", "Characters"),
       form: nil,
       editing_character: nil,
       favorite?: false,
       new_owner: "personal",
       selected_id: nil,
       staged_avatar: nil,
       avatar_job: nil,
       ai_appearance: nil,
       avatar_question: "",
       template_completions: Completions.template(socket.assigns.current_scope),
       description_compaction: nil,
       # Bumped on every sync, so the Expressions component re-reads what changed elsewhere.
       expressions_revision: 0
     )
     |> assign_filter()
     |> assign_tag_filter()
     |> stream_characters()
     |> Bulk.attach([bulk_spec()])
     |> Uploads.allow_images(:avatar, 1, progress: &avatar_progress/3)
     |> LiveSync.attach_editor([:characters, :tags], &sync/2)}
  end

  defp sync(socket, kinds) do
    scope = socket.assigns.current_scope
    form = socket.assigns.form
    socket = if :tags in kinds, do: refresh_graph(socket), else: socket

    socket
    |> update(:expressions_revision, &(&1 + 1))
    |> stream_characters()
    |> LiveSync.sync_open(:editing_character,
      fetch: fn id ->
        with %{} = character <- Characters.get_editable_character(scope, id),
             do: Characters.preload_avatar(scope, character)
      end,
      clean?: LiveSync.clean?(form) and is_nil(pending_avatar(socket.assigns)),
      reload: fn s, fresh ->
        s
        |> assign(form: to_form(Characters.change_character(fresh)), editing_character: fresh)
        |> assign_tag_fields(:item, fresh, fresh.user_id)
      end,
      # The Expressions section saves its own fields; they never make the main form stale.
      compare:
        &(LiveSync.changed?(&1, &2, [:appearance, :expression_labels, :fallback_expression, :expression_profile_id]) or
            avatar_id(&1) != avatar_id(&2)),
      gone: ~p"/characters",
      gone_message:
        (
          gettext_comment("Flash shown when the character open in the editor was deleted or moved by someone else.")
          dgettext("characters", "The character was deleted or moved elsewhere.")
        ),
      force: :tags in kinds
    )
    |> assign_favorite()
  end

  defp avatar_id(%{avatar: %Attachment{id: id}}), do: id
  defp avatar_id(_character), do: nil

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> reset_avatar_edits(nil)
    |> assign(form: nil, editing_character: nil, favorite?: false, selected_id: nil, description_compaction: nil)
    |> stream_characters()
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> reset_avatar_edits(nil)
    |> assign(
      form: to_form(Characters.change_character(%Character{})),
      editing_character: nil,
      favorite?: false,
      new_owner: "personal",
      selected_id: nil,
      description_compaction: nil
    )
    |> assign_tag_fields(:item, nil, OwnerSelect.tag_owner(socket.assigns.current_scope, Character, "personal"))
    |> stream_characters()
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Characters.get_editable_character(socket.assigns.current_scope, id) do
      nil ->
        socket
        |> put_flash(:error, not_found_flash())
        |> push_patch(to: ~p"/characters")

      character ->
        if connected?(socket) do
          if previous = socket.assigns.editing_character,
            do: Phoenix.PubSub.unsubscribe(Mythweaver.PubSub, Attachments.character_topic(previous.id))

          Phoenix.PubSub.subscribe(Mythweaver.PubSub, Attachments.character_topic(character.id))
        end

        socket
        |> reset_avatar_edits(character.id)
        |> assign(
          form: to_form(Characters.change_character(character)),
          editing_character: Characters.preload_avatar(socket.assigns.current_scope, character),
          selected_id: character.id,
          description_compaction: nil
        )
        |> assign_favorite()
        |> assign_tag_fields(:item, character, character.user_id)
        |> stream_characters()
    end
  end

  # The character's appearance changed elsewhere (a script, an avatar a script set). Only that field
  # is refreshed: anything else typed in the form so far stays.
  @impl true
  def handle_info({:appearance_updated, id}, %{assigns: %{editing_character: %{id: id}}} = socket) do
    scope = socket.assigns.current_scope
    character = Characters.get_editable_character(scope, id)

    {:noreply,
     socket
     |> assign(editing_character: Characters.preload_avatar(scope, character))
     |> put_form_field("appearance", character.appearance, socket.assigns.form.source.action)}
  end

  def handle_info({:appearance_updated, _id}, socket), do: {:noreply, socket}

  # The description the form waits for (`avatar_job`) ended; a finished one fills Appearance.
  def handle_info(
        {:job_changed, %{id: id, tag: :caption, status: status}},
        %{assigns: %{avatar_job: %{id: id} = job}} = socket
      )
      when status in [:completed, :failed, :canceled] do
    socket = socket |> assign(avatar_job: nil) |> refresh_avatars()
    {:noreply, if(status == :completed, do: fill_appearance(socket, job), else: socket)}
  end

  # Any other description (a script's, another tab's): the avatar's caption status drives the
  # Describe button.
  def handle_info({:job_changed, %{tag: :caption}}, socket), do: {:noreply, refresh_avatars(socket)}

  def handle_info({:job_changed, %{id: id, status: status}}, %{assigns: %{description_compaction: %{id: id}}} = socket)
      when FieldCompaction.finished?(status) do
    put_description = &put_form_field(&1, "description", &2, :validate)

    {:noreply, FieldCompaction.finish(socket, :description_compaction, compaction_target(socket), put_description)}
  end

  def handle_info({:job_changed, _job}, socket), do: {:noreply, socket}
  def handle_info({:job_progress, _payload}, socket), do: {:noreply, socket}
  def handle_info({:job_queue, _positions}, socket), do: {:noreply, socket}

  defp refresh_avatars(socket) do
    scope = socket.assigns.current_scope

    socket
    |> update(:staged_avatar, &(&1 && Attachments.get_attachment(scope, &1.id)))
    |> update(:editing_character, &(&1 && Characters.preload_avatar(scope, &1)))
  end

  # The description replaces Appearance when the person asked for it, or when the form's
  # `avatar_updates_appearance` (else the setting) says so. Revert goes back to what was there before
  # the first of a run of descriptions, not to an earlier one of them.
  defp fill_appearance(socket, job) do
    scope = socket.assigns.current_scope
    current = socket.assigns.form[:appearance].value || ""
    form_character = Ecto.Changeset.apply_changes(socket.assigns.form.source)

    with %Attachment{description: text} when is_binary(text) and text != "" <-
           Attachments.get_attachment(scope, job.attachment_id),
         true <- text != current,
         true <- job.requested? or Captions.updates_appearance?(scope, form_character) do
      previous =
        case socket.assigns.ai_appearance do
          %{text: ^current, previous: previous} -> previous
          _ -> current
        end

      ai_appearance = if text != previous, do: %{text: text, previous: previous, attachment_id: job.attachment_id}
      socket |> put_form_field("appearance", text, :validate) |> assign(ai_appearance: ai_appearance)
    else
      _ -> socket
    end
  end

  # Only `field` changes: anything else typed in the form so far stays.
  defp put_form_field(socket, field, text, action) do
    params = Map.put(socket.assigns.form.params, field, text)
    form = socket |> target_character() |> Characters.change_character(params) |> to_form(action: action)
    assign(socket, form: form)
  end

  # The character the form shows (nil for a new one), so a rewrite lands only where it came from.
  defp compaction_target(socket),
    do: {:character, socket.assigns.editing_character && socket.assigns.editing_character.id}

  # A finished upload is stored at once so it can be described before Save; it replaces an earlier
  # one never saved.
  defp avatar_progress(:avatar, %{done?: true} = entry, socket) do
    case Uploads.consume_image(socket, entry) do
      {:ok, attachment} ->
        socket = socket |> discard_staged_avatar() |> assign(staged_avatar: attachment)
        {:noreply, if(auto_describe?(socket), do: describe(socket, attachment, false), else: socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, avatar_upload_failed_flash(Uploads.error_text(reason)))}
    end
  end

  defp avatar_progress(:avatar, _entry, socket), do: {:noreply, socket}

  # Read at upload time, not mount, so a setting changed in another tab applies.
  defp auto_describe?(socket) do
    scope = socket.assigns.current_scope

    Settings.get(scope, "images.auto_caption") and
      Captions.updates_appearance?(scope, Ecto.Changeset.apply_changes(socket.assigns.form.source))
  end

  # `requested?`: a person pressed "Describe avatar" (their question goes along, and the text always
  # fills Appearance); otherwise a new upload is described on its own.
  defp describe(socket, avatar, requested?) do
    scope = socket.assigns.current_scope
    opts = if requested?, do: [instruction: socket.assigns.avatar_question], else: []

    case Captions.describe_avatar(scope, socket.assigns.editing_character, avatar, opts) do
      {:ok, job_id} ->
        socket
        |> assign(avatar_job: %{id: job_id, attachment_id: avatar.id, requested?: requested?, keep_for: nil})
        |> refresh_avatars()

      {:error, :no_captioner} ->
        if requested?, do: put_flash(socket, :error, no_captioner_flash()), else: socket

      {:error, :unauthorized} ->
        flash_unauthorized(socket)

      {:error, :not_queued} ->
        put_flash(socket, :error, describe_failed_flash())
    end
  end

  # Leaving the form's edits (Cancel, another character, the new form) drops the avatar it never
  # saved and stops waiting for a description. After a save the patch lands back on the saved
  # character, and a description still on its way is still waited for (`keep_for`).
  defp reset_avatar_edits(socket, character_id) do
    socket = discard_staged_avatar(socket)

    avatar_job =
      case socket.assigns.avatar_job do
        %{keep_for: id} = job when is_binary(id) and id == character_id -> %{job | keep_for: nil}
        _ -> nil
      end

    assign(socket, avatar_job: avatar_job, ai_appearance: nil, avatar_question: "")
  end

  # An upload never saved belongs to nobody: its description stops and the image is deleted.
  defp discard_staged_avatar(%{assigns: %{staged_avatar: nil}} = socket), do: socket

  defp discard_staged_avatar(%{assigns: %{staged_avatar: avatar, avatar_job: job}} = socket) do
    scope = socket.assigns.current_scope
    own_job? = job != nil and job.attachment_id == avatar.id
    if own_job?, do: Mythweaver.Jobs.cancel(scope, job.id)
    :ok = Attachments.delete_unlinked(scope, [avatar.id])
    assign(socket, staged_avatar: nil, avatar_job: if(!own_job?, do: job))
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, socket |> assign_filter(params) |> assign_tag_filter(params) |> stream_characters()}
  end

  def handle_event("describe_avatar", _params, socket) do
    case describable(socket.assigns) do
      nil -> {:noreply, put_flash(socket, :error, no_avatar_flash())}
      avatar -> {:noreply, describe(socket, avatar, true)}
    end
  end

  def handle_event("revert_appearance", _params, %{assigns: %{ai_appearance: %{previous: previous}}} = socket),
    do: {:noreply, socket |> put_form_field("appearance", previous, :validate) |> assign(ai_appearance: nil)}

  def handle_event("revert_appearance", _params, socket), do: {:noreply, socket}

  # Compacts the Description as the form shows it; the rewrite replaces it unsaved (`handle_info/2`).
  def handle_event("compact_description", _params, socket) do
    form = socket.assigns.form
    attrs = %{title: form[:name].value, content: form[:description].value, kind: "character"}
    {:noreply, FieldCompaction.start(socket, :description_compaction, compaction_target(socket), attrs)}
  end

  def handle_event("validate", %{"character" => params} = form_params, socket) do
    changeset =
      socket
      |> target_character()
      |> Characters.change_character(greeting_params(params))
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(form: to_form(changeset), avatar_question: form_params["avatar_question"] || "")
     |> put_new_owner(:editing_character, Character, OwnerSelect.choice(form_params))
     |> put_tag_params(:item, form_params["tags"])}
  end

  def handle_event("save", %{"character" => params} = all, socket) do
    socket = put_tag_params(socket, :item, all["tags"])
    params = greeting_params(params)

    result =
      case socket.assigns.editing_character do
        nil ->
          opts = OwnerSelect.create_opts(OwnerSelect.choice(all))

          Characters.create_character(
            socket.assigns.current_scope,
            params,
            [followups: held_followups(socket, opts)] ++ opts
          )

        character ->
          Characters.update_character(socket.assigns.current_scope, character, params)
      end

    case result do
      {:ok, character} ->
        socket =
          case save_tags(socket, :item, character) do
            {:ok, socket} -> put_flash(socket, :info, "#{character.name} saved")
            {:error, what, socket} -> put_flash(socket, :error, "#{character.name} saved, but #{what} did not")
          end

        {:noreply,
         socket
         |> save_avatar(character)
         |> update(:avatar_job, &(&1 && %{&1 | keep_for: character.id}))
         |> push_patch(to: ~p"/characters/#{character.id}/edit")}

      {:held, hold} ->
        path =
          case socket.assigns.editing_character do
            nil -> ~p"/characters"
            character -> ~p"/characters/#{character.id}/edit"
          end

        {:noreply, socket |> flash_held(hold) |> push_patch(to: path)}

      {:error, :hold_limit} ->
        {:noreply, flash_hold_limit(socket)}

      {:error, :quota_exceeded} ->
        {:noreply, flash_quota(socket, "quota.characters")}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(:error, save_failed_flash())}
    end
  end

  def handle_event("remove_avatar", _params, socket) do
    case socket.assigns.editing_character do
      nil ->
        {:noreply, socket}

      character ->
        :ok = Attachments.remove_avatar(socket.assigns.current_scope, character)
        {:noreply, push_patch(socket, to: ~p"/characters/#{character.id}/edit")}
    end
  end

  def handle_event("cancel_avatar", %{"ref" => ref}, socket), do: {:noreply, cancel_upload(socket, :avatar, ref)}

  # "Keep current" on an uploaded avatar: it is dropped, and so is its description in Appearance.
  def handle_event("discard_avatar", _params, %{assigns: %{staged_avatar: %Attachment{id: id}}} = socket) do
    socket =
      case socket.assigns.ai_appearance do
        %{attachment_id: ^id, text: text, previous: previous} ->
          if socket.assigns.form[:appearance].value == text,
            do: socket |> put_form_field("appearance", previous, :validate) |> assign(ai_appearance: nil),
            else: socket

        _ ->
          socket
      end

    {:noreply, socket |> discard_staged_avatar() |> assign(avatar_question: "")}
  end

  def handle_event("discard_avatar", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_favorite", _params, %{assigns: %{editing_character: %Character{} = character}} = socket) do
    favorite? = !socket.assigns.favorite?

    case Characters.set_favorite(socket.assigns.current_scope, character, favorite?) do
      :ok -> {:noreply, assign(socket, favorite?: favorite?)}
      {:error, :unauthorized} -> {:noreply, flash_unauthorized(socket)}
      {:error, :not_found} -> {:noreply, put_flash(socket, :error, not_found_flash())}
    end
  end

  def handle_event("toggle_favorite", _params, socket), do: {:noreply, socket}

  def handle_event("delete", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Characters.get_editable_character(scope, id) do
      nil ->
        {:noreply, socket}

      character ->
        case Characters.delete_character(scope, character) do
          {:ok, {:handed_off, user}} ->
            {:noreply, socket |> put_flash(:info, handed_off_flash(user.handle)) |> push_patch(to: ~p"/characters")}

          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, deleted_flash(character.name))
             |> push_patch(to: ~p"/characters")}

          {:error, :unauthorized} ->
            {:noreply, flash_unauthorized(socket)}

          {:error, :in_use} ->
            {:noreply, put_flash(socket, :error, "#{character.name} is in a chat and can't be deleted")}
        end
    end
  end

  defp target_character(socket) do
    socket.assigns.editing_character || %Character{}
  end

  defp assign_favorite(%{assigns: %{editing_character: %Character{} = character}} = socket),
    do: assign(socket, favorite?: Characters.favorite?(socket.assigns.current_scope, character))

  defp assign_favorite(socket), do: assign(socket, favorite?: false)

  @greeting_keys ~w(alternate_greetings group_greetings)
  @greeting_controls for key <- @greeting_keys, suffix <- ~w(_add _drop), do: key <> suffix

  # The greeting lists post as `key[]` plus an Add (`key_add`) or Remove (`key_drop`, the index)
  # button's name. `greeting_lists` marks a post from the form itself: without it (`put_form_field/4`
  # reusing `form.params`) the lists stay as they are. The cast drops blank entries (Ecto strips
  # empty values inside arrays), so a blank row is never saved; `greeting_list/1` shows the rows
  # from these params so a new empty one stays on screen.
  defp greeting_params(params) do
    params =
      if Map.has_key?(params, "greeting_lists"),
        do: Enum.reduce(@greeting_keys, params, &put_greeting_list(&2, &1)),
        else: params

    Map.drop(params, ["greeting_lists" | @greeting_controls])
  end

  defp put_greeting_list(params, key) do
    list = List.wrap(params[key] || [])

    list =
      case Integer.parse(params["#{key}_drop"] || "") do
        {index, ""} -> List.delete_at(list, index)
        _ -> list
      end

    list = if params["#{key}_add"], do: list ++ [""], else: list
    Map.put(params, key, list)
  end

  # What an approved held create still does: its tags and its uploaded avatar.
  defp held_followups(socket, opts) do
    avatar =
      case socket.assigns.staged_avatar do
        nil -> []
        avatar -> [{Attachments, :set_avatar, [:row, avatar, [describe: false]]}]
      end

    tag_followups(socket, :item, opts) ++ avatar
  end

  # The avatar uploaded since the last save becomes the character's. It was described as it
  # uploaded (or was not meant to be), so it is not described again.
  defp save_avatar(%{assigns: %{staged_avatar: nil}} = socket, _character), do: socket

  defp save_avatar(%{assigns: %{staged_avatar: avatar}} = socket, character) do
    case Attachments.set_avatar(socket.assigns.current_scope, character, avatar, describe: false) do
      :ok -> assign(socket, staged_avatar: nil)
      {:error, _} -> put_flash(socket, :error, avatar_not_saved_flash())
    end
  end

  defp not_found_flash do
    gettext_comment("Flash when the character in the URL does not exist or cannot be edited.")
    dpgettext("characters", "status: flash when a character could not be found", "Character not found")
  end

  defp avatar_upload_failed_flash(upload_error) do
    gettext_comment(
      "Flash when a character avatar upload is refused; the error is a sentence fragment such as \"File is too large\"."
    )

    dpgettext(
      "characters",
      "status: flash after a character avatar upload was refused",
      "Avatar not uploaded: %{upload_error}",
      upload_error: upload_error
    )
  end

  defp no_captioner_flash do
    gettext_comment("Flash after Describe avatar when no AI model can read images.")
    dgettext("characters", "No model can describe images.")
  end

  defp describe_failed_flash do
    gettext_comment("Flash when the avatar description job could not be queued.")
    dgettext("characters", "The avatar could not be described.")
  end

  defp no_avatar_flash do
    gettext_comment("Flash after Describe avatar on a character without an avatar.")
    dgettext("characters", "This character has no avatar to describe.")
  end

  defp save_failed_flash do
    gettext_comment("Flash when saving an editor form fails validation; the invalid fields are highlighted.")
    dgettext("characters", "Could not save — see the highlighted fields")
  end

  defp handed_off_flash(handle) do
    gettext_comment(
      "Flash after deleting a shared character hands it to another user; the placeholder is their handle without the @."
    )

    dpgettext(
      "characters",
      "status: flash after a deleted shared character was handed to another user",
      "Given to @%{user_handle}",
      user_handle: handle
    )
  end

  defp deleted_flash(character_name) do
    gettext_comment("Flash after a character is deleted.")

    dpgettext("characters", "status: flash after deleting a character", "%{character_name} deleted",
      character_name: character_name
    )
  end

  defp avatar_not_saved_flash do
    gettext_comment("Flash when a saved character's new avatar could not be stored.")
    dpgettext("characters", "status: flash after a character's new avatar could not be stored", "Avatar not saved")
  end

  defp delete_confirm(character_name) do
    gettext_comment("Confirm dialog before deleting a character.")

    dpgettext("characters", "status: confirm dialog before deleting a character", "Delete %{character_name}?",
      character_name: character_name
    )
  end

  defp avatar_updates_appearance_label,
    do:
      dpgettext(
        "characters",
        "field label: character setting to rewrite Appearance from a new avatar",
        "Update Appearance from a new avatar"
      )

  defp follow_settings_option,
    do: dpgettext("characters", "option: avatar updates appearance per user settings", "Follow my settings")

  defp yes_no_options do
    [
      {dpgettext("characters", "option: avatar updates appearance", "Yes"), "true"},
      {dpgettext("characters", "option: avatar updates appearance", "No"), "false"}
    ]
  end

  defp greeting_label(:alternate, i),
    do:
      dpgettext(
        "characters",
        "field label: one numbered alternate greeting of a character",
        "Alternate greeting %{greeting_number}", greeting_number: Format.number(i + 1))

  defp greeting_label(:group_only, i),
    do:
      dpgettext(
        "characters",
        "field label: one numbered group-only greeting of a character",
        "Group-only greeting %{greeting_number}", greeting_number: Format.number(i + 1))

  defp remove_greeting_label(:alternate, i),
    do:
      dpgettext(
        "characters",
        "aria label: remove one alternate greeting",
        "Remove Alternate greeting %{greeting_number}", greeting_number: Format.number(i + 1))

  defp remove_greeting_label(:group_only, i),
    do:
      dpgettext(
        "characters",
        "aria label: remove one group-only greeting",
        "Remove Group-only greeting %{greeting_number}", greeting_number: Format.number(i + 1))

  defp system_prompt_hint do
    gettext_comment(
      "%{original_tag} is template code that inserts the replaced block's text; %{add_option} is the name of the \"Add to the prompt\" option of Card prompts."
    )

    rich(
      dgettext(
        "characters",
        "Replaces the block tagged Main prompt (%{original_tag} is its text); with no tagged block, or with %{add_option}, it goes before the before-character lore.",
        original_tag: code("{{ original }}"),
        add_option: em(dpgettext("characters", "option: how character card prompts are applied", "Add to the prompt"))
      )
    )
  end

  defp bulk_spec do
    %Spec{
      name: :characters,
      tag_kind: :character,
      count_label:
        &dpngettext(
          "characters",
          "count phrase: characters affected by a bulk action",
          "%{character_count} character",
          "%{character_count} characters",
          &1,
          character_count: Mythweaver.Format.number(&1)
        ),
      ids: & &1.assigns.characters_ids,
      get: &Characters.get_editable_character/2,
      update: &Characters.update_character/3,
      delete: &Characters.delete_character/2,
      title: & &1.name,
      refresh: &stream_characters/1,
      open_id: & &1.assigns.selected_id,
      index_path: ~p"/characters",
      edit_path: &~p"/characters/#{&1}/edit",
      fields: [
        %Field{
          key: :avatar_updates_appearance,
          label: avatar_updates_appearance_label(),
          type: :select,
          options: yes_no_options(),
          prompt: follow_settings_option()
        },
        %Field{
          key: :talkativeness,
          label: dpgettext("characters", "field label: how often a character speaks in group chats", "Talkativeness"),
          type: :number,
          min: 0,
          max: 1,
          step: 0.05
        }
      ]
    }
  end

  defp stream_characters(socket) do
    stream_search(
      socket,
      :characters,
      filter_tagged(socket, Characters.list_editable_characters(socket.assigns.current_scope), :character),
      &[&1.name, &1.description, &1.creator]
    )
  end

  # What "Describe avatar" describes: an avatar uploaded since the last save, else the saved one.
  defp describable(%{staged_avatar: %Attachment{} = avatar}), do: avatar
  defp describable(%{editing_character: %Character{avatar: %Attachment{} = avatar}}), do: avatar
  defp describable(_assigns), do: nil

  # The guard's value for the avatar: the stored upload, else the one still uploading (its ref), so
  # a picked image reads as unsaved from its preview on, not only once it is stored. A file the
  # upload refused (too large, wrong type) changes nothing.
  defp pending_avatar(%{staged_avatar: %Attachment{id: id}}), do: id

  defp pending_avatar(%{uploads: %{avatar: upload}}) do
    case Enum.find(upload.entries, & &1.valid?) do
      nil -> nil
      entry -> entry.ref
    end
  end

  @impl true
  def render(assigns) do
    describable = describable(assigns)
    ai_appearance = assigns.ai_appearance

    assigns =
      assign(assigns,
        describable: describable,
        pending_avatar: pending_avatar(assigns),
        describing?: assigns.avatar_job != nil or (describable != nil and describable.caption_status == :pending),
        # Revert stays while Appearance still holds the description as it came; editing it by hand
        # makes the text the person's own.
        revert?: ai_appearance != nil and assigns.form[:appearance].value == ai_appearance.text
      )

    ~H"""
    <%!--
      `lower-bound="none"`: rules here may reach inside `<.input>`'s own template,
      which is a nested-component root carrying `phx-r` that the default exclusive bound cuts off.
    --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      /* The editor slot's root. `pane_layout`'s `<section>` carries no marker from this block, so
         without it `<.form>` (which carries none either) would sit outside this scope. */
      div.character-editor-body:scope {
        display: contents;
      }

      .character-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .character-form label {
        display: block;
      }

      /* Drop zone: `phx-drop-target` takes dropped files; LiveView adds `phx-drop-target-active`
         while one is dragged over it. */
      div.character-form-avatar {
        display: flex;
        align-items: center;
        gap: var(--size-3);
        flex-wrap: wrap;
        padding: var(--size-3);
        border: 2px dashed var(--border);
        border-radius: var(--radius-2);
      }

      /* A native file input doesn't shrink, so on a phone its label ran past the row. */
      .character-form-avatar label,
      .character-form-avatar input[type="file"] {
        max-inline-size: 100%;
      }

      div.character-form-avatar.phx-drop-target-active {
        border-color: var(--primary-accent);
        background: var(--surface-3);
      }

      .character-form-avatar-hint {
        margin: 0;
        color: var(--muted-foreground);
      }

      .character-form-avatar img {
        inline-size: 96px;
        block-size: 128px;
        object-fit: cover;
        border-radius: var(--radius-2);
        background: var(--primary-accent);
      }

      .character-form-avatar span.character-form-avatar-placeholder {
        flex: none;
        inline-size: 96px;
        block-size: 128px;
        --avatar-radius: var(--radius-2);
      }

      .character-form-avatar-error {
        color: var(--destructive);
      }

      /* "Compact" and "Describe avatar" sit at the end of their field's label line, raised so the
         small button (taller than the label) clears the editor below. */
      div.character-form-description,
      div.character-form-appearance {
        position: relative;
      }

      .character-form-label-action {
        position: absolute;
        inset-block-start: calc(-1 * var(--size-2));
        inset-inline-end: 0;
      }

      .character-form-appearance-revert {
        margin-block-start: var(--size-2);
      }

      /* A favorite's star after its name in the list. */
      .character-list-favorite {
        margin-inline-start: var(--size-1);
        color: var(--primary-accent);
        font-size: 0.85em;
      }
    </style>

    <Layouts.app flash={@flash} current_scope={@current_scope} search={:characters}>
      <.pane_layout>
        <:list
          id="characters-nav"
          label={dpgettext("characters", "page title: character list and editor", "Characters")}
        >
          <.pane_header title={
            dpgettext("characters", "page title: character list and editor", "Characters")
          }>
            <:switch
              id="pane-switch-expression-profiles"
              navigate={~p"/characters/expression-profiles"}
            >
              <.lucide name="face-slightly-smiling" />
              {dpgettext(
                "characters",
                "link: switch to the expression rule profiles pane",
                "Expression rules"
              )}
            </:switch>
          </.pane_header>
          <.pane_actions>
            <.button variant="primary" patch={~p"/characters/new"} id="new-character">
              <.lucide name="plus" /> {dpgettext(
                "characters",
                "button: create a character",
                "New character"
              )}
            </.button>
            <.button navigate={~p"/import"} id="import-character">
              <.lucide name="upload" /> {dpgettext(
                "characters",
                "button: open the import page",
                "Import"
              )}
            </.button>
            <.bulk_toggle bulk={@bulk} id="characters-bulk-toggle" />
          </.pane_actions>
          <.bulk_bar bulk={@bulk} id="characters-bulk" />
          <.pane_search
            id="character-filter"
            form={@filter_form}
            placeholder={
              dpgettext(
                "characters",
                "placeholder: search characters by name, description, or creator",
                "Name, description, or creator"
              )
            }
          >
            <.tag_filter
              id="character-filter-tags"
              values={@tag_filter}
              vocabulary={@tag_vocabulary}
              errors={@tag_filter_errors}
              invalid={@tag_filter_invalid}
            />
          </.pane_search>
          <.pane_items
            :let={character}
            id="characters"
            rows={@streams.characters}
            empty?={@characters_empty?}
            empty={
              if @query == "" and @tag_filter == [],
                do: dpgettext("characters", "empty state: no characters exist", "No characters yet"),
                else: dgettext("characters", "No characters match this search")
            }
            selected_id={@selected_id}
            patch={fn character -> ~p"/characters/#{character.id}/edit" end}
            bulk={@bulk}
            bulk_list="characters"
          >
            <span class="pane-item-name">
              {character.name}<span
                :if={character.favorite}
                class="character-list-favorite"
                role="img"
                aria-label={
                  dpgettext("characters", "aria label: star marking a favorite character", "Favorite")
                }
                title={
                  dpgettext("characters", "tooltip: star marking a favorite character", "Favorite")
                }
              ><.carbon name="star--filled" /></span>
            </span>
          </.pane_items>
        </:list>
        <:editor id="character-editor">
          <.pane_placeholder :if={@live_action == :index} id="character-placeholder">
            {dgettext("characters", "Select a character, or create a new one.")}
          </.pane_placeholder>
          <div :if={@live_action != :index} class="character-editor-body">
            <.panel_header sticky>
              {if @editing_character,
                do: @editing_character.name,
                else: dpgettext("characters", "heading: unsaved new character", "New character")}
              <:actions :if={@editing_character}>
                <.pane_export
                  id="export-character"
                  kind={:character}
                  item={@editing_character}
                  current_scope={@current_scope}
                />
                <.button
                  size="sm"
                  id="character-favorite"
                  phx-click="toggle_favorite"
                  aria-pressed={to_string(@favorite?)}
                  title={
                    if @favorite?,
                      do:
                        dpgettext(
                          "characters",
                          "tooltip: unfavorite the open character",
                          "Remove from favorites"
                        ),
                      else:
                        dpgettext(
                          "characters",
                          "tooltip: favorite the open character",
                          "Add to favorites"
                        )
                  }
                >
                  <%= if @favorite? do %>
                    <.carbon name="star--filled" />
                    {dpgettext("characters", "button: unfavorite the open character", "Unfavorite")}
                  <% else %>
                    <.carbon name="star" />
                    {dpgettext("characters", "button: favorite the open character", "Favorite")}
                  <% end %>
                </.button>
                <.live_component
                  :if={Ownership.deletable?(@current_scope, @editing_character)}
                  module={MythweaverWeb.HandOff}
                  id="character-handoff"
                  thing="character"
                  current_scope={@current_scope}
                  item={@editing_character}
                  delete={&Characters.delete_character/3}
                  index={~p"/characters"}
                  delete_id="delete-character"
                  confirm={delete_confirm(@editing_character.name)}
                />
              </:actions>
            </.panel_header>
            <.live_component
              :if={@editing_character}
              module={MythweaverWeb.Lineage}
              id="character-lineage-line"
              thing="character"
              current_scope={@current_scope}
              item={@editing_character}
            />

            <.pane_section>
              <.changed_elsewhere
                :if={@changed_elsewhere?}
                id="character-changed-elsewhere"
                patch={@live_sync_path}
              />
              <.form
                for={@form}
                id="character-form"
                class="character-form"
                phx-hook="UnsavedChanges"
                data-saved={is_nil(@form.action) and is_nil(@pending_avatar)}
                phx-change="validate"
                phx-submit="save"
              >
                <.owner_select
                  :if={is_nil(@editing_character)}
                  id="character-form-owner"
                  scope={@current_scope}
                  schema={Character}
                  value={@new_owner}
                />
                <.input
                  field={@form[:name]}
                  type="text"
                  label={dpgettext("characters", "field label: name of a character", "Name")}
                  id="character-form-name"
                  required
                />
                <div
                  id="character-form-avatar"
                  class="character-form-avatar"
                  phx-drop-target={@uploads.avatar.ref}
                  phx-hook=".AvatarPaste"
                >
                  <%= cond do %>
                    <% entry = List.first(@uploads.avatar.entries) -> %>
                      <.live_img_preview entry={entry} />
                      <.button
                        type="button"
                        size="sm"
                        variant="secondary"
                        id="character-form-avatar-cancel"
                        phx-click="cancel_avatar"
                        phx-value-ref={entry.ref}
                      >
                        {dpgettext(
                          "characters",
                          "button: discard the newly picked avatar",
                          "Keep current"
                        )}
                      </.button>
                    <% @staged_avatar -> %>
                      <.avatar_image
                        avatar={@staged_avatar}
                        preset={:portrait}
                        sizes="96px"
                        alt={
                          dpgettext(
                            "characters",
                            "alt text: newly uploaded character avatar",
                            "New avatar"
                          )
                        }
                      />
                      <.button
                        type="button"
                        size="sm"
                        variant="secondary"
                        id="character-form-avatar-cancel"
                        phx-click="discard_avatar"
                      >
                        {dpgettext(
                          "characters",
                          "button: discard the newly picked avatar",
                          "Keep current"
                        )}
                      </.button>
                      <.input
                        type="text"
                        name="avatar_question"
                        id="character-form-avatar-question"
                        value={@avatar_question}
                        label={dgettext("characters", "Question for Describe avatar (optional)")}
                      />
                    <% @editing_character && @editing_character.avatar -> %>
                      <.avatar_image
                        avatar={@editing_character.avatar}
                        preset={:portrait}
                        sizes="96px"
                        alt={
                          dpgettext("characters", "alt text: character's current avatar", "Avatar")
                        }
                      />
                      <.button
                        type="button"
                        size="sm"
                        variant="secondary"
                        id="character-form-avatar-remove"
                        phx-click="remove_avatar"
                      >
                        {dpgettext(
                          "characters",
                          "button: remove the character's avatar",
                          "Remove avatar"
                        )}
                      </.button>
                    <% true -> %>
                      <.avatar_placeholder class="character-form-avatar-placeholder" />
                  <% end %>
                  <%!-- An avatar picked but not saved yet, still uploading or stored, counts as an unsaved
                       edit for the guard. --%>
                  <input
                    type="hidden"
                    name="staged_avatar_id"
                    id="character-form-staged-avatar"
                    value={@pending_avatar}
                  />
                  <label for={@uploads.avatar.ref}>
                    {dpgettext("characters", "field label: character avatar upload", "Avatar")}
                    <.live_file_input upload={@uploads.avatar} />
                  </label>
                  <p class="character-form-avatar-hint">
                    {dgettext("characters", "Or drop or paste an image here.")}
                  </p>
                  <p
                    :for={
                      error <-
                        upload_errors(@uploads.avatar) ++
                          Enum.flat_map(@uploads.avatar.entries, &upload_errors(@uploads.avatar, &1))
                    }
                    class="character-form-avatar-error"
                  >
                    {Uploads.error_text(error)}
                  </p>
                </div>
                <script :type={Phoenix.LiveView.ColocatedHook} name=".AvatarPaste">
                  // A pasted image (screenshot, "Copy image") becomes the avatar upload. Pastes with
                  // no image, or text pasted into a field, are left alone.
                  export default {
                    mounted() {
                      this.onPaste = (event) => {
                        const data = event.clipboardData;
                        const images = [...(data?.files ?? [])].filter((f) =>
                          f.type.startsWith("image/"),
                        );
                        if (images.length === 0) return;
                        const editable = event.target.closest?.(
                          "input, textarea, [contenteditable]",
                        );
                        if (editable && data.types.includes("text/plain")) return;

                        event.preventDefault();
                        const files = new DataTransfer();
                        files.items.add(images[0]);
                        this.upload("avatar", files.files);
                      };
                      document.addEventListener("paste", this.onPaste);
                    },
                    destroyed() {
                      document.removeEventListener("paste", this.onPaste);
                    },
                  };
                </script>
                <div class="character-form-description">
                  <.editor
                    field={@form[:description]}
                    label={
                      dpgettext("characters", "field label: character description", "Description")
                    }
                    rows={5}
                    id="character-form-description"
                    language="liquid"
                    spellcheck
                    completions={@template_completions}
                  />
                  <.button
                    size="sm"
                    id="character-form-description-compact"
                    class="character-form-label-action"
                    phx-click="compact_description"
                    disabled={@description_compaction != nil}
                  >
                    <.lucide name="shrink" />
                    {dpgettext("characters", "button: compact the character description", "Compact")}
                  </.button>
                </div>
                <div class="character-form-appearance">
                  <.editor
                    field={@form[:appearance]}
                    label={dpgettext("characters", "field label: character appearance", "Appearance")}
                    rows={3}
                    id="character-form-appearance"
                    language="markdown"
                    spellcheck
                  />
                  <.button
                    :if={@describable}
                    type="button"
                    size="sm"
                    variant="secondary"
                    id="character-form-appearance-describe"
                    class="character-form-label-action"
                    phx-click="describe_avatar"
                    disabled={@describing?}
                  >
                    <.lucide name="scan-eye" />
                    {if @describing?,
                      do:
                        dpgettext(
                          "characters",
                          "status: avatar description in progress",
                          "Describing…"
                        ),
                      else:
                        dpgettext(
                          "characters",
                          "button: describe the character's avatar",
                          "Describe avatar"
                        )}
                  </.button>
                  <.button
                    :if={@revert?}
                    type="button"
                    size="sm"
                    variant="secondary"
                    id="character-appearance-revert"
                    class="character-form-appearance-revert"
                    phx-click="revert_appearance"
                  >
                    <.lucide name="undo-2" />
                    {dpgettext("characters", "button: revert the appearance text", "Revert")}
                  </.button>
                </div>
                <.input
                  field={@form[:avatar_updates_appearance]}
                  type="select"
                  id="character-form-avatar_updates_appearance"
                  label={avatar_updates_appearance_label()}
                  options={[{follow_settings_option(), ""} | yes_no_options()]}
                />
                <.editor
                  field={@form[:first_message]}
                  label={
                    dpgettext("characters", "field label: character first message", "First message")
                  }
                  rows={3}
                  id="character-form-first-message"
                  language="liquid"
                  spellcheck
                  completions={@template_completions}
                />
                <input type="hidden" name="character[greeting_lists]" value="1" />
                <.greeting_list
                  form={@form}
                  field={:alternate_greetings}
                  id="character-form-alternate-greetings"
                  kind={:alternate}
                  title={
                    dpgettext(
                      "characters",
                      "heading: list of alternate greetings",
                      "Alternate greetings"
                    )
                  }
                  add_label={
                    dpgettext(
                      "characters",
                      "button: add an alternate greeting",
                      "Add alternate greeting"
                    )
                  }
                  completions={@template_completions}
                />
                <.greeting_list
                  form={@form}
                  field={:group_greetings}
                  id="character-form-group-greetings"
                  kind={:group_only}
                  title={
                    dpgettext(
                      "characters",
                      "heading: list of group-only greetings",
                      "Group-only greetings"
                    )
                  }
                  add_label={
                    dpgettext(
                      "characters",
                      "button: add a group-only greeting",
                      "Add group-only greeting"
                    )
                  }
                  completions={@template_completions}
                />
                <.input
                  field={@form[:creator]}
                  type="text"
                  label={
                    dpgettext("characters", "field label: creator of a character card", "Creator")
                  }
                  id="character-form-creator"
                />
                <.editor
                  field={@form[:creator_notes]}
                  label={
                    dpgettext(
                      "characters",
                      "field label: creator notes of a character card",
                      "Creator notes"
                    )
                  }
                  rows={5}
                  id="character-form-creator-notes"
                  language="markdown"
                  spellcheck
                />
                <.editor
                  field={@form[:system_prompt]}
                  label={
                    dpgettext(
                      "characters",
                      "field label: character card system prompt",
                      "System prompt"
                    )
                  }
                  rows={3}
                  id="character-form-system_prompt"
                  language="liquid"
                  spellcheck
                  completions={@template_completions}
                >
                  <:hint>
                    {system_prompt_hint()}
                  </:hint>
                </.editor>
                <.editor
                  field={@form[:post_history_instructions]}
                  label={
                    dpgettext(
                      "characters",
                      "field label: character card post-history instructions",
                      "Post-history instructions"
                    )
                  }
                  rows={3}
                  id="character-form-post_history_instructions"
                  language="liquid"
                  spellcheck
                  completions={@template_completions}
                />
                <.input
                  field={@form[:card_prompt_mode]}
                  type="select"
                  id="character-form-card_prompt_mode"
                  label={
                    dpgettext(
                      "characters",
                      "field label: how character card prompts are applied",
                      "Card prompts"
                    )
                  }
                  options={[
                    {dgettext("characters", "Replace the prompt's tagged block"), "replace"},
                    {dpgettext(
                       "characters",
                       "option: how character card prompts are applied",
                       "Add to the prompt"
                     ), "add"}
                  ]}
                />
                <.input
                  field={@form[:character_version]}
                  type="text"
                  label={
                    dpgettext(
                      "characters",
                      "field label: version of a character card",
                      "Character version"
                    )
                  }
                  id="character-form-character-version"
                />
                <.input
                  field={@form[:pronouns]}
                  type="text"
                  label={dpgettext("characters", "field label: pronouns of a character", "Pronouns")}
                  id="character-form-pronouns"
                />
                <.input
                  field={@form[:talkativeness]}
                  type="number"
                  min="0"
                  max="1"
                  step="0.05"
                  label={
                    dgettext("characters", "Talkativeness (0 = only when named, 1 = every turn)")
                  }
                  id="character-form-talkativeness"
                />
                <.input
                  :if={
                    OwnerSelect.site_row?(@editing_character, @current_scope, Character, @new_owner)
                  }
                  field={@form[:site_visibility]}
                  type="select"
                  label={
                    dpgettext(
                      "characters",
                      "field label: what non-admin users see of a site character",
                      "Visible to users"
                    )
                  }
                  id="character-form-site_visibility"
                  options={[
                    {dpgettext(
                       "characters",
                       "option: what non-admin users see of a site character",
                       "Everything"
                     ), "readable"},
                    {dpgettext(
                       "characters",
                       "option: what non-admin users see of a site character",
                       "Only names (runtime-only)"
                     ), "runtime_only"}
                  ]}
                >
                  <:hint>
                    {dgettext(
                      "characters",
                      "What users who are not admins see of this character. Only names: never its description or appearance, in the prompt inspector, the assistant, scripts or exports; the model still gets them. Admins always see everything."
                    )}
                  </:hint>
                </.input>
                <.tag_fields
                  id="character-form-tags"
                  prefix="tags"
                  field={@tag_fields.item}
                  vocabulary={@tag_vocabulary}
                />
                <.form_actions>
                  <.button patch={
                    if @editing_character,
                      do: ~p"/characters/#{@editing_character.id}/edit",
                      else: ~p"/characters"
                  }>
                    {dpgettext("characters", "button: discard edits to the open form", "Cancel")}
                  </.button>
                  <.button type="submit" variant="primary">
                    {dpgettext("characters", "button: save the open character", "Save")}
                  </.button>
                </.form_actions>
              </.form>
            </.pane_section>

            <.live_component
              :if={@live_action == :edit and @editing_character}
              module={MythweaverWeb.CharacterLive.Expressions}
              id="character-expressions"
              character={@editing_character}
              current_scope={@current_scope}
              revision={@expressions_revision}
            />
            <.pane_section :if={@live_action == :new}>
              <p id="character-expressions-hint">
                {dgettext("characters", "Save the character to add expression sprites.")}
              </p>
            </.pane_section>
            <.live_component
              :if={@editing_character}
              module={MythweaverWeb.SharePanel}
              id="character-share"
              current_scope={@current_scope}
              item={@editing_character}
            />
          </div>
        </:editor>
      </.pane_layout>
    </Layouts.app>
    """
  end

  attr :form, Form, required: true
  attr :field, :atom, required: true
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :kind, :atom, required: true, values: [:alternate, :group_only]
  attr :add_label, :string, required: true
  attr :completions, :map, default: nil

  # One editable list of greetings, a `<details>` collapsed by default (its `open` survives form
  # re-renders): a row per entry (editor + Remove) and an Add button. Add and Remove post the form's
  # change with their name/value (`greeting_params/1`). Rows come from the form's params when it has
  # them: the changeset's value has lost the blank ones.
  defp greeting_list(assigns) do
    field = assigns.form[assigns.field]
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    texts =
      case assigns.form.params[Atom.to_string(assigns.field)] do
        list when is_list(list) -> list
        _ -> List.wrap(field.value)
      end

    filled = for {t, i} <- Enum.with_index(texts), String.trim(t) != "", do: i

    {row_errors, errors} =
      Enum.split_with(errors, fn {_msg, opts} -> is_integer(opts[:index]) end)

    row_errors =
      Enum.map(row_errors, fn {_msg, opts} = error -> {Enum.at(filled, opts[:index] - 1), translate_error(error)} end)

    assigns =
      assign(assigns,
        texts: texts,
        count: Format.number(length(filled)),
        row_errors: row_errors,
        errors: Enum.map(errors, &translate_error/1)
      )

    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      .character-form-greetings-count {
        color: var(--muted-foreground);
      }

      .character-form-greetings-invalid {
        display: inline-flex;
        align-items: center;
        gap: var(--size-1);
        color: var(--destructive);
      }

      .character-form-greetings-body {
        display: grid;
        gap: var(--size-2);
        margin-block-start: var(--size-2);
      }

      .character-form-greeting {
        display: grid;
        grid-template-columns: minmax(0, 1fr) auto;
        align-items: end;
        gap: var(--size-2);
      }
    </style>
    <.disclosure id={@id} class="character-form-greetings">
      <:title>{@title}</:title>
      <:summary_extra>
        <span class="character-form-greetings-count">{@count}</span>
        <span
          :if={@row_errors != [] or @errors != []}
          id={"#{@id}-invalid"}
          class="character-form-greetings-invalid"
        >
          <.lucide name="circle-alert" />
          {dpgettext("characters", "status: greeting list has invalid entries", "Has errors")}
        </span>
      </:summary_extra>
      <div class="character-form-greetings-body">
        <div
          :for={{text, i} <- Enum.with_index(@texts)}
          id={"#{@id}-#{i}"}
          class="character-form-greeting"
        >
          <.editor
            name={"character[#{@field}][]"}
            value={text}
            id={"#{@id}-#{i}-text"}
            label={greeting_label(@kind, i)}
            rows={3}
            language="liquid"
            spellcheck
            completions={@completions}
          />
          <.button
            size="sm"
            icon
            id={"#{@id}-#{i}-remove"}
            name={"character[#{@field}_drop]"}
            value={i}
            phx-click={JS.dispatch("change")}
            aria-label={remove_greeting_label(@kind, i)}
          >
            <.lucide name="trash" />
          </.button>
          <.error :for={{^i, msg} <- @row_errors}>{msg}</.error>
        </div>
        <div>
          <.button
            type="button"
            size="sm"
            id={"#{@id}-add"}
            name={"character[#{@field}_add]"}
            value="1"
            phx-click={JS.dispatch("change")}
          >
            <.lucide name="plus" /> {@add_label}
          </.button>
        </div>
        <.error :for={msg <- @errors}>{msg}</.error>
      </div>
    </.disclosure>
    """
  end
end
