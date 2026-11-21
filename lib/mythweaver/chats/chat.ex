defmodule Mythweaver.Chats.Chat do
  @moduledoc """
  A conversation: its cast of `Participant`s, which of them the player speaks as, and its default
  model.

  Two invariants are enforced at create time: at least two participants, and the
  `player_character_id` must be one of them. The player rung matters beyond bookkeeping:
  automatic turns (`Mythweaver.Generation.TurnPolicy`) never pick the player, whose lines are
  usually typed; a reply for the player is generated only when explicitly asked for.

  `ai_model_id` is the middle rung of `Mythweaver.Generation.model_for/3`'s ladder and is nullable:
  unset falls through to `Mythweaver.AI.default_model/1`. An assistant thread's `ai_model_id` is the
  first rung of `Mythweaver.Assistant.model/2` and must be a chat-mode model.

  `update_changeset/2` does not touch participants; membership changes go through
  `Mythweaver.Chats.add_participants/2` so the two-participant floor cannot be violated by a partial
  cast.

  Turn-taking settings (`reply_strategy`, `allow_self_responses`, `max_turns`, `auto_mode_delay`) are
  read by `Mythweaver.Generation.TurnPolicy` and the per-chat conductor. `participants` preload in
  speaking order (`position`).

  `group_cards` is SillyTavern's group generation handling mode: whose cards a reply sees besides the
  responder's and the player's (`card_character_ids/2`). `:swap` (the default) none, `:join` the
  other unmuted participants, `:join_all` every participant. It decides both
  `anchors.other_characters` and which character-bound lore books activate.

  `last_activity_at` is when something a reader should notice last happened (a message was created,
  or a generation produced tokens); `last_read_at` is the owner's read cursor, the `last_activity_at`
  the owner's tab last showed (each accepted member has their own, `Member`'s `last_read_at`). The
  chat picker's unread dot is `last_activity_at` past the viewer's cursor. Neither is castable: only
  `Mythweaver.Messages.touch_activity/1` and `Mythweaver.Messages.mark_read/2` set them.

  `last_opened_at` is when the owner last opened the chat, so `/` reopens it
  (`Mythweaver.Chats.mark_opened/2`, its only writer).

  `kind` is `:roleplay`, or `:assistant` for a "Chat with Mythweaver" thread
  (`Mythweaver.Assistant`), which has no participants and no player. It is never castable:
  `assistant_changeset/2` creates and updates assistant chats.

  Sharing (`Mythweaver.Chats.Member`): `guest_permissions` holds the guest toggles, read through
  `guest_permissions/1`, which fills the defaults in; `guests_bring_characters` lets guests add their
  own characters, `free_switching` lets members take any participant themselves, shared with
  whoever else plays it, and release them one at a time (`Mythweaver.Chats.CharacterLock`), and
  `turn_mode` `:round` waits for every locked member before the AI replies.

  `greeting` and `greeting_text` are virtual creation-only choices that `Mythweaver.Greetings.post/2`
  reads off the inserted struct; they are never stored.
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Accounts.User
  alias Mythweaver.AI.Model
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats.Participant

  @type t :: %__MODULE__{}

  @reply_strategies [:manual, :natural, :list, :pooled]
  @group_cards [:swap, :join, :join_all]
  @guest_permission_defaults %{
    "edit_own" => true,
    "delete_own" => true,
    "regenerate" => true,
    "trigger_replies" => true,
    "run_scripts" => false,
    "attach" => true
  }

  schema "chats" do
    field :kind, Ecto.Enum, values: [:roleplay, :assistant], default: :roleplay
    field :name, :string
    field :reply_strategy, Ecto.Enum, values: @reply_strategies, default: :manual
    field :allow_self_responses, :boolean, default: false
    field :max_turns, :integer
    field :auto_mode_delay, :integer, default: 5
    field :group_cards, Ecto.Enum, values: @group_cards, default: :swap
    field :last_activity_at, :utc_datetime_usec
    field :last_read_at, :utc_datetime_usec
    field :last_opened_at, :utc_datetime_usec
    field :guest_permissions, :map, default: %{}
    field :guests_bring_characters, :boolean, default: false
    field :free_switching, :boolean, default: false
    field :turn_mode, Ecto.Enum, values: [:any, :round], default: :any
    field :greeting, :string, virtual: true
    field :greeting_text, :string, virtual: true

    belongs_to :player_character, Character, foreign_key: :player_character_id
    has_many :participants, Participant, preload_order: [asc: :position, asc: :id]
    belongs_to :model, Model, foreign_key: :ai_model_id
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  def reply_strategies, do: @reply_strategies
  def group_cards_modes, do: @group_cards

  @doc false
  def create_changeset(chat, attrs) do
    chat
    |> cast(attrs, [:name, :player_character_id, :ai_model_id, :greeting, :greeting_text])
    |> cast_assoc(:participants, with: &Participant.changeset/2, required: true)
    |> put_positions()
    |> validate_min_participants()
    |> validate_player_is_participant()
    |> validate_greeting()
    |> foreign_key_constraint(:player_character_id)
    |> foreign_key_constraint(:ai_model_id)
  end

  @doc false
  def assistant_changeset(chat, attrs) do
    chat
    |> cast(attrs, [:name, :ai_model_id])
    |> put_change(:kind, :assistant)
    |> foreign_key_constraint(:ai_model_id)
  end

  @doc false
  def update_changeset(chat, attrs) do
    chat
    |> cast(attrs, [
      :name,
      :player_character_id,
      :ai_model_id,
      :reply_strategy,
      :allow_self_responses,
      :max_turns,
      :auto_mode_delay,
      :group_cards,
      :guest_permissions,
      :guests_bring_characters,
      :free_switching,
      :turn_mode
    ])
    |> validate_turn_settings()
    |> validate_guest_permissions()
    |> validate_player_is_participant()
    |> foreign_key_constraint(:player_character_id)
    |> foreign_key_constraint(:ai_model_id)
  end

  @doc false
  def membership_changeset(chat, attrs) do
    chat
    |> cast(attrs, [:guest_permissions, :guests_bring_characters, :free_switching, :turn_mode])
    |> validate_guest_permissions()
  end

  # Only the known toggles, each a boolean.
  defp validate_guest_permissions(changeset) do
    validate_change(changeset, :guest_permissions, fn :guest_permissions, perms ->
      if Enum.all?(perms, fn {k, v} -> Map.has_key?(@guest_permission_defaults, k) and is_boolean(v) end),
        do: [],
        else: [guest_permissions: dgettext_noop("errors", "is invalid")]
    end)
  end

  @doc """
  The chat's guest toggles (`"edit_own"`, `"delete_own"`, `"regenerate"`, `"trigger_replies"`,
  `"run_scripts"`, `"attach"`), the stored ones over the defaults.
  """
  @spec guest_permissions(t()) :: %{String.t() => boolean()}
  def guest_permissions(%__MODULE__{guest_permissions: perms}),
    do: Map.merge(@guest_permission_defaults, Map.take(perms || %{}, Map.keys(@guest_permission_defaults)))

  @doc "The turn-taking bounds, shared with `Mythweaver.Chats.change_settings/2`'s schemaless form."
  @spec validate_turn_settings(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_turn_settings(changeset) do
    changeset
    |> validate_number(:max_turns, greater_than: 0)
    |> validate_number(:auto_mode_delay, greater_than_or_equal_to: 1, less_than_or_equal_to: 999)
  end

  @doc "The chat's display name."
  @spec title(t()) :: String.t()
  def title(%__MODULE__{name: name}),
    do: name || dpgettext("chat", "placeholder: name shown for a chat that has no name", "Untitled chat")

  @doc "The participants other than the player."
  @spec bots(t()) :: [Participant.t()]
  def bots(%__MODULE__{} = chat), do: Enum.reject(chat.participants, &(&1.character_id == chat.player_character_id))

  @doc "The name of the participant playing `character_id`, or nil when absent."
  @spec participant_name(t(), Ecto.UUID.t() | nil) :: String.t() | nil
  def participant_name(%__MODULE__{participants: participants}, character_id) do
    participants
    |> List.wrap()
    |> Enum.find_value(&(&1.character_id == character_id && &1.character && &1.character.name))
  end

  @doc "The participants' characters in speaking order; `[]` when participants are not loaded."
  @spec characters(t()) :: [Character.t() | nil]
  def characters(%__MODULE__{participants: participants}) when is_list(participants),
    do: Enum.map(participants, & &1.character)

  def characters(%__MODULE__{}), do: []

  @doc "The responding character: the first participant character who isn't the player."
  @spec responder(t()) :: Character.t() | nil
  def responder(%__MODULE__{} = chat) do
    chat
    |> characters()
    |> Enum.filter(&is_struct/1)
    |> Enum.find(&(&1.id != chat.player_character_id))
  end

  @doc """
  The characters whose cards and bound lore a reply by `responder_id` sees, per `group_cards`: the
  responder and the player always; with `:join` also every unmuted participant, with `:join_all`
  every participant. A nil responder (a lore preview, no reply yet) sees every participant.
  """
  @spec card_character_ids(t(), Ecto.UUID.t() | nil) :: [Ecto.UUID.t()]
  def card_character_ids(%__MODULE__{participants: participants} = chat, responder_id) do
    participants = List.wrap(participants)

    others =
      case {responder_id, chat.group_cards} do
        {nil, _mode} -> participants
        {_id, :join_all} -> participants
        {_id, :join} -> Enum.reject(participants, & &1.muted)
        {_id, _swap} -> []
      end

    Enum.uniq(Enum.reject([responder_id, chat.player_character_id], &is_nil/1) ++ Enum.map(others, & &1.character_id))
  end

  defp put_positions(changeset) do
    case get_change(changeset, :participants) do
      nil ->
        changeset

      participants ->
        positioned = Enum.with_index(participants, fn cs, i -> put_change(cs, :position, i) end)

        put_change(changeset, :participants, positioned)
    end
  end

  defp validate_min_participants(changeset) do
    if length(get_field(changeset, :participants) || []) >= 2 do
      changeset
    else
      add_error(changeset, :participants, dgettext_noop("errors", "must have at least 2 participants"))
    end
  end

  defp validate_player_is_participant(changeset) do
    case get_field(changeset, :player_character_id) do
      nil ->
        changeset

      character_id ->
        ids = changeset |> get_field(:participants) |> List.wrap() |> Enum.map(& &1.character_id)

        if character_id in ids do
          changeset
        else
          add_error(changeset, :player_character_id, dgettext_noop("errors", "must be a participant of the chat"))
        end
    end
  end

  # nil, "random", "all", "custom" (the narrator's text, required) or a non-player participant's
  # character id (`Mythweaver.Greetings`).
  defp validate_greeting(changeset) do
    case get_field(changeset, :greeting) do
      greeting when greeting in [nil, "random", "all"] ->
        changeset

      "custom" ->
        changeset
        |> validate_required(:greeting_text, message: dgettext_noop("errors", "write the narrator's message"))
        |> Mythweaver.Templates.validate(:greeting_text)

      character_id ->
        ids = changeset |> get_field(:participants) |> List.wrap() |> Enum.map(& &1.character_id)

        if character_id in ids and character_id != get_field(changeset, :player_character_id),
          do: changeset,
          else:
            add_error(
              changeset,
              :greeting,
              dgettext_noop("errors", "must be one of the chat's characters other than the player")
            )
    end
  end
end
