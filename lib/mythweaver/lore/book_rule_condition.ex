defmodule Mythweaver.Lore.BookRuleCondition do
  @moduledoc """
  One condition of a `Mythweaver.Lore.BookRule`. `kind` picks the single target it reads:

    * `:chat`: `chat_id` is the chat being replied in
    * `:character_present`: `character_id` is in the reply's card set
    * `:responder`: `character_id` is the character replying
    * `:chat_tag` / `:character_tag`: the chat, or any present character, carries one of `tags`
      (canonical texts, sibling- and parent-expanded through the chat owner's tag graph)
    * `:template`: the Liquid condition expression `template` is true against the chat's stored
      variables

  `negate` inverts the result. A deleted chat or character nilifies its target, which then matches
  nothing (`Mythweaver.Lore.Rules`).
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Lore.BookRule
  alias Mythweaver.Tags
  alias Mythweaver.Templates

  @type t :: %__MODULE__{}
  @type refs :: %{chats: MapSet.t() | :any, characters: MapSet.t() | :any}

  schema "lore_book_rule_conditions" do
    field :position, :integer, default: 0

    field :kind, Ecto.Enum,
      values: [:chat, :character_present, :responder, :chat_tag, :character_tag, :template],
      default: :character_present

    field :negate, :boolean, default: false
    belongs_to :chat, Chat
    belongs_to :character, Character
    field :tags, {:array, :string}, default: []
    field :template, :string

    belongs_to :rule, BookRule, foreign_key: :lore_book_rule_id

    timestamps(type: :utc_datetime)
  end

  @doc """
  `refs` lists the chats and characters this condition may name, or `:any` to skip the check.
  """
  @spec changeset(t(), map(), non_neg_integer() | nil, refs()) :: Ecto.Changeset.t()
  def changeset(condition, attrs, position, refs) do
    changeset = cast(condition, drop_blank_tags(attrs), [:kind, :negate, :chat_id, :character_id, :tags, :template])
    changeset = if is_nil(position), do: changeset, else: put_change(changeset, :position, position)
    kind = get_field(changeset, :kind)

    changeset
    |> clear_unused_targets(kind)
    |> validate_target(kind)
    |> normalize_tags()
    |> validate_ref(:chat_id, refs.chats, dgettext_noop("errors", "is not a chat this book may name"))
    |> validate_ref(:character_id, refs.characters, dgettext_noop("errors", "is not a character this book may name"))
  end

  # The chip input always posts a `""` sentinel.
  defp drop_blank_tags(%{"tags" => tags} = attrs) when is_list(tags),
    do: %{attrs | "tags" => Enum.reject(tags, &(&1 == ""))}

  defp drop_blank_tags(%{tags: tags} = attrs) when is_list(tags), do: %{attrs | tags: Enum.reject(tags, &(&1 == ""))}
  defp drop_blank_tags(attrs), do: attrs

  # A kind switch leaves no stale target behind.
  defp clear_unused_targets(changeset, kind) do
    keep =
      case kind do
        :chat -> :chat_id
        kind when kind in [:character_present, :responder] -> :character_id
        kind when kind in [:chat_tag, :character_tag] -> :tags
        :template -> :template
        _ -> nil
      end

    Enum.reduce([chat_id: nil, character_id: nil, tags: [], template: nil], changeset, fn
      {^keep, _}, changeset -> changeset
      {field, empty}, changeset -> put_change(changeset, field, empty)
    end)
  end

  defp validate_target(changeset, :chat), do: validate_required(changeset, [:chat_id])

  defp validate_target(changeset, kind) when kind in [:character_present, :responder],
    do: validate_required(changeset, [:character_id])

  defp validate_target(changeset, kind) when kind in [:chat_tag, :character_tag] do
    if get_field(changeset, :tags) in [nil, []],
      do: add_error(changeset, :tags, dgettext_noop("errors", "add at least one tag")),
      else: changeset
  end

  defp validate_target(changeset, :template) do
    changeset
    |> validate_required([:template])
    |> validate_length(:template, max: 2000)
    |> Templates.validate_condition(:template)
  end

  defp validate_target(changeset, _kind), do: changeset

  defp normalize_tags(changeset) do
    case get_change(changeset, :tags) do
      [_ | _] = texts ->
        Enum.reduce_while(texts, [], fn text, acc ->
          case Tags.normalize(text) do
            {:ok, {_namespace, _name, canonical}} -> {:cont, [canonical | acc]}
            {:error, reason} -> {:halt, {:error, text, reason}}
          end
        end)
        |> case do
          {:error, text, reason} ->
            add_error(changeset, :tags, tag_error(reason), tag_text: text)

          canonical ->
            put_change(changeset, :tags, canonical |> Enum.reverse() |> Enum.uniq())
        end

      _ ->
        changeset
    end
  end

  # One whole message per `Tags.normalize/1` reason, so the quoted tag and the problem read as one sentence.
  defp tag_error("needs a name"), do: dgettext_noop("errors", "“%{tag_text}” needs a name")
  defp tag_error("can't start with -"), do: dgettext_noop("errors", "“%{tag_text}” can't start with -")
  defp tag_error("can't contain *"), do: dgettext_noop("errors", "“%{tag_text}” can't contain *")
  defp tag_error("is too long"), do: dgettext_noop("errors", "“%{tag_text}” is too long")

  defp validate_ref(changeset, _field, :any, _message), do: changeset

  defp validate_ref(changeset, field, allowed, message) do
    validate_change(changeset, field, fn ^field, id ->
      if MapSet.member?(allowed, id), do: [], else: [{field, message}]
    end)
  end
end
