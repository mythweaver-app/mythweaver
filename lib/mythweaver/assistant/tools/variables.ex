defmodule Mythweaver.Assistant.Tools.Variables do
  @moduledoc """
  Assistant tools over `Mythweaver.Variables`: a role-play chat's variables (`vars.*`) and global
  ones (`globals.*`).
  """

  alias Mythweaver.Assistant.Paths
  alias Mythweaver.Assistant.Tool
  alias Mythweaver.Assistant.Tools.Args
  alias Mythweaver.Assistant.Tools.Batch
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Variables
  alias Mythweaver.Variables.Variable

  @keys ~w(key value)
  @id %{"type" => "string", "description" => "Variable id."}
  @value %{"description" => "The JSON value: a string, number, boolean, array, or object."}
  @key %{
    "type" => "string",
    "description" => "Variable key: letters, digits and underscores, starting with a letter or underscore."
  }
  @chat_id %{"type" => "string", "description" => "Role-play chat id (from list_chats). Omit for a global variable."}

  def tools do
    variables = {"variable", "variables"}
    label = fn scope, id -> with %Variable{key: key} <- Variables.get_editable_variable(scope, id), do: key end

    [
      %Tool{
        name: "list_variables",
        description:
          "List variables, optionally searched by key: a role-play chat's own (vars.* in templates) with chat_id, " <>
            "else the global ones the user may edit (globals.*).",
        parameters: schema(%{"chat_id" => @chat_id, "query" => Args.query_property()}, []),
        kind: :read,
        summary: fn args -> if args["chat_id"], do: "List chat variables", else: "List global variables" end,
        run: &list/2
      },
      %Tool{
        name: "get_variable",
        description: "Read a variable.",
        parameters: schema(%{"id" => @id}, ["id"]),
        kind: :read,
        summary: fn _ -> "Read a variable" end,
        run: fn scope, args -> with {:ok, variable} <- editable(scope, args), do: {:ok, variable_map(variable)} end
      },
      Batch.items("create_variables",
        description: "Create variables: in a role-play chat when chat_id is given, else global.",
        verb: "Create",
        noun: variables,
        name_key: "key",
        item: schema(%{"key" => @key, "value" => @value, "chat_id" => @chat_id}, ["key", "value"]),
        run: &create/2
      ),
      Batch.items("update_variables",
        description: "Change variables' key or value; only the given fields change.",
        verb: "Update",
        noun: variables,
        label: label,
        item: schema(%{"id" => @id, "key" => @key, "value" => @value}, ["id"]),
        run: fn scope, item ->
          with {:ok, variable} <- editable(scope, item) do
            scope |> Variables.update_variable(variable, Args.attrs(item, @keys)) |> Args.wrap(&variable_map/1)
          end
        end
      ),
      Batch.ids("delete_variables",
        description: "Delete variables.",
        verb: "Delete",
        noun: variables,
        label: label,
        run: fn scope, args ->
          with {:ok, variable} <- editable(scope, args) do
            scope
            |> Variables.delete_variable(variable)
            |> Args.wrap(&%{"deleted" => true, "id" => &1.id, "key" => &1.key})
          end
        end
      )
    ]
  end

  defp list(scope, %{"chat_id" => chat_id} = args) when not is_nil(chat_id) do
    with {:ok, chat} <- roleplay_chat(scope, args) do
      rows = scope |> Variables.list_chat_variables(chat.id) |> Enum.map(&variable_map/1)
      {:ok, Args.list("variables", Args.by_name(rows, args["query"], "key"))}
    end
  end

  defp list(scope, args) do
    rows = scope |> Variables.list_global_variables() |> Enum.map(&variable_map/1)
    {:ok, Args.list("variables", Args.by_name(rows, args["query"], "key"))}
  end

  defp create(scope, %{"chat_id" => chat_id} = item) when not is_nil(chat_id) do
    with {:ok, chat} <- roleplay_chat(scope, item) do
      scope |> Variables.create_variable(chat.id, Args.attrs(item, @keys)) |> Args.wrap(&variable_map/1)
    end
  end

  defp create(scope, item),
    do: scope |> Variables.create_variable(nil, Args.attrs(item, @keys)) |> Args.wrap(&variable_map/1)

  defp roleplay_chat(scope, args) do
    with {:ok, id} <- Args.uuid(args, "chat_id") do
      case Chats.get_chat(scope, id) do
        %Chat{kind: :roleplay} = chat -> {:ok, chat}
        _ -> {:error, Args.error(:not_found)}
      end
    end
  end

  defp editable(scope, args) do
    with {:ok, id} <- Args.uuid(args, "id") do
      case Variables.get_editable_variable(scope, id) do
        nil -> {:error, Args.error(:not_found)}
        variable -> {:ok, variable}
      end
    end
  end

  defp schema(props, required), do: %{"type" => "object", "properties" => props, "required" => required}

  defp variable_map(%Variable{chat_id: nil} = v),
    do: %{
      "id" => v.id,
      "key" => v.key,
      "value" => v.value,
      "scope" => "global",
      "owner" => Args.owner(v),
      "path" => Paths.variable(v.id)
    }

  defp variable_map(%Variable{} = v),
    do: %{
      "id" => v.id,
      "key" => v.key,
      "value" => v.value,
      "scope" => "chat",
      "chat_id" => v.chat_id,
      "path" => Paths.chat(v.chat_id)
    }
end
