defmodule Mythweaver.Assistant.Tools.Search do
  @moduledoc "The assistant's search tool over Mythweaver.Search."

  alias Mythweaver.Assistant.Paths
  alias Mythweaver.Assistant.Tool
  alias Mythweaver.Assistant.Tools.Args
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Search
  alias Mythweaver.Search.Hit

  def tools do
    kinds = kinds()

    [
      %Tool{
        name: "search",
        description:
          "Full-text search across the user's content: role-play chats and messages, characters, lore books and " <>
            "entries, prompts, prompt blocks, prompt outlets, scripts, side prompts, memory profiles, AI models and " <>
            "connections. Words match by prefix; -word excludes. Results are grouped by kind, best first; more is " <>
            "true when a kind had more hits than limit.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "text" => %{"type" => "string", "description" => "The words to search for."},
            "kinds" => %{
              "type" => "array",
              "items" => %{"type" => "string", "enum" => kinds},
              "description" => "Only these kinds; default all."
            },
            "chat_id" => %{
              "type" => "string",
              "description" => "Only messages of this role-play chat (id from list_chats), newest first."
            },
            "book_id" => %{"type" => "string", "description" => "Only lore entries in this book."},
            "limit" => %{
              "type" => "integer",
              "minimum" => 1,
              "maximum" => 20,
              "description" => "Hits per kind, default 5."
            }
          },
          "required" => ["text"]
        },
        kind: :read,
        summary: fn args -> "Search for “#{args["text"] || ""}”" end,
        run: &search/2
      }
    ]
  end

  defp kinds, do: Enum.map(Search.kinds(), &Atom.to_string/1)

  defp search(scope, args) do
    with {:ok, chat_opts} <- chat_opt(scope, args),
         {:ok, book_opts} <- book_opt(args),
         {:ok, kind_opts} <- kinds_opt(args["kinds"]),
         {:ok, limit_opts} <- limit_opt(args["limit"]) do
      opts = [chat_kind: :roleplay] ++ chat_opts ++ book_opts ++ kind_opts ++ limit_opts
      groups = Search.search(scope, args["text"], opts)
      {:ok, %{"groups" => Enum.map(groups, &group/1)}}
    end
  end

  defp chat_opt(_scope, %{"chat_id" => nil}), do: {:ok, []}

  defp chat_opt(scope, %{"chat_id" => _} = args) do
    with {:ok, id} <- Args.uuid(args, "chat_id") do
      case Chats.get_chat(scope, id) do
        %Chat{kind: :roleplay} -> {:ok, [chat_id: id]}
        _ -> {:error, Args.error(:not_found)}
      end
    end
  end

  defp chat_opt(_scope, _args), do: {:ok, []}

  defp book_opt(%{"book_id" => id} = args) when not is_nil(id) do
    with {:ok, id} <- Args.uuid(args, "book_id"), do: {:ok, [book_id: id]}
  end

  defp book_opt(_args), do: {:ok, []}

  defp kinds_opt(nil), do: {:ok, []}

  defp kinds_opt(list) when is_list(list) do
    case Enum.find(list, &(&1 not in kinds())) do
      nil -> {:ok, [kinds: Enum.map(list, &String.to_existing_atom/1)]}
      kind -> {:error, Args.error("unknown kind: #{kind}")}
    end
  end

  defp kinds_opt(_other), do: {:error, Args.error("kinds must be a list")}

  defp limit_opt(nil), do: {:ok, []}
  defp limit_opt(limit) when is_integer(limit) and limit in 1..20, do: {:ok, [limit: limit]}
  defp limit_opt(_limit), do: {:error, Args.error("limit must be an integer from 1 to 20.")}

  defp group(%{kind: kind, hits: hits, more?: more?}),
    do: %{"kind" => Atom.to_string(kind), "more" => more?, "hits" => Enum.map(hits, &hit/1)}

  defp hit(%Hit{kind: :message} = hit) do
    %{
      "id" => hit.id,
      "title" => text(hit.title),
      "snippet" => text(hit.snippet),
      "chat_id" => hit.chat_id,
      "chat_title" => hit.chat_title,
      "number" => hit.position + 1,
      "path" => Paths.chat(hit.chat_id)
    }
  end

  defp hit(%Hit{} = hit),
    do: %{"id" => hit.id, "title" => text(hit.title), "snippet" => text(hit.snippet), "path" => path(hit.kind, hit.id)}

  defp text(nil), do: nil
  defp text(segments), do: Enum.map_join(segments, fn {chunk, _highlighted?} -> chunk end)

  defp path(:chat, id), do: Paths.chat(id)
  defp path(:character, id), do: Paths.character(id)
  defp path(:lore_book, id), do: Paths.lore_book(id)
  defp path(:lore_entry, id), do: Paths.lore_entry(id)
  defp path(:prompt, id), do: Paths.prompt(id)
  defp path(:prompt_block, id), do: Paths.prompt_block(id)
  defp path(:prompt_outlet, id), do: Paths.prompt_outlet(id)
  defp path(:script, id), do: Paths.script(id)
  defp path(:side_prompt, id), do: Paths.side_prompt(id)
  defp path(:memory_profile, id), do: Paths.memory_profile(id)
  defp path(:ai_model, id), do: Paths.model(id)
  defp path(:ai_provider, id), do: Paths.connection(id)
end
