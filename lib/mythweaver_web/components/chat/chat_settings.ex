defmodule MythweaverWeb.Chat.ChatSettings do
  @moduledoc """
  The chat settings modal, routed at `/chats/:id/settings`, backed by
  `Mythweaver.Chats.change_settings/2`. Its one form is split into tabs: Basics (name, default
  model, prompt, group cards, tags, and "Describe all attachments",
  `Mythweaver.Attachments.Captions.request_all/1`, which acts at once rather than on save), Replies
  (reply strategy, self responses, replies per turn, auto-mode delay), Participants (participants,
  player character) and Lore books.

  Every tab's panel is always rendered, an inactive one `hidden`, so Save and Apply submit every
  field. The tab is a server assign (`settings_tab`, set by `"chat_settings_tab"`), not a route,
  since a patch would rebuild the form and drop unsaved edits.

  The Members tab sits outside that form and acts at once: inviting by handle (`"invite_member"`;
  an editor invites guests only, and only the owner picks the invitee's `model_source`, whose
  models their replies and captions spend), each member's model source (`"set_member_model_source"`,
  owner only, on change), removing a member (`"remove_member"`), the guest toggles,
  `guests_bring_characters`, `free_switching` and `turn_mode` (`"save_membership"`, on change), and,
  without free switching, a row per player (`"add_player_row"`, `"remove_player_row"`), each with
  the characters that player holds (`"assign_players"`, on change). Only the owner sees Delete and
  chooses the chat's model.
  """

  use MythweaverWeb, :html

  import MythweaverWeb.Pane, only: [pane_export: 1]
  import MythweaverWeb.TagFields, only: [tag_fields: 1]

  alias Mythweaver.Accounts.User
  alias Mythweaver.Chats.Chat

  @tabs [
    {"basics", [:name, :ai_model_id, :prompt_id, :group_cards]},
    {"replies", [:reply_strategy, :allow_self_responses, :max_turns, :auto_mode_delay]},
    {"participants", [:participant_ids, :player_character_id]},
    {"lore", [:lore_book_ids]},
    {"members", []}
  ]

  defp tab_label("basics"), do: dpgettext("chat", "tab: chat settings, basic options", "Basics")
  defp tab_label("replies"), do: dpgettext("chat", "tab: chat settings, how replies are made", "Replies")
  defp tab_label("participants"), do: dpgettext("chat", "tab: chat settings, characters in the chat", "Participants")
  defp tab_label("lore"), do: dpgettext("chat", "tab: chat settings, lore books of the chat", "Lore books")
  defp tab_label("members"), do: dpgettext("chat", "tab: chat settings, people in the chat", "Members")

  # `Chat.guest_permissions/1`'s keys, in display order.
  defp guest_toggles do
    [
      {"edit_own", dpgettext("chat", "toggle: guests may edit their own messages", "Edit their own messages")},
      {"delete_own", dpgettext("chat", "toggle: guests may delete their own messages", "Delete their own messages")},
      {"regenerate",
       dpgettext("chat", "toggle: guests may regenerate and swipe replies", "Regenerate and swipe replies")},
      {"trigger_replies", dpgettext("chat", "toggle: guests may trigger replies", "Trigger replies")},
      {"run_scripts", dpgettext("chat", "toggle: guests may run scripts", "Run scripts")},
      {"attach", dpgettext("chat", "toggle: guests may attach files", "Attach files")}
    ]
  end

  defp delete_confirm(chat) do
    gettext_comment("Confirm dialog before deleting a chat from its settings.")
    dgettext("chat", "Delete %{chat_title}? This also deletes its messages.", chat_title: Chat.title(chat))
  end

  defp remove_member_confirm(member, chat) do
    gettext_comment("Confirm dialog before removing a member from a shared chat.")

    dpgettext(
      "chat",
      "status: confirm dialog before removing a member from a shared chat",
      "Remove %{member_name} from %{chat_title}?",
      member_name: User.display_name(member.user),
      chat_title: Chat.title(chat)
    )
  end

  @doc "The tab names, first the default."
  def tab_names, do: for({tab, _fields} <- @tabs, do: tab)

  @doc "`tab` when its fields show no error, else the first tab whose fields do, else `tab`."
  def error_tab(form, tab) do
    invalid = invalid_tabs(form)
    if tab in invalid or invalid == [], do: tab, else: hd(invalid)
  end

  # Tabs holding a field that shows an error (`used_input?`, as `<.input>` gates its own).
  defp invalid_tabs(form) do
    for {tab, fields} <- @tabs,
        Enum.any?(fields, &(used_input?(form[&1]) and form[&1].errors != [])),
        do: tab
  end

  attr :chat, :any, required: true
  attr :form, :any, required: true
  attr :tab, :string, default: "basics", doc: "the open tab, one of `tab_names/0`"
  attr :character_options, :list, default: []
  attr :model_options, :list, default: []
  attr :lore_book_options, :list, default: []
  attr :prompt_options, :list, default: []
  attr :tag_field, :map, required: true, doc: "the `:chat` entry of `MythweaverWeb.TagFields`' state"
  attr :tag_vocabulary, :list, required: true
  attr :viewer_id, :string, required: true, doc: "`current_scope.user.id`, for the participant picker's tag filter"
  attr :tag_graph, :any, required: true, doc: "the viewer's `Mythweaver.Tags.Graph`"
  attr :role, :atom, required: true, doc: "the viewer's `Chats.role/2`: `:owner` or `:editor`"
  attr :members, :list, default: [], doc: "`Chats.list_members/2`, each with `:user`"
  attr :invite_form, :any, required: true, doc: "the Members tab's invite form (`handle`, `role`)"
  attr :locks, :map, default: %{}, doc: "`Chats.locks/1`: character id => holders (`[User]`)"
  attr :lock_holders, :list, default: [], doc: "`{label, user_id}` of the owner and accepted members"
  attr :player_rows_added, :list, default: [], doc: "user ids added as rows that hold nothing yet"
  attr :can_report, :boolean, default: false, doc: "the viewer holds `\"reports.create\"`"
  attr :current_scope, :any, required: true

  def chat_settings(assigns) do
    held_user_ids = assigns.locks |> Map.values() |> List.flatten() |> MapSet.new(& &1.id)

    player_rows =
      for {label, uid} <- assigns.lock_holders,
          MapSet.member?(held_user_ids, uid) or uid in assigns.player_rows_added,
          do: %{label: label, user_id: uid, selected: held_by(assigns.chat, assigns.locks, uid)}

    row_ids = MapSet.new(player_rows, & &1.user_id)

    assigns =
      assign(assigns,
        tab_list: @tabs,
        invalid_tabs: invalid_tabs(assigns.form),
        guest_toggles: guest_toggles(),
        guest_permissions: Chat.guest_permissions(assigns.chat),
        player_rows: player_rows,
        addable_players: Enum.reject(assigns.lock_holders, fn {_label, uid} -> MapSet.member?(row_ids, uid) end),
        character_choices: for(p <- assigns.chat.participants, do: {p.character.name, p.character_id})
      )

    ~H"""
    <%!--
      `lower-bound="none"`: the form is rendered through `<.modal>`'s slot and `<.input>`'s
      internals, both nested component roots carrying `phx-r`. The wrapping `<div>` is the root
      that carries the scope marker (a component call alone gives the block nothing to attach to);
      every rule is scoped to a `.chat-settings-*` class, never to the root.
    --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      .chat-settings-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      /* `display` here would beat the UA's `[hidden]` rule, so only a shown panel gets it. */
      .chat-settings-panel:not([hidden]) {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .chat-settings-form label {
        display: block;
      }

      .chat-settings-form-attachments {
        display: flex;
        gap: var(--size-2);
        align-items: center;
        justify-content: space-between;
      }

      .chat-settings-form-help {
        margin: 0;
        color: var(--muted-foreground);
        font-size: var(--font-size-0);
      }

      .chat-settings-members-invite {
        display: flex;
        gap: var(--size-2);
        align-items: end;
      }

      .chat-settings-members {
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
        margin: 0;
        padding: 0;
        list-style: none;
      }

      .chat-settings-player {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .chat-settings-player-head {
        display: flex;
        gap: var(--size-2);
        align-items: center;
        justify-content: space-between;
      }

      .chat-settings-members li {
        display: flex;
        gap: var(--size-2);
        align-items: center;
      }

      .chat-settings-member-name {
        flex: 1;
      }

      .chat-settings-fieldset {
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
        margin: 0;
        padding: 0;
        border: 0;
      }
    </style>

    <div class="chat-settings">
      <.modal
        id="chat-settings-modal"
        title={dpgettext("chat", "heading: modal with a chat's settings", "Chat settings")}
        on_cancel="close_chat_settings"
      >
        <.tabs
          id="chat-settings"
          label={dpgettext("chat", "aria label: tab list of a chat's settings", "Chat settings")}
          active={@tab}
          on_select="chat_settings_tab"
          panels
        >
          <:tab
            :for={{tab, _fields} <- @tab_list}
            name={tab}
            invalid={tab in @invalid_tabs}
          >
            <.lucide :if={tab in @invalid_tabs} name="circle-alert" />
            {tab_label(tab)}
          </:tab>
        </.tabs>
        <.form
          for={@form}
          id="chat-settings-form"
          class="chat-settings-form"
          phx-hook="UnsavedChanges"
          data-saved={is_nil(@form.action)}
          phx-change="validate_settings"
          phx-submit="save_settings"
        >
          <.tab_panel tabs="chat-settings" name="basics" active={@tab} class="chat-settings-panel">
            <.input
              field={@form[:name]}
              type="text"
              label={dpgettext("chat", "field label: name of a chat", "Name")}
              id="chat-settings-form-name"
            />
            <.input
              field={@form[:ai_model_id]}
              type="select"
              label={dpgettext("chat", "field label: model a chat replies with", "Default model")}
              prompt={
                dpgettext(
                  "chat",
                  "option: no chat model, use the one from settings",
                  "Default model from Settings"
                )
              }
              options={@model_options}
              id="chat-settings-form-ai_model_id"
              disabled={@role != :owner}
            />
            <p
              :if={@role != :owner}
              id="chat-settings-form-ai_model_id-help"
              class="chat-settings-form-help"
            >
              {dgettext("chat", "Only the chat's owner chooses models.")}
            </p>
            <.input
              field={@form[:prompt_id]}
              type="select"
              label={dpgettext("chat", "field label: prompt a chat uses", "Prompt")}
              prompt={
                dpgettext("chat", "option: no chat prompt, inherit one", "Inherit (no chat prompt)")
              }
              options={@prompt_options}
              id="chat-settings-form-prompt_id"
            />
            <div class="chat-settings-form-field">
              <.input
                field={@form[:group_cards]}
                type="select"
                label={
                  dpgettext(
                    "chat",
                    "field label: which character cards a group reply sees",
                    "Group cards"
                  )
                }
                id="chat-settings-form-group_cards"
                aria-describedby="chat-settings-form-group_cards-help"
                options={[
                  {dgettext("chat", "Swap: only the responder's card"), "swap"},
                  {dgettext("chat", "Join: every unmuted member's card"), "join"},
                  {dgettext("chat", "Join all: every member's card, muted included"), "join_all"}
                ]}
              />
              <p id="chat-settings-form-group_cards-help" class="chat-settings-form-help">
                {dgettext(
                  "chat",
                  "Which characters' cards a reply sees besides the responder's and the player's: their descriptions (the Other characters block) and the lore books bound to them, such as an imported card's personality and scenario. SillyTavern's group generation handling mode."
                )}
              </p>
            </div>
            <.tag_fields
              id="chat-settings-form-tags"
              prefix="tags"
              field={@tag_field}
              vocabulary={@tag_vocabulary}
            />
            <div class="chat-settings-form-attachments">
              <span>{dpgettext("chat", "heading: chat settings attachments row", "Attachments")}</span>
              <.button
                size="sm"
                id="chat-settings-describe-attachments"
                phx-click="describe_all_attachments"
                title={
                  dgettext(
                    "chat",
                    "Describe every image, audio clip, video and document in this chat that has no description yet (hidden messages are skipped)"
                  )
                }
              >
                <.lucide name="sparkles" />
                {dpgettext(
                  "chat",
                  "button: describe every attachment in the chat",
                  "Describe all attachments"
                )}
              </.button>
            </div>
          </.tab_panel>
          <.tab_panel tabs="chat-settings" name="replies" active={@tab} class="chat-settings-panel">
            <.input
              field={@form[:reply_strategy]}
              type="select"
              label={dpgettext("chat", "field label: how a chat picks who replies", "Reply strategy")}
              id="chat-settings-form-reply_strategy"
              options={[
                {dpgettext("chat", "option: chat reply strategy", "Manual"), "manual"},
                {dpgettext("chat", "option: chat reply strategy", "Natural order"), "natural"},
                {dpgettext("chat", "option: chat reply strategy", "List order"), "list"},
                {dpgettext("chat", "option: chat reply strategy", "Pooled order"), "pooled"}
              ]}
            />
            <.input
              field={@form[:allow_self_responses]}
              type="checkbox"
              label={
                dpgettext("chat", "toggle: a character may reply to itself", "Allow self responses")
              }
              id="chat-settings-form-allow_self_responses"
            />
            <.input
              field={@form[:max_turns]}
              type="number"
              min="1"
              label={
                dpgettext(
                  "chat",
                  "field label: chat reply limit per turn",
                  "Maximum replies per turn"
                )
              }
              placeholder={dpgettext("chat", "placeholder: no reply limit per turn", "Unlimited")}
              id="chat-settings-form-max_turns"
            />
            <.input
              field={@form[:auto_mode_delay]}
              type="number"
              min="1"
              max="999"
              label={
                dpgettext(
                  "chat",
                  "field label: delay between automatic replies",
                  "Auto mode delay (seconds)"
                )
              }
              id="chat-settings-form-auto_mode_delay"
            />
          </.tab_panel>
          <.tab_panel
            tabs="chat-settings"
            name="participants"
            active={@tab}
            class="chat-settings-panel"
          >
            <.live_component
              module={MythweaverWeb.MultiSelect}
              id="chat-settings-form-participant_ids"
              name="settings[participant_ids][]"
              label={
                dpgettext("chat", "field label: characters in a chat", "Participants (at least 2)")
              }
              options={@character_options}
              selected={@form[:participant_ids].value || []}
              errors={picker_errors(@form, :participant_ids)}
              empty={
                dpgettext("chat", "empty state: no characters to add to a chat", "No characters yet")
              }
              tag_kind={:character}
              viewer_id={@viewer_id}
              tag_graph={@tag_graph}
              tag_vocabulary={@tag_vocabulary}
            />
            <.input
              field={@form[:player_character_id]}
              type="select"
              label={dpgettext("chat", "field label: character the player plays", "Player character")}
              prompt={dpgettext("chat", "option: no player character", "None (spectator)")}
              options={player_options(@character_options, @chat, @form)}
              id="chat-settings-form-player_character_id"
            />
          </.tab_panel>
          <.tab_panel tabs="chat-settings" name="lore" active={@tab} class="chat-settings-panel">
            <.live_component
              module={MythweaverWeb.MultiSelect}
              id="chat-settings-form-lore_book_ids"
              name="settings[lore_book_ids][]"
              label={dpgettext("chat", "field label: lore books of a chat", "Lore books")}
              options={@lore_book_options}
              selected={@form[:lore_book_ids].value || []}
              errors={picker_errors(@form, :lore_book_ids)}
              empty={
                dpgettext("chat", "empty state: no lore books to add to a chat", "No lore books yet")
              }
              tag_kind={:lore_book}
              viewer_id={@viewer_id}
              tag_graph={@tag_graph}
              tag_vocabulary={@tag_vocabulary}
            />
          </.tab_panel>
          <.form_actions :if={@tab != "members"}>
            <:start :if={@role == :owner}>
              <.button
                id="chat-settings-delete"
                danger
                phx-click="delete_chat"
                phx-value-id={@chat.id}
                data-confirm={delete_confirm(@chat)}
              >
                <.lucide name="trash" /> {dpgettext("chat", "button: delete this chat", "Delete")}
              </.button>
              <.pane_export
                id="chat-settings-export"
                kind={:chat}
                item={@chat}
                current_scope={@current_scope}
              />
            </:start>
            <.button patch={~p"/chats/#{@chat.id}"} id="chat-settings-cancel">
              {dpgettext("chat", "button: close chat settings without saving", "Cancel")}
            </.button>
            <.button type="submit" name="intent" value="apply" id="chat-settings-apply">
              {dpgettext("chat", "button: save chat settings and keep them open", "Apply")}
            </.button>
            <.button
              type="submit"
              name="intent"
              value="save"
              id="chat-settings-save"
              variant="primary"
            >
              {dpgettext("chat", "button: save chat settings", "Save")}
            </.button>
          </.form_actions>
        </.form>
        <.tab_panel tabs="chat-settings" name="members" active={@tab} class="chat-settings-panel">
          <.form
            for={@invite_form}
            id="chat-members-invite"
            class="chat-settings-members-invite"
            phx-submit="invite_member"
          >
            <.input
              field={@invite_form[:handle]}
              type="text"
              label={
                dpgettext(
                  "chat",
                  "field label: handle of a user to invite to a chat",
                  "Invite by handle"
                )
              }
              placeholder={dpgettext("chat", "placeholder: a user handle", "@handle")}
              autocomplete="off"
              id="chat-members-invite-handle"
            />
            <.input
              field={@invite_form[:role]}
              type="select"
              label={dpgettext("chat", "field label: role of a chat member", "Role")}
              options={invite_roles(@role)}
              id="chat-members-invite-role"
            />
            <.input
              :if={@role == :owner}
              field={@invite_form[:model_source]}
              type="select"
              label={dpgettext("chat", "field label: whose models a chat member spends", "Models")}
              options={model_source_options()}
              id="chat-members-invite-model_source"
            />
            <.button type="submit" id="chat-members-invite-submit">
              <.lucide name="user-plus" /> {dpgettext(
                "chat",
                "button: invite a user to a chat",
                "Invite"
              )}
            </.button>
          </.form>
          <p :if={@members == []} id="chat-members-empty" class="chat-settings-form-help">
            {dgettext("chat", "Nobody else is in this chat yet.")}
          </p>
          <ul :if={@members != []} id="chat-members" class="chat-settings-members">
            <li :for={member <- @members} id={"chat-member-#{member.id}"}>
              <span class="chat-settings-member-name">
                {User.display_name(member.user)}
                <span :if={member.user.nickname} class="chat-settings-form-help">
                  @{member.user.handle}
                </span>
              </span>
              <.badge>{role_label(member.role)}</.badge>
              <.badge :if={member.status == :pending}>
                {dpgettext("chat", "badge: chat member who has not accepted yet", "Invited")}
              </.badge>
              <.form
                :if={@role == :owner}
                for={%{}}
                as={:member_model_source}
                id={"chat-member-model-source-#{member.id}"}
                phx-change="set_member_model_source"
              >
                <input type="hidden" name="member_id" value={member.id} />
                <.input
                  name="model_source"
                  type="select"
                  label={
                    dpgettext("chat", "field label: whose models a chat member spends", "Models")
                  }
                  options={model_source_options()}
                  value={to_string(member.model_source)}
                  id={"chat-member-model-source-#{member.id}-select"}
                />
              </.form>
              <.button
                :if={removable?(@role, member)}
                size="sm"
                danger
                id={"chat-member-remove-#{member.id}"}
                phx-click="remove_member"
                phx-value-id={member.id}
                data-confirm={remove_member_confirm(member, @chat)}
              >
                <.lucide name="user-minus" /> {dpgettext(
                  "chat",
                  "button: remove a member from a chat",
                  "Remove"
                )}
              </.button>
              <.button
                :if={@can_report && member.user_id != @viewer_id}
                size="sm"
                id={"chat-member-report-#{member.id}"}
                phx-click="open_report"
                phx-value-kind="user"
                phx-value-id={member.user_id}
              >
                <.lucide name="flag" /> {dpgettext("chat", "button: report a chat member", "Report")}
              </.button>
            </li>
          </ul>
          <.form
            for={%{}}
            as={:membership}
            id="chat-membership-form"
            class="chat-settings-form"
            phx-change="save_membership"
          >
            <fieldset class="chat-settings-fieldset">
              <legend>
                {dpgettext("chat", "heading: what guests of a chat may do", "Guests may")}
              </legend>
              <.input
                :for={{key, label} <- @guest_toggles}
                type="checkbox"
                name={"membership[guest_permissions][#{key}]"}
                id={"chat-membership-guest-#{key}"}
                value={@guest_permissions[key]}
                label={label}
              />
            </fieldset>
            <.input
              type="checkbox"
              name="membership[guests_bring_characters]"
              id="chat-membership-guests_bring_characters"
              value={@chat.guests_bring_characters}
              label={dgettext("chat", "Guests may bring their own characters")}
            />
            <.input
              type="checkbox"
              name="membership[free_switching]"
              id="chat-membership-free_switching"
              value={@chat.free_switching}
              label={
                dgettext("chat", "Free switching: players take and release any characters themselves")
              }
            />
            <.input
              type="select"
              name="membership[turn_mode]"
              id="chat-membership-turn_mode"
              value={to_string(@chat.turn_mode)}
              label={dpgettext("chat", "field label: when a chat's replies come in turns", "Turns")}
              options={[
                {dgettext("chat", "Any time: every message may get a reply"), "any"},
                {dgettext("chat", "Rounds: reply once every player posted or skipped"), "round"}
              ]}
            />
          </.form>
          <.form
            :if={!@chat.free_switching and @player_rows != []}
            for={%{}}
            as={:players}
            id="chat-players-form"
            class="chat-settings-form"
            phx-change="assign_players"
          >
            <fieldset class="chat-settings-fieldset">
              <legend>
                {dpgettext(
                  "chat",
                  "heading: which player plays which chat characters",
                  "Who plays which characters"
                )}
              </legend>
              <div
                :for={row <- @player_rows}
                id={"chat-player-#{row.user_id}"}
                class="chat-settings-player"
              >
                <div class="chat-settings-player-head">
                  <span class="chat-settings-member-name">{row.label}</span>
                  <.button
                    type="button"
                    size="sm"
                    danger
                    id={"chat-player-remove-#{row.user_id}"}
                    phx-click="remove_player_row"
                    phx-value-user_id={row.user_id}
                  >
                    <.lucide name="user-minus" />
                    {dpgettext(
                      "chat",
                      "button: remove a player row from the character assignment",
                      "Remove"
                    )}
                  </.button>
                </div>
                <.live_component
                  module={MythweaverWeb.MultiSelect}
                  id={"chat-player-#{row.user_id}-characters"}
                  name={"players[#{row.user_id}][]"}
                  label={dpgettext("chat", "field label: characters a player plays", "Characters")}
                  options={@character_choices}
                  selected={row.selected}
                  empty={
                    dpgettext("chat", "empty state: chat has no participants", "No participants")
                  }
                />
              </div>
            </fieldset>
          </.form>
          <.form
            :if={!@chat.free_switching and @addable_players != []}
            for={%{}}
            as={:player}
            id="chat-players-add"
            class="chat-settings-members-invite"
            phx-submit="add_player_row"
          >
            <.input
              type="select"
              name="player[user_id]"
              id="chat-players-add-user"
              label={
                dpgettext(
                  "chat",
                  "field label: player to add to the character assignment",
                  "Add a player"
                )
              }
              value=""
              options={@addable_players}
            />
            <.button type="submit" id="chat-players-add-submit">
              <.lucide name="user-plus" /> {dpgettext(
                "chat",
                "button: add a player to the character assignment",
                "Add player"
              )}
            </.button>
          </.form>
        </.tab_panel>
      </.modal>
    </div>
    """
  end

  # The chat's saved participants plus whatever the picker currently holds; `validate_settings`
  # re-renders on every change, so this tracks the selection live.
  defp player_options(character_options, chat, form) do
    selected = Ecto.Changeset.get_field(form.source, :participant_ids) || []
    allowed = MapSet.new(Enum.map(chat.participants, & &1.character_id) ++ selected)
    Enum.filter(character_options, fn {_name, id} -> MapSet.member?(allowed, id) end)
  end

  # An editor invites guests only (`Chats.invite/5`).
  defp invite_roles(:owner), do: [{role_label(:guest), "guest"}, {role_label(:editor), "editor"}]
  defp invite_roles(_role), do: [{role_label(:guest), "guest"}]

  # A member's `model_source`: whose models their replies and captions spend.
  defp model_source_options,
    do: [
      {dpgettext("chat", "option: a chat member spends the owner's models", "Uses my models"), "owner"},
      {dpgettext("chat", "option: a chat member spends their own models", "Brings their own models"), "own"}
    ]

  defp role_label(:editor), do: dpgettext("chat", "option: chat member role", "Editor")
  defp role_label(:guest), do: dpgettext("chat", "option: chat member role", "Guest")

  # `Chats.remove_member/2`: the owner removes anyone, an editor only guests.
  defp removable?(:owner, _member), do: true
  defp removable?(:editor, %{role: :guest}), do: true
  defp removable?(_role, _member), do: false

  # The participant character ids, in speaking order, that `user_id` holds.
  defp held_by(chat, locks, user_id) do
    for %{character_id: id} <- chat.participants,
        Enum.any?(Map.get(locks, id, []), &(&1.id == user_id)),
        do: id
  end

  # A picker has no `field`, so this is `input/1`'s `used_input?` gate: no errors on a pristine form.
  defp picker_errors(form, name) do
    field = form[name]
    if used_input?(field), do: Enum.map(field.errors, &translate_error/1), else: []
  end
end
