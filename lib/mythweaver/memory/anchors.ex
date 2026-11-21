defmodule Mythweaver.Memory.Anchors do
  @moduledoc """
  Builds `anchors.memory` (`Mythweaver.Prompts.Anchor.memory_catalog/0`) for one memory job. Every
  key is always present: nil, or `[]` for the arrays, when the job's kind does not use it.
  """

  alias Mythweaver.Memory.Scene

  @kinds [:memory, :consolidation, :compaction, :topical_clip, :side_prompt, :memory_assistance]

  @doc """
  `data` keys, all optional:

    * `:messages`: the scene's `Messages.Message`s (with author and bodies preloaded)
    * `:speakers`: speaker names
    * `:previous`: earlier memories, `%{"title", "content"}` maps, oldest first
    * `:context`: Additional Context entries, maps or structs with `name` and `content`
    * `:sources`: `%{"title", "content"}` maps; ids are assigned here
    * `:previous_summary`: `%{"title", "content"}` or nil
    * `:target_tier`: `%{"number", "name"}` or nil
    * `:entry`: `%{"title", "content", "kind"}` or nil
    * `:topic`, `:keywords` (a list or a string)
    * `:clips`: string-keyed clip maps for Memory Assistance, passed through unchanged
    * `:character`: a character copy's target character name(s), or nil
  """
  @spec build(atom(), map() | keyword()) :: %{String.t() => term()}
  def build(kind, data) when kind in @kinds do
    data = Map.new(data)
    messages = Map.get(data, :messages, [])
    previous = Map.get(data, :previous, [])
    sources = data |> Map.get(:sources, []) |> numbered()
    clips = Map.get(data, :clips, [])

    %{
      "kind" => Atom.to_string(kind),
      "scene" => blank_nil(Scene.text(messages)),
      "scene_messages" =>
        Enum.map(
          messages,
          &%{"number" => &1.position + 1, "author" => Scene.author(&1), "content" => Scene.content(&1)}
        ),
      "range" => range(messages),
      "speakers" => data |> Map.get(:speakers, []) |> Enum.join(", ") |> blank_nil(),
      "previous_memories" => previous,
      "previous_text" => previous |> Enum.map_join("\n\n", &"### #{&1["title"]}\n#{&1["content"]}") |> blank_nil(),
      "context" =>
        data
        |> Map.get(:context, [])
        |> Enum.map_join("\n\n", &"### #{field(&1, :name)}\n#{field(&1, :content)}")
        |> blank_nil(),
      "sources" => sources,
      "sources_text" =>
        sources |> Enum.map_join("\n\n", &"[#{&1["id"]}] #{&1["title"]}\n#{&1["content"]}") |> blank_nil(),
      "previous_summary" => Map.get(data, :previous_summary),
      "target_tier" => Map.get(data, :target_tier),
      "entry" => Map.get(data, :entry),
      "topic" => Map.get(data, :topic),
      "keywords" => keywords(Map.get(data, :keywords)),
      "clips" => clips,
      "clips_text" => if(clips != [], do: Jason.encode!(clips, pretty: true)),
      "character" => Map.get(data, :character)
    }
  end

  defp range([]), do: nil
  defp range(messages), do: %{"start" => hd(messages).position + 1, "end" => List.last(messages).position + 1}

  defp numbered(sources) do
    for {source, i} <- Enum.with_index(sources, 1) do
      %{
        "id" => i |> Integer.to_string() |> String.pad_leading(3, "0"),
        "title" => source["title"],
        "content" => source["content"]
      }
    end
  end

  defp field(%{} = item, key), do: Map.get(item, key) || Map.get(item, Atom.to_string(key))

  defp keywords(nil), do: nil
  defp keywords(list) when is_list(list), do: list |> Enum.join(", ") |> blank_nil()
  defp keywords(text), do: blank_nil(text)

  defp blank_nil(""), do: nil
  defp blank_nil(text), do: text
end
