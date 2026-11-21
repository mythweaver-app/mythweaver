defmodule Mythweaver.Memory.JSONTest do
  use ExUnit.Case, async: true

  alias Mythweaver.Memory.JSON

  @object ~s({"title": "T", "content": "C", "keywords": ["k"]})

  describe "decode/1" do
    test "takes a fenced block's body over the surrounding prose" do
      text = "Here you go:\n```json\n#{@object}\n```\nand {\"ignored\": true}"
      assert JSON.decode(text) == {:ok, %{"title" => "T", "content" => "C", "keywords" => ["k"]}}
    end

    test "reads a bare fence" do
      assert {:ok, %{"title" => "T"}} = JSON.decode("```\n#{@object}\n```")
    end

    test "falls back to the first balanced object, braces inside strings ignored" do
      text = ~s(Sure! {"title": "a } b", "content": "C", "nested": {"x": 1}} trailing {"no": 1})
      assert {:ok, %{"title" => "a } b", "nested" => %{"x" => 1}}} = JSON.decode(text)
    end

    test "decodes the whole text" do
      assert {:ok, %{"title" => "T"}} = JSON.decode(@object)
    end

    test "drops think blocks, a BOM and control characters" do
      text = ~s(\uFEFF<think>{"title": "wrong"}</think>\r\n{"title": "right\u0001", "content": "C"})
      assert {:ok, %{"title" => "right"}} = JSON.decode(text)
    end

    test "strips comments and trailing commas outside strings" do
      text = """
      {
        // the title
        "title": "http://x.test/a,}", /* inline */
        "keywords": ["a", "b",],
      }
      """

      assert JSON.decode(text) == {:ok, %{"title" => "http://x.test/a,}", "keywords" => ["a", "b"]}}
    end

    test "refuses text with no object" do
      assert JSON.decode("no json here") == {:error, :unparseable}
      assert JSON.decode(~s(["a list"])) == {:error, :unparseable}
      assert JSON.decode(nil) == {:error, :unparseable}
    end
  end

  describe "memory/1" do
    test "requires a title, content and keywords, and splits comma keywords" do
      assert JSON.memory(%{"title" => " T ", "content" => "C", "keywords" => "a, b,,"}) ==
               {:ok, %{"title" => "T", "content" => "C", "keywords" => ["a", "b"]}}

      assert {:ok, %{"keywords" => []}} = JSON.memory(%{"title" => "T", "content" => "C", "keywords" => []})
      assert JSON.memory(%{"title" => "T", "content" => "C", "keywords" => 3}) == {:error, :invalid}
      assert JSON.memory(%{"title" => "T", "content" => "C"}) == {:error, :invalid}
      assert JSON.memory(%{"title" => " ", "content" => "C", "keywords" => []}) == {:error, :invalid}
      assert JSON.memory(%{"title" => "T"}) == {:error, :invalid}
    end
  end

  describe "consolidation/1" do
    test "requires a non-empty list of complete summaries" do
      summary = %{"title" => "Arc", "summary" => "S", "keywords" => ["k"], "member_ids" => ["001", 2]}

      assert {:ok, %{"summaries" => [%{"member_ids" => ["001", "2"]}], "unassigned" => []}} =
               JSON.consolidation(%{"summaries" => [summary]})

      assert JSON.consolidation(%{"summaries" => []}) == {:error, :invalid}
      assert JSON.consolidation(%{"summaries" => [Map.delete(summary, "member_ids")]}) == {:error, :invalid}
    end
  end
end
