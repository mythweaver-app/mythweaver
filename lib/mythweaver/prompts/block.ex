defmodule Mythweaver.Prompts.Block do
  @moduledoc """
  A reusable prompt block: one segment a prompt can inject, shared across every prompt that includes it.

  A block is one of two kinds:

    * template: `content` is a Liquid template (`Mythweaver.Templates`) reading `anchors.*`,
      `outlets.*`, `vars.*` and `globals.*`
    * chat history: the transcript marker. It has no text, because for chat models it expands
      into one message per turn. `speaker_roles` picks those turns' roles: `:responder` (the
      default) sends the responder's own lines as bare `assistant` turns and everyone else's as
      `user` turns prefixed `"Name: "`; `:fixed` sends every non-player character's lines as
      `assistant` and everyone else's as `user`, all prefixed `"Name: "`, so the turns read the same
      whoever replies (a prompt cache can reuse them). Text prompts are `"Name: line"` either way.

  One table rather than two because a prompt's ordered list mixes both kinds, which keeps
  `Mythweaver.Prompts.PromptBlock`'s foreign key single-target.
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Accounts.User
  alias Mythweaver.Prompts.PromptBlock
  alias Mythweaver.Templates

  schema "prompt_blocks" do
    field :name, :string
    field :description, :string
    field :role, Ecto.Enum, values: [:system, :user, :assistant], default: :system
    field :kind, Ecto.Enum, values: [:template, :chat_history], default: :template
    field :content, :string
    field :enabled, :boolean, default: true
    field :speaker_roles, Ecto.Enum, values: [:responder, :fixed], default: :responder
    # Which card prompt replaces this block (`Mythweaver.Prompts.Builder`): `:main` a card's system
    # prompt, `:post_history` its post-history instructions. `forbid_overrides` keeps the block's own
    # text and drops the card's.
    field :role_tag, Ecto.Enum, values: [:main, :post_history]
    field :forbid_overrides, :boolean, default: false

    has_many :prompt_blocks, PromptBlock, foreign_key: :block_id
    has_many :prompts, through: [:prompt_blocks, :prompt]

    field :site_visibility, Ecto.Enum, values: [:readable, :runtime_only], default: :readable

    belongs_to :user, User
    # What `Mythweaver.Sharing.Clone` copied this from (no FK: the source may go). Never cast.
    field :cloned_from_type, Ecto.Enum,
      values: [
        :character,
        :lore_book,
        :prompt,
        :block,
        :outlet,
        :script,
        :memory_profile,
        :side_prompt,
        :side_prompt_set,
        :ai_model
      ]

    field :cloned_from_id, Ecto.UUID
    # The catalog release a clone from a listing was made of (`Mythweaver.Catalog`).
    field :cloned_from_release_id, Ecto.UUID
    # Set on a catalog mirror row (`Mythweaver.Catalog`): its listing and the live row it copies.
    # Never cast.
    field :frozen_listing_id, Ecto.UUID
    field :mirror_of_id, Ecto.UUID

    timestamps(type: :utc_datetime)
  end

  @doc "The block's kind."
  def kind(%__MODULE__{kind: kind}), do: kind

  @doc "Short badge label for `kind/1`."
  def kind_label(%__MODULE__{} = block) do
    case kind(block) do
      :template -> dpgettext("prompts", "badge: kind of prompt block, a Liquid template", "template")
      :chat_history -> dpgettext("prompts", "badge: kind of prompt block, the chat transcript marker", "chat history")
    end
  end

  @doc false
  def changeset(block, attrs) do
    block
    |> cast(attrs, [
      :name,
      :description,
      :role,
      :kind,
      :content,
      :enabled,
      :speaker_roles,
      :site_visibility,
      :role_tag,
      :forbid_overrides
    ])
    |> validate_required([:name, :role, :kind])
    |> validate_kind_content()
    |> Templates.validate(:content)
    |> validate_site_visibility()
    |> unique_constraint(:name, name: :prompt_blocks_user_id_name_index)
  end

  # A chat-history block has no text, so stale content from a former template is cleared, and it
  # can't take a card prompt's place, so its role tag goes too.
  defp validate_kind_content(changeset) do
    if get_field(changeset, :kind) == :chat_history do
      changeset
      |> put_change(:content, nil)
      |> put_change(:role_tag, nil)
      |> put_change(:forbid_overrides, false)
    else
      validate_required(changeset, [:content])
    end
  end

  # A site row may hide its protected content from users; a personal row is only ever its owner's.
  defp validate_site_visibility(changeset) do
    if get_field(changeset, :user_id) != nil and get_field(changeset, :site_visibility) != :readable,
      do: add_error(changeset, :site_visibility, dgettext_noop("errors", "only site items can be runtime-only")),
      else: changeset
  end
end
