defmodule MythweaverWeb.UserDataLive do
  @moduledoc """
  A user's content index in the moderation panel (`/moderation/users/:id/data`,
  `Mythweaver.Accounts.UserData`): their chats and own characters, lore books, prompts, scripts and
  AI connections, each opening its read-only lookup view (`MythweaverWeb.ModerationLookupLive`),
  where it is deleted. Lore books can be moved to the site here, after the viewer's password
  (`MythweaverWeb.Sudo`). Holders of `"moderation.content.view"` reach it from the account's page;
  every open is written to the moderation log.
  """
  use MythweaverWeb, :live_view

  import MythweaverWeb.Pane

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.Accounts.UserData
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Moderation.Log

  on_mount {MythweaverWeb.UserAuth, {:require_permission, "moderation.content.view"}}
  on_mount MythweaverWeb.Sudo

  @sections [
    {:characters, :character},
    {:lore_books, :lore_book},
    {:prompts, :prompt},
    {:scripts, :script},
    {:ai_providers, :ai_provider}
  ]

  defp section_label(:characters),
    do: dpgettext("accounts", "heading: a user's characters on their moderation data page", "Characters")

  defp section_label(:lore_books),
    do: dpgettext("accounts", "heading: a user's lore books on their moderation data page", "Lore books")

  defp section_label(:prompts),
    do: dpgettext("accounts", "heading: a user's prompts on their moderation data page", "Prompts")

  defp section_label(:scripts),
    do: dpgettext("accounts", "heading: a user's scripts on their moderation data page", "Scripts")

  defp section_label(:ai_providers),
    do: dpgettext("accounts", "heading: a user's AI connections on their moderation data page", "AI connections")

  defp moved_message(book_name) do
    gettext_comment("Flash after a moderator moved a user's lore book to the site.")
    dgettext("accounts", "%{book_name} is now a site book", book_name: book_name)
  end

  defp move_failed_message do
    gettext_comment("Flash when moving a user's lore book to the site failed.")
    dpgettext("accounts", "status: moving a user's lore book to the site failed", "Could not move it")
  end

  defp move_confirm(book_name) do
    gettext_comment("Confirm dialog before a moderator moves a user's lore book to the site.")

    dgettext("accounts", "Move %{book_name} to the site? Its links to this user's other content are removed.",
      book_name: book_name
    )
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    with %User{} = user <- Accounts.get_user(id),
         :ok <- UserData.authorize(socket.assigns.current_scope, user) do
      scope = socket.assigns.current_scope

      {:ok,
       assign(socket,
         user: user,
         page_title:
           dpgettext("accounts", "page title: moderation page listing a user's content", "%{user_name}'s data",
             user_name: User.display_name(user)
           ),
         can_move?: Scope.can?(scope, "moderation.content.delete") and Scope.can?(scope, "site.content.manage")
       )}
    else
      _ ->
        {:ok, socket |> flash_unauthorized() |> push_navigate(to: ~p"/moderation/users")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(%{assigns: %{user: user}} = socket, :show, _params) do
    if connected?(socket),
      do: :ok = Log.record(socket.assigns.current_scope, :viewed, :user, user.id, user.id, %{"page" => "content"})

    load(socket)
  end

  defp apply_action(socket, _action, _params), do: socket

  defp load(socket) do
    scope = socket.assigns.current_scope
    user = socket.assigns.user
    assign(socket, chats: UserData.chats(scope, user), content: UserData.content(scope, user))
  end

  @impl true
  def handle_event("move_book", %{"id" => id} = params, socket) do
    case UserData.move_book_to_site(socket.assigns.current_scope, socket.assigns.user, id) do
      {:ok, book} ->
        {:noreply, socket |> load() |> put_flash(:info, moved_message(book.name))}

      {:error, :sudo_required} ->
        {:noreply, MythweaverWeb.Sudo.require(socket, "move_book", params)}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}

      _other ->
        {:noreply, put_flash(socket, :error, move_failed_message())}
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, sections: @sections)

    ~H"""
    <%!-- `lower-bound="none"`: the sections' content sits in `<.pane_section>` slots. --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      div.user-data:scope {
        flex: 1 1 auto;
        min-block-size: 0;
        overflow-y: auto;
        margin: var(--panel-gap);
        background: var(--card);
        border: 1px solid var(--border);
        border-radius: var(--radius-3);
        box-shadow: var(--elevation-lg);
      }

      .user-data-list {
        list-style: none;
        margin: 0;
        padding: 0;
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
      }

      .user-data-row {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: var(--size-2);
      }

      .user-data-actions {
        display: flex;
        gap: var(--size-1);
      }

      .user-data-empty {
        margin: 0;
      }

      @media (--phone) {
        .user-data-row {
          flex-wrap: wrap;
          gap: var(--size-2);
        }
        .user-data-row > a:first-child {
          flex: 1 1 100%;
          min-inline-size: 0;
          overflow-wrap: anywhere;
        }
      }
    </style>

    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <MythweaverWeb.ModerationNav.nav current_scope={@current_scope} active="users" />
      <div class="user-data">
        <.panel_header sticky>
          {@page_title}
          <:actions>
            <.button size="sm" navigate={~p"/moderation/users/#{@user.id}/edit"} id="user-data-back">
              {dpgettext(
                "accounts",
                "button: back to the user's account page in moderation",
                "Back to account"
              )}
            </.button>
          </:actions>
        </.panel_header>

        <.pane_section>
          <.section_header>
            {dpgettext("accounts", "heading: a user's chats on their moderation data page", "Chats")}
          </.section_header>
          <p :if={@chats == []} class="user-data-empty">
            {dpgettext("accounts", "empty state: the user has no chats", "No chats")}
          </p>
          <ul id="user-data-chats" class="user-data-list">
            <li :for={chat <- @chats} id={"user-data-chats-#{chat.id}"} class="user-data-row">
              <.link navigate={~p"/moderation/lookup/chat/#{chat.id}"}>{Chat.title(chat)}</.link>
            </li>
          </ul>
        </.pane_section>

        <.pane_section :for={{key, kind} <- @sections}>
          <.section_header>{section_label(key)}</.section_header>
          <p :if={@content[key] == []} class="user-data-empty">
            {dpgettext("accounts", "empty state: the user has no content of this kind", "None")}
          </p>
          <ul
            id={"user-data-#{String.replace(Atom.to_string(key), "_", "-")}"}
            class="user-data-list"
          >
            <li
              :for={row <- @content[key]}
              id={"user-data-#{kind}-#{row.id}"}
              class="user-data-row"
            >
              <.link navigate={~p"/moderation/lookup/#{kind}/#{row.id}"}>{row.name}</.link>
              <span class="user-data-actions">
                <.button
                  :if={kind == :lore_book and @can_move?}
                  size="sm"
                  id={"user-data-move-#{row.id}"}
                  phx-click="move_book"
                  phx-value-id={row.id}
                  data-confirm={move_confirm(row.name)}
                >
                  {dpgettext(
                    "accounts",
                    "button: move a user's lore book to the site",
                    "Move to site"
                  )}
                </.button>
              </span>
            </li>
          </ul>
        </.pane_section>
      </div>
      <MythweaverWeb.Sudo.modal :if={@sudo_prompt} prompt={@sudo_prompt} />
    </Layouts.app>
    """
  end
end
