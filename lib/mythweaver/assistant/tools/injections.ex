defmodule Mythweaver.Assistant.Tools.Injections do
  @moduledoc """
  Assistant tools over `Mythweaver.Injections`: a role-play chat's injections, prompt text outside
  the prompt's blocks that steers the next replies.
  """

  alias Mythweaver.Assistant.Paths
  alias Mythweaver.Assistant.Tool
  alias Mythweaver.Assistant.Tools.Args
  alias Mythweaver.Assistant.Tools.Batch
  alias Mythweaver.Chats
  alias Mythweaver.Chats.Chat
  alias Mythweaver.Injections
  alias Mythweaver.Injections.Injection

  @keys ~w(key content position depth role condition enabled uses order)
  @id %{"type" => "string", "description" => "Injection id."}
  @chat_id %{"type" => "string", "description" => "Role-play chat id (from list_chats)."}

  defp positions, do: Enum.map(Ecto.Enum.values(Injection, :position), &Atom.to_string/1)

  def tools do
    injections = {"injection", "injections"}
    label = fn scope, id -> with %Injection{key: key} <- Injections.get_injection(scope, id), do: key end

    props = %{
      "key" => %{
        "type" => "string",
        "description" => "Letters, digits and underscores, starting with a letter or underscore."
      },
      "content" => %{"type" => "string", "description" => "Liquid template text injected into the prompt."},
      "position" => %{
        "type" => "string",
        "enum" => positions(),
        "description" => "Where it is injected: after a lore slot's lore, or at_depth (uses depth and role)."
      },
      "depth" => %{"type" => "integer", "minimum" => 0, "description" => "Messages back from the newest, for at_depth."},
      "role" => %{
        "type" => "string",
        "enum" => ~w(system user assistant),
        "description" => "Message role, for at_depth."
      },
      "condition" => %{
        "type" => "string",
        "description" => ~s(A Liquid condition, e.g. "vars.flag"; it is injected only while true.)
      },
      "enabled" => %{"type" => "boolean"},
      "uses" => %{
        "type" => ["integer", "null"],
        "minimum" => 1,
        "description" => "Successful replies it lasts for; null lasts until removed."
      },
      "order" => %{
        "type" => "integer",
        "minimum" => 0,
        "description" => "Lower runs first among injections in the same slot."
      }
    }

    [
      %Tool{
        name: "list_injections",
        description:
          "List a role-play chat's injections, spent and disabled ones included, optionally searched by key.",
        parameters: schema(%{"chat_id" => @chat_id, "query" => Args.query_property()}, ["chat_id"]),
        kind: :read,
        summary: fn _ -> "List a chat's injections" end,
        run: fn scope, args ->
          with {:ok, chat} <- roleplay_chat(scope, args) do
            rows = scope |> Injections.list_injections(chat.id) |> Enum.map(&injection_map/1)
            {:ok, Args.list("injections", Args.by_name(rows, args["query"], "key"))}
          end
        end
      },
      Batch.items("create_injections",
        description: "Create injections in role-play chats.",
        verb: "Create",
        noun: injections,
        name_key: "key",
        item: schema(Map.put(props, "chat_id", @chat_id), ["chat_id", "key", "content", "position"]),
        run: fn scope, item ->
          with {:ok, chat} <- roleplay_chat(scope, item) do
            scope |> Injections.create_injection(chat.id, Args.attrs(item, @keys)) |> Args.wrap(&injection_map/1)
          end
        end
      ),
      Batch.items("update_injections",
        description: "Change injections; only the given fields change.",
        verb: "Update",
        noun: injections,
        label: label,
        item: schema(Map.put(props, "id", @id), ["id"]),
        run: fn scope, item ->
          with {:ok, injection} <- editable(scope, item) do
            scope |> Injections.update_injection(injection, Args.attrs(item, @keys)) |> Args.wrap(&injection_map/1)
          end
        end
      ),
      Batch.ids("delete_injections",
        description: "Delete injections.",
        verb: "Delete",
        noun: injections,
        label: label,
        run: fn scope, args ->
          with {:ok, injection} <- editable(scope, args) do
            scope
            |> Injections.delete_injection(injection)
            |> Args.wrap(&%{"deleted" => true, "id" => &1.id, "key" => &1.key})
          end
        end
      ),
      Batch.ids("rearm_injections",
        description: "Restore limited injections' remaining uses to their full count.",
        verb: "Rearm",
        noun: injections,
        label: label,
        run: fn scope, args ->
          with {:ok, injection} <- editable(scope, args) do
            scope |> Injections.rearm(injection) |> Args.wrap(&injection_map/1)
          end
        end
      )
    ]
  end

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
      case Injections.get_injection(scope, id) do
        nil -> {:error, Args.error(:not_found)}
        injection -> {:ok, injection}
      end
    end
  end

  defp schema(props, required), do: %{"type" => "object", "properties" => props, "required" => required}

  defp injection_map(%Injection{} = i) do
    %{
      "id" => i.id,
      "chat_id" => i.chat_id,
      "key" => i.key,
      "content" => i.content,
      "position" => i.position,
      "depth" => i.depth,
      "role" => i.role,
      "condition" => i.condition,
      "enabled" => i.enabled,
      "uses" => i.uses,
      "remaining" => i.remaining,
      "order" => i.order,
      "active" => Injection.active?(i),
      "path" => Paths.chat(i.chat_id)
    }
  end
end
