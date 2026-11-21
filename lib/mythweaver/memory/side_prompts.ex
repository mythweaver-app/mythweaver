defmodule Mythweaver.Memory.SidePrompts do
  @moduledoc """
  Side prompts: extra trackers (`Mythweaver.Memory.SidePrompt`) run over a range of messages, each
  maintaining its own lore entry.

  A run is a `:side_prompt` job (`Mythweaver.Memory.Workers.SidePrompt`). It starts on demand
  (`run/4`, `run_set/3`), after each saved memory over the memory's messages (`after_memory/5`), or
  once `interval` visible messages have piled up past the side prompt's checkpoint in the chat
  (`check_intervals/2`). `save_side_prompt/3` writes its output: the target entry is updated in
  place, or, with versioning on in both the preferences and the side prompt, a new numbered entry
  is created and the older versions are disabled.

  What runs automatically (`automatic/3`) is either the individually enabled side prompts or the
  rows of the chat's side prompt set (`Mythweaver.Memory.SidePromptSet`). A set row is its own
  tracker: its own entry (named by the row's label), checkpoint and records, all keyed by
  `side_prompt_set_row_id`, and its macro values as the side prompt's runtime macros. A side prompt
  whose declared macros are not all filled never runs (`missing_macros/2`).

  Every written record keeps a `snapshot` of what the entry was before (`"existed"`, `"prior"`),
  the `"range"` it covered and its `"template"` (the side prompt's id), for rollback.

  Only side prompts usable by the chat's owner run in a chat (`Ownership.for_owner/2`), and a new
  entry goes only to a book the job's scope may edit (falling back to the chat's memory book).
  """

  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Query, warn: false

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Jobs
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Lore
  alias Mythweaver.Lore.BookEntry
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Memory
  alias Mythweaver.Memory.ChatSettings
  alias Mythweaver.Memory.Profile
  alias Mythweaver.Memory.Record
  alias Mythweaver.Memory.Scene
  alias Mythweaver.Memory.SidePrompt
  alias Mythweaver.Memory.SidePromptCheckpoint
  alias Mythweaver.Memory.SidePromptSet
  alias Mythweaver.Memory.SidePromptSetRow
  alias Mythweaver.Messages.Message
  alias Mythweaver.Moderation.Gate
  alias Mythweaver.Ownership
  alias Mythweaver.Prompts.Prompt
  alias Mythweaver.Repo

  require Logger

  @doc """
  Queues one run of `side_prompt` in `chat`.

  `opts`:

    * `:start`/`:end`: positions; default the message after the chat's checkpoint (or the first)
      through the last message
    * `:trigger`: `:manual` (default, interactive), `:script` (a Lua script's `mw.memory`),
      `:after_memory` or `:interval` (all background)
    * `:parent_id`: the job that triggered this one
    * `:record_id`: regenerate that `:side_prompt` record over its snapshot range; only a record
      of `chat` in a book the scope may edit (else `{:error, :unauthorized}`)
    * `:review`: default `prefs.show_previews` for manual and script runs, false otherwise
    * `:message_ids`: read exactly these messages in the range, hidden or not
    * `:set_row`: run as that `SidePromptSetRow`, with its macro values, label and own checkpoint
      and entry
    * `:macros`: runtime macro values for a manual run (`%{name => value}`)

  Every macro the side prompt declares needs a non-blank value, else `{:error, :missing_macros}`.
  A regeneration reruns its record's set row, if any.

  An `:after_memory` run reads exactly the memory's messages (`:message_ids`), hidden or not, so
  auto-hide after the memory does not empty its scene; a regeneration reuses the ids in its
  record's snapshot.
  """
  @spec run(Scope.t(), Chat.t(), SidePrompt.t(), keyword()) ::
          {:ok, Job.t()}
          | {:error,
             :no_profile
             | :no_model
             | :ambiguous_model
             | :no_prompt
             | :empty_scene
             | :not_found
             | :changed
             | :missing_macros
             | :unauthorized}
  def run(%Scope{} = scope, %Chat{} = chat, %SidePrompt{} = side_prompt, opts \\ []) do
    with :ok <- Chats.authorize(scope, chat, :manage),
         true <- Ownership.reference_ok?(chat.user_id, side_prompt) || {:error, :unauthorized},
         do: do_run(Chats.run_scope(scope, chat), chat, side_prompt, opts)
  end

  defp do_run(scope, chat, side_prompt, opts) do
    prefs = Memory.preferences(scope)
    trigger = Keyword.get(opts, :trigger, :manual)

    with {:ok, record} <- target_for_regeneration(scope, chat, side_prompt, opts[:record_id]),
         row = opts[:set_row] || record_row(record),
         macros = if(row, do: row.macro_values, else: opts[:macros] || %{}),
         :ok <- macros_filled(side_prompt, macros),
         {:ok, profile} <- profile(scope, chat, side_prompt),
         {:ok, model} <- Memory.model_for(scope, chat, profile),
         {:ok, prompt} <- side_prompt_prompt(scope, side_prompt),
         {:ok, first, last} <- range(chat, side_prompt, row, record, opts),
         message_ids = opts[:message_ids] || (record && record.snapshot["message_ids"]),
         [_ | _] <-
           if(message_ids,
             do: Scene.listed(scope, chat, first, last, message_ids),
             else: Scene.messages(scope, chat, first, last, prefs)
           ) do
      params =
        Map.reject(
          %{
            "chat_id" => chat.id,
            "side_prompt_id" => side_prompt.id,
            "profile_id" => profile.id,
            "prompt_id" => prompt.id,
            "start" => first,
            "end" => last,
            "trigger" => Atom.to_string(trigger),
            "message_ids" => message_ids,
            "review" => Keyword.get(opts, :review, prefs.show_previews and trigger in [:manual, :script]),
            "record_id" => record && record.id,
            "written_fingerprint" => record && record.written_fingerprint,
            "set_row_id" => row && row.id,
            "row_label" => row && row.label,
            "macros" => if(macros != %{}, do: macros)
          },
          fn {_key, value} -> is_nil(value) end
        )

      Jobs.enqueue(scope, :side_prompt, %{
        origin: if(trigger == :manual, do: :interactive, else: :background),
        chat_id: chat.id,
        label: label(scope, trigger, side_prompt, row),
        ai_model_id: model.id,
        params: params,
        range_start: first,
        range_end: last,
        parent_id: opts[:parent_id]
      })
    else
      [] -> {:error, :empty_scene}
      error -> error
    end
  end

  defp macros_filled(side_prompt, macros) do
    if missing_macros(side_prompt, macros) == [], do: :ok, else: {:error, :missing_macros}
  end

  defp record_row(%Record{side_prompt_set_row_id: id}) when is_binary(id), do: Repo.get(SidePromptSetRow, id)
  defp record_row(_record), do: nil

  # A manual run is the user's own request, in their current language; the rest run unattended.
  defp label(scope, trigger, side_prompt, row) when trigger != :manual,
    do: Mythweaver.Locale.with_user_locale(scope, fn -> label(scope, :manual, side_prompt, row) end)

  defp label(_scope, _trigger, side_prompt, row) do
    case row && String.trim(row.label || "") do
      label when label in [nil, ""] ->
        dpgettext("memory", "heading: job that runs a side prompt", "Side prompt — %{side_prompt_name}",
          side_prompt_name: side_prompt.name
        )

      label ->
        dgettext("memory", "Side prompt — %{side_prompt_name} — %{row_label}",
          side_prompt_name: side_prompt.name,
          row_label: label
        )
    end
  end

  @doc "The macros `side_prompt` declares that have no non-blank value in `values`."
  @spec missing_macros(SidePrompt.t(), map()) :: [String.t()]
  def missing_macros(%SidePrompt{macros: macros}, values), do: Enum.reject(macros, &(Map.get(values, &1, "") != ""))

  @doc """
  Queues a manual run of every row of `set` in `chat`, in order. `{:ok, jobs}`, or the first
  error (rows before it stay queued).
  """
  @spec run_set(Scope.t(), Chat.t(), SidePromptSet.t()) :: {:ok, [Job.t()]} | {:error, term()}
  def run_set(%Scope{} = scope, %Chat{} = chat, %SidePromptSet{} = set) do
    if Ownership.reference_ok?(Memory.owner_of(chat), set) do
      set
      |> Repo.preload(rows: :side_prompt)
      |> Map.fetch!(:rows)
      |> Enum.reduce_while({:ok, []}, fn row, {:ok, jobs} ->
        case run(scope, chat, row.side_prompt, trigger: :manual, set_row: row) do
          {:ok, job} -> {:cont, {:ok, [job | jobs]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, jobs} -> {:ok, Enum.reverse(jobs)}
        error -> error
      end
    else
      {:error, :unauthorized}
    end
  end

  # A regeneration rewrites a record of this chat, in a book `scope` may edit, whose entry is still as
  # the side prompt last wrote it.
  defp target_for_regeneration(_scope, _chat, _side_prompt, nil), do: {:ok, nil}

  defp target_for_regeneration(scope, chat, %SidePrompt{id: id}, record_id) do
    case Repo.one(from(r in Record, where: r.id == ^record_id and r.kind == :side_prompt, preload: :entry)) do
      %Record{side_prompt_id: ^id} = record ->
        cond do
          own_record(scope, chat, record) != :ok -> {:error, :unauthorized}
          Scene.sha256(record.entry.content) != record.written_fingerprint -> {:error, :changed}
          true -> {:ok, record}
        end

      _missing ->
        {:error, :not_found}
    end
  end

  defp own_record(scope, %Chat{id: chat_id}, %Record{chat_id: chat_id} = record),
    do: Memory.authorize_book(scope, record.lore_book_id)

  defp own_record(_scope, _chat, _record), do: {:error, :unauthorized}

  # The side prompt's own profile, else the chat's.
  defp profile(scope, chat, %SidePrompt{profile_id: id}) do
    case id && Memory.get_profile(scope, id) do
      %Profile{} = profile -> {:ok, profile}
      nil -> Memory.profile_for(scope, chat)
    end
  end

  @doc "The side prompt's prompt: `{:error, :no_prompt}` when missing or not a side prompt."
  @spec side_prompt_prompt(Scope.t(), SidePrompt.t()) :: {:ok, Prompt.t()} | {:error, :no_prompt}
  def side_prompt_prompt(%Scope{} = scope, %SidePrompt{prompt_id: id}),
    do: Memory.purpose_prompt(scope, id, :side_prompt)

  defp range(_chat, _side_prompt, _row, %Record{snapshot: %{"range" => [first, last]}}, _opts), do: {:ok, first, last}

  defp range(chat, side_prompt, row, _record, opts) do
    floor = checkpoint_position(chat.id, side_prompt.id, row && row.id) || -1
    {default_first, default_last} = Memory.unprocessed_range(chat.id, floor)

    case {opts[:start] || default_first, opts[:end] || default_last} do
      {first, last} when is_integer(first) and is_integer(last) and first <= last -> {:ok, first, last}
      _nothing -> {:error, :empty_scene}
    end
  end

  @doc "The last message position `side_prompt`, run individually, has covered in `chat`, or nil."
  @spec checkpoint(Chat.t(), SidePrompt.t()) :: integer() | nil
  def checkpoint(%Chat{id: chat_id}, %SidePrompt{id: id}), do: checkpoint_position(chat_id, id, nil)

  defp checkpoint_position(chat_id, side_prompt_id, row_id) do
    from(c in SidePromptCheckpoint,
      where: c.chat_id == ^chat_id and c.side_prompt_id == ^side_prompt_id,
      select: c.last_position
    )
    |> for_row(row_id)
    |> Repo.one()
  end

  # Rows of a query on a table with `side_prompt_set_row_id`: that row's, or nil's (individual runs).
  defp for_row(query, nil), do: where(query, [r], is_nil(r.side_prompt_set_row_id))
  defp for_row(query, row_id), do: where(query, [r], r.side_prompt_set_row_id == ^row_id)

  @doc "Each side prompt's checkpoint in `chat` when run individually, keyed by side prompt id."
  @spec checkpoints(Scope.t(), Chat.t()) :: %{Ecto.UUID.t() => integer()}
  def checkpoints(%Scope{} = scope, %Chat{id: chat_id} = chat) do
    if Chats.authorize(scope, chat, :inspect) != :ok, do: raise(Mythweaver.UnauthorizedError)

    from(c in SidePromptCheckpoint, where: c.chat_id == ^chat_id, select: {c.side_prompt_id, c.last_position})
    |> for_row(nil)
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  The newest `:side_prompt` record `side_prompt_id` wrote in `chat_id` (its latest version) for the
  set row `row_id` (nil: run individually), with its entry, or nil.
  """
  @spec target_record(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t() | nil) :: Record.t() | nil
  def target_record(chat_id, side_prompt_id, row_id) do
    chat_id
    |> records_query(side_prompt_id, row_id)
    |> order_by([r], desc_nulls_last: r.version, desc: r.inserted_at, desc: r.id)
    |> limit(1)
    |> preload(:entry)
    |> Repo.one()
  end

  defp records_query(chat_id, side_prompt_id, row_id) do
    from(r in Record, where: r.chat_id == ^chat_id and r.side_prompt_id == ^side_prompt_id and r.kind == :side_prompt)
    |> for_row(row_id)
  end

  ## Triggers

  @doc """
  The side prompt set `chat` runs: `settings.side_prompt_set_id` in `:set` mode (`:missing` when it
  no longer resolves for the chat's owner), the `memory.side_prompt_set_solo`/`_group` setting in
  `:default` mode (nil when unset or gone), nil in `:individual` mode. Rows come with
  `:side_prompt`, in position order. A chat with no settings row yet is on `:default`; none is
  created here, since this runs after every message.
  """
  @spec chat_set(Scope.t(), Chat.t()) :: SidePromptSet.t() | :missing | nil
  def chat_set(%Scope{} = scope, %Chat{} = chat) do
    if Chats.authorize(scope, chat, :inspect) != :ok, do: raise(Mythweaver.UnauthorizedError)
    chat = Repo.preload(chat, :participants)
    settings = Repo.get_by(ChatSettings, chat_id: chat.id) || %ChatSettings{}

    case settings.side_prompt_set_mode do
      :individual ->
        nil

      :set ->
        load_set(chat, settings.side_prompt_set_id) || :missing

      :default ->
        key = if length(Chat.bots(chat)) >= 2, do: "memory.side_prompt_set_group", else: "memory.side_prompt_set_solo"
        load_set(chat, Mythweaver.Settings.get(scope, key))
    end
  end

  defp load_set(_chat, nil), do: nil

  defp load_set(chat, id) do
    SidePromptSet
    |> Ownership.for_owner(Memory.owner_of(chat))
    |> preload(rows: :side_prompt)
    |> Repo.get(id)
  end

  @doc """
  What runs automatically in `chat` on `trigger` (`:after_memory` or `:interval`), as
  `{side_prompt, row | nil}` in run order: the rows of the chat's set (`chat_set/2`) whose side
  prompt is enabled and runs on the trigger, else the enabled side prompts usable by the chat's
  owner that run on it, by name. A `:set` mode set that is gone runs nothing. An entry with a
  macro left unfilled (`missing_macros/2`) is dropped with a warning.
  """
  @spec automatic(Scope.t(), Chat.t(), :after_memory | :interval) :: [{SidePrompt.t(), SidePromptSetRow.t() | nil}]
  def automatic(%Scope{} = scope, %Chat{} = chat, trigger) when trigger in [:after_memory, :interval] do
    flag = if trigger == :after_memory, do: :run_after_memory, else: :run_on_interval

    entries =
      case chat_set(scope, chat) do
        :missing ->
          Logger.warning("Side prompt set for chat #{chat.id} is missing")
          []

        nil ->
          from(s in SidePrompt, where: s.enabled and field(s, ^flag), order_by: [asc: s.name])
          |> Ownership.owned_or_site(Memory.owner_of(chat))
          |> Repo.all()
          |> Enum.map(&{&1, nil})

        %SidePromptSet{rows: rows} ->
          for row <- rows, row.side_prompt.enabled and Map.fetch!(row.side_prompt, flag), do: {row.side_prompt, row}
      end

    Enum.filter(entries, fn {side_prompt, row} ->
      case missing_macros(side_prompt, (row && row.macro_values) || %{}) do
        [] ->
          true

        missing ->
          Logger.warning(
            "Side prompt #{side_prompt.name} for chat #{chat.id} skipped: no value for #{Enum.join(missing, ", ")}"
          )

          false
      end
    end)
  end

  @doc """
  Runs everything `automatic/3` lists for `:after_memory` over the memory `record` just saved,
  reading exactly `message_ids`, the messages the memory summarized.
  """
  @spec after_memory(Scope.t(), Chat.t(), Record.t(), Job.t(), [Ecto.UUID.t()]) :: :ok
  def after_memory(%Scope{} = scope, %Chat{} = chat, %Record{} = record, %Job{} = job, message_ids) do
    scope
    |> automatic(chat, :after_memory)
    |> Enum.each(fn {side_prompt, row} ->
      scope
      |> run(chat, side_prompt,
        start: record.range_start,
        end: record.range_end,
        trigger: :after_memory,
        parent_id: job.id,
        message_ids: message_ids,
        set_row: row
      )
      |> log_failure(chat, side_prompt)
    end)
  end

  @doc """
  Runs everything `automatic/3` lists for `:interval` with at least `interval` visible messages
  past its checkpoint in the chat (a set row has its own), unless a run of it is already queued or
  running there. Takes the chat or its id.
  """
  @spec check_intervals(Scope.t(), Chat.t() | Ecto.UUID.t()) :: :ok
  def check_intervals(%Scope{} = scope, %Chat{id: chat_id}), do: check_intervals(scope, chat_id)

  def check_intervals(%Scope{} = scope, chat_id) when is_binary(chat_id) do
    case Chats.get_chat(chat_id) do
      nil ->
        :ok

      chat ->
        scope
        |> automatic(chat, :interval)
        |> Enum.each(fn {side_prompt, row} ->
          row_id = row && row.id

          if due?(chat_id, side_prompt, row_id) and not running?(chat_id, side_prompt, row_id) do
            scope |> run(chat, side_prompt, trigger: :interval, set_row: row) |> log_failure(chat, side_prompt)
          end
        end)
    end
  end

  defp due?(chat_id, side_prompt, row_id) do
    floor = checkpoint_position(chat_id, side_prompt.id, row_id) || -1

    count =
      Repo.aggregate(
        from(m in Message,
          where: m.chat_id == ^chat_id and m.draft == false and m.visible_to_ai and m.position > ^floor
        ),
        :count
      )

    count >= side_prompt.interval
  end

  defp running?(chat_id, side_prompt, row_id) do
    query =
      from(j in Job,
        where: j.chat_id == ^chat_id and j.tag == :side_prompt and j.status in [:queued, :running],
        where: fragment("?->>'side_prompt_id' = ?", j.params, ^side_prompt.id)
      )

    query =
      if row_id,
        do: where(query, [j], fragment("?->>'set_row_id' = ?", j.params, ^row_id)),
        else: where(query, [j], fragment("?->>'set_row_id' IS NULL", j.params))

    Repo.exists?(query)
  end

  defp log_failure({:ok, _job}, _chat, _side_prompt), do: :ok

  defp log_failure(error, chat, side_prompt),
    do: Logger.warning("Side prompt #{side_prompt.name} for chat #{chat.id} not started: #{inspect(error)}")

  ## Saving

  @doc """
  Writes a `:side_prompt` job's output `text`, in one transaction:

    * a regeneration (`params["record_id"]`) replaces only that entry's content, and only while the
      entry is as the side prompt last wrote it; otherwise `{:error, :changed}`
    * with versioning (`prefs.side_prompt_versioning` and `side_prompt.save_versions`), a new
      `"<title>-NNN"` entry is created and the older versions are disabled
    * otherwise the side prompt's latest entry in the chat is updated in place, in its own book, or
      created when there is none

  A new entry (the first write, or a new version) goes to the chat's override for the side prompt
  (`ChatSettings.side_prompt_book_ids`), else the side prompt's `target_book_id`, else the chat's
  memory book, with the side prompt's entry settings.

  Then the chat's checkpoint for the side prompt moves to the run's last position.

  A set row's run (`params["set_row_id"]`) does all of this on its own records and checkpoint, and
  names a new entry after the row's label when it has one; `{:error, :source_missing}` when the
  row is gone.
  """
  @spec save_side_prompt(Scope.t(), Job.t(), String.t() | nil) :: {:ok, Record.t()} | {:error, term()}
  def save_side_prompt(%Scope{} = scope, %Job{params: params} = job, text) do
    with {:ok, text} <- non_blank(text),
         %Chat{} = chat <- Chats.get_chat(params["chat_id"]) || {:error, :no_chat},
         :ok <- Chats.authorize(scope, chat, :manage),
         scope = Chats.run_scope(scope, chat),
         %SidePrompt{} = side_prompt <-
           Memory.get_side_prompt(scope, params["side_prompt_id"]) || {:error, :source_missing},
         {:ok, record} <-
           Jobs.complete_in_transaction(job, fn ->
             record = save_tx(scope, chat, side_prompt, params, text)
             {record, Map.put(job.result || %{}, "record_id", record.id)}
           end) do
      Memory.broadcast_changed(chat.id)
      {:ok, record}
    else
      {:error, %Ecto.Changeset{}} -> {:error, :invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp non_blank(text) when is_binary(text) do
    case String.trim(text) do
      "" -> {:error, :empty}
      text -> {:ok, text}
    end
  end

  defp non_blank(_text), do: {:error, :empty}

  defp save_tx(scope, chat, _side_prompt, %{"record_id" => id} = params, text) when is_binary(id) do
    record =
      case Repo.one(from(r in Record, where: r.id == ^id and r.kind == :side_prompt, lock: "FOR UPDATE")) do
        nil -> Repo.rollback(:changed)
        record -> Repo.preload(record, :entry)
      end

    if own_record(scope, chat, record) != :ok, do: Repo.rollback(:unauthorized)

    unchanged? =
      record.written_fingerprint == params["written_fingerprint"] and
        Scene.sha256(record.entry.content) == record.written_fingerprint

    if !unchanged?, do: Repo.rollback(:changed)

    entry =
      Gate.unmoderated(fn -> Lore.update_entry(scope, record.entry, %{content: text}) end) |> Repo.ok_or_rollback()

    record
    |> Ecto.Changeset.change(written_fingerprint: Scene.sha256(entry.content))
    |> Repo.update!()
  end

  defp save_tx(scope, chat, side_prompt, params, text) do
    # Locks the template so two saves for it (a review approved while a run finishes) take turns
    # picking the target and the next version.
    Repo.one!(from(s in SidePrompt, where: s.id == ^side_prompt.id, lock: "FOR UPDATE", select: s.id))
    row_id = params["set_row_id"]
    if row_id && !Repo.exists?(from(r in SidePromptSetRow, where: r.id == ^row_id)), do: Repo.rollback(:source_missing)
    target = target_record(chat.id, side_prompt.id, row_id)
    versioned? = Memory.preferences(scope).side_prompt_versioning and side_prompt.save_versions

    record =
      cond do
        versioned? -> new_version!(scope, chat, side_prompt, params, text)
        target -> update_in_place!(scope, target, params, text)
        true -> create!(scope, chat, side_prompt, params, text, nil, nil)
      end

    upsert_checkpoint!(chat, side_prompt, row_id, params["end"])
    record
  end

  # Disables every older version first, in its own record's book; the new entry starts enabled.
  defp new_version!(scope, chat, side_prompt, params, text) do
    query = records_query(chat.id, side_prompt.id, params["set_row_id"])
    version = (Repo.one(select(query, [r], max(r.version))) || 0) + 1

    older =
      Repo.all(
        from(r in query,
          join: be in BookEntry,
          on: be.lore_book_id == r.lore_book_id and be.lore_entry_id == r.lore_entry_id,
          where: be.enabled
        )
      )

    Lore.set_memberships_enabled(Enum.map(older, &{&1.lore_book_id, &1.lore_entry_id}), false)

    snapshot_extra = %{"disabled_entry_ids" => Enum.map(older, & &1.lore_entry_id)}
    name = "#{base_name(side_prompt, params)}-#{version |> Integer.to_string() |> String.pad_leading(3, "0")}"
    create!(scope, chat, side_prompt, params, text, version, name, snapshot_extra)
  end

  defp update_in_place!(scope, %Record{entry: entry} = record, params, text) do
    prior = %{
      "name" => entry.name,
      "content" => entry.content,
      "keywords" => entry.keywords,
      # The membership's switch in this record's book; the entry itself has none.
      "enabled" => Memory.record_enabled?(record)
    }

    entry = Gate.unmoderated(fn -> Lore.update_entry(scope, entry, %{content: text}) end) |> Repo.ok_or_rollback()

    record
    |> Record.changeset(%{
      range_start: params["start"],
      range_end: params["end"],
      written_fingerprint: Scene.sha256(entry.content),
      profile_id: params["profile_id"],
      prompt_id: params["prompt_id"],
      snapshot: snapshot(true, prior, params)
    })
    |> Repo.update()
    |> Repo.ok_or_rollback()
  end

  # The chat's own book for this side prompt's new entries; nil when unset, gone or not editable.
  defp chat_book(scope, chat, side_prompt) do
    case Memory.chat_settings(scope, chat).side_prompt_book_ids[side_prompt.id] do
      nil -> nil
      book_id -> editable_book(scope, book_id)
    end
  end

  defp editable_book(scope, book_id), do: Repo.get(Ownership.editable(LoreBook, scope), book_id)

  defp create!(scope, chat, side_prompt, params, text, version, name, snapshot_extra \\ %{}) do
    book =
      chat_book(scope, chat, side_prompt) ||
        (side_prompt.target_book_id && editable_book(scope, side_prompt.target_book_id)) ||
        Memory.ensure_book(scope, chat)

    name = name || base_name(side_prompt, params)

    entry =
      %{
        name: name,
        content: text,
        keywords: entry_keywords(side_prompt, name),
        activation: side_prompt.activation,
        outlet: side_prompt.outlet,
        placement: side_prompt.placement,
        custom_outlet: side_prompt.custom_outlet,
        depth: side_prompt.depth,
        prevent_recursion: side_prompt.prevent_recursion,
        exclude_recursion: side_prompt.exclude_recursion,
        ignore_budget: side_prompt.ignore_budget
      }
      |> then(fn attrs ->
        Gate.unmoderated(fn -> Lore.create_entry(scope, attrs, [book.id], %{order: side_prompt.order}) end)
      end)
      |> Repo.ok_or_rollback()

    %Record{}
    |> Record.changeset(%{
      lore_entry_id: entry.id,
      lore_book_id: book.id,
      chat_id: chat.id,
      kind: :side_prompt,
      range_start: params["start"],
      range_end: params["end"],
      written_fingerprint: Scene.sha256(entry.content),
      profile_id: params["profile_id"],
      prompt_id: params["prompt_id"],
      side_prompt_id: side_prompt.id,
      version: version,
      side_prompt_set_row_id: params["set_row_id"],
      snapshot: Map.merge(snapshot(false, nil, params), snapshot_extra)
    })
    |> Repo.insert()
    |> Repo.ok_or_rollback()
  end

  defp snapshot(existed?, prior, params) do
    %{
      "existed" => existed?,
      "prior" => prior,
      "message_ids" => params["message_ids"],
      "range" => [params["start"], params["end"]],
      "template" => params["side_prompt_id"]
    }
  end

  defp title(%SidePrompt{title: title, name: name}) do
    case String.trim(title || "") do
      "" -> name
      title -> title
    end
  end

  # A set row's entries are named after its label, when it has one.
  defp base_name(side_prompt, params) do
    case String.trim(params["row_label"] || "") do
      "" -> title(side_prompt)
      label -> label
    end
  end

  # A keyword-activated entry needs a keyword: without any configured, it is keyed on its title.
  defp entry_keywords(%SidePrompt{activation: :keyword, keywords: []}, name), do: [name]
  defp entry_keywords(%SidePrompt{keywords: keywords}, _name), do: keywords

  defp upsert_checkpoint!(chat, side_prompt, row_id, last) do
    now = DateTime.utc_now(:second)

    %SidePromptCheckpoint{}
    |> SidePromptCheckpoint.changeset(%{
      chat_id: chat.id,
      side_prompt_id: side_prompt.id,
      side_prompt_set_row_id: row_id,
      last_position: last
    })
    |> Repo.insert!(
      on_conflict: [set: [last_position: last, updated_at: now]],
      conflict_target: [:chat_id, :side_prompt_id, :side_prompt_set_row_id]
    )
  end
end
