defmodule MythweaverWeb.MainChatLive.ClipDialog do
  @moduledoc """
  The clip dialog's events for `MainChatLive`, which routes every name in `events/0` here. The
  `.ClipSelection` hook (in `MythweaverWeb.Chat.Messages`) sends `clip_selection` with the text
  highlighted in one message; the dialog saves it as a line of a new or existing clip
  (`Mythweaver.Memory.Clips.save_clip/4`). `clip_extract` instead opens the memory panel's Topical tab with
  the message picker searched for the text and that message picked.

  The dialog lives in the `:clip_draft` assign (nil while closed): the message id, the form and the
  chat book's clips.
  """
  use MythweaverWeb, :verified_routes
  use Gettext, backend: Mythweaver.Gettext

  import MythweaverWeb.Flash, only: [flash_unauthorized: 1]
  import Phoenix.Component, only: [assign: 2, to_form: 2]
  import Phoenix.LiveView, only: [push_patch: 2, put_flash: 3]

  alias Mythweaver.Memory
  alias Mythweaver.Memory.Clips
  alias Mythweaver.Messages

  @events ~w(clip_selection clip_extract clip_change clip_save close_clip)

  def events, do: @events

  # The message must be this chat's: the hook only names it, the text is the user's to edit anyway.
  def handle_event(
        "clip_selection",
        %{"text" => text, "message_id" => id},
        %{assigns: %{selected_chat: %{} = chat}} = socket
      )
      when is_binary(text) do
    scope = socket.assigns.current_scope

    case Messages.get_message(scope, id) do
      %{chat_id: chat_id} when chat_id == chat.id ->
        book_id = scope |> Memory.chat_settings(chat) |> Map.get(:memory_book_id)
        clips = scope |> Memory.list_records(book_id) |> clips()
        params = %{"text" => String.trim(text), "target" => "new", "title" => "", "activation" => "keyword"}
        {:noreply, assign(socket, clip_draft: %{message_id: id, clips: clips, form: form(params), error: nil})}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "clip_extract",
        %{"text" => text, "message_id" => id},
        %{assigns: %{selected_chat: %{} = chat}} = socket
      )
      when is_binary(text) do
    case Messages.get_message(socket.assigns.current_scope, id) do
      %{chat_id: chat_id} when chat_id == chat.id ->
        params = %{tab: "topical", extract: String.slice(String.trim(text), 0, 200), extract_message: id}
        {:noreply, push_patch(socket, to: ~p"/chats/#{chat.id}/memory?#{params}")}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("clip_change", %{"clip" => params}, %{assigns: %{clip_draft: %{} = draft}} = socket),
    do: {:noreply, assign(socket, clip_draft: %{draft | form: form(params), error: nil})}

  def handle_event(
        "clip_save",
        %{"clip" => params},
        %{assigns: %{clip_draft: %{} = draft, selected_chat: %{} = chat}} = socket
      ) do
    with {:ok, target} <- target(draft, params),
         {:ok, _record} <- Clips.save_clip(socket.assigns.current_scope, chat, params["text"], target) do
      {:noreply, socket |> assign(clip_draft: nil) |> put_flash(:info, saved_flash())}
    else
      {:error, :unauthorized} -> {:noreply, flash_unauthorized(socket)}
      {:error, reason} -> {:noreply, assign(socket, clip_draft: %{draft | form: form(params), error: message(reason)})}
    end
  end

  def handle_event("close_clip", _params, socket), do: {:noreply, assign(socket, clip_draft: nil)}

  # A closed dialog, or no chat selected.
  def handle_event(event, _params, socket) when event in @events, do: {:noreply, socket}

  defp clips(records), do: Enum.filter(records, &(&1.kind == :clip))

  defp form(params), do: to_form(params, as: :clip)

  # Existing clip ids are looked up in the dialog's own list, the chat book's clips.
  defp target(_draft, %{"target" => "new"} = params),
    do: {:ok, {:new, params["title"], if(params["activation"] == "constant", do: :constant, else: :keyword)}}

  defp target(draft, %{"target" => id}) do
    case Enum.find(draft.clips, &(&1.id == id)) do
      nil -> {:error, :not_found}
      record -> {:ok, {:existing, record.id}}
    end
  end

  defp target(_draft, _params), do: {:error, :not_found}

  defp saved_flash do
    gettext_comment("Flash after a passage of a message is saved as a clip lore entry.")
    dpgettext("chat", "status: a passage of a message was saved as a clip", "Clip saved")
  end

  defp message(:empty), do: dgettext("chat", "Nothing to clip: the text is empty.")

  defp message(:no_title),
    do: dpgettext("chat", "status: clip dialog error when a new clip has no title", "Name the new clip.")

  defp message(:not_found), do: dgettext("chat", "That clip is gone: pick another or make a new one.")
  defp message(:invalid), do: dgettext("chat", "The clip could not be saved (check the text for template tags).")

  defp message(reason) do
    gettext_comment("Clip save error; %{error_reason} is an internal error term, shown verbatim.")

    dpgettext("chat", "status: clip dialog error when saving the clip failed", "Failed: %{error_reason}",
      error_reason: inspect(reason)
    )
  end
end
