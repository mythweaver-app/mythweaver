defmodule Mythweaver.Scripts.API.Images do
  @moduledoc """
  `mw.images.*`: the images attached to the current chat's messages, and their descriptions.

  An image is reachable when a message of the chat links it, or, in a `user_message` run, when it is
  one of `event.images` (stored in the composer, not linked to a message yet).

  A caption finishes in the background; its result arrives as an `image_described` run, carrying
  the `tag` and `data` given to `mw.images.caption` or `mw.images.request` (held in
  `Mythweaver.Scripts.CallbackStore` meanwhile, and lost on a restart). Inside that run,
  `set_description` saves without running the trigger again, and captioning the image being
  described is refused, so a script cannot loop.
  """

  use Gettext, backend: Mythweaver.Gettext

  import Mythweaver.Scripts.API.Convert

  alias Mythweaver.Attachments
  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Attachments.Captions
  alias Mythweaver.Messages.Message
  alias Mythweaver.Scripts.API
  alias Mythweaver.Scripts.CallbackStore

  @functions %{
    list:
      {"mw.images.list(message_id)",
       dgettext_noop(
         "scripts",
         ~s[The images attached to the current chat's message, in order (else nil, "not_found"). Each has id, message_id, content_type, width, height, description, caption_status ("none", "pending", "done", "failed") and url (a signed link that expires, within two days by default: fetch it again rather than storing it).]
       )},
    get: {"mw.images.get(id)", dgettext_noop("scripts", ~s[One image, as in mw.images.list, or nil, "not_found".])},
    caption:
      {"mw.images.caption(id, opts?)",
       dgettext_noop(
         "scripts",
         ~s[Has the chat's caption model describe the image, in the background; returns true. The description arrives as an image_described run, where opts.tag (a string) and opts.data (any value, at most 64 KB) come back as event.tag and event.data. Refuses "not_found", "no_captioner", "data_too_large", or "same_image" when an image_described script asks for its own image.]
       )},
    set_description:
      {"mw.images.set_description(id, text)",
       dgettext_noop(
         "scripts",
         ~s[Saves text as the image's description, kept over any caption still running; blank clears it. Runs image_described (by "script") except from inside it. Returns the image, or nil, "not_found".]
       )},
    request:
      {"mw.images.request(prompt?, opts?)",
       dgettext_noop(
         "scripts",
         ~s[Asks the player for an image: the chat shows a dialog with prompt and a Choose image button; the image joins the composer like any upload. Returns true at once; the image arrives as an image_described run (once it is described), with opts.tag and opts.data as event.tag and event.data. A newer request replaces an open one. Refuses "not_allowed" in lore_activated, or "data_too_large".]
       )}
  }
  @usage Map.new(@functions, fn {name, {signature, _info}} -> {name, signature} end)

  @doc "The installed functions' signatures and descriptions, by name."
  def functions, do: @functions

  def install(lua, ctx), do: install_functions(lua, [:mw, :images], @functions, &call(&1, ctx, &2, &3))

  @doc "An image's Lua table; `message_id` is nil for an image still in the composer."
  def to_table(%Attachment{} = a, message_id) do
    %{
      id: a.id,
      message_id: message_id,
      content_type: a.content_type,
      width: a.width,
      height: a.height,
      description: a.description,
      caption_status: a.caption_status,
      url: Attachments.url(a, :full)
    }
  end

  defp call(:list, ctx, [message_id], state) when is_binary(message_id) do
    case API.Messages.in_chat(ctx.scope, ctx.chat, message_id) do
      nil ->
        refuse(state, :not_found)

      message ->
        images = Enum.filter(Message.loaded_attachments(message), &(&1.kind == :image))
        ok(state, Enum.map(images, &to_table(&1, message.id)))
    end
  end

  defp call(:get, ctx, [id], state) when is_binary(id) do
    case resolve(ctx, id) do
      {attachment, message_id} -> ok(state, to_table(attachment, message_id))
      nil -> refuse(state, :not_found)
    end
  end

  defp call(:caption, ctx, [id | opts], state) when is_binary(id) and length(opts) <= 1 do
    cond do
      ctx.trigger == :image_described and id == ctx.event["image_id"] ->
        refuse(state, :same_image)

      resolved = resolve(ctx, id) ->
        with_callback(state, opts, :caption, fn callback ->
          case resolved do
            {_attachment, message_id} when is_binary(message_id) ->
              caption_result(state, Captions.request(ctx.scope, ctx.chat, id, callback: callback))

            {attachment, nil} ->
              caption_result(state, Captions.request_staged(ctx.scope, ctx.chat, attachment, callback: callback))
          end
        end)

      true ->
        refuse(state, :not_found)
    end
  end

  defp call(:set_description, ctx, [id, text], state) when is_binary(id) and is_binary(text) do
    case resolve(ctx, id) do
      {attachment, message_id} ->
        opts = [by: "script", scripts?: ctx.trigger != :image_described]
        description = Captions.put_manual_description(ctx.scope, ctx.chat.id, attachment, text, opts)
        ok(state, to_table(description, message_id))

      nil ->
        refuse(state, :not_found)
    end
  end

  defp call(:request, %{trigger: :lore_activated}, _args, state), do: refuse(state, :not_allowed)

  defp call(:request, ctx, args, state) when length(args) <= 2 do
    {prompt, opts} =
      case args do
        [] -> {nil, []}
        [prompt | opts] when is_binary(prompt) or is_nil(prompt) -> {prompt, opts}
        _ -> usage!(@usage[:request])
      end

    with_callback(state, opts, :request, fn callback ->
      _id = Attachments.request_image(ctx.chat.id, prompt, callback)
      ok(state, true)
    end)
  end

  defp call(name, _ctx, _args, _state), do: usage!(@usage[name])

  defp caption_result(state, :ok), do: ok(state, true)
  defp caption_result(state, {:ok, _attachment}), do: ok(state, true)
  defp caption_result(state, {:error, reason}), do: refuse(state, reason)

  # `opts.tag` (a string) and `opts.data` (plain data: nil, booleans, numbers, strings and tables of
  # them) of `name`'s optional opts table, stored in `CallbackStore`; `fun` gets the key, or nil
  # when neither is given.
  defp with_callback(state, opts, name, fun) do
    {tag, data} =
      case opts do
        [] ->
          {nil, nil}

        [table] ->
          fields = fields!(state, table, @usage[name])
          {tag, data} = {fields["tag"], fields["data"]}
          valid? = (is_nil(tag) or is_binary(tag)) and plain?(data)
          if valid?, do: {tag, data}, else: usage!(@usage[name])
      end

    case CallbackStore.put(tag, data) do
      {:ok, callback} -> fun.(callback)
      {:error, reason} -> refuse(state, reason)
    end
  end

  # A message of the chat links it, or it is one of this run's composer images. `mw.images` reads
  # images only, though a chat describes other kinds too.
  defp resolve(ctx, id) do
    case Captions.in_chat(ctx.chat, id) do
      {%Attachment{kind: :image} = attachment, message_id} ->
        {attachment, message_id}

      {%Attachment{}, _message_id} ->
        nil

      nil ->
        with true <- id in List.wrap(ctx.event["images"]),
             %Attachment{} = attachment <- fetch(id, &Attachments.get_attachment(ctx.scope, &1)) do
          {attachment, nil}
        else
          _ -> nil
        end
    end
  end
end
