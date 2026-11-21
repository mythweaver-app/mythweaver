defmodule Mythweaver.Accounts.UserData do
  @moduledoc """
  A moderator's index of one user's data (`"moderation.content.view"`): their chats and their own
  characters, lore books, prompts, scripts and AI connections. Each is read and deleted through
  `Mythweaver.Moderation.Lookup`; this module only lists them, and moves a lore book to the site
  (`move_book_to_site/3`: `"moderation.content.delete"`, `"site.content.manage"` and sudo mode
  (`Mythweaver.Accounts.sudo?/1`), acting as the owner). Nobody but an owner may open another
  owner's data.
  """

  import Ecto.Query

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.AI
  alias Mythweaver.Changes
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Lore
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Lore.Transfer
  alias Mythweaver.Ownership
  alias Mythweaver.Prompts.Prompt
  alias Mythweaver.Repo
  alias Mythweaver.Scripts.Script

  @doc "`:ok` when `actor` may open `user`'s data."
  @spec authorize(Scope.t(), User.t()) :: :ok | {:error, :unauthorized}
  def authorize(%Scope{} = actor, %User{} = user) do
    if Scope.can?(actor, "moderation.content.view") and (Scope.owner?(actor) or user.role != :owner),
      do: :ok,
      else: {:error, :unauthorized}
  end

  @doc "`user`'s chats, most recently updated first; `[]` when `actor` may not see them."
  @spec chats(Scope.t(), User.t()) :: [Chat.t()]
  def chats(%Scope{} = actor, %User{} = user) do
    if authorize(actor, user) == :ok,
      do: Repo.all(from(c in Chat, where: c.user_id == ^user.id, order_by: [desc: c.updated_at])),
      else: []
  end

  @doc "`user`'s own content by kind, each by name; empty lists when `actor` may not see it."
  @spec content(Scope.t(), User.t()) :: %{
          characters: [Character.t()],
          lore_books: [LoreBook.t()],
          prompts: [Prompt.t()],
          scripts: [Script.t()],
          ai_providers: [AI.Provider.t()]
        }
  def content(%Scope{} = actor, %User{} = user) do
    allowed? = authorize(actor, user) == :ok

    Map.new(
      [characters: Character, lore_books: LoreBook, prompts: Prompt, scripts: Script, ai_providers: AI.Provider],
      fn {key, schema} ->
        rows = if allowed?, do: schema |> Ownership.owned_exactly(user.id) |> order_by(:name) |> Repo.all(), else: []
        {key, rows}
      end
    )
  end

  @doc """
  Moves one of `user`'s lore books to the site (`Mythweaver.Lore.Transfer`). When `user` cannot edit
  site books, their own memory settings, locks and topic suggestions naming it are cleared too.
  """
  @spec move_book_to_site(Scope.t(), User.t(), String.t()) :: {:ok, LoreBook.t()} | {:error, term()}
  def move_book_to_site(%Scope{} = actor, %User{} = user, book_id) do
    with :ok <- authorize(actor, user),
         :ok <- Scope.authorize(actor, "moderation.content.delete"),
         :ok <- Scope.authorize(actor, "site.content.manage"),
         :ok <- Accounts.authorize_sudo(actor) do
      owner = Scope.for_user(user)

      with {:ok, id} <- Ecto.UUID.cast(book_id),
           %LoreBook{user_id: uid} = book when uid == user.id <- Lore.get_editable_book(owner, id) do
        clear = if not Scope.can?(owner, "site.content.manage"), do: user.id
        book |> Transfer.run(clear_memory_of: clear) |> Changes.notify(:lore, [nil, user.id])
      else
        _ -> {:error, :not_found}
      end
    end
  end
end
