defmodule Mythweaver.Sharing.HandOff do
  @moduledoc """
  What `Mythweaver.Sharing.hand_off/3` changes on the item itself once its root and parts have a new
  owner: every reference the new owner may not use (`Mythweaver.Ownership.reference_ok?/2`: a site
  row, one of their own, one shared to them) goes, as it would be refused on an edit. Character ↔
  book bindings, a character's expression profile and prompt bindings, a book's tag filters, its
  entries' character and tag filters and their memberships in the old owner's books and pools, the
  chats and characters a book's activation rule conditions name, a prompt's blocks, a memory
  profile's prompts and personal model, a script's dependencies, a side
  prompt's profile and target book, a side prompt set's rows.

  A side prompt cannot run without its prompt, so one whose prompt the new owner may not use refuses
  the hand-off (`blocking_prompt/3`) instead.
  """

  import Ecto.Query

  alias Mythweaver.AI
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Expressions
  alias Mythweaver.Lore.BookCharacter
  alias Mythweaver.Lore.BookEntry
  alias Mythweaver.Lore.BookFilterTag
  alias Mythweaver.Lore.BookRule
  alias Mythweaver.Lore.BookRuleCondition
  alias Mythweaver.Lore.EntryCharacter
  alias Mythweaver.Lore.EntryFilterTag
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Lore.PoolEntry
  alias Mythweaver.Memory.Profile
  alias Mythweaver.Memory.SidePrompt
  alias Mythweaver.Memory.SidePromptSetRow
  alias Mythweaver.Prompts.Binding
  alias Mythweaver.Prompts.Block
  alias Mythweaver.Prompts.Prompt
  alias Mythweaver.Prompts.PromptBlock
  alias Mythweaver.Repo
  alias Mythweaver.Scripts.Script
  alias Mythweaver.Sharing.Grant
  alias Mythweaver.Sharing.Items
  alias Mythweaver.Sharing.Share
  alias Mythweaver.Tags.Tag

  @doc """
  The prompt of the side prompt `item` that `share`'s user could not use once `share` is gone, or
  nil: the hand-off to them must wait until the prompt is shared with them on its own.
  """
  @spec blocking_prompt(Items.root_type(), struct(), Share.t()) :: Prompt.t() | nil
  def blocking_prompt(:side_prompt, %SidePrompt{prompt_id: prompt_id}, %Share{} = share) when is_binary(prompt_id) do
    case Repo.get(Prompt, prompt_id) do
      %Prompt{user_id: owner} = prompt when is_binary(owner) and owner != share.user_id ->
        kept? =
          Repo.exists?(
            from(g in Grant,
              where:
                g.user_id == ^share.user_id and g.share_id != ^share.id and g.item_type == :prompt and
                  g.item_id == ^prompt_id and g.access in [:edit, :use]
            )
          )

        if !kept?, do: prompt

      _ ->
        nil
    end
  end

  def blocking_prompt(_type, _item, _share), do: nil

  @doc """
  Removes the references of the handed-off item `type`/`id` that `new_owner` may not use. `moved` is
  what changed owner, by type (the root and its parts). Run inside the hand-off's transaction, after
  the move and before the grants are rebuilt.
  """
  @spec strip(Items.root_type(), Ecto.UUID.t(), %{atom() => [Ecto.UUID.t()]}, Ecto.UUID.t()) :: :ok
  def strip(type, id, moved, new_owner) do
    for {query, action} <- plan(type, id, moved, new_owner) do
      case action do
        :delete -> Repo.delete_all(query)
        {:set, set} -> Repo.update_all(query, set: set)
      end
    end

    :ok
  end

  defp plan(:character, id, _moved, x) do
    [
      {from(bc in BookCharacter,
         where: bc.character_id == ^id and bc.lore_book_id not in subquery(usable(LoreBook, x))
       ), :delete},
      {from(c in Character,
         where: c.id == ^id and c.expression_profile_id not in subquery(usable(Expressions.Profile, x))
       ), {:set, expression_profile_id: nil}},
      {from(bd in Binding, where: bd.character_id == ^id and bd.prompt_id not in subquery(usable(Prompt, x))), :delete}
    ]
  end

  defp plan(:lore_book, id, moved, x) do
    entries = Map.get(moved, :lore_entry, [])
    pools = Map.get(moved, :lore_pool, [])
    own_books = from(b in LoreBook, where: b.user_id == ^x, select: b.id)
    rules = from(r in BookRule, where: r.lore_book_id == ^id, select: r.id)
    own_chats = from(c in Chat, where: c.user_id == ^x, select: c.id)

    [
      {from(bc in BookCharacter,
         where: bc.lore_book_id == ^id and bc.character_id not in subquery(usable(Character, x))
       ), :delete},
      {from(bf in BookFilterTag, where: bf.lore_book_id == ^id and bf.tag_id not in subquery(usable(Tag, x))), :delete},
      # `NULL NOT IN` is not true, so conditions already without a target stay as they are.
      {from(rc in BookRuleCondition,
         where: rc.lore_book_rule_id in subquery(rules) and rc.character_id not in subquery(usable(Character, x))
       ), {:set, character_id: nil}},
      {from(rc in BookRuleCondition,
         where: rc.lore_book_rule_id in subquery(rules) and rc.chat_id not in subquery(own_chats)
       ), {:set, chat_id: nil}},
      {from(be in BookEntry,
         where: be.lore_entry_id in ^entries and be.lore_book_id != ^id and be.lore_book_id not in subquery(own_books)
       ), :delete},
      {from(pe in PoolEntry, where: pe.lore_entry_id in ^entries and pe.lore_pool_id not in ^pools), :delete},
      {from(ec in EntryCharacter,
         where: ec.lore_entry_id in ^entries and ec.character_id not in subquery(usable(Character, x))
       ), :delete},
      {from(ef in EntryFilterTag, where: ef.lore_entry_id in ^entries and ef.tag_id not in subquery(usable(Tag, x))),
       :delete}
    ]
  end

  defp plan(:prompt, id, _moved, x) do
    [{from(pb in PromptBlock, where: pb.prompt_id == ^id and pb.block_id not in subquery(usable(Block, x))), :delete}]
  end

  defp plan(:memory_profile, id, _moved, x) do
    prompts =
      for {field, _purpose} <- Profile.prompt_purposes() do
        {from(p in Profile, where: p.id == ^id and field(p, ^field) not in subquery(usable(Prompt, x))),
         {:set, [{field, nil}]}}
      end

    personal_models = from(m in AI.Model, where: not is_nil(m.user_id) and m.user_id != ^x, select: m.id)

    prompts ++
      [
        {from(p in Profile, where: p.id == ^id and p.ai_model_id in subquery(personal_models)),
         {:set, ai_model_id: nil}}
      ]
  end

  defp plan(:script, id, _moved, x) do
    [
      {from(d in "script_dependencies",
         where: d.script_id == type(^id, Ecto.UUID) and d.dependency_id not in subquery(usable(Script, x))
       ), :delete}
    ]
  end

  defp plan(:side_prompt, id, _moved, x) do
    [
      {from(s in SidePrompt, where: s.id == ^id and s.profile_id not in subquery(usable(Profile, x))),
       {:set, profile_id: nil}},
      {from(s in SidePrompt, where: s.id == ^id and s.target_book_id not in subquery(usable(LoreBook, x))),
       {:set, target_book_id: nil}}
    ]
  end

  defp plan(:side_prompt_set, id, _moved, x) do
    [
      {from(r in SidePromptSetRow,
         where: r.side_prompt_set_id == ^id and r.side_prompt_id not in subquery(usable(SidePrompt, x))
       ), :delete}
    ]
  end

  defp plan(_type, _id, _moved, _x), do: []

  # The ids of `schema` rows `x` may reference: the site's, their own, those shared to them.
  defp usable(schema, x) do
    own = from(r in schema, where: is_nil(r.user_id) or r.user_id == ^x, select: r.id)

    case Items.type_of(schema) do
      nil -> own
      type -> from(r in own, or_where: r.id in subquery(Mythweaver.Sharing.granted_ids(x, type, [:edit, :use])))
    end
  end
end
