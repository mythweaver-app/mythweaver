defmodule Mythweaver.Import do
  @moduledoc """
  Imports SillyTavern characters, chats, lore books and Chat Completion presets, plus Character
  Card V1/V2/V3 files (PNG, JSON, CHARX), onto the existing schemas.

  Importing is two steps: `parse/2` is pure (no Repo, no scope) and detects the file type, and
  `import/3` writes a parsed file for a scope.

  ## Detection

  By lowercased extension: `.png` (card in a `ccv3` or `chara` `tEXt` chunk, `ccv3` preferred;
  the PNG becomes the avatar), `.charx` (zip with `card.json`; the main icon asset becomes the
  avatar), `.jsonl` (chat), `.json` sniffed as a character card, then a lore book (`entries`), then
  a preset (`prompts` / `prompt_order`). Text-completion presets and other apps' files are
  recognized and rejected with a message saying so. `.mythweaver` is a native bundle
  (`Mythweaver.Bundle.decode/1`), reviewed per item (`Mythweaver.Import.Review`) and written by
  `Mythweaver.Import.BundleWriter`.

  ## Mapping

  * Text that goes through `Mythweaver.Templates.validate/2` (character description, lore entry
    content, block content) is converted from ST macros by `Mythweaver.Import.Macros`; macros with
    no equivalent stay literal and are listed in one warning. Names, keywords, creator notes and
    chat message text are never converted.
  * **Character** (`Mythweaver.Import.Card`): name, description, creator, creator notes, version and
    talkativeness map to columns. System prompt, personality, scenario, example dialogue,
    post-history instructions and the depth prompt become constant entries for a "(card)" lore
    book (`card_fields`); the card's `character_book` becomes its own book. Greetings, tags and other
    fields are dropped.
  * **Lore book** (`Mythweaver.Import.WorldInfo`): ST's `position` maps onto `LoreEntry`'s
    `outlet` + `placement` (see that module's table); `order` and `disable` go on the membership.
    SillyTavern-MemoryBooks entries (`stmemorybooks: true`, or `extensions.stmemorybooks` in a
    card's `character_book`) are adopted as memories of their book (`Mythweaver.Memory.adopt_memories/3`),
    with no chat or message range, so they can't be regenerated. Its summaries (`stmbSummary` with
    `stmbSummaryTier`, or a legacy arc) become consolidations of that tier, linked to their sources.
  * **Chat** (`Mythweaver.Import.Chat`): speakers are matched to characters in a review step;
    swipes become bodies, `is_system` hides a message from the AI.
  * **Preset** (`Mythweaver.Import.Preset`): prompts become blocks in `prompt_order` order, marker
    prompts become Mythweaver's standard blocks, and sampler values can be written onto a model.
  """

  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Changes
  alias Mythweaver.Import.Bundle
  alias Mythweaver.Import.Card
  alias Mythweaver.Import.Charx
  alias Mythweaver.Import.Chat
  alias Mythweaver.Import.Embedded
  alias Mythweaver.Import.Png
  alias Mythweaver.Import.Preset
  alias Mythweaver.Import.TaskSupervisor
  alias Mythweaver.Import.Text
  alias Mythweaver.Import.WorldInfo
  alias Mythweaver.Import.Writer
  alias Mythweaver.Moderation.Gate
  alias Mythweaver.Moderation.Hold

  @typedoc """
  A parsed file. Every shape carries `warnings`; all template text is already macro-converted.
  """
  @type parsed ::
          character()
          | lore_book()
          | chat()
          | preset()
          | bundle()

  @type character :: %{
          kind: :character,
          name: String.t(),
          description: String.t() | nil,
          creator: String.t() | nil,
          creator_notes: String.t() | nil,
          character_version: String.t() | nil,
          talkativeness: float() | nil,
          system_prompt: String.t() | nil,
          post_history_instructions: String.t() | nil,
          world: String.t() | nil,
          tags: [String.t()],
          foreign: map(),
          source_file: String.t(),
          card_fields: [WorldInfo.entry_spec()],
          book: WorldInfo.book_spec() | nil,
          avatar: binary() | nil,
          warnings: [String.t()]
        }

  @type lore_book :: %{
          kind: :lore_book,
          name: String.t(),
          book: map(),
          entries: [WorldInfo.entry_spec()],
          warnings: [String.t()]
        }

  @type chat :: %{
          kind: :chat,
          name: String.t(),
          player_name: String.t() | nil,
          speakers: [Chat.speaker()],
          messages: [Chat.message()],
          warnings: [String.t()]
        }

  @type preset :: %{
          kind: :preset,
          name: String.t(),
          blocks: [Preset.block()],
          sampler: map(),
          ignored: [String.t()],
          warnings: [String.t()]
        }

  @type bundle :: %{
          kind: :bundle,
          name: String.t() | nil,
          bundle: Mythweaver.Bundle.t(),
          warnings: [String.t()]
        }

  @spec unrecognized() :: String.t()
  defp unrecognized,
    do: dpgettext("import_export", "status: import error, the file's type is not recognized", "Unrecognized file.")

  @parse_timeout 120_000

  @doc """
  Detects and parses an uploaded file by its name and bytes, parsed in its own process capped at
  2 GiB (unzipped and decompressed binaries included) and 2 minutes, so a hostile file cannot
  exhaust the server's memory or hang it. The cap is `config :mythweaver, Mythweaver.Import,
  max_parse_bytes: …`, read at call time.
  """
  @spec parse(String.t(), binary()) :: {:ok, parsed()} | {:error, String.t()}
  def parse(filename, bytes) do
    task =
      Task.Supervisor.async_nolink(
        TaskSupervisor,
        Mythweaver.Locale.carry(fn ->
          Process.flag(:max_heap_size, %{
            size: div(max_parse_bytes(), :erlang.system_info(:wordsize)),
            kill: true,
            error_logger: false,
            include_shared_binaries: true
          })

          do_parse(filename, bytes)
        end)
      )

    case Task.yield(task, @parse_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, :killed} -> {:error, dgettext("import_export", "This file is too large to import.")}
      {:exit, _reason} -> {:error, dgettext("import_export", "This file couldn't be read.")}
      nil -> {:error, dgettext("import_export", "This file took too long to read.")}
    end
  end

  defp max_parse_bytes,
    do: Keyword.get(Application.get_env(:mythweaver, Mythweaver.Import, []), :max_parse_bytes, 2 * 1024 ** 3)

  defp do_parse(filename, bytes) do
    result =
      filename
      |> Path.extname()
      |> String.downcase()
      |> case do
        ".png" -> Png.card(bytes)
        ".charx" -> Charx.card(bytes)
        ".jsonl" -> Chat.parse(bytes, filename)
        ".mythweaver" -> Bundle.parse(bytes)
        ".json" -> parse_json(bytes, Text.stem(filename))
        _other -> {:error, unrecognized()}
      end

    # A card's file name is what SillyTavern character filters name it by.
    with {:ok, parsed} <- result do
      parsed = if parsed.kind == :character, do: Map.put(parsed, :source_file, Text.stem(filename)), else: parsed
      {:ok, finalize(parsed)}
    end
  end

  defp parse_json(bytes, stem) do
    case Jason.decode(bytes) do
      {:ok, json} when is_map(json) -> sniff(json, stem)
      {:ok, _other} -> {:error, unrecognized()}
      {:error, _} -> {:error, dgettext("import_export", "This file isn't valid JSON.")}
    end
  end

  defp sniff(json, stem) do
    cond do
      character?(json) ->
        Card.normalize(json)

      is_map(json["entries"]) or is_list(json["entries"]) ->
        book = WorldInfo.normalize(json, stem)
        {:ok, Map.put(book, :embedded, Embedded.extract(json["extensions"]))}

      is_list(json["prompts"]) or is_list(json["prompt_order"]) ->
        Preset.parse(json, stem)

      Enum.any?(~w(temp rep_pen story_string input_sequence system_sequence), &Map.has_key?(json, &1)) ->
        {:error,
         dgettext(
           "import_export",
           "Only SillyTavern Chat Completion presets can be imported; this looks like a text-completion preset or template."
         )}

      other_app?(json) ->
        {:error,
         dgettext(
           "import_export",
           "That file is from another app; only SillyTavern and Character Card files are supported."
         )}

      true ->
        {:error, unrecognized()}
    end
  end

  defp character?(json) do
    json["spec"] in ["chara_card_v2", "chara_card_v3"] or
      (Map.has_key?(json, "name") and
         Enum.any?(~w(description personality first_mes), &Map.has_key?(json, &1))) or
      Map.has_key?(json, "char_name")
  end

  defp other_app?(json) do
    Enum.any?(~w(lorebookVersion histories data_visible savedsettings), &Map.has_key?(json, &1)) or
      json["kind"] == "memory" or json["type"] in ["risu", "risuChat"] or is_list(json["messages"])
  end

  # A bundle (a `.mythweaver` file, or an external file still carrying its export's bundle) has no
  # macro text of its own to warn about.
  defp finalize(parsed) do
    case Embedded.resolve(parsed) do
      %{kind: :bundle} = bundle ->
        bundle

      parsed ->
        {names, parsed} = Map.pop(parsed, :unconverted, [])
        %{parsed | warnings: parsed.warnings ++ Text.macro_warnings(names)}
    end
  end

  @doc """
  Writes a parsed file for `scope` in one transaction (`Mythweaver.Import.Writer`). `warnings` are
  the writer's own (skipped entries, unmatched filter names, a failed avatar), not `parsed`'s.

  `opts`: for a chat, `player:` (a speaker key) and `speakers:` (`%{key => {:character, id} |
  :create | :name_only}`; a missing key is `:name_only`); for a preset, `model_id:` (a model whose
  sampler takes the preset's values, or nil).
  """
  @spec import(Scope.t(), parsed(), keyword()) ::
          {:ok, %{kind: atom(), record: struct(), warnings: [String.t()]}}
          | {:held, Hold.t()}
          | {:error, String.t()}
  def import(scope, parsed, opts \\ []) do
    case Gate.import(scope, parsed, opts) do
      {:held, hold} ->
        {:held, hold}

      {:error, :hold_limit} ->
        {:error,
         dgettext(
           "import_export",
           "You have too much waiting for review; withdraw something on the Submissions page first."
         )}

      :proceed ->
        Gate.no_holds(fn -> write(scope, parsed, opts) end)
    end
  end

  # An import that is not held still has each of its writes scanned (`Gate.no_holds/1`); an imported
  # chat's messages skip `Messages.send_message/5`, so the whole file is scanned as the chat.
  defp write(scope, parsed, opts) do
    with {:ok, result} <- Writer.import(scope, parsed, opts) do
      Changes.broadcast(
        [:characters, :lore, :prompts, :ai, :memory, :tags, :scripts, :variables],
        [nil, scope.user.id]
      )

      if result.kind == :chat, do: :ok = Gate.scan_import_chat(scope, result.record, parsed)
      {:ok, result}
    end
  end
end
