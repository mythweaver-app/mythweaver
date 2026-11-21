defmodule Mythweaver.Characters do
  @moduledoc """
  The Characters context.

  Characters are owned content (`Mythweaver.Ownership`): a site character (`user_id` nil) is usable by
  everyone and edited by admins; a user's own is seen, used and edited only by them. Reads for pickers
  and chats return usable characters, the editor lists editable ones; writes need edit rights.

  Favorites are per user (`Mythweaver.Characters.Favorite`): the list functions put the scope user's
  favorites first.
  """

  import Ecto.Query, warn: false

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.Changes
  alias Mythweaver.Characters.Character
  alias Mythweaver.Characters.Favorite
  alias Mythweaver.Expressions.Sprite
  alias Mythweaver.Moderation.Gate
  alias Mythweaver.Moderation.Hold
  alias Mythweaver.Ownership
  alias Mythweaver.Permissions.Quota
  alias Mythweaver.Repo

  @doc """
  Characters `scope` may use (its own plus the site's): pickers, scripts, the palette. The scope
  user's favorites first, then by name.
  """
  @spec list_characters(Scope.t()) :: [Character.t()]
  def list_characters(%Scope{} = scope), do: Character |> Ownership.usable(scope) |> ordered(scope) |> Repo.all()

  @doc """
  Characters `scope` may edit (its own, plus the site's for an admin): the character editor. The
  scope user's favorites first, then by name.
  """
  @spec list_editable_characters(Scope.t()) :: [Character.t()]
  def list_editable_characters(%Scope{} = scope),
    do: Character |> Ownership.editable(scope) |> ordered(scope) |> Repo.all()

  # The scope user's favorites first, each group by name.
  defp ordered(query, %Scope{user: %User{id: uid}}) do
    query
    |> join(:left, [c], f in Favorite, as: :favorite, on: f.character_id == c.id and f.user_id == ^uid)
    |> order_by([c, favorite: f], asc: is_nil(f.id), asc: c.name, asc: c.id)
    |> select_merge([favorite: f], %{favorite: not is_nil(f.id)})
  end

  defp ordered(query, %Scope{}), do: order_by(query, [c], asc: c.name, asc: c.id)

  @doc "`{name, id}` select options for every character `scope` may use, or for a list of characters."
  def character_options(%Scope{} = scope), do: character_options(list_characters(scope))
  def character_options(characters) when is_list(characters), do: Enum.map(characters, &{&1.name, &1.id})

  @doc "Unscoped system lookup for non-request code."
  def get_character!(id), do: Repo.get!(Character, id)

  @doc "A character `scope` may use; raises otherwise."
  def get_character!(%Scope{} = scope, id), do: Character |> Ownership.usable(scope) |> Repo.get!(id)

  @doc "A character `scope` may use, or nil."
  def get_character(%Scope{} = scope, id), do: Character |> Ownership.usable(scope) |> Repo.get(id)

  @doc "A character `scope` may edit, or nil."
  def get_editable_character(%Scope{} = scope, id), do: Character |> Ownership.editable(scope) |> Repo.get(id)

  @doc "Whether `character` is one of `scope`'s user's favorites (never, for a scope with no user)."
  @spec favorite?(Scope.t(), Character.t()) :: boolean()
  def favorite?(%Scope{user: %User{id: uid}}, %Character{id: id}),
    do: Repo.exists?(from(f in Favorite, where: f.user_id == ^uid and f.character_id == ^id))

  def favorite?(%Scope{}, %Character{}), do: false

  @doc """
  Stars (`true`) or unstars (`false`) `character` for `scope`'s user: any character they may use
  (`Ownership.usable?/2`). Idempotent. Tells only that user's own `:characters` topic.
  """
  @spec set_favorite(Scope.t(), Character.t(), boolean()) :: :ok | {:error, :unauthorized | :not_found}
  def set_favorite(%Scope{user: %User{id: uid}} = scope, %Character{} = character, favorite?)
      when is_boolean(favorite?) do
    if Ownership.usable?(scope, character),
      do: uid |> write_favorite(character.id, favorite?) |> Changes.notify_own(:characters, uid),
      else: {:error, :unauthorized}
  end

  def set_favorite(%Scope{}, %Character{}, _favorite?), do: {:error, :unauthorized}

  defp write_favorite(uid, id, true) do
    %Favorite{user_id: uid, character_id: id}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.foreign_key_constraint(:character_id)
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :character_id])
    |> case do
      {:ok, _favorite} -> :ok
      {:error, _changeset} -> {:error, :not_found}
    end
  end

  defp write_favorite(uid, id, false) do
    Repo.delete_all(from(f in Favorite, where: f.user_id == ^uid and f.character_id == ^id))
    :ok
  end

  @doc """
  Whether a chat owned by `owner_id` (nil: an unowned chat) may use the character `character_id`:
  it is the site's or that owner's. A missing character is not usable.
  """
  @spec usable_by?(Ecto.UUID.t() | nil, Ecto.UUID.t()) :: boolean()
  def usable_by?(owner_id, character_id) do
    Character |> Ownership.for_owner(owner_id) |> where([c], c.id == ^character_id) |> Repo.exists?()
  end

  @doc """
  The first character usable by `scope` named `name`, ignoring case and surrounding spaces, or `nil`.
  The scope user's own character wins over a site one; among equal names the oldest wins (ids are
  time-ordered UUID v7).
  """
  @spec find_character_by_name(Scope.t(), String.t()) :: Character.t() | nil
  def find_character_by_name(%Scope{} = scope, name) when is_binary(name),
    do: first_usable(scope, dynamic([c], fragment("lower(?) = lower(?)", c.name, ^String.trim(name))))

  @doc """
  The character a SillyTavern character filter's `wanted` (a card file name, `.png` optional) names
  for `scope`: the usable one imported from that file (`source_file`), else `find_character_by_name/2`.
  Ranked like `find_character_by_name/2`.
  """
  @spec find_character_for_filter(Scope.t(), String.t()) :: Character.t() | nil
  def find_character_for_filter(%Scope{} = scope, wanted) when is_binary(wanted) do
    stem = wanted |> String.trim() |> String.replace_suffix(".png", "")
    first_usable(scope, dynamic([c], c.source_file == ^stem)) || find_character_by_name(scope, stem)
  end

  # The scope user's own match before a site one, then the oldest.
  defp first_usable(scope, condition) do
    Repo.one(
      from(c in Ownership.usable(Character, scope),
        where: ^condition,
        order_by: ^[asc: Ownership.owner_rank(scope.user && scope.user.id), asc: dynamic([c], c.id)],
        limit: 1
      )
    )
  end

  @doc "Loads the character's avatar attachment (`nil` when it has none), reloading a loaded one."
  def preload_avatar(%Scope{}, %Character{} = character), do: Repo.preload(character, :avatar, force: true)

  @doc """
  Creates a character owned per `Ownership.new_owner/3`: `scope`'s own, or the site's with
  `site: true`. `import: true` also casts the import-only fields (`Character.import_changeset/2`).
  Content moderation may hold it instead (`Mythweaver.Moderation.Gate.run/5`); `followups:` run
  after an approved hold saves.
  """
  @spec create_character(Scope.t(), map(), keyword()) ::
          {:ok, Character.t()}
          | {:held, Hold.t()}
          | {:error, Ecto.Changeset.t() | :unauthorized | :quota_exceeded | :hold_limit}
  def create_character(%Scope{} = scope, attrs \\ %{}, opts \\ []) do
    {followups, opts} = Keyword.pop(opts, :followups, [])

    with {:ok, owner} <- Ownership.new_owner(scope, Character, opts),
         :ok <- Quota.check_new_row(scope, owner, "quota.characters", Character) do
      changeset = character_changeset(%Character{user_id: owner}, attrs, opts)

      scope
      |> Gate.run(changeset, {__MODULE__, :create_character, [attrs, opts]}, [followups: followups], fn ->
        Repo.insert(changeset)
      end)
      |> Changes.notify(:characters)
    end
  end

  @doc "Updates a character `scope` may edit; `import: true` as for `create_character/3`. May be held."
  @spec update_character(Scope.t(), Character.t(), map(), keyword()) ::
          {:ok, Character.t()} | {:held, Hold.t()} | {:error, Ecto.Changeset.t() | :unauthorized | :hold_limit}
  def update_character(%Scope{} = scope, %Character{} = character, attrs, opts \\ []) do
    with :ok <- Ownership.authorize_edit(scope, character) do
      changeset = character_changeset(character, attrs, opts)

      scope
      |> Gate.run(changeset, {__MODULE__, :update_character, [{:row, Character, character.id}, attrs, opts]}, [], fn ->
        Repo.update(changeset)
      end)
      |> Changes.notify(:characters)
    end
  end

  defp character_changeset(character, attrs, opts) do
    if Keyword.get(opts, :import, false),
      do: Character.import_changeset(character, attrs),
      else: Character.changeset(character, attrs)
  end

  @doc """
  Deletes `character` (its owner or a site-content manager only). Fails with `:in_use` while it is in
  a chat of its owner; its shares end first, which takes it out of its editors' chats. With accepted
  editors it is given to `opts[:to]` or the oldest of them instead (`Mythweaver.Sharing.hand_off_or/4`),
  in use or not.
  """
  @spec delete_character(Scope.t(), Character.t(), keyword()) ::
          {:ok, Character.t() | {:handed_off, User.t()}}
          | {:error, :in_use | :unauthorized}
  def delete_character(%Scope{} = scope, %Character{} = character, opts \\ []) do
    with :ok <- Ownership.authorize_delete(scope, character) do
      Mythweaver.Sharing.hand_off_or(scope, character, opts, fn ->
        with :ok <- if(Mythweaver.Chats.character_in_owner_chats?(character), do: {:error, :in_use}, else: :ok),
             :ok <- Mythweaver.Sharing.revoke_all(:character, character.id, :deleted),
             do: character |> do_delete_character() |> Changes.notify(:characters)
      end)
    end
  end

  defp do_delete_character(character) do
    sprite_files =
      Repo.all(from(s in Sprite, where: s.character_id == ^character.id, select: s.attachment_id))

    Repo.transaction(fn ->
      if Mythweaver.Chats.character_in_chat?(character) do
        Repo.rollback(:in_use)
      else
        Mythweaver.Messages.detach_character(character)
        Repo.delete!(character)
      end
    end)
    |> tap(fn result -> if match?({:ok, _}, result), do: Mythweaver.Attachments.delete_orphaned(sprite_files) end)
  end

  def change_character(%Character{} = character, attrs \\ %{}) do
    Character.changeset(character, attrs)
  end
end
