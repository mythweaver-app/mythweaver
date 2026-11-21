defmodule Mythweaver.Sharing.Items do
  @moduledoc """
  The item types sharing knows. Root types are shared on their own (they carry a Share panel); grant
  types are those plus what travels only inside a closure (lore entries and pools, expression
  profiles). Part types (lore entries and pools) take the share's own access, so an editor of a book
  edits and deletes them.

  A subscriber's `/shared` card (`card/2`) shows each row's `fields/1` always and its
  `protected_fields/1` only when the viewer may read them (`Mythweaver.Sharing.readable?/2`).
  """

  import Ecto.Query

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.AI
  alias Mythweaver.Characters
  alias Mythweaver.Characters.Character
  alias Mythweaver.Expressions
  alias Mythweaver.Lore
  alias Mythweaver.Lore.LoreBook
  alias Mythweaver.Lore.LoreEntry
  alias Mythweaver.Lore.LorePool
  alias Mythweaver.Memory
  alias Mythweaver.Prompts.Block
  alias Mythweaver.Prompts.Outlet
  alias Mythweaver.Prompts.Prompt
  alias Mythweaver.Prompts.PromptBlock
  alias Mythweaver.Repo
  alias Mythweaver.Scripts
  alias Mythweaver.Scripts.Script
  alias Mythweaver.Sharing
  alias Mythweaver.Sharing.Visibility
  alias Mythweaver.Tags

  @type root_type ::
          :character
          | :lore_book
          | :prompt
          | :block
          | :outlet
          | :script
          | :memory_profile
          | :side_prompt
          | :side_prompt_set
          | :ai_model
  @type type :: root_type() | :lore_entry | :lore_pool | :expression_profile

  @root_types [
    :character,
    :lore_book,
    :prompt,
    :block,
    :outlet,
    :script,
    :memory_profile,
    :side_prompt,
    :side_prompt_set,
    :ai_model
  ]
  @part_types [:lore_entry, :lore_pool]
  @grant_types @root_types ++ @part_types ++ [:expression_profile]

  @schemas %{
    ai_model: AI.Model,
    character: Character,
    lore_book: LoreBook,
    lore_entry: LoreEntry,
    lore_pool: LorePool,
    prompt: Prompt,
    block: Block,
    outlet: Outlet,
    script: Script,
    memory_profile: Memory.Profile,
    side_prompt: Memory.SidePrompt,
    side_prompt_set: Memory.SidePromptSet,
    expression_profile: Expressions.Profile
  }

  @types Map.new(@schemas, fn {type, schema} -> {schema, type} end)

  @doc "Types shared on their own."
  @spec root_types() :: [root_type()]
  def root_types, do: @root_types

  @doc "Types that take the share's own access (an editor edits and deletes them)."
  @spec part_types() :: [type()]
  def part_types, do: @part_types

  @doc "Every type a grant may name."
  @spec grant_types() :: [type()]
  def grant_types, do: @grant_types

  @doc "The schema of `type`."
  @spec schema(type()) :: module()
  def schema(type), do: Map.fetch!(@schemas, type)

  @doc "The type of a schema module or struct, or nil for one sharing does not know."
  @spec type_of(module() | struct()) :: type() | nil
  def type_of(%schema{}), do: type_of(schema)
  def type_of(schema) when is_atom(schema), do: Map.get(@types, schema)

  @doc "Whether `type` is shared on its own."
  @spec root?(term()) :: boolean()
  def root?(type), do: type in @root_types

  @doc "The `Mythweaver.Changes` kind writes to `type` announce."
  @spec kind(type()) :: Mythweaver.Changes.kind()
  def kind(type) when type in [:character, :expression_profile], do: :characters
  def kind(type) when type in [:lore_book, :lore_entry, :lore_pool], do: :lore
  def kind(type) when type in [:prompt, :block, :outlet], do: :prompts
  def kind(:script), do: :scripts
  def kind(type) when type in [:memory_profile, :side_prompt, :side_prompt_set], do: :memory
  def kind(:ai_model), do: :ai

  @doc "Every kind a shared item may announce."
  @spec kinds() :: [Mythweaver.Changes.kind()]
  def kinds, do: [:characters, :lore, :prompts, :scripts, :memory, :ai]

  @doc ~S|How `type` reads in a sentence: "the character".|
  @spec noun(root_type()) :: String.t()
  def noun(:character), do: "the character"
  def noun(:lore_book), do: "the lore book"
  def noun(:prompt), do: "the prompt"
  def noun(:block), do: "the prompt block"
  def noun(:outlet), do: "the outlet"
  def noun(:script), do: "the script"
  def noun(:memory_profile), do: "the memory profile"
  def noun(:side_prompt), do: "the side prompt"
  def noun(:side_prompt_set), do: "the side prompt set"
  def noun(:ai_model), do: "the AI model"

  @doc "The editor page of a root item."
  @spec edit_path(root_type(), Ecto.UUID.t()) :: String.t()
  def edit_path(:character, id), do: "/characters/#{id}/edit"
  def edit_path(:lore_book, id), do: "/lore/#{id}/edit"
  def edit_path(:prompt, id), do: "/prompts/#{id}/edit"
  def edit_path(:block, id), do: "/prompts/blocks/#{id}/edit"
  def edit_path(:outlet, id), do: "/prompts/outlets/#{id}/edit"
  def edit_path(:script, id), do: "/scripts/#{id}/edit"
  def edit_path(:memory_profile, id), do: "/memory/profiles/#{id}/edit"
  def edit_path(:side_prompt, id), do: "/memory/side-prompts/#{id}/edit"
  def edit_path(:side_prompt_set, id), do: "/memory/side-prompt-sets/#{id}/edit"
  def edit_path(:ai_model, id), do: "/ai/models/#{id}/edit"

  @doc "The item of `type` with `id`, unscoped, or nil."
  @spec get(type(), Ecto.UUID.t()) :: struct() | nil
  def get(type, id), do: Repo.get(schema(type), id)

  @doc """
  What a share's card always shows of a `type` row. `:avatar`, `:tags`, a book's `:entries` (each
  showing `fields(:lore_entry)`) and a prompt's `:blocks` (each showing `fields(:block)`) are not
  plain fields; `card/2` loads them.
  """
  @spec fields(type()) :: [atom()]
  def fields(:character),
    do: [:name, :avatar, :creator, :creator_notes, :character_version, :pronouns, :tags, :talkativeness]

  def fields(:lore_book), do: [:name, :description, :entries]
  def fields(:lore_entry), do: [:name]
  def fields(:prompt), do: [:name, :description, :blocks]
  def fields(:block), do: [:name, :description, :role, :enabled]
  def fields(:outlet), do: [:key, :name, :description]
  def fields(:script), do: [:name, :description, :trigger]
  def fields(type) when type in [:memory_profile, :side_prompt, :side_prompt_set], do: [:name]

  def fields(:ai_model),
    do: [
      :name,
      :completion_mode,
      :context_window,
      :supports_images,
      :supports_files,
      :supports_audio,
      :supports_video,
      :supports_tools,
      :supports_thinking,
      :prompt_cost_per_mtok,
      :completion_cost_per_mtok
    ]

  @doc "The fields of a `type` row a Runtime-only viewer never sees."
  @spec protected_fields(type()) :: [atom()]
  def protected_fields(:character), do: [:description, :appearance]
  def protected_fields(:lore_entry), do: [:content, :keywords, :secondary_keywords]
  def protected_fields(:block), do: [:content]
  def protected_fields(:script), do: [:body]
  def protected_fields(:ai_model), do: AI.Model.protected_fields()
  def protected_fields(_type), do: []

  @doc """
  What a share's card shows of the root `item` to `scope`: the `item` (a character with its avatar
  loaded), whether `scope` may read its protected fields (`readable?`), the `tags` `scope` sees on a
  character, the `parts` in order (a book's entries, a prompt's blocks), each `{row, readable?}`,
  a script's `capabilities` (`Mythweaver.Scripts.capabilities/1`, shown even when its body is not),
  and `switches`: the scope user's state of each togglable row by id (`Mythweaver.Sharing.set_toggle/3`)
  (`true`/`false`, or `:forced` for an entry of a forced site book). Their own rows take none.
  `consent_changed?` is true for a shared script the user enabled that changed since
  (its toggle's `consent_hash` no longer `Script.consent_hash/1`); its switch then reads `false`.
  """
  @spec card(Scope.t(), struct()) :: %{
          item: struct(),
          readable?: boolean(),
          tags: [String.t()],
          parts: [{struct(), boolean()}],
          capabilities: [String.t()],
          switches: %{Ecto.UUID.t() => boolean() | :forced},
          consent_changed?: boolean()
        }
  def card(%Scope{} = scope, item) do
    uid = scope.user && scope.user.id

    card(type_of(item), scope, %{
      item: item,
      readable?: Sharing.readable?(uid, item),
      tags: [],
      parts: [],
      capabilities: [],
      switches: %{},
      consent_changed?: false
    })
  end

  defp card(:character, scope, %{item: character} = card) do
    %{site: site, mine: mine} = Tags.item_tags(scope, character)
    %{card | item: Characters.preload_avatar(scope, character), tags: site ++ mine}
  end

  defp card(:lore_book, scope, %{item: book} = card) do
    entries = Lore.list_entries_in_book(scope, book)
    ids = Enum.map(entries, & &1.id)

    readable =
      from(e in LoreEntry, where: e.id in ^ids, select: e.id)
      |> Visibility.readable_entries(scope)
      |> Repo.all()
      |> MapSet.new()

    forced = Sharing.forced_entries(ids)
    switches = switches(scope, :lore_entry, entries, fn _row -> true end)
    switches = Map.new(switches, fn {id, on?} -> {id, if(MapSet.member?(forced, id), do: :forced, else: on?)} end)
    %{card | parts: Enum.map(entries, &{&1, MapSet.member?(readable, &1.id)}), switches: switches}
  end

  defp card(:prompt, scope, %{item: prompt} = card) do
    prompt = Repo.preload(prompt, prompt_blocks: {from(pb in PromptBlock, order_by: [asc: pb.position]), :block})
    blocks = Enum.map(prompt.prompt_blocks, & &1.block)
    parts = Enum.map(blocks, &{&1, not Visibility.block_hidden_for?(scope, &1, prompt)})
    %{card | item: prompt, parts: parts, switches: switches(scope, :block, blocks, fn _row -> true end)}
  end

  defp card(:block, scope, %{item: block} = card),
    do: %{card | switches: switches(scope, :block, [block], fn _row -> true end)}

  defp card(:script, scope, %{item: script} = card) do
    {switches, changed?} = script_switch(scope.user && scope.user.id, script)
    %{card | capabilities: Scripts.capabilities(script.body), switches: switches, consent_changed?: changed?}
  end

  defp card(_type, _scope, card), do: card

  # The scope user's toggle state of each of `rows` they don't own, `default.(row)` when untoggled.
  defp switches(scope, type, rows, default) do
    uid = scope.user && scope.user.id
    rows = Enum.reject(rows, &(is_nil(uid) or &1.user_id == uid))
    toggles = Sharing.toggles(uid, type, Enum.map(rows, & &1.id))
    Map.new(rows, &{&1.id, Map.get(toggles, &1.id, default.(&1))})
  end

  # A script's `switches` and `consent_changed?`, from one toggle read: a site script runs until
  # switched off; a shared one only once switched on, and only while unchanged since (the toggle's
  # consent hash is still `Script.consent_hash/1`), else its switch reads off.
  defp script_switch(uid, %Script{user_id: owner_id}) when is_nil(uid) or owner_id == uid, do: {%{}, false}

  defp script_switch(uid, %Script{id: id} = script) do
    shared? = is_binary(script.user_id)
    current = Script.consent_hash(script)

    case Sharing.script_toggle(uid, script) do
      nil -> {%{id => not shared?}, false}
      {true, hash} when shared? and hash != current -> {%{id => false}, true}
      {enabled, _hash} -> {%{id => enabled}, false}
    end
  end

  @doc "The types each `MythweaverWeb.ContentAccess` area edits."
  @spec areas() :: %{atom() => [type()]}
  def areas do
    %{
      characters: [:character],
      lore: [:lore_book, :lore_entry, :lore_pool],
      prompts: [:prompt, :block, :outlet],
      scripts: [:script],
      memory: [:memory_profile, :side_prompt, :side_prompt_set]
    }
  end
end
