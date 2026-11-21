defmodule Mythweaver.Memory.Request do
  @moduledoc """
  Renders a memory prompt into a completion `input` for `Mythweaver.AI.stream_link/4`, and sizes it.
  """

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI.Model
  alias Mythweaver.AI.Request
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Memory.Profile
  alias Mythweaver.Prompts.Builder
  alias Mythweaver.Prompts.ContextLimit
  alias Mythweaver.Prompts.Prompt
  alias Mythweaver.Sharing.Protected
  alias Mythweaver.Tokenizer

  @memory_schema %{
    "type" => "object",
    "properties" => %{
      "title" => %{"type" => "string"},
      "content" => %{"type" => "string"},
      "keywords" => %{"type" => "array", "items" => %{"type" => "string"}}
    },
    "required" => ["title", "content", "keywords"],
    "additionalProperties" => false
  }

  @consolidation_schema %{
    "type" => "object",
    "properties" => %{
      "summaries" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "title" => %{"type" => "string"},
            "summary" => %{"type" => "string"},
            "keywords" => %{"type" => "array", "items" => %{"type" => "string"}},
            "member_ids" => %{"type" => "array", "items" => %{"type" => "string"}}
          },
          "required" => ["title", "summary", "keywords", "member_ids"],
          "additionalProperties" => false
        }
      },
      "unassigned_items" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "properties" => %{"id" => %{"type" => "string"}, "reason" => %{"type" => "string"}},
          "required" => ["id", "reason"],
          "additionalProperties" => false
        }
      }
    },
    "required" => ["summaries", "unassigned_items"],
    "additionalProperties" => false
  }

  @doc """
  `prompt` rendered for `chat` with `memory_map` as `anchors.memory`. Template writes are discarded.
  The profile's temperature and max tokens override the model's sampler (a `max_tokens` of 0 sends
  none, so the model's own limit applies); that response limit (the profile's, or the model's when
  the profile says 0) is cut to what the model's context window leaves after the prompt. The
  prompt's `thinking` goes along, capped by the model's level in `Mythweaver.AI`. With
  `profile.structured_output`, a JSON kind also asks for its `response_format` schema. `:protected`
  holds the build's scrub pairs (`Mythweaver.Sharing.Protected.pairs/1`), which
  `Mythweaver.Jobs.Runner` takes off before sending.

  `opts`: `:macros`, a map of string names to values, set as top-level Liquid variables in every
  block (a side prompt's runtime macros: `{{ npc_name }}`); a template's own `{% assign %}` wins.
  `:context`, extra `Builder.context/3` options (a chatless request passes `messages: []`,
  `variables:` and `character: nil`). `:max_tokens`, a response limit in place of the profile's
  (a compaction's, sized from its entry), still cut to the context window.
  """
  @spec input(Scope.t(), Chat.t(), Prompt.t(), Model.t(), Profile.t(), map(), keyword()) :: map()
  def input(
        %Scope{} = scope,
        %Chat{} = chat,
        %Prompt{} = prompt,
        %Model{} = model,
        %Profile{} = profile,
        memory_map,
        opts \\ []
      ) do
    macros = Keyword.get(opts, :macros, %{})

    context =
      scope
      |> Builder.context(chat, Keyword.merge([memory: memory_map, model: model], Keyword.get(opts, :context, [])))
      |> update_in([Access.key!(:templates)], &%{&1 | assigns: Map.merge(&1.assigns, macros)})

    built = Builder.build(prompt, context)

    input = Builder.render_segments(built.segments, model, context)

    limit =
      Keyword.get_lazy(opts, :max_tokens, fn ->
        response_limit(profile.max_tokens) || (model.sampler && model.sampler.max_tokens)
      end)

    input
    |> Map.put(:sampler, %{temperature: profile.temperature, max_tokens: fit(limit, model, input)})
    |> Map.put(:thinking, prompt.thinking)
    |> Map.put(:protected, Protected.pairs(built.protected_values))
    |> put_schema(profile.structured_output, memory_map["kind"])
  end

  # 0 is "use the model's own limit": nil, which `AI` skips when merging over the model's sampler.
  defp response_limit(0), do: nil
  defp response_limit(max_tokens), do: max_tokens

  # A response limit the model's context window cannot hold after the prompt is cut to what is left
  # (`ContextLimit.room/2`), so a hosted endpoint does not reject the request. No window, no limit, or
  # a prompt that already fills the window: sent as it is (the provider's error then says why).
  defp fit(nil, _model, _input), do: nil

  defp fit(limit, %Model{context_window: window} = model, input) when is_integer(window) do
    room = ContextLimit.room(window, tokens(model, input))
    if room > 0 and limit > room, do: room, else: limit
  end

  defp fit(limit, _model, _input), do: limit

  defp put_schema(input, true, kind) when kind in ["memory", "consolidation"] do
    schema = if kind == "memory", do: @memory_schema, else: @consolidation_schema

    Map.put(input, :extra_body, %{
      "response_format" => %{
        "type" => "json_schema",
        "json_schema" => %{"name" => kind, "strict" => true, "schema" => schema}
      }
    })
  end

  defp put_schema(input, _structured?, _kind), do: input

  @doc "`input` with `text` appended as a final user turn (chat mode) or paragraph (text mode)."
  @spec append_user(map(), String.t()) :: map()
  def append_user(%{messages: messages} = input, text),
    do: %{input | messages: messages ++ [%Request.Message{role: :user, content: text}]}

  def append_user(%{prompt: prompt} = input, text), do: %{input | prompt: prompt <> "\n\n" <> text}

  @doc "Tokens in `input`'s message contents or prompt, counted with `model`'s tokenizer."
  @spec tokens(Model.t() | nil, map()) :: non_neg_integer()
  def tokens(model, %{messages: messages}),
    do: Enum.reduce(messages, 0, fn message, sum -> sum + count(model, message.content) end)

  def tokens(model, %{prompt: prompt}), do: count(model, prompt)

  defp count(model, text), do: model |> Tokenizer.count(text) |> elem(0)
end
