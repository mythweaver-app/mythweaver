defmodule MythweaverWeb.HandOff do
  @moduledoc """
  An item editor's Delete button (`Mythweaver.Sharing.hand_off_or/4`). For an item without accepted
  editors it is the plain confirmed Delete, sending `"delete"` (with `phx-value-id`) to the host. With
  editors the item is not deleted but given away: the button opens `#<thing>-handoff-modal`, a select
  of the editors (`#<thing>-handoff-to`, the oldest preselected) and "Give and remove from my account"
  (`#<thing>-handoff-confirm`), which calls `delete` with `to:`, flashes "Given to @handle" and patches
  to `index`.

  Attrs: `id`, `thing` (the id prefix, e.g. `"character"`), `current_scope`, `item`, `delete` (the
  context's `delete_*/3`), `index` (the path after a hand-off), `delete_id` (the button's id) and
  `confirm` (the plain delete's question). Every `update/2` reloads the editors.
  """

  use MythweaverWeb, :live_component

  import MythweaverWeb.Pane

  alias Mythweaver.Sharing
  alias Phoenix.LiveView.Socket

  @impl true
  def mount(socket), do: {:ok, assign(socket, open?: false, error: nil, form: nil)}

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(Map.take(assigns, [:id, :thing, :current_scope, :item, :delete, :index, :delete_id, :confirm]))
     |> load()}
  end

  defp load(socket), do: assign(socket, editors: Sharing.editors(socket.assigns.item))

  @impl true
  def handle_event("open", _params, socket) do
    socket = load(socket)

    case socket.assigns.editors do
      [] ->
        {:noreply, socket}

      [oldest | _] ->
        {:noreply, assign(socket, open?: true, error: nil, form: to_form(%{"to" => oldest.id}, as: :hand_off))}
    end
  end

  def handle_event("close", _params, socket), do: {:noreply, assign(socket, open?: false, error: nil)}

  def handle_event("confirm", %{"hand_off" => %{"to" => to} = params}, socket) do
    %{current_scope: scope, item: item, delete: delete, index: index} = socket.assigns

    case delete.(scope, item, to: to) do
      {:ok, {:handed_off, user}} ->
        {:noreply, socket |> assign(open?: false) |> put_flash(:info, given_flash(user)) |> push_patch(to: index)}

      {:ok, _deleted} ->
        {:noreply,
         socket |> assign(open?: false) |> put_flash(:info, deleted_flash(item.name)) |> push_patch(to: index)}

      {:error, {:needs_share, prompt}} ->
        error =
          case Enum.find(socket.assigns.editors, &(&1.id == to)) do
            nil ->
              dgettext("sharing", "Share “%{prompt_name}” with them first.", prompt_name: prompt.name)

            editor ->
              dgettext("sharing", "Share “%{prompt_name}” with %{user_handle} first.",
                prompt_name: prompt.name,
                user_handle: "@" <> editor.handle
              )
          end

        {:noreply, assign(socket, error: error, form: to_form(params, as: :hand_off))}

      {:error, _reason} ->
        {:noreply, socket |> assign(open?: false) |> load() |> flash_unauthorized()}
    end
  end

  defp label(%{nickname: nil, handle: handle}), do: "@#{handle}"
  defp label(%{nickname: nickname, handle: handle}), do: "#{nickname} (@#{handle})"

  @doc """
  The host's plain `"delete"` result for the item named `name`: flashes and patches to `index` once
  it is gone, deleted or (should an editor have accepted meanwhile) given to its oldest editor.
  """
  @spec after_delete(Socket.t(), {:ok, term()} | {:error, term()}, String.t(), String.t()) ::
          Socket.t()
  def after_delete(socket, {:ok, {:handed_off, user}}, _name, index),
    do: socket |> put_flash(:info, given_flash(user)) |> push_patch(to: index)

  def after_delete(socket, {:ok, _deleted}, name, index),
    do: socket |> put_flash(:info, deleted_flash(name)) |> push_patch(to: index)

  def after_delete(socket, {:error, {:needs_share, prompt}}, _name, _index) do
    gettext_comment("Flash when deleting hands an item to an editor who cannot use one of its prompts yet.")

    put_flash(
      socket,
      :error,
      dgettext("sharing", "Share “%{prompt_name}” with its editor first.", prompt_name: prompt.name)
    )
  end

  def after_delete(socket, {:error, _reason}, _name, _index), do: flash_unauthorized(socket)

  defp given_flash(user) do
    gettext_comment("Flash after deleting an item that had editors: it now belongs to this user (an @handle).")

    dpgettext(
      "sharing",
      "status: flash after a deleted item was given to one of its editors",
      "Given to %{user_handle}",
      user_handle: "@" <> user.handle
    )
  end

  defp deleted_flash(name) do
    gettext_comment("Flash after an item was deleted.")
    dpgettext("sharing", "status: flash after deleting an item", "%{item_name} deleted", item_name: name)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style :type={MythweaverWeb.ColocatedScopedCSS} lower-bound="none">
      /* The host's header actions lay out the button itself. */
      div:scope.hand-off {
        display: contents;
      }

      p:scope.hand-off-error {
        color: var(--destructive);
      }
    </style>
    <div id={@id} class="hand-off">
      <.pane_delete
        :if={@editors == []}
        id={@delete_id}
        phx-click="delete"
        phx-value-id={@item.id}
        confirm={@confirm}
      >
        {dpgettext("sharing", "button: delete this item", "Delete")}
      </.pane_delete>
      <.button
        :if={@editors != []}
        size="sm"
        danger
        id={@delete_id}
        phx-click="open"
        phx-target={@myself}
      >
        <.lucide name="trash" /> {dpgettext("sharing", "button: delete this item", "Delete")}
      </.button>
      <.modal
        :if={@open?}
        id={"#{@thing}-handoff-modal"}
        title={
          dpgettext(
            "sharing",
            "heading: dialog asking to give an item away to one of its editors",
            "Give %{item_name} away?",
            item_name: @item.name
          )
        }
        on_cancel="close"
        on_cancel_target={"##{@id}"}
      >
        <.form for={@form} id={"#{@thing}-handoff-form"} phx-submit="confirm" phx-target={@myself}>
          <p>
            {dgettext(
              "sharing",
              "%{item_name} has editors, so it is not deleted: one of them owns it from now on, and it leaves your account and your chats.",
              item_name: @item.name
            )}
          </p>
          <.input
            field={@form[:to]}
            type="select"
            label={dpgettext("sharing", "field label: editor who receives a deleted item", "Give to")}
            id={"#{@thing}-handoff-to"}
            options={Enum.map(@editors, &{label(&1), &1.id})}
          />
          <p :if={@error} id={"#{@thing}-handoff-error"} class="hand-off-error">{@error}</p>
          <.form_actions>
            <.button
              type="button"
              phx-click={JS.dispatch("modal:close", to: "##{@thing}-handoff-modal")}
            >
              {dpgettext("sharing", "button: close the dialog without acting", "Cancel")}
            </.button>
            <.button type="submit" variant="primary" danger id={"#{@thing}-handoff-confirm"}>
              {dgettext("sharing", "Give and remove from my account")}
            </.button>
          </.form_actions>
        </.form>
      </.modal>
    </div>
    """
  end
end
