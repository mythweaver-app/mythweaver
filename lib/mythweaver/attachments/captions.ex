defmodule Mythweaver.Attachments.Captions do
  @moduledoc """
  Text descriptions of attachments (images, audio clips, video clips, and summaries of documents),
  for models that cannot take them and for everything that reads text (lore matching, memory
  summaries, older history past a model's inline limits).

  Who describes:

    * Chat images, audio and video: a model that cannot take a kind may name a caption model
      (`AI.Model.caption_model_id`) that can, which describes each attachment of that kind first.
      `captioner_for/3` picks one for a chat's images: the replying character's when known, then
      the other non-player participants in speaking order, then the player's.
    * Avatars, and AI-generated images in a chat with no such model: the site default,
      `AI.default_caption_model/1`.
    * Attachments past a model's inline limits (`AI.Model.inline_limits/1`): that model itself
      (`request_aged_out/4`), once, in the background: images, audio and video it takes natively,
      and documents for any chat model, which reads their text and writes a summary.
    * A person's request (Describe, Ask…, Describe all, mw.images.caption) in a chat with no
      caption model for the kind: the first participant's own model that takes it (any chat model
      for a document).

  A document is always readable as text, so a caption model never stands in for one: only a
  chat-mode model summarizes, and a text-mode model's old documents keep their full text.

  How: one `:caption` job per attachment (`Mythweaver.Attachments.Workers.Caption`). A chat image
  gets the describing model's `caption_prompt` (a `:caption`-purpose prompt) rendered against the
  chat, so a capable model can be given history while a small one gets only instructions; an avatar
  gets the site's `images.avatar_caption_prompt` instead, since it has no chat. With none, the
  built-in instruction (`AI.Model.default_description_prompt/1`) is used; audio, video and documents
  always get theirs. The model's `caption_max_tokens` caps the reply. A person's one-off question
  may replace that prompt (`request/4`, `request_staged/4`, `request_avatar/5` and
  `describe_avatar/4`'s `:instruction`).

  When: images are stored as soon as they upload to the composer, so `request_staged/3` can
  describe one before it is sent; on send `request_for_message/3` queues every image, audio and
  video clip still without a description; `request_all/2` backfills a whole chat, documents
  included; before a reply, `request_for_reply/6` describes what the responder's model cannot take, and
  `request_for_guide/5` describes the guide's attachments whether or not its model takes their
  kind. Background requests skip messages hidden from the AI. A description the
  player wrote (`put_manual_description/4`, `edit_description/4`) is final: a caption job still
  running for that attachment no longer overwrites it.

  With `images.auto_caption` off, the automatic entry points (`request_for_message/3`,
  `request_for_reply/6`, `request_for_guide/5`, `request_aged_out/4`, and a new avatar through
  `Attachments.set_avatar/4`) queue nothing, and the character editor does not describe a new
  avatar as it uploads; the ones a person or script calls (`request/4`, `request_staged/4`,
  `request_all/2`, `request_avatar/5`, `describe_avatar/4`) still describe.

  Review: with `images.review_results` on, a finished caption of a sent image is held
  (`hold_for_review/2`): the attachment is `:review` and its `:caption` job waits in `:review` with
  the text in `result["text"]`. A person saves it, edited or not (`approve/3`), drops it
  (`discard/2`) or has it described again (`retry/2`); a new request or a hand-written description
  supersedes it. A composer image or an avatar is never held: its description lands in a field
  that is edited anyway (the composer's, or Appearance). A reply waiting on a held caption keeps
  waiting until a person resolves it or the reply is stopped.

  Every entry point takes the `Mythweaver.Accounts.Scope` it acts for; caption jobs carry it as
  their initiator.

  A finished or edited description broadcasts `{:caption_finished, attachment_id}` on
  `Attachments.topic/1`, `{:message_updated, message}` for every message linking the image, and,
  for an avatar, `{:appearance_updated, character_id}` on `Attachments.character_topic/1`.
  """

  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Query

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.AI.Model
  alias Mythweaver.Attachments
  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Attachments.MessageAttachment
  alias Mythweaver.Characters
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Generation
  alias Mythweaver.Jobs
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message
  alias Mythweaver.Moderation.Gate
  alias Mythweaver.Repo
  alias Mythweaver.Scripts
  alias Mythweaver.Scripts.CallbackStore

  # The kinds that get a description, and those described as soon as they are sent (a document is
  # summarized only once it ages out, or on request).
  @described [:image, :audio, :video, :document]
  @on_send [:image, :audio, :video]

  # Background captions of images past a vision model's inline limit, per reply.
  @aged_out_batch 10

  @doc """
  The caption model for `chat`: the first participant, in `prefer`-first order (the replying
  character, then the non-player participants by speaking order, then the player), whose model
  cannot see images but names a caption model that can. An assistant chat, which has no
  participants, uses the assistant's model (`Mythweaver.Assistant.model/2`) the same way. `:none`
  when none does.
  """
  @spec captioner_for(Scope.t(), Chat.t(), Character.t() | nil) :: {:ok, Model.t()} | :none
  def captioner_for(%Scope{} = scope, %Chat{} = chat, prefer \\ nil) do
    authorize!(scope, chat, :attach)
    scope = Chats.spend_scope(scope, chat)
    find_captioner(scope, chat, prefer, :image, participant_models(scope, chat))
  end

  # Each participant character's model (`Generation.model_resolver/2`): the member row is read once
  # per request, not per participant and kind. An assistant chat has no participants.
  defp participant_models(_scope, %Chat{kind: :assistant}), do: nil
  defp participant_models(scope, chat), do: Generation.model_resolver(scope, chat)

  # `models`, with `responder` speaking with `model`: the model its reply was gated on.
  defp with_responder(models, %Character{id: id}, %Model{} = model) do
    fn
      %Character{id: ^id} -> {:ok, model}
      character -> models.(character)
    end
  end

  defp find_captioner(scope, %Chat{kind: :assistant} = chat, _prefer, kind, _models) do
    with {:ok, model} <- Mythweaver.Assistant.model(scope, chat.ai_model_id),
         {:ok, captioner} <- model_captioner(scope, model, kind) do
      {:ok, captioner}
    else
      _ -> :none
    end
  end

  defp find_captioner(scope, chat, prefer, kind, models) do
    chat
    |> candidates(prefer)
    |> Enum.find_value(:none, fn participant ->
      with {:ok, %Model{} = model} <- models.(participant.character),
           {:ok, captioner} <- model_captioner(scope, model, kind) do
        {:ok, captioner}
      else
        _ -> nil
      end
    end)
  end

  # A model that cannot take `kind` but names a caption model that can describe it.
  defp model_captioner(scope, %Model{caption_model_id: id} = model, kind) when is_binary(id) do
    with false <- takes?(model, kind),
         %Model{} = captioner <- AI.get_model(scope, id),
         true <- Model.describes?(captioner, kind) do
      {:ok, captioner}
    else
      _ -> :none
    end
  end

  defp model_captioner(_scope, _model, _kind), do: :none

  # Whether `model` takes `kind` itself. A document is always readable as text, so a caption model
  # never stands in for one.
  defp takes?(model, :image), do: Model.sees_images?(model)
  defp takes?(model, :audio), do: Model.hears_audio?(model)
  defp takes?(model, :video), do: Model.watches_video?(model)
  defp takes?(_model, kind) when kind in [:document, :file], do: true

  # A person asked: the chat's caption model for `kind`, else the first participant (same order)
  # whose own model can describe `kind`.
  defp manual_captioner(scope, chat, kind, models) do
    with :none <- find_captioner(scope, chat, nil, kind, models), do: own_describer(scope, chat, kind, models)
  end

  defp own_describer(scope, %Chat{kind: :assistant} = chat, kind, _models) do
    case Mythweaver.Assistant.model(scope, chat.ai_model_id) do
      {:ok, %Model{} = model} -> if Model.describes?(model, kind), do: {:ok, model}, else: :none
      _ -> :none
    end
  end

  defp own_describer(_scope, chat, kind, models) do
    chat
    |> candidates(nil)
    |> Enum.find_value(:none, fn p ->
      case models.(p.character) do
        {:ok, %Model{} = model} -> if Model.describes?(model, kind), do: {:ok, model}
        _ -> nil
      end
    end)
  end

  defp authorize!(scope, chat_or_id, action) do
    if Chats.authorize(scope, chat_or_id, action) != :ok, do: raise(Mythweaver.UnauthorizedError)
    :ok
  end

  defp candidates(chat, prefer) do
    prefer_id = prefer && prefer.id

    Enum.sort_by(chat.participants, fn p ->
      cond do
        p.character_id == prefer_id -> 0
        p.character_id != chat.player_character_id -> 1
        true -> 2
      end
    end)
  end

  @doc """
  Queues a description for each image, audio and video clip of `message` that has none yet and is
  not already being described. A description the player wrote or reviewed while composing is kept.
  Statuses are `:pending` before this returns, so a reply requested right after sees them; the
  message is rebroadcast so open tabs show it. A message hidden from the AI is skipped, and nothing
  is queued while `images.auto_caption` is off. Documents are not described on send.

  Uploads are described only when the chat has a caption model for their kind. AI-generated images
  (`source: :generated`) fall back to the site default (`AI.default_caption_model/1`), so even an
  all-vision chat has text for lore and memory to read.
  """
  @spec request_for_message(Scope.t(), Chat.t(), Message.t()) :: :ok | {:error, :unauthorized}
  def request_for_message(%Scope{} = scope, %Chat{} = chat, %Message{} = message) do
    with :ok <- Chats.authorize(scope, chat, :attach) do
      scope = Chats.spend_scope(scope, chat)
      if auto_caption?(scope), do: queue_for_message(scope, chat, message), else: :ok
    end
  end

  defp queue_for_message(_scope, _chat, %Message{visible_to_ai: false}), do: :ok

  defp queue_for_message(scope, chat, message) do
    models = participant_models(scope, chat)
    captioners = Map.new(@on_send, &{&1, find_captioner(scope, chat, nil, &1, models)})

    queued =
      for %Attachment{kind: kind} = a <- Message.loaded_attachments(message),
          kind in @on_send,
          a.status == :ready,
          a.caption_status in [:none, :failed],
          {:ok, captioner} <- [send_captioner(scope, a, captioners[kind])],
          do: enqueue(scope, %{chat_id: chat.id, message_id: message.id}, a, captioner)

    if queued != [], do: broadcast_message(scope, chat.id, message.id)
    :ok
  end

  defp send_captioner(_scope, _attachment, {:ok, captioner}), do: {:ok, captioner}
  defp send_captioner(scope, %Attachment{kind: :image, source: :generated}, :none), do: AI.default_caption_model(scope)
  defp send_captioner(_scope, _attachment, :none), do: :none

  @doc """
  Before `responder` replies with `model`: describes, with a caption model for each kind `model`
  cannot take, the images, audio and video clips sent since it last spoke that still have none (sent
  while no participant could describe them), and those of `reply`, the message a regenerate,
  continue or rewrite writes. `scope` is whose models the reply spends (`Chats.spend_scope/2`).
  Hidden messages are skipped, and nothing is queued while `images.auto_caption` is off. Returns
  the ids queued.
  """
  @spec request_for_reply(
          Scope.t(),
          Chat.t(),
          [Message.t()],
          Character.t() | nil,
          Model.t() | nil,
          Message.t() | nil
        ) :: [Ecto.UUID.t()]
  def request_for_reply(scope, chat, messages, responder, model, reply \\ nil)
  def request_for_reply(%Scope{}, _chat, _messages, nil, _model, _reply), do: []

  def request_for_reply(%Scope{} = scope, %Chat{} = chat, messages, %Character{} = responder, %Model{} = model, reply) do
    with :ok <- Chats.authorize(scope, chat, :generate),
         true <- auto_caption?(scope) do
      window = reply_window(messages, responder) ++ List.wrap(reply)
      models = scope |> participant_models(chat) |> with_responder(responder, model)

      for kind <- @on_send,
          not takes?(model, kind),
          {:ok, captioner} <- [find_captioner(scope, chat, responder, kind, models)],
          {message, a} <- undescribed(window, [kind]) do
        enqueue(scope, %{chat_id: chat.id, message_id: message.id}, a, captioner)
        a.id
      end
    else
      _ -> []
    end
  end

  @doc """
  Before `responder` replies with `model`: describes, with its caption model for each kind, the
  guide's images, audio and video clips that have no description, whether or not `model` takes the
  kind. `scope` as for `request_for_reply/6`. Nothing is queued while `images.auto_caption` is off.
  Returns the ids queued.
  """
  @spec request_for_guide(Scope.t(), Chat.t(), [Attachment.t()], Character.t() | nil, Model.t() | nil) ::
          [Ecto.UUID.t()]
  def request_for_guide(%Scope{}, _chat, [], _responder, _model), do: []
  def request_for_guide(%Scope{}, _chat, _attachments, nil, _model), do: []

  def request_for_guide(%Scope{} = scope, %Chat{} = chat, attachments, %Character{} = responder, %Model{} = model) do
    with :ok <- Chats.authorize(scope, chat, :generate),
         true <- auto_caption?(scope) do
      undescribed =
        for %Attachment{kind: k, status: :ready, caption_status: s} = a <- attachments,
            k in @on_send,
            s in [:none, :failed],
            do: a

      models = scope |> participant_models(chat) |> with_responder(responder, model)

      for {kind, group} <- Enum.group_by(undescribed, & &1.kind),
          {:ok, captioner} <- [find_captioner(scope, chat, responder, kind, models)],
          a <- group do
        :ok = enqueue(scope, %{chat_id: chat.id}, a, captioner)
        a.id
      end
    else
      _ -> []
    end
  end

  @doc "The messages sent since `responder` last spoke (all of them when it never has, or for nil): what a reply waits on."
  @spec reply_window([Message.t()], Character.t() | nil) :: [Message.t()]
  def reply_window(messages, nil), do: messages

  def reply_window(messages, %Character{id: id}),
    do: messages |> Enum.reverse() |> Enum.take_while(&(&1.author_character_id != id)) |> Enum.reverse()

  @doc "The ids among `attachment_ids` whose caption is `:pending` or held for review. Deleted ones are gone."
  @spec pending_attachment_ids([Ecto.UUID.t()]) :: [Ecto.UUID.t()]
  def pending_attachment_ids([]), do: []

  def pending_attachment_ids(ids),
    do: Repo.all(from a in Attachment, where: a.id in ^ids and a.caption_status in [:pending, :review], select: a.id)

  @doc """
  Describes, with `captioner` (the model that reads the prompt), the attachments of `messages` that
  its prompt sends as text, past its inline limits (`AI.Model.inline_limits/1`), and that have no
  description: images, audio and video it takes natively, and documents, which it summarizes.
  Background, best effort: the current reply does not wait. Hidden messages are skipped, and nothing
  is queued while `images.auto_caption` is off.

  At most `aged_out_batch/0` per call, newest first (the ones that just left the inline window), so
  turning a limit on in a long chat does not flood the provider; each later reply takes the next
  batch. "Describe all attachments" is the way to do a whole chat at once.
  """
  @spec request_aged_out(Scope.t(), Chat.t(), [{Message.t(), Attachment.t()}], Model.t()) ::
          :ok | {:error, :unauthorized}
  def request_aged_out(%Scope{} = scope, %Chat{} = chat, pairs, %Model{} = captioner) do
    with :ok <- Chats.authorize(scope, chat, :generate) do
      if auto_caption?(scope) do
        pairs
        |> Enum.filter(fn {message, a} -> message.visible_to_ai and a.caption_status == :none end)
        |> Enum.take(-@aged_out_batch)
        |> Enum.each(fn {message, a} ->
          enqueue(scope, %{chat_id: chat.id, message_id: message.id, origin: :background}, a, captioner)
        end)
      end

      :ok
    end
  end

  defp auto_caption?(scope), do: Mythweaver.Settings.get(scope, "images.auto_caption")

  @doc "How many aged-out images `request_aged_out/4` queues per reply."
  def aged_out_batch, do: @aged_out_batch

  @doc """
  Describes every image, audio clip and video, and summarizes every document, in `chat` that has no
  description (never described or failed), skipping messages hidden from the AI. Backs "Describe
  all attachments" in the chat settings. `{:error, :no_captioner}` when some had none but no model
  could describe any of them.
  """
  @spec request_all(Scope.t(), Chat.t()) :: {:ok, non_neg_integer()} | {:error, :no_captioner | :unauthorized}
  def request_all(%Scope{} = scope, %Chat{} = chat) do
    with :ok <- Chats.authorize(scope, chat, :manage) do
      messages = Messages.list_messages(chat)
      models = participant_models(scope, chat)

      {queued, skipped} =
        Enum.reduce(@described, {0, 0}, fn kind, {queued, skipped} ->
          case {undescribed(messages, [kind]), manual_captioner(scope, chat, kind, models)} do
            {[], _} ->
              {queued, skipped}

            {pairs, {:ok, captioner}} ->
              Enum.each(pairs, fn {message, a} ->
                enqueue(scope, %{chat_id: chat.id, message_id: message.id, origin: :background}, a, captioner)
              end)

              {queued + length(pairs), skipped}

            {pairs, :none} ->
              {queued, skipped + length(pairs)}
          end
        end)

      if queued == 0 and skipped > 0, do: {:error, :no_captioner}, else: {:ok, queued}
    end
  end

  defp undescribed(messages, kinds) do
    for %Message{visible_to_ai: true} = message <- messages,
        %Attachment{kind: kind, status: :ready, caption_status: status} = a <- Message.loaded_attachments(message),
        kind in kinds,
        status in [:none, :failed],
        do: {message, a}
  end

  @doc """
  (Re)captions one attachment of a message in `chat`; backs the UI's caption/retry button and
  `mw.images.caption`. `opts[:callback]` is a `Mythweaver.Scripts.CallbackStore` key whose tag and
  data come back on the `image_described` run; a non-blank `opts[:instruction]` (the "Ask…" dialog)
  is sent in place of the captioner's caption prompt.
  """
  @spec request(Scope.t(), Chat.t(), Ecto.UUID.t(), keyword()) ::
          :ok | {:error, :not_found | :no_captioner | :unauthorized}
  def request(%Scope{} = scope, %Chat{} = chat, attachment_id, opts \\ []) do
    with :ok <- Chats.authorize(scope, chat, :attach) do
      scope = Chats.spend_scope(scope, chat)

      case in_chat(chat, attachment_id) do
        nil -> {:error, :not_found}
        {attachment, message_id} -> request_in_chat(scope, chat, attachment, message_id, opts)
      end
    end
  end

  defp request_in_chat(scope, chat, attachment, message_id, opts) do
    case manual_captioner(scope, chat, attachment.kind, participant_models(scope, chat)) do
      :none ->
        {:error, :no_captioner}

      {:ok, captioner} ->
        target = %{
          chat_id: chat.id,
          message_id: message_id,
          callback: opts[:callback],
          instruction: instruction(opts)
        }

        :ok = enqueue(scope, target, attachment, captioner)
        broadcast_message(scope, chat.id, message_id)
    end
  end

  @doc """
  Captions an attachment that is not linked to a message yet (an image waiting in the composer).
  The caller vouches that it owns `attachment`. Returns the attachment as `:pending`.
  `opts[:callback]` as for `request/4`; a non-blank `opts[:instruction]` is sent in place of the
  captioner's caption prompt (the command palette's `chat: caption image`, the "Ask…" dialog).
  """
  @spec request_staged(Scope.t(), Chat.t(), Attachment.t(), keyword()) ::
          {:ok, Attachment.t()} | {:error, :no_captioner | :unauthorized}
  def request_staged(scope, chat, attachment, opts \\ [])

  def request_staged(%Scope{}, %Chat{}, %Attachment{kind: kind}, _opts) when kind != :image, do: {:error, :no_captioner}

  def request_staged(%Scope{} = scope, %Chat{} = chat, %Attachment{} = attachment, opts) do
    with :ok <- Chats.authorize(scope, chat, :attach) do
      scope = Chats.spend_scope(scope, chat)

      case manual_captioner(scope, chat, :image, participant_models(scope, chat)) do
        {:ok, captioner} ->
          target = %{chat_id: chat.id, callback: opts[:callback], instruction: instruction(opts)}
          :ok = enqueue(scope, target, attachment, captioner)
          {:ok, Repo.get!(Attachment, attachment.id)}

        :none ->
          {:error, :no_captioner}
      end
    end
  end

  @doc """
  Describes `character`'s new avatar with the site default caption model
  (`AI.default_caption_model/1`, which also decides whether `scope` may run it). The description
  becomes the character's `appearance` per `images.avatar_updates_appearance` (or the character's
  own `avatar_updates_appearance`) when that is blank or still the replaced avatar's description
  (`previous`); an appearance someone wrote is kept. No-op when no model can caption. Needs a scope
  that may edit `character`. A non-blank `opts[:instruction]` replaces the caption prompt.
  """
  @spec request_avatar(Scope.t(), Character.t(), Attachment.t(), String.t() | nil, keyword()) ::
          :ok | {:error, :unauthorized}
  def request_avatar(%Scope{} = scope, %Character{} = character, %Attachment{} = avatar, previous \\ nil, opts \\ []) do
    with :ok <- Mythweaver.Ownership.authorize_edit(scope, character) do
      case AI.default_caption_model(scope) do
        {:ok, captioner} ->
          target = %{
            character_id: character.id,
            previous: previous,
            origin: :background,
            instruction: instruction(opts)
          }

          enqueue(scope, target, avatar, captioner)

        :none ->
          :ok
      end
    end
  end

  @doc """
  Describes an avatar open in the character editor with the site default caption model: a new upload
  not saved yet, or `character`'s current avatar on request. `character` is nil on the new-character
  form; otherwise `scope` must be able to edit it, and it is the caption prompt's character. The text
  is saved on the attachment only: the editor puts it into its unsaved Appearance when the returned
  job completes, so the character changes only on Save. A non-blank `opts[:instruction]` replaces
  the caption prompt. The caller vouches that it owns `avatar`.
  """
  @spec describe_avatar(Scope.t(), Character.t() | nil, Attachment.t(), keyword()) ::
          {:ok, Ecto.UUID.t()} | {:error, :unauthorized | :no_captioner | :not_queued}
  def describe_avatar(%Scope{} = scope, character, %Attachment{} = avatar, opts \\ []) do
    with :ok <- if(character, do: Mythweaver.Ownership.authorize_edit(scope, character), else: :ok),
         {:ok, captioner} <- AI.default_caption_model(scope) do
      target = %{character_id: character && character.id, staged: true, instruction: instruction(opts)}

      case enqueue_job(scope, target, avatar, captioner) do
        {:ok, job} -> {:ok, job.id}
        {:error, _reason} -> {:error, :not_queued}
      end
    else
      :none -> {:error, :no_captioner}
      error -> error
    end
  end

  defp instruction(opts) do
    case non_blank(opts[:instruction]) do
      {:ok, text} -> text
      {:error, :blank} -> nil
    end
  end

  defp enqueue(scope, target, %Attachment{} = attachment, captioner) do
    _ = enqueue_job(scope, target, attachment, captioner)
    :ok
  end

  defp enqueue_job(scope, target, %Attachment{} = attachment, captioner) do
    drop_review(attachment.id)
    attachment = update!(attachment, %{caption_status: :pending, caption_error: nil})

    # A composer image (no message yet) or an avatar is never held: its description already lands
    # in an editable field (the composer's, or the character's Appearance).
    review? = target[:message_id] != nil and Mythweaver.Settings.get(scope, "images.review_results")
    avatar? = target[:character_id] != nil or target[:staged] == true

    origin = Map.get(target, :origin, :interactive)

    result =
      Jobs.enqueue(scope, :caption, %{
        ai_model_id: captioner.id,
        chat_id: target[:chat_id],
        origin: origin,
        label: job_label(scope, origin, if(avatar?, do: :avatar, else: attachment.kind)),
        params: %{
          "attachment_id" => attachment.id,
          "message_id" => target[:message_id],
          "chat_id" => target[:chat_id],
          "character_id" => target[:character_id],
          "previous_description" => target[:previous],
          "callback" => target[:callback],
          "staged" => target[:staged] == true,
          "instruction" => target[:instruction],
          "review" => review?
        }
      })

    case result do
      {:ok, _job} ->
        result

      {:error, reason} ->
        update!(attachment, %{caption_status: :failed, caption_error: inspect(reason)})
        {:error, reason}
    end
  end

  # A background job is labeled in its user's language; an interactive one is the user's own request.
  defp job_label(scope, :background, kind),
    do: Mythweaver.Locale.with_user_locale(scope, fn -> job_label(scope, :interactive, kind) end)

  defp job_label(_scope, _origin, :avatar),
    do: dpgettext("chat", "heading: job that describes an avatar", "Describe avatar")

  defp job_label(_scope, _origin, :audio),
    do: dpgettext("chat", "heading: job that describes an audio clip", "Describe audio")

  defp job_label(_scope, _origin, :video),
    do: dpgettext("chat", "heading: job that describes a video clip", "Describe video")

  defp job_label(_scope, _origin, :document),
    do: dpgettext("chat", "heading: job that summarizes a document", "Summarize document")

  defp job_label(_scope, _origin, _image), do: dpgettext("chat", "heading: job that captions an image", "Caption image")

  @doc """
  Saves a description a person or script wrote. Blank clears it, so the image is captioned again on
  send. A caption job still running for it no longer overwrites it.

  A non-blank description runs `image_described` scripts unless `opts[:scripts?]` is false (the
  composer's typing, which runs them on send instead). `opts[:by]` is `"person"` (default) or
  `"script"`.
  """
  @spec put_manual_description(Scope.t(), Ecto.UUID.t() | nil, Attachment.t(), String.t(), keyword()) ::
          Attachment.t()
  def put_manual_description(%Scope{} = scope, chat_id, %Attachment{} = attachment, text, opts \\ []) do
    authorize!(scope, chat_id, :attach)
    save_manual_description(scope, chat_id, attachment, text, opts)
  end

  defp save_manual_description(scope, chat_id, attachment, text, opts) do
    drop_review(attachment.id)
    cleared = %{caption_error: nil, described_by_model_id: nil}

    case String.trim(text) do
      "" ->
        attachment = update!(attachment, Map.merge(cleared, %{description: nil, caption_status: :none}))
        notify(scope, chat_id, attachment.id)
        attachment

      text ->
        attachment = update!(attachment, Map.merge(cleared, %{description: text, caption_status: :done}))
        info = %{by: Keyword.get(opts, :by, "person"), model_id: nil, callback: nil}

        attachment =
          if Keyword.get(opts, :scripts?, true), do: describe(scope, chat_id, attachment, info), else: attachment

        notify(scope, chat_id, attachment.id)
        attachment
    end
  end

  @doc "Like `put_manual_description/5` for an attachment of a sent message, scoped to `chat`."
  @spec edit_description(Scope.t(), Chat.t(), Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, Attachment.t()} | {:error, :not_found | :unauthorized}
  def edit_description(%Scope{} = scope, %Chat{} = chat, attachment_id, text, opts \\ []) do
    with :ok <- Chats.authorize(scope, chat, :attach) do
      case in_chat(chat, attachment_id) do
        {attachment, _message_id} -> {:ok, save_manual_description(scope, chat.id, attachment, text, opts)}
        nil -> {:error, :not_found}
      end
    end
  end

  @doc """
  After a send: runs `image_described` for each of `message`'s images whose description a person
  wrote in the composer, where typing ran no scripts. Model descriptions already ran it when they
  were saved. `callbacks` maps an image id to the `CallbackStore` key of the `mw.images.request`
  that brought it.
  """
  @spec described_on_send(Scope.t(), Chat.t(), Message.t(), %{optional(Ecto.UUID.t()) => String.t()}) ::
          :ok | {:error, :unauthorized}
  def described_on_send(%Scope{} = scope, %Chat{} = chat, %Message{} = message, callbacks \\ %{}) do
    with :ok <- Chats.authorize(scope, chat, :attach) do
      for %Attachment{caption_status: :done, described_by_model_id: nil, description: d} = a <-
            Message.loaded_attachments(message),
          is_binary(d) do
        a = describe(scope, chat.id, a, %{by: "person", model_id: nil, callback: callbacks[a.id]})
        notify(scope, chat.id, a.id)
      end

      :ok
    end
  end

  # Runs the chat's `image_described` scripts for a description just saved, and saves a non-blank
  # rewrite. In the caller's process, before the description is announced: a reply waiting on the
  # caption then reads the rewrite. Images outside a chat (avatars) run none.
  defp describe(_scope, nil, attachment, _info), do: attachment

  defp describe(scope, chat_id, %Attachment{} = attachment, info) do
    case Chats.get_chat(chat_id) do
      nil ->
        attachment

      chat ->
        %{tag: tag, data: data} = CallbackStore.fetch(info.callback)

        event = %{
          "text" => attachment.description,
          "image_id" => attachment.id,
          "message_id" => message_id_for(attachment.id),
          "by" => info.by,
          "model_id" => info.model_id,
          "tag" => tag,
          "data" => data
        }

        %{text: text} = Scripts.run(scope, :image_described, chat, event)

        case text && String.trim(text) do
          blank when blank in [nil, ""] -> attachment
          same when same == attachment.description -> attachment
          rewritten -> update!(attachment, %{description: rewritten})
        end
    end
  end

  defp message_id_for(attachment_id) do
    Repo.one(from l in MessageAttachment, where: l.attachment_id == ^attachment_id, select: l.message_id, limit: 1)
  end

  @doc "The described attachment (image, audio, video or document) and the id of the message of `chat` that links it, or `nil`."
  @spec in_chat(Chat.t(), Ecto.UUID.t()) :: {Attachment.t(), Ecto.UUID.t()} | nil
  def in_chat(%Chat{} = chat, attachment_id) do
    case Ecto.UUID.cast(attachment_id) do
      {:ok, attachment_id} ->
        Repo.one(
          from l in MessageAttachment,
            join: m in assoc(l, :message),
            join: a in assoc(l, :attachment),
            where: l.attachment_id == ^attachment_id and m.chat_id == ^chat.id and a.kind in ^@described,
            select: {a, l.message_id},
            limit: 1
        )

      :error ->
        nil
    end
  end

  @doc """
  Ids among the images of `message_ids` whose caption is still `:pending`, or finished and held
  for review (`:review`): a reply waits on both.
  """
  @spec pending_ids([Ecto.UUID.t()]) :: [Ecto.UUID.t()]
  def pending_ids([]), do: []

  def pending_ids(message_ids) do
    Repo.all(
      from l in MessageAttachment,
        join: a in assoc(l, :attachment),
        where: l.message_id in ^message_ids and a.caption_status in [:pending, :review],
        distinct: true,
        select: a.id
    )
  end

  @doc """
  Saves a caption job's description, runs `image_described` scripts on it, and announces it.
  Skipped (but still announced) when the player wrote a description while the job ran. An avatar's
  description also becomes its character's `appearance` (see `request_avatar/5`), unless it was
  asked for by the character editor (`describe_avatar/4`), which fills its own form instead.
  """
  @spec put_description(Scope.t(), Job.t(), String.t()) ::
          {:ok, Attachment.t()} | {:error, :source_missing | :unauthorized}
  def put_description(%Scope{} = scope, %Job{params: params} = job, text) do
    with :ok <- Jobs.authorize(scope, job),
         %Attachment{} = attachment <- fetch_attachment(params) do
      attachment =
        if attachment.caption_status in [:pending, :review] do
          attachment
          |> update!(%{
            description: text,
            caption_status: :done,
            caption_error: nil,
            described_by_model_id: job.ai_model_id
          })
          |> then(
            &describe(scope, params["chat_id"], &1, %{
              by: "model",
              model_id: job.ai_model_id,
              callback: params["callback"]
            })
          )
        else
          attachment
        end

      if params["character_id"] && params["staged"] != true,
        do: put_appearance(scope, params["character_id"], attachment.description, params)

      notify(scope, params["chat_id"], attachment.id)
      {:ok, attachment}
    end
  end

  @doc """
  For a job whose `review` param is set (`images.review_results`): holds its finished caption for
  a person instead of saving it. The attachment becomes `:review` and its messages are
  rebroadcast, but `{:caption_finished, id}` is not sent, so a reply waiting on it keeps waiting.
  `:skipped` (and announced) when someone wrote a description while the job ran.
  """
  @spec hold_for_review(Scope.t(), Job.t()) ::
          {:ok, :held | :skipped, Attachment.t()} | {:error, :source_missing | :unauthorized}
  def hold_for_review(%Scope{} = scope, %Job{params: params} = job) do
    with :ok <- Jobs.authorize(scope, job),
         %Attachment{} = attachment <- fetch_attachment(params) do
      if attachment.caption_status in [:pending, :review] do
        attachment = update!(attachment, %{caption_status: :review, caption_error: nil})
        broadcast_linking(scope, params["chat_id"], attachment.id)
        {:ok, :held, attachment}
      else
        notify(scope, params["chat_id"], attachment.id)
        {:ok, :skipped, attachment}
      end
    end
  end

  defp fetch_attachment(params), do: Repo.get(Attachment, params["attachment_id"]) || {:error, :source_missing}

  @doc "The chat's caption jobs held for review, by attachment id."
  @spec reviews(Scope.t(), Chat.t()) :: %{Ecto.UUID.t() => Job.t()}
  def reviews(%Scope{} = scope, %Chat{} = chat) do
    scope
    |> Jobs.list_jobs(chat_id: chat.id, tags: [:caption], statuses: [:review])
    |> Map.new(&{&1.params["attachment_id"], &1})
  end

  @doc """
  Saves a held caption as `text` (the reviewed, possibly edited, description): completes the job,
  then saves it like a finished caption (`put_description/3`) and releases a waiting reply. Scripts
  run after the job's transaction commits, so a slow `image_described` never holds the row lock.
  """
  @spec approve(Scope.t(), Job.t(), String.t()) ::
          {:ok, Attachment.t()} | {:error, :blank | :not_in_review | :unauthorized | :source_missing}
  def approve(%Scope{} = scope, %Job{} = job, text) do
    with :ok <- Jobs.authorize(scope, job),
         :ok <- in_review(job),
         {:ok, text} <- non_blank(text),
         :ok <- complete_review(job, text) do
      put_description(scope, job, text)
    end
  end

  @doc """
  Drops a held caption: the job is canceled, and the image goes back to its earlier description
  (`:done`) or to none (`:none`). A waiting reply is released.
  """
  @spec discard(Scope.t(), Job.t()) :: :ok | {:error, :not_in_review | :unauthorized}
  def discard(%Scope{} = scope, %Job{params: params} = job) do
    with :ok <- Jobs.authorize(scope, job),
         :ok <- in_review(job),
         {:ok, _} <-
           not_in_review(
             Jobs.resolve_review(job.id, :canceled, %{
               error: dpgettext("jobs", "status: caption draft the user discarded", "Discarded.")
             })
           ) do
      case Repo.get(Attachment, params["attachment_id"]) do
        %Attachment{caption_status: :review} = attachment ->
          status = if blank?(attachment.description), do: :none, else: :done
          update!(attachment, %{caption_status: status})

        _ ->
          :ok
      end

      notify(scope, params["chat_id"], params["attachment_id"])
    end
  end

  @doc "Describes a held caption's image again with the same job; the result is held again."
  @spec retry(Scope.t(), Job.t()) :: :ok | {:error, term()}
  def retry(%Scope{} = scope, %Job{params: params} = job) do
    with :ok <- Jobs.authorize(scope, job),
         :ok <- in_review(job),
         {:ok, _} <- Jobs.retry(scope, job.id) do
      case Repo.get(Attachment, params["attachment_id"]) do
        %Attachment{caption_status: :review} = attachment ->
          update!(attachment, %{caption_status: :pending})
          broadcast_linking(scope, params["chat_id"], attachment.id)

        _ ->
          :ok
      end
    end
  end

  defp in_review(%Job{tag: :caption, status: :review}), do: :ok
  defp in_review(_job), do: {:error, :not_in_review}

  defp not_in_review({:ok, _} = ok), do: ok
  defp not_in_review({:error, _}), do: {:error, :not_in_review}

  defp non_blank(text) when is_binary(text) do
    case String.trim(text) do
      "" -> {:error, :blank}
      text -> {:ok, text}
    end
  end

  defp non_blank(_text), do: {:error, :blank}

  defp blank?(text), do: is_nil(text) or String.trim(text) == ""

  defp complete_review(job, text) do
    case Jobs.complete_in_transaction(job, fn -> {:ok, Map.put(job.result || %{}, "text", text)} end) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :not_in_review}
    end
  end

  # A newer caption request, or a description someone wrote, supersedes a held one.
  defp drop_review(attachment_id) do
    from(j in Job,
      where:
        j.tag == :caption and j.status == :review and
          fragment("?->>'attachment_id' = ?", j.params, ^attachment_id),
      select: j.id
    )
    |> Repo.all()
    |> Enum.each(
      &Jobs.resolve_review(&1, :canceled, %{
        error: dpgettext("jobs", "status: held caption replaced by a newer one", "Superseded.")
      })
    )
  end

  # The character's own `avatar_updates_appearance` wins over the setting; an Appearance someone
  # wrote (neither blank nor the replaced avatar's description) is kept.
  defp put_appearance(scope, character_id, text, params) do
    with %Character{appearance: current} = character <- Characters.get_character(scope, character_id),
         true <- updates_appearance?(scope, character),
         true <- current in [nil, ""] or current == params["previous_description"],
         {:ok, _} <- Gate.unmoderated(fn -> Characters.update_character(scope, character, %{appearance: text}) end) do
      Attachments.broadcast_appearance_updated(character_id)
    end
  end

  @doc """
  Whether a new avatar's description is written into `character`'s Appearance: its own
  `avatar_updates_appearance`, else the scope's `images.avatar_updates_appearance` setting.
  """
  @spec updates_appearance?(Scope.t(), Character.t()) :: boolean()
  def updates_appearance?(%Scope{} = scope, %Character{avatar_updates_appearance: nil}),
    do: Mythweaver.Settings.get(scope, "images.avatar_updates_appearance")

  def updates_appearance?(%Scope{}, %Character{avatar_updates_appearance: value}), do: value

  @doc """
  Records a failed caption job and announces it, so a waiting reply stops waiting. A job whose
  initiator is gone (deleted user) is left alone.
  """
  @spec mark_failed(Job.t()) :: :ok
  def mark_failed(%Job{params: params} = job) do
    case Jobs.initiator_scope(job) do
      nil ->
        :ok

      scope ->
        error =
          case Jobs.get_job(scope, job.id) do
            %Job{error: error} when is_binary(error) ->
              error

            _ ->
              Mythweaver.Locale.with_user_locale(scope, fn ->
                dpgettext("jobs", "status: error text of a caption job that failed", "Caption failed.")
              end)
          end

        case Repo.get(Attachment, params["attachment_id"]) do
          %Attachment{caption_status: :pending} = attachment ->
            update!(attachment, %{caption_status: :failed, caption_error: error})

          _ ->
            :ok
        end

        notify(scope, params["chat_id"], params["attachment_id"])
    end
  end

  defp update!(attachment, attrs), do: attachment |> Attachment.changeset(attrs) |> Repo.update!()

  # Announces on the attachments topic (composer previews, waiting replies), then rebroadcasts every
  # message that links the attachment now: a caption started in the composer may finish after send.
  defp notify(_scope, nil, _attachment_id), do: :ok

  defp notify(scope, chat_id, attachment_id) do
    Phoenix.PubSub.broadcast(Mythweaver.PubSub, Attachments.topic(chat_id), {:caption_finished, attachment_id})
    broadcast_linking(scope, chat_id, attachment_id)
  end

  defp broadcast_linking(_scope, nil, _attachment_id), do: :ok

  defp broadcast_linking(scope, chat_id, attachment_id) do
    MessageAttachment
    |> where([l], l.attachment_id == ^attachment_id)
    |> select([l], l.message_id)
    |> Repo.all()
    |> Enum.each(&broadcast_message(scope, chat_id, &1))
  end

  defp broadcast_message(scope, chat_id, message_id) do
    if message = Messages.get_message(scope, message_id), do: Messages.broadcast_message_updated(chat_id, message)
    :ok
  end
end
