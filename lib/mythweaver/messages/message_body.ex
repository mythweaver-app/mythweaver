defmodule Mythweaver.Messages.MessageBody do
  @moduledoc """
  One swipe of a message: its text plus the provenance of the generation that produced it.

  Alternatives are rows rather than a single edited string so regenerating never destroys the previous
  reply; exactly one row per message carries `active: true`.

  Five changesets, deliberately not one with options:

    * `initial_changeset/2`: a user-authored or manually added body; content is required.
    * `streaming_changeset/2`: a body an orchestrator will stream into; content starts blank and
      `generating` is forced true.
    * `finalize_changeset/2`: the outcome of a streamed generation; clears `generating`.
    * `continuing_changeset/2`: a continuation swipe that starts from the source swipe's text and
      reasoning; `generating` forced true.
    * `attached_changeset/2`: a user-authored body sent with attachments; blank text is legal.

  `cost` is the provider's reported charge when there is one; otherwise it may be an estimate from
  `Mythweaver.AI.Model`'s per-Mtok prices, and then `cost_estimated` is true, so a real charge and a
  guess are never confused. `generation_ms` is the wall time from sending the request to finalizing
  the body. `error` holds a rendered failure string so a dead generation stays visible in the
  transcript instead of leaving a silently empty bubble. `reasoning` is the model's separate thinking
  text: shown in the UI, never sent back in prompt history. `reasoning_redacted` is that text with
  every protected value of the build replaced by its label (`Mythweaver.Sharing.Protected.scrub/2`),
  shown instead of `reasoning` to a scope lacking `site.hidden.view`; nil when the build revealed
  nothing protected. `reasoning_share_redacted` replaces only share-protected values (a share has no
  admin bypass) and is shown instead of `reasoning` to a scope holding `site.hidden.view`; nil when
  the build revealed none. Only the generation changesets set them.

  `origin` records why the swipe exists. `source_body_id` is the swipe an edit, continue, refine,
  split, merge or scratchpad append was derived from (the active body at that moment); it is `nil` for
  originals and regenerations, because a regeneration is written from the prompt, not from earlier
  text. Neither is cast: both are set on the struct by `Mythweaver.Messages`, and the `:original`
  default covers a message's first body.
  `guide` is the text the user steered this generation with (a guided generation's outline, or a
  refine's editing instructions), likewise set by `Mythweaver.Messages` and never cast.
  `guide_attachments` are the attachments sent with that guide or refine, linked by
  `Mythweaver.Generation.Server` (`Mythweaver.Attachments.link_body!/2`) when the swipe is created.

  `expression`, `expression_scores`, `expression_source` and `expression_sprite_id` are the swipe's
  character expression (`Mythweaver.Expressions`): the resolved label, the classifier's percent
  scores, whether it was classified or set by hand, and the sprite shown in place of the portrait.
  Only `expression_changeset/2` casts them.
  """

  use Mythweaver.Schema

  import Ecto.Changeset

  alias Mythweaver.AI.ProviderModel
  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Attachments.BodyAttachment
  alias Mythweaver.Expressions.Sprite
  alias Mythweaver.Messages.Message
  alias Mythweaver.Messages.PromptSnapshot

  @type t :: %__MODULE__{}

  schema "message_bodies" do
    field :content, :string
    field :reasoning, :string
    field :reasoning_redacted, :string
    field :reasoning_share_redacted, :string
    field :active, :boolean, default: false
    field :finish_reason, :string
    field :prompt_tokens, :integer
    field :completion_tokens, :integer
    field :total_tokens, :integer
    field :cost, :decimal
    field :cost_estimated, :boolean, default: false
    field :generating, :boolean, default: false
    field :error, :string
    field :generation_ms, :integer

    field :origin, Ecto.Enum,
      values: [:original, :edit, :continue, :regenerate, :refine, :split, :merge, :append],
      default: :original

    field :guide, :string
    field :expression, :string
    field :expression_scores, :map
    field :expression_source, Ecto.Enum, values: [:classified, :manual]

    belongs_to :expression_sprite, Sprite

    belongs_to :message, Message
    belongs_to :provider_model, ProviderModel, foreign_key: :provider_model_id
    belongs_to :source_body, __MODULE__, foreign_key: :source_body_id

    # What the generation sent and received; transcript loads preload only its id.
    has_one :prompt_snapshot, PromptSnapshot

    many_to_many :guide_attachments, Attachment,
      join_through: BodyAttachment,
      preload_order: [asc: :id]

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def initial_changeset(body, attrs) do
    body
    |> cast(attrs, [:content])
    |> validate_required([:content])
    |> put_change(:active, true)
    |> assoc_constraint(:message)
  end

  @doc "A user edit saved into an existing swipe: only `content` changes, and it may not be blank."
  def edit_changeset(body, attrs) do
    body
    |> cast(attrs, [:content])
    |> validate_required([:content])
  end

  @doc "A greeting swipe (`Message.greeting_changeset/2`): `active` is cast so one of several can be shown."
  def greeting_changeset(body, attrs) do
    body
    |> cast(attrs, [:content, :active])
    |> validate_required([:content])
    |> assoc_constraint(:message)
  end

  @doc "A user-authored body sent with attachments (an image-only message): blank text is legal."
  def attached_changeset(body, attrs) do
    cs = cast(body, attrs, [:content], empty_values: [])

    cs
    |> put_change(:content, get_field(cs, :content) || "")
    |> put_change(:active, true)
    |> assoc_constraint(:message)
  end

  @doc """
  A body an orchestrator will stream into: blank content is legal and `generating` is forced true.

  Separate from `initial_changeset/2` rather than a relaxing option on it: a user-authored body with
  no text is a bug, and the two callers must not be able to reach each other's rules by passing attrs.
  """
  def streaming_changeset(body, attrs) do
    body
    |> cast(attrs, [:content, :reasoning_redacted, :reasoning_share_redacted])
    |> put_change(:content, "")
    |> put_change(:active, true)
    |> put_change(:generating, true)
    |> assoc_constraint(:message)
  end

  @doc "A continuation swipe: seeded with the source swipe's text and reasoning; `generating` forced true."
  def continuing_changeset(body, attrs) do
    body
    |> cast(attrs, [:content, :reasoning, :reasoning_redacted, :reasoning_share_redacted])
    |> put_change(:active, true)
    |> put_change(:generating, true)
    |> assoc_constraint(:message)
  end

  @doc "Records the outcome of a streamed generation, clearing `generating`."
  def finalize_changeset(body, attrs) do
    body
    |> cast(attrs, [:content, :reasoning, :reasoning_redacted, :reasoning_share_redacted], empty_values: [])
    |> cast(attrs, [
      :finish_reason,
      :prompt_tokens,
      :completion_tokens,
      :total_tokens,
      :cost,
      :cost_estimated,
      :generation_ms,
      :provider_model_id,
      :error
    ])
    |> put_change(:generating, false)
    |> assoc_constraint(:provider_model)
  end

  @doc "Records the swipe's character expression (`Mythweaver.Expressions`)."
  def expression_changeset(body, attrs) do
    cast(body, attrs, [:expression, :expression_scores, :expression_source, :expression_sprite_id])
  end
end
