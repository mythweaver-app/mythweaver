defmodule MythweaverWeb.Chat.Access do
  @moduledoc """
  What the viewer may do in the open role-play chat, resolved once from their `Chats.role/2` with
  `Chats.permits?/4` (the rules of `Chats.authorize/3`, without a query per check), so the chat
  components show only the controls the server would accept.

  `manage?` covers settings, participants, scratchpads, merge and reattribution; `inspect?` the
  prompt and swipe inspectors, variables, injections, jobs and memory; `report?` the scope's
  `"reports.create"`. Per-message edit, delete and report depend on the message (`message?/3`).
  """

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Messages.Message

  defstruct [
    :role,
    :scope,
    :chat,
    manage?: false,
    inspect?: false,
    post?: false,
    generate?: false,
    regenerate?: false,
    attach?: false,
    run_scripts?: false,
    report?: false
  ]

  @type t :: %__MODULE__{}

  @doc "The viewer's access to `chat` given their `role` (nil without one: nothing is allowed)."
  @spec new(Scope.t(), Chat.t(), :owner | :editor | :guest | nil) :: t()
  def new(%Scope{} = scope, %Chat{} = chat, role) do
    can? = &Chats.permits?(role, chat, scope, &1)

    %__MODULE__{
      role: role,
      scope: scope,
      chat: chat,
      manage?: can?.(:manage),
      inspect?: can?.(:inspect),
      post?: can?.(:post),
      generate?: can?.(:generate),
      regenerate?: can?.(:regenerate),
      attach?: can?.(:attach),
      run_scripts?: can?.(:run_scripts),
      report?: Scope.can?(scope, "reports.create")
    }
  end

  @doc """
  Whether the viewer may `:edit`, `:delete` or `:report` `message` (a guest edits and deletes their
  own, per the toggles; a member holding `"reports.create"` reports anything but their own, AI
  messages included).
  """
  @spec message?(t(), :edit | :delete | :report, Message.t()) :: boolean()
  def message?(%__MODULE__{role: role, scope: scope, report?: report?}, :report, %Message{} = message),
    do: report? and role != nil and message.author_user_id != scope.user.id

  def message?(%__MODULE__{role: role, chat: chat, scope: scope}, :edit, %Message{} = message),
    do: Chats.permits?(role, chat, scope, {:edit_message, message})

  def message?(%__MODULE__{role: role, chat: chat, scope: scope}, :delete, %Message{} = message),
    do: Chats.permits?(role, chat, scope, {:delete_message, message})
end
