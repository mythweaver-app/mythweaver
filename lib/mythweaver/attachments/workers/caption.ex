defmodule Mythweaver.Attachments.Workers.Caption do
  @moduledoc """
  The `:caption` job: a model describes one attachment, and the text becomes the attachment's
  `description` (`Mythweaver.Attachments.Captions.put_description/3`): an image, audio or video
  clip it takes natively, or a document it summarizes (a PDF as a file part for a model that
  reads them, else its extracted text).

  Params (string keys): `attachment_id`, and where the attachment lives: `chat_id` and `message_id`
  (both nil for an avatar, `message_id` nil for an image still in the composer or a guide's), or
  `character_id` for an avatar. `staged` true marks an avatar the character editor asked about
  (`Captions.describe_avatar/4`): its text stays on the attachment for the editor's form, and
  `character_id` (nil on the new-character form) only sets the prompt's character. An `instruction`
  (a person's one-off question, `Captions.request/4`, `request_staged/4`, `request_avatar/5`,
  `describe_avatar/4`) replaces the caption prompt. With `review` true (`images.review_results`,
  sent attachments only) the finished text is held for a person (`Captions.hold_for_review/2`) and
  the job ends in `:review` with it in `result["text"]`.

  For an image the request is a `:caption`-purpose prompt rendered by `Mythweaver.Prompts.Builder`,
  the image added to its last user turn: for a chat image the describing model's `caption_prompt`,
  rendered against the chat so a capable model can be given the conversation; for an avatar, which
  has no chat, the `images.avatar_caption_prompt` setting's. With no prompt it is the built-in
  instruction alone. Audio, video and documents always get their kind's built-in instruction
  (`AI.Model.default_description_prompt/1`). The model's own sampler applies, capped at its
  `caption_max_tokens`.
  """

  @behaviour Mythweaver.Jobs.Worker

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.AI.Model
  alias Mythweaver.AI.Request
  alias Mythweaver.Attachments
  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Attachments.Captions
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Jobs
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Lore.Activation
  alias Mythweaver.Prompts
  alias Mythweaver.Prompts.Builder
  alias Mythweaver.Prompts.Prompt
  alias Mythweaver.Repo
  alias Mythweaver.Settings
  alias Mythweaver.Sharing.Protected

  # The model and its caption prompt are read as whoever spends the caption (`Jobs.spend_scope/1`:
  # an `:own` member's own); the prompt's context stays the chat owner's (`Jobs.run_scope/1`).
  @impl true
  def build(%Job{params: params} = job) do
    with %Scope{} = scope <- Jobs.run_scope(job) || {:error, :no_initiator},
         %Scope{} = spend <- Jobs.spend_scope(job) || {:error, :no_initiator},
         %Attachment{status: :ready} = attachment <-
           Repo.get(Attachment, params["attachment_id"]) || {:error, :source_missing},
         %Model{} = model <- (job.ai_model_id && AI.get_model(spend, job.ai_model_id)) || {:error, :no_model},
         {:ok, part} <- read(attachment, model) do
      {input, prompt_name} = text_input(scope, spend, params, model, attachment)
      {:ok, input |> attach_part(part) |> put_max_tokens(model), prompt_name}
    else
      %Attachment{} -> {:error, :source_missing}
      error -> error
    end
  end

  # An image scaled, and with the captioner's `image_detail`, like any image a vision model is sent;
  # a PDF, audio or video clip as the part a model that takes it is sent; any other document as its
  # text.
  defp read(%Attachment{kind: :image} = attachment, model) do
    case Attachments.image_part(attachment, model) do
      {:ok, image} -> {:ok, image}
      {:error, _} -> {:error, :source_missing}
    end
  end

  defp read(%Attachment{} = attachment, model) do
    cond do
      (attachment.content_type == "application/pdf" and Model.reads_files?(model)) or
        (attachment.kind == :audio and Model.hears_audio?(model)) or
          (attachment.kind == :video and Model.watches_video?(model)) ->
        case Attachments.model_part(attachment, model) do
          {:ok, part} -> {:ok, part}
          {:error, _} -> {:error, :source_missing}
        end

      attachment.kind == :document ->
        case attachment.text_content && String.trim(attachment.text_content) do
          text when text not in [nil, ""] ->
            {:ok, {:text, "[Document: #{attachment.filename || "untitled"}]\n#{text}\n[/Document]"}}

          _ ->
            {:error, :no_text}
        end

      true ->
        {:error, :source_missing}
    end
  end

  defp text_input(_scope, _spend, %{"instruction" => instruction}, _model, _attachment)
       when is_binary(instruction) and instruction != "",
       do: {%{messages: [%Request.Message{role: :user, content: instruction}]}, nil}

  defp text_input(_scope, _spend, _params, _model, %Attachment{kind: kind}) when kind != :image,
    do: {%{messages: [%Request.Message{role: :user, content: Model.default_description_prompt(kind)}]}, nil}

  # `:protected` carries the build's scrub pairs to `Mythweaver.Jobs.Runner` (`Jobs.Worker`).
  defp text_input(scope, spend, params, model, _image) do
    with id when is_binary(id) <- prompt_id(spend, params, model),
         %Prompt{purpose: :caption} = prompt <- Prompts.get_prompt(spend, id) do
      context = context(scope, params, model)
      built = Builder.build(prompt, context)

      case Builder.render_segments(built.segments, model, context) do
        %{messages: [_ | _]} = input ->
          input
          |> Map.put(:thinking, prompt.thinking)
          |> Map.put(:protected, Protected.pairs(built.protected_values))
          |> then(&{&1, prompt.name})

        _empty ->
          {instruction_only(), nil}
      end
    else
      _ -> {instruction_only(), nil}
    end
  end

  # A chat image takes the describing model's prompt; an avatar (no chat) the site's avatar prompt,
  # so a prompt written for a scene never describes one that isn't there.
  defp prompt_id(_scope, %{"chat_id" => chat_id}, model) when is_binary(chat_id), do: model.caption_prompt_id
  defp prompt_id(scope, _params, _model), do: Settings.get(scope, "images.avatar_caption_prompt")

  defp instruction_only, do: %{messages: [%Request.Message{role: :user, content: Model.default_caption_prompt()}]}

  # Template writes are never committed, and lore resolves read-only: describing an image changes
  # nothing about the chat.
  defp context(scope, %{"chat_id" => chat_id} = params, model) when is_binary(chat_id) do
    case Chats.get_chat(chat_id) do
      %Chat{} = chat -> Builder.context(scope, chat, model: model, character: character(scope, params))
      nil -> context(scope, Map.delete(params, "chat_id"), model)
    end
  end

  # No chat (an avatar): the prompt still renders, with no history, lore or injections.
  defp context(scope, params, model) do
    Builder.context(scope, %Chat{participants: [], player_character: nil},
      model: model,
      character: character(scope, params),
      messages: [],
      lore: Activation.empty(),
      outlets: %{},
      injections: [],
      variables: %{chat: %{}, global: %{}},
      memory_counts: %{}
    )
  end

  defp character(scope, %{"character_id" => id}) when is_binary(id), do: Characters.get_character(scope, id)
  defp character(_scope, _params), do: nil

  # The attachment joins the last user turn, so backends that require alternating roles accept it;
  # a document read as text follows the instruction's text.
  defp attach_part(%{messages: messages} = input, part) do
    part = with {:text, text} <- part, do: %Request.Text{text: "\n\n" <> text}

    case List.last(messages) do
      %Request.Message{role: :user, content: content} ->
        %{input | messages: List.replace_at(messages, -1, %Request.Message{role: :user, content: join(content, part)})}

      _other ->
        %{input | messages: messages ++ [%Request.Message{role: :user, content: [part]}]}
    end
  end

  defp join(content, %Request.Text{text: text}) when is_binary(content), do: content <> text
  defp join(content, part), do: parts(content) ++ [part]

  defp parts(text) when is_binary(text), do: [%Request.Text{text: text}]
  defp parts(parts) when is_list(parts), do: parts

  defp put_max_tokens(input, %Model{caption_max_tokens: max}) when is_integer(max),
    do: Map.put(input, :sampler, %{max_tokens: max})

  defp put_max_tokens(input, _model), do: input

  @impl true
  def finish(%Job{} = job, completion, _retried?) do
    with %Scope{} = scope <- Jobs.run_scope(job) || {:error, :no_initiator} do
      case String.trim(completion.text || "") do
        "" ->
          {:error, :empty}

        text ->
          save(scope, job, text)
      end
    end
  end

  defp save(scope, %Job{params: %{"review" => true}} = job, text) do
    case Captions.hold_for_review(scope, job) do
      {:ok, :held, attachment} -> {:ok, :review, %{"attachment_id" => attachment.id, "text" => text}}
      {:ok, :skipped, attachment} -> {:ok, :completed, %{"attachment_id" => attachment.id}}
      {:error, _} = error -> error
    end
  end

  defp save(scope, job, text) do
    with {:ok, attachment} <- Captions.put_description(scope, job, text),
         do: {:ok, :completed, %{"attachment_id" => attachment.id}}
  end

  @impl true
  def failed(%Job{} = job), do: Captions.mark_failed(job)
end
