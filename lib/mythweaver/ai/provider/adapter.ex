defmodule Mythweaver.AI.Provider.Adapter do
  @moduledoc """
  Behaviour every AI provider implementation satisfies.

  A callback receives the `Mythweaver.AI.Provider` row it belongs to, so an implementation reads
  `base_url`, `api_key`, `extra_headers`, and `request_timeout_ms` from one place and
  holds no configuration of its own.

  Add an implementation by writing the module, adding one `{atom, module}` pair to `@adapters` below,
  and adding the same atom to `Mythweaver.AI.Provider`'s `:adapter` enum; nothing else in the app
  needs to change.

  ## Request contract

  The `request` argument to `complete/2` and `stream/3` is a `Mythweaver.AI.Request`. Streaming is a
  transport choice made by calling `stream/3`, not a request, model, or provider setting, so the
  struct is identical:

    * `model_id`: wire id, already resolved through `ProviderModel.effective_model_id/1`
    * `mode`: `:chat | :text`, from `Model.completion_mode`
    * `messages`: `[Mythweaver.AI.Request.Message.t()]` for `mode: :chat`, else `nil`
    * `prompt`: `String.t()` for `mode: :text`, else `nil`
    * `sampler`: `%Mythweaver.AI.SamplerParams{}` or `nil`
    * `sampler_dialect`: `atom() | nil`, the link's `sampler_dialect` or else the connection's;
      `Mythweaver.AI.Provider.SamplerDialect.module_for/1` names the typed sampler fields on the wire
    * `extra_body`: thinking dialect fragment → model → connection → link, deep-merged by
      `Mythweaver.AI`; merged into the body after the sampler. Defaults to `%{}`.
    * `reasoning_tags`: `{prefix, suffix} | nil`, from `Model.reasoning_tags/1`; the adapter splits
      inline reasoning out of content with `Mythweaver.AI.ReasoningParser`
    * `stop`: `[String.t()]`, every string that ends the reply. The adapter must end the reply's
      content at the first one (`Mythweaver.AI.StopScanner`) even when the backend ignored its wire
      `stop`, emit nothing past it, and report `finish_reason: "stop"`; a stream may be abandoned
      there, losing its usage frame.
    * `session_id`: `String.t() | nil`, set on every request of a chat-bound job. The
      OpenAI-compatible adapter sends it as the `x-session-id` header (OpenRouter sticky routing,
      vLLM session affinity, llama-swap's Activity column); nil sends nothing.

  `messages` is required for `:chat` and ignored for `:text`; `prompt` vice versa. An adapter given
  the wrong pair returns `{:error, {:invalid_request, :missing_messages}}` or
  `{:error, {:invalid_request, :missing_prompt}}` rather than crashing. The pair is data-driven by a
  model row's `completion_mode`, so a mismatch is a configuration error the caller must see.

  A `Mythweaver.AI.Request.Message` has a `role` (`:system | :user | :assistant`) and a `content`
  that is a string, or a list of parts:

    * `%Mythweaver.AI.Request.Text{text: String.t()}`
    * `%Mythweaver.AI.Request.Image{media_type: String.t(), data: binary(), detail: :low | :auto | :high | nil}`
    * `%Mythweaver.AI.Request.File{media_type: String.t(), filename: String.t() | nil, data: binary()}`
    * `%Mythweaver.AI.Request.Audio{format: String.t(), data: binary()}`
    * `%Mythweaver.AI.Request.Video{media_type: String.t(), data: binary()}`

  Parts appear only for models where `Mythweaver.AI.Model.sees_images?/1`, `reads_files?/1`,
  `hears_audio?/1` or `watches_video?/1` is true; a part's `data` is its raw bytes, and the adapter
  chooses the wire encoding. `detail` is the model's `image_detail`, sent where the wire format has
  a place for it.
  A new modality adds a part struct. Nothing else is a part: `Mythweaver.Prompts.AttachmentRef` is
  the prompt builder's unread placeholder and an adapter has no clause for it.

  ## HTTP contract

  Every outbound HTTP request an adapter makes (discovery, completion, and streaming alike) carries
  `user_agent/0` as its `user-agent` header. With Req, pass `user_agent: Mythweaver.AI.Provider.Adapter.user_agent()`
  when building the client; never let the library default through. A provider's `extra_headers` may
  still override it, since those are user-configured per connection.

  ## Streaming event contract

  `stream/3` invokes its `on_event` callback with exactly these structs (`Mythweaver.AI.StreamEvent.t()`):

    * `%Mythweaver.AI.StreamEvent.Request{url: String.t(), body: map()}`: emitted once, before the
      HTTP request: the exact JSON body sent (headers omitted, since they carry secrets)
    * `%Mythweaver.AI.StreamEvent.Delta{text: String.t()}`: a content token
    * `%Mythweaver.AI.StreamEvent.Reasoning{text: String.t()}`: a reasoning/thinking token
    * `%Mythweaver.AI.StreamEvent.Done{finish_reason: String.t() | nil}`: generation ended
    * `%Mythweaver.AI.StreamEvent.PromptProgress{done: non_neg_integer(), total: pos_integer()}`:
      optional, prompt tokens processed so far out of the tokens this request must process (see
      "Progress contract")

  Separate token structs rather than one delta with a flag: a consumer renders reasoning in a separate
  collapsed region from content, and matching on the struct is what lets it do that without
  inspecting the model row. A `Reasoning` token comes either from a separate wire field or from
  inline tags parsed out of the content; consumers cannot tell which.

  `Delta` and `Reasoning` never carry empty `text`: a `nil` or `""` token is dropped by the
  adapter rather than pushed to the callback, so a consumer never has to guard against it. Real
  streams produce both: the first chat frame announces the role with `content: null`, the final one
  carries the finish reason with an empty delta.

  An adapter that cannot stream still implements the callback and returns
  `{:error, :streaming_unsupported}`, so a caller gets a decidable answer instead of an
  `UndefinedFunctionError`.

  ## Progress contract

  `StreamEvent.PromptProgress` is the only optional event. An adapter emits it only when its backend
  reports prompt processing, any number of times, before the first `StreamEvent.Delta` or
  `StreamEvent.Reasoning`.

  `done` and `total` count only the tokens the backend actually processes: prompt-cache hits are
  excluded, so `done / total` is the real fraction. `total` is always ≥ 1 (a frame whose uncached
  total is 0 is dropped), and `done` is clamped to `0..total`.

  An adapter that can report progress says so with the optional `prompt_progress?/0` callback
  returning `true`; one that leaves it out cannot, and the connection form hides its opt-in. Ask
  through `prompt_progress?/1`, never the module, so a missing callback reads as `false`.

  `Mythweaver.AI.Provider.prompt_progress` is the connection's opt-in, and each adapter honors it its
  own way. The OpenAI-compatible adapter sends `"return_progress": true`, which llama.cpp and TabbyAPI
  accept; other backends behind it send nothing, so `true` there means "can, on some backends". An
  adapter whose backend reports progress unasked may emit regardless; one that cannot report it
  ignores the flag.

  A consumer must not require the event. Without it, a job falls back to the history estimate
  (`Mythweaver.Jobs.expected_first_token_ms/4`).

  ## Embedding contract

  `embed/2` returns one vector per input text, in input order whatever order the backend answered
  in. Each vector is a non-empty list of floats, and all have the same length. The HTTP contract
  (the `user-agent` header) applies to it like any other request.
  """

  alias Mythweaver.AI.Adapters.OpenAICompatible
  alias Mythweaver.AI.DiscoveredModel
  alias Mythweaver.AI.Embedding
  alias Mythweaver.AI.EmbeddingRequest
  alias Mythweaver.AI.Request
  alias Mythweaver.AI.StreamEvent

  @adapters %{openai_compatible: OpenAICompatible}

  # Compile-time on purpose: `Mix` is unavailable at runtime in a release.
  @user_agent "Mythweaver/#{Mix.Project.config()[:version]}"

  @doc """
  Lists the models the provider advertises, in the order the API returned them.

  Each entry is a `%Mythweaver.AI.DiscoveredModel{id: String.t(), name: String.t() | nil, attrs: map()}`.
  `name` is the friendly name when the API supplies one (llama-swap does), `nil` otherwise. The
  untouched payload entry is not kept: nothing reads it, and it is unbounded remote data.

  `attrs` holds `Mythweaver.AI.Model` field names (string keys) for whatever the payload advertised
  (context/response limits, per-Mtok pricing converted to this app's unit, capability flags) and omits
  every field it did not, so the schema's own defaults survive. It is ready to pass to
  `Model.changeset/2`.

  Values are bounded integers, decimals, and booleans only. Provider free text (an entry's
  `description`) is deliberately dropped rather than mapped onto `notes`: `notes` is user-authored, and
  an arbitrary-length remote string per advertised model is memory a hostile `/models` reply controls.
  """
  @callback discover_models(provider :: struct()) :: {:ok, [DiscoveredModel.t()]} | {:error, term()}

  @doc "Runs one non-streaming completion and normalizes it into an `Mythweaver.AI.Completion`."
  @callback complete(provider :: struct(), request :: Request.t()) :: {:ok, struct()} | {:error, term()}

  @doc "Embeds `request.input` and normalizes the reply into a `Mythweaver.AI.Embedding` (\"Embedding contract\")."
  @callback embed(provider :: struct(), request :: EmbeddingRequest.t()) :: {:ok, Embedding.t()} | {:error, term()}

  @doc """
  Runs one streaming completion, invoking `on_event` for each decoded event as it arrives.

  Returns `{:ok, %Mythweaver.AI.Completion{}}` assembled from the whole stream once it ends, so a
  caller that also wants the final text does not have to accumulate deltas itself.
  """
  @callback stream(
              provider :: struct(),
              request :: Request.t(),
              on_event :: (StreamEvent.t() -> any())
            ) ::
              {:ok, struct()} | {:error, term()}

  @doc "Human-readable adapter name for pickers."
  @callback label() :: String.t()

  @doc """
  Whether this adapter can emit `StreamEvent.PromptProgress` (the "Progress contract"). Optional:
  leaving it out means it cannot.
  """
  @callback prompt_progress?() :: boolean()

  @optional_callbacks prompt_progress?: 0

  @doc """
  The module implementing `adapter`.

  Guards on the registry so an unknown atom raises here instead of surfacing as an
  `UndefinedFunctionError` deep inside a request.
  """
  def module_for(adapter) when is_map_key(@adapters, adapter), do: Map.fetch!(@adapters, adapter)

  @doc "The full `%{atom => module}` registry, for pickers and validation."
  def adapters, do: @adapters

  @doc "Whether `adapter`'s module can report prompt progress; `false` when it omits `prompt_progress?/0`."
  @spec prompt_progress?(atom()) :: boolean()
  def prompt_progress?(adapter) do
    module = module_for(adapter)
    Code.ensure_loaded?(module) and function_exported?(module, :prompt_progress?, 0) and module.prompt_progress?()
  end

  @doc """
  The `user-agent` every adapter sends on every HTTP request, `"Mythweaver/<app version>"`.

  Pass it as Req's `user_agent:` option (or set the header directly for a non-Req client), so a
  provider sees the app rather than the HTTP library. A provider's `extra_headers` `"user-agent"`
  entry may override it.
  """
  @spec user_agent() :: String.t()
  def user_agent, do: @user_agent
end
