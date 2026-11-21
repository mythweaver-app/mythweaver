defmodule MythweaverWeb.SharePanel do
  @moduledoc """
  The Sharing section of a shareable item's editor (`Mythweaver.Sharing`). The owner invites
  accounts by handle as editors or subscribers (Runtime-only or Readable), switches a subscriber's
  visibility, and removes any share after seeing what the removal takes from that user's own content
  (`Mythweaver.Sharing.impact/2`). An editor sees the owner and the other shares, invites Runtime-only
  subscribers and removes subscribers. Renders nothing for a site item or a viewer the item is not
  shared with.

  An AI model's shares also carry an AI mode: the subscriber runs it on their own connection (the
  default, and all an editor may invite), or on the owner's ("My connection", offered only to an owner
  holding `"sharing.ai.owner_key"`) with an optional daily token limit. The owner switches both per
  share (`Mythweaver.Sharing.set_ai_mode/4`).

  The owner of a personal root item that can be published (`Mythweaver.Catalog.types/0`), holding
  `"catalog.publish"`, also gets a Catalog section: unpublished, a Publish form (title, summary,
  comma-separated tags, visibility; `Catalog.publish/3`); published, a link to the listing, its
  visibility (`Catalog.set_visibility/3`), a New release with notes (`Catalog.release/3`) and
  Unpublish after seeing what it takes from subscribers' content (`Catalog.unpublish_impact/2`,
  `Catalog.unpublish/2`).

  Attrs: `id`, `current_scope`, `item`. Every `update/2` reloads the share list and the listing, so
  the host's re-render on a `Mythweaver.Changes` broadcast keeps it current.
  """

  use MythweaverWeb, :live_component

  import MythweaverWeb.Pane

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.Catalog
  alias Mythweaver.Format
  alias Mythweaver.Sharing
  alias Mythweaver.Sharing.Fallout
  alias Mythweaver.Sharing.Items

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       confirming: nil,
       ai_mode_error: nil,
       invite_form: invite_form(),
       publish_form: nil,
       release_form: release_form(),
       unpublishing: nil
     )}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(id: assigns.id, current_scope: assigns.current_scope, item: assigns.item)
     |> load()}
  end

  defp load(socket) do
    %{current_scope: scope, item: item} = socket.assigns
    owner? = owner?(scope, item)
    shares = Sharing.list_shares(scope, item)
    editor? = !owner? and shares != [] and Sharing.granted?(scope.user.id, item, [:edit])
    ai? = Items.type_of(item) == :ai_model

    catalog? =
      owner? and Items.type_of(item) in Catalog.types() and is_nil(item.frozen_listing_id) and
        Scope.can?(scope, "catalog.publish")

    socket
    |> assign(
      owner?: owner?,
      editor?: editor?,
      ai?: ai?,
      owner_key?: ai? and owner? and Scope.can?(scope, "sharing.ai.owner_key"),
      can_invite?: (owner? or editor?) and Scope.can?(scope, "sharing.invite"),
      shares: shares,
      show?: not is_nil(item.user_id) and (owner? or shares != []),
      owner: if(!(owner? or is_nil(item.user_id)), do: Accounts.get_user(item.user_id)),
      catalog?: catalog?,
      listing: if(catalog?, do: Catalog.listing_for(item))
    )
    |> assign_new_publish_form()
  end

  defp assign_new_publish_form(%{assigns: %{publish_form: nil, item: item}} = socket),
    do: assign(socket, publish_form: publish_form(%{"title" => item.name}))

  defp assign_new_publish_form(socket), do: socket

  @blank_publish %{"title" => "", "summary" => "", "tags" => "", "visibility" => "runtime_only"}

  defp publish_form(params, errors \\ [])
  defp publish_form(params, []), do: to_form(Map.merge(@blank_publish, params), as: :listing)

  defp publish_form(params, errors),
    do: to_form(Map.merge(@blank_publish, params), as: :listing, errors: errors, action: :validate)

  defp release_form, do: to_form(%{"notes" => ""}, as: :release)

  defp publish_attrs(params) do
    %{
      title: params["title"],
      summary: params["summary"],
      tags: params |> Map.get("tags", "") |> String.split(","),
      visibility: visibility(params["visibility"])
    }
  end

  defp owner?(%Scope{user: %User{id: uid}}, %{user_id: uid}) when is_binary(uid), do: true
  defp owner?(_scope, _item), do: false

  @blank_invite %{
    "handle" => "",
    "role" => "editor",
    "visibility" => "runtime_only",
    "ai_mode" => "own_key",
    "token_limit" => ""
  }

  defp invite_form(params \\ @blank_invite, errors \\ [])
  defp invite_form(params, []), do: to_form(Map.merge(@blank_invite, params), as: :share)

  defp invite_form(params, errors),
    do: to_form(Map.merge(@blank_invite, params), as: :share, errors: errors, action: :validate)

  # An editor may only invite Runtime-only own-key subscribers, whatever the params say.
  defp invite_opts(%{owner?: true, ai?: ai?}, params) do
    opts = [role: role(params["role"]), visibility: visibility(params["visibility"])]

    case ai? && ai_mode_args(params["ai_mode"], params["token_limit"]) do
      false -> {:ok, opts}
      {:ok, mode, limit} -> {:ok, opts ++ [ai_mode: mode, token_limit_per_day: limit]}
      :error -> :error
    end
  end

  defp invite_opts(_assigns, _params), do: {:ok, [role: :subscriber, visibility: :runtime_only]}

  # `{:ok, mode, limit}`, the limit only with the owner's key; `:error` for a limit that isn't a
  # positive whole number.
  defp ai_mode_args("owner_key", limit) do
    limit
    |> to_string()
    |> String.trim()
    |> case do
      "" -> {:ok, :owner_key, nil}
      text -> if n = positive_integer(text), do: {:ok, :owner_key, n}, else: :error
    end
  end

  defp ai_mode_args(_mode, _limit), do: {:ok, :own_key, nil}

  defp positive_integer(text) do
    case Integer.parse(text) do
      {n, ""} when n > 0 -> n
      _invalid -> nil
    end
  end

  defp token_limit_error, do: dgettext_noop("errors", "must be a whole number above 0")

  defp role("subscriber"), do: :subscriber
  defp role(_role), do: :editor

  defp visibility("readable"), do: :readable
  defp visibility(_visibility), do: :runtime_only

  @impl true
  def handle_event("invite_change", %{"share" => params}, socket) do
    {:noreply, assign(socket, invite_form: invite_form(params))}
  end

  def handle_event("invite", %{"share" => %{"handle" => handle} = params}, socket) do
    %{current_scope: scope, item: item} = socket.assigns

    with {:ok, opts} <- invite_opts(socket.assigns, params),
         {:ok, _share} <- Sharing.invite(scope, item, handle, opts) do
      {:noreply, socket |> assign(invite_form: invite_form(Map.put(params, "handle", ""))) |> load()}
    else
      :error ->
        {:noreply, assign(socket, invite_form: invite_form(params, token_limit: {token_limit_error(), []}))}

      {:error, reason} ->
        {:noreply, assign(socket, invite_form: invite_form(params, handle: {invite_error(reason), []}))}
    end
  end

  def handle_event("set_visibility", %{"share_id" => id, "visibility" => value}, socket) do
    # `{:error, _}`: gone or no longer a subscriber share; the reload shows that.
    _ = Sharing.set_visibility(socket.assigns.current_scope, id, visibility(value))
    {:noreply, load(socket)}
  end

  def handle_event("set_ai_mode", %{"share_id" => id, "ai_mode" => mode} = params, socket) do
    error =
      case ai_mode_args(mode, params["token_limit"]) do
        {:ok, mode, limit} ->
          # `{:error, :not_found}`: gone elsewhere; the reload shows that.
          case Sharing.set_ai_mode(socket.assigns.current_scope, id, mode, limit) do
            {:error, :unauthorized} -> {id, dgettext("sharing", "You can't share your connection.")}
            _result -> nil
          end

        :error ->
          {id, dgettext("sharing", "The daily limit must be a whole number above 0.")}
      end

    {:noreply, socket |> assign(ai_mode_error: error) |> load()}
  end

  def handle_event("prepare_remove", %{"id" => id}, socket) do
    case Sharing.impact(socket.assigns.current_scope, id) do
      {:ok, impact} -> {:noreply, assign(socket, confirming: {id, impact})}
      {:error, :not_found} -> {:noreply, socket |> assign(confirming: nil) |> load()}
    end
  end

  def handle_event("cancel_remove", _params, socket) do
    {:noreply, assign(socket, confirming: nil)}
  end

  def handle_event("remove", %{"id" => id}, socket) do
    # `{:error, :not_found}`: already gone elsewhere; the reload shows that too.
    _ = Sharing.remove(socket.assigns.current_scope, id)
    {:noreply, socket |> assign(confirming: nil) |> load()}
  end

  def handle_event("publish", %{"listing" => params}, socket) do
    %{current_scope: scope, item: item} = socket.assigns

    case Catalog.publish(scope, item, publish_attrs(params)) do
      {:ok, _listing} ->
        {:noreply, socket |> assign(publish_form: nil) |> load()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, publish_form: publish_form(params, changeset.errors))}

      {:error, _reason} ->
        {:noreply,
         assign(socket,
           publish_form: publish_form(params, title: {dgettext_noop("errors", "You can't publish this."), []})
         )}
    end
  end

  def handle_event("release", %{"release" => %{"notes" => notes}}, socket) do
    notes = if String.trim(notes) != "", do: notes

    socket =
      case socket.assigns.listing && Catalog.release(socket.assigns.current_scope, socket.assigns.listing, notes) do
        {:ok, listing} -> put_flash(socket, :info, released_flash(listing.current_release.version))
        _ -> put_flash(socket, :error, release_failed_flash())
      end

    {:noreply, socket |> assign(release_form: release_form()) |> load()}
  end

  def handle_event("set_listing_visibility", %{"visibility" => value}, socket) do
    # `{:error, _}`: unpublished elsewhere; the reload shows that.
    _ =
      socket.assigns.listing &&
        Catalog.set_visibility(socket.assigns.current_scope, socket.assigns.listing, visibility(value))

    {:noreply, load(socket)}
  end

  def handle_event("prepare_unpublish", _params, socket) do
    case socket.assigns.listing && Catalog.unpublish_impact(socket.assigns.current_scope, socket.assigns.listing) do
      {:ok, impact} -> {:noreply, assign(socket, unpublishing: impact)}
      _ -> {:noreply, socket |> assign(unpublishing: nil) |> load()}
    end
  end

  def handle_event("cancel_unpublish", _params, socket) do
    {:noreply, assign(socket, unpublishing: nil)}
  end

  def handle_event("unpublish", _params, socket) do
    # `{:error, _}`: already unpublished elsewhere; the reload shows that too.
    _ = socket.assigns.listing && Catalog.unpublish(socket.assigns.current_scope, socket.assigns.listing)
    {:noreply, socket |> assign(unpublishing: nil, publish_form: nil) |> load()}
  end

  defp released_flash(version) do
    gettext_comment("Flash after the owner publishes a new release of their catalog listing.")

    dpgettext("sharing", "status: new catalog release published", "Released version %{version_number}",
      version_number: Format.number(version)
    )
  end

  defp release_failed_flash do
    gettext_comment("Flash when publishing a new release of a catalog listing fails.")
    dpgettext("sharing", "status: publishing a catalog release failed", "Could not release this")
  end

  defp invite_error(:unknown_handle), do: dgettext_noop("errors", "No account has that handle.")
  defp invite_error(:self), do: dgettext_noop("errors", "That's you.")
  defp invite_error(:already_shared), do: dgettext_noop("errors", "Already shared with them.")
  defp invite_error(:quota_exceeded), do: dgettext_noop("errors", "Too many invites are waiting for an answer.")
  defp invite_error(:unauthorized), do: dgettext_noop("errors", "You can't share this.")

  defp impact_sentence(_user, impact) when map_size(impact) == 0, do: dgettext("sharing", "Nothing of theirs uses it.")

  defp impact_sentence(user, impact) do
    gettext_comment(
      "Confirmation before removing a share. %{impact_list} is a list of counted things, e.g. \"2 chat participants and 1 tag\"."
    )

    dgettext("sharing", "Also removes from @%{user_handle}'s content: %{impact_list}.",
      user_handle: user.handle,
      impact_list: impact_list(impact)
    )
  end

  defp unpublish_sentence(impact) when map_size(impact) == 0,
    do: dgettext("sharing", "No subscriber's content uses it.")

  defp unpublish_sentence(impact) do
    gettext_comment(
      "Confirmation before unpublishing a catalog listing. %{impact_list} is a list of counted things, e.g. \"2 chat participants and 1 tag\"."
    )

    dgettext("sharing", "Also removes from its subscribers' content: %{impact_list}.", impact_list: impact_list(impact))
  end

  defp impact_list(impact) do
    impact
    |> Enum.sort()
    |> Enum.map(fn {kind, n} -> Fallout.label(kind, n) end)
    |> Format.list()
  end

  defp status_text(:pending), do: dpgettext("sharing", "status: share invite not yet answered", "Pending")
  defp status_text(:declined), do: dpgettext("sharing", "status: share invite the invitee declined", "Declined")
  defp status_text(:accepted), do: nil

  defp role_text(:editor), do: dpgettext("sharing", "badge: share role that may edit the item", "Editor")
  defp role_text(:subscriber), do: dpgettext("sharing", "badge: share role that may only use the item", "Subscriber")

  defp visibility_text(:readable), do: readable_label()
  defp visibility_text(:runtime_only), do: runtime_only_label()

  defp readable_label, do: dpgettext("sharing", "option: shared item visibility, contents can be inspected", "Readable")
  defp runtime_only_label, do: dpgettext("sharing", "option: shared item visibility, use only", "Runtime-only")

  defp visibility_options, do: [{runtime_only_label(), "runtime_only"}, {readable_label(), "readable"}]

  defp ai_mode_text(:owner_key, true = _owner?), do: my_connection_label()

  defp ai_mode_text(:owner_key, false),
    do: dpgettext("sharing", "status: shared AI model runs on its owner's connection", "Owner's connection")

  defp ai_mode_text(_own_key, _owner?), do: their_connection_label()

  defp my_connection_label,
    do: dpgettext("sharing", "option: shared AI model runs on the viewer's (owner's) connection", "My connection")

  defp their_connection_label,
    do: dpgettext("sharing", "option: shared AI model runs on the subscriber's own connection", "Their own connection")

  defp no_limit_label, do: dpgettext("sharing", "status: shared AI model without a daily token limit", "No daily limit")

  defp limit_text(nil), do: no_limit_label()

  defp limit_text(limit),
    do:
      dpngettext(
        "sharing",
        "status: daily token limit of a shared AI model",
        "Daily limit: %{token_limit} token",
        "Daily limit: %{token_limit} tokens",
        limit, token_limit: Format.number(limit))

  defp ai_mode_meta(share, owner?) do
    if share.ai_mode == :owner_key,
      do:
        dpgettext("sharing", "status: AI mode of a share, then its daily limit", "%{ai_mode} · %{daily_limit}",
          ai_mode: ai_mode_text(share.ai_mode, owner?),
          daily_limit: limit_text(share.token_limit_per_day)
        ),
      else: ai_mode_text(share.ai_mode, owner?)
  end

  defp listing_meta(listing) do
    n = listing.subscriber_count

    if release = listing.current_release do
      dpngettext(
        "sharing",
        "status: catalog listing's current version and subscriber total",
        "v%{version_number} · %{subscriber_count} subscriber",
        "v%{version_number} · %{subscriber_count} subscribers",
        n,
        version_number: Format.number(release.version),
        subscriber_count: Format.number(n)
      )
    else
      dpngettext(
        "sharing",
        "status: catalog listing's subscriber total",
        "%{subscriber_count} subscriber",
        "%{subscriber_count} subscribers",
        n,
        subscriber_count: Format.number(n)
      )
    end
  end

  # "My connection" needs `"sharing.ai.owner_key"`; a share already on it keeps the option, so a
  # withdrawn permission still shows where it stands.
  defp ai_mode_options(owner_key?, mode) do
    [{their_connection_label(), "own_key"}] ++
      if owner_key? or mode == :owner_key, do: [{my_connection_label(), "owner_key"}], else: []
  end

  # The owner switches a share's AI mode while they may offer their key, or to take a share off it.
  defp ai_mode_editable?(owner?, owner_key?, share), do: owner? and (owner_key? or share.ai_mode == :owner_key)

  defp removable?(owner?, editor?, share), do: owner? or (editor? and share.role == :subscriber)

  # An editor's form always invites Runtime-only; the owner's when Subscriber is picked and Readable is not.
  defp runtime_only_invite?(false = _owner?, _form), do: true
  defp runtime_only_invite?(true, form), do: form[:role].value == "subscriber" and form[:visibility].value != "readable"

  defp invite_label(false = _owner?, _form), do: invite_subscriber_label()

  defp invite_label(true, form),
    do:
      if(form[:role].value == "subscriber",
        do: invite_subscriber_label(),
        else: dpgettext("sharing", "button: invite the account as an editor of this item", "Invite as editor")
      )

  defp invite_subscriber_label,
    do: dpgettext("sharing", "button: invite the account as a subscriber of this item", "Invite subscriber")

  defp remove_label(%{status: :pending}),
    do: dpgettext("sharing", "button: withdraw a pending share invite", "Cancel invite")

  defp remove_label(_share), do: dpgettext("sharing", "button: end this share", "Remove")

  defp unpublish_label, do: dpgettext("sharing", "button: remove this item's listing from the catalog", "Unpublish")

  defp listing_visibility_label, do: dpgettext("sharing", "field label: visibility of a catalog listing", "Visibility")

  @impl true
  def render(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      .share-panel-list {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
        margin: 0;
        padding: 0;
        list-style: none;
      }

      .share-panel-row {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: var(--size-2);
        padding: 0;
      }

      .share-panel-meta {
        color: var(--muted-foreground);
        font-size: 0.875rem;
      }

      .share-panel-who {
        flex: 1;
        min-inline-size: 0;
      }

      .share-panel-confirm {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: var(--size-2);
        flex-basis: 100%;
        margin: 0;
      }

      .share-panel-invite {
        display: flex;
        flex-wrap: wrap;
        align-items: flex-start;
        gap: var(--size-2);

        & > .input-wrapper:first-child {
          flex: 1;
          min-inline-size: 12rem;
        }
      }

      .share-panel-hint {
        margin: var(--size-1) 0 0;
        color: var(--muted-foreground);
        font-size: 0.875rem;
      }

      .share-panel-catalog {
        display: flex;
        flex-direction: column;
        gap: var(--size-2);
      }

      .share-panel-visibility {
        margin: 0;
      }

      .share-panel-ai-mode {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: var(--size-2);
        margin: 0;
      }
    </style>
    <div class="share-panel">
      <.pane_section :if={@show?} id={@id}>
        <.section_header>
          {dpgettext("sharing", "heading: sharing section of an item editor", "Sharing")}
        </.section_header>
        <p :if={@owner} id={"#{@id}-owner"}>
          {dpgettext(
            "sharing",
            "status: owner of a shared item, with their handle",
            "Owned by %{owner_name} (@%{owner_handle})",
            owner_name: User.display_name(@owner),
            owner_handle: @owner.handle
          )}
        </p>
        <.form
          :if={@can_invite?}
          for={@invite_form}
          id={"#{@id}-invite"}
          phx-change="invite_change"
          phx-submit="invite"
          phx-target={@myself}
        >
          <div class="share-panel-invite">
            <.input
              field={@invite_form[:handle]}
              type="text"
              id={"#{@id}-invite-handle"}
              placeholder={
                dpgettext("sharing", "placeholder: account handle to share with", "@handle")
              }
              autocomplete="off"
            />
            <.input
              :if={@owner?}
              field={@invite_form[:role]}
              type="select"
              id={"#{@id}-invite-role"}
              aria-label={
                dpgettext(
                  "sharing",
                  "aria label: select for the invited account's share role",
                  "Role"
                )
              }
              options={[
                {dpgettext("sharing", "option: share role that may edit the item", "Editor"),
                 "editor"},
                {dpgettext("sharing", "option: share role that may only use the item", "Subscriber"),
                 "subscriber"}
              ]}
            />
            <.input
              :if={@owner? and @invite_form[:role].value == "subscriber"}
              field={@invite_form[:visibility]}
              type="select"
              id={"#{@id}-invite-visibility"}
              aria-label={
                dpgettext(
                  "sharing",
                  "aria label: select for the invited subscriber's visibility",
                  "Visibility"
                )
              }
              options={[
                {dpgettext(
                   "sharing",
                   "option: share visibility, use only",
                   "Runtime-only (use only)"
                 ), "runtime_only"},
                {dpgettext(
                   "sharing",
                   "option: share visibility, contents can be inspected",
                   "Readable (can inspect and export)"
                 ), "readable"}
              ]}
            />
            <.input
              :if={@owner? and @ai?}
              field={@invite_form[:ai_mode]}
              type="select"
              id={"#{@id}-invite-ai_mode"}
              aria-label={dgettext("sharing", "Whose connection their runs use")}
              options={ai_mode_options(@owner_key?, nil)}
            />
            <.input
              :if={@owner? and @ai? and @invite_form[:ai_mode].value == "owner_key"}
              field={@invite_form[:token_limit]}
              type="number"
              min="1"
              id={"#{@id}-invite-token_limit"}
              aria-label={
                dpgettext(
                  "sharing",
                  "aria label: daily token limit field of a shared AI model",
                  "Daily token limit"
                )
              }
              placeholder={
                dpgettext(
                  "sharing",
                  "placeholder: optional daily token limit of a shared AI model",
                  "Tokens per day (optional)"
                )
              }
            />
            <.button type="submit" variant="primary">{invite_label(@owner?, @invite_form)}</.button>
          </div>
          <p
            :if={not @ai? and runtime_only_invite?(@owner?, @invite_form)}
            id={"#{@id}-invite-hint"}
            class="share-panel-hint"
          >
            {dgettext(
              "sharing",
              "The model still receives the content, so careful prompting can coax it into repeating parts of it."
            )}
          </p>
        </.form>
        <ul id={"#{@id}-list"} class="share-panel-list">
          <li :for={share <- @shares} id={"#{@id}-#{share.id}"} class="share-panel-row">
            <span class="share-panel-who">
              {User.display_name(share.user)}
              <span class="share-panel-meta">@{share.user.handle}</span>
            </span>
            <span class="share-panel-meta">{role_text(share.role)}</span>
            <span :if={share.role == :subscriber and not @owner?} class="share-panel-meta">
              {visibility_text(share.visibility)}
            </span>
            <form
              :if={share.role == :subscriber and @owner?}
              id={"#{@id}-visibility-form-#{share.id}"}
              class="share-panel-visibility"
              phx-change="set_visibility"
              phx-target={@myself}
            >
              <input type="hidden" name="share_id" value={share.id} />
              <.input
                type="select"
                name="visibility"
                id={"#{@id}-visibility-#{share.id}"}
                aria-label={
                  dpgettext(
                    "sharing",
                    "aria label: visibility select of one subscriber share",
                    "Visibility for @%{user_handle}",
                    user_handle: share.user.handle
                  )
                }
                value={share.visibility}
                options={visibility_options()}
              />
            </form>
            <span
              :if={@ai? and not ai_mode_editable?(@owner?, @owner_key?, share)}
              id={"#{@id}-ai-mode-text-#{share.id}"}
              class="share-panel-meta"
            >
              {ai_mode_meta(share, @owner?)}
            </span>
            <form
              :if={@ai? and ai_mode_editable?(@owner?, @owner_key?, share)}
              id={"#{@id}-ai-mode-#{share.id}"}
              class="share-panel-ai-mode"
              phx-change="set_ai_mode"
              phx-target={@myself}
            >
              <input type="hidden" name="share_id" value={share.id} />
              <.input
                type="select"
                name="ai_mode"
                id={"#{@id}-ai-mode-#{share.id}-mode"}
                aria-label={
                  dgettext("sharing", "Whose connection @%{user_handle}'s runs use",
                    user_handle: share.user.handle
                  )
                }
                value={share.ai_mode}
                options={ai_mode_options(@owner_key?, share.ai_mode)}
              />
              <.input
                :if={share.ai_mode == :owner_key}
                type="number"
                name="token_limit"
                min="1"
                id={"#{@id}-ai-mode-#{share.id}-limit"}
                aria-label={
                  dgettext("sharing", "Daily token limit for @%{user_handle}",
                    user_handle: share.user.handle
                  )
                }
                placeholder={no_limit_label()}
                value={share.token_limit_per_day}
                phx-debounce="blur"
              />
            </form>
            <p
              :if={match?({id, _} when id == share.id, @ai_mode_error)}
              id={"#{@id}-ai-mode-error-#{share.id}"}
              class="share-panel-confirm"
              role="alert"
            >
              {elem(@ai_mode_error, 1)}
            </p>
            <span :if={status_text(share.status)} class="share-panel-meta">
              {status_text(share.status)}
            </span>
            <.button
              :if={removable?(@owner?, @editor?, share)}
              size="sm"
              id={"#{@id}-remove-#{share.id}"}
              phx-click="prepare_remove"
              phx-value-id={share.id}
              phx-target={@myself}
            >
              {remove_label(share)}
            </.button>
            <p
              :if={
                removable?(@owner?, @editor?, share) &&
                  match?({id, _} when id == share.id, @confirming)
              }
              class="share-panel-confirm"
            >
              <span>{impact_sentence(share.user, elem(@confirming, 1))}</span>
              <.button
                size="sm"
                danger
                id={"#{@id}-confirm-#{share.id}"}
                phx-click="remove"
                phx-value-id={share.id}
                phx-target={@myself}
              >
                {remove_label(share)}
              </.button>
              <.button size="sm" phx-click="cancel_remove" phx-target={@myself}>
                {dpgettext(
                  "sharing",
                  "button: keep the share, dismiss the removal confirmation",
                  "Cancel"
                )}
              </.button>
            </p>
          </li>
        </ul>
      </.pane_section>
      <.pane_section :if={@catalog?} id={"#{@id}-catalog"}>
        <.section_header>
          {dpgettext("sharing", "heading: catalog publishing section of an item editor", "Catalog")}
        </.section_header>
        <.form
          :if={is_nil(@listing)}
          for={@publish_form}
          id={"#{@id}-publish"}
          class="share-panel-catalog"
          phx-submit="publish"
          phx-target={@myself}
        >
          <.input
            field={@publish_form[:title]}
            type="text"
            label={dpgettext("sharing", "field label: title of a catalog listing", "Title")}
            id={"#{@id}-publish-title"}
          />
          <.editor
            field={@publish_form[:summary]}
            label={dpgettext("sharing", "field label: summary of a catalog listing", "Summary")}
            id={"#{@id}-publish-summary"}
          />
          <.input
            field={@publish_form[:tags]}
            type="text"
            label={
              dpgettext("sharing", "field label: comma-separated tags of a catalog listing", "Tags")
            }
            id={"#{@id}-publish-tags"}
            placeholder={
              dpgettext(
                "sharing",
                "placeholder: example tags of a catalog listing",
                "fantasy, sci-fi"
              )
            }
            autocomplete="off"
          />
          <.input
            field={@publish_form[:visibility]}
            type="select"
            label={listing_visibility_label()}
            id={"#{@id}-publish-visibility"}
            options={[
              {dpgettext("sharing", "option: share visibility, use only", "Runtime-only (use only)"),
               "runtime_only"},
              {dpgettext(
                 "sharing",
                 "option: catalog listing visibility, contents can be inspected",
                 "Readable (can inspect, clone and export)"
               ), "readable"}
            ]}
          />
          <p class="share-panel-hint">
            {dgettext(
              "sharing",
              "Anyone can subscribe to a published copy; each new release updates it for them."
            )}
          </p>
          <div>
            <.button type="submit" variant="primary">
              <.lucide name="store" /> {dpgettext(
                "sharing",
                "button: publish this item to the catalog",
                "Publish"
              )}
            </.button>
          </div>
        </.form>
        <div :if={@listing} class="share-panel-catalog">
          <p id={"#{@id}-listing"} class="share-panel-row">
            <.link navigate={~p"/catalog/#{@listing.id}"}>{@listing.title}</.link>
            <span class="share-panel-meta">
              {listing_meta(@listing)}
            </span>
          </p>
          <form
            id={"#{@id}-catalog-visibility"}
            class="share-panel-visibility"
            phx-change="set_listing_visibility"
            phx-target={@myself}
          >
            <.input
              type="select"
              name="visibility"
              label={listing_visibility_label()}
              id={"#{@id}-catalog-visibility-select"}
              value={@listing.visibility}
              options={visibility_options()}
            />
          </form>
          <.form
            for={@release_form}
            id={"#{@id}-release"}
            class="share-panel-catalog"
            phx-submit="release"
            phx-target={@myself}
          >
            <.editor
              field={@release_form[:notes]}
              label={
                dpgettext("sharing", "field label: notes of a new catalog release", "Release notes")
              }
              id={"#{@id}-release-notes"}
            />
            <div>
              <.button type="submit" variant="primary">
                {dpgettext(
                  "sharing",
                  "button: publish a new release of the catalog listing",
                  "New release"
                )}
              </.button>
            </div>
          </.form>
          <div>
            <.button
              size="sm"
              danger
              id={"#{@id}-unpublish"}
              phx-click="prepare_unpublish"
              phx-target={@myself}
            >
              {unpublish_label()}
            </.button>
          </div>
          <p :if={@unpublishing} id={"#{@id}-unpublish-confirm"} class="share-panel-confirm">
            <span>{unpublish_sentence(@unpublishing)}</span>
            <.button
              size="sm"
              danger
              id={"#{@id}-unpublish-confirm-button"}
              phx-click="unpublish"
              phx-target={@myself}
            >
              {unpublish_label()}
            </.button>
            <.button size="sm" phx-click="cancel_unpublish" phx-target={@myself}>
              {dpgettext(
                "sharing",
                "button: keep the listing, dismiss the unpublish confirmation",
                "Cancel"
              )}
            </.button>
          </p>
        </div>
      </.pane_section>
    </div>
    """
  end
end
