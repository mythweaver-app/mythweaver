defmodule Mythweaver.Assistant.Tools.Settings do
  @moduledoc "Assistant tools over `Mythweaver.Settings`: list settings by category and change one."

  alias Mythweaver.Assistant.Paths
  alias Mythweaver.Assistant.Tool
  alias Mythweaver.Assistant.Tools.Args
  alias Mythweaver.Assistant.Tools.Batch
  alias Mythweaver.Settings

  def tools do
    [
      %Tool{
        name: "list_settings",
        description:
          "List settings with their current values and options, optionally for one category. " <>
            ~s{level "user" (default) shows the user's effective values; level "site" shows site-wide } <>
            "defaults and returns nothing unless the user is an admin.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "category" => %{
              "type" => "string",
              "enum" => category_ids(),
              "description" => "Only this category's settings."
            },
            "level" => level_property()
          },
          "required" => []
        },
        kind: :read,
        summary: fn args -> "List #{args["category"] || "all"} settings" end,
        run: &list_settings/2
      },
      %Tool{
        name: "update_setting",
        description:
          "Change one setting's value (keys from list_settings). A null value resets it to the inherited default. " <>
            "level \"site\" changes it for everyone and needs an admin.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "key" => %{"type" => "string", "description" => "Setting key, e.g. lore.scan_depth."},
            "value" => %{"description" => "The new value: boolean, number, text, an option value, or a list."},
            "level" => level_property()
          },
          "required" => ["key", "value"]
        },
        kind: :write,
        summary: fn args ->
          "Set #{args["key"] || "a setting"} to #{inspect(args["value"])}" <>
            if(args["level"] == "site", do: " for the site", else: "")
        end,
        run: &update_setting/2
      },
      Batch.items("lock_settings",
        description:
          "Lock or unlock settings a site admin controls for every user: a locked key reads the site value and " <>
            "cannot be changed or reset by that user.",
        verb: "Lock or unlock",
        noun: {"setting", "settings"},
        item: %{
          "type" => "object",
          "properties" => %{
            "key" => %{"type" => "string", "description" => "Setting key, from list_settings."},
            "locked" => %{"type" => "boolean", "description" => "true locks it, false unlocks it."}
          },
          "required" => ["key", "locked"]
        },
        name_key: "key",
        run: &lock/2
      )
    ]
  end

  defp list_settings(scope, args) do
    with {:ok, level} <- level(args),
         {:ok, keys} <- category_keys(args["category"]) do
      rows =
        for entry <- Settings.entries(scope, level), keys == :all or entry.key in keys do
          %{
            "key" => entry.key,
            "label" => entry.label,
            "description" => entry[:description],
            "type" => to_string(entry.type),
            "value" => entry.value,
            "options" => for({value, label} <- entry[:options] || [], do: %{"value" => value, "label" => label}),
            "editable" => entry.editable?,
            "locked" => entry.locked?
          }
        end

      {:ok, Map.put(Args.list("settings", rows), "path", Paths.settings(args["category"] || "models"))}
    end
  end

  defp update_setting(scope, %{"key" => key} = args) do
    with {:ok, level} <- level(args),
         true <- key in all_keys() || {:error, %{"error" => "unknown setting"}} do
      case Settings.put(scope, level, key, args["value"]) do
        :ok -> {:ok, %{"key" => key, "level" => to_string(level), "value" => current(scope, level, key)}}
        {:error, reason} -> {:error, Args.error(reason)}
      end
    end
  end

  defp lock(scope, %{"key" => key, "locked" => locked}) when is_boolean(locked) do
    if key in all_keys() do
      case Settings.lock(scope, key, locked) do
        :ok -> {:ok, %{"key" => key, "locked" => locked}}
        {:error, reason} -> {:error, Args.error(reason)}
      end
    else
      {:error, %{"error" => "unknown setting"}}
    end
  end

  defp lock(_scope, _args), do: {:error, %{"error" => "locked must be true or false"}}

  defp current(scope, level, key) do
    case Enum.find(Settings.entries(scope, level), &(&1.key == key)) do
      nil -> nil
      entry -> entry.value
    end
  end

  defp level(args) do
    case args["level"] do
      nil -> {:ok, :user}
      "user" -> {:ok, :user}
      "site" -> {:ok, :site}
      _ -> {:error, %{"error" => ~s|level must be "user" or "site"|}}
    end
  end

  defp category_keys(nil), do: {:ok, :all}

  defp category_keys(id) do
    case Enum.find(Settings.categories(), &(&1.id == id)) do
      nil -> {:error, %{"error" => "unknown category"}}
      category -> {:ok, for(section <- category.sections, key <- section.settings, do: key)}
    end
  end

  defp all_keys, do: for(c <- Settings.categories(), s <- c.sections, key <- s.settings, do: key)

  defp category_ids, do: Enum.map(Settings.categories(), & &1.id)

  defp level_property, do: %{"type" => "string", "enum" => ["user", "site"], "description" => "user (default) or site."}
end
