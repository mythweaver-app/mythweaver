defmodule Mythweaver.AI.SamplerParams do
  @moduledoc """
  Generation parameters for one model, in canonical names; adapters map these onto wire names.

  Every field defaults to `nil`, meaning "send nothing and let the backend decide". A zero is a real
  instruction (`temperature: 0.0` is greedy decoding) and must never be conflated with unset.

  SillyTavern uses two disagreeing name sets for the same knobs (`temp` vs `temp_openai`, `rep_pen`
  vs `repetition_penalty_openai`); neither is copied. Wire names come from the connection's sampler
  dialect (`Mythweaver.AI.Provider.SamplerDialect`, overridable per link), which renames, converts
  or drops typed fields per backend. `extra` is for knobs with no typed field (mirostat, adaptive-P,
  grammar, smoothing): string keys, passed through verbatim into the request body.

  `thinking` is a canonical reasoning effort level, not a wire key. The connection's thinking dialect
  (`Mythweaver.AI.Provider.ThinkingDialect`, overridable per link) translates it into the backend's
  own fields; when neither the connection nor the link has a dialect, nothing is sent for it. The
  translated keys live in the `extra_body` layer, so they beat `extra`: to override a dialect key, set
  it in a model, connection, or link `extra_body`, not here.
  """

  use Ecto.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.AI.ScalarMap

  @thinking_levels [:none, :minimal, :low, :medium, :high, :xhigh, :max]
  @type thinking :: :none | :minimal | :low | :medium | :high | :xhigh | :max

  @fields [
    :temperature,
    :top_p,
    :top_k,
    :min_p,
    :top_a,
    :typical_p,
    :repetition_penalty,
    :frequency_penalty,
    :presence_penalty,
    :repetition_penalty_range,
    :max_tokens,
    :seed,
    :stop_sequences,
    :top_n_sigma,
    :dry_multiplier,
    :dry_base,
    :dry_allowed_length,
    :dry_penalty_last_n,
    :dry_sequence_breakers,
    :xtc_threshold,
    :xtc_probability,
    :dynatemp_low,
    :dynatemp_high,
    :dynatemp_exponent,
    :ignore_eos,
    :skip_special_tokens,
    :sampler_order,
    :logit_bias,
    :thinking,
    :extra
  ]

  # llama.cpp's own `samplers` names (`common/sampling.cpp`), so they go on the wire unchanged.
  @default_sampler_order [
    :penalties,
    :dry,
    :top_n_sigma,
    :top_k,
    :typ_p,
    :top_p,
    :min_p,
    :xtc,
    :temperature
  ]

  @primary_key false
  embedded_schema do
    field :temperature, :float
    field :top_p, :float
    field :top_k, :integer
    field :min_p, :float
    field :top_a, :float
    field :typical_p, :float
    field :repetition_penalty, :float
    field :frequency_penalty, :float
    field :presence_penalty, :float
    field :repetition_penalty_range, :integer
    field :max_tokens, :integer
    field :seed, :integer
    field :stop_sequences, {:array, :string}, default: []
    field :top_n_sigma, :float
    field :dry_multiplier, :float
    field :dry_base, :float
    field :dry_allowed_length, :integer
    field :dry_penalty_last_n, :integer
    field :dry_sequence_breakers, {:array, :string}, default: []
    field :xtc_threshold, :float
    field :xtc_probability, :float
    field :dynatemp_low, :float
    field :dynatemp_high, :float
    field :dynatemp_exponent, :float
    field :ignore_eos, :boolean
    field :skip_special_tokens, :boolean
    field :sampler_order, {:array, Ecto.Enum}, values: @default_sampler_order, default: []
    field :logit_bias, :map, default: %{}
    field :thinking, Ecto.Enum, values: @thinking_levels
    field :extra, :map, default: %{}
  end

  @doc false
  def changeset(params, attrs) do
    params
    |> cast(attrs, @fields -- [:dry_sequence_breakers])
    # A separate cast: the default `empty_values` strips whitespace-only elements from an array, and
    # the most useful breaker is "\n".
    |> cast(attrs, [:dry_sequence_breakers], empty_values: [nil])
    |> validate_number(:temperature, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 5.0)
    |> validate_number(:top_p, greater_than: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:top_k, greater_than_or_equal_to: 0)
    |> validate_number(:min_p, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:top_a, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:typical_p, greater_than: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:repetition_penalty, greater_than: 0.0, less_than_or_equal_to: 4.0)
    |> validate_number(:frequency_penalty,
      greater_than_or_equal_to: -2.0,
      less_than_or_equal_to: 2.0
    )
    |> validate_number(:presence_penalty,
      greater_than_or_equal_to: -2.0,
      less_than_or_equal_to: 2.0
    )
    |> validate_number(:repetition_penalty_range, greater_than_or_equal_to: 0)
    |> validate_number(:max_tokens, greater_than: 0)
    |> validate_number(:top_n_sigma, greater_than_or_equal_to: 0.0)
    |> validate_number(:dry_multiplier, greater_than_or_equal_to: 0.0)
    |> validate_number(:dry_base, greater_than_or_equal_to: 1.0)
    |> validate_number(:dry_allowed_length, greater_than_or_equal_to: 0)
    |> validate_number(:dry_penalty_last_n, greater_than_or_equal_to: 0)
    |> validate_number(:xtc_threshold, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:xtc_probability, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:dynatemp_low, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 5.0)
    |> validate_number(:dynatemp_high, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 5.0)
    |> validate_number(:dynatemp_exponent, greater_than: 0.0, less_than_or_equal_to: 10.0)
    |> validate_change(:dry_sequence_breakers, fn :dry_sequence_breakers, breakers ->
      if Enum.all?(breakers, &(&1 != "")),
        do: [],
        else: [dry_sequence_breakers: dgettext_noop("errors", "breakers must be non-empty strings")]
    end)
    |> validate_change(:sampler_order, fn :sampler_order, order ->
      if order == [] or Enum.sort(order) == Enum.sort(@default_sampler_order),
        do: [],
        else: [sampler_order: dgettext_noop("errors", "must list every sampler exactly once")]
    end)
    |> validate_change(:logit_bias, &validate_logit_bias/2)
    |> validate_dynatemp()
    |> ScalarMap.validate(:extra)
  end

  defp validate_logit_bias(:logit_bias, bias) do
    valid? =
      Enum.all?(bias, fn {key, value} ->
        is_binary(key) and String.trim(key) != "" and
          (value == false or (is_number(value) and value >= -100 and value <= 100))
      end)

    if valid?,
      do: [],
      else: [logit_bias: dgettext_noop("errors", "values must be numbers from -100 to 100, or false to ban")]
  end

  defp validate_dynatemp(changeset) do
    low = get_field(changeset, :dynatemp_low)
    high = get_field(changeset, :dynatemp_high)

    cond do
      is_nil(low) and not is_nil(high) ->
        add_error(
          changeset,
          :dynatemp_low,
          dgettext_noop("errors", "must be set together with the dynamic temperature maximum")
        )

      not is_nil(low) and is_nil(high) ->
        add_error(
          changeset,
          :dynatemp_high,
          dgettext_noop("errors", "must be set together with the dynamic temperature minimum")
        )

      is_nil(low) and not is_nil(get_field(changeset, :dynatemp_exponent)) ->
        add_error(changeset, :dynatemp_exponent, dgettext_noop("errors", "needs a dynamic temperature range"))

      not is_nil(low) and low > high ->
        add_error(changeset, :dynatemp_high, dgettext_noop("errors", "must be at least the minimum"))

      true ->
        changeset
    end
  end

  @doc "llama.cpp's built-in sampler order (`common/common.h`); the starting point for a custom order."
  def default_sampler_order, do: @default_sampler_order

  @doc "The reasoning effort levels, weakest first."
  @spec thinking_levels() :: [thinking()]
  def thinking_levels, do: @thinking_levels

  @doc "Label/level pairs for a Thinking picker, weakest first."
  def thinking_options do
    [
      {dpgettext("ai", "option: model reasoning effort", "Off"), :none},
      {dpgettext("ai", "option: model reasoning effort", "Minimal"), :minimal},
      {dpgettext("ai", "option: model reasoning effort", "Low"), :low},
      {dpgettext("ai", "option: model reasoning effort", "Medium"), :medium},
      {dpgettext("ai", "option: model reasoning effort", "High"), :high},
      {dpgettext("ai", "option: model reasoning effort", "Extra high"), :xhigh},
      {dpgettext("ai", "option: model reasoning effort", "Max"), :max}
    ]
  end

  @doc """
  The level a request asking for `requested` runs at on a model set to `model_level`: never above
  the model's own level. A model on backend default (nil) sets no ceiling, so the request's level
  goes as it is; a request asking for nothing keeps the model's.
  """
  @spec cap_thinking(thinking() | nil, thinking() | nil) :: thinking() | nil
  def cap_thinking(nil, model_level), do: model_level
  def cap_thinking(requested, nil), do: requested

  def cap_thinking(requested, model_level) do
    if rank(requested) <= rank(model_level), do: requested, else: model_level
  end

  defp rank(level), do: Enum.find_index(@thinking_levels, &(&1 == level))

  @doc """
  The set typed fields as an atom-keyed map, for a sampler dialect to name on the wire.

  `extra` and `thinking` are excluded (the adapter and the thinking dialect handle them), and unset
  values (`nil`, `[]`, `%{}`) are absent. A zero or `false` is a real instruction and is kept.
  """
  def set_values(%__MODULE__{} = params) do
    params
    |> Map.from_struct()
    |> Map.drop([:extra, :thinking])
    |> Map.reject(fn {_field, value} -> value in [nil, [], %{}] end)
  end
end
