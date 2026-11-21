defmodule Mythweaver.AI.Provider do
  @moduledoc """
  One API connection: an adapter implementation, a base URL, and the single credential it needs.

  A provider holds no model list of its own. Models are shared rows joined through
  `Mythweaver.AI.ProviderModel`, because the same model is usually reachable through several
  connections and selection rotates between them.

  `user_id` nil is a site connection, managed by admins and run by the site's models; set, it is
  that user's own ("bring your own provider"), seen and run only by them. Only `Mythweaver.AI` sets
  it. `api_key` is encrypted at rest (`Mythweaver.Encrypted.Binary`).
  """

  use Mythweaver.Schema
  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Changeset

  alias Mythweaver.Accounts.User
  alias Mythweaver.AI.ProviderModel
  alias Mythweaver.AI.ScalarMap
  alias Mythweaver.Encrypted.Binary

  schema "providers" do
    field :name, :string

    # The behaviour-implementation selector. An enum, not a module string: resolving user input with
    # `String.to_existing_atom` is forbidden, and an enum makes this the one place a community
    # adapter is registered. MUST stay in lockstep with `Mythweaver.AI.Provider.Adapter`'s
    # `@adapters` map, which maps these atoms to modules.
    field :adapter, Ecto.Enum, values: [:openai_compatible], default: :openai_compatible

    # How `SamplerParams.thinking` is translated onto the wire. Must stay in lockstep with
    # `Mythweaver.AI.Provider.ThinkingDialect`'s `@dialects`. `nil` means the effort is not translated:
    # no thinking keys are sent.
    field :thinking_dialect, Ecto.Enum, values: [:openai, :openrouter, :llama_cpp]

    # How typed `SamplerParams` fields are named on the wire. Must stay in lockstep with
    # `Mythweaver.AI.Provider.SamplerDialect`'s `@dialects`. `nil` is the generic dialect: canonical
    # names (vLLM, TabbyAPI, others).
    field :sampler_dialect, Ecto.Enum, values: [:openai, :openrouter, :llama_cpp]

    field :base_url, :string
    field :api_key, Binary, redact: true
    field :enabled, :boolean, default: true

    # Lower number = preferred, and it outranks link `weight` entirely: a priority-1 connection takes
    # every call while enabled, so "free before paid" needs no weighting. Weight then splits traffic
    # among the connections *within* one tier. Same 1..5 scale as `Lore.LoreBook.priority`.
    field :priority, :integer, default: 3

    field :extra_headers, :map, default: %{}
    field :extra_body, :map, default: %{}

    # 120s, set by measurement: a cold llama.cpp model load took ~45s and `Req`'s default is 15s.
    field :request_timeout_ms, :integer, default: 120_000

    # How many generations `Mythweaver.Jobs.Scheduler` runs on this connection at once. A hosted
    # provider can take more; a self-hosted one (llama.cpp) keeps 1.
    field :max_concurrency, :integer, default: 1

    # The connection asks its adapter for prompt-processing progress; each adapter decides what that
    # means on its own wire (`Mythweaver.AI.Provider.Adapter`, "Progress contract"). Off by default:
    # the OpenAI-compatible adapter honors it by sending a key hosted APIs (OpenAI) reject with a 400.
    field :prompt_progress, :boolean, default: false

    belongs_to :user, User
    has_many :provider_models, ProviderModel
    has_many :models, through: [:provider_models, :model]

    # How many models link to this connection; set only by `Mythweaver.AI.list_providers/1`.
    field :model_count, :integer, virtual: true

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(provider, attrs) do
    provider
    |> cast(attrs, [
      :name,
      :adapter,
      :thinking_dialect,
      :sampler_dialect,
      :base_url,
      :api_key,
      :enabled,
      :priority,
      :extra_headers,
      :extra_body,
      :request_timeout_ms,
      :max_concurrency,
      :prompt_progress
    ])
    |> validate_required([:name, :adapter, :base_url])
    |> validate_format(:base_url, ~r{\Ahttps?://},
      message: dgettext_noop("errors", "must start with http:// or https://")
    )
    |> trim_trailing_slash()
    |> validate_inclusion(:priority, 1..5)
    |> validate_number(:request_timeout_ms, greater_than: 0)
    |> validate_number(:max_concurrency, greater_than_or_equal_to: 1)
    |> check_constraint(:max_concurrency, name: :providers_max_concurrency_positive)
    |> ScalarMap.validate(:extra_headers)
    |> ScalarMap.validate_json(:extra_body)
    |> unique_constraint(:name, name: :providers_user_id_name_index)
  end

  # So `http://host:8080/v1/` and `http://host:8080/v1` behave identically once a path is appended.
  defp trim_trailing_slash(changeset) do
    case get_change(changeset, :base_url) do
      nil -> changeset
      url -> put_change(changeset, :base_url, String.trim_trailing(url, "/"))
    end
  end
end
