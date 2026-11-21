defmodule MythweaverWeb.TagLive do
  @moduledoc """
  Tag manager: the editable tags on the left (the site's for a content manager, plus the viewer's
  own), the selected tag's form on the right. `:index` selects nothing: the editor pane shows a
  placeholder until a tag is picked.

  The form edits a tag's text, its sibling ("Displays as", at most one) and its parents, all named
  by text in the tag's own domain (`Mythweaver.Tags.create_tag/3`, `update_tag/3`). Below it, the
  viewer's graph lists the tags shown as this one and the tags whose parent it is, and the items
  carrying the tag itself (`Mythweaver.Tags.tagged_items/2`) link to their editors.

  Select mode (`MythweaverWeb.Bulk`) deletes tags, or sets their sibling and adds or removes
  parents on each (`Mythweaver.Tags.edit_tag/3`).
  """
  use MythweaverWeb, :live_view

  import MythweaverWeb.BulkComponents
  import MythweaverWeb.Pane

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Tags
  alias Mythweaver.Tags.Graph
  alias Mythweaver.Tags.Tag
  alias MythweaverWeb.Bulk
  alias MythweaverWeb.Bulk.Field
  alias MythweaverWeb.Bulk.Spec
  alias MythweaverWeb.LiveSync

  on_mount {MythweaverWeb.ContentAccess, :tags}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: dpgettext("tags", "page title: tag manager", "Tags"),
       form: nil,
       editing_tag: nil,
       selected_id: nil,
       new_owner: "personal",
       vocabulary: [],
       aliases: [],
       children: [],
       tagged_count: 0
     )
     |> stream_configure(:tags, dom_id: &"tags-#{&1.id}")
     |> stream_configure(:tagged_items, dom_id: &"tagged-#{&1.id}")
     |> stream(:tagged_items, [])
     |> assign_filter()
     |> stream_tags()
     |> Bulk.attach([bulk_spec()])
     |> LiveSync.attach_editor([:tags], &sync/2)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(
      form: nil,
      editing_tag: nil,
      selected_id: nil,
      new_owner: "personal",
      aliases: [],
      children: [],
      tagged_count: 0
    )
    |> stream(:tagged_items, [], reset: true)
    |> stream_tags()
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(
      form: to_form(Tags.change_tag(%Tag{parents: []})),
      editing_tag: nil,
      selected_id: nil,
      new_owner: "personal",
      aliases: [],
      children: []
    )
    |> assign_vocabulary()
    |> stream_tags()
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    scope = socket.assigns.current_scope

    case Tags.get_editable_tag(scope, id) do
      nil ->
        socket
        |> put_flash(:error, not_found_message())
        |> push_patch(to: ~p"/tags")

      tag ->
        socket
        |> assign(form: to_form(Tags.change_tag(tag)), editing_tag: tag, selected_id: tag.id)
        |> load_tag_details(tag)
        |> assign_vocabulary()
        |> stream_tags()
    end
  end

  # The viewer's graph around `tag` and the items carrying it.
  defp load_tag_details(socket, tag) do
    scope = socket.assigns.current_scope
    viewer = Tags.graph(scope.user.id)
    text = Tag.text(tag)
    tagged = scope |> Tags.tagged_items(tag) |> Enum.map(&tagged_row/1)

    socket
    |> assign(
      aliases: Tags.sort(Graph.aliases(viewer, text)),
      children: Tags.sort(Graph.children(viewer, text)),
      tagged_count: length(tagged)
    )
    |> stream(:tagged_items, tagged, reset: true)
  end

  defp sync(socket, _kinds) do
    scope = socket.assigns.current_scope
    socket = stream_tags(socket)
    socket = if socket.assigns.form, do: assign_vocabulary(socket), else: socket

    socket =
      LiveSync.sync_open(socket, :editing_tag,
        fetch: &Tags.get_editable_tag(scope, &1),
        clean?: LiveSync.clean?(socket.assigns.form),
        reload: &assign(&1, form: to_form(Tags.change_tag(&2)), editing_tag: &2),
        gone: ~p"/tags",
        gone_message:
          (
            gettext_comment("Flash shown when the tag open in the editor was deleted or moved by someone else.")
            dgettext("tags", "The tag was deleted or moved elsewhere.")
          )
      )

    case socket.assigns.editing_tag do
      nil -> socket
      tag -> load_tag_details(socket, tag)
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, socket |> assign_filter(params) |> stream_tags()}
  end

  def handle_event("validate", %{"tag" => params} = all, socket) do
    socket = assign(socket, new_owner: owner_choice(all))

    changeset =
      socket
      |> target_tag()
      |> Tags.change_tag(attrs(params))
      |> Map.put(:action, :validate)

    {:noreply, socket |> assign(form: to_form(changeset)) |> assign_vocabulary()}
  end

  def handle_event("save", %{"tag" => params} = all, socket) do
    scope = socket.assigns.current_scope
    socket = assign(socket, new_owner: owner_choice(all))

    result =
      case socket.assigns.editing_tag do
        nil -> Tags.create_tag(scope, attrs(params), site: socket.assigns.new_owner == "site")
        tag -> Tags.update_tag(scope, tag, attrs(params))
      end

    case result do
      {:ok, tag} ->
        {:noreply,
         socket
         |> put_flash(:info, saved_message(tag))
         |> push_patch(to: ~p"/tags/#{tag.id}/edit")}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(:error, save_failed_message())}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Tags.get_editable_tag(scope, id) do
      %Tag{} = tag ->
        case Tags.delete_tag(scope, tag) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, deleted_message(tag))
             |> push_patch(to: ~p"/tags")}

          {:error, :unauthorized} ->
            {:noreply, flash_unauthorized(socket)}
        end

      nil ->
        {:noreply, socket}
    end
  end

  defp not_found_message do
    gettext_comment("Error flash: the tag in the address does not exist or the viewer cannot edit it.")
    dpgettext("tags", "status: flash when the tag in the address does not exist", "Tag not found")
  end

  defp saved_message(tag) do
    gettext_comment("Info flash after a tag is saved; %{tag_name} is the tag's text, e.g. series:metroid.")
    dpgettext("tags", "status: flash after saving a tag", "%{tag_name} saved", tag_name: Tag.text(tag))
  end

  defp save_failed_message do
    gettext_comment("Error flash when the tag form has invalid fields.")
    dgettext("tags", "Could not save — see the highlighted fields")
  end

  defp deleted_message(tag) do
    gettext_comment("Info flash after a tag is deleted; %{tag_name} is the tag's text, e.g. series:metroid.")
    dpgettext("tags", "status: flash after deleting a tag", "%{tag_name} deleted", tag_name: Tag.text(tag))
  end

  # The ideal input posts a list (its sentinel, then a chip or a pending pick); the last non-blank
  # value is the choice, none means no sibling.
  defp attrs(params) do
    params
    |> Map.update("ideal_text", nil, fn values ->
      values |> List.wrap() |> Enum.reject(&(&1 == "")) |> List.last()
    end)
    |> Map.update("parent_texts", [], fn values -> values |> List.wrap() |> Enum.reject(&(&1 == "")) end)
  end

  defp target_tag(%{assigns: %{editing_tag: nil}} = socket), do: %Tag{user_id: new_owner_id(socket), parents: []}
  defp target_tag(socket), do: socket.assigns.editing_tag

  # The domain a new tag lands in: the creator's own unless a content manager chooses Site.
  defp new_owner_id(%{assigns: %{current_scope: scope, new_owner: choice}}) do
    if !(Scope.can?(scope, "site.content.manage") and choice == "site"), do: scope.user.id
  end

  defp owner_choice(%{"owner" => "site"}), do: "site"
  defp owner_choice(_params), do: "personal"

  # Suggestions come from the tag's own domain: the site's tags for a site tag, the site's and the
  # owner's for a personal one.
  defp assign_vocabulary(socket) do
    owner =
      case socket.assigns.editing_tag do
        nil -> new_owner_id(socket)
        tag -> tag.user_id
      end

    assign(socket, vocabulary: Tags.vocabulary(owner, Tags.graph(owner)))
  end

  defp stream_tags(socket) do
    stream_search(
      socket,
      :tags,
      Tags.list_editable_tags(socket.assigns.current_scope),
      &[Tag.text(&1), &1.ideal && Tag.text(&1.ideal)]
    )
  end

  defp bulk_spec do
    %Spec{
      name: :tags,
      count_label:
        &dpngettext("tags", "count phrase: tags affected by a bulk action", "%{tag_count} tag", "%{tag_count} tags", &1,
          tag_count: Mythweaver.Format.number(&1)
        ),
      ids: & &1.assigns.tags_ids,
      get: &Tags.get_editable_tag/2,
      update: &Tags.edit_tag/3,
      delete: &Tags.delete_tag/2,
      title: &Tag.text/1,
      refresh: &stream_tags/1,
      open_id: & &1.assigns.selected_id,
      index_path: ~p"/tags",
      edit_path: &~p"/tags/#{&1}/edit",
      fields: [
        %Field{
          key: :ideal_text,
          label: dpgettext("tags", "field label: bulk edit, sibling tag the selected tags display as", "Displays as"),
          type: :tags,
          max: 1,
          options: &vocabulary/1
        },
        %Field{
          key: :add_parents,
          label: dpgettext("tags", "field label: bulk edit, parent tags to add to the selected tags", "Add parents"),
          type: :tags,
          options: &vocabulary/1
        },
        %Field{
          key: :remove_parents,
          label:
            dpgettext("tags", "field label: bulk edit, parent tags to remove from the selected tags", "Remove parents"),
          type: :tags,
          options: &vocabulary/1
        }
      ]
    }
  end

  defp vocabulary(scope), do: Tags.vocabulary(scope.user.id, Tags.graph(scope.user.id))

  defp kind_label(:character), do: dpgettext("tags", "column header: kind of a tagged item, a character", "Character")
  defp kind_label(:chat), do: dpgettext("tags", "column header: kind of a tagged item, a chat", "Chat")

  defp kind_label(:lore_entry),
    do: dpgettext("tags", "column header: kind of a tagged item, a lore entry", "Lore entry")

  defp kind_label(:lore_book), do: dpgettext("tags", "column header: kind of a tagged item, a lore book", "Lore book")
  defp kind_label(:prompt), do: dpgettext("tags", "column header: kind of a tagged item, a prompt", "Prompt")

  defp kind_label(:prompt_block),
    do: dpgettext("tags", "column header: kind of a tagged item, a prompt block", "Prompt block")

  defp kind_label(:script), do: dpgettext("tags", "column header: kind of a tagged item, a script", "Script")
  defp kind_label(:ai_model), do: dpgettext("tags", "column header: kind of a tagged item, an AI model", "AI model")

  defp tagged_row({kind, item}) do
    %{
      id: item.id,
      kind: kind_label(kind),
      name: item.name || dpgettext("tags", "empty state: a tagged item that has no name", "Untitled"),
      path: item_path(kind, item.id)
    }
  end

  defp item_path(:character, id), do: ~p"/characters/#{id}/edit"
  defp item_path(:chat, id), do: ~p"/chats/#{id}"
  defp item_path(:lore_entry, id), do: ~p"/lore/entries/#{id}/edit"
  defp item_path(:lore_book, id), do: ~p"/lore/#{id}/edit"
  defp item_path(:prompt, id), do: ~p"/prompts/#{id}/edit"
  defp item_path(:prompt_block, id), do: ~p"/prompts/blocks/#{id}/edit"
  defp item_path(:script, id), do: ~p"/scripts/#{id}/edit"
  defp item_path(:ai_model, id), do: ~p"/ai/models/#{id}/edit"

  defp field_errors(form, field), do: Enum.map(form[field].errors, &translate_error/1)

  defp ideal_values(form) do
    case Ecto.Changeset.get_field(form.source, :ideal_text) do
      nil -> []
      text -> [text]
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      /* The editor slot's root. `pane_layout`'s `<section>` carries no marker from this block, so
         without it `<.form>` (which carries none either) would sit outside this scope. */
      div.tag-editor-body:scope {
        display: contents;
      }

      .tag-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .tag-row {
        display: flex;
        align-items: center;
        gap: var(--size-2);
        min-width: 0;
      }

      .tag-row-count {
        margin-left: auto;
        color: var(--muted-foreground);
      }

      .tag-related {
        display: flex;
        flex-wrap: wrap;
        gap: var(--size-1);
      }

      .tag-related-none {
        color: var(--muted-foreground);
      }

      .tagged-items {
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
        margin: 0;
        padding: 0;
        list-style: none;
      }

      .tagged-item {
        display: flex;
        align-items: baseline;
        gap: var(--size-2);
        min-width: 0;
      }

      .tagged-item-kind {
        flex: none;
        min-inline-size: 7rem;
        color: var(--muted-foreground);
        font-size: var(--font-size-0);
      }

      .tagged-item-link {
        min-width: 0;
        overflow-wrap: anywhere;
      }
    </style>

    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.pane_layout>
        <:list
          id="tags-nav"
          label={dpgettext("tags", "aria label: list of tags in the tag manager", "Tags")}
        >
          <.pane_header title={dpgettext("tags", "heading: tag manager list", "Tags")} />
          <.pane_actions>
            <.button variant="primary" patch={~p"/tags/new"} id="new-tag">
              <.lucide name="plus" /> {dpgettext("tags", "button: create a new tag", "New tag")}
            </.button>
            <.bulk_toggle bulk={@bulk} id="tags-bulk-toggle" />
          </.pane_actions>
          <.bulk_bar bulk={@bulk} id="tags-bulk" />
          <.pane_search
            id="tag-filter"
            form={@filter_form}
            placeholder={
              dpgettext("tags", "placeholder: search the tag list by tag text", "Tag text")
            }
          />
          <.pane_items
            :let={tag}
            bulk={@bulk}
            bulk_list="tags"
            id="tags"
            rows={@streams.tags}
            empty?={@tags_empty?}
            empty={
              if @query == "",
                do: dpgettext("tags", "empty state: tag manager with no tags", "No tags yet"),
                else:
                  dpgettext(
                    "tags",
                    "empty state: tag search with no results",
                    "No tags match this search"
                  )
            }
            selected_id={@selected_id}
            patch={fn tag -> ~p"/tags/#{tag.id}/edit" end}
          >
            <span class="tag-row">
              <.tag_chip text={Tag.text(tag)} ideal={tag.ideal && Tag.text(tag.ideal)} />
              <.badge :if={is_nil(tag.user_id)}>
                {dpgettext("tags", "badge: a site-wide tag", "Site")}
              </.badge>
              <span
                class="tag-row-count"
                title={
                  dpgettext(
                    "tags",
                    "tooltip: number of items carrying this tag",
                    "Items with this tag"
                  )
                }
              >
                {Mythweaver.Format.number(tag.usage_count)}
              </span>
            </span>
          </.pane_items>
        </:list>
        <:editor id="tag-editor">
          <.pane_placeholder :if={@live_action == :index} id="tag-placeholder">
            {dgettext("tags", "Select a tag, or create a new one.")}
          </.pane_placeholder>
          <div :if={@live_action != :index} class="tag-editor-body">
            <.panel_header sticky>
              {if @editing_tag,
                do: Tag.text(@editing_tag),
                else: dpgettext("tags", "heading: tag form for a tag not yet created", "New tag")}
              <:actions :if={@editing_tag}>
                <.pane_delete
                  id="tag-delete"
                  phx-click="delete"
                  phx-value-id={@editing_tag.id}
                  confirm={delete_confirm()}
                >
                  {dpgettext("tags", "button: delete the open tag", "Delete")}
                </.pane_delete>
              </:actions>
            </.panel_header>

            <.pane_section>
              <.changed_elsewhere
                :if={@changed_elsewhere?}
                id="tag-changed-elsewhere"
                patch={@live_sync_path}
              />
              <.form
                for={@form}
                id="tag-form"
                class="tag-form"
                phx-hook="UnsavedChanges"
                data-saved={is_nil(@form.action)}
                phx-change="validate"
                phx-submit="save"
              >
                <.input
                  :if={is_nil(@editing_tag) and Scope.can?(@current_scope, "site.content.manage")}
                  name="owner"
                  value={@new_owner}
                  type="select"
                  label={dpgettext("tags", "field label: who owns a new tag", "Owner")}
                  id="tag-form-owner"
                  options={[
                    {dpgettext("tags", "option: tag owner, the viewer alone", "Personal (only me)"),
                     "personal"},
                    {dpgettext("tags", "option: tag owner, the whole site", "Site (every user)"),
                     "site"}
                  ]}
                >
                  <:hint>
                    {dgettext(
                      "tags",
                      "A personal tag is yours alone: no other user, admin or not, sees it or its rules. Site tags, siblings and parents are seen by every user, and only admins edit them."
                    )}
                  </:hint>
                </.input>
                <.input
                  field={@form[:text]}
                  type="text"
                  id="tag-form-text"
                  label={dpgettext("tags", "field label: the text of a tag", "Tag")}
                  required
                >
                  <:hint>{tag_format_hint()}</:hint>
                </.input>
                <.tag_input
                  id="tag-form-ideal_text"
                  name="tag[ideal_text][]"
                  max={1}
                  label={
                    dpgettext("tags", "field label: sibling tag this tag displays as", "Displays as")
                  }
                  values={ideal_values(@form)}
                  vocabulary={@vocabulary}
                  errors={field_errors(@form, :ideal_text)}
                >
                  <:hint>
                    {dgettext("tags", "A sibling: wherever this tag appears, show that one instead.")}
                  </:hint>
                </.tag_input>
                <.tag_input
                  id="tag-form-parent_texts"
                  name="tag[parent_texts][]"
                  label={dpgettext("tags", "field label: parent tags of a tag", "Parents")}
                  values={Ecto.Changeset.get_field(@form.source, :parent_texts) || []}
                  vocabulary={@vocabulary}
                  errors={field_errors(@form, :parent_texts)}
                >
                  <:hint>
                    {dgettext("tags", "Every item with this tag also counts as having these.")}
                  </:hint>
                </.tag_input>
                <.form_actions>
                  <.button patch={
                    if @editing_tag, do: ~p"/tags/#{@editing_tag.id}/edit", else: ~p"/tags"
                  }>
                    {dpgettext("tags", "button: discard edits to the tag form", "Cancel")}
                  </.button>
                  <.button type="submit" variant="primary">
                    {dpgettext("tags", "button: save the tag form", "Save")}
                  </.button>
                </.form_actions>
              </.form>
            </.pane_section>

            <.pane_section :if={@editing_tag} id="tag-aliases">
              <.section_header>
                {dpgettext("tags", "heading: tags that display as the open tag", "Shown as this tag")}
              </.section_header>
              <div class="tag-related">
                <.tag_chip :for={text <- @aliases} text={text} />
                <span :if={@aliases == []} class="tag-related-none">
                  {dpgettext("tags", "empty state: no tags display as the open tag", "None")}
                </span>
              </div>
            </.pane_section>

            <.pane_section :if={@editing_tag} id="tag-children">
              <.section_header>
                {dpgettext("tags", "heading: tags whose parent is the open tag", "Children")}
              </.section_header>
              <div class="tag-related">
                <.tag_chip :for={text <- @children} text={text} />
                <span :if={@children == []} class="tag-related-none">
                  {dpgettext("tags", "empty state: the open tag has no child tags", "None")}
                </span>
              </div>
            </.pane_section>

            <.pane_section :if={@editing_tag} id="tag-items">
              <.section_header>
                {dgettext("tags", "Items with this tag (%{tagged_item_count})",
                  tagged_item_count: Mythweaver.Format.number(@tagged_count)
                )}
              </.section_header>
              <ul id="tagged-items" class="tagged-items" phx-update="stream">
                <li :for={{id, row} <- @streams.tagged_items} id={id} class="tagged-item">
                  <span class="tagged-item-kind">{row.kind}</span>
                  <.link navigate={row.path} class="tagged-item-link">{row.name}</.link>
                </li>
              </ul>
              <span :if={@tagged_count == 0} class="tag-related-none">
                {dpgettext("tags", "empty state: no items carry the open tag", "None")}
              </span>
            </.pane_section>
          </div>
        </:editor>
      </.pane_layout>
    </Layouts.app>
    """
  end

  defp delete_confirm do
    gettext_comment("Confirm dialog before deleting the open tag in the tag manager.")
    dgettext("tags", "Delete this tag? It is removed from every item and filter.")
  end

  defp tag_format_hint do
    gettext_comment(
      "Hint under the tag text field. %{tag_format} is the literal pattern \"namespace:name\" and %{example_tag} a literal example tag; neither is translated."
    )

    dgettext("tags", "%{tag_format}, e.g. %{example_tag}; stored lowercase",
      tag_format: "namespace:name",
      example_tag: "series:metroid"
    )
  end
end
