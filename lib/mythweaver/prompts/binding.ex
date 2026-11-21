defmodule Mythweaver.Prompts.Binding do
  @moduledoc """
  One binding of a prompt to a scope, with CSS-like specificity.

  `scope` is stored rather than derived from which columns are set, so `Mythweaver.Prompts.resolve_prompt/1`
  is a single indexed comparison instead of a NULL-pattern puzzle. `changeset/2` then guarantees the
  stored scope and the populated columns agree.

  "Connection" is the user-facing word for `Mythweaver.AI.Provider`, whose moduledoc already calls itself
  one API connection; there is no `connections` table.
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.AI.Model
  alias Mythweaver.AI.Provider
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Prompts.Prompt

  @scopes [:global, :connection, :model, :character, :chat, :character_in_chat]

  # scope => {required columns, columns that must be nil}
  @columns %{
    global: {[], [:provider_id, :ai_model_id, :character_id, :chat_id]},
    connection: {[:provider_id], [:ai_model_id, :character_id, :chat_id]},
    model: {[:ai_model_id], [:provider_id, :character_id, :chat_id]},
    character: {[:character_id], [:provider_id, :ai_model_id, :chat_id]},
    chat: {[:chat_id], [:provider_id, :ai_model_id, :character_id]},
    character_in_chat: {[:character_id, :chat_id], [:provider_id, :ai_model_id]}
  }

  schema "prompt_bindings" do
    field :scope, Ecto.Enum, values: @scopes

    belongs_to :prompt, Prompt
    belongs_to :provider, Provider, foreign_key: :provider_id
    belongs_to :model, Model, foreign_key: :ai_model_id
    belongs_to :character, Character, foreign_key: :character_id
    belongs_to :chat, Chat, foreign_key: :chat_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(binding, attrs) do
    binding
    |> cast(attrs, [:prompt_id, :scope, :provider_id, :ai_model_id, :character_id, :chat_id])
    |> validate_required([:prompt_id, :scope])
    |> validate_scope_columns()
    |> assoc_constraint(:prompt)
    |> assoc_constraint(:provider)
    |> assoc_constraint(:model)
    |> assoc_constraint(:character)
    |> assoc_constraint(:chat)
    |> unique_constraint([:scope, :prompt_id, :provider_id, :ai_model_id, :character_id, :chat_id],
      name: :prompt_bindings_scope_target_index,
      message: dgettext_noop("errors", "already binds this prompt at this scope")
    )
  end

  defp validate_scope_columns(changeset) do
    case get_field(changeset, :scope) do
      nil ->
        changeset

      scope ->
        {required, forbidden} = Map.fetch!(@columns, scope)

        changeset =
          Enum.reduce(required, changeset, fn field, acc ->
            if get_field(acc, field),
              do: acc,
              else:
                add_error(acc, :scope, dgettext_noop("errors", "a %{binding_scope} binding needs %{column_name}"),
                  binding_scope: scope,
                  column_name: field
                )
          end)

        Enum.reduce(forbidden, changeset, fn field, acc ->
          if get_field(acc, field),
            do:
              add_error(acc, :scope, dgettext_noop("errors", "a %{binding_scope} binding must not set %{column_name}"),
                binding_scope: scope,
                column_name: field
              ),
            else: acc
        end)
    end
  end
end
