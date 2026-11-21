defmodule MythweaverWeb.ModerationLookupLive do
  @moduledoc """
  The moderation panel's lookup (`/moderation/lookup`): a link, an id, an `@handle` or an email
  (`Mythweaver.Moderation.Lookup.resolve/2`) opens an account's record or a read-only view of the row
  (`/moderation/lookup/:type/:id`, `Lookup.fetch/4`; each look is written to the moderation log). The
  view's only actions are deleting it (`Lookup.delete/3`, sudo mode), deleting one message of a chat,
  taking a catalog listing down (`Mythweaver.Catalog.takedown/3`) and opening the owner's record to
  warn or suspend them. There is no list of anything here.

  Reloads on every `Mythweaver.Moderation` change; a row that is gone leaves for the lookup form.
  """
  use MythweaverWeb, :live_view

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Attachments
  alias Mythweaver.Catalog
  alias Mythweaver.Format
  alias Mythweaver.Messages.Message
  alias Mythweaver.Moderation
  alias Mythweaver.Moderation.Lookup
  alias Mythweaver.Moderation.Reports
  alias Mythweaver.Sharing.Items
  alias MythweaverWeb.ItemFields
  alias MythweaverWeb.ModerationNav

  on_mount {MythweaverWeb.UserAuth, {:require_any_permission, Moderation.record_keys()}}
  on_mount MythweaverWeb.Sudo

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Moderation.subscribe()

    {:ok,
     socket
     |> assign(
       page_title: lookup_title(),
       lookup_form: to_form(%{"q" => ""}, as: :lookup),
       takedown_form: takedown_form(),
       subject: nil,
       view: nil,
       messages_empty?: true
     )
     |> stream_configure(:messages, dom_id: &"lookup-message-#{&1.id}")
     |> stream(:messages, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(page_title: lookup_title(), subject: nil, view: nil, messages_empty?: true)
    |> stream(:messages, [], reset: true)
  end

  defp apply_action(socket, :show, %{"type" => type_name, "id" => id}) do
    case Lookup.parse_type(type_name) do
      nil -> leave(socket, not_found_flash())
      :user -> push_navigate(socket, to: Lookup.path({:user, id}))
      type -> if connected?(socket), do: load(socket, type, id, []), else: socket
    end
  end

  defp load(socket, type, id, opts) do
    case Lookup.fetch(socket.assigns.current_scope, type, id, opts) do
      {:ok, view} ->
        messages = Map.get(view, :messages, [])

        socket
        |> assign(
          page_title: view_title(type, view),
          subject: {type, id},
          view: view,
          takedown_form: takedown_form(),
          messages_empty?: messages == []
        )
        |> stream(:messages, messages, reset: true)

      {:error, :unauthorized} ->
        socket |> flash_unauthorized() |> push_navigate(to: ~p"/moderation/lookup")

      {:error, :not_found} ->
        leave(socket, not_found_flash())
    end
  end

  defp leave(socket, message) do
    socket |> put_flash(:error, message) |> push_navigate(to: ~p"/moderation/lookup")
  end

  defp takedown_form, do: to_form(%{"reason" => ""}, as: :takedown)

  @impl true
  def handle_event("lookup", %{"lookup" => %{"q" => query}}, socket) do
    case Lookup.resolve(socket.assigns.current_scope, query) do
      {:ok, {:user, _id} = target} ->
        {:noreply, push_navigate(socket, to: Lookup.path(target))}

      {:ok, target} ->
        if Scope.can?(socket.assigns.current_scope, "moderation.content.view"),
          do: {:noreply, push_navigate(socket, to: Lookup.path(target))},
          else: {:noreply, put_flash(socket, :error, cannot_open_flash())}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, nothing_found_flash())
         |> assign(lookup_form: to_form(%{"q" => query}, as: :lookup))}
    end
  end

  def handle_event("delete", params, %{assigns: %{view: view}} = socket) when not is_nil(view) do
    {type, id} = delete_target(socket.assigns.subject, view)

    case Lookup.delete(socket.assigns.current_scope, type, id) do
      {:ok, :deleted} ->
        {:noreply, gone(socket, deleted_flash())}

      {:error, :sudo_required} ->
        {:noreply, MythweaverWeb.Sudo.require(socket, "delete", params)}

      {:error, reason} ->
        {:noreply, ModerationNav.delete_refused(socket, reason)}
    end
  end

  def handle_event("delete_message", %{"id" => id} = params, %{assigns: %{view: view}} = socket)
      when not is_nil(view) do
    case Lookup.delete(socket.assigns.current_scope, :message, id) do
      {:ok, :deleted} when id == view.target_id ->
        {:noreply,
         socket
         |> put_flash(:info, message_deleted_flash())
         |> push_patch(to: Lookup.path({:chat, view.chat.id}))}

      {:ok, :deleted} ->
        {:noreply,
         socket
         |> put_flash(:info, message_deleted_flash())
         |> stream_delete_by_dom_id(:messages, "lookup-message-#{id}")}

      {:error, :sudo_required} ->
        {:noreply, MythweaverWeb.Sudo.require(socket, "delete_message", params)}

      {:error, reason} ->
        {:noreply, ModerationNav.delete_refused(socket, reason)}
    end
  end

  def handle_event(
        "takedown",
        %{"takedown" => %{"reason" => reason}},
        %{assigns: %{view: %{listing: listing}}} = socket
      ) do
    case Catalog.takedown(socket.assigns.current_scope, listing, reason) do
      :ok ->
        {:noreply, gone(socket, taken_down_flash())}

      {:error, :reason_required} ->
        {:noreply, put_flash(socket, :error, reason_required_flash())}

      {:error, :not_found} ->
        {:noreply, leave(socket, listing_gone_flash())}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}
    end
  end

  # The viewed row is gone by the moderator's own hand: leave without reloading on the broadcast.
  defp gone(socket, message) do
    socket
    |> assign(subject: nil)
    |> put_flash(:info, message)
    |> push_navigate(to: ~p"/moderation/lookup")
  end

  # A message's view deletes its whole chat.
  defp delete_target({:message, _id}, view), do: {:chat, view.chat.id}
  defp delete_target(subject, _view), do: subject

  @impl true
  def handle_info({Moderation, :changed}, %{assigns: %{subject: {type, id}}} = socket),
    do: {:noreply, load(socket, type, id, log: false)}

  def handle_info({Moderation, :changed}, socket), do: {:noreply, socket}

  defp type_label(type), do: ModerationNav.subject_label(type)

  defp lookup_title, do: dpgettext("moderation", "page title: moderation lookup form", "Lookup")

  defp view_title(type, view) do
    gettext_comment("Title of a looked-up item: its type (e.g. \"Character\"), then its name.")

    dpgettext("moderation", "page title: type and name of a looked-up item", "%{item_type}: %{item_name}",
      item_type: type_label(type),
      item_name: view.name
    )
  end

  defp not_found_flash do
    gettext_comment("Flash when the looked-up item does not exist or is gone.")
    dpgettext("moderation", "status: looked-up item does not exist", "Not found")
  end

  defp cannot_open_flash do
    gettext_comment("Flash when a moderator who may only open account records looks up content.")
    dpgettext("moderation", "status: moderator may not open content", "You can't open content")
  end

  defp nothing_found_flash do
    gettext_comment("Flash when a moderation lookup matches nothing.")
    dpgettext("moderation", "status: moderation lookup matched nothing", "Nothing found for that")
  end

  defp deleted_flash do
    gettext_comment("Flash after a moderator deletes the looked-up item.")
    dpgettext("moderation", "status: a moderator deleted the looked-up item", "Deleted")
  end

  defp message_deleted_flash do
    gettext_comment("Flash after a moderator deletes one message of a looked-up chat.")
    dpgettext("moderation", "status: a moderator deleted a chat message", "Message deleted")
  end

  defp taken_down_flash do
    gettext_comment("Flash after a moderator takes a catalog listing down.")
    dpgettext("moderation", "status: a moderator took a catalog listing down", "Taken down")
  end

  defp reason_required_flash do
    gettext_comment("Flash when a moderator takes a catalog listing down without a reason.")
    dgettext("moderation", "Say why it is taken down; its owner is told")
  end

  defp listing_gone_flash do
    gettext_comment("Flash when the catalog listing being taken down is already gone.")
    dgettext("moderation", "That listing is already gone")
  end

  defp handle(nil), do: nil
  defp handle(user), do: "@" <> user.handle

  defp attachment_links(message) do
    for attachment <- Message.loaded_attachments(message),
        url = Attachments.url(attachment, :original),
        do: {attachment, url}
  end

  defp attachment_name(%{filename: filename}) when is_binary(filename), do: filename
  defp attachment_name(%{kind: :image}), do: dpgettext("moderation", "link: attachment with no file name", "Image")

  defp attachment_name(%{kind: :document}),
    do: dpgettext("moderation", "link: attachment with no file name", "Document")

  defp attachment_name(%{kind: :audio}), do: dpgettext("moderation", "link: attachment with no file name", "Audio")
  defp attachment_name(%{kind: :video}), do: dpgettext("moderation", "link: attachment with no file name", "Video")
  defp attachment_name(%{kind: :file}), do: dpgettext("moderation", "link: attachment with no file name", "File")

  defp delete_confirm(%{type: :message} = view) do
    gettext_comment("Confirm dialog before a moderator deletes the chat a looked-up message is in.")

    dgettext("moderation", "Delete the whole chat %{chat_name}? It is removed for its owner and everyone in it.",
      chat_name: view.name
    )
  end

  defp delete_confirm(view) do
    gettext_comment("Confirm dialog before a moderator deletes a looked-up item.")

    dgettext("moderation", "Delete %{item_name}? It is removed for its owner and everyone it is shared with.",
      item_name: view.name
    )
  end

  defp delete_message_confirm do
    gettext_comment("Confirm dialog before a moderator deletes one message of a looked-up chat.")
    dpgettext("moderation", "heading: confirm dialog before deleting one chat message", "Delete this message?")
  end

  # The item a view's card shows: a listing's mirror, else the row itself.
  defp card_type(%{type: :listing, listing: listing}), do: listing.item_type
  defp card_type(%{type: type}), do: type

  defp listing_meta(:readable, owner) do
    dpgettext(
      "moderation",
      "status: a readable catalog listing and who published it",
      "Readable · published by %{publisher_handle}",
      publisher_handle: handle(owner) || ""
    )
  end

  defp listing_meta(:runtime_only, owner) do
    dpgettext(
      "moderation",
      "status: a runtime-only catalog listing and who published it",
      "Runtime-only · published by %{publisher_handle}",
      publisher_handle: handle(owner) || ""
    )
  end

  defp owner_line(%{owner: %{} = owner}) do
    gettext_comment("Who owns a looked-up item; the placeholder is a link to the owner's @handle.")

    rich(
      dpgettext("moderation", "status: owner of a looked-up item", "Owner: %{owner_link}",
        owner_link: navigate_link(handle(owner), Lookup.path({:user, owner.id}))
      )
    )
  end

  defp owner_line(%{type: type}) when type in [:chat, :message],
    do: dpgettext("moderation", "status: owner of a looked-up chat that has none", "Owner: No owner")

  defp owner_line(_view), do: dpgettext("moderation", "status: owner of a looked-up site item", "Owner: Site")

  defp members_line(members) do
    gettext_comment("Accounts in a looked-up chat; the placeholder is a list of @handles.")

    dpgettext("moderation", "status: accounts in a looked-up chat", "Members: %{member_handles}",
      member_handles: Format.list(Enum.map(members, &handle/1))
    )
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, can_delete?: Scope.can?(assigns.current_scope, "moderation.content.delete"))

    ~H"""
    <%!-- `lower-bound="none"`: rules reach the `<img>` root of `<.avatar_image>`. --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      div.lookup:scope {
        flex: 1 1 auto;
        min-block-size: 0;
        overflow-y: auto;
        margin: var(--panel-gap);
        background: var(--card);
        border: 1px solid var(--border);
        border-radius: var(--radius-3);
        box-shadow: var(--elevation-lg);
      }

      .lookup-body {
        display: flex;
        flex-direction: column;
        gap: var(--size-3);
        padding: var(--size-3);
      }

      .lookup-search {
        display: flex;
        align-items: end;
        gap: var(--size-2);
        max-inline-size: 40rem;
      }

      .lookup-search-field {
        flex: 1 1 auto;
      }

      .lookup-section {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .lookup-meta,
      .lookup-summary {
        margin: 0;
      }

      .lookup-meta {
        color: var(--muted-foreground);
      }

      .lookup-summary,
      .lookup-message-text {
        white-space: pre-wrap;
        overflow-wrap: anywhere;
      }

      .lookup-avatar {
        inline-size: 10rem;

        & img {
          display: block;
          inline-size: 100%;
          border-radius: var(--radius-3);
        }
      }

      .lookup-tags {
        display: flex;
        flex-wrap: wrap;
        gap: var(--size-1);
        margin: 0;
        padding: 0;
        list-style: none;

        & li {
          padding: 0 var(--size-2);
          border: 1px solid var(--border);
          border-radius: var(--radius-round);
          font-size: 0.875rem;
        }
      }

      .lookup-list {
        display: flex;
        flex-direction: column;
        gap: var(--size-3);
        margin: 0;
        padding: 0;
        list-style: none;
      }

      .lookup-messages {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .lookup-message {
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
        padding: var(--size-2) var(--size-3);
        border: 1px solid var(--border-grey);
        border-radius: var(--radius-2);

        &[aria-current="true"] {
          border-color: var(--primary-accent);
          border-width: 2px;
        }
      }

      .lookup-message-head {
        display: flex;
        align-items: baseline;
        gap: var(--size-2);
      }

      .lookup-message-author {
        font-weight: var(--font-weight-6);
      }

      .lookup-message-handle,
      .lookup-message-at {
        color: var(--muted-foreground);
        font-size: 0.875rem;
      }

      .lookup-message-delete {
        margin-inline-start: auto;
      }

      .lookup-message-attachments {
        display: flex;
        flex-wrap: wrap;
        gap: var(--size-2);
      }
    </style>
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <ModerationNav.nav current_scope={@current_scope} active="lookup" />
      <div class="lookup">
        <%= if @live_action == :index do %>
          <.panel_header sticky>
            {dpgettext("moderation", "heading: moderation lookup form", "Look up")}
          </.panel_header>
          <div class="lookup-body">
            <.form for={@lookup_form} id="lookup-form" phx-submit="lookup">
              <div class="lookup-search">
                <div class="lookup-search-field">
                  <.input
                    field={@lookup_form[:q]}
                    type="search"
                    id="lookup-form-q"
                    label={
                      dpgettext(
                        "moderation",
                        "field label: what to look up in the moderation panel",
                        "Look up"
                      )
                    }
                    placeholder={
                      dpgettext(
                        "moderation",
                        "placeholder: what to look up in the moderation panel",
                        "Link, id, @handle or email"
                      )
                    }
                  />
                </div>
                <.button type="submit" variant="primary" id="lookup-form-submit">
                  <.lucide name="search" />
                  {dpgettext("moderation", "button: run the moderation lookup", "Look up")}
                </.button>
              </div>
            </.form>
          </div>
        <% end %>

        <%= if @view do %>
          <.panel_header sticky>
            {view_title(@view.type, @view)}
            <:actions>
              <.button
                :if={
                  @view.owner && Scope.can?(@current_scope, "moderation.accounts.sanction") &&
                    Mythweaver.Moderation.sanctionable(@current_scope, @view.owner) == :ok
                }
                size="sm"
                id="lookup-sanction"
                navigate={Lookup.path({:user, @view.owner.id})}
              >
                <.lucide name="shield-alert" />
                {dpgettext(
                  "moderation",
                  "button: open the owner's record to warn or suspend them",
                  "Warn or suspend"
                )}
              </.button>
              <.button
                :if={@can_delete? and @view.type != :listing}
                size="sm"
                danger
                id="lookup-delete"
                phx-click="delete"
                data-confirm={delete_confirm(@view)}
              >
                <.lucide name="trash" />
                {if @view.type == :message,
                  do:
                    dpgettext(
                      "moderation",
                      "button: delete the chat of the looked-up message",
                      "Delete chat"
                    ),
                  else: dpgettext("moderation", "button: delete the looked-up item", "Delete")}
              </.button>
              <.button size="sm" navigate={~p"/moderation/lookup"} id="lookup-back">
                {dpgettext("moderation", "button: go back to the lookup form", "New lookup")}
              </.button>
            </:actions>
          </.panel_header>

          <div class="lookup-body">
            <p id="lookup-owner" class="lookup-meta">
              {owner_line(@view)}
            </p>

            <section :if={@view.type in [:chat, :message]} class="lookup-section">
              <p :if={@view.members != []} id="lookup-members" class="lookup-meta">
                {members_line(@view.members)}
              </p>
              <p :if={@messages_empty?} id="lookup-messages-empty" class="lookup-meta">
                {dpgettext("moderation", "empty state: looked-up chat has no messages", "No messages")}
              </p>
              <div
                id="lookup-messages"
                class="lookup-messages"
                phx-update="stream"
                phx-hook=".ScrollToTarget"
              >
                <div
                  :for={{dom_id, message} <- @streams.messages}
                  id={dom_id}
                  class="lookup-message"
                  aria-current={message.id == @view.target_id && "true"}
                >
                  <div class="lookup-message-head">
                    <span class="lookup-message-author">{Reports.author(message)}</span>
                    <span :if={message.author_user} class="lookup-message-handle">
                      {handle(message.author_user)}
                    </span>
                    <.local_time
                      id={"lookup-message-#{message.id}-at"}
                      at={message.inserted_at}
                      class="lookup-message-at"
                    />
                    <.button
                      :if={@can_delete?}
                      size="sm"
                      danger
                      class="lookup-message-delete"
                      id={"lookup-delete-message-#{message.id}"}
                      phx-click="delete_message"
                      phx-value-id={message.id}
                      data-confirm={delete_message_confirm()}
                    >
                      <.lucide name="trash" />
                      {dpgettext(
                        "moderation",
                        "button: delete one message of the looked-up chat",
                        "Delete"
                      )}
                    </.button>
                  </div>
                  <div class="lookup-message-text">{Message.active_content(message)}</div>
                  <div
                    :if={Message.loaded_attachments(message) != []}
                    class="lookup-message-attachments"
                  >
                    <.link
                      :for={{attachment, url} <- attachment_links(message)}
                      id={"lookup-attachment-#{attachment.id}"}
                      href={url}
                      target="_blank"
                    >
                      {attachment_name(attachment)}
                    </.link>
                  </div>
                </div>
              </div>
              <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollToTarget">
                // Brings the looked-up message (`aria-current`) into view once the transcript mounts.
                export default {
                  mounted() {
                    this.el
                      .querySelector('[aria-current="true"]')
                      ?.scrollIntoView({ block: "center" });
                  },
                };
              </script>
            </section>

            <section :if={@view.type == :listing} id="lookup-listing" class="lookup-section">
              <p class="lookup-meta">
                {listing_meta(@view.listing.visibility, @view.owner)}
              </p>
              <p :if={@view.listing.summary} id="lookup-summary" class="lookup-summary">
                {@view.listing.summary}
              </p>
              <ul :if={@view.listing.tags != []} id="lookup-tags" class="lookup-tags">
                <li :for={tag <- @view.listing.tags}>{tag}</li>
              </ul>
            </section>

            <section :if={Map.has_key?(@view, :card)} id="lookup-item" class="lookup-section">
              <.section_header :if={@view.type == :listing}>{@view.card.item.name}</.section_header>
              <div :if={:avatar in Items.fields(card_type(@view))} class="lookup-avatar">
                <.avatar_image
                  avatar={@view.card.item}
                  preset={:portrait}
                  sizes="160px"
                  alt={@view.card.item.name}
                />
              </div>
              <ItemFields.item_fields
                id="lookup-card"
                type={card_type(@view)}
                row={@view.card.item}
                readable?={true}
                fields={@view[:fields]}
              />
              <div :if={@view.card.capabilities != []} id="lookup-capabilities">
                <.section_header>
                  {dpgettext(
                    "moderation",
                    "heading: script capabilities of the looked-up item",
                    "Capabilities"
                  )}
                </.section_header>
                <ul class="lookup-tags">
                  <li :for={capability <- @view.card.capabilities}>{capability}</li>
                </ul>
              </div>
              <ul :if={@view.card.parts != []} id="lookup-parts" class="lookup-list">
                <li :for={{part, _readable?} <- @view.card.parts} id={"lookup-part-#{part.id}-row"}>
                  <.section_header>{part.name}</.section_header>
                  <ItemFields.item_fields
                    id={"lookup-part-#{part.id}"}
                    type={Items.type_of(part)}
                    row={part}
                    readable?={true}
                  />
                </li>
              </ul>
            </section>

            <section :if={@view.type == :ai_provider} id="lookup-item" class="lookup-section">
              <ItemFields.item_fields
                id="lookup-card"
                type={:ai_provider}
                row={@view.item}
                readable?={true}
                fields={@view.fields}
              />
            </section>

            <section
              :if={@view.type == :listing and @can_delete?}
              class="lookup-section"
            >
              <.form for={@takedown_form} id="lookup-takedown" phx-submit="takedown">
                <.editor
                  field={@takedown_form[:reason]}
                  id="lookup-takedown-reason"
                  label={dgettext("moderation", "Why is it taken down? Its owner is told.")}
                />
                <.form_actions>
                  <.button type="submit" danger id="lookup-takedown-submit">
                    {dpgettext("moderation", "button: take the catalog listing down", "Take down")}
                  </.button>
                </.form_actions>
              </.form>
            </section>
          </div>
        <% end %>
      </div>
      <MythweaverWeb.Sudo.modal :if={@sudo_prompt} prompt={@sudo_prompt} />
    </Layouts.app>
    """
  end
end
