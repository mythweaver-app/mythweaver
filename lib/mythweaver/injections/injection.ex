defmodule Mythweaver.Injections.Injection do
  @moduledoc """
  Short-lived, per-chat prompt text outside a prompt's blocks. A Liquid template rendered into a lore
  slot after that slot's lore, or into chat history at `depth` with `role` (`position: :at_depth`).

  `uses` is the number of successful replies it lasts for, `nil` for until removed. `remaining`
  counts those down; only `Mythweaver.Injections` sets it. A spent injection (`remaining == 0`) stays
  listed, inactive, until re-armed or cleaned up.
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Chats.Chat
  alias Mythweaver.Templates

  @type t :: %__MODULE__{}

  @key_format ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  schema "chat_injections" do
    field :key, :string
    field :content, :string

    # Literal lockstep with `Lore.Settings.slots/0`; a test enforces it.
    field :position, Ecto.Enum,
      values: [
        :before_character,
        :after_character,
        :before_examples,
        :after_examples,
        :at_depth,
        :before_author_note,
        :after_author_note
      ],
      default: :after_author_note

    field :depth, :integer, default: 4
    field :role, Ecto.Enum, values: [:system, :user, :assistant], default: :system
    field :condition, :string
    field :enabled, :boolean, default: true
    field :uses, :integer
    field :remaining, :integer
    field :order, :integer, default: 100

    belongs_to :chat, Chat

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(injection, attrs) do
    injection
    |> cast(attrs, [:key, :content, :position, :depth, :role, :condition, :enabled, :uses, :order])
    |> validate_required([:key, :content, :position])
    |> validate_length(:key, max: 64)
    |> validate_format(:key, @key_format,
      message:
        dgettext_noop(
          "errors",
          "must start with a letter or underscore and contain only letters, digits, and underscores"
        )
    )
    |> validate_number(:depth, greater_than_or_equal_to: 0)
    |> validate_number(:uses, greater_than: 0)
    |> validate_number(:order, greater_than_or_equal_to: 0)
    |> Templates.validate(:content)
    |> Templates.validate_condition(:condition)
    |> sync_remaining()
    |> unique_constraint(:key,
      name: :chat_injections_chat_id_key_index,
      message: dgettext_noop("errors", "is already taken")
    )
  end

  # A new injection, or a changed lifetime, starts with its full count.
  defp sync_remaining(changeset) do
    if changeset.data.__meta__.state == :built or changed?(changeset, :uses),
      do: put_change(changeset, :remaining, get_field(changeset, :uses)),
      else: changeset
  end

  @doc "Whether a limited injection has used up its replies."
  def spent?(%__MODULE__{uses: uses, remaining: remaining}), do: not is_nil(uses) and remaining == 0

  @doc "Whether the injection applies to the next generation: enabled and not spent."
  def active?(%__MODULE__{} = injection), do: injection.enabled and not spent?(injection)

  @doc "Select options for `position`, in `Lore.Settings.slots/0` order."
  def position_options do
    [
      {dpgettext("chat", "option: where an injection's text is inserted", "Before character"), :before_character},
      {dpgettext("chat", "option: where an injection's text is inserted", "After character"), :after_character},
      {dpgettext("chat", "option: where an injection's text is inserted", "Before examples"), :before_examples},
      {dpgettext("chat", "option: where an injection's text is inserted", "After examples"), :after_examples},
      {dpgettext("chat", "option: where an injection's text is inserted", "In chat history, at depth"), :at_depth},
      {dpgettext("chat", "option: where an injection's text is inserted", "Before author's note"), :before_author_note},
      {dpgettext("chat", "option: where an injection's text is inserted", "After author's note"), :after_author_note}
    ]
  end
end
