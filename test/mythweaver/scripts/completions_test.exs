defmodule Mythweaver.Scripts.CompletionsTest do
  use ExUnit.Case, async: true

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Accounts.User
  alias Mythweaver.Scripts.API
  alias Mythweaver.Scripts.Completions

  test "offers exactly the host functions a script VM has, with arguments and descriptions" do
    data = Completions.lua(:user_message)

    offered =
      for {path, options} <- data.members,
          path != "event",
          %{type: "function", label: name} <- options,
          into: MapSet.new(),
          do: "#{path}.#{name}"

    assert offered == installed_functions()
    assert %{detail: "(s, pattern, repl [, flags [, limit]])"} = find(data.members["regex"], "replace")

    for {path, options} <- data.members, %{type: "function"} = option <- options do
      assert is_binary(option[:info]) and option.info != "", "#{path}.#{option.label} has no description"
    end

    assert %{type: "namespace", info: "Every character." <> _} = find(data.members["mw"], "characters")
    assert ~w(event mw regex) == data.globals |> Enum.map(& &1.label) |> Enum.sort()
  end

  test "lists the event fields of the script's trigger" do
    assert ~w(trigger chat_id text character_id message_id edit images) == labels(Completions.lua(:user_message))
    assert "entries" in labels(Completions.lua("lore_activated"))
    assert ~w(trigger chat_id) == labels(Completions.lua(nil))
    assert %{detail: "string | nil"} = find(Completions.lua(:user_message).members["event"], "message_id")
  end

  # Walks the `mw` and `regex` tables of a VM set up exactly as a run sets it up, for an owner (who
  # holds every script permission, so nothing is refused).
  defp installed_functions do
    scope = %Scope{user: %User{role: :owner}}
    lua = API.install(Lua.new(), %{scope: scope, chat: nil, trigger: :user_message, event: %{}})

    {[names], _} =
      Lua.eval!(lua, ~S"""
      local out = {}
      local function walk(path, t)
        for k, v in pairs(t) do
          if type(v) == "table" then walk(path .. "." .. k, v) else out[#out + 1] = path .. "." .. k end
        end
      end
      walk("mw", mw)
      walk("regex", regex)
      return table.concat(out, " ")
      """)

    names |> String.split() |> MapSet.new()
  end

  defp labels(data), do: Enum.map(data.members["event"], & &1.label)
  defp find(options, label), do: Enum.find(options, &(&1.label == label))
end
