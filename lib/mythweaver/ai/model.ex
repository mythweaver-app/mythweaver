defmodule Mythweaver.AI.Model do
  @moduledoc """
  Exactly one AI model: "Opus 5" is a different row from "Opus 4.8".

  Carries the friendly name shown in pickers, the exact wire id the API expects, capability flags,
  the context window, optional theoretical pricing, and the default sampler params generation
  starts from, the reply length cap among them (`sampler.max_tokens`). Which connections can serve
  it is the join's business (`Mythweaver.AI.ProviderModel`), not this row's.

  `user_id` nil is a site model, run on site connections; set, it is that user's own, linked only to
  their own connections. Only `Mythweaver.AI` sets it.

  `completion_mode` is what the model is for. `:chat` and `:text` generate (`text_modes/0`);
  `:embedding` turns text into vectors for Vector lore; `:classifier` is a sequence classifier served
  like an embedding model (llama-server `--embedding --pooling rank`), whose `/embeddings` vector is
  one raw logit per label, used for character expressions (`Mythweaver.Expressions`). Only the
  generating modes can run a chat, a participant, a memory profile or a job.
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Accounts.User
  alias Mythweaver.AI.HuggingFace
  alias Mythweaver.AI.ProviderModel
  alias Mythweaver.AI.SamplerParams
  alias Mythweaver.AI.ScalarMap
  alias Mythweaver.Prompts.Prompt

  @timeout_fields [
    :chat_first_token_seconds,
    :chat_stall_seconds,
    :chat_deadline_seconds,
    :background_first_token_seconds,
    :background_stall_seconds,
    :background_deadline_seconds
  ]

  schema "ai_models" do
    # Set on a catalog mirror row (`Mythweaver.Catalog`): its listing and the live row it copies.
    # Never cast.
    field :frozen_listing_id, Ecto.UUID
    field :mirror_of_id, Ecto.UUID

    field :name, :string

    # The exact id sent on the wire (`gemma-4`, `claude-sonnet-4-5`). Indexed and required because
    # model identity takes part in prompt assembly as well as request routing.
    field :api_model_id, :string

    field :completion_mode, Ecto.Enum, values: [:chat, :text, :embedding, :classifier], default: :chat
    field :context_window, :integer
    field :supports_images, :boolean, default: false
    field :supports_files, :boolean, default: false
    field :supports_audio, :boolean, default: false
    field :supports_video, :boolean, default: false
    field :supports_tools, :boolean, default: false

    # Thinking, not "inference": every model infers, so the meaningful capability is whether the
    # response carries separate reasoning content.
    field :supports_thinking, :boolean, default: false

    # Chat mode only: continue a message by sending it as a trailing assistant turn (prefill) instead
    # of the nudge instruction. Needs a backend that continues a final assistant message (llama.cpp,
    # Claude); text models ignore it.
    field :continue_prefill, :boolean, default: false

    # An inline tag pair (`<think>`/`</think>`) split out of the reply for backends that put thinking
    # in the text instead of a separate field. Parsing only; never sent. Applies to every provider.
    field :reasoning_prefix, :string
    field :reasoning_suffix, :string

    # Hugging Face repo id whose tokenizer.json counts this model's tokens (lore budget, prompt
    # inspector); nil = estimate.
    field :tokenizer, :string

    # Theoretical pricing per million tokens, used only when a provider reports no real charge.
    field :prompt_cost_per_mtok, :decimal
    field :completion_cost_per_mtok, :decimal

    field :notes, :string

    # Base layer of the request body extras; the connection's, then the link's, deep-merge over it.
    field :extra_body, :map, default: %{}

    # For a model that cannot take images, audio or video: a model that can, which describes each
    # such attachment as text first (`Mythweaver.Attachments.Captions`).
    belongs_to :caption_model, __MODULE__, foreign_key: :caption_model_id

    # For a vision model doing the describing: the `:caption` prompt it is given (nil = the built-in
    # instruction, `default_caption_prompt/0`) and how long a description may run.
    belongs_to :caption_prompt, Prompt, foreign_key: :caption_prompt_id
    field :caption_max_tokens, :integer, default: 300

    # For a vision model: how many of the history's newest messages with images send them inline as
    # image parts, every image of each (nil = all). Older ones go as their description text, so long
    # chats stay bounded.
    field :inline_image_limit, :integer

    # Like `inline_image_limit`, for the newest messages with audio / video / documents sent in full
    # (nil = all); older ones go as their description (a document's summary).
    field :inline_audio_limit, :integer
    field :inline_video_limit, :integer
    field :inline_document_limit, :integer

    # For a vision model: the OpenAI-style `detail` sent with each image (nil = none sent; backends
    # that ignore it, such as llama.cpp, are unaffected). `:low` caps an image at 85 tokens.
    field :image_detail, Ecto.Enum, values: [:low, :auto, :high]

    # Job time limits in seconds, chat replies (`Jobs.chat_tags/0`) and background work
    # (`Jobs.worker_tags/0`) apart. nil keeps the tag's default (`Mythweaver.Jobs.tag_options/1`);
    # 0 is no limit.
    field :chat_first_token_seconds, :integer
    field :chat_stall_seconds, :integer
    field :chat_deadline_seconds, :integer
    field :background_first_token_seconds, :integer
    field :background_stall_seconds, :integer
    field :background_deadline_seconds, :integer

    # `on_replace: :update` so a partial form update does not wipe unrelated sampler params.
    embeds_one :sampler, SamplerParams, on_replace: :update

    # A site model's protected settings (`protected_fields/0`) are hidden from users without
    # `site.hidden.view` when `:runtime_only`; a personal model is always `:readable`.
    field :site_visibility, Ecto.Enum, values: [:readable, :runtime_only], default: :readable

    belongs_to :user, User
    has_many :provider_models, ProviderModel, foreign_key: :ai_model_id
    has_many :providers, through: [:provider_models, :provider]

    # How many connections serve this model; set only by `Mythweaver.AI.list_editable_models/1`.
    field :connection_count, :integer, virtual: true

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(model, attrs) do
    model
    |> cast(
      attrs,
      [
        :name,
        :api_model_id,
        :completion_mode,
        :context_window,
        :supports_images,
        :supports_files,
        :supports_audio,
        :supports_video,
        :supports_tools,
        :supports_thinking,
        :continue_prefill,
        :reasoning_prefix,
        :reasoning_suffix,
        :prompt_cost_per_mtok,
        :completion_cost_per_mtok,
        :notes,
        :extra_body,
        :tokenizer,
        :caption_model_id,
        :caption_prompt_id,
        :caption_max_tokens,
        :inline_image_limit,
        :inline_audio_limit,
        :inline_video_limit,
        :inline_document_limit,
        :image_detail,
        :site_visibility
      ] ++ @timeout_fields
    )
    |> cast_embed(:sampler, with: &SamplerParams.changeset/2)
    |> validate_required([:name, :api_model_id, :completion_mode])
    |> validate_number(:context_window, greater_than: 0)
    |> validate_reasoning_tags()
    |> update_change(:tokenizer, &HuggingFace.normalize_repo/1)
    |> validate_format(:tokenizer, HuggingFace.repo_format(),
      message: dgettext_noop("errors", "must be a Hugging Face repo id like owner/name")
    )
    |> ScalarMap.validate_json(:extra_body)
    |> foreign_key_constraint(:caption_model_id)
    |> foreign_key_constraint(:caption_prompt_id)
    |> validate_number(:caption_max_tokens, greater_than: 0)
    |> validate_number(:inline_image_limit, greater_than_or_equal_to: 0)
    |> validate_number(:inline_audio_limit, greater_than_or_equal_to: 0)
    |> validate_number(:inline_video_limit, greater_than_or_equal_to: 0)
    |> validate_number(:inline_document_limit, greater_than_or_equal_to: 0)
    |> then(fn changeset ->
      Enum.reduce(@timeout_fields, changeset, &validate_number(&2, &1, greater_than_or_equal_to: 0))
    end)
    |> validate_change(:caption_model_id, fn :caption_model_id, id ->
      if id == model.id, do: [caption_model_id: dgettext_noop("errors", "can't caption for itself")], else: []
    end)
    |> put_default_sampler()
    |> validate_site_visibility()
    |> unique_constraint(:name, name: :ai_models_user_id_name_index)
  end

  defp validate_site_visibility(changeset) do
    if get_field(changeset, :user_id) != nil and get_field(changeset, :site_visibility) != :readable,
      do: add_error(changeset, :site_visibility, dgettext_noop("errors", "only site models can be runtime-only")),
      else: changeset
  end

  @doc """
  The settings a Runtime-only viewer never sees (`Mythweaver.Sharing.Items.protected_fields/1`): the
  wire id, sampler, request extras, reasoning tags, tokenizer, notes, time limits and caption prompt.
  """
  @spec protected_fields() :: [atom()]
  def protected_fields,
    do:
      [:api_model_id, :sampler, :extra_body, :reasoning_prefix, :reasoning_suffix, :tokenizer, :notes] ++
        @timeout_fields ++ [:caption_prompt_id]

  @doc "The inline reasoning tag pair, or `nil` when tag parsing is off."
  def reasoning_tags(%__MODULE__{reasoning_prefix: prefix, reasoning_suffix: suffix})
      when is_binary(prefix) and is_binary(suffix), do: {prefix, suffix}

  def reasoning_tags(%__MODULE__{}), do: nil

  @doc """
  The job limits this model overrides for `kind`, in `Mythweaver.Jobs.tag_options/1`'s keys
  (`first_token_ms`, `idle_ms`, `deadline_ms`). An unset field is left out, so the tag's default
  stands. 0 means no limit (`nil`).
  """
  @spec job_limits(%__MODULE__{}, :chat | :background) :: keyword()
  def job_limits(%__MODULE__{} = m, :chat),
    do: limits(m.chat_first_token_seconds, m.chat_stall_seconds, m.chat_deadline_seconds)

  def job_limits(%__MODULE__{} = m, :background),
    do: limits(m.background_first_token_seconds, m.background_stall_seconds, m.background_deadline_seconds)

  @doc "The completion modes that generate text: the only ones that can run a chat or a job."
  @spec text_modes() :: [:chat | :text]
  def text_modes, do: [:chat, :text]

  @doc """
  Whether prompts for this model carry images as image parts. A text-completion prompt has nowhere
  to put one, so text-mode models always get captions instead.
  """
  def sees_images?(%__MODULE__{supports_images: true, completion_mode: :chat}), do: true
  def sees_images?(%__MODULE__{}), do: false

  @doc """
  Whether prompts for this model carry PDFs as file parts. Text-mode models, and models without the
  flag, read the document's extracted text instead.
  """
  def reads_files?(%__MODULE__{supports_files: true, completion_mode: :chat}), do: true
  def reads_files?(_), do: false

  @doc """
  Whether prompts for this model carry audio as `input_audio` parts. Text-mode models, and models
  without the flag, see only an `[Audio: name]` line.
  """
  def hears_audio?(%__MODULE__{supports_audio: true, completion_mode: :chat}), do: true
  def hears_audio?(_), do: false

  @doc """
  Whether prompts for this model carry video clips as `video_url` parts. Text-mode models, and
  models without the flag, see only a `[Video: name]` line.
  """
  def watches_video?(%__MODULE__{supports_video: true, completion_mode: :chat}), do: true
  def watches_video?(_), do: false

  @doc "Per-kind inline limits (nil = all): how many of the newest messages with that kind send it in full."
  def inline_limits(%__MODULE__{} = m),
    do: %{
      image: m.inline_image_limit,
      audio: m.inline_audio_limit,
      video: m.inline_video_limit,
      document: m.inline_document_limit
    }

  @doc """
  Whether this model can write a description of an attachment of `kind`: it must take images,
  audio or video natively; any chat model can summarize a document from its text.
  """
  def describes?(%__MODULE__{} = m, :image), do: sees_images?(m)
  def describes?(%__MODULE__{} = m, :audio), do: hears_audio?(m)
  def describes?(%__MODULE__{} = m, :video), do: watches_video?(m)
  def describes?(%__MODULE__{completion_mode: :chat}, :document), do: true
  def describes?(%__MODULE__{}, _kind), do: false

  @doc "The caption instruction used when a captioning model has no `caption_prompt`."
  def default_caption_prompt do
    "Write a concise, objective description of this image for someone who cannot see it, in one " <>
      "short paragraph. Describe the people, their appearance, clothing and expressions, the setting, " <>
      "and any visible text."
  end

  @doc "The built-in instruction for describing an attachment of `kind`."
  def default_description_prompt(:image), do: default_caption_prompt()

  def default_description_prompt(:audio),
    do:
      "Describe this audio clip for someone who cannot hear it, in one short paragraph: transcribe any speech, " <>
        "saying who speaks if that is clear, and describe music, sounds and mood."

  def default_description_prompt(:video),
    do:
      "Describe this video clip for someone who cannot watch it, in one short paragraph: what happens, in order, " <>
        "the people and setting, and any speech or visible text."

  def default_description_prompt(:document),
    do:
      "Summarize this document in one short paragraph for someone who will not read it: its subject, key facts, " <>
        "names and figures, and anything a reader may need to refer back to."

  @doc """
  A theoretical charge for `prompt_tokens` in and `completion_tokens` out at this model's per-Mtok
  prices, rounded to 12 decimal places: a short embedding call at a cent-per-Mtok price costs well
  under a millionth of a dollar, and it must still add to `quota.spend_per_day`. An unset price
  counts as zero when the other is set; with both unset there is no estimate.
  """
  @spec estimate_cost(%__MODULE__{}, non_neg_integer(), non_neg_integer()) :: Decimal.t() | nil
  def estimate_cost(%__MODULE__{prompt_cost_per_mtok: nil, completion_cost_per_mtok: nil}, _prompt, _completion),
    do: nil

  def estimate_cost(%__MODULE__{} = model, prompt_tokens, completion_tokens) do
    zero = Decimal.new(0)

    Decimal.new(prompt_tokens)
    |> Decimal.mult(model.prompt_cost_per_mtok || zero)
    |> Decimal.add(Decimal.mult(Decimal.new(completion_tokens), model.completion_cost_per_mtok || zero))
    |> Decimal.div(1_000_000)
    |> Decimal.round(12)
    |> Decimal.normalize()
  end

  # A lone tag cannot delimit anything; cast's `empty_values: [""]` already turns blanks into `nil`.
  defp validate_reasoning_tags(changeset) do
    case {get_field(changeset, :reasoning_prefix), get_field(changeset, :reasoning_suffix)} do
      {prefix, nil} when is_binary(prefix) ->
        add_error(
          changeset,
          :reasoning_suffix,
          dgettext_noop("errors", "must be set together with the reasoning prefix")
        )

      {nil, suffix} when is_binary(suffix) ->
        add_error(
          changeset,
          :reasoning_prefix,
          dgettext_noop("errors", "must be set together with the reasoning suffix")
        )

      _both_or_neither ->
        changeset
    end
  end

  # `model.sampler` is never `nil` for callers: an unset embed becomes an all-defaults struct.
  defp put_default_sampler(changeset) do
    case get_field(changeset, :sampler) do
      nil -> put_change(changeset, :sampler, %SamplerParams{})
      _sampler -> changeset
    end
  end

  defp limits(first_token, stall, deadline) do
    for {key, seconds} <- [first_token_ms: first_token, idle_ms: stall, deadline_ms: deadline],
        is_integer(seconds),
        do: {key, if(seconds != 0, do: seconds * 1000)}
  end
end
