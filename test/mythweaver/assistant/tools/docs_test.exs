defmodule Mythweaver.Assistant.Tools.DocsTest do
  use ExUnit.Case, async: true

  alias Mythweaver.Accounts.Scope
  alias Mythweaver.Assistant.Tools
  alias Mythweaver.Docs.Source

  defp call(name, args) do
    {:ok, tool} = Tools.fetch(name)
    Tools.run(%Scope{}, tool, args)
  end

  describe "a docs page's source" do
    setup do
      root = Path.join(System.tmp_dir!(), "mythweaver-docs-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "chats"))
      on_exit(fn -> File.rm_rf!(root) end)
      %{root: root}
    end

    test "links become page ids and sections split at headings outside code", %{root: root} do
      file = Path.join(root, "chats/messages.md")

      File.write!(file, """
      ---
      title: Messages
      order: 1
      ---

      Intro, see [sticky](../lore/timing.md#sticky), [the chat](index.md) and [site](https://example.com/a.md).

      ## Edit `mw.messages.edit`

      ```markdown
      ## not a heading
      ```

      ### Undo

      Text.
      """)

      page = Source.read!(root, file)

      assert page.id == "chats/messages"
      assert page.body =~ "[sticky](lore/timing#sticky)"
      assert page.body =~ "[the chat](chats)"
      assert page.body =~ "(https://example.com/a.md)"

      assert [
               %{heading: nil, text: "Intro" <> _},
               %{
                 heading: "Edit mw.messages.edit",
                 id: "edit-mwmessagesedit",
                 level: 2,
                 text: "```markdown\n## not a heading\n```"
               },
               %{heading: "Undo", id: "undo", level: 3, text: "Text."}
             ] = page.sections
    end
  end

  test "every listed page reads, and so does every section it lists" do
    {:ok, %{"pages" => pages}} = call("list_docs", %{})
    assert %{"page" => "index"} = hd(pages)

    for %{"page" => id} <- pages do
      assert {:ok, %{"markdown" => markdown, "sections" => sections}} = call("read_doc", %{"page" => id})
      refute markdown =~ ~r/\]\([^)]*\.md[)#]/, "#{id} still links a .md file"

      for heading <- sections do
        assert {:ok, %{"section" => ^heading, "markdown" => "#" <> _}} =
                 call("read_doc", %{"page" => id, "section" => heading})
      end
    end
  end

  test "a how-to question finds the section that answers it, and read_doc reads it by its anchor" do
    {:ok, %{"results" => results}} =
      call("search_docs", %{"query" => "How do I make a lore entry sticky?", "limit" => 3})

    assert %{"page" => "lore/timing", "section" => "Sticky"} in Enum.map(results, &Map.take(&1, ["page", "section"]))
    assert Enum.all?(results, &is_binary(&1["snippet"]))

    assert {:ok, %{"section" => "Sticky", "markdown" => "## Sticky" <> _}} =
             call("read_doc", %{"page" => "../lore/timing.md#sticky"})
  end

  test "an unknown page or section is an error the model can act on" do
    assert {:error, %{"error" => "No documentation page nope" <> _}} = call("read_doc", %{"page" => "nope"})

    assert {:error, %{"error" => "That page has no such section" <> _}} =
             call("read_doc", %{"page" => "lore", "section" => "nope"})

    assert {:ok, %{"results" => []}} = call("search_docs", %{"query" => "a the"})
  end
end
