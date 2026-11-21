defmodule Mythweaver.Memory.Auto do
  @moduledoc """
  Automatic memories: after each new message, `check/2` decides whether enough unprocessed messages
  have piled up past the boundary to summarize, keeping the newest `auto_buffer` out of the scene.
  The trigger, interval, buffer and token threshold are the chat's own, else the `memory.auto_*`
  settings of the chat's owner (`Mythweaver.Memory.auto_settings/2`).
  Then it runs any interval side prompt that is due (`Mythweaver.Memory.SidePrompts`), whether or
  not automatic memories are on. Synchronous and cheap: a few queries when nothing is due.
  """

  import Ecto.Query, warn: false

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Memory
  alias Mythweaver.Memory.ChatSettings
  alias Mythweaver.Memory.Scene
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message
  alias Mythweaver.Repo
  alias Mythweaver.Sharing.Visibility
  alias Mythweaver.Tokenizer

  require Logger

  @doc """
  `:off`, `:busy` (a memory job is pending), `:waiting`, or `:fired`. Needs `:post` on the chat,
  then runs as the chat's owner, whose memory (books, profile, settings and quota) it is, whoever
  posted: jobs it starts belong to the owner.
  """
  @spec check(Scope.t(), Ecto.UUID.t()) :: :off | :busy | :waiting | :fired
  def check(%Scope{} = scope, chat_id) do
    if Chats.authorize(scope, chat_id, :post) != :ok, do: raise(Mythweaver.UnauthorizedError)
    scope = owner_scope(scope, chat_id)

    settings = Repo.get_by(ChatSettings, chat_id: chat_id)

    result =
      case settings do
        %ChatSettings{auto_enabled: true} ->
          chat = Chats.get_chat!(scope, chat_id)
          if busy?(chat_id), do: :busy, else: maybe_fire(scope, chat, settings)

        _off ->
          :off
      end

    Memory.SidePrompts.check_intervals(scope, chat_id)
    Memory.Reminders.check(scope, chat_id, settings, result in [:busy, :fired] or busy?(chat_id))
    result
  end

  # The owner's own scope even when a member's reply carries them in (`Scope.initiator_id`).
  defp owner_scope(%Scope{user: %{id: uid}} = scope, chat_id) do
    case Chats.owner_id(chat_id) do
      owner when owner in [nil, uid] -> %{scope | initiator_id: nil}
      owner -> Visibility.owner_scope(owner)
    end
  end

  @doc """
  How far a chat has come toward its next automatic memory, for the chat header's meter: `done` of
  `total` messages (the interval) or tokens (the threshold) past the processed boundary, the buffer
  left out as `check/2` leaves it out. `nil` when automatic memories are off, or, counting tokens,
  when the chat has no memory profile or model to count with.
  """
  @spec progress(Scope.t(), Chat.t()) ::
          %{unit: :messages | :tokens, done: non_neg_integer(), total: pos_integer()} | nil
  def progress(%Scope{} = scope, %Chat{} = chat) do
    with :ok <- Chats.authorize(scope, chat, :inspect),
         %ChatSettings{auto_enabled: true} = settings <- Repo.get_by(ChatSettings, chat_id: chat.id) do
      meter(scope, chat, Memory.auto_settings(scope, settings), positions(chat.id, settings))
    else
      _off -> nil
    end
  end

  defp meter(_scope, _chat, %{auto_trigger: :messages} = auto, positions) do
    done = (length(positions) - auto.auto_buffer) |> max(0) |> min(auto.auto_interval)
    %{unit: :messages, done: done, total: auto.auto_interval}
  end

  defp meter(scope, chat, %{auto_trigger: :tokens} = auto, positions) do
    if tokens = scene_tokens(scope, chat, positions, auto.auto_buffer),
      do: %{unit: :tokens, done: min(tokens, auto.auto_token_threshold), total: auto.auto_token_threshold}
  end

  defp busy?(chat_id) do
    Repo.exists?(
      from(j in Job, where: j.chat_id == ^chat_id and j.tag == :memory and j.status in [:queued, :running, :review])
    )
  end

  defp maybe_fire(scope, chat, settings) do
    positions = positions(chat.id, settings)

    case last(scope, chat, Memory.auto_settings(scope, settings), positions) do
      nil -> :waiting
      last -> fire(scope, chat, hd(positions), last)
    end
  end

  # The unprocessed, non-draft messages' positions, oldest first.
  defp positions(chat_id, settings) do
    floor = settings.highest_processed || -1

    Repo.all(
      from(m in Message,
        where: m.chat_id == ^chat_id and m.draft == false and m.position > ^floor,
        order_by: [asc: m.position],
        select: m.position
      )
    )
  end

  defp last(_scope, _chat, %{auto_trigger: :messages} = settings, positions) do
    count = length(positions)
    if count >= settings.auto_interval + settings.auto_buffer, do: Enum.at(positions, count - settings.auto_buffer - 1)
  end

  defp last(scope, chat, %{auto_trigger: :tokens} = settings, positions) do
    tokens = scene_tokens(scope, chat, positions, settings.auto_buffer)
    if tokens && tokens >= settings.auto_token_threshold, do: Enum.at(positions, -settings.auto_buffer - 1)
  end

  # The scene past the boundary, `buffer` newest messages left out, counted with the memory model's
  # tokenizer (0 when only the buffer is left); nil without a memory profile or model.
  defp scene_tokens(scope, chat, positions, buffer) do
    with {:ok, profile} <- Memory.profile_for(scope, chat),
         {:ok, model} <- Memory.model_for(scope, chat, profile) do
      if length(positions) > buffer do
        text =
          scope
          |> Messages.list_messages_between(chat, hd(positions), Enum.at(positions, -buffer - 1))
          |> Scene.text()

        model |> Tokenizer.count(text) |> elem(0)
      else
        0
      end
    else
      _ -> nil
    end
  end

  defp fire(scope, chat, first, last) do
    review = Memory.preferences(scope).show_previews

    case Memory.create_memory(scope, chat, first, last, origin: :background, review: review) do
      {:ok, _job} ->
        :fired

      other ->
        Logger.warning("Automatic memory for chat #{chat.id} not started: #{inspect(other)}")
        :waiting
    end
  end
end
