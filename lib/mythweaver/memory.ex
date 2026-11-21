defmodule Mythweaver.Memory do
  @moduledoc """
  The Memory Books context (SillyTavern-MemoryBooks, built server-side): AI-written scene memories
  stored as lore entries in a per-chat memory book, plus the profiles, preferences, side prompts and
  per-chat settings that drive them.

  The data model:

    * `Profile`: reusable model, prompt and entry settings; one may be the default
    * memory settings live in `Mythweaver.Settings` under `memory.*`, read through `preferences/1`
    * `ChatSettings`: one chat's book, profile, auto-memory triggers and processed boundary
    * `Record`: the memory metadata of one managed lore entry; `RecordSource` links a consolidation
      to its sources. An entry written elsewhere can be adopted as a memory (`mark_as_memories/3`);
      its record has no chat and no message range, so it is never regenerated
    * `SidePrompt` and `SidePromptCheckpoint`: extra trackers and how far each has run per chat;
      `SidePromptSet` holds ordered rows of side prompts with their runtime macro values
    * `CharacterBook`: a user's lock of one character to a book; new memories are copied into each
      present character's book (`CharacterBooks.character_book/3`) as records with a `canonical_id`
    * sub-contexts: `Memory.Clips` (clips, topical clips, Memory Assistance and topic suggestions),
      `Memory.Consolidation` (eligibility, batches, running and saving consolidations) and
      `Memory.CharacterBooks` (character locks and per-chat character books)

  Memory changes broadcast `{:memory_changed, chat_id}` on `topic/1`.

  ## Ownership

  Profiles, side prompts and side prompt sets follow `Mythweaver.Ownership` (`"content.memory.create"`), like lore
  books: editor lists (`list_profiles/1`, `list_side_prompts/1`) hold editable rows, pickers
  (`list_usable_profiles/1`) and `get_*` usable ones, and a chat runs only what its owner may use
  (`profile_for/2`, `list_chat_side_prompts/1`). Each owner has at most one default profile. A
  profile or side prompt references only prompts, models, profiles and books of its own owner or the
  site's. A chat's memory book and side-prompt books are books the chat's owner may edit (its own, or
  the site's for an admin; `update_chat_settings/3`, `ensure_book/2`). Memory jobs write only to books
  their scope may edit (`authorize_book/2`), and a regeneration rewrites only a record of its own
  chat; the panel lists only records of editable books (`list_records/2`).

  A chat's memory work runs as its owner whoever asks (`Mythweaver.Chats.run_scope/2`): a chat
  editor's memory, consolidation, compaction, clip, assistance and side-prompt jobs resolve the
  owner's profile, models, prompts and quota and save as the owner, while each job stays recorded
  under the editor who started it. `create_memory/5` keeps the asker's own preferences (previews,
  token warnings).
  """

  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Query, warn: false

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.AI
  alias Mythweaver.AI.Model
  alias Mythweaver.Changes
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Format
  alias Mythweaver.Jobs
  alias Mythweaver.Jobs.Job
  alias Mythweaver.Lore
  alias Mythweaver.Lore.BookEntry
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Memory.CharacterBook
  alias Mythweaver.Memory.CharacterBooks
  alias Mythweaver.Memory.ChatSettings
  alias Mythweaver.Memory.Clips
  alias Mythweaver.Memory.Consolidation
  alias Mythweaver.Memory.JSON
  alias Mythweaver.Memory.Profile
  alias Mythweaver.Memory.Record
  alias Mythweaver.Memory.RecordSource
  alias Mythweaver.Memory.Request
  alias Mythweaver.Memory.Scene
  alias Mythweaver.Memory.SidePrompt
  alias Mythweaver.Memory.SidePrompts
  alias Mythweaver.Memory.SidePromptSet
  alias Mythweaver.Memory.Title
  alias Mythweaver.Memory.Workers
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message
  alias Mythweaver.Moderation.Gate
  alias Mythweaver.Ownership
  alias Mythweaver.Prompts
  alias Mythweaver.Prompts.Anchor
  alias Mythweaver.Prompts.Prompt
  alias Mythweaver.Repo
  alias Mythweaver.Sharing.Visibility

  require Logger

  @pubsub Mythweaver.PubSub

  ## PubSub

  @doc "The PubSub topic for one chat's memory changes."
  def topic(chat_id), do: "memory:#{chat_id}"

  @doc "Broadcasts `{:memory_changed, chat_id}` on `topic/1`."
  def broadcast_changed(chat_id) do
    Phoenix.PubSub.broadcast(@pubsub, topic(chat_id), {:memory_changed, chat_id})
    owner = Chats.owner_id(chat_id)
    Changes.broadcast(:lore, [nil, owner])
  end

  ## Preferences

  @preference_keys ~w(show_previews show_consolidation_previews token_warning_threshold
                      default_previous_count allow_overlap include_hidden boundary_indicator
                      consolidation_watch_tiers consolidation_max_entries consolidation_token_budget
                      rollback_enabled rollback_scope rollback_update_boundary
                      rollback_delete_memories rollback_restore_side_prompts side_prompt_versioning
                     auto_trigger auto_interval auto_buffer auto_token_threshold
                     manual_reminders manual_reminder_interval auto_reminders auto_reminder_interval
                     assistance_mode)a

  @auto_keys ~w(auto_trigger auto_interval auto_buffer auto_token_threshold)a

  @doc """
  The memory settings (`memory.*` in `Mythweaver.Settings`) as `scope` reads them, keyed by field;
  `consolidation_minimums` maps each tier `"1".."6"` to its minimum.
  """
  @spec preferences(Scope.t()) :: map()
  def preferences(%Scope{} = scope) do
    keys = Enum.map(@preference_keys, &"memory.#{&1}")
    minimum_keys = Enum.map(1..6, &"memory.consolidation_minimum_#{&1}")
    values = Mythweaver.Settings.get_many(scope, keys ++ minimum_keys)

    @preference_keys
    |> Map.new(&{&1, Map.fetch!(values, "memory.#{&1}")})
    |> Map.put(
      :consolidation_minimums,
      Map.new(1..6, &{"#{&1}", Map.fetch!(values, "memory.consolidation_minimum_#{&1}")})
    )
  end

  ## Chat settings

  @doc """
  The chat's memory settings, created with defaults on first read. A solo chat whose character is
  locked to a book (`CharacterBooks.lock_character_book/3`) follows the lock: its memory book becomes that book.
  """
  @spec chat_settings(Scope.t(), Chat.t()) :: ChatSettings.t()
  def chat_settings(%Scope{} = scope, %Chat{} = chat) do
    authorize!(Chats.authorize(scope, chat, :inspect))
    chat |> settings_row() |> follow_solo_lock(scope, Repo.preload(chat, :participants))
  end

  # The old book keeps its chat binding and its memories; only new memories go to the locked book.
  defp follow_solo_lock(settings, scope, chat) do
    with [bot] <- Chat.bots(chat),
         %CharacterBook{lore_book_id: book_id} when book_id != settings.memory_book_id <-
           Repo.get_by(CharacterBook, user_id: owner_of(chat), character_id: bot.character_id),
         %LoreBook{} <- Repo.get(Ownership.editable(LoreBook, scope), book_id) do
      settings |> Ecto.Changeset.change(memory_book_id: book_id) |> Repo.update!()
    else
      _ -> settings
    end
  end

  @doc """
  The automatic-memory trigger, interval, buffer and token threshold in effect for a chat: each of
  `settings`' own values, else (nil) `scope`'s `memory.auto_*` setting. `scope` is the chat owner's.
  """
  @spec auto_settings(Scope.t(), ChatSettings.t()) :: %{
          auto_trigger: :messages | :tokens,
          auto_interval: pos_integer(),
          auto_buffer: non_neg_integer(),
          auto_token_threshold: pos_integer()
        }
  def auto_settings(%Scope{} = scope, %ChatSettings{} = settings) do
    prefs = preferences(scope)
    Map.new(@auto_keys, &{&1, Map.fetch!(settings, &1) || Map.fetch!(prefs, &1)})
  end

  @doc false
  def settings_row(%Chat{id: chat_id}) do
    case Repo.get_by(ChatSettings, chat_id: chat_id) do
      nil ->
        Repo.insert!(%ChatSettings{chat_id: chat_id}, on_conflict: :nothing, conflict_target: :chat_id)
        Repo.get_by!(ChatSettings, chat_id: chat_id)

      settings ->
        settings
    end
  end

  defp authorize!(:ok), do: :ok
  defp authorize!({:error, :unauthorized}), do: raise(Mythweaver.UnauthorizedError)

  @doc "`:ok` when `scope` may edit (write memories into) the book `book_id`."
  @spec authorize_book(Scope.t(), Ecto.UUID.t()) :: :ok | {:error, :unauthorized}
  def authorize_book(%Scope{} = scope, book_id) do
    case get_owned(LoreBook, book_id) do
      %LoreBook{} = book -> Ownership.authorize_edit(scope, book)
      nil -> {:error, :unauthorized}
    end
  end

  @doc """
  Updates a chat's memory settings. Every newly chosen book (the memory book, a side prompt's book, or
  a character memory book) must be one the chat's owner may edit, the profile and the side prompt set
  usable by the owner, the Additional Context entries usable and readable by the owner, and every
  present-cast character a non-player participant, so a chat never points at another user's content
  nor writes into a site book a non-admin owner cannot edit. `scope` may `:manage` the chat
  (`Chats.authorize/3`: its owner or a chat editor).
  """
  @spec update_chat_settings(Scope.t(), ChatSettings.t(), map()) ::
          {:ok, ChatSettings.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def update_chat_settings(%Scope{} = scope, %ChatSettings{} = settings, attrs) do
    with :ok <- Chats.authorize(scope, settings.chat_id, :manage) do
      changeset = ChatSettings.changeset(settings, attrs)
      chat = Repo.one!(from(c in Chat, where: c.id == ^settings.chat_id, preload: :participants))
      profile = Ecto.Changeset.get_change(changeset, :profile_id)
      entries = (Ecto.Changeset.get_change(changeset, :context_entry_ids) || []) -- settings.context_entry_ids
      bots = MapSet.new(Chat.bots(chat), & &1.character_id)
      cast = Ecto.Changeset.get_change(changeset, :cast_ids) || []
      set = Ecto.Changeset.get_change(changeset, :side_prompt_set_id)

      if all_in?(Ownership.editable(LoreBook, scope), newly_chosen_books(changeset, settings)) and
           all_in?(Ownership.for_owner(Profile, chat.user_id), List.wrap(profile)) and
           all_in?(LoreEntry |> Ownership.for_owner(chat.user_id) |> Visibility.readable_entries(scope), entries) and
           Enum.all?(cast, &MapSet.member?(bots, &1)) and
           all_in?(Ownership.for_owner(SidePromptSet, chat.user_id), List.wrap(set)),
         do: Repo.update(changeset),
         else: {:error, :unauthorized}
    end
  end

  # Whether every id is a row of `query`; an id that is not a UUID or is gone fails.
  defp all_in?(query, ids) do
    ids = Enum.uniq(ids)

    Enum.all?(ids, &match?({:ok, _}, Ecto.UUID.cast(&1))) and
      query |> where([r], r.id in ^ids) |> Repo.aggregate(:count) == length(ids)
  end

  @doc "The books `scope` may pick as a chat's memory book or a side prompt's book: those it may edit, by name."
  @spec list_memory_books(Scope.t()) :: [LoreBook.t()]
  def list_memory_books(%Scope{} = scope) do
    from(b in LoreBook, order_by: [asc: b.name, asc: b.id]) |> Ownership.editable(scope) |> Repo.all()
  end

  defp newly_chosen_books(changeset, %ChatSettings{} = settings) do
    [
      Ecto.Changeset.get_change(changeset, :memory_book_id)
      | new_values(changeset, :side_prompt_book_ids, settings.side_prompt_book_ids) ++
          new_values(changeset, :character_book_ids, settings.character_book_ids)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp new_values(changeset, field, old),
    do: Map.values(Ecto.Changeset.get_change(changeset, field) || %{}) -- Map.values(old)

  def change_chat_settings(%ChatSettings{} = settings, attrs \\ %{}) do
    ChatSettings.changeset(settings, attrs)
  end

  ## Profiles

  @doc "Profiles `scope` may edit, by name."
  def list_profiles(%Scope{} = scope) do
    from(p in Profile, order_by: [asc: p.name, asc: p.id]) |> Ownership.editable(scope) |> Repo.all()
  end

  @doc "Profiles `scope` may use (its own plus the site's), by name: pickers."
  def list_usable_profiles(%Scope{} = scope) do
    from(p in Profile, order_by: [asc: p.name, asc: p.id]) |> Ownership.usable(scope) |> Repo.all()
  end

  @doc "A profile `scope` may use, or nil."
  def get_profile(%Scope{} = scope, id), do: get_owned(Ownership.usable(Profile, scope), id)

  @doc "A profile `scope` may edit, or nil."
  def get_editable_profile(%Scope{} = scope, id), do: get_owned(Ownership.editable(Profile, scope), id)

  @doc false
  def get_owned(query, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get(query, id)
      :error -> nil
    end
  end

  @doc "The default profile for `scope`: its own default, else the site's, or nil."
  def default_profile(%Scope{user: user}), do: default_for(user && user.id)

  # The owner's own default first, then the site's; never a shared profile's default flag.
  defp default_for(owner_id) do
    from(p in Profile,
      where: p.default,
      order_by: [asc_nulls_last: p.user_id],
      limit: 1
    )
    |> Ownership.owned_or_site(owner_id)
    |> Repo.one()
  end

  @doc "Creates a memory profile owned per `Ownership.new_owner/3`: `scope`'s own, or the site's with `site: true`."
  def create_profile(%Scope{} = scope, attrs \\ %{}, opts \\ []) do
    with {:ok, owner} <- Ownership.new_owner(scope, Profile, opts) do
      %Profile{user_id: owner}
      |> profile_changeset(attrs)
      |> validate_references(ai_model_id: Model)
      |> validate_profile_prompts()
      |> Repo.insert()
      |> Changes.notify(:memory)
    end
  end

  def update_profile(%Scope{} = scope, %Profile{} = profile, attrs) do
    with :ok <- Ownership.authorize_edit(scope, profile) do
      profile
      |> profile_changeset(attrs)
      |> validate_references(ai_model_id: Model)
      |> validate_profile_prompts()
      |> Repo.update()
      |> Changes.notify(:memory)
    end
  end

  @doc """
  Deletes a memory profile. With accepted editors it is given to `opts[:to]` or the oldest of them
  instead (`Mythweaver.Sharing.hand_off_or/4`).
  """
  @spec delete_profile(Scope.t(), Profile.t(), keyword()) ::
          {:ok, Profile.t() | {:handed_off, User.t()}} | {:error, Ecto.Changeset.t() | :unauthorized}
  def delete_profile(%Scope{} = scope, %Profile{} = profile, opts \\ []) do
    with :ok <- Ownership.authorize_delete(scope, profile) do
      Mythweaver.Sharing.hand_off_or(scope, profile, opts, fn ->
        :ok = Mythweaver.Sharing.revoke_all(:memory_profile, profile.id, :deleted)
        profile |> Repo.delete() |> Changes.notify(:memory)
      end)
    end
  end

  def change_profile(%Profile{} = profile, attrs \\ %{}), do: profile_changeset(profile, attrs)

  defp profile_changeset(profile, attrs) do
    profile
    |> Profile.changeset(attrs)
    |> validate_prompt_purposes(Profile.prompt_purposes())
  end

  @doc """
  Makes `profile` the default for its owner (the site's default for a site profile), clearing that
  owner's other default in the same transaction.
  """
  @spec set_default_profile(Scope.t(), Profile.t()) :: {:ok, Profile.t()} | {:error, term()}
  def set_default_profile(%Scope{} = scope, %Profile{id: id} = profile) do
    with :ok <- Ownership.authorize_edit(scope, profile) do
      Repo.transaction(fn ->
        from(p in Profile, where: p.default and p.id != ^id)
        |> Ownership.owned_exactly(profile.user_id)
        |> Repo.update_all(set: [default: false])

        profile
        |> Ecto.Changeset.change(default: true)
        |> Repo.update()
        |> case do
          {:ok, profile} -> profile
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
      |> Changes.notify(:memory, profile.user_id)
    end
  end

  @doc """
  The profile a chat's memory jobs use, by the chat's owner: the chat settings' profile when the owner
  may use it, then the owner's own default, then the site's default.
  """
  @spec profile_for(Scope.t(), Chat.t()) :: {:ok, Profile.t()} | {:error, :no_profile}
  def profile_for(%Scope{}, %Chat{id: chat_id} = chat) do
    profile_id = Repo.one(from(s in ChatSettings, where: s.chat_id == ^chat_id, select: s.profile_id))
    owner_id = owner_of(chat)

    case (profile_id && Repo.get(Ownership.for_owner(Profile, owner_id), profile_id)) || default_for(owner_id) do
      %Profile{} = profile -> {:ok, profile}
      nil -> {:error, :no_profile}
    end
  end

  # A chat struct built without its owner (a bare `%Chat{id: id}`) reads it from the database.
  @doc false
  def owner_of(%Chat{user_id: nil, id: id}) when is_binary(id), do: Chats.owner_id(id)

  def owner_of(%Chat{user_id: owner_id}), do: owner_id

  @doc """
  The model a memory job runs on: the profile's model, then the chat's model, then
  `Mythweaver.AI.default_model/1`. A model `scope` may not run (`AI.usable?/2`) counts as unset.
  """
  @spec model_for(Scope.t(), Chat.t(), Profile.t()) ::
          {:ok, Model.t()} | {:error, :no_model | :ambiguous_model | :unauthorized}
  def model_for(%Scope{} = scope, %Chat{} = chat, %Profile{} = profile) do
    with :ok <- Chats.authorize(scope, chat, :inspect),
         nil <- profile.ai_model_id && AI.get_model(scope, profile.ai_model_id),
         nil <- chat.ai_model_id && AI.get_model(scope, chat.ai_model_id) do
      AI.default_model(scope)
    else
      %Model{} = model -> {:ok, model}
      {:error, _} = error -> error
    end
  end

  ## Side prompts

  @doc "Side prompts `scope` may edit, by name."
  def list_side_prompts(%Scope{} = scope) do
    from(s in SidePrompt, order_by: [asc: s.name, asc: s.id]) |> Ownership.editable(scope) |> Repo.all()
  end

  @doc "Side prompts usable in `chat`: the site's plus the chat owner's, by name."
  def list_chat_side_prompts(%Chat{} = chat) do
    from(s in SidePrompt, order_by: [asc: s.name, asc: s.id]) |> Ownership.for_owner(owner_of(chat)) |> Repo.all()
  end

  @doc "Side prompts `scope` may use: the site's plus its own, by name."
  def list_usable_side_prompts(%Scope{} = scope) do
    from(s in SidePrompt, order_by: [asc: s.name, asc: s.id]) |> Ownership.usable(scope) |> Repo.all()
  end

  @doc "A side prompt `scope` may use, or nil."
  def get_side_prompt(%Scope{} = scope, id), do: get_owned(Ownership.usable(SidePrompt, scope), id)

  @doc "A side prompt `scope` may edit, or nil."
  def get_editable_side_prompt(%Scope{} = scope, id), do: get_owned(Ownership.editable(SidePrompt, scope), id)

  @doc "Creates a side prompt owned per `Ownership.new_owner/3`: `scope`'s own, or the site's with `site: true`."
  def create_side_prompt(%Scope{} = scope, attrs \\ %{}, opts \\ []) do
    with {:ok, owner} <- Ownership.new_owner(scope, SidePrompt, opts) do
      %SidePrompt{user_id: owner}
      |> side_prompt_changeset(attrs)
      |> validate_references(prompt_id: Prompt, target_book_id: LoreBook, profile_id: Profile)
      |> Repo.insert()
      |> Changes.notify(:memory)
    end
  end

  def update_side_prompt(%Scope{} = scope, %SidePrompt{} = side_prompt, attrs) do
    with :ok <- Ownership.authorize_edit(scope, side_prompt) do
      side_prompt
      |> side_prompt_changeset(attrs)
      |> validate_references(prompt_id: Prompt, target_book_id: LoreBook, profile_id: Profile)
      |> Repo.update()
      |> Changes.notify(:memory)
    end
  end

  @doc """
  Deletes a side prompt. With accepted editors it is given to `opts[:to]` or the oldest of them
  instead (`Mythweaver.Sharing.hand_off_or/4`), which refuses with `{:needs_share, prompt}` while
  that editor could not use its prompt.
  """
  @spec delete_side_prompt(Scope.t(), SidePrompt.t(), keyword()) ::
          {:ok, SidePrompt.t() | {:handed_off, User.t()}}
          | {:error, Ecto.Changeset.t() | :unauthorized | {:needs_share, Prompt.t()}}
  def delete_side_prompt(%Scope{} = scope, %SidePrompt{} = side_prompt, opts \\ []) do
    with :ok <- Ownership.authorize_delete(scope, side_prompt) do
      Mythweaver.Sharing.hand_off_or(scope, side_prompt, opts, fn ->
        :ok = Mythweaver.Sharing.revoke_all(:side_prompt, side_prompt.id, :deleted)
        side_prompt |> Repo.delete() |> Changes.notify(:memory)
      end)
    end
  end

  def change_side_prompt(%SidePrompt{} = side_prompt, attrs \\ %{}), do: side_prompt_changeset(side_prompt, attrs)

  defp side_prompt_changeset(side_prompt, attrs) do
    side_prompt
    |> SidePrompt.changeset(attrs)
    |> validate_prompt_purposes(prompt_id: :side_prompt)
  end

  ## Side prompt sets

  @doc "Side prompt sets `scope` may edit, by name."
  def list_side_prompt_sets(%Scope{} = scope) do
    from(s in SidePromptSet, order_by: [asc: s.name, asc: s.id]) |> Ownership.editable(scope) |> Repo.all()
  end

  @doc "Side prompt sets `scope` may use: the site's plus its own, by name."
  def list_usable_side_prompt_sets(%Scope{} = scope) do
    from(s in SidePromptSet, order_by: [asc: s.name, asc: s.id]) |> Ownership.usable(scope) |> Repo.all()
  end

  @doc "A side prompt set `scope` may edit, with `rows: :side_prompt`, or nil."
  def get_editable_side_prompt_set(%Scope{} = scope, id) do
    case get_owned(Ownership.editable(SidePromptSet, scope), id) do
      nil -> nil
      set -> Repo.preload(set, rows: :side_prompt)
    end
  end

  @doc """
  Creates a side prompt set with its rows, owned per `Ownership.new_owner/3`: `scope`'s own, or the
  site's with `site: true`. Every row's side prompt must be one the set's owner may reference (the
  site's, or the owner's own), else `{:error, :unauthorized}`.
  """
  def create_side_prompt_set(%Scope{} = scope, attrs \\ %{}, opts \\ []) do
    with {:ok, owner} <- Ownership.new_owner(scope, SidePromptSet, opts) do
      changeset = SidePromptSet.changeset(%SidePromptSet{user_id: owner, rows: []}, attrs)
      with :ok <- set_rows_ok(changeset, owner), do: changeset |> Repo.insert() |> Changes.notify(:memory)
    end
  end

  @doc "Updates a set `scope` may edit; its rows are checked as in `create_side_prompt_set/2`."
  def update_side_prompt_set(%Scope{} = scope, %SidePromptSet{} = set, attrs) do
    with :ok <- Ownership.authorize_edit(scope, set) do
      changeset = set |> with_rows() |> SidePromptSet.changeset(attrs)
      with :ok <- set_rows_ok(changeset, set.user_id), do: changeset |> Repo.update() |> Changes.notify(:memory)
    end
  end

  @doc """
  Deletes a side prompt set. With accepted editors it is given to `opts[:to]` or the oldest of them
  instead (`Mythweaver.Sharing.hand_off_or/4`).
  """
  @spec delete_side_prompt_set(Scope.t(), SidePromptSet.t(), keyword()) ::
          {:ok, SidePromptSet.t() | {:handed_off, User.t()}} | {:error, Ecto.Changeset.t() | :unauthorized}
  def delete_side_prompt_set(%Scope{} = scope, %SidePromptSet{} = set, opts \\ []) do
    with :ok <- Ownership.authorize_delete(scope, set) do
      Mythweaver.Sharing.hand_off_or(scope, set, opts, fn ->
        :ok = Mythweaver.Sharing.revoke_all(:side_prompt_set, set.id, :deleted)
        set |> Repo.delete() |> Changes.notify(:memory)
      end)
    end
  end

  def change_side_prompt_set(%SidePromptSet{} = set, attrs \\ %{}) do
    set |> with_rows() |> SidePromptSet.changeset(attrs)
  end

  defp with_rows(%SidePromptSet{id: nil, rows: %Ecto.Association.NotLoaded{}} = set), do: %{set | rows: []}
  defp with_rows(%SidePromptSet{} = set), do: Repo.preload(set, :rows)

  # Every row's side prompt exists and `owner_id` may reference it. A row with none is left to the
  # changeset's `validate_required`.
  defp set_rows_ok(changeset, owner_id) do
    ids =
      changeset
      |> Ecto.Changeset.get_field(:rows)
      |> Enum.map(& &1.side_prompt_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    side_prompts = Repo.all(from(s in SidePrompt, where: s.id in ^ids))

    if length(side_prompts) == length(ids) and Enum.all?(side_prompts, &Ownership.reference_ok?(owner_id, &1)),
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp validate_profile_prompts(changeset),
    do: validate_references(changeset, Enum.map(Profile.prompt_purposes(), fn {field, _} -> {field, Prompt} end))

  # Each `{field, schema}` must point at a row the changeset's owner may reference (`user_id` on the
  # struct: the site's, or its own). Checked on insert/update only, since a form's struct may not
  # carry its eventual owner yet.
  defp validate_references(changeset, fields) do
    owner = Ecto.Changeset.get_field(changeset, :user_id)

    Enum.reduce(fields, changeset, fn {field, schema}, changeset ->
      Ecto.Changeset.validate_change(changeset, field, fn ^field, id ->
        case Repo.one(reference_query(schema, id)) do
          nil ->
            []

          {_owner, mode} when mode in [:embedding, :classifier] ->
            [{field, dgettext_noop("errors", "is not available")}]

          {nil, _mode} ->
            []

          {^owner, _mode} ->
            []

          _other ->
            [{field, dgettext_noop("errors", "is not available")}]
        end
      end)
    end)
  end

  # An embedding or classifier model can't run a memory job, so it is refused like a model the owner
  # can't use.
  defp reference_query(Model, id), do: from(m in Model, where: m.id == ^id, select: {m.user_id, m.completion_mode})
  defp reference_query(schema, id), do: from(r in schema, where: r.id == ^id, select: {r.user_id, nil})

  # A memory prompt is picked by purpose; pointing a profile at a roleplay prompt would send a reply
  # prompt to a summarizing job.
  defp validate_prompt_purposes(changeset, fields) do
    Enum.reduce(fields, changeset, fn {field, purpose}, changeset ->
      Ecto.Changeset.validate_change(changeset, field, fn ^field, id ->
        case Repo.one(from(p in Prompt, where: p.id == ^id, select: p.purpose)) do
          ^purpose -> []
          nil -> [{field, dgettext_noop("errors", "does not exist")}]
          _other -> [{field, "must be a #{purpose_label(purpose)} prompt"}]
        end
      end)
    end)
  end

  # "must be a side prompt", not "a side prompt prompt".
  defp purpose_label(:side_prompt), do: "side"
  defp purpose_label(purpose), do: purpose |> Atom.to_string() |> String.replace("_", " ")

  ## Counts

  @doc """
  `anchors.memory_counts` for `chat`: how many records of each tier, clips (plain and topical) and
  side-prompt entries its memory book holds, shared copies (`Record.without_shared_copies/1`) not
  counted. All zeros when the chat has no book, or its book is one the chat's owner may not edit (a
  site book under an owner without `"site.content.manage"`).
  """
  @spec counts(Chat.t()) :: %{String.t() => non_neg_integer()}
  def counts(%Chat{id: nil}), do: Anchor.empty_memory_counts()

  def counts(%Chat{id: chat_id}) do
    owner = Repo.one(from(c in Chat, join: u in User, on: u.id == c.user_id, where: c.id == ^chat_id, select: u))
    site? = owner != nil and Scope.can?(Scope.for_user(owner), "site.content.manage")

    from(r in Record,
      join: s in ChatSettings,
      on: s.memory_book_id == r.lore_book_id,
      join: c in Chat,
      on: c.id == s.chat_id,
      join: b in LoreBook,
      on: b.id == r.lore_book_id,
      where: s.chat_id == ^chat_id,
      where: b.user_id == c.user_id or (is_nil(b.user_id) and ^site?),
      group_by: [r.kind, r.tier],
      select: {r.kind, r.tier, count(r.id)}
    )
    |> Record.without_shared_copies()
    |> Repo.all()
    |> Enum.reduce(Anchor.empty_memory_counts(), fn {kind, tier, n}, counts ->
      Map.update!(counts, count_key(kind, tier), &(&1 + n))
    end)
  end

  defp count_key(:memory, _tier), do: "tier0"
  defp count_key(:consolidation, tier), do: "tier#{tier}"
  defp count_key(kind, _tier) when kind in [:clip, :topical_clip], do: "clips"
  defp count_key(:side_prompt, _tier), do: "side_prompts"

  ## Records

  @doc """
  The memory records of a book with their entries (and the entries' memberships, for
  `record_enabled?/1`), by kind, tier, then sequence; `[]` for nil or a book `scope` may not edit.
  """
  @spec list_records(Scope.t(), Ecto.UUID.t() | nil) :: [Record.t()]
  def list_records(%Scope{}, nil), do: []

  def list_records(%Scope{} = scope, book_id) do
    case get_owned(Ownership.editable(LoreBook, scope), book_id) do
      %LoreBook{} ->
        Repo.all(
          from(r in Record,
            where: r.lore_book_id == ^book_id,
            order_by: [asc: r.kind, asc: r.tier, asc: r.sequence, asc: r.inserted_at],
            preload: [entry: :book_entries]
          )
        )

      nil ->
        []
    end
  end

  @doc """
  Whether the record's entry is on in the record's own book, the membership Memory Books switches
  (consolidation, side prompt versions). Reads preloaded `entry.book_entries` when present.
  """
  @spec record_enabled?(Record.t()) :: boolean()
  def record_enabled?(%Record{entry: %LoreEntry{book_entries: memberships}} = record) when is_list(memberships) do
    Enum.any?(memberships, &(&1.lore_book_id == record.lore_book_id and &1.enabled))
  end

  def record_enabled?(%Record{} = record) do
    Repo.exists?(
      from(be in BookEntry,
        where: be.lore_book_id == ^record.lore_book_id and be.lore_entry_id == ^record.lore_entry_id and be.enabled
      )
    )
  end

  @doc "One record with its entry, or nil (also when the scope may not act on its chat)."
  @spec get_record(Scope.t(), Ecto.UUID.t() | nil) :: Record.t() | nil
  def get_record(%Scope{}, nil), do: nil

  def get_record(%Scope{} = scope, id) do
    with %Record{} = record <- Repo.get(Record, id),
         :ok <- Chats.authorize(scope, record.chat_id, :inspect) do
      Repo.preload(record, :entry)
    else
      _ -> nil
    end
  end

  @doc "The records among `ids` with their entries, by id; invalid, missing and not-inspectable ones are absent."
  @spec get_records(Scope.t(), [String.t()]) :: %{Ecto.UUID.t() => Record.t()}
  def get_records(%Scope{} = scope, ids) when is_list(ids) do
    ids = for id <- ids, {:ok, id} <- [Ecto.UUID.cast(id)], do: id
    records = Repo.all(from(r in Record, where: r.id in ^ids, preload: :entry))

    allowed =
      records
      |> Enum.map(& &1.chat_id)
      |> Enum.uniq()
      |> Enum.filter(&(Chats.authorize(scope, &1, :inspect) == :ok))
      |> MapSet.new()

    for r <- records, MapSet.member?(allowed, r.chat_id), into: %{}, do: {r.id, r}
  end

  @doc "The entry names of `record_ids`, keyed by record id; deleted records are absent."
  @spec record_names(Scope.t(), [Ecto.UUID.t()]) :: %{Ecto.UUID.t() => String.t()}
  def record_names(%Scope{}, record_ids) do
    Map.new(
      Repo.all(from(r in Record, join: e in assoc(r, :entry), where: r.id in ^record_ids, select: {r.id, e.name}))
    )
  end

  @doc "The lore books `scope` may edit that hold memory records, by name."
  @spec record_books(Scope.t()) :: [LoreBook.t()]
  def record_books(%Scope{} = scope) do
    from(b in LoreBook,
      where: b.id in subquery(from(r in Record, where: not is_nil(r.lore_book_id), select: r.lore_book_id)),
      order_by: [asc: b.name, asc: b.id]
    )
    |> Ownership.editable(scope)
    |> Repo.all()
  end

  ## Adoption

  @doc """
  Marks existing entries of `book` as scene memories ("adopts" them): each member entry with no
  record yet gets a tier-0 `:memory` record in `book` with no chat and no message range, numbered
  after the book's last memory in ascending entry-name order (so "01 - …" titles number in order).
  Ids that are not members of `book` are ignored; `skipped` counts members that already have a
  record of any kind. A record with no chat is never regenerated (`regenerate/4`).
  """
  @spec mark_as_memories(Scope.t(), LoreBook.t(), [Ecto.UUID.t()]) ::
          {:ok, %{marked: non_neg_integer(), skipped: non_neg_integer()}} | {:error, :unauthorized}
  def mark_as_memories(%Scope{} = scope, %LoreBook{} = book, entry_ids) when is_list(entry_ids) do
    adopt_memories(scope, book, Enum.map(uuids(entry_ids), &%{entry_id: &1, tier: 0, source_entry_ids: []}))
  end

  @doc """
  `mark_as_memories/3` with a tier per entry, for an import that knows it (SillyTavern-MemoryBooks'
  arcs and higher summaries). A tier-0 entry becomes a `:memory`; a higher one a `:consolidation` of
  that tier, numbered after the book's last one of the tier, consolidated from the records of its
  `source_entry_ids` one tier below that are not consolidated yet (each source marked
  `disabled_by_consolidation` when its membership is off). Still no chat and no message range.
  """
  @spec adopt_memories(Scope.t(), LoreBook.t(), [
          %{entry_id: Ecto.UUID.t(), tier: 0..6, source_entry_ids: [Ecto.UUID.t()]}
        ]) :: {:ok, %{marked: non_neg_integer(), skipped: non_neg_integer()}} | {:error, :unauthorized}
  def adopt_memories(%Scope{} = scope, %LoreBook{} = book, adoptions) when is_list(adoptions) do
    scope |> adopt(book, adoptions) |> Changes.notify(:lore, book.user_id)
  end

  defp adopt(scope, book, adoptions) do
    with :ok <- Ownership.authorize_edit(scope, book) do
      by_entry = Map.new(adoptions, &{&1.entry_id, &1})

      # No inner rollback: this may run inside a caller's transaction (an import).
      {:ok, counts} =
        Repo.transaction(fn ->
          members =
            Repo.all(
              from(e in LoreEntry,
                join: be in BookEntry,
                on: be.lore_entry_id == e.id and be.lore_book_id == ^book.id,
                left_join: r in Record,
                on: r.lore_entry_id == e.id,
                where: e.id in ^Map.keys(by_entry),
                order_by: [asc: e.name, asc: e.id],
                select: {e.id, r.id}
              )
            )

          now = DateTime.truncate(DateTime.utc_now(), :second)

          unrecorded = for {entry_id, nil} <- members, do: by_entry[entry_id]

          rows =
            unrecorded
            |> Enum.group_by(& &1.tier)
            |> Enum.flat_map(fn {tier, group} ->
              first = if tier == 0, do: next_sequence(book), else: next_tier_sequence(book, tier)
              for {adoption, sequence} <- Enum.with_index(group, first), do: adopted_row(book, adoption, sequence, now)
            end)

          {marked, _} = Repo.insert_all(Record, rows, on_conflict: :nothing, conflict_target: :lore_entry_id)
          link_adopted_sources(book, rows, by_entry, now)
          %{marked: marked, skipped: length(members) - marked}
        end)

      if counts.marked > 0, do: broadcast_book_changed(book)
      {:ok, counts}
    end
  end

  defp adopted_row(book, %{entry_id: entry_id, tier: tier}, sequence, now) do
    %{
      id: Mythweaver.Schema.generate_id(),
      lore_entry_id: entry_id,
      lore_book_id: book.id,
      chat_id: nil,
      kind: if(tier == 0, do: :memory, else: :consolidation),
      tier: tier,
      sequence: sequence,
      range_start: nil,
      range_end: nil,
      disabled_by_consolidation: false,
      snapshot: %{},
      inserted_at: now,
      updated_at: now
    }
  end

  # Lower tiers first, so an adopted chapter can take adopted arcs as sources.
  defp link_adopted_sources(book, rows, by_entry, now) do
    rows
    |> Enum.filter(&(&1.tier > 0 and by_entry[&1.lore_entry_id].source_entry_ids != []))
    |> Enum.sort_by(& &1.tier)
    |> Enum.each(fn row ->
      sources =
        Repo.all(
          from(r in Record,
            join: be in BookEntry,
            on: be.lore_book_id == r.lore_book_id and be.lore_entry_id == r.lore_entry_id,
            where: r.lore_book_id == ^book.id and r.lore_entry_id in ^by_entry[row.lore_entry_id].source_entry_ids,
            where: r.tier == ^(row.tier - 1) and r.kind in [:memory, :consolidation] and is_nil(r.consolidated_into_id),
            where: r.id != ^row.id,
            order_by: [asc: be.order, asc: r.sequence],
            select: {r.id, be.enabled}
          )
        )

      if sources != [] do
        Repo.insert_all(
          RecordSource,
          for(
            {id, _enabled} <- sources,
            do: %{
              id: Mythweaver.Schema.generate_id(),
              record_id: row.id,
              source_id: id,
              inserted_at: now,
              updated_at: now
            }
          )
        )

        for {enabled?, ids} <- Enum.group_by(sources, &elem(&1, 1), &elem(&1, 0)) do
          Repo.update_all(from(r in Record, where: r.id in ^ids),
            set: [consolidated_into_id: row.id, disabled_by_consolidation: not enabled?, updated_at: now]
          )
        end

        Repo.update_all(from(r in Record, where: r.id == ^row.id),
          set: [snapshot: %{"source_ids" => Enum.map(sources, &elem(&1, 0))}]
        )
      end
    end)
  end

  @doc """
  Writes memory records exported from another instance (`Mythweaver.Import.BundleWriter`). Each
  spec whose entry is a member of `book` and has no record yet gets one `Record` in `book` with the
  spec's fields; a `nil` sequence numbers after the book's last record of that tier, as
  `adopt_memories/3` does. `consolidated_into_entry_id`, `canonical_entry_id` and
  `source_entry_ids` name entries and are wired to the records written here or already on them.
  Returns the number of records written. Runs inside a caller's transaction when there is one.
  """
  @spec import_records(Scope.t(), LoreBook.t(), [map()]) :: {:ok, non_neg_integer()} | {:error, :unauthorized}
  def import_records(%Scope{} = scope, %LoreBook{} = book, specs) when is_list(specs) do
    scope |> write_records(book, specs) |> Changes.notify(:lore, book.user_id)
  end

  defp write_records(scope, book, specs) do
    with :ok <- Ownership.authorize_edit(scope, book) do
      by_entry = Map.new(specs, &{&1.entry_id, &1})

      {:ok, count} =
        Repo.transaction(fn ->
          unrecorded =
            Repo.all(
              from(e in LoreEntry,
                join: be in BookEntry,
                on: be.lore_entry_id == e.id and be.lore_book_id == ^book.id,
                left_join: r in Record,
                on: r.lore_entry_id == e.id,
                where: e.id in ^Map.keys(by_entry) and is_nil(r.id),
                order_by: [asc: e.name, asc: e.id],
                select: e.id
              )
            )

          now = DateTime.truncate(DateTime.utc_now(), :second)

          rows =
            unrecorded
            |> Enum.map(&by_entry[&1])
            |> Enum.group_by(&(&1[:tier] || 0))
            |> Enum.flat_map(fn {tier, group} ->
              {unnumbered, numbered} = Enum.split_with(group, &is_nil(&1[:sequence]))
              next = if tier == 0, do: next_sequence(book), else: next_tier_sequence(book, tier)
              first = Enum.reduce(numbered, next, &max(&1.sequence + 1, &2))
              numbered_rows = Enum.map(numbered, &imported_row(book, &1, &1.sequence, now))

              numbered_rows ++
                for {spec, sequence} <- Enum.with_index(unnumbered, first), do: imported_row(book, spec, sequence, now)
            end)

          {count, _} = Repo.insert_all(Record, rows, on_conflict: :nothing, conflict_target: :lore_entry_id)
          link_imported_records(rows, by_entry, now)
          count
        end)

      if count > 0, do: broadcast_book_changed(book)
      {:ok, count}
    end
  end

  defp imported_row(book, spec, sequence, now) do
    tier = spec[:tier] || 0

    %{
      id: Mythweaver.Schema.generate_id(),
      lore_entry_id: spec.entry_id,
      lore_book_id: book.id,
      chat_id: spec[:chat_id],
      kind: spec[:kind] || if(tier == 0, do: :memory, else: :consolidation),
      tier: tier,
      sequence: sequence,
      range_start: spec[:range_start],
      range_end: spec[:range_end],
      scene_fingerprint: spec[:scene_fingerprint],
      written_fingerprint: spec[:written_fingerprint],
      disabled_by_consolidation: spec[:disabled_by_consolidation] || false,
      version: spec[:version],
      snapshot: spec[:snapshot] || %{},
      profile_id: spec[:profile_id],
      prompt_id: spec[:prompt_id],
      side_prompt_id: spec[:side_prompt_id],
      inserted_at: now,
      updated_at: now
    }
  end

  # Entry ids → record ids for the links: this import's rows plus records already on those entries.
  defp link_imported_records([], _by_entry, _now), do: :ok

  defp link_imported_records(rows, by_entry, now) do
    written = for row <- rows, do: {row, by_entry[row.lore_entry_id]}

    linked =
      written
      |> Enum.flat_map(fn {_row, spec} ->
        [spec[:consolidated_into_entry_id], spec[:canonical_entry_id] | spec[:source_entry_ids] || []]
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    record_ids =
      Map.new(Repo.all(from(r in Record, where: r.lore_entry_id in ^linked, select: {r.lore_entry_id, r.id})))

    Enum.each(written, fn {row, spec} ->
      set =
        [
          consolidated_into_id: record_ids[spec[:consolidated_into_entry_id]],
          canonical_id: record_ids[spec[:canonical_entry_id]]
        ]
        |> Enum.reject(fn {_k, v} -> is_nil(v) or v == row.id end)

      if set != [], do: Repo.update_all(from(r in Record, where: r.id == ^row.id), set: set)
    end)

    written
    |> Enum.flat_map(fn {row, spec} ->
      (spec[:source_entry_ids] || [])
      |> Enum.map(&record_ids[&1])
      |> Enum.reject(&(is_nil(&1) or &1 == row.id))
      |> Enum.uniq()
      |> Enum.map(
        &%{id: Mythweaver.Schema.generate_id(), record_id: row.id, source_id: &1, inserted_at: now, updated_at: now}
      )
    end)
    |> Enum.chunk_every(1000)
    |> Enum.each(&Repo.insert_all(RecordSource, &1))
  end

  @doc """
  Sets `settings`' `highest_processed` (the last message position memory has covered), which no
  changeset casts. For an import restoring a chat's memory progress.
  """
  @spec restore_progress(ChatSettings.t(), integer() | nil) :: :ok
  def restore_progress(%ChatSettings{id: id}, highest_processed) do
    Repo.update_all(from(s in ChatSettings, where: s.id == ^id), set: [highest_processed: highest_processed])
    :ok
  end

  @doc """
  Unmarks memories of `book`: deletes the `:memory` records of `entry_ids` in `book` that are neither
  consolidated into anything nor a source of a consolidation. The lore entries stay. `skipped`
  counts the other entries of `entry_ids` that have a record (kept).
  """
  @spec unmark_memories(Scope.t(), LoreBook.t(), [Ecto.UUID.t()]) ::
          {:ok, %{unmarked: non_neg_integer(), skipped: non_neg_integer()}} | {:error, :unauthorized}
  def unmark_memories(%Scope{} = scope, %LoreBook{} = book, entry_ids) when is_list(entry_ids) do
    scope |> unmark(book, entry_ids) |> Changes.notify(:lore, book.user_id)
  end

  defp unmark(scope, book, entry_ids) do
    with :ok <- Ownership.authorize_edit(scope, book) do
      ids = uuids(entry_ids)

      {:ok, counts} =
        Repo.transaction(fn ->
          recorded = Repo.aggregate(from(r in Record, where: r.lore_entry_id in ^ids), :count)

          {unmarked, _} =
            Repo.delete_all(
              from(r in Record,
                where: r.lore_entry_id in ^ids and r.lore_book_id == ^book.id and r.kind == :memory,
                where: is_nil(r.consolidated_into_id),
                where: r.id not in subquery(from(s in RecordSource, select: s.source_id))
              )
            )

          %{unmarked: unmarked, skipped: recorded - unmarked}
        end)

      if counts.unmarked > 0, do: broadcast_book_changed(book)
      {:ok, counts}
    end
  end

  @doc """
  What each of `entry_ids` is as a memory, for badges: its record's kind, or `{:consolidation, tier}`.
  Entries with no record are absent.
  """
  @spec memory_kinds([Ecto.UUID.t()]) ::
          %{Ecto.UUID.t() => :memory | :clip | :topical_clip | :side_prompt | {:consolidation, 1..6}}
  def memory_kinds(entry_ids) when is_list(entry_ids) do
    ids = uuids(entry_ids)

    from(r in Record, where: r.lore_entry_id in ^ids, select: {r.lore_entry_id, r.kind, r.tier})
    |> Repo.all()
    |> Map.new(fn
      {entry_id, :consolidation, tier} -> {entry_id, {:consolidation, tier}}
      {entry_id, kind, _tier} -> {entry_id, kind}
    end)
  end

  ## The lore entry editor

  @doc """
  The memory side of `entry` (books preloaded) for the lore entry editor:

    * `record`: its record (chat and parent entry preloaded), or nil
    * `book`: the book the record lives in, or for an entry with none the book a new one would
      go in: `preferred_book_id` when the entry is in it, else its first book; nil when that book
      is not one `scope` may edit, or the entry is in no book
    * `source_ids`: a consolidation's source records
    * `candidates`: the memories and consolidations of `book` the record may take as sources (any
      tier; the editor shows the tier below the chosen one): those not consolidated into another
      record. `%{id, name, tier}`, in the book's order.
  """
  @spec entry_memory(Scope.t(), LoreEntry.t(), Ecto.UUID.t() | nil) :: %{
          record: Record.t() | nil,
          book: LoreBook.t() | nil,
          source_ids: [Ecto.UUID.t()],
          candidates: [%{id: Ecto.UUID.t(), name: String.t(), tier: 0..6}]
        }
  def entry_memory(%Scope{} = scope, %LoreEntry{} = entry, preferred_book_id \\ nil) do
    record =
      Repo.one(from(r in Record, where: r.lore_entry_id == ^entry.id, preload: [:chat, consolidated_into: :entry]))

    book_id =
      cond do
        record -> record.lore_book_id
        Enum.any?(entry.books, &(&1.id == preferred_book_id)) -> preferred_book_id
        true -> entry.books |> List.first() |> then(&(&1 && &1.id))
      end

    book = book_id && get_owned(Ownership.editable(LoreBook, scope), book_id)

    %{
      record: record,
      book: book,
      source_ids: if(record, do: source_ids(record.id), else: []),
      candidates: if(book, do: source_candidates(book.id, entry.id, record), else: [])
    }
  end

  defp source_ids(record_id) do
    Repo.all(from(s in RecordSource, where: s.record_id == ^record_id, select: s.source_id))
  end

  defp source_candidates(book_id, entry_id, record) do
    query =
      from(r in Record,
        join: e in assoc(r, :entry),
        join: be in BookEntry,
        on: be.lore_book_id == r.lore_book_id and be.lore_entry_id == r.lore_entry_id,
        where: r.lore_book_id == ^book_id and r.kind in [:memory, :consolidation] and r.lore_entry_id != ^entry_id,
        order_by: [asc: r.tier, asc: be.order, asc_nulls_last: r.range_start, asc: r.sequence],
        select: %{id: r.id, name: e.name, tier: r.tier}
      )

    query =
      case record do
        %Record{id: id} -> where(query, [r], is_nil(r.consolidated_into_id) or r.consolidated_into_id == ^id)
        nil -> where(query, [r], is_nil(r.consolidated_into_id))
      end

    query |> Record.without_shared_copies() |> Repo.all()
  end

  @doc """
  Sets what `entry` is as a memory of `book`, from the lore entry editor. `attrs`:

    * `:tier`: nil (not a memory: its record is deleted), 0 (a scene memory) or 1..6 (a
      consolidation of that tier)
    * `:sequence`: its number within the book and tier; nil keeps the current one, or numbers a
      new record (or one moved to another tier) after the tier's last
    * `:source_ids`: a consolidation's sources, which are records of `book` one tier below not
      consolidated into another record (others are ignored)

  A source dropped (or every source, when the record leaves its tier or stops being a memory) is
  released: no longer consolidated, and switched back on in its book if the consolidation switched
  it off. A new record has no chat and no message range; an existing one keeps its own.

  Errors: `:unauthorized` (a book `scope` may not edit, or the record lives in another book);
  `:managed` (a clip, topical clip or side prompt entry, which only its job writes); `:consolidated`
  (the record is a source of another and the edit would change its tier or remove it).
  """
  @spec set_entry_memory(Scope.t(), LoreEntry.t(), LoreBook.t(), map()) ::
          {:ok, Record.t() | nil} | {:error, :unauthorized | :managed | :consolidated}
  def set_entry_memory(%Scope{} = scope, %LoreEntry{} = entry, %LoreBook{} = book, attrs) do
    scope |> write_entry_memory_for(entry, book, attrs) |> Changes.notify(:lore, book.user_id)
  end

  defp write_entry_memory_for(scope, entry, book, attrs) do
    with :ok <- Ownership.authorize_edit(scope, book) do
      result =
        Repo.transaction(fn ->
          record = Repo.one(from(r in Record, where: r.lore_entry_id == ^entry.id, lock: "FOR UPDATE"))

          case write_entry_memory(record, entry, book, attrs) do
            {:ok, record} -> record
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      with {:ok, _record} <- result, do: broadcast_book_changed(book)
      result
    end
  end

  defp write_entry_memory(%Record{lore_book_id: other}, _entry, %LoreBook{id: book_id}, _attrs) when other != book_id,
    do: {:error, :unauthorized}

  defp write_entry_memory(%Record{kind: kind}, _entry, _book, _attrs) when kind not in [:memory, :consolidation],
    do: {:error, :managed}

  defp write_entry_memory(nil, _entry, _book, %{tier: nil}), do: {:ok, nil}

  defp write_entry_memory(%Record{consolidated_into_id: parent, tier: tier}, _entry, _book, %{tier: new_tier})
       when is_binary(parent) and new_tier != tier, do: {:error, :consolidated}

  defp write_entry_memory(%Record{} = record, _entry, _book, %{tier: nil}) do
    release_sources(record, [])
    Repo.delete!(record)
    {:ok, nil}
  end

  defp write_entry_memory(record, entry, book, %{tier: tier} = attrs) do
    sequence =
      cond do
        is_integer(attrs[:sequence]) and attrs[:sequence] > 0 -> attrs[:sequence]
        record && record.tier == tier -> record.sequence
        tier == 0 -> next_sequence(book)
        true -> next_tier_sequence(book, tier)
      end

    changes = %{kind: if(tier == 0, do: :memory, else: :consolidation), tier: tier, sequence: sequence}

    record =
      case record do
        nil ->
          Repo.insert!(
            Record.changeset(%Record{}, Map.merge(changes, %{lore_entry_id: entry.id, lore_book_id: book.id}))
          )

        record ->
          record |> Record.changeset(changes) |> Repo.update!()
      end

    wanted = if tier == 0, do: [], else: wanted_sources(book, record, tier, attrs[:source_ids] || [])
    release_sources(record, wanted)
    {:ok, link_sources(record, wanted)}
  end

  # Records of `book` one tier below `record`'s, free or already its own, in the order given; shared
  # copies follow their canonical instead.
  defp wanted_sources(book, record, tier, ids) do
    ids = uuids(ids)

    found =
      from(r in Record,
        where: r.id in ^ids and r.lore_book_id == ^book.id and r.tier == ^(tier - 1) and r.id != ^record.id,
        where: r.kind in [:memory, :consolidation],
        where: is_nil(r.consolidated_into_id) or r.consolidated_into_id == ^record.id,
        select: r.id
      )
      |> Record.without_shared_copies()
      |> Repo.all()

    Enum.filter(ids, &(&1 in found))
  end

  # Every source of `record` not in `keep` (and its shared copies) stops being one; those its
  # consolidation switched off are switched back on.
  defp release_sources(record, keep) do
    keep = keep ++ shared_copy_ids(keep)

    released =
      Repo.all(from(r in Record, where: r.consolidated_into_id == ^record.id and r.id not in ^keep))

    released
    |> Enum.filter(& &1.disabled_by_consolidation)
    |> Enum.map(&{&1.lore_book_id, &1.lore_entry_id})
    |> Lore.set_memberships_enabled(true)

    ids = Enum.map(released, & &1.id)

    Repo.update_all(from(r in Record, where: r.id in ^ids),
      set: [consolidated_into_id: nil, disabled_by_consolidation: false]
    )

    Repo.delete_all(from(s in RecordSource, where: s.record_id == ^record.id and s.source_id not in ^keep))
  end

  defp link_sources(record, []),
    do: Repo.update!(Record.changeset(record, %{snapshot: Map.delete(record.snapshot, "source_ids")}))

  defp link_sources(record, ids) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    Repo.insert_all(
      RecordSource,
      for(
        id <- ids,
        do: %{
          id: Mythweaver.Schema.generate_id(),
          record_id: record.id,
          source_id: id,
          inserted_at: now,
          updated_at: now
        }
      ),
      on_conflict: :nothing,
      conflict_target: [:record_id, :source_id]
    )

    Repo.update_all(from(r in Record, where: r.id in ^(ids ++ shared_copy_ids(ids)) and is_nil(r.consolidated_into_id)),
      set: [consolidated_into_id: record.id]
    )

    # Kept sources keep the order a regeneration reads them in; new ones follow.
    previous = Enum.filter(record.snapshot["source_ids"] || [], &(&1 in ids))
    ordered = previous ++ Enum.reject(ids, &(&1 in previous))
    record |> Record.changeset(%{snapshot: Map.put(record.snapshot, "source_ids", ordered)}) |> Repo.update!()
  end

  defp shared_copy_ids([]), do: []
  defp shared_copy_ids(ids), do: ids |> Record.shared_copies() |> select([r], r.id) |> Repo.all()

  # Open memory panels of every chat writing into `book` refresh.
  defp broadcast_book_changed(%LoreBook{id: book_id}) do
    from(s in ChatSettings, where: s.memory_book_id == ^book_id, select: s.chat_id)
    |> Repo.all()
    |> Enum.each(&broadcast_changed/1)
  end

  @doc false
  def uuids(ids), do: for(id <- ids, {:ok, uuid} <- [Ecto.UUID.cast(id)], uniq: true, do: uuid)

  ## Scene memories

  @doc """
  The profile's memory prompt for a scene with `speaker_count` non-player speakers: the group memory
  prompt (when set) at two or more, else the memory prompt. `{:error, :no_prompt}` when unset,
  missing or not a memory prompt.
  """
  @spec memory_prompt(Scope.t(), Profile.t(), non_neg_integer()) :: {:ok, Prompt.t()} | {:error, :no_prompt}
  def memory_prompt(%Scope{} = scope, %Profile{} = profile, speaker_count \\ 1) do
    id =
      if speaker_count >= 2,
        do: profile.group_memory_prompt_id || profile.memory_prompt_id,
        else: profile.memory_prompt_id

    purpose_prompt(scope, id, :memory)
  end

  @doc """
  The next unprocessed scene, as `{first, last}` positions: the first message after
  `highest_processed` (or the first message) through the last one. `:none` when nothing is left.
  """
  @spec next_range(Scope.t(), Chat.t()) :: {integer(), integer()} | :none
  def next_range(%Scope{} = scope, %Chat{} = chat) do
    floor = chat_settings(scope, chat).highest_processed || -1

    case unprocessed_range(chat.id, floor) do
      {first, last} when is_integer(first) -> {first, last}
      _nothing -> :none
    end
  end

  # `{first, last}`: the first transcript position after `floor` and the last one, each nil when none.
  @doc false
  def unprocessed_range(chat_id, floor) do
    Repo.one(
      from(m in Message,
        where: m.chat_id == ^chat_id and m.draft == false,
        select: {min(fragment("CASE WHEN ? > ? THEN ? END", m.position, ^floor, m.position)), max(m.position)}
      )
    )
  end

  @doc "Sets (or with nil clears) the chat's processed-message boundary."
  @spec set_highest_processed(Scope.t(), Chat.t(), integer() | nil) :: {:ok, ChatSettings.t()} | {:error, :unauthorized}
  def set_highest_processed(%Scope{} = scope, %Chat{} = chat, position) when is_integer(position) or is_nil(position) do
    with :ok <- Chats.authorize(scope, chat, :manage) do
      {:ok, settings} = chat |> settings_row() |> Ecto.Changeset.change(highest_processed: position) |> Repo.update()
      broadcast_changed(chat.id)
      {:ok, settings}
    end
  end

  @doc """
  The position the chat's boundary divider renders after: `highest_processed` while the preferences
  show a divider, else nil. Reads without creating the chat's settings row.
  """
  @spec boundary_position(Scope.t(), Chat.t()) :: integer() | nil
  def boundary_position(%Scope{} = scope, %Chat{id: chat_id} = chat) do
    if Chats.authorize(scope, chat, :inspect) == :ok and preferences(scope).boundary_indicator == :divider,
      do: Repo.one(from(s in ChatSettings, where: s.chat_id == ^chat_id, select: s.highest_processed))
  end

  @doc """
  Queues a memory of the messages at positions `first..last`.

  `opts`: `:origin` (default `:interactive`), `:previous_count` (default the preferences'),
  `:confirm_tokens` (skip the token warning), `:review` (default `prefs.show_previews`), `:batch_id`,
  `:participant_ids` (character ids that replace the detected speakers and the chat's present cast;
  nil or `[]` detects), and `:record_id`/`:entry_updated_at` to regenerate an existing memory.
  Without `:participant_ids`, the chat's present cast (`ChatSettings.cast_ids`) joins the detected
  speakers, and that list is the job's participants.

  `{:confirm, tokens}` asks an interactive caller to confirm a prompt over the token warning.
  `{:error, :invalid_participants}` when a participant id is not a participant of the chat.
  """
  @spec create_memory(Scope.t(), Chat.t(), integer(), integer(), keyword()) ::
          {:ok, Job.t()}
          | {:confirm, non_neg_integer()}
          | {:error,
             :no_profile
             | :no_model
             | :ambiguous_model
             | :no_prompt
             | :empty_scene
             | :overlap
             | :invalid_participants
             | :unauthorized}
  def create_memory(%Scope{} = scope, %Chat{} = chat, first, last, opts \\ []) do
    prefs = preferences(scope)
    origin = Keyword.get(opts, :origin, :interactive)
    previous_count = Keyword.get(opts, :previous_count, prefs.default_previous_count)

    with :ok <- Chats.authorize(scope, chat, :manage),
         scope = Chats.run_scope(scope, chat),
         {:ok, participant_ids} <- participant_ids(chat, opts[:participant_ids]),
         {:ok, profile} <- profile_for(scope, chat),
         {:ok, model} <- model_for(scope, chat, profile),
         {:ok, messages} <- scene_messages(scope, chat, first, last, prefs),
         participant_ids = with_cast(scope, chat, messages, participant_ids),
         {:ok, prompt} <- memory_prompt(scope, profile, length(Scene.speakers(chat, messages, participant_ids))),
         :ok <- check_overlap(chat, first, last, prefs, opts[:record_id]),
         :ok <-
           check_tokens(origin == :interactive and !opts[:confirm_tokens], model, prefs, fn ->
             Workers.Scene.input(scope, chat, profile, prompt, model, messages,
               previous_count: previous_count,
               participant_ids: participant_ids
             )
           end) do
      params =
        %{
          "chat_id" => chat.id,
          "start" => first,
          "end" => last,
          "profile_id" => profile.id,
          "previous_count" => previous_count,
          "review" => Keyword.get(opts, :review, prefs.show_previews),
          "skip_side_prompts" => false,
          "scene_fingerprint" => Scene.fingerprint(messages),
          "batch_id" => opts[:batch_id],
          "participant_ids" => participant_ids,
          "record_id" => opts[:record_id],
          "entry_updated_at" => opts[:entry_updated_at] && DateTime.to_iso8601(opts[:entry_updated_at])
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      Jobs.enqueue(scope, :memory, %{
        origin: origin,
        chat_id: chat.id,
        label: memory_job_label(scope, origin, first, last),
        ai_model_id: model.id,
        params: params,
        range_start: first,
        range_end: last
      })
    end
  end

  defp scene_messages(scope, chat, first, last, prefs) do
    case Scene.messages(scope, chat, first, last, prefs) do
      [] -> {:error, :empty_scene}
      messages -> {:ok, messages}
    end
  end

  defp participant_ids(_chat, ids) when ids in [nil, []], do: {:ok, nil}

  defp participant_ids(chat, ids) when is_list(ids) do
    members = MapSet.new(chat.participants, & &1.character_id)
    if Enum.all?(ids, &MapSet.member?(members, &1)), do: {:ok, Enum.uniq(ids)}, else: {:error, :invalid_participants}
  end

  defp participant_ids(_chat, _ids), do: {:error, :invalid_participants}

  # The chat's present cast joins the detected speakers (speakers first), among the chat's
  # non-player participants; an explicit participant list replaces both.
  defp with_cast(scope, chat, messages, nil) do
    bots = MapSet.new(Chat.bots(chat), & &1.character_id)

    with [_ | _] = cast_ids <- chat_settings(scope, chat).cast_ids,
         [_ | _] = ids <-
           Enum.filter(Enum.uniq(Scene.speakers(chat, messages, nil) ++ cast_ids), &MapSet.member?(bots, &1)) do
      ids
    else
      [] -> nil
    end
  end

  defp with_cast(_scope, _chat, _messages, participant_ids), do: participant_ids

  defp check_overlap(_chat, _first, _last, %{allow_overlap: true}, _record_id), do: :ok

  defp check_overlap(chat, first, last, _prefs, record_id) do
    query =
      from(r in Record,
        where: r.chat_id == ^chat.id and r.kind == :memory and is_nil(r.canonical_id),
        where: r.range_start <= ^last and r.range_end >= ^first
      )

    query = if record_id, do: where(query, [r], r.id != ^record_id), else: query
    if Repo.exists?(query), do: {:error, :overlap}, else: :ok
  end

  # Only an interactive, unconfirmed request is sized: rendering the prompt twice is the cost.
  defp check_tokens(false, _model, _prefs, _input_fun), do: :ok

  defp check_tokens(true, model, prefs, input_fun) do
    tokens = Request.tokens(model, input_fun.())
    if tokens > prefs.token_warning_threshold, do: {:confirm, tokens}, else: :ok
  end

  @doc """
  Queues memories over `first..last` in consecutive chunks of `chunk` messages (5..250), saved
  directly, in order. The chunks share a `batch_id`: the first failure cancels the rest.
  """
  @spec catch_up(Scope.t(), Chat.t(), integer(), integer(), pos_integer()) ::
          {:ok, [Job.t()]} | {:error, :invalid_chunk | :empty_scene | :overlap | :unauthorized | term()}
  def catch_up(%Scope{} = scope, %Chat{} = chat, first, last, chunk) when is_integer(chunk) and chunk in 5..250 do
    with :ok <- Chats.authorize(scope, chat, :manage), do: do_catch_up(scope, chat, first, last, chunk)
  end

  def catch_up(%Scope{}, %Chat{}, _first, _last, _chunk), do: {:error, :invalid_chunk}

  defp do_catch_up(scope, chat, first, last, chunk) do
    prefs = preferences(scope)

    chunks =
      from(m in Message,
        where: m.chat_id == ^chat.id and m.draft == false and m.position >= ^first and m.position <= ^last,
        order_by: [asc: m.position],
        select: m.position
      )
      |> Repo.all()
      |> Enum.chunk_every(chunk)
      |> Enum.map(&{hd(&1), List.last(&1)})

    cond do
      chunks == [] ->
        {:error, :empty_scene}

      Enum.any?(chunks, fn {a, b} -> check_overlap(chat, a, b, prefs, nil) != :ok end) ->
        {:error, :overlap}

      true ->
        batch_id = Ecto.UUID.generate()

        collect_ok(chunks, fn {a, b} ->
          create_memory(scope, chat, a, b, origin: :background, review: false, batch_id: batch_id)
        end)
    end
  end

  # `fun` over `items` in order: `{:ok, results}`, or the first result that is not `{:ok, _}` (the
  # jobs queued before it stay queued).
  @doc false
  def collect_ok(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, results} ->
      case fun.(item) do
        {:ok, result} -> {:cont, {:ok, [result | results]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  @doc """
  The chat's memory book: the settings' book when the chat's owner may edit it (its own, or a site
  book for an admin), else a new `"<chat> Memories"` book owned by the chat's owner (numbered on a
  name collision among that owner's books), bound to the chat and stored in the settings. `scope` is
  the owner (`chat_settings/2` admits only the owner).
  """
  @spec ensure_book(Scope.t(), Chat.t()) :: LoreBook.t()
  def ensure_book(%Scope{} = scope, %Chat{} = chat) do
    settings = chat_settings(scope, chat)
    owner_id = owner_of(chat)

    case settings.memory_book_id && Repo.get(Ownership.editable(LoreBook, scope), settings.memory_book_id) do
      %LoreBook{} = book ->
        book

      nil ->
        name = free_book_name(owner_id, "#{Chat.title(chat)} Memories")
        {:ok, book} = Lore.create_chat_book(scope, %{chat | user_id: owner_id}, %{name: name})
        {:ok, _} = settings |> Ecto.Changeset.change(memory_book_id: book.id) |> Repo.update()
        book
    end
  end

  # Checked up front: a failed insert would abort an enclosing transaction.
  defp free_book_name(owner_id, base) do
    taken =
      from(b in LoreBook, where: like(b.name, ^"#{base}%"), select: b.name)
      |> Ownership.owned_exactly(owner_id)
      |> Repo.all()
      |> MapSet.new()

    [base]
    |> Stream.concat(Stream.map(Stream.iterate(2, &(&1 + 1)), &"#{base} #{&1}"))
    |> Enum.find(&(not MapSet.member?(taken, &1)))
  end

  @doc """
  Saves a scene memory's `draft` (`"title"`, `"content"`, `"keywords"`) for a `:memory` job, in one
  transaction: the entry in the chat's book, its record, the boundary and auto-hide.

  Every save is refused with `{:error, :changed}` when the scene's messages changed since the job was
  queued. A regeneration (`params["record_id"]`) rewrites only the entry's name, content and
  keywords, and is also refused with `{:error, :changed}` when the entry changed, with
  `{:error, :consolidated}` when something consolidated it, and with `{:error, :unauthorized}`
  unless the record is this chat's, in a book `scope` may edit. `opts`: `ignore_changes: true` saves
  over a changed scene or entry anyway (the person said so); the record then carries the scene as it
  is now.

  A new memory also goes to the character memory book (`CharacterBooks.character_book/3`) of each non-player
  character in it (every non-player character when none spoke): one copy per distinct book, filtered
  to its characters and linked to the chat's memory by `canonical_id`. The chat's own book may be
  one; its copy is a second entry there with the memory's sequence (`Record`'s shared copies).
  Without the profile's character memory prompt the copies are verbatim and written in the same
  transaction; with it, each book gets a background `:memory` job (`params["copy"]`:
  `"canonical_id"`, `"book_id"`, `"character_ids"`) that rewrites the scene from those characters'
  perspective and saves here. A copy's save moves no boundary, hides nothing and runs no side
  prompts; it is refused with `{:error, :changed}` once the chat's memory is gone or the scene
  changed.

  A regeneration writes no new copies but refreshes the existing ones in books `scope` may edit and
  not yet consolidated: verbatim copies are rewritten in the same transaction; perspective copies get
  a copy job each, whose `params["copy"]["record_id"]` names the copy it rewrites in place (refused
  with `{:error, :changed}` once that copy is gone).
  """
  @spec save_scene(Scope.t(), Job.t(), map(), keyword()) :: {:ok, Record.t()} | {:error, term()}
  def save_scene(%Scope{} = scope, %Job{params: params} = job, draft, opts \\ []) do
    with {:ok, draft} <- JSON.memory(draft),
         %Chat{} = chat <- Chats.get_chat(params["chat_id"]) || {:error, :no_chat},
         :ok <- Chats.authorize(scope, chat, :manage),
         scope = Chats.run_scope(scope, chat),
         %Profile{} = profile <- get_profile(scope, params["profile_id"]) || {:error, :no_profile} do
      if params["copy"],
        do: save_copy(scope, job, chat, profile, draft),
        else: save_memory(scope, job, chat, profile, draft, Keyword.get(opts, :ignore_changes, false))
    end
    |> invalid_changeset()
  end

  # A changeset refused inside a save surfaces as `{:error, :invalid}`.
  @doc false
  def invalid_changeset({:error, %Ecto.Changeset{}}), do: {:error, :invalid}
  def invalid_changeset(result), do: result

  defp save_memory(scope, %Job{params: params} = job, chat, profile, draft, ignore_changes?) do
    with {:ok, {record, book, hide_ids, message_ids, copies}} <-
           Jobs.complete_in_transaction(job, fn ->
             {record, _book, _hide_ids, _message_ids, _copies} =
               value = save_scene_tx(scope, job, chat, profile, draft, preferences(scope), ignore_changes?)

             {value, %{"record_id" => record.id}}
           end) do
      Messages.set_visible_many(chat, hide_ids, false)
      broadcast_changed(chat.id)
      if !params["skip_side_prompts"], do: SidePrompts.after_memory(scope, chat, record, job, message_ids)
      if is_nil(params["record_id"]), do: Clips.enqueue_assistance(scope, chat, record, message_ids, job.id)
      Consolidation.check_ready(scope, book)
      Enum.each(copies, &after_copy(scope, chat, job, record, &1, message_ids))
      {:ok, record}
    end
  end

  defp save_copy(scope, %Job{params: %{"copy" => copy} = params} = job, chat, profile, draft) do
    with {:ok, {record, book, canonical}} <-
           Jobs.complete_in_transaction(job, fn ->
             {record, _book, _canonical} = value = save_copy_tx(scope, job, chat, profile, draft)
             {value, %{"record_id" => record.id}}
           end) do
      broadcast_changed(chat.id)

      # A refresh adds nothing to its book; a shared copy's book is the canonical's, already followed up.
      if is_nil(copy["record_id"]) and book.id != canonical.lore_book_id do
        Consolidation.check_ready(scope, book)
        Clips.enqueue_assistance(scope, chat, record, params["message_ids"], job.id)
      end

      {:ok, record}
    end
  end

  # A verbatim copy, already written, runs its book's follow-ups (a shared copy's are the canonical's);
  # a perspective copy, new or refreshed, is queued.
  defp after_copy(_scope, _chat, _job, %Record{lore_book_id: book_id}, {:written, %LoreBook{id: book_id}, _copy}, _ids),
    do: :ok

  defp after_copy(scope, chat, job, _record, {:written, book, %Record{} = copy}, message_ids) do
    Consolidation.check_ready(scope, book)
    Clips.enqueue_assistance(scope, chat, copy, message_ids, job.id)
  end

  defp after_copy(scope, chat, %Job{params: params} = job, record, {:queue, book, character_ids, copy_id}, message_ids) do
    names = character_ids |> Enum.map(&Chat.participant_name(chat, &1)) |> Enum.reject(&is_nil/1)
    copy = %{"canonical_id" => record.id, "book_id" => book.id, "character_ids" => character_ids}

    # The canonical's fingerprint, not the job's: after a save over a changed scene they differ, and
    # the copy summarizes the messages as saved.
    copy_params =
      params
      |> Map.take(~w(chat_id start end profile_id previous_count participant_ids))
      |> Map.merge(%{
        "review" => false,
        "scene_fingerprint" => record.scene_fingerprint,
        "message_ids" => message_ids,
        "copy" => if(copy_id, do: Map.put(copy, "record_id", copy_id), else: copy)
      })

    case Jobs.enqueue(scope, :memory, %{
           origin: :background,
           chat_id: chat.id,
           label: copy_job_label(scope, record, names),
           ai_model_id: job.ai_model_id,
           params: copy_params,
           range_start: record.range_start,
           range_end: record.range_end,
           parent_id: job.id
         }) do
      {:ok, _job} -> :ok
      error -> Logger.warning("Character memory copy for chat #{chat.id} not queued: #{inspect(error)}")
    end
  end

  defp save_scene_tx(scope, job, chat, profile, draft, prefs, ignore_changes?) do
    %{"start" => first, "end" => last} = params = job.params
    book = ensure_book(scope, chat)
    messages = Scene.messages(scope, chat, first, last, prefs)
    # The draft summarizes the messages as queued; a changed scene would be saved over text the model
    # never saw, unless the person chose to.
    if !ignore_changes? and Scene.fingerprint(messages) != params["scene_fingerprint"], do: Repo.rollback(:changed)
    existing = regenerated_record(scope, chat, :memory, params)
    if existing, do: check_unchanged!(existing, params, ignore_changes?)
    sequence = if existing, do: existing.sequence, else: next_sequence(book)
    participant_ids = params["participant_ids"]
    speakers = Scene.speakers(chat, messages, participant_ids)

    prompt = scope |> memory_prompt(profile, length(speakers)) |> Repo.ok_or_rollback()

    vars = title_vars(chat, profile, draft, first, last, messages, participant_ids)

    content_attrs = %{
      name: Title.format(profile.title_format, Map.put(vars, :sequence, sequence)),
      content: draft["content"],
      keywords: draft["keywords"]
    }

    entry = write_entry(scope, existing, book, profile, content_attrs, sequence, speakers)

    # The participant correction is kept so a regeneration summarizes with the same cast.
    snapshot_attrs =
      if is_list(participant_ids) and participant_ids != [],
        do: %{snapshot: %{"participant_ids" => participant_ids}},
        else: %{}

    record =
      (existing || %Record{})
      |> Record.changeset(
        Map.merge(snapshot_attrs, %{
          lore_entry_id: entry.id,
          lore_book_id: book.id,
          chat_id: chat.id,
          kind: :memory,
          tier: 0,
          sequence: sequence,
          range_start: first,
          range_end: last,
          scene_fingerprint: Scene.fingerprint(messages),
          written_fingerprint: Scene.sha256(entry.content),
          profile_id: profile.id,
          prompt_id: prompt.id
        })
      )
      |> Repo.insert_or_update()
      |> Repo.ok_or_rollback()

    settings = settings_row(chat)

    {:ok, settings} =
      settings
      |> Ecto.Changeset.change(highest_processed: max(settings.highest_processed || -1, last))
      |> Repo.update()

    copies =
      if existing,
        do: refresh_copies(scope, profile, record, content_attrs, vars),
        else: write_copies(scope, chat, profile, record, content_attrs, vars, speakers)

    {record, book, hide_ids(chat, settings, first, last), Enum.map(messages, & &1.id), copies}
  end

  # `Title.format/2`'s variables for a scene memory, all but `sequence`, which is per book.
  defp title_vars(chat, profile, draft, first, last, messages, participant_ids) do
    %{
      title: draft["title"],
      scene: "##{first + 1}–##{last + 1}",
      char: chat |> Chat.bots() |> Enum.map_join(", ", &(&1.character && &1.character.name)),
      chat: Chat.title(chat),
      present: chat |> Scene.speaker_names(messages, participant_ids) |> Enum.join(", "),
      user: (chat.player_character && chat.player_character.name) || "",
      messages: length(messages),
      profile: profile.name
    }
  end

  # Per character book of `speakers`: `{:written, book, copy}` for a verbatim copy, or
  # `{:queue, book, character_ids, nil}` for a perspective job to write after the commit.
  defp write_copies(scope, chat, profile, canonical, content_attrs, vars, speakers) do
    for {target, character_ids} <- copy_targets(scope, chat, speakers) do
      if is_nil(profile.character_memory_prompt_id),
        do:
          {:written, target,
           write_copy!(scope, canonical, target, profile, content_attrs, vars, character_ids, canonical.prompt_id)},
        else: {:queue, target, character_ids, nil}
    end
  end

  # Each distinct character book of the non-player `speakers` (every non-player character when none
  # spoke) with its characters, in speaking order. The chat's own book counts like any other.
  defp copy_targets(scope, chat, speakers) do
    character_ids =
      case speakers -- [chat.player_character_id] do
        [] -> Enum.map(Chat.bots(chat), & &1.character_id)
        ids -> ids
      end

    books = CharacterBooks.character_books(scope, chat, character_ids)
    pairs = for id <- character_ids, %LoreBook{} = target <- [books[id]], do: {target, id}

    pairs
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq_by(& &1.id)
    |> Enum.map(fn target -> {target, for({%{id: id}, character_id} <- pairs, id == target.id, do: character_id)} end)
  end

  # A regenerated `canonical`'s copies in books `scope` may edit, not consolidated: verbatim ones
  # rewritten from `content_attrs` now; perspective ones `{:queue, book, character_ids, copy_id}`.
  defp refresh_copies(scope, profile, canonical, content_attrs, vars) do
    copies =
      Repo.all(
        from(r in Record,
          where: r.canonical_id == ^canonical.id,
          order_by: [asc: r.inserted_at],
          preload: [:book, entry: :entry_characters]
        )
      )

    book_ids = Enum.map(copies, & &1.lore_book_id)
    editable = Repo.all(from(b in Ownership.editable(LoreBook, scope), where: b.id in ^book_ids, select: b.id))

    Enum.flat_map(copies, fn copy ->
      cond do
        copy.lore_book_id not in editable ->
          Logger.debug("Copy #{copy.id} of memory #{canonical.id} not refreshed: its book is not editable")
          []

        copy.consolidated_into_id ->
          Logger.debug("Copy #{copy.id} of memory #{canonical.id} not refreshed: it is consolidated")
          []

        is_nil(profile.character_memory_prompt_id) ->
          rewrite_copy!(scope, copy, canonical, profile, content_attrs, vars, canonical.prompt_id)
          []

        true ->
          character_ids = Enum.map(copy.entry.entry_characters, & &1.character_id)
          [{:queue, copy.book, character_ids, copy.id}]
      end
    end)
  end

  # A character's copy of `canonical` in `book`: its own entry, always filtered to `character_ids`,
  # numbered in that book; a shared copy (in the canonical's own book) takes the canonical's sequence.
  defp write_copy!(scope, canonical, book, profile, content_attrs, vars, character_ids, prompt_id) do
    sequence = if book.id == canonical.lore_book_id, do: canonical.sequence, else: next_sequence(book)
    attrs = %{content_attrs | name: Title.format(profile.title_format, Map.put(vars, :sequence, sequence))}
    entry = write_entry(scope, nil, book, profile, attrs, sequence, character_ids, force_filter: true)

    %Record{}
    |> Record.changeset(
      Map.merge(copy_attrs(canonical, entry, prompt_id), %{
        lore_entry_id: entry.id,
        lore_book_id: book.id,
        sequence: sequence
      })
    )
    |> Repo.insert()
    |> Repo.ok_or_rollback()
  end

  # Rewrites `copy`'s entry (keeping its sequence and character filter) and record from `canonical`.
  defp rewrite_copy!(scope, copy, canonical, profile, content_attrs, vars, prompt_id) do
    attrs = %{content_attrs | name: Title.format(profile.title_format, Map.put(vars, :sequence, copy.sequence))}
    entry = Gate.unmoderated(fn -> Lore.update_entry(scope, copy.entry, attrs) end) |> Repo.ok_or_rollback()

    copy
    |> Record.changeset(copy_attrs(canonical, entry, prompt_id))
    |> Repo.update()
    |> Repo.ok_or_rollback()
  end

  defp copy_attrs(canonical, entry, prompt_id) do
    %{
      chat_id: canonical.chat_id,
      kind: :memory,
      tier: 0,
      range_start: canonical.range_start,
      range_end: canonical.range_end,
      scene_fingerprint: canonical.scene_fingerprint,
      written_fingerprint: Scene.sha256(entry.content),
      profile_id: canonical.profile_id,
      prompt_id: prompt_id,
      snapshot: canonical.snapshot,
      canonical_id: canonical.id
    }
  end

  # A perspective copy: the job's draft in its character book, while the chat's memory still exists
  # and the scene is as it was when the copy was queued. With `copy["record_id"]` it rewrites that
  # copy in place. `{copy, book, canonical}`.
  defp save_copy_tx(scope, %Job{params: %{"copy" => copy} = params}, chat, profile, draft) do
    %{"start" => first, "end" => last} = params
    book = Repo.get(Ownership.editable(LoreBook, scope), copy["book_id"]) || Repo.rollback(:unauthorized)
    canonical = Repo.get(Record, copy["canonical_id"]) || Repo.rollback(:changed)
    messages = Scene.listed(scope, chat, first, last, params["message_ids"] || [])
    if Scene.fingerprint(messages) != params["scene_fingerprint"], do: Repo.rollback(:changed)

    prompt = scope |> character_memory_prompt(profile) |> Repo.ok_or_rollback()

    vars = title_vars(chat, profile, draft, first, last, messages, params["participant_ids"])
    content_attrs = %{name: nil, content: draft["content"], keywords: draft["keywords"]}

    record =
      case copy["record_id"] do
        nil ->
          write_copy!(scope, canonical, book, profile, content_attrs, vars, copy["character_ids"], prompt.id)

        id ->
          existing = refreshed_copy!(id, canonical, book)
          rewrite_copy!(scope, existing, canonical, profile, content_attrs, vars, prompt.id)
      end

    {record, book, canonical}
  end

  defp refreshed_copy!(id, canonical, book) do
    query =
      from(r in Record,
        where: r.id == ^id and r.canonical_id == ^canonical.id and r.lore_book_id == ^book.id,
        lock: "FOR UPDATE",
        preload: :entry
      )

    Repo.one(query) || Repo.rollback(:changed)
  end

  # A regeneration rewrites only a `kind` record of this chat, in a book `scope` may edit.
  @doc false
  def regenerated_record(scope, chat, kind, %{"record_id" => id}) when is_binary(id) do
    case Repo.one(from(r in Record, where: r.id == ^id and r.kind == ^kind)) do
      nil ->
        Repo.rollback(:changed)

      record ->
        if regenerable(scope, chat, record) != :ok, do: Repo.rollback(:unauthorized)
        Repo.preload(record, :entry)
    end
  end

  def regenerated_record(_scope, _chat, _kind, _params), do: nil

  # A consolidated memory is never rewritten; an entry edited since the job was queued only when the
  # person chose to save anyway.
  defp check_unchanged!(existing, params, ignore_changes?) do
    if existing.consolidated_into_id, do: Repo.rollback(:consolidated)

    if !ignore_changes? and DateTime.to_iso8601(existing.entry.updated_at) != params["entry_updated_at"],
      do: Repo.rollback(:changed)
  end

  defp next_sequence(book) do
    (Repo.one(from(r in Record, where: r.lore_book_id == ^book.id and r.kind == :memory, select: max(r.sequence))) || 0) +
      1
  end

  # `force_filter: true` filters a new entry to `speakers` whatever the profile's `character_aware`.
  @doc false
  def write_entry(scope, existing, book, profile, content_attrs, sequence, speakers, opts \\ [])

  def write_entry(scope, %Record{entry: entry}, _book, _profile, content_attrs, _sequence, _speakers, _opts) do
    Gate.unmoderated(fn -> Lore.update_entry(scope, entry, content_attrs) end) |> Repo.ok_or_rollback()
  end

  def write_entry(scope, nil, book, profile, content_attrs, sequence, speakers, opts) do
    filter? = (opts[:force_filter] || profile.character_aware) and speakers != []

    attrs =
      Map.merge(content_attrs, %{
        activation: profile.activation,
        outlet: profile.outlet,
        placement: profile.placement,
        custom_outlet: profile.custom_outlet,
        depth: profile.depth,
        prevent_recursion: profile.prevent_recursion,
        exclude_recursion: profile.exclude_recursion,
        character_filter_mode: if(filter?, do: :include, else: :off)
      })

    order = if(profile.order_mode == :auto, do: sequence, else: profile.order)

    entry =
      Gate.unmoderated(fn -> Lore.create_entry(scope, attrs, [book.id], %{order: order}) end) |> Repo.ok_or_rollback()

    if filter?, do: Lore.set_entry_filter_characters(scope, entry, speakers) |> Repo.ok_or_rollback()
    entry
  end

  # Auto-hide: `:all` hides every visible message through the scene, `:last` only the scene; the
  # newest `leave_unhidden` candidates stay visible either way.
  defp hide_ids(_chat, %ChatSettings{auto_hide: :none}, _first, _last), do: []

  defp hide_ids(chat, settings, first, last) do
    floor = if settings.auto_hide != :all, do: first

    from(m in Message,
      where: m.chat_id == ^chat.id and m.draft == false and m.visible_to_ai and m.position <= ^last,
      order_by: [asc: m.position],
      select: m.id
    )
    |> then(&if(floor, do: where(&1, [m], m.position >= ^floor), else: &1))
    |> Repo.all()
    |> Enum.drop(-settings.leave_unhidden)
  end

  ## Purpose prompts and tier sequences

  @doc "The `:compaction` prompt `id`: `{:error, :no_prompt}` when missing or of another purpose."
  @spec compaction_prompt(Scope.t(), Ecto.UUID.t() | nil) :: {:ok, Prompt.t()} | {:error, :no_prompt}
  def compaction_prompt(%Scope{} = scope, id), do: purpose_prompt(scope, id, :compaction)

  # The prompt `id` when it is one of `purpose`; `{:error, :no_prompt}` when unset, missing or another purpose.
  @doc false
  def purpose_prompt(%Scope{} = scope, id, purpose) do
    case id && Prompts.get_prompt(scope, id) do
      %Prompt{purpose: ^purpose} = prompt -> {:ok, prompt}
      _missing -> {:error, :no_prompt}
    end
  end

  @doc false
  def next_tier_sequence(book, tier) do
    (Repo.one(
       from(r in Record,
         where: r.lore_book_id == ^book.id and r.kind == :consolidation and r.tier == ^tier,
         select: max(r.sequence)
       )
     ) || 0) + 1
  end

  ## Compaction

  @doc """
  Queues a compaction of `record`'s entry, always reviewed: the draft replaces the entry's content
  only if the entry is unchanged when approved.
  """
  @spec compact(Scope.t(), Chat.t(), Record.t()) ::
          {:ok, Job.t()} | {:error, :no_profile | :no_model | :ambiguous_model | :no_prompt | :unauthorized}
  def compact(%Scope{} = scope, %Chat{} = chat, %Record{} = record) do
    record = Repo.preload(record, :entry)

    with :ok <- Chats.authorize(scope, chat, :manage),
         scope = Chats.run_scope(scope, chat),
         {:ok, profile} <- profile_for(scope, chat),
         {:ok, model} <- model_for(scope, chat, profile),
         {:ok, prompt} <- compaction_prompt(scope, profile.compaction_prompt_id) do
      Jobs.enqueue(scope, :compaction, %{
        origin: :interactive,
        chat_id: chat.id,
        label:
          dpgettext("memory", "heading: job that compacts a lore entry", "Compact %{entry_name}",
            entry_name: record.entry.name
          ),
        ai_model_id: model.id,
        range_start: record.range_start,
        range_end: record.range_end,
        params: %{
          "chat_id" => chat.id,
          "profile_id" => profile.id,
          "prompt_id" => prompt.id,
          "record_id" => record.id,
          "review" => true,
          "entry_updated_at" => DateTime.to_iso8601(record.entry.updated_at),
          "entry_fingerprint" => Scene.sha256(record.entry.content)
        }
      })
    end
  end

  @doc """
  Queues a compaction of unsaved entry text with no chat (the lore entry editor). Not reviewed: the
  job completes with `%{"content" => text}` in its result, and nothing is saved.
  `attrs`: `:title`, `:content`, `:kind` (the anchor's `entry.kind`, default `"lore"`).
  """
  @spec compact_text(Scope.t(), map()) ::
          {:ok, Job.t()} | {:error, :empty | :no_profile | :no_model | :ambiguous_model | :no_prompt}
  def compact_text(%Scope{} = scope, attrs) do
    title =
      case non_blank(attrs[:title]) do
        {:ok, title} -> title
        {:error, :invalid} -> nil
      end

    with {:ok, content} <- non_blank_content(attrs[:content]),
         %Profile{} = profile <- default_profile(scope) || {:error, :no_profile},
         {:ok, model} <- profile_model(scope, profile),
         {:ok, prompt} <- compaction_prompt(scope, profile.compaction_prompt_id) do
      Jobs.enqueue(scope, :compaction, %{
        origin: :interactive,
        chat_id: nil,
        label:
          if(title,
            do:
              dpgettext("memory", "heading: job that compacts a lore entry", "Compact %{entry_name}", entry_name: title),
            else: dpgettext("memory", "heading: job that compacts an untitled entry", "Compact entry")
          ),
        ai_model_id: model.id,
        params: %{
          "profile_id" => profile.id,
          "prompt_id" => prompt.id,
          "title" => title,
          "content" => content,
          "kind" => attrs[:kind] || "lore"
        }
      })
    end
  end

  defp non_blank_content(text) do
    with {:error, :invalid} <- non_blank(text), do: {:error, :empty}
  end

  # `model_for/3` with no chat: the profile's model, else `AI.default_model/1`.
  defp profile_model(scope, profile) do
    case profile.ai_model_id && AI.get_model(scope, profile.ai_model_id) do
      %Model{} = model -> {:ok, model}
      _unset -> AI.default_model(scope)
    end
  end

  @doc "Saves a `:compaction` job's `content` over its record's entry, when the entry is unchanged."
  @spec save_compaction(Scope.t(), Job.t(), String.t() | nil) :: {:ok, Record.t()} | {:error, term()}
  def save_compaction(%Scope{} = scope, %Job{params: params} = job, content) do
    with {:ok, content} <- non_blank(content),
         :ok <- Chats.authorize(scope, job.chat_id, :manage),
         scope = Chats.run_scope(scope, job.chat_id),
         {:ok, record} <-
           Jobs.complete_in_transaction(job, fn ->
             record = Repo.get(Record, params["record_id"]) || Repo.rollback(:changed)
             record = Repo.preload(record, :entry)
             if !entry_unchanged?(record.entry, params), do: Repo.rollback(:changed)
             record = rewrite_content!(scope, record, content)
             {record, Map.put(job.result || %{}, "record_id", record.id)}
           end) do
      broadcast_changed(job.chat_id)
      {:ok, record}
    end
  end

  @doc false
  def non_blank(text) when is_binary(text) do
    case String.trim(text) do
      "" -> {:error, :invalid}
      text -> {:ok, text}
    end
  end

  def non_blank(_text), do: {:error, :invalid}

  # Whether `entry` is as it was when the job was queued (`entry_updated_at`, `entry_fingerprint`).
  @doc false
  def entry_unchanged?(entry, params) do
    DateTime.to_iso8601(entry.updated_at) == params["entry_updated_at"] and
      Scene.sha256(entry.content) == params["entry_fingerprint"]
  end

  # The `kind` record `id` with its entry, locked for the transaction; rolls back with `reason` when gone.
  @doc false
  def lock_record!(id, kind, reason) do
    case Repo.one(from(r in Record, where: r.id == ^id and r.kind == ^kind, lock: "FOR UPDATE")) do
      nil -> Repo.rollback(reason)
      record -> Repo.preload(record, :entry)
    end
  end

  # Replaces `record`'s entry content and records what was written.
  @doc false
  def rewrite_content!(scope, record, content) do
    entry =
      Gate.unmoderated(fn -> Lore.update_entry(scope, record.entry, %{content: content}) end) |> Repo.ok_or_rollback()

    record |> Ecto.Changeset.change(written_fingerprint: Scene.sha256(entry.content)) |> Repo.update!()
  end

  @doc """
  The profile's character-memory prompt (a `:memory` prompt) for perspective copies in character
  books; `{:error, :no_prompt}` when unset (verbatim copies), missing or of another purpose.
  """
  @spec character_memory_prompt(Scope.t(), Profile.t()) :: {:ok, Prompt.t()} | {:error, :no_prompt}
  def character_memory_prompt(%Scope{} = scope, %Profile{character_memory_prompt_id: id}),
    do: purpose_prompt(scope, id, :memory)

  ## Regeneration

  @doc """
  Queues a fresh, reviewed draft for `record`:

    * a memory re-summarizes its range; refused once consolidated, or when no messages remain; a
      character's copy (`canonical_id`) is refused with `{:error, :copy}`: regenerate the chat's memory
    * a consolidation re-summarizes exactly its sources; refused once itself consolidated, or when
      a source is gone

    * a side prompt's entry is rerun over its snapshot range; refused once the entry was edited
      since the side prompt wrote it (`:changed`), or when the side prompt is gone

  `opts`: `:confirm_tokens` (default false) skips a memory's token warning, which otherwise returns
  `{:confirm, tokens}`; the other kinds ignore it. Clips and topical clips are not regenerated here.

  `{:error, :unauthorized}` unless `record` belongs to `chat` and lives in a book `scope` may edit;
  the save checks both again.
  """
  @spec regenerate(Scope.t(), Chat.t(), Record.t(), keyword()) ::
          {:ok, Job.t()} | {:confirm, non_neg_integer()} | {:error, term()}
  def regenerate(%Scope{} = scope, %Chat{} = chat, %Record{} = record, opts \\ []) do
    with :ok <- Chats.authorize(scope, chat, :manage),
         :ok <- regenerable(scope, chat, record),
         do: do_regenerate(Chats.run_scope(scope, chat), chat, record, opts)
  end

  # A record of another chat (even in a book the scope may edit) is not this chat's to rewrite.
  defp regenerable(scope, %Chat{id: chat_id}, %Record{chat_id: chat_id} = record) when is_binary(chat_id),
    do: authorize_book(scope, record.lore_book_id)

  defp regenerable(_scope, _chat, _record), do: {:error, :unauthorized}

  defp do_regenerate(_scope, _chat, %Record{kind: :memory, canonical_id: canonical_id}, _opts)
       when is_binary(canonical_id), do: {:error, :copy}

  defp do_regenerate(_scope, _chat, %Record{kind: kind, consolidated_into_id: parent}, _opts)
       when kind in [:memory, :consolidation] and is_binary(parent), do: {:error, :consolidated}

  defp do_regenerate(scope, chat, %Record{kind: :memory} = record, opts) do
    record = Repo.preload(record, :entry)
    prefs = preferences(scope)

    case Scene.messages(scope, chat, record.range_start, record.range_end, prefs) do
      [] ->
        {:error, :source_missing}

      _messages ->
        create_memory(scope, chat, record.range_start, record.range_end,
          record_id: record.id,
          review: true,
          confirm_tokens: Keyword.get(opts, :confirm_tokens, false),
          participant_ids: record.snapshot["participant_ids"],
          previous_count: prefs.default_previous_count,
          entry_updated_at: record.entry.updated_at
        )
    end
  end

  defp do_regenerate(scope, chat, %Record{kind: :consolidation} = record, _opts) do
    ids = record.snapshot["source_ids"] || []

    sources =
      Repo.all(
        from(r in Record,
          where: r.id in ^ids and r.consolidated_into_id == ^record.id and r.tier == ^(record.tier - 1),
          preload: :entry
        )
      )

    with :ok <- if(ids != [] and length(sources) == length(ids), do: :ok, else: {:error, :source_missing}),
         %LoreBook{} = book <- Repo.get(LoreBook, record.lore_book_id) || {:error, :source_missing},
         {:ok, profile} <- profile_for(scope, chat),
         {:ok, model} <- model_for(scope, chat, profile),
         {:ok, prompt} <-
           Consolidation.consolidation_prompt(scope, record.prompt_id || profile.consolidation_prompt_id) do
      by_id = Map.new(sources, &{&1.id, &1})
      attrs = %{"record_id" => record.id, "disable_sources" => false, "review" => true}

      Consolidation.enqueue_consolidation(
        scope,
        chat,
        book,
        profile,
        {model, prompt},
        record.tier,
        Enum.map(ids, &by_id[&1]),
        attrs
      )
    end
  end

  defp do_regenerate(scope, chat, %Record{kind: :side_prompt} = record, _opts) do
    case record.side_prompt_id && get_side_prompt(scope, record.side_prompt_id) do
      %SidePrompt{} = side_prompt -> SidePrompts.run(scope, chat, side_prompt, record_id: record.id, review: true)
      nil -> {:error, :source_missing}
    end
  end

  defp do_regenerate(_scope, _chat, %Record{}, _opts), do: {:error, :not_regenerable}

  ## Review

  @doc """
  Commits a `:review` job's `edited` draft. On an error the job stays in review and the error is
  returned for the UI.

    * `:memory`: `%{"title", "content", "keywords"}`; `opts` `ignore_changes: true` saves it even
      though its scene or regenerated entry changed since the job was queued (`save_scene/4`)
    * `:consolidation`: `%{"candidates" => …}`, a list or an index-keyed map of
      `%{"keep", "title", "summary", "keywords"}` laid over the job's candidates (sources always come
      from the job); candidates whose `"keep"` is false are dropped
    * `:compaction`, `:topical_clip` and `:side_prompt`: `%{"content"}`

  An index-keyed map (consolidation or assistance candidates, assistance topics) whose key is not a
  non-negative integer (or `"new"`, for topics) is `{:error, :invalid}`.
  """
  @spec approve(Scope.t(), Job.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def approve(%Scope{} = scope, %Job{} = job, edited, opts \\ []) do
    with :ok <- Jobs.authorize(scope, job), do: do_approve(scope, job, edited, opts)
  end

  defp do_approve(scope, %Job{tag: :memory, status: :review} = job, edited, opts),
    do: save_scene(scope, job, edited, opts)

  defp do_approve(scope, %Job{tag: :consolidation, status: :review} = job, edited, _opts) do
    with {:ok, kept} <- kept_candidates(job.result, edited),
         do: Consolidation.save_consolidation(scope, job, kept, job.result["unassigned"] || [])
  end

  defp do_approve(scope, %Job{tag: :compaction, status: :review} = job, edited, _opts),
    do: save_compaction(scope, job, edited["content"])

  defp do_approve(scope, %Job{tag: :topical_clip, status: :review} = job, edited, _opts),
    do: Clips.save_topical_clip(scope, job, edited["content"])

  defp do_approve(scope, %Job{tag: :memory_assistance, status: :review} = job, edited, _opts),
    do: Clips.approve_assistance(scope, job, edited)

  defp do_approve(scope, %Job{tag: :side_prompt, status: :review} = job, edited, _opts),
    do: SidePrompts.save_side_prompt(scope, job, edited["content"])

  defp do_approve(_scope, %Job{}, _edited, _opts), do: {:error, :not_in_review}

  defp kept_candidates(%{"candidates" => candidates}, edited) do
    with {:ok, edits} <- edited_candidates(edited["candidates"]) do
      kept =
        for {candidate, i} <- Enum.with_index(candidates),
            edit <- [Map.get(edits, i, %{})],
            edit["keep"] not in [false, "false"],
            do: Map.merge(candidate, Map.take(edit, ["title", "summary", "keywords"]))

      {:ok, kept}
    end
  end

  # Form params key candidates by index; a key that is not a non-negative integer is `{:error, :invalid}`.
  @doc false
  def edited_candidates(list) when is_list(list),
    do: {:ok, list |> Enum.with_index() |> Map.new(fn {c, i} -> {i, c} end)}

  def edited_candidates(%{} = map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, candidate}, {:ok, acc} ->
      case form_index(key) do
        {:ok, i} -> {:cont, {:ok, Map.put(acc, i, candidate)}}
        :error -> {:halt, {:error, :invalid}}
      end
    end)
  end

  def edited_candidates(_none), do: {:ok, %{}}

  @doc false
  def form_index(key) when is_integer(key) and key >= 0, do: {:ok, key}

  def form_index(key) when is_binary(key) do
    case Integer.parse(key) do
      {i, ""} when i >= 0 -> {:ok, i}
      _ -> :error
    end
  end

  def form_index(_key), do: :error

  @doc "Throws away a `:review` job's draft: the job ends `:canceled`, \"Discarded.\""
  @spec discard(Scope.t(), Job.t()) :: {:ok, Job.t()} | {:error, :not_found | :unauthorized}
  def discard(%Scope{} = scope, %Job{} = job) do
    with :ok <- Jobs.authorize(scope, job),
         do:
           Jobs.resolve_review(job.id, :canceled, %{
             error: dpgettext("memory", "status: memory draft the user discarded", "Discarded.")
           })
  end

  @doc """
  Parses a hand-corrected reply for a failed `:memory`/`:consolidation` job and reopens the job for
  review with it, so it is approved through the same checks as any draft.
  """
  @spec correct(Scope.t(), Job.t(), String.t()) ::
          {:ok, Job.t()} | {:error, :unparseable | :invalid | :not_correctable | :not_found | :unauthorized}
  def correct(%Scope{} = scope, %Job{} = job, text) do
    with :ok <- Jobs.authorize(scope, job), do: do_correct(job, text)
  end

  defp do_correct(%Job{tag: :memory, status: :failed} = job, text) do
    with {:ok, map} <- JSON.decode(text),
         {:ok, draft} <- JSON.memory(map),
         do: Jobs.reopen_for_review(job.id, draft, text)
  end

  defp do_correct(%Job{tag: :consolidation, status: :failed} = job, text) do
    with {:ok, map} <- JSON.decode(text),
         {:ok, reply} <- JSON.consolidation(map),
         {:ok, result} <- Workers.Consolidation.result(job.params, reply),
         do: Jobs.reopen_for_review(job.id, result, text)
  end

  defp do_correct(%Job{}, _text), do: {:error, :not_correctable}

  ## Job labels (shown in the UI; background ones in the scope user's locale)

  defp memory_job_label(scope, :background, first, last),
    do: Mythweaver.Locale.with_user_locale(scope, fn -> memory_job_label(scope, :interactive, first, last) end)

  defp memory_job_label(_scope, _origin, first, last) do
    dpgettext(
      "memory",
      "heading: job that writes a memory of a message range",
      "Memory #%{first_message_number}–#%{last_message_number}",
      first_message_number: Format.number(first + 1),
      last_message_number: Format.number(last + 1)
    )
  end

  defp copy_job_label(scope, record, names) do
    Mythweaver.Locale.with_user_locale(scope, fn ->
      gettext_comment("%{character_names} is a list of character names.")

      dpgettext(
        "memory",
        "heading: job that copies a memory of a message range to other characters",
        "Memory #%{first_message_number}–#%{last_message_number} for %{character_names}",
        first_message_number: Format.number(record.range_start + 1),
        last_message_number: Format.number(record.range_end + 1),
        character_names: Format.list(names)
      )
    end)
  end
end
