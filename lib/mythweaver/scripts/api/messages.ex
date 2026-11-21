defmodule Mythweaver.Scripts.API.Messages do
  @moduledoc "`mw.messages.*`: the current chat's transcript."

  use Gettext, backend: Mythweaver.Gettext

  import Mythweaver.Scripts.API.Convert

  alias Mythweaver.Characters.Character
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message
  alias Mythweaver.Messages.Segment

  # Scripts see a message's number as the chat shows it (`#1` first): the stored position plus one.
  # Every number in and out of this module converts here, clamped to the column's range so an
  # out-of-range number matches nothing instead of overflowing; `list(first)` reads to the end.
  @max_position 2_147_483_647

  @functions %{
    list:
      {"mw.messages.list([first [, last]])",
       dgettext_noop(
         "scripts",
         "The current chat's messages in order: all of them, or those numbered first..last (inclusive, as the chat shows #N; last defaults to the end)."
       )},
    get:
      {"mw.messages.get(id)",
       dgettext_noop("scripts", ~s(The current chat's message with this id, or nil, "not_found".))},
    last:
      {"mw.messages.last()",
       dgettext_noop(
         "scripts",
         "The current chat's newest message, or nil when it has none; its number is the newest #N."
       )},
    create:
      {"mw.messages.create(author, text)",
       dgettext_noop(
         "scripts",
         ~s[Posts text as a new message and returns it. author is the chat's player or a participant (its character id, or {id = character_id}; else nil, "not_in_chat"), or {name = "text"} for a speaker with no character, such as a narrator (blank is "blank_name"). Another message's author table works.]
       )},
    edit:
      {"mw.messages.edit(id, text)",
       dgettext_noop(
         "scripts",
         ~s(Saves text as the message's new active version; returns the message. Refuses "generating".)
       )},
    delete:
      {"mw.messages.delete(target)",
       dgettext_noop(
         "scripts",
         ~s[Deletes messages. target is a message id, a message number (as the chat shows #N), a "first-last" range of numbers (both ends included), or a list of numbers, ranges and ids. One id or number returns true, or nil, "not_found"; a range or list returns how many were deleted. Refuses "generating", deleting nothing, if any of them is generating.]
       )},
    set_visible:
      {"mw.messages.set_visible(target, visible)",
       dgettext_noop(
         "scripts",
         ~s[Shows messages to the AI's prompt, or hides them; target as for delete. One id or number returns the message, or nil, "not_found"; a range or list updates them at once and returns the messages that changed.]
       )},
    select:
      {"mw.messages.select(target)",
       dgettext_noop("scripts", ~s[The messages target names, as for delete, in order; a list, empty when none match.])},
    versions:
      {"mw.messages.versions(id)",
       dgettext_noop(
         "scripts",
         ~s[The message's versions (swipes), oldest first: {index, text, active, origin, generating, created_at}. origin is "original", "edit", "continue", "regenerate", "refine", "split", "merge" or "append".]
       )},
    set_version:
      {"mw.messages.set_version(id, index)",
       dgettext_noop(
         "scripts",
         ~s[Makes version index (from 1, as in versions) the active one; returns the message. Refuses "not_found" or "generating".]
       )},
    merge:
      {"mw.messages.merge(ids)",
       dgettext_noop(
         "scripts",
         ~s(Merges two or more consecutive messages into the first: its new active version joins their texts, and the rest are deleted. Returns the merged message; refuses "not_found", "too_few", "not_contiguous" or "generating".)
       )},
    split:
      {"mw.messages.split(id, match [, multi])",
       dgettext_noop(
         "scripts",
         ~s[Splits the message before the first paragraph (after its first) whose text contains match, or before every such paragraph when multi is true, as the split editor's markers do; the pieces keep the author and visibility. Returns the resulting messages, in order; refuses "no_match" or "generating".]
       )},
    set_author:
      {"mw.messages.set_author(id, author)",
       dgettext_noop(
         "scripts",
         ~s[Changes who wrote the message, without adding a version: author is a participant's character id, {id = character_id}, or {name = "text"} for a name with no character (so another message's author table works). Returns the message; refuses "not_in_chat", "blank_name" or "generating".]
       )}
  }

  @usage Map.new(@functions, fn {name, {signature, _info}} -> {name, signature} end)

  @doc "The installed functions' signatures and descriptions, by name."
  def functions, do: @functions

  def install(lua, ctx), do: install_functions(lua, [:mw, :messages], @functions, &call(&1, ctx, &2, &3))

  @doc """
  A message's Lua table. `author` is `{id, name}`: a character's id and current name, or `id = nil`
  and the stored name for a detached author (an imported speaker, or a deleted character).
  Needs `author_character` loaded, as every `Messages` read does.
  """
  def to_table(%Message{} = message) do
    body = Message.active_body(message)

    %{
      id: message.id,
      position: message.position + 1,
      number: message.position + 1,
      character_id: message.author_character_id,
      author: author(message),
      author_is_player: message.author_is_player,
      text: body && body.content,
      visible_to_ai: message.visible_to_ai,
      generating: (body && body.generating) || false,
      version: (Enum.find_index(message.bodies, & &1.active) || 0) + 1,
      version_count: length(message.bodies),
      created_at: message.inserted_at
    }
  end

  defp version_table({body, index}) do
    %{
      index: index,
      text: body.content,
      active: body.active,
      origin: body.origin,
      generating: body.generating,
      created_at: body.inserted_at
    }
  end

  defp author(%Message{author_is_character: true, author_character: %Character{id: id, name: name}}),
    do: %{id: id, name: name}

  defp author(%Message{author_is_character: false, author_name: name}), do: %{id: nil, name: name}

  @doc "`id`'s message when it belongs to `chat` and `scope` may read it, else `nil`."
  def in_chat(scope, chat, id) do
    case fetch(id, &Messages.get_message(scope, &1)) do
      %Message{chat_id: chat_id} = message when chat_id == chat.id -> message
      _ -> nil
    end
  end

  @doc "Whether `character_id` is the chat's player or one of its participants."
  def member?(chat, character_id) do
    is_binary(character_id) and
      (character_id == chat.player_character_id or Enum.any?(chat.participants, &(&1.character_id == character_id)))
  end

  defp call(:list, ctx, [], state), do: ok(state, Enum.map(Messages.list_messages(ctx.chat), &to_table/1))

  defp call(:list, ctx, [first | rest], state) when length(rest) <= 1 do
    first = first |> int!(:list) |> position()
    last = if rest == [], do: @max_position, else: rest |> hd() |> int!(:list) |> position()
    ok(state, Enum.map(Messages.list_messages_between(ctx.scope, ctx.chat, first, last), &to_table/1))
  end

  defp call(:last, ctx, [], state) do
    case Messages.list_messages_page(ctx.scope, ctx.chat, limit: 1) do
      {[message], _more?} -> ok(state, to_table(message))
      {[], _more?} -> ok(state, nil)
    end
  end

  defp call(:get, ctx, [id], state) when is_binary(id) do
    with_message(ctx, id, state, &ok(state, to_table(&1)))
  end

  defp call(:create, ctx, [author, text], state) when is_binary(text) do
    case author!(state, author, :create) do
      {:character, id} = author ->
        if member?(ctx.chat, id), do: post(ctx, author, text, state), else: refuse(state, :not_in_chat)

      {:name, name} = author ->
        if String.trim(name) == "", do: refuse(state, :blank_name), else: post(ctx, author, text, state)
    end
  end

  defp call(:edit, ctx, [id, text], state) when is_binary(id) and is_binary(text) do
    with_idle_message(ctx, id, state, fn message ->
      ctx.scope |> Messages.add_edited_body(message, %{"content" => text}) |> reply(state, &to_table/1)
    end)
  end

  defp call(:delete, ctx, [target], state) do
    case target!(ctx, state, target, :delete) do
      {:one, nil} ->
        refuse(state, :not_found)

      {:one, message} ->
        if generating?(message),
          do: refuse(state, :generating),
          else: ctx.scope |> Messages.delete_message(message) |> reply(state, fn _ -> true end)

      # Checked up front so a refusal deletes nothing.
      {:many, messages} ->
        if Enum.any?(messages, &generating?/1) do
          refuse(state, :generating)
        else
          Enum.each(messages, &({:ok, _} = Messages.delete_message(ctx.scope, &1)))
          ok(state, length(messages))
        end
    end
  end

  defp call(:set_visible, ctx, [target, visible?], state) when is_boolean(visible?) do
    case target!(ctx, state, target, :set_visible) do
      {:one, nil} ->
        refuse(state, :not_found)

      {:one, message} ->
        ctx.scope |> Messages.set_visible_to_ai(message, visible?) |> reply(state, &to_table/1)

      {:many, messages} ->
        changed = Messages.set_visible_many(ctx.chat, Enum.map(messages, & &1.id), visible?)
        ok(state, Enum.map(changed, &to_table/1))
    end
  end

  defp call(:select, ctx, [target], state) do
    messages =
      case target!(ctx, state, target, :select) do
        {:one, message} -> List.wrap(message)
        {:many, messages} -> messages
      end

    ok(state, Enum.map(messages, &to_table/1))
  end

  defp call(:set_author, ctx, [id, author], state) when is_binary(id) do
    case author!(state, author, :set_author) do
      {:name, name} = author ->
        if String.trim(name) == "",
          do: refuse(state, :blank_name),
          else: reattribute(ctx, id, author, state)

      author ->
        reattribute(ctx, id, author, state)
    end
  end

  defp call(:versions, ctx, [id], state) when is_binary(id) do
    with_message(ctx, id, state, fn message ->
      ok(state, message.bodies |> Enum.with_index(1) |> Enum.map(&version_table/1))
    end)
  end

  defp call(:set_version, ctx, [id, index], state) when is_binary(id) do
    index = int!(index, :set_version)

    with_message(ctx, id, state, fn message ->
      cond do
        Enum.any?(message.bodies, & &1.generating) ->
          refuse(state, :generating)

        index < 1 or index > length(message.bodies) ->
          refuse(state, :not_found)

        true ->
          {:ok, _} = Messages.set_active_body(ctx.scope, Enum.at(message.bodies, index - 1))
          message = Messages.get_message!(ctx.scope, message.id)
          # Unlike a swipe click, which repaints only its own tab, a script's change reaches every tab.
          Messages.broadcast_message_updated(message.chat_id, message)
          ok(state, to_table(message))
      end
    end)
  end

  defp call(:merge, ctx, [ids], state) do
    ids = ids!(state, ids, :merge)

    # `merge_messages/2` casts every id; a malformed one names no message.
    if Enum.all?(ids, &match?({:ok, _}, Ecto.UUID.cast(&1))) do
      ctx.scope |> Messages.merge_messages(ctx.chat, ids) |> reply(state, &to_table/1)
    else
      refuse(state, :not_found)
    end
  end

  defp call(:split, ctx, [id, match | multi], state)
       when is_binary(id) and is_binary(match) and match != "" and multi in [[], [nil], [true], [false]] do
    with_message(ctx, id, state, fn message ->
      content = Message.active_content(message) || ""

      case split_boundaries(content, match, multi == [true]) do
        [] ->
          refuse(state, :no_match)

        boundaries ->
          dividers = Enum.map(boundaries, &%{boundary: &1, author_id: nil})

          ctx.scope
          |> Messages.split_message(ctx.chat, message, content, dividers)
          |> reply(state, fn head ->
            ctx.scope
            |> Messages.list_messages_between(ctx.chat, head.position, head.position + length(dividers))
            |> Enum.map(&to_table/1)
          end)
      end
    end)
  end

  defp call(name, _ctx, _args, _state), do: usage!(@usage[name])

  defp with_message(ctx, id, state, fun) do
    case in_chat(ctx.scope, ctx.chat, id) do
      nil -> refuse(state, :not_found)
      message -> fun.(message)
    end
  end

  # A character id, `{id = character_id}`, or `{name = text}`; a message's `author` table has `id`
  # set for a character and `nil` for a detached name, so it maps the same way.
  defp author!(_state, id, _name) when is_binary(id), do: {:character, id}

  defp author!(state, {:tref, _} = table, name) do
    case fields!(state, table, @usage[name]) do
      %{"id" => id} when is_binary(id) -> {:character, id}
      %{"name" => author_name} when is_binary(author_name) -> {:name, author_name}
      _ -> usage!(@usage[name])
    end
  end

  defp author!(_state, _author, name), do: usage!(@usage[name])

  defp post(ctx, author, text, state) do
    ctx.scope |> Messages.post_message(ctx.chat, author, text) |> reply(state, &to_table/1)
  end

  # The paragraph gaps the split editor would put a marker in: before each paragraph, after the first,
  # whose text contains `match`; only the first such gap unless `multi?`.
  defp split_boundaries(content, match, multi?) do
    boundaries =
      for {paragraph, index} <- content |> Segment.paragraphs() |> Enum.with_index(),
          index > 0,
          String.contains?(paragraph, match),
          do: index

    if multi?, do: boundaries, else: Enum.take(boundaries, 1)
  end

  defp ids!(state, {:tref, _} = table, name) do
    case from_lua(state, table) do
      ids when is_list(ids) -> if Enum.all?(ids, &is_binary/1), do: ids, else: usage!(@usage[name])
      _ -> usage!(@usage[name])
    end
  end

  defp ids!(_state, _ids, name), do: usage!(@usage[name])

  # Lua numbers arrive as integers or, after arithmetic like `n / 2`, as floats.
  defp int!(n, _name) when is_integer(n), do: n
  defp int!(n, _name) when is_float(n) and n == trunc(n), do: trunc(n)
  defp int!(_n, name), do: usage!(@usage[name])

  defp reattribute(ctx, id, author, state) do
    with_message(ctx, id, state, fn message ->
      case Messages.reattribute_message(ctx.scope, ctx.chat, message, author) do
        {:ok, message} -> ok(state, to_table(message))
        {:error, :not_participant} -> refuse(state, :not_in_chat)
        {:error, reason} -> refuse(state, reason)
      end
    end)
  end

  defp with_idle_message(ctx, id, state, fun) do
    with_message(ctx, id, state, fn message ->
      if generating?(message), do: refuse(state, :generating), else: fun.(message)
    end)
  end

  defp generating?(message) do
    body = Message.active_body(message)
    (body && body.generating) || false
  end

  # One id or position names one message (`nil` when none matches); a "first-last" range or a list
  # of positions, ranges and ids names however many match, in order.
  defp target!(ctx, state, {:tref, _} = table, name) do
    case from_lua(state, table) do
      items when is_list(items) -> {:many, resolve(ctx, Enum.map(items, &target_item!(&1, name)))}
      _ -> usage!(@usage[name])
    end
  end

  defp target!(ctx, _state, target, name) do
    case target_item!(target, name) do
      {:range, _, _} = range -> {:many, resolve(ctx, [range])}
      single -> {:one, ctx |> resolve([single]) |> List.first()}
    end
  end

  defp target_item!(text, name) when is_binary(text) do
    case Regex.run(~r/\A\s*(\d+)\s*-\s*(\d+)\s*\z/, text, capture: :all_but_first) do
      [first, last] ->
        {first, last} = {String.to_integer(first), String.to_integer(last)}
        if first > last, do: usage!(@usage[name]), else: {:range, position(first), position(last)}

      nil ->
        {:id, text}
    end
  end

  defp target_item!(n, name) when is_number(n), do: {:position, n |> int!(name) |> position()}
  defp target_item!(_target, name), do: usage!(@usage[name])

  defp position(number), do: (number - 1) |> min(@max_position) |> max(-@max_position)

  defp resolve(ctx, items) do
    ids = for {:id, id} <- items, match?({:ok, _}, Ecto.UUID.cast(id)), do: id
    positions = for {:position, n} <- items, do: n
    ranges = for {:range, first, last} <- items, do: {first, last}
    Messages.list_targeted(ctx.chat, ids, positions, ranges)
  end
end
