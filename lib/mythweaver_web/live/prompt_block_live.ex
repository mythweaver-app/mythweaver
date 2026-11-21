defmodule MythweaverWeb.PromptBlockLive do
  @moduledoc """
  Prompt block editor: the block list on the left, the selected block's form on the right.
  `:index` selects nothing: the editor pane shows a placeholder until a block is picked.
  Blocks are the reusable segments prompts are composed from.

  `kind` is a schema field. A **template** block's content is a Liquid template, so the form shows a
  "Template reference" list of every `anchors.*` path, each custom `outlets.<key>`, and `vars`/`globals`.
  A **chat history** block has no text: the content box is hidden and saving clears it. Outlets are
  created on a sibling page, so the list is reloaded whenever the form opens.

  `/prompts/blocks/new?prompt_id=<id>` (the prompt editor's "Create new block") is the same form
  with a return prompt: saving also adds the block to that prompt and navigates back to it, and
  Cancel returns there too. `/prompts/blocks/:id/edit?prompt_id=<id>` (the prompt editor's per-block
  edit button) returns the same way after a save or Cancel, without touching membership. An unknown
  or malformed `prompt_id` is ignored, leaving the plain form; picking another block in the list
  drops the return prompt.

  The Preview panel (`MythweaverWeb.PromptPreview`) renders the block as currently typed, saved or
  not, against a chosen chat.
  """

  use MythweaverWeb, :live_view

  import MythweaverWeb.Pane
  import MythweaverWeb.PromptPreview
  import MythweaverWeb.TagFields
  import MythweaverWeb.TagFilter

  alias Mythweaver.Ownership
  alias Mythweaver.Prompts
  alias Mythweaver.Prompts.Anchor
  alias Mythweaver.Prompts.Block
  alias Mythweaver.Prompts.Completions
  alias Mythweaver.Prompts.Preview
  alias MythweaverWeb.CoreComponents.OwnerSelect
  alias MythweaverWeb.LiveSync

  on_mount {MythweaverWeb.ContentAccess, :prompts}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: dpgettext("prompts", "page title: list of prompt blocks", "Prompt blocks"),
       form: nil,
       editing_block: nil,
       new_owner: "personal",
       selected_id: nil,
       return_prompt: nil,
       anchor_catalog: Anchor.catalog(),
       template_completions: Completions.template(socket.assigns.current_scope),
       outlets: []
     )
     |> assign_preview()
     |> assign_filter()
     |> assign_tag_filter()
     |> stream_configure(:blocks, dom_id: &"prompt-blocks-#{&1.id}")
     |> stream_blocks()
     |> LiveSync.attach_editor([:prompts, :tags], &sync/2)}
  end

  defp sync(socket, kinds) do
    scope = socket.assigns.current_scope
    form = socket.assigns.form
    socket = if :tags in kinds, do: refresh_graph(socket), else: socket
    socket = if form, do: assign(socket, outlets: Prompts.list_outlets(scope)), else: socket

    socket
    |> stream_blocks()
    |> LiveSync.sync_open(:editing_block,
      fetch: &Prompts.get_editable_block(scope, &1),
      clean?: LiveSync.clean?(form),
      reload: fn s, fresh ->
        s
        |> assign(form: to_form(Prompts.change_block(fresh)), editing_block: fresh)
        |> assign_tag_fields(:item, fresh, fresh.user_id)
      end,
      gone: ~p"/prompts/blocks",
      gone_message:
        (
          gettext_comment("Flash shown when the block open in the editor was deleted or moved by someone else.")
          dgettext("prompts", "The block was deleted or moved elsewhere.")
        ),
      force: :tags in kinds
    )
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(form: nil, editing_block: nil, selected_id: nil, return_prompt: nil)
    |> stream_blocks()
  end

  defp apply_action(socket, :new, params), do: open_form(socket, nil, params)

  defp apply_action(socket, :edit, %{"id" => id} = params) do
    case Prompts.get_editable_block(socket.assigns.current_scope, id) do
      nil ->
        socket
        |> put_flash(:error, not_found_flash())
        |> push_patch(to: ~p"/prompts/blocks")

      block ->
        open_form(socket, block, params)
    end
  end

  # `block` is nil for the new form.
  defp open_form(socket, block, params) do
    scope = socket.assigns.current_scope
    return_prompt = return_prompt(scope, params)

    socket
    |> assign(
      form: to_form(Prompts.change_block(block || %Block{})),
      editing_block: block,
      new_owner: "personal",
      selected_id: block && block.id,
      outlets: Prompts.list_outlets(scope),
      return_prompt: return_prompt
    )
    |> assign_preview()
    |> assign_tag_fields(
      :item,
      block,
      if(block, do: block.user_id, else: new_tag_owner(scope, return_prompt, "personal"))
    )
    |> stream_blocks()
  end

  # The owner a new block gets: its return prompt's owner (`Prompts.create_block/3`'s `for_prompt:`),
  # else the one for the Owner choice. Tags follow it: site tags only on a site block.
  defp new_tag_owner(_scope, %{user_id: owner}, _choice), do: owner

  defp new_tag_owner(scope, nil, choice), do: OwnerSelect.tag_owner(scope, Block, choice)

  defp put_new_owner(%{assigns: %{editing_block: nil, return_prompt: nil, new_owner: choice}} = socket, new)
       when new != choice,
       do: socket |> assign(new_owner: new) |> put_owner(:item, new_tag_owner(socket.assigns.current_scope, nil, new))

  defp put_new_owner(socket, _choice), do: socket

  # Visibility is a site-block control: a new block is the site's when its return prompt is, or
  # when a site manager leaves Owner at Site.
  defp site_row?(%Block{user_id: user_id}, _return_prompt, _scope, _choice), do: is_nil(user_id)
  defp site_row?(nil, %{user_id: user_id}, _scope, _choice), do: is_nil(user_id)

  defp site_row?(nil, nil, scope, choice), do: OwnerSelect.site_row?(nil, scope, Block, choice)

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, socket |> assign_filter(params) |> assign_tag_filter(params) |> stream_blocks()}
  end

  def handle_event("validate", %{"block" => params} = all, socket) do
    changeset =
      socket
      |> target_block()
      |> Prompts.change_block(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(form: to_form(changeset))
     |> put_new_owner(OwnerSelect.choice(all))
     |> put_tag_params(:item, all["tags"])}
  end

  def handle_event("save", %{"block" => attrs} = all, socket) do
    socket = put_tag_params(socket, :item, all["tags"])

    result =
      case socket.assigns.editing_block do
        nil ->
          opts = new_block_opts(socket, all)
          Prompts.create_block(socket.assigns.current_scope, attrs, [followups: held_followups(socket, opts)] ++ opts)

        block ->
          Prompts.update_block(socket.assigns.current_scope, block, attrs)
      end

    case result do
      {:ok, block} ->
        case save_tags(socket, :item, block) do
          {:ok, socket} ->
            {:noreply, after_save(socket, block, socket.assigns.return_prompt)}

          {:error, _what, socket} ->
            {:noreply,
             socket
             |> after_save(block, socket.assigns.return_prompt)
             |> clear_flash(:info)
             |> put_flash(:error, tags_failed_flash(block.name))}
        end

      {:held, hold} ->
        socket = flash_held(socket, hold)

        {:noreply,
         case {socket.assigns.editing_block, socket.assigns.return_prompt} do
           {%Block{} = block, _} -> push_patch(socket, to: ~p"/prompts/blocks/#{block.id}/edit")
           {nil, nil} -> push_patch(socket, to: ~p"/prompts/blocks")
           {nil, prompt} -> push_navigate(socket, to: ~p"/prompts/#{prompt.id}/edit")
         end}

      {:error, :hold_limit} ->
        {:noreply, flash_hold_limit(socket)}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(:error, save_failed_flash())}
    end
  end

  def handle_event("preview_options", %{"preview" => params}, socket), do: {:noreply, update_preview(socket, params)}

  def handle_event("preview_view", %{"view" => view}, socket), do: {:noreply, set_preview_view(socket, view)}

  # The form as typed, saved or not, so a template can be checked before it is saved.
  def handle_event("preview", _params, socket) do
    block = Ecto.Changeset.apply_changes(socket.assigns.form.source)
    {:noreply, run_preview(socket, Preview.block_prompt(socket.assigns.current_scope, block))}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Prompts.get_editable_block(socket.assigns.current_scope, id) do
      nil ->
        {:noreply, socket}

      block ->
        result = Prompts.delete_block(socket.assigns.current_scope, block)
        {:noreply, MythweaverWeb.HandOff.after_delete(socket, result, block.name, ~p"/prompts/blocks")}
    end
  end

  # Created from a prompt's "Create new block": the block is that prompt's owner's, so the prompt can
  # hold it even when it is shared to this user.
  # What an approved held create still does: its tags, and joining the prompt it was created from.
  defp held_followups(socket, opts) do
    add =
      case socket.assigns.return_prompt do
        nil -> []
        prompt -> [{Prompts, :add_block, [prompt, :row]}]
      end

    tag_followups(socket, :item, opts) ++ add
  end

  defp new_block_opts(%{assigns: %{return_prompt: nil}}, all), do: OwnerSelect.create_opts(OwnerSelect.choice(all))
  defp new_block_opts(%{assigns: %{return_prompt: prompt}}, _all), do: [for_prompt: prompt]

  defp after_save(socket, block, nil) do
    socket
    |> put_flash(:info, saved_flash(block.name))
    |> push_patch(to: ~p"/prompts/blocks/#{block.id}/edit")
  end

  # Edited from a prompt's block list: the membership already exists, so only go back there.
  defp after_save(%{assigns: %{editing_block: %Block{}}} = socket, block, prompt) do
    socket
    |> put_flash(:info, saved_flash(block.name))
    |> push_navigate(to: ~p"/prompts/#{prompt.id}/edit")
  end

  # Created from a prompt's "Create new block": join it to that prompt and go back there.
  defp after_save(socket, block, prompt) do
    case Prompts.add_block(socket.assigns.current_scope, prompt, block) do
      {:ok, _membership} ->
        socket
        |> put_flash(:info, created_and_added_flash(block.name, prompt.name))
        |> push_navigate(to: ~p"/prompts/#{prompt.id}/edit")

      {:error, :unauthorized} ->
        flash_unauthorized(socket)

      {:error, _reason} ->
        socket
        |> put_flash(:error, add_failed_flash(block.name, prompt.name))
        |> push_patch(to: ~p"/prompts/blocks/#{block.id}/edit")
    end
  end

  # `prompt_id` comes from the URL, so it is cast before the lookup (`Repo.get/2` raises on a
  # malformed UUID) and a miss is simply no return prompt.
  defp return_prompt(scope, %{"prompt_id" => id}) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Prompts.get_prompt(scope, uuid)
      :error -> nil
    end
  end

  defp return_prompt(_scope, _params), do: nil

  defp target_block(socket), do: socket.assigns.editing_block || %Block{}

  defp not_found_flash do
    gettext_comment("Flash when the prompt block in the address no longer exists or cannot be edited.")
    dpgettext("prompts", "status: flash, the prompt block to edit was not found", "Block not found")
  end

  defp saved_flash(block_name) do
    gettext_comment("Flash after a prompt block was saved.")
    dpgettext("prompts", "status: flash after a prompt block was saved", "%{block_name} saved", block_name: block_name)
  end

  defp tags_failed_flash(block_name) do
    gettext_comment("Flash when a prompt block was saved but writing its tags failed.")
    dgettext("prompts", "%{block_name} saved, but its tags did not", block_name: block_name)
  end

  defp save_failed_flash do
    gettext_comment("Flash when saving an editor form fails validation; the invalid fields are highlighted.")
    dgettext("prompts", "Could not save — see the highlighted fields")
  end

  defp created_and_added_flash(block_name, prompt_name) do
    gettext_comment("Flash after a block created from a prompt's editor was saved and added to that prompt.")

    dgettext("prompts", "%{block_name} created and added to %{prompt_name}",
      block_name: block_name,
      prompt_name: prompt_name
    )
  end

  defp add_failed_flash(block_name, prompt_name) do
    gettext_comment("Flash when a block created from a prompt's editor was saved but could not join that prompt.")

    dgettext("prompts", "%{block_name} saved, but could not be added to %{prompt_name}",
      block_name: block_name,
      prompt_name: prompt_name
    )
  end

  defp delete_confirm(block_name) do
    gettext_comment("Confirm dialog before deleting a prompt block.")

    dpgettext("prompts", "button: confirm dialog, delete a prompt block", "Delete %{block_name}?",
      block_name: block_name
    )
  end

  defp role_badge(:system), do: dpgettext("prompts", "badge: prompt block role, system message", "system")
  defp role_badge(:user), do: dpgettext("prompts", "badge: prompt block role, user message", "user")
  defp role_badge(:assistant), do: dpgettext("prompts", "badge: prompt block role, assistant message", "assistant")

  defp item_fields_text(fields) do
    gettext_comment(
      "Template reference: the fields of each item in a list value. The placeholder is a comma-separated list like \"name (string), id (string)\" of untranslated field names and types."
    )

    dpgettext(
      "prompts",
      "field label: fields of each item in a template reference list value",
      "Each item: %{field_list}.",
      field_list: Enum.map_join(fields, ", ", fn {name, type} -> "#{name} (#{type})" end)
    )
  end

  defp outlet_reference_text(outlet_name) do
    dgettext("prompts", "Lore that activated into the %{outlet_name} outlet, rendered.", outlet_name: outlet_name)
  end

  defp stream_blocks(socket) do
    # `block_detail/1` is the row's meta line (content preview, or "Chat history"), so what the row
    # shows is searchable too.
    blocks = filter_tagged(socket, Prompts.list_editable_blocks(socket.assigns.current_scope), :prompt_block)

    stream_search(socket, :blocks, blocks, fn block ->
      [block.name, block.description, block.content, block_detail(block)]
    end)
  end

  ## View helpers

  defp template_kind?(form), do: to_string(form[:kind].value) != "chat_history"

  defp block_detail(%Block{kind: :chat_history}),
    do: dpgettext("prompts", "status: list row detail of a chat history prompt block", "Chat history")

  defp block_detail(%Block{content: content}), do: preview_text(content)

  @impl true
  def render(assigns) do
    ~H"""
    <%!--
      `lower-bound="none"`: rules here may reach inside `<.input>`'s own template,
      which is a nested-component root carrying `phx-r` that the default exclusive bound cuts off.
    --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      /* The editor slot's root. `pane_layout`'s `<section>` carries no marker from this block, so
         without it `<.form>` (which carries none either) would sit outside this scope. */
      div.prompt-block-editor-body:scope {
        display: contents;
      }

      .prompt-block-return-hint {
        margin: 0;
        color: var(--muted-foreground);
      }

      .prompt-block-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .prompt-block-form label {
        display: block;
      }

      .prompt-block-reference dl {
        display: grid;
        gap: var(--size-1);
        margin: 0;
      }

      .prompt-block-reference dt,
      .prompt-block-reference dd {
        margin: 0;
      }

      .prompt-block-reference dd {
        color: var(--muted-foreground);
        font-size: 0.85rem;
      }

      .prompt-block-reference-type {
        margin-inline-start: var(--size-2);
        color: var(--muted-foreground);
        font-family: var(--font-monospace-code, ui-monospace, monospace);
        font-size: 0.8rem;
      }
    </style>
    <Layouts.app flash={@flash} current_scope={@current_scope} search={:prompts}>
      <.pane_layout>
        <:list
          id="prompt-blocks-nav"
          label={dpgettext("prompts", "aria label: list of prompt blocks", "Prompt blocks")}
        >
          <.pane_header title={
            dpgettext("prompts", "heading: list of prompt blocks", "Prompt blocks")
          }>
            <:switch id="pane-switch-prompts" navigate={~p"/prompts"}>
              <.lucide name="messages-square" /> {dpgettext(
                "prompts",
                "link: switch to the prompts list",
                "Prompts"
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
            <.button variant="primary" patch={~p"/prompts/blocks/new"} id="new-prompt-block">
              <.lucide name="plus" /> {dpgettext(
                "prompts",
                "button: create a prompt block",
                "New block"
              )}
            </.button>
          </.pane_actions>
          <.pane_search
            id="prompt-block-filter"
            form={@filter_form}
            placeholder={
              dpgettext(
                "prompts",
                "placeholder: search prompt blocks",
                "Name, description, or content"
              )
            }
          >
            <.tag_filter
              id="prompt-block-filter-tags"
              values={@tag_filter}
              vocabulary={@tag_vocabulary}
              errors={@tag_filter_errors}
              invalid={@tag_filter_invalid}
            />
          </.pane_search>
          <.pane_items
            :let={block}
            id="prompt-blocks"
            rows={@streams.blocks}
            empty?={@blocks_empty?}
            empty={
              if @query == "" and @tag_filter == [],
                do:
                  dpgettext("prompts", "empty state: no prompt blocks exist", "No prompt blocks yet"),
                else:
                  dpgettext(
                    "prompts",
                    "empty state: no prompt blocks match the search",
                    "No blocks match this search"
                  )
            }
            selected_id={@selected_id}
            patch={fn block -> ~p"/prompts/blocks/#{block.id}/edit" end}
          >
            <span class="pane-item-name">{block.name}</span>
            <span class="pane-item-meta">{block_detail(block)}</span>
            <span class="pane-item-badges">
              <.badge>{Block.kind_label(block)}</.badge>
              <.badge>{role_badge(block.role)}</.badge>
              <.badge :if={!block.enabled}>
                {dpgettext("prompts", "badge: prompt block is turned off", "disabled")}
              </.badge>
            </span>
          </.pane_items>
        </:list>
        <:editor id="prompt-block-editor">
          <.pane_placeholder :if={@live_action == :index} id="prompt-block-placeholder">
            {dgettext("prompts", "Select a block, or create a new one.")}
          </.pane_placeholder>
          <div :if={@live_action != :index} class="prompt-block-editor-body">
            <.panel_header sticky>
              {if @editing_block,
                do: @editing_block.name,
                else: dpgettext("prompts", "heading: form for a new prompt block", "New block")}
              <:actions :if={@editing_block}>
                <.live_component
                  :if={Ownership.deletable?(@current_scope, @editing_block)}
                  module={MythweaverWeb.HandOff}
                  id="prompt-block-handoff"
                  thing="prompt-block"
                  current_scope={@current_scope}
                  item={@editing_block}
                  delete={&Prompts.delete_block/3}
                  index={~p"/prompts/blocks"}
                  delete_id="delete-prompt-block"
                  confirm={delete_confirm(@editing_block.name)}
                />
              </:actions>
            </.panel_header>
            <.live_component
              :if={@editing_block}
              module={MythweaverWeb.Lineage}
              id="prompt-block-lineage-line"
              thing="prompt-block"
              current_scope={@current_scope}
              item={@editing_block}
            />

            <.pane_section>
              <.changed_elsewhere
                :if={@changed_elsewhere?}
                id="prompt-block-changed-elsewhere"
                patch={@live_sync_path}
              />
              <.form
                for={@form}
                id="prompt-block-form"
                class="prompt-block-form"
                phx-hook="UnsavedChanges"
                data-saved={is_nil(@form.action)}
                phx-change="validate"
                phx-submit="save"
              >
                <.owner_select
                  :if={is_nil(@editing_block) and is_nil(@return_prompt)}
                  id="prompt-block-form-owner"
                  scope={@current_scope}
                  schema={Block}
                  value={@new_owner}
                />
                <.input
                  field={@form[:name]}
                  type="text"
                  label={dpgettext("prompts", "field label: name of a prompt block", "Name")}
                  id="prompt-block-form-name"
                  required
                />
                <.editor
                  field={@form[:description]}
                  label={
                    dpgettext("prompts", "field label: description of a prompt block", "Description")
                  }
                  rows={2}
                  id="prompt-block-form-description"
                  language="markdown"
                  spellcheck
                />
                <.input
                  field={@form[:role]}
                  type="select"
                  label={
                    dpgettext("prompts", "field label: chat role a prompt block is sent as", "Role")
                  }
                  options={MythweaverWeb.EnumLabels.values(Block, :role)}
                  id="prompt-block-form-role"
                />
                <.input
                  field={@form[:kind]}
                  type="select"
                  label={dpgettext("prompts", "field label: kind of prompt block", "Kind")}
                  options={[
                    {dpgettext(
                       "prompts",
                       "option: kind of prompt block, a Liquid template",
                       "Template"
                     ), :template},
                    {dpgettext(
                       "prompts",
                       "option: kind of prompt block, the chat transcript marker",
                       "Chat history"
                     ), :chat_history}
                  ]}
                  id="prompt-block-form-kind"
                />
                <.input
                  :if={not template_kind?(@form)}
                  field={@form[:speaker_roles]}
                  type="select"
                  label={
                    dpgettext(
                      "prompts",
                      "field label: roles a chat history block gives each turn",
                      "Speaker roles"
                    )
                  }
                  options={[
                    {dgettext(
                       "prompts",
                       "Responder: its own lines as the assistant, everyone else's named"
                     ), :responder},
                    {dgettext(
                       "prompts",
                       "Fixed: characters as the assistant, the player as the user, every line named"
                     ), :fixed}
                  ]}
                  id="prompt-block-form-speaker_roles"
                />
                <.editor
                  :if={template_kind?(@form)}
                  field={@form[:content]}
                  label={
                    dpgettext(
                      "prompts",
                      "field label: Liquid template text of a prompt block",
                      "Template"
                    )
                  }
                  rows={10}
                  max_rows={40}
                  id="prompt-block-form-content"
                  language="liquid"
                  spellcheck
                  completions={@template_completions}
                />
                <.input
                  :if={template_kind?(@form)}
                  type="select"
                  field={@form[:role_tag]}
                  id="prompt-block-form-role_tag"
                  label={
                    dpgettext(
                      "prompts",
                      "field label: which character card prompt replaces this block",
                      "Character override"
                    )
                  }
                  options={[
                    {dpgettext(
                       "prompts",
                       "option: no character card prompt replaces this block",
                       "None"
                     ), ""},
                    {dgettext("prompts", "Main prompt (a card's system prompt replaces it)"), "main"},
                    {dgettext("prompts", "Post-history instructions (a card's replace them)"),
                     "post_history"}
                  ]}
                />
                <.input
                  :if={template_kind?(@form)}
                  type="checkbox"
                  field={@form[:forbid_overrides]}
                  id="prompt-block-form-forbid_overrides"
                  label={
                    dpgettext(
                      "prompts",
                      "toggle: keep this block's text even when a character card has its own prompt",
                      "Ignore character overrides"
                    )
                  }
                />
                <details
                  :if={template_kind?(@form)}
                  id="prompt-block-template-reference"
                  class="prompt-block-reference"
                >
                  <summary>
                    {dpgettext(
                      "prompts",
                      "heading: list of values a block template can read",
                      "Template reference"
                    )}
                  </summary>
                  <dl>
                    <div :for={entry <- @anchor_catalog}>
                      <dt>
                        <code>{"{{ #{entry.path} }}"}</code>
                        <span class="prompt-block-reference-type">{entry.type}</span>
                      </dt>
                      <dd>
                        {entry.description}
                        <span :if={entry[:fields]}>
                          {item_fields_text(entry[:fields])}
                        </span>
                      </dd>
                    </div>
                    <div :for={outlet <- @outlets} id={"prompt-block-reference-outlet-#{outlet.key}"}>
                      <dt>
                        <code>{"{{ outlets.#{outlet.key} }}"}</code>
                        <span class="prompt-block-reference-type">string | nil</span>
                      </dt>
                      <dd>{outlet_reference_text(outlet.name)}</dd>
                    </div>
                    <div>
                      <dt>
                        <code>{"{{ vars.name }} · {{ globals.name }}"}</code>
                        <span class="prompt-block-reference-type">
                          string | int | float | bool | array | map | nil
                        </span>
                      </dt>
                      <dd>
                        {dgettext(
                          "prompts",
                          "Chat and global variables: any JSON value, nil when unset. Write them with %{setvar_tag} or %{setglobalvar_tag}.",
                          setvar_tag: "{% setvar name = value %}",
                          setglobalvar_tag: "{% setglobalvar name = value %}"
                        )}
                      </dd>
                    </div>
                  </dl>
                </details>
                <.input
                  field={@form[:enabled]}
                  type="checkbox"
                  label={
                    dpgettext("prompts", "toggle: prompt block is included in prompts", "Enabled")
                  }
                  id="prompt-block-form-enabled"
                />
                <.input
                  :if={site_row?(@editing_block, @return_prompt, @current_scope, @new_owner)}
                  field={@form[:site_visibility]}
                  type="select"
                  label={
                    dpgettext(
                      "prompts",
                      "field label: how much of a site prompt block users see",
                      "Visible to users"
                    )
                  }
                  id="prompt-block-form-site_visibility"
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
                      "What users who are not admins see of this block. Only names: never its content, in any prompt, in the prompt inspector, the assistant, scripts or exports; the model still gets it. Admins always see everything."
                    )}
                  </:hint>
                </.input>
                <.tag_fields
                  id="prompt-block-form-tags"
                  prefix="tags"
                  field={@tag_fields.item}
                  vocabulary={@tag_vocabulary}
                />
                <.form_actions>
                  <.button :if={@return_prompt} navigate={~p"/prompts/#{@return_prompt.id}/edit"}>
                    {dpgettext("prompts", "button: cancel editing the open form", "Cancel")}
                  </.button>
                  <.button
                    :if={!@return_prompt}
                    patch={
                      if @editing_block,
                        do: ~p"/prompts/blocks/#{@editing_block.id}/edit",
                        else: ~p"/prompts/blocks"
                    }
                  >
                    {dpgettext("prompts", "button: cancel editing the open form", "Cancel")}
                  </.button>
                  <.button type="submit" variant="primary">
                    {dpgettext("prompts", "button: save the open form", "Save")}
                  </.button>
                </.form_actions>
              </.form>
            </.pane_section>

            <.pane_section>
              <.section_header>
                {dpgettext("prompts", "heading: rendered preview of the block or prompt", "Preview")}
              </.section_header>
              <.prompt_preview
                id="prompt-block-preview"
                chats={@preview_chats}
                chat={@preview_chat}
                form={@preview_form}
                result={@preview_result}
                view={@preview_view}
              />
            </.pane_section>
            <.live_component
              :if={@editing_block}
              module={MythweaverWeb.SharePanel}
              id="prompt-block-share"
              current_scope={@current_scope}
              item={@editing_block}
            />
          </div>
        </:editor>
      </.pane_layout>
    </Layouts.app>
    """
  end
end
