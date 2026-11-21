defmodule Mythweaver.Prompts.Preview do
  @moduledoc """
  Renders a prompt, or one block, against a real chat without generating anything: the editors'
  "Preview" for debugging templates.

  It runs the same `Mythweaver.Prompts.Builder` path a generation does (descriptions, then lore, then
  blocks), with lore resolved `commit: false` and the template state discarded, so a preview never
  advances sticky/cooldown state or writes variables. The result is shaped and redacted exactly like a
  generation's `Mythweaver.Messages.PromptSnapshot`, so hidden lore never reaches a non-admin's page.
  """

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI.Model
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Messages.PromptSnapshot
  alias Mythweaver.Prompts.Block
  alias Mythweaver.Prompts.Builder
  alias Mythweaver.Prompts.Prompt
  alias Mythweaver.Prompts.PromptBlock

  @doc """
  `prompt` built for `chat`, replying as `character` (`nil` for the chat's default responder).

  Returns a redacted `PromptSnapshot` with `sections`, `lore`, `injections` and `template_errors`, and
  `request: %{"prompt" => text}`: the whole prompt as one flat string, exactly as a text-completion
  model would receive it (`Builder.render_segments/3`), ending on the responder's cue. Token counts are
  estimates, since no model is chosen. Raises `Mythweaver.UnauthorizedError` unless `scope` may act on
  `chat`.
  """
  @spec run(Scope.t(), Prompt.t(), Chat.t(), Character.t() | nil) :: PromptSnapshot.t()
  def run(%Scope{} = scope, %Prompt{} = prompt, %Chat{} = chat, character) do
    context =
      case character do
        %Character{} -> Builder.context(scope, chat, character: character)
        nil -> Builder.context(scope, chat)
      end

    built = Builder.build(prompt, context)
    %{prompt: text} = Builder.render_segments(built.segments, %Model{completion_mode: :text}, context)

    # `request` is where `redacted/2` scrubs the wire text, so the flat prompt goes there too.
    attrs =
      prompt
      |> PromptSnapshot.build_attrs(built, context.lore, nil)
      |> Map.put(:request, %{"prompt" => text})

    PromptSnapshot.redacted(scope, struct(PromptSnapshot, attrs))
  end

  @doc """
  A one-block prompt for previewing `block` on its own, enabled even when the block is not, so an
  unsaved or disabled block still renders.
  """
  @spec block_prompt(Scope.t(), Block.t()) :: Prompt.t()
  def block_prompt(%Scope{}, %Block{} = block) do
    %Prompt{prompt_blocks: [%PromptBlock{position: 0, enabled: true, block: %{block | enabled: true}}]}
  end
end
