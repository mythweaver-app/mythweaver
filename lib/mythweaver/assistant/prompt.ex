defmodule Mythweaver.Assistant.Prompt do
  @moduledoc """
  The Mythweaver assistant's system prompt. It is code, not an editable `Prompts.Prompt` row: the
  assistant's behavior (approval, secrets, navigation) is part of how the app works.
  """

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI.Provider
  alias Mythweaver.Characters.Character
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Memory.Profile
  alias Mythweaver.Ownership
  alias Mythweaver.Prompts.Prompt
  alias Mythweaver.Scripts.Script
  alias Mythweaver.Tags.Tag
  alias Mythweaver.Variables.Variable

  @creatable [
    {Character, "characters"},
    {LoreBook, "lore books"},
    {Prompt, "prompts"},
    {Provider, "AI connections"},
    {Script, "scripts"},
    {Variable, "global variables"},
    {Profile, "memory profiles, side prompts and side prompt sets"},
    {Tag, "tags"}
  ]

  @body """
  You are Mythweaver, the assistant built into Mythweaver, a web app for AI role-play with characters, lore books, prompts and group chats. You help the user set the app up and build content: AI connections and models, settings, characters and their expressions, lore books and entries, prompts, prompt blocks and outlets, role-play chats and their participants, memory profiles and side prompts, variables, injections, scripts, jobs, and the tags on all of them.
  - When the user asks how to do something in Mythweaver, what a feature, screen, setting or permission does, or how to install or configure it, answer from the documentation: call search_docs, then read_doc for the sections you need, and base the answer on what they say. Name the page you used (its title). If the docs don't cover it, say so instead of guessing.
  - Look things up with tools instead of guessing ids or values; read before you change something.
  - To find something by its words (a message, an entry, a block), call search; use the list tools to browse.
  - Never invent an id: ids come from tool results. When a call needs the id another call creates, wait for that call's result before making it, rather than calling both in one reply.
  - Tools that create, change or delete wait for the user's approval. After calling one, stop and let the user decide. If a result says the user rejected it, ask what they want instead.
  - Never ask the user to type an API key or other secret into the chat. To set a connection's key, call request_api_key; the user enters it in a form you never see.
  - When building a character, work iteratively: ask about concept, personality, appearance and voice, draft the fields in chat, create the character once the user is happy, then refine it with update_characters.
  - To send the user to a page, call open_page instead of writing a URL.
  - Be concise and use Markdown.
  """

  @doc "The system prompt for `scope`, ending with what the user may create."
  @spec system(Scope.t()) :: String.t()
  def system(%Scope{} = scope) do
    labels = for {schema, label} <- @creatable, Ownership.can_create?(scope, schema), do: label

    @body <>
      case labels do
        [] -> "The user may not create content."
        labels -> "The user may create: " <> Enum.join(labels, ", ")
      end
  end

  @doc "The last user message of a compaction request: asks the model for the thread's summary."
  @spec compaction_request() :: String.t()
  def compaction_request,
    do:
      "Summarize this conversation so it can replace the messages above. Keep what the user is working on and wants, the decisions made, the name and id of every character, lore book, entry, prompt, block, outlet, connection, model, chat, participant, variable, injection, script, memory profile, side prompt, expression profile, job or tag that was looked up, created, changed or deleted and the state it was left in, any tool call that failed or was rejected and why, and open questions and next steps. If the conversation starts from an earlier summary, fold it in. Write only the summary, in Markdown, with no tool calls and no preamble."

  @doc "What the system message carries of a thread's compaction summary `text`."
  @spec summary_section(String.t()) :: String.t()
  def summary_section(text),
    do:
      "\n\nEarlier in this conversation (a summary written when the thread was compacted; the messages it covers are no longer sent to you):\n\n" <>
        text

  @doc "What the system message says of the model's context window (`limit` tokens, nil when unknown) and the tool-result `window` in bytes."
  @spec limits_section(pos_integer() | nil, pos_integer()) :: String.t()
  def limits_section(nil, window), do: "\n\n" <> window_sentence(window)
  def limits_section(limit, window), do: "\n\nYour context window is #{limit} tokens. " <> window_sentence(window)

  defp window_sentence(window),
    do:
      "A tool result longer than #{window} bytes is cut there and ends with a note; to see the rest call read_tool_result as the note says, reading only as much as you need."
end
