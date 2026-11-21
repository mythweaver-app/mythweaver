defmodule Mythweaver.Export.ChatLog do
  @moduledoc """
  Writes a bundle's chat as a SillyTavern `.jsonl` chat log, the inverse of
  `Mythweaver.Import.Chat`: a header line, then one line per message with its bodies as swipes.
  Message text is written as stored (the importer never converts it either); attachments are left
  out. The bundle, transcripts included, travels under the header's `chat_metadata.mythweaver`.
  """

  use Gettext, backend: Mythweaver.Gettext

  alias Mythweaver.Bundle
  alias Mythweaver.Export
  alias Mythweaver.Export.WorldInfo
  alias Mythweaver.Import.Chat, as: ImportChat
  alias Mythweaver.Import.Embedded

  @doc "The chat log for the chat item `chat_uid` of `bundle`. `opts`: `bundle:` (default true) adds the header's bundle."
  @spec file(Bundle.t(), String.t(), keyword()) :: %{
          bytes: binary(),
          filename: String.t(),
          content_type: String.t(),
          warnings: [String.t()]
        }
  def file(%Bundle{} = bundle, chat_uid, opts \\ []) do
    items = WorldInfo.index(bundle)
    chat = Map.fetch!(items, chat_uid)
    player = chat.data["player"]

    name_of = fn
      %{"kind" => "character", "name" => name} ->
        name

      uid ->
        case items[uid] do
          %{kind: :character, name: name} -> name
          _other -> nil
        end
    end

    messages = Map.get(bundle.messages, chat_uid, [])

    character =
      chat.data["participants"]
      |> List.wrap()
      |> Enum.map(& &1["character"])
      |> Enum.find(&(&1 != player))

    header = %{
      "user_name" => name_of.(player),
      "character_name" => name_of.(character),
      "create_date" =>
        case messages do
          [%{"inserted_at" => at} | _rest] when is_binary(at) -> at
          _other -> DateTime.to_iso8601(DateTime.utc_now(:second))
        end,
      "chat_metadata" => %{}
    }

    lines = Enum.map(messages, &line(&1, player, name_of))
    filename = Export.filename(chat.name, "jsonl")

    header =
      if Keyword.get(opts, :bundle, true) do
        digest = lines |> jsonl(header) |> digest(filename)
        put_in(header, ["chat_metadata", "mythweaver"], Bundle.to_embedded(bundle, digest))
      else
        header
      end

    attached? =
      Enum.any?(messages, fn message ->
        List.wrap(message["attachments"]) != [] or
          Enum.any?(List.wrap(message["bodies"]), &(List.wrap(&1["attachments"]) != []))
      end)

    %{
      bytes: jsonl(lines, header),
      filename: filename,
      content_type: "application/jsonl",
      warnings:
        if(attached?,
          do: [dgettext("import_export", "Attachments aren't part of SillyTavern chats and were left out.")],
          else: []
        )
    }
  end

  defp jsonl(lines, header), do: Enum.map_join([header | lines], "\n", &Jason.encode!/1) <> "\n"

  # A chat with no messages isn't a chat log the importer reads, so there is nothing to vouch for.
  defp digest(bytes, filename) do
    case ImportChat.parse(bytes, filename) do
      {:ok, parsed} -> Embedded.digest(parsed)
      {:error, _message} -> ""
    end
  end

  defp line(message, player, name_of) do
    bodies = List.wrap(message["bodies"])
    active = Enum.find_index(bodies, & &1["active"]) || max(length(bodies) - 1, 0)
    current = Enum.at(bodies, active) || %{}
    author = message["author"]

    %{
      "name" => (author && name_of.(author)) || message["author_name"] || "Unknown",
      "is_user" => author != nil and author == player,
      "is_system" => message["visible_to_ai"] == false,
      "send_date" => message["inserted_at"],
      "mes" => current["content"] || "",
      "swipes" => Enum.map(bodies, &(&1["content"] || "")),
      "swipe_id" => active,
      "swipe_info" =>
        Enum.map(bodies, &%{"send_date" => &1["inserted_at"], "extra" => %{"reasoning" => &1["reasoning"]}}),
      "extra" => %{"reasoning" => current["reasoning"]}
    }
  end
end
