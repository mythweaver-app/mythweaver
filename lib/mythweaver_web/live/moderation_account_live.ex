defmodule MythweaverWeb.ModerationAccountLive do
  @moduledoc """
  An account's moderation record (`/moderation/users/:id/record`): who the account is and whether it
  is suspended, the reports about it, its warnings and bans with the forms that issue them, the
  IPs, browsers and devices it was seen with, and the other accounts sharing them. Each section shows
  only to a holder of its key; opening the page needs any of `Mythweaver.Moderation.record_keys/0`,
  and only owners open an owner's record. Every open is written to the moderation log.

  The reports page links here with `?report=<id>`; a warning or ban issued from the page then
  resolves that report. Bans ask for the password first (`MythweaverWeb.Sudo`).
  """
  use MythweaverWeb, :live_view

  import MythweaverWeb.Pane

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.Format
  alias Mythweaver.Moderation
  alias Mythweaver.Moderation.Ban
  alias Mythweaver.Moderation.Fingerprints
  alias Mythweaver.Moderation.GeoIP
  alias Mythweaver.Moderation.Log
  alias Mythweaver.Moderation.Reports
  alias Mythweaver.Moderation.Sanctions
  alias MythweaverWeb.ModerationNav
  alias MythweaverWeb.UserAuth

  on_mount {MythweaverWeb.UserAuth, {:require_any_permission, Mythweaver.Moderation.record_keys()}}
  on_mount MythweaverWeb.Sudo

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope

    case fetch_user(scope, id) do
      {:ok, user} ->
        if connected?(socket), do: Moderation.subscribe()

        {:ok,
         socket
         |> assign(user: user, page_title: User.display_name(user), report_id: nil)
         |> assign(geoip?: GeoIP.enabled?())
         |> stream_configure(:reports, dom_id: &"account-reports-#{&1.id}")
         |> stream_configure(:ban_values, dom_id: &"ban-form-values-#{&1.id}")
         |> stream_configure(:linked, dom_id: &"linked-#{&1.user.id}")
         |> assign(warn_form: warn_form(), ban_form: ban_form())
         |> load()
         |> load_ban_choices()
         |> MythweaverWeb.LiveSync.attach([:accounts], fn socket, _kinds -> reload_record(socket) end)}

      {:error, message} ->
        {:ok, socket |> put_flash(:error, message) |> push_navigate(to: ~p"/moderation/lookup")}
    end
  end

  defp fetch_user(scope, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %User{} = user <- Accounts.get_user(id) do
      case Moderation.authorize_record(scope, user) do
        :ok -> {:ok, user}
        {:error, :unauthorized} -> {:error, MythweaverWeb.Flash.unauthorized_message()}
      end
    else
      _ -> {:error, account_not_found_flash()}
    end
  end

  defp account_not_found_flash do
    gettext_comment("Flash when a moderator opens the record of an account that does not exist.")
    dpgettext("moderation", "status: the account in the link does not exist", "Account not found")
  end

  @impl true
  def handle_params(params, _uri, %{assigns: %{user: user}} = socket) do
    if connected?(socket) do
      :ok = Log.record(socket.assigns.current_scope, :viewed, :user, user.id, user.id, %{"page" => "record"})
    end

    {:noreply, assign(socket, report_id: report_id(params["report"]))}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  defp report_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  defp report_id(_id), do: nil

  @impl true
  def handle_info({Moderation, :changed}, socket), do: {:noreply, reload_record(socket)}

  defp reload_record(socket) do
    case fetch_user(socket.assigns.current_scope, socket.assigns.user.id) do
      {:ok, user} -> socket |> assign(user: user) |> load()
      {:error, message} -> socket |> put_flash(:error, message) |> push_navigate(to: ~p"/moderation/lookup")
    end
  end

  # Everything but the ban form's choices, which reload only after a ban so a moderator's
  # ticked boxes survive other moderators' actions.
  defp load(socket) do
    scope = socket.assigns.current_scope
    user = socket.assigns.user
    can? = &Scope.can?(scope, &1)
    sanction? = can?.("moderation.accounts.sanction")
    fingerprints? = can?.("moderation.fingerprints")

    reports = if can?.("moderation.reports"), do: Reports.about_user(scope, user.id), else: []
    warnings = if sanction?, do: Sanctions.warnings_for(user.id), else: []
    bans = Sanctions.bans_for(user.id)
    fingerprints = if fingerprints?, do: Fingerprints.for_user(user.id), else: []
    linked = if fingerprints?, do: Fingerprints.linked_accounts(user.id), else: []
    now = DateTime.utc_now(:second)
    shown_bans = if sanction? or fingerprints?, do: bans, else: []

    socket
    |> assign(
      account_ban: Enum.find(bans, &(&1.kind == :account and Ban.active?(&1, now))),
      sanctionable?: Moderation.sanctionable(scope, user) == :ok,
      sanction_note: sanction_note(Moderation.sanctionable(scope, user)),
      now: now,
      reports_empty?: reports == [],
      warnings_empty?: warnings == [],
      bans_empty?: shown_bans == [],
      fingerprints_empty?: fingerprints == [],
      linked_empty?: linked == []
    )
    |> stream(:reports, reports, reset: true)
    |> stream(:warnings, warnings, reset: true)
    |> stream(:bans, shown_bans, reset: true)
    |> stream(:fingerprints, fingerprints, reset: true)
    |> stream(:linked, linked, reset: true)
  end

  defp load_ban_choices(socket) do
    values =
      if Scope.can?(socket.assigns.current_scope, "moderation.fingerprints"),
        do: Fingerprints.recent(socket.assigns.user.id),
        else: []

    socket
    |> assign(ban_values_empty?: values == [])
    |> stream(:ban_values, values, reset: true)
  end

  # Why the warn and ban forms are missing, when they are.
  defp sanction_note({:error, :self}),
    do: dgettext("moderation", "This is your own account: you can't warn or ban yourself.")

  defp sanction_note({:error, :owner}), do: dgettext("moderation", "Owners can't be warned or banned.")
  defp sanction_note(_result), do: nil

  defp warn_form(params \\ %{"reason" => ""}, opts \\ []), do: to_form(params, [as: :warn] ++ opts)

  defp ban_form(params \\ %{"reason" => "", "duration" => "7d", "account" => "false"}, opts \\ []),
    do: to_form(params, [as: :ban] ++ opts)

  @impl true
  def handle_event("validate_warn", %{"warn" => params}, socket) do
    {:noreply, assign(socket, warn_form: warn_form(params))}
  end

  def handle_event("warn", %{"warn" => params}, socket) do
    %{current_scope: scope, user: user, report_id: report_id} = socket.assigns

    case Sanctions.warn(scope, user, params["reason"] || "", report_id) do
      {:ok, _warning} ->
        UserAuth.disconnect_users([user])
        {:noreply, socket |> load() |> assign(warn_form: warn_form()) |> put_flash(:info, warned_flash())}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, warn_form: warn_form(params, errors: changeset.errors, action: :validate))}

      {:error, reason} ->
        {:noreply, refuse(socket, reason)}
    end
  end

  def handle_event("validate_ban", %{"ban" => params}, socket) do
    {:noreply, assign(socket, ban_form: ban_form(params))}
  end

  def handle_event("ban", %{"ban" => params} = event_params, socket) do
    %{current_scope: scope, user: user, report_id: report_id} = socket.assigns

    case Sanctions.ban(scope, user, Map.put(params, "report_id", report_id)) do
      {:ok, %{tokens: tokens}} ->
        UserAuth.disconnect_sessions(tokens)

        {:noreply,
         socket
         |> load()
         |> load_ban_choices()
         |> assign(ban_form: ban_form())
         |> put_flash(:info, banned_flash())}

      {:error, :sudo_required} ->
        {:noreply, MythweaverWeb.Sudo.require(socket, "ban", event_params)}

      {:error, %Ecto.Changeset{} = changeset} ->
        errors = Enum.map(changeset.errors, fn {field, error} -> {ban_field(field), error} end)
        {:noreply, assign(socket, ban_form: ban_form(params, errors: errors, action: :validate))}

      {:error, reason} ->
        {:noreply, refuse(socket, reason)}
    end
  end

  def handle_event("lift", params, socket), do: {:noreply, ModerationNav.lift_ban(socket, params, &load/1)}

  defp ban_field(:ends_at), do: :duration
  defp ban_field(field), do: field

  defp warned_flash do
    gettext_comment("Flash after a moderator sends an account a warning.")
    dpgettext("moderation", "status: a moderator sent a warning", "Warning sent")
  end

  defp banned_flash do
    gettext_comment("Flash after a moderator bans an account or its devices and addresses.")
    dpgettext("moderation", "status: a moderator issued a ban", "Banned")
  end

  defp refuse(socket, reason) when reason in [:no_targets, :own_signal, :unknown_value, :self, :owner],
    do: put_flash(socket, :error, refusal(reason))

  defp refuse(socket, _reason), do: flash_unauthorized(socket)

  defp refusal(:no_targets) do
    gettext_comment("Flash when a moderator submits the ban form without choosing anything to ban.")
    dgettext("moderation", "Choose the account or at least one device or address")
  end

  defp refusal(:own_signal) do
    gettext_comment("Flash when a moderator tries to ban a device or address they use themselves.")
    dgettext("moderation", "You share one of those, so you would ban yourself")
  end

  defp refusal(:unknown_value) do
    gettext_comment("Flash when a device or address chosen in the ban form is no longer on record.")
    dgettext("moderation", "That device or address is no longer on record")
  end

  defp refusal(:self) do
    gettext_comment("Flash when a moderator tries to warn or ban their own account.")
    dgettext("moderation", "You can't sanction your own account")
  end

  defp refusal(:owner) do
    gettext_comment("Flash when a moderator tries to warn or ban an owner.")
    dpgettext("moderation", "status: owners cannot be warned or banned", "Owners can't be sanctioned")
  end

  defp active_tab(scope), do: if(Scope.can?(scope, "users.manage"), do: "users", else: "lookup")

  defp match_label(%{kind: :ip, value: value} = match, geoip?) do
    case geoip? && GeoIP.label(match[:geo]) do
      label when is_binary(label) ->
        dpgettext(
          "moderation",
          "status: an IP address two accounts share, with its place",
          "IP %{ip_address} (%{place_name})",
          ip_address: value,
          place_name: label
        )

      _ ->
        dpgettext("moderation", "status: an IP address two accounts share", "IP %{ip_address}", ip_address: value)
    end
  end

  defp match_label(%{kind: :device, value: value}, _geoip?) do
    gettext_comment("The placeholder is the last six characters of the device id.")

    dpgettext("moderation", "status: a device two accounts share", "Device …%{device_id_end}",
      device_id_end: String.slice(value, -6, 6)
    )
  end

  defp match_label(%{kind: :fingerprint, value: value}, _geoip?) do
    gettext_comment("The placeholder is the last six characters of the browser fingerprint.")

    dpgettext(
      "moderation",
      "status: a browser fingerprint two accounts share",
      "Browser fingerprint …%{fingerprint_end}",
      fingerprint_end: String.slice(value, -6, 6)
    )
  end

  defp fingerprint_kind_label(:ip),
    do: dpgettext("moderation", "badge: kind of value an account was seen with", "IP address")

  defp fingerprint_kind_label(:user_agent),
    do: dpgettext("moderation", "badge: kind of value an account was seen with", "Browser")

  defp fingerprint_kind_label(:language),
    do: dpgettext("moderation", "badge: kind of value an account was seen with", "Language")

  defp fingerprint_kind_label(:device),
    do: dpgettext("moderation", "badge: kind of value an account was seen with", "Device")

  defp fingerprint_kind_label(:fingerprint),
    do:
      dpgettext(
        "moderation",
        "badge: kind of value an account was seen with",
        "Browser fingerprint (identical devices share it)"
      )

  # A ban form choice: the kind of value, then the value itself.
  defp ban_value_text(%{kind: :ip, value: value}),
    do: dpgettext("moderation", "option: an IP address to ban", "IP address: %{ip_address}", ip_address: value)

  defp ban_value_text(%{kind: :user_agent, value: value}),
    do: dpgettext("moderation", "option: a browser to ban", "Browser: %{user_agent}", user_agent: value)

  defp ban_value_text(%{kind: :language, value: value}),
    do:
      dpgettext("moderation", "option: a browser language to ban", "Language: %{browser_language}",
        browser_language: value
      )

  defp ban_value_text(%{kind: :device, value: value}),
    do: dpgettext("moderation", "option: a device to ban", "Device: %{device_id}", device_id: value)

  defp ban_value_text(%{kind: :fingerprint, value: value}),
    do:
      dpgettext(
        "moderation",
        "option: a browser fingerprint to ban",
        "Browser fingerprint (identical devices share it): %{fingerprint}", fingerprint: value)

  # A report's subject type, then the start of the reported text.
  defp report_subject(%{subject_type: type, snapshot: snapshot}) do
    excerpt = String.slice(snapshot, 0, 80)

    case type do
      :listing ->
        dpgettext("moderation", "status: a reported catalog listing and its text", "Listing: %{reported_text}",
          reported_text: excerpt
        )

      :user ->
        dpgettext("moderation", "status: a reported account and its text", "Account: %{reported_text}",
          reported_text: excerpt
        )

      :message ->
        dpgettext("moderation", "status: a reported chat message and its text", "Message: %{reported_text}",
          reported_text: excerpt
        )
    end
  end

  defp report_status(:open), do: dpgettext("moderation", "status: report", "Open")
  defp report_status(:dismissed), do: dpgettext("moderation", "status: report", "Dismissed")
  defp report_status(:actioned), do: dpgettext("moderation", "status: report", "Actioned")

  defp lift_confirm do
    gettext_comment("Confirm dialog before a moderator lifts a ban.")
    dpgettext("moderation", "heading: confirm dialog before lifting a ban", "Lift this ban?")
  end

  @impl true
  def render(assigns) do
    scope = assigns.current_scope
    can? = &Scope.can?(scope, &1)
    sanction? = can?.("moderation.accounts.sanction")
    fingerprints? = can?.("moderation.fingerprints")

    assigns =
      assign(assigns,
        active: active_tab(scope),
        reports?: can?.("moderation.reports"),
        sanction?: sanction?,
        fingerprints?: fingerprints?,
        bans?: sanction? or fingerprints?,
        manage?: can?.("users.manage"),
        content?: can?.("moderation.content.view"),
        log?: can?.("moderation.log.view"),
        account_choice?: sanction? and assigns.sanctionable?,
        duration_options: Sanctions.duration_options()
      )

    ~H"""
    <%!-- `lower-bound="none"`: the sections' content sits in `<.pane_section>` slots. --%>
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      div.account-record:scope {
        flex: 1 1 auto;
        min-height: 0;
        overflow-y: auto;
        margin: var(--panel-gap);
        background: var(--card);
        border: 1px solid var(--border);
        border-radius: var(--radius-3);
        box-shadow: var(--elevation-lg);
      }

      .account-facts {
        display: grid;
        grid-template-columns: max-content 1fr;
        gap: var(--size-1) var(--size-3);
        margin: 0;
      }

      .account-facts dt {
        margin: 0;
        color: var(--muted-foreground);
      }

      .account-facts dd {
        margin: 0;
        overflow-wrap: anywhere;
      }

      .account-list {
        list-style: none;
        margin: 0;
        padding: 0;
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .account-row {
        display: flex;
        flex-wrap: wrap;
        align-items: baseline;
        gap: var(--size-1) var(--size-3);
        padding-block-end: var(--size-2);
        border-block-end: 1px solid var(--border);
      }

      .account-row-main {
        flex: 1 1 20rem;
        min-inline-size: 0;
        overflow-wrap: anywhere;
      }

      .account-row-meta {
        color: var(--muted-foreground);
        font-size: var(--font-size-0);
      }

      .account-text {
        margin: 0;
        white-space: pre-wrap;
      }

      .account-empty {
        margin: 0;
        color: var(--muted-foreground);
      }

      .account-form {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .account-values {
        display: flex;
        flex-direction: column;
        gap: var(--size-1);
        margin: 0;
        padding: var(--size-2);
        border: 1px solid var(--border);
        border-radius: var(--radius-2);
      }

      .account-value {
        display: flex;
        gap: var(--size-2);
        align-items: baseline;
        overflow-wrap: anywhere;
      }

      .account-form-submit {
        align-self: flex-start;
      }
    </style>

    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <MythweaverWeb.ModerationNav.nav current_scope={@current_scope} active={@active} />
      <div class="account-record">
        <.panel_header sticky>
          {User.display_name(@user)}
          <:actions>
            <.button
              :if={@manage?}
              size="sm"
              id="account-edit"
              navigate={~p"/moderation/users/#{@user.id}/edit"}
            >
              <.lucide name="pencil" /> {dpgettext(
                "moderation",
                "button: edit this account's settings",
                "Edit account"
              )}
            </.button>
            <.button
              :if={@content?}
              size="sm"
              id="account-content"
              navigate={~p"/moderation/users/#{@user.id}/data"}
            >
              <.lucide name="folder-open" />
              {dpgettext("moderation", "button: open this account's chats and content", "Content")}
            </.button>
            <.button
              :if={@log?}
              size="sm"
              id="account-log"
              navigate={~p"/moderation/log?user=#{@user.id}"}
            >
              <.lucide name="scroll-text" />
              {dpgettext(
                "moderation",
                "button: open the moderation log filtered to this account",
                "Moderation log"
              )}
            </.button>
          </:actions>
        </.panel_header>
        <.pane_section id="account-summary">
          <dl class="account-facts">
            <dt>{dpgettext("moderation", "field label: an account's handle", "Handle")}</dt>
            <dd>@{@user.handle}</dd>
            <dt>{dpgettext("moderation", "field label: an account's email address", "Email")}</dt>
            <dd>{@user.email}</dd>
            <dt>{dpgettext("moderation", "field label: an account's role", "Role")}</dt>
            <dd>
              {if @user.role == :owner,
                do: dpgettext("moderation", "status: account role", "Owner"),
                else: dpgettext("moderation", "status: account role", "User")}
            </dd>
            <dt>{dpgettext("moderation", "field label: when an account was created", "Joined")}</dt>
            <dd><.local_time id="account-joined" at={@user.inserted_at} format={:full} /></dd>
            <dt>
              {dpgettext("moderation", "field label: whether an account is suspended", "Status")}
            </dt>
            <dd id="account-status">
              <%= cond do %>
                <% is_nil(@account_ban) -> %>
                  {dpgettext("moderation", "status: account not suspended", "Active")}
                <% is_nil(@account_ban.ends_at) -> %>
                  {dpgettext(
                    "moderation",
                    "status: account suspended for good",
                    "Suspended permanently"
                  )}
                <% true -> %>
                  {dpgettext(
                    "moderation",
                    "status: account suspended, followed by the date and time it ends",
                    "Suspended until"
                  )}
                  <.local_time id="account-status-until" at={@account_ban.ends_at} format={:full} />
              <% end %>
            </dd>
          </dl>
        </.pane_section>

        <.pane_section :if={@reports?} id="account-reports">
          <.section_header>
            {dpgettext(
              "moderation",
              "heading: reports about the account on its record",
              "Reports about this account"
            )}
          </.section_header>
          <p :if={@reports_empty?} id="account-reports-empty" class="account-empty">
            {dpgettext("moderation", "empty state: no reports about the account", "No reports")}
          </p>
          <ul id="account-reports-list" class="account-list" phx-update="stream">
            <li :for={{dom_id, report} <- @streams.reports} id={dom_id} class="account-row">
              <div class="account-row-main">
                <.link :if={report.status == :open} navigate={~p"/moderation/reports/#{report.id}"}>
                  {report_subject(report)}
                </.link>
                <span :if={report.status != :open}>
                  {report_subject(report)}
                </span>
                <p class="account-text">{report.reason}</p>
              </div>
              <span class="account-row-meta">
                {ModerationNav.handle(report.reporter)} ·
                <.local_time id={"#{dom_id}-at"} at={report.inserted_at} />
                · {report_status(report.status)}
              </span>
            </li>
          </ul>
        </.pane_section>

        <.pane_section :if={@sanction?} id="account-warnings">
          <.section_header>
            {dpgettext("moderation", "heading: warnings an account got", "Warnings")}
          </.section_header>
          <p :if={@warnings_empty?} id="account-warnings-empty" class="account-empty">
            {dpgettext("moderation", "empty state: the account has no warnings", "No warnings")}
          </p>
          <ul id="account-warnings-list" class="account-list" phx-update="stream">
            <li :for={{dom_id, warning} <- @streams.warnings} id={dom_id} class="account-row">
              <p class="account-text account-row-main">{warning.reason}</p>
              <span class="account-row-meta">
                {ModerationNav.handle(warning.issued_by)} ·
                <.local_time id={"#{dom_id}-at"} at={warning.inserted_at} /> ·
                <%= if warning.acknowledged_at do %>
                  {dpgettext(
                    "moderation",
                    "status: warning read, followed by the date and time it was read",
                    "Acknowledged"
                  )}
                  <.local_time id={"#{dom_id}-acknowledged"} at={warning.acknowledged_at} />
                <% else %>
                  {dpgettext("moderation", "status: warning not read yet", "Not yet acknowledged")}
                <% end %>
              </span>
            </li>
          </ul>
          <p :if={@sanction_note} id="account-warnings-note" class="account-empty">
            {@sanction_note}
          </p>
          <.form
            :if={@sanctionable?}
            for={@warn_form}
            id="warn-form"
            class="account-form"
            phx-change="validate_warn"
            phx-submit="warn"
          >
            <.editor
              field={@warn_form[:reason]}
              id="warn-form-reason"
              label={dpgettext("moderation", "field label: text of a warning to send", "Warning")}
            />
            <.button type="submit" variant="primary" class="account-form-submit">
              {dpgettext("moderation", "button: send the warning to the account", "Warn")}
            </.button>
          </.form>
        </.pane_section>

        <.pane_section :if={@bans?} id="account-bans">
          <.section_header>
            {dpgettext("moderation", "heading: list of bans", "Bans")}
          </.section_header>
          <p :if={@bans_empty?} id="account-bans-empty" class="account-empty">
            {dpgettext("moderation", "empty state: the account has no bans", "No bans")}
          </p>
          <ul id="account-bans-list" class="account-list" phx-update="stream">
            <li :for={{dom_id, ban} <- @streams.bans} id={dom_id} class="account-row">
              <div class="account-row-main">
                <strong>{ModerationNav.ban_kind_label(ban.kind)}</strong>
                <span :if={ban.value}>{ban.value}</span>
                <p class="account-text">{ban.reason}</p>
              </div>
              <span class="account-row-meta">
                {ModerationNav.handle(ban.issued_by)} ·
                <.local_time id={"#{dom_id}-at"} at={ban.inserted_at} /> ·
                <%= if ban.ends_at do %>
                  {dpgettext(
                    "moderation",
                    "status: when a ban ends, followed by its date and time",
                    "Ends"
                  )}
                  <.local_time id={"#{dom_id}-ends"} at={ban.ends_at} />
                <% else %>
                  {dpgettext("moderation", "status: a ban that never ends", "Permanent")}
                <% end %>
                · {ModerationNav.ban_status(ban, @now)}
              </span>
              <.button
                :if={Ban.active?(ban, @now) and Sanctions.can_list?(@current_scope, ban.kind)}
                size="sm"
                id={"#{dom_id}-lift"}
                phx-click="lift"
                phx-value-id={ban.id}
                data-confirm={lift_confirm()}
              >
                {dpgettext("moderation", "button: lift this ban", "Lift")}
              </.button>
            </li>
          </ul>

          <p :if={@sanction_note} id="account-bans-note" class="account-empty">{@sanction_note}</p>
          <.form
            :if={@sanctionable? and (@account_choice? or (@fingerprints? and not @ban_values_empty?))}
            for={@ban_form}
            id="ban-form"
            class="account-form"
            phx-change="validate_ban"
            phx-submit="ban"
          >
            <.editor
              field={@ban_form[:reason]}
              id="ban-form-reason"
              label={dpgettext("moderation", "field label: reason for a ban", "Reason")}
            />
            <.input
              field={@ban_form[:duration]}
              type="select"
              id="ban-form-duration"
              label={dpgettext("moderation", "field label: how long a ban lasts", "For")}
              options={@duration_options}
            />
            <.input
              :if={@account_choice?}
              field={@ban_form[:account]}
              type="checkbox"
              id="ban-form-account"
              label={dpgettext("moderation", "toggle: ban the whole account", "Suspend the account")}
            />
            <fieldset
              :if={@fingerprints?}
              id="ban-form-values"
              class="account-values"
              phx-hook="RangeSelect"
            >
              <legend>
                {dgettext("moderation", "Devices and addresses seen in the last 30 days")}
              </legend>
              <div id="ban-form-values-list" phx-update="stream">
                <label
                  :for={{dom_id, fingerprint} <- @streams.ban_values}
                  id={dom_id}
                  class="account-value"
                >
                  <input
                    type="checkbox"
                    name="ban[values][]"
                    value={"#{fingerprint.kind}:#{fingerprint.value}"}
                    id={"ban-form-value-#{fingerprint.id}"}
                    data-range-id={fingerprint.id}
                    class="input-check"
                  />
                  <span>
                    {ban_value_text(fingerprint)}<span :if={@geoip? and GeoIP.label(fingerprint.geo)}> · {GeoIP.label(
                      fingerprint.geo
                    )}</span>
                    <span class="account-row-meta">
                      {dpgettext(
                        "moderation",
                        "status: when a device or address was last seen, followed by its date and time",
                        "Last seen"
                      )}
                      <.local_time id={"#{dom_id}-seen"} at={fingerprint.last_seen_at} />
                    </span>
                  </span>
                </label>
              </div>
            </fieldset>
            <.button type="submit" danger class="account-form-submit">
              {dpgettext("moderation", "button: ban the chosen account, devices and addresses", "Ban")}
            </.button>
          </.form>
        </.pane_section>

        <.pane_section :if={@fingerprints?} id="account-fingerprints">
          <.section_header>
            {dpgettext(
              "moderation",
              "heading: devices and addresses an account was seen with",
              "Seen with"
            )}
          </.section_header>
          <p :if={@fingerprints_empty?} id="account-fingerprints-empty" class="account-empty">
            {dpgettext(
              "moderation",
              "empty state: no devices or addresses on record for the account",
              "Nothing on record"
            )}
          </p>
          <ul id="account-fingerprints-list" class="account-list" phx-update="stream">
            <li :for={{dom_id, fingerprint} <- @streams.fingerprints} id={dom_id} class="account-row">
              <div class="account-row-main">
                <strong>{fingerprint_kind_label(fingerprint.kind)}</strong> {fingerprint.value}
              </div>
              <span
                :if={@geoip? and GeoIP.label(fingerprint.geo)}
                id={"#{dom_id}-geo"}
                class="account-row-meta"
              >
                {GeoIP.label(fingerprint.geo)}
              </span>
              <span class="account-row-meta">
                {dpgettext(
                  "moderation",
                  "status: when a device or address was first seen, followed by its date and time",
                  "First"
                )}
                <.local_time id={"#{dom_id}-first"} at={fingerprint.first_seen_at} />
                · {dpgettext(
                  "moderation",
                  "status: when a device or address was last seen, followed by its date and time",
                  "Last"
                )}
                <.local_time id={"#{dom_id}-last"} at={fingerprint.last_seen_at} />
                · {seen_count(fingerprint.seen_count)}
              </span>
            </li>
          </ul>
          <p :if={@geoip?} id="account-geoip-attribution" class="account-empty">
            {GeoIP.attribution()}
          </p>
        </.pane_section>

        <.pane_section :if={@fingerprints?} id="account-linked">
          <.section_header>
            {dpgettext(
              "moderation",
              "heading: other accounts sharing a device or address with this one",
              "Accounts sharing these"
            )}
          </.section_header>
          <p :if={@linked_empty?} id="account-linked-empty" class="account-empty">
            {dpgettext(
              "moderation",
              "empty state: no other account shares a device or address",
              "No other accounts"
            )}
          </p>
          <ul id="account-linked-list" class="account-list" phx-update="stream">
            <li :for={{dom_id, link} <- @streams.linked} id={dom_id} class="account-row">
              <div class="account-row-main">
                <.link navigate={~p"/moderation/users/#{link.user.id}/record"}>
                  {User.display_name(link.user)} (@{link.user.handle})
                </.link>
                <span :for={match <- link.matches}> · {match_label(match, @geoip?)}</span>
              </div>
              <span class="account-row-meta">
                {dpgettext(
                  "moderation",
                  "status: when two accounts last shared a device or address, followed by its date and time",
                  "Last shared"
                )}
                <.local_time id={"#{dom_id}-seen"} at={hd(link.matches).last_seen_at} />
              </span>
            </li>
          </ul>
        </.pane_section>
      </div>
      <MythweaverWeb.Sudo.modal :if={@sudo_prompt} prompt={@sudo_prompt} />
    </Layouts.app>
    """
  end

  defp seen_count(count) do
    dpgettext("moderation", "unit: how many times an account was seen with a device or address", "%{seen_count}×",
      seen_count: Format.number(count)
    )
  end
end
