defmodule Mythweaver.Assistant.Tools.Navigation do
  @moduledoc "The assistant's `open_page` tool: a link to an app page."

  alias Mythweaver.Assistant.Paths
  alias Mythweaver.Assistant.Tool
  alias Mythweaver.Assistant.Tools.Args

  # page => {label, index path} or {label, record path function}
  @index %{
    "characters" => {"Characters", :characters},
    "lore" => {"Lore", :lore},
    "prompts" => {"Prompts", :prompts},
    "ai_connections" => {"AI connections", :connections},
    "ai_models" => {"AI models", :models},
    "jobs" => {"Jobs", :jobs},
    "import" => {"Import", :import},
    "tags" => {"Tags", :tags},
    "prompt_outlets" => {"Prompt outlets", :prompt_outlets},
    "memory_profiles" => {"Memory profiles", :memory_profiles},
    "side_prompts" => {"Side prompts", :side_prompts},
    "side_prompt_sets" => {"Side prompt sets", :side_prompt_sets},
    "variables" => {"Variables", :variables},
    "scripts" => {"Scripts", :scripts},
    "expression_profiles" => {"Expression profiles", :expression_profiles},
    "analytics" => {"Analytics", :analytics}
  }

  @record %{
    "character" => {"Character", &Paths.character/1},
    "lore_book" => {"Lore book", &Paths.lore_book/1},
    "lore_entry" => {"Lore entry", &Paths.lore_entry/1},
    "prompt" => {"Prompt", &Paths.prompt/1},
    "prompt_block" => {"Prompt block", &Paths.prompt_block/1},
    "ai_connection" => {"AI connection", &Paths.connection/1},
    "ai_model" => {"AI model", &Paths.model/1},
    "chat" => {"Chat", &Paths.chat/1},
    "tag" => {"Tag", &Paths.tag/1},
    "prompt_outlet" => {"Prompt outlet", &Paths.prompt_outlet/1},
    "memory_profile" => {"Memory profile", &Paths.memory_profile/1},
    "side_prompt" => {"Side prompt", &Paths.side_prompt/1},
    "side_prompt_set" => {"Side prompt set", &Paths.side_prompt_set/1},
    "chat_memory" => {"Chat memory", &Paths.chat_memory/1},
    "variable" => {"Variable", &Paths.variable/1},
    "script" => {"Script", &Paths.script/1},
    "expression_profile" => {"Expression profile", &Paths.expression_profile/1}
  }

  @pages ~w[characters character lore lore_book lore_entry prompts prompt prompt_block ai_connections ai_connection ai_models ai_model settings jobs import chat tags tag
            prompt_outlets prompt_outlet memory_profiles memory_profile side_prompts side_prompt side_prompt_sets side_prompt_set
            chat_memory variables variable scripts script expression_profiles expression_profile analytics]

  def tools do
    [
      %Tool{
        name: "open_page",
        description:
          "Give the user a link to an app page. Singular pages (character, lore_book, …, chat, chat_memory) need the record id; " <>
            "settings takes an optional category id (e.g. models, lore, memory).",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "page" => %{"type" => "string", "enum" => @pages, "description" => "The page."},
            "id" => %{"type" => "string", "description" => "Record id, or the settings category."}
          },
          "required" => ["page"]
        },
        kind: :read,
        summary: fn args -> "Open #{args["page"] || "a page"}" end,
        run: &open/2
      }
    ]
  end

  defp open(_scope, %{"page" => "settings"} = args) do
    case args["id"] do
      id when is_binary(id) and id != "" -> {:ok, %{"path" => Paths.settings(id), "label" => "Settings"}}
      _ -> {:ok, %{"path" => Paths.index(:settings), "label" => "Settings"}}
    end
  end

  defp open(_scope, %{"page" => page} = args) do
    cond do
      Map.has_key?(@index, page) ->
        {label, key} = @index[page]
        {:ok, %{"path" => Paths.index(key), "label" => label}}

      Map.has_key?(@record, page) ->
        {label, fun} = @record[page]

        if args["id"] in [nil, ""] do
          {:error, Args.error("#{page} needs an id")}
        else
          with {:ok, id} <- Args.uuid(args, "id"), do: {:ok, %{"path" => fun.(id), "label" => label}}
        end

      true ->
        {:error, Args.error("unknown page")}
    end
  end
end
