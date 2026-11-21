defmodule Mythweaver.Expressions.Encoder do
  @moduledoc """
  Expression classification by a classifier model (`completion_mode: :classifier`): a GoEmotions
  sequence classifier, such as `cirimus/modernbert-large-go-emotions` served by llama-server with
  `--embedding --pooling rank`. One `Mythweaver.AI.classify/2` call returns a raw logit per label in
  GoEmotions' label order, which is `Mythweaver.Expressions.base_labels/0`; each becomes
  `round(100 * sigmoid(logit))` and goes to `Mythweaver.Expressions.apply_scores/3`. A character's
  custom labels score 0: the classifier only knows its 28.

  Like `Mythweaver.AI.embed/2`, the call is outside `Mythweaver.Jobs`: it takes milliseconds and
  must not wait behind a reply on the same connection. It runs under
  `Mythweaver.Expressions.TaskSupervisor`, or in the caller with
  `config :mythweaver, :expressions_in_background, false` (tests). Each call is a
  `generation_stats` row (`tag: :expression`, `Mythweaver.Analytics.record_call/1`) and passes
  `Mythweaver.Permissions.Quota.check_spend/3` first, as embeddings do.
  """

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.AI.Embedding
  alias Mythweaver.AI.Model
  alias Mythweaver.Analytics
  alias Mythweaver.Expressions
  alias Mythweaver.Expressions.TaskSupervisor
  alias Mythweaver.Messages.MessageBody
  alias Mythweaver.Permissions.Quota
  alias Mythweaver.Repo

  require Logger

  # The end of a long reply, where it lands emotionally; also well inside an 8k-token context.
  @max_chars 4_000

  @doc "Runs `classify/3` in the background (inline when background work is off). Always `:ok`."
  @spec classify_later(Scope.t(), Model.t(), map()) :: :ok
  def classify_later(%Scope{} = scope, %Model{} = model, params) do
    run = fn -> classify(scope, model, params) end

    if Application.get_env(:mythweaver, :expressions_in_background, true) do
      {:ok, _pid} = Task.Supervisor.start_child(TaskSupervisor, run)
    else
      run.()
    end

    :ok
  end

  @doc """
  Classifies the body named by `params` (`classify_later/5`'s job params) and stores the result
  (`Mythweaver.Expressions.apply_scores/3`). Errors are logged and returned.
  """
  @spec classify(Scope.t(), Model.t(), map()) :: {:ok, map()} | {:error, term()}
  def classify(%Scope{} = scope, %Model{} = model, params) do
    with %MessageBody{content: content} when is_binary(content) <-
           Repo.get(MessageBody, params["body_id"]) || {:error, :source_missing},
         :ok <- Quota.check_spend(scope, model, AI.run_owner(scope, params["chat_id"])),
         {:ok, logits} <- call(scope, model, params["chat_id"], tail(content)),
         {:ok, scores} <- scores(logits) do
      Expressions.apply_scores(scope, params, scores)
    else
      {:error, reason} = error ->
        Logger.warning("Expression classification with #{model.name} failed: #{inspect(reason)}")
        error
    end
  end

  defp tail(content) do
    if String.length(content) > @max_chars, do: String.slice(content, -@max_chars, @max_chars), else: content
  end

  defp call(scope, model, chat_id, text) do
    started_at = DateTime.utc_now()

    stat = %{
      tag: :expression,
      scope: scope,
      model: model,
      chat_id: chat_id,
      origin: :background,
      started_at: started_at
    }

    case AI.classify(model, AI.run_owner(scope, chat_id), [text]) do
      {:ok, %Embedding{vectors: [logits], usage: usage}, link} ->
        record(stat, %{status: :completed, link: link, usage: usage})
        {:ok, logits}

      {:error, :no_provider} = error ->
        error

      {:error, _reason} = error ->
        record(stat, %{status: :failed, link: nil, usage: %{}})
        error
    end
  end

  defp record(stat, outcome),
    do: stat |> Map.merge(outcome) |> Map.put(:finished_at, DateTime.utc_now()) |> Analytics.record_call()

  # Extra trailing values (a GGUF without `embedding_length_out`) are ignored; too few is a model
  # that is not a GoEmotions classifier.
  defp scores(logits) do
    labels = Expressions.base_labels()

    if length(logits) >= length(labels),
      do: {:ok, labels |> Enum.zip(logits) |> Map.new(fn {label, x} -> {label, percent(x)} end)},
      else: {:error, {:invalid_response, :classifier_outputs}}
  end

  # Clamped so :math.exp/1 cannot overflow on an extreme logit.
  defp percent(x), do: round(100 / (1 + :math.exp(-(x |> max(-50.0) |> min(50.0)))))
end
