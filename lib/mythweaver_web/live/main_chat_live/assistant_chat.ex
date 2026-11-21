defmodule MythweaverWeb.MainChatLive.AssistantChat do
  @moduledoc """
  The Mythweaver assistant's events for `MainChatLive`, which routes every name in `events/0` here:
  starting a thread from the landing, the landing's model settings modal (the
  `:assistant_landing_form` assign, nil while closed; its pick is `:assistant_model_id`), stopping
  and compacting the open thread, and answering its tool cards (approve or reject a call, submit or
  dismiss an API key).
  """
  use Gettext, backend: Mythweaver.Gettext

  import MythweaverWeb.Flash, only: [unauthorized_message: 0]
  import Phoenix.Component, only: [assign: 2, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Mythweaver.Assistant
  alias Mythweaver.Chats.Chat
  alias MythweaverWeb.MainChatLive.Composer

  @events ~w(new_assistant_chat open_assistant_landing_settings close_assistant_landing_settings
             assistant_landing_settings stop_assistant compact_assistant approve_tool_call reject_tool_call
             submit_api_key dismiss_api_key)

  def events, do: @events

  def handle_event("new_assistant_chat", _params, socket),
    do: {:noreply, Composer.start_assistant_chat(socket, fn s, _ -> s end)}

  def handle_event("open_assistant_landing_settings", _params, socket) do
    {:noreply,
     socket
     |> assign(assistant_landing_form: landing_form(socket.assigns.assistant_model_id))
     |> assign_assistant_models()}
  end

  def handle_event("close_assistant_landing_settings", _params, socket),
    do: {:noreply, assign(socket, assistant_landing_form: nil)}

  # The pick applies at once (no Save); an id that is not an option is the default.
  def handle_event("assistant_landing_settings", %{"assistant_landing" => %{"ai_model_id" => id}}, socket) do
    id = option_id(socket.assigns.assistant_model_options, id)

    {:noreply,
     socket
     |> assign(assistant_model_id: id, assistant_landing_form: landing_form(id))
     |> assign_assistant_models()}
  end

  def handle_event("stop_assistant", _params, %{assigns: %{selected_chat: %Chat{kind: :assistant} = chat}} = socket) do
    _ = Assistant.stop(socket.assigns.current_scope, chat)
    {:noreply, socket}
  end

  def handle_event("compact_assistant", _params, %{assigns: %{selected_chat: %Chat{kind: :assistant} = chat}} = socket) do
    case Assistant.compact(socket.assigns.current_scope, chat) do
      :ok -> {:noreply, socket}
      {:error, reason} -> {:noreply, put_flash(socket, :error, assistant_error(reason))}
    end
  end

  def handle_event(event, %{"id" => id}, %{assigns: %{selected_chat: %Chat{kind: :assistant} = chat}} = socket)
      when event in ["approve_tool_call", "reject_tool_call"] do
    decision = if event == "approve_tool_call", do: :approve, else: :reject
    {:noreply, assistant_decided(socket, Assistant.decide(socket.assigns.current_scope, chat, id, decision))}
  end

  def handle_event(
        "submit_api_key",
        %{"call_id" => id, "key" => %{"api_key" => key}},
        %{assigns: %{selected_chat: %Chat{kind: :assistant} = chat}} = socket
      ) do
    case Assistant.submit_api_key(socket.assigns.current_scope, chat, id, key) do
      {:error, %Ecto.Changeset{}} -> {:noreply, put_flash(socket, :error, dgettext("chat", "Could not save the key."))}
      {:error, :empty} -> {:noreply, put_flash(socket, :error, enter_key_flash())}
      result -> {:noreply, assistant_decided(socket, result)}
    end
  end

  def handle_event(
        "dismiss_api_key",
        %{"id" => id},
        %{assigns: %{selected_chat: %Chat{kind: :assistant} = chat}} = socket
      ), do: {:noreply, assistant_decided(socket, Assistant.dismiss_input(socket.assigns.current_scope, chat, id))}

  @doc """
  Assigns the assistant's model options, default label and landing error; a landing pick that is
  no longer an option drops back to the default.
  """
  def assign_assistant_models(socket) do
    scope = socket.assigns.current_scope
    options = Assistant.model_options(scope)
    id = option_id(options, socket.assigns.assistant_model_id)
    default = Assistant.model(scope, nil)
    picked = if id, do: Assistant.model(scope, id), else: default

    socket
    |> assign(
      assistant_model_options: options,
      assistant_model_id: id,
      assistant_default_label:
        case default do
          {:ok, model} ->
            dpgettext("chat", "option: the default model of the assistant, with its name", "Default (%{model_name})",
              model_name: model.name
            )

          {:error, _} ->
            dpgettext("chat", "option: the default model of the assistant", "Default")
        end,
      # Whether the landing's next thread can run: its pick, else the default.
      assistant_model_error:
        case picked do
          {:ok, _model} -> nil
          {:error, reason} -> reason
        end
    )
    |> then(&if(&1.assigns.assistant_landing_form, do: assign(&1, assistant_landing_form: landing_form(id)), else: &1))
  end

  defp option_id(options, id), do: if(Enum.any?(options, &match?({_, ^id}, &1)), do: id)

  defp landing_form(id), do: to_form(%{"ai_model_id" => id || ""}, as: :assistant_landing)

  # Another tab deciding first (`:not_pending`) needs no flash: its card update is on the way.
  defp assistant_decided(socket, {:ok, _resumed_or_waiting}), do: socket
  defp assistant_decided(socket, {:error, :not_pending}), do: socket
  defp assistant_decided(socket, {:error, reason}), do: put_flash(socket, :error, assistant_error(reason))

  @doc "The flash text for an assistant action `reason` refused."
  def assistant_error(:busy) do
    gettext_comment("Error shown when the Mythweaver assistant is asked to act while it is still replying.")
    dpgettext("chat", "status: error when the Mythweaver assistant is still replying", "Mythweaver is still replying.")
  end

  def assistant_error(:no_model),
    do:
      dgettext(
        "chat",
        "No model can run Mythweaver. Add a connection under AI → Connections, or pick a model in Settings → Models."
      )

  def assistant_error(:ambiguous_model),
    do:
      dgettext(
        "chat",
        "Several models are available: pick one with the gear button, or set a Mythweaver model in Settings → Models."
      )

  def assistant_error(:text_model),
    do: dgettext("chat", "Mythweaver needs a chat-mode model. Pick one in Settings → Models.")

  def assistant_error(reason) when reason in [:quota_exceeded, :unauthorized], do: generation_error(reason)
  def assistant_error(:not_found), do: dgettext("chat", "That tool call or its connection no longer exists.")
  def assistant_error(:nothing_to_compact), do: dgettext("chat", "Nothing new to compact since the last summary.")

  def assistant_error(other) do
    gettext_comment("%{error_reason} is an internal error term, shown verbatim.")
    dgettext("chat", "Mythweaver could not reply: %{error_reason}", error_reason: inspect(other))
  end

  @doc "The flash text for a generation `reason` refused (`Mythweaver.Generation`'s errors)."
  def generation_error(:quota_exceeded),
    do: dgettext("chat", "You've spent today's budget on the site's AI connections.")

  def generation_error(:unauthorized), do: unauthorized_message()

  def generation_error(:busy),
    do: dgettext("chat", "A reply is already being generated — wait for the queue to finish.")

  def generation_error(:no_model),
    do: dgettext("chat", "No AI model is configured. Add a connection and link a model first.")

  def generation_error(:ambiguous_model),
    do:
      dgettext(
        "chat",
        "Several models are available — pick one for this character or chat, or set a default model in Settings."
      )

  def generation_error(:no_prompt), do: dgettext("chat", "No prompt is bound for this chat.")
  def generation_error(:not_character_authored), do: dgettext("chat", "That message has no character author.")

  def generation_error(:not_last),
    do: dgettext("chat", "Only the latest message can be regenerated, continued or refined.")

  def generation_error(:empty), do: dgettext("chat", "That message has no text to continue or refine.")
  def generation_error(:no_instructions), do: dgettext("chat", "Type editing instructions in the composer first.")

  def generation_error(:no_refine_block) do
    gettext_comment("anchors.refine is a template variable name: keep it as is.")

    dgettext(
      "chat",
      "This chat's prompt has no block that reads anchors.refine. Add the Refine block to the prompt."
    )
  end

  def generation_error(:no_guide_block) do
    gettext_comment("anchors.guide is a template variable name: keep it as is.")

    dgettext(
      "chat",
      "This chat's prompt has no block that reads anchors.guide, so the guide would be ignored. Add the Guide block to the prompt."
    )
  end

  def generation_error(other) do
    gettext_comment("%{error_reason} is an internal error term, shown verbatim.")
    dgettext("chat", "Could not generate a reply: %{error_reason}", error_reason: inspect(other))
  end

  defp enter_key_flash do
    gettext_comment("Flash when the API key form the Mythweaver assistant asked for is submitted empty.")
    dpgettext("chat", "status: flash when an API key submitted to the assistant is empty", "Enter a key.")
  end
end
