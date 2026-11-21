defmodule MythweaverWeb.MainChatLive.Composer do
  @moduledoc """
  The composer's events for `MainChatLive`, which routes every name in `events/0` here: the draft,
  staged attachments and their descriptions (asked, reviewed, approved), sent attachments' captions,
  sending a message or an assistant turn, and quick replies. It also owns the upload callbacks of the
  composer and the message-edit form (`composer_upload_progress/3`, `edit_upload_progress/3`, both
  capped at `attachment_limit/0`), a quick reply's result (`apply_quick_reply/2`) and staged
  descriptions a caption job writes back (`replace_staged/2`).
  """
  use MythweaverWeb, :verified_routes
  use Gettext, backend: Mythweaver.Gettext

  import MythweaverWeb.Flash, only: [flash_unauthorized: 1, flash_quota: 2]
  import Phoenix.Component, only: [assign: 2, to_form: 2, update: 3]

  import Phoenix.LiveView,
    only: [cancel_upload: 3, push_event: 3, push_patch: 2, put_flash: 3, start_async: 3, uploaded_entries: 2]

  alias Mythweaver.Assistant
  alias Mythweaver.Attachments
  alias Mythweaver.Attachments.Captions
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Format
  alias Mythweaver.Generation
  alias Mythweaver.Messages
  alias Mythweaver.Messages.DraftBuffer
  alias Mythweaver.Prompts.Builder
  alias Mythweaver.Scripts
  alias Mythweaver.Scripts.Inline
  alias MythweaverWeb.MainChatLive.AssistantChat
  alias MythweaverWeb.MainChatLive.ChatRefresh
  alias MythweaverWeb.MainChatLive.Members
  alias MythweaverWeb.MainChatLive.MessageActions
  alias MythweaverWeb.Uploads

  @events ~w(save_draft cancel_composer_file describe_all_attachments remove_composer_attachment
             dismiss_image_request describe_composer_attachment ask_caption cancel_caption_question
             submit_caption_question caption_image edit_attachment_description
             cancel_attachment_description save_attachment_description caption_attachment approve_caption
             discard_caption retry_caption send_message quick_reply)

  @attachment_limit 4

  def events, do: @events

  @doc "How many attachments one message takes, from the composer or the edit form."
  def attachment_limit, do: @attachment_limit

  # A pending image's description, typed in the composer. Matched on `_target` so a keystroke in the
  # message text never rewrites a description that changed on the server meanwhile.
  def handle_event("save_draft", %{"_target" => ["attachment_descriptions", id]} = params, socket) do
    {:noreply, describe_staged(socket, id, get_in(params, ["attachment_descriptions", id]) || "")}
  end

  def handle_event("save_draft", %{"composer" => %{"content" => content}}, socket) do
    chat = socket.assigns.selected_chat

    if chat && socket.assigns.role == :owner && Members.poster_id(socket.assigns) do
      DraftBuffer.put(socket.assigns.current_scope, chat, content)
    end

    # `composer_form` is left alone so the editor is never re-rendered mid-typing; `composer_text`
    # is what a sparkle/regenerate/continue click sends as its guide.
    {:noreply, assign(socket, composer_text: content)}
  end

  # A change event that only carries upload progress (no composer text).
  def handle_event("save_draft", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_composer_file", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :composer_files, ref)}

  def handle_event("describe_all_attachments", _params, socket) do
    case Captions.request_all(socket.assigns.current_scope, socket.assigns.selected_chat) do
      {:ok, 0} ->
        {:noreply, put_flash(socket, :info, dgettext("chat", "Every attachment already has a description"))}

      {:ok, n} ->
        {:noreply, put_flash(socket, :info, describing_flash(n))}

      {:error, reason} ->
        {:noreply, flash_caption_error(socket, reason)}
    end
  end

  def handle_event("remove_composer_attachment", %{"id" => id}, socket) do
    {removed, kept} = Enum.split_with(socket.assigns.composer_attachments, &(&1.id == id))
    Attachments.delete_unlinked(socket.assigns.current_scope, Enum.map(removed, & &1.id))
    {:noreply, socket |> assign(composer_attachments: kept) |> update(:composer_image_callbacks, &Map.delete(&1, id))}
  end

  # Dismissing the dialog (Cancel, close, Escape, backdrop) ends the request in every tab.
  def handle_event("dismiss_image_request", _params, %{assigns: %{image_request: %{id: id}}} = socket) do
    :ok = Attachments.close_image_request(socket.assigns.selected_chat.id, id)
    {:noreply, assign(socket, image_request: nil)}
  end

  def handle_event("dismiss_image_request", _params, socket), do: {:noreply, socket}

  def handle_event("describe_composer_attachment", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.composer_attachments, &(&1.id == id)) do
      nil -> {:noreply, socket}
      attachment -> {:noreply, describe_staged_images(socket, [attachment])}
    end
  end

  def handle_event("ask_caption", %{"id" => id, "target" => "staged"}, socket) do
    if Enum.any?(socket.assigns.composer_attachments, &(&1.id == id)),
      do: {:noreply, open_caption_question(socket, {:staged, [id]})},
      else: {:noreply, socket}
  end

  def handle_event("ask_caption", %{"id" => id, "target" => "sent"}, socket),
    do: {:noreply, open_caption_question(socket, {:sent, id})}

  def handle_event("cancel_caption_question", _params, socket), do: {:noreply, assign(socket, caption_question: nil)}

  def handle_event("submit_caption_question", %{"question" => question}, socket) do
    case socket.assigns.caption_question do
      %{target: {:staged, ids}} ->
        staged = Enum.filter(socket.assigns.composer_attachments, &(&1.id in ids))

        {:noreply,
         socket
         |> assign(caption_question: nil)
         |> caption_staged(staged, instruction: question)}

      %{target: {:sent, id}} ->
        {:noreply, socket |> assign(caption_question: nil) |> request_sent_caption(id, instruction: question)}

      nil ->
        {:noreply, socket}
    end
  end

  # The command palette's `chat: caption image`: its freshly uploaded image joins the composer, like
  # one attached there, and is described at once; a non-blank prompt replaces the caption prompt.
  def handle_event("caption_image", %{"attachment_id" => id} = params, socket) do
    with %Chat{} <- socket.assigns.selected_chat,
         %{} = attachment <- Attachments.get_unlinked_image(socket.assigns.current_scope, id) do
      if length(socket.assigns.composer_attachments) < @attachment_limit do
        {:noreply,
         socket
         |> stage_attachment(attachment)
         |> caption_staged([attachment], instruction: params["prompt"])}
      else
        {:noreply, refuse_attachment(socket, attachment)}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("edit_attachment_description", %{"attachment_id" => id, "message_id" => message_id}, socket) do
    {:noreply, socket |> assign(editing_attachment_id: id) |> MessageActions.restream_message(message_id)}
  end

  def handle_event("cancel_attachment_description", %{"message_id" => message_id}, socket) do
    {:noreply, socket |> assign(editing_attachment_id: nil) |> MessageActions.restream_message(message_id)}
  end

  def handle_event(
        "save_attachment_description",
        %{"attachment_id" => id, "message_id" => message_id, "description" => text},
        socket
      ) do
    # `edit_description/3` rebroadcasts the message, which restreams it in every tab.
    case Captions.edit_description(socket.assigns.current_scope, socket.assigns.selected_chat, id, text) do
      {:ok, _} ->
        {:noreply, socket |> assign(editing_attachment_id: nil) |> MessageActions.restream_message(message_id)}

      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}

      {:error, :not_found} ->
        {:noreply, assign(socket, editing_attachment_id: nil)}
    end
  end

  def handle_event("caption_attachment", %{"attachment_id" => id}, socket) do
    if socket.assigns.ask_captions?,
      do: {:noreply, open_caption_question(socket, {:sent, id})},
      else: {:noreply, request_sent_caption(socket, id)}
  end

  def handle_event("approve_caption", %{"job_id" => job_id, "message_id" => message_id, "text" => text}, socket) do
    caption_review(socket, job_id, message_id, &Captions.approve(&1, &2, text))
  end

  def handle_event("discard_caption", %{"job_id" => job_id, "message_id" => message_id}, socket) do
    caption_review(socket, job_id, message_id, &Captions.discard/2)
  end

  def handle_event("retry_caption", %{"job_id" => job_id, "message_id" => message_id}, socket) do
    caption_review(socket, job_id, message_id, &Captions.retry/2)
  end

  # `composer_submitted` closes every send, sent or not, after any `composer_sent`: the composer
  # hook shows a sent message at once and needs to know when a send was refused instead.
  def handle_event("send_message", %{"composer" => %{"content" => content}} = params, socket) do
    {:noreply,
     socket
     |> apply_staged_descriptions(params["attachment_descriptions"] || %{})
     |> submit_composer(content)
     |> push_event("composer_submitted", %{})}
  end

  # From a toolbar button, with the composer's live text.
  def handle_event("quick_reply", %{"id" => id, "text" => text}, socket) when is_binary(id) and is_binary(text) do
    cond do
      socket.assigns.selected_chat == nil or socket.assigns.composer_form == nil ->
        {:noreply, put_flash(socket, :error, quick_reply_no_player())}

      socket.assigns.quick_reply_chat_id != nil ->
        {:noreply, put_flash(socket, :info, dgettext("chat", "A quick reply is already running."))}

      true ->
        chat = socket.assigns.selected_chat
        scope = socket.assigns.current_scope

        {:noreply,
         socket
         |> assign(quick_reply_chat_id: chat.id)
         |> start_async(:quick_reply, Mythweaver.Locale.carry(fn -> Scripts.run_quick_reply(scope, id, chat, text) end))}
    end
  end

  # From the command palette, which has no text: the composer hook answers with its live text, since
  # `composer_text` lags the editor's debounce.
  def handle_event("quick_reply", %{"id" => id}, socket) when is_binary(id) do
    if socket.assigns.composer_form == nil,
      do: {:noreply, put_flash(socket, :error, quick_reply_no_player())},
      else: {:noreply, push_event(socket, "quick_reply:collect", %{id: id})}
  end

  defp quick_reply_no_player do
    gettext_comment("Flash when a quick reply is run in a chat that has no player character.")
    dgettext("chat", "Assign a player character to this chat to use quick replies.")
  end

  @doc "Shown instead of the composer when the viewer has no character to post as."
  def composer_notice(:owner, _chat), do: dgettext("chat", "Assign a player character to this chat to send messages.")

  def composer_notice(_role, %Chat{free_switching: true}),
    do: dpgettext("chat", "empty state: composer, the viewer holds no character", "Take a character to post.")

  def composer_notice(_role, _chat),
    do: dpgettext("chat", "empty state: composer, the viewer holds no character", "Ask the owner for a character.")

  # From the landing (no chat selected) the thread is created first; it is opened even when the
  # message is refused, so the flash has somewhere to explain why. The landing has no file picker,
  # so there is nothing staged to carry over.
  defp send_assistant(socket, nil, content) do
    if String.trim(content) == "" do
      socket
    else
      start_assistant_chat(socket, &send_assistant(&1, &2, content))
    end
  end

  # A sent message clears the composer and its staged files; a refused one keeps them and says why.
  defp send_assistant(socket, %Chat{kind: :assistant} = chat, content) do
    scope = socket.assigns.current_scope
    attachments = socket.assigns.composer_attachments

    case Assistant.send_message(scope, chat, content, attachments) do
      {:ok, message} ->
        :ok = Captions.described_on_send(scope, chat, message, socket.assigns.composer_image_callbacks)

        socket
        |> clear_composer(content, message.id)
        |> assign(composer_attachments: [], composer_image_callbacks: %{}, own_message_id: message.id)

      {:error, :empty} ->
        socket

      {:error, reason} ->
        socket
        |> assign(composer_form: to_form(%{"content" => content}, as: :composer))
        |> put_flash(:error, AssistantChat.assistant_error(reason))
    end
  end

  @doc "Creates a thread on the landing's model pick, runs `after_create` on it, then opens it."
  def start_assistant_chat(socket, after_create) do
    case Assistant.create_chat(socket.assigns.current_scope, %{ai_model_id: socket.assigns.assistant_model_id}) do
      {:ok, chat} ->
        socket |> after_create.(chat) |> ChatRefresh.refresh_chats() |> push_patch(to: ~p"/chats/#{chat.id}")

      {:error, :quota_exceeded} ->
        flash_quota(socket, "quota.chats")

      {:error, _changeset} ->
        put_flash(socket, :error, dgettext("chat", "Could not start a conversation."))
    end
  end

  # Send's checks before anything runs: uploads must finish, and staged images under review must be
  # described first. Then the text goes out as typed.
  defp submit_composer(socket, content) do
    staged = socket.assigns.composer_attachments

    cond do
      match?({_done, [_ | _]}, uploaded_entries(socket, :composer_files)) ->
        put_flash(socket, :error, dgettext("chat", "Wait for attachments to finish uploading"))

      socket.assigns.review_descriptions? and Enum.any?(staged, &(&1.caption_status == :pending)) ->
        put_flash(socket, :info, dgettext("chat", "Waiting for image descriptions. Review them, then send."))

      socket.assigns.review_descriptions? and socket.assigns.auto_caption? and Enum.any?(staged, &undescribed?/1) and
          Captions.captioner_for(socket.assigns.current_scope, socket.assigns.selected_chat) != :none ->
        undescribed = Enum.filter(staged, &undescribed?/1)

        if socket.assigns.ask_captions? do
          socket
          |> open_caption_question({:staged, Enum.map(undescribed, & &1.id)})
          |> put_flash(:info, dgettext("chat", "Answer the question to describe the images, then send."))
        else
          socket
          |> caption_staged(undescribed)
          |> put_flash(:info, dgettext("chat", "Describing images. Review the descriptions, then send."))
        end

      true ->
        send_composer(socket, content)
    end
  end

  # `{! … !}` blocks come out before Liquid renders and run after it, so `{% if %}` decides which run.
  # Nothing has run when preparing or rendering fails; a failing block stops the send at that block.
  defp send_composer(%{assigns: %{selected_chat: chat}} = socket, content) when is_nil(chat) or chat.kind == :assistant,
    do: send_assistant(socket, chat, content)

  defp send_composer(socket, content) do
    chat = socket.assigns.selected_chat
    player = Members.poster_id(socket.assigns)
    images = MessageActions.image_ids(socket.assigns.composer_attachments)

    socket =
      with {:ok, template, scripts} <- prepare_inline(content),
           {:ok, rendered, notices} <- Builder.render_user_text(socket.assigns.current_scope, chat, player, template),
           {:ok, text, lines} <-
             run_inline(socket.assigns.current_scope, chat, rendered, scripts, %{
               "character_id" => player,
               "images" => images
             }) do
        post_composer(socket, content, text, notices ++ lines, scripts != [])
      else
        {:error, :unauthorized} ->
          flash_unauthorized(socket)

        {:error, message} ->
          socket
          |> assign(composer_form: to_form(%{"content" => content}, as: :composer))
          |> put_flash(:error, not_sent_flash(message))
      end

    socket
  end

  defp not_sent_flash(message) do
    gettext_comment(
      "Flash when a composer message is refused; %{script_error} is the reason an inline script or template failed, a lowercase phrase."
    )

    dpgettext(
      "chat",
      "status: flash when a composer message is refused by a script error",
      "Message not sent: %{script_error}",
      script_error: message
    )
  end

  defp prepare_inline(content) do
    case Inline.prepare(content) do
      :none -> {:ok, content, []}
      {:ok, %{template: template, scripts: scripts}} -> {:ok, template, scripts}
      {:error, _message} = error -> error
    end
  end

  defp run_inline(_scope, _chat, rendered, [], _event), do: {:ok, rendered, []}

  defp run_inline(scope, chat, rendered, scripts, event) do
    blocks = Enum.map(Inline.present(rendered, length(scripts)), &{&1, Enum.at(scripts, &1 - 1)})

    case Scripts.run_inline(scope, chat, blocks, event) do
      {:ok, values, lines} -> {:ok, Inline.fill(rendered, values), lines}
      {:error, :unauthorized} -> {:error, :unauthorized}
      {:error, message, _lines} -> {:error, message}
    end
  end

  # `inline?`: the message had `{! … !}` blocks, which already ran, so even a send that posts nothing
  # clears the composer.
  defp post_composer(socket, content, text, notices, inline?) do
    chat = socket.assigns.selected_chat
    player = Members.poster_id(socket.assigns)
    scope = socket.assigns.current_scope

    %{text: text, errors: script_errors} =
      MessageActions.run_user_scripts(socket.assigns.current_scope, chat, %{
        "text" => text,
        "character_id" => player,
        "message_id" => nil,
        "edit" => false,
        "images" => MessageActions.image_ids(socket.assigns.composer_attachments)
      })

    socket = MessageActions.flash_script_errors(socket, script_errors)
    attachments = socket.assigns.composer_attachments

    case Messages.send_message(socket.assigns.current_scope, chat, player, text, attachments: attachments) do
      {:ok, message} ->
        # Before the reply starts, so it reads what those scripts make of the descriptions. Only a
        # message with images (which needed `:attach` to send) has any.
        if attachments != [] do
          :ok = Captions.described_on_send(scope, chat, message, socket.assigns.composer_image_callbacks)
        end

        # A guest without "trigger replies" only posts.
        if Chats.permits?(socket.assigns.role, chat, scope, :generate), do: :ok = Generation.respond(scope, chat)

        socket
        |> clear_composer(content, message.id)
        |> assign(composer_attachments: [], composer_image_callbacks: %{})
        |> assign(own_message_id: message.id)
        |> MessageActions.flash_notices(notices)

      {:error, :empty} when inline? ->
        # Discard first, as `Messages.send_message/5` does, so a pending write cannot revive the draft.
        if socket.assigns.role == :owner do
          :ok = DraftBuffer.discard(socket.assigns.current_scope, chat.id)
          {:ok, nil} = Messages.upsert_draft(socket.assigns.current_scope, chat, "")
        end

        socket
        |> clear_composer(content, nil)
        |> MessageActions.flash_notices(notices)

      {:error, :unauthorized} ->
        flash_unauthorized(socket)

      {:error, :no_character} ->
        put_flash(socket, :error, composer_notice(socket.assigns.role, chat))

      {:error, :empty} ->
        socket

      {:error, %Ecto.Changeset{}} ->
        put_flash(socket, :error, send_failed_flash())
    end
  end

  # `composer_sent` clears the editor and adds the typed source to input history; `message_id` is
  # the message it became (nil when its inline scripts left nothing to post), whose row replaces the
  # composer's provisional copy.
  defp clear_composer(socket, content, message_id) do
    socket
    |> assign(composer_form: to_form(%{"content" => ""}, as: :composer), composer_text: "")
    |> push_event("composer_sent", %{content: content, message_id: message_id})
  end

  @doc """
  The `:composer_files` upload's progress callback. A finished composer upload becomes a stored
  attachment right away, so an image can be described before the message is sent. In review mode,
  describing starts at once. An open `mw.images.request` is fulfilled by an image: the request's
  callback goes with it, and the dialog closes in every tab. An open `mw.characters.set_avatar`
  request takes the image as that character's avatar instead.
  """
  def composer_upload_progress(
        :composer_files,
        %{done?: true} = entry,
        %{assigns: %{image_request: %{avatar: %{} = avatar} = request}} = socket
      ) do
    :ok = Attachments.close_image_request(socket.assigns.selected_chat.id, request.id)
    socket = assign(socket, image_request: nil)

    case {Uploads.consume_image(socket, entry),
          Characters.get_character(socket.assigns.current_scope, avatar.character_id)} do
      {{:error, reason}, _character} ->
        {:noreply, put_flash(socket, :error, avatar_not_set_flash(entry.client_name, reason))}

      # Deleted while the dialog was open; the image belongs to nobody.
      {{:ok, attachment}, nil} ->
        Attachments.delete_unlinked(socket.assigns.current_scope, [attachment.id])
        {:noreply, put_flash(socket, :error, dgettext("chat", "Avatar not set: the character no longer exists"))}

      {{:ok, attachment}, character} ->
        :ok = Attachments.set_avatar(socket.assigns.current_scope, character, attachment, describe: avatar.describe?)

        {:noreply, put_flash(socket, :info, avatar_set_flash(character.name))}
    end
  end

  def composer_upload_progress(:composer_files, %{done?: true} = entry, socket) do
    case Uploads.consume_file(socket, entry) do
      {:ok, attachment} when length(socket.assigns.composer_attachments) < @attachment_limit ->
        socket = stage_attachment(socket, attachment)

        socket =
          if attachment.kind == :image and socket.assigns.review_descriptions? and socket.assigns.auto_caption? and
               Captions.captioner_for(socket.assigns.current_scope, socket.assigns.selected_chat) != :none,
             do: describe_staged_images(socket, [attachment]),
             else: socket

        {:noreply, socket}

      {:ok, attachment} ->
        {:noreply, refuse_attachment(socket, attachment)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, not_attached_flash(entry.client_name, reason))}
    end
  end

  def composer_upload_progress(:composer_files, _entry, socket), do: {:noreply, socket}

  defp stage_attachment(socket, attachment) do
    socket = update(socket, :composer_attachments, &(&1 ++ [attachment]))
    if attachment.kind == :image, do: fulfil_image_request(socket, attachment), else: socket
  end

  # Past the per-message limit: the stored file belongs to nobody.
  defp refuse_attachment(socket, attachment) do
    Attachments.delete_unlinked(socket.assigns.current_scope, [attachment.id])

    put_flash(
      socket,
      :error,
      dngettext(
        "chat",
        "At most %{attachment_limit} attachment per message",
        "At most %{attachment_limit} attachments per message",
        @attachment_limit,
        attachment_limit: Format.number(@attachment_limit)
      )
    )
  end

  @doc """
  The `:edit_files` upload's progress callback: a finished upload joins the attachments the edited
  message gets on save.
  """
  def edit_upload_progress(:edit_files, %{done?: true} = entry, socket) do
    socket =
      case Uploads.consume_file(socket, entry) do
        {:ok, attachment} when length(socket.assigns.edit_attachments) < @attachment_limit ->
          update(socket, :edit_attachments, &(&1 ++ [attachment]))

        {:ok, attachment} ->
          refuse_attachment(socket, attachment)

        {:error, reason} ->
          put_flash(socket, :error, not_attached_flash(entry.client_name, reason))
      end

    {:noreply, MessageActions.restream_editing(socket)}
  end

  def edit_upload_progress(:edit_files, _entry, socket), do: {:noreply, MessageActions.restream_editing(socket)}

  defp fulfil_image_request(%{assigns: %{image_request: %{id: id, callback: callback}}} = socket, attachment) do
    :ok = Attachments.close_image_request(socket.assigns.selected_chat.id, id)

    socket
    |> assign(image_request: nil)
    |> update(:composer_image_callbacks, &if(callback, do: Map.put(&1, attachment.id, callback), else: &1))
  end

  defp fulfil_image_request(socket, _attachment), do: socket

  # Never tried. A failed description does not hold Send: the message goes out, and sending retries
  # it once in the background (`Captions.request_for_message/2`) while the reply waits for it.
  defp undescribed?(attachment), do: attachment.kind == :image and attachment.caption_status == :none

  # A description a person starts: the "Ask…" dialog first when `images.ask_every_time` is on.
  defp describe_staged_images(socket, attachments) do
    if socket.assigns.ask_captions?,
      do: open_caption_question(socket, {:staged, Enum.map(attachments, & &1.id)}),
      else: caption_staged(socket, attachments)
  end

  # Several uploads finishing together, or Send, add to an open question about staged images.
  defp open_caption_question(%{assigns: %{caption_question: %{target: {:staged, ids}}}} = socket, {:staged, more}),
    do: assign(socket, caption_question: %{target: {:staged, Enum.uniq(ids ++ more)}})

  defp open_caption_question(socket, target), do: assign(socket, caption_question: %{target: target})

  defp request_sent_caption(socket, id, opts \\ []) do
    case Captions.request(socket.assigns.current_scope, socket.assigns.selected_chat, id, opts) do
      {:error, reason} when reason in [:unauthorized, :no_captioner] -> flash_caption_error(socket, reason)
      _ -> socket
    end
  end

  defp flash_caption_error(socket, :unauthorized), do: flash_unauthorized(socket)

  defp flash_caption_error(socket, :no_captioner),
    do:
      put_flash(
        socket,
        :error,
        dgettext("chat", "No model in this chat can describe that, and none has a caption model for it")
      )

  defp caption_staged(socket, attachments, opts \\ []) do
    Enum.reduce(attachments, socket, fn attachment, socket ->
      callback = socket.assigns.composer_image_callbacks[attachment.id]
      opts = Keyword.put(opts, :callback, callback)

      case Captions.request_staged(socket.assigns.current_scope, socket.assigns.selected_chat, attachment, opts) do
        {:ok, pending} -> replace_staged(socket, pending)
        {:error, reason} -> flash_caption_error(socket, reason)
      end
    end)
  end

  defp describe_staged(socket, id, text) do
    case Enum.find(socket.assigns.composer_attachments, &(&1.id == id)) do
      nil ->
        socket

      attachment ->
        replace_staged(
          socket,
          Captions.put_manual_description(
            socket.assigns.current_scope,
            socket.assigns.selected_chat.id,
            attachment,
            text,
            scripts?: false
          )
        )
    end
  end

  # On send: descriptions typed in the last debounce window. Only non-blank changes, so a textarea
  # that has not caught up with a just-finished caption cannot erase it.
  defp apply_staged_descriptions(socket, descriptions) do
    Enum.reduce(socket.assigns.composer_attachments, socket, fn attachment, socket ->
      case String.trim(Map.get(descriptions, attachment.id, "")) do
        "" -> socket
        text when text == attachment.description -> socket
        text -> describe_staged(socket, attachment.id, text)
      end
    end)
  end

  @doc "Puts `attachment`'s new state in place of the staged attachment with its id."
  def replace_staged(socket, %{id: id} = attachment) do
    update(socket, :composer_attachments, fn list -> Enum.map(list, &if(&1.id == id, do: attachment, else: &1)) end)
  end

  defp avatar_not_set_flash(file_name, reason) do
    gettext_comment(
      "Flash when an uploaded image could not become a character's avatar; %{upload_error} is the upload error."
    )

    dgettext("chat", "Avatar not set: %{file_name} (%{upload_error})",
      file_name: file_name,
      upload_error: Uploads.error_text(reason)
    )
  end

  defp not_attached_flash(file_name, reason) do
    gettext_comment("Flash when an uploaded file could not be attached; %{upload_error} is the upload error.")

    dpgettext(
      "chat",
      "status: flash when an uploaded file could not be attached",
      "Not attached: %{file_name} (%{upload_error})",
      file_name: file_name,
      upload_error: Uploads.error_text(reason)
    )
  end

  # Approve, discard or redescribe a held caption of the open chat; an unknown job is a no-op.
  defp caption_review(socket, job_id, message_id, action) do
    scope = socket.assigns.current_scope

    case Enum.find(Map.values(socket.assigns.caption_reviews), &(&1.id == job_id)) do
      nil ->
        {:noreply, socket}

      job ->
        case action.(scope, job) do
          {:error, :blank} ->
            {:noreply, put_flash(socket, :error, dgettext("chat", "Write a description or discard it."))}

          {:error, :unauthorized} ->
            {:noreply, flash_unauthorized(socket)}

          _ ->
            {:noreply,
             socket
             |> assign(caption_reviews: Captions.reviews(scope, socket.assigns.selected_chat))
             |> MessageActions.restream_message(message_id)}
        end
    end
  end

  @doc "Applies a finished quick reply script's result: composer text, a message to send, or an error."
  def apply_quick_reply(socket, {:ok, nil, printed}), do: MessageActions.flash_notices(socket, printed)

  def apply_quick_reply(socket, {:ok, :clear, printed}) do
    socket |> push_event("composer:set_text", %{value: ""}) |> MessageActions.flash_notices(printed)
  end

  def apply_quick_reply(socket, {:ok, {:input, text}, printed}) do
    socket |> push_event("composer:set_text", %{value: text}) |> MessageActions.flash_notices(printed)
  end

  # The player may have been unassigned while it ran.
  def apply_quick_reply(%{assigns: %{composer_form: nil}} = socket, {:ok, {:message, _text}, _printed}),
    do: put_flash(socket, :error, quick_reply_no_player())

  def apply_quick_reply(socket, {:ok, {:message, text}, printed}),
    do: socket |> MessageActions.flash_notices(printed) |> submit_composer(text)

  def apply_quick_reply(socket, {:error, :unauthorized}), do: flash_unauthorized(socket)

  def apply_quick_reply(socket, {:error, message, printed}),
    do: put_flash(socket, :error, Enum.join(printed ++ [message], " "))

  defp describing_flash(n) do
    gettext_comment("Flash after the user asks for every undescribed attachment in the chat to be described.")

    dpngettext(
      "chat",
      "status: flash when attachments start being described",
      "Describing %{attachment_count} attachment",
      "Describing %{attachment_count} attachments",
      n,
      attachment_count: Format.number(n)
    )
  end

  defp send_failed_flash do
    gettext_comment("Flash when a message from the composer could not be saved.")
    dpgettext("chat", "status: flash when a message could not be sent", "Could not send message")
  end

  defp avatar_set_flash(character_name) do
    gettext_comment("Flash after an uploaded image is set as a character's avatar.")

    dpgettext("chat", "status: flash after a character's avatar is set", "Avatar set for %{character_name}",
      character_name: character_name
    )
  end
end
