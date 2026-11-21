defmodule Mythweaver.Assistant.Tools.Chats do
  @moduledoc "Assistant tools over role-play chats (`Mythweaver.Chats`) and their messages. Assistant threads are never visible here."

  alias Mythweaver.Assistant.Paths
  alias Mythweaver.Assistant.Tool
  alias Mythweaver.Assistant.Tools.Args
  alias Mythweaver.Assistant.Tools.Batch
  alias Mythweaver.Assistant.Tools.Preview
  alias Mythweaver.Characters
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Chats.Participant
  alias Mythweaver.Generation
  alias Mythweaver.Messages
  alias Mythweaver.Messages.Message

  @update_keys ~w(name participant_ids player_character_id ai_model_id lore_book_ids prompt_id reply_strategy
                  allow_self_responses max_turns auto_mode_delay group_cards)
  @participant_keys ~w(ai_model_id muted talkativeness outfit_id)
  # A read's cap: message numbers asked for.
  @max_numbers 200

  def tools do
    chat_label = fn scope, id ->
      case fetch(scope, %{"id" => id}) do
        {:ok, chat} -> Chat.title(chat)
        _ -> nil
      end
    end

    character_label = fn scope, id -> with %{name: name} <- Characters.get_character(scope, id), do: name end

    participant_label = fn scope, id ->
      case fetch_participant(scope, id) do
        {:ok, %Participant{character: %{name: name}}} -> name
        _ -> nil
      end
    end

    [
      %Tool{
        name: "list_chats",
        description:
          "Lists the user's role-play chats with their participant seats (seat id, character, position, mute and " <>
            "per-seat overrides), optionally searched by title.",
        parameters: %{"type" => "object", "properties" => %{"query" => Args.query_property()}, "required" => []},
        kind: :read,
        summary: fn _ -> "List chats" end,
        run: &list/2
      },
      %Tool{
        name: "read_chat_messages",
        description:
          "Reads messages of a role-play chat (id from list_chats) by their number, the #N shown on each message " <>
            ~s|in the chat: give numbers and "first-last" ranges, e.g. ["23-51", "60"]. | <>
            "Gives each message's author and current text, oldest first, up to #{@max_numbers} numbers per call. " <>
            "Negative numbers count back from the newest (-1 is the newest). With max_chars, text past that many " <>
            "characters is left out and omitted_from is the first number not given; ask again from there. " <>
            "last_number is the chat's newest message number.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "chat_id" => %{"type" => "string", "description" => "Chat id."},
            "messages" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "minItems" => 1,
              "description" =>
                ~s|Message numbers and inclusive "first-last" ranges, e.g. ["12", "23-51"]; negative numbers count from the newest: "-1" is the newest, "-5--1" the newest five, "780--1" #780 to the end.|
            },
            "max_chars" => %{
              "type" => "integer",
              "minimum" => 1,
              "description" =>
                "Optional: stop once the messages' text would pass this many characters; omitted_from then says where to resume."
            }
          },
          "required" => ["chat_id", "messages"]
        },
        kind: :read,
        summary: &messages_summary/1,
        run: &read_messages/2
      },
      %Tool{
        name: "create_chat",
        description: "Creates a role-play chat with at least two characters (ids from list_characters).",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string", "description" => "Chat name; optional."},
            "character_ids" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "minItems" => 2,
              "description" => "Participant character ids."
            },
            "player_character_id" => %{
              "type" => "string",
              "description" => "The participant the user plays; optional."
            },
            "ai_model_id" => %{"type" => "string", "description" => "Model id for the chat; optional."}
          },
          "required" => ["character_ids"]
        },
        kind: :write,
        summary: fn args -> "Create chat “#{args["name"] || "Untitled chat"}”" end,
        preview: fn scope, args ->
          for id <- List.wrap(args["character_ids"]), do: Preview.row(character_label, scope, id)
        end,
        run: &create/2
      },
      %Tool{
        name: "update_chat",
        description:
          "Changes a role-play chat's settings. Only given keys change; participant_ids replaces the participant " <>
            "list (a replaced seat loses its per-seat overrides; prefer add_participants/remove_participants). " <>
            "Turn-taking (allow_self_responses, max_turns, auto_mode_delay) and group_cards matter for reply_strategy " <>
            "natural/list/pooled.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "id" => %{"type" => "string", "description" => "Chat id."},
            "name" => %{"type" => "string"},
            "participant_ids" => %{"type" => "array", "items" => %{"type" => "string"}, "minItems" => 2},
            "player_character_id" => %{"type" => "string"},
            "ai_model_id" => %{"type" => "string"},
            "lore_book_ids" => %{"type" => "array", "items" => %{"type" => "string"}},
            "prompt_id" => %{"type" => "string"},
            "reply_strategy" => %{
              "type" => "string",
              "enum" => Enum.map(Chat.reply_strategies(), &Atom.to_string/1)
            },
            "allow_self_responses" => %{
              "type" => "boolean",
              "description" => "Whether a character may reply to their own last message."
            },
            "max_turns" => %{
              "type" => ["integer", "null"],
              "minimum" => 1,
              "description" => "Cap on auto-mode replies per run; null for no cap."
            },
            "auto_mode_delay" => %{
              "type" => "integer",
              "minimum" => 1,
              "maximum" => 999,
              "description" => "Seconds between auto-mode turns."
            },
            "group_cards" => %{
              "type" => "string",
              "enum" => Enum.map(Chat.group_cards_modes(), &Atom.to_string/1),
              "description" =>
                "Whose cards a reply sees besides the responder's and the player's: swap (none), join (unmuted " <>
                  "participants), join_all (everyone)."
            }
          },
          "required" => ["id"]
        },
        kind: :write,
        summary: fn args -> "Update chat #{(args["name"] && "“#{args["name"]}”") || args["id"] || "…"}" end,
        preview: Preview.update(chat_label),
        run: &update/2
      },
      Batch.ids("delete_chats",
        description: "Deletes role-play chats and all their messages.",
        verb: "Delete",
        noun: {"chat", "chats"},
        label: chat_label,
        run: &delete/2
      ),
      %Tool{
        name: "add_participants",
        description: "Seats characters in a role-play chat (ids from list_characters). " <> Batch.rule(),
        parameters: %{
          "type" => "object",
          "properties" => %{
            "chat_id" => %{"type" => "string", "description" => "Chat id."},
            "character_ids" =>
              Batch.array(%{"type" => "string"}, "Character ids to seat in the chat (ids from list_characters).")
          },
          "required" => ["chat_id", "character_ids"]
        },
        kind: :write,
        summary: &Batch.count("Add", &1["character_ids"], {"participant", "participants"}),
        preview: fn scope, args ->
          for id <- List.wrap(args["character_ids"]), do: Preview.row(character_label, scope, id)
        end,
        run: &add_participants/2
      },
      Batch.ids("remove_participants",
        description:
          "Removes seats (participant ids from list_chats) from a role-play chat. Refuses a removal that would " <>
            "drop the chat below two participants.",
        verb: "Remove",
        noun: {"participant", "participants"},
        label: participant_label,
        run: fn scope, %{"id" => id} ->
          with {:ok, participant} <- fetch_participant(scope, id) do
            scope |> Chats.remove_participant(participant) |> Args.wrap(&%{"removed" => true, "id" => &1.id})
          end
        end
      ),
      Batch.items("update_participants",
        description:
          "Changes participants' per-seat settings (participant ids from list_chats): model, mute, talkativeness, " <>
            "outfit. Only given keys change.",
        verb: "Update",
        noun: {"participant", "participants"},
        label: participant_label,
        item: %{
          "type" => "object",
          "properties" => %{
            "id" => %{"type" => "string", "description" => "Participant id."},
            "ai_model_id" => %{
              "type" => ["string", "null"],
              "description" => "Model for this seat; null falls back to the chat's model."
            },
            "muted" => %{"type" => "boolean", "description" => "Excludes the seat from automatic turn selection."},
            "talkativeness" => %{
              "type" => ["number", "null"],
              "minimum" => 0.0,
              "maximum" => 1.0,
              "description" => "Overrides the character's talkativeness; null falls back to it."
            },
            "outfit_id" => %{
              "type" => ["string", "null"],
              "description" => "Expression outfit for this seat; null is the Default set."
            }
          },
          "required" => ["id"]
        },
        run: fn scope, item ->
          with {:ok, participant} <- fetch_participant(scope, item["id"]) do
            scope
            |> Chats.update_participant(participant, Args.attrs(item, @participant_keys))
            |> Args.wrap(&participant_result/1)
          end
        end
      ),
      %Tool{
        name: "reorder_participants",
        description:
          "Sets a role-play chat's speaking order. participant_ids must be every current participant id of the " <>
            "chat, each once.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "chat_id" => %{"type" => "string", "description" => "Chat id."},
            "participant_ids" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "minItems" => 2,
              "description" => "Every participant id of the chat, in the new speaking order."
            }
          },
          "required" => ["chat_id", "participant_ids"]
        },
        kind: :write,
        summary: fn args -> "Reorder #{length(List.wrap(args["participant_ids"]))} participants" end,
        preview: fn scope, args -> [Preview.row(chat_label, scope, args["chat_id"])] end,
        run: &reorder/2
      }
    ]
  end

  defp list(scope, args) do
    rows =
      for chat <- Chats.list_chats(scope, :roleplay) do
        %{
          "id" => chat.id,
          "title" => Chat.title(chat),
          "participants" => Enum.map(chat.participants, &participant_row/1),
          "player_character_id" => chat.player_character_id,
          "player" => chat.player_character && chat.player_character.name,
          "path" => Paths.chat(chat.id)
        }
      end

    {:ok, Args.list("chats", Args.by_name(rows, args["query"], "title"))}
  end

  defp read_messages(scope, args) do
    with {:ok, chat} <- fetch(scope, args, "chat_id"),
         last_number = last_number(scope, chat),
         {:ok, ranges} <- message_ranges(args["messages"], last_number),
         {:ok, max_chars} <- max_chars(args) do
      messages =
        ranges
        |> Enum.flat_map(fn {first, last} -> Messages.list_messages_between(scope, chat, first - 1, last - 1) end)
        |> Enum.uniq_by(& &1.id)
        |> Enum.sort_by(& &1.position)

      {shown, omitted_from} = within_budget(messages, max_chars)

      {:ok,
       %{
         "chat_id" => chat.id,
         "title" => Chat.title(chat),
         "last_number" => last_number,
         "omitted_from" => omitted_from,
         "messages" => Enum.map(shown, &message_row/1)
       }}
    end
  end

  defp last_number(scope, chat) do
    case Messages.list_messages_page(scope, chat, limit: 1) do
      {[newest], _more?} -> newest.position + 1
      {[], _more?} -> nil
    end
  end

  # Each entry as an inclusive `{first, last}` of message numbers, negative ends counted back from
  # `last_number`; a range that names no message is dropped, and the rest are refused past `@max_numbers`.
  defp message_ranges(entries, last_number) when is_list(entries) and entries != [] do
    parsed = Enum.map(entries, &message_range/1)

    if Enum.any?(parsed, &(&1 == :error)) do
      {:error,
       Args.error(~s|Each messages entry is a number or a "first-last" range, like 23, "23-51" or "-1" (the newest).|)}
    else
      ranges = parsed |> Enum.map(&resolve_range(&1, last_number)) |> Enum.reject(&is_nil/1)

      if ranges |> Enum.map(fn {first, last} -> last - first + 1 end) |> Enum.sum() > @max_numbers,
        do: {:error, Args.error("At most #{@max_numbers} message numbers per call.")},
        else: {:ok, ranges}
    end
  end

  defp message_ranges(_entries, _last_number), do: {:error, Args.error("messages must be a non-empty list.")}

  defp message_range(n) when is_integer(n) and n != 0, do: {n, n}

  defp message_range(text) when is_binary(text) do
    case parse_entry(text) do
      [first] -> message_range(first)
      [first, last] -> ordered(first, last)
      nil -> :error
    end
  end

  defp message_range(_entry), do: :error

  defp parse_entry(text) do
    with [_ | _] = ends <- Regex.run(~r/\A\s*(-?\d+)\s*(?:-\s*(-?\d+)\s*)?\z/, text, capture: :all_but_first),
         do: Enum.map(ends, &String.to_integer/1)
  end

  # Ends of one sign must be in order; mixed signs ("780--1") are only known once resolved.
  defp ordered(first, last) when first == 0 or last == 0, do: :error
  defp ordered(first, last) when (first > 0 and last > 0) or (first < 0 and last < 0), do: ordered_same(first, last)
  defp ordered(first, last), do: {first, last}

  defp ordered_same(first, last) when first <= last, do: {first, last}
  defp ordered_same(_first, _last), do: :error

  defp resolve_range({first, last}, last_number) do
    with first when not is_nil(first) <- resolve(first, last_number),
         last when not is_nil(last) <- resolve(last, last_number),
         first = max(first, 1),
         true <- last >= 1 and first <= last do
      {first, last}
    else
      _ -> nil
    end
  end

  defp resolve(n, _last_number) when n > 0, do: n
  defp resolve(_n, nil), do: nil
  defp resolve(n, last_number), do: last_number + n + 1

  defp max_chars(%{"max_chars" => nil}), do: {:ok, nil}
  defp max_chars(%{"max_chars" => n}) when is_integer(n) and n > 0, do: {:ok, n}
  defp max_chars(%{"max_chars" => _}), do: {:error, Args.error("max_chars must be a positive integer.")}
  defp max_chars(_args), do: {:ok, nil}

  # The messages whose text fits in `max_chars` (the first always does), and the number of the
  # first one left out, or nil; no `max_chars` keeps them all.
  defp within_budget(messages, nil), do: {messages, nil}

  defp within_budget(messages, max_chars) do
    {shown, _used, omitted} =
      Enum.reduce_while(messages, {[], 0, nil}, fn message, {shown, used, nil} ->
        size = String.length(Message.active_content(message) || "")

        if shown == [] or used + size <= max_chars,
          do: {:cont, {[message | shown], used + size, nil}},
          else: {:halt, {shown, used, message.position + 1}}
      end)

    {Enum.reverse(shown), omitted}
  end

  defp message_row(%Message{} = message) do
    %{
      "number" => message.position + 1,
      "author" => author_name(message),
      "is_player" => message.author_is_player,
      "visible_to_ai" => message.visible_to_ai,
      "content" => Message.active_content(message)
    }
  end

  defp author_name(%Message{author_is_character: true, author_character: %{name: name}}), do: name
  defp author_name(%Message{author_name: name}), do: name

  defp messages_summary(%{"messages" => [_ | _] = entries}),
    do: "Read chat messages " <> Enum.map_join(entries, ", ", &entry_label/1)

  defp messages_summary(_args), do: "Read chat messages"

  defp entry_label(entry) do
    case parse_entry(to_string(entry)) do
      [first] -> number_label(first)
      [first, last] -> number_label(first) <> "–" <> number_label(last)
      nil -> to_string(entry)
    end
  end

  defp number_label(-1), do: "newest"
  defp number_label(n) when n < 0, do: "newest−#{-n - 1}"
  defp number_label(n), do: "##{n}"

  defp create(scope, args) do
    attrs =
      args
      |> Args.attrs(~w(name player_character_id ai_model_id))
      |> Map.put("participants", Enum.map(List.wrap(args["character_ids"]), &%{"character_id" => &1}))

    scope |> Chats.create_chat(attrs) |> Args.wrap(&result/1)
  end

  defp update(scope, args) do
    with {:ok, chat} <- fetch(scope, args) do
      scope |> Chats.update_settings(chat, Args.attrs(args, @update_keys)) |> Args.wrap(&result/1)
    end
  end

  defp delete(scope, args) do
    with {:ok, chat} <- fetch(scope, args) do
      # :not_generating is the usual answer; anything else surfaces through delete_chat's own check.
      _ = Generation.cancel(scope, chat)
      scope |> Chats.delete_chat(chat) |> Args.wrap(&%{"deleted" => true, "id" => &1.id})
    end
  end

  defp fetch(scope, args, key \\ "id") do
    with {:ok, id} <- Args.uuid(args, key) do
      case Chats.get_chat(scope, id) do
        %Chat{kind: :roleplay} = chat -> {:ok, chat}
        _ -> {:error, Args.error(:not_found)}
      end
    end
  end

  defp fetch_participant(scope, id) do
    with {:ok, uuid} <- Args.uuid(%{"id" => id}, "id") do
      case Chats.get_participant(uuid) do
        nil ->
          {:error, Args.error(:not_found)}

        %Participant{} = participant ->
          case Chats.authorize(scope, participant.chat_id, :manage) do
            :ok -> {:ok, participant}
            {:error, reason} -> {:error, Args.error(reason)}
          end
      end
    end
  end

  defp add_participants(scope, args) do
    with {:ok, chat} <- fetch(scope, args, "chat_id"),
         {:ok, character_ids} <- Batch.fetch_list(args, "character_ids") do
      Batch.each(Enum.uniq(character_ids), fn character_id ->
        with {:ok, id} <- Args.uuid(%{"character_id" => character_id}, "character_id") do
          scope
          |> Chats.add_participants(chat, [id])
          |> Args.wrap(fn [participant] -> participant_result(participant) end)
        end
      end)
    end
  end

  defp reorder(scope, args) do
    with {:ok, chat} <- fetch(scope, args, "chat_id"),
         {:ok, ids} <- participant_ids(args) do
      scope |> Chats.reorder_participants(chat, ids) |> Args.wrap(&result/1)
    end
  end

  defp participant_ids(%{"participant_ids" => [_, _ | _] = ids}) do
    if Enum.all?(ids, &is_binary/1),
      do: {:ok, ids},
      else: {:error, Args.error("participant_ids must be a list of at least 2 ids.")}
  end

  defp participant_ids(_args), do: {:error, Args.error("participant_ids must be a list of at least 2 ids.")}

  defp participant_row(%Participant{} = p) do
    %{
      "id" => p.id,
      "character_id" => p.character_id,
      "name" => p.character && p.character.name,
      "position" => p.position,
      "muted" => p.muted,
      "ai_model_id" => p.ai_model_id,
      "talkativeness" => p.talkativeness,
      "outfit_id" => p.outfit_id
    }
  end

  # Reloaded, so the character is preloaded whatever the write returned.
  defp participant_result(%Participant{id: id}) do
    participant = Chats.get_participant(id)
    participant |> participant_row() |> Map.put("chat_id", participant.chat_id)
  end

  defp result(%Chat{} = chat), do: %{"id" => chat.id, "title" => Chat.title(chat), "path" => Paths.chat(chat.id)}
end
