defmodule Mythweaver.Assistant.Tools.Characters do
  @moduledoc "Assistant tools over `Mythweaver.Characters`."

  alias Mythweaver.Assistant.Paths
  alias Mythweaver.Assistant.Tool
  alias Mythweaver.Assistant.Tools.Args
  alias Mythweaver.Assistant.Tools.Batch
  alias Mythweaver.Characters
  alias Mythweaver.Characters.Character
  alias Mythweaver.Ownership
  alias Mythweaver.Sharing.Visibility

  @fields ~w[name description creator creator_notes character_version pronouns appearance avatar_updates_appearance talkativeness site_visibility
             system_prompt post_history_instructions card_prompt_mode]
  @writable ~w[name description appearance pronouns creator creator_notes character_version talkativeness avatar_updates_appearance site_visibility
               system_prompt post_history_instructions card_prompt_mode]

  @properties %{
    "name" => %{"type" => "string", "description" => "The character's name."},
    "description" => %{"type" => "string", "description" => "Personality, background and behaviour."},
    "appearance" => %{"type" => "string", "description" => "What the character looks like."},
    "pronouns" => %{"type" => "string", "description" => "E.g. she/her."},
    "creator" => %{"type" => "string", "description" => "Author credit."},
    "creator_notes" => %{"type" => "string", "description" => "Notes for users of the card."},
    "character_version" => %{"type" => "string", "description" => "Card version label."},
    "talkativeness" => %{"type" => "number", "description" => "0 to 1: how often it speaks in group chats."},
    "avatar_updates_appearance" => %{
      "type" => ["boolean", "null"],
      "description" => "Overrides the images.avatar_updates_appearance setting for this character; null follows it."
    },
    "system_prompt" => %{
      "type" => "string",
      "description" =>
        "The card's system prompt (Liquid; {{ original }} is the replaced prompt block's text). See card_prompt_mode."
    },
    "post_history_instructions" => %{
      "type" => "string",
      "description" => "Instructions sent after the chat history (Liquid; {{ original }} as for system_prompt)."
    },
    "card_prompt_mode" => %{
      "type" => "string",
      "enum" => ~w(replace add),
      "description" =>
        "replace: system_prompt and post_history_instructions take the place of the prompt blocks tagged main " <>
          "and post_history. add: they are added to the prompt alongside the lore instead."
    },
    "site_visibility" => %{
      "type" => "string",
      "enum" => ~w(readable runtime_only),
      "description" =>
        "What users may see of a site character: readable (everything) or runtime_only (its description and appearance hidden; the model still gets it). " <>
          "Site items only; a personal one must stay readable."
    }
  }

  @id %{"type" => "string", "description" => "The character id."}

  def tools do
    noun = {"character", "characters"}
    label = &editable_name/2

    [
      %Tool{
        name: "list_characters",
        description: "List the characters the user can use, optionally searched by name.",
        parameters: %{
          "type" => "object",
          "properties" => %{"query" => Args.query_property()},
          "required" => []
        },
        kind: :read,
        summary: fn _ -> "List characters" end,
        run: &list/2
      },
      %Tool{
        name: "get_character",
        description: "Read every field of one character.",
        parameters: %{"type" => "object", "properties" => %{"id" => @id}, "required" => ["id"]},
        kind: :read,
        summary: fn _ -> "Read a character" end,
        run: &get/2
      },
      Batch.items("create_characters",
        description: "Create characters.",
        verb: "Create",
        noun: noun,
        item: %{"type" => "object", "properties" => @properties, "required" => ["name"]},
        run: &create/2
      ),
      Batch.items("update_characters",
        description: "Change some fields of characters; fields left out keep their value.",
        verb: "Update",
        noun: noun,
        label: label,
        item: %{"type" => "object", "properties" => Map.put(@properties, "id", @id), "required" => ["id"]},
        run: &update/2
      ),
      Batch.ids("delete_characters",
        description: "Delete characters. One in a chat is not deleted.",
        verb: "Delete",
        noun: noun,
        label: label,
        run: &delete/2
      )
    ]
  end

  defp editable_name(scope, id),
    do: with(%Character{name: name} <- Characters.get_editable_character(scope, id), do: name)

  defp list(scope, args) do
    rows =
      scope
      |> Characters.list_characters()
      |> Enum.map(fn c ->
        hide(scope, c, %{
          "id" => c.id,
          "name" => c.name,
          "description" => Args.cut(c.description),
          "owner" => Args.owner(c),
          "editable" => Ownership.authorize_edit(scope, c) == :ok,
          "path" => Paths.character(c.id)
        })
      end)

    {:ok, Args.list("characters", Args.by_name(rows, args["query"]))}
  end

  defp get(scope, args) do
    with {:ok, id} <- Args.uuid(args, "id"),
         %Character{} = c <- Characters.get_character(scope, id) || {:error, Args.error(:not_found)} do
      {:ok, full(scope, c)}
    end
  end

  defp create(scope, args) do
    scope |> Characters.create_character(Args.attrs(args, @writable)) |> Args.wrap(&full(scope, &1))
  end

  defp update(scope, args) do
    with {:ok, c} <- editable(scope, args) do
      scope |> Characters.update_character(c, Args.attrs(args, @writable)) |> Args.wrap(&full(scope, &1))
    end
  end

  defp delete(scope, args) do
    with {:ok, c} <- editable(scope, args) do
      scope
      |> Characters.delete_character(c)
      |> Args.wrap(fn _ -> %{"deleted" => true, "id" => c.id, "name" => c.name} end)
    end
  end

  defp editable(scope, args) do
    with {:ok, id} <- Args.uuid(args, "id") do
      case Characters.get_editable_character(scope, id) do
        nil -> {:error, Args.error(:not_found)}
        c -> {:ok, c}
      end
    end
  end

  defp full(scope, %Character{} = c) do
    row =
      c
      |> Map.take(Enum.map(@fields, &String.to_existing_atom/1))
      |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
      |> Map.merge(%{"id" => c.id, "owner" => Args.owner(c), "path" => Paths.character(c.id)})

    hide(scope, c, row)
  end

  # A runtime-only site character's description, appearance and card prompts never reach a viewer
  # lacking site.hidden.view.
  defp hide(scope, %Character{} = c, row) do
    if Visibility.content_hidden_for?(scope, c) do
      row
      |> Map.replace("description", nil)
      |> Map.replace("appearance", nil)
      |> Map.replace("system_prompt", nil)
      |> Map.replace("post_history_instructions", nil)
      |> Map.put("content_hidden", true)
    else
      row
    end
  end
end
