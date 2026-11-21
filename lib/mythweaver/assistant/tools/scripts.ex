defmodule Mythweaver.Assistant.Tools.Scripts do
  @moduledoc """
  Assistant tools over `Mythweaver.Scripts`: create, read, update and delete Lua scripts. The
  assistant never runs one.
  """

  alias Mythweaver.Assistant.Paths
  alias Mythweaver.Assistant.Tool
  alias Mythweaver.Assistant.Tools.Args
  alias Mythweaver.Assistant.Tools.Batch
  alias Mythweaver.Scripts
  alias Mythweaver.Scripts.Script
  alias Mythweaver.Sharing.Visibility

  @keys ~w(name description priority trigger enabled body dependency_ids site_visibility)
  @id %{"type" => "string", "description" => "Script id."}

  defp triggers, do: Enum.map(Ecto.Enum.values(Script, :trigger), &Atom.to_string/1)

  def tools do
    scripts = {"script", "scripts"}
    label = fn scope, id -> with %Script{name: name} <- Scripts.get_script(scope, id), do: name end

    props = %{
      "name" => %{"type" => "string"},
      "description" => %{"type" => "string"},
      "priority" => %{
        "type" => "integer",
        "description" => "Higher runs first among ready scripts of the same trigger."
      },
      "trigger" => %{"type" => "string", "enum" => triggers(), "description" => "The event that runs the script."},
      "enabled" => %{"type" => "boolean"},
      "body" => %{"type" => "string", "description" => "Lua source."},
      "dependency_ids" => %{
        "type" => "array",
        "items" => %{"type" => "string"},
        "description" => "Scripts of the same trigger and owner that must succeed first; replaces the list."
      },
      "site_visibility" => %{
        "type" => "string",
        "enum" => ~w(readable runtime_only),
        "description" =>
          "What users may see of a site script: readable (everything) or runtime_only (its body hidden; the model still gets it). " <>
            "Site items only; a personal one must stay readable."
      }
    }

    [
      %Tool{
        name: "list_scripts",
        description: "List the scripts the user may edit, optionally searched by name.",
        parameters: schema(%{"query" => Args.query_property()}, []),
        kind: :read,
        summary: fn _ -> "List scripts" end,
        run: fn scope, args ->
          rows =
            for s <- Scripts.list_scripts(scope) do
              s
              |> summary_map()
              |> Map.put("description", Args.cut(s.description))
            end

          {:ok, Args.list("scripts", Args.by_name(rows, args["query"]))}
        end
      },
      %Tool{
        name: "get_script",
        description: "Read a script: its Lua body, dependencies and last run outcome.",
        parameters: schema(%{"id" => @id}, ["id"]),
        kind: :read,
        summary: fn _ -> "Read a script" end,
        run: fn scope, args -> with {:ok, script} <- editable(scope, args), do: {:ok, full_map(scope, script)} end
      },
      Batch.items("create_scripts",
        description: "Create Lua scripts.",
        verb: "Create",
        noun: scripts,
        item: schema(props, ["name", "trigger"]),
        run: fn scope, item ->
          scope |> Scripts.create_script(Args.attrs(item, @keys)) |> Args.wrap(&full_map(scope, &1))
        end
      ),
      Batch.items("update_scripts",
        description: "Change scripts; only the given fields change.",
        verb: "Update",
        noun: scripts,
        label: label,
        item: schema(Map.put(props, "id", @id), ["id"]),
        run: fn scope, item ->
          with {:ok, script} <- editable(scope, item) do
            scope |> Scripts.update_script(script, Args.attrs(item, @keys)) |> Args.wrap(&full_map(scope, &1))
          end
        end
      ),
      Batch.ids("delete_scripts",
        description: "Delete scripts.",
        verb: "Delete",
        noun: scripts,
        label: label,
        run: fn scope, args ->
          with {:ok, script} <- editable(scope, args) do
            scope |> Scripts.delete_script(script) |> Args.wrap(&%{"deleted" => true, "id" => &1.id, "name" => &1.name})
          end
        end
      )
    ]
  end

  defp editable(scope, args) do
    with {:ok, id} <- Args.uuid(args, "id") do
      case Scripts.get_script(scope, id) do
        nil -> {:error, Args.error(:not_found)}
        script -> {:ok, script}
      end
    end
  end

  defp schema(props, required), do: %{"type" => "object", "properties" => props, "required" => required}

  defp summary_map(%Script{} = s) do
    %{
      "id" => s.id,
      "name" => s.name,
      "trigger" => s.trigger,
      "priority" => s.priority,
      "enabled" => s.enabled,
      "site_visibility" => s.site_visibility,
      "dependency_ids" => Enum.map(s.dependencies, & &1.id),
      "owner" => Args.owner(s),
      "path" => Paths.script(s.id)
    }
  end

  defp full_map(scope, %Script{} = s) do
    s
    |> summary_map()
    |> Map.merge(%{
      "description" => s.description,
      "body" => if(!Visibility.content_hidden_for?(scope, s), do: s.body),
      "dependencies" => Enum.map(s.dependencies, &%{"id" => &1.id, "name" => &1.name}),
      "last_error" => s.last_error,
      "last_error_at" => s.last_error_at,
      "last_success_at" => s.last_success_at
    })
  end
end
