defmodule Mythweaver.Assistant.PathsTest do
  use ExUnit.Case, async: true

  alias Mythweaver.Assistant.Paths

  @id "01960000-0000-7000-8000-000000000000"

  test "every path is a route" do
    paths =
      [
        Paths.character(@id),
        Paths.lore_book(@id),
        Paths.lore_entry(@id),
        Paths.prompt(@id),
        Paths.prompt_block(@id),
        Paths.connection(@id),
        Paths.model(@id),
        Paths.chat(@id),
        Paths.script(@id),
        Paths.tag(@id),
        Paths.prompt_outlet(@id),
        Paths.memory_profile(@id),
        Paths.side_prompt(@id),
        Paths.side_prompt_set(@id),
        Paths.chat_memory(@id),
        Paths.variable(@id),
        Paths.expression_profile(@id),
        Paths.settings("models")
      ] ++
        Enum.map(
          ~w[characters lore prompts prompt_blocks connections models settings jobs import tags
             prompt_outlets memory_profiles side_prompts side_prompt_sets variables scripts expression_profiles analytics]a,
          &Paths.index/1
        )

    for path <- paths do
      assert Phoenix.Router.route_info(MythweaverWeb.Router, "GET", path, "localhost") != :error, path
    end
  end
end
