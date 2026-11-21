defmodule MythweaverWeb.ModerationNav do
  @moduledoc """
  The moderation panel's section tabs and shared web helpers: its sections (`sections/1`, each shown
  only to a scope that may open it), the tab bar atop every moderation page (`nav/1`), and the
  labels, ban lifting and delete refusals its LiveViews share. The top bar's Moderation link opens
  the first section.
  """

  use MythweaverWeb, :html

  import Phoenix.LiveView, only: [put_flash: 3]

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.Moderation
  alias Mythweaver.Moderation.Ban
  alias Mythweaver.Moderation.Sanctions
  alias Phoenix.LiveView.Socket

  @doc "`{name, label, path}` of every section `scope` may open, in order."
  @spec sections(Scope.t() | nil) :: [{String.t(), String.t(), String.t()}]
  def sections(nil), do: []

  def sections(%Scope{} = scope) do
    can? = &Scope.can?(scope, &1)

    [
      {"reports", dpgettext("moderation", "tab: moderation section listing reports", "Reports"),
       if(can?.("moderation.reports"), do: ~p"/moderation/reports", else: ~p"/moderation/flagged"),
       can?.("moderation.reports") or can?.("moderation.review")},
      {"rules", dpgettext("moderation", "tab: moderation section listing moderation rules", "Rules"),
       ~p"/moderation/rules", can?.("moderation.rules.manage")},
      {"lookup", dpgettext("moderation", "tab: moderation section for looking up content", "Lookup"),
       ~p"/moderation/lookup", Enum.any?(Moderation.record_keys(), can?)},
      {"users", dpgettext("moderation", "tab: moderation section listing user accounts", "Users"),
       ~p"/moderation/users", can?.("users.manage")},
      {"groups", dpgettext("moderation", "tab: moderation section listing permission groups", "Groups"),
       ~p"/moderation/groups", can?.("groups.manage")},
      {"bans", dpgettext("moderation", "tab: moderation section listing bans", "Bans"), ~p"/moderation/bans",
       can?.("moderation.accounts.sanction") or can?.("moderation.fingerprints")},
      {"log", dpgettext("moderation", "tab: moderation section showing the moderation log", "Log"), ~p"/moderation/log",
       can?.("moderation.log.view")}
    ]
    |> Enum.filter(&elem(&1, 3))
    |> Enum.map(fn {name, label, path, _} -> {name, label, path} end)
  end

  @doc "The path of `scope`'s first section, or nil when it may open none."
  @spec home(Scope.t() | nil) :: String.t() | nil
  def home(scope) do
    case sections(scope) do
      [{_name, _label, path} | _] -> path
      [] -> nil
    end
  end

  attr :current_scope, :any, required: true
  attr :active, :string, required: true, doc: "the current section's name"

  @doc "The section tabs, the first child of every moderation page."
  def nav(assigns) do
    assigns = assign(assigns, sections: sections(assigns.current_scope))

    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      div.moderation-nav:scope {
        flex: none;
        padding: var(--panel-gap) var(--panel-gap) 0;
      }
    </style>
    <div class="moderation-nav">
      <.tabs
        id="moderation"
        label={dpgettext("moderation", "aria label: tab bar of the moderation panel", "Moderation")}
        active={@active}
      >
        <:tab :for={{name, label, path} <- @sections} name={name} navigate={path}>{label}</:tab>
      </.tabs>
    </div>
    """
  end

  @doc "An account's `@handle`, or \"a deleted account\"."
  @spec handle(User.t() | nil) :: String.t()
  def handle(%User{handle: handle}), do: "@" <> handle

  def handle(nil),
    do:
      dpgettext(
        "moderation",
        "status: shown in place of the handle of an account that was deleted",
        "a deleted account"
      )

  @doc "The label of a ban kind."
  @spec ban_kind_label(Ban.kind()) :: String.t()
  def ban_kind_label(:account), do: dpgettext("moderation", "badge: kind of ban, on a whole account", "Account")
  def ban_kind_label(:device), do: dpgettext("moderation", "badge: kind of ban, on one device", "Device")

  def ban_kind_label(:fingerprint),
    do:
      dpgettext(
        "moderation",
        "badge: kind of ban, on a browser fingerprint",
        "Browser fingerprint (identical devices share it)"
      )

  def ban_kind_label(:ip), do: dpgettext("moderation", "badge: kind of ban, on an IP address", "IP address")

  @doc "Whether `ban` is lifted, active or expired at `now`."
  @spec ban_status(Ban.t(), DateTime.t()) :: String.t()
  def ban_status(%Ban{lifted_at: %DateTime{}}, _now), do: dpgettext("moderation", "status: ban", "Lifted")

  def ban_status(ban, now) do
    if Ban.active?(ban, now),
      do: dpgettext("moderation", "status: ban", "Active"),
      else: dpgettext("moderation", "status: ban", "Expired")
  end

  @doc "Lifts the ban `params[\"id\"]` (sudo mode), then `reload`s the page on success or when it is gone."
  @spec lift_ban(Socket.t(), map(), (Socket.t() -> Socket.t())) ::
          Socket.t()
  def lift_ban(socket, %{"id" => id} = params, reload) do
    case Sanctions.lift_ban(socket.assigns.current_scope, id) do
      {:ok, _ban} -> socket |> reload.() |> put_flash(:info, ban_lifted_flash())
      {:error, :sudo_required} -> MythweaverWeb.Sudo.require(socket, "lift", params)
      {:error, :not_found} -> socket |> reload.() |> put_flash(:error, ban_gone_flash())
      {:error, :unauthorized} -> MythweaverWeb.Flash.flash_unauthorized(socket)
    end
  end

  defp ban_lifted_flash do
    gettext_comment("Flash after a moderator lifts a ban.")
    dpgettext("moderation", "status: a moderator lifted a ban", "Ban lifted")
  end

  defp ban_gone_flash do
    gettext_comment("Flash when a moderator tries to lift a ban that already ended or was lifted.")
    dgettext("moderation", "That ban is no longer in force")
  end

  @doc "The label of a moderation subject type (a lookup type, a report or a ban)."
  @spec subject_label(atom()) :: String.t()
  def subject_label(:user), do: dpgettext("moderation", "badge: type of moderated item", "Account")
  def subject_label(:chat), do: dpgettext("moderation", "badge: type of moderated item", "Chat")
  def subject_label(:message), do: dpgettext("moderation", "badge: type of moderated item", "Message")
  def subject_label(:listing), do: dpgettext("moderation", "badge: type of moderated item", "Catalog listing")
  def subject_label(:report), do: dpgettext("moderation", "badge: type of moderated item", "Report")
  def subject_label(:ban), do: dpgettext("moderation", "badge: type of moderated item", "Ban")
  def subject_label(:ai_provider), do: dpgettext("moderation", "badge: type of moderated item", "AI connection")
  def subject_label(:character), do: dpgettext("moderation", "badge: type of moderated item", "Character")
  def subject_label(:lore_book), do: dpgettext("moderation", "badge: type of moderated item", "Lore book")
  def subject_label(:lore_entry), do: dpgettext("moderation", "badge: type of moderated item", "Lore entry")
  def subject_label(:lore_pool), do: dpgettext("moderation", "badge: type of moderated item", "Lore pool")
  def subject_label(:prompt), do: dpgettext("moderation", "badge: type of moderated item", "Prompt")
  def subject_label(:block), do: dpgettext("moderation", "badge: type of moderated item", "Prompt block")
  def subject_label(:outlet), do: dpgettext("moderation", "badge: type of moderated item", "Outlet")
  def subject_label(:script), do: dpgettext("moderation", "badge: type of moderated item", "Script")
  def subject_label(:memory_profile), do: dpgettext("moderation", "badge: type of moderated item", "Memory profile")
  def subject_label(:side_prompt), do: dpgettext("moderation", "badge: type of moderated item", "Side prompt")

  def subject_label(:side_prompt_set), do: dpgettext("moderation", "badge: type of moderated item", "Side prompt set")

  def subject_label(:ai_model), do: dpgettext("moderation", "badge: type of moderated item", "AI model")

  def subject_label(:expression_profile),
    do: dpgettext("moderation", "badge: type of moderated item", "Expression profile")

  def subject_label(:import), do: dpgettext("moderation", "badge: type of moderated item", "Import")

  def subject_label(:moderation_rule), do: dpgettext("moderation", "badge: type of moderated item", "Moderation rule")

  @doc "Flashes why a moderator delete was refused."
  @spec delete_refused(Socket.t(), term()) :: Socket.t()
  def delete_refused(socket, :unauthorized), do: MythweaverWeb.Flash.flash_unauthorized(socket)
  def delete_refused(socket, reason), do: put_flash(socket, :error, delete_refused_text(reason))

  defp delete_refused_text(:site_row) do
    gettext_comment("Flash when a moderator tries to delete site content from the moderation panel.")
    dgettext("moderation", "Site content is managed in the site's editors")
  end

  defp delete_refused_text(:generating) do
    gettext_comment("Flash when a moderator tries to delete a chat or message while a reply is being generated.")
    dgettext("moderation", "Wait for the reply to finish")
  end

  defp delete_refused_text(:in_use) do
    gettext_comment("Flash when a moderator tries to delete content still used in its owner's chats.")
    dgettext("moderation", "It is in use in its owner's chats")
  end

  defp delete_refused_text(_reason) do
    gettext_comment("Flash when a moderator's delete (of an item or a rule) fails.")
    dpgettext("moderation", "status: deleting the item failed", "Could not delete it")
  end
end
