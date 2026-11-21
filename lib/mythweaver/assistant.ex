defmodule Mythweaver.Assistant do
  @moduledoc """
  "Chat with Mythweaver": a generic assistant chat (`Chat.kind == :assistant`, no participants)
  that browses and edits app data through tool calls (`Mythweaver.Assistant.Tools`).

  A turn is run by `Mythweaver.Assistant.Runner`. Read tools run at once; a write tool waits on an
  Approve/Reject card (`decide/4`), and `request_api_key` on a password form (`submit_api_key/4`)
  whose key goes straight to the connection, never through the model or the thread. The loop
  resumes once no call of the reply is open. `compact/2` runs a one-round summary instead, which
  later rounds read in place of the messages before it.

  The model is the thread's `ai_model_id`, else the `assistant.model` setting, else
  `AI.default_model/1` (`model/2`); it must be a chat-mode model. A tool-capable one
  (`supports_tools`) gets native `tools`, others the `Mythweaver.Assistant.TextProtocol` fallback.

  Every function is scope-first and authorizes with `Chats.authorize/3` (`:manage`: an assistant
  thread has no members, so only its owner); a role-play chat is
  `{:error, :not_assistant}`. Broadcasts on `Messages.topic/1`: `{:tool_calls_changed, message_id}`
  and `{:assistant_state, chat_id, running?}`.
  """

  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Query, warn: false

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.AI.Model
  alias Mythweaver.Assistant.Context
  alias Mythweaver.Assistant.Runner
  alias Mythweaver.Assistant.Tool
  alias Mythweaver.Assistant.ToolCall
  alias Mythweaver.Assistant.Tools
  alias Mythweaver.Attachments.Attachment
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message
  alias Mythweaver.Ownership
  alias Mythweaver.Permissions.Quota
  alias Mythweaver.Repo
  alias Mythweaver.Settings

  @open [:pending, :awaiting_input, :running]
  @character_tools ~w[create_characters update_characters]

  @doc """
  The model the assistant runs for `scope` in a thread naming `ai_model_id` (nil: none): that model,
  else the `assistant.model` setting, else `AI.default_model/1`. A rung naming a model the scope may
  not run counts as unset.
  """
  @spec model(Scope.t(), Ecto.UUID.t() | nil) :: {:ok, Model.t()} | {:error, :no_model | :ambiguous_model | :text_model}
  def model(%Scope{} = scope, ai_model_id) do
    chosen =
      Enum.find_value([fn -> ai_model_id end, fn -> Settings.get(scope, "assistant.model") end], fn rung ->
        case rung.() do
          id when is_binary(id) and id != "" -> AI.get_model(scope, id)
          _ -> nil
        end
      end)

    result = if chosen, do: {:ok, chosen}, else: AI.default_model(scope)

    case result do
      {:ok, %Model{completion_mode: :chat}} = ok -> ok
      {:ok, %Model{}} -> {:error, :text_model}
      error -> error
    end
  end

  @doc "A new, empty assistant thread for `scope`'s user, with `attrs` (`name`, `ai_model_id`)."
  @spec create_chat(Scope.t(), map()) :: {:ok, Chat.t()} | {:error, :quota_exceeded | Ecto.Changeset.t()}
  def create_chat(%Scope{} = scope, attrs \\ %{}), do: Chats.create_assistant_chat(scope, attrs)

  @doc "The chat-mode models `scope` may run, as `{name, id}` select options: what a thread may name."
  @spec model_options(Scope.t()) :: [{String.t(), Ecto.UUID.t()}]
  def model_options(%Scope{} = scope),
    do: for(%Model{completion_mode: :chat} = m <- AI.list_models(scope), do: {m.name, m.id})

  @doc "The settings form's changeset over an assistant thread's `name` and `ai_model_id`."
  @spec change_chat(Chat.t(), map()) :: Ecto.Changeset.t()
  def change_chat(%Chat{kind: :assistant} = chat, attrs \\ %{}), do: Chat.assistant_changeset(chat, attrs)

  @doc "Saves an assistant thread's name and model (a chat-mode model the owner may use, or blank for the default)."
  @spec update_chat(Scope.t(), Chat.t(), map()) ::
          {:ok, Chat.t()} | {:error, Ecto.Changeset.t() | :unauthorized | :not_assistant}
  def update_chat(%Scope{} = scope, %Chat{} = chat, attrs) do
    with :ok <- check(scope, chat), do: Chats.update_chat(scope, chat, attrs)
  end

  @doc """
  Posts the user's message, with `attachments` (staged `:ready` attachments; with any the text may
  be blank), and starts a turn. Open tool calls are closed first: a pending or key call is
  rejected, a running one failed. A thread with no name takes the message's first line.
  """
  @spec send_message(Scope.t(), Chat.t(), String.t(), [Attachment.t()]) ::
          {:ok, Message.t()}
          | {:error,
             :empty
             | :unauthorized
             | :not_assistant
             | :busy
             | :no_model
             | :ambiguous_model
             | :text_model
             | :quota_exceeded}
  def send_message(%Scope{} = scope, %Chat{} = chat, content, attachments \\ []) when is_binary(content) do
    with :ok <- check(scope, chat),
         :ok <- if(running?(scope, chat), do: {:error, :busy}, else: :ok),
         :ok <- if(String.trim(content) == "" and attachments == [], do: {:error, :empty}, else: :ok),
         {:ok, model} <- model(scope, chat.ai_model_id),
         :ok <- Quota.check_spend(scope, model, AI.run_owner(scope, chat)) do
      reject_open_calls(chat)

      with {:ok, message} <- Messages.post_assistant_user_message(scope, chat, content, attachments) do
        chat = maybe_name(scope, chat, String.trim(content))

        case Runner.start(scope, chat, model) do
          :ok -> {:ok, message}
          error -> error
        end
      end
    end
  end

  defp maybe_name(scope, %Chat{name: nil} = chat, text) when text != "" do
    name = text |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 60)

    case Chats.update_chat(scope, chat, %{name: name}) do
      {:ok, chat} -> chat
      _ -> chat
    end
  end

  defp maybe_name(_scope, chat, _text), do: chat

  @doc """
  Compacts the thread: the model summarises what it currently reads into a summary message, and later
  rounds send that summary in place of the messages before it. Open tool calls are closed first, as for
  `send_message/4`.
  """
  @spec compact(Scope.t(), Chat.t()) ::
          :ok
          | {:error,
             :unauthorized
             | :not_assistant
             | :busy
             | :nothing_to_compact
             | :no_model
             | :ambiguous_model
             | :text_model
             | :quota_exceeded}
  def compact(%Scope{} = scope, %Chat{} = chat) do
    with :ok <- check(scope, chat),
         :ok <- if(running?(scope, chat), do: {:error, :busy}, else: :ok),
         :ok <- if(match?({_, []}, Context.thread(chat)), do: {:error, :nothing_to_compact}, else: :ok),
         {:ok, model} <- model(scope, chat.ai_model_id),
         :ok <- Quota.check_spend(scope, model, AI.run_owner(scope, chat)) do
      reject_open_calls(chat)
      Runner.start(scope, chat, model, :compact)
    end
  end

  defp reject_open_calls(chat) do
    {_, pending} =
      Repo.update_all(
        from(t in ToolCall,
          where: t.chat_id == ^chat.id and t.status in [:pending, :awaiting_input],
          select: t.message_id
        ),
        set: [
          status: :rejected,
          result: %{"error" => "The user sent a new message instead of acting on this."},
          updated_at: DateTime.utc_now()
        ]
      )

    {_, running} =
      Repo.update_all(
        from(t in ToolCall, where: t.chat_id == ^chat.id and t.status == :running, select: t.message_id),
        set: [
          status: :failed,
          error:
            dpgettext(
              "jobs",
              "status: error text of an assistant tool call cut off by the user's next message",
              "Interrupted."
            ),
          updated_at: DateTime.utc_now()
        ]
      )

    for message_id <- Enum.uniq(pending ++ running), do: broadcast_tool_calls(chat.id, message_id)
    :ok
  end

  @doc """
  Approves (runs) or rejects a pending write call, then resumes the turn when the reply has no
  open call left. The claim is atomic, so two tabs cannot both run a call.
  """
  @spec decide(Scope.t(), Chat.t(), Ecto.UUID.t(), :approve | :reject) ::
          {:ok, :resumed | :waiting} | {:error, atom()}
  def decide(%Scope{} = scope, %Chat{} = chat, call_id, decision) when decision in [:approve, :reject] do
    with :ok <- check(scope, chat),
         {:ok, call} <- claim(chat, call_id, :pending) do
      {status, result} =
        case decision do
          :approve -> run_call(scope, call)
          :reject -> {:rejected, %{"error" => "The user rejected this."}}
        end

      finish(call, status, result)
      broadcast_tool_calls(chat.id, call.message_id)
      maybe_resume(scope, chat, call.message_id)
    end
  end

  defp run_call(scope, call) do
    case Tools.fetch(call.name) do
      {:ok, tool} ->
        case Tools.run(scope, tool, call.arguments) do
          {:ok, result} -> {:succeeded, result}
          {:error, result} -> {:failed, result}
        end

      :error ->
        {:failed, %{"error" => "Unknown tool"}}
    end
  end

  @doc """
  Saves the key a `request_api_key` card collected onto its connection. The key is written only to
  `providers.api_key`; the call's result says only that it was saved. A refused key leaves the card
  open.
  """
  @spec submit_api_key(Scope.t(), Chat.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, :resumed | :waiting} | {:error, atom() | Ecto.Changeset.t()}
  def submit_api_key(%Scope{} = scope, %Chat{} = chat, call_id, api_key) when is_binary(api_key) do
    with :ok <- check(scope, chat),
         {:ok, call} <- fetch_call(chat, call_id),
         :ok <-
           if(call.status == :awaiting_input and call.name == "request_api_key", do: :ok, else: {:error, :not_pending}),
         key when key != "" <- String.trim(api_key),
         {:ok, connection_id} <- Ecto.UUID.cast(call.arguments["connection_id"] || ""),
         %AI.Provider{} = provider <- AI.get_provider(scope, connection_id) || {:error, :not_found},
         {:ok, call} <- claim(chat, call.id, :awaiting_input),
         {:ok, _provider} <- save_key(scope, provider, key, call) do
      finish(call, :succeeded, %{"api_key_saved" => true, "connection_id" => provider.id})
      broadcast_tool_calls(chat.id, call.message_id)
      maybe_resume(scope, chat, call.message_id)
    else
      "" -> {:error, :empty}
      :error -> {:error, :not_found}
      error -> error
    end
  end

  # A refused save puts the call back so the card stays open.
  defp save_key(scope, provider, key, call) do
    case AI.update_provider(scope, provider, %{api_key: key}) do
      {:ok, _} = ok ->
        ok

      error ->
        call |> Ecto.Changeset.change(status: :awaiting_input) |> Repo.update!()
        error
    end
  end

  @doc "The key card's Cancel: rejects the `request_api_key` call, then resumes like `decide/4`."
  @spec dismiss_input(Scope.t(), Chat.t(), Ecto.UUID.t()) :: {:ok, :resumed | :waiting} | {:error, atom()}
  def dismiss_input(%Scope{} = scope, %Chat{} = chat, call_id) do
    with :ok <- check(scope, chat),
         {:ok, call} <- claim(chat, call_id, :awaiting_input) do
      finish(call, :rejected, %{"error" => "The user dismissed this."})
      broadcast_tool_calls(chat.id, call.message_id)
      maybe_resume(scope, chat, call.message_id)
    end
  end

  @doc "Stops the chat's running turn; its streamed reply ends \"Stopped.\"."
  @spec stop(Scope.t(), Chat.t()) :: :ok | {:error, :not_running | :unauthorized | :not_assistant}
  def stop(%Scope{} = scope, %Chat{} = chat) do
    with :ok <- check(scope, chat) do
      case runner(chat.id) do
        nil ->
          {:error, :not_running}

        pid ->
          try do
            GenServer.stop(pid, {:shutdown, :stopped})
          catch
            :exit, _ -> :ok
          end
      end
    end
  end

  @doc "Whether a turn is running in the chat."
  @spec running?(Scope.t(), Chat.t()) :: boolean()
  def running?(%Scope{} = scope, %Chat{} = chat), do: check(scope, chat) == :ok and runner(chat.id) != nil

  # The live runner. A runner that just exited can linger in the registry until the registry
  # processes its exit, so a dead pid counts as none.
  defp runner(chat_id) do
    case Registry.lookup(Mythweaver.Generation.Registry, {:assistant, chat_id}) do
      [{pid, _}] -> if Process.alive?(pid), do: pid
      [] -> nil
    end
  end

  @doc false
  @spec list_tool_calls(Ecto.UUID.t()) :: %{optional(Ecto.UUID.t()) => [ToolCall.t()]}
  def list_tool_calls(chat_id) do
    from(t in ToolCall, where: t.chat_id == ^chat_id, order_by: [asc: t.message_id, asc: t.position])
    |> Repo.all()
    |> Enum.group_by(& &1.message_id)
  end

  @doc "The tool call id in one of scope's own assistant threads, or nil."
  @spec get_tool_call(Scope.t(), Ecto.UUID.t()) :: ToolCall.t() | nil
  def get_tool_call(%Scope{} = scope, id) do
    Repo.one(
      from(t in ToolCall,
        join: c in Chat,
        on: c.id == t.chat_id,
        where: t.id == ^id and c.user_id == ^scope.user.id and c.kind == :assistant
      )
    )
  end

  @doc """
  What the thread's tool cards show: the calls by message, the characters named by succeeded
  character tools (avatar preloaded) by id, and the `Tool` `preview` lines of each pending call
  whose tool has one, by call id.
  """
  @spec tool_cards(Scope.t(), Chat.t()) :: %{
          calls: map(),
          characters: %{optional(Ecto.UUID.t()) => Character.t()},
          previews: %{optional(Ecto.UUID.t()) => [String.t()]}
        }
  def tool_cards(%Scope{} = scope, %Chat{} = chat) do
    if check(scope, chat) == :ok do
      calls = list_tool_calls(chat.id)

      ids =
        for {_message_id, list} <- calls,
            call <- list,
            id <- character_ids(call),
            {:ok, id} <- [Ecto.UUID.cast(id)],
            uniq: true,
            do: id

      characters =
        if ids == [] do
          %{}
        else
          from(c in Character, where: c.id in ^ids, preload: :avatar)
          |> Ownership.usable(scope)
          |> Repo.all()
          |> Map.new(&{&1.id, &1})
        end

      previews =
        for {_message_id, list} <- calls,
            %ToolCall{status: :pending} = call <- list,
            {:ok, %Tool{preview: preview}} when is_function(preview, 2) <- [Tools.fetch(call.name)],
            into: %{},
            do: {call.id, preview.(scope, call.arguments || %{})}

      %{calls: calls, characters: characters, previews: previews}
    else
      %{calls: %{}, characters: %{}, previews: %{}}
    end
  end

  @doc "The ids of the characters a succeeded `get_character`, `create_characters` or `update_characters` call returned, in order."
  @spec character_ids(ToolCall.t()) :: [term()]
  def character_ids(%ToolCall{status: :succeeded, name: "get_character", result: %{"id" => id}}), do: [id]

  def character_ids(%ToolCall{status: :succeeded, name: name, result: %{"done" => done}})
      when name in @character_tools and is_list(done), do: for(%{"id" => id} <- done, do: id)

  def character_ids(%ToolCall{}), do: []

  @doc false
  def broadcast_tool_calls(chat_id, message_id),
    do: Phoenix.PubSub.broadcast(Mythweaver.PubSub, Messages.topic(chat_id), {:tool_calls_changed, message_id})

  @doc false
  def broadcast_state(chat_id, running?),
    do: Phoenix.PubSub.broadcast(Mythweaver.PubSub, Messages.topic(chat_id), {:assistant_state, chat_id, running?})

  defp check(scope, %Chat{} = chat) do
    with :ok <- Chats.authorize(scope, chat, :manage) do
      if chat.kind == :assistant, do: :ok, else: {:error, :not_assistant}
    end
  end

  defp fetch_call(chat, call_id) do
    with {:ok, id} <- Ecto.UUID.cast(call_id),
         %ToolCall{} = call <- Repo.get_by(ToolCall, id: id, chat_id: chat.id) do
      {:ok, call}
    else
      _ -> {:error, :not_found}
    end
  end

  # Moves the call from `from` to `:running` in one statement; zero rows is someone else's claim.
  defp claim(chat, call_id, from) do
    with {:ok, call} <- fetch_call(chat, call_id) do
      case Repo.update_all(
             from(t in ToolCall, where: t.id == ^call.id and t.chat_id == ^chat.id and t.status == ^from),
             set: [status: :running, updated_at: DateTime.utc_now()]
           ) do
        {1, _} -> {:ok, %{call | status: :running}}
        {0, _} -> {:error, :not_pending}
      end
    end
  end

  defp finish(call, status, result) do
    call
    |> Ecto.Changeset.change(status: status, result: result)
    |> Repo.update!()
  end

  defp maybe_resume(scope, chat, message_id) do
    open? = Repo.exists?(from(t in ToolCall, where: t.message_id == ^message_id and t.status in ^@open))

    if open? do
      {:ok, :waiting}
    else
      chat = Chats.get_chat(chat.id) || chat

      with {:ok, model} <- model(scope, chat.ai_model_id),
           :ok <- Quota.check_spend(scope, model, AI.run_owner(scope, chat)),
           :ok <- Runner.start(scope, chat, model) do
        {:ok, :resumed}
      end
    end
  end
end
