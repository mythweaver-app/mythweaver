defmodule Mythweaver.Messages.Message do
  @moduledoc """
  One turn in a chat: who spoke, where in the order, and one or more alternative bodies.

  An author is exactly one of two things, enforced by `validate_author/1`: a `Character` (via
  `author_character_id`) or a detached string `author_name`. The string form lets an imported
  transcript keep a speaker that has no character row in this app.

  A message owns its swipes: `has_many :bodies`, of which exactly one is `active`. A message is
  created with exactly one body (`validate_single_body/1`); further bodies arrive through
  `Mythweaver.Messages.add_body/2` or `add_generating_body/1`. `generating_changeset/2` is the
  streaming sibling of `create_changeset/2`, needed because the latter's `cast_assoc` is hard-wired to
  `MessageBody.initial_changeset/2`, which requires content.

  `position` and `chat_id` are set by `Mythweaver.Messages` and are deliberately not castable.

  `author_is_player` records whether the author was the chat's player character when the message
  was created, the AI writing as the player included. It is frozen on the row so switching who the
  user plays as re-brands only later messages, never history. Like `position`, it is never cast:
  `put_author_is_player/2` sets it from the chat at insert time. Reattribution
  (`Mythweaver.Messages.reattribute_message/3`) leaves it alone too: it marks what the user wrote,
  whoever the message is now attributed to. In an assistant chat (`Chat.kind == :assistant`) every
  string author except `assistant_author/0` is the user.

  `author_user_id` is the account that sent a human message (`Mythweaver.Messages.send_message/5`
  stamps it from the scope); nil for AI replies and older rows. Never cast. A guest's own-message
  edit and delete rights (`Mythweaver.Chats.authorize/3`) follow it.
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Accounts.User
  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Attachments.MessageAttachment
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Messages.MessageBody

  @type t :: %__MODULE__{}

  @assistant_author "Assistant"

  @doc "The `author_name` of the replies in an assistant chat."
  def assistant_author, do: @assistant_author

  schema "messages" do
    field :position, :integer
    field :draft, :boolean, default: false
    field :author_is_character, :boolean
    field :author_name, :string
    field :visible_to_ai, :boolean, default: true
    # An assistant thread's compaction summary; set only by `Messages.create_assistant_summary/1`.
    field :summary, :boolean, default: false
    field :author_is_player, :boolean, default: false

    belongs_to :chat, Chat
    belongs_to :author_character, Character, foreign_key: :author_character_id
    belongs_to :author_user, User
    has_many :bodies, MessageBody
    # v7 ids are insertion-ordered, so `id` order is attach order.
    many_to_many :attachments, Attachment, join_through: MessageAttachment, preload_order: [asc: :id]

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The active swipe, or nil when there is none or bodies are not loaded."
  @spec active_body(t()) :: MessageBody.t() | nil
  def active_body(%__MODULE__{bodies: bodies}) when is_list(bodies), do: Enum.find(bodies, & &1.active)
  def active_body(%__MODULE__{}), do: nil

  @doc "The active swipe's content, or nil."
  @spec active_content(t()) :: String.t() | nil
  def active_content(%__MODULE__{} = message), do: (body = active_body(message)) && body.content

  @doc "The message's attachments when loaded, else `[]`."
  @spec loaded_attachments(t()) :: [Attachment.t()]
  def loaded_attachments(%__MODULE__{attachments: list}) when is_list(list), do: list
  def loaded_attachments(_), do: []

  @doc "Stamps `author_is_player` from the chat's player as of now; see the moduledoc."
  def put_author_is_player(changeset, %Chat{kind: :assistant}) do
    put_change(
      changeset,
      :author_is_player,
      get_field(changeset, :author_is_character) == false and get_field(changeset, :author_name) != @assistant_author
    )
  end

  def put_author_is_player(changeset, %Chat{player_character_id: player_id}) do
    author_id = get_field(changeset, :author_character_id)

    put_change(
      changeset,
      :author_is_player,
      get_field(changeset, :author_is_character) == true and author_id != nil and author_id == player_id
    )
  end

  @author_fields [:author_is_character, :author_character_id, :author_name]

  @doc false
  def create_changeset(message, attrs), do: initial_changeset(message, attrs, &MessageBody.initial_changeset/2)

  @doc "`create_changeset/2` for a message sent with attachments: its body may be blank."
  def attached_changeset(message, attrs), do: initial_changeset(message, attrs, &MessageBody.attached_changeset/2)

  @doc false
  def generating_changeset(message, attrs, guide \\ nil) do
    message
    |> author_changeset(attrs, [:visible_to_ai | @author_fields])
    |> put_assoc(:bodies, [MessageBody.streaming_changeset(%MessageBody{guide: guide}, %{})])
    |> insert_constraints()
  end

  @doc false
  def update_changeset(message, attrs), do: author_changeset(message, attrs, [:visible_to_ai | @author_fields])

  @doc false
  def reattribute_changeset(message, attrs), do: author_changeset(message, attrs, @author_fields)

  @doc "A new chat's greeting (`Mythweaver.Messages.post_greeting/5`): one or more swipes, exactly one active."
  def greeting_changeset(message, attrs) do
    message
    |> author_changeset(attrs, @author_fields)
    |> cast_assoc(:bodies, with: &MessageBody.greeting_changeset/2, required: true)
    |> validate_one_active()
    |> insert_constraints()
  end

  defp initial_changeset(message, attrs, body_changeset) do
    message
    |> author_changeset(attrs, [:visible_to_ai | @author_fields])
    |> cast_assoc(:bodies, with: body_changeset, required: true)
    |> validate_single_body()
    |> insert_constraints()
  end

  defp author_changeset(message, attrs, fields) do
    message
    |> cast(attrs, fields)
    |> validate_required([:author_is_character])
    |> validate_author()
  end

  defp insert_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:chat_id)
    |> unique_constraint([:chat_id, :position])
  end

  defp validate_author(changeset) do
    case get_field(changeset, :author_is_character) do
      true ->
        changeset
        |> validate_required([:author_character_id])
        |> forbid(:author_name, dgettext_noop("errors", "must be blank for a character author"))
        |> assoc_constraint(:author_character)

      false ->
        changeset
        |> validate_required([:author_name])
        |> forbid(:author_character_id, dgettext_noop("errors", "must be blank for a string author"))

      nil ->
        changeset
    end
  end

  defp forbid(changeset, field, message) do
    if get_field(changeset, field) == nil do
      changeset
    else
      add_error(changeset, field, message)
    end
  end

  defp validate_single_body(changeset) do
    case get_field(changeset, :bodies) || [] do
      [_one] -> changeset
      _ -> add_error(changeset, :bodies, dgettext_noop("errors", "must have exactly one initial body"))
    end
  end

  defp validate_one_active(changeset) do
    changeset
    |> get_change(:bodies, [])
    |> Enum.count(&(get_field(&1, :active) == true))
    |> case do
      1 -> changeset
      _ -> add_error(changeset, :bodies, dgettext_noop("errors", "must have exactly one active body"))
    end
  end
end
