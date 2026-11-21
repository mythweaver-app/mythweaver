defmodule Mythweaver.Sharing.Fallout do
  @moduledoc """
  What a user's own content loses with rows no share grants them any more (`Mythweaver.Sharing`
  ends a share): every reference of *exactly that user's* chats and rows to the lost rows. The shape
  is `Mythweaver.Lore.Transfer`'s `{kind, query, action}` list, aimed at one user instead of "every
  owner but the new one".

  A lost character leaves the user's chats the way a deleted one would (`Chats.detach_characters/2`):
  its messages stay under its name, and the user's books' activation rule conditions naming it lose
  their target. Nothing is copied. A side prompt whose prompt is lost is deleted,
  as the prompt's own deletion would; every other reference is cleared or dropped. A lost AI model
  leaves the user's chats, participants, memory profiles, settings and caption models naming none,
  and their own connections' links to it are deleted.
  """

  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Query

  alias Mythweaver.AI
  alias Mythweaver.Characters.Character
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Chats.Participant
  alias Mythweaver.Format
  alias Mythweaver.Lore.BookCharacter
  alias Mythweaver.Lore.BookChat
  alias Mythweaver.Lore.BookRule
  alias Mythweaver.Lore.BookRuleCondition
  alias Mythweaver.Lore.EntryCharacter
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Memory.CharacterBook
  alias Mythweaver.Memory.ChatSettings
  alias Mythweaver.Memory.Profile
  alias Mythweaver.Memory.SidePrompt
  alias Mythweaver.Memory.SidePromptSet
  alias Mythweaver.Memory.SidePromptSetRow
  alias Mythweaver.Memory.TopicSuggestion
  alias Mythweaver.Notifications.Notification
  alias Mythweaver.Prompts.Binding
  alias Mythweaver.Prompts.Prompt
  alias Mythweaver.Prompts.PromptBlock
  alias Mythweaver.Repo
  alias Mythweaver.Scripts.Script
  alias Mythweaver.Settings.Setting
  alias Mythweaver.Sharing.Toggle
  alias Mythweaver.Tags.Tag
  alias Mythweaver.Tags.Tagging

  @set_settings ["memory.side_prompt_set_solo", "memory.side_prompt_set_group"]
  @model_settings ["ai.default_model", "images.default_caption_model"]

  @typedoc "Lost row ids by type, as `Mythweaver.Sharing` groups them."
  @type lost :: %{optional(atom()) => [Ecto.UUID.t()]}

  @doc "How many rows each kind would touch, zeros dropped."
  @spec impact(Ecto.UUID.t(), lost()) :: %{atom() => pos_integer()}
  def impact(_user_id, lost) when map_size(lost) == 0, do: %{}

  def impact(user_id, lost) do
    user_id
    |> plan(lost)
    |> Enum.map(fn {kind, query, action} -> {kind, count(query, action, lost)} end)
    |> Enum.reject(fn {kind, n} -> n == 0 or kind in [:notifications, :toggles] end)
    |> Map.new()
  end

  @doc "Applies every kind; run inside the caller's transaction. Returns the ids of chats it changed."
  @spec run(Ecto.UUID.t(), lost()) :: [Ecto.UUID.t()]
  def run(_user_id, lost) when map_size(lost) == 0, do: []

  def run(user_id, lost) do
    user_id
    |> plan(lost)
    |> Enum.flat_map(fn {_kind, query, action} -> apply_action(user_id, query, action, lost) end)
    |> Enum.uniq()
  end

  @doc """
  The counted impact phrase of a kind (`"3 chat participants"`), for the owner's confirmation.
  Built in the caller's locale.
  """
  @spec label(atom(), non_neg_integer()) :: String.t()
  def label(:participants, n) do
    dpngettext(
      "sharing",
      "unit: chat participants a lost share removes",
      "%{participant_count} chat participant",
      "%{participant_count} chat participants",
      n,
      participant_count: Format.number(n)
    )
  end

  def label(:chat_models, n) do
    dpngettext(
      "sharing",
      "unit: chats whose model a lost share clears",
      "%{chat_count} chat's model",
      "%{chat_count} chats' models",
      n,
      chat_count: Format.number(n)
    )
  end

  def label(:participant_models, n) do
    dpngettext(
      "sharing",
      "unit: chat participants whose model a lost share clears",
      "%{participant_count} chat participant's model",
      "%{participant_count} chat participants' models",
      n,
      participant_count: Format.number(n)
    )
  end

  def label(:profile_models, n) do
    dpngettext(
      "sharing",
      "unit: memory profiles whose model a lost share clears",
      "%{profile_count} memory profile's model",
      "%{profile_count} memory profiles' models",
      n,
      profile_count: Format.number(n)
    )
  end

  def label(:caption_models, n) do
    dpngettext(
      "sharing",
      "unit: AI models whose caption model a lost share clears",
      "%{model_count} AI model caption model",
      "%{model_count} AI model caption models",
      n,
      model_count: Format.number(n)
    )
  end

  def label(:model_links, n) do
    dpngettext(
      "sharing",
      "unit: links from AI connections a lost share deletes",
      "%{link_count} AI connection link",
      "%{link_count} AI connection links",
      n,
      link_count: Format.number(n)
    )
  end

  def label(:character_bindings, n) do
    dpngettext(
      "sharing",
      "unit: lore book character bindings a lost share deletes",
      "%{binding_count} lore book character binding",
      "%{binding_count} lore book character bindings",
      n,
      binding_count: Format.number(n)
    )
  end

  def label(:entry_filters, n) do
    dpngettext(
      "sharing",
      "unit: lore entry character filters a lost share deletes",
      "%{filter_count} entry character filter",
      "%{filter_count} entry character filters",
      n,
      filter_count: Format.number(n)
    )
  end

  def label(:rule_conditions, n) do
    dpngettext(
      "sharing",
      "unit: lore book activation rule conditions a lost share clears",
      "%{condition_count} lore book activation rule condition",
      "%{condition_count} lore book activation rule conditions",
      n,
      condition_count: Format.number(n)
    )
  end

  def label(:character_locks, n) do
    dpngettext(
      "sharing",
      "unit: character memory book links a lost share deletes",
      "%{book_count} character memory book",
      "%{book_count} character memory books",
      n,
      book_count: Format.number(n)
    )
  end

  def label(:chat_bindings, n) do
    dpngettext(
      "sharing",
      "unit: chat lore book bindings a lost share deletes",
      "%{binding_count} chat lore binding",
      "%{binding_count} chat lore bindings",
      n,
      binding_count: Format.number(n)
    )
  end

  def label(:memory_settings, n) do
    dpngettext(
      "sharing",
      "unit: chats whose memory settings a lost share changes",
      "%{chat_count} chat's memory settings",
      "%{chat_count} chats' memory settings",
      n,
      chat_count: Format.number(n)
    )
  end

  def label(:topic_suggestions, n) do
    dpngettext(
      "sharing",
      "unit: memory topic suggestions a lost share deletes",
      "%{suggestion_count} topic suggestion",
      "%{suggestion_count} topic suggestions",
      n,
      suggestion_count: Format.number(n)
    )
  end

  def label(:side_prompt_targets, n) do
    dpngettext(
      "sharing",
      "unit: side prompts whose target book a lost share clears",
      "%{book_count} side prompt target book",
      "%{book_count} side prompt target books",
      n,
      book_count: Format.number(n)
    )
  end

  def label(:side_prompt_profiles, n) do
    dpngettext(
      "sharing",
      "unit: side prompts whose memory profile a lost share clears",
      "%{profile_count} side prompt profile",
      "%{profile_count} side prompt profiles",
      n,
      profile_count: Format.number(n)
    )
  end

  def label(:side_prompts, n) do
    dpngettext(
      "sharing",
      "unit: side prompts a lost share deletes",
      "%{side_prompt_count} side prompt",
      "%{side_prompt_count} side prompts",
      n,
      side_prompt_count: Format.number(n)
    )
  end

  def label(:profiles, n) do
    dpngettext(
      "sharing",
      "unit: memory profiles whose prompts a lost share clears",
      "%{profile_count} memory profile's prompts",
      "%{profile_count} memory profiles' prompts",
      n,
      profile_count: Format.number(n)
    )
  end

  def label(:caption_prompts, n) do
    dpngettext(
      "sharing",
      "unit: AI models whose caption prompt a lost share clears",
      "%{prompt_count} AI model caption prompt",
      "%{prompt_count} AI model caption prompts",
      n,
      prompt_count: Format.number(n)
    )
  end

  def label(:prompt_bindings, n) do
    dpngettext(
      "sharing",
      "unit: prompt bindings a lost share deletes",
      "%{binding_count} prompt binding",
      "%{binding_count} prompt bindings",
      n,
      binding_count: Format.number(n)
    )
  end

  def label(:prompt_blocks, n) do
    dpngettext(
      "sharing",
      "unit: blocks placed in prompts that a lost share removes",
      "%{block_count} block in a prompt",
      "%{block_count} blocks in prompts",
      n,
      block_count: Format.number(n)
    )
  end

  def label(:script_dependencies, n) do
    dpngettext(
      "sharing",
      "unit: script dependencies a lost share deletes",
      "%{dependency_count} script dependency",
      "%{dependency_count} script dependencies",
      n,
      dependency_count: Format.number(n)
    )
  end

  def label(:side_prompt_rows, n) do
    dpngettext(
      "sharing",
      "unit: side prompt set rows a lost share deletes",
      "%{row_count} side prompt set row",
      "%{row_count} side prompt set rows",
      n,
      row_count: Format.number(n)
    )
  end

  def label(:settings, n) do
    dpngettext(
      "sharing",
      "unit: default settings a lost share clears",
      "%{setting_count} default setting",
      "%{setting_count} default settings",
      n,
      setting_count: Format.number(n)
    )
  end

  def label(:expression_profiles, n) do
    dpngettext(
      "sharing",
      "unit: characters whose expression profile a lost share clears",
      "%{character_count} character's expression profile",
      "%{character_count} characters' expression profiles",
      n,
      character_count: Format.number(n)
    )
  end

  def label(:taggings, n) do
    dpngettext("sharing", "unit: tags a lost share removes from items", "%{tag_count} tag", "%{tag_count} tags", n,
      tag_count: Format.number(n)
    )
  end

  defp plan(x, lost) do
    c = ids(lost, :character)
    b = ids(lost, :lore_book)
    e = ids(lost, :lore_entry)
    pr = ids(lost, :prompt)
    bl = ids(lost, :block)
    s = ids(lost, :script)
    mp = ids(lost, :memory_profile)
    sp = ids(lost, :side_prompt)
    ep = ids(lost, :expression_profile)
    m = ids(lost, :ai_model)

    chats = mine(Chat, x)
    characters = mine(Character, x)
    books = mine(LoreBook, x)
    book_rules = from(r in BookRule, where: r.lore_book_id in subquery(books), select: r.id)
    prompts = mine(Prompt, x)

    [
      {:participants, from(p in Participant, where: p.chat_id in subquery(chats) and p.character_id in ^c), :detach},
      {:chat_models, from(ch in Chat, where: ch.user_id == ^x and ch.ai_model_id in ^m), {:set_chats, :id}},
      {:participant_models, from(p in Participant, where: p.chat_id in subquery(chats) and p.ai_model_id in ^m),
       {:set_chats, :chat_id}},
      {:profile_models, from(p in Profile, where: p.user_id == ^x and p.ai_model_id in ^m), {:set, ai_model_id: nil}},
      {:caption_models, from(md in AI.Model, where: md.user_id == ^x and md.caption_model_id in ^m),
       {:set, caption_model_id: nil}},
      {:model_links,
       from(pm in AI.ProviderModel, where: pm.ai_model_id in ^m and pm.provider_id in subquery(mine(AI.Provider, x))),
       :delete},
      {:character_bindings,
       from(bc in BookCharacter,
         where:
           (bc.character_id in ^c and bc.lore_book_id in subquery(books)) or
             (bc.lore_book_id in ^b and bc.character_id in subquery(characters))
       ), :delete},
      {:entry_filters,
       from(ec in EntryCharacter, where: ec.character_id in ^c and ec.lore_entry_id in subquery(mine(LoreEntry, x))),
       :delete},
      {:rule_conditions,
       from(rc in BookRuleCondition, where: rc.lore_book_rule_id in subquery(book_rules) and rc.character_id in ^c),
       {:set, character_id: nil}},
      {:character_locks,
       from(l in CharacterBook, where: l.user_id == ^x and (l.character_id in ^c or l.lore_book_id in ^b)), :delete},
      {:chat_bindings, from(bc in BookChat, where: bc.chat_id in subquery(chats) and bc.lore_book_id in ^b), :delete},
      {:memory_settings, from(st in ChatSettings, where: st.chat_id in subquery(chats)), :memory_settings},
      {:topic_suggestions, from(t in TopicSuggestion, where: t.chat_id in subquery(chats) and t.lore_book_id in ^b),
       :delete},
      {:side_prompt_targets, from(sp in SidePrompt, where: sp.user_id == ^x and sp.target_book_id in ^b),
       {:set, target_book_id: nil}},
      {:side_prompt_profiles, from(sp in SidePrompt, where: sp.user_id == ^x and sp.profile_id in ^mp),
       {:set, profile_id: nil}},
      {:side_prompts, from(sp in SidePrompt, where: sp.user_id == ^x and sp.prompt_id in ^pr), :delete},
      {:profiles, from(p in Profile, where: p.user_id == ^x, where: ^any_prompt(pr)), :clear_prompts},
      {:caption_prompts, from(m in AI.Model, where: m.user_id == ^x and m.caption_prompt_id in ^pr),
       {:set, caption_prompt_id: nil}},
      {:prompt_bindings,
       from(bd in Binding,
         where:
           (bd.prompt_id in ^pr and
              (bd.chat_id in subquery(chats) or bd.character_id in subquery(characters) or
                 bd.ai_model_id in subquery(mine(AI.Model, x)) or bd.provider_id in subquery(mine(AI.Provider, x)))) or
             (bd.character_id in ^c and bd.prompt_id in subquery(prompts)) or
             (bd.ai_model_id in ^m and bd.prompt_id in subquery(prompts))
       ), :delete},
      {:prompt_blocks, from(pb in PromptBlock, where: pb.prompt_id in subquery(prompts) and pb.block_id in ^bl),
       :delete},
      {:script_dependencies,
       from(d in "script_dependencies",
         where: d.script_id in subquery(mine(Script, x)) and d.dependency_id in type(^s, {:array, Ecto.UUID})
       ), :delete},
      {:side_prompt_rows,
       from(r in SidePromptSetRow,
         where: r.side_prompt_set_id in subquery(mine(SidePromptSet, x)) and r.side_prompt_id in ^sp
       ), :delete},
      {:settings, from(st in Setting, where: st.user_id == ^x), :settings},
      {:expression_profiles, from(ch in Character, where: ch.user_id == ^x and ch.expression_profile_id in ^ep),
       {:set, expression_profile_id: nil}},
      {:taggings,
       from(tg in Tagging,
         where: tg.tag_id in subquery(mine(Tag, x)),
         where:
           tg.character_id in ^c or tg.lore_book_id in ^b or tg.lore_entry_id in ^e or tg.prompt_id in ^pr or
             tg.prompt_block_id in ^bl or tg.script_id in ^s or tg.ai_model_id in ^m
       ), :delete},
      {:notifications, from(n in Notification, where: n.user_id == ^x and n.lore_book_id in ^b), :delete},
      {:toggles,
       from(t in Toggle,
         where:
           t.user_id == ^x and
             ((t.item_type == :lore_entry and t.item_id in ^e) or (t.item_type == :block and t.item_id in ^bl) or
                (t.item_type == :script and t.item_id in ^s))
       ), :delete}
    ]
  end

  defp ids(lost, type), do: Map.get(lost, type, [])

  defp mine(schema, x), do: from(r in schema, where: r.user_id == ^x, select: r.id)

  defp any_prompt(pr) do
    Enum.reduce(Profile.prompt_purposes(), dynamic(false), fn {field, _purpose}, acc ->
      dynamic([p], ^acc or field(p, ^field) in ^pr)
    end)
  end

  defp count(query, :memory_settings, lost), do: Enum.count(Repo.all(query), &scrub(&1, lost))
  defp count(query, :settings, lost), do: Enum.count(Repo.all(query), &settings_scrub(&1, lost))
  defp count(query, _action, _lost), do: Repo.aggregate(query, :count)

  defp apply_action(x, _query, :detach, lost) do
    characters = Repo.all(from(c in Character, where: c.id in ^ids(lost, :character)))
    Chats.detach_characters(x, characters)
  end

  defp apply_action(_x, query, :delete, _lost) do
    Repo.delete_all(query)
    []
  end

  defp apply_action(_x, query, {:set_chats, chat_field}, _lost) do
    chat_ids = Repo.all(from(r in query, select: field(r, ^chat_field), distinct: true))
    Repo.update_all(query, set: [ai_model_id: nil])
    chat_ids
  end

  defp apply_action(_x, query, {:set, set}, _lost) do
    Repo.update_all(query, set: set)
    []
  end

  defp apply_action(x, _query, :clear_prompts, lost) do
    pr = ids(lost, :prompt)

    for {field, _purpose} <- Profile.prompt_purposes() do
      Repo.update_all(from(p in Profile, where: p.user_id == ^x and field(p, ^field) in ^pr), set: [{field, nil}])
    end

    []
  end

  defp apply_action(_x, query, :memory_settings, lost) do
    for settings <- Repo.all(query), changes = scrub(settings, lost), changes do
      Repo.update_all(from(s in ChatSettings, where: s.id == ^settings.id), set: changes)
      settings.chat_id
    end
  end

  defp apply_action(_x, query, :settings, lost) do
    for setting <- Repo.all(query), values = settings_scrub(setting, lost), values do
      Repo.update_all(from(s in Setting, where: s.id == ^setting.id), set: [values: values])
    end

    []
  end

  # The chat settings' new values when a lost row is named, else nil.
  defp scrub(%ChatSettings{} = s, lost) do
    books = ids(lost, :lore_book)
    characters = ids(lost, :character)
    side_prompts = ids(lost, :side_prompt)

    changes = [
      memory_book_id: if(s.memory_book_id not in books, do: s.memory_book_id),
      profile_id: if(s.profile_id not in ids(lost, :memory_profile), do: s.profile_id),
      side_prompt_set_id: if(s.side_prompt_set_id not in ids(lost, :side_prompt_set), do: s.side_prompt_set_id),
      side_prompt_book_ids:
        Map.reject(s.side_prompt_book_ids, fn {key, value} -> key in side_prompts or value in books end),
      character_book_ids: Map.reject(s.character_book_ids, fn {key, value} -> key in characters or value in books end),
      context_entry_ids: s.context_entry_ids -- ids(lost, :lore_entry),
      cast_ids: s.cast_ids -- characters
    ]

    if Enum.any?(changes, fn {field, value} -> Map.fetch!(s, field) != value end), do: changes
  end

  defp settings_scrub(%Setting{values: values}, lost) do
    sets = Enum.map(ids(lost, :side_prompt_set), &to_string/1)
    models = Enum.map(ids(lost, :ai_model), &to_string/1)

    kept =
      Map.reject(values || %{}, fn {key, value} ->
        (key in @set_settings and value in sets) or (key in @model_settings and value in models)
      end)

    if map_size(kept) != map_size(values || %{}), do: kept
  end
end
