{common_event_fields, event_reference} = Mythweaver.Scripts.EventReference.data()

defmodule Mythweaver.Scripts do
  @moduledoc """
  Lua scripts: every enabled script usable by a chat's owner runs in that chat when its trigger
  fires.

  ## Ownership

  Scripts are owned (`Mythweaver.Ownership`): a nil `user_id` is a site script, edited by admins and
  run in every chat; a user's own script is edited by them alone and runs only in their chats. Names
  are unique per owner, so `mw.commands.run(name)` prefers the chat owner's command over the site's
  of the same name. A script depends only on site scripts or scripts of its own owner (a site script:
  site scripts only).

  Scripts of one trigger run in dependency order, higher `priority` first among those ready, then by
  name. A script whose dependency failed, was skipped or is disabled does not run. Each run gets a
  fresh VM (`Mythweaver.Scripts.Sandbox`); only `event.text` passes from one script to the next.
  `print(...)` lines join the run's errors (`Script "<name>" printed: …`), so a user message's
  author sees them; the sandbox caps how many.

  ## Events

  Every event has #{Enum.map_join(common_event_fields, " and ", &"`#{elem(&1, 0)}`")}. The rest, by
  trigger (`event_reference/0` holds the full descriptions):

  #{Enum.map_join(event_reference, "\n", fn event -> "  * `#{event.trigger}`: #{if event.fields == [], do: "no fields", else: Enum.map_join(event.fields, ", ", &"`#{elem(&1, 0)}`")}. #{event.returns}" end)}

  ## Host API

  A malformed call raises (catchable with `pcall`). A refusal returns `nil, "<reason>"`. A success
  returns the record table, or `true` for toggles and deletes. Message and generation functions act
  only on the current chat; a character that is neither its player nor a participant is
  `"not_in_chat"`. A character or lore write the runner's content moderation holds for review
  (`Mythweaver.Moderation.Holds`) refuses `"held_for_review"`; too much held already refuses
  `"hold_limit"`.

  A script acts with its runner's permissions. Each namespace's acting and writing functions need one
  of nine: `scripts.messages` (`mw.messages.*`), `scripts.images` (`mw.images.*`),
  `scripts.generation` (`mw.generation.*`), `scripts.memory` (`mw.memory.*`), `scripts.characters`
  (`mw.characters.*`), `scripts.prompts` (`mw.prompts.*`, `mw.blocks.*`), `scripts.lore`
  (`mw.lore.*`), `scripts.variables` (`mw.vars.*`, `mw.globals.*`) and `scripts.injections`
  (`mw.injections.*`); without it they refuse `"no_permission"`. The reads are never gated:
  `mw.messages.list`/`get`/`last`/`select`/`versions`, `mw.images.list`/`get`, `mw.memory.highest`,
  `mw.characters.list`/`get`/`find`, `mw.prompts.list`, `mw.lore.books`/`book`,
  `mw.vars.get`/`list`, `mw.globals.get`/`list` and `mw.injections.list`/`get`; nor are
  `mw.commands.run` (the command's own calls are gated), `mw.roll` and `regex.*`.

  * `mw.messages.list([first [, last]])`, `get(id)`, `last()`, `select(target)`, `create(author, text)`,
    `edit(id, text)`, `delete(target)`, `set_visible(target, visible)`,
    `set_author(id, author)`, `versions(id)`, `set_version(id, index)`, `merge(ids)`,
    `split(id, match [, multi])`: message `{id, number, position, character_id, author = {id, name},
    author_is_player, text, visible_to_ai, generating, version, version_count, created_at}`; a
    detached author (an imported speaker, a narrator, or a deleted character) has `author.id = nil`.
    `number` (also `position`, the same value) and every message number a script passes are the
    `#N` the chat shows, from 1.
    `list`'s bounds are numbers, inclusive. A `target` is a message id, a number, a
    `"first-last"` range of numbers (both ends included), or a list of numbers, ranges and ids: one id or
    number makes `delete` return `true` and `set_visible` the message (or `"not_found"`); a range
    or list makes `delete` return the count deleted and `set_visible` the messages that changed, and
    `select` always returns a list. `last()` is `nil` in an empty chat. `create` and
    `set_author` take a character id, `{id = …}` or `{name = …}` (so another message's `author`
    works) and refuse `"blank_name"`; `create` allows the player or a participant, `set_author` a
    participant, and `set_author` adds no version. A version is `{index, text, active, origin, generating,
    created_at}`, from 1. `merge` joins consecutive messages into the first; `split` cuts before
    paragraphs (after the first) containing `match` (the first such one, or all with `multi`) and
    returns the pieces, or refuses `"no_match"`. `edit`/`delete`/`set_author`/`set_version`/`merge`/
    `split` refuse `"generating"`; a `delete` of several deletes nothing if any is generating.
  * `mw.generation.generate(character_id [, guide])` (participants only),
    `regenerate(message_id [, guide])`: `true`, or a reason such as `"busy"` or `"not_last"`.
    Only `user_message`, `command`, `quick_reply` and inline scripts may start generations; inside a generation (`ai_generation`,
    `lore_activated`) both return `nil, "not_allowed"`, so an AI reply never starts another.
  * `mw.memory.create(start, finish)`, `next()`, `catch_up(start, finish, chunk)`,
    `run_side_prompt(side_prompt_id [, start [, finish]])`, `set_side_prompt_enabled(id_or_all, enabled)`,
    `highest()`, `set_highest(number_or_nil)`: Memory Book commands for the current chat. All
    message ranges are inclusive display numbers from 1. Create, next, catch-up, and side-prompt
    runs return job tables `{id, tag, status, label, range_start, range_end}` (catch-up returns a
    list); `next` refuses `"empty_scene"` when no message remains. `run_side_prompt` leaves omitted
    endpoints at its checkpoint/latest defaults and refuses `"not_found"` for an unknown prompt.
    `set_side_prompt_enabled` accepts a side-prompt id or literal `"all"` and returns the number
    changed (`0` for `"all"` with no side prompts); if an update fails it refuses with that reason,
    and the prompts updated before it stay changed. `highest` returns the display boundary or nil;
    `set_highest(nil)` clears it and otherwise returns true. Jobs run in the background without
    token confirmation but retain the configured review policy. `create`, `next`, `catch_up` and
    `run_side_prompt` follow `mw.generation`'s trigger rule and return `nil, "not_allowed"` elsewhere.
  * `mw.characters.list()`, `get(id)`, `find(name)`, `update(id, fields)`,
    `set_avatar(character [, prompt [, describe]])`, `set_appearance(character, text)`: character
    `{id, name, description, pronouns, appearance, creator, creator_notes, character_version,
    talkativeness, site_visibility}` (`description` and `appearance` nil when a site character's
    content is hidden from you). `find` matches the whole name, ignoring case and surrounding spaces; names are
    not unique, so it returns the oldest match. `set_avatar` and `set_appearance` take a character
    id or table. `set_avatar` asks the chat's player for an image (as `mw.images.request` does)
    and makes it the avatar; unless `describe` is `false` it is then described and fills an
    appearance nobody wrote. It returns `true` at once, needs a chat, and refuses `"not_found"` or
    `"not_allowed"` in `lore_activated`. `set_appearance` saves the text and returns the character.
  * `mw.prompts.list()`: prompt `{id, name, enabled, purpose, site_visibility, blocks = {{id, name,
    enabled, block_enabled, site_visibility}}}` (`enabled` is the membership switch, `block_enabled` the block's own);
    `set_enabled(prompt_id, enabled)`, `set_block_enabled(prompt_id, block_id, enabled)`.
  * `mw.blocks.set_enabled(block_id, enabled)`: the block's own switch.
  * `mw.lore.books()`, `book(id)` (adds `entries`), `create_book(fields)`, `update_book(id, fields)`,
    `delete_book(id)`, `create_entry(book_id, fields)`, `update_entry(id, fields)`,
    `delete_entry(id)`, `set_entry_enabled(book_id, entry_id, enabled)`,
    `set_chat_bound(book_id, bound)`: book `{id, name, description, global, priority,
    order_adjustment, token_budget, scan_depth, recursive, site_visibility, forced}`, entry `{id,
    name, content, keywords, activation, book_id, enabled, order}` (`content` and `keywords` nil
    when a book's content is hidden from you).
  * `mw.vars.get(key)`, `set(key, value)`, `list()`: the chat's variables, which templates read as
    `vars.*`. `mw.globals.get(key)`, `set(key, value)`, `list()`: the globals your chats read as
    `globals.*` (site globals overlaid by your own); `set` writes your own global, never the
    site's, as `{% setglobalvar %}` does. `get` returns the value or `nil`, `list` a table of
    `key = value`, and `set` `true`; a `nil` value deletes. Values are strings, numbers, booleans
    and tables of them (anything else raises); a malformed key refuses with the key's error.
  * `mw.injections.list()`, `get(key_or_id)`, `create(fields)`, `update(key_or_id, fields)`,
    `set_enabled(key_or_id, enabled)`, `rearm(key_or_id)`, `delete(key_or_id)`, `clean_up()`:
    the chat's injections: `{id, key, content, position, depth, role, condition, enabled, uses,
    remaining, order, active}`, where `active` means it applies to the next generation. Fields are
    the injections panel's (`position` a lore slot such as `"after_author_note"` or `"at_depth"`,
    `role` `"system"`/`"user"`/`"assistant"`, `uses` the successful replies it lasts for);
    `false` clears `uses` or `condition`. `rearm` restores `remaining` to `uses`; `clean_up`
    deletes the spent ones and returns how many.
  * `mw.commands.run(name [, args])`: runs an enabled command script as a function: `args` by
    `---@param` name (entities as id or record table), cast as the palette casts them; it runs with
    the caller's event (only `args` replaced), trigger and permissions and returns its return
    values (nil, booleans, numbers, strings, tables). Refuses `"not_found"`, `"<param>: <problem>"`,
    `"too_deep"` (past 3 nested calls); an unknown parameter or a failing command raises.
  * `mw.roll(dice)`: rolls dice such as `"2d6+1"`, `"d6"` or `"D20"` (count optional, default 1;
    up to 999 dice with 1–9999 sides and a ±9999 modifier) and returns the total; malformed dice raise.
  * `regex.test(s, pattern [, flags])`, `match(s, pattern [, flags [, init]])`,
    `match_all(s, pattern [, flags [, limit]])`, `replace(s, pattern, repl [, flags [, limit]])`
    (returns the new string and the replacement count), `split(s, pattern [, flags [, limit]])`,
    `escape(s)`: PCRE regular expressions. A match is `{text, start, finish, groups, named}`, with
    1-based inclusive byte positions like `string.find`; unset groups are `nil`. Flags: `i`, `m`,
    `s`, `x`, `U`. A string `repl` is a template (`$1`, `${1}`, `${name}`, `$$`); a function `repl`
    gets the match and returns its replacement, or `nil`/`false` to keep it. Malformed patterns and
    match-limit overruns raise.

  Script writes never fire triggers. A generation a script starts runs the `ai_generation` and
  `lore_activated` scripts as usual, marked `script_triggered`, but those cannot start generations,
  so chains stop after one level. Writes made during a generation take effect from the next one.
  """

  use Gettext, backend: Mythweaver.Gettext

  import Ecto.Query, warn: false

  alias Lua.AST.Block
  alias Lua.AST.Chunk
  alias Lua.AST.Expr.Property
  alias Lua.AST.Expr.Var
  alias Lua.AST.Statement.Do
  alias Lua.AST.Statement.If
  alias Lua.AST.Statement.Return
  alias Lua.AST.Walker
  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.Changes
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Ownership
  alias Mythweaver.Permissions.Quota
  alias Mythweaver.Repo
  alias Mythweaver.Scripts.API
  alias Mythweaver.Scripts.Command
  alias Mythweaver.Scripts.Sandbox
  alias Mythweaver.Scripts.Script
  alias Mythweaver.Sharing.Toggle

  require Logger

  @common_event_fields common_event_fields

  @event_reference event_reference

  @typedoc "`{name, type, description}` of one `event` field."
  @type event_field :: {String.t(), String.t(), String.t()}

  @doc "The `event` fields every trigger carries."
  @spec common_event_fields() :: [event_field()]
  def common_event_fields, do: Enum.map(@common_event_fields, &localize_field/1)

  @doc """
  What each trigger hands a script: when it runs, its `event` fields beyond `common_event_fields/0`,
  what a return value does, and a short example.
  """
  @spec event_reference() :: [
          %{
            trigger: Script.trigger() | :inline,
            summary: String.t(),
            fields: [event_field()],
            returns: String.t(),
            example: String.t() | nil
          }
        ]
  def event_reference do
    for event <- @event_reference do
      %{
        event
        | summary: localize(event.summary),
          returns: localize(event.returns),
          fields: Enum.map(event.fields, &localize_field/1)
      }
    end
  end

  defp localize_field({name, type, description}), do: {name, type, localize(description)}

  defp localize({context, msgid}), do: Gettext.dpgettext(Mythweaver.Gettext, "scripts", context, msgid)
  defp localize(msgid), do: Gettext.dgettext(Mythweaver.Gettext, "scripts", msgid)

  @doc """
  Runs every enabled `trigger` script against `event` (string keys) in `chat`, records each outcome,
  and returns the final `text` (`event["text"]` after every rewrite) and, in `errors`, each line a
  script printed followed by one message per failure or skip.
  Raises `Mythweaver.UnauthorizedError` when `scope` may not act on `chat`.

  Runs nothing (returns `event["text"]`, no errors) unless `scope` is the chat's owner: the scripts
  are the owner's, and a member's post must not run them with the member's permissions.
  """
  @spec run(Scope.t(), :ai_generation | :user_message | :lore_activated | :image_described, Chat.t(), map()) ::
          %{text: String.t() | nil, errors: [String.t()]}
  def run(%Scope{} = scope, trigger, %Chat{} = chat, event)
      when trigger in [:ai_generation, :user_message, :lore_activated, :image_described] do
    if Chats.authorize(scope, chat, :post) != :ok, do: raise(Mythweaver.UnauthorizedError)

    if chat.user_id == scope.user.id,
      do: run_owned(scope, trigger, chat, event),
      else: %{text: event["text"], errors: []}
  end

  defp run_owned(scope, trigger, chat, event) do
    enabled =
      from(s in Script, where: s.trigger == ^trigger and s.enabled, preload: :dependencies)
      |> Ownership.for_owner(chat.user_id)
      |> effective(chat.user_id)
      |> Repo.all()

    if enabled == [] do
      %{text: event["text"], errors: []}
    else
      chat = Chats.get_chat!(scope, chat.id)
      event = Map.merge(event, %{"trigger" => Atom.to_string(trigger), "chat_id" => chat.id})
      {ordered, cyclic} = order(enabled)

      {text, _succeeded, results, printed} =
        Enum.reduce(ordered, {event["text"], MapSet.new(), [], []}, fn script, {text, succeeded, results, printed} ->
          {outcome, lines} = run_one(scope, script, trigger, chat, event, text, succeeded)
          printed = Enum.reduce(lines, printed, &[printed_line(script, &1) | &2])

          case outcome do
            {:ok, text} -> {text, MapSet.put(succeeded, script.id), [{script, :ok} | results], printed}
            {:error, _} = error -> {text, succeeded, [{script, error} | results], printed}
          end
        end)

      results =
        Enum.reverse(
          results,
          Enum.map(
            cyclic,
            &{&1,
             {:error,
              dpgettext(
                "scripts",
                "status: a script skipped because of a dependency cycle",
                "Not run: dependency cycle."
              )}}
          )
        )

      record_results(scope, results)

      printed = Enum.reverse(printed)
      Enum.each(printed, &Logger.info/1)

      errors =
        for {script, {:error, message}} <- results do
          error = ~s(Script "#{script.name}" failed: #{message})
          Logger.warning(error)
          error
        end

      %{text: text, errors: printed ++ errors}
    end
  end

  @doc """
  Runs a sent message's inline `{! … !}` blocks (`{index, body}`, in order) in `chat`, each in a
  fresh VM with `event` plus `trigger`, `chat_id` and `index`. Returns each block's text by index
  and the lines printed, or stops at the first failure: blocks before it have already taken effect.
  All blocks share one block's wall-clock budget (`Sandbox.limits/0`'s `max_wall_ms`); a block
  left without time is not run. Needs the chat's `:run_scripts` and `content.scripts.create`.
  """
  @spec run_inline(Scope.t(), Chat.t(), [{pos_integer(), String.t()}], map()) ::
          {:ok, %{pos_integer() => String.t()}, [String.t()]} | {:error, String.t(), [String.t()]}
  def run_inline(%Scope{} = scope, %Chat{} = chat, blocks, event) when is_list(blocks) and is_map(event) do
    if Chats.authorize(scope, chat, :run_scripts) == :ok and Scope.can?(scope, "content.scripts.create"),
      do: do_run_inline(scope, chat, blocks, event),
      else: {:error, not_allowed(), []}
  end

  defp do_run_inline(scope, chat, blocks, event) do
    chat = Chats.get_chat!(scope, chat.id)
    limits = Sandbox.limits()
    wall_ms = limits[:max_wall_ms]
    deadline = if is_integer(wall_ms), do: System.monotonic_time(:millisecond) + wall_ms

    blocks
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}, []}, fn {{i, body}, position}, {:ok, values, printed} ->
      later? = position > 0
      remaining = deadline && deadline - System.monotonic_time(:millisecond)

      if remaining && remaining <= 0 do
        error = inline_out_of_time(i, later?)
        Logger.warning(error)
        {:halt, {:error, error, Enum.reverse(printed)}}
      else
        event = Map.merge(event, %{"trigger" => "inline", "chat_id" => chat.id, "index" => i})
        setup = &API.install(&1, %{scope: scope, chat: chat, trigger: :inline, event: event})
        block_limits = if remaining, do: Keyword.put(limits, :max_wall_ms, remaining), else: limits

        {outcome, lines} = sandboxed(body, setup, &inline_value/1, block_limits)

        printed =
          Enum.reduce(
            lines,
            printed,
            &[
              dgettext("scripts", "Inline script %{block_number} printed: %{printed_text}",
                block_number: Mythweaver.Format.number(i),
                printed_text: &1
              )
              | &2
            ]
          )

        case outcome do
          {:ok, value} ->
            {:cont, {:ok, Map.put(values, i, value), printed}}

          {:error, message} ->
            error = inline_failed(i, message, later?)
            Logger.warning(error)
            {:halt, {:error, error, Enum.reverse(printed)}}
        end
      end
    end)
    |> case do
      {:ok, values, printed} -> {:ok, values, Enum.reverse(printed)}
      error -> error
    end
  end

  defp inline_out_of_time(i, false) do
    gettext_comment("Shown when a message's {! !} inline Lua blocks ran out of their shared time limit.")

    dgettext(
      "errors",
      "inline script %{block_number} not run: the message's inline scripts used up their time budget.",
      block_number: Mythweaver.Format.number(i)
    )
  end

  defp inline_out_of_time(i, true) do
    gettext_comment("Shown when a message's {! !} inline Lua blocks ran out of their shared time limit.")

    dgettext(
      "errors",
      "inline script %{block_number} not run: the message's inline scripts used up their time budget. Inline scripts before it already ran.",
      block_number: Mythweaver.Format.number(i)
    )
  end

  defp inline_failed(i, message, false) do
    gettext_comment(
      "Shown when an inline {! !} Lua block fails; the reason is the script's error text, often English from the Lua engine."
    )

    dgettext("errors", "inline script %{block_number} failed: %{failure_reason}",
      block_number: Mythweaver.Format.number(i),
      failure_reason: message
    )
  end

  defp inline_failed(i, message, true) do
    gettext_comment(
      "Shown when an inline {! !} Lua block fails; the reason is the script's error text, often English from the Lua engine."
    )

    dgettext("errors", "inline script %{block_number} failed: %{failure_reason} Inline scripts before it already ran.",
      block_number: Mythweaver.Format.number(i),
      failure_reason: message
    )
  end

  defp printed_line(script, line) do
    gettext_comment("A line a Lua script printed with print(...), shown to the chat owner with the run's errors.")

    dpgettext("scripts", "status: a line a script printed", ~S(Script "%{script_name}" printed: %{printed_text}),
      script_name: script.name,
      printed_text: line
    )
  end

  defp not_allowed, do: dgettext("scripts", "You're not allowed to do that.")

  @doc """
  Every enabled `:command` script `scope` may use whose header parses, by name, with its header:
  `description` is the header's, else the script's.
  """
  @spec list_commands(Scope.t()) :: [%{script: Script.t(), description: String.t() | nil, params: [Command.param()]}]
  def list_commands(%Scope{} = scope) do
    from(s in Script, where: s.trigger == :command and s.enabled, order_by: [asc: s.name, asc: s.id])
    |> Ownership.usable(scope)
    |> effective(command_owner(%{scope: scope}))
    |> Repo.all()
    |> Enum.flat_map(fn script ->
      case Command.parse(script.body) do
        {:ok, header} ->
          [%{script: script, description: header.description || script.description, params: header.params}]

        {:error, _errors} ->
          []
      end
    end)
  end

  @doc """
  Runs the command script `script_id` with already-cast `args` (`Command.cast_args/4`), in `chat`
  or with none, and records the outcome. Returns the notice to show (`nil` for none) and the lines
  printed, or the failure message and the lines printed.
  """
  @spec run_command(Scope.t(), Ecto.UUID.t(), Chat.t() | nil, map()) ::
          {:ok, String.t() | nil, [String.t()]} | {:error, String.t(), [String.t()]}
  def run_command(%Scope{} = scope, script_id, chat, args) when is_map(args) do
    if Chats.authorize(scope, chat, :run_scripts) == :ok,
      do: do_run_command(scope, script_id, chat, args),
      else: {:error, not_allowed(), []}
  end

  defp do_run_command(scope, script_id, chat, args) do
    script = runnable(scope, chat, script_id, :command)

    case {script, chat && Chats.get_chat(chat.id)} do
      {nil, _chat} ->
        {:error, dgettext("scripts", "That command script no longer exists or is disabled."), []}

      {_script, nil} when not is_nil(chat) ->
        {:error, dgettext("scripts", "The chat no longer exists."), []}

      {script, chat} ->
        case run_picked(scope, script, chat, %{"trigger" => "command", "chat_id" => chat && chat.id, "args" => args}) do
          {:ok, "", printed} -> {:ok, nil, printed}
          result -> result
        end
    end
  end

  @doc """
  Every enabled `:quick_reply` script `scope` may use, in toolbar order: higher `priority` first,
  then name.
  """
  @spec list_quick_replies(Scope.t()) :: [Script.t()]
  def list_quick_replies(%Scope{} = scope) do
    from(s in Script,
      where: s.trigger == :quick_reply and s.enabled,
      order_by: [desc: s.priority, asc: s.name, asc: s.id]
    )
    |> Ownership.usable(scope)
    |> effective(command_owner(%{scope: scope}))
    |> Repo.all()
  end

  @doc """
  Runs the quick reply script `script_id` in `chat` against the composer's `text` and records the
  outcome. Returns what to do with the composer (`nil` nothing, `{:input, text}` replace its text,
  `:clear` empty it, `{:message, text}` send `text`) and the lines printed, or the failure message
  and the lines printed.
  """
  @spec run_quick_reply(Scope.t(), Ecto.UUID.t(), Chat.t(), String.t()) ::
          {:ok, nil | :clear | {:input, String.t()} | {:message, String.t()}, [String.t()]}
          | {:error, String.t(), [String.t()]}
  def run_quick_reply(%Scope{} = scope, script_id, %Chat{} = chat, text) when is_binary(text) do
    if Chats.authorize(scope, chat, :run_scripts) == :ok,
      do: do_run_quick_reply(scope, script_id, chat, text),
      else: {:error, not_allowed(), []}
  end

  defp do_run_quick_reply(scope, script_id, chat, text) do
    script = runnable(scope, chat, script_id, :quick_reply)

    case {script, Chats.get_chat(chat.id)} do
      {nil, _chat} ->
        {:error, dgettext("scripts", "That quick reply no longer exists or is disabled."), []}

      {_script, nil} ->
        {:error, dgettext("scripts", "The chat no longer exists."), []}

      {script, chat} ->
        run_picked(scope, script, chat, %{"trigger" => "quick_reply", "chat_id" => chat.id, "text" => text})
    end
  end

  # A script run by hand must be usable in the chat: by its owner, or by `scope` with no chat.
  defp runnable(scope, chat, script_id, trigger) do
    case Ecto.UUID.cast(script_id) do
      {:ok, id} ->
        Script
        |> usable_in(chat, scope)
        |> effective(command_owner(%{chat: chat, scope: scope}))
        |> Repo.get_by(id: id, trigger: trigger, enabled: true)

      :error ->
        nil
    end
  end

  defp usable_in(query, %Chat{user_id: owner_id}, _scope), do: Ownership.for_owner(query, owner_id)
  defp usable_in(query, nil, scope), do: Ownership.usable(query, scope)

  # The effective state of a script for `user_id` beyond its own `enabled`: their own runs as is, a
  # site one unless they toggled it off, a shared one only once they toggled it on
  # (`Mythweaver.Sharing.set_toggle/3`), and only while it is unchanged since: the toggle's
  # `consent_hash` must still be `Script.consent_hash/1` of the script.
  defp effective(query, nil), do: where(query, [s], is_nil(s.user_id))

  defp effective(query, user_id) do
    opted_out =
      from(t in Toggle,
        where: t.user_id == ^user_id and t.item_type == :script and not t.enabled,
        select: t.item_id
      )

    consented =
      from(t in Toggle,
        join: c in Script,
        on: c.id == t.item_id,
        where:
          t.user_id == ^user_id and t.item_type == :script and t.enabled and
            t.consent_hash ==
              fragment("encode(sha256(convert_to(? || chr(10) || ?, 'UTF8')), 'hex')", c.trigger, c.body),
        select: t.item_id
      )

    where(
      query,
      [s],
      s.user_id == ^user_id or (is_nil(s.user_id) and s.id not in subquery(opted_out)) or
        (not is_nil(s.user_id) and s.id in subquery(consented))
    )
  end

  # A script the person ran by hand (a command or quick reply): one run, recorded, its printed
  # lines prefixed with its name.
  defp run_picked(scope, script, chat, event) do
    setup = &API.install(&1, %{scope: scope, chat: chat, trigger: script.trigger, event: event})
    {outcome, lines} = sandboxed(script.body, setup, &interpret(script.trigger, &1, event["text"]))

    printed = Enum.map(lines, &printed_line(script, &1))
    Enum.each(printed, &Logger.info/1)

    case outcome do
      {:ok, value} ->
        record_results(scope, [{script, :ok}])
        {:ok, value, printed}

      {:error, message} = error ->
        record_results(scope, [{script, error}])

        gettext_comment(
          "Shown when a command or quick reply script fails; the reason is the script's error text, often English from the Lua engine."
        )

        error =
          dpgettext(
            "scripts",
            "status: a command or quick reply script failed",
            ~S(Script "%{script_name}" failed: %{failure_reason}),
            script_name: script.name,
            failure_reason: message
          )

        Logger.warning(error)
        {:error, error, printed}
    end
  end

  @max_command_depth 3

  @doc """
  Runs the enabled command script `name` for `mw.commands.run`, the chat owner's own over the site's
  of that name (with no chat, `ctx.scope`'s own over the site's): `raw` holds the palette text per
  parameter, cast as the palette casts it. The command runs with the caller's `ctx` (chat, trigger,
  event and `test?`), only `event.args` replaced, one level deeper; past #{@max_command_depth}
  nested calls it is refused. Outside a test run the outcome is recorded. Returns its decoded
  return values and printed lines, or its raw failure message and printed lines.
  """
  @spec call_command(String.t(), %{String.t() => String.t()}, map()) ::
          {:ok, [term()], [String.t()]}
          | {:failed, String.t(), [String.t()]}
          | {:error, :too_deep | :not_found | {:unknown_params, [String.t()]} | {:args, %{String.t() => String.t()}}}
  def call_command(name, raw, ctx) when is_binary(name) and is_map(raw) do
    depth = Map.get(ctx, :depth, 0)

    with {:depth, true} <- {:depth, depth < @max_command_depth},
         %Script{} = script <- command_by_name(ctx, name),
         {:ok, %{params: params}} <- Command.parse(script.body),
         {:extra, []} <- {:extra, Map.keys(raw) -- Enum.map(params, & &1.name)},
         {:ok, args} <- Command.cast_args(ctx.scope, params, raw, ctx.chat) do
      nested = ctx |> Map.put(:event, Map.put(ctx.event, "args", args)) |> Map.put(:depth, depth + 1)
      result = Sandbox.run(script.body, &API.install(&1, nested), Sandbox.limits())

      case result do
        {:ok, values, lines} ->
          if !ctx[:test?], do: record_results(ctx.scope, [{script, :ok}])
          {:ok, values, lines}

        {:error, message, lines} ->
          if !ctx[:test?], do: record_results(ctx.scope, [{script, {:error, message}}])
          {:failed, message, lines}
      end
    else
      {:depth, false} -> {:error, :too_deep}
      nil -> {:error, :not_found}
      {:error, [_ | _]} -> {:error, :not_found}
      {:extra, extra} -> {:error, {:unknown_params, Enum.sort(extra)}}
      {:error, %{} = errors} -> {:error, {:args, errors}}
    end
  end

  defp command_by_name(ctx, name) do
    from(s in Script,
      where: s.name == ^name and s.trigger == :command and s.enabled,
      order_by: ^[asc: Ownership.owner_rank(command_owner(ctx)), asc: :id],
      limit: 1
    )
    |> usable_in(ctx.chat, ctx.scope)
    |> effective(command_owner(ctx))
    |> Repo.one()
  end

  # Whose commands rank first: the chat owner's in a chat, else the scope user's (`usable_in/3`).
  defp command_owner(%{chat: %Chat{user_id: owner_id}}), do: owner_id
  defp command_owner(%{scope: %Scope{user: %{id: id}}}), do: id
  defp command_owner(_ctx), do: nil

  defp inline_value([]), do: {:ok, ""}
  defp inline_value([nil | _]), do: {:ok, ""}
  defp inline_value([value | _]) when is_binary(value), do: {:ok, value}
  defp inline_value([value | _]) when is_integer(value), do: {:ok, Integer.to_string(value)}
  defp inline_value([value | _]) when is_float(value), do: {:ok, Float.to_string(value)}
  defp inline_value(_values), do: {:error, dgettext("errors", "must return a string, a number or nil.")}

  # Disabled dependencies never succeed, so their dependents are skipped too.
  defp run_one(scope, script, trigger, chat, event, text, succeeded) do
    case Enum.find(script.dependencies, &(not MapSet.member?(succeeded, &1.id))) do
      nil ->
        setup = &API.install(&1, %{scope: scope, chat: chat, trigger: trigger, event: Map.put(event, "text", text)})
        sandboxed(script.body, setup, &interpret(trigger, &1, text))

      dep ->
        {{:error,
          dgettext("scripts", ~S(Not run: dependency "%{script_name}" did not succeed.), script_name: dep.name)}, []}
    end
  end

  # One sandboxed run as `{outcome, printed lines}`; `interpret` turns the returned values into the
  # outcome.
  defp sandboxed(body, setup, interpret, limits \\ Sandbox.limits()) do
    case Sandbox.run(body, setup, limits) do
      {:ok, values, lines} -> {interpret.(values), lines}
      {:error, message, lines} -> {{:error, message}, lines}
    end
  end

  defp interpret(:lore_activated, _values, text), do: {:ok, text}
  defp interpret(:command, values, _text), do: inline_value(values)
  defp interpret(:quick_reply, values, _text), do: quick_reply_value(values)
  defp interpret(_trigger, [new | _], _text) when is_binary(new), do: {:ok, new}
  defp interpret(_trigger, [nil | _], text), do: {:ok, text}
  defp interpret(_trigger, [], text), do: {:ok, text}
  defp interpret(_trigger, _values, _text), do: {:error, dgettext("scripts", "Script must return a string or nil.")}

  defp quick_reply_error, do: dgettext("errors", ~S[must return a string, {"message", text}, {"clear"} or nil.])

  defp quick_reply_value([]), do: {:ok, nil}
  defp quick_reply_value([nil | _]), do: {:ok, nil}

  defp quick_reply_value([value | _]) when is_binary(value) or is_number(value) do
    {:ok, text} = inline_value([value])
    {:ok, {:input, text}}
  end

  defp quick_reply_value([value | _]) when is_list(value) do
    case API.Convert.from_decoded(value) do
      ["clear"] ->
        {:ok, :clear}

      ["message", text] when is_binary(text) or is_number(text) ->
        {:ok, text} = inline_value([text])
        {:ok, {:message, text}}

      _ ->
        {:error, quick_reply_error()}
    end
  end

  defp quick_reply_value(_values), do: {:error, quick_reply_error()}

  # The triggers whose return value is used: a script without a closing `return` keeps the text.
  @returning_triggers [:user_message, :ai_generation]

  @doc """
  Compile errors and warnings for an unsaved `body` of `trigger`, for the editor. The one warning
  is a `user_message`/`ai_generation` body that does not end in `return` on every path, the usual
  way a script silently changes nothing.
  """
  @spec check(String.t(), atom()) :: %{errors: [String.t()], warnings: [String.t()]}
  def check(body, trigger) do
    case Sandbox.parse(body, &ends_with_return?/1) do
      {:ok, ends_with_return?} ->
        warnings =
          if not ends_with_return? and trigger in @returning_triggers do
            [
              dgettext(
                "scripts",
                "The script does not end with return, so it returns nothing and the text stays as it was. End it with return and the new text, or return nil to keep the text on purpose."
              )
            ]
          else
            []
          end

        %{errors: header_errors(body, trigger), warnings: warnings}

      {:error, errors} ->
        %{errors: errors, warnings: []}
    end
  end

  defp header_errors(body, :command) do
    case Command.parse(body) do
      {:ok, _header} -> []
      {:error, errors} -> errors
    end
  end

  defp header_errors(_body, _trigger), do: []

  defp ends_with_return?(%Chunk{block: block}), do: block_returns?(block)

  defp block_returns?(%Block{stmts: stmts}), do: stmts |> List.last() |> returns?()

  defp returns?(%Return{}), do: true
  defp returns?(%Do{body: body}), do: block_returns?(body)

  # Every branch must return, so an `if` needs an `else`.
  defp returns?(%If{then_block: then_block, elseifs: elseifs, else_block: %Block{} = else_block}) do
    block_returns?(then_block) and Enum.all?(elseifs, fn {_condition, block} -> block_returns?(block) end) and
      block_returns?(else_block)
  end

  defp returns?(_statement), do: false

  @doc """
  The `mw.<namespace>` host APIs `body` reaches, sorted: what a subscriber is told before enabling a
  shared script. Read from the parsed body, so only direct `mw.<namespace>` accesses count (an alias
  such as `local m = mw` hides them). `[]` when the body does not parse.
  """
  @spec capabilities(String.t()) :: [String.t()]
  def capabilities(body) when is_binary(body) do
    known = API.namespaces()

    case Sandbox.parse(body, &mw_namespaces/1) do
      {:ok, used} -> used |> Enum.filter(&(&1 in known)) |> Enum.sort() |> Enum.map(&("mw." <> &1))
      {:error, _errors} -> []
    end
  end

  defp mw_namespaces(ast) do
    ast
    |> Walker.reduce(MapSet.new(), fn
      %Property{table: %Var{name: "mw"}, field: namespace}, acc -> MapSet.put(acc, namespace)
      _node, acc -> acc
    end)
    |> MapSet.to_list()
  end

  @doc """
  Runs an unsaved `body` as a `trigger` script against sample `text`, with no chat. Other `event`
  fields take empty sample values (`nil` ids, `false` flags, empty lists, `mode` `"new"`). `mw.*`
  functions that need a chat or change data return `nil, "test_run"`, so a test changes nothing.
  Returns what a real run would keep (`:ok` with the text, unchanged on `nil`) or its error, plus
  any printed lines.
  """
  @spec test_run(Scope.t(), String.t(), atom(), String.t()) ::
          %{
            result:
              {:ok, String.t() | nil | :clear | {:input, String.t()} | {:message, String.t()}} | {:error, String.t()},
            lines: [String.t()]
          }
  def test_run(%Scope{} = scope, body, trigger, text) do
    if not Ownership.can_create?(scope, Script), do: raise(Mythweaver.UnauthorizedError)

    setup =
      &API.install(&1, %{scope: scope, chat: nil, trigger: trigger, event: sample_event(trigger, text), test?: true})

    {result, lines} = sandboxed(body, setup, &interpret(trigger, &1, text))
    %{result: result, lines: lines}
  end

  defp sample_event(trigger, text) do
    fields = Enum.find_value(@event_reference, [], &(&1.trigger == trigger && &1.fields))

    fields
    |> Map.new(fn {name, type, _description} -> {name, sample_value(name, type, text)} end)
    |> Map.merge(%{"trigger" => Atom.to_string(trigger), "chat_id" => nil})
  end

  defp sample_value("text", _type, text), do: text
  defp sample_value("mode", _type, _text), do: "new"
  defp sample_value(_name, "bool", _text), do: false
  defp sample_value(_name, "array" <> _, _text), do: []
  defp sample_value("args", _type, _text), do: %{}
  defp sample_value(_name, _type, _text), do: nil

  # Kahn's algorithm over edges between the given (enabled) scripts, always taking the ready script
  # with the highest priority, then name, then id. Scripts left over sit on a cycle.
  defp order(scripts) do
    ids = MapSet.new(scripts, & &1.id)

    deps =
      Map.new(scripts, fn script ->
        {script.id, for(dep <- script.dependencies, MapSet.member?(ids, dep.id), into: MapSet.new(), do: dep.id)}
      end)

    order(scripts, deps, MapSet.new(), [])
  end

  defp order(pending, deps, done_ids, done) do
    ready = Enum.filter(pending, &MapSet.subset?(deps[&1.id], done_ids))

    case Enum.min_by(ready, &{-&1.priority, &1.name, &1.id}, fn -> nil end) do
      nil -> {Enum.reverse(done), pending}
      next -> order(List.delete(pending, next), deps, MapSet.put(done_ids, next.id), [next | done])
    end
  end

  @doc "The scripts `scope` may edit (its own; plus the site's for an admin), by name."
  @spec list_scripts(Scope.t()) :: [Script.t()]
  def list_scripts(%Scope{} = scope) do
    from(s in Script, order_by: [asc: s.name, asc: s.id], preload: :dependencies)
    |> Ownership.editable(scope)
    |> Repo.all()
  end

  @doc """
  A script `scope` may edit, by id, with its dependencies loaded; `nil` for an unknown or malformed
  id or one `scope` may not edit.
  """
  @spec get_script(Scope.t(), String.t()) :: Script.t() | nil
  def get_script(%Scope{} = scope, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Script |> Ownership.editable(scope) |> Repo.get(id) |> with_dependencies()
      :error -> nil
    end
  end

  def get_script!(%Scope{} = scope, id), do: Script |> Ownership.editable(scope) |> Repo.get!(id) |> with_dependencies()

  defp with_dependencies(nil), do: nil

  defp with_dependencies(%Script{} = script) do
    script = Repo.preload(script, :dependencies)
    %{script | dependency_ids: Enum.map(script.dependencies, & &1.id)}
  end

  @doc """
  The script changeset with the dependency rules applied. `script` must have `:dependencies`
  loaded; a new one is `%Script{dependencies: []}`.
  """
  def change_script(%Script{} = script, attrs \\ %{}) do
    script |> Script.changeset(attrs) |> put_dependencies(script)
  end

  @doc """
  Creates a script owned per `Ownership.new_owner/3`: `scope`'s own, or the site's with `site: true`
  (which needs `"site.content.manage"`).
  """
  def create_script(%Scope{} = scope, attrs, opts \\ []) do
    with {:ok, user_id} <- Ownership.new_owner(scope, Script, opts),
         :ok <- Quota.check_new_row(scope, user_id, "quota.scripts", Script),
         do: do_create_script(user_id, attrs)
  end

  defp do_create_script(user_id, attrs) do
    %Script{user_id: user_id, dependencies: []}
    |> change_script(attrs)
    |> Repo.insert()
    |> broadcast_result()
  end

  def update_script(%Scope{} = scope, %Script{} = script, attrs) do
    with :ok <- Ownership.authorize_edit(scope, script), do: do_update_script(script, attrs)
  end

  defp do_update_script(script, attrs) do
    script
    |> Repo.preload(:dependencies)
    |> change_script(attrs)
    |> Repo.update()
    |> broadcast_result()
  end

  @doc """
  Deletes a script. With accepted editors it is given to `opts[:to]` or the oldest of them instead
  (`Mythweaver.Sharing.hand_off_or/4`).
  """
  @spec delete_script(Scope.t(), Script.t(), keyword()) ::
          {:ok, Script.t() | {:handed_off, User.t()}}
          | {:error, Ecto.Changeset.t() | :unauthorized}
  def delete_script(%Scope{} = scope, %Script{} = script, opts \\ []) do
    with :ok <- Ownership.authorize_delete(scope, script) do
      Mythweaver.Sharing.hand_off_or(scope, script, opts, fn ->
        :ok = Mythweaver.Sharing.revoke_all(:script, script.id, :deleted)
        script |> Repo.delete() |> broadcast_result()
      end)
    end
  end

  @doc """
  `{name, id}` for every script `script` could depend on under `trigger`, by name: site scripts and
  those reaching `script`'s owner (a new script's owner as `new_script/2` set it).
  """
  @spec dependency_options(Scope.t(), Script.t(), Script.trigger()) :: [{String.t(), Ecto.UUID.t()}]
  def dependency_options(%Scope{} = scope, %Script{id: id} = script, trigger) do
    query =
      from(s in Script, where: s.trigger == ^trigger, order_by: [asc: s.name, asc: s.id], select: {s.name, s.id})
      |> Ownership.for_owner(script.user_id)
      |> Ownership.usable(scope)

    query = if id, do: where(query, [s], s.id != ^id), else: query
    Repo.all(query)
  end

  @doc """
  A blank script owned as one `scope` creates with `opts` (`create_script/3`) would be, for the
  editor's validation.
  """
  @spec new_script(Scope.t(), keyword()) :: Script.t()
  def new_script(%Scope{} = scope, opts \\ []) do
    owner_id =
      case Ownership.new_owner(scope, Script, opts) do
        {:ok, owner_id} -> owner_id
        {:error, :unauthorized} -> nil
      end

    %Script{user_id: owner_id, dependencies: []}
  end

  defp put_dependencies(changeset, %Script{} = script) do
    ids = Ecto.Changeset.get_field(changeset, :dependency_ids) || []
    trigger = Ecto.Changeset.get_field(changeset, :trigger)
    other_ids = Enum.uniq(ids) -- [script.id]
    deps = Repo.all(from(s in Script, where: s.id in ^other_ids, order_by: [asc: s.name, asc: s.id]))
    found = MapSet.new(deps, & &1.id)

    changeset
    |> check(script.id in ids, :dependency_ids, dgettext_noop("errors", "cannot include the script itself"))
    |> check(
      Enum.any?(other_ids, &(&1 not in found)),
      :dependency_ids,
      dgettext_noop("errors", "includes a script that no longer exists")
    )
    |> check(
      not Enum.all?(deps, &Ownership.reference_ok?(script.user_id, &1)),
      :dependency_ids,
      dgettext_noop("errors", "includes a script you can't depend on")
    )
    |> check_triggers(deps, trigger)
    |> check(
      script.id != nil and cycle?(script.id, deps),
      :dependency_ids,
      dgettext_noop("errors", "would create a dependency cycle")
    )
    |> check_dependents(script)
    |> then(fn cs -> if cs.valid?, do: Ecto.Changeset.put_assoc(cs, :dependencies, deps), else: cs end)
  end

  defp check(changeset, true, field, message), do: Ecto.Changeset.add_error(changeset, field, message)
  defp check(changeset, false, _field, _message), do: changeset

  defp check_triggers(changeset, deps, trigger) do
    case Enum.filter(deps, &(&1.trigger != trigger)) do
      [] ->
        changeset

      other ->
        Ecto.Changeset.add_error(
          changeset,
          :dependency_ids,
          dgettext_noop("errors", "must share this script's trigger: %{script_names}"),
          script_names: names(other)
        )
    end
  end

  # Whether `script_id` is reachable from `deps` along the stored edges.
  defp cycle?(script_id, deps) do
    edges =
      from(d in "script_dependencies", select: {d.script_id, d.dependency_id})
      |> Repo.all()
      |> Enum.group_by(&load_uuid(elem(&1, 0)), &load_uuid(elem(&1, 1)))

    deps |> Enum.map(& &1.id) |> reaches?(script_id, edges, MapSet.new())
  end

  defp reaches?([], _target, _edges, _seen), do: false
  defp reaches?([target | _], target, _edges, _seen), do: true

  defp reaches?([id | rest], target, edges, seen) do
    if MapSet.member?(seen, id),
      do: reaches?(rest, target, edges, seen),
      else: reaches?(Map.get(edges, id, []) ++ rest, target, edges, MapSet.put(seen, id))
  end

  defp load_uuid(binary), do: Ecto.UUID.load!(binary)

  defp check_dependents(changeset, %Script{id: nil}), do: changeset

  defp check_dependents(changeset, %Script{id: id}) do
    if Ecto.Changeset.get_change(changeset, :trigger) do
      dependents =
        Repo.all(
          from(s in Script,
            join: d in "script_dependencies",
            on: d.script_id == s.id,
            where: d.dependency_id == type(^id, Ecto.UUID),
            order_by: [asc: s.name]
          )
        )

      if dependents == [],
        do: changeset,
        else:
          Ecto.Changeset.add_error(
            changeset,
            :trigger,
            dgettext_noop("errors", "other scripts depend on this one: %{script_names}"),
            script_names: names(dependents)
          )
    else
      changeset
    end
  end

  defp names(scripts), do: Enum.map_join(scripts, ", ", & &1.name)

  @doc """
  Stores each script's run outcome, for the scripts `scope` (the run's chat owner) may edit: its own,
  and the site's when it is an admin. A site script run in another user's chat records nothing, so
  its status never carries that user's chat content; the run's caller still gets the error. `:ok`
  stamps `last_success_at`; `{:error, message}` sets `last_error` and `last_error_at`. A success
  leaves the last error in place. Each recorded script's owner topic is told.
  """
  @spec record_results(Scope.t(), [{Script.t(), :ok | {:error, String.t()}}]) :: :ok
  def record_results(%Scope{} = scope, results) do
    now = DateTime.utc_now(:second)

    for {%Script{} = script, outcome} <- results, Ownership.authorize_edit(scope, script) == :ok, uniq: true do
      set =
        case outcome do
          :ok -> [last_success_at: now]
          {:error, message} -> [last_error: message, last_error_at: now]
        end

      Repo.update_all(from(s in Script, where: s.id == ^script.id), set: set)
      script.user_id
    end
    |> then(&Changes.broadcast(:scripts, &1))
  end

  defp broadcast_result({:ok, %Script{user_id: user_id}} = result) do
    Changes.broadcast(:scripts, user_id)
    result
  end

  defp broadcast_result(error), do: error
end
