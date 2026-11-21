defmodule Mythweaver.Prompts do
  @moduledoc """
  The Prompts context: reusable prompt blocks, the prompts that order them, the bindings that decide
  which prompt wins where, and the custom outlets lore entries can target.

  A prompt block is first-class and shared: it belongs to any number of prompts, and each membership
  (`Prompts.PromptBlock`) carries its own `position` and `enabled` flag, the same split
  `Mythweaver.Lore` uses for shared lore entries.

  `resolve_prompt/1` is the load-bearing function: it picks the winning prompt by CSS-like specificity,
  so the user binds a prompt at whatever level is meaningful and the most specific match applies.

  ## Ownership (`Mythweaver.Ownership`, permission `"content.prompts.create"`)

  Prompts, blocks and outlets are site rows (`user_id` nil, edited by site content managers, usable by everyone) or a
  user's own (only that user sees, edits or uses them). Editors list `list_editable_*`; pickers and the
  `get_*` functions chats use return usable rows (own plus site). A prompt includes only site blocks or
  its owner's, and binds only to targets (connection, model, character, chat) that are site rows or its
  owner's. At runtime everything resolves for the *chat owner*: `resolve_prompt/1` considers only the
  site's prompts and the chat owner's, and an outlet key resolves to the owner's outlet before the site's.
  """

  import Ecto.Query, warn: false

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.AI.Model
  alias Mythweaver.AI.Provider
  alias Mythweaver.Changes
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Moderation.Gate
  alias Mythweaver.Moderation.Hold
  alias Mythweaver.Ownership
  alias Mythweaver.Permissions.Quota
  alias Mythweaver.Prompts.Binding
  alias Mythweaver.Prompts.Block
  alias Mythweaver.Prompts.Outlet
  alias Mythweaver.Prompts.Prompt
  alias Mythweaver.Prompts.PromptBlock
  alias Mythweaver.Repo
  alias Mythweaver.Sharing.Clone

  ## Blocks

  @doc "Whether `scope` may create prompts, blocks and outlets (a site content manager, or a user with `\"content.prompts.create\"`)."
  def can_create?(scope), do: Ownership.can_create?(scope, Prompt)

  @doc "Blocks `scope` may use (own plus site), by name."
  def list_blocks(%Scope{} = scope), do: Block |> Ownership.usable(scope) |> blocks_by_name()

  @doc "Blocks `scope` may edit (own, plus site for an admin), by name."
  def list_editable_blocks(%Scope{} = scope), do: Block |> Ownership.editable(scope) |> blocks_by_name()

  defp blocks_by_name(query), do: Repo.all(from(b in query, order_by: [asc: b.name, asc: b.id]))

  @doc "A block `scope` may use, or nil."
  def get_block(%Scope{} = scope, id), do: Block |> Ownership.usable(scope) |> get_preloaded(id, [:prompts])

  @doc "A block `scope` may edit, or nil."
  def get_editable_block(%Scope{} = scope, id), do: Block |> Ownership.editable(scope) |> get_preloaded(id, [:prompts])

  defp get_preloaded(query, id, preloads) do
    case Repo.one(from(r in query, where: r.id == ^id)) do
      nil -> nil
      row -> Repo.preload(row, preloads)
    end
  end

  @doc """
  Creates a block owned per `Ownership.new_owner/3`: `scope`'s own, or the site's with `site: true`.
  `for_prompt: prompt` makes it the owner's of `prompt` (nil: the site's), which `scope` must be able
  to edit (`Ownership.authorize_edit/2`), so `add_block/4` accepts it there.
  """
  @spec create_block(Scope.t(), map(), keyword()) ::
          {:ok, Block.t()} | {:held, Hold.t()} | {:error, Ecto.Changeset.t() | :unauthorized | :hold_limit}
  def create_block(%Scope{} = scope, attrs \\ %{}, opts \\ []) do
    {followups, opts} = Keyword.pop(opts, :followups, [])

    with {:ok, owner} <- block_owner(scope, opts[:for_prompt], opts) do
      changeset = Block.changeset(%Block{user_id: owner}, attrs)

      scope
      |> Gate.run(changeset, {__MODULE__, :create_block, [attrs, opts]}, [followups: followups], fn ->
        Repo.insert(changeset)
      end)
      |> Changes.notify(:prompts)
    end
  end

  defp block_owner(scope, nil, opts), do: Ownership.new_owner(scope, Block, opts)

  # A site prompt is editable only with the site permission, the same one that edits site blocks.
  defp block_owner(scope, %Prompt{} = prompt, _opts) do
    with :ok <- Ownership.authorize_edit(scope, prompt), do: {:ok, prompt.user_id}
  end

  @spec update_block(Scope.t(), Block.t(), map()) ::
          {:ok, Block.t()} | {:held, Hold.t()} | {:error, Ecto.Changeset.t() | :unauthorized | :hold_limit}
  def update_block(%Scope{} = scope, %Block{} = block, attrs) do
    with :ok <- Ownership.authorize_edit(scope, block) do
      changeset = Block.changeset(block, attrs)

      scope
      |> Gate.run(changeset, {__MODULE__, :update_block, [{:row, Block, block.id}, attrs]}, [], fn ->
        Repo.update(changeset)
      end)
      |> Changes.notify(:prompts)
    end
  end

  @doc """
  Deletes a block; its membership rows cascade, so it vanishes from every prompt that used it.

  Unlike `Lore.delete_book/2`, this never refuses on content: a block carries no dependent content of
  its own, so there is nothing to orphan. With accepted editors it is given to `opts[:to]` or the
  oldest of them instead (`Mythweaver.Sharing.hand_off_or/4`).
  """
  @spec delete_block(Scope.t(), Block.t(), keyword()) ::
          {:ok, Block.t() | {:handed_off, User.t()}}
          | {:error, Ecto.Changeset.t() | :unauthorized}
  def delete_block(%Scope{} = scope, %Block{} = block, opts \\ []) do
    with :ok <- Ownership.authorize_delete(scope, block) do
      Mythweaver.Sharing.hand_off_or(scope, block, opts, fn ->
        :ok = Mythweaver.Sharing.revoke_all(:block, block.id, :deleted)
        Changes.notify(Repo.delete(block), :prompts)
      end)
    end
  end

  def change_block(%Block{} = block, attrs \\ %{}) do
    Block.changeset(block, attrs)
  end

  ## Prompts

  @doc "Prompts `scope` may use (own plus site) by name, or only those of `purpose` when given."
  def list_prompts(%Scope{} = scope, purpose \\ nil), do: Prompt |> Ownership.usable(scope) |> prompts_by_name(purpose)

  @doc "Prompts `scope` may edit (own, plus site for an admin) by name."
  def list_editable_prompts(%Scope{} = scope), do: Prompt |> Ownership.editable(scope) |> prompts_by_name(nil)

  defp prompts_by_name(query, purpose) do
    from(p in query, order_by: [asc: p.name, asc: p.id], preload: [prompt_blocks: :block])
    |> then(&if(purpose, do: where(&1, [p], p.purpose == ^purpose), else: &1))
    |> Repo.all()
  end

  def get_prompt!(id), do: Prompt |> Repo.get!(id) |> Repo.preload(prompt_preloads())

  @doc "A prompt `scope` may use, or nil."
  def get_prompt(%Scope{} = scope, id), do: Prompt |> Ownership.usable(scope) |> get_preloaded(id, prompt_preloads())

  @doc "A prompt `scope` may edit, or nil."
  def get_editable_prompt(%Scope{} = scope, id),
    do: Prompt |> Ownership.editable(scope) |> get_preloaded(id, prompt_preloads())

  @doc "Creates a prompt owned per `Ownership.new_owner/3`: `scope`'s own, or the site's with `site: true`."
  @spec create_prompt(Scope.t(), map(), keyword()) ::
          {:ok, Prompt.t()}
          | {:held, Hold.t()}
          | {:error, Ecto.Changeset.t() | :unauthorized | :quota_exceeded | :hold_limit}
  def create_prompt(%Scope{} = scope, attrs \\ %{}, opts \\ []) do
    {followups, opts} = Keyword.pop(opts, :followups, [])

    with {:ok, owner} <- Ownership.new_owner(scope, Prompt, opts),
         :ok <- Quota.check_new_row(scope, owner, "quota.prompts", Prompt) do
      changeset = Prompt.changeset(%Prompt{user_id: owner}, attrs)

      scope
      |> Gate.run(changeset, {__MODULE__, :create_prompt, [attrs, opts]}, [followups: followups], fn ->
        Repo.insert(changeset)
      end)
      |> Changes.notify(:prompts)
    end
  end

  @spec update_prompt(Scope.t(), Prompt.t(), map()) ::
          {:ok, Prompt.t()} | {:held, Hold.t()} | {:error, Ecto.Changeset.t() | :unauthorized | :hold_limit}
  def update_prompt(%Scope{} = scope, %Prompt{} = prompt, attrs) do
    with :ok <- Ownership.authorize_edit(scope, prompt) do
      changeset = Prompt.changeset(prompt, attrs)

      scope
      |> Gate.run(changeset, {__MODULE__, :update_prompt, [{:row, Prompt, prompt.id}, attrs]}, [], fn ->
        Repo.update(changeset)
      end)
      |> Changes.notify(:prompts)
    end
  end

  @doc """
  Deletes a prompt; its membership and binding rows cascade, the blocks themselves are untouched.
  With accepted editors it is given to `opts[:to]` or the oldest of them instead
  (`Mythweaver.Sharing.hand_off_or/4`).
  """
  @spec delete_prompt(Scope.t(), Prompt.t(), keyword()) ::
          {:ok, Prompt.t() | {:handed_off, User.t()}}
          | {:error, Ecto.Changeset.t() | :unauthorized}
  def delete_prompt(%Scope{} = scope, %Prompt{} = prompt, opts \\ []) do
    with :ok <- Ownership.authorize_delete(scope, prompt) do
      Mythweaver.Sharing.hand_off_or(scope, prompt, opts, fn ->
        :ok = Mythweaver.Sharing.revoke_all(:prompt, prompt.id, :deleted)
        Changes.notify(Repo.delete(prompt), :prompts)
      end)
    end
  end

  def change_prompt(%Prompt{} = prompt, attrs \\ %{}) do
    Prompt.changeset(prompt, attrs)
  end

  @doc """
  Clones `prompt` into a new row: name serialized by `Mythweaver.Sharing.Clone.next_copy_name/4`, same description, `enabled`
  and `purpose`, and one fresh membership per block preserving `position` and the per-prompt `enabled`.

  Bindings are deliberately not copied: two prompts bound at the same specificity would make
  `resolve_prompt/1`'s winner a name tie-break, silently changing which prompt renders.

  The copy belongs to whoever duplicates it (`Ownership.new_owner/2`): a user copying a site prompt
  gets their own. Only memberships whose block the copy's owner may reference are kept.

  Returns `{:ok, prompt}` with `prompt_preloads/0` loaded, `{:error, :unauthorized}` when `scope` may not
  use `prompt` or create prompts, or `{:error, changeset}` from the prompt insert.
  """
  @spec duplicate_prompt(Scope.t(), Prompt.t()) ::
          {:ok, Prompt.t()} | {:error, Ecto.Changeset.t() | :unauthorized | :quota_exceeded}
  def duplicate_prompt(%Scope{} = scope, %Prompt{} = prompt) do
    with true <- Ownership.usable?(scope, prompt) || {:error, :unauthorized},
         {:ok, owner} <- Ownership.new_owner(scope, Prompt),
         :ok <- Quota.check_new_row(scope, owner, "quota.prompts", Prompt) do
      Repo.transaction(fn ->
        attrs = %{
          name: Clone.next_copy_name(Prompt, prompt.name, owner),
          description: prompt.description,
          enabled: prompt.enabled,
          purpose: prompt.purpose,
          thinking: prompt.thinking
        }

        case create_prompt(scope, attrs) do
          {:ok, copy} ->
            for membership <- list_prompt_blocks(prompt), Ownership.reference_ok?(owner, membership.block) do
              %PromptBlock{}
              |> PromptBlock.changeset(%{
                prompt_id: copy.id,
                block_id: membership.block_id,
                position: membership.position,
                enabled: membership.enabled
              })
              |> Repo.insert!()
            end

            Repo.preload(copy, prompt_preloads())

          {:error, %Ecto.Changeset{} = changeset} ->
            Repo.rollback(changeset)
        end
      end)
      |> Changes.notify(:prompts)
    end
  end

  defp prompt_preloads do
    membership_query = from(pb in PromptBlock, order_by: [asc: pb.position])

    [:bindings, prompt_blocks: {membership_query, [:block]}]
  end

  @doc """
  Appends `block` to `prompt` at the next free position.

  A duplicate surfaces as the unique-constraint changeset error rather than a raise, so a UI can show it
  on the form. `{:error, :unauthorized}` unless `scope` may edit `prompt` and `block` is a site block or
  one of the prompt owner's.
  """
  @spec add_block(Scope.t(), Prompt.t(), Block.t(), map()) ::
          {:ok, PromptBlock.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def add_block(%Scope{} = scope, %Prompt{} = prompt, %Block{} = block, attrs \\ %{}) do
    with :ok <- Ownership.authorize_edit(scope, prompt),
         true <- Ownership.reference_ok?(prompt.user_id, block) || {:error, :unauthorized} do
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.merge(%{
        "prompt_id" => prompt.id,
        "block_id" => block.id,
        "position" => next_position(prompt)
      })
      |> then(&PromptBlock.changeset(%PromptBlock{}, &1))
      |> Repo.insert()
      |> Changes.notify(:prompts, prompt.user_id)
    end
  end

  defp next_position(%Prompt{} = prompt) do
    case Repo.one(from(pb in PromptBlock, where: pb.prompt_id == ^prompt.id, select: max(pb.position))) do
      nil -> 0
      position -> position + 1
    end
  end

  @doc """
  Removes a block from its prompt and re-densifies the remaining positions, so positions stay a gapless
  `0..n-1` for `reorder_blocks/3`.
  """
  @spec remove_block(Scope.t(), PromptBlock.t()) :: {:ok, PromptBlock.t()} | {:error, :unauthorized}
  def remove_block(%Scope{} = scope, %PromptBlock{} = membership) do
    with :ok <- authorize_prompt(scope, membership.prompt_id) do
      Repo.transaction(fn ->
        Repo.delete!(membership)
        densify!(membership.prompt_id)
        membership
      end)
      |> Changes.notify(:prompts, prompt_owner(membership.prompt_id))
    end
  end

  @doc "Updates one membership: the per-prompt `enabled` toggle."
  @spec update_block_membership(Scope.t(), PromptBlock.t(), map()) ::
          {:ok, PromptBlock.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def update_block_membership(%Scope{} = scope, %PromptBlock{} = membership, attrs) do
    with :ok <- authorize_prompt(scope, membership.prompt_id) do
      membership
      |> PromptBlock.changeset(attrs)
      |> Repo.update()
      |> Changes.notify(:prompts, prompt_owner(membership.prompt_id))
    end
  end

  # A membership or binding is edited through its prompt.
  defp authorize_prompt(scope, prompt_id) do
    case Repo.one(from(p in Prompt, where: p.id == ^prompt_id, select: struct(p, [:id, :user_id]))) do
      nil -> {:error, :unauthorized}
      owner -> Ownership.authorize_edit(scope, owner)
    end
  end

  defp prompt_owner(prompt_id), do: Repo.one(from(p in Prompt, where: p.id == ^prompt_id, select: p.user_id))

  def list_prompt_blocks(%Prompt{} = prompt) do
    Repo.all(
      from(pb in PromptBlock,
        where: pb.prompt_id == ^prompt.id,
        order_by: [asc: pb.position],
        preload: [:block]
      )
    )
  end

  @doc """
  One membership row by id, with its block loaded.

  A streamed UI cannot read a row back out of its own stream, so an event handler resolves the id
  through here rather than searching an assign. Nil unless `scope` may edit the membership's prompt.
  """
  def get_prompt_block(%Scope{} = scope, id) do
    prompts = Ownership.editable(Prompt, scope)

    from(pb in PromptBlock, join: p in subquery(prompts), on: p.id == pb.prompt_id)
    |> get_preloaded(id, [:block])
  end

  @doc """
  Rewrites the prompt's block order from `block_ids`, which must be a permutation of the prompt's
  current block ids; anything else returns `{:error, :not_a_permutation}` rather than silently
  dropping or inventing memberships.
  """
  @spec reorder_blocks(Scope.t(), Prompt.t(), [Ecto.UUID.t()]) ::
          {:ok, :ok} | {:error, :not_a_permutation | :unauthorized}
  def reorder_blocks(%Scope{} = scope, %Prompt{} = prompt, block_ids) when is_list(block_ids) do
    with :ok <- Ownership.authorize_edit(scope, prompt) do
      memberships = list_prompt_blocks(prompt)
      current = memberships |> Enum.map(& &1.block_id) |> Enum.sort()

      if Enum.sort(block_ids) == current do
        by_block_id = Map.new(memberships, &{&1.block_id, &1})

        Repo.transaction(fn ->
          restage_positions!(Enum.map(block_ids, &by_block_id[&1].id))
        end)
        |> Changes.notify(:prompts, prompt.user_id)
      else
        {:error, :not_a_permutation}
      end
    end
  end

  # Two passes: the `(prompt_id, position)` unique index makes a single in-place renumber collide with
  # rows not yet moved. Negative staging values are outside every final position. Each pass is one
  # `UPDATE … FROM unnest(…)`, as `Lore`'s `renumber!/2`.
  defp restage_positions!(membership_ids) do
    positions = Enum.to_list(0..(length(membership_ids) - 1)//1)
    set_positions!(membership_ids, Enum.map(positions, &(-1 - &1)))
    set_positions!(membership_ids, positions)
    :ok
  end

  defp set_positions!(membership_ids, positions) do
    Repo.update_all(
      from(pb in PromptBlock,
        join:
          n in fragment(
            "SELECT * FROM unnest(?, ?) AS n(id, position)",
            type(^membership_ids, {:array, Ecto.UUID}),
            type(^positions, {:array, :integer})
          ),
        on: n.id == pb.id,
        update: [set: [position: n.position]]
      ),
      []
    )
  end

  defp densify!(prompt_id) do
    ids =
      Repo.all(
        from(pb in PromptBlock,
          where: pb.prompt_id == ^prompt_id,
          order_by: [asc: pb.position],
          select: pb.id
        )
      )

    restage_positions!(ids)
  end

  ## Bindings

  @doc """
  The bindings of `prompt` (the caller already holds a prompt it may use). A chat binding (`:chat`,
  `:character_in_chat`) is listed only when the chat is `scope`'s own.
  """
  def list_bindings(%Scope{} = scope, %Prompt{} = prompt) do
    Repo.all(
      from(b in visible_bindings(scope),
        where: b.prompt_id == ^prompt.id,
        order_by: [asc: b.scope, asc: b.inserted_at],
        preload: [:provider, :model, :character, :chat]
      )
    )
  end

  # Bindings without a chat, plus those to `scope`'s own chats.
  defp visible_bindings(%Scope{user: %{id: uid}}) do
    own_chats = from(c in Chat, where: c.user_id == ^uid, select: c.id)
    from(b in Binding, where: is_nil(b.chat_id) or b.chat_id in subquery(own_chats))
  end

  @doc """
  Binds `prompt` at `binding_scope`. `ids` is a keyword list of exactly the columns that level
  requires, e.g. `bind_prompt(scope, prompt, :character_in_chat, character_id: c.id, chat_id: chat.id)`.

  Only a `:roleplay` prompt is bindable; any other purpose returns `{:error, :not_roleplay}`.
  `{:error, :unauthorized}` unless `scope` may edit `prompt` and every target is usable with it: a
  provider, model or character must be a site row or one of the prompt owner's (a site prompt binds
  only site ones); a chat, always owned, must be the scope's own and may take any prompt its owner
  may use (site or theirs), as `set_chat_prompt/2` does.
  """
  @spec bind_prompt(Scope.t(), Prompt.t(), atom(), keyword()) ::
          {:ok, Binding.t()} | {:error, Ecto.Changeset.t() | :not_roleplay | :unauthorized}
  def bind_prompt(scope, prompt, binding_scope, ids \\ [])

  def bind_prompt(%Scope{} = scope, %Prompt{purpose: :roleplay} = prompt, binding_scope, ids) do
    with :ok <- Ownership.authorize_edit(scope, prompt),
         :ok <- authorize_targets(scope, prompt, ids) do
      ids
      |> Map.new()
      |> Map.merge(%{prompt_id: prompt.id, scope: binding_scope})
      |> then(&Binding.changeset(%Binding{}, &1))
      |> Repo.insert()
      |> Changes.notify(:prompts, prompt.user_id)
    end
  end

  def bind_prompt(%Scope{} = scope, %Prompt{} = prompt, _binding_scope, _ids) do
    with :ok <- Ownership.authorize_edit(scope, prompt), do: {:error, :not_roleplay}
  end

  @binding_targets %{
    provider_id: Provider,
    ai_model_id: Model,
    character_id: Character,
    chat_id: Chat
  }

  # A missing target is left to the changeset's `assoc_constraint`; an id that is not a UUID is left to
  # its cast. Loaded as its struct, which `Ownership.reference_ok?/2` needs to see a share.
  defp authorize_targets(scope, prompt, ids) do
    ok? =
      Enum.all?(ids, fn {field, id} ->
        with schema when not is_nil(schema) <- Map.get(@binding_targets, field),
             {:ok, uuid} <- Ecto.UUID.cast(to_string(id)),
             %{} = target <- Repo.get(schema, uuid) do
          target_ok?(scope, prompt, field, target)
        else
          _ -> true
        end
      end)

    if ok?, do: :ok, else: {:error, :unauthorized}
  end

  defp target_ok?(%Scope{user: %{id: uid}}, prompt, :chat_id, %{user_id: uid}), do: Ownership.reference_ok?(uid, prompt)
  defp target_ok?(_scope, _prompt, :chat_id, _chat), do: false
  defp target_ok?(_scope, prompt, _field, target), do: Ownership.reference_ok?(prompt.user_id, target)

  @doc "Deletes a binding; needs edit rights on its prompt, and for a chat binding the chat (only its owner)."
  @spec unbind_prompt(Scope.t(), Binding.t()) :: {:ok, Binding.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def unbind_prompt(%Scope{} = scope, %Binding{} = binding) do
    with :ok <- authorize_binding_chat(scope, binding),
         :ok <- authorize_prompt(scope, binding.prompt_id),
         do: Changes.notify(Repo.delete(binding), :prompts, prompt_owner(binding.prompt_id))
  end

  defp authorize_binding_chat(_scope, %Binding{chat_id: nil}), do: :ok
  defp authorize_binding_chat(scope, %Binding{chat_id: chat_id}), do: Chats.authorize(scope, chat_id, :manage)

  @doc "One binding by id, or nil unless `scope` may edit its prompt (and owns its chat, if any)."
  def get_binding(%Scope{} = scope, id) do
    prompts = Ownership.editable(Prompt, scope)

    from(b in visible_bindings(scope), join: p in subquery(prompts), on: p.id == b.prompt_id)
    |> get_preloaded(id, [:provider, :model, :character, :chat])
  end

  @doc "The prompt of the chat's `:chat`-scope binding (the one `resolve_prompt/1` picks), or nil."
  def chat_prompt_id(%Chat{} = chat) do
    from(b in Binding,
      join: p in subquery(Ownership.for_owner(Prompt, chat.user_id)),
      on: p.id == b.prompt_id,
      where: b.scope == :chat and b.chat_id == ^chat.id and p.purpose == :roleplay,
      order_by: [asc: p.name, asc: p.id],
      limit: 1,
      select: b.prompt_id
    )
    |> Repo.one()
  end

  @doc """
  Makes `prompt_id` (or nothing, when nil) the chat's only `:chat`-scope binding.
  `:character_in_chat` bindings are untouched. A prompt whose purpose is not `:roleplay` returns
  `{:error, :not_roleplay}`, and one the chat owner may not use (another user's) `{:error, :unauthorized}`;
  given `actor` (a chat editor who is not the owner), so does a newly chosen one `actor` may not use.
  Either changes nothing.
  """
  def set_chat_prompt(%Chat{} = chat, prompt_id, actor \\ nil) do
    Repo.transaction(fn ->
      prompt = prompt_id && Repo.get(Prompt, prompt_id)

      cond do
        is_nil(prompt) ->
          :ok

        not Ownership.reference_ok?(chat.user_id, prompt) ->
          Repo.rollback(:unauthorized)

        actor && prompt.id != chat_prompt_id(chat) && not Ownership.usable?(actor, prompt) ->
          Repo.rollback(:unauthorized)

        prompt.purpose != :roleplay ->
          Repo.rollback(:not_roleplay)

        true ->
          :ok
      end

      query = from(b in Binding, where: b.scope == :chat and b.chat_id == ^chat.id)

      query
      |> then(&if(prompt_id, do: where(&1, [b], b.prompt_id != ^prompt_id), else: &1))
      |> Repo.delete_all()

      if prompt_id && !Repo.exists?(query) do
        %Binding{}
        |> Binding.changeset(%{prompt_id: prompt_id, scope: :chat, chat_id: chat.id})
        |> Repo.insert()
        |> Repo.ok_or_rollback()
      end

      :ok
    end)
    |> Changes.notify(:prompts, chat.user_id)
  end

  @doc """
  The prompt that wins for `scope`, by CSS-like specificity: the most specific binding beats the more
  general one.

  `scope` is a map with any of `:provider`, `:model`, `:chat`, `:character` (structs or ids). Specificity,
  highest first:

    1. `:character_in_chat`: this character, in this chat
    2. `:chat`
    3. `:character`
    4. `:model`
    5. `:connection`
    6. `:global`

  Returns the winning enabled `:roleplay` `%Prompt{}` with its blocks preloaded in position order, or
  `nil` when nothing is bound at any level. Several prompts may sit at one specificity level, so the
  tie is broken by owner (`Ownership.owner_rank/1`: the chat owner's own, the site's, then those
  shared to it), then `prompt.name` ascending to keep the choice total and deterministic. That is the same
  name tie-break `Lore.Activation`'s `membership_rank/1` uses on `book.name`.

  Candidates are the site's prompts, the chat owner's and those shared to it; a shared prompt only
  counts through a `:chat`, `:character_in_chat` or `:character` binding (one its owner chose for
  that chat or character), never a model, connection or global one. The owner is `:owner_id` when
  the map has that key, else the `:chat`'s `user_id` (a struct, or an id looked up); no chat means
  site only.

  One query, not six: a `nil` id simply drops that scope from the `where`, so a build with no chat can
  still resolve a `:model` or `:global` prompt.
  """
  @spec resolve_prompt(map()) :: Prompt.t() | nil
  def resolve_prompt(scope) when is_map(scope) do
    provider_id = id_of(scope, :provider)
    model_id = id_of(scope, :model)
    character_id = id_of(scope, :character)
    chat_id = id_of(scope, :chat)
    owner_id = owner_id(scope, chat_id)

    candidates =
      Prompt
      |> Ownership.for_owner(owner_id)
      |> select([p], ^%{id: dynamic([p], p.id), rank: Ownership.owner_rank(owner_id)})

    query =
      from(b in Binding,
        join: c in subquery(candidates),
        on: c.id == b.prompt_id,
        join: p in Prompt,
        on: p.id == c.id,
        where: p.enabled and p.purpose == :roleplay,
        where: ^shared_by_chat_choice(owner_id),
        order_by: [
          asc:
            fragment(
              """
              CASE ?
                WHEN 'character_in_chat' THEN 1
                WHEN 'chat' THEN 2
                WHEN 'character' THEN 3
                WHEN 'model' THEN 4
                WHEN 'connection' THEN 5
                ELSE 6
              END
              """,
              b.scope
            ),
          asc: c.rank,
          asc: p.name
        ],
        limit: 1,
        select: p
      )

    query
    |> where(^candidate_bindings(provider_id, model_id, character_id, chat_id))
    |> Repo.one()
    |> case do
      nil -> nil
      prompt -> Repo.preload(prompt, prompt_preloads())
    end
  end

  # A prompt shared to the owner counts only through a binding its owner chose for a chat or character.
  # With no owner the candidates are site prompts already.
  defp shared_by_chat_choice(nil), do: dynamic(true)

  defp shared_by_chat_choice(owner_id) do
    dynamic(
      [b, _c, p],
      b.scope in [:chat, :character_in_chat, :character] or is_nil(p.user_id) or p.user_id == ^owner_id
    )
  end

  # One dynamic, built by folding: a `dynamic/2` may only be interpolated at the top level of a
  # `where`, so the alternatives are combined here rather than `or`-ed inside the query expression.
  # An absent id drops its scope from the disjunction entirely instead of contributing `false`.
  defp candidate_bindings(provider_id, model_id, character_id, chat_id) do
    [
      scope_match(:connection, :provider_id, provider_id),
      scope_match(:model, :ai_model_id, model_id),
      scope_match(:character, :character_id, character_id),
      scope_match(:chat, :chat_id, chat_id),
      character_in_chat_match(character_id, chat_id)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(dynamic([b], b.scope == :global), fn clause, acc ->
      dynamic([b], ^acc or ^clause)
    end)
  end

  defp scope_match(_scope, _field, nil), do: nil

  defp scope_match(scope, field, id) do
    dynamic([b], b.scope == ^scope and field(b, ^field) == ^id)
  end

  defp character_in_chat_match(nil, _chat_id), do: nil
  defp character_in_chat_match(_character_id, nil), do: nil

  defp character_in_chat_match(character_id, chat_id) do
    dynamic(
      [b],
      b.scope == :character_in_chat and b.character_id == ^character_id and b.chat_id == ^chat_id
    )
  end

  defp owner_id(%{owner_id: owner_id}, _chat_id), do: owner_id
  defp owner_id(%{chat: %Chat{user_id: owner_id}}, _chat_id), do: owner_id
  defp owner_id(_scope, nil), do: nil

  defp owner_id(_scope, chat_id) do
    case Ecto.UUID.cast(chat_id) do
      {:ok, id} -> Chats.owner_id(id)
      :error -> nil
    end
  end

  # A scope map may carry structs or bare ids; both are common at a callsite. Anything else is treated
  # as an absent target rather than raising: a malformed optional key must degrade to "this scope does
  # not match", exactly as `nil` does, so one bad target cannot take prompt resolution down.
  defp id_of(scope, key) do
    case Map.get(scope, key) do
      %{id: id} -> id
      id when is_binary(id) -> id
      _ -> nil
    end
  end

  ## Outlets

  @doc """
  Outlets `scope` may use, by name, one per key: `scope`'s own outlet shadows the site's with the same
  key, as `get_outlet_by_key/2` resolves it at runtime.
  """
  def list_outlets(%Scope{} = scope) do
    Outlet
    |> Ownership.usable(scope)
    |> outlets_by_name()
    |> Enum.sort_by(&is_nil(&1.user_id))
    |> Enum.uniq_by(& &1.key)
    |> Enum.sort_by(&{&1.name, &1.id})
  end

  @doc "Outlets `scope` may edit (own, plus site for an admin), by name."
  def list_editable_outlets(%Scope{} = scope), do: Outlet |> Ownership.editable(scope) |> outlets_by_name()

  defp outlets_by_name(query), do: Repo.all(from(o in query, order_by: [asc: o.name, asc: o.id]))

  @doc "An outlet `scope` may use, or nil."
  def get_outlet(%Scope{} = scope, id), do: Outlet |> Ownership.usable(scope) |> get_preloaded(id, [])

  @doc "An outlet `scope` may edit, or nil."
  def get_editable_outlet(%Scope{} = scope, id), do: Outlet |> Ownership.editable(scope) |> get_preloaded(id, [])

  @doc """
  The outlet a lore entry's stored key refers to for a chat owned by `owner_id` (nil: site only): the
  owner's own outlet with that key, else the site's, else one shared to it (`Ownership.owner_rank/1`),
  else `nil` when the key is dangling.
  """
  def get_outlet_by_key(owner_id, key) when is_binary(key) do
    Outlet
    |> Ownership.for_owner(owner_id)
    |> where([o], o.key == ^key)
    |> order_by(^[asc: Ownership.owner_rank(owner_id), asc: :id])
    |> limit(1)
    |> Repo.one()
  end

  @doc "Creates an outlet owned per `Ownership.new_owner/3`: `scope`'s own, or the site's with `site: true`."
  @spec create_outlet(Scope.t(), map(), keyword()) ::
          {:ok, Outlet.t()} | {:held, Hold.t()} | {:error, Ecto.Changeset.t() | :unauthorized | :hold_limit}
  def create_outlet(%Scope{} = scope, attrs \\ %{}, opts \\ []) do
    {followups, opts} = Keyword.pop(opts, :followups, [])

    with {:ok, owner} <- Ownership.new_owner(scope, Outlet, opts) do
      changeset = Outlet.changeset(%Outlet{user_id: owner}, attrs)

      scope
      |> Gate.run(changeset, {__MODULE__, :create_outlet, [attrs, opts]}, [followups: followups], fn ->
        Repo.insert(changeset)
      end)
      |> Changes.notify(:prompts)
    end
  end

  @spec update_outlet(Scope.t(), Outlet.t(), map()) ::
          {:ok, Outlet.t()} | {:held, Hold.t()} | {:error, Ecto.Changeset.t() | :unauthorized | :hold_limit}
  def update_outlet(%Scope{} = scope, %Outlet{} = outlet, attrs) do
    with :ok <- Ownership.authorize_edit(scope, outlet) do
      changeset = Outlet.changeset(outlet, attrs)

      scope
      |> Gate.run(changeset, {__MODULE__, :update_outlet, [{:row, Outlet, outlet.id}, attrs]}, [], fn ->
        Repo.update(changeset)
      end)
      |> Changes.notify(:prompts)
    end
  end

  @doc """
  Deletes an outlet. That removes it from the picker only: lore entries still keyed to it keep
  filling `outlets.<key>`, because an entry stores the bare key rather than a reference to this row.
  With accepted editors it is given to `opts[:to]` or the oldest of them instead
  (`Mythweaver.Sharing.hand_off_or/4`).
  """
  @spec delete_outlet(Scope.t(), Outlet.t(), keyword()) ::
          {:ok, Outlet.t() | {:handed_off, User.t()}}
          | {:error, Ecto.Changeset.t() | :unauthorized}
  def delete_outlet(%Scope{} = scope, %Outlet{} = outlet, opts \\ []) do
    with :ok <- Ownership.authorize_delete(scope, outlet) do
      Mythweaver.Sharing.hand_off_or(scope, outlet, opts, fn ->
        :ok = Mythweaver.Sharing.revoke_all(:outlet, outlet.id, :deleted)
        Changes.notify(Repo.delete(outlet), :prompts)
      end)
    end
  end

  def change_outlet(%Outlet{} = outlet, attrs \\ %{}) do
    Outlet.changeset(outlet, attrs)
  end

  @doc """
  Outlets as `{name, key}` pairs, exactly what `<.input type="select">` wants, so a LiveView holds no
  formatting logic. The value is the stable `key`, which is what a lore entry stores.
  """
  def outlet_options(%Scope{} = scope) do
    Enum.map(list_outlets(scope), &{&1.name, &1.key})
  end
end
