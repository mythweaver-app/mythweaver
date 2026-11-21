defmodule MythweaverWeb.MainChatLive.MemoryCommands do
  @moduledoc """
  The command palette's memory events for `MainChatLive`, which routes every name in `events/0` here:
  the memory panel's non-generation controls (side prompts on or off, and the processed-through
  boundary), run without opening the panel. Each reloads an open panel and reports by flash.
  """
  use Gettext, backend: Mythweaver.Gettext

  import MythweaverWeb.Flash, only: [flash_unauthorized: 1]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Mythweaver.Format
  alias Mythweaver.Memory
  alias MythweaverWeb.MainChatLive.MemoryPanel

  @events ~w(memory_set_side_prompt_enabled memory_enable_all_side_prompts memory_disable_all_side_prompts
             memory_show_highest memory_set_highest memory_clear_highest)

  def events, do: @events

  # Command-palette equivalents of the memory panel's non-generation controls. Side prompts are
  # looked up from the current catalog so stale ids cannot mutate anything.
  def handle_event(
        "memory_set_side_prompt_enabled",
        %{"id" => id, "enabled" => enabled},
        %{assigns: %{selected_chat: %{} = _chat}} = socket
      )
      when enabled in ~w(true false) do
    case Enum.find(Memory.list_side_prompts(socket.assigns.current_scope), &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      side_prompt ->
        value = enabled == "true"

        if side_prompt.enabled == value do
          {:noreply,
           socket
           |> MemoryPanel.reload()
           |> put_flash(:info, side_prompt_already_flash(side_prompt.name, value))}
        else
          case Memory.update_side_prompt(socket.assigns.current_scope, side_prompt, %{enabled: value}) do
            {:ok, _} ->
              {:noreply,
               socket
               |> MemoryPanel.reload()
               |> put_flash(:info, side_prompt_set_flash(side_prompt.name, value))}

            {:error, :unauthorized} ->
              {:noreply, flash_unauthorized(socket)}

            {:error, _changeset} ->
              {:noreply, put_flash(socket, :error, side_prompt_update_failed_flash(side_prompt.name))}
          end
        end
    end
  end

  def handle_event("memory_enable_all_side_prompts", _params, socket), do: set_all_side_prompts(socket, true)

  def handle_event("memory_disable_all_side_prompts", _params, socket), do: set_all_side_prompts(socket, false)

  def handle_event("memory_show_highest", _params, %{assigns: %{selected_chat: %{} = chat}} = socket) do
    message =
      case Memory.chat_settings(socket.assigns.current_scope, chat).highest_processed do
        nil ->
          dgettext("chat", "No messages have been processed.")

        position ->
          processed_through_flash(position + 1)
      end

    {:noreply, put_flash(socket, :info, message)}
  end

  def handle_event("memory_set_highest", %{"number" => number}, %{assigns: %{selected_chat: %{} = chat}} = socket) do
    case Integer.parse(to_string(number)) do
      {display, ""} when display in 1..2_147_483_647//1 ->
        {:ok, _} = Memory.set_highest_processed(socket.assigns.current_scope, chat, display - 1)

        {:noreply, socket |> MemoryPanel.reload() |> put_flash(:info, processed_through_flash(display))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("memory_clear_highest", _params, %{assigns: %{selected_chat: %{} = chat}} = socket) do
    {:ok, _} = Memory.set_highest_processed(socket.assigns.current_scope, chat, nil)
    {:noreply, socket |> MemoryPanel.reload() |> put_flash(:info, processed_cleared_flash())}
  end

  defp set_all_side_prompts(%{assigns: %{selected_chat: %{} = _chat}} = socket, enabled) do
    scope = socket.assigns.current_scope

    {changed, failed} =
      Memory.list_side_prompts(scope)
      |> Enum.reject(&(&1.enabled == enabled))
      |> Enum.split_with(&match?({:ok, _}, Memory.update_side_prompt(scope, &1, %{enabled: enabled})))

    socket = MemoryPanel.reload(socket)
    count = length(changed)
    message = side_prompts_set_message(count, enabled)

    case failed do
      [] ->
        {:noreply, put_flash(socket, :info, message)}

      failed ->
        {:noreply,
         put_flash(
           socket,
           :error,
           message <> " " <> side_prompts_update_failed_flash(Enum.map(failed, & &1.name))
         )}
    end
  end

  defp set_all_side_prompts(socket, _enabled), do: {:noreply, socket}

  defp side_prompts_set_message(count, true) do
    gettext_comment("Flash after every side prompt is enabled from the command palette.")

    dpngettext(
      "chat",
      "status: flash after every side prompt is enabled",
      "%{side_prompt_count} side prompt enabled.",
      "%{side_prompt_count} side prompts enabled.",
      count,
      side_prompt_count: Format.number(count)
    )
  end

  defp side_prompts_set_message(count, false) do
    gettext_comment("Flash after every side prompt is disabled from the command palette.")

    dpngettext(
      "chat",
      "status: flash after every side prompt is disabled",
      "%{side_prompt_count} side prompt disabled.",
      "%{side_prompt_count} side prompts disabled.",
      count,
      side_prompt_count: Format.number(count)
    )
  end

  defp side_prompt_already_flash(name, true) do
    gettext_comment("Flash when the user enables a side prompt that is already enabled.")

    dpgettext("chat", "status: flash when a side prompt is already enabled", "%{side_prompt_name} is already enabled.",
      side_prompt_name: name
    )
  end

  defp side_prompt_already_flash(name, false) do
    gettext_comment("Flash when the user disables a side prompt that is already disabled.")

    dpgettext(
      "chat",
      "status: flash when a side prompt is already disabled",
      "%{side_prompt_name} is already disabled.",
      side_prompt_name: name
    )
  end

  defp side_prompt_set_flash(name, true) do
    gettext_comment("Flash after the user enables a side prompt.")

    dpgettext("chat", "status: flash after a side prompt is enabled", "%{side_prompt_name} enabled.",
      side_prompt_name: name
    )
  end

  defp side_prompt_set_flash(name, false) do
    gettext_comment("Flash after the user disables a side prompt.")

    dpgettext("chat", "status: flash after a side prompt is disabled", "%{side_prompt_name} disabled.",
      side_prompt_name: name
    )
  end

  defp side_prompt_update_failed_flash(name) do
    gettext_comment("Flash when enabling or disabling one side prompt failed.")

    dpgettext(
      "chat",
      "status: flash when enabling or disabling a side prompt failed",
      "Could not update %{side_prompt_name}.",
      side_prompt_name: name
    )
  end

  defp side_prompts_update_failed_flash(names) do
    gettext_comment(
      "Appended to the flash after enabling or disabling every side prompt; %{side_prompt_names} is a list of the side prompt names that failed, like \"A, B, and C\"."
    )

    dpgettext(
      "chat",
      "status: flash listing side prompts that could not be enabled or disabled",
      "Could not update %{side_prompt_names}.",
      side_prompt_names: Format.list(names)
    )
  end

  defp processed_through_flash(message_number) do
    gettext_comment(
      "Flash showing the last chat message that memory has processed; %{message_number} is its position in the chat."
    )

    dpgettext(
      "chat",
      "status: flash showing the last message memory has processed",
      "Processed through #%{message_number}.",
      message_number: Format.number(message_number)
    )
  end

  defp processed_cleared_flash do
    gettext_comment("Flash after the user clears the marker of how far memory has processed the chat.")
    dpgettext("chat", "status: flash after the memory processed boundary is cleared", "Processed boundary cleared.")
  end
end
