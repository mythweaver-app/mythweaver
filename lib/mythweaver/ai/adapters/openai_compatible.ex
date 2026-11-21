defmodule Mythweaver.AI.Adapters.OpenAICompatible do
  @moduledoc """
  Adapter for any endpoint speaking the OpenAI HTTP shape: llama.cpp/llama-swap, vLLM, TabbyAPI,
  Ollama, OpenRouter, OpenAI itself.

  `complete/2` and `stream/3` are separate wire paths on purpose: the non-streaming request keeps
  returning one whole JSON body (which `Completion.raw` holds verbatim), while `stream/3` posts
  `stream: true` and folds Server-Sent Events. Retries are off on both: a completion is expensive and
  non-idempotent in cost terms, so `Req`'s default retry would silently double-bill.
  """

  @behaviour Mythweaver.AI.Provider.Adapter

  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI.Completion
  alias Mythweaver.AI.DiscoveredModel
  alias Mythweaver.AI.Embedding
  alias Mythweaver.AI.EmbeddingRequest
  alias Mythweaver.AI.Provider.Adapter
  alias Mythweaver.AI.Provider.SamplerDialect
  alias Mythweaver.AI.ReasoningParser
  alias Mythweaver.AI.Request
  alias Mythweaver.AI.SamplerParams
  alias Mythweaver.AI.SSE
  alias Mythweaver.AI.StopScanner
  alias Mythweaver.AI.StreamEvent
  alias Mythweaver.Net.Guard

  @impl true
  def label, do: dpgettext("ai", "option: API type of an AI connection", "OpenAI-compatible")

  # Only llama.cpp and TabbyAPI answer `return_progress`; the rest of this adapter's backends send none.
  @impl true
  def prompt_progress?, do: true

  @impl true
  def discover_models(provider) do
    client = client(provider)

    case Req.get(client, url: "/models") do
      {:ok, %{status: 200, body: %{"data" => data}}} when is_list(data) ->
        data = Enum.uniq_by(data ++ embedding_entries(client), & &1["id"])
        {:ok, Enum.map(data, &%DiscoveredModel{id: &1["id"], name: &1["name"], attrs: model_attrs(&1)})}

      other ->
        {:error, error_reason(other)}
    end
  end

  # OpenRouter's plain `/models` omits embedding models; this query lists them. Any failure is ignored
  # so discovery depends only on the plain request, and a backend that ignores the query string just
  # repeats its list, which the caller's dedup absorbs.
  defp embedding_entries(client) do
    case Req.get(client, url: "/models", params: [output_modalities: "embeddings"]) do
      {:ok, %{status: 200, body: %{"data" => data}}} when is_list(data) -> data
      _other -> []
    end
  end

  # A string-keyed map of `Mythweaver.AI.Model` field names holding only what this entry actually
  # advertised. An unadvertised capability is *omitted* rather than written as `false`, so
  # `Model.changeset/2`'s schema defaults apply and the UI can render asserted facts only.
  #
  # Every value here is a bounded integer, decimal, or boolean by construction. No provider free text
  # is extracted, notably not `description`, which `notes` would otherwise hold: `notes` is a
  # user-authored field, and holding an arbitrary-length remote string per advertised model (446 of
  # them from OpenRouter) in LiveView assigns is memory a hostile `/models` reply could balloon at will.
  defp model_attrs(entry) do
    %{}
    |> put_present("completion_mode", embedding_mode(entry))
    |> put_present("context_window", context_window(entry))
    |> put_present("prompt_cost_per_mtok", cost_per_mtok(entry, "prompt"))
    |> put_present("completion_cost_per_mtok", cost_per_mtok(entry, "completion"))
    |> put_present("supports_images", images?(entry))
    |> put_present("supports_files", files?(entry))
    |> put_present("supports_audio", audio?(entry))
    |> put_present("supports_video", video?(entry))
    |> put_present("supports_tools", tools?(entry))
    |> put_present("supports_thinking", thinking?(entry))
  end

  defp put_present(attrs, _key, nil), do: attrs
  defp put_present(attrs, key, value), do: Map.put(attrs, key, value)

  defp embedding_mode(entry) do
    if "embeddings" in list(nested(entry, "architecture", "output_modalities")), do: "embedding"
  end

  # First positive integer wins. OpenRouter and llama-swap use `context_length`; llama-swap also
  # duplicates it as `context_window` and `meta.n_ctx`; `meta.n_ctx` is llama.cpp's and TabbyAPI's
  # *loaded* context; vLLM has flat `max_model_len`. `meta.n_ctx_train` is last because the training
  # context can exceed what the server actually allocated.
  defp context_window(entry) do
    pos_int(entry["context_length"]) ||
      pos_int(entry["context_window"]) ||
      pos_int(nested(entry, "meta", "n_ctx")) ||
      pos_int(nested(entry, "parameters", "max_seq_len")) ||
      pos_int(entry["max_model_len"]) ||
      pos_int(nested(entry, "meta", "n_ctx_train"))
  end

  # `> 0`, not merely `is_integer`: vLLM's `max_model_len` is nullable and llama.cpp reports
  # `n_ctx_train: 0` when unknown, and `ai_models` has positive-value check constraints: a `0` would
  # raise `Postgrex.Error` instead of surfacing as a changeset error. Strings and floats are rejected
  # too: a backend that stringifies a limit is not asserting a number this app can trust.
  defp pos_int(value) when is_integer(value) and value > 0, do: value
  defp pos_int(_value), do: nil

  # OpenRouter prices in USD per *single* token as a decimal string, hence `× 1_000_000`.
  # `normalize/1` is required: without it the product of `"0.00001"` is `Decimal.new("10.00000")`,
  # whose `to_string` is `"1E+1"`. `Decimal.negative?/1` drops OpenRouter's `"-1"` "priced at
  # runtime" sentinel while keeping `"0"`, which is a real free tier.
  defp cost_per_mtok(entry, key) do
    with %{} = pricing <- entry["pricing"],
         raw when is_binary(raw) <- pricing[key],
         {decimal, ""} <- Decimal.parse(raw),
         false <- Decimal.negative?(decimal) do
      decimal |> Decimal.mult(1_000_000) |> Decimal.normalize()
    else
      _other -> nil
    end
  end

  # Capability predicates return `nil`, never `false`: an entry that says nothing must not overwrite
  # the schema default, and an explicit negative claim lands on the same stored value anyway.
  defp images?(entry) do
    cond do
      "image" in list(nested(entry, "architecture", "input_modalities")) -> true
      nested(entry, "capabilities", "vision") == true -> true
      nested(entry, "parameters", "use_vision") == true -> true
      true -> nil
    end
  end

  defp files?(entry) do
    if "file" in list(nested(entry, "architecture", "input_modalities")), do: true
  end

  defp audio?(entry) do
    if "audio" in list(nested(entry, "architecture", "input_modalities")), do: true
  end

  defp video?(entry) do
    if "video" in list(nested(entry, "architecture", "input_modalities")), do: true
  end

  defp tools?(entry) do
    cond do
      "tools" in list(entry["supported_parameters"]) -> true
      nested(entry, "capabilities", "function_calling") == true -> true
      true -> nil
    end
  end

  # Union of both OpenRouter signals: some entries carry the `reasoning` object without the
  # `reasoning` parameter and some the reverse.
  defp thinking?(entry) do
    params = list(entry["supported_parameters"])

    cond do
      is_map(entry["reasoning"]) -> true
      "reasoning" in params -> true
      "include_reasoning" in params -> true
      true -> nil
    end
  end

  # Never `get_in/2` on this payload: it raises `UndefinedFunctionError` the moment a backend puts a
  # string where this app expects a map, so every nested read pattern-matches the intermediate.
  defp nested(entry, outer, inner) do
    case entry[outer] do
      %{} = map -> map[inner]
      _other -> nil
    end
  end

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []

  @impl true
  def complete(provider, %Request{} = request) do
    with {:ok, path, input} <- wire_input(request) do
      post(provider, path, Map.merge(base_body(request), input), request)
    end
  end

  @impl true
  def embed(provider, %EmbeddingRequest{} = request) do
    body = Map.merge(request.extra_body, %{"model" => request.model_id, "input" => request.input})

    provider
    |> client()
    |> Req.post(url: "/embeddings", json: body)
    |> case do
      {:ok, %{status: 200, body: %{"data" => data} = response}} when is_list(data) ->
        with {:ok, vectors} <- embedding_vectors(data, length(request.input)),
             do: {:ok, %Embedding{vectors: vectors, usage: response["usage"] || %{}}}

      other ->
        {:error, error_reason(other)}
    end
  end

  defp embedding_vectors(data, count) do
    vectors =
      data
      |> Enum.sort_by(&((is_map(&1) && is_integer(&1["index"]) && &1["index"]) || 0))
      |> Enum.map(&(is_map(&1) && &1["embedding"]))

    valid? =
      length(vectors) == count and
        Enum.all?(vectors, &(is_list(&1) and &1 != [] and Enum.all?(&1, fn x -> is_number(x) end))) and
        vectors |> Enum.map(&length/1) |> Enum.uniq() |> length() == 1

    if valid?,
      do: {:ok, Enum.map(vectors, fn vector -> Enum.map(vector, &(&1 * 1.0)) end)},
      else: {:error, {:invalid_response, :embeddings}}
  end

  defp post(provider, path, body, request) do
    provider
    |> client(request.session_id)
    |> Req.post(url: path, json: body)
    |> case do
      {:ok, %{status: 200, body: %{"choices" => [%{} = choice | _rest]} = response}} ->
        {:ok, normalize(response, choice, request)}

      other ->
        {:error, error_reason(other)}
    end
  end

  @impl true
  def stream(provider, %Request{} = request, on_event) when is_function(on_event, 1) do
    with {:ok, path, input} <- wire_input(request) do
      body = Map.merge(stream_body(provider, request), input)
      stream_request(provider, path, body, request, on_event)
    end
  end

  # The mode decides the path and the one body key that carries the input; a chat request offering
  # tools also carries `"tools"`.
  defp wire_input(%Request{mode: :chat, messages: [_ | _] = messages} = request) do
    input = %{"messages" => Enum.map(messages, &wire_message/1)}
    input = if request.tools == [], do: input, else: Map.put(input, "tools", request.tools)
    {:ok, "/chat/completions", input}
  end

  defp wire_input(%Request{mode: :text, prompt: prompt}) when is_binary(prompt),
    do: {:ok, "/completions", %{"prompt" => prompt}}

  defp wire_input(%Request{mode: :chat}), do: {:error, {:invalid_request, :missing_messages}}
  defp wire_input(%Request{mode: :text}), do: {:error, {:invalid_request, :missing_prompt}}
  defp wire_input(%Request{mode: :embedding}), do: {:error, {:invalid_request, :embedding_model}}

  # The streaming keys are merged *after* the merged `extra_body` (the reverse of `base_body/1`'s
  # ordering) on purpose: an `extra_body` of `%{"stream" => false}` would return one JSON body into an SSE decoder
  # and hang the fold until the receive timeout. `include_usage` is mandatory: without
  # it the chat endpoint emits no usage frame at all and token counts would be permanently nil.
  # `return_progress` (llama.cpp, TabbyAPI) is opt-in per connection because OpenAI rejects unknown
  # body keys with a 400.
  defp stream_body(provider, request) do
    request
    |> base_body()
    |> Map.merge(%{"stream" => true, "stream_options" => %{"include_usage" => true}})
    |> then(&if(provider.prompt_progress == true, do: Map.put(&1, "return_progress", true), else: &1))
  end

  # The request event is the exact body sent; headers are left out because they carry the key.
  defp stream_request(provider, path, body, request, on_event) do
    on_event.(%StreamEvent.Request{url: String.trim_trailing(provider.base_url, "/") <> path, body: body})

    provider
    |> client(request.session_id)
    |> Req.post(url: path, json: body, into: collector(request, on_event))
    |> case do
      {:ok, %{status: 200} = resp} ->
        acc = Req.Response.get_private(resp, :ai_acc, new_acc(request))
        acc = finish_content(acc, on_event)
        on_event.(%StreamEvent.Done{finish_reason: acc.finish_reason})
        {:ok, completion(acc)}

      {:ok, %{status: status} = resp} ->
        body = resp |> Req.Response.get_private(:ai_error_body, []) |> Enum.reverse() |> IO.iodata_to_binary()
        {:error, {:http_error, status, body}}

      other ->
        {:error, error_reason(other)}
    end
  end

  # Flush what the parser held back (a partial tag, an unterminated think block), then the tail the
  # stop scanner held. A stopped reply has nothing more to flush.
  defp finish_content(%{stopped?: true} = acc, _on_event), do: acc

  defp finish_content(acc, on_event) do
    acc = apply_pieces(acc, ReasoningParser.finish(acc.parser), on_event)

    case acc do
      %{stopped?: true} ->
        acc

      _running ->
        held = StopScanner.finish(acc.scanner)
        emit(on_event, StreamEvent.Delta, held)
        %{acc | text: prepend(acc.text, held)}
    end
  end

  # `into: fun` gets no "response started" callback, so decoder and accumulator are initialized
  # lazily on the first chunk. `resp.private` is the only channel for threading state through the
  # fold. `{:halt, …}` only once a stop string ended the reply: halting mid-generation discards the
  # trailing usage frame, which then nothing can recover, so the counts are estimated downstream.
  defp collector(request, on_event) do
    fn {:data, chunk}, {req, resp} ->
      resp = consume(resp, chunk, request, on_event)

      case Req.Response.get_private(resp, :ai_acc) do
        %{stopped?: true} -> {:halt, {req, resp}}
        _running -> {:cont, {req, resp}}
      end
    end
  end

  # A non-200 body arrives as data chunks too, so it is buffered raw and never decoded: feeding a
  # JSON error object to the SSE decoder yields zero events and looks like an empty generation.
  defp consume(%{status: status} = resp, chunk, _request, _on_event) when status != 200 do
    Req.Response.put_private(resp, :ai_error_body, [chunk | Req.Response.get_private(resp, :ai_error_body, [])])
  end

  defp consume(resp, chunk, request, on_event) do
    {payloads, decoder} = SSE.decode(Req.Response.get_private(resp, :ai_sse, SSE.new()), chunk)

    acc =
      Enum.reduce(payloads, Req.Response.get_private(resp, :ai_acc, new_acc(request)), fn payload, acc ->
        apply_payload(payload, acc, request.mode, on_event)
      end)

    resp
    |> Req.Response.put_private(:ai_sse, decoder)
    |> Req.Response.put_private(:ai_acc, acc)
  end

  # `[DONE]` is the stream sentinel, not JSON, so `Jason.decode/1` would fail on it. A payload that
  # does not parse, or parses to anything but an object, is dropped rather than aborting: a truncated
  # final frame from a killed connection must not turn a good generation into a crash.
  defp apply_payload("[DONE]", acc, _mode, _on_event), do: acc
  # Frames after a stop string (the rest of its chunk) are past the end of the reply.
  defp apply_payload(_payload, %{stopped?: true} = acc, _mode, _on_event), do: acc

  defp apply_payload(payload, acc, mode, on_event) do
    case Jason.decode(payload) do
      {:ok, %{} = frame} -> apply_frame(frame, acc, mode, on_event)
      _invalid -> acc
    end
  end

  defp apply_frame(frame, acc, mode, on_event) do
    case prompt_progress(frame) do
      nil -> :ok
      event -> on_event.(event)
    end

    {content, reasoning, finish_reason} = frame_delta(frame, mode)

    emit(on_event, StreamEvent.Reasoning, reasoning)
    acc = %{acc | reasoning: prepend(acc.reasoning, reasoning)}

    acc =
      if is_binary(content) and content != "" do
        {pieces, parser} = ReasoningParser.feed(acc.parser, content)
        apply_pieces(%{acc | parser: parser}, pieces, on_event)
      else
        acc
      end

    %{
      acc
      | finish_reason: if(acc.stopped?, do: "stop", else: finish_reason || acc.finish_reason),
        model: frame["model"] || acc.model,
        usage: frame["usage"] || acc.usage,
        tool_calls: fold_tool_calls(acc.tool_calls, frame_tool_calls(frame, mode))
    }
  end

  # A call streams as fragments keyed by `index`: the first carries `id` and `function.name`, the
  # rest pieces of `function.arguments`. A fragment without an index takes its list position.
  defp fold_tool_calls(calls, fragments) do
    fragments
    |> Enum.with_index()
    |> Enum.reduce(calls, fn
      {%{} = fragment, position}, calls ->
        index = if is_integer(fragment["index"]), do: fragment["index"], else: position
        function = if is_map(fragment["function"]), do: fragment["function"], else: %{}
        call = Map.get(calls, index, %{id: nil, name: nil, arguments: []})

        call = %{
          call
          | id: call.id || fragment["id"],
            name: if(call.name in [nil, ""], do: function["name"], else: call.name),
            arguments: prepend(call.arguments, function["arguments"])
        }

        Map.put(calls, index, call)

      _other, calls ->
        calls
    end)
  end

  defp frame_tool_calls(%{"choices" => [%{"delta" => %{"tool_calls" => [_ | _] = calls}} | _rest]}, :chat), do: calls
  defp frame_tool_calls(_frame, _mode), do: []

  # llama.cpp's shape: a top-level `prompt_progress` on a chat chunk whose delta is
  # `{"role":"assistant","content":null}`, one per prompt batch. Cache hits are excluded so the
  # fraction is the real one; a fully cached prompt has nothing to report.
  defp prompt_progress(%{"prompt_progress" => %{"total" => total, "processed" => processed} = progress})
       when is_integer(total) and is_integer(processed) do
    cache = if is_integer(progress["cache"]), do: progress["cache"], else: 0
    uncached = total - cache

    if uncached >= 1,
      do: %StreamEvent.PromptProgress{done: min(max(processed - cache, 0), uncached), total: uncached}
  end

  defp prompt_progress(_frame), do: nil

  # Parsed content pieces, emitted and accumulated in stream order. Content goes through the stop
  # scanner, which may hold a tail back or end the reply; reasoning is never cut.
  defp apply_pieces(acc, pieces, on_event) do
    Enum.reduce(pieces, acc, fn
      _piece, %{stopped?: true} = acc ->
        acc

      {:reasoning, piece}, acc ->
        emit(on_event, StreamEvent.Reasoning, piece)
        %{acc | reasoning: prepend(acc.reasoning, piece)}

      {:delta, piece}, acc ->
        case StopScanner.feed(acc.scanner, piece) do
          {:cont, text, scanner} ->
            emit(on_event, StreamEvent.Delta, text)
            %{acc | text: prepend(acc.text, text), scanner: scanner}

          {:stop, text} ->
            emit(on_event, StreamEvent.Delta, text)
            %{acc | text: prepend(acc.text, text), stopped?: true, finish_reason: "stop"}
        end
    end)
  end

  # Usage is read from *every* frame, not only from empty-`choices` ones: chat mode sends it in a
  # separate trailing frame while text mode rides it on the final content frame.
  # A non-object `choices` entry or `delta` yields no text rather than a raise.
  defp frame_delta(%{"choices" => [%{} = choice | _rest]}, :chat) do
    case choice["delta"] do
      %{} = delta -> {delta["content"], delta["reasoning_content"], choice["finish_reason"]}
      _other -> {nil, nil, choice["finish_reason"]}
    end
  end

  defp frame_delta(%{"choices" => [%{} = choice | _rest]}, :text), do: {choice["text"], nil, choice["finish_reason"]}

  # The chat usage frame carries `"choices" => []`; indexing it would crash or read nil.
  defp frame_delta(_frame, _mode), do: {nil, nil, nil}

  # `nil` and `""` both occur in real frames (the role-announcement delta, the final empty delta,
  # text mode's empty final `text`), and pushing them would force every consumer to filter.
  defp emit(on_event, module, text) when is_binary(text) and text != "", do: on_event.(struct!(module, text: text))

  defp emit(_on_event, _module, _text), do: :ok

  # Reverse iodata: one reversal at the end instead of a binary copy per token.
  defp prepend(acc, text) when is_binary(text) and text != "", do: [text | acc]
  defp prepend(acc, _text), do: acc

  defp new_acc(%Request{} = request) do
    %{
      text: [],
      reasoning: [],
      finish_reason: nil,
      model: nil,
      usage: nil,
      parser: ReasoningParser.new(request.reasoning_tags),
      scanner: StopScanner.new(request.stop),
      stopped?: false,
      tool_calls: %{}
    }
  end

  defp completion(acc) do
    put_usage(
      %Completion{
        text: acc.text |> Enum.reverse() |> IO.iodata_to_binary(),
        reasoning: joined_or_nil(acc.reasoning),
        finish_reason: acc.finish_reason,
        model: acc.model,
        # The aggregate usage frame is the only whole-response JSON a stream produces; there is no
        # single body to keep.
        raw: acc.usage,
        tool_calls:
          for {index, call} <- Enum.sort_by(acc.tool_calls, &elem(&1, 0)) do
            %{
              id: call.id || "call_#{index}",
              name: call.name || "",
              arguments: call.arguments |> Enum.reverse() |> IO.iodata_to_binary()
            }
          end
      },
      acc.usage
    )
  end

  defp put_usage(%Completion{} = completion, usage) do
    usage = usage || %{}

    %{
      completion
      | prompt_tokens: usage["prompt_tokens"],
        completion_tokens: usage["completion_tokens"],
        total_tokens: usage["total_tokens"],
        cost: to_decimal(usage["cost"])
    }
  end

  # `nil` rather than `""` when the model emitted no reasoning, matching `complete/2`.
  defp joined_or_nil([]), do: nil
  defp joined_or_nil(reasoning), do: reasoning |> Enum.reverse() |> IO.iodata_to_binary()

  # `:ai_req_options` is the documented `Req.Test` seam: `config/test.exs` sets
  # `plug: {Req.Test, Mythweaver.AI}`, dev and prod set nothing. The app, not Req, owns the
  # user-agent (see Adapter's HTTP contract).
  defp client(provider, session_id \\ nil) do
    [
      base_url: provider.base_url,
      receive_timeout: provider.request_timeout_ms,
      headers: headers(provider, session_id),
      user_agent: Adapter.user_agent(),
      retry: false
    ]
    |> Keyword.merge(Application.get_env(:mythweaver, :ai_req_options, []))
    |> Req.new()
    |> Guard.attach(private: private_policy(provider), max_body: 32 * 1024 * 1024, max_stream: 64 * 1024 * 1024)
  end

  # Site connections, and personal ones owned by an AI admin, may point at a local server. The
  # owner is only looked up when the host does resolve to a private address.
  defp private_policy(%{user_id: nil}), do: :allow

  defp private_policy(%{user_id: user_id}) do
    fn ->
      scope = user_id |> Accounts.get_user() |> Scope.for_user()
      if Scope.can?(scope, "site.ai.manage"), do: :allow, else: :deny
    end
  end

  # `extra_headers` is merged last so a provider needing `x-api-key` or `api-key` (Anthropic, Azure)
  # can override the bearer scheme (or `x-session-id`) without a new adapter. Names are downcased
  # first: Req downcases header names and appends on collision, so a typed `"Authorization"` would
  # otherwise go out twice.
  defp headers(provider, session_id) do
    base = %{"content-type" => "application/json"}
    extra = Map.new(provider.extra_headers || %{}, fn {k, v} -> {String.downcase(k, :ascii), v} end)

    base
    |> put_authorization(provider.api_key)
    |> put_session(session_id)
    |> Map.merge(extra)
  end

  defp put_authorization(headers, key) when is_binary(key) and key != "",
    do: Map.put(headers, "authorization", "Bearer " <> key)

  defp put_authorization(headers, _key), do: headers

  defp put_session(headers, id) when is_binary(id) and id != "", do: Map.put(headers, "x-session-id", id)
  defp put_session(headers, _id), do: headers

  # Precedence: typed fields (named by the sampler dialect) < `extra` < `extra_body`. The dialect's
  # `adjust_body/2` sees the merged result last, so it can rewrite keys any layer set.
  defp base_body(%Request{} = request) do
    dialect = SamplerDialect.module_for(request.sampler_dialect)

    %{"model" => request.model_id, "stream" => false}
    |> Map.merge(sampler_body(dialect, request.sampler))
    |> Map.merge(request.extra_body)
    |> dialect.adjust_body(request.mode)
  end

  defp sampler_body(dialect, %SamplerParams{} = sampler), do: Map.merge(dialect.body(sampler), sampler.extra || %{})

  defp sampler_body(_dialect, _nil), do: %{}

  defp wire_message(%Request.Message{role: :assistant, tool_calls: [_ | _] = calls, content: content}) do
    %{
      "role" => "assistant",
      "content" => content || "",
      "tool_calls" =>
        for(
          c <- calls,
          do: %{"id" => c.id, "type" => "function", "function" => %{"name" => c.name, "arguments" => c.arguments}}
        )
    }
  end

  defp wire_message(%Request.Message{role: :tool, tool_call_id: id, content: content}),
    do: %{"role" => "tool", "tool_call_id" => id, "content" => content}

  defp wire_message(%Request.Message{role: role, content: parts}) when is_list(parts),
    do: %{"role" => to_string(role), "content" => Enum.map(parts, &wire_part/1)}

  defp wire_message(%Request.Message{role: role, content: content}),
    do: %{"role" => to_string(role), "content" => content}

  # Always a data URI, never a remote URL: a local llama.cpp server cannot be assumed to fetch one.
  defp wire_part(%Request.Text{text: text}), do: %{"type" => "text", "text" => text}

  defp wire_part(%Request.Image{media_type: media_type, data: data, detail: detail}) do
    url = %{"url" => "data:#{media_type};base64," <> Base.encode64(data)}
    url = if detail, do: Map.put(url, "detail", to_string(detail)), else: url
    %{"type" => "image_url", "image_url" => url}
  end

  # OpenAI's and OpenRouter's `file` part: the PDF as a data URL with its filename.
  defp wire_part(%Request.File{media_type: media_type, filename: filename, data: data}) do
    file = %{"filename" => filename, "file_data" => "data:#{media_type};base64," <> Base.encode64(data)}
    %{"type" => "file", "file" => file}
  end

  defp wire_part(%Request.Audio{format: format, data: data}),
    do: %{"type" => "input_audio", "input_audio" => %{"data" => Base.encode64(data), "format" => format}}

  # OpenRouter's `video_url` part, which llama.cpp's server also takes: the clip as a data URL.
  defp wire_part(%Request.Video{media_type: media_type, data: data}),
    do: %{"type" => "video_url", "video_url" => %{"url" => "data:#{media_type};base64," <> Base.encode64(data)}}

  defp normalize(response, choice, %Request{} = request) do
    {parsed, text} = ReasoningParser.split(choice_text(choice, request.mode) || "", request.reasoning_tags)
    {text, stopped?} = StopScanner.cut(text, request.stop)

    reasoning =
      [message(choice)["reasoning_content"], parsed]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> case do
        [] -> nil
        parts -> Enum.join(parts, "\n\n")
      end

    put_usage(
      %Completion{
        text: text,
        reasoning: reasoning,
        finish_reason: if(stopped?, do: "stop", else: choice["finish_reason"]),
        model: response["model"],
        raw: response
      },
      response["usage"]
    )
  end

  defp choice_text(choice, :chat), do: message(choice)["content"]
  defp choice_text(choice, :text), do: choice["text"]

  defp message(%{"message" => %{} = message}), do: message
  defp message(_choice), do: %{}

  defp to_decimal(nil), do: nil
  defp to_decimal(%Decimal{} = value), do: value
  defp to_decimal(value), do: Decimal.new(to_string(value))

  defp error_reason({:ok, %{status: 200, body: body}}), do: {:unexpected_body, body}
  defp error_reason({:ok, %{status: status, body: body}}), do: {:http_error, status, body}
  defp error_reason({:error, exception}), do: {:transport_error, Exception.message(exception)}
end
