defmodule Mythweaver.Assistant.ContextTest do
  use Mythweaver.DataCase

  alias Mythweaver.AI
  alias Mythweaver.Assistant
  alias Mythweaver.Assistant.Context
  alias Mythweaver.Messages
  alias Mythweaver.Tokenizer

  setup do
    scope = scope!()

    {:ok, provider} =
      AI.create_provider(scope, %{
        name: "Local-#{System.unique_integer([:positive])}",
        adapter: :openai_compatible,
        base_url: "http://localhost:8080/v1"
      })

    {:ok, model} =
      AI.create_model(scope, %{name: "Gemma-#{System.unique_integer([:positive])}", api_model_id: "gemma-4"})

    {:ok, _link} = AI.link_model(scope, provider, model)
    {:ok, chat} = Assistant.create_chat(scope)

    contents =
      for i <- 1..6 do
        content = "m#{i} " <> String.duplicate("lantern ", 400)
        {:ok, _} = Messages.post_assistant_user_message(scope, chat, content)
        content
      end

    %{scope: scope, model: model, chat: chat, contents: contents}
  end

  defp sent(input), do: for(%{role: :user, content: content} <- input.messages, do: binary_part(content, 0, 2))

  test "without a known limit every message goes out", %{scope: scope, model: model, chat: chat} do
    assert sent(Context.build(scope, chat, model, :text)) == ~w[m1 m2 m3 m4 m5 m6]
  end

  test "with a limit only the newest messages that fit go out, oldest dropped first",
       %{scope: scope, model: model, chat: chat, contents: contents} do
    # A limited build's system message names its limit; a huge one differs only in digits.
    [%{role: :system, content: system} | _] =
      Context.build(scope, chat, %{model | context_window: 1_000_000}, :text).messages

    fixed = elem(Tokenizer.count(model, system), 0)
    each = contents |> Enum.map(&elem(Tokenizer.count(model, &1), 0)) |> Enum.max()

    model = %{model | context_window: ceil((fixed + 3 * each) * 1.1) + 1152 + 20}
    assert sent(Context.build(scope, chat, model, :text)) == ~w[m4 m5 m6]
  end

  test "the newest message goes out even when nothing fits", %{scope: scope, model: model, chat: chat} do
    assert sent(Context.build(scope, chat, %{model | context_window: 10}, :text)) == ~w[m6]
  end
end
