defmodule Mythweaver.Prompts.ContextLimit do
  @moduledoc """
  How many tokens a chat reply's prompt may use, and which chat history fits in it.

  The limit is the smaller of the model's `context_window` and the `generation.max_context` setting;
  `reserve` is kept free for the reply (the model's response tokens, else 1024). `fit/4` keeps the
  newest chat-history entries that fit after the fixed parts of the prompt, SillyTavern-style, so the
  oldest turns are left out.

  Trimming moves the start of the history in `step`s (`generation.trim_step`): the first kept entry
  is always at a multiple of `step` from the start of the chat, so it stays put for about `step`
  replies instead of moving with every one. A provider's prompt cache reuses only an unchanged
  prompt prefix, and a history that starts one message later each reply changes it every time.
  """

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI.Model
  alias Mythweaver.Attachments
  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Settings
  alias Mythweaver.Tokenizer

  defstruct [:limit, :reserve, :model, step: 1]

  @type t :: %__MODULE__{
          limit: pos_integer(),
          reserve: non_neg_integer(),
          model: Model.t(),
          step: pos_integer()
        }

  @type report :: %{
          limit: pos_integer(),
          reserve: non_neg_integer(),
          used: non_neg_integer(),
          kept: non_neg_integer(),
          trimmed: non_neg_integer(),
          estimated?: boolean(),
          overflow?: boolean()
        }

  @type entry :: %{
          required(:content) => String.t(),
          required(:images) => [Attachment.t()],
          optional(:files) => [Attachment.t()]
        }

  @default_reserve 1024

  @doc """
  The limit for a reply by `model` under `scope`, or `nil` (no trimming) when neither the model's
  context window nor the `generation.max_context` setting is set.
  """
  @spec for_reply(Scope.t(), Model.t()) :: t() | nil
  def for_reply(%Scope{} = scope, %Model{} = model) do
    values = Settings.get_many(scope, ["generation.max_context", "generation.trim_step"])

    case Enum.filter([model.context_window, values["generation.max_context"]], &positive?/1) do
      [] ->
        nil

      candidates ->
        %__MODULE__{
          limit: Enum.min(candidates),
          reserve: (model.sampler && model.sampler.max_tokens) || @default_reserve,
          model: model,
          step: values["generation.trim_step"]
        }
    end
  end

  defp positive?(value), do: is_integer(value) and value > 0

  @doc """
  Tokens left in a `limit`-token context after a `prompt`-token prompt. The 10% + 128 margin covers an
  estimated token count and the chat template's own tokens.
  """
  @spec room(pos_integer(), non_neg_integer()) :: integer()
  def room(limit, prompt), do: limit - prompt - div(prompt, 10) - 128

  @doc "Whether a `tokens`-token prompt leaves the reply its reserve."
  @spec fits?(t(), non_neg_integer()) :: boolean()
  def fits?(%__MODULE__{} = cl, tokens), do: room(cl.limit, tokens) >= cl.reserve

  @doc """
  `{kept, report}`: how many of `entries` (chat history, oldest first) fit after `fixed_texts` and
  `fixed_attachments` (images and files every prompt sends, such as a guide's or the reply's own),
  kept as a contiguous newest suffix.
  An entry is everything the prompt sends of one history message, across all its chat-history
  segments.

  When some must go, the first kept entry is rounded up to a multiple of `step` (see the moduledoc),
  which leaves out up to `step - 1` more; the step shrinks to half of what fits, so rounding never
  drops more than half of it. `kept` is 0 and `overflow?` true when the fixed texts alone leave no
  reserve.
  """
  @spec fit(t(), [String.t()], [entry()], [Attachment.t()]) :: {non_neg_integer(), report()}
  def fit(%__MODULE__{} = cl, fixed_texts, entries, fixed_attachments \\ []) do
    fixed =
      Enum.reduce(fixed_texts, 0, &(&2 + count(cl.model, &1))) +
        Enum.reduce(fixed_attachments, 0, &(&2 + attachment_tokens(cl.model, &1)))

    total = length(entries)

    if fits?(cl, fixed) do
      # Oldest first: each fitting entry's `{cost, images?}`, walked newest-first.
      {fitting, _used} =
        entries
        |> Enum.reverse()
        |> Enum.reduce_while({[], fixed}, fn entry, {acc, used} ->
          cost = entry_tokens(cl.model, entry)

          if fits?(cl, used + cost),
            do: {:cont, {[{cost, entry.images != [] or Map.get(entry, :files, []) != []} | acc], used + cost}},
            else: {:halt, {acc, used}}
        end)

      kept = stepped(total, length(fitting), cl.step)
      kept_entries = Enum.take(fitting, -kept)
      used = Enum.reduce(kept_entries, fixed, fn {cost, _images?}, sum -> sum + cost end)
      images? = Enum.any?(kept_entries, &elem(&1, 1))

      {kept, report(cl, used, kept, total, images?, false)}
    else
      {0, report(cl, fixed, 0, total, false, true)}
    end
  end

  # How many of `total` entries to keep when the newest `most` fit.
  defp stepped(total, total, _step), do: total

  defp stepped(total, most, step) do
    step = step |> min(div(most, 2)) |> max(1)
    start = ceil_div(total - most, step) * step
    total - start
  end

  defp ceil_div(a, b), do: div(a + b - 1, b)

  defp report(cl, used, kept, total, images?, overflow?) do
    %{
      limit: cl.limit,
      reserve: cl.reserve,
      used: used,
      kept: kept,
      trimmed: total - kept,
      estimated?: not Tokenizer.exact?(cl.model) or images?,
      overflow?: overflow?
    }
  end

  # Natively sent images and files are estimates (`Attachments.image_tokens/2`, `file_tokens/2`).
  defp entry_tokens(model, entry) do
    count(model, entry.content) +
      Enum.reduce(entry.images ++ Map.get(entry, :files, []), 0, &(&2 + attachment_tokens(model, &1)))
  end

  defp attachment_tokens(model, %Attachment{kind: :image} = a), do: Attachments.image_tokens(a, model.image_detail)
  defp attachment_tokens(model, a), do: Attachments.file_tokens(a, model)
  defp count(model, text), do: model |> Tokenizer.count(text) |> elem(0)
end
