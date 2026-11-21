defmodule MythweaverWeb.MainChatLive.MessageActions do
  @moduledoc """
  A message row's menu events for `MainChatLive`, which routes every name in `events/0` here:
  editing (the `:editing_message_id` assign and its `edit_*` form, saved as a new swipe or in place),
  deleting (behind the `:delete_confirm` dialog, single or bulk), reporting
  (`MythweaverWeb.ReportModal`), hiding from the AI, reattributing (the `:reattributing` assign) and
  the expression picker (the `:expression_picker` assign). Each open picker re-streams its row, which
  renders it inline. It also holds the script and notice helpers that sending and editing share.
  """
  use Gettext, backend: Mythweaver.Gettext

  import MythweaverWeb.Flash, only: [flash_unauthorized: 1]
  import Phoenix.Component, only: [assign: 2, to_form: 2]
  import Phoenix.LiveView, only: [cancel_upload: 3, put_flash: 3, uploaded_entries: 2]

  alias Mythweaver.Accounts
  alias Mythweaver.Attachments
  alias Mythweaver.Expressions
  alias Mythweaver.Memory.Rollback
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message
  alias Mythweaver.Prompts.Builder
  alias Mythweaver.Scripts
  alias MythweaverWeb.MainChatLive.Annotations
  alias MythweaverWeb.MainChatLive.MessageWindow
  alias MythweaverWeb.MainChatLive.SplitEditor
  alias MythweaverWeb.MainChatLive.Swipes
  alias MythweaverWeb.ReportModal

  @events ~w(edit_message cancel_message_edit validate_edit_files cancel_edit_file remove_edit_attachment
             save_message_edit delete_message open_report close_report report confirm_delete cancel_delete
             toggle_message_visibility open_reattribute change_reattribute save_reattribute
             cancel_reattribute open_expression_picker close_expression_picker set_expression
             reclassify_expression)

  def events, do: @events

  # Deleting asks first, in a dialog that also lists what memory rollback would undo.
  def handle_event("delete_message", %{"message_id" => id}, socket) do
    socket =
      case Swipes.chat_message(socket, id) do
        nil ->
          socket

        message ->
          if generating?(message) do
            put_flash(socket, :error, Swipes.still_generating())
          else
            assign(socket,
              delete_confirm: %{
                kind: {:single, message.id},
                count: 1,
                preview: Rollback.preview(socket.assigns.current_scope, message.chat_id, [message.position])
              }
            )
          end
      end

    {:noreply, socket}
  end

  # Reporting a message of the open chat, or one of its members (`MythweaverWeb.ReportModal`).
  def handle_event("open_report", %{"kind" => "message", "id" => id}, socket) do
    case Swipes.chat_message(socket, id) do
      nil ->
        {:noreply, socket}

      message ->
        {:noreply,
         ReportModal.open(
           socket,
           :message,
           message.id,
           dpgettext("chat", "heading: report dialog for a chat message", "Report this message")
         )}
    end
  end

  def handle_event("open_report", %{"kind" => "user", "id" => id}, socket) do
    case Accounts.get_user(id) do
      nil ->
        {:noreply, socket}

      user ->
        {:noreply,
         ReportModal.open(
           socket,
           :user,
           user.id,
           dpgettext("chat", "heading: report dialog for a chat member, with their handle", "Report @%{user_handle}",
             user_handle: user.handle
           )
         )}
    end
  end

  def handle_event("open_report", _params, socket), do: {:noreply, socket}

  def handle_event("close_report", _params, socket), do: {:noreply, ReportModal.close(socket)}

  def handle_event("report", %{"report" => params}, socket), do: {:noreply, ReportModal.submit(socket, params)}

  def handle_event("confirm_delete", _params, socket) do
    socket =
      case socket.assigns.delete_confirm do
        %{kind: {:single, id}} -> socket |> assign(delete_confirm: nil) |> delete_single(id)
        %{kind: :bulk} -> socket |> assign(delete_confirm: nil) |> delete_bulk()
        nil -> socket
      end

    {:noreply, socket}
  end

  def handle_event("cancel_delete", _params, socket), do: {:noreply, assign(socket, delete_confirm: nil)}

  def handle_event("toggle_message_visibility", %{"message_id" => id}, socket) do
    socket =
      case Swipes.chat_message(socket, id) do
        nil ->
          socket

        message ->
          {:ok, message} = Messages.set_visible_to_ai(socket.assigns.current_scope, message, not message.visible_to_ai)

          socket
          |> MessageWindow.restream(message)
      end

    {:noreply, socket}
  end

  # Reattribution changes only the author fields; no swipe is added. See `Messages.reattribute_message/3`.
  def handle_event("open_reattribute", %{"message_id" => id}, socket) do
    socket =
      case Swipes.chat_message(socket, id) do
        nil ->
          socket

        message ->
          if generating?(message) do
            put_flash(socket, :error, Swipes.still_generating())
          else
            options = SplitEditor.author_options(socket.assigns.selected_chat)

            socket
            |> close_reattribute()
            |> assign(
              reattributing: %{
                message_id: message.id,
                author_options: options,
                form: to_form(reattribute_params(message, options), as: :reattribute)
              }
            )
            |> MessageWindow.restream(message)
          end
      end

    {:noreply, socket}
  end

  def handle_event("change_reattribute", %{"reattribute" => params}, %{assigns: %{reattributing: %{} = r}} = socket) do
    {:noreply,
     socket
     |> assign(reattributing: %{r | form: to_form(params, as: :reattribute)})
     |> restream_message(r.message_id)}
  end

  def handle_event("save_reattribute", %{"reattribute" => params}, %{assigns: %{reattributing: %{} = r}} = socket) do
    socket =
      case Swipes.chat_message(socket, r.message_id) do
        nil ->
          assign(socket, reattributing: nil)

        message ->
          author =
            case params["author"] do
              "other" -> {:name, params["name"] || ""}
              id -> {:character, id}
            end

          scope = socket.assigns.current_scope

          case Messages.reattribute_message(scope, socket.assigns.selected_chat, message, author) do
            {:ok, message} ->
              socket
              |> assign(reattributing: nil)
              |> MessageWindow.restream(message)

            {:error, :unauthorized} ->
              flash_unauthorized(socket)

            {:error, %Ecto.Changeset{}} ->
              socket
              |> assign(reattributing: %{r | form: to_form(params, as: :reattribute)})
              |> put_flash(:error, dgettext("chat", "Enter a name for the author."))
              |> MessageWindow.restream(message)

            {:error, :not_participant} ->
              put_flash(socket, :error, dgettext("chat", "That character is not in this chat."))

            {:error, :generating} ->
              socket
              |> assign(reattributing: nil)
              |> put_flash(:error, Swipes.still_generating())
              |> MessageWindow.restream(message)
          end
      end

    {:noreply, socket}
  end

  def handle_event("change_reattribute", _params, socket), do: {:noreply, socket}
  def handle_event("save_reattribute", _params, socket), do: {:noreply, socket}
  def handle_event("cancel_reattribute", _params, socket), do: {:noreply, close_reattribute(socket)}

  # A hand-picked expression; see `Mythweaver.Expressions.set_manual/3`.
  def handle_event("open_expression_picker", %{"message_id" => id}, socket) do
    socket =
      case Swipes.chat_message(socket, id) do
        nil ->
          socket

        message ->
          scope = socket.assigns.current_scope
          body = Message.active_body(message)

          socket
          |> close_expression_picker()
          |> assign(
            expression_picker: %{
              message_id: message.id,
              labels: Expressions.picker_labels(scope, message.chat_id, message),
              current: body && body.expression
            }
          )
          |> MessageWindow.restream(message)
      end

    {:noreply, socket}
  end

  def handle_event("close_expression_picker", _params, socket), do: {:noreply, close_expression_picker(socket)}

  def handle_event("set_expression", %{"message_id" => id} = params, socket) do
    socket =
      case Swipes.chat_message(socket, id) do
        nil ->
          socket

        message ->
          case Expressions.set_manual(socket.assigns.current_scope, message, params["expression"] || "") do
            {:ok, _message} -> close_expression_picker(socket)
            {:error, :no_sprite} -> put_flash(socket, :error, dgettext("chat", "That expression has no sprite"))
            {:error, :unauthorized} -> flash_unauthorized(socket)
          end
      end

    {:noreply, socket}
  end

  def handle_event("reclassify_expression", %{"message_id" => id}, socket) do
    socket =
      case Swipes.chat_message(socket, id) do
        nil ->
          socket

        message ->
          case Expressions.reclassify(socket.assigns.current_scope, message) do
            :ok ->
              socket |> close_expression_picker() |> put_flash(:info, classifying_flash())

            {:error, :off} ->
              put_flash(socket, :error, dgettext("chat", "Set a classifier model in Settings → Expressions first"))

            {:error, :unauthorized} ->
              flash_unauthorized(socket)
          end
      end

    {:noreply, socket}
  end

  def handle_event("edit_message", %{"message_id" => id} = params, socket) do
    socket = socket |> close_edit() |> SplitEditor.close() |> Annotations.close_draft()
    message = Swipes.chat_message(socket, id)
    body = message && Message.active_body(message)

    # The button is hidden while generating; this only covers a race with a regenerate.
    socket =
      if body == nil or body.generating do
        socket
      else
        socket
        |> assign(
          editing_message_id: message.id,
          edit_body_id: body.id,
          edit_form: to_form(%{"content" => body.content}, as: :message_body),
          edit_caret: caret(params),
          edit_attachments: Message.loaded_attachments(message)
        )
        |> MessageWindow.restream(message)
      end

    {:noreply, socket}
  end

  def handle_event("cancel_message_edit", _params, socket), do: {:noreply, close_edit(socket)}

  # The edit form's file input sits outside the stream; its row restreams to show the entries.
  def handle_event("validate_edit_files", _params, socket), do: {:noreply, restream_editing(socket)}

  def handle_event("cancel_edit_file", %{"ref" => ref}, socket),
    do: {:noreply, socket |> cancel_upload(:edit_files, ref) |> restream_editing()}

  # An image the message still links is only unlinked on save; a fresh upload goes now.
  def handle_event("remove_edit_attachment", %{"id" => id}, socket) do
    Attachments.delete_unlinked(socket.assigns.current_scope, [id])

    {:noreply,
     socket
     |> assign(edit_attachments: Enum.reject(socket.assigns.edit_attachments, &(&1.id == id)))
     |> restream_editing()}
  end

  # "Save edits" submits `edit_mode=in_place`; any other submit (the default button, Enter, Escape)
  # makes a new swipe.
  def handle_event("save_message_edit", %{"message_body" => %{"content" => content} = params} = all, socket) do
    message = socket.assigns.editing_message_id && Swipes.chat_message(socket, socket.assigns.editing_message_id)
    save_message_edit(socket, message, content, params, all["edit_mode"] == "in_place")
  end

  @doc "Re-streams the open chat's message `message_id`, when it still exists, so its row re-renders."
  def restream_message(socket, message_id) do
    case Swipes.chat_message(socket, message_id) do
      nil -> socket
      message -> MessageWindow.restream(socket, message)
    end
  end

  # Closes any open reattribute picker and re-streams that message so its picker disappears.
  defp close_reattribute(%{assigns: %{reattributing: nil}} = socket), do: socket

  defp close_reattribute(%{assigns: %{reattributing: %{message_id: id}}} = socket),
    do: socket |> assign(reattributing: nil) |> restream_message(id)

  # Closes any open expression picker and re-streams that message so its picker disappears.
  defp close_expression_picker(%{assigns: %{expression_picker: nil}} = socket), do: socket

  defp close_expression_picker(%{assigns: %{expression_picker: %{message_id: id}}} = socket),
    do: socket |> assign(expression_picker: nil) |> restream_message(id)

  # The picker opens on the current author; a character no longer in the chat becomes a name.
  defp reattribute_params(%Message{author_is_character: true, author_character_id: id} = message, options) do
    if Enum.any?(options, &(elem(&1, 1) == id)),
      do: %{"author" => id, "name" => ""},
      else: %{"author" => "other", "name" => (message.author_character && message.author_character.name) || ""}
  end

  defp reattribute_params(%Message{} = message, _options),
    do: %{"author" => "other", "name" => message.author_name || ""}

  # Its reply is still streaming; the generation server's debounced `save_streamed_body/3` would
  # crash on a deleted row.
  defp generating?(message), do: match?(%{generating: true}, Message.active_body(message))

  # Re-checked at confirm time: the message may have started generating while the dialog was open.
  defp delete_single(socket, id) do
    case Swipes.chat_message(socket, id) do
      nil ->
        socket

      message ->
        if generating?(message) do
          put_flash(socket, :error, Swipes.still_generating())
        else
          # Every tab, this one included, updates from the `{:message_deleted, _}` broadcast.
          {:ok, _} = Messages.delete_message(socket.assigns.current_scope, message)
          socket
        end
    end
  end

  # Same guard as the single delete: a generating message stays, and stays selected.
  defp delete_bulk(socket) do
    {kept, skipped?} =
      socket.assigns.current_scope
      |> Messages.get_messages(Map.keys(socket.assigns.selected_messages))
      |> Enum.reduce({%{}, false}, fn message, {kept, skipped?} ->
        if generating?(message) do
          {Map.put(kept, message.id, message.visible_to_ai), true}
        else
          # The stream updates from the `{:message_deleted, _}` broadcast, as for a single delete.
          {:ok, _} = Messages.delete_message(socket.assigns.current_scope, message)
          {kept, skipped?}
        end
      end)

    socket = assign(socket, selected_messages: kept)

    if skipped?,
      do: put_flash(socket, :error, dgettext("chat", "Skipped messages that are still being generated.")),
      else: socket
  end

  defp classifying_flash do
    gettext_comment("Flash after the user asks to re-classify a message's character expression.")
    dpgettext("chat", "status: re-classifying a message's character expression", "Classifying expression…")
  end

  @doc "Closes any open edit and re-streams that message so its editor disappears."
  def close_edit(%{assigns: %{editing_message_id: nil}} = socket), do: socket

  def close_edit(%{assigns: %{editing_message_id: id}} = socket),
    do: socket |> drop_edit() |> MessageWindow.restream_id(id)

  @doc "Closes the edit without saving: deletes its uploads no message links yet and cancels the pending ones."
  def drop_edit(socket) do
    Attachments.delete_unlinked(socket.assigns.current_scope, Enum.map(socket.assigns.edit_attachments, & &1.id))

    socket.assigns.uploads.edit_files.entries
    |> Enum.reduce(socket, &cancel_upload(&2, :edit_files, &1.ref))
    |> assign(editing_message_id: nil, edit_body_id: nil, edit_form: nil, edit_attachments: [])
  end

  @doc "Re-streams the message being edited, whose form sits inside its stream item; call after each attachment change."
  def restream_editing(%{assigns: %{editing_message_id: nil}} = socket), do: socket
  def restream_editing(%{assigns: %{editing_message_id: id}} = socket), do: MessageWindow.restream_id(socket, id)

  # Unchanged text with unchanged attachments would only add a duplicate swipe; unchanged text with
  # changed attachments changes the message's attachments alone, without a swipe. Changed text goes
  # into the active swipe with `in_place?` ("Save edits"), else into a new one.
  defp save_message_edit(socket, nil, _content, _params, _in_place?), do: {:noreply, close_edit(socket)}

  defp save_message_edit(socket, message, content, params, in_place?) do
    attachments_changed? =
      MapSet.new(Message.loaded_attachments(message), & &1.id) != MapSet.new(socket.assigns.edit_attachments, & &1.id)

    cond do
      match?({_, [_ | _]}, uploaded_entries(socket, :edit_files)) ->
        {:noreply,
         socket
         |> assign(edit_form: to_form(%{"content" => content}, as: :message_body))
         |> put_flash(:error, dgettext("chat", "Wait for attachments to finish uploading"))
         |> MessageWindow.restream(message)}

      content == Message.active_content(message) and not attachments_changed? ->
        {:noreply, close_edit(socket)}

      content == Message.active_content(message) ->
        case set_edit_attachments(socket, message, true) do
          {:ok, message} -> {:noreply, socket |> drop_edit() |> MessageWindow.restream(message)}
          {:error, :unauthorized} -> {:noreply, flash_unauthorized(socket)}
        end

      true ->
        save_edited_text(socket, message, content, params, attachments_changed?, in_place?)
    end
  end

  # A message's attachments change only when the edit changed them.
  defp set_edit_attachments(_socket, message, false), do: {:ok, message}

  defp set_edit_attachments(socket, message, true),
    do:
      Messages.set_attachments(
        socket.assigns.current_scope,
        socket.assigns.selected_chat,
        message,
        socket.assigns.edit_attachments
      )

  defp save_edited_text(socket, message, content, params, attachments_changed?, in_place?) do
    case Builder.render_user_text(
           socket.assigns.current_scope,
           socket.assigns.selected_chat,
           message.author_character_id,
           content
         ) do
      {:error, :unauthorized} ->
        {:noreply, flash_unauthorized(socket)}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(edit_form: to_form(%{"content" => content}, as: :message_body))
         |> put_flash(:error, edit_not_saved_flash(error))
         |> MessageWindow.restream(message)}

      {:ok, text, notices} ->
        %{text: text, errors: script_errors} =
          run_user_scripts(socket.assigns.current_scope, socket.assigns.selected_chat, %{
            "text" => text,
            "character_id" => message.author_character_id,
            "message_id" => message.id,
            "edit" => true,
            "images" => image_ids(socket.assigns.edit_attachments)
          })

        socket = flash_script_errors(socket, script_errors)

        save =
          if in_place?,
            do: &Messages.update_edited_body(&1, &2, socket.assigns.edit_body_id, &3),
            else: &Messages.add_edited_body/3

        with {:ok, message} <- save.(socket.assigns.current_scope, message, Map.put(params, "content", text)),
             {:ok, message} <- set_edit_attachments(socket, message, attachments_changed?) do
          {:noreply, socket |> drop_edit() |> MessageWindow.restream(message) |> flash_notices(notices)}
        else
          {:error, :unauthorized} ->
            {:noreply, flash_unauthorized(socket)}

          {:error, :generating} ->
            {:noreply, socket |> put_flash(:error, Swipes.still_generating()) |> close_edit()}

          {:error, :not_found} ->
            {:noreply, socket |> put_flash(:error, dgettext("chat", "That swipe no longer exists")) |> close_edit()}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             socket
             |> assign(edit_form: to_form(changeset, action: :validate, as: :message_body))
             |> MessageWindow.restream(message)}
        end
    end
  end

  # Double-click edit: a selection's UTF-16 `[from, to]` offsets in the body text, or the click's
  # single offset, as `{offset, selection_end | nil}`; the editor clamps both client-side.
  defp caret(%{"selection" => [from, to]}) when is_integer(from) and is_integer(to) and 0 <= from and from < to,
    do: {from, to}

  defp caret(%{"caret" => n}) when is_integer(n) and n >= 0, do: {n, nil}
  defp caret(_params), do: nil

  defp edit_not_saved_flash(error) do
    gettext_comment(
      "Flash when a message edit is refused; %{template_error} is the reason its template failed to render."
    )

    dpgettext(
      "chat",
      "status: flash when a message edit is refused by a template error",
      "Edit not saved: %{template_error}",
      template_error: error
    )
  end

  @doc "Flashes a send's or edit's script and template notices as one info line."
  def flash_notices(socket, []), do: socket
  def flash_notices(socket, notices), do: put_flash(socket, :info, Enum.join(notices, " "))

  @doc """
  Runs the `:user_message` scripts over a sent or edited message's `event`. Blank text with no
  images is left alone, so a blank send stays a no-op even under a script that appends text.
  """
  def run_user_scripts(scope, chat, %{"text" => text} = event) do
    if String.trim(text) == "" and Map.get(event, "images", []) == [],
      do: %{text: text, errors: []},
      else: Scripts.run(scope, :user_message, chat, event)
  end

  @doc "Flashes script failures from a send or edit. The message still goes out with the last good text."
  def flash_script_errors(socket, []), do: socket
  def flash_script_errors(socket, errors), do: put_flash(socket, :error, Enum.join(errors, " "))

  @doc "The image ids among `attachments`: script events name only the images (`mw.images`)."
  def image_ids(attachments), do: for(%{kind: :image, id: id} <- attachments, do: id)
end
