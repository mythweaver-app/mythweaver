defmodule Mythweaver.AI.ProviderModel do
  @moduledoc """
  The link between a provider connection and a model, with its own wiring fields.

  Selection state (`selection_deadline`) lives here rather than on either side because selection
  rotates over pairs: the same model served by three providers is three competing slots, each with
  its own share of the traffic. `last_used_at`/`use_count` sit beside it as per-pair audit fields.
  All three are set programmatically by `Mythweaver.AI` and are deliberately not castable.
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.AI.Model
  alias Mythweaver.AI.Provider
  alias Mythweaver.AI.ScalarMap

  schema "provider_models" do
    field :enabled, :boolean, default: true

    # The same logical model has different ids per provider: `gemma-4` locally versus
    # `google/gemma-4-31b-it` on OpenRouter.
    field :api_model_id_override, :string

    # Share of traffic within a priority tier, not a preference order: weights 3/2/1 across three
    # links send exactly 3x and 2x the calls of the 1-weight link, and the 1-weight link is never
    # starved. Consumed by `selection_deadline` advancement in `Mythweaver.AI`.
    field :weight, :integer, default: 1

    # Final layer of the request body extras: deep-merged over the model's and the connection's.
    field :extra_body, :map, default: %{}

    # Overrides the connection's thinking dialect; nil inherits the connection's dialect. Same values
    # as `Provider.thinking_dialect`, in lockstep with `ThinkingDialect`'s `@dialects`. A link cannot
    # force "no dialect" over a connection that has one; `extra_body` already covers that.
    field :thinking_dialect, Ecto.Enum, values: [:openai, :openrouter, :llama_cpp]

    # Overrides the connection's sampler dialect; nil inherits. Same values as
    # `Provider.sampler_dialect`, in lockstep with `SamplerDialect`'s `@dialects`.
    field :sampler_dialect, Ecto.Enum, values: [:openai, :openrouter, :llama_cpp]

    field :last_used_at, :utc_datetime_usec
    field :use_count, :integer, default: 0

    # EDF virtual deadline: selection takes the smallest, then advances it by `1 / weight`. A higher
    # weight advances in smaller steps, so the link comes back to the front sooner and receives
    # proportionally more traffic. Set programmatically by `Mythweaver.AI` and deliberately not
    # castable: a user editing this by hand would corrupt the schedule for every sibling link.
    field :selection_deadline, :float, default: 0.0

    belongs_to :provider, Provider
    belongs_to :model, Model, foreign_key: :ai_model_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(provider_model, attrs) do
    provider_model
    |> cast(attrs, [
      :provider_id,
      :ai_model_id,
      :enabled,
      :api_model_id_override,
      :weight,
      :extra_body,
      :thinking_dialect,
      :sampler_dialect
    ])
    |> validate_required([:provider_id, :ai_model_id])
    |> validate_number(:weight, greater_than_or_equal_to: 1)
    |> ScalarMap.validate_json(:extra_body)
    |> assoc_constraint(:provider)
    |> assoc_constraint(:model)
    # `:ai_model_id` leads the field list so `Ecto.Changeset` puts the error on the model: the
    # field a UI actually renders (the provider is the page, the model is the chosen input), and the
    # only reading under which "is already linked to this provider" is a sentence.
    |> unique_constraint([:ai_model_id, :provider_id],
      name: :provider_models_provider_id_ai_model_id_index,
      message: dgettext_noop("errors", "is already linked to this provider")
    )
  end

  @doc """
  The wire id this link should send: the per-provider override when set, else the model's own id.

  Requires `:model` to be loaded; an unloaded association raises rather than silently querying.
  """
  def effective_model_id(%__MODULE__{api_model_id_override: override}) when is_binary(override) and override != "",
    do: override

  def effective_model_id(%__MODULE__{model: %Model{api_model_id: api_model_id}}), do: api_model_id
end
