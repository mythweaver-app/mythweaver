defmodule MythweaverWeb.ModerationBanLive do
  @moduledoc """
  The bans page (`/moderation/bans`): one ban type's history at a time (`?kind=`, among the types the
  scope may list: `Mythweaver.Moderation.Sanctions.can_list?/2`), active bans only or every ban
  (`?state=all`), each liftable while in force (sudo mode).
  """
  use MythweaverWeb, :live_view

  alias Mythweaver.Moderation
  alias Mythweaver.Moderation.Ban
  alias Mythweaver.Moderation.Sanctions
  alias MythweaverWeb.ModerationNav

  on_mount {MythweaverWeb.UserAuth,
            {:require_any_permission, ["moderation.accounts.sanction", "moderation.fingerprints"]}}

  on_mount MythweaverWeb.Sudo

  @kinds %{"account" => :account, "device" => :device, "fingerprint" => :fingerprint, "ip" => :ip}
  @states %{"active" => :active, "all" => :all}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Moderation.subscribe()

    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(
       page_title: dpgettext("moderation", "page title: list of bans", "Bans"),
       kinds: Enum.filter(Ban.kinds(), &Sanctions.can_list?(scope, &1)),
       kind: nil,
       state: :active,
       now: DateTime.utc_now(:second),
       bans_empty?: true
     )
     |> stream_configure(:bans, dom_id: &"bans-#{&1.id}")
     |> stream(:bans, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    kinds = socket.assigns.kinds
    kind = Map.get(@kinds, params["kind"])
    kind = if kind in kinds, do: kind, else: List.first(kinds)
    state = Map.get(@states, params["state"], :active)

    {:noreply, socket |> assign(kind: kind, state: state) |> stream_bans()}
  end

  defp stream_bans(%{assigns: %{current_scope: scope, kind: kind, state: state}} = socket) do
    bans = Sanctions.list_bans(scope, kind, state)

    socket
    |> assign(bans_empty?: bans == [], now: DateTime.utc_now(:second))
    |> stream(:bans, bans, reset: true)
  end

  @impl true
  def handle_event("lift", params, socket), do: {:noreply, ModerationNav.lift_ban(socket, params, &stream_bans/1)}

  @impl true
  def handle_info({Moderation, :changed}, socket), do: {:noreply, stream_bans(socket)}

  defp bans_path(kind, state), do: ~p"/moderation/bans?#{[kind: kind, state: state]}"

  defp tab_label(:account), do: dpgettext("moderation", "tab: bans on whole accounts", "Accounts")
  defp tab_label(:device), do: dpgettext("moderation", "tab: bans on devices", "Devices")
  defp tab_label(:fingerprint), do: dpgettext("moderation", "tab: bans on browser fingerprints", "Browser fingerprints")
  defp tab_label(:ip), do: dpgettext("moderation", "tab: bans on IP addresses", "IP addresses")

  defp lift_confirm do
    gettext_comment("Confirm dialog before a moderator lifts a ban.")
    dpgettext("moderation", "heading: confirm dialog before lifting a ban", "Lift this ban?")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      div.moderation-bans:scope {
        flex: 1 1 auto;
        min-block-size: 0;
        overflow-y: auto;
        margin: var(--panel-gap);
        background: var(--card);
        border: 1px solid var(--border);
        border-radius: var(--radius-3);
        box-shadow: var(--elevation-lg);
      }

      .bans-body {
        display: flex;
        flex-direction: column;
        gap: var(--size-3);
        padding: var(--size-3);
      }

      .bans-list {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
        margin: 0;
        padding: 0;
        list-style: none;
      }

      .bans-row {
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
        padding: var(--size-3);
        border: 1px solid var(--border);
        border-radius: var(--radius-2);
        background: var(--card);
      }

      .bans-row-head {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        justify-content: space-between;
        gap: var(--size-2);
      }

      .bans-value {
        font-family: var(--font-monospace-code, ui-monospace, monospace);
        overflow-wrap: anywhere;
      }

      .bans-status {
        font-weight: 600;
      }

      .bans-reason {
        margin: 0;
        white-space: pre-wrap;
        overflow-wrap: anywhere;
      }

      .bans-meta {
        display: flex;
        flex-wrap: wrap;
        gap: var(--size-1) var(--size-3);
        color: var(--muted-foreground);
        font-size: 0.875rem;
      }

      .bans-empty {
        margin: 0;
        color: var(--muted-foreground);
      }
    </style>
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <ModerationNav.nav current_scope={@current_scope} active="bans" />
      <div class="moderation-bans">
        <.panel_header sticky>
          {dpgettext("moderation", "heading: list of bans", "Bans")}
          <:actions>
            <.button
              size="sm"
              patch={bans_path(@kind, if(@state == :active, do: :all, else: :active))}
              id="bans-state"
            >
              {if @state == :active,
                do:
                  dpgettext(
                    "moderation",
                    "button: show every ban, not only active ones",
                    "Show lifted and expired"
                  ),
                else: dpgettext("moderation", "button: show only bans in force", "Show active only")}
            </.button>
          </:actions>
        </.panel_header>

        <div class="bans-body">
          <.tabs
            id="bans"
            label={
              dpgettext(
                "moderation",
                "aria label: tabs choosing which kind of ban is listed",
                "Ban type"
              )
            }
            active={to_string(@kind)}
          >
            <:tab :for={kind <- @kinds} name={to_string(kind)} patch={bans_path(kind, @state)}>
              {tab_label(kind)}
            </:tab>
          </.tabs>

          <p :if={@bans_empty?} id="bans-empty" class="bans-empty">
            {if @state == :active,
              do: dpgettext("moderation", "empty state: no ban is in force", "No bans in force"),
              else: dpgettext("moderation", "empty state: no ban was ever issued", "No bans yet")}
          </p>
          <ul id="bans" class="bans-list" phx-update="stream">
            <li :for={{id, ban} <- @streams.bans} id={id} class="bans-row">
              <div class="bans-row-head">
                <span>
                  {ModerationNav.ban_kind_label(ban.kind)}
                  <span :if={ban.value} class="bans-value">{ban.value}</span>
                  <span :if={ban.user}>
                    ·
                    <.link navigate={~p"/moderation/users/#{ban.user.id}/record"} id={"#{id}-user"}>
                      {ModerationNav.handle(ban.user)}
                    </.link>
                  </span>
                  <span :if={!ban.user}>· {ModerationNav.handle(nil)}</span>
                </span>
                <span class="bans-status" id={"#{id}-status"}>{ModerationNav.ban_status(ban, @now)}</span>
              </div>
              <p class="bans-reason">{ban.reason}</p>
              <div class="bans-meta">
                <span>
                  {issued_by(ban.issued_by)}
                  <.local_time id={"#{id}-issued"} at={ban.inserted_at} format={:full} />
                </span>
                <span :if={ban.ends_at}>
                  {dpgettext(
                    "moderation",
                    "status: when a ban ends, followed by its date and time",
                    "Ends"
                  )}
                  <.local_time id={"#{id}-ends"} at={ban.ends_at} format={:full} />
                </span>
                <span :if={!ban.ends_at}>
                  {dpgettext("moderation", "status: a ban that never ends", "Permanent")}
                </span>
                <span :if={ban.lifted_at}>
                  {lifted_by(ban.lifted_by)}
                  <.local_time id={"#{id}-lifted"} at={ban.lifted_at} format={:full} />
                </span>
              </div>
              <div :if={Ban.active?(ban, @now)}>
                <.button
                  size="sm"
                  danger
                  id={"#{id}-lift"}
                  phx-click="lift"
                  phx-value-id={ban.id}
                  data-confirm={lift_confirm()}
                >
                  {dpgettext("moderation", "button: lift this ban", "Lift")}
                </.button>
              </div>
            </li>
          </ul>
        </div>
      </div>
      <MythweaverWeb.Sudo.modal :if={@sudo_prompt} prompt={@sudo_prompt} />
    </Layouts.app>
    """
  end

  defp issued_by(user) do
    gettext_comment(
      "Who issued a ban; the date and time it was issued follow. The handle may read \"a deleted account\"."
    )

    dpgettext("moderation", "status: who issued a ban", "Issued by %{account_handle}",
      account_handle: ModerationNav.handle(user)
    )
  end

  defp lifted_by(user) do
    gettext_comment(
      "Who lifted a ban; the date and time it was lifted follow. The handle may read \"a deleted account\"."
    )

    dpgettext("moderation", "status: who lifted a ban", "Lifted by %{account_handle}",
      account_handle: ModerationNav.handle(user)
    )
  end
end
