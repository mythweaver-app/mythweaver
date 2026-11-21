defmodule Mythweaver.Moderation.Lookup do
  @moduledoc """
  The moderation panel's lookup: from a link, an id, an `@handle` or an email to one row
  (`resolve/2`), a read-only view of it (`fetch/4`, `"moderation.content.view"`, every look written to
  the moderation log), and its deletion (`delete/3`, `"moderation.content.delete"` and sudo mode).
  There is no listing of anything: content is reached only from a report, a lookup or a user's
  content index (`MythweaverWeb.UserDataLive`).

  A delete acts as the row's owner through the context function the owner's own editor uses, and a
  shared root item is revoked first, so it goes for everyone rather than passing to an editor. Site
  rows stay with the site's editors. Nobody but an owner looks up or deletes an owner's rows.
  """

  import Ecto.Query

  alias Mythweaver.Accounts
  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.AI
  alias Mythweaver.Catalog.Listing
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Chats.Member
  alias Mythweaver.Expressions
  alias Mythweaver.Lore
  alias Mythweaver.Memory
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message
  alias Mythweaver.Moderation
  alias Mythweaver.Moderation.Log
  alias Mythweaver.Moderation.Report
  alias Mythweaver.Moderation.Reports
  alias Mythweaver.Prompts
  alias Mythweaver.Repo
  alias Mythweaver.Scripts
  alias Mythweaver.Sharing
  alias Mythweaver.Sharing.Items

  @item_types [
    :character,
    :lore_book,
    :lore_entry,
    :lore_pool,
    :prompt,
    :block,
    :outlet,
    :script,
    :memory_profile,
    :side_prompt,
    :side_prompt_set,
    :ai_model,
    :expression_profile
  ]

  @types [:user, :chat, :message, :listing, :ai_provider] ++ @item_types

  @type_names Map.new(@types, &{Atom.to_string(&1), &1})

  @type type ::
          :user
          | :chat
          | :message
          | :listing
          | :ai_provider
          | :character
          | :lore_book
          | :lore_entry
          | :lore_pool
          | :prompt
          | :block
          | :outlet
          | :script
          | :memory_profile
          | :side_prompt
          | :side_prompt_set
          | :ai_model
          | :expression_profile

  @doc "Every type a lookup can name."
  @spec types() :: [type()]
  def types, do: @types

  @doc "The type a URL segment names, or nil."
  @spec parse_type(String.t()) :: type() | nil
  def parse_type(name) when is_binary(name), do: Map.get(@type_names, name)
  def parse_type(_name), do: nil

  @doc """
  What `query` names: `@handle`, an email, a bare id (any table), or a link to a chat, an editor, a
  catalog listing or a moderation page. Needs any of `Mythweaver.Moderation.record_keys/0`.
  """
  @spec resolve(Scope.t(), String.t()) :: {:ok, {type(), Ecto.UUID.t()}} | {:error, :not_found | :unauthorized}
  def resolve(%Scope{} = scope, query) when is_binary(query) do
    if Enum.any?(Moderation.record_keys(), &Scope.can?(scope, &1)),
      do: resolve_query(query),
      else: {:error, :unauthorized}
  end

  defp resolve_query(query) do
    query = String.trim(query)

    result =
      cond do
        query == "" -> nil
        String.starts_with?(query, "@") -> user(Accounts.get_user_by_handle(query))
        not String.contains?(query, "/") and String.contains?(query, "@") -> user(Accounts.get_user_by_email(query))
        match?({:ok, _}, Ecto.UUID.cast(query)) -> by_id(query)
        true -> by_path(query)
      end

    if result, do: {:ok, result}, else: {:error, :not_found}
  end

  defp user(%User{id: id}), do: {:user, id}
  defp user(nil), do: nil

  defp by_id(id) do
    {:ok, id} = Ecto.UUID.cast(id)

    [first | rest] =
      Enum.map(@types, &from(r in schema(&1), where: r.id == ^id, select: %{type: type(^Atom.to_string(&1), :string)}))

    union = Enum.reduce(rest, first, fn query, acc -> union_all(acc, ^query) end)

    case Repo.one(from(u in subquery(union), select: u.type, limit: 1)) do
      nil -> nil
      name -> {parse_type(name), id}
    end
  end

  defp by_path(query) do
    segments = (URI.parse(query).path || "") |> String.split("/", trim: true)

    with {type, id} when not is_nil(type) <- path_target(segments),
         {:ok, id} <- Ecto.UUID.cast(id),
         true <- exists?(type, id) do
      {type, id}
    else
      _ -> nil
    end
  end

  defp path_target(["chats", id | _]), do: {:chat, id}
  defp path_target(["characters", "expression-profiles", id, "edit"]), do: {:expression_profile, id}
  defp path_target(["characters", id, "edit"]), do: {:character, id}
  defp path_target(["lore", "entries", id, "edit"]), do: {:lore_entry, id}
  defp path_target(["lore", _book, "entries", id, "edit"]), do: {:lore_entry, id}
  defp path_target(["lore", id, "edit"]), do: {:lore_book, id}
  defp path_target(["prompts", "blocks", id, "edit"]), do: {:block, id}
  defp path_target(["prompts", "outlets", id, "edit"]), do: {:outlet, id}
  defp path_target(["prompts", id, "edit"]), do: {:prompt, id}
  defp path_target(["scripts", id, "edit"]), do: {:script, id}
  defp path_target(["memory", "profiles", id, "edit"]), do: {:memory_profile, id}
  defp path_target(["memory", "side-prompts", id, "edit"]), do: {:side_prompt, id}
  defp path_target(["memory", "side-prompt-sets", id, "edit"]), do: {:side_prompt_set, id}
  defp path_target(["ai", "models", id, "edit"]), do: {:ai_model, id}
  defp path_target(["ai", "providers", id, "edit"]), do: {:ai_provider, id}
  defp path_target(["catalog", id]), do: {:listing, id}
  defp path_target(["moderation", "users", id | _]), do: {:user, id}
  defp path_target(["moderation", "lookup", type, id]), do: {parse_type(type), id}
  defp path_target(_segments), do: nil

  defp exists?(type, id), do: Repo.exists?(from(r in schema(type), where: r.id == ^id))

  defp schema(:user), do: User
  defp schema(:chat), do: Chat
  defp schema(:message), do: Message
  defp schema(:listing), do: Listing
  defp schema(:ai_provider), do: AI.Provider
  defp schema(type) when type in @item_types, do: Items.schema(type)

  @doc "The moderation page of `{type, id}`: an account's record, else its lookup view."
  @spec path({type(), Ecto.UUID.t()}) :: String.t()
  def path({:user, id}), do: "/moderation/users/#{id}/record"
  def path({type, id}), do: "/moderation/lookup/#{type}/#{id}"

  @doc """
  The read-only view of `type`/`id` (not `:user`: that is the account's record page). Writes the
  look to the moderation log unless `log: false`. Every view has `type`, `name` and `owner` (nil for a site
  or unowned row), plus:

    * `:chat` / `:message`: `chat`, `members` (accepted members' users), `messages`, `target_id`
      (the message's id, else nil);
    * `:listing`: `listing` (taken-down ones too) and `card`, the mirror's card;
    * any other: `item`, `card` (shareable types) and `fields` (nil: `MythweaverWeb.ItemFields`' default).
  """
  @spec fetch(Scope.t(), type(), String.t(), keyword()) :: {:ok, map()} | {:error, :unauthorized | :not_found}
  def fetch(%Scope{} = actor, type, id, opts \\ []) do
    with :ok <- Scope.authorize(actor, "moderation.content.view"),
         true <- type in @types and type != :user,
         {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, row, owner} <- load(type, id),
         :ok <- Moderation.authorize_owned_by(actor, owner),
         {:ok, view} <- view(actor, type, row, owner) do
      if Keyword.get(opts, :log, true), do: :ok = Log.record(actor, :viewed, type, id, owner && owner.id)
      {:ok, view}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      _ -> {:error, :not_found}
    end
  end

  # The row of `type` `id` with its owning account (nil for a site row).
  defp load(:chat, id) do
    case Chats.get_chat(id) do
      nil -> {:error, :not_found}
      chat -> {:ok, chat, owner(chat.user_id)}
    end
  end

  defp load(:message, id) do
    with %Message{chat_id: chat_id} = message when is_binary(chat_id) <- Repo.get(Message, id),
         %Chat{} = chat <- Chats.get_chat(chat_id) do
      {:ok, %{message | chat: chat}, owner(chat.user_id)}
    else
      _ -> {:error, :not_found}
    end
  end

  defp load(:listing, id) do
    case Repo.get(Listing, id) do
      nil ->
        {:error, :not_found}

      listing ->
        listing = Repo.preload(listing, [:owner, :current_release])
        {:ok, listing, listing.owner}
    end
  end

  defp load(type, id) do
    case Repo.get(schema(type), id) do
      nil -> {:error, :not_found}
      row -> {:ok, row, owner(row.user_id)}
    end
  end

  defp owner(nil), do: nil
  defp owner(id), do: Repo.get(User, id)

  defp view(_actor, :chat, chat, owner), do: {:ok, chat_view(:chat, chat, owner, nil)}
  defp view(_actor, :message, message, owner), do: {:ok, chat_view(:message, message.chat, owner, message.id)}

  defp view(actor, :listing, listing, owner) do
    case Items.get(listing.item_type, listing.mirror_id) do
      nil ->
        {:error, :not_found}

      mirror ->
        {:ok, %{type: :listing, name: listing.title, owner: owner, listing: listing, card: card(actor, mirror, owner)}}
    end
  end

  defp view(_actor, :ai_provider, provider, owner) do
    {:ok,
     %{
       type: :ai_provider,
       name: provider.name,
       owner: owner,
       item: provider,
       fields: [:base_url, :enabled, :priority, :max_concurrency]
     }}
  end

  defp view(actor, type, row, owner) do
    card = card(actor, row, owner)
    {:ok, %{type: type, name: row.name, owner: owner, item: card.item, card: card, fields: fields(type)}}
  end

  defp fields(:lore_pool), do: [:description, :max_activations]
  defp fields(:expression_profile), do: []
  defp fields(_type), do: nil

  defp chat_view(type, %Chat{} = chat, owner, target_id) do
    members =
      Repo.all(
        from(m in Member,
          where: m.chat_id == ^chat.id and m.status == :accepted,
          order_by: [asc: m.inserted_at],
          preload: :user
        )
      )

    %{
      type: type,
      name: Chat.title(chat),
      owner: owner,
      chat: chat,
      members: Enum.map(members, & &1.user),
      messages: chat |> Messages.list_messages() |> Repo.preload(:author_user),
      target_id: target_id
    }
  end

  # The row's card as its owner sees it (the actor for a site row), with everything readable.
  defp card(actor, row, owner) do
    scope = if owner, do: Scope.for_user(owner), else: actor
    card = Items.card(scope, row)
    %{card | readable?: true, parts: Enum.map(card.parts, fn {part, _} -> {part, true} end)}
  end

  @doc """
  Deletes `type`/`id` as its owner (sudo mode, `"moderation.content.delete"`). A listing is taken
  down instead (`Mythweaver.Catalog.takedown/3`, which needs a reason). Context errors (`:in_use`, a
  changeset) pass through.
  """
  @spec delete(Scope.t(), type(), String.t()) ::
          {:ok, :deleted}
          | {:error, :sudo_required | :unauthorized | :not_found | :site_row | :generating | term()}
  def delete(%Scope{} = actor, type, id) do
    with :ok <- Accounts.authorize_sudo(actor),
         :ok <- Scope.authorize(actor, "moderation.content.delete"),
         true <- (type in @types and type not in [:user, :listing]) || {:error, :unauthorized},
         {:ok, id} <- Ecto.UUID.cast(id) |> found(),
         {:ok, row, owner_user} <- load(type, id),
         %User{} <- owner_user || {:error, :site_row},
         :ok <- Moderation.authorize_owned_by(actor, owner_user),
         message_ids = chat_message_ids(type, id),
         {:ok, _} <- delete_row(Scope.for_user(owner_user), type, row) do
      :ok = Log.record(actor, :deleted, type, id, owner_user.id, %{"name" => display_name(type, row)})
      if type in Report.subject_types(), do: :ok = Reports.resolve_subject(actor, type, id)
      :ok = Reports.resolve_messages(actor, message_ids)
      Moderation.broadcast_changed()
      {:ok, :deleted}
    end
  end

  defp found({:ok, id}), do: {:ok, id}
  defp found(:error), do: {:error, :not_found}

  # Collected before the delete: the messages go with their chat.
  defp chat_message_ids(:chat, id), do: Repo.all(from(m in Message, where: m.chat_id == ^id, select: m.id))
  defp chat_message_ids(_type, _id), do: []

  defp display_name(:chat, chat), do: Chat.title(chat)
  defp display_name(:message, message), do: Chat.title(message.chat)
  defp display_name(_type, row), do: row.name

  defp delete_row(owner, :chat, chat), do: Chats.delete_chat(owner, chat)

  defp delete_row(owner, :message, message) do
    message = Repo.preload(message, :bodies)

    if Enum.any?(message.bodies, & &1.generating),
      do: {:error, :generating},
      else: Messages.delete_message(owner, message)
  end

  # Checked before the shares end: a character in its owner's chats is not deleted, so it keeps them.
  defp delete_row(owner, :character, row) do
    if Chats.character_in_owner_chats?(row), do: {:error, :in_use}, else: revoke_and_delete(owner, :character, row)
  end

  defp delete_row(owner, type, row), do: revoke_and_delete(owner, type, row)

  defp revoke_and_delete(owner, type, row) do
    if Items.root?(type), do: :ok = Sharing.revoke_all(type, row.id, :taken_down)
    delete_item(owner, type, row)
  end

  defp delete_item(owner, :character, row), do: Characters.delete_character(owner, row)
  defp delete_item(owner, :lore_book, row), do: Lore.delete_book(owner, row)
  defp delete_item(owner, :prompt, row), do: Prompts.delete_prompt(owner, row)
  defp delete_item(owner, :block, row), do: Prompts.delete_block(owner, row)
  defp delete_item(owner, :outlet, row), do: Prompts.delete_outlet(owner, row)
  defp delete_item(owner, :script, row), do: Scripts.delete_script(owner, row)
  defp delete_item(owner, :memory_profile, row), do: Memory.delete_profile(owner, row)
  defp delete_item(owner, :side_prompt, row), do: Memory.delete_side_prompt(owner, row)
  defp delete_item(owner, :side_prompt_set, row), do: Memory.delete_side_prompt_set(owner, row)
  defp delete_item(owner, :ai_model, row), do: AI.delete_model(owner, row)
  defp delete_item(owner, :lore_entry, row), do: Lore.delete_entry(owner, row)
  defp delete_item(owner, :lore_pool, row), do: Lore.delete_pool(owner, row)
  defp delete_item(owner, :expression_profile, row), do: Expressions.delete_profile(owner, row)
  defp delete_item(owner, :ai_provider, row), do: AI.delete_provider(owner, row)
end
