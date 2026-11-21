import Ecto.Query

alias Mythweaver.AI.Model
alias Mythweaver.Prompts
alias Mythweaver.Prompts.Block
alias Mythweaver.Prompts.Prompt
alias Mythweaver.Prompts.PromptBlock
alias Mythweaver.Repo

Code.require_file("scope.exs", __DIR__)
seed_scope = Mythweaver.Seeds.scope()

# Seed the built-in caption prompts (`purpose: :caption`), assigned on a vision model's edit page
# ("Caption prompt"). The image itself is appended to the last user turn by
# `Mythweaver.Attachments.Workers.Caption`.
#
#   * "Caption: Instructions only", for small captioners (JoyCaption and the like) that do best with
#     a short instruction and nothing else. The same text as the built-in fallback.
#   * "Caption: With scene context", for capable multimodal models with a large context: the chat so
#     far, so the description can use names and the scene.
#
# Runnable on its own (`mix run priv/repo/seeds/captions.exs`) and required by `priv/repo/seeds.exs`.
# Idempotent: prompts and blocks are upserted by name.

upsert_block = fn name, attrs ->
  attrs = Map.merge(%{name: name, kind: :template}, attrs)

  {:ok, block} =
    case Repo.get_by(Block, name: name) do
      nil -> Prompts.create_block(seed_scope, attrs, site: true)
      block -> Prompts.update_block(seed_scope, block, attrs)
    end

  block
end

upsert_prompt = fn name, description, blocks ->
  attrs = %{name: name, purpose: :caption, description: description}

  {:ok, prompt} =
    case Repo.get_by(Prompt, name: name) do
      nil -> Prompts.create_prompt(seed_scope, attrs, site: true)
      prompt -> Prompts.update_prompt(seed_scope, prompt, attrs)
    end

  Repo.delete_all(from(pb in PromptBlock, where: pb.prompt_id == ^prompt.id))
  Enum.each(blocks, fn block -> {:ok, _} = Prompts.add_block(seed_scope, prompt, block) end)
  prompt
end

instruction =
  upsert_block.("Caption: Instruction", %{
    role: :user,
    content: Model.default_caption_prompt(),
    description: "The bare captioning instruction; the image follows it."
  })

upsert_prompt.("Caption: Instructions only", "For small captioning models: the instruction alone.", [instruction])

scene_system =
  upsert_block.("Caption: Scene system", %{
    role: :system,
    content: ~S"""
    You describe images shared in a role-play chat for participants who cannot see them. The chat so
    far is given for context. Describe what the image actually shows, objectively; use a character's
    name only when the image clearly shows that character. Do not continue the story or speak as anyone.
    """,
    description: "Sets the captioner up as a describer for a chat, not a participant."
  })

history =
  upsert_block.("Caption: Chat history", %{
    kind: :chat_history,
    role: :user,
    content: nil,
    description: "The chat so far, for context."
  })

scene_instruction =
  upsert_block.("Caption: Scene instruction", %{
    role: :user,
    content: ~S"""
    Describe the attached image in one short paragraph, for someone in this chat who cannot see it:
    the people, their appearance, clothing and expressions, the setting, and any visible text.
    """,
    description: "The instruction after the history; the image follows it."
  })

upsert_prompt.(
  "Caption: With scene context",
  "For capable multimodal models: the chat history, then the instruction.",
  [scene_system, history, scene_instruction]
)
