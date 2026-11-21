defmodule Mythweaver.Moderation.Gate do
  @moduledoc """
  Where moderated writes meet their content-moderation mode (`Mythweaver.Moderation.Modes`).

  `run/5` wraps a context's insert or update: a restrictive-mode write of a holdable kind is held
  (`Mythweaver.Moderation.Holds.submit/2`) instead of saved; otherwise it saves, and a non-exempt
  mode scans the saved row in the background (`Mythweaver.Moderation.Scanner`). An update that
  changes no text field is never held or scanned, so toggles, samplers and orders pass straight
  through. `scan_result/3` and `scan_message/3` scan chats and player messages, which are never
  held; `import/3` decides whether a whole import is held.

  The process dictionary narrows this for the writes inside a block: `no_holds/1` scans but never
  holds (an import's own writes), `unmoderated/1` neither holds nor scans (a hold being applied, and
  system writers such as memory and captions).
  """

  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.Messages.Message
  alias Mythweaver.Moderation.Hold
  alias Mythweaver.Moderation.Holds
  alias Mythweaver.Moderation.Modes
  alias Mythweaver.Moderation.Scan
  alias Mythweaver.Moderation.Scanner
  alias Mythweaver.Moderation.Subject

  @key {__MODULE__, :mode}

  @doc "Runs `fun` with holds off: its moderated writes are scanned but never held."
  @spec no_holds((-> result)) :: result when result: term()
  def no_holds(fun), do: with_mode(if(mode() == :off, do: :off, else: :no_holds), fun)

  @doc "Runs `fun` with moderation off: its writes are neither held nor scanned."
  @spec unmoderated((-> result)) :: result when result: term()
  def unmoderated(fun), do: with_mode(:off, fun)

  defp with_mode(mode, fun) do
    previous = Process.get(@key)
    Process.put(@key, mode)

    try do
      fun.()
    after
      if previous, do: Process.put(@key, previous), else: Process.delete(@key)
    end
  end

  defp mode, do: Process.get(@key)

  @doc """
  Holds or saves the write `changeset` for `scope`. `op` is the `{module, function, args}` (without
  the scope) that repeats it when a hold is approved; `write_fun` saves it now. `opts[:followups]`
  are run after an approved hold saves (`Mythweaver.Moderation.Hold`).
  """
  @spec run(Scope.t() | nil, Ecto.Changeset.t(), mfa() | {module(), atom(), list()}, keyword(), (-> result)) ::
          result | {:held, Hold.t()} | {:error, :hold_limit}
        when result: term()
  def run(scope, %Ecto.Changeset{} = changeset, op, opts, write_fun) do
    kind = Subject.kind(changeset.data)

    if mode() == :off or not changeset.valid? or not text_changed?(changeset) do
      write_fun.()
    else
      mode = Modes.mode(scope, Subject.type(kind))

      if mode == :restrictive and Subject.holdable?(kind) and mode() != :no_holds do
        hold(scope, kind, changeset, op, opts)
      else
        result = write_fun.()

        with true <- mode != :exempt, {:ok, row} <- result do
          :ok = Scanner.scan_later(row_scan(scope, kind, row, action(changeset)))
        end

        result
      end
    end
  end

  defp action(changeset), do: if(changeset.data.__meta__.state == :loaded, do: :update, else: :create)

  defp text_changed?(%Ecto.Changeset{data: %{__meta__: %{state: :loaded}, __struct__: schema}} = changeset) do
    changed = changeset.changes |> Map.keys() |> MapSet.new()
    not MapSet.disjoint?(changed, MapSet.new(Subject.text_fields(schema)))
  end

  defp text_changed?(_changeset), do: true

  defp hold(scope, kind, changeset, op, opts) do
    proposed = Ecto.Changeset.apply_changes(changeset)
    action = action(changeset)

    previous =
      if action == :update,
        do:
          for(
            field <- Subject.text_fields(changeset.data.__struct__),
            Map.has_key?(changeset.changes, field),
            into: %{},
            do: {Atom.to_string(field), Subject.text(Map.get(changeset.data, field)) || ""}
          ),
        else: %{}

    Holds.submit(scope, %{
      kind: kind,
      action: action,
      target_id: if(action == :update, do: changeset.data.id),
      title: Subject.title(proposed),
      fields: Subject.fields(proposed),
      previous: previous,
      op: op,
      followups: Keyword.get(opts, :followups, [])
    })
  end

  @doc """
  Scans a saved chat (`{:ok, chat}`) when the chats mode is not exempt and, for an update, its text
  changed from `previous`. Returns `result`.
  """
  @spec scan_result(Scope.t() | nil, result, struct() | nil) :: result when result: term()
  def scan_result(scope, result, previous \\ nil) do
    with {:ok, row} <- result,
         true <- mode() in [nil, :no_holds],
         kind = Subject.kind(row),
         true <- Modes.mode(scope, Subject.type(kind)) != :exempt,
         true <- is_nil(previous) or Subject.fields(row) != Subject.fields(previous) do
      :ok = Scanner.scan_later(row_scan(scope, kind, row, if(previous, do: :update, else: :create)))
    end

    result
  end

  @doc "Scans the text `content` the scope's user wrote as `message`, under the chats mode."
  @spec scan_message(Scope.t() | nil, Message.t(), String.t() | nil) :: :ok
  def scan_message(%Scope{user: %User{id: uid}} = scope, %Message{} = message, content) do
    if mode() in [nil, :no_holds] and is_binary(content) and String.trim(content) != "" and
         Modes.mode(scope, :chats) != :exempt do
      fields = [{"content", content}]

      Scanner.scan_later(%Scan{
        type: :chats,
        subject_type: :message,
        subject_id: message.id,
        chat_id: message.chat_id,
        user_id: uid,
        title: dpgettext("moderation", "heading: title of a flagged chat message in the review list", "Message"),
        fields: fields,
        snapshot: content
      })
    else
      :ok
    end
  end

  def scan_message(_scope, _message, _content), do: :ok

  @doc "Scans an imported chat's whole parsed file under the chats mode (its messages skip `send_message`)."
  @spec scan_import_chat(Scope.t(), struct(), map()) :: :ok
  def scan_import_chat(%Scope{user: %User{id: uid}} = scope, chat, parsed) do
    if mode() in [nil, :no_holds] and Modes.mode(scope, :chats) != :exempt do
      fields = Subject.import_fields(parsed)

      Scanner.scan_later(%Scan{
        type: :chats,
        subject_type: :chat,
        subject_id: chat.id,
        chat_id: chat.id,
        user_id: uid,
        title: Subject.title(chat),
        action: :import,
        fields: fields,
        snapshot: Subject.join(fields)
      })
    else
      :ok
    end
  end

  def scan_import_chat(_scope, _chat, _parsed), do: :ok

  @doc """
  Whether an import of `parsed` is held: `{:held, hold}` when any content type it writes is
  restrictive for `scope`, else `:proceed`.
  """
  @spec import(Scope.t(), map(), keyword()) :: :proceed | {:held, Hold.t()} | {:error, :hold_limit}
  def import(scope, parsed, opts) do
    restrictive =
      if mode() not in [:off, :no_holds],
        do: parsed |> import_types(opts) |> Enum.find(&(Modes.mode(scope, &1) == :restrictive))

    if restrictive do
      Holds.submit(scope, %{
        kind: :import,
        type: restrictive,
        action: :import,
        target_id: nil,
        title: parsed[:name] || dpgettext("moderation", "heading: title of a held import that has no name", "Import"),
        fields: Subject.import_fields(parsed),
        op: {Mythweaver.Import, :import, [parsed, opts]},
        followups: []
      })
    else
      :proceed
    end
  end

  defp import_types(%{kind: :character}, _opts), do: [:characters, :lore]
  defp import_types(%{kind: :lore_book}, _opts), do: [:lore]
  defp import_types(%{kind: :preset}, _opts), do: [:prompts]

  defp import_types(%{kind: :chat}, opts) do
    if opts |> Keyword.get(:speakers, %{}) |> Map.values() |> Enum.member?(:create), do: [:characters], else: []
  end

  defp import_types(%{kind: :bundle}, _opts), do: [:characters, :lore, :ai, :prompts]
  defp import_types(_parsed, _opts), do: []

  defp row_scan(%Scope{user: %User{id: uid}}, kind, row, action) do
    fields = Subject.fields(row)

    %Scan{
      type: Subject.type(kind),
      subject_type: kind,
      subject_id: row.id,
      user_id: uid,
      title: Subject.title(row),
      action: action,
      fields: fields,
      snapshot: Subject.join(fields)
    }
  end
end
