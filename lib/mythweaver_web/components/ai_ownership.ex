defmodule MythweaverWeb.AIOwnership do
  @moduledoc """
  Site-or-personal ownership controls shared by `MythweaverWeb.AIProviderLive` and
  `MythweaverWeb.AIModelLive`, after the lore book editor's: an Owner select on the new form (for a
  scope that may make either, `Mythweaver.AI.owner_choice?/1`), an owner line on an existing row
  with a move-to-site button on a personal one (for a `"site.ai.manage"` holder), the move's
  confirmation dialog with what it removes (`Mythweaver.AI.transfer_impact/3`), and the "Personal"
  list badge. A site row is never made personal. Components take `kind` (`:connection` | `:model`)
  and write each sentence per kind.

  The LiveView keeps `new_owner` (`"site"` | `"personal"`) and `transfer` (nil or
  `%{warnings:, blocked:}`) assigns, mounts `MythweaverWeb.Sudo`, and handles
  `"prepare_transfer"`, `"cancel_transfer"` and `"transfer"` through `prepare/2` and `run/4`.
  """
  use MythweaverWeb, :html

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.AI.Model
  alias Mythweaver.Format

  @doc "The new form's Owner choice from its params."
  def owner_choice(%{"owner" => "site"}), do: "site"
  def owner_choice(_params), do: "personal"

  @doc "Whether a list row gets the Personal badge: the viewer sees site rows beside its own."
  def personal_badge?(%{user_id: user_id}, scope), do: user_id != nil and Scope.can?(scope, "site.ai.manage")

  @doc "Assigns the dialog moving `row` to the site, or flashes why not."
  def prepare(socket, row) do
    case AI.transfer_impact(socket.assigns.current_scope, row, :site) do
      {:ok, {impact, taken}} ->
        Phoenix.Component.assign(socket, transfer: %{warnings: warnings(row, impact), blocked: taken})

      {:error, _reason} ->
        flash_unauthorized(socket)
    end
  end

  @doc """
  Runs the prepared move of `row`; on success clears the dialog and patches to `path.(moved)`. A
  missing sudo mode opens the password prompt and keeps the dialog, so confirming replays `event`.
  """
  def run(socket, row, path, params \\ %{}) do
    case AI.transfer(socket.assigns.current_scope, row, :site) do
      {:ok, moved} ->
        socket
        |> Phoenix.Component.assign(transfer: nil)
        |> Phoenix.LiveView.put_flash(:info, moved_flash(moved.name))
        |> Phoenix.LiveView.push_patch(to: path.(moved))

      {:error, :sudo_required} ->
        MythweaverWeb.Sudo.require(socket, "transfer", params)

      {:error, {:name_taken, names}} ->
        socket
        |> Phoenix.Component.assign(transfer: nil)
        |> Phoenix.LiveView.put_flash(:error, name_taken_flash(names))

      {:error, _reason} ->
        socket |> Phoenix.Component.assign(transfer: nil) |> flash_unauthorized()
    end
  end

  defp moved_flash(name) do
    gettext_comment("Flash after a personal AI connection or model was moved to the site.")
    dgettext("ai", "%{row_name} is now the site's", row_name: name)
  end

  defp name_taken_flash(names) do
    gettext_comment(
      "Flash when moving a personal AI connection or model to the site fails because the site already has rows with these names. %{row_names} is a list of names."
    )

    dgettext("ai", "The site already has %{row_names}: rename first", row_names: Format.list(names))
  end

  # One line per kind the move changes; kinds it leaves alone say nothing.
  defp warnings(row, impact) do
    [
      {impact.models, &moved_models_warning/1},
      {impact.links, if(match?(%Model{}, row), do: &model_links_warning/1, else: &provider_links_warning/1)},
      {impact.caption_models, &caption_models_warning/1}
    ]
    |> Enum.reject(fn {count, _text} -> count == 0 end)
    |> Enum.map(fn {count, text} -> text.(count) end)
  end

  defp moved_models_warning(count),
    do:
      dngettext(
        "ai",
        "Models linked to it move with it: %{model_count}.",
        "Models linked to it move with it: %{model_count}.",
        count, model_count: Format.number(count))

  defp model_links_warning(count),
    do:
      dngettext(
        "ai",
        "Its links to connections are removed (link it again to a site connection): %{link_count}.",
        "Its links to connections are removed (link it again to a site connection): %{link_count}.",
        count, link_count: Format.number(count))

  defp provider_links_warning(count),
    do:
      dngettext(
        "ai",
        "Those models' links to other connections are removed: %{link_count}.",
        "Those models' links to other connections are removed: %{link_count}.",
        count, link_count: Format.number(count))

  defp caption_models_warning(count),
    do:
      dngettext(
        "ai",
        "Caption model choices that are not the site's are cleared: %{model_count}.",
        "Caption model choices that are not the site's are cleared: %{model_count}.",
        count, model_count: Format.number(count))

  attr :id, :string, required: true
  attr :value, :string, required: true
  attr :kind, :atom, required: true, values: [:connection, :model]

  @doc "The new form's Owner select."
  def owner_select(assigns) do
    ~H"""
    <.input
      name="owner"
      value={@value}
      type="select"
      label={dpgettext("ai", "field label: who owns a new AI connection or model", "Owner")}
      id={@id}
      options={[
        {dpgettext("ai", "option: owner of a new AI connection or model", "Personal (only me)"),
         "personal"},
        {dpgettext("ai", "option: owner of a new AI connection or model", "Site (every user)"),
         "site"}
      ]}
    >
      <:hint>{owner_hint(@kind)}</:hint>
    </.input>
    """
  end

  defp owner_hint(:connection),
    do:
      dgettext(
        "ai",
        "A personal connection is yours alone: no other user, admin or not, sees or runs it. A site connection is there for every user allowed to use the site's AI, and only site managers edit it. You can make a personal one the site's later from its editor."
      )

  defp owner_hint(:model),
    do:
      dgettext(
        "ai",
        "A personal model is yours alone: no other user, admin or not, sees or runs it. A site model is there for every user allowed to use the site's AI, and only site managers edit it. You can make a personal one the site's later from its editor."
      )

  attr :id, :string, required: true
  attr :row, :map, required: true
  attr :kind, :atom, required: true, values: [:connection, :model]

  @doc "An existing row's owner, and on a personal row its move-to-site button."
  def owner_line(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      div.ai-owner:scope {
        display: flex;
        align-items: center;
        gap: var(--size-3);
        color: var(--muted-foreground);
      }
    </style>
    <div id={@id} class="ai-owner">
      <span id={"#{@id}-label"}>{owner_text(@kind, @row.user_id != nil)}</span>
      <.button
        :if={@row.user_id}
        type="button"
        size="sm"
        id={"#{@id}-transfer"}
        phx-click="prepare_transfer"
      >
        {make_site_label(@kind)}
      </.button>
    </div>
    """
  end

  defp owner_text(:connection, true), do: dgettext("ai", "Personal connection: only you see and run it.")

  defp owner_text(:connection, false),
    do: dgettext("ai", "Site connection: every user allowed to use the site's AI can run it.")

  defp owner_text(:model, true), do: dgettext("ai", "Personal model: only you see and run it.")

  defp owner_text(:model, false), do: dgettext("ai", "Site model: every user allowed to use the site's AI can run it.")

  defp make_site_label(:connection),
    do: dpgettext("ai", "button: move a personal AI connection to the site", "Make site connection")

  defp make_site_label(:model), do: dpgettext("ai", "button: move a personal AI model to the site", "Make site model")

  attr :id, :string, required: true
  attr :transfer, :map, required: true
  attr :row, :map, required: true
  attr :kind, :atom, required: true, values: [:connection, :model]

  @doc "The move's confirmation dialog."
  def transfer_modal(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS}>
      /* A root tag of `<.modal>`'s slot: it carries this block's marker, so it is a scope root. */
      div:scope.ai-transfer-actions {
        display: flex;
        justify-content: flex-end;
        gap: var(--size-2);
      }
    </style>
    <.modal id={@id} title={transfer_title(@kind)} on_cancel="cancel_transfer">
      <p>
        {dgettext(
          "ai",
          "Every user allowed to use the site's AI will be able to run %{row_name}; only site managers will edit it.",
          row_name: @row.name
        )}
      </p>
      <p :if={@transfer.blocked != []} id={"#{@id}-blocked"}>{blocked_text(@transfer.blocked)}</p>
      <p :if={@transfer.warnings != []}>
        {dpgettext(
          "ai",
          "heading: list of what moving a row to the site also changes",
          "This also changes:"
        )}
      </p>
      <ul id={"#{@id}-warnings"}>
        <li :for={warning <- @transfer.warnings}>{warning}</li>
      </ul>
      <p>{no_way_back_text(@kind)}</p>
      <div class="ai-transfer-actions">
        <.button
          type="button"
          id={"#{@id}-cancel"}
          phx-click={JS.dispatch("modal:close", to: "##{@id}")}
        >
          {dpgettext("ai", "button: close the move-to-site dialog without moving", "Cancel")}
        </.button>
        <.button
          type="button"
          variant="primary"
          danger
          id={"#{@id}-confirm"}
          phx-click="transfer"
          disabled={@transfer.blocked != []}
        >
          {make_site_label(@kind)}
        </.button>
      </div>
    </.modal>
    """
  end

  defp transfer_title(:connection),
    do:
      dpgettext(
        "ai",
        "heading: dialog confirming a personal AI connection's move to the site",
        "Make this a site connection?"
      )

  defp transfer_title(:model),
    do: dpgettext("ai", "heading: dialog confirming a personal AI model's move to the site", "Make this a site model?")

  defp blocked_text(names) do
    gettext_comment("%{row_names} is a list of names the site already uses.")
    dgettext("ai", "The site already has %{row_names}. Rename first.", row_names: Format.list(names))
  end

  defp no_way_back_text(:connection), do: dgettext("ai", "A site connection cannot be made personal again.")
  defp no_way_back_text(:model), do: dgettext("ai", "A site model cannot be made personal again.")
end
