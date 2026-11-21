defmodule MythweaverWeb.PromptLive do
  @moduledoc """
  Prompt editor: the prompt list on the left; on the right the selected prompt's form, its ordered
  blocks, the blocks it can still take, and its bindings. `:index` selects nothing: the editor pane
  shows a placeholder until a prompt is picked. Every purpose is listed here, each
  row tagged with it, and the list's Type select narrows it to one purpose; only a `:roleplay`
  prompt shows its bindings, since no other purpose can be bound.

  Blocks are reordered by dragging a row's `<.drag_handle>` (the shared `SortableList` hook,
  `assets/js/hooks/sortable_list.ts`, which pushes the full block id order as `reorder_blocks`),
  handed straight to `Mythweaver.Prompts.reorder_blocks/2`, so position densification stays in the
  context. The rows follow the chat participant rail's shape: handle, name and detail, then a
  transparent icon toolbar. The Preview panel (`MythweaverWeb.PromptPreview`) renders the saved prompt
  against a chosen chat, for debugging its templates.
  """

  use MythweaverWeb, :live_view

  import MythweaverWeb.BulkComponents
  import MythweaverWeb.Pane
  import MythweaverWeb.PromptPreview
  import MythweaverWeb.TagFields
  import MythweaverWeb.TagFilter

  alias Mythweaver.AI
  alias Mythweaver.AI.SamplerParams
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Ownership
  alias Mythweaver.Prompts
  alias Mythweaver.Prompts.Block
  alias Mythweaver.Prompts.Prompt
  alias MythweaverWeb.Bulk
  alias MythweaverWeb.Bulk.Field
  alias MythweaverWeb.Bulk.Spec
  alias MythweaverWeb.CoreComponents.OwnerSelect
  alias MythweaverWeb.LiveSync

  on_mount {MythweaverWeb.ContentAccess, :prompts}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: page_title(),
       form: nil,
       editing_prompt: nil,
       new_owner: "personal",
       selected_id: nil,
       memberships_empty?: true,
       candidate_blocks: [],
       bindings_empty?: true,
       binding_scope: "global",
       provider_options: [],
       model_options: [],
       character_options: [],
       chat_options: []
     )
     |> assign_preview()
     |> assign_filter(%{}, [:query, :purpose])
     |> assign_tag_filter()
     |> stream_configure(:prompts, dom_id: &"prompts-#{&1.id}")
     |> stream_configure(:memberships, dom_id: &"prompt-prompt-blocks-#{&1.id}")
     |> stream_configure(:bindings, dom_id: &"prompt-bindings-#{&1.id}")
     |> stream(:memberships, [])
     |> stream(:bindings, [])
     |> stream_prompts()
     |> Bulk.attach([bulk_spec()])
     |> LiveSync.attach_editor([:prompts, :ai, :characters, :tags], &sync/2)}
  end

  defp sync(socket, kinds) do
    scope = socket.assigns.current_scope
    form = socket.assigns.form
    socket = if :tags in kinds, do: refresh_graph(socket), else: socket

    socket =
      if socket.assigns.editing_prompt && (:ai in kinds or :characters in kinds),
        do: load_options(socket),
        else: socket

    socket =
      socket
      |> stream_prompts()
      |> LiveSync.sync_open(:editing_prompt,
        fetch: &Prompts.get_editable_prompt(scope, &1),
        clean?: LiveSync.clean?(form),
        reload: fn s, fresh ->
          s
          |> assign(form: to_form(Prompts.change_prompt(fresh)))
          |> assign_tag_fields(:item, fresh, fresh.user_id)
        end,
        gone: ~p"/prompts",
        gone_message:
          (
            gettext_comment("Flash shown when the prompt open in the editor was deleted or moved by someone else.")
            dgettext("prompts", "The prompt was deleted or moved elsewhere.")
          ),
        force: :tags in kinds
      )

    with %Prompt{id: id} <- socket.assigns.editing_prompt,
         %Prompt{} = prompt <- Prompts.get_editable_prompt(scope, id) do
      load_prompt(socket, prompt)
    else
      _ -> socket
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(form: nil, editing_prompt: nil, selected_id: nil, page_title: page_title())
    |> stream_prompts()
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(
      form: to_form(Prompts.change_prompt(%Prompt{})),
      editing_prompt: nil,
      new_owner: "personal",
      selected_id: nil,
      page_title: page_title()
    )
    |> assign_tag_fields(:item, nil, OwnerSelect.tag_owner(socket.assigns.current_scope, Prompt, "personal"))
    |> stream_prompts()
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Prompts.get_editable_prompt(socket.assigns.current_scope, id) do
      nil ->
        prompt_missing(socket)

      prompt ->
        socket
        |> assign(form: to_form(Prompts.change_prompt(prompt)), selected_id: prompt.id)
        |> load_options()
        |> assign_preview()
        |> load_prompt(prompt)
        |> assign_tag_fields(:item, prompt, prompt.user_id)
        |> stream_prompts()
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, socket |> assign_filter(params, [:query, :purpose]) |> assign_tag_filter(params) |> stream_prompts()}
  end

  def handle_event("validate", %{"prompt" => params} = all, socket) do
    changeset =
      socket
      |> target_prompt()
      |> Prompts.change_prompt(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(form: to_form(changeset))
     |> put_new_owner(:editing_prompt, Prompt, OwnerSelect.choice(all))
     |> put_tag_params(:item, all["tags"])}
  end

  def handle_event("save", %{"prompt" => params} = all, socket) do
    socket = put_tag_params(socket, :item, all["tags"])

    result =
      case socket.assigns.editing_prompt do
        nil ->
          opts = OwnerSelect.create_opts(OwnerSelect.choice(all))

          Prompts.create_prompt(
            socket.assigns.current_scope,
            params,
            [followups: tag_followups(socket, :item, opts)] ++ opts
          )

        prompt ->
          Prompts.update_prompt(socket.assigns.current_scope, prompt, params)
      end

    case result do
      {:ok, prompt} ->
        socket =
          case save_tags(socket, :item, prompt) do
            {:ok, socket} -> put_flash(socket, :info, saved_flash(prompt.name))
            {:error, _what, socket} -> put_flash(socket, :error, tags_failed_flash(prompt.name))
          end

        {:noreply, push_patch(socket, to: ~p"/prompts/#{prompt.id}/edit")}

      {:held, hold} ->
        path =
          case socket.assigns.editing_prompt do
            nil -> ~p"/prompts"
            prompt -> ~p"/prompts/#{prompt.id}/edit"
          end

        {:noreply, socket |> flash_held(hold) |> push_patch(to: path)}

      {:error, :hold_limit} ->
        {:noreply, flash_hold_limit(socket)}

      {:error, :quota_exceeded} ->
        {:noreply, flash_quota(socket, "quota.prompts")}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(:error, save_failed_flash())}
    end
  end

  def handle_event("duplicate", %{"id" => id}, socket) do
    case Prompts.get_editable_prompt(socket.assigns.current_scope, id) do
      nil ->
        {:noreply, socket}

      prompt ->
        case Prompts.duplicate_prompt(socket.assigns.current_scope, prompt) do
          {:ok, copy} ->
            {:noreply,
             socket
             |> put_flash(:info, created_flash(copy.name))
             |> push_patch(to: ~p"/prompts/#{copy.id}/edit")}

          {:error, :quota_exceeded} ->
            {:noreply, flash_quota(socket, "quota.prompts")}

          {:error, :unauthorized} ->
            {:noreply, flash_unauthorized(socket)}

          {:error, %Ecto.Changeset{}} ->
            {:noreply, put_flash(socket, :error, duplicate_failed_flash(prompt.name))}
        end
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Prompts.get_editable_prompt(socket.assigns.current_scope, id) do
      nil ->
        {:noreply, socket}

      prompt ->
        result = Prompts.delete_prompt(socket.assigns.current_scope, prompt)
        {:noreply, MythweaverWeb.HandOff.after_delete(socket, result, prompt.name, ~p"/prompts")}
    end
  end

  def handle_event("toggle_block", %{"id" => id}, socket) do
    case membership(socket, id) do
      nil ->
        {:noreply, socket}

      membership ->
        {:ok, _} =
          Prompts.update_block_membership(socket.assigns.current_scope, membership, %{enabled: !membership.enabled})

        {:noreply, reload(socket)}
    end
  end

  def handle_event("remove_block", %{"id" => id}, socket) do
    case membership(socket, id) do
      nil ->
        {:noreply, socket}

      membership ->
        {:ok, _} = Prompts.remove_block(socket.assigns.current_scope, membership)
        {:noreply, socket |> reload() |> put_flash(:info, block_removed_flash(membership.block.name))}
    end
  end

  # From the drag hook: the full DOM order of block ids. A list that is not a permutation of the
  # prompt's blocks (a stale tab) is refused by the context; reloading snaps the rows back either way.
  def handle_event("reorder_blocks", %{"ids" => ids}, socket) when is_list(ids) do
    _ = Prompts.reorder_blocks(socket.assigns.current_scope, socket.assigns.editing_prompt, ids)
    {:noreply, reload(socket)}
  end

  def handle_event("add_block", %{"block_id" => ""}, socket), do: {:noreply, socket}

  def handle_event("add_block", %{"block_id" => block_id}, socket) do
    case Prompts.get_block(socket.assigns.current_scope, block_id) do
      nil ->
        {:noreply, socket}

      block ->
        case Prompts.add_block(socket.assigns.current_scope, socket.assigns.editing_prompt, block) do
          {:ok, _} ->
            {:noreply, socket |> reload() |> put_flash(:info, block_added_flash(block.name))}

          {:error, :unauthorized} ->
            {:noreply, flash_unauthorized(socket)}

          {:error, %Ecto.Changeset{}} ->
            {:noreply, put_flash(socket, :error, block_already_in_flash(block.name))}
        end
    end
  end

  def handle_event("select_scope", %{"scope" => scope}, socket) do
    {:noreply, assign(socket, binding_scope: scope)}
  end

  def handle_event("bind", %{"scope" => binding_scope} = params, socket) do
    case Prompts.bind_prompt(
           socket.assigns.current_scope,
           socket.assigns.editing_prompt,
           binding_scope,
           binding_ids(binding_scope, params)
         ) do
      {:ok, _} ->
        {:noreply, socket |> reload() |> put_flash(:info, binding_added_flash())}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, binding_error(changeset))}

      {:error, :not_roleplay} ->
        {:noreply, put_flash(socket, :error, not_roleplay_flash())}
    end
  end

  def handle_event("preview_options", %{"preview" => params}, socket), do: {:noreply, update_preview(socket, params)}

  def handle_event("preview_view", %{"view" => view}, socket), do: {:noreply, set_preview_view(socket, view)}

  def handle_event("preview", _params, socket) do
    case Prompts.get_editable_prompt(socket.assigns.current_scope, socket.assigns.editing_prompt.id) do
      nil -> {:noreply, prompt_missing(socket)}
      prompt -> {:noreply, run_preview(socket, prompt)}
    end
  end

  def handle_event("unbind", %{"id" => id}, socket) do
    prompt_id = socket.assigns.editing_prompt.id

    case Prompts.get_binding(socket.assigns.current_scope, id) do
      %{prompt_id: ^prompt_id} = binding ->
        {:ok, _} = Prompts.unbind_prompt(socket.assigns.current_scope, binding)
        {:noreply, socket |> reload() |> put_flash(:info, binding_removed_flash())}

      _ ->
        {:noreply, socket}
    end
  end

  # Only the columns the chosen scope requires; the changeset rejects anything else, so the form never
  # smuggles a leftover select value into a narrower scope.
  defp binding_ids(scope, params) do
    for field <- required_fields(scope), do: {field, blank_to_nil(params[Atom.to_string(field)])}
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp binding_error(changeset) do
    changeset.errors
    |> Enum.map_join("; ", fn {_field, error} -> translate_error(error) end)
    |> case do
      "" -> binding_failed_flash()
      message -> message
    end
  end

  # The streamed rows are not readable back out of the stream, so an id resolves through the context,
  # and only to a membership of the open prompt.
  defp membership(socket, id) do
    prompt_id = socket.assigns.editing_prompt.id

    case Prompts.get_prompt_block(socket.assigns.current_scope, id) do
      %{prompt_id: ^prompt_id} = membership -> membership
      _ -> nil
    end
  end

  defp reload(socket) do
    case Prompts.get_editable_prompt(socket.assigns.current_scope, socket.assigns.editing_prompt.id) do
      nil -> prompt_missing(socket)
      prompt -> socket |> load_prompt(prompt) |> stream_prompts()
    end
  end

  defp prompt_missing(socket) do
    socket
    |> put_flash(:error, not_found_flash())
    |> push_patch(to: ~p"/prompts")
  end

  defp load_prompt(socket, prompt) do
    memberships = prompt.prompt_blocks
    taken = MapSet.new(memberships, & &1.block_id)
    # Only blocks this prompt may include: site blocks, or its owner's.
    candidates =
      for block <- Prompts.list_blocks(socket.assigns.current_scope),
          not MapSet.member?(taken, block.id),
          Ownership.reference_ok?(prompt.user_id, block),
          do: block

    bindings = Prompts.list_bindings(socket.assigns.current_scope, prompt)

    socket
    |> assign(
      editing_prompt: prompt,
      page_title: prompt.name,
      memberships_empty?: memberships == [],
      candidate_blocks: candidates,
      bindings_empty?: bindings == []
    )
    |> stream(:memberships, memberships, reset: true)
    |> stream(:bindings, bindings, reset: true)
  end

  # Targets are managed elsewhere, so the option lists are refreshed on every navigation rather than
  # cached at mount.
  defp load_options(socket) do
    scope = socket.assigns.current_scope

    assign(socket,
      provider_options: AI.provider_options(scope),
      model_options: AI.model_options(scope),
      character_options: Characters.character_options(scope),
      chat_options: Chats.chat_options(scope)
    )
  end

  ## View helpers

  defp page_title, do: dpgettext("prompts", "page title: list of prompts", "Prompts")

  defp scopes do
    [
      {dpgettext("prompts", "option: prompt binding scope, every chat", "Global"), :global},
      {dpgettext("prompts", "option: prompt binding scope, one AI connection", "Connection"), :connection},
      {dpgettext("prompts", "option: prompt binding scope, one AI model", "Model"), :model},
      {dpgettext("prompts", "option: prompt binding scope, one character", "Character"), :character},
      {dpgettext("prompts", "option: prompt binding scope, one chat", "Chat"), :chat},
      {dpgettext("prompts", "option: prompt binding scope, one character in one chat", "Character in chat"),
       :character_in_chat}
    ]
  end

  defp purpose_options do
    for purpose <- Ecto.Enum.values(Prompt, :purpose), do: {purpose_label(purpose), purpose}
  end

  defp purpose_label(:roleplay), do: dpgettext("prompts", "option: prompt purpose", "Roleplay")
  defp purpose_label(:memory), do: dpgettext("prompts", "option: prompt purpose", "Memory")
  defp purpose_label(:consolidation), do: dpgettext("prompts", "option: prompt purpose", "Consolidation")
  defp purpose_label(:compaction), do: dpgettext("prompts", "option: prompt purpose", "Compaction")
  defp purpose_label(:topical_clip), do: dpgettext("prompts", "option: prompt purpose", "Topical clip")
  defp purpose_label(:side_prompt), do: dpgettext("prompts", "option: prompt purpose", "Side prompt")
  defp purpose_label(:clip_review), do: dpgettext("prompts", "option: prompt purpose", "Clip review")
  defp purpose_label(:clip_suggestions), do: dpgettext("prompts", "option: prompt purpose", "Clip suggestions")
  defp purpose_label(:combine_clips), do: dpgettext("prompts", "option: prompt purpose", "Combine clips")
  defp purpose_label(:caption), do: dpgettext("prompts", "option: prompt purpose", "Caption")

  defp scope_label(scope) do
    Enum.find_value(scopes(), to_string(scope), fn {label, value} ->
      if value == scope, do: label
    end)
  end

  defp binding_target(binding) do
    case binding.scope do
      :global ->
        dpgettext("prompts", "status: target of a global prompt binding", "every chat")

      :connection ->
        name_of(binding.provider)

      :model ->
        name_of(binding.model)

      :character ->
        name_of(binding.character)

      :chat ->
        name_of(binding.chat)

      :character_in_chat ->
        dpgettext(
          "prompts",
          "status: target of a character-in-chat prompt binding",
          "%{character_name} in %{chat_name}",
          character_name: name_of(binding.character),
          chat_name: name_of(binding.chat)
        )
    end
  end

  defp name_of(nil), do: dpgettext("prompts", "status: a prompt binding's target was deleted", "(deleted)")
  defp name_of(%{name: nil}), do: dpgettext("prompts", "heading: item without a name", "Untitled")
  defp name_of(%{name: name}), do: name

  defp needs?(scope, field), do: field in required_fields(scope)

  defp required_fields("connection"), do: [:provider_id]
  defp required_fields("model"), do: [:ai_model_id]
  defp required_fields("character"), do: [:character_id]
  defp required_fields("chat"), do: [:chat_id]
  defp required_fields("character_in_chat"), do: [:character_id, :chat_id]
  defp required_fields(_scope), do: []

  defp target_prompt(socket), do: socket.assigns.editing_prompt || %Prompt{}

  defp bulk_spec do
    %Spec{
      name: :prompts,
      tag_kind: :prompt,
      count_label:
        &dpngettext(
          "prompts",
          "count phrase: prompts affected by a bulk action",
          "%{prompt_count} prompt",
          "%{prompt_count} prompts",
          &1,
          prompt_count: Mythweaver.Format.number(&1)
        ),
      ids: & &1.assigns.prompts_ids,
      get: &Prompts.get_editable_prompt/2,
      update: &Prompts.update_prompt/3,
      delete: &Prompts.delete_prompt/2,
      title: & &1.name,
      refresh: &stream_prompts/1,
      open_id: & &1.assigns.selected_id,
      index_path: ~p"/prompts",
      edit_path: &~p"/prompts/#{&1}/edit",
      fields: [
        %Field{
          key: :enabled,
          label: dpgettext("prompts", "toggle: prompt is in use", "Enabled"),
          type: :checkbox
        },
        %Field{
          key: :purpose,
          label: dpgettext("prompts", "field label: what a prompt is used for", "Purpose"),
          type: :select,
          options: purpose_options()
        },
        %Field{
          key: :thinking,
          label: dpgettext("prompts", "field label: reasoning level a prompt asks the model for", "Thinking"),
          type: :select,
          options: SamplerParams.thinking_options(),
          prompt: dpgettext("prompts", "option: use the model's own thinking level", "Model's level")
        }
      ]
    }
  end

  defp stream_prompts(socket) do
    prompts = filter_by_purpose(Prompts.list_editable_prompts(socket.assigns.current_scope), socket.assigns.purpose)
    stream_search(socket, :prompts, filter_tagged(socket, prompts, :prompt), &[&1.name, &1.description])
  end

  defp filter_by_purpose(prompts, ""), do: prompts
  defp filter_by_purpose(prompts, purpose), do: Enum.filter(prompts, &(to_string(&1.purpose) == purpose))

  defp block_count(count) do
    dpngettext(
      "prompts",
      "status: number of blocks in a prompt",
      "%{block_count} block",
      "%{block_count} blocks",
      count,
      block_count: Mythweaver.Format.number(count)
    )
  end

  defp not_found_flash do
    gettext_comment("Flash when the prompt in the address no longer exists or cannot be edited.")
    dpgettext("prompts", "status: flash, the prompt to edit was not found", "Prompt not found")
  end

  defp saved_flash(prompt_name) do
    gettext_comment("Flash after a prompt was saved.")
    dpgettext("prompts", "status: flash after a prompt was saved", "%{prompt_name} saved", prompt_name: prompt_name)
  end

  defp tags_failed_flash(prompt_name) do
    gettext_comment("Flash when a prompt was saved but writing its tags failed.")
    dgettext("prompts", "%{prompt_name} saved, but its tags did not", prompt_name: prompt_name)
  end

  defp save_failed_flash do
    gettext_comment("Flash when saving an editor form fails validation; the invalid fields are highlighted.")
    dgettext("prompts", "Could not save — see the highlighted fields")
  end

  defp created_flash(prompt_name) do
    gettext_comment("Flash after a prompt was duplicated; the name is the copy's.")

    dpgettext("prompts", "status: flash after a prompt copy was created", "%{prompt_name} created",
      prompt_name: prompt_name
    )
  end

  defp duplicate_failed_flash(prompt_name) do
    gettext_comment("Flash when duplicating a prompt failed.")

    dpgettext("prompts", "status: flash, duplicating a prompt failed", "Could not duplicate %{prompt_name}",
      prompt_name: prompt_name
    )
  end

  defp block_removed_flash(block_name) do
    gettext_comment("Flash after a block was removed from the open prompt.")

    dpgettext("prompts", "status: flash after a block was removed from a prompt", "%{block_name} removed",
      block_name: block_name
    )
  end

  defp block_added_flash(block_name) do
    gettext_comment("Flash after a block was added to the open prompt.")

    dpgettext("prompts", "status: flash after a block was added to a prompt", "%{block_name} added",
      block_name: block_name
    )
  end

  defp block_already_in_flash(block_name) do
    gettext_comment("Flash when the block chosen to add is already part of the open prompt.")
    dgettext("prompts", "%{block_name} is already in this prompt", block_name: block_name)
  end

  defp binding_added_flash do
    gettext_comment("Flash after a binding was added to the open prompt.")
    dpgettext("prompts", "status: flash after a prompt binding was added", "Binding added")
  end

  defp binding_removed_flash do
    gettext_comment("Flash after a binding was removed from the open prompt.")
    dpgettext("prompts", "status: flash after a prompt binding was removed", "Binding removed")
  end

  defp binding_failed_flash do
    gettext_comment("Flash when adding a prompt binding failed for no specific reason.")
    dgettext("prompts", "Could not add the binding")
  end

  defp not_roleplay_flash do
    gettext_comment("Flash when binding a prompt whose purpose is not roleplay.")
    dgettext("prompts", "Only a roleplay prompt can be bound")
  end

  defp delete_confirm(prompt_name) do
    gettext_comment("Confirm dialog before deleting a prompt.")
    dpgettext("prompts", "button: confirm dialog, delete a prompt", "Delete %{prompt_name}?", prompt_name: prompt_name)
  end

  defp role_label(:system), do: dpgettext("prompts", "badge: prompt block role, system message", "system")
  defp role_label(:user), do: dpgettext("prompts", "badge: prompt block role, user message", "user")
  defp role_label(:assistant), do: dpgettext("prompts", "badge: prompt block role, assistant message", "assistant")

  defp binding_target_fields(provider_options, model_options, character_options, chat_options) do
    [
      {:provider_id, dpgettext("prompts", "field label: AI connection a prompt is bound to", "Connection"),
       dpgettext("prompts", "option: no AI connection chosen yet for a prompt binding", "Choose a connection"),
       provider_options},
      {:ai_model_id, dpgettext("prompts", "field label: AI model a prompt is bound to", "Model"),
       dpgettext("prompts", "option: no AI model chosen yet for a prompt binding", "Choose a model"), model_options},
      {:character_id, dpgettext("prompts", "field label: character a prompt is bound to", "Character"),
       dpgettext("prompts", "option: no character chosen yet for a prompt binding", "Choose a character"),
       character_options},
      {:chat_id, dpgettext("prompts", "field label: chat a prompt is bound to", "Chat"),
       dpgettext("prompts", "option: no chat chosen yet for a prompt binding", "Choose a chat"), chat_options}
    ]
  end

  defp edit_block_label(block_name) do
    dpgettext("prompts", "aria label: icon link that edits this block of the prompt", "Edit %{block_name}",
      block_name: block_name
    )
  end

  defp remove_block_label(block_name) do
    dgettext("prompts", "Remove %{block_name} from this prompt", block_name: block_name)
  end

  defp thinking_hint do
    gettext_comment(
      "Hint under a prompt's Thinking select. %{backend_default} and %{off} are the select's option names, emphasized."
    )

    rich(
      dgettext(
        "prompts",
        "How hard a reasoning model thinks for this prompt. Never above the model's own Thinking level; on a model left at %{backend_default}, this level is sent as it is. %{off} suits mechanical work such as compaction.",
        backend_default: em(dpgettext("prompts", "option: thinking level, leave it to the backend", "Backend default")),
        off: em(dpgettext("prompts", "option: thinking level, no reasoning", "Off"))
      )
    )
  end

  @impl true
  def render(assigns) do
    # The membership toggle's icon is computed, so the Iconex compiler cannot see it.
    Iconex.hint(:lucide, ~w[eye eye-off])

    ~H"""
    <%!--
      `lower-bound="none"`: `.prompt-show-input` styles reach inside
      `<.input>`'s own template, which is a nested-component root carrying `phx-r` that the default
      exclusive bound cuts off.
    --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      /* The editor slot's root. `pane_layout`'s `<section>` carries no marker from this block, so
         without it `<.form>` and the panels would sit outside this scope. */
      div.prompt-editor-body:scope {
        display: contents;
      }

      .prompt-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .prompt-form label {
        display: block;
      }

      .prompt-show-hint {
        margin: 0;
        color: var(--muted-foreground);
      }

      .prompt-show-list {
        list-style: none;
        margin: 0;
        padding: 0;
        border: 1px solid var(--border-grey);
        border-radius: var(--radius-2);
        background: var(--surface-2);
      }

      .prompt-show-row {
        display: flex;
        align-items: center;
        flex-wrap: wrap;
        gap: var(--size-2);
        padding: var(--size-2) var(--size-3);
        border-bottom: 1px solid var(--border-grey);
      }

      .prompt-show-row:last-child {
        border-bottom: 0;
      }

      /*
        Block rows, shaped like `.chat-participant` in participants.ex (the other draggable list):
        handle and toolbar size to content, the name column absorbs the rest and truncates.
      */
      .prompt-block-list {
        list-style: none;
        margin: 0;
        padding: 0;
        border: 1px solid var(--border-grey);
        border-radius: var(--radius-2);
        background: var(--surface-2);
      }

      .prompt-block-row {
        display: grid;
        grid-template-columns: auto minmax(0, 1fr) auto;
        align-items: center;
        gap: var(--size-2);
        padding: var(--size-2) var(--size-3);
        border-bottom: 1px solid var(--border-grey);
      }

      .prompt-block-row:last-child {
        border-bottom: 0;
      }

      .prompt-block-row--disabled .prompt-block-main {
        opacity: 0.6;
      }

      .prompt-block-main {
        min-width: 0;
      }

      .prompt-block-identity {
        display: flex;
        align-items: center;
        gap: var(--size-1);
      }

      .prompt-block-name {
        font-weight: 600;
        overflow: hidden;
        white-space: nowrap;
        text-overflow: ellipsis;
      }

      .prompt-block-meta {
        margin: 0;
        color: var(--muted-foreground);
        font-size: 0.8rem;
      }

      .prompt-block-actions {
        display: flex;
        align-items: center;
        gap: var(--size-1);
      }

      /* Transparent secondary variant, matching `.chat-participant-action`. */
      .prompt-block-action {
        padding: var(--size-1);
        border: 0;
        border-radius: var(--radius-2);
        background: none;
        color: var(--muted-foreground);
        font: inherit;
        line-height: 0;
        cursor: pointer;
      }

      .prompt-block-action:hover {
        color: var(--foreground);
        background: var(--surface-5);
      }

      .prompt-block-action--danger:hover {
        color: var(--destructive-foreground);
        background: var(--destructive);
      }

      .prompt-show-row-name {
        font-weight: 600;
      }

      .prompt-show-row-actions {
        display: flex;
        gap: var(--size-1);
        margin-left: auto;
      }

      .prompt-show-form {
        display: flex;
        align-items: flex-end;
        flex-wrap: wrap;
        gap: var(--size-2);
      }

      .prompt-show-form label {
        display: block;
      }

      .prompt-show-input {
        display: block;
        font: inherit;
        color: var(--foreground);
        background: var(--surface-2);
        border: 1px solid var(--input);
        border-radius: var(--radius-2);
        padding: var(--size-2);
      }

      /* The add-existing form and "Create new block" side by side, wrapping on a narrow pane. */
      .prompt-show-add {
        display: flex;
        align-items: flex-end;
        flex-wrap: wrap;
        gap: var(--size-2);
      }

      /* Buttons beside a `.prompt-show-input`, sized to its height: its `--size-2` padding, less the
         1px border `<.button>` always carries. */
      .prompt-show-control {
        padding: calc(var(--size-2) - 1px);
      }
    </style>
    <Layouts.app flash={@flash} current_scope={@current_scope} search={:prompts}>
      <.pane_layout>
        <:list id="prompts-nav" label={dpgettext("prompts", "aria label: list of prompts", "Prompts")}>
          <.pane_header title={dpgettext("prompts", "heading: list of prompts", "Prompts")}>
            <:switch id="pane-switch-blocks" navigate={~p"/prompts/blocks"}>
              <.lucide name="blocks" /> {dpgettext(
                "prompts",
                "link: switch to the prompt blocks list",
                "Blocks"
              )}
            </:switch>
            <:switch id="pane-switch-outlets" navigate={~p"/prompts/outlets"}>
              <.lucide name="cable" /> {dpgettext(
                "prompts",
                "link: switch to the custom outlets list",
                "Outlets"
              )}
            </:switch>
          </.pane_header>

          <.pane_actions>
            <.button variant="primary" patch={~p"/prompts/new"} id="new-prompt">
              <.lucide name="plus" /> {dpgettext("prompts", "button: create a prompt", "New prompt")}
            </.button>
            <.button navigate={~p"/import"} id="import-prompt">
              <.lucide name="upload" /> {dpgettext(
                "prompts",
                "button: open the import page",
                "Import"
              )}
            </.button>
            <.bulk_toggle bulk={@bulk} id="prompts-bulk-toggle" />
          </.pane_actions>
          <.bulk_bar bulk={@bulk} id="prompts-bulk" />

          <.pane_search
            id="prompt-filter"
            form={@filter_form}
            placeholder={dpgettext("prompts", "placeholder: search prompts", "Name or description")}
          >
            <.input
              field={@filter_form[:purpose]}
              type="select"
              label={dpgettext("prompts", "field label: filter prompts by purpose", "Type")}
              id="prompt-filter-purpose"
              prompt={dpgettext("prompts", "option: show prompts of every purpose", "All types")}
              options={purpose_options()}
            />
            <.tag_filter
              id="prompt-filter-tags"
              values={@tag_filter}
              vocabulary={@tag_vocabulary}
              errors={@tag_filter_errors}
              invalid={@tag_filter_invalid}
            />
          </.pane_search>

          <.pane_items
            :let={prompt}
            id="prompts"
            bulk={@bulk}
            bulk_list="prompts"
            rows={@streams.prompts}
            empty?={@prompts_empty?}
            empty={
              if @query == "" and @purpose == "" and @tag_filter == [],
                do: dpgettext("prompts", "empty state: no prompts exist", "No prompts yet"),
                else:
                  dpgettext(
                    "prompts",
                    "empty state: no prompts match the filter",
                    "No prompts match this filter"
                  )
            }
            selected_id={@selected_id}
            patch={fn prompt -> ~p"/prompts/#{prompt.id}/edit" end}
          >
            <span class="pane-item-name">{prompt.name}</span>
            <span class="pane-item-meta">
              {block_count(length(prompt.prompt_blocks))}
              <.badge id={"prompts-#{prompt.id}-purpose"}>{purpose_label(prompt.purpose)}</.badge>
            </span>
          </.pane_items>
        </:list>

        <:editor id="prompt-editor">
          <.pane_placeholder :if={@live_action == :index} id="prompt-placeholder">
            {dgettext("prompts", "Select a prompt, or create a new one.")}
          </.pane_placeholder>
          <div :if={@live_action != :index} class="prompt-editor-body">
            <.panel_header sticky>
              {if @editing_prompt,
                do: @editing_prompt.name,
                else: dpgettext("prompts", "heading: form for a new prompt", "New prompt")}
              <:actions :if={@editing_prompt}>
                <.pane_export
                  id="export-prompt"
                  kind={:prompt}
                  item={@editing_prompt}
                  current_scope={@current_scope}
                />
                <.button
                  id={"duplicate-prompt-#{@editing_prompt.id}"}
                  size="sm"
                  phx-click="duplicate"
                  phx-value-id={@editing_prompt.id}
                >
                  <.lucide name="copy" /> {dpgettext(
                    "prompts",
                    "button: duplicate the open prompt",
                    "Duplicate"
                  )}
                </.button>
                <.live_component
                  :if={Ownership.deletable?(@current_scope, @editing_prompt)}
                  module={MythweaverWeb.HandOff}
                  id="prompt-handoff"
                  thing="prompt"
                  current_scope={@current_scope}
                  item={@editing_prompt}
                  delete={&Prompts.delete_prompt/3}
                  index={~p"/prompts"}
                  delete_id="delete-prompt"
                  confirm={delete_confirm(@editing_prompt.name)}
                />
              </:actions>
            </.panel_header>
            <.live_component
              :if={@editing_prompt}
              module={MythweaverWeb.Lineage}
              id="prompt-lineage-line"
              thing="prompt"
              current_scope={@current_scope}
              item={@editing_prompt}
            />

            <.pane_section>
              <.changed_elsewhere
                :if={@changed_elsewhere?}
                id="prompt-changed-elsewhere"
                patch={@live_sync_path}
              />
              <.form
                for={@form}
                id="prompt-form"
                class="prompt-form"
                phx-hook="UnsavedChanges"
                data-saved={is_nil(@form.action)}
                phx-change="validate"
                phx-submit="save"
              >
                <.owner_select
                  :if={is_nil(@editing_prompt)}
                  id="prompt-form-owner"
                  scope={@current_scope}
                  schema={Prompt}
                  value={@new_owner}
                />
                <.input
                  field={@form[:name]}
                  type="text"
                  label={dpgettext("prompts", "field label: name of a prompt", "Name")}
                  id="prompt-form-name"
                  required
                />
                <.editor
                  field={@form[:description]}
                  label={dpgettext("prompts", "field label: description of a prompt", "Description")}
                  rows={2}
                  id="prompt-form-description"
                  language="markdown"
                  spellcheck
                />
                <.input
                  field={@form[:purpose]}
                  type="select"
                  label={dpgettext("prompts", "field label: what a prompt is used for", "Purpose")}
                  id="prompt-form-purpose"
                  options={purpose_options()}
                />
                <.input
                  field={@form[:thinking]}
                  type="select"
                  label={
                    dpgettext(
                      "prompts",
                      "field label: reasoning level a prompt asks the model for",
                      "Thinking"
                    )
                  }
                  prompt={
                    dpgettext(
                      "prompts",
                      "option: use the model's own thinking level",
                      "Model's level"
                    )
                  }
                  options={SamplerParams.thinking_options()}
                  id="prompt-form-thinking"
                >
                  <:hint>
                    {thinking_hint()}
                  </:hint>
                </.input>
                <.input
                  field={@form[:enabled]}
                  type="checkbox"
                  label={dpgettext("prompts", "toggle: prompt is in use", "Enabled")}
                  id="prompt-form-enabled"
                />
                <.input
                  :if={OwnerSelect.site_row?(@editing_prompt, @current_scope, Prompt, @new_owner)}
                  field={@form[:site_visibility]}
                  type="select"
                  label={
                    dpgettext(
                      "prompts",
                      "field label: how much of a site prompt users see",
                      "Visible to users"
                    )
                  }
                  id="prompt-form-site_visibility"
                  options={[
                    {dpgettext(
                       "prompts",
                       "option: users see all of a site prompt block",
                       "Everything"
                     ), "readable"},
                    {dpgettext(
                       "prompts",
                       "option: users see only a site prompt block's name",
                       "Only names (runtime-only)"
                     ), "runtime_only"}
                  ]}
                >
                  <:hint>
                    {dgettext(
                      "prompts",
                      "What users who are not admins see of this prompt. Only names: never the content of its blocks, in the prompt inspector, the assistant, scripts or exports; the model still gets it. Admins always see everything."
                    )}
                  </:hint>
                </.input>
                <.tag_fields
                  id="prompt-form-tags"
                  prefix="tags"
                  field={@tag_fields.item}
                  vocabulary={@tag_vocabulary}
                />
                <.form_actions>
                  <.button patch={
                    if @editing_prompt,
                      do: ~p"/prompts/#{@editing_prompt.id}/edit",
                      else: ~p"/prompts"
                  }>
                    {dpgettext("prompts", "button: cancel editing the open form", "Cancel")}
                  </.button>
                  <.button type="submit" variant="primary">
                    {dpgettext("prompts", "button: save the open form", "Save")}
                  </.button>
                </.form_actions>
              </.form>
            </.pane_section>

            <.pane_section :if={@editing_prompt}>
              <.section_header>
                {dpgettext(
                  "prompts",
                  "heading: ordered blocks of the open prompt",
                  "Blocks in this prompt"
                )}
              </.section_header>
              <p :if={@memberships_empty?} class="prompt-show-hint">
                {dpgettext("prompts", "empty state: the open prompt has no blocks", "No blocks yet")}
              </p>
              <ul
                id="prompt-blocks"
                class="prompt-block-list"
                hidden={@memberships_empty?}
                phx-update="stream"
                phx-hook="SortableList"
                data-sortable-event="reorder_blocks"
              >
                <li
                  :for={{dom_id, membership} <- @streams.memberships}
                  id={dom_id}
                  class={["prompt-block-row", !membership.enabled && "prompt-block-row--disabled"]}
                  data-id={membership.block_id}
                >
                  <.drag_handle />

                  <div class="prompt-block-main">
                    <div class="prompt-block-identity">
                      <span class="prompt-block-name">{membership.block.name}</span>
                      <.badge :if={!membership.enabled}>
                        {dpgettext("prompts", "badge: block is turned off in this prompt", "disabled")}
                      </.badge>
                    </div>
                    <p class="prompt-block-meta">
                      {Block.kind_label(membership.block)} · {role_label(membership.block.role)}
                    </p>
                  </div>

                  <div
                    class="prompt-block-actions"
                    role="group"
                    aria-label={
                      dpgettext(
                        "prompts",
                        "aria label: toolbar of a block row in a prompt",
                        "Actions for %{block_name}",
                        block_name: membership.block.name
                      )
                    }
                  >
                    <button
                      type="button"
                      class="prompt-block-action"
                      id={"toggle-prompt-block-#{membership.id}"}
                      phx-click="toggle_block"
                      phx-value-id={membership.id}
                      aria-pressed={to_string(membership.enabled)}
                      aria-label={
                        if membership.enabled,
                          do:
                            dgettext("prompts", "Disable %{block_name} in this prompt",
                              block_name: membership.block.name
                            ),
                          else:
                            dgettext("prompts", "Enable %{block_name} in this prompt",
                              block_name: membership.block.name
                            )
                      }
                    >
                      <.lucide name={if membership.enabled, do: "eye", else: "eye-off"} />
                    </button>
                    <.link
                      navigate={
                        ~p"/prompts/blocks/#{membership.block_id}/edit?#{[prompt_id: @editing_prompt.id]}"
                      }
                      class="prompt-block-action"
                      id={"edit-prompt-block-#{membership.id}"}
                      aria-label={edit_block_label(membership.block.name)}
                      title={edit_block_label(membership.block.name)}
                    >
                      <.lucide name="pencil" />
                    </.link>
                    <button
                      type="button"
                      class="prompt-block-action prompt-block-action--danger"
                      id={"remove-prompt-block-#{membership.id}"}
                      phx-click="remove_block"
                      phx-value-id={membership.id}
                      aria-label={remove_block_label(membership.block.name)}
                      title={remove_block_label(membership.block.name)}
                    >
                      <.lucide name="x" />
                    </button>
                  </div>
                </li>
              </ul>
            </.pane_section>

            <.pane_section :if={@editing_prompt}>
              <.section_header>
                {dpgettext("prompts", "heading: rendered preview of the block or prompt", "Preview")}
              </.section_header>
              <.prompt_preview
                id="prompt-preview"
                chats={@preview_chats}
                chat={@preview_chat}
                form={@preview_form}
                result={@preview_result}
                view={@preview_view}
              />
            </.pane_section>

            <.pane_section :if={@editing_prompt}>
              <.section_header>
                {dpgettext("prompts", "heading: add a block to the open prompt", "Add a block")}
              </.section_header>
              <p :if={@candidate_blocks == []} class="prompt-show-hint">
                {dgettext("prompts", "Every block is already in this prompt")}
              </p>
              <div class="prompt-show-add">
                <form
                  :if={@candidate_blocks != []}
                  id="prompt-add-block-form"
                  class="prompt-show-form"
                  phx-submit="add_block"
                >
                  <label for="prompt-add-block-form-block_id">
                    {dpgettext("prompts", "field label: block to add to the open prompt", "Block")}
                  </label>
                  <select
                    name="block_id"
                    id="prompt-add-block-form-block_id"
                    class="prompt-show-input"
                  >
                    <option value="">
                      {dpgettext(
                        "prompts",
                        "option: no block chosen yet to add to the prompt",
                        "Choose a block"
                      )}
                    </option>
                    <option :for={block <- @candidate_blocks} value={block.id}>{block.name}</option>
                  </select>
                  <.button type="submit" variant="primary" class="prompt-show-control">
                    <.lucide name="plus" /> {dpgettext(
                      "prompts",
                      "button: add the chosen block to the prompt",
                      "Add"
                    )}
                  </.button>
                </form>
                <%!-- The block editor adds the new block to this prompt on save and navigates back. --%>
                <.button
                  class="prompt-show-control"
                  navigate={~p"/prompts/blocks/new?#{[prompt_id: @editing_prompt.id]}"}
                  id="create-prompt-block"
                >
                  <.lucide name="square-plus" />
                  {dpgettext(
                    "prompts",
                    "button: create a block and add it to the open prompt",
                    "Create new block"
                  )}
                </.button>
              </div>
            </.pane_section>

            <.pane_section :if={@editing_prompt && @editing_prompt.purpose == :roleplay}>
              <.section_header>
                {dgettext("prompts", "Bindings — the most specific match wins")}
              </.section_header>
              <p class="prompt-show-hint">
                {dgettext(
                  "prompts",
                  "Character in chat beats chat, which beats character, model, connection, and finally global."
                )}
              </p>
              <p :if={@bindings_empty?} class="prompt-show-hint">
                {dgettext("prompts", "Not bound to anything yet")}
              </p>
              <ul
                id="prompt-bindings"
                class="prompt-show-list"
                phx-update="stream"
                hidden={@bindings_empty?}
              >
                <li
                  :for={{dom_id, binding} <- @streams.bindings}
                  id={dom_id}
                  class="prompt-show-row"
                >
                  <.badge>{scope_label(binding.scope)}</.badge>
                  <span class="prompt-show-row-name">{binding_target(binding)}</span>
                  <div class="prompt-show-row-actions">
                    <.button danger phx-click="unbind" phx-value-id={binding.id}>
                      <.lucide name="x" /> {dpgettext(
                        "prompts",
                        "button: remove this prompt binding",
                        "Unbind"
                      )}
                    </.button>
                  </div>
                </li>
              </ul>
              <form
                id="prompt-bindings-form"
                class="prompt-show-form"
                phx-change="select_scope"
                phx-submit="bind"
              >
                <label for="prompt-bindings-form-scope">
                  {dpgettext("prompts", "field label: scope of a new prompt binding", "Scope")}
                </label>
                <select name="scope" id="prompt-bindings-form-scope" class="prompt-show-input">
                  <option
                    :for={{label, value} <- scopes()}
                    value={value}
                    selected={@binding_scope == to_string(value)}
                  >
                    {label}
                  </option>
                </select>

                <%= for {field, label, choose, options} <- binding_target_fields(@provider_options, @model_options, @character_options, @chat_options),
                        needs?(@binding_scope, field) do %>
                  <label for={"prompt-bindings-form-#{field}"}>{label}</label>
                  <select name={field} id={"prompt-bindings-form-#{field}"} class="prompt-show-input">
                    <option value="">{choose}</option>
                    <option :for={{name, value} <- options} value={value}>{name}</option>
                  </select>
                <% end %>

                <.button type="submit" variant="primary" class="prompt-show-control">
                  <.lucide name="plus" /> {dpgettext(
                    "prompts",
                    "button: add a binding to the open prompt",
                    "Bind"
                  )}
                </.button>
              </form>
            </.pane_section>
            <.live_component
              :if={@editing_prompt}
              module={MythweaverWeb.SharePanel}
              id="prompt-share"
              current_scope={@current_scope}
              item={@editing_prompt}
            />
          </div>
        </:editor>
      </.pane_layout>
    </Layouts.app>
    """
  end
end
