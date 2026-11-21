defmodule Mythweaver.Expressions.Workers.Classify do
  @moduledoc """
  The `:expression` job: asks the classifier model (`expressions.classifier_model`) to rate one
  message body's emotions from 0 to 100, as `{"scores": {label: n}}`, then hands the scores to
  `Mythweaver.Expressions.apply_scores/3`. The instruction is the `expressions.classifier_prompt`
  template (Liquid, with `labels` and `char`), else the built-in one. With
  `expressions.structured_output` the request carries a JSON schema; `Mythweaver.Jobs.Runner` drops
  it for a backend that refuses it. An unparseable reply gets one repair retry.
  """

  @behaviour Mythweaver.Jobs.Worker

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.AI.Model
  alias Mythweaver.AI.Request
  alias Mythweaver.Characters.Character
  alias Mythweaver.Expressions
  alias Mythweaver.Jobs
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Memory
  alias Mythweaver.Messages.MessageBody
  alias Mythweaver.Repo
  alias Mythweaver.Settings
  alias Mythweaver.Templates
  alias Mythweaver.Templates.State

  @default_prompt """
  Rate how strongly the message below expresses each of these emotions, from 0 (absent) to 100 (dominant): {{ labels }}.
  Reply with only a JSON object of the form {% raw %}{"scores": {"<emotion>": <number>, ...}}{% endraw %} with every listed emotion as a key.
  """

  @max_tokens 1024

  @impl true
  def build(%Job{params: params} = job) do
    with %Scope{} = scope <- Jobs.run_scope(job) || {:error, :no_initiator},
         %MessageBody{} = body <- Repo.get(MessageBody, params["body_id"]) || {:error, :source_missing},
         %Character{} = character <- Repo.get(Character, params["character_id"]) || {:error, :source_missing},
         %Model{} = model <- (job.ai_model_id && AI.get_model(scope, job.ai_model_id)) || {:error, :no_model} do
      labels = Expressions.classifier_labels(character)
      instruction = instruction(scope, labels, character, body)
      content = body.content || ""

      input =
        case model.completion_mode do
          :text ->
            %{prompt: instruction <> "\n\nMessage:\n" <> content <> "\n\nJSON:\n"}

          _chat ->
            %{
              messages: [
                %Request.Message{role: :system, content: instruction},
                %Request.Message{role: :user, content: content}
              ]
            }
        end

      # A rating needs no reasoning; on a thinking model it would spend the token budget before the JSON.
      input = Map.merge(input, %{sampler: %{max_tokens: @max_tokens}, thinking: :none})
      {:ok, put_schema(input, scope, labels), nil}
    end
  end

  defp instruction(scope, labels, character, body) do
    data = %{"labels" => Enum.join(labels, ", "), "char" => character.name}

    with template when is_binary(template) <- Settings.get(scope, "expressions.classifier_prompt"),
         {:ok, text} <- render(template, data, body.id) do
      text
    else
      _ ->
        {:ok, text} = render(@default_prompt, data, body.id)
        text
    end
  end

  defp render(template, data, id) do
    case Templates.render(template, State.new(data, %{chat: %{}, global: %{}}, id)) do
      {text, _state, []} -> {:ok, String.trim(text)}
      {_source, _state, _errors} -> :error
    end
  end

  defp put_schema(input, scope, labels) do
    if Settings.get(scope, "expressions.structured_output") do
      schema = %{
        "type" => "object",
        "properties" => %{
          "scores" => %{
            "type" => "object",
            "properties" => Map.new(labels, &{&1, %{"type" => "number"}}),
            "required" => labels,
            "additionalProperties" => false
          }
        },
        "required" => ["scores"],
        "additionalProperties" => false
      }

      Map.put(input, :extra_body, %{
        "response_format" => %{
          "type" => "json_schema",
          "json_schema" => %{"name" => "expression_scores", "strict" => true, "schema" => schema}
        }
      })
    else
      input
    end
  end

  @impl true
  def finish(%Job{} = job, completion, retried?) do
    with %Scope{} = scope <- Jobs.run_scope(job) || {:error, :no_initiator},
         %Character{} = character <- Repo.get(Character, job.params["character_id"]) || {:error, :source_missing} do
      case scores(completion.text, Expressions.classifier_labels(character)) do
        {:ok, scores} ->
          {:ok, result} = Expressions.apply_scores(scope, job.params, scores)
          {:ok, :completed, result}

        :error ->
          Memory.Workers.repair(__MODULE__, job, retried?)
      end
    end
  end

  # Every classifier label, rounded and clamped to 0..100 (absent or non-numeric: 0). Keys match
  # case- and space-insensitively; a reply naming none of the labels is unparseable.
  defp scores(text, labels) do
    case Memory.JSON.decode(text) do
      {:ok, map} ->
        raw = if is_map(map["scores"]), do: map["scores"], else: map
        normalized = Map.new(raw, fn {k, v} -> {k |> to_string() |> String.trim() |> String.downcase(), v} end)

        if Enum.any?(labels, &Map.has_key?(normalized, &1)),
          do: {:ok, Map.new(labels, &{&1, clamp(normalized[&1])})},
          else: :error

      _ ->
        :error
    end
  end

  defp clamp(n) when is_number(n), do: n |> round() |> max(0) |> min(100)
  defp clamp(_value), do: 0
end
